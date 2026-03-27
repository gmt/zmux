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
// Ported in part from tmux/alerts.c.
// Original copyright:
//   Copyright (c) 2015 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence - same terms as above.
//
// Additional zmux port work:
//   Copyright (c) 2026 Greg Turner <gmt@be-evil.net>

//! alerts.zig - reduced window/session alert handling.
//!
//! This ports the core bell/activity/silence flag propagation from tmux.
//! The message overlay consumer is still reduced, but visual-* alerts now ride
//! the shared status-message runtime instead of stopping at audible bells.

const std = @import("std");
const T = @import("types.zig");
const c = @import("c.zig");
const xm = @import("xmalloc.zig");
const opts = @import("options.zig");
const win = @import("window.zig");
const sess = @import("session.zig");
const notify = @import("notify.zig");
const proc_mod = @import("proc.zig");
const client_registry = @import("client-registry.zig");
const server = @import("server.zig");
const status_runtime = @import("status-runtime.zig");

var alerts_fired = false;
var alerts_list: std.ArrayList(*T.Window) = .{};
var alerts_event: ?*c.libevent.event = null;

pub fn alerts_reset_all() void {
    var it = win.windows.valueIterator();
    while (it.next()) |w| alerts_reset(w.*);
}

pub fn alerts_check_session(s: *T.Session) void {
    var it = s.windows.valueIterator();
    while (it.next()) |wl| {
        _ = alerts_check_all(wl.*.window);
    }
}

pub fn alerts_clear_session(s: *T.Session) void {
    s.flags &= ~@as(u32, T.SESSION_ALERTED);
    var it = s.windows.valueIterator();
    while (it.next()) |wl| {
        wl.*.window.flags &= ~@as(u32, T.WINDOW_ALERTFLAGS);
        wl.*.flags &= ~@as(u32, T.WINLINK_ALERTFLAGS);
    }
    mark_session_redraw(s);
}

pub fn alerts_queue(w: *T.Window, flags: u32) void {
    alerts_reset(w);

    if ((w.flags & flags) != flags)
        w.flags |= flags;

    if (!alerts_enabled(w, flags))
        return;

    if (!w.alerts_queued) {
        w.alerts_queued = true;
        alerts_list.append(xm.allocator, w) catch unreachable;
        win.window_add_ref(w, "alerts_queue");
    }

    schedule_callback();
}

fn schedule_callback() void {
    if (alerts_fired) return;

    const base = proc_mod.libevent orelse {
        alerts_callback_cb(-1, 0, null);
        return;
    };

    if (alerts_event == null) {
        alerts_event = c.libevent.event_new(
            base,
            -1,
            @intCast(c.libevent.EV_TIMEOUT),
            alerts_callback_cb,
            null,
        );
    }
    if (alerts_event) |ev| {
        var tv = std.posix.timeval{ .sec = 0, .usec = 0 };
        _ = c.libevent.event_add(ev, @ptrCast(&tv));
        alerts_fired = true;
    }
}

fn alerts_enabled(w: *T.Window, flags: u32) bool {
    if ((flags & T.WINDOW_BELL) != 0 and opts.options_get_number(w.options, "monitor-bell") != 0)
        return true;
    if ((flags & T.WINDOW_ACTIVITY) != 0 and opts.options_get_number(w.options, "monitor-activity") != 0)
        return true;
    if ((flags & T.WINDOW_SILENCE) != 0 and opts.options_get_number(w.options, "monitor-silence") != 0)
        return true;
    return false;
}

fn alerts_action_applies(wl: *T.Winlink, name: []const u8) bool {
    const action: u32 = @intCast(opts.options_get_number(wl.session.options, name));
    return switch (action) {
        T.ALERT_ANY => true,
        T.ALERT_CURRENT => wl.session.curw == wl,
        T.ALERT_OTHER => wl.session.curw != wl,
        else => false,
    };
}

fn alerts_check_all(w: *T.Window) u32 {
    var flags: u32 = 0;
    flags |= alerts_check_bell(w);
    flags |= alerts_check_activity(w);
    flags |= alerts_check_silence(w);
    return flags;
}

