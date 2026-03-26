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
// Ported in part from tmux/resize.c.
// Original copyright:
//   Copyright (c) 2007 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

const std = @import("std");
const T = @import("types.zig");
const client_registry = @import("client-registry.zig");
const notify = @import("notify.zig");
const opts = @import("options.zig");
const server_fn = @import("server-fn.zig");
const sess = @import("session.zig");
const win = @import("window.zig");
const xm = @import("xmalloc.zig");

const SkipClientFn = *const fn (*T.Client, u32, bool, ?*T.Session, ?*T.Window) bool;

pub fn resize_window(w: *T.Window, sx_: u32, sy_: u32, xpixel: i32, ypixel: i32) void {
    var sx = std.math.clamp(sx_, T.WINDOW_MINIMUM, T.WINDOW_MAXIMUM);
    var sy = std.math.clamp(sy_, T.WINDOW_MINIMUM, T.WINDOW_MAXIMUM);

    if (w.layout_root) |root| {
        sx = @max(sx, root.sx);
        sy = @max(sy, root.sy);
    }

    win.window_resize(w, sx, sy, xpixel, ypixel);

    // Reduced seam: until layout.zig exists, panes follow the whole-window size.
    if (w.layout_root == null) {
        for (w.panes.items) |wp| {
            wp.sx = sx;
            wp.sy = sy;
            wp.xoff = 0;
            wp.yoff = 0;
        }
    }

    server_fn.server_status_window(w);
    notify.notify_window("window-layout-changed", w);
    notify.notify_window("window-resized", w);
    w.flags &= ~@as(u32, T.WINDOW_RESIZE);
}

pub fn default_window_size(
    c: ?*T.Client,
    s: ?*T.Session,
    w: ?*T.Window,
    sx: *u32,
    sy: *u32,
    xpixel: *u32,
    ypixel: *u32,
    type_: i32,
) void {
    const size_type: u32 = if (type_ == -1)
        @intCast(opts.options_get_number(opts.global_w_options, "window-size"))
    else
        @intCast(type_);
    var base_client = c;

    if (size_type == T.WINDOW_SIZE_LATEST and base_client != null and !ignore_client_size(base_client.?)) {
        use_client_size(base_client.?, sx, sy, xpixel, ypixel);
        clamp_size(sx, sy);
        return;
    }

    if (base_client != null and base_client.?.flags & T.CLIENT_CONTROL != 0)
        base_client = null;

    if (!clients_calculate_size(size_type, false, base_client, s, w, default_window_size_skip_client, sx, sy, xpixel, ypixel)) {
        const owner = s orelse blk: {
            if (base_client) |cl| break :blk cl.session orelse null;
            break :blk null;
        };
        parse_default_size(if (owner) |session| session.options else opts.global_s_options, sx, sy);
        xpixel.* = 0;
        ypixel.* = 0;
    }

    clamp_size(sx, sy);
}

pub fn recalculate_size(w: *T.Window, now: bool) void {
    if (w.active == null) return;

    const size_type: u32 = @intCast(opts.options_get_number(w.options, "window-size"));
    const current = opts.options_get_number(w.options, "aggressive-resize") != 0;

    var sx: u32 = 0;
    var sy: u32 = 0;
    var xpixel: u32 = 0;
    var ypixel: u32 = 0;
    var changed = clients_calculate_size(size_type, current, null, null, w, recalculate_size_skip_client, &sx, &sy, &xpixel, &ypixel);

    if (w.flags & T.WINDOW_RESIZE != 0) {
        if (!now and changed and w.new_sx == sx and w.new_sy == sy)
            changed = false;
    } else if (!now and changed and w.sx == sx and w.sy == sy) {
        changed = false;
    }

    if (!changed) return;

    // Reduced seam: tmux can defer this until server-client's resize pass;
    // zmux applies it immediately because that later pass is not ported yet.
    resize_window(w, sx, sy, @intCast(xpixel), @intCast(ypixel));
}

