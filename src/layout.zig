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
// Ported in part from tmux/layout.c.
// Original copyright:
//   Copyright (c) 2009 Nicholas Marriott <nicholas.marriott@gmail.com>
//   Copyright (c) 2016 Stephen Kent <smkent@smkent.net>
//   ISC licence - same terms as above.

const std = @import("std");
const args_mod = @import("arguments.zig");
const opts = @import("options.zig");
const T = @import("types.zig");
const win = @import("window.zig");
const xm = @import("xmalloc.zig");

const Rect = struct {
    xoff: u32,
    yoff: u32,
    sx: u32,
    sy: u32,
};

/// tmux `struct layout_cell` — used throughout layout algorithms and audit wrappers.
const Cell = T.LayoutCell;

const BuildError = error{
    InvalidLayout,
};

const layout_set_names = [_][]const u8{
    "even-horizontal",
    "even-vertical",
    "main-horizontal",
    "main-horizontal-mirrored",
    "main-vertical",
    "main-vertical-mirrored",
    "tiled",
};

pub fn resize_pane(wp: *T.WindowPane, type_: T.LayoutType, change: i32, opposite: bool) bool {
    var builder = Builder.init(wp.window.panes.items);
    defer builder.arena.deinit();
    const root = builder.build() catch return false;
    const leaf = find_leaf(root, wp) orelse return false;
    return resize_leaf(root, leaf, type_, change, opposite);
}

pub fn resize_pane_to(wp: *T.WindowPane, type_: T.LayoutType, new_size: u32) bool {
    var builder = Builder.init(wp.window.panes.items);
    defer builder.arena.deinit();
    const root = builder.build() catch return false;
    const leaf = find_leaf(root, wp) orelse return false;

    var lc = leaf;
    var lcparent = lc.parent;
    while (lcparent != null and lcparent.?.type != type_) {
        lc = lcparent.?;
        lcparent = lc.parent;
    }
    const parent = lcparent orelse return false;

    const size: u32 = switch (type_) {
        .leftright => lc.sx,
        .topbottom => lc.sy,
        .windowpane => return false,
    };
    const change64: i64 = if (is_last_child(parent, lc))
        @as(i64, @intCast(size)) - @as(i64, @intCast(new_size))
    else
        @as(i64, @intCast(new_size)) - @as(i64, @intCast(size));
    const change: i32 = std.math.cast(i32, change64) orelse return false;
    return resize_leaf(root, leaf, type_, change, true);
}

pub fn resize_by_border_drag(w: *T.Window, x: u32, y: u32, last_x: u32, last_y: u32) bool {
    var builder = Builder.init(w.panes.items);
    defer builder.arena.deinit();
    const root = builder.build() catch return false;

    const dx64 = @as(i64, @intCast(x)) - @as(i64, @intCast(last_x));
    const dy64 = @as(i64, @intCast(y)) - @as(i64, @intCast(last_y));
    const dx: i32 = std.math.cast(i32, dx64) orelse return false;
    const dy: i32 = std.math.cast(i32, dy64) orelse return false;
    if (dx == 0 and dy == 0) return false;

    const offsets = [_][2]i32{
        .{ 0, 0 },
        .{ 0, 1 },
        .{ 1, 0 },
        .{ 0, -1 },
        .{ -1, 0 },
    };
    var cells: [offsets.len]*Cell = undefined;
    var ncells: usize = 0;

    for (offsets) |offset| {
        const border_x = offsetCoord(last_x, offset[0]) orelse continue;
        const border_y = offsetCoord(last_y, offset[1]) orelse continue;
        const cell = search_by_border(root, border_x, border_y) orelse continue;

        var duplicate = false;
        for (cells[0..ncells]) |existing| {
            if (existing == cell) {
                duplicate = true;
                break;
            }
        }
        if (duplicate) continue;

        cells[ncells] = cell;
        ncells += 1;
    }

    var changed = false;
    for (cells[0..ncells]) |cell| {
        const parent = cell.parent orelse continue;
        switch (parent.type) {
            .topbottom => {
                if (dy != 0 and resize_layout(root, cell, .topbottom, dy, false))
                    changed = true;
            },
            .leftright => {
                if (dx != 0 and resize_layout(root, cell, .leftright, dx, false))
                    changed = true;
            },
            .windowpane => {},
        }
    }
    return changed;
}

pub fn dump_window(w: *T.Window) ?[]u8 {
    if (w.layout_root) |root| {
        if (layout_count_cells(root) == w.panes.items.len)
            return dump_root(root);
    }
    if (w.panes.items.len == 0)
        return null;

    var builder = Builder.init(w.panes.items);
    defer builder.arena.deinit();
    const root = builder.build() catch return null;

    var body: std.ArrayList(u8) = .{};
    defer body.deinit(xm.allocator);
    if (!dump_append(root, &body))
        return null;
    return xm.xasprintf("{x:0>4},{s}", .{ layout_checksum(body.items), body.items });
}

pub fn dump_root(root: *const T.LayoutCell) ?[]u8 {
    var body: std.ArrayList(u8) = .{};
    defer body.deinit(xm.allocator);
    if (!dump_append_public(root, &body))
        return null;
    return xm.xasprintf("{x:0>4},{s}", .{ layout_checksum(body.items), body.items });
}

pub fn parse_window(w: *T.Window, layout: []const u8, cause: *?[]u8) bool {
    cause.* = null;
    if (w.panes.items.len == 0) {
        cause.* = xm.xstrdup("invalid layout");
        return false;
    }
    if (layout.len < 5 or layout[4] != ',') {
        cause.* = xm.xstrdup("invalid layout");
        return false;
    }

    const csum = std.fmt.parseInt(u16, layout[0..4], 16) catch {
        cause.* = xm.xstrdup("invalid layout");
        return false;
    };
    const encoded = layout[5..];
    if (layout_checksum(encoded) != csum) {
        cause.* = xm.xstrdup("invalid layout");
        return false;
    }

    var arena = std.heap.ArenaAllocator.init(xm.allocator);
    defer arena.deinit();
    var parser = LayoutParser.init(arena.allocator(), encoded);
    var root: ?*Cell = parser.construct(null) orelse {
        cause.* = xm.xstrdup("invalid layout");
        return false;
    };
    if (!parser.atEnd()) {
        cause.* = xm.xstrdup("invalid layout");
        return false;
    }

    while (true) {
        const npanes = w.panes.items.len;
        const ncells = count_cells(root.?);
        if (npanes > ncells) {
            cause.* = xm.xasprintf("have {d} panes but need {d}", .{ npanes, ncells });
            return false;
        }
        if (npanes == ncells)
            break;

        const bottom_right = find_bottomright(root.?);
        destroy_cell(bottom_right, &root);
        if (root == null) {
            cause.* = xm.xstrdup("invalid layout");
            return false;
        }
    }

    normalize_root_size(root.?);
    if (!check_layout(root.?)) {
        cause.* = xm.xstrdup("size mismatch after applying layout");
        return false;
    }

    assign_panes(w.panes.items, root.?);
    apply_tree_to_window(w, root.?);
    return true;
}

pub fn spread_out(wp: *T.WindowPane) bool {
    if (wp.layout_cell) |leaf| {
        var parent = leaf.parent;
        while (parent) |candidate| : (parent = candidate.parent) {
            if (layout_spread_cell(wp.window, candidate) != 0) {
                layout_fix_offsets(wp.window);
                layout_fix_panes(wp.window, null);
                return true;
            }
        }
    }

    var builder = Builder.init(wp.window.panes.items);
    defer builder.arena.deinit();
    const root = builder.build() catch return false;
    const leaf = find_leaf(root, wp) orelse return false;

    var parent = leaf.parent;
    while (parent) |candidate| : (parent = candidate.parent) {
        if (spread_cell(candidate)) {
            fix_offsets(root);
            apply_panes(root);
            return true;
        }
    }
    return false;
}

pub fn set_lookup(name: []const u8) i32 {
    var matched: i32 = -1;

    for (layout_set_names, 0..) |candidate, idx| {
        if (std.mem.eql(u8, candidate, name))
            return @intCast(idx);
    }
    for (layout_set_names, 0..) |candidate, idx| {
        if (!std.mem.startsWith(u8, candidate, name))
            continue;
        if (matched != -1)
            return -1;
        matched = @intCast(idx);
    }

    return matched;
}

pub fn set_select(w: *T.Window, layout: usize) usize {
    const bounded = @min(layout, layout_set_names.len - 1);
    apply_preset_layout(w, bounded);
    w.lastlayout = @intCast(bounded);
    return bounded;
}

pub fn set_next(w: *T.Window) usize {
    const layout = if (w.lastlayout == -1)
        @as(usize, 0)
    else
        (@as(usize, @intCast(w.lastlayout)) + 1) % layout_set_names.len;
    return set_select(w, layout);
}

pub fn set_previous(w: *T.Window) usize {
    const layout = if (w.lastlayout == -1)
        layout_set_names.len - 1
    else if (w.lastlayout == 0)
        layout_set_names.len - 1
    else
        @as(usize, @intCast(w.lastlayout - 1));
    return set_select(w, layout);
}

