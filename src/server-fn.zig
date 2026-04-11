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
// Ported in part from tmux/server-fn.c.
// Original copyright:
//   Copyright (c) 2007 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

//! server-fn.zig – cross-cutting server helper functions.

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const log = @import("log.zig");
const srv = @import("server.zig");
const sess = @import("session.zig");
const win = @import("window.zig");
const layout_mod = @import("layout.zig");
const opts = @import("options.zig");
const format_mod = @import("format.zig");
const format_draw = @import("format-draw.zig");
const cmd_display_panes = @import("cmd-display-panes.zig");
const key_bindings = @import("key-bindings.zig");
const key_string = @import("key-string.zig");
const cmd_find = @import("cmd-find.zig");
const marked_pane_mod = @import("marked-pane.zig");
const input_keys = @import("input-keys.zig");
const menu = @import("menu.zig");
const mouse_runtime = @import("mouse-runtime.zig");
const pane_io = @import("pane-io.zig");
const popup = @import("popup.zig");
const screen_write = @import("screen-write.zig");
const server_client_mod = @import("server-client.zig");
const status_prompt = @import("status-prompt.zig");
const status_runtime = @import("status-runtime.zig");
const client_registry = @import("client-registry.zig");
const notify_mod = @import("notify.zig");
const resize_mod = @import("resize.zig");

pub fn server_lock() void {
    for (client_registry.clients.items) |cl| {
        if (cl.session != null) server_lock_client(cl);
    }
}

pub fn server_redraw_session(s: *T.Session) void {
    srv.server_redraw_session(s);
}

pub fn server_redraw_session_group(s: *T.Session) void {
    srv.server_redraw_session_group(s);
}

pub fn server_status_session(s: *T.Session) void {
    srv.server_status_session(s);
}

pub fn server_status_session_group(s: *T.Session) void {
    srv.server_status_session_group(s);
}

pub fn server_status_window(w: *T.Window) void {
    srv.server_status_window(w);
}

pub fn server_redraw_window(w: *T.Window) void {
    srv.server_redraw_window(w);
}

pub fn server_redraw_window_borders(w: *T.Window) void {
    srv.server_redraw_window_borders(w);
}

pub fn server_redraw_pane(wp: *T.WindowPane) void {
    srv.server_redraw_pane(wp);
}

pub fn server_lock_session(s: *T.Session) void {
    for (client_registry.clients.items) |cl| {
        if (cl.session == s) server_lock_client(cl);
    }
}

pub fn server_lock_client(cl: *T.Client) void {
    const s = cl.session orelse return;
    if (cl.flags & (T.CLIENT_CONTROL | T.CLIENT_SUSPENDED) != 0) return;

    const cmd = opts.options_get_string(s.options, "lock-command");
    if (cmd.len == 0) return;

    server_client_mod.server_client_lock(cl, cmd);
}

pub fn server_kill_window(w: *T.Window, detach_last: bool) void {
    _ = detach_last;
    if (w.references == 0) return;

    win.window_destroy_all_panes(w);

    var affected: std.ArrayList(*T.Session) = .{};
    defer affected.deinit(xm.allocator);

    var sit = sess.sessions.valueIterator();
    while (sit.next()) |s| {
        if (!sess.session_has_window(s.*, w)) continue;
        affected.append(xm.allocator, s.*) catch unreachable;
    }

    for (affected.items) |s| {
        var indices: std.ArrayList(i32) = .{};
        defer indices.deinit(xm.allocator);

        var wit = s.windows.valueIterator();
        while (wit.next()) |wl| {
            if (wl.*.window == w) indices.append(xm.allocator, wl.*.idx) catch unreachable;
        }

        for (indices.items) |idx| {
            _ = sess.session_detach_index(s, idx, "server_kill_window");
        }

        if (s.windows.count() == 0) {
            srv.server_destroy_session(s);
            sess.session_destroy(s, true, "server_kill_window");
            continue;
        }

        if (s.curw == null) s.curw = sess.session_first_winlink(s);
    }
}

pub fn server_renumber_session(s: *T.Session) void {
    if (opts.options_get_number(s.options, "renumber-windows") == 0) return;

    if (sess.session_group_contains(s)) |group| {
        for (group.sessions.items) |member|
            sess.session_renumber_windows(member);
        return;
    }

    sess.session_renumber_windows(s);
}

pub fn server_renumber_all() void {
    var it = sess.sessions.valueIterator();
    while (it.next()) |s|
        server_renumber_session(s.*);
}

pub fn server_link_window(
    src: *T.Session,
    srcwl: *T.Winlink,
    dst: *T.Session,
    dst_idx: i32,
    kill_existing: bool,
    select_dst: bool,
    cause: *?[]u8,
) i32 {
    const src_group = sess.session_group_contains(src);
    const dst_group = sess.session_group_contains(dst);
    if (src != dst and src_group != null and dst_group != null and src_group.? == dst_group.?) {
        cause.* = xm.xasprintf("sessions are grouped", .{});
        return -1;
    }

    var actual_select = select_dst;
    var actual_idx = dst_idx;

    if (actual_idx != -1) {
        if (sess.winlink_find_by_index(&dst.windows, actual_idx)) |dstwl| {
            if (dstwl.window == srcwl.window) {
                cause.* = xm.xasprintf("same index: {d}", .{actual_idx});
                return -1;
            }
            if (!kill_existing) {
                cause.* = xm.xasprintf("index in use: {d}", .{actual_idx});
                return -1;
            }
            if (dst.curw == dstwl) {
                actual_select = true;
                dst.curw = null;
            }
            _ = sess.session_detach_index(dst, actual_idx, "server_link_window -k");
        }
    } else {
        actual_idx = sess.session_next_index(dst);
    }

    const new_wl = sess.session_attach(dst, srcwl.window, actual_idx, cause) orelse return -1;
    marked_pane_mod.rebind_winlink(srcwl, new_wl);
    if (actual_select) dst.curw = new_wl;
    server_redraw_session_group(dst);
    return 0;
}

pub fn server_unlink_window(s: *T.Session, wl: *T.Winlink) void {
    if (sess.session_detach(s, wl)) {
        srv.server_destroy_session(s);
        sess.session_destroy(s, true, "server_unlink_window");
    } else {
        if (s.curw == null) s.curw = sess.session_first_winlink(s);
        server_redraw_session_group(s);
    }
}

