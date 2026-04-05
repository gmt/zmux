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

//! pane-runtime-test.zig – focused pane runtime coverage on shared state.

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const alerts = @import("alerts.zig");
const client_registry = @import("client-registry.zig");
const env_mod = @import("environ.zig");
const opts = @import("options.zig");
const pane_io = @import("pane-io.zig");
const resize_mod = @import("resize.zig");
const sess = @import("session.zig");
const spawn = @import("spawn.zig");
const win = @import("window.zig");

fn initRuntimeGlobals() void {
    client_registry.clients.clearRetainingCapacity();
    opts.global_options = opts.options_create(null);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.global_s_options = opts.options_create(null);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_set_string(opts.global_s_options, false, "default-shell", "/bin/true");
    opts.global_w_options = opts.options_create(null);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    env_mod.global_environ = env_mod.environ_create();
    sess.session_init_globals(xm.allocator);
    win.window_init_globals(xm.allocator);
}

fn deinitRuntimeGlobals() void {
    client_registry.clients.clearRetainingCapacity();
    env_mod.environ_free(env_mod.global_environ);
    opts.options_free(opts.global_options);
    opts.options_free(opts.global_s_options);
    opts.options_free(opts.global_w_options);
}

fn destroySessionIfLive(name: []const u8, s: *T.Session) void {
    if (sess.session_find(name) != null) sess.session_destroy(s, false, "test");
}

