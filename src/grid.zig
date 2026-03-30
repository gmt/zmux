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
// Ported in part from tmux/grid.c, tmux/grid-view.c, and tmux/grid-reader.c.
// Original copyright:
//   Copyright (c) 2009 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

//! grid.zig – shared grid allocation and cell helpers.

const std = @import("std");
const colour = @import("colour.zig");
const hyperlinks = @import("hyperlinks.zig");
const T = @import("types.zig");
const utf8 = @import("utf8.zig");
const xm = @import("xmalloc.zig");

pub const WHITESPACE = "\t ";

pub const StringCellsOptions = struct {
    trim_trailing_spaces: bool = false,
    escape_sequences: bool = false,
    with_sequences: bool = false,
    include_empty_cells: bool = false,
    screen: ?*T.Screen = null,
    last_cell: ?*T.GridCell = null,
};

pub fn grid_create(sx: u32, sy: u32, hlimit: u32) *T.Grid {
    const g = xm.allocator.create(T.Grid) catch unreachable;
    const lines = xm.allocator.alloc(T.GridLine, sy) catch unreachable;
    init_lines(lines);
    g.* = .{
        .flags = if (hlimit != 0) T.GRID_HISTORY else 0,
        .sx = sx,
        .sy = sy,
        .hlimit = hlimit,
        .linedata = lines,
    };
    return g;
}

fn init_lines(lines: []T.GridLine) void {
    for (lines) |*line| line.* = .{};
}

fn resize_linedata(gd: *T.Grid, new_len: usize) void {
    const old_len = gd.linedata.len;
    gd.linedata = xm.allocator.realloc(gd.linedata, new_len) catch unreachable;
    if (new_len > old_len) init_lines(gd.linedata[old_len..new_len]);
}

fn stored_history_rows(gd: *const T.Grid) usize {
    return gd.linedata.len -| @as(usize, @intCast(gd.sy));
}

pub fn absolute_row_to_storage(gd: *const T.Grid, absolute_row: u32) ?u32 {
    const history_rows: u32 = @intCast(@min(@as(usize, @intCast(gd.hsize)), stored_history_rows(gd)));
    if (absolute_row < history_rows) return gd.sy + absolute_row;

    const visible_row = absolute_row - history_rows;
    if (visible_row >= gd.sy) return null;
    return visible_row;
}

pub fn grid_free(gd: *T.Grid) void {
    for (gd.linedata) |*line| free_line_storage(line);
    xm.allocator.free(gd.linedata);
    xm.allocator.destroy(gd);
}

pub fn grid_reset(gd: *T.Grid) void {
    for (gd.linedata) |*line| clear_line(line);
    gd.hsize = 0;
    gd.hscrolled = 0;
}

pub fn grid_clear_history(gd: *T.Grid) void {
    const history_start: usize = @intCast(gd.sy);
    const history_rows = stored_history_rows(gd);
    for (gd.linedata[history_start .. history_start + history_rows]) |*line| {
        free_line_storage(line);
    }
    if (gd.linedata.len != gd.sy) resize_linedata(gd, gd.sy);
    gd.hsize = 0;
    gd.hscrolled = 0;
}

pub fn ensure_line_capacity(gd: *T.Grid, row: u32) void {
    if (row >= gd.linedata.len) return;
    expand_line(gd, row, gd.sx, 8);
}

pub fn clear_line(line: *T.GridLine) void {
    if (line.extddata.len > 0) {
        xm.allocator.free(line.extddata);
        line.extddata = &.{};
    }
    if (line.celldata.len > 0) {
        for (line.celldata) |*cell| cell.* = cleared_entry();
    }
    line.cellused = 0;
    line.flags = 0;
    line.time = 0;
}

pub fn scroll_up(gd: *T.Grid, top: u32, bottom: u32) void {
    if (gd.linedata.len == 0 or bottom >= gd.linedata.len or top >= bottom) return;
    clear_line(&gd.linedata[top]);
    const first = gd.linedata[top];
    std.mem.copyForwards(T.GridLine, gd.linedata[top..bottom], gd.linedata[top + 1 .. bottom + 1]);
    gd.linedata[bottom] = first;
    clear_line(&gd.linedata[bottom]);
}

pub fn scroll_down(gd: *T.Grid, top: u32, bottom: u32) void {
    if (gd.linedata.len == 0 or bottom >= gd.linedata.len or top >= bottom) return;
    clear_line(&gd.linedata[bottom]);
    const last = gd.linedata[bottom];
    var row = bottom;
    while (row > top) : (row -= 1) {
        gd.linedata[row] = gd.linedata[row - 1];
    }
    gd.linedata[top] = last;
    clear_line(&gd.linedata[top]);
}

pub fn insert_lines(gd: *T.Grid, row: u32, bottom: u32, count: u32) void {
    if (gd.linedata.len == 0 or row >= gd.linedata.len or bottom >= gd.linedata.len or row > bottom) return;
    var n = @min(count, bottom - row + 1);
    while (n > 0) : (n -= 1) scroll_down(gd, row, bottom);
}

pub fn delete_lines(gd: *T.Grid, row: u32, bottom: u32, count: u32) void {
    if (gd.linedata.len == 0 or row >= gd.linedata.len or bottom >= gd.linedata.len or row > bottom) return;
    var n = @min(count, bottom - row + 1);
    while (n > 0) : (n -= 1) scroll_up(gd, row, bottom);
}

pub fn remove_history(gd: *T.Grid, count: u32) void {
    if (count == 0 or count > gd.hsize) return;

    const history_rows = stored_history_rows(gd);
    const drop = @min(@as(usize, @intCast(count)), history_rows);
    if (drop != 0) {
        const history_start: usize = @intCast(gd.sy);
        const history_end = history_start + history_rows;

        for (gd.linedata[history_start .. history_start + drop]) |*line| {
            free_line_storage(line);
        }
        if (history_rows > drop) {
            std.mem.copyForwards(
                T.GridLine,
                gd.linedata[history_start .. history_start + history_rows - drop],
                gd.linedata[history_start + drop .. history_end],
            );
        }
        resize_linedata(gd, gd.linedata.len - drop);
    }

    gd.hsize -= count;
    if (gd.hscrolled > gd.hsize) gd.hscrolled = gd.hsize;
}

pub fn scroll_full_screen_into_history(gd: *T.Grid) void {
    if (gd.sy == 0) return;
    if ((gd.flags & T.GRID_HISTORY) == 0 or gd.hlimit == 0) {
        scroll_up(gd, 0, gd.sy - 1);
        return;
    }

    if (gd.hsize >= gd.hlimit) remove_history(gd, gd.hsize - gd.hlimit + 1);

    const old_len = gd.linedata.len;
    resize_linedata(gd, old_len + 1);

    const top_line = gd.linedata[0];
    const blank_line = gd.linedata[old_len];
    if (gd.sy > 1) {
        std.mem.copyForwards(T.GridLine, gd.linedata[0 .. gd.sy - 1], gd.linedata[1..gd.sy]);
    }
    gd.linedata[gd.sy - 1] = blank_line;

    const history_index: usize = @intCast(gd.sy + gd.hsize);
    gd.linedata[history_index] = top_line;
    gd.linedata[history_index].time = std.time.timestamp();
    gd.hscrolled += 1;
    gd.hsize += 1;
}

pub fn set_ascii(gd: *T.Grid, row: u32, col: u32, ch: u8) void {
    var cell = T.grid_default_cell;
    utf8.utf8_set(&cell.data, ch);
    set_cell(gd, row, col, &cell);
}

pub fn ascii_at(gd: *T.Grid, row: u32, col: u32) u8 {
    var cell: T.GridCell = undefined;
    get_cell(gd, row, col, &cell);
    if (cell.isPadding() or cell.data.size == 0) return ' ';
    const ch = cell.data.data[0];
    return if (ch == 0) ' ' else ch;
}

pub fn get_cell(gd: *T.Grid, row: u32, col: u32, gc: *T.GridCell) void {
    if (row >= gd.linedata.len) {
        gc.* = T.grid_default_cell;
        return;
    }
    const line = &gd.linedata[row];
    if (col >= line.celldata.len) {
        gc.* = T.grid_default_cell;
        return;
    }
    get_cell_from_line(line, col, gc);
}

pub fn set_cell(gd: *T.Grid, row: u32, col: u32, gc: *const T.GridCell) void {
    if (row >= gd.linedata.len) return;

    expand_line(gd, row, col + 1, 8);
    const line = &gd.linedata[row];
    if (col + 1 > line.cellused) line.cellused = col + 1;

    store_entry(line, &line.celldata[col], gc);
}

pub fn set_padding(gd: *T.Grid, row: u32, col: u32) void {
    set_cell(gd, row, col, &T.grid_padding_cell);
}

pub fn cells_look_equal(lhs: *const T.GridCell, rhs: *const T.GridCell) bool {
    const lhs_flags = lhs.flags;
    const rhs_flags = rhs.flags;

    return lhs.fg == rhs.fg and
        lhs.bg == rhs.bg and
        lhs.attr == rhs.attr and
        (lhs_flags & ~T.GRID_FLAG_CLEARED) == (rhs_flags & ~T.GRID_FLAG_CLEARED) and
        lhs.link == rhs.link;
}

