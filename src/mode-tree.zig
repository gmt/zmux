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
// Ported in part from tmux/mode-tree.c.
// Original copyright:
//   Copyright (c) 2017 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

//! mode-tree.zig – shared reduced tree-mode state substrate.

const std = @import("std");
const format_draw = @import("format-draw.zig");
const key_string = @import("key-string.zig");
const screen = @import("screen.zig");
const screen_write = @import("screen-write.zig");
const server = @import("server.zig");
const sort_mod = @import("sort.zig");
const T = @import("types.zig");
const window = @import("window.zig");
const xm = @import("xmalloc.zig");

pub const SearchDir = enum {
    forward,
    backward,
};

pub const Preview = enum {
    off,
    normal,
    big,
};

pub const Item = struct {
    parent: ?*Item = null,
    itemdata: ?*anyopaque = null,
    line: u32 = 0,

    key: T.key_code = T.KEYC_NONE,
    keystr: ?[]u8 = null,
    keylen: usize = 0,

    tag: u64 = 0,
    name: []u8,
    text: ?[]u8 = null,

    expanded: bool = false,
    tagged: bool = false,

    draw_as_parent: bool = false,
    no_tag: bool = false,
    @"align": i8 = 0,

    children: std.ArrayList(*Item) = .{},
};

pub const Line = struct {
    item: *Item,
    depth: u32,
    last: bool,
    flat: bool,
};

pub const BuildCallback = *const fn (*Data) void;
pub const DrawCallback = *const fn (*Data, ?*anyopaque, *T.ScreenWriteCtx, u32, u32) void;
pub const SearchCallback = *const fn (*Data, ?*anyopaque, []const u8, bool) bool;
pub const MenuCallback = *const fn (*Data, ?*T.Client, T.key_code) void;
pub const HeightCallback = *const fn (*Data, u32) u32;
pub const KeyCallback = *const fn (*Data, ?*anyopaque, u32) T.key_code;
pub const SwapCallback = *const fn (?*anyopaque, ?*anyopaque, *T.SortCriteria) bool;
pub const SortCallback = *const fn (*T.SortCriteria) void;
pub const HelpCallback = *const fn (*u32, *[]const u8) ?[*]const ?[*:0]const u8;
pub const EachCallback = *const fn (*Data, ?*anyopaque, ?*T.Client, T.key_code) void;

pub const Config = struct {
    modedata: ?*anyopaque = null,
    preview: Preview = .normal,
    zoom: bool = false,
    buildcb: BuildCallback,
    drawcb: ?DrawCallback = null,
    searchcb: ?SearchCallback = null,
    menucb: ?MenuCallback = null,
    heightcb: ?HeightCallback = null,
    keycb: ?KeyCallback = null,
    swapcb: ?SwapCallback = null,
    sortcb: ?SortCallback = null,
    helpcb: ?HelpCallback = null,
};

pub const Data = struct {
    dead: bool = false,
    references: u32 = 1,

    wp: *T.WindowPane,
    modedata: ?*anyopaque,

    sort_crit: T.SortCriteria = .{},

    buildcb: BuildCallback,
    drawcb: ?DrawCallback,
    searchcb: ?SearchCallback,
    menucb: ?MenuCallback,
    heightcb: ?HeightCallback,
    keycb: ?KeyCallback,
    swapcb: ?SwapCallback,
    sortcb: ?SortCallback,
    helpcb: ?HelpCallback,

    children: std.ArrayList(*Item) = .{},
    saved: std.ArrayList(*Item) = .{},
    line_list: std.ArrayList(Line) = .{},

    depth: u32 = 0,
    maxdepth: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,

    offset: u32 = 0,
    current: u32 = 0,

    screen: *T.Screen,

    preview: Preview,
    zoomed: i8 = -1,
    search: ?[]u8 = null,
    filter: ?[]u8 = null,
    no_matches: bool = false,
    search_dir: SearchDir = .forward,
    search_icase: bool = false,

    pub fn getScreen(self: *Data) *T.Screen {
        return self.screen;
    }
};

// ── tmux C-name aliases (grep / port parity) ─────────────────────────────
pub const mode_tree_start = start;
pub const mode_tree_free = free;
pub const mode_tree_resize = resize;
pub const mode_tree_zoom = zoom;
pub const mode_tree_set_filter = setFilter;
pub const mode_tree_set_search = setSearch;
pub const mode_tree_cycle_preview = cyclePreview;
pub const mode_tree_build = build;
pub const mode_tree_add = add;
pub const mode_tree_draw_as_parent = drawAsParent;
pub const mode_tree_no_tag = noTag;
pub const mode_tree_align = setAlign;
pub const mode_tree_remove = remove;
pub const mode_tree_up = up;
pub const mode_tree_down = down;
pub const mode_tree_swap = swap;
pub const mode_tree_get_current = getCurrent;
pub const mode_tree_get_current_name = getCurrentName;
pub const mode_tree_expand_current = expandCurrent;
pub const mode_tree_collapse_current = collapseCurrent;
pub const mode_tree_expand = expand;
pub const mode_tree_set_current = setCurrent;
pub const mode_tree_count_tagged = countTagged;
pub const mode_tree_each_tagged = eachTagged;
pub const mode_tree_clear_all_tagged = clearAllTagged;
pub const mode_tree_tag_all = tagAll;
pub const mode_tree_toggle_current_tag = toggleCurrentTag;
pub const mode_tree_search_set = searchSet;
pub const mode_tree_draw = draw;
pub const mode_tree_key = handleKey;
pub const mode_tree_run_command = runCommand;
pub const mode_tree_display_menu = displayMenu;
pub const mode_tree_display_help = displayHelp;
pub const mode_tree_menu_callback = menuCallback;
pub const mode_tree_search_callback = searchCallbackInternal;
pub const mode_tree_filter_callback = filterCallbackInternal;
pub const mode_tree_remove_ref = removeRef;
pub const mode_tree_get_screen = Data.getScreen;
pub const mode_tree_search_free = removeRef;
pub const mode_tree_filter_free = removeRef;

