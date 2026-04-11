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
// Ported in part from tmux/window-client.c.
// Original copyright:
//   Copyright (c) 2017 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

//! window-client.zig - reduced choose-client pane mode.

const std = @import("std");
const T = @import("types.zig");
const args_mod = @import("arguments.zig");
const client_registry = @import("client-registry.zig");
const cmd_mod = @import("cmd.zig");
const cmdq = @import("cmd-queue.zig");
const format_mod = @import("format.zig");
const key_string = @import("key-string.zig");
const menu_mod = @import("menu.zig");
const mode_tree = @import("mode-tree.zig");
const opts = @import("options.zig");
const resize_mod = @import("resize.zig");
const screen = @import("screen.zig");
const screen_write = @import("screen-write.zig");
const server = @import("server.zig");
const server_client = @import("server-client.zig");
const sort_mod = @import("sort.zig");
const status_mod = @import("status.zig");
const status_prompt = @import("status-prompt.zig");
const status_runtime = @import("status-runtime.zig");
const protocol = @import("zmux-protocol.zig");
const window = @import("window.zig");
const window_mode_runtime = @import("window-mode-runtime.zig");
const xm = @import("xmalloc.zig");

const DEFAULT_COMMAND = "detach-client -t '%%'";
const DEFAULT_FORMAT = "#{client_tty}: session #{client_session_name}";
const DEFAULT_KEY_FORMAT =
    "#{?#{e|<:#{line},10}," ++
    "#{line}" ++
    ",#{e|<:#{line},36}," ++
    "M-#{a:#{e|+:97,#{e|-:#{line},10}}}" ++
    "}";
const HELP_TEXT = "Enter choose  d/x/z detach kill suspend  t/T/^T tags  q cancel";

const window_client_menu_items = [_]menu_mod.MenuItemTemplate{
    .{ .name = "Detach", .key = 'd' },
    .{ .name = "Detach Tagged", .key = 'D' },
    .{ .name = "", .key = T.KEYC_NONE },
    .{ .name = "Tag", .key = 't' },
    .{ .name = "Tag All", .key = '\x14' },
    .{ .name = "Tag None", .key = 'T' },
    .{ .name = "", .key = T.KEYC_NONE },
    .{ .name = "Cancel", .key = 'q' },
    .{},
};

const ClientItem = struct {
    client: *T.Client,
    target_name: []u8,
    text: []u8,
};

const ClientModeData = struct {
    wp: *T.WindowPane,
    tree: *mode_tree.Data,
    format: []u8,
    key_format: []u8,
    command: []u8,
    items: std.ArrayList(*ClientItem) = .{},
};

const FilterPromptState = struct {
    pane_id: u32,
};

fn previewModeFromArgs(args: *const args_mod.Arguments) mode_tree.Preview {
    const count = if (args.entry('N')) |entry| entry.count else 0;
    return switch (count) {
        0 => if (args.has('y')) .normal else .off,
        1 => .normal,
        else => .big,
    };
}

pub const window_client_mode = T.WindowMode{
    .name = "client-mode",
    .update = clientModeUpdate,
    .resize = window_client_resize,
    .key = clientModeKey,
    .key_table = clientModeKeyTable,
    .command = clientModeCommand,
    .close = clientModeClose,
    .get_screen = clientModeGetScreen,
};

pub fn enterMode(wp: *T.WindowPane, args: *const args_mod.Arguments) *T.WindowModeEntry {
    if (window.window_pane_mode(wp)) |wme| {
        if (wme.mode == &window_client_mode) {
            refreshFromArgs(wme, args);
            rebuildAndDraw(wme);
            return wme;
        }
    }

    screen.screen_enter_alternate(wp, true);

    const data = xm.allocator.create(ClientModeData) catch unreachable;
    data.* = .{
        .wp = wp,
        .tree = undefined,
        .format = xm.xstrdup(args.get('F') orelse DEFAULT_FORMAT),
        .key_format = xm.xstrdup(args.get('K') orelse DEFAULT_KEY_FORMAT),
        .command = xm.xstrdup(args.value_at(0) orelse DEFAULT_COMMAND),
    };
    data.tree = mode_tree.start(wp, .{
        .modedata = @ptrCast(data),
        .preview = previewModeFromArgs(args),
        .zoom = args.has('Z'),
        .menu = &window_client_menu_items,
        .buildcb = buildTree,
        .searchcb = searchItem,
        .menucb = modeTreeMenuCallback,
        .keycb = modeTreeKeyCallback,
        .sortcb = modeTreeSortCallback,
        .helpcb = modeTreeHelpCallback,
    });
    data.tree.sort_crit.order = if (args.has('O')) sort_mod.sort_order_from_string(args.get('O')) else .name;
    data.tree.sort_crit.reversed = args.has('r');
    mode_tree.setFilter(data.tree, args.get('f'));

    const wme = window_mode_runtime.pushMode(wp, &window_client_mode, @ptrCast(data), null);
    rebuildAndDraw(wme);
    return wme;
}

fn clientModeKey(
    wme: *T.WindowModeEntry,
    client: ?*T.Client,
    session: *T.Session,
    wl: *T.Winlink,
    key: T.key_code,
    mouse: ?*const T.MouseEvent,
) void {
    const data = modeData(wme);
    _ = session;
    _ = wl;

    var translated = key;
    const finished = mode_tree.handleKey(data.tree, client, &translated, mouse, null, null);
    switch (translated) {
        'd', 'x', 'z' => {
            if (currentItem(data)) |item|
                window_client_do_detach(data, item, translated);
            rebuildAfterAction(wme);
            return;
        },
        'D', 'X', 'Z' => {
            mode_tree.eachTagged(data.tree, detachTaggedCallback, client, translated, false);
            rebuildAfterAction(wme);
            return;
        },
        '\r' => {
            chooseCurrent(wme, client);
            return;
        },
        else => {},
    }

    if (finished or countSelectableClients() == 0) {
        _ = window_mode_runtime.resetMode(wme.wp);
        return;
    }
    redraw(wme);
}