pub fn cells_equal(lhs: *const T.GridCell, rhs: *const T.GridCell) bool {
    if (!cells_look_equal(lhs, rhs)) return false;
    if (lhs.data.width != rhs.data.width) return false;
    if (lhs.data.size != rhs.data.size) return false;
    return std.mem.eql(u8, lhs.data.data[0..lhs.data.size], rhs.data.data[0..rhs.data.size]);
}

pub fn set_tab(gc: *T.GridCell, width: u8) void {
    @memset(gc.data.data[0..], 0);
    gc.flags |= T.GRID_FLAG_TAB;
    gc.flags &= ~T.GRID_FLAG_PADDING;
    gc.data.width = width;
    gc.data.size = width;
    gc.data.have = width;
    @memset(gc.data.data[0..gc.data.size], ' ');
}

pub fn line_used(gd: *T.Grid, row: u32) u32 {
    if (row >= gd.linedata.len) return 0;
    const line = gd.linedata[row];
    return @min(line.cellused, @as(u32, @intCast(line.celldata.len)));
}

pub fn line_length(gd: *T.Grid, row: u32) u32 {
    if (row >= gd.linedata.len) return 0;

    var px = @min(@as(u32, @intCast(gd.linedata[row].celldata.len)), gd.sx);
    var gc: T.GridCell = undefined;
    while (px > 0) {
        get_cell(gd, row, px - 1, &gc);
        if (gc.isPadding() or gc.data.size != 1 or gc.data.data[0] != ' ') break;
        px -= 1;
    }
    return px;
}

pub fn string_cells(gd: *T.Grid, row: u32, width: u32, options: StringCellsOptions) []u8 {
    if (row >= gd.linedata.len or width == 0) return xm.xstrdup("");

    const line = &gd.linedata[row];
    const used = if (options.include_empty_cells)
        @min(width, gd.sx)
    else
        @min(width, line.cellused);

    var out: std.ArrayList(u8) = .{};
    errdefer out.deinit(xm.allocator);
    var local_last = T.grid_default_cell;
    const last_cell = options.last_cell orelse &local_last;
    var has_link = false;

    var col: u32 = 0;
    while (col < used) : (col += 1) {
        var gc: T.GridCell = undefined;
        get_cell(gd, row, col, &gc);
        if (gc.isPadding()) continue;

        if (options.with_sequences) {
            append_rendered_sequence(&out, last_cell, &gc, options.escape_sequences, options.screen, &has_link);
            last_cell.* = gc;
        }
        append_rendered_cell_payload(&out, &gc, options.escape_sequences);
    }

    if (has_link) {
        append_hyperlink(&out, "", "", options.escape_sequences);
    }
    if (options.trim_trailing_spaces) {
        while (out.items.len > 0 and out.items[out.items.len - 1] == ' ') {
            _ = out.pop();
        }
    }

    return out.toOwnedSlice(xm.allocator) catch unreachable;
}

/// Public wrapper for resize_linedata (used by screen_resize_y).
pub fn resize_linedata_pub(gd: *T.Grid, new_len: u32) void {
    resize_linedata(gd, @intCast(new_len));
}

/// Duplicate lines from one grid to another (grid_duplicate_lines).
pub fn duplicate_lines(dst: *T.Grid, dst_start: u32, src: *T.Grid, src_start: u32, count: u32) void {
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const dst_row = dst_start + i;
        const src_row = src_start + i;
        if (dst_row >= dst.linedata.len or src_row >= src.linedata.len) break;

        // Free old destination line storage.
        free_line_storage(&dst.linedata[dst_row]);

        const src_line = &src.linedata[src_row];
        var dst_line = &dst.linedata[dst_row];

        // Copy metadata.
        dst_line.cellused = src_line.cellused;
        dst_line.flags = src_line.flags;
        dst_line.time = src_line.time;

        // Copy cell data.
        if (src_line.celldata.len > 0) {
            dst_line.celldata = xm.allocator.alloc(T.GridCellEntry, src_line.celldata.len) catch unreachable;
            @memcpy(dst_line.celldata, src_line.celldata);
        } else {
            dst_line.celldata = &.{};
        }

        // Copy extended data.
        if (src_line.extddata.len > 0) {
            dst_line.extddata = xm.allocator.alloc(T.GridExtdEntry, src_line.extddata.len) catch unreachable;
            @memcpy(dst_line.extddata, src_line.extddata);
        } else {
            dst_line.extddata = &.{};
        }
    }
}

/// Clear an area of the grid (grid_view_clear / grid_clear).
pub fn clear_area(gd: *T.Grid, row_start: u32, col_start: u32, nx: u32, ny: u32) void {
    var y: u32 = 0;
    while (y < ny) : (y += 1) {
        const row = row_start + y;
        if (row >= gd.linedata.len) break;

        const line = &gd.linedata[row];
        if (col_start == 0 and nx >= gd.sx) {
            // Clear entire line.
            clear_line(line);
        } else {
            // Clear specific columns.
            expand_line(gd, row, col_start + nx, 8);
            var x: u32 = col_start;
            while (x < col_start + nx and x < line.celldata.len) : (x += 1) {
                line.celldata[x] = cleared_entry();
            }
            if (col_start + nx >= line.cellused)
                line.cellused = col_start;
        }
    }
}

pub fn grid_in_set(gd: *T.Grid, row: u32, col: u32, set: []const u8) u32 {
    if (row >= gd.linedata.len or col >= gd.sx) return 0;

    var gc: T.GridCell = undefined;
    var tmp_gc: T.GridCell = undefined;
    get_cell(gd, row, col, &gc);

    if (std.mem.indexOfScalar(u8, set, '\t') != null) {
        if (gc.isPadding()) {
            var scan = col;
            while (scan > 0) {
                scan -= 1;
                get_cell(gd, row, scan, &tmp_gc);
                if (!tmp_gc.isPadding()) break;
            }
            if ((tmp_gc.flags & T.GRID_FLAG_TAB) != 0)
                return tmp_gc.data.width - (col - scan);
        } else if ((gc.flags & T.GRID_FLAG_TAB) != 0) {
            return gc.data.width;
        }
    }
    if (gc.isPadding()) return 0;
    return if (utf8.utf8_cstrhas(set, &gc.data)) 1 else 0;
}

pub fn grid_reader_start(gr: *T.GridReader, gd: *T.Grid, cx: u32, cy: u32) void {
    gr.* = .{
        .gd = gd,
        .cx = cx,
        .cy = cy,
    };
}

pub fn grid_reader_get_cursor(gr: *const T.GridReader, cx: *u32, cy: *u32) void {
    cx.* = gr.cx;
    cy.* = gr.cy;
}

pub fn grid_reader_line_length(gr: *const T.GridReader) u32 {
    return line_length(gr.gd, gr.cy);
}

pub fn grid_reader_cursor_right(gr: *T.GridReader, wrap: bool, all: bool) void {
    const px = if (all) gr.gd.sx else grid_reader_line_length(gr);

    if (wrap and gr.cx >= px and gr.cy < grid_reader_last_row(gr.gd)) {
        grid_reader_cursor_start_of_line(gr, false);
        grid_reader_cursor_down(gr);
    } else if (gr.cx < px) {
        gr.cx += 1;
        while (gr.cx < px) {
            var gc: T.GridCell = undefined;
            get_cell(gr.gd, gr.cy, gr.cx, &gc);
            if (!gc.isPadding()) break;
            gr.cx += 1;
        }
    }
}

pub fn grid_reader_cursor_left(gr: *T.GridReader, wrap: bool) void {
    while (gr.cx > 0) {
        var gc: T.GridCell = undefined;
        get_cell(gr.gd, gr.cy, gr.cx, &gc);
        if (!gc.isPadding()) break;
        gr.cx -= 1;
    }
    if (gr.cx == 0 and gr.cy > 0 and (wrap or grid_line_wrapped(gr.gd, gr.cy - 1))) {
        grid_reader_cursor_up(gr);
        grid_reader_cursor_end_of_line(gr, false, false);
    } else if (gr.cx > 0) {
        gr.cx -= 1;
    }
}

pub fn grid_reader_cursor_down(gr: *T.GridReader) void {
    if (gr.cy < grid_reader_last_row(gr.gd)) gr.cy += 1;
    while (gr.cx > 0) {
        var gc: T.GridCell = undefined;
        get_cell(gr.gd, gr.cy, gr.cx, &gc);
        if (!gc.isPadding()) break;
        gr.cx -= 1;
    }
}

pub fn grid_reader_cursor_up(gr: *T.GridReader) void {
    if (gr.cy > 0) gr.cy -= 1;
    while (gr.cx > 0) {
        var gc: T.GridCell = undefined;
        get_cell(gr.gd, gr.cy, gr.cx, &gc);
        if (!gc.isPadding()) break;
        gr.cx -= 1;
    }
}

