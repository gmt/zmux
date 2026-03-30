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
// Ported in part from tmux/window-customize.c.
// Original copyright:
//   Copyright (c) 2020 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence - same terms as above.

const std = @import("std");
const args_mod = @import("arguments.zig");
const cmd_options = @import("cmd-options.zig");
const format_mod = @import("format.zig");
const mode_tree = @import("mode-tree.zig");
const options_table = @import("options-table.zig");
const opts = @import("options.zig");
const screen = @import("screen.zig");
const screen_write = @import("screen-write.zig");
const status_prompt = @import("status-prompt.zig");
const status_runtime = @import("status-runtime.zig");
const T = @import("types.zig");
const window = @import("window.zig");
const window_mode_runtime = @import("window-mode-runtime.zig");
const xm = @import("xmalloc.zig");

const DEFAULT_FORMAT = "#{option_name}: #{option_value}#{?option_unit, #{option_unit},}#{?option_inherited, [inherited],}";
const HELP_TEXT = "Arrows move  left/right fold  Enter edit  u unset  d reset  H hide inherited  q cancel";

const ScopeKind = enum(u8) {
    server = 0,
    session = 1,
    window = 2,
    pane = 3,
};

const OptionItem = struct {
    target: cmd_options.ResolvedTarget,
    name: []u8,
    idx: ?u32,
};

const PromptAction = enum(u8) {
    edit,
    unset,
    reset,
};

const OptionPromptState = struct {
    pane_id: u32,
    target: cmd_options.ResolvedTarget,
    name: []u8,
    idx: ?u32,
    action: PromptAction,
};

const CustomizeModeData = struct {
    fs: T.CmdFindState,
    tree: *mode_tree.Data,
    items: std.ArrayList(*OptionItem) = .{},
    format: []u8,
    filter: ?[]u8 = null,
    hide_inherited: bool = false,
};

pub const window_customize_mode = T.WindowMode{
    .name = "options-mode",
    .key = windowCustomizeKey,
    .key_table = windowCustomizeKeyTable,
    .command = windowCustomizeCommand,
    .close = windowCustomizeClose,
    .get_screen = windowCustomizeGetScreen,
};

pub fn enterMode(
    wp: *T.WindowPane,
    fs: *const T.CmdFindState,
    args: *const args_mod.Arguments,
) *T.WindowModeEntry {
    if (window.window_pane_mode(wp)) |wme| {
        if (wme.mode == &window_customize_mode) {
            refreshFromArgs(wme, fs, args);
            rebuildAndDraw(wme);
            return wme;
        }
    }

    screen.screen_enter_alternate(wp, true);

    const data = xm.allocator.create(CustomizeModeData) catch unreachable;
    data.* = .{
        .fs = fs.*,
        .tree = undefined,
        .format = xm.xstrdup(args.get('F') orelse DEFAULT_FORMAT),
        .filter = if (args.get('f')) |filter| xm.xstrdup(filter) else null,
    };

    data.tree = mode_tree.start(wp, .{
        .modedata = @ptrCast(data),
        .preview = .off,
        .zoom = args.has('Z'),
        .buildcb = buildTree,
    });

    const wme = window_mode_runtime.pushMode(wp, &window_customize_mode, @ptrCast(data), null);
    wme.prefix = 1;
    rebuildAndDraw(wme);
    return wme;
}

fn windowCustomizeKeyTable(wme: *T.WindowModeEntry) []const u8 {
    if (opts.options_get_number(wme.wp.window.options, "mode-keys") == T.MODEKEY_VI)
        return "options-mode-vi";
    return "options-mode";
}

fn windowCustomizeCommand(
    wme: *T.WindowModeEntry,
    client: ?*T.Client,
    _session: *T.Session,
    _wl: *T.Winlink,
    raw_args: *const anyopaque,
    mouse: ?*const T.MouseEvent,
) void {
    _ = _session;
    _ = _wl;
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
    if (std.mem.eql(u8, command, "choose")) {
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
        pageUp(data.tree, viewRows(data.tree), repeat);
        redraw(wme);
        return;
    }
    if (std.mem.eql(u8, command, "page-down")) {
        pageDown(data.tree, viewRows(data.tree), repeat);
        redraw(wme);
        return;
    }
    if (std.mem.eql(u8, command, "expand")) {
        mode_tree.expandCurrent(data.tree);
        redraw(wme);
        return;
    }
    if (std.mem.eql(u8, command, "collapse")) {
        mode_tree.collapseCurrent(data.tree);
        redraw(wme);
        return;
    }
    if (std.mem.eql(u8, command, "toggle-hide-inherited")) {
        data.hide_inherited = !data.hide_inherited;
        rebuildAndDraw(wme);
        return;
    }
    if (std.mem.eql(u8, command, "unset-current")) {
        const item = currentOptionItem(data) orelse return;
        promptForCurrentItem(client orelse return, wme.wp, item, .unset);
        return;
    }
    if (std.mem.eql(u8, command, "reset-current")) {
        const item = currentOptionItem(data) orelse return;
        promptForCurrentItem(client orelse return, wme.wp, item, .reset);
        return;
    }

    unsupportedCommand(client, command);
    redraw(wme);
}

fn windowCustomizeKey(
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

fn windowCustomizeClose(wme: *T.WindowModeEntry) void {
    const data = modeData(wme);
    mode_tree.free(data.tree);
    freeItems(data);
    data.items.deinit(xm.allocator);
    xm.allocator.free(data.format);
    if (data.filter) |filter| xm.allocator.free(filter);
    xm.allocator.destroy(data);

    if (wme.wp.modes.items.len <= 1) {
        screen.screen_leave_alternate(wme.wp, true);
    }
}

fn windowCustomizeGetScreen(wme: *T.WindowModeEntry) *T.Screen {
    return modeData(wme).tree.getScreen();
}

fn modeData(wme: *T.WindowModeEntry) *CustomizeModeData {
    return @ptrCast(@alignCast(wme.data.?));
}

fn refreshFromArgs(wme: *T.WindowModeEntry, fs: *const T.CmdFindState, args: *const args_mod.Arguments) void {
    const data = modeData(wme);
    data.fs = fs.*;

    xm.allocator.free(data.format);
    data.format = xm.xstrdup(args.get('F') orelse DEFAULT_FORMAT);

    if (data.filter) |filter| xm.allocator.free(filter);
    data.filter = if (args.get('f')) |filter| xm.xstrdup(filter) else null;
}

fn rebuildAndDraw(wme: *T.WindowModeEntry) void {
    mode_tree.build(modeData(wme).tree);
    redraw(wme);
}

fn redraw(wme: *T.WindowModeEntry) void {
    const data = modeData(wme);
    const tree = data.tree;
    const view = tree.getScreen();
    const rows = view.grid.sy;
    const body_rows = viewRows(tree);

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
        screen_write.putn(&ctx, if (data.filter != null) "No matching options." else "No options.");
    }

    window_mode_runtime.noteModeRedraw(wme.wp);
}

