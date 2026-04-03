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
// Ported in part from tmux/format.c.
// Original copyright:
//   Copyright (c) 2011 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence - same terms as above.

//! format-resolve.zig - resolver table and individual format resolvers.

const std = @import("std");
const T = @import("types.zig");
const c = @import("c.zig");
const cmd_render = @import("cmd-render.zig");
const cmdq = @import("cmd-queue.zig");
const colour = @import("colour.zig");
const grid = @import("grid.zig");
const hyperlinks = @import("hyperlinks.zig");
const log = @import("log.zig");
const mouse_runtime = @import("mouse-runtime.zig");
const opts = @import("options.zig");
const proc_mod = @import("proc.zig");
const screen_mod = @import("screen.zig");
const sort_mod = @import("sort.zig");
const srv = @import("server.zig");
const regsub_mod = @import("regsub.zig");
const tty_features = @import("tty-features.zig");
const tty_mod = @import("tty.zig");
const utf8 = @import("utf8.zig");
const xm = @import("xmalloc.zig");
const client_registry = @import("client-registry.zig");
const key_string = @import("key-string.zig");
const names = @import("names.zig");
const paste_mod = @import("paste.zig");
const layout_mod = @import("layout.zig");
const marked_pane_mod = @import("marked-pane.zig");
const sess = @import("session.zig");
const window_mod = @import("window.zig");
const window_copy = @import("window-copy.zig");

const fmt = @import("format.zig");

pub const FormatContext = fmt.FormatContext;
pub const FormatExpandResult = fmt.FormatExpandResult;
pub const FormatType = fmt.FormatType;

pub const Resolver = struct {
    name: []const u8,
    func: *const fn (std.mem.Allocator, *const FormatContext) ?[]u8,
};

pub const FORMAT_LOOP_LIMIT: u32 = 100;

pub const resolver_table = [_]Resolver{
    .{ .name = "message", .func = resolve_message },
    .{ .name = "message_number", .func = resolve_message_number },
    .{ .name = "message_time", .func = resolve_message_time },
    .{ .name = "message_text", .func = resolve_message_text },
    .{ .name = "command", .func = resolve_command },
    .{ .name = "command_prompt", .func = resolve_command_prompt },
    .{ .name = "hook", .func = resolve_hook },
    .{ .name = "hook_client", .func = resolve_hook_client },
    .{ .name = "hook_session", .func = resolve_hook_session },
    .{ .name = "hook_session_name", .func = resolve_hook_session_name },
    .{ .name = "hook_window", .func = resolve_hook_window },
    .{ .name = "hook_window_name", .func = resolve_hook_window_name },
    .{ .name = "hook_pane", .func = resolve_hook_pane },

    .{ .name = "client_activity", .func = resolve_client_activity },
    .{ .name = "client_cell_height", .func = resolve_client_cell_height },
    .{ .name = "client_cell_width", .func = resolve_client_cell_width },
    .{ .name = "client_control_mode", .func = resolve_client_control_mode },
    .{ .name = "client_created", .func = resolve_client_created },
    .{ .name = "client_discarded", .func = resolve_client_discarded },
    .{ .name = "client_flags", .func = resolve_client_flags },
    .{ .name = "client_height", .func = resolve_client_height },
    .{ .name = "client_key_table", .func = resolve_client_key_table },
    .{ .name = "client_last_session", .func = resolve_client_last_session },
    .{ .name = "client_name", .func = resolve_client_name },
    .{ .name = "client_pid", .func = resolve_client_pid },
    .{ .name = "client_prefix", .func = resolve_client_prefix },
    .{ .name = "client_readonly", .func = resolve_client_readonly },
    .{ .name = "client_session", .func = resolve_client_session },
    .{ .name = "client_session_name", .func = resolve_client_session_name },
    .{ .name = "client_termfeatures", .func = resolve_client_termfeatures },
    .{ .name = "client_tty", .func = resolve_client_tty },
    .{ .name = "client_termname", .func = resolve_client_termname },
    .{ .name = "client_termtype", .func = resolve_client_termtype },
    .{ .name = "client_theme", .func = resolve_client_theme },
    .{ .name = "client_uid", .func = resolve_client_uid },
    .{ .name = "client_user", .func = resolve_client_user },
    .{ .name = "client_utf8", .func = resolve_client_utf8 },
    .{ .name = "client_utf", .func = resolve_client_utf },
    .{ .name = "client_mode_format", .func = resolve_client_mode_format },
    .{ .name = "client_width", .func = resolve_client_width },
    .{ .name = "client_written", .func = resolve_client_written },

    .{ .name = "command_alias", .func = resolve_command_alias },
    .{ .name = "command_name", .func = resolve_command_name },
    .{ .name = "command_usage", .func = resolve_command_usage },
    .{ .name = "is_key", .func = resolve_is_key },
    .{ .name = "is_option", .func = resolve_is_option },
    .{ .name = "option_inherited", .func = resolve_option_inherited },
    .{ .name = "option_is_global", .func = resolve_option_is_global },
    .{ .name = "option_name", .func = resolve_option_name },
    .{ .name = "option_scope", .func = resolve_option_scope },
    .{ .name = "option_unit", .func = resolve_option_unit },
    .{ .name = "option_value", .func = resolve_option_value },

    .{ .name = "key_command", .func = resolve_key_command },
    .{ .name = "key_has_repeat", .func = resolve_key_has_repeat },
    .{ .name = "key_note", .func = resolve_key_note },
    .{ .name = "key_prefix", .func = resolve_key_prefix },
    .{ .name = "key_repeat", .func = resolve_key_repeat },
    .{ .name = "key_string", .func = resolve_key_string },
    .{ .name = "key_string_width", .func = resolve_key_string_width },
    .{ .name = "key_table", .func = resolve_key_table },
    .{ .name = "key_table_width", .func = resolve_key_table_width },
    .{ .name = "loop_last_flag", .func = resolve_loop_last_flag },
    .{ .name = "notes_only", .func = resolve_notes_only },

    .{ .name = "host", .func = resolve_host },
    .{ .name = "host_short", .func = resolve_host_short },
    .{ .name = "config_files", .func = resolve_config_files },
    .{ .name = "line", .func = resolve_line },

    .{ .name = "pid", .func = resolve_pid },
    .{ .name = "next_session_id", .func = resolve_next_session_id },
    .{ .name = "origin_flag", .func = resolve_origin_flag },
    .{ .name = "server_sessions", .func = resolve_server_sessions },
    .{ .name = "socket_path", .func = resolve_socket_path },
    .{ .name = "start_time", .func = resolve_start_time },

    .{ .name = "alternate_on", .func = resolve_alternate_on },
    .{ .name = "alternate_saved_x", .func = resolve_alternate_saved_x },
    .{ .name = "alternate_saved_y", .func = resolve_alternate_saved_y },
    .{ .name = "buffer_created", .func = resolve_buffer_created },
    .{ .name = "buffer_full", .func = resolve_buffer_full },
    .{ .name = "buffer_name", .func = resolve_buffer_name },
    .{ .name = "buffer_sample", .func = resolve_buffer_sample },
    .{ .name = "buffer_size", .func = resolve_buffer_size },
    .{ .name = "bracket_paste_flag", .func = resolve_bracket_paste_flag },
    .{ .name = "buffer_mode_format", .func = resolve_buffer_mode_format },
    .{ .name = "cursor_blinking", .func = resolve_cursor_blinking },
    .{ .name = "cursor_character", .func = resolve_cursor_character },
    .{ .name = "cursor_colour", .func = resolve_cursor_colour },
    .{ .name = "cursor_flag", .func = resolve_cursor_flag },
    .{ .name = "cursor_shape", .func = resolve_cursor_shape },
    .{ .name = "cursor_very_visible", .func = resolve_cursor_very_visible },
    .{ .name = "cursor_x", .func = resolve_cursor_x },
    .{ .name = "cursor_y", .func = resolve_cursor_y },
    .{ .name = "history_all_bytes", .func = resolve_history_all_bytes },
    .{ .name = "history_bytes", .func = resolve_history_bytes },
    .{ .name = "history_limit", .func = resolve_history_limit },
    .{ .name = "history_size", .func = resolve_history_size },
    .{ .name = "insert_flag", .func = resolve_insert_flag },
    .{ .name = "keypad_cursor_flag", .func = resolve_keypad_cursor_flag },
    .{ .name = "keypad_flag", .func = resolve_keypad_flag },
    .{ .name = "mouse_all_flag", .func = resolve_mouse_all_flag },
    .{ .name = "mouse_any_flag", .func = resolve_mouse_any_flag },
    .{ .name = "mouse_button_flag", .func = resolve_mouse_button_flag },
    .{ .name = "mouse_hyperlink", .func = resolve_mouse_hyperlink },
    .{ .name = "mouse_line", .func = resolve_mouse_line },
    .{ .name = "mouse_pane", .func = resolve_mouse_pane },
    .{ .name = "mouse_sgr_flag", .func = resolve_mouse_sgr_flag },
    .{ .name = "mouse_standard_flag", .func = resolve_mouse_standard_flag },
    .{ .name = "mouse_status_line", .func = resolve_mouse_status_line },
    .{ .name = "mouse_status_range", .func = resolve_mouse_status_range },
    .{ .name = "mouse_utf8_flag", .func = resolve_mouse_utf8_flag },
    .{ .name = "mouse_utf", .func = resolve_mouse_utf },
    .{ .name = "mouse_word", .func = resolve_mouse_word },
    .{ .name = "mouse_x", .func = resolve_mouse_x },
    .{ .name = "mouse_y", .func = resolve_mouse_y },

    .{ .name = "pane_active", .func = resolve_pane_active },
    .{ .name = "pane_at_bottom", .func = resolve_pane_at_bottom },
    .{ .name = "pane_at_left", .func = resolve_pane_at_left },
    .{ .name = "pane_at_right", .func = resolve_pane_at_right },
    .{ .name = "pane_at_top", .func = resolve_pane_at_top },
    .{ .name = "pane_bg", .func = resolve_pane_bg },
    .{ .name = "pane_bottom", .func = resolve_pane_bottom },
    .{ .name = "pane_current_command", .func = resolve_pane_current_command },
    .{ .name = "pane_current_path", .func = resolve_pane_current_path },
    .{ .name = "pane_dead", .func = resolve_pane_dead },
    .{ .name = "pane_dead_signal", .func = resolve_pane_dead_signal },
    .{ .name = "pane_dead_status", .func = resolve_pane_dead_status },
    .{ .name = "pane_dead_time", .func = resolve_pane_dead_time },
    .{ .name = "pane_fg", .func = resolve_pane_fg },
    .{ .name = "pane_height", .func = resolve_pane_height },
    .{ .name = "pane_id", .func = resolve_pane_id },
    .{ .name = "pane_in_mode", .func = resolve_pane_in_mode },
    .{ .name = "pane_index", .func = resolve_pane_index },
    .{ .name = "pane_input_off", .func = resolve_pane_input_off },
    .{ .name = "pane_key_mode", .func = resolve_pane_key_mode },
    .{ .name = "pane_last", .func = resolve_pane_last },
    .{ .name = "pane_left", .func = resolve_pane_left },
    .{ .name = "pane_marked", .func = resolve_pane_marked },
    .{ .name = "pane_marked_set", .func = resolve_pane_marked_set },
    .{ .name = "pane_mode", .func = resolve_pane_mode },
    .{ .name = "pane_pid", .func = resolve_pane_pid },
    .{ .name = "pane_pipe", .func = resolve_pane_pipe },
    .{ .name = "pane_pipe_pid", .func = resolve_pane_pipe_pid },
    .{ .name = "pane_path", .func = resolve_pane_path },
    .{ .name = "pane_right", .func = resolve_pane_right },
    .{ .name = "pane_search_string", .func = resolve_pane_search_string },
    .{ .name = "pane_start_command", .func = resolve_pane_start_command },
    .{ .name = "pane_start_path", .func = resolve_pane_start_path },
    .{ .name = "pane_synchronized", .func = resolve_pane_synchronized },
    .{ .name = "pane_tabs", .func = resolve_pane_tabs },
    .{ .name = "pane_top", .func = resolve_pane_top },
    .{ .name = "pane_tty", .func = resolve_pane_tty },
    .{ .name = "pane_unseen_changes", .func = resolve_pane_unseen_changes },
    .{ .name = "pane_title", .func = resolve_pane_title },
    .{ .name = "pane_width", .func = resolve_pane_width },
    .{ .name = "pane_format", .func = resolve_pane_format },
    .{ .name = "current_command", .func = resolve_current_command },
    .{ .name = "current_path", .func = resolve_current_path },
    .{ .name = "start_command", .func = resolve_start_command },
    .{ .name = "start_path", .func = resolve_start_path },

    .{ .name = "scroll_region_lower", .func = resolve_scroll_region_lower },
    .{ .name = "scroll_region_upper", .func = resolve_scroll_region_upper },

    .{ .name = "session_active", .func = resolve_session_active },
    .{ .name = "session_activity", .func = resolve_session_activity },
    .{ .name = "session_alert", .func = resolve_session_alert },
    .{ .name = "session_alerts", .func = resolve_session_alerts },
    .{ .name = "session_attached", .func = resolve_session_attached },
    .{ .name = "session_attached_list", .func = resolve_session_attached_list },
    .{ .name = "session_created", .func = resolve_session_created },
    .{ .name = "session_group", .func = resolve_session_group },
    .{ .name = "session_group_attached", .func = resolve_session_group_attached },
    .{ .name = "session_group_attached_list", .func = resolve_session_group_attached_list },
    .{ .name = "session_group_list", .func = resolve_session_group_list },
    .{ .name = "session_group_many_attached", .func = resolve_session_group_many_attached },
    .{ .name = "session_group_size", .func = resolve_session_group_size },
    .{ .name = "session_grouped", .func = resolve_session_grouped },
    .{ .name = "session_id", .func = resolve_session_id },
    .{ .name = "session_last_attached", .func = resolve_session_last_attached },
    .{ .name = "session_name", .func = resolve_session_name },
    .{ .name = "session_windows", .func = resolve_session_windows },
    .{ .name = "session_activity_flag", .func = resolve_session_activity_flag },
    .{ .name = "session_bell_flag", .func = resolve_session_bell_flag },
    .{ .name = "session_format", .func = resolve_session_format },
    .{ .name = "session_many_attached", .func = resolve_session_many_attached },
    .{ .name = "session_marked", .func = resolve_session_marked },
    .{ .name = "session_path", .func = resolve_session_path },
    .{ .name = "session_silence_flag", .func = resolve_session_silence_flag },
    .{ .name = "session_stack", .func = resolve_session_stack },

    .{ .name = "active_window_index", .func = resolve_active_window_index },
    .{ .name = "last_window_index", .func = resolve_last_window_index },
    .{ .name = "window_active", .func = resolve_window_active },
    .{ .name = "window_activity_flag", .func = resolve_window_activity_flag },
    .{ .name = "window_bell_flag", .func = resolve_window_bell_flag },
    .{ .name = "window_bigger", .func = resolve_window_bigger },
    .{ .name = "window_flags", .func = resolve_window_flags },
    .{ .name = "window_height", .func = resolve_window_height },
    .{ .name = "window_id", .func = resolve_window_id },
    .{ .name = "window_index", .func = resolve_window_index },
    .{ .name = "window_last_flag", .func = resolve_window_last_flag },
    .{ .name = "window_layout", .func = resolve_window_layout },
    .{ .name = "window_linked", .func = resolve_window_linked },
    .{ .name = "window_name", .func = resolve_window_name },
    .{ .name = "window_offset_x", .func = resolve_window_offset_x },
    .{ .name = "window_offset_y", .func = resolve_window_offset_y },
    .{ .name = "window_panes", .func = resolve_window_panes },
    .{ .name = "window_raw_flags", .func = resolve_window_raw_flags },
    .{ .name = "window_silence_flag", .func = resolve_window_silence_flag },
    .{ .name = "window_visible_layout", .func = resolve_window_visible_layout },
    .{ .name = "window_zoomed_flag", .func = resolve_window_zoomed_flag },
    .{ .name = "window_width", .func = resolve_window_width },
    .{ .name = "window_active_clients", .func = resolve_window_active_clients },
    .{ .name = "window_active_clients_list", .func = resolve_window_active_clients_list },
    .{ .name = "window_active_sessions", .func = resolve_window_active_sessions },
    .{ .name = "window_active_sessions_list", .func = resolve_window_active_sessions_list },
    .{ .name = "window_activity", .func = resolve_window_activity },
    .{ .name = "window_cell_height", .func = resolve_window_cell_height },
    .{ .name = "window_cell_width", .func = resolve_window_cell_width },
    .{ .name = "window_end_flag", .func = resolve_window_end_flag },
    .{ .name = "window_format", .func = resolve_window_format },
    .{ .name = "window_linked_sessions", .func = resolve_window_linked_sessions },
    .{ .name = "window_linked_sessions_list", .func = resolve_window_linked_sessions_list },
    .{ .name = "window_marked_flag", .func = resolve_window_marked_flag },
    .{ .name = "window_stack_index", .func = resolve_window_stack_index },
    .{ .name = "window_start_flag", .func = resolve_window_start_flag },
    .{ .name = "synchronized_output_flag", .func = resolve_synchronized_output_flag },
    .{ .name = "version", .func = resolve_version },
    .{ .name = "sixel_support", .func = resolve_sixel_support },
    .{ .name = "tree_mode_format", .func = resolve_tree_mode_format },
    .{ .name = "uid", .func = resolve_uid },
    .{ .name = "user", .func = resolve_user },
    .{ .name = "wrap_flag", .func = resolve_wrap_flag },

    // Copy-mode format resolvers
    .{ .name = "scroll_position", .func = resolve_scroll_position },
    .{ .name = "top_line_time", .func = resolve_top_line_time },
    .{ .name = "rectangle_toggle", .func = resolve_rectangle_toggle },
    .{ .name = "copy_cursor_x", .func = resolve_copy_cursor_x },
    .{ .name = "copy_cursor_y", .func = resolve_copy_cursor_y },
    .{ .name = "copy_cursor_word", .func = resolve_copy_cursor_word },
    .{ .name = "copy_cursor_line", .func = resolve_copy_cursor_line },
    .{ .name = "selection_start_x", .func = resolve_selection_start_x },
    .{ .name = "selection_start_y", .func = resolve_selection_start_y },
    .{ .name = "selection_end_x", .func = resolve_selection_end_x },
    .{ .name = "selection_end_y", .func = resolve_selection_end_y },
    .{ .name = "selection_active", .func = resolve_selection_active },
    .{ .name = "selection_present", .func = resolve_selection_present },
    .{ .name = "selection_mode", .func = resolve_selection_mode },
};

