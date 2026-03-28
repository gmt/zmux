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
const T = @import("types.zig");
const xm = @import("xmalloc.zig");

const Rect = struct {
    xoff: u32,
    yoff: u32,
    sx: u32,
    sy: u32,
};

const Cell = struct {
    type: T.LayoutType,
    parent: ?*Cell = null,
    xoff: u32,
    yoff: u32,
    sx: u32,
    sy: u32,
    wp: ?*T.WindowPane = null,
    cells: std.ArrayList(*Cell),
};

const BuildError = error{
    InvalidLayout,
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
        wp.sx = lc.sx;
        wp.sy = lc.sy;
        return;
    }

    for (lc.cells.items) |child|
        apply_panes(child);
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
