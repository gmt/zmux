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
// Ported in part from tmux/window-tree.c.
// Original copyright:
//   Copyright (c) 2017 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence - same terms as above.

const std = @import("std");
const args_mod = @import("arguments.zig");
const format_mod = @import("format.zig");
const key_string = @import("key-string.zig");
const marked_pane = @import("marked-pane.zig");
const menu_mod = @import("menu.zig");
const mode_tree = @import("mode-tree.zig");
const opts = @import("options.zig");
const screen = @import("screen.zig");
const screen_write = @import("screen-write.zig");
const server = @import("server.zig");
const sess = @import("session.zig");
const server_fn = @import("server-fn.zig");
const sort_mod = @import("sort.zig");
const status_prompt = @import("status-prompt.zig");
const status_runtime = @import("status-runtime.zig");
const cmdq = @import("cmd-queue.zig");
const T = @import("types.zig");
const window = @import("window.zig");
const window_mode_runtime = @import("window-mode-runtime.zig");
const xm = @import("xmalloc.zig");

const DEFAULT_COMMAND = "switch-client -Zt '%%'";
const DEFAULT_KEY_FORMAT =
    "#{?#{e|<:#{line},10}," ++
    "#{line}" ++
    ",#{e|<:#{line},36}," ++
    "M-#{a:#{e|+:97,#{e|-:#{line},10}}}" ++
    "}";
const DEFAULT_SESSION_FORMAT = "#{session_name}: #{session_windows} windows#{?session_attached, (attached),}";
const DEFAULT_WINDOW_FORMAT = "#{window_index}:#{window_name}#{window_flags}";
const DEFAULT_PANE_FORMAT = "#{pane_index}: #{pane_current_command}#{?pane_active,*,}#{?pane_title, \"#{pane_title}\",}";
const HELP_TEXT = "Enter choose  arrows move  left/right fold  t/T/^T tags  H home  q cancel";

/// Context-menu items for tree mode (tmux `window_tree_menu_items`).
const window_tree_menu_items = [_]menu_mod.MenuItemTemplate{
    .{ .name = "Select", .key = '\r' },
    .{ .name = "Expand", .key = T.KEYC_RIGHT },
    .{ .name = "Mark", .key = 'm' },
    .{ .name = "", .key = T.KEYC_NONE },
    .{ .name = "Tag", .key = 't' },
    .{ .name = "Tag All", .key = '\x14' }, // Ctrl-T
    .{ .name = "Tag None", .key = 'T' },
    .{ .name = "", .key = T.KEYC_NONE },
    .{ .name = "Kill", .key = 'x' },
    .{ .name = "Kill Tagged", .key = 'X' },
    .{ .name = "", .key = T.KEYC_NONE },
    .{ .name = "Cancel", .key = 'q' },
    .{}, // sentinel
};

pub const DisplayKind = enum {
    session,
    window,
    pane,
};

pub const EnterConfig = struct {
    fs: *const T.CmdFindState,
    kind: DisplayKind = .pane,
    format: ?[]const u8 = null,
    key_format: ?[]const u8 = null,
    filter: ?[]const u8 = null,
    command: ?[]const u8 = null,
    sort_crit: T.SortCriteria = .{},
    squash_groups: bool = true,
    zoom: bool = false,
};

const ItemType = enum {
    session,
    window,
    pane,
};

const TreeItem = struct {
    item_type: ItemType,
    session: *T.Session,
    winlink: ?*T.Winlink = null,
    pane: ?*T.WindowPane = null,
    text: []u8,
};

const WindowTreeModeData = struct {
    fs: T.CmdFindState,
    tree: *mode_tree.Data,
    items: std.ArrayList(*TreeItem) = .{},
    format: []u8,
    key_format: []u8,
    filter: ?[]u8 = null,
    command: []u8,
    entered: ?[]const u8 = null,
    sort_crit: T.SortCriteria = .{},
    kind: DisplayKind = .pane,
    squash_groups: bool = true,
    preview_offset: i32 = 0,
    preview_left: i32 = -1,
    preview_right: i32 = -1,
    preview_start: u32 = 0,
    preview_end: u32 = 0,
    preview_each: u32 = 0,
    preview_top: u32 = 0,
    preview_bottom: u32 = 0,
};

const TreePromptAction = enum(u8) {
    command,
    kill_current,
    kill_tagged,
};

const TreePromptState = struct {
    pane_id: u32,
    action: TreePromptAction,
};

const TreeDoneState = struct {
    pane_id: u32,
};

pub const window_tree_mode = T.WindowMode{
    .name = "tree-mode",
    .resize = window_tree_resize,
    .key = windowTreeKey,
    .key_table = windowTreeKeyTable,
    .command = windowTreeCommand,
    .close = windowTreeClose,
    .get_screen = windowTreeGetScreen,
};

pub fn enterMode(wp: *T.WindowPane, config: EnterConfig) *T.WindowModeEntry {
    if (window.window_pane_mode(wp)) |wme| {
        if (wme.mode == &window_tree_mode) {
            refreshFromConfig(wme, config);
            if (config.zoom)
                mode_tree.zoom(modeData(wme).tree, true);
            rebuildAndDraw(wme);
            return wme;
        }
    }

    screen.screen_enter_alternate(wp, true);

    const data = xm.allocator.create(WindowTreeModeData) catch unreachable;
    data.* = .{
        .fs = config.fs.*,
        .tree = undefined,
        .format = xm.xstrdup(config.format orelse defaultFormat(config.kind)),
        .key_format = xm.xstrdup(config.key_format orelse DEFAULT_KEY_FORMAT),
        .filter = if (config.filter) |filter| xm.xstrdup(filter) else null,
        .command = xm.xstrdup(config.command orelse DEFAULT_COMMAND),
        .sort_crit = config.sort_crit,
        .kind = config.kind,
        .squash_groups = config.squash_groups,
    };

    data.tree = mode_tree.start(wp, .{
        .modedata = @ptrCast(data),
        .zoom = config.zoom,
        .menu = &window_tree_menu_items,
        .buildcb = buildTree,
        .searchcb = searchItem,
        .menucb = windowTreeMenuCallback,
        .keycb = keyForLineCallback,
    });

    const wme = window_mode_runtime.pushMode(wp, &window_tree_mode, @ptrCast(data), null);
    wme.prefix = 1;
    rebuildAndDraw(wme);
    return wme;
}

fn windowTreeKeyTable(wme: *T.WindowModeEntry) []const u8 {
    if (opts.options_get_number(wme.wp.window.options, "mode-keys") == T.MODEKEY_VI)
        return "tree-mode-vi";
    return "tree-mode";
}

fn windowTreeCommand(
    wme: *T.WindowModeEntry,
    client: ?*T.Client,
    session: *T.Session,
    wl: *T.Winlink,
    raw_args: *const anyopaque,
    mouse: ?*const T.MouseEvent,
) void {
    const args: *const args_mod.Arguments = @ptrCast(@alignCast(raw_args));
    if (args.count() == 0) return;

    const command = args.value_at(0).?;
    const data = modeData(wme);
    const repeat = repeatCount(wme);
    _ = mouse;

    if (std.mem.eql(u8, command, "cancel")) {
        _ = window_mode_runtime.resetMode(wme.wp);
        return;
    }
    if (std.mem.eql(u8, command, "choose")) {
        chooseCurrent(wme, client, session, wl);
        return;
    }
    if (std.mem.eql(u8, command, "cursor-up")) {
        const previous_tag = currentTag(data.tree);
        var remaining = repeat;
        while (remaining > 0) : (remaining -= 1) mode_tree.up(data.tree, false);
        resetPreviewOffsetIfSelectionChanged(data, previous_tag);
        redraw(wme);
        wme.prefix = 1;
        return;
    }
    if (std.mem.eql(u8, command, "cursor-down")) {
        const previous_tag = currentTag(data.tree);
        var remaining = repeat;
        while (remaining > 0) : (remaining -= 1) _ = mode_tree.down(data.tree, false);
        resetPreviewOffsetIfSelectionChanged(data, previous_tag);
        redraw(wme);
        wme.prefix = 1;
        return;
    }
    if (std.mem.eql(u8, command, "page-up")) {
        const previous_tag = currentTag(data.tree);
        pageUp(data.tree, viewRows(wme.wp), repeat);
        resetPreviewOffsetIfSelectionChanged(data, previous_tag);
        redraw(wme);
        wme.prefix = 1;
        return;
    }
    if (std.mem.eql(u8, command, "page-down")) {
        const previous_tag = currentTag(data.tree);
        pageDown(data.tree, viewRows(wme.wp), repeat);
        resetPreviewOffsetIfSelectionChanged(data, previous_tag);
        redraw(wme);
        wme.prefix = 1;
        return;
    }
    if (std.mem.eql(u8, command, "expand")) {
        mode_tree.expandCurrent(data.tree);
        redraw(wme);
        wme.prefix = 1;
        return;
    }
    if (std.mem.eql(u8, command, "collapse")) {
        mode_tree.collapseCurrent(data.tree);
        redraw(wme);
        wme.prefix = 1;
        return;
    }
    if (std.mem.eql(u8, command, "tag")) {
        mode_tree.toggleCurrentTag(data.tree, false);
        redraw(wme);
        wme.prefix = 1;
        return;
    }
    if (std.mem.eql(u8, command, "tag-all")) {
        mode_tree.tagAll(data.tree);
        redraw(wme);
        wme.prefix = 1;
        return;
    }
    if (std.mem.eql(u8, command, "tag-none")) {
        mode_tree.clearAllTagged(data.tree);
        redraw(wme);
        wme.prefix = 1;
        return;
    }
    if (std.mem.eql(u8, command, "home-target")) {
        const previous_tag = currentTag(data.tree);
        focusTarget(data);
        resetPreviewOffsetIfSelectionChanged(data, previous_tag);
        redraw(wme);
        wme.prefix = 1;
        return;
    }
    if (std.mem.eql(u8, command, "scroll-left")) {
        var remaining = repeat;
        while (remaining > 0) : (remaining -= 1) data.preview_offset -= 1;
        redraw(wme);
        wme.prefix = 1;
        return;
    }
    if (std.mem.eql(u8, command, "scroll-right")) {
        var remaining = repeat;
        while (remaining > 0) : (remaining -= 1) data.preview_offset += 1;
        redraw(wme);
        wme.prefix = 1;
        return;
    }

    unsupportedCommand(client, command);
    redraw(wme);
    wme.prefix = 1;
}

