// Copyright (c) 2026 Greg Turner <gmt@be-evil.net>
//
// Permission to use, copy, modify, and distribute this software for any
// purpose with or without fee is hereby granted, provided that the above
// copyright notice and this permission notice appear in all copies.
//
// THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
// WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
// MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
// ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
// WHATSOEVER RESULTING FROM LOSS OF MIND, USE, DATA OR PROFITS, WHETHER
// IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING
// OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
//
// Ported from tmux/options.c
// Original copyright:
//   Copyright (c) 2008 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

//! options.zig – hierarchical runtime options.
//!
//! Options are stored in a per-scope hash map with parent-chain lookups.
//! Three global scopes exist (global_options, global_s_options,
//! global_w_options); sessions and windows inherit from their respective
//! global scope.  Pane options inherit from their window's options.

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const log = @import("log.zig");
const colour_mod = @import("colour.zig");
const style_mod = @import("style.zig");
const win = @import("window.zig");
const sess = @import("session.zig");
const alerts_mod = @import("alerts.zig");
const client_registry = @import("client-registry.zig");
const server_client = @import("server-client.zig");
const server_fn = @import("server-fn.zig");
const status_mod = @import("status.zig");
const utf8_mod = @import("utf8.zig");
const resize_mod = @import("resize.zig");
const format_mod = @import("format.zig");
const cmd_mod = @import("cmd.zig");
const tty_mod = @import("tty.zig");

/// Global option tables (see options-table.zig for entries).
/// Set at startup before any session is created.
pub var global_options: *T.Options = undefined;
pub var global_s_options: *T.Options = undefined;
pub var global_w_options: *T.Options = undefined;

/// True once the global option trees have been populated at startup.
pub var options_ready: bool = false;

const empty_array_items = [_]T.OptionsArrayItem{};
const OptionNameMap = struct {
    from: []const u8,
    to: []const u8,
};
const option_name_maps = [_]OptionNameMap{
    .{ .from = "display-panes-color", .to = "display-panes-colour" },
    .{ .from = "display-panes-active-color", .to = "display-panes-active-colour" },
    .{ .from = "clock-mode-color", .to = "clock-mode-colour" },
    .{ .from = "cursor-color", .to = "cursor-colour" },
    .{ .from = "prompt-cursor-color", .to = "prompt-cursor-colour" },
    .{ .from = "pane-colors", .to = "pane-colours" },
};

// ── Lifecycle ─────────────────────────────────────────────────────────────

/// Create a new options set, optionally inheriting from a parent scope.
pub fn options_create(parent: ?*T.Options) *T.Options {
    const oo = xm.allocator.create(T.Options) catch unreachable;
    oo.* = T.Options.init(xm.allocator, parent);
    return oo;
}

/// Free all entries in an options set and destroy it.
pub fn options_free(oo: *T.Options) void {
    var it = oo.entries.valueIterator();
    while (it.next()) |v| {
        free_value(v);
    }
    oo.deinit();
    xm.allocator.destroy(oo);
}

fn free_value(v: *T.OptionsValue) void {
    switch (v.*) {
        .string => |s| xm.allocator.free(s),
        .command => |s| xm.allocator.free(s),
        .array => |*arr| {
            for (arr.items) |item| xm.allocator.free(item.value);
            arr.deinit(xm.allocator);
        },
        else => {},
    }
}

fn entry_name_owned(oo: *T.Options, name: []const u8) ?[]u8 {
    var it = oo.entries.keyIterator();
    while (it.next()) |key| {
        if (std.mem.eql(u8, key.*, name)) return key.*;
    }
    return null;
}

fn put_value(oo: *T.Options, name: []const u8, value: T.OptionsValue) void {
    if (oo.entries.getPtr(name)) |existing| {
        free_value(existing);
        existing.* = value;
        return;
    }
    const owned_name = xm.xstrdup(name);
    oo.entries.put(owned_name, value) catch unreachable;
}

// ── Lookup ────────────────────────────────────────────────────────────────

/// Look up an option by name, walking up the parent chain.
pub fn options_get(oo: *T.Options, name: []const u8) ?*T.OptionsValue {
    if (oo.entries.getPtr(name)) |v| return v;
    if (oo.parent) |p| return options_get(p, name);
    return null;
}

/// Look up an option in this scope only (no parent walk). Tries the exact
/// name, then [`options_map_name`] (tmux `options_get_only`).
pub fn options_get_only(oo: *T.Options, name: []const u8) ?*T.OptionsValue {
    if (oo.entries.getPtr(name)) |v| return v;
    const mapped = options_map_name(name);
    if (!std.mem.eql(u8, name, mapped))
        return oo.entries.getPtr(mapped);
    return null;
}

pub fn options_map_name(name: []const u8) []const u8 {
    for (option_name_maps) |mapping| {
        if (std.mem.eql(u8, mapping.from, name)) return mapping.to;
    }
    return name;
}

pub fn options_parse(name: []const u8, idx: *?u32) ?[]u8 {
    idx.* = null;
    if (name.len == 0) return null;

    const open = std.mem.indexOfScalar(u8, name, '[') orelse return xm.xstrdup(name);
    const close = std.mem.indexOfScalarPos(u8, name, open + 1, ']') orelse return null;
    if (close + 1 != name.len or close == open + 1) return null;

    const idx_text = name[open + 1 .. close];
    for (idx_text) |ch| {
        if (!std.ascii.isDigit(ch)) return null;
    }
    idx.* = std.fmt.parseInt(u32, idx_text, 10) catch return null;
    return xm.xstrdup(name[0..open]);
}

pub fn options_match(s: []const u8, idx: *?u32, ambiguous: *bool) ?[]u8 {
    ambiguous.* = false;

    const parsed = options_parse(s, idx) orelse return null;
    defer xm.allocator.free(parsed);
    if (parsed.len != 0 and parsed[0] == '@') return xm.xstrdup(parsed);

    const name = options_map_name(parsed);
    for (table.options_table) |*oe| {
        if (std.mem.eql(u8, oe.name, name)) return xm.xstrdup(oe.name);
    }

    var found: ?*const T.OptionsTableEntry = null;
    for (table.options_table) |*oe| {
        if (std.mem.startsWith(u8, oe.name, name)) {
            if (found != null) {
                ambiguous.* = true;
                return null;
            }
            found = oe;
        }
    }
    return if (found) |oe| xm.xstrdup(oe.name) else null;
}

