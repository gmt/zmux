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
// Ported in part from tmux/tty.c.
// Original copyright:
//   Copyright (c) 2007 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

//! tty.zig – reduced server-side tty lifecycle and metadata helpers.

const std = @import("std");
const c_zig = @import("c.zig");
const T = @import("types.zig");
const grid = @import("grid.zig");
const file_mod = @import("file.zig");
const proc_mod = @import("proc.zig");
const xm = @import("xmalloc.zig");
const tty_features = @import("tty-features.zig");
const tty_term = @import("tty-term.zig");
const tty_draw_mod = @import("tty-draw.zig");
const hyperlinks_mod = @import("hyperlinks.zig");
const input_keys = @import("input-keys.zig");
const log = @import("log.zig");
const resize_mod = @import("resize.zig");
const status_mod = @import("status.zig");
const server_client_mod = @import("server-client.zig");
const client_registry = @import("client-registry.zig");
const server_fn = @import("server-fn.zig");
const notify_mod = @import("notify.zig");
const win_mod = @import("window.zig");
const tty_keys_mod = @import("tty-keys.zig");
const colour_mod = @import("colour.zig");
const session_mod = @import("session.zig");
const input_mod = @import("input.zig");
const paste_mod = @import("paste.zig");

pub fn tty_init(tty: *T.Tty, cl: *T.Client) void {
    tty.* = .{ .client = cl };
}

pub fn tty_set_size(tty: *T.Tty, sx: u32, sy: u32, xpixel: u32, ypixel: u32) void {
    tty.sx = @max(sx, 1);
    tty.sy = @max(sy, 1);
    tty.xpixel = if (xpixel == 0) T.DEFAULT_XPIXEL else xpixel;
    tty.ypixel = if (ypixel == 0) T.DEFAULT_YPIXEL else ypixel;
}

pub fn tty_resize(tty: *T.Tty, sx: u32, sy: u32, xpixel: u32, ypixel: u32) void {
    // Convert total pixel dimensions to per-cell (matching tmux tty_resize).
    const cw = if (sx > 0 and xpixel > 0) xpixel / sx else 0;
    const ch = if (sy > 0 and ypixel > 0) ypixel / sy else 0;
    tty_set_size(tty, sx, sy, cw, ch);
    tty_invalidate(tty);
}

pub fn tty_open(tty: *T.Tty, cause: *?[]u8) i32 {
    cause.* = null;
    tty.flags |= @intCast(T.TTY_OPENED);
    tty.flags &= ~@as(i32, @intCast(T.TTY_NOCURSOR | T.TTY_FREEZE | T.TTY_BLOCK));
    tty_start_tty(tty);
    tty_keys_build(tty);
    return 0;
}

pub fn tty_close(tty: *T.Tty) void {
    tty_stop_tty(tty);
    freeClipboardTimer(tty);
    freeStartTimer(tty);
    if (tty.flags & @as(i32, @intCast(T.TTY_OPENED)) != 0) {
        tty_keys_free(tty);
    }
    tty.flags &= ~@as(i32, @intCast(T.TTY_OPENED));
}

pub fn tty_start_tty(tty: *T.Tty) void {
    if ((tty.flags & @as(i32, @intCast(T.TTY_STARTED))) != 0) return;
    tty.flags |= @intCast(T.TTY_STARTED);
    tty_invalidate(tty);
    tty_start_start_timer(tty);
}

pub fn tty_stop_tty(tty: *T.Tty) void {
    cancelClipboardQuery(tty);
    cancelStartTimer(tty);
    tty.flags &= ~@as(i32, @intCast(T.TTY_STARTED | T.TTY_BLOCK));
}

/// Send initial DA/XDA queries to discover what the outer terminal supports.
/// Mirrors tmux tty_send_requests (tty.c).
pub fn tty_send_requests(tty: *T.Tty) void {
    if ((tty.flags & @as(i32, @intCast(T.TTY_STARTED))) == 0) return;
    // Send DA1, DA2, and XTVERSION to a VT100-like terminal if we have not
    // already received the corresponding responses.
    if (tty_term.isVt100Like(tty)) {
        if ((tty.flags & @as(i32, @intCast(T.TTY_HAVEDA))) == 0)
            tty_puts_str(tty, "\x1b[c");
        if ((tty.flags & @as(i32, @intCast(T.TTY_HAVEDA2))) == 0)
            tty_puts_str(tty, "\x1b[>c");
        if ((tty.flags & @as(i32, @intCast(T.TTY_HAVEXDA))) == 0)
            tty_puts_str(tty, "\x1b[>q");
        tty_puts_str(tty, "\x1b]10;?\x1b\\\x1b]11;?\x1b\\");
        tty.flags |= @intCast(T.TTY_WAITBG | T.TTY_WAITFG);
    } else {
        // Terminal does not look VT100-like; treat all requests as satisfied.
        tty.flags |= @intCast(T.TTY_ALL_REQUEST_FLAGS);
    }
    tty.last_requests = std.time.timestamp();
}

/// Repeat the foreground/background colour queries if enough time has elapsed.
/// Mirrors tmux tty_repeat_requests (tty.c).
pub fn tty_repeat_requests(tty: *T.Tty, force: i32) void {
    if ((tty.flags & @as(i32, @intCast(T.TTY_STARTED))) == 0) return;
    const t = std.time.timestamp();
    const n: i64 = t - tty.last_requests;
    if (force == 0 and n <= @as(i64, T.TTY_REQUEST_LIMIT)) return;
    tty.last_requests = t;
    if (tty_term.isVt100Like(tty)) {
        tty_puts_str(tty, "\x1b]10;?\x1b\\\x1b]11;?\x1b\\");
        tty.flags |= @intCast(T.TTY_WAITBG | T.TTY_WAITFG);
    }
    tty_start_start_timer(tty);
}

/// Write raw terminal data directly to the client fd, bypassing the
/// buffered output path.  Used during tty_stop_tty and server_lock_client
/// where the event loop may not be running.  Retries up to 5 times on
/// short writes or EAGAIN, matching tmux tty_raw().
pub fn tty_raw(tty: *T.Tty, s: []const u8) void {
    const fd = tty.client.fd;
    if (fd < 0) return;
    var buf = s;
    var i: u32 = 0;
    while (i < 5) : (i += 1) {
        const n = std.posix.write(@intCast(fd), buf) catch |err| {
            if (err == error.WouldBlock) {
                std.time.sleep(100_000); // 100 us, matches tmux usleep(100)
                continue;
            }
            return;
        };
        buf = buf[n..];
        if (buf.len == 0) break;
        std.time.sleep(100_000);
    }
}

pub fn tty_invalidate(tty: *T.Tty) void {
    tty.cell = T.grid_default_cell;
    tty.last_cell = T.grid_default_cell;
    tty.cx = std.math.maxInt(u32);
    tty.cy = std.math.maxInt(u32);
    tty.cstyle = .default;
    tty.ccolour = -1;
    tty.mode = 0;
    tty.fg = 8;
    tty.bg = 8;
    tty.us = 8;

    // Force re-emission of region and margin on next use.
    tty.rupper = 0;
    tty.rlower = 0;
    tty.rleft = 0;
    tty.rright = 0;
}

/// Context for pane-relative cursor positioning.
/// Captures the minimum fields from tmux's struct tty_ctx needed by
/// tty_cursor_pane and tty_cursor_pane_unless_wrap.
pub const TtyCursorCtx = struct {
    xoff: u32 = 0,
    yoff: u32 = 0,
    wox: u32 = 0,
    woy: u32 = 0,
    sx: u32 = 0,
    wrapped: bool = false,
};

/// Move the terminal cursor to absolute position (px, py).
/// Ported from tmux tty_cursor(). Uses terminfo capabilities (cup, home, cub1,
/// cuf1, cuu1, cud1, cub, cuf, cuu, cud, hpa, vpa) with fallback to the CUP
/// ANSI sequence. Handles automargin/wrap-at-right-margin behaviour.
pub fn tty_cursor(tty: *T.Tty, px: u32, py: u32) void {
    if ((tty.flags & @as(i32, @intCast(T.TTY_STARTED))) == 0) return;

    var cx = px;
    const cy = py;

    const thisx = tty.cx;
    const thisy = tty.cy;

    // If in the automargin space and want to be there, do not move.
    if (cx == thisx and cy == thisy and cx == tty.sx) return;

    // Clamp x to the right margin.
    if (cx > tty.sx - 1) cx = tty.sx - 1;

    // No change.
    if (cx == thisx and cy == thisy) return;

    const moved = moved: {
        // Currently at the very end of the line (past right margin) -- use absolute.
        if (thisx > tty.sx - 1) {
            tty_putcode_ii(tty, "cup", cy, cx);
            break :moved true;
        }

        // Move to home position (0, 0).
        if (cx == 0 and cy == 0) {
            if (tty_term.stringCapability(tty, "home")) |home| {
                if (home.len > 0) {
                    tty_write(tty, home);
                    break :moved true;
                }
            }
        }

        // Zero on the next line: CR + LF.
        if (cx == 0 and cy == thisy + 1) {
            tty_write(tty, "\r\n");
            break :moved true;
        }

        // Same row -- column-only movement.
        if (cy == thisy) {
            if (tryColumnMovement(tty, thisx, cx)) break :moved true;
        } else if (cx == thisx) {
            // Same column -- row-only movement.
            if (tryRowMovement(tty, thisy, cy)) break :moved true;
        }

        // Absolute movement: CUP (cup).
        tty_putcode_ii(tty, "cup", cy, cx);
        break :moved true;
    };

    if (moved) {
        tty.cx = cx;
        tty.cy = cy;
    }
}

/// Attempt relative column movement on the current row.
/// Returns true if a movement sequence was emitted.
fn tryColumnMovement(tty: *T.Tty, thisx: u32, cx: u32) bool {
    // To left edge.
    if (cx == 0) {
        tty_write(tty, "\r");
        return true;
    }

    // One to the left via cub1.
    if (cx == thisx -% 1) {
        if (tty_term.stringCapability(tty, "cub1")) |cub1| {
            if (cub1.len > 0) {
                tty_write(tty, cub1);
                return true;
            }
        }
    }

    // One to the right via cuf1.
    if (cx == thisx + 1) {
        if (tty_term.stringCapability(tty, "cuf1")) |cuf1| {
            if (cuf1.len > 0) {
                tty_write(tty, cuf1);
                return true;
            }
        }
    }

    const change: i64 = @as(i64, thisx) - @as(i64, cx); // positive = left, negative = right

    // Use HPA if change is larger than absolute target.
    if (@abs(change) > @as(i64, cx)) {
        if (tty_term.stringCapability(tty, "hpa")) |_| {
            tty_putcode_i(tty, "hpa", cx);
            return true;
        }
    }

    // Move left via cub.
    if (change > 0) {
        if (tty_term.stringCapability(tty, "cub")) |cub| {
            if (cub.len > 0) {
                if (change == 2) {
                    if (tty_term.stringCapability(tty, "cub1")) |cub1| {
                        if (cub1.len > 0) {
                            tty_write(tty, cub1);
                            tty_write(tty, cub1);
                            return true;
                        }
                    }
                }
                tty_putcode_i(tty, "cub", @intCast(change));
                return true;
            }
        }
    }

    // Move right via cuf.
    if (change < 0) {
        if (tty_term.stringCapability(tty, "cuf")) |cuf| {
            if (cuf.len > 0) {
                tty_putcode_i(tty, "cuf", @intCast(-change));
                return true;
            }
        }
    }

    return false;
}

/// Attempt relative row movement in the current column.
/// Returns true if a movement sequence was emitted.
fn tryRowMovement(tty: *T.Tty, thisy: u32, cy: u32) bool {
    // One above via cuu1.
    if (cy == thisy -% 1) {
        if (tty_term.stringCapability(tty, "cuu1")) |cuu1| {
            if (cuu1.len > 0) {
                tty_write(tty, cuu1);
                return true;
            }
        }
    }

    // One below via cud1.
    if (cy == thisy + 1) {
        if (tty_term.stringCapability(tty, "cud1")) |cud1| {
            if (cud1.len > 0) {
                tty_write(tty, cud1);
                return true;
            }
        }
    }

    const change: i64 = @as(i64, thisy) - @as(i64, cy); // positive = up, negative = down

    // Use VPA if change is larger than absolute target.
    if (@abs(change) > @as(i64, cy)) {
        if (tty_term.stringCapability(tty, "vpa")) |_| {
            tty_putcode_i(tty, "vpa", cy);
            return true;
        }
    }

    // Move up via cuu.
    if (change > 0) {
        if (tty_term.stringCapability(tty, "cuu")) |cuu| {
            if (cuu.len > 0) {
                tty_putcode_i(tty, "cuu", @intCast(change));
                return true;
            }
        }
    }

    // Move down via cud.
    if (change < 0) {
        if (tty_term.stringCapability(tty, "cud")) |cud| {
            if (cud.len > 0) {
                tty_putcode_i(tty, "cud", @intCast(-change));
                return true;
            }
        }
    }

    return false;
}

/// Move cursor inside a pane. Translates pane-relative coordinates to absolute
/// by adding the pane offset and subtracting the window origin.
/// Ported from tmux tty_cursor_pane().
pub fn tty_cursor_pane(tty: *T.Tty, ctx: *const TtyCursorCtx, px: u32, py: u32) void {
    const abs_x = ctx.xoff + px - ctx.wox;
    const abs_y = ctx.yoff + py - ctx.woy;
    tty_cursor(tty, abs_x, abs_y);
}

/// Same as tty_cursor_pane but skips if the cursor is already at the right
/// position (optimization for wrap-at-margin case).
/// Ported from tmux tty_cursor_pane_unless_wrap().
pub fn tty_cursor_pane_unless_wrap(tty: *T.Tty, ctx: *const TtyCursorCtx, px: u32, py: u32) void {
    if (!ctx.wrapped or
        !(ctx.xoff == 0 and ctx.sx >= tty.sx) or
        ctx.xoff + px != 0 or
        ctx.yoff + py != tty.cy + 1 or
        tty.cx < tty.sx)
    {
        tty_cursor_pane(tty, ctx, px, py);
    }
}

// ── Clear / region / margin operations ────────────────────────────────────────

/// Check whether BCE must be faked because the terminal lacks it and the
/// background colour is non-default.
/// Ported from tmux tty_fake_bce().
pub fn tty_fake_bce(tty: *const T.Tty, gc: *const T.GridCell, bg: u32) bool {
    if (tty_term.hasCapability(tty, "bce")) return false;
    if (!colour_default(@intCast(bg)) or !colour_default(gc.bg)) return true;
    return false;
}

/// Write N space characters, tracking cursor position.
/// Ported from tmux tty_repeat_space().
pub fn tty_repeat_space(tty: *T.Tty, n: u32) void {
    const spaces = [1]u8{' '} ** 500;
    var remaining = n;
    while (remaining > 500) {
        tty_putn(tty, &spaces, 500);
        remaining -= 500;
    }
    if (remaining > 0) {
        tty_putn(tty, spaces[0..remaining], remaining);
    }
}

/// Clear a line (or part of it: left-of-cursor, right-of-cursor, or whole line).
/// Uses el (erase to end of line), el1 (erase to start of line), and ech (erase
/// characters) capabilities, falling back to spaces when needed.
/// Ported from tmux tty_clear_line().
pub fn tty_clear_line(tty: *T.Tty, defaults: *const T.GridCell, py: u32, px: u32, nx: u32, bg: u32) void {
    // Nothing to clear.
    if (nx == 0) return;

    // If genuine BCE is available, try escape sequences.
    if (!tty_fake_bce(tty, defaults, bg)) {
        // Off the end of the line -- use EL if available.
        if (px + nx >= tty.sx and tty_term.hasCapability(tty, "el")) {
            tty_cursor(tty, px, py);
            tty_putcode(tty, "el");
            return;
        }

        // At the start of the line -- use EL1.
        if (px == 0 and tty_term.hasCapability(tty, "el1")) {
            tty_cursor(tty, px + nx - 1, py);
            tty_putcode(tty, "el1");
            return;
        }

        // Section of line -- use ECH if possible.
        if (tty_term.hasCapability(tty, "ech")) {
            tty_cursor(tty, px, py);
            tty_putcode_i(tty, "ech", nx);
            return;
        }
    }

    // Couldn't use an escape sequence -- use spaces.
    tty_cursor(tty, px, py);
    tty_repeat_space(tty, nx);
}

/// Clear a rectangular area of the screen. Uses ED, DECFRA, scrolling, or
/// falls back to per-line clearing via tty_clear_line.
/// Ported from tmux tty_clear_area().
pub fn tty_clear_area(tty: *T.Tty, defaults: *const T.GridCell, py: u32, ny: u32, px: u32, nx: u32, bg: u32) void {
    // Nothing to clear.
    if (nx == 0 or ny == 0) return;

    // If genuine BCE is available, try escape sequences.
    if (!tty_fake_bce(tty, defaults, bg)) {
        // Use ED if clearing off the bottom of the terminal.
        if (px == 0 and
            px + nx >= tty.sx and
            py + ny >= tty.sy and
            tty_term.hasCapability(tty, "ed"))
        {
            tty_cursor(tty, 0, py);
            tty_putcode(tty, "ed");
            return;
        }

        // Use DECFRA if the terminal supports it and bg is non-default.
        if (tty_term.hasCapability(tty, "Rect") and !colour_default(@intCast(bg))) {
            const seq = std.fmt.allocPrint(xm.allocator, "\x1b[32;{d};{d};{d};{d}$x", .{
                py + 1,
                px + 1,
                py + ny,
                px + nx,
            }) catch return;
            defer xm.allocator.free(seq);
            tty_write(tty, seq);
            return;
        }

        // Full lines can be scrolled away to clear them.
        if (px == 0 and
            px + nx >= tty.sx and
            ny > 2 and
            tty_term.hasCapability(tty, "csr") and
            tty_term.hasCapability(tty, "indn"))
        {
            tty_region(tty, py, py + ny - 1);
            tty_margin_off(tty);
            tty_putcode_i(tty, "indn", ny);
            return;
        }

        // If margins are supported, scroll the area off to clear it.
        if (nx > 2 and
            ny > 2 and
            tty_term.hasCapability(tty, "csr") and
            tty_use_margin(tty) and
            tty_term.hasCapability(tty, "indn"))
        {
            tty_region(tty, py, py + ny - 1);
            tty_margin(tty, px, px + nx - 1);
            tty_putcode_i(tty, "indn", ny);
            return;
        }
    }

    // Couldn't use an escape sequence -- loop over the lines.
    var yy: u32 = py;
    while (yy < py + ny) : (yy += 1) {
        tty_clear_line(tty, defaults, yy, px, nx, bg);
    }
}

/// Clear the whole screen. Delegates to tty_clear_area for the full terminal size.
/// Ported from the relevant portion of tmux tty_clear_screen().
pub fn tty_clear_screen(tty: *T.Tty, defaults: *const T.GridCell, bg: u32) void {
    tty_clear_area(tty, defaults, 0, tty.sy, 0, tty.sx, bg);
}

