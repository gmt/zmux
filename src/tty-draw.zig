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
// Written for zmux by Greg Turner. This file is new zmux runtime work that
// sits between the reduced screen substrate and the attached client path.

//! tty-draw.zig – pane-only ANSI redraw with row caching.

const std = @import("std");
const T = @import("types.zig");
const grid_mod = @import("grid.zig");
const window_mod = @import("window.zig");
const xm = @import("xmalloc.zig");
const screen_mod = @import("screen.zig");
const opts = @import("options.zig");
const style_mod = @import("style.zig");
const tty_acs = @import("tty-acs.zig");
const utf8 = @import("utf8.zig");
const sixel = @import("image-sixel.zig");
const hyperlinks_mod = @import("hyperlinks.zig");

pub const WindowRenderResult = struct {
    payload: []u8 = &.{},
    cursor_visible: bool = false,
    cursor_x: u32 = 0,
    cursor_y: u32 = 0,
};

pub fn tty_draw_invalidate(cache: *T.ClientPaneCache) void {
    free_rows(cache);
    cache.pane_id = null;
    cache.sx = 0;
    cache.sy = 0;
    cache.scrollbar_left = false;
    cache.scrollbar_width = 0;
    cache.scrollbar_pad = 0;
    cache.scrollbar_slider_y = 0;
    cache.scrollbar_slider_h = 0;
    cache.cursor_x = 0;
    cache.cursor_y = 0;
    cache.cursor_visible = true;
    cache.valid = false;
}

pub fn tty_draw_free(cache: *T.ClientPaneCache) void {
    tty_draw_invalidate(cache);
    cache.rows.deinit(xm.allocator);
}

pub fn tty_draw_pane(
    cache: *T.ClientPaneCache,
    wp: *T.WindowPane,
    sx: u32,
    sy: u32,
) ![]u8 {
    return tty_draw_pane_offset(cache, wp, sx, sy, 0);
}

pub fn tty_draw_pane_offset(
    cache: *T.ClientPaneCache,
    wp: *T.WindowPane,
    sx: u32,
    sy: u32,
    row_offset: u32,
) ![]u8 {
    var out: std.ArrayList(u8) = .{};
    defer out.deinit(xm.allocator);
    const screen = screen_mod.screen_current(wp);
    const scrollbar = window_mod.window_pane_scrollbar_layout(wp);
    var update_started = false;

    const full_redraw =
        !cache.valid or
        cache.pane_id != wp.id or
        cache.sx != sx or
        cache.sy != sy or
        cache.scrollbar_left != (scrollbar != null and scrollbar.?.left) or
        cache.scrollbar_width != (if (scrollbar) |layout| layout.width else 0) or
        cache.scrollbar_pad != (if (scrollbar) |layout| layout.pad else 0) or
        cache.scrollbar_slider_y != (if (scrollbar) |layout| layout.slider_y else 0) or
        cache.scrollbar_slider_h != (if (scrollbar) |layout| layout.slider_h else 0);

    if (full_redraw) {
        try begin_update(&out, &update_started);
        try out.appendSlice(xm.allocator, "\x1b[H\x1b[2J");
        free_rows(cache);
        cache.pane_id = wp.id;
        cache.sx = sx;
        cache.sy = sy;
        cache.scrollbar_left = scrollbar != null and scrollbar.?.left;
        cache.scrollbar_width = if (scrollbar) |layout| layout.width else 0;
        cache.scrollbar_pad = if (scrollbar) |layout| layout.pad else 0;
        cache.scrollbar_slider_y = if (scrollbar) |layout| layout.slider_y else 0;
        cache.scrollbar_slider_h = if (scrollbar) |layout| layout.slider_h else 0;
        cache.valid = true;
    }

    const row_count: usize = @intCast(sy);
    if (cache.rows.items.len < row_count) {
        try cache.rows.ensureTotalCapacity(xm.allocator, row_count);
        while (cache.rows.items.len < row_count) {
            cache.rows.appendAssumeCapacity(xm.xstrdup(""));
        }
    } else if (cache.rows.items.len > row_count) {
        for (cache.rows.items[row_count..]) |row| xm.allocator.free(row);
        cache.rows.shrinkRetainingCapacity(row_count);
    }

    for (0..row_count) |row_idx| {
        const rendered = try render_pane_row(wp, screen, @intCast(row_idx), sx, scrollbar, screen.hyperlinks);
        defer xm.allocator.free(rendered);

        if (full_redraw or !std.mem.eql(u8, cache.rows.items[row_idx], rendered)) {
            try begin_update(&out, &update_started);
            const move = try std.fmt.allocPrint(xm.allocator, "\x1b[{d};1H", .{row_offset + row_idx + 1});
            defer xm.allocator.free(move);
            try out.appendSlice(xm.allocator, move);
            try out.appendSlice(xm.allocator, rendered);
            try out.appendSlice(xm.allocator, "\x1b[K");

            xm.allocator.free(cache.rows.items[row_idx]);
            cache.rows.items[row_idx] = try xm.allocator.dupe(u8, rendered);
        }
    }

    try append_sixel_images(&out, screen, wp, row_offset, 0, 0);

    const cursor_prefix = if (scrollbar != null and scrollbar.?.left)
        @min(sx, scrollbar.?.width + scrollbar.?.pad)
    else
        0;
    const cursor_y = @min(screen.cy, sy - 1);
    const cursor_x = @min(cursor_prefix + screen.cx, sx - 1);
    const cursor_changed = full_redraw or
        cache.cursor_x != cursor_x or
        cache.cursor_y != cursor_y or
        cache.cursor_visible != screen.cursor_visible;
    if (cursor_changed) {
        try begin_update(&out, &update_started);
    }
    if (screen.cursor_visible and (full_redraw or cache.cursor_x != cursor_x or cache.cursor_y != cursor_y or !cache.cursor_visible)) {
        const cursor = try std.fmt.allocPrint(xm.allocator, "\x1b[{d};{d}H", .{ row_offset + cursor_y + 1, cursor_x + 1 });
        defer xm.allocator.free(cursor);
        try out.appendSlice(xm.allocator, cursor);
    }
    cache.cursor_x = cursor_x;
    cache.cursor_y = cursor_y;
    cache.cursor_visible = screen.cursor_visible;

    if (update_started and screen.cursor_visible) try out.appendSlice(xm.allocator, "\x1b[?25h");
    return out.toOwnedSlice(xm.allocator);
}

