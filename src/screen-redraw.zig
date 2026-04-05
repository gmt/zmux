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
// Ported from tmux/screen-redraw.c
// Original copyright:
//   Copyright (c) 2007 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence -- same terms as above.

//! screen-redraw.zig -- screen redraw dispatch for direct tty connections.
//!
//! Provides `screen_redraw_screen` (full redraw) and `screen_redraw_pane`
//! (single-pane redraw) following the tmux screen-redraw.c pattern.  These
//! use the tty-level drawing functions (tty_draw_line, tty_draw_pane, etc.)
//! which write directly through the client's peer stream.

const std = @import("std");
const T = @import("types.zig");
const log = @import("log.zig");
const tty_mod = @import("tty.zig");
const win_mod = @import("window.zig");
const opts = @import("options.zig");
const status = @import("status.zig");
const status_prompt = @import("status-prompt.zig");
const resize_mod = @import("resize.zig");
const screen_mod = @import("screen.zig");

/// Redraw context matching tmux's `struct screen_redraw_ctx`.
const ScreenRedrawCtx = struct {
    c: *T.Client,

    statuslines: u32 = 0,
    statustop: bool = false,

    pane_status: u32 = T.PANE_STATUS_OFF,
    pane_scrollbars: u32 = 0,

    ox: u32 = 0,
    oy: u32 = 0,
    sx: u32 = 0,
    sy: u32 = 0,
};

/// Build the redraw context from client state (tmux: screen_redraw_set_context).
fn set_context(cl: *T.Client) ScreenRedrawCtx {
    const s = cl.session orelse return .{ .c = cl };
    const wl = s.curw orelse return .{ .c = cl };
    const w = wl.window;

    var lines = resize_mod.status_line_size(cl);
    if (cl.message_string != null or status_prompt.status_prompt_active(cl))
        lines = if (lines == 0) 1 else lines;

    const statustop = if (lines != 0)
        opts.options_get_number(s.options, "status-position") == 0
    else
        false;

    const pane_status: u32 = @intCast(@max(opts.options_get_number(w.options, "pane-border-status"), 0));
    const pane_scrollbars: u32 = @intCast(@max(opts.options_get_number(w.options, "pane-scrollbars"), 0));

    var ox: u32 = 0;
    var oy: u32 = 0;
    var sx: u32 = 0;
    var sy: u32 = 0;
    _ = tty_mod.tty_window_offset(&cl.tty, &ox, &oy, &sx, &sy);

    return .{
        .c = cl,
        .statuslines = lines,
        .statustop = statustop,
        .pane_status = pane_status,
        .pane_scrollbars = pane_scrollbars,
        .ox = ox,
        .oy = oy,
        .sx = sx,
        .sy = sy,
    };
}

/// Determine which redraw flags are actually needed (tmux: screen_redraw_update).
fn update_flags(ctx: *const ScreenRedrawCtx, flags: u64) u64 {
    var result = flags;
    const cl = ctx.c;

    const redraw = if (cl.message_string != null)
        status.status_message_redraw(cl)
    else if (status_prompt.status_prompt_active(cl))
        status.status_prompt_redraw(cl)
    else
        status.status_redraw(cl);

    if (!redraw and (result & T.CLIENT_REDRAWSTATUSALWAYS == 0))
        result &= ~T.CLIENT_REDRAWSTATUS;

    if (cl.overlay_draw != null)
        result |= T.CLIENT_REDRAWOVERLAY;

    return result;
}

/// Draw a single pane into the tty (tmux: screen_redraw_draw_pane).
///
/// Iterates over the pane's visible lines and calls tty_draw_line for each,
/// respecting the window offset in `ctx`.
fn draw_pane(ctx: *const ScreenRedrawCtx, wp: *T.WindowPane) void {
    const cl = ctx.c;
    const s = cl.session orelse return;
    const wl = s.curw orelse return;

    log.log_debug("screen_redraw_draw_pane: @{d} %%{d}", .{ wl.window.id, wp.id });

    // Check horizontal visibility.
    if (wp.xoff + wp.sx <= ctx.ox or wp.xoff >= ctx.ox + ctx.sx)
        return;

    const top: u32 = if (ctx.statustop) ctx.statuslines else 0;
    const screen = screen_mod.screen_current(wp);
    var defaults: T.GridCell = T.grid_default_cell;
    tty_mod.tty_default_colours(&defaults, wp);

    var j: u32 = 0;
    while (j < wp.sy) : (j += 1) {
        if (wp.yoff + j < ctx.oy or wp.yoff + j >= ctx.oy + ctx.sy)
            continue;
        const y = top + wp.yoff + j - ctx.oy;

        // Compute visible horizontal slice.
        var i: u32 = undefined;
        var x: u32 = undefined;
        var width: u32 = undefined;

        if (wp.xoff >= ctx.ox and wp.xoff + wp.sx <= ctx.ox + ctx.sx) {
            // All visible.
            i = 0;
            x = wp.xoff - ctx.ox;
            width = wp.sx;
        } else if (wp.xoff < ctx.ox and wp.xoff + wp.sx > ctx.ox + ctx.sx) {
            // Both sides clipped.
            i = ctx.ox;
            x = 0;
            width = ctx.sx;
        } else if (wp.xoff < ctx.ox) {
            // Left clipped.
            i = ctx.ox - wp.xoff;
            x = 0;
            width = wp.sx - i;
        } else {
            // Right clipped.
            i = 0;
            x = wp.xoff - ctx.ox;
            width = ctx.sx - x;
        }

        const r = tty_mod.tty_check_overlay_range(&cl.tty, x, y, width);
        var k: u32 = 0;
        while (k < r.used) : (k += 1) {
            const rr = &r.ranges[k];
            if (rr.nx != 0) {
                tty_mod.tty_draw_line(
                    &cl.tty,
                    screen,
                    i + (rr.px - x),
                    j,
                    rr.nx,
                    rr.px,
                    y,
                    &defaults,
                    &wp.palette,
                );
            }
        }
    }
}

