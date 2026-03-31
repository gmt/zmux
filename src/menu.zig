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
// Ported in part from tmux/menu.c.
// Original copyright:
//   Copyright (c) 2019 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

const std = @import("std");
const T = @import("types.zig");
const cmd_mod = @import("cmd.zig");
const cmdq = @import("cmd-queue.zig");
const format_draw = @import("format-draw.zig");
const format_mod = @import("format.zig");
const grid = @import("grid.zig");
const key_string = @import("key-string.zig");
const popup = @import("popup.zig");
const screen_mod = @import("screen.zig");
const screen_write = @import("screen-write.zig");
const status = @import("status.zig");
const status_runtime = @import("status-runtime.zig");
const style_mod = @import("style.zig");
const tty_acs = @import("tty-acs.zig");
const tty_draw = @import("tty-draw.zig");
const utf8 = @import("utf8.zig");
const xm = @import("xmalloc.zig");

pub const MENU_NOMOUSE: i32 = 0x1;
pub const MENU_TAB: i32 = 0x2;
pub const MENU_STAYOPEN: i32 = 0x4;

/// Callback invoked when a menu item is chosen (port of tmux `menu_choice_cb`).
/// Parameters: menu pointer, choice index, shortcut key, caller data.
pub const MenuChoiceCb = *const fn (*Menu, i32, T.key_code, ?*anyopaque) void;

/// Raw template for a menu item — name and command are format strings that will
/// be expanded at build time (port of tmux `struct menu_item`).
pub const MenuItemSpec = struct {
    name: []const u8,
    key: T.key_code = T.KEYC_UNKNOWN,
    command: ?[]const u8 = null,
};

pub const MenuItem = struct {
    display_text: ?[]u8 = null,
    command: ?[]u8 = null,
    key: T.key_code = T.KEYC_UNKNOWN,
    separator: bool = false,
    dimmed: bool = false,

    fn selectable(self: MenuItem) bool {
        return !self.separator and !self.dimmed;
    }

    pub fn deinit(self: *MenuItem) void {
        if (self.display_text) |text| xm.allocator.free(text);
        if (self.command) |command| xm.allocator.free(command);
        self.* = .{};
    }
};

pub const Menu = struct {
    title: []u8,
    items: []MenuItem,
    width: u32,

    pub fn deinit(self: *Menu) void {
        for (self.items) |*item| item.deinit();
        xm.allocator.free(self.items);
        xm.allocator.free(self.title);
        xm.allocator.destroy(self);
    }
};

/// Static menu-item template (tmux `struct menu_item`).
/// Used by `menu_add_item` / `menu_add_items` to build a `Menu` from a
/// compile-time table.  A sentinel entry with `name == null` terminates
/// the list for `menu_add_items`.
pub const MenuItemTemplate = struct {
    name: ?[]const u8 = null,
    key: T.key_code = T.KEYC_NONE,
    command: ?[]const u8 = null,
};

pub const Bounds = struct {
    px: u32,
    py: u32,
    sx: u32,
    sy: u32,
};

const MenuData = struct {
    client: *T.Client,
    item: ?*cmdq.CmdqItem = null,
    flags: i32 = 0,
    style: ?[]u8 = null,
    border_style: ?[]u8 = null,
    selected_style: ?[]u8 = null,
    defaults: T.GridCell = T.grid_default_cell,
    border_cell: T.GridCell = T.grid_default_cell,
    selected_cell: T.GridCell = T.grid_default_cell,
    border_lines: u32 = 0,
    target: T.CmdFindState = .{ .idx = -1 },
    screen: ?*T.Screen = null,
    px: u32 = 0,
    py: u32 = 0,
    menu: *Menu,
    choice: i32 = -1,
    cb: ?MenuChoiceCb = null,
    data: ?*anyopaque = null,

    fn deinit(self: *MenuData) void {
        if (self.screen) |screen| {
            screen_mod.screen_free(screen);
            xm.allocator.destroy(screen);
        }
        if (self.style) |style| xm.allocator.free(style);
        if (self.border_style) |style| xm.allocator.free(style);
        if (self.selected_style) |style| xm.allocator.free(style);
        self.menu.deinit();
    }
};

const ClippedBounds = struct {
    xoff: u32,
    yoff: u32,
    sx: u32,
    sy: u32,
};

