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
// Written for zmux by Greg Turner. This file is new zmux runtime work that
// sits between the reduced screen substrate and the attached client path.

//! tty-draw.zig – pane-only ANSI redraw with row caching.

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");

pub fn tty_draw_invalidate(cache: *T.ClientPaneCache) void {
    free_rows(cache);
    cache.pane_id = null;
    cache.sx = 0;
    cache.sy = 0;
    cache.cursor_x = 0;
    cache.cursor_y = 0;
    cache.valid = false;
}

pub fn tty_draw_free(cache: *T.ClientPaneCache) void {
    tty_draw_invalidate(cache);
    cache.rows.deinit(xm.allocator);
}

pub fn tty_draw_pane(
    cache: *T.ClientPaneCache,
    wp: *T.WindowPane,
    sx: u32,
    sy: u32,
) ![]u8 {
    var out: std.ArrayList(u8) = .{};
    defer out.deinit(xm.allocator);

    const full_redraw =
        !cache.valid or
        cache.pane_id != wp.id or
        cache.sx != sx or
        cache.sy != sy;

    if (full_redraw) {
        try out.appendSlice(xm.allocator, "\x1b[?25l");
        try out.appendSlice(xm.allocator, "\x1b[H\x1b[2J");
        free_rows(cache);
        cache.pane_id = wp.id;
        cache.sx = sx;
        cache.sy = sy;
        cache.valid = true;
    }

    const row_count: usize = @intCast(sy);
    if (cache.rows.items.len < row_count) {
        try cache.rows.ensureTotalCapacity(xm.allocator, row_count);
        while (cache.rows.items.len < row_count) {
            cache.rows.appendAssumeCapacity(xm.xstrdup(""));
        }
    } else if (cache.rows.items.len > row_count) {
        for (cache.rows.items[row_count..]) |row| xm.allocator.free(row);
        cache.rows.shrinkRetainingCapacity(row_count);
    }

    for (0..row_count) |row_idx| {
        const rendered = try render_row(wp.base.grid, @intCast(row_idx), sx);
        defer xm.allocator.free(rendered);

        if (full_redraw or !std.mem.eql(u8, cache.rows.items[row_idx], rendered)) {
            if (!full_redraw and out.items.len == 0) try out.appendSlice(xm.allocator, "\x1b[?25l");
            const move = try std.fmt.allocPrint(xm.allocator, "\x1b[{d};1H", .{row_idx + 1});
            defer xm.allocator.free(move);
            try out.appendSlice(xm.allocator, move);
            try out.appendSlice(xm.allocator, rendered);
            try out.appendSlice(xm.allocator, "\x1b[K");

            xm.allocator.free(cache.rows.items[row_idx]);
            cache.rows.items[row_idx] = try xm.allocator.dupe(u8, rendered);
        }
    }

    const cursor_y = @min(wp.base.cy, sy - 1);
    const cursor_x = @min(wp.base.cx, sx - 1);
    if (full_redraw or cache.cursor_x != cursor_x or cache.cursor_y != cursor_y) {
        if (!full_redraw and out.items.len == 0) try out.appendSlice(xm.allocator, "\x1b[?25l");
        const cursor = try std.fmt.allocPrint(xm.allocator, "\x1b[{d};{d}H", .{ cursor_y + 1, cursor_x + 1 });
        defer xm.allocator.free(cursor);
        try out.appendSlice(xm.allocator, cursor);
        cache.cursor_x = cursor_x;
        cache.cursor_y = cursor_y;
    }

    if (out.items.len != 0) try out.appendSlice(xm.allocator, "\x1b[?25h");
    return out.toOwnedSlice(xm.allocator);
}

fn render_row(gd: *T.Grid, row: u32, sx: u32) ![]u8 {
    var out: std.ArrayList(u8) = .{};
    defer out.deinit(xm.allocator);

    var last_style = CellStyle{};
    var have_style = false;

    for (0..sx) |col_idx| {
        const cell = cell_at(gd, row, @intCast(col_idx));
        const style = style_of(cell);
        if (!have_style or !std.meta.eql(style, last_style)) {
            const sgr = try style_to_sgr(style);
            defer xm.allocator.free(sgr);
            try out.appendSlice(xm.allocator, sgr);
            last_style = style;
            have_style = true;
        }
        try out.append(xm.allocator, ascii_of(cell));
    }

    if (have_style and !style_is_default(last_style))
        try out.appendSlice(xm.allocator, "\x1b[0m");
    return out.toOwnedSlice(xm.allocator);
}

const CellStyle = struct {
    attr: u16 = 0,
    fg: i32 = 0,
    bg: i32 = 0,
};

fn style_of(cell: T.GridCellEntry) CellStyle {
    return .{
        .attr = cell.offset_or_data.data.attr,
        .fg = cell.offset_or_data.data.fg,
        .bg = cell.offset_or_data.data.bg,
    };
}

fn style_is_default(style: CellStyle) bool {
    return style.attr == 0 and style.fg == 0 and style.bg == 0;
}

