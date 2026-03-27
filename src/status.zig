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

//! status.zig – reduced shared status/prompt renderer over shared cells.

const std = @import("std");
const T = @import("types.zig");
const c_import = @import("c.zig");
const format_mod = @import("format.zig");
const format_draw = @import("format-draw.zig");
const opts = @import("options.zig");
const proc_mod = @import("proc.zig");
const resize_mod = @import("resize.zig");
const screen_mod = @import("screen.zig");
const screen_write = @import("screen-write.zig");
const status_prompt = @import("status-prompt.zig");
const status_runtime = @import("status-runtime.zig");
const style_mod = @import("style.zig");
const tty_draw = @import("tty-draw.zig");
const xm = @import("xmalloc.zig");

pub const RenderResult = struct {
    payload: []u8 = &.{},
    cursor_visible: bool = false,
    cursor_x: u32 = 0,
    cursor_y: u32 = 0,
};

const Area = struct {
    x: u32,
    width: u32,
    line: u32,
};

pub fn pane_row_offset(c: *T.Client) u32 {
    const lines = resize_mod.status_line_size(c);
    if (lines == 0) return 0;
    return if (status_at_line(c) == 0) lines else 0;
}

pub fn status_at_line(c: *T.Client) i32 {
    if (c.flags & (T.CLIENT_STATUSOFF | T.CLIENT_CONTROL) != 0) return -1;
    const lines = resize_mod.status_line_size(c);
    if (lines == 0) return -1;
    const s = c.session orelse return 0;
    if (s.statusat != 1) return s.statusat;
    return @intCast(c.tty.sy - lines);
}

pub fn status_prompt_line_at(c: *T.Client) u32 {
    const lines = resize_mod.status_line_size(c);
    if (lines == 0) return 0;
    const s = c.session orelse return 0;
    const raw_line = @max(opts.options_get_number(s.options, "message-line"), 0);
    return @min(@as(u32, @intCast(raw_line)), lines - 1);
}

pub fn status_get_range(c: *T.Client, x: u32, y: u32) ?*const T.StyleRange {
    if (y >= c.status.entries.len) return null;
    for (c.status.entries[y].ranges.items) |*range| {
        if (x >= range.start and x < range.end) return range;
    }
    return null;
}

pub fn status_free(c: *T.Client) void {
    if (c.status.timer) |ev| {
        _ = c_import.libevent.event_del(ev);
        c_import.libevent.event_free(ev);
        c.status.timer = null;
    }
    for (&c.status.entries) |*entry| {
        if (entry.expanded) |old| xm.allocator.free(old);
        entry.expanded = null;
        entry.ranges.deinit(xm.allocator);
        entry.ranges = .{};
    }
}

pub fn status_timer_start(c: *T.Client) void {
    status_timer_rearm(c, true);
}

pub fn status_timer_update(c: *T.Client) void {
    status_timer_rearm(c, false);
}

pub fn render(c: *T.Client) RenderResult {
    status_timer_update(c);
    if (c.tty.sx == 0 or c.tty.sy == 0) {
        clear_status_entries_from(c, 0);
        return .{};
    }

    const rows = overlay_rows(c);
    if (rows == 0) {
        clear_status_entries_from(c, 0);
        return .{};
    }

    const overlay_start = overlay_start_row(c, rows);
    const screen = screen_mod.screen_init(c.tty.sx, rows, 0);
    defer {
        screen_mod.screen_free(screen);
        xm.allocator.destroy(screen);
    }

    draw_base(screen, c, rows);

    var result = RenderResult{};
    if (status_prompt.status_prompt_active(c)) {
        render_prompt(screen, c, rows, &result);
    } else if (c.message_string) |message| {
        render_message(screen, c, rows, message);
    }

    result.payload = tty_draw.tty_draw_render_screen(screen, c.tty.sx, rows, overlay_start) catch unreachable;
    if (result.cursor_visible) result.cursor_y += overlay_start;
    return result;
}

fn status_timer_rearm(c: *T.Client, fire_now: bool) void {
    if (c.status.timer) |ev| _ = c_import.libevent.event_del(ev);

    const s = c.session orelse return;
    if (opts.options_get_number(s.options, "status") == 0) return;

    if (fire_now) {
        status_timer_callback(-1, 0, c);
        return;
    }

    arm_status_timer(c, opts.options_get_number(s.options, "status-interval"));
}