fn windowTreeKey(
    wme: *T.WindowModeEntry,
    client: ?*T.Client,
    session: *T.Session,
    wl: *T.Winlink,
    key: T.key_code,
    mouse: ?*const T.MouseEvent,
) void {
    const data = modeData(wme);
    var translated = key;
    var finished = false;

    if (mouse) |event| {
        if (currentItem(data)) |item| {
            const previous_tag = currentTag(data.tree);
            translated = windowTreeMouse(data, key, event.x, event.y, item);
            resetPreviewOffsetIfSelectionChanged(data, previous_tag);
        }
    }

    if (translated == key) {
        var mouse_x: u32 = 0;
        var mouse_y: u32 = 0;
        const previous_tag = currentTag(data.tree);
        finished = mode_tree.handleKey(data.tree, client, &translated, mouse, &mouse_x, &mouse_y);
        resetPreviewOffsetIfSelectionChanged(data, previous_tag);

        if (T.keycIsMouse(translated) and mouse != null) {
            if (currentItem(data)) |item| {
                const previous_mouse_tag = currentTag(data.tree);
                translated = windowTreeMouse(data, translated, mouse_x, mouse_y, item);
                resetPreviewOffsetIfSelectionChanged(data, previous_mouse_tag);
            } else {
                translated = T.KEYC_NONE;
            }
        }
    }

    switch (translated) {
        '<' => {
            data.preview_offset -= 1;
        },
        '>' => {
            data.preview_offset += 1;
        },
        'H' => {
            const previous_tag = currentTag(data.tree);
            focusTarget(data);
            resetPreviewOffsetIfSelectionChanged(data, previous_tag);
        },
        'm' => {
            setMarkedCurrent(data);
        },
        'M' => {
            marked_pane.clear();
            mode_tree.build(data.tree);
        },
        'x' => {
            promptTreeKill(client, wme, .kill_current);
            return;
        },
        'X' => {
            promptTreeKill(client, wme, .kill_tagged);
            return;
        },
        ':' => {
            promptTreeCommand(client, wme);
            return;
        },
        '\r' => {
            chooseCurrent(wme, client, session, wl);
            return;
        },
        else => {},
    }

    if (finished) {
        _ = window_mode_runtime.resetMode(wme.wp);
        return;
    }
    redraw(wme);
}

fn windowTreeMenuCallback(tree: *mode_tree.Data, client: ?*T.Client, key: T.key_code) void {
    const data: *WindowTreeModeData = @ptrCast(@alignCast(tree.modedata.?));
    const pane = data.fs.wp orelse return;
    const wme = window.window_pane_mode(pane) orelse return;
    const session = data.fs.s orelse return;
    const wl = data.fs.wl orelse return;
    windowTreeKey(wme, client, session, wl, key, null);
}

fn windowTreeClose(wme: *T.WindowModeEntry) void {
    const data = modeData(wme);
    mode_tree.free(data.tree);
    freeItems(data);
    data.items.deinit(xm.allocator);
    xm.allocator.free(data.format);
    xm.allocator.free(data.key_format);
    if (data.filter) |filter| xm.allocator.free(filter);
    xm.allocator.free(data.command);
    xm.allocator.destroy(data);

    if (wme.wp.modes.items.len <= 1)
        screen.screen_leave_alternate(wme.wp, true);
}

fn windowTreeGetScreen(wme: *T.WindowModeEntry) *T.Screen {
    return modeData(wme).tree.getScreen();
}

fn modeData(wme: *T.WindowModeEntry) *WindowTreeModeData {
    return @ptrCast(@alignCast(wme.data.?));
}

fn refreshFromConfig(wme: *T.WindowModeEntry, config: EnterConfig) void {
    const data = modeData(wme);
    data.fs = config.fs.*;
    data.kind = config.kind;
    data.squash_groups = config.squash_groups;
    data.sort_crit = config.sort_crit;

    xm.allocator.free(data.format);
    data.format = xm.xstrdup(config.format orelse defaultFormat(config.kind));

    xm.allocator.free(data.key_format);
    data.key_format = xm.xstrdup(config.key_format orelse DEFAULT_KEY_FORMAT);

    if (data.filter) |filter| xm.allocator.free(filter);
    data.filter = if (config.filter) |filter| xm.xstrdup(filter) else null;

    xm.allocator.free(data.command);
    data.command = xm.xstrdup(config.command orelse DEFAULT_COMMAND);
}

fn rebuildAndDraw(wme: *T.WindowModeEntry) void {
    const data = modeData(wme);
    mode_tree.setFilter(data.tree, data.filter);
    mode_tree.build(data.tree);
    focusTarget(data);
    redraw(wme);
}

fn redraw(wme: *T.WindowModeEntry) void {
    const data = modeData(wme);
    const tree = data.tree;
    const view = tree.getScreen();
    const rows = view.grid.sy;
    const help_row = if (rows > 0) rows - 1 else 0;
    const body_rows = if (rows > 0) @min(tree.height, help_row) else 0;
    const preview_rows = if (rows > body_rows + 1) rows - body_rows - 1 else 0;

    screen.screen_reset_active(view);
    view.mode &= ~@as(i32, T.MODE_CURSOR | T.MODE_WRAP);
    view.cursor_visible = false;

    var ctx = T.ScreenWriteCtx{ .s = view };
    var row: u32 = 0;
    while (row < body_rows) : (row += 1) {
        screen_write.cursor_to(&ctx, row, 0);
        screen_write.erase_line(&ctx);

        const line_index = tree.offset + row;
        if (line_index >= tree.line_list.items.len) continue;

        const rendered = renderLine(tree, line_index);
        defer xm.allocator.free(rendered);
        screen_write.putn(&ctx, rendered);
    }

    drawPreview(data, &ctx, body_rows, preview_rows);

    if (rows > 0) {
        screen_write.cursor_to(&ctx, rows - 1, 0);
        screen_write.erase_line(&ctx);
        screen_write.putn(&ctx, HELP_TEXT);
    }

    if (tree.line_list.items.len == 0 and body_rows != 0) {
        screen_write.cursor_to(&ctx, 0, 0);
        screen_write.erase_line(&ctx);
        screen_write.putn(&ctx, if (data.filter != null) "No matching sessions, windows, or panes." else "No sessions, windows, or panes.");
    }

    window_mode_runtime.noteModeRedraw(wme.wp);
}

const PreviewLayout = struct {
    start: u32,
    end: u32,
    each: u32,
    remaining: u32,
    left: bool,
    right: bool,
};

fn drawPreview(data: *WindowTreeModeData, ctx: *T.ScreenWriteCtx, top: u32, height: u32) void {
    data.preview_left = -1;
    data.preview_right = -1;
    data.preview_start = 0;
    data.preview_end = 0;
    data.preview_each = 0;
    data.preview_top = top;
    data.preview_bottom = top;

    if (height == 0) return;
    const item_ptr = mode_tree.getCurrent(data.tree) orelse return;
    const item: *TreeItem = @ptrCast(@alignCast(item_ptr));

    data.preview_bottom = top + height;
    switch (item.item_type) {
        .session => drawSessionPreview(data, item.session, ctx, top, height),
        .window => drawWindowPreview(data, item.winlink.?.window, ctx, top, height),
        .pane => drawPanePreview(item.pane.?, ctx, top, height),
    }
}

fn drawPanePreview(pane: *T.WindowPane, ctx: *T.ScreenWriteCtx, top: u32, height: u32) void {
    const width = ctx.s.grid.sx;
    if (width == 0 or height == 0) return;
    screen_write.cursor_to(ctx, top, 0);
    screen_write.preview(ctx, &pane.base, width, height);
}

fn drawSessionPreview(data: *WindowTreeModeData, session_ptr: *T.Session, ctx: *T.ScreenWriteCtx, top: u32, height: u32) void {
    const windows = sort_mod.sorted_winlinks_session(session_ptr, .{ .order = .index });
    defer xm.allocator.free(windows);

    const current_index = sessionCurrentIndex(session_ptr, windows);
    const layout = beginPreviewLayout(data, ctx, top, height, @intCast(windows.len), @intCast(current_index)) orelse return;

    var visual_index: u32 = 0;
    var loop = layout.start;
    while (loop < layout.end) : (loop += 1) {
        const wl = windows[@intCast(loop)];
        const x = previewTileOffset(layout, visual_index);
        const width = previewTileWidth(layout, loop);
        if (width == 0) {
            visual_index += 1;
            continue;
        }

        screen_write.cursor_to(ctx, top, x);
        screen_write.preview(ctx, &wl.window.active.?.base, width, height);

        var label = xm.xasprintf(" {d}:{s} ", .{ wl.idx, wl.window.name });
        if (label.len > width) {
            xm.allocator.free(label);
            label = xm.xasprintf(" {d} ", .{wl.idx});
        }
        defer xm.allocator.free(label);
        drawCenteredText(ctx, top, x, width, height, label);

        if (loop != layout.end - 1)
            drawVerticalLine(ctx, x + width, top, height);
        visual_index += 1;
    }
}

fn drawWindowPreview(data: *WindowTreeModeData, w: *T.Window, ctx: *T.ScreenWriteCtx, top: u32, height: u32) void {
    const current_index = windowCurrentPaneIndex(w);
    const layout = beginPreviewLayout(data, ctx, top, height, @intCast(w.panes.items.len), @intCast(current_index)) orelse return;

    var visual_index: u32 = 0;
    var loop = layout.start;
    while (loop < layout.end) : (loop += 1) {
        const pane = w.panes.items[@intCast(loop)];
        const x = previewTileOffset(layout, visual_index);
        const width = previewTileWidth(layout, loop);
        if (width == 0) {
            visual_index += 1;
            continue;
        }

        screen_write.cursor_to(ctx, top, x);
        screen_write.preview(ctx, &pane.base, width, height);

        const label = xm.xasprintf(" {d} ", .{paneIndex(w, pane)});
        defer xm.allocator.free(label);
        drawCenteredText(ctx, top, x, width, height, label);

        if (loop != layout.end - 1)
            drawVerticalLine(ctx, x + width, top, height);
        visual_index += 1;
    }
}

fn beginPreviewLayout(
    data: *WindowTreeModeData,
    ctx: *T.ScreenWriteCtx,
    top: u32,
    height: u32,
    total: u32,
    current: u32,
) ?PreviewLayout {
    const sx = ctx.s.grid.sx;
    if (sx == 0 or total == 0) return null;

    var visible: u32 = if (sx / total < 24) sx / 24 else total;
    if (visible == 0) visible = 1;

    var start: u32 = 0;
    var end: u32 = 0;
    if (current < visible) {
        start = 0;
        end = visible;
    } else if (current >= total - visible) {
        start = total - visible;
        end = total;
    } else {
        start = current - (visible / 2);
        end = start + visible;
    }

    const min_offset = -@as(i32, @intCast(start));
    const max_offset = @as(i32, @intCast(total - end));
    if (data.preview_offset < min_offset) data.preview_offset = min_offset;
    if (data.preview_offset > max_offset) data.preview_offset = max_offset;

    start = @intCast(@as(i32, @intCast(start)) + data.preview_offset);
    end = @intCast(@as(i32, @intCast(end)) + data.preview_offset);

    var left = start != 0;
    var right = end != total;
    if (((left and right) and sx <= 6) or ((left or right) and sx <= 3)) {
        left = false;
        right = false;
    }

    var each: u32 = 0;
    var remaining: u32 = 0;
    if (left and right) {
        each = (sx - 6) / visible;
        remaining = (sx - 6) - (visible * each);
    } else if (left or right) {
        each = (sx - 3) / visible;
        remaining = (sx - 3) - (visible * each);
    } else {
        each = sx / visible;
        remaining = sx - (visible * each);
    }
    if (each == 0) return null;

    if (left) {
        data.preview_left = 2;
        drawVerticalLine(ctx, 2, top, height);
        drawCenteredText(ctx, top, 0, 1, height, "<");
    }
    if (right) {
        data.preview_right = @as(i32, @intCast(sx)) - 3;
        drawVerticalLine(ctx, sx - 3, top, height);
        drawCenteredText(ctx, top, sx - 1, 1, height, ">");
    }

    data.preview_start = start;
    data.preview_end = end;
    data.preview_each = each;
    return .{
        .start = start,
        .end = end,
        .each = each,
        .remaining = remaining,
        .left = left,
        .right = right,
    };
}

