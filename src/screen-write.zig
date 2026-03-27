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
const opts = @import("options.zig");
const utf8 = @import("utf8.zig");
const xm = @import("xmalloc.zig");

pub fn putc(ctx: *T.ScreenWriteCtx, ch: u8) void {
    const glyph = utf8.Glyph.fromAscii(ch);
    putGlyph(ctx, &glyph);
}

pub fn putn(ctx: *T.ScreenWriteCtx, bytes: []const u8) void {
    _ = putBytes(ctx, bytes, false);
}

pub fn putBytes(ctx: *T.ScreenWriteCtx, bytes: []const u8, keep_incomplete_tail: bool) usize {
    return putBytesMode(ctx, bytes, keep_incomplete_tail, .literal);
}

pub fn putEscapedBytes(ctx: *T.ScreenWriteCtx, bytes: []const u8, keep_incomplete_tail: bool) usize {
    return putBytesMode(ctx, bytes, keep_incomplete_tail, .escaped);
}

const ByteWriteMode = enum {
    literal,
    escaped,
};

fn putBytesMode(ctx: *T.ScreenWriteCtx, bytes: []const u8, keep_incomplete_tail: bool, mode: ByteWriteMode) usize {
    var decoder = utf8.Decoder.init();
    var i: usize = 0;

    while (i < bytes.len) {
        const ch = bytes[i];
        switch (ch) {
            '\r' => {
                carriage_return(ctx);
                i += 1;
                continue;
            },
            '\n' => {
                newline(ctx);
                i += 1;
                continue;
            },
            '\t' => {
                tab(ctx);
                i += 1;
                continue;
            },
            0x20...0x7e => {
                putc(ctx, ch);
                i += 1;
                continue;
            },
            else => {},
        }

        if (mode == .escaped and ch < 0x80) {
            putEscapedByte(ctx, ch);
            i += 1;
            continue;
        }

        if (mode == .literal and ch < ' ' and ch != 0x1b) {
            i += 1;
            continue;
        }

        switch (decoder.feed(bytes[i..])) {
            .glyph => |step| {
                putGlyph(ctx, &step.glyph);
                i += step.consumed;
            },
            .invalid => |consumed| {
                if (mode == .escaped) {
                    putEscapedByte(ctx, ch);
                    decoder.reset();
                    i += 1;
                    continue;
                }

                if (consumed == 0) {
                    i += 1;
                    continue;
                }
                i += consumed;
            },
            .need_more => {
                if (mode == .escaped and !keep_incomplete_tail) {
                    putEscapedByte(ctx, ch);
                    decoder.reset();
                    i += 1;
                    continue;
                }
                return if (keep_incomplete_tail) i else bytes.len;
            },
        }
    }

    return i;
}

fn putEscapedByte(ctx: *T.ScreenWriteCtx, byte: u8) void {
    const escaped = utf8.utf8_strvisx(&.{byte}, utf8.VIS_OCTAL | utf8.VIS_CSTYLE | utf8.VIS_NOSLASH);
    defer xm.allocator.free(escaped);
    putn(ctx, escaped);
}

pub fn putGlyph(ctx: *T.ScreenWriteCtx, glyph: *const utf8.Glyph) void {
    var gc = T.GridCell.fromPayload(glyph.payload());
    putCell(ctx, &gc);
}

pub fn putCell(ctx: *T.ScreenWriteCtx, gc: *const T.GridCell) void {
    const s = ctx.s;
    const gd = s.grid;
    if (gd.sx == 0 or gd.sy == 0) return;
    if (gc.isPadding()) return;

    if (combineCell(ctx, gc)) return;

    const width: u32 = gc.data.width;
    if (width == 0) return;

    if ((s.mode & T.MODE_WRAP) == 0 and
        width > 1 and
        (width > gd.sx or (s.cx != gd.sx and s.cx > gd.sx - width)))
        return;

    if ((s.mode & T.MODE_WRAP) != 0 and s.cx > gd.sx - width) {
        newline(ctx);
    }

    if (s.cx > gd.sx - width or s.cy >= gd.sy) return;

    var current: T.GridCell = undefined;
    grid.get_cell(gd, s.cy, s.cx, &current);
    _ = overwriteCells(ctx, &current, width);

    var xx = s.cx + 1;
    while (xx < s.cx + width and xx < gd.sx) : (xx += 1) {
        grid.set_padding(gd, s.cy, xx);
    }

    grid.set_cell(gd, s.cy, s.cx, gc);
    advanceCursorAfterWrite(ctx, @intCast(width));
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
        grid.set_cell(gd, ctx.s.cy, col, &T.grid_default_cell);
    }
    const line = &gd.linedata[ctx.s.cy];
    line.cellused = @min(line.cellused, ctx.s.cx);
}