// ── Typed getters ─────────────────────────────────────────────────────────

/// Get a numeric option value; returns 0 if not found.
pub fn options_get_number(oo: *T.Options, name: []const u8) i64 {
    const v = options_get(oo, name) orelse return 0;
    return switch (v.*) {
        .number => |n| n,
        .bool => |b| if (b) 1 else 0,
        .choice => |ch| @intCast(ch),
        .colour => |col| col,
        else => 0,
    };
}

/// Get a string option value; returns "" if not found.
pub fn options_get_string(oo: *T.Options, name: []const u8) []const u8 {
    const v = options_get(oo, name) orelse return "";
    return switch (v.*) {
        .string => |s| s,
        else => "",
    };
}

pub fn options_get_command_string(oo: *T.Options, name: []const u8) []const u8 {
    const v = options_get(oo, name) orelse return "";
    return switch (v.*) {
        .command => |s| s,
        else => "",
    };
}

fn array_find_position(items: []const T.OptionsArrayItem, idx: u32) usize {
    var pos: usize = 0;
    while (pos < items.len and items[pos].index < idx) : (pos += 1) {}
    return pos;
}

fn array_next_free_index(items: []const T.OptionsArrayItem) u32 {
    var next: u32 = 0;
    for (items) |item| {
        if (item.index == next) {
            next += 1;
            continue;
        }
        if (item.index > next) break;
    }
    return next;
}

fn array_join_values(alloc: std.mem.Allocator, items: []const T.OptionsArrayItem, sep: []const u8) []u8 {
    if (items.len == 0) return xm.xstrdup("");

    var out: std.ArrayList(u8) = .{};
    for (items, 0..) |item, idx| {
        if (idx != 0) out.appendSlice(alloc, sep) catch unreachable;
        out.appendSlice(alloc, item.value) catch unreachable;
    }
    return out.toOwnedSlice(alloc) catch unreachable;
}

fn array_clear(arr: *std.ArrayList(T.OptionsArrayItem)) void {
    for (arr.items) |item| xm.allocator.free(item.value);
    arr.clearRetainingCapacity();
}

fn array_set(
    arr: *std.ArrayList(T.OptionsArrayItem),
    idx: u32,
    value: ?[]const u8,
    append: bool,
) void {
    const pos = array_find_position(arr.items, idx);
    const existing = pos < arr.items.len and arr.items[pos].index == idx;
    if (value == null) {
        if (existing) {
            xm.allocator.free(arr.items[pos].value);
            _ = arr.orderedRemove(pos);
        }
        return;
    }

    const owned = if (existing and append)
        xm.xasprintf("{s}{s}", .{ arr.items[pos].value, value.? })
    else
        xm.xstrdup(value.?);
    if (existing) {
        xm.allocator.free(arr.items[pos].value);
        arr.items[pos].value = owned;
        return;
    }
    arr.insert(xm.allocator, pos, .{ .index = idx, .value = owned }) catch unreachable;
}

fn ensure_local_array(oo: *T.Options, name: []const u8) *std.ArrayList(T.OptionsArrayItem) {
    if (oo.entries.getPtr(name)) |existing| {
        return switch (existing.*) {
            .array => |*arr| arr,
            else => unreachable,
        };
    }

    put_value(oo, name, .{ .array = .{} });
    return &oo.entries.getPtr(name).?.array;
}

fn array_separator(oe: *const T.OptionsTableEntry) []const u8 {
    if (oe.separator) |sep| return sep;
    if (oe.is_hook) return "";
    return " ,";
}

fn array_assign(
    arr: *std.ArrayList(T.OptionsArrayItem),
    oe: *const T.OptionsTableEntry,
    value: []const u8,
) void {
    const separator = array_separator(oe);
    if (separator.len == 0) {
        if (value.len == 0) return;
        array_set(arr, array_next_free_index(arr.items), value, false);
        return;
    }
    if (value.len == 0) return;

    var it = std.mem.tokenizeAny(u8, value, separator);
    while (it.next()) |part| {
        array_set(arr, array_next_free_index(arr.items), part, false);
    }
}

/// Get an array option value as indexed items; returns an empty slice if not found.
pub fn options_get_array_items(oo: *T.Options, name: []const u8) []const T.OptionsArrayItem {
    const v = options_get(oo, name) orelse return empty_array_items[0..];
    return switch (v.*) {
        .array => |arr| arr.items,
        else => empty_array_items[0..],
    };
}

pub fn options_array_get_value(value: *const T.OptionsValue, idx: u32) ?[]const u8 {
    return switch (value.*) {
        .array => |arr| blk: {
            const pos = array_find_position(arr.items, idx);
            if (pos >= arr.items.len or arr.items[pos].index != idx) break :blk null;
            break :blk arr.items[pos].value;
        },
        else => null,
    };
}

pub fn options_get_array_item(oo: *T.Options, name: []const u8, idx: u32) ?[]const u8 {
    const v = options_get(oo, name) orelse return null;
    return options_array_get_value(v, idx);
}

/// Get a raw style option string; returns null if absent or non-string.
pub fn options_get_style_string(oo: *T.Options, name: []const u8) ?[]const u8 {
    const v = options_get(oo, name) orelse return null;
    return switch (v.*) {
        .string => |s| s,
        else => null,
    };
}

// ── Typed setters ─────────────────────────────────────────────────────────

/// Set a numeric option.
pub fn options_set_number(oo: *T.Options, name: []const u8, value: i64) void {
    put_value(oo, name, .{ .number = value });
}

/// Set a boolean option.
pub fn options_set_bool(oo: *T.Options, name: []const u8, value: bool) void {
    put_value(oo, name, .{ .bool = value });
}

/// Set a string option (takes ownership of a copy of value).
pub fn options_set_string(oo: *T.Options, comptime _: bool, name: []const u8, value: []const u8) void {
    put_value(oo, name, .{ .string = xm.xstrdup(value) });
}

pub fn options_set_command(oo: *T.Options, name: []const u8, value: []const u8) void {
    put_value(oo, name, .{ .command = xm.xstrdup(value) });
}

