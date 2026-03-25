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
// Ported in part from tmux/screen.c.
// Original copyright:
//   Copyright (c) 2009 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

//! screen.zig – shared screen lifecycle helpers.

const std = @import("std");
const T = @import("types.zig");
const grid = @import("grid.zig");

pub fn screen_init(sx: u32, sy: u32, hlimit: u32) *T.Screen {
    const g = grid.grid_create(sx, sy, hlimit);
    const s = @import("xmalloc.zig").allocator.create(T.Screen) catch unreachable;
    s.* = .{
        .grid = g,
        .rlower = if (sy == 0) 0 else sy - 1,
    };
    return s;
}

pub fn screen_reset(s: *T.Screen) void {
    grid.grid_reset(s.grid);
    s.cx = 0;
    s.cy = 0;
    s.saved_cx = 0;
    s.saved_cy = 0;
    s.rupper = 0;
    s.rlower = if (s.grid.sy == 0) 0 else s.grid.sy - 1;
}

pub fn screen_resize(s: *T.Screen, sx: u32, sy: u32) void {
    _ = sx;
    _ = sy;
    // Reduced for now: window/pane resize still owns geometry truth.
    if (s.cx >= s.grid.sx) s.cx = if (s.grid.sx == 0) 0 else s.grid.sx - 1;
    if (s.cy >= s.grid.sy) s.cy = if (s.grid.sy == 0) 0 else s.grid.sy - 1;
    s.rlower = if (s.grid.sy == 0) 0 else s.grid.sy - 1;
}

test "screen_reset clears cursor and region state" {
    const s = screen_init(4, 2, 100);
    defer {
        grid.grid_free(s.grid);
        @import("xmalloc.zig").allocator.destroy(s);
    }

    s.cx = 2;
    s.cy = 1;
    s.rupper = 1;
    s.rlower = 1;
    screen_reset(s);

    try std.testing.expectEqual(@as(u32, 0), s.cx);
    try std.testing.expectEqual(@as(u32, 0), s.cy);
    try std.testing.expectEqual(@as(u32, 0), s.rupper);
    try std.testing.expectEqual(@as(u32, 1), s.rlower);
}
