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
const cmd_mod = @import("cmd.zig");
const cmdq_mod = @import("cmd-queue.zig");

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
    seed_default_bindings();
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

pub fn key_bindings_unref_table(table: ?*T.KeyTable) void {
    const actual = table orelse return;
    if (actual.references == 0) return;
    actual.references -= 1;
    if (actual.references != 0) return;

    clear_explicit_table(actual);
    clear_default_table(actual);
    actual.deinit();
    xm.allocator.free(actual.name);
    xm.allocator.destroy(actual);
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

    const binding = alloc_binding(table, masked, note, if (repeat) T.KEY_BINDING_REPEAT else 0, cmdlist, false);
    add_explicit_binding(table, binding);
}

pub fn key_bindings_remove(name: []const u8, key: T.key_code) void {
    const table = key_bindings_get_table(name, false) orelse return;
    const binding = key_bindings_get(table, key) orelse return;
    remove_binding_from_table(table, binding);
    maybe_remove_empty_table(table);
}

pub fn key_bindings_reset(name: []const u8, key: T.key_code) void {
    const table = key_bindings_get_table(name, false) orelse return;
    const binding = key_bindings_get(table, key) orelse return;
    const default_binding = key_bindings_get_default(table, key) orelse {
        remove_binding_from_table(table, binding);
        maybe_remove_empty_table(table);
        return;
    };
    restore_binding_from_default(binding, default_binding);
}

pub fn key_bindings_remove_table(name: []const u8) void {
    const table = key_bindings_get_table(name, false) orelse return;
    remove_table_from_registry(table);
}

pub fn key_bindings_reset_table(name: []const u8) void {
    const table = key_bindings_get_table(name, false) orelse return;
    if (table.default_order.items.len == 0) {
        remove_table_from_registry(table);
        return;
    }
    clear_explicit_table(table);
    restore_all_defaults(table);
}

pub fn key_bindings_has_repeat(bindings: []const *T.KeyBinding) i32 {
    for (bindings) |binding| {
        if (binding.flags & T.KEY_BINDING_REPEAT != 0) return 1;
    }
    return 0;
}