fn buildTree(tree: *mode_tree.Data) void {
    const data: *CustomizeModeData = @ptrCast(@alignCast(tree.modedata.?));
    freeItems(data);

    buildScope(data, tree, .server, "Server Options", opts.global_options);
    if (data.fs.s) |session_ptr| buildScope(data, tree, .session, "Session Options", session_ptr.options);
    if (data.fs.w) |window_ptr| buildScope(data, tree, .window, "Window Options", window_ptr.options);
    if (data.fs.wp) |pane_ptr| buildScope(data, tree, .pane, "Pane Options", pane_ptr.options);
}

fn buildScope(
    data: *CustomizeModeData,
    tree: *mode_tree.Data,
    scope_kind: ScopeKind,
    title: []const u8,
    oo: *T.Options,
) void {
    const section = mode_tree.add(tree, null, null, sectionTag(scope_kind), title, null, 1);
    mode_tree.noTag(section);

    const scope_label = buildScopeLabel(scope_kind, &data.fs);
    defer xm.allocator.free(scope_label);

    for (options_table.options_table) |*oe| {
        if (oe.is_hook) continue;
        if (!scopeHasOption(scope_kind, oe)) continue;
        appendOption(data, tree, section, scope_kind, oo, oe.name, oe, scope_label);
    }

    const custom_names = collectCustomNames(oo);
    defer freeOwnedNames(custom_names);
    for (custom_names) |name| appendOption(data, tree, section, scope_kind, oo, name, null, scope_label);

    if (section.children.items.len == 0) mode_tree.remove(tree, section);
}

fn appendOption(
    data: *CustomizeModeData,
    tree: *mode_tree.Data,
    parent: *mode_tree.Item,
    scope_kind: ScopeKind,
    oo: *T.Options,
    base_name: []const u8,
    oe: ?*const T.OptionsTableEntry,
    scope_label: []const u8,
) void {
    const target = targetForScope(scope_kind, &data.fs, oo);
    const local_value = opts.options_get_only(oo, base_name);
    const value = local_value orelse opts.options_get(oo, base_name) orelse return;
    const inherited = local_value == null and oo.parent != null;

    if (data.hide_inherited and inherited) return;

    switch (value.*) {
        .array => |arr| {
            if (arr.items.len == 0) {
                appendRenderedOption(data, tree, parent, scope_kind, target, base_name, null, "", oe, scope_label, inherited);
                return;
            }
            for (arr.items) |item| {
                const indexed_name = xm.xasprintf("{s}[{d}]", .{ base_name, item.index });
                defer xm.allocator.free(indexed_name);
                appendRenderedOption(data, tree, parent, scope_kind, target, indexed_name, item.index, item.value, oe, scope_label, inherited);
            }
        },
        else => {
            const value_text = opts.options_value_to_string(base_name, value, oe);
            defer xm.allocator.free(value_text);
            appendRenderedOption(data, tree, parent, scope_kind, target, base_name, null, value_text, oe, scope_label, inherited);
        },
    }
}

fn appendRenderedOption(
    data: *CustomizeModeData,
    tree: *mode_tree.Data,
    parent: *mode_tree.Item,
    scope_kind: ScopeKind,
    target: cmd_options.ResolvedTarget,
    display_name: []const u8,
    idx: ?u32,
    display_value: []const u8,
    oe: ?*const T.OptionsTableEntry,
    scope_label: []const u8,
    inherited: bool,
) void {
    const unit = if (oe) |entry| entry.unit orelse "" else "";
    const ctx = optionFormatContext(&data.fs, display_name, display_value, scope_label, unit, inherited, scope_kind == .server);

    if (data.filter) |filter| {
        const matches = format_mod.format_filter_match(xm.allocator, filter, &ctx) orelse false;
        if (!matches) return;
    }

    const rendered = format_mod.format_require_complete(xm.allocator, data.format, &ctx) orelse
        fallbackText(display_name, display_value, unit, inherited);
    defer xm.allocator.free(rendered);

    const item = xm.allocator.create(OptionItem) catch unreachable;
    item.* = .{
        .target = target,
        .name = xm.xstrdup(optionBaseName(display_name, idx)),
        .idx = idx,
    };
    data.items.append(xm.allocator, item) catch unreachable;

    _ = mode_tree.add(
        tree,
        parent,
        @ptrCast(item),
        optionTag(scope_kind, display_name),
        display_name,
        rendered,
        0,
    );
}

fn optionFormatContext(
    fs: *const T.CmdFindState,
    display_name: []const u8,
    display_value: []const u8,
    scope_label: []const u8,
    unit: []const u8,
    inherited: bool,
    is_global: bool,
) format_mod.FormatContext {
    return .{
        .session = fs.s,
        .winlink = fs.wl,
        .window = fs.w,
        .pane = fs.wp,
        .is_option = true,
        .is_key = false,
        .option_name = display_name,
        .option_value = display_value,
        .option_scope = scope_label,
        .option_unit = unit,
        .option_is_global = is_global,
        .option_inherited = inherited,
    };
}

fn fallbackText(
    display_name: []const u8,
    display_value: []const u8,
    unit: []const u8,
    inherited: bool,
) []u8 {
    var out: std.ArrayList(u8) = .{};
    defer out.deinit(xm.allocator);

    out.appendSlice(xm.allocator, display_name) catch unreachable;
    if (display_value.len != 0 or unit.len != 0) {
        out.appendSlice(xm.allocator, ": ") catch unreachable;
        if (display_value.len != 0) out.appendSlice(xm.allocator, display_value) catch unreachable;
        if (unit.len != 0) {
            if (display_value.len != 0) out.append(xm.allocator, ' ') catch unreachable;
            out.appendSlice(xm.allocator, unit) catch unreachable;
        }
    }
    if (inherited) out.appendSlice(xm.allocator, " [inherited]") catch unreachable;
    return out.toOwnedSlice(xm.allocator) catch unreachable;
}