fn previewTileOffset(layout: PreviewLayout, visual_index: u32) u32 {
    return if (layout.left) 3 + (visual_index * layout.each) else visual_index * layout.each;
}

fn previewTileWidth(layout: PreviewLayout, loop: u32) u32 {
    return if (loop == layout.end - 1) layout.each + layout.remaining else layout.each -| 1;
}

fn drawVerticalLine(ctx: *T.ScreenWriteCtx, col: u32, top: u32, height: u32) void {
    const clamped = @min(height, ctx.s.grid.sy -| top);
    if (clamped == 0) return;
    screen_write.cursor_to(ctx, top, col);
    screen_write.vline(ctx, clamped, false, false);
}

fn drawCenteredText(ctx: *T.ScreenWriteCtx, top: u32, left: u32, width: u32, height: u32, text: []const u8) void {
    if (width == 0 or height == 0 or text.len > width) return;
    const row = top + height / 2;
    const col = left + (width - @as(u32, @intCast(text.len))) / 2;
    if (row >= ctx.s.grid.sy or col >= ctx.s.grid.sx) return;
    screen_write.cursor_to(ctx, row, col);
    screen_write.putn(ctx, text);
}

fn sessionCurrentIndex(session_ptr: *T.Session, windows: []*T.Winlink) usize {
    const current = session_ptr.curw orelse return 0;
    for (windows, 0..) |wl, idx| {
        if (wl == current) return idx;
    }
    return 0;
}

fn windowCurrentPaneIndex(w: *T.Window) usize {
    const current = w.active orelse return 0;
    for (w.panes.items, 0..) |pane, idx| {
        if (pane == current) return idx;
    }
    return 0;
}

fn currentTag(tree: *const mode_tree.Data) ?u64 {
    if (tree.line_list.items.len == 0 or tree.current >= tree.line_list.items.len) return null;
    return tree.line_list.items[tree.current].item.tag;
}

fn currentItem(data: *const WindowTreeModeData) ?*TreeItem {
    const item_ptr = mode_tree.getCurrent(data.tree) orelse return null;
    return @ptrCast(@alignCast(item_ptr));
}

fn resetPreviewOffsetIfSelectionChanged(data: *WindowTreeModeData, previous_tag: ?u64) void {
    const previous = previous_tag orelse return;
    const current = currentTag(data.tree) orelse {
        data.preview_offset = 0;
        return;
    };
    if (current != previous) data.preview_offset = 0;
}

fn setMarkedCurrent(data: *WindowTreeModeData) void {
    const item = currentItem(data) orelse return;
    switch (item.item_type) {
        .session => {
            const wl = item.session.curw orelse return;
            const pane = wl.window.active orelse return;
            marked_pane.set(item.session, wl, pane);
        },
        .window => {
            const wl = item.winlink orelse return;
            const pane = wl.window.active orelse return;
            marked_pane.set(item.session, wl, pane);
        },
        .pane => {
            const wl = item.winlink orelse return;
            const pane = item.pane orelse return;
            marked_pane.set(item.session, wl, pane);
        },
    }
    mode_tree.build(data.tree);
}

fn windowTreeMouse(
    data: *const WindowTreeModeData,
    key: T.key_code,
    x: u32,
    y: u32,
    item: *const TreeItem,
) T.key_code {
    if (key != T.keycMouse(T.KEYC_MOUSEDOWN1, .pane)) return T.KEYC_NONE;
    if (y < data.preview_top or y >= data.preview_bottom) return T.KEYC_NONE;
    if (data.preview_left != -1 and x <= @as(u32, @intCast(data.preview_left))) return '<';
    if (data.preview_right != -1 and x >= @as(u32, @intCast(data.preview_right))) return '>';
    if (data.preview_end <= data.preview_start or data.preview_each == 0) return T.KEYC_NONE;

    var preview_x = x;
    if (data.preview_left != -1) {
        preview_x -|= @as(u32, @intCast(data.preview_left));
    } else if (preview_x != 0) {
        preview_x -= 1;
    }

    var preview_index: u32 = 0;
    if (preview_x != 0) {
        preview_index = preview_x / data.preview_each;
        const max_index = data.preview_end - data.preview_start - 1;
        if (preview_index > max_index) preview_index = max_index;
    }
    const target_index = data.preview_start + preview_index;

    switch (item.item_type) {
        .session => {
            const windows = sort_mod.sorted_winlinks_session(item.session, .{ .order = .index });
            defer xm.allocator.free(windows);
            if (target_index >= windows.len) return T.KEYC_NONE;
            mode_tree.expandCurrent(data.tree);
            _ = mode_tree.setCurrent(data.tree, tagForWinlink(windows[target_index]));
            return '\r';
        },
        .window => {
            const window_ptr = item.winlink.?.window;
            if (target_index >= window_ptr.panes.items.len) return T.KEYC_NONE;
            mode_tree.expandCurrent(data.tree);
            _ = mode_tree.setCurrent(data.tree, tagForPane(window_ptr.panes.items[target_index]));
            return '\r';
        },
        .pane => return T.KEYC_NONE,
    }
}

fn buildTree(tree: *mode_tree.Data) void {
    const data: *WindowTreeModeData = @ptrCast(@alignCast(tree.modedata.?));
    freeItems(data);

    const sessions = sort_mod.sorted_sessions(data.sort_crit);
    defer xm.allocator.free(sessions);

    const current_group = sess.session_group_contains(data.fs.s.?);
    for (sessions) |session_ptr| {
        if (data.squash_groups and shouldSkipSession(data, session_ptr, current_group))
            continue;
        addSession(data, tree, session_ptr);
    }
}

fn addSession(data: *WindowTreeModeData, tree: *mode_tree.Data, session_ptr: *T.Session) void {
    switch (data.kind) {
        .session => {
            if (!sessionMatchesFilter(data, session_ptr)) return;
            const item = allocItem(data, .session, session_ptr, null, null);
            _ = mode_tree.add(tree, null, @ptrCast(item), tagForSession(session_ptr), session_ptr.name, item.text, 0);
        },
        .window, .pane => {
            const children = sort_mod.sorted_winlinks_session(session_ptr, data.sort_crit);
            defer xm.allocator.free(children);

            var matching_children: std.ArrayList(*T.Winlink) = .{};
            defer matching_children.deinit(xm.allocator);
            for (children) |wl| {
                if (windowMatchesFilter(data, session_ptr, wl))
                    matching_children.append(xm.allocator, wl) catch unreachable;
            }
            if (matching_children.items.len == 0) return;

            const item = allocItem(data, .session, session_ptr, null, null);
            const session_node = mode_tree.add(tree, null, @ptrCast(item), tagForSession(session_ptr), session_ptr.name, item.text, if (data.kind == .window) 1 else 1);
            for (matching_children.items) |wl| addWindow(data, tree, session_node, session_ptr, wl);
        },
    }
}

fn addWindow(data: *WindowTreeModeData, tree: *mode_tree.Data, parent: *mode_tree.Item, session_ptr: *T.Session, wl: *T.Winlink) void {
    if (data.kind == .window) {
        const item = allocItem(data, .window, session_ptr, wl, null);
        const name = xm.xasprintf("{d}", .{wl.idx});
        defer xm.allocator.free(name);
        _ = mode_tree.add(tree, parent, @ptrCast(item), tagForWinlink(wl), name, item.text, 0);
        return;
    }

    const panes = sort_mod.sorted_panes_window(wl.window, data.sort_crit);
    defer xm.allocator.free(panes);

    var matching_panes: std.ArrayList(*T.WindowPane) = .{};
    defer matching_panes.deinit(xm.allocator);
    for (panes) |pane| {
        if (paneMatchesFilter(data, session_ptr, wl, pane))
            matching_panes.append(xm.allocator, pane) catch unreachable;
    }
    if (matching_panes.items.len == 0) return;

    const item = allocItem(data, .window, session_ptr, wl, null);
    const name = xm.xasprintf("{d}", .{wl.idx});
    defer xm.allocator.free(name);
    const window_node = mode_tree.add(tree, parent, @ptrCast(item), tagForWinlink(wl), name, item.text, 1);
    for (matching_panes.items) |pane| addPane(data, tree, window_node, session_ptr, wl, pane);
}

fn addPane(data: *WindowTreeModeData, tree: *mode_tree.Data, parent: *mode_tree.Item, session_ptr: *T.Session, wl: *T.Winlink, pane: *T.WindowPane) void {
    const item = allocItem(data, .pane, session_ptr, wl, pane);
    const name = xm.xasprintf("{d}", .{paneIndex(wl.window, pane)});
    defer xm.allocator.free(name);
    _ = mode_tree.add(tree, parent, @ptrCast(item), tagForPane(pane), name, item.text, 0);
}

fn allocItem(data: *WindowTreeModeData, item_type: ItemType, session_ptr: *T.Session, wl: ?*T.Winlink, pane: ?*T.WindowPane) *TreeItem {
    const item = xm.allocator.create(TreeItem) catch unreachable;
    item.* = .{
        .item_type = item_type,
        .session = session_ptr,
        .winlink = wl,
        .pane = pane,
        .text = renderItemText(data, item_type, session_ptr, wl, pane),
    };
    data.items.append(xm.allocator, item) catch unreachable;
    return item;
}

fn renderItemText(data: *const WindowTreeModeData, item_type: ItemType, session_ptr: *T.Session, wl: ?*T.Winlink, pane: ?*T.WindowPane) []u8 {
    const ctx = formatContext(session_ptr, wl, pane);
    const template = if (data.format.len != 0)
        data.format
    else switch (item_type) {
        .session => DEFAULT_SESSION_FORMAT,
        .window => DEFAULT_WINDOW_FORMAT,
        .pane => DEFAULT_PANE_FORMAT,
    };
    return format_mod.format_require_complete(xm.allocator, template, &ctx) orelse fallbackText(item_type, session_ptr, wl, pane);
}

fn fallbackText(item_type: ItemType, session_ptr: *T.Session, wl: ?*T.Winlink, pane: ?*T.WindowPane) []u8 {
    return switch (item_type) {
        .session => xm.xasprintf("{s}", .{session_ptr.name}),
        .window => xm.xasprintf("{d}:{s}", .{ wl.?.idx, wl.?.window.name }),
        .pane => xm.xasprintf("{d}: pane %{d}", .{ paneIndex(wl.?.window, pane.?), pane.?.id }),
    };
}

fn formatContext(session_ptr: *T.Session, wl: ?*T.Winlink, pane: ?*T.WindowPane) format_mod.FormatContext {
    return .{
        .session = session_ptr,
        .winlink = wl,
        .window = if (wl) |value| value.window else if (session_ptr.curw) |current| current.window else null,
        .pane = pane orelse if (wl) |value| value.window.active else if (session_ptr.curw) |current| current.window.active else null,
        .format_type = format_mod.infer_format_type(session_ptr, wl, pane),
    };
}

fn sessionMatchesFilter(data: *const WindowTreeModeData, session_ptr: *T.Session) bool {
    const filter = data.filter orelse return true;
    const ctx = formatContext(session_ptr, null, null);
    return format_mod.format_filter_match(xm.allocator, filter, &ctx) orelse false;
}