fn style_to_sgr(style: CellStyle) ![]u8 {
    if (style_is_default(style)) return xm.xstrdup("\x1b[0m");

    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(xm.allocator);
    try buf.appendSlice(xm.allocator, "\x1b[0");

    if (style.attr & T.GRID_ATTR_BRIGHT != 0) try buf.appendSlice(xm.allocator, ";1");
    if (style.attr & T.GRID_ATTR_DIM != 0) try buf.appendSlice(xm.allocator, ";2");
    if (style.attr & T.GRID_ATTR_UNDERSCORE != 0) try buf.appendSlice(xm.allocator, ";4");
    if (style.attr & T.GRID_ATTR_BLINK != 0) try buf.appendSlice(xm.allocator, ";5");
    if (style.attr & T.GRID_ATTR_REVERSE != 0) try buf.appendSlice(xm.allocator, ";7");
    if (style.attr & T.GRID_ATTR_HIDDEN != 0) try buf.appendSlice(xm.allocator, ";8");
    if (style.attr & T.GRID_ATTR_ITALICS != 0) try buf.appendSlice(xm.allocator, ";3");
    if (style.attr & T.GRID_ATTR_STRIKETHROUGH != 0) try buf.appendSlice(xm.allocator, ";9");

    if (style.fg != 0 and style.fg != 8) {
        const fg = if (style.fg < 8) 30 + style.fg else if (style.fg < 16) 90 + (style.fg - 8) else -1;
        if (fg != -1) try append_code(&buf, fg);
    }
    if (style.bg != 0 and style.bg != 8) {
        const bg = if (style.bg < 8) 40 + style.bg else if (style.bg < 16) 100 + (style.bg - 8) else -1;
        if (bg != -1) try append_code(&buf, bg);
    }

    try buf.append(xm.allocator, 'm');
    return buf.toOwnedSlice(xm.allocator);
}

fn append_code(buf: *std.ArrayList(u8), code: i32) !void {
    const text = try std.fmt.allocPrint(xm.allocator, ";{d}", .{code});
    defer xm.allocator.free(text);
    try buf.appendSlice(xm.allocator, text);
}

fn cell_at(gd: *T.Grid, row: u32, col: u32) T.GridCellEntry {
    if (row >= gd.linedata.len) return blank_cell();
    const line = gd.linedata[row];
    if (col >= line.celldata.len or col >= line.cellused) return blank_cell();
    return line.celldata[col];
}

fn ascii_of(cell: T.GridCellEntry) u8 {
    const ch = cell.offset_or_data.data.data;
    return if (ch == 0) ' ' else ch;
}

fn blank_cell() T.GridCellEntry {
    return .{
        .offset_or_data = .{
            .data = .{
                .attr = 0,
                .fg = 0,
                .bg = 0,
                .data = ' ',
            },
        },
        .flags = 0,
    };
}

fn free_rows(cache: *T.ClientPaneCache) void {
    for (cache.rows.items) |row| xm.allocator.free(row);
    cache.rows.clearRetainingCapacity();
}

test "tty_draw_pane performs full redraw then row diff" {
    const opts = @import("options.zig");
    const win = @import("window.zig");
    const pane_io = @import("pane-io.zig");

    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    win.window_init_globals(xm.allocator);

    const w = win.window_create(4, 2, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    defer {
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

    const wp = win.window_add_pane(w, null, 4, 2);
    pane_io.pane_io_feed(wp, "ab");

    var cache = T.ClientPaneCache{};
    defer tty_draw_free(&cache);

    const first = try tty_draw_pane(&cache, wp, 4, 2);
    defer xm.allocator.free(first);
    try std.testing.expect(std.mem.indexOf(u8, first, "\x1b[H\x1b[2J") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "\x1b[1;1H") != null);

    const second = try tty_draw_pane(&cache, wp, 4, 2);
    defer xm.allocator.free(second);
    try std.testing.expect(std.mem.indexOf(u8, second, "\x1b[H\x1b[2J") == null);

    pane_io.pane_io_feed(wp, "\nZ");
    const third = try tty_draw_pane(&cache, wp, 4, 2);
    defer xm.allocator.free(third);
    try std.testing.expect(std.mem.indexOf(u8, third, "\x1b[2;1H") != null);
    try std.testing.expect(std.mem.indexOf(u8, third, "Z") != null);
    try std.testing.expect(std.mem.indexOf(u8, third, "\x1b[1;1H") == null);
}

test "tty_draw_invalidate forces full redraw again" {
    const opts = @import("options.zig");
    const win = @import("window.zig");
    const pane_io = @import("pane-io.zig");

    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    win.window_init_globals(xm.allocator);

    const w = win.window_create(3, 1, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    defer {
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

    const wp = win.window_add_pane(w, null, 3, 1);
    pane_io.pane_io_feed(wp, "abc");
    var cache = T.ClientPaneCache{};
    defer tty_draw_free(&cache);

    const first = try tty_draw_pane(&cache, wp, 3, 1);
    defer xm.allocator.free(first);
    tty_draw_invalidate(&cache);
    const second = try tty_draw_pane(&cache, wp, 3, 1);
    defer xm.allocator.free(second);
    try std.testing.expect(std.mem.indexOf(u8, second, "\x1b[H\x1b[2J") != null);
}