fn scopeHasOption(scope_kind: ScopeKind, oe: *const T.OptionsTableEntry) bool {
    return switch (scope_kind) {
        .server => oe.scope.server,
        .session => oe.scope.session,
        .window => oe.scope.window,
        .pane => oe.scope.pane,
    };
}

fn buildScopeLabel(scope_kind: ScopeKind, fs: *const T.CmdFindState) []u8 {
    return switch (scope_kind) {
        .server => xm.xstrdup("server"),
        .session => xm.xasprintf("session {s}", .{if (fs.s) |session_ptr| session_ptr.name else ""}),
        .window => xm.xasprintf("window {d}", .{if (fs.wl) |wl| wl.idx else 0}),
        .pane => xm.xasprintf("pane {d}", .{paneIndex(fs)}),
    };
}

fn paneIndex(fs: *const T.CmdFindState) usize {
    const pane = fs.wp orelse return 0;
    const w = fs.w orelse pane.window;
    return window.window_pane_index(w, pane) orelse 0;
}

fn collectCustomNames(oo: *T.Options) [][]u8 {
    var names: std.ArrayList([]u8) = .{};

    var current: ?*T.Options = oo;
    while (current) |scope_options| : (current = scope_options.parent) {
        var it = scope_options.entries.keyIterator();
        while (it.next()) |name| {
            if (name.*.len == 0 or name.*[0] != '@') continue;
            if (containsName(names.items, name.*)) continue;
            names.append(xm.allocator, xm.xstrdup(name.*)) catch unreachable;
        }
    }

    std.sort.block([]u8, names.items, {}, lessThanString);
    return names.toOwnedSlice(xm.allocator) catch unreachable;
}

fn containsName(names: []const []u8, target: []const u8) bool {
    for (names) |name| {
        if (std.mem.eql(u8, name, target)) return true;
    }
    return false;
}

fn lessThanString(_: void, lhs: []u8, rhs: []u8) bool {
    return std.mem.order(u8, lhs, rhs) == .lt;
}

fn freeOwnedNames(names: [][]u8) void {
    for (names) |name| xm.allocator.free(name);
    xm.allocator.free(names);
}

fn renderLine(tree: *const mode_tree.Data, index: usize) []u8 {
    const line = tree.line_list.items[index];
    const current = if (index == tree.current) ">" else " ";
    const expanded = if (line.item.children.items.len == 0)
        " "
    else if (line.item.expanded)
        "-"
    else
        "+";
    const text = line.item.text orelse line.item.name;

    var out: std.ArrayList(u8) = .{};
    defer out.deinit(xm.allocator);

    out.appendSlice(xm.allocator, current) catch unreachable;
    out.appendSlice(xm.allocator, "  ") catch unreachable;
    var depth: u32 = 0;
    while (depth < line.depth) : (depth += 1) {
        out.appendSlice(xm.allocator, "  ") catch unreachable;
    }
    out.appendSlice(xm.allocator, expanded) catch unreachable;
    out.appendSlice(xm.allocator, " ") catch unreachable;
    out.appendSlice(xm.allocator, text) catch unreachable;

    return out.toOwnedSlice(xm.allocator) catch unreachable;
}

fn chooseCurrent(wme: *T.WindowModeEntry, client: ?*T.Client) void {
    const data = modeData(wme);
    if (data.tree.line_list.items.len == 0) return;

    const current = data.tree.line_list.items[data.tree.current].item;
    if (current.itemdata == null) {
        if (current.children.items.len != 0) {
            if (current.expanded)
                mode_tree.collapseCurrent(data.tree)
            else
                mode_tree.expandCurrent(data.tree);
            redraw(wme);
        }
        return;
    }

    const item = currentOptionItem(data) orelse return;
    editCurrentItem(wme, client, item);
}

fn currentOptionItem(data: *CustomizeModeData) ?*OptionItem {
    const current = mode_tree.getCurrent(data.tree) orelse return null;
    return @ptrCast(@alignCast(current));
}

fn editCurrentItem(wme: *T.WindowModeEntry, client: ?*T.Client, item: *OptionItem) void {
    const cl = client orelse return;
    const oe = opts.options_table_entry(item.name);

    if (oe) |entry| {
        switch (entry.type) {
            .flag => {
                const flag = opts.options_get_number(item.target.options, item.name);
                opts.options_set_number(item.target.options, item.name, if (flag == 0) 1 else 0);
                cmd_options.apply_target_side_effects(item.target, item.name);
                rebuildAndDraw(wme);
                return;
            },
            .choice => {
                const next = nextChoiceValue(item.target.options, item.name, entry);
                opts.options_set_number(item.target.options, item.name, next);
                cmd_options.apply_target_side_effects(item.target, item.name);
                rebuildAndDraw(wme);
                return;
            },
            else => {},
        }
    }

    promptForCurrentItem(cl, wme.wp, item, .edit);
}

fn promptForCurrentItem(client: *T.Client, pane: *T.WindowPane, item: *const OptionItem, action: PromptAction) void {
    const prompt = switch (action) {
        .edit => buildEditPrompt(item),
        .unset => buildUnsetPrompt(item),
        .reset => buildResetPrompt(item),
    } orelse return;
    defer xm.allocator.free(prompt);

    const input = switch (action) {
        .edit => currentEditValue(item),
        .unset, .reset => xm.xstrdup(""),
    };
    defer xm.allocator.free(input);

    const state = createPromptState(pane, item, action);
    const flags: u32 = if (action == .edit)
        status_prompt.PROMPT_NOFORMAT
    else
        status_prompt.PROMPT_SINGLE | status_prompt.PROMPT_NOFORMAT;
    status_prompt.status_prompt_set(
        client,
        null,
        prompt,
        input,
        optionPromptCallback,
        null,
        freePromptState,
        state,
        flags,
        .command,
    );
}

fn buildEditPrompt(item: *const OptionItem) ?[]u8 {
    const scope_text = scopeText(item.target);
    defer xm.allocator.free(scope_text);

    const scope_sep = if (scope_text.len != 0) ", for " else "";
    if (item.idx) |idx|
        return xm.xasprintf("({s}[{d}]{s}{s}) ", .{ item.name, idx, scope_sep, scope_text });

    if (isArrayOption(item.name))
        return xm.xasprintf("({s}[+]{s}{s}) ", .{ item.name, scope_sep, scope_text });

    return xm.xasprintf("({s}{s}{s}) ", .{ item.name, scope_sep, scope_text });
}