pub const mode_tree_build_lines = buildLines;
pub const mode_tree_clear_lines = clearLines;
pub const mode_tree_find_item = findItem;
pub const mode_tree_free_item = freeItem;
pub const mode_tree_free_items = freeItems;
pub const mode_tree_search_forward = searchForward;
pub const mode_tree_search_backward = searchBackward;

/// tmux `mode_tree_clear_tagged(mtl)` — clear `tagged` on a list subtree.
pub fn mode_tree_clear_tagged(mtl: *std.ArrayList(*Item)) void {
    clearTaggedRecursive(mtl);
}

/// tmux `mode_tree_get_tag(mtd, tag, found)`.
pub fn mode_tree_get_tag(mtd: *Data, tag: u64, found: *u32) bool {
    if (findLineByTag(mtd, tag)) |idx| {
        found.* = idx;
        return true;
    }
    return false;
}

pub fn mode_tree_set_height(mtd: *Data) void {
    setHeight(mtd);
}

pub fn mode_tree_check_selected(mtd: *Data) void {
    checkSelected(mtd);
}

pub fn mode_tree_is_lowercase(ptr: []const u8) bool {
    return isLowercase(ptr);
}

pub fn start(wp: *T.WindowPane, config: Config) *Data {
    const screen_ptr = screen.screen_init(wp.base.grid.sx, wp.base.grid.sy, 0);
    screen_ptr.mode &= ~T.MODE_CURSOR;

    const mtd = xm.allocator.create(Data) catch unreachable;
    mtd.* = .{
        .wp = wp,
        .modedata = config.modedata,
        .buildcb = config.buildcb,
        .drawcb = config.drawcb,
        .searchcb = config.searchcb,
        .menucb = config.menucb,
        .heightcb = config.heightcb,
        .keycb = config.keycb,
        .swapcb = config.swapcb,
        .sortcb = config.sortcb,
        .helpcb = config.helpcb,
        .screen = screen_ptr,
        .preview = config.preview,
    };
    zoom(mtd, config.zoom);
    return mtd;
}

pub fn free(mtd: *Data) void {
    if (mtd.zoomed == 0 and window.window_unzoom(mtd.wp.window))
        server.server_redraw_window(mtd.wp.window);

    freeItems(&mtd.children);
    freeItems(&mtd.saved);
    clearLines(mtd);

    if (mtd.search) |value| xm.allocator.free(value);
    if (mtd.filter) |value| xm.allocator.free(value);

    screen.screen_free(mtd.screen);
    xm.allocator.destroy(mtd.screen);

    mtd.dead = true;
    removeRef(mtd);
}

pub fn resize(mtd: *Data, sx: u32, sy: u32) void {
    screen.screen_free(mtd.screen);
    xm.allocator.destroy(mtd.screen);
    mtd.screen = screen.screen_init(sx, sy, 0);
    mtd.screen.mode &= ~T.MODE_CURSOR;

    build(mtd);
    mtd.wp.flags |= T.PANE_REDRAW;
}

pub fn zoom(mtd: *Data, enabled: bool) void {
    if (!enabled) {
        mtd.zoomed = -1;
        return;
    }

    mtd.zoomed = if (mtd.wp.window.flags & T.WINDOW_ZOOMED != 0) 1 else 0;
    if (mtd.zoomed == 0 and window.window_zoom(mtd.wp))
        server.server_redraw_window(mtd.wp.window);
}

pub fn setFilter(mtd: *Data, filter: ?[]const u8) void {
    if (mtd.filter) |value| xm.allocator.free(value);
    mtd.filter = if (filter) |value|
        xm.xstrdup(value)
    else
        null;
}

pub fn setSearch(mtd: *Data, search_text: ?[]const u8) void {
    if (mtd.search) |value| xm.allocator.free(value);
    if (search_text) |value| {
        if (value.len == 0) {
            mtd.search = null;
            mtd.search_icase = false;
            return;
        }
        mtd.search = xm.xstrdup(value);
        mtd.search_icase = isLowercase(value);
        return;
    }
    mtd.search = null;
    mtd.search_icase = false;
}

pub fn cyclePreview(mtd: *Data) void {
    mtd.preview = switch (mtd.preview) {
        .off => .big,
        .normal => .off,
        .big => .normal,
    };
}

pub fn build(mtd: *Data) void {
    var selected_tag: u64 = std.math.maxInt(u64);
    if (mtd.line_list.items.len != 0 and mtd.current < mtd.line_list.items.len)
        selected_tag = mtd.line_list.items[mtd.current].item.tag;

    freeItems(&mtd.saved);
    mtd.saved = mtd.children;
    mtd.children = .{};

    if (mtd.sortcb) |sortcb| sortcb(&mtd.sort_crit);

    mtd.buildcb(mtd);
    mtd.no_matches = mtd.children.items.len == 0;
    if (mtd.no_matches and mtd.filter != null) {
        const saved_filter = mtd.filter;
        mtd.filter = null;
        mtd.buildcb(mtd);
        mtd.filter = saved_filter;
    }

    freeItems(&mtd.saved);
    mtd.saved = .{};

    clearLines(mtd);
    mtd.maxdepth = 0;
    buildLines(mtd, &mtd.children, 0);

    if (mtd.line_list.items.len != 0 and selected_tag == std.math.maxInt(u64) and mtd.current < mtd.line_list.items.len)
        selected_tag = mtd.line_list.items[mtd.current].item.tag;
    _ = setCurrent(mtd, selected_tag);

    mtd.width = mtd.screen.grid.sx;
    if (mtd.preview != .off)
        setHeight(mtd)
    else
        mtd.height = mtd.screen.grid.sy;
    checkSelected(mtd);
}