pub fn tty_draw_render_window(
    w: *T.Window,
    sx_limit: u32,
    sy_limit: u32,
    row_offset: u32,
) !WindowRenderResult {
    return tty_draw_render_window_region(w, 0, 0, sx_limit, sy_limit, row_offset);
}

pub fn tty_draw_render_window_region(
    w: *T.Window,
    view_x: u32,
    view_y: u32,
    sx_limit: u32,
    sy_limit: u32,
    row_offset: u32,
) !WindowRenderResult {
    var result = WindowRenderResult{};
    if (sx_limit == 0 or sy_limit == 0) return result;

    var out: std.ArrayList(u8) = .{};
    errdefer out.deinit(xm.allocator);

    try out.appendSlice(xm.allocator, "\x1b[?25l\x1b[H\x1b[2J");

    for (w.panes.items) |wp| {
        if (!window_mod.window_pane_visible(wp)) continue;

        const bounds = window_mod.window_pane_draw_bounds(wp);
        const region = intersect_region(bounds.xoff, bounds.yoff, bounds.sx, bounds.sy, view_x, view_y, sx_limit, sy_limit) orelse continue;
        const screen = screen_mod.screen_current(wp);
        const scrollbar = window_mod.window_pane_scrollbar_layout(wp);

        for (0..region.height) |row_idx| {
            const absolute_row = region.start_y + @as(u32, @intCast(row_idx));
            const rendered = try render_pane_row_region(
                wp,
                screen,
                absolute_row - bounds.yoff,
                region.start_x - bounds.xoff,
                region.width,
                scrollbar,
                screen.hyperlinks,
            );
            defer xm.allocator.free(rendered);

            try append_move(
                &out,
                row_offset + (absolute_row - view_y) + 1,
                region.start_x - view_x + 1,
            );
            try out.appendSlice(xm.allocator, rendered);
        }

        try append_sixel_images(&out, screen, wp, row_offset, view_x, view_y);
    }

    if (w.active) |active| {
        const bounds = window_mod.window_pane_draw_bounds(active);
        const screen = screen_mod.screen_current(active);
        if (screen.cursor_visible and screen.cx < active.sx and screen.cy < active.sy) {
            const scrollbar = window_mod.window_pane_scrollbar_layout(active);
            const cursor_prefix = if (scrollbar != null and scrollbar.?.left)
                @min(bounds.sx, scrollbar.?.width + scrollbar.?.pad)
            else
                0;
            const cursor_x = bounds.xoff + cursor_prefix + screen.cx;
            const cursor_y = bounds.yoff + screen.cy;
            if (cursor_x >= view_x and cursor_x < view_x + sx_limit and
                cursor_y >= view_y and cursor_y < view_y + sy_limit)
            {
                result.cursor_visible = true;
                result.cursor_x = cursor_x - view_x;
                result.cursor_y = row_offset + (cursor_y - view_y);
                try append_move(&out, result.cursor_y + 1, result.cursor_x + 1);
                try out.appendSlice(xm.allocator, "\x1b[?25h");
            }
        }
    }

    result.payload = try out.toOwnedSlice(xm.allocator);
    return result;
}

pub fn tty_draw_render_dirty_panes(
    w: *T.Window,
    sx_limit: u32,
    sy_limit: u32,
    row_offset: u32,
) ![]u8 {
    return tty_draw_render_dirty_panes_region(w, 0, 0, sx_limit, sy_limit, row_offset);
}

pub fn tty_draw_render_dirty_panes_region(
    w: *T.Window,
    view_x: u32,
    view_y: u32,
    sx_limit: u32,
    sy_limit: u32,
    row_offset: u32,
) ![]u8 {
    var out: std.ArrayList(u8) = .{};
    defer out.deinit(xm.allocator);

    for (w.panes.items) |wp| {
        if (!window_mod.window_pane_visible(wp)) continue;
        if (wp.flags & T.PANE_REDRAW == 0) continue;

        const bounds = window_mod.window_pane_draw_bounds(wp);
        const region = intersect_region(bounds.xoff, bounds.yoff, bounds.sx, bounds.sy, view_x, view_y, sx_limit, sy_limit) orelse continue;
        const screen = screen_mod.screen_current(wp);
        const scrollbar = window_mod.window_pane_scrollbar_layout(wp);

        for (0..region.height) |row_idx| {
            const absolute_row = region.start_y + @as(u32, @intCast(row_idx));
            const rendered = try render_pane_row_region(
                wp,
                screen,
                absolute_row - bounds.yoff,
                region.start_x - bounds.xoff,
                region.width,
                scrollbar,
                screen.hyperlinks,
            );
            defer xm.allocator.free(rendered);

            try append_move(
                &out,
                row_offset + (absolute_row - view_y) + 1,
                region.start_x - view_x + 1,
            );
            try out.appendSlice(xm.allocator, rendered);
        }

        try append_sixel_images(&out, screen, wp, row_offset, view_x, view_y);
    }

    return out.toOwnedSlice(xm.allocator);
}

pub fn tty_draw_render_borders(
    tty: ?*const T.Tty,
    w: *T.Window,
    sx_limit: u32,
    sy_limit: u32,
    row_offset: u32,
) ![]u8 {
    return tty_draw_render_borders_region(tty, w, 0, 0, sx_limit, sy_limit, row_offset);
}

pub fn tty_draw_render_borders_region(
    tty: ?*const T.Tty,
    w: *T.Window,
    view_x: u32,
    view_y: u32,
    sx_limit: u32,
    sy_limit: u32,
    row_offset: u32,
) ![]u8 {
    var out: std.ArrayList(u8) = .{};
    defer out.deinit(xm.allocator);

    for (0..sy_limit) |row_idx| {
        for (0..sx_limit) |col_idx| {
            const border = borderCellAt(
                w,
                @intCast(view_x + @as(u32, @intCast(col_idx))),
                @intCast(view_y + @as(u32, @intCast(row_idx))),
            ) orelse continue;
            const cell = makeBorderCell(tty, border.pane, border.cell_type);

            var renderer = RowRenderer{};
            defer renderer.deinit();
            try renderer.appendCell(&cell);
            const rendered = try renderer.finish();
            defer xm.allocator.free(rendered);

            try append_move(&out, row_offset + @as(u32, @intCast(row_idx)) + 1, @as(u32, @intCast(col_idx)) + 1);
            try out.appendSlice(xm.allocator, rendered);
        }
    }

    return out.toOwnedSlice(xm.allocator);
}

