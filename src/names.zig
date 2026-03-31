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
// Ported from tmux/names.c
// Original copyright:
//   Copyright (c) 2009 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

const std = @import("std");
const T = @import("types.zig");
const c = @import("c.zig");
const xm = @import("xmalloc.zig");
const cmd_render = @import("cmd-render.zig");
const format_mod = @import("format.zig");
const log = @import("log.zig");
const opts = @import("options.zig");
const proc_mod = @import("proc.zig");
const server_fn = @import("server-fn.zig");
const win_mod = @import("window.zig");

export fn name_time_callback(_fd: c_int, _events: c_short, arg: ?*anyopaque) void {
    _ = _fd;
    _ = _events;
    const w: *T.Window = @ptrCast(@alignCast(arg orelse return));

    // The server loop will call check_window_name on the way out.
    log.log_debug("@{d} name timer expired", .{w.id});
}

fn name_time_expired(w: *T.Window, tv: *const std.posix.timeval) u64 {
    const interval_us: i128 = @intCast(T.NAME_INTERVAL);
    const elapsed_us = (@as(i128, @intCast(tv.sec)) - @as(i128, @intCast(w.name_time.sec))) * std.time.us_per_s +
        (@as(i128, @intCast(tv.usec)) - @as(i128, @intCast(w.name_time.usec)));
    if (elapsed_us < 0 or elapsed_us >= interval_us) return 0;
    return @intCast(interval_us - elapsed_us);
}

fn format_window_name(w: *T.Window) []u8 {
    const wp = w.active orelse return xm.xstrdup("");
    const fmt = opts.options_get_string(w.options, "automatic-rename-format");
    const ctx = format_mod.FormatContext{
        .window = w,
        .pane = wp,
    };
    return format_mod.format_expand(xm.allocator, fmt, &ctx).text;
}

fn queue_name_timer(w: *T.Window, left: u64) void {
    const base = proc_mod.libevent orelse return;
    if (w.name_event == null) {
        w.name_event = c.libevent.event_new(
            base,
            -1,
            @intCast(c.libevent.EV_TIMEOUT),
            name_time_callback,
            w,
        );
    }

    const ev = w.name_event orelse return;
    if (c.libevent.event_pending(ev, @as(c_short, @intCast(c.libevent.EV_TIMEOUT)), null) != 0) {
        log.log_debug("@{d} name timer already queued ({d} left)", .{ w.id, left });
        return;
    }

    var next = std.posix.timeval{
        .sec = @intCast(@divTrunc(left, std.time.us_per_s)),
        .usec = @intCast(@mod(left, std.time.us_per_s)),
    };
    if (next.sec == 0 and next.usec == 0) next.usec = 1;

    log.log_debug("@{d} name timer queued ({d} left)", .{ w.id, left });
    _ = c.libevent.event_add(ev, @ptrCast(&next));
}

fn mark_automatic_rename_window(w: *T.Window) void {
    const wp = w.active orelse return;
    if (opts.options_get_number(w.options, "automatic-rename") == 0) return;
    wp.flags |= T.PANE_CHANGED;
}

pub fn mark_automatic_rename_change(target_window: ?*T.Window, global: bool) void {
    if (global) {
        var it = win_mod.windows.valueIterator();
        while (it.next()) |window_ptr| {
            mark_automatic_rename_window(window_ptr.*);
        }
        return;
    }

    if (target_window) |w| mark_automatic_rename_window(w);
}

pub fn check_window_name(w: *T.Window) void {
    const wp = w.active orelse return;

    if (opts.options_get_number(w.options, "automatic-rename") == 0)
        return;

    if ((wp.flags & T.PANE_CHANGED) == 0) {
        log.log_debug("@{d} active pane not changed", .{w.id});
        return;
    }
    log.log_debug("@{d} active pane changed", .{w.id});

    var tv: std.posix.timeval = undefined;
    std.posix.gettimeofday(&tv, null);
    const left = name_time_expired(w, &tv);
    if (left != 0) {
        queue_name_timer(w, left);
        return;
    }

    w.name_time = tv;
    if (w.name_event) |ev| _ = c.libevent.event_del(ev);

    wp.flags &= ~@as(u32, T.PANE_CHANGED);

    const name = format_window_name(w);
    defer xm.allocator.free(name);

    if (!std.mem.eql(u8, name, w.name)) {
        log.log_debug("@{d} new name {s} (was {s})", .{ w.id, name, w.name });
        win_mod.window_set_name(w, name);
        server_fn.server_redraw_window_borders(w);
        server_fn.server_status_window(w);
    } else {
        log.log_debug("@{d} name not changed (still {s})", .{ w.id, w.name });
    }
}

pub fn default_window_name(w: *T.Window) []u8 {
    const wp = w.active orelse return xm.xstrdup("");
    if (wp.argv) |argv| {
        const cmd = cmd_render.stringify_argv(xm.allocator, argv);
        defer xm.allocator.free(cmd);
        return parse_window_name(cmd);
    }
    return parse_window_name(wp.shell orelse "");
}

