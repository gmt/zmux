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
// Ported in part from tmux/window.c.
// Original copyright:
//   Copyright (c) 2007 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

//! window.zig – window and pane lifecycle.

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const log = @import("log.zig");
const opts = @import("options.zig");
const colour_mod = @import("colour.zig");
const style_mod = @import("style.zig");

// ── Global state ──────────────────────────────────────────────────────────

pub var windows: std.AutoHashMap(u32, *T.Window) = undefined;
pub var all_window_panes: std.AutoHashMap(u32, *T.WindowPane) = undefined;
var next_window_id: u32 = 0;
var next_window_pane_id: u32 = 0;

pub fn window_init_globals(alloc: std.mem.Allocator) void {
    windows = std.AutoHashMap(u32, *T.Window).init(alloc);
    all_window_panes = std.AutoHashMap(u32, *T.WindowPane).init(alloc);
}

// ── Window comparators ────────────────────────────────────────────────────

pub fn window_cmp(a: *T.Window, b: *T.Window) std.math.Order {
    return std.math.order(a.id, b.id);
}

pub fn winlink_cmp(a: *T.Winlink, b: *T.Winlink) std.math.Order {
    return std.math.order(a.idx, b.idx);
}

pub fn window_pane_cmp(a: *T.WindowPane, b: *T.WindowPane) std.math.Order {
    return std.math.order(a.id, b.id);
}

// ── Window creation / destruction ─────────────────────────────────────────

pub fn window_create(sx: u32, sy: u32, _xpixel: u32, _ypixel: u32) *T.Window {
    const w = xm.allocator.create(T.Window) catch unreachable;
    w.* = .{
        .id = next_window_id,
        .name = xm.xstrdup(""),
        .sx = sx,
        .sy = sy,
        .xpixel = _xpixel,
        .ypixel = _ypixel,
        .options = opts.options_create(opts.global_w_options),
    };
    next_window_id += 1;
    windows.put(w.id, w) catch unreachable;
    log.log_debug("new window @{d} {d}x{d}", .{ w.id, sx, sy });
    return w;
}

pub fn window_add_pane(w: *T.Window, before: ?*T.WindowPane, sx: u32, sy: u32) *T.WindowPane {
    const wp = window_pane_create(w, sx, sy);
    window_adopt_pane_before(w, wp, before);
    return wp;
}

fn window_pane_create(w: *T.Window, sx: u32, sy: u32) *T.WindowPane {
    const grid = grid_create(sx, sy, 2000);
    const screen_ptr = xm.allocator.create(T.Screen) catch unreachable;
    screen_ptr.* = T.Screen{ .grid = grid };

    const wp = xm.allocator.create(T.WindowPane) catch unreachable;
    wp.* = T.WindowPane{
        .id = next_window_pane_id,
        .window = w,
        .options = opts.options_create(w.options),
        .sx = sx,
        .sy = sy,
        .screen = screen_ptr,
        .base = T.Screen{ .grid = grid },
    };
    window_pane_options_changed(wp, null);
    next_window_pane_id += 1;
    all_window_panes.put(wp.id, wp) catch unreachable;
    return wp;
}

pub fn window_remove_pane(w: *T.Window, wp: *T.WindowPane) void {
    _ = window_detach_pane(w, wp);
    _ = all_window_panes.remove(wp.id);
    window_pane_destroy(wp);
}

pub fn window_detach_pane(w: *T.Window, wp: *T.WindowPane) bool {
    remove_last_pane_reference(w, wp);
    for (w.panes.items, 0..) |p, i| {
        if (p == wp) {
            _ = w.panes.orderedRemove(i);
            if (w.active == wp) {
                w.active = if (w.panes.items.len > 0) w.panes.items[0] else null;
            }
            return true;
        }
    }
    return false;
}

pub fn window_adopt_pane(w: *T.Window, wp: *T.WindowPane) void {
    window_adopt_pane_before(w, wp, null);
}

pub fn window_adopt_pane_before(w: *T.Window, wp: *T.WindowPane, before: ?*T.WindowPane) void {
    wp.window = w;
    wp.options.parent = w.options;
    if (before) |target| {
        for (w.panes.items, 0..) |pane, idx| {
            if (pane == target) {
                w.panes.insert(xm.allocator, idx, wp) catch unreachable;
                if (w.active == null) w.active = wp;
                window_pane_options_changed(wp, null);
                return;
            }
        }
    }
    w.panes.append(xm.allocator, wp) catch unreachable;
    if (w.active == null) w.active = wp;
    window_pane_options_changed(wp, null);
}

pub fn window_count_panes(w: *T.Window) usize {
    return w.panes.items.len;
}

pub fn window_get_last_pane(w: *T.Window) ?*T.WindowPane {
    if (w.last_panes.items.len == 0) return null;
    return w.last_panes.items[w.last_panes.items.len - 1];
}