pub fn server_destroy_pane(wp: *T.WindowPane, notify: bool) void {
    const w = wp.window;
    close_pane_io(wp);

    const remain_on_exit = opts.options_get_number(wp.options, "remain-on-exit");
    if (remain_on_exit != 0 and (wp.flags & T.PANE_STATUSREADY) == 0)
        return;

    var keep_dead_pane = false;
    switch (remain_on_exit) {
        0 => {},
        2 => {
            const status: u32 = @bitCast(wp.status);
            keep_dead_pane = !(std.posix.W.IFEXITED(status) and std.posix.W.EXITSTATUS(status) == 0);
        },
        1 => keep_dead_pane = true,
        else => {},
    }
    if (keep_dead_pane) {
        if ((wp.flags & T.PANE_STATUSDRAWN) != 0)
            return;
        wp.flags |= T.PANE_STATUSDRAWN;
        wp.dead_time = std.time.timestamp();
        if (notify)
            notify_mod.notify_pane("pane-died", wp);
        draw_remain_on_exit(wp);
        wp.base.mode &= ~@as(i32, T.MODE_CURSOR);
        wp.flags |= T.PANE_REDRAW;
        return;
    }

    if (notify)
        notify_mod.notify_pane("pane-exited", wp);

    if (w.panes.items.len <= 1) {
        server_kill_window(w, true);
        return;
    }

    _ = win.window_unzoom(w);
    if (layout_mod.layout_close_pane(wp))
        win.window_remove_pane_layout_managed(w, wp)
    else
        win.window_remove_pane(w, wp);
    srv.server_redraw_window(w);
    server_status_window(w);
}

fn close_pane_io(wp: *T.WindowPane) void {
    pane_io.pane_io_stop(wp);
    if (wp.fd >= 0) {
        std.posix.close(wp.fd);
        wp.fd = -1;
    }
}

fn draw_remain_on_exit(wp: *T.WindowPane) void {
    const fmt = opts.options_get_string(wp.options, "remain-on-exit-format");
    if (fmt.len == 0) return;
    if (wp.base.grid.sx == 0 or wp.base.grid.sy == 0) return;

    const expanded = format_mod.format_single(null, fmt, null, null, null, wp);
    defer xm.allocator.free(expanded);

    var ctx = T.ScreenWriteCtx{ .s = &wp.base };
    screen_write.set_scroll_region(&ctx, 0, wp.base.grid.sy - 1);
    screen_write.cursor_to(&ctx, wp.base.grid.sy - 1, 0);
    screen_write.newline(&ctx);
    format_draw.format_draw(&ctx, &T.grid_default_cell, wp.base.grid.sx, expanded);
}

pub fn server_client_handle_key(cl: *T.Client, event: *T.key_event) bool {
    const s = cl.session orelse return false;
    const wl = s.curw orelse return false;
    const wp = wl.window.active orelse return false;
    const now = std.time.milliTimestamp();
    var target_session = s;
    var target_wl = wl;
    var target_wp = wp;
    var mouse_find_state: T.CmdFindState = .{};
    var binding_find_state: ?*T.CmdFindState = null;

    cl.last_activity_time = cl.activity_time;
    cl.activity_time = now;
    sess.session_update_activity(s, now);

    switch (event.key) {
        T.KEYC_REPORT_LIGHT_THEME => {
            cl.theme = .light;
            notify_mod.notify_client("client-light-theme", cl);
            sess.session_theme_changed(s);
            return true;
        },
        T.KEYC_REPORT_DARK_THEME => {
            cl.theme = .dark;
            notify_mod.notify_client("client-dark-theme", cl);
            sess.session_theme_changed(s);
            return true;
        },
        else => {},
    }

    if (popup.overlay_active(cl)) {
        if (popup.handle_key(cl, event))
            return true;
    }

    if (menu.overlay_active(cl)) {
        if (menu.handle_key(cl, event))
            return true;
    }

    if (cmd_display_panes.overlay_active(cl)) {
        if (cmd_display_panes.handle_key(cl, event))
            return true;
    }

    if (status_runtime.status_message_active(cl)) {
        if (status_runtime.status_message_ignore_keys(cl))
            return true;
        status_runtime.status_message_clear(cl);
    }

    if (status_prompt.status_prompt_handle_key(cl, event)) return true;

    if (event.key == T.KEYC_MOUSE or event.key == T.KEYC_DOUBLECLICK) {
        if (!mouse_runtime.translate_client_mouse_event(cl, event)) {
            server_client_mod.server_client_refresh_click_timer(cl);
            return true;
        }
        server_client_mod.server_client_refresh_click_timer(cl);
        if ((event.key & T.KEYC_MASK_KEY) == T.KEYC_DRAGGING) {
            if (cl.tty.mouse_drag_update) |update|
                update(cl, &event.m);
            return true;
        }
        if (cmd_find.cmd_find_from_mouse(&mouse_find_state, &event.m, 0)) {
            binding_find_state = &mouse_find_state;
            target_session = mouse_find_state.s orelse s;
            target_wl = mouse_find_state.wl orelse wl;
            target_wp = mouse_find_state.wp orelse wp;
        }

        if (mouse_runtime.key_target(event.key)) |target| {
            const base = mouse_runtime.key_base(event.key) orelse T.KEYC_UNKNOWN;
            if (base == T.KEYC_MOUSEMOVE and target == .pane and target_wp != target_wl.window.active and
                opts.options_get_number(target_session.options, "focus-follows-mouse") != 0)
            {
                if (win.window_set_active_pane(target_wl.window, target_wp, true)) {
                    srv.server_redraw_window(target_wl.window);
                    server_status_window(target_wl.window);
                }
            }

            if (target == .pane) {
                if (win.window_pane_mode(target_wp)) |wme| {
                    if (wme.mode.key) |mode_key| {
                        mode_key(wme, cl, target_session, target_wl, event.key & ~T.KEYC_MASK_FLAGS, &event.m);
                        return true;
                    }
                }
            }
        }
    }

    const client_table_name = if (cl.key_table_name) |name| name else blk: {
        const configured = opts.options_get_string(s.options, "key-table");
        break :blk if (configured.len != 0) configured else "root";
    };
    const pane_mode = win.window_pane_mode(wp);
    const mode_table_name = if (std.mem.eql(u8, client_table_name, "root") and pane_mode != null and pane_mode.?.mode.key_table != null)
        pane_mode.?.mode.key_table.?(pane_mode.?)
    else
        null;
    const current_table = mode_table_name orelse client_table_name;
    const using_mode_table = mode_table_name != null;

    if (!using_mode_table and std.mem.eql(u8, current_table, "root") and is_prefix_key(s, event.key)) {
        server_client_mod.server_client_set_key_table(cl, "prefix");
        return true;
    }

    // Check prefix-timeout: if we're in the prefix table and the timeout has
    // been exceeded, revert to root and fall through to default key handling.
    // Mirrors tmux: server_client_key_callback prefix-timeout logic.
    if (!using_mode_table and opts.options_ready and std.mem.eql(u8, current_table, "prefix")) {
        const prefix_delay = opts.options_get_number(opts.global_options, "prefix-timeout");
        if (prefix_delay > 0 and
            server_client_mod.server_client_key_table_activity_diff(cl) > @as(u64, @intCast(prefix_delay)))
        {
            const bd = if (key_bindings.key_bindings_get_table(current_table, false)) |tbl|
                lookup_binding(tbl, event.key)
            else
                null;
            // If repeating is active and this is a repeating binding, ignore the timeout.
            if (bd != null and (cl.flags & T.CLIENT_REPEAT != 0) and (bd.?.flags & T.KEY_BINDING_REPEAT != 0)) {
                log.log_debug("prefix timeout ignored, repeat is active", .{});
            } else {
                log.log_debug("prefix timeout exceeded", .{});
                server_client_mod.server_client_set_key_table(cl, null);
                cl.flags &= ~@as(u64, T.CLIENT_REPEAT);
                cl.flags |= T.CLIENT_REDRAWSTATUS;
                // Fall through to handle the key in the root table.
                return server_client_handle_key(cl, event);
            }
        }
    }

    if (key_bindings.key_bindings_get_table(current_table, false)) |table| {
        if (lookup_binding(table, event.key)) |binding| {
            _ = key_bindings.key_bindings_dispatch(binding, null, cl, event, binding_find_state);
            if (!using_mode_table and !std.mem.eql(u8, current_table, "root"))
                server_client_mod.server_client_set_key_table(cl, null);
            return true;
        }
    }

    if (using_mode_table) {
        if (pane_mode) |wme| {
            if (wme.mode.key) |mode_key|
                mode_key(wme, cl, s, wl, normalize_key(event.key), null);
        }
        return true;
    }

    if (!std.mem.eql(u8, current_table, "root")) {
        server_client_mod.server_client_set_key_table(cl, null);
        return true;
    }

    // If the active pane is in a mode that has a .key handler but no
    // .key_table, dispatch unbound root-table keys to the mode instead
    // of sending them to the pane PTY.  This covers modes like the
    // server-print view mode which intercept all keys to exit.
    if (pane_mode) |wme| {
        if (wme.mode.key_table == null) {
            if (wme.mode.key) |mode_key| {
                mode_key(wme, cl, s, wl, normalize_key(event.key), null);
                return true;
            }
        }
    }

    if (T.keycIsMouse(event.key)) {
        if (target_wp.fd < 0 or target_wp.flags & T.PANE_INPUTOFF != 0) return true;

        var mouse_buf: [40]u8 = undefined;
        const bytes = input_keys.input_key_mouse_pane(target_wp, &event.m, &mouse_buf);
        if (bytes.len != 0) write_pane_bytes(target_wp.fd, bytes);
        return true;
    }
    if (wp.fd < 0 or event.len == 0) return false;
    write_pane_bytes(wp.fd, event.data[0..event.len]);
    win.window_pane_synchronize_key_bytes(wp, event.key, event.data[0..event.len]);
    return true;
}