pub fn grid_reader_cursor_start_of_line(gr: *T.GridReader, wrap: bool) void {
    if (wrap) {
        while (gr.cy > 0 and grid_line_wrapped(gr.gd, gr.cy - 1)) gr.cy -= 1;
    }
    gr.cx = 0;
}

pub fn grid_reader_cursor_end_of_line(gr: *T.GridReader, wrap: bool, all: bool) void {
    if (wrap) {
        const last_row = grid_reader_last_row(gr.gd);
        while (gr.cy < last_row and grid_line_wrapped(gr.gd, gr.cy)) gr.cy += 1;
    }
    gr.cx = if (all) gr.gd.sx else grid_reader_line_length(gr);
}

pub fn grid_reader_in_set(gr: *T.GridReader, set: []const u8) u32 {
    return grid_in_set(gr.gd, gr.cy, gr.cx, set);
}

pub fn grid_reader_cursor_next_word(gr: *T.GridReader, separators: []const u8) void {
    var xx: u32 = if (grid_line_wrapped(gr.gd, gr.cy)) gr.gd.sx - 1 else grid_reader_line_length(gr);
    var yy = grid_reader_last_row(gr.gd);

    if (!grid_reader_handle_wrap(gr, &xx, &yy)) return;
    if (grid_reader_in_set(gr, WHITESPACE) == 0) {
        if (grid_reader_in_set(gr, separators) != 0) {
            while (true) {
                gr.cx += 1;
                if (!grid_reader_handle_wrap(gr, &xx, &yy) or grid_reader_in_set(gr, separators) == 0 or grid_reader_in_set(gr, WHITESPACE) != 0) break;
            }
        } else {
            while (true) {
                gr.cx += 1;
                if (!grid_reader_handle_wrap(gr, &xx, &yy) or grid_reader_in_set(gr, separators) != 0 or grid_reader_in_set(gr, WHITESPACE) != 0) break;
            }
        }
    }
    while (grid_reader_handle_wrap(gr, &xx, &yy)) {
        const width = grid_reader_in_set(gr, WHITESPACE);
        if (width == 0) break;
        gr.cx += width;
    }
}

pub fn grid_reader_cursor_next_word_end(gr: *T.GridReader, separators: []const u8) void {
    var xx: u32 = if (grid_line_wrapped(gr.gd, gr.cy)) gr.gd.sx - 1 else grid_reader_line_length(gr);
    var yy = grid_reader_last_row(gr.gd);

    while (grid_reader_handle_wrap(gr, &xx, &yy)) {
        if (grid_reader_in_set(gr, WHITESPACE) != 0) {
            gr.cx += 1;
        } else if (grid_reader_in_set(gr, separators) != 0) {
            while (true) {
                gr.cx += 1;
                if (!grid_reader_handle_wrap(gr, &xx, &yy) or grid_reader_in_set(gr, separators) == 0 or grid_reader_in_set(gr, WHITESPACE) != 0) break;
            }
            return;
        } else {
            while (true) {
                gr.cx += 1;
                if (!grid_reader_handle_wrap(gr, &xx, &yy) or grid_reader_in_set(gr, WHITESPACE) != 0 or grid_reader_in_set(gr, separators) != 0) break;
            }
            return;
        }
    }
}

pub fn grid_reader_cursor_previous_word(gr: *T.GridReader, separators: []const u8, already: bool, stop_at_eol: bool) void {
    var oldx: u32 = 0;
    var oldy: u32 = 0;
    var word_is_letters = false;

    if (already or grid_reader_in_set(gr, WHITESPACE) != 0) {
        while (true) {
            if (gr.cx > 0) {
                gr.cx -= 1;
                if (grid_reader_in_set(gr, WHITESPACE) == 0) {
                    word_is_letters = grid_reader_in_set(gr, separators) == 0;
                    break;
                }
            } else {
                if (gr.cy == 0) return;
                grid_reader_cursor_up(gr);
                grid_reader_cursor_end_of_line(gr, false, false);

                if (stop_at_eol and gr.cx > 0) {
                    oldx = gr.cx;
                    gr.cx -= 1;
                    const at_eol = grid_reader_in_set(gr, WHITESPACE) != 0;
                    gr.cx = oldx;
                    if (at_eol) {
                        word_is_letters = false;
                        break;
                    }
                }
            }
        }
    } else {
        word_is_letters = grid_reader_in_set(gr, separators) == 0;
    }

    while (true) {
        oldx = gr.cx;
        oldy = gr.cy;
        if (gr.cx == 0) {
            if (gr.cy == 0 or !grid_line_wrapped(gr.gd, gr.cy - 1)) break;
            grid_reader_cursor_up(gr);
            grid_reader_cursor_end_of_line(gr, false, true);
        }
        if (gr.cx > 0) gr.cx -= 1;
        if (grid_reader_in_set(gr, WHITESPACE) != 0) break;
        if (word_is_letters == (grid_reader_in_set(gr, separators) == 0)) continue;
        break;
    }
    gr.cx = oldx;
    gr.cy = oldy;
}

pub fn grid_reader_cursor_jump(gr: *T.GridReader, jump_cell: *const T.Utf8Data) bool {
    var px = gr.cx;
    const last_row = grid_reader_last_row(gr.gd);
    var py = gr.cy;
    while (py <= last_row) : (py += 1) {
        const xx = line_length(gr.gd, py);
        while (px < xx) : (px += 1) {
            var gc: T.GridCell = undefined;
            get_cell(gr.gd, py, px, &gc);
            if (grid_reader_cell_equals_data(&gc, jump_cell)) {
                gr.cx = px;
                gr.cy = py;
                return true;
            }
        }
        if (py == last_row or !grid_line_wrapped(gr.gd, py)) return false;
        px = 0;
    }
    return false;
}

pub fn grid_reader_cursor_jump_back(gr: *T.GridReader, jump_cell: *const T.Utf8Data) bool {
    var xx = gr.cx + 1;
    var py = gr.cy + 1;
    while (py > 0) : (py -= 1) {
        var px = xx;
        while (px > 0) : (px -= 1) {
            var gc: T.GridCell = undefined;
            get_cell(gr.gd, py - 1, px - 1, &gc);
            if (grid_reader_cell_equals_data(&gc, jump_cell)) {
                gr.cx = px - 1;
                gr.cy = py - 1;
                return true;
            }
        }
        if (py == 1 or !grid_line_wrapped(gr.gd, py - 2)) return false;
        xx = line_length(gr.gd, py - 2);
    }
    return false;
}

pub fn grid_reader_cursor_back_to_indentation(gr: *T.GridReader) void {
    const oldx = gr.cx;
    const oldy = gr.cy;
    const last_row = grid_reader_last_row(gr.gd);
    grid_reader_cursor_start_of_line(gr, true);

    var py = gr.cy;
    while (py <= last_row) : (py += 1) {
        const xx = line_length(gr.gd, py);
        var px: u32 = 0;
        while (px < xx) : (px += 1) {
            var gc: T.GridCell = undefined;
            get_cell(gr.gd, py, px, &gc);
            if ((gc.data.size != 1 or gc.data.data[0] != ' ') and (gc.flags & (T.GRID_FLAG_TAB | T.GRID_FLAG_PADDING)) == 0) {
                gr.cx = px;
                gr.cy = py;
                return;
            }
        }
        if (!grid_line_wrapped(gr.gd, py)) break;
    }
    gr.cx = oldx;
    gr.cy = oldy;
}

fn grid_line_wrapped(gd: *T.Grid, row: u32) bool {
    return row < gd.linedata.len and (gd.linedata[row].flags & T.GRID_LINE_WRAPPED) != 0;
}

fn grid_reader_last_row(gd: *T.Grid) u32 {
    return if (gd.linedata.len == 0) 0 else @intCast(gd.linedata.len - 1);
}

fn grid_reader_handle_wrap(gr: *T.GridReader, xx: *u32, yy: *u32) bool {
    while (gr.cx > xx.*) {
        if (gr.cy == yy.*) return false;
        grid_reader_cursor_start_of_line(gr, false);
        grid_reader_cursor_down(gr);

        if (grid_line_wrapped(gr.gd, gr.cy))
            xx.* = gr.gd.sx - 1
        else
            xx.* = grid_reader_line_length(gr);
    }
    return true;
}

fn grid_reader_cell_equals_data(gc: *const T.GridCell, ud: *const T.Utf8Data) bool {
    if (gc.isPadding()) return false;
    if ((gc.flags & T.GRID_FLAG_TAB) != 0 and ud.size == 1 and ud.data[0] == '\t') return true;
    if (gc.data.size != ud.size) return false;
    return std.mem.eql(u8, gc.data.data[0..gc.data.size], ud.data[0..ud.size]);
}

fn free_line_storage(line: *T.GridLine) void {
    if (line.celldata.len > 0) xm.allocator.free(line.celldata);
    if (line.extddata.len > 0) xm.allocator.free(line.extddata);
    line.* = .{};
}

