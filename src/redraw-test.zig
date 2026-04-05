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

const std = @import("std");
const T = @import("types.zig");
const env_mod = @import("environ.zig");
const opts = @import("options.zig");
const pane_io = @import("pane-io.zig");
const redraw = @import("screen-redraw.zig");
const sess = @import("session.zig");
const status = @import("status.zig");
const tty = @import("tty.zig");
const tty_draw = @import("tty-draw.zig");
const win = @import("window.zig");
const xm = @import("xmalloc.zig");

fn initRuntimeGlobals() void {
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
    env_mod.environ_free(env_mod.global_environ);
    opts.options_free(opts.global_w_options);
    opts.options_free(opts.global_s_options);
    opts.options_free(opts.global_options);
}

fn destroyWindow(w: *T.Window) void {
    while (w.panes.items.len > 0) {
        const pane = w.panes.items[w.panes.items.len - 1];
        win.window_remove_pane(w, pane);
    }
    w.panes.deinit(xm.allocator);
    w.last_panes.deinit(xm.allocator);
    opts.options_free(w.options);
    xm.allocator.free(w.name);
    _ = win.windows.remove(w.id);
    xm.allocator.destroy(w);
}

test "redraw_status_render_updates_visible_text_after_format_change" {
    initRuntimeGlobals();
    defer deinitRuntimeGlobals();

    const session_opts = opts.options_create(opts.global_s_options);
    opts.options_set_number(session_opts, "status", 1);
    opts.options_set_array(session_opts, "status-format", &.{"left #{session_name}"});
    const session_env = env_mod.environ_create();
    const s = sess.session_create(null, "status-redraw", "/", session_env, session_opts, null);
    defer sess.session_destroy(s, false, "test");

    const w = win.window_create(20, 3, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    defer destroyWindow(w);
    var cause: ?[]u8 = null;
    const wl = sess.session_attach(s, w, 0, &cause).?;
    s.curw = wl;
    const wp = win.window_add_pane(w, null, 20, 3);
    w.active = wp;

    var client = T.Client{
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{},
        .session = s,
    };
    defer {
        status.status_free(&client);
        env_mod.environ_free(client.environ);
    }
    client.tty = .{ .client = &client, .sx = 20, .sy = 4 };

    const first = status.render(&client);
    defer if (first.payload.len != 0) xm.allocator.free(first.payload);
    try std.testing.expect(std.mem.indexOf(u8, first.payload, "left status-redraw") != null);

    opts.options_set_array(s.options, "status-format", &.{"right #{session_name}"});
    const second = status.render(&client);
    defer if (second.payload.len != 0) xm.allocator.free(second.payload);
    try std.testing.expect(std.mem.indexOf(u8, second.payload, "right status-redraw") != null);
    try std.testing.expect(std.mem.indexOf(u8, second.payload, "left status-redraw") == null);
}

test "redraw_tty_draw_render_borders_outputs_numeric_border_payload" {
    initRuntimeGlobals();
    defer deinitRuntimeGlobals();

    const w = win.window_create(7, 3, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    defer destroyWindow(w);

    const left = win.window_add_pane(w, null, 3, 3);
    const right = win.window_add_pane(w, null, 3, 3);
    w.active = left;

    left.xoff = 0;
    left.yoff = 0;
    right.xoff = 4;
    right.yoff = 0;

    opts.options_set_number(w.options, "pane-border-lines", 4);

    const payload = try tty_draw.tty_draw_render_borders(null, w, 7, 3, 0);
    defer xm.allocator.free(payload);

    try std.testing.expect(payload.len != 0);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\x1b[1;4H") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "0") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "1") != null);
}

test "redraw_tty_send_requests_marks_non_vt100_terminals_satisfied_without_waiting" {
    var client = T.Client{
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{},
    };
    defer env_mod.environ_free(client.environ);
    tty.tty_init(&client.tty, &client);
    tty.tty_start_tty(&client.tty);

    tty.tty_send_requests(&client.tty);

    try std.testing.expect((client.tty.flags & @as(i32, @intCast(T.TTY_WAITFG | T.TTY_WAITBG))) == 0);
    try std.testing.expect((client.tty.flags & @as(i32, @intCast(T.TTY_ALL_REQUEST_FLAGS))) == @as(i32, @intCast(T.TTY_ALL_REQUEST_FLAGS)));
}

test "redraw_tty_send_requests_marks_vt100_like_terminals_waiting_for_colour_replies" {
    var caps = [_][]u8{
        @constCast("clear=\x1b[H\x1b[J"),
    };
    var client = T.Client{
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{},
        .term_caps = caps[0..],
    };
    defer env_mod.environ_free(client.environ);
    tty.tty_init(&client.tty, &client);
    tty.tty_start_tty(&client.tty);

    tty.tty_send_requests(&client.tty);

    try std.testing.expect((client.tty.flags & @as(i32, @intCast(T.TTY_WAITFG | T.TTY_WAITBG))) == @as(i32, @intCast(T.TTY_WAITFG | T.TTY_WAITBG)));
    try std.testing.expect((client.tty.flags & @as(i32, @intCast(T.TTY_ALL_REQUEST_FLAGS))) == 0);
    try std.testing.expect(client.tty.last_requests != 0);
}

test "redraw_screen_redraw_screen_clears_sync_state_after_full_redraw" {
    initRuntimeGlobals();
    defer deinitRuntimeGlobals();

    var caps = [_][]u8{
        @constCast("Sync=SYNC%p1%d"),
    };
    const s = sess.session_create(null, "screen-sync", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer sess.session_destroy(s, false, "test");

    const w = win.window_create(4, 2, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    defer destroyWindow(w);
    var cause: ?[]u8 = null;
    const wl = sess.session_attach(s, w, 0, &cause).?;
    s.curw = wl;

    const wp = win.window_add_pane(w, null, 4, 2);
    w.active = wp;
    pane_io.pane_io_feed(wp, "ab");

    var client = T.Client{
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{},
        .session = s,
        .term_caps = caps[0..],
        .flags = T.CLIENT_ATTACHED | T.CLIENT_UTF8 | T.CLIENT_STATUSOFF | T.CLIENT_REDRAWWINDOW,
    };
    defer env_mod.environ_free(client.environ);
    tty.tty_init(&client.tty, &client);
    client.tty.sx = 4;
    client.tty.sy = 2;
    tty.tty_start_tty(&client.tty);

    redraw.screen_redraw_screen(&client);

    try std.testing.expect((client.tty.flags & @as(i32, @intCast(T.TTY_SYNCING))) == 0);
}
