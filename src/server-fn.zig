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
const opts = @import("options.zig");
const key_bindings = @import("key-bindings.zig");
const key_string = @import("key-string.zig");
const server_client_mod = @import("server-client.zig");

pub fn server_redraw_session(s: *T.Session) void {
    srv.server_redraw_session(s);
}

pub fn server_redraw_session_group(s: *T.Session) void {
    srv.server_redraw_session(s);
}

pub fn server_status_session(s: *T.Session) void {
    srv.server_redraw_session(s);
}

pub fn server_status_window(w: *T.Window) void {
    srv.server_redraw_window(w);
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
    const s = cl.session orelse return;
    const wl = s.curw orelse return;
    const wp = wl.window.active orelse return;

    const current_table = if (cl.key_table_name) |name| name else blk: {
        const configured = opts.options_get_string(s.options, "key-table");
        break :blk if (configured.len != 0) configured else "root";
    };

    if (std.mem.eql(u8, current_table, "root") and is_prefix_key(s, event.key)) {
        server_client_mod.server_client_set_key_table(cl, "prefix");
        return;
    }

    if (key_bindings.key_bindings_get_table(current_table, false)) |table| {
        if (key_bindings.key_bindings_get(table, event.key)) |binding| {
            _ = key_bindings.key_bindings_dispatch(binding, null, cl, event, null);
            if (!std.mem.eql(u8, current_table, "root"))
                server_client_mod.server_client_set_key_table(cl, null);
            return;
        }
    }

    if (!std.mem.eql(u8, current_table, "root")) {
        server_client_mod.server_client_set_key_table(cl, null);
        return;
    }

    if (wp.fd < 0 or event.len == 0) return;
    write_pane_bytes(wp.fd, event.data[0..event.len]);
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

test "server_destroy_pane removes non-last pane and reassigns active pane" {
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

    server_destroy_pane(second, false);

    try std.testing.expectEqual(@as(usize, 1), w.panes.items.len);
    try std.testing.expectEqual(first, w.active.?);
    try std.testing.expectEqual(first, w.panes.items[0]);
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
        .status = .{ .screen = undefined },
        .flags = T.CLIENT_ATTACHED,
        .session = s,
    };
    cl.tty.client = &cl;

    var prefix_event = T.key_event{ .key = @as(T.key_code, 'b') | T.KEYC_CTRL, .data = std.mem.zeroes([16]u8), .len = 1 };
    prefix_event.data[0] = 0x02;
    server_client_handle_key(&cl, &prefix_event);
    try std.testing.expectEqualStrings("prefix", cl.key_table_name.?);

    var create_event = T.key_event{ .key = 'c', .data = std.mem.zeroes([16]u8), .len = 1 };
    create_event.data[0] = 'c';
    server_client_handle_key(&cl, &create_event);
    try std.testing.expect(cl.key_table_name == null);
    _ = cmdq.cmdq_next(&cl);
    try std.testing.expectEqual(@as(usize, 2), s.windows.count());
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
        .status = .{ .screen = undefined },
        .flags = T.CLIENT_ATTACHED,
        .session = s,
    };
    cl.tty.client = &cl;

    var event = T.key_event{ .key = 'x', .data = std.mem.zeroes([16]u8), .len = 1 };
    event.data[0] = 'x';
    server_client_handle_key(&cl, &event);

    var buf: [8]u8 = undefined;
    const n = try std.posix.read(pipe_fds[0], &buf);
    try std.testing.expectEqualStrings("x", buf[0..n]);
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