fn lookup_binding(table: *T.KeyTable, key: T.key_code) ?*T.KeyBinding {
    if (key_bindings.key_bindings_get(table, key)) |binding| return binding;
    if (normalize_key(key) == T.KEYC_ANY) return null;
    return key_bindings.key_bindings_get(table, T.KEYC_ANY);
}

fn is_prefix_key(s: *T.Session, key: T.key_code) bool {
    return prefix_option_matches(s, "prefix", key) or prefix_option_matches(s, "prefix2", key);
}

fn prefix_option_matches(s: *T.Session, name: []const u8, key: T.key_code) bool {
    const text = opts.options_get_string(s.options, name);
    if (text.len == 0) return false;
    const parsed = key_string.key_string_lookup_string(text);
    if (parsed == T.KEYC_UNKNOWN or parsed == T.KEYC_NONE) return false;
    return normalize_key(parsed) == normalize_key(key);
}

fn normalize_key(key: T.key_code) T.key_code {
    return key & ~(T.KEYC_MASK_FLAGS);
}

fn write_pane_bytes(fd: i32, bytes: []const u8) void {
    var rest = bytes;
    while (rest.len > 0) {
        const written = std.posix.write(fd, rest) catch return;
        if (written == 0) return;
        rest = rest[written..];
    }
}

// Placeholder for format_tree.zig integration
pub fn server_format_session(
    _ft: ?*anyopaque,
    _s: *T.Session,
) void {
    _ = _ft;
    _ = _s;
}

pub fn server_redraw_client(cl: *T.Client) void {
    cl.flags |= T.CLIENT_REDRAW;
}

pub fn server_status_client(cl: *T.Client) void {
    cl.flags |= T.CLIENT_REDRAWSTATUS;
}

pub fn server_check_unattached() void {
    var to_destroy: std.ArrayList(*T.Session) = .{};
    defer to_destroy.deinit(xm.allocator);

    var it = sess.sessions.valueIterator();
    while (it.next()) |s| {
        if (s.*.attached != 0) continue;
        const mode = opts.options_get_number(s.*.options, "destroy-unattached");
        switch (mode) {
            0 => continue,
            1 => {},
            2 => {
                const sg = sess.session_group_contains(s.*);
                if (sg == null or sess.session_group_count(sg.?) <= 1)
                    continue;
            },
            3 => {
                const sg = sess.session_group_contains(s.*);
                if (sg != null and sess.session_group_count(sg.?) == 1)
                    continue;
            },
            else => continue,
        }
        to_destroy.append(xm.allocator, s.*) catch unreachable;
    }

    for (to_destroy.items) |s|
        sess.session_destroy(s, true, "server_check_unattached");
}

fn server_destroy_session_group(s: *T.Session) void {
    if (sess.session_group_contains(s)) |sg| {
        var members: std.ArrayList(*T.Session) = .{};
        defer members.deinit(xm.allocator);
        for (sg.sessions.items) |member|
            members.append(xm.allocator, member) catch unreachable;
        for (members.items) |member| {
            srv.server_destroy_session(member);
            sess.session_destroy(member, true, "server_destroy_session_group");
        }
    } else {
        srv.server_destroy_session(s);
        sess.session_destroy(s, true, "server_destroy_session_group");
    }
}

