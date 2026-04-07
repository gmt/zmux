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
const opts = @import("options.zig");
const screen = @import("screen.zig");
const screen_write = @import("screen-write.zig");
const server = @import("server.zig");
const server_client = @import("server-client.zig");
const sort_mod = @import("sort.zig");
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

const ClientItem = struct {
    client: *T.Client,
    target_name: []u8,
    text: []u8,
    key: T.key_code = T.KEYC_NONE,
    keystr: ?[]u8 = null,
    tagged: bool = false,
};

const ClientModeData = struct {
    format: []u8,
    key_format: []u8,
    filter: ?[]u8 = null,
    command: []u8,
    sort_crit: T.SortCriteria = .{},
    items: std.ArrayList(ClientItem) = .{},
    current: usize = 0,
    offset: usize = 0,
    max_key_label_width: usize = 0,
    zoomed: i8 = -1,
};

pub const window_client_mode = T.WindowMode{
    .name = "client-mode",
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
            maybeZoom(wme.wp, modeData(wme), args);
            rebuildAndDraw(wme);
            return wme;
        }
    }

    screen.screen_enter_alternate(wp, true);

    const data = xm.allocator.create(ClientModeData) catch unreachable;
    data.* = .{
        .format = xm.xstrdup(args.get('F') orelse DEFAULT_FORMAT),
        .key_format = xm.xstrdup(args.get('K') orelse DEFAULT_KEY_FORMAT),
        .filter = if (args.get('f')) |filter| xm.xstrdup(filter) else null,
        .command = xm.xstrdup(args.value_at(0) orelse DEFAULT_COMMAND),
        .sort_crit = .{
            .order = if (args.has('O')) sort_mod.sort_order_from_string(args.get('O')) else .name,
            .reversed = args.has('r'),
        },
    };
    maybeZoom(wp, data, args);

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
    _ = mouse;

    const data = modeData(wme);
    for (data.items.items, 0..) |item, idx| {
        if (item.key == T.KEYC_NONE or item.key != key) continue;
        data.current = idx;
        runCommand(client, session, wl, data.command, item.target_name);
        _ = window_mode_runtime.resetMode(wme.wp);
        return;
    }
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
        if (currentItem(data)) |item| runCommand(client, session, wl, data.command, item.target_name);
        _ = window_mode_runtime.resetMode(wme.wp);
        return;
    }
    if (std.mem.eql(u8, command, "cursor-up")) {
        moveUp(data, repeat);
        redraw(wme);
        return;
    }
    if (std.mem.eql(u8, command, "cursor-down")) {
        moveDown(data, repeat);
        redraw(wme);
        return;
    }
    if (std.mem.eql(u8, command, "page-up")) {
        pageUp(data, viewRows(wme.wp));
        redraw(wme);
        return;
    }
    if (std.mem.eql(u8, command, "page-down")) {
        pageDown(data, viewRows(wme.wp));
        redraw(wme);
        return;
    }
    if (std.mem.eql(u8, command, "tag")) {
        toggleTag(data);
        redraw(wme);
        return;
    }
    if (std.mem.eql(u8, command, "tag-all")) {
        for (data.items.items) |*item| item.tagged = true;
        redraw(wme);
        return;
    }
    if (std.mem.eql(u8, command, "tag-none")) {
        for (data.items.items) |*item| item.tagged = false;
        redraw(wme);
        return;
    }
    if (std.mem.eql(u8, command, "detach")) {
        actOnCurrent(data, protocol.MsgType, detachClient, .detach);
        rebuildAfterAction(wme);
        return;
    }
    if (std.mem.eql(u8, command, "detach-tagged")) {
        actOnTagged(data, protocol.MsgType, detachClient, .detach, true);
        rebuildAfterAction(wme);
        return;
    }
    if (std.mem.eql(u8, command, "kill")) {
        actOnCurrent(data, protocol.MsgType, detachClient, .detachkill);
        rebuildAfterAction(wme);
        return;
    }
    if (std.mem.eql(u8, command, "kill-tagged")) {
        actOnTagged(data, protocol.MsgType, detachClient, .detachkill, true);
        rebuildAfterAction(wme);
        return;
    }
    if (std.mem.eql(u8, command, "suspend")) {
        actOnCurrent(data, void, suspendClient, {});
        rebuildAfterAction(wme);
        return;
    }
    if (std.mem.eql(u8, command, "suspend-tagged")) {
        actOnTagged(data, void, suspendClient, {}, true);
        rebuildAfterAction(wme);
        return;
    }

    unsupportedCommand(client, command);
    redraw(wme);
}