/// Set a colour option.
pub fn options_set_colour(oo: *T.Options, name: []const u8, value: i32) void {
    put_value(oo, name, .{ .colour = value });
}

pub fn options_remove(oo: *T.Options, name: []const u8) void {
    if (oo.entries.fetchRemove(name)) |kv| {
        xm.allocator.free(kv.key);
        var value = kv.value;
        free_value(&value);
    }
}

pub fn options_table_entry(name: []const u8) ?*const T.OptionsTableEntry {
    for (table.options_table) |*oe| {
        if (std.mem.eql(u8, oe.name, name)) return oe;
    }
    return null;
}

pub fn options_scope_has(scope: T.OptionsScope, oe: *const T.OptionsTableEntry) bool {
    return (scope.server and oe.scope.server) or
        (scope.session and oe.scope.session) or
        (scope.window and oe.scope.window) or
        (scope.pane and oe.scope.pane);
}

pub fn options_clone_array(value: []const []const u8) T.OptionsValue {
    var arr: std.ArrayList(T.OptionsArrayItem) = .{};
    for (value, 0..) |item, idx| {
        arr.append(xm.allocator, .{ .index = @intCast(idx), .value = xm.xstrdup(item) }) catch unreachable;
    }
    return .{ .array = arr };
}

pub fn options_set_array(oo: *T.Options, name: []const u8, items: []const []const u8) void {
    put_value(oo, name, options_clone_array(items));
}

pub fn options_append_array(oo: *T.Options, name: []const u8, item: []const u8) void {
    const arr = ensure_local_array(oo, name);
    array_set(arr, array_next_free_index(arr.items), item, false);
}

pub fn options_parse_number(value: []const u8) ?i64 {
    return std.fmt.parseInt(i64, value, 10) catch null;
}

pub fn options_parse_boolish(value: ?[]const u8) ?bool {
    const raw = value orelse return true;
    if (std.ascii.eqlIgnoreCase(raw, "on") or
        std.ascii.eqlIgnoreCase(raw, "yes") or
        std.ascii.eqlIgnoreCase(raw, "true") or
        std.mem.eql(u8, raw, "1")) return true;
    if (std.ascii.eqlIgnoreCase(raw, "off") or
        std.ascii.eqlIgnoreCase(raw, "no") or
        std.ascii.eqlIgnoreCase(raw, "false") or
        std.mem.eql(u8, raw, "0")) return false;
    return null;
}

pub fn options_choice_index(oe: *const T.OptionsTableEntry, value: []const u8) ?u32 {
    if (oe.choices) |choices| {
        for (choices, 0..) |choice, idx| {
            if (std.ascii.eqlIgnoreCase(choice, value)) return @intCast(idx);
        }
    }
    return if (options_parse_number(value)) |parsed|
        if (parsed >= 0) @intCast(parsed) else null
    else
        null;
}

pub fn options_set_from_string(
    oo: *T.Options,
    oe: ?*const T.OptionsTableEntry,
    name: []const u8,
    idx: ?u32,
    value: ?[]const u8,
    append: bool,
    cause: *?[]u8,
) bool {
    if (oe == null) {
        if (value == null) {
            cause.* = xm.xstrdup("empty value");
            return false;
        }
        if (append) {
            const current = options_get_string(oo, name);
            const combined = xm.xasprintf("{s}{s}", .{ current, value.? });
            defer xm.allocator.free(combined);
            options_set_string(oo, false, name, combined);
        } else {
            options_set_string(oo, false, name, value.?);
        }
        return true;
    }

    switch (oe.?.type) {
        .string, .style => {
            if (value == null) {
                cause.* = xm.xstrdup("empty value");
                return false;
            }
            if (append) {
                const current = options_get_string(oo, name);
                const combined = xm.xasprintf("{s}{s}", .{ current, value.? });
                defer xm.allocator.free(combined);
                options_set_string(oo, false, name, combined);
            } else {
                options_set_string(oo, false, name, value.?);
            }
        },
        .number => {
            const parsed = options_parse_number(value orelse "") orelse {
                cause.* = xm.xasprintf("invalid number: {s}", .{value orelse ""});
                return false;
            };
            options_set_number(oo, name, parsed);
        },
        .flag, .bool => {
            const parsed = options_parse_boolish(value) orelse {
                cause.* = xm.xasprintf("invalid flag value: {s}", .{value orelse ""});
                return false;
            };
            options_set_number(oo, name, if (parsed) 1 else 0);
        },
        .choice => {
            const choice_idx = options_choice_index(oe.?, value orelse "") orelse {
                cause.* = xm.xasprintf("invalid choice: {s}", .{value orelse ""});
                return false;
            };
            if (oe.?.choices) |choices| {
                if (choice_idx >= choices.len) {
                    cause.* = xm.xasprintf("invalid choice: {s}", .{value orelse ""});
                    return false;
                }
            }
            options_set_number(oo, name, choice_idx);
        },
        .colour => {
            const parsed = colour_mod.colour_fromstring(value orelse "");
            if (parsed == -1) {
                cause.* = xm.xasprintf("invalid colour: {s}", .{value orelse ""});
                return false;
            }
            options_set_colour(oo, name, parsed);
        },
        .array => {
            if (value == null) {
                cause.* = xm.xstrdup("empty value");
                return false;
            }
            const arr = ensure_local_array(oo, name);
            if (idx) |array_idx| {
                array_set(arr, array_idx, value.?, append);
            } else {
                if (!append) array_clear(arr);
                array_assign(arr, oe.?, value.?);
            }
        },
        .command => {
            if (value == null) {
                cause.* = xm.xstrdup("empty value");
                return false;
            }
            options_set_command(oo, name, value.?);
        },
    }
    return true;
}