pub fn add(
    mtd: *Data,
    parent: ?*Item,
    itemdata: ?*anyopaque,
    tag: u64,
    name: []const u8,
    text: ?[]const u8,
    expanded: i8,
) *Item {
    const mti = xm.allocator.create(Item) catch unreachable;
    mti.* = .{
        .parent = parent,
        .itemdata = itemdata,
        .tag = tag,
        .name = xm.xstrdup(name),
        .text = if (text) |value| xm.xstrdup(value) else null,
    };

    if (findItem(&mtd.saved, tag)) |saved| {
        if (parent == null or parent.?.expanded)
            mti.tagged = saved.tagged;
        mti.expanded = saved.expanded;
    } else if (expanded == -1) {
        mti.expanded = true;
    } else {
        mti.expanded = expanded != 0;
    }

    if (parent) |parent_item|
        parent_item.children.append(xm.allocator, mti) catch unreachable
    else
        mtd.children.append(xm.allocator, mti) catch unreachable;

    return mti;
}

pub fn drawAsParent(mti: *Item) void {
    mti.draw_as_parent = true;
}

pub fn noTag(mti: *Item) void {
    mti.no_tag = true;
}

pub fn setAlign(mti: *Item, value: i8) void {
    mti.@"align" = value;
}

pub fn remove(mtd: *Data, mti: *Item) void {
    if (mti.parent) |parent|
        removeFromList(&parent.children, mti)
    else
        removeFromList(&mtd.children, mti);
    freeItem(mti);
}

pub fn up(mtd: *Data, wrap: bool) void {
    if (mtd.line_list.items.len == 0) return;

    if (mtd.current == 0) {
        if (wrap) {
            mtd.current = @intCast(mtd.line_list.items.len - 1);
            if (mtd.line_list.items.len >= mtd.height and mtd.height != 0)
                mtd.offset = @intCast(mtd.line_list.items.len - mtd.height);
        }
    } else {
        mtd.current -= 1;
        if (mtd.current < mtd.offset) mtd.offset -= 1;
    }
}

pub fn down(mtd: *Data, wrap: bool) bool {
    if (mtd.line_list.items.len == 0) return false;

    const last_index: u32 = @intCast(mtd.line_list.items.len - 1);
    if (mtd.current == last_index) {
        if (wrap) {
            mtd.current = 0;
            mtd.offset = 0;
        } else {
            return false;
        }
    } else {
        mtd.current += 1;
        if (mtd.current > mtd.offset + mtd.height -| 1) mtd.offset += 1;
    }
    return true;
}

pub fn swap(mtd: *Data, direction: i32) void {
    if (mtd.swapcb == null or mtd.line_list.items.len == 0) return;

    const current_depth = mtd.line_list.items[mtd.current].depth;
    var swap_with: i32 = @intCast(mtd.current);
    var swap_depth: u32 = current_depth;

    while (true) {
        if (direction < 0 and swap_with < -direction) return;
        swap_with += direction;
        if (swap_with < 0 or swap_with >= mtd.line_list.items.len) return;

        swap_depth = mtd.line_list.items[@intCast(swap_with)].depth;
        if (swap_depth <= current_depth) break;
    }
    if (swap_depth != current_depth) return;

    const current_item = mtd.line_list.items[mtd.current].item;
    const swap_item = mtd.line_list.items[@intCast(swap_with)].item;
    if (mtd.swapcb.?(current_item.itemdata, swap_item.itemdata, &mtd.sort_crit)) {
        mtd.current = @intCast(swap_with);
        build(mtd);
    }
}

pub fn getCurrent(mtd: *Data) ?*anyopaque {
    if (mtd.line_list.items.len == 0) return null;
    return mtd.line_list.items[mtd.current].item.itemdata;
}

pub fn getCurrentName(mtd: *Data) ?[]const u8 {
    if (mtd.line_list.items.len == 0) return null;
    return mtd.line_list.items[mtd.current].item.name;
}

pub fn expandCurrent(mtd: *Data) void {
    if (mtd.line_list.items.len == 0) return;
    const item = mtd.line_list.items[mtd.current].item;
    if (!item.expanded) {
        item.expanded = true;
        build(mtd);
    }
}

pub fn collapseCurrent(mtd: *Data) void {
    if (mtd.line_list.items.len == 0) return;
    const item = mtd.line_list.items[mtd.current].item;
    if (item.expanded) {
        item.expanded = false;
        build(mtd);
    }
}

pub fn expand(mtd: *Data, tag: u64) void {
    const found = findLineByTag(mtd, tag) orelse return;
    const item = mtd.line_list.items[found].item;
    if (!item.expanded) {
        item.expanded = true;
        build(mtd);
    }
}

pub fn setCurrent(mtd: *Data, tag: u64) bool {
    if (mtd.line_list.items.len == 0) {
        mtd.current = 0;
        mtd.offset = 0;
        return false;
    }

    if (findLineByTag(mtd, tag)) |found| {
        mtd.current = found;
        if (mtd.current > mtd.height -| 1)
            mtd.offset = mtd.current - mtd.height + 1
        else
            mtd.offset = 0;
        return true;
    }

    if (mtd.current >= mtd.line_list.items.len) {
        mtd.current = @intCast(mtd.line_list.items.len - 1);
        if (mtd.current > mtd.height -| 1)
            mtd.offset = mtd.current - mtd.height + 1
        else
            mtd.offset = 0;
    }
    return false;
}

pub fn countTagged(mtd: *Data) u32 {
    var tagged: u32 = 0;
    for (mtd.line_list.items) |line| {
        if (line.item.tagged) tagged += 1;
    }
    return tagged;
}

pub fn eachTagged(mtd: *Data, cb: EachCallback, client: ?*T.Client, key: T.key_code, current_fallback: bool) void {
    var fired = false;
    for (mtd.line_list.items) |line| {
        if (!line.item.tagged) continue;
        fired = true;
        cb(mtd, line.item.itemdata, client, key);
    }
    if (!fired and current_fallback and mtd.line_list.items.len != 0)
        cb(mtd, mtd.line_list.items[mtd.current].item.itemdata, client, key);
}

