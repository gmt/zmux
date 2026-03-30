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

    // Track last written character for CSI REP (repeat previous character).
    if (gc.data.width > 0 and !gc.isPadding()) {
        s.last_glyph = gc.data;
        s.input_last_valid = true;
    }

    // Apply screen's current cell state (fg/bg/us/attr) to the cell.
    var merged = gc.*;
    if (gc.fg == 8) merged.fg = @intCast(s.cell_fg);
    if (gc.bg == 8) merged.bg = @intCast(s.cell_bg);
    if (gc.us == 8) merged.us = @intCast(s.cell_us);
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
    const s = ctx.s;
    s.saved_cx = s.cx;
    s.saved_cy = s.cy;
    s.saved_cell_fg = s.cell_fg;
    s.saved_cell_bg = s.cell_bg;
    s.saved_cell_us = s.cell_us;
    s.saved_cell_attr = s.cell_attr;
    s.saved_g0set = s.g0set;
    s.saved_g1set = s.g1set;
    s.saved_mode = s.mode;
}

pub fn restore_cursor(ctx: *T.ScreenWriteCtx) void {
    const s = ctx.s;
    s.cell_fg = s.saved_cell_fg;
    s.cell_bg = s.saved_cell_bg;
    s.cell_us = s.saved_cell_us;
    s.cell_attr = s.saved_cell_attr;
    s.g0set = s.saved_g0set;
    s.g1set = s.saved_g1set;
    if (s.saved_mode & T.MODE_ORIGIN != 0)
        s.mode |= T.MODE_ORIGIN
    else
        s.mode &= ~T.MODE_ORIGIN;
    if (s.grid.sx != 0) s.cx = @min(s.saved_cx, s.grid.sx - 1) else s.cx = 0;
    if (s.grid.sy != 0) s.cy = @min(s.saved_cy, s.grid.sy - 1) else s.cy = 0;
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

/// Draw a box with ACS line-drawing characters (screen_write_box).
/// Draws top border, bottom border, and vertical sides at cursor position.
/// Restores cursor to original position when done.
pub fn box_draw(ctx: *T.ScreenWriteCtx, nx: u32, ny: u32) void {
    const s = ctx.s;
    const gd = s.grid;
    if (gd.sx == 0 or gd.sy == 0) return;
    if (nx < 2 or ny < 2) return;

    const cx = s.cx;
    const cy = s.cy;

    var gc = T.grid_default_cell;
    gc.attr |= T.GRID_ATTR_CHARSET;
    gc.flags |= T.GRID_FLAG_NOPALETTE;

    // Top border: top-left corner, horizontal lines, top-right corner
    utf8.utf8_set(&gc.data, 'l'); // ACS top-left
    putCell(ctx, &gc);
    utf8.utf8_set(&gc.data, 'q'); // ACS horizontal
    var i: u32 = 1;
    while (i < nx - 1) : (i += 1) {
        putCell(ctx, &gc);
    }
    utf8.utf8_set(&gc.data, 'k'); // ACS top-right
    putCell(ctx, &gc);

    // Bottom border
    cursor_to(ctx, cy + ny - 1, cx);
    utf8.utf8_set(&gc.data, 'm'); // ACS bottom-left
    putCell(ctx, &gc);
    utf8.utf8_set(&gc.data, 'q'); // ACS horizontal
    i = 1;
    while (i < nx - 1) : (i += 1) {
        putCell(ctx, &gc);
    }
    utf8.utf8_set(&gc.data, 'j'); // ACS bottom-right
    putCell(ctx, &gc);

    // Vertical sides
    utf8.utf8_set(&gc.data, 'x'); // ACS vertical
    i = 1;
    while (i < ny - 1) : (i += 1) {
        // Left side
        cursor_to(ctx, cy + i, cx);
        putCell(ctx, &gc);
        // Right side
        cursor_to(ctx, cy + i, cx + nx - 1);
        putCell(ctx, &gc);
    }

    cursor_to(ctx, cy, cx);
}

/// Draw a horizontal line across the screen (screen_write_hline).
/// If `left` is true, use a left-join at the start; otherwise a plain horizontal.
/// If `right` is true, use a right-join at the end; otherwise a plain horizontal.
/// Restores cursor to original position when done.
pub fn hline(ctx: *T.ScreenWriteCtx, nx: u32, left: bool, right: bool) void {
    const s = ctx.s;
    if (s.grid.sx == 0 or nx == 0) return;

    const cx = s.cx;
    const cy = s.cy;

    var gc = T.grid_default_cell;
    gc.attr |= T.GRID_ATTR_CHARSET;

    // Start character: left-join or plain horizontal
    if (left) {
        utf8.utf8_set(&gc.data, 't'); // ACS left join
    } else {
        utf8.utf8_set(&gc.data, 'q'); // ACS horizontal
    }
    putCell(ctx, &gc);

    // Middle characters: plain horizontal
    utf8.utf8_set(&gc.data, 'q');
    var i: u32 = 1;
    while (i < nx - 1) : (i += 1) {
        putCell(ctx, &gc);
    }

    // End character: right-join or plain horizontal
    if (right) {
        utf8.utf8_set(&gc.data, 'u'); // ACS right join
    } else {
        utf8.utf8_set(&gc.data, 'q'); // ACS horizontal
    }
    putCell(ctx, &gc);

    cursor_to(ctx, cy, cx);
}

/// Draw a vertical line on the screen (screen_write_vline).
/// If `top` is true, use a top-join at the start; otherwise a plain vertical.
/// If `bottom` is true, use a bottom-join at the end; otherwise a plain vertical.
/// Restores cursor to original position when done.
pub fn vline(ctx: *T.ScreenWriteCtx, ny: u32, top: bool, bottom: bool) void {
    const s = ctx.s;
    if (s.grid.sy == 0 or ny == 0) return;

    const cx = s.cx;
    const cy = s.cy;

    var gc = T.grid_default_cell;
    gc.attr |= T.GRID_ATTR_CHARSET;

    // Start character: top-join or plain vertical
    if (top) {
        utf8.utf8_set(&gc.data, 'w'); // ACS top join
    } else {
        utf8.utf8_set(&gc.data, 'x'); // ACS vertical
    }
    putCell(ctx, &gc);

    // Middle characters: plain vertical
    utf8.utf8_set(&gc.data, 'x');
    var i: u32 = 1;
    while (i < ny - 1) : (i += 1) {
        cursor_to(ctx, cy + i, cx);
        putCell(ctx, &gc);
    }

    // End character: bottom-join or plain vertical
    cursor_to(ctx, cy + ny - 1, cx);
    if (bottom) {
        utf8.utf8_set(&gc.data, 'v'); // ACS bottom join
    } else {
        utf8.utf8_set(&gc.data, 'x'); // ACS vertical
    }
    putCell(ctx, &gc);

    cursor_to(ctx, cy, cx);
}

/// Force a full redraw of the pane content (screen_write_fullredraw).
/// In tmux this invokes the TTY redraw callback; zmux's reduced screen-write
/// layer has no TTY connection, so this is a no-op stub. The server-client
/// draw path handles redraws via PANE_REDRAW flags on the pane.
pub fn fullredraw(ctx: *T.ScreenWriteCtx) void {
    _ = ctx;
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

/// Origin-aware cursor positioning (screen_write_cursormove).
/// Pass null for px or py to keep the current value unchanged.
/// When `origin` is true and MODE_ORIGIN is set, py is relative to the
/// scroll region (rupper).
pub fn cursormove(ctx: *T.ScreenWriteCtx, px: ?u32, py_in: ?u32, origin: bool) void {
    const s = ctx.s;
    const gd = s.grid;
    if (gd.sx == 0 or gd.sy == 0) return;

    var py = py_in;
    if (origin and py != null and (s.mode & T.MODE_ORIGIN) != 0) {
        if (py.? > s.rlower -| s.rupper)
            py = s.rlower
        else
            py = py.? + s.rupper;
    }

    if (px) |x| {
        s.cx = @min(x, gd.sx - 1);
    }
    if (py) |y| {
        s.cy = @min(y, gd.sy - 1);
    }
}

/// Scroll-region-aware cursor up (screen_write_cursorup).
/// When the cursor is above the scroll region, movement is clamped to row 0.
/// When inside or below the region, movement is clamped to rupper.
pub fn cursorup(ctx: *T.ScreenWriteCtx, count: u32) void {
    const s = ctx.s;
    const gd = s.grid;
    if (gd.sx == 0 or gd.sy == 0) return;

    var ny: u32 = if (count == 0) 1 else count;
    var cx = s.cx;
    var cy = s.cy;

    if (cy < s.rupper) {
        if (ny > cy) ny = cy;
    } else {
        if (ny > cy - s.rupper) ny = cy - s.rupper;
    }
    if (cx == gd.sx) cx -= 1;

    cy -= ny;
    s.cx = cx;
    s.cy = cy;
}

/// Scroll-region-aware cursor down (screen_write_cursordown).
/// When the cursor is below the scroll region, movement is clamped to the
/// last screen row.  When inside or above, it is clamped to rlower.
pub fn cursordown(ctx: *T.ScreenWriteCtx, count: u32) void {
    const s = ctx.s;
    const gd = s.grid;
    if (gd.sx == 0 or gd.sy == 0) return;

    var ny: u32 = if (count == 0) 1 else count;
    var cx = s.cx;
    var cy = s.cy;

    if (cy > s.rlower) {
        const space = gd.sy -| 1 -| cy;
        if (ny > space) ny = space;
    } else {
        if (ny > s.rlower - cy) ny = s.rlower - cy;
    }
    if (cx == gd.sx) {
        cx -= 1;
    } else if (ny == 0) {
        return;
    }

    cy += ny;
    s.cx = cx;
    s.cy = cy;
}

/// Cursor right by count, clamped to the last column (screen_write_cursorright).
pub fn cursorright(ctx: *T.ScreenWriteCtx, count: u32) void {
    const s = ctx.s;
    const gd = s.grid;
    if (gd.sx == 0) return;

    var nx: u32 = if (count == 0) 1 else count;
    var cx = s.cx;

    if (nx > gd.sx - 1 -| cx) nx = gd.sx - 1 -| cx;
    if (nx == 0) return;

    cx += nx;
    s.cx = cx;
}

/// Cursor left by count, clamped to column 0 (screen_write_cursorleft).
pub fn cursorleft(ctx: *T.ScreenWriteCtx, count: u32) void {
    var nx: u32 = if (count == 0) 1 else count;
    var cx = ctx.s.cx;

    if (nx > cx) nx = cx;
    if (nx == 0) return;

    cx -= nx;
    ctx.s.cx = cx;
}

/// Write single character with grid cell style (screen_write_putc).
/// Copies `gcp`, sets the data to `ch`, then writes the cell.
pub fn putc_styled(ctx: *T.ScreenWriteCtx, gcp: *const T.GridCell, ch: u8) void {
    var gc = gcp.*;
    utf8.utf8_set(&gc.data, ch);
    putCell(ctx, &gc);
}

/// Write a string with a maximum display width, using a grid cell for
/// style (screen_write_nputs / screen_write_vnputs).
/// A non-positive `maxlen` means unlimited width.
pub fn nputs(ctx: *T.ScreenWriteCtx, maxlen: i32, gcp: *const T.GridCell, str: []const u8) void {
    var gc = gcp.*;
    var size: usize = 0;
    var decoder = utf8.Decoder.init();
    var i: usize = 0;

    while (i < str.len) {
        const ch = str[i];

        if (ch > 0x7f) {
            switch (decoder.feed(str[i..])) {
                .glyph => |step| {
                    const ud = step.glyph.payload();
                    const w: usize = ud.width;
                    if (maxlen > 0 and size + w > @as(usize, @intCast(maxlen))) {
                        while (size < @as(usize, @intCast(maxlen))) {
                            putc_styled(ctx, &gc, ' ');
                            size += 1;
                        }
                        return;
                    }
                    size += w;
                    gc.data = ud.*;
                    putCell(ctx, &gc);
                    i += step.consumed;
                },
                .invalid => |consumed| {
                    i += if (consumed == 0) 1 else consumed;
                },
                .need_more => return,
            }
            continue;
        }

        if (maxlen > 0 and size + 1 > @as(usize, @intCast(maxlen))) break;

        if (ch == 0x01) {
            gc.attr ^= T.GRID_ATTR_CHARSET;
        } else if (ch == '\n') {
            linefeed(ctx, false);
            carriage_return(ctx);
        } else if (ch == '\t' or (ch > 0x1f and ch < 0x7f)) {
            size += 1;
            putc_styled(ctx, &gc, ch);
        }
        i += 1;
    }
}

/// Fast copy from source screen to destination (screen_write_fast_copy).
/// Copies an nx-by-ny rectangle starting at (px, py) in `src` into the
/// destination screen at the current cursor position.  The cursor is
/// restored to its original position afterward.
pub fn fast_copy(ctx: *T.ScreenWriteCtx, src: *const T.Screen, px: u32, py: u32, nx: u32, ny: u32) void {
    const s = ctx.s;
    const src_gd = src.grid;
    if (nx == 0 or ny == 0) return;

    const save_cx = s.cx;
    const save_cy = s.cy;

    var yy: u32 = 0;
    while (yy < ny) : (yy += 1) {
        const src_row = py + yy;
        if (src_row >= src_gd.linedata.len) break;

        s.cx = save_cx;
        if (s.cy >= s.grid.linedata.len) break;

        const src_used = grid.line_used(src_gd, src_row);
        const dst_used = grid.line_used(s.grid, s.cy);

        var xx: u32 = 0;
        while (xx < nx) : (xx += 1) {
            const src_col = px + xx;
            if (src_col >= src_gd.sx) break;

            if (src_col >= src_used and s.cx >= dst_used) break;

            var gc: T.GridCell = undefined;
            grid.get_cell(src_gd, src_row, src_col, &gc);
            if (src_col + gc.data.width > px + nx) break;
            grid.set_cell(s.grid, s.cy, s.cx, &gc);
            s.cx += 1;
        }
        s.cy += 1;
    }

    s.cx = save_cx;
    s.cy = save_cy;
}

/// Set scroll region and reset cursor to top-left (screen_write_scrollregion).
/// This is the full tmux-compatible version; the cursor always moves to (0,0).
pub fn scrollregion(ctx: *T.ScreenWriteCtx, rupper: u32, rlower: u32) void {
    const s = ctx.s;
    const gd = s.grid;
    if (gd.sy == 0) return;

    var top = rupper;
    var bottom = rlower;
    if (top > gd.sy - 1) top = gd.sy - 1;
    if (bottom > gd.sy - 1) bottom = gd.sy - 1;
    if (top >= bottom) return;

    s.cx = 0;
    s.cy = 0;
    s.rupper = top;
    s.rlower = bottom;
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

test "screen-write box_draw draws four corners and borders with ACS charset" {
    const screen = @import("screen.zig");
    const s = screen.screen_init(6, 4, 100);
    defer {
        screen.screen_free(s);
        xm.allocator.destroy(s);
    }

    var ctx = T.ScreenWriteCtx{ .s = s };
    box_draw(&ctx, 6, 4);

    // Top-left corner should be 'l' with CHARSET attr
    var gc: T.GridCell = undefined;
    grid.get_cell(s.grid, 0, 0, &gc);
    try std.testing.expect(gc.attr & T.GRID_ATTR_CHARSET != 0);
    try std.testing.expectEqual(@as(u8, 'l'), gc.data.data[0]);

    // Top-right corner should be 'k'
    grid.get_cell(s.grid, 0, 5, &gc);
    try std.testing.expectEqual(@as(u8, 'k'), gc.data.data[0]);

    // Bottom-left corner should be 'm'
    grid.get_cell(s.grid, 3, 0, &gc);
    try std.testing.expectEqual(@as(u8, 'm'), gc.data.data[0]);

    // Bottom-right corner should be 'j'
    grid.get_cell(s.grid, 3, 5, &gc);
    try std.testing.expectEqual(@as(u8, 'j'), gc.data.data[0]);

    // Top edge middle should be 'q' (horizontal)
    grid.get_cell(s.grid, 0, 3, &gc);
    try std.testing.expectEqual(@as(u8, 'q'), gc.data.data[0]);

    // Left side should be 'x' (vertical)
    grid.get_cell(s.grid, 1, 0, &gc);
    try std.testing.expectEqual(@as(u8, 'x'), gc.data.data[0]);

    // Right side should be 'x' (vertical)
    grid.get_cell(s.grid, 2, 5, &gc);
    try std.testing.expectEqual(@as(u8, 'x'), gc.data.data[0]);

    // Cursor should be restored to original position
    try std.testing.expectEqual(@as(u32, 0), s.cx);
    try std.testing.expectEqual(@as(u32, 0), s.cy);
}

test "screen-write hline draws horizontal line with join characters" {
    const screen = @import("screen.zig");
    const s = screen.screen_init(10, 3, 100);
    defer {
        screen.screen_free(s);
        xm.allocator.destroy(s);
    }

    var ctx = T.ScreenWriteCtx{ .s = s };
    cursor_to(&ctx, 1, 1);
    hline(&ctx, 6, true, true);

    // Left join at start
    var gc: T.GridCell = undefined;
    grid.get_cell(s.grid, 1, 1, &gc);
    try std.testing.expect(gc.attr & T.GRID_ATTR_CHARSET != 0);
    try std.testing.expectEqual(@as(u8, 't'), gc.data.data[0]);

    // Horizontal in the middle
    grid.get_cell(s.grid, 1, 3, &gc);
    try std.testing.expectEqual(@as(u8, 'q'), gc.data.data[0]);

    // Right join at end
    grid.get_cell(s.grid, 1, 6, &gc);
    try std.testing.expectEqual(@as(u8, 'u'), gc.data.data[0]);

    // Cursor restored
    try std.testing.expectEqual(@as(u32, 1), s.cx);
    try std.testing.expectEqual(@as(u32, 1), s.cy);
}

test "screen-write hline without joins uses plain horizontal" {
    const screen = @import("screen.zig");
    const s = screen.screen_init(6, 1, 100);
    defer {
        screen.screen_free(s);
        xm.allocator.destroy(s);
    }

    var ctx = T.ScreenWriteCtx{ .s = s };
    hline(&ctx, 4, false, false);

    var gc: T.GridCell = undefined;
    grid.get_cell(s.grid, 0, 0, &gc);
    try std.testing.expectEqual(@as(u8, 'q'), gc.data.data[0]);

    grid.get_cell(s.grid, 0, 3, &gc);
    try std.testing.expectEqual(@as(u8, 'q'), gc.data.data[0]);
}

test "screen-write vline draws vertical line with join characters" {
    const screen = @import("screen.zig");
    const s = screen.screen_init(5, 6, 100);
    defer {
        screen.screen_free(s);
        xm.allocator.destroy(s);
    }

    var ctx = T.ScreenWriteCtx{ .s = s };
    cursor_to(&ctx, 0, 2);
    vline(&ctx, 5, true, true);

    // Top join at start
    var gc: T.GridCell = undefined;
    grid.get_cell(s.grid, 0, 2, &gc);
    try std.testing.expect(gc.attr & T.GRID_ATTR_CHARSET != 0);
    try std.testing.expectEqual(@as(u8, 'w'), gc.data.data[0]);

    // Vertical in the middle
    grid.get_cell(s.grid, 2, 2, &gc);
    try std.testing.expectEqual(@as(u8, 'x'), gc.data.data[0]);

    // Bottom join at end
    grid.get_cell(s.grid, 4, 2, &gc);
    try std.testing.expectEqual(@as(u8, 'v'), gc.data.data[0]);

    // Cursor restored
    try std.testing.expectEqual(@as(u32, 2), s.cx);
    try std.testing.expectEqual(@as(u32, 0), s.cy);
}

test "screen-write vline without joins uses plain vertical" {
    const screen = @import("screen.zig");
    const s = screen.screen_init(3, 4, 100);
    defer {
        screen.screen_free(s);
        xm.allocator.destroy(s);
    }

    var ctx = T.ScreenWriteCtx{ .s = s };
    cursor_to(&ctx, 0, 1);
    vline(&ctx, 3, false, false);

    var gc: T.GridCell = undefined;
    grid.get_cell(s.grid, 0, 1, &gc);
    try std.testing.expectEqual(@as(u8, 'x'), gc.data.data[0]);

    grid.get_cell(s.grid, 2, 1, &gc);
    try std.testing.expectEqual(@as(u8, 'x'), gc.data.data[0]);
}

test "screen-write fullredraw is a no-op that doesn't corrupt content" {
    const screen = @import("screen.zig");
    const s = screen.screen_init(3, 2, 100);
    defer {
        screen.screen_free(s);
        xm.allocator.destroy(s);
    }

    var ctx = T.ScreenWriteCtx{ .s = s };
    putn(&ctx, "abc");

    // fullredraw is a no-op stub; just verify it doesn't crash
    fullredraw(&ctx);

    // Content should be unchanged
    try std.testing.expectEqual(@as(u8, 'a'), grid.ascii_at(s.grid, 0, 0));
    try std.testing.expectEqual(@as(u8, 'b'), grid.ascii_at(s.grid, 0, 1));
    try std.testing.expectEqual(@as(u8, 'c'), grid.ascii_at(s.grid, 0, 2));
}

test "screen-write cursormove respects origin mode" {
    const screen = @import("screen.zig");
    const s = screen.screen_init(10, 10, 100);
    defer {
        screen.screen_free(s);
        xm.allocator.destroy(s);
    }

    var ctx = T.ScreenWriteCtx{ .s = s };
    s.rupper = 2;
    s.rlower = 7;

    cursormove(&ctx, 3, 1, false);
    try std.testing.expectEqual(@as(u32, 3), s.cx);
    try std.testing.expectEqual(@as(u32, 1), s.cy);

    s.mode |= T.MODE_ORIGIN;
    cursormove(&ctx, 0, 0, true);
    try std.testing.expectEqual(@as(u32, 0), s.cx);
    try std.testing.expectEqual(@as(u32, 2), s.cy);

    cursormove(&ctx, null, 3, true);
    try std.testing.expectEqual(@as(u32, 0), s.cx);
    try std.testing.expectEqual(@as(u32, 5), s.cy);
}

test "screen-write cursorup and cursordown respect scroll region" {
    const screen = @import("screen.zig");
    const s = screen.screen_init(10, 10, 100);
    defer {
        screen.screen_free(s);
        xm.allocator.destroy(s);
    }

    var ctx = T.ScreenWriteCtx{ .s = s };
    s.rupper = 2;
    s.rlower = 7;

    s.cy = 5;
    cursorup(&ctx, 10);
    try std.testing.expectEqual(@as(u32, 2), s.cy);

    s.cy = 1;
    cursorup(&ctx, 10);
    try std.testing.expectEqual(@as(u32, 0), s.cy);

    s.cy = 5;
    cursordown(&ctx, 10);
    try std.testing.expectEqual(@as(u32, 7), s.cy);

    s.cy = 8;
    cursordown(&ctx, 10);
    try std.testing.expectEqual(@as(u32, 9), s.cy);
}

test "screen-write cursorleft and cursorright clamp at edges" {
    const screen = @import("screen.zig");
    const s = screen.screen_init(10, 5, 100);
    defer {
        screen.screen_free(s);
        xm.allocator.destroy(s);
    }

    var ctx = T.ScreenWriteCtx{ .s = s };
    s.cx = 5;
    cursorright(&ctx, 100);
    try std.testing.expectEqual(@as(u32, 9), s.cx);

    cursorleft(&ctx, 100);
    try std.testing.expectEqual(@as(u32, 0), s.cx);

    cursorleft(&ctx, 0);
    try std.testing.expectEqual(@as(u32, 0), s.cx);
}

test "screen-write putc_styled writes character with cell attributes" {
    const screen = @import("screen.zig");
    const s = screen.screen_init(6, 2, 100);
    defer {
        screen.screen_free(s);
        xm.allocator.destroy(s);
    }

    var ctx = T.ScreenWriteCtx{ .s = s };
    var gc = T.grid_default_cell;
    gc.attr |= T.GRID_ATTR_BRIGHT;
    putc_styled(&ctx, &gc, 'A');

    var stored: T.GridCell = undefined;
    grid.get_cell(s.grid, 0, 0, &stored);
    try std.testing.expectEqual(@as(u8, 'A'), stored.data.data[0]);
    try std.testing.expect(stored.attr & T.GRID_ATTR_BRIGHT != 0);
}

test "screen-write nputs writes styled string with width limit" {
    const screen = @import("screen.zig");
    const s = screen.screen_init(10, 2, 100);
    defer {
        screen.screen_free(s);
        xm.allocator.destroy(s);
    }

    var ctx = T.ScreenWriteCtx{ .s = s };
    var gc = T.grid_default_cell;
    gc.attr |= T.GRID_ATTR_ITALICS;
    nputs(&ctx, 4, &gc, "Hello!");

    try std.testing.expectEqual(@as(u8, 'H'), grid.ascii_at(s.grid, 0, 0));
    try std.testing.expectEqual(@as(u8, 'e'), grid.ascii_at(s.grid, 0, 1));
    try std.testing.expectEqual(@as(u8, 'l'), grid.ascii_at(s.grid, 0, 2));
    try std.testing.expectEqual(@as(u8, 'l'), grid.ascii_at(s.grid, 0, 3));
    try std.testing.expectEqual(@as(u8, ' '), grid.ascii_at(s.grid, 0, 4));

    var stored: T.GridCell = undefined;
    grid.get_cell(s.grid, 0, 0, &stored);
    try std.testing.expect(stored.attr & T.GRID_ATTR_ITALICS != 0);
}

test "screen-write fast_copy copies cells between screens" {
    const screen = @import("screen.zig");
    const src = screen.screen_init(6, 3, 100);
    defer {
        screen.screen_free(src);
        xm.allocator.destroy(src);
    }
    const dst = screen.screen_init(6, 3, 100);
    defer {
        screen.screen_free(dst);
        xm.allocator.destroy(dst);
    }

    {
        var src_ctx = T.ScreenWriteCtx{ .s = src };
        putn(&src_ctx, "abcdef");
        cursor_to(&src_ctx, 1, 0);
        putn(&src_ctx, "ghijkl");
    }

    var dst_ctx = T.ScreenWriteCtx{ .s = dst };
    cursor_to(&dst_ctx, 0, 0);
    fast_copy(&dst_ctx, src, 2, 0, 3, 2);

    try std.testing.expectEqual(@as(u8, 'c'), grid.ascii_at(dst.grid, 0, 0));
    try std.testing.expectEqual(@as(u8, 'd'), grid.ascii_at(dst.grid, 0, 1));
    try std.testing.expectEqual(@as(u8, 'e'), grid.ascii_at(dst.grid, 0, 2));
    try std.testing.expectEqual(@as(u8, 'i'), grid.ascii_at(dst.grid, 1, 0));
    try std.testing.expectEqual(@as(u8, 'j'), grid.ascii_at(dst.grid, 1, 1));
    try std.testing.expectEqual(@as(u8, 'k'), grid.ascii_at(dst.grid, 1, 2));

    try std.testing.expectEqual(@as(u32, 0), dst.cx);
    try std.testing.expectEqual(@as(u32, 0), dst.cy);
}

test "screen-write scrollregion resets cursor to top-left" {
    const screen = @import("screen.zig");
    const s = screen.screen_init(10, 10, 100);
    defer {
        screen.screen_free(s);
        xm.allocator.destroy(s);
    }

    var ctx = T.ScreenWriteCtx{ .s = s };
    s.cx = 5;
    s.cy = 5;

    scrollregion(&ctx, 2, 7);
    try std.testing.expectEqual(@as(u32, 0), s.cx);
    try std.testing.expectEqual(@as(u32, 0), s.cy);
    try std.testing.expectEqual(@as(u32, 2), s.rupper);
    try std.testing.expectEqual(@as(u32, 7), s.rlower);
}
