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
const cmd_mod = @import("cmd.zig");
const cmdq = @import("cmd-queue.zig");
const format_mod = @import("format.zig");
const mode_tree = @import("mode-tree.zig");
const opts = @import("options.zig");
const screen = @import("screen.zig");
const screen_write = @import("screen-write.zig");
const sess = @import("session.zig");
const sort_mod = @import("sort.zig");
const status_runtime = @import("status-runtime.zig");
const T = @import("types.zig");
const window = @import("window.zig");
const window_mode_runtime = @import("window-mode-runtime.zig");
const xm = @import("xmalloc.zig");

const DEFAULT_COMMAND = "switch-client -Zt '%%'";
const DEFAULT_SESSION_FORMAT = "#{session_name}: #{session_windows} windows#{?session_attached, (attached),}";
const DEFAULT_WINDOW_FORMAT = "#{window_index}:#{window_name}#{window_flags}";
const DEFAULT_PANE_FORMAT = "#{pane_index}: #{pane_current_command}#{?pane_active,*,}#{?pane_title, \"#{pane_title}\",}";
const HELP_TEXT = "Enter choose  arrows move  left/right fold  t/T/^T tags  H home  q cancel";

pub const DisplayKind = enum {
    session,
    window,
    pane,
};

pub const EnterConfig = struct {
    fs: *const T.CmdFindState,
    kind: DisplayKind = .pane,
    format: ?[]const u8 = null,
    filter: ?[]const u8 = null,
    command: ?[]const u8 = null,
    sort_crit: T.SortCriteria = .{},
    squash_groups: bool = true,
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
    filter: ?[]u8 = null,
    command: []u8,
    sort_crit: T.SortCriteria = .{},
    kind: DisplayKind = .pane,
    squash_groups: bool = true,
};

pub const window_tree_mode = T.WindowMode{
    .name = "tree-mode",
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
        .filter = if (config.filter) |filter| xm.xstrdup(filter) else null,
        .command = xm.xstrdup(config.command orelse DEFAULT_COMMAND),
        .sort_crit = config.sort_crit,
        .kind = config.kind,
        .squash_groups = config.squash_groups,
    };

    data.tree = mode_tree.start(wp, .{
        .modedata = @ptrCast(data),
        .buildcb = buildTree,
        .searchcb = searchItem,
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
    _ = mouse;

    const args: *const args_mod.Arguments = @ptrCast(@alignCast(raw_args));
    if (args.count() == 0) return;

    const command = args.value_at(0).?;
    const data = modeData(wme);
    const repeat = repeatCount(wme);

    if (std.mem.eql(u8, command, "cancel")) {
        _ = window_mode_runtime.resetMode(wme.wp);
        return;
    }
    if (std.mem.eql(u8, command, "choose")) {
        chooseCurrent(wme, client, session, wl);
        return;
    }
    if (std.mem.eql(u8, command, "cursor-up")) {
        var remaining = repeat;
        while (remaining > 0) : (remaining -= 1) mode_tree.up(data.tree, false);
        redraw(wme);
        wme.prefix = 1;
        return;
    }
    if (std.mem.eql(u8, command, "cursor-down")) {
        var remaining = repeat;
        while (remaining > 0) : (remaining -= 1) _ = mode_tree.down(data.tree, false);
        redraw(wme);
        wme.prefix = 1;
        return;
    }
    if (std.mem.eql(u8, command, "page-up")) {
        pageUp(data.tree, viewRows(wme.wp), repeat);
        redraw(wme);
        wme.prefix = 1;
        return;
    }
    if (std.mem.eql(u8, command, "page-down")) {
        pageDown(data.tree, viewRows(wme.wp), repeat);
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
        focusTarget(data);
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
    _client: ?*T.Client,
    _session: *T.Session,
    _wl: *T.Winlink,
    key: T.key_code,
    mouse: ?*const T.MouseEvent,
) void {
    _ = _client;
    _ = _session;
    _ = _wl;

    if (mouse != null) return;

    const data = modeData(wme);
    switch (key) {
        T.KEYC_WHEELUP => {
            mode_tree.up(data.tree, false);
            redraw(wme);
        },
        T.KEYC_WHEELDOWN => {
            _ = mode_tree.down(data.tree, false);
            redraw(wme);
        },
        else => {},
    }
}

fn windowTreeClose(wme: *T.WindowModeEntry) void {
    const data = modeData(wme);
    mode_tree.free(data.tree);
    freeItems(data);
    data.items.deinit(xm.allocator);
    xm.allocator.free(data.format);
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
    const body_rows = viewRows(wme.wp);

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
    else
        switch (item_type) {
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
    const data = modeData(wme);
    const item_ptr = mode_tree.getCurrent(data.tree) orelse return;
    const item: *TreeItem = @ptrCast(@alignCast(item_ptr));
    const target_name = targetName(item) orelse return;
    defer xm.allocator.free(target_name);

    runCommand(client, session, wl, data.command, target_name);
    _ = window_mode_runtime.resetMode(wme.wp);
}

fn targetName(item: *const TreeItem) ?[]u8 {
    return switch (item.item_type) {
        .session => xm.xasprintf("={s}:", .{item.session.name}),
        .window => xm.xasprintf("={s}:{d}.", .{ item.session.name, item.winlink.?.idx }),
        .pane => xm.xasprintf("={s}:{d}.%{d}", .{ item.session.name, item.winlink.?.idx, item.pane.?.id }),
    };
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

fn unsupportedCommand(client: ?*T.Client, command: []const u8) void {
    const cl = client orelse return;
    const text = xm.xasprintf("Tree-mode command not supported yet: {s}", .{command});
    defer xm.allocator.free(text);
    status_runtime.present_client_message(cl, text);
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
        .status = .{ .screen = undefined },
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
    var args = try args_mod.args_parse(xm.allocator, &.{ "choose" }, "", 1, 1, &args_cause);
    defer args.deinit();
    windowTreeCommand(wme, &client, session_ptr, wl, @ptrCast(&args), null);
    while (cmdq_mod.cmdq_next(null) != 0) {}

    try std.testing.expect(wl.window.active == extra);
    try std.testing.expect(window.window_pane_mode(extra) == null);
}
