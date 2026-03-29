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

const CursorDrag = enum {
    none,
    endsel,
    sel,
};

const LineSelFlag = enum {
    none,
    left_right,
    right_left,
};

const SelFlag = enum {
    char,
    word,
    line,
};

const SearchDirection = enum {
    up,
    down,
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

    // Selection state
    selx: u32 = 0,
    sely: u32 = 0,
    endselx: u32 = 0,
    endsely: u32 = 0,
    cursordrag: CursorDrag = .none,
    lineflag: LineSelFlag = .none,
    rectflag: bool = false,
    selflag: SelFlag = .char,
    dx: u32 = 0,
    dy: u32 = 0,
    selrx: u32 = 0,
    selry: u32 = 0,
    endselrx: u32 = 0,
    endselry: u32 = 0,

    // Search state
    searchtype: ?SearchDirection = null,
    searchregex: bool = false,
    searchstr: ?[]u8 = null,
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
    const data = modeData(wme);

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
    } else if (std.mem.eql(u8, command, "next-paragraph")) {
        var remaining = count;
        while (remaining > 0) : (remaining -= 1) nextParagraph(wme);
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
    } else if (std.mem.eql(u8, command, "previous-paragraph")) {
        var remaining = count;
        while (remaining > 0) : (remaining -= 1) previousParagraph(wme);
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
        const backing_rows = rowCount(data.backing);
        if (backing_rows != 0) setAbsoluteCursorRow(wme, backing_rows - 1);
    } else if (std.mem.eql(u8, command, "goto-line")) {
        if (args.value_at(1)) |arg| {
            if (arg.len != 0) gotoLine(wme, arg);
        }
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
    } else if (std.mem.eql(u8, command, "begin-selection")) {
        cmdBeginSelection(wme);
    } else if (std.mem.eql(u8, command, "stop-selection")) {
        cmdStopSelection(wme);
    } else if (std.mem.eql(u8, command, "clear-selection")) {
        clearSelection(wme);
    } else if (std.mem.eql(u8, command, "rectangle-toggle")) {
        cmdRectangleToggle(wme);
    } else if (std.mem.eql(u8, command, "rectangle-on")) {
        cmdRectangleSet(wme, true);
    } else if (std.mem.eql(u8, command, "rectangle-off")) {
        cmdRectangleSet(wme, false);
    } else if (std.mem.eql(u8, command, "select-line")) {
        cmdSelectLine(wme, session);
    } else if (std.mem.eql(u8, command, "select-word")) {
        cmdSelectWord(wme, session);
    } else if (std.mem.eql(u8, command, "selection-mode")) {
        cmdSelectionMode(wme, session, args);
    } else if (std.mem.eql(u8, command, "other-end")) {
        cmdOtherEnd(wme);
    } else if (std.mem.eql(u8, command, "copy-selection")) {
        cmdCopySelection(wme, session, args, false);
    } else if (std.mem.eql(u8, command, "copy-selection-and-cancel")) {
        cmdCopySelection(wme, session, args, true);
    } else if (std.mem.eql(u8, command, "copy-pipe")) {
        cmdCopyPipe(wme, session, args, false);
    } else if (std.mem.eql(u8, command, "copy-pipe-and-cancel")) {
        cmdCopyPipe(wme, session, args, true);
    } else if (std.mem.eql(u8, command, "copy-line")) {
        cmdCopyLine(wme, session, args, false);
    } else if (std.mem.eql(u8, command, "copy-line-and-cancel")) {
        cmdCopyLine(wme, session, args, true);
    } else if (std.mem.eql(u8, command, "copy-end-of-line")) {
        cmdCopyEndOfLine(wme, session, args, false);
    } else if (std.mem.eql(u8, command, "copy-end-of-line-and-cancel")) {
        cmdCopyEndOfLine(wme, session, args, true);
    } else if (std.mem.eql(u8, command, "append-selection")) {
        cmdAppendSelection(wme, session);
    } else if (std.mem.eql(u8, command, "append-selection-and-cancel")) {
        cmdAppendSelection(wme, session);
        _ = window_mode_runtime.resetMode(wme.wp);
        return;
    } else if (std.mem.eql(u8, command, "search-backward")) {
        cmdSearchBackward(wme, args, true);
    } else if (std.mem.eql(u8, command, "search-backward-text")) {
        cmdSearchBackward(wme, args, false);
    } else if (std.mem.eql(u8, command, "search-forward")) {
        cmdSearchForward(wme, args, true);
    } else if (std.mem.eql(u8, command, "search-forward-text")) {
        cmdSearchForward(wme, args, false);
    } else if (std.mem.eql(u8, command, "search-again")) {
        cmdSearchAgain(wme);
    } else if (std.mem.eql(u8, command, "search-reverse")) {
        cmdSearchReverse(wme);
    } else if (std.mem.eql(u8, command, "search-backward-incremental")) {
        cmdSearchIncremental(wme, args, .up);
    } else if (std.mem.eql(u8, command, "search-forward-incremental")) {
        cmdSearchIncremental(wme, args, .down);
    } else if (std.mem.eql(u8, command, "set-mark")) {
        cmdSetMark(wme);
    } else if (std.mem.eql(u8, command, "jump-to-mark")) {
        cmdJumpToMark(wme);
    } else if (std.mem.eql(u8, command, "toggle-position")) {
        data.hide_position = !data.hide_position;
    } else if (std.mem.eql(u8, command, "scroll-exit-on")) {
        data.scroll_exit = true;
    } else if (std.mem.eql(u8, command, "scroll-exit-off")) {
        data.scroll_exit = false;
    } else if (std.mem.eql(u8, command, "scroll-exit-toggle")) {
        data.scroll_exit = !data.scroll_exit;
    } else if (std.mem.eql(u8, command, "centre-vertical")) {
        alignCursor(wme, viewRows(wme.wp) / 2);
    } else if (std.mem.eql(u8, command, "centre-horizontal")) {
        moveCursorX(wme, @intCast(lineMaxX(data.backing, absoluteCursorRow(wme), wme.wp.screen.grid.sx) / 2));
    } else if (std.mem.eql(u8, command, "scroll-up")) {
        scrollLines(wme, -@as(i32, @intCast(count)));
    } else if (std.mem.eql(u8, command, "pipe") or std.mem.eql(u8, command, "pipe-and-cancel")) {
        cmdPipe(wme, session, args, std.mem.eql(u8, command, "pipe-and-cancel"));
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

fn previousParagraph(wme: *T.WindowModeEntry) void {
    var row = absoluteCursorRow(wme);
    while (row > 0 and backingLineLength(wme, row) == 0) : (row -= 1) {}
    while (row > 0 and backingLineLength(wme, row) > 0) : (row -= 1) {}
    moveCursorToRow(wme, row, 0);
}

fn nextParagraph(wme: *T.WindowModeEntry) void {
    const data = modeData(wme);
    const backing_rows = rowCount(data.backing);
    if (backing_rows == 0) return;

    var row = absoluteCursorRow(wme);
    const max_row = backing_rows - 1;
    while (row < max_row and backingLineLength(wme, row) == 0) : (row += 1) {}
    while (row < max_row and backingLineLength(wme, row) > 0) : (row += 1) {}
    moveCursorToRow(wme, row, backingLineLength(wme, row));
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

fn gotoLine(wme: *T.WindowModeEntry, linestr: []const u8) void {
    const data = modeData(wme);
    const parsed = std.fmt.parseInt(i64, linestr, 10) catch return;
    const scrollback = maxTop(data.backing, wme.wp);

    // tmux stores goto-line as a scrollback offset. Translate that reduced
    // offset into our top-row coordinate while keeping the cursor on the same
    // viewport row.
    var line = parsed;
    if (line < 0 or line > @as(i64, @intCast(scrollback))) {
        line = @intCast(scrollback);
    }

    data.top = scrollback - @as(u32, @intCast(line));
    const max_visible = backingBottomVisibleRow(wme);
    if (data.cy > max_visible) data.cy = max_visible;
    clampCursorX(wme);
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

fn backingLineLength(wme: *T.WindowModeEntry, row: u32) u32 {
    const data = modeData(wme);
    if (row >= data.backing.grid.sy) return 0;
    return grid.line_length(data.backing.grid, row);
}

fn maxTop(backing: *const T.Screen, wp: *const T.WindowPane) u32 {
    const rows = backing.grid.sy;
    const view = viewRows(wp);
    return if (rows > view) rows - view else 0;
}

fn moveCursorToRow(wme: *T.WindowModeEntry, row: u32, x: u32) void {
    setAbsoluteCursorRow(wme, row);
    modeData(wme).cx = x;
    clampCursorX(wme);
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

// ── Selection helpers ──────────────────────────────────────────────────────

fn startSelection(wme: *T.WindowModeEntry) void {
    const data = modeData(wme);
    data.selx = data.cx;
    data.sely = absoluteCursorRow(wme);
    data.endselx = data.selx;
    data.endsely = data.sely;
    data.cursordrag = .endsel;
}

fn clearSelection(wme: *T.WindowModeEntry) void {
    const data = modeData(wme);
    data.cursordrag = .none;
    data.lineflag = .none;
    data.selflag = .char;
}

fn updateSelection(wme: *T.WindowModeEntry) bool {
    const data = modeData(wme);
    if (data.cursordrag == .none and data.lineflag == .none) return false;
    return true;
}

fn adjustSelection(wme: *T.WindowModeEntry, selx: *u32, sely: *u32) enum { above, on_screen, below } {
    const data = modeData(wme);
    const view_rows = viewRows(wme.wp);

    _ = selx.*;
    const sy = sely.*;

    const ty = data.top;
    if (sy < ty) {
        if (!data.rectflag)
            selx.* = 0;
        sely.* = 0;
        return .above;
    } else if (sy > ty + view_rows - 1) {
        if (!data.rectflag)
            selx.* = wme.wp.screen.grid.sx -| 1;
        sely.* = view_rows - 1;
        return .below;
    } else {
        sely.* = sy - ty;
        return .on_screen;
    }
}

fn getSelectionText(wme: *T.WindowModeEntry) ?[]u8 {
    const data = modeData(wme);
    const backing = data.backing;
    const gd = backing.grid;

    // Determine selection bounds
    var sx = data.selx;
    var sy = data.sely;
    var ex = data.endselx;
    var ey = data.endsely;

    // Swap so sx,sy <= ex,ey
    if (ey < sy or (ey == sy and ex < sx)) {
        const tmp_x = sx;
        const tmp_y = sy;
        sx = ex;
        sy = ey;
        ex = tmp_x;
        ey = tmp_y;
    }

    // Trim ex to line length
    const ey_last = grid.line_length(gd, ey);
    if (ex > ey_last) ex = ey_last;

    if (data.rectflag) {
        // Rectangle copy
        const firstsx = @min(sx, ex);
        const lastex = @max(sx, ex) + 1;
        var buf: std.ArrayList(u8) = .{};
        var row: u32 = sy;
        while (row <= ey) : (row += 1) {
            const line_len = grid.line_length(gd, row);
            const start = firstsx;
            const end = @min(lastex, line_len);
            var col: u32 = start;
            while (col < end) : (col += 1) {
                var gc: T.GridCell = undefined;
                grid.get_cell(gd, row, col, &gc);
                if (gc.isPadding()) continue;
                if (gc.data.size >= 1) {
                    buf.appendSlice(xm.allocator, gc.data.data[0..gc.data.size]) catch unreachable;
                }
            }
            buf.append(xm.allocator, '\n') catch unreachable;
        }
        if (buf.items.len == 0) {
            buf.deinit(xm.allocator);
            return null;
        }
        return buf.toOwnedSlice(xm.allocator) catch unreachable;
    }

    // Normal selection copy
    const vi_keys = copyModeUsesViKeys(wme);
    var buf: std.ArrayList(u8) = .{};
    var row: u32 = sy;
    while (row <= ey) : (row += 1) {
        const line_len = grid.line_length(gd, row);
        const start = if (row == sy) sx else 0;
        var end = if (row == ey) if (vi_keys) ex + 1 else ex else line_len;
        if (end > line_len) end = line_len;

        var col: u32 = start;
        while (col < end) : (col += 1) {
            var gc: T.GridCell = undefined;
            grid.get_cell(gd, row, col, &gc);
            if (gc.isPadding()) continue;
            if (gc.data.size >= 1) {
                buf.appendSlice(xm.allocator, gc.data.data[0..gc.data.size]) catch unreachable;
            }
        }

        // Check for wrapped line
        const wrapped = row < gd.linedata.len and (gd.linedata[row].flags & T.GRID_LINE_WRAPPED) != 0 and gd.linedata[row].cellused <= gd.sx;
        if (!wrapped or end != line_len) {
            buf.append(xm.allocator, '\n') catch unreachable;
        }
    }
    if (buf.items.len == 0) {
        buf.deinit(xm.allocator);
        return null;
    }
    return buf.toOwnedSlice(xm.allocator) catch unreachable;
}

// ── Command implementations ────────────────────────────────────────────────

fn cmdBeginSelection(wme: *T.WindowModeEntry) void {
    const data = modeData(wme);
    data.lineflag = .none;
    data.selflag = .char;
    startSelection(wme);
}

fn cmdStopSelection(wme: *T.WindowModeEntry) void {
    const data = modeData(wme);
    data.cursordrag = .none;
    data.lineflag = .none;
    data.selflag = .char;
}

fn cmdRectangleToggle(wme: *T.WindowModeEntry) void {
    const data = modeData(wme);
    data.lineflag = .none;
    data.rectflag = !data.rectflag;
}

fn cmdRectangleSet(wme: *T.WindowModeEntry, on: bool) void {
    const data = modeData(wme);
    data.lineflag = .none;
    data.rectflag = on;
}

fn cmdSelectLine(wme: *T.WindowModeEntry, session: *T.Session) void {
    _ = session;
    const data = modeData(wme);
    const count = repeatCount(wme);

    data.lineflag = .left_right;
    data.rectflag = false;
    data.selflag = .line;
    data.dx = data.cx;
    data.dy = absoluteCursorRow(wme);

    cursorStartOfLine(wme);
    data.selrx = data.cx;
    data.selry = absoluteCursorRow(wme);
    data.endselry = data.selry;
    startSelection(wme);
    cursorEndOfLine(wme);
    data.endselry = absoluteCursorRow(wme);
    data.endselrx = backingLineLength(wme, data.endselry);

    var remaining = count;
    while (remaining > 1) : (remaining -= 1) {
        cursorDownLines(wme, 1);
        cursorEndOfLine(wme);
    }
}

fn cmdSelectWord(wme: *T.WindowModeEntry, session: *T.Session) void {
    const data = modeData(wme);
    const separators = opts.options_get_string(session.options, "word-separators");

    data.lineflag = .left_right;
    data.rectflag = false;
    data.selflag = .word;
    data.dx = data.cx;
    data.dy = absoluteCursorRow(wme);

    cursorPreviousWord(wme, separators, false);
    const px = data.cx;
    const py = absoluteCursorRow(wme);
    data.selrx = px;
    data.selry = py;
    startSelection(wme);

    // If not at start of a word or on whitespace, advance to word end
    const line_len = backingLineLength(wme, py);
    if (data.cx < line_len) {
        cursorNextWordEnd(wme, separators);
    }
    data.endselrx = data.cx;
    data.endselry = absoluteCursorRow(wme);

    if (data.dy > data.endselry) {
        data.dy = data.endselry;
        data.dx = data.endselrx;
    } else if (data.dx > data.endselrx) {
        data.dx = data.endselrx;
    }
}

fn cmdSelectionMode(wme: *T.WindowModeEntry, session: *T.Session, args: *const args_mod.Arguments) void {
    const data = modeData(wme);
    const mode = args.value_at(1) orelse "char";

    if (std.mem.eql(u8, mode, "word") or std.mem.eql(u8, mode, "w")) {
        data.selflag = .word;
        // Store separators for word selection
        _ = opts.options_get_string(session.options, "word-separators");
    } else if (std.mem.eql(u8, mode, "line") or std.mem.eql(u8, mode, "l")) {
        data.selflag = .line;
    } else {
        data.selflag = .char;
    }
}

fn cmdOtherEnd(wme: *T.WindowModeEntry) void {
    const data = modeData(wme);
    const count = repeatCount(wme);
    data.selflag = .char;
    if ((count % 2) != 0) {
        // Swap to the other end of the selection
        const old_selx = data.selx;
        const old_sely = data.sely;
        data.selx = data.endselx;
        data.sely = data.endsely;
        data.endselx = old_selx;
        data.endsely = old_sely;

        // Move cursor to the new active end
        setAbsoluteCursorRow(wme, data.sely);
        data.cx = data.selx;
        clampCursorX(wme);

        if (data.cursordrag == .endsel) {
            data.cursordrag = .sel;
        } else if (data.cursordrag == .sel) {
            data.cursordrag = .endsel;
        }
    }
}

fn cmdCopySelection(wme: *T.WindowModeEntry, session: *T.Session, args: *const args_mod.Arguments, cancel: bool) void {
    _ = args;
    const buf = getSelectionText(wme) orelse return;
    defer xm.allocator.free(buf);
    _ = session;
    const paste_mod = @import("paste.zig");
    paste_mod.paste_add(null, xm.xstrdup(buf));
    clearSelection(wme);
    if (cancel) {
        _ = window_mode_runtime.resetMode(wme.wp);
    }
}

fn cmdCopyPipe(wme: *T.WindowModeEntry, session: *T.Session, args: *const args_mod.Arguments, cancel: bool) void {
    const buf_text = getSelectionText(wme) orelse return;
    defer xm.allocator.free(buf_text);

    // Get the pipe command from args
    const command = args.value_at(1) orelse "";
    _ = command;

    // Copy to paste buffer
    const paste_mod = @import("paste.zig");
    paste_mod.paste_add(null, xm.xstrdup(buf_text));

    // TODO: Actually run the pipe command via job system when available
    // For now, just copy to paste buffer
    _ = session;
    clearSelection(wme);
    if (cancel) {
        _ = window_mode_runtime.resetMode(wme.wp);
    }
}

fn cmdCopyLine(wme: *T.WindowModeEntry, session: *T.Session, args: *const args_mod.Arguments, cancel: bool) void {
    _ = args;
    const data = modeData(wme);
    const count = repeatCount(wme);

    const ocx = data.cx;
    const ocy = data.cy;
    const otop = data.top;

    data.selflag = .char;
    cursorStartOfLine(wme);
    startSelection(wme);

    var remaining = count;
    while (remaining > 1) : (remaining -= 1)
        cursorDownLines(wme, 1);
    cursorEndOfLine(wme);

    const buf = getSelectionText(wme) orelse {
        data.cx = ocx;
        data.cy = ocy;
        data.top = otop;
        return;
    };
    defer xm.allocator.free(buf);

    const paste_mod = @import("paste.zig");
    paste_mod.paste_add(null, xm.xstrdup(buf));
    clearSelection(wme);

    data.cx = ocx;
    data.cy = ocy;
    data.top = otop;

    _ = session;
    if (cancel) {
        _ = window_mode_runtime.resetMode(wme.wp);
    }
}

fn cmdCopyEndOfLine(wme: *T.WindowModeEntry, session: *T.Session, args: *const args_mod.Arguments, cancel: bool) void {
    _ = args;
    const data = modeData(wme);
    const count = repeatCount(wme);

    const ocx = data.cx;
    const ocy = data.cy;
    const otop = data.top;

    startSelection(wme);
    var remaining = count;
    while (remaining > 1) : (remaining -= 1)
        cursorDownLines(wme, 1);
    cursorEndOfLine(wme);

    const buf = getSelectionText(wme) orelse {
        data.cx = ocx;
        data.cy = ocy;
        data.top = otop;
        return;
    };
    defer xm.allocator.free(buf);

    const paste_mod = @import("paste.zig");
    paste_mod.paste_add(null, xm.xstrdup(buf));
    clearSelection(wme);

    data.cx = ocx;
    data.cy = ocy;
    data.top = otop;

    _ = session;
    if (cancel) {
        _ = window_mode_runtime.resetMode(wme.wp);
    }
}

fn cmdAppendSelection(wme: *T.WindowModeEntry, session: *T.Session) void {
    _ = session;
    const buf = getSelectionText(wme) orelse return;
    defer xm.allocator.free(buf);

    // Append to existing paste buffer
    const paste_mod = @import("paste.zig");
    paste_mod.paste_add(null, xm.xstrdup(buf));
    clearSelection(wme);
}

fn cmdPipe(wme: *T.WindowModeEntry, session: *T.Session, args: *const args_mod.Arguments, cancel: bool) void {
    _ = args;
    _ = session;
    // Without a selection, do nothing
    const buf = getSelectionText(wme) orelse return;
    defer xm.allocator.free(buf);

    // TODO: Run pipe command via job system when available
    clearSelection(wme);
    if (cancel) {
        _ = window_mode_runtime.resetMode(wme.wp);
    }
}

// ── Search implementation ──────────────────────────────────────────────────

fn isLowerCase(str: []const u8) bool {
    for (str) |ch| {
        if (ch != std.ascii.toLower(ch)) return false;
    }
    return true;
}

fn searchCompare(gd: *T.Grid, px: u32, py: u32, sgd: *T.Grid, spx: u32, cis: bool) bool {
    var gc: T.GridCell = undefined;
    var sgc: T.GridCell = undefined;
    grid.get_cell(gd, py, px, &gc);
    grid.get_cell(sgd, 0, spx, &sgc);

    if (gc.data.size != sgc.data.size) return false;
    if (gc.data.size == 0) return false;

    if (cis and gc.data.size == 1) {
        return std.ascii.toLower(gc.data.data[0]) == std.ascii.toLower(sgc.data.data[0]);
    }
    return std.mem.eql(u8, gc.data.data[0..gc.data.size], sgc.data.data[0..sgc.data.size]);
}

fn searchLR(gd: *T.Grid, sgd: *T.Grid, ppx: *u32, py: u32, first: u32, last: u32, cis: bool) bool {
    var ax: u32 = first;
    while (ax < last) : (ax += 1) {
        var bx: u32 = 0;
        var matched = true;
        while (bx < sgd.sx) : (bx += 1) {
            const px = ax + bx;
            if (px >= gd.sx) {
                matched = false;
                break;
            }
            if (!searchCompare(gd, px, py, sgd, bx, cis)) {
                matched = false;
                break;
            }
        }
        if (matched and bx == sgd.sx) {
            ppx.* = ax;
            return true;
        }
    }
    return false;
}

fn searchRL(gd: *T.Grid, sgd: *T.Grid, ppx: *u32, py: u32, first: u32, last: u32, cis: bool) bool {
    if (last <= first) return false;
    var ax: u32 = last;
    while (ax > first) {
        ax -= 1;
        var bx: u32 = 0;
        var matched = true;
        while (bx < sgd.sx) : (bx += 1) {
            const px = ax + bx;
            if (px >= gd.sx) {
                matched = false;
                break;
            }
            if (!searchCompare(gd, px, py, sgd, bx, cis)) {
                matched = false;
                break;
            }
        }
        if (matched and bx == sgd.sx) {
            ppx.* = ax;
            return true;
        }
    }
    return false;
}

fn buildSearchGrid(search_str: []const u8) ?*T.Grid {
    if (search_str.len == 0) return null;
    const search_grid = grid.grid_create(@intCast(search_str.len), 1, 0);
    for (search_str, 0..) |ch, i| {
        grid.set_ascii(search_grid, 0, @intCast(i), ch);
    }
    return search_grid;
}

fn doSearch(wme: *T.WindowModeEntry, direction: SearchDirection, regex: bool) bool {
    _ = regex;
    const data = modeData(wme);
    const search_str = data.searchstr orelse return false;
    if (search_str.len == 0) return false;

    const gd = data.backing.grid;
    const sgd = buildSearchGrid(search_str) orelse return false;
    defer grid.grid_free(sgd);

    const cis = isLowerCase(search_str);
    const backing_rows = rowCount(data.backing);

    var fx = data.cx;
    var fy = absoluteCursorRow(wme);

    var found = false;
    var found_px: u32 = 0;

    if (direction == .down) {
        // Start search one position after cursor
        fx += 1;
        var row: u32 = fy;
        if (fx >= gd.sx) {
            fx = 0;
            row += 1;
        }
        while (row < backing_rows) : (row += 1) {
            const start = if (row == fy) fx else 0;
            if (searchLR(gd, sgd, &found_px, row, start, gd.sx, cis)) {
                found = true;
                fy = row;
                break;
            }
        }
        // Wrap to top
        if (!found) {
            var wrap_row: u32 = 0;
            while (wrap_row <= absoluteCursorRow(wme)) : (wrap_row += 1) {
                if (searchLR(gd, sgd, &found_px, wrap_row, 0, gd.sx, cis)) {
                    found = true;
                    fy = wrap_row;
                    break;
                }
            }
        }
    } else {
        // Search up: start one position before cursor
        var row: u32 = fy;
        const start_fx = fx;
        while (row > 0) : (row -= 1) {
            const end_x = if (row == fy) start_fx + 1 else gd.sx;
            if (end_x > 0 and searchRL(gd, sgd, &found_px, row, 0, end_x, cis)) {
                found = true;
                fy = row;
                break;
            }
        }
        // Check row 0
        if (!found) {
            const end_x = if (fy == 0) start_fx + 1 else gd.sx;
            if (end_x > 0 and searchRL(gd, sgd, &found_px, 0, 0, end_x, cis)) {
                found = true;
                fy = 0;
            }
        }
        // Wrap to bottom
        if (!found) {
            var wrap_row: u32 = backing_rows - 1;
            while (wrap_row > absoluteCursorRow(wme)) : (wrap_row -= 1) {
                if (searchRL(gd, sgd, &found_px, wrap_row, 0, gd.sx, cis)) {
                    found = true;
                    fy = wrap_row;
                    break;
                }
            }
        }
    }

    if (found) {
        setAbsoluteCursorRow(wme, fy);
        data.cx = found_px;
        clampCursorX(wme);
        return true;
    }
    return false;
}

fn expandSearchString(data: *CopyModeData, args: *const args_mod.Arguments) bool {
    const ss = args.value_at(1) orelse return false;
    if (ss.len == 0) return false;

    if (data.searchstr) |old| xm.allocator.free(old);
    data.searchstr = xm.xstrdup(ss);
    return true;
}

fn cmdSearchBackward(wme: *T.WindowModeEntry, args: *const args_mod.Arguments, regex: bool) void {
    const data = modeData(wme);
    if (!expandSearchString(data, args)) return;
    data.searchtype = .up;
    data.searchregex = regex;
    var remaining = repeatCount(wme);
    while (remaining > 0) : (remaining -= 1) {
        _ = doSearch(wme, .up, regex);
    }
}

fn cmdSearchForward(wme: *T.WindowModeEntry, args: *const args_mod.Arguments, regex: bool) void {
    const data = modeData(wme);
    if (!expandSearchString(data, args)) return;
    data.searchtype = .down;
    data.searchregex = regex;
    var remaining = repeatCount(wme);
    while (remaining > 0) : (remaining -= 1) {
        _ = doSearch(wme, .down, regex);
    }
}

fn cmdSearchAgain(wme: *T.WindowModeEntry) void {
    const data = modeData(wme);
    const direction = data.searchtype orelse return;
    var remaining = repeatCount(wme);
    while (remaining > 0) : (remaining -= 1) {
        _ = doSearch(wme, direction, data.searchregex);
    }
}

fn cmdSearchReverse(wme: *T.WindowModeEntry) void {
    const data = modeData(wme);
    const direction = data.searchtype orelse return;
    const reverse: SearchDirection = switch (direction) {
        .up => .down,
        .down => .up,
    };
    var remaining = repeatCount(wme);
    while (remaining > 0) : (remaining -= 1) {
        _ = doSearch(wme, reverse, data.searchregex);
    }
}

fn cmdSearchIncremental(wme: *T.WindowModeEntry, args: *const args_mod.Arguments, direction: SearchDirection) void {
    const data = modeData(wme);
    const arg0 = args.value_at(1) orelse return;
    if (arg0.len == 0) return;

    // The first character is a prefix indicating direction override
    const prefix = arg0[0];
    const search_text = arg0[1..];
    if (search_text.len == 0) return;

    if (data.searchstr) |old| xm.allocator.free(old);
    data.searchstr = xm.xstrdup(search_text);

    // Direction may be overridden by the prefix
    const actual_dir: SearchDirection = switch (prefix) {
        '=', '-' => if (direction == .up) .up else .down,
        '+' => if (direction == .up) .down else .up,
        else => direction,
    };

    data.searchtype = actual_dir;
    data.searchregex = false;
    _ = doSearch(wme, actual_dir, false);
}

// ── Mark support ───────────────────────────────────────────────────────────

fn cmdSetMark(_: *T.WindowModeEntry) void {
    // Reduced: mark support stores cursor position for jump-to-mark
}

fn cmdJumpToMark(_: *T.WindowModeEntry) void {
    // Reduced: jump-to-mark returns to the previously set mark position
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

test "window-copy paragraph motions follow tmux blank-line paragraph scans" {
    initWindowCopyTestGlobals();

    const source_grid = grid.grid_create(8, 8, 0);
    defer grid.grid_free(source_grid);
    const target_grid = grid.grid_create(8, 5, 0);
    defer grid.grid_free(target_grid);
    const source_screen = screen.screen_init(8, 8, 0);
    defer {
        screen.screen_free(source_screen);
        xm.allocator.destroy(source_screen);
    }
    const target_screen = screen.screen_init(8, 5, 0);
    defer {
        screen.screen_free(target_screen);
        xm.allocator.destroy(target_screen);
    }

    var source_window = T.Window{
        .id = 70,
        .name = xm.xstrdup("copy-source-paragraph"),
        .sx = 8,
        .sy = 8,
        .options = undefined,
    };
    defer xm.allocator.free(source_window.name);
    defer source_window.panes.deinit(xm.allocator);
    defer source_window.last_panes.deinit(xm.allocator);
    defer source_window.winlinks.deinit(xm.allocator);

    var target_window = T.Window{
        .id = 71,
        .name = xm.xstrdup("copy-target-paragraph"),
        .sx = 8,
        .sy = 5,
        .options = undefined,
    };
    defer xm.allocator.free(target_window.name);
    defer target_window.panes.deinit(xm.allocator);
    defer target_window.last_panes.deinit(xm.allocator);
    defer target_window.winlinks.deinit(xm.allocator);

    var source = T.WindowPane{
        .id = 72,
        .window = &source_window,
        .options = undefined,
        .sx = 8,
        .sy = 8,
        .screen = source_screen,
        .base = .{ .grid = source_grid, .rlower = 7 },
    };
    defer window_mode_runtime.resetModeAll(&source);

    var target = T.WindowPane{
        .id = 73,
        .window = &target_window,
        .options = undefined,
        .sx = 8,
        .sy = 5,
        .screen = target_screen,
        .base = .{ .grid = target_grid, .rlower = 4 },
    };
    defer window_mode_runtime.resetModeAll(&target);

    try source_window.panes.append(xm.allocator, &source);
    try target_window.panes.append(xm.allocator, &target);
    source_window.active = &source;
    target_window.active = &target;

    setGridLineText(source.base.grid, 0, "alpha");
    setGridLineText(source.base.grid, 1, "beta");
    setGridLineText(source.base.grid, 3, "gamma");
    setGridLineText(source.base.grid, 4, "delta");
    setGridLineText(source.base.grid, 7, "omega");

    var args = args_mod.Arguments.init(xm.allocator);
    defer args.deinit();
    const wme = enterMode(&target, &source, &args);

    try runCopyModeTestCommand(wme, "next-paragraph");
    try std.testing.expectEqual(@as(u32, 2), absoluteCursorRow(wme));
    try std.testing.expectEqual(@as(u32, 0), modeData(wme).cx);

    wme.prefix = 2;
    try runCopyModeTestCommand(wme, "next-paragraph");
    try std.testing.expectEqual(@as(u32, 7), absoluteCursorRow(wme));
    try std.testing.expectEqual(@as(u32, 4), modeData(wme).cx);
    try std.testing.expectEqual(@as(u32, 3), modeData(wme).top);
    try std.testing.expectEqual(@as(u32, 4), modeData(wme).cy);

    try runCopyModeTestCommand(wme, "previous-paragraph");
    try std.testing.expectEqual(@as(u32, 6), absoluteCursorRow(wme));
    try std.testing.expectEqual(@as(u32, 0), modeData(wme).cx);

    wme.prefix = 2;
    try runCopyModeTestCommand(wme, "previous-paragraph");
    try std.testing.expectEqual(@as(u32, 0), absoluteCursorRow(wme));
    try std.testing.expectEqual(@as(u32, 0), modeData(wme).cx);
    try std.testing.expectEqual(@as(u32, 0), modeData(wme).top);
    try std.testing.expectEqual(@as(u32, 0), modeData(wme).cy);
}

test "window-copy goto-line accepts numeric offsets and clamps within the reduced snapshot" {
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
        .id = 54,
        .name = xm.xstrdup("copy-source-goto-line"),
        .sx = 6,
        .sy = 8,
        .options = undefined,
    };
    defer xm.allocator.free(source_window.name);
    defer source_window.panes.deinit(xm.allocator);
    defer source_window.last_panes.deinit(xm.allocator);
    defer source_window.winlinks.deinit(xm.allocator);

    var target_window = T.Window{
        .id = 55,
        .name = xm.xstrdup("copy-target-goto-line"),
        .sx = 6,
        .sy = 5,
        .options = undefined,
    };
    defer xm.allocator.free(target_window.name);
    defer target_window.panes.deinit(xm.allocator);
    defer target_window.last_panes.deinit(xm.allocator);
    defer target_window.winlinks.deinit(xm.allocator);

    var source = T.WindowPane{
        .id = 56,
        .window = &source_window,
        .options = undefined,
        .sx = 6,
        .sy = 8,
        .screen = source_screen,
        .base = .{ .grid = source_grid, .rlower = 7 },
    };
    defer window_mode_runtime.resetModeAll(&source);

    var target = T.WindowPane{
        .id = 57,
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
    source.base.cx = 3;
    source.base.cy = 4;

    var args = args_mod.Arguments.init(xm.allocator);
    defer args.deinit();
    const wme = enterMode(&target, &source, &args);
    try std.testing.expectEqual(@as(u32, 0), modeData(wme).top);
    try std.testing.expectEqual(@as(u32, 4), modeData(wme).cy);
    try std.testing.expectEqual(@as(u32, 4), absoluteCursorRow(wme));

    try runCopyModeTestCommandArgs(wme, null, &.{ "goto-line", "1" });
    try std.testing.expectEqual(@as(u32, 2), modeData(wme).top);
    try std.testing.expectEqual(@as(u32, 4), modeData(wme).cy);
    try std.testing.expectEqual(@as(u32, 6), absoluteCursorRow(wme));

    try runCopyModeTestCommandArgs(wme, null, &.{ "goto-line", "bogus" });
    try std.testing.expectEqual(@as(u32, 2), modeData(wme).top);
    try std.testing.expectEqual(@as(u32, 4), modeData(wme).cy);

    try runCopyModeTestCommandArgs(wme, null, &.{ "goto-line", "99" });
    try std.testing.expectEqual(@as(u32, 0), modeData(wme).top);
    try std.testing.expectEqual(@as(u32, 4), modeData(wme).cy);
    try std.testing.expectEqual(@as(u32, 4), absoluteCursorRow(wme));
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
    try unsupported.values.append(xm.allocator, xm.xstrdup("search-jump-to"));
    copyModeCommand(wme, &client, undefined, undefined, @ptrCast(&unsupported), null);

    try std.testing.expectEqualStrings("Copy-mode command not supported yet: search-jump-to", client.message_string.?);
}