fn window_pane_destroy(wp: *T.WindowPane) void {
    if (wp.pid > 0) {
        _ = std.c.kill(wp.pid, std.posix.SIG.HUP);
        _ = std.c.kill(wp.pid, std.posix.SIG.TERM);
        wp.pid = -1;
    }
    if (wp.pipe_pid > 0) {
        _ = std.c.kill(wp.pipe_pid, std.posix.SIG.HUP);
        _ = std.c.kill(wp.pipe_pid, std.posix.SIG.TERM);
        wp.pipe_pid = -1;
    }
    if (wp.fd >= 0) {
        std.posix.close(wp.fd);
        wp.fd = -1;
    }
    if (wp.pipe_fd >= 0) {
        std.posix.close(wp.pipe_fd);
        wp.pipe_fd = -1;
    }
    if (wp.argv) |argv| {
        for (argv) |arg| xm.allocator.free(arg);
        xm.allocator.free(argv);
    }
    if (wp.shell) |shell| xm.allocator.free(shell);
    if (wp.cwd) |cwd| xm.allocator.free(cwd);
    opts.options_free(wp.options);
    colour_mod.colour_palette_free(&wp.palette);
    const grid = wp.screen.grid;
    if (wp.screen.title) |title| xm.allocator.free(title);
    if (wp.screen.path) |path| xm.allocator.free(path);
    if (wp.screen.tabs) |tabs| xm.allocator.free(tabs);
    xm.allocator.free(grid.linedata);
    xm.allocator.destroy(grid);
    xm.allocator.destroy(wp.screen);
    xm.allocator.destroy(wp);
}

pub fn window_pane_options_changed(wp: *T.WindowPane, changed: ?[]const u8) void {
    if (changed == null) {
        colour_mod.colour_palette_init(&wp.palette);
        style_mod.style_set_scrollbar_style_from_option(&wp.scrollbar_style, wp.options);
        colour_mod.colour_palette_from_option(&wp.palette, wp.options);
        return;
    }

    if (std.mem.eql(u8, changed.?, "pane-scrollbars-style"))
        style_mod.style_set_scrollbar_style_from_option(&wp.scrollbar_style, wp.options);
    if (std.mem.eql(u8, changed.?, "pane-colours"))
        colour_mod.colour_palette_from_option(&wp.palette, wp.options);
}

pub fn window_find_by_id(id: u32) ?*T.Window {
    return windows.get(id);
}

pub fn window_pane_find_by_id(id: u32) ?*T.WindowPane {
    return all_window_panes.get(id);
}

pub fn window_add_ref(w: *T.Window, _from: []const u8) void {
    _ = _from;
    w.references += 1;
}

pub fn window_remove_ref(w: *T.Window, _from: []const u8) void {
    _ = _from;
    if (w.references == 0) return;
    w.references -= 1;
    if (w.references == 0) {
        _ = windows.remove(w.id);
        while (w.panes.items.len > 0) {
            const wp = w.panes.items[w.panes.items.len - 1];
            window_remove_pane(w, wp);
        }
        w.panes.deinit(xm.allocator);
        w.last_panes.deinit(xm.allocator);
        w.winlinks.deinit(xm.allocator);
        opts.options_free(w.options);
        xm.allocator.free(w.name);
        xm.allocator.destroy(w);
    }
}

pub fn window_destroy_all_panes(w: *T.Window) void {
    while (w.panes.items.len > 0) {
        const wp = w.panes.items[w.panes.items.len - 1];
        window_remove_pane(w, wp);
    }
    w.active = null;
}

pub fn window_set_active_pane(w: *T.Window, wp: *T.WindowPane, _notify: bool) bool {
    _ = _notify;
    if (w.active == wp) return false;
    if (!window_has_pane(w, wp)) return false;
    if (w.active) |old| push_last_pane(w, old);
    remove_last_pane_reference(w, wp);
    w.active = wp;
    return true;
}

pub fn window_set_name(w: *T.Window, name: []const u8) void {
    xm.allocator.free(w.name);
    w.name = xm.xstrdup(name);
}

pub fn window_resize(w: *T.Window, sx: u32, sy: u32, _xpixel: i32, _ypixel: i32) void {
    _ = _xpixel;
    _ = _ypixel;
    w.sx = sx;
    w.sy = sy;
}

pub fn window_pane_resize(wp: *T.WindowPane, sx: ?u32, sy: ?u32) void {
    const w = wp.window;
    if (sx) |new_sx| {
        const clamped = @max(@as(u32, 1), @min(new_sx, w.sx));
        wp.sx = clamped;
        if (w.panes.items.len == 1) {
            w.sx = clamped;
            w.manual_sx = clamped;
        }
    }
    if (sy) |new_sy| {
        const clamped = @max(@as(u32, 1), @min(new_sy, w.sy));
        wp.sy = clamped;
        if (w.panes.items.len == 1) {
            w.sy = clamped;
            w.manual_sy = clamped;
        }
    }
}