pub fn server_kill_pane(wp: *T.WindowPane) void {
    const w = wp.window;
    if (win.window_count_panes(w) == 1) {
        server_kill_window(w, true);
        resize_mod.recalculate_sizes();
    } else {
        _ = win.window_unzoom(w);
        if (layout_mod.layout_close_pane(wp))
            win.window_remove_pane_layout_managed(w, wp)
        else
            win.window_remove_pane(w, wp);
        srv.server_redraw_window(w);
    }
}

pub fn server_unzoom_window(w: *T.Window) void {
    if (win.window_unzoom(w))
        srv.server_redraw_window(w);
}

fn server_find_session(
    s: *T.Session,
    comptime pred: fn (*T.Session, ?*T.Session) bool,
) ?*T.Session {
    var best: ?*T.Session = null;
    var it = sess.sessions.valueIterator();
    while (it.next()) |candidate| {
        if (candidate.* == s) continue;
        if (pred(candidate.*, best))
            best = candidate.*;
    }
    return best;
}

fn server_newer_session(s_loop: *T.Session, s_out: ?*T.Session) bool {
    const out = s_out orelse return true;
    return s_loop.activity_time > out.activity_time;
}

fn server_newer_detached_session(s_loop: *T.Session, s_out: ?*T.Session) bool {
    if (s_loop.attached != 0) return false;
    return server_newer_session(s_loop, s_out);
}

test "server_redraw_client and server_status_client set client redraw flags" {
    const env_mod = @import("environ.zig");

    var cl = T.Client{
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{},
        .flags = 0,
    };
    defer env_mod.environ_free(cl.environ);
    cl.tty = .{ .client = &cl };

    server_redraw_client(&cl);
    try std.testing.expect(cl.flags & T.CLIENT_REDRAW != 0);
    cl.flags = 0;
    server_status_client(&cl);
    try std.testing.expect(cl.flags & T.CLIENT_REDRAWSTATUS != 0);
}