pub fn options_value_to_string(_: []const u8, value: *const T.OptionsValue, oe: ?*const T.OptionsTableEntry) []u8 {
    return switch (value.*) {
        .string => |s| xm.xstrdup(s),
        .number => |n| if (oe) |entry|
            switch (entry.type) {
                .choice => if (entry.choices) |choices|
                    if (n >= 0 and @as(usize, @intCast(n)) < choices.len) xm.xstrdup(choices[@intCast(n)]) else xm.xasprintf("{d}", .{n})
                else
                    xm.xasprintf("{d}", .{n}),
                .flag, .bool => xm.xstrdup(if (n != 0) "on" else "off"),
                else => xm.xasprintf("{d}", .{n}),
            }
        else
            xm.xasprintf("{d}", .{n}),
        .bool => |b| xm.xstrdup(if (b) "on" else "off"),
        .choice => |idx| if (oe) |entry|
            if (entry.choices) |choices|
                if (idx < choices.len) xm.xstrdup(choices[idx]) else xm.xasprintf("{d}", .{idx})
            else
                xm.xasprintf("{d}", .{idx})
        else
            xm.xasprintf("{d}", .{idx}),
        .colour => |colour| xm.xstrdup(colour_mod.colour_tostring(colour)),
        .style => |_| xm.xstrdup("default"),
        .flag => |b| xm.xstrdup(if (b) "on" else "off"),
        .array => |arr| array_join_values(xm.allocator, arr.items, " "),
        .command => |cmd| xm.xstrdup(cmd),
    };
}

// ── Default initialisation (from options table) ───────────────────────────

const table = @import("options-table.zig");

/// Install the default value for one table entry into an options set.
pub fn options_default(oo: *T.Options, oe: *const T.OptionsTableEntry) void {
    switch (oe.type) {
        .number, .choice, .colour, .flag => {
            options_set_number(oo, oe.name, oe.default_num);
        },
        .bool => {
            options_set_bool(oo, oe.name, oe.default_num != 0);
        },
        .string => {
            const def = oe.default_str orelse "";
            options_set_string(oo, false, oe.name, def);
        },
        .style => {
            const def = oe.default_str orelse "default";
            options_set_string(oo, false, oe.name, def);
        },
        .array => {
            if (oe.default_arr) |items| {
                options_set_array(oo, oe.name, items);
            } else if (oe.default_str) |value| {
                const arr = ensure_local_array(oo, oe.name);
                array_clear(arr);
                array_assign(arr, oe, value);
            }
        },
        .command => {
            const def = oe.default_str orelse "";
            options_set_command(oo, oe.name, def);
        },
    }
    _ = table; // suppress unused import warning until table is referenced
}

pub fn options_remove_or_default(
    oo: *T.Options,
    oe: ?*const T.OptionsTableEntry,
    name: []const u8,
    idx: ?u32,
    global: bool,
    cause: *?[]u8,
) bool {
    if (idx == null) {
        if (oe != null and global) {
            options_remove(oo, name);
            options_default(oo, oe.?);
        } else {
            options_remove(oo, name);
        }
        return true;
    }

    const existing = options_get_only(oo, name) orelse return true;
    switch (existing.*) {
        .array => |*arr| {
            array_set(arr, idx.?, null, false);
            return true;
        },
        else => {
            cause.* = xm.xstrdup("not an array");
            return false;
        },
    }
}

/// Initialise all options in a scope from the global table.
pub fn options_default_all(oo: *T.Options, scope: T.OptionsScope) void {
    for (table.options_table) |oe| {
        if ((oe.scope.server and scope.server) or
            (oe.scope.session and scope.session) or
            (oe.scope.window and scope.window) or
            (oe.scope.pane and scope.pane))
        {
            options_default(oo, &oe);
        }
    }
}

// ── Type predicates (C: OPTIONS_IS_STRING / OPTIONS_IS_ARRAY) ─────────────

/// True when the option is a string (or a user @-option with no table entry).
pub fn options_is_string(oe: ?*const T.OptionsTableEntry) bool {
    return oe == null or oe.?.type == .string;
}

/// True when the option is an array type.
pub fn options_is_array(oe: ?*const T.OptionsTableEntry) bool {
    return oe != null and oe.?.type == .array;
}

// ── options_to_string ─────────────────────────────────────────────────────

/// Convert an option value to a string.  When `idx` is null and the value
/// is an array, all elements are joined with spaces (C: idx == -1).
/// When `idx` is set, only the element at that index is returned.
pub fn options_to_string(
    oo: *T.Options,
    name: []const u8,
    idx: ?u32,
    numeric: bool,
) []u8 {
    const oe = options_table_entry(name);
    const v = options_get(oo, name) orelse return xm.xstrdup("");
    switch (v.*) {
        .array => |arr| {
            if (idx == null) {
                if (arr.items.len == 0) return xm.xstrdup("");
                var result: ?[]u8 = null;
                for (arr.items) |item| {
                    const next = xm.xstrdup(item.value);
                    if (result) |prev| {
                        const joined = xm.xasprintf("{s} {s}", .{ prev, next });
                        xm.allocator.free(prev);
                        xm.allocator.free(next);
                        result = joined;
                    } else {
                        result = next;
                    }
                }
                return result orelse xm.xstrdup("");
            }
            const pos = array_find_position(arr.items, idx.?);
            if (pos >= arr.items.len or arr.items[pos].index != idx.?) return xm.xstrdup("");
            return xm.xstrdup(arr.items[pos].value);
        },
        else => return options_value_to_string(name, v, oe),
    }
    _ = numeric;
}

// ── options_from_string_check ─────────────────────────────────────────────

fn checkshell_path(shell: []const u8) bool {
    if (shell.len == 0 or shell[0] != '/') return false;
    std.fs.accessAbsolute(shell, .{}) catch return false;
    return true;
}

/// Validate a string value against the table entry constraints (pattern,
/// style validity, etc.).  Returns true on success; on failure sets cause.
pub fn options_from_string_check(
    oe: ?*const T.OptionsTableEntry,
    value: []const u8,
    cause: *?[]u8,
) bool {
    const entry = oe orelse return true;
    if (std.mem.eql(u8, entry.name, "default-shell") and !checkshell_path(value)) {
        cause.* = xm.xasprintf("not a suitable shell: {s}", .{value});
        return false;
    }
    if (entry.type == .style) {
        if (std.mem.indexOf(u8, value, "#{") == null) {
            var sy = T.Style{};
            if (style_mod.style_parse(&sy, &T.grid_default_cell, value) != 0) {
                cause.* = xm.xasprintf("invalid style: {s}", .{value});
                return false;
            }
        }
    }
    return true;
}

// ── options_find_choice ───────────────────────────────────────────────────

