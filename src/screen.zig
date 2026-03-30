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
const tty_acs_mod = @import("tty-acs.zig");

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
    if (s.sel) |sel| xm.allocator.destroy(sel);
    screen_free_titles(s);
    if (s.title) |title| xm.allocator.free(title);
    if (s.path) |path| xm.allocator.free(path);
    if (s.tabs) |tabs| xm.allocator.free(tabs);
    if (s.hyperlinks) |hl| hyperlinks.hyperlinks_free(hl);
    if (s.saved_grid) |saved| grid.grid_free(saved);
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
    screen_clear_selection(s);
    screen_free_titles(s);
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

// ── Selection ─────────────────────────────────────────────────────────────

/// Set selection on a screen (screen_set_selection).
pub fn screen_set_selection(s: *T.Screen, sx: u32, sy: u32, ex: u32, ey: u32, rectangle: bool, modekeys: u32, gc: *const T.GridCell) void {
    if (s.sel == null)
        s.sel = xm.allocator.create(T.ScreenSel) catch unreachable;
    s.sel.?.* = .{
        .hidden = false,
        .rectangle = rectangle,
        .modekeys = modekeys,
        .sx = sx,
        .sy = sy,
        .ex = ex,
        .ey = ey,
        .cell = gc.*,
    };
}

/// Clear selection (screen_clear_selection).
pub fn screen_clear_selection(s: *T.Screen) void {
    if (s.sel) |sel| {
        xm.allocator.destroy(sel);
        s.sel = null;
    }
}

/// Hide selection (screen_hide_selection).
pub fn screen_hide_selection(s: *T.Screen) void {
    if (s.sel) |sel| sel.hidden = true;
}

/// Check if a cell is in the selection (screen_check_selection).
/// Returns true if the cell at (px, py) is within the active selection.
pub fn screen_check_selection(s: *const T.Screen, px: u32, py: u32) bool {
    const sel = s.sel orelse return false;
    if (sel.hidden) return false;

    if (sel.rectangle) {
        // Rectangle selection: check row bounds.
        if (sel.sy < sel.ey) {
            if (py < sel.sy or py > sel.ey) return false;
        } else if (sel.sy > sel.ey) {
            if (py > sel.sy or py < sel.ey) return false;
        } else {
            if (py != sel.sy) return false;
        }
        // Check column bounds.
        if (sel.ex < sel.sx) {
            if (px < sel.ex or px > sel.sx) return false;
        } else {
            if (px < sel.sx or px > sel.ex) return false;
        }
    } else {
        // Non-rectangle selection.
        if (sel.sy < sel.ey) {
            if (py < sel.sy or py > sel.ey) return false;
            if (py == sel.sy and px < sel.sx) return false;
            const xx = if (sel.modekeys == T.MODEKEY_EMACS)
                (if (sel.ex == 0) @as(u32, 0) else sel.ex - 1)
            else
                sel.ex;
            if (py == sel.ey and px > xx) return false;
        } else if (sel.sy > sel.ey) {
            if (py > sel.sy or py < sel.ey) return false;
            if (py == sel.ey and px < sel.ex) return false;
            const xx = if (sel.modekeys == T.MODEKEY_EMACS) sel.sx -| 1 else sel.sx;
            if (py == sel.sy and (sel.sx == 0 or px > xx)) return false;
        } else {
            if (py != sel.sy) return false;
            if (sel.ex < sel.sx) {
                const xx = if (sel.modekeys == T.MODEKEY_EMACS) sel.sx -| 1 else sel.sx;
                if (px > xx or px < sel.ex) return false;
            } else {
                const xx = if (sel.modekeys == T.MODEKEY_EMACS)
                    (if (sel.ex == 0) @as(u32, 0) else sel.ex - 1)
                else
                    sel.ex;
                if (px < sel.sx or px > xx) return false;
            }
        }
    }
    return true;
}