fn state(client: *const T.Client) ?*MenuData {
    const ptr = client.menu_data orelse return null;
    return @ptrCast(@alignCast(ptr));
}

pub fn overlay_active(client: *const T.Client) bool {
    return client.menu_data != null;
}

pub fn overlay_wants_mouse(client: *const T.Client) bool {
    const md = state(client) orelse return false;
    return (md.flags & MENU_NOMOUSE) == 0;
}

pub fn overlay_bounds(client: *const T.Client) ?Bounds {
    const md = state(client) orelse return null;
    return .{
        .px = md.px,
        .py = md.py,
        .sx = md.menu.width + 4,
        .sy = @as(u32, @intCast(md.menu.items.len)) + 2,
    };
}

/// Allocate a new empty menu with the given title (port of tmux `menu_create`).
pub fn menu_create(title: []const u8) *Menu {
    const menu = xm.allocator.create(Menu) catch unreachable;
    menu.* = .{
        .title = xm.xstrdup(title),
        .items = xm.allocator.alloc(MenuItem, 0) catch unreachable,
        .width = format_draw.format_width(title),
    };
    return menu;
}

/// Expand a template item and append it to `menu` (port of tmux `menu_add_item`).
/// Empty `spec.name` inserts a separator; empty format expansion silently drops the item.
pub fn menu_add_item(
    menu: *Menu,
    spec: MenuItemSpec,
    qitem: ?*cmdq.CmdqItem,
    c: *T.Client,
    fs: ?*const T.CmdFindState,
) void {
    // zmux has no format_single_from_state; fs is accepted for API parity only.
    _ = fs;
    const is_separator = spec.name.len == 0;
    if (is_separator) {
        if (menu.items.len == 0) return;
        if (menu.items[menu.items.len - 1].separator) return;
        menu.items = xm.allocator.realloc(menu.items, menu.items.len + 1) catch unreachable;
        menu.items[menu.items.len - 1] = .{ .separator = true };
        return;
    }

    const raw_qitem: ?*anyopaque = if (qitem) |qi| @ptrCast(qi) else null;
    const s = format_mod.format_single(raw_qitem, spec.name, c, null, null, null);
    defer xm.allocator.free(s);

    if (s.len == 0) return; // empty expansion → skip

    const max_width: u32 = c.tty.sx -| 4;

    var key_hint: ?[]const u8 = null;
    if (s[0] != '-' and spec.key != T.KEYC_UNKNOWN and spec.key != T.KEYC_NONE) {
        const kstr = key_string.key_string_lookup_key(spec.key, 0);
        const klen: u32 = @intCast(kstr.len + 3); // space + two brackets
        if (klen <= max_width / 4) {
            key_hint = kstr;
        } else if (klen < max_width) {
            const name_len = @min(format_draw.format_width(s), max_width);
            if (name_len < max_width - klen)
                key_hint = kstr;
        }
    }

    const available: u32 = if (key_hint) |kstr|
        max_width -| @as(u32, @intCast(kstr.len + 3))
    else
        max_width;

    var suffix: []const u8 = "";
    const trimmed_width = format_draw.format_width(s);
    const trim_to: u32 = if (trimmed_width > available and available > 0) blk: {
        suffix = ">";
        break :blk available - 1;
    } else available;

    const trimmed = format_draw.format_trim_right(s, trim_to);
    defer xm.allocator.free(trimmed);

    const display: []u8 = if (key_hint) |kstr|
        xm.xasprintf("{s}{s}#[default] #[align=right]({s})", .{ trimmed, suffix, kstr })
    else
        xm.xasprintf("{s}{s}", .{ trimmed, suffix });

    const cmd_expanded: ?[]u8 = if (spec.command) |cmd_tmpl|
        format_mod.format_single(raw_qitem, cmd_tmpl, c, null, null, null)
    else
        null;

    menu.items = xm.allocator.realloc(menu.items, menu.items.len + 1) catch unreachable;
    menu.items[menu.items.len - 1] = .{
        .display_text = display,
        .command = cmd_expanded,
        .key = spec.key,
    };

    var w = format_draw.format_width(display);
    if (display.len > 0 and display[0] == '-') w -|= 1;
    if (w > menu.width) menu.width = w;
}

