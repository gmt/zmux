// Copyright (c) 2024 Greg Turner <gmt@be-evil.net>
//
// Permission to use, copy, modify, and distribute this software for any
// purpose with or without fee is hereby granted, provided that the above
// copyright notice and this permission notice appear in all copies.
//
// THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
// WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
// MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
// ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
// WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
// ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
// OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

//! screen-redraw.zig – full-screen redraw orchestration.
//!
//! Ported from tmux/screen-redraw.c (Nicholas Marriott, ISC licence).
//! Handles pane border drawing (6 styles), border colour/indicators,
//! scrollbar rendering, fill characters, and full-screen redraw orchestration
//! via screen_redraw_screen and screen_redraw_pane.

const std = @import("std");
const T = @import("types.zig");
const opts = @import("options.zig");
const tty_acs = @import("tty-acs.zig");
const utf8 = @import("utf8.zig");
const style_mod = @import("style.zig");
const win_mod = @import("window.zig");
const tty_mod = @import("tty.zig");
const tty_draw = @import("tty-draw.zig");
const resize_mod = @import("resize.zig");
const log = @import("log.zig");
const server_client_mod = @import("server-client.zig");

// ── Unicode isolate markers for bidi handling ────────────────────────────────
const START_ISOLATE = "\xe2\x81\xa6";
const END_ISOLATE = "\xe2\x81\xa9";

// ── Border position markers (BORDER_MARKERS "  +,.-") ────────────────────────
const BORDER_MARKERS = "  +,.-";

// ── Border type in relation to a pane ────────────────────────────────────────

pub const ScreenRedrawBorderType = enum(u8) {
    outside = 0,
    inside,
    border_left,
    border_right,
    border_top,
    border_bottom,
};

// ── Redraw context ────────────────────────────────────────────────────────────

/// Equivalent to tmux's struct screen_redraw_ctx.
pub const ScreenRedrawCtx = struct {
    c: *T.Client,

    // Status line configuration
    statustop: bool = false,
    statuslines: u32 = 0,

    // Pane border configuration
    pane_status: u32 = T.PANE_STATUS_OFF,
    pane_lines: u32 = 0,

    // Scrollbar configuration
    pane_scrollbars: u32 = 0,
    pane_scrollbars_pos: u32 = T.PANE_SCROLLBARS_RIGHT,

    // Viewport offsets and dimensions (from tty_window_offset)
    ox: u32 = 0,
    oy: u32 = 0,
    sx: u32 = 0,
    sy: u32 = 0,

    // Cached "no pane" border gc (for areas not belonging to any pane)
    no_pane_gc: T.GridCell = T.grid_default_cell,
    no_pane_gc_set: bool = false,
};

// ── Context initialisation ────────────────────────────────────────────────────

/// Initialise a redraw context from a client, mirroring
/// screen_redraw_set_context in screen-redraw.c.
pub fn screen_redraw_set_context(c: *T.Client, ctx: *ScreenRedrawCtx) void {
    const s = c.session orelse return;
    const wl = s.curw orelse return;
    const wo = wl.window.options;
    const oo = s.options;

    ctx.* = ScreenRedrawCtx{ .c = c };

    // Status line position
    var lines = resize_mod.status_line_size(c);
    if (c.message_string != null) {
        if (lines == 0) lines = 1;
    }
    // TODO: c.prompt_string is not yet a field on Client; add when status-prompt is ported
    if (lines != 0 and opts.options_get_number(oo, "status-position") == 0)
        ctx.statustop = true;
    ctx.statuslines = lines;

    ctx.pane_status = @intCast(@max(opts.options_get_number(wo, "pane-border-status"), 0));
    ctx.pane_lines = @intCast(@max(opts.options_get_number(wo, "pane-border-lines"), 0));

    ctx.pane_scrollbars = @intCast(@max(opts.options_get_number(wo, "pane-scrollbars"), 0));
    ctx.pane_scrollbars_pos = @intCast(@max(opts.options_get_number(wo, "pane-scrollbars-position"), 0));

    _ = tty_mod.tty_window_offset(&c.tty, &ctx.ox, &ctx.oy, &ctx.sx, &ctx.sy);

    log.log_debug(
        "screen_redraw_set_context: @{d} ox={d} oy={d} sx={d} sy={d} {d}/{s}",
        .{
            wl.window.id,
            ctx.ox, ctx.oy, ctx.sx, ctx.sy,
            ctx.statuslines,
            if (ctx.statustop) "top" else "bottom",
        },
    );
}

