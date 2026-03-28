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

/// Global option tables (see options-table.zig for entries).
/// Set at startup before any session is created.
pub var global_options: *T.Options = undefined;
pub var global_s_options: *T.Options = undefined;
pub var global_w_options: *T.Options = undefined;

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

/// Look up an option that must exist (panics if not found).
pub fn options_get_only(oo: *T.Options, name: []const u8) ?*T.OptionsValue {
    return oo.entries.getPtr(name);
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
    var found: ?*const T.OptionsTableEntry = null;
    for (table.options_table) |*oe| {
        if (std.mem.eql(u8, oe.name, name)) return xm.xstrdup(oe.name);
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
            cause.* = xm.xstrdup("command options not supported yet");
            return false;
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
        .command => xm.xstrdup(""),
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
        .command => {},
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
