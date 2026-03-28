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
// Ported in part from tmux/window-copy.c.
// Original copyright:
//   Copyright (c) 2007 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

const std = @import("std");
const args_mod = @import("arguments.zig");
const grid = @import("grid.zig");
const hyperlinks = @import("hyperlinks.zig");
const mouse_runtime = @import("mouse-runtime.zig");
const opts = @import("options.zig");
const screen = @import("screen.zig");
const status_runtime = @import("status-runtime.zig");
const T = @import("types.zig");
const window = @import("window.zig");
const window_mode_runtime = @import("window-mode-runtime.zig");
const xm = @import("xmalloc.zig");

const CopyModeData = struct {
    backing: *T.Screen,
    top: u32 = 0,
    cx: u32 = 0,
    cy: u32 = 0,
    hide_position: bool = false,
    scroll_exit: bool = false,
};

pub const window_copy_mode = T.WindowMode{
    .name = "copy-mode",
    .key = copyModeKey,
    .key_table = copyModeKeyTable,
    .command = copyModeCommand,
    .close = copyModeClose,
    .get_screen = copyModeGetScreen,
};

pub const MouseFormatSource = struct {
    screen: *const T.Screen,
    row: u32,
};

pub fn enterMode(wp: *T.WindowPane, swp: *T.WindowPane, args: *const args_mod.Arguments) *T.WindowModeEntry {
    if (window.window_pane_mode(wp)) |wme| {
        if (wme.mode == &window_copy_mode) {
            wme.swp = swp;
            const data = modeData(wme);
            data.scroll_exit = args.has('e');
            data.hide_position = args.has('H');
            refreshFromSource(wme, false);
            wme.prefix = 1;
            return wme;
        }
    }

    screen.screen_enter_alternate(wp, true);

    const data = xm.allocator.create(CopyModeData) catch unreachable;
    data.* = .{
        .backing = screen.screen_init(swp.base.grid.sx, swp.base.grid.sy, 0),
        .hide_position = args.has('H'),
        .scroll_exit = args.has('e'),
    };

    const wme = window_mode_runtime.pushMode(wp, &window_copy_mode, @ptrCast(data), swp);
    wme.prefix = 1;
    refreshFromSource(wme, false);
    return wme;
}

pub fn pageUp(wp: *T.WindowPane, half_page: bool) void {
    const wme = window.window_pane_mode(wp) orelse return;
    if (wme.mode != &window_copy_mode) return;
    pageUpMode(wme, half_page);
    redraw(wme);
}

pub fn pageDown(wp: *T.WindowPane, half_page: bool, scroll_exit: bool) void {
    const wme = window.window_pane_mode(wp) orelse return;
    if (wme.mode != &window_copy_mode) return;
    if (pageDownMode(wme, half_page, scroll_exit)) {
        _ = window_mode_runtime.resetMode(wp);
        return;
    }
    redraw(wme);
}

pub fn mouseFormatSource(wp: *T.WindowPane, y: u32) ?MouseFormatSource {
    const wme = window.window_pane_mode(wp) orelse return null;
    if (wme.mode != &window_copy_mode) return null;

    const data = modeData(wme);
    const row = data.top + y;
    if (row >= data.backing.grid.sy) return null;
    return .{
        .screen = data.backing,
        .row = row,
    };
}

fn copyModeKeyTable(wme: *T.WindowModeEntry) []const u8 {
    if (opts.options_get_number(wme.wp.window.options, "mode-keys") == T.MODEKEY_VI)
        return "copy-mode-vi";
    return "copy-mode";
}

fn copyModeKey(
    wme: *T.WindowModeEntry,
    _client: ?*T.Client,
    _session: *T.Session,
    _wl: *T.Winlink,
    key: T.key_code,
    _mouse: ?*const T.MouseEvent,
) void {
    _ = _client;
    _ = _session;
    _ = _wl;
    _ = _mouse;

    const base = mouse_runtime.key_base(key) orelse return;
    switch (base) {
        T.KEYC_WHEELUP => {
            scrollLines(wme, -3);
            redraw(wme);
        },
        T.KEYC_WHEELDOWN => {
            if (scrollDownLines(wme, 3, modeData(wme).scroll_exit)) {
                _ = window_mode_runtime.resetMode(wme.wp);
                return;
            }
            redraw(wme);
        },
        else => {},
    }
}