pub fn tty_draw_render_scrollbars(
    w: *T.Window,
    sx_limit: u32,
    sy_limit: u32,
    row_offset: u32,
) ![]u8 {
    return tty_draw_render_scrollbars_region(w, 0, 0, sx_limit, sy_limit, row_offset);
}

pub fn tty_draw_render_scrollbars_region(
    w: *T.Window,
    view_x: u32,
    view_y: u32,
    sx_limit: u32,
    sy_limit: u32,
    row_offset: u32,
) ![]u8 {
    var out: std.ArrayList(u8) = .{};
    defer out.deinit(xm.allocator);

    for (w.panes.items) |wp| {
        if (!window_mod.window_pane_visible(wp)) continue;
        const layout = window_mod.window_pane_scrollbar_layout(wp) orelse continue;
        const bounds = window_mod.window_pane_draw_bounds(wp);
        const start_x = if (layout.left)
            bounds.xoff
        else
            bounds.xoff + bounds.sx - (layout.width + layout.pad);
        const region = intersect_region(
            start_x,
            bounds.yoff,
            layout.width + layout.pad,
            bounds.sy,
            view_x,
            view_y,
            sx_limit,
            sy_limit,
        ) orelse continue;
        for (0..region.height) |row_idx| {
            const absolute_row = region.start_y + @as(u32, @intCast(row_idx));
            const rendered = try render_scrollbar_row_region(
                wp,
                absolute_row - bounds.yoff,
                region.start_x - start_x,
                region.width,
                layout.left,
                layout,
            );
            defer xm.allocator.free(rendered);

            try append_move(
                &out,
                row_offset + (absolute_row - view_y) + 1,
                region.start_x - view_x + 1,
            );
            try out.appendSlice(xm.allocator, rendered);
        }
    }

    return out.toOwnedSlice(xm.allocator);
}

pub fn tty_draw_render_screen(screen: *T.Screen, sx: u32, sy: u32, row_offset: u32) ![]u8 {
    return tty_draw_render_screen_region(screen, 0, 0, sx, sy, row_offset, 0);
}

pub fn tty_draw_render_screen_region(
    screen: *T.Screen,
    view_x: u32,
    view_y: u32,
    sx: u32,
    sy: u32,
    row_offset: u32,
    col_offset: u32,
) ![]u8 {
    var out: std.ArrayList(u8) = .{};
    defer out.deinit(xm.allocator);

    for (0..sy) |row_idx| {
        const row = view_y + @as(u32, @intCast(row_idx));
        if (row >= screen.grid.sy) break;
        const rendered = try render_text_row_region(screen.grid, row, view_x, sx, screen);
        defer xm.allocator.free(rendered);
        try append_move(&out, row_offset + @as(u32, @intCast(row_idx)) + 1, col_offset + 1);
        try out.appendSlice(xm.allocator, rendered);
        try out.appendSlice(xm.allocator, "\x1b[K");
    }

    return out.toOwnedSlice(xm.allocator);
}

fn begin_update(out: *std.ArrayList(u8), started: *bool) !void {
    if (started.*) return;
    try out.appendSlice(xm.allocator, "\x1b[?25l");
    started.* = true;
}

fn append_move(out: *std.ArrayList(u8), row: u32, col: u32) !void {
    const move = try std.fmt.allocPrint(xm.allocator, "\x1b[{d};{d}H", .{ row, col });
    defer xm.allocator.free(move);
    try out.appendSlice(xm.allocator, move);
}

/// Append sixel images for all images on a screen.  When the client
/// terminal supports sixel, emit real DCS sixel data via sixel_print;
/// otherwise fall back to text placeholders.
fn append_sixel_images(
    out: *std.ArrayList(u8),
    screen: *T.Screen,
    wp: *T.WindowPane,
    row_offset: u32,
    view_x: u32,
    view_y: u32,
) !void {
    const sixel_mod = @import("image-sixel.zig");
    for (screen.images.items) |im| {
        const abs_x = wp.xoff + im.px;
        const abs_y = wp.yoff + im.py;
        if (abs_x < view_x or abs_y < view_y) continue;
        const x = abs_x - view_x;
        const y = abs_y - view_y;

        try append_move(out, row_offset + y + 1, x + 1);

        // Emit real sixel DCS data; fall back to text placeholder on failure.
        if (sixel_mod.sixel_print(im.data, null)) |printed| {
            defer xm.allocator.free(printed);
            try out.appendSlice(xm.allocator, printed);
        } else if (im.fallback) |fb| {
            try out.appendSlice(xm.allocator, fb);
        }
    }
}

const CellStyle = struct {
    attr: u16 = 0,
    fg: i32 = 0,
    bg: i32 = 0,
    link: u32 = 0,
};