pub fn clearAllTagged(mtd: *Data) void {
    for (mtd.line_list.items) |line| line.item.tagged = false;
}

pub fn tagAll(mtd: *Data) void {
    for (mtd.line_list.items) |line| {
        const item = line.item;
        if ((item.parent == null and !item.no_tag) or
            (item.parent != null and item.parent.?.no_tag))
            item.tagged = true
        else
            item.tagged = false;
    }
}

pub fn toggleCurrentTag(mtd: *Data, advance: bool) void {
    if (mtd.line_list.items.len == 0) return;
    const current_item = mtd.line_list.items[mtd.current].item;
    if (current_item.no_tag) return;

    if (!current_item.tagged) {
        var parent = current_item.parent;
        while (parent) |ancestor| {
            ancestor.tagged = false;
            parent = ancestor.parent;
        }
        clearTaggedRecursive(&current_item.children);
        current_item.tagged = true;
    } else {
        current_item.tagged = false;
    }

    if (advance) _ = down(mtd, false);
}

pub fn searchSet(mtd: *Data) bool {
    if (mtd.line_list.items.len == 0) return false;

    const found_item = switch (mtd.search_dir) {
        .forward => searchForward(mtd),
        .backward => searchBackward(mtd),
    } orelse return false;
    const tag = found_item.tag;

    var loop = found_item.parent;
    while (loop) |item| {
        item.expanded = true;
        loop = item.parent;
    }

    build(mtd);
    _ = setCurrent(mtd, tag);
    mtd.wp.flags |= T.PANE_REDRAW;
    return true;
}

pub fn draw(mtd: *Data) void {
    const s = mtd.screen;

    if (mtd.line_list.items.len == 0) return;

    var gc0 = T.grid_default_cell;
    var gc = T.grid_default_cell;
    _ = &gc0;
    _ = &gc;

    const w = mtd.width;
    const h = mtd.height;

    var ctx = T.ScreenWriteCtx{ .s = s };
    screen_write.erase_screen(&ctx);

    var keylen: usize = 0;
    for (mtd.line_list.items) |line| {
        const mti = line.item;
        if (mti.key == T.KEYC_NONE) continue;
        if (mti.keylen + 3 > keylen)
            keylen = mti.keylen + 3;
    }

    const max_depth_idx = mtd.maxdepth + 1;
    var alignlen_buf: [64]usize = [_]usize{0} ** 64;
    const alignlen = alignlen_buf[0..@min(max_depth_idx, 64)];
    for (mtd.line_list.items) |line| {
        const mti = line.item;
        if (mti.@"align" != 0 and mti.name.len > alignlen[@min(line.depth, alignlen.len - 1)])
            alignlen[@min(line.depth, alignlen.len - 1)] = mti.name.len;
    }

    for (mtd.line_list.items, 0..) |line, i| {
        if (i < mtd.offset) continue;
        if (i > mtd.offset + h - 1) break;
        const mti = line.item;

        screen_write.cursor_to(&ctx, @intCast(i - mtd.offset), 0);

        var text_buf: std.ArrayList(u8) = .{};
        defer text_buf.deinit(xm.allocator);

        if (mti.key != T.KEYC_NONE) {
            text_buf.append(xm.allocator, '(') catch unreachable;
            if (mti.keystr) |ks| text_buf.appendSlice(xm.allocator, ks) catch unreachable;
            text_buf.append(xm.allocator, ')') catch unreachable;
            const pad = if (keylen > mti.keylen + 2) keylen - mti.keylen - 2 else 0;
            var p: usize = 0;
            while (p < pad) : (p += 1) text_buf.append(xm.allocator, ' ') catch unreachable;
        } else {
            var p: usize = 0;
            while (p < keylen) : (p += 1) text_buf.append(xm.allocator, ' ') catch unreachable;
        }

        if (line.flat) {
            // no symbol
        } else if (mti.children.items.len == 0) {
            text_buf.appendSlice(xm.allocator, "  ") catch unreachable;
        } else if (mti.expanded) {
            text_buf.appendSlice(xm.allocator, "- ") catch unreachable;
        } else {
            text_buf.appendSlice(xm.allocator, "+ ") catch unreachable;
        }

        if (line.depth > 0) {
            var d: u32 = 0;
            while (d < line.depth) : (d += 1)
                text_buf.appendSlice(xm.allocator, "  ") catch unreachable;
        }

        const al_idx = @min(line.depth, @as(u32, @intCast(alignlen.len -| 1)));
        const al = alignlen[al_idx];
        if (mti.@"align" > 0 and al > mti.name.len) {
            var pad = al - mti.name.len;
            while (pad > 0) : (pad -= 1) text_buf.append(xm.allocator, ' ') catch unreachable;
        }

        text_buf.appendSlice(xm.allocator, mti.name) catch unreachable;
        if (mti.tagged)
            text_buf.append(xm.allocator, '*') catch unreachable;
        if (mti.text) |t| {
            text_buf.appendSlice(xm.allocator, ": ") catch unreachable;
            text_buf.appendSlice(xm.allocator, t) catch unreachable;
        }

        screen_write.erase_to_eol(&ctx);
        const max_write: u32 = @min(@as(u32, @intCast(text_buf.items.len)), w);
        if (max_write > 0)
            screen_write.putn(&ctx, text_buf.items[0..max_write]);
    }

    if (mtd.preview == .off) {
        screen_write.cursor_to(&ctx, mtd.current -| mtd.offset, 0);
        return;
    }

    const sy = s.grid.sy;
    if (sy <= 4 or h < 2 or sy -| h <= 4 or w <= 4) {
        screen_write.cursor_to(&ctx, mtd.current -| mtd.offset, 0);
        return;
    }

    var draw_mti = mtd.line_list.items[mtd.current].item;
    if (draw_mti.draw_as_parent)
        if (draw_mti.parent) |parent| {
            draw_mti = parent;
        };

    screen_write.cursor_to(&ctx, h, 0);
    screen_write.box_draw(&ctx, w, sy - h);

    const name_text = xm.xasprintf(" {s}", .{draw_mti.name});
    defer xm.allocator.free(name_text);
    if (w >= 2 + name_text.len) {
        screen_write.cursor_to(&ctx, h, 1);
        screen_write.putn(&ctx, name_text);
        screen_write.putn(&ctx, " ");
    }

    const box_x = w -| 4;
    const box_y = sy -| h -| 2;

    if (box_x != 0 and box_y != 0) {
        screen_write.cursor_to(&ctx, h + 1, 2);
        if (mtd.drawcb) |drawcb|
            drawcb(mtd, draw_mti.itemdata, &ctx, box_x, box_y);
    }

    screen_write.cursor_to(&ctx, mtd.current -| mtd.offset, 0);
}