// ── Utility: two-pane detection ───────────────────────────────────────────────

/// Return true when the window has exactly two panes split in `direction`.
/// direction 0 = horizontal (left/right), 1 = vertical (top/bottom).
fn screen_redraw_two_panes(w: *T.Window, direction: u8) bool {
    if (w.panes.items.len != 2) return false;
    const wp = w.panes.items[1];
    if (direction == 0 and wp.xoff == 0) return false;
    if (direction == 1 and wp.yoff == 0) return false;
    return true;
}

// ── Border position relative to a pane ───────────────────────────────────────

/// Determine where (px, py) lies relative to pane `wp`.
/// This is the key function that accounts for scrollbar width and pane-status.
pub fn screen_redraw_pane_border(
    ctx: *const ScreenRedrawCtx,
    wp: *T.WindowPane,
    px: u32,
    py: u32,
) ScreenRedrawBorderType {
    const ex = wp.xoff + wp.sx;
    const ey = wp.yoff + wp.sy;
    const pane_status = ctx.pane_status;
    const pane_scrollbars = ctx.pane_scrollbars;
    const sb_pos = if (pane_scrollbars != 0) ctx.pane_scrollbars_pos else 0;

    // Inside the pane content area
    if (px >= wp.xoff and px < ex and py >= wp.yoff and py < ey)
        return .inside;

    // Determine indicator mode for the two-pane colouring split
    var hsplit = false;
    var vsplit = false;
    const ind_value = opts.options_get_number(wp.window.options, "pane-border-indicators");
    if (ind_value == 2 or ind_value == 3) { // PANE_BORDER_COLOUR=2, PANE_BORDER_BOTH=3
        hsplit = screen_redraw_two_panes(wp.window, 0);
        vsplit = screen_redraw_two_panes(wp.window, 1);
    }

    // Scrollbar width contribution
    var sb_w: u32 = 0;
    if (win_mod.window_pane_show_scrollbar(wp)) {
        const sw = wp.scrollbar_style.width;
        const sp = wp.scrollbar_style.pad;
        if (sw > 0 and sp >= 0)
            sb_w = @intCast(sw + sp)
        else if (sw > 0)
            sb_w = @intCast(sw);
    }

    // Left/right border detection
    if ((wp.yoff == 0 or py >= wp.yoff - 1) and py <= ey) {
        if (sb_pos == T.PANE_SCROLLBARS_LEFT) {
            const left_xoff = if (wp.xoff >= sb_w) wp.xoff - sb_w else 0;
            if (left_xoff == 0 and px == wp.sx + sb_w) {
                if (!hsplit or py <= wp.sy / 2)
                    return .border_right;
            }
            if (left_xoff != 0) {
                if (px == left_xoff - 1 and (!hsplit or py > wp.sy / 2))
                    return .border_left;
                if (px == wp.xoff + wp.sx + sb_w - 1)
                    return .border_right;
            }
        } else {
            // PANE_SCROLLBARS_RIGHT or disabled
            if (wp.xoff == 0 and px == wp.sx + sb_w) {
                if (!hsplit or py <= wp.sy / 2)
                    return .border_right;
            }
            if (wp.xoff != 0) {
                if (px == wp.xoff - 1 and (!hsplit or py > wp.sy / 2))
                    return .border_left;
                if (px == wp.xoff + wp.sx + sb_w)
                    return .border_right;
            }
        }
    }

    // Top/bottom border detection
    if (vsplit and pane_status == T.PANE_STATUS_OFF and sb_w == 0) {
        if (wp.yoff == 0 and py == wp.sy and px <= wp.sx / 2)
            return .border_bottom;
        if (wp.yoff != 0 and py == wp.yoff - 1 and px > wp.sx / 2)
            return .border_top;
    } else {
        if (sb_pos == T.PANE_SCROLLBARS_LEFT) {
            const left_xoff = if (wp.xoff >= sb_w) wp.xoff - sb_w else 0;
            if ((left_xoff == 0 or px >= left_xoff) and
                (px <= ex or (sb_w != 0 and px < ex + sb_w)))
            {
                if (wp.yoff != 0 and py == wp.yoff - 1)
                    return .border_top;
                if (py == ey)
                    return .border_bottom;
            }
        } else {
            if ((wp.xoff == 0 or px >= wp.xoff) and
                (px <= ex or (sb_w != 0 and px < ex + sb_w)))
            {
                if (pane_status != T.PANE_STATUS_BOTTOM and
                    wp.yoff != 0 and
                    py == wp.yoff - 1)
                    return .border_top;
                if (pane_status != T.PANE_STATUS_TOP and py == ey)
                    return .border_bottom;
            }
        }
    }

    return .outside;
}