const RowRenderer = struct {
    out: std.ArrayList(u8) = .{},
    last_style: CellStyle = .{},
    have_style: bool = false,
    hyperlinks: ?*hyperlinks_mod.Hyperlinks = null,

    fn deinit(self: *RowRenderer) void {
        self.out.deinit(xm.allocator);
    }

    fn appendCell(self: *RowRenderer, cell: *const T.GridCell) !void {
        const style = style_of(cell.*);
        if (!self.have_style or !std.meta.eql(style, self.last_style)) {
            const sgr = try style_to_sgr(style);
            defer xm.allocator.free(sgr);
            try self.out.appendSlice(xm.allocator, sgr);

            if (style.link != self.last_style.link) {
                try self.emitHyperlink(style.link);
            }

            self.last_style = style;
            self.have_style = true;
        }

        const bytes = if (cell.payload().isEmpty()) " " else cell.payload().bytes();
        try self.out.appendSlice(xm.allocator, bytes);
    }

    /// Emit an OSC 8 hyperlink escape for the given link id.
    /// link == 0 closes the current hyperlink; link != 0 opens one.
    fn emitHyperlink(self: *RowRenderer, link: u32) !void {
        if (link == 0) {
            try self.out.appendSlice(xm.allocator, "\x1b]8;;\x1b\\");
            return;
        }
        const hl = self.hyperlinks orelse return;
        var uri: []const u8 = "";
        var id: []const u8 = "";
        if (hyperlinks_mod.hyperlinks_get(hl, link, &uri, null, &id)) {
            const seq = try std.fmt.allocPrint(xm.allocator, "\x1b]8;id={s};{s}\x1b\\", .{ id, uri });
            defer xm.allocator.free(seq);
            try self.out.appendSlice(xm.allocator, seq);
        }
    }

    fn finish(self: *RowRenderer) ![]u8 {
        if (self.have_style and self.last_style.link != 0)
            try self.emitHyperlink(0);
        if (self.have_style and !style_is_default(self.last_style))
            try self.out.appendSlice(xm.allocator, "\x1b[0m");
        return self.out.toOwnedSlice(xm.allocator);
    }
};

/// tmux `tty_draw_line`: zmux draws panes via cached ANSI rows, not a live `Tty`.
pub fn tty_draw_line(
    tty: *T.Tty,
    s: *T.Screen,
    px: u32,
    py: u32,
    nx: u32,
    atx: u32,
    aty: u32,
    defaults: *const T.GridCell,
    palette: *const T.ColourPalette,
) void {
    _ = tty;
    _ = s;
    _ = px;
    _ = py;
    _ = nx;
    _ = atx;
    _ = aty;
    _ = defaults;
    _ = palette;
}

/// tmux `tty_draw_line_clear` (stub: no direct TTY cell clearing in this module).
pub fn tty_draw_line_clear(
    tty: *T.Tty,
    px: u32,
    py: u32,
    nx: u32,
    defaults: *const T.GridCell,
    bg: u32,
    wrapped: bool,
) void {
    _ = tty;
    _ = px;
    _ = py;
    _ = nx;
    _ = defaults;
    _ = bg;
    _ = wrapped;
}

/// tmux `tty_draw_line_get_empty` — display cells to treat as empty for line drawing.
pub fn tty_draw_line_get_empty(gc: *const T.GridCell, nx: u32) u32 {
    var empty: u32 = 0;
    if (gc.data.width != 1 and gc.data.width > nx) {
        empty = nx;
    } else if (gc.attr == 0 and gc.link == 0) {
        if ((gc.flags & T.GRID_FLAG_CLEARED) != 0) {
            empty = 1;
        } else if ((gc.flags & T.GRID_FLAG_TAB) != 0) {
            empty = gc.data.width;
        } else if (gc.data.size == 1 and gc.data.data[0] == ' ') {
            empty = 1;
        }
    }
    return empty;
}

fn render_pane_row(
    wp: *T.WindowPane,
    s: *T.Screen,
    row: u32,
    sx: u32,
    scrollbar: ?window_mod.ScrollbarLayout,
    hl: ?*hyperlinks_mod.Hyperlinks,
) ![]u8 {
    return render_pane_row_region(wp, s, row, 0, sx, scrollbar, hl);
}

fn render_pane_row_region(
    wp: *T.WindowPane,
    s: *T.Screen,
    row: u32,
    start_col: u32,
    sx: u32,
    scrollbar: ?window_mod.ScrollbarLayout,
    hl: ?*hyperlinks_mod.Hyperlinks,
) ![]u8 {
    if (scrollbar == null) return render_text_row_region(s.grid, row, start_col, sx, s);

    const layout = scrollbar.?;
    const extra = layout.width + layout.pad;
    var renderer = RowRenderer{ .hyperlinks = hl };
    errdefer renderer.deinit();

    if (layout.left) {
        const scrollbar_width = overlap_width(start_col, sx, 0, extra);
        if (scrollbar_width != 0)
            try append_scrollbar_segment_range(&renderer, wp, row, start_col, scrollbar_width, true, layout);

        const text_start = @max(start_col, extra) - extra;
        const text_width = overlap_width(start_col, sx, extra, wp.sx);
        if (text_width != 0)
            try append_text_cells_range(&renderer, s.grid, row, text_start, text_width, s);
    } else {
        const text_width = overlap_width(start_col, sx, 0, wp.sx);
        if (text_width != 0)
            try append_text_cells_range(&renderer, s.grid, row, start_col, text_width, s);

        const scrollbar_start = @max(start_col, wp.sx) - wp.sx;
        const scrollbar_width = overlap_width(start_col, sx, wp.sx, extra);
        if (scrollbar_width != 0)
            try append_scrollbar_segment_range(&renderer, wp, row, scrollbar_start, scrollbar_width, false, layout);
    }

    return renderer.finish();
}

fn render_text_row(gd: *T.Grid, row: u32, sx: u32) ![]u8 {
    return render_text_row_region(gd, row, 0, sx, null);
}

fn render_text_row_region(gd: *T.Grid, row: u32, start_col: u32, sx: u32, s: ?*T.Screen) ![]u8 {
    var renderer = RowRenderer{ .hyperlinks = if (s) |scr| scr.hyperlinks else null };
    errdefer renderer.deinit();
    try append_text_cells_range(&renderer, gd, row, start_col, sx, s);
    return renderer.finish();
}

fn append_text_cells(renderer: *RowRenderer, gd: *T.Grid, row: u32, sx: u32) !void {
    try append_text_cells_range(renderer, gd, row, 0, sx, null);
}

fn append_text_cells_range(renderer: *RowRenderer, gd: *T.Grid, row: u32, start_col: u32, sx: u32, s: ?*T.Screen) !void {
    var col = start_col;
    const end_col = start_col + sx;
    while (col < end_col) {
        var cell: T.GridCell = undefined;
        grid_mod.get_cell(gd, row, @intCast(col), &cell);
        const remaining = end_col - col;

        if (cell.isPadding()) {
            const padding_col = col;
            while (col < end_col) : (col += 1) {
                grid_mod.get_cell(gd, row, @intCast(col), &cell);
                if (!cell.isPadding()) break;
            }
            try append_cleared_cells(renderer, col - padding_col, cleared_bg_before(gd, row, padding_col));
            continue;
        }

        const cell_width = @max(@as(u32, cell.data.width), 1);
        if (cell_width > remaining) {
            try append_cleared_cells(renderer, remaining, cell.bg);
            break;
        }

        var ngc: T.GridCell = undefined;
        const render_cell = if (s) |screen| blk: {
            break :blk if (cell.flags & T.GRID_FLAG_SELECTED != 0 and
                screen_mod.screen_select_cell(screen, &ngc, &cell)) &ngc else &cell;
        } else &cell;

        try renderer.appendCell(render_cell);
        col += cell_width;
    }
}

