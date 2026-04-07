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
// Ported in part from tmux/window-clock.c.
// Original copyright:
//   Copyright (c) 2009 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

const std = @import("std");
const T = @import("types.zig");
const c = @import("c.zig");
const args_mod = @import("arguments.zig");
const grid_mod = @import("grid.zig");
const opts = @import("options.zig");
const proc_mod = @import("proc.zig");
const screen_mod = @import("screen.zig");
const screen_write = @import("screen-write.zig");
const window_mod = @import("window.zig");
const window_mode_runtime = @import("window-mode-runtime.zig");
const xm = @import("xmalloc.zig");

/// Mirrors tmux `window_clock_mode_data`: dedicated mode screen, last-render time, timer.
const ClockModeData = struct {
    mode_screen: *T.Screen,
    tim: c.posix_sys.time_t,
    timer_event: ?*c.libevent.event = null,
};

/// Same layout as tmux `window_clock_table` (digit / colon / A / P / M glyphs).
pub const window_clock_table = [14][5][5]u8{
    .{ .{ 1, 1, 1, 1, 1 }, .{ 1, 0, 0, 0, 1 }, .{ 1, 0, 0, 0, 1 }, .{ 1, 0, 0, 0, 1 }, .{ 1, 1, 1, 1, 1 } },
    .{ .{ 0, 0, 0, 0, 1 }, .{ 0, 0, 0, 0, 1 }, .{ 0, 0, 0, 0, 1 }, .{ 0, 0, 0, 0, 1 }, .{ 0, 0, 0, 0, 1 } },
    .{ .{ 1, 1, 1, 1, 1 }, .{ 0, 0, 0, 0, 1 }, .{ 1, 1, 1, 1, 1 }, .{ 1, 0, 0, 0, 0 }, .{ 1, 1, 1, 1, 1 } },
    .{ .{ 1, 1, 1, 1, 1 }, .{ 0, 0, 0, 0, 1 }, .{ 1, 1, 1, 1, 1 }, .{ 0, 0, 0, 0, 1 }, .{ 1, 1, 1, 1, 1 } },
    .{ .{ 1, 0, 0, 0, 1 }, .{ 1, 0, 0, 0, 1 }, .{ 1, 1, 1, 1, 1 }, .{ 0, 0, 0, 0, 1 }, .{ 0, 0, 0, 0, 1 } },
    .{ .{ 1, 1, 1, 1, 1 }, .{ 1, 0, 0, 0, 0 }, .{ 1, 1, 1, 1, 1 }, .{ 0, 0, 0, 0, 1 }, .{ 1, 1, 1, 1, 1 } },
    .{ .{ 1, 1, 1, 1, 1 }, .{ 1, 0, 0, 0, 0 }, .{ 1, 1, 1, 1, 1 }, .{ 1, 0, 0, 0, 1 }, .{ 1, 1, 1, 1, 1 } },
    .{ .{ 1, 1, 1, 1, 1 }, .{ 0, 0, 0, 0, 1 }, .{ 0, 0, 0, 0, 1 }, .{ 0, 0, 0, 0, 1 }, .{ 0, 0, 0, 0, 1 } },
    .{ .{ 1, 1, 1, 1, 1 }, .{ 1, 0, 0, 0, 1 }, .{ 1, 1, 1, 1, 1 }, .{ 1, 0, 0, 0, 1 }, .{ 1, 1, 1, 1, 1 } },
    .{ .{ 1, 1, 1, 1, 1 }, .{ 1, 0, 0, 0, 1 }, .{ 1, 1, 1, 1, 1 }, .{ 0, 0, 0, 0, 1 }, .{ 1, 1, 1, 1, 1 } },
    .{ .{ 0, 0, 0, 0, 0 }, .{ 0, 0, 1, 0, 0 }, .{ 0, 0, 0, 0, 0 }, .{ 0, 0, 1, 0, 0 }, .{ 0, 0, 0, 0, 0 } },
    .{ .{ 1, 1, 1, 1, 1 }, .{ 1, 0, 0, 0, 1 }, .{ 1, 1, 1, 1, 1 }, .{ 1, 0, 0, 0, 1 }, .{ 1, 0, 0, 0, 1 } },
    .{ .{ 1, 1, 1, 1, 1 }, .{ 1, 0, 0, 0, 1 }, .{ 1, 1, 1, 1, 1 }, .{ 1, 0, 0, 0, 0 }, .{ 1, 0, 0, 0, 0 } },
    .{ .{ 1, 0, 0, 0, 1 }, .{ 1, 1, 0, 1, 1 }, .{ 1, 0, 1, 0, 1 }, .{ 1, 0, 0, 0, 1 }, .{ 1, 0, 0, 0, 1 } },
};

