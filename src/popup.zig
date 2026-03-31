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
// Ported in part from tmux/popup.c.
// Original copyright:
//   Copyright (c) 2020 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

const std = @import("std");
const T = @import("types.zig");
const cmdq = @import("cmd-queue.zig");
const grid = @import("grid.zig");
const job_mod = @import("job.zig");
const layout_mod = @import("layout.zig");
const menu_mod = @import("menu.zig");
const opts_mod = @import("options.zig");
const screen_mod = @import("screen.zig");
const screen_write = @import("screen-write.zig");
const server_client = @import("server-client.zig");
const server_fn = @import("server-fn.zig");
const status = @import("status.zig");
const style_mod = @import("style.zig");
const tty_acs = @import("tty-acs.zig");
const tty_draw = @import("tty-draw.zig");
const utf8 = @import("utf8.zig");
const window_mod = @import("window.zig");
const xm = @import("xmalloc.zig");

pub const POPUP_CLOSEANYKEY: i32 = 0x1;
pub const POPUP_CLOSEEXIT: i32 = 0x2;
pub const POPUP_CLOSEEXITZERO: i32 = 0x4;
pub const POPUP_INTERNAL: i32 = 0x20;
pub const POPUP_NOJOB: i32 = 0x10;

/// tmux `popup_close_cb` — called when the popup exits (status, user data).
pub const PopupCloseCb = *const fn (i32, ?*anyopaque) void;

/// Matches tmux `BOX_LINES_NONE` / zmux display-popup `-B` (see cmd-display-menu.zig).
pub const POPUP_BORDER_NONE: u32 = 6;

/// Context-menu items for standard popups (tmux `popup_menu_items`).
const popup_menu_items = [_]menu_mod.MenuItemTemplate{
    .{ .name = "Close", .key = 'q' },
    .{ .name = "#{?buffer_name,Paste #[underscore]#{buffer_name},}", .key = 'p' },
    .{ .name = "", .key = T.KEYC_NONE },
    .{ .name = "Fill Space", .key = 'F' },
    .{ .name = "Centre", .key = 'C' },
    .{ .name = "", .key = T.KEYC_NONE },
    .{ .name = "To Horizontal Pane", .key = 'h' },
    .{ .name = "To Vertical Pane", .key = 'v' },
    .{}, // sentinel
};

/// Context-menu items for internal popups (tmux `popup_internal_menu_items`).
const popup_internal_menu_items = [_]menu_mod.MenuItemTemplate{
    .{ .name = "Close", .key = 'q' },
    .{ .name = "", .key = T.KEYC_NONE },
    .{ .name = "Fill Space", .key = 'F' },
    .{ .name = "Centre", .key = 'C' },
    .{}, // sentinel
};

/// Subset of tmux `tty_ctx` used by overlay hooks (`popup_set_client_cb`, `popup_redraw_cb`).
pub const PopupTtyCtx = struct {
    bigger: i32 = 0,
    wox: u32 = 0,
    woy: u32 = 0,
    wsx: u32 = 0,
    wsy: u32 = 0,
    xoff: u32 = 0,
    yoff: u32 = 0,
    rxoff: u32 = 0,
    ryoff: u32 = 0,
    defaults: T.GridCell = T.grid_default_cell,
    arg: ?*anyopaque = null,
};

/// Visible line ranges for `popup_check_cb` (same layout as tmux / server-client overlay math).
pub const PopupVisibleRange = struct {
    px: u32 = 0,
    nx: u32 = 0,
};

pub const PopupVisibleRanges = struct {
    ranges: ?[]PopupVisibleRange = null,
    size: u32 = 0,
    used: u32 = 0,
};

pub const PopupScreenRedrawCtx = struct {};

/// tmux `layout_type` values used by `popup_make_pane`.
pub const PopupLayoutType = enum {
    leftright,
    topbottom,
};

pub const PopupFinishEditCb = *const fn (?[]u8, usize, ?*anyopaque) void;

pub const PopupEditor = struct {
    path: ?[]u8 = null,
    cb: ?PopupFinishEditCb = null,
    arg: ?*anyopaque = null,
};

const Dragging = enum { off, move, size };