test "server_destroy_pane removes non-last pane and reassigns active pane" {
    const opts_mod = @import("options.zig");
    const layout = @import("layout.zig");

    win.window_init_globals(xm.allocator);
    opts_mod.global_w_options = opts_mod.options_create(null);
    defer opts_mod.options_free(opts_mod.global_w_options);
    opts_mod.options_default_all(opts_mod.global_w_options, T.OPTIONS_TABLE_WINDOW);

    const w = win.window_create(80, 24, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    defer win.window_remove_ref(w, "test");

    const first = win.window_add_pane(w, null, 80, 24);
    layout.layout_init(w, first);
    const second_cell = layout.layout_split_pane(first, .leftright, -1, 0) orelse return error.SplitFailed;
    const second = win.window_add_pane(w, null, 40, 24);
    layout.layout_assign_pane(second_cell, second, 0);
    w.active = second;
    w.references = 1;

    server_destroy_pane(second, false);

    try std.testing.expectEqual(@as(usize, 1), w.panes.items.len);
    try std.testing.expectEqual(first, w.active.?);
    try std.testing.expectEqual(first, w.panes.items[0]);
    try std.testing.expect(w.layout_root != null);
    try std.testing.expectEqual(T.LayoutType.windowpane, w.layout_root.?.type);
    try std.testing.expect(w.layout_root.?.wp == first);
}

test "server_destroy_pane keeps a dead pane and draws remain-on-exit text" {
    const grid = @import("grid.zig");
    const opts_mod = @import("options.zig");

    win.window_init_globals(xm.allocator);
    opts_mod.global_w_options = opts_mod.options_create(null);
    defer opts_mod.options_free(opts_mod.global_w_options);
    opts_mod.options_default_all(opts_mod.global_w_options, T.OPTIONS_TABLE_WINDOW);

    const w = win.window_create(24, 3, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    defer win.window_remove_ref(w, "test");
    const wp = win.window_add_pane(w, null, 24, 3);
    w.active = wp;
    w.references = 1;

    const pipe_fds = try std.posix.pipe();
    defer std.posix.close(pipe_fds[0]);
    wp.fd = pipe_fds[1];
    opts_mod.options_set_number(wp.options, "remain-on-exit", 1);
    wp.flags |= T.PANE_STATUSREADY;
    wp.status = 7 << 8;

    server_destroy_pane(wp, false);

    try std.testing.expectEqual(@as(usize, 1), w.panes.items.len);
    try std.testing.expectEqual(@as(i32, -1), wp.fd);
    try std.testing.expect(wp.flags & T.PANE_STATUSDRAWN != 0);
    try std.testing.expect(wp.flags & T.PANE_REDRAW != 0);
    try std.testing.expect(wp.dead_time != 0);
    try std.testing.expect(wp.base.mode & T.MODE_CURSOR == 0);

    const line = grid.string_cells(wp.base.grid, wp.base.grid.sy - 1, wp.base.grid.sx, .{ .trim_trailing_spaces = true });
    defer xm.allocator.free(line);
    try std.testing.expectEqualStrings("Pane is dead (7)", line);
}

test "server_destroy_pane waits for remain-on-exit status before drawing or removing" {
    const opts_mod = @import("options.zig");

    win.window_init_globals(xm.allocator);
    opts_mod.global_w_options = opts_mod.options_create(null);
    defer opts_mod.options_free(opts_mod.global_w_options);
    opts_mod.options_default_all(opts_mod.global_w_options, T.OPTIONS_TABLE_WINDOW);

    const w = win.window_create(24, 3, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    defer win.window_remove_ref(w, "test");
    const wp = win.window_add_pane(w, null, 24, 3);
    w.active = wp;
    w.references = 1;

    const pipe_fds = try std.posix.pipe();
    defer std.posix.close(pipe_fds[0]);
    wp.fd = pipe_fds[1];
    opts_mod.options_set_number(wp.options, "remain-on-exit", 1);

    server_destroy_pane(wp, false);

    try std.testing.expectEqual(@as(usize, 1), w.panes.items.len);
    try std.testing.expectEqual(@as(i32, -1), wp.fd);
    try std.testing.expect(wp.flags & T.PANE_STATUSDRAWN == 0);
    try std.testing.expect(wp.flags & T.PANE_REDRAW == 0);
    try std.testing.expectEqual(@as(i64, 0), wp.dead_time);
    try std.testing.expect(wp.base.mode & T.MODE_CURSOR != 0);
}

test "server_destroy_pane removes a zero-exit pane when remain-on-exit is failed" {
    const opts_mod = @import("options.zig");

    win.window_init_globals(xm.allocator);
    opts_mod.global_w_options = opts_mod.options_create(null);
    defer opts_mod.options_free(opts_mod.global_w_options);
    opts_mod.options_default_all(opts_mod.global_w_options, T.OPTIONS_TABLE_WINDOW);

    const w = win.window_create(80, 24, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    defer win.window_remove_ref(w, "test");

    const first = win.window_add_pane(w, null, 80, 24);
    const second = win.window_add_pane(w, null, 80, 24);
    w.active = second;
    w.references = 1;

    opts_mod.options_set_number(second.options, "remain-on-exit", 2);
    second.flags |= T.PANE_STATUSREADY;
    second.status = 0;

    server_destroy_pane(second, false);

    try std.testing.expectEqual(@as(usize, 1), w.panes.items.len);
    try std.testing.expectEqual(first, w.active.?);
    try std.testing.expectEqual(first, w.panes.items[0]);
}

test "server_destroy_pane queues pane-died hooks for remain-on-exit panes" {
    const cmdq = @import("cmd-queue.zig");
    const env_mod = @import("environ.zig");
    const opts_mod = @import("options.zig");

    cmdq.cmdq_reset_for_tests();
    defer cmdq.cmdq_reset_for_tests();

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

    const s = sess.session_create(null, "pane-died-hook", "/", env_mod.environ_create(), opts_mod.options_create(opts_mod.global_s_options), null);
    defer if (sess.session_find("pane-died-hook") != null) sess.session_destroy(s, false, "test");

    const w = win.window_create(24, 3, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    const wp = win.window_add_pane(w, null, 24, 3);
    w.active = wp;

    var cause: ?[]u8 = null;
    _ = sess.session_attach(s, w, -1, &cause).?;
    while (cmdq.cmdq_next(null) != 0) {}

    opts_mod.options_set_array(w.options, "pane-died", &.{
        "set-environment -g -F HOOK_RESULT '#{hook}:#{hook_pane}'",
    });

    const pipe_fds = try std.posix.pipe();
    defer std.posix.close(pipe_fds[0]);
    wp.fd = pipe_fds[1];
    opts_mod.options_set_number(wp.options, "remain-on-exit", 1);
    wp.flags |= T.PANE_STATUSREADY;
    wp.status = 7 << 8;

    const expected = try std.fmt.allocPrint(xm.allocator, "pane-died:%{d}", .{wp.id});
    defer xm.allocator.free(expected);

    server_destroy_pane(wp, true);
    while (cmdq.cmdq_next(null) != 0) {}

    try std.testing.expectEqualStrings(expected, env_mod.environ_find(env_mod.global_environ, "HOOK_RESULT").?.value.?);
}

test "server_destroy_pane queues pane-exited hooks before removing the pane" {
    const cmdq = @import("cmd-queue.zig");
    const env_mod = @import("environ.zig");
    const opts_mod = @import("options.zig");

    cmdq.cmdq_reset_for_tests();
    defer cmdq.cmdq_reset_for_tests();

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

    const s = sess.session_create(null, "pane-exited-hook", "/", env_mod.environ_create(), opts_mod.options_create(opts_mod.global_s_options), null);
    defer if (sess.session_find("pane-exited-hook") != null) sess.session_destroy(s, false, "test");

    const w = win.window_create(80, 24, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    const first = win.window_add_pane(w, null, 80, 24);
    const second = win.window_add_pane(w, null, 80, 24);
    w.active = second;

    var cause: ?[]u8 = null;
    _ = sess.session_attach(s, w, -1, &cause).?;
    while (cmdq.cmdq_next(null) != 0) {}

    opts_mod.options_set_array(w.options, "pane-exited", &.{
        "set-environment -g -F HOOK_RESULT '#{hook}:#{hook_pane}'",
    });

    const expected = try std.fmt.allocPrint(xm.allocator, "pane-exited:%{d}", .{second.id});
    defer xm.allocator.free(expected);

    server_destroy_pane(second, true);
    while (cmdq.cmdq_next(null) != 0) {}

    try std.testing.expectEqual(@as(usize, 1), w.panes.items.len);
    try std.testing.expectEqual(first, w.active.?);
    try std.testing.expectEqualStrings(expected, env_mod.environ_find(env_mod.global_environ, "HOOK_RESULT").?.value.?);
}

test "server_client_handle_key uses prefix table and queues bound commands" {
    const env_mod = @import("environ.zig");
    const opts_mod = @import("options.zig");
    const spawn = @import("spawn.zig");
    const cmdq = @import("cmd-queue.zig");

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
    key_bindings.key_bindings_init();

    const s = sess.session_create(null, "key-dispatch", "/", env_mod.environ_create(), opts_mod.options_create(opts_mod.global_s_options), null);
    defer if (sess.session_find("key-dispatch") != null) sess.session_destroy(s, false, "test");

    var cause: ?[]u8 = null;
    var sc: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    _ = spawn.spawn_window(&sc, &cause).?;

    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);
    var cl = T.Client{
        .environ = env,
        .tty = undefined,
        .status = .{},
        .flags = T.CLIENT_ATTACHED,
        .session = s,
    };
    cl.tty.client = &cl;

    var prefix_event = T.key_event{ .key = @as(T.key_code, 'b') | T.KEYC_CTRL, .data = std.mem.zeroes([16]u8), .len = 1 };
    prefix_event.data[0] = 0x02;
    _ = server_client_handle_key(&cl, &prefix_event);
    try std.testing.expectEqualStrings("prefix", cl.key_table_name.?);

    var create_event = T.key_event{ .key = 'c', .data = std.mem.zeroes([16]u8), .len = 1 };
    create_event.data[0] = 'c';
    _ = server_client_handle_key(&cl, &create_event);
    try std.testing.expect(cl.key_table_name == null);
    _ = cmdq.cmdq_next(&cl);
    try std.testing.expectEqual(@as(usize, 2), s.windows.count());
}

test "server_client_handle_key routes default keys through the active pane mode table" {
    const args_mod = @import("arguments.zig");
    const cmdq = @import("cmd-queue.zig");
    const env_mod = @import("environ.zig");
    const opts_mod = @import("options.zig");
    const spawn = @import("spawn.zig");
    const window_copy = @import("window-copy.zig");

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
    key_bindings.key_bindings_init();

    const s = sess.session_create(null, "key-copy-mode", "/", env_mod.environ_create(), opts_mod.options_create(opts_mod.global_s_options), null);
    defer if (sess.session_find("key-copy-mode") != null) sess.session_destroy(s, false, "test");

    var cause: ?[]u8 = null;
    var sc: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const wl = spawn.spawn_window(&sc, &cause).?;
    const wp = wl.window.active.?;

    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);
    var cl = T.Client{
        .environ = env,
        .tty = undefined,
        .status = .{},
        .flags = T.CLIENT_ATTACHED,
        .session = s,
    };
    cl.tty.client = &cl;

    var args = args_mod.Arguments.init(xm.allocator);
    defer args.deinit();
    _ = window_copy.enterMode(wp, wp, &args);
    try std.testing.expectEqual(&window_copy.window_copy_mode, win.window_pane_mode(wp).?.mode);

    var event = T.key_event{
        .key = 'q',
        .data = std.mem.zeroes([16]u8),
        .len = 1,
    };
    event.data[0] = 'q';
    try std.testing.expect(server_client_handle_key(&cl, &event));
    _ = cmdq.cmdq_next(&cl);
    try std.testing.expect(win.window_pane_mode(wp) == null);
}

test "server_client_handle_key forwards unbound keys to pane" {
    const env_mod = @import("environ.zig");
    const opts_mod = @import("options.zig");
    const spawn = @import("spawn.zig");

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
    key_bindings.key_bindings_init();

    const s = sess.session_create(null, "key-forward", "/", env_mod.environ_create(), opts_mod.options_create(opts_mod.global_s_options), null);
    defer if (sess.session_find("key-forward") != null) sess.session_destroy(s, false, "test");

    var cause: ?[]u8 = null;
    var sc: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const wl = spawn.spawn_window(&sc, &cause).?;
    const wp = wl.window.active.?;

    const pipe_fds = try std.posix.pipe();
    defer std.posix.close(pipe_fds[0]);
    wp.fd = pipe_fds[1];
    defer {
        if (wp.fd >= 0) std.posix.close(wp.fd);
        wp.fd = -1;
    }

    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);
    var cl = T.Client{
        .environ = env,
        .tty = undefined,
        .status = .{},
        .flags = T.CLIENT_ATTACHED,
        .session = s,
    };
    cl.tty.client = &cl;

    var event = T.key_event{ .key = 'x', .data = std.mem.zeroes([16]u8), .len = 1 };
    event.data[0] = 'x';
    _ = server_client_handle_key(&cl, &event);

    var buf: [8]u8 = undefined;
    const n = try std.posix.read(pipe_fds[0], &buf);
    try std.testing.expectEqualStrings("x", buf[0..n]);
}

test "server_client_handle_key dispatches to mode .key when mode has no key_table" {
    const env_mod = @import("environ.zig");
    const opts_mod = @import("options.zig");
    const spawn = @import("spawn.zig");

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
    key_bindings.key_bindings_init();

    const s = sess.session_create(null, "key-viewmode", "/", env_mod.environ_create(), opts_mod.options_create(opts_mod.global_s_options), null);
    defer if (sess.session_find("key-viewmode") != null) sess.session_destroy(s, false, "test");

    var cause: ?[]u8 = null;
    var sc: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const wl = spawn.spawn_window(&sc, &cause).?;
    const wp = wl.window.active.?;

    // Wire a pipe so we can detect whether bytes leak to the PTY.
    const pipe_fds = try std.posix.pipe();
    defer std.posix.close(pipe_fds[0]);
    wp.fd = pipe_fds[1];
    defer {
        if (wp.fd >= 0) std.posix.close(wp.fd);
        wp.fd = -1;
    }

    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);
    var cl = T.Client{
        .environ = env,
        .tty = undefined,
        .status = .{},
        .flags = T.CLIENT_ATTACHED,
        .session = s,
    };
    cl.tty.client = &cl;

    // Push a custom test mode that has .key but no .key_table.
    var mode_exited = false;
    const test_mode = T.WindowMode{
        .name = "test-keyonly-mode",
        .key = struct {
            fn key(wme: *T.WindowModeEntry, _: ?*T.Client, _: *T.Session, _: *T.Winlink, _: T.key_code, _: ?*const T.MouseEvent) void {
                const flag: *bool = @ptrCast(@alignCast(wme.data));
                flag.* = true;
            }
        }.key,
    };
    const window_mode_runtime = @import("window-mode-runtime.zig");
    _ = window_mode_runtime.pushMode(wp, &test_mode, @ptrCast(&mode_exited), null);
    try std.testing.expect(win.window_pane_mode(wp) != null);

    // Send a key that is NOT bound in the root table.
    var event = T.key_event{ .key = 'j', .data = std.mem.zeroes([16]u8), .len = 1 };
    event.data[0] = 'j';
    _ = server_client_handle_key(&cl, &event);

    // The mode's .key handler should have fired, NOT sent 'j' to the PTY.
    try std.testing.expect(mode_exited);

    // Verify nothing was written to the PTY pipe.
    var poll_fds = [_]std.posix.pollfd{.{
        .fd = pipe_fds[0],
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    const ready = try std.posix.poll(&poll_fds, 0);
    try std.testing.expectEqual(@as(usize, 0), ready);

    _ = window_mode_runtime.popMode(wp, win.window_pane_mode(wp).?);
}

test "server_client_handle_key records reported client theme before overlays" {
    const env_mod = @import("environ.zig");
    const opts_mod = @import("options.zig");
    const spawn = @import("spawn.zig");

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

    const s = sess.session_create(null, "key-theme-report", "/", env_mod.environ_create(), opts_mod.options_create(opts_mod.global_s_options), null);
    defer if (sess.session_find("key-theme-report") != null) sess.session_destroy(s, false, "test");

    var cause: ?[]u8 = null;
    var sc: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const wl = spawn.spawn_window(&sc, &cause).?;
    const wp = wl.window.active.?;

    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);
    var cl = T.Client{
        .environ = env,
        .tty = undefined,
        .status = .{},
        .flags = T.CLIENT_ATTACHED,
        .session = s,
    };
    cl.tty.client = &cl;

    var dark = T.key_event{ .key = T.KEYC_REPORT_DARK_THEME };
    try std.testing.expect(server_client_handle_key(&cl, &dark));
    try std.testing.expectEqual(T.ClientTheme.dark, cl.theme);
    try std.testing.expect(wp.flags & T.PANE_THEMECHANGED != 0);

    wp.flags &= ~@as(u32, T.PANE_THEMECHANGED);
    var light = T.key_event{ .key = T.KEYC_REPORT_LIGHT_THEME };
    try std.testing.expect(server_client_handle_key(&cl, &light));
    try std.testing.expectEqual(T.ClientTheme.light, cl.theme);
    try std.testing.expect(wp.flags & T.PANE_THEMECHANGED != 0);
}

test "server_client_handle_key routes through the status-message runtime before pane input" {
    const env_mod = @import("environ.zig");
    const opts_mod = @import("options.zig");
    const spawn = @import("spawn.zig");

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
    key_bindings.key_bindings_init();

    const s = sess.session_create(null, "status-message-key", "/", env_mod.environ_create(), opts_mod.options_create(opts_mod.global_s_options), null);
    defer if (sess.session_find("status-message-key") != null) sess.session_destroy(s, false, "test");

    var cause: ?[]u8 = null;
    var sc: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const wl = spawn.spawn_window(&sc, &cause).?;
    const wp = wl.window.active.?;

    const pipe_fds = try std.posix.pipe();
    defer std.posix.close(pipe_fds[0]);
    wp.fd = pipe_fds[1];
    defer {
        if (wp.fd >= 0) std.posix.close(wp.fd);
        wp.fd = -1;
    }

    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);
    var cl = T.Client{
        .environ = env,
        .tty = undefined,
        .status = .{},
        .flags = T.CLIENT_ATTACHED,
        .session = s,
    };
    cl.tty.client = &cl;

    status_runtime.status_message_set_text(&cl, 0, true, false, false, "hello");
    try std.testing.expect(status_runtime.status_message_active(&cl));

    var event = T.key_event{ .key = 'x', .data = std.mem.zeroes([16]u8), .len = 1 };
    event.data[0] = 'x';
    try std.testing.expect(server_client_handle_key(&cl, &event));
    try std.testing.expect(!status_runtime.status_message_active(&cl));

    var buf: [8]u8 = undefined;
    const n = try std.posix.read(pipe_fds[0], &buf);
    try std.testing.expectEqualStrings("x", buf[0..n]);

    status_runtime.status_message_set_text(&cl, 1, true, true, false, "locked");
    try std.testing.expect(status_runtime.status_message_active(&cl));
    try std.testing.expect(server_client_handle_key(&cl, &event));
    try std.testing.expect(status_runtime.status_message_active(&cl));
    status_runtime.status_message_clear(&cl);
}

test "server_client_handle_key mirrors unbound keys to synchronized panes" {
    const env_mod = @import("environ.zig");
    const opts_mod = @import("options.zig");
    const spawn = @import("spawn.zig");

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
    key_bindings.key_bindings_init();

    const s = sess.session_create(null, "key-forward-sync", "/", env_mod.environ_create(), opts_mod.options_create(opts_mod.global_s_options), null);
    defer if (sess.session_find("key-forward-sync") != null) sess.session_destroy(s, false, "test");

    var cause: ?[]u8 = null;
    var sc: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const wl = spawn.spawn_window(&sc, &cause).?;
    const wp = wl.window.active.?;
    const sibling = win.window_add_pane(wl.window, null, wp.sx, wp.sy);

    const source_pipe = try std.posix.pipe();
    const sibling_pipe = try std.posix.pipe();
    defer std.posix.close(source_pipe[0]);
    defer std.posix.close(sibling_pipe[0]);
    wp.fd = source_pipe[1];
    sibling.fd = sibling_pipe[1];
    defer {
        if (wp.fd >= 0) std.posix.close(wp.fd);
        if (sibling.fd >= 0) std.posix.close(sibling.fd);
        wp.fd = -1;
        sibling.fd = -1;
    }

    opts_mod.options_set_number(wp.options, "synchronize-panes", 1);
    opts_mod.options_set_number(sibling.options, "synchronize-panes", 1);

    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);
    var cl = T.Client{
        .environ = env,
        .tty = undefined,
        .status = .{},
        .flags = T.CLIENT_ATTACHED,
        .session = s,
    };
    cl.tty.client = &cl;

    var event = T.key_event{ .key = 'x', .data = std.mem.zeroes([16]u8), .len = 1 };
    event.data[0] = 'x';
    _ = server_client_handle_key(&cl, &event);

    var source_buf: [8]u8 = undefined;
    const source_len = try std.posix.read(source_pipe[0], &source_buf);
    try std.testing.expectEqualStrings("x", source_buf[0..source_len]);

    var sibling_buf: [8]u8 = undefined;
    const sibling_len = try std.posix.read(sibling_pipe[0], &sibling_buf);
    try std.testing.expectEqualStrings("x", sibling_buf[0..sibling_len]);
}

test "server_client_handle_key routes raw mouse events through the shared pane mouse runtime" {
    const env_mod = @import("environ.zig");
    const opts_mod = @import("options.zig");
    const spawn = @import("spawn.zig");

    const ModeState = struct {
        calls: usize = 0,
        last_key: T.key_code = T.KEYC_NONE,
        saw_mouse: bool = false,
    };

    const mode_callbacks = struct {
        fn key(
            wme: *T.WindowModeEntry,
            client: ?*T.Client,
            session: *T.Session,
            wl: *T.Winlink,
            key_code: T.key_code,
            mouse: ?*const T.MouseEvent,
        ) void {
            _ = client;
            _ = session;
            _ = wl;
            const state: *ModeState = @ptrCast(@alignCast(wme.data.?));
            state.calls += 1;
            state.last_key = key_code;
            state.saw_mouse = mouse != null;
        }
    };

    const test_mode = T.WindowMode{
        .name = "server-fn-mouse-test",
        .key = mode_callbacks.key,
    };

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
    key_bindings.key_bindings_init();

    const s = sess.session_create(null, "key-mouse-runtime", "/", env_mod.environ_create(), opts_mod.options_create(opts_mod.global_s_options), null);
    defer if (sess.session_find("key-mouse-runtime") != null) sess.session_destroy(s, false, "test");

    var cause: ?[]u8 = null;
    var sc: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const wl = spawn.spawn_window(&sc, &cause).?;
    const wp = wl.window.active.?;
    var state = ModeState{};
    _ = win.window_pane_push_mode(wp, &test_mode, @ptrCast(&state), null);

    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);
    var cl = T.Client{
        .environ = env,
        .tty = undefined,
        .status = .{},
        .flags = T.CLIENT_ATTACHED,
        .session = s,
    };
    cl.tty = .{ .client = &cl, .sx = wp.sx, .sy = wp.sy };

    var event = T.key_event{
        .key = T.KEYC_MOUSE,
        .len = 1,
        .m = .{ .x = 1, .y = 1, .b = T.MOUSE_BUTTON_1 },
    };
    try std.testing.expect(server_client_handle_key(&cl, &event));
    try std.testing.expectEqual(@as(usize, 1), state.calls);
    try std.testing.expect(state.saw_mouse);
    try std.testing.expectEqual(T.keycMouse(T.KEYC_MOUSEDOWN1, .pane), state.last_key);
}

