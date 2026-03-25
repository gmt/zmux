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
// Ported in part from tmux/screen-write.c.
// Original copyright:
//   Copyright (c) 2009 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

//! screen-write.zig – reduced screen writer over the shared grid/screen model.

const std = @import("std");
const T = @import("types.zig");
const grid = @import("grid.zig");

pub fn putc(ctx: *T.ScreenWriteCtx, ch: u8) void {
    const s = ctx.s;
    const gd = s.grid;
    if (gd.sx == 0 or gd.sy == 0) return;

    if (s.cx >= gd.sx) newline(ctx);
    grid.set_ascii(gd, s.cy, s.cx, ch);
    if (s.cx + 1 < gd.sx) {
        s.cx += 1;
    } else {
        newline(ctx);
    }
}

pub fn putn(ctx: *T.ScreenWriteCtx, bytes: []const u8) void {
    for (bytes) |ch| putc(ctx, ch);
}

pub fn carriage_return(ctx: *T.ScreenWriteCtx) void {
    ctx.s.cx = 0;
}

pub fn backspace(ctx: *T.ScreenWriteCtx) void {
    if (ctx.s.cx > 0) ctx.s.cx -= 1;
}

pub fn tab(ctx: *T.ScreenWriteCtx) void {
    const gd = ctx.s.grid;
    const next_tab = (((ctx.s.cx / 8) + 1) * 8);
    while (ctx.s.cx < next_tab and ctx.s.cx < gd.sx) putc(ctx, ' ');
}

pub fn newline(ctx: *T.ScreenWriteCtx) void {
    const s = ctx.s;
    const gd = s.grid;
    s.cx = 0;
    if (s.cy < s.rlower and s.cy + 1 < gd.sy) {
        s.cy += 1;
        return;
    }
    const top = @min(s.rupper, gd.sy - 1);
    const bottom = @min(s.rlower, gd.sy - 1);
    grid.scroll_up(gd, top, bottom);
    s.cy = bottom;
}

pub fn cursor_left(ctx: *T.ScreenWriteCtx, count: u32) void {
    ctx.s.cx -|= count;
}

pub fn cursor_right(ctx: *T.ScreenWriteCtx, count: u32) void {
    const gd = ctx.s.grid;
    if (gd.sx == 0) return;
    ctx.s.cx = @min(ctx.s.cx + count, gd.sx - 1);
}

pub fn cursor_up(ctx: *T.ScreenWriteCtx, count: u32) void {
    ctx.s.cy -|= count;
}

pub fn cursor_down(ctx: *T.ScreenWriteCtx, count: u32) void {
    const gd = ctx.s.grid;
    if (gd.sy == 0) return;
    ctx.s.cy = @min(ctx.s.cy + count, gd.sy - 1);
}

pub fn cursor_to(ctx: *T.ScreenWriteCtx, row: u32, col: u32) void {
    const gd = ctx.s.grid;
    if (gd.sx == 0 or gd.sy == 0) return;
    ctx.s.cy = @min(row, gd.sy - 1);
    ctx.s.cx = @min(col, gd.sx - 1);
}

pub fn erase_to_eol(ctx: *T.ScreenWriteCtx) void {
    const gd = ctx.s.grid;
    if (gd.sy == 0 or ctx.s.cy >= gd.sy) return;
    grid.ensure_line_capacity(gd, ctx.s.cy);
    var col = ctx.s.cx;
    while (col < gd.sx) : (col += 1) {
        grid.set_ascii(gd, ctx.s.cy, col, ' ');
    }
    const line = &gd.linedata[ctx.s.cy];
    line.cellused = @min(line.cellused, ctx.s.cx);
}

pub fn erase_to_bol(ctx: *T.ScreenWriteCtx) void {
    const gd = ctx.s.grid;
    if (gd.sy == 0 or ctx.s.cy >= gd.sy) return;
    var col: u32 = 0;
    while (col <= ctx.s.cx and col < gd.sx) : (col += 1) {
        grid.set_ascii(gd, ctx.s.cy, col, ' ');
    }
}