pub const PopupData = struct {
    client: *T.Client,
    item: ?*cmdq.CmdqItem = null,
    flags: i32 = 0,
    title: ?[]u8 = null,
    style: ?[]u8 = null,
    border_style: ?[]u8 = null,
    defaults: T.GridCell = T.grid_default_cell,
    border_cell: T.GridCell = T.grid_default_cell,
    border_lines: u32 = 1,
    /// Colour palette (tmux `pd->palette`).
    palette: T.ColourPalette = .{},
    screen: ?*T.Screen = null,
    content: std.ArrayList(u8) = .{},
    /// Exit status of the popup job (tmux `pd->status`).
    command_status: i32 = 0,
    /// PTY-backed job for interactive popups (tmux `pd->job`).
    job: ?*job_mod.Job = null,
    /// Completion callback invoked on exit (tmux `pd->cb` / `pd->arg`).
    close_cb: ?PopupCloseCb = null,
    close_cb_arg: ?*anyopaque = null,
    /// Pending overlay close requested from job/menu (tmux `pd->close`).
    close_pending: bool = false,
    px: u32 = 0,
    py: u32 = 0,
    sx: u32 = 0,
    sy: u32 = 0,
    /// Preferred geometry (tmux `ppx` / `ppy` / `psx` / `psy`) for resize.
    ppx: u32 = 0,
    ppy: u32 = 0,
    psx: u32 = 0,
    psy: u32 = 0,
    dragging: Dragging = .off,
    dx: u32 = 0,
    dy: u32 = 0,
    lx: u32 = 0,
    ly: u32 = 0,
    lb: u32 = 0,
    overlay_ranges: PopupVisibleRanges = .{},

    fn deinit(self: *PopupData) void {
        if (self.overlay_ranges.ranges) |r| {
            xm.allocator.free(r);
            self.overlay_ranges.ranges = null;
            self.overlay_ranges.size = 0;
            self.overlay_ranges.used = 0;
        }
        if (self.screen) |screen| {
            screen_mod.screen_free(screen);
            xm.allocator.destroy(screen);
        }
        if (self.job) |j| job_mod.job_free(j);
        if (self.title) |title| xm.allocator.free(title);
        if (self.style) |style| xm.allocator.free(style);
        if (self.border_style) |border_style| xm.allocator.free(border_style);
        self.content.deinit(xm.allocator);
    }
};

const ClippedBounds = struct {
    xoff: u32,
    yoff: u32,
    sx: u32,
    sy: u32,
};

var popup_check_null_data_fallback: PopupVisibleRanges = .{};

fn state(client: *const T.Client) ?*PopupData {
    const ptr = client.popup_data orelse return null;
    return @ptrCast(@alignCast(ptr));
}

pub fn popup_data(client: *const T.Client) ?*PopupData {
    return state(client);
}

pub fn overlay_active(client: *const T.Client) bool {
    return client.popup_data != null;
}

pub fn popup_present(client: *const T.Client) bool {
    return overlay_active(client);
}

pub fn clear_overlay(client: *T.Client) void {
    const pd = state(client) orelse return;

    client.popup_data = null;
    client.tty.flags &= ~@as(i32, @intCast(T.TTY_NOCURSOR | T.TTY_FREEZE));
    client.flags |= T.CLIENT_REDRAWOVERLAY;

    if (pd.item) |item| cmdq.cmdq_continue(item);
    pd.deinit();
    xm.allocator.destroy(pd);
}

pub fn popup_modify(
    client: *T.Client,
    title: ?[]const u8,
    style: ?[]const u8,
    border_style: ?[]const u8,
    lines: ?u32,
    flags: ?i32,
) void {
    const pd = state(client) orelse return;

    replace_optional_string(&pd.title, title);
    replace_optional_string(&pd.style, style);
    replace_optional_string(&pd.border_style, border_style);
    if (lines) |value| pd.border_lines = value;
    if (flags) |value| pd.flags = value;

    apply_styles(pd);
    rebuild_screen(pd);
    client.flags |= T.CLIENT_REDRAWOVERLAY;
}

pub fn popup_write(client: *T.Client, data: []const u8) void {
    const pd = state(client) orelse return;
    pd.content.appendSlice(xm.allocator, data) catch unreachable;
    rebuild_screen(pd);
    client.flags |= T.CLIENT_REDRAWOVERLAY;
}

pub fn popup_display(
    flags: i32,
    lines: u32,
    item: ?*cmdq.CmdqItem,
    px: u32,
    py: u32,
    sx: u32,
    sy: u32,
    title: []const u8,
    client: *T.Client,
    _session: ?*T.Session,
    style: ?[]const u8,
    border_style: ?[]const u8,
    content: []const u8,
) i32 {
    const popup_height = available_height(client);
    if (sx == 0 or sy == 0 or client.tty.sx < sx or popup_height < sy)
        return -1;

    clear_overlay(client);

    const pd = xm.allocator.create(PopupData) catch unreachable;
    pd.* = .{
        .client = client,
        .item = item,
        .flags = flags,
        .border_lines = lines,
        .px = px,
        .py = py,
        .sx = sx,
        .sy = sy,
        .ppx = px,
        .ppy = py,
        .psx = sx,
        .psy = sy,
        .content = .{},
    };
    errdefer {
        pd.deinit();
        xm.allocator.destroy(pd);
    }

    pd.title = xm.xstrdup(title);
    if (style) |value| pd.style = xm.xstrdup(value);
    if (border_style) |value| pd.border_style = xm.xstrdup(value);
    pd.content.appendSlice(xm.allocator, content) catch unreachable;

    if (_session != null or client.session != null) {
        apply_styles(pd);
    }
    rebuild_screen(pd);

    client.popup_data = pd;
    client.references += 1;
    client.tty.flags |= @intCast(T.TTY_FREEZE | T.TTY_NOCURSOR);
    client.flags |= T.CLIENT_REDRAWOVERLAY;
    return 0;
}

pub fn handle_key(client: *T.Client, event: *const T.key_event) bool {
    const pd = state(client) orelse return false;

    if ((pd.flags & POPUP_CLOSEANYKEY) != 0 and !T.keycIsMouse(event.key) and !T.keycIsPaste(event.key)) {
        clear_overlay(client);
        return true;
    }

    if (event.key == T.C0_ESC or event.key == ('c' | T.KEYC_CTRL)) {
        clear_overlay(client);
        return true;
    }

    return true;
}