fn clientModeClose(wme: *T.WindowModeEntry) void {
    const data = modeData(wme);
    freeItems(data);
    data.items.deinit(xm.allocator);
    xm.allocator.free(data.format);
    xm.allocator.free(data.key_format);
    if (data.filter) |filter| xm.allocator.free(filter);
    xm.allocator.free(data.command);

    if (data.zoomed == 0 and window.window_unzoom(wme.wp.window))
        server.server_redraw_window(wme.wp.window);

    xm.allocator.destroy(data);

    if (wme.wp.modes.items.len <= 1) {
        screen.screen_leave_alternate(wme.wp, true);
    }
}

fn clientModeGetScreen(wme: *T.WindowModeEntry) *T.Screen {
    return wme.wp.screen;
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

    if (data.filter) |filter| xm.allocator.free(filter);
    data.filter = if (args.get('f')) |filter| xm.xstrdup(filter) else null;

    xm.allocator.free(data.command);
    data.command = xm.xstrdup(args.value_at(0) orelse DEFAULT_COMMAND);

    data.sort_crit.order = if (args.has('O')) sort_mod.sort_order_from_string(args.get('O')) else .name;
    data.sort_crit.reversed = args.has('r');
}

fn maybeZoom(wp: *T.WindowPane, data: *ClientModeData, args: *const args_mod.Arguments) void {
    if (!args.has('Z') or data.zoomed != -1) return;

    data.zoomed = if (wp.window.flags & T.WINDOW_ZOOMED != 0) 1 else 0;
    if (data.zoomed == 0 and window.window_zoom(wp))
        server.server_redraw_window(wp.window);
}

fn rebuildAndDraw(wme: *T.WindowModeEntry) void {
    rebuildData(modeData(wme));
    redraw(wme);
}

fn rebuildAfterAction(wme: *T.WindowModeEntry) void {
    rebuildData(modeData(wme));
    if (countSelectableClients() == 0) {
        _ = window_mode_runtime.resetMode(wme.wp);
        return;
    }
    redraw(wme);
}

fn rebuildData(data: *ClientModeData) void {
    const previous_client = if (data.items.items.len != 0 and data.current < data.items.items.len)
        data.items.items[data.current].client
    else
        null;

    var tagged_clients: std.ArrayList(*T.Client) = .{};
    defer tagged_clients.deinit(xm.allocator);
    for (data.items.items) |item| {
        if (item.tagged) tagged_clients.append(xm.allocator, item.client) catch unreachable;
    }

    freeItems(data);
    data.items.clearRetainingCapacity();
    data.max_key_label_width = 0;

    const clients = sort_mod.sorted_clients(data.sort_crit);
    defer xm.allocator.free(clients);

    var restored_current = false;
    for (clients) |cl| {
        if (!isSelectable(cl)) continue;

        const ctx = clientFormatContext(cl);
        if (data.filter) |filter| {
            const matches = format_mod.format_filter_match(xm.allocator, filter, &ctx) orelse false;
            if (!matches) continue;
        }

        const text = format_mod.format_require_complete(xm.allocator, data.format, &ctx) orelse fallbackText(cl);
        const target_name = clientTargetName(cl);
        const line_number: u32 = @intCast(data.items.items.len);
        const item_key = keyForLine(data, cl, line_number);
        const item_keystr = if (item_key != T.KEYC_NONE)
            xm.xstrdup(key_string.key_string_lookup_key(item_key, 0))
        else
            null;
        data.items.append(xm.allocator, .{
            .client = cl,
            .target_name = target_name,
            .text = text,
            .key = item_key,
            .keystr = item_keystr,
            .tagged = isTagged(tagged_clients.items, cl),
        }) catch unreachable;
        if (item_keystr) |keystr|
            data.max_key_label_width = @max(data.max_key_label_width, keystr.len);
        if (!restored_current and previous_client == cl) {
            data.current = data.items.items.len - 1;
            restored_current = true;
        }
    }

    if (data.items.items.len == 0) {
        data.current = 0;
        data.offset = 0;
        return;
    }
    if (!restored_current or data.current >= data.items.items.len)
        data.current = 0;
    clampOffset(data, 1);
}