fn clientModeKeyTable(wme: *T.WindowModeEntry) []const u8 {
    if (opts.options_get_number(wme.wp.window.options, "mode-keys") == T.MODEKEY_VI)
        return "client-mode-vi";
    return "client-mode";
}

fn clientModeCommand(
    wme: *T.WindowModeEntry,
    client: ?*T.Client,
    session: *T.Session,
    wl: *T.Winlink,
    raw_args: *const anyopaque,
    _mouse: ?*const T.MouseEvent,
) void {
    _ = _mouse;

    const args: *const args_mod.Arguments = @ptrCast(@alignCast(raw_args));
    if (args.count() == 0) return;

    const command = args.value_at(0).?;
    const data = modeData(wme);
    const repeat = repeatCount(wme);
    defer wme.prefix = 1;

    if (std.mem.eql(u8, command, "cancel")) {
        _ = window_mode_runtime.resetMode(wme.wp);
        return;
    }
    if (std.mem.eql(u8, command, "choose")) {
        _ = session;
        _ = wl;
        chooseCurrent(wme, client);
        return;
    }
    if (std.mem.eql(u8, command, "cursor-up")) {
        var remaining = repeat;
        while (remaining > 0) : (remaining -= 1) mode_tree.up(data.tree, false);
        redraw(wme);
        return;
    }
    if (std.mem.eql(u8, command, "cursor-down")) {
        var remaining = repeat;
        while (remaining > 0) : (remaining -= 1) _ = mode_tree.down(data.tree, false);
        redraw(wme);
        return;
    }
    if (std.mem.eql(u8, command, "page-up")) {
        pageUp(data.tree, listRows(data.tree, wme.wp), repeat);
        redraw(wme);
        return;
    }
    if (std.mem.eql(u8, command, "page-down")) {
        pageDown(data.tree, listRows(data.tree, wme.wp), repeat);
        redraw(wme);
        return;
    }
    if (std.mem.eql(u8, command, "tag")) {
        mode_tree.toggleCurrentTag(data.tree, false);
        redraw(wme);
        return;
    }
    if (std.mem.eql(u8, command, "tag-all")) {
        mode_tree.tagAll(data.tree);
        redraw(wme);
        return;
    }
    if (std.mem.eql(u8, command, "tag-none")) {
        mode_tree.clearAllTagged(data.tree);
        redraw(wme);
        return;
    }
    if (std.mem.eql(u8, command, "filter")) {
        startFilterPrompt(wme, client);
        return;
    }
    if (std.mem.eql(u8, command, "detach")) {
        actOnCurrent(data, protocol.MsgType, detachClient, .detach);
        rebuildAfterAction(wme);
        return;
    }
    if (std.mem.eql(u8, command, "detach-tagged")) {
        actOnTagged(data, protocol.MsgType, detachClient, .detach, false);
        rebuildAfterAction(wme);
        return;
    }
    if (std.mem.eql(u8, command, "kill")) {
        actOnCurrent(data, protocol.MsgType, detachClient, .detachkill);
        rebuildAfterAction(wme);
        return;
    }
    if (std.mem.eql(u8, command, "kill-tagged")) {
        actOnTagged(data, protocol.MsgType, detachClient, .detachkill, false);
        rebuildAfterAction(wme);
        return;
    }
    if (std.mem.eql(u8, command, "suspend")) {
        actOnCurrent(data, void, suspendClient, {});
        rebuildAfterAction(wme);
        return;
    }
    if (std.mem.eql(u8, command, "suspend-tagged")) {
        actOnTagged(data, void, suspendClient, {}, false);
        rebuildAfterAction(wme);
        return;
    }

    unsupportedCommand(client, command);
    redraw(wme);
}

fn clientModeClose(wme: *T.WindowModeEntry) void {
    const data = modeData(wme);
    mode_tree.free(data.tree);
    freeItems(data);
    data.items.deinit(xm.allocator);
    xm.allocator.free(data.format);
    xm.allocator.free(data.key_format);
    xm.allocator.free(data.command);
    xm.allocator.destroy(data);

    if (wme.wp.modes.items.len <= 1) {
        screen.screen_leave_alternate(wme.wp, true);
    }
}

fn clientModeGetScreen(wme: *T.WindowModeEntry) *T.Screen {
    return modeData(wme).tree.getScreen();
}

fn clientModeUpdate(wme: *T.WindowModeEntry) void {
    rebuildAndDraw(wme);
}

fn modeData(wme: *T.WindowModeEntry) *ClientModeData {
    return @ptrCast(@alignCast(wme.data.?));
}

fn refreshFromArgs(wme: *T.WindowModeEntry, args: *const args_mod.Arguments) void {
    const data = modeData(wme);
    xm.allocator.free(data.format);
    data.format = xm.xstrdup(args.get('F') orelse DEFAULT_FORMAT);

    xm.allocator.free(data.key_format);
    data.key_format = xm.xstrdup(args.get('K') orelse DEFAULT_KEY_FORMAT);

    xm.allocator.free(data.command);
    data.command = xm.xstrdup(args.value_at(0) orelse DEFAULT_COMMAND);

    data.tree.sort_crit.order = if (args.has('O')) sort_mod.sort_order_from_string(args.get('O')) else .name;
    data.tree.sort_crit.reversed = args.has('r');
    data.tree.preview = previewModeFromArgs(args);
    mode_tree.setFilter(data.tree, args.get('f'));
    if (args.has('Z'))
        mode_tree.zoom(data.tree, true);
}

