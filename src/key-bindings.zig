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
const default_new_window_argv = [_][]const u8{"new-window"};
const default_display_message_argv = [_][]const u8{"display-message"};
const default_refresh_client_argv = [_][]const u8{"refresh-client"};
const default_copy_mode_cancel_argv = [_][]const u8{ "send-keys", "-X", "cancel" };
const default_copy_mode_cursor_left_argv = [_][]const u8{ "send-keys", "-X", "cursor-left" };
const default_copy_mode_cursor_right_argv = [_][]const u8{ "send-keys", "-X", "cursor-right" };
const default_copy_mode_cursor_up_argv = [_][]const u8{ "send-keys", "-X", "cursor-up" };
const default_copy_mode_cursor_down_argv = [_][]const u8{ "send-keys", "-X", "cursor-down" };
const default_copy_mode_page_up_argv = [_][]const u8{ "send-keys", "-X", "page-up" };
const default_copy_mode_page_down_argv = [_][]const u8{ "send-keys", "-X", "page-down" };
const default_copy_mode_halfpage_up_argv = [_][]const u8{ "send-keys", "-X", "halfpage-up" };
const default_copy_mode_halfpage_down_argv = [_][]const u8{ "send-keys", "-X", "halfpage-down" };
const default_copy_mode_history_top_argv = [_][]const u8{ "send-keys", "-X", "history-top" };
const default_copy_mode_history_bottom_argv = [_][]const u8{ "send-keys", "-X", "history-bottom" };
const default_copy_mode_start_of_line_argv = [_][]const u8{ "send-keys", "-X", "start-of-line" };
const default_copy_mode_end_of_line_argv = [_][]const u8{ "send-keys", "-X", "end-of-line" };
const default_copy_mode_top_line_argv = [_][]const u8{ "send-keys", "-X", "top-line" };
const default_copy_mode_middle_line_argv = [_][]const u8{ "send-keys", "-X", "middle-line" };
const default_copy_mode_bottom_line_argv = [_][]const u8{ "send-keys", "-X", "bottom-line" };
const default_client_mode_cancel_argv = [_][]const u8{ "send-keys", "-X", "cancel" };
const default_client_mode_choose_argv = [_][]const u8{ "send-keys", "-X", "choose" };
const default_client_mode_cursor_up_argv = [_][]const u8{ "send-keys", "-X", "cursor-up" };
const default_client_mode_cursor_down_argv = [_][]const u8{ "send-keys", "-X", "cursor-down" };
const default_client_mode_page_up_argv = [_][]const u8{ "send-keys", "-X", "page-up" };
const default_client_mode_page_down_argv = [_][]const u8{ "send-keys", "-X", "page-down" };
const default_client_mode_detach_argv = [_][]const u8{ "send-keys", "-X", "detach" };
const default_client_mode_detach_tagged_argv = [_][]const u8{ "send-keys", "-X", "detach-tagged" };
const default_client_mode_kill_argv = [_][]const u8{ "send-keys", "-X", "kill" };
const default_client_mode_kill_tagged_argv = [_][]const u8{ "send-keys", "-X", "kill-tagged" };
const default_client_mode_suspend_argv = [_][]const u8{ "send-keys", "-X", "suspend" };
const default_client_mode_suspend_tagged_argv = [_][]const u8{ "send-keys", "-X", "suspend-tagged" };
const default_client_mode_tag_argv = [_][]const u8{ "send-keys", "-X", "tag" };
const default_client_mode_tag_all_argv = [_][]const u8{ "send-keys", "-X", "tag-all" };
const default_client_mode_tag_none_argv = [_][]const u8{ "send-keys", "-X", "tag-none" };
const default_tree_mode_cancel_argv = [_][]const u8{ "send-keys", "-X", "cancel" };
const default_tree_mode_choose_argv = [_][]const u8{ "send-keys", "-X", "choose" };
const default_tree_mode_cursor_up_argv = [_][]const u8{ "send-keys", "-X", "cursor-up" };
const default_tree_mode_cursor_down_argv = [_][]const u8{ "send-keys", "-X", "cursor-down" };
const default_tree_mode_page_up_argv = [_][]const u8{ "send-keys", "-X", "page-up" };
const default_tree_mode_page_down_argv = [_][]const u8{ "send-keys", "-X", "page-down" };
const default_tree_mode_expand_argv = [_][]const u8{ "send-keys", "-X", "expand" };
const default_tree_mode_collapse_argv = [_][]const u8{ "send-keys", "-X", "collapse" };
const default_tree_mode_tag_argv = [_][]const u8{ "send-keys", "-X", "tag" };
const default_tree_mode_tag_all_argv = [_][]const u8{ "send-keys", "-X", "tag-all" };
const default_tree_mode_tag_none_argv = [_][]const u8{ "send-keys", "-X", "tag-none" };
const default_tree_mode_home_target_argv = [_][]const u8{ "send-keys", "-X", "home-target" };

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
    .{
        .table = "copy-mode",
        .key = 'q',
        .note = "Exit copy mode",
        .argv = default_copy_mode_cancel_argv[0..],
    },
    .{
        .table = "copy-mode",
        .key = T.C0_ESC,
        .note = "Exit copy mode",
        .argv = default_copy_mode_cancel_argv[0..],
    },
    .{
        .table = "copy-mode",
        .key = T.KEYC_LEFT,
        .note = "Move left",
        .argv = default_copy_mode_cursor_left_argv[0..],
    },
    .{
        .table = "copy-mode",
        .key = T.KEYC_RIGHT,
        .note = "Move right",
        .argv = default_copy_mode_cursor_right_argv[0..],
    },
    .{
        .table = "copy-mode",
        .key = T.KEYC_UP,
        .note = "Move up",
        .argv = default_copy_mode_cursor_up_argv[0..],
    },
    .{
        .table = "copy-mode",
        .key = T.KEYC_DOWN,
        .note = "Move down",
        .argv = default_copy_mode_cursor_down_argv[0..],
    },
    .{
        .table = "copy-mode",
        .key = T.KEYC_PPAGE,
        .note = "Page up",
        .argv = default_copy_mode_page_up_argv[0..],
    },
    .{
        .table = "copy-mode",
        .key = T.KEYC_NPAGE,
        .note = "Page down",
        .argv = default_copy_mode_page_down_argv[0..],
    },
    .{
        .table = "copy-mode-vi",
        .key = 'q',
        .note = "Exit copy mode",
        .argv = default_copy_mode_cancel_argv[0..],
    },
    .{
        .table = "copy-mode-vi",
        .key = T.C0_ESC,
        .note = "Exit copy mode",
        .argv = default_copy_mode_cancel_argv[0..],
    },
    .{
        .table = "copy-mode-vi",
        .key = 'h',
        .note = "Move left",
        .argv = default_copy_mode_cursor_left_argv[0..],
    },
    .{
        .table = "copy-mode-vi",
        .key = 'l',
        .note = "Move right",
        .argv = default_copy_mode_cursor_right_argv[0..],
    },
    .{
        .table = "copy-mode-vi",
        .key = 'k',
        .note = "Move up",
        .argv = default_copy_mode_cursor_up_argv[0..],
    },
    .{
        .table = "copy-mode-vi",
        .key = 'j',
        .note = "Move down",
        .argv = default_copy_mode_cursor_down_argv[0..],
    },
    .{
        .table = "copy-mode-vi",
        .key = T.KEYC_PPAGE,
        .note = "Page up",
        .argv = default_copy_mode_page_up_argv[0..],
    },
    .{
        .table = "copy-mode-vi",
        .key = T.KEYC_NPAGE,
        .note = "Page down",
        .argv = default_copy_mode_page_down_argv[0..],
    },
    .{
        .table = "copy-mode-vi",
        .key = 'u' | T.KEYC_CTRL,
        .note = "Half page up",
        .argv = default_copy_mode_halfpage_up_argv[0..],
    },
    .{
        .table = "copy-mode-vi",
        .key = 'd' | T.KEYC_CTRL,
        .note = "Half page down",
        .argv = default_copy_mode_halfpage_down_argv[0..],
    },
    .{
        .table = "copy-mode-vi",
        .key = 'g',
        .note = "Go to top",
        .argv = default_copy_mode_history_top_argv[0..],
    },
    .{
        .table = "copy-mode-vi",
        .key = 'G',
        .note = "Go to bottom",
        .argv = default_copy_mode_history_bottom_argv[0..],
    },
    .{
        .table = "copy-mode-vi",
        .key = '0',
        .note = "Start of line",
        .argv = default_copy_mode_start_of_line_argv[0..],
    },
    .{
        .table = "copy-mode-vi",
        .key = '$',
        .note = "End of line",
        .argv = default_copy_mode_end_of_line_argv[0..],
    },
    .{
        .table = "copy-mode-vi",
        .key = 'H',
        .note = "Move to top line",
        .argv = default_copy_mode_top_line_argv[0..],
    },
    .{
        .table = "copy-mode-vi",
        .key = 'M',
        .note = "Move to middle line",
        .argv = default_copy_mode_middle_line_argv[0..],
    },
    .{
        .table = "copy-mode-vi",
        .key = 'L',
        .note = "Move to bottom line",
        .argv = default_copy_mode_bottom_line_argv[0..],
    },
    .{
        .table = "client-mode",
        .key = 'q',
        .note = "Exit client mode",
        .argv = default_client_mode_cancel_argv[0..],
    },
    .{
        .table = "client-mode",
        .key = T.C0_ESC,
        .note = "Exit client mode",
        .argv = default_client_mode_cancel_argv[0..],
    },
    .{
        .table = "client-mode",
        .key = '\r',
        .note = "Choose selected client",
        .argv = default_client_mode_choose_argv[0..],
    },
    .{
        .table = "client-mode",
        .key = T.KEYC_UP,
        .note = "Move up",
        .argv = default_client_mode_cursor_up_argv[0..],
    },
    .{
        .table = "client-mode",
        .key = T.KEYC_DOWN,
        .note = "Move down",
        .argv = default_client_mode_cursor_down_argv[0..],
    },
    .{
        .table = "client-mode",
        .key = T.KEYC_PPAGE,
        .note = "Page up",
        .argv = default_client_mode_page_up_argv[0..],
    },
    .{
        .table = "client-mode",
        .key = T.KEYC_NPAGE,
        .note = "Page down",
        .argv = default_client_mode_page_down_argv[0..],
    },
    .{
        .table = "client-mode",
        .key = 'd',
        .note = "Detach selected client",
        .argv = default_client_mode_detach_argv[0..],
    },
    .{
        .table = "client-mode",
        .key = 'D',
        .note = "Detach tagged clients",
        .argv = default_client_mode_detach_tagged_argv[0..],
    },
    .{
        .table = "client-mode",
        .key = 'x',
        .note = "Kill selected client",
        .argv = default_client_mode_kill_argv[0..],
    },
    .{
        .table = "client-mode",
        .key = 'X',
        .note = "Kill tagged clients",
        .argv = default_client_mode_kill_tagged_argv[0..],
    },
    .{
        .table = "client-mode",
        .key = 'z',
        .note = "Suspend selected client",
        .argv = default_client_mode_suspend_argv[0..],
    },
    .{
        .table = "client-mode",
        .key = 'Z',
        .note = "Suspend tagged clients",
        .argv = default_client_mode_suspend_tagged_argv[0..],
    },
    .{
        .table = "client-mode",
        .key = 't',
        .note = "Tag selected client",
        .argv = default_client_mode_tag_argv[0..],
    },
    .{
        .table = "client-mode",
        .key = 'T',
        .note = "Clear all tags",
        .argv = default_client_mode_tag_none_argv[0..],
    },
    .{
        .table = "client-mode",
        .key = 't' | T.KEYC_CTRL,
        .note = "Tag all clients",
        .argv = default_client_mode_tag_all_argv[0..],
    },
    .{
        .table = "client-mode-vi",
        .key = 'q',
        .note = "Exit client mode",
        .argv = default_client_mode_cancel_argv[0..],
    },
    .{
        .table = "client-mode-vi",
        .key = T.C0_ESC,
        .note = "Exit client mode",
        .argv = default_client_mode_cancel_argv[0..],
    },
    .{
        .table = "client-mode-vi",
        .key = '\r',
        .note = "Choose selected client",
        .argv = default_client_mode_choose_argv[0..],
    },
    .{
        .table = "client-mode-vi",
        .key = 'k',
        .note = "Move up",
        .argv = default_client_mode_cursor_up_argv[0..],
    },
    .{
        .table = "client-mode-vi",
        .key = 'j',
        .note = "Move down",
        .argv = default_client_mode_cursor_down_argv[0..],
    },
    .{
        .table = "client-mode-vi",
        .key = T.KEYC_UP,
        .note = "Move up",
        .argv = default_client_mode_cursor_up_argv[0..],
    },
    .{
        .table = "client-mode-vi",
        .key = T.KEYC_DOWN,
        .note = "Move down",
        .argv = default_client_mode_cursor_down_argv[0..],
    },
    .{
        .table = "client-mode-vi",
        .key = T.KEYC_PPAGE,
        .note = "Page up",
        .argv = default_client_mode_page_up_argv[0..],
    },
    .{
        .table = "client-mode-vi",
        .key = T.KEYC_NPAGE,
        .note = "Page down",
        .argv = default_client_mode_page_down_argv[0..],
    },
    .{
        .table = "client-mode-vi",
        .key = 'd',
        .note = "Detach selected client",
        .argv = default_client_mode_detach_argv[0..],
    },
    .{
        .table = "client-mode-vi",
        .key = 'D',
        .note = "Detach tagged clients",
        .argv = default_client_mode_detach_tagged_argv[0..],
    },
    .{
        .table = "client-mode-vi",
        .key = 'x',
        .note = "Kill selected client",
        .argv = default_client_mode_kill_argv[0..],
    },
    .{
        .table = "client-mode-vi",
        .key = 'X',
        .note = "Kill tagged clients",
        .argv = default_client_mode_kill_tagged_argv[0..],
    },
    .{
        .table = "client-mode-vi",
        .key = 'z',
        .note = "Suspend selected client",
        .argv = default_client_mode_suspend_argv[0..],
    },
    .{
        .table = "client-mode-vi",
        .key = 'Z',
        .note = "Suspend tagged clients",
        .argv = default_client_mode_suspend_tagged_argv[0..],
    },
    .{
        .table = "client-mode-vi",
        .key = 't',
        .note = "Tag selected client",
        .argv = default_client_mode_tag_argv[0..],
    },
    .{
        .table = "client-mode-vi",
        .key = 'T',
        .note = "Clear all tags",
        .argv = default_client_mode_tag_none_argv[0..],
    },
    .{
        .table = "client-mode-vi",
        .key = 't' | T.KEYC_CTRL,
        .note = "Tag all clients",
        .argv = default_client_mode_tag_all_argv[0..],
    },
    .{
        .table = "tree-mode",
        .key = 'q',
        .note = "Exit tree mode",
        .argv = default_tree_mode_cancel_argv[0..],
    },
    .{
        .table = "tree-mode",
        .key = T.C0_ESC,
        .note = "Exit tree mode",
        .argv = default_tree_mode_cancel_argv[0..],
    },
    .{
        .table = "tree-mode",
        .key = '\r',
        .note = "Choose selected item",
        .argv = default_tree_mode_choose_argv[0..],
    },
    .{
        .table = "tree-mode",
        .key = T.KEYC_UP,
        .note = "Move up",
        .argv = default_tree_mode_cursor_up_argv[0..],
    },
    .{
        .table = "tree-mode",
        .key = T.KEYC_DOWN,
        .note = "Move down",
        .argv = default_tree_mode_cursor_down_argv[0..],
    },
    .{
        .table = "tree-mode",
        .key = T.KEYC_PPAGE,
        .note = "Page up",
        .argv = default_tree_mode_page_up_argv[0..],
    },
    .{
        .table = "tree-mode",
        .key = T.KEYC_NPAGE,
        .note = "Page down",
        .argv = default_tree_mode_page_down_argv[0..],
    },
    .{
        .table = "tree-mode",
        .key = T.KEYC_LEFT,
        .note = "Collapse current item",
        .argv = default_tree_mode_collapse_argv[0..],
    },
    .{
        .table = "tree-mode",
        .key = T.KEYC_RIGHT,
        .note = "Expand current item",
        .argv = default_tree_mode_expand_argv[0..],
    },
    .{
        .table = "tree-mode",
        .key = 't',
        .note = "Tag selected item",
        .argv = default_tree_mode_tag_argv[0..],
    },
    .{
        .table = "tree-mode",
        .key = 'T',
        .note = "Clear all tree tags",
        .argv = default_tree_mode_tag_none_argv[0..],
    },
    .{
        .table = "tree-mode",
        .key = 't' | T.KEYC_CTRL,
        .note = "Tag all tree items",
        .argv = default_tree_mode_tag_all_argv[0..],
    },
    .{
        .table = "tree-mode",
        .key = 'H',
        .note = "Jump to the target item",
        .argv = default_tree_mode_home_target_argv[0..],
    },
    .{
        .table = "tree-mode-vi",
        .key = 'q',
        .note = "Exit tree mode",
        .argv = default_tree_mode_cancel_argv[0..],
    },
    .{
        .table = "tree-mode-vi",
        .key = T.C0_ESC,
        .note = "Exit tree mode",
        .argv = default_tree_mode_cancel_argv[0..],
    },
    .{
        .table = "tree-mode-vi",
        .key = '\r',
        .note = "Choose selected item",
        .argv = default_tree_mode_choose_argv[0..],
    },
    .{
        .table = "tree-mode-vi",
        .key = 'k',
        .note = "Move up",
        .argv = default_tree_mode_cursor_up_argv[0..],
    },
    .{
        .table = "tree-mode-vi",
        .key = 'j',
        .note = "Move down",
        .argv = default_tree_mode_cursor_down_argv[0..],
    },
    .{
        .table = "tree-mode-vi",
        .key = T.KEYC_UP,
        .note = "Move up",
        .argv = default_tree_mode_cursor_up_argv[0..],
    },
    .{
        .table = "tree-mode-vi",
        .key = T.KEYC_DOWN,
        .note = "Move down",
        .argv = default_tree_mode_cursor_down_argv[0..],
    },
    .{
        .table = "tree-mode-vi",
        .key = T.KEYC_PPAGE,
        .note = "Page up",
        .argv = default_tree_mode_page_up_argv[0..],
    },
    .{
        .table = "tree-mode-vi",
        .key = T.KEYC_NPAGE,
        .note = "Page down",
        .argv = default_tree_mode_page_down_argv[0..],
    },
    .{
        .table = "tree-mode-vi",
        .key = 'h',
        .note = "Collapse current item",
        .argv = default_tree_mode_collapse_argv[0..],
    },
    .{
        .table = "tree-mode-vi",
        .key = 'l',
        .note = "Expand current item",
        .argv = default_tree_mode_expand_argv[0..],
    },
    .{
        .table = "tree-mode-vi",
        .key = T.KEYC_LEFT,
        .note = "Collapse current item",
        .argv = default_tree_mode_collapse_argv[0..],
    },
    .{
        .table = "tree-mode-vi",
        .key = T.KEYC_RIGHT,
        .note = "Expand current item",
        .argv = default_tree_mode_expand_argv[0..],
    },
    .{
        .table = "tree-mode-vi",
        .key = 't',
        .note = "Tag selected item",
        .argv = default_tree_mode_tag_argv[0..],
    },
    .{
        .table = "tree-mode-vi",
        .key = 'T',
        .note = "Clear all tree tags",
        .argv = default_tree_mode_tag_none_argv[0..],
    },
    .{
        .table = "tree-mode-vi",
        .key = 't' | T.KEYC_CTRL,
        .note = "Tag all tree items",
        .argv = default_tree_mode_tag_all_argv[0..],
    },
    .{
        .table = "tree-mode-vi",
        .key = 'H',
        .note = "Jump to the target item",
        .argv = default_tree_mode_home_target_argv[0..],
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
    const argv = [_][]const u8{ "select-window", "-t", target_buf[0..] };
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
    try std.testing.expectEqualStrings("prefix", key_bindings_first_table().?.name);
    try std.testing.expectEqualStrings("root", key_bindings_next_table(key_bindings_first_table().?).?.name);
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
