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

//! layout-test.zig – focused coverage for layout mutation semantics.

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const opts = @import("options.zig");
const win = @import("window.zig");
const layout_mod = @import("layout.zig");

const testing = std.testing;

const Fixture = struct {
    w: *T.Window,

    fn init(sx: u32, sy: u32) Fixture {
        opts.global_w_options = opts.options_create(null);
        opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
        win.window_init_globals(xm.allocator);
        return .{ .w = win.window_create(sx, sy, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL) };
    }

    fn deinit(self: *Fixture) void {
        if (self.w.saved_layout_root) |saved| {
            layout_mod.layout_free_cell(saved);
            self.w.saved_layout_root = null;
        }
        while (self.w.panes.items.len > 0) {
            const wp = self.w.panes.items[self.w.panes.items.len - 1];
            win.window_remove_pane(self.w, wp);
        }
        self.w.panes.deinit(xm.allocator);
        self.w.last_panes.deinit(xm.allocator);
        opts.options_free(self.w.options);
        xm.allocator.free(self.w.name);
        _ = win.windows.remove(self.w.id);
        xm.allocator.destroy(self.w);
        opts.options_free(opts.global_w_options);
    }
};

fn initSinglePaneWindow(sx: u32, sy: u32) struct { fixture: Fixture, pane: *T.WindowPane } {
    const fixture = Fixture.init(sx, sy);
    const pane = win.window_add_pane(fixture.w, null, sx, sy);
    layout_mod.layout_init(fixture.w, pane);
    return .{ .fixture = fixture, .pane = pane };
}

fn splitAssign(target: *T.WindowPane, type_: T.LayoutType, size: i32, flags: i32) !*T.WindowPane {
    const cell = layout_mod.layout_split_pane(target, type_, size, flags) orelse return error.SplitFailed;
    const pane = win.window_add_pane_with_flags(target.window, null, cell.sx, cell.sy, @intCast(flags));
    layout_mod.layout_assign_pane(cell, pane, 0);
    return pane;
}

fn snapshotLayout(w: *T.Window) ![]u8 {
    return layout_mod.dump_root(w.layout_root.?) orelse error.OutOfMemory;
}

fn expectLayoutInvariants(w: *T.Window) !void {
    const root = w.layout_root orelse return error.MissingRoot;
    try testing.expect(root.parent == null);
    try testing.expectEqual(w.sx, root.sx);
    try testing.expectEqual(w.sy, root.sy);
    const leaves = try expectCellInvariants(root, null);
    try testing.expectEqual(w.panes.items.len, leaves);
    for (w.panes.items) |wp| {
        try testing.expect(wp.layout_cell != null);
        try testing.expectEqual(wp.xoff, wp.layout_cell.?.xoff);
        try testing.expectEqual(wp.yoff, wp.layout_cell.?.yoff);
        try testing.expectEqual(wp.sx, wp.layout_cell.?.sx);
        try testing.expectEqual(wp.sy, wp.layout_cell.?.sy);
    }
}

fn expectCellInvariants(lc: *T.LayoutCell, parent: ?*T.LayoutCell) !usize {
    try testing.expectEqual(parent, lc.parent);
    switch (lc.type) {
        .windowpane => {
            try testing.expectEqual(@as(usize, 0), lc.cells.items.len);
            const wp = lc.wp orelse return error.MissingPane;
            try testing.expectEqual(lc, wp.layout_cell.?);
            try testing.expectEqual(lc.xoff, wp.xoff);
            try testing.expectEqual(lc.yoff, wp.yoff);
            try testing.expectEqual(lc.sx, wp.sx);
            try testing.expectEqual(lc.sy, wp.sy);
            return 1;
        },
        .leftright => {
            try testing.expect(lc.wp == null);
            try testing.expect(lc.cells.items.len >= 2);
            var cursor = lc.xoff;
            var leaves: usize = 0;
            for (lc.cells.items, 0..) |child, idx| {
                try testing.expectEqual(cursor, child.xoff);
                try testing.expectEqual(lc.yoff, child.yoff);
                try testing.expectEqual(lc.sy, child.sy);
                cursor += child.sx;
                if (idx + 1 < lc.cells.items.len) cursor += 1;
                leaves += try expectCellInvariants(child, lc);
            }
            try testing.expectEqual(lc.xoff + lc.sx, cursor);
            return leaves;
        },
        .topbottom => {
            try testing.expect(lc.wp == null);
            try testing.expect(lc.cells.items.len >= 2);
            var cursor = lc.yoff;
            var leaves: usize = 0;
            for (lc.cells.items, 0..) |child, idx| {
                try testing.expectEqual(lc.xoff, child.xoff);
                try testing.expectEqual(cursor, child.yoff);
                try testing.expectEqual(lc.sx, child.sx);
                cursor += child.sy;
                if (idx + 1 < lc.cells.items.len) cursor += 1;
                leaves += try expectCellInvariants(child, lc);
            }
            try testing.expectEqual(lc.yoff + lc.sy, cursor);
            return leaves;
        },
    }
}

