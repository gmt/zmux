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
// Ported in part from tmux/server-client.c and tmux/cmd.c.
// Original copyright:
//   Copyright (c) 2009 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

//! mouse-runtime.zig – reduced shared mouse target and hit-test helpers.

const std = @import("std");
const T = @import("types.zig");
const resize_mod = @import("resize.zig");
const sess = @import("session.zig");
const status_mod = @import("status.zig");
const window_mod = @import("window.zig");
const xm = @import("xmalloc.zig");

const RawType = enum {
    move,
    down,
    up,
    drag,
    wheel,
};

const ResolvedTarget = struct {
    s: *T.Session,
    wl: *T.Winlink,
    w: *T.Window,
    wp: ?*T.WindowPane = null,
    target: T.KeyMouseTarget,
};

pub fn key_target(key: T.key_code) ?T.KeyMouseTarget {
    if (!T.keycIsMouse(key)) return null;
    const masked = key & T.KEYC_MASK_KEY;
    if (masked < T.KEYC_MOUSEMOVE) return null;
    const offset = masked - T.KEYC_MOUSEMOVE;
    return @enumFromInt(offset % T.KEYC_MOUSE_TARGET_COUNT);
}

pub fn cmd_mouse_window(m: *const T.MouseEvent, session_out: ?*?*T.Session) ?*T.Winlink {
    if (!m.valid) return null;

    const session_id: u32 = std.math.cast(u32, m.s) orelse return null;
    const s = sess.session_find_by_id(session_id) orelse return null;
    const wl = if (m.w == -1) blk: {
        break :blk s.curw orelse return null;
    } else blk: {
        const window_id: u32 = std.math.cast(u32, m.w) orelse return null;
        const window = window_mod.window_find_by_id(window_id) orelse return null;
        break :blk sess.winlink_find_by_window(&s.windows, window) orelse return null;
    };

    if (session_out) |slot| slot.* = s;
    return wl;
}

pub fn cmd_mouse_pane(
    m: *const T.MouseEvent,
    session_out: ?*?*T.Session,
    winlink_out: ?*?*T.Winlink,
) ?*T.WindowPane {
    var local_session: ?*T.Session = null;
    const wl = cmd_mouse_window(m, &local_session) orelse return null;
    const wp = if (m.wp == -1) blk: {
        break :blk wl.window.active orelse return null;
    } else blk: {
        const pane_id: u32 = std.math.cast(u32, m.wp) orelse return null;
        const pane = window_mod.window_pane_find_by_id(pane_id) orelse return null;
        if (!window_mod.window_has_pane(wl.window, pane)) return null;
        break :blk pane;
    };

    if (session_out) |slot| slot.* = local_session;
    if (winlink_out) |slot| slot.* = wl;
    return wp;
}

pub fn translate_client_mouse_event(cl: *T.Client, event: *T.key_event) bool {
    if (event.key != T.KEYC_MOUSE) return true;

    const raw_type = classify_raw_event(&event.m) orelse return false;
    const button_bits = button_bits_for(raw_type, &event.m) orelse return false;
    const resolved = resolve_target(cl, &event.m) orelse return false;
    const family = key_family_for(raw_type, T.mouseButtons(button_bits)) orelse return false;

    var translated = T.keycMouse(family, resolved.target);
    if (button_bits & T.MOUSE_MASK_META != 0) translated |= T.KEYC_META;
    if (button_bits & T.MOUSE_MASK_CTRL != 0) translated |= T.KEYC_CTRL;
    if (button_bits & T.MOUSE_MASK_SHIFT != 0) translated |= T.KEYC_SHIFT;

    event.key = translated;
    event.m.valid = true;
    event.m.key = translated;
    event.m.s = @intCast(resolved.s.id);
    event.m.w = @intCast(resolved.w.id);
    event.m.wp = if (resolved.wp) |pane| @intCast(pane.id) else -1;
    return true;
}

fn classify_raw_event(m: *const T.MouseEvent) ?RawType {
    if (T.mouseWheel(m.b)) return .wheel;
    if (T.mouseRelease(m.b)) return .up;
    if (T.mouseDrag(m.b)) return .drag;
    if (m.sgr_type == 'm' and T.mouseWheel(m.sgr_b)) return null;
    return .down;
}

fn button_bits_for(raw_type: RawType, m: *const T.MouseEvent) ?u32 {
    return switch (raw_type) {
        .down, .drag, .wheel => m.b,
        .up => if (m.sgr_type == 'm') m.sgr_b else m.lb,
        .move => m.b,
    };
}