pub fn parse_window_name(input: []const u8) []u8 {
    var name = input;
    if (name.len > 0 and name[0] == '"') name = name[1..];
    if (std.mem.indexOfScalar(u8, name, '"')) |idx| name = name[0..idx];

    if (std.mem.startsWith(u8, name, "exec "))
        name = name["exec ".len..];

    while (name.len > 0 and (name[0] == ' ' or name[0] == '-'))
        name = name[1..];

    if (std.mem.indexOfScalar(u8, name, ' ')) |idx|
        name = name[0..idx];

    if (name.len > 0) {
        var end = name.len;
        while (end > 1 and !is_name_char(name[end - 1]))
            end -= 1;
        name = name[0..end];
    }

    if (name.len > 0 and name[0] == '/')
        name = std.fs.path.basenamePosix(name);

    return xm.xstrdup(name);
}

fn is_name_char(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or is_ascii_punctuation(ch);
}

fn is_ascii_punctuation(ch: u8) bool {
    return (ch >= '!' and ch <= '/') or
        (ch >= ':' and ch <= '@') or
        (ch >= '[' and ch <= '`') or
        (ch >= '{' and ch <= '~');
}

test "parse_window_name strips quotes exec prefix and path" {
    const out = parse_window_name("\"exec /usr/bin/zsh -l\"");
    defer xm.allocator.free(out);
    try std.testing.expectEqualStrings("zsh", out);
}

test "parse_window_name trims leading dashes and trailing junk" {
    const out = parse_window_name("  -git!!!   ");
    defer xm.allocator.free(out);
    try std.testing.expectEqualStrings("git!!!", out);
}

test "check_window_name renames immediately and marks redraws" {
    const sess = @import("session.zig");
    const env_mod = @import("environ.zig");
    const client_registry = @import("client-registry.zig");

    client_registry.clients.clearRetainingCapacity();
    defer client_registry.clients.clearRetainingCapacity();

    sess.session_init_globals(xm.allocator);
    win_mod.window_init_globals(xm.allocator);

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

    const session = sess.session_create(null, "names-immediate", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer sess.session_destroy(session, false, "test");

    const window = win_mod.window_create(80, 24, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    var attach_cause: ?[]u8 = null;
    const wl = sess.session_attach(session, window, 0, &attach_cause).?;
    session.curw = wl;
    const pane = win_mod.window_add_pane(window, null, 80, 24);
    window.active = pane;
    pane.shell = xm.xstrdup("/bin/sh");
    pane.flags |= T.PANE_CHANGED;
    win_mod.window_set_name(window, "before");

    var client = T.Client{
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{},
        .session = session,
        .flags = T.CLIENT_ATTACHED,
    };
    defer env_mod.environ_free(client.environ);
    client_registry.add(&client);

    check_window_name(window);

    try std.testing.expectEqualStrings("sh", window.name);
    try std.testing.expectEqual(@as(u32, 0), pane.flags & T.PANE_CHANGED);
    try std.testing.expect(client.flags & T.CLIENT_REDRAWBORDERS != 0);
    try std.testing.expect(client.flags & T.CLIENT_REDRAWSTATUS != 0);
}

test "check_window_name queues a timer until the rename interval expires" {
    const sess = @import("session.zig");
    const env_mod = @import("environ.zig");
    const os_mod = @import("os/linux.zig");

    const old_base = proc_mod.libevent;
    proc_mod.libevent = os_mod.osdep_event_init();
    defer {
        if (proc_mod.libevent) |base| c.libevent.event_base_free(base);
        proc_mod.libevent = old_base;
    }

    sess.session_init_globals(xm.allocator);
    win_mod.window_init_globals(xm.allocator);

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

    const session = sess.session_create(null, "names-timer", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer sess.session_destroy(session, false, "test");

    const window = win_mod.window_create(80, 24, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    var attach_cause: ?[]u8 = null;
    _ = sess.session_attach(session, window, 0, &attach_cause).?;
    const pane = win_mod.window_add_pane(window, null, 80, 24);
    window.active = pane;
    pane.shell = xm.xstrdup("/bin/sh");
    pane.flags |= T.PANE_CHANGED;
    win_mod.window_set_name(window, "before");

    std.posix.gettimeofday(&window.name_time, null);
    window.name_time.usec -= 400_000;
    if (window.name_time.usec < 0) {
        window.name_time.sec -= 1;
        window.name_time.usec += std.time.us_per_s;
    }

    check_window_name(window);
    try std.testing.expect(window.name_event != null);
    try std.testing.expectEqualStrings("before", window.name);
    try std.testing.expect(pane.flags & T.PANE_CHANGED != 0);

    std.Thread.sleep(150 * std.time.ns_per_ms);
    _ = c.libevent.event_loop(c.libevent.EVLOOP_ONCE);
    check_window_name(window);

    try std.testing.expectEqualStrings("sh", window.name);
    try std.testing.expectEqual(@as(u32, 0), pane.flags & T.PANE_CHANGED);
}