pub fn handleKey(mtd: *Data, client: ?*T.Client, key_val: *T.key_code, mouse: ?*const T.MouseEvent, xp: ?*u32, yp: ?*u32) bool {
    if (mtd.line_list.items.len == 0) return false;

    if (T.keycIsMouse(key_val.*) and mouse != null) {
        const m = mouse.?;
        const x = m.x;
        const y = m.y;
        if (xp) |xout| xout.* = x;
        if (yp) |yout| yout.* = y;
        if (x > mtd.width or y > mtd.height) {
            if (key_val.* == T.keycMouse(T.KEYC_MOUSEDOWN3, .pane))
                displayMenu(mtd, client, x, y, true);
            if (mtd.preview == .off)
                key_val.* = T.KEYC_NONE;
            return false;
        }
        if (mtd.offset + y < mtd.line_list.items.len) {
            if (key_val.* == T.keycMouse(T.KEYC_MOUSEDOWN1, .pane) or
                key_val.* == T.keycMouse(T.KEYC_MOUSEDOWN3, .pane) or
                key_val.* == T.keycMouse(T.KEYC_DOUBLECLICK1, .pane))
                mtd.current = mtd.offset + y;
            if (key_val.* == T.keycMouse(T.KEYC_DOUBLECLICK1, .pane)) {
                key_val.* = '\r';
            } else {
                if (key_val.* == T.keycMouse(T.KEYC_MOUSEDOWN3, .pane))
                    displayMenu(mtd, client, x, y, false);
                key_val.* = T.KEYC_NONE;
            }
        } else {
            if (key_val.* == T.keycMouse(T.KEYC_MOUSEDOWN3, .pane))
                displayMenu(mtd, client, x, y, false);
            key_val.* = T.KEYC_NONE;
        }
        return false;
    }

    const line = &mtd.line_list.items[mtd.current];
    var current = line.item;

    for (mtd.line_list.items, 0..) |l, idx| {
        if (key_val.* == l.item.key) {
            if (idx > mtd.line_list.items.len - 1) {
                key_val.* = T.KEYC_NONE;
                return false;
            }
            mtd.current = @intCast(idx);
            key_val.* = '\r';
            return false;
        }
    }

    switch (key_val.*) {
        'q', '\x1b', 'g' | T.KEYC_CTRL => return true,
        T.KEYC_F1, 'h' | T.KEYC_CTRL => displayHelp(mtd, client),
        T.KEYC_UP, 'k', T.keycMouse(T.KEYC_WHEELUP, .pane), 'p' | T.KEYC_CTRL => up(mtd, true),
        T.KEYC_DOWN, 'j', T.keycMouse(T.KEYC_WHEELDOWN, .pane), 'n' | T.KEYC_CTRL => _ = down(mtd, true),
        T.KEYC_UP | T.KEYC_SHIFT, 'K' => swap(mtd, -1),
        T.KEYC_DOWN | T.KEYC_SHIFT, 'J' => swap(mtd, 1),
        T.KEYC_PPAGE, 'b' | T.KEYC_CTRL => {
            var i: u32 = 0;
            while (i < mtd.height) : (i += 1) {
                if (mtd.current == 0) break;
                up(mtd, true);
            }
        },
        T.KEYC_NPAGE, 'f' | T.KEYC_CTRL => {
            var i: u32 = 0;
            while (i < mtd.height) : (i += 1) {
                if (mtd.current == mtd.line_list.items.len - 1) break;
                _ = down(mtd, true);
            }
        },
        'g', T.KEYC_HOME => {
            mtd.current = 0;
            mtd.offset = 0;
        },
        'G', T.KEYC_END => {
            mtd.current = @intCast(mtd.line_list.items.len - 1);
            if (mtd.current > mtd.height -| 1)
                mtd.offset = mtd.current - mtd.height + 1
            else
                mtd.offset = 0;
        },
        't' => {
            if (!current.no_tag) {
                if (!current.tagged) {
                    var parent = current.parent;
                    while (parent) |ancestor| {
                        ancestor.tagged = false;
                        parent = ancestor.parent;
                    }
                    clearTaggedRecursive(&current.children);
                    current.tagged = true;
                } else {
                    current.tagged = false;
                }
                if (mouse != null) _ = down(mtd, false);
            }
        },
        'T' => {
            for (mtd.line_list.items) |l| l.item.tagged = false;
        },
        't' | T.KEYC_CTRL => {
            for (mtd.line_list.items) |l| {
                if ((l.item.parent == null and !l.item.no_tag) or
                    (l.item.parent != null and l.item.parent.?.no_tag))
                    l.item.tagged = true
                else
                    l.item.tagged = false;
            }
        },
        'O' => {
            sort_mod.sort_next_order(&mtd.sort_crit);
            build(mtd);
        },
        'r' => {
            mtd.sort_crit.reversed = !mtd.sort_crit.reversed;
            build(mtd);
        },
        T.KEYC_LEFT, 'h', '-' => {
            if (line.flat or !current.expanded)
                current = current.parent orelse current;
            if (current.parent == null and (line.flat or !mtd.line_list.items[mtd.current].item.expanded)) {
                up(mtd, false);
            } else {
                current.expanded = false;
                mtd.current = current.line;
                build(mtd);
            }
        },
        T.KEYC_RIGHT, 'l', '+' => {
            if (line.flat or current.expanded) {
                _ = down(mtd, false);
            } else if (!line.flat) {
                current.expanded = true;
                build(mtd);
            }
        },
        '-' | T.KEYC_META => {
            for (mtd.children.items) |child| child.expanded = false;
            build(mtd);
        },
        '+' | T.KEYC_META => {
            for (mtd.children.items) |child| child.expanded = true;
            build(mtd);
        },
        '?', '/', 's' | T.KEYC_CTRL => {
            mtd.references += 1;
            mtd.search_dir = .forward;
            searchCallback(mtd, client);
        },
        'n' => {
            mtd.search_dir = .forward;
            _ = searchSet(mtd);
        },
        'N' => {
            mtd.search_dir = .backward;
            _ = searchSet(mtd);
        },
        'f' => {
            mtd.references += 1;
            filterCallback(mtd, client);
        },
        'v' => {
            cyclePreview(mtd);
            build(mtd);
            if (mtd.preview != .off) checkSelected(mtd);
        },
        else => {},
    }
    return false;
}

