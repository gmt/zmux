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
// Ported in part from tmux/window-buffer.c.
// Original copyright:
//   Copyright (c) 2017 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

//! window-buffer.zig - reduced choose-buffer pane mode.

const std = @import("std");
const T = @import("types.zig");
const args_mod = @import("arguments.zig");
const cmd_mod = @import("cmd.zig");
const cmdq = @import("cmd-queue.zig");
const editor_handoff = @import("editor-handoff.zig");
const format_mod = @import("format.zig");
const mode_tree = @import("mode-tree.zig");
const opts = @import("options.zig");
const paste_mod = @import("paste.zig");
const key_string = @import("key-string.zig");
const screen = @import("screen.zig");
const screen_write = @import("screen-write.zig");
const server_client = @import("server-client.zig");
const sort_mod = @import("sort.zig");
const status_prompt = @import("status-prompt.zig");
const status_runtime = @import("status-runtime.zig");
const window = @import("window.zig");
const window_mode_runtime = @import("window-mode-runtime.zig");
const xm = @import("xmalloc.zig");

const DEFAULT_COMMAND = "paste-buffer -p -b '%%'";
const DEFAULT_FORMAT = "#{t/p:buffer_created}: #{buffer_sample}";
const DEFAULT_KEY_FORMAT =
    "#{?#{e|<:#{line},10}," ++
    "#{line}" ++
    ",#{e|<:#{line},36}," ++
    "M-#{a:#{e|+:97,#{e|-:#{line},10}}}" ++
    "}";
const HELP_TEXT = "Enter/p/P paste  d/D delete  t/T/^T tags  e edit  arrows move  q cancel";

const BufferItem = struct {
    buffer: *paste_mod.PasteBuffer,
    name: []u8,
    text: []u8,
};

const BufferModeData = struct {
    fs: T.CmdFindState,
    tree: *mode_tree.Data,
    items: std.ArrayList(*BufferItem) = .{},
    format: []u8,
    key_format: []u8,
    filter: ?[]u8 = null,
    command: []u8,
    sort_crit: T.SortCriteria = .{},
};

fn previewModeFromArgs(args: *const args_mod.Arguments) mode_tree.Preview {
    const count = if (args.entry('N')) |entry| entry.count else 0;
    return switch (count) {
        0 => .normal,
        1 => .off,
        else => .big,
    };
}

const EditData = struct {
    wp_id: u32,
    name: []u8,
    pb: *paste_mod.PasteBuffer,
};

const FilterPromptState = struct {
    pane_id: u32,
};

var edit_dispatch_hook: ?*const fn (*T.Client, []const u8) void = null;

pub const window_buffer_mode = T.WindowMode{
    .name = "buffer-mode",
    .key_table = windowBufferKeyTable,
    .command = windowBufferCommand,
    .close = windowBufferClose,
    .get_screen = windowBufferGetScreen,
};

pub fn enterMode(
    wp: *T.WindowPane,
    fs: *const T.CmdFindState,
    args: *const args_mod.Arguments,
) *T.WindowModeEntry {
    if (window.window_pane_mode(wp)) |wme| {
        if (wme.mode == &window_buffer_mode) {
            refreshFromArgs(wme, fs, args);
            if (args.has('Z'))
                mode_tree.zoom(modeData(wme).tree, true);
            rebuildAndDraw(wme);
            return wme;
        }
    }

    screen.screen_enter_alternate(wp, true);

    const data = xm.allocator.create(BufferModeData) catch unreachable;
    data.* = .{
        .fs = fs.*,
        .tree = undefined,
        .format = xm.xstrdup(args.get('F') orelse DEFAULT_FORMAT),
        .key_format = xm.xstrdup(args.get('K') orelse DEFAULT_KEY_FORMAT),
        .filter = if (args.get('f')) |filter| xm.xstrdup(filter) else null,
        .command = xm.xstrdup(args.value_at(0) orelse DEFAULT_COMMAND),
        .sort_crit = .{
            .order = if (args.has('O')) sort_mod.sort_order_from_string(args.get('O')) else .creation,
            .reversed = args.has('r'),
        },
    };

    data.tree = mode_tree.start(wp, .{
        .modedata = @ptrCast(data),
        .preview = previewModeFromArgs(args),
        .zoom = args.has('Z'),
        .buildcb = buildTree,
        .searchcb = searchItem,
        .menucb = modeTreeMenuCallback,
        .keycb = modeTreeKeyCallback,
        .helpcb = modeTreeHelpCallback,
    });

    const wme = window_mode_runtime.pushMode(wp, &window_buffer_mode, @ptrCast(data), null);
    wme.prefix = 1;
    rebuildAndDraw(wme);
    return wme;
}

fn windowBufferKeyTable(wme: *T.WindowModeEntry) []const u8 {
    if (opts.options_get_number(wme.wp.window.options, "mode-keys") == T.MODEKEY_VI)
        return "buffer-mode-vi";
    return "buffer-mode";
}

