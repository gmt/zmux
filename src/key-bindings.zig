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
    if (binding.cmdlist) |list| cmd_mod.cmd_list_unref(list);
    if (binding.note) |note| xm.allocator.free(note);
    xm.allocator.destroy(binding);
}

const DefaultBindingSpec = struct {
    table: []const u8,
    key: T.key_code = T.KEYC_NONE,
    key_name: ?[]const u8 = null,
    note: ?[]const u8 = null,
    repeat: bool = false,
    argv: ?[]const []const u8 = null,
    command: ?[]const u8 = null,
};

const default_list_keys_argv = [_][]const u8{ "list-keys", "-N" };
const default_new_window_argv = [_][]const u8{"new-window"};
const default_display_message_argv = [_][]const u8{"display-message"};
const default_refresh_client_argv = [_][]const u8{"refresh-client"};
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
const default_buffer_mode_cancel_argv = [_][]const u8{ "send-keys", "-X", "cancel" };
const default_buffer_mode_choose_argv = [_][]const u8{ "send-keys", "-X", "choose" };
const default_buffer_mode_delete_argv = [_][]const u8{ "send-keys", "-X", "delete" };
const default_buffer_mode_delete_tagged_argv = [_][]const u8{ "send-keys", "-X", "delete-tagged" };
const default_buffer_mode_edit_selected_argv = [_][]const u8{ "send-keys", "-X", "edit-selected" };
const default_buffer_mode_filter_argv = [_][]const u8{ "send-keys", "-X", "filter" };
const default_buffer_mode_paste_argv = [_][]const u8{ "send-keys", "-X", "paste" };
const default_buffer_mode_paste_tagged_argv = [_][]const u8{ "send-keys", "-X", "paste-tagged" };
const default_buffer_mode_tag_argv = [_][]const u8{ "send-keys", "-X", "tag" };
const default_buffer_mode_tag_all_argv = [_][]const u8{ "send-keys", "-X", "tag-all" };
const default_buffer_mode_tag_none_argv = [_][]const u8{ "send-keys", "-X", "tag-none" };
const default_buffer_mode_cursor_up_argv = [_][]const u8{ "send-keys", "-X", "cursor-up" };
const default_buffer_mode_cursor_down_argv = [_][]const u8{ "send-keys", "-X", "cursor-down" };
const default_buffer_mode_page_up_argv = [_][]const u8{ "send-keys", "-X", "page-up" };
const default_buffer_mode_page_down_argv = [_][]const u8{ "send-keys", "-X", "page-down" };
const default_tree_mode_cancel_argv = [_][]const u8{ "send-keys", "-X", "cancel" };
const default_tree_mode_choose_argv = [_][]const u8{ "send-keys", "-X", "choose" };
const default_tree_mode_cursor_up_argv = [_][]const u8{ "send-keys", "-X", "cursor-up" };
const default_tree_mode_cursor_down_argv = [_][]const u8{ "send-keys", "-X", "cursor-down" };
const default_tree_mode_page_up_argv = [_][]const u8{ "send-keys", "-X", "page-up" };
const default_tree_mode_page_down_argv = [_][]const u8{ "send-keys", "-X", "page-down" };
const default_tree_mode_expand_argv = [_][]const u8{ "send-keys", "-X", "expand" };
const default_tree_mode_collapse_argv = [_][]const u8{ "send-keys", "-X", "collapse" };
const default_tree_mode_scroll_left_argv = [_][]const u8{ "send-keys", "-X", "scroll-left" };
const default_tree_mode_scroll_right_argv = [_][]const u8{ "send-keys", "-X", "scroll-right" };
const default_tree_mode_tag_argv = [_][]const u8{ "send-keys", "-X", "tag" };
const default_tree_mode_tag_all_argv = [_][]const u8{ "send-keys", "-X", "tag-all" };
const default_tree_mode_tag_none_argv = [_][]const u8{ "send-keys", "-X", "tag-none" };
const default_tree_mode_home_target_argv = [_][]const u8{ "send-keys", "-X", "home-target" };
const default_options_mode_cancel_argv = [_][]const u8{ "send-keys", "-X", "cancel" };
const default_options_mode_choose_argv = [_][]const u8{ "send-keys", "-X", "choose" };
const default_options_mode_cursor_up_argv = [_][]const u8{ "send-keys", "-X", "cursor-up" };
const default_options_mode_cursor_down_argv = [_][]const u8{ "send-keys", "-X", "cursor-down" };
const default_options_mode_page_up_argv = [_][]const u8{ "send-keys", "-X", "page-up" };
const default_options_mode_page_down_argv = [_][]const u8{ "send-keys", "-X", "page-down" };
const default_options_mode_expand_argv = [_][]const u8{ "send-keys", "-X", "expand" };
const default_options_mode_collapse_argv = [_][]const u8{ "send-keys", "-X", "collapse" };
const default_options_mode_reset_current_argv = [_][]const u8{ "send-keys", "-X", "reset-current" };
const default_options_mode_toggle_hide_inherited_argv = [_][]const u8{ "send-keys", "-X", "toggle-hide-inherited" };
const default_options_mode_unset_current_argv = [_][]const u8{ "send-keys", "-X", "unset-current" };
const default_session_menu =
    " 'Next' 'n' {switch-client -n}" ++
    " 'Previous' 'p' {switch-client -p}" ++
    " ''" ++
    " 'Renumber' 'N' {move-window -r}" ++
    " 'Rename' 'n' {command-prompt -I \"#S\" {rename-session -- '%%'}}" ++
    " ''" ++
    " 'New Session' 's' {new-session}" ++
    " 'New Window' 'w' {new-window}";
const default_window_menu =
    " '#{?#{>:#{session_windows},1},,-}Swap Left' 'l' {swap-window -t:-1}" ++
    " '#{?#{>:#{session_windows},1},,-}Swap Right' 'r' {swap-window -t:+1}" ++
    " '#{?pane_marked_set,,-}Swap Marked' 's' {swap-window}" ++
    " ''" ++
    " 'Kill' 'X' {kill-window}" ++
    " 'Respawn' 'R' {respawn-window -k}" ++
    " '#{?pane_marked,Unmark,Mark}' 'm' {select-pane -m}" ++
    " 'Rename' 'n' {command-prompt -FI \"#W\" {rename-window -t '#{window_id}' -- '%%'}}" ++
    " ''" ++
    " 'New After' 'w' {new-window -a}" ++
    " 'New At End' 'W' {new-window}";