/// Find a choice value in the table entry's choice list.  Returns the
/// index on success; on failure sets cause and returns null.
pub fn options_find_choice(
    oe: *const T.OptionsTableEntry,
    value: []const u8,
    cause: *?[]u8,
) ?u32 {
    if (oe.choices) |choices| {
        for (choices, 0..) |choice, idx| {
            if (std.mem.eql(u8, choice, value)) return @intCast(idx);
        }
    }
    cause.* = xm.xasprintf("unknown value: {s}", .{value});
    return null;
}

// ── options_parse_get ─────────────────────────────────────────────────────

/// Parse an option name (possibly with [idx]) and look it up.
/// When `only` is true, only the given options set is searched (no
/// parent chain).
pub fn options_parse_get(
    oo: *T.Options,
    s: []const u8,
    idx: *?u32,
    only: bool,
) ?*T.OptionsValue {
    const name = options_parse(s, idx) orelse return null;
    defer xm.allocator.free(name);
    return if (only) options_get_only(oo, name) else options_get(oo, name);
}

// ── options_match_get ─────────────────────────────────────────────────────

/// Match an option name (with prefix completion) and look it up.
/// Sets `ambiguous` when the prefix matches more than one option.
pub fn options_match_get(
    oo: *T.Options,
    s: []const u8,
    idx: *?u32,
    only: bool,
    ambiguous: *bool,
) ?*T.OptionsValue {
    const name = options_match(s, idx, ambiguous) orelse return null;
    defer xm.allocator.free(name);
    ambiguous.* = false;
    return if (only) options_get_only(oo, name) else options_get(oo, name);
}

// ── Parent chain helpers ──────────────────────────────────────────────────

pub fn options_get_parent(oo: *T.Options) ?*T.Options {
    return oo.parent;
}

pub fn options_set_parent(oo: *T.Options, parent: ?*T.Options) void {
    oo.parent = parent;
}

// ── C API parity: entry handles, iteration, and string parsing ───────────

/// Handle to one local option (tmux `struct options_entry`). `name` must
/// remain valid while in use — it points at storage inside `oo.entries`.
pub const OptionsEntry = struct {
    oo: *T.Options,
    name: []const u8,

    pub fn valuePtr(self: OptionsEntry) *T.OptionsValue {
        return self.oo.entries.getPtr(self.name).?;
    }
};

/// Lexicographic comparison of two local entries (tmux `options_cmp`).
pub fn options_cmp(lhs: OptionsEntry, rhs: OptionsEntry) std.math.Order {
    return std.mem.order(u8, lhs.name, rhs.name);
}

pub fn options_name(entry: OptionsEntry) []const u8 {
    return entry.name;
}

pub fn options_owner(entry: OptionsEntry) *T.Options {
    return entry.oo;
}

/// First local option in lexicographic name order (tmux `options_first`).
pub fn options_first(oo: *T.Options) ?OptionsEntry {
    var it = oo.entries.iterator();
    var best_key: ?[]const u8 = null;
    while (it.next()) |kv| {
        if (best_key == null or std.mem.order(u8, kv.key_ptr.*, best_key.?) == .lt)
            best_key = kv.key_ptr.*;
    }
    return if (best_key) |k| .{ .oo = oo, .name = k } else null;
}

/// Next local option after `entry` in lexicographic order (tmux `options_next`).
pub fn options_next(entry: OptionsEntry) ?OptionsEntry {
    var it = entry.oo.entries.iterator();
    var best_key: ?[]const u8 = null;
    while (it.next()) |kv| {
        if (std.mem.order(u8, kv.key_ptr.*, entry.name) != .gt) continue;
        if (best_key == null or std.mem.order(u8, kv.key_ptr.*, best_key.?) == .lt)
            best_key = kv.key_ptr.*;
    }
    return if (best_key) |k| .{ .oo = entry.oo, .name = k } else null;
}

/// Remove any existing value for `name` and insert a zero-initialised slot
/// (tmux `options_add`). The stored tag is `.number` until replaced.
pub fn options_add(oo: *T.Options, name: []const u8) void {
    options_remove(oo, name);
    put_value(oo, name, .{ .number = 0 });
}

/// Create an empty table-backed option (tmux `options_empty`).
pub fn options_empty(oo: *T.Options, oe: *const T.OptionsTableEntry) void {
    options_remove(oo, oe.name);
    switch (oe.type) {
        .array => put_value(oo, oe.name, .{ .array = .{} }),
        .string => put_value(oo, oe.name, .{ .string = xm.xstrdup("") }),
        .style => put_value(oo, oe.name, .{ .string = xm.xstrdup("") }),
        .command => put_value(oo, oe.name, .{ .command = xm.xstrdup("") }),
        .number, .colour => put_value(oo, oe.name, .{ .number = 0 }),
        .choice => put_value(oo, oe.name, .{ .choice = 0 }),
        .flag => put_value(oo, oe.name, .{ .flag = false }),
        .bool => put_value(oo, oe.name, .{ .bool = false }),
    }
}

/// Free dynamic parts of one option value (tmux `options_value_free`). The
/// value is reset to `.number = 0` afterward.
pub fn options_value_free(oe: ?*const T.OptionsTableEntry, ov: *T.OptionsValue) void {
    _ = oe;
    free_value(ov);
    ov.* = .{ .number = 0 };
}

/// Resolve the table entry for `s` from the parent scope (tmux
/// `options_parent_table_entry`). Returns null if there is no parent or the
/// name is not present upstream.
pub fn options_parent_table_entry(oo: *T.Options, s: []const u8) ?*const T.OptionsTableEntry {
    const p = oo.parent orelse return null;
    if (options_get(p, s) == null) return null;
    return options_table_entry(options_map_name(s));
}

/// Clear every element of an array option by name (tmux `options_array_clear`).
pub fn options_array_clear(oo: *T.Options, name: []const u8) void {
    const v = options_get_only(oo, name) orelse return;
    options_array_clear_value(v);
}

/// Command option as stored text (tmux `options_get_command` / `cmd_list` analogue).
pub fn options_get_command(oo: *T.Options, name: []const u8) []const u8 {
    return options_get_command_string(oo, name);
}