pub const window_clock_mode = T.WindowMode{
    .name = "clock-mode",
    .resize = window_clock_resize,
    .key = window_clock_key,
    .close = window_clock_free,
    .get_screen = window_clock_get_screen,
};

pub fn enter_mode(wp: *T.WindowPane) void {
    if (window_mod.window_pane_mode(wp)) |active| {
        if (active.mode == &window_clock_mode) return;
    }

    screen_mod.screen_enter_alternate(wp, true);

    const wme = window_mode_runtime.pushMode(wp, &window_clock_mode, null, null);
    _ = window_clock_init(wme, null, null);
}

/// tmux `window_clock_init` – allocate mode data, mode screen, timer, initial draw.
pub fn window_clock_init(
    wme: *T.WindowModeEntry,
    fs: ?*const T.CmdFindState,
    args: ?*const args_mod.Arguments,
) *T.Screen {
    _ = fs;
    _ = args;
    const wp = wme.wp;
    const sx = wp.base.grid.sx;
    const sy = wp.base.grid.sy;

    const mode_screen = screen_mod.screen_init(sx, sy, 0);
    mode_screen.mode &= ~@as(i32, T.MODE_CURSOR);
    mode_screen.cursor_visible = false;

    const data_ptr = xm.allocator.create(ClockModeData) catch unreachable;
    data_ptr.* = .{
        .mode_screen = mode_screen,
        .tim = c.posix_sys.time(null),
        .timer_event = null,
    };
    wme.data = @ptrCast(data_ptr);

    window_clock_start_timer(wme);
    window_clock_draw_screen(wme);
    return mode_screen;
}

/// tmux `window_clock_free` – tear down timer, mode screen, and heap data.
pub fn window_clock_free(wme: *T.WindowModeEntry) void {
    const data = window_clock_mode_data(wme);
    if (data.timer_event) |ev| {
        _ = c.libevent.event_del(ev);
        c.libevent.event_free(ev);
    }
    screen_mod.screen_free(data.mode_screen);
    xm.allocator.destroy(data.mode_screen);
    xm.allocator.destroy(data);

    if (wme.wp.modes.items.len <= 1) {
        screen_mod.screen_leave_alternate(wme.wp, true);
    }
}

/// tmux `window_clock_key` – any key exits the mode.
pub fn window_clock_key(
    wme: *T.WindowModeEntry,
    _client: ?*T.Client,
    _session: *T.Session,
    _wl: *T.Winlink,
    _key: T.key_code,
    _mouse: ?*const T.MouseEvent,
) void {
    _ = _client;
    _ = _session;
    _ = _wl;
    _ = _key;
    _ = _mouse;
    _ = window_mode_runtime.resetMode(wme.wp);
}

/// tmux `window_clock_resize` – resize the mode screen and redraw.
pub fn window_clock_resize(wme: *T.WindowModeEntry, sx: u32, sy: u32) void {
    const data = window_clock_mode_data(wme);
    screen_mod.screen_resize_cursor(data.mode_screen, sx, sy, false, true, true);
    window_clock_draw_screen(wme);
}