pub fn erase_line(ctx: *T.ScreenWriteCtx) void {
    const gd = ctx.s.grid;
    if (gd.sy == 0 or ctx.s.cy >= gd.sy) return;
    grid.ensure_line_capacity(gd, ctx.s.cy);
    grid.clear_line(&gd.linedata[ctx.s.cy]);
}

pub fn erase_screen(ctx: *T.ScreenWriteCtx) void {
    grid.grid_reset(ctx.s.grid);
    ctx.s.cx = 0;
    ctx.s.cy = 0;
}

pub fn erase_to_screen_end(ctx: *T.ScreenWriteCtx) void {
    const gd = ctx.s.grid;
    if (gd.sy == 0) return;
    erase_to_eol(ctx);
    var row = ctx.s.cy + 1;
    while (row < gd.sy) : (row += 1) {
        grid.ensure_line_capacity(gd, row);
        grid.clear_line(&gd.linedata[row]);
    }
}

pub fn erase_to_screen_beginning(ctx: *T.ScreenWriteCtx) void {
    const gd = ctx.s.grid;
    if (gd.sy == 0) return;
    var row: u32 = 0;
    while (row < ctx.s.cy and row < gd.sy) : (row += 1) {
        grid.ensure_line_capacity(gd, row);
        grid.clear_line(&gd.linedata[row]);
    }
    erase_to_bol(ctx);
}

pub fn insert_characters(ctx: *T.ScreenWriteCtx, count: u32) void {
    const gd = ctx.s.grid;
    if (gd.sy == 0 or gd.sx == 0 or ctx.s.cy >= gd.sy or ctx.s.cx >= gd.sx) return;
    const n = @min(count, gd.sx - ctx.s.cx);
    var dest = gd.sx;
    while (dest > ctx.s.cx + n) {
        dest -= 1;
        const from = grid.ascii_at(gd, ctx.s.cy, dest - n);
        grid.set_ascii(gd, ctx.s.cy, dest, from);
    }
    var col: u32 = 0;
    while (col < n) : (col += 1) grid.set_ascii(gd, ctx.s.cy, ctx.s.cx + col, ' ');
}

pub fn delete_characters(ctx: *T.ScreenWriteCtx, count: u32) void {
    const gd = ctx.s.grid;
    if (gd.sy == 0 or gd.sx == 0 or ctx.s.cy >= gd.sy or ctx.s.cx >= gd.sx) return;
    const n = @min(count, gd.sx - ctx.s.cx);
    var col = ctx.s.cx;
    while (col + n < gd.sx) : (col += 1) {
        const from = grid.ascii_at(gd, ctx.s.cy, col + n);
        grid.set_ascii(gd, ctx.s.cy, col, from);
    }
    while (col < gd.sx) : (col += 1) grid.set_ascii(gd, ctx.s.cy, col, ' ');
}

pub fn erase_characters(ctx: *T.ScreenWriteCtx, count: u32) void {
    const gd = ctx.s.grid;
    if (gd.sy == 0 or gd.sx == 0 or ctx.s.cy >= gd.sy or ctx.s.cx >= gd.sx) return;
    const n = @min(count, gd.sx - ctx.s.cx);
    var col: u32 = 0;
    while (col < n) : (col += 1) grid.set_ascii(gd, ctx.s.cy, ctx.s.cx + col, ' ');
}

pub fn insert_lines(ctx: *T.ScreenWriteCtx, count: u32) void {
    const gd = ctx.s.grid;
    if (gd.sy == 0) return;
    const top = @min(@max(ctx.s.cy, ctx.s.rupper), gd.sy - 1);
    const bottom = @min(ctx.s.rlower, gd.sy - 1);
    grid.insert_lines(gd, top, bottom, count);
}