fn buildUnsetPrompt(item: *const OptionItem) ?[]u8 {
    if (item.idx) |idx|
        return xm.xasprintf("Unset {s}[{d}]? ", .{ item.name, idx });
    return xm.xasprintf("Unset {s}? ", .{item.name});
}

fn buildResetPrompt(item: *const OptionItem) ?[]u8 {
    if (item.idx != null) return null;
    return xm.xasprintf("Reset {s} to default? ", .{item.name});
}

fn currentEditValue(item: *const OptionItem) []u8 {
    const value = opts.options_get(item.target.options, item.name) orelse return xm.xstrdup("");
    if (item.idx) |idx| {
        const entry = opts.options_array_get_value(value, idx) orelse return xm.xstrdup("");
        return xm.xstrdup(entry);
    }
    return opts.options_value_to_string(item.name, value, opts.options_table_entry(item.name));
}

fn createPromptState(pane: *T.WindowPane, item: *const OptionItem, action: PromptAction) *OptionPromptState {
    const state = xm.allocator.create(OptionPromptState) catch unreachable;
    state.* = .{
        .pane_id = pane.id,
        .target = item.target,
        .name = xm.xstrdup(item.name),
        .idx = item.idx,
        .action = action,
    };
    return state;
}

fn freePromptState(data: ?*anyopaque) void {
    const state: *OptionPromptState = @ptrCast(@alignCast(data orelse return));
    xm.allocator.free(state.name);
    xm.allocator.destroy(state);
}

fn optionPromptCallback(client: *T.Client, data: ?*anyopaque, input: ?[]const u8, _: bool) i32 {
    const state: *OptionPromptState = @ptrCast(@alignCast(data orelse return 0));
    const text = input orelse return 0;

    switch (state.action) {
        .edit => {
            if (text.len == 0) return 0;
            applyEdit(state, client, text);
        },
        .unset => {
            if (confirmed(text))
                applyUnset(state, client);
        },
        .reset => {
            if (confirmed(text))
                applyReset(state, client);
        },
    }
    return 0;
}

fn confirmed(text: []const u8) bool {
    return text.len == 1 and std.ascii.toLower(text[0]) == 'y';
}

fn applyEdit(state: *OptionPromptState, client: *T.Client, text: []const u8) void {
    const oe = opts.options_table_entry(state.name);
    var idx = state.idx;
    if (oe) |entry| {
        if (entry.type == .array and idx == null)
            idx = nextArrayIndex(state.target.options, state.name);
    }

    var cause: ?[]u8 = null;
    defer if (cause) |msg| xm.allocator.free(msg);
    if (!opts.options_set_from_string(state.target.options, oe, state.name, idx, text, false, &cause)) {
        if (cause) |msg| {
            uppercaseFirst(msg);
            status_runtime.present_client_message(client, msg);
        }
        return;
    }

    cmd_options.apply_target_side_effects(state.target, state.name);
    rebuildIfStillActive(state.pane_id);
}

fn applyUnset(state: *OptionPromptState, client: *T.Client) void {
    const oe = opts.options_table_entry(state.name);
    var cause: ?[]u8 = null;
    defer if (cause) |msg| xm.allocator.free(msg);
    if (!opts.options_remove_or_default(state.target.options, oe, state.name, state.idx, state.target.global, &cause)) {
        if (cause) |msg| {
            uppercaseFirst(msg);
            status_runtime.present_client_message(client, msg);
        }
        return;
    }

    cmd_options.apply_target_side_effects(state.target, state.name);
    rebuildIfStillActive(state.pane_id);
}

fn applyReset(state: *OptionPromptState, client: *T.Client) void {
    if (state.idx != null) return;

    const oe = opts.options_table_entry(state.name);
    var current: ?*T.Options = state.target.options;
    var cause: ?[]u8 = null;
    defer if (cause) |msg| xm.allocator.free(msg);

    while (current) |options_ptr| : (current = options_ptr.parent) {
        if (opts.options_get_only(options_ptr, state.name) == null) continue;
        const global = isGlobalOptions(options_ptr);
        if (!opts.options_remove_or_default(options_ptr, oe, state.name, null, global, &cause)) {
            if (cause) |msg| {
                uppercaseFirst(msg);
                status_runtime.present_client_message(client, msg);
            }
            return;
        }
    }

    cmd_options.apply_target_side_effects(state.target, state.name);
    rebuildIfStillActive(state.pane_id);
}

fn rebuildIfStillActive(pane_id: u32) void {
    const pane = window.window_pane_find_by_id(pane_id) orelse return;
    const wme = window.window_pane_mode(pane) orelse return;
    if (wme.mode != &window_customize_mode) return;
    rebuildAndDraw(wme);
}

fn nextChoiceValue(oo: *T.Options, name: []const u8, oe: *const T.OptionsTableEntry) i64 {
    const choices = oe.choices orelse return 0;
    if (choices.len == 0) return 0;

    var choice = opts.options_get_number(oo, name);
    choice += 1;
    if (choice >= @as(i64, @intCast(choices.len)))
        choice = 0;
    return choice;
}

fn nextArrayIndex(oo: *T.Options, name: []const u8) ?u32 {
    const value = opts.options_get(oo, name) orelse return 0;
    return switch (value.*) {
        .array => |arr| blk: {
            var next: u32 = 0;
            for (arr.items) |item| {
                if (item.index == next) {
                    next += 1;
                    continue;
                }
                if (item.index > next) break;
            }
            break :blk next;
        },
        else => null,
    };
}

fn uppercaseFirst(text: []u8) void {
    if (text.len == 0) return;
    text[0] = std.ascii.toUpper(text[0]);
}

fn isArrayOption(name: []const u8) bool {
    const oe = opts.options_table_entry(name) orelse return false;
    return oe.type == .array;
}

fn scopeText(target: cmd_options.ResolvedTarget) []u8 {
    return switch (target.kind) {
        .server => xm.xstrdup(""),
        .session => xm.xasprintf("session {s}", .{if (target.session) |session_ptr| session_ptr.name else ""}),
        .window => xm.xasprintf("window {d}", .{if (target.winlink) |wl| wl.idx else 0}),
        .pane => blk: {
            const pane_ptr = target.pane orelse break :blk xm.xasprintf("pane {d}", .{0});
            const pane_window = target.window orelse pane_ptr.window;
            break :blk xm.xasprintf("pane {d}", .{window.window_pane_index(pane_window, pane_ptr) orelse 0});
        },
    };
}