fn parse_i64_bounded(oe: *const T.OptionsTableEntry, text: []const u8, cause: *?[]u8) ?i64 {
    const n = std.fmt.parseInt(i64, text, 10) catch {
        cause.* = xm.xasprintf("invalid number: {s}", .{text});
        return null;
    };
    if (oe.minimum) |lo| {
        if (n < lo) {
            cause.* = xm.xasprintf("value is too small: {s}", .{text});
            return null;
        }
    }
    if (oe.maximum) |hi| {
        if (n > hi) {
            cause.* = xm.xasprintf("value is too large: {s}", .{text});
            return null;
        }
    }
    return n;
}

/// Toggle / set a flag option from a string (tmux `options_from_string_flag`).
pub fn options_from_string_flag(oo: *T.Options, name: []const u8, value: ?[]const u8, cause: *?[]u8) bool {
    const flag: i64 = if (value == null or value.?.len == 0)
        if (options_get_number(oo, name) != 0) 0 else 1
    else if (options_parse_boolish(value)) |b|
        if (b) 1 else 0
    else {
        cause.* = xm.xasprintf("bad value: {s}", .{value.?});
        return false;
    };
    options_set_number(oo, name, flag);
    return true;
}

/// Set a choice option from a string or toggle when value is null (tmux
/// `options_from_string_choice`).
pub fn options_from_string_choice(
    oe: *const T.OptionsTableEntry,
    oo: *T.Options,
    name: []const u8,
    value: ?[]const u8,
    cause: *?[]u8,
) bool {
    const choice: i64 = if (value == null or value.?.len == 0) blk: {
        var cur = options_get_number(oo, name);
        if (cur < 2)
            cur = if (cur != 0) 0 else 1;
        break :blk cur;
    } else blk: {
        const idx = options_find_choice(oe, value.?, cause) orelse return false;
        break :blk @intCast(idx);
    };
    options_set_number(oo, name, choice);
    return true;
}

/// Parse and assign an option from a string (tmux `options_from_string`).
pub fn options_from_string(
    oo: *T.Options,
    oe: ?*const T.OptionsTableEntry,
    name: []const u8,
    value: ?[]const u8,
    append: bool,
    cause: *?[]u8,
) bool {
    if (oe == null) {
        if (name.len == 0 or name[0] != '@') {
            cause.* = xm.xstrdup("bad option name");
            return false;
        }
        if (value == null) {
            cause.* = xm.xstrdup("empty value");
            return false;
        }
        const old = xm.xstrdup(options_get_string(oo, name));
        defer xm.allocator.free(old);
        if (append) {
            const cur = options_get_string(oo, name);
            const combined = xm.xasprintf("{s}{s}", .{ cur, value.? });
            defer xm.allocator.free(combined);
            options_set_string(oo, false, name, combined);
        } else {
            options_set_string(oo, false, name, value.?);
        }
        const new = options_get_string(oo, name);
        if (!options_from_string_check(null, new, cause)) {
            options_set_string(oo, false, name, old);
            return false;
        }
        return true;
    }

    if (value == null and oe.?.type != .flag and oe.?.type != .bool and oe.?.type != .choice) {
        cause.* = xm.xstrdup("empty value");
        return false;
    }

    switch (oe.?.type) {
        .string, .style => {
            const v = value orelse {
                cause.* = xm.xstrdup("empty value");
                return false;
            };
            const old = xm.xstrdup(options_get_string(oo, name));
            defer xm.allocator.free(old);
            if (append) {
                const cur = options_get_string(oo, name);
                const combined = xm.xasprintf("{s}{s}", .{ cur, v });
                defer xm.allocator.free(combined);
                options_set_string(oo, false, name, combined);
            } else {
                options_set_string(oo, false, name, v);
            }
            const new = options_get_string(oo, name);
            if (!options_from_string_check(oe, new, cause)) {
                options_set_string(oo, false, name, old);
                return false;
            }
            return true;
        },
        .number => {
            const v = value orelse {
                cause.* = xm.xstrdup("empty value");
                return false;
            };
            const n = parse_i64_bounded(oe.?, v, cause) orelse return false;
            options_set_number(oo, name, n);
            return true;
        },
        .colour => {
            const v = value orelse {
                cause.* = xm.xstrdup("empty value");
                return false;
            };
            const parsed = colour_mod.colour_fromstring(v);
            if (parsed == -1) {
                cause.* = xm.xasprintf("bad colour: {s}", .{v});
                return false;
            }
            options_set_colour(oo, name, parsed);
            return true;
        },
        .flag, .bool => return options_from_string_flag(oo, name, value, cause),
        .choice => return options_from_string_choice(oe.?, oo, name, value, cause),
        .command => {
            const raw = value orelse {
                cause.* = xm.xstrdup("empty value");
                return false;
            };
            var parse_input = T.CmdParseInput{};
            const pr = cmd_mod.cmd_parse_from_string(raw, &parse_input);
            switch (pr.status) {
                .@"error" => {
                    cause.* = pr.@"error".?;
                    return false;
                },
                .success => {
                    const cl: *cmd_mod.CmdList = @ptrCast(pr.cmdlist.?);
                    cmd_mod.cmd_list_free(cl);
                    options_set_command(oo, name, raw);
                    return true;
                },
            }
        },
        .array => {
            cause.* = xm.xstrdup("wrong option type");
            return false;
        },
    }
}

/// Parse a string option into a style (tmux `options_string_to_style`). Fills
/// `out`; returns false if the option is missing, not a string, or parsing fails.
/// There is no per-entry cache yet; callers should treat `out` as scratch.
pub fn options_string_to_style(
    oo: *T.Options,
    name: []const u8,
    ft: ?*const format_mod.FormatContext,
    out: *T.Style,
) bool {
    const v = options_get(oo, name) orelse return false;
    const s = switch (v.*) {
        .string => |str| str,
        else => return false,
    };
    style_mod.style_set(out, &T.grid_default_cell);
    const needs_expand = std.mem.indexOf(u8, s, "#{") != null;
    if (ft != null and needs_expand) {
        const expanded = format_mod.format_expand(xm.allocator, s, ft.?);
        defer xm.allocator.free(expanded.text);
        return style_mod.style_parse(out, &T.grid_default_cell, expanded.text) == 0;
    }
    return style_mod.style_parse(out, &T.grid_default_cell, s) == 0;
}

// ── Iterator helpers ──────────────────────────────────────────────────────