fn copyModeCommand(
    wme: *T.WindowModeEntry,
    client: ?*T.Client,
    _session: *T.Session,
    _wl: *T.Winlink,
    raw_args: *const anyopaque,
    _mouse: ?*const T.MouseEvent,
) void {
    _ = _session;
    _ = _wl;
    _ = _mouse;

    const args: *const args_mod.Arguments = @ptrCast(@alignCast(raw_args));
    if (args.count() == 0) return;

    const count = repeatCount(wme);
    const command = args.value_at(0).?;

    if (std.mem.eql(u8, command, "cancel")) {
        _ = window_mode_runtime.resetMode(wme.wp);
        return;
    }
    if (std.mem.eql(u8, command, "refresh-from-pane")) {
        refreshFromSource(wme, true);
        wme.prefix = 1;
        return;
    }

    if (std.mem.eql(u8, command, "cursor-left")) {
        moveCursorX(wme, -@as(i32, @intCast(count)));
    } else if (std.mem.eql(u8, command, "cursor-right")) {
        moveCursorX(wme, @intCast(count));
    } else if (std.mem.eql(u8, command, "cursor-up")) {
        scrollLines(wme, -@as(i32, @intCast(count)));
    } else if (std.mem.eql(u8, command, "cursor-down")) {
        if (scrollDownLines(wme, count, false)) unreachable;
    } else if (std.mem.eql(u8, command, "page-up")) {
        var remaining = count;
        while (remaining > 0) : (remaining -= 1) pageUpMode(wme, false);
    } else if (std.mem.eql(u8, command, "page-down")) {
        var remaining = count;
        while (remaining > 0) : (remaining -= 1) {
            if (pageDownMode(wme, false, modeData(wme).scroll_exit)) {
                _ = window_mode_runtime.resetMode(wme.wp);
                return;
            }
        }
    } else if (std.mem.eql(u8, command, "halfpage-up")) {
        var remaining = count;
        while (remaining > 0) : (remaining -= 1) pageUpMode(wme, true);
    } else if (std.mem.eql(u8, command, "halfpage-down")) {
        var remaining = count;
        while (remaining > 0) : (remaining -= 1) {
            if (pageDownMode(wme, true, modeData(wme).scroll_exit)) {
                _ = window_mode_runtime.resetMode(wme.wp);
                return;
            }
        }
    } else if (std.mem.eql(u8, command, "history-top")) {
        setAbsoluteCursorRow(wme, 0);
    } else if (std.mem.eql(u8, command, "history-bottom")) {
        const data = modeData(wme);
        const backing_rows = rowCount(data.backing);
        if (backing_rows != 0) setAbsoluteCursorRow(wme, backing_rows - 1);
    } else if (std.mem.eql(u8, command, "top-line")) {
        setCursorLine(wme, 0);
    } else if (std.mem.eql(u8, command, "middle-line")) {
        setCursorLine(wme, viewRows(wme.wp) / 2);
    } else if (std.mem.eql(u8, command, "bottom-line")) {
        const rows = viewRows(wme.wp);
        if (rows != 0) setCursorLine(wme, rows - 1);
    } else if (std.mem.eql(u8, command, "scroll-top")) {
        alignCursor(wme, 0);
    } else if (std.mem.eql(u8, command, "scroll-middle")) {
        alignCursor(wme, viewRows(wme.wp) / 2);
    } else if (std.mem.eql(u8, command, "scroll-bottom")) {
        const rows = viewRows(wme.wp);
        alignCursor(wme, if (rows == 0) 0 else rows - 1);
    } else if (std.mem.eql(u8, command, "start-of-line")) {
        modeData(wme).cx = 0;
    } else if (std.mem.eql(u8, command, "end-of-line")) {
        modeData(wme).cx = lineMaxX(modeData(wme).backing, absoluteCursorRow(wme), wme.wp.screen.grid.sx);
    } else {
        unsupportedCommand(client, command);
        wme.prefix = 1;
        return;
    }

    wme.prefix = 1;
    redraw(wme);
}