/// Set the scrolling region (top/bottom margins). Uses the csr capability.
/// Tracks rupper/rlower in the Tty struct to avoid redundant emission.
/// Ported from tmux tty_region().
pub fn tty_region(tty: *T.Tty, rupper: u32, rlower: u32) void {
    if (tty.rlower == rlower and tty.rupper == rupper) return;
    if (!tty_term.hasCapability(tty, "csr")) return;

    tty.rupper = rupper;
    tty.rlower = rlower;

    // Some terminals (such as PuTTY) do not correctly reset the cursor to
    // 0,0 if it is beyond the last column (they do not reset their wrap
    // flag so further output causes a line feed). Do an explicit move to 0.
    if (tty.cx >= tty.sx) {
        if (tty.cy == std.math.maxInt(u32)) {
            tty_cursor(tty, 0, 0);
        } else {
            tty_cursor(tty, 0, tty.cy);
        }
    }

    tty_putcode_ii(tty, "csr", tty.rupper, tty.rlower);
    tty.cx = std.math.maxInt(u32);
    tty.cy = std.math.maxInt(u32);
}

/// Reset the scrolling region to the full terminal height.
/// Ported from tmux tty_region_off().
pub fn tty_region_off(tty: *T.Tty) void {
    tty_region(tty, 0, tty.sy - 1);
}

/// Set the scrolling region inside a pane. Translates pane-relative coordinates
/// to absolute by adding the pane offset and subtracting the window origin.
/// Ported from tmux tty_region_pane().
pub fn tty_region_pane(tty: *T.Tty, ctx: *const TtyCursorCtx, rupper: u32, rlower: u32) void {
    tty_region(tty, ctx.yoff + rupper - ctx.woy, ctx.yoff + rlower - ctx.woy);
}

/// Check whether the terminal supports DECSLRM (left/right margins).
/// Ported from tmux tty_use_margin() macro.
pub fn tty_use_margin(tty: *const T.Tty) bool {
    return tty_features.supportsTty(tty, .margins);
}

/// Set left/right margins. Uses SLRM (DECSLRM) via Clmg (clear margins) and
/// Cmg (set margins) capabilities. Tracks rleft/rright in the Tty struct.
/// Ported from tmux tty_margin().
pub fn tty_margin(tty: *T.Tty, rleft: u32, rright: u32) void {
    if (!tty_use_margin(tty)) return;
    if (tty.rleft == rleft and tty.rright == rright) return;

    // Must re-emit the vertical scrolling region first (csr).
    tty_putcode_ii(tty, "csr", tty.rupper, tty.rlower);

    tty.rleft = rleft;
    tty.rright = rright;

    if (rleft == 0 and rright == tty.sx - 1) {
        tty_putcode(tty, "Clmg");
    } else {
        tty_putcode_ii(tty, "Cmg", rleft, rright);
    }
    tty.cx = std.math.maxInt(u32);
    tty.cy = std.math.maxInt(u32);
}

/// Reset left/right margins to the full terminal width.
/// Ported from tmux tty_margin_off().
pub fn tty_margin_off(tty: *T.Tty) void {
    tty_margin(tty, 0, tty.sx - 1);
}

/// Set margins inside a pane. Translates pane coordinates to absolute.
/// Ported from tmux tty_margin_pane().
pub fn tty_margin_pane(tty: *T.Tty, ctx: *const TtyCursorCtx) void {
    tty_margin(tty, ctx.xoff - ctx.wox, ctx.xoff + ctx.sx - 1 - ctx.wox);
}

/// Emit a terminfo string capability with one integer parameter.
/// Expands simple %i%p1%d-style parameterized strings, falls back to CUP-like
/// manual expansion for common capabilities.
fn tty_putcode_i(tty: *T.Tty, name: []const u8, a: u32) void {
    const s = tty_term.stringCapability(tty, name) orelse return;
    if (s.len == 0) return;
    const expanded = expand_tparm_1(s, a) catch return;
    defer xm.allocator.free(expanded);
    tty_write(tty, expanded);
}

/// Emit a terminfo string capability with two integer parameters.
/// Expands %i%p1%d;%p2%d-style parameterized strings, falls back to CUP-like
/// manual expansion for common capabilities.
fn tty_putcode_ii(tty: *T.Tty, name: []const u8, a: u32, b: u32) void {
    const s = tty_term.stringCapability(tty, name) orelse return;
    if (s.len == 0) return;
    const expanded = expand_tparm_2(s, a, b) catch return;
    defer xm.allocator.free(expanded);
    tty_write(tty, expanded);
}

/// Expand a terminfo string with one integer parameter.
/// Handles %i (increment), %p1%d (print param 1 as decimal), and literal text.
fn expand_tparm_1(template: []const u8, a: u32) ![]u8 {
    var pa = a;
    return expand_tparm_impl(template, &pa, null);
}

/// Expand a terminfo string with two integer parameters.
/// Handles %i (increment), %p1%d / %p2%d (print params as decimal), and literal text.
fn expand_tparm_2(template: []const u8, a: u32, b: u32) ![]u8 {
    var pa = a;
    var pb = b;
    return expand_tparm_impl(template, &pa, &pb);
}

/// Core terminfo parameter expansion for up to 2 integer parameters.
/// Supports: %i (increment both params), %p1%d (param 1 decimal),
/// %p2%d (param 2 decimal), %% (literal %), and literal characters.
fn expand_tparm_impl(template: []const u8, pa: *u32, pb: ?*u32) ![]u8 {
    var out: std.ArrayList(u8) = .{};
    errdefer out.deinit(xm.allocator);

    var idx: usize = 0;
    while (idx < template.len) {
        if (template[idx] != '%') {
            try out.append(xm.allocator, template[idx]);
            idx += 1;
            continue;
        }
        idx += 1;
        if (idx >= template.len) break;
        switch (template[idx]) {
            '%' => {
                try out.append(xm.allocator, '%');
                idx += 1;
            },
            'i' => {
                pa.* += 1;
                if (pb) |b| b.* += 1;
                idx += 1;
            },
            'p' => {
                idx += 1;
                if (idx >= template.len) break;
                const param_num = template[idx];
                idx += 1;
                // Skip format specifier (e.g. %d)
                if (idx < template.len and template[idx] == 'd') {
                    idx += 1;
                }
                const val: u32 = switch (param_num) {
                    '1' => pa.*,
                    '2' => if (pb) |b| b.* else 0,
                    else => 0,
                };
                const digits = std.fmt.allocPrint(xm.allocator, "{d}", .{val}) catch unreachable;
                defer xm.allocator.free(digits);
                try out.appendSlice(xm.allocator, digits);
            },
            else => {
                idx += 1;
            },
        }
    }

    return out.toOwnedSlice(xm.allocator);
}

// ── Colour helpers ──────────────────────────────────────────────────────────

/// Split a colour value (without flags) into R, G, B components.
fn colour_split_rgb(c: i32) struct { r: u8, g: u8, b: u8 } {
    return .{
        .r = @intCast((c >> 16) & 0xff),
        .g = @intCast((c >> 8) & 0xff),
        .b = @intCast(c & 0xff),
    };
}

/// Force a colour value to RGB form. Returns -1 if not convertible.
fn colour_force_rgb(c: i32) i32 {
    if (c & T.COLOUR_FLAG_RGB != 0) return c;
    if (c & T.COLOUR_FLAG_256 != 0) return colour_256_to_rgb(c);
    if (c >= 0 and c <= 7) return colour_256_to_rgb(c);
    if (c >= 90 and c <= 97) return colour_256_to_rgb(8 + c - 90);
    return -1;
}

/// Convert a 256-colour index to the closest 16-colour index.
fn colour_256_to_16(c: i32) i32 {
    const table = [256]i8{
         0,  1,  2,  3,  4,  5,  6,  7,  8,  9, 10, 11, 12, 13, 14, 15,
         0,  4,  4,  4, 12, 12,  2,  6,  4,  4, 12, 12,  2,  2,  6,  4,
        12, 12,  2,  2,  2,  6, 12, 12, 10, 10, 10, 10, 14, 12, 10, 10,
        10, 10, 10, 14,  1,  5,  4,  4, 12, 12,  3,  8,  4,  4, 12, 12,
         2,  2,  6,  4, 12, 12,  2,  2,  2,  6, 12, 12, 10, 10, 10, 10,
        14, 12, 10, 10, 10, 10, 10, 14,  1,  1,  5,  4, 12, 12,  1,  1,
         5,  4, 12, 12,  3,  3,  8,  4, 12, 12,  2,  2,  2,  6, 12, 12,
        10, 10, 10, 10, 14, 12, 10, 10, 10, 10, 10, 14,  1,  1,  1,  5,
        12, 12,  1,  1,  1,  5, 12, 12,  1,  1,  1,  5, 12, 12,  3,  3,
         3,  7, 12, 12, 10, 10, 10, 10, 14, 12, 10, 10, 10, 10, 10, 14,
         9,  9,  9,  9, 13, 12,  9,  9,  9,  9, 13, 12,  9,  9,  9,  9,
        13, 12,  9,  9,  9,  9, 13, 12, 11, 11, 11, 11,  7, 12, 10, 10,
        10, 10, 10, 14,  9,  9,  9,  9,  9, 13,  9,  9,  9,  9,  9, 13,
         9,  9,  9,  9,  9, 13,  9,  9,  9,  9,  9, 13,  9,  9,  9,  9,
         9, 13, 11, 11, 11, 11, 11, 15,  0,  0,  0,  0,  0,  0,  8,  8,
         8,  8,  8,  8,  7,  7,  7,  7,  7,  7, 15, 15, 15, 15, 15, 15,
    };
    const idx: usize = @intCast(c & 0xff);
    return table[idx];
}

/// Convert a 256-colour index (or standard 0-7) to RGB.
fn colour_256_to_rgb(c: i32) i32 {
    const table = [256]i32{
        0x000000, 0x800000, 0x008000, 0x808000,
        0x000080, 0x800080, 0x008080, 0xc0c0c0,
        0x808080, 0xff0000, 0x00ff00, 0xffff00,
        0x0000ff, 0xff00ff, 0x00ffff, 0xffffff,
        0x000000, 0x00005f, 0x000087, 0x0000af,
        0x0000d7, 0x0000ff, 0x005f00, 0x005f5f,
        0x005f87, 0x005faf, 0x005fd7, 0x005fff,
        0x008700, 0x00875f, 0x008787, 0x0087af,
        0x0087d7, 0x0087ff, 0x00af00, 0x00af5f,
        0x00af87, 0x00afaf, 0x00afd7, 0x00afff,
        0x00d700, 0x00d75f, 0x00d787, 0x00d7af,
        0x00d7d7, 0x00d7ff, 0x00ff00, 0x00ff5f,
        0x00ff87, 0x00ffaf, 0x00ffd7, 0x00ffff,
        0x5f0000, 0x5f005f, 0x5f0087, 0x5f00af,
        0x5f00d7, 0x5f00ff, 0x5f5f00, 0x5f5f5f,
        0x5f5f87, 0x5f5faf, 0x5f5fd7, 0x5f5fff,
        0x5f8700, 0x5f875f, 0x5f8787, 0x5f87af,
        0x5f87d7, 0x5f87ff, 0x5faf00, 0x5faf5f,
        0x5faf87, 0x5fafaf, 0x5fafd7, 0x5fafff,
        0x5fd700, 0x5fd75f, 0x5fd787, 0x5fd7af,
        0x5fd7d7, 0x5fd7ff, 0x5fff00, 0x5fff5f,
        0x5fff87, 0x5fffaf, 0x5fffd7, 0x5fffff,
        0x870000, 0x87005f, 0x870087, 0x8700af,
        0x8700d7, 0x8700ff, 0x875f00, 0x875f5f,
        0x875f87, 0x875faf, 0x875fd7, 0x875fff,
        0x878700, 0x87875f, 0x878787, 0x8787af,
        0x8787d7, 0x8787ff, 0x87af00, 0x87af5f,
        0x87af87, 0x87afaf, 0x87afd7, 0x87afff,
        0x87d700, 0x87d75f, 0x87d787, 0x87d7af,
        0x87d7d7, 0x87d7ff, 0x87ff00, 0x87ff5f,
        0x87ff87, 0x87ffaf, 0x87ffd7, 0x87ffff,
        0xaf0000, 0xaf005f, 0xaf0087, 0xaf00af,
        0xaf00d7, 0xaf00ff, 0xaf5f00, 0xaf5f5f,
        0xaf5f87, 0xaf5faf, 0xaf5fd7, 0xaf5fff,
        0xaf8700, 0xaf875f, 0xaf8787, 0xaf87af,
        0xaf87d7, 0xaf87ff, 0xafaf00, 0xafaf5f,
        0xafaf87, 0xafafaf, 0xafafd7, 0xafafff,
        0xafd700, 0xafd75f, 0xafd787, 0xafd7af,
        0xafd7d7, 0xafd7ff, 0xafff00, 0xafff5f,
        0xafff87, 0xafffaf, 0xafffd7, 0xafffff,
        0xd70000, 0xd7005f, 0xd70087, 0xd700af,
        0xd700d7, 0xd700ff, 0xd75f00, 0xd75f5f,
        0xd75f87, 0xd75faf, 0xd75fd7, 0xd75fff,
        0xd78700, 0xd7875f, 0xd78787, 0xd787af,
        0xd787d7, 0xd787ff, 0xd7af00, 0xd7af5f,
        0xd7af87, 0xd7afaf, 0xd7afd7, 0xd7afff,
        0xd7d700, 0xd7d75f, 0xd7d787, 0xd7d7af,
        0xd7d7d7, 0xd7d7ff, 0xd7ff00, 0xd7ff5f,
        0xd7ff87, 0xd7ffaf, 0xd7ffd7, 0xd7ffff,
        0xff0000, 0xff005f, 0xff0087, 0xff00af,
        0xff00d7, 0xff00ff, 0xff5f00, 0xff5f5f,
        0xff5f87, 0xff5faf, 0xff5fd7, 0xff5fff,
        0xff8700, 0xff875f, 0xff8787, 0xff87af,
        0xff87d7, 0xff87ff, 0xffaf00, 0xffaf5f,
        0xffaf87, 0xffafaf, 0xffafd7, 0xffafff,
        0xffd700, 0xffd75f, 0xffd787, 0xffd7af,
        0xffd7d7, 0xffd7ff, 0xffff00, 0xffff5f,
        0xffff87, 0xffffaf, 0xffffd7, 0xffffff,
        0x080808, 0x121212, 0x1c1c1c, 0x262626,
        0x303030, 0x3a3a3a, 0x444444, 0x4e4e4e,
        0x585858, 0x626262, 0x6c6c6c, 0x767676,
        0x808080, 0x8a8a8a, 0x949494, 0x9e9e9e,
        0xa8a8a8, 0xb2b2b2, 0xbcbcbc, 0xc6c6c6,
        0xd0d0d0, 0xdadada, 0xe4e4e4, 0xeeeeee,
    };
    const idx: usize = @intCast(c & 0xff);
    return table[idx] | @as(i32, T.COLOUR_FLAG_RGB);
}

/// Convert RGB to the closest 256-colour palette index (with COLOUR_FLAG_256 set).
fn colour_find_rgb(r: u8, g: u8, b: u8) i32 {
    const q2c = [6]i32{ 0x00, 0x5f, 0x87, 0xaf, 0xd7, 0xff };

    const qr = colour_to_6cube(r);
    const qg = colour_to_6cube(g);
    const qb = colour_to_6cube(b);
    const cr = q2c[qr];
    const cg = q2c[qg];
    const cb = q2c[qb];

    // Exact match in 6x6x6 cube?
    if (cr == r and cg == g and cb == b)
        return (16 + 36 * qr + 6 * qg + qb) | @as(i32, T.COLOUR_FLAG_256);

    // Closest grey.
    const grey_avg = (@as(i32, r) + g + b) / 3;
    const grey_idx: i32 = if (grey_avg > 238) 23 else (grey_avg - 3) / 10;
    const grey = 8 + 10 * grey_idx;

    // Pick closer of cube or grey.
    const d_cube = colour_dist_sq(cr, cg, cb, r, g, b);
    const d_grey = colour_dist_sq(grey, grey, grey, r, g, b);
    const idx = if (d_grey < d_cube) 232 + grey_idx else 16 + 36 * qr + 6 * qg + qb;
    return idx | @as(i32, T.COLOUR_FLAG_256);
}

fn colour_to_6cube(v: u8) i32 {
    if (v < 48) return 0;
    if (v < 114) return 1;
    return (@as(i32, v) - 35) / 40;
}

fn colour_dist_sq(R: i32, G: i32, B: i32, r: u8, g: u8, b: u8) i32 {
    return (R - r) * (R - r) + (G - g) * (G - g) + (B - b) * (B - b);
}

/// Check whether a colour value is the default colour (8 or 9).
fn colour_default(c: i32) bool {
    return c == 8 or c == 9;
}

/// Get a colour from a palette if available.
fn colour_palette_get(palette: ?*T.ColourPalette, n: i32) i32 {
    const p = palette orelse return -1;
    var idx = n;
    if (idx >= 90 and idx <= 97)
        idx = 8 + idx - 90
    else if (idx & T.COLOUR_FLAG_256 != 0)
        idx &= ~@as(i32, T.COLOUR_FLAG_256)
    else if (idx >= 8)
        return -1;

    if (idx < 0 or idx > 255) return -1;
    const uidx: usize = @intCast(idx);

    if (p.palette) |pal| {
        if (pal[uidx] != -1) return pal[uidx];
    }
    if (p.default_palette) |dpal| {
        if (dpal[uidx] != -1) return dpal[uidx];
    }
    return -1;
}

// ── TTY reset ───────────────────────────────────────────────────────────────

/// Reset terminal to default attribute state. Clears colours, attributes,
/// and hyperlink. Uses terminfo sgr0 or fallback CSI 0m.
/// Ported from tmux tty_reset().
pub fn tty_reset(tty: *T.Tty) void {
    if ((tty.flags & @as(i32, @intCast(T.TTY_STARTED))) == 0) return;

    const gc = &tty.cell;
    if (!grid.cells_equal(gc, &T.grid_default_cell)) {
        if (gc.link != 0) {
            // Clear hyperlink.
            tty_putcode_ss(tty, "Hls", "", "");
        }
        if ((gc.attr & T.GRID_ATTR_CHARSET) != 0)
            tty_putcode(tty, "rmacs");
        tty_putcode(tty, "sgr0");
        tty.cell = T.grid_default_cell;
    }
    tty.last_cell = T.grid_default_cell;

    tty.fg = 8;
    tty.bg = 8;
    tty.us = 8;
}

