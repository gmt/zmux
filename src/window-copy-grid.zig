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
// Grid / screen line helpers for copy-mode (tmux/window-copy.c correlate).

const grid = @import("grid.zig");
const T = @import("types.zig");

pub fn absoluteStorageRow(gd: *const T.Grid, row: u32) ?u32 {
    return grid.absolute_row_to_storage(gd, row);
}

pub fn storageRowToAbsolute(gd: *const T.Grid, row: u32) u32 {
    return if (row < gd.sy) gd.hsize + row else row - gd.sy;
}

pub fn absoluteLine(gd: *const T.Grid, row: u32) ?*const T.GridLine {
    const storage_row = absoluteStorageRow(gd, row) orelse return null;
    return grid.grid_peek_line(gd, storage_row);
}

pub fn absoluteLineLength(gd: *const T.Grid, row: u32) u32 {
    const storage_row = absoluteStorageRow(gd, row) orelse return 0;
    return grid.line_length(@constCast(gd), storage_row);
}

pub fn absoluteGetCell(gd: *const T.Grid, row: u32, col: u32, gc: *T.GridCell) void {
    const storage_row = absoluteStorageRow(gd, row) orelse {
        gc.* = T.grid_default_cell;
        return;
    };
    grid.get_cell(@constCast(gd), storage_row, col, gc);
}

pub fn copyLine(dst_grid: *T.Grid, dst_row: u32, src_grid: *const T.Grid, src_row: u32, width: u32) void {
    const storage_row = absoluteStorageRow(src_grid, src_row) orelse return;
    if (storage_row >= src_grid.linedata.len or dst_row >= dst_grid.linedata.len) return;

    const src_line = &src_grid.linedata[storage_row];
    var cell: T.GridCell = undefined;
    var col: u32 = 0;
    while (col < width) : (col += 1) {
        grid.get_cell(@constCast(src_grid), storage_row, col, &cell);
        grid.set_cell(dst_grid, dst_row, col, &cell);
    }

    dst_grid.linedata[dst_row].flags = src_line.flags;
    dst_grid.linedata[dst_row].time = src_line.time;
}

pub fn rewrapStoredPosition(old_backing: *const T.Screen, new_backing: *const T.Screen, px: *u32, py: *u32) void {
    const old_rows = rowCount(old_backing);
    const new_rows = rowCount(new_backing);
    if (old_rows == 0 or new_rows == 0) {
        px.* = 0;
        py.* = 0;
        return;
    }

    if (py.* >= old_rows) py.* = old_rows - 1;
    const old_len = absoluteLineLength(old_backing.grid, py.*);
    if (px.* > old_len) px.* = old_len;

    if (old_backing.grid.sx != new_backing.grid.sx) {
        var wx: u32 = 0;
        var wy: u32 = 0;
        grid.grid_wrap_position(old_backing.grid, px.*, py.*, &wx, &wy);
        grid.grid_unwrap_position(new_backing.grid, px, py, wx, wy);
    }

    if (py.* >= new_rows) py.* = new_rows - 1;
    const new_len = absoluteLineLength(new_backing.grid, py.*);
    if (px.* > new_len) px.* = new_len;
}

pub fn rowCount(s: *const T.Screen) u32 {
    return s.grid.hsize + s.grid.sy;
}