pub fn recalculate_sizes() void {
    recalculate_sizes_now(false);
}

pub fn recalculate_sizes_now(now: bool) void {
    var sit = sess.sessions.valueIterator();
    while (sit.next()) |s| {
        s.*.attached = 0;
        status_update_cache(s.*);
    }

    for (client_registry.clients.items) |cl| {
        if (cl.session) |s| {
            if (cl.flags & T.CLIENT_EXIT == 0)
                s.attached += 1;

            if (!ignore_client_size(cl)) {
                if (cl.tty.sy <= s.statuslines or cl.flags & T.CLIENT_CONTROL != 0)
                    cl.flags |= T.CLIENT_STATUSOFF
                else
                    cl.flags &= ~@as(u64, T.CLIENT_STATUSOFF);
            }
        }
    }

    var wit = win.windows.valueIterator();
    while (wit.next()) |w| recalculate_size(w.*, now);
}

pub fn status_update_cache(s: *T.Session) void {
    s.statuslines = @intCast(@max(opts.options_get_number(s.options, "status"), 0));
    if (s.statuslines == 0)
        s.statusat = -1
    else if (opts.options_get_number(s.options, "status-position") == 0)
        s.statusat = 0
    else
        s.statusat = 1;
}

pub fn status_line_size(c: *T.Client) u32 {
    if (c.flags & (T.CLIENT_STATUSOFF | T.CLIENT_CONTROL) != 0)
        return 0;
    if (c.session) |s|
        return s.statuslines;
    return @intCast(@max(opts.options_get_number(opts.global_s_options, "status"), 0));
}

fn ignore_client_size(c: *T.Client) bool {
    if (c.session == null) return true;
    if (c.flags & T.CLIENT_EXIT != 0) return true;

    if (c.flags & T.CLIENT_IGNORESIZE != 0) {
        for (client_registry.clients.items) |other| {
            if (other.session == null) continue;
            if (other.flags & T.CLIENT_EXIT != 0) continue;
            if (other.flags & T.CLIENT_IGNORESIZE == 0) return true;
        }
    }

    if (c.flags & T.CLIENT_CONTROL != 0 and
        c.flags & T.CLIENT_SIZECHANGED == 0 and
        c.flags & T.CLIENT_WINDOWSIZECHANGED == 0)
        return true;

    return false;
}

fn clients_with_window(w: *T.Window) u32 {
    var count: u32 = 0;
    for (client_registry.clients.items) |cl| {
        const s = cl.session orelse continue;
        if (ignore_client_size(cl) or !sess.session_has_window(s, w))
            continue;
        count += 1;
        if (count > 1) break;
    }
    return count;
}

fn clients_calculate_size(
    size_type: u32,
    current: bool,
    c: ?*T.Client,
    s: ?*T.Session,
    w: ?*T.Window,
    skip_client: SkipClientFn,
    sx: *u32,
    sy: *u32,
    xpixel: *u32,
    ypixel: *u32,
) bool {
    const max_u32 = std.math.maxInt(u32);
    if (size_type == T.WINDOW_SIZE_LARGEST) {
        sx.* = 0;
        sy.* = 0;
    } else if (w != null and size_type == T.WINDOW_SIZE_MANUAL) {
        sx.* = w.?.manual_sx;
        sy.* = w.?.manual_sy;
    } else {
        sx.* = max_u32;
        sy.* = max_u32;
    }
    xpixel.* = 0;
    ypixel.* = 0;

    var window_client_count: u32 = 0;
    if (size_type == T.WINDOW_SIZE_LATEST and w != null)
        window_client_count = clients_with_window(w.?);

    if (size_type == T.WINDOW_SIZE_MANUAL)
        return w != null;

    for (client_registry.clients.items) |loop| {
        if (loop != c and ignore_client_size(loop))
            continue;
        if (loop != c and skip_client(loop, size_type, current, s, w))
            continue;

        if (size_type == T.WINDOW_SIZE_LATEST and window_client_count > 1) {
            const latest = latest_client(w.?);
            if (latest == null or latest.? != loop)
                continue;
        }

        const cx = loop.tty.sx;
        const cy = line_clamped_height(loop);

        if (size_type == T.WINDOW_SIZE_LARGEST) {
            sx.* = @max(sx.*, cx);
            sy.* = @max(sy.*, cy);
        } else {
            sx.* = @min(sx.*, cx);
            sy.* = @min(sy.*, cy);
        }

        if (loop.tty.xpixel > xpixel.* and loop.tty.ypixel > ypixel.*) {
            xpixel.* = loop.tty.xpixel;
            ypixel.* = loop.tty.ypixel;
        }
    }

    if (size_type == T.WINDOW_SIZE_LARGEST)
        return sx.* != 0 and sy.* != 0;
    return sx.* != max_u32 and sy.* != max_u32;
}