// ── Border cell detection ─────────────────────────────────────────────────────

/// Return true when (px, py) lies on any border in the window.
fn screen_redraw_cell_border(ctx: *const ScreenRedrawCtx, px: u32, py: u32) bool {
    const c = ctx.c;
    const s = c.session orelse return false;
    const wl = s.curw orelse return false;
    const w = wl.window;
    var sy = w.sy;

    if (ctx.pane_status == T.PANE_STATUS_BOTTOM and sy > 0)
        sy -= 1;

    // Outside the window
    if (px > w.sx or py > sy) return false;
    // On the window border
    if (px == w.sx or py == sy) return true;

    for (w.panes.items) |wp| {
        if (!win_mod.window_pane_visible(wp)) continue;
        switch (screen_redraw_pane_border(ctx, wp, px, py)) {
            .inside => return false,
            .outside => {},
            else => return true,
        }
    }

    return false;
}

// ── Cell type from surrounding border cells ───────────────────────────────────

/// Determine the CELL_* type for a border cell at (px, py).
pub fn screen_redraw_type_of_cell(ctx: *const ScreenRedrawCtx, px: u32, py: u32) usize {
    const c = ctx.c;
    const s = c.session orelse return tty_acs.CELL_OUTSIDE;
    const wl = s.curw orelse return tty_acs.CELL_OUTSIDE;
    const w = wl.window;
    const sx = w.sx;
    var sy = w.sy;
    const pane_status = ctx.pane_status;

    if (pane_status == T.PANE_STATUS_BOTTOM and sy > 0)
        sy -= 1;

    if (px > sx or py > sy) return tty_acs.CELL_OUTSIDE;

    // Build bitmask: bit 8=left, 4=right, 2=top, 1=bottom
    var borders: u8 = 0;
    if (px == 0 or screen_redraw_cell_border(ctx, px - 1, py)) borders |= 8;
    if (px <= sx and screen_redraw_cell_border(ctx, px + 1, py)) borders |= 4;

    if (pane_status == T.PANE_STATUS_TOP) {
        if (py != 0 and screen_redraw_cell_border(ctx, px, py - 1)) borders |= 2;
        if (screen_redraw_cell_border(ctx, px, py + 1)) borders |= 1;
    } else if (pane_status == T.PANE_STATUS_BOTTOM) {
        if (py == 0 or screen_redraw_cell_border(ctx, px, py - 1)) borders |= 2;
        if (py != sy and screen_redraw_cell_border(ctx, px, py + 1)) borders |= 1;
    } else {
        if (py == 0 or screen_redraw_cell_border(ctx, px, py - 1)) borders |= 2;
        if (screen_redraw_cell_border(ctx, px, py + 1)) borders |= 1;
    }

    return switch (borders) {
        15 => tty_acs.CELL_JOIN,
        14 => tty_acs.CELL_BOTTOMJOIN,
        13 => tty_acs.CELL_TOPJOIN,
        12 => tty_acs.CELL_LEFTRIGHT,
        11 => tty_acs.CELL_RIGHTJOIN,
        10 => tty_acs.CELL_BOTTOMRIGHT,
        9  => tty_acs.CELL_TOPRIGHT,
        7  => tty_acs.CELL_LEFTJOIN,
        6  => tty_acs.CELL_BOTTOMLEFT,
        5  => tty_acs.CELL_TOPLEFT,
        3  => tty_acs.CELL_TOPBOTTOM,
        else => tty_acs.CELL_OUTSIDE,
    };
}

// ── Cell-inside check ─────────────────────────────────────────────────────────

pub const CellCheckResult = union(enum) {
    inside,
    outside,
    scrollbar,
    border: usize, // cell type value
};