fn ensure_popup_visible_ranges(r: *PopupVisibleRanges, n: u32) void {
    if (r.size >= n) return;
    if (r.ranges) |old| {
        const new = xm.allocator.realloc(old, n) catch unreachable;
        for (new[r.size..n]) |*slot| slot.* = .{};
        r.ranges = new;
    } else {
        const new = xm.allocator.alloc(PopupVisibleRange, n) catch unreachable;
        for (new) |*slot| slot.* = .{};
        r.ranges = new;
    }
    r.size = n;
}

/// Parts of the input range not covered by the popup (tmux `server_client_overlay_range`).
fn popup_overlay_range(
    x: u32,
    y: u32,
    sx: u32,
    sy: u32,
    px: u32,
    py: u32,
    nx: u32,
    out: *PopupVisibleRanges,
) void {
    if (py < y or py > y + sy -| 1) {
        ensure_popup_visible_ranges(out, 1);
        out.ranges.?[0].px = px;
        out.ranges.?[0].nx = nx;
        out.used = 1;
        return;
    }
    ensure_popup_visible_ranges(out, 2);

    if (px < x) {
        out.ranges.?[0].px = px;
        out.ranges.?[0].nx = @min(x - px, nx);
    } else {
        out.ranges.?[0].px = 0;
        out.ranges.?[0].nx = 0;
    }

    const ox = if (px > x + sx) px else x + sx;
    const onx = px + nx;
    if (onx > ox) {
        out.ranges.?[1].px = ox;
        out.ranges.?[1].nx = onx - ox;
    } else {
        out.ranges.?[1].px = 0;
        out.ranges.?[1].nx = 0;
    }
    out.used = 2;
}

/// Re-read option-backed popup styles (tmux `popup_reapply_styles`).
pub fn popup_reapply_styles(pd: *PopupData) void {
    apply_styles(pd);
}

/// Request overlay redraw (tmux `popup_redraw_cb`).
pub fn popup_redraw_cb(ttyctx: *const PopupTtyCtx) void {
    const pd: *PopupData = @ptrCast(@alignCast(ttyctx.arg orelse return));
    pd.client.flags |= T.CLIENT_REDRAWOVERLAY;
}

/// Configure tty draw offsets for the popup pane (tmux `popup_set_client_cb`). Returns 1 if `c` owns the ctx.
pub fn popup_set_client_cb(ttyctx: *PopupTtyCtx, c: *T.Client) i32 {
    const pd: *PopupData = @ptrCast(@alignCast(ttyctx.arg orelse return 0));
    if (c != pd.client) return 0;
    if ((pd.client.flags & T.CLIENT_REDRAWOVERLAY) != 0) return 0;

    ttyctx.bigger = 0;
    ttyctx.wox = 0;
    ttyctx.woy = 0;
    ttyctx.wsx = c.tty.sx;
    ttyctx.wsy = c.tty.sy;

    if (pd.border_lines == POPUP_BORDER_NONE) {
        ttyctx.xoff = pd.px;
        ttyctx.rxoff = pd.px;
        ttyctx.yoff = pd.py;
        ttyctx.ryoff = pd.py;
    } else {
        ttyctx.xoff = pd.px + 1;
        ttyctx.rxoff = pd.px + 1;
        ttyctx.yoff = pd.py + 1;
        ttyctx.ryoff = pd.py + 1;
    }
    return 1;
}

/// Initialize tty context for writes into the popup screen (tmux `popup_init_ctx_cb`).
/// Callers must set `ttyctx.arg` to the [`PopupData`] pointer before calling (tmux passes it via `ctx->arg`).
pub fn popup_init_ctx_cb(ctx: *T.ScreenWriteCtx, ttyctx: *PopupTtyCtx) void {
    const pd: *PopupData = @ptrCast(@alignCast(ttyctx.arg orelse return));
    ttyctx.defaults = pd.defaults;
    ttyctx.arg = pd;
    _ = ctx;
}

/// Mode cursor screen for the popup (tmux `popup_mode_cb`). Menu integration is not wired yet.
pub fn popup_mode_cb(_: *T.Client, data: ?*anyopaque, cx: *u32, cy: *u32) ?*T.Screen {
    const pd: *PopupData = @ptrCast(@alignCast(data orelse return null));
    const scr = pd.screen orelse return null;
    if (pd.border_lines == POPUP_BORDER_NONE) {
        cx.* = pd.px + scr.cx;
        cy.* = pd.py + scr.cy;
    } else {
        cx.* = pd.px + 1 + scr.cx;
        cy.* = pd.py + 1 + scr.cy;
    }
    return scr;
}

/// Menu-aware path is a stub; without overlay menu, ranges match tmux `popup_check_cb` non-menu branch.
pub fn popup_check_cb(
    _: *T.Client,
    data: ?*anyopaque,
    px: u32,
    py: u32,
    nx: u32,
) *PopupVisibleRanges {
    const pd: *PopupData = @ptrCast(@alignCast(data orelse return &popup_check_null_data_fallback));
    popup_overlay_range(pd.px, pd.py, pd.sx, pd.sy, px, py, nx, &pd.overlay_ranges);
    return &pd.overlay_ranges;
}