/// Emit OSC 8 hyperlink escape sequences.  Tracks the current link in
/// tty.cell.link and only emits when it changes.  Ported from tmux
/// tty_hyperlink().
fn tty_hyperlink(tty: *T.Tty, gc: *const T.GridCell, hl: ?*hyperlinks_mod.Hyperlinks) void {
    if (gc.link == tty.cell.link) return;
    tty.cell.link = gc.link;

    const h = hl orelse return;

    var uri: []const u8 = "";
    var id: []const u8 = "";
    if (gc.link != 0 and hyperlinks_mod.hyperlinks_get(h, gc.link, &uri, null, &id)) {
        tty_putcode_ss(tty, "Hls", id, uri);
    } else {
        tty_putcode_ss(tty, "Hls", "", "");
    }
}

/// Apply text attributes (bold, dim, italic, underline, strikethrough, etc.)
/// and colours to the terminal. Tracks current state in tty.cell to only
/// emit changes when attributes differ.
/// Ported from tmux tty_attributes().
pub fn tty_attributes(tty: *T.Tty, gc: *const T.GridCell, defaults: *const T.GridCell, hl: ?*hyperlinks_mod.Hyperlinks) void {
    var gc2 = gc.*;
    const tc = &tty.cell;

    // Update default colours from the defaults cell.
    if ((gc.flags & T.GRID_FLAG_NOPALETTE) == 0) {
        if (gc2.fg == 8)
            gc2.fg = defaults.fg;
        if (gc2.bg == 8)
            gc2.bg = defaults.bg;
    }

    // If the cell looks the same as the last one rendered, skip.
    if (gc2.attr == tty.last_cell.attr and
        gc2.fg == tty.last_cell.fg and
        gc2.bg == tty.last_cell.bg and
        gc2.us == tty.last_cell.us and
        gc2.link == tty.last_cell.link)
    {
        return;
    }

    // If no setab, use reverse as best-effort for non-default background.
    if (!tty_term.hasCapability(tty, "setab")) {
        if ((gc2.attr & T.GRID_ATTR_REVERSE) != 0) {
            if (gc2.fg != 7 and !colour_default(gc2.fg))
                gc2.attr &= ~T.GRID_ATTR_REVERSE;
        } else {
            if (gc2.bg != 0 and !colour_default(gc2.bg))
                gc2.attr |= T.GRID_ATTR_REVERSE;
        }
    }

    // Fix up the colours if necessary (palette substitution, RGB-to-256
    // downsampling when the terminal lacks truecolour support).
    tty_check_fg(tty, null, &gc2);
    tty_check_bg(tty, null, &gc2);
    tty_check_us(tty, null, &gc2);

    // If any bits are being cleared, reset everything first.
    if ((tc.attr & ~gc2.attr) != 0 or (tc.us != gc2.us and gc2.us == 0))
        tty_reset(tty);

    // Set the colours.
    tty_colours(tty, &gc2);

    // Filter out attribute bits already set.
    const changed = gc2.attr & ~tc.attr;
    tc.attr = gc2.attr;

    // Set the attributes.
    if ((changed & T.GRID_ATTR_BRIGHT) != 0)
        tty_putcode(tty, "bold");
    if ((changed & T.GRID_ATTR_DIM) != 0)
        tty_putcode(tty, "dim");
    if ((changed & T.GRID_ATTR_ITALICS) != 0)
        tty_set_italics(tty);
    if ((changed & T.GRID_ATTR_ALL_UNDERSCORE) != 0) {
        if ((changed & T.GRID_ATTR_UNDERSCORE) != 0) {
            tty_putcode(tty, "smul");
        } else if ((changed & T.GRID_ATTR_UNDERSCORE_2) != 0) {
            tty_putcode_i(tty, "Smulx", 2);
        } else if ((changed & T.GRID_ATTR_UNDERSCORE_3) != 0) {
            tty_putcode_i(tty, "Smulx", 3);
        } else if ((changed & T.GRID_ATTR_UNDERSCORE_4) != 0) {
            tty_putcode_i(tty, "Smulx", 4);
        } else if ((changed & T.GRID_ATTR_UNDERSCORE_5) != 0) {
            tty_putcode_i(tty, "Smulx", 5);
        }
    }
    if ((changed & T.GRID_ATTR_BLINK) != 0)
        tty_putcode(tty, "blink");
    if ((changed & T.GRID_ATTR_REVERSE) != 0) {
        if (tty_term.hasCapability(tty, "rev")) {
            tty_putcode(tty, "rev");
        } else if (tty_term.hasCapability(tty, "smso")) {
            tty_putcode(tty, "smso");
        }
    }
    if ((changed & T.GRID_ATTR_HIDDEN) != 0)
        tty_putcode(tty, "invis");
    if ((changed & T.GRID_ATTR_STRIKETHROUGH) != 0)
        tty_putcode(tty, "smxx");
    if ((changed & T.GRID_ATTR_OVERLINE) != 0)
        tty_putcode(tty, "Smol");
    if ((changed & T.GRID_ATTR_CHARSET) != 0)
        tty_putcode(tty, "smacs");

    // Set hyperlink if any.
    tty_hyperlink(tty, gc, hl);

    tty.last_cell = gc2;
}

/// Render a single grid cell. Handles character output including padding
/// characters and single-byte vs multi-byte output. Uses tty_attributes for
/// attribute/colour state and tty_putc/tty_putn for character emission.
/// Ported from tmux tty_cell().
pub fn tty_cell(tty: *T.Tty, gc: *const T.GridCell, defaults: *const T.GridCell, hl: ?*hyperlinks_mod.Hyperlinks) void {
    // If this is a padding character, do nothing.
    if ((gc.flags & T.GRID_FLAG_PADDING) != 0)
        return;

    // Apply attributes and colours.
    tty_attributes(tty, gc, defaults, hl);

    // If it is a single-byte character, write with putc.
    if (gc.data.size == 1) {
        const ch = gc.data.data[0];
        if (ch < 0x20 or ch == 0x7f)
            return;
        tty_putc(tty, ch);
        return;
    }

    // Multi-byte character: write the data.
    tty_putn(tty, gc.data.data[0..gc.data.size], gc.data.width);
}

/// Emit a terminfo string capability with no parameters.
pub fn tty_putcode(tty: *T.Tty, name: []const u8) void {
    const s = tty_term.stringCapability(tty, name) orelse return;
    if (s.len == 0) return;
    tty_write(tty, s);
}

/// Emit a terminfo string capability with two string parameters.
pub fn tty_putcode_ss(tty: *T.Tty, name: []const u8, a: []const u8, b: []const u8) void {
    const template = tty_term.stringCapability(tty, name) orelse return;
    if (template.len == 0) return;
    const expanded = expand_tparm_ss(template, a, b) catch return;
    defer xm.allocator.free(expanded);
    tty_write(tty, expanded);
}

/// Write a single character to the terminal, tracking cursor position.
fn tty_putc(tty: *T.Tty, ch: u8) void {
    // Handle ACS charset mode.
    if ((tty.cell.attr & T.GRID_ATTR_CHARSET) != 0) {
        if (tty_term.acsCapability(tty, ch)) |acs| {
            tty_write(tty, acs);
        } else {
            tty_write(tty, &[_]u8{ch});
        }
    } else {
        tty_write(tty, &[_]u8{ch});
    }

    if (ch >= 0x20 and ch != 0x7f) {
        if (tty.cx >= tty.sx) {
            tty.cx = 1;
            tty.cy += 1;
        } else {
            tty.cx += 1;
        }
    }
}

/// Write a byte string with known display width, tracking cursor position.
fn tty_putn(tty: *T.Tty, buf: []const u8, width: u32) void {
    tty_write(tty, buf);
    if (tty.cx + width > tty.sx) {
        tty.cx = (tty.cx + width) - tty.sx;
        if (tty.cx <= tty.sx)
            tty.cy += 1
        else {
            tty.cx = std.math.maxInt(u32);
            tty.cy = std.math.maxInt(u32);
        }
    } else {
        tty.cx += width;
    }
}

/// Set italics mode. Uses sitm if available, falls back to smso (standout).
/// Ported from tmux tty_set_italics().
fn tty_set_italics(tty: *T.Tty) void {
    if (tty_term.hasCapability(tty, "sitm")) {
        tty_putcode(tty, "sitm");
        return;
    }
    tty_putcode(tty, "smso");
}

/// Expand a terminfo string with two string parameters (%p1%s and %p2%s).
fn expand_tparm_ss(template: []const u8, a: []const u8, b: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .{};
    errdefer out.deinit(xm.allocator);

    var idx: usize = 0;
    while (idx < template.len) {
        if (std.mem.startsWith(u8, template[idx..], "%p1%s")) {
            try out.appendSlice(xm.allocator, a);
            idx += "%p1%s".len;
            continue;
        }
        if (std.mem.startsWith(u8, template[idx..], "%p2%s")) {
            try out.appendSlice(xm.allocator, b);
            idx += "%p2%s".len;
            continue;
        }
        if (std.mem.startsWith(u8, template[idx..], "%%")) {
            try out.append(xm.allocator, '%');
            idx += 2;
            continue;
        }
        try out.append(xm.allocator, template[idx]);
        idx += 1;
    }

    return out.toOwnedSlice(xm.allocator);
}

// ── Colour pipeline ─────────────────────────────────────────────────────────

/// Set foreground and background colours for a grid cell.
/// Ported from tmux tty_colours().
pub fn tty_colours(tty: *T.Tty, gc: *const T.GridCell) void {
    const tc_fg = tty.fg;
    const tc_bg = tty.bg;
    const tc_us = tty.us;

    // No changes? Nothing is necessary.
    if (gc.fg == tc_fg and gc.bg == tc_bg and gc.us == tc_us)
        return;

    // If either is the default colour, handle specially.
    if (colour_default(gc.fg) or colour_default(gc.bg)) {
        // If AX not available, do a full reset. Otherwise set defaults individually.
        if (!tty_term.hasCapability(tty, "AX")) {
            tty_reset(tty);
        } else {
            if (colour_default(gc.fg) and !colour_default(tc_fg)) {
                tty_write(tty, "\x1b[39m");
                tty.fg = gc.fg;
            }
            if (colour_default(gc.bg) and !colour_default(tc_bg)) {
                tty_write(tty, "\x1b[49m");
                tty.bg = gc.bg;
            }
        }
    }

    // Set the foreground colour.
    if (!colour_default(gc.fg) and gc.fg != tty.fg)
        tty_colours_fg(tty, gc);

    // Set the background colour. Must come after fg because tty_colours_fg can
    // call tty_reset.
    if (!colour_default(gc.bg) and gc.bg != tty.bg)
        tty_colours_bg(tty, gc);

    // Set the underline colour.
    if (gc.us != tty.us)
        tty_colours_us(tty, gc);
}

/// Set foreground colour on the terminal.
/// Ported from tmux tty_colours_fg().
pub fn tty_colours_fg(tty: *T.Tty, gc: *const T.GridCell) void {
    // If current is aixterm bright and new is not, reset (some terminals don't
    // clear bright correctly).
    if (tty.fg >= 90 and tty.fg <= 97 and (gc.fg < 90 or gc.fg > 97))
        tty_reset(tty);

    // Is this a 24-bit or 256-colour colour?
    if (gc.fg & T.COLOUR_FLAG_RGB != 0 or gc.fg & T.COLOUR_FLAG_256 != 0) {
        if (tty_try_colour(tty, gc.fg, "38") == 0) {
            tty.fg = gc.fg;
            return;
        }
        return;
    }

    // Is this an aixterm bright colour?
    if (gc.fg >= 90 and gc.fg <= 97) {
        if (tty_term.hasCapability(tty, "setaf")) {
            tty_putcode_i(tty, "setaf", @intCast(gc.fg - 90 + 8));
        } else {
            // Fallback SGR.
            const s = std.fmt.allocPrint(xm.allocator, "\x1b[{d}m", .{gc.fg}) catch unreachable;
            defer xm.allocator.free(s);
            tty_write(tty, s);
        }
        tty.fg = gc.fg;
        return;
    }

    // Otherwise set the foreground colour.
    tty_putcode_i(tty, "setaf", @intCast(gc.fg));
    tty.fg = gc.fg;
}

/// Set background colour on the terminal.
/// Ported from tmux tty_colours_bg().
pub fn tty_colours_bg(tty: *T.Tty, gc: *const T.GridCell) void {
    // Is this a 24-bit or 256-colour colour?
    if (gc.bg & T.COLOUR_FLAG_RGB != 0 or gc.bg & T.COLOUR_FLAG_256 != 0) {
        if (tty_try_colour(tty, gc.bg, "48") == 0) {
            tty.bg = gc.bg;
            return;
        }
        return;
    }

    // Is this an aixterm bright colour?
    if (gc.bg >= 90 and gc.bg <= 97) {
        if (tty_term.hasCapability(tty, "setab")) {
            tty_putcode_i(tty, "setab", @intCast(gc.bg - 90 + 8));
        } else {
            // Fallback SGR.
            const s = std.fmt.allocPrint(xm.allocator, "\x1b[{d}m", .{gc.bg + 10}) catch unreachable;
            defer xm.allocator.free(s);
            tty_write(tty, s);
        }
        tty.bg = gc.bg;
        return;
    }

    // Otherwise set the background colour.
    tty_putcode_i(tty, "setab", @intCast(gc.bg));
    tty.bg = gc.bg;
}

/// Set underline colour on the terminal.
/// Ported from tmux tty_colours_us().
pub fn tty_colours_us(tty: *T.Tty, gc: *const T.GridCell) void {
    // Clear underline colour.
    if (colour_default(gc.us)) {
        if (tty_term.stringCapability(tty, "ol")) |ol| {
            if (ol.len > 0) tty_write(tty, ol);
        }
        tty.us = gc.us;
        return;
    }

    // If not RGB, use Setulc1 if it exists.
    if (gc.us & T.COLOUR_FLAG_RGB == 0) {
        var c: i32 = gc.us;
        if ((c & T.COLOUR_FLAG_256) == 0 and c >= 90 and c <= 97)
            c -= 82;
        tty_putcode_i(tty, "Setulc1", @intCast(c & ~@as(i32, T.COLOUR_FLAG_256)));
        tty.us = gc.us;
        return;
    }

    // Setulc / setal use ncurses one-argument "direct colour" format.
    const rgb = colour_split_rgb(gc.us);
    const c: u32 = 65536 * @as(u32, rgb.r) + 256 * @as(u32, rgb.g) + @as(u32, rgb.b);

    if (tty_term.stringCapability(tty, "Setulc")) |setulc| {
        if (setulc.len > 0) {
            tty_putcode_i(tty, "Setulc", c);
            tty.us = gc.us;
            return;
        }
    }
    if (tty_term.hasCapability(tty, "RGB") and tty_term.stringCapability(tty, "setal")) |setal| {
        if (setal.len > 0) {
            tty_putcode_i(tty, "setal", c);
            tty.us = gc.us;
            return;
        }
    }
}

/// Check if foreground colour needs updating (translation/downsampling).
/// Ported from tmux tty_check_fg().
pub fn tty_check_fg(tty: *T.Tty, palette: ?*T.ColourPalette, gc: *T.GridCell) void {
    var c: i32 = gc.fg;

    // Perform palette substitution.
    if (gc.flags & T.GRID_FLAG_NOPALETTE == 0) {
        c = gc.fg;
        if (c < 8 and gc.attr & T.GRID_ATTR_BRIGHT != 0 and !tty_term.hasCapability(tty, "Nobr"))
            c += 90;
        const subst = colour_palette_get(palette, c);
        if (subst != -1) gc.fg = subst;
    }

    // Is this a 24-bit colour?
    if (gc.fg & T.COLOUR_FLAG_RGB != 0) {
        // Not a 24-bit terminal? Translate to 256-colour palette.
        if (!tty_term.hasCapability(tty, "RGB")) {
            const rgb = colour_split_rgb(gc.fg);
            gc.fg = colour_find_rgb(rgb.r, rgb.g, rgb.b);
        }
    }

    // How many colours does this terminal have?
    const colours: i32 = if (tty_term.hasCapability(tty, "RGB"))
        256
    else blk: {
        if (tty_term.numberCapability(tty, "colors")) |n| break :blk n;
        break :blk 8;
    };

    // Is this a 256-colour colour?
    if (gc.fg & T.COLOUR_FLAG_256 != 0) {
        if (colours >= 256) return;
        gc.fg = colour_256_to_16(gc.fg);
        if (gc.fg & 8 == 0) return;
        gc.fg &= 7;
        if (colours >= 16) {
            gc.fg += 90;
        } else {
            // Avoid black-on-black or white-on-white.
            if (gc.fg == 0 and gc.bg == 0)
                gc.fg = 7
            else if (gc.fg == 7 and gc.bg == 7)
                gc.fg = 0;
        }
        return;
    }

    // Is this an aixterm colour?
    if (gc.fg >= 90 and gc.fg <= 97 and colours < 16) {
        gc.fg -= 90;
        gc.attr |= T.GRID_ATTR_BRIGHT;
    }
}

/// Check if background colour needs updating (translation/downsampling).
/// Ported from tmux tty_check_bg().
pub fn tty_check_bg(tty: *T.Tty, palette: ?*T.ColourPalette, gc: *T.GridCell) void {
    // Perform palette substitution.
    if (gc.flags & T.GRID_FLAG_NOPALETTE == 0) {
        const subst = colour_palette_get(palette, gc.bg);
        if (subst != -1) gc.bg = subst;
    }

    // Is this a 24-bit colour?
    if (gc.bg & T.COLOUR_FLAG_RGB != 0) {
        if (!tty_term.hasCapability(tty, "RGB")) {
            const rgb = colour_split_rgb(gc.bg);
            gc.bg = colour_find_rgb(rgb.r, rgb.g, rgb.b);
        }
    }

    // How many colours does this terminal have?
    const colours: i32 = if (tty_term.hasCapability(tty, "RGB"))
        256
    else blk: {
        if (tty_term.numberCapability(tty, "colors")) |n| break :blk n;
        break :blk 8;
    };

    // Is this a 256-colour colour?
    if (gc.bg & T.COLOUR_FLAG_256 != 0) {
        if (colours >= 256) return;
        gc.bg = colour_256_to_16(gc.bg);
        if (gc.bg & 8 == 0) return;
        gc.bg &= 7;
        if (colours >= 16)
            gc.bg += 90;
        return;
    }

    // Is this an aixterm colour?
    if (gc.bg >= 90 and gc.bg <= 97 and colours < 16)
        gc.bg -= 90;
}

/// Check if underline colour needs updating (translation).
/// Ported from tmux tty_check_us().
pub fn tty_check_us(tty: *T.Tty, palette: ?*T.ColourPalette, gc: *T.GridCell) void {
    // Perform palette substitution.
    if (gc.flags & T.GRID_FLAG_NOPALETTE == 0) {
        const subst = colour_palette_get(palette, gc.us);
        if (subst != -1) gc.us = subst;
    }

    // Convert underscore colour if only RGB can be supported.
    if (!tty_term.hasCapability(tty, "Setulc1")) {
        const c = colour_force_rgb(gc.us);
        if (c == -1)
            gc.us = 8
        else
            gc.us = c;
    }
}