/// Determine whether (px, py) is inside a pane, on a border, or in a scrollbar.
/// Sets `wpp` to the matching pane (or null for border with no pane).
pub fn screen_redraw_check_cell(
    ctx: *const ScreenRedrawCtx,
    px: u32,
    py: u32,
    wpp: *?*T.WindowPane,
) CellCheckResult {
    const c = ctx.c;
    const s = c.session orelse {
        wpp.* = null;
        return .outside;
    };
    const wl = s.curw orelse {
        wpp.* = null;
        return .outside;
    };
    const w = wl.window;
    const sx = w.sx;
    const sy = w.sy;
    const sb_pos = ctx.pane_scrollbars_pos;

    wpp.* = null;

    if (px > sx or py > sy) return .outside;
    if (px == sx or py == sy) {
        const ct = screen_redraw_type_of_cell(ctx, px, py);
        return .{ .border = ct };
    }

    // Pane-status area check
    if (ctx.pane_status != T.PANE_STATUS_OFF) {
        // TODO: when pane status bar is ported (status_screen/status_size on WindowPane),
        // check if (px, py) falls in a pane's status row and return .inside if so.
    }

    // Scrollbar + border check for each pane
    for (w.panes.items) |wp| {
        if (!win_mod.window_pane_visible(wp)) continue;
        wpp.* = wp;

        // Scrollbar region check
        if (win_mod.window_pane_show_scrollbar(wp)) {
            const sw = wp.scrollbar_style.width;
            const sp = if (wp.scrollbar_style.pad >= 0) wp.scrollbar_style.pad else 0;
            const sb_w: u32 = if (sw > 0) @as(u32, @intCast(sw + sp)) else 0;

            if (sb_w > 0 and
                ((wp.yoff == 0 and py < wp.sy) or
                 (py >= wp.yoff and py < wp.yoff + wp.sy)))
            {
                if (sb_pos == T.PANE_SCROLLBARS_RIGHT) {
                    if (px >= wp.xoff + wp.sx and px < wp.xoff + wp.sx + sb_w)
                        return .scrollbar;
                } else {
                    if (wp.xoff >= sb_w and
                        px >= wp.xoff - sb_w and px < wp.xoff)
                        return .scrollbar;
                }
            }
        }

        const border = screen_redraw_pane_border(ctx, wp, px, py);
        if (border == .inside) return .inside;
        if (border == .outside) continue;
        const ct = screen_redraw_type_of_cell(ctx, px, py);
        return .{ .border = ct };
    }

    return .outside;
}

// ── Is-border check for a specific pane ──────────────────────────────────────

/// Return true if (px, py) is on the border of pane `wp`.
pub fn screen_redraw_check_is(
    ctx: *const ScreenRedrawCtx,
    px: u32,
    py: u32,
    wp: *T.WindowPane,
) bool {
    const border = screen_redraw_pane_border(ctx, wp, px, py);
    return border != .inside and border != .outside;
}

// ── Border glyph selection ────────────────────────────────────────────────────

/// Map a CELL_* constant to the ACS key character used for default borders.
fn default_border_acs_key(cell_type: usize) u8 {
    return switch (cell_type) {
        tty_acs.CELL_TOPBOTTOM  => 'x',
        tty_acs.CELL_LEFTRIGHT  => 'q',
        tty_acs.CELL_TOPLEFT    => 'l',
        tty_acs.CELL_TOPRIGHT   => 'k',
        tty_acs.CELL_BOTTOMLEFT => 'm',
        tty_acs.CELL_BOTTOMRIGHT=> 'j',
        tty_acs.CELL_TOPJOIN    => 'w',
        tty_acs.CELL_BOTTOMJOIN => 'v',
        tty_acs.CELL_LEFTJOIN   => 't',
        tty_acs.CELL_RIGHTJOIN  => 'u',
        tty_acs.CELL_JOIN       => 'n',
        else                    => 0,
    };
}