fn copyModeClose(wme: *T.WindowModeEntry) void {
    const data = modeData(wme);
    screen.screen_free(data.backing);
    xm.allocator.destroy(data.backing);
    xm.allocator.destroy(data);

    if (wme.wp.modes.items.len <= 1) {
        screen.screen_leave_alternate(wme.wp, true);
    }
}

fn copyModeGetScreen(wme: *T.WindowModeEntry) *T.Screen {
    return modeData(wme).backing;
}

fn modeData(wme: *T.WindowModeEntry) *CopyModeData {
    return @ptrCast(@alignCast(wme.data.?));
}

fn refreshFromSource(wme: *T.WindowModeEntry, preserve_cursor: bool) void {
    const data = modeData(wme);
    const source_wp = wme.swp orelse wme.wp;
    const source_screen = &source_wp.base;
    const old_absolute = if (preserve_cursor) absoluteCursorRow(wme) else 0;

    if (data.backing.grid.sx != source_screen.grid.sx or data.backing.grid.sy != source_screen.grid.sy) {
        screen.screen_free(data.backing);
        xm.allocator.destroy(data.backing);
        data.backing = screen.screen_init(source_screen.grid.sx, source_screen.grid.sy, 0);
    } else {
        screen.screen_reset(data.backing);
    }

    cloneScreen(data.backing, source_screen);

    if (preserve_cursor) {
        setAbsoluteCursorRow(wme, old_absolute);
    } else {
        const target_rows = viewRows(wme.wp);
        const backing_rows = rowCount(data.backing);
        const max_top = maxTop(data.backing, wme.wp);
        data.top = if (target_rows == 0 or source_screen.cy < target_rows) 0 else source_screen.cy - (target_rows - 1);
        if (data.top > max_top) data.top = max_top;
        if (backing_rows == 0) {
            data.cy = 0;
        } else {
            data.cy = @min(source_screen.cy, backing_rows - 1) - data.top;
        }
        data.cx = source_screen.cx;
        clampCursorX(wme);
    }

    redraw(wme);
}

fn cloneScreen(dst: *T.Screen, src: *const T.Screen) void {
    dst.mode = src.mode;
    dst.cursor_visible = src.cursor_visible;
    dst.bracketed_paste = src.bracketed_paste;

    if (src.title) |title| _ = screen.screen_set_title(dst, title);
    if (src.path) |path| screen.screen_set_path(dst, path);

    if (dst.hyperlinks) |hl| {
        hyperlinks.hyperlinks_free(hl);
        dst.hyperlinks = null;
    }
    dst.hyperlinks = if (src.hyperlinks) |hl| hyperlinks.hyperlinks_copy(hl) else hyperlinks.hyperlinks_init();

    var row: u32 = 0;
    while (row < @min(src.grid.sy, dst.grid.sy)) : (row += 1) {
        copyLine(dst.grid, row, src.grid, row, @min(src.grid.sx, dst.grid.sx));
    }

    if (dst.grid.sx != 0) dst.cx = @min(src.cx, dst.grid.sx - 1) else dst.cx = 0;
    if (dst.grid.sy != 0) dst.cy = @min(src.cy, dst.grid.sy - 1) else dst.cy = 0;
}

fn copyLine(dst_grid: *T.Grid, dst_row: u32, src_grid: *const T.Grid, src_row: u32, width: u32) void {
    if (src_row >= src_grid.linedata.len or dst_row >= dst_grid.linedata.len) return;

    const src_line = &src_grid.linedata[src_row];
    var cell: T.GridCell = undefined;
    var col: u32 = 0;
    while (col < width) : (col += 1) {
        grid.get_cell(@constCast(src_grid), src_row, col, &cell);
        grid.set_cell(dst_grid, dst_row, col, &cell);
    }

    dst_grid.linedata[dst_row].flags = src_line.flags;
    dst_grid.linedata[dst_row].time = src_line.time;
}

