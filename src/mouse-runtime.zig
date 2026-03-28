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
const options_mod = @import("options.zig");
const resize_mod = @import("resize.zig");
const screen_mod = @import("screen.zig");
const sess = @import("session.zig");
const status_mod = @import("status.zig");
const status_prompt = @import("status-prompt.zig");
const menu = @import("menu.zig");
const window_mod = @import("window.zig");
const xm = @import("xmalloc.zig");

const EventType = enum {
    move,
    down,
    up,
    drag,
    wheel,
    second,
    double,
    triple,
};

const EffectiveEvent = struct {
    kind: EventType,
    x: u32,
    y: u32,
    buttons: u32,
    ignore: bool = false,
};

const ResolvedTarget = struct {
    s: *T.Session,
    wl: *T.Winlink,
    w: *T.Window,
    wp: ?*T.WindowPane = null,
    target: T.KeyMouseTarget,
    slider_mpos: i32 = -1,
};

pub fn client_outer_tty_mode(cl: *const T.Client) i32 {
    if ((cl.flags & (T.CLIENT_CONTROL | T.CLIENT_SUSPENDED)) != 0) return 0;

    const session = cl.session orelse return 0;
    const wl = session.curw orelse return 0;
    const window = wl.window;

    var mode: i32 = 0;
    if (!status_prompt.status_prompt_active(@constCast(cl))) {
        if (window.active) |wp| {
            const current = screen_mod.screen_current(wp);
            if (current.bracketed_paste) mode |= T.MODE_BRACKETPASTE;
        }
    }

    if (options_mod.options_get_number(session.options, "focus-events") != 0)
        mode |= T.MODE_FOCUSON;

    if (menu.overlay_wants_mouse(cl))
        return mode | T.MODE_MOUSE_ALL | T.MODE_MOUSE_BUTTON;

    if (options_mod.options_get_number(session.options, "mouse") == 0) return mode;

    for (window.panes.items) |pane| {
        const current = screen_mod.screen_current(pane);
        if ((current.mode & T.MODE_MOUSE_ALL) != 0) mode |= T.MODE_MOUSE_ALL;
    }

    if (options_mod.options_get_number(session.options, "focus-follows-mouse") != 0)
        mode |= T.MODE_MOUSE_ALL
    else if ((mode & T.MODE_MOUSE_ALL) == 0)
        mode |= T.MODE_MOUSE_BUTTON;

    return mode;
}

pub fn key_target(key: T.key_code) ?T.KeyMouseTarget {
    if (!T.keycIsMouse(key)) return null;
    const masked = key & T.KEYC_MASK_KEY;
    if (masked < T.KEYC_MOUSEMOVE) return null;
    const offset = masked - T.KEYC_MOUSEMOVE;
    return @enumFromInt(offset % T.KEYC_MOUSE_TARGET_COUNT);
}

pub fn key_base(key: T.key_code) ?T.key_code {
    const target = key_target(key) orelse return null;
    return (key & T.KEYC_MASK_KEY) - @intFromEnum(target);
}

pub fn click_timeout_event(cl: *T.Client) ?T.key_event {
    defer clearClickState(cl);

    if (cl.click_state != .triple_pending) return null;

    var event = T.key_event{
        .key = T.KEYC_DOUBLECLICK,
        .m = cl.click_event,
    };
    event.m.ignore = true;
    return event;
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
    if (event.key != T.KEYC_MOUSE and event.key != T.KEYC_DOUBLECLICK) return true;

    const effective = classify_raw_event(cl, event) orelse return false;
    var resolved = resolve_target(cl, effective.x, effective.y, &event.m) orelse {
        if (effective.kind != .drag and effective.kind != .wheel and effective.kind != .double and effective.kind != .triple and
            cl.tty.mouse_drag_flag != 0)
        {
            clearDragState(cl);
        }
        return false;
    };
    var kind = effective.kind;
    const button_bits = effective.buttons;
    const buttons = T.mouseButtons(button_bits);

    if (kind != .drag and kind != .wheel and kind != .double and kind != .triple and cl.tty.mouse_drag_flag != 0) {
        if (cl.tty.mouse_scrolling_flag) resolved.target = .scrollbar_slider;
        if (cl.tty.mouse_drag_release) |release|
            release(cl, &event.m);
        const family = drag_end_family(cl.tty.mouse_drag_flag - 1) orelse {
            clearDragState(cl);
            return false;
        };
        clearDragState(cl);
        finish_translation(event, family, resolved.target, resolved, effective.ignore, button_bits);
        return true;
    }

    if (kind == .down or kind == .second or kind == .triple) {
        update_click_state(cl, &kind, button_bits, resolved.target, event.m.wp, &event.m);
    }

    if (kind == .drag and cl.tty.mouse_scrolling_flag) {
        resolved.target = .scrollbar_slider;
    }

    const family = key_family_for(kind, buttons, resolved.target) orelse return false;

    if (kind == .drag) {
        cl.tty.mouse_drag_flag = buttons + 1;
        if (!cl.tty.mouse_scrolling_flag and resolved.target == .scrollbar_slider) {
            cl.tty.mouse_scrolling_flag = true;
            cl.tty.mouse_slider_mpos = resolved.slider_mpos;
            if (event.m.statusat == 0) {
                cl.tty.mouse_slider_mpos += @intCast(event.m.statuslines);
            }
        }
        if (cl.tty.mouse_drag_update != null) {
            assign_translated_mouse_event(event, T.KEYC_DRAGGING, resolved, effective.ignore, button_bits);
            return true;
        }
    }

    finish_translation(event, family, resolved.target, resolved, effective.ignore, button_bits);
    return true;
}