fn default_window_size_skip_client(loop: *T.Client, _: u32, _: bool, s: ?*T.Session, w: ?*T.Window) bool {
    if (w != null) {
        const loop_session = loop.session orelse return true;
        return !sess.session_has_window(loop_session, w.?);
    }
    return loop.session != s;
}

fn recalculate_size_skip_client(loop: *T.Client, _: u32, current: bool, _: ?*T.Session, w: ?*T.Window) bool {
    const s = loop.session orelse return true;
    const curw = s.curw orelse return true;
    if (current)
        return curw.window != w.?;
    return !sess.session_has_window(s, w.?);
}

fn parse_default_size(oo: *T.Options, sx: *u32, sy: *u32) void {
    const value = opts.options_get_string(oo, "default-size");
    var it = std.mem.splitScalar(u8, value, 'x');
    sx.* = if (it.next()) |width| std.fmt.parseInt(u32, width, 10) catch 80 else 80;
    sy.* = if (it.next()) |height| std.fmt.parseInt(u32, height, 10) catch 24 else 24;
}

fn clamp_size(sx: *u32, sy: *u32) void {
    sx.* = std.math.clamp(sx.*, T.WINDOW_MINIMUM, T.WINDOW_MAXIMUM);
    sy.* = std.math.clamp(sy.*, T.WINDOW_MINIMUM, T.WINDOW_MAXIMUM);
}

fn use_client_size(c: *T.Client, sx: *u32, sy: *u32, xpixel: *u32, ypixel: *u32) void {
    sx.* = c.tty.sx;
    sy.* = line_clamped_height(c);
    xpixel.* = c.tty.xpixel;
    ypixel.* = c.tty.ypixel;
}

fn line_clamped_height(c: *T.Client) u32 {
    const lines = status_line_size(c);
    return if (c.tty.sy > lines) c.tty.sy - lines else 1;
}

fn latest_client(w: *T.Window) ?*T.Client {
    const raw = w.latest orelse return null;
    return @ptrCast(@alignCast(raw));
}

test "default_window_size uses the latest eligible client" {
    const env_mod = @import("environ.zig");

    client_registry.clients.clearRetainingCapacity();
    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);

    const s = xm.allocator.create(T.Session) catch unreachable;
    defer xm.allocator.destroy(s);
    s.* = .{
        .id = 1,
        .name = xm.xstrdup("s"),
        .cwd = xm.xstrdup("/"),
        .windows = std.AutoHashMap(i32, *T.Winlink).init(xm.allocator),
        .options = opts.options_create(opts.global_s_options),
        .environ = env_mod.environ_create(),
    };
    defer {
        s.windows.deinit();
        opts.options_free(s.options);
        env_mod.environ_free(s.environ);
        xm.allocator.free(s.name);
        xm.allocator.free(@constCast(s.cwd));
    }
    status_update_cache(s);

    var cl: T.Client = .{
        .name = "c1",
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{ .screen = undefined },
    };
    defer env_mod.environ_free(cl.environ);
    cl.tty = .{ .client = &cl, .sx = 120, .sy = 40, .xpixel = 17, .ypixel = 34 };
    cl.session = s;

    try client_registry.clients.append(xm.allocator, &cl);
    defer client_registry.clients.clearRetainingCapacity();

    var sx: u32 = 0;
    var sy: u32 = 0;
    var xpixel: u32 = 0;
    var ypixel: u32 = 0;
    default_window_size(&cl, s, null, &sx, &sy, &xpixel, &ypixel, -1);

    try std.testing.expectEqual(@as(u32, 120), sx);
    try std.testing.expectEqual(@as(u32, 39), sy);
    try std.testing.expectEqual(@as(u32, 17), xpixel);
    try std.testing.expectEqual(@as(u32, 34), ypixel);
}