fn redraw(wme: *T.WindowModeEntry) void {
    const data = modeData(wme);
    const view = wme.wp.screen;
    const backing = data.backing;

    screen.screen_reset_active(view);
    view.mode = backing.mode;
    view.cursor_visible = backing.cursor_visible;
    view.bracketed_paste = backing.bracketed_paste;

    if (view.hyperlinks) |hl| {
        hyperlinks.hyperlinks_free(hl);
        view.hyperlinks = null;
    }
    view.hyperlinks = if (backing.hyperlinks) |hl| hyperlinks.hyperlinks_copy(hl) else hyperlinks.hyperlinks_init();

    const rows = viewRows(wme.wp);
    const width = @min(backing.grid.sx, view.grid.sx);
    var row: u32 = 0;
    while (row < rows) : (row += 1) {
        const backing_row = data.top + row;
        if (backing_row >= backing.grid.sy) break;
        copyLine(view.grid, row, backing.grid, backing_row, width);
    }

    if (view.grid.sx != 0) view.cx = @min(data.cx, view.grid.sx - 1) else view.cx = 0;
    if (rows != 0) view.cy = @min(data.cy, rows - 1) else view.cy = 0;
    window_mode_runtime.noteModeRedraw(wme.wp);
}

fn repeatCount(wme: *T.WindowModeEntry) u32 {
    return if (wme.prefix == 0) 1 else wme.prefix;
}

fn absoluteCursorRow(wme: *T.WindowModeEntry) u32 {
    const data = modeData(wme);
    return data.top + data.cy;
}

fn viewRows(wp: *const T.WindowPane) u32 {
    return wp.screen.grid.sy;
}

fn rowCount(s: *const T.Screen) u32 {
    return s.grid.sy;
}

fn maxTop(backing: *const T.Screen, wp: *const T.WindowPane) u32 {
    const rows = backing.grid.sy;
    const view = viewRows(wp);
    return if (rows > view) rows - view else 0;
}

fn setAbsoluteCursorRow(wme: *T.WindowModeEntry, row: u32) void {
    const data = modeData(wme);
    const backing_rows = rowCount(data.backing);
    if (backing_rows == 0) {
        data.top = 0;
        data.cy = 0;
        data.cx = 0;
        return;
    }

    const clamped = @min(row, backing_rows - 1);
    const max_top = maxTop(data.backing, wme.wp);
    if (clamped < data.top) {
        data.top = clamped;
    } else if (clamped >= data.top + viewRows(wme.wp)) {
        const desired_top = clamped + 1 - @min(viewRows(wme.wp), clamped + 1);
        data.top = @min(desired_top, max_top);
    }
    if (data.top > max_top) data.top = max_top;
    data.cy = clamped - data.top;
    clampCursorX(wme);
}

fn setCursorLine(wme: *T.WindowModeEntry, line: u32) void {
    const data = modeData(wme);
    const rows = viewRows(wme.wp);
    if (rows == 0) {
        data.cy = 0;
        return;
    }
    const clamped_line = @min(line, rows - 1);
    const max_line = backingBottomVisibleRow(wme);
    data.cy = @min(clamped_line, max_line);
    clampCursorX(wme);
}

fn backingBottomVisibleRow(wme: *T.WindowModeEntry) u32 {
    const data = modeData(wme);
    const rows = rowCount(data.backing);
    if (rows == 0 or data.top >= rows) return 0;
    const visible = rows - data.top;
    const view = viewRows(wme.wp);
    return if (visible == 0 or view == 0) 0 else @min(view, visible) - 1;
}

fn alignCursor(wme: *T.WindowModeEntry, view_row: u32) void {
    const data = modeData(wme);
    const abs_row = absoluteCursorRow(wme);
    const desired_row = if (viewRows(wme.wp) == 0) 0 else @min(view_row, viewRows(wme.wp) - 1);
    const new_top = abs_row -| desired_row;
    data.top = @min(new_top, maxTop(data.backing, wme.wp));
    data.cy = abs_row - data.top;
    clampCursorX(wme);
}