/// Draw the popup into the client (tmux `popup_draw_cb`).
pub fn popup_draw_cb(c: *T.Client, data: ?*anyopaque, _: *PopupScreenRedrawCtx) void {
    const pd: *PopupData = @ptrCast(@alignCast(data orelse return));
    const tty = &c.tty;

    popup_reapply_styles(pd);

    const s = screen_mod.screen_init(pd.sx, pd.sy, 0);
    defer {
        screen_mod.screen_free(s);
        xm.allocator.destroy(s);
    }
    s.cursor_visible = false;

    fill_rect(s.grid, 0, 0, pd.sx, pd.sy, &pd.defaults);
    if (pd.border_lines == POPUP_BORDER_NONE) {
        if (pd.screen) |inner| blit_screen(s.grid, 0, 0, inner);
    } else if (pd.sx > 2 and pd.sy > 2) {
        fill_rect(s.grid, 0, 0, pd.sx, pd.sy, &pd.border_cell);
        fill_rect(s.grid, 1, 1, pd.sx - 2, pd.sy - 2, &pd.defaults);
        draw_border(pd, s);
        draw_title(pd, s);
        if (pd.screen) |inner| blit_screen(s.grid, 1, 1, inner);
    }

    var defaults = pd.defaults;
    if (defaults.fg == 8) defaults.fg = pd.palette.fg;
    if (defaults.bg == 8) defaults.bg = pd.palette.bg;

    for (0..pd.sy) |i| {
        tty_draw.tty_draw_line(tty, s, 0, @intCast(i), pd.sx, pd.px, pd.py + @as(u32, @intCast(i)), &defaults, &pd.palette);
    }
}

/// Tear down overlay-owned state (tmux `popup_free_cb`).
pub fn popup_free_cb(c: *T.Client, data: ?*anyopaque) void {
    const pd: *PopupData = @ptrCast(@alignCast(data orelse return));

    if (pd.close_cb) |cb| cb(pd.command_status, pd.close_cb_arg);

    if (pd.item) |item| {
        if (cmdq.cmdq_get_client(item)) |item_client| {
            if (item_client.session == null)
                item_client.retval = pd.command_status;
        }
        cmdq.cmdq_continue(item);
    }

    server_client.server_client_unref(c);

    pd.deinit();
    xm.allocator.destroy(pd);
}

/// Adjust popup geometry on tty resize (tmux `popup_resize_cb`).
pub fn popup_resize_cb(_: *T.Client, data: ?*anyopaque) void {
    const pd: *PopupData = @ptrCast(@alignCast(data orelse return));
    const tty = &pd.client.tty;

    if (pd.psy > tty.sy)
        pd.sy = tty.sy
    else
        pd.sy = pd.psy;
    if (pd.psx > tty.sx)
        pd.sx = tty.sx
    else
        pd.sx = pd.psx;
    if (pd.ppy + pd.sy > tty.sy)
        pd.py = tty.sy - pd.sy
    else
        pd.py = pd.ppy;
    if (pd.ppx + pd.sx > tty.sx)
        pd.px = tty.sx - pd.sx
    else
        pd.px = pd.ppx;

    rebuild_screen(pd);
    pd.client.flags |= T.CLIENT_REDRAWOVERLAY;
}

/// Promote popup PTY into a split pane (tmux `popup_make_pane`).
pub fn popup_make_pane(pd: *PopupData, layout_type: PopupLayoutType) void {
    const c = pd.client;
    const s = c.session orelse return;
    const wl = s.curw orelse return;
    const w = wl.window;
    const wp = w.active orelse return;

    _ = window_mod.window_unzoom(w);

    const zig_type: T.LayoutType = switch (layout_type) {
        .leftright => .leftright,
        .topbottom => .topbottom,
    };

    const lc = layout_mod.layout_split_pane(wp, zig_type, -1, 0) orelse return;

    const new_wp = window_mod.window_add_pane(w, null, lc.sx, lc.sy);
    layout_mod.layout_assign_pane(lc, new_wp, 0);

    if (pd.job) |j| {
        new_wp.fd = j.fd;
        new_wp.pid = j.pid;
        j.fd = -1;
        pd.job = null;
    }

    if (pd.screen) |ps| {
        if (ps.title) |t| _ = screen_mod.screen_set_title(&new_wp.base, t);
        screen_mod.screen_free(&new_wp.base);
        new_wp.base = ps.*;
        screen_mod.screen_resize(&new_wp.base, new_wp.sx, new_wp.sy);
        pd.screen = screen_mod.screen_init(1, 1, 0);
    }

    window_mod.window_pane_set_event(new_wp);
    _ = window_mod.window_set_active_pane(w, new_wp, true);
    new_wp.flags |= T.PANE_CHANGED;

    pd.close_pending = true;
}