/// Draw all visible panes (tmux: screen_redraw_draw_panes).
fn draw_panes(ctx: *const ScreenRedrawCtx) void {
    const cl = ctx.c;
    const s = cl.session orelse return;
    const wl = s.curw orelse return;
    const w = wl.window;

    log.log_debug("screen_redraw_draw_panes: @{d}", .{w.id});

    for (w.panes.items) |wp| {
        if (win_mod.window_pane_visible(wp))
            draw_pane(ctx, wp);
    }
}

/// Redraw the entire screen for a client (tmux: screen_redraw_screen).
///
/// Handles borders, panes, status, and overlay based on the client's
/// redraw flags.  Uses tty-level drawing which writes through the peer stream.
pub fn screen_redraw_screen(cl: *T.Client) void {
    if (cl.flags & T.CLIENT_SUSPENDED != 0)
        return;

    const ctx = set_context(cl);

    const flags = update_flags(&ctx, cl.flags);
    if (flags & T.CLIENT_ALLREDRAWFLAGS == 0)
        return;

    tty_mod.tty_sync_start(&cl.tty);
    tty_mod.tty_update_mode(&cl.tty, cl.tty.mode, null);

    // TODO: screen_redraw_draw_borders (delegated to payload path for now).
    if (flags & (T.CLIENT_REDRAWWINDOW | T.CLIENT_REDRAWBORDERS) != 0)
        log.log_debug("screen_redraw_screen: redrawing borders", .{});

    if (flags & T.CLIENT_REDRAWWINDOW != 0) {
        log.log_debug("screen_redraw_screen: redrawing panes", .{});
        draw_panes(&ctx);
    }

    // TODO: screen_redraw_draw_status (delegated to payload path for now).
    if (ctx.statuslines != 0 and
        (flags & (T.CLIENT_REDRAWSTATUS | T.CLIENT_REDRAWSTATUSALWAYS) != 0))
        log.log_debug("screen_redraw_screen: redrawing status", .{});

    // TODO: overlay_draw callback (delegated to payload path for now).
    if (cl.overlay_draw != null and (flags & T.CLIENT_REDRAWOVERLAY != 0))
        log.log_debug("screen_redraw_screen: redrawing overlay", .{});

    tty_mod.tty_reset(&cl.tty);
}

/// Redraw a single pane and its scrollbar (tmux: screen_redraw_pane).
///
/// Called from the per-pane redraw loop in server_client_check_redraw for
/// panes that have PANE_REDRAW set.
pub fn screen_redraw_pane(cl: *T.Client, wp: *T.WindowPane, scrollbar_only: bool) void {
    if (!win_mod.window_pane_visible(wp))
        return;

    var ctx = set_context(cl);

    tty_mod.tty_sync_start(&cl.tty);
    tty_mod.tty_update_mode(&cl.tty, cl.tty.mode, null);

    if (!scrollbar_only)
        draw_pane(&ctx, wp);

    // TODO: screen_redraw_draw_pane_scrollbar (delegated to payload path for now).
    if (win_mod.window_pane_show_scrollbar(wp))
        _ = &ctx;

    tty_mod.tty_reset(&cl.tty);
}

// ── Tests ────────────────────────────────────────────────────────────────

const xm = @import("xmalloc.zig");
const env_mod = @import("environ.zig");
const sess = @import("session.zig");
const pane_io = @import("pane-io.zig");

fn initTestGlobals() void {
    opts.global_options = opts.options_create(null);
    opts.global_s_options = opts.options_create(null);
    opts.global_w_options = opts.options_create(null);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    sess.session_init_globals(xm.allocator);
    win_mod.window_init_globals(xm.allocator);
}

fn deinitTestGlobals() void {
    opts.options_free(opts.global_w_options);
    opts.options_free(opts.global_s_options);
    opts.options_free(opts.global_options);
}