/// tmux `window_clock_draw_screen` – format time, draw large digits or compact text, sync to pane.
pub fn window_clock_draw_screen(wme: *T.WindowModeEntry) void {
    const wp = wme.wp;
    const data = window_clock_mode_data(wme);
    const screen = data.mode_screen;
    const colour: i32 = @intCast(opts.options_get_number(wp.window.options, "clock-mode-colour"));
    const style = opts.options_get_number(wp.window.options, "clock-mode-style");

    screen_mod.screen_reset_active(screen);
    screen.mode &= ~@as(i32, T.MODE_CURSOR);
    screen.cursor_visible = false;

    var time_buf: [64]u8 = undefined;
    const text = format_time_now(&time_buf, style) orelse return;

    if (screen.grid.sx < 6 * text.len or screen.grid.sy < 6) {
        draw_compact(screen, text, colour);
    } else {
        draw_large(screen, text, colour);
    }

    sync_mode_screen_to_pane(wp, screen);
}

/// tmux `window_clock_start_timer` – libevent one-shot aligned to the next second (stub if no base).
pub fn window_clock_start_timer(wme: *T.WindowModeEntry) void {
    const data = window_clock_mode_data(wme);
    const base = proc_mod.libevent orelse return;

    if (data.timer_event == null) {
        data.timer_event = c.libevent.event_new(
            base,
            -1,
            @intCast(c.libevent.EV_TIMEOUT),
            window_clock_timer_callback,
            wme,
        );
    }

    const ev = data.timer_event orelse return;
    var ts: c.posix_sys.struct_timespec = undefined;
    if (c.posix_sys.clock_gettime(c.posix_sys.CLOCK_REALTIME, &ts) != 0) {
        var fallback = std.posix.timeval{ .sec = 1, .usec = 0 };
        _ = c.libevent.event_add(ev, @ptrCast(&fallback));
        return;
    }

    var delay_us: i64 = 1_000_000 - @divTrunc(@as(i64, ts.tv_nsec), 1_000);
    if (delay_us <= 0) delay_us = 1_000_000;
    var tv = std.posix.timeval{
        .sec = @intCast(@divTrunc(delay_us, 1_000_000)),
        .usec = @intCast(@mod(delay_us, 1_000_000)),
    };
    if (tv.sec < 0 or (tv.sec == 0 and tv.usec <= 0)) {
        tv.sec = 1;
        tv.usec = 0;
    }
    _ = c.libevent.event_add(ev, @ptrCast(&tv));
}

/// Libevent callback (tmux `window_clock_timer_callback`). C ABI stub forwards here.
export fn window_clock_timer_callback(_fd: i32, _events: i16, arg: ?*anyopaque) void {
    window_clock_timer_callback_inner(_fd, _events, arg);
}

fn window_clock_timer_callback_inner(_fd: i32, _events: i16, arg: ?*anyopaque) void {
    _ = _fd;
    _ = _events;
    const wme: *T.WindowModeEntry = @ptrCast(@alignCast(arg orelse return));
    const wp = wme.wp;
    const data = window_clock_mode_data(wme);
    if (data.timer_event) |ev| _ = c.libevent.event_del(ev);

    var now_tm: c.posix_sys.struct_tm = undefined;
    var then_tm: c.posix_sys.struct_tm = undefined;
    const t = c.posix_sys.time(null);
    var t_mut = t;
    var tim_mut = data.tim;
    _ = c.posix_sys.gmtime_r(&t_mut, &now_tm);
    _ = c.posix_sys.gmtime_r(&tim_mut, &then_tm);

    if (now_tm.tm_sec != then_tm.tm_sec) {
        data.tim = t;
        window_clock_draw_screen(wme);
        window_mode_runtime.noteModeRedraw(wp);
    }

    window_clock_start_timer(wme);
}

fn window_clock_get_screen(wme: *T.WindowModeEntry) *T.Screen {
    return window_clock_mode_data(wme).mode_screen;
}

fn window_clock_mode_data(wme: *T.WindowModeEntry) *ClockModeData {
    return @ptrCast(@alignCast(wme.data.?));
}