fn moveCursorX(wme: *T.WindowModeEntry, delta: i32) void {
    const data = modeData(wme);
    const max_x = lineMaxX(data.backing, absoluteCursorRow(wme), wme.wp.screen.grid.sx);
    const current = @as(i32, @intCast(data.cx));
    const next = std.math.clamp(current + delta, 0, @as(i32, @intCast(max_x)));
    data.cx = @intCast(next);
}

fn clampCursorX(wme: *T.WindowModeEntry) void {
    const data = modeData(wme);
    const max_x = lineMaxX(data.backing, absoluteCursorRow(wme), wme.wp.screen.grid.sx);
    if (data.cx > max_x) data.cx = max_x;
}

fn lineMaxX(backing: *const T.Screen, row: u32, view_width: u32) u32 {
    if (view_width == 0 or row >= backing.grid.sy) return 0;
    const length = grid.line_length(@constCast(backing.grid), row);
    if (length == 0) return 0;
    return @min(view_width - 1, length - 1);
}

fn scrollLines(wme: *T.WindowModeEntry, delta: i32) void {
    if (delta == 0) return;

    const data = modeData(wme);
    const backing_rows = rowCount(data.backing);
    if (backing_rows == 0) {
        data.top = 0;
        data.cy = 0;
        return;
    }

    if (delta < 0) {
        var remaining: u32 = @intCast(-delta);
        while (remaining > 0) : (remaining -= 1) {
            if (data.cy > 0) {
                data.cy -= 1;
            } else if (data.top > 0) {
                data.top -= 1;
            }
        }
    } else {
        _ = scrollDownLines(wme, @intCast(delta), false);
    }
    clampCursorX(wme);
}

fn scrollDownLines(wme: *T.WindowModeEntry, count: u32, scroll_exit: bool) bool {
    const data = modeData(wme);
    const backing_rows = rowCount(data.backing);
    if (backing_rows == 0) return false;

    var remaining = count;
    while (remaining > 0) : (remaining -= 1) {
        const abs_row = absoluteCursorRow(wme);
        if (abs_row + 1 >= backing_rows) break;

        const max_visible = backingBottomVisibleRow(wme);
        if (data.cy < max_visible) {
            data.cy += 1;
        } else if (data.top < maxTop(data.backing, wme.wp)) {
            data.top += 1;
        }
    }

    clampCursorX(wme);
    return scroll_exit and absoluteCursorRow(wme) + 1 >= backing_rows and data.top == maxTop(data.backing, wme.wp);
}

fn pageStep(view_rows: u32, half_page: bool) u32 {
    if (view_rows <= 2) return 1;
    return if (half_page) @max(@as(u32, 1), view_rows / 2) else view_rows - 2;
}

fn pageUpMode(wme: *T.WindowModeEntry, half_page: bool) void {
    const data = modeData(wme);
    const step = pageStep(viewRows(wme.wp), half_page);

    if (data.top >= step) {
        data.top -= step;
    } else {
        const remainder = step - data.top;
        data.top = 0;
        data.cy = data.cy -| remainder;
    }
    clampCursorX(wme);
}

fn pageDownMode(wme: *T.WindowModeEntry, half_page: bool, scroll_exit: bool) bool {
    const data = modeData(wme);
    const backing_rows = rowCount(data.backing);
    if (backing_rows == 0) return false;

    const step = pageStep(viewRows(wme.wp), half_page);
    const max_top = maxTop(data.backing, wme.wp);
    const available_scroll = max_top - data.top;

    if (available_scroll >= step) {
        data.top += step;
    } else {
        const remainder = step - available_scroll;
        data.top = max_top;
        const max_visible = backingBottomVisibleRow(wme);
        data.cy = @min(data.cy + remainder, max_visible);
    }
    clampCursorX(wme);
    return scroll_exit and data.top == max_top and absoluteCursorRow(wme) + 1 >= backing_rows;
}

