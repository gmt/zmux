// Copyright (c) 2026 Greg Turner <gmt@pobox.com>
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
            for (arr.items) |item| xm.allocator.free(item);
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

// ── Typed getters ─────────────────────────────────────────────────────────

/// Get a numeric option value; returns 0 if not found.
pub fn options_get_number(oo: *T.Options, name: []const u8) i64 {
    const v = options_get(oo, name) orelse return 0;
    return switch (v.*) {
        .number => |n| n,
        .@"bool" => |b| if (b) 1 else 0,
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
    put_value(oo, name, .{ .@"bool" = value });
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
    var arr: std.ArrayList([]u8) = .{};
    for (value) |item| arr.append(xm.allocator, xm.xstrdup(item)) catch unreachable;
    return .{ .array = arr };
}

pub fn options_set_array(oo: *T.Options, name: []const u8, items: []const []const u8) void {
    put_value(oo, name, options_clone_array(items));
}

pub fn options_append_array(oo: *T.Options, name: []const u8, item: []const u8) void {
    if (oo.entries.getPtr(name)) |existing| {
        switch (existing.*) {
            .array => |*arr| {
                arr.append(xm.allocator, xm.xstrdup(item)) catch unreachable;
                return;
            },
            else => {},
        }
    }

    if (options_get(oo, name)) |effective| {
        switch (effective.*) {
            .array => |arr| {
                var copy: std.ArrayList([]u8) = .{};
                for (arr.items) |existing_item| copy.append(xm.allocator, xm.xstrdup(existing_item)) catch unreachable;
                copy.append(xm.allocator, xm.xstrdup(item)) catch unreachable;
                put_value(oo, name, .{ .array = copy });
                return;
            },
            else => {},
        }
    }

    options_set_array(oo, name, &.{item});
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

    switch (oe.?.@"type") {
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
        .flag, .@"bool" => {
            const parsed = options_parse_boolish(value) orelse {
                cause.* = xm.xasprintf("invalid flag value: {s}", .{value orelse ""});
                return false;
            };
            options_set_number(oo, name, if (parsed) 1 else 0);
        },
        .choice => {
            const idx = options_choice_index(oe.?, value orelse "") orelse {
                cause.* = xm.xasprintf("invalid choice: {s}", .{value orelse ""});
                return false;
            };
            if (oe.?.choices) |choices| {
                if (idx >= choices.len) {
                    cause.* = xm.xasprintf("invalid choice: {s}", .{value orelse ""});
                    return false;
                }
            }
            options_set_number(oo, name, idx);
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
            if (append) {
                options_append_array(oo, name, value.?);
            } else {
                options_set_array(oo, name, &.{value.?});
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
            switch (entry.@"type") {
                .choice => if (entry.choices) |choices|
                    if (n >= 0 and @as(usize, @intCast(n)) < choices.len) xm.xstrdup(choices[@intCast(n)]) else xm.xasprintf("{d}", .{n})
                else
                    xm.xasprintf("{d}", .{n}),
                .flag, .@"bool" => xm.xstrdup(if (n != 0) "on" else "off"),
                else => xm.xasprintf("{d}", .{n}),
            }
        else
            xm.xasprintf("{d}", .{n}),
        .@"bool" => |b| xm.xstrdup(if (b) "on" else "off"),
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
        .array => |arr| blk: {
            if (arr.items.len == 0) break :blk xm.xstrdup("");
            const joined = std.mem.join(xm.allocator, ",", arr.items) catch unreachable;
            break :blk joined;
        },
        .command => xm.xstrdup(""),
    };
}

// ── Default initialisation (from options table) ───────────────────────────

const table = @import("options-table.zig");

/// Install the default value for one table entry into an options set.
pub fn options_default(oo: *T.Options, oe: *const T.OptionsTableEntry) void {
    switch (oe.@"type") {
        .number, .choice, .colour, .flag => {
            options_set_number(oo, oe.name, oe.default_num);
        },
        .@"bool" => {
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
            // leave array empty; individual entries added via set-option
        },
        .command => {},
    }
    _ = table; // suppress unused import warning until table is referenced
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