test "server_client_handle_key encodes pane mouse events when no mode owns them" {
    const env_mod = @import("environ.zig");
    const opts_mod = @import("options.zig");
    const spawn = @import("spawn.zig");

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

    const s = sess.session_create(null, "key-mouse-pane-bytes", "/", env_mod.environ_create(), opts_mod.options_create(opts_mod.global_s_options), null);
    defer if (sess.session_find("key-mouse-pane-bytes") != null) sess.session_destroy(s, false, "test");

    var cause: ?[]u8 = null;
    var sc: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const wl = spawn.spawn_window(&sc, &cause).?;
    const wp = wl.window.active.?;
    wp.base.mode |= T.MODE_MOUSE_ALL | T.MODE_MOUSE_SGR;

    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);
    var cl = T.Client{
        .environ = env,
        .tty = undefined,
        .status = .{},
        .flags = T.CLIENT_ATTACHED,
        .session = s,
    };
    cl.tty = .{ .client = &cl, .sx = wp.sx, .sy = wp.sy };

    var event = T.key_event{
        .key = T.keycMouse(T.KEYC_MOUSEDOWN1, .pane),
        .len = 1,
        .m = .{
            .valid = true,
            .key = T.keycMouse(T.KEYC_MOUSEDOWN1, .pane),
            .wp = @intCast(wp.id),
            .x = 1,
            .y = 1,
            .b = T.MOUSE_BUTTON_1,
            .statusat = 0,
            .statuslines = 1,
            .sgr_type = 'M',
            .sgr_b = T.MOUSE_BUTTON_1,
        },
    };
    try std.testing.expect(server_client_handle_key(&cl, &event));

    var buf: [40]u8 = undefined;
    try std.testing.expectEqualStrings("\x1b[<0;2;1M", input_keys.input_key_mouse_pane(wp, &event.m, &buf));
}