fn windowMatchesFilter(data: *const WindowTreeModeData, session_ptr: *T.Session, wl: *T.Winlink) bool {
    const filter = data.filter orelse return true;
    const ctx = formatContext(session_ptr, wl, wl.window.active);
    if (format_mod.format_filter_match(xm.allocator, filter, &ctx) orelse false)
        return true;

    for (wl.window.panes.items) |pane| {
        if (paneMatchesFilter(data, session_ptr, wl, pane))
            return true;
    }
    return false;
}

fn paneMatchesFilter(data: *const WindowTreeModeData, session_ptr: *T.Session, wl: *T.Winlink, pane: *T.WindowPane) bool {
    const filter = data.filter orelse return true;
    const ctx = formatContext(session_ptr, wl, pane);
    return format_mod.format_filter_match(xm.allocator, filter, &ctx) orelse false;
}

fn searchItem(tree: *mode_tree.Data, itemdata: ?*anyopaque, search: []const u8, ignore_case: bool) bool {
    _ = tree;
    const item: *TreeItem = @ptrCast(@alignCast(itemdata.?));
    return contains(item.text, search, ignore_case) or contains(itemName(item), search, ignore_case);
}

fn itemName(item: *const TreeItem) []const u8 {
    return switch (item.item_type) {
        .session => item.session.name,
        .window => item.winlink.?.window.name,
        .pane => item.pane.?.screen.title orelse "",
    };
}

fn renderLine(tree: *const mode_tree.Data, index: usize) []u8 {
    const line = tree.line_list.items[index];
    const item: *TreeItem = @ptrCast(@alignCast(line.item.itemdata.?));
    const current = if (index == tree.current) ">" else " ";
    const tagged = if (line.item.tagged) "*" else " ";
    const expanded = if (line.item.children.items.len == 0)
        " "
    else if (line.item.expanded)
        "-"
    else
        "+";

    var out: std.ArrayList(u8) = .{};
    defer out.deinit(xm.allocator);

    out.appendSlice(xm.allocator, current) catch unreachable;
    out.appendSlice(xm.allocator, tagged) catch unreachable;
    out.append(xm.allocator, ' ') catch unreachable;

    const key_width = maxKeyLabelWidth(tree);
    if (key_width != 0) {
        const label_width = key_width + 2;
        if (line.item.keystr) |keystr| {
            out.append(xm.allocator, '[') catch unreachable;
            out.appendSlice(xm.allocator, keystr) catch unreachable;
            out.append(xm.allocator, ']') catch unreachable;

            const pad = label_width - (keystr.len + 2);
            var i: usize = 0;
            while (i < pad) : (i += 1) out.append(xm.allocator, ' ') catch unreachable;
        } else {
            var i: usize = 0;
            while (i < label_width) : (i += 1) out.append(xm.allocator, ' ') catch unreachable;
        }
        out.append(xm.allocator, ' ') catch unreachable;
    }

    var depth: u32 = 0;
    while (depth < line.depth) : (depth += 1) {
        out.appendSlice(xm.allocator, "  ") catch unreachable;
    }

    out.appendSlice(xm.allocator, expanded) catch unreachable;
    out.appendSlice(xm.allocator, " ") catch unreachable;
    out.appendSlice(xm.allocator, switch (item.item_type) {
        .session => "session ",
        .window => "window  ",
        .pane => "pane    ",
    }) catch unreachable;
    out.appendSlice(xm.allocator, item.text) catch unreachable;

    return out.toOwnedSlice(xm.allocator) catch unreachable;
}

fn chooseCurrent(wme: *T.WindowModeEntry, client: ?*T.Client, session: *T.Session, wl: *T.Winlink) void {
    _ = session;
    _ = wl;
    const data = modeData(wme);
    const item_ptr = mode_tree.getCurrent(data.tree) orelse return;
    const item: *TreeItem = @ptrCast(@alignCast(item_ptr));
    const target_name = targetName(item) orelse return;
    defer xm.allocator.free(target_name);

    mode_tree.runCommand(client, null, data.command, target_name);
    _ = window_mode_runtime.resetMode(wme.wp);
}

fn targetName(item: *const TreeItem) ?[]u8 {
    return switch (item.item_type) {
        .session => xm.xasprintf("={s}:", .{item.session.name}),
        .window => xm.xasprintf("={s}:{d}.", .{ item.session.name, item.winlink.?.idx }),
        .pane => xm.xasprintf("={s}:{d}.%{d}", .{ item.session.name, item.winlink.?.idx, item.pane.?.id }),
    };
}

fn focusTarget(data: *WindowTreeModeData) void {
    switch (data.kind) {
        .session => {
            if (data.fs.s) |session_ptr| _ = mode_tree.setCurrent(data.tree, tagForSession(session_ptr));
        },
        .window => {
            if (data.fs.s) |session_ptr| mode_tree.expand(data.tree, tagForSession(session_ptr));
            if (data.fs.wl) |wl| _ = mode_tree.setCurrent(data.tree, tagForWinlink(wl));
        },
        .pane => {
            if (data.fs.s) |session_ptr| mode_tree.expand(data.tree, tagForSession(session_ptr));
            if (data.fs.wl) |wl| mode_tree.expand(data.tree, tagForWinlink(wl));
            if (data.fs.wp) |pane| {
                if (!mode_tree.setCurrent(data.tree, tagForPane(pane))) {
                    if (data.fs.wl) |wl| {
                        _ = mode_tree.setCurrent(data.tree, tagForWinlink(wl));
                    }
                }
            }
        },
    }
}

fn tagForSession(session_ptr: *T.Session) u64 {
    return @intFromPtr(session_ptr);
}

fn tagForWinlink(wl: *T.Winlink) u64 {
    return @intFromPtr(wl);
}

fn tagForPane(pane: *T.WindowPane) u64 {
    return @intFromPtr(pane);
}

fn paneIndex(w: *T.Window, pane: *T.WindowPane) u32 {
    for (w.panes.items, 0..) |candidate, idx| {
        if (candidate == pane) return @intCast(idx);
    }
    return 0;
}

fn pageUp(tree: *mode_tree.Data, rows: u32, repeat: u32) void {
    const step = if (rows > 1) rows - 1 else 1;
    var remaining = repeat;
    while (remaining > 0) : (remaining -= 1) {
        var moved: u32 = 0;
        while (moved < step) : (moved += 1) mode_tree.up(tree, false);
    }
}

fn pageDown(tree: *mode_tree.Data, rows: u32, repeat: u32) void {
    const step = if (rows > 1) rows - 1 else 1;
    var remaining = repeat;
    while (remaining > 0) : (remaining -= 1) {
        var moved: u32 = 0;
        while (moved < step) : (moved += 1) _ = mode_tree.down(tree, false);
    }
}

fn viewRows(wp: *const T.WindowPane) u32 {
    return if (wp.screen.grid.sy > 0) wp.screen.grid.sy - 1 else 0;
}

fn shouldSkipSession(data: *const WindowTreeModeData, session_ptr: *T.Session, current_group: ?*T.SessionGroup) bool {
    const group = sess.session_group_contains(session_ptr) orelse return false;
    if (current_group) |current| {
        if (group == current)
            return session_ptr != data.fs.s.?;
    }
    return group.sessions.items.len != 0 and group.sessions.items[0] != session_ptr;
}

fn freeItems(data: *WindowTreeModeData) void {
    for (data.items.items) |item| {
        xm.allocator.free(item.text);
        xm.allocator.destroy(item);
    }
    data.items.clearRetainingCapacity();
}

fn defaultFormat(kind: DisplayKind) []const u8 {
    return switch (kind) {
        .session => DEFAULT_SESSION_FORMAT,
        .window => DEFAULT_WINDOW_FORMAT,
        .pane => DEFAULT_PANE_FORMAT,
    };
}

fn contains(haystack: []const u8, needle: []const u8, ignore_case: bool) bool {
    if (!ignore_case) return std.mem.indexOf(u8, haystack, needle) != null;
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;

    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var matched = true;
        for (needle, 0..) |needle_ch, idx| {
            if (std.ascii.toLower(haystack[i + idx]) != std.ascii.toLower(needle_ch)) {
                matched = false;
                break;
            }
        }
        if (matched) return true;
    }
    return false;
}

fn repeatCount(wme: *T.WindowModeEntry) u32 {
    return if (wme.prefix == 0) 1 else wme.prefix;
}

fn keyForLineCallback(tree: *mode_tree.Data, itemdata: ?*anyopaque, line: u32) T.key_code {
    const data: *WindowTreeModeData = @ptrCast(@alignCast(tree.modedata.?));
    const item: *TreeItem = @ptrCast(@alignCast(itemdata.?));
    return keyForLine(data, item, line);
}

fn keyForLine(data: *const WindowTreeModeData, item: *const TreeItem, line: u32) T.key_code {
    var ctx = formatContext(item.session, item.winlink, item.pane);
    ctx.line = line;

    const expanded = format_mod.format_require_complete(xm.allocator, data.key_format, &ctx) orelse return T.KEYC_NONE;
    defer xm.allocator.free(expanded);

    const key = key_string.key_string_lookup_string(expanded);
    if (key == T.KEYC_UNKNOWN or key == T.KEYC_NONE) return T.KEYC_NONE;
    return key;
}

fn maxKeyLabelWidth(tree: *const mode_tree.Data) usize {
    var width: usize = 0;
    for (tree.line_list.items) |line| {
        if (line.item.keystr) |keystr|
            width = @max(width, keystr.len);
    }
    return width;
}

fn shortcutLineForKey(tree: *const mode_tree.Data, key: T.key_code) ?u32 {
    if (key == T.KEYC_NONE or key == T.KEYC_UNKNOWN) return null;
    for (tree.line_list.items, 0..) |line, idx| {
        if (line.item.key == key)
            return @intCast(idx);
    }
    return null;
}

fn adjustOffsetForCurrent(tree: *mode_tree.Data) void {
    if (tree.height == 0) return;
    if (tree.current < tree.offset) {
        tree.offset = tree.current;
        return;
    }
    if (tree.current >= tree.offset + tree.height)
        tree.offset = tree.current - tree.height + 1;
}

fn unsupportedCommand(client: ?*T.Client, command: []const u8) void {
    const cl = client orelse return;
    const text = xm.xasprintf("Tree-mode command not supported yet: {s}", .{command});
    defer xm.allocator.free(text);
    status_runtime.present_client_message(cl, text);
}

fn promptTreeKill(client: ?*T.Client, wme: *T.WindowModeEntry, action: TreePromptAction) void {
    const cl = client orelse return;
    const data = modeData(wme);

    const prompt = switch (action) {
        .command => return,
        .kill_current => killCurrentPrompt(data) orelse return,
        .kill_tagged => blk: {
            const tagged = mode_tree.countTagged(data.tree);
            if (tagged == 0) return;
            break :blk xm.xasprintf("Kill {d} tagged? ", .{tagged});
        },
    };
    defer xm.allocator.free(prompt);

    const state = xm.allocator.create(TreePromptState) catch unreachable;
    state.* = .{
        .pane_id = wme.wp.id,
        .action = action,
    };
    status_prompt.status_prompt_set(
        cl,
        null,
        prompt,
        "",
        treePromptCallback,
        null,
        treePromptFree,
        state,
        status_prompt.PROMPT_SINGLE | status_prompt.PROMPT_NOFORMAT,
        .command,
    );
}