fn dump_append(lc: *Cell, body: *std.ArrayList(u8)) bool {
    var tmp: [64]u8 = undefined;
    const prefix = if (lc.wp) |pane|
        std.fmt.bufPrint(&tmp, "{d}x{d},{d},{d},{d}", .{ lc.sx, lc.sy, lc.xoff, lc.yoff, pane.id }) catch return false
    else
        std.fmt.bufPrint(&tmp, "{d}x{d},{d},{d}", .{ lc.sx, lc.sy, lc.xoff, lc.yoff }) catch return false;
    body.appendSlice(xm.allocator, prefix) catch unreachable;

    switch (lc.type) {
        .windowpane => return true,
        .leftright, .topbottom => {
            const open_bracket: u8 = if (lc.type == .leftright) '{' else '[';
            const close_bracket: u8 = if (lc.type == .leftright) '}' else ']';
            body.append(xm.allocator, open_bracket) catch unreachable;
            for (lc.cells.items, 0..) |child, idx| {
                if (!dump_append(child, body))
                    return false;
                if (idx + 1 < lc.cells.items.len)
                    body.append(xm.allocator, ',') catch unreachable;
            }
            body.append(xm.allocator, close_bracket) catch unreachable;
            return true;
        },
    }
}

fn dump_append_public(lc: *const T.LayoutCell, body: *std.ArrayList(u8)) bool {
    var tmp: [64]u8 = undefined;
    const prefix = switch (lc.type) {
        .windowpane => blk: {
            const pane = lc.wp orelse return false;
            break :blk std.fmt.bufPrint(&tmp, "{d}x{d},{d},{d},{d}", .{ lc.sx, lc.sy, lc.xoff, lc.yoff, pane.id }) catch return false;
        },
        .leftright, .topbottom => std.fmt.bufPrint(&tmp, "{d}x{d},{d},{d}", .{ lc.sx, lc.sy, lc.xoff, lc.yoff }) catch return false,
    };
    body.appendSlice(xm.allocator, prefix) catch unreachable;

    switch (lc.type) {
        .windowpane => return true,
        .leftright, .topbottom => {
            const open_bracket: u8 = if (lc.type == .leftright) '{' else '[';
            const close_bracket: u8 = if (lc.type == .leftright) '}' else ']';
            body.append(xm.allocator, open_bracket) catch unreachable;
            for (lc.cells.items, 0..) |child, idx| {
                if (!dump_append_public(child, body))
                    return false;
                if (idx + 1 < lc.cells.items.len)
                    body.append(xm.allocator, ',') catch unreachable;
            }
            body.append(xm.allocator, close_bracket) catch unreachable;
            return true;
        },
    }
}

fn layout_checksum(layout: []const u8) u16 {
    var csum: u16 = 0;
    for (layout) |ch| {
        csum = (csum >> 1) + ((csum & 1) << 15);
        csum +%= ch;
    }
    return csum;
}

const LayoutParser = struct {
    alloc: std.mem.Allocator,
    input: []const u8,
    index: usize = 0,

    fn init(alloc: std.mem.Allocator, input: []const u8) LayoutParser {
        return .{
            .alloc = alloc,
            .input = input,
        };
    }

    fn atEnd(self: *const LayoutParser) bool {
        return self.index >= self.input.len;
    }

    fn peek(self: *const LayoutParser) ?u8 {
        if (self.index >= self.input.len)
            return null;
        return self.input[self.index];
    }

    fn readNumber(self: *LayoutParser) ?u32 {
        const start = self.index;
        while (self.index < self.input.len and std.ascii.isDigit(self.input[self.index]))
            self.index += 1;
        if (self.index == start)
            return null;
        return std.fmt.parseInt(u32, self.input[start..self.index], 10) catch null;
    }

    fn expect(self: *LayoutParser, ch: u8) bool {
        if (self.peek() != ch)
            return false;
        self.index += 1;
        return true;
    }

    fn construct(self: *LayoutParser, parent: ?*Cell) ?*Cell {
        const sx = self.readNumber() orelse return null;
        if (!self.expect('x'))
            return null;
        const sy = self.readNumber() orelse return null;
        if (!self.expect(','))
            return null;
        const xoff = self.readNumber() orelse return null;
        if (!self.expect(','))
            return null;
        const yoff = self.readNumber() orelse return null;

        if (self.peek() == ',') {
            const saved = self.index;
            self.index += 1;
            _ = self.readNumber() orelse {
                self.index = saved;
                return null;
            };
            if (self.peek() == 'x')
                self.index = saved;
        }

        const lc = create_cell(self.alloc, .windowpane, .{
            .xoff = xoff,
            .yoff = yoff,
            .sx = sx,
            .sy = sy,
        }) catch unreachable;
        lc.parent = parent;

        const next = self.peek() orelse return lc;
        switch (next) {
            ',', '}', ']' => return lc,
            '{', '[' => {
                lc.type = if (next == '{') .leftright else .topbottom;
                self.index += 1;
            },
            else => return null,
        }

        while (true) {
            const child = self.construct(lc) orelse return null;
            append_raw_child(lc, child, self.alloc) catch unreachable;
            if (self.peek() != ',')
                break;
            self.index += 1;
        }

        const close_bracket: u8 = if (lc.type == .leftright) '}' else ']';
        if (!self.expect(close_bracket))
            return null;
        return lc;
    }
};

fn count_cells(lc: *Cell) usize {
    if (lc.type == .windowpane)
        return 1;

    var count: usize = 0;
    for (lc.cells.items) |child|
        count += count_cells(child);
    return count;
}

fn find_bottomright(lc: *Cell) *Cell {
    if (lc.type == .windowpane)
        return lc;
    return find_bottomright(lc.cells.items[lc.cells.items.len - 1]);
}

fn destroy_cell(lc: *Cell, root: *?*Cell) void {
    const parent = lc.parent orelse {
        root.* = null;
        return;
    };
    const idx = child_index(parent, lc) orelse return;

    if (parent.cells.items.len > 1) {
        const other = if (idx == 0)
            parent.cells.items[1]
        else
            parent.cells.items[idx - 1];
        if (parent.type == .leftright)
            resize_adjust(other, .leftright, @intCast(lc.sx + 1))
        else
            resize_adjust(other, .topbottom, @intCast(lc.sy + 1));
    }

    _ = parent.cells.orderedRemove(idx);
    if (parent.cells.items.len != 1)
        return;

    const survivor = parent.cells.items[0];
    survivor.parent = parent.parent;
    if (survivor.parent) |grandparent| {
        const parent_idx = child_index(grandparent, parent) orelse return;
        grandparent.cells.items[parent_idx] = survivor;
        return;
    }

    survivor.xoff = 0;
    survivor.yoff = 0;
    root.* = survivor;
}

fn child_index(parent: *Cell, child: *Cell) ?usize {
    for (parent.cells.items, 0..) |candidate, idx| {
        if (candidate == child)
            return idx;
    }
    return null;
}

fn normalize_root_size(root: *Cell) void {
    if (root.type == .windowpane)
        return;

    var sx: u32 = 0;
    var sy: u32 = 0;
    switch (root.type) {
        .leftright => {
            for (root.cells.items) |child| {
                sy = child.sy + 1;
                sx += child.sx + 1;
            }
        },
        .topbottom => {
            for (root.cells.items) |child| {
                sx = child.sx + 1;
                sy += child.sy + 1;
            }
        },
        .windowpane => unreachable,
    }

    if (sx != 0 and sy != 0) {
        root.sx = sx - 1;
        root.sy = sy - 1;
    }
}

fn check_layout(lc: *Cell) bool {
    switch (lc.type) {
        .windowpane => return true,
        .leftright => {
            var total: u32 = 0;
            for (lc.cells.items) |child| {
                if (child.sy != lc.sy)
                    return false;
                if (!check_layout(child))
                    return false;
                total += child.sx + 1;
            }
            return total != 0 and total - 1 == lc.sx;
        },
        .topbottom => {
            var total: u32 = 0;
            for (lc.cells.items) |child| {
                if (child.sx != lc.sx)
                    return false;
                if (!check_layout(child))
                    return false;
                total += child.sy + 1;
            }
            return total != 0 and total - 1 == lc.sy;
        },
    }
}

fn assign_panes(panes: []const *T.WindowPane, root: *Cell) void {
    var next_pane: usize = 0;
    assign_panes_recursive(panes, &next_pane, root);
}

fn assign_panes_recursive(panes: []const *T.WindowPane, next_pane: *usize, lc: *Cell) void {
    switch (lc.type) {
        .windowpane => {
            lc.wp = panes[next_pane.*];
            next_pane.* += 1;
        },
        .leftright, .topbottom => {
            for (lc.cells.items) |child|
                assign_panes_recursive(panes, next_pane, child);
        },
    }
}

fn apply_tree_to_window(w: *T.Window, root: *Cell) void {
    win.window_resize(w, root.sx, root.sy, -1, -1);
    root.xoff = 0;
    root.yoff = 0;
    fix_offsets(root);
    apply_panes(root);
}

fn spread_cell(parent: *Cell) bool {
    const number = parent.cells.items.len;
    if (number <= 1)
        return false;

    const size = switch (parent.type) {
        .leftright => parent.sx,
        .topbottom => parent.sy,
        .windowpane => return false,
    };
    if (size < number - 1)
        return false;

    const each = (size - (number - 1)) / @as(u32, @intCast(number));
    if (each == 0)
        return false;

    var remainder = size - (@as(u32, @intCast(number)) * each) - (@as(u32, @intCast(number)) - 1);
    var changed = false;
    for (parent.cells.items) |child| {
        switch (parent.type) {
            .leftright => {
                var change = @as(i32, @intCast(each)) - @as(i32, @intCast(child.sx));
                if (remainder > 0) {
                    change += 1;
                    remainder -= 1;
                }
                resize_adjust(child, .leftright, change);
                changed = changed or change != 0;
            },
            .topbottom => {
                var change = @as(i32, @intCast(each)) - @as(i32, @intCast(child.sy));
                if (remainder > 0) {
                    change += 1;
                    remainder -= 1;
                }
                resize_adjust(child, .topbottom, change);
                changed = changed or change != 0;
            },
            .windowpane => unreachable,
        }
    }
    return changed;
}