/// Try to apply a colour using terminfo capabilities.
/// Ported from tmux tty_try_colour().
/// Returns 0 on success, -1 if not handled.
pub fn tty_try_colour(tty: *T.Tty, colour: i32, type_str: []const u8) i32 {
    if (colour & T.COLOUR_FLAG_256 != 0) {
        if (type_str[0] == '3' and tty_term.stringCapability(tty, "setaf")) |setaf| {
            if (setaf.len > 0) {
                tty_putcode_i(tty, "setaf", @intCast(colour & 0xff));
                return 0;
            }
        }
        if (tty_term.stringCapability(tty, "setab")) |setab| {
            if (setab.len > 0) {
                tty_putcode_i(tty, "setab", @intCast(colour & 0xff));
                return 0;
            }
        }
        return -1;
    }

    if (colour & T.COLOUR_FLAG_RGB != 0) {
        const rgb = colour_split_rgb(colour);
        if (type_str[0] == '3') {
            if (tty_term.stringCapability(tty, "setrgbf")) |setrgbf| {
                if (setrgbf.len > 0) {
                    tty_putcode_iii(tty, "setrgbf", rgb.r, rgb.g, rgb.b);
                    return 0;
                }
            }
        }
        if (tty_term.stringCapability(tty, "setrgbb")) |setrgbb| {
            if (setrgbb.len > 0) {
                tty_putcode_iii(tty, "setrgbb", rgb.r, rgb.g, rgb.b);
                return 0;
            }
        }
        return -1;
    }

    return -1;
}

/// Set the cursor colour via OSC 12.
/// Ported from tmux tty_force_cursor_colour().
pub fn tty_force_cursor_colour(tty: *T.Tty, c: i32) void {
    var colour = c;
    if (colour != -1)
        colour = colour_force_rgb(colour);
    if (colour == tty.ccolour) return;

    if (colour == -1) {
        // Reset cursor colour.
        if (tty_term.stringCapability(tty, "Cr")) |cr| {
            if (cr.len > 0) tty_write(tty, cr);
        }
    } else {
        const rgb = colour_split_rgb(colour);
        const s = std.fmt.allocPrint(xm.allocator, "rgb:{x:0>2}/{x:0>2}/{x:0>2}", .{ rgb.r, rgb.g, rgb.b }) catch unreachable;
        defer xm.allocator.free(s);
        // Use Cs capability (cursor colour set with string parameter).
        if (tty_term.stringCapability(tty, "Cs")) |cs| {
            if (cs.len > 0) {
                // Replace %s or %p1%s in the capability with the colour string.
                const expanded = expand_tparm_s(cs, s) catch return;
                defer xm.allocator.free(expanded);
                tty_write(tty, expanded);
            }
        } else {
            // Fallback: OSC 12.
            const seq = std.fmt.allocPrint(xm.allocator, "\x1b]12;rgb:{x:0>2}/{x:0>2}/{x:0>2}\x07", .{ rgb.r, rgb.g, rgb.b }) catch unreachable;
            defer xm.allocator.free(seq);
            tty_write(tty, seq);
        }
    }
    tty.ccolour = colour;
}

/// Emit a terminfo string capability with three integer parameters.
fn tty_putcode_iii(tty: *T.Tty, name: []const u8, a: u32, b: u32, c: u32) void {
    const s = tty_term.stringCapability(tty, name) orelse return;
    if (s.len == 0) return;
    const expanded = expand_tparm_3(s, a, b, c) catch return;
    defer xm.allocator.free(expanded);
    tty_write(tty, expanded);
}

/// Expand a terminfo string with three integer parameters.
fn expand_tparm_3(template: []const u8, a: u32, b: u32, c: u32) ![]u8 {
    var pa = a;
    var pb = b;
    var pc = c;
    return expand_tparm_impl3(template, &pa, &pb, &pc);
}

/// Core terminfo parameter expansion for up to 3 integer parameters.
fn expand_tparm_impl3(template: []const u8, pa: *u32, pb: *u32, pc: *u32) ![]u8 {
    var out: std.ArrayList(u8) = .{};
    errdefer out.deinit(xm.allocator);

    var idx: usize = 0;
    while (idx < template.len) {
        if (template[idx] != '%') {
            try out.append(xm.allocator, template[idx]);
            idx += 1;
            continue;
        }
        idx += 1;
        if (idx >= template.len) break;
        switch (template[idx]) {
            '%' => {
                try out.append(xm.allocator, '%');
                idx += 1;
            },
            'i' => {
                pa.* += 1;
                pb.* += 1;
                pc.* += 1;
                idx += 1;
            },
            'p' => {
                idx += 1;
                if (idx >= template.len) break;
                const param_num = template[idx];
                idx += 1;
                // Skip format specifier (e.g. %d)
                if (idx < template.len and template[idx] == 'd') {
                    idx += 1;
                }
                const val: u32 = switch (param_num) {
                    '1' => pa.*,
                    '2' => pb.*,
                    '3' => pc.*,
                    else => 0,
                };
                const digits = std.fmt.allocPrint(xm.allocator, "{d}", .{val}) catch unreachable;
                defer xm.allocator.free(digits);
                try out.appendSlice(xm.allocator, digits);
            },
            else => {
                idx += 1;
            },
        }
    }

    return out.toOwnedSlice(xm.allocator);
}

/// Expand a terminfo string with a string parameter (%s substitution).
fn expand_tparm_s(template: []const u8, str_param: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .{};
    errdefer out.deinit(xm.allocator);

    var idx: usize = 0;
    while (idx < template.len) {
        if (template[idx] != '%') {
            try out.append(xm.allocator, template[idx]);
            idx += 1;
            continue;
        }
        idx += 1;
        if (idx >= template.len) break;
        switch (template[idx]) {
            '%' => {
                try out.append(xm.allocator, '%');
                idx += 1;
            },
            's' => {
                try out.appendSlice(xm.allocator, str_param);
                idx += 1;
            },
            'p' => {
                idx += 1;
                if (idx >= template.len) break;
                idx += 1; // skip param number
                // If followed by %s, insert the string parameter.
                if (idx + 1 < template.len and template[idx] == '%' and template[idx + 1] == 's') {
                    try out.appendSlice(xm.allocator, str_param);
                    idx += 2;
                }
            },
            else => {
                idx += 1;
            },
        }
    }

    return out.toOwnedSlice(xm.allocator);
}

pub fn tty_set_title(tty: *T.Tty, title: []const u8) void {
    if (title.len == 0) return;
    if ((tty.flags & @as(i32, @intCast(T.TTY_STARTED))) == 0) return;
    if (!tty_features.supportsTty(tty, .title)) return;

    const sequence = if (tty_term.stringCapability(tty, "tsl")) |tsl| blk: {
        const fsl = tty_term.stringCapability(tty, "fsl") orelse break :blk null;
        break :blk std.fmt.allocPrint(xm.allocator, "{s}{s}{s}", .{ tsl, title, fsl }) catch return;
    } else std.fmt.allocPrint(xm.allocator, "\x1b]2;{s}\x07", .{title}) catch return;
    if (sequence == null) return;
    defer xm.allocator.free(sequence.?);
    tty_write(tty, sequence.?);
}

pub fn tty_clipboard_query(tty: *T.Tty) void {
    if ((tty.flags & @as(i32, @intCast(T.TTY_STARTED))) == 0) return;
    if ((tty.flags & @as(i32, @intCast(T.TTY_OSC52QUERY))) != 0) return;

    const ms = tty_term.stringCapability(tty, "Ms") orelse return;
    const sequence = formatClipboardCapability(ms, "", "?") orelse return;
    defer xm.allocator.free(sequence);

    tty_write(tty, sequence);
    armClipboardTimer(tty);
}

pub fn tty_finish_clipboard_query(tty: *T.Tty) void {
    cancelClipboardQuery(tty);
}

pub fn tty_append_mode_update(tty: *T.Tty, mode: i32, out: *std.ArrayList(u8)) !void {
    var actual = mode;
    if ((tty.flags & @as(i32, @intCast(T.TTY_NOCURSOR))) != 0)
        actual &= ~@as(i32, T.MODE_CURSOR);

    const supports_mouse = tty_features.supportsTty(tty, .mouse);
    const supports_bpaste = tty_features.supportsTty(tty, .bpaste);
    const supports_focus = tty_features.supportsTty(tty, .focus);
    if (!supports_mouse)
        actual &= ~@as(i32, T.ALL_MOUSE_MODES);
    if (!supports_bpaste)
        actual &= ~@as(i32, T.MODE_BRACKETPASTE);
    if (!supports_focus)
        actual &= ~@as(i32, T.MODE_FOCUSON);

    const changed = actual ^ tty.mode;
    if ((changed & T.ALL_MOUSE_MODES) != 0 and (supports_mouse or (tty.mode & T.ALL_MOUSE_MODES) != 0)) {
        try out.appendSlice(xm.allocator, "\x1b[?1006l\x1b[?1005l\x1b[?1000l\x1b[?1002l\x1b[?1003l");
        if (supports_mouse and (actual & T.ALL_MOUSE_MODES) != 0)
            try out.appendSlice(xm.allocator, "\x1b[?1006h");
        if (supports_mouse and (actual & T.MODE_MOUSE_ALL) != 0)
            try out.appendSlice(xm.allocator, "\x1b[?1000h\x1b[?1002h\x1b[?1003h")
        else if (supports_mouse and (actual & T.MODE_MOUSE_BUTTON) != 0)
            try out.appendSlice(xm.allocator, "\x1b[?1000h\x1b[?1002h")
        else if (supports_mouse and (actual & T.MODE_MOUSE_STANDARD) != 0)
            try out.appendSlice(xm.allocator, "\x1b[?1000h");
    }
    if ((changed & T.MODE_BRACKETPASTE) != 0 and (supports_bpaste or (tty.mode & T.MODE_BRACKETPASTE) != 0)) {
        try appendCapabilityToggle(
            tty,
            out,
            "Enbp",
            "Dsbp",
            "\x1b[?2004h",
            "\x1b[?2004l",
            (actual & T.MODE_BRACKETPASTE) != 0,
        );
    }
    if ((changed & T.MODE_FOCUSON) != 0 and (supports_focus or (tty.mode & T.MODE_FOCUSON) != 0)) {
        try appendCapabilityToggle(
            tty,
            out,
            "Enfcs",
            "Dsfcs",
            "\x1b[?1004h",
            "\x1b[?1004l",
            (actual & T.MODE_FOCUSON) != 0,
        );
    }

    tty.mode = actual;
}

fn appendCapabilityToggle(
    tty: *const T.Tty,
    out: *std.ArrayList(u8),
    enable_cap: []const u8,
    disable_cap: []const u8,
    fallback_enable: []const u8,
    fallback_disable: []const u8,
    enabled: bool,
) !void {
    const cap_name = if (enabled) enable_cap else disable_cap;
    const fallback = if (enabled) fallback_enable else fallback_disable;
    const sequence = tty_term.stringCapability(tty, cap_name) orelse fallback;
    try out.appendSlice(xm.allocator, sequence);
}

fn formatClipboardCapability(template: []const u8, clip: []const u8, value: []const u8) ?[]u8 {
    var out: std.ArrayList(u8) = .{};
    errdefer out.deinit(xm.allocator);

    var idx: usize = 0;
    while (idx < template.len) {
        if (std.mem.startsWith(u8, template[idx..], "%p1%s")) {
            out.appendSlice(xm.allocator, clip) catch return null;
            idx += "%p1%s".len;
            continue;
        }
        if (std.mem.startsWith(u8, template[idx..], "%p2%s")) {
            out.appendSlice(xm.allocator, value) catch return null;
            idx += "%p2%s".len;
            continue;
        }
        if (std.mem.startsWith(u8, template[idx..], "%%")) {
            out.append(xm.allocator, '%') catch return null;
            idx += 2;
            continue;
        }
        if (template[idx] == '%') return null;

        out.append(xm.allocator, template[idx]) catch return null;
        idx += 1;
    }

    return out.toOwnedSlice(xm.allocator) catch null;
}

/// Arm the start timer that fires TTY_QUERY_TIMEOUT seconds later and calls
/// tty_send_requests.  Mirrors tmux tty_start_start_timer.
fn tty_start_start_timer(tty: *T.Tty) void {
    const base = proc_mod.libevent orelse return;
    if (tty.start_timer == null) {
        tty.start_timer = c_zig.libevent.event_new(
            base,
            -1,
            @intCast(c_zig.libevent.EV_TIMEOUT),
            tty_start_timer_fire,
            tty,
        );
    }
    if (tty.start_timer) |ev| {
        var tv = std.posix.timeval{ .sec = T.TTY_QUERY_TIMEOUT, .usec = 0 };
        _ = c_zig.libevent.event_del(ev);
        _ = c_zig.libevent.event_add(ev, @ptrCast(&tv));
    }
}

fn cancelStartTimer(tty: *T.Tty) void {
    if (tty.start_timer) |ev| _ = c_zig.libevent.event_del(ev);
}

fn freeStartTimer(tty: *T.Tty) void {
    cancelStartTimer(tty);
    if (tty.start_timer) |ev| {
        c_zig.libevent.event_free(ev);
        tty.start_timer = null;
    }
}

export fn tty_start_timer_fire(_fd: c_int, _events: c_short, arg: ?*anyopaque) void {
    _ = _fd;
    _ = _events;
    const tty: *T.Tty = @ptrCast(@alignCast(arg orelse return));
    tty_send_requests(tty);
}

/// Write a Zig slice to the tty (helper used by tty_send_requests and similar).
fn tty_puts_str(tty: *T.Tty, s: []const u8) void {
    tty_write(tty, s);
}

fn armClipboardTimer(tty: *T.Tty) void {
    const base = proc_mod.libevent orelse return;

    if (tty.clipboard_timer == null) {
        tty.clipboard_timer = c_zig.libevent.event_new(
            base,
            -1,
            @intCast(c_zig.libevent.EV_TIMEOUT),
            tty_clipboard_query_callback,
            tty,
        );
    }
    if (tty.clipboard_timer) |ev| {
        tty.flags |= @as(i32, @intCast(T.TTY_OSC52QUERY));
        var tv = std.posix.timeval{ .sec = 5, .usec = 0 };
        _ = c_zig.libevent.event_add(ev, @ptrCast(&tv));
    }
}

fn cancelClipboardQuery(tty: *T.Tty) void {
    if (tty.clipboard_timer) |ev| _ = c_zig.libevent.event_del(ev);
    tty.flags &= ~@as(i32, @intCast(T.TTY_OSC52QUERY));
}

fn freeClipboardTimer(tty: *T.Tty) void {
    cancelClipboardQuery(tty);
    if (tty.clipboard_timer) |ev| {
        c_zig.libevent.event_free(ev);
        tty.clipboard_timer = null;
    }
}

export fn tty_clipboard_query_callback(_fd: c_int, _events: c_short, arg: ?*anyopaque) void {
    _ = _fd;
    _ = _events;
    const tty: *T.Tty = @ptrCast(@alignCast(arg orelse return));
    cancelClipboardQuery(tty);
}

export fn tty_clipboard_query_timeout_cb(_fd: c_int, _events: c_short, arg: ?*anyopaque) void {
    tty_clipboard_query_callback(_fd, _events, arg);
}

fn tty_write(tty: *T.Tty, payload: []const u8) void {
    const peer = tty.client.peer orelse return;
    if ((tty.client.flags & T.CLIENT_CONTROL) != 0) return;

    _ = file_mod.sendPeerStream(peer, 1, payload);
}

// ── C-name stubs: tmux screen-write / overlay API ─────────────────────────
// zmux redraws via tty-draw.zig; these symbols match tmux names for porting
// and cross-reference. `tty_ctx` is represented as opaque until a full port
// wires screen-write → tty.

/// Stub stand-in for tmux `visible_range` / `visible_ranges`.
pub const VisibleRange = struct {
    px: u32 = 0,
    nx: u32 = 0,
};

pub const VisibleRanges = struct {
    ranges: [1]VisibleRange = .{.{ .px = 0, .nx = 0 }},
    used: u32 = 0,
};

threadlocal var tty_stub_overlay_storage: VisibleRanges = .{};

/// tmux `tty_draw_line` — implementation lives in tty-draw.zig (stub body there).
pub const tty_draw_line = tty_draw_mod.tty_draw_line;

// ── C-name stubs: I/O, timers, offsets, pane clamp (tmux tty.c parity) ───────


/// Libevent read callback for the client tty fd.
/// Reads available bytes into the tty input buffer, then dispatches all
/// complete keys via tty_keys_next (mirrors tmux tty_read_callback).
export fn tty_read_callback(_fd: c_int, _events: c_short, _arg: ?*anyopaque) void {
    _ = _events;
    const tty: *T.Tty = @ptrCast(@alignCast(_arg orelse return));
    const c = tty.client;
    const fd = if (_fd >= 0) _fd else c.fd;
    if (fd < 0) return;

    var tmp: [4096]u8 = undefined;
    const nread = std.posix.read(@intCast(fd), &tmp) catch |err| {
        log.log_debug("tty read error: {s}", .{@errorName(err)});
        return;
    };
    if (nread == 0) {
        log.log_debug("tty read: closed", .{});
        return;
    }

    tty.in_buf.appendSlice(xm.allocator, tmp[0..nread]) catch return;

    while (tty_keys_next(tty)) {}
}

/// Decode and dispatch the next key from the tty input buffer.
/// Returns true if a key was consumed (caller should loop), false if the
/// buffer is empty or contains only a partial sequence.
/// Mirrors tmux tty_keys_next (tty-keys.c:732).
pub fn tty_keys_next(tty: *T.Tty) bool {
    return tty_keys_next_inner(tty, false);
}