test "server_link_window replaces occupied destination with -k and server_unlink_window drops one link" {
    const opts_mod = @import("options.zig");
    const env_mod = @import("environ.zig");
    const spawn = @import("spawn.zig");

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

    const src = sess.session_create(null, "src", "/", env_mod.environ_create(), opts_mod.options_create(opts_mod.global_s_options), null);
    defer if (sess.session_find("src") != null) sess.session_destroy(src, false, "test");
    const dst = sess.session_create(null, "dst", "/", env_mod.environ_create(), opts_mod.options_create(opts_mod.global_s_options), null);
    defer if (sess.session_find("dst") != null) sess.session_destroy(dst, false, "test");

    var cause: ?[]u8 = null;
    var src_ctx: T.SpawnContext = .{ .s = src, .idx = -1, .flags = T.SPAWN_EMPTY };
    const src_wl = spawn.spawn_window(&src_ctx, &cause).?;
    marked_pane_mod.set(src, src_wl, src_wl.window.active.?);
    var dst_ctx: T.SpawnContext = .{ .s = dst, .idx = -1, .flags = T.SPAWN_EMPTY };
    _ = spawn.spawn_window(&dst_ctx, &cause).?;
    dst.curw = sess.winlink_find_by_index(&dst.windows, 0).?;

    try std.testing.expectEqual(@as(i32, 0), server_link_window(src, src_wl, dst, 0, true, true, &cause));
    try std.testing.expectEqual(src_wl.window, dst.curw.?.window);
    try std.testing.expectEqual(@as(u32, 2), sess.session_window_link_count(src_wl.window));
    try std.testing.expectEqual(dst.curw.?, marked_pane_mod.marked_pane.wl.?);

    const linked = sess.winlink_find_by_window(&dst.windows, src_wl.window).?;
    server_unlink_window(dst, linked);
    try std.testing.expectEqual(@as(u32, 1), sess.session_window_link_count(src_wl.window));
    try std.testing.expect(sess.session_find("dst") == null or dst.windows.count() == 0);
}