/// Append all specs from a slice, calling `menu_add_item` for each (port of tmux `menu_add_items`).
pub fn menu_add_items(
    menu: *Menu,
    specs: []const MenuItemSpec,
    qitem: ?*cmdq.CmdqItem,
    c: *T.Client,
    fs: ?*const T.CmdFindState,
) void {
    for (specs) |spec| menu_add_item(menu, spec, qitem, c, fs);
}

/// Prepare a MenuData without installing it on the client (port of tmux `menu_prepare`).
/// Returns null if the terminal is too small.
pub fn menu_prepare(
    menu: *Menu,
    flags: i32,
    starting_choice: i32,
    item: ?*cmdq.CmdqItem,
    px: u32,
    py: u32,
    client: *T.Client,
    lines: u32,
    style: ?[]const u8,
    selected_style: ?[]const u8,
    border_style: ?[]const u8,
    fs: ?*const T.CmdFindState,
    cb: ?MenuChoiceCb,
    data: ?*anyopaque,
) ?*MenuData {
    const sx = menu.width + 4;
    const count: u32 = @intCast(menu.items.len);
    const sy = count + 2;
    const max_sy = available_height(client);
    if (client.tty.sx < sx or max_sy < sy) return null;

    const safe_px = if (px + sx > client.tty.sx) client.tty.sx - sx else px;
    const safe_py = if (py + sy > max_sy) max_sy - sy else py;

    const md = xm.allocator.create(MenuData) catch unreachable;
    md.* = .{
        .client = client,
        .item = item,
        .flags = flags,
        .border_lines = lines,
        .target = if (fs) |target| target.* else .{ .idx = -1 },
        .px = safe_px,
        .py = safe_py,
        .menu = menu,
        .cb = cb,
        .data = data,
    };

    if (style) |value| md.style = xm.xstrdup(value);
    if (selected_style) |value| md.selected_style = xm.xstrdup(value);
    if (border_style) |value| md.border_style = xm.xstrdup(value);

    if ((flags & MENU_NOMOUSE) != 0)
        md.choice = find_initial_choice(menu, starting_choice);

    return md;
}

/// Reposition menu to stay within the terminal after a resize (port of tmux `menu_resize_cb`).
pub fn menu_resize_cb(client: *T.Client) void {
    const md = state(client) orelse return;
    const w = md.menu.width + 4;
    const h: u32 = @intCast(md.menu.items.len + 2);

    if (md.px + w > client.tty.sx) {
        md.px = if (client.tty.sx <= w) 0 else client.tty.sx - w;
    }
    if (md.py + h > client.tty.sy) {
        md.py = if (client.tty.sy <= h) 0 else client.tty.sy - h;
    }
}

pub fn clear_overlay(client: *T.Client) void {
    const md = state(client) orelse return;

    client.menu_data = null;
    client.tty.flags &= ~@as(i32, @intCast(T.TTY_NOCURSOR | T.TTY_FREEZE));
    client.flags |= T.CLIENT_REDRAWOVERLAY;

    if (md.item) |item| cmdq.cmdq_continue(item);

    md.deinit();
    xm.allocator.destroy(md);
}

pub fn menu_display(
    menu: *Menu,
    flags: i32,
    starting_choice: i32,
    item: ?*cmdq.CmdqItem,
    px: u32,
    py: u32,
    client: *T.Client,
    lines: u32,
    style: ?[]const u8,
    selected_style: ?[]const u8,
    border_style: ?[]const u8,
    fs: ?*const T.CmdFindState,
    cb: ?MenuChoiceCb,
    data: ?*anyopaque,
) i32 {
    return menu_display_cb(menu, flags, starting_choice, item, px, py, client, lines, style, selected_style, border_style, fs, cb, data);
}

/// Display a menu, optionally invoking a callback when an item is chosen
/// (port of tmux `menu_display` with `cb`/`data` arguments).
pub fn menu_display_cb(
    menu: *Menu,
    flags: i32,
    starting_choice: i32,
    item: ?*cmdq.CmdqItem,
    px: u32,
    py: u32,
    client: *T.Client,
    lines: u32,
    style: ?[]const u8,
    selected_style: ?[]const u8,
    border_style: ?[]const u8,
    fs: ?*const T.CmdFindState,
    cb: ?MenuChoiceCb,
    data: ?*anyopaque,
) i32 {
    const md = menu_prepare(menu, flags, starting_choice, item, px, py, client, lines, style, selected_style, border_style, fs, cb, data) orelse return -1;

    clear_overlay(client);
    client.menu_data = md;
    client.tty.flags |= @intCast(T.TTY_FREEZE | T.TTY_NOCURSOR);
    client.flags |= T.CLIENT_REDRAWOVERLAY;
    return 0;
}