fn c_string_bytes(bytes: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, bytes, 0) orelse bytes.len;
    return bytes[0..end];
}

fn normalize_format_time(value: i64) i64 {
    if (value > 10_000_000_000 or value < -10_000_000_000)
        return @divTrunc(value, 1000);
    return value;
}

pub fn lookup_option_value(alloc: std.mem.Allocator, name: []const u8, ctx: *const FormatContext) ?[]u8 {
    const found = find_option_value(name, ctx) orelse return null;
    return switch (found.value.*) {
        .array => |arr| blk: {
            if (arr.items.len == 0) break :blk xm.xstrdup("");
            var out: std.ArrayList(u8) = .{};
            for (arr.items, 0..) |item, idx| {
                if (idx != 0) out.appendSlice(alloc, " ") catch unreachable;
                out.appendSlice(alloc, item.value) catch unreachable;
            }
            break :blk out.toOwnedSlice(alloc) catch unreachable;
        },
        else => opts.options_value_to_string(name, found.value, found.entry),
    };
}

const FoundOption = struct {
    value: *const T.OptionsValue,
    entry: ?*const T.OptionsTableEntry,
};

fn find_option_value(name: []const u8, ctx: *const FormatContext) ?FoundOption {
    const entry = opts.options_table_entry(name);
    if (entry) |oe| {
        if (oe.scope.pane) {
            if (ctx_pane(ctx)) |wp| {
                if (opts.options_get(wp.options, name)) |value| return .{ .value = value, .entry = oe };
            }
        }
        if (oe.scope.window) {
            if (ctx_window(ctx)) |w| {
                if (opts.options_get(w.options, name)) |value| return .{ .value = value, .entry = oe };
            }
        }
        if (oe.scope.session) {
            if (ctx_session(ctx)) |s| {
                if (opts.options_get(s.options, name)) |value| return .{ .value = value, .entry = oe };
            } else if (opts.options_get(opts.global_s_options, name)) |value| {
                return .{ .value = value, .entry = oe };
            }
        }
        if (oe.scope.server) {
            if (opts.options_get(opts.global_options, name)) |value| return .{ .value = value, .entry = oe };
        }
        return null;
    }

    if (!(name.len > 0 and name[0] == '@')) return null;

    if (ctx_pane(ctx)) |wp| {
        if (opts.options_get(wp.options, name)) |value| return .{ .value = value, .entry = null };
    }
    if (ctx_window(ctx)) |w| {
        if (opts.options_get(w.options, name)) |value| return .{ .value = value, .entry = null };
    }
    if (ctx_session(ctx)) |s| {
        if (opts.options_get(s.options, name)) |value| return .{ .value = value, .entry = null };
    }
    if (opts.options_get(opts.global_options, name)) |value| return .{ .value = value, .entry = null };
    if (opts.options_get(opts.global_s_options, name)) |value| return .{ .value = value, .entry = null };
    if (opts.options_get(opts.global_w_options, name)) |value| return .{ .value = value, .entry = null };
    return null;
}

pub fn child_context_for_session(base: *const FormatContext, s: *T.Session, last: bool) FormatContext {
    var child = base.*;
    child.session = s;
    child.winlink = s.curw;
    child.window = if (s.curw) |wl| wl.window else null;
    child.pane = if (s.curw) |wl| wl.window.active else null;
    child.loop_last_flag = last;
    child.format_type = .session;
    return child;
}

pub fn child_context_for_winlink(base: *const FormatContext, s: *T.Session, wl: *T.Winlink, last: bool) FormatContext {
    var child = base.*;
    child.session = s;
    child.winlink = wl;
    child.window = wl.window;
    child.pane = wl.window.active;
    child.loop_last_flag = last;
    child.format_type = .window;
    return child;
}

pub fn child_context_for_pane(base: *const FormatContext, w: *T.Window, wp: *T.WindowPane, last: bool) FormatContext {
    var child = base.*;
    child.window = w;
    child.pane = wp;
    child.loop_last_flag = last;
    child.format_type = .pane;
    return child;
}

pub fn child_context_for_client(base: *const FormatContext, cl: *T.Client, last: bool) FormatContext {
    var child = base.*;
    child.client = cl;
    if (cl.session) |s| {
        child.session = s;
        child.winlink = s.curw;
        child.window = if (s.curw) |wl| wl.window else null;
        child.pane = if (s.curw) |wl| wl.window.active else null;
    }
    child.loop_last_flag = last;
    return child;
}

pub fn session_is_active(base: *const FormatContext, s: *T.Session) bool {
    if (base.client) |cl| return cl.session == s;
    return base.session == s;
}

pub fn ctx_session(ctx: *const FormatContext) ?*T.Session {
    if (ctx.session) |s| return s;
    if (ctx.winlink) |wl| return wl.session;
    if (ctx.client) |cl| return cl.session;
    return null;
}

fn ctx_winlink(ctx: *const FormatContext) ?*T.Winlink {
    if (ctx.winlink) |wl| return wl;
    if (ctx.session) |s| return s.curw;
    if (ctx.client) |cl| {
        if (cl.session) |s| return s.curw;
    }
    return null;
}

pub fn ctx_window(ctx: *const FormatContext) ?*T.Window {
    if (ctx.window) |w| return w;
    if (ctx.winlink) |wl| return wl.window;
    if (ctx.pane) |wp| return wp.window;
    if (ctx.session) |s| {
        if (s.curw) |wl| return wl.window;
    }
    if (ctx.client) |cl| {
        if (cl.session) |s| {
            if (s.curw) |wl| return wl.window;
        }
    }
    return null;
}

pub fn ctx_pane(ctx: *const FormatContext) ?*T.WindowPane {
    if (ctx.pane) |wp| return wp;
    if (ctx.window) |w| return w.active;
    if (ctx.winlink) |wl| return wl.window.active;
    if (ctx.session) |s| {
        if (s.curw) |wl| return wl.window.active;
    }
    if (ctx.client) |cl| {
        if (cl.session) |s| {
            if (s.curw) |wl| return wl.window.active;
        }
    }
    return null;
}

fn ctx_buffer(ctx: *const FormatContext) ?*paste_mod.PasteBuffer {
    return ctx.paste_buffer;
}

const MousePoint = struct {
    x: u32,
    y: u32,
};

const MouseScreenRow = struct {
    screen: *const T.Screen,
    row: u32,
};

fn ctx_mouse_event(ctx: *const FormatContext) ?*const T.MouseEvent {
    if (ctx.mouse_event) |mouse| return mouse;
    const raw = ctx.item orelse return null;
    const item: *cmdq.CmdqItem = @ptrCast(@alignCast(raw));
    const event = cmdq.cmdq_get_event(item);
    if (!event.m.valid) return null;
    return &event.m;
}