/// Context menu selection (tmux `popup_menu_done`).
pub fn popup_menu_done(_menu: ?*anyopaque, _choice: u32, key: T.key_code, data: ?*anyopaque) void {
    _ = _menu;
    _ = _choice;
    const pd: *PopupData = @ptrCast(@alignCast(data orelse return));
    const c = pd.client;

    server_fn.server_redraw_client(c);

    switch (key) {
        'F' => {
            pd.sx = c.tty.sx;
            pd.sy = c.tty.sy;
            pd.px = 0;
            pd.py = 0;
        },
        'C' => {
            pd.px = c.tty.sx / 2 - pd.sx / 2;
            pd.py = c.tty.sy / 2 - pd.sy / 2;
        },
        'h' => popup_make_pane(pd, .leftright),
        'v' => popup_make_pane(pd, .topbottom),
        'q' => pd.close_pending = true,
        else => {},
    }
}

/// Mouse move/resize drag (tmux `popup_handle_drag`).
pub fn popup_handle_drag(c: *T.Client, pd: *PopupData, m: *const T.MouseEvent) void {
    var px: u32 = undefined;
    var py: u32 = undefined;

    if (!T.mouseDrag(m.b))
        pd.dragging = .off
    else if (pd.dragging == .move) {
        if (m.x < pd.dx)
            px = 0
        else if (m.x - pd.dx + pd.sx > c.tty.sx)
            px = c.tty.sx - pd.sx
        else
            px = m.x - pd.dx;
        if (m.y < pd.dy)
            py = 0
        else if (m.y - pd.dy + pd.sy > c.tty.sy)
            py = c.tty.sy - pd.sy
        else
            py = m.y - pd.dy;
        pd.px = px;
        pd.py = py;
        pd.dx = m.x - pd.px;
        pd.dy = m.y - pd.py;
        pd.ppx = px;
        pd.ppy = py;
        c.flags |= T.CLIENT_REDRAWOVERLAY;
    } else if (pd.dragging == .size) {
        if (pd.border_lines == POPUP_BORDER_NONE) {
            if (m.x < pd.px + 1 or m.y < pd.py + 1) return;
        } else {
            if (m.x < pd.px + 3 or m.y < pd.py + 3) return;
        }
        pd.sx = m.x - pd.px;
        pd.sy = m.y - pd.py;
        pd.psx = pd.sx;
        pd.psy = pd.sy;

        rebuild_screen(pd);
        c.flags |= T.CLIENT_REDRAWOVERLAY;
    }

    pd.lx = m.x;
    pd.ly = m.y;
    pd.lb = m.b;
}

/// Key / mouse dispatch (tmux `popup_key_cb`). Returns 1 to request closing the overlay; 0 otherwise.
pub fn popup_key_cb(c: *T.Client, data: ?*anyopaque, event: *const T.key_event) i32 {
    const pd: *PopupData = @ptrCast(@alignCast(data orelse return 0));
    const cur = state(c) orelse return 0;
    if (pd != cur) return 0;

    if (T.keycIsMouse(event.key)) {
        const m = &event.m;
        if (pd.dragging != .off) {
            popup_handle_drag(c, pd, m);
            return 0;
        }
        if (m.x < pd.px or m.x > pd.px + pd.sx - 1 or
            m.y < pd.py or m.y > pd.py + pd.sy - 1)
        {
            return 0;
        }
        var border: enum { none, left, right, top, bottom } = .none;
        if (pd.border_lines != POPUP_BORDER_NONE) {
            if (m.x == pd.px) {
                border = .left;
            } else if (m.x == pd.px + pd.sx - 1) {
                border = .right;
            } else if (m.y == pd.py) {
                border = .top;
            } else if (m.y == pd.py + pd.sy - 1) {
                border = .bottom;
            }
        }
        if ((m.b & T.MOUSE_MASK_MODIFIERS) == 0 and
            T.mouseButtons(m.b) == T.MOUSE_BUTTON_3 and
            (border == .left or border == .top))
        {
            popupDisplayMenu(c, pd, m);
            return 0;
        }
        if (((m.b & T.MOUSE_MASK_MODIFIERS) == T.MOUSE_MASK_META) or
            (border != .none and !T.mouseDrag(m.lb)))
        {
            if (!T.mouseDrag(m.b)) return 0;
            if (T.mouseButtons(m.lb) == T.MOUSE_BUTTON_1)
                pd.dragging = .move
            else if (T.mouseButtons(m.lb) == T.MOUSE_BUTTON_3)
                pd.dragging = .size;
            pd.dx = m.lx - pd.px;
            pd.dy = m.ly - pd.py;
            return 0;
        }
    }

    if (event.key == T.C0_ESC or event.key == ('c' | T.KEYC_CTRL))
        return 1;
    if ((pd.flags & POPUP_CLOSEANYKEY) != 0 and
        !T.keycIsMouse(event.key) and !T.keycIsPaste(event.key))
    {
        return 1;
    }
    return 0;
}

/// Build and display the popup context menu (tmux `popup_key_cb` menu: label).
fn popupDisplayMenu(c: *T.Client, pd: *PopupData, m: *const T.MouseEvent) void {
    const items: []const menu_mod.MenuItemTemplate = if ((pd.flags & POPUP_INTERNAL) != 0)
        &popup_internal_menu_items
    else
        &popup_menu_items;

    const menu = menu_mod.menu_create("");
    menu_mod.menu_add_items(menu, items);

    var x: u32 = m.x;
    const half = (menu.width + 4) / 2;
    if (x >= half)
        x -= half
    else
        x = 0;

    if (menu_mod.menu_display(menu, 0, 0, null, x, m.y, c, 0, null, null, null, null) != 0) {
        menu.deinit();
    } else {
        c.flags |= T.CLIENT_REDRAWOVERLAY;
    }
}