fn makeSession(name: []const u8) *T.Session {
    return sess.session_create(null, name, "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
}

fn addWindowWithPane(s: *T.Session, idx: i32, sx: u32, sy: u32) *T.Winlink {
    const w = win.window_create(sx, sy, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    var cause: ?[]u8 = null;
    const wl = sess.session_attach(s, w, idx, &cause) orelse unreachable;
    const wp = win.window_add_pane(w, null, sx, sy);
    w.active = wp;
    return wl;
}

fn groupedSessionsWithAlertWindow() struct {
    source: *T.Session,
    peer: *T.Session,
    current: *T.Winlink,
    alert: *T.Winlink,
    peer_current: *T.Winlink,
    peer_alert: *T.Winlink,
    pane: *T.WindowPane,
} {
    const source = makeSession("pane-runtime-source");
    errdefer destroySessionIfLive("pane-runtime-source", source);
    const peer = makeSession("pane-runtime-peer");
    errdefer destroySessionIfLive("pane-runtime-peer", peer);

    const current = addWindowWithPane(source, 0, 80, 24);
    const alert = addWindowWithPane(source, 1, 80, 24);
    source.curw = current;
    source.attached = 1;
    peer.attached = 1;

    const group = sess.session_group_new("pane-runtime-group");
    sess.session_group_add(group, source);
    sess.session_group_add(group, peer);
    sess.session_group_synchronize_from(source);

    const peer_current = sess.winlink_find_by_window(&peer.windows, current.window) orelse unreachable;
    const peer_alert = sess.winlink_find_by_window(&peer.windows, alert.window) orelse unreachable;
    return .{
        .source = source,
        .peer = peer,
        .current = current,
        .alert = alert,
        .peer_current = peer_current,
        .peer_alert = peer_alert,
        .pane = alert.window.active.?,
    };
}

test "pane_runtime pane io activity propagates to grouped winlinks" {
    initRuntimeGlobals();
    defer deinitRuntimeGlobals();

    const fixture = groupedSessionsWithAlertWindow();
    defer destroySessionIfLive("pane-runtime-peer", fixture.peer);
    defer destroySessionIfLive("pane-runtime-source", fixture.source);

    opts.options_set_number(fixture.alert.window.options, "monitor-activity", 1);

    pane_io.pane_io_display(fixture.pane, "runtime-alert");

    try std.testing.expect(fixture.source.curw == fixture.current);
    try std.testing.expect(fixture.peer.curw == fixture.peer_current);
    try std.testing.expect((fixture.alert.flags & T.WINLINK_ACTIVITY) != 0);
    try std.testing.expect((fixture.peer_alert.flags & T.WINLINK_ACTIVITY) != 0);
    try std.testing.expect((fixture.source.flags & T.SESSION_ALERTED) != 0);
    try std.testing.expect((fixture.peer.flags & T.SESSION_ALERTED) != 0);
}

test "pane_runtime bell alerts fan out across grouped sessions" {
    initRuntimeGlobals();
    defer deinitRuntimeGlobals();

    const fixture = groupedSessionsWithAlertWindow();
    defer destroySessionIfLive("pane-runtime-peer", fixture.peer);
    defer destroySessionIfLive("pane-runtime-source", fixture.source);

    opts.options_set_number(fixture.alert.window.options, "monitor-bell", 1);

    alerts.alerts_queue(fixture.alert.window, T.WINDOW_BELL);

    try std.testing.expect((fixture.alert.flags & T.WINLINK_BELL) != 0);
    try std.testing.expect((fixture.peer_alert.flags & T.WINLINK_BELL) != 0);
    try std.testing.expect((fixture.source.flags & T.SESSION_ALERTED) != 0);
    try std.testing.expect((fixture.peer.flags & T.SESSION_ALERTED) != 0);
}

test "pane_runtime grouped spawn keeps new window linked without changing peer current" {
    initRuntimeGlobals();
    defer deinitRuntimeGlobals();

    const source = makeSession("pane-runtime-spawn-source");
    defer destroySessionIfLive("pane-runtime-spawn-source", source);
    const peer = makeSession("pane-runtime-spawn-peer");
    defer destroySessionIfLive("pane-runtime-spawn-peer", peer);

    const initial = addWindowWithPane(source, 0, 80, 24);
    source.curw = initial;
    peer.attached = 1;
    source.attached = 1;

    const group = sess.session_group_new("pane-runtime-spawn-group");
    sess.session_group_add(group, source);
    sess.session_group_add(group, peer);
    sess.session_group_synchronize_from(source);

    const peer_initial = sess.winlink_find_by_window(&peer.windows, initial.window) orelse unreachable;
    try std.testing.expect(peer.curw == peer_initial);

    var cause: ?[]u8 = null;
    var sc = T.SpawnContext{ .s = source, .idx = 3, .flags = T.SPAWN_EMPTY };
    const spawned = spawn.spawn_window(&sc, &cause) orelse unreachable;

    const peer_spawned = sess.winlink_find_by_window(&peer.windows, spawned.window) orelse unreachable;
    try std.testing.expectEqual(@as(i32, 3), spawned.idx);
    try std.testing.expectEqual(@as(i32, 3), peer_spawned.idx);
    try std.testing.expectEqual(@as(usize, 2), source.windows.count());
    try std.testing.expectEqual(@as(usize, 2), peer.windows.count());
    try std.testing.expect(peer.curw == peer_initial);
    try std.testing.expect(peer_spawned.window == spawned.window);
}

test "pane_runtime resize_window updates shared pane state and queues delivery" {
    initRuntimeGlobals();
    defer deinitRuntimeGlobals();

    const source = makeSession("pane-runtime-resize-source");
    defer destroySessionIfLive("pane-runtime-resize-source", source);
    const peer = makeSession("pane-runtime-resize-peer");
    defer destroySessionIfLive("pane-runtime-resize-peer", peer);

    const wl = addWindowWithPane(source, 0, 80, 24);
    source.curw = wl;

    const group = sess.session_group_new("pane-runtime-resize-group");
    sess.session_group_add(group, source);
    sess.session_group_add(group, peer);
    sess.session_group_synchronize_from(source);

    const peer_wl = sess.winlink_find_by_window(&peer.windows, wl.window) orelse unreachable;
    const wp = wl.window.active.?;
    wl.window.flags |= T.WINDOW_RESIZE;

    resize_mod.resize_window(wl.window, 95, 17, 11, 22);

    try std.testing.expect(peer_wl.window == wl.window);
    try std.testing.expectEqual(@as(u32, 95), wl.window.sx);
    try std.testing.expectEqual(@as(u32, 17), wl.window.sy);
    try std.testing.expectEqual(@as(u32, 95), wp.sx);
    try std.testing.expectEqual(@as(u32, 17), wp.sy);
    try std.testing.expectEqual(@as(usize, 1), wp.resize_queue.items.len);
    try std.testing.expectEqual(@as(u32, 80), wp.resize_queue.items[0].osx);
    try std.testing.expectEqual(@as(u32, 24), wp.resize_queue.items[0].osy);
    try std.testing.expectEqual(@as(u32, 95), wp.resize_queue.items[0].sx);
    try std.testing.expectEqual(@as(u32, 17), wp.resize_queue.items[0].sy);
    try std.testing.expectEqual(@as(u32, 0), wl.window.flags & T.WINDOW_RESIZE);
}