/// Get the selection cell style, merging with the source cell (screen_select_cell).
/// Returns true if a selection exists and dst was populated.
pub fn screen_select_cell(s: *const T.Screen, dst: *T.GridCell, src: *const T.GridCell) bool {
    const sel = s.sel orelse return false;
    if (sel.hidden) return false;

    dst.* = sel.cell;
    if (T.colour_is_default(dst.fg)) dst.fg = src.fg;
    if (T.colour_is_default(dst.bg)) dst.bg = src.bg;
    dst.data = src.data;
    dst.flags = src.flags;

    if (dst.attr & T.GRID_ATTR_NOATTR != 0)
        dst.attr |= (src.attr & T.GRID_ATTR_CHARSET)
    else
        dst.attr |= src.attr;
    return true;
}

// ── Cursor Style ──────────────────────────────────────────────────────────

/// Set screen cursor style and mode from a numeric style code (screen_set_cursor_style).
pub fn screen_set_cursor_style(style: u32, cstyle: *T.ScreenCursorStyle, mode: *i32) void {
    switch (style) {
        0 => cstyle.* = .default,
        1 => {
            cstyle.* = .block;
            mode.* |= T.MODE_CURSOR_BLINKING;
        },
        2 => {
            cstyle.* = .block;
            mode.* &= ~T.MODE_CURSOR_BLINKING;
        },
        3 => {
            cstyle.* = .underline;
            mode.* |= T.MODE_CURSOR_BLINKING;
        },
        4 => {
            cstyle.* = .underline;
            mode.* &= ~T.MODE_CURSOR_BLINKING;
        },
        5 => {
            cstyle.* = .bar;
            mode.* |= T.MODE_CURSOR_BLINKING;
        },
        6 => {
            cstyle.* = .bar;
            mode.* &= ~T.MODE_CURSOR_BLINKING;
        },
        else => {},
    }
}

/// Set screen cursor colour (screen_set_cursor_colour).
pub fn screen_set_cursor_colour(s: *T.Screen, colour: i32) void {
    s.ccolour = colour;
}

/// Set default cursor style and colour from options (screen_set_default_cursor).
pub fn screen_set_default_cursor(s: *T.Screen, oo: *T.Options) void {
    const opts = @import("options.zig");
    const colour = opts.options_get_number(oo, "cursor-colour");
    s.default_ccolour = @intCast(colour);
    const style: u32 = @intCast(opts.options_get_number(oo, "cursor-style"));
    s.default_mode = 0;
    screen_set_cursor_style(style, &s.default_cstyle, &s.default_mode);
}

// ── Title Stack ───────────────────────────────────────────────────────────

/// Push the current title onto the stack (screen_push_title).
pub fn screen_push_title(s: *T.Screen) void {
    const text = if (s.title) |t| xm.xstrdup(t) else xm.xstrdup("");
    s.titles.insert(xm.allocator, 0, .{ .text = text }) catch unreachable;
}

/// Pop a title from the stack and set it (screen_pop_title).
pub fn screen_pop_title(s: *T.Screen) void {
    if (s.titles.items.len == 0) return;
    const entry = s.titles.orderedRemove(0);
    _ = screen_set_title(s, entry.text);
    xm.allocator.free(entry.text);
}

/// Free the title stack (screen_free_titles).
pub fn screen_free_titles(s: *T.Screen) void {
    for (s.titles.items) |entry| {
        xm.allocator.free(entry.text);
    }
    s.titles.clearAndFree(xm.allocator);
}

// ── Reinit ────────────────────────────────────────────────────────────────

/// Reinitialise a screen to default state (screen_reinit).
pub fn screen_reinit(s: *T.Screen) void {
    s.cx = 0;
    s.cy = 0;
    s.rupper = 0;
    s.rlower = if (s.grid.sy == 0) 0 else s.grid.sy - 1;
    s.mode = T.MODE_CURSOR | T.MODE_WRAP | (s.mode & T.MODE_CRLF);

    const opts = @import("options.zig");
    if (opts.options_get_number(opts.global_options, "extended-keys") == 2)
        s.mode = (s.mode & ~T.EXTENDED_KEY_MODES) | T.MODE_KEYS_EXTENDED;

    s.saved_cx = std.math.maxInt(u32);
    s.saved_cy = std.math.maxInt(u32);

    screen_reset_tabs(s);
    screen_clear_selection(s);
    screen_free_titles(s);
    screen_reset_hyperlinks(s);
}