fn redraw(wme: *T.WindowModeEntry) void {
    const data = modeData(wme);
    const view = wme.wp.screen;

    screen.screen_reset_active(view);
    view.mode &= ~@as(i32, T.MODE_CURSOR | T.MODE_WRAP);
    view.cursor_visible = false;

    var ctx = T.ScreenWriteCtx{ .s = view };
    const width = view.grid.sx;
    const rows = view.grid.sy;
    const item_rows = viewRows(wme.wp);
    clampOffset(data, item_rows);

    var row: u32 = 0;
    while (row < item_rows) : (row += 1) {
        screen_write.cursor_to(&ctx, row, 0);
        screen_write.erase_line(&ctx);

        const index = data.offset + row;
        if (index >= data.items.items.len) continue;

        const line = renderLine(data, index);
        defer xm.allocator.free(line);
        screen_write.putn(&ctx, line);
    }

    if (rows > 0) {
        screen_write.cursor_to(&ctx, rows - 1, 0);
        screen_write.erase_line(&ctx);
        if (width != 0) screen_write.putn(&ctx, HELP_TEXT);
    }

    if (data.items.items.len == 0 and item_rows != 0) {
        screen_write.cursor_to(&ctx, 0, 0);
        screen_write.erase_line(&ctx);
        screen_write.putn(&ctx, if (data.filter != null) "No matching clients." else "No clients.");
    }

    window_mode_runtime.noteModeRedraw(wme.wp);
}