fn append_cleared_cells(renderer: *RowRenderer, count: u32, bg: i32) !void {
    var cleared = T.grid_default_cell;
    cleared.bg = bg;

    var idx: u32 = 0;
    while (idx < count) : (idx += 1) {
        try renderer.appendCell(&cleared);
    }
}

fn cleared_bg_before(gd: *T.Grid, row: u32, start_col: u32) i32 {
    var col = start_col;
    while (col > 0) {
        col -= 1;
        var cell: T.GridCell = undefined;
        grid_mod.get_cell(gd, row, @intCast(col), &cell);
        if (!cell.isPadding()) return cell.bg;
    }
    return T.grid_default_cell.bg;
}

fn append_scrollbar_segment(
    renderer: *RowRenderer,
    wp: *T.WindowPane,
    row: u32,
    count: u32,
    left: bool,
    layout: window_mod.ScrollbarLayout,
) !void {
    try append_scrollbar_segment_range(renderer, wp, row, 0, count, left, layout);
}

fn append_scrollbar_segment_range(
    renderer: *RowRenderer,
    wp: *T.WindowPane,
    row: u32,
    start: u32,
    count: u32,
    left: bool,
    layout: window_mod.ScrollbarLayout,
) !void {
    var gc = wp.scrollbar_style.gc;
    var slider_gc = gc;
    slider_gc.fg = gc.bg;
    slider_gc.bg = gc.fg;

    var idx: u32 = 0;
    while (idx < count) : (idx += 1) {
        const segment_idx = start + idx;
        const is_pad = if (left) segment_idx >= layout.width else segment_idx < layout.pad;
        if (is_pad) {
            try renderer.appendCell(&T.grid_default_cell);
            continue;
        }

        const on_slider = row >= layout.slider_y and row < layout.slider_y + layout.slider_h;
        try renderer.appendCell(if (on_slider) &slider_gc else &gc);
    }
}

fn render_row(gd: *T.Grid, row: u32, sx: u32) ![]u8 {
    return render_text_row(gd, row, sx, null);
}

fn render_scrollbar_row(
    wp: *T.WindowPane,
    row: u32,
    sx: u32,
    left: bool,
    layout: window_mod.ScrollbarLayout,
) ![]u8 {
    return render_scrollbar_row_region(wp, row, 0, sx, left, layout);
}

fn render_scrollbar_row_region(
    wp: *T.WindowPane,
    row: u32,
    start_col: u32,
    sx: u32,
    left: bool,
    layout: window_mod.ScrollbarLayout,
) ![]u8 {
    var renderer = RowRenderer{};
    errdefer renderer.deinit();
    try append_scrollbar_segment_range(&renderer, wp, row, start_col, sx, left, layout);
    return renderer.finish();
}

const RegionIntersection = struct {
    start_x: u32,
    start_y: u32,
    width: u32,
    height: u32,
};

fn intersect_region(
    rect_x: u32,
    rect_y: u32,
    rect_w: u32,
    rect_h: u32,
    view_x: u32,
    view_y: u32,
    view_w: u32,
    view_h: u32,
) ?RegionIntersection {
    const start_x = @max(rect_x, view_x);
    const start_y = @max(rect_y, view_y);
    const end_x = @min(rect_x + rect_w, view_x + view_w);
    const end_y = @min(rect_y + rect_h, view_y + view_h);
    if (start_x >= end_x or start_y >= end_y) return null;
    return .{
        .start_x = start_x,
        .start_y = start_y,
        .width = end_x - start_x,
        .height = end_y - start_y,
    };
}

fn overlap_width(start_col: u32, width: u32, seg_start: u32, seg_width: u32) u32 {
    const start = @max(start_col, seg_start);
    const end = @min(start_col + width, seg_start + seg_width);
    return if (start >= end) 0 else end - start;
}

fn style_of(cell: T.GridCell) CellStyle {
    return .{
        .attr = cell.attr,
        .fg = cell.fg,
        .bg = cell.bg,
        .link = cell.link,
    };
}

fn style_is_default(style: CellStyle) bool {
    return style.attr == 0 and
        (style.fg == 0 or style.fg == 8) and
        (style.bg == 0 or style.bg == 8);
}

fn style_to_sgr(style: CellStyle) ![]u8 {
    if (style_is_default(style)) return xm.xstrdup("\x1b[0m");

    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(xm.allocator);
    try buf.appendSlice(xm.allocator, "\x1b[0");

    if (style.attr & T.GRID_ATTR_BRIGHT != 0) try buf.appendSlice(xm.allocator, ";1");
    if (style.attr & T.GRID_ATTR_DIM != 0) try buf.appendSlice(xm.allocator, ";2");
    if (style.attr & T.GRID_ATTR_UNDERSCORE != 0) try buf.appendSlice(xm.allocator, ";4");
    if (style.attr & T.GRID_ATTR_BLINK != 0) try buf.appendSlice(xm.allocator, ";5");
    if (style.attr & T.GRID_ATTR_REVERSE != 0) try buf.appendSlice(xm.allocator, ";7");
    if (style.attr & T.GRID_ATTR_HIDDEN != 0) try buf.appendSlice(xm.allocator, ";8");
    if (style.attr & T.GRID_ATTR_ITALICS != 0) try buf.appendSlice(xm.allocator, ";3");
    if (style.attr & T.GRID_ATTR_STRIKETHROUGH != 0) try buf.appendSlice(xm.allocator, ";9");

    try append_colour(&buf, style.fg, 38);
    try append_colour(&buf, style.bg, 48);

    try buf.append(xm.allocator, 'm');
    return buf.toOwnedSlice(xm.allocator);
}

