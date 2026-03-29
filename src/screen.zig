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
const hyperlinks = @import("hyperlinks.zig");
const xm = @import("xmalloc.zig");
const utf8 = @import("utf8.zig");

pub fn screen_init(sx: u32, sy: u32, hlimit: u32) *T.Screen {
    const g = grid.grid_create(sx, sy, hlimit);
    const s = @import("xmalloc.zig").allocator.create(T.Screen) catch unreachable;
    s.* = .{
        .grid = g,
        .mode = T.MODE_CURSOR | T.MODE_WRAP,
        .rlower = if (sy == 0) 0 else sy - 1,
    };
    screen_reset_tabs(s);
    screen_reset_hyperlinks(s);
    return s;
}

pub fn screen_free(s: *T.Screen) void {
    if (s.title) |title| xm.allocator.free(title);
    if (s.path) |path| xm.allocator.free(path);
    if (s.tabs) |tabs| xm.allocator.free(tabs);
    if (s.hyperlinks) |hl| hyperlinks.hyperlinks_free(hl);
    grid.grid_free(s.grid);
    s.* = undefined;
}

pub fn screen_reset(s: *T.Screen) void {
    grid.grid_reset(s.grid);
    s.cx = 0;
    s.cy = 0;
    s.rupper = 0;
    s.rlower = if (s.grid.sy == 0) 0 else s.grid.sy - 1;
    s.mode = T.MODE_CURSOR | T.MODE_WRAP;
    s.cursor_visible = true;
    s.bracketed_paste = false;
    s.saved_cx = 0;
    s.saved_cy = 0;
    s.saved_grid = null;
    screen_reset_tabs(s);
    screen_reset_hyperlinks(s);
}

pub fn screen_resize(s: *T.Screen, sx: u32, sy: u32) void {
    _ = sx;
    _ = sy;
    // Reduced for now: window/pane resize still owns geometry truth.
    if (s.cx >= s.grid.sx) s.cx = if (s.grid.sx == 0) 0 else s.grid.sx - 1;
    if (s.cy >= s.grid.sy) s.cy = if (s.grid.sy == 0) 0 else s.grid.sy - 1;
    s.rlower = if (s.grid.sy == 0) 0 else s.grid.sy - 1;
}

pub fn screen_reset_active(s: *T.Screen) void {
    grid.grid_reset(s.grid);
    s.cx = 0;
    s.cy = 0;
    s.rupper = 0;
    s.rlower = if (s.grid.sy == 0) 0 else s.grid.sy - 1;
    s.mode = T.MODE_CURSOR | T.MODE_WRAP;
    s.cursor_visible = true;
    s.bracketed_paste = false;
    screen_reset_tabs(s);
    screen_reset_hyperlinks(s);
}

pub fn screen_reset_hyperlinks(s: *T.Screen) void {
    if (s.hyperlinks) |hl| {
        hyperlinks.hyperlinks_reset(hl);
        return;
    }
    s.hyperlinks = hyperlinks.hyperlinks_init();
}

pub fn screen_current(wp: *T.WindowPane) *T.Screen {
    return if (screen_alternate_active(wp)) wp.screen else &wp.base;
}

pub fn screen_reset_tabs(s: *T.Screen) void {
    if (s.tabs) |old| xm.allocator.free(old);

    const tab_bytes = (s.grid.sx + 7) / 8;
    const tabs = xm.allocator.alloc(u8, tab_bytes) catch unreachable;
    @memset(tabs, 0);
    s.tabs = tabs;

    var x: u32 = 8;
    while (x < s.grid.sx) : (x += 8) {
        screen_set_tab(s, x);
    }
}

pub fn screen_set_tab(s: *T.Screen, x: u32) void {
    const tabs = s.tabs orelse return;
    const byte_index: usize = @intCast(x / 8);
    if (byte_index >= tabs.len) return;
    tabs[byte_index] |= @as(u8, 1) << @intCast(x % 8);
}

pub fn screen_clear_tab(s: *T.Screen, x: u32) void {
    const tabs = s.tabs orelse return;
    const byte_index: usize = @intCast(x / 8);
    if (byte_index >= tabs.len) return;
    tabs[byte_index] &= ~(@as(u8, 1) << @intCast(x % 8));
}

pub fn screen_clear_all_tabs(s: *T.Screen) void {
    const tabs = s.tabs orelse return;
    @memset(tabs, 0);
}

pub fn screen_has_tab(s: *const T.Screen, x: u32) bool {
    const tabs = s.tabs orelse return x != 0 and x % 8 == 0;
    const byte_index: usize = @intCast(x / 8);
    if (byte_index >= tabs.len) return false;
    return (tabs[byte_index] & (@as(u8, 1) << @intCast(x % 8))) != 0;
}

pub fn screen_next_tabstop(s: *const T.Screen) u32 {
    if (s.grid.sx == 0) return 0;

    var x = s.cx + 1;
    while (x < s.grid.sx) : (x += 1) {
        if (screen_has_tab(s, x)) return x;
    }
    return s.grid.sx;
}

pub fn screen_alternate_active(wp: *T.WindowPane) bool {
    return wp.screen.saved_grid != null;
}

pub fn screen_set_title(s: *T.Screen, title: []const u8) bool {
    if (!utf8.utf8_isvalid(title)) return false;
    if (s.title) |old| xm.allocator.free(old);
    s.title = xm.xstrdup(title);
    return true;
}