fn arm_status_timer(c: *T.Client, delay_seconds: i64) void {
    if (delay_seconds <= 0) return;

    if (c.status.timer == null) {
        const base = proc_mod.libevent orelse return;
        c.status.timer = c_import.libevent.event_new(
            base,
            -1,
            @intCast(c_import.libevent.EV_TIMEOUT),
            status_timer_callback,
            c,
        );
    }

    if (c.status.timer) |ev| {
        var tv = std.posix.timeval{
            .sec = @intCast(delay_seconds),
            .usec = 0,
        };
        _ = c_import.libevent.event_add(ev, @ptrCast(&tv));
    }
}

export fn status_timer_callback(_fd: c_int, _events: c_short, arg: ?*anyopaque) void {
    _ = _fd;
    _ = _events;
    const client: *T.Client = @ptrCast(@alignCast(arg orelse return));
    if (client.status.timer) |ev| _ = c_import.libevent.event_del(ev);

    const session = client.session orelse return;
    if (client.message_string == null and !status_prompt.status_prompt_active(client))
        client.flags |= T.CLIENT_REDRAWSTATUS;

    arm_status_timer(client, opts.options_get_number(session.options, "status-interval"));
}

pub fn overlay_rows(c: *T.Client) u32 {
    const lines = resize_mod.status_line_size(c);
    if (lines != 0) return lines;
    return if (status_prompt.status_prompt_active(c) or status_runtime.status_message_active(c)) 1 else 0;
}

fn overlay_start_row(c: *T.Client, rows: u32) u32 {
    const status_row = status_at_line(c);
    if (status_row >= 0) return @intCast(status_row);
    return if (c.tty.sy > rows) c.tty.sy - rows else 0;
}

fn format_context(c: *T.Client) format_mod.FormatContext {
    const s = c.session;
    const wl = if (s) |session| session.curw else null;
    const w = if (wl) |winlink| winlink.window else null;
    const wp = if (w) |window| window.active else null;
    return .{
        .client = c,
        .session = s,
        .winlink = wl,
        .window = w,
        .pane = wp,
    };
}

fn draw_base(screen: *T.Screen, c: *T.Client, rows: u32) void {
    const s = c.session orelse {
        clear_status_entries_from(c, 0);
        return;
    };

    var base_gc = T.grid_default_cell;
    style_mod.style_apply(&base_gc, s.options, "status-style", null);
    const fg = opts.options_get_number(s.options, "status-fg");
    if (fg != 8) base_gc.fg = @intCast(fg);
    const bg = opts.options_get_number(s.options, "status-bg");
    if (bg != 8) base_gc.bg = @intCast(bg);

    var row: u32 = 0;
    while (row < rows) : (row += 1) {
        fill_row(screen, row, &base_gc);
    }

    if (resize_mod.status_line_size(c) == 0) {
        clear_status_entries_from(c, 0);
        return;
    }

    var ctx = format_context(c);
    const formats = opts.options_get_array(s.options, "status-format");
    var left_gc = base_gc;
    var swctx = T.ScreenWriteCtx{ .s = screen };
    row = 0;
    while (row < rows) : (row += 1) {
        const row_index: usize = @intCast(row);
        if (row_index >= formats.len) break;
        const entry = &c.status.entries[row_index];
        style_mod.style_apply(&left_gc, s.options, "status-style", null);
        const expanded = format_mod.format_expand(xm.allocator, formats[row_index], &ctx);
        defer xm.allocator.free(expanded.text);
        replace_cached_status_entry(entry, expanded.text);
        entry.ranges.clearRetainingCapacity();
        screen_write.cursor_to(&swctx, row, 0);
        format_draw.format_draw_ranges(&swctx, &left_gc, screen.grid.sx, expanded.text, &entry.ranges);
    }
    clear_status_entries_from(c, row);
}