fn unsupportedCommand(client: ?*T.Client, command: []const u8) void {
    const text = xm.xasprintf("Copy-mode command not supported yet: {s}", .{command});
    const cl = client orelse {
        xm.allocator.free(text);
        return;
    };
    status_runtime.status_message_set_owned(cl, -1, true, false, false, text);
}

fn setGridLineText(gd: *T.Grid, row: u32, text: []const u8) void {
    var col: u32 = 0;
    while (col < text.len and col < gd.sx) : (col += 1) {
        var cell = T.grid_default_cell;
        cell.data = T.grid_default_cell.data;
        cell.data.data[0] = text[col];
        grid.set_cell(gd, row, col, &cell);
    }
}

test "window-copy snapshots the source pane and refresh-from-pane updates it" {
    const source_grid = grid.grid_create(6, 2, 0);
    defer grid.grid_free(source_grid);
    const target_grid = grid.grid_create(6, 2, 0);
    defer grid.grid_free(target_grid);
    const source_screen = screen.screen_init(6, 2, 0);
    defer {
        screen.screen_free(source_screen);
        xm.allocator.destroy(source_screen);
    }
    const target_screen = screen.screen_init(6, 2, 0);
    defer {
        screen.screen_free(target_screen);
        xm.allocator.destroy(target_screen);
    }

    var source_window = T.Window{
        .id = 1,
        .name = xm.xstrdup("copy-source"),
        .sx = 6,
        .sy = 2,
        .options = undefined,
    };
    defer xm.allocator.free(source_window.name);
    defer source_window.panes.deinit(xm.allocator);
    defer source_window.last_panes.deinit(xm.allocator);
    defer source_window.winlinks.deinit(xm.allocator);

    var target_window = T.Window{
        .id = 2,
        .name = xm.xstrdup("copy-target"),
        .sx = 6,
        .sy = 2,
        .options = undefined,
    };
    defer xm.allocator.free(target_window.name);
    defer target_window.panes.deinit(xm.allocator);
    defer target_window.last_panes.deinit(xm.allocator);
    defer target_window.winlinks.deinit(xm.allocator);

    var source = T.WindowPane{
        .id = 3,
        .window = &source_window,
        .options = undefined,
        .sx = 6,
        .sy = 2,
        .screen = source_screen,
        .base = .{ .grid = source_grid, .rlower = 1 },
    };
    defer window_mode_runtime.resetModeAll(&source);

    var target = T.WindowPane{
        .id = 4,
        .window = &target_window,
        .options = undefined,
        .sx = 6,
        .sy = 2,
        .screen = target_screen,
        .base = .{ .grid = target_grid, .rlower = 1 },
    };
    defer window_mode_runtime.resetModeAll(&target);

    try source_window.panes.append(xm.allocator, &source);
    try target_window.panes.append(xm.allocator, &target);
    source_window.active = &source;
    target_window.active = &target;

    setGridLineText(source.base.grid, 0, "alpha");
    setGridLineText(source.base.grid, 1, "beta");

    var args = args_mod.Arguments.init(xm.allocator);
    defer args.deinit();

    const wme = enterMode(&target, &source, &args);
    try std.testing.expectEqual(&window_copy_mode, wme.mode);
    try std.testing.expect(screen.screen_alternate_active(&target));
    {
        const captured = grid.string_cells(modeData(wme).backing.grid, 0, 6, .{ .trim_trailing_spaces = true });
        defer xm.allocator.free(captured);
        try std.testing.expectEqualStrings("alpha", captured);
    }

    setGridLineText(source.base.grid, 0, "omega");
    {
        const snap = grid.string_cells(modeData(wme).backing.grid, 0, 6, .{ .trim_trailing_spaces = true });
        defer xm.allocator.free(snap);
        try std.testing.expectEqualStrings("alpha", snap);
    }

    var refresh_args = args_mod.Arguments.init(xm.allocator);
    defer refresh_args.deinit();
    try refresh_args.values.append(xm.allocator, xm.xstrdup("refresh-from-pane"));
    copyModeCommand(wme, null, undefined, undefined, @ptrCast(&refresh_args), null);

    {
        const refreshed = grid.string_cells(modeData(wme).backing.grid, 0, 6, .{ .trim_trailing_spaces = true });
        defer xm.allocator.free(refreshed);
        try std.testing.expectEqualStrings("omega", refreshed);
    }
}