fn optionBaseName(display_name: []const u8, idx: ?u32) []const u8 {
    if (idx == null) return display_name;
    const open = std.mem.lastIndexOfScalar(u8, display_name, '[') orelse return display_name;
    return display_name[0..open];
}

fn targetForScope(scope_kind: ScopeKind, fs: *const T.CmdFindState, oo: *T.Options) cmd_options.ResolvedTarget {
    return switch (scope_kind) {
        .server => .{
            .kind = .server,
            .options = oo,
            .global = true,
        },
        .session => .{
            .kind = .session,
            .options = oo,
            .global = false,
            .session = fs.s,
            .winlink = fs.wl,
            .window = fs.w,
            .pane = fs.wp,
        },
        .window => .{
            .kind = .window,
            .options = oo,
            .global = false,
            .session = fs.s,
            .winlink = fs.wl,
            .window = fs.w,
            .pane = fs.wp,
        },
        .pane => .{
            .kind = .pane,
            .options = oo,
            .global = false,
            .session = fs.s,
            .winlink = fs.wl,
            .window = fs.w,
            .pane = fs.wp,
        },
    };
}

fn isGlobalOptions(oo: *T.Options) bool {
    return oo == opts.global_options or oo == opts.global_s_options or oo == opts.global_w_options;
}

fn unsupportedCommand(client: ?*T.Client, command: []const u8) void {
    const cl = client orelse return;
    const text = xm.xasprintf("Options-mode command not supported yet: {s}", .{command});
    defer xm.allocator.free(text);
    status_runtime.present_client_message(cl, text);
}

fn repeatCount(wme: *T.WindowModeEntry) u32 {
    return if (wme.prefix == 0) 1 else wme.prefix;
}

fn viewRows(tree: *const mode_tree.Data) u32 {
    return if (tree.screen.grid.sy > 0) tree.screen.grid.sy - 1 else 0;
}

fn pageUp(tree: *mode_tree.Data, rows: u32, repeat: u32) void {
    if (tree.line_list.items.len == 0) return;
    const step = if (rows > 1) rows - 1 else 1;
    var remaining = repeat;
    while (remaining > 0) : (remaining -= 1) {
        var moved: u32 = 0;
        while (moved < step) : (moved += 1) mode_tree.up(tree, false);
    }
}

fn pageDown(tree: *mode_tree.Data, rows: u32, repeat: u32) void {
    if (tree.line_list.items.len == 0) return;
    const step = if (rows > 1) rows - 1 else 1;
    var remaining = repeat;
    while (remaining > 0) : (remaining -= 1) {
        var moved: u32 = 0;
        while (moved < step) : (moved += 1) {
            if (!mode_tree.down(tree, false)) break;
        }
    }
}

fn sectionTag(scope_kind: ScopeKind) u64 {
    return 0x5100_0000_0000_0000 | (@as(u64, @intFromEnum(scope_kind)) << 48);
}

fn optionTag(scope_kind: ScopeKind, name: []const u8) u64 {
    return 0x5200_0000_0000_0000 |
        (@as(u64, @intFromEnum(scope_kind)) << 48) |
        (std.hash.Wyhash.hash(@as(u64, @intFromEnum(scope_kind)) + 1, name) & 0x0000_ffff_ffff_ffff);
}

fn freeItems(data: *CustomizeModeData) void {
    for (data.items.items) |item| {
        xm.allocator.free(item.name);
        xm.allocator.destroy(item);
    }
    data.items.clearRetainingCapacity();
}

// ── Public API: wrappers matching tmux C function names ─────────────────
//
// Each wrapper below corresponds to a static function in tmux
// window-customize.c.  Where the logic already exists under a
// Zig-idiomatic name the wrapper simply delegates; where the tmux
// function has no equivalent yet a minimal stub is provided.

/// tmux: window_customize_init – enter options/customize mode.
pub const window_customize_init = enterMode;

/// tmux: window_customize_free – release mode resources.
pub const window_customize_free = windowCustomizeClose;

/// tmux: window_customize_resize – resize the mode-tree display area.
pub fn window_customize_resize(wme: *T.WindowModeEntry, sx: u32, sy: u32) void {
    mode_tree.resize(modeData(wme).tree, sx, sy);
}

/// tmux: window_customize_key – low-level key dispatch.
pub const window_customize_key = windowCustomizeKey;

/// tmux: window_customize_build – mode_tree build callback.
pub const window_customize_build = buildTree;

/// tmux: window_customize_draw – draw option/key preview.
///
/// The Zig port uses a text-only view without a separate preview pane,
/// so this is a no-op stub matching the tmux callback signature.
pub fn window_customize_draw(
    data: *CustomizeModeData,
    item: ?*OptionItem,
    ctx: *T.ScreenWriteCtx,
    sx: u32,
    sy: u32,
) void {
    _ = data;
    _ = item;
    _ = ctx;
    _ = sx;
    _ = sy;
}

/// tmux: window_customize_draw_key – draw a key binding preview.
pub fn window_customize_draw_key(
    data: *CustomizeModeData,
    item: ?*OptionItem,
    ctx: *T.ScreenWriteCtx,
    sx: u32,
    sy: u32,
) void {
    _ = data;
    _ = item;
    _ = ctx;
    _ = sx;
    _ = sy;
}

/// tmux: window_customize_draw_option – draw an option value preview.
pub fn window_customize_draw_option(
    data: *CustomizeModeData,
    item: ?*OptionItem,
    ctx: *T.ScreenWriteCtx,
    sx: u32,
    sy: u32,
) void {
    _ = data;
    _ = item;
    _ = ctx;
    _ = sx;
    _ = sy;
}

/// tmux: window_customize_menu – forward a menu key to the key handler.
pub fn window_customize_menu(
    wme: *T.WindowModeEntry,
    client: ?*T.Client,
    key_code: T.key_code,
) void {
    if (wme.mode != &window_customize_mode) return;
    const data = modeData(wme);
    const session = data.fs.s orelse return;
    const wl = data.fs.wl orelse return;
    windowCustomizeKey(wme, client, session, wl, key_code, null);
}