const default_pane_menu =
    " '#{?#{m/r:(copy|view)-mode,#{pane_mode}},Go To Top,}' '<' \"send -X history-top\"" ++
    " '#{?#{m/r:(copy|view)-mode,#{pane_mode}},Go To Bottom,}' '>' \"send -X history-bottom\"" ++
    " ''" ++
    " '#{?#{&&:#{buffer_size},#{!:#{pane_in_mode}}},Paste #[underscore]#{=/9/...:buffer_sample},}' 'p' \"paste-buffer\"" ++
    " ''" ++
    " '#{?mouse_word,Search For #[underscore]#{=/9/...:mouse_word},}' 'C-r' \"if -F '#{?#{m/r:(copy|view)-mode,#{pane_mode}},0,1}' 'copy-mode -t ='; send -X -t = search-backward -- '#{q:mouse_word}'\"" ++
    " '#{?mouse_word,Type #[underscore]#{=/9/...:mouse_word},}' 'C-y' \"copy-mode -q; send-keys -l -- '#{q:mouse_word}'\"" ++
    " '#{?mouse_word,Copy #[underscore]#{=/9/...:mouse_word},}' 'c' \"copy-mode -q; set-buffer -- '#{q:mouse_word}'\"" ++
    " '#{?mouse_line,Copy Line,}' 'l' \"copy-mode -q; set-buffer -- '#{q:mouse_line}'\"" ++
    " ''" ++
    " '#{?mouse_hyperlink,Type #[underscore]#{=/9/...:mouse_hyperlink},}' 'C-h' \"copy-mode -q; send-keys -l -- '#{q:mouse_hyperlink}'\"" ++
    " '#{?mouse_hyperlink,Copy #[underscore]#{=/9/...:mouse_hyperlink},}' 'h' \"copy-mode -q; set-buffer -- '#{q:mouse_hyperlink}'\"" ++
    " ''" ++
    " 'Horizontal Split' 'h' \"split-window -h\"" ++
    " 'Vertical Split' 'v' \"split-window -v\"" ++
    " ''" ++
    " '#{?#{>:#{window_panes},1},,-}Swap Up' 'u' \"swap-pane -U\"" ++
    " '#{?#{>:#{window_panes},1},,-}Swap Down' 'd' \"swap-pane -D\"" ++
    " '#{?pane_marked_set,,-}Swap Marked' 's' \"swap-pane\"" ++
    " ''" ++
    " 'Kill' 'X' \"kill-pane\"" ++
    " 'Respawn' 'R' \"respawn-pane -k\"" ++
    " '#{?pane_marked,Unmark,Mark}' 'm' \"select-pane -m\"" ++
    " '#{?#{>:#{window_panes},1},,-}#{?window_zoomed_flag,Unzoom,Zoom}' 'z' \"resize-pane -Z\"";
const default_pane_menu_display =
    "display-menu -t = -xM -yM -T '#[align=centre]#{pane_index} (#{pane_id})'" ++ default_pane_menu;
const default_mouse_down3_pane_argv = [_][]const u8{
    "if",
    "-F",
    "-t",
    "=",
    "#{||:#{mouse_any_flag},#{&&:#{pane_in_mode},#{?#{m/r:(copy|view)-mode,#{pane_mode}},0,1}}}",
    "select-pane -t=; send -M",
    default_pane_menu_display,
};