/// Job output hook (tmux `popup_job_update_cb`).
/// Full input parsing (ictx + bufferevent) is not yet wired; mark dirty so
/// any content written via popup_write is visible.
pub fn popup_job_update_cb(data: ?*anyopaque) void {
    const pd: *PopupData = @ptrCast(@alignCast(data orelse return));
    pd.client.flags |= T.CLIENT_REDRAWOVERLAY;
}

/// Job exit hook (tmux `popup_job_complete_cb`).
pub fn popup_job_complete_cb(data: ?*anyopaque) void {
    const pd: *PopupData = @ptrCast(@alignCast(data orelse return));
    const j = pd.job orelse return;

    const raw_status = j.status;
    if (std.c.WIFEXITED(raw_status)) {
        pd.command_status = std.c.WEXITSTATUS(raw_status);
    } else if (std.c.WIFSIGNALED(raw_status)) {
        pd.command_status = std.c.WTERMSIG(raw_status);
    } else {
        pd.command_status = 0;
    }
    pd.job = null;

    if ((pd.flags & POPUP_CLOSEEXIT) != 0 or
        ((pd.flags & POPUP_CLOSEEXITZERO) != 0 and pd.command_status == 0))
    {
        server_client.server_client_clear_overlay(pd.client);
    }
}

pub fn popup_editor_free(pe: *PopupEditor) void {
    if (pe.path) |p| {
        std.fs.deleteFileAbsolute(p) catch {};
        xm.allocator.free(p);
    }
    xm.allocator.destroy(pe);
}

/// Close callback for editor popups (tmux `popup_editor_close_cb`).
pub fn popup_editor_close_cb(exit_status: i32, arg: ?*anyopaque) void {
    const pe: *PopupEditor = @ptrCast(@alignCast(arg orelse return));

    if (exit_status != 0) {
        if (pe.cb) |cb| cb(null, 0, pe.arg);
        popup_editor_free(pe);
        return;
    }

    const path = pe.path orelse {
        if (pe.cb) |cb| cb(null, 0, pe.arg);
        popup_editor_free(pe);
        return;
    };

    var buf: ?[]u8 = null;
    var len: usize = 0;

    read_file: {
        const f = std.fs.openFileAbsolute(path, .{ .mode = .read_only }) catch break :read_file;
        defer f.close();
        const stat = f.stat() catch break :read_file;
        const file_len = stat.size;
        if (file_len == 0) break :read_file;
        const raw = xm.allocator.alloc(u8, @intCast(file_len)) catch break :read_file;
        const n = f.readAll(raw) catch {
            xm.allocator.free(raw);
            break :read_file;
        };
        if (n != @as(usize, @intCast(file_len))) {
            xm.allocator.free(raw);
            break :read_file;
        }
        buf = raw;
        len = n;
    }

    if (pe.cb) |cb| cb(buf, len, pe.arg);
    popup_editor_free(pe);
}

/// External editor in a popup (tmux `popup_editor`).
pub fn popup_editor(c: *T.Client, buf: []const u8, len: usize, cb: ?PopupFinishEditCb, arg: ?*anyopaque) i32 {
    _ = len; // buf.len is authoritative

    const editor = opts_mod.options_get_string(opts_mod.global_options, "editor");
    if (editor.len == 0) return -1;

    var tmp_path_buf: [64]u8 = undefined;
    const tmp_path = std.fmt.bufPrint(&tmp_path_buf, "/tmp/zmux.{d}", .{std.os.linux.getpid()}) catch return -1;

    write_tmp: {
        const f = std.fs.createFileAbsolute(tmp_path, .{ .truncate = true }) catch return -1;
        defer f.close();
        f.writeAll(buf) catch break :write_tmp;
        break :write_tmp;
    }

    const pe = xm.allocator.create(PopupEditor) catch {
        std.fs.deleteFileAbsolute(tmp_path) catch {};
        return -1;
    };
    pe.* = .{
        .path = xm.xstrdup(tmp_path),
        .cb = cb,
        .arg = arg,
    };

    const sx = c.tty.sx * 9 / 10;
    const sy = c.tty.sy * 9 / 10;
    const px = c.tty.sx / 2 - sx / 2;
    const py = c.tty.sy / 2 - sy / 2;

    const cmd = std.fmt.allocPrint(xm.allocator, "{s} {s}", .{ editor, tmp_path }) catch {
        popup_editor_free(pe);
        return -1;
    };
    defer xm.allocator.free(cmd);

    const rc = popup_display(
        POPUP_INTERNAL | POPUP_CLOSEEXIT,
        1, // BOX_LINES_DEFAULT mapped to single border
        null,
        px,
        py,
        sx,
        sy,
        editor,
        c,
        null,
        null,
        null,
        cmd,
    );
    if (rc != 0) {
        popup_editor_free(pe);
        return -1;
    }
    if (state(c)) |pd| {
        pd.close_cb = popup_editor_close_cb;
        pd.close_cb_arg = pe;
    }
    return 0;
}

