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

pub fn server_redraw_session(s: *T.Session) void {
    _ = s;
    // TODO: mark all clients attached to this session for redraw
}

pub fn server_redraw_session_group(s: *T.Session) void {
    _ = s;
}

pub fn server_status_session(s: *T.Session) void {
    _ = s;
}

pub fn server_status_window(w: *T.Window) void {
    _ = w;
}

pub fn server_lock_session(s: *T.Session) void {
    _ = s;
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
            if (wl.window == w) indices.append(xm.allocator, wl.idx) catch unreachable;
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

pub fn server_link_window(
    src: *T.Session,
    srcwl: *T.Winlink,
    dst: *T.Session,
    dst_idx: i32,
    kill_existing: bool,
    select_dst: bool,
    cause: *?[]u8,
) i32 {
    _ = src;

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
    if (actual_select) dst.curw = new_wl;
    server_redraw_session_group(dst);
    return 0;
}

pub fn server_unlink_window(s: *T.Session, wl: *T.Winlink) void {
    _ = sess.session_detach_index(s, wl.idx, "server_unlink_window");
    if (s.windows.count() == 0) {
        srv.server_destroy_session(s);
        sess.session_destroy(s, true, "server_unlink_window");
    } else {
        if (s.curw == null) s.curw = sess.session_first_winlink(s);
        server_redraw_session_group(s);
    }
}

pub fn server_destroy_pane(wp: *T.WindowPane, notify: bool) void {
    _ = notify;
    const w = wp.window;
    if (w.panes.items.len <= 1) {
        server_kill_window(w, true);
        return;
    }

    const was_active = w.active == wp;
    win.window_remove_pane(w, wp);
    if (was_active) {
        w.active = if (w.panes.items.len > 0) w.panes.items[0] else null;
    }

    srv.server_redraw_window(w);
    server_status_window(w);
}

pub fn server_client_handle_key(cl: *T.Client, event: *T.key_event) void {
    _ = cl;
    _ = event;
}

// Placeholder for format_tree.zig integration
pub fn server_format_session(
    _ft: ?*anyopaque,
    _s: *T.Session,
) void {
    _ = _ft;
    _ = _s;
}

test "server_destroy_pane removes non-last pane and reassigns active pane" {
    const opts = @import("options.zig");

    win.window_init_globals(xm.allocator);
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);

    const w = win.window_create(80, 24, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    defer win.window_remove_ref(w, "test");

    const first = win.window_add_pane(w, null, 80, 24);
    const second = win.window_add_pane(w, null, 80, 24);
    w.active = second;
    w.references = 1;

    server_destroy_pane(second, false);

    try std.testing.expectEqual(@as(usize, 1), w.panes.items.len);
    try std.testing.expectEqual(first, w.active.?);
    try std.testing.expectEqual(first, w.panes.items[0]);
}

test "server_link_window replaces occupied destination with -k and server_unlink_window drops one link" {
    const opts = @import("options.zig");
    const env_mod = @import("environ.zig");
    const spawn = @import("spawn.zig");

    sess.session_init_globals(xm.allocator);
    win.window_init_globals(xm.allocator);

    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);

    env_mod.global_environ = env_mod.environ_create();
    defer env_mod.environ_free(env_mod.global_environ);

    const src = sess.session_create(null, "src", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("src") != null) sess.session_destroy(src, false, "test");
    const dst = sess.session_create(null, "dst", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("dst") != null) sess.session_destroy(dst, false, "test");

    var cause: ?[]u8 = null;
    var src_ctx: T.SpawnContext = .{ .s = src, .idx = -1, .flags = T.SPAWN_EMPTY };
    const src_wl = spawn.spawn_window(&src_ctx, &cause).?;
    var dst_ctx: T.SpawnContext = .{ .s = dst, .idx = -1, .flags = T.SPAWN_EMPTY };
    _ = spawn.spawn_window(&dst_ctx, &cause).?;
    dst.curw = sess.winlink_find_by_index(&dst.windows, 0).?;

    try std.testing.expectEqual(@as(i32, 0), server_link_window(src, src_wl, dst, 0, true, true, &cause));
    try std.testing.expectEqual(src_wl.window, dst.curw.?.window);
    try std.testing.expectEqual(@as(u32, 2), sess.session_window_link_count(src_wl.window));

    const linked = sess.winlink_find_by_window(&dst.windows, src_wl.window).?;
    server_unlink_window(dst, linked);
    try std.testing.expectEqual(@as(u32, 1), sess.session_window_link_count(src_wl.window));
    try std.testing.expect(sess.session_find("dst") == null or dst.windows.count() == 0);
}