fn classify_raw_event(cl: *const T.Client, event: *const T.key_event) ?EffectiveEvent {
    const m = &event.m;

    if (event.key == T.KEYC_DOUBLECLICK) {
        return .{
            .kind = .double,
            .x = m.x,
            .y = m.y,
            .buttons = m.b,
            .ignore = true,
        };
    }

    if ((m.sgr_type != ' ' and T.mouseDrag(m.sgr_b) and T.mouseRelease(m.sgr_b)) or
        (m.sgr_type == ' ' and T.mouseDrag(m.b) and T.mouseRelease(m.b) and T.mouseRelease(m.lb)))
    {
        return .{ .kind = .move, .x = m.x, .y = m.y, .buttons = 0 };
    }

    if (T.mouseDrag(m.b)) {
        if (cl.tty.mouse_drag_flag != 0) {
            if (m.x == m.lx and m.y == m.ly) return null;
            return .{ .kind = .drag, .x = m.x, .y = m.y, .buttons = m.b };
        }
        return .{ .kind = .drag, .x = m.lx, .y = m.ly, .buttons = m.lb };
    }

    if (T.mouseWheel(m.b)) return .{ .kind = .wheel, .x = m.x, .y = m.y, .buttons = m.b };
    if (T.mouseRelease(m.b)) {
        return .{
            .kind = .up,
            .x = m.x,
            .y = m.y,
            .buttons = if (m.sgr_type == 'm') m.sgr_b else m.lb,
        };
    }

    return .{
        .kind = switch (cl.click_state) {
            .none => .down,
            .double_pending => .second,
            .triple_pending => .triple,
        },
        .x = m.x,
        .y = m.y,
        .buttons = m.b,
    };
}