const default_binding_specs = [_]DefaultBindingSpec{
    .{
        .table = "prefix",
        .key_name = "C-b",
        .note = "Send the prefix key",
        .command = "send-prefix",
    },
    .{
        .table = "prefix",
        .key_name = "C-o",
        .note = "Rotate through the panes",
        .command = "rotate-window",
    },
    .{
        .table = "prefix",
        .key_name = "C-z",
        .note = "Suspend the current client",
        .command = "suspend-client",
    },
    .{
        .table = "prefix",
        .key_name = "Space",
        .note = "Select next layout",
        .command = "next-layout",
    },
    .{
        .table = "prefix",
        .key = '!',
        .note = "Break pane to a new window",
        .command = "break-pane",
    },
    .{
        .table = "prefix",
        .key = '"',
        .note = "Split window vertically",
        .command = "split-window",
    },
    .{
        .table = "prefix",
        .key = '#',
        .note = "List all paste buffers",
        .command = "list-buffers",
    },
    .{
        .table = "prefix",
        .key = '$',
        .note = "Rename current session",
        .command = "command-prompt -I'#S' \"rename-session -- '%%'\"",
    },
    .{
        .table = "prefix",
        .key = '%',
        .note = "Split window horizontally",
        .command = "split-window -h",
    },
    .{
        .table = "prefix",
        .key = '&',
        .note = "Kill current window",
        .command = "confirm-before -p'kill-window #W? (y/n)' kill-window",
    },
    .{
        .table = "prefix",
        .key_name = "'",
        .note = "Prompt for window index to select",
        .command = "command-prompt -T window-target -pindex \"select-window -t ':%%'\"",
    },
    .{
        .table = "prefix",
        .key = '(',
        .note = "Switch to previous client",
        .command = "switch-client -p",
    },
    .{
        .table = "prefix",
        .key = ')',
        .note = "Switch to next client",
        .command = "switch-client -n",
    },
    .{
        .table = "prefix",
        .key = ',',
        .note = "Rename current window",
        .command = "command-prompt -I'#W' \"rename-window -- '%%'\"",
    },
    .{
        .table = "prefix",
        .key = '-',
        .note = "Delete the most recent paste buffer",
        .command = "delete-buffer",
    },
    .{
        .table = "prefix",
        .key = '.',
        .note = "Move the current window",
        .command = "command-prompt -T target \"move-window -t '%%'\"",
    },
    .{
        .table = "prefix",
        .key = '/',
        .note = "Describe key binding",
        .command = "command-prompt -kpkey \"list-keys -1N '%%'\"",
    },
    .{
        .table = "prefix",
        .key = ':',
        .note = "Prompt for a command",
        .command = "command-prompt",
    },
    .{
        .table = "prefix",
        .key = ';',
        .note = "Move to the previously active pane",
        .command = "last-pane",
    },
    .{
        .table = "prefix",
        .key = '=',
        .note = "Choose a paste buffer from a list",
        .command = "choose-buffer -Z",
    },
    .{
        .table = "prefix",
        .key = '?',
        .note = "List key bindings",
        .argv = default_list_keys_argv[0..],
    },
    .{
        .table = "prefix",
        .key = 'D',
        .note = "Choose and detach a client from a list",
        .command = "choose-client -Z",
    },
    .{
        .table = "prefix",
        .key = 'E',
        .note = "Spread panes out evenly",
        .command = "select-layout -E",
    },
    .{
        .table = "prefix",
        .key = 'L',
        .note = "Switch to the last client",
        .command = "switch-client -l",
    },
    .{
        .table = "prefix",
        .key = 'M',
        .note = "Clear the marked pane",
        .command = "select-pane -M",
    },
    .{
        .table = "prefix",
        .key = '[',
        .note = "Enter copy mode",
        .command = "copy-mode",
    },
    .{
        .table = "prefix",
        .key = ']',
        .note = "Paste the most recent paste buffer",
        .command = "paste-buffer -p",
    },
    .{
        .table = "prefix",
        .key = 'c',
        .note = "Create a new window",
        .argv = default_new_window_argv[0..],
    },
    .{
        .table = "prefix",
        .key = 'd',
        .note = "Detach the current client",
        .command = "detach-client",
    },
    .{
        .table = "prefix",
        .key = 'f',
        .note = "Search for a pane",
        .command = "command-prompt \"find-window -Z -- '%%'\"",
    },
    .{
        .table = "prefix",
        .key = 'i',
        .note = "Display window information",
        .argv = default_display_message_argv[0..],
    },
    .{
        .table = "prefix",
        .key = 'l',
        .note = "Select the previously current window",
        .command = "last-window",
    },
    .{
        .table = "prefix",
        .key = 'm',
        .note = "Toggle the marked pane",
        .command = "select-pane -m",
    },
    .{
        .table = "prefix",
        .key = 'n',
        .note = "Select the next window",
        .command = "next-window",
    },
    .{
        .table = "prefix",
        .key = 'o',
        .note = "Select the next pane",
        .command = "select-pane -t:.+",
    },
    .{
        .table = "prefix",
        .key = 'C',
        .note = "Customize options",
        .command = "customize-mode -Z",
    },
    .{
        .table = "prefix",
        .key = 'p',
        .note = "Select the previous window",
        .command = "previous-window",
    },
    .{
        .table = "prefix",
        .key = 'q',
        .note = "Display pane numbers",
        .command = "display-panes",
    },
    .{
        .table = "prefix",
        .key = 'r',
        .note = "Redraw the current client",
        .argv = default_refresh_client_argv[0..],
    },
    .{
        .table = "prefix",
        .key = 's',
        .note = "Choose a session from a list",
        .command = "choose-tree -Zs",
    },
    .{
        .table = "prefix",
        .key = 't',
        .note = "Show a clock",
        .command = "clock-mode",
    },
    .{
        .table = "prefix",
        .key = 'w',
        .note = "Choose a window from a list",
        .command = "choose-tree -Zw",
    },
    .{
        .table = "prefix",
        .key = 'x',
        .note = "Kill the active pane",
        .command = "confirm-before -p'kill-pane #P? (y/n)' kill-pane",
    },
    .{
        .table = "prefix",
        .key = 'z',
        .note = "Zoom the active pane",
        .command = "resize-pane -Z",
    },
    .{
        .table = "prefix",
        .key = '{',
        .note = "Swap the active pane with the pane above",
        .command = "swap-pane -U",
    },
    .{
        .table = "prefix",
        .key = '}',
        .note = "Swap the active pane with the pane below",
        .command = "swap-pane -D",
    },
    .{
        .table = "prefix",
        .key = '~',
        .note = "Show messages",
        .command = "show-messages",
    },
    .{
        .table = "prefix",
        .key_name = "PPage",
        .note = "Enter copy mode and scroll up",
        .command = "copy-mode -u",
    },
    .{
        .table = "prefix",
        .key_name = "Up",
        .note = "Select the pane above the active pane",
        .repeat = true,
        .command = "select-pane -U",
    },
    .{
        .table = "prefix",
        .key_name = "Down",
        .note = "Select the pane below the active pane",
        .repeat = true,
        .command = "select-pane -D",
    },
    .{
        .table = "prefix",
        .key_name = "Left",
        .note = "Select the pane to the left of the active pane",
        .repeat = true,
        .command = "select-pane -L",
    },
    .{
        .table = "prefix",
        .key_name = "Right",
        .note = "Select the pane to the right of the active pane",
        .repeat = true,
        .command = "select-pane -R",
    },
    .{
        .table = "prefix",
        .key_name = "M-1",
        .note = "Set the even-horizontal layout",
        .command = "select-layout even-horizontal",
    },
    .{
        .table = "prefix",
        .key_name = "M-2",
        .note = "Set the even-vertical layout",
        .command = "select-layout even-vertical",
    },
    .{
        .table = "prefix",
        .key_name = "M-3",
        .note = "Set the main-horizontal layout",
        .command = "select-layout main-horizontal",
    },
    .{
        .table = "prefix",
        .key_name = "M-4",
        .note = "Set the main-vertical layout",
        .command = "select-layout main-vertical",
    },
    .{
        .table = "prefix",
        .key_name = "M-5",
        .note = "Select the tiled layout",
        .command = "select-layout tiled",
    },
    .{
        .table = "prefix",
        .key_name = "M-6",
        .note = "Set the main-horizontal-mirrored layout",
        .command = "select-layout main-horizontal-mirrored",
    },
    .{
        .table = "prefix",
        .key_name = "M-7",
        .note = "Set the main-vertical-mirrored layout",
        .command = "select-layout main-vertical-mirrored",
    },
    .{
        .table = "prefix",
        .key_name = "M-n",
        .note = "Select the next window with an alert",
        .command = "next-window -a",
    },
    .{
        .table = "prefix",
        .key_name = "M-o",
        .note = "Rotate through the panes in reverse",
        .command = "rotate-window -D",
    },
    .{
        .table = "prefix",
        .key_name = "M-p",
        .note = "Select the previous window with an alert",
        .command = "previous-window -a",
    },
    .{
        .table = "prefix",
        .key_name = "S-Up",
        .note = "Move the visible part of the window up",
        .repeat = true,
        .command = "refresh-client -U 10",
    },
    .{
        .table = "prefix",
        .key_name = "S-Down",
        .note = "Move the visible part of the window down",
        .repeat = true,
        .command = "refresh-client -D 10",
    },
    .{
        .table = "prefix",
        .key_name = "S-Left",
        .note = "Move the visible part of the window left",
        .repeat = true,
        .command = "refresh-client -L 10",
    },
    .{
        .table = "prefix",
        .key_name = "S-Right",
        .note = "Move the visible part of the window right",
        .repeat = true,
        .command = "refresh-client -R 10",
    },
    .{
        .table = "prefix",
        .key_name = "DC",
        .note = "Reset so the visible part of the window follows the cursor",
        .repeat = true,
        .command = "refresh-client -c",
    },
    .{
        .table = "prefix",
        .key_name = "M-Up",
        .note = "Resize the pane up by 5",
        .repeat = true,
        .command = "resize-pane -U 5",
    },
    .{
        .table = "prefix",
        .key_name = "M-Down",
        .note = "Resize the pane down by 5",
        .repeat = true,
        .command = "resize-pane -D 5",
    },
    .{
        .table = "prefix",
        .key_name = "M-Left",
        .note = "Resize the pane left by 5",
        .repeat = true,
        .command = "resize-pane -L 5",
    },
    .{
        .table = "prefix",
        .key_name = "M-Right",
        .note = "Resize the pane right by 5",
        .repeat = true,
        .command = "resize-pane -R 5",
    },
    .{
        .table = "prefix",
        .key_name = "C-Up",
        .note = "Resize the pane up",
        .repeat = true,
        .command = "resize-pane -U",
    },
    .{
        .table = "prefix",
        .key_name = "C-Down",
        .note = "Resize the pane down",
        .repeat = true,
        .command = "resize-pane -D",
    },
    .{
        .table = "prefix",
        .key_name = "C-Left",
        .note = "Resize the pane left",
        .repeat = true,
        .command = "resize-pane -L",
    },
    .{
        .table = "prefix",
        .key_name = "C-Right",
        .note = "Resize the pane right",
        .repeat = true,
        .command = "resize-pane -R",
    },
    .{
        .table = "prefix",
        .key = '<',
        .note = "Display window menu",
        .command = "display-menu -xW -yW -T '#[align=centre]#{window_index}:#{window_name}'" ++ default_window_menu,
    },
    .{
        .table = "prefix",
        .key = '>',
        .note = "Display pane menu",
        .command = "display-menu -xP -yP -T '#[align=centre]#{pane_index} (#{pane_id})'" ++ default_pane_menu,
    },
    .{
        .table = "root",
        .key_name = "MouseDown1Pane",
        .command = "select-pane -t =; send -M",
    },
    .{
        .table = "root",
        .key_name = "C-MouseDown1Pane",
        .command = "swap-pane -s @",
    },
    .{
        .table = "root",
        .key_name = "MouseDrag1Pane",
        .command = "if -F '#{||:#{pane_in_mode},#{mouse_any_flag}}' \"send -M\" \"copy-mode -M\"",
    },
    .{
        .table = "root",
        .key_name = "WheelUpPane",
        .command = "if -F '#{||:#{alternate_on},#{pane_in_mode},#{mouse_any_flag}}' \"send -M\" \"copy-mode -e -t =\"",
    },
    .{
        .table = "root",
        .key_name = "MouseDown2Pane",
        .command = "select-pane -t =; if -F '#{||:#{pane_in_mode},#{mouse_any_flag}}' \"send -M\" \"paste-buffer -p\"",
    },
    .{
        .table = "root",
        .key_name = "DoubleClick1Pane",
        .command = "select-pane -t =; if -F '#{||:#{pane_in_mode},#{mouse_any_flag}}' \"send -M\" \"copy-mode -H -t =; send -X select-word; run -d0.3; send -X copy-pipe-and-cancel\"",
    },
    .{
        .table = "root",
        .key_name = "TripleClick1Pane",
        .command = "select-pane -t =; if -F '#{||:#{pane_in_mode},#{mouse_any_flag}}' \"send -M\" \"copy-mode -H -t =; send -X select-line; run -d0.3; send -X copy-pipe-and-cancel\"",
    },
    .{
        .table = "root",
        .key_name = "MouseDrag1Border",
        .command = "resize-pane -M",
    },
    .{
        .table = "root",
        .key_name = "MouseDown1Status",
        .command = "switch-client -t =",
    },
    .{
        .table = "root",
        .key_name = "C-MouseDown1Status",
        .command = "swap-window -t @",
    },
    .{
        .table = "root",
        .key_name = "WheelDownStatus",
        .command = "select-window -t +",
    },
    .{
        .table = "root",
        .key_name = "WheelUpStatus",
        .command = "select-window -t -",
    },
    .{
        .table = "root",
        .key_name = "MouseDown3StatusLeft",
        .command = "display-menu -t = -xM -yW -T '#[align=centre]#{session_name}'" ++ default_session_menu,
    },
    .{
        .table = "root",
        .key_name = "M-MouseDown3StatusLeft",
        .command = "display-menu -t = -xM -yW -T '#[align=centre]#{session_name}'" ++ default_session_menu,
    },
    .{
        .table = "root",
        .key_name = "MouseDown3Status",
        .command = "display-menu -t = -xW -yW -T '#[align=centre]#{window_index}:#{window_name}'" ++ default_window_menu,
    },
    .{
        .table = "root",
        .key_name = "M-MouseDown3Status",
        .command = "display-menu -t = -xW -yW -T '#[align=centre]#{window_index}:#{window_name}'" ++ default_window_menu,
    },
    .{
        .table = "root",
        .key_name = "MouseDown3Pane",
        .argv = default_mouse_down3_pane_argv[0..],
    },
    .{
        .table = "root",
        .key_name = "M-MouseDown3Pane",
        .command = default_pane_menu_display,
    },
    .{
        .table = "root",
        .key_name = "MouseDown1ScrollbarUp",
        .command = "if -Ft= '#{pane_in_mode}' \"send -Xt= page-up\" \"copy-mode -u -t =\"",
    },
    .{
        .table = "root",
        .key_name = "MouseDown1ScrollbarDown",
        .command = "if -Ft= '#{pane_in_mode}' \"send -Xt= page-down\" \"copy-mode -d -t =\"",
    },
    .{
        .table = "root",
        .key_name = "MouseDrag1ScrollbarSlider",
        .command = "if -Ft= '#{pane_in_mode}' \"send -Xt= scroll-to-mouse\" \"copy-mode -S -t =\"",
    },
    .{
        .table = "copy-mode",
        .key_name = "C-Space",
        .command = "send -X begin-selection",
    },
    .{
        .table = "copy-mode",
        .key_name = "C-a",
        .command = "send -X start-of-line",
    },
    .{
        .table = "copy-mode",
        .key_name = "C-c",
        .command = "send -X cancel",
    },
    .{
        .table = "copy-mode",
        .key_name = "C-e",
        .command = "send -X end-of-line",
    },
    .{
        .table = "copy-mode",
        .key_name = "C-f",
        .command = "send -X cursor-right",
    },
    .{
        .table = "copy-mode",
        .key_name = "C-b",
        .command = "send -X cursor-left",
    },
    .{
        .table = "copy-mode",
        .key_name = "C-g",
        .command = "send -X clear-selection",
    },
    .{
        .table = "copy-mode",
        .key_name = "C-k",
        .command = "send -X copy-pipe-end-of-line-and-cancel",
    },
    .{
        .table = "copy-mode",
        .key_name = "C-l",
        .command = "send -X cursor-centre-vertical",
    },
    .{
        .table = "copy-mode",
        .key_name = "M-l",
        .command = "send -X cursor-centre-horizontal",
    },
    .{
        .table = "copy-mode",
        .key_name = "C-n",
        .command = "send -X cursor-down",
    },
    .{
        .table = "copy-mode",
        .key_name = "C-p",
        .command = "send -X cursor-up",
    },
    .{
        .table = "copy-mode",
        .key_name = "C-r",
        .command = "command-prompt -T search -ip'(search up)' -I'#{pane_search_string}' \"send -X search-backward-incremental -- '%%'\"",
    },
    .{
        .table = "copy-mode",
        .key_name = "C-s",
        .command = "command-prompt -T search -ip'(search down)' -I'#{pane_search_string}' \"send -X search-forward-incremental -- '%%'\"",
    },
    .{
        .table = "copy-mode",
        .key_name = "C-v",
        .command = "send -X page-down",
    },
    .{
        .table = "copy-mode",
        .key_name = "C-w",
        .command = "send -X copy-pipe-and-cancel",
    },
    .{
        .table = "copy-mode",
        .key_name = "Escape",
        .command = "send -X cancel",
    },
    .{
        .table = "copy-mode",
        .key_name = "Space",
        .command = "send -X page-down",
    },
    .{
        .table = "copy-mode",
        .key_name = ",",
        .command = "send -X jump-reverse",
    },
    .{
        .table = "copy-mode",
        .key_name = ";",
        .command = "send -X jump-again",
    },
    .{
        .table = "copy-mode",
        .key_name = "F",
        .command = "command-prompt -1p'(jump backward)' \"send -X jump-backward -- '%%'\"",
    },
    .{
        .table = "copy-mode",
        .key_name = "N",
        .command = "send -X search-reverse",
    },
    .{
        .table = "copy-mode",
        .key_name = "P",
        .command = "send -X toggle-position",
    },
    .{
        .table = "copy-mode",
        .key_name = "R",
        .command = "send -X rectangle-toggle",
    },
    .{
        .table = "copy-mode",
        .key_name = "T",
        .command = "command-prompt -1p'(jump to backward)' \"send -X jump-to-backward -- '%%'\"",
    },
    .{
        .table = "copy-mode",
        .key_name = "X",
        .command = "send -X set-mark",
    },
    .{
        .table = "copy-mode",
        .key_name = "f",
        .command = "command-prompt -1p'(jump forward)' \"send -X jump-forward -- '%%'\"",
    },
    .{
        .table = "copy-mode",
        .key_name = "g",
        .command = "command-prompt -p'(goto line)' \"send -X goto-line -- '%%'\"",
    },
    .{
        .table = "copy-mode",
        .key_name = "n",
        .command = "send -X search-again",
    },
    .{
        .table = "copy-mode",
        .key_name = "q",
        .command = "send -X cancel",
    },
    .{
        .table = "copy-mode",
        .key_name = "r",
        .command = "send -X refresh-from-pane",
    },
    .{
        .table = "copy-mode",
        .key_name = "t",
        .command = "command-prompt -1p'(jump to forward)' \"send -X jump-to-forward -- '%%'\"",
    },
    .{
        .table = "copy-mode",
        .key_name = "Home",
        .command = "send -X start-of-line",
    },
    .{
        .table = "copy-mode",
        .key_name = "End",
        .command = "send -X end-of-line",
    },
    .{
        .table = "copy-mode",
        .key_name = "MouseDown1Pane",
        .command = "select-pane",
    },
    .{
        .table = "copy-mode",
        .key_name = "MouseDrag1Pane",
        .command = "select-pane; send -X begin-selection",
    },
    .{
        .table = "copy-mode",
        .key_name = "MouseDragEnd1Pane",
        .command = "send -X copy-pipe-and-cancel",
    },
    .{
        .table = "copy-mode",
        .key_name = "WheelUpPane",
        .command = "select-pane; send -N5 -X scroll-up",
    },
    .{
        .table = "copy-mode",
        .key_name = "WheelDownPane",
        .command = "select-pane; send -N5 -X scroll-down",
    },
    .{
        .table = "copy-mode",
        .key_name = "DoubleClick1Pane",
        .command = "select-pane; send -X select-word; run -d0.3; send -X copy-pipe-and-cancel",
    },
    .{
        .table = "copy-mode",
        .key_name = "TripleClick1Pane",
        .command = "select-pane; send -X select-line; run -d0.3; send -X copy-pipe-and-cancel",
    },
    .{
        .table = "copy-mode",
        .key_name = "NPage",
        .command = "send -X page-down",
    },
    .{
        .table = "copy-mode",
        .key_name = "PPage",
        .command = "send -X page-up",
    },
    .{
        .table = "copy-mode",
        .key_name = "Up",
        .command = "send -X cursor-up",
    },
    .{
        .table = "copy-mode",
        .key_name = "Down",
        .command = "send -X cursor-down",
    },
    .{
        .table = "copy-mode",
        .key_name = "Left",
        .command = "send -X cursor-left",
    },
    .{
        .table = "copy-mode",
        .key_name = "Right",
        .command = "send -X cursor-right",
    },
    .{
        .table = "copy-mode",
        .key_name = "M-1",
        .command = "command-prompt -Np'(repeat)' -I1 \"send -N '%%'\"",
    },
    .{
        .table = "copy-mode",
        .key_name = "M-2",
        .command = "command-prompt -Np'(repeat)' -I2 \"send -N '%%'\"",
    },
    .{
        .table = "copy-mode",
        .key_name = "M-3",
        .command = "command-prompt -Np'(repeat)' -I3 \"send -N '%%'\"",
    },
    .{
        .table = "copy-mode",
        .key_name = "M-4",
        .command = "command-prompt -Np'(repeat)' -I4 \"send -N '%%'\"",
    },
    .{
        .table = "copy-mode",
        .key_name = "M-5",
        .command = "command-prompt -Np'(repeat)' -I5 \"send -N '%%'\"",
    },
    .{
        .table = "copy-mode",
        .key_name = "M-6",
        .command = "command-prompt -Np'(repeat)' -I6 \"send -N '%%'\"",
    },
    .{
        .table = "copy-mode",
        .key_name = "M-7",
        .command = "command-prompt -Np'(repeat)' -I7 \"send -N '%%'\"",
    },
    .{
        .table = "copy-mode",
        .key_name = "M-8",
        .command = "command-prompt -Np'(repeat)' -I8 \"send -N '%%'\"",
    },
    .{
        .table = "copy-mode",
        .key_name = "M-9",
        .command = "command-prompt -Np'(repeat)' -I9 \"send -N '%%'\"",
    },
    .{
        .table = "copy-mode",
        .key_name = "M-<",
        .command = "send -X history-top",
    },
    .{
        .table = "copy-mode",
        .key_name = "M->",
        .command = "send -X history-bottom",
    },
    .{
        .table = "copy-mode",
        .key_name = "M-R",
        .command = "send -X top-line",
    },
    .{
        .table = "copy-mode",
        .key_name = "M-b",
        .command = "send -X previous-word",
    },
    .{
        .table = "copy-mode",
        .key_name = "C-M-b",
        .command = "send -X previous-matching-bracket",
    },
    .{
        .table = "copy-mode",
        .key_name = "M-f",
        .command = "send -X next-word-end",
    },
    .{
        .table = "copy-mode",
        .key_name = "C-M-f",
        .command = "send -X next-matching-bracket",
    },
    .{
        .table = "copy-mode",
        .key_name = "M-m",
        .command = "send -X back-to-indentation",
    },
    .{
        .table = "copy-mode",
        .key_name = "M-r",
        .command = "send -X middle-line",
    },
    .{
        .table = "copy-mode",
        .key_name = "M-v",
        .command = "send -X page-up",
    },
    .{
        .table = "copy-mode",
        .key_name = "M-w",
        .command = "send -X copy-pipe-and-cancel",
    },
    .{
        .table = "copy-mode",
        .key_name = "M-x",
        .command = "send -X jump-to-mark",
    },
    .{
        .table = "copy-mode",
        .key_name = "M-{",
        .command = "send -X previous-paragraph",
    },
    .{
        .table = "copy-mode",
        .key_name = "M-}",
        .command = "send -X next-paragraph",
    },
    .{
        .table = "copy-mode",
        .key_name = "M-Up",
        .command = "send -X halfpage-up",
    },
    .{
        .table = "copy-mode",
        .key_name = "M-Down",
        .command = "send -X halfpage-down",
    },
    .{
        .table = "copy-mode",
        .key_name = "C-Up",
        .command = "send -X scroll-up",
    },
    .{
        .table = "copy-mode",
        .key_name = "C-Down",
        .command = "send -X scroll-down",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "#",
        .command = "send -FX search-backward -- '#{copy_cursor_word}'",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "*",
        .command = "send -FX search-forward -- '#{copy_cursor_word}'",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "C-c",
        .command = "send -X cancel",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "C-d",
        .command = "send -X halfpage-down",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "C-e",
        .command = "send -X scroll-down",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "C-b",
        .command = "send -X page-up",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "C-f",
        .command = "send -X page-down",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "C-h",
        .command = "send -X cursor-left",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "C-j",
        .command = "send -X copy-pipe-and-cancel",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "Enter",
        .command = "send -X copy-pipe-and-cancel",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "C-u",
        .command = "send -X halfpage-up",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "C-v",
        .command = "send -X rectangle-toggle",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "C-y",
        .command = "send -X scroll-up",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "Escape",
        .command = "send -X clear-selection",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "Space",
        .command = "send -X begin-selection",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "$",
        .command = "send -X end-of-line",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = ",",
        .command = "send -X jump-reverse",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "/",
        .command = "command-prompt -T search -p'(search down)' \"send -X search-forward -- '%%'\"",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "0",
        .command = "send -X start-of-line",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "1",
        .command = "command-prompt -Np'(repeat)' -I1 \"send -N '%%'\"",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "2",
        .command = "command-prompt -Np'(repeat)' -I2 \"send -N '%%'\"",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "3",
        .command = "command-prompt -Np'(repeat)' -I3 \"send -N '%%'\"",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "4",
        .command = "command-prompt -Np'(repeat)' -I4 \"send -N '%%'\"",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "5",
        .command = "command-prompt -Np'(repeat)' -I5 \"send -N '%%'\"",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "6",
        .command = "command-prompt -Np'(repeat)' -I6 \"send -N '%%'\"",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "7",
        .command = "command-prompt -Np'(repeat)' -I7 \"send -N '%%'\"",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "8",
        .command = "command-prompt -Np'(repeat)' -I8 \"send -N '%%'\"",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "9",
        .command = "command-prompt -Np'(repeat)' -I9 \"send -N '%%'\"",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = ":",
        .command = "command-prompt -p'(goto line)' \"send -X goto-line -- '%%'\"",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = ";",
        .command = "send -X jump-again",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "?",
        .command = "command-prompt -T search -p'(search up)' \"send -X search-backward -- '%%'\"",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "A",
        .command = "send -X append-selection-and-cancel",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "B",
        .command = "send -X previous-space",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "D",
        .command = "send -X copy-pipe-end-of-line-and-cancel",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "E",
        .command = "send -X next-space-end",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "F",
        .command = "command-prompt -1p'(jump backward)' \"send -X jump-backward -- '%%'\"",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "G",
        .command = "send -X history-bottom",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "H",
        .command = "send -X top-line",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "J",
        .command = "send -X scroll-down",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "K",
        .command = "send -X scroll-up",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "L",
        .command = "send -X bottom-line",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "M",
        .command = "send -X middle-line",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "N",
        .command = "send -X search-reverse",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "P",
        .command = "send -X toggle-position",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "T",
        .command = "command-prompt -1p'(jump to backward)' \"send -X jump-to-backward -- '%%'\"",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "V",
        .command = "send -X select-line",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "W",
        .command = "send -X next-space",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "X",
        .command = "send -X set-mark",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "^",
        .command = "send -X back-to-indentation",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "b",
        .command = "send -X previous-word",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "e",
        .command = "send -X next-word-end",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "f",
        .command = "command-prompt -1p'(jump forward)' \"send -X jump-forward -- '%%'\"",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "g",
        .command = "send -X history-top",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "h",
        .command = "send -X cursor-left",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "j",
        .command = "send -X cursor-down",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "k",
        .command = "send -X cursor-up",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "z",
        .command = "send -X scroll-middle",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "l",
        .command = "send -X cursor-right",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "n",
        .command = "send -X search-again",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "o",
        .command = "send -X other-end",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "q",
        .command = "send -X cancel",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "r",
        .command = "send -X refresh-from-pane",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "t",
        .command = "command-prompt -1p'(jump to forward)' \"send -X jump-to-forward -- '%%'\"",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "v",
        .command = "send -X rectangle-toggle",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "w",
        .command = "send -X next-word",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "{",
        .command = "send -X previous-paragraph",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "}",
        .command = "send -X next-paragraph",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "%",
        .command = "send -X next-matching-bracket",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "Home",
        .command = "send -X start-of-line",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "End",
        .command = "send -X end-of-line",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "MouseDown1Pane",
        .command = "select-pane",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "MouseDrag1Pane",
        .command = "select-pane; send -X begin-selection",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "MouseDragEnd1Pane",
        .command = "send -X copy-pipe-and-cancel",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "WheelUpPane",
        .command = "select-pane; send -N5 -X scroll-up",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "WheelDownPane",
        .command = "select-pane; send -N5 -X scroll-down",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "DoubleClick1Pane",
        .command = "select-pane; send -X select-word; run -d0.3; send -X copy-pipe-and-cancel",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "TripleClick1Pane",
        .command = "select-pane; send -X select-line; run -d0.3; send -X copy-pipe-and-cancel",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "BSpace",
        .command = "send -X cursor-left",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "NPage",
        .command = "send -X page-down",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "PPage",
        .command = "send -X page-up",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "Up",
        .command = "send -X cursor-up",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "Down",
        .command = "send -X cursor-down",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "Left",
        .command = "send -X cursor-left",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "Right",
        .command = "send -X cursor-right",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "M-x",
        .command = "send -X jump-to-mark",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "C-Up",
        .command = "send -X scroll-up",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "C-Down",
        .command = "send -X scroll-down",
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
        .table = "buffer-mode",
        .key = 'q',
        .note = "Exit buffer mode",
        .argv = default_buffer_mode_cancel_argv[0..],
    },
    .{
        .table = "buffer-mode",
        .key = T.C0_ESC,
        .note = "Exit buffer mode",
        .argv = default_buffer_mode_cancel_argv[0..],
    },
    .{
        .table = "buffer-mode",
        .key = '\r',
        .note = "Paste selected buffer",
        .argv = default_buffer_mode_choose_argv[0..],
    },
    .{
        .table = "buffer-mode",
        .key = 'p',
        .note = "Paste selected buffer",
        .argv = default_buffer_mode_paste_argv[0..],
    },
    .{
        .table = "buffer-mode",
        .key = 'P',
        .note = "Paste tagged buffers",
        .argv = default_buffer_mode_paste_tagged_argv[0..],
    },
    .{
        .table = "buffer-mode",
        .key = 'e',
        .note = "Edit selected buffer",
        .argv = default_buffer_mode_edit_selected_argv[0..],
    },
    .{
        .table = "buffer-mode",
        .key = 'd',
        .note = "Delete selected buffer",
        .argv = default_buffer_mode_delete_argv[0..],
    },
    .{
        .table = "buffer-mode",
        .key = 'D',
        .note = "Delete tagged buffers",
        .argv = default_buffer_mode_delete_tagged_argv[0..],
    },
    .{
        .table = "buffer-mode",
        .key = 'f',
        .note = "Filter buffers",
        .argv = default_buffer_mode_filter_argv[0..],
    },
    .{
        .table = "buffer-mode",
        .key = 't',
        .note = "Tag buffer",
        .argv = default_buffer_mode_tag_argv[0..],
    },
    .{
        .table = "buffer-mode",
        .key = 'T',
        .note = "Clear all tagged buffers",
        .argv = default_buffer_mode_tag_none_argv[0..],
    },
    .{
        .table = "buffer-mode",
        .key = 't' | T.KEYC_CTRL,
        .note = "Tag all buffers",
        .argv = default_buffer_mode_tag_all_argv[0..],
    },
    .{
        .table = "buffer-mode",
        .key = T.KEYC_UP,
        .note = "Move up",
        .argv = default_buffer_mode_cursor_up_argv[0..],
    },
    .{
        .table = "buffer-mode",
        .key = T.KEYC_DOWN,
        .note = "Move down",
        .argv = default_buffer_mode_cursor_down_argv[0..],
    },
    .{
        .table = "buffer-mode",
        .key = T.KEYC_PPAGE,
        .note = "Page up",
        .argv = default_buffer_mode_page_up_argv[0..],
    },
    .{
        .table = "buffer-mode",
        .key = T.KEYC_NPAGE,
        .note = "Page down",
        .argv = default_buffer_mode_page_down_argv[0..],
    },
    .{
        .table = "buffer-mode-vi",
        .key = 'q',
        .note = "Exit buffer mode",
        .argv = default_buffer_mode_cancel_argv[0..],
    },
    .{
        .table = "buffer-mode-vi",
        .key = T.C0_ESC,
        .note = "Exit buffer mode",
        .argv = default_buffer_mode_cancel_argv[0..],
    },
    .{
        .table = "buffer-mode-vi",
        .key = '\r',
        .note = "Paste selected buffer",
        .argv = default_buffer_mode_choose_argv[0..],
    },
    .{
        .table = "buffer-mode-vi",
        .key = 'p',
        .note = "Paste selected buffer",
        .argv = default_buffer_mode_paste_argv[0..],
    },
    .{
        .table = "buffer-mode-vi",
        .key = 'P',
        .note = "Paste tagged buffers",
        .argv = default_buffer_mode_paste_tagged_argv[0..],
    },
    .{
        .table = "buffer-mode-vi",
        .key = 'e',
        .note = "Edit selected buffer",
        .argv = default_buffer_mode_edit_selected_argv[0..],
    },
    .{
        .table = "buffer-mode-vi",
        .key = 'd',
        .note = "Delete selected buffer",
        .argv = default_buffer_mode_delete_argv[0..],
    },
    .{
        .table = "buffer-mode-vi",
        .key = 'D',
        .note = "Delete tagged buffers",
        .argv = default_buffer_mode_delete_tagged_argv[0..],
    },
    .{
        .table = "buffer-mode-vi",
        .key = 'f',
        .note = "Filter buffers",
        .argv = default_buffer_mode_filter_argv[0..],
    },
    .{
        .table = "buffer-mode-vi",
        .key = 't',
        .note = "Tag buffer",
        .argv = default_buffer_mode_tag_argv[0..],
    },
    .{
        .table = "buffer-mode-vi",
        .key = 'T',
        .note = "Clear all tagged buffers",
        .argv = default_buffer_mode_tag_none_argv[0..],
    },
    .{
        .table = "buffer-mode-vi",
        .key = 't' | T.KEYC_CTRL,
        .note = "Tag all buffers",
        .argv = default_buffer_mode_tag_all_argv[0..],
    },
    .{
        .table = "buffer-mode-vi",
        .key = 'k',
        .note = "Move up",
        .argv = default_buffer_mode_cursor_up_argv[0..],
    },
    .{
        .table = "buffer-mode-vi",
        .key = 'j',
        .note = "Move down",
        .argv = default_buffer_mode_cursor_down_argv[0..],
    },
    .{
        .table = "buffer-mode-vi",
        .key = T.KEYC_UP,
        .note = "Move up",
        .argv = default_buffer_mode_cursor_up_argv[0..],
    },
    .{
        .table = "buffer-mode-vi",
        .key = T.KEYC_DOWN,
        .note = "Move down",
        .argv = default_buffer_mode_cursor_down_argv[0..],
    },
    .{
        .table = "buffer-mode-vi",
        .key = T.KEYC_PPAGE,
        .note = "Page up",
        .argv = default_buffer_mode_page_up_argv[0..],
    },
    .{
        .table = "buffer-mode-vi",
        .key = T.KEYC_NPAGE,
        .note = "Page down",
        .argv = default_buffer_mode_page_down_argv[0..],
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
        .key = '<',
        .note = "Scroll previews left",
        .argv = default_tree_mode_scroll_left_argv[0..],
    },
    .{
        .table = "tree-mode",
        .key = '>',
        .note = "Scroll previews right",
        .argv = default_tree_mode_scroll_right_argv[0..],
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
        .key = '<',
        .note = "Scroll previews left",
        .argv = default_tree_mode_scroll_left_argv[0..],
    },
    .{
        .table = "tree-mode-vi",
        .key = '>',
        .note = "Scroll previews right",
        .argv = default_tree_mode_scroll_right_argv[0..],
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
    .{
        .table = "options-mode",
        .key = 'q',
        .note = "Exit options mode",
        .argv = default_options_mode_cancel_argv[0..],
    },
    .{
        .table = "options-mode",
        .key = T.C0_ESC,
        .note = "Exit options mode",
        .argv = default_options_mode_cancel_argv[0..],
    },
    .{
        .table = "options-mode",
        .key = '\r',
        .note = "Inspect selected option",
        .argv = default_options_mode_choose_argv[0..],
    },
    .{
        .table = "options-mode",
        .key = T.KEYC_UP,
        .note = "Move up",
        .argv = default_options_mode_cursor_up_argv[0..],
    },
    .{
        .table = "options-mode",
        .key = T.KEYC_DOWN,
        .note = "Move down",
        .argv = default_options_mode_cursor_down_argv[0..],
    },
    .{
        .table = "options-mode",
        .key = T.KEYC_PPAGE,
        .note = "Page up",
        .argv = default_options_mode_page_up_argv[0..],
    },
    .{
        .table = "options-mode",
        .key = T.KEYC_NPAGE,
        .note = "Page down",
        .argv = default_options_mode_page_down_argv[0..],
    },
    .{
        .table = "options-mode",
        .key = T.KEYC_LEFT,
        .note = "Collapse current section",
        .argv = default_options_mode_collapse_argv[0..],
    },
    .{
        .table = "options-mode",
        .key = T.KEYC_RIGHT,
        .note = "Expand current section",
        .argv = default_options_mode_expand_argv[0..],
    },
    .{
        .table = "options-mode",
        .key = 'd',
        .note = "Reset selected option to default",
        .argv = default_options_mode_reset_current_argv[0..],
    },
    .{
        .table = "options-mode",
        .key = 'u',
        .note = "Unset selected option",
        .argv = default_options_mode_unset_current_argv[0..],
    },
    .{
        .table = "options-mode",
        .key = 'H',
        .note = "Toggle inherited options",
        .argv = default_options_mode_toggle_hide_inherited_argv[0..],
    },
    .{
        .table = "options-mode-vi",
        .key = 'q',
        .note = "Exit options mode",
        .argv = default_options_mode_cancel_argv[0..],
    },
    .{
        .table = "options-mode-vi",
        .key = T.C0_ESC,
        .note = "Exit options mode",
        .argv = default_options_mode_cancel_argv[0..],
    },
    .{
        .table = "options-mode-vi",
        .key = '\r',
        .note = "Inspect selected option",
        .argv = default_options_mode_choose_argv[0..],
    },
    .{
        .table = "options-mode-vi",
        .key = 'k',
        .note = "Move up",
        .argv = default_options_mode_cursor_up_argv[0..],
    },
    .{
        .table = "options-mode-vi",
        .key = 'j',
        .note = "Move down",
        .argv = default_options_mode_cursor_down_argv[0..],
    },
    .{
        .table = "options-mode-vi",
        .key = T.KEYC_UP,
        .note = "Move up",
        .argv = default_options_mode_cursor_up_argv[0..],
    },
    .{
        .table = "options-mode-vi",
        .key = T.KEYC_DOWN,
        .note = "Move down",
        .argv = default_options_mode_cursor_down_argv[0..],
    },
    .{
        .table = "options-mode-vi",
        .key = T.KEYC_PPAGE,
        .note = "Page up",
        .argv = default_options_mode_page_up_argv[0..],
    },
    .{
        .table = "options-mode-vi",
        .key = T.KEYC_NPAGE,
        .note = "Page down",
        .argv = default_options_mode_page_down_argv[0..],
    },
    .{
        .table = "options-mode-vi",
        .key = 'h',
        .note = "Collapse current section",
        .argv = default_options_mode_collapse_argv[0..],
    },
    .{
        .table = "options-mode-vi",
        .key = 'l',
        .note = "Expand current section",
        .argv = default_options_mode_expand_argv[0..],
    },
    .{
        .table = "options-mode-vi",
        .key = T.KEYC_LEFT,
        .note = "Collapse current section",
        .argv = default_options_mode_collapse_argv[0..],
    },
    .{
        .table = "options-mode-vi",
        .key = T.KEYC_RIGHT,
        .note = "Expand current section",
        .argv = default_options_mode_expand_argv[0..],
    },
    .{
        .table = "options-mode-vi",
        .key = 'd',
        .note = "Reset selected option to default",
        .argv = default_options_mode_reset_current_argv[0..],
    },
    .{
        .table = "options-mode-vi",
        .key = 'u',
        .note = "Unset selected option",
        .argv = default_options_mode_unset_current_argv[0..],
    },
    .{
        .table = "options-mode-vi",
        .key = 'H',
        .note = "Toggle inherited options",
        .argv = default_options_mode_toggle_hide_inherited_argv[0..],
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