/// tmux: window_customize_height – minimum preview area height.
pub fn window_customize_height() u32 {
    return 12;
}

/// tmux: window_customize_help – return help line data.
pub const window_customize_help_lines = [_][]const u8{
    "   Enter, s  Set option value",
    "          S  Set global option value",
    "          w  Set window option value",
    "          d  Set to default value",
    "          D  Set tagged options to default value",
    "          u  Unset an option",
    "          U  Unset tagged options",
    "          f  Enter a filter",
    "          v  Toggle information",
};

pub fn window_customize_help() struct { width: u32, item_noun: []const u8 } {
    return .{ .width = 52, .item_noun = "option" };
}

/// tmux: window_customize_get_tag – compute a unique tag for an option.
pub const window_customize_get_tag = optionTag;

/// tmux: window_customize_get_tree – resolve scope to its options tree.
///
/// In the Zig port, this is handled by targetForScope; this wrapper
/// returns just the options pointer for a given scope and find-state.
pub fn window_customize_get_tree(scope: cmd_options.ScopeKind, fs: *const T.CmdFindState) ?*T.Options {
    return switch (scope) {
        .server => opts.global_options,
        .session => if (fs.s) |s| s.options else null,
        .window => if (fs.w) |w| w.options else null,
        .pane => if (fs.wp) |wp| wp.options else null,
    };
}

/// tmux: window_customize_check_item – verify an item is still valid.
pub fn window_customize_check_item(
    data: *CustomizeModeData,
    item: *const OptionItem,
) bool {
    const oo = window_customize_get_tree(item.target.kind, &data.fs);
    return oo == item.target.options;
}

/// tmux: window_customize_scope_text – human-readable scope label.
pub const window_customize_scope_text = scopeText;

/// tmux: window_customize_add_item – allocate a new option item.
pub fn window_customize_add_item(
    data: *CustomizeModeData,
    target: cmd_options.ResolvedTarget,
    name: []const u8,
    idx: ?u32,
) *OptionItem {
    const item = xm.allocator.create(OptionItem) catch unreachable;
    item.* = .{
        .target = target,
        .name = xm.xstrdup(name),
        .idx = idx,
    };
    data.items.append(xm.allocator, item) catch unreachable;
    return item;
}

/// tmux: window_customize_free_item – free a single option item.
pub fn window_customize_free_item(item: *OptionItem) void {
    xm.allocator.free(item.name);
    xm.allocator.destroy(item);
}

/// tmux: window_customize_find_user_options – collect @-prefixed option names.
pub const window_customize_find_user_options = collectCustomNames;

/// tmux: window_customize_build_options – build one scope section.
pub const window_customize_build_options = buildScope;

/// tmux: window_customize_build_option – add a single option to the tree.
pub const window_customize_build_option = appendOption;

/// tmux: window_customize_build_array – expand array option items.
///
/// In the Zig port, array expansion is integrated into appendOption;
/// this is a compatibility alias.
pub const window_customize_build_array = appendOption;

/// tmux: window_customize_build_keys – build key binding tree section.
///
/// Key binding editing is not yet ported; this is a no-op stub.
pub fn window_customize_build_keys(
    data: *CustomizeModeData,
    tree: *mode_tree.Data,
) void {
    _ = data;
    _ = tree;
}

/// tmux: window_customize_destroy – reference-counted destroy.
///
/// The Zig port handles teardown through windowCustomizeClose; this
/// is a compatibility shim.
pub fn window_customize_destroy(data: *CustomizeModeData) void {
    _ = data;
}

/// tmux: window_customize_free_callback – release reference from prompt.
pub fn window_customize_free_callback(data: *CustomizeModeData) void {
    _ = data;
}

/// tmux: window_customize_free_item_callback – free prompt item + release ref.
pub fn window_customize_free_item_callback(item: *OptionItem) void {
    window_customize_free_item(item);
}

/// tmux: window_customize_set_option_callback – prompt callback for editing.
pub const window_customize_set_option_callback = optionPromptCallback;

/// tmux: window_customize_set_option – begin editing an option value.
pub fn window_customize_set_option(
    wme: *T.WindowModeEntry,
    client: ?*T.Client,
    item: *OptionItem,
) void {
    editCurrentItem(wme, client, item);
}

/// tmux: window_customize_unset_option – remove/reset an option.
pub fn window_customize_unset_option(
    state: *OptionPromptState,
    client: *T.Client,
) void {
    applyUnset(state, client);
}

/// tmux: window_customize_reset_option – reset option to default.
pub fn window_customize_reset_option(
    state: *OptionPromptState,
    client: *T.Client,
) void {
    applyReset(state, client);
}

/// tmux: window_customize_set_command_callback – set key command (stub).
pub fn window_customize_set_command_callback(
    client: ?*T.Client,
    item: ?*anyopaque,
    s: ?[]const u8,
) bool {
    _ = client;
    _ = item;
    _ = s;
    return false;
}

/// tmux: window_customize_set_note_callback – set key note (stub).
pub fn window_customize_set_note_callback(
    client: ?*T.Client,
    item: ?*anyopaque,
    s: ?[]const u8,
) bool {
    _ = client;
    _ = item;
    _ = s;
    return false;
}

/// tmux: window_customize_set_key – begin editing a key binding (stub).
pub fn window_customize_set_key(
    client: ?*T.Client,
    data: *CustomizeModeData,
    item: ?*anyopaque,
) void {
    _ = client;
    _ = data;
    _ = item;
}

/// tmux: window_customize_unset_key – remove a key binding (stub).
pub fn window_customize_unset_key(
    data: *CustomizeModeData,
    item: ?*anyopaque,
) void {
    _ = data;
    _ = item;
}

/// tmux: window_customize_reset_key – reset a key binding (stub).
pub fn window_customize_reset_key(
    data: *CustomizeModeData,
    item: ?*anyopaque,
) void {
    _ = data;
    _ = item;
}

/// tmux: window_customize_change_each – apply change to each tagged item.
pub fn window_customize_change_each(
    data: *CustomizeModeData,
    item: ?*anyopaque,
    client: ?*T.Client,
) void {
    _ = data;
    _ = item;
    _ = client;
}

/// tmux: window_customize_change_current_callback – prompt callback (stub).
pub fn window_customize_change_current_callback(
    client: ?*T.Client,
    data: *CustomizeModeData,
    s: ?[]const u8,
) bool {
    _ = client;
    _ = data;
    _ = s;
    return false;
}