test "server_link_window rejects linking across the same session group" {
    const opts_mod = @import("options.zig");
    const env_mod = @import("environ.zig");
    const spawn = @import("spawn.zig");

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

    const src = sess.session_create(null, "src-group-guard", "/", env_mod.environ_create(), opts_mod.options_create(opts_mod.global_s_options), null);
    defer if (sess.session_find("src-group-guard") != null) sess.session_destroy(src, false, "test");
    const dst = sess.session_create(null, "dst-group-guard", "/", env_mod.environ_create(), opts_mod.options_create(opts_mod.global_s_options), null);
    defer if (sess.session_find("dst-group-guard") != null) sess.session_destroy(dst, false, "test");

    var cause: ?[]u8 = null;
    defer if (cause) |msg| xm.allocator.free(msg);

    var src_ctx: T.SpawnContext = .{ .s = src, .idx = -1, .flags = T.SPAWN_EMPTY };
    const src_wl = spawn.spawn_window(&src_ctx, &cause).?;
    var dst_ctx: T.SpawnContext = .{ .s = dst, .idx = -1, .flags = T.SPAWN_EMPTY };
    const dst_wl = spawn.spawn_window(&dst_ctx, &cause).?;

    const group = sess.session_group_new("group-guard");
    sess.session_group_add(group, src);
    sess.session_group_add(group, dst);

    try std.testing.expectEqual(@as(i32, -1), server_link_window(src, src_wl, dst, -1, false, true, &cause));
    try std.testing.expectEqualStrings("sessions are grouped", cause.?);
    try std.testing.expectEqual(@as(u32, 1), sess.session_window_link_count(src_wl.window));
    try std.testing.expectEqual(@as(u32, 1), sess.session_window_link_count(dst_wl.window));
    try std.testing.expect(sess.winlink_find_by_window(&dst.windows, src_wl.window) == null);
}