test "window-copy navigation commands move through a taller source snapshot" {
    const source_grid = grid.grid_create(6, 4, 0);
    defer grid.grid_free(source_grid);
    const target_grid = grid.grid_create(6, 2, 0);
    defer grid.grid_free(target_grid);
    const source_screen = screen.screen_init(6, 4, 0);
    defer {
        screen.screen_free(source_screen);
        xm.allocator.destroy(source_screen);
    }
    const target_screen = screen.screen_init(6, 2, 0);
    defer {
        screen.screen_free(target_screen);
        xm.allocator.destroy(target_screen);
    }

    var source_window = T.Window{
        .id = 10,
        .name = xm.xstrdup("copy-source-nav"),
        .sx = 6,
        .sy = 4,
        .options = undefined,
    };
    defer xm.allocator.free(source_window.name);
    defer source_window.panes.deinit(xm.allocator);
    defer source_window.last_panes.deinit(xm.allocator);
    defer source_window.winlinks.deinit(xm.allocator);

    var target_window = T.Window{
        .id = 11,
        .name = xm.xstrdup("copy-target-nav"),
        .sx = 6,
        .sy = 2,
        .options = undefined,
    };
    defer xm.allocator.free(target_window.name);
    defer target_window.panes.deinit(xm.allocator);
    defer target_window.last_panes.deinit(xm.allocator);
    defer target_window.winlinks.deinit(xm.allocator);

    var source = T.WindowPane{
        .id = 12,
        .window = &source_window,
        .options = undefined,
        .sx = 6,
        .sy = 4,
        .screen = source_screen,
        .base = .{ .grid = source_grid, .rlower = 3 },
    };
    defer window_mode_runtime.resetModeAll(&source);

    var target = T.WindowPane{
        .id = 13,
        .window = &target_window,
        .options = undefined,
        .sx = 6,
        .sy = 2,
        .screen = target_screen,
        .base = .{ .grid = target_grid, .rlower = 1 },
    };
    defer window_mode_runtime.resetModeAll(&target);

    try source_window.panes.append(xm.allocator, &source);
    try target_window.panes.append(xm.allocator, &target);
    source_window.active = &source;
    target_window.active = &target;

    setGridLineText(source.base.grid, 0, "one");
    setGridLineText(source.base.grid, 1, "two");
    setGridLineText(source.base.grid, 2, "tri");
    setGridLineText(source.base.grid, 3, "for");

    var args = args_mod.Arguments.init(xm.allocator);
    defer args.deinit();
    const wme = enterMode(&target, &source, &args);

    var bottom_args = args_mod.Arguments.init(xm.allocator);
    defer bottom_args.deinit();
    try bottom_args.values.append(xm.allocator, xm.xstrdup("history-bottom"));
    copyModeCommand(wme, null, undefined, undefined, @ptrCast(&bottom_args), null);
    try std.testing.expectEqual(@as(u32, 2), modeData(wme).top);
    try std.testing.expectEqual(@as(u32, 1), modeData(wme).cy);

    var top_args = args_mod.Arguments.init(xm.allocator);
    defer top_args.deinit();
    try top_args.values.append(xm.allocator, xm.xstrdup("history-top"));
    copyModeCommand(wme, null, undefined, undefined, @ptrCast(&top_args), null);
    try std.testing.expectEqual(@as(u32, 0), modeData(wme).top);
    try std.testing.expectEqual(@as(u32, 0), modeData(wme).cy);

    var page_args = args_mod.Arguments.init(xm.allocator);
    defer page_args.deinit();
    try page_args.values.append(xm.allocator, xm.xstrdup("page-down"));
    copyModeCommand(wme, null, undefined, undefined, @ptrCast(&page_args), null);
    try std.testing.expectEqual(@as(u32, 1), modeData(wme).top);
    try std.testing.expectEqual(@as(u32, 0), modeData(wme).cy);
}