/// tmux: window_customize_change_tagged_callback – prompt callback (stub).
pub fn window_customize_change_tagged_callback(
    client: ?*T.Client,
    data: *CustomizeModeData,
    s: ?[]const u8,
) bool {
    _ = client;
    _ = data;
    _ = s;
    return false;
}

fn initTestGlobals() void {
    const env_mod = @import("environ.zig");
    const opts_mod = @import("options.zig");
    const sess = @import("session.zig");

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
    const env_mod = @import("environ.zig");
    const opts_mod = @import("options.zig");

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
    s.curw = wl;
    return .{
        .session = s,
        .pane = wl.window.active.?,
    };
}

fn targetState(setup: TestSetup) T.CmdFindState {
    const wl = setup.session.curw.?;
    return .{
        .s = setup.session,
        .wl = wl,
        .w = wl.window,
        .wp = setup.pane,
        .idx = wl.idx,
    };
}

fn containsLineName(tree: *const mode_tree.Data, name: []const u8) bool {
    for (tree.line_list.items) |line| {
        if (std.mem.eql(u8, line.item.name, name)) return true;
    }
    return false;
}

fn containsLineText(tree: *const mode_tree.Data, fragment: []const u8) bool {
    for (tree.line_list.items) |line| {
        const text = line.item.text orelse continue;
        if (std.mem.indexOf(u8, text, fragment) != null) return true;
    }
    return false;
}