pub fn key_bindings_dispatch(
    binding: *T.KeyBinding,
    item: ?*T.CmdqItem,
    client: ?*T.Client,
    event: ?*anyopaque,
    fs: ?*T.CmdFindState,
) ?*T.CmdqItem {
    _ = event;
    _ = fs;
    if (binding.cmdlist) |list| {
        cmdq_mod.cmdq_append(client, @ptrCast(@alignCast(cmd_mod.cmd_list_ref(list))));
    }
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
        table.references = 1;
        key_bindings_unref_table(table);
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

fn add_explicit_binding(table: *T.KeyTable, binding: *T.KeyBinding) void {
    table.key_bindings.put(binding.key, binding) catch unreachable;
    table.order.append(xm.allocator, binding) catch unreachable;
}

fn add_default_binding(table: *T.KeyTable, binding: *T.KeyBinding) void {
    table.default_key_bindings.put(binding.key, binding) catch unreachable;
    table.default_order.append(xm.allocator, binding) catch unreachable;
}

fn alloc_binding(
    table: *T.KeyTable,
    key: T.key_code,
    note: ?[]const u8,
    flags: u32,
    cmdlist: ?*T.CmdList,
    retain_cmdlist: bool,
) *T.KeyBinding {
    const binding = xm.allocator.create(T.KeyBinding) catch unreachable;
    binding.* = .{
        .key = key,
        .tablename = table.name,
        .note = if (note) |n| xm.xstrdup(n) else null,
        .flags = flags,
        .cmdlist = if (cmdlist) |list|
            if (retain_cmdlist) cmd_mod.cmd_list_ref(list) else list
        else
            null,
    };
    return binding;
}

fn clone_default_from_explicit(table: *T.KeyTable, binding: *T.KeyBinding) void {
    const clone = alloc_binding(table, binding.key, binding.note, binding.flags, binding.cmdlist, true);
    add_default_binding(table, clone);
}

fn restore_binding_from_default(binding: *T.KeyBinding, default_binding: *T.KeyBinding) void {
    if (binding.cmdlist) |list| cmd_mod.cmd_list_unref(list);
    binding.cmdlist = if (default_binding.cmdlist) |list| cmd_mod.cmd_list_ref(list) else null;

    if (binding.note) |note| xm.allocator.free(note);
    binding.note = if (default_binding.note) |note| xm.xstrdup(note) else null;
    binding.flags = default_binding.flags;
}

fn restore_all_defaults(table: *T.KeyTable) void {
    for (table.default_order.items) |default_binding| {
        const restored = alloc_binding(table, default_binding.key, default_binding.note, default_binding.flags, default_binding.cmdlist, true);
        add_explicit_binding(table, restored);
    }
}

fn maybe_remove_empty_table(table: *T.KeyTable) void {
    if (table.order.items.len != 0) return;
    if (table.default_order.items.len != 0) return;
    remove_table_from_registry(table);
}

fn remove_table_from_registry(table: *T.KeyTable) void {
    _ = key_tables.remove(table.name);
    for (key_table_order.items, 0..) |current, idx| {
        if (current != table) continue;
        _ = key_table_order.orderedRemove(idx);
        break;
    }
    key_bindings_unref_table(table);
}

fn free_binding(binding: *T.KeyBinding) void {
    if (binding.cmdlist) |list| cmd_mod.cmd_list_unref(list);
    if (binding.note) |note| xm.allocator.free(note);
    xm.allocator.destroy(binding);
}

const DefaultBindingSpec = struct {
    table: []const u8,
    key: T.key_code,
    note: []const u8,
    repeat: bool = false,
    argv: []const []const u8,
};

const default_list_keys_argv = [_][]const u8{ "list-keys", "-N" };
const default_new_window_argv = [_][]const u8{ "new-window" };
const default_display_message_argv = [_][]const u8{ "display-message" };
const default_refresh_client_argv = [_][]const u8{ "refresh-client" };

const default_binding_specs = [_]DefaultBindingSpec{
    .{
        .table = "prefix",
        .key = '?',
        .note = "List key bindings",
        .argv = default_list_keys_argv[0..],
    },
    .{
        .table = "prefix",
        .key = 'c',
        .note = "Create a new window",
        .argv = default_new_window_argv[0..],
    },
    .{
        .table = "prefix",
        .key = 'i',
        .note = "Display window information",
        .argv = default_display_message_argv[0..],
    },
    .{
        .table = "prefix",
        .key = 'r',
        .note = "Redraw the current client",
        .argv = default_refresh_client_argv[0..],
    },
};

fn seed_default_bindings() void {
    for (default_binding_specs) |spec| install_default_binding(spec);
    var idx: u8 = 0;
    while (idx <= 9) : (idx += 1) {
        install_select_window_default(idx);
    }
}

fn install_default_binding(spec: DefaultBindingSpec) void {
    const table = key_bindings_get_table(spec.table, true).?;
    const parsed = cmd_mod.cmd_parse_from_argv(spec.argv, null) catch unreachable;
    const explicit = alloc_binding(table, maskedKey(spec.key), spec.note, if (spec.repeat) T.KEY_BINDING_REPEAT else 0, @ptrCast(parsed), false);
    add_explicit_binding(table, explicit);
    clone_default_from_explicit(table, explicit);
}

fn install_select_window_default(idx: u8) void {
    const key_buf: [1]u8 = .{idx + '0'};
    const target_buf: [3]u8 = .{ ':', '=', idx + '0' };
    const note = xm.xasprintf("Select window {d}", .{idx});
    defer xm.allocator.free(note);
    const argv = [_][]const u8{ "select-window", target_buf[0..] };
    const spec = DefaultBindingSpec{
        .table = "prefix",
        .key = key_buf[0],
        .note = note,
        .argv = argv[0..],
    };
    install_default_binding(spec);
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
    try std.testing.expect(key_bindings_get_table("root", false) == null);
}

test "key bindings init seeds prefix defaults and keeps root empty" {
    key_bindings_init();

    const prefix = key_bindings_get_table("prefix", false).?;
    const root = key_bindings_get_table("root", false).?;
    try std.testing.expect(root.order.items.len == 0);
    try std.testing.expect(prefix.order.items.len >= 14);
    try std.testing.expect(key_bindings_get_default(prefix, '?') != null);
    try std.testing.expect(key_bindings_get(prefix, '?') != null);
}

test "key bindings reset restores built in defaults" {
    key_bindings_init();

    const prefix = key_bindings_get_table("prefix", false).?;
    const question = key_bindings_get(prefix, '?').?;
    const original_cmdlist = question.cmdlist.?;

    key_bindings_add("prefix", '?', "override", false, null);
    key_bindings_reset("prefix", '?');

    const reset_question = key_bindings_get(prefix, '?').?;
    try std.testing.expectEqualStrings("List key bindings", reset_question.note.?);
    try std.testing.expect(reset_question.cmdlist == original_cmdlist);
}

test "key bindings reset table restores default prefix set" {
    key_bindings_init();

    const prefix = key_bindings_get_table("prefix", false).?;
    const original_count = prefix.order.items.len;
    key_bindings_remove("prefix", '?');
    key_bindings_add("prefix", 'x', "temporary", false, null);
    key_bindings_reset_table("prefix");
    const restored = key_bindings_get_table("prefix", false).?;
    try std.testing.expectEqual(original_count, restored.order.items.len);
    try std.testing.expect(key_bindings_get(restored, '?') != null);
    try std.testing.expect(key_bindings_get(restored, 'x') == null);
}

test "key bindings remove table removes prefix entirely" {
    key_bindings_init();
    key_bindings_remove_table("prefix");
    try std.testing.expect(key_bindings_get_table("prefix", false) == null);
}

test "key bindings retain shared cmdlists across default restores" {
    key_bindings_init();

    const prefix = key_bindings_get_table("prefix", false).?;
    const question = key_bindings_get(prefix, '?').?;
    const list: *cmd_mod.CmdList = @ptrCast(@alignCast(question.cmdlist.?));
    try std.testing.expectEqual(@as(u32, 2), list.references);

    key_bindings_remove("prefix", '?');
    try std.testing.expectEqual(@as(u32, 1), list.references);

    key_bindings_reset_table("prefix");
    try std.testing.expectEqual(@as(u32, 2), list.references);
}