/// Push current zoom state.
pub fn window_push_zoom(_w: *T.Window, _ignore: bool, _zoom: bool) bool {
    _ = _w;
    _ = _ignore;
    _ = _zoom;
    return false;
}

/// Pop zoom state.
pub fn window_pop_zoom(_w: *T.Window) bool {
    _ = _w;
    return false;
}

pub fn window_redraw_active_switch(_w: *T.Window, _wp: *T.WindowPane) void {
    _ = _w;
    _ = _wp;
}

// ── Grid helpers (minimal – full grid.zig will be a separate port) ────────

fn grid_create(sx: u32, sy: u32, hlimit: u32) *T.Grid {
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

fn window_has_pane(w: *T.Window, wp: *T.WindowPane) bool {
    for (w.panes.items) |pane| {
        if (pane == wp) return true;
    }
    return false;
}

fn push_last_pane(w: *T.Window, wp: *T.WindowPane) void {
    remove_last_pane_reference(w, wp);
    w.last_panes.append(xm.allocator, wp) catch unreachable;
}

fn remove_last_pane_reference(w: *T.Window, wp: *T.WindowPane) void {
    var i: usize = 0;
    while (i < w.last_panes.items.len) {
        if (w.last_panes.items[i] == wp) {
            _ = w.last_panes.orderedRemove(i);
        } else {
            i += 1;
        }
    }
}

test "window panes inherit from their window options and refresh cached pane state" {
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    window_init_globals(xm.allocator);

    const w = window_create(80, 24, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);

    const wp = window_add_pane(w, null, 80, 24);
    defer {
        _ = all_window_panes.remove(wp.id);
        window_pane_destroy(wp);
        opts.options_free(w.options);
        xm.allocator.free(w.name);
        _ = windows.remove(w.id);
        xm.allocator.destroy(w);
    }

    try std.testing.expect(wp.options != opts.global_w_options);
    try std.testing.expectEqual(w.options, wp.options.parent.?);

    opts.options_set_string(wp.options, false, "pane-scrollbars-style", "fg=blue,pad=4");
    window_pane_options_changed(wp, "pane-scrollbars-style");
    try std.testing.expectEqual(@as(i32, 4), wp.scrollbar_style.pad);
    try std.testing.expectEqual(@as(i32, 4), wp.scrollbar_style.gc.fg);

    opts.options_set_array(wp.options, "pane-colours", &.{ "1=#010203", "2=brightred" });
    window_pane_options_changed(wp, "pane-colours");
    try std.testing.expectEqual(colour_mod.colour_join_rgb(0x01, 0x02, 0x03), colour_mod.colour_palette_get(&wp.palette, 1));
    try std.testing.expectEqual(@as(i32, 91), colour_mod.colour_palette_get(&wp.palette, 2));
}

test "window_set_active_pane tracks last pane history and detach prunes it" {
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    window_init_globals(xm.allocator);

    const w = window_create(80, 24, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    defer {
        while (w.panes.items.len > 0) {
            const wp = w.panes.items[w.panes.items.len - 1];
            window_remove_pane(w, wp);
        }
        w.panes.deinit(xm.allocator);
        w.last_panes.deinit(xm.allocator);
        opts.options_free(w.options);
        xm.allocator.free(w.name);
        _ = windows.remove(w.id);
        xm.allocator.destroy(w);
    }

    const first = window_add_pane(w, null, 80, 24);
    const second = window_add_pane(w, null, 80, 24);
    const third = window_add_pane(w, null, 80, 24);
    _ = third;

    try std.testing.expectEqual(first, w.active.?);
    try std.testing.expect(window_set_active_pane(w, second, true));
    try std.testing.expectEqual(second, w.active.?);
    try std.testing.expectEqual(first, window_get_last_pane(w).?);

    try std.testing.expect(window_set_active_pane(w, first, true));
    try std.testing.expectEqual(first, w.active.?);
    try std.testing.expectEqual(second, window_get_last_pane(w).?);

    try std.testing.expect(window_detach_pane(w, second));
    try std.testing.expect(window_get_last_pane(w) == null);
}

test "window_pane_resize clamps to window bounds and updates sole pane window size" {
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    window_init_globals(xm.allocator);

    const w = window_create(80, 24, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    defer {
        while (w.panes.items.len > 0) {
            const wp = w.panes.items[w.panes.items.len - 1];
            window_remove_pane(w, wp);
        }
        w.panes.deinit(xm.allocator);
        w.last_panes.deinit(xm.allocator);
        opts.options_free(w.options);
        xm.allocator.free(w.name);
        _ = windows.remove(w.id);
        xm.allocator.destroy(w);
    }

    const wp = window_add_pane(w, null, 80, 24);
    window_pane_resize(wp, 120, 12);
    try std.testing.expectEqual(@as(u32, 80), wp.sx);
    try std.testing.expectEqual(@as(u32, 12), wp.sy);
    try std.testing.expectEqual(@as(u32, 80), w.sx);
    try std.testing.expectEqual(@as(u32, 12), w.sy);
}