pub fn runCommand(client: ?*T.Client, template: []const u8, name: []const u8) void {
    _ = client;
    _ = template;
    _ = name;
    // Stub: requires cmd_parse_and_append / cmdq_new_state from full runtime.
}

pub fn displayMenu(mtd: *Data, client: ?*T.Client, x: u32, y: u32, outside: bool) void {
    _ = mtd;
    _ = client;
    _ = x;
    _ = y;
    _ = outside;
    // Stub: requires menu_create / menu_display from full runtime.
}

pub fn displayHelp(mtd: *Data, client: ?*T.Client) void {
    _ = mtd;
    _ = client;
    // Stub: requires popup_display / popup_write from full runtime.
}

pub fn menuCallback(mtd: *Data, client: ?*T.Client, key_val: T.key_code) void {
    if (mtd.dead or key_val == T.KEYC_NONE) {
        removeRef(mtd);
        return;
    }
    if (mtd.menucb) |menucb| menucb(mtd, client, key_val);
    removeRef(mtd);
}

pub fn searchCallbackInternal(mtd: *Data, s: ?[]const u8) void {
    if (mtd.dead) return;
    setSearch(mtd, s);
    if (mtd.search != null) _ = searchSet(mtd);
}

pub fn filterCallbackInternal(mtd: *Data, s: ?[]const u8) void {
    if (mtd.dead) return;
    setFilter(mtd, s);
    build(mtd);
    draw(mtd);
    mtd.wp.flags |= T.PANE_REDRAW;
}

pub fn removeRef(mtd: *Data) void {
    mtd.references -|= 1;
    if (mtd.references == 0)
        xm.allocator.destroy(mtd);
}

fn searchCallback(mtd: *Data, client: ?*T.Client) void {
    _ = client;
    // Stub: in tmux this calls status_prompt_set with mode_tree_search_callback.
    // For now, release the reference taken by the caller.
    removeRef(mtd);
}

fn filterCallback(mtd: *Data, client: ?*T.Client) void {
    _ = client;
    // Stub: in tmux this calls status_prompt_set with mode_tree_filter_callback.
    removeRef(mtd);
}

fn isLowercase(ptr: []const u8) bool {
    for (ptr) |ch| {
        if (ch != std.ascii.toLower(ch)) return false;
    }
    return true;
}

fn findItem(items: *const std.ArrayList(*Item), tag: u64) ?*Item {
    for (items.items) |item| {
        if (item.tag == tag) return item;
        if (findItem(&item.children, tag)) |child| return child;
    }
    return null;
}

fn freeItem(mti: *Item) void {
    freeItems(&mti.children);
    if (mti.text) |text| xm.allocator.free(text);
    if (mti.keystr) |keystr| xm.allocator.free(keystr);
    xm.allocator.free(mti.name);
    xm.allocator.destroy(mti);
}

fn freeItems(items: *std.ArrayList(*Item)) void {
    for (items.items) |item| freeItem(item);
    items.deinit(xm.allocator);
    items.* = .{};
}

fn clearLines(mtd: *Data) void {
    mtd.line_list.deinit(xm.allocator);
    mtd.line_list = .{};
}

fn buildLines(mtd: *Data, items: *std.ArrayList(*Item), depth: u32) void {
    var flat = true;

    mtd.depth = depth;
    if (depth > mtd.maxdepth) mtd.maxdepth = depth;

    for (items.items, 0..) |item, idx| {
        mtd.line_list.append(xm.allocator, .{
            .item = item,
            .depth = depth,
            .last = idx + 1 == items.items.len,
            .flat = false,
        }) catch unreachable;

        item.line = @intCast(mtd.line_list.items.len - 1);
        if (item.children.items.len != 0) flat = false;
        if (item.expanded) buildLines(mtd, &item.children, depth + 1);

        if (mtd.keycb) |keycb| {
            const key = keycb(mtd, item.itemdata, item.line);
            setItemKey(item, if (key == T.KEYC_UNKNOWN) T.KEYC_NONE else key);
        } else {
            setItemKey(item, defaultKeyForLine(item.line));
        }
    }

    for (items.items) |item| {
        mtd.line_list.items[item.line].flat = flat;
    }
}

fn setItemKey(item: *Item, key: T.key_code) void {
    if (item.keystr) |keystr| {
        xm.allocator.free(keystr);
        item.keystr = null;
    }

    item.key = key;
    if (key != T.KEYC_NONE) {
        item.keystr = xm.xstrdup(key_string.key_string_lookup_key(key, 0));
        item.keylen = item.keystr.?.len;
    } else {
        item.keylen = 0;
    }
}

