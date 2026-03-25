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
// Ported from tmux/key-bindings.c
// Original copyright:
//   Copyright (c) 2007 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const log = @import("log.zig");

var key_tables: std.StringHashMap(*T.KeyTable) = undefined;
var key_table_order: std.ArrayList(*T.KeyTable) = .{};
var ready = false;

pub fn key_bindings_init() void {
    clear_all();
    key_tables = std.StringHashMap(*T.KeyTable).init(xm.allocator);
    key_table_order = .{};
    ready = true;

    _ = key_bindings_get_table("root", true);
    _ = key_bindings_get_table("prefix", true);
    log.log_debug("key_bindings_init", .{});
}

pub fn key_bindings_get_table(name: []const u8, create: bool) ?*T.KeyTable {
    ensure_ready();
    if (key_tables.get(name)) |table| return table;
    if (!create) return null;

    const table = xm.allocator.create(T.KeyTable) catch unreachable;
    table.* = T.KeyTable.init(xm.allocator, xm.xstrdup(name));
    key_tables.put(table.name, table) catch unreachable;
    key_table_order.append(xm.allocator, table) catch unreachable;
    return table;
}

pub fn key_bindings_first_table() ?*T.KeyTable {
    ensure_ready();
    if (key_table_order.items.len == 0) return null;
    return key_table_order.items[0];
}

pub fn key_bindings_next_table(table: *T.KeyTable) ?*T.KeyTable {
    ensure_ready();
    for (key_table_order.items, 0..) |current, idx| {
        if (current != table) continue;
        if (idx + 1 >= key_table_order.items.len) return null;
        return key_table_order.items[idx + 1];
    }
    return null;
}

pub fn key_bindings_unref_table(_table: ?*T.KeyTable) void {
    _ = _table;
}

pub fn key_bindings_get(table: *T.KeyTable, key: T.key_code) ?*T.KeyBinding {
    return table.key_bindings.get(maskedKey(key));
}

pub fn key_bindings_get_default(table: *T.KeyTable, key: T.key_code) ?*T.KeyBinding {
    return table.default_key_bindings.get(maskedKey(key));
}

pub fn key_bindings_first(table: *T.KeyTable) ?*T.KeyBinding {
    if (table.order.items.len == 0) return null;
    return table.order.items[0];
}

pub fn key_bindings_next(table: *T.KeyTable, bd: *T.KeyBinding) ?*T.KeyBinding {
    for (table.order.items, 0..) |current, idx| {
        if (current != bd) continue;
        if (idx + 1 >= table.order.items.len) return null;
        return table.order.items[idx + 1];
    }
    return null;
}

pub fn key_bindings_add(name: []const u8, key: T.key_code, note: ?[]const u8, repeat: bool, cmdlist: ?*T.CmdList) void {
    const table = key_bindings_get_table(name, true).?;
    const masked = maskedKey(key);

    if (cmdlist == null) {
        if (key_bindings_get(table, masked)) |existing| {
            if (note) |new_note| {
                if (existing.note) |old_note| xm.allocator.free(old_note);
                existing.note = xm.xstrdup(new_note);
            }
            if (repeat) existing.flags |= T.KEY_BINDING_REPEAT;
            return;
        }
    } else if (key_bindings_get(table, masked)) |existing| {
        remove_binding_from_table(table, existing);
    }

    const binding = xm.allocator.create(T.KeyBinding) catch unreachable;
    binding.* = .{
        .key = masked,
        .tablename = table.name,
        .note = if (note) |n| xm.xstrdup(n) else null,
        .flags = if (repeat) T.KEY_BINDING_REPEAT else 0,
        .cmdlist = cmdlist,
    };

    table.key_bindings.put(masked, binding) catch unreachable;
    table.order.append(xm.allocator, binding) catch unreachable;
}

pub fn key_bindings_remove(name: []const u8, key: T.key_code) void {
    const table = key_bindings_get_table(name, false) orelse return;
    const binding = key_bindings_get(table, key) orelse return;
    remove_binding_from_table(table, binding);
}

pub fn key_bindings_reset(name: []const u8, key: T.key_code) void {
    const table = key_bindings_get_table(name, false) orelse return;
    const binding = key_bindings_get(table, key) orelse return;
    remove_binding_from_table(table, binding);
}

pub fn key_bindings_remove_table(name: []const u8) void {
    const table = key_bindings_get_table(name, false) orelse return;
    clear_explicit_table(table);
}