// ── Resize ────────────────────────────────────────────────────────────────

/// Resize screen with cursor tracking and reflow (screen_resize_cursor).
pub fn screen_resize_cursor(s: *T.Screen, sx_in: u32, sy_in: u32, reflow_flag: bool, eat_empty: bool, cursor: bool) void {
    const sx = if (sx_in < 1) @as(u32, 1) else sx_in;
    const sy = if (sy_in < 1) @as(u32, 1) else sy_in;

    var cx: u32 = s.cx;
    var cy: u32 = s.grid.hsize + s.cy;

    var do_reflow = reflow_flag;
    if (sx != s.grid.sx) {
        s.grid.sx = sx;
        screen_reset_tabs(s);
    } else {
        do_reflow = false;
    }

    if (sy != s.grid.sy)
        screen_resize_y(s, sy, eat_empty, &cy);

    if (do_reflow)
        screen_reflow(s, sx, &cx, &cy, cursor);

    if (cy >= s.grid.hsize) {
        s.cx = cx;
        s.cy = cy - s.grid.hsize;
    } else {
        s.cx = 0;
        s.cy = 0;
    }
}

/// Y-axis resize with history management (screen_resize_y).
fn screen_resize_y(s: *T.Screen, sy: u32, eat_empty: bool, cy: *u32) void {
    const gd = s.grid;
    const oldy = gd.sy;

    // Size decreasing.
    if (sy < oldy) {
        var needed: u32 = oldy - sy;

        // Delete empty lines from the bottom.
        if (eat_empty) {
            var available: u32 = oldy - 1 - s.cy;
            if (available > needed) available = needed;
            if (available > 0)
                grid.delete_lines(gd, oldy - available, oldy - 1, available);
            needed -= available;
        }

        // Push remaining lines into history or delete from top.
        if (gd.flags & T.GRID_HISTORY != 0) {
            gd.hscrolled += needed;
            gd.hsize += needed;
        } else if (needed > 0 and s.cy > 0) {
            var available: u32 = s.cy;
            if (available > needed) available = needed;
            grid.delete_lines(gd, 0, oldy - 1, available);
            cy.* -= available;
        }
    }

    // Resize line array.
    grid.resize_linedata_pub(gd, gd.hsize + sy);

    // Size increasing.
    if (sy > oldy) {
        var needed: u32 = sy - oldy;

        // Pull from scrolled history.
        if (gd.flags & T.GRID_HISTORY != 0 and gd.hscrolled > 0) {
            var available: u32 = gd.hscrolled;
            if (available > needed) available = needed;
            gd.hscrolled -= available;
            gd.hsize -= available;
            needed -= available;
        }

        // Fill remaining with blanks.
        var i: u32 = gd.hsize + sy - needed;
        while (i < gd.hsize + sy) : (i += 1) {
            grid.clear_line(&gd.linedata.ptr[@intCast(i)]);
        }
    }

    gd.sy = sy;
    s.rupper = 0;
    s.rlower = if (sy == 0) 0 else sy - 1;
}

/// Line reflow after width change (screen_reflow).
fn screen_reflow(s: *T.Screen, new_x: u32, cx: *u32, cy: *u32, cursor: bool) void {
    var wx: u32 = undefined;
    var wy: u32 = undefined;

    if (cursor) {
        grid.grid_wrap_position(s.grid, cx.*, cy.*, &wx, &wy);
    }

    grid.grid_reflow(s.grid, new_x);

    if (cursor) {
        grid.grid_unwrap_position(s.grid, cx, cy, wx, wy);
    } else {
        cx.* = 0;
        cy.* = s.grid.hsize;
    }
}