pub fn erase_to_bol(ctx: *T.ScreenWriteCtx) void {
    const gd = ctx.s.grid;
    if (gd.sy == 0 or ctx.s.cy >= gd.sy) return;
    var col: u32 = 0;
    while (col <= ctx.s.cx and col < gd.sx) : (col += 1) {
        grid.set_cell(gd, ctx.s.cy, col, &T.grid_default_cell);
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
        var from: T.GridCell = undefined;
        grid.get_cell(gd, ctx.s.cy, dest - n, &from);
        grid.set_cell(gd, ctx.s.cy, dest, &from);
    }
    var col: u32 = 0;
    while (col < n) : (col += 1) grid.set_cell(gd, ctx.s.cy, ctx.s.cx + col, &T.grid_default_cell);
}

pub fn delete_characters(ctx: *T.ScreenWriteCtx, count: u32) void {
    const gd = ctx.s.grid;
    if (gd.sy == 0 or gd.sx == 0 or ctx.s.cy >= gd.sy or ctx.s.cx >= gd.sx) return;
    const n = @min(count, gd.sx - ctx.s.cx);
    var col = ctx.s.cx;
    while (col + n < gd.sx) : (col += 1) {
        var from: T.GridCell = undefined;
        grid.get_cell(gd, ctx.s.cy, col + n, &from);
        grid.set_cell(gd, ctx.s.cy, col, &from);
    }
    while (col < gd.sx) : (col += 1) grid.set_cell(gd, ctx.s.cy, col, &T.grid_default_cell);
}

