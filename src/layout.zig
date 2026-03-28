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

pub fn dump_window(w: *T.Window) ?[]u8 {
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