fn promptTreeCommand(client: ?*T.Client, wme: *T.WindowModeEntry) void {
    const cl = client orelse return;
    const data = modeData(wme);
    const tagged = mode_tree.countTagged(data.tree);
    const prompt = if (tagged != 0)
        xm.xasprintf("({d} tagged) ", .{tagged})
    else
        xm.xstrdup("(current) ");
    defer xm.allocator.free(prompt);

    const state = xm.allocator.create(TreePromptState) catch unreachable;
    state.* = .{
        .pane_id = wme.wp.id,
        .action = .command,
    };
    status_prompt.status_prompt_set(
        cl,
        null,
        prompt,
        "",
        treePromptCallback,
        null,
        treePromptFree,
        state,
        status_prompt.PROMPT_NOFORMAT,
        .command,
    );
}

fn treePromptFree(data: ?*anyopaque) void {
    const state: *TreePromptState = @ptrCast(@alignCast(data orelse return));
    xm.allocator.destroy(state);
}

fn treeDoneFree(data: ?*anyopaque) void {
    const state: *TreeDoneState = @ptrCast(@alignCast(data orelse return));
    xm.allocator.destroy(state);
}

fn treeDoneCallback(_: *cmdq.CmdqItem, data: ?*anyopaque) T.CmdRetval {
    const state: *TreeDoneState = @ptrCast(@alignCast(data orelse return .normal));
    rebuildAndDrawForPaneId(state.pane_id);
    return .normal;
}

fn queueTreeDone(client: ?*T.Client, pane_id: u32) void {
    const state = xm.allocator.create(TreeDoneState) catch unreachable;
    state.* = .{ .pane_id = pane_id };
    const item = cmdq.cmdq_get_callback2("window-tree-done", treeDoneCallback, state, treeDoneFree);
    _ = cmdq.cmdq_append_item(client, item);
}

fn treePromptCallback(client: *T.Client, data: ?*anyopaque, s: ?[]const u8, _: bool) i32 {
    const state: *TreePromptState = @ptrCast(@alignCast(data orelse return 0));
    const tree_data = treeModeDataForPaneId(state.pane_id) orelse return 0;
    switch (state.action) {
        .command => {
            const command = s orelse return 0;
            if (command.len == 0) return 0;
            runTreeCommand(tree_data, client, command);
            queueTreeDone(client, state.pane_id);
        },
        .kill_current => {
            if (!confirmedPrompt(s orelse return 0)) return 0;
            killCurrentTreeItem(tree_data);
            server_fn.server_renumber_all();
            queueTreeDone(client, state.pane_id);
        },
        .kill_tagged => {
            if (!confirmedPrompt(s orelse return 0)) return 0;
            killTaggedTreeItems(tree_data);
            server_fn.server_renumber_all();
            queueTreeDone(client, state.pane_id);
        },
    }
    return 0;
}

fn confirmedPrompt(text: []const u8) bool {
    return text.len == 1 and std.ascii.toLower(text[0]) == 'y';
}

fn treeModeDataForPaneId(pane_id: u32) ?*WindowTreeModeData {
    const pane = window.window_pane_find_by_id(pane_id) orelse return null;
    const wme = window.window_pane_mode(pane) orelse return null;
    if (wme.mode != &window_tree_mode) return null;
    return modeData(wme);
}

fn rebuildAndDrawForPaneId(pane_id: u32) void {
    const pane = window.window_pane_find_by_id(pane_id) orelse return;
    const wme = window.window_pane_mode(pane) orelse return;
    if (wme.mode != &window_tree_mode) return;
    rebuildAndDraw(wme);
}

fn killCurrentTreeItem(data: *WindowTreeModeData) void {
    const current_ptr = mode_tree.getCurrent(data.tree) orelse return;
    const item: *TreeItem = @ptrCast(@alignCast(current_ptr));
    killTreeItem(item);
}

fn killCurrentPrompt(data: *WindowTreeModeData) ?[]u8 {
    const current_ptr = mode_tree.getCurrent(data.tree) orelse return null;
    const item: *TreeItem = @ptrCast(@alignCast(current_ptr));
    return switch (item.item_type) {
        .session => xm.xasprintf("Kill session {s}? ", .{item.session.name}),
        .window => xm.xasprintf("Kill window {d}? ", .{item.winlink.?.idx}),
        .pane => xm.xasprintf("Kill pane {d}? ", .{paneIndex(item.winlink.?.window, item.pane.?)}),
    };
}

fn killTaggedTreeItems(data: *WindowTreeModeData) void {
    for (data.tree.line_list.items) |line| {
        if (!line.item.tagged) continue;
        const raw = line.item.itemdata orelse continue;
        const item: *TreeItem = @ptrCast(@alignCast(raw));
        killTreeItem(item);
    }
    mode_tree.clearAllTagged(data.tree);
}

fn killTreeItem(item: *const TreeItem) void {
    switch (item.item_type) {
        .session => {
            server.server_destroy_session(item.session);
            sess.session_destroy(item.session, true, "window_tree_kill_item");
        },
        .window => {
            if (item.winlink) |wl| server_fn.server_kill_window(wl.window, false);
        },
        .pane => {
            if (item.pane) |pane| server_fn.server_kill_pane(pane);
        },
    }
}

fn runTreeCommand(data: *WindowTreeModeData, client: ?*T.Client, command: []const u8) void {
    data.entered = command;
    defer data.entered = null;
    mode_tree.eachTagged(data.tree, treeCommandEach, client, T.KEYC_NONE, true);
}

fn treeCommandEach(mtd: *mode_tree.Data, itemdata: ?*anyopaque, client: ?*T.Client, _: T.key_code) void {
    const data: *WindowTreeModeData = @ptrCast(@alignCast(mtd.modedata.?));
    const item: *const TreeItem = @ptrCast(@alignCast(itemdata orelse return));
    const name = targetName(item) orelse return;
    defer xm.allocator.free(name);

    const wl = item.winlink;
    var fs: T.CmdFindState = .{
        .s = item.session,
        .wl = wl,
        .w = if (wl) |value| value.window else null,
        .wp = if (item.pane) |pane| pane else if (wl) |value| value.window.active else null,
        .idx = if (wl) |value| value.idx else 0,
    };
    const entered = data.entered orelse return;
    mode_tree.runCommand(client, &fs, entered, name);
}

// ── Public API: wrappers matching tmux C function names ─────────────────
//
// Each wrapper below corresponds to a static function in tmux window-tree.c.
// Where the logic already exists under a Zig-idiomatic name the wrapper
// simply delegates; where the tmux function has no equivalent yet a minimal
// stub (or a new implementation) is provided.

/// tmux: window_tree_init – enter tree mode on a pane.
pub const window_tree_init = enterMode;

/// tmux: window_tree_free – release mode resources.
pub const window_tree_free = windowTreeClose;

/// tmux: window_tree_resize – resize the mode-tree display area.
pub fn window_tree_resize(wme: *T.WindowModeEntry, sx: u32, sy: u32) void {
    mode_tree.resize(modeData(wme).tree, sx, sy);
}

/// tmux: window_tree_update – rebuild and redraw after external changes.
pub fn window_tree_update(wme: *T.WindowModeEntry) void {
    const data = modeData(wme);
    mode_tree.build(data.tree);
    redraw(wme);
}

/// tmux: window_tree_key – low-level key dispatch.
pub const window_tree_key = windowTreeKey;

/// tmux: window_tree_build – mode_tree build callback.
pub const window_tree_build = buildTree;

/// tmux: window_tree_draw – draw the preview area below the tree.
pub fn window_tree_draw(
    data: *WindowTreeModeData,
    ctx: *T.ScreenWriteCtx,
    top: u32,
    height: u32,
) void {
    drawPreview(data, ctx, top, height);
}

/// tmux: window_tree_draw_session – draw session preview tiles.
pub fn window_tree_draw_session(
    data: *WindowTreeModeData,
    s: *T.Session,
    ctx: *T.ScreenWriteCtx,
    top: u32,
    height: u32,
) void {
    drawSessionPreview(data, s, ctx, top, height);
}

/// tmux: window_tree_draw_window – draw window/pane preview tiles.
pub fn window_tree_draw_window(
    data: *WindowTreeModeData,
    w: *T.Window,
    ctx: *T.ScreenWriteCtx,
    top: u32,
    height: u32,
) void {
    drawWindowPreview(data, w, ctx, top, height);
}

/// tmux: window_tree_draw_label – draw a centred label inside a tile.
pub fn window_tree_draw_label(
    ctx: *T.ScreenWriteCtx,
    top: u32,
    left: u32,
    width: u32,
    height: u32,
    text: []const u8,
) void {
    drawCenteredText(ctx, top, left, width, height, text);
}

/// tmux: window_tree_search – mode_tree search callback.
pub const window_tree_search = searchItem;

/// tmux: window_tree_get_key – mode_tree key-label callback.
pub const window_tree_get_key = keyForLineCallback;

/// tmux: window_tree_get_target – build a target string for the item.
pub const window_tree_get_target = targetName;

/// tmux: window_tree_mouse – translate mouse events in the preview area.
pub const window_tree_mouse = windowTreeMouse;

/// tmux: window_tree_pull_item – resolve a TreeItem into session/winlink/pane.
pub fn window_tree_pull_item(item: *const TreeItem) struct {
    session: ?*T.Session,
    winlink: ?*T.Winlink,
    pane: ?*T.WindowPane,
} {
    return .{
        .session = item.session,
        .winlink = item.winlink,
        .pane = item.pane,
    };
}

/// tmux: window_tree_add_item – allocate and register a new tree item.
pub const window_tree_add_item = allocItem;

/// tmux: window_tree_free_item – free a single tree item.
pub fn window_tree_free_item(item: *TreeItem) void {
    xm.allocator.free(item.text);
    xm.allocator.destroy(item);
}

/// tmux: window_tree_build_pane – add a pane node to the tree.
pub const window_tree_build_pane = addPane;

/// tmux: window_tree_filter_pane – test whether a pane matches the filter.
pub const window_tree_filter_pane = paneMatchesFilter;

/// tmux: window_tree_build_window – add a window node to the tree.
pub const window_tree_build_window = addWindow;

/// tmux: window_tree_build_session – add a session node to the tree.
pub const window_tree_build_session = addSession;

/// tmux: window_tree_sort – configure sort order for tree mode.
pub fn window_tree_sort(crit: *T.SortCriteria) void {
    crit.order_seq = sort_mod.window_tree_sort_order_seq;
    if (crit.order == .end)
        crit.order = sort_mod.window_tree_sort_order_seq[0];
}

/// tmux: window_tree_help – return help line data.
pub const window_tree_help_lines = [_][]const u8{
    "      Enter  Choose selected item",
    "       S-Up  Swap current and previous window",
    "     S-Down  Swap current and next window",
    "          x  Kill selected item",
    "          X  Kill tagged items",
    "          <  Scroll previews left",
    "          >  Scroll previews right",
    "          m  Set the marked pane",
    "          M  Clear the marked pane",
    "          :  Run a command for each tagged item",
    "          f  Enter a format",
    "          H  Jump to the starting pane",
};

pub fn window_tree_help() struct { width: u32, item_noun: []const u8 } {
    return .{ .width = 51, .item_noun = "item" };
}