pub fn key_bindings_reset_table(name: []const u8) void {
    const table = key_bindings_get_table(name, false) orelse return;
    clear_explicit_table(table);
}

pub fn key_bindings_has_repeat(bindings: []const *T.KeyBinding) i32 {
    for (bindings) |binding| {
        if (binding.flags & T.KEY_BINDING_REPEAT != 0) return 1;
    }
    return 0;
}

pub fn key_bindings_dispatch(
    _binding: *T.KeyBinding,
    item: ?*T.CmdqItem,
    _client: ?*T.Client,
    _event: ?*anyopaque,
    _fs: ?*T.CmdFindState,
) ?*T.CmdqItem {
    _ = _binding;
    _ = _client;
    _ = _event;
    _ = _fs;
    return item;
}

fn ensure_ready() void {
    if (!ready) key_bindings_init();
}

fn maskedKey(key: T.key_code) T.key_code {
    return key & ~T.KEYC_MASK_FLAGS;
}

fn clear_all() void {
    if (!ready) return;
    for (key_table_order.items) |table| {
        clear_explicit_table(table);
        clear_default_table(table);
        table.deinit();
        xm.allocator.free(table.name);
        xm.allocator.destroy(table);
    }
    key_table_order.deinit(xm.allocator);
    key_tables.deinit();
    ready = false;
}

fn clear_explicit_table(table: *T.KeyTable) void {
    while (table.order.items.len > 0) {
        const binding = table.order.items[table.order.items.len - 1];
        remove_binding_from_table(table, binding);
    }
}

fn clear_default_table(table: *T.KeyTable) void {
    while (table.default_order.items.len > 0) {
        const binding = table.default_order.items[table.default_order.items.len - 1];
        _ = table.default_key_bindings.remove(binding.key);
        _ = table.default_order.pop();
        free_binding(binding);
    }
}

fn remove_binding_from_table(table: *T.KeyTable, binding: *T.KeyBinding) void {
    _ = table.key_bindings.remove(binding.key);
    for (table.order.items, 0..) |current, idx| {
        if (current != binding) continue;
        _ = table.order.orderedRemove(idx);
        break;
    }
    free_binding(binding);
}

fn free_binding(binding: *T.KeyBinding) void {
    if (binding.note) |note| xm.allocator.free(note);
    xm.allocator.destroy(binding);
}

test "key_bindings_init creates root and prefix tables" {
    key_bindings_init();

    try std.testing.expect(key_bindings_get_table("root", false) != null);
    try std.testing.expect(key_bindings_get_table("prefix", false) != null);
    try std.testing.expectEqualStrings("root", key_bindings_first_table().?.name);
    try std.testing.expectEqualStrings("prefix", key_bindings_next_table(key_bindings_first_table().?).?.name);
}

test "key bindings add remove reset and iteration" {
    key_bindings_init();

    key_bindings_add("root", 'a', "alpha", true, null);
    key_bindings_add("root", 'b', null, false, null);

    const root = key_bindings_get_table("root", false).?;
    const a = key_bindings_get(root, 'a').?;
    const b = key_bindings_get(root, 'b').?;
    try std.testing.expectEqualStrings("alpha", a.note.?);
    try std.testing.expect(a.flags & T.KEY_BINDING_REPEAT != 0);
    try std.testing.expectEqual(@as(i32, 1), key_bindings_has_repeat(&.{ a, b }));
    try std.testing.expect(key_bindings_first(root) == a);
    try std.testing.expect(key_bindings_next(root, a) == b);

    key_bindings_remove("root", 'a');
    try std.testing.expect(key_bindings_get(root, 'a') == null);

    key_bindings_reset("root", 'b');
    try std.testing.expect(key_bindings_get(root, 'b') == null);
}

test "key bindings remove and reset table leave shell intact" {
    key_bindings_init();

    key_bindings_add("prefix", 'x', null, false, null);
    key_bindings_add("prefix", 'y', null, false, null);
    key_bindings_remove_table("prefix");

    const prefix = key_bindings_get_table("prefix", false).?;
    try std.testing.expect(prefix.order.items.len == 0);

    key_bindings_add("prefix", 'z', null, false, null);
    key_bindings_reset_table("prefix");
    try std.testing.expect(prefix.order.items.len == 0);
    try std.testing.expectEqualStrings("prefix", prefix.name);
}