pub fn screen_set_path(s: *T.Screen, path: []const u8) void {
    if (s.path) |old| xm.allocator.free(old);
    s.path = utf8.utf8_stravis(path, utf8.VIS_OCTAL | utf8.VIS_CSTYLE | utf8.VIS_TAB | utf8.VIS_NL);
}

pub fn screen_save_cursor(s: *T.Screen) void {
    s.saved_cx = s.cx;
    s.saved_cy = s.cy;
}

pub fn screen_restore_cursor(s: *T.Screen) void {
    if (s.grid.sx != 0) s.cx = @min(s.saved_cx, s.grid.sx - 1) else s.cx = 0;
    if (s.grid.sy != 0) s.cy = @min(s.saved_cy, s.grid.sy - 1) else s.cy = 0;
}

pub fn screen_enter_alternate(wp: *T.WindowPane, save_cursor: bool) void {
    if (screen_alternate_active(wp)) return;

    if (save_cursor) {
        wp.screen.saved_cx = wp.base.cx;
        wp.screen.saved_cy = wp.base.cy;
    } else {
        wp.screen.saved_cx = 0;
        wp.screen.saved_cy = 0;
    }
    wp.screen.saved_grid = wp.base.grid;
    screen_reset_active(wp.screen);
}

pub fn screen_leave_alternate(wp: *T.WindowPane, restore_cursor: bool) void {
    if (!screen_alternate_active(wp)) return;

    if (restore_cursor) {
        if (wp.base.grid.sx != 0) wp.base.cx = @min(wp.screen.saved_cx, wp.base.grid.sx - 1) else wp.base.cx = 0;
        if (wp.base.grid.sy != 0) wp.base.cy = @min(wp.screen.saved_cy, wp.base.grid.sy - 1) else wp.base.cy = 0;
    }

    wp.screen.saved_grid = null;
    screen_reset_active(wp.screen);
}

/// Map a numeric cursor-style option (0-6) to a ScreenCursorStyle and
/// blinking mode bit.  Ported from tmux screen_set_cursor_style().
pub fn screen_set_cursor_style(style: u32, cstyle: *T.ScreenCursorStyle, mode: *i32) void {
    switch (style) {
        0 => {
            cstyle.* = .default;
        },
        1 => {
            cstyle.* = .block;
            mode.* |= T.MODE_CURSOR_BLINKING;
        },
        2 => {
            cstyle.* = .block;
            mode.* &= ~@as(i32, T.MODE_CURSOR_BLINKING);
        },
        3 => {
            cstyle.* = .underline;
            mode.* |= T.MODE_CURSOR_BLINKING;
        },
        4 => {
            cstyle.* = .underline;
            mode.* &= ~@as(i32, T.MODE_CURSOR_BLINKING);
        },
        5 => {
            cstyle.* = .bar;
            mode.* |= T.MODE_CURSOR_BLINKING;
        },
        6 => {
            cstyle.* = .bar;
            mode.* &= ~@as(i32, T.MODE_CURSOR_BLINKING);
        },
        else => {},
    }
}

test "screen_reset clears cursor and region state" {
    const s = screen_init(4, 2, 100);
    defer {
        screen_free(s);
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

test "screen alternate helpers switch current screen and restore cursor" {
    const base_grid = grid.grid_create(4, 2, 100);
    defer grid.grid_free(base_grid);
    const alt = screen_init(4, 2, 100);
    defer {
        screen_free(alt);
        xm.allocator.destroy(alt);
    }

    var dummy_window: T.Window = undefined;
    var wp = T.WindowPane{
        .id = 1,
        .window = &dummy_window,
        .options = undefined,
        .sx = 4,
        .sy = 2,
        .screen = alt,
        .base = .{ .grid = base_grid, .rlower = 1 },
    };

    wp.base.cx = 2;
    wp.base.cy = 1;
    try std.testing.expectEqual(&wp.base, screen_current(&wp));

    screen_enter_alternate(&wp, true);
    try std.testing.expect(screen_alternate_active(&wp));
    try std.testing.expectEqual(alt, screen_current(&wp));

    alt.cx = 1;
    alt.cy = 0;
    screen_leave_alternate(&wp, true);
    try std.testing.expect(!screen_alternate_active(&wp));
    try std.testing.expectEqual(&wp.base, screen_current(&wp));
    try std.testing.expectEqual(@as(u32, 2), wp.base.cx);
    try std.testing.expectEqual(@as(u32, 1), wp.base.cy);
}

test "screen title rejects invalid utf8 and path is escaped" {
    const s = screen_init(4, 2, 100);
    defer {
        screen_free(s);
        xm.allocator.destroy(s);
    }

    try std.testing.expect(screen_set_title(s, "valid"));
    try std.testing.expect(!screen_set_title(s, &.{ 'a', 0xff }));

    screen_set_path(s, "one\ntwo");
    try std.testing.expectEqualStrings("one\\ntwo", s.path.?);
}

test "screen_reset_hyperlinks keeps the set but drops stored ids" {
    const s = screen_init(4, 2, 100);
    defer {
        screen_free(s);
        xm.allocator.destroy(s);
    }

    const first = hyperlinks.hyperlinks_put(s.hyperlinks.?, "https://example.com", "pane");
    try std.testing.expect(hyperlinks.hyperlinks_get(s.hyperlinks.?, first, null, null, null));

    const original = s.hyperlinks.?;
    screen_reset_hyperlinks(s);

    try std.testing.expectEqual(original, s.hyperlinks.?);
    try std.testing.expect(!hyperlinks.hyperlinks_get(s.hyperlinks.?, first, null, null, null));
}