fn append_rendered_cell_payload(out: *std.ArrayList(u8), gc: *const T.GridCell, escape_sequences: bool) void {
    if ((gc.flags & T.GRID_FLAG_TAB) != 0) {
        out.append(xm.allocator, '\t') catch unreachable;
        return;
    }

    const bytes = gc.payload().bytes();
    if (escape_sequences and bytes.len == 1 and bytes[0] == '\\') {
        out.appendSlice(xm.allocator, "\\\\") catch unreachable;
        return;
    }

    out.appendSlice(xm.allocator, bytes) catch unreachable;
}

fn append_rendered_sequence(
    out: *std.ArrayList(u8),
    lastgc: *const T.GridCell,
    gc: *const T.GridCell,
    escape_sequences: bool,
    screen: ?*T.Screen,
    has_link: *bool,
) void {
    var attrs: [128]i32 = undefined;
    var attr_len: usize = 0;
    var last_attr = lastgc.attr;

    const attr_pairs = [_]struct { mask: u16, code: i32 }{
        .{ .mask = T.GRID_ATTR_BRIGHT, .code = 1 },
        .{ .mask = T.GRID_ATTR_DIM, .code = 2 },
        .{ .mask = T.GRID_ATTR_ITALICS, .code = 3 },
        .{ .mask = T.GRID_ATTR_UNDERSCORE, .code = 4 },
        .{ .mask = T.GRID_ATTR_BLINK, .code = 5 },
        .{ .mask = T.GRID_ATTR_REVERSE, .code = 7 },
        .{ .mask = T.GRID_ATTR_HIDDEN, .code = 8 },
        .{ .mask = T.GRID_ATTR_STRIKETHROUGH, .code = 9 },
        .{ .mask = T.GRID_ATTR_UNDERSCORE_2, .code = 42 },
        .{ .mask = T.GRID_ATTR_UNDERSCORE_3, .code = 43 },
        .{ .mask = T.GRID_ATTR_UNDERSCORE_4, .code = 44 },
        .{ .mask = T.GRID_ATTR_UNDERSCORE_5, .code = 45 },
        .{ .mask = T.GRID_ATTR_OVERLINE, .code = 53 },
    };

    for (attr_pairs) |entry| {
        if (((gc.attr & entry.mask) == 0 and (last_attr & entry.mask) != 0) or
            (lastgc.us != 8 and gc.us == 8))
        {
            attrs[attr_len] = 0;
            attr_len += 1;
            last_attr &= T.GRID_ATTR_CHARSET;
            break;
        }
    }
    for (attr_pairs) |entry| {
        if ((gc.attr & entry.mask) != 0 and (last_attr & entry.mask) == 0) {
            attrs[attr_len] = entry.code;
            attr_len += 1;
        }
    }

    if (attr_len > 0) {
        append_sgr_codes(out, attrs[0..attr_len], escape_sequences, true);
    }

    append_changed_colour_codes(out, attr_len > 0 and attrs[0] == 0, gc, lastgc, .fg, escape_sequences);
    append_changed_colour_codes(out, attr_len > 0 and attrs[0] == 0, gc, lastgc, .bg, escape_sequences);
    append_changed_colour_codes(out, attr_len > 0 and attrs[0] == 0, gc, lastgc, .us, escape_sequences);

    if ((gc.attr & T.GRID_ATTR_CHARSET) != 0 and (last_attr & T.GRID_ATTR_CHARSET) == 0) {
        append_control_byte(out, escape_sequences, 0x0e);
    }
    if ((gc.attr & T.GRID_ATTR_CHARSET) == 0 and (last_attr & T.GRID_ATTR_CHARSET) != 0) {
        append_control_byte(out, escape_sequences, 0x0f);
    }

    if (screen) |sc| {
        if (sc.hyperlinks) |hl| {
            if (lastgc.link != gc.link) {
                var uri: []const u8 = undefined;
                var id: []const u8 = undefined;
                if (hyperlinks.hyperlinks_get(hl, gc.link, &uri, &id, null)) {
                    append_hyperlink(out, id, uri, escape_sequences);
                    has_link.* = true;
                } else if (has_link.*) {
                    append_hyperlink(out, "", "", escape_sequences);
                    has_link.* = false;
                }
            }
        }
    }
}

const ColourField = enum { fg, bg, us };

fn append_changed_colour_codes(
    out: *std.ArrayList(u8),
    reset_started: bool,
    gc: *const T.GridCell,
    lastgc: *const T.GridCell,
    comptime field: ColourField,
    escape_sequences: bool,
) void {
    var newc: [8]i32 = undefined;
    var oldc: [8]i32 = undefined;
    const nnew = colour_codes(gc, field, &newc);
    if (nnew == 0) return;
    const nold = colour_codes(lastgc, field, &oldc);
    if (!reset_started and nnew == nold and std.mem.eql(i32, newc[0..nnew], oldc[0..nold])) return;
    if (reset_started and ((field == .fg and newc[0] == 39) or (field == .bg and newc[0] == 49))) return;
    append_sgr_codes(out, newc[0..nnew], escape_sequences, false);
}

fn colour_codes(gc: *const T.GridCell, comptime field: ColourField, values: *[8]i32) usize {
    const colour_value = switch (field) {
        .fg => gc.fg,
        .bg => gc.bg,
        .us => gc.us,
    };

    var len: usize = 0;
    if (colour_value & T.COLOUR_FLAG_256 != 0) {
        values[len] = switch (field) {
            .fg => 38,
            .bg => 48,
            .us => 58,
        };
        len += 1;
        values[len] = 5;
        len += 1;
        values[len] = colour_value & 0xff;
        len += 1;
        return len;
    }
    if (colour_value & T.COLOUR_FLAG_RGB != 0) {
        var r: u8 = undefined;
        var g: u8 = undefined;
        var b: u8 = undefined;
        colour.colour_split_rgb(colour_value, &r, &g, &b);
        values[len] = switch (field) {
            .fg => 38,
            .bg => 48,
            .us => 58,
        };
        len += 1;
        values[len] = 2;
        len += 1;
        values[len] = r;
        len += 1;
        values[len] = g;
        len += 1;
        values[len] = b;
        len += 1;
        return len;
    }

    switch (field) {
        .fg => switch (colour_value) {
            0...7 => {
                values[0] = colour_value + 30;
                return 1;
            },
            8 => {
                values[0] = 39;
                return 1;
            },
            90...97 => {
                values[0] = colour_value;
                return 1;
            },
            else => return 0,
        },
        .bg => switch (colour_value) {
            0...7 => {
                values[0] = colour_value + 40;
                return 1;
            },
            8 => {
                values[0] = 49;
                return 1;
            },
            90...97 => {
                values[0] = colour_value + 10;
                return 1;
            },
            else => return 0,
        },
        .us => return 0,
    }
}

fn append_sgr_codes(out: *std.ArrayList(u8), codes: []const i32, escape_sequences: bool, use_colon_notation: bool) void {
    if (codes.len == 0) return;
    append_escape_prefix(out, escape_sequences, "[");
    for (codes, 0..) |code, idx| {
        var buf: [32]u8 = undefined;
        const rendered = if (!use_colon_notation or code < 10)
            std.fmt.bufPrint(&buf, "{d}", .{code}) catch unreachable
        else
            std.fmt.bufPrint(&buf, "{d}:{d}", .{ @divTrunc(code, 10), @mod(code, 10) }) catch unreachable;
        out.appendSlice(xm.allocator, rendered) catch unreachable;
        if (idx + 1 < codes.len) out.append(xm.allocator, ';') catch unreachable;
    }
    out.append(xm.allocator, 'm') catch unreachable;
}

fn append_hyperlink(out: *std.ArrayList(u8), id: []const u8, uri: []const u8, escape_sequences: bool) void {
    append_escape_prefix(out, escape_sequences, "]8;");
    if (id.len != 0) {
        out.appendSlice(xm.allocator, "id=") catch unreachable;
        out.appendSlice(xm.allocator, id) catch unreachable;
        out.append(xm.allocator, ';') catch unreachable;
    } else {
        out.append(xm.allocator, ';') catch unreachable;
    }
    out.appendSlice(xm.allocator, uri) catch unreachable;
    append_st(out, escape_sequences);
}

fn append_escape_prefix(out: *std.ArrayList(u8), escape_sequences: bool, suffix: []const u8) void {
    if (escape_sequences)
        out.appendSlice(xm.allocator, "\\033") catch unreachable
    else
        out.append(xm.allocator, 0x1b) catch unreachable;
    out.appendSlice(xm.allocator, suffix) catch unreachable;
}

fn append_st(out: *std.ArrayList(u8), escape_sequences: bool) void {
    if (escape_sequences) {
        out.appendSlice(xm.allocator, "\\033\\\\") catch unreachable;
        return;
    }
    out.append(xm.allocator, 0x1b) catch unreachable;
    out.append(xm.allocator, '\\') catch unreachable;
}