fn alerts_check_bell(w: *T.Window) u32 {
    if ((w.flags & T.WINDOW_BELL) == 0)
        return 0;
    if (opts.options_get_number(w.options, "monitor-bell") == 0)
        return 0;

    clear_session_alerted(w);

    var sit = sess.sessions.valueIterator();
    while (sit.next()) |s| {
        var wit = s.*.windows.valueIterator();
        while (wit.next()) |wl| {
            if (wl.*.window != w)
                continue;

            if (s.*.curw != wl.* or s.*.attached == 0) {
                wl.*.flags |= T.WINLINK_BELL;
                mark_session_redraw(s.*);
            }
            if (!alerts_action_applies(wl.*, "bell-action"))
                continue;

            notify.notify_winlink("alert-bell", wl.*);

            if ((s.*.flags & T.SESSION_ALERTED) != 0)
                continue;
            s.*.flags |= T.SESSION_ALERTED;

            alerts_set_message(wl.*, "Bell", "visual-bell");
        }
    }

    return T.WINDOW_BELL;
}

fn alerts_check_activity(w: *T.Window) u32 {
    if ((w.flags & T.WINDOW_ACTIVITY) == 0)
        return 0;
    if (opts.options_get_number(w.options, "monitor-activity") == 0)
        return 0;

    clear_session_alerted(w);

    var sit = sess.sessions.valueIterator();
    while (sit.next()) |s| {
        var wit = s.*.windows.valueIterator();
        while (wit.next()) |wl| {
            if (wl.*.window != w)
                continue;
            if ((wl.*.flags & T.WINLINK_ACTIVITY) != 0)
                continue;

            if (s.*.curw != wl.* or s.*.attached == 0) {
                wl.*.flags |= T.WINLINK_ACTIVITY;
                mark_session_redraw(s.*);
            }
            if (!alerts_action_applies(wl.*, "activity-action"))
                continue;

            notify.notify_winlink("alert-activity", wl.*);

            if ((s.*.flags & T.SESSION_ALERTED) != 0)
                continue;
            s.*.flags |= T.SESSION_ALERTED;

            alerts_set_message(wl.*, "Activity", "visual-activity");
        }
    }

    return T.WINDOW_ACTIVITY;
}

fn alerts_check_silence(w: *T.Window) u32 {
    if ((w.flags & T.WINDOW_SILENCE) == 0)
        return 0;
    if (opts.options_get_number(w.options, "monitor-silence") == 0)
        return 0;

    clear_session_alerted(w);

    var sit = sess.sessions.valueIterator();
    while (sit.next()) |s| {
        var wit = s.*.windows.valueIterator();
        while (wit.next()) |wl| {
            if (wl.*.window != w)
                continue;
            if ((wl.*.flags & T.WINLINK_SILENCE) != 0)
                continue;

            if (s.*.curw != wl.* or s.*.attached == 0) {
                wl.*.flags |= T.WINLINK_SILENCE;
                mark_session_redraw(s.*);
            }
            if (!alerts_action_applies(wl.*, "silence-action"))
                continue;

            notify.notify_winlink("alert-silence", wl.*);

            if ((s.*.flags & T.SESSION_ALERTED) != 0)
                continue;
            s.*.flags |= T.SESSION_ALERTED;

            alerts_set_message(wl.*, "Silence", "visual-silence");
        }
    }

    return T.WINDOW_SILENCE;
}

fn clear_session_alerted(w: *T.Window) void {
    var sit = sess.sessions.valueIterator();
    while (sit.next()) |s| {
        var wit = s.*.windows.valueIterator();
        while (wit.next()) |wl| {
            if (wl.*.window == w)
                s.*.flags &= ~@as(u32, T.SESSION_ALERTED);
        }
    }
}

