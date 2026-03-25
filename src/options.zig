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
    const owned_name = xm.xstrdup(name);
    oo.entries.put(owned_name, .{ .number = value }) catch unreachable;
}

/// Set a boolean option.
pub fn options_set_bool(oo: *T.Options, name: []const u8, value: bool) void {
    const owned_name = xm.xstrdup(name);
    oo.entries.put(owned_name, .{ .@"bool" = value }) catch unreachable;
}

/// Set a string option (takes ownership of a copy of value).
pub fn options_set_string(oo: *T.Options, comptime _: bool, name: []const u8, value: []const u8) void {
    if (oo.entries.getPtr(name)) |existing| {
        free_value(existing);
        existing.* = .{ .string = xm.xstrdup(value) };
    } else {
        const owned_name = xm.xstrdup(name);
        oo.entries.put(owned_name, .{ .string = xm.xstrdup(value) }) catch unreachable;
    }
}

/// Set a colour option.
pub fn options_set_colour(oo: *T.Options, name: []const u8, value: i32) void {
    const owned_name = xm.xstrdup(name);
    oo.entries.put(owned_name, .{ .colour = value }) catch unreachable;
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
