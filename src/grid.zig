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
const T = @import("types.zig");
const utf8 = @import("utf8.zig");
const xm = @import("xmalloc.zig");

pub const StringCellsOptions = struct {
    trim_trailing_spaces: bool = false,
    escape_sequences: bool = false,
};

pub fn grid_create(sx: u32, sy: u32, hlimit: u32) *T.Grid {
    const g = xm.allocator.create(T.Grid) catch unreachable;
    const lines = xm.allocator.alloc(T.GridLine, sy) catch unreachable;
    for (lines) |*l| l.* = .{};
    g.* = .{
        .flags = if (hlimit != 0) T.GRID_HISTORY else 0,
        .sx = sx,
        .sy = sy,
        .hlimit = hlimit,
        .linedata = lines,
    };
    return g;
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
    if (count > gd.hsize) return;
    gd.hsize -= count;
    if (gd.hscrolled > gd.hsize) gd.hscrolled = gd.hsize;
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

    const used = if (options.trim_trailing_spaces)
        @min(line_length(gd, row), width)
    else
        @min(width, gd.sx);

    var out: std.ArrayList(u8) = .{};
    errdefer out.deinit(xm.allocator);

    var col: u32 = 0;
    while (col < used) : (col += 1) {
        var gc: T.GridCell = undefined;
        get_cell(gd, row, col, &gc);
        if (gc.isPadding()) continue;
        append_rendered_cell(&out, &gc, options.escape_sequences);
    }

    return out.toOwnedSlice(xm.allocator) catch unreachable;
}

fn free_line_storage(line: *T.GridLine) void {
    if (line.celldata.len > 0) xm.allocator.free(line.celldata);
    if (line.extddata.len > 0) xm.allocator.free(line.extddata);
    line.* = .{};
}

fn append_rendered_cell(out: *std.ArrayList(u8), gc: *const T.GridCell, escape_sequences: bool) void {
    const bytes = if (gc.payload().isEmpty()) " " else gc.payload().bytes();
    if (!escape_sequences) {
        out.appendSlice(xm.allocator, bytes) catch unreachable;
        return;
    }

    for (bytes) |ch| {
        if ((ch >= ' ' and ch <= '~') and ch != '\\') {
            out.append(xm.allocator, ch) catch unreachable;
            continue;
        }

        var octal: [4]u8 = undefined;
        const rendered = std.fmt.bufPrint(&octal, "\\{o:0>3}", .{ch}) catch unreachable;
        out.appendSlice(xm.allocator, rendered) catch unreachable;
    }
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

fn colour_is_default(colour: i32) bool {
    return colour == 8 or colour == 9;
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

test "grid remove_history trims tracked history and clamps hscrolled" {
    const gd = grid_create(4, 2, 100);
    defer grid_free(gd);

    gd.hsize = 5;
    gd.hscrolled = 7;

    remove_history(gd, 3);
    try std.testing.expectEqual(@as(u32, 2), gd.hsize);
    try std.testing.expectEqual(@as(u32, 2), gd.hscrolled);

    remove_history(gd, 3);
    try std.testing.expectEqual(@as(u32, 2), gd.hsize);
}

test "grid stores multibyte cells and padding through the shared cell API" {
    const gd = grid_create(4, 1, 0);
    defer grid_free(gd);

    const glyph = utf8.Glyph.fromCodepoint(0x1f642) orelse return error.ExpectedGlyph;
    const source = T.GridCell.fromPayload(glyph.payload());
    set_cell(gd, 0, 0, &source);
    set_padding(gd, 0, 1);

    var stored: T.GridCell = undefined;
    get_cell(gd, 0, 0, &stored);
    try std.testing.expect(cells_equal(&source, &stored));
    try std.testing.expectEqualStrings("🙂", stored.payload().bytes());
    try std.testing.expectEqual(@as(u8, 2), stored.payload().width);

    get_cell(gd, 0, 1, &stored);
    try std.testing.expect(stored.isPadding());
    try std.testing.expectEqual(@as(u8, 0), stored.payload().width);
    try std.testing.expectEqual(@as(u32, 2), line_length(gd, 0));
}

test "grid string_cells preserves utf8 payloads while skipping padding cells" {
    const gd = grid_create(4, 1, 0);
    defer grid_free(gd);

    const accent = utf8.Glyph.fromCodepoint('é').?;
    const emoji = utf8.Glyph.fromCodepoint(0x1f642).?;

    var accent_cell = T.GridCell.fromPayload(accent.payload());
    var emoji_cell = T.GridCell.fromPayload(emoji.payload());
    set_cell(gd, 0, 0, &accent_cell);
    set_cell(gd, 0, 1, &emoji_cell);
    set_padding(gd, 0, 2);
    set_ascii(gd, 0, 3, '!');

    const rendered = string_cells(gd, 0, gd.sx, .{ .trim_trailing_spaces = true });
    defer xm.allocator.free(rendered);

    try std.testing.expectEqualStrings("é🙂!", rendered);
}

test "grid overwriting an extended slot with ascii preserves readable content" {
    const gd = grid_create(4, 1, 0);
    defer grid_free(gd);

    const glyph = utf8.Glyph.fromCodepoint(0x00e9) orelse return error.ExpectedGlyph;
    var cell = T.GridCell.fromPayload(glyph.payload());
    set_cell(gd, 0, 0, &cell);

    set_ascii(gd, 0, 0, 'x');

    var stored: T.GridCell = undefined;
    get_cell(gd, 0, 0, &stored);
    try std.testing.expectEqual(@as(u8, 'x'), ascii_at(gd, 0, 0));
    try std.testing.expectEqual(@as(u8, 1), stored.payload().size);
    try std.testing.expectEqual(@as(u8, 'x'), stored.payload().data[0]);
}
