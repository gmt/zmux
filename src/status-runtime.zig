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
// Ported in part from tmux/status.c.
// Original copyright:
//   Copyright (c) 2008 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

//! status-runtime.zig – shared prompt/message overlay lifetime and timers.

const std = @import("std");
const T = @import("types.zig");
const c = @import("c.zig");
const opts = @import("options.zig");
const proc_mod = @import("proc.zig");
const xm = @import("xmalloc.zig");

pub fn status_push_screen(client: *T.Client) void {
    client.status.references += 1;
}

pub fn status_pop_screen(client: *T.Client) void {
    if (client.status.references == 0) return;
    client.status.references -= 1;
}

pub fn status_message_active(client: *const T.Client) bool {
    return client.message_string != null;
}

pub fn status_message_ignore_keys(client: *const T.Client) bool {
    return client.message_ignore_keys;
}

pub fn status_message_ignore_styles(client: *const T.Client) bool {
    return client.message_ignore_styles;
}

pub fn status_message_set(
    client: *T.Client,
    delay: i32,
    ignore_styles: bool,
    ignore_keys: bool,
    no_freeze: bool,
    comptime fmt: []const u8,
    args: anytype,
) void {
    const message = xm.xasprintf(fmt, args);
    status_message_set_owned(client, delay, ignore_styles, ignore_keys, no_freeze, message);
}

pub fn status_message_set_text(
    client: *T.Client,
    delay: i32,
    ignore_styles: bool,
    ignore_keys: bool,
    no_freeze: bool,
    text: []const u8,
) void {
    status_message_set_owned(client, delay, ignore_styles, ignore_keys, no_freeze, xm.xstrdup(text));
}

fn status_message_set_owned(
    client: *T.Client,
    delay: i32,
    ignore_styles: bool,
    ignore_keys: bool,
    no_freeze: bool,
    message: []u8,
) void {
    status_message_clear(client);
    status_push_screen(client);
    client.message_string = message;

    var actual_delay = delay;
    if (actual_delay == -1) {
        if (client.session) |session|
            actual_delay = @intCast(opts.options_get_number(session.options, "display-time"))
        else
            actual_delay = @intCast(opts.options_get_number(opts.global_s_options, "display-time"));
    }
    if (actual_delay > 0) arm_message_timer(client, actual_delay);

    client.message_ignore_keys = actual_delay != 0 and ignore_keys;
    client.message_ignore_styles = ignore_styles;

    if (!no_freeze) client.tty.flags |= @intCast(T.TTY_FREEZE);
    client.tty.flags |= @intCast(T.TTY_NOCURSOR);
    client.flags |= T.CLIENT_REDRAWSTATUS;
}

pub fn status_message_clear(client: *T.Client) void {
    if (client.message_string == null) return;

    if (client.message_timer) |ev| _ = c.libevent.event_del(ev);

    xm.allocator.free(client.message_string.?);
    client.message_string = null;
    client.message_ignore_keys = false;
    client.message_ignore_styles = false;
    client.tty.flags &= ~@as(i32, @intCast(T.TTY_NOCURSOR | T.TTY_FREEZE));
    client.flags |= T.CLIENT_REDRAW;
    status_pop_screen(client);
}

pub fn status_prompt_enter(client: *T.Client, freeze: bool) void {
    status_push_screen(client);
    if (freeze) client.tty.flags |= @intCast(T.TTY_FREEZE);
    client.tty.flags |= @intCast(T.TTY_NOCURSOR);
    client.flags |= T.CLIENT_REDRAWSTATUS;
}

pub fn status_prompt_leave(client: *T.Client) void {
    client.tty.flags &= ~@as(i32, @intCast(T.TTY_NOCURSOR | T.TTY_FREEZE));
    client.flags |= T.CLIENT_REDRAW;
    status_pop_screen(client);
}

pub fn status_cleanup(client: *T.Client) void {
    if (client.message_timer) |ev| {
        _ = c.libevent.event_del(ev);
        c.libevent.event_free(ev);
        client.message_timer = null;
    }
}

fn arm_message_timer(client: *T.Client, delay_ms: i32) void {
    if (client.message_timer == null) {
        const base = proc_mod.libevent orelse return;
        client.message_timer = c.libevent.event_new(
            base,
            -1,
            @intCast(c.libevent.EV_TIMEOUT),
            status_message_timer_cb,
            client,
        );
    }
    if (client.message_timer) |ev| {
        var tv = std.posix.timeval{
            .sec = @divTrunc(delay_ms, 1000),
            .usec = @mod(delay_ms, 1000) * 1000,
        };
        _ = c.libevent.event_add(ev, @ptrCast(&tv));
    }
}

export fn status_message_timer_cb(_fd: c_int, _events: c_short, arg: ?*anyopaque) void {
    _ = _fd;
    _ = _events;
    const client: *T.Client = @ptrCast(@alignCast(arg orelse return));
    status_message_clear(client);
}

test "status runtime arms and clears a timed message overlay" {
    const env_mod = @import("environ.zig");
    const os_mod = @import("os/linux.zig");
    const sess_mod = @import("session.zig");
    const win_mod = @import("window.zig");

    const old_base = proc_mod.libevent;
    proc_mod.libevent = os_mod.osdep_event_init();
    defer {
        if (proc_mod.libevent) |base| c.libevent.event_base_free(base);
        proc_mod.libevent = old_base;
    }

    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);

    sess_mod.session_init_globals(xm.allocator);
    win_mod.window_init_globals(xm.allocator);
    env_mod.global_environ = env_mod.environ_create();
    defer env_mod.environ_free(env_mod.global_environ);

    const session = sess_mod.session_create(
        null,
        "status-runtime-test",
        "/",
        env_mod.environ_create(),
        opts.options_create(opts.global_s_options),
        null,
    );

    const window = win_mod.window_create(80, 24, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    defer win_mod.window_remove_ref(window, "test");
    defer if (sess_mod.session_find(session.name)) |_| sess_mod.session_destroy(session, false, "test");
    var attach_cause: ?[]u8 = null;
    const wl = sess_mod.session_attach(session, window, -1, &attach_cause).?;
    _ = wl;

    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);
    var client = T.Client{
        .environ = env,
        .tty = undefined,
        .status = .{ .screen = undefined },
        .session = session,
        .flags = T.CLIENT_ATTACHED,
    };
    client.tty.client = &client;

    status_message_set_text(&client, 5, true, false, false, "timed");
    try std.testing.expectEqualStrings("timed", client.message_string.?);
    try std.testing.expectEqual(@as(u32, 1), client.status.references);
    try std.testing.expect(client.message_timer != null);

    std.Thread.sleep(20 * std.time.ns_per_ms);
    _ = c.libevent.event_loop(c.libevent.EVLOOP_ONCE);

    try std.testing.expect(client.message_string == null);
    try std.testing.expectEqual(@as(u32, 0), client.status.references);
    status_cleanup(&client);
}