fn append_control_byte(out: *std.ArrayList(u8), escape_sequences: bool, byte: u8) void {
    if (escape_sequences) {
        var octal: [4]u8 = undefined;
        const rendered = std.fmt.bufPrint(&octal, "\\{o:0>3}", .{byte}) catch unreachable;
        out.appendSlice(xm.allocator, rendered) catch unreachable;
        return;
    }
    out.append(xm.allocator, byte) catch unreachable;
}

fn cleared_entry() T.GridCellEntry {
    return .{
        .offset_or_data = .{
            .data = .{
                .attr = 0,
                .fg = 8,
                .bg = 8,
                .data = ' ',
            },
        },
        .flags = T.GRID_FLAG_CLEARED,
    };
}

fn colour_is_default(colour_value: i32) bool {
    return colour_value == 8 or colour_value == 9;
}

fn grow_slice(comptime Elem: type, current: []Elem, new_len: usize) []Elem {
    if (current.len == 0) return xm.allocator.alloc(Elem, new_len) catch unreachable;
    return xm.allocator.realloc(current, new_len) catch unreachable;
}

fn store_cell(entry: *T.GridCellEntry, gc: *const T.GridCell, ch: u8) void {
    var flags = gc.flags & ~(T.GRID_FLAG_CLEARED | T.GRID_FLAG_EXTENDED);

    const compact = T.GridCellEntryData{
        .attr = @truncate(gc.attr),
        .fg = @intCast(gc.fg & 0xff),
        .bg = @intCast(gc.bg & 0xff),
        .data = ch,
    };
    if ((gc.fg & T.COLOUR_FLAG_256) != 0) flags |= T.GRID_FLAG_FG256;
    if ((gc.bg & T.COLOUR_FLAG_256) != 0) flags |= T.GRID_FLAG_BG256;

    entry.* = .{
        .offset_or_data = .{ .data = compact },
        .flags = flags,
    };
}

fn need_extended_cell(entry: *const T.GridCellEntry, gc: *const T.GridCell) bool {
    if ((entry.flags & T.GRID_FLAG_EXTENDED) != 0) return true;
    if ((gc.flags & (T.GRID_FLAG_PADDING | T.GRID_FLAG_TAB)) != 0) return true;
    if (gc.attr > 0xff) return true;
    if (gc.data.size > 1 or gc.data.width > 1) return true;
    if ((gc.fg & T.COLOUR_FLAG_RGB) != 0 or (gc.bg & T.COLOUR_FLAG_RGB) != 0) return true;
    if (gc.us != 8) return true;
    if (gc.link != 0) return true;
    return false;
}

fn get_extended_slot(line: *T.GridLine, entry: *T.GridCellEntry, flags: u8) *T.GridExtdEntry {
    if ((entry.flags & T.GRID_FLAG_EXTENDED) == 0) {
        const offset = line.extddata.len;
        line.extddata = grow_slice(T.GridExtdEntry, line.extddata, offset + 1);
        line.extddata[offset] = std.mem.zeroes(T.GridExtdEntry);
        entry.offset_or_data = .{ .offset = @intCast(offset) };
        entry.flags = flags | T.GRID_FLAG_EXTENDED;
    } else {
        const offset = entry.offset_or_data.offset;
        if (offset >= line.extddata.len) {
            const old_len = line.extddata.len;
            line.extddata = grow_slice(T.GridExtdEntry, line.extddata, offset + 1);
            for (line.extddata[old_len .. offset + 1]) |*slot| slot.* = std.mem.zeroes(T.GridExtdEntry);
        }
        entry.flags = flags | T.GRID_FLAG_EXTENDED;
    }

    line.flags |= T.GRID_LINE_EXTENDED;
    return &line.extddata[entry.offset_or_data.offset];
}

fn extended_cell(line: *T.GridLine, entry: *T.GridCellEntry, gc: *const T.GridCell) void {
    const flags = gc.flags & ~(T.GRID_FLAG_CLEARED | T.GRID_FLAG_EXTENDED);
    const slot = get_extended_slot(line, entry, flags);

    var compact_data: T.utf8_char = 0;
    if ((gc.flags & T.GRID_FLAG_TAB) != 0) {
        compact_data = gc.data.width;
    } else {
        switch (utf8.utf8_from_data(&gc.data, &compact_data)) {
            .done => {},
            else => unreachable,
        }
    }

    slot.* = .{
        .data = compact_data,
        .attr = gc.attr,
        .flags = flags,
        .fg = gc.fg,
        .bg = gc.bg,
        .us = gc.us,
        .link = gc.link,
    };
}

fn store_entry(line: *T.GridLine, entry: *T.GridCellEntry, gc: *const T.GridCell) void {
    if (need_extended_cell(entry, gc)) {
        extended_cell(line, entry, gc);
        return;
    }
    store_cell(entry, gc, gc.data.data[0]);
}

fn cleared_cell_with_bg(bg: u32) T.GridCell {
    var cell = T.grid_cleared_cell;
    cell.bg = @intCast(bg);
    return cell;
}

fn expand_line(gd: *T.Grid, row: u32, wanted_cells: u32, bg: u32) void {
    const line = &gd.linedata[row];
    if (wanted_cells <= line.celldata.len) return;

    var new_len = wanted_cells;
    if (new_len < gd.sx / 4) {
        new_len = gd.sx / 4;
    } else if (new_len < gd.sx / 2) {
        new_len = gd.sx / 2;
    } else if (gd.sx > new_len) {
        new_len = gd.sx;
    }

    const old_len = line.celldata.len;
    line.celldata = grow_slice(T.GridCellEntry, line.celldata, new_len);
    for (line.celldata[old_len..]) |*entry| entry.* = cleared_entry();

    if (!colour_is_default(@intCast(bg))) {
        const blank = cleared_cell_with_bg(bg);
        for (line.celldata[old_len..]) |*entry| store_entry(line, entry, &blank);
    }
}

// ── Move/scroll/view functions (ported from tmux grid.c / grid-view.c) ────

/// Compact extended cell data in a line, removing unused slots.
fn compact_line(line: *T.GridLine) void {
    if (line.extddata.len == 0) return;

    var new_count: usize = 0;
    for (line.celldata) |entry| {
        if ((entry.flags & T.GRID_FLAG_EXTENDED) != 0)
            new_count += 1;
    }

    if (new_count == 0) {
        xm.allocator.free(line.extddata);
        line.extddata = &.{};
        return;
    }

    const new_extd = xm.allocator.alloc(T.GridExtdEntry, new_count) catch unreachable;
    var idx: usize = 0;
    for (line.celldata) |*entry| {
        if ((entry.flags & T.GRID_FLAG_EXTENDED) != 0) {
            const off = entry.offset_or_data.offset;
            if (off < line.extddata.len) {
                new_extd[idx] = line.extddata[off];
            } else {
                new_extd[idx] = std.mem.zeroes(T.GridExtdEntry);
            }
            entry.offset_or_data = .{ .offset = @intCast(idx) };
            idx += 1;
        }
    }

    xm.allocator.free(line.extddata);
    line.extddata = new_extd;
}

/// Zero a line and optionally expand with a background colour.
fn empty_line(gd: *T.Grid, py: u32, bg: u32) void {
    gd.linedata[py] = .{};
    if (!colour_is_default(@intCast(bg)))
        expand_line(gd, py, gd.sx, bg);
}

/// Clear a single cell, respecting bg colour.
fn clear_cell_bg(gd: *T.Grid, px: u32, py: u32, bg: u32) void {
    const line = &gd.linedata[py];
    if (px >= line.celldata.len) return;
    const entry = &line.celldata[px];
    entry.* = cleared_entry();
    if (!colour_is_default(@intCast(bg))) {
        var gc = T.grid_cleared_cell;
        gc.bg = @intCast(bg);
        store_entry(line, entry, &gc);
        entry.flags |= T.GRID_FLAG_CLEARED;
    }
}

/// Remove ny oldest history lines and shift remaining forward.
fn trim_history(gd: *T.Grid, ny: u32) void {
    const history_start: usize = @intCast(gd.sy);
    const n: usize = @intCast(ny);
    const hsize: usize = @intCast(gd.hsize);

    for (gd.linedata[history_start .. history_start + n]) |*line| {
        free_line_storage(line);
    }

    const remaining = hsize - n;
    if (remaining > 0) {
        std.mem.copyForwards(
            T.GridLine,
            gd.linedata[history_start .. history_start + remaining],
            gd.linedata[history_start + n .. history_start + n + remaining],
        );
    }
    const new_len: usize = @intCast(gd.sy);
    resize_linedata(gd, new_len + remaining);
}

/// Clear full lines (free and re-empty with bg).
pub fn grid_clear_lines(gd: *T.Grid, py: u32, ny: u32, bg: u32) void {
    if (ny == 0) return;
    var yy = py;
    while (yy < py + ny) : (yy += 1) {
        if (yy >= gd.linedata.len) break;
        free_line_storage(&gd.linedata[yy]);
        empty_line(gd, yy, bg);
    }
    if (py != 0 and py < gd.linedata.len)
        gd.linedata[py - 1].flags &= ~T.GRID_LINE_WRAPPED;
}