fn key_family_for(raw_type: RawType, buttons: u32) ?T.key_code {
    return switch (raw_type) {
        .move => T.KEYC_MOUSEMOVE,
        .drag => button_family(buttons, .{
            .one = T.KEYC_MOUSEDRAG1,
            .two = T.KEYC_MOUSEDRAG2,
            .three = T.KEYC_MOUSEDRAG3,
            .six = T.KEYC_MOUSEDRAG6,
            .seven = T.KEYC_MOUSEDRAG7,
            .eight = T.KEYC_MOUSEDRAG8,
            .nine = T.KEYC_MOUSEDRAG9,
            .ten = T.KEYC_MOUSEDRAG10,
            .eleven = T.KEYC_MOUSEDRAG11,
        }),
        .down => button_family(buttons, .{
            .one = T.KEYC_MOUSEDOWN1,
            .two = T.KEYC_MOUSEDOWN2,
            .three = T.KEYC_MOUSEDOWN3,
            .six = T.KEYC_MOUSEDOWN6,
            .seven = T.KEYC_MOUSEDOWN7,
            .eight = T.KEYC_MOUSEDOWN8,
            .nine = T.KEYC_MOUSEDOWN9,
            .ten = T.KEYC_MOUSEDOWN10,
            .eleven = T.KEYC_MOUSEDOWN11,
        }),
        .up => button_family(buttons, .{
            .one = T.KEYC_MOUSEUP1,
            .two = T.KEYC_MOUSEUP2,
            .three = T.KEYC_MOUSEUP3,
            .six = T.KEYC_MOUSEUP6,
            .seven = T.KEYC_MOUSEUP7,
            .eight = T.KEYC_MOUSEUP8,
            .nine = T.KEYC_MOUSEUP9,
            .ten = T.KEYC_MOUSEUP10,
            .eleven = T.KEYC_MOUSEUP11,
        }),
        .wheel => switch (buttons) {
            T.MOUSE_WHEEL_UP => T.KEYC_WHEELUP,
            T.MOUSE_WHEEL_DOWN => T.KEYC_WHEELDOWN,
            else => null,
        },
    };
}

fn button_family(buttons: u32, families: anytype) ?T.key_code {
    return switch (buttons) {
        T.MOUSE_BUTTON_1 => families.one,
        T.MOUSE_BUTTON_2 => families.two,
        T.MOUSE_BUTTON_3 => families.three,
        T.MOUSE_BUTTON_6 => families.six,
        T.MOUSE_BUTTON_7 => families.seven,
        T.MOUSE_BUTTON_8 => families.eight,
        T.MOUSE_BUTTON_9 => families.nine,
        T.MOUSE_BUTTON_10 => families.ten,
        T.MOUSE_BUTTON_11 => families.eleven,
        else => null,
    };
}

fn resolve_target(cl: *T.Client, m: *T.MouseEvent) ?ResolvedTarget {
    const s = cl.session orelse return null;
    const wl = s.curw orelse return null;
    const w = wl.window;

    m.valid = false;
    m.ignore = false;
    m.s = @intCast(s.id);
    m.w = -1;
    m.wp = -1;
    m.statusat = status_mod.status_at_line(cl);
    m.statuslines = resize_mod.status_line_size(cl);

    if (m.statusat != -1 and m.y >= @as(u32, @intCast(m.statusat)) and m.y < @as(u32, @intCast(m.statusat)) + m.statuslines) {
        const row = m.y - @as(u32, @intCast(m.statusat));
        if (status_mod.status_get_range(cl, m.x, row)) |range| {
            switch (range.type) {
                .none => return null,
                .left => return .{ .s = s, .wl = wl, .w = w, .target = .status_left },
                .right => return .{ .s = s, .wl = wl, .w = w, .target = .status_right },
                .pane => {
                    const pane = window_mod.window_pane_find_by_id(range.argument) orelse return null;
                    const range_wl = sess.winlink_find_by_window(&s.windows, pane.window) orelse return null;
                    m.wp = @intCast(pane.id);
                    m.w = @intCast(pane.window.id);
                    return .{ .s = s, .wl = range_wl, .w = pane.window, .wp = pane, .target = .status };
                },
                .window => {
                    const range_wl = sess.winlink_find_by_index(&s.windows, @intCast(range.argument)) orelse return null;
                    m.w = @intCast(range_wl.window.id);
                    return .{ .s = s, .wl = range_wl, .w = range_wl.window, .wp = range_wl.window.active, .target = .status };
                },
                .session => {
                    const range_session = sess.session_find_by_id(range.argument) orelse return null;
                    const range_wl = range_session.curw orelse return null;
                    m.s = @intCast(range_session.id);
                    return .{ .s = range_session, .wl = range_wl, .w = range_wl.window, .wp = range_wl.window.active, .target = .status };
                },
                .user => return .{ .s = s, .wl = wl, .w = w, .wp = w.active, .target = .status },
            }
        }
        return .{ .s = s, .wl = wl, .w = w, .wp = w.active, .target = .status_default };
    }

    const pane_y = if (m.statusat == 0 and m.y >= m.statuslines) m.y - m.statuslines else m.y;
    const pane = window_get_active_at(w, m.x, pane_y) orelse return null;
    m.w = @intCast(w.id);
    m.wp = @intCast(pane.id);
    return .{ .s = s, .wl = wl, .w = w, .wp = pane, .target = .pane };
}