// ── Alternate Screen (tmux-style) ─────────────────────────────────────────

/// Enter alternate screen mode with grid swap (screen_alternate_on).
pub fn screen_alternate_on(s: *T.Screen, gc: *const T.GridCell, cursor: bool) void {
    if (s.saved_grid != null) return; // already alternate

    const sx = s.grid.sx;
    const sy = s.grid.sy;

    // Save visible screen content.
    const saved = grid.grid_create(sx, sy, 0);
    grid.duplicate_lines(saved, 0, s.grid, s.grid.hsize, sy);
    s.saved_grid = saved;

    if (cursor) {
        s.saved_cx = s.cx;
        s.saved_cy = s.cy;
    }
    s.saved_cell = gc.*;

    // Clear visible area.
    grid.clear_area(s.grid, s.grid.hsize, 0, sx, sy);

    s.saved_flags = s.grid.flags;
    s.grid.flags &= ~T.GRID_HISTORY;
}

/// Exit alternate screen mode and restore saved grid (screen_alternate_off).
pub fn screen_alternate_off(s: *T.Screen, gc: ?*T.GridCell, cursor: bool) void {
    const sx = s.grid.sx;
    const sy = s.grid.sy;

    // Resize to saved grid size if different.
    if (s.saved_grid) |saved| {
        if (saved.sx != sx or saved.sy != sy)
            screen_resize_cursor(s, saved.sx, saved.sy, false, true, true);
    }

    // Restore cursor.
    if (cursor and s.saved_cx != std.math.maxInt(u32) and s.saved_cy != std.math.maxInt(u32)) {
        s.cx = s.saved_cx;
        s.cy = s.saved_cy;
        if (gc) |g| g.* = s.saved_cell;
    }

    // Restore saved grid.
    if (s.saved_grid) |saved| {
        grid.duplicate_lines(s.grid, s.grid.hsize, saved, 0, saved.sy);

        if (s.saved_flags & T.GRID_HISTORY != 0)
            s.grid.flags |= T.GRID_HISTORY;
        screen_resize_cursor(s, sx, sy, true, true, true);

        grid.grid_free(saved);
        s.saved_grid = null;
    }

    if (s.grid.sx > 0 and s.cx >= s.grid.sx) s.cx = s.grid.sx - 1;
    if (s.grid.sy > 0 and s.cy >= s.grid.sy) s.cy = s.grid.sy - 1;
}

// ── Diagnostic dump ─────────────────────────────────────────────────────

var screen_print_buf: [16384]u8 = undefined;