/// Clear a rectangular area with bg colour.
pub fn grid_clear(gd: *T.Grid, px: u32, py: u32, nx: u32, ny: u32, bg: u32) void {
    if (nx == 0 or ny == 0) return;
    if (px == 0 and nx == gd.sx) {
        grid_clear_lines(gd, py, ny, bg);
        return;
    }

    var yy = py;
    while (yy < py + ny) : (yy += 1) {
        if (yy >= gd.linedata.len) break;
        const line = &gd.linedata[yy];
        var sx = gd.sx;
        if (sx > @as(u32, @intCast(line.celldata.len)))
            sx = @intCast(line.celldata.len);
        var ox = nx;
        if (colour_is_default(@intCast(bg))) {
            if (px > sx) continue;
            if (px + nx > sx) ox = sx - px;
        }
        expand_line(gd, yy, px + ox, 8);
        var xx = px;
        while (xx < px + ox) : (xx += 1) {
            clear_cell_bg(gd, xx, yy, bg);
        }
    }
}

/// Move nx cells from column px to column dx on line py.
pub fn grid_move_cells(gd: *T.Grid, dx: u32, px: u32, py: u32, nx: u32, bg: u32) void {
    if (nx == 0 or px == dx) return;
    if (py >= gd.linedata.len) return;

    expand_line(gd, py, px + nx, 8);
    expand_line(gd, py, dx + nx, 8);

    const line = &gd.linedata[py];
    if (dx < px) {
        std.mem.copyForwards(
            T.GridCellEntry,
            line.celldata[dx .. dx + nx],
            line.celldata[px .. px + nx],
        );
    } else {
        std.mem.copyBackwards(
            T.GridCellEntry,
            line.celldata[dx .. dx + nx],
            line.celldata[px .. px + nx],
        );
    }
    if (dx + nx > line.cellused) line.cellused = dx + nx;

    var xx = px;
    while (xx < px + nx) : (xx += 1) {
        if (xx >= dx and xx < dx + nx) continue;
        clear_cell_bg(gd, xx, py, bg);
    }
}

/// Move ny lines from row py to row dy.
pub fn grid_move_lines(gd: *T.Grid, dy: u32, py: u32, ny: u32, bg: u32) void {
    if (ny == 0 or py == dy) return;
    if (py + ny > gd.linedata.len or dy + ny > gd.linedata.len) return;

    {
        var yy = dy;
        while (yy < dy + ny) : (yy += 1) {
            if (yy >= py and yy < py + ny) continue;
            free_line_storage(&gd.linedata[yy]);
        }
    }
    if (dy != 0)
        gd.linedata[dy - 1].flags &= ~T.GRID_LINE_WRAPPED;

    if (dy < py) {
        std.mem.copyForwards(
            T.GridLine,
            gd.linedata[dy .. dy + ny],
            gd.linedata[py .. py + ny],
        );
    } else {
        std.mem.copyBackwards(
            T.GridLine,
            gd.linedata[dy .. dy + ny],
            gd.linedata[py .. py + ny],
        );
    }

    {
        var yy = py;
        while (yy < py + ny) : (yy += 1) {
            if (yy < dy or yy >= dy + ny)
                empty_line(gd, yy, bg);
        }
    }
    if (py != 0 and (py < dy or py >= dy + ny))
        gd.linedata[py - 1].flags &= ~T.GRID_LINE_WRAPPED;
}

/// Scroll entire visible screen, moving top line into history.
pub fn grid_scroll_history(gd: *T.Grid, bg: u32) void {
    const old_len = gd.linedata.len;
    resize_linedata(gd, old_len + 1);

    const top_line = gd.linedata[0];
    if (gd.sy > 1) {
        std.mem.copyForwards(
            T.GridLine,
            gd.linedata[0 .. gd.sy - 1],
            gd.linedata[1..gd.sy],
        );
    }

    gd.linedata[gd.sy - 1] = .{};
    empty_line(gd, gd.sy - 1, bg);

    const history_idx: usize = @intCast(gd.sy + gd.hsize);
    gd.linedata[history_idx] = top_line;
    compact_line(&gd.linedata[history_idx]);
    gd.linedata[history_idx].time = std.time.timestamp();

    gd.hscrolled += 1;
    gd.hsize += 1;
}

/// Scroll a region up, moving the upper line into history.
pub fn grid_scroll_history_region(gd: *T.Grid, upper: u32, lower: u32, bg: u32) void {
    const old_len = gd.linedata.len;
    resize_linedata(gd, old_len + 1);

    const saved_line = gd.linedata[upper];
    if (lower > upper) {
        const count: usize = @intCast(lower - upper);
        std.mem.copyForwards(
            T.GridLine,
            gd.linedata[upper .. upper + count],
            gd.linedata[upper + 1 .. upper + 1 + count],
        );
    }

    gd.linedata[lower] = .{};
    empty_line(gd, lower, bg);

    const history_idx: usize = @intCast(gd.sy + gd.hsize);
    gd.linedata[history_idx] = saved_line;
    gd.linedata[history_idx].time = std.time.timestamp();

    gd.hscrolled += 1;
    gd.hsize += 1;
}

/// Compact history, trimming oldest lines when at the limit.
pub fn grid_collect_history(gd: *T.Grid, all: bool) void {
    if (gd.hsize == 0 or gd.hsize < gd.hlimit) return;

    var ny: u32 = if (all) gd.hsize - gd.hlimit else gd.hlimit / 10;
    if (ny < 1) ny = 1;
    if (ny > gd.hsize) ny = gd.hsize;

    trim_history(gd, ny);
    gd.hsize -= ny;
    if (gd.hscrolled > gd.hsize)
        gd.hscrolled = gd.hsize;
}

// ── grid_view_* functions ─────────────────────────────────────────────────

/// Clear visible area into history.
pub fn grid_view_clear_history(gd: *T.Grid, bg: u32) void {
    var last: u32 = 0;
    {
        var yy: u32 = 0;
        while (yy < gd.sy) : (yy += 1) {
            if (yy < gd.linedata.len and gd.linedata[yy].cellused != 0)
                last = yy + 1;
        }
    }
    if (last == 0) {
        grid_clear(gd, 0, 0, gd.sx, gd.sy, bg);
        return;
    }
    {
        var yy: u32 = 0;
        while (yy < last) : (yy += 1) {
            grid_collect_history(gd, false);
            grid_scroll_history(gd, bg);
        }
    }
    if (last < gd.sy)
        grid_clear(gd, 0, 0, gd.sx, gd.sy - last, bg);
    gd.hscrolled = 0;
}

/// Scroll a view region up.
pub fn grid_view_scroll_region_up(gd: *T.Grid, rupper: u32, rlower: u32, bg: u32) void {
    if ((gd.flags & T.GRID_HISTORY) != 0) {
        grid_collect_history(gd, false);
        if (rupper == 0 and rlower == gd.sy - 1)
            grid_scroll_history(gd, bg)
        else
            grid_scroll_history_region(gd, rupper, rlower, bg);
    } else {
        grid_move_lines(gd, rupper, rupper + 1, rlower - rupper, bg);
    }
}

/// Scroll a view region down.
pub fn grid_view_scroll_region_down(gd: *T.Grid, rupper: u32, rlower: u32, bg: u32) void {
    grid_move_lines(gd, rupper + 1, rupper, rlower - rupper, bg);
}

/// Insert lines at view position.
pub fn grid_view_insert_lines(gd: *T.Grid, py: u32, ny: u32, bg: u32) void {
    grid_move_lines(gd, py + ny, py, gd.sy - py - ny, bg);
}

/// Delete lines at view position.
pub fn grid_view_delete_lines(gd: *T.Grid, py: u32, ny: u32, bg: u32) void {
    grid_move_lines(gd, py, py + ny, gd.sy - py - ny, bg);
    grid_clear(gd, 0, gd.sy - ny, gd.sx, ny, bg);
}

/// Insert lines within a scroll region.
pub fn grid_view_insert_lines_region(gd: *T.Grid, rlower: u32, py: u32, ny: u32, bg: u32) void {
    const ny2 = rlower + 1 - py - ny;
    grid_move_lines(gd, rlower + 1 - ny2, py, ny2, bg);
    grid_clear(gd, 0, py + ny2, gd.sx, ny - ny2, bg);
}

/// Delete lines within a scroll region.
pub fn grid_view_delete_lines_region(gd: *T.Grid, rlower: u32, py: u32, ny: u32, bg: u32) void {
    const ny2 = rlower + 1 - py - ny;
    grid_move_lines(gd, py, py + ny, ny2, bg);
    grid_clear(gd, 0, py + ny2, gd.sx, ny - ny2, bg);
}

/// Insert cells (shift right) at view position.
pub fn grid_view_insert_cells(gd: *T.Grid, px: u32, py: u32, nx: u32, bg: u32) void {
    const sx = gd.sx;
    if (sx == 0) return;
    if (px >= sx - 1)
        grid_clear(gd, px, py, 1, 1, bg)
    else
        grid_move_cells(gd, px + nx, px, py, sx - px - nx, bg);
}