fn mouse_status_point(ctx: *const FormatContext, mouse: *const T.MouseEvent) ?MousePoint {
    const cl = ctx.client orelse return null;
    if ((cl.tty.flags & T.TTY_STARTED) == 0) return null;

    if (mouse.statusat == 0 and mouse.y < mouse.statuslines) {
        return .{ .x = mouse.x, .y = mouse.y };
    }
    if (mouse.statusat > 0 and mouse.y >= @as(u32, @intCast(mouse.statusat))) {
        return .{
            .x = mouse.x,
            .y = mouse.y - @as(u32, @intCast(mouse.statusat)),
        };
    }
    return null;
}

fn mouse_pane_point(wp: *T.WindowPane, mouse: *const T.MouseEvent, last: bool) ?MousePoint {
    const x = (if (last) mouse.lx else mouse.x) + mouse.ox;
    var y = (if (last) mouse.ly else mouse.y) + mouse.oy;

    if (mouse.statusat == 0 and y >= mouse.statuslines)
        y -= mouse.statuslines;

    if (x < wp.xoff or x >= wp.xoff + wp.sx) return null;
    if (y < wp.yoff or y >= wp.yoff + wp.sy) return null;

    return .{
        .x = x - wp.xoff,
        .y = y - wp.yoff,
    };
}

fn mouse_screen_row(wp: *T.WindowPane, y: u32) ?MouseScreenRow {
    if (window_copy.mouseFormatSource(wp, y)) |source| {
        return .{
            .screen = source.screen,
            .row = source.row,
        };
    }
    if (window_mod.window_pane_mode(wp) != null) return null;

    const current = screen_mod.screen_current(wp);
    const row = y;
    if (row >= current.grid.linedata.len) return null;
    return .{
        .screen = current,
        .row = row,
    };
}

fn grid_line_wrapped_local(gd: *const T.Grid, row: u32) bool {
    return row < gd.linedata.len and (gd.linedata[row].flags & T.GRID_LINE_WRAPPED) != 0;
}

fn grid_word_separator(gd: *T.Grid, row: u32, col: u32, separators: []const u8) bool {
    var gc: T.GridCell = undefined;
    grid.get_cell(gd, row, col, &gc);
    if (grid.grid_in_set(gd, row, col, separators) != 0) return true;
    if ((gc.flags & T.GRID_FLAG_TAB) != 0) return true;
    return gc.data.size == 1 and gc.data.data[0] == ' ';
}

pub fn format_grid_word(alloc: std.mem.Allocator, gd: *T.Grid, start_x: u32, start_y: u32, separators: []const u8) ?[]u8 {
    if (start_y >= gd.linedata.len) return null;

    var x = start_x;
    var y = start_y;
    var found_separator = false;
    while (true) {
        var gc: T.GridCell = undefined;
        grid.get_cell(gd, y, x, &gc);
        if (!gc.isPadding() and grid_word_separator(gd, y, x, separators)) {
            found_separator = true;
            break;
        }

        if (x == 0) {
            if (y == 0) break;
            if (!grid_line_wrapped_local(gd, y - 1)) break;
            y -= 1;
            x = grid.line_length(gd, y);
            if (x == 0) break;
        }
        x -= 1;
    }

    var cells: std.ArrayList(T.Utf8Data) = .{};
    while (true) {
        if (found_separator) {
            const end = grid.line_length(gd, y);
            if (end == 0 or x == end - 1) {
                if (y + 1 >= gd.linedata.len) break;
                if (!grid_line_wrapped_local(gd, y)) break;
                y += 1;
                x = 0;
            } else {
                x += 1;
            }
        }
        found_separator = true;

        var gc: T.GridCell = undefined;
        grid.get_cell(gd, y, x, &gc);
        if (gc.isPadding()) continue;
        if (grid_word_separator(gd, y, x, separators)) break;
        cells.append(alloc, gc.data) catch unreachable;
    }

    if (cells.items.len == 0) {
        cells.deinit(alloc);
        return null;
    }
    cells.append(alloc, std.mem.zeroes(T.Utf8Data)) catch unreachable;
    defer cells.deinit(alloc);
    return utf8.utf8_tocstr(cells.items);
}

pub fn format_grid_line(alloc: std.mem.Allocator, gd: *T.Grid, row: u32) ?[]u8 {
    if (row >= gd.linedata.len) return null;

    var cells: std.ArrayList(T.Utf8Data) = .{};
    const length = grid.line_length(gd, row);
    var x: u32 = 0;
    while (x < length) : (x += 1) {
        var gc: T.GridCell = undefined;
        grid.get_cell(gd, row, x, &gc);
        if (gc.isPadding()) continue;

        if ((gc.flags & T.GRID_FLAG_TAB) != 0) {
            var tab = std.mem.zeroes(T.Utf8Data);
            utf8.utf8_set(&tab, '\t');
            cells.append(alloc, tab) catch unreachable;
        } else {
            cells.append(alloc, gc.data) catch unreachable;
        }
    }

    if (cells.items.len == 0) {
        cells.deinit(alloc);
        return null;
    }
    cells.append(alloc, std.mem.zeroes(T.Utf8Data)) catch unreachable;
    defer cells.deinit(alloc);
    return utf8.utf8_tocstr(cells.items);
}

pub fn format_grid_hyperlink(screen: *const T.Screen, x_in: u32, row: u32) ?[]u8 {
    const hl = screen.hyperlinks orelse return null;
    var x = x_in;
    while (true) {
        var gc: T.GridCell = undefined;
        grid.get_cell(screen.grid, row, x, &gc);
        if (!gc.isPadding()) {
            if (gc.link == 0) return null;
            var uri: []const u8 = undefined;
            if (!hyperlinks.hyperlinks_get(hl, gc.link, &uri, null, null)) return null;
            return xm.xstrdup(uri);
        }
        if (x == 0) return null;
        x -= 1;
    }
}

fn mouse_mode_flag(alloc: std.mem.Allocator, ctx: *const FormatContext, flag: i32) ?[]u8 {
    const wp = ctx_pane(ctx) orelse return null;
    const current = screen_mod.screen_current(wp);
    return alloc.dupe(u8, if ((current.mode & flag) != 0) "1" else "0") catch unreachable;
}

pub const GridStorageUsage = struct {
    lines: usize = 0,
    line_bytes: usize = 0,
    cells: usize = 0,
    cell_bytes: usize = 0,
    extended_cells: usize = 0,
    extended_bytes: usize = 0,

    pub fn totalBytes(self: GridStorageUsage) usize {
        return self.line_bytes + self.cell_bytes + self.extended_bytes;
    }
};

// tmux keeps the pane's active or alternate screen state inside wp->base and
// only points wp->screen at temporary mode displays. zmux currently splits the
// alternate or mode display screen out, so pane-state formatter keys use the
// current screen unless a pane mode is borrowing wp.screen.
fn pane_state_screen(wp: *T.WindowPane) *T.Screen {
    if (window_mod.window_pane_mode(wp) != null) return &wp.base;
    return screen_mod.screen_current(wp);
}

fn pane_display_screen(wp: *T.WindowPane) *T.Screen {
    return screen_mod.screen_current(wp);
}

// The current grid runtime only materializes the stored backing it actually
// owns, so the history byte counters describe live backing storage rather than
// reconstructing scrolled-off lines that the reduced grid does not retain.
pub fn grid_storage_usage(gd: *const T.Grid) GridStorageUsage {
    var usage = GridStorageUsage{
        .lines = gd.linedata.len,
        .line_bytes = gd.linedata.len * @sizeOf(T.GridLine),
    };
    for (gd.linedata) |line| {
        usage.cells += line.celldata.len;
        usage.extended_cells += line.extddata.len;
    }
    usage.cell_bytes = usage.cells * @sizeOf(T.GridCellEntry);
    usage.extended_bytes = usage.extended_cells * @sizeOf(T.GridExtdEntry);
    return usage;
}

fn resolve_message_text(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    return alloc.dupe(u8, ctx.message_text orelse "") catch unreachable;
}

fn resolve_message(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    return alloc.dupe(u8, ctx.message_text orelse "") catch unreachable;
}

fn resolve_message_number(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    return std.fmt.allocPrint(alloc, "{d}", .{ctx.message_number orelse 0}) catch unreachable;
}

fn resolve_message_time(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    return std.fmt.allocPrint(alloc, "{d}", .{ctx.message_time orelse 0}) catch unreachable;
}

fn resolve_command_prompt(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    return alloc.dupe(u8, if (ctx.command_prompt orelse false) "1" else "0") catch unreachable;
}

fn resolve_hook_value(alloc: std.mem.Allocator, ctx: *const FormatContext, key: []const u8) ?[]u8 {
    const value = cmdq.cmdq_lookup_hook(ctx.item, key) orelse return null;
    return alloc.dupe(u8, value) catch unreachable;
}

fn resolve_hook(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    return resolve_hook_value(alloc, ctx, "hook");
}

fn resolve_hook_client(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    return resolve_hook_value(alloc, ctx, "hook_client");
}

fn resolve_hook_session(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    return resolve_hook_value(alloc, ctx, "hook_session");
}

fn resolve_hook_session_name(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    return resolve_hook_value(alloc, ctx, "hook_session_name");
}

fn resolve_hook_window(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    return resolve_hook_value(alloc, ctx, "hook_window");
}

fn resolve_hook_window_name(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    return resolve_hook_value(alloc, ctx, "hook_window_name");
}

fn resolve_hook_pane(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    return resolve_hook_value(alloc, ctx, "hook_pane");
}

fn client_tty_started(cl: *const T.Client) bool {
    return (cl.tty.flags & @as(i32, @intCast(T.TTY_STARTED))) != 0;
}

fn resolve_client_activity(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    _ = alloc;
    const cl = ctx.client orelse return null;
    return xm.xasprintf("{d}", .{normalize_format_time(cl.activity_time)});
}

fn resolve_client_cell_height(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    _ = alloc;
    const cl = ctx.client orelse return null;
    if (!client_tty_started(cl)) return null;
    return xm.xasprintf("{d}", .{cl.tty.ypixel});
}

fn resolve_client_cell_width(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    _ = alloc;
    const cl = ctx.client orelse return null;
    if (!client_tty_started(cl)) return null;
    return xm.xasprintf("{d}", .{cl.tty.xpixel});
}

fn resolve_client_control_mode(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const cl = ctx.client orelse return null;
    return alloc.dupe(u8, if (cl.flags & T.CLIENT_CONTROL != 0) "1" else "0") catch unreachable;
}

fn resolve_client_created(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    _ = alloc;
    const cl = ctx.client orelse return null;
    return xm.xasprintf("{d}", .{normalize_format_time(cl.creation_time)});
}

fn resolve_client_discarded(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    _ = alloc;
    const cl = ctx.client orelse return null;
    return xm.xasprintf("{d}", .{cl.discarded});
}

fn append_client_flag(out: *std.ArrayList(u8), alloc: std.mem.Allocator, flag: []const u8) void {
    if (out.items.len != 0)
        out.append(alloc, ',') catch unreachable;
    out.appendSlice(alloc, flag) catch unreachable;
}

fn resolve_client_flags(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const cl = ctx.client orelse return null;

    var out: std.ArrayList(u8) = .{};
    if (cl.flags & T.CLIENT_ATTACHED != 0)
        append_client_flag(&out, alloc, "attached");
    if (cl.flags & T.CLIENT_FOCUSED != 0)
        append_client_flag(&out, alloc, "focused");
    if (cl.flags & T.CLIENT_CONTROL != 0)
        append_client_flag(&out, alloc, "control-mode");
    if (cl.flags & T.CLIENT_IGNORESIZE != 0)
        append_client_flag(&out, alloc, "ignore-size");
    if (cl.flags & T.CLIENT_NO_DETACH_ON_DESTROY != 0)
        append_client_flag(&out, alloc, "no-detach-on-destroy");
    if (cl.flags & T.CLIENT_CONTROL_NOOUTPUT != 0)
        append_client_flag(&out, alloc, "no-output");
    if (cl.flags & T.CLIENT_CONTROL_WAITEXIT != 0)
        append_client_flag(&out, alloc, "wait-exit");
    if (cl.flags & T.CLIENT_CONTROL_PAUSEAFTER != 0) {
        const pause_after = std.fmt.allocPrint(alloc, "pause-after={d}", .{@divTrunc(cl.pause_age, 1000)}) catch unreachable;
        defer alloc.free(pause_after);
        append_client_flag(&out, alloc, pause_after);
    }
    if (cl.flags & T.CLIENT_READONLY != 0)
        append_client_flag(&out, alloc, "read-only");
    if (cl.flags & T.CLIENT_ACTIVEPANE != 0)
        append_client_flag(&out, alloc, "active-pane");
    if (cl.flags & T.CLIENT_SUSPENDED != 0)
        append_client_flag(&out, alloc, "suspended");
    if (cl.flags & T.CLIENT_UTF8 != 0)
        append_client_flag(&out, alloc, "UTF-8");
    return out.toOwnedSlice(alloc) catch unreachable;
}