fn tty_keys_next_inner(tty: *T.Tty, expired: bool) bool {
    const cl = tty.client;
    const buf = tty.in_buf.items;
    if (buf.len == 0) return false;

    var size: usize = 0;
    var event: T.key_event = .{};

    // ── Response parsers (consume bytes without generating key events) ──

    // 1. Clipboard response (OSC 52).
    {
        var clip: u8 = 0;
        var clip_data: ?[]u8 = null;
        switch (tty_keys_mod.tty_keys_clipboard(buf, &size, &clip, &clip_data)) {
            .match => {
                if (clip_data) |data| {
                    // If we queried the clipboard, create a paste buffer.
                    if (tty.flags & @as(i32, @intCast(T.TTY_OSC52QUERY)) != 0) {
                        paste_mod.paste_add(null, data);
                        tty.flags &= ~@as(i32, @intCast(T.TTY_OSC52QUERY));
                    } else {
                        xm.allocator.free(data);
                    }
                }
                drainInBuf(tty, size);
                tty_keys_cancel_timer(tty);
                return true;
            },
            .partial => return handle_partial(tty, cl),
            .no_match, .discard => {},
        }
    }

    // 2. Primary device attributes (DA1): \033[?...c
    {
        var da_params: [16]u32 = undefined;
        var n_params: usize = 0;
        const have_da = (tty.flags & @as(i32, @intCast(T.TTY_HAVEDA))) != 0;
        switch (tty_keys_mod.tty_keys_device_attributes(buf, &size, have_da, &da_params, &n_params)) {
            .match => {
                tty.flags |= @as(i32, @intCast(T.TTY_HAVEDA));
                // Parse DA1 feature codes.
                for (da_params[0..n_params]) |param| {
                    switch (param) {
                        4 => tty_features.tty_add_features(&cl.term_features, "sixel", ","),
                        69 => tty_features.tty_add_features(&cl.term_features, "margins", ","),
                        28 => tty_features.tty_add_features(&cl.term_features, "rectfill", ","),
                        else => {},
                    }
                }
                tty_update_features(tty);
                drainInBuf(tty, size);
                tty_keys_cancel_timer(tty);
                return true;
            },
            .partial => return handle_partial(tty, cl),
            .no_match, .discard => {},
        }
    }

    // 3. Secondary device attributes (DA2): \033[>...c
    {
        var da2_params: [16]u32 = undefined;
        var n_params: usize = 0;
        const have_da2 = (tty.flags & @as(i32, @intCast(T.TTY_HAVEDA2))) != 0;
        switch (tty_keys_mod.tty_keys_device_attributes2(buf, &size, have_da2, &da2_params, &n_params)) {
            .match => {
                tty.flags |= @as(i32, @intCast(T.TTY_HAVEDA2));
                // DA2 first param identifies terminal type.
                if (n_params >= 2) {
                    const term_type = da2_params[0];
                    const version = da2_params[1];
                    switch (term_type) {
                        77 => tty_features.defaultFeatures(&cl.term_features, "mintty", version),
                        // tmux identifies itself in DA2
                        else => {},
                    }
                }
                tty_update_features(tty);
                drainInBuf(tty, size);
                tty_keys_cancel_timer(tty);
                return true;
            },
            .partial => return handle_partial(tty, cl),
            .no_match, .discard => {},
        }
    }

    // 4. Extended device attributes (XDA/XTVERSION): \033P>|...\033\\
    {
        var xda_tmp: [256]u8 = undefined;
        const have_xda = (tty.flags & @as(i32, @intCast(T.TTY_HAVEXDA))) != 0;
        switch (tty_keys_mod.tty_keys_extended_device_attributes(buf, &size, have_xda, &xda_tmp)) {
            .match => {
                tty.flags |= @as(i32, @intCast(T.TTY_HAVEXDA));
                // Parse terminal identity from XDA string.
                const xda_str = std.mem.sliceTo(&xda_tmp, 0);
                if (xda_str.len > 0) {
                    // Match known terminal names.
                    inline for (.{ "iTerm2", "foot", "tmux", "mintty", "XTerm" }) |name| {
                        if (std.mem.indexOf(u8, xda_str, name) != null) {
                            tty_features.defaultFeatures(&cl.term_features, name, 0);
                        }
                    }
                }
                tty_update_features(tty);
                drainInBuf(tty, size);
                tty_keys_cancel_timer(tty);
                return true;
            },
            .partial => return handle_partial(tty, cl),
            .no_match, .discard => {},
        }
    }

    // 5. Foreground/background colour responses (OSC 10/11).
    {
        var colour_tmp: [128]u8 = undefined;
        // Check OSC 10 (foreground).
        switch (tty_keys_mod.tty_keys_colours(buf, &size, true, &colour_tmp)) {
            .match => {
                const colour_str = std.mem.sliceTo(&colour_tmp, 0);
                if (colour_str.len > 0) {
                    tty.fg = colour_mod.colour_parseX11(colour_str);
                }
                tty.flags &= ~@as(i32, @intCast(T.TTY_WAITFG));
                if (cl.session) |s| session_mod.session_theme_changed(s);
                drainInBuf(tty, size);
                tty_keys_cancel_timer(tty);
                return true;
            },
            .partial => {
                // Even on partial colour response, trigger theme change
                // (tmux does this — see tty-keys.c:804).
                if (cl.session) |s| session_mod.session_theme_changed(s);
                return handle_partial(tty, cl);
            },
            .no_match, .discard => {},
        }
        // Check OSC 11 (background).
        switch (tty_keys_mod.tty_keys_colours(buf, &size, false, &colour_tmp)) {
            .match => {
                const colour_str = std.mem.sliceTo(&colour_tmp, 0);
                if (colour_str.len > 0) {
                    tty.bg = colour_mod.colour_parseX11(colour_str);
                }
                tty.flags &= ~@as(i32, @intCast(T.TTY_WAITBG));
                if (cl.session) |s| session_mod.session_theme_changed(s);
                drainInBuf(tty, size);
                tty_keys_cancel_timer(tty);
                return true;
            },
            .partial => {
                if (cl.session) |s| session_mod.session_theme_changed(s);
                return handle_partial(tty, cl);
            },
            .no_match, .discard => {},
        }
    }

    // 6. Palette colour response (OSC 4).
    {
        var palette_tmp: [128]u8 = undefined;
        switch (tty_keys_mod.tty_keys_palette(buf, &size, &palette_tmp)) {
            .match => {
                drainInBuf(tty, size);
                tty_keys_cancel_timer(tty);
                return true;
            },
            .partial => return handle_partial(tty, cl),
            .no_match, .discard => {},
        }
    }

    // 7. Mouse events.
    {
        const mr = tty_keys_mod.tty_keys_mouse(
            buf,
            &size,
            &tty.mouse_last_x,
            &tty.mouse_last_y,
            &tty.mouse_last_b,
        );
        switch (mr.result) {
            .match => {
                event.key = T.KEYC_MOUSE;
                event.m = mr.m;
                drainInBuf(tty, size);
                tty_keys_cancel_timer(tty);
                dispatchKeyEvent(cl, &event);
                return true;
            },
            .discard => {
                // Valid mouse event we don't care about.
                drainInBuf(tty, size);
                tty_keys_cancel_timer(tty);
                return true;
            },
            .partial => return handle_partial(tty, cl),
            .no_match => {},
        }
    }

    // 8. Extended key sequences (CSI u / modifyOtherKeys).
    {
        var ext_key: T.key_code = T.KEYC_UNKNOWN;
        switch (tty_keys_mod.tty_keys_extended_key(buf, &size, &ext_key, null)) {
            .match => {
                event.key = ext_key;
                drainInBuf(tty, size);
                tty_keys_cancel_timer(tty);
                dispatchKeyEvent(cl, &event);
                return true;
            },
            .partial => return handle_partial(tty, cl),
            .no_match, .discard => {},
        }
    }

    // 9. Window size report (CSI 8;...t / CSI 4;...t).
    if (tty_keys_mod.tty_keys_winsz(buf, &size)) |winsz| {
        switch (winsz.kind) {
            .chars => tty_set_size(tty, winsz.v1, winsz.v2, 0, 0),
            .pixels => {
                // Calculate character dimensions from pixels.
                if (tty.sx > 0 and tty.sy > 0) {
                    const cw = winsz.v1 / tty.sx;
                    const ch = winsz.v2 / tty.sy;
                    if (cw > 0 and ch > 0)
                        tty_set_size(tty, tty.sx, tty.sy, cw, ch);
                }
                tty_invalidate(tty);
            },
        }
        drainInBuf(tty, size);
        tty_keys_cancel_timer(tty);
        return true;
    }

    // ── Regular key decoding (fallback to input-keys.zig) ──

    // 10. Try the existing input-keys decoder for regular keystrokes.
    const consumed = input_keys.input_key_get_client(cl, buf, &event) orelse {
        if (expired) {
            // Timer expired and we still have partial data -- treat the
            // first byte(s) as a literal key (mirrors tmux fallthrough in
            // tty_keys_next after the timer fires).
            var key: T.key_code = @intCast(buf[0]);
            var key_size: usize = 1;
            if (buf[0] == 0x1b and buf.len >= 2) {
                key = @as(T.key_code, @intCast(buf[1])) | T.KEYC_META;
                key_size = 2;
            }
            event.key = key;
            event.len = @min(key_size, event.data.len);
            @memcpy(event.data[0..event.len], buf[0..event.len]);
            drainInBuf(tty, key_size);
            tty_keys_cancel_timer(tty);
            dispatchKeyEvent(cl, &event);
            return true;
        }
        // Partial sequence -- set escape timer if not already running.
        return handle_partial(tty, cl);
    };

    drainInBuf(tty, consumed);
    tty_keys_cancel_timer(tty);
    dispatchKeyEvent(cl, &event);
    return true;
}

/// Handle a partial key sequence: arm the escape timer if not already running.
fn handle_partial(tty: *T.Tty, _: *T.Client) bool {
    if (tty.flags & @as(i32, @intCast(T.TTY_TIMER)) == 0) {
        tty_keys_set_timer(tty);
    }
    return false;
}

/// Remove `n` bytes from the front of the tty input buffer.
fn drainInBuf(tty: *T.Tty, n: usize) void {
    if (n == 0) return;
    if (n >= tty.in_buf.items.len) {
        tty.in_buf.clearRetainingCapacity();
    } else {
        const remaining = tty.in_buf.items.len - n;
        std.mem.copyForwards(u8, tty.in_buf.items[0..remaining], tty.in_buf.items[n..]);
        tty.in_buf.shrinkRetainingCapacity(remaining);
    }
}

/// Handle focus events and fire the key through server_client_handle_key.
fn dispatchKeyEvent(c: *T.Client, event: *T.key_event) void {
    // Handle focus events.
    if (event.key == T.KEYC_FOCUS_OUT) {
        c.flags &= ~T.CLIENT_FOCUSED;
        if (c.session) |s| {
            if (s.curw) |wl| {
                win_mod.window_update_focus(wl.window);
            }
        }
        notify_mod.notify_client("client-focus-out", c);
    } else if (event.key == T.KEYC_FOCUS_IN) {
        c.flags |= T.CLIENT_FOCUSED;
        notify_mod.notify_client("client-focus-in", c);
        if (c.session) |s| {
            if (s.curw) |wl| {
                win_mod.window_update_focus(wl.window);
            }
        }
    }

    // Fire the key.
    if (event.key != T.KEYC_UNKNOWN) {
        _ = server_fn.server_client_handle_key(c, event);
    }
}

/// Set the escape-time timer for partial key sequences.
fn tty_keys_set_timer(tty: *T.Tty) void {
    const base = proc_mod.libevent orelse return;
    if (tty.key_timer == null) {
        tty.key_timer = c_zig.libevent.event_new(
            base,
            -1,
            @intCast(c_zig.libevent.EV_TIMEOUT),
            tty_keys_timer_callback,
            tty,
        );
    }
    if (tty.key_timer) |ev| {
        tty.flags |= @as(i32, @intCast(T.TTY_TIMER));
        // Default 500ms escape time.
        var tv = std.posix.timeval{ .sec = 0, .usec = 500000 };
        _ = c_zig.libevent.event_add(ev, @ptrCast(&tv));
    }
}

/// Cancel the escape-time timer.
fn tty_keys_cancel_timer(tty: *T.Tty) void {
    if (tty.key_timer) |ev| _ = c_zig.libevent.event_del(ev);
    tty.flags &= ~@as(i32, @intCast(T.TTY_TIMER));
}

/// Libevent callback fired when the escape-time timer expires.
/// Treats buffered partial data as complete key(s).
export fn tty_keys_timer_callback(_fd: c_int, _events: c_short, arg: ?*anyopaque) void {
    _ = _fd;
    _ = _events;
    const tty: *T.Tty = @ptrCast(@alignCast(arg orelse return));
    if (tty.flags & @as(i32, @intCast(T.TTY_TIMER)) != 0) {
        while (tty_keys_next_inner(tty, true)) {}
    }
}

/// Build the key lookup structures.  In zmux, input_key_get uses
/// compile-time tables so this is a no-op placeholder that matches the
/// tmux tty_keys_build call site.
pub fn tty_keys_build(_: *T.Tty) void {}

/// Free key lookup structures.  No-op in zmux (no runtime tree to free),
/// but releases the input buffer memory.
pub fn tty_keys_free(tty: *T.Tty) void {
    tty_keys_cancel_timer(tty);
    if (tty.key_timer) |ev| {
        c_zig.libevent.event_free(ev);
        tty.key_timer = null;
    }
    tty.in_buf.deinit(xm.allocator);
    tty.in_buf = .{};
}

export fn tty_timer_callback(_fd: c_int, _events: c_short, _arg: ?*anyopaque) void {
    _ = _fd;
    _ = _events;
    _ = _arg;
}

/// Port of tmux tty_block_maybe().
/// Throttles output when the output buffer exceeds TTY_BLOCK_START bytes.
/// Zmux uses synchronous imsg delivery instead of evbuffers, so
/// tty.pending_out is always 0; the block path is never taken in practice.
pub fn tty_block_maybe(tty: *T.Tty) i32 {
    const c = tty.client;
    const size = tty.pending_out;

    // TTY_BLOCK_START(tty) = 1 + sx*sy*8; TTY_BLOCK_STOP = 1 + sx*sy/8 (timer, not yet ported).
    const tty_block_start: usize = 1 + @as(usize, tty.sx) * @as(usize, tty.sy) * 8;

    if (size == 0)
        tty.flags &= ~@as(i32, @intCast(T.TTY_NOBLOCK))
    else if ((tty.flags & @as(i32, @intCast(T.TTY_NOBLOCK))) != 0)
        return 0;

    if (size < tty_block_start)
        return 0;

    if ((tty.flags & @as(i32, @intCast(T.TTY_BLOCK))) != 0)
        return 1;

    tty.flags |= @as(i32, @intCast(T.TTY_BLOCK));

    log.log_debug("{s}: can't keep up, {d} discarded", .{ c.name orelse "(unknown)", size });

    c.discarded += size;
    tty.pending_out = 0;

    return 1;
}

/// Libevent write-readiness callback for the tty fd.  Calls
/// tty_block_maybe to maintain flow-control bookkeeping.
export fn tty_write_callback(_fd: c_int, _events: c_short, _arg: ?*anyopaque) void {
    _ = _fd;
    _ = _events;
    const tty: *T.Tty = @ptrCast(@alignCast(_arg orelse return));
    _ = tty_block_maybe(tty);
}

// tty_start_timer_callback — replaced by tty_start_timer_fire (above).




pub fn tty_update_features(tty: *T.Tty) void {
    // Features might have changed since the first draw during attach.
    // For example, this happens when DA responses are received.
    server_fn.server_redraw_client(tty.client);
    tty_invalidate(tty);
}


pub fn tty_add(tty: *T.Tty, buf: [*]const u8, len: usize) void {
    if (len == 0) return;
    tty_write(tty, buf[0..len]);
}

pub fn tty_puts(tty: *T.Tty, s: [*:0]const u8) void {
    const n = std.mem.len(s);
    if (n == 0) return;
    tty_write(tty, s[0..n]);
}


pub fn tty_emulate_repeat(tty: *T.Tty, code: []const u8, code1: []const u8, n: u32) void {
    if (tty_term.hasCapability(tty, code)) {
        tty_putcode_i(tty, code, n);
    } else {
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            tty_putcode(tty, code1);
        }
    }
}

/// Port of tmux tty_window_bigger().
pub fn tty_window_bigger(tty: *T.Tty) i32 {
    const c = tty.client;
    const s = c.session orelse return 0;
    const curw = s.curw orelse return 0;
    const w = curw.window;
    const lines = resize_mod.status_line_size(c);
    return if (tty.sx < w.sx or tty.sy -| lines < w.sy) 1 else 0;
}

/// Port of tmux tty_window_offset().
/// Returns the cached viewport offset (populated by tty_update_client_offset).
pub fn tty_window_offset(tty: *T.Tty, ox: *u32, oy: *u32, sx: *u32, sy: *u32) i32 {
    ox.* = tty.oox;
    oy.* = tty.ooy;
    sx.* = tty.osx;
    sy.* = tty.osy;
    return tty.oflag;
}

/// Port of tmux tty_window_offset1() — computes the viewport for caching.
fn tty_window_offset1(tty: *T.Tty, ox: *u32, oy: *u32, sx: *u32, sy: *u32) i32 {
    const c = tty.client;
    const s = c.session orelse {
        ox.* = 0; oy.* = 0; sx.* = 0; sy.* = 0;
        return 0;
    };
    const curw = s.curw orelse {
        ox.* = 0; oy.* = 0; sx.* = 0; sy.* = 0;
        return 0;
    };
    const w = curw.window;
    const wp = server_client_mod.server_client_get_pane(c) orelse {
        ox.* = 0; oy.* = 0; sx.* = 0; sy.* = 0;
        return 0;
    };
    const lines = resize_mod.status_line_size(c);

    if (tty.sx >= w.sx and tty.sy -| lines >= w.sy) {
        ox.* = 0;
        oy.* = 0;
        sx.* = w.sx;
        sy.* = w.sy;
        c.pan_window = null;
        return 0;
    }

    sx.* = tty.sx;
    sy.* = tty.sy -| lines;

    if (c.pan_window == w) {
        if (sx.* >= w.sx)
            c.pan_ox = 0
        else if (c.pan_ox + sx.* > w.sx)
            c.pan_ox = w.sx - sx.*;
        ox.* = c.pan_ox;
        if (sy.* >= w.sy)
            c.pan_oy = 0
        else if (c.pan_oy + sy.* > w.sy)
            c.pan_oy = w.sy - sy.*;
        oy.* = c.pan_oy;
        return 1;
    }

    if ((wp.screen.mode & T.MODE_CURSOR) == 0) {
        ox.* = 0;
        oy.* = 0;
    } else {
        const cx = wp.xoff + wp.screen.cx;
        const cy = wp.yoff + wp.screen.cy;

        if (cx < sx.*)
            ox.* = 0
        else if (cx > w.sx -| sx.*)
            ox.* = w.sx -| sx.*
        else
            ox.* = cx -| sx.* / 2;

        if (cy < sy.*)
            oy.* = 0
        else if (cy > w.sy -| sy.*)
            oy.* = w.sy -| sy.*
        else
            oy.* = cy -| sy.* / 2;
    }

    c.pan_window = null;
    return 1;
}