fn render_prompt(screen: *T.Screen, c: *T.Client, rows: u32, result: *RenderResult) void {
    const s = c.session orelse return;
    const message = status_prompt.status_prompt_message(c) orelse return;
    const area = message_area(c, rows);
    if (area.width == 0) return;
    const command_prompt = status_prompt.status_prompt_command_mode(c);

    var prompt_gc = T.grid_default_cell;
    const style_name = if (command_prompt) "message-command-style" else "message-style";
    style_mod.style_apply(&prompt_gc, s.options, style_name, null);
    fill_area(screen, area, &prompt_gc, message_fill_colour(s.options, style_name));

    var ctx = format_context(c);
    ctx.message_text = message;
    ctx.command_prompt = command_prompt;

    const fmt = opts.options_get_string(s.options, "message-format");
    const expanded = format_mod.format_require_complete(xm.allocator, fmt, &ctx) orelse xm.xstrdup(message);
    defer xm.allocator.free(expanded);

    var swctx = T.ScreenWriteCtx{ .s = screen };
    screen_write.cursor_to(&swctx, area.line, area.x);
    format_draw.format_draw(&swctx, &prompt_gc, area.width, expanded);

    const prefix_width = @min(format_draw.format_width(expanded), area.width);
    if (prefix_width >= area.width) {
        result.cursor_visible = true;
        result.cursor_x = area.x + area.width - 1;
        result.cursor_y = area.line;
        return;
    }

    const render_state = status_prompt.status_prompt_render_state(c, area.width - prefix_width) orelse return;
    defer xm.allocator.free(render_state.input_visible);
    screen_write.cursor_to(&swctx, area.line, area.x + prefix_width);
    format_draw.format_draw(&swctx, &prompt_gc, area.width - prefix_width, render_state.input_visible);

    result.cursor_visible = true;
    result.cursor_x = area.x + @min(prefix_width + render_state.cursor_column, area.width - 1);
    result.cursor_y = area.line;
}

fn render_message(screen: *T.Screen, c: *T.Client, rows: u32, message: []const u8) void {
    const s = c.session orelse return;
    const area = message_area(c, rows);
    if (area.width == 0) return;

    var message_gc = T.grid_default_cell;
    style_mod.style_apply(&message_gc, s.options, "message-style", null);
    fill_area(screen, area, &message_gc, message_fill_colour(s.options, "message-style"));

    var ctx = format_context(c);
    const display_message = if (status_runtime.status_message_ignore_styles(c))
        escape_message_hashes(message)
    else
        xm.xstrdup(message);
    defer xm.allocator.free(display_message);
    ctx.message_text = display_message;
    ctx.command_prompt = false;

    const fmt = opts.options_get_string(s.options, "message-format");
    const expanded = format_mod.format_require_complete(xm.allocator, fmt, &ctx) orelse xm.xstrdup(display_message);
    defer xm.allocator.free(expanded);

    var swctx = T.ScreenWriteCtx{ .s = screen };
    screen_write.cursor_to(&swctx, area.line, area.x);
    format_draw.format_draw(&swctx, &message_gc, area.width, expanded);
}

fn message_area(c: *T.Client, rows: u32) Area {
    const s = c.session orelse return .{ .x = 0, .width = c.tty.sx, .line = 0 };
    const sy = style_mod.style_from_option(s.options, "message-style");

    var width = c.tty.sx;
    if (sy) |style| {
        if (style.width >= 0) {
            const raw: u32 = @intCast(style.width);
            width = if (style.width_percentage != 0)
                (c.tty.sx * raw) / 100
            else
                raw;
        }
    }
    if (width == 0 or width > c.tty.sx) width = c.tty.sx;

    var x: u32 = 0;
    if (sy) |style| {
        x = switch (style.@"align") {
            .centre, .absolute_centre => (c.tty.sx - width) / 2,
            .right => c.tty.sx - width,
            else => 0,
        };
    }

    const line: u32 = if (resize_mod.status_line_size(c) == 0) 0 else @min(status_prompt_line_at(c), rows - 1);
    return .{ .x = x, .width = width, .line = line };
}

fn message_fill_colour(oo: *T.Options, style_name: []const u8) i32 {
    if (style_mod.style_from_option(oo, style_name)) |sy| {
        if (sy.fill != 8) return sy.fill;
        return sy.gc.bg;
    }
    return T.grid_default_cell.bg;
}

fn escape_message_hashes(message: []const u8) []u8 {
    var count: usize = 0;
    for (message) |ch| {
        if (ch == '#') count += 1;
    }

    var out: std.ArrayList(u8) = .{};
    out.ensureTotalCapacity(xm.allocator, message.len + count) catch unreachable;
    for (message) |ch| {
        if (ch == '#') out.appendAssumeCapacity('#');
        out.appendAssumeCapacity(ch);
    }
    return out.toOwnedSlice(xm.allocator) catch unreachable;
}

fn fill_row(screen: *T.Screen, row: u32, gc: *const T.GridCell) void {
    var ctx = T.ScreenWriteCtx{ .s = screen };
    screen_write.cursor_to(&ctx, row, 0);
    var col: u32 = 0;
    while (col < screen.grid.sx) : (col += 1) {
        screen_write.putCell(&ctx, gc);
    }
}