fn alerts_reset(w: *T.Window) void {
    w.flags &= ~@as(u32, T.WINDOW_SILENCE);
    if (w.alerts_timer) |ev|
        _ = c.libevent.event_del(ev);

    const timeout = opts.options_get_number(w.options, "monitor-silence");
    if (timeout == 0)
        return;

    const base = proc_mod.libevent orelse return;
    if (w.alerts_timer == null) {
        w.alerts_timer = c.libevent.event_new(
            base,
            -1,
            @intCast(c.libevent.EV_TIMEOUT),
            alerts_timer_cb,
            w,
        );
    }
    if (w.alerts_timer) |ev| {
        var tv = std.posix.timeval{ .sec = @intCast(timeout), .usec = 0 };
        _ = c.libevent.event_add(ev, @ptrCast(&tv));
    }
}

fn alerts_set_message(wl: *T.Winlink, comptime typ: []const u8, option: []const u8) void {
    const visual: u32 = @intCast(opts.options_get_number(wl.session.options, option));
    for (client_registry.clients.items) |cl| {
        if (cl.session != wl.session)
            continue;
        if ((cl.flags & T.CLIENT_CONTROL) != 0)
            continue;

        if (visual == T.VISUAL_OFF or visual == T.VISUAL_BOTH)
            send_bell(cl);
        if (visual == T.VISUAL_OFF)
            continue;

        if (wl.session.curw == wl)
            status_runtime.status_message_set(cl, -1, true, false, false, "{s} in current window", .{typ})
        else
            status_runtime.status_message_set(cl, -1, true, false, false, "{s} in window {d}", .{ typ, wl.idx });
    }
}

fn send_bell(cl: *T.Client) void {
    const peer = cl.peer orelse return;
    var payload: [@sizeOf(i32) + 1]u8 = undefined;
    const stream: i32 = 1;
    @memcpy(payload[0..@sizeOf(i32)], std.mem.asBytes(&stream));
    payload[@sizeOf(i32)] = 0x07;
    _ = proc_mod.proc_send(peer, .write, -1, payload[0..].ptr, payload.len);
}

fn mark_session_redraw(s: *T.Session) void {
    server.server_status_session(s);
}

export fn alerts_timer_cb(_fd: c_int, _events: c_short, arg: ?*anyopaque) void {
    _ = _fd;
    _ = _events;
    const w: *T.Window = @ptrCast(@alignCast(arg orelse return));
    alerts_queue(w, T.WINDOW_SILENCE);
}

export fn alerts_callback_cb(_fd: c_int, _events: c_short, _arg: ?*anyopaque) void {
    _ = _fd;
    _ = _events;
    _ = _arg;

    while (alerts_list.items.len > 0) {
        const w = alerts_list.orderedRemove(0);
        _ = alerts_check_all(w);
        w.alerts_queued = false;
        w.flags &= ~@as(u32, T.WINDOW_ALERTFLAGS);
        win.window_remove_ref(w, "alerts_callback");
    }

    if (alerts_event) |ev| {
        _ = c.libevent.event_del(ev);
        c.libevent.event_free(ev);
        alerts_event = null;
    }
    alerts_fired = false;
}