fn format_time_now(buf: *[64]u8, style: i64) ?[]const u8 {
    const t = c.posix_sys.time(null);
    var t_mut = t;
    var tm_value: c.posix_sys.struct_tm = undefined;
    if (c.posix_sys.localtime_r(&t_mut, &tm_value) == null) return null;

    const fmt = switch (style) {
        0 => "%l:%M \x00",
        2 => "%l:%M:%S \x00",
        3 => "%H:%M:%S\x00",
        else => "%H:%M\x00",
    };

    const written = c.posix_sys.strftime(buf.ptr, buf.len, fmt.ptr, &tm_value);
    if (written == 0) return null;

    var len: usize = written;
    if (style == 0 or style == 2) {
        const suffix = if (tm_value.tm_hour >= 12) "PM" else "AM";
        if (len + suffix.len > buf.len) return null;
        @memcpy(buf[len .. len + suffix.len], suffix);
        len += suffix.len;
    }
    return buf[0..len];
}

fn draw_compact(screen: *T.Screen, text: []const u8, colour: i32) void {
    if (screen.grid.sy == 0 or screen.grid.sx < text.len) return;

    var gc = T.grid_default_cell;
    gc.flags |= T.GRID_FLAG_NOPALETTE;
    gc.fg = colour;

    var ctx = T.ScreenWriteCtx{ .s = screen };
    const x = screen.grid.sx / 2 - @as(u32, @intCast(text.len / 2));
    const y = screen.grid.sy / 2;
    screen_write.cursor_to(&ctx, y, x);
    put_ascii_string(&ctx, &gc, text);
}

fn draw_large(screen: *T.Screen, text: []const u8, colour: i32) void {
    var gc = T.grid_default_cell;
    gc.flags |= T.GRID_FLAG_NOPALETTE;
    gc.bg = colour;

    var ctx = T.ScreenWriteCtx{ .s = screen };
    var x = screen.grid.sx / 2 - 3 * @as(u32, @intCast(text.len));
    const y = screen.grid.sy / 2 - 3;

    for (text) |ch| {
        const idx = clock_glyph_index(ch) orelse {
            x += 6;
            continue;
        };

        for (0..5) |row| {
            for (0..5) |col| {
                if (window_clock_table[idx][row][col] == 0) continue;
                screen_write.cursor_to(&ctx, y + @as(u32, @intCast(row)), x + @as(u32, @intCast(col)));
                screen_write.putCell(&ctx, &gc);
            }
        }
        x += 6;
    }
}

fn put_ascii_string(ctx: *T.ScreenWriteCtx, gc: *const T.GridCell, text: []const u8) void {
    for (text) |ch| {
        var cell = gc.*;
        cell.data = T.grid_default_cell.data;
        cell.data.data[0] = ch;
        screen_write.putCell(ctx, &cell);
    }
}

fn clock_glyph_index(ch: u8) ?usize {
    return switch (ch) {
        '0'...'9' => ch - '0',
        ':' => 10,
        'A' => 11,
        'P' => 12,
        'M' => 13,
        else => null,
    };
}

/// Copy the mode screen into `wp.screen` so tty drawing (`screen_current`) shows the clock.
fn sync_mode_screen_to_pane(wp: *T.WindowPane, src: *T.Screen) void {
    const view = wp.screen;
    screen_mod.screen_reset_active(view);
    view.mode = src.mode;
    view.cursor_visible = src.cursor_visible;

    var row: u32 = 0;
    while (row < @min(src.grid.sy, view.grid.sy)) : (row += 1) {
        const w = @min(src.grid.sx, view.grid.sx);
        var col: u32 = 0;
        while (col < w) : (col += 1) {
            var cell: T.GridCell = undefined;
            grid_mod.get_cell(src.grid, row, col, &cell);
            grid_mod.set_cell(view.grid, row, col, &cell);
        }
    }
}