fn fill_area(screen: *T.Screen, area: Area, gc: *const T.GridCell, fill_bg: i32) void {
    var fill_gc = gc.*;
    fill_gc.bg = fill_bg;
    var ctx = T.ScreenWriteCtx{ .s = screen };
    screen_write.cursor_to(&ctx, area.line, area.x);
    var col: u32 = 0;
    while (col < area.width) : (col += 1) {
        screen_write.putCell(&ctx, &fill_gc);
    }
}

fn replace_cached_status_entry(entry: *T.StatusLineEntry, expanded: []const u8) void {
    if (entry.expanded) |old| xm.allocator.free(old);
    entry.expanded = xm.xstrdup(expanded);
}

fn clear_cached_status_entry(entry: *T.StatusLineEntry) void {
    if (entry.expanded) |old| xm.allocator.free(old);
    entry.expanded = null;
    entry.ranges.clearRetainingCapacity();
}

fn clear_status_entries_from(c: *T.Client, start: usize) void {
    var idx = start;
    while (idx < c.status.entries.len) : (idx += 1) {
        clear_cached_status_entry(&c.status.entries[idx]);
    }
}

const PromptCapture = struct {
    last: ?[]u8 = null,
};

fn capture_prompt_input(_: *T.Client, data: ?*anyopaque, text: ?[]const u8, _: bool) i32 {
    const capture: *PromptCapture = @ptrCast(@alignCast(data orelse return 1));
    if (capture.last) |last| xm.allocator.free(last);
    capture.last = if (text) |value| xm.xstrdup(value) else null;
    return 1;
}

fn free_prompt_capture(data: ?*anyopaque) void {
    const capture: *PromptCapture = @ptrCast(@alignCast(data orelse return));
    if (capture.last) |last| xm.allocator.free(last);
    xm.allocator.destroy(capture);
}

test "status render draws reduced status line and utf8 prompt overlay" {
    const env_mod = @import("environ.zig");
    const sess = @import("session.zig");
    const win_mod = @import("window.zig");

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

    const session_opts = opts.options_create(opts.global_s_options);
    const session_env = env_mod.environ_create();
    const s = sess.session_create(null, "alpha", "/", session_env, session_opts, null);
    defer sess.session_destroy(s, false, "test");

    const w = win_mod.window_create(20, 4, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    xm.allocator.free(w.name);
    w.name = xm.xstrdup("editor");
    var cause: ?[]u8 = null;
    const wl = sess.session_attach(s, w, 0, &cause).?;
    s.curw = wl;
    const wp = win_mod.window_add_pane(w, null, 20, 4);
    w.active = wp;
    wp.screen.title = xm.xstrdup("🙂 pane");

    var client = T.Client{
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{ .screen = undefined },
        .session = s,
    };
    defer env_mod.environ_free(client.environ);
    client.tty = .{ .client = &client, .sx = 20, .sy = 5 };

    const base = render(&client);
    defer if (base.payload.len != 0) xm.allocator.free(base.payload);
    try std.testing.expect(std.mem.indexOf(u8, base.payload, "[alpha]") != null);
    try std.testing.expect(std.mem.indexOf(u8, base.payload, "0:editor*") != null);
    try std.testing.expect(std.mem.indexOf(u8, base.payload, "pane") != null);
    try std.testing.expect(std.mem.indexOf(u8, base.payload, "#{") == null);

    const capture = xm.allocator.create(PromptCapture) catch unreachable;
    capture.* = .{};
    status_prompt.status_prompt_set(
        &client,
        null,
        "Name ",
        "🙂",
        capture_prompt_input,
        null,
        free_prompt_capture,
        capture,
        0,
        .command,
    );
    defer status_prompt.status_prompt_clear(&client);

    const prompt = render(&client);
    defer if (prompt.payload.len != 0) xm.allocator.free(prompt.payload);
    try std.testing.expect(std.mem.indexOf(u8, prompt.payload, "Name ") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt.payload, "🙂") != null);
    try std.testing.expect(prompt.cursor_visible);
}