/// tmux: window_tree_menu – forward a menu key to the tree key handler.
pub fn window_tree_menu(
    wme: *T.WindowModeEntry,
    client: ?*T.Client,
    key_code: T.key_code,
) void {
    if (wme.mode != &window_tree_mode) return;
    const data = modeData(wme);
    const session = data.fs.s orelse return;
    const wl = data.fs.wl orelse return;
    windowTreeKey(wme, client, session, wl, key_code, null);
}

/// tmux: window_tree_swap – swap two window items in the tree.
///
/// In tmux this swaps the underlying winlinks.  The Zig port does not
/// yet implement full winlink manipulation; returns false (swap refused).
pub fn window_tree_swap(
    cur_itemdata: ?*anyopaque,
    other_itemdata: ?*anyopaque,
    sort_crit: *T.SortCriteria,
) bool {
    _ = cur_itemdata;
    _ = other_itemdata;
    _ = sort_crit;
    return false;
}

/// tmux: window_tree_destroy – reference-counted destroy.
///
/// The Zig port manages teardown through windowTreeClose (window_tree_free);
/// this wrapper is a no-op compatibility shim.
pub fn window_tree_destroy(data: *WindowTreeModeData) void {
    _ = data;
}

/// tmux: window_tree_command_each – run a command for each tagged item.
pub fn window_tree_command_each(
    data: *WindowTreeModeData,
    item: *const TreeItem,
    client: ?*T.Client,
) void {
    const name = targetName(item) orelse return;
    defer xm.allocator.free(name);

    const wl = item.winlink;
    var fs: T.CmdFindState = .{
        .s = item.session,
        .wl = wl,
        .w = if (wl) |w| w.window else null,
        .wp = if (wl) |w| w.window.active else null,
        .idx = if (wl) |w| w.idx else 0,
    };
    mode_tree.runCommand(client, &fs, data.command, name);
}

/// tmux: window_tree_command_done – callback after tagged commands complete.
pub fn window_tree_command_done(data: *WindowTreeModeData) void {
    if (data.fs.wp) |pane| rebuildAndDrawForPaneId(pane.id);
}

/// tmux: window_tree_command_callback – prompt callback for running commands.
pub fn window_tree_command_callback(
    client: ?*T.Client,
    data: *WindowTreeModeData,
    s: ?[]const u8,
) bool {
    const cl = client orelse return false;
    const command = s orelse return false;
    if (command.len == 0) return false;
    runTreeCommand(data, cl, command);
    if (data.fs.wp) |pane| queueTreeDone(cl, pane.id);
    return true;
}

/// tmux: window_tree_command_free – release reference from command prompt.
pub fn window_tree_command_free(data: *WindowTreeModeData) void {
    _ = data;
}

/// tmux: window_tree_kill_each – kill session/window/pane for a tagged item.
pub fn window_tree_kill_each(
    item: *const TreeItem,
    client: ?*T.Client,
) void {
    _ = client;
    killTreeItem(item);
}

/// tmux: window_tree_kill_current_callback – prompt callback to kill current.
pub fn window_tree_kill_current_callback(
    client: ?*T.Client,
    data: *WindowTreeModeData,
    s: ?[]const u8,
) bool {
    const cl = client orelse return false;
    if (!confirmedPrompt(s orelse return false)) return false;
    killCurrentTreeItem(data);
    server_fn.server_renumber_all();
    if (data.fs.wp) |pane| queueTreeDone(cl, pane.id);
    return true;
}

/// tmux: window_tree_kill_tagged_callback – prompt callback to kill tagged.
pub fn window_tree_kill_tagged_callback(
    client: ?*T.Client,
    data: *WindowTreeModeData,
    s: ?[]const u8,
) bool {
    const cl = client orelse return false;
    if (!confirmedPrompt(s orelse return false)) return false;
    killTaggedTreeItems(data);
    server_fn.server_renumber_all();
    if (data.fs.wp) |pane| queueTreeDone(cl, pane.id);
    return true;
}

test "window-tree enterMode builds reduced hierarchy and focuses the target pane" {
    const env_mod = @import("environ.zig");
    const options_mod = @import("options.zig");
    const spawn = @import("spawn.zig");

    sess.session_init_globals(xm.allocator);
    window.window_init_globals(xm.allocator);

    options_mod.global_options = options_mod.options_create(null);
    defer options_mod.options_free(options_mod.global_options);
    options_mod.global_s_options = options_mod.options_create(null);
    defer options_mod.options_free(options_mod.global_s_options);
    options_mod.global_w_options = options_mod.options_create(null);
    defer options_mod.options_free(options_mod.global_w_options);
    options_mod.options_default_all(options_mod.global_options, T.OPTIONS_TABLE_SERVER);
    options_mod.options_default_all(options_mod.global_s_options, T.OPTIONS_TABLE_SESSION);
    options_mod.options_default_all(options_mod.global_w_options, T.OPTIONS_TABLE_WINDOW);

    env_mod.global_environ = env_mod.environ_create();
    defer env_mod.environ_free(env_mod.global_environ);

    const session_ptr = sess.session_create(null, "tree-session", "/", env_mod.environ_create(), options_mod.options_create(options_mod.global_s_options), null);
    defer if (sess.session_find("tree-session") != null) sess.session_destroy(session_ptr, false, "test");

    var cause: ?[]u8 = null;
    var ctx: T.SpawnContext = .{ .s = session_ptr, .idx = -1, .flags = T.SPAWN_EMPTY };
    const wl = spawn.spawn_window(&ctx, &cause).?;
    session_ptr.curw = wl;

    const extra = window.window_add_pane(wl.window, null, 80, 24);
    wl.window.active = extra;
    extra.screen.title = xm.xstrdup("needle-pane");

    var target = T.CmdFindState{
        .s = session_ptr,
        .wl = wl,
        .w = wl.window,
        .wp = extra,
        .idx = wl.idx,
    };

    const wme = enterMode(extra, .{
        .fs = &target,
        .kind = .pane,
        .filter = "#{m:*needle*,#{pane_title}}",
    });
    defer {
        if (window.window_pane_mode(extra) != null)
            _ = window_mode_runtime.resetMode(extra);
    }

    const data = modeData(wme);
    try std.testing.expectEqual(&window_tree_mode, wme.mode);
    try std.testing.expectEqual(@as(usize, 3), data.tree.line_list.items.len);
    const item_ptr = mode_tree.getCurrent(data.tree) orelse return error.TestUnexpectedResult;
    const item: *TreeItem = @ptrCast(@alignCast(item_ptr));
    try std.testing.expectEqual(ItemType.pane, item.item_type);
    try std.testing.expect(item.pane == extra);
}

test "window-tree choose runs the command template for the selected target" {
    const cmdq_mod = @import("cmd-queue.zig");
    const env_mod = @import("environ.zig");
    const options_mod = @import("options.zig");
    const spawn = @import("spawn.zig");

    cmdq_mod.cmdq_reset_for_tests();
    defer cmdq_mod.cmdq_reset_for_tests();

    sess.session_init_globals(xm.allocator);
    window.window_init_globals(xm.allocator);

    options_mod.global_options = options_mod.options_create(null);
    defer options_mod.options_free(options_mod.global_options);
    options_mod.global_s_options = options_mod.options_create(null);
    defer options_mod.options_free(options_mod.global_s_options);
    options_mod.global_w_options = options_mod.options_create(null);
    defer options_mod.options_free(options_mod.global_w_options);
    options_mod.options_default_all(options_mod.global_options, T.OPTIONS_TABLE_SERVER);
    options_mod.options_default_all(options_mod.global_s_options, T.OPTIONS_TABLE_SESSION);
    options_mod.options_default_all(options_mod.global_w_options, T.OPTIONS_TABLE_WINDOW);

    env_mod.global_environ = env_mod.environ_create();
    defer env_mod.environ_free(env_mod.global_environ);

    const session_ptr = sess.session_create(null, "tree-choose", "/", env_mod.environ_create(), options_mod.options_create(options_mod.global_s_options), null);
    defer if (sess.session_find("tree-choose") != null) sess.session_destroy(session_ptr, false, "test");

    var cause: ?[]u8 = null;
    var ctx: T.SpawnContext = .{ .s = session_ptr, .idx = -1, .flags = T.SPAWN_EMPTY };
    const wl = spawn.spawn_window(&ctx, &cause).?;
    session_ptr.curw = wl;

    const extra = window.window_add_pane(wl.window, null, 80, 24);
    wl.window.active = extra;

    var env = T.Environ.init(xm.allocator);
    defer env.deinit();

    var client = T.Client{
        .name = "tree-client",
        .environ = &env,
        .tty = undefined,
        .status = .{},
        .flags = T.CLIENT_ATTACHED,
        .session = session_ptr,
    };
    client.tty = .{ .client = &client };

    var target = T.CmdFindState{
        .s = session_ptr,
        .wl = wl,
        .w = wl.window,
        .wp = extra,
        .idx = wl.idx,
    };

    const wme = enterMode(extra, .{
        .fs = &target,
        .kind = .pane,
        .command = "select-pane -t '%%'",
    });
    try std.testing.expect(window.window_pane_mode(extra) != null);

    wl.window.active = wl.window.panes.items[0];
    var args_cause: ?[]u8 = null;
    var args = try args_mod.args_parse(xm.allocator, &.{"choose"}, "", 1, 1, &args_cause);
    defer args.deinit();
    windowTreeCommand(wme, &client, session_ptr, wl, @ptrCast(&args), null);
    while (cmdq_mod.cmdq_next(&client) != 0) {}

    try std.testing.expect(wl.window.active == extra);
    try std.testing.expect(window.window_pane_mode(extra) == null);
}

test "window-tree command prompt runs the entered command for the current item" {
    const cmdq_mod = @import("cmd-queue.zig");
    const env_mod = @import("environ.zig");
    const options_mod = @import("options.zig");
    const spawn = @import("spawn.zig");

    cmdq_mod.cmdq_reset_for_tests();
    defer cmdq_mod.cmdq_reset_for_tests();

    sess.session_init_globals(xm.allocator);
    window.window_init_globals(xm.allocator);

    options_mod.global_options = options_mod.options_create(null);
    defer options_mod.options_free(options_mod.global_options);
    options_mod.global_s_options = options_mod.options_create(null);
    defer options_mod.options_free(options_mod.global_s_options);
    options_mod.global_w_options = options_mod.options_create(null);
    defer options_mod.options_free(options_mod.global_w_options);
    options_mod.options_default_all(options_mod.global_options, T.OPTIONS_TABLE_SERVER);
    options_mod.options_default_all(options_mod.global_s_options, T.OPTIONS_TABLE_SESSION);
    options_mod.options_default_all(options_mod.global_w_options, T.OPTIONS_TABLE_WINDOW);

    env_mod.global_environ = env_mod.environ_create();
    defer env_mod.environ_free(env_mod.global_environ);

    const session_ptr = sess.session_create(null, "tree-prompt", "/", env_mod.environ_create(), options_mod.options_create(options_mod.global_s_options), null);
    defer if (sess.session_find("tree-prompt") != null) sess.session_destroy(session_ptr, false, "test");

    var cause: ?[]u8 = null;
    var ctx: T.SpawnContext = .{ .s = session_ptr, .idx = -1, .flags = T.SPAWN_EMPTY };
    const wl = spawn.spawn_window(&ctx, &cause).?;
    session_ptr.curw = wl;

    const original = wl.window.active.?;
    const extra = window.window_add_pane(wl.window, null, 80, 24);
    wl.window.active = extra;

    var env = T.Environ.init(xm.allocator);
    defer env.deinit();

    var client = T.Client{
        .name = "tree-prompt-client",
        .environ = &env,
        .tty = undefined,
        .status = .{},
        .flags = T.CLIENT_ATTACHED,
        .session = session_ptr,
    };
    client.tty = .{ .client = &client };

    var target = T.CmdFindState{
        .s = session_ptr,
        .wl = wl,
        .w = wl.window,
        .wp = extra,
        .idx = wl.idx,
    };

    const wme = enterMode(extra, .{
        .fs = &target,
        .kind = .pane,
    });
    defer {
        status_prompt.status_prompt_clear(&client);
        if (window.window_pane_mode(extra) != null)
            _ = window_mode_runtime.resetMode(extra);
    }

    wl.window.active = original;
    windowTreeKey(wme, &client, session_ptr, wl, ':', null);
    try std.testing.expect(status_prompt.status_prompt_active(&client));
    try std.testing.expectEqualStrings("(current) ", status_prompt.status_prompt_message(&client).?);

    try std.testing.expect(window_tree_command_callback(&client, modeData(wme), "select-pane -t '%%'"));
    status_prompt.status_prompt_clear(&client);
    while (cmdq_mod.cmdq_next(&client) != 0) {}

    try std.testing.expect(wl.window.active == extra);
    try std.testing.expect(window.window_pane_mode(extra) != null);
}

