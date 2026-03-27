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
const format_mod = @import("format.zig");
const format_draw = @import("format-draw.zig");
const opts = @import("options.zig");
const resize_mod = @import("resize.zig");
const screen_mod = @import("screen.zig");
const screen_write = @import("screen-write.zig");
const status_prompt = @import("status-prompt.zig");
const style_mod = @import("style.zig");
const tty_draw = @import("tty-draw.zig");
const utf8 = @import("utf8.zig");
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

pub fn render(c: *T.Client) RenderResult {
    if (c.tty.sx == 0 or c.tty.sy == 0) return .{};

    const rows = overlay_rows(c);
    if (rows == 0) return .{};

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

fn overlay_rows(c: *T.Client) u32 {
    const lines = resize_mod.status_line_size(c);
    if (lines != 0) return lines;
    return if (status_prompt.status_prompt_active(c) or c.message_string != null) 1 else 0;
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
    const s = c.session orelse return;

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

    if (resize_mod.status_line_size(c) == 0) return;

    var ctx = format_context(c);
    const formats = opts.options_get_array(s.options, "status-format");
    var left_gc = base_gc;
    var swctx = T.ScreenWriteCtx{ .s = screen };
    row = 0;
    while (row < rows) : (row += 1) {
        const row_index: usize = @intCast(row);
        if (row_index >= formats.len) break;
        style_mod.style_apply(&left_gc, s.options, "status-style", null);
        const expanded = format_mod.format_expand(xm.allocator, formats[row_index], &ctx);
        defer xm.allocator.free(expanded.text);
        screen_write.cursor_to(&swctx, row, 0);
        format_draw.format_draw(&swctx, &left_gc, screen.grid.sx, expanded.text);
    }
}

fn render_prompt(screen: *T.Screen, c: *T.Client, rows: u32, result: *RenderResult) void {
    const s = c.session orelse return;
    const message = status_prompt.status_prompt_message(c) orelse return;
    const input = status_prompt.status_prompt_input(c) orelse "";
    const area = message_area(c, rows);
    if (area.width == 0) return;

    var prompt_gc = T.grid_default_cell;
    style_mod.style_apply(&prompt_gc, s.options, "message-style", null);
    fill_area(screen, area, &prompt_gc, message_fill_colour(s.options));

    var ctx = format_context(c);
    ctx.message_text = message;
    ctx.command_prompt = false;

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

    const input_visible = utf8.trimDisplay(input, .right, area.width - prefix_width);
    defer xm.allocator.free(input_visible);
    screen_write.cursor_to(&swctx, area.line, area.x + prefix_width);
    format_draw.format_draw(&swctx, &prompt_gc, area.width - prefix_width, input_visible);

    const input_width = utf8.displayWidth(input_visible);
    result.cursor_visible = true;
    result.cursor_x = area.x + @min(prefix_width + input_width, area.width - 1);
    result.cursor_y = area.line;
}

fn render_message(screen: *T.Screen, c: *T.Client, rows: u32, message: []const u8) void {
    const s = c.session orelse return;
    const area = message_area(c, rows);
    if (area.width == 0) return;

    var message_gc = T.grid_default_cell;
    style_mod.style_apply(&message_gc, s.options, "message-style", null);
    fill_area(screen, area, &message_gc, message_fill_colour(s.options));

    var ctx = format_context(c);
    ctx.message_text = message;
    ctx.command_prompt = false;

    const fmt = opts.options_get_string(s.options, "message-format");
    const expanded = format_mod.format_require_complete(xm.allocator, fmt, &ctx) orelse xm.xstrdup(message);
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

    const raw_line = @max(opts.options_get_number(s.options, "message-line"), 0);
    const line: u32 = @min(@as(u32, @intCast(raw_line)), rows - 1);
    return .{ .x = x, .width = width, .line = line };
}

fn message_fill_colour(oo: *T.Options) i32 {
    if (style_mod.style_from_option(oo, "message-style")) |sy| {
        if (sy.fill != 8) return sy.fill;
        return sy.gc.bg;
    }
    return T.grid_default_cell.bg;
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