/// Port of tmux tty_update_client_offset().
pub fn tty_update_client_offset(c: *T.Client) void {
    if ((c.flags & T.CLIENT_TERMINAL) == 0) return;

    var ox: u32 = 0;
    var oy: u32 = 0;
    var sx: u32 = 0;
    var sy: u32 = 0;
    c.tty.oflag = tty_window_offset1(&c.tty, &ox, &oy, &sx, &sy);
    if (ox == c.tty.oox and oy == c.tty.ooy and sx == c.tty.osx and sy == c.tty.osy)
        return;

    log.log_debug("tty_update_client_offset: {s} offset changed ({d},{d} {d}x{d} -> {d},{d} {d}x{d})", .{
        c.name orelse "(unknown)",
        c.tty.oox, c.tty.ooy, c.tty.osx, c.tty.osy,
        ox, oy, sx, sy,
    });

    c.tty.oox = ox;
    c.tty.ooy = oy;
    c.tty.osx = sx;
    c.tty.osy = sy;

    c.flags |= T.CLIENT_REDRAWWINDOW | T.CLIENT_REDRAWSTATUS;
}

/// Port of tmux tty_update_window_offset().
pub fn tty_update_window_offset(w: *T.Window) void {
    if (!@import("options.zig").options_ready) return;
    for (client_registry.clients.items) |c| {
        if (c.session) |s| {
            if (s.curw) |curw| {
                if (curw.window == w)
                    tty_update_client_offset(c);
            }
        }
    }
}

// tty_send_requests and tty_repeat_requests are defined above (line ~93).

pub fn tty_large_region(_: *T.Tty, ctx: *const T.TtyCtx) i32 {
    return if (ctx.orlower -| ctx.orupper >= ctx.sy / 2) @as(i32, 1) else @as(i32, 0);
}

pub fn tty_redraw_region(tty: *T.Tty, ctx: *const T.TtyCtx) void {
    if (tty_large_region(tty, ctx) != 0) {
        if (ctx.redraw_cb) |cb| cb(ctx);
        return;
    }
    var i: u32 = ctx.orupper;
    while (i <= ctx.orlower) : (i += 1) {
        tty_draw_pane(tty, ctx, i);
    }
}

pub fn tty_is_visible(_: *T.Tty, ctx: *const T.TtyCtx, px: u32, py: u32, nx: u32, ny: u32) i32 {
    const xoff = ctx.rxoff + px;
    const yoff = ctx.ryoff + py;

    if (ctx.bigger) {
        if (xoff + nx <= ctx.wox or xoff >= ctx.wox + ctx.wsx)
            return 0;
        if (yoff + ny <= ctx.woy or yoff >= ctx.woy + ctx.wsy)
            return 0;
    }
    return 1;
}

pub fn tty_clamp_line(
    _: *T.Tty,
    ctx: *const T.TtyCtx,
    px: u32,
    py: u32,
    nx: u32,
    i: *u32,
    x: *u32,
    rx: *u32,
    ry: *u32,
) i32 {
    const xoff = ctx.rxoff + px;
    const yoff = ctx.ryoff + py;

    if (tty_is_visible_inline(ctx, px, py, nx, 1) == 0) return 0;

    if (ctx.bigger) {
        if (xoff < ctx.wox) {
            i.* = ctx.wox - xoff;
            x.* = ctx.wox;
            rx.* = nx -| i.*;
        } else {
            i.* = 0;
            x.* = xoff;
            rx.* = nx;
        }
        if (xoff + nx > ctx.wox + ctx.wsx)
            rx.* = (ctx.wox + ctx.wsx) -| x.*;
    } else {
        i.* = 0;
        x.* = xoff;
        rx.* = nx;
    }
    ry.* = yoff - ctx.woy;
    return 1;
}

fn tty_is_visible_inline(ctx: *const T.TtyCtx, px: u32, py: u32, nx: u32, ny: u32) i32 {
    const xoff = ctx.rxoff + px;
    const yoff = ctx.ryoff + py;
    if (ctx.bigger) {
        if (xoff + nx <= ctx.wox or xoff >= ctx.wox + ctx.wsx) return 0;
        if (yoff + ny <= ctx.woy or yoff >= ctx.woy + ctx.wsy) return 0;
    }
    return 1;
}

pub fn tty_clear_pane_line(tty: *T.Tty, ctx: *const T.TtyCtx, py: u32, px: u32, nx: u32, bg: u32) void {
    var i: u32 = 0;
    var x: u32 = 0;
    var rx: u32 = 0;
    var ry: u32 = 0;
    if (tty_clamp_line(tty, ctx, px, py, nx, &i, &x, &rx, &ry) != 0) {
        tty_clear_line(tty, &ctx.defaults, ry, x, rx, bg);
    }
}

pub fn tty_clamp_area(
    tty: *T.Tty,
    ctx: *const T.TtyCtx,
    px: u32,
    py: u32,
    nx: u32,
    ny: u32,
    i: *u32,
    j: *u32,
    x: *u32,
    y: *u32,
    rx: *u32,
    ry: *u32,
) i32 {
    const xoff = ctx.rxoff + px;
    const yoff = ctx.ryoff + py;

    if (tty_is_visible(tty, ctx, px, py, nx, ny) == 0) return 0;

    if (ctx.bigger) {
        if (xoff < ctx.wox) {
            i.* = ctx.wox - xoff;
            x.* = ctx.wox;
            rx.* = nx -| i.*;
        } else {
            i.* = 0;
            x.* = xoff;
            rx.* = nx;
        }
        if (xoff + nx > ctx.wox + ctx.wsx)
            rx.* = (ctx.wox + ctx.wsx) -| x.*;

        if (yoff < ctx.woy) {
            j.* = ctx.woy - yoff;
            y.* = ctx.woy;
            ry.* = ny -| j.*;
        } else {
            j.* = 0;
            y.* = yoff;
            ry.* = ny;
        }
        if (yoff + ny > ctx.woy + ctx.wsy)
            ry.* = (ctx.woy + ctx.wsy) -| y.*;
    } else {
        i.* = 0;
        x.* = xoff;
        rx.* = nx;
        j.* = 0;
        y.* = yoff;
        ry.* = ny;
    }
    return 1;
}

pub fn tty_clear_pane_area(tty: *T.Tty, ctx: *const T.TtyCtx, py: u32, ny: u32, px: u32, nx: u32, bg: u32) void {
    var i: u32 = 0;
    var j: u32 = 0;
    var x: u32 = 0;
    var y: u32 = 0;
    var rx: u32 = 0;
    var ry: u32 = 0;
    if (tty_clamp_area(tty, ctx, px, py, nx, ny, &i, &j, &x, &y, &rx, &ry) != 0) {
        tty_clear_area(tty, &ctx.defaults, y, ry, x, rx, bg);
    }
}

pub fn tty_check_codeset(_: *T.Tty, gc: *const T.GridCell) *const T.GridCell {
    return gc;
}

/// Port of tmux tty_set_client_cb() (#ifdef ENABLE_SIXEL).
/// Per-client setup callback for multi-client sixel rendering.
pub fn tty_set_client_cb(ttyctx: *T.TtyCtx, c: *T.Client) i32 {
    const wp: *T.WindowPane = @ptrCast(@alignCast(ttyctx.arg orelse return 0));

    const s = c.session orelse return 0;
    const curw = s.curw orelse return 0;
    if (curw.window != wp.window) return 0;
    if (wp.layout_cell == null) return 0;

    ttyctx.bigger = tty_window_offset(&c.tty, &ttyctx.wox, &ttyctx.woy,
        &ttyctx.wsx, &ttyctx.wsy) != 0;

    ttyctx.yoff = wp.yoff;
    ttyctx.ryoff = wp.yoff;
    if (status_mod.status_at_line(c) == 0)
        ttyctx.yoff += resize_mod.status_line_size(c);

    return 1;
}

/// Port of tmux tty_client_ready().
pub fn tty_client_ready(ctx: *const T.TtyCtx, c: *T.Client) i32 {
    if (c.session == null) return 0;
    // Zmux does not carry a per-client TtyTerm pointer on the Tty struct;
    // skip the term != NULL guard (the client would not have been attached
    // without a term).
    if ((c.flags & T.CLIENT_SUSPENDED) != 0) return 0;

    // If invisible panes are allowed (passthrough), skip redraw/freeze checks.
    if (ctx.allow_invisible_panes) return 1;

    if ((c.flags & T.CLIENT_REDRAWWINDOW) != 0) return 0;
    if ((c.tty.flags & @as(i32, @intCast(T.TTY_FREEZE))) != 0) return 0;
    return 1;
}


pub fn tty_window_default_style(gc: *T.GridCell, wp: *T.WindowPane) void {
    gc.* = T.grid_default_cell;
    gc.fg = wp.palette.fg;
    gc.bg = wp.palette.bg;
}

/// tmux `tty_draw_pane(tty, ctx, py)` — redraws a single line of a pane.
/// Uses overlay range checks and delegates to tty_draw_line.
pub fn tty_draw_pane(tty: *T.Tty, ctx: *const T.TtyCtx, py: u32) void {
    const s = ctx.s orelse return;
    const nx = ctx.sx;

    if (!ctx.bigger) {
        const r = tty_check_overlay_range(tty, ctx.xoff, ctx.yoff + py, nx);
        var j: u32 = 0;
        while (j < r.used) : (j += 1) {
            const rr = &r.ranges[j];
            if (rr.nx != 0) {
                tty_draw_line(tty, s, rr.px - ctx.xoff, py, rr.nx, rr.px, ctx.yoff + py, &ctx.defaults, ctx.palette orelse &default_palette);
            }
        }
        return;
    }

    var i: u32 = 0;
    var x: u32 = 0;
    var rx: u32 = 0;
    var ry: u32 = 0;
    if (tty_clamp_line(tty, ctx, 0, py, nx, &i, &x, &rx, &ry) != 0) {
        const r = tty_check_overlay_range(tty, x, ry, rx);
        var j: u32 = 0;
        while (j < r.used) : (j += 1) {
            const rr = &r.ranges[j];
            if (rr.nx != 0) {
                tty_draw_line(tty, s, i + (rr.px - x), py, rr.nx, rr.px, ry, &ctx.defaults, ctx.palette orelse &default_palette);
            }
        }
    }
}

const default_palette = T.ColourPalette{};

pub fn tty_check_overlay(_: *T.Tty, _: u32, _: u32) i32 {
    return 1;
}

pub fn tty_check_overlay_range(tty: *T.Tty, px: u32, py: u32, nx: u32) *VisibleRanges {
    _ = tty;
    _ = py;
    tty_stub_overlay_storage.ranges[0] = .{ .px = px, .nx = nx };
    tty_stub_overlay_storage.used = 1;
    return &tty_stub_overlay_storage;
}

pub fn tty_update_cursor(_: *T.Tty, mode: i32, _: ?*T.Screen) i32 {
    return mode;
}

pub fn tty_update_mode(tty: *T.Tty, mode: i32, s: ?*T.Screen) void {
    var actual = mode;
    if ((tty.flags & @as(i32, @intCast(T.TTY_NOCURSOR))) != 0)
        actual &= ~@as(i32, T.MODE_CURSOR);

    const changed = actual ^ tty.mode;
    _ = changed;
    _ = s;

    tty.mode = actual;
}

pub fn tty_sync_start(tty: *T.Tty) void {
    if ((tty.flags & @as(i32, @intCast(T.TTY_BLOCK))) != 0) return;
    if ((tty.flags & @as(i32, @intCast(T.TTY_SYNCING))) != 0) return;
    tty.flags |= @intCast(T.TTY_SYNCING);

    if (tty_term.hasCapability(tty, "Sync"))
        tty_putcode_i(tty, "Sync", 1);
}

pub fn tty_sync_end(tty: *T.Tty) void {
    if ((tty.flags & @as(i32, @intCast(T.TTY_BLOCK))) != 0) return;
    if ((tty.flags & @as(i32, @intCast(T.TTY_SYNCING))) == 0) return;
    tty.flags &= ~@as(i32, @intCast(T.TTY_SYNCING));

    if (tty_term.hasCapability(tty, "Sync"))
        tty_putcode_i(tty, "Sync", 2);
}

pub fn tty_default_colours(gc: *T.GridCell, wp: *T.WindowPane) void {
    gc.* = T.grid_default_cell;
    gc.fg = wp.palette.fg;
    gc.bg = wp.palette.bg;
}

pub fn tty_default_attributes(
    tty: *T.Tty,
    defaults: *const T.GridCell,
    _: ?*T.ColourPalette,
    bg: u32,
    hl: ?*hyperlinks_mod.Hyperlinks,
) void {
    var gc = T.grid_default_cell;
    gc.bg = @intCast(bg);
    tty_attributes(tty, &gc, defaults, hl);
}

pub fn tty_set_selection(tty: *T.Tty, clip: ?[*:0]const u8, buf: ?[*]const u8, len: usize) void {
    if ((tty.flags & @as(i32, @intCast(T.TTY_STARTED))) == 0) return;
    if (!tty_term.hasCapability(tty, "Ms")) return;
    if (buf == null or len == 0) return;

    const src = buf.?[0..len];
    const b64_size = 4 * ((len + 2) / 3) + 1;
    const encoded = xm.allocator.alloc(u8, b64_size) catch return;
    defer xm.allocator.free(encoded);

    const b64_alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    var out_idx: usize = 0;
    var i: usize = 0;
    while (i < src.len) {
        const b0: u32 = src[i];
        const b1: u32 = if (i + 1 < src.len) src[i + 1] else 0;
        const b2: u32 = if (i + 2 < src.len) src[i + 2] else 0;
        const triple = (b0 << 16) | (b1 << 8) | b2;
        if (out_idx < encoded.len) encoded[out_idx] = b64_alphabet[(triple >> 18) & 0x3F];
        out_idx += 1;
        if (out_idx < encoded.len) encoded[out_idx] = b64_alphabet[(triple >> 12) & 0x3F];
        out_idx += 1;
        if (i + 1 < src.len) {
            if (out_idx < encoded.len) encoded[out_idx] = b64_alphabet[(triple >> 6) & 0x3F];
        } else {
            if (out_idx < encoded.len) encoded[out_idx] = '=';
        }
        out_idx += 1;
        if (i + 2 < src.len) {
            if (out_idx < encoded.len) encoded[out_idx] = b64_alphabet[triple & 0x3F];
        } else {
            if (out_idx < encoded.len) encoded[out_idx] = '=';
        }
        out_idx += 1;
        i += 3;
    }

    const clip_str = if (clip) |c| std.mem.span(c) else "";
    const b64_str = encoded[0..out_idx];
    tty.flags |= @intCast(T.TTY_NOBLOCK);
    tty_putcode_ss(tty, "Ms", clip_str, b64_str);
}


pub fn tty_cmd_insertcharacter(tty: *T.Tty, ctx: *const T.TtyCtx) void {
    if (ctx.bigger or
        !tty_full_width(tty, ctx) or
        tty_fake_bce(tty, &ctx.defaults, ctx.bg) or
        (!tty_term.hasCapability(tty, "ich") and
        !tty_term.hasCapability(tty, "ich1")))
    {
        tty_draw_pane(tty, ctx, ctx.ocy);
        return;
    }

    tty_default_attributes(tty, &ctx.defaults, ctx.palette, ctx.bg, if (ctx.s) |s| s.hyperlinks else null);
    tty_cursor_pane_ctx(tty, ctx, ctx.ocx, ctx.ocy);
    tty_emulate_repeat(tty, "ich", "ich1", ctx.num);
}

pub fn tty_cmd_deletecharacter(tty: *T.Tty, ctx: *const T.TtyCtx) void {
    if (ctx.bigger or
        !tty_full_width(tty, ctx) or
        tty_fake_bce(tty, &ctx.defaults, ctx.bg) or
        (!tty_term.hasCapability(tty, "dch") and
        !tty_term.hasCapability(tty, "dch1")))
    {
        tty_draw_pane(tty, ctx, ctx.ocy);
        return;
    }

    tty_default_attributes(tty, &ctx.defaults, ctx.palette, ctx.bg, if (ctx.s) |s| s.hyperlinks else null);
    tty_cursor_pane_ctx(tty, ctx, ctx.ocx, ctx.ocy);
    tty_emulate_repeat(tty, "dch", "dch1", ctx.num);
}

pub fn tty_cmd_clearcharacter(tty: *T.Tty, ctx: *const T.TtyCtx) void {
    tty_default_attributes(tty, &ctx.defaults, ctx.palette, ctx.bg, if (ctx.s) |s| s.hyperlinks else null);
    tty_clear_pane_line(tty, ctx, ctx.ocy, ctx.ocx, ctx.num, ctx.bg);
}

pub fn tty_cmd_insertline(tty: *T.Tty, ctx: *const T.TtyCtx) void {
    if (ctx.bigger or
        !tty_full_width(tty, ctx) or
        tty_fake_bce(tty, &ctx.defaults, ctx.bg) or
        !tty_term.hasCapability(tty, "csr") or
        !tty_term.hasCapability(tty, "il1") or
        ctx.sx == 1 or
        ctx.sy == 1)
    {
        tty_redraw_region(tty, ctx);
        return;
    }

    tty_default_attributes(tty, &ctx.defaults, ctx.palette, ctx.bg, if (ctx.s) |s| s.hyperlinks else null);
    tty_region_pane_ctx(tty, ctx, ctx.orupper, ctx.orlower);
    tty_margin_off(tty);
    tty_cursor_pane_ctx(tty, ctx, ctx.ocx, ctx.ocy);
    tty_emulate_repeat(tty, "il", "il1", ctx.num);
    tty.cx = std.math.maxInt(u32);
    tty.cy = std.math.maxInt(u32);
}

pub fn tty_cmd_deleteline(tty: *T.Tty, ctx: *const T.TtyCtx) void {
    if (ctx.bigger or
        !tty_full_width(tty, ctx) or
        tty_fake_bce(tty, &ctx.defaults, ctx.bg) or
        !tty_term.hasCapability(tty, "csr") or
        !tty_term.hasCapability(tty, "dl1") or
        ctx.sx == 1 or
        ctx.sy == 1)
    {
        tty_redraw_region(tty, ctx);
        return;
    }

    tty_default_attributes(tty, &ctx.defaults, ctx.palette, ctx.bg, if (ctx.s) |s| s.hyperlinks else null);
    tty_region_pane_ctx(tty, ctx, ctx.orupper, ctx.orlower);
    tty_margin_off(tty);
    tty_cursor_pane_ctx(tty, ctx, ctx.ocx, ctx.ocy);
    tty_emulate_repeat(tty, "dl", "dl1", ctx.num);
    tty.cx = std.math.maxInt(u32);
    tty.cy = std.math.maxInt(u32);
}

pub fn tty_cmd_clearline(tty: *T.Tty, ctx: *const T.TtyCtx) void {
    tty_default_attributes(tty, &ctx.defaults, ctx.palette, ctx.bg, if (ctx.s) |s| s.hyperlinks else null);
    tty_clear_pane_line(tty, ctx, ctx.ocy, 0, ctx.sx, ctx.bg);
}

pub fn tty_cmd_clearendofline(tty: *T.Tty, ctx: *const T.TtyCtx) void {
    const nx = ctx.sx -| ctx.ocx;
    tty_default_attributes(tty, &ctx.defaults, ctx.palette, ctx.bg, if (ctx.s) |s| s.hyperlinks else null);
    tty_clear_pane_line(tty, ctx, ctx.ocy, ctx.ocx, nx, ctx.bg);
}