/// Emit a foreground (base=38) or background (base=48) colour into an SGR
/// sequence being assembled in `buf`.  Handles basic 8/16, 256-colour, and
/// 24-bit RGB.
fn append_colour(buf: *std.ArrayList(u8), colour: i32, base: u32) !void {
    if (colour == 0 or colour == 8) return;

    if (colour & T.COLOUR_FLAG_RGB != 0) {
        const r = (colour >> 16) & 0xff;
        const g = (colour >> 8) & 0xff;
        const b = colour & 0xff;
        const s = try std.fmt.allocPrint(xm.allocator, ";{d};2;{d};{d};{d}", .{ base, r, g, b });
        defer xm.allocator.free(s);
        try buf.appendSlice(xm.allocator, s);
        return;
    }

    if (colour & T.COLOUR_FLAG_256 != 0) {
        const idx = colour & 0xff;
        const s = try std.fmt.allocPrint(xm.allocator, ";{d};5;{d}", .{ base, idx });
        defer xm.allocator.free(s);
        try buf.appendSlice(xm.allocator, s);
        return;
    }

    // Basic 8 colours (0-7) → 30-37 / 40-47.
    if (colour < 8) {
        try append_code(buf, @as(i32, @intCast(base)) - 8 + colour);
        return;
    }
    // Aixterm bright colours (90-97 / 100-107).
    if (colour >= 90 and colour <= 97) {
        try append_code(buf, @as(i32, @intCast(base)) + 52 + colour - 90);
        return;
    }
}

fn append_code(buf: *std.ArrayList(u8), code: i32) !void {
    const text = try std.fmt.allocPrint(xm.allocator, ";{d}", .{code});
    defer xm.allocator.free(text);
    try buf.appendSlice(xm.allocator, text);
}

fn free_rows(cache: *T.ClientPaneCache) void {
    for (cache.rows.items) |row| xm.allocator.free(row);
    cache.rows.clearRetainingCapacity();
}

const BorderCell = struct {
    pane: *T.WindowPane,
    cell_type: usize,
};

fn borderCellAt(w: *T.Window, x: u32, y: u32) ?BorderCell {
    const hit = window_mod.window_hit_test(w, x, y) orelse return null;
    if (hit.region != .border) return null;
    return .{ .pane = hit.pane, .cell_type = borderCellType(w, x, y) };
}

fn isBorderCoord(w: *T.Window, x: u32, y: u32) bool {
    const hit = window_mod.window_hit_test(w, x, y) orelse return false;
    return hit.region == .border;
}

fn borderCellType(w: *T.Window, x: u32, y: u32) usize {
    var borders: u8 = 0;

    if (x == 0 or isBorderCoord(w, x - 1, y)) borders |= 8;
    if (x + 1 >= w.sx or isBorderCoord(w, x + 1, y)) borders |= 4;
    if (y == 0 or isBorderCoord(w, x, y - 1)) borders |= 2;
    if (y + 1 >= w.sy or isBorderCoord(w, x, y + 1)) borders |= 1;

    return switch (borders) {
        15 => tty_acs.CELL_JOIN,
        14 => tty_acs.CELL_BOTTOMJOIN,
        13 => tty_acs.CELL_TOPJOIN,
        12 => tty_acs.CELL_LEFTRIGHT,
        11 => tty_acs.CELL_RIGHTJOIN,
        10 => tty_acs.CELL_BOTTOMRIGHT,
        9 => tty_acs.CELL_TOPRIGHT,
        7 => tty_acs.CELL_LEFTJOIN,
        6 => tty_acs.CELL_BOTTOMLEFT,
        5 => tty_acs.CELL_TOPLEFT,
        3 => tty_acs.CELL_TOPBOTTOM,
        else => blk: {
            const vertical = (borders & 0b0011) != 0;
            const horizontal = (borders & 0b1100) != 0;
            break :blk if (vertical and !horizontal)
                tty_acs.CELL_TOPBOTTOM
            else if (horizontal and !vertical)
                tty_acs.CELL_LEFTRIGHT
            else
                tty_acs.CELL_OUTSIDE;
        },
    };
}

fn makeBorderCell(tty: ?*const T.Tty, pane: *T.WindowPane, cell_type: usize) T.GridCell {
    var gc = T.grid_default_cell;
    if (pane.window.active != null and pane.window.active.? == pane)
        style_mod.style_apply(&gc, pane.options, "pane-active-border-style", null)
    else
        style_mod.style_apply(&gc, pane.options, "pane-border-style", null);
    setBorderGlyph(tty, &gc, pane, cell_type);
    return gc;
}

fn setBorderGlyph(tty: ?*const T.Tty, gc: *T.GridCell, pane: *T.WindowPane, cell_type: usize) void {
    switch (@as(u32, @intCast(opts.options_get_number(pane.options, "pane-border-lines")))) {
        1 => gc.data = tty_acs.tty_acs_double_borders(cell_type).*,
        2 => gc.data = tty_acs.tty_acs_heavy_borders(cell_type).*,
        3 => utf8.utf8_set(&gc.data, simpleBorderByte(cell_type)),
        4 => {
            const idx = window_mod.window_pane_index(pane.window, pane) orelse 0;
            utf8.utf8_set(&gc.data, if (idx < 10) @as(u8, '0') + @as(u8, @intCast(idx)) else '*');
        },
        5 => utf8.utf8_set(&gc.data, ' '),
        else => setSingleBorderGlyph(tty, gc, cell_type),
    }
}

fn setSingleBorderGlyph(tty: ?*const T.Tty, gc: *T.GridCell, cell_type: usize) void {
    const key: u8 = switch (cell_type) {
        tty_acs.CELL_TOPBOTTOM => 'x',
        tty_acs.CELL_LEFTRIGHT => 'q',
        tty_acs.CELL_TOPLEFT => 'l',
        tty_acs.CELL_TOPRIGHT => 'k',
        tty_acs.CELL_BOTTOMLEFT => 'm',
        tty_acs.CELL_BOTTOMRIGHT => 'j',
        tty_acs.CELL_TOPJOIN => 'w',
        tty_acs.CELL_BOTTOMJOIN => 'v',
        tty_acs.CELL_LEFTJOIN => 't',
        tty_acs.CELL_RIGHTJOIN => 'u',
        tty_acs.CELL_JOIN => 'n',
        else => 0,
    };
    if (key == 0) {
        utf8.utf8_set(&gc.data, ' ');
        return;
    }
    const bytes = tty_acs.tty_acs_get(tty, key) orelse {
        utf8.utf8_set(&gc.data, simpleBorderByte(cell_type));
        return;
    };

    gc.data = std.mem.zeroes(T.Utf8Data);
    std.mem.copyForwards(u8, gc.data.data[0..bytes.len], bytes);
    gc.data.size = @intCast(bytes.len);
    gc.data.width = 1;
}