test "window-tree custom key format renders labels and chooses the matching line" {
    const cmdq_mod = @import("cmd-queue.zig");
    const env_mod = @import("environ.zig");
    const options_mod = @import("options.zig");
    const spawn = @import("spawn.zig");

    cmdq_mod.cmdq_reset_for_tests();
    defer cmdq_mod.cmdq_reset_for_tests();

    sess.session_init_globals(xm.allocator);
    window.window_init_globals(xm.allocator);

    options_mod.global_options = options_mod.options_create(null);
    defer options_mod.options_free(options_mod.global_options);
    options_mod.global_s_options = options_mod.options_create(null);
    defer options_mod.options_free(options_mod.global_s_options);
    options_mod.global_w_options = options_mod.options_create(null);
    defer options_mod.options_free(options_mod.global_w_options);
    options_mod.options_default_all(options_mod.global_options, T.OPTIONS_TABLE_SERVER);
    options_mod.options_default_all(options_mod.global_s_options, T.OPTIONS_TABLE_SESSION);
    options_mod.options_default_all(options_mod.global_w_options, T.OPTIONS_TABLE_WINDOW);

    env_mod.global_environ = env_mod.environ_create();
    defer env_mod.environ_free(env_mod.global_environ);

    const session_ptr = sess.session_create(null, "tree-key-format", "/", env_mod.environ_create(), options_mod.options_create(options_mod.global_s_options), null);
    defer if (sess.session_find("tree-key-format") != null) sess.session_destroy(session_ptr, false, "test");

    var cause: ?[]u8 = null;
    var ctx: T.SpawnContext = .{ .s = session_ptr, .idx = -1, .flags = T.SPAWN_EMPTY };
    const wl = spawn.spawn_window(&ctx, &cause).?;
    session_ptr.curw = wl;

    const original = wl.window.active.?;
    const extra = window.window_add_pane(wl.window, null, 80, 24);
    wl.window.active = extra;

    var env = T.Environ.init(xm.allocator);
    defer env.deinit();

    var client = T.Client{
        .name = "tree-key-client",
        .environ = &env,
        .tty = undefined,
        .status = .{},
        .flags = T.CLIENT_ATTACHED,
        .session = session_ptr,
    };
    client.tty = .{ .client = &client };

    var target = T.CmdFindState{
        .s = session_ptr,
        .wl = wl,
        .w = wl.window,
        .wp = extra,
        .idx = wl.idx,
    };

    const wme = enterMode(extra, .{
        .fs = &target,
        .kind = .pane,
        .command = "select-pane -t '%%'",
        .key_format = "#{line}",
    });
    try std.testing.expect(window.window_pane_mode(extra) != null);

    const data = modeData(wme);
    try std.testing.expectEqual(@as(T.key_code, '0'), data.tree.line_list.items[0].item.key);
    try std.testing.expectEqual(@as(T.key_code, '1'), data.tree.line_list.items[1].item.key);
    const first_line = renderLine(data.tree, 0);
    defer xm.allocator.free(first_line);
    try std.testing.expect(std.mem.indexOf(u8, first_line, "[0]") != null);

    const target_key = blk: {
        for (data.tree.line_list.items) |line| {
            const tree_item: *TreeItem = @ptrCast(@alignCast(line.item.itemdata.?));
            if (tree_item.item_type == .pane and tree_item.pane == extra)
                break :blk line.item.key;
        }
        return error.TestUnexpectedResult;
    };

    wl.window.active = original;
    windowTreeKey(wme, &client, session_ptr, wl, target_key, null);
    while (cmdq_mod.cmdq_next(&client) != 0) {}

    try std.testing.expect(wl.window.active == extra);
    try std.testing.expect(window.window_pane_mode(extra) == null);
}

test "window-tree preview scroll commands page current window previews" {
    const env_mod = @import("environ.zig");
    const options_mod = @import("options.zig");
    const spawn = @import("spawn.zig");

    sess.session_init_globals(xm.allocator);
    window.window_init_globals(xm.allocator);

    options_mod.global_options = options_mod.options_create(null);
    defer options_mod.options_free(options_mod.global_options);
    options_mod.global_s_options = options_mod.options_create(null);
    defer options_mod.options_free(options_mod.global_s_options);
    options_mod.global_w_options = options_mod.options_create(null);
    defer options_mod.options_free(options_mod.global_w_options);
    options_mod.options_default_all(options_mod.global_options, T.OPTIONS_TABLE_SERVER);
    options_mod.options_default_all(options_mod.global_s_options, T.OPTIONS_TABLE_SESSION);
    options_mod.options_default_all(options_mod.global_w_options, T.OPTIONS_TABLE_WINDOW);

    env_mod.global_environ = env_mod.environ_create();
    defer env_mod.environ_free(env_mod.global_environ);

    const session_ptr = sess.session_create(null, "tree-preview-scroll", "/", env_mod.environ_create(), options_mod.options_create(options_mod.global_s_options), null);
    defer if (sess.session_find("tree-preview-scroll") != null) sess.session_destroy(session_ptr, false, "test");

    var cause: ?[]u8 = null;
    var spawn_ctx: T.SpawnContext = .{ .s = session_ptr, .idx = -1, .flags = T.SPAWN_EMPTY };
    const wl = spawn.spawn_window(&spawn_ctx, &cause).?;
    session_ptr.curw = wl;

    var sw = T.ScreenWriteCtx{ .s = &wl.window.active.?.base };
    screen_write.putn(&sw, "pane-0");

    var idx: usize = 1;
    while (idx < 4) : (idx += 1) {
        const pane = window.window_add_pane(wl.window, null, 24, 12);
        var pane_ctx = T.ScreenWriteCtx{ .s = &pane.base };
        switch (idx) {
            1 => screen_write.putn(&pane_ctx, "pane-1"),
            2 => screen_write.putn(&pane_ctx, "pane-2"),
            else => screen_write.putn(&pane_ctx, "pane-3"),
        }
    }
    wl.window.active = wl.window.panes.items[2];

    var target = T.CmdFindState{
        .s = session_ptr,
        .wl = wl,
        .w = wl.window,
        .wp = wl.window.active,
        .idx = wl.idx,
    };

    const wme = enterMode(wl.window.active.?, .{
        .fs = &target,
        .kind = .window,
    });
    defer {
        if (window.window_pane_mode(wl.window.active.?) != null)
            _ = window_mode_runtime.resetMode(wl.window.active.?);
    }

    const data = modeData(wme);
    const current_line = blk: {
        for (data.tree.line_list.items, 0..) |line, line_index| {
            const item: *TreeItem = @ptrCast(@alignCast(line.item.itemdata.?));
            if (item.item_type == .window and item.winlink == wl)
                break :blk @as(u32, @intCast(line_index));
        }
        return error.TestUnexpectedResult;
    };
    data.tree.current = current_line;
    mode_tree.resize(data.tree, 24, 24);
    redraw(wme);
    try std.testing.expectEqual(@as(u32, 2), data.preview_start);
    try std.testing.expectEqual(@as(u32, 3), data.preview_end);
    try std.testing.expect(data.preview_left != -1);
    try std.testing.expect(data.preview_right != -1);

    var args_cause: ?[]u8 = null;
    var left_args = try args_mod.args_parse(xm.allocator, &.{"scroll-left"}, "", 1, 1, &args_cause);
    defer left_args.deinit();
    windowTreeCommand(wme, null, session_ptr, wl, @ptrCast(&left_args), null);
    try std.testing.expectEqual(@as(u32, 1), data.preview_start);
    try std.testing.expectEqual(@as(u32, 2), data.preview_end);

    var right_args = try args_mod.args_parse(xm.allocator, &.{"scroll-right"}, "", 1, 1, &args_cause);
    defer right_args.deinit();
    windowTreeCommand(wme, null, session_ptr, wl, @ptrCast(&right_args), null);
    try std.testing.expectEqual(@as(u32, 2), data.preview_start);
    try std.testing.expectEqual(@as(u32, 3), data.preview_end);
}

test "window-tree kill prompts identify the selected pane and tagged count" {
    const env_mod = @import("environ.zig");
    const options_mod = @import("options.zig");
    const spawn = @import("spawn.zig");

    sess.session_init_globals(xm.allocator);
    window.window_init_globals(xm.allocator);

    options_mod.global_options = options_mod.options_create(null);
    defer options_mod.options_free(options_mod.global_options);
    options_mod.global_s_options = options_mod.options_create(null);
    defer options_mod.options_free(options_mod.global_s_options);
    options_mod.global_w_options = options_mod.options_create(null);
    defer options_mod.options_free(options_mod.global_w_options);
    options_mod.options_default_all(options_mod.global_options, T.OPTIONS_TABLE_SERVER);
    options_mod.options_default_all(options_mod.global_s_options, T.OPTIONS_TABLE_SESSION);
    options_mod.options_default_all(options_mod.global_w_options, T.OPTIONS_TABLE_WINDOW);

    env_mod.global_environ = env_mod.environ_create();
    defer env_mod.environ_free(env_mod.global_environ);

    const session_ptr = sess.session_create(null, "tree-kill-prompt", "/", env_mod.environ_create(), options_mod.options_create(options_mod.global_s_options), null);
    defer if (sess.session_find("tree-kill-prompt") != null) sess.session_destroy(session_ptr, false, "test");

    var cause: ?[]u8 = null;
    var spawn_ctx: T.SpawnContext = .{ .s = session_ptr, .idx = -1, .flags = T.SPAWN_EMPTY };
    const wl = spawn.spawn_window(&spawn_ctx, &cause).?;
    session_ptr.curw = wl;

    const extra = window.window_add_pane(wl.window, null, 80, 24);
    wl.window.active = extra;

    var env = T.Environ.init(xm.allocator);
    defer env.deinit();

    var client = T.Client{
        .name = "tree-kill-prompt-client",
        .environ = &env,
        .tty = undefined,
        .status = .{},
        .flags = T.CLIENT_ATTACHED,
        .session = session_ptr,
    };
    client.tty = .{ .client = &client };

    var target = T.CmdFindState{
        .s = session_ptr,
        .wl = wl,
        .w = wl.window,
        .wp = extra,
        .idx = wl.idx,
    };

    const wme = enterMode(extra, .{
        .fs = &target,
        .kind = .pane,
    });
    defer {
        status_prompt.status_prompt_clear(&client);
        if (window.window_pane_mode(extra) != null)
            _ = window_mode_runtime.resetMode(extra);
    }

    windowTreeKey(wme, &client, session_ptr, wl, 'x', null);
    try std.testing.expect(status_prompt.status_prompt_active(&client));
    try std.testing.expectEqualStrings("Kill pane 1? ", status_prompt.status_prompt_message(&client).?);

    status_prompt.status_prompt_clear(&client);
    mode_tree.toggleCurrentTag(modeData(wme).tree, false);

    windowTreeKey(wme, &client, session_ptr, wl, 'X', null);
    try std.testing.expect(status_prompt.status_prompt_active(&client));
    try std.testing.expectEqualStrings("Kill 1 tagged? ", status_prompt.status_prompt_message(&client).?);
}