fn resolve_client_last_session(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const cl = ctx.client orelse return null;
    const last = cl.last_session orelse return null;
    if (!sess.session_alive(last)) return null;
    return alloc.dupe(u8, last.name) catch unreachable;
}

fn resolve_client_name(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const cl = ctx.client orelse return null;
    return alloc.dupe(u8, cl.name orelse return null) catch unreachable;
}

fn resolve_client_pid(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    _ = alloc;
    const cl = ctx.client orelse return null;
    return xm.xasprintf("{d}", .{cl.pid});
}

fn resolve_client_tty(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const cl = ctx.client orelse return null;
    return alloc.dupe(u8, cl.ttyname orelse return null) catch unreachable;
}

fn resolve_client_width(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    _ = alloc;
    const cl = ctx.client orelse return null;
    // Return tty.sx directly; 0 for clients without an active tty (matches tmux).
    return xm.xasprintf("{d}", .{cl.tty.sx});
}

fn resolve_client_height(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    _ = alloc;
    const cl = ctx.client orelse return null;
    // Return tty.sy directly; 0 for clients without an active tty (matches tmux).
    return xm.xasprintf("{d}", .{cl.tty.sy});
}

fn resolve_client_session(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const cl = ctx.client orelse return null;
    const s = cl.session orelse return null;
    return alloc.dupe(u8, s.name) catch unreachable;
}

fn resolve_client_session_name(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const cl = ctx.client orelse return null;
    return alloc.dupe(u8, if (cl.session) |s| s.name else "") catch unreachable;
}

fn resolve_client_key_table(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const cl = ctx.client orelse return null;
    return alloc.dupe(u8, cl.key_table_name orelse "root") catch unreachable;
}

fn resolve_client_prefix(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const cl = ctx.client orelse return null;
    return alloc.dupe(u8, if (cl.key_table_name != null and std.mem.eql(u8, cl.key_table_name.?, "prefix")) "1" else "0") catch unreachable;
}

fn resolve_client_readonly(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const cl = ctx.client orelse return null;
    return alloc.dupe(u8, if (cl.flags & T.CLIENT_READONLY != 0) "1" else "0") catch unreachable;
}

fn resolve_client_termname(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const cl = ctx.client orelse return null;
    return alloc.dupe(u8, cl.term_name orelse "") catch unreachable;
}

fn resolve_client_termfeatures(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const cl = ctx.client orelse return null;
    return tty_features.featureString(alloc, cl.term_features);
}

fn resolve_client_termtype(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const cl = ctx.client orelse return null;
    return alloc.dupe(u8, cl.term_type orelse "") catch unreachable;
}

fn resolve_client_theme(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const cl = ctx.client orelse return null;
    const theme = switch (cl.theme) {
        .light => "light",
        .dark => "dark",
        .unknown => return null,
    };
    return alloc.dupe(u8, theme) catch unreachable;
}

fn resolve_client_uid(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const cl = ctx.client orelse return null;
    const peer = cl.peer orelse return null;
    const uid = proc_mod.proc_get_peer_uid(peer);
    if (uid == std.math.maxInt(std.posix.uid_t)) return null;
    return std.fmt.allocPrint(alloc, "{d}", .{uid}) catch unreachable;
}

fn resolve_client_user(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const cl = ctx.client orelse return null;
    const peer = cl.peer orelse return null;
    const uid = proc_mod.proc_get_peer_uid(peer);
    if (uid == std.math.maxInt(std.posix.uid_t)) return null;

    const pw = c.posix_sys.getpwuid(uid) orelse return null;
    return alloc.dupe(u8, std.mem.span(@as([*:0]const u8, @ptrCast(pw.*.pw_name)))) catch unreachable;
}

fn resolve_client_utf8(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const cl = ctx.client orelse return null;
    return alloc.dupe(u8, if (cl.flags & T.CLIENT_UTF8 != 0) "1" else "0") catch unreachable;
}

/// Resolve #{command} – the running command name from the cmdq item.
/// tmux populates this via cmdq_merge_formats(); in zmux we resolve it
/// directly from the item's cmd entry so hook templates can use it.
fn resolve_command(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const raw = ctx.item orelse return null;
    const item: *cmdq.CmdqItem = @ptrCast(@alignCast(raw));
    const cmd = item.cmd orelse return null;
    return alloc.dupe(u8, cmd.entry.name) catch unreachable;
}

fn resolve_command_name(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    return alloc.dupe(u8, ctx.command_name orelse return null) catch unreachable;
}

fn resolve_command_alias(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    _ = alloc;
    if (ctx.command_name == null) return null;
    return xm.xstrdup(ctx.command_alias orelse "");
}

fn resolve_command_usage(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    _ = alloc;
    if (ctx.command_name == null) return null;
    return xm.xstrdup(ctx.command_usage orelse "");
}

fn resolve_is_key(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    return alloc.dupe(u8, if (ctx.is_key orelse return null) "1" else "0") catch unreachable;
}

fn resolve_is_option(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    return alloc.dupe(u8, if (ctx.is_option orelse return null) "1" else "0") catch unreachable;
}

fn resolve_option_inherited(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    return alloc.dupe(u8, if (ctx.option_inherited orelse return null) "1" else "0") catch unreachable;
}

fn resolve_option_is_global(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    return alloc.dupe(u8, if (ctx.option_is_global orelse return null) "1" else "0") catch unreachable;
}

fn resolve_option_name(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    return alloc.dupe(u8, ctx.option_name orelse return null) catch unreachable;
}

fn resolve_option_scope(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    return alloc.dupe(u8, ctx.option_scope orelse return null) catch unreachable;
}

fn resolve_option_unit(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    return alloc.dupe(u8, ctx.option_unit orelse return null) catch unreachable;
}

fn resolve_option_value(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    return alloc.dupe(u8, ctx.option_value orelse return null) catch unreachable;
}

fn resolve_key_binding(ctx: *const FormatContext) ?*const T.KeyBinding {
    return ctx.key_binding;
}

fn resolve_key_table(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const binding = resolve_key_binding(ctx) orelse return null;
    return alloc.dupe(u8, binding.tablename) catch unreachable;
}

fn resolve_key_string(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const binding = resolve_key_binding(ctx) orelse return null;
    return alloc.dupe(u8, key_string.key_string_lookup_key(binding.key, 0)) catch unreachable;
}

fn resolve_key_note(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const binding = resolve_key_binding(ctx) orelse return null;
    const note = ctx.key_note orelse binding.note orelse "";
    return alloc.dupe(u8, note) catch unreachable;
}

fn resolve_key_command(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const binding = resolve_key_binding(ctx) orelse return null;
    _ = binding;
    return alloc.dupe(u8, ctx.key_command orelse "") catch unreachable;
}

fn resolve_key_has_repeat(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    if (ctx.key_has_repeat) |has_repeat| {
        const value: []const u8 = if (has_repeat) "1" else "0";
        return alloc.dupe(u8, value) catch unreachable;
    }
    return resolve_key_repeat(alloc, ctx);
}

fn resolve_key_repeat(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const binding = resolve_key_binding(ctx) orelse return null;
    const value: []const u8 = if (binding.flags & T.KEY_BINDING_REPEAT != 0) "1" else "0";
    return alloc.dupe(u8, value) catch unreachable;
}

fn resolve_key_prefix(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const binding = resolve_key_binding(ctx) orelse return null;
    _ = binding;
    return alloc.dupe(u8, ctx.key_prefix orelse "") catch unreachable;
}

fn resolve_key_string_width(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    _ = alloc;
    const binding = resolve_key_binding(ctx) orelse return null;
    _ = binding;
    return xm.xasprintf("{d}", .{ctx.key_string_width orelse 0});
}

fn resolve_key_table_width(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    _ = alloc;
    const binding = resolve_key_binding(ctx) orelse return null;
    _ = binding;
    return xm.xasprintf("{d}", .{ctx.key_table_width orelse 0});
}

fn resolve_loop_last_flag(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    return alloc.dupe(u8, if (ctx.loop_last_flag orelse false) "1" else "0") catch unreachable;
}

fn resolve_notes_only(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const binding = resolve_key_binding(ctx) orelse return null;
    _ = binding;
    const value: []const u8 = if (ctx.notes_only orelse false) "1" else "0";
    return alloc.dupe(u8, value) catch unreachable;
}

fn resolve_host(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    _ = ctx;
    var uts: c.posix_sys.struct_utsname = undefined;
    if (c.posix_sys.uname(&uts) != 0) return alloc.dupe(u8, "") catch unreachable;
    return alloc.dupe(u8, c_string_bytes(uts.nodename[0..])) catch unreachable;
}

fn resolve_host_short(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const host = resolve_host(alloc, ctx) orelse return null;
    defer alloc.free(host);
    const short = std.mem.indexOfScalar(u8, host, '.') orelse host.len;
    return alloc.dupe(u8, host[0..short]) catch unreachable;
}

fn resolve_line(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const line = ctx.line orelse return null;
    return std.fmt.allocPrint(alloc, "{d}", .{line}) catch unreachable;
}

fn resolve_pid(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    _ = alloc;
    _ = ctx;
    return xm.xasprintf("{d}", .{std.c.getpid()});
}

fn resolve_socket_path(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    _ = ctx;
    return alloc.dupe(u8, srv.socket_path) catch unreachable;
}

fn resolve_start_time(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    _ = alloc;
    _ = ctx;
    return xm.xasprintf("{d}", .{srv.start_time.sec});
}

fn resolve_alternate_on(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const wp = ctx_pane(ctx) orelse return null;
    return alloc.dupe(u8, if (screen_mod.screen_alternate_active(wp)) "1" else "0") catch unreachable;
}

fn resolve_alternate_saved_x(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    _ = alloc;
    const wp = ctx_pane(ctx) orelse return null;
    return xm.xasprintf("{d}", .{wp.screen.saved_cx});
}

fn resolve_alternate_saved_y(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    _ = alloc;
    const wp = ctx_pane(ctx) orelse return null;
    return xm.xasprintf("{d}", .{wp.screen.saved_cy});
}

fn resolve_buffer_created(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    _ = alloc;
    const pb = ctx_buffer(ctx) orelse return null;
    return xm.xasprintf("{d}", .{paste_mod.paste_buffer_created(pb)});
}

fn resolve_buffer_full(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const pb = ctx_buffer(ctx) orelse return null;
    return alloc.dupe(u8, paste_mod.paste_buffer_data(pb, null)) catch unreachable;
}

fn resolve_buffer_name(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const pb = ctx_buffer(ctx) orelse return null;
    return alloc.dupe(u8, paste_mod.paste_buffer_name(pb)) catch unreachable;
}

fn resolve_buffer_sample(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    _ = alloc;
    const pb = ctx_buffer(ctx) orelse return null;
    return paste_mod.paste_make_sample(pb);
}

fn resolve_buffer_size(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    _ = alloc;
    const pb = ctx_buffer(ctx) orelse return null;
    return xm.xasprintf("{d}", .{paste_mod.paste_buffer_data(pb, null).len});
}

fn resolve_cursor_blinking(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const wp = ctx_pane(ctx) orelse return null;
    const screen = pane_display_screen(wp);
    return alloc.dupe(u8, if ((screen.mode & T.MODE_CURSOR_BLINKING) != 0) "1" else "0") catch unreachable;
}

fn resolve_cursor_character(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const wp = ctx_pane(ctx) orelse return null;
    const screen = pane_state_screen(wp);
    var gc: T.GridCell = undefined;
    grid.get_cell(screen.grid, screen.cy, screen.cx, &gc);
    if (gc.isPadding()) return null;
    return alloc.dupe(u8, gc.data.data[0..gc.data.size]) catch unreachable;
}

fn resolve_cursor_colour(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const wp = ctx_pane(ctx) orelse return null;
    const screen = pane_display_screen(wp);
    const colour_value = if (screen.ccolour != -1) screen.ccolour else screen.default_ccolour;
    return alloc.dupe(u8, colour.colour_tostring(colour_value)) catch unreachable;
}

fn resolve_cursor_flag(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const wp = ctx_pane(ctx) orelse return null;
    const screen = pane_state_screen(wp);
    return alloc.dupe(u8, if ((screen.mode & T.MODE_CURSOR) != 0) "1" else "0") catch unreachable;
}

fn resolve_cursor_shape(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const wp = ctx_pane(ctx) orelse return null;
    const screen = pane_display_screen(wp);
    const value: []const u8 = switch (screen.cstyle) {
        .block => "block",
        .underline => "underline",
        .bar => "bar",
        .default => "default",
    };
    return alloc.dupe(u8, value) catch unreachable;
}