pub fn render_overlay_payload_region(
    client: *T.Client,
    view_x: u32,
    view_y: u32,
    tty_sx: u32,
    pane_area_sy: u32,
    row_offset: u32,
) !?[]u8 {
    const pd = state(client) orelse return null;
    const screen = pd.screen orelse return null;
    const bounds = clipped_bounds_region(pd.px, pd.py, pd.sx, pd.sy, view_x, view_y, tty_sx, pane_area_sy) orelse return null;
    return try tty_draw.tty_draw_render_screen_region(
        screen,
        bounds.xoff + view_x - pd.px,
        bounds.yoff + view_y - pd.py,
        bounds.sx,
        bounds.sy,
        row_offset + bounds.yoff,
        bounds.xoff,
    );
}

fn available_height(client: *const T.Client) u32 {
    const overlay_rows = status.overlay_rows(@constCast(client));
    return if (client.tty.sy > overlay_rows) client.tty.sy - overlay_rows else 0;
}

fn replace_optional_string(slot: *?[]u8, value: ?[]const u8) void {
    if (slot.*) |existing| xm.allocator.free(existing);
    slot.* = if (value) |text| xm.xstrdup(text) else null;
}

fn apply_styles(pd: *PopupData) void {
    const session = pd.client.session orelse return;
    const wl = session.curw orelse return;
    const options = wl.window.options;
    var parsed: T.Style = .{};

    pd.defaults = T.grid_default_cell;
    style_mod.style_apply(&pd.defaults, options, "popup-style", null);
    if (pd.style) |style| {
        style_mod.style_set(&parsed, &T.grid_default_cell);
        if (style_mod.style_parse(&parsed, &pd.defaults, style) == 0) {
            pd.defaults.attr = parsed.gc.attr;
            pd.defaults.fg = parsed.gc.fg;
            pd.defaults.bg = parsed.gc.bg;
            pd.defaults.us = parsed.gc.us;
        }
    }
    pd.defaults.flags &= ~@as(u8, T.GRID_FLAG_PADDING);

    pd.border_cell = T.grid_default_cell;
    style_mod.style_apply(&pd.border_cell, options, "popup-border-style", null);
    if (pd.border_style) |style| {
        style_mod.style_set(&parsed, &T.grid_default_cell);
        if (style_mod.style_parse(&parsed, &pd.border_cell, style) == 0) {
            pd.border_cell.attr = parsed.gc.attr;
            pd.border_cell.fg = parsed.gc.fg;
            pd.border_cell.bg = parsed.gc.bg;
            pd.border_cell.us = parsed.gc.us;
        }
    }
    pd.border_cell.flags &= ~@as(u8, T.GRID_FLAG_PADDING);
}

fn rebuild_screen(pd: *PopupData) void {
    if (pd.screen) |screen| {
        screen_mod.screen_free(screen);
        xm.allocator.destroy(screen);
    }

    const screen = screen_mod.screen_init(pd.sx, pd.sy, 0);
    screen.cursor_visible = false;
    pd.screen = screen;

    fill_rect(screen.grid, 0, 0, pd.sx, pd.sy, &pd.defaults);
    if (pd.border_lines != 6 and pd.sx >= 3 and pd.sy >= 3) {
        fill_rect(screen.grid, 0, 0, pd.sx, pd.sy, &pd.border_cell);
        fill_rect(screen.grid, 1, 1, pd.sx - 2, pd.sy - 2, &pd.defaults);
        draw_border(pd, screen);
        draw_title(pd, screen);
    }

    const inner_x: u32 = if (pd.border_lines == 6) 0 else 1;
    const inner_y: u32 = if (pd.border_lines == 6) 0 else 1;
    const inner_sx: u32 = if (pd.border_lines == 6) pd.sx else pd.sx - 2;
    const inner_sy: u32 = if (pd.border_lines == 6) pd.sy else pd.sy - 2;
    if (inner_sx == 0 or inner_sy == 0) return;

    const body = screen_mod.screen_init(inner_sx, inner_sy, 0);
    defer {
        screen_mod.screen_free(body);
        xm.allocator.destroy(body);
    }
    body.cursor_visible = false;

    var body_ctx = T.ScreenWriteCtx{ .s = body };
    screen_write.putn(&body_ctx, pd.content.items);
    apply_screen_style(body, &pd.defaults);
    blit_screen(screen.grid, inner_x, inner_y, body);
}

