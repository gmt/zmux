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
const client_registry = @import("client-registry.zig");
const notify = @import("notify.zig");
const pane_io = @import("pane-io.zig");
const style_mod = @import("style.zig");
const grid_mod = @import("grid.zig");
const screen_mod = @import("screen.zig");
const marked_pane_mod = @import("marked-pane.zig");
const c = @import("c.zig");
const utf8 = @import("utf8.zig");

// ── Global state ──────────────────────────────────────────────────────────

pub var windows: std.AutoHashMap(u32, *T.Window) = undefined;
pub var all_window_panes: std.AutoHashMap(u32, *T.WindowPane) = undefined;
var next_window_id: u32 = 0;
var next_window_pane_id: u32 = 0;
var next_active_point: u32 = 0;

pub fn window_init_globals(alloc: std.mem.Allocator) void {
    windows = std.AutoHashMap(u32, *T.Window).init(alloc);
    all_window_panes = std.AutoHashMap(u32, *T.WindowPane).init(alloc);
    next_active_point = 0;
    marked_pane_mod.clear();
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

pub const PaneHitRegion = enum {
    pane,
    border,
    scrollbar_up,
    scrollbar_slider,
    scrollbar_down,
};

pub const PaneHit = struct {
    pane: *T.WindowPane,
    region: PaneHitRegion,
    slider_mpos: i32 = -1,
};

pub const ScrollbarLayout = struct {
    left: bool,
    width: u32,
    pad: u32,
    slider_y: u32,
    slider_h: u32,
};

pub const PaneGeometry = struct {
    xoff: u32,
    yoff: u32,
    sx: u32,
    sy: u32,
};

pub const SplitPanePlan = struct {
    target_before: PaneGeometry,
    target_after: PaneGeometry,
    new_pane: PaneGeometry,
};

pub const SplitPaneError = error{
    NoSpace,
    FullSizeNeedsLayout,
};

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
    return window_add_pane_with_flags(w, before, sx, sy, 0);
}

pub fn window_add_pane_with_flags(w: *T.Window, before: ?*T.WindowPane, sx: u32, sy: u32, flags: u32) *T.WindowPane {
    const wp = window_pane_create(w, sx, sy);
    const anchor = before orelse w.active;

    if (w.panes.items.len == 0) {
        window_adopt_pane_before(w, wp, null);
        return wp;
    }

    if (flags & T.SPAWN_BEFORE != 0) {
        if (flags & T.SPAWN_FULLSIZE != 0) {
            window_adopt_pane_before(w, wp, w.panes.items[0]);
        } else {
            window_adopt_pane_before(w, wp, anchor);
        }
        return wp;
    }

    if (flags & T.SPAWN_FULLSIZE != 0) {
        window_adopt_pane_before(w, wp, null);
        return wp;
    }

    if (anchor) |target| {
        for (w.panes.items, 0..) |pane, idx| {
            if (pane != target) continue;
            if (idx + 1 >= w.panes.items.len)
                window_adopt_pane_before(w, wp, null)
            else
                window_adopt_pane_before(w, wp, w.panes.items[idx + 1]);
            return wp;
        }
    }

    window_adopt_pane_before(w, wp, null);
    return wp;
}

fn window_pane_create(w: *T.Window, sx: u32, sy: u32) *T.WindowPane {
    const base_grid = grid_mod.grid_create(sx, sy, 2000);
    const screen_ptr = screen_mod.screen_init(sx, sy, 2000);

    const wp = xm.allocator.create(T.WindowPane) catch unreachable;
    wp.* = T.WindowPane{
        .id = next_window_pane_id,
        .window = w,
        .options = opts.options_create(w.options),
        .sx = sx,
        .sy = sy,
        .screen = screen_ptr,
        .base = T.Screen{
            .grid = base_grid,
            .mode = T.MODE_CURSOR | T.MODE_WRAP,
            .rlower = if (sy == 0) 0 else sy - 1,
        },
        .input_pending = .{},
    };
    screen_mod.screen_reset_tabs(&wp.base);
    screen_mod.screen_reset_hyperlinks(&wp.base);
    window_pane_options_changed(wp, null);
    next_window_pane_id += 1;
    all_window_panes.put(wp.id, wp) catch unreachable;
    return wp;
}

pub fn window_remove_pane(w: *T.Window, wp: *T.WindowPane) void {
    marked_pane_mod.clear_if_pane(wp);
    _ = window_detach_pane(w, wp);
    _ = all_window_panes.remove(wp.id);
    window_pane_destroy(wp);
}