pub fn tty_cmd_clearstartofline(tty: *T.Tty, ctx: *const T.TtyCtx) void {
    tty_default_attributes(tty, &ctx.defaults, ctx.palette, ctx.bg, if (ctx.s) |s| s.hyperlinks else null);
    tty_clear_pane_line(tty, ctx, ctx.ocy, 0, ctx.ocx + 1, ctx.bg);
}

pub fn tty_cmd_reverseindex(tty: *T.Tty, ctx: *const T.TtyCtx) void {
    if (ctx.ocy != ctx.orupper) return;

    if (ctx.bigger or
        (!tty_full_width(tty, ctx) and !tty_use_margin(tty)) or
        tty_fake_bce(tty, &ctx.defaults, 8) or
        !tty_term.hasCapability(tty, "csr") or
        (!tty_term.hasCapability(tty, "ri") and
        !tty_term.hasCapability(tty, "rin")) or
        ctx.sx == 1 or
        ctx.sy == 1)
    {
        tty_redraw_region(tty, ctx);
        return;
    }

    tty_default_attributes(tty, &ctx.defaults, ctx.palette, ctx.bg, if (ctx.s) |s| s.hyperlinks else null);
    tty_region_pane_ctx(tty, ctx, ctx.orupper, ctx.orlower);
    tty_margin_pane_ctx(tty, ctx);
    tty_cursor_pane_ctx(tty, ctx, ctx.ocx, ctx.orupper);

    if (tty_term.hasCapability(tty, "ri"))
        tty_putcode(tty, "ri")
    else
        tty_putcode_i(tty, "rin", 1);
}

pub fn tty_cmd_linefeed(tty: *T.Tty, ctx: *const T.TtyCtx) void {
    if (ctx.ocy != ctx.orlower) return;

    if (ctx.bigger or
        (!tty_full_width(tty, ctx) and !tty_use_margin(tty)) or
        tty_fake_bce(tty, &ctx.defaults, 8) or
        !tty_term.hasCapability(tty, "csr") or
        ctx.sx == 1 or
        ctx.sy == 1)
    {
        tty_redraw_region(tty, ctx);
        return;
    }

    tty_default_attributes(tty, &ctx.defaults, ctx.palette, ctx.bg, if (ctx.s) |s| s.hyperlinks else null);
    tty_region_pane_ctx(tty, ctx, ctx.orupper, ctx.orlower);
    tty_margin_pane_ctx(tty, ctx);

    if (ctx.xoff + ctx.ocx > tty.rright) {
        if (!tty_use_margin(tty))
            tty_cursor(tty, 0, ctx.yoff + ctx.ocy)
        else
            tty_cursor(tty, tty.rright, ctx.yoff + ctx.ocy);
    } else {
        tty_cursor_pane_ctx(tty, ctx, ctx.ocx, ctx.ocy);
    }

    tty_putc(tty, '\n');
}

pub fn tty_cmd_scrollup(tty: *T.Tty, ctx: *const T.TtyCtx) void {
    if (ctx.bigger or
        (!tty_full_width(tty, ctx) and !tty_use_margin(tty)) or
        tty_fake_bce(tty, &ctx.defaults, 8) or
        !tty_term.hasCapability(tty, "csr") or
        ctx.sx == 1 or
        ctx.sy == 1)
    {
        tty_redraw_region(tty, ctx);
        return;
    }

    tty_default_attributes(tty, &ctx.defaults, ctx.palette, ctx.bg, if (ctx.s) |s| s.hyperlinks else null);
    tty_region_pane_ctx(tty, ctx, ctx.orupper, ctx.orlower);
    tty_margin_pane_ctx(tty, ctx);

    if (ctx.num == 1 or !tty_term.hasCapability(tty, "indn")) {
        if (!tty_use_margin(tty))
            tty_cursor(tty, 0, tty.rlower)
        else
            tty_cursor(tty, tty.rright, tty.rlower);
        var i: u32 = 0;
        while (i < ctx.num) : (i += 1)
            tty_putc(tty, '\n');
    } else {
        if (tty.cy == std.math.maxInt(u32))
            tty_cursor(tty, 0, 0)
        else
            tty_cursor(tty, 0, tty.cy);
        tty_putcode_i(tty, "indn", ctx.num);
    }
}

pub fn tty_cmd_scrolldown(tty: *T.Tty, ctx: *const T.TtyCtx) void {
    if (ctx.bigger or
        (!tty_full_width(tty, ctx) and !tty_use_margin(tty)) or
        tty_fake_bce(tty, &ctx.defaults, 8) or
        !tty_term.hasCapability(tty, "csr") or
        (!tty_term.hasCapability(tty, "ri") and
        !tty_term.hasCapability(tty, "rin")) or
        ctx.sx == 1 or
        ctx.sy == 1)
    {
        tty_redraw_region(tty, ctx);
        return;
    }

    tty_default_attributes(tty, &ctx.defaults, ctx.palette, ctx.bg, if (ctx.s) |s| s.hyperlinks else null);
    tty_region_pane_ctx(tty, ctx, ctx.orupper, ctx.orlower);
    tty_margin_pane_ctx(tty, ctx);
    tty_cursor_pane_ctx(tty, ctx, ctx.ocx, ctx.orupper);

    if (tty_term.hasCapability(tty, "rin")) {
        tty_putcode_i(tty, "rin", ctx.num);
    } else {
        var i: u32 = 0;
        while (i < ctx.num) : (i += 1)
            tty_putcode(tty, "ri");
    }
}

pub fn tty_cmd_clearendofscreen(tty: *T.Tty, ctx: *const T.TtyCtx) void {
    tty_default_attributes(tty, &ctx.defaults, ctx.palette, ctx.bg, if (ctx.s) |s| s.hyperlinks else null);
    tty_region_pane_ctx(tty, ctx, 0, ctx.sy -| 1);
    tty_margin_off(tty);

    var py = ctx.ocy + 1;
    const ny = ctx.sy -| ctx.ocy -| 1;
    tty_clear_pane_area(tty, ctx, py, ny, 0, ctx.sx, ctx.bg);

    py = ctx.ocy;
    const nx = ctx.sx -| ctx.ocx;
    tty_clear_pane_line(tty, ctx, py, ctx.ocx, nx, ctx.bg);
}

pub fn tty_cmd_clearstartofscreen(tty: *T.Tty, ctx: *const T.TtyCtx) void {
    tty_default_attributes(tty, &ctx.defaults, ctx.palette, ctx.bg, if (ctx.s) |s| s.hyperlinks else null);
    tty_region_pane_ctx(tty, ctx, 0, ctx.sy -| 1);
    tty_margin_off(tty);

    tty_clear_pane_area(tty, ctx, 0, ctx.ocy, 0, ctx.sx, ctx.bg);
    tty_clear_pane_line(tty, ctx, ctx.ocy, 0, ctx.ocx + 1, ctx.bg);
}

pub fn tty_cmd_clearscreen(tty: *T.Tty, ctx: *const T.TtyCtx) void {
    tty_default_attributes(tty, &ctx.defaults, ctx.palette, ctx.bg, if (ctx.s) |s| s.hyperlinks else null);
    tty_region_pane_ctx(tty, ctx, 0, ctx.sy -| 1);
    tty_margin_off(tty);
    tty_clear_pane_area(tty, ctx, 0, ctx.sy, 0, ctx.sx, ctx.bg);
}

pub fn tty_cmd_alignmenttest(tty: *T.Tty, ctx: *const T.TtyCtx) void {
    if (ctx.bigger) {
        if (ctx.redraw_cb) |cb| cb(ctx);
        return;
    }

    tty_attributes(tty, &T.grid_default_cell, &ctx.defaults, null);
    tty_region_pane_ctx(tty, ctx, 0, ctx.sy -| 1);
    tty_margin_off(tty);

    var j: u32 = 0;
    while (j < ctx.sy) : (j += 1) {
        tty_cursor_pane_ctx(tty, ctx, 0, j);
        var i: u32 = 0;
        while (i < ctx.sx) : (i += 1)
            tty_putc(tty, 'E');
    }
}

pub fn tty_cmd_cell(tty: *T.Tty, ctx: *const T.TtyCtx) void {
    const gcp = ctx.cell orelse return;
    const s = ctx.s orelse return;

    const px = ctx.xoff + ctx.ocx -| ctx.wox;
    const py = ctx.yoff + ctx.ocy -| ctx.woy;
    if (tty_is_visible(tty, ctx, ctx.ocx, ctx.ocy, 1, 1) == 0 or
        (gcp.data.width == 1 and tty_check_overlay(tty, px, py) == 0))
        return;

    if (ctx.xoff + ctx.ocx -| ctx.wox > tty.sx -| 1 and
        ctx.ocy == ctx.orlower and
        tty_full_width(tty, ctx))
    {
        tty_region_pane_ctx(tty, ctx, ctx.orupper, ctx.orlower);
    }

    tty_margin_off(tty);
    tty_cursor_pane_unless_wrap_ctx(tty, ctx, ctx.ocx, ctx.ocy);
    tty_cell(tty, gcp, &ctx.defaults, s.hyperlinks);

    if (ctx.num == 1) tty_invalidate(tty);
}

pub fn tty_cmd_cells(tty: *T.Tty, ctx: *const T.TtyCtx) void {
    const cp = ctx.ptr orelse return;

    if (tty_is_visible(tty, ctx, ctx.ocx, ctx.ocy, ctx.num, 1) == 0) return;

    if (ctx.bigger and
        (ctx.xoff + ctx.ocx < ctx.wox or
        ctx.xoff + ctx.ocx + ctx.num > ctx.wox + ctx.wsx))
    {
        if (!ctx.wrapped or
            !tty_full_width(tty, ctx) or
            ctx.xoff + ctx.ocx != 0 or
            ctx.yoff + ctx.ocy != tty.cy +% 1 or
            tty.cx < tty.sx or
            tty.cy == tty.rlower)
        {
            tty_draw_pane(tty, ctx, ctx.ocy);
        } else {
            if (ctx.redraw_cb) |cb| cb(ctx);
        }
        return;
    }

    tty_margin_off(tty);
    tty_cursor_pane_unless_wrap_ctx(tty, ctx, ctx.ocx, ctx.ocy);
    if (ctx.cell) |gc| {
        tty_attributes(tty, gc, &ctx.defaults, if (ctx.s) |s| s.hyperlinks else null);
    }

    const px = ctx.xoff + ctx.ocx -| ctx.wox;
    const r = tty_check_overlay_range(tty, px, ctx.yoff + ctx.ocy -| ctx.woy, ctx.num);
    var i: u32 = 0;
    while (i < r.used) : (i += 1) {
        const rr = &r.ranges[i];
        if (rr.nx != 0) {
            const cx = rr.px -| ctx.xoff +| ctx.wox;
            tty_cursor_pane_unless_wrap_ctx(tty, ctx, cx, ctx.ocy);
            const start = rr.px -| px;
            if (start + rr.nx <= ctx.num) {
                tty_putn(tty, cp[start .. start + rr.nx], rr.nx);
            }
        }
    }
}

pub fn tty_cmd_setselection(tty: *T.Tty, ctx: *const T.TtyCtx) void {
    tty_set_selection(tty, ctx.ptr2, if (ctx.ptr) |p| @ptrCast(p) else null, ctx.num);
}

pub fn tty_cmd_rawstring(tty: *T.Tty, ctx: *const T.TtyCtx) void {
    tty.flags |= @intCast(T.TTY_NOBLOCK);
    if (ctx.ptr) |p| {
        tty_add(tty, p, ctx.num);
    }
    tty_invalidate(tty);
}

/// Port of tmux tty_cmd_sixelimage() (#ifdef ENABLE_SIXEL).
/// Renders a sixel image stored in ctx.ptr at position (ctx.ocx, ctx.ocy).
/// TODO: replace ctx.ptr/ctx.num fallback text with sixel_scale/sixel_print
/// output once image-sixel.zig is ported.
pub fn tty_cmd_sixelimage(tty: *T.Tty, ctx: *const T.TtyCtx) void {
    const has_sixel = (tty.client.term_features & tty_features.TERM_SIXEL) != 0 or
        tty_term.hasCapability(tty, "Sxl");
    const has_pixel = tty.xpixel != 0 and tty.ypixel != 0;
    const fallback = !has_sixel or !has_pixel;

    // Use ctx.sx/sy as dimension bounds; exact cell size requires the sixel
    // runtime which is not yet ported.
    var i: u32 = 0;
    var j: u32 = 0;
    var x: u32 = 0;
    var y: u32 = 0;
    var rx: u32 = 0;
    var ry: u32 = 0;
    if (tty_clamp_area(tty, ctx, ctx.ocx, ctx.ocy, ctx.sx, ctx.sy,
            &i, &j, &x, &y, &rx, &ry) == 0)
        return;

    log.log_debug("tty_cmd_sixelimage: fallback={}, clamp ({d},{d})-({d},{d})",
        .{ fallback, i, j, rx, ry });

    tty_region_off(tty);
    tty_margin_off(tty);
    tty_cursor(tty, x, y);
    tty.flags |= @as(i32, @intCast(T.TTY_NOBLOCK));

    if (!fallback) {
        // Sixel-capable terminal: scale the image to the visible region
        // and emit real sixel DCS data.
        const sixel_mod = @import("image-sixel.zig");
        const si: *T.SixelImage = @ptrCast(@alignCast(ctx.si orelse {
            // No sixel data available — fall through to fallback text.
            const data = ctx.ptr orelse return;
            tty_add(tty, data, ctx.num);
            tty_invalidate(tty);
            return;
        }));
        const scaled = sixel_mod.sixel_scale(si, i, j, rx -| i, ry -| j,
            rx -| i, ry -| j, false) orelse {
            // Scale failed — use fallback text.
            const data = ctx.ptr orelse return;
            tty_add(tty, data, ctx.num);
            tty_invalidate(tty);
            return;
        };
        defer sixel_mod.sixel_free(scaled);
        const printed = sixel_mod.sixel_print(scaled, null) orelse {
            const data = ctx.ptr orelse return;
            tty_add(tty, data, ctx.num);
            tty_invalidate(tty);
            return;
        };
        defer xm.allocator.free(printed);
        tty_add(tty, printed.ptr, printed.len);
    } else {
        // Non-sixel terminal: emit pre-rendered fallback text.
        const data = ctx.ptr orelse return;
        tty_add(tty, data, ctx.num);
    }
    tty_invalidate(tty);
}

/// Write a tty command to a single client (not all clients).  Used by
/// tty_draw_images to render sixel images to the originating client only.
/// Ported from tmux tty_write_one(); gated on ENABLE_SIXEL in tmux.
fn tty_write_one(
    cmdfn: *const fn (*T.Tty, *const T.TtyCtx) void,
    c: *T.Client,
    ctx: *T.TtyCtx,
) void {
    const set_cb = ctx.set_client_cb orelse return;
    if (set_cb(ctx, c) == 1)
        cmdfn(&c.tty, ctx);
}

/// Iterate the sixel image list on screen `s` and redraw each one via
/// tty_write_one → tty_cmd_sixelimage.  Called from screen_redraw_draw_pane
/// after pane content is drawn.  Gated on ENABLE_SIXEL in tmux; zmux does
/// not yet have an Image type, so this is a no-op placeholder that
/// preserves the call interface.
pub fn tty_draw_images(_: *T.Client, _: *T.WindowPane, _: *T.Screen) void {
    // Sixel image support is not yet ported; nothing to iterate.
}

pub fn tty_cmd_syncstart(tty: *T.Tty, ctx: *const T.TtyCtx) void {
    if (ctx.num == 0x11) {
        tty_sync_start(tty);
    } else if ((ctx.num & 0x10) == 0) {
        if (ctx.num != 0 or tty.client.popup_data != null)
            tty_sync_start(tty);
    }
}

/// Check if pane spans full terminal width.
fn tty_full_width(tty: *const T.Tty, ctx: *const T.TtyCtx) bool {
    return ctx.xoff == 0 and ctx.sx >= tty.sx;
}

/// Move cursor inside a pane using a TtyCtx.
fn tty_cursor_pane_ctx(tty: *T.Tty, ctx: *const T.TtyCtx, px: u32, py: u32) void {
    tty_cursor(tty, ctx.xoff + px -| ctx.wox, ctx.yoff + py -| ctx.woy);
}

/// Same as tty_cursor_pane_ctx but skips if the cursor is already at the right
/// position (optimization for wrap-at-margin case).
fn tty_cursor_pane_unless_wrap_ctx(tty: *T.Tty, ctx: *const T.TtyCtx, px: u32, py: u32) void {
    if (!ctx.wrapped or
        !(ctx.xoff == 0 and ctx.sx >= tty.sx) or
        ctx.xoff + px != 0 or
        ctx.yoff + py != tty.cy +% 1 or
        tty.cx < tty.sx)
    {
        tty_cursor_pane_ctx(tty, ctx, px, py);
    }
}

/// Set the scrolling region inside a pane using a TtyCtx.
fn tty_region_pane_ctx(tty: *T.Tty, ctx: *const T.TtyCtx, rupper: u32, rlower: u32) void {
    tty_region(tty, ctx.yoff + rupper -| ctx.woy, ctx.yoff + rlower -| ctx.woy);
}

/// Set margins inside a pane using a TtyCtx.
fn tty_margin_pane_ctx(tty: *T.Tty, ctx: *const T.TtyCtx) void {
    tty_margin(tty, ctx.xoff -| ctx.wox, ctx.xoff + ctx.sx -| 1 -| ctx.wox);
}

test "tty_open starts reduced tty lifecycle" {
    const env_mod = @import("environ.zig");

    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);

    var cl = T.Client{
        .environ = env,
        .tty = undefined,
        .status = .{},
    };
    tty_init(&cl.tty, &cl);

    cl.tty.cx = 7;
    cl.tty.cy = 9;
    cl.tty.mode = 123;
    cl.tty.fg = 3;
    cl.tty.bg = 4;

    var cause: ?[]u8 = null;
    try std.testing.expectEqual(@as(i32, 0), tty_open(&cl.tty, &cause));
    try std.testing.expect(cause == null);
    try std.testing.expect((cl.tty.flags & @as(i32, @intCast(T.TTY_OPENED))) != 0);
    try std.testing.expect((cl.tty.flags & @as(i32, @intCast(T.TTY_STARTED))) != 0);
    try std.testing.expectEqual(std.math.maxInt(u32), cl.tty.cx);
    try std.testing.expectEqual(std.math.maxInt(u32), cl.tty.cy);
    try std.testing.expectEqual(@as(i32, 8), cl.tty.fg);
    try std.testing.expectEqual(@as(i32, 8), cl.tty.bg);

    tty_close(&cl.tty);
    try std.testing.expect((cl.tty.flags & @as(i32, @intCast(T.TTY_OPENED))) == 0);
    try std.testing.expect((cl.tty.flags & @as(i32, @intCast(T.TTY_STARTED))) == 0);
}