fn window_get_active_at(w: *T.Window, x: u32, y: u32) ?*T.WindowPane {
    for (w.panes.items) |pane| {
        if (x < pane.xoff or x >= pane.xoff + pane.sx) continue;
        if (y < pane.yoff or y >= pane.yoff + pane.sy) continue;
        return pane;
    }
    return null;
}

test "translate_client_mouse_event maps status pane ranges onto shared status targets" {
    const env_mod = @import("environ.zig");
    const opts = @import("options.zig");

    sess.session_init_globals(xm.allocator);
    window_mod.window_init_globals(xm.allocator);

    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);

    const s = sess.session_create(null, "mouse-status", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer sess.session_destroy(s, false, "test");

    const w = window_mod.window_create(12, 4, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    var cause: ?[]u8 = null;
    const wl = sess.session_attach(s, w, 0, &cause).?;
    s.curw = wl;
    const wp = window_mod.window_add_pane(w, null, 12, 4);
    w.active = wp;

    const fmt = try std.fmt.allocPrint(xm.allocator, "#[range=pane|%{d}]hit#[norange default]", .{wp.id});
    defer xm.allocator.free(fmt);
    opts.options_set_array(s.options, "status-format", &.{fmt});

    var client = T.Client{
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{ .screen = undefined },
        .session = s,
    };
    defer {
        status_mod.status_free(&client);
        env_mod.environ_free(client.environ);
    }
    client.tty = .{ .client = &client, .sx = 12, .sy = 5 };

    const rendered = status_mod.render(&client);
    defer if (rendered.payload.len != 0) xm.allocator.free(rendered.payload);

    var event = T.key_event{ .key = T.KEYC_MOUSE, .len = 1 };
    event.m = .{ .x = 1, .y = @intCast(status_mod.status_at_line(&client)), .b = T.MOUSE_BUTTON_1 };

    try std.testing.expect(translate_client_mouse_event(&client, &event));
    try std.testing.expect(event.m.valid);
    try std.testing.expectEqual(T.keycMouse(T.KEYC_MOUSEDOWN1, .status), event.key);
    try std.testing.expectEqual(@as(i32, @intCast(s.id)), event.m.s);
    try std.testing.expectEqual(@as(i32, @intCast(w.id)), event.m.w);
    try std.testing.expectEqual(@as(i32, @intCast(wp.id)), event.m.wp);
}

test "translate_client_mouse_event maps pane hits onto pane targets" {
    const env_mod = @import("environ.zig");
    const opts = @import("options.zig");

    sess.session_init_globals(xm.allocator);
    window_mod.window_init_globals(xm.allocator);

    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);

    const s = sess.session_create(null, "mouse-pane", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer sess.session_destroy(s, false, "test");

    const w = window_mod.window_create(10, 3, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    var cause: ?[]u8 = null;
    const wl = sess.session_attach(s, w, 0, &cause).?;
    s.curw = wl;
    const wp = window_mod.window_add_pane(w, null, 10, 3);
    w.active = wp;

    var client = T.Client{
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{ .screen = undefined },
        .session = s,
    };
    defer env_mod.environ_free(client.environ);
    client.tty = .{ .client = &client, .sx = 10, .sy = 3 };

    var event = T.key_event{ .key = T.KEYC_MOUSE, .len = 1 };
    event.m = .{ .x = 2, .y = 1, .b = T.MOUSE_BUTTON_1 };

    try std.testing.expect(translate_client_mouse_event(&client, &event));
    try std.testing.expectEqual(T.keycMouse(T.KEYC_MOUSEDOWN1, .pane), event.key);
    try std.testing.expectEqual(@as(i32, @intCast(wp.id)), event.m.wp);
}