test "screen_redraw_pane draws visible pane lines" {
    initTestGlobals();
    defer deinitTestGlobals();

    const s = sess.session_create(null, "screen-redraw-pane-test", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("screen-redraw-pane-test") != null) sess.session_destroy(s, false, "test");

    const w = win_mod.window_create(4, 3, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    var cause: ?[]u8 = null;
    const wl = sess.session_attach(s, w, 0, &cause) orelse unreachable;
    s.curw = wl;

    const wp = win_mod.window_add_pane(w, null, 4, 3);
    wp.xoff = 0;
    wp.yoff = 0;
    w.active = wp;
    pane_io.pane_io_feed(wp, "abc\ndef\nghi");

    var client = T.Client{
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{},
        .flags = T.CLIENT_ATTACHED | T.CLIENT_UTF8 | T.CLIENT_STATUSOFF,
        .session = s,
    };
    defer env_mod.environ_free(client.environ);
    client.tty = .{ .client = &client, .sx = 4, .sy = 3 };

    // Should not crash; pane drawing goes through tty_draw_line -> tty_write
    // which requires a peer, so with peer=null it's a no-op but exercises the
    // clipping and iteration logic.
    screen_redraw_pane(&client, wp, false);

    // Scrollbar-only should also not crash.
    screen_redraw_pane(&client, wp, true);
}

test "screen_redraw_screen tolerates multiple visible panes" {
    initTestGlobals();
    defer deinitTestGlobals();

    const s = sess.session_create(null, "screen-redraw-multi-pane", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("screen-redraw-multi-pane") != null) sess.session_destroy(s, false, "test");

    const w = win_mod.window_create(8, 2, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    var cause: ?[]u8 = null;
    const wl = sess.session_attach(s, w, 0, &cause) orelse unreachable;
    s.curw = wl;

    const wp_left = win_mod.window_add_pane(w, null, 4, 2);
    const wp_right = win_mod.window_add_pane(w, null, 4, 2);
    wp_left.xoff = 0;
    wp_left.yoff = 0;
    wp_right.xoff = 4;
    wp_right.yoff = 0;
    w.active = wp_left;
    pane_io.pane_io_feed(wp_left, "L");
    pane_io.pane_io_feed(wp_right, "R");

    var client = T.Client{
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{},
        .flags = T.CLIENT_ATTACHED | T.CLIENT_UTF8 | T.CLIENT_STATUSOFF | T.CLIENT_REDRAWWINDOW,
        .session = s,
    };
    defer env_mod.environ_free(client.environ);
    client.tty = .{ .client = &client, .sx = 8, .sy = 2 };

    screen_redraw_screen(&client);
}

test "screen_redraw_screen with full redraw flags" {
    initTestGlobals();
    defer deinitTestGlobals();

    const s = sess.session_create(null, "screen-redraw-screen-test", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("screen-redraw-screen-test") != null) sess.session_destroy(s, false, "test");

    const w = win_mod.window_create(6, 2, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    var cause: ?[]u8 = null;
    const wl = sess.session_attach(s, w, 0, &cause) orelse unreachable;
    s.curw = wl;

    const wp = win_mod.window_add_pane(w, null, 6, 2);
    wp.xoff = 0;
    wp.yoff = 0;
    w.active = wp;
    pane_io.pane_io_feed(wp, "hello\nworld");

    var client = T.Client{
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{},
        .flags = T.CLIENT_ATTACHED | T.CLIENT_UTF8 | T.CLIENT_STATUSOFF | T.CLIENT_REDRAWWINDOW,
        .session = s,
    };
    defer env_mod.environ_free(client.environ);
    client.tty = .{ .client = &client, .sx = 6, .sy = 2 };

    // Full screen redraw should not crash.
    screen_redraw_screen(&client);
}

test "screen_redraw_pane skips invisible panes" {
    initTestGlobals();
    defer deinitTestGlobals();

    const s = sess.session_create(null, "screen-redraw-zoom-test", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("screen-redraw-zoom-test") != null) sess.session_destroy(s, false, "test");

    const w = win_mod.window_create(8, 3, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    var cause: ?[]u8 = null;
    const wl = sess.session_attach(s, w, 0, &cause) orelse unreachable;
    s.curw = wl;

    const wp1 = win_mod.window_add_pane(w, null, 4, 3);
    const wp2 = win_mod.window_add_pane(w, null, 4, 3);
    wp1.xoff = 0;
    wp1.yoff = 0;
    wp2.xoff = 4;
    wp2.yoff = 0;
    w.active = wp1;

    // Zoom the window -- only active pane should be visible.
    w.flags |= T.WINDOW_ZOOMED;

    var client = T.Client{
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{},
        .flags = T.CLIENT_ATTACHED | T.CLIENT_UTF8 | T.CLIENT_STATUSOFF,
        .session = s,
    };
    defer env_mod.environ_free(client.environ);
    client.tty = .{ .client = &client, .sx = 8, .sy = 3 };

    // wp2 is invisible (zoomed, not active) -- should be a no-op.
    screen_redraw_pane(&client, wp2, false);

    // wp1 (active) should still work.
    screen_redraw_pane(&client, wp1, false);
}