fn rebuildAndDraw(wme: *T.WindowModeEntry) void {
    mode_tree.build(modeData(wme).tree);
    redraw(wme);
}

fn rebuildAfterAction(wme: *T.WindowModeEntry) void {
    mode_tree.build(modeData(wme).tree);
    if (countSelectableClients() == 0) {
        _ = window_mode_runtime.resetMode(wme.wp);
        return;
    }
    redraw(wme);
}

fn redraw(wme: *T.WindowModeEntry) void {
    const data = modeData(wme);
    const tree = data.tree;
    const view = tree.getScreen();

    screen.screen_reset_active(view);
    view.mode &= ~@as(i32, T.MODE_CURSOR | T.MODE_WRAP);
    view.cursor_visible = false;

    var ctx = T.ScreenWriteCtx{ .s = view };
    const width = view.grid.sx;
    const rows = view.grid.sy;
    const item_rows = listRows(tree, wme.wp);
    const preview_rows = previewRows(tree, wme.wp);

    var row: u32 = 0;
    while (row < item_rows) : (row += 1) {
        screen_write.cursor_to(&ctx, row, 0);
        screen_write.erase_line(&ctx);

        const index = tree.offset + row;
        if (index >= tree.line_list.items.len) continue;

        const line = renderLine(tree, index);
        defer xm.allocator.free(line);
        screen_write.putn(&ctx, line);
    }

    drawPreview(data, &ctx, item_rows, preview_rows);

    if (rows > 0) {
        screen_write.cursor_to(&ctx, rows - 1, 0);
        screen_write.erase_line(&ctx);
        if (width != 0) screen_write.putn(&ctx, HELP_TEXT);
    }

    if (tree.no_matches and item_rows != 0) {
        screen_write.cursor_to(&ctx, 0, 0);
        screen_write.erase_line(&ctx);
        screen_write.putn(&ctx, "No matching clients.");
    } else if (tree.line_list.items.len == 0 and item_rows != 0) {
        screen_write.cursor_to(&ctx, 0, 0);
        screen_write.erase_line(&ctx);
        screen_write.putn(&ctx, "No clients.");
    }

    window_mode_runtime.noteModeRedraw(wme.wp);
}

fn renderLine(tree: *const mode_tree.Data, index: usize) []u8 {
    const line = tree.line_list.items[index];
    const item: *ClientItem = @ptrCast(@alignCast(line.item.itemdata.?));
    const current = if (index == tree.current) ">" else " ";
    const tagged = if (line.item.tagged) "*" else " ";

    var out: std.ArrayList(u8) = .{};
    defer out.deinit(xm.allocator);

    out.appendSlice(xm.allocator, current) catch unreachable;
    out.appendSlice(xm.allocator, tagged) catch unreachable;
    out.append(xm.allocator, ' ') catch unreachable;

    const max_key_width = maxKeyLabelWidth(tree);
    if (max_key_width != 0) {
        const key_width = max_key_width + 2;
        if (line.item.keystr) |keystr| {
            out.append(xm.allocator, '[') catch unreachable;
            out.appendSlice(xm.allocator, keystr) catch unreachable;
            out.append(xm.allocator, ']') catch unreachable;

            const pad = key_width - (keystr.len + 2);
            var i: usize = 0;
            while (i < pad) : (i += 1) out.append(xm.allocator, ' ') catch unreachable;
        } else {
            var i: usize = 0;
            while (i < key_width) : (i += 1) out.append(xm.allocator, ' ') catch unreachable;
        }
        out.append(xm.allocator, ' ') catch unreachable;
    }

    out.appendSlice(xm.allocator, item.text) catch unreachable;
    return out.toOwnedSlice(xm.allocator) catch unreachable;
}

fn viewRows(wp: *const T.WindowPane) u32 {
    return if (wp.screen.grid.sy > 0) wp.screen.grid.sy - 1 else 0;
}

fn previewRows(tree: *const mode_tree.Data, wp: *const T.WindowPane) u32 {
    const rows = viewRows(wp);
    if (rows < 3) return 0;
    return switch (tree.preview) {
        .off => 0,
        .normal => @max(@as(u32, 1), rows / 2),
        .big => @max(@as(u32, 2), (rows * 3) / 4),
    };
}

fn listRows(tree: *const mode_tree.Data, wp: *const T.WindowPane) u32 {
    const rows = viewRows(wp);
    const preview = previewRows(tree, wp);
    return rows -| preview;
}

fn drawPreview(data: *const ClientModeData, ctx: *T.ScreenWriteCtx, top: u32, height: u32) void {
    if (height == 0) return;
    const item = currentItem(data) orelse return;
    const cl = item.client;
    const session = cl.session orelse return;
    const wl = session.curw orelse return;
    const pane = wl.window.active orelse return;

    var lines = resize_mod.status_line_size(cl);
    if (lines >= height) lines = 0;
    const at: u32 = if (status_mod.status_at_line(cl) == 0) lines else 0;

    const preview_height = height -| 2 -| lines;
    if (preview_height != 0) {
        screen_write.cursor_to(ctx, top + at, 0);
        screen_write.preview(ctx, &pane.base, ctx.s.grid.sx, preview_height);
    }

    const separator_row = if (at != 0) top + 2 else top + height -| 1 -| lines;
    if (separator_row < ctx.s.grid.sy) {
        screen_write.cursor_to(ctx, separator_row, 0);
        screen_write.hline(ctx, ctx.s.grid.sx, false, false);
    }

    if (lines != 0) {
        const status_screen = cl.status.screen orelse return;
        const status_top = if (at != 0) top else top + height -| lines;
        screen_write.cursor_to(ctx, status_top, 0);
        screen_write.fast_copy(ctx, status_screen, 0, 0, ctx.s.grid.sx, lines);
    }
}