fn simpleBorderByte(cell_type: usize) u8 {
    return switch (cell_type) {
        tty_acs.CELL_TOPBOTTOM => '|',
        tty_acs.CELL_LEFTRIGHT => '-',
        tty_acs.CELL_TOPLEFT,
        tty_acs.CELL_TOPRIGHT,
        tty_acs.CELL_BOTTOMLEFT,
        tty_acs.CELL_BOTTOMRIGHT,
        tty_acs.CELL_TOPJOIN,
        tty_acs.CELL_BOTTOMJOIN,
        tty_acs.CELL_LEFTJOIN,
        tty_acs.CELL_RIGHTJOIN,
        tty_acs.CELL_JOIN,
        => '+',
        else => ' ',
    };
}

test "tty_draw_pane performs full redraw then row diff" {
    const win = @import("window.zig");
    const pane_io = @import("pane-io.zig");

    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    win.window_init_globals(xm.allocator);

    const w = win.window_create(4, 2, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    defer {
        while (w.panes.items.len > 0) {
            const pane = w.panes.items[w.panes.items.len - 1];
            win.window_remove_pane(w, pane);
        }
        w.panes.deinit(xm.allocator);
        w.last_panes.deinit(xm.allocator);
        opts.options_free(w.options);
        xm.allocator.free(w.name);
        _ = win.windows.remove(w.id);
        xm.allocator.destroy(w);
    }

    const wp = win.window_add_pane(w, null, 4, 2);
    pane_io.pane_io_feed(wp, "ab");

    var cache = T.ClientPaneCache{};
    defer tty_draw_free(&cache);

    const first = try tty_draw_pane(&cache, wp, 4, 2);
    defer xm.allocator.free(first);
    try std.testing.expect(std.mem.indexOf(u8, first, "\x1b[H\x1b[2J") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "\x1b[1;1H") != null);

    const second = try tty_draw_pane(&cache, wp, 4, 2);
    defer xm.allocator.free(second);
    try std.testing.expect(std.mem.indexOf(u8, second, "\x1b[H\x1b[2J") == null);

    pane_io.pane_io_feed(wp, "\nZ");
    const third = try tty_draw_pane(&cache, wp, 4, 2);
    defer xm.allocator.free(third);
    try std.testing.expect(std.mem.indexOf(u8, third, "\x1b[2;1H") != null);
    try std.testing.expect(std.mem.indexOf(u8, third, "Z") != null);
    try std.testing.expect(std.mem.indexOf(u8, third, "\x1b[1;1H") == null);
}