test "unsupported window-copy commands surface a status message" {
    const opts_mod = @import("options.zig");
    var env = T.Environ.init(xm.allocator);
    defer env.deinit();

    opts_mod.global_options = opts_mod.options_create(null);
    defer opts_mod.options_free(opts_mod.global_options);
    opts_mod.global_s_options = opts_mod.options_create(null);
    defer opts_mod.options_free(opts_mod.global_s_options);
    opts_mod.global_w_options = opts_mod.options_create(null);
    defer opts_mod.options_free(opts_mod.global_w_options);
    opts_mod.options_default_all(opts_mod.global_options, T.OPTIONS_TABLE_SERVER);
    opts_mod.options_default_all(opts_mod.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts_mod.options_default_all(opts_mod.global_w_options, T.OPTIONS_TABLE_WINDOW);

    const source_grid = grid.grid_create(4, 1, 0);
    defer grid.grid_free(source_grid);
    const target_grid = grid.grid_create(4, 1, 0);
    defer grid.grid_free(target_grid);
    const source_screen = screen.screen_init(4, 1, 0);
    defer {
        screen.screen_free(source_screen);
        xm.allocator.destroy(source_screen);
    }
    const target_screen = screen.screen_init(4, 1, 0);
    defer {
        screen.screen_free(target_screen);
        xm.allocator.destroy(target_screen);
    }

    var source_window = T.Window{
        .id = 20,
        .name = xm.xstrdup("copy-source-unsupported"),
        .sx = 4,
        .sy = 1,
        .options = undefined,
    };
    defer xm.allocator.free(source_window.name);
    defer source_window.panes.deinit(xm.allocator);
    defer source_window.last_panes.deinit(xm.allocator);
    defer source_window.winlinks.deinit(xm.allocator);

    var target_window = T.Window{
        .id = 21,
        .name = xm.xstrdup("copy-target-unsupported"),
        .sx = 4,
        .sy = 1,
        .options = undefined,
    };
    defer xm.allocator.free(target_window.name);
    defer target_window.panes.deinit(xm.allocator);
    defer target_window.last_panes.deinit(xm.allocator);
    defer target_window.winlinks.deinit(xm.allocator);

    var source = T.WindowPane{
        .id = 22,
        .window = &source_window,
        .options = undefined,
        .sx = 4,
        .sy = 1,
        .screen = source_screen,
        .base = .{ .grid = source_grid, .rlower = 0 },
    };
    defer window_mode_runtime.resetModeAll(&source);

    var target = T.WindowPane{
        .id = 23,
        .window = &target_window,
        .options = undefined,
        .sx = 4,
        .sy = 1,
        .screen = target_screen,
        .base = .{ .grid = target_grid, .rlower = 0 },
    };
    defer window_mode_runtime.resetModeAll(&target);

    try source_window.panes.append(xm.allocator, &source);
    try target_window.panes.append(xm.allocator, &target);
    source_window.active = &source;
    target_window.active = &target;

    var args = args_mod.Arguments.init(xm.allocator);
    defer args.deinit();
    const wme = enterMode(&target, &source, &args);

    var client = T.Client{
        .name = "copy-mode-status-client",
        .environ = &env,
        .tty = undefined,
        .status = .{ .screen = undefined },
        .flags = T.CLIENT_ATTACHED,
    };
    client.tty = .{ .client = &client };
    defer if (client.message_string) |msg| xm.allocator.free(msg);

    var unsupported = args_mod.Arguments.init(xm.allocator);
    defer unsupported.deinit();
    try unsupported.values.append(xm.allocator, xm.xstrdup("begin-selection"));
    copyModeCommand(wme, &client, undefined, undefined, @ptrCast(&unsupported), null);

    try std.testing.expectEqualStrings("Copy-mode command not supported yet: begin-selection", client.message_string.?);
}