fn renderLine(data: *const ClientModeData, index: usize) []u8 {
    const item = data.items.items[index];
    const current = if (index == data.current) ">" else " ";
    const tagged = if (item.tagged) "*" else " ";

    var out: std.ArrayList(u8) = .{};
    defer out.deinit(xm.allocator);

    out.appendSlice(xm.allocator, current) catch unreachable;
    out.appendSlice(xm.allocator, tagged) catch unreachable;
    out.append(xm.allocator, ' ') catch unreachable;

    if (data.max_key_label_width != 0) {
        const key_width = data.max_key_label_width + 2;
        if (item.keystr) |keystr| {
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

fn clampOffset(data: *ClientModeData, rows: u32) void {
    if (data.items.items.len == 0 or rows == 0) {
        data.offset = 0;
        return;
    }
    if (data.current < data.offset) data.offset = data.current;
    const row_count: usize = rows;
    if (data.current >= data.offset + row_count) data.offset = data.current - row_count + 1;
}

fn moveUp(data: *ClientModeData, count: u32) void {
    if (data.items.items.len == 0) return;
    const step: usize = count;
    data.current -|= step;
    clampOffset(data, 1);
}

fn moveDown(data: *ClientModeData, count: u32) void {
    if (data.items.items.len == 0) return;
    const max_index = data.items.items.len - 1;
    data.current = @min(data.current + @as(usize, count), max_index);
    clampOffset(data, 1);
}

fn pageUp(data: *ClientModeData, rows: u32) void {
    if (data.items.items.len == 0) return;
    const step = if (rows > 1) rows - 1 else 1;
    data.current -|= @as(usize, step);
    clampOffset(data, rows);
}

fn pageDown(data: *ClientModeData, rows: u32) void {
    if (data.items.items.len == 0) return;
    const step = if (rows > 1) rows - 1 else 1;
    const max_index = data.items.items.len - 1;
    data.current = @min(data.current + @as(usize, step), max_index);
    clampOffset(data, rows);
}

fn toggleTag(data: *ClientModeData) void {
    const item = currentItem(data) orelse return;
    item.tagged = !item.tagged;
}

fn currentItem(data: *ClientModeData) ?*ClientItem {
    if (data.items.items.len == 0 or data.current >= data.items.items.len) return null;
    return &data.items.items[data.current];
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
    for (data.items.items) |*item| {
        if (!item.tagged) continue;
        fired = true;
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
        xm.allocator.free(item.target_name);
        xm.allocator.free(item.text);
        if (item.keystr) |keystr| xm.allocator.free(keystr);
    }
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

fn isTagged(tagged_clients: []*T.Client, client: *T.Client) bool {
    for (tagged_clients) |tagged_client| {
        if (tagged_client == client) return true;
    }
    return false;
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

pub fn window_client_resize(wme: *T.WindowModeEntry, _: u32, _: u32) void {
    redraw(wme);
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
    const text = format_mod.format_require_complete(
        xm.allocator,
        data.format,
        &clientFormatContext(cl),
    ) orelse fallbackText(cl);
    const target_name = clientTargetName(cl);
    const line_number: u32 = @intCast(data.items.items.len);
    const item_key = keyForLine(data, cl, line_number);
    const item_keystr = if (item_key != T.KEYC_NONE)
        xm.xstrdup(key_string.key_string_lookup_key(item_key, 0))
    else
        null;
    data.items.append(xm.allocator, .{
        .client = cl,
        .target_name = target_name,
        .text = text,
        .key = item_key,
        .keystr = item_keystr,
    }) catch unreachable;
    if (item_keystr) |keystr|
        data.max_key_label_width = @max(data.max_key_label_width, keystr.len);
}

pub fn window_client_free_item(item: *ClientItem) void {
    xm.allocator.free(item.target_name);
    xm.allocator.free(item.text);
    if (item.keystr) |keystr| xm.allocator.free(keystr);
}

pub fn window_client_build(wme: *T.WindowModeEntry) void {
    rebuildData(modeData(wme));
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
        moveDown(data, 1);
    if (key == 'd' or key == 'D')
        server_client.server_client_detach(item.client, .detach)
    else if (key == 'x' or key == 'X')
        server_client.server_client_detach(item.client, .detachkill)
    else if (key == 'z' or key == 'Z')
        server_client.server_client_suspend(item.client);
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

pub fn window_client_get_key(
    data: *const ClientModeData,
    cl: *T.Client,
    line: u32,
) T.key_code {
    return keyForLine(data, cl, line);
}

pub fn window_client_sort(sort_crit: *T.SortCriteria) void {
    sort_crit.order_seq = &window_client_order_seq;
    if (sort_crit.order == .end)
        sort_crit.order = window_client_order_seq[0];
}

pub fn window_client_help(width: *u32, item_name: *[]const u8) []const []const u8 {
    width.* = 0;
    item_name.* = "client";
    return &window_client_help_lines;
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
    const first_line = renderLine(data, 0);
    defer xm.allocator.free(first_line);
    try std.testing.expect(std.mem.indexOf(u8, first_line, "[0]") != null);

    data.current = 1;
    rebuildData(data);
    try std.testing.expectEqualStrings("/dev/pts/202", data.items.items[data.current].target_name);
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
    try std.testing.expectEqual(@as(T.key_code, '0'), modeData(wme).items.items[0].key);
    try std.testing.expectEqual(@as(T.key_code, '1'), modeData(wme).items.items[1].key);
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