/// Set the character in gc for the given border cell type and style.
/// Equivalent to screen_redraw_border_set in screen-redraw.c.
pub fn screen_redraw_border_set(
    w: *T.Window,
    wp: ?*T.WindowPane,
    pane_lines: u32,
    cell_type: usize,
    gc: *T.GridCell,
) void {
    // Fill character for CELL_OUTSIDE
    if (cell_type == tty_acs.CELL_OUTSIDE) {
        if (w.fill_character) |fc| {
            gc.data = fc[0];
            return;
        }
    }

    switch (pane_lines) {
        // PANE_LINES_NUMBER = 4 in tmux options table
        4 => {
            if (cell_type == tty_acs.CELL_OUTSIDE) {
                gc.attr |= T.GRID_ATTR_CHARSET;
                utf8.utf8_set(&gc.data, default_border_acs_key(cell_type));
            } else {
                gc.attr &= ~@as(u16, T.GRID_ATTR_CHARSET);
                if (wp) |p| {
                    if (win_mod.window_pane_index(p.window, p)) |idx| {
                        utf8.utf8_set(&gc.data, if (idx < 10) @as(u8, '0') + @as(u8, @intCast(idx)) else '*');
                    } else {
                        utf8.utf8_set(&gc.data, '*');
                    }
                } else {
                    utf8.utf8_set(&gc.data, '*');
                }
            }
        },
        // PANE_LINES_DOUBLE = 1
        1 => {
            gc.attr &= ~@as(u16, T.GRID_ATTR_CHARSET);
            gc.data = tty_acs.tty_acs_double_borders(cell_type).*;
        },
        // PANE_LINES_HEAVY = 2
        2 => {
            gc.attr &= ~@as(u16, T.GRID_ATTR_CHARSET);
            gc.data = tty_acs.tty_acs_heavy_borders(cell_type).*;
        },
        // PANE_LINES_SIMPLE = 3
        3 => {
            gc.attr &= ~@as(u16, T.GRID_ATTR_CHARSET);
            utf8.utf8_set(&gc.data, simple_border_byte(cell_type));
        },
        // PANE_LINES_SPACES = 5
        5 => {
            gc.attr &= ~@as(u16, T.GRID_ATTR_CHARSET);
            utf8.utf8_set(&gc.data, ' ');
        },
        // Default (single ACS borders)
        else => {
            gc.attr |= T.GRID_ATTR_CHARSET;
            utf8.utf8_set(&gc.data, default_border_acs_key(cell_type));
        },
    }
}