test "tty_draw_pane respects hidden cursor state" {
    const win = @import("window.zig");
    const pane_io = @import("pane-io.zig");

    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    win.window_init_globals(xm.allocator);

    const w = win.window_create(4, 2, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    defer {
        while (w.panes.items.len > 0) {
            const pane = w.panes.items[w.panes.items.len - 1];
            win.window_remove_pane(w, pane);
        }
        w.panes.deinit(xm.allocator);
        w.last_panes.deinit(xm.allocator);
        opts.options_free(w.options);
        xm.allocator.free(w.name);
        _ = win.windows.remove(w.id);
        xm.allocator.destroy(w);
    }

    const wp = win.window_add_pane(w, null, 4, 2);
    pane_io.pane_io_feed(wp, "ab");
    wp.base.cursor_visible = false;

    var cache = T.ClientPaneCache{};
    defer tty_draw_free(&cache);

    const draw = try tty_draw_pane(&cache, wp, 4, 2);
    defer xm.allocator.free(draw);
    try std.testing.expect(std.mem.indexOf(u8, draw, "\x1b[?25l") != null);
    try std.testing.expect(std.mem.indexOf(u8, draw, "\x1b[?25h") == null);
}

test "tty_draw_invalidate forces full redraw again" {
    const win = @import("window.zig");
    const pane_io = @import("pane-io.zig");

    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    win.window_init_globals(xm.allocator);

    const w = win.window_create(3, 1, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    defer {
        while (w.panes.items.len > 0) {
            const pane = w.panes.items[w.panes.items.len - 1];
            win.window_remove_pane(w, pane);
        }
        w.panes.deinit(xm.allocator);
        w.last_panes.deinit(xm.allocator);
        opts.options_free(w.options);
        xm.allocator.free(w.name);
        _ = win.windows.remove(w.id);
        xm.allocator.destroy(w);
    }

    const wp = win.window_add_pane(w, null, 3, 1);
    pane_io.pane_io_feed(wp, "abc");
    var cache = T.ClientPaneCache{};
    defer tty_draw_free(&cache);

    const first = try tty_draw_pane(&cache, wp, 3, 1);
    defer xm.allocator.free(first);
    tty_draw_invalidate(&cache);
    const second = try tty_draw_pane(&cache, wp, 3, 1);
    defer xm.allocator.free(second);
    try std.testing.expect(std.mem.indexOf(u8, second, "\x1b[H\x1b[2J") != null);
}

test "tty_draw_pane preserves stored utf8 glyph bytes" {
    const win = @import("window.zig");
    const pane_io = @import("pane-io.zig");

    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    win.window_init_globals(xm.allocator);

    const w = win.window_create(4, 1, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    defer {
        while (w.panes.items.len > 0) {
            const pane = w.panes.items[w.panes.items.len - 1];
            win.window_remove_pane(w, pane);
        }
        w.panes.deinit(xm.allocator);
        w.last_panes.deinit(xm.allocator);
        opts.options_free(w.options);
        xm.allocator.free(w.name);
        _ = win.windows.remove(w.id);
        xm.allocator.destroy(w);
    }

    const wp = win.window_add_pane(w, null, 4, 1);
    pane_io.pane_io_feed(wp, "🙂x");

    var cache = T.ClientPaneCache{};
    defer tty_draw_free(&cache);

    const draw = try tty_draw_pane(&cache, wp, 4, 1);
    defer xm.allocator.free(draw);
    try std.testing.expect(std.mem.indexOf(u8, draw, "🙂x") != null);
}

test "tty_draw_render_window_region clears clipped leading wide-cell padding" {
    const win = @import("window.zig");
    const screen_write = @import("screen-write.zig");

    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    win.window_init_globals(xm.allocator);

    const w = win.window_create(3, 1, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    defer {
        while (w.panes.items.len > 0) {
            const pane = w.panes.items[w.panes.items.len - 1];
            win.window_remove_pane(w, pane);
        }
        w.panes.deinit(xm.allocator);
        w.last_panes.deinit(xm.allocator);
        opts.options_free(w.options);
        xm.allocator.free(w.name);
        _ = win.windows.remove(w.id);
        xm.allocator.destroy(w);
    }

    const wp = win.window_add_pane(w, null, 3, 1);
    w.active = wp;

    var ctx = T.ScreenWriteCtx{ .wp = wp, .s = &wp.base };
    screen_write.putn(&ctx, "🙂x");

    const rendered = try tty_draw_render_window_region(w, 1, 0, 2, 1, 0);
    defer xm.allocator.free(rendered.payload);

    try std.testing.expect(std.mem.indexOf(u8, rendered.payload, "\x1b[1;1H\x1b[0m x") != null);
}

test "tty_draw_render_screen_region clears clipped trailing wide cells" {
    const screen = @import("screen.zig");
    const screen_write = @import("screen-write.zig");

    const s = screen.screen_init(3, 1, 0);
    defer {
        screen.screen_free(s);
        xm.allocator.destroy(s);
    }

    var ctx = T.ScreenWriteCtx{ .s = s };
    screen_write.putn(&ctx, "🙂x");

    const rendered = try tty_draw_render_screen_region(s, 0, 0, 1, 1, 0, 0);
    defer xm.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "\x1b[1;1H\x1b[0m \x1b[K") != null);
}

test "tty_draw_render_window paints multiple visible panes at shared offsets" {
    const win = @import("window.zig");
    const pane_io = @import("pane-io.zig");

    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    win.window_init_globals(xm.allocator);

    const w = win.window_create(6, 2, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    defer {
        while (w.panes.items.len > 0) {
            const pane = w.panes.items[w.panes.items.len - 1];
            win.window_remove_pane(w, pane);
        }
        w.panes.deinit(xm.allocator);
        w.last_panes.deinit(xm.allocator);
        opts.options_free(w.options);
        xm.allocator.free(w.name);
        _ = win.windows.remove(w.id);
        xm.allocator.destroy(w);
    }

    const left = win.window_add_pane(w, null, 3, 2);
    const right = win.window_add_pane(w, null, 3, 2);
    w.active = right;

    left.xoff = 0;
    left.yoff = 0;
    right.xoff = 3;
    right.yoff = 0;

    pane_io.pane_io_feed(left, "L1\r\nL2");
    pane_io.pane_io_feed(right, "R1\r\nR2");

    const rendered = try tty_draw_render_window(w, 6, 2, 0);
    defer xm.allocator.free(rendered.payload);

    try std.testing.expect(std.mem.indexOf(u8, rendered.payload, "\x1b[H\x1b[2J") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.payload, "\x1b[1;1H") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.payload, "\x1b[1;4H") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.payload, "\x1b[2;1H") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.payload, "\x1b[2;4H") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.payload, "L1") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.payload, "R1") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.payload, "L2") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.payload, "R2") != null);
    try std.testing.expect(rendered.cursor_visible);
    try std.testing.expectEqual(@as(u32, 5), rendered.cursor_x);
    try std.testing.expectEqual(@as(u32, 1), rendered.cursor_y);
}

test "tty_draw_pane renders attached right scrollbar columns from shared window geometry" {
    const win = @import("window.zig");
    const screen_write = @import("screen-write.zig");

    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    win.window_init_globals(xm.allocator);

    const w = win.window_create(4, 4, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    defer {
        while (w.panes.items.len > 0) {
            const pane = w.panes.items[w.panes.items.len - 1];
            win.window_remove_pane(w, pane);
        }
        w.panes.deinit(xm.allocator);
        w.last_panes.deinit(xm.allocator);
        opts.options_free(w.options);
        xm.allocator.free(w.name);
        _ = win.windows.remove(w.id);
        xm.allocator.destroy(w);
    }

    const wp = win.window_add_pane(w, null, 4, 4);
    w.active = wp;
    opts.options_set_number(wp.options, "pane-scrollbars", T.PANE_SCROLLBARS_ALWAYS);
    opts.options_set_string(wp.options, false, "pane-scrollbars-style", "fg=blue,pad=1");
    win.window_pane_options_changed(wp, "pane-scrollbars-style");
    wp.base.grid.hsize = 4;

    var ctx = T.ScreenWriteCtx{ .wp = wp, .s = &wp.base };
    screen_write.putn(&ctx, "abcd");

    var cache = T.ClientPaneCache{};
    defer tty_draw_free(&cache);

    const draw = try tty_draw_pane(&cache, wp, win.window_pane_total_width(wp), 4);
    defer xm.allocator.free(draw);

    try std.testing.expect(std.mem.indexOf(u8, draw, "abcd") != null);
    try std.testing.expect(std.mem.indexOf(u8, draw, "\x1b[0;34m ") != null);
}

test "tty_draw_invalidate clears pane identity and dimensions" {
    var cache = T.ClientPaneCache{};
    defer tty_draw_free(&cache);

    cache.pane_id = 7;
    cache.valid = true;
    cache.sx = 80;
    cache.sy = 24;
    tty_draw_invalidate(&cache);
    try std.testing.expect(cache.pane_id == null);
    try std.testing.expect(!cache.valid);
    try std.testing.expectEqual(@as(u32, 0), cache.sx);
    try std.testing.expectEqual(@as(u32, 0), cache.sy);
}