test "layout split sequences keep tmux-style pane geometry" {
    var state = initSinglePaneWindow(80, 24);
    defer state.fixture.deinit();

    const second = try splitAssign(state.pane, .leftright, 25, 0);
    const third = try splitAssign(state.pane, .topbottom, -1, 0);

    try testing.expectEqual(@as(u32, 0), state.pane.xoff);
    try testing.expectEqual(@as(u32, 0), state.pane.yoff);
    try testing.expectEqual(@as(u32, 54), state.pane.sx);
    try testing.expectEqual(@as(u32, 12), state.pane.sy);

    try testing.expectEqual(@as(u32, 0), third.xoff);
    try testing.expectEqual(@as(u32, 13), third.yoff);
    try testing.expectEqual(@as(u32, 54), third.sx);
    try testing.expectEqual(@as(u32, 11), third.sy);

    try testing.expectEqual(@as(u32, 55), second.xoff);
    try testing.expectEqual(@as(u32, 0), second.yoff);
    try testing.expectEqual(@as(u32, 25), second.sx);
    try testing.expectEqual(@as(u32, 24), second.sy);
    try expectLayoutInvariants(state.fixture.w);
}

test "layout resize sequences preserve geometry totals and parent links" {
    var state = initSinglePaneWindow(80, 24);
    defer state.fixture.deinit();

    const second = try splitAssign(state.pane, .leftright, 25, 0);
    const third = try splitAssign(state.pane, .topbottom, -1, 0);

    try testing.expect(layout_mod.layout_resize_pane(state.pane, .leftright, 10, true));
    try testing.expect(layout_mod.layout_resize_pane_to(third, .topbottom, 8));

    try testing.expectEqual(@as(u32, 64), state.pane.sx);
    try testing.expectEqual(@as(u32, 15), state.pane.sy);
    try testing.expectEqual(@as(u32, 64), third.sx);
    try testing.expectEqual(@as(u32, 8), third.sy);
    try testing.expectEqual(@as(u32, 16), third.yoff);
    try testing.expectEqual(@as(u32, 65), second.xoff);
    try testing.expectEqual(@as(u32, 15), second.sx);
    try testing.expectEqual(@as(u32, 24), second.sy);
    try expectLayoutInvariants(state.fixture.w);
}

test "layout resize without a matching ancestor leaves the tree unchanged" {
    var state = initSinglePaneWindow(80, 24);
    defer state.fixture.deinit();

    const before = try snapshotLayout(state.fixture.w);
    defer xm.allocator.free(before);

    try testing.expect(!layout_mod.layout_resize_pane_to(state.pane, .leftright, 20));

    const after = try snapshotLayout(state.fixture.w);
    defer xm.allocator.free(after);
    try testing.expectEqualStrings(before, after);
    try expectLayoutInvariants(state.fixture.w);
}

test "layout spread_out mirrors tmux even-spread semantics" {
    var state = initSinglePaneWindow(80, 24);
    defer state.fixture.deinit();

    const second = try splitAssign(state.pane, .leftright, 20, 0);
    const third = try splitAssign(state.pane, .leftright, 20, 0);

    _ = second;
    try testing.expectEqual(@as(u32, 38), state.pane.sx);
    try testing.expectEqual(@as(u32, 20), third.sx);

    try testing.expect(layout_mod.layout_spread_out(state.pane));

    const root = state.fixture.w.layout_root.?;
    try testing.expectEqual(T.LayoutType.leftright, root.type);
    try testing.expectEqual(@as(usize, 3), root.cells.items.len);
    for (root.cells.items) |child| {
        try testing.expectEqual(@as(u32, 26), child.sx);
    }
    try expectLayoutInvariants(state.fixture.w);
}

test "layout full-size split failure at minimum widths is transactional" {
    var state = initSinglePaneWindow(5, 3);
    defer state.fixture.deinit();

    const second = try splitAssign(state.pane, .leftright, 1, 0);
    const third = try splitAssign(state.pane, .leftright, 1, 0);

    try testing.expectEqual(@as(u32, T.PANE_MINIMUM), state.pane.sx);
    try testing.expectEqual(@as(u32, T.PANE_MINIMUM), second.sx);
    try testing.expectEqual(@as(u32, T.PANE_MINIMUM), third.sx);
    try expectLayoutInvariants(state.fixture.w);

    const before = try snapshotLayout(state.fixture.w);
    defer xm.allocator.free(before);

    try testing.expectEqual(@as(?*T.LayoutCell, null), layout_mod.layout_split_pane(second, .leftright, -1, @intCast(T.SPAWN_FULLSIZE)));

    const after = try snapshotLayout(state.fixture.w);
    defer xm.allocator.free(after);
    try testing.expectEqualStrings(before, after);
    try expectLayoutInvariants(state.fixture.w);
}