fn simple_border_byte(cell_type: usize) u8 {
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

// ── Border arrows (pane-border-indicators) ────────────────────────────────────

/// Draw an arrow indicator on the border gc if warranted.
/// Equivalent to screen_redraw_draw_border_arrows.
fn screen_redraw_draw_border_arrows(
    ctx: *const ScreenRedrawCtx,
    i: u32,
    j: u32,
    cell_type: usize,
    wp: ?*T.WindowPane,
    active: ?*T.WindowPane,
    gc: *T.GridCell,
) void {
    const c_ptr = ctx.c;
    const s = c_ptr.session orelse return;
    const wl = s.curw orelse return;
    const w = wl.window;
    const x = ctx.ox + i;
    const y = ctx.oy + j;

    _ = wp; // used below via active

    const value = opts.options_get_number(w.options, "pane-border-indicators");
    // PANE_BORDER_ARROWS=1, PANE_BORDER_BOTH=3
    if (value != 1 and value != 3) return;

    const act = active orelse return;

    // Only draw arrows near xoff+1 or yoff+1 of the active pane
    if (i != act.xoff + 1 and j != act.yoff + 1) return;

    var arrows = false;
    var border = screen_redraw_pane_border(ctx, act, x, y);
    if (border == .inside) return;

    if (i == act.xoff + 1) {
        if (border == .outside) {
            if (screen_redraw_two_panes(w, 1)) {
                if (w.panes.items.len > 0 and act == w.panes.items[0]) {
                    border = .border_bottom;
                } else {
                    border = .border_top;
                }
                arrows = true;
            }
        } else {
            if (cell_type == tty_acs.CELL_LEFTRIGHT) arrows = true
            else if (cell_type == tty_acs.CELL_TOPJOIN and border == .border_bottom) arrows = true
            else if (cell_type == tty_acs.CELL_BOTTOMJOIN and border == .border_top) arrows = true;
        }
    }
    if (j == act.yoff + 1) {
        if (border == .outside) {
            if (screen_redraw_two_panes(w, 0)) {
                if (w.panes.items.len > 0 and act == w.panes.items[0]) {
                    border = .border_right;
                } else {
                    border = .border_left;
                }
                arrows = true;
            }
        } else {
            if (cell_type == tty_acs.CELL_TOPBOTTOM) arrows = true
            else if (cell_type == tty_acs.CELL_LEFTJOIN and border == .border_right) arrows = true
            else if (cell_type == tty_acs.CELL_RIGHTJOIN and border == .border_left) arrows = true;
        }
    }

    if (arrows) {
        gc.attr |= T.GRID_ATTR_CHARSET;
        const marker_idx = @intFromEnum(border);
        if (marker_idx < BORDER_MARKERS.len)
            utf8.utf8_set(&gc.data, BORDER_MARKERS[marker_idx]);
    }
}

// ── Border style selection (per-cell) ────────────────────────────────────────

/// Get the grid_cell style for a border cell at window coords (x, y) near pane wp.
/// Equivalent to screen_redraw_draw_borders_style.
/// Returns null if unresolvable.
fn screen_redraw_draw_borders_style(
    ctx: *const ScreenRedrawCtx,
    x: u32,
    y: u32,
    wp: *T.WindowPane,
) ?T.GridCell {
    var gc = T.grid_default_cell;
    const active = server_client_mod.server_client_get_pane(ctx.c) orelse return null;

    if (screen_redraw_check_is(ctx, x, y, active)) {
        style_mod.style_apply(&gc, wp.window.options, "pane-active-border-style", null);
    } else {
        style_mod.style_apply(&gc, wp.window.options, "pane-border-style", null);
    }
    return gc;
}

// ── Full-screen redraw orchestration ─────────────────────────────────────────

/// Redraw the entire screen for client `c`.
/// Equivalent to screen_redraw_screen in screen-redraw.c.
///
/// The zmux draw path in server-client.zig already handles sending payloads to
/// the client peer via build_client_draw_payload / server_client_draw.
/// This function orchestrates the same logical sequence using the zmux
/// payload-based rendering API rather than direct tty_* calls.
pub fn screen_redraw_screen(c: *T.Client) void {
    if (c.flags & T.CLIENT_SUSPENDED != 0) return;

    var ctx: ScreenRedrawCtx = undefined;
    screen_redraw_set_context(c, &ctx);

    const flags = c.flags;
    if (flags & T.CLIENT_REDRAW == 0) return;

    const s = c.session orelse return;
    const wl = s.curw orelse return;

    log.log_debug("screen_redraw_screen: @{d}", .{wl.window.id});

    if (flags & (T.CLIENT_REDRAWWINDOW | T.CLIENT_REDRAWBORDERS) != 0) {
        log.log_debug("screen_redraw_screen: redrawing borders @{d}", .{wl.window.id});
        // TODO: draw_pane_status when pane status bar is ported
        // TODO: draw_pane_scrollbars fully via ctx (delegates to tty_draw for now)
    }

    if (flags & T.CLIENT_REDRAWWINDOW != 0) {
        log.log_debug("screen_redraw_screen: redrawing panes @{d}", .{wl.window.id});
        // Pane content draw is handled by the payload path in server_client_draw.
    }

    if (ctx.statuslines != 0 and
        flags & (T.CLIENT_REDRAWSTATUS | T.CLIENT_REDRAWSTATUSALWAYS) != 0)
    {
        log.log_debug("screen_redraw_screen: redrawing status @{d}", .{wl.window.id});
        // TODO: draw_status when status rendering is fully ported to ctx
    }

    if (c.overlay_draw != null and flags & T.CLIENT_REDRAWOVERLAY != 0) {
        log.log_debug("screen_redraw_screen: redrawing overlay @{d}", .{wl.window.id});
        // Overlay draw callback invocation:
        // TODO: invoke c.overlay_draw(c, c.overlay_data, &ctx) once ctx-based draw is wired
    }
}

/// Redraw a single pane and its scrollbar for client `c`.
/// Equivalent to screen_redraw_pane in screen-redraw.c.
pub fn screen_redraw_pane(c: *T.Client, wp: *T.WindowPane, redraw_scrollbar_only: bool) void {
    if (!win_mod.window_pane_visible(wp)) return;

    var ctx: ScreenRedrawCtx = undefined;
    screen_redraw_set_context(c, &ctx);

    if (!redraw_scrollbar_only) {
        // Pane content draw is done via the payload path for zmux.
        // TODO: wire screen_redraw_draw_pane (ctx-based) once the tty abstraction allows it.
        log.log_debug("screen_redraw_pane: pane %{d}", .{wp.id});
    }

    if (win_mod.window_pane_show_scrollbar(wp)) {
        screen_redraw_draw_pane_scrollbar_impl(&ctx, wp);
    }
}

// ── Scrollbar rendering ───────────────────────────────────────────────────────

/// Compute and store the scrollbar slider geometry for pane wp.
/// Equivalent to screen_redraw_draw_pane_scrollbar in screen-redraw.c.
fn screen_redraw_draw_pane_scrollbar_impl(ctx: *const ScreenRedrawCtx, wp: *T.WindowPane) void {
    const sb = ctx.pane_scrollbars;
    const sb_h = wp.sy;

    if (sb_h == 0) return;

    var slider_h: u32 = 0;
    var slider_y: u32 = 0;

    const mode = win_mod.window_pane_mode(wp);
    if (mode == null) {
        // Normal (non-modal) mode
        if (sb == T.PANE_SCROLLBARS_MODAL) return;

        // Show slider at bottom
        win_mod.window_pane_update_scrollbar_geometry(wp);
        slider_h = wp.sb_slider_h;
        slider_y = wp.sb_slider_y;
    } else {
        // Copy/mode view
        // TODO: wire window_copy_get_current_offset when copy mode is ported
        win_mod.window_pane_update_scrollbar_geometry(wp);
        slider_h = wp.sb_slider_h;
        slider_y = wp.sb_slider_y;
    }

    if (slider_h < 1) slider_h = 1;
    if (slider_y >= sb_h) slider_y = sb_h - 1;

    wp.sb_slider_y = slider_y;
    wp.sb_slider_h = slider_h;

    log.log_debug(
        "screen_redraw_draw_pane_scrollbar: pane %{d} slider_y={d} slider_h={d}",
        .{ wp.id, slider_y, slider_h },
    );
}

// ── Pane status bar (stubbed) ─────────────────────────────────────────────────

// TODO: screen_redraw_make_pane_status and screen_redraw_draw_pane_status
// require the format system (format_create, format_expand_time, format_draw)
// and the status_screen / status_size fields on WindowPane, none of which are
// ported yet.  Implement once those dependencies land.

// ── Tests ─────────────────────────────────────────────────────────────────────

test "screen_redraw_two_panes: single pane returns false" {
    const win = @import("window.zig");
    const xm = @import("xmalloc.zig");

    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    win.window_init_globals(xm.allocator);

    const w = win.window_create(10, 5, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
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
    _ = win.window_add_pane(w, null, 10, 5);
    try std.testing.expect(!screen_redraw_two_panes(w, 0));
    try std.testing.expect(!screen_redraw_two_panes(w, 1));
}

test "screen_redraw_two_panes: two horizontal panes" {
    const win = @import("window.zig");
    const xm = @import("xmalloc.zig");

    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    win.window_init_globals(xm.allocator);

    const w = win.window_create(10, 5, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
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
    const wp1 = win.window_add_pane(w, null, 5, 5);
    const wp2 = win.window_add_pane(w, null, 4, 5);
    wp1.xoff = 0;
    wp2.xoff = 6; // right-of-border
    // Two panes split horizontally: wp2.xoff != 0, direction 0
    try std.testing.expect(screen_redraw_two_panes(w, 0));
    try std.testing.expect(!screen_redraw_two_panes(w, 1));
}

test "screen_redraw_type_of_cell: CELL_OUTSIDE when no session" {
    const xm = @import("xmalloc.zig");
    const env_mod = @import("environ.zig");

    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);

    const cl = xm.allocator.create(T.Client) catch unreachable;
    defer xm.allocator.destroy(cl);
    cl.* = T.Client{
        .environ = env,
        .tty = undefined,
        .status = .{},
        .flags = 0,
        .session = null,
    };
    cl.tty = T.Tty{ .client = cl };

    var ctx = ScreenRedrawCtx{ .c = cl };
    const ct = screen_redraw_type_of_cell(&ctx, 0, 0);
    try std.testing.expectEqual(tty_acs.CELL_OUTSIDE, ct);
}

test "screen_redraw_border_set: spaces style returns space" {
    const win = @import("window.zig");
    const xm = @import("xmalloc.zig");

    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    win.window_init_globals(xm.allocator);

    const w = win.window_create(10, 5, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
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
    const wp = win.window_add_pane(w, null, 10, 5);

    var gc = T.grid_default_cell;
    // PANE_LINES_SPACES = 5
    screen_redraw_border_set(w, wp, 5, tty_acs.CELL_TOPBOTTOM, &gc);
    try std.testing.expectEqual(@as(u8, ' '), gc.data.data[0]);
}