fn draw_border(pd: *PopupData, screen: *T.Screen) void {
    const top_bottom = border_glyph(pd.client, pd.border_lines, tty_acs.CELL_LEFTRIGHT);
    const left_right = border_glyph(pd.client, pd.border_lines, tty_acs.CELL_TOPBOTTOM);
    const top_left = border_glyph(pd.client, pd.border_lines, tty_acs.CELL_TOPLEFT);
    const top_right = border_glyph(pd.client, pd.border_lines, tty_acs.CELL_TOPRIGHT);
    const bottom_left = border_glyph(pd.client, pd.border_lines, tty_acs.CELL_BOTTOMLEFT);
    const bottom_right = border_glyph(pd.client, pd.border_lines, tty_acs.CELL_BOTTOMRIGHT);

    var cell = pd.border_cell;
    cell.data = top_left;
    grid.set_cell(screen.grid, 0, 0, &cell);
    cell.data = top_right;
    grid.set_cell(screen.grid, 0, pd.sx - 1, &cell);
    cell.data = bottom_left;
    grid.set_cell(screen.grid, pd.sy - 1, 0, &cell);
    cell.data = bottom_right;
    grid.set_cell(screen.grid, pd.sy - 1, pd.sx - 1, &cell);

    cell.data = top_bottom;
    for (1..pd.sx - 1) |x| grid.set_cell(screen.grid, 0, @intCast(x), &cell);
    for (1..pd.sx - 1) |x| grid.set_cell(screen.grid, pd.sy - 1, @intCast(x), &cell);

    cell.data = left_right;
    for (1..pd.sy - 1) |y| grid.set_cell(screen.grid, @intCast(y), 0, &cell);
    for (1..pd.sy - 1) |y| grid.set_cell(screen.grid, @intCast(y), pd.sx - 1, &cell);
}

fn draw_title(pd: *PopupData, screen: *T.Screen) void {
    const title = pd.title orelse return;
    if (title.len == 0 or pd.sx <= 4) return;

    const title_screen = screen_mod.screen_init(pd.sx - 4, 1, 0);
    defer {
        screen_mod.screen_free(title_screen);
        xm.allocator.destroy(title_screen);
    }

    var ctx = T.ScreenWriteCtx{ .s = title_screen };
    screen_write.putn(&ctx, title);
    apply_screen_style(title_screen, &pd.border_cell);
    blit_screen(screen.grid, 2, 0, title_screen);
}

fn blit_screen(dst: *T.Grid, dst_x: u32, dst_y: u32, src: *T.Screen) void {
    var cell: T.GridCell = undefined;
    for (0..src.grid.sy) |row| {
        for (0..src.grid.sx) |col| {
            grid.get_cell(src.grid, @intCast(row), @intCast(col), &cell);
            grid.set_cell(dst, dst_y + @as(u32, @intCast(row)), dst_x + @as(u32, @intCast(col)), &cell);
        }
    }
}

fn apply_screen_style(screen: *T.Screen, style_cell: *const T.GridCell) void {
    var cell: T.GridCell = undefined;
    for (0..screen.grid.sy) |row| {
        for (0..screen.grid.sx) |col| {
            grid.get_cell(screen.grid, @intCast(row), @intCast(col), &cell);
            if (cell.isPadding()) continue;
            cell.attr = style_cell.attr;
            cell.fg = style_cell.fg;
            cell.bg = style_cell.bg;
            cell.us = style_cell.us;
            grid.set_cell(screen.grid, @intCast(row), @intCast(col), &cell);
        }
    }
}

fn fill_rect(gd: *T.Grid, x0: u32, y0: u32, sx: u32, sy: u32, cell: *const T.GridCell) void {
    for (0..sy) |row| {
        for (0..sx) |col| {
            grid.set_cell(gd, y0 + @as(u32, @intCast(row)), x0 + @as(u32, @intCast(col)), cell);
        }
    }
}

fn border_glyph(client: *T.Client, lines: u32, cell_type: usize) T.Utf8Data {
    return switch (lines) {
        1 => tty_acs.tty_acs_rounded_borders(cell_type).*,
        2 => tty_acs.tty_acs_double_borders(cell_type).*,
        3 => tty_acs.tty_acs_heavy_borders(cell_type).*,
        4 => simple_glyph(cell_type),
        5 => blank_glyph(),
        else => single_glyph(client, cell_type),
    };
}

fn blank_glyph() T.Utf8Data {
    var data = std.mem.zeroes(T.Utf8Data);
    utf8.utf8_set(&data, ' ');
    return data;
}

fn simple_glyph(cell_type: usize) T.Utf8Data {
    var data = std.mem.zeroes(T.Utf8Data);
    utf8.utf8_set(&data, switch (cell_type) {
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
    });
    return data;
}

fn single_glyph(client: *T.Client, cell_type: usize) T.Utf8Data {
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
    if (key == 0) return blank_glyph();

    if (tty_acs.tty_acs_get(&client.tty, key)) |bytes| {
        var data = std.mem.zeroes(T.Utf8Data);
        std.mem.copyForwards(u8, data.data[0..bytes.len], bytes);
        data.size = @intCast(bytes.len);
        data.width = 1;
        return data;
    }
    return simple_glyph(cell_type);
}

fn clipped_bounds_region(
    popup_x: u32,
    popup_y: u32,
    popup_sx: u32,
    popup_sy: u32,
    view_x: u32,
    view_y: u32,
    max_sx: u32,
    max_sy: u32,
) ?ClippedBounds {
    const start_x = @max(popup_x, view_x);
    const start_y = @max(popup_y, view_y);
    const end_x = @min(popup_x + popup_sx, view_x + max_sx);
    const end_y = @min(popup_y + popup_sy, view_y + max_sy);
    if (start_x >= end_x or start_y >= end_y) return null;
    return .{
        .xoff = start_x - view_x,
        .yoff = start_y - view_y,
        .sx = end_x - start_x,
        .sy = end_y - start_y,
    };
}