fn windowBufferCommand(
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
    defer wme.prefix = 1;

    if (std.mem.eql(u8, command, "cancel")) {
        _ = window_mode_runtime.resetMode(wme.wp);
        return;
    }
    if (std.mem.eql(u8, command, "choose") or std.mem.eql(u8, command, "paste")) {
        chooseCurrent(wme, client, session, wl);
        return;
    }
    if (std.mem.eql(u8, command, "edit-selected")) {
        startEditSelected(wme, client);
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
    if (std.mem.eql(u8, command, "delete")) {
        deleteCurrent(wme);
        return;
    }
    if (std.mem.eql(u8, command, "delete-tagged")) {
        deleteTagged(wme);
        return;
    }
    if (std.mem.eql(u8, command, "paste-tagged")) {
        pasteTagged(wme, client, session, wl);
        return;
    }
    if (std.mem.eql(u8, command, "filter")) {
        startFilterPrompt(wme, client);
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
        pageUp(data.tree, viewRows(wme.wp), repeat);
        redraw(wme);
        return;
    }
    if (std.mem.eql(u8, command, "page-down")) {
        pageDown(data.tree, viewRows(wme.wp), repeat);
        redraw(wme);
        return;
    }

    unsupportedCommand(client, command);
    redraw(wme);
}

fn windowBufferClose(wme: *T.WindowModeEntry) void {
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

fn windowBufferGetScreen(wme: *T.WindowModeEntry) *T.Screen {
    return modeData(wme).tree.getScreen();
}

fn modeData(wme: *T.WindowModeEntry) *BufferModeData {
    return @ptrCast(@alignCast(wme.data.?));
}

pub fn window_buffer_data(wme: *T.WindowModeEntry) *BufferModeData {
    return modeData(wme);
}

fn refreshFromArgs(wme: *T.WindowModeEntry, fs: *const T.CmdFindState, args: *const args_mod.Arguments) void {
    const data = modeData(wme);
    data.fs = fs.*;
    data.sort_crit.order = if (args.has('O')) sort_mod.sort_order_from_string(args.get('O')) else .creation;
    data.sort_crit.reversed = args.has('r');

    xm.allocator.free(data.format);
    data.format = xm.xstrdup(args.get('F') orelse DEFAULT_FORMAT);

    xm.allocator.free(data.key_format);
    data.key_format = xm.xstrdup(args.get('K') orelse DEFAULT_KEY_FORMAT);

    if (data.filter) |filter| xm.allocator.free(filter);
    data.filter = if (args.get('f')) |filter| xm.xstrdup(filter) else null;

    xm.allocator.free(data.command);
    data.command = xm.xstrdup(args.value_at(0) orelse DEFAULT_COMMAND);
}

fn rebuildAndDraw(wme: *T.WindowModeEntry) void {
    const data = modeData(wme);
    mode_tree.setFilter(data.tree, data.filter);
    mode_tree.build(data.tree);
    redraw(wme);
}

fn modeTreeMenuCallback(tree: *mode_tree.Data, client: ?*T.Client, key: T.key_code) void {
    const wme = window.window_pane_mode(tree.wp) orelse return;
    if (wme.mode != &window_buffer_mode) return;
    window_buffer_menu(wme, client, key);
}

fn modeTreeKeyCallback(tree: *mode_tree.Data, itemdata: ?*anyopaque, line: u32) T.key_code {
    const wme = window.window_pane_mode(tree.wp) orelse return T.KEYC_NONE;
    if (wme.mode != &window_buffer_mode) return T.KEYC_NONE;
    const item: *BufferItem = @ptrCast(@alignCast(itemdata orelse return T.KEYC_NONE));
    return window_buffer_get_key(wme, item, line);
}

fn modeTreeHelpCallback(width: *u32, item_name: *[]const u8) ?[*]const ?[*:0]const u8 {
    const lines = window_buffer_help(width, item_name);
    return @ptrCast(lines.ptr);
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
        screen_write.putn(&ctx, if (data.filter != null) "No matching buffers." else "No buffers.");
    }

    window_mode_runtime.noteModeRedraw(wme.wp);
}

fn buildTree(tree: *mode_tree.Data) void {
    const data: *BufferModeData = @ptrCast(@alignCast(tree.modedata.?));
    freeItems(data);

    const buffers = sort_mod.sorted_buffers(data.sort_crit);
    defer xm.allocator.free(buffers);

    for (buffers) |pb| {
        const ctx = formatContext(data, pb);
        if (data.filter) |filter| {
            const matches = format_mod.format_filter_match(xm.allocator, filter, &ctx) orelse false;
            if (!matches) continue;
        }

        const item = allocItem(data, pb);
        _ = mode_tree.add(tree, null, @ptrCast(item), tagForBuffer(pb), item.name, item.text, 0);
    }
}

fn allocItem(data: *BufferModeData, pb: *paste_mod.PasteBuffer) *BufferItem {
    const item = xm.allocator.create(BufferItem) catch unreachable;
    item.* = .{
        .buffer = pb,
        .name = xm.xstrdup(paste_mod.paste_buffer_name(pb)),
        .text = renderItemText(data, pb),
    };
    data.items.append(xm.allocator, item) catch unreachable;
    return item;
}

fn renderItemText(data: *const BufferModeData, pb: *paste_mod.PasteBuffer) []u8 {
    const ctx = formatContext(data, pb);
    return format_mod.format_require_complete(xm.allocator, data.format, &ctx) orelse fallbackText(pb);
}

fn fallbackText(pb: *paste_mod.PasteBuffer) []u8 {
    const sample = paste_mod.paste_make_sample(pb);
    defer xm.allocator.free(sample);
    return xm.xasprintf("{s}", .{sample});
}

fn formatContext(data: *const BufferModeData, pb: *paste_mod.PasteBuffer) format_mod.FormatContext {
    return .{
        .session = data.fs.s,
        .winlink = data.fs.wl,
        .window = data.fs.w,
        .pane = data.fs.wp,
        .paste_buffer = pb,
    };
}

fn searchItem(tree: *mode_tree.Data, itemdata: ?*anyopaque, search: []const u8, ignore_case: bool) bool {
    const data: *BufferModeData = @ptrCast(@alignCast(tree.modedata.?));
    const item: *BufferItem = @ptrCast(@alignCast(itemdata.?));
    _ = data;
    return contains(item.text, search, ignore_case) or contains(item.name, search, ignore_case);
}

fn renderLine(tree: *const mode_tree.Data, index: usize) []u8 {
    const line = tree.line_list.items[index];
    const item: *BufferItem = @ptrCast(@alignCast(line.item.itemdata.?));
    const current = if (index == tree.current) ">" else " ";
    const tagged = if (line.item.tagged) "*" else " ";
    return xm.xasprintf("{s}{s} {s}", .{ current, tagged, item.text });
}

fn chooseCurrent(wme: *T.WindowModeEntry, client: ?*T.Client, session: *T.Session, wl: *T.Winlink) void {
    const data = modeData(wme);
    const item_ptr = mode_tree.getCurrent(data.tree) orelse return;
    const item: *BufferItem = @ptrCast(@alignCast(item_ptr));

    runCommand(client, session, wl, data.command, item.name);
    _ = window_mode_runtime.resetMode(wme.wp);
}

fn startEditSelected(wme: *T.WindowModeEntry, client: ?*T.Client) void {
    const cl = client orelse return;
    if ((cl.flags & T.CLIENT_ATTACHED) == 0) return;
    if (edit_dispatch_hook == null and (cl.session == null or cl.peer == null or (cl.flags & (T.CLIENT_CONTROL | T.CLIENT_SUSPENDED)) != 0))
        return;

    const data = modeData(wme);
    const item_ptr = mode_tree.getCurrent(data.tree) orelse return;
    const item: *BufferItem = @ptrCast(@alignCast(item_ptr));
    const initial = paste_mod.paste_buffer_data(item.buffer, null);

    const ed = xm.allocator.create(EditData) catch unreachable;
    ed.* = .{
        .wp_id = data.tree.wp.id,
        .name = xm.xstrdup(paste_mod.paste_buffer_name(item.buffer)),
        .pb = item.buffer,
    };
    const command = editor_handoff.begin(cl, initial, finishEditClose, @ptrCast(ed)) orelse {
        finishEdit(ed);
        return;
    };
    defer xm.allocator.free(command);

    dispatchEditCommand(cl, command);
}

fn startFilterPrompt(wme: *T.WindowModeEntry, client: ?*T.Client) void {
    const cl = client orelse return;
    if ((cl.flags & T.CLIENT_ATTACHED) == 0) return;

    const state = xm.allocator.create(FilterPromptState) catch unreachable;
    state.* = .{ .pane_id = wme.wp.id };
    status_prompt.status_prompt_set(
        cl,
        null,
        "(filter) ",
        modeData(wme).filter,
        filterPromptCallback,
        null,
        freeFilterPromptState,
        state,
        status_prompt.PROMPT_NOFORMAT,
        .search,
    );
}

fn deleteCurrent(wme: *T.WindowModeEntry) void {
    const data = modeData(wme);
    const item_ptr = mode_tree.getCurrent(data.tree) orelse return;
    deleteItem(data, item_ptr);
    rebuildAfterDelete(wme);
}

fn deleteTagged(wme: *T.WindowModeEntry) void {
    const data = modeData(wme);
    mode_tree.eachTagged(data.tree, deleteTaggedCallback, null, T.KEYC_NONE, false);
    rebuildAfterDelete(wme);
}

fn pasteTagged(wme: *T.WindowModeEntry, client: ?*T.Client, session: *T.Session, wl: *T.Winlink) void {
    const data = modeData(wme);
    data.fs.s = session;
    data.fs.wl = wl;
    data.fs.w = wl.window;
    data.fs.wp = wl.window.active;
    data.fs.idx = wl.idx;
    mode_tree.eachTagged(data.tree, pasteTaggedCallback, client, T.KEYC_NONE, false);
    _ = window_mode_runtime.resetMode(wme.wp);
}

fn deleteTaggedCallback(tree: *mode_tree.Data, itemdata: ?*anyopaque, _: ?*T.Client, _: T.key_code) void {
    const data: *BufferModeData = @ptrCast(@alignCast(tree.modedata.?));
    const item_ptr = itemdata orelse return;
    deleteItem(data, item_ptr);
}

fn pasteTaggedCallback(tree: *mode_tree.Data, itemdata: ?*anyopaque, client: ?*T.Client, _: T.key_code) void {
    const data: *BufferModeData = @ptrCast(@alignCast(tree.modedata.?));
    const item_ptr = itemdata orelse return;
    const item: *BufferItem = @ptrCast(@alignCast(item_ptr));
    runCommand(client, data.fs.s.?, data.fs.wl.?, data.command, item.name);
}

fn deleteItem(data: *BufferModeData, item_ptr: *anyopaque) void {
    const item: *BufferItem = @ptrCast(@alignCast(item_ptr));
    if (mode_tree.getCurrent(data.tree) == item_ptr) {
        if (!mode_tree.down(data.tree, false))
            mode_tree.up(data.tree, false);
    }
    paste_mod.paste_free(item.buffer);
}

fn rebuildAfterDelete(wme: *T.WindowModeEntry) void {
    if (paste_mod.paste_is_empty()) {
        _ = window_mode_runtime.resetMode(wme.wp);
        return;
    }
    rebuildAndDraw(wme);
}

fn runCommand(client: ?*T.Client, session: *T.Session, wl: *T.Winlink, template: []const u8, buffer_name: []const u8) void {
    const cl = client orelse return;
    const expanded = templateReplace(template, buffer_name, 1);
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

fn dispatchEditCommand(client: *T.Client, command: []const u8) void {
    if (edit_dispatch_hook) |hook| {
        hook(client, command);
        return;
    }
    server_client.server_client_lock(client, command);
}

fn filterPromptCallback(_: *T.Client, data: ?*anyopaque, input: ?[]const u8, _: bool) i32 {
    const state: *FilterPromptState = @ptrCast(@alignCast(data orelse return 0));
    const pane = window.window_pane_find_by_id(state.pane_id) orelse return 0;
    const wme = window.window_pane_mode(pane) orelse return 0;
    if (wme.mode != &window_buffer_mode) return 0;

    const mode_data = modeData(wme);
    if (mode_data.filter) |filter| xm.allocator.free(filter);

    if (input) |text| {
        if (text.len != 0)
            mode_data.filter = xm.xstrdup(text)
        else
            mode_data.filter = null;
    } else {
        mode_data.filter = null;
    }

    rebuildAndDraw(wme);
    return 0;
}

fn freeFilterPromptState(data: ?*anyopaque) void {
    const state: *FilterPromptState = @ptrCast(@alignCast(data orelse return));
    xm.allocator.destroy(state);
}

fn finishEditClose(buf: ?[]u8, arg: ?*anyopaque) void {
    const ed: *EditData = @ptrCast(@alignCast(arg.?));
    defer finishEdit(ed);

    var owned = buf orelse return;

    const pb = paste_mod.paste_get_name(ed.name) orelse {
        xm.allocator.free(owned);
        return;
    };
    if (pb != ed.pb) {
        xm.allocator.free(owned);
        return;
    }

    const oldbuf = paste_mod.paste_buffer_data(pb, null);
    var new_len = owned.len;
    if (oldbuf.len != 0 and oldbuf[oldbuf.len - 1] != '\n' and owned[new_len - 1] == '\n')
        new_len -= 1;

    if (new_len != 0) {
        if (new_len != owned.len) {
            const trimmed = xm.allocator.dupe(u8, owned[0..new_len]) catch unreachable;
            xm.allocator.free(owned);
            owned = trimmed;
        }
        paste_mod.paste_replace(pb, owned);
    } else {
        xm.allocator.free(owned);
    }

    const wp = window.window_pane_find_by_id(ed.wp_id) orelse return;
    if (window.window_pane_mode(wp)) |wme| {
        if (wme.mode == &window_buffer_mode)
            rebuildAndDraw(wme);
    }
    wp.flags |= T.PANE_REDRAW;
}

fn finishEdit(ed: *EditData) void {
    xm.allocator.free(ed.name);
    xm.allocator.destroy(ed);
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

fn tagForBuffer(pb: *paste_mod.PasteBuffer) u64 {
    return @intFromPtr(pb);
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

fn repeatCount(wme: *T.WindowModeEntry) u32 {
    return if (wme.prefix == 0) 1 else wme.prefix;
}

fn unsupportedCommand(client: ?*T.Client, command: []const u8) void {
    const cl = client orelse return;
    const text = xm.xasprintf("Buffer-mode command not supported yet: {s}", .{command});
    defer xm.allocator.free(text);
    status_runtime.present_client_message(cl, text);
}

fn freeItems(data: *BufferModeData) void {
    for (data.items.items) |item| {
        xm.allocator.free(item.name);
        xm.allocator.free(item.text);
        xm.allocator.destroy(item);
    }
    data.items.clearRetainingCapacity();
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

// ── tmux-compatible public API (window-buffer) ─────────────────────────

const window_buffer_order_seq = [_]T.SortOrder{ .creation, .name, .size, .end };

const window_buffer_help_lines = [_][]const u8{
    "\r\x1b[1m      Enter \x1b[0m\x0ex\x0f \x1b[0mPaste selected %1\n",
    "\r\x1b[1m          p \x1b[0m\x0ex\x0f \x1b[0mPaste selected %1\n",
    "\r\x1b[1m          P \x1b[0m\x0ex\x0f \x1b[0mPaste tagged %1s\n",
    "\r\x1b[1m          d \x1b[0m\x0ex\x0f \x1b[0mDelete selected %1\n",
    "\r\x1b[1m          D \x1b[0m\x0ex\x0f \x1b[0mDelete tagged %1s\n",
    "\r\x1b[1m          e \x1b[0m\x0ex\x0f \x1b[0mOpen %1 in editor\n",
    "\r\x1b[1m          f \x1b[0m\x0ex\x0f \x1b[0mEnter a filter\n",
};

pub fn window_buffer_init(
    wp: *T.WindowPane,
    fs: *const T.CmdFindState,
    args: *const args_mod.Arguments,
) *T.Screen {
    const wme = enterMode(wp, fs, args);
    return windowBufferGetScreen(wme);
}

pub fn window_buffer_free(wme: *T.WindowModeEntry) void {
    windowBufferClose(wme);
}

pub fn window_buffer_resize(wme: *T.WindowModeEntry, _: u32, _: u32) void {
    redraw(wme);
}

pub fn window_buffer_update(wme: *T.WindowModeEntry) void {
    rebuildAndDraw(wme);
}

pub fn window_buffer_key(
    wme: *T.WindowModeEntry,
    client: ?*T.Client,
    session: ?*T.Session,
    wl: ?*T.Winlink,
    key: T.key_code,
    _: ?*const T.MouseEvent,
) void {
    if (paste_mod.paste_is_empty()) {
        _ = window_mode_runtime.resetMode(wme.wp);
        return;
    }
    var finished = false;
    switch (key) {
        'e' => startEditSelected(wme, client),
        'd' => {
            window_buffer_do_delete(wme);
            rebuildAfterDelete(wme);
            return;
        },
        'D' => {
            deleteTagged(wme);
            return;
        },
        'P' => {
            if (session != null and wl != null)
                pasteTagged(wme, client, session.?, wl.?);
            return;
        },
        'p', '\r' => {
            if (session != null and wl != null)
                window_buffer_do_paste(wme, client, session.?, wl.?);
            finished = true;
        },
        else => {},
    }
    if (finished or paste_mod.paste_is_empty())
        _ = window_mode_runtime.resetMode(wme.wp)
    else
        redraw(wme);
}

pub fn window_buffer_add_item(
    data: *BufferModeData,
    pb: *paste_mod.PasteBuffer,
) *BufferItem {
    return allocItem(data, pb);
}

pub fn window_buffer_free_item(data: *BufferModeData, item: *BufferItem) void {
    for (data.items.items, 0..) |stored, idx| {
        if (stored == item) {
            _ = data.items.swapRemove(idx);
            break;
        }
    }
    xm.allocator.free(item.name);
    xm.allocator.free(item.text);
    xm.allocator.destroy(item);
}

pub fn window_buffer_build(wme: *T.WindowModeEntry) void {
    buildTree(modeData(wme).tree);
}

pub fn window_buffer_draw(
    wme: *T.WindowModeEntry,
    ctx: *T.ScreenWriteCtx,
    sx: u32,
    sy: u32,
) void {
    const data = modeData(wme);
    const item_ptr = mode_tree.getCurrent(data.tree) orelse return;
    const item: *BufferItem = @ptrCast(@alignCast(item_ptr));

    const pdata = paste_mod.paste_buffer_data(item.buffer, null);
    if (pdata.len == 0) return;

    const cx = ctx.s.cx;
    const cy = ctx.s.cy;
    var pos: usize = 0;
    var row: u32 = 0;
    while (row < sy and pos < pdata.len) : (row += 1) {
        const start = pos;
        while (pos < pdata.len and pdata[pos] != '\n') : (pos += 1) {}
        const line = pdata[start..pos];
        if (line.len > 0) {
            screen_write.cursormove(ctx, cx, cy + row, false);
            screen_write.nputs(ctx, @intCast(sx), &T.grid_default_cell, line);
        }
        if (pos < pdata.len) pos += 1;
    }
}

pub fn window_buffer_find(
    data: []const u8,
    needle: []const u8,
    icase: bool,
) bool {
    return contains(data, needle, icase);
}

pub fn window_buffer_search(
    wme: *T.WindowModeEntry,
    item: *BufferItem,
    ss: []const u8,
    icase: bool,
) bool {
    return searchItem(modeData(wme).tree, @ptrCast(item), ss, icase);
}

pub fn window_buffer_menu(
    wme: *T.WindowModeEntry,
    client: ?*T.Client,
    key: T.key_code,
) void {
    if (wme.mode != &window_buffer_mode) return;
    window_buffer_key(wme, client, null, null, key, null);
}

pub fn window_buffer_get_key(
    wme: *T.WindowModeEntry,
    item: *BufferItem,
    line: u32,
) T.key_code {
    const data = modeData(wme);
    const pb = paste_mod.paste_get_name(item.name) orelse return T.KEYC_NONE;

    var ctx = formatContext(data, pb);
    ctx.line = line;

    const expanded = format_mod.format_require_complete(
        xm.allocator,
        data.key_format,
        &ctx,
    ) orelse return T.KEYC_NONE;
    defer xm.allocator.free(expanded);

    const key = key_string.key_string_lookup_string(expanded);
    if (key == T.KEYC_UNKNOWN or key == T.KEYC_NONE) return T.KEYC_NONE;
    return key;
}

pub fn window_buffer_sort(sort_crit: *T.SortCriteria) void {
    sort_crit.order_seq = &window_buffer_order_seq;
    if (sort_crit.order == .end)
        sort_crit.order = window_buffer_order_seq[0];
}

pub fn window_buffer_help(width: *u32, item_name: *[]const u8) []const []const u8 {
    width.* = 0;
    item_name.* = "buffer";
    return &window_buffer_help_lines;
}

pub fn window_buffer_do_delete(wme: *T.WindowModeEntry) void {
    const data = modeData(wme);
    const item_ptr = mode_tree.getCurrent(data.tree) orelse return;
    deleteItem(data, item_ptr);
}

pub fn window_buffer_do_paste(
    wme: *T.WindowModeEntry,
    client: ?*T.Client,
    session: *T.Session,
    wl: *T.Winlink,
) void {
    const data = modeData(wme);
    const item_ptr = mode_tree.getCurrent(data.tree) orelse return;
    const item: *BufferItem = @ptrCast(@alignCast(item_ptr));
    if (paste_mod.paste_get_name(item.name) != null)
        runCommand(client, session, wl, data.command, item.name);
}

pub fn window_buffer_start_edit(
    wme: *T.WindowModeEntry,
    client: ?*T.Client,
) void {
    startEditSelected(wme, client);
}

pub fn window_buffer_finish_edit(ed: *EditData) void {
    finishEdit(ed);
}

pub fn window_buffer_edit_close_cb(buf: ?[]u8, arg: ?*anyopaque) void {
    finishEditClose(buf, arg);
}

fn sendPromptKey(client: *T.Client, key: T.key_code, bytes: []const u8) bool {
    var event = T.key_event{ .key = key, .len = bytes.len };
    if (bytes.len != 0) @memcpy(event.data[0..bytes.len], bytes);
    return status_prompt.status_prompt_handle_key(client, &event);
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

    editor_handoff.resetForTests();
    paste_mod.paste_reset_for_tests();
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

test "window-buffer mode lists paste buffers and preserves current buffer" {
    const sess = @import("session.zig");

    initTestGlobals();
    defer deinitTestGlobals();

    const setup = try testSetup("window-buffer-render");
    defer if (sess.session_find("window-buffer-render") != null) sess.session_destroy(setup.session, false, "test");

    paste_mod.paste_add(null, xm.xstrdup("older"));
    paste_mod.paste_add(null, xm.xstrdup("newer"));

    var cause: ?[]u8 = null;
    var args = try args_mod.args_parse(xm.allocator, &.{}, "F:f:NO:rt:yZ", 0, 1, &cause);
    defer args.deinit();

    var fs = T.CmdFindState{
        .s = setup.session,
        .wl = setup.session.curw,
        .w = setup.session.curw.?.window,
        .wp = setup.pane,
        .idx = setup.session.curw.?.idx,
    };

    const wme = enterMode(setup.pane, &fs, &args);
    defer {
        if (window.window_pane_mode(setup.pane) != null)
            _ = window_mode_runtime.resetMode(setup.pane);
    }

    const data = modeData(wme);
    try std.testing.expectEqual(@as(usize, 2), data.items.items.len);
    try std.testing.expectEqualStrings("buffer0", data.items.items[0].name);

    _ = mode_tree.down(data.tree, false);
    const current_name = mode_tree.getCurrentName(data.tree) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("buffer1", current_name);

    mode_tree.build(data.tree);
    try std.testing.expectEqualStrings("buffer1", mode_tree.getCurrentName(data.tree).?);
}

test "window-buffer choose runs the tmux template command for the selected buffer" {
    const cmdq_mod = @import("cmd-queue.zig");
    const env_mod = @import("environ.zig");
    const sess = @import("session.zig");

    initTestGlobals();
    defer deinitTestGlobals();

    const setup = try testSetup("window-buffer-choose");
    defer if (sess.session_find("window-buffer-choose") != null) sess.session_destroy(setup.session, false, "test");

    paste_mod.paste_add(null, xm.xstrdup("older"));
    paste_mod.paste_add(null, xm.xstrdup("newer"));

    var chooser = makeClient(setup.session, "chooser", "/dev/pts/410");
    defer freeClient(&chooser);

    var cause: ?[]u8 = null;
    var mode_args = try args_mod.args_parse(
        xm.allocator,
        &.{"set-environment -g CHOSEN_BUFFER '%%'"},
        "F:f:NO:rt:yZ",
        0,
        1,
        &cause,
    );
    defer mode_args.deinit();

    var fs = T.CmdFindState{
        .s = setup.session,
        .wl = setup.session.curw,
        .w = setup.session.curw.?.window,
        .wp = setup.pane,
        .idx = setup.session.curw.?.idx,
    };

    const wme = enterMode(setup.pane, &fs, &mode_args);
    _ = mode_tree.down(modeData(wme).tree, false);

    cause = null;
    var command_args = try args_mod.args_parse(xm.allocator, &.{"choose"}, "", 0, -1, &cause);
    defer command_args.deinit();
    windowBufferCommand(wme, &chooser, setup.session, setup.session.curw.?, @ptrCast(&command_args), null);
    while (cmdq_mod.cmdq_next(&chooser) != 0) {}

    try std.testing.expectEqualStrings("buffer1", env_mod.environ_find(env_mod.global_environ, "CHOSEN_BUFFER").?.value.?);
    try std.testing.expect(window.window_pane_mode(setup.pane) == null);
}

test "window-buffer delete removes the selected buffer and keeps selection stable" {
    const sess = @import("session.zig");

    initTestGlobals();
    defer deinitTestGlobals();

    const setup = try testSetup("window-buffer-delete");
    defer if (sess.session_find("window-buffer-delete") != null) sess.session_destroy(setup.session, false, "test");

    paste_mod.paste_add(null, xm.xstrdup("older"));
    paste_mod.paste_add(null, xm.xstrdup("newer"));
    paste_mod.paste_add(null, xm.xstrdup("newest"));

    var cause: ?[]u8 = null;
    var mode_args = try args_mod.args_parse(xm.allocator, &.{}, "F:f:NO:rt:yZ", 0, 1, &cause);
    defer mode_args.deinit();

    var fs = T.CmdFindState{
        .s = setup.session,
        .wl = setup.session.curw,
        .w = setup.session.curw.?.window,
        .wp = setup.pane,
        .idx = setup.session.curw.?.idx,
    };

    const wme = enterMode(setup.pane, &fs, &mode_args);

    _ = mode_tree.down(modeData(wme).tree, false);
    try std.testing.expectEqualStrings("buffer1", mode_tree.getCurrentName(modeData(wme).tree).?);

    cause = null;
    var delete_args = try args_mod.args_parse(xm.allocator, &.{"delete"}, "", 0, -1, &cause);
    defer delete_args.deinit();

    windowBufferCommand(wme, null, setup.session, setup.session.curw.?, @ptrCast(&delete_args), null);
    try std.testing.expect(paste_mod.paste_get_name("buffer1") == null);
    try std.testing.expectEqualStrings("buffer2", mode_tree.getCurrentName(modeData(wme).tree).?);

    windowBufferCommand(wme, null, setup.session, setup.session.curw.?, @ptrCast(&delete_args), null);
    try std.testing.expect(paste_mod.paste_get_name("buffer2") == null);
    try std.testing.expectEqualStrings("buffer0", mode_tree.getCurrentName(modeData(wme).tree).?);

    windowBufferCommand(wme, null, setup.session, setup.session.curw.?, @ptrCast(&delete_args), null);
    try std.testing.expect(paste_mod.paste_is_empty());
    try std.testing.expect(window.window_pane_mode(setup.pane) == null);
}

test "window-buffer delete-tagged removes tagged buffers and keeps the untagged selection" {
    const sess = @import("session.zig");

    initTestGlobals();
    defer deinitTestGlobals();

    const setup = try testSetup("window-buffer-delete-tagged");
    defer if (sess.session_find("window-buffer-delete-tagged") != null) sess.session_destroy(setup.session, false, "test");

    paste_mod.paste_add(null, xm.xstrdup("older"));
    paste_mod.paste_add(null, xm.xstrdup("middle"));
    paste_mod.paste_add(null, xm.xstrdup("newest"));

    var cause: ?[]u8 = null;
    var mode_args = try args_mod.args_parse(xm.allocator, &.{}, "F:f:NO:rt:yZ", 0, 1, &cause);
    defer mode_args.deinit();

    var fs = T.CmdFindState{
        .s = setup.session,
        .wl = setup.session.curw,
        .w = setup.session.curw.?.window,
        .wp = setup.pane,
        .idx = setup.session.curw.?.idx,
    };

    const wme = enterMode(setup.pane, &fs, &mode_args);
    defer {
        if (window.window_pane_mode(setup.pane) != null)
            _ = window_mode_runtime.resetMode(setup.pane);
    }

    cause = null;
    var tag_args = try args_mod.args_parse(xm.allocator, &.{"tag"}, "", 0, -1, &cause);
    defer tag_args.deinit();
    cause = null;
    var delete_tagged_args = try args_mod.args_parse(xm.allocator, &.{"delete-tagged"}, "", 0, -1, &cause);
    defer delete_tagged_args.deinit();

    windowBufferCommand(wme, null, setup.session, setup.session.curw.?, @ptrCast(&tag_args), null);
    _ = mode_tree.down(modeData(wme).tree, false);
    _ = mode_tree.down(modeData(wme).tree, false);
    windowBufferCommand(wme, null, setup.session, setup.session.curw.?, @ptrCast(&tag_args), null);

    windowBufferCommand(wme, null, setup.session, setup.session.curw.?, @ptrCast(&delete_tagged_args), null);

    try std.testing.expect(paste_mod.paste_get_name("buffer0") == null);
    try std.testing.expect(paste_mod.paste_get_name("buffer2") == null);
    try std.testing.expect(paste_mod.paste_get_name("buffer1") != null);
    try std.testing.expectEqual(@as(usize, 1), modeData(wme).items.items.len);
    try std.testing.expectEqualStrings("buffer1", mode_tree.getCurrentName(modeData(wme).tree).?);
}

test "window-buffer paste-tagged runs the command for every tagged buffer and exits mode" {
    const env_mod = @import("environ.zig");
    const sess = @import("session.zig");

    initTestGlobals();
    defer deinitTestGlobals();

    const setup = try testSetup("window-buffer-paste-tagged");
    defer if (sess.session_find("window-buffer-paste-tagged") != null) sess.session_destroy(setup.session, false, "test");

    paste_mod.paste_add(null, xm.xstrdup("older"));
    paste_mod.paste_add(null, xm.xstrdup("middle"));
    paste_mod.paste_add(null, xm.xstrdup("newest"));

    var chooser = makeClient(setup.session, "chooser", "/dev/pts/413");
    defer freeClient(&chooser);

    var cause: ?[]u8 = null;
    var mode_args = try args_mod.args_parse(
        xm.allocator,
        &.{"set-environment -g HIT_%% yes"},
        "F:f:NO:rt:yZ",
        0,
        1,
        &cause,
    );
    defer mode_args.deinit();

    var fs = T.CmdFindState{
        .s = setup.session,
        .wl = setup.session.curw,
        .w = setup.session.curw.?.window,
        .wp = setup.pane,
        .idx = setup.session.curw.?.idx,
    };

    const wme = enterMode(setup.pane, &fs, &mode_args);

    cause = null;
    var tag_args = try args_mod.args_parse(xm.allocator, &.{"tag"}, "", 0, -1, &cause);
    defer tag_args.deinit();
    cause = null;
    var paste_tagged_args = try args_mod.args_parse(xm.allocator, &.{"paste-tagged"}, "", 0, -1, &cause);
    defer paste_tagged_args.deinit();

    windowBufferCommand(wme, null, setup.session, setup.session.curw.?, @ptrCast(&tag_args), null);
    _ = mode_tree.down(modeData(wme).tree, false);
    _ = mode_tree.down(modeData(wme).tree, false);
    windowBufferCommand(wme, null, setup.session, setup.session.curw.?, @ptrCast(&tag_args), null);

    windowBufferCommand(wme, &chooser, setup.session, setup.session.curw.?, @ptrCast(&paste_tagged_args), null);

    while (cmdq.cmdq_next(&chooser) != 0) {}

    try std.testing.expect(env_mod.environ_find(env_mod.global_environ, "HIT_buffer0") != null);
    try std.testing.expect(env_mod.environ_find(env_mod.global_environ, "HIT_buffer2") != null);
    try std.testing.expect(env_mod.environ_find(env_mod.global_environ, "HIT_buffer1") == null);
    try std.testing.expect(window.window_pane_mode(setup.pane) == null);
}

test "window-buffer edit-selected updates the selected buffer and rebuilds the mode tree on save" {
    const sess = @import("session.zig");

    initTestGlobals();
    defer deinitTestGlobals();

    const setup = try testSetup("window-buffer-edit");
    defer if (sess.session_find("window-buffer-edit") != null) sess.session_destroy(setup.session, false, "test");

    paste_mod.paste_add(null, xm.xstrdup("seed"));

    var chooser = makeClient(setup.session, "editor", "/dev/pts/411");
    defer freeClient(&chooser);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmpdir = try tmp.dir.realpathAlloc(xm.allocator, ".");
    defer xm.allocator.free(tmpdir);

    editor_handoff.test_editor_override = "/bin/sh";
    editor_handoff.test_tmpdir_override = tmpdir;

    const capture = struct {
        var command: ?[]u8 = null;

        fn dispatch(_: *T.Client, cmd: []const u8) void {
            if (command) |old| xm.allocator.free(old);
            command = xm.xstrdup(cmd);
        }
    };
    defer {
        if (capture.command) |cmd| xm.allocator.free(cmd);
        edit_dispatch_hook = null;
    }
    edit_dispatch_hook = capture.dispatch;

    var cause: ?[]u8 = null;
    var mode_args = try args_mod.args_parse(xm.allocator, &.{}, "F:f:NO:rt:yZ", 0, 1, &cause);
    defer mode_args.deinit();

    var fs = T.CmdFindState{
        .s = setup.session,
        .wl = setup.session.curw,
        .w = setup.session.curw.?.window,
        .wp = setup.pane,
        .idx = setup.session.curw.?.idx,
    };

    const wme = enterMode(setup.pane, &fs, &mode_args);
    defer {
        if (window.window_pane_mode(setup.pane) != null)
            _ = window_mode_runtime.resetMode(setup.pane);
    }

    cause = null;
    var command_args = try args_mod.args_parse(xm.allocator, &.{"edit-selected"}, "", 0, -1, &cause);
    defer command_args.deinit();
    windowBufferCommand(wme, &chooser, setup.session, setup.session.curw.?, @ptrCast(&command_args), null);

    const command = capture.command orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.startsWith(u8, command, "/bin/sh "));
    const edited = try std.fs.createFileAbsolute(command["/bin/sh ".len..], .{ .truncate = true });
    defer edited.close();
    try edited.writeAll("edited\n");

    editor_handoff.handleUnlock(&chooser, 0);

    const pb = paste_mod.paste_get_name("buffer0") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("edited", paste_mod.paste_buffer_data(pb, null));
    try std.testing.expectEqualStrings("buffer0", mode_tree.getCurrentName(modeData(wme).tree).?);

    const first_item = modeData(wme).items.items[0];
    try std.testing.expect(std.mem.indexOf(u8, first_item.text, "edited") != null);
}

test "window-buffer filter command updates the live mode filter through the shared prompt" {
    const sess = @import("session.zig");

    initTestGlobals();
    defer deinitTestGlobals();

    const setup = try testSetup("window-buffer-filter");
    defer if (sess.session_find("window-buffer-filter") != null) sess.session_destroy(setup.session, false, "test");

    paste_mod.paste_add(null, xm.xstrdup("older"));
    paste_mod.paste_add(null, xm.xstrdup("needle buffer"));

    var chooser = makeClient(setup.session, "filterer", "/dev/pts/412");
    defer freeClient(&chooser);

    var cause: ?[]u8 = null;
    var mode_args = try args_mod.args_parse(xm.allocator, &.{}, "F:f:NO:rt:yZ", 0, 1, &cause);
    defer mode_args.deinit();

    var fs = T.CmdFindState{
        .s = setup.session,
        .wl = setup.session.curw,
        .w = setup.session.curw.?.window,
        .wp = setup.pane,
        .idx = setup.session.curw.?.idx,
    };

    const wme = enterMode(setup.pane, &fs, &mode_args);
    defer {
        status_prompt.status_prompt_clear(&chooser);
        if (window.window_pane_mode(setup.pane) != null)
            _ = window_mode_runtime.resetMode(setup.pane);
    }

    cause = null;
    var command_args = try args_mod.args_parse(xm.allocator, &.{"filter"}, "", 0, -1, &cause);
    defer command_args.deinit();
    windowBufferCommand(wme, &chooser, setup.session, setup.session.curw.?, @ptrCast(&command_args), null);

    try std.testing.expectEqualStrings("(filter) ", status_prompt.status_prompt_message(&chooser).?);
    const filter_expr = "#{==:buffer_name,buffer1}";
    for (filter_expr) |ch| {
        const bytes = [_]u8{ch};
        try std.testing.expect(sendPromptKey(&chooser, ch, &bytes));
    }
    try std.testing.expect(sendPromptKey(&chooser, T.C0_CR, "\r"));

    const data = modeData(wme);
    try std.testing.expectEqualStrings(filter_expr, data.filter.?);
    try std.testing.expectEqual(@as(usize, 1), data.items.items.len);
    try std.testing.expectEqualStrings("buffer1", mode_tree.getCurrentName(data.tree).?);
    try std.testing.expect(status_prompt.status_prompt_input(&chooser) == null);
}