fn defaultKeyForLine(line: u32) T.key_code {
    if (line < 10) return '0' + line;
    if (line < 36) return T.KEYC_META | ('a' + line - 10);
    return T.KEYC_NONE;
}

fn clearTaggedRecursive(items: *std.ArrayList(*Item)) void {
    for (items.items) |item| {
        item.tagged = false;
        clearTaggedRecursive(&item.children);
    }
}

fn findLineByTag(mtd: *const Data, tag: u64) ?u32 {
    for (mtd.line_list.items, 0..) |line, idx| {
        if (line.item.tag == tag) return @intCast(idx);
    }
    return null;
}

fn checkSelected(mtd: *Data) void {
    if (mtd.height == 0) return;
    if (mtd.current > mtd.height - 1)
        mtd.offset = mtd.current - mtd.height + 1;
}

fn setHeight(mtd: *Data) void {
    const sy = mtd.screen.grid.sy;
    if (sy == 0) {
        mtd.height = 0;
        return;
    }

    if (mtd.heightcb) |heightcb| {
        const reserved = heightcb(mtd, sy);
        if (reserved < sy) mtd.height = sy - reserved else mtd.height = sy;
    } else {
        switch (mtd.preview) {
            .normal => {
                mtd.height = (sy / 3) * 2;
                if (mtd.height > mtd.line_list.items.len)
                    mtd.height = sy / 2;
                if (mtd.height < 10) mtd.height = sy;
            },
            .big => {
                mtd.height = sy / 4;
                if (mtd.height > mtd.line_list.items.len)
                    mtd.height = @intCast(mtd.line_list.items.len);
                if (mtd.height < 2) mtd.height = 2;
            },
            .off => mtd.height = sy,
        }
    }

    if (sy - mtd.height < 2) mtd.height = sy;
}

fn containsIgnoreCaseAscii(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;

    var pos: usize = 0;
    while (pos + needle.len <= haystack.len) : (pos += 1) {
        var matched = true;
        for (needle, 0..) |needle_ch, idx| {
            if (std.ascii.toLower(haystack[pos + idx]) != std.ascii.toLower(needle_ch)) {
                matched = false;
                break;
            }
        }
        if (matched) return true;
    }
    return false;
}

fn searchMatches(mtd: *Data, item: *Item) bool {
    const search_text = mtd.search orelse return false;
    if (mtd.searchcb) |searchcb|
        return searchcb(mtd, item.itemdata, search_text, mtd.search_icase);

    if (!mtd.search_icase)
        return std.mem.indexOf(u8, item.name, search_text) != null;
    return containsIgnoreCaseAscii(item.name, search_text);
}

fn lastDescendant(item: *Item) *Item {
    var current = item;
    while (current.children.items.len != 0) {
        current = current.children.items[current.children.items.len - 1];
    }
    return current;
}

fn nextSibling(mtd: *Data, item: *Item) ?*Item {
    const items = if (item.parent) |parent| parent.children.items else mtd.children.items;
    for (items, 0..) |candidate, idx| {
        if (candidate != item) continue;
        if (idx + 1 < items.len) return items[idx + 1];
        return null;
    }
    return null;
}

fn prevSibling(mtd: *Data, item: *Item) ?*Item {
    const items = if (item.parent) |parent| parent.children.items else mtd.children.items;
    for (items, 0..) |candidate, idx| {
        if (candidate != item) continue;
        if (idx > 0) return items[idx - 1];
        return null;
    }
    return null;
}

fn searchForward(mtd: *Data) ?*Item {
    _ = mtd.search orelse return null;
    if (mtd.line_list.items.len == 0) return null;

    const last = mtd.line_list.items[mtd.current].item;
    var current: ?*Item = last;
    while (true) {
        if (current.?.children.items.len != 0) {
            current = current.?.children.items[0];
        } else if (nextSibling(mtd, current.?)) |next| {
            current = next;
        } else {
            while (current) |node| {
                current = node.parent;
                if (current == null) break;
                if (nextSibling(mtd, current.?)) |next| {
                    current = next;
                    break;
                }
            }
        }

        if (current == null) {
            if (mtd.children.items.len == 0) return null;
            current = mtd.children.items[0];
        }
        if (current.? == last) break;
        if (searchMatches(mtd, current.?)) return current;
    }
    return null;
}

fn searchBackward(mtd: *Data) ?*Item {
    _ = mtd.search orelse return null;
    if (mtd.line_list.items.len == 0) return null;

    const last = mtd.line_list.items[mtd.current].item;
    var current: ?*Item = last;
    while (true) {
        if (prevSibling(mtd, current.?)) |prev| {
            current = lastDescendant(prev);
        } else {
            current = current.?.parent;
        }

        if (current == null) {
            if (mtd.children.items.len == 0) return null;
            current = lastDescendant(mtd.children.items[mtd.children.items.len - 1]);
        }
        if (current.? == last) break;
        if (searchMatches(mtd, current.?)) return current;
    }
    return null;
}

fn removeFromList(items: *std.ArrayList(*Item), target: *Item) void {
    for (items.items, 0..) |item, idx| {
        if (item != target) continue;
        _ = items.orderedRemove(idx);
        return;
    }
}

const TestTreeSpec = struct {
    nodes: []const NodeSpec,
    sort_calls: u32 = 0,

    const NodeSpec = struct {
        tag: u64,
        name: []const u8,
        text: ?[]const u8 = null,
        expanded: i8 = 0,
        children: []const NodeSpec = &.{},
    };
};

fn addSpecNodes(mtd: *Data, parent: ?*Item, nodes: []const TestTreeSpec.NodeSpec) void {
    for (nodes) |node| {
        const item = add(mtd, parent, @ptrFromInt(node.tag), node.tag, node.name, node.text, node.expanded);
        addSpecNodes(mtd, item, node.children);
    }
}