fn init_test_globals() void {
    const env_mod = @import("environ.zig");
    const opts_mod = @import("options.zig");
    const sess = @import("session.zig");

    sess.session_init_globals(xm.allocator);
    window_mod.window_init_globals(xm.allocator);

    opts_mod.global_options = opts_mod.options_create(null);
    opts_mod.global_s_options = opts_mod.options_create(null);
    opts_mod.global_w_options = opts_mod.options_create(null);
    opts_mod.options_default_all(opts_mod.global_options, T.OPTIONS_TABLE_SERVER);
    opts_mod.options_default_all(opts_mod.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts_mod.options_default_all(opts_mod.global_w_options, T.OPTIONS_TABLE_WINDOW);

    env_mod.global_environ = env_mod.environ_create();
}

fn deinit_test_globals() void {
    const env_mod = @import("environ.zig");
    const opts_mod = @import("options.zig");

    env_mod.environ_free(env_mod.global_environ);
    opts_mod.options_free(opts_mod.global_w_options);
    opts_mod.options_free(opts_mod.global_s_options);
    opts_mod.options_free(opts_mod.global_options);
}

const TestSetup = struct {
    session: *T.Session,
    pane: *T.WindowPane,
    winlink: *T.Winlink,
};

fn test_setup(session_name: []const u8, sx: u32, sy: u32) !TestSetup {
    const sess = @import("session.zig");
    const env_mod = @import("environ.zig");
    const opts_mod = @import("options.zig");

    const session = sess.session_create(null, session_name, "/", env_mod.environ_create(), opts_mod.options_create(opts_mod.global_s_options), null);
    var cause: ?[]u8 = null;
    const window = window_mod.window_create(sx, sy, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    const pane = window_mod.window_add_pane(window, null, sx, sy);
    window.active = pane;
    const wl = sess.session_attach(session, window, -1, &cause).?;
    session.curw = wl;
    return .{
        .session = session,
        .pane = pane,
        .winlink = wl,
    };
}

fn local_timestamp(year: c_int, month: c_int, day: c_int, hour: c_int, minute: c_int, second: c_int) i64 {
    var tm_value: c.posix_sys.struct_tm = std.mem.zeroes(c.posix_sys.struct_tm);
    tm_value.tm_year = year - 1900;
    tm_value.tm_mon = month - 1;
    tm_value.tm_mday = day;
    tm_value.tm_hour = hour;
    tm_value.tm_min = minute;
    tm_value.tm_sec = second;
    tm_value.tm_isdst = -1;
    return @intCast(c.posix_sys.mktime(&tm_value));
}

fn screen_row(screen: *T.Screen, row: u32, alloc: std.mem.Allocator) []u8 {
    const out = alloc.alloc(u8, screen.grid.sx) catch unreachable;
    for (out, 0..) |*slot, col| {
        slot.* = grid_mod.ascii_at(screen.grid, row, @intCast(col));
    }
    return out;
}

/// Test helper: draw as if `when` were the current wall clock (init path uses real time).
fn window_clock_draw_screen_at(wme: *T.WindowModeEntry, when: i64) void {
    const wp = wme.wp;
    const data = window_clock_mode_data(wme);
    const screen = data.mode_screen;
    const colour: i32 = @intCast(opts.options_get_number(wp.window.options, "clock-mode-colour"));
    const style = opts.options_get_number(wp.window.options, "clock-mode-style");

    screen_mod.screen_reset_active(screen);
    screen.mode &= ~@as(i32, T.MODE_CURSOR);
    screen.cursor_visible = false;

    var time_buf: [64]u8 = undefined;
    const text = format_time_at(&time_buf, style, when) orelse return;

    if (screen.grid.sx < 6 * text.len or screen.grid.sy < 6) {
        draw_compact(screen, text, colour);
    } else {
        draw_large(screen, text, colour);
    }

    sync_mode_screen_to_pane(wp, screen);
}

fn format_time_at(buf: *[64]u8, style: i64, when: i64) ?[]const u8 {
    var when_time: c.posix_sys.time_t = @intCast(when);
    var tm_value: c.posix_sys.struct_tm = undefined;
    if (c.posix_sys.localtime_r(&when_time, &tm_value) == null) return null;

    const fmt = switch (style) {
        0 => "%l:%M \x00",
        2 => "%l:%M:%S \x00",
        3 => "%H:%M:%S\x00",
        else => "%H:%M\x00",
    };

    const written = c.posix_sys.strftime(buf.ptr, buf.len, fmt.ptr, &tm_value);
    if (written == 0) return null;

    var len: usize = written;
    if (style == 0 or style == 2) {
        const suffix = if (tm_value.tm_hour >= 12) "PM" else "AM";
        if (len + suffix.len > buf.len) return null;
        @memcpy(buf[len .. len + suffix.len], suffix);
        len += suffix.len;
    }
    return buf[0..len];
}

test "window clock draws compact centred time with configured style" {
    const opts_mod = @import("options.zig");
    const sess = @import("session.zig");

    init_test_globals();
    defer deinit_test_globals();

    const setup = try test_setup("window-clock-compact", 10, 1);
    defer if (sess.session_find("window-clock-compact") != null) sess.session_destroy(setup.session, false, "test");

    enter_mode(setup.pane);
    const wme = window_mod.window_pane_mode(setup.pane).?;
    opts_mod.options_set_number(setup.pane.window.options, "clock-mode-style", 3);
    window_clock_draw_screen_at(wme, local_timestamp(2024, 4, 5, 13, 45, 7));

    const row = screen_row(setup.pane.screen, 0, xm.allocator);
    defer xm.allocator.free(row);
    try std.testing.expectEqualStrings(" 13:45:07 ", row);
}

test "window clock draws large blocks with configured colour" {
    const opts_mod = @import("options.zig");
    const sess = @import("session.zig");

    init_test_globals();
    defer deinit_test_globals();

    const setup = try test_setup("window-clock-large", 40, 7);
    defer if (sess.session_find("window-clock-large") != null) sess.session_destroy(setup.session, false, "test");

    enter_mode(setup.pane);
    const wme = window_mod.window_pane_mode(setup.pane).?;
    opts_mod.options_set_number(setup.pane.window.options, "clock-mode-style", 1);
    opts_mod.options_set_number(setup.pane.window.options, "clock-mode-colour", 6);
    window_clock_draw_screen_at(wme, local_timestamp(2024, 4, 5, 13, 45, 7));

    var cell: T.GridCell = undefined;
    grid_mod.get_cell(setup.pane.screen.grid, 1, 9, &cell);
    try std.testing.expectEqual(@as(i32, 6), cell.bg);
    grid_mod.get_cell(setup.pane.screen.grid, 0, 0, &cell);
    try std.testing.expectEqual(T.grid_default_cell.bg, cell.bg);
}

test "window clock key exits mode and restores the base screen" {
    const sess = @import("session.zig");

    init_test_globals();
    defer deinit_test_globals();

    const setup = try test_setup("window-clock-exit", 20, 6);
    defer if (sess.session_find("window-clock-exit") != null) sess.session_destroy(setup.session, false, "test");

    enter_mode(setup.pane);
    const wme = window_mod.window_pane_mode(setup.pane).?;
    try std.testing.expect(screen_mod.screen_alternate_active(setup.pane));

    window_clock_mode.key.?(wme, null, setup.session, setup.winlink, 'q', null);

    try std.testing.expect(window_mod.window_pane_mode(setup.pane) == null);
    try std.testing.expect(!screen_mod.screen_alternate_active(setup.pane));
}

test "window clock timer callback redraws when the second changes" {
    const sess = @import("session.zig");

    init_test_globals();
    defer deinit_test_globals();

    const setup = try test_setup("window-clock-timer", 20, 6);
    defer if (sess.session_find("window-clock-timer") != null) sess.session_destroy(setup.session, false, "test");

    enter_mode(setup.pane);
    const wme = window_mod.window_pane_mode(setup.pane).?;
    const data = window_clock_mode_data(wme);
    data.tim = c.posix_sys.time(null) - 1;
    setup.pane.flags = 0;

    window_clock_timer_callback_inner(-1, 0, wme);

    try std.testing.expect(setup.pane.flags & T.PANE_REDRAW != 0);
    try std.testing.expect(data.tim != 0);
}
