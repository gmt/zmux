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
const screen_mod = @import("screen.zig");
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

    // Apply screen's current cell state (fg/bg/attr) to the cell.
    var merged = gc.*;
    if (gc.fg == 8) merged.fg = @intCast(s.cell_fg);
    if (gc.bg == 8) merged.bg = @intCast(s.cell_bg);
    merged.attr |= s.cell_attr;

    if (combineCell(ctx, &merged)) return;

    const width: u32 = merged.data.width;
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

    grid.set_cell(gd, s.cy, s.cx, &merged);
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
    const next_tab = screen_mod.screen_next_tabstop(ctx.s);
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
    if (top == 0 and bottom == gd.sy - 1)
        grid.scroll_full_screen_into_history(gd)
    else
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

pub fn preview(ctx: *T.ScreenWriteCtx, src: *const T.Screen, nx: u32, ny: u32) void {
    const dst = ctx.s;
    if (nx == 0 or ny == 0 or dst.grid.sx == 0 or dst.grid.sy == 0) return;

    const base_x = dst.cx;
    const base_y = dst.cy;

    var px: u32 = 0;
    var py: u32 = 0;
    if ((src.mode & T.MODE_CURSOR) != 0 and src.cursor_visible) {
        px = src.cx;
        if (px < nx / 3)
            px = 0
        else
            px -= nx / 3;
        if (px + nx > src.grid.sx) {
            if (nx > src.grid.sx)
                px = 0
            else
                px = src.grid.sx - nx;
        }

        py = src.cy;
        if (py < ny / 3)
            py = 0
        else
            py -= ny / 3;
        if (py + ny > src.grid.sy) {
            if (ny > src.grid.sy)
                py = 0
            else
                py = src.grid.sy - ny;
        }
    }

    var row: u32 = 0;
    while (row < ny and base_y + row < dst.grid.sy) : (row += 1) {
        cursor_to(ctx, base_y + row, base_x);

        var col: u32 = 0;
        while (col < nx and base_x + col < dst.grid.sx) : (col += 1) {
            if (py + row >= src.grid.sy or px + col >= src.grid.sx) {
                putCell(ctx, &T.grid_default_cell);
                continue;
            }

            var gc: T.GridCell = undefined;
            grid.get_cell(src.grid, py + row, px + col, &gc);
            if (gc.isPadding()) {
                putc(ctx, ' ');
                continue;
            }
            putCell(ctx, &gc);
        }
    }

    if ((src.mode & T.MODE_CURSOR) != 0 and src.cursor_visible and
        src.cx >= px and src.cx < px + nx and
        src.cy >= py and src.cy < py + ny and
        base_x + (src.cx - px) < dst.grid.sx and
        base_y + (src.cy - py) < dst.grid.sy)
    {
        var gc: T.GridCell = undefined;
        grid.get_cell(src.grid, src.cy, src.cx, &gc);
        if (!gc.isPadding()) {
            gc.attr |= T.GRID_ATTR_REVERSE;
            cursor_to(ctx, base_y + (src.cy - py), base_x + (src.cx - px));
            putCell(ctx, &gc);
        }
    }

    cursor_to(ctx, base_y, base_x);
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

// ── Functions ported from tmux screen-write.c ─────────────────────────────

/// Scroll region up by n lines (screen_write_scrollup).
pub fn scrollup(ctx: *T.ScreenWriteCtx, lines: u32) void {
    const s = ctx.s;
    const gd = s.grid;
    if (gd.sy == 0) return;
    var n = lines;
    if (n == 0) n = 1;
    const top = @min(s.rupper, gd.sy - 1);
    const bottom = @min(s.rlower, gd.sy - 1);
    if (n > bottom - top + 1) n = bottom - top + 1;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        if (top == 0 and bottom == gd.sy - 1)
            grid.scroll_full_screen_into_history(gd)
        else
            grid.scroll_up(gd, top, bottom);
    }
}

/// Scroll region down by n lines (screen_write_scrolldown).
pub fn scrolldown(ctx: *T.ScreenWriteCtx, lines: u32) void {
    const s = ctx.s;
    const gd = s.grid;
    if (gd.sy == 0) return;
    var n = lines;
    if (n == 0) n = 1;
    const top = @min(s.rupper, gd.sy - 1);
    const bottom = @min(s.rlower, gd.sy - 1);
    if (n > bottom - top + 1) n = bottom - top + 1;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        grid.scroll_down(gd, top, bottom);
    }
}

/// Line feed: move cursor down, scroll up if at bottom of scroll region.
/// Unlike newline(), this does NOT do a carriage return (screen_write_linefeed).
pub fn linefeed(ctx: *T.ScreenWriteCtx, wrapped: bool) void {
    const s = ctx.s;
    const gd = s.grid;
    if (gd.sy == 0) return;

    if (wrapped) {
        const row = @min(gd.hsize + s.cy, gd.linedata.len);
        if (row < gd.linedata.len) {
            gd.linedata[row].flags |= T.GRID_LINE_WRAPPED;
        }
    }

    if (s.cy == s.rlower) {
        const top = @min(s.rupper, gd.sy - 1);
        const bottom = @min(s.rlower, gd.sy - 1);
        if (top == 0 and bottom == gd.sy - 1)
            grid.scroll_full_screen_into_history(gd)
        else
            grid.scroll_up(gd, top, bottom);
    } else if (s.cy + 1 < gd.sy) {
        s.cy += 1;
    }
}