fn testBuildCallback(mtd: *Data) void {
    const spec: *TestTreeSpec = @ptrCast(@alignCast(mtd.modedata.?));
    addSpecNodes(mtd, null, spec.nodes);
}

fn testSortCallback(sort_crit: *T.SortCriteria) void {
    _ = sort_crit;
}

fn initTestPane() *T.WindowPane {
    const base_grid = @import("grid.zig").grid_create(80, 24, 2000);
    const alt_screen = screen.screen_init(80, 24, 2000);

    const test_window = xm.allocator.create(T.Window) catch unreachable;
    test_window.* = .{
        .id = 1,
        .name = xm.xstrdup("mode-tree"),
        .sx = 80,
        .sy = 24,
        .options = undefined,
    };

    const pane = xm.allocator.create(T.WindowPane) catch unreachable;
    pane.* = .{
        .id = 2,
        .window = test_window,
        .options = undefined,
        .sx = 80,
        .sy = 24,
        .screen = alt_screen,
        .base = .{ .grid = base_grid, .rlower = 23 },
    };

    test_window.panes.append(xm.allocator, pane) catch unreachable;
    test_window.active = pane;
    return pane;
}

fn freeTestPane(pane: *T.WindowPane) void {
    const test_window = pane.window;
    screen.screen_free(pane.screen);
    xm.allocator.destroy(pane.screen);
    @import("grid.zig").grid_free(pane.base.grid);
    pane.modes.deinit(xm.allocator);
    pane.input_pending.deinit(xm.allocator);
    xm.allocator.destroy(pane);

    test_window.panes.deinit(xm.allocator);
    test_window.last_panes.deinit(xm.allocator);
    test_window.winlinks.deinit(xm.allocator);
    xm.allocator.free(test_window.name);
    xm.allocator.destroy(test_window);
}

test "mode-tree build preserves saved expanded and tagged state by tag" {
    const pane = initTestPane();
    defer freeTestPane(pane);

    const spec = TestTreeSpec{
        .nodes = &.{
            .{
                .tag = 1,
                .name = "root",
                .expanded = 0,
                .children = &.{
                    .{ .tag = 11, .name = "child-one" },
                    .{ .tag = 12, .name = "child-two" },
                },
            },
            .{ .tag = 2, .name = "other" },
        },
    };

    const mtd = start(pane, .{
        .modedata = @ptrCast(@constCast(&spec)),
        .buildcb = testBuildCallback,
        .sortcb = testSortCallback,
    });
    defer free(mtd);

    build(mtd);
    try std.testing.expectEqual(@as(u32, 2), @as(u32, @intCast(mtd.line_list.items.len)));

    expandCurrent(mtd);
    try std.testing.expectEqual(@as(u32, 4), @as(u32, @intCast(mtd.line_list.items.len)));

    try std.testing.expect(setCurrent(mtd, 11));
    toggleCurrentTag(mtd, false);
    try std.testing.expectEqual(@as(u32, 1), countTagged(mtd));

    build(mtd);
    try std.testing.expectEqual(@as(u32, 4), @as(u32, @intCast(mtd.line_list.items.len)));
    try std.testing.expect(setCurrent(mtd, 11));
    try std.testing.expect(mtd.line_list.items[mtd.current].item.tagged);
    try std.testing.expect(mtd.line_list.items[0].item.expanded);
}

test "mode-tree search walks the tree in preorder and wraps" {
    const pane = initTestPane();
    defer freeTestPane(pane);

    const spec = TestTreeSpec{
        .nodes = &.{
            .{
                .tag = 1,
                .name = "alpha",
                .expanded = 1,
                .children = &.{
                    .{ .tag = 11, .name = "bravo" },
                    .{ .tag = 12, .name = "charlie" },
                },
            },
            .{ .tag = 2, .name = "delta" },
        },
    };

    const mtd = start(pane, .{
        .modedata = @ptrCast(@constCast(&spec)),
        .buildcb = testBuildCallback,
    });
    defer free(mtd);

    build(mtd);
    try std.testing.expect(setCurrent(mtd, 11));

    setSearch(mtd, "delta");
    mtd.search_dir = .forward;
    try std.testing.expect(searchSet(mtd));
    try std.testing.expectEqualStrings("delta", getCurrentName(mtd).?);

    setSearch(mtd, "alpha");
    mtd.search_dir = .backward;
    try std.testing.expect(searchSet(mtd));
    try std.testing.expectEqualStrings("alpha", getCurrentName(mtd).?);
}

test "mode-tree tagging clears parent child conflicts and can fall back to current" {
    const pane = initTestPane();
    defer freeTestPane(pane);

    const spec = TestTreeSpec{
        .nodes = &.{
            .{
                .tag = 1,
                .name = "root",
                .expanded = 1,
                .children = &.{
                    .{ .tag = 11, .name = "child" },
                },
            },
        },
    };

    const mtd = start(pane, .{
        .modedata = @ptrCast(@constCast(&spec)),
        .buildcb = testBuildCallback,
    });
    defer free(mtd);

    build(mtd);
    toggleCurrentTag(mtd, false);
    try std.testing.expect(mtd.line_list.items[0].item.tagged);

    try std.testing.expect(setCurrent(mtd, 11));
    toggleCurrentTag(mtd, false);
    try std.testing.expect(!mtd.line_list.items[0].item.tagged);
    try std.testing.expect(mtd.line_list.items[mtd.current].item.tagged);
    try std.testing.expectEqual(@as(u32, 1), countTagged(mtd));

    clearAllTagged(mtd);

    const Collector = struct {
        var value: usize = 0;

        fn visit(data: *Data, itemdata: ?*anyopaque, client: ?*T.Client, key: T.key_code) void {
            _ = data;
            _ = client;
            _ = key;
            value = @intFromPtr(itemdata);
        }
    };

    Collector.value = 0;
    eachTagged(mtd, Collector.visit, null, T.KEYC_NONE, true);
    try std.testing.expectEqual(@as(usize, 11), Collector.value);
}