/// Return a key iterator over all entries in this options set.
pub fn options_key_iterator(oo: *T.Options) std.StringHashMap(T.OptionsValue).KeyIterator {
    return oo.entries.keyIterator();
}

// ── Default-to-string ─────────────────────────────────────────────────────

/// Convert a table entry's default value to a string.
pub fn options_default_to_string(oe: *const T.OptionsTableEntry) []u8 {
    return switch (oe.type) {
        .string, .style, .command => xm.xstrdup(oe.default_str orelse ""),
        .number => xm.xasprintf("{d}", .{oe.default_num}),
        .colour => xm.xstrdup(colour_mod.colour_tostring(@intCast(oe.default_num))),
        .flag, .bool => xm.xstrdup(if (oe.default_num != 0) "on" else "off"),
        .choice => if (oe.choices) |choices|
            if (oe.default_num >= 0 and @as(usize, @intCast(oe.default_num)) < choices.len)
                xm.xstrdup(choices[@intCast(oe.default_num)])
            else
                xm.xasprintf("{d}", .{oe.default_num})
        else
            xm.xasprintf("{d}", .{oe.default_num}),
        .array => xm.xstrdup(oe.default_str orelse ""),
    };
}

// ── Public array API ──────────────────────────────────────────────────────

/// Red-black tree order for array items (tmux `options_array_cmp`).
pub fn options_array_cmp(a1: *const T.OptionsArrayItem, a2: *const T.OptionsArrayItem) i32 {
    if (a1.index < a2.index) return -1;
    if (a1.index > a2.index) return 1;
    return 0;
}

/// Insert a new empty array element at `idx` (tmux `options_array_new`).
/// If an item with that index already exists, returns the existing entry.
pub fn options_array_new(ov: *T.OptionsValue, idx: u32) *T.OptionsArrayItem {
    const arr = switch (ov.*) {
        .array => |*a| a,
        else => unreachable,
    };
    const pos = array_find_position(arr.items, idx);
    if (pos < arr.items.len and arr.items[pos].index == idx)
        return &arr.items[pos];
    const empty = xm.xstrdup("");
    arr.insert(xm.allocator, pos, .{ .index = idx, .value = empty }) catch unreachable;
    return &arr.items[pos];
}

/// Remove one array element and free its value (tmux `options_array_free`).
pub fn options_array_free(ov: *T.OptionsValue, item: *T.OptionsArrayItem) void {
    const arr = switch (ov.*) {
        .array => |*a| a,
        else => unreachable,
    };
    for (arr.items, 0..) |*it, i| {
        if (it == item) {
            xm.allocator.free(it.value);
            _ = arr.orderedRemove(i);
            return;
        }
    }
}

/// Clear all elements from an array option.
pub fn options_array_clear_value(v: *T.OptionsValue) void {
    switch (v.*) {
        .array => |*arr| array_clear(arr),
        else => {},
    }
}

/// Return the first item in an array option value, or null.
pub fn options_array_first(v: *const T.OptionsValue) ?*const T.OptionsArrayItem {
    return switch (v.*) {
        .array => |arr| if (arr.items.len > 0) &arr.items[0] else null,
        else => null,
    };
}

/// Return the next item after `current` in the array, or null.
pub fn options_array_next(v: *const T.OptionsValue, current: *const T.OptionsArrayItem) ?*const T.OptionsArrayItem {
    const items: []const T.OptionsArrayItem = switch (v.*) {
        .array => |arr| arr.items,
        else => return null,
    };
    if (items.len == 0) return null;
    const base = @intFromPtr(&items[0]);
    const cur = @intFromPtr(current);
    if (cur < base) return null;
    const offset = cur - base;
    const size = @sizeOf(T.OptionsArrayItem);
    if (offset % size != 0) return null;
    const idx = offset / size;
    return if (idx + 1 < items.len) &items[idx + 1] else null;
}

/// Get the index of an array item.
pub fn options_array_item_index(a: *const T.OptionsArrayItem) u32 {
    return a.index;
}

/// Get the value of an array item.
pub fn options_array_item_value(a: *const T.OptionsArrayItem) []const u8 {
    return a.value;
}

/// Set or remove an array element in the named option.  When value is null,
/// the element at idx is removed.  Returns true on success.
pub fn options_array_set_entry(
    oo: *T.Options,
    name: []const u8,
    idx: u32,
    value: ?[]const u8,
    append: bool,
    cause: *?[]u8,
) bool {
    const oe = options_table_entry(name);
    if (oe != null and oe.?.type != .array) {
        cause.* = xm.xstrdup("not an array");
        return false;
    }
    const arr = ensure_local_array(oo, name);
    array_set(arr, idx, value, append);
    return true;
}

/// Assign (split by separator) into an array option.  Returns true on success.
pub fn options_array_assign_entry(
    oo: *T.Options,
    name: []const u8,
    value: []const u8,
    cause: *?[]u8,
) bool {
    const oe = options_table_entry(name) orelse {
        cause.* = xm.xstrdup("not an array option");
        return false;
    };
    if (oe.type != .array) {
        cause.* = xm.xstrdup("not an array option");
        return false;
    }
    const arr = ensure_local_array(oo, name);
    array_assign(arr, oe, value);
    return true;
}

// ── Scope resolution ──────────────────────────────────────────────────────

pub const OptionsScopeResult = enum {
    none,
    server,
    session,
    window,
    pane,
};