fn resolve_cursor_very_visible(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const wp = ctx_pane(ctx) orelse return null;
    const screen = pane_display_screen(wp);
    return alloc.dupe(u8, if ((screen.mode & T.MODE_CURSOR_VERY_VISIBLE) != 0) "1" else "0") catch unreachable;
}

fn resolve_cursor_x(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    _ = alloc;
    const wp = ctx_pane(ctx) orelse return null;
    const screen = pane_state_screen(wp);
    return xm.xasprintf("{d}", .{screen.cx});
}

fn resolve_cursor_y(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    _ = alloc;
    const wp = ctx_pane(ctx) orelse return null;
    const screen = pane_state_screen(wp);
    return xm.xasprintf("{d}", .{screen.cy});
}

fn resolve_history_all_bytes(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    _ = alloc;
    const wp = ctx_pane(ctx) orelse return null;
    const usage = grid_storage_usage(pane_state_screen(wp).grid);
    return xm.xasprintf(
        "{d},{d},{d},{d},{d},{d}",
        .{ usage.lines, usage.line_bytes, usage.cells, usage.cell_bytes, usage.extended_cells, usage.extended_bytes },
    );
}

fn resolve_history_bytes(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    _ = alloc;
    const wp = ctx_pane(ctx) orelse return null;
    return xm.xasprintf("{d}", .{grid_storage_usage(pane_state_screen(wp).grid).totalBytes()});
}

fn resolve_history_limit(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    _ = alloc;
    const wp = ctx_pane(ctx) orelse return null;
    return xm.xasprintf("{d}", .{pane_state_screen(wp).grid.hlimit});
}

fn resolve_history_size(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    _ = alloc;
    const wp = ctx_pane(ctx) orelse return null;
    return xm.xasprintf("{d}", .{pane_state_screen(wp).grid.hsize});
}

fn resolve_insert_flag(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const wp = ctx_pane(ctx) orelse return null;
    return alloc.dupe(u8, if ((pane_state_screen(wp).mode & T.MODE_INSERT) != 0) "1" else "0") catch unreachable;
}

fn resolve_keypad_cursor_flag(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const wp = ctx_pane(ctx) orelse return null;
    return alloc.dupe(u8, if ((pane_state_screen(wp).mode & T.MODE_KCURSOR) != 0) "1" else "0") catch unreachable;
}

fn resolve_keypad_flag(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const wp = ctx_pane(ctx) orelse return null;
    return alloc.dupe(u8, if ((pane_state_screen(wp).mode & T.MODE_KKEYPAD) != 0) "1" else "0") catch unreachable;
}

fn resolve_mouse_all_flag(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    return mouse_mode_flag(alloc, ctx, T.MODE_MOUSE_ALL);
}

fn resolve_mouse_any_flag(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    return mouse_mode_flag(alloc, ctx, T.ALL_MOUSE_MODES);
}

fn resolve_mouse_button_flag(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    return mouse_mode_flag(alloc, ctx, T.MODE_MOUSE_BUTTON);
}

fn resolve_mouse_hyperlink(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    _ = alloc;
    const mouse = ctx_mouse_event(ctx) orelse return null;
    const wp = mouse_runtime.cmd_mouse_pane(mouse, null, null) orelse return null;
    const point = mouse_pane_point(wp, mouse, false) orelse return null;
    const source = mouse_screen_row(wp, point.y) orelse return null;
    return format_grid_hyperlink(source.screen, point.x, source.row);
}

fn resolve_mouse_line(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const mouse = ctx_mouse_event(ctx) orelse return null;
    const wp = mouse_runtime.cmd_mouse_pane(mouse, null, null) orelse return null;
    const point = mouse_pane_point(wp, mouse, false) orelse return null;
    const source = mouse_screen_row(wp, point.y) orelse return null;
    return format_grid_line(alloc, source.screen.grid, source.row);
}

fn resolve_mouse_pane(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    _ = alloc;
    const mouse = ctx_mouse_event(ctx) orelse return null;
    const wp = mouse_runtime.cmd_mouse_pane(mouse, null, null) orelse return null;
    return xm.xasprintf("%{d}", .{wp.id});
}

fn resolve_mouse_sgr_flag(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    return mouse_mode_flag(alloc, ctx, T.MODE_MOUSE_SGR);
}

fn resolve_mouse_standard_flag(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    return mouse_mode_flag(alloc, ctx, T.MODE_MOUSE_STANDARD);
}

fn resolve_mouse_status_line(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    _ = alloc;
    const mouse = ctx_mouse_event(ctx) orelse return null;
    const point = mouse_status_point(ctx, mouse) orelse return null;
    return xm.xasprintf("{d}", .{point.y});
}

fn resolve_mouse_status_range(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const mouse = ctx_mouse_event(ctx) orelse return null;
    const point = mouse_status_point(ctx, mouse) orelse return null;
    const cl = ctx.client orelse return null;
    const range = if (point.y < cl.status.entries.len)
        cl.status.entries[point.y].ranges.items
    else
        return null;

    for (range) |entry| {
        if (point.x < entry.start or point.x >= entry.end) continue;
        return switch (entry.type) {
            .none => null,
            .left => alloc.dupe(u8, "left") catch unreachable,
            .right => alloc.dupe(u8, "right") catch unreachable,
            .pane => alloc.dupe(u8, "pane") catch unreachable,
            .window => alloc.dupe(u8, "window") catch unreachable,
            .session => alloc.dupe(u8, "session") catch unreachable,
            .user => alloc.dupe(u8, c_string_bytes(entry.string[0..])) catch unreachable,
        };
    }
    return null;
}

fn resolve_mouse_utf8_flag(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    return mouse_mode_flag(alloc, ctx, T.MODE_MOUSE_UTF8);
}

fn resolve_mouse_word(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const mouse = ctx_mouse_event(ctx) orelse return null;
    const wp = mouse_runtime.cmd_mouse_pane(mouse, null, null) orelse return null;
    const point = mouse_pane_point(wp, mouse, false) orelse return null;
    const source = mouse_screen_row(wp, point.y) orelse return null;
    const separators = opts.options_get_string(opts.global_s_options, "word-separators");
    return format_grid_word(alloc, source.screen.grid, point.x, source.row, separators);
}

fn resolve_mouse_x(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    _ = alloc;
    const mouse = ctx_mouse_event(ctx) orelse return null;
    if (mouse_runtime.cmd_mouse_pane(mouse, null, null)) |wp| {
        if (mouse_pane_point(wp, mouse, false)) |point|
            return xm.xasprintf("{d}", .{point.x});
    }
    if (mouse_status_point(ctx, mouse)) |point|
        return xm.xasprintf("{d}", .{point.x});
    return null;
}

fn resolve_mouse_y(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    _ = alloc;
    const mouse = ctx_mouse_event(ctx) orelse return null;
    if (mouse_runtime.cmd_mouse_pane(mouse, null, null)) |wp| {
        if (mouse_pane_point(wp, mouse, false)) |point|
            return xm.xasprintf("{d}", .{point.y});
    }
    if (mouse_status_point(ctx, mouse)) |point|
        return xm.xasprintf("{d}", .{point.y});
    return null;
}

fn resolve_session_name(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const s = ctx_session(ctx) orelse return null;
    return alloc.dupe(u8, s.name) catch unreachable;
}

fn resolve_session_windows(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    _ = alloc;
    const s = ctx_session(ctx) orelse return null;
    return xm.xasprintf("{d}", .{s.windows.count()});
}

fn resolve_session_active(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const s = ctx_session(ctx) orelse return null;
    const active = if (ctx.client) |cl| cl.session == s else ctx.session == s;
    return alloc.dupe(u8, if (active) "1" else "0") catch unreachable;
}

fn resolve_session_attached(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    _ = alloc;
    const s = ctx_session(ctx) orelse return null;
    return xm.xasprintf("{d}", .{s.attached});
}

fn resolve_session_attached_list(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const s = ctx_session(ctx) orelse return null;

    var out: std.ArrayList(u8) = .{};
    for (client_registry.clients.items) |cl| {
        if (cl.session != s) continue;
        const name = cl.name orelse continue;
        if (out.items.len != 0)
            out.append(alloc, ',') catch unreachable;
        out.appendSlice(alloc, name) catch unreachable;
    }
    return out.toOwnedSlice(alloc) catch unreachable;
}

fn resolve_session_activity(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    _ = alloc;
    const s = ctx_session(ctx) orelse return null;
    return xm.xasprintf("{d}", .{normalize_format_time(s.activity_time)});
}

fn resolve_session_alert(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const s = ctx_session(ctx) orelse return null;
    const items = sort_mod.sorted_winlinks_session(s, .{});
    defer xm.allocator.free(items);

    var out: std.ArrayList(u8) = .{};
    var alerted: u32 = 0;
    for (items) |wl| {
        if ((wl.flags & T.WINLINK_ALERTFLAGS) == 0)
            continue;
        if ((alerted & T.WINLINK_ACTIVITY) == 0 and (wl.flags & T.WINLINK_ACTIVITY) != 0) {
            out.append(alloc, '#') catch unreachable;
            alerted |= T.WINLINK_ACTIVITY;
        }
        if ((alerted & T.WINLINK_BELL) == 0 and (wl.flags & T.WINLINK_BELL) != 0) {
            out.append(alloc, '!') catch unreachable;
            alerted |= T.WINLINK_BELL;
        }
        if ((alerted & T.WINLINK_SILENCE) == 0 and (wl.flags & T.WINLINK_SILENCE) != 0) {
            out.append(alloc, '~') catch unreachable;
            alerted |= T.WINLINK_SILENCE;
        }
    }
    return out.toOwnedSlice(alloc) catch unreachable;
}

fn resolve_session_alerts(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const s = ctx_session(ctx) orelse return null;
    const items = sort_mod.sorted_winlinks_session(s, .{});
    defer xm.allocator.free(items);

    var out: std.ArrayList(u8) = .{};
    for (items) |wl| {
        if ((wl.flags & T.WINLINK_ALERTFLAGS) == 0)
            continue;
        if (out.items.len != 0)
            out.append(alloc, ',') catch unreachable;
        out.writer(alloc).print("{d}", .{wl.idx}) catch unreachable;
        if ((wl.flags & T.WINLINK_ACTIVITY) != 0)
            out.append(alloc, '#') catch unreachable;
        if ((wl.flags & T.WINLINK_BELL) != 0)
            out.append(alloc, '!') catch unreachable;
        if ((wl.flags & T.WINLINK_SILENCE) != 0)
            out.append(alloc, '~') catch unreachable;
    }
    return out.toOwnedSlice(alloc) catch unreachable;
}

fn resolve_session_created(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    _ = alloc;
    const s = ctx_session(ctx) orelse return null;
    return xm.xasprintf("{d}", .{normalize_format_time(s.created)});
}

fn resolve_session_grouped(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const s = ctx_session(ctx) orelse return null;
    const value: []const u8 = if (sess.session_group_contains(s) != null) "1" else "0";
    return alloc.dupe(u8, value) catch unreachable;
}

fn resolve_session_group(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const s = ctx_session(ctx) orelse return null;
    const group = sess.session_group_contains(s) orelse return alloc.dupe(u8, "") catch unreachable;
    return alloc.dupe(u8, group.name) catch unreachable;
}

fn resolve_session_group_attached(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    _ = alloc;
    const s = ctx_session(ctx) orelse return null;
    const group = sess.session_group_contains(s) orelse return xm.xasprintf("{d}", .{@as(u32, 0)});
    return xm.xasprintf("{d}", .{sess.session_group_attached_count(group)});
}

fn resolve_session_group_attached_list(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const s = ctx_session(ctx) orelse return null;
    const group = sess.session_group_contains(s) orelse return alloc.dupe(u8, "") catch unreachable;

    var out: std.ArrayList(u8) = .{};
    for (client_registry.clients.items) |cl| {
        const client_session = cl.session orelse continue;
        var in_group = false;
        for (group.sessions.items) |member| {
            if (member == client_session) {
                in_group = true;
                break;
            }
        }
        if (!in_group) continue;
        const name = cl.name orelse continue;
        if (out.items.len != 0)
            out.append(alloc, ',') catch unreachable;
        out.appendSlice(alloc, name) catch unreachable;
    }
    return out.toOwnedSlice(alloc) catch unreachable;
}

fn resolve_session_group_list(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const s = ctx_session(ctx) orelse return null;
    const group = sess.session_group_contains(s) orelse return alloc.dupe(u8, "") catch unreachable;

    var out: std.ArrayList(u8) = .{};
    for (group.sessions.items, 0..) |entry, idx| {
        if (idx != 0) out.appendSlice(alloc, ",") catch unreachable;
        out.appendSlice(alloc, entry.name) catch unreachable;
    }
    return out.toOwnedSlice(alloc) catch unreachable;
}