/// Delete cells (shift left) at view position.
pub fn grid_view_delete_cells(gd: *T.Grid, px: u32, py: u32, nx: u32, bg: u32) void {
    const sx = gd.sx;
    grid_move_cells(gd, px, px + nx, py, sx - px - nx, bg);
    grid_clear(gd, sx - nx, py, nx, 1, bg);
}

fn get_cell_from_line(line: *T.GridLine, col: u32, gc: *T.GridCell) void {
    const entry = &line.celldata[col];
    if ((entry.flags & T.GRID_FLAG_EXTENDED) != 0) {
        const offset = entry.offset_or_data.offset;
        if (offset >= line.extddata.len) {
            gc.* = T.grid_default_cell;
            return;
        }

        const slot = line.extddata[offset];
        gc.flags = slot.flags;
        gc.attr = slot.attr;
        gc.fg = slot.fg;
        gc.bg = slot.bg;
        gc.us = slot.us;
        gc.link = slot.link;
        if ((gc.flags & T.GRID_FLAG_TAB) != 0) {
            gc.data = T.grid_default_cell.data;
            set_tab(gc, @intCast(slot.data));
        } else {
            utf8.utf8_to_data(slot.data, &gc.data);
        }
        return;
    }

    gc.flags = entry.flags & ~(T.GRID_FLAG_FG256 | T.GRID_FLAG_BG256 | T.GRID_FLAG_EXTENDED);
    gc.attr = entry.offset_or_data.data.attr;
    gc.fg = entry.offset_or_data.data.fg;
    if ((entry.flags & T.GRID_FLAG_FG256) != 0) gc.fg |= T.COLOUR_FLAG_256;
    gc.bg = entry.offset_or_data.data.bg;
    if ((entry.flags & T.GRID_FLAG_BG256) != 0) gc.bg |= T.COLOUR_FLAG_256;
    gc.us = 8;
    gc.link = 0;
    utf8.utf8_set(&gc.data, entry.offset_or_data.data.data);
}

// ── tmux C-name wrappers (grid.c) for audit cross-reference ───────────────

pub const grid_destroy = grid_free;
pub const grid_line_length = line_length;
pub const grid_cells_look_equal = cells_look_equal;
pub const grid_cells_equal = cells_equal;
pub const grid_set_tab = set_tab;
pub const grid_duplicate_lines = duplicate_lines;
pub const grid_remove_history = remove_history;

pub fn grid_get_cell(gd: *T.Grid, px: u32, py: u32, gc: *T.GridCell) void {
    get_cell(gd, py, px, gc);
}

pub fn grid_set_cell(gd: *T.Grid, px: u32, py: u32, gc: *const T.GridCell) void {
    set_cell(gd, py, px, gc);
}

pub fn grid_set_padding(gd: *T.Grid, px: u32, py: u32) void {
    set_padding(gd, py, px);
}

pub fn grid_get_line(gd: *T.Grid, line: u32) *T.GridLine {
    return &gd.linedata[line];
}

pub fn grid_check_y(gd: *const T.Grid, from: []const u8, py: u32) i32 {
    _ = from;
    if (py >= gd.hsize + gd.sy) return -1;
    return 0;
}

pub fn grid_peek_line(gd: *const T.Grid, py: u32) ?*const T.GridLine {
    if (grid_check_y(gd, "grid_peek_line", py) != 0) return null;
    return &gd.linedata[py];
}

pub fn grid_free_line(gd: *T.Grid, py: u32) void {
    if (py >= gd.linedata.len) return;
    free_line_storage(&gd.linedata[py]);
}

pub fn grid_free_lines(gd: *T.Grid, py: u32, ny: u32) void {
    var yy = py;
    while (yy < py + ny) : (yy += 1) {
        grid_free_line(gd, yy);
    }
}

pub fn grid_clear_cell(gd: *T.Grid, px: u32, py: u32, bg: u32) void {
    clear_cell_bg(gd, px, py, bg);
}

pub fn grid_empty_line(gd: *T.Grid, py: u32, bg: u32) void {
    empty_line(gd, py, bg);
}

pub fn grid_expand_line(gd: *T.Grid, py: u32, sx: u32, bg: u32) void {
    expand_line(gd, py, sx, bg);
}

pub fn grid_compact_line(gl: *T.GridLine) void {
    compact_line(gl);
}

pub fn grid_adjust_lines(gd: *T.Grid, lines: u32) void {
    resize_linedata(gd, @intCast(lines));
}

pub fn grid_trim_history(gd: *T.Grid, ny: u32) void {
    trim_history(gd, ny);
}

pub fn grid_store_cell(gce: *T.GridCellEntry, gc: *const T.GridCell, ch: u8) void {
    store_cell(gce, gc, ch);
}

pub fn grid_need_extended_cell(gce: *const T.GridCellEntry, gc: *const T.GridCell) bool {
    return need_extended_cell(gce, gc);
}

pub fn grid_get_extended_cell(gl: *T.GridLine, gce: *T.GridCellEntry, flags: u8) *T.GridExtdEntry {
    return get_extended_slot(gl, gce, flags);
}

pub fn grid_extended_cell(gl: *T.GridLine, gce: *T.GridCellEntry, gc: *const T.GridCell) *T.GridExtdEntry {
    extended_cell(gl, gce, gc);
    return &gl.extddata[gce.offset_or_data.offset];
}

pub fn grid_get_cell1(gl: *T.GridLine, px: u32, gc: *T.GridCell) void {
    get_cell_from_line(gl, px, gc);
}

pub fn grid_compare(ga: *const T.Grid, gb: *const T.Grid) i32 {
    if (ga.sx != gb.sx or ga.sy != gb.sy) return 1;
    var yy: u32 = 0;
    while (yy < ga.sy) : (yy += 1) {
        const gla = &ga.linedata[yy];
        const glb = &gb.linedata[yy];
        if (gla.celldata.len != glb.celldata.len) return 1;
        var xx: u32 = 0;
        const w: u32 = @intCast(gla.celldata.len);
        while (xx < w) : (xx += 1) {
            var gca: T.GridCell = undefined;
            var gcb: T.GridCell = undefined;
            get_cell(ga, yy, xx, &gca);
            get_cell(gb, yy, xx, &gcb);
            if (!cells_equal(&gca, &gcb)) return 1;
        }
    }
    return 0;
}

/// tmux `grid_string_cells` (flags / lastgc / screen) — stub; use `string_cells` for Zig callers.
pub fn grid_string_cells(
    _: *T.Grid,
    _: u32,
    _: u32,
    _: u32,
    _: ?*?*T.GridCell,
    _: i32,
    _: ?*T.Screen,
) []u8 {
    return xm.xstrdup("");
}

pub fn grid_string_cells_fg(_: *const T.GridCell, _: []i32) usize {
    return 0;
}

pub fn grid_string_cells_bg(_: *const T.GridCell, _: []i32) usize {
    return 0;
}

pub fn grid_string_cells_us(_: *const T.GridCell, _: []i32) usize {
    return 0;
}

pub fn grid_string_cells_code(
    _: *const T.GridCell,
    _: *const T.GridCell,
    _: []u8,
    _: usize,
    _: u32,
    _: ?*T.Screen,
    _: *bool,
) void {}

// ── Grid reflow (ported from tmux grid.c lines 1220-1612) ─────────────────
//
// The zmux grid stores linedata as [visible | history] while tmux C uses
// [history | visible].  grid_reflow temporarily rearranges to C layout so
// that contiguous-index arithmetic in the join/split helpers works
// unchanged, then rearranges back.  grid_wrap_position / grid_unwrap_position
// translate absolute (C-style) row indices to storage indices on the fly.

fn reflow_abs_to_storage(gd: *const T.Grid, abs: u32) usize {
    if (abs < gd.hsize) return @as(usize, gd.sy) + @as(usize, abs);
    return @as(usize, abs - gd.hsize);
}

fn rearrange_to_c_layout(gd: *T.Grid) void {
    const sy: usize = gd.sy;
    const hsize: usize = gd.hsize;
    if (hsize == 0 or sy == 0) return;
    const total = sy + hsize;
    if (gd.linedata.len < total) return;
    const tmp = xm.allocator.alloc(T.GridLine, total) catch unreachable;
    @memcpy(tmp[0..hsize], gd.linedata[sy .. sy + hsize]);
    @memcpy(tmp[hsize..total], gd.linedata[0..sy]);
    @memcpy(gd.linedata[0..total], tmp[0..total]);
    xm.allocator.free(tmp);
}

fn rearrange_to_zmux_layout(gd: *T.Grid) void {
    const sy: usize = gd.sy;
    const hsize: usize = gd.hsize;
    if (hsize == 0 or sy == 0) return;
    const total = sy + hsize;
    if (gd.linedata.len < total) return;
    const tmp = xm.allocator.alloc(T.GridLine, total) catch unreachable;
    @memcpy(tmp[0..sy], gd.linedata[hsize .. hsize + sy]);
    @memcpy(tmp[sy..total], gd.linedata[0..hsize]);
    @memcpy(gd.linedata[0..total], tmp[0..total]);
    xm.allocator.free(tmp);
}