test "tty_resize clamps size and restores default pixels" {
    const env_mod = @import("environ.zig");

    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);

    var cl = T.Client{
        .environ = env,
        .tty = undefined,
        .status = .{},
    };
    tty_init(&cl.tty, &cl);

    tty_resize(&cl.tty, 0, 0, 0, 0);
    try std.testing.expectEqual(@as(u32, 1), cl.tty.sx);
    try std.testing.expectEqual(@as(u32, 1), cl.tty.sy);
    try std.testing.expectEqual(T.DEFAULT_XPIXEL, cl.tty.xpixel);
    try std.testing.expectEqual(T.DEFAULT_YPIXEL, cl.tty.ypixel);
}

test "tty_append_mode_update emits reduced outer mouse, bracketed-paste, and focus negotiation" {
    const env_mod = @import("environ.zig");

    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);

    var caps = [_][]u8{
        @constCast("kmous=\x1b[M"),
        @constCast("Enbp=\x1b[?2004h"),
        @constCast("Dsbp=\x1b[?2004l"),
        @constCast("Enfcs=\x1b[?1004h"),
        @constCast("Dsfcs=\x1b[?1004l"),
    };
    var cl = T.Client{
        .environ = env,
        .tty = undefined,
        .status = .{},
        .term_caps = caps[0..],
    };
    tty_init(&cl.tty, &cl);

    var out: std.ArrayList(u8) = .{};
    defer out.deinit(xm.allocator);

    try tty_append_mode_update(&cl.tty, T.MODE_MOUSE_BUTTON | T.MODE_BRACKETPASTE | T.MODE_FOCUSON, &out);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\x1b[?1006h") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\x1b[?1002h") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\x1b[?2004h") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\x1b[?1004h") != null);

    out.clearRetainingCapacity();
    try tty_append_mode_update(&cl.tty, 0, &out);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\x1b[?1006l") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\x1b[?2004l") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\x1b[?1004l") != null);
}

test "tty_append_mode_update suppresses unsupported outer modes on reduced dumb terminals" {
    const env_mod = @import("environ.zig");

    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);

    var cl = T.Client{
        .environ = env,
        .tty = undefined,
        .status = .{},
        .term_caps = &.{},
    };
    tty_init(&cl.tty, &cl);

    var out: std.ArrayList(u8) = .{};
    defer out.deinit(xm.allocator);

    try tty_append_mode_update(&cl.tty, T.MODE_MOUSE_BUTTON | T.MODE_BRACKETPASTE | T.MODE_FOCUSON, &out);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
    try std.testing.expectEqual(@as(i32, 0), cl.tty.mode);
}

test "tty_append_mode_update falls back to standard toggles when only feature bits are known" {
    const env_mod = @import("environ.zig");

    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);

    var cl = T.Client{
        .environ = env,
        .tty = undefined,
        .status = .{},
        .term_features = tty_features.featureBit(.bpaste) | tty_features.featureBit(.focus),
    };
    tty_init(&cl.tty, &cl);

    var out: std.ArrayList(u8) = .{};
    defer out.deinit(xm.allocator);

    try tty_append_mode_update(&cl.tty, T.MODE_BRACKETPASTE | T.MODE_FOCUSON, &out);
    try std.testing.expectEqualStrings("\x1b[?2004h\x1b[?1004h", out.items);

    out.clearRetainingCapacity();
    try tty_append_mode_update(&cl.tty, 0, &out);
    try std.testing.expectEqualStrings("\x1b[?2004l\x1b[?1004l", out.items);
}

test "tty_set_title honours the reduced title capability layer" {
    const env_mod = @import("environ.zig");

    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);

    var cl = T.Client{
        .environ = env,
        .tty = undefined,
        .status = .{},
        .term_caps = &.{},
    };
    tty_init(&cl.tty, &cl);
    cl.tty.flags |= @as(i32, @intCast(T.TTY_STARTED));

    tty_set_title(&cl.tty, "suppressed");
}

test "tty_clipboard_query emits the recorded Ms capability query" {
    const proc_mod_local = @import("proc.zig");

    var pair: [2]i32 = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &pair));

    var proc = T.ZmuxProc{ .name = "tty-clipboard-query-test" };
    defer proc.peers.deinit(xm.allocator);

    var caps = [_][]u8{
        @constCast("Ms=\x1b]52;c;!\x07\x1b]52;c;%p2%s\x07"),
    };
    var cl = T.Client{
        .environ = undefined,
        .tty = undefined,
        .status = .{},
        .term_caps = caps[0..],
    };
    tty_init(&cl.tty, &cl);
    tty_start_tty(&cl.tty);
    cl.peer = proc_mod_local.proc_add_peer(&proc, pair[0], test_peer_dispatch, null);
    defer {
        const peer = cl.peer.?;
        c_zig.imsg.imsgbuf_clear(&peer.ibuf);
        std.posix.close(peer.ibuf.fd);
        xm.allocator.destroy(peer);
        proc.peers.clearRetainingCapacity();
    }

    var reader: c_zig.imsg.imsgbuf = undefined;
    try std.testing.expectEqual(@as(i32, 0), c_zig.imsg.imsgbuf_init(&reader, pair[1]));
    defer {
        c_zig.imsg.imsgbuf_clear(&reader);
        std.posix.close(pair[1]);
    }

    tty_clipboard_query(&cl.tty);

    try std.testing.expectEqual(@as(i32, 1), c_zig.imsg.imsgbuf_read(&reader));

    var imsg_msg: c_zig.imsg.imsg = undefined;
    try std.testing.expect(c_zig.imsg.imsg_get(&reader, &imsg_msg) > 0);
    defer c_zig.imsg.imsg_free(&imsg_msg);

    try std.testing.expectEqual(@as(u32, @intCast(@intFromEnum(@import("zmux-protocol.zig").MsgType.write))), c_zig.imsg.imsg_get_type(&imsg_msg));

    const payload_len = c_zig.imsg.imsg_get_len(&imsg_msg);
    var payload = try xm.allocator.alloc(u8, payload_len);
    defer xm.allocator.free(payload);
    try std.testing.expectEqual(@as(i32, 0), c_zig.imsg.imsg_get_data(&imsg_msg, payload.ptr, payload.len));

    var stream: i32 = 0;
    @memcpy(std.mem.asBytes(&stream), payload[0..@sizeOf(i32)]);
    try std.testing.expectEqual(@as(i32, 1), stream);
    try std.testing.expectEqualStrings("\x1b]52;c;!\x07\x1b]52;c;?\x07", payload[@sizeOf(i32)..]);
}

fn test_peer_dispatch(_: ?*c_zig.imsg.imsg, _: ?*anyopaque) callconv(.c) void {}

test "tty_cursor updates cx/cy to target position" {
    const proc_mod_local = @import("proc.zig");

    var pair: [2]i32 = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &pair));

    var proc = T.ZmuxProc{ .name = "tty-cursor-test" };
    defer proc.peers.deinit(xm.allocator);

    var caps = [_][]u8{
        @constCast("cup=\x1b[%i%p1%d;%p2%dH"),
    };
    var cl = T.Client{
        .environ = undefined,
        .tty = undefined,
        .status = .{},
        .term_caps = caps[0..],
    };
    tty_init(&cl.tty, &cl);
    tty_start_tty(&cl.tty);
    cl.tty.sx = 80;
    cl.tty.sy = 24;
    cl.tty.cx = 0;
    cl.tty.cy = 0;
    cl.peer = proc_mod_local.proc_add_peer(&proc, pair[0], test_peer_dispatch, null);
    defer {
        const peer = cl.peer.?;
        c_zig.imsg.imsgbuf_clear(&peer.ibuf);
        std.posix.close(peer.ibuf.fd);
        xm.allocator.destroy(peer);
        proc.peers.clearRetainingCapacity();
    }

    tty_cursor(&cl.tty, 10, 5);
    try std.testing.expectEqual(@as(u32, 10), cl.tty.cx);
    try std.testing.expectEqual(@as(u32, 5), cl.tty.cy);
}

test "tty_cursor skips when already at target position" {
    const proc_mod_local = @import("proc.zig");

    var pair: [2]i32 = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &pair));

    var proc = T.ZmuxProc{ .name = "tty-cursor-skip-test" };
    defer proc.peers.deinit(xm.allocator);

    var caps = [_][]u8{
        @constCast("cup=\x1b[%i%p1%d;%p2%dH"),
    };
    var cl = T.Client{
        .environ = undefined,
        .tty = undefined,
        .status = .{},
        .term_caps = caps[0..],
    };
    tty_init(&cl.tty, &cl);
    tty_start_tty(&cl.tty);
    cl.tty.sx = 80;
    cl.tty.sy = 24;
    cl.tty.cx = 10;
    cl.tty.cy = 5;
    cl.peer = proc_mod_local.proc_add_peer(&proc, pair[0], test_peer_dispatch, null);
    defer {
        const peer = cl.peer.?;
        c_zig.imsg.imsgbuf_clear(&peer.ibuf);
        std.posix.close(peer.ibuf.fd);
        xm.allocator.destroy(peer);
        proc.peers.clearRetainingCapacity();
    }

    // Position unchanged -- no write should happen.
    tty_cursor(&cl.tty, 10, 5);
    try std.testing.expectEqual(@as(u32, 10), cl.tty.cx);
    try std.testing.expectEqual(@as(u32, 5), cl.tty.cy);
}

test "tty_cursor clamps x to right margin" {
    const proc_mod_local = @import("proc.zig");

    var pair: [2]i32 = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &pair));

    var proc = T.ZmuxProc{ .name = "tty-cursor-clamp-test" };
    defer proc.peers.deinit(xm.allocator);

    var caps = [_][]u8{
        @constCast("cup=\x1b[%i%p1%d;%p2%dH"),
    };
    var cl = T.Client{
        .environ = undefined,
        .tty = undefined,
        .status = .{},
        .term_caps = caps[0..],
    };
    tty_init(&cl.tty, &cl);
    tty_start_tty(&cl.tty);
    cl.tty.sx = 80;
    cl.tty.sy = 24;
    cl.tty.cx = 0;
    cl.tty.cy = 0;
    cl.peer = proc_mod_local.proc_add_peer(&proc, pair[0], test_peer_dispatch, null);
    defer {
        const peer = cl.peer.?;
        c_zig.imsg.imsgbuf_clear(&peer.ibuf);
        std.posix.close(peer.ibuf.fd);
        xm.allocator.destroy(peer);
        proc.peers.clearRetainingCapacity();
    }

    tty_cursor(&cl.tty, 200, 5);
    try std.testing.expectEqual(@as(u32, 79), cl.tty.cx);
    try std.testing.expectEqual(@as(u32, 5), cl.tty.cy);
}

test "tty_cursor_pane translates pane-relative to absolute coordinates" {
    const proc_mod_local = @import("proc.zig");

    var pair: [2]i32 = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &pair));

    var proc = T.ZmuxProc{ .name = "tty-cursor-pane-test" };
    defer proc.peers.deinit(xm.allocator);

    var caps = [_][]u8{
        @constCast("cup=\x1b[%i%p1%d;%p2%dH"),
    };
    var cl = T.Client{
        .environ = undefined,
        .tty = undefined,
        .status = .{},
        .term_caps = caps[0..],
    };
    tty_init(&cl.tty, &cl);
    tty_start_tty(&cl.tty);
    cl.tty.sx = 80;
    cl.tty.sy = 24;
    cl.tty.cx = 0;
    cl.tty.cy = 0;
    cl.peer = proc_mod_local.proc_add_peer(&proc, pair[0], test_peer_dispatch, null);
    defer {
        const peer = cl.peer.?;
        c_zig.imsg.imsgbuf_clear(&peer.ibuf);
        std.posix.close(peer.ibuf.fd);
        xm.allocator.destroy(peer);
        proc.peers.clearRetainingCapacity();
    }

    var ctx = TtyCursorCtx{ .xoff = 10, .yoff = 5, .wox = 0, .woy = 0 };
    tty_cursor_pane(&cl.tty, &ctx, 3, 2);
    try std.testing.expectEqual(@as(u32, 13), cl.tty.cx);
    try std.testing.expectEqual(@as(u32, 7), cl.tty.cy);
}

test "tty_cursor_pane subtracts window origin offset" {
    const proc_mod_local = @import("proc.zig");

    var pair: [2]i32 = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &pair));

    var proc = T.ZmuxProc{ .name = "tty-cursor-pane-wox-test" };
    defer proc.peers.deinit(xm.allocator);

    var caps = [_][]u8{
        @constCast("cup=\x1b[%i%p1%d;%p2%dH"),
    };
    var cl = T.Client{
        .environ = undefined,
        .tty = undefined,
        .status = .{},
        .term_caps = caps[0..],
    };
    tty_init(&cl.tty, &cl);
    tty_start_tty(&cl.tty);
    cl.tty.sx = 80;
    cl.tty.sy = 24;
    cl.tty.cx = 0;
    cl.tty.cy = 0;
    cl.peer = proc_mod_local.proc_add_peer(&proc, pair[0], test_peer_dispatch, null);
    defer {
        const peer = cl.peer.?;
        c_zig.imsg.imsgbuf_clear(&peer.ibuf);
        std.posix.close(peer.ibuf.fd);
        xm.allocator.destroy(peer);
        proc.peers.clearRetainingCapacity();
    }

    var ctx = TtyCursorCtx{ .xoff = 20, .yoff = 10, .wox = 5, .woy = 3 };
    tty_cursor_pane(&cl.tty, &ctx, 7, 4);
    try std.testing.expectEqual(@as(u32, 22), cl.tty.cx); // 20 + 7 - 5
    try std.testing.expectEqual(@as(u32, 11), cl.tty.cy); // 10 + 4 - 3
}

test "tty_cursor_pane_unless_wrap delegates when not wrapped" {
    const proc_mod_local = @import("proc.zig");

    var pair: [2]i32 = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &pair));

    var proc = T.ZmuxProc{ .name = "tty-cursor-wrap-test" };
    defer proc.peers.deinit(xm.allocator);

    var caps = [_][]u8{
        @constCast("cup=\x1b[%i%p1%d;%p2%dH"),
    };
    var cl = T.Client{
        .environ = undefined,
        .tty = undefined,
        .status = .{},
        .term_caps = caps[0..],
    };
    tty_init(&cl.tty, &cl);
    tty_start_tty(&cl.tty);
    cl.tty.sx = 80;
    cl.tty.sy = 24;
    cl.tty.cx = 0;
    cl.tty.cy = 0;
    cl.peer = proc_mod_local.proc_add_peer(&proc, pair[0], test_peer_dispatch, null);
    defer {
        const peer = cl.peer.?;
        c_zig.imsg.imsgbuf_clear(&peer.ibuf);
        std.posix.close(peer.ibuf.fd);
        xm.allocator.destroy(peer);
        proc.peers.clearRetainingCapacity();
    }

    // wrapped=false, so tty_cursor_pane_unless_wrap should always delegate.
    var ctx = TtyCursorCtx{ .xoff = 5, .yoff = 3, .wox = 0, .woy = 0, .wrapped = false };
    tty_cursor_pane_unless_wrap(&cl.tty, &ctx, 2, 1);
    try std.testing.expectEqual(@as(u32, 7), cl.tty.cx);
    try std.testing.expectEqual(@as(u32, 4), cl.tty.cy);
}

test "tty_cursor emits CUP with correct parameter expansion" {
    const proc_mod_local = @import("proc.zig");

    var pair: [2]i32 = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &pair));

    var proc = T.ZmuxProc{ .name = "tty-cursor-cup-test" };
    defer proc.peers.deinit(xm.allocator);

    var caps = [_][]u8{
        @constCast("cup=\x1b[%i%p1%d;%p2%dH"),
    };
    var cl = T.Client{
        .environ = undefined,
        .tty = undefined,
        .status = .{},
        .term_caps = caps[0..],
    };
    tty_init(&cl.tty, &cl);
    tty_start_tty(&cl.tty);
    cl.tty.sx = 80;
    cl.tty.sy = 24;
    cl.tty.cx = 0;
    cl.tty.cy = 0;
    cl.peer = proc_mod_local.proc_add_peer(&proc, pair[0], test_peer_dispatch, null);
    defer {
        const peer = cl.peer.?;
        c_zig.imsg.imsgbuf_clear(&peer.ibuf);
        std.posix.close(peer.ibuf.fd);
        xm.allocator.destroy(peer);
        proc.peers.clearRetainingCapacity();
    }

    // Flush any pending data from the socket.
    var reader: c_zig.imsg.imsgbuf = undefined;
    try std.testing.expectEqual(@as(i32, 0), c_zig.imsg.imsgbuf_init(&reader, pair[1]));
    defer {
        c_zig.imsg.imsgbuf_clear(&reader);
        std.posix.close(pair[1]);
    }

    tty_cursor(&cl.tty, 4, 7);

    try std.testing.expectEqual(@as(i32, 1), c_zig.imsg.imsgbuf_read(&reader));

    var imsg_msg: c_zig.imsg.imsg = undefined;
    try std.testing.expect(c_zig.imsg.imsg_get(&reader, &imsg_msg) > 0);
    defer c_zig.imsg.imsg_free(&imsg_msg);

    const payload_len = c_zig.imsg.imsg_get_len(&imsg_msg);
    var payload = try xm.allocator.alloc(u8, payload_len);
    defer xm.allocator.free(payload);
    try std.testing.expectEqual(@as(i32, 0), c_zig.imsg.imsg_get_data(&imsg_msg, payload.ptr, payload.len));

    // %i increments both params: row=7+1=8, col=4+1=5 => \x1b[8;5H
    const expected = "\x1b[8;5H";
    const data = payload[@sizeOf(i32)..];
    try std.testing.expectEqualStrings(expected, data);
}

test "expand_tparm expands %i%p1%d;%p2%d pattern correctly" {
    // cup is called as cup(row, col). With row=7, col=4:
    // %i increments: p1=7->8, p2=4->5 => \x1b[8;5H
    const result = try expand_tparm_2("\x1b[%i%p1%d;%p2%dH", 7, 4);
    defer xm.allocator.free(result);
    try std.testing.expectEqualStrings("\x1b[8;5H", result);
}

test "expand_tparm_1 expands %i%p1%d pattern correctly" {
    const result = try expand_tparm_1("\x1b[%i%p1%d`", 9);
    defer xm.allocator.free(result);
    // %i increments: 9->10
    try std.testing.expectEqualStrings("\x1b[10`", result);
}

test "expand_tparm handles literal text without parameters" {
    const result = try expand_tparm_1("\x1b[2J", 0);
    defer xm.allocator.free(result);
    try std.testing.expectEqualStrings("\x1b[2J", result);
}