fn resolve_session_group_many_attached(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const s = ctx_session(ctx) orelse return null;
    const group = sess.session_group_contains(s) orelse return alloc.dupe(u8, "0") catch unreachable;
    const value: []const u8 = if (sess.session_group_attached_count(group) > 1) "1" else "0";
    return alloc.dupe(u8, value) catch unreachable;
}

fn resolve_session_group_size(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    _ = alloc;
    const s = ctx_session(ctx) orelse return null;
    const group = sess.session_group_contains(s) orelse return xm.xasprintf("{d}", .{@as(u32, 0)});
    return xm.xasprintf("{d}", .{sess.session_group_count(group)});
}

fn resolve_session_id(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    _ = alloc;
    const s = ctx_session(ctx) orelse return null;
    return xm.xasprintf("${d}", .{s.id});
}

fn resolve_session_last_attached(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    _ = alloc;
    const s = ctx_session(ctx) orelse return null;
    return xm.xasprintf("{d}", .{normalize_format_time(s.last_attached_time)});
}

fn resolve_active_window_index(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    _ = alloc;
    const s = ctx_session(ctx) orelse return null;
    const wl = s.curw orelse return null;
    return xm.xasprintf("{d}", .{wl.idx});
}

fn resolve_last_window_index(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    _ = alloc;
    const s = ctx_session(ctx) orelse return null;

    var max_idx: ?i32 = null;
    var it = s.windows.valueIterator();
    while (it.next()) |wl| {
        if (max_idx == null or wl.*.idx > max_idx.?)
            max_idx = wl.*.idx;
    }
    const idx = max_idx orelse return null;
    return xm.xasprintf("{d}", .{idx});
}

fn resolve_window_name(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const w = ctx_window(ctx) orelse return null;
    return alloc.dupe(u8, w.name) catch unreachable;
}

fn resolve_next_session_id(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    _ = alloc;
    _ = ctx;
    return xm.xasprintf("${d}", .{sess.session_next_id_peek()});
}

fn resolve_origin_flag(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const wp = ctx_pane(ctx) orelse return null;
    return alloc.dupe(u8, if ((pane_state_screen(wp).mode & T.MODE_ORIGIN) != 0) "1" else "0") catch unreachable;
}

fn resolve_server_sessions(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    _ = alloc;
    _ = ctx;
    return xm.xasprintf("{d}", .{sess.sessions.count()});
}

fn resolve_window_index(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const wl = ctx_winlink(ctx) orelse return null;
    _ = alloc;
    return xm.xasprintf("{d}", .{wl.idx});
}

fn resolve_window_width(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const w = ctx_window(ctx) orelse return null;
    _ = alloc;
    return xm.xasprintf("{d}", .{w.sx});
}

fn resolve_window_height(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const w = ctx_window(ctx) orelse return null;
    _ = alloc;
    return xm.xasprintf("{d}", .{w.sy});
}

fn resolve_window_layout(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const w = ctx_window(ctx) orelse return null;
    _ = alloc;
    if (w.saved_layout_root) |saved|
        return layout_mod.dump_root(saved);
    if (w.layout_root) |root|
        return layout_mod.dump_root(root);
    return layout_mod.dump_window(w);
}

fn resolve_window_visible_layout(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const w = ctx_window(ctx) orelse return null;
    _ = alloc;
    if (w.layout_root) |root|
        return layout_mod.dump_root(root);
    return layout_mod.dump_window(w);
}

fn resolve_window_panes(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const w = ctx_window(ctx) orelse return null;
    _ = alloc;
    return xm.xasprintf("{d}", .{w.panes.items.len});
}

fn resolve_window_active(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const wl = ctx_winlink(ctx) orelse return null;
    const s = ctx_session(ctx) orelse return null;
    const value: []const u8 = if (s.curw == wl) "1" else "0";
    return alloc.dupe(u8, value) catch unreachable;
}

fn resolve_window_activity_flag(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const wl = ctx_winlink(ctx) orelse return null;
    return alloc.dupe(u8, if (wl.flags & T.WINLINK_ACTIVITY != 0) "1" else "0") catch unreachable;
}

fn resolve_window_bell_flag(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const wl = ctx_winlink(ctx) orelse return null;
    return alloc.dupe(u8, if (wl.flags & T.WINLINK_BELL != 0) "1" else "0") catch unreachable;
}

const WindowOffset = struct { ox: u32, oy: u32, sx: u32, sy: u32, bigger: bool };

fn ctx_window_offset(ctx: *const FormatContext) ?WindowOffset {
    const cl = ctx.client orelse return null;
    var wo: WindowOffset = undefined;
    wo.bigger = tty_mod.tty_window_offset(&cl.tty, &wo.ox, &wo.oy, &wo.sx, &wo.sy) != 0;
    return wo;
}

fn resolve_window_bigger(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    _ = ctx_window(ctx) orelse return null;
    const wo = ctx_window_offset(ctx) orelse return null;
    return alloc.dupe(u8, if (wo.bigger) "1" else "0") catch unreachable;
}

fn resolve_window_id(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const w = ctx_window(ctx) orelse return null;
    _ = alloc;
    return xm.xasprintf("@{d}", .{w.id});
}

fn resolve_window_last_flag(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const wl = ctx_winlink(ctx) orelse return null;
    const s = ctx_session(ctx) orelse return null;
    const value: []const u8 = if (s.lastw.items.len > 0 and s.lastw.items[0] == wl) "1" else "0";
    return alloc.dupe(u8, value) catch unreachable;
}

fn resolve_window_linked(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const w = ctx_window(ctx) orelse return null;
    return alloc.dupe(u8, if (w.references > 1) "1" else "0") catch unreachable;
}

fn resolve_window_flags(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    return resolve_window_flags_impl(alloc, ctx);
}

fn resolve_window_raw_flags(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    return resolve_window_flags_impl(alloc, ctx);
}

fn resolve_window_silence_flag(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const wl = ctx_winlink(ctx) orelse return null;
    return alloc.dupe(u8, if (wl.flags & T.WINLINK_SILENCE != 0) "1" else "0") catch unreachable;
}

fn resolve_window_flags_impl(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const wl = ctx_winlink(ctx) orelse return null;
    const s = ctx_session(ctx) orelse return null;

    var out: std.ArrayList(u8) = .{};
    if (wl.flags & T.WINLINK_ACTIVITY != 0) out.append(alloc, '#') catch unreachable;
    if (wl.flags & T.WINLINK_BELL != 0) out.append(alloc, '!') catch unreachable;
    if (wl.flags & T.WINLINK_SILENCE != 0) out.append(alloc, '~') catch unreachable;
    if (s.curw == wl) out.append(alloc, '*') catch unreachable;
    if (s.lastw.items.len > 0 and s.lastw.items[0] == wl) out.append(alloc, '-') catch unreachable;
    if (wl.window.flags & T.WINDOW_ZOOMED != 0) out.append(alloc, 'Z') catch unreachable;
    return out.toOwnedSlice(alloc) catch unreachable;
}

fn resolve_window_offset_x(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    _ = alloc;
    const wo = ctx_window_offset(ctx) orelse return null;
    if (!wo.bigger) return null;
    return xm.xasprintf("{d}", .{wo.ox});
}

fn resolve_window_offset_y(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    _ = alloc;
    const wo = ctx_window_offset(ctx) orelse return null;
    if (!wo.bigger) return null;
    return xm.xasprintf("{d}", .{wo.oy});
}

fn resolve_window_zoomed_flag(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const w = ctx_window(ctx) orelse return null;
    return alloc.dupe(u8, if (w.flags & T.WINDOW_ZOOMED != 0) "1" else "0") catch unreachable;
}

fn resolve_pane_id(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const wp = ctx_pane(ctx) orelse return null;
    _ = alloc;
    return xm.xasprintf("%{d}", .{wp.id});
}

fn resolve_pane_at_top(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const wp = ctx_pane(ctx) orelse return null;
    const status = opts.options_get_number(wp.window.options, "pane-border-status");
    const value: []const u8 = if (status == T.PANE_STATUS_TOP) blk: {
        break :blk if (wp.yoff == 1) "1" else "0";
    } else blk: {
        break :blk if (wp.yoff == 0) "1" else "0";
    };
    return alloc.dupe(u8, value) catch unreachable;
}

fn resolve_pane_at_bottom(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const wp = ctx_pane(ctx) orelse return null;
    const w = wp.window;
    const status = opts.options_get_number(w.options, "pane-border-status");
    const value: []const u8 = if (status == T.PANE_STATUS_BOTTOM) blk: {
        break :blk if (wp.yoff + wp.sy == w.sy -| 1) "1" else "0";
    } else blk: {
        break :blk if (wp.yoff + wp.sy == w.sy) "1" else "0";
    };
    return alloc.dupe(u8, value) catch unreachable;
}

fn resolve_pane_at_left(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const wp = ctx_pane(ctx) orelse return null;
    return alloc.dupe(u8, if (wp.xoff == 0) "1" else "0") catch unreachable;
}

fn resolve_pane_at_right(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const wp = ctx_pane(ctx) orelse return null;
    return alloc.dupe(u8, if (wp.xoff + wp.sx == wp.window.sx) "1" else "0") catch unreachable;
}

fn resolve_pane_bottom(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const wp = ctx_pane(ctx) orelse return null;
    _ = alloc;
    return xm.xasprintf("{d}", .{wp.yoff + wp.sy -| 1});
}

fn resolve_pane_top(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const wp = ctx_pane(ctx) orelse return null;
    _ = alloc;
    return xm.xasprintf("{d}", .{wp.yoff});
}

fn resolve_pane_left(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const wp = ctx_pane(ctx) orelse return null;
    _ = alloc;
    return xm.xasprintf("{d}", .{wp.xoff});
}

fn resolve_pane_right(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const wp = ctx_pane(ctx) orelse return null;
    _ = alloc;
    return xm.xasprintf("{d}", .{wp.xoff + wp.sx -| 1});
}

fn resolve_pane_fg(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const wp = ctx_pane(ctx) orelse return null;
    const colour_value = pane_colour(wp, .fg);
    return alloc.dupe(u8, colour.colour_tostring(colour_value)) catch unreachable;
}

fn resolve_pane_bg(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const wp = ctx_pane(ctx) orelse return null;
    const colour_value = pane_colour(wp, .bg);
    return alloc.dupe(u8, colour.colour_tostring(colour_value)) catch unreachable;
}

fn resolve_pane_pid(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const wp = ctx_pane(ctx) orelse return null;
    _ = alloc;
    return xm.xasprintf("{d}", .{wp.pid});
}

fn resolve_pane_pipe(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const wp = ctx_pane(ctx) orelse return null;
    const active = wp.pipe_fd >= 0 or wp.pipe_pid > 0;
    return alloc.dupe(u8, if (active) "1" else "0") catch unreachable;
}

fn resolve_pane_pipe_pid(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const wp = ctx_pane(ctx) orelse return null;
    if (wp.pipe_pid <= 0) return alloc.dupe(u8, "") catch unreachable;
    return xm.xasprintf("{d}", .{wp.pipe_pid});
}

fn resolve_pane_path(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const wp = ctx_pane(ctx) orelse return null;
    return pane_path_text(alloc, wp, false);
}

fn resolve_pane_current_path(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const wp = ctx_pane(ctx) orelse return null;
    return pane_path_text(alloc, wp, true);
}

fn resolve_pane_start_command(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const wp = ctx_pane(ctx) orelse return null;
    if (wp.argv) |argv| return cmd_render.stringify_argv(alloc, argv);
    if (wp.shell) |shell| return alloc.dupe(u8, shell) catch unreachable;
    return alloc.dupe(u8, "") catch unreachable;
}

fn resolve_pane_start_path(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const wp = ctx_pane(ctx) orelse return null;
    return alloc.dupe(u8, wp.cwd orelse "") catch unreachable;
}

fn resolve_pane_input_off(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const wp = ctx_pane(ctx) orelse return null;
    return alloc.dupe(u8, if (wp.flags & T.PANE_INPUTOFF != 0) "1" else "0") catch unreachable;
}

fn resolve_pane_unseen_changes(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const wp = ctx_pane(ctx) orelse return null;
    return alloc.dupe(u8, if (wp.flags & T.PANE_UNSEENCHANGES != 0) "1" else "0") catch unreachable;
}

fn resolve_pane_key_mode(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const wp = ctx_pane(ctx) orelse return null;
    const mode = screen_mod.screen_current(wp).mode & T.EXTENDED_KEY_MODES;
    const value: []const u8 = switch (mode) {
        T.MODE_KEYS_EXTENDED => "Ext 1",
        T.MODE_KEYS_EXTENDED_2 => "Ext 2",
        else => "VT10x",
    };
    return alloc.dupe(u8, value) catch unreachable;
}