/// Reverse index: move cursor up, scroll down if at top of scroll region
/// (screen_write_reverseindex).
pub fn reverseindex(ctx: *T.ScreenWriteCtx) void {
    const s = ctx.s;
    const gd = s.grid;
    if (gd.sy == 0) return;

    if (s.cy == s.rupper) {
        const top = @min(s.rupper, gd.sy - 1);
        const bottom = @min(s.rlower, gd.sy - 1);
        grid.scroll_down(gd, top, bottom);
    } else if (s.cy > 0) {
        s.cy -= 1;
    }
}

/// Set mode bits on the screen (screen_write_mode_set).
pub fn mode_set(ctx: *T.ScreenWriteCtx, mode: i32) void {
    ctx.s.mode |= mode;
}

/// Clear mode bits on the screen (screen_write_mode_clear).
pub fn mode_clear(ctx: *T.ScreenWriteCtx, mode: i32) void {
    ctx.s.mode &= ~mode;
}

/// VT100 alignment test: fill every cell with 'E' (screen_write_alignmenttest).
pub fn alignmenttest(ctx: *T.ScreenWriteCtx) void {
    const s = ctx.s;
    const gd = s.grid;
    if (gd.sx == 0 or gd.sy == 0) return;

    var gc = T.grid_default_cell;
    gc.data.data[0] = 'E';
    gc.data.size = 1;
    gc.data.width = 1;
    gc.data.have = 1;

    var yy: u32 = 0;
    while (yy < gd.sy) : (yy += 1) {
        var xx: u32 = 0;
        while (xx < gd.sx) : (xx += 1) {
            grid.set_cell(gd, yy, xx, &gc);
        }
    }

    s.cx = 0;
    s.cy = 0;
    s.rupper = 0;
    s.rlower = gd.sy - 1;
}

/// Full screen reset (screen_write_reset).
pub fn reset(ctx: *T.ScreenWriteCtx) void {
    const s = ctx.s;
    const gd = s.grid;
    if (gd.sx == 0 or gd.sy == 0) return;

    screen_mod.screen_reset_tabs(s);
    s.rupper = 0;
    s.rlower = gd.sy - 1;
    s.mode = T.MODE_CURSOR | T.MODE_WRAP;
    erase_screen(ctx);
    s.cx = 0;
    s.cy = 0;
}

/// Clear scrollback history (screen_write_clearhistory).
pub fn clearhistory(ctx: *T.ScreenWriteCtx) void {
    grid.grid_clear_history(ctx.s.grid);
}

/// Clear n characters at cursor position (screen_write_clearcharacter).
pub fn clearcharacter(ctx: *T.ScreenWriteCtx, nx: u32) void {
    erase_characters(ctx, nx);
}

/// Write raw escape string to the terminal. No-op stub in zmux since we
/// don't have a TTY layer that forwards raw sequences (screen_write_rawstring).
pub fn rawstring(ctx: *T.ScreenWriteCtx, str: []const u8) void {
    _ = ctx;
    _ = str;
}

/// Set clipboard selection. No-op stub in zmux (screen_write_setselection).
pub fn setselection(ctx: *T.ScreenWriteCtx, clip: []const u8, str: []const u8) void {
    _ = ctx;
    _ = clip;
    _ = str;
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

test "screen-write preview copies a cursor-centered viewport" {
    const screen = @import("screen.zig");

    const src = screen.screen_init(8, 4, 100);
    defer {
        screen.screen_free(src);
        @import("xmalloc.zig").allocator.destroy(src);
    }
    const dst = screen.screen_init(4, 2, 100);
    defer {
        screen.screen_free(dst);
        @import("xmalloc.zig").allocator.destroy(dst);
    }

    {
        var src_ctx = T.ScreenWriteCtx{ .s = src };
        putn(&src_ctx, "abcdefgh\nijklmnop\nqrstuvwx\nyz012345");
        src.cx = 5;
        src.cy = 2;
        src.mode |= T.MODE_CURSOR;
        src.cursor_visible = true;
    }

    var dst_ctx = T.ScreenWriteCtx{ .s = dst };
    preview(&dst_ctx, src, 4, 2);

    const first = grid.string_cells(dst.grid, 0, dst.grid.sx, .{ .trim_trailing_spaces = true });
    defer xm.allocator.free(first);
    const second = grid.string_cells(dst.grid, 1, dst.grid.sx, .{ .trim_trailing_spaces = true });
    defer xm.allocator.free(second);

    try std.testing.expectEqualStrings("uvwx", first);
    try std.testing.expectEqualStrings("2345", second);
}