test "alerts_queue marks activity on unattached current window" {
    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);

    sess.session_init_globals(xm.allocator);
    win.window_init_globals(xm.allocator);

    const env_mod = @import("environ.zig");
    env_mod.global_environ = env_mod.environ_create();
    defer env_mod.environ_free(env_mod.global_environ);

    const s = sess.session_create(null, "alerts-activity", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer sess.session_destroy(s, false, "test");

    const w = win.window_create(80, 24, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    var cause: ?[]u8 = null;
    const wl = sess.session_attach(s, w, -1, &cause).?;
    s.curw = wl;
    opts.options_set_number(w.options, "monitor-activity", 1);

    alerts_queue(w, T.WINDOW_ACTIVITY);

    try std.testing.expect((wl.flags & T.WINLINK_ACTIVITY) != 0);
    try std.testing.expect((s.flags & T.SESSION_ALERTED) != 0);
}

test "alerts_reset_all re-arms silence timer and timer callback sets silence" {
    const os_mod = @import("os/linux.zig");
    const old_base = proc_mod.libevent;
    proc_mod.libevent = os_mod.osdep_event_init();
    defer {
        if (proc_mod.libevent) |base| c.libevent.event_base_free(base);
        proc_mod.libevent = old_base;
    }

    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);

    sess.session_init_globals(xm.allocator);
    win.window_init_globals(xm.allocator);

    const env_mod = @import("environ.zig");
    env_mod.global_environ = env_mod.environ_create();
    defer env_mod.environ_free(env_mod.global_environ);

    const s = sess.session_create(null, "alerts-silence", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer sess.session_destroy(s, false, "test");

    const w = win.window_create(80, 24, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    var cause: ?[]u8 = null;
    const wl = sess.session_attach(s, w, -1, &cause).?;
    s.curw = wl;
    opts.options_set_number(w.options, "monitor-silence", 1);

    alerts_reset_all();
    try std.testing.expect(w.alerts_timer != null);

    alerts_timer_cb(-1, 0, w);
    _ = c.libevent.event_loop(c.libevent.EVLOOP_ONCE);

    try std.testing.expect((wl.flags & T.WINLINK_SILENCE) != 0);
}

test "alerts_clear_session clears window and winlink alert flags" {
    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);

    sess.session_init_globals(xm.allocator);
    win.window_init_globals(xm.allocator);

    const env_mod = @import("environ.zig");
    env_mod.global_environ = env_mod.environ_create();
    defer env_mod.environ_free(env_mod.global_environ);

    const s = sess.session_create(null, "alerts-clear", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer sess.session_destroy(s, false, "test");

    const w = win.window_create(80, 24, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    var cause: ?[]u8 = null;
    const wl = sess.session_attach(s, w, -1, &cause).?;

    w.flags = T.WINDOW_ALERTFLAGS;
    wl.flags = T.WINLINK_ALERTFLAGS;
    s.flags = T.SESSION_ALERTED;

    alerts_clear_session(s);

    try std.testing.expectEqual(@as(u32, 0), w.flags & T.WINDOW_ALERTFLAGS);
    try std.testing.expectEqual(@as(u32, 0), wl.flags & T.WINLINK_ALERTFLAGS);
    try std.testing.expectEqual(@as(u32, 0), s.flags & T.SESSION_ALERTED);
}

test "alerts queue keeps winlink alert fallout on shared status redraw" {
    client_registry.clients.clearRetainingCapacity();
    defer client_registry.clients.clearRetainingCapacity();

    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);

    sess.session_init_globals(xm.allocator);
    win.window_init_globals(xm.allocator);

    const env_mod = @import("environ.zig");
    env_mod.global_environ = env_mod.environ_create();
    defer env_mod.environ_free(env_mod.global_environ);

    const s = sess.session_create(null, "alerts-status-redraw", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer sess.session_destroy(s, false, "test");

    const current_window = win.window_create(80, 24, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    const alert_window = win.window_create(80, 24, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    var cause: ?[]u8 = null;
    const current = sess.session_attach(s, current_window, -1, &cause).?;
    const alerted = sess.session_attach(s, alert_window, -1, &cause).?;
    s.curw = current;
    s.attached = 1;
    opts.options_set_number(alert_window.options, "monitor-activity", 1);

    var env = T.Environ.init(xm.allocator);
    defer env.deinit();
    var client = T.Client{
        .name = "alerts-client",
        .environ = &env,
        .tty = undefined,
        .status = .{ .screen = undefined },
        .session = s,
        .flags = T.CLIENT_ATTACHED,
    };
    try client_registry.clients.append(xm.allocator, &client);

    alerts_queue(alert_window, T.WINDOW_ACTIVITY);

    try std.testing.expect(alerted.flags & T.WINLINK_ACTIVITY != 0);
    try std.testing.expect(client.flags & T.CLIENT_REDRAWSTATUS != 0);
    try std.testing.expect(client.flags & T.CLIENT_REDRAWWINDOW == 0);
}
