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
const client_registry = @import("client-registry.zig");
const key_string = @import("key-string.zig");

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
    insert_table_in_order(table);
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
    remove_table_from_registry(table, true);
}

pub fn key_bindings_reset_table(name: []const u8) void {
    const table = key_bindings_get_table(name, false) orelse return;
    if (table.default_order.items.len == 0) {
        remove_table_from_registry(table, true);
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

fn key_bindings_read_only(item: *cmdq_mod.CmdqItem, _: ?*anyopaque) T.CmdRetval {
    cmdq_mod.cmdq_error(item, "client is read-only", .{});
    return .@"error";
}

pub fn key_bindings_dispatch(
    binding: *T.KeyBinding,
    item: ?*T.CmdqItem,
    client: ?*T.Client,
    event: ?*const T.key_event,
    fs: ?*T.CmdFindState,
) ?*T.CmdqItem {
    if (binding.cmdlist) |list| {
        const allowed =
            client == null or
            (client.?.flags & T.CLIENT_READONLY == 0) or
            cmd_mod.cmd_list_all_have(list, T.CMD_READONLY);

        var new_item: *cmdq_mod.CmdqItem = if (allowed) blk: {
            const state_flags: u32 = if (binding.flags & T.KEY_BINDING_REPEAT != 0) T.CMDQ_STATE_REPEAT else 0;
            const state = cmdq_mod.cmdq_new_state(fs, event, state_flags);
            defer cmdq_mod.cmdq_free_state(state);
            break :blk cmdq_mod.cmdq_get_command(cmd_mod.cmd_list_ref(list), state);
        } else cmdq_mod.cmdq_get_callback1("key-bindings-read-only", key_bindings_read_only, null);

        if (item) |after| {
            return @ptrCast(cmdq_mod.cmdq_insert_after(@ptrCast(@alignCast(after)), new_item));
        }
        new_item = cmdq_mod.cmdq_append_item(client, new_item);
        return @ptrCast(new_item);
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
    remove_table_from_registry(table, false);
}

fn remove_table_from_registry(table: *T.KeyTable, reset_clients: bool) void {
    _ = key_tables.remove(table.name);
    for (key_table_order.items, 0..) |current, idx| {
        if (current != table) continue;
        _ = key_table_order.orderedRemove(idx);
        break;
    }
    if (reset_clients) reset_clients_for_removed_table(table.name);
    key_bindings_unref_table(table);
}

fn insert_table_in_order(table: *T.KeyTable) void {
    for (key_table_order.items, 0..) |current, idx| {
        if (std.mem.order(u8, table.name, current.name) != .lt) continue;
        key_table_order.insert(xm.allocator, idx, table) catch unreachable;
        return;
    }
    key_table_order.append(xm.allocator, table) catch unreachable;
}

fn reset_clients_for_removed_table(name: []const u8) void {
    for (client_registry.clients.items) |cl| {
        const current_name = cl.key_table_name orelse continue;
        if (!std.mem.eql(u8, current_name, name)) continue;
        xm.allocator.free(current_name);
        cl.key_table_name = null;
    }
}

fn free_binding(binding: *T.KeyBinding) void {
    key_bindings_free(binding);
}

/// Free a single key binding, releasing its command list and note.
/// Zig port of tmux key_bindings_free().
pub fn key_bindings_free(binding: *T.KeyBinding) void {
    if (binding.cmdlist) |list| cmd_mod.cmd_list_unref(list);
    if (binding.note) |note| xm.allocator.free(note);
    xm.allocator.destroy(binding);
}

/// Snapshot all current explicit bindings into default_key_bindings
/// for every table, so user changes can later be distinguished from
/// built-in defaults.  Zig port of tmux key_bindings_init_done().
pub fn key_bindings_init_done() void {
    ensure_ready();
    for (key_table_order.items) |table| {
        for (table.order.items) |bd| {
            if (table.default_key_bindings.get(bd.key) != null) continue;
            clone_default_from_explicit(table, bd);
        }
    }
}

/// Compare two key bindings by key code, returning standard ordering.
/// Zig port of tmux key_bindings_cmp().
pub fn key_bindings_cmp(a: *const T.KeyBinding, b: *const T.KeyBinding) std.math.Order {
    return std.math.order(a.key, b.key);
}

/// Compare two key tables by name, returning standard ordering.
/// Zig port of tmux key_table_cmp().
pub fn key_table_cmp(a: *const T.KeyTable, b: *const T.KeyTable) std.math.Order {
    return std.mem.order(u8, a.name, b.name);
}

const key_bindings_data = @import("key-bindings-data.zig");
const DefaultBindingSpec = key_bindings_data.DefaultBindingSpec;
const default_binding_specs = key_bindings_data.default_binding_specs;

fn seed_default_bindings() void {
    for (default_binding_specs) |spec| install_default_binding(spec);
    var idx: u8 = 0;
    while (idx <= 9) : (idx += 1) {
        install_select_window_default(idx);
    }
}

fn install_default_binding(spec: DefaultBindingSpec) void {
    const table = key_bindings_get_table(spec.table, true).?;
    const key = if (spec.key_name) |name| parse_default_binding_key(name) else maskedKey(spec.key);
    const parsed = parse_default_binding_cmdlist(spec);
    const explicit = alloc_binding(table, key, spec.note, if (spec.repeat) T.KEY_BINDING_REPEAT else 0, parsed, false);
    add_explicit_binding(table, explicit);
    clone_default_from_explicit(table, explicit);
}

fn parse_default_binding_key(name: []const u8) T.key_code {
    const key = key_string.key_string_lookup_string(name);
    if (key == T.KEYC_UNKNOWN or key == T.KEYC_NONE)
        @panic("bad default binding key");
    return maskedKey(key);
}

fn parse_default_binding_cmdlist(spec: DefaultBindingSpec) *T.CmdList {
    if (spec.argv) |argv| return @ptrCast(cmd_mod.cmd_parse_from_argv(argv, null) catch unreachable);
    if (spec.command) |text| {
        var input: T.CmdParseInput = .{};
        const parsed = cmd_mod.cmd_parse_from_string(text, &input);
        switch (parsed.status) {
            .success => return @ptrCast(@alignCast(parsed.cmdlist.?)),
            .@"error" => {
                if (parsed.@"error") |err| xm.allocator.free(err);
                std.debug.panic("bad default binding command: {s}", .{text});
            },
        }
    }
    @panic("missing default binding command");
}

fn install_select_window_default(idx: u8) void {
    const key_buf: [1]u8 = .{idx + '0'};
    const target_buf: [3]u8 = .{ ':', '=', idx + '0' };
    const note = xm.xasprintf("Select window {d}", .{idx});
    defer xm.allocator.free(note);
    const argv = [_][]const u8{ "select-window", "-t", target_buf[0..] };
    const spec = DefaultBindingSpec{
        .table = "prefix",
        .key = key_buf[0],
        .note = note,
        .argv = argv[0..],
    };
    install_default_binding(spec);
}

fn binding_cmdlist(binding: *T.KeyBinding) *cmd_mod.CmdList {
    return @ptrCast(@alignCast(binding.cmdlist.?));
}

fn cmdlist_len(list: *cmd_mod.CmdList) usize {
    var count: usize = 0;
    var cmd = list.head;
    while (cmd) |current| : (cmd = current.next) {
        count += 1;
    }
    return count;
}

fn cmdlist_nth(list: *cmd_mod.CmdList, idx: usize) *cmd_mod.Cmd {
    var cmd = list.head orelse unreachable;
    var i: usize = 0;
    while (i < idx) : (i += 1) {
        cmd = cmd.next orelse unreachable;
    }
    return cmd;
}

test "key_bindings_init creates root and prefix tables" {
    key_bindings_init();

    try std.testing.expect(key_bindings_get_table("root", false) != null);
    try std.testing.expect(key_bindings_get_table("prefix", false) != null);

    var saw_root = false;
    var saw_prefix = false;
    var table = key_bindings_first_table();
    while (table) |current| : (table = key_bindings_next_table(current)) {
        if (std.mem.eql(u8, current.name, "root")) saw_root = true;
        if (std.mem.eql(u8, current.name, "prefix")) saw_prefix = true;
    }
    try std.testing.expect(saw_root);
    try std.testing.expect(saw_prefix);
}

test "key bindings tables iterate in tmux name order" {
    key_bindings_init();

    _ = key_bindings_get_table("aaa-custom", true);
    _ = key_bindings_get_table("zzz-custom", true);

    var table = key_bindings_first_table();
    var saw_first = false;
    var saw_last = false;
    var previous_name: ?[]const u8 = null;
    while (table) |current| : (table = key_bindings_next_table(current)) {
        if (previous_name) |previous|
            try std.testing.expect(std.mem.order(u8, previous, current.name) == .lt);
        if (std.mem.eql(u8, current.name, "aaa-custom")) saw_first = true;
        if (std.mem.eql(u8, current.name, "zzz-custom")) saw_last = true;
        previous_name = current.name;
    }
    try std.testing.expect(saw_first);
    try std.testing.expect(saw_last);
}

test "key bindings add remove reset and iteration" {
    key_bindings_init();

    key_bindings_add("transient-test", 'a', "alpha", true, null);
    key_bindings_add("transient-test", 'b', null, false, null);

    const root = key_bindings_get_table("transient-test", false).?;
    const a = key_bindings_get(root, 'a').?;
    const b = key_bindings_get(root, 'b').?;
    try std.testing.expectEqualStrings("alpha", a.note.?);
    try std.testing.expect(a.flags & T.KEY_BINDING_REPEAT != 0);
    try std.testing.expectEqual(@as(i32, 1), key_bindings_has_repeat(&.{ a, b }));
    try std.testing.expect(key_bindings_first(root) == a);
    try std.testing.expect(key_bindings_next(root, a) == b);

    key_bindings_remove("transient-test", 'a');
    try std.testing.expect(key_bindings_get(root, 'a') == null);

    key_bindings_reset("transient-test", 'b');
    try std.testing.expect(key_bindings_get_table("transient-test", false) == null);
}

test "key bindings init seeds prefix menu defaults and root menu mouse defaults" {
    key_bindings_init();

    const prefix = key_bindings_get_table("prefix", false).?;
    const root = key_bindings_get_table("root", false).?;
    try std.testing.expectEqual(@as(usize, 87), prefix.order.items.len);
    try std.testing.expectEqual(@as(usize, 21), root.order.items.len);
    try std.testing.expect(key_bindings_get_default(prefix, '?') != null);
    try std.testing.expect(key_bindings_get(prefix, '?') != null);

    const send_prefix = key_bindings_get(prefix, key_string.key_string_lookup_string("C-b")).?;
    try std.testing.expectEqualStrings("Send the prefix key", send_prefix.note.?);
    try std.testing.expectEqualStrings("send-prefix", cmdlist_nth(binding_cmdlist(send_prefix), 0).entry.name);

    const kill_window = key_bindings_get(prefix, '&').?;
    try std.testing.expectEqualStrings("Kill current window", kill_window.note.?);
    const kill_window_cmd = cmdlist_nth(binding_cmdlist(kill_window), 0);
    try std.testing.expectEqualStrings("confirm-before", kill_window_cmd.entry.name);
    try std.testing.expectEqualStrings("kill-window #W? (y/n)", cmd_mod.cmd_get_args(kill_window_cmd).get('p').?);

    const last_window = key_bindings_get(prefix, 'l').?;
    try std.testing.expectEqualStrings("last-window", cmdlist_nth(binding_cmdlist(last_window), 0).entry.name);

    const alert_next = key_bindings_get(prefix, key_string.key_string_lookup_string("M-n")).?;
    const alert_next_cmd = cmdlist_nth(binding_cmdlist(alert_next), 0);
    try std.testing.expectEqualStrings("next-window", alert_next_cmd.entry.name);
    try std.testing.expect(cmd_mod.cmd_get_args(alert_next_cmd).has('a'));

    const shifted_left = key_bindings_get(prefix, key_string.key_string_lookup_string("S-Left")).?;
    try std.testing.expect(shifted_left.flags & T.KEY_BINDING_REPEAT != 0);
    const shifted_left_cmd = cmdlist_nth(binding_cmdlist(shifted_left), 0);
    try std.testing.expectEqualStrings("refresh-client", shifted_left_cmd.entry.name);
    try std.testing.expectEqualStrings("10", cmd_mod.cmd_get_args(shifted_left_cmd).value_at(0).?);

    const resize_up = key_bindings_get(prefix, key_string.key_string_lookup_string("C-Up")).?;
    try std.testing.expect(resize_up.flags & T.KEY_BINDING_REPEAT != 0);
    try std.testing.expectEqualStrings("resize-pane", cmdlist_nth(binding_cmdlist(resize_up), 0).entry.name);

    const window_menu = key_bindings_get(prefix, '<').?;
    try std.testing.expectEqualStrings("Display window menu", window_menu.note.?);
    try std.testing.expectEqualStrings("display-menu", cmdlist_nth(binding_cmdlist(window_menu), 0).entry.name);
    const window_menu_args = cmd_mod.cmd_get_args(cmdlist_nth(binding_cmdlist(window_menu), 0));
    try std.testing.expectEqualStrings("W", window_menu_args.get('x').?);
    try std.testing.expectEqualStrings("W", window_menu_args.get('y').?);
    try std.testing.expectEqualStrings("#[align=centre]#{window_index}:#{window_name}", window_menu_args.get('T').?);
    try std.testing.expectEqualStrings("#{?#{>:#{session_windows},1},,-}Swap Left", window_menu_args.value_at(0).?);

    const pane_menu = key_bindings_get(prefix, '>').?;
    try std.testing.expectEqualStrings("Display pane menu", pane_menu.note.?);
    try std.testing.expectEqualStrings("display-menu", cmdlist_nth(binding_cmdlist(pane_menu), 0).entry.name);

    const status_click = key_bindings_get(root, key_string.key_string_lookup_string("MouseDown1Status")).?;
    const status_click_cmd = cmdlist_nth(binding_cmdlist(status_click), 0);
    try std.testing.expectEqualStrings("switch-client", status_click_cmd.entry.name);
    try std.testing.expectEqualStrings("=", cmd_mod.cmd_get_args(status_click_cmd).get('t').?);

    const pane_context = key_bindings_get(root, key_string.key_string_lookup_string("MouseDown3Pane")).?;
    const pane_context_cmd = cmdlist_nth(binding_cmdlist(pane_context), 0);
    const pane_context_args = cmd_mod.cmd_get_args(pane_context_cmd);
    try std.testing.expectEqualStrings("if-shell", pane_context_cmd.entry.name);
    try std.testing.expect(pane_context_args.has('F'));
    try std.testing.expectEqualStrings("=", pane_context_args.get('t').?);
    try std.testing.expectEqualStrings("#{||:#{mouse_any_flag},#{&&:#{pane_in_mode},#{?#{m/r:(copy|view)-mode,#{pane_mode}},0,1}}}", pane_context_args.value_at(0).?);

    const scrollbar_drag = key_bindings_get(root, key_string.key_string_lookup_string("MouseDrag1ScrollbarSlider")).?;
    const scrollbar_drag_cmd = cmdlist_nth(binding_cmdlist(scrollbar_drag), 0);
    try std.testing.expectEqualStrings("if-shell", scrollbar_drag_cmd.entry.name);
    try std.testing.expectEqualStrings("#{pane_in_mode}", cmd_mod.cmd_get_args(scrollbar_drag_cmd).value_at(0).?);
}

test "key bindings init seeds full copy-mode default tables" {
    key_bindings_init();

    const copy = key_bindings_get_table("copy-mode", false).?;
    const copy_vi = key_bindings_get_table("copy-mode-vi", false).?;
    try std.testing.expectEqual(@as(usize, 74), copy.order.items.len);
    try std.testing.expectEqual(@as(usize, 87), copy_vi.order.items.len);

    const incremental = key_bindings_get(copy, key_string.key_string_lookup_string("C-r")).?;
    try std.testing.expect(incremental.note == null);
    const incremental_list = binding_cmdlist(incremental);
    try std.testing.expectEqual(@as(usize, 1), cmdlist_len(incremental_list));
    const incremental_cmd = cmdlist_nth(incremental_list, 0);
    try std.testing.expectEqualStrings("command-prompt", incremental_cmd.entry.name);
    const incremental_args = cmd_mod.cmd_get_args(incremental_cmd);
    try std.testing.expect(incremental_args.has('i'));
    try std.testing.expectEqualStrings("search", incremental_args.get('T').?);
    try std.testing.expectEqualStrings("(search up)", incremental_args.get('p').?);
    try std.testing.expectEqualStrings("#{pane_search_string}", incremental_args.get('I').?);
    try std.testing.expectEqualStrings("send -X search-backward-incremental -- '%%'", incremental_args.value_at(0).?);

    const repeat = key_bindings_get(copy, key_string.key_string_lookup_string("M-1")).?;
    const repeat_cmd = cmdlist_nth(binding_cmdlist(repeat), 0);
    const repeat_args = cmd_mod.cmd_get_args(repeat_cmd);
    try std.testing.expect(repeat_args.has('N'));
    try std.testing.expectEqualStrings("(repeat)", repeat_args.get('p').?);
    try std.testing.expectEqualStrings("1", repeat_args.get('I').?);
    try std.testing.expectEqualStrings("send -N '%%'", repeat_args.value_at(0).?);

    const double_click = key_bindings_get(copy, key_string.key_string_lookup_string("DoubleClick1Pane")).?;
    const double_click_list = binding_cmdlist(double_click);
    try std.testing.expectEqual(@as(usize, 4), cmdlist_len(double_click_list));
    try std.testing.expectEqualStrings("select-pane", cmdlist_nth(double_click_list, 0).entry.name);
    try std.testing.expectEqualStrings("send-keys", cmdlist_nth(double_click_list, 1).entry.name);
    try std.testing.expectEqualStrings("run-shell", cmdlist_nth(double_click_list, 2).entry.name);
    try std.testing.expectEqualStrings("send-keys", cmdlist_nth(double_click_list, 3).entry.name);
    try std.testing.expectEqualStrings("select-word", cmd_mod.cmd_get_args(cmdlist_nth(double_click_list, 1)).value_at(0).?);
    try std.testing.expectEqualStrings("0.3", cmd_mod.cmd_get_args(cmdlist_nth(double_click_list, 2)).get('d').?);
    try std.testing.expectEqualStrings("copy-pipe-and-cancel", cmd_mod.cmd_get_args(cmdlist_nth(double_click_list, 3)).value_at(0).?);

    const semicolon = key_bindings_get(copy_vi, key_string.key_string_lookup_string(";")).?;
    try std.testing.expectEqualStrings("send-keys", cmdlist_nth(binding_cmdlist(semicolon), 0).entry.name);
    try std.testing.expectEqualStrings("jump-again", cmd_mod.cmd_get_args(cmdlist_nth(binding_cmdlist(semicolon), 0)).value_at(0).?);

    const word_search = key_bindings_get(copy_vi, key_string.key_string_lookup_string("#")).?;
    const word_search_args = cmd_mod.cmd_get_args(cmdlist_nth(binding_cmdlist(word_search), 0));
    try std.testing.expect(word_search_args.has('F'));
    try std.testing.expect(word_search_args.has('X'));
    try std.testing.expectEqualStrings("search-backward", word_search_args.value_at(0).?);
    try std.testing.expectEqualStrings("--", word_search_args.value_at(1).?);
    try std.testing.expectEqualStrings("#{copy_cursor_word}", word_search_args.value_at(2).?);
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
    key_bindings_add("prefix", 'v', "temporary", false, null);
    key_bindings_reset_table("prefix");
    const restored = key_bindings_get_table("prefix", false).?;
    try std.testing.expectEqual(original_count, restored.order.items.len);
    try std.testing.expect(key_bindings_get(restored, '?') != null);
    try std.testing.expect(key_bindings_get(restored, 'v') == null);
}

test "key bindings remove table removes prefix entirely" {
    key_bindings_init();
    key_bindings_remove_table("prefix");
    try std.testing.expect(key_bindings_get_table("prefix", false) == null);
}

test "key bindings remove table clears matching client override" {
    const env_mod = @import("environ.zig");

    key_bindings_init();
    key_bindings_add("transient-table", 'x', null, false, null);

    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);

    var client = T.Client{
        .environ = env,
        .tty = undefined,
        .status = undefined,
        .key_table_name = xm.xstrdup("transient-table"),
    };
    client_registry.add(&client);
    defer client_registry.remove(&client);

    key_bindings_remove_table("transient-table");
    try std.testing.expect(client.key_table_name == null);
}

test "key bindings dropping an empty table does not clear client override" {
    const env_mod = @import("environ.zig");

    key_bindings_init();
    key_bindings_add("transient-table", 'x', null, false, null);

    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);

    var client = T.Client{
        .environ = env,
        .tty = undefined,
        .status = undefined,
        .key_table_name = xm.xstrdup("transient-table"),
    };
    client_registry.add(&client);
    defer {
        client_registry.remove(&client);
        if (client.key_table_name) |name| xm.allocator.free(name);
    }

    key_bindings_remove("transient-table", 'x');
    try std.testing.expect(client.key_table_name != null);
    try std.testing.expectEqualStrings("transient-table", client.key_table_name.?);
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

test "default options-mode bindings are installed" {
    key_bindings_init();

    const emacs = key_bindings_get_table("options-mode", false).?;
    try std.testing.expect(key_bindings_get(emacs, 'q') != null);
    try std.testing.expect(key_bindings_get(emacs, T.KEYC_RIGHT) != null);
    try std.testing.expect(key_bindings_get(emacs, 'd') != null);
    try std.testing.expect(key_bindings_get(emacs, 'u') != null);
    try std.testing.expect(key_bindings_get(emacs, 'H') != null);

    const vi = key_bindings_get_table("options-mode-vi", false).?;
    try std.testing.expect(key_bindings_get(vi, 'h') != null);
    try std.testing.expect(key_bindings_get(vi, 'l') != null);
    try std.testing.expect(key_bindings_get(vi, 'd') != null);
    try std.testing.expect(key_bindings_get(vi, 'u') != null);
    try std.testing.expect(key_bindings_get(vi, 'H') != null);
}

test "default buffer-mode bindings are installed" {
    key_bindings_init();

    const emacs = key_bindings_get_table("buffer-mode", false).?;
    try std.testing.expect(key_bindings_get(emacs, 'q') != null);
    try std.testing.expect(key_bindings_get(emacs, 'p') != null);
    try std.testing.expect(key_bindings_get(emacs, 'P') != null);
    try std.testing.expect(key_bindings_get(emacs, 'd') != null);
    try std.testing.expect(key_bindings_get(emacs, 'D') != null);
    try std.testing.expect(key_bindings_get(emacs, 'e') != null);
    try std.testing.expect(key_bindings_get(emacs, 'f') != null);
    try std.testing.expect(key_bindings_get(emacs, 't') != null);
    try std.testing.expect(key_bindings_get(emacs, 'T') != null);
    try std.testing.expect(key_bindings_get(emacs, 't' | T.KEYC_CTRL) != null);
    try std.testing.expect(key_bindings_get(emacs, T.KEYC_DOWN) != null);

    const vi = key_bindings_get_table("buffer-mode-vi", false).?;
    try std.testing.expect(key_bindings_get(vi, 'q') != null);
    try std.testing.expect(key_bindings_get(vi, 'j') != null);
    try std.testing.expect(key_bindings_get(vi, 'p') != null);
    try std.testing.expect(key_bindings_get(vi, 'P') != null);
    try std.testing.expect(key_bindings_get(vi, 'd') != null);
    try std.testing.expect(key_bindings_get(vi, 'D') != null);
    try std.testing.expect(key_bindings_get(vi, 'e') != null);
    try std.testing.expect(key_bindings_get(vi, 'f') != null);
    try std.testing.expect(key_bindings_get(vi, 't') != null);
    try std.testing.expect(key_bindings_get(vi, 'T') != null);
    try std.testing.expect(key_bindings_get(vi, 't' | T.KEYC_CTRL) != null);
}

test "key bindings dispatch preserves the supplied current target state" {
    const args_mod = @import("arguments.zig");
    const cmd_find = @import("cmd-find.zig");
    const env_mod = @import("environ.zig");
    const opts_mod = @import("options.zig");
    const sess = @import("session.zig");
    const spawn = @import("spawn.zig");
    const win = @import("window.zig");

    const capture = struct {
        var seen_session: ?[]const u8 = null;

        fn exec(_: *cmd_mod.Cmd, item: *cmdq_mod.CmdqItem) T.CmdRetval {
            var target: T.CmdFindState = .{};
            if (cmd_find.cmd_find_target(&target, item, null, .session, 0) != 0)
                return .@"error";
            seen_session = target.s.?.name;
            return .normal;
        }
    };

    cmdq_mod.cmdq_reset_for_tests();
    defer cmdq_mod.cmdq_reset_for_tests();

    sess.session_init_globals(xm.allocator);
    win.window_init_globals(xm.allocator);

    opts_mod.global_options = opts_mod.options_create(null);
    defer opts_mod.options_free(opts_mod.global_options);
    opts_mod.global_s_options = opts_mod.options_create(null);
    defer opts_mod.options_free(opts_mod.global_s_options);
    opts_mod.global_w_options = opts_mod.options_create(null);
    defer opts_mod.options_free(opts_mod.global_w_options);
    opts_mod.options_default_all(opts_mod.global_options, T.OPTIONS_TABLE_SERVER);
    opts_mod.options_default_all(opts_mod.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts_mod.options_default_all(opts_mod.global_w_options, T.OPTIONS_TABLE_WINDOW);

    env_mod.global_environ = env_mod.environ_create();
    defer env_mod.environ_free(env_mod.global_environ);

    const s = sess.session_create(null, "dispatch-current", "/", env_mod.environ_create(), opts_mod.options_create(opts_mod.global_s_options), null);
    defer if (sess.session_find("dispatch-current") != null) sess.session_destroy(s, false, "test");

    var cause: ?[]u8 = null;
    var sc: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    _ = spawn.spawn_window(&sc, &cause).?;
    while (cmdq_mod.cmdq_next(null) != 0) {}

    const list = xm.allocator.create(cmd_mod.CmdList) catch unreachable;
    defer cmd_mod.cmd_list_free(list);
    list.* = .{};

    const entry = cmd_mod.CmdEntry{
        .name = "key-bindings-current-target-test",
        .exec = capture.exec,
    };

    const cmd = xm.allocator.create(cmd_mod.Cmd) catch unreachable;
    cmd.* = .{
        .entry = &entry,
        .args = args_mod.Arguments.init(xm.allocator),
    };
    list.append(cmd);

    var binding = T.KeyBinding{
        .key = 'x',
        .tablename = "test",
        .cmdlist = @ptrCast(list),
    };

    capture.seen_session = null;
    var current: T.CmdFindState = .{};
    cmd_find.cmd_find_from_session(&current, s, 0);

    _ = key_bindings_dispatch(&binding, null, null, null, &current);
    try std.testing.expect(cmdq_mod.cmdq_next(null) >= 1);
    try std.testing.expectEqualStrings("dispatch-current", capture.seen_session.?);
}