/// Resolve the option scope from command flags (-s, -w, -p, -g) and
/// the option name.  Returns the scope and sets `oo` to the
/// appropriate options set.  On failure, sets cause and returns `.none`.
pub fn options_scope_from_name(
    args: *const @import("arguments.zig").Arguments,
    window: bool,
    name: []const u8,
    fs: *const T.CmdFindState,
    oo: **T.Options,
    cause: *?[]u8,
) OptionsScopeResult {
    if (name.len > 0 and name[0] == '@')
        return options_scope_from_flags(args, window, fs, oo, cause);

    const entry = blk: {
        for (table.options_table) |*oe| {
            if (std.mem.eql(u8, oe.name, name)) break :blk oe;
        }
        cause.* = xm.xasprintf("unknown option: {s}", .{name});
        return .none;
    };

    if (entry.scope.server) {
        oo.* = global_options;
        return .server;
    }
    if (entry.scope.session) {
        if (args.has('g')) {
            oo.* = global_s_options;
            return .session;
        }
        if (fs.s) |s| {
            oo.* = s.options;
            return .session;
        }
        if (args.get('t')) |target|
            cause.* = xm.xasprintf("no such session: {s}", .{target})
        else
            cause.* = xm.xstrdup("no current session");
        return .none;
    }
    if (entry.scope.window and entry.scope.pane) {
        if (args.has('p')) {
            if (fs.wp) |wp| {
                oo.* = wp.options;
                return .pane;
            }
            if (args.get('t')) |target|
                cause.* = xm.xasprintf("no such pane: {s}", .{target})
            else
                cause.* = xm.xstrdup("no current pane");
            return .none;
        }
    }
    if (entry.scope.window) {
        if (args.has('g')) {
            oo.* = global_w_options;
            return .window;
        }
        if (fs.wl) |wl| {
            oo.* = wl.window.options;
            return .window;
        }
        if (args.get('t')) |target|
            cause.* = xm.xasprintf("no such window: {s}", .{target})
        else
            cause.* = xm.xstrdup("no current window");
        return .none;
    }
    return .none;
}

/// Resolve the option scope purely from command flags (-s, -w, -p, -g),
/// for user @-options or when the option name's scope doesn't matter.
pub fn options_scope_from_flags(
    args: *const @import("arguments.zig").Arguments,
    window_default: bool,
    fs: *const T.CmdFindState,
    oo: **T.Options,
    cause: *?[]u8,
) OptionsScopeResult {
    if (args.has('s')) {
        oo.* = global_options;
        return .server;
    }
    if (args.has('p')) {
        if (fs.wp) |wp| {
            oo.* = wp.options;
            return .pane;
        }
        if (args.get('t')) |target|
            cause.* = xm.xasprintf("no such pane: {s}", .{target})
        else
            cause.* = xm.xstrdup("no current pane");
        return .none;
    }
    if (window_default or args.has('w')) {
        if (args.has('g')) {
            oo.* = global_w_options;
            return .window;
        }
        if (fs.wl) |wl| {
            oo.* = wl.window.options;
            return .window;
        }
        if (args.get('t')) |target|
            cause.* = xm.xasprintf("no such window: {s}", .{target})
        else
            cause.* = xm.xstrdup("no current window");
        return .none;
    }
    if (args.has('g')) {
        oo.* = global_s_options;
        return .session;
    }
    if (fs.s) |s| {
        oo.* = s.options;
        return .session;
    }
    if (args.get('t')) |target|
        cause.* = xm.xasprintf("no such session: {s}", .{target})
    else
        cause.* = xm.xstrdup("no current session");
    return .none;
}

// ── options_push_changes ──────────────────────────────────────────────────

/// Notify all consumers after an option has been changed.
/// Mirrors tmux options_push_changes().
pub fn options_push_changes(name: []const u8) void {
    log.log_debug("options_push_changes: {s}", .{name});

    if (std.mem.eql(u8, name, "automatic-rename")) {
        var wit = win.windows.valueIterator();
        while (wit.next()) |w| {
            if (w.*.active) |pane| {
                pane.flags |= T.PANE_CHANGED;
            }
        }
    }
    if (std.mem.eql(u8, name, "cursor-colour") or
        std.mem.eql(u8, name, "cursor-style"))
    {
        var pit = win.all_window_panes.valueIterator();
        while (pit.next()) |wp| {
            win.window_pane_default_cursor(wp.*);
        }
    }
    if (std.mem.eql(u8, name, "fill-character")) {
        var wit = win.windows.valueIterator();
        while (wit.next()) |w| {
            win.window_set_fill_character(w.*);
        }
    }
    if (std.mem.eql(u8, name, "key-table")) {
        for (client_registry.clients.items) |cl| {
            server_client.server_client_set_key_table(cl, null);
        }
    }
    if (std.mem.eql(u8, name, "user-keys")) {
        for (client_registry.clients.items) |cl| {
            if (cl.tty.flags & @as(i32, @intCast(T.TTY_OPENED)) != 0)
                tty_mod.tty_keys_build(&cl.tty);
        }
    }
    if (std.mem.eql(u8, name, "status") or
        std.mem.eql(u8, name, "status-interval"))
    {
        status_mod.status_timer_start_all();
    }
    if (std.mem.eql(u8, name, "monitor-silence"))
        alerts_mod.alerts_reset_all();
    if (std.mem.eql(u8, name, "window-style") or
        std.mem.eql(u8, name, "window-active-style"))
    {
        var pit = win.all_window_panes.valueIterator();
        while (pit.next()) |wp| {
            wp.*.flags |= (T.PANE_STYLECHANGED | T.PANE_THEMECHANGED);
        }
    }
    if (name.len > 0 and name[0] == '@') {
        var pit = win.all_window_panes.valueIterator();
        while (pit.next()) |wp| {
            wp.*.flags |= T.PANE_STYLECHANGED;
        }
    }
    if (std.mem.eql(u8, name, "pane-colours")) {
        var pit = win.all_window_panes.valueIterator();
        while (pit.next()) |wp| {
            colour_mod.colour_palette_from_option(&wp.*.palette, wp.*.options);
        }
    }
    if (std.mem.eql(u8, name, "pane-scrollbars-style")) {
        var pit = win.all_window_panes.valueIterator();
        while (pit.next()) |wp| {
            style_mod.style_set_scrollbar_style_from_option(&wp.*.scrollbar_style, wp.*.options);
        }
    }
    if (std.mem.eql(u8, name, "codepoint-widths"))
        utf8_mod.utf8_update_width_cache();
    if (std.mem.eql(u8, name, "history-limit")) {
        var sit = sess.sessions.valueIterator();
        while (sit.next()) |s| {
            sess.session_update_history(s.*);
        }
    }
    if (std.mem.eql(u8, name, "input-buffer-size")) {
        const input_mod = @import("input.zig");
        const v = options_get_number(global_options, "input-buffer-size");
        if (v > 0) input_mod.input_set_buffer_size(@intCast(v));
    }

    resize_mod.recalculate_sizes();
    for (client_registry.clients.items) |cl| {
        if (cl.session != null)
            server_fn.server_redraw_client(cl);
    }
}