fn apply_preset_layout(w: *T.Window, layout: usize) void {
    var arena = std.heap.ArenaAllocator.init(xm.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const root = switch (layout) {
        0 => build_even_layout(w, alloc, .leftright),
        1 => build_even_layout(w, alloc, .topbottom),
        2 => build_main_horizontal_layout(w, alloc, false),
        3 => build_main_horizontal_layout(w, alloc, true),
        4 => build_main_vertical_layout(w, alloc, false),
        5 => build_main_vertical_layout(w, alloc, true),
        6 => build_tiled_layout(w, alloc),
        else => unreachable,
    };
    if (root == null)
        return;
    apply_tree_to_window(w, root.?);
}

fn build_even_layout(w: *T.Window, alloc: std.mem.Allocator, type_: T.LayoutType) ?*Cell {
    const n = w.panes.items.len;
    if (n <= 1)
        return null;

    const root = create_cell(alloc, type_, .{
        .xoff = 0,
        .yoff = 0,
        .sx = if (type_ == .leftright)
            @max(@as(u32, @intCast(n)) * (T.PANE_MINIMUM + 1) - 1, w.sx)
        else
            w.sx,
        .sy = if (type_ == .topbottom)
            @max(@as(u32, @intCast(n)) * (T.PANE_MINIMUM + 1) - 1, w.sy)
        else
            w.sy,
    }) catch unreachable;
    for (w.panes.items) |pane| {
        const child = create_cell(alloc, .windowpane, .{
            .xoff = 0,
            .yoff = 0,
            .sx = if (type_ == .leftright) w.sx else root.sx,
            .sy = if (type_ == .topbottom) w.sy else root.sy,
        }) catch unreachable;
        child.wp = pane;
        append_raw_child(root, child, alloc) catch unreachable;
    }
    _ = spread_cell(root);
    return root;
}

fn build_main_horizontal_layout(w: *T.Window, alloc: std.mem.Allocator, mirrored: bool) ?*Cell {
    const total = w.panes.items.len;
    if (total <= 1)
        return null;
    const other_count = total - 1;

    const available = w.sy - 1;
    var cause: ?[]u8 = null;
    defer if (cause) |msg| xm.allocator.free(msg);

    const main_text = opts.options_get_string(w.options, "main-pane-height");
    var mainh = @as(u32, @intCast(args_mod.args_string_percentage(main_text, 0, std.math.maxInt(i32), available, &cause)));
    if (cause != null) {
        xm.allocator.free(cause.?);
        cause = null;
        mainh = 24;
    }

    var otherh: u32 = undefined;
    if (mainh + T.PANE_MINIMUM >= available) {
        mainh = if (available <= T.PANE_MINIMUM * 2) T.PANE_MINIMUM else available - T.PANE_MINIMUM;
        otherh = T.PANE_MINIMUM;
    } else {
        const other_text = opts.options_get_string(w.options, "other-pane-height");
        otherh = @as(u32, @intCast(args_mod.args_string_percentage(other_text, 0, std.math.maxInt(i32), available, &cause)));
        if (cause != null or otherh == 0) {
            if (cause) |msg| {
                xm.allocator.free(msg);
                cause = null;
            }
            otherh = available - mainh;
        } else if (otherh > available or available - otherh < mainh) {
            otherh = available - mainh;
        } else {
            mainh = available - otherh;
        }
    }

    const sx = @max(@as(u32, @intCast(other_count)) * (T.PANE_MINIMUM + 1) - 1, w.sx);
    const root = create_cell(alloc, .topbottom, .{
        .xoff = 0,
        .yoff = 0,
        .sx = sx,
        .sy = mainh + otherh + 1,
    }) catch unreachable;
    const main = create_cell(alloc, .windowpane, .{
        .xoff = 0,
        .yoff = 0,
        .sx = sx,
        .sy = mainh,
    }) catch unreachable;
    main.wp = w.panes.items[0];

    const other = if (other_count == 1) blk: {
        const leaf = create_cell(alloc, .windowpane, .{
            .xoff = 0,
            .yoff = 0,
            .sx = sx,
            .sy = otherh,
        }) catch unreachable;
        leaf.wp = w.panes.items[1];
        break :blk leaf;
    } else blk: {
        const node = create_cell(alloc, .leftright, .{
            .xoff = 0,
            .yoff = 0,
            .sx = sx,
            .sy = otherh,
        }) catch unreachable;
        for (w.panes.items[1..]) |pane| {
            const child = create_cell(alloc, .windowpane, .{
                .xoff = 0,
                .yoff = 0,
                .sx = T.PANE_MINIMUM,
                .sy = otherh,
            }) catch unreachable;
            child.wp = pane;
            append_raw_child(node, child, alloc) catch unreachable;
        }
        _ = spread_cell(node);
        break :blk node;
    };

    if (!mirrored) {
        append_raw_child(root, main, alloc) catch unreachable;
        append_raw_child(root, other, alloc) catch unreachable;
    } else {
        append_raw_child(root, other, alloc) catch unreachable;
        append_raw_child(root, main, alloc) catch unreachable;
    }
    return root;
}

fn build_main_vertical_layout(w: *T.Window, alloc: std.mem.Allocator, mirrored: bool) ?*Cell {
    const total = w.panes.items.len;
    if (total <= 1)
        return null;
    const other_count = total - 1;

    const available = w.sx - 1;
    var cause: ?[]u8 = null;
    defer if (cause) |msg| xm.allocator.free(msg);

    const main_text = opts.options_get_string(w.options, "main-pane-width");
    var mainw = @as(u32, @intCast(args_mod.args_string_percentage(main_text, 0, std.math.maxInt(i32), available, &cause)));
    if (cause != null) {
        xm.allocator.free(cause.?);
        cause = null;
        mainw = 80;
    }

    var otherw: u32 = undefined;
    if (mainw + T.PANE_MINIMUM >= available) {
        mainw = if (available <= T.PANE_MINIMUM * 2) T.PANE_MINIMUM else available - T.PANE_MINIMUM;
        otherw = T.PANE_MINIMUM;
    } else {
        const other_text = opts.options_get_string(w.options, "other-pane-width");
        otherw = @as(u32, @intCast(args_mod.args_string_percentage(other_text, 0, std.math.maxInt(i32), available, &cause)));
        if (cause != null or otherw == 0) {
            if (cause) |msg| {
                xm.allocator.free(msg);
                cause = null;
            }
            otherw = available - mainw;
        } else if (otherw > available or available - otherw < mainw) {
            otherw = available - mainw;
        } else {
            mainw = available - otherw;
        }
    }

    const sy = @max(@as(u32, @intCast(other_count)) * (T.PANE_MINIMUM + 1) - 1, w.sy);
    const root = create_cell(alloc, .leftright, .{
        .xoff = 0,
        .yoff = 0,
        .sx = mainw + otherw + 1,
        .sy = sy,
    }) catch unreachable;
    const main = create_cell(alloc, .windowpane, .{
        .xoff = 0,
        .yoff = 0,
        .sx = mainw,
        .sy = sy,
    }) catch unreachable;
    main.wp = w.panes.items[0];

    const other = if (other_count == 1) blk: {
        const leaf = create_cell(alloc, .windowpane, .{
            .xoff = 0,
            .yoff = 0,
            .sx = otherw,
            .sy = sy,
        }) catch unreachable;
        leaf.wp = w.panes.items[1];
        break :blk leaf;
    } else blk: {
        const node = create_cell(alloc, .topbottom, .{
            .xoff = 0,
            .yoff = 0,
            .sx = otherw,
            .sy = sy,
        }) catch unreachable;
        for (w.panes.items[1..]) |pane| {
            const child = create_cell(alloc, .windowpane, .{
                .xoff = 0,
                .yoff = 0,
                .sx = otherw,
                .sy = T.PANE_MINIMUM,
            }) catch unreachable;
            child.wp = pane;
            append_raw_child(node, child, alloc) catch unreachable;
        }
        _ = spread_cell(node);
        break :blk node;
    };

    if (!mirrored) {
        append_raw_child(root, main, alloc) catch unreachable;
        append_raw_child(root, other, alloc) catch unreachable;
    } else {
        append_raw_child(root, other, alloc) catch unreachable;
        append_raw_child(root, main, alloc) catch unreachable;
    }
    return root;
}

fn build_tiled_layout(w: *T.Window, alloc: std.mem.Allocator) ?*Cell {
    const total = w.panes.items.len;
    if (total <= 1)
        return null;

    const max_columns: u32 = @intCast(@max(opts.options_get_number(w.options, "tiled-layout-max-columns"), 0));
    var rows: u32 = 1;
    var columns: u32 = 1;
    while (rows * columns < total) {
        rows += 1;
        if (rows * columns < total and (max_columns == 0 or columns < max_columns))
            columns += 1;
    }

    var width = (w.sx - (columns - 1)) / columns;
    if (width < T.PANE_MINIMUM)
        width = T.PANE_MINIMUM;
    var height = (w.sy - (rows - 1)) / rows;
    if (height < T.PANE_MINIMUM)
        height = T.PANE_MINIMUM;

    const root_sx = @max(((width + 1) * columns) - 1, w.sx);
    const root_sy = @max(((height + 1) * rows) - 1, w.sy);
    const root = create_cell(alloc, .topbottom, .{
        .xoff = 0,
        .yoff = 0,
        .sx = root_sx,
        .sy = root_sy,
    }) catch unreachable;

    var pane_index: usize = 0;
    for (0..rows) |_| {
        if (pane_index >= total)
            break;

        const remaining = total - pane_index;
        const row_count: usize = @min(@as(usize, columns), remaining);
        if (row_count == 1 or columns == 1) {
            const leaf = create_cell(alloc, .windowpane, .{
                .xoff = 0,
                .yoff = 0,
                .sx = root_sx,
                .sy = height,
            }) catch unreachable;
            leaf.wp = w.panes.items[pane_index];
            pane_index += 1;
            append_raw_child(root, leaf, alloc) catch unreachable;
            continue;
        }

        const row = create_cell(alloc, .leftright, .{
            .xoff = 0,
            .yoff = 0,
            .sx = root_sx,
            .sy = height,
        }) catch unreachable;
        for (0..row_count) |_| {
            const child = create_cell(alloc, .windowpane, .{
                .xoff = 0,
                .yoff = 0,
                .sx = width,
                .sy = height,
            }) catch unreachable;
            child.wp = w.panes.items[pane_index];
            pane_index += 1;
            append_raw_child(row, child, alloc) catch unreachable;
        }

        const used = @as(u32, @intCast(row.cells.items.len)) * (width + 1) - 1;
        if (row.sx > used) {
            const last = row.cells.items[row.cells.items.len - 1];
            resize_adjust(last, .leftright, @intCast(row.sx - used));
        }
        append_raw_child(root, row, alloc) catch unreachable;
    }

    const used_rows = @as(u32, @intCast(root.cells.items.len)) * height + @as(u32, @intCast(root.cells.items.len)) - 1;
    if (root.sy > used_rows) {
        const last_row = root.cells.items[root.cells.items.len - 1];
        resize_adjust(last_row, .topbottom, @intCast(root.sy - used_rows));
    }
    return root;
}

fn append_raw_child(parent: *Cell, child: *Cell, alloc: std.mem.Allocator) BuildError!void {
    child.parent = parent;
    parent.cells.append(alloc, child) catch unreachable;
}

const Builder = struct {
    arena: std.heap.ArenaAllocator,
    panes: []const *T.WindowPane,

    fn init(panes: []const *T.WindowPane) Builder {
        return .{
            .arena = std.heap.ArenaAllocator.init(xm.allocator),
            .panes = panes,
        };
    }

    fn build(self: *Builder) !*Cell {
        if (self.panes.len == 0) return BuildError.InvalidLayout;
        return try build_region(self.arena.allocator(), self.panes, union_rect(self.panes));
    }
};

fn build_region(alloc: std.mem.Allocator, panes: []const *T.WindowPane, bounds: Rect) BuildError!*Cell {
    if (panes.len == 1) {
        const pane = panes[0];
        const rect = pane_rect(pane);
        if (!rect_equal(rect, bounds))
            return BuildError.InvalidLayout;
        const leaf = try create_cell(alloc, .windowpane, bounds);
        leaf.wp = pane;
        return leaf;
    }

    if (try build_split(alloc, panes, bounds, .leftright)) |node|
        return node;
    if (try build_split(alloc, panes, bounds, .topbottom)) |node|
        return node;
    return BuildError.InvalidLayout;
}

fn build_split(
    alloc: std.mem.Allocator,
    panes: []const *T.WindowPane,
    bounds: Rect,
    type_: T.LayoutType,
) BuildError!?*Cell {
    var cuts: std.ArrayList(u32) = .{};
    for (panes) |pane| {
        const rect = pane_rect(pane);
        const cut = switch (type_) {
            .leftright => rect.xoff + rect.sx,
            .topbottom => rect.yoff + rect.sy,
            .windowpane => unreachable,
        };
        if (!cut_within_bounds(bounds, type_, cut))
            continue;
        if (contains_cut(cuts.items, cut))
            continue;
        cuts.append(alloc, cut) catch unreachable;
    }

    std.sort.heap(u32, cuts.items, {}, std.sort.asc(u32));
    for (cuts.items) |cut| {
        const partition = partition_panes(alloc, panes, type_, cut) orelse continue;

        const first_bounds = union_rect(partition.first);
        const second_bounds = union_rect(partition.second);
        if (!bounds_match_partition(bounds, first_bounds, second_bounds, type_, cut))
            continue;

        const node = try create_cell(alloc, type_, bounds);
        const first = build_region(alloc, partition.first, first_bounds) catch continue;
        const second = build_region(alloc, partition.second, second_bounds) catch continue;
        try append_child(node, first, alloc);
        try append_child(node, second, alloc);
        return node;
    }
    return null;
}

fn cut_within_bounds(bounds: Rect, type_: T.LayoutType, cut: u32) bool {
    return switch (type_) {
        .leftright => cut > bounds.xoff and cut < bounds.xoff + bounds.sx,
        .topbottom => cut > bounds.yoff and cut < bounds.yoff + bounds.sy,
        .windowpane => false,
    };
}

fn contains_cut(cuts: []const u32, cut: u32) bool {
    for (cuts) |existing| {
        if (existing == cut) return true;
    }
    return false;
}

const Partition = struct {
    first: []const *T.WindowPane,
    second: []const *T.WindowPane,
};

fn partition_panes(
    alloc: std.mem.Allocator,
    panes: []const *T.WindowPane,
    type_: T.LayoutType,
    cut: u32,
) ?Partition {
    var first: std.ArrayList(*T.WindowPane) = .{};
    var second: std.ArrayList(*T.WindowPane) = .{};

    for (panes) |pane| {
        const rect = pane_rect(pane);
        switch (type_) {
            .leftright => {
                const border = rect.xoff + rect.sx;
                if (border <= cut) {
                    first.append(alloc, pane) catch unreachable;
                } else if (rect.xoff >= cut + 1) {
                    second.append(alloc, pane) catch unreachable;
                } else {
                    return null;
                }
            },
            .topbottom => {
                const border = rect.yoff + rect.sy;
                if (border <= cut) {
                    first.append(alloc, pane) catch unreachable;
                } else if (rect.yoff >= cut + 1) {
                    second.append(alloc, pane) catch unreachable;
                } else {
                    return null;
                }
            },
            .windowpane => return null,
        }
    }

    if (first.items.len == 0 or second.items.len == 0)
        return null;
    return .{ .first = first.items, .second = second.items };
}

fn bounds_match_partition(bounds: Rect, first: Rect, second: Rect, type_: T.LayoutType, cut: u32) bool {
    return switch (type_) {
        .leftright => first.xoff == bounds.xoff and
            first.yoff == bounds.yoff and
            first.sy == bounds.sy and
            first.xoff + first.sx == cut and
            second.xoff == cut + 1 and
            second.yoff == bounds.yoff and
            second.sy == bounds.sy and
            first.sx + 1 + second.sx == bounds.sx,
        .topbottom => first.xoff == bounds.xoff and
            first.yoff == bounds.yoff and
            first.sx == bounds.sx and
            first.yoff + first.sy == cut and
            second.xoff == bounds.xoff and
            second.yoff == cut + 1 and
            second.sx == bounds.sx and
            first.sy + 1 + second.sy == bounds.sy,
        .windowpane => false,
    };
}

fn create_cell(alloc: std.mem.Allocator, type_: T.LayoutType, bounds: Rect) BuildError!*Cell {
    const cell = alloc.create(Cell) catch unreachable;
    cell.* = .{
        .type = type_,
        .xoff = bounds.xoff,
        .yoff = bounds.yoff,
        .sx = bounds.sx,
        .sy = bounds.sy,
        .cells = .{},
    };
    return cell;
}

fn append_child(parent: *Cell, child: *Cell, alloc: std.mem.Allocator) BuildError!void {
    if (child.type == parent.type) {
        for (child.cells.items) |grandchild| {
            grandchild.parent = parent;
            parent.cells.append(alloc, grandchild) catch unreachable;
        }
        return;
    }

    child.parent = parent;
    parent.cells.append(alloc, child) catch unreachable;
}

fn union_rect(panes: []const *T.WindowPane) Rect {
    std.debug.assert(panes.len != 0);
    var min_x = panes[0].xoff;
    var min_y = panes[0].yoff;
    var max_x = panes[0].xoff + panes[0].sx;
    var max_y = panes[0].yoff + panes[0].sy;

    for (panes[1..]) |pane| {
        min_x = @min(min_x, pane.xoff);
        min_y = @min(min_y, pane.yoff);
        max_x = @max(max_x, pane.xoff + pane.sx);
        max_y = @max(max_y, pane.yoff + pane.sy);
    }
    return .{
        .xoff = min_x,
        .yoff = min_y,
        .sx = max_x - min_x,
        .sy = max_y - min_y,
    };
}

fn pane_rect(wp: *T.WindowPane) Rect {
    return .{
        .xoff = wp.xoff,
        .yoff = wp.yoff,
        .sx = wp.sx,
        .sy = wp.sy,
    };
}

fn rect_equal(a: Rect, b: Rect) bool {
    return a.xoff == b.xoff and a.yoff == b.yoff and a.sx == b.sx and a.sy == b.sy;
}

fn offsetCoord(value: u32, delta: i32) ?u32 {
    const shifted = @as(i64, @intCast(value)) + delta;
    return std.math.cast(u32, shifted);
}

fn search_by_border(lc: *Cell, x: u32, y: u32) ?*Cell {
    var last: ?*Cell = null;

    for (lc.cells.items) |child| {
        if (x >= child.xoff and x < child.xoff + child.sx and y >= child.yoff and y < child.yoff + child.sy)
            return search_by_border(child, x, y);

        if (last == null) {
            last = child;
            continue;
        }

        switch (lc.type) {
            .leftright => {
                if (x < child.xoff and x >= last.?.xoff + last.?.sx)
                    return last;
            },
            .topbottom => {
                if (y < child.yoff and y >= last.?.yoff + last.?.sy)
                    return last;
            },
            .windowpane => {},
        }

        last = child;
    }

    return null;
}

fn find_leaf(root: *Cell, wp: *T.WindowPane) ?*Cell {
    if (root.type == .windowpane)
        return if (root.wp == wp) root else null;

    for (root.cells.items) |child| {
        if (find_leaf(child, wp)) |leaf|
            return leaf;
    }
    return null;
}

fn resize_leaf(root: *Cell, leaf: *Cell, type_: T.LayoutType, change: i32, opposite: bool) bool {
    var lc = leaf;
    var lcparent = lc.parent;
    while (lcparent != null and lcparent.?.type != type_) {
        lc = lcparent.?;
        lcparent = lc.parent;
    }
    const parent = lcparent orelse return false;

    if (is_last_child(parent, lc))
        lc = previous_sibling(parent, lc) orelse return false;

    return resize_layout(root, lc, type_, change, opposite);
}

fn resize_layout(root: *Cell, lc: *Cell, type_: T.LayoutType, change: i32, opposite: bool) bool {
    var needed = change;
    var changed = false;
    while (needed != 0) {
        const size = if (change > 0)
            resize_pane_grow(lc, type_, needed, opposite)
        else
            resize_pane_shrink(lc, type_, needed);
        if (size == 0)
            break;

        changed = true;
        if (change > 0)
            needed -= size
        else
            needed += size;
    }
    if (!changed)
        return false;

    fix_offsets(root);
    apply_panes(root);
    return true;
}

fn resize_pane_grow(lc: *Cell, type_: T.LayoutType, needed: i32, opposite: bool) i32 {
    var remove_cell = next_sibling(lc.parent.?, lc);
    var size: u32 = 0;

    while (remove_cell) |candidate| {
        size = resize_check(candidate, type_);
        if (size > 0)
            break;
        remove_cell = next_sibling(candidate.parent.?, candidate);
    }

    if (opposite and remove_cell == null) {
        remove_cell = previous_sibling(lc.parent.?, lc);
        while (remove_cell) |candidate| {
            size = resize_check(candidate, type_);
            if (size > 0)
                break;
            remove_cell = previous_sibling(candidate.parent.?, candidate);
        }
    }
    const remover = remove_cell orelse return 0;

    const actual: u32 = @min(size, @as(u32, @intCast(needed)));
    resize_adjust(lc, type_, @intCast(actual));
    resize_adjust(remover, type_, -@as(i32, @intCast(actual)));
    return @intCast(actual);
}

fn resize_pane_shrink(lc: *Cell, type_: T.LayoutType, needed: i32) i32 {
    var remove_cell: ?*Cell = lc;
    var size: u32 = 0;
    while (remove_cell) |candidate| {
        size = resize_check(candidate, type_);
        if (size != 0)
            break;
        remove_cell = previous_sibling(candidate.parent.?, candidate);
    }
    const remover = remove_cell orelse return 0;

    const add_cell = next_sibling(lc.parent.?, lc) orelse return 0;
    const actual: u32 = @min(size, @as(u32, @intCast(-needed)));
    resize_adjust(add_cell, type_, @intCast(actual));
    resize_adjust(remover, type_, -@as(i32, @intCast(actual)));
    return @intCast(actual);
}

fn resize_check(lc: *Cell, type_: T.LayoutType) u32 {
    if (lc.type == .windowpane) {
        const available = switch (type_) {
            .leftright => lc.sx,
            .topbottom => lc.sy,
            .windowpane => return 0,
        };
        return if (available > T.PANE_MINIMUM)
            available - T.PANE_MINIMUM
        else
            0;
    }

    if (lc.type == type_) {
        var total: u32 = 0;
        for (lc.cells.items) |child|
            total += resize_check(child, type_);
        return total;
    }

    var minimum: u32 = std.math.maxInt(u32);
    for (lc.cells.items) |child|
        minimum = @min(minimum, resize_check(child, type_));
    return minimum;
}

fn resize_adjust(lc: *Cell, type_: T.LayoutType, change: i32) void {
    switch (type_) {
        .leftright => {
            const next = @as(i64, @intCast(lc.sx)) + change;
            std.debug.assert(next >= 0);
            lc.sx = @intCast(next);
        },
        .topbottom => {
            const next = @as(i64, @intCast(lc.sy)) + change;
            std.debug.assert(next >= 0);
            lc.sy = @intCast(next);
        },
        .windowpane => unreachable,
    }

    if (lc.type != type_) {
        for (lc.cells.items) |child|
            resize_adjust(child, type_, change);
        return;
    }

    var remaining = change;
    while (remaining != 0) {
        for (lc.cells.items) |child| {
            if (remaining == 0)
                break;
            if (remaining > 0) {
                resize_adjust(child, type_, 1);
                remaining -= 1;
                continue;
            }
            if (resize_check(child, type_) > 0) {
                resize_adjust(child, type_, -1);
                remaining += 1;
            }
        }
    }
}

fn fix_offsets(root: *Cell) void {
    fix_offsets1(root);
}

fn fix_offsets1(lc: *Cell) void {
    if (lc.type == .windowpane)
        return;

    if (lc.type == .leftright) {
        var xoff = lc.xoff;
        for (lc.cells.items) |child| {
            child.xoff = xoff;
            child.yoff = lc.yoff;
            fix_offsets1(child);
            xoff += child.sx + 1;
        }
        return;
    }

    var yoff = lc.yoff;
    for (lc.cells.items) |child| {
        child.xoff = lc.xoff;
        child.yoff = yoff;
        fix_offsets1(child);
        yoff += child.sy + 1;
    }
}

fn apply_panes(lc: *Cell) void {
    if (lc.type == .windowpane) {
        const wp = lc.wp orelse return;
        wp.xoff = lc.xoff;
        wp.yoff = lc.yoff;
        win.window_pane_resize(wp, lc.sx, lc.sy);
        return;
    }

    for (lc.cells.items) |child|
        apply_panes(child);
}

fn apply_panes_skip(lc: *Cell, skip: ?*T.WindowPane) void {
    if (lc.type == .windowpane) {
        const wp = lc.wp orelse return;
        if (skip) |s| if (s == wp) return;
        wp.xoff = lc.xoff;
        wp.yoff = lc.yoff;
        win.window_pane_resize(wp, lc.sx, lc.sy);
        return;
    }

    for (lc.cells.items) |child|
        apply_panes_skip(child, skip);
}

fn is_last_child(parent: *Cell, child: *Cell) bool {
    return parent.cells.items[parent.cells.items.len - 1] == child;
}

fn next_sibling(parent: *Cell, child: *Cell) ?*Cell {
    for (parent.cells.items, 0..) |candidate, idx| {
        if (candidate != child)
            continue;
        if (idx + 1 >= parent.cells.items.len)
            return null;
        return parent.cells.items[idx + 1];
    }
    return null;
}

fn previous_sibling(parent: *Cell, child: *Cell) ?*Cell {
    for (parent.cells.items, 0..) |candidate, idx| {
        if (candidate != child)
            continue;
        if (idx == 0)
            return null;
        return parent.cells.items[idx - 1];
    }
    return null;
}

// ── tmux C-name wrappers (layout.c) for audit cross-reference ─────────────

pub const layout_resize_pane = resize_pane;
pub const layout_resize_pane_to = resize_pane_to;
pub const layout_spread_out = spread_out;

pub fn layout_create_cell(lcparent: ?*T.LayoutCell) *T.LayoutCell {
    const lc = xm.allocator.create(T.LayoutCell) catch unreachable;
    lc.* = .{
        .type = .windowpane,
        .parent = lcparent,
        .sx = std.math.maxInt(u32),
        .sy = std.math.maxInt(u32),
        .xoff = std.math.maxInt(u32),
        .yoff = std.math.maxInt(u32),
        .wp = null,
        .cells = .{},
    };
    return lc;
}

pub fn layout_free_cell(lc: *T.LayoutCell) void {
    switch (lc.type) {
        .leftright, .topbottom => {
            for (lc.cells.items) |child| {
                layout_free_cell(child);
            }
            lc.cells.deinit(xm.allocator);
        },
        .windowpane => {
            if (lc.wp) |wp| {
                wp.layout_cell = null;
            }
        },
    }
    xm.allocator.destroy(lc);
}

pub fn layout_make_leaf(lc: *T.LayoutCell, wp: *T.WindowPane) void {
    switch (lc.type) {
        .leftright, .topbottom => {
            for (lc.cells.items) |child| {
                layout_free_cell(child);
            }
            lc.cells.deinit(xm.allocator);
        },
        .windowpane => {},
    }
    lc.type = .windowpane;
    lc.cells = .{};
    if (lc.wp) |old| {
        if (old != wp) old.layout_cell = null;
    }
    wp.layout_cell = lc;
    lc.wp = wp;
}

pub fn layout_make_node(lc: *T.LayoutCell, type_: T.LayoutType) void {
    std.debug.assert(type_ != .windowpane);
    if (lc.wp) |wp| {
        wp.layout_cell = null;
        lc.wp = null;
    }
    switch (lc.type) {
        .leftright, .topbottom => {
            for (lc.cells.items) |child| {
                layout_free_cell(child);
            }
            lc.cells.deinit(xm.allocator);
        },
        .windowpane => {},
    }
    lc.type = type_;
    lc.cells = .{};
}

pub fn layout_set_size(lc: *T.LayoutCell, sx: u32, sy: u32, xoff: u32, yoff: u32) void {
    lc.sx = sx;
    lc.sy = sy;
    lc.xoff = xoff;
    lc.yoff = yoff;
}

pub fn layout_fix_offsets(w: *T.Window) void {
    const lc = w.layout_root orelse return;
    lc.xoff = 0;
    lc.yoff = 0;
    fix_offsets1(lc);
}

pub fn layout_fix_panes(w: *T.Window, skip: ?*T.WindowPane) void {
    const root = w.layout_root orelse return;
    apply_panes_skip(root, skip);
}

pub fn layout_resize(w: *T.Window, sx: u32, sy: u32) void {
    const lc = w.layout_root orelse return;
    var xchange: i32 = @as(i32, @intCast(sx)) - @as(i32, @intCast(lc.sx));
    const xlimit: i32 = @intCast(resize_check(lc, .leftright));
    if (xchange < 0 and xchange < -xlimit) xchange = -xlimit;
    if (xlimit == 0) {
        if (sx <= lc.sx)
            xchange = 0
        else
            xchange = @as(i32, @intCast(sx)) - @as(i32, @intCast(lc.sx));
    }
    if (xchange != 0)
        resize_adjust(lc, .leftright, xchange);

    var ychange: i32 = @as(i32, @intCast(sy)) - @as(i32, @intCast(lc.sy));
    const ylimit: i32 = @intCast(resize_check(lc, .topbottom));
    if (ychange < 0 and ychange < -ylimit) ychange = -ylimit;
    if (ylimit == 0) {
        if (sy <= lc.sy)
            ychange = 0
        else
            ychange = @as(i32, @intCast(sy)) - @as(i32, @intCast(lc.sy));
    }
    if (ychange != 0)
        resize_adjust(lc, .topbottom, ychange);

    layout_fix_offsets(w);
    layout_fix_panes(w, null);
}

pub fn layout_resize_check(w: *T.Window, lc: *T.LayoutCell, type_: T.LayoutType) u32 {
    _ = w;
    return resize_check(lc, type_);
}

pub fn layout_resize_adjust(w: *T.Window, lc: *T.LayoutCell, type_: T.LayoutType, change: i32) void {
    _ = w;
    resize_adjust(lc, type_, change);
}

pub fn layout_count_cells(lc: *T.LayoutCell) u32 {
    return @intCast(count_cells(lc));
}

pub fn layout_destroy_cell(w: *T.Window, lc: *T.LayoutCell) void {
    const lcparent_or_null = lc.parent;
    if (lcparent_or_null == null) {
        layout_free_cell(lc);
        w.layout_root = null;
        return;
    }
    const parent = lcparent_or_null.?;
    const idx = child_index(parent, lc) orelse return;

    const lcother: ?*T.LayoutCell = if (parent.cells.items.len > 1)
        if (idx == 0) parent.cells.items[1] else parent.cells.items[idx - 1]
    else
        null;

    if (lcother) |other| {
        if (parent.type == .leftright)
            layout_resize_adjust(w, other, .leftright, @intCast(lc.sx + 1))
        else
            layout_resize_adjust(w, other, .topbottom, @intCast(lc.sy + 1));
    }

    _ = parent.cells.orderedRemove(idx);
    layout_free_cell(lc);

    if (parent.cells.items.len != 1)
        return;

    const survivor = parent.cells.items[0];
    _ = parent.cells.orderedRemove(0);

    survivor.parent = parent.parent;
    if (survivor.parent) |grandparent| {
        const parent_idx = child_index(grandparent, parent) orelse return;
        grandparent.cells.items[parent_idx] = survivor;
    } else {
        survivor.xoff = 0;
        survivor.yoff = 0;
        w.layout_root = survivor;
    }
    layout_free_cell(parent);
}

pub fn layout_close_pane(wp: *T.WindowPane) void {
    const w = wp.window;
    const lc = wp.layout_cell orelse return;
    layout_destroy_cell(w, lc);
    if (w.layout_root != null) {
        layout_fix_offsets(w);
        layout_fix_panes(w, null);
    }
}

pub fn layout_init(w: *T.Window, wp: *T.WindowPane) void {
    const lc = layout_create_cell(null);
    w.layout_root = lc;
    layout_set_size(lc, w.sx, w.sy, 0, 0);
    layout_make_leaf(lc, wp);
    layout_fix_panes(w, null);
}

pub fn layout_free(w: *T.Window) void {
    if (w.layout_root) |root| {
        layout_free_cell(root);
        w.layout_root = null;
    }
}

pub fn layout_cell_is_top(w: *T.Window, lc: *T.LayoutCell) bool {
    var cur = lc;
    while (cur != w.layout_root) {
        const next = cur.parent orelse return true;
        if (next.type == .topbottom and next.cells.items.len > 0 and next.cells.items[0] != cur)
            return false;
        cur = next;
    }
    return true;
}

pub fn layout_cell_is_bottom(w: *T.Window, lc: *T.LayoutCell) bool {
    var cur = lc;
    while (cur != w.layout_root) {
        const next = cur.parent orelse return true;
        if (next.type == .topbottom and next.cells.items.len > 0) {
            const last = next.cells.items[next.cells.items.len - 1];
            if (last != cur) return false;
        }
        cur = next;
    }
    return true;
}

pub fn layout_add_horizontal_border(w: *T.Window, lc: *T.LayoutCell, status: i32) bool {
    if (status == T.PANE_STATUS_TOP)
        return layout_cell_is_top(w, lc);
    if (status == T.PANE_STATUS_BOTTOM)
        return layout_cell_is_bottom(w, lc);
    return false;
}

pub fn layout_spread_cell(w: *T.Window, parent: *T.LayoutCell) i32 {
    _ = w;
    return if (spread_cell(parent)) 1 else 0;
}

pub fn layout_assign_pane(lc: *T.LayoutCell, wp: *T.WindowPane, do_not_resize: i32) void {
    layout_make_leaf(lc, wp);
    if (do_not_resize != 0)
        layout_fix_panes(wp.window, wp)
    else
        layout_fix_panes(wp.window, null);
}

pub fn layout_search_by_border(lc: *T.LayoutCell, x: u32, y: u32) ?*T.LayoutCell {
    return search_by_border(lc, x, y);
}

pub fn layout_resize_layout(w: *T.Window, lc: *T.LayoutCell, type_: T.LayoutType, change: i32, opposite: bool) bool {
    const root = w.layout_root orelse return false;
    return resize_layout(root, lc, type_, change, opposite);
}

pub fn layout_resize_pane_grow(w: *T.Window, lc: *T.LayoutCell, type_: T.LayoutType, needed: i32, opposite: bool) i32 {
    _ = w;
    return resize_pane_grow(lc, type_, needed, opposite);
}

pub fn layout_resize_pane_shrink(w: *T.Window, lc: *T.LayoutCell, type_: T.LayoutType, needed: i32) i32 {
    _ = w;
    return resize_pane_shrink(lc, type_, needed);
}

/// Calculate the new pane size for resized parent.
/// Ported from tmux layout_new_pane_size.
pub fn layout_new_pane_size(
    w: *T.Window,
    previous: u32,
    lc: *T.LayoutCell,
    type_: T.LayoutType,
    size: u32,
    count_left: u32,
    size_left: u32,
) u32 {
    // If this is the last cell, it can take all of the remaining size.
    if (count_left == 1)
        return size_left;

    // How much is available in this parent?
    const available = layout_resize_check(w, lc, type_);

    // Work out the minimum size of this cell and the new size
    // proportionate to the previous size.
    var min: u32 = (T.PANE_MINIMUM + 1) * (count_left - 1);
    var new_size: u32 = undefined;
    switch (type_) {
        .leftright => {
            const floor = lc.sx -| available;
            if (floor > min) min = floor;
            new_size = if (previous == 0) T.PANE_MINIMUM else (lc.sx * size) / previous;
        },
        .topbottom => {
            const floor = lc.sy -| available;
            if (floor > min) min = floor;
            new_size = if (previous == 0) T.PANE_MINIMUM else (lc.sy * size) / previous;
        },
        .windowpane => return T.PANE_MINIMUM,
    }

    // Check against the maximum and minimum size.
    const max = size_left -| min;
    if (new_size > max)
        new_size = max;
    if (new_size < T.PANE_MINIMUM)
        new_size = T.PANE_MINIMUM;
    return new_size;
}

/// Check if the cell and all its children can be resized to a specific size.
/// Ported from tmux layout_set_size_check.
pub fn layout_set_size_check(w: *T.Window, lc: *T.LayoutCell, type_: T.LayoutType, size: i32) bool {
    const usize_val: u32 = if (size < 0) return false else @intCast(size);

    if (lc.type == .windowpane)
        return usize_val >= T.PANE_MINIMUM;

    var available_space = usize_val;
    const count: u32 = @intCast(lc.cells.items.len);
    if (count == 0) return true;

    if (lc.type == type_) {
        if (available_space < (count * 2) - 1)
            return false;

        const previous: u32 = switch (type_) {
            .leftright => lc.sx,
            .topbottom => lc.sy,
            .windowpane => return false,
        };

        for (lc.cells.items, 0..) |child, idx| {
            const new_child_size = layout_new_pane_size(
                w,
                previous,
                child,
                type_,
                usize_val,
                count - @as(u32, @intCast(idx)),
                available_space,
            );
            if (idx == count - 1) {
                if (new_child_size > available_space)
                    return false;
                available_space -= new_child_size;
            } else {
                if (new_child_size + 1 > available_space)
                    return false;
                available_space -= new_child_size + 1;
            }
            if (!layout_set_size_check(w, child, type_, @intCast(new_child_size)))
                return false;
        }
    } else {
        for (lc.cells.items) |child| {
            if (child.type == .windowpane)
                continue;
            if (!layout_set_size_check(w, child, type_, size))
                return false;
        }
    }

    return true;
}

/// Resize all child cells to fit within the current cell.
/// Ported from tmux layout_resize_child_cells.
fn layout_resize_child_cells(w: *T.Window, lc: *T.LayoutCell) void {
    if (lc.type == .windowpane)
        return;

    var count: u32 = 0;
    var previous: u32 = 0;
    for (lc.cells.items) |child| {
        count += 1;
        if (lc.type == .leftright)
            previous += child.sx
        else if (lc.type == .topbottom)
            previous += child.sy;
    }
    if (count > 0)
        previous += (count - 1);

    var available: u32 = 0;
    if (lc.type == .leftright)
        available = lc.sx
    else if (lc.type == .topbottom)
        available = lc.sy;

    for (lc.cells.items, 0..) |child, idx| {
        if (lc.type == .topbottom) {
            child.sx = lc.sx;
            child.xoff = lc.xoff;
        } else {
            child.sx = layout_new_pane_size(w, previous, child, lc.type, lc.sx, count - @as(u32, @intCast(idx)), available);
            available -|= (child.sx + 1);
        }
        if (lc.type == .leftright) {
            child.sy = lc.sy;
        } else {
            child.sy = layout_new_pane_size(w, previous, child, lc.type, lc.sy, count - @as(u32, @intCast(idx)), available);
            available -|= (child.sy + 1);
        }
        layout_resize_child_cells(w, child);
    }
}

/// Split a pane into two. size is a hint, or -1 for default half/half split.
/// This must be followed by layout_assign_pane before much else happens!
/// Ported from tmux layout_split_pane.
pub fn layout_split_pane(wp: *T.WindowPane, type_: T.LayoutType, size_arg: i32, flags: i32) ?*T.LayoutCell {
    if (type_ != .leftright and type_ != .topbottom)
        return null;

    const full_size = (flags & @as(i32, @intCast(T.SPAWN_FULLSIZE))) != 0;
    const before = (flags & @as(i32, @intCast(T.SPAWN_BEFORE))) != 0;

    // If full_size is specified, add a new cell at the top of the window
    // layout. Otherwise, split the cell for the current pane.
    const lc: *T.LayoutCell = if (full_size)
        wp.window.layout_root orelse return null
    else
        wp.layout_cell orelse return null;

    const sx = lc.sx;
    const sy = lc.sy;
    const xoff = lc.xoff;
    const yoff = lc.yoff;

    const minimum: u32 = T.PANE_MINIMUM * 2 + 1;
    switch (type_) {
        .leftright => if (sx < minimum) return null,
        .topbottom => if (sy < minimum) return null,
        .windowpane => return null,
    }

    // Calculate new cell sizes. size is the target size or -1 for middle
    // split, size1 is the size of the top/left and size2 the bottom/right.
    const saved_size: u32 = if (type_ == .leftright) sx else sy;
    var size: i32 = size_arg;
    var size2: u32 = if (size < 0)
        ((saved_size + 1) / 2) - 1
    else if (before)
        saved_size -| @as(u32, @intCast(size)) -| 1
    else
        @intCast(size);

    if (size2 < T.PANE_MINIMUM)
        size2 = T.PANE_MINIMUM
    else if (size2 > saved_size - 2)
        size2 = saved_size - 2;
    const size1: u32 = saved_size - 1 - size2;

    const new_size: u32 = if (before) size2 else size1;
    if (full_size and !layout_set_size_check(wp.window, lc, type_, @intCast(new_size)))
        return null;

    var lcnew: *T.LayoutCell = undefined;
    var resize_first: bool = false;

    if (lc.parent != null and lc.parent.?.type == type_) {
        // If the parent exists and is of the same type as the split,
        // create a new cell and insert it after this one.
        const lcparent = lc.parent.?;
        lcnew = layout_create_cell(lcparent);
        const lc_idx = child_index(lcparent, lc) orelse return null;
        if (before) {
            lcparent.cells.insert(xm.allocator, lc_idx, lcnew) catch unreachable;
        } else {
            lcparent.cells.insert(xm.allocator, lc_idx + 1, lcnew) catch unreachable;
        }
    } else if (full_size and lc.parent == null and lc.type == type_) {
        // If the new full size pane is the same type as the root split,
        // insert the new pane under the existing root cell instead of
        // creating a new root cell. The existing layout must be resized
        // before inserting the new cell.
        if (type_ == .leftright) {
            lc.sx = new_size;
            layout_resize_child_cells(wp.window, lc);
            lc.sx = saved_size;
        } else if (type_ == .topbottom) {
            lc.sy = new_size;
            layout_resize_child_cells(wp.window, lc);
            lc.sy = saved_size;
        }
        resize_first = true;
        lcnew = layout_create_cell(lc);
        size = @as(i32, @intCast(saved_size)) - 1 - @as(i32, @intCast(new_size));
        if (type_ == .leftright)
            layout_set_size(lcnew, @intCast(size), sy, 0, 0)
        else if (type_ == .topbottom)
            layout_set_size(lcnew, sx, @intCast(size), 0, 0);
        if (before)
            lc.cells.insert(xm.allocator, 0, lcnew) catch unreachable
        else
            lc.cells.append(xm.allocator, lcnew) catch unreachable;
    } else {
        // New parent: wrap lc and lcnew under a fresh container.
        const lcparent = layout_create_cell(lc.parent);
        layout_make_node(lcparent, type_);
        layout_set_size(lcparent, sx, sy, xoff, yoff);
        if (lc.parent == null) {
            wp.window.layout_root = lcparent;
        } else {
            const grandparent = lc.parent.?;
            const lc_idx = child_index(grandparent, lc) orelse return null;
            grandparent.cells.items[lc_idx] = lcparent;
        }

        lc.parent = lcparent;
        lcparent.cells.append(xm.allocator, lc) catch unreachable;

        lcnew = layout_create_cell(lcparent);
        if (before)
            lcparent.cells.insert(xm.allocator, 0, lcnew) catch unreachable
        else
            lcparent.cells.append(xm.allocator, lcnew) catch unreachable;
    }

    const lc1: *T.LayoutCell = if (before) lcnew else lc;
    const lc2: *T.LayoutCell = if (before) lc else lcnew;

    // Set new cell sizes. size1 is the size of the top/left and size2 the
    // bottom/right.
    if (!resize_first and type_ == .leftright) {
        layout_set_size(lc1, size1, sy, xoff, yoff);
        layout_set_size(lc2, size2, sy, xoff + lc1.sx + 1, yoff);
    } else if (!resize_first and type_ == .topbottom) {
        layout_set_size(lc1, sx, size1, xoff, yoff);
        layout_set_size(lc2, sx, size2, xoff, yoff + lc1.sy + 1);
    }
    if (full_size) {
        if (!resize_first)
            layout_resize_child_cells(wp.window, lc);
        layout_fix_offsets(wp.window);
    } else {
        layout_make_leaf(lc, wp);
    }

    return lcnew;
}

// ── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

fn test_setup_window(sx: u32, sy: u32) *T.Window {
    opts.global_w_options = opts.options_create(null);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    win.window_init_globals(xm.allocator);
    return win.window_create(sx, sy, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
}

fn test_teardown_window(w: *T.Window) void {
    if (w.saved_layout_root) |saved| {
        layout_free_cell(saved);
        w.saved_layout_root = null;
    }
    while (w.panes.items.len > 0) {
        const wp = w.panes.items[w.panes.items.len - 1];
        win.window_remove_pane(w, wp);
    }
    w.panes.deinit(xm.allocator);
    w.last_panes.deinit(xm.allocator);
    opts.options_free(w.options);
    xm.allocator.free(w.name);
    _ = win.windows.remove(w.id);
    xm.allocator.destroy(w);
}

test "layout_split_pane splits a single pane vertically" {
    const w = test_setup_window(80, 24);
    defer test_teardown_window(w);

    const wp = win.window_add_pane(w, null, 80, 24);
    layout_init(w, wp);

    const lcnew = layout_split_pane(wp, .topbottom, -1, 0) orelse
        return error.SplitFailed;

    try testing.expect(lcnew.type == .windowpane);
    try testing.expect(wp.layout_cell != null);
    try testing.expect(wp.layout_cell.?.parent != null);
    try testing.expectEqual(T.LayoutType.topbottom, wp.layout_cell.?.parent.?.type);

    // Sizes should add up: size1 + 1 (border) + size2 = 24.
    const lc_orig = wp.layout_cell.?;
    try testing.expectEqual(@as(u32, 24), lc_orig.sy + 1 + lcnew.sy);
    try testing.expectEqual(@as(u32, 80), lc_orig.sx);
    try testing.expectEqual(@as(u32, 80), lcnew.sx);
}

test "layout_split_pane splits a single pane horizontally" {
    const w = test_setup_window(80, 24);
    defer test_teardown_window(w);

    const wp = win.window_add_pane(w, null, 80, 24);
    layout_init(w, wp);

    const lcnew = layout_split_pane(wp, .leftright, -1, 0) orelse
        return error.SplitFailed;

    try testing.expect(lcnew.type == .windowpane);
    const lc_orig = wp.layout_cell.?;
    try testing.expectEqual(T.LayoutType.leftright, lc_orig.parent.?.type);
    try testing.expectEqual(@as(u32, 80), lc_orig.sx + 1 + lcnew.sx);
    try testing.expectEqual(@as(u32, 24), lc_orig.sy);
    try testing.expectEqual(@as(u32, 24), lcnew.sy);
}

test "layout_split_pane with explicit size" {
    const w = test_setup_window(80, 24);
    defer test_teardown_window(w);

    const wp = win.window_add_pane(w, null, 80, 24);
    layout_init(w, wp);

    const lcnew = layout_split_pane(wp, .leftright, 20, 0) orelse
        return error.SplitFailed;

    const lc_orig = wp.layout_cell.?;
    // size2 = 20, size1 = 80 - 1 - 20 = 59
    try testing.expectEqual(@as(u32, 59), lc_orig.sx);
    try testing.expectEqual(@as(u32, 20), lcnew.sx);
}

test "layout_split_pane with SPAWN_BEFORE inserts before the target" {
    const w = test_setup_window(80, 24);
    defer test_teardown_window(w);

    const wp = win.window_add_pane(w, null, 80, 24);
    layout_init(w, wp);

    const before_flags: i32 = @intCast(T.SPAWN_BEFORE);
    const lcnew = layout_split_pane(wp, .topbottom, -1, before_flags) orelse
        return error.SplitFailed;

    const parent = wp.layout_cell.?.parent.?;
    try testing.expect(parent.cells.items.len == 2);
    try testing.expectEqual(lcnew, parent.cells.items[0]);
    try testing.expectEqual(wp.layout_cell.?, parent.cells.items[1]);
}

test "layout_split_pane rejects split when too small" {
    const w = test_setup_window(2, 2);
    defer test_teardown_window(w);

    const wp = win.window_add_pane(w, null, 2, 2);
    layout_init(w, wp);

    // 2x2 is too small for PANE_MINIMUM*2+1 = 3.
    try testing.expectEqual(@as(?*T.LayoutCell, null), layout_split_pane(wp, .topbottom, -1, 0));
    try testing.expectEqual(@as(?*T.LayoutCell, null), layout_split_pane(wp, .leftright, -1, 0));
}

test "layout_split_pane merges into existing same-type parent" {
    const w = test_setup_window(80, 24);
    defer test_teardown_window(w);

    const wp1 = win.window_add_pane(w, null, 80, 24);
    layout_init(w, wp1);

    // First split: creates a topbottom parent.
    const lc2 = layout_split_pane(wp1, .topbottom, -1, 0) orelse
        return error.SplitFailed;

    // Assign the second pane to the new cell.
    const wp2 = win.window_add_pane(w, null, 80, 12);
    layout_assign_pane(lc2, wp2, 0);

    _ = layout_split_pane(wp1, .topbottom, -1, 0) orelse
        return error.SplitFailed;

    const parent = wp1.layout_cell.?.parent.?;
    try testing.expectEqual(@as(usize, 3), parent.cells.items.len);
}

test "layout_set_size_check validates minimum sizes" {
    const w = test_setup_window(80, 24);
    defer test_teardown_window(w);

    const wp = win.window_add_pane(w, null, 80, 24);
    layout_init(w, wp);

    const lc = wp.layout_cell.?;
    try testing.expect(layout_set_size_check(w, lc, .leftright, @intCast(T.PANE_MINIMUM)));
    try testing.expect(!layout_set_size_check(w, lc, .leftright, 0));
}

test "layout_set_size_check validates topbottom minimum sizes" {
    const w = test_setup_window(80, 24);
    defer test_teardown_window(w);

    const wp = win.window_add_pane(w, null, 80, 24);
    layout_init(w, wp);

    const lc = wp.layout_cell.?;
    try testing.expect(layout_set_size_check(w, lc, .topbottom, @intCast(T.PANE_MINIMUM)));
    try testing.expect(!layout_set_size_check(w, lc, .topbottom, 0));
}

test "layout_new_pane_size gives remaining space to last cell" {
    const w = test_setup_window(80, 24);
    defer test_teardown_window(w);

    const wp = win.window_add_pane(w, null, 80, 24);
    layout_init(w, wp);

    const lc = wp.layout_cell.?;
    try testing.expectEqual(@as(u32, 42), layout_new_pane_size(w, 80, lc, .leftright, 80, 1, 42));
}

test "layout_close_pane removes a cell and restores space" {
    const w = test_setup_window(80, 24);
    defer test_teardown_window(w);

    const wp1 = win.window_add_pane(w, null, 80, 24);
    layout_init(w, wp1);

    const lc2 = layout_split_pane(wp1, .leftright, -1, 0) orelse
        return error.SplitFailed;
    const wp2 = win.window_add_pane(w, null, 40, 24);
    layout_assign_pane(lc2, wp2, 0);

    layout_close_pane(wp2);

    const root = w.layout_root.?;
    try testing.expectEqual(T.LayoutType.windowpane, root.type);
    try testing.expectEqual(@as(u32, 80), root.sx);
    try testing.expectEqual(@as(u32, 24), root.sy);
}

test "zoom saves and restores layout" {
    const w = test_setup_window(80, 24);
    defer test_teardown_window(w);

    const wp1 = win.window_add_pane(w, null, 80, 24);
    layout_init(w, wp1);

    const lc2 = layout_split_pane(wp1, .leftright, -1, 0) orelse
        return error.SplitFailed;
    const wp2 = win.window_add_pane(w, null, 40, 24);
    layout_assign_pane(lc2, wp2, 0);

    const orig_sx1 = wp1.layout_cell.?.sx;
    const orig_sx2 = wp2.layout_cell.?.sx;

    // Zoom on wp1.
    try testing.expect(win.window_zoom(wp1));
    try testing.expect(w.flags & T.WINDOW_ZOOMED != 0);
    try testing.expect(w.saved_layout_root != null);

    // After zoom, wp1 should have a fresh single-pane layout.
    try testing.expect(wp1.layout_cell != null);
    try testing.expectEqual(@as(u32, 80), wp1.layout_cell.?.sx);
    try testing.expectEqual(@as(u32, 24), wp1.layout_cell.?.sy);

    // Unzoom.
    try testing.expect(win.window_unzoom(w));
    try testing.expectEqual(@as(u32, 0), w.flags & T.WINDOW_ZOOMED);
    try testing.expect(w.saved_layout_root == null);

    // Layout should be restored.
    try testing.expect(wp1.layout_cell != null);
    try testing.expect(wp2.layout_cell != null);
    try testing.expectEqual(orig_sx1, wp1.layout_cell.?.sx);
    try testing.expectEqual(orig_sx2, wp2.layout_cell.?.sx);
}

test "dump_window prefers layout_root over pane rectangles" {
    const w = test_setup_window(80, 24);
    defer test_teardown_window(w);

    const wp1 = win.window_add_pane(w, null, 80, 24);
    layout_init(w, wp1);

    const lc2 = layout_split_pane(wp1, .leftright, -1, 0) orelse
        return error.SplitFailed;
    const wp2 = win.window_add_pane(w, null, 40, 24);
    layout_assign_pane(lc2, wp2, 0);

    const root_dump = dump_root(w.layout_root.?).?;
    defer xm.allocator.free(root_dump);

    wp1.sx = 70;
    wp2.xoff = 71;
    wp2.sx = 9;

    const window_dump = dump_window(w).?;
    defer xm.allocator.free(window_dump);
    try testing.expectEqualStrings(root_dump, window_dump);
}

test "spread_out prefers layout_cell parents over stale pane rectangles" {
    const w = test_setup_window(80, 24);
    defer test_teardown_window(w);

    const wp1 = win.window_add_pane(w, null, 80, 24);
    layout_init(w, wp1);

    const bottom_cell = layout_split_pane(wp1, .topbottom, -1, 0) orelse
        return error.SplitFailed;
    const wp2 = win.window_add_pane(w, null, 80, 12);
    layout_assign_pane(bottom_cell, wp2, 0);

    const right_cell = layout_split_pane(wp1, .leftright, -1, 0) orelse
        return error.SplitFailed;
    const wp3 = win.window_add_pane(w, null, 40, 12);
    layout_assign_pane(right_cell, wp3, 0);

    layout_resize_adjust(w, wp1.layout_cell.?, .leftright, -10);
    layout_fix_offsets(w);
    layout_fix_panes(w, null);
    try testing.expect(wp1.layout_cell.?.sx != wp3.layout_cell.?.sx);

    wp1.xoff = 0;
    wp1.yoff = 0;
    wp1.sx = 80;
    wp1.sy = 11;
    wp3.xoff = 0;
    wp3.yoff = 0;
    wp3.sx = 80;
    wp3.sy = 11;

    try testing.expect(spread_out(wp1));
    const top_left = wp1.layout_cell.?.sx;
    const top_right = wp3.layout_cell.?.sx;
    try testing.expect(top_left == top_right or top_left == top_right + 1 or top_right == top_left + 1);
    try testing.expectEqual(@as(u32, 80), wp2.layout_cell.?.sx);
}