pub fn delete_lines(ctx: *T.ScreenWriteCtx, count: u32) void {
    const gd = ctx.s.grid;
    if (gd.sy == 0) return;
    const top = @min(@max(ctx.s.cy, ctx.s.rupper), gd.sy - 1);
    const bottom = @min(ctx.s.rlower, gd.sy - 1);
    grid.delete_lines(gd, top, bottom, count);
}

pub fn set_scroll_region(ctx: *T.ScreenWriteCtx, top: u32, bottom: u32) void {
    const gd = ctx.s.grid;
    if (gd.sy == 0) return;
    const clamped_top = @min(top, gd.sy - 1);
    const clamped_bottom = @min(bottom, gd.sy - 1);
    if (clamped_top >= clamped_bottom) {
        ctx.s.rupper = 0;
        ctx.s.rlower = gd.sy - 1;
    } else {
        ctx.s.rupper = clamped_top;
        ctx.s.rlower = clamped_bottom;
    }
}

pub fn save_cursor(ctx: *T.ScreenWriteCtx) void {
    ctx.s.saved_cx = ctx.s.cx;
    ctx.s.saved_cy = ctx.s.cy;
}

pub fn restore_cursor(ctx: *T.ScreenWriteCtx) void {
    if (ctx.s.grid.sx != 0) ctx.s.cx = @min(ctx.s.saved_cx, ctx.s.grid.sx - 1) else ctx.s.cx = 0;
    if (ctx.s.grid.sy != 0) ctx.s.cy = @min(ctx.s.saved_cy, ctx.s.grid.sy - 1) else ctx.s.cy = 0;
}

test "screen-write handles cursor movement and erase" {
    const screen = @import("screen.zig");
    const s = screen.screen_init(4, 2, 100);
    defer {
        grid.grid_free(s.grid);
        @import("xmalloc.zig").allocator.destroy(s);
    }

    var ctx = T.ScreenWriteCtx{ .s = s };
    putn(&ctx, "ab");
    carriage_return(&ctx);
    putc(&ctx, 'Z');
    try std.testing.expectEqual(@as(u8, 'Z'), grid.ascii_at(s.grid, 0, 0));
    try std.testing.expectEqual(@as(u8, 'b'), grid.ascii_at(s.grid, 0, 1));

    cursor_to(&ctx, 1, 1);
    putc(&ctx, 'x');
    erase_to_eol(&ctx);
    try std.testing.expectEqual(@as(u8, 'x'), grid.ascii_at(s.grid, 1, 1));
    try std.testing.expectEqual(@as(u8, ' '), grid.ascii_at(s.grid, 1, 2));
}

test "screen-write supports insert delete and save restore cursor" {
    const screen = @import("screen.zig");
    const s = screen.screen_init(5, 3, 100);
    defer {
        grid.grid_free(s.grid);
        @import("xmalloc.zig").allocator.destroy(s);
    }

    var ctx = T.ScreenWriteCtx{ .s = s };
    putn(&ctx, "abc");
    cursor_to(&ctx, 0, 1);
    insert_characters(&ctx, 1);
    try std.testing.expectEqual(@as(u8, 'a'), grid.ascii_at(s.grid, 0, 0));
    try std.testing.expectEqual(@as(u8, ' '), grid.ascii_at(s.grid, 0, 1));
    try std.testing.expectEqual(@as(u8, 'b'), grid.ascii_at(s.grid, 0, 2));

    delete_characters(&ctx, 1);
    try std.testing.expectEqual(@as(u8, 'b'), grid.ascii_at(s.grid, 0, 1));

    cursor_to(&ctx, 1, 2);
    save_cursor(&ctx);
    cursor_to(&ctx, 2, 4);
    restore_cursor(&ctx);
    try std.testing.expectEqual(@as(u32, 1), s.cy);
    try std.testing.expectEqual(@as(u32, 2), s.cx);
}
