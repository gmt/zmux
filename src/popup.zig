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
const opts = @import("options.zig");
const screen_mod = @import("screen.zig");
const screen_write = @import("screen-write.zig");
const status = @import("status.zig");
const style_mod = @import("style.zig");
const tty_acs = @import("tty-acs.zig");
const tty_draw = @import("tty-draw.zig");
const utf8 = @import("utf8.zig");
const xm = @import("xmalloc.zig");

pub const POPUP_CLOSEANYKEY: i32 = 0x1;

const PopupData = struct {
    client: *T.Client,
    item: ?*cmdq.CmdqItem = null,
    flags: i32 = 0,
    title: ?[]u8 = null,
    style: ?[]u8 = null,
    border_style: ?[]u8 = null,
    defaults: T.GridCell = T.grid_default_cell,
    border_cell: T.GridCell = T.grid_default_cell,
    border_lines: u32 = 1,
    screen: ?*T.Screen = null,
    content: std.ArrayList(u8) = .{},
    px: u32 = 0,
    py: u32 = 0,
    sx: u32 = 0,
    sy: u32 = 0,

    fn deinit(self: *PopupData) void {
        if (self.screen) |screen| {
            screen_mod.screen_free(screen);
            xm.allocator.destroy(screen);
        }
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

fn state(client: *const T.Client) ?*PopupData {
    const ptr = client.popup_data orelse return null;
    return @ptrCast(@alignCast(ptr));
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