pub fn grid_reflow_dead(gl: *T.GridLine) void {
    gl.* = .{};
    gl.flags = T.GRID_LINE_DEAD;
}

pub fn grid_reflow_add(gd: *T.Grid, n: u32) *T.GridLine {
    const old_sy = gd.sy;
    const new_sy = old_sy + n;
    resize_linedata(gd, new_sy);
    gd.sy = new_sy;
    return &gd.linedata[old_sy];
}

pub fn grid_reflow_move(gd: *T.Grid, from: *T.GridLine) *T.GridLine {
    const to = grid_reflow_add(gd, 1);
    to.* = from.*;
    grid_reflow_dead(from);
    return to;
}

pub fn grid_reflow_join(target: *T.Grid, gd: *T.Grid, sx: u32, yy: u32, width_in: u32, already: bool) void {
    var from: ?*T.GridLine = null;
    var gc: T.GridCell = undefined;
    var lines: u32 = 0;
    var width = width_in;
    var to: u32 = undefined;
    var at: u32 = undefined;
    var want: u32 = 0;
    var wrapped: bool = true;
    var gl: *T.GridLine = undefined;

    if (!already) {
        to = target.sy;
        gl = grid_reflow_move(target, &gd.linedata[yy]);
    } else {
        to = target.sy - 1;
        gl = &target.linedata[to];
    }
    at = gl.cellused;

    while (true) {
        if (yy + 1 + lines == gd.hsize + gd.sy)
            break;
        const line = yy + 1 + lines;

        if ((gd.linedata[line].flags & T.GRID_LINE_WRAPPED) == 0)
            wrapped = false;
        if (gd.linedata[line].cellused == 0) {
            if (!wrapped) break;
            lines += 1;
            continue;
        }

        grid_get_cell1(&gd.linedata[line], 0, &gc);
        if (width + gc.data.width > sx)
            break;
        width += gc.data.width;
        grid_set_cell(target, at, to, &gc);
        at += 1;

        from = &gd.linedata[line];
        want = 1;
        while (want < from.?.cellused) : (want += 1) {
            grid_get_cell1(from.?, want, &gc);
            if (width + gc.data.width > sx)
                break;
            width += gc.data.width;
            grid_set_cell(target, at, to, &gc);
            at += 1;
        }
        lines += 1;

        if (!wrapped or want != from.?.cellused or width == sx)
            break;
    }

    if (lines == 0 or from == null) return;

    const left = from.?.cellused - want;
    if (left != 0) {
        grid_move_cells(gd, 0, want, yy + lines, left, 8);
        from.?.cellused = left;
        lines -= 1;
    } else if (!wrapped) {
        gl.flags &= ~T.GRID_LINE_WRAPPED;
    }

    var i = yy + 1;
    while (i < yy + 1 + lines) : (i += 1) {
        if (gd.linedata[i].celldata.len > 0)
            xm.allocator.free(gd.linedata[i].celldata);
        if (gd.linedata[i].extddata.len > 0)
            xm.allocator.free(gd.linedata[i].extddata);
        grid_reflow_dead(&gd.linedata[i]);
    }

    if (gd.hscrolled > to + lines)
        gd.hscrolled -= lines
    else if (gd.hscrolled > to)
        gd.hscrolled = to;
}

pub fn grid_reflow_split(target: *T.Grid, gd: *T.Grid, sx: u32, yy: u32, at: u32) void {
    const gl = &gd.linedata[yy];
    var gc: T.GridCell = undefined;
    var lines: u32 = undefined;
    const used = gl.cellused;
    const flags = gl.flags;

    if ((gl.flags & T.GRID_LINE_EXTENDED) == 0) {
        lines = 1 + (gl.cellused - 1) / sx;
    } else {
        lines = 2;
        var count_w: u32 = 0;
        var j = at;
        while (j < used) : (j += 1) {
            grid_get_cell1(gl, j, &gc);
            if (count_w + gc.data.width > sx) {
                lines += 1;
                count_w = 0;
            }
            count_w += gc.data.width;
        }
    }

    var line = target.sy + 1;
    const first = grid_reflow_add(target, lines);

    var w: u32 = 0;
    var xx: u32 = 0;
    {
        var j = at;
        while (j < used) : (j += 1) {
            grid_get_cell1(gl, j, &gc);
            if (w + gc.data.width > sx) {
                target.linedata[line].flags |= T.GRID_LINE_WRAPPED;
                line += 1;
                w = 0;
                xx = 0;
            }
            w += gc.data.width;
            grid_set_cell(target, xx, line, &gc);
            xx += 1;
        }
    }
    if ((flags & T.GRID_LINE_WRAPPED) != 0)
        target.linedata[line].flags |= T.GRID_LINE_WRAPPED;

    gl.cellused = at;
    gl.flags |= T.GRID_LINE_WRAPPED;
    first.* = gl.*;
    grid_reflow_dead(gl);

    if (yy <= gd.hscrolled)
        gd.hscrolled += lines - 1;

    if (w < sx and (flags & T.GRID_LINE_WRAPPED) != 0)
        grid_reflow_join(target, gd, sx, yy, w, true);
}

pub fn grid_reflow(gd: *T.Grid, sx: u32) void {
    rearrange_to_c_layout(gd);

    const target = grid_create(gd.sx, 0, 0);

    var yy: u32 = 0;
    while (yy < gd.hsize + gd.sy) : (yy += 1) {
        const gl = &gd.linedata[yy];
        if ((gl.flags & T.GRID_LINE_DEAD) != 0)
            continue;

        var at_val: u32 = 0;
        var width: u32 = 0;
        if ((gl.flags & T.GRID_LINE_EXTENDED) == 0) {
            width = gl.cellused;
            if (width > sx)
                at_val = sx
            else
                at_val = width;
        } else {
            var i: u32 = 0;
            while (i < gl.cellused) : (i += 1) {
                var gc: T.GridCell = undefined;
                grid_get_cell1(gl, i, &gc);
                if (at_val == 0 and width + gc.data.width > sx)
                    at_val = i;
                width += gc.data.width;
            }
        }

        if (width == sx) {
            _ = grid_reflow_move(target, gl);
            continue;
        }
        if (width > sx) {
            grid_reflow_split(target, gd, sx, yy, at_val);
            continue;
        }
        if ((gl.flags & T.GRID_LINE_WRAPPED) != 0)
            grid_reflow_join(target, gd, sx, yy, width, false)
        else
            _ = grid_reflow_move(target, gl);
    }

    if (target.sy < gd.sy)
        _ = grid_reflow_add(target, gd.sy - target.sy);
    gd.hsize = target.sy - gd.sy;
    if (gd.hscrolled > gd.hsize)
        gd.hscrolled = gd.hsize;
    xm.allocator.free(gd.linedata);
    gd.linedata = target.linedata;

    rearrange_to_zmux_layout(gd);

    xm.allocator.destroy(target);
}

pub fn grid_wrap_position(gd: *T.Grid, px: u32, py: u32, wx: *u32, wy: *u32) void {
    var ax: u32 = 0;
    var ay: u32 = 0;

    var yy: u32 = 0;
    while (yy < py) : (yy += 1) {
        const si = reflow_abs_to_storage(gd, yy);
        if ((gd.linedata[si].flags & T.GRID_LINE_WRAPPED) != 0)
            ax += gd.linedata[si].cellused
        else {
            ax = 0;
            ay += 1;
        }
    }

    const si = reflow_abs_to_storage(gd, yy);
    if (si >= gd.linedata.len or px >= gd.linedata[si].cellused)
        ax = std.math.maxInt(u32)
    else
        ax += px;
    wx.* = ax;
    wy.* = ay;
}

pub fn grid_unwrap_position(gd: *T.Grid, px: *u32, py: *u32, wx: u32, wy: u32) void {
    var yy: u32 = 0;
    var ay: u32 = 0;
    const total = gd.hsize + gd.sy;

    while (yy < total -| 1) : (yy += 1) {
        if (ay == wy) break;
        const si = reflow_abs_to_storage(gd, yy);
        if ((gd.linedata[si].flags & T.GRID_LINE_WRAPPED) == 0)
            ay += 1;
    }

    var local_wx = wx;
    if (local_wx == std.math.maxInt(u32)) {
        while (true) {
            const si = reflow_abs_to_storage(gd, yy);
            if ((gd.linedata[si].flags & T.GRID_LINE_WRAPPED) == 0) break;
            yy += 1;
        }
        const si_final = reflow_abs_to_storage(gd, yy);
        local_wx = gd.linedata[si_final].cellused;
    } else {
        while (true) {
            const si = reflow_abs_to_storage(gd, yy);
            if ((gd.linedata[si].flags & T.GRID_LINE_WRAPPED) == 0) break;
            if (local_wx < gd.linedata[si].cellused) break;
            local_wx -= gd.linedata[si].cellused;
            yy += 1;
        }
    }

    px.* = local_wx;
    py.* = yy;
}