fn key_family_for(kind: EventType, buttons: u32, target: T.KeyMouseTarget) ?T.key_code {
    return switch (kind) {
        .move => switch (target) {
            .scrollbar_up, .scrollbar_slider, .scrollbar_down => null,
            else => T.KEYC_MOUSEMOVE,
        },
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
        .wheel => switch (buttons) {
            T.MOUSE_WHEEL_UP => T.KEYC_WHEELUP,
            T.MOUSE_WHEEL_DOWN => T.KEYC_WHEELDOWN,
            else => null,
        },
        .second => button_family(buttons, .{
            .one = T.KEYC_SECONDCLICK1,
            .two = T.KEYC_SECONDCLICK2,
            .three = T.KEYC_SECONDCLICK3,
            .six = T.KEYC_SECONDCLICK6,
            .seven = T.KEYC_SECONDCLICK7,
            .eight = T.KEYC_SECONDCLICK8,
            .nine = T.KEYC_SECONDCLICK9,
            .ten = T.KEYC_SECONDCLICK10,
            .eleven = T.KEYC_SECONDCLICK11,
        }),
        .double => button_family(buttons, .{
            .one = T.KEYC_DOUBLECLICK1,
            .two = T.KEYC_DOUBLECLICK2,
            .three = T.KEYC_DOUBLECLICK3,
            .six = T.KEYC_DOUBLECLICK6,
            .seven = T.KEYC_DOUBLECLICK7,
            .eight = T.KEYC_DOUBLECLICK8,
            .nine = T.KEYC_DOUBLECLICK9,
            .ten = T.KEYC_DOUBLECLICK10,
            .eleven = T.KEYC_DOUBLECLICK11,
        }),
        .triple => button_family(buttons, .{
            .one = T.KEYC_TRIPLECLICK1,
            .two = T.KEYC_TRIPLECLICK2,
            .three = T.KEYC_TRIPLECLICK3,
            .six = T.KEYC_TRIPLECLICK6,
            .seven = T.KEYC_TRIPLECLICK7,
            .eight = T.KEYC_TRIPLECLICK8,
            .nine = T.KEYC_TRIPLECLICK9,
            .ten = T.KEYC_TRIPLECLICK10,
            .eleven = T.KEYC_TRIPLECLICK11,
        }),
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

fn drag_end_family(buttons: u32) ?T.key_code {
    return button_family(buttons, .{
        .one = T.KEYC_MOUSEDRAGEND1,
        .two = T.KEYC_MOUSEDRAGEND2,
        .three = T.KEYC_MOUSEDRAGEND3,
        .six = T.KEYC_MOUSEDRAGEND6,
        .seven = T.KEYC_MOUSEDRAGEND7,
        .eight = T.KEYC_MOUSEDRAGEND8,
        .nine = T.KEYC_MOUSEDRAGEND9,
        .ten = T.KEYC_MOUSEDRAGEND10,
        .eleven = T.KEYC_MOUSEDRAGEND11,
    });
}

fn resolve_target(cl: *T.Client, x: u32, y: u32, m: *T.MouseEvent) ?ResolvedTarget {
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

    if (m.statusat != -1 and y >= @as(u32, @intCast(m.statusat)) and y < @as(u32, @intCast(m.statusat)) + m.statuslines) {
        const row = y - @as(u32, @intCast(m.statusat));
        if (status_mod.status_get_range(cl, x, row)) |range| {
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

    const pane_y = if (m.statusat == 0 and y >= m.statuslines) y - m.statuslines else y;
    const hit = window_mod.window_hit_test(w, x, pane_y) orelse return null;
    m.w = @intCast(w.id);
    m.wp = @intCast(hit.pane.id);
    return switch (hit.region) {
        .pane => .{ .s = s, .wl = wl, .w = w, .wp = hit.pane, .target = .pane },
        .border => .{ .s = s, .wl = wl, .w = w, .wp = hit.pane, .target = .border },
        .scrollbar_up => .{ .s = s, .wl = wl, .w = w, .wp = hit.pane, .target = .scrollbar_up },
        .scrollbar_slider => .{
            .s = s,
            .wl = wl,
            .w = w,
            .wp = hit.pane,
            .target = .scrollbar_slider,
            .slider_mpos = hit.slider_mpos,
        },
        .scrollbar_down => .{ .s = s, .wl = wl, .w = w, .wp = hit.pane, .target = .scrollbar_down },
    };
}

fn finish_translation(
    event: *T.key_event,
    family: T.key_code,
    target: T.KeyMouseTarget,
    resolved: ResolvedTarget,
    ignore: bool,
    button_bits: u32,
) void {
    const translated = T.keycMouse(family, target);
    assign_translated_mouse_event(event, translated, resolved, ignore, button_bits);
}

fn assign_translated_mouse_event(
    event: *T.key_event,
    base_key: T.key_code,
    resolved: ResolvedTarget,
    ignore: bool,
    button_bits: u32,
) void {
    var translated = base_key;
    if (button_bits & T.MOUSE_MASK_META != 0) translated |= T.KEYC_META;
    if (button_bits & T.MOUSE_MASK_CTRL != 0) translated |= T.KEYC_CTRL;
    if (button_bits & T.MOUSE_MASK_SHIFT != 0) translated |= T.KEYC_SHIFT;

    event.key = translated;
    event.m.valid = true;
    event.m.ignore = ignore;
    event.m.key = translated;
    event.m.s = @intCast(resolved.s.id);
    event.m.w = @intCast(resolved.w.id);
    event.m.wp = if (resolved.wp) |pane| @intCast(pane.id) else -1;
}

fn update_click_state(
    cl: *T.Client,
    kind: *EventType,
    button_bits: u32,
    target: T.KeyMouseTarget,
    wp: i32,
    m: *const T.MouseEvent,
) void {
    if (kind.* != .down and
        (button_bits != cl.click_button or cl.click_target == null or cl.click_target.? != target or cl.click_wp != wp))
    {
        kind.* = .down;
    }

    switch (kind.*) {
        .down => {
            cl.click_state = .double_pending;
            cl.click_event = m.*;
            cl.click_button = button_bits;
            cl.click_target = target;
            cl.click_wp = wp;
        },
        .second => {
            cl.click_state = .triple_pending;
            cl.click_event = m.*;
            cl.click_button = button_bits;
            cl.click_target = target;
            cl.click_wp = wp;
        },
        .triple => clearClickState(cl),
        else => {},
    }
}

fn clearClickState(cl: *T.Client) void {
    cl.click_state = .none;
    cl.click_button = 0;
    cl.click_target = null;
    cl.click_wp = -1;
}

fn clearDragState(cl: *T.Client) void {
    cl.tty.mouse_drag_flag = 0;
    cl.tty.mouse_drag_update = null;
    cl.tty.mouse_drag_release = null;
    cl.tty.mouse_scrolling_flag = false;
    cl.tty.mouse_slider_mpos = -1;
}

fn testDragCallback(_: *T.Client, _: *T.MouseEvent) void {}

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

test "client_outer_tty_mode follows tmux-style button versus all-motion negotiation" {
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

    const s = sess.session_create(null, "mouse-mode", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer sess.session_destroy(s, false, "test");

    const w = window_mod.window_create(12, 4, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    var cause: ?[]u8 = null;
    const wl = sess.session_attach(s, w, 0, &cause).?;
    s.curw = wl;
    const wp = window_mod.window_add_pane(w, null, 12, 4);
    w.active = wp;
    opts.options_set_number(s.options, "mouse", 1);

    var client = T.Client{
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{ .screen = undefined },
        .session = s,
    };
    defer env_mod.environ_free(client.environ);

    try std.testing.expectEqual(@as(i32, T.MODE_MOUSE_BUTTON), client_outer_tty_mode(&client) & T.ALL_MOUSE_MODES);

    wp.base.mode |= T.MODE_MOUSE_ALL;
    try std.testing.expectEqual(@as(i32, T.MODE_MOUSE_ALL), client_outer_tty_mode(&client) & T.ALL_MOUSE_MODES);

    opts.options_set_number(s.options, "focus-follows-mouse", 1);
    wp.base.mode &= ~@as(i32, T.MODE_MOUSE_ALL);
    try std.testing.expectEqual(@as(i32, T.MODE_MOUSE_ALL), client_outer_tty_mode(&client) & T.ALL_MOUSE_MODES);

    opts.options_set_number(s.options, "focus-events", 1);
    try std.testing.expect((client_outer_tty_mode(&client) & T.MODE_FOCUSON) != 0);
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

test "translate_client_mouse_event maps border hits onto shared border targets" {
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

    const s = sess.session_create(null, "mouse-border", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer sess.session_destroy(s, false, "test");

    const w = window_mod.window_create(9, 3, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    var cause: ?[]u8 = null;
    const wl = sess.session_attach(s, w, 0, &cause).?;
    s.curw = wl;
    const left = window_mod.window_add_pane(w, null, 4, 3);
    left.xoff = 0;
    left.yoff = 0;
    const right = window_mod.window_add_pane(w, null, 4, 3);
    right.xoff = 5;
    right.yoff = 0;
    w.active = left;

    var client = T.Client{
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{ .screen = undefined },
        .session = s,
    };
    defer env_mod.environ_free(client.environ);
    client.tty = .{ .client = &client, .sx = 9, .sy = 3 };

    var event = T.key_event{ .key = T.KEYC_MOUSE, .len = 1 };
    event.m = .{ .x = 4, .y = 1, .b = T.MOUSE_BUTTON_1 };

    try std.testing.expect(translate_client_mouse_event(&client, &event));
    try std.testing.expectEqual(T.keycMouse(T.KEYC_MOUSEDOWN1, .border), event.key);
    try std.testing.expectEqual(@as(i32, @intCast(left.id)), event.m.wp);
}

test "mouse click timeout promotes second click to a translated double click" {
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

    const s = sess.session_create(null, "mouse-double", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
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

    var first = T.key_event{ .key = T.KEYC_MOUSE, .len = 1 };
    first.m = .{ .x = 1, .y = 1, .b = T.MOUSE_BUTTON_1 };
    try std.testing.expect(translate_client_mouse_event(&client, &first));
    try std.testing.expectEqual(T.keycMouse(T.KEYC_MOUSEDOWN1, .pane), first.key);
    try std.testing.expectEqual(T.MouseClickState.double_pending, client.click_state);

    var second = T.key_event{ .key = T.KEYC_MOUSE, .len = 1 };
    second.m = .{ .x = 1, .y = 1, .b = T.MOUSE_BUTTON_1 };
    try std.testing.expect(translate_client_mouse_event(&client, &second));
    try std.testing.expectEqual(T.keycMouse(T.KEYC_SECONDCLICK1, .pane), second.key);
    try std.testing.expectEqual(T.MouseClickState.triple_pending, client.click_state);

    var timed = click_timeout_event(&client) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(T.KEYC_DOUBLECLICK, timed.key);
    try std.testing.expectEqual(@as(i32, @intCast(wp.id)), timed.m.wp);
    try std.testing.expectEqual(T.MouseClickState.none, client.click_state);

    try std.testing.expect(translate_client_mouse_event(&client, &timed));
    try std.testing.expectEqual(T.keycMouse(T.KEYC_DOUBLECLICK1, .pane), timed.key);
}

test "translate_client_mouse_event emits drag-end keys when a drag stops" {
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

    const s = sess.session_create(null, "mouse-drag-end", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
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

    var drag = T.key_event{ .key = T.KEYC_MOUSE, .len = 1 };
    drag.m = .{
        .x = 3,
        .y = 1,
        .lx = 2,
        .ly = 1,
        .lb = T.MOUSE_BUTTON_1,
        .b = T.MOUSE_BUTTON_1 | T.MOUSE_MASK_DRAG,
    };
    try std.testing.expect(translate_client_mouse_event(&client, &drag));
    try std.testing.expectEqual(T.keycMouse(T.KEYC_MOUSEDRAG1, .pane), drag.key);
    try std.testing.expectEqual(T.MOUSE_BUTTON_1 + 1, client.tty.mouse_drag_flag);

    var release = T.key_event{ .key = T.KEYC_MOUSE, .len = 1 };
    release.m = .{
        .x = 3,
        .y = 1,
        .lb = T.MOUSE_BUTTON_1,
        .b = 3,
    };
    try std.testing.expect(translate_client_mouse_event(&client, &release));
    try std.testing.expectEqual(T.keycMouse(T.KEYC_MOUSEDRAGEND1, .pane), release.key);
    try std.testing.expectEqual(@as(u32, 0), client.tty.mouse_drag_flag);
}

test "translate_client_mouse_event emits KEYC_DRAGGING when a drag callback is installed" {
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

    const s = sess.session_create(null, "mouse-drag-callback", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
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
    client.tty.mouse_drag_update = testDragCallback;
    client.tty.mouse_drag_release = testDragCallback;

    var drag = T.key_event{ .key = T.KEYC_MOUSE, .len = 1 };
    drag.m = .{
        .x = 3,
        .y = 1,
        .lx = 2,
        .ly = 1,
        .lb = T.MOUSE_BUTTON_1,
        .b = T.MOUSE_BUTTON_1 | T.MOUSE_MASK_DRAG,
    };
    try std.testing.expect(translate_client_mouse_event(&client, &drag));
    try std.testing.expectEqual(T.KEYC_DRAGGING, drag.key);
    try std.testing.expect(drag.m.valid);
    try std.testing.expectEqual(@as(i32, @intCast(s.id)), drag.m.s);
    try std.testing.expectEqual(@as(i32, @intCast(w.id)), drag.m.w);
    try std.testing.expectEqual(@as(i32, @intCast(wp.id)), drag.m.wp);

    var release = T.key_event{ .key = T.KEYC_MOUSE, .len = 1 };
    release.m = .{
        .x = 3,
        .y = 1,
        .lb = T.MOUSE_BUTTON_1,
        .b = 3,
    };
    try std.testing.expect(translate_client_mouse_event(&client, &release));
    try std.testing.expectEqual(T.keycMouse(T.KEYC_MOUSEDRAGEND1, .pane), release.key);
    try std.testing.expectEqual(@as(u32, 0), client.tty.mouse_drag_flag);
    try std.testing.expect(client.tty.mouse_drag_update == null);
    try std.testing.expect(client.tty.mouse_drag_release == null);
}