test "window-tree preview arrows translate pane clicks into scroll actions" {
    const env_mod = @import("environ.zig");
    const options_mod = @import("options.zig");
    const spawn = @import("spawn.zig");

    sess.session_init_globals(xm.allocator);
    window.window_init_globals(xm.allocator);

    options_mod.global_options = options_mod.options_create(null);
    defer options_mod.options_free(options_mod.global_options);
    options_mod.global_s_options = options_mod.options_create(null);
    defer options_mod.options_free(options_mod.global_s_options);
    options_mod.global_w_options = options_mod.options_create(null);
    defer options_mod.options_free(options_mod.global_w_options);
    options_mod.options_default_all(options_mod.global_options, T.OPTIONS_TABLE_SERVER);
    options_mod.options_default_all(options_mod.global_s_options, T.OPTIONS_TABLE_SESSION);
    options_mod.options_default_all(options_mod.global_w_options, T.OPTIONS_TABLE_WINDOW);

    env_mod.global_environ = env_mod.environ_create();
    defer env_mod.environ_free(env_mod.global_environ);

    const session_ptr = sess.session_create(null, "tree-preview-mouse", "/", env_mod.environ_create(), options_mod.options_create(options_mod.global_s_options), null);
    defer if (sess.session_find("tree-preview-mouse") != null) sess.session_destroy(session_ptr, false, "test");

    var cause: ?[]u8 = null;
    var spawn_ctx: T.SpawnContext = .{ .s = session_ptr, .idx = -1, .flags = T.SPAWN_EMPTY };
    const wl = spawn.spawn_window(&spawn_ctx, &cause).?;
    session_ptr.curw = wl;

    var idx: usize = 0;
    while (idx < 3) : (idx += 1) {
        _ = window.window_add_pane(wl.window, null, 24, 12);
    }
    wl.window.active = wl.window.panes.items[2];

    var target = T.CmdFindState{
        .s = session_ptr,
        .wl = wl,
        .w = wl.window,
        .wp = wl.window.active,
        .idx = wl.idx,
    };

    const wme = enterMode(wl.window.active.?, .{
        .fs = &target,
        .kind = .window,
    });
    defer {
        if (window.window_pane_mode(wl.window.active.?) != null)
            _ = window_mode_runtime.resetMode(wl.window.active.?);
    }

    const data = modeData(wme);
    const current_line = blk: {
        for (data.tree.line_list.items, 0..) |line, line_index| {
            const item: *TreeItem = @ptrCast(@alignCast(line.item.itemdata.?));
            if (item.item_type == .window and item.winlink == wl)
                break :blk @as(u32, @intCast(line_index));
        }
        return error.TestUnexpectedResult;
    };
    data.tree.current = current_line;
    mode_tree.resize(data.tree, 24, 24);
    redraw(wme);
    try std.testing.expectEqual(@as(u32, 2), data.preview_start);

    const left_mouse = T.MouseEvent{
        .valid = true,
        .key = T.keycMouse(T.KEYC_MOUSEDOWN1, .pane),
        .x = 0,
        .y = data.preview_top,
    };
    windowTreeKey(wme, null, session_ptr, wl, T.keycMouse(T.KEYC_MOUSEDOWN1, .pane), &left_mouse);
    try std.testing.expectEqual(@as(u32, 1), data.preview_start);

    const right_mouse = T.MouseEvent{
        .valid = true,
        .key = T.keycMouse(T.KEYC_MOUSEDOWN1, .pane),
        .x = @intCast(data.preview_right + 1),
        .y = data.preview_top,
    };
    windowTreeKey(wme, null, session_ptr, wl, T.keycMouse(T.KEYC_MOUSEDOWN1, .pane), &right_mouse);
    try std.testing.expectEqual(@as(u32, 2), data.preview_start);
}

test "window-tree H jumps back to the original target" {
    const env_mod = @import("environ.zig");
    const options_mod = @import("options.zig");
    const spawn = @import("spawn.zig");

    sess.session_init_globals(xm.allocator);
    window.window_init_globals(xm.allocator);

    options_mod.global_options = options_mod.options_create(null);
    defer options_mod.options_free(options_mod.global_options);
    options_mod.global_s_options = options_mod.options_create(null);
    defer options_mod.options_free(options_mod.global_s_options);
    options_mod.global_w_options = options_mod.options_create(null);
    defer options_mod.options_free(options_mod.global_w_options);
    options_mod.options_default_all(options_mod.global_options, T.OPTIONS_TABLE_SERVER);
    options_mod.options_default_all(options_mod.global_s_options, T.OPTIONS_TABLE_SESSION);
    options_mod.options_default_all(options_mod.global_w_options, T.OPTIONS_TABLE_WINDOW);

    env_mod.global_environ = env_mod.environ_create();
    defer env_mod.environ_free(env_mod.global_environ);

    const session_ptr = sess.session_create(null, "tree-home-target", "/", env_mod.environ_create(), options_mod.options_create(options_mod.global_s_options), null);
    defer if (sess.session_find("tree-home-target") != null) sess.session_destroy(session_ptr, false, "test");

    var cause: ?[]u8 = null;
    var spawn_ctx: T.SpawnContext = .{ .s = session_ptr, .idx = -1, .flags = T.SPAWN_EMPTY };
    const wl = spawn.spawn_window(&spawn_ctx, &cause).?;
    session_ptr.curw = wl;
    _ = window.window_add_pane(wl.window, null, 24, 12);
    const target_pane = window.window_add_pane(wl.window, null, 24, 12);
    wl.window.active = target_pane;

    var target = T.CmdFindState{
        .s = session_ptr,
        .wl = wl,
        .w = wl.window,
        .wp = target_pane,
        .idx = wl.idx,
    };

    const wme = enterMode(target_pane, .{
        .fs = &target,
        .kind = .pane,
    });
    defer {
        if (window.window_pane_mode(target_pane) != null)
            _ = window_mode_runtime.resetMode(target_pane);
    }

    const data = modeData(wme);
    data.tree.current = 0;
    data.preview_offset = 3;
    windowTreeKey(wme, null, session_ptr, wl, 'H', null);

    const item = currentItem(data) orelse return error.TestUnexpectedResult;
    try std.testing.expect(item.item_type == .pane);
    try std.testing.expect(item.pane == target_pane);
    try std.testing.expectEqual(@as(i32, 0), data.preview_offset);
}

test "window-tree preview tile clicks select the clicked pane" {
    const env_mod = @import("environ.zig");
    const options_mod = @import("options.zig");
    const spawn = @import("spawn.zig");

    sess.session_init_globals(xm.allocator);
    window.window_init_globals(xm.allocator);

    options_mod.global_options = options_mod.options_create(null);
    defer options_mod.options_free(options_mod.global_options);
    options_mod.global_s_options = options_mod.options_create(null);
    defer options_mod.options_free(options_mod.global_s_options);
    options_mod.global_w_options = options_mod.options_create(null);
    defer options_mod.options_free(options_mod.global_w_options);
    options_mod.options_default_all(options_mod.global_options, T.OPTIONS_TABLE_SERVER);
    options_mod.options_default_all(options_mod.global_s_options, T.OPTIONS_TABLE_SESSION);
    options_mod.options_default_all(options_mod.global_w_options, T.OPTIONS_TABLE_WINDOW);

    env_mod.global_environ = env_mod.environ_create();
    defer env_mod.environ_free(env_mod.global_environ);

    const session_ptr = sess.session_create(null, "tree-preview-choose", "/", env_mod.environ_create(), options_mod.options_create(options_mod.global_s_options), null);
    defer if (sess.session_find("tree-preview-choose") != null) sess.session_destroy(session_ptr, false, "test");

    var cause: ?[]u8 = null;
    var spawn_ctx: T.SpawnContext = .{ .s = session_ptr, .idx = -1, .flags = T.SPAWN_EMPTY };
    const wl = spawn.spawn_window(&spawn_ctx, &cause).?;
    session_ptr.curw = wl;

    const first = wl.window.active.?;
    _ = window.window_add_pane(wl.window, null, 24, 12);
    _ = window.window_add_pane(wl.window, null, 24, 12);
    wl.window.active = first;

    var target = T.CmdFindState{
        .s = session_ptr,
        .wl = wl,
        .w = wl.window,
        .wp = first,
        .idx = wl.idx,
    };

    const wme = enterMode(first, .{
        .fs = &target,
        .kind = .pane,
    });
    defer {
        if (window.window_pane_mode(first) != null)
            _ = window_mode_runtime.resetMode(first);
    }

    const data = modeData(wme);
    const current_line = blk: {
        for (data.tree.line_list.items, 0..) |line, line_index| {
            const item: *TreeItem = @ptrCast(@alignCast(line.item.itemdata.?));
            if (item.item_type == .window and item.winlink == wl)
                break :blk @as(u32, @intCast(line_index));
        }
        return error.TestUnexpectedResult;
    };
    data.tree.current = current_line;
    mode_tree.resize(data.tree, 120, 24);
    redraw(wme);
    try std.testing.expectEqual(@as(i32, -1), data.preview_right);

    const click_layout = PreviewLayout{
        .start = data.preview_start,
        .end = data.preview_end,
        .each = data.preview_each,
        .remaining = 0,
        .left = data.preview_left != -1,
        .right = data.preview_right != -1,
    };
    const click_x = previewTileOffset(click_layout, 1) + 1;
    const click = T.MouseEvent{
        .valid = true,
        .key = T.keycMouse(T.KEYC_MOUSEDOWN1, .pane),
        .x = click_x,
        .y = data.preview_top,
    };
    const translated = windowTreeMouse(data, T.keycMouse(T.KEYC_MOUSEDOWN1, .pane), click.x, click.y, currentItem(data).?);
    try std.testing.expectEqual(@as(T.key_code, '\r'), translated);
    const selected = currentItem(data) orelse return error.TestUnexpectedResult;
    try std.testing.expect(selected.item_type == .pane);
    try std.testing.expect(selected.pane != first);
}

test "window-tree default choose command targets switch-client" {
    try std.testing.expect(std.mem.indexOf(u8, DEFAULT_COMMAND, "switch-client") != null);
    try std.testing.expect(std.mem.indexOf(u8, HELP_TEXT, "cancel") != null);
}