pub fn handle_key(client: *T.Client, event: *T.key_event) bool {
    const md = state(client) orelse return false;

    if (event.key == T.KEYC_MOUSE or event.key == T.KEYC_DOUBLECLICK) {
        handle_mouse(md, event);
        return true;
    }

    const normalized = event.key & ~T.KEYC_MASK_FLAGS;
    if (select_by_shortcut(md, normalized)) {
        choose_current(client);
        return true;
    }

    switch (normalized) {
        T.KEYC_BTAB, T.KEYC_UP, 'k' => move_choice(client, -1),
        T.KEYC_BSPACE => if ((md.flags & MENU_TAB) != 0) clear_overlay(client),
        '\t', T.KEYC_DOWN, 'j' => {
            if (normalized == '\t' and (md.flags & MENU_TAB) != 0 and md.choice == @as(i32, @intCast(md.menu.items.len)) - 1)
                clear_overlay(client)
            else
                move_choice(client, 1);
        },
        T.KEYC_PPAGE, ('b' | T.KEYC_CTRL) => page_choice(client, false),
        T.KEYC_NPAGE, ('f' | T.KEYC_CTRL) => page_choice(client, true),
        'g', T.KEYC_HOME => jump_choice(client, false),
        'G', T.KEYC_END => jump_choice(client, true),
        '\r' => choose_current(client),
        '\x1b', ('c' | T.KEYC_CTRL), ('g' | T.KEYC_CTRL), 'q' => clear_overlay(client),
        else => {},
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
    const md = state(client) orelse return null;
    refresh_screen(md);
    const screen = md.screen orelse return null;
    const sx = md.menu.width + 4;
    const sy: u32 = @as(u32, @intCast(md.menu.items.len)) + 2;
    const bounds = clipped_bounds_region(md.px, md.py, sx, sy, view_x, view_y, tty_sx, pane_area_sy) orelse return null;
    return try tty_draw.tty_draw_render_screen_region(
        screen,
        bounds.xoff + view_x - md.px,
        bounds.yoff + view_y - md.py,
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

fn refresh_screen(md: *MenuData) void {
    apply_styles(md);
    rebuild_screen(md);
}

fn apply_styles(md: *MenuData) void {
    const session = md.client.session orelse return;
    const wl = session.curw orelse return;
    const options = wl.window.options;
    var parsed: T.Style = .{};

    md.defaults = T.grid_default_cell;
    style_mod.style_apply(&md.defaults, options, "menu-style", null);
    if (md.style) |style| {
        style_mod.style_set(&parsed, &T.grid_default_cell);
        if (style_mod.style_parse(&parsed, &md.defaults, style) == 0) {
            md.defaults.attr = parsed.gc.attr;
            md.defaults.fg = parsed.gc.fg;
            md.defaults.bg = parsed.gc.bg;
            md.defaults.us = parsed.gc.us;
        }
    }
    md.defaults.flags &= ~@as(u8, T.GRID_FLAG_PADDING);

    md.selected_cell = T.grid_default_cell;
    style_mod.style_apply(&md.selected_cell, options, "menu-selected-style", null);
    if (md.selected_style) |style| {
        style_mod.style_set(&parsed, &T.grid_default_cell);
        if (style_mod.style_parse(&parsed, &md.selected_cell, style) == 0) {
            md.selected_cell.attr = parsed.gc.attr;
            md.selected_cell.fg = parsed.gc.fg;
            md.selected_cell.bg = parsed.gc.bg;
            md.selected_cell.us = parsed.gc.us;
        }
    }
    md.selected_cell.flags &= ~@as(u8, T.GRID_FLAG_PADDING);

    md.border_cell = T.grid_default_cell;
    style_mod.style_apply(&md.border_cell, options, "menu-border-style", null);
    if (md.border_style) |style| {
        style_mod.style_set(&parsed, &T.grid_default_cell);
        if (style_mod.style_parse(&parsed, &md.border_cell, style) == 0) {
            md.border_cell.attr = parsed.gc.attr;
            md.border_cell.fg = parsed.gc.fg;
            md.border_cell.bg = parsed.gc.bg;
            md.border_cell.us = parsed.gc.us;
        }
    }
    md.border_cell.flags &= ~@as(u8, T.GRID_FLAG_PADDING);
}

fn rebuild_screen(md: *MenuData) void {
    if (md.screen) |screen| {
        screen_mod.screen_free(screen);
        xm.allocator.destroy(screen);
    }

    const sx = md.menu.width + 4;
    const sy: u32 = @as(u32, @intCast(md.menu.items.len)) + 2;
    const screen = screen_mod.screen_init(sx, sy, 0);
    screen.cursor_visible = false;
    md.screen = screen;

    fill_rect(screen.grid, 0, 0, sx, sy, &md.defaults);
    if (md.border_lines != 6 and sx >= 3 and sy >= 3) {
        fill_rect(screen.grid, 0, 0, sx, sy, &md.border_cell);
        fill_rect(screen.grid, 1, 1, sx - 2, sy - 2, &md.defaults);
        draw_border(md, screen);
        draw_title(md, screen);
    }

    var ctx = T.ScreenWriteCtx{ .s = screen };
    for (md.menu.items, 0..) |item, idx| {
        const row: u32 = 1 + @as(u32, @intCast(idx));
        if (item.separator) {
            draw_separator(md, screen, row);
            continue;
        }

        const selected = md.choice == @as(i32, @intCast(idx)) and item.selectable();
        var base = if (selected) md.selected_cell else md.defaults;
        fill_rect(screen.grid, 1, row, md.menu.width + 2, 1, &base);

        const text = item.display_text orelse continue;
        var text_cell = base;
        if (item.dimmed) text_cell.attr |= T.GRID_ATTR_DIM;
        screen_write.cursor_to(&ctx, row, 2);
        format_draw.format_draw(&ctx, &text_cell, md.menu.width, text);
    }
}

fn draw_separator(md: *MenuData, screen: *T.Screen, row: u32) void {
    if (md.border_lines == 6) return;

    const left = border_glyph(md.client, md.border_lines, tty_acs.CELL_LEFTJOIN);
    const join = border_glyph(md.client, md.border_lines, tty_acs.CELL_LEFTRIGHT);
    const right = border_glyph(md.client, md.border_lines, tty_acs.CELL_RIGHTJOIN);

    var cell = md.border_cell;
    cell.data = left;
    grid.set_cell(screen.grid, row, 0, &cell);
    cell.data = right;
    grid.set_cell(screen.grid, row, md.menu.width + 3, &cell);

    cell.data = join;
    for (1..md.menu.width + 3) |x| {
        grid.set_cell(screen.grid, row, @intCast(x), &cell);
    }
}

fn draw_title(md: *MenuData, screen: *T.Screen) void {
    if (md.menu.title.len == 0 or md.menu.width == 0) return;
    var ctx = T.ScreenWriteCtx{ .s = screen };
    screen_write.cursor_to(&ctx, 0, 2);
    format_draw.format_draw(&ctx, &md.border_cell, md.menu.width, md.menu.title);
}

fn handle_mouse(md: *MenuData, event: *T.key_event) void {
    const m = &event.m;
    if ((md.flags & MENU_NOMOUSE) != 0) {
        if (T.mouseButtons(m.b) != T.MOUSE_BUTTON_1)
            clear_overlay(md.client);
        return;
    }

    const sx = md.menu.width + 4;
    const sy: u32 = @as(u32, @intCast(md.menu.items.len)) + 2;
    const inside = m.x >= md.px and m.x < md.px + sx and m.y >= md.py + 1 and m.y < md.py + sy - 1;
    if (!inside) {
        const close = if ((md.flags & MENU_STAYOPEN) == 0)
            T.mouseRelease(m.b)
        else
            !T.mouseRelease(m.b) and !T.mouseWheel(m.b) and !T.mouseDrag(m.b);
        if (close) {
            clear_overlay(md.client);
            return;
        }
        if (md.choice != -1) {
            md.choice = -1;
            md.client.flags |= T.CLIENT_REDRAWOVERLAY;
        }
        return;
    }

    const row = @as(i32, @intCast(m.y - (md.py + 1)));
    if ((md.flags & MENU_STAYOPEN) == 0) {
        if (T.mouseRelease(m.b)) {
            md.choice = row;
            choose_current(md.client);
            return;
        }
    } else if (!T.mouseWheel(m.b) and !T.mouseDrag(m.b)) {
        md.choice = row;
        choose_current(md.client);
        return;
    }

    if (md.choice != row) {
        md.choice = row;
        md.client.flags |= T.CLIENT_REDRAWOVERLAY;
    }
}

fn select_by_shortcut(md: *MenuData, key: T.key_code) bool {
    for (md.menu.items, 0..) |item, idx| {
        if (!item.selectable()) continue;
        if (key == item.key) {
            md.choice = @intCast(idx);
            return true;
        }
    }
    return false;
}

fn move_choice(client: *T.Client, delta: i32) void {
    const md = state(client) orelse return;
    const count: i32 = @intCast(md.menu.items.len);
    if (count == 0) return;

    var old = md.choice;
    if (old == -1) old = 0;
    var next = md.choice;
    while (true) {
        if (delta < 0) {
            if (next <= 0)
                next = count - 1
            else
                next -= 1;
        } else {
            if (next == -1 or next >= count - 1)
                next = 0
            else
                next += 1;
        }
        if (md.menu.items[@intCast(next)].selectable() or next == old)
            break;
    }
    if (md.choice != next) {
        md.choice = next;
        client.flags |= T.CLIENT_REDRAWOVERLAY;
    }
}

fn page_choice(client: *T.Client, forward: bool) void {
    const md = state(client) orelse return;
    const count: i32 = @intCast(md.menu.items.len);
    if (count == 0) return;
    if (md.choice == -1) md.choice = 0;

    if (!forward) {
        if (md.choice < 6) {
            md.choice = 0;
        } else {
            var remaining: usize = 5;
            while (remaining > 0 and md.choice > 0) {
                md.choice -= 1;
                if (md.choice != 0 and md.menu.items[@intCast(md.choice)].selectable())
                    remaining -= 1
                else if (md.choice == 0)
                    break;
            }
        }
    } else {
        if (md.choice > count - 6) {
            md.choice = count - 1;
        } else {
            var remaining: usize = 5;
            while (remaining > 0 and md.choice < count - 1) {
                md.choice += 1;
                if (md.choice != count - 1 and md.menu.items[@intCast(md.choice)].selectable())
                    remaining -= 1
                else if (md.choice == count - 1)
                    break;
            }
        }
        while (!md.menu.items[@intCast(md.choice)].selectable() and md.choice > 0)
            md.choice -= 1;
    }
    client.flags |= T.CLIENT_REDRAWOVERLAY;
}

fn jump_choice(client: *T.Client, to_end: bool) void {
    const md = state(client) orelse return;
    const count: i32 = @intCast(md.menu.items.len);
    if (count == 0) return;

    md.choice = if (to_end) count - 1 else 0;
    while (!md.menu.items[@intCast(md.choice)].selectable()) {
        if (to_end) {
            if (md.choice == 0) break;
            md.choice -= 1;
        } else {
            if (md.choice == count - 1) break;
            md.choice += 1;
        }
    }
    client.flags |= T.CLIENT_REDRAWOVERLAY;
}

fn choose_current(client: *T.Client) void {
    const md = state(client) orelse return;
    if (md.choice < 0 or md.choice >= @as(i32, @intCast(md.menu.items.len))) {
        clear_overlay(client);
        return;
    }

    const idx: u32 = @intCast(md.choice);
    const item = &md.menu.items[idx];
    if (!item.selectable()) {
        if ((md.flags & MENU_STAYOPEN) == 0)
            clear_overlay(client);
        return;
    }

    if (md.cb) |cb| {
        const choice = md.choice;
        const item_key = item.key;
        const cb_data = md.data;
        const menu = md.menu;
        // Null the callback before clearing so it isn't double-invoked.
        md.cb = null;
        clear_overlay(client);
        cb(menu, choice, item_key, cb_data);
        return;
    }

    if (item.command) |command| {
        queue_command(md, command);
    }
    clear_overlay(client);
}

fn queue_command(md: *MenuData, command: []const u8) void {
    var pi = T.CmdParseInput{
        .c = md.client,
        .fs = md.target,
        .item = if (md.item) |item| @ptrCast(item) else null,
    };
    const parsed = cmd_mod.cmd_parse_from_string(command, &pi);
    switch (parsed.status) {
        .success => {
            const cmdlist: *cmd_mod.CmdList = @ptrCast(@alignCast(parsed.cmdlist.?));
            if (md.item != null and md.item.?.queue != null) {
                _ = cmdq.cmdq_insert_after(md.item.?, cmdq.cmdq_get_command(@ptrCast(cmdlist), cmdq.cmdq_get_state(md.item.?)));
            } else {
                cmdq.cmdq_append_event(md.client, cmdlist, if (md.item) |item| cmdq.cmdq_get_event(item) else null);
            }
        },
        .@"error" => {
            const err = parsed.@"error" orelse xm.xstrdup("parse error");
            defer xm.allocator.free(err);
            if (md.item) |item|
                cmdq.cmdq_error(item, "{s}", .{err})
            else
                status_runtime.present_client_message(md.client, err);
        },
    }
}

fn find_initial_choice(menu: *const Menu, starting_choice: i32) i32 {
    const count: i32 = @intCast(menu.items.len);
    if (count == 0) return -1;

    if (starting_choice >= count) {
        var choice = count;
        const start = count;
        while (true) {
            const idx = choice - 1;
            if (menu.items[@intCast(idx)].selectable())
                return idx;
            choice -= 1;
            if (choice == 0)
                choice = count;
            if (choice == start)
                break;
        }
        return -1;
    }

    if (starting_choice >= 0) {
        var choice = starting_choice;
        while (true) {
            if (menu.items[@intCast(choice)].selectable())
                return choice;
            choice += 1;
            if (choice == count)
                choice = 0;
            if (choice == starting_choice)
                break;
        }
    }

    return -1;
}

fn fill_rect(gd: *T.Grid, x0: u32, y0: u32, sx: u32, sy: u32, cell: *const T.GridCell) void {
    for (0..sy) |row| {
        for (0..sx) |col| {
            grid.set_cell(gd, y0 + @as(u32, @intCast(row)), x0 + @as(u32, @intCast(col)), cell);
        }
    }
}

fn draw_border(md: *MenuData, screen: *T.Screen) void {
    const sx = md.menu.width + 4;
    const sy: u32 = @as(u32, @intCast(md.menu.items.len)) + 2;
    const top_bottom = border_glyph(md.client, md.border_lines, tty_acs.CELL_LEFTRIGHT);
    const left_right = border_glyph(md.client, md.border_lines, tty_acs.CELL_TOPBOTTOM);
    const top_left = border_glyph(md.client, md.border_lines, tty_acs.CELL_TOPLEFT);
    const top_right = border_glyph(md.client, md.border_lines, tty_acs.CELL_TOPRIGHT);
    const bottom_left = border_glyph(md.client, md.border_lines, tty_acs.CELL_BOTTOMLEFT);
    const bottom_right = border_glyph(md.client, md.border_lines, tty_acs.CELL_BOTTOMRIGHT);

    var cell = md.border_cell;
    cell.data = top_left;
    grid.set_cell(screen.grid, 0, 0, &cell);
    cell.data = top_right;
    grid.set_cell(screen.grid, 0, sx - 1, &cell);
    cell.data = bottom_left;
    grid.set_cell(screen.grid, sy - 1, 0, &cell);
    cell.data = bottom_right;
    grid.set_cell(screen.grid, sy - 1, sx - 1, &cell);

    cell.data = top_bottom;
    for (1..sx - 1) |x| {
        grid.set_cell(screen.grid, 0, @intCast(x), &cell);
        grid.set_cell(screen.grid, sy - 1, @intCast(x), &cell);
    }

    cell.data = left_right;
    for (1..sy - 1) |y| {
        grid.set_cell(screen.grid, @intCast(y), 0, &cell);
        grid.set_cell(screen.grid, @intCast(y), sx - 1, &cell);
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
    menu_x: u32,
    menu_y: u32,
    menu_sx: u32,
    menu_sy: u32,
    view_x: u32,
    view_y: u32,
    max_sx: u32,
    max_sy: u32,
) ?ClippedBounds {
    const start_x = @max(menu_x, view_x);
    const start_y = @max(menu_y, view_y);
    const end_x = @min(menu_x + menu_sx, view_x + max_sx);
    const end_y = @min(menu_y + menu_sy, view_y + max_sy);
    if (start_x >= end_x or start_y >= end_y) return null;
    return .{
        .xoff = start_x - view_x,
        .yoff = start_y - view_y,
        .sx = end_x - start_x,
        .sy = end_y - start_y,
    };
}