fn resolve_pane_last(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const wp = ctx_pane(ctx) orelse return null;
    const value: []const u8 = if (window_mod.window_get_last_pane(wp.window) == wp) "1" else "0";
    return alloc.dupe(u8, value) catch unreachable;
}

fn resolve_pane_search_string(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const wp = ctx_pane(ctx) orelse return null;
    return alloc.dupe(u8, wp.searchstr orelse "") catch unreachable;
}

fn resolve_pane_synchronized(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const wp = ctx_pane(ctx) orelse return null;
    return alloc.dupe(u8, if (opts.options_get_number(wp.options, "synchronize-panes") != 0) "1" else "0") catch unreachable;
}

fn resolve_pane_tabs(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const wp = ctx_pane(ctx) orelse return null;
    const tabs = wp.base.tabs orelse return alloc.dupe(u8, "") catch unreachable;

    var out: std.ArrayList(u8) = .{};
    for (0..wp.base.grid.sx) |idx| {
        if (!tab_stop_set(tabs, @intCast(idx))) continue;
        if (out.items.len != 0) out.append(alloc, ',') catch unreachable;
        out.writer(alloc).print("{d}", .{idx}) catch unreachable;
    }
    return out.toOwnedSlice(alloc) catch unreachable;
}

fn resolve_pane_tty(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const wp = ctx_pane(ctx) orelse return null;
    return alloc.dupe(u8, c_string_bytes(wp.tty_name[0..])) catch unreachable;
}

fn resolve_pane_width(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const wp = ctx_pane(ctx) orelse return null;
    _ = alloc;
    return xm.xasprintf("{d}", .{wp.sx});
}

fn resolve_pane_height(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const wp = ctx_pane(ctx) orelse return null;
    _ = alloc;
    return xm.xasprintf("{d}", .{wp.sy});
}

fn resolve_pane_index(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const wp = ctx_pane(ctx) orelse return null;
    const w = ctx_window(ctx) orelse return null;
    for (w.panes.items, 0..) |pane, idx| {
        if (pane == wp) return xm.xasprintf("{d}", .{idx});
    }
    return alloc.dupe(u8, "0") catch unreachable;
}

fn resolve_pane_title(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const wp = ctx_pane(ctx) orelse return null;
    return alloc.dupe(u8, if (wp.screen.title) |title| title else "") catch unreachable;
}

fn resolve_pane_active(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const wp = ctx_pane(ctx) orelse return null;
    const w = ctx_window(ctx) orelse return null;
    const value: []const u8 = if (w.active == wp) "1" else "0";
    return alloc.dupe(u8, value) catch unreachable;
}

fn resolve_pane_dead(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const wp = ctx_pane(ctx) orelse return null;
    const value: []const u8 = if (wp.flags & T.PANE_EXITED != 0) "1" else "0";
    return alloc.dupe(u8, value) catch unreachable;
}

fn resolve_pane_dead_status(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const wp = ctx_pane(ctx) orelse return null;
    const status = pane_wait_status(wp) orelse return alloc.dupe(u8, "") catch unreachable;
    if (!std.posix.W.IFEXITED(status)) return alloc.dupe(u8, "") catch unreachable;
    return xm.xasprintf("{d}", .{std.posix.W.EXITSTATUS(status)});
}

fn resolve_pane_dead_signal(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const wp = ctx_pane(ctx) orelse return null;
    const status = pane_wait_status(wp) orelse return alloc.dupe(u8, "") catch unreachable;
    if (!std.posix.W.IFSIGNALED(status)) return alloc.dupe(u8, "") catch unreachable;
    return xm.xasprintf("{d}", .{std.posix.W.TERMSIG(status)});
}

fn resolve_pane_dead_time(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const wp = ctx_pane(ctx) orelse return null;
    if (wp.dead_time == 0) return alloc.dupe(u8, "") catch unreachable;
    return xm.xasprintf("{d}", .{wp.dead_time});
}

fn resolve_pane_in_mode(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const wp = ctx_pane(ctx) orelse return null;
    const value: []const u8 = if (window_mod.window_pane_mode(wp) != null) "1" else "0";
    return alloc.dupe(u8, value) catch unreachable;
}

fn resolve_pane_marked(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const wp = ctx_pane(ctx) orelse return null;
    const value: []const u8 = if (marked_pane_mod.check() and marked_pane_mod.marked_pane.wp == wp) "1" else "0";
    return alloc.dupe(u8, value) catch unreachable;
}

fn resolve_pane_marked_set(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    _ = ctx_pane(ctx) orelse return null;
    const value: []const u8 = if (marked_pane_mod.check()) "1" else "0";
    return alloc.dupe(u8, value) catch unreachable;
}

fn resolve_pane_mode(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const wp = ctx_pane(ctx) orelse return null;
    const wme = window_mod.window_pane_mode(wp) orelse return null;
    return alloc.dupe(u8, wme.mode.name) catch unreachable;
}

fn resolve_pane_current_command(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const wp = ctx_pane(ctx) orelse return null;
    if (wp.argv) |argv| {
        const text = cmd_render.stringify_argv(alloc, argv);
        defer alloc.free(text);
        return names.parse_window_name(text);
    }
    if (wp.shell) |shell| return names.parse_window_name(shell);
    return alloc.dupe(u8, "") catch unreachable;
}

const PaneColourSlot = enum {
    fg,
    bg,
};

fn pane_colour(wp: *T.WindowPane, slot: PaneColourSlot) i32 {
    if (pane_control_colour(wp, slot)) |value| return value;
    if (pane_attached_colour(wp, slot)) |value| return value;
    return 8;
}

fn pane_control_colour(wp: *T.WindowPane, slot: PaneColourSlot) ?i32 {
    const colour_value = switch (slot) {
        .fg => wp.control_fg,
        .bg => wp.control_bg,
    };
    if (colour_value == -1) return null;

    for (client_registry.clients.items) |cl| {
        if (cl.flags & T.CLIENT_CONTROL != 0) return colour_value;
    }
    return null;
}

fn pane_attached_colour(wp: *T.WindowPane, slot: PaneColourSlot) ?i32 {
    for (client_registry.clients.items) |cl| {
        if (cl.flags & T.CLIENT_ATTACHED == 0) continue;
        const s = cl.session orelse continue;
        if (!sess.session_has_window(s, wp.window)) continue;

        const colour_value = switch (slot) {
            .fg => cl.tty.fg,
            .bg => cl.tty.bg,
        };
        if (colour_value != -1) return colour_value;
    }
    return null;
}

fn pane_path_text(alloc: std.mem.Allocator, wp: *T.WindowPane, prefer_current: bool) []u8 {
    if (prefer_current) {
        if (screen_mod.screen_current(wp).path) |path| return alloc.dupe(u8, path) catch unreachable;
    }
    if (wp.base.path) |path| return alloc.dupe(u8, path) catch unreachable;
    if (wp.cwd) |cwd| return alloc.dupe(u8, cwd) catch unreachable;
    return alloc.dupe(u8, "") catch unreachable;
}

fn pane_wait_status(wp: *T.WindowPane) ?u32 {
    if ((wp.flags & (T.PANE_STATUSREADY | T.PANE_EXITED)) == 0) return null;
    return @as(u32, @bitCast(wp.status));
}

fn tab_stop_set(tabs: []const u8, x: u32) bool {
    const byte_index: usize = @intCast(x / 8);
    if (byte_index >= tabs.len) return false;
    return (tabs[byte_index] & (@as(u8, 1) << @intCast(x % 8))) != 0;
}

fn resolve_scroll_region_upper(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    _ = alloc;
    const wp = ctx_pane(ctx) orelse return null;
    const screen = screen_mod.screen_current(wp);
    return xm.xasprintf("{d}", .{screen.rupper});
}

fn resolve_scroll_region_lower(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    _ = alloc;
    const wp = ctx_pane(ctx) orelse return null;
    const screen = screen_mod.screen_current(wp);
    return xm.xasprintf("{d}", .{screen.rlower});
}

fn resolve_version(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    _ = ctx;
    return alloc.dupe(u8, T.ZMUX_VERSION) catch unreachable;
}

fn resolve_synchronized_output_flag(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const wp = ctx_pane(ctx) orelse return null;
    return alloc.dupe(u8, if ((pane_state_screen(wp).mode & T.MODE_SYNC) != 0) "1" else "0") catch unreachable;
}

// ── Copy-mode format resolvers ────────────────────────────────────────────

/// Helper: obtain copy-mode data for a pane that is actually in copy mode.
fn copyModeDataFromCtx(ctx: *const FormatContext) ?*window_copy.CopyModeData {
    const wp = ctx_pane(ctx) orelse return null;
    const wme = window_mod.window_pane_mode(wp) orelse return null;
    if (wme.mode != &window_copy.window_copy_mode) return null;
    return window_copy.modeData(wme);
}

fn resolve_scroll_position(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    _ = alloc;
    const data = copyModeDataFromCtx(ctx) orelse return null;
    // In tmux, scroll_position = data->oy which is the number of history
    // lines scrolled past.  Our `top` is the absolute row index of the top
    // visible row.  The scrollback offset is the number of history rows
    // above the current viewport, i.e. the hsize of the backing minus the
    // rows already accounted for minus top.
    const backing = data.backing;
    const hsize = backing.grid.hsize;
    // The total scrollable content is hsize + sy rows.  When top = 0 the
    // viewport is at the very top (oldest history), scroll_position = hsize.
    // When top = hsize, viewport is at the newest content, scroll_position = 0.
    const scroll_pos = hsize -| @min(data.top, hsize);
    return xm.xasprintf("{d}", .{scroll_pos});
}

fn resolve_top_line_time(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const data = copyModeDataFromCtx(ctx) orelse return null;
    const gd = data.backing.grid;
    const hsize = gd.hsize;
    const row = hsize -| @min(data.top, hsize);
    if (row >= gd.linedata.len) return alloc.dupe(u8, "0") catch unreachable;
    return xm.xasprintf("{d}", .{gd.linedata[row].time});
}

fn resolve_rectangle_toggle(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const data = copyModeDataFromCtx(ctx) orelse return null;
    return alloc.dupe(u8, if (data.rectflag) "1" else "0") catch unreachable;
}

fn resolve_copy_cursor_x(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    _ = alloc;
    const data = copyModeDataFromCtx(ctx) orelse return null;
    return xm.xasprintf("{d}", .{data.cx});
}

fn resolve_copy_cursor_y(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    _ = alloc;
    const data = copyModeDataFromCtx(ctx) orelse return null;
    return xm.xasprintf("{d}", .{data.cy});
}

fn resolve_copy_cursor_word(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const wp = ctx_pane(ctx) orelse return null;
    const data = copyModeDataFromCtx(ctx) orelse return null;
    const gd = data.backing.grid;
    const abs_row = data.top + data.cy;
    if (abs_row >= gd.linedata.len) return alloc.dupe(u8, "") catch unreachable;

    // Read the word at the cursor position (simplified: gather non-whitespace
    // cells under and around cx).
    var start_x: u32 = data.cx;
    while (start_x > 0) : (start_x -= 1) {
        var gc: T.GridCell = undefined;
        grid.get_cell(gd, abs_row, start_x - 1, &gc);
        if (gc.data.size == 0 or gc.data.data[0] == ' ' or gc.data.data[0] == '\t') break;
    } else {
        start_x = 0;
    }
    var end_x: u32 = data.cx + 1;
    while (end_x < gd.sx) : (end_x += 1) {
        var gc: T.GridCell = undefined;
        grid.get_cell(gd, abs_row, end_x, &gc);
        if (gc.data.size == 0 or gc.data.data[0] == ' ' or gc.data.data[0] == '\t') break;
    } else {
        end_x = gd.sx;
    }

    _ = wp;
    var buf: std.ArrayList(u8) = .{};
    var col: u32 = start_x;
    while (col < end_x) : (col += 1) {
        var gc: T.GridCell = undefined;
        grid.get_cell(gd, abs_row, col, &gc);
        if (gc.isPadding()) continue;
        if (gc.data.size >= 1) {
            buf.appendSlice(alloc, gc.data.data[0..gc.data.size]) catch unreachable;
        }
    }
    return buf.toOwnedSlice(alloc) catch unreachable;
}

fn resolve_copy_cursor_line(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const data = copyModeDataFromCtx(ctx) orelse return null;
    const gd = data.backing.grid;
    const abs_row = data.top + data.cy;
    if (abs_row >= gd.linedata.len) return alloc.dupe(u8, "") catch unreachable;

    const length = grid.line_length(gd, abs_row);
    var buf: std.ArrayList(u8) = .{};
    var col: u32 = 0;
    while (col < length) : (col += 1) {
        var gc: T.GridCell = undefined;
        grid.get_cell(gd, abs_row, col, &gc);
        if (gc.isPadding()) continue;
        if (gc.data.size >= 1) {
            buf.appendSlice(alloc, gc.data.data[0..gc.data.size]) catch unreachable;
        }
    }
    return buf.toOwnedSlice(alloc) catch unreachable;
}