test "status persists translated ranges for hit-test consumers" {
    const env_mod = @import("environ.zig");
    const sess = @import("session.zig");
    const win_mod = @import("window.zig");

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

    const session_opts = opts.options_create(opts.global_s_options);
    opts.options_set_array(session_opts, "status-format", &.{"#[range=user|hit]foo#[norange default]"});
    const session_env = env_mod.environ_create();
    const s = sess.session_create(null, "range", "/", session_env, session_opts, null);
    defer sess.session_destroy(s, false, "test");

    const w = win_mod.window_create(8, 4, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    var cause: ?[]u8 = null;
    const wl = sess.session_attach(s, w, 0, &cause).?;
    s.curw = wl;
    const wp = win_mod.window_add_pane(w, null, 8, 4);
    w.active = wp;

    var client = T.Client{
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{ .screen = undefined },
        .session = s,
    };
    defer {
        status_free(&client);
        env_mod.environ_free(client.environ);
    }
    client.tty = .{ .client = &client, .sx = 8, .sy = 5 };

    const rendered = render(&client);
    defer if (rendered.payload.len != 0) xm.allocator.free(rendered.payload);

    const range = status_get_range(&client, 1, 0) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(T.StyleRangeType.user, range.type);
    try std.testing.expectEqual(@as(u32, 0), range.start);
    try std.testing.expectEqual(@as(u32, 3), range.end);
    try std.testing.expectEqualStrings("hit", std.mem.sliceTo(&range.string, 0));
}

test "status message overlay respects multiline status rows and message-line" {
    const env_mod = @import("environ.zig");
    const sess = @import("session.zig");
    const win_mod = @import("window.zig");

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

    const session_opts = opts.options_create(opts.global_s_options);
    opts.options_set_number(session_opts, "status", 3);
    opts.options_set_number(session_opts, "message-line", 1);
    opts.options_set_array(session_opts, "status-format", &.{ "top row", "middle row", "bottom row" });

    const session_env = env_mod.environ_create();
    const s = sess.session_create(null, "multi", "/", session_env, session_opts, null);
    defer sess.session_destroy(s, false, "test");
    resize_mod.status_update_cache(s);

    const w = win_mod.window_create(20, 3, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    var cause: ?[]u8 = null;
    const wl = sess.session_attach(s, w, 0, &cause).?;
    s.curw = wl;
    const wp = win_mod.window_add_pane(w, null, 20, 3);
    w.active = wp;

    var client = T.Client{
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{ .screen = undefined },
        .session = s,
    };
    defer {
        status_runtime.status_message_clear(&client);
        status_free(&client);
        env_mod.environ_free(client.environ);
    }
    client.tty = .{ .client = &client, .sx = 20, .sy = 6 };

    status_runtime.status_message_set_text(&client, 0, false, false, true, "overlay row");
    const rendered = render(&client);
    defer if (rendered.payload.len != 0) xm.allocator.free(rendered.payload);

    try std.testing.expect(std.mem.indexOf(u8, rendered.payload, "\x1b[4;1H") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.payload, "\x1b[5;1H") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.payload, "\x1b[6;1H") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.payload, "top row") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.payload, "overlay row") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.payload, "bottom row") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.payload, "middle row") == null);
}

test "status timer reuses the shared redraw seam and suppresses overlay churn" {
    const env_mod = @import("environ.zig");
    const os_mod = @import("os/linux.zig");
    const sess = @import("session.zig");
    const win_mod = @import("window.zig");

    const old_base = proc_mod.libevent;
    proc_mod.libevent = os_mod.osdep_event_init();
    defer {
        if (proc_mod.libevent) |base| c_import.libevent.event_base_free(base);
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

    const session_opts = opts.options_create(opts.global_s_options);
    opts.options_set_number(session_opts, "status", 1);
    opts.options_set_number(session_opts, "status-interval", 15);
    const session_env = env_mod.environ_create();
    const s = sess.session_create(null, "timer", "/", session_env, session_opts, null);
    defer sess.session_destroy(s, false, "test");

    const w = win_mod.window_create(10, 2, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    var cause: ?[]u8 = null;
    const wl = sess.session_attach(s, w, 0, &cause).?;
    s.curw = wl;
    const wp = win_mod.window_add_pane(w, null, 10, 2);
    w.active = wp;

    var client = T.Client{
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{ .screen = undefined },
        .session = s,
    };
    defer {
        status_free(&client);
        env_mod.environ_free(client.environ);
    }
    client.tty = .{ .client = &client, .sx = 10, .sy = 3 };

    status_timer_start(&client);
    try std.testing.expect(client.status.timer != null);
    try std.testing.expect(client.flags & T.CLIENT_REDRAWSTATUS != 0);

    client.flags = 0;
    client.message_string = xm.xstrdup("overlay busy");
    defer {
        if (client.message_string) |message| xm.allocator.free(message);
        client.message_string = null;
    }

    status_timer_callback(-1, 0, &client);
    try std.testing.expect(client.status.timer != null);
    try std.testing.expect(client.flags & T.CLIENT_REDRAWSTATUS == 0);

    xm.allocator.free(client.message_string.?);
    client.message_string = null;

    status_timer_callback(-1, 0, &client);
    try std.testing.expect(client.flags & T.CLIENT_REDRAWSTATUS != 0);
}