pub fn window_detach_pane(w: *T.Window, wp: *T.WindowPane) bool {
    remove_last_pane_reference(w, wp);
    window_clear_client_pane_reference(w, wp);
    const removed_geometry = pane_geometry(wp);
    for (w.panes.items, 0..) |p, i| {
        if (p == wp) {
            _ = w.panes.orderedRemove(i);
            if (w.active == wp) {
                w.active = window_get_last_pane(w);
                if (w.active == null) {
                    if (i > 0)
                        w.active = w.panes.items[i - 1]
                    else if (i < w.panes.items.len)
                        w.active = w.panes.items[i];
                }
                if (w.active) |active| {
                    remove_last_pane_reference(w, active);
                    active.flags |= T.PANE_CHANGED;
                    if (w.winlinks.items.len != 0)
                        notify.notify_window("window-pane-changed", w);
                    window_mark_viewing_clients_for_active_pane_change(w);
                    window_update_focus(w);
                }
            }
            collapse_detached_pane_gap(w, removed_geometry);
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

pub fn window_pane_search(wp: *T.WindowPane, term: []const u8, regex: bool, ignore: bool) u32 {
    const s = &wp.base;

    if (!regex) {
        const pattern = std.fmt.allocPrint(xm.allocator, "*{s}*", .{term}) catch unreachable;
        defer xm.allocator.free(pattern);

        const match_pattern = if (ignore)
            std.ascii.allocLowerString(xm.allocator, pattern) catch unreachable
        else
            xm.xstrdup(pattern);
        defer xm.allocator.free(match_pattern);

        const pattern_z = xm.xm_dupeZ(match_pattern);
        defer xm.allocator.free(pattern_z);

        var row: u32 = 0;
        while (row < s.grid.sy) : (row += 1) {
            const line = grid_mod.string_cells(s.grid, row, s.grid.sx, .{});
            defer xm.allocator.free(line);

            const trimmed = trim_trailing_ascii_whitespace(line);
            const haystack = if (ignore)
                std.ascii.allocLowerString(xm.allocator, trimmed) catch unreachable
            else
                xm.xstrdup(trimmed);
            defer xm.allocator.free(haystack);

            const haystack_z = xm.xm_dupeZ(haystack);
            defer xm.allocator.free(haystack_z);

            if (c.posix_sys.fnmatch(pattern_z.ptr, haystack_z.ptr, 0) == 0)
                return row + 1;
        }
        return 0;
    }

    const re = c.posix_sys.zmux_regex_new() orelse return 0;
    defer c.posix_sys.zmux_regex_free(re);

    var flags: c_int = c.posix_sys.REG_EXTENDED | c.posix_sys.REG_NOSUB;
    if (ignore) flags |= c.posix_sys.REG_ICASE;

    const term_z = xm.xm_dupeZ(term);
    defer xm.allocator.free(term_z);
    if (c.posix_sys.zmux_regex_compile(re, term_z.ptr, flags) != 0)
        return 0;

    var row: u32 = 0;
    while (row < s.grid.sy) : (row += 1) {
        const line = grid_mod.string_cells(s.grid, row, s.grid.sx, .{});
        defer xm.allocator.free(line);

        const trimmed = trim_trailing_ascii_whitespace(line);
        const line_z = xm.xm_dupeZ(trimmed);
        defer xm.allocator.free(line_z);

        if (c.posix_sys.zmux_regex_exec(re, line_z.ptr, 0, null) == 0)
            return row + 1;
    }

    return 0;
}

pub fn window_pane_find_up(wp: *T.WindowPane) ?*T.WindowPane {
    const w = wp.window;
    const status = opts.options_get_number(w.options, "pane-border-status");
    const current = window_pane_draw_bounds(wp);

    var edge = current.yoff;
    if (status == T.PANE_STATUS_TOP) {
        if (edge == 1) edge = w.sy + 1;
    } else if (status == T.PANE_STATUS_BOTTOM) {
        if (edge == 0) edge = w.sy;
    } else {
        if (edge == 0) edge = w.sy + 1;
    }

    const left = current.xoff;
    const right = current.xoff + current.sx;

    var best: ?*T.WindowPane = null;
    for (w.panes.items) |next| {
        if (next == wp) continue;
        const candidate = window_pane_draw_bounds(next);
        if (candidate.yoff + candidate.sy + 1 != edge) continue;

        const cand_end = pane_range_end(candidate.xoff, candidate.sx);
        if (!pane_ranges_overlap(left, right, candidate.xoff, cand_end)) continue;
        best = choose_better_pane(best, next);
    }
    return best;
}

pub fn window_pane_find_down(wp: *T.WindowPane) ?*T.WindowPane {
    const w = wp.window;
    const status = opts.options_get_number(w.options, "pane-border-status");
    const current = window_pane_draw_bounds(wp);

    var edge = current.yoff + current.sy + 1;
    if (status == T.PANE_STATUS_TOP) {
        if (edge >= w.sy) edge = 1;
    } else if (status == T.PANE_STATUS_BOTTOM) {
        if (edge >= w.sy - 1) edge = 0;
    } else {
        if (edge >= w.sy) edge = 0;
    }

    const left = wp.xoff;
    const right = wp.xoff + wp.sx;

    var best: ?*T.WindowPane = null;
    for (w.panes.items) |next| {
        if (next == wp) continue;
        const candidate = window_pane_draw_bounds(next);
        if (candidate.yoff != edge) continue;

        const cand_end = pane_range_end(candidate.xoff, candidate.sx);
        if (!pane_ranges_overlap(left, right, candidate.xoff, cand_end)) continue;
        best = choose_better_pane(best, next);
    }
    return best;
}

pub fn window_pane_find_left(wp: *T.WindowPane) ?*T.WindowPane {
    const w = wp.window;
    const current = window_pane_draw_bounds(wp);

    var edge = current.xoff;
    if (edge == 0) edge = w.sx + 1;

    const top = current.yoff;
    const bottom = current.yoff + current.sy;

    var best: ?*T.WindowPane = null;
    for (w.panes.items) |next| {
        if (next == wp) continue;
        const candidate = window_pane_draw_bounds(next);
        if (candidate.xoff + candidate.sx + 1 != edge) continue;

        const cand_end = pane_range_end(candidate.yoff, candidate.sy);
        if (!pane_ranges_overlap(top, bottom, candidate.yoff, cand_end)) continue;
        best = choose_better_pane(best, next);
    }
    return best;
}

pub fn window_pane_find_right(wp: *T.WindowPane) ?*T.WindowPane {
    const w = wp.window;
    const current = window_pane_draw_bounds(wp);

    var edge = current.xoff + current.sx + 1;
    if (edge >= w.sx) edge = 0;

    const top = wp.yoff;
    const bottom = wp.yoff + wp.sy;

    var best: ?*T.WindowPane = null;
    for (w.panes.items) |next| {
        if (next == wp) continue;
        const candidate = window_pane_draw_bounds(next);
        if (candidate.xoff != edge) continue;

        const cand_end = pane_range_end(candidate.yoff, candidate.sy);
        if (!pane_ranges_overlap(top, bottom, candidate.yoff, cand_end)) continue;
        best = choose_better_pane(best, next);
    }
    return best;
}

pub fn window_pane_index(w: *T.Window, wp: *T.WindowPane) ?usize {
    for (w.panes.items, 0..) |pane, idx| {
        if (pane == wp) return idx;
    }
    return null;
}

pub fn window_plan_split(
    wp: *T.WindowPane,
    type_: T.LayoutType,
    size: i32,
    flags: u32,
) SplitPaneError!SplitPanePlan {
    if (type_ != .leftright and type_ != .topbottom)
        return error.NoSpace;

    if (flags & T.SPAWN_FULLSIZE != 0 and wp.window.panes.items.len > 1)
        return error.FullSizeNeedsLayout;

    const original = pane_geometry(wp);
    const saved_size: u32 = if (type_ == .leftright) original.sx else original.sy;
    if (saved_size < T.PANE_MINIMUM * 2 + 1)
        return error.NoSpace;

    var size2: u32 = if (size < 0)
        ((saved_size + 1) / 2) - 1
    else if (flags & T.SPAWN_BEFORE != 0)
        saved_size - @as(u32, @intCast(size)) - 1
    else
        @intCast(size);

    if (size2 < T.PANE_MINIMUM)
        size2 = T.PANE_MINIMUM
    else if (size2 > saved_size - 2)
        size2 = saved_size - 2;

    const size1 = saved_size - 1 - size2;

    var target_after = original;
    var new_pane = original;
    if (type_ == .leftright) {
        if (flags & T.SPAWN_BEFORE != 0) {
            target_after.xoff = original.xoff + size1 + 1;
            target_after.sx = size2;
            new_pane.sx = size1;
        } else {
            target_after.sx = size1;
            new_pane.xoff = original.xoff + size1 + 1;
            new_pane.sx = size2;
        }
    } else {
        if (flags & T.SPAWN_BEFORE != 0) {
            target_after.yoff = original.yoff + size1 + 1;
            target_after.sy = size2;
            new_pane.sy = size1;
        } else {
            target_after.sy = size1;
            new_pane.yoff = original.yoff + size1 + 1;
            new_pane.sy = size2;
        }
    }

    return .{
        .target_before = original,
        .target_after = target_after,
        .new_pane = new_pane,
    };
}

pub fn window_apply_split_plan(target: *T.WindowPane, new_pane: *T.WindowPane, plan: SplitPanePlan) void {
    apply_pane_geometry(target, plan.target_after);
    apply_pane_geometry(new_pane, plan.new_pane);
}

pub fn window_restore_split_plan(target: *T.WindowPane, plan: SplitPanePlan) void {
    apply_pane_geometry(target, plan.target_before);
}

pub fn window_pane_at_index(w: *T.Window, idx: usize) ?*T.WindowPane {
    if (idx >= w.panes.items.len) return null;
    return w.panes.items[idx];
}

pub fn window_forget_pane_history(w: *T.Window, wp: *T.WindowPane) void {
    remove_last_pane_reference(w, wp);
}

pub fn window_pane_destroy(wp: *T.WindowPane) void {
    pane_io.pane_io_stop(wp);
    pane_io.pane_pipe_close(wp);
    if (wp.pid > 0) {
        _ = std.c.kill(wp.pid, std.posix.SIG.HUP);
        _ = std.c.kill(wp.pid, std.posix.SIG.TERM);
        wp.pid = -1;
    }
    if (wp.fd >= 0) {
        std.posix.close(wp.fd);
        wp.fd = -1;
    }
    if (wp.argv) |argv| {
        for (argv) |arg| xm.allocator.free(arg);
        xm.allocator.free(argv);
    }
    if (wp.shell) |shell| xm.allocator.free(shell);
    if (wp.cwd) |cwd| xm.allocator.free(cwd);
    if (wp.searchstr) |searchstr| xm.allocator.free(searchstr);
    wp.input_pending.deinit(xm.allocator);
    while (wp.modes.items.len > 0) {
        const wme = wp.modes.orderedRemove(0);
        xm.allocator.destroy(wme);
    }
    wp.modes.deinit(xm.allocator);
    opts.options_free(wp.options);
    colour_mod.colour_palette_free(&wp.palette);
    screen_mod.screen_free(wp.screen);
    xm.allocator.destroy(wp.screen);
    screen_mod.screen_free(&wp.base);
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

pub fn window_pane_mode(wp: *T.WindowPane) ?*T.WindowModeEntry {
    if (wp.modes.items.len == 0) return null;
    return wp.modes.items[0];
}

pub fn window_pane_push_mode(
    wp: *T.WindowPane,
    mode: *const T.WindowMode,
    data: ?*anyopaque,
    swp: ?*T.WindowPane,
) *T.WindowModeEntry {
    const wme = xm.allocator.create(T.WindowModeEntry) catch unreachable;
    wme.* = .{
        .wp = wp,
        .swp = swp,
        .mode = mode,
        .data = data,
    };
    wp.modes.insert(xm.allocator, 0, wme) catch unreachable;
    return wme;
}

pub fn window_pane_pop_mode(wp: *T.WindowPane, wme: *T.WindowModeEntry) bool {
    for (wp.modes.items, 0..) |current, idx| {
        if (current != wme) continue;
        _ = wp.modes.orderedRemove(idx);
        if (wp.modes.items.len == 0)
            wp.flags &= ~T.PANE_UNSEENCHANGES;
        xm.allocator.destroy(wme);
        return true;
    }
    return false;
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
        if (w.alerts_timer) |ev| {
            _ = c.libevent.event_del(ev);
            c.libevent.event_free(ev);
            w.alerts_timer = null;
        }
        if (w.name_event) |ev| {
            _ = c.libevent.event_del(ev);
            c.libevent.event_free(ev);
            w.name_event = null;
        }
        while (w.panes.items.len > 0) {
            const wp = w.panes.items[w.panes.items.len - 1];
            window_remove_pane(w, wp);
        }
        w.panes.deinit(xm.allocator);
        w.last_panes.deinit(xm.allocator);
        w.winlinks.deinit(xm.allocator);
        opts.options_free(w.options);
        if (w.old_layout) |old_layout| xm.allocator.free(old_layout);
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
    if (w.active == wp) return false;
    if (!window_has_pane(w, wp)) return false;
    const lastwp = w.active;
    remove_last_pane_reference(w, wp);
    if (lastwp) |old| push_last_pane(w, old);
    w.active = wp;
    wp.active_point = next_active_point;
    next_active_point +%= 1;
    wp.flags |= T.PANE_CHANGED;

    if (client_registry.clients.items.len != 0 and
        opts.options_get_number(opts.global_options, "focus-events") != 0)
    {
        if (lastwp) |old| window_pane_update_focus(old);
        window_pane_update_focus(w.active);
    }

    window_mark_viewing_clients_for_active_pane_change(w);
    if (_notify and w.winlinks.items.len != 0)
        notify.notify_window("window-pane-changed", w);
    return true;
}

pub fn window_update_focus(w: ?*T.Window) void {
    const window = w orelse return;
    window_pane_update_focus(window.active);
}

pub fn window_pane_update_focus(wp: ?*T.WindowPane) void {
    const pane = wp orelse return;
    if (pane.flags & T.PANE_EXITED != 0) return;

    const focused = window_pane_should_be_focused(pane);
    if (!focused and (pane.flags & T.PANE_FOCUSED) != 0) {
        if ((pane.base.mode & T.MODE_FOCUSON) != 0 and pane.fd >= 0)
            write_pane_bytes_best_effort(pane.fd, "\x1b[O");
        notify.notify_pane("pane-focus-out", pane);
        pane.flags &= ~@as(u32, T.PANE_FOCUSED);
    } else if (focused and (pane.flags & T.PANE_FOCUSED) == 0) {
        if ((pane.base.mode & T.MODE_FOCUSON) != 0 and pane.fd >= 0)
            write_pane_bytes_best_effort(pane.fd, "\x1b[I");
        notify.notify_pane("pane-focus-in", pane);
        pane.flags |= T.PANE_FOCUSED;
    }
}

pub fn window_rotate_panes(w: *T.Window, reverse: bool) ?*T.WindowPane {
    if (w.panes.items.len <= 1) return w.active;

    const PaneSlot = struct {
        pane: *T.WindowPane,
        sx: u32,
        sy: u32,
        xoff: u32,
        yoff: u32,
        layout_cell: ?*T.LayoutCell,
    };

    const count = w.panes.items.len;
    const slots = xm.allocator.alloc(PaneSlot, count) catch unreachable;
    defer xm.allocator.free(slots);
    const reordered = xm.allocator.alloc(*T.WindowPane, count) catch unreachable;
    defer xm.allocator.free(reordered);

    const old_active = w.active;
    var next_active: ?*T.WindowPane = null;

    for (w.panes.items, 0..) |pane, idx| {
        slots[idx] = .{
            .pane = pane,
            .sx = pane.sx,
            .sy = pane.sy,
            .xoff = pane.xoff,
            .yoff = pane.yoff,
            .layout_cell = pane.layout_cell,
        };
    }

    if (reverse) {
        reordered[0] = slots[count - 1].pane;
        for (1..count) |idx| reordered[idx] = slots[idx - 1].pane;
        if (old_active) |active| {
            const active_idx = window_pane_index(w, active) orelse 0;
            next_active = if (active_idx == 0) slots[count - 1].pane else slots[active_idx - 1].pane;
        }
    } else {
        for (0..count - 1) |idx| reordered[idx] = slots[idx + 1].pane;
        reordered[count - 1] = slots[0].pane;
        if (old_active) |active| {
            const active_idx = window_pane_index(w, active) orelse 0;
            next_active = if (active_idx + 1 < count) slots[active_idx + 1].pane else slots[0].pane;
        }
    }

    for (0..count) |idx| {
        const pane = reordered[idx];
        const slot = slots[idx];
        w.panes.items[idx] = pane;
        pane.sx = slot.sx;
        pane.sy = slot.sy;
        pane.xoff = slot.xoff;
        pane.yoff = slot.yoff;
        pane.layout_cell = slot.layout_cell;
        if (pane.layout_cell) |lc| lc.wp = pane;
    }

    if (next_active) |active| {
        _ = window_set_active_pane(w, active, true);
    }
    return w.active;
}

pub fn window_set_name(w: *T.Window, name: []const u8) void {
    xm.allocator.free(w.name);
    w.name = utf8.utf8_stravis(name, utf8.VIS_OCTAL | utf8.VIS_CSTYLE | utf8.VIS_TAB | utf8.VIS_NL);
    notify.notify_window("window-renamed", w);
}

pub fn window_resize(w: *T.Window, sx: u32, sy: u32, _xpixel: i32, _ypixel: i32) void {
    w.sx = sx;
    w.sy = sy;
    if (_xpixel != -1)
        w.xpixel = if (_xpixel == 0) T.DEFAULT_XPIXEL else @intCast(_xpixel);
    if (_ypixel != -1)
        w.ypixel = if (_ypixel == 0) T.DEFAULT_YPIXEL else @intCast(_ypixel);
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

pub fn window_pane_reset_contents(wp: *T.WindowPane) void {
    grid_mod.grid_reset(wp.base.grid);
    screen_mod.screen_reset(&wp.base);
    if (wp.screen.grid != wp.base.grid) {
        grid_mod.grid_reset(wp.screen.grid);
        screen_mod.screen_reset(wp.screen);
    }
    wp.input_pending.clearRetainingCapacity();
}

pub fn window_pane_visible(wp: *T.WindowPane) bool {
    if (wp.window.flags & T.WINDOW_ZOOMED == 0) return true;
    return wp == wp.window.active;
}

pub fn window_pane_show_scrollbar(wp: *T.WindowPane) bool {
    if (screen_mod.screen_alternate_active(wp)) return false;

    return switch (@as(u32, @intCast(opts.options_get_number(wp.options, "pane-scrollbars")))) {
        T.PANE_SCROLLBARS_ALWAYS => true,
        T.PANE_SCROLLBARS_MODAL => window_pane_mode(wp) != null,
        else => false,
    };
}

pub fn window_pane_update_scrollbar_geometry(wp: *T.WindowPane) void {
    wp.sb_slider_y = 0;
    wp.sb_slider_h = 0;

    if (!window_pane_show_scrollbar(wp) or wp.sy == 0) return;

    const screen = screen_mod.screen_current(wp);
    const sb_h = wp.sy;
    const total_height = screen.grid.sy + screen.grid.hsize;
    if (total_height == 0) return;

    const view = @as(f64, @floatFromInt(sb_h));
    const total = @as(f64, @floatFromInt(total_height));
    var slider_h: u32 = @intFromFloat(view * (view / total));
    if (slider_h < 1) slider_h = 1;

    var slider_y: u32 = sb_h - slider_h;
    if (window_pane_mode(wp) != null and screen.grid.hscrolled != 0) {
        const scrolled = @as(f64, @floatFromInt(screen.grid.hscrolled));
        slider_y = @min(
            sb_h - 1,
            @as(u32, @intFromFloat(@as(f64, @floatFromInt(sb_h + 1)) * (scrolled / total))),
        );
    }
    if (slider_y >= sb_h) slider_y = sb_h - 1;

    wp.sb_slider_y = slider_y;
    wp.sb_slider_h = slider_h;
}

pub fn window_pane_scrollbar_layout(wp: *T.WindowPane) ?ScrollbarLayout {
    window_pane_update_scrollbar_geometry(wp);
    if (!window_pane_show_scrollbar(wp) or wp.sb_slider_h == 0) return null;

    return .{
        .left = opts.options_get_number(wp.options, "pane-scrollbars-position") == T.PANE_SCROLLBARS_LEFT,
        .width = @intCast(@max(wp.scrollbar_style.width, 0)),
        .pad = @intCast(@max(wp.scrollbar_style.pad, 0)),
        .slider_y = wp.sb_slider_y,
        .slider_h = wp.sb_slider_h,
    };
}

pub fn window_pane_total_width(wp: *T.WindowPane) u32 {
    const layout = window_pane_scrollbar_layout(wp) orelse return wp.sx;
    return wp.sx + layout.width + layout.pad;
}

pub fn window_get_active_at(w: *T.Window, x: u32, y: u32) ?*T.WindowPane {
    for (w.panes.items) |pane| {
        if (!window_pane_visible(pane)) continue;
        const full = window_pane_draw_bounds(pane);
        if (x < full.xoff or x > full.xoff + full.sx) continue;
        if (y < full.yoff or y > full.yoff + full.sy) continue;
        return pane;
    }
    return null;
}

pub fn window_hit_test(w: *T.Window, x: u32, y: u32) ?PaneHit {
    const candidate = window_get_active_at(w, x, y);
    if (candidate) |pane| {
        window_pane_update_scrollbar_geometry(pane);
        if (x >= pane.xoff and x < pane.xoff + pane.sx and y >= pane.yoff and y < pane.yoff + pane.sy) {
            return .{ .pane = pane, .region = .pane };
        }

        if (window_pane_scrollbar_layout(pane)) |layout| {
            const scroll_start = if (layout.left)
                pane.xoff -| (layout.pad + layout.width)
            else
                pane.xoff + pane.sx + layout.pad;
            const scroll_end = scroll_start + layout.width;

            if (x >= scroll_start and x < scroll_end) {
                const slider_top = pane.yoff + layout.slider_y;
                const slider_bottom = slider_top + layout.slider_h - 1;
                if (y < slider_top)
                    return .{ .pane = pane, .region = .scrollbar_up };
                if (y <= slider_bottom)
                    return .{
                        .pane = pane,
                        .region = .scrollbar_slider,
                        .slider_mpos = @intCast(y - slider_top),
                    };
                return .{ .pane = pane, .region = .scrollbar_down };
            }
        }
    }

    if (w.flags & T.WINDOW_ZOOMED != 0) return null;

    for (w.panes.items) |pane| {
        if (!window_pane_visible(pane)) continue;
        const full = window_pane_draw_bounds(pane);
        const right_border = full.xoff + full.sx;

        if (x == right_border and pane.yoff <= y + 1 and pane.yoff + pane.sy >= y)
            return .{ .pane = pane, .region = .border };
        if (y == pane.yoff + pane.sy and pane.xoff <= x + 1 and pane.xoff + pane.sx >= x)
            return .{ .pane = pane, .region = .border };
    }

    if (candidate) |pane| {
        return .{ .pane = pane, .region = .pane };
    }

    return null;
}

pub fn window_pane_synchronize_key_bytes(wp: *T.WindowPane, key: T.key_code, bytes: []const u8) void {
    if (bytes.len == 0) return;
    if (T.keycIsMouse(key)) return;
    if (opts.options_get_number(wp.options, "synchronize-panes") == 0) return;

    for (wp.window.panes.items) |loop| {
        if (loop == wp) continue;
        if (loop.fd < 0 or loop.flags & T.PANE_INPUTOFF != 0) continue;
        if (!window_pane_visible(loop)) continue;
        if (opts.options_get_number(loop.options, "synchronize-panes") == 0) continue;
        write_pane_bytes_best_effort(loop.fd, bytes);
    }
}

pub fn window_zoom(wp: *T.WindowPane) bool {
    const w = wp.window;
    if (w.flags & T.WINDOW_ZOOMED != 0) return false;
    if (window_count_panes(w) <= 1) return false;
    if (w.active != wp) _ = window_set_active_pane(w, wp, true);
    w.flags |= T.WINDOW_ZOOMED;
    return true;
}

pub fn window_unzoom(w: *T.Window) bool {
    if (w.flags & T.WINDOW_ZOOMED == 0) return false;
    w.flags &= ~@as(u32, T.WINDOW_ZOOMED);
    return true;
}

/// Push current zoom state.
pub fn window_push_zoom(w: *T.Window, always: bool, zoom: bool) bool {
    if (zoom and (always or (w.flags & T.WINDOW_ZOOMED != 0)))
        w.flags |= T.WINDOW_WASZOOMED
    else
        w.flags &= ~@as(u32, T.WINDOW_WASZOOMED);

    return window_unzoom(w);
}

/// Pop zoom state.
pub fn window_pop_zoom(w: *T.Window) bool {
    if (w.flags & T.WINDOW_WASZOOMED == 0) return false;
    w.flags &= ~@as(u32, T.WINDOW_WASZOOMED);

    const active = w.active orelse return false;
    return window_zoom(active);
}

pub fn window_redraw_active_switch(_w: *T.Window, _wp: *T.WindowPane) void {
    const w = _w;
    const wp = _wp;
    const active = w.active orelse return;

    if (wp == active) return;

    // The reduced renderer does not cache separate active/inactive pane body
    // styles, so mark both panes dirty whenever the active pane changes.
    wp.flags |= T.PANE_REDRAW;
    active.flags |= T.PANE_REDRAW;
}

pub fn window_has_pane(w: *T.Window, wp: *T.WindowPane) bool {
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

fn window_clear_client_pane_reference(w: *T.Window, wp: *T.WindowPane) void {
    for (client_registry.clients.items) |cl| {
        var i: usize = 0;
        while (i < cl.client_windows.items.len) {
            const cw = cl.client_windows.items[i];
            if (cw.window == w.id and cw.pane == wp) {
                _ = cl.client_windows.swapRemove(i);
                continue;
            }
            i += 1;
        }
    }
}

fn pane_geometry(wp: *T.WindowPane) PaneGeometry {
    return .{
        .xoff = wp.xoff,
        .yoff = wp.yoff,
        .sx = wp.sx,
        .sy = wp.sy,
    };
}

fn collapse_detached_pane_gap(w: *T.Window, removed: PaneGeometry) void {
    if (w.panes.items.len == 0) return;

    if (w.panes.items.len == 1) {
        apply_pane_geometry(w.panes.items[0], .{
            .xoff = 0,
            .yoff = 0,
            .sx = w.sx,
            .sy = w.sy,
        });
        return;
    }

    if (find_gap_absorber(w, removed)) |absorber| {
        var geometry = pane_geometry(absorber);

        if (geometry.xoff + geometry.sx + 1 == removed.xoff and geometry.yoff == removed.yoff and geometry.sy == removed.sy) {
            geometry.sx += removed.sx + 1;
        } else if (removed.xoff + removed.sx + 1 == geometry.xoff and geometry.yoff == removed.yoff and geometry.sy == removed.sy) {
            geometry.xoff = removed.xoff;
            geometry.sx += removed.sx + 1;
        } else if (geometry.yoff + geometry.sy + 1 == removed.yoff and geometry.xoff == removed.xoff and geometry.sx == removed.sx) {
            geometry.sy += removed.sy + 1;
        } else if (removed.yoff + removed.sy + 1 == geometry.yoff and geometry.xoff == removed.xoff and geometry.sx == removed.sx) {
            geometry.yoff = removed.yoff;
            geometry.sy += removed.sy + 1;
        } else {
            return;
        }

        apply_pane_geometry(absorber, geometry);
    }
}

fn find_gap_absorber(w: *T.Window, removed: PaneGeometry) ?*T.WindowPane {
    for (w.panes.items) |pane| {
        const geometry = pane_geometry(pane);
        if (geometry.xoff + geometry.sx + 1 == removed.xoff and geometry.yoff == removed.yoff and geometry.sy == removed.sy)
            return pane;
    }
    for (w.panes.items) |pane| {
        const geometry = pane_geometry(pane);
        if (removed.xoff + removed.sx + 1 == geometry.xoff and geometry.yoff == removed.yoff and geometry.sy == removed.sy)
            return pane;
    }
    for (w.panes.items) |pane| {
        const geometry = pane_geometry(pane);
        if (geometry.yoff + geometry.sy + 1 == removed.yoff and geometry.xoff == removed.xoff and geometry.sx == removed.sx)
            return pane;
    }
    for (w.panes.items) |pane| {
        const geometry = pane_geometry(pane);
        if (removed.yoff + removed.sy + 1 == geometry.yoff and geometry.xoff == removed.xoff and geometry.sx == removed.sx)
            return pane;
    }
    return null;
}

fn apply_pane_geometry(wp: *T.WindowPane, geometry: PaneGeometry) void {
    wp.xoff = geometry.xoff;
    wp.yoff = geometry.yoff;
    wp.sx = geometry.sx;
    wp.sy = geometry.sy;
}

pub const PaneDrawBounds = struct {
    xoff: u32,
    yoff: u32,
    sx: u32,
    sy: u32,
};

pub fn window_pane_draw_bounds(wp: *T.WindowPane) PaneDrawBounds {
    const layout = window_pane_scrollbar_layout(wp);
    const sb_total: u32 = if (layout) |sb| sb.width + sb.pad else 0;

    return .{
        .xoff = if (layout != null and layout.?.left) wp.xoff -| sb_total else wp.xoff,
        .yoff = wp.yoff,
        .sx = wp.sx + sb_total,
        .sy = wp.sy,
    };
}

fn pane_range_end(start: u32, len: u32) u32 {
    return if (len == 0) start else start + len - 1;
}

fn pane_ranges_overlap(left: u32, right: u32, cand_left: u32, cand_right: u32) bool {
    return !(cand_right < left or cand_left > right);
}

fn trim_trailing_ascii_whitespace(text: []const u8) []const u8 {
    var end = text.len;
    while (end > 0 and std.ascii.isWhitespace(text[end - 1])) : (end -= 1) {}
    return text[0..end];
}

fn choose_better_pane(best: ?*T.WindowPane, candidate: *T.WindowPane) *T.WindowPane {
    if (best == null) return candidate;
    if (candidate.active_point > best.?.active_point) return candidate;
    return best.?;
}

fn window_pane_should_be_focused(wp: *T.WindowPane) bool {
    if (wp.window.active != wp) return false;

    for (client_registry.clients.items) |cl| {
        const s = cl.session orelse continue;
        const wl = s.curw orelse continue;
        if (s.attached == 0) continue;
        if ((cl.flags & T.CLIENT_FOCUSED) == 0) continue;
        if (wl.window == wp.window) return true;
    }
    return false;
}

fn window_mark_viewing_clients_for_active_pane_change(w: *T.Window) void {
    for (client_registry.clients.items) |cl| {
        const s = cl.session orelse continue;
        const wl = s.curw orelse continue;
        if ((cl.flags & T.CLIENT_ATTACHED) == 0) continue;
        if ((cl.flags & T.CLIENT_TERMINAL) == 0) continue;
        if (wl.window != w) continue;
        cl.flags |= T.CLIENT_REDRAWWINDOW | T.CLIENT_REDRAWSTATUS;
    }
}

fn write_pane_bytes_best_effort(fd: i32, bytes: []const u8) void {
    var rest = bytes;
    while (rest.len > 0) {
        const written = std.posix.write(fd, rest) catch return;
        if (written == 0) return;
        rest = rest[written..];
    }
}