fn makeClient(session_ptr: *T.Session, name: []const u8, ttyname: []const u8) T.Client {
    const env_mod = @import("environ.zig");
    var client = T.Client{
        .name = xm.xstrdup(name),
        .ttyname = xm.xstrdup(ttyname),
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{ .screen = undefined },
        .flags = T.CLIENT_ATTACHED,
        .session = session_ptr,
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

test "window-customize enterMode builds scoped read-only options" {
    const grid = @import("grid.zig");
    const sess = @import("session.zig");

    initTestGlobals();
    defer deinitTestGlobals();

    const setup = try testSetup("window-customize-render");
    defer if (sess.session_find("window-customize-render") != null) sess.session_destroy(setup.session, false, "test");

    opts.options_set_string(setup.session.options, false, "status-left", "session-left");
    opts.options_set_string(setup.pane.options, false, "@pane-note", "local");

    var cause: ?[]u8 = null;
    var args = try args_mod.args_parse(xm.allocator, &.{}, "F:f:Nt:yZ", 0, 0, &cause);
    defer args.deinit();

    var target = targetState(setup);
    const wme = enterMode(setup.pane, &target, &args);
    defer {
        if (window.window_pane_mode(setup.pane) != null)
            _ = window_mode_runtime.resetMode(setup.pane);
    }

    const data = modeData(wme);
    try std.testing.expectEqual(&window_customize_mode, wme.mode);
    try std.testing.expect(containsLineName(data.tree, "Server Options"));
    try std.testing.expect(containsLineName(data.tree, "status-left"));
    try std.testing.expect(containsLineName(data.tree, "@pane-note"));

    const view = window_customize_mode.get_screen.?(wme);
    const first = grid.string_cells(view.grid, 0, view.grid.sx, .{ .trim_trailing_spaces = true });
    defer xm.allocator.free(first);
    try std.testing.expect(std.mem.indexOf(u8, first, "Server Options") != null);
}

test "window-customize honours option format fields and filters" {
    const sess = @import("session.zig");

    initTestGlobals();
    defer deinitTestGlobals();

    const setup = try testSetup("window-customize-filter");
    defer if (sess.session_find("window-customize-filter") != null) sess.session_destroy(setup.session, false, "test");

    opts.options_set_string(setup.pane.options, false, "@pane-note", "local");

    var cause: ?[]u8 = null;
    var args = try args_mod.args_parse(
        xm.allocator,
        &.{
            "-F",
            "#{option_scope}|#{option_name}|#{option_value}|#{option_inherited}",
            "-f",
            "#{==:#{option_name},@pane-note}",
        },
        "F:f:Nt:yZ",
        0,
        0,
        &cause,
    );
    defer args.deinit();

    var target = targetState(setup);
    const wme = enterMode(setup.pane, &target, &args);
    defer {
        if (window.window_pane_mode(setup.pane) != null)
            _ = window_mode_runtime.resetMode(setup.pane);
    }

    const data = modeData(wme);
    try std.testing.expectEqual(@as(usize, 2), data.tree.line_list.items.len);
    try std.testing.expect(containsLineText(data.tree, "@pane-note|local|0"));
}

fn sendPromptKey(client: *T.Client, key: T.key_code, bytes: []const u8) bool {
    var event = T.key_event{ .key = key, .len = bytes.len };
    if (bytes.len != 0) @memcpy(event.data[0..bytes.len], bytes);
    return status_prompt.status_prompt_handle_key(client, &event);
}

test "window-customize choose edits the selected option through the shared prompt" {
    const sess = @import("session.zig");

    initTestGlobals();
    defer deinitTestGlobals();

    const setup = try testSetup("window-customize-choose");
    defer if (sess.session_find("window-customize-choose") != null) sess.session_destroy(setup.session, false, "test");

    opts.options_set_string(setup.pane.options, false, "@pane-note", "local");

    var cause: ?[]u8 = null;
    var args = try args_mod.args_parse(
        xm.allocator,
        &.{ "-f", "#{==:#{option_name},@pane-note}" },
        "F:f:Nt:yZ",
        0,
        0,
        &cause,
    );
    defer args.deinit();

    var target = targetState(setup);
    const wme = enterMode(setup.pane, &target, &args);
    defer {
        if (window.window_pane_mode(setup.pane) != null)
            _ = window_mode_runtime.resetMode(setup.pane);
    }

    var client = makeClient(setup.session, "options-client", "/dev/pts/501");
    defer freeClient(&client);

    const data = modeData(wme);
    _ = mode_tree.down(data.tree, false);

    cause = null;
    var command_args = try args_mod.args_parse(xm.allocator, &.{"choose"}, "", 0, -1, &cause);
    defer command_args.deinit();
    windowCustomizeCommand(wme, &client, setup.session, setup.session.curw.?, @ptrCast(&command_args), null);

    try std.testing.expect(status_prompt.status_prompt_active(&client));
    var backspaces: usize = opts.options_get_string(setup.pane.options, "@pane-note").len;
    while (backspaces > 0) : (backspaces -= 1)
        try std.testing.expect(sendPromptKey(&client, T.KEYC_BSPACE, "\x7f"));
    try std.testing.expect(sendPromptKey(&client, 'u', "u"));
    try std.testing.expect(sendPromptKey(&client, 'p', "p"));
    try std.testing.expect(sendPromptKey(&client, 'd', "d"));
    try std.testing.expect(sendPromptKey(&client, 'a', "a"));
    try std.testing.expect(sendPromptKey(&client, 't', "t"));
    try std.testing.expect(sendPromptKey(&client, 'e', "e"));
    try std.testing.expect(sendPromptKey(&client, T.C0_CR, "\r"));

    try std.testing.expectEqualStrings("update", opts.options_get_string(setup.pane.options, "@pane-note"));
    try std.testing.expect(status_prompt.status_prompt_active(&client) == false);
    try std.testing.expect(window.window_pane_mode(setup.pane) == wme);
}

test "window-customize choose toggles flag options without prompting" {
    const sess = @import("session.zig");

    initTestGlobals();
    defer deinitTestGlobals();

    const setup = try testSetup("window-customize-toggle");
    defer if (sess.session_find("window-customize-toggle") != null) sess.session_destroy(setup.session, false, "test");

    const initial = opts.options_get_number(setup.pane.window.options, "automatic-rename");

    var cause: ?[]u8 = null;
    var args = try args_mod.args_parse(
        xm.allocator,
        &.{ "-f", "#{==:#{option_name},automatic-rename}" },
        "F:f:Nt:yZ",
        0,
        0,
        &cause,
    );
    defer args.deinit();

    var target = targetState(setup);
    const wme = enterMode(setup.pane, &target, &args);
    defer {
        if (window.window_pane_mode(setup.pane) != null)
            _ = window_mode_runtime.resetMode(setup.pane);
    }

    var client = makeClient(setup.session, "options-toggle-client", "/dev/pts/511");
    defer freeClient(&client);

    const data = modeData(wme);
    _ = mode_tree.down(data.tree, false);

    cause = null;
    var command_args = try args_mod.args_parse(xm.allocator, &.{"choose"}, "", 0, -1, &cause);
    defer command_args.deinit();
    windowCustomizeCommand(wme, &client, setup.session, setup.session.curw.?, @ptrCast(&command_args), null);

    try std.testing.expectEqual(if (initial == 0) @as(i64, 1) else @as(i64, 0), opts.options_get_number(setup.pane.window.options, "automatic-rename"));
    try std.testing.expect(status_prompt.status_prompt_active(&client) == false);
}

test "window-customize unset-current removes the selected local option" {
    const sess = @import("session.zig");

    initTestGlobals();
    defer deinitTestGlobals();

    const setup = try testSetup("window-customize-unset");
    defer if (sess.session_find("window-customize-unset") != null) sess.session_destroy(setup.session, false, "test");

    opts.options_set_string(setup.pane.options, false, "@pane-note", "local");

    var cause: ?[]u8 = null;
    var args = try args_mod.args_parse(
        xm.allocator,
        &.{ "-f", "#{==:#{option_name},@pane-note}" },
        "F:f:Nt:yZ",
        0,
        0,
        &cause,
    );
    defer args.deinit();

    var target = targetState(setup);
    const wme = enterMode(setup.pane, &target, &args);
    defer {
        if (window.window_pane_mode(setup.pane) != null)
            _ = window_mode_runtime.resetMode(setup.pane);
    }

    var client = makeClient(setup.session, "options-unset-client", "/dev/pts/521");
    defer freeClient(&client);

    const data = modeData(wme);
    _ = mode_tree.down(data.tree, false);

    cause = null;
    var command_args = try args_mod.args_parse(xm.allocator, &.{"unset-current"}, "", 0, -1, &cause);
    defer command_args.deinit();
    windowCustomizeCommand(wme, &client, setup.session, setup.session.curw.?, @ptrCast(&command_args), null);

    try std.testing.expect(status_prompt.status_prompt_active(&client));
    try std.testing.expect(sendPromptKey(&client, 'y', "y"));

    try std.testing.expect(opts.options_get_only(setup.pane.options, "@pane-note") == null);
}

test "window-customize reset-current clears local and inherited overrides back to default" {
    const sess = @import("session.zig");

    initTestGlobals();
    defer deinitTestGlobals();

    const setup = try testSetup("window-customize-reset");
    defer if (sess.session_find("window-customize-reset") != null) sess.session_destroy(setup.session, false, "test");

    const default_status_left = xm.xstrdup(opts.options_get_string(opts.global_s_options, "status-left"));
    defer xm.allocator.free(default_status_left);

    opts.options_set_string(opts.global_s_options, false, "status-left", "global-left");
    opts.options_set_string(setup.session.options, false, "status-left", "session-left");

    var cause: ?[]u8 = null;
    var args = try args_mod.args_parse(
        xm.allocator,
        &.{ "-f", "#{==:#{option_name},status-left}" },
        "F:f:Nt:yZ",
        0,
        0,
        &cause,
    );
    defer args.deinit();

    var target = targetState(setup);
    const wme = enterMode(setup.pane, &target, &args);
    defer {
        if (window.window_pane_mode(setup.pane) != null)
            _ = window_mode_runtime.resetMode(setup.pane);
    }

    var client = makeClient(setup.session, "options-reset-client", "/dev/pts/531");
    defer freeClient(&client);

    const data = modeData(wme);
    _ = mode_tree.down(data.tree, false);
    _ = mode_tree.down(data.tree, false);

    cause = null;
    var command_args = try args_mod.args_parse(xm.allocator, &.{"reset-current"}, "", 0, -1, &cause);
    defer command_args.deinit();
    windowCustomizeCommand(wme, &client, setup.session, setup.session.curw.?, @ptrCast(&command_args), null);

    try std.testing.expect(status_prompt.status_prompt_active(&client));
    try std.testing.expect(sendPromptKey(&client, 'y', "y"));

    try std.testing.expect(opts.options_get_only(setup.session.options, "status-left") == null);
    try std.testing.expectEqualStrings(default_status_left, opts.options_get_string(opts.global_s_options, "status-left"));
    try std.testing.expectEqualStrings(default_status_left, opts.options_get_string(setup.session.options, "status-left"));
}