fn resolve_selection_start_x(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    _ = alloc;
    const data = copyModeDataFromCtx(ctx) orelse return null;
    if (data.cursordrag == .none and data.lineflag == .none) return null;
    return xm.xasprintf("{d}", .{data.selx});
}

fn resolve_selection_start_y(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    _ = alloc;
    const data = copyModeDataFromCtx(ctx) orelse return null;
    if (data.cursordrag == .none and data.lineflag == .none) return null;
    return xm.xasprintf("{d}", .{data.sely});
}

fn resolve_selection_end_x(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    _ = alloc;
    const data = copyModeDataFromCtx(ctx) orelse return null;
    if (data.cursordrag == .none and data.lineflag == .none) return null;
    return xm.xasprintf("{d}", .{data.endselx});
}

fn resolve_selection_end_y(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    _ = alloc;
    const data = copyModeDataFromCtx(ctx) orelse return null;
    if (data.cursordrag == .none and data.lineflag == .none) return null;
    return xm.xasprintf("{d}", .{data.endsely});
}

fn resolve_selection_active(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const data = copyModeDataFromCtx(ctx) orelse return null;
    if (data.cursordrag != .none) {
        return alloc.dupe(u8, "1") catch unreachable;
    }
    return alloc.dupe(u8, "0") catch unreachable;
}

fn resolve_selection_present(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const data = copyModeDataFromCtx(ctx) orelse return null;
    if (data.cursordrag == .none and data.lineflag == .none) return alloc.dupe(u8, "0") catch unreachable;
    if (data.endselx != data.selx or data.endsely != data.sely) {
        return alloc.dupe(u8, "1") catch unreachable;
    }
    return alloc.dupe(u8, "0") catch unreachable;
}

fn resolve_selection_mode(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const data = copyModeDataFromCtx(ctx) orelse return null;
    return switch (data.selflag) {
        .char => alloc.dupe(u8, "char") catch unreachable,
        .word => alloc.dupe(u8, "word") catch unreachable,
        .line => alloc.dupe(u8, "line") catch unreachable,
    };
}

// ── New format resolvers (tmux parity) ────────────────────────────────────

fn resolve_bracket_paste_flag(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const wp = ctx_pane(ctx) orelse return null;
    const screen = pane_state_screen(wp);
    return alloc.dupe(u8, if ((screen.mode & T.MODE_BRACKETPASTE) != 0) "1" else "0") catch unreachable;
}

fn resolve_buffer_mode_format(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    _ = ctx;
    return alloc.dupe(u8, "#{t/p:buffer_created}: #{buffer_sample}") catch unreachable;
}

fn resolve_client_mode_format(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    _ = ctx;
    return alloc.dupe(u8, "#{client_tty}: session #{client_session_name}") catch unreachable;
}

fn resolve_client_utf(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    return resolve_client_utf8(alloc, ctx);
}

fn resolve_client_written(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    // tmux tracks cumulative bytes written to the client tty in c->written.
    // zmux does not yet have a Client.written counter; returns 0 until that
    // accounting is wired up.
    _ = ctx.client orelse return null;
    return alloc.dupe(u8, "0") catch unreachable;
}

fn resolve_config_files(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    _ = ctx;
    const cfg = @import("cfg.zig");
    const paths = cfg.cfg_file_paths.items;
    if (paths.len == 0) return alloc.dupe(u8, "") catch unreachable;
    var out: std.ArrayList(u8) = .{};
    for (paths, 0..) |path, idx| {
        if (idx != 0) out.append(alloc, ',') catch unreachable;
        out.appendSlice(alloc, path) catch unreachable;
    }
    return out.toOwnedSlice(alloc) catch unreachable;
}

fn resolve_current_command(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    return resolve_pane_current_command(alloc, ctx);
}

fn resolve_current_path(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    return resolve_pane_current_path(alloc, ctx);
}

fn resolve_mouse_utf(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    return resolve_mouse_utf8_flag(alloc, ctx);
}

fn resolve_pane_format(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    return alloc.dupe(u8, if (ctx.format_type == .pane) "1" else "0") catch unreachable;
}

fn resolve_session_activity_flag(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    _ = ctx_session(ctx) orelse return null;
    const wl = ctx_winlink(ctx) orelse return null;
    return alloc.dupe(u8, if (wl.flags & T.WINLINK_ACTIVITY != 0) "1" else "0") catch unreachable;
}

fn resolve_session_bell_flag(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    _ = ctx_session(ctx) orelse return null;
    const wl = ctx_winlink(ctx) orelse return null;
    return alloc.dupe(u8, if (wl.flags & T.WINLINK_BELL != 0) "1" else "0") catch unreachable;
}

fn resolve_session_format(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    return alloc.dupe(u8, if (ctx.format_type == .session) "1" else "0") catch unreachable;
}

fn resolve_session_many_attached(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const s = ctx_session(ctx) orelse return null;
    return alloc.dupe(u8, if (s.attached > 1) "1" else "0") catch unreachable;
}

fn resolve_session_marked(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const s = ctx_session(ctx) orelse return null;
    const value: []const u8 = if (marked_pane_mod.check() and marked_pane_mod.marked_pane.s == s) "1" else "0";
    return alloc.dupe(u8, value) catch unreachable;
}

fn resolve_session_path(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const s = ctx_session(ctx) orelse return null;
    return alloc.dupe(u8, s.cwd) catch unreachable;
}

fn resolve_session_silence_flag(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    _ = ctx_session(ctx) orelse return null;
    const wl = ctx_winlink(ctx) orelse return null;
    return alloc.dupe(u8, if (wl.flags & T.WINLINK_SILENCE != 0) "1" else "0") catch unreachable;
}

fn resolve_session_stack(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const s = ctx_session(ctx) orelse return null;
    const curw = s.curw orelse return null;
    var out: std.ArrayList(u8) = .{};
    out.writer(alloc).print("{d}", .{curw.idx}) catch unreachable;
    for (s.lastw.items) |wl| {
        out.append(alloc, ',') catch unreachable;
        out.writer(alloc).print("{d}", .{wl.idx}) catch unreachable;
    }
    return out.toOwnedSlice(alloc) catch unreachable;
}

fn resolve_sixel_support(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    // zmux does not implement sixel graphics; always report unsupported.
    _ = ctx;
    return alloc.dupe(u8, "0") catch unreachable;
}

fn resolve_start_command(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    return resolve_pane_start_command(alloc, ctx);
}

fn resolve_start_path(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    return resolve_pane_start_path(alloc, ctx);
}

fn resolve_tree_mode_format(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    _ = ctx;
    return alloc.dupe(u8, "#{?pane_format," ++
        "#{?pane_marked,#[reverse],}" ++
        "#{pane_current_command}#{?pane_active,*,}#{?pane_marked,M,}" ++
        "#{?#{&&:#{pane_title},#{!=:#{pane_title},#{host_short}}},: \"#{pane_title}\",}" ++
        ",#{?window_format," ++
        "#{?window_marked_flag,#[reverse],}" ++
        "#{window_name}#{window_flags}" ++
        "#{?#{&&:#{==:#{window_panes},1},#{&&:#{pane_title},#{!=:#{pane_title},#{host_short}}}},: \"#{pane_title}\",}" ++
        "," ++
        "#{session_windows} windows" ++
        "#{?session_grouped, (group #{session_group}: #{session_group_list}),}" ++
        "#{?session_attached, (attached),}" ++
        "}}") catch unreachable;
}

fn resolve_uid(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    _ = ctx;
    return std.fmt.allocPrint(alloc, "{d}", .{std.os.linux.getuid()}) catch unreachable;
}

fn resolve_user(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    _ = ctx;
    const pw = c.posix_sys.getpwuid(std.os.linux.getuid()) orelse return null;
    return alloc.dupe(u8, std.mem.span(@as([*:0]const u8, @ptrCast(pw.*.pw_name)))) catch unreachable;
}

fn resolve_wrap_flag(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const wp = ctx_pane(ctx) orelse return null;
    const screen = pane_state_screen(wp);
    return alloc.dupe(u8, if ((screen.mode & T.MODE_WRAP) != 0) "1" else "0") catch unreachable;
}

fn resolve_window_active_clients(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    _ = alloc;
    const w = ctx_window(ctx) orelse return null;
    var n: u32 = 0;
    for (client_registry.clients.items) |cl| {
        const cs = cl.session orelse continue;
        const cw = cs.curw orelse continue;
        if (cw.window == w) n += 1;
    }
    return xm.xasprintf("{d}", .{n});
}

fn resolve_window_active_clients_list(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const w = ctx_window(ctx) orelse return null;
    var out: std.ArrayList(u8) = .{};
    for (client_registry.clients.items) |cl| {
        const cs = cl.session orelse continue;
        const cw = cs.curw orelse continue;
        if (cw.window == w) {
            const name = cl.name orelse continue;
            if (out.items.len != 0) out.append(alloc, ',') catch unreachable;
            out.appendSlice(alloc, name) catch unreachable;
        }
    }
    return out.toOwnedSlice(alloc) catch unreachable;
}

fn resolve_window_active_sessions(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    _ = alloc;
    const w = ctx_window(ctx) orelse return null;
    var n: u32 = 0;
    for (w.winlinks.items) |wl| {
        if (wl.session.curw == wl) n += 1;
    }
    return xm.xasprintf("{d}", .{n});
}

fn resolve_window_active_sessions_list(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const w = ctx_window(ctx) orelse return null;
    var out: std.ArrayList(u8) = .{};
    for (w.winlinks.items) |wl| {
        if (wl.session.curw == wl) {
            if (out.items.len != 0) out.append(alloc, ',') catch unreachable;
            out.appendSlice(alloc, wl.session.name) catch unreachable;
        }
    }
    return out.toOwnedSlice(alloc) catch unreachable;
}

fn resolve_window_activity(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    _ = alloc;
    const w = ctx_window(ctx) orelse return null;
    return xm.xasprintf("{d}", .{normalize_format_time(w.activity_time)});
}

fn resolve_window_cell_height(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    _ = alloc;
    const w = ctx_window(ctx) orelse return null;
    return xm.xasprintf("{d}", .{w.ypixel});
}

fn resolve_window_cell_width(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    _ = alloc;
    const w = ctx_window(ctx) orelse return null;
    return xm.xasprintf("{d}", .{w.xpixel});
}

fn resolve_window_end_flag(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const wl = ctx_winlink(ctx) orelse return null;
    const s = ctx_session(ctx) orelse return null;
    var max_idx: ?i32 = null;
    var it = s.windows.valueIterator();
    while (it.next()) |w| {
        if (max_idx == null or w.*.idx > max_idx.?)
            max_idx = w.*.idx;
    }
    const value: []const u8 = if (max_idx != null and wl.idx == max_idx.?) "1" else "0";
    return alloc.dupe(u8, value) catch unreachable;
}

fn resolve_window_format(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    return alloc.dupe(u8, if (ctx.format_type == .window) "1" else "0") catch unreachable;
}

fn resolve_window_linked_sessions(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    _ = alloc;
    const w = ctx_window(ctx) orelse return null;
    return xm.xasprintf("{d}", .{w.winlinks.items.len});
}

fn resolve_window_linked_sessions_list(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const w = ctx_window(ctx) orelse return null;
    var out: std.ArrayList(u8) = .{};
    for (w.winlinks.items) |wl| {
        if (out.items.len != 0) out.append(alloc, ',') catch unreachable;
        out.appendSlice(alloc, wl.session.name) catch unreachable;
    }
    return out.toOwnedSlice(alloc) catch unreachable;
}

fn resolve_window_marked_flag(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const wl = ctx_winlink(ctx) orelse return null;
    const value: []const u8 = if (marked_pane_mod.check() and marked_pane_mod.marked_pane.wl == wl) "1" else "0";
    return alloc.dupe(u8, value) catch unreachable;
}

fn resolve_window_stack_index(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    _ = alloc;
    const wl = ctx_winlink(ctx) orelse return null;
    const s = wl.session;
    for (s.lastw.items, 0..) |entry, idx| {
        if (entry == wl)
            return xm.xasprintf("{d}", .{idx + 1});
    }
    return xm.xasprintf("{d}", .{@as(u32, 0)});
}

fn resolve_window_start_flag(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const wl = ctx_winlink(ctx) orelse return null;
    const s = ctx_session(ctx) orelse return null;
    var min_idx: ?i32 = null;
    var it = s.windows.valueIterator();
    while (it.next()) |w| {
        if (min_idx == null or w.*.idx < min_idx.?)
            min_idx = w.*.idx;
    }
    const value: []const u8 = if (min_idx != null and wl.idx == min_idx.?) "1" else "0";
    return alloc.dupe(u8, value) catch unreachable;
}
