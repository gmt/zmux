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
// Ported in part from tmux/grid.c, tmux/grid-view.c, and tmux/grid-reader.c.
// Original copyright:
//   Copyright (c) 2009 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

//! grid.zig – shared grid allocation and cell helpers.

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");

pub fn grid_create(sx: u32, sy: u32, hlimit: u32) *T.Grid {
    const g = xm.allocator.create(T.Grid) catch unreachable;
    const lines = xm.allocator.alloc(T.GridLine, sy) catch unreachable;
    for (lines) |*l| l.* = .{};
    g.* = .{
        .sx = sx,
        .sy = sy,
        .hlimit = hlimit,
        .linedata = lines,
    };
    return g;
}

pub fn grid_free(gd: *T.Grid) void {
    for (gd.linedata) |line| {
        if (line.celldata.len > 0) xm.allocator.free(line.celldata);
        if (line.extddata.len > 0) xm.allocator.free(line.extddata);
    }
    xm.allocator.free(gd.linedata);
    xm.allocator.destroy(gd);
}

pub fn grid_reset(gd: *T.Grid) void {
    for (gd.linedata) |*line| clear_line(line);
    gd.hsize = 0;
    gd.hscrolled = 0;
}

pub fn ensure_line_capacity(gd: *T.Grid, row: u32) void {
    if (row >= gd.linedata.len) return;
    const line = &gd.linedata[row];
    if (line.celldata.len == gd.sx) return;
    if (line.celldata.len > 0) xm.allocator.free(line.celldata);
    line.celldata = xm.allocator.alloc(T.GridCellEntry, gd.sx) catch unreachable;
    for (line.celldata) |*cell| cell.* = default_cell_entry();
    line.cellused = 0;
}

pub fn clear_line(line: *T.GridLine) void {
    if (line.celldata.len > 0) {
        for (line.celldata) |*cell| cell.* = default_cell_entry();
    }
    line.cellused = 0;
}

pub fn scroll_up(gd: *T.Grid, top: u32, bottom: u32) void {
    if (gd.linedata.len == 0 or bottom >= gd.linedata.len or top >= bottom) return;
    clear_line(&gd.linedata[top]);
    const first = gd.linedata[top];
    std.mem.copyForwards(T.GridLine, gd.linedata[top..bottom], gd.linedata[top + 1 .. bottom + 1]);
    gd.linedata[bottom] = first;
    clear_line(&gd.linedata[bottom]);
}

pub fn set_ascii(gd: *T.Grid, row: u32, col: u32, ch: u8) void {
    if (row >= gd.linedata.len or col >= gd.sx) return;
    ensure_line_capacity(gd, row);
    const line = &gd.linedata[row];
    line.celldata[col] = .{
        .offset_or_data = .{
            .data = .{
                .attr = 0,
                .fg = 0,
                .bg = 0,
                .data = ch,
            },
        },
        .flags = 0,
    };
    if (line.cellused < col + 1) line.cellused = col + 1;
}

pub fn ascii_at(gd: *T.Grid, row: u32, col: u32) u8 {
    if (row >= gd.linedata.len) return ' ';
    const line = gd.linedata[row];
    if (col >= line.celldata.len or col >= line.cellused) return ' ';
    const ch = line.celldata[col].offset_or_data.data.data;
    return if (ch == 0) ' ' else ch;
}

pub fn line_used(gd: *T.Grid, row: u32) u32 {
    if (row >= gd.linedata.len) return 0;
    const line = gd.linedata[row];
    return @min(line.cellused, @as(u32, @intCast(line.celldata.len)));
}

fn default_cell_entry() T.GridCellEntry {
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

test "grid set_ascii and scroll_up keep content bounded" {
    const gd = grid_create(4, 2, 100);
    defer grid_free(gd);

    set_ascii(gd, 0, 0, 'a');
    set_ascii(gd, 1, 0, 'b');
    try std.testing.expectEqual(@as(u8, 'a'), ascii_at(gd, 0, 0));
    try std.testing.expectEqual(@as(u8, 'b'), ascii_at(gd, 1, 0));

    scroll_up(gd, 0, 1);
    try std.testing.expectEqual(@as(u8, 'b'), ascii_at(gd, 0, 0));
    try std.testing.expectEqual(@as(u8, ' '), ascii_at(gd, 1, 0));
}