pub fn erase_characters(ctx: *T.ScreenWriteCtx, count: u32) void {
    const gd = ctx.s.grid;
    if (gd.sy == 0 or gd.sx == 0 or ctx.s.cy >= gd.sy or ctx.s.cx >= gd.sx) return;
    const n = @min(count, gd.sx - ctx.s.cx);
    var col: u32 = 0;
    while (col < n) : (col += 1) grid.set_cell(gd, ctx.s.cy, ctx.s.cx + col, &T.grid_default_cell);
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

fn advanceCursorAfterWrite(ctx: *T.ScreenWriteCtx, width: u8) void {
    const gd = ctx.s.grid;
    const cell_width: u32 = width;
    if ((ctx.s.mode & T.MODE_WRAP) != 0) {
        if (ctx.s.cx <= gd.sx - cell_width) {
            ctx.s.cx += cell_width;
        } else {
            ctx.s.cx = gd.sx;
        }
        return;
    }

    if (ctx.s.cx + cell_width < gd.sx) {
        ctx.s.cx += cell_width;
    } else {
        ctx.s.cx = gd.sx - 1;
    }
}

fn combineCell(ctx: *T.ScreenWriteCtx, gc: *const T.GridCell) bool {
    const s = ctx.s;
    const gd = s.grid;
    const ud = &gc.data;
    var cx = s.cx;
    const cy = s.cy;

    if (utf8.utf8_is_hangul_filler(ud)) return true;

    var force_wide = false;
    var zero_width = false;
    if (utf8.utf8_is_zwj(ud)) {
        zero_width = true;
    } else if (utf8.utf8_is_vs(ud)) {
        zero_width = true;
        force_wide = opts.options_get_number(opts.global_options, "variation-selector-always-wide") != 0;
    } else if (ud.width == 0) {
        zero_width = true;
    }

    if (ud.size < 2 or cx == 0) return zero_width;

    var n: u32 = 1;
    var last: T.GridCell = undefined;
    grid.get_cell(gd, cy, cx - n, &last);
    if (cx != 1 and last.isPadding()) {
        n = 2;
        grid.get_cell(gd, cy, cx - n, &last);
    }
    if (n != @as(u32, last.data.width) or last.isPadding()) return zero_width;

    if (!zero_width) {
        switch (utf8.hanguljamo_check_state(&last.data, ud)) {
            .not_composable => return true,
            .choseong => return false,
            .composable => {},
            .not_hanguljamo => {
                if (utf8.utf8_should_combine(&last.data, ud) or utf8.utf8_should_combine(ud, &last.data)) {
                    force_wide = true;
                } else if (!utf8.utf8_has_zwj(&last.data)) {
                    return false;
                }
            },
        }
    }

    const last_size: usize = last.data.size;
    const add_size: usize = ud.size;
    if (last_size + add_size > T.UTF8_SIZE) return false;

    @memcpy(last.data.data[last_size .. last_size + add_size], ud.data[0..ud.size]);
    last.data.size += ud.size;
    last.data.have = last.data.size;

    if (last.data.width == 1 and force_wide) {
        last.data.width = 2;
        n = 2;
        cx += 1;
    } else {
        force_wide = false;
    }

    grid.set_cell(gd, cy, cx - n, &last);
    if (force_wide and cx > 0 and cx - 1 < gd.sx) {
        grid.set_padding(gd, cy, cx - 1);
    }
    s.cx = cx;
    return true;
}

fn overwriteCells(ctx: *T.ScreenWriteCtx, gc: *const T.GridCell, width: u32) bool {
    const s = ctx.s;
    const gd = s.grid;
    var done = false;

    if (gc.isPadding()) {
        var xx = s.cx;
        while (xx > 0) {
            var tmp_gc: T.GridCell = undefined;
            grid.get_cell(gd, s.cy, xx, &tmp_gc);
            if (!tmp_gc.isPadding()) break;
            grid.set_cell(gd, s.cy, xx, &T.grid_default_cell);
            xx -= 1;
        }
        grid.set_cell(gd, s.cy, xx, &T.grid_default_cell);
        done = true;
    }

    if (width != 1 or gc.data.width != 1 or gc.isPadding()) {
        var xx = s.cx + width - 1;
        while (xx + 1 < gd.sx) {
            xx += 1;
            var tmp_gc: T.GridCell = undefined;
            grid.get_cell(gd, s.cy, xx, &tmp_gc);
            if (!tmp_gc.isPadding()) break;
            if ((gc.flags & T.GRID_FLAG_TAB) != 0) {
                var blank = gc.*;
                blank.data = T.grid_default_cell.data;
                grid.set_cell(gd, s.cy, xx, &blank);
            } else {
                grid.set_cell(gd, s.cy, xx, &T.grid_default_cell);
            }
            done = true;
        }
    }

    return done;
}

test "screen-write handles cursor movement and erase" {
    const screen = @import("screen.zig");
    const s = screen.screen_init(4, 2, 100);
    defer {
        screen.screen_free(s);
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
        screen.screen_free(s);
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

test "screen-write stores wide glyphs and combines modifier cells" {
    const screen = @import("screen.zig");
    const s = screen.screen_init(6, 2, 100);
    defer {
        screen.screen_free(s);
        @import("xmalloc.zig").allocator.destroy(s);
    }

    var ctx = T.ScreenWriteCtx{ .s = s };
    putn(&ctx, "🙂");

    var stored: T.GridCell = undefined;
    grid.get_cell(s.grid, 0, 0, &stored);
    try std.testing.expectEqual(@as(u8, 2), stored.data.width);
    grid.get_cell(s.grid, 0, 1, &stored);
    try std.testing.expect(stored.isPadding());
    try std.testing.expectEqual(@as(u32, 2), s.cx);

    cursor_to(&ctx, 1, 0);
    putn(&ctx, "👋");
    putn(&ctx, "🏽");
    grid.get_cell(s.grid, 1, 0, &stored);
    try std.testing.expectEqual(@as(u8, 2), stored.data.width);
    try std.testing.expectEqual(@as(u8, 8), stored.data.size);
    grid.get_cell(s.grid, 1, 1, &stored);
    try std.testing.expect(stored.isPadding());
    try std.testing.expectEqual(@as(u32, 2), s.cx);
}

test "screen-write escaped byte path keeps utf8 glyphs but visualizes raw control and invalid bytes" {
    const screen = @import("screen.zig");
    const s = screen.screen_init(16, 2, 100);
    defer {
        screen.screen_free(s);
        @import("xmalloc.zig").allocator.destroy(s);
    }

    var ctx = T.ScreenWriteCtx{ .s = s };
    _ = putEscapedBytes(&ctx, "\x1b🙂\xc3(", false);

    const rendered = grid.string_cells(s.grid, 0, s.grid.sx, .{
        .trim_trailing_spaces = true,
    });
    defer xm.allocator.free(rendered);

    try std.testing.expectEqualStrings("\\033🙂\\303(", rendered);
}