fn chooseCurrent(wme: *T.WindowModeEntry, client: ?*T.Client) void {
    const data = modeData(wme);
    const item = currentItem(data) orelse return;
    mode_tree.runCommand(client, null, data.command, item.target_name);
    _ = window_mode_runtime.resetMode(wme.wp);
}

fn searchItem(_: *mode_tree.Data, itemdata: ?*anyopaque, search: []const u8, ignore_case: bool) bool {
    const item: *ClientItem = @ptrCast(@alignCast(itemdata orelse return false));
    if (contains(item.text, search, ignore_case)) return true;
    if (item.client.name) |name|
        if (contains(name, search, ignore_case)) return true;
    if (item.client.ttyname) |ttyname|
        if (contains(ttyname, search, ignore_case)) return true;
    return false;
}

fn contains(haystack: []const u8, needle: []const u8, ignore_case: bool) bool {
    if (!ignore_case) return std.mem.indexOf(u8, haystack, needle) != null;
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

fn startFilterPrompt(wme: *T.WindowModeEntry, client: ?*T.Client) void {
    const cl = client orelse return;
    if ((cl.flags & T.CLIENT_ATTACHED) == 0) return;

    const state = xm.allocator.create(FilterPromptState) catch unreachable;
    state.* = .{ .pane_id = wme.wp.id };
    const data = modeData(wme);
    status_prompt.status_prompt_set(
        cl,
        null,
        "(filter) ",
        data.tree.filter,
        filterPromptCallback,
        null,
        freeFilterPromptState,
        state,
        status_prompt.PROMPT_NOFORMAT,
        .search,
    );
}

fn freeFilterPromptState(raw: ?*anyopaque) void {
    const state: *FilterPromptState = @ptrCast(@alignCast(raw orelse return));
    xm.allocator.destroy(state);
}

fn filterPromptCallback(_: *T.Client, raw: ?*anyopaque, input: ?[]const u8, _: bool) i32 {
    const state: *FilterPromptState = @ptrCast(@alignCast(raw orelse return 0));
    const pane = window.window_pane_find_by_id(state.pane_id) orelse return 0;
    const wme = window.window_pane_mode(pane) orelse return 0;
    if (wme.mode != &window_client_mode) return 0;
    const data = modeData(wme);
    mode_tree.setFilter(data.tree, input);
    mode_tree.build(data.tree);
    redraw(wme);
    return 0;
}

fn maxKeyLabelWidth(tree: *const mode_tree.Data) usize {
    var width: usize = 0;
    for (tree.line_list.items) |line| {
        if (line.item.keystr) |keystr|
            width = @max(width, keystr.len);
    }
    return width;
}

fn currentItem(data: *const ClientModeData) ?*ClientItem {
    return @ptrCast(@alignCast(mode_tree.getCurrent(@constCast(data.tree)) orelse return null));
}

fn repeatCount(wme: *T.WindowModeEntry) u32 {
    return if (wme.prefix == 0) 1 else wme.prefix;
}

fn detachClient(item: *ClientItem, msg: protocol.MsgType) void {
    server_client.server_client_detach(item.client, msg);
}

fn suspendClient(item: *ClientItem, _: void) void {
    server_client.server_client_suspend(item.client);
}

fn actOnCurrent(
    data: *ClientModeData,
    comptime Arg: type,
    comptime func: *const fn (*ClientItem, Arg) void,
    arg: Arg,
) void {
    if (currentItem(data)) |item| func(item, arg);
}

fn actOnTagged(
    data: *ClientModeData,
    comptime Arg: type,
    comptime func: *const fn (*ClientItem, Arg) void,
    arg: Arg,
    current_fallback: bool,
) void {
    var fired = false;
    for (data.tree.line_list.items) |line| {
        if (!line.item.tagged) continue;
        fired = true;
        const item: *ClientItem = @ptrCast(@alignCast(line.item.itemdata.?));
        func(item, arg);
    }
    if (!fired and current_fallback) actOnCurrent(data, Arg, func, arg);
}

fn runCommand(client: ?*T.Client, session: *T.Session, wl: *T.Winlink, template: []const u8, target_name: []const u8) void {
    const cl = client orelse return;
    const expanded = templateReplace(template, target_name, 1);
    defer xm.allocator.free(expanded);
    if (expanded.len == 0) return;

    var input = T.CmdParseInput{
        .c = cl,
        .fs = .{
            .s = session,
            .wl = wl,
            .w = wl.window,
            .wp = wl.window.active,
            .idx = wl.idx,
        },
    };
    const parsed = cmd_mod.cmd_parse_from_string(expanded, &input);
    switch (parsed.status) {
        .success => {
            const cmdlist: *cmd_mod.CmdList = @ptrCast(@alignCast(parsed.cmdlist.?));
            cmdq.cmdq_append(cl, cmdlist);
        },
        .@"error" => {
            const err = parsed.@"error" orelse xm.xstrdup("parse error");
            defer xm.allocator.free(err);
            status_runtime.present_client_message(cl, err);
        },
    }
}

fn templateReplace(template: []const u8, replacement: []const u8, idx: usize) []u8 {
    if (std.mem.indexOfScalar(u8, template, '%') == null) return xm.xstrdup(template);

    var out: std.ArrayList(u8) = .{};
    defer out.deinit(xm.allocator);

    var i: usize = 0;
    var replaced = false;
    while (i < template.len) {
        if (template[i] != '%') {
            out.append(xm.allocator, template[i]) catch unreachable;
            i += 1;
            continue;
        }
        if (i + 1 >= template.len) {
            out.append(xm.allocator, '%') catch unreachable;
            i += 1;
            continue;
        }

        const next = template[i + 1];
        const matches_idx = next >= '1' and next <= '9' and (next - '0') == idx;
        const matches_escaped = next == '%' and !replaced;
        if (!matches_idx and !matches_escaped) {
            out.append(xm.allocator, '%') catch unreachable;
            i += 1;
            continue;
        }

        i += 2;
        var quoted = false;
        if (i < template.len and template[i] == '%') {
            quoted = true;
            i += 1;
        }
        if (matches_escaped) replaced = true;

        for (replacement) |ch| {
            if (quoted and std.mem.indexOfScalar(u8, "\"\\$;~", ch) != null)
                out.append(xm.allocator, '\\') catch unreachable;
            out.append(xm.allocator, ch) catch unreachable;
        }
    }

    return out.toOwnedSlice(xm.allocator) catch unreachable;
}

fn freeItems(data: *ClientModeData) void {
    for (data.items.items) |item| {
        window_client_free_item(item);
        xm.allocator.destroy(item);
    }
    data.items.clearRetainingCapacity();
}

fn isSelectable(cl: *T.Client) bool {
    return cl.session != null and
        (cl.flags & (T.CLIENT_ATTACHED | T.CLIENT_SUSPENDED | T.CLIENT_EXIT)) == T.CLIENT_ATTACHED;
}

fn countSelectableClients() usize {
    var count: usize = 0;
    for (client_registry.clients.items) |cl| {
        if (isSelectable(cl)) count += 1;
    }
    return count;
}

pub fn hasSelectableClients() bool {
    return countSelectableClients() != 0;
}

fn clientTargetName(cl: *const T.Client) []u8 {
    if (cl.ttyname) |ttyname| {
        if (ttyname.len != 0) return xm.xstrdup(ttyname);
    }
    if (cl.name) |name| {
        if (name.len != 0) return xm.xstrdup(name);
    }
    return xm.xstrdup("unknown");
}

fn fallbackText(cl: *const T.Client) []u8 {
    const target_name = if (cl.ttyname) |ttyname| ttyname else cl.name orelse "unknown";
    const session_name = if (cl.session) |s| s.name else "none";
    return xm.xasprintf("{s}: session {s}", .{ target_name, session_name });
}

fn clientFormatContext(cl: *T.Client) format_mod.FormatContext {
    const s = cl.session;
    const wl = if (s) |session| session.curw else null;
    const w = if (wl) |winlink| winlink.window else null;
    const pane = if (w) |win_ptr| win_ptr.active else null;
    return .{
        .client = cl,
        .session = s,
        .winlink = wl,
        .window = w,
        .pane = pane,
    };
}

fn keyForLine(data: *const ClientModeData, cl: *T.Client, line: u32) T.key_code {
    var ctx = clientFormatContext(cl);
    ctx.line = line;

    const expanded = format_mod.format_require_complete(xm.allocator, data.key_format, &ctx) orelse return T.KEYC_NONE;
    defer xm.allocator.free(expanded);

    const key = key_string.key_string_lookup_string(expanded);
    if (key == T.KEYC_UNKNOWN or key == T.KEYC_NONE) return T.KEYC_NONE;
    return key;
}

fn unsupportedCommand(client: ?*T.Client, command: []const u8) void {
    const text = xm.xasprintf("Client-mode command not supported yet: {s}", .{command});
    const cl = client orelse {
        xm.allocator.free(text);
        return;
    };
    status_runtime.status_message_set_owned(cl, -1, true, false, false, text);
}

// ── tmux-compatible public API (window-client) ─────────────────────────

const window_client_order_seq = [_]T.SortOrder{ .name, .size, .creation, .activity, .end };

const window_client_help_lines = [_][]const u8{
    "\r\x1b[1m      Enter \x1b[0m\x0ex\x0f \x1b[0mChoose selected %1\n",
    "\r\x1b[1m          d \x1b[0m\x0ex\x0f \x1b[0mDetach selected %1\n",
    "\r\x1b[1m          D \x1b[0m\x0ex\x0f \x1b[0mDetach tagged %1s\n",
    "\r\x1b[1m          x \x1b[0m\x0ex\x0f \x1b[0mDetach selected %1\n",
    "\r\x1b[1m          X \x1b[0m\x0ex\x0f \x1b[0mDetach tagged %1s\n",
    "\r\x1b[1m          z \x1b[0m\x0ex\x0f \x1b[0mSuspend selected %1\n",
    "\r\x1b[1m          Z \x1b[0m\x0ex\x0f \x1b[0mSuspend tagged %1s\n",
    "\r\x1b[1m          f \x1b[0m\x0ex\x0f \x1b[0mEnter a filter\n",
};

pub fn window_client_init(
    wp: *T.WindowPane,
    args: *const args_mod.Arguments,
) *T.Screen {
    const wme = enterMode(wp, args);
    return clientModeGetScreen(wme);
}

pub fn window_client_free(wme: *T.WindowModeEntry) void {
    clientModeClose(wme);
}

pub fn window_client_resize(wme: *T.WindowModeEntry, sx: u32, sy: u32) void {
    mode_tree.resize(modeData(wme).tree, sx, sy);
}

pub fn window_client_update(wme: *T.WindowModeEntry) void {
    rebuildAndDraw(wme);
}

pub fn window_client_key(
    wme: *T.WindowModeEntry,
    client: ?*T.Client,
    session: *T.Session,
    wl: *T.Winlink,
    key: T.key_code,
    mouse: ?*const T.MouseEvent,
) void {
    clientModeKey(wme, client, session, wl, key, mouse);
}

pub fn window_client_add_item(data: *ClientModeData, cl: *T.Client) void {
    const item = xm.allocator.create(ClientItem) catch unreachable;
    const text = format_mod.format_require_complete(
        xm.allocator,
        data.format,
        &clientFormatContext(cl),
    ) orelse fallbackText(cl);
    const target_name = clientTargetName(cl);
    item.* = .{
        .client = cl,
        .target_name = target_name,
        .text = text,
    };
    data.items.append(xm.allocator, item) catch unreachable;
}

pub fn window_client_free_item(item: *ClientItem) void {
    xm.allocator.free(item.target_name);
    xm.allocator.free(item.text);
}

pub fn window_client_build(wme: *T.WindowModeEntry) void {
    buildTree(modeData(wme).tree);
}

pub fn window_client_draw(wme: *T.WindowModeEntry) void {
    redraw(wme);
}

pub fn window_client_do_detach(
    data: *ClientModeData,
    item: *ClientItem,
    key: T.key_code,
) void {
    if (item == currentItem(data))
        _ = mode_tree.down(data.tree, false);
    if (key == 'd' or key == 'D')
        server_client.server_client_detach(item.client, .detach)
    else if (key == 'x' or key == 'X')
        server_client.server_client_detach(item.client, .detachkill)
    else if (key == 'z' or key == 'Z')
        server_client.server_client_suspend(item.client);
}

fn detachTaggedCallback(tree: *mode_tree.Data, itemdata: ?*anyopaque, _: ?*T.Client, key: T.key_code) void {
    const data: *ClientModeData = @ptrCast(@alignCast(tree.modedata.?));
    const item: *ClientItem = @ptrCast(@alignCast(itemdata orelse return));
    window_client_do_detach(data, item, key);
}

pub fn window_client_menu(
    wme: *T.WindowModeEntry,
    client: ?*T.Client,
    session: *T.Session,
    wl: *T.Winlink,
    key: T.key_code,
) void {
    if (wme.mode != &window_client_mode) return;
    clientModeKey(wme, client, session, wl, key, null);
}

fn modeTreeMenuCallback(tree: *mode_tree.Data, client: ?*T.Client, key: T.key_code) void {
    const wme = window.window_pane_mode(tree.wp) orelse return;
    if (wme.mode != &window_client_mode) return;
    const data: *ClientModeData = @ptrCast(@alignCast(tree.modedata.?));
    const item = currentItem(data) orelse return;
    const session = item.client.session orelse return;
    const wl = session.curw orelse return;
    window_client_menu(wme, client, session, wl, key);
}

pub fn window_client_get_key(
    data: *const ClientModeData,
    cl: *T.Client,
    line: u32,
) T.key_code {
    return keyForLine(data, cl, line);
}

pub fn window_client_sort(sort_crit: *T.SortCriteria) void {
    sort_crit.order_seq = sort_mod.window_client_sort_order_seq;
    if (sort_crit.order == .end)
        sort_crit.order = sort_mod.window_client_sort_order_seq[0];
}

pub fn window_client_help(width: *u32, item_name: *[]const u8) []const []const u8 {
    width.* = 0;
    item_name.* = "client";
    return &window_client_help_lines;
}

fn modeTreeKeyCallback(tree: *mode_tree.Data, itemdata: ?*anyopaque, line: u32) T.key_code {
    const data: *ClientModeData = @ptrCast(@alignCast(tree.modedata.?));
    const item: *ClientItem = @ptrCast(@alignCast(itemdata orelse return T.KEYC_NONE));
    return window_client_get_key(data, item.client, line);
}

fn modeTreeSortCallback(sort_crit: *T.SortCriteria) void {
    window_client_sort(sort_crit);
}

fn modeTreeHelpCallback(width: *u32, item_name: *[]const u8) ?[*]const ?[*:0]const u8 {
    const lines = window_client_help(width, item_name);
    return @ptrCast(lines.ptr);
}

fn buildTree(tree: *mode_tree.Data) void {
    const data: *ClientModeData = @ptrCast(@alignCast(tree.modedata.?));
    freeItems(data);

    const clients = sort_mod.sorted_clients(tree.sort_crit);
    defer xm.allocator.free(clients);

    for (clients) |cl| {
        if (!isSelectable(cl)) continue;

        const ctx = clientFormatContext(cl);
        if (tree.filter) |filter| {
            const matches = format_mod.format_filter_match(xm.allocator, filter, &ctx) orelse false;
            if (!matches) continue;
        }

        window_client_add_item(data, cl);
        const item = data.items.items[data.items.items.len - 1];
        _ = mode_tree.add(
            tree,
            null,
            @ptrCast(item),
            @intFromPtr(cl),
            cl.name orelse "client",
            item.text,
            0,
        );
    }
}

fn initTestGlobals() void {
    const cmdq_mod = @import("cmd-queue.zig");
    const env_mod = @import("environ.zig");
    const opts_mod = @import("options.zig");
    const sess = @import("session.zig");

    cmdq_mod.cmdq_reset_for_tests();
    sess.session_init_globals(xm.allocator);
    window.window_init_globals(xm.allocator);

    opts_mod.global_options = opts_mod.options_create(null);
    opts_mod.global_s_options = opts_mod.options_create(null);
    opts_mod.global_w_options = opts_mod.options_create(null);
    opts_mod.options_default_all(opts_mod.global_options, T.OPTIONS_TABLE_SERVER);
    opts_mod.options_default_all(opts_mod.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts_mod.options_default_all(opts_mod.global_w_options, T.OPTIONS_TABLE_WINDOW);

    env_mod.global_environ = env_mod.environ_create();
}

fn deinitTestGlobals() void {
    const cmdq_mod = @import("cmd-queue.zig");
    const env_mod = @import("environ.zig");
    const opts_mod = @import("options.zig");

    client_registry.clients.clearRetainingCapacity();
    cmdq_mod.cmdq_reset_for_tests();
    env_mod.environ_free(env_mod.global_environ);
    opts_mod.options_free(opts_mod.global_w_options);
    opts_mod.options_free(opts_mod.global_s_options);
    opts_mod.options_free(opts_mod.global_options);
}

const TestSetup = struct {
    session: *T.Session,
    pane: *T.WindowPane,
};

fn setGridLineText(gd: *T.Grid, row: u32, text: []const u8) void {
    var col: u32 = 0;
    while (col < text.len and col < gd.sx) : (col += 1) {
        var cell = T.grid_default_cell;
        cell.data = T.grid_default_cell.data;
        cell.data.data[0] = text[col];
        @import("grid.zig").set_cell(gd, row, col, &cell);
    }
}

fn testSetup(session_name: []const u8) !TestSetup {
    const env_mod = @import("environ.zig");
    const opts_mod = @import("options.zig");
    const sess = @import("session.zig");
    const spawn = @import("spawn.zig");

    const s = sess.session_create(null, session_name, "/", env_mod.environ_create(), opts_mod.options_create(opts_mod.global_s_options), null);
    var cause: ?[]u8 = null;
    var ctx: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const wl = spawn.spawn_window(&ctx, &cause).?;
    return .{
        .session = s,
        .pane = wl.window.active.?,
    };
}

fn makeClient(session: *T.Session, name: []const u8, ttyname: []const u8) T.Client {
    const env_mod = @import("environ.zig");
    var client = T.Client{
        .name = xm.xstrdup(name),
        .ttyname = xm.xstrdup(ttyname),
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{},
        .flags = T.CLIENT_ATTACHED,
        .session = session,
    };
    client.tty = .{ .client = &client };
    return client;
}

fn freeClient(client: *T.Client) void {
    const env_mod = @import("environ.zig");
    env_mod.environ_free(client.environ);
    if (client.status.screen) |screen_ptr| {
        screen.screen_free(screen_ptr);
        xm.allocator.destroy(screen_ptr);
    }
    if (client.name) |name| xm.allocator.free(@constCast(name));
    if (client.ttyname) |ttyname| xm.allocator.free(ttyname);
    if (client.message_string) |message| xm.allocator.free(message);
    if (client.exit_session) |exit_session| xm.allocator.free(exit_session);
}

test "window-client mode renders attached clients and preserves selection by client" {
    const sess = @import("session.zig");

    initTestGlobals();
    defer deinitTestGlobals();

    const setup = try testSetup("window-client-render");
    defer if (sess.session_find("window-client-render") != null) sess.session_destroy(setup.session, false, "test");

    var first = makeClient(setup.session, "first", "/dev/pts/201");
    defer freeClient(&first);
    var second = makeClient(setup.session, "second", "/dev/pts/202");
    defer freeClient(&second);
    client_registry.add(&second);
    client_registry.add(&first);

    var cause: ?[]u8 = null;
    var args = try args_mod.args_parse(xm.allocator, &.{ "-K", "#{line}" }, "F:f:K:NO:rt:yZ", 0, 1, &cause);
    defer args.deinit();

    const wme = enterMode(setup.pane, &args);
    defer {
        if (window.window_pane_mode(setup.pane)) |_| _ = window_mode_runtime.resetMode(setup.pane);
    }

    const data = modeData(wme);
    try std.testing.expectEqual(@as(usize, 2), data.items.items.len);
    try std.testing.expectEqualStrings("/dev/pts/201: session window-client-render", data.items.items[0].text);
    const first_line = renderLine(data.tree, 0);
    defer xm.allocator.free(first_line);
    try std.testing.expect(std.mem.indexOf(u8, first_line, "[0]") != null);

    data.tree.current = 1;
    mode_tree.build(data.tree);
    try std.testing.expectEqualStrings("/dev/pts/202", currentItem(data).?.target_name);
}

test "window-client choose runs the tmux template command for the selected client" {
    const cmdq_mod = @import("cmd-queue.zig");
    const sess = @import("session.zig");

    initTestGlobals();
    defer deinitTestGlobals();

    const setup = try testSetup("window-client-choose");
    defer if (sess.session_find("window-client-choose") != null) sess.session_destroy(setup.session, false, "test");

    var chooser = makeClient(setup.session, "chooser", "/dev/pts/300");
    defer freeClient(&chooser);
    var target = makeClient(setup.session, "target", "/dev/pts/301");
    defer freeClient(&target);
    client_registry.add(&target);

    var cause: ?[]u8 = null;
    var mode_args = try args_mod.args_parse(xm.allocator, &.{}, "F:f:K:NO:rt:yZ", 0, 1, &cause);
    defer mode_args.deinit();
    const wme = enterMode(setup.pane, &mode_args);

    cause = null;
    var command_args = try args_mod.args_parse(xm.allocator, &.{"choose"}, "", 0, -1, &cause);
    defer command_args.deinit();
    clientModeCommand(wme, &chooser, setup.session, setup.session.curw.?, @ptrCast(&command_args), null);
    while (cmdq_mod.cmdq_next(&chooser) != 0) {}

    try std.testing.expect(target.session == null);
    try std.testing.expect((target.flags & T.CLIENT_ATTACHED) == 0);
    try std.testing.expect(window.window_pane_mode(setup.pane) == null);
}

test "window-client custom key format chooses the matching client" {
    const cmdq_mod = @import("cmd-queue.zig");
    const sess = @import("session.zig");

    initTestGlobals();
    defer deinitTestGlobals();

    const setup = try testSetup("window-client-key-format");
    defer if (sess.session_find("window-client-key-format") != null) sess.session_destroy(setup.session, false, "test");

    var chooser = makeClient(setup.session, "chooser", "/dev/pts/320");
    defer freeClient(&chooser);
    var first = makeClient(setup.session, "first", "/dev/pts/321");
    defer freeClient(&first);
    var second = makeClient(setup.session, "second", "/dev/pts/322");
    defer freeClient(&second);
    client_registry.add(&second);
    client_registry.add(&first);

    var cause: ?[]u8 = null;
    var args = try args_mod.args_parse(xm.allocator, &.{ "-K", "#{line}" }, "F:f:K:NO:rt:yZ", 0, 1, &cause);
    defer args.deinit();

    const wme = enterMode(setup.pane, &args);
    try std.testing.expectEqual(@as(T.key_code, '0'), modeData(wme).tree.line_list.items[0].item.key);
    try std.testing.expectEqual(@as(T.key_code, '1'), modeData(wme).tree.line_list.items[1].item.key);
    const chosen = modeData(wme).items.items[1].client;

    clientModeKey(wme, &chooser, setup.session, setup.session.curw.?, '1', null);
    while (cmdq_mod.cmdq_next(&chooser) != 0) {}
    try std.testing.expect(chosen.session == null);
    try std.testing.expect(first.session != null or second.session != null);
    try std.testing.expect(window.window_pane_mode(setup.pane) == null);
}

test "window-client -Z zooms for the mode lifetime" {
    const sess = @import("session.zig");

    initTestGlobals();
    defer deinitTestGlobals();

    const setup = try testSetup("window-client-zoom");
    defer if (sess.session_find("window-client-zoom") != null) sess.session_destroy(setup.session, false, "test");

    const extra = window.window_add_pane(setup.pane.window, null, 80, 24);
    setup.pane.window.active = extra;

    var target = makeClient(setup.session, "target", "/dev/pts/340");
    defer freeClient(&target);
    client_registry.add(&target);

    var cause: ?[]u8 = null;
    var args = try args_mod.args_parse(xm.allocator, &.{"-Z"}, "F:f:K:NO:rt:yZ", 0, 1, &cause);
    defer args.deinit();

    _ = enterMode(setup.pane, &args);
    try std.testing.expect(setup.pane.window.flags & T.WINDOW_ZOOMED != 0);

    try std.testing.expect(window_mode_runtime.resetMode(setup.pane));
    try std.testing.expectEqual(@as(u32, 0), setup.pane.window.flags & T.WINDOW_ZOOMED);
}

test "window-client preview draws the selected client's current pane when enabled" {
    const grid = @import("grid.zig");
    const sess = @import("session.zig");

    initTestGlobals();
    defer deinitTestGlobals();

    const setup = try testSetup("window-client-preview");
    defer if (sess.session_find("window-client-preview") != null) sess.session_destroy(setup.session, false, "test");

    setGridLineText(setup.pane.base.grid, 0, "preview");

    var target = makeClient(setup.session, "target", "/dev/pts/350");
    defer freeClient(&target);
    target.tty.sx = 20;
    target.tty.sy = 24;
    setup.session.statusat = 23;
    target.status.screen = screen.screen_init(20, 1, 0);
    {
        var status_ctx = T.ScreenWriteCtx{ .s = target.status.screen.? };
        screen_write.putn(&status_ctx, "status");
    }
    client_registry.add(&target);

    var cause: ?[]u8 = null;
    var args = try args_mod.args_parse(xm.allocator, &.{"-N"}, "F:f:K:NO:rt:yZ", 0, 1, &cause);
    defer args.deinit();

    const wme = enterMode(setup.pane, &args);
    defer {
        if (window.window_pane_mode(setup.pane)) |_| _ = window_mode_runtime.resetMode(setup.pane);
    }

    const data = modeData(wme);
    try std.testing.expect(data.tree.preview != .off);

    const preview_line = grid.string_cells(clientModeGetScreen(wme).grid, 12, clientModeGetScreen(wme).grid.sx, .{ .trim_trailing_spaces = true });
    defer xm.allocator.free(preview_line);
    try std.testing.expect(std.mem.indexOf(u8, preview_line, "preview") != null);

    const status_line = grid.string_cells(clientModeGetScreen(wme).grid, 22, clientModeGetScreen(wme).grid.sx, .{ .trim_trailing_spaces = true });
    defer xm.allocator.free(status_line);
    try std.testing.expect(std.mem.indexOf(u8, status_line, "status") != null);
}

test "window-client mode update refreshes preview content" {
    const grid = @import("grid.zig");
    const sess = @import("session.zig");

    initTestGlobals();
    defer deinitTestGlobals();

    const setup = try testSetup("window-client-preview-update");
    defer if (sess.session_find("window-client-preview-update") != null) sess.session_destroy(setup.session, false, "test");

    setGridLineText(setup.pane.base.grid, 0, "before");

    var target = makeClient(setup.session, "target-update", "/dev/pts/351");
    defer freeClient(&target);
    target.tty.sx = 20;
    target.tty.sy = 24;
    setup.session.statusat = 23;
    client_registry.add(&target);

    var cause: ?[]u8 = null;
    var args = try args_mod.args_parse(xm.allocator, &.{"-N"}, "F:f:K:NO:rt:yZ", 0, 1, &cause);
    defer args.deinit();

    const wme = enterMode(setup.pane, &args);
    defer {
        if (window.window_pane_mode(setup.pane)) |_| _ = window_mode_runtime.resetMode(setup.pane);
    }

    setGridLineText(setup.pane.base.grid, 0, "after");
    window_client_mode.update.?(wme);

    const preview_line = grid.string_cells(clientModeGetScreen(wme).grid, 12, clientModeGetScreen(wme).grid.sx, .{ .trim_trailing_spaces = true });
    defer xm.allocator.free(preview_line);
    try std.testing.expect(std.mem.indexOf(u8, preview_line, "after") != null);
}