test "default_window_size falls back to session default-size" {
    const env_mod = @import("environ.zig");

    client_registry.clients.clearRetainingCapacity();
    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);

    const s = xm.allocator.create(T.Session) catch unreachable;
    defer xm.allocator.destroy(s);
    s.* = .{
        .id = 2,
        .name = xm.xstrdup("fallback"),
        .cwd = xm.xstrdup("/"),
        .windows = std.AutoHashMap(i32, *T.Winlink).init(xm.allocator),
        .options = opts.options_create(opts.global_s_options),
        .environ = env_mod.environ_create(),
    };
    defer {
        s.windows.deinit();
        opts.options_free(s.options);
        env_mod.environ_free(s.environ);
        xm.allocator.free(s.name);
        xm.allocator.free(@constCast(s.cwd));
    }
    opts.options_set_string(s.options, false, "default-size", "101x33");
    status_update_cache(s);

    var sx: u32 = 0;
    var sy: u32 = 0;
    var xpixel: u32 = 99;
    var ypixel: u32 = 99;
    default_window_size(null, s, null, &sx, &sy, &xpixel, &ypixel, -1);

    try std.testing.expectEqual(@as(u32, 101), sx);
    try std.testing.expectEqual(@as(u32, 33), sy);
    try std.testing.expectEqual(@as(u32, 0), xpixel);
    try std.testing.expectEqual(@as(u32, 0), ypixel);
}

test "recalculate_size applies smallest client size to a linked window" {
    const env_mod = @import("environ.zig");

    client_registry.clients.clearRetainingCapacity();
    sess.session_init_globals(xm.allocator);
    win.window_init_globals(xm.allocator);

    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);

    const s = sess.session_create(null, "resize-test", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("resize-test") != null) sess.session_destroy(s, false, "test");
    status_update_cache(s);

    var cause: ?[]u8 = null;
    const w = win.window_create(120, 50, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    defer win.window_remove_ref(w, "test");
    const wl = sess.session_attach(s, w, -1, &cause).?;
    const wp = win.window_add_pane(w, null, 120, 50);
    w.active = wp;
    s.curw = wl;

    opts.options_set_number(w.options, "window-size", T.WINDOW_SIZE_SMALLEST);

    var big: T.Client = .{
        .name = "big",
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{ .screen = undefined },
    };
    defer env_mod.environ_free(big.environ);
    big.tty = .{ .client = &big, .sx = 120, .sy = 40, .xpixel = 20, .ypixel = 40 };
    big.session = s;

    var small: T.Client = .{
        .name = "small",
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{ .screen = undefined },
    };
    defer env_mod.environ_free(small.environ);
    small.tty = .{ .client = &small, .sx = 90, .sy = 30, .xpixel = 18, .ypixel = 36 };
    small.session = s;

    try client_registry.clients.append(xm.allocator, &big);
    try client_registry.clients.append(xm.allocator, &small);
    defer client_registry.clients.clearRetainingCapacity();

    recalculate_size(w, true);

    try std.testing.expectEqual(@as(u32, 90), w.sx);
    try std.testing.expectEqual(@as(u32, 29), w.sy);
    try std.testing.expectEqual(@as(u32, 90), wp.sx);
    try std.testing.expectEqual(@as(u32, 29), wp.sy);
}
