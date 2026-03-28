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
const utf8 = @import("utf8.zig");
const window = @import("window.zig");
const window_mode_runtime = @import("window-mode-runtime.zig");
const xm = @import("xmalloc.zig");

const word_whitespace = "\t ";

const JumpType = enum {
    off,
    forward,
    backward,
    to_forward,
    to_backward,
};

const CopyModeData = struct {
    backing: *T.Screen,
    top: u32 = 0,
    cx: u32 = 0,
    cy: u32 = 0,
    jump_type: JumpType = .off,
    jump_char: T.Utf8Data = std.mem.zeroes(T.Utf8Data),
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

pub fn scrollToMouse(wp: *T.WindowPane, slider_mouse_pos: i32, mouse_y: u32, scroll_exit: bool) void {
    const wme = window.window_pane_mode(wp) orelse return;
    if (wme.mode != &window_copy_mode) return;
    if (slider_mouse_pos < 0) return;

    _ = window.window_set_active_pane(wp.window, wp, false);

    const data = modeData(wme);
    const backing_rows = rowCount(data.backing);
    const view_rows = viewRows(wp);
    if (backing_rows <= view_rows or view_rows == 0) {
        data.top = 0;
        data.cy = @min(data.cy, backingBottomVisibleRow(wme));
        redraw(wme);
        return;
    }

    const sb_height = wp.sy;
    if (sb_height == 0) return;

    var slider_height: u32 = @intFromFloat(
        @as(f64, @floatFromInt(sb_height)) *
            (@as(f64, @floatFromInt(view_rows)) / @as(f64, @floatFromInt(backing_rows))),
    );
    if (slider_height < 1) slider_height = 1;

    const max_slider_y = sb_height -| slider_height;
    const relative_mouse_y = @as(i32, @intCast(mouse_y)) - @as(i32, @intCast(wp.yoff));
    const unclamped_slider_y = relative_mouse_y - slider_mouse_pos;
    const slider_y: u32 = if (unclamped_slider_y <= 0)
        0
    else
        @min(@as(u32, @intCast(unclamped_slider_y)), max_slider_y);

    const max_top = maxTop(data.backing, wp);
    data.top = if (max_slider_y == 0)
        0
    else
        @intCast((@as(u64, slider_y) * max_top + (max_slider_y / 2)) / max_slider_y);

    const max_visible = backingBottomVisibleRow(wme);
    if (data.cy > max_visible) data.cy = max_visible;
    clampCursorX(wme);

    if (scroll_exit and absoluteCursorRow(wme) + 1 >= backing_rows and data.top == max_top) {
        _ = window_mode_runtime.resetMode(wp);
        return;
    }
    redraw(wme);
}

pub fn startDrag(client: ?*T.Client, mouse: *const T.MouseEvent) void {
    const cl = client orelse return;
    const wp = resolveMousePane(mouse) orelse return;
    const wme = window.window_pane_mode(wp) orelse return;
    if (wme.mode != &window_copy_mode) return;

    updateCursorFromMouse(wme, mouse, true);
    cl.tty.mouse_drag_update = dragUpdate;
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
            if (scrollViewportDownLines(wme, 3, modeData(wme).scroll_exit)) {
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
    session: *T.Session,
    _wl: *T.Winlink,
    raw_args: *const anyopaque,
    _mouse: ?*const T.MouseEvent,
) void {
    _ = _wl;

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
    if (std.mem.eql(u8, command, "scroll-to-mouse")) {
        if (client) |cl| {
            if (_mouse) |mouse|
                scrollToMouse(wme.wp, cl.tty.mouse_slider_mpos, mouse.y, args.has('e'));
        }
        wme.prefix = 1;
        return;
    }

    if (std.mem.eql(u8, command, "cursor-left")) {
        moveCursorX(wme, -@as(i32, @intCast(count)));
    } else if (std.mem.eql(u8, command, "cursor-right")) {
        moveCursorX(wme, @intCast(count));
    } else if (std.mem.eql(u8, command, "jump-again")) {
        repeatJump(wme, modeData(wme).jump_type);
    } else if (std.mem.eql(u8, command, "jump-reverse")) {
        repeatJump(wme, reverseJumpType(modeData(wme).jump_type));
    } else if (std.mem.eql(u8, command, "jump-backward")) {
        if (args.value_at(1)) |arg|
            if (setJumpCharacter(modeData(wme), .backward, arg))
                repeatJump(wme, .backward);
    } else if (std.mem.eql(u8, command, "jump-forward")) {
        if (args.value_at(1)) |arg|
            if (setJumpCharacter(modeData(wme), .forward, arg))
                repeatJump(wme, .forward);
    } else if (std.mem.eql(u8, command, "jump-to-backward")) {
        if (args.value_at(1)) |arg|
            if (setJumpCharacter(modeData(wme), .to_backward, arg))
                repeatJump(wme, .to_backward);
    } else if (std.mem.eql(u8, command, "jump-to-forward")) {
        if (args.value_at(1)) |arg|
            if (setJumpCharacter(modeData(wme), .to_forward, arg))
                repeatJump(wme, .to_forward);
    } else if (std.mem.eql(u8, command, "next-space")) {
        var remaining = count;
        while (remaining > 0) : (remaining -= 1) cursorNextWord(wme, "");
    } else if (std.mem.eql(u8, command, "next-space-end")) {
        var remaining = count;
        while (remaining > 0) : (remaining -= 1) cursorNextWordEnd(wme, "");
    } else if (std.mem.eql(u8, command, "next-word")) {
        const separators = opts.options_get_string(session.options, "word-separators");
        var remaining = count;
        while (remaining > 0) : (remaining -= 1) cursorNextWord(wme, separators);
    } else if (std.mem.eql(u8, command, "next-word-end")) {
        const separators = opts.options_get_string(session.options, "word-separators");
        var remaining = count;
        while (remaining > 0) : (remaining -= 1) cursorNextWordEnd(wme, separators);
    } else if (std.mem.eql(u8, command, "previous-space")) {
        var remaining = count;
        while (remaining > 0) : (remaining -= 1) cursorPreviousWord(wme, "", true);
    } else if (std.mem.eql(u8, command, "previous-word")) {
        const separators = opts.options_get_string(session.options, "word-separators");
        var remaining = count;
        while (remaining > 0) : (remaining -= 1) cursorPreviousWord(wme, separators, true);
    } else if (std.mem.eql(u8, command, "cursor-up")) {
        scrollLines(wme, -@as(i32, @intCast(count)));
    } else if (std.mem.eql(u8, command, "cursor-down")) {
        cursorDownLines(wme, count);
    } else if (std.mem.eql(u8, command, "cursor-down-and-cancel")) {
        if (cursorDownAndCancel(wme, count)) {
            _ = window_mode_runtime.resetMode(wme.wp);
            return;
        }
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
    } else if (std.mem.eql(u8, command, "page-down-and-cancel")) {
        var remaining = count;
        while (remaining > 0) : (remaining -= 1) {
            if (pageDownMode(wme, false, true)) {
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
    } else if (std.mem.eql(u8, command, "halfpage-down-and-cancel")) {
        var remaining = count;
        while (remaining > 0) : (remaining -= 1) {
            if (pageDownMode(wme, true, true)) {
                _ = window_mode_runtime.resetMode(wme.wp);
                return;
            }
        }
    } else if (std.mem.eql(u8, command, "scroll-down")) {
        if (scrollViewportDownLines(wme, count, modeData(wme).scroll_exit)) {
            _ = window_mode_runtime.resetMode(wme.wp);
            return;
        }
    } else if (std.mem.eql(u8, command, "scroll-down-and-cancel")) {
        if (scrollViewportDownLines(wme, count, true)) {
            _ = window_mode_runtime.resetMode(wme.wp);
            return;
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
        cursorStartOfLine(wme);
    } else if (std.mem.eql(u8, command, "back-to-indentation")) {
        cursorBackToIndentation(wme);
    } else if (std.mem.eql(u8, command, "end-of-line")) {
        cursorEndOfLine(wme);
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

fn mouseAt(wp: *T.WindowPane, mouse: *const T.MouseEvent, last: bool) ?struct { x: u32, y: u32 } {
    const x = (if (last) mouse.lx else mouse.x) + mouse.ox;
    var y = (if (last) mouse.ly else mouse.y) + mouse.oy;

    if (mouse.statusat == 0 and y >= mouse.statuslines)
        y -= mouse.statuslines;

    if (x < wp.xoff or x >= wp.xoff + wp.sx) return null;
    if (y < wp.yoff or y >= wp.yoff + wp.sy) return null;

    return .{
        .x = x - wp.xoff,
        .y = y - wp.yoff,
    };
}

fn updateCursorFromMouse(wme: *T.WindowModeEntry, mouse: *const T.MouseEvent, last: bool) void {
    const point = mouseAt(wme.wp, mouse, last) orelse return;
    const data = modeData(wme);
    const absolute_row = data.top + point.y;
    setAbsoluteCursorRow(wme, absolute_row);
    data.cx = point.x;
    clampCursorX(wme);
}

fn dragUpdate(client: *T.Client, mouse: *T.MouseEvent) void {
    _ = client;
    const wp = resolveMousePane(mouse) orelse return;
    const wme = window.window_pane_mode(wp) orelse return;
    if (wme.mode != &window_copy_mode) return;

    updateCursorFromMouse(wme, mouse, false);
    redraw(wme);
}

fn resolveMousePane(mouse: *const T.MouseEvent) ?*T.WindowPane {
    if (mouse_runtime.cmd_mouse_pane(mouse, null, null)) |wp| return wp;
    if (mouse.wp == -1) return null;
    const pane_id = std.math.cast(u32, mouse.wp) orelse return null;
    return window.window_pane_find_by_id(pane_id);
}

fn repeatCount(wme: *T.WindowModeEntry) u32 {
    return if (wme.prefix == 0) 1 else wme.prefix;
}

fn copyModeUsesViKeys(wme: *T.WindowModeEntry) bool {
    return opts.options_get_number(wme.wp.window.options, "mode-keys") == T.MODEKEY_VI;
}

fn setJumpCharacter(data: *CopyModeData, jump_type: JumpType, text: []const u8) bool {
    if (text.len == 0) return false;

    const cells = utf8.utf8_fromcstr(text);
    defer xm.allocator.free(cells);

    if (cells.len == 0 or cells[0].isEmpty()) return false;
    data.jump_type = jump_type;
    data.jump_char = cells[0];
    return true;
}

fn reverseJumpType(jump_type: JumpType) JumpType {
    return switch (jump_type) {
        .forward => .backward,
        .backward => .forward,
        .to_forward => .to_backward,
        .to_backward => .to_forward,
        .off => .off,
    };
}

fn repeatJump(wme: *T.WindowModeEntry, jump_type: JumpType) void {
    const data = modeData(wme);
    if (jump_type == .off or data.jump_char.isEmpty()) return;

    var remaining = repeatCount(wme);
    while (remaining > 0) : (remaining -= 1) {
        switch (jump_type) {
            .forward => cursorJump(wme),
            .backward => cursorJumpBack(wme),
            .to_forward => cursorJumpTo(wme),
            .to_backward => cursorJumpToBack(wme),
            .off => return,
        }
    }
}

fn startMotionReader(wme: *T.WindowModeEntry, gr: *T.GridReader) bool {
    if (rowCount(modeData(wme).backing) == 0) return false;
    grid.grid_reader_start(gr, modeData(wme).backing.grid, modeData(wme).cx, absoluteCursorRow(wme));
    return true;
}

fn applyMotionReader(wme: *T.WindowModeEntry, gr: *const T.GridReader) void {
    var cx: u32 = 0;
    var cy: u32 = 0;
    grid.grid_reader_get_cursor(gr, &cx, &cy);
    setAbsoluteCursorRow(wme, cy);
    modeData(wme).cx = cx;
    clampCursorX(wme);
}

fn cursorNextWord(wme: *T.WindowModeEntry, separators: []const u8) void {
    var gr: T.GridReader = undefined;
    if (!startMotionReader(wme, &gr)) return;

    grid.grid_reader_cursor_next_word(&gr, separators);
    applyMotionReader(wme, &gr);
}

fn cursorJump(wme: *T.WindowModeEntry) void {
    var gr: T.GridReader = undefined;
    if (!startMotionReader(wme, &gr)) return;

    gr.cx = modeData(wme).cx + 1;
    if (!grid.grid_reader_cursor_jump(&gr, &modeData(wme).jump_char)) return;
    applyMotionReader(wme, &gr);
}

fn cursorJumpBack(wme: *T.WindowModeEntry) void {
    var gr: T.GridReader = undefined;
    if (!startMotionReader(wme, &gr)) return;

    grid.grid_reader_cursor_left(&gr, false);
    if (!grid.grid_reader_cursor_jump_back(&gr, &modeData(wme).jump_char)) return;
    applyMotionReader(wme, &gr);
}

fn cursorJumpTo(wme: *T.WindowModeEntry) void {
    var gr: T.GridReader = undefined;
    if (!startMotionReader(wme, &gr)) return;

    gr.cx = modeData(wme).cx + 2;
    if (!grid.grid_reader_cursor_jump(&gr, &modeData(wme).jump_char)) return;
    grid.grid_reader_cursor_left(&gr, true);
    applyMotionReader(wme, &gr);
}

fn cursorJumpToBack(wme: *T.WindowModeEntry) void {
    var gr: T.GridReader = undefined;
    if (!startMotionReader(wme, &gr)) return;

    grid.grid_reader_cursor_left(&gr, false);
    grid.grid_reader_cursor_left(&gr, false);
    if (!grid.grid_reader_cursor_jump_back(&gr, &modeData(wme).jump_char)) return;
    grid.grid_reader_cursor_right(&gr, true, false);
    applyMotionReader(wme, &gr);
}

fn cursorNextWordEnd(wme: *T.WindowModeEntry, separators: []const u8) void {
    var gr: T.GridReader = undefined;
    if (!startMotionReader(wme, &gr)) return;

    if (copyModeUsesViKeys(wme)) {
        if (grid.grid_reader_in_set(&gr, word_whitespace) == 0)
            grid.grid_reader_cursor_right(&gr, false, false);
        grid.grid_reader_cursor_next_word_end(&gr, separators);
        grid.grid_reader_cursor_left(&gr, true);
    } else {
        grid.grid_reader_cursor_next_word_end(&gr, separators);
    }
    applyMotionReader(wme, &gr);
}

fn cursorPreviousWord(wme: *T.WindowModeEntry, separators: []const u8, already: bool) void {
    var gr: T.GridReader = undefined;
    if (!startMotionReader(wme, &gr)) return;

    grid.grid_reader_cursor_previous_word(&gr, separators, already, !copyModeUsesViKeys(wme));
    applyMotionReader(wme, &gr);
}

fn cursorStartOfLine(wme: *T.WindowModeEntry) void {
    var gr: T.GridReader = undefined;
    if (!startMotionReader(wme, &gr)) return;

    grid.grid_reader_cursor_start_of_line(&gr, true);
    applyMotionReader(wme, &gr);
}

fn cursorBackToIndentation(wme: *T.WindowModeEntry) void {
    var gr: T.GridReader = undefined;
    if (!startMotionReader(wme, &gr)) return;

    grid.grid_reader_cursor_back_to_indentation(&gr);
    applyMotionReader(wme, &gr);
}

fn cursorEndOfLine(wme: *T.WindowModeEntry) void {
    var gr: T.GridReader = undefined;
    if (!startMotionReader(wme, &gr)) return;

    grid.grid_reader_cursor_end_of_line(&gr, true, false);
    applyMotionReader(wme, &gr);
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
        cursorDownLines(wme, @intCast(delta));
    }
    clampCursorX(wme);
}

fn cursorDownLines(wme: *T.WindowModeEntry, count: u32) void {
    const data = modeData(wme);
    const backing_rows = rowCount(data.backing);
    if (backing_rows == 0) return;

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
}

fn cursorDownAndCancel(wme: *T.WindowModeEntry, count: u32) bool {
    const data = modeData(wme);
    const start_top = data.top;
    const start_cy = data.cy;

    cursorDownLines(wme, count);
    return data.top == start_top and data.cy == start_cy and data.top == maxTop(data.backing, wme.wp);
}

fn scrollViewportDownLines(wme: *T.WindowModeEntry, count: u32, scroll_exit: bool) bool {
    const data = modeData(wme);
    const backing_rows = rowCount(data.backing);
    if (backing_rows == 0) return false;

    const max_top = maxTop(data.backing, wme.wp);
    const advance = @min(count, max_top - data.top);
    data.top += advance;

    const max_visible = backingBottomVisibleRow(wme);
    if (data.cy > max_visible) data.cy = max_visible;
    clampCursorX(wme);
    return scroll_exit and data.top == max_top;
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
    return scroll_exit and data.top == max_top;
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

fn runCopyModeTestCommand(wme: *T.WindowModeEntry, command: []const u8) !void {
    return runCopyModeTestCommandArgs(wme, null, &.{command});
}

fn runCopyModeTestCommandWithSession(wme: *T.WindowModeEntry, session: *T.Session, command: []const u8) !void {
    return runCopyModeTestCommandArgs(wme, session, &.{command});
}

fn runCopyModeTestCommandArgs(wme: *T.WindowModeEntry, session: ?*T.Session, values: []const []const u8) !void {
    var args = args_mod.Arguments.init(xm.allocator);
    defer args.deinit();
    for (values) |value|
        try args.values.append(xm.allocator, xm.xstrdup(value));
    copyModeCommand(wme, null, if (session) |s| s else undefined, undefined, @ptrCast(&args), null);
}

fn initWindowCopyTestGlobals() void {
    const sess = @import("session.zig");

    sess.session_init_globals(xm.allocator);
    window.window_init_globals(xm.allocator);
}

test "window-copy snapshots the source pane and refresh-from-pane updates it" {
    initWindowCopyTestGlobals();

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
    initWindowCopyTestGlobals();

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

test "window-copy wrapped line motions follow the shared grid reader" {
    initWindowCopyTestGlobals();

    const source_grid = grid.grid_create(5, 2, 0);
    defer grid.grid_free(source_grid);
    const target_grid = grid.grid_create(5, 2, 0);
    defer grid.grid_free(target_grid);
    const source_screen = screen.screen_init(5, 2, 0);
    defer {
        screen.screen_free(source_screen);
        xm.allocator.destroy(source_screen);
    }
    const target_screen = screen.screen_init(5, 2, 0);
    defer {
        screen.screen_free(target_screen);
        xm.allocator.destroy(target_screen);
    }

    var window_ = T.Window{
        .id = 14,
        .name = xm.xstrdup("copy-window-wrapped"),
        .sx = 5,
        .sy = 2,
        .options = undefined,
    };
    defer xm.allocator.free(window_.name);
    defer window_.panes.deinit(xm.allocator);
    defer window_.last_panes.deinit(xm.allocator);
    defer window_.winlinks.deinit(xm.allocator);

    var source = T.WindowPane{
        .id = 15,
        .window = &window_,
        .options = undefined,
        .sx = 5,
        .sy = 2,
        .screen = source_screen,
        .base = .{ .grid = source_grid, .rlower = 1 },
    };
    defer window_mode_runtime.resetModeAll(&source);

    var target = T.WindowPane{
        .id = 16,
        .window = &window_,
        .options = undefined,
        .sx = 5,
        .sy = 2,
        .screen = target_screen,
        .base = .{ .grid = target_grid, .rlower = 1 },
    };
    defer window_mode_runtime.resetModeAll(&target);

    try window_.panes.append(xm.allocator, &source);
    try window_.panes.append(xm.allocator, &target);
    window_.active = &target;

    grid.set_ascii(source.base.grid, 0, 0, ' ');
    grid.set_ascii(source.base.grid, 0, 1, ' ');
    grid.set_ascii(source.base.grid, 0, 2, 'a');
    grid.set_ascii(source.base.grid, 0, 3, 'b');
    source.base.grid.linedata[0].flags |= T.GRID_LINE_WRAPPED;
    grid.set_ascii(source.base.grid, 1, 0, ' ');
    grid.set_ascii(source.base.grid, 1, 1, 'c');

    var args = args_mod.Arguments.init(xm.allocator);
    defer args.deinit();
    const wme = enterMode(&target, &source, &args);

    modeData(wme).cx = 1;
    modeData(wme).cy = 1;
    try runCopyModeTestCommand(wme, "back-to-indentation");
    try std.testing.expectEqual(@as(u32, 2), modeData(wme).cx);
    try std.testing.expectEqual(@as(u32, 0), absoluteCursorRow(wme));

    modeData(wme).cx = 1;
    modeData(wme).cy = 1;
    try runCopyModeTestCommand(wme, "start-of-line");
    try std.testing.expectEqual(@as(u32, 0), modeData(wme).cx);
    try std.testing.expectEqual(@as(u32, 0), absoluteCursorRow(wme));

    modeData(wme).cx = 0;
    modeData(wme).cy = 0;
    try runCopyModeTestCommand(wme, "end-of-line");
    try std.testing.expectEqual(@as(u32, 1), modeData(wme).cx);
    try std.testing.expectEqual(@as(u32, 1), absoluteCursorRow(wme));
}

test "window-copy word and space motions use session separators and mode keys" {
    const opts_mod = @import("options.zig");

    initWindowCopyTestGlobals();

    opts_mod.global_options = opts_mod.options_create(null);
    defer opts_mod.options_free(opts_mod.global_options);
    opts_mod.global_s_options = opts_mod.options_create(null);
    defer opts_mod.options_free(opts_mod.global_s_options);
    opts_mod.global_w_options = opts_mod.options_create(null);
    defer opts_mod.options_free(opts_mod.global_w_options);
    opts_mod.options_default_all(opts_mod.global_options, T.OPTIONS_TABLE_SERVER);
    opts_mod.options_default_all(opts_mod.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts_mod.options_default_all(opts_mod.global_w_options, T.OPTIONS_TABLE_WINDOW);

    const source_grid = grid.grid_create(14, 1, 0);
    defer grid.grid_free(source_grid);
    const target_grid = grid.grid_create(14, 1, 0);
    defer grid.grid_free(target_grid);
    const source_screen = screen.screen_init(14, 1, 0);
    defer {
        screen.screen_free(source_screen);
        xm.allocator.destroy(source_screen);
    }
    const target_screen = screen.screen_init(14, 1, 0);
    defer {
        screen.screen_free(target_screen);
        xm.allocator.destroy(target_screen);
    }

    var env = T.Environ.init(xm.allocator);
    defer env.deinit();

    const session_options = opts_mod.options_create(opts_mod.global_s_options);
    defer opts_mod.options_free(session_options);
    opts_mod.options_set_string(session_options, false, "word-separators", ",");

    var session = T.Session{
        .id = 60,
        .name = xm.xstrdup("copy-word-session"),
        .cwd = "/",
        .lastw = .{},
        .windows = std.AutoHashMap(i32, *T.Winlink).init(xm.allocator),
        .options = session_options,
        .environ = &env,
    };
    defer xm.allocator.free(session.name);
    defer session.lastw.deinit(xm.allocator);
    defer session.windows.deinit();

    var window_ = T.Window{
        .id = 61,
        .name = xm.xstrdup("copy-word-window"),
        .sx = 14,
        .sy = 1,
        .options = opts_mod.options_create(opts_mod.global_w_options),
    };
    defer xm.allocator.free(window_.name);
    defer opts_mod.options_free(window_.options);
    defer window_.panes.deinit(xm.allocator);
    defer window_.last_panes.deinit(xm.allocator);
    defer window_.winlinks.deinit(xm.allocator);

    var source = T.WindowPane{
        .id = 62,
        .window = &window_,
        .options = opts_mod.options_create(window_.options),
        .sx = 14,
        .sy = 1,
        .screen = source_screen,
        .base = .{ .grid = source_grid, .rlower = 0 },
    };
    defer opts_mod.options_free(source.options);
    defer window_mode_runtime.resetModeAll(&source);

    var target = T.WindowPane{
        .id = 63,
        .window = &window_,
        .options = opts_mod.options_create(window_.options),
        .sx = 14,
        .sy = 1,
        .screen = target_screen,
        .base = .{ .grid = target_grid, .rlower = 0 },
    };
    defer opts_mod.options_free(target.options);
    defer window_mode_runtime.resetModeAll(&target);

    try window_.panes.append(xm.allocator, &source);
    try window_.panes.append(xm.allocator, &target);
    window_.active = &target;

    setGridLineText(source.base.grid, 0, "foo,  bar baz");

    var args = args_mod.Arguments.init(xm.allocator);
    defer args.deinit();
    const wme = enterMode(&target, &source, &args);

    try runCopyModeTestCommandWithSession(wme, &session, "next-word");
    try std.testing.expectEqual(@as(u32, 3), modeData(wme).cx);
    try std.testing.expectEqual(@as(u32, 0), absoluteCursorRow(wme));

    try runCopyModeTestCommandWithSession(wme, &session, "next-word");
    try std.testing.expectEqual(@as(u32, 6), modeData(wme).cx);

    try runCopyModeTestCommandWithSession(wme, &session, "previous-word");
    try std.testing.expectEqual(@as(u32, 3), modeData(wme).cx);

    modeData(wme).cx = 0;
    try runCopyModeTestCommandWithSession(wme, &session, "next-space");
    try std.testing.expectEqual(@as(u32, 6), modeData(wme).cx);

    try runCopyModeTestCommandWithSession(wme, &session, "previous-space");
    try std.testing.expectEqual(@as(u32, 0), modeData(wme).cx);

    modeData(wme).cx = 6;
    try runCopyModeTestCommandWithSession(wme, &session, "next-word-end");
    try std.testing.expectEqual(@as(u32, 9), modeData(wme).cx);

    opts_mod.options_set_number(window_.options, "mode-keys", T.MODEKEY_VI);

    modeData(wme).cx = 0;
    try runCopyModeTestCommandWithSession(wme, &session, "next-word-end");
    try std.testing.expectEqual(@as(u32, 2), modeData(wme).cx);

    modeData(wme).cx = 0;
    try runCopyModeTestCommandWithSession(wme, &session, "next-space-end");
    try std.testing.expectEqual(@as(u32, 3), modeData(wme).cx);
}

test "window-copy jump char motions remember direction and target character" {
    initWindowCopyTestGlobals();

    const source_grid = grid.grid_create(16, 1, 0);
    defer grid.grid_free(source_grid);
    const target_grid = grid.grid_create(16, 1, 0);
    defer grid.grid_free(target_grid);
    const source_screen = screen.screen_init(16, 1, 0);
    defer {
        screen.screen_free(source_screen);
        xm.allocator.destroy(source_screen);
    }
    const target_screen = screen.screen_init(16, 1, 0);
    defer {
        screen.screen_free(target_screen);
        xm.allocator.destroy(target_screen);
    }

    var window_ = T.Window{
        .id = 70,
        .name = xm.xstrdup("copy-window-jump"),
        .sx = 16,
        .sy = 1,
        .options = undefined,
    };
    defer xm.allocator.free(window_.name);
    defer window_.panes.deinit(xm.allocator);
    defer window_.last_panes.deinit(xm.allocator);
    defer window_.winlinks.deinit(xm.allocator);

    var source = T.WindowPane{
        .id = 71,
        .window = &window_,
        .options = undefined,
        .sx = 16,
        .sy = 1,
        .screen = source_screen,
        .base = .{ .grid = source_grid, .rlower = 0 },
    };
    defer window_mode_runtime.resetModeAll(&source);

    var target = T.WindowPane{
        .id = 72,
        .window = &window_,
        .options = undefined,
        .sx = 16,
        .sy = 1,
        .screen = target_screen,
        .base = .{ .grid = target_grid, .rlower = 0 },
    };
    defer window_mode_runtime.resetModeAll(&target);

    try window_.panes.append(xm.allocator, &source);
    try window_.panes.append(xm.allocator, &target);
    window_.active = &target;

    setGridLineText(source.base.grid, 0, "abc def ghi def");

    var args = args_mod.Arguments.init(xm.allocator);
    defer args.deinit();
    const wme = enterMode(&target, &source, &args);

    try runCopyModeTestCommandArgs(wme, null, &.{ "jump-forward", "d" });
    try std.testing.expectEqual(@as(u32, 4), modeData(wme).cx);
    try std.testing.expectEqual(JumpType.forward, modeData(wme).jump_type);
    try std.testing.expectEqual(@as(u8, 'd'), modeData(wme).jump_char.data[0]);

    try runCopyModeTestCommand(wme, "jump-again");
    try std.testing.expectEqual(@as(u32, 12), modeData(wme).cx);

    try runCopyModeTestCommand(wme, "jump-reverse");
    try std.testing.expectEqual(@as(u32, 4), modeData(wme).cx);

    modeData(wme).cx = 0;
    try runCopyModeTestCommandArgs(wme, null, &.{ "jump-to-forward", "d" });
    try std.testing.expectEqual(@as(u32, 3), modeData(wme).cx);
    try std.testing.expectEqual(JumpType.to_forward, modeData(wme).jump_type);

    modeData(wme).cx = 12;
    try runCopyModeTestCommandArgs(wme, null, &.{ "jump-to-backward", "d" });
    try std.testing.expectEqual(@as(u32, 5), modeData(wme).cx);
    try std.testing.expectEqual(JumpType.to_backward, modeData(wme).jump_type);

    modeData(wme).cx = 12;
    try runCopyModeTestCommandArgs(wme, null, &.{ "jump-backward", "d" });
    try std.testing.expectEqual(@as(u32, 4), modeData(wme).cx);
    try std.testing.expectEqual(JumpType.backward, modeData(wme).jump_type);
}

test "window-copy downward commands keep viewport scrolling separate from cancel variants" {
    initWindowCopyTestGlobals();

    const source_grid = grid.grid_create(6, 8, 0);
    defer grid.grid_free(source_grid);
    const target_grid = grid.grid_create(6, 5, 0);
    defer grid.grid_free(target_grid);
    const source_screen = screen.screen_init(6, 8, 0);
    defer {
        screen.screen_free(source_screen);
        xm.allocator.destroy(source_screen);
    }
    const target_screen = screen.screen_init(6, 5, 0);
    defer {
        screen.screen_free(target_screen);
        xm.allocator.destroy(target_screen);
    }

    var source_window = T.Window{
        .id = 50,
        .name = xm.xstrdup("copy-source-downward"),
        .sx = 6,
        .sy = 8,
        .options = undefined,
    };
    defer xm.allocator.free(source_window.name);
    defer source_window.panes.deinit(xm.allocator);
    defer source_window.last_panes.deinit(xm.allocator);
    defer source_window.winlinks.deinit(xm.allocator);

    var target_window = T.Window{
        .id = 51,
        .name = xm.xstrdup("copy-target-downward"),
        .sx = 6,
        .sy = 5,
        .options = undefined,
    };
    defer xm.allocator.free(target_window.name);
    defer target_window.panes.deinit(xm.allocator);
    defer target_window.last_panes.deinit(xm.allocator);
    defer target_window.winlinks.deinit(xm.allocator);

    var source = T.WindowPane{
        .id = 52,
        .window = &source_window,
        .options = undefined,
        .sx = 6,
        .sy = 8,
        .screen = source_screen,
        .base = .{ .grid = source_grid, .rlower = 7 },
    };
    defer window_mode_runtime.resetModeAll(&source);

    var target = T.WindowPane{
        .id = 53,
        .window = &target_window,
        .options = undefined,
        .sx = 6,
        .sy = 5,
        .screen = target_screen,
        .base = .{ .grid = target_grid, .rlower = 4 },
    };
    defer window_mode_runtime.resetModeAll(&target);

    try source_window.panes.append(xm.allocator, &source);
    try target_window.panes.append(xm.allocator, &target);
    source_window.active = &source;
    target_window.active = &target;

    var row: u32 = 0;
    while (row < 8) : (row += 1) {
        setGridLineText(source.base.grid, row, "line");
        source.base.grid.linedata[row].cellused = 4;
    }

    var args = args_mod.Arguments.init(xm.allocator);
    defer args.deinit();

    var wme = enterMode(&target, &source, &args);
    try runCopyModeTestCommand(wme, "scroll-down");
    try std.testing.expectEqual(@as(u32, 1), modeData(wme).top);
    try std.testing.expectEqual(@as(u32, 0), modeData(wme).cy);

    try runCopyModeTestCommand(wme, "cursor-down");
    try std.testing.expectEqual(@as(u32, 1), modeData(wme).top);
    try std.testing.expectEqual(@as(u32, 1), modeData(wme).cy);

    _ = window_mode_runtime.resetMode(&target);
    try std.testing.expect(window.window_pane_mode(&target) == null);

    wme = enterMode(&target, &source, &args);
    wme.prefix = 3;
    try runCopyModeTestCommand(wme, "scroll-down-and-cancel");
    try std.testing.expect(window.window_pane_mode(&target) == null);

    wme = enterMode(&target, &source, &args);
    try runCopyModeTestCommand(wme, "page-down-and-cancel");
    try std.testing.expect(window.window_pane_mode(&target) == null);

    wme = enterMode(&target, &source, &args);
    try runCopyModeTestCommand(wme, "halfpage-down");
    try std.testing.expectEqual(@as(u32, 2), modeData(wme).top);
    try runCopyModeTestCommand(wme, "halfpage-down-and-cancel");
    try std.testing.expect(window.window_pane_mode(&target) == null);

    wme = enterMode(&target, &source, &args);
    try runCopyModeTestCommand(wme, "history-bottom");
    try std.testing.expectEqual(@as(u32, 3), modeData(wme).top);
    try std.testing.expectEqual(@as(u32, 4), modeData(wme).cy);
    try runCopyModeTestCommand(wme, "cursor-down-and-cancel");
    try std.testing.expect(window.window_pane_mode(&target) == null);
}

test "window-copy startDrag keeps the cursor under reduced mouse drags" {
    const opts_mod = @import("options.zig");

    initWindowCopyTestGlobals();

    opts_mod.global_options = opts_mod.options_create(null);
    defer opts_mod.options_free(opts_mod.global_options);
    opts_mod.global_s_options = opts_mod.options_create(null);
    defer opts_mod.options_free(opts_mod.global_s_options);
    opts_mod.global_w_options = opts_mod.options_create(null);
    defer opts_mod.options_free(opts_mod.global_w_options);
    opts_mod.options_default_all(opts_mod.global_options, T.OPTIONS_TABLE_SERVER);
    opts_mod.options_default_all(opts_mod.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts_mod.options_default_all(opts_mod.global_w_options, T.OPTIONS_TABLE_WINDOW);
    window.window_init_globals(xm.allocator);

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

    var window_ = T.Window{
        .id = 30,
        .name = xm.xstrdup("copy-drag"),
        .sx = 6,
        .sy = 2,
        .options = opts_mod.options_create(opts_mod.global_w_options),
    };
    defer xm.allocator.free(window_.name);
    defer opts_mod.options_free(window_.options);
    defer window_.panes.deinit(xm.allocator);
    defer window_.last_panes.deinit(xm.allocator);
    defer window_.winlinks.deinit(xm.allocator);

    var source = T.WindowPane{
        .id = 31,
        .window = &window_,
        .options = opts_mod.options_create(window_.options),
        .sx = 6,
        .sy = 2,
        .screen = source_screen,
        .base = .{ .grid = source_grid, .rlower = 1 },
    };
    defer opts_mod.options_free(source.options);
    defer window_mode_runtime.resetModeAll(&source);

    var target = T.WindowPane{
        .id = 32,
        .window = &window_,
        .options = opts_mod.options_create(window_.options),
        .sx = 6,
        .sy = 2,
        .screen = target_screen,
        .base = .{ .grid = target_grid, .rlower = 1 },
    };
    defer opts_mod.options_free(target.options);
    defer window_mode_runtime.resetModeAll(&target);

    try window_.panes.append(xm.allocator, &source);
    try window_.panes.append(xm.allocator, &target);
    window_.active = &target;
    try window.all_window_panes.put(target.id, &target);
    defer _ = window.all_window_panes.remove(target.id);

    grid.set_ascii(source.base.grid, 1, 0, 'a');
    grid.set_ascii(source.base.grid, 1, 1, 'b');
    grid.set_ascii(source.base.grid, 1, 2, 'c');
    grid.set_ascii(source.base.grid, 1, 3, 'd');
    grid.set_ascii(source.base.grid, 1, 4, 'e');
    grid.set_ascii(source.base.grid, 0, 0, 'v');
    grid.set_ascii(source.base.grid, 0, 1, 'w');
    grid.set_ascii(source.base.grid, 0, 2, 'x');

    var args = args_mod.Arguments.init(xm.allocator);
    defer args.deinit();
    _ = enterMode(&target, &source, &args);

    var env = T.Environ.init(xm.allocator);
    defer env.deinit();

    var client = T.Client{
        .name = "copy-mode-drag-client",
        .environ = &env,
        .tty = undefined,
        .status = .{ .screen = undefined },
        .flags = T.CLIENT_ATTACHED,
    };
    client.tty = .{ .client = &client };

    var start_mouse = T.MouseEvent{
        .valid = true,
        .s = -1,
        .w = -1,
        .wp = @intCast(target.id),
        .x = 5,
        .y = 1,
        .lx = 4,
        .ly = 1,
    };
    startDrag(&client, &start_mouse);
    try std.testing.expect(client.tty.mouse_drag_update != null);
    try std.testing.expectEqual(@as(u32, 4), target.screen.cx);
    try std.testing.expectEqual(@as(u32, 1), target.screen.cy);

    var drag_mouse = T.MouseEvent{
        .valid = true,
        .s = -1,
        .w = -1,
        .wp = @intCast(target.id),
        .x = 2,
        .y = 0,
    };
    client.tty.mouse_drag_update.?(&client, &drag_mouse);
    try std.testing.expectEqual(@as(u32, 2), target.screen.cx);
    try std.testing.expectEqual(@as(u32, 0), target.screen.cy);
}

test "window-copy scrollToMouse maps the reduced viewport onto scrollbar drags" {
    const opts_mod = @import("options.zig");

    initWindowCopyTestGlobals();

    opts_mod.global_options = opts_mod.options_create(null);
    defer opts_mod.options_free(opts_mod.global_options);
    opts_mod.global_s_options = opts_mod.options_create(null);
    defer opts_mod.options_free(opts_mod.global_s_options);
    opts_mod.global_w_options = opts_mod.options_create(null);
    defer opts_mod.options_free(opts_mod.global_w_options);
    opts_mod.options_default_all(opts_mod.global_options, T.OPTIONS_TABLE_SERVER);
    opts_mod.options_default_all(opts_mod.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts_mod.options_default_all(opts_mod.global_w_options, T.OPTIONS_TABLE_WINDOW);

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

    var window_ = T.Window{
        .id = 40,
        .name = xm.xstrdup("copy-scroll"),
        .sx = 6,
        .sy = 2,
        .options = opts_mod.options_create(opts_mod.global_w_options),
    };
    defer xm.allocator.free(window_.name);
    defer opts_mod.options_free(window_.options);
    defer window_.panes.deinit(xm.allocator);
    defer window_.last_panes.deinit(xm.allocator);
    defer window_.winlinks.deinit(xm.allocator);

    var source = T.WindowPane{
        .id = 41,
        .window = &window_,
        .options = opts_mod.options_create(window_.options),
        .sx = 6,
        .sy = 4,
        .screen = source_screen,
        .base = .{ .grid = source_grid, .rlower = 3 },
    };
    defer opts_mod.options_free(source.options);
    defer window_mode_runtime.resetModeAll(&source);

    var target = T.WindowPane{
        .id = 42,
        .window = &window_,
        .options = opts_mod.options_create(window_.options),
        .sx = 6,
        .sy = 2,
        .screen = target_screen,
        .base = .{ .grid = target_grid, .rlower = 1 },
    };
    defer opts_mod.options_free(target.options);
    defer window_mode_runtime.resetModeAll(&target);

    try window_.panes.append(xm.allocator, &source);
    try window_.panes.append(xm.allocator, &target);
    window_.active = &source;

    var args = args_mod.Arguments.init(xm.allocator);
    defer args.deinit();
    const wme = enterMode(&target, &source, &args);
    try std.testing.expectEqual(@as(u32, 0), modeData(wme).top);

    scrollToMouse(&target, 0, 1, false);
    try std.testing.expectEqual(@as(u32, 2), modeData(wme).top);
    try std.testing.expectEqual(@as(u32, 0), target.screen.cy);

    scrollToMouse(&target, 0, 0, false);
    try std.testing.expectEqual(@as(u32, 0), modeData(wme).top);
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
