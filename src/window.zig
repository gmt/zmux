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
// Ported from tmux/window.c
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
        .options = opts.global_w_options,
    };
    next_window_id += 1;
    windows.put(w.id, w) catch unreachable;
    log.log_debug("new window @{d} {d}x{d}", .{ w.id, sx, sy });
    return w;
}

pub fn window_add_pane(w: *T.Window, _before: ?*T.WindowPane, sx: u32, sy: u32) *T.WindowPane {
    _ = _before;
    const wp = window_pane_create(w, sx, sy);
    w.panes.append(xm.allocator, wp) catch unreachable;
    if (w.active == null) w.active = wp;
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
        .options = opts.global_w_options,
        .sx = sx,
        .sy = sy,
        .screen = screen_ptr,
        .base = T.Screen{ .grid = grid },
    };
    colour_mod.colour_palette_init(&wp.palette);
    next_window_pane_id += 1;
    all_window_panes.put(wp.id, wp) catch unreachable;
    return wp;
}

pub fn window_remove_pane(w: *T.Window, wp: *T.WindowPane) void {
    for (w.panes.items, 0..) |p, i| {
        if (p == wp) {
            _ = w.panes.swapRemove(i);
            break;
        }
    }
    _ = all_window_panes.remove(wp.id);
    window_pane_destroy(wp);
}

fn window_pane_destroy(wp: *T.WindowPane) void {
    if (wp.argv) |argv| {
        for (argv) |arg| xm.allocator.free(arg);
        xm.allocator.free(argv);
    }
    if (wp.shell) |shell| xm.allocator.free(shell);
    if (wp.cwd) |cwd| xm.allocator.free(cwd);
    colour_mod.colour_palette_free(&wp.palette);
    xm.allocator.destroy(wp.screen);
    xm.allocator.destroy(wp);
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
        xm.allocator.free(w.name);
        xm.allocator.destroy(w);
    }
}

pub fn window_set_active_pane(w: *T.Window, wp: *T.WindowPane, _notify: bool) void {
    _ = _notify;
    w.active = wp;
}

pub fn window_resize(w: *T.Window, sx: u32, sy: u32, _xpixel: i32, _ypixel: i32) void {
    _ = _xpixel;
    _ = _ypixel;
    w.sx = sx;
    w.sy = sy;
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