/// Render screen contents to a static buffer for debugging (tmux `screen_print`).
/// The returned slice is NUL-terminated and valid until the next call.
pub fn screen_print(s: *T.Screen) [:0]const u8 {
    var last: usize = 0;
    const h = s.grid.hsize;
    const sy = s.grid.sy;
    var y: u32 = 0;
    outer: while (y < h + sy) : (y += 1) {
        if (y >= s.grid.linedata.len) break;
        const hdr = std.fmt.bufPrint(screen_print_buf[last..], "{d:0>4} \"", .{y}) catch break :outer;
        if (last + hdr.len >= screen_print_buf.len) break;
        last += hdr.len;

        const gl = &s.grid.linedata[y];
        var x: u32 = 0;
        while (x < gl.cellused) : (x += 1) {
            if (x >= gl.celldata.len) break;
            const gce = gl.celldata[x];
            if ((gce.flags & T.GRID_FLAG_PADDING) != 0) continue;

            if ((gce.flags & T.GRID_FLAG_EXTENDED) == 0) {
                if (last + 2 > screen_print_buf.len) break :outer;
                screen_print_buf[last] = gce.offset_or_data.data.data;
                last += 1;
            } else if ((gce.flags & T.GRID_FLAG_TAB) != 0) {
                if (last + 2 > screen_print_buf.len) break :outer;
                screen_print_buf[last] = '\t';
                last += 1;
            } else if ((gce.flags & @as(u8, @truncate(T.GRID_ATTR_CHARSET))) != 0) {
                const ch = gce.offset_or_data.data.data;
                var one: [1]u8 = .{ch};
                const acs = tty_acs_mod.tty_acs_get(null, ch) orelse one[0..1];
                if (last + acs.len + 1 > screen_print_buf.len) break :outer;
                @memcpy(screen_print_buf[last..][0..acs.len], acs);
                last += acs.len;
            } else {
                const off = gce.offset_or_data.offset;
                if (off >= gl.extddata.len) continue;
                var ud: T.Utf8Data = undefined;
                utf8.utf8_to_data(gl.extddata[off].data, &ud);
                if (ud.size > 0) {
                    if (last + ud.size + 1 > screen_print_buf.len) break :outer;
                    @memcpy(screen_print_buf[last..][0..ud.size], ud.data[0..ud.size]);
                    last += ud.size;
                }
            }
        }

        if (last + 3 > screen_print_buf.len) break;
        screen_print_buf[last] = '"';
        last += 1;
        screen_print_buf[last] = '\n';
        last += 1;
    }

    if (last >= screen_print_buf.len) last = screen_print_buf.len - 1;
    screen_print_buf[last] = 0;
    return screen_print_buf[0..last :0];
}

// ── Mode String ───────────────────────────────────────────────────────────

/// Convert mode flags to a comma-separated string (screen_mode_to_string).
pub fn screen_mode_to_string(mode: i32) []const u8 {
    if (mode == 0) return "NONE";

    const S = struct {
        var buf: [1024]u8 = undefined;
    };
    var len: usize = 0;

    const pairs = [_]struct { flag: i32, name: []const u8 }{
        .{ .flag = T.MODE_CURSOR, .name = "CURSOR" },
        .{ .flag = T.MODE_INSERT, .name = "INSERT" },
        .{ .flag = T.MODE_KCURSOR, .name = "KCURSOR" },
        .{ .flag = T.MODE_KKEYPAD, .name = "KKEYPAD" },
        .{ .flag = T.MODE_WRAP, .name = "WRAP" },
        .{ .flag = T.MODE_MOUSE_STANDARD, .name = "MOUSE_STANDARD" },
        .{ .flag = T.MODE_MOUSE_BUTTON, .name = "MOUSE_BUTTON" },
        .{ .flag = T.MODE_CURSOR_BLINKING, .name = "CURSOR_BLINKING" },
        .{ .flag = T.MODE_CURSOR_VERY_VISIBLE, .name = "CURSOR_VERY_VISIBLE" },
        .{ .flag = T.MODE_MOUSE_SGR, .name = "MOUSE_SGR" },
        .{ .flag = T.MODE_BRACKETPASTE, .name = "BRACKETPASTE" },
        .{ .flag = T.MODE_FOCUSON, .name = "FOCUSON" },
        .{ .flag = T.MODE_MOUSE_ALL, .name = "MOUSE_ALL" },
        .{ .flag = T.MODE_ORIGIN, .name = "ORIGIN" },
        .{ .flag = T.MODE_CRLF, .name = "CRLF" },
        .{ .flag = T.MODE_KEYS_EXTENDED, .name = "KEYS_EXTENDED" },
        .{ .flag = T.MODE_KEYS_EXTENDED_2, .name = "KEYS_EXTENDED_2" },
    };

    for (pairs) |p| {
        if (mode & p.flag != 0) {
            if (len > 0 and len < S.buf.len) {
                S.buf[len] = ',';
                len += 1;
            }
            const remain = S.buf.len - len;
            const to_copy = @min(p.name.len, remain);
            @memcpy(S.buf[len..][0..to_copy], p.name[0..to_copy]);
            len += to_copy;
        }
    }

    if (len == 0) return "NONE";
    return S.buf[0..len];
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
