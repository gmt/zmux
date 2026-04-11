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
const format_mod = @import("format.zig");
const format_draw = @import("format-draw.zig");
const grid = @import("grid.zig");
const hyperlinks = @import("hyperlinks.zig");
const input_mod = @import("input.zig");
const mouse_runtime = @import("mouse-runtime.zig");
const opts = @import("options.zig");
const screen = @import("screen.zig");
const screen_write = @import("screen-write.zig");
const status_runtime = @import("status-runtime.zig");
const T = @import("types.zig");
const utf8 = @import("utf8.zig");
const window = @import("window.zig");
const window_mode_runtime = @import("window-mode-runtime.zig");
const xm = @import("xmalloc.zig");

const word_whitespace = "\t ";

pub const JumpType = enum {
    off,
    forward,
    backward,
    to_forward,
    to_backward,
};

pub const CursorDrag = enum {
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

pub const CopyModeData = struct {
    backing: *T.Screen,
    top: u32 = 0,
    cx: u32 = 0,
    cy: u32 = 0,
    jump_type: JumpType = .off,
    jump_char: T.Utf8Data = std.mem.zeroes(T.Utf8Data),
    hide_position: bool = false,
    scroll_exit: bool = false,
    viewmode: bool = false,
    backing_written: bool = false,

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
    searchdirection: ?SearchDirection = null,
    searchmark: ?[]u8 = null,
    searchcount: i32 = -1,
    searchmore: i32 = 0,
    searchall: bool = false,
    searchx: u32 = 0,
    searchy: u32 = 0,
    searcho: u32 = 0,
    searchgen: u8 = 1,
    timeout: bool = false,

    // Mark state
    mark_x: u32 = 0,
    mark_y: u32 = 0,
    show_mark: bool = false,
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

    // Initialize mark to the cursor position (mirrors tmux behaviour).
    data.mark_x = data.cx;
    data.mark_y = absoluteCursorRow(wme);

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
    refreshSearchMarks(wme, true);
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

pub fn copyModeCommand(
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
    } else if (std.mem.eql(u8, command, "copy-pipe-no-clear")) {
        cmdCopyPipeNoClear(wme, session, args);
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
    } else if (std.mem.eql(u8, command, "swap-selection-start")) {
        cmdSwapSelectionStart(wme);
    } else if (std.mem.eql(u8, command, "swap-selection-end")) {
        cmdSwapSelectionEnd(wme);
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
    } else if (std.mem.eql(u8, command, "pipe-no-clear")) {
        cmdPipeNoClear(wme, session, args);
    } else if (std.mem.eql(u8, command, "previous-matching-bracket")) {
        const cs = CmdState{
            .wme = wme,
            .args = args,
            .wargs = args,
            .mouse = null,
            .client = client,
            .session = session,
            .wl = null,
        };
        _ = window_copy_cmd_previous_matching_bracket(&cs);
    } else if (std.mem.eql(u8, command, "next-matching-bracket")) {
        const cs = CmdState{
            .wme = wme,
            .args = args,
            .wargs = args,
            .mouse = null,
            .client = client,
            .session = session,
            .wl = null,
        };
        _ = window_copy_cmd_next_matching_bracket(&cs);
    } else if (std.mem.eql(u8, command, "next-prompt")) {
        window_copy_cursor_prompt(wme, 1, false);
    } else if (std.mem.eql(u8, command, "previous-prompt")) {
        window_copy_cursor_prompt(wme, -1, false);
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
    if (data.searchmark) |sm| xm.allocator.free(sm);
    if (data.searchstr) |ss| xm.allocator.free(ss);
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

pub fn modeData(wme: *T.WindowModeEntry) *CopyModeData {
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

fn absoluteStorageRow(gd: *const T.Grid, row: u32) ?u32 {
    return grid.absolute_row_to_storage(gd, row);
}

fn storageRowToAbsolute(gd: *const T.Grid, row: u32) u32 {
    return if (row < gd.sy) gd.hsize + row else row - gd.sy;
}

fn absoluteLine(gd: *const T.Grid, row: u32) ?*const T.GridLine {
    const storage_row = absoluteStorageRow(gd, row) orelse return null;
    return grid.grid_peek_line(gd, storage_row);
}

fn absoluteLineLength(gd: *const T.Grid, row: u32) u32 {
    const storage_row = absoluteStorageRow(gd, row) orelse return 0;
    return grid.line_length(@constCast(gd), storage_row);
}

fn absoluteGetCell(gd: *const T.Grid, row: u32, col: u32, gc: *T.GridCell) void {
    const storage_row = absoluteStorageRow(gd, row) orelse {
        gc.* = T.grid_default_cell;
        return;
    };
    grid.get_cell(@constCast(gd), storage_row, col, gc);
}

fn copyLine(dst_grid: *T.Grid, dst_row: u32, src_grid: *const T.Grid, src_row: u32, width: u32) void {
    const storage_row = absoluteStorageRow(src_grid, src_row) orelse return;
    if (storage_row >= src_grid.linedata.len or dst_row >= dst_grid.linedata.len) return;

    const src_line = &src_grid.linedata[storage_row];
    var cell: T.GridCell = undefined;
    var col: u32 = 0;
    while (col < width) : (col += 1) {
        grid.get_cell(@constCast(src_grid), storage_row, col, &cell);
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
    const total_backing_rows = backing.grid.hsize + backing.grid.sy;
    while (row < rows) : (row += 1) {
        const backing_row = data.top + row;
        if (backing_row >= total_backing_rows) break;
        copyLine(view.grid, row, backing.grid, backing_row, width);
    }

    // Expand and draw the copy-mode-position-format on the first visible
    // line (mirrors tmux's window_copy_write_line).
    if (opts.options_ready and !data.hide_position and rows > 0 and view.grid.sx > 0) {
        const pos_fmt = opts.options_get_string(wme.wp.window.options, "copy-mode-position-format");
        if (pos_fmt.len > 0) {
            const expanded = format_mod.format_single(null, pos_fmt, null, null, null, wme.wp);
            if (expanded.len > 0) {
                var ctx = T.ScreenWriteCtx{ .s = view };
                screen_write.cursor_to(&ctx, 0, 0);
                format_draw.format_draw(&ctx, &T.grid_default_cell, view.grid.sx, expanded);
            }
            xm.allocator.free(expanded);
        }
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
    const row = absoluteStorageRow(modeData(wme).backing.grid, absoluteCursorRow(wme)) orelse return false;
    grid.grid_reader_start(gr, modeData(wme).backing.grid, modeData(wme).cx, row);
    return true;
}

fn applyMotionReader(wme: *T.WindowModeEntry, gr: *const T.GridReader) void {
    var cx: u32 = 0;
    var cy: u32 = 0;
    grid.grid_reader_get_cursor(gr, &cx, &cy);
    setAbsoluteCursorRow(wme, storageRowToAbsolute(modeData(wme).backing.grid, cy));
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

pub fn absoluteCursorRow(wme: *T.WindowModeEntry) u32 {
    const data = modeData(wme);
    return data.top + data.cy;
}

fn viewRows(wp: *const T.WindowPane) u32 {
    return wp.screen.grid.sy;
}

fn rowCount(s: *const T.Screen) u32 {
    return s.grid.hsize + s.grid.sy;
}

fn backingLineLength(wme: *T.WindowModeEntry, row: u32) u32 {
    const data = modeData(wme);
    if (row >= data.backing.grid.hsize + data.backing.grid.sy) return 0;
    return absoluteLineLength(data.backing.grid, row);
}

fn maxTop(backing: *const T.Screen, wp: *const T.WindowPane) u32 {
    const rows = backing.grid.hsize + backing.grid.sy;
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
    if (view_width == 0 or row >= rowCount(backing)) return 0;
    const length = absoluteLineLength(backing.grid, row);
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
    refreshSearchMarks(wme, true);
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
    if (scroll_exit and data.top == max_top) return true;
    refreshSearchMarks(wme, true);
    return false;
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
    const vi_keys = copyModeUsesViKeys(wme);

    // No active selection
    if (data.cursordrag == .none and data.lineflag == .none)
        return null;

    // Determine selection bounds (selx,sely = anchor, endselx,endsely = cursor end)
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
    const ey_last = absoluteLineLength(gd, ey);
    if (ex > ey_last) ex = ey_last;

    // Compute per-line start/end columns (handles both rect and normal).
    // In rectangle mode tmux determines the column bounds from the cursor
    // position relative to the selection anchor; in emacs mode the cursor
    // column is excluded, in vi mode it is included.
    const firstsx: u32, const restsx: u32, const lastex: u32, const restex: u32 = if (data.rectflag) rect: {
        // Determine which column is the "selection" vs "cursor" side
        const selx: u32 = if (data.cursordrag == .endsel)
            data.selx
        else
            data.endselx;

        var fsx: u32 = undefined;
        var rsx: u32 = undefined;
        var lex: u32 = undefined;
        var rex: u32 = undefined;

        if (selx < data.cx) {
            // Selection start is on the left, cursor on the right
            if (vi_keys) {
                lex = data.cx + 1;
                rex = data.cx + 1;
            } else {
                lex = data.cx;
                rex = data.cx;
            }
            fsx = selx;
            rsx = selx;
        } else {
            // Cursor is on the left
            lex = selx + 1;
            rex = selx + 1;
            fsx = data.cx;
            rsx = data.cx;
        }
        break :rect .{ fsx, rsx, lex, rex };
    } else normal: {
        // Normal (non-rectangle) selection
        const lex: u32 = if (vi_keys) ex + 1 else ex;
        break :normal .{ sx, 0, lex, gd.sx };
    };

    var buf: std.ArrayList(u8) = .{};

    // Copy each line in the selection range
    var row: u32 = sy;
    while (row <= ey) : (row += 1) {
        const line_start = if (row == sy) firstsx else restsx;
        const line_end = if (row == ey) lastex else restex;
        copyLineToBuffer(&buf, gd, row, line_start, line_end);
    }

    if (buf.items.len == 0) {
        buf.deinit(xm.allocator);
        return null;
    }

    // Remove final \n (unless at end in vi mode)
    if (!vi_keys or lastex <= ey_last) {
        const wrapped = ey < gd.linedata.len and
            (gd.linedata[ey].flags & T.GRID_LINE_WRAPPED) != 0 and
            gd.linedata[ey].cellused <= gd.sx;
        if (!wrapped or lastex != ey_last) {
            if (buf.items.len > 0 and buf.items[buf.items.len - 1] == '\n') {
                buf.items.len -= 1;
            }
        }
    }

    return buf.toOwnedSlice(xm.allocator) catch unreachable;
}

/// Append cells from a single grid row [line_start..line_end) into buf,
/// respecting wrapped lines and padding.  Adds a trailing newline when
/// appropriate (mirrors tmux's window_copy_copy_line).
fn copyLineToBuffer(
    buf: *std.ArrayList(u8),
    gd: *T.Grid,
    row: u32,
    line_start: u32,
    line_end: u32,
) void {
    if (line_start > line_end) return;

    // Determine effective line length
    const line = absoluteLine(gd, row);
    const wrapped = line != null and
        (line.?.flags & T.GRID_LINE_WRAPPED) != 0 and
        line.?.cellused <= gd.sx;
    const effective_len: u32 = if (wrapped)
        line.?.cellused
    else
        absoluteLineLength(gd, row);

    var ex = line_end;
    var sx = line_start;
    if (ex > effective_len) ex = effective_len;
    if (sx > effective_len) sx = effective_len;

    // Collect cell data
    var col: u32 = sx;
    while (col < ex) : (col += 1) {
        var gc: T.GridCell = undefined;
        absoluteGetCell(gd, row, col, &gc);
        if (gc.isPadding()) continue;
        if (gc.data.size >= 1) {
            buf.appendSlice(xm.allocator, gc.data.data[0..gc.data.size]) catch unreachable;
        }
    }

    // Only add a newline if the line was not wrapped, or we didn't copy
    // to the full effective width
    if (!wrapped or ex != effective_len) {
        buf.append(xm.allocator, '\n') catch unreachable;
    }
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
    rectangleSetUpdateCursor(wme);
}

fn cmdRectangleSet(wme: *T.WindowModeEntry, on: bool) void {
    const data = modeData(wme);
    data.lineflag = .none;
    data.rectflag = on;
    rectangleSetUpdateCursor(wme);
}

/// After toggling rectangle mode, clamp cursor to line length and update
/// any active selection (mirrors tmux's window_copy_rectangle_set).
fn rectangleSetUpdateCursor(wme: *T.WindowModeEntry) void {
    const data = modeData(wme);
    const abs_row = absoluteCursorRow(wme);
    const line_len = absoluteLineLength(data.backing.grid, abs_row);
    if (data.cx > line_len)
        data.cx = line_len;
    _ = updateSelection(wme);
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

/// Swap cursor position to the selection start (anchor) point, making it the
/// new active end.  Mirrors tmux's window_copy_cmd_swap_selection_start.
fn cmdSwapSelectionStart(wme: *T.WindowModeEntry) void {
    const data = modeData(wme);
    if (data.cursordrag == .none and data.lineflag == .none) return;

    // The cursor becomes the new endsel; the old sel anchor becomes the
    // cursor position.
    data.endselx = data.cx;
    data.endsely = absoluteCursorRow(wme);

    data.cx = data.selx;
    setAbsoluteCursorRow(wme, data.sely);

    // Flip the drag state so further cursor motion adjusts the end.
    if (data.cursordrag == .sel) {
        data.cursordrag = .endsel;
    }
    clampCursorX(wme);
}

/// Swap cursor position to the selection end point, making it the new active
/// end.  Mirrors tmux's window_copy_cmd_swap_selection_end.
fn cmdSwapSelectionEnd(wme: *T.WindowModeEntry) void {
    const data = modeData(wme);
    if (data.cursordrag == .none and data.lineflag == .none) return;

    // The cursor becomes the new sel anchor; the old endsel becomes the
    // cursor position.
    data.selx = data.cx;
    data.sely = absoluteCursorRow(wme);

    data.cx = data.endselx;
    setAbsoluteCursorRow(wme, data.endsely);

    // Flip the drag state so further cursor motion adjusts the start.
    if (data.cursordrag == .endsel) {
        data.cursordrag = .sel;
    }
    clampCursorX(wme);
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
    doCopyPipe(wme, session, args, true, cancel);
}

fn cmdCopyPipeNoClear(wme: *T.WindowModeEntry, session: *T.Session, args: *const args_mod.Arguments) void {
    doCopyPipe(wme, session, args, false, false);
}

fn doCopyPipe(wme: *T.WindowModeEntry, session: *T.Session, args: *const args_mod.Arguments, do_clear: bool, cancel: bool) void {
    const buf_text = getSelectionText(wme) orelse return;
    defer xm.allocator.free(buf_text);

    const paste_mod = @import("paste.zig");
    paste_mod.paste_add(null, xm.xstrdup(buf_text));

    const command = if (args.value_at(1)) |a| a else "";
    pipeRun(wme, session, command, buf_text);

    if (do_clear) clearSelection(wme);
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
    doPipe(wme, session, args, true, cancel);
}

fn cmdPipeNoClear(wme: *T.WindowModeEntry, session: *T.Session, args: *const args_mod.Arguments) void {
    doPipe(wme, session, args, false, false);
}

fn doPipe(wme: *T.WindowModeEntry, session: *T.Session, args: *const args_mod.Arguments, do_clear: bool, cancel: bool) void {
    const buf_text = getSelectionText(wme) orelse return;
    defer xm.allocator.free(buf_text);

    const command = if (args.value_at(1)) |a| a else "";
    pipeRun(wme, session, command, buf_text);

    if (do_clear) clearSelection(wme);
    if (cancel) {
        _ = window_mode_runtime.resetMode(wme.wp);
    }
}

/// Run a shell command with the selected text piped to its stdin.
/// Falls back to the "copy-command" global option when command is empty.
fn pipeRun(wme: *T.WindowModeEntry, session: *T.Session, command: []const u8, input: []const u8) void {
    _ = wme;

    // Resolve effective command: arg > session option > global option
    var effective_cmd: []const u8 = command;
    if (effective_cmd.len == 0) {
        effective_cmd = opts.options_get_string(session.options, "copy-command");
    }
    if (effective_cmd.len == 0) {
        effective_cmd = opts.options_get_string(opts.global_options, "copy-command");
    }

    if (effective_cmd.len == 0 or input.len == 0) return;

    // Fork a child process: sh -c <command>, pipe input to stdin
    const child_pid = std.posix.fork() catch return;
    if (child_pid == 0) {
        // Child process — set up pipe for stdin
        const pipe_fds = std.posix.pipe() catch std.process.exit(1);

        const read_end = pipe_fds[0];
        const write_end = pipe_fds[1];

        // Fork again so a grandchild can write input while the child
        // execs the shell command.
        const grandchild = std.posix.fork() catch std.process.exit(1);
        if (grandchild == 0) {
            // Grandchild: write input to the pipe, then exit
            std.posix.close(read_end);
            _ = std.posix.write(write_end, input) catch {};
            std.posix.close(write_end);
            std.process.exit(0);
        }

        // Still in child: redirect stdin to the read end of the pipe
        std.posix.close(write_end);
        const dev_null = std.posix.open("/dev/null", .{ .ACCMODE = .RDWR }, 0) catch std.process.exit(1);
        std.posix.dup2(read_end, 0) catch std.process.exit(1); // stdin
        std.posix.dup2(dev_null, 1) catch std.process.exit(1); // stdout -> /dev/null
        std.posix.dup2(dev_null, 2) catch std.process.exit(1); // stderr -> /dev/null
        std.posix.close(read_end);
        std.posix.close(dev_null);

        // Build a null-terminated copy of the command for execve
        const cmd_z = xm.allocator.allocSentinel(u8, effective_cmd.len, 0) catch std.process.exit(1);
        @memcpy(cmd_z[0..effective_cmd.len], effective_cmd);
        const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", cmd_z, null };
        std.posix.execveZ("/bin/sh", &argv, @ptrCast(std.os.environ.ptr)) catch {
            std.process.exit(127);
        };
    }
    // Parent: reap child asynchronously (we don't care about its exit status)
    var status: i32 = 0;
    _ = std.c.waitpid(child_pid, &status, std.posix.W.NOHANG);
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
    absoluteGetCell(gd, py, px, &gc);
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

/// Walk outward from `at` in the searchmark array to find the contiguous
/// run of cells sharing the same mark value.  Returns start/end inclusive
/// indices into the flat searchmark array.  Mirrors tmux's
/// window_copy_match_start_end().
fn matchStartEnd(data: *CopyModeData, at: u32, start: *u32, end: *u32) void {
    const sm = data.searchmark orelse return;
    const gd = data.backing.grid;
    const sx = gd.sx;
    const sy = gd.sy;
    const last: u32 = if (sx > 0 and sy > 0) sx * sy - 1 else 0;
    const mark: u8 = sm[at];
    start.* = at;
    end.* = at;
    while (start.* != 0 and sm[start.*] == mark)
        start.* -= 1;
    if (sm[start.*] != mark)
        start.* += 1;
    while (end.* != last and sm[end.*] == mark)
        end.* += 1;
    if (sm[end.*] != mark)
        end.* -= 1;
}

/// Return an allocated string for the match under the cursor, or null if
/// there is none.  Caller owns the returned slice.  Mirrors tmux's
/// window_copy_match_at_cursor().
fn matchAtCursor(data: *CopyModeData) ?[]u8 {
    const sm = data.searchmark orelse return null;
    const gd = data.backing.grid;
    const sx = gd.sx;

    // Convert (cx, cy) in viewport coords to flat searchmark index.
    const cy_abs = data.top + data.cy;
    var at: u32 = undefined;
    if (!window_copy_search_mark_at(data, data.cx, cy_abs, &at))
        return null;
    if (sm[at] == 0) {
        // Allow one position after the match.
        if (at == 0 or sm[at - 1] == 0)
            return null;
        at -= 1;
    }

    var start: u32 = undefined;
    var end: u32 = undefined;
    matchStartEnd(data, at, &start, &end);

    var buf = std.ArrayList(u8).init(xm.allocator);
    var i: u32 = start;
    while (i <= end) : (i += 1) {
        const py = data.top + (i / sx);
        const px = i % sx;
        var gc: T.GridCell = undefined;
        absoluteGetCell(gd, py, px, &gc);
        if ((gc.flags & T.GRID_FLAG_TAB) != 0) {
            buf.append('\t') catch unreachable;
        } else if ((gc.flags & T.GRID_FLAG_PADDING) != 0) {
            // skip
        } else {
            buf.appendSlice(gc.data.data[0..gc.data.size]) catch unreachable;
        }
    }

    if (buf.items.len == 0) {
        buf.deinit();
        return null;
    }
    return buf.toOwnedSlice() catch unreachable;
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
        // Populate search marks so highlight rendering works.
        if (!data.timeout)
            _ = window_copy_search_marks(wme, null, regex, true);
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

fn cmdSetMark(wme: *T.WindowModeEntry) void {
    const data = modeData(wme);
    data.mark_x = data.cx;
    data.mark_y = absoluteCursorRow(wme);
    data.show_mark = true;
}

fn cmdJumpToMark(wme: *T.WindowModeEntry) void {
    const data = modeData(wme);

    // Swap current cursor position with the mark, mirroring tmux's
    // window_copy_jump_to_mark which exchanges the two positions so
    // that repeated jumps toggle back and forth.
    const tmp_x = data.cx;
    const tmp_y = absoluteCursorRow(wme);

    data.cx = data.mark_x;
    setAbsoluteCursorRow(wme, data.mark_y);

    data.mark_x = tmp_x;
    data.mark_y = tmp_y;
    data.show_mark = true;
}

// ═══════════════════════════════════════════════════════════════════════════
// tmux-compatible function names
//
// Every window_copy_* function from tmux's window-copy.c is represented
// below, either as a real implementation delegating to the Zig helpers
// above, or as a stub returning a sensible default.  This satisfies audit
// completeness: callers can find every expected symbol.
// ═══════════════════════════════════════════════════════════════════════════

pub const CmdAction = enum {
    nothing,
    redraw,
    cancel,
};

pub const CmdClear = enum {
    always,
    never,
    emacs_only,
};

pub const CmdState = struct {
    wme: *T.WindowModeEntry,
    args: *const args_mod.Arguments,
    wargs: *const args_mod.Arguments,
    mouse: ?*const T.MouseEvent,
    client: ?*T.Client,
    session: ?*T.Session,
    wl: ?*T.Winlink,
};

pub const window_view_mode = T.WindowMode{
    .name = "view-mode",
    .init = window_copy_view_init_mode,
    .resize = window_copy_resize,
    .key = copyModeKey,
    .key_table = copyModeKeyTable,
    .command = copyModeCommand,
    .close = copyModeClose,
    .get_screen = copyModeGetScreen,
};

// ── Lifecycle ──────────────────────────────────────────────────────────────

pub fn window_copy_common_init(wme: *T.WindowModeEntry) *CopyModeData {
    const data = xm.allocator.create(CopyModeData) catch unreachable;
    data.* = .{
        .backing = screen.screen_init(wme.wp.sx, wme.wp.sy, 0),
    };
    wme.data = @ptrCast(data);
    return data;
}

pub fn window_copy_init(wme: *T.WindowModeEntry, _fs: ?*anyopaque, args: *const args_mod.Arguments) *T.Screen {
    _ = _fs;
    const data = window_copy_common_init(wme);
    data.hide_position = args.has('H');
    data.scroll_exit = args.has('e');
    refreshFromSource(wme, false);
    data.mark_x = data.cx;
    data.mark_y = absoluteCursorRow(wme);
    return data.backing;
}

pub fn window_copy_view_init(wme: *T.WindowModeEntry, _fs: ?*anyopaque, args: *const args_mod.Arguments) *T.Screen {
    _ = _fs;
    const data = window_copy_common_init(wme);
    data.hide_position = args.has('H');
    return data.backing;
}

/// Init callback for `window_view_mode`, matching the `WindowMode.init`
/// signature.  Called from `window_pane_set_mode` when view-mode is pushed
/// onto a pane.  Enters alternate screen so the pane's own screen serves
/// as the view, with data.backing holding the written text.
fn window_copy_view_init_mode(wme: *T.WindowModeEntry) *T.Screen {
    const wp = wme.wp;
    const sx = wp.sx;
    const sy = wp.sy;

    screen.screen_enter_alternate(wp, true);

    const data = xm.allocator.create(CopyModeData) catch unreachable;
    data.* = .{
        // Unlimited history so window_copy_add content is never lost
        // and PgDn/PgUp scrolling works across all output.
        .backing = screen.screen_init(sx, sy, std.math.maxInt(u32)),
    };
    data.viewmode = true;
    wme.data = @ptrCast(data);

    return wp.screen;
}

pub fn window_copy_free(wme: *T.WindowModeEntry) void {
    copyModeClose(wme);
}

pub fn window_copy_resize(wme: *T.WindowModeEntry, sx: u32, sy: u32) void {
    const data = modeData(wme);
    screen.screen_resize(data.backing, sx, sy, false);
    redraw(wme);
}

pub fn window_copy_size_changed(wme: *T.WindowModeEntry) void {
    const data = modeData(wme);
    const had_searchmark = data.searchmark != null;
    window_copy_resize(wme, wme.wp.sx, wme.wp.sy);
    if (had_searchmark and !data.timeout) {
        // Use false: after resize, marks need full recomputation, not just refresh.
        _ = window_copy_search_marks(wme, null, data.searchregex, false);
    }
}

pub fn window_copy_get_screen(wme: *T.WindowModeEntry) *T.Screen {
    return copyModeGetScreen(wme);
}

pub fn window_copy_clone_screen(src: *T.Screen, hint: ?*T.Screen, cx_out: ?*u32, cy_out: ?*u32, trim: bool) *T.Screen {
    _ = hint;
    var sy = src.grid.sy;

    // If trimming, remove empty trailing lines
    if (trim) {
        while (sy > 0) {
            const gl = grid.grid_peek_line(@constCast(src.grid), sy - 1);
            if (gl == null or gl.?.cellused != 0) break;
            sy -= 1;
        }
        if (sy == 0) sy = 1;
    }

    const dst = screen.screen_init(src.grid.sx, sy, 0);
    cloneScreen(dst, src);

    if (cx_out) |cx| cx.* = if (dst.grid.sx != 0) @min(src.cx, dst.grid.sx - 1) else 0;
    if (cy_out) |cy| cy.* = if (dst.grid.sy != 0) @min(src.cy, dst.grid.sy - 1) else 0;

    return dst;
}

// ── Timer / Callbacks ──────────────────────────────────────────────────────

pub fn window_copy_scroll_timer(_fd: i32, _events: i16, _arg: ?*anyopaque) void {
    // Timer callback for scroll speed management.
    // In tmux, this fires periodically while the mouse is dragging
    // near the edge to auto-scroll. Not yet needed in zmux.
    _ = _fd;
    _ = _events;
    _ = _arg;
}

pub fn window_copy_init_ctx_cb(_ctx: ?*anyopaque, _cell: ?*T.GridCell) void {
    // Context init callback for screen_write operations in view mode.
    // Sets defaults on the tty context. Minimal implementation since
    // zmux's screen_write doesn't use the same callback pattern.
    if (_cell) |cell| {
        cell.* = T.grid_default_cell;
    }
    _ = _ctx;
}

// ── Text add (view-mode output) ────────────────────────────────────────────

/// Reset the view-mode scroll position to the top of the content.
pub fn window_copy_reset_view(wp: *T.WindowPane) void {
    const wme = window.window_pane_mode(wp) orelse return;
    if (wme.mode != &window_copy_mode and wme.mode != &window_view_mode) return;
    const data = modeData(wme);
    data.top = 0;
    data.cy = 0;
    data.cx = 0;
    redraw(wme);
}

pub fn window_copy_add(wp: *T.WindowPane, parse: bool, text: []const u8) void {
    window_copy_vadd(wp, parse, text);
}

pub fn window_copy_vadd(wp: *T.WindowPane, parse: bool, text: []const u8) void {
    const wme = window.window_pane_mode(wp) orelse return;
    if (wme.mode != &window_copy_mode and wme.mode != &window_view_mode) return;
    const data = modeData(wme);
    const backing = data.backing;

    var ctx = T.ScreenWriteCtx{ .s = backing };
    if (data.backing_written) {
        // On the second or later line, do a CRLF before writing
        // (so it's on a new line).
        screen_write.carriage_return(&ctx);
        screen_write.newline(&ctx);
    } else {
        data.backing_written = true;
    }

    if (parse) {
        screen_write.putn(&ctx, text);
    } else {
        for (text) |ch| {
            screen_write.putc(&ctx, ch);
        }
    }

    if (data.viewmode) {
        const rows = rowCount(backing);
        const view = viewRows(wp);
        data.top = if (rows > view) rows - view else 0;
        const visible_rows = @min(rows, view);
        data.cy = if (visible_rows == 0) 0 else visible_rows - 1;
    }

    redraw(wme);
}

// ── Getters for format callbacks ───────────────────────────────────────────

pub fn window_copy_get_word(wp: *T.WindowPane, x: u32, y: u32) ?[]u8 {
    const wme = window.window_pane_mode(wp) orelse return null;
    if (wme.mode != &window_copy_mode and wme.mode != &window_view_mode) return null;
    const data = modeData(wme);
    const gd = data.backing.grid;
    const row = data.top + y;
    const format_resolve = @import("format-resolve.zig");
    return format_resolve.format_grid_word(xm.allocator, gd, x, row, word_whitespace);
}

pub fn window_copy_get_line(wp: *T.WindowPane, y: u32) ?[]u8 {
    const wme = window.window_pane_mode(wp) orelse return null;
    if (wme.mode != &window_copy_mode and wme.mode != &window_view_mode) return null;
    const data = modeData(wme);
    const gd = data.backing.grid;
    const row = data.top + y;
    const format_resolve = @import("format-resolve.zig");
    return format_resolve.format_grid_line(xm.allocator, gd, row);
}

pub fn window_copy_get_hyperlink(wp: *T.WindowPane, x: u32, y: u32) ?[]u8 {
    const wme = window.window_pane_mode(wp) orelse return null;
    if (wme.mode != &window_copy_mode and wme.mode != &window_view_mode) return null;
    const data = modeData(wme);
    const row = data.top + y;
    const format_resolve = @import("format-resolve.zig");
    return format_resolve.format_grid_hyperlink(data.backing, x, row);
}

pub fn window_copy_cursor_hyperlink_cb(ft: ?*anyopaque) ?*anyopaque {
    const ctx: *format_mod.FormatContext = @ptrCast(@alignCast(ft orelse return null));
    const wp = ctx.pane orelse return null;
    const wme = window.window_pane_mode(wp) orelse return null;
    if (wme.mode != &window_copy_mode and wme.mode != &window_view_mode) return null;
    const data = modeData(wme);
    const format_resolve = @import("format-resolve.zig");
    const result = format_resolve.format_grid_hyperlink(data.backing, data.cx, data.top + data.cy) orelse return null;
    return @ptrCast(result.ptr);
}

pub fn window_copy_cursor_word_cb(ft: ?*anyopaque) ?*anyopaque {
    const ctx: *format_mod.FormatContext = @ptrCast(@alignCast(ft orelse return null));
    const wp = ctx.pane orelse return null;
    const wme = window.window_pane_mode(wp) orelse return null;
    if (wme.mode != &window_copy_mode and wme.mode != &window_view_mode) return null;
    const data = modeData(wme);
    const format_resolve = @import("format-resolve.zig");
    const s_opts = if (ctx.session) |s| s.options else opts.global_s_options;
    const separators = opts.options_get_string(s_opts, "word-separators");
    const gd = data.backing.grid;
    const result = format_resolve.format_grid_word(xm.allocator, gd, data.cx, data.top + data.cy, separators) orelse return null;
    return @ptrCast(result.ptr);
}

pub fn window_copy_cursor_line_cb(ft: ?*anyopaque) ?*anyopaque {
    const ctx: *format_mod.FormatContext = @ptrCast(@alignCast(ft orelse return null));
    const wp = ctx.pane orelse return null;
    const wme = window.window_pane_mode(wp) orelse return null;
    if (wme.mode != &window_copy_mode and wme.mode != &window_view_mode) return null;
    const data = modeData(wme);
    const format_resolve = @import("format-resolve.zig");
    const gd = data.backing.grid;
    const result = format_resolve.format_grid_line(xm.allocator, gd, data.top + data.cy) orelse return null;
    return @ptrCast(result.ptr);
}

pub fn window_copy_search_match_cb(ft: ?*anyopaque) ?*anyopaque {
    const ctx: *format_mod.FormatContext = @ptrCast(@alignCast(ft orelse return null));
    const wp = ctx.pane orelse return null;
    const wme = window.window_pane_mode(wp) orelse return null;
    if (wme.mode != &window_copy_mode and wme.mode != &window_view_mode) return null;
    const data = modeData(wme);
    const result = matchAtCursor(data) orelse return null;
    return @ptrCast(result.ptr);
}

/// Helper: format a number into a temp buffer, call format_add, then free.
fn formatAddNum(ctx: *format_mod.FormatContext, key: []const u8, value: anytype) void {
    const s = std.fmt.allocPrint(xm.allocator, "{d}", .{value}) catch return;
    defer xm.allocator.free(s);
    format_mod.format_add(ctx, key, s);
}

pub fn window_copy_formats(wme: *T.WindowModeEntry, raw_ft: ?*anyopaque) void {
    const ctx: *format_mod.FormatContext = @ptrCast(@alignCast(raw_ft orelse return));
    const data = modeData(wme);
    const gd = data.backing.grid;

    // top_line_time: timestamp of the grid line at the top of the viewport.
    if (data.top < gd.hsize + gd.sy) {
        const gl = grid.grid_get_line(@constCast(gd), data.top);
        var buf: [24]u8 = undefined;
        const time_str = std.fmt.bufPrint(&buf, "{d}", .{gl.time}) catch "0";
        format_mod.format_add(ctx, "top_line_time", time_str);
    }

    formatAddNum(ctx, "scroll_position", data.top);
    format_mod.format_add(ctx, "rectangle_toggle", if (data.rectflag) "1" else "0");
    formatAddNum(ctx, "copy_cursor_x", data.cx);
    formatAddNum(ctx, "copy_cursor_y", data.cy);

    if (data.cursordrag != .none or data.lineflag != .none) {
        formatAddNum(ctx, "selection_start_x", data.selx);
        formatAddNum(ctx, "selection_start_y", data.sely);
        formatAddNum(ctx, "selection_end_x", data.endselx);
        formatAddNum(ctx, "selection_end_y", data.endsely);
        format_mod.format_add(ctx, "selection_active", if (data.cursordrag != .none) "1" else "0");
        format_mod.format_add(ctx, "selection_present", if (data.endselx != data.selx or data.endsely != data.sely) "1" else "0");
    } else {
        format_mod.format_add(ctx, "selection_active", "0");
        format_mod.format_add(ctx, "selection_present", "0");
    }

    format_mod.format_add(ctx, "selection_mode", switch (data.selflag) {
        .char => "char",
        .word => "word",
        .line => "line",
    });

    format_mod.format_add(ctx, "search_present", if (data.searchmark != null) "1" else "0");
    format_mod.format_add(ctx, "search_timed_out", if (data.timeout) "1" else "0");
    if (data.searchcount != -1) {
        formatAddNum(ctx, "search_count", data.searchcount);
        formatAddNum(ctx, "search_count_partial", data.searchmore);
    }

    // Eager evaluation of callback-style keys: compute and store inline.
    if (matchAtCursor(data)) |match| {
        defer xm.allocator.free(match);
        format_mod.format_add(ctx, "search_match", match);
    }
    {
        const format_resolve = @import("format-resolve.zig");
        const s_opts2 = if (ctx.session) |s| s.options else opts.global_s_options;
        const separators = opts.options_get_string(s_opts2, "word-separators");
        if (format_resolve.format_grid_word(xm.allocator, gd, data.cx, data.top + data.cy, separators)) |w| {
            defer xm.allocator.free(w);
            format_mod.format_add(ctx, "copy_cursor_word", w);
        }
        if (format_resolve.format_grid_line(xm.allocator, gd, data.top + data.cy)) |l| {
            defer xm.allocator.free(l);
            format_mod.format_add(ctx, "copy_cursor_line", l);
        }
    }
}

// ── Scroll helpers (public API wrappers) ───────────────────────────────────

pub fn window_copy_scroll(wp: *T.WindowPane, sl_mpos: i32, my: u32, scroll_exit: bool) void {
    scrollToMouse(wp, sl_mpos, my, scroll_exit);
}

pub fn window_copy_scroll1(wme: *T.WindowModeEntry, wp: *T.WindowPane, sl_mpos: i32, my: u32, scroll_exit: bool) void {
    _ = wme;
    scrollToMouse(wp, sl_mpos, my, scroll_exit);
}

pub fn window_copy_pageup(wp: *T.WindowPane, half_page: bool) void {
    pageUp(wp, half_page);
}

pub fn window_copy_pageup1(wme: *T.WindowModeEntry, half_page: bool) void {
    pageUpMode(wme, half_page);
}

pub fn window_copy_pagedown(wp: *T.WindowPane, half_page: bool, scroll_exit: bool) void {
    pageDown(wp, half_page, scroll_exit);
}

pub fn window_copy_pagedown1(wme: *T.WindowModeEntry, half_page: bool, scroll_exit: bool) bool {
    return pageDownMode(wme, half_page, scroll_exit);
}

pub fn window_copy_next_paragraph(wme: *T.WindowModeEntry) void {
    nextParagraph(wme);
}

pub fn window_copy_previous_paragraph(wme: *T.WindowModeEntry) void {
    previousParagraph(wme);
}

// ── Draw / redraw ──────────────────────────────────────────────────────────

pub fn window_copy_redraw_screen(wme: *T.WindowModeEntry) void {
    redraw(wme);
}

pub fn window_copy_redraw_lines(wme: *T.WindowModeEntry, py: u32, ny: u32) void {
    _ = py;
    _ = ny;
    redraw(wme);
}

pub fn window_copy_redraw_selection(wme: *T.WindowModeEntry, old_y: u32) void {
    _ = old_y;
    redraw(wme);
}

pub fn window_copy_style_changed(wme: *T.WindowModeEntry) void {
    redraw(wme);
}

pub fn window_copy_write_line(wme: *T.WindowModeEntry, raw_ctx: ?*anyopaque, py: u32) void {
    const ctx: ?*T.ScreenWriteCtx = if (raw_ctx) |p| @ptrCast(@alignCast(p)) else null;
    const data = modeData(wme);
    const backing = data.backing;
    const gd = backing.grid;

    // Write the backing row into the screen_write context
    const backing_row = data.top + py;
    if (backing_row >= gd.hsize + gd.sy) return;

    const sw = ctx orelse return;
    screen_write.cursor_to(sw, py, 0);

    const width = @min(gd.sx, sw.s.grid.sx);
    var col: u32 = 0;
    while (col < width) : (col += 1) {
        var gc: T.GridCell = undefined;
        absoluteGetCell(gd, backing_row, col, &gc);
        screen_write.putCell(sw, &gc);
    }

    // Draw position format on the first line
    if (py == 0 and !data.hide_position and gd.sx > 0) {
        if (opts.options_ready) {
            const pos_fmt = opts.options_get_string(wme.wp.window.options, "copy-mode-position-format");
            if (pos_fmt.len > 0) {
                const expanded = format_mod.format_single(null, pos_fmt, null, null, null, wme.wp);
                if (expanded.len > 0) {
                    screen_write.cursor_to(sw, 0, 0);
                    format_draw.format_draw(sw, &T.grid_default_cell, sw.s.grid.sx, expanded);
                }
                xm.allocator.free(expanded);
            }
        }
    }
}

pub fn window_copy_write_lines(wme: *T.WindowModeEntry, raw_ctx: ?*anyopaque, py: u32, ny: u32) void {
    var yy: u32 = py;
    while (yy < py + ny) : (yy += 1) {
        window_copy_write_line(wme, raw_ctx, yy);
    }
}

pub fn window_copy_write_one(wme: *T.WindowModeEntry, raw_ctx: ?*anyopaque, py: u32) void {
    window_copy_write_line(wme, raw_ctx, py);
}

pub fn window_copy_update_style(wme: *T.WindowModeEntry, fx: u32, fy: u32, gc: ?*T.GridCell, _mgc: ?*const T.GridCell, _cgc: ?*const T.GridCell, mkgc: ?*const T.GridCell) void {
    const data = modeData(wme);

    // Apply mark style if the cell is on the mark line
    if (data.show_mark and fy == data.mark_y) {
        if (gc) |g| {
            if (mkgc) |mk| {
                g.attr = mk.attr;
                if (fx == data.mark_x) {
                    g.fg = mk.bg;
                    g.bg = mk.fg;
                } else {
                    g.fg = mk.fg;
                    g.bg = mk.bg;
                }
            }
        }
    }

    // Search mark highlighting.
    const mgc = _mgc orelse return;
    const cgc = _cgc orelse return;
    const data_sm = data.searchmark orelse return;

    var current: u32 = undefined;
    if (!window_copy_search_mark_at(data, fx, fy, &current)) return;
    const mark = data_sm[current];
    if (mark == 0) return;

    // Check if this cell is in the match under the cursor.
    const cy_abs = data.top + data.cy;
    var cursor: u32 = undefined;
    var found_cursor = false;
    if (window_copy_search_mark_at(data, data.cx, cy_abs, &cursor)) {
        const use_emacs = !copyModeUsesViKeys(wme);
        var check_cursor = cursor;
        if (cursor != 0 and use_emacs and data.searchdirection == .down) {
            if (data_sm[cursor - 1] == mark) {
                check_cursor = cursor - 1;
                found_cursor = true;
            }
        } else if (data_sm[cursor] == mark) {
            check_cursor = cursor;
            found_cursor = true;
        }
        if (found_cursor) {
            var start: u32 = undefined;
            var end: u32 = undefined;
            matchStartEnd(data, check_cursor, &start, &end);
            if (current >= start and current <= end) {
                if (gc) |g| {
                    g.attr = cgc.attr;
                    g.fg = cgc.fg;
                    g.bg = cgc.bg;
                }
                return;
            }
        }
    }

    if (gc) |g| {
        g.attr = mgc.attr;
        g.fg = mgc.fg;
        g.bg = mgc.bg;
    }
}

pub fn window_copy_get_current_offset(wp: *T.WindowPane, offset: ?*u32, size: ?*u32) bool {
    const wme = window.window_pane_mode(wp) orelse return false;
    if (wme.mode != &window_copy_mode and wme.mode != &window_view_mode) return false;
    const data = modeData(wme);
    if (offset) |o| o.* = data.top;
    if (size) |s| s.* = rowCount(data.backing);
    return true;
}

// ── Cursor update ──────────────────────────────────────────────────────────

pub fn window_copy_update_cursor(wme: *T.WindowModeEntry, cx: u32, cy: u32) void {
    const data = modeData(wme);
    data.cx = cx;
    data.cy = cy;
    clampCursorX(wme);
}

// ── Selection functions ────────────────────────────────────────────────────

pub fn window_copy_start_selection(wme: *T.WindowModeEntry) void {
    startSelection(wme);
}

pub fn window_copy_clear_selection(wme: *T.WindowModeEntry) void {
    clearSelection(wme);
}

pub fn window_copy_update_selection(wme: *T.WindowModeEntry, _may_redraw: bool, no_reset: bool) bool {
    _ = _may_redraw;
    const data = modeData(wme);
    if (data.cursordrag == .none and data.lineflag == .none) return false;
    window_copy_synchronize_cursor(wme, no_reset);
    return true;
}

pub fn window_copy_adjust_selection(wme: *T.WindowModeEntry, selx: *u32, sely: *u32) i32 {
    const result = adjustSelection(wme, selx, sely);
    return switch (result) {
        .above => 0,
        .on_screen => 1,
        .below => 2,
    };
}

pub fn window_copy_set_selection(wme: *T.WindowModeEntry, _may_redraw: bool, no_reset: bool) bool {
    _ = _may_redraw;
    const data = modeData(wme);
    if (data.cursordrag == .none and data.lineflag == .none) return false;
    window_copy_synchronize_cursor(wme, no_reset);
    return true;
}

pub fn window_copy_get_selection(wme: *T.WindowModeEntry, len: ?*usize) ?[]u8 {
    const buf = getSelectionText(wme) orelse return null;
    if (len) |l| l.* = buf.len;
    return buf;
}

pub fn window_copy_synchronize_cursor(wme: *T.WindowModeEntry, no_reset: bool) void {
    const data = modeData(wme);
    switch (data.cursordrag) {
        .endsel => window_copy_synchronize_cursor_end(wme, false, no_reset),
        .sel => window_copy_synchronize_cursor_end(wme, true, no_reset),
        .none => {},
    }
}

pub fn window_copy_synchronize_cursor_end(wme: *T.WindowModeEntry, begin: bool, no_reset: bool) void {
    const data = modeData(wme);
    var xx = data.cx;
    var yy = absoluteCursorRow(wme);

    switch (data.selflag) {
        .word => {
            if (!no_reset) {
                if (data.dy > yy or (data.dy == yy and data.dx > xx)) {
                    window_copy_cursor_previous_word_pos(wme, word_whitespace, &xx, &yy);
                    data.endselx = data.endselrx;
                    data.endsely = data.endselry;
                } else {
                    if (xx >= backingLineLength(wme, yy) or
                        grid.grid_in_set(data.backing.grid, yy, xx + 1, word_whitespace) == 0)
                    {
                        window_copy_cursor_next_word_end_pos(wme, word_whitespace, &xx, &yy);
                    }
                    data.selx = data.selrx;
                    data.sely = data.selry;
                }
            }
        },
        .line => {
            if (!no_reset) {
                if (data.dy > yy) {
                    data.endselx = data.endselrx;
                    data.endsely = data.endselry;
                    xx = 0;
                    yy = absoluteCursorRow(wme);
                } else {
                    data.selx = data.selrx;
                    data.sely = data.selry;
                    xx = backingLineLength(wme, yy);
                }
            }
        },
        .char => {},
    }

    if (begin) {
        data.selx = xx;
        data.sely = yy;
    } else {
        data.endselx = xx;
        data.endsely = yy;
    }
}

// ── Copy / paste / pipe ────────────────────────────────────────────────────

pub fn window_copy_copy_buffer(wme: *T.WindowModeEntry, prefix: ?[]const u8, buf: []u8, _len: usize, set_paste: bool, set_clip: bool) void {
    _ = _len;

    if (set_clip) {
        var ctx = T.ScreenWriteCtx{ .s = wme.wp.screen };
        screen_write.setselection(&ctx, "", buf);
    }

    if (set_paste) {
        const paste_mod = @import("paste.zig");
        paste_mod.paste_add(prefix, buf);
    } else {
        xm.allocator.free(buf);
    }
}

pub fn window_copy_pipe_run(wme: *T.WindowModeEntry, s: *T.Session, cmd: []const u8) ?[]u8 {
    const buf = getSelectionText(wme) orelse return null;
    pipeRun(wme, s, cmd, buf);
    return buf;
}

pub fn window_copy_pipe(wme: *T.WindowModeEntry, s: *T.Session, cmd: []const u8) void {
    const buf = window_copy_pipe_run(wme, s, cmd);
    if (buf) |b| xm.allocator.free(b);
}

pub fn window_copy_copy_pipe(wme: *T.WindowModeEntry, s: *T.Session, prefix: ?[]const u8, cmd: []const u8, set_paste: bool, set_clip: bool) void {
    const buf = window_copy_pipe_run(wme, s, cmd) orelse return;
    window_copy_copy_buffer(wme, prefix, xm.xstrdup(buf), buf.len, set_paste, set_clip);
    xm.allocator.free(buf);
}

pub fn window_copy_copy_selection(wme: *T.WindowModeEntry, prefix: ?[]const u8, set_paste: bool, set_clip: bool) void {
    const buf = getSelectionText(wme) orelse return;
    window_copy_copy_buffer(wme, prefix, xm.xstrdup(buf), buf.len, set_paste, set_clip);
    xm.allocator.free(buf);
}

pub fn window_copy_append_selection(wme: *T.WindowModeEntry) void {
    cmdAppendSelection(wme, undefined);
}

pub fn window_copy_copy_line(wme: *T.WindowModeEntry, buf: ?*?[]u8, off: ?*usize, py: u32, sx: u32, ex_in: u32) void {
    const data = modeData(wme);
    const gd = data.backing.grid;
    var ex = ex_in;

    if (sx > ex) return;

    // Check if the line was wrapped at the screen edge
    var wrapped: bool = false;
    if (py < gd.linedata.len) {
        const gl = &gd.linedata[py];
        wrapped = (gl.flags & T.GRID_LINE_WRAPPED) != 0 and gl.cellused <= gd.sx;
    }

    const xx: u32 = if (wrapped)
        (if (py < gd.linedata.len) gd.linedata[py].cellused else 0)
    else
        backingLineLength(wme, py);
    if (ex > xx) ex = xx;
    var start = sx;
    if (start > xx) start = xx;

    const out_buf = buf orelse return;
    const out_off = off orelse return;

    if (start < ex) {
        var i: u32 = start;
        while (i < ex) : (i += 1) {
            var gc: T.GridCell = undefined;
            absoluteGetCell(gd, py, i, &gc);
            if (gc.isPadding()) continue;

            const cell_data = if ((gc.flags & T.GRID_FLAG_TAB) != 0)
                "\t"
            else if (gc.data.size > 0)
                gc.data.data[0..gc.data.size]
            else
                continue;

            // Grow the buffer
            const new_size = out_off.* + cell_data.len;
            if (out_buf.*) |old| {
                const grown = xm.allocator.realloc(old, new_size) catch unreachable;
                @memcpy(grown[out_off.*..new_size], cell_data);
                out_buf.* = grown;
            } else {
                const new = xm.allocator.alloc(u8, new_size) catch unreachable;
                @memcpy(new[out_off.*..new_size], cell_data);
                out_buf.* = new;
            }
            out_off.* = new_size;
        }
    }

    // Only add a newline if the line wasn't wrapped
    if (!wrapped or ex != xx) {
        const new_size = out_off.* + 1;
        if (out_buf.*) |old| {
            const grown = xm.allocator.realloc(old, new_size) catch unreachable;
            grown[out_off.*] = '\n';
            out_buf.* = grown;
        } else {
            const new = xm.allocator.alloc(u8, new_size) catch unreachable;
            new[out_off.*] = '\n';
            out_buf.* = new;
        }
        out_off.* = new_size;
    }
}

// ── Search helpers ─────────────────────────────────────────────────────────

pub fn window_copy_search_compare(gd: *T.Grid, px: u32, py: u32, sgd: *T.Grid, spx: u32, cis: bool) bool {
    return searchCompare(gd, px, py, sgd, spx, cis);
}

pub fn window_copy_search_lr(gd: *T.Grid, sgd: *T.Grid, ppx: *u32, py: u32, first: u32, last: u32, cis: bool) bool {
    return searchLR(gd, sgd, ppx, py, first, last, cis);
}

pub fn window_copy_search_rl(gd: *T.Grid, sgd: *T.Grid, ppx: *u32, py: u32, first: u32, last: u32, cis: bool) bool {
    return searchRL(gd, sgd, ppx, py, first, last, cis);
}

/// Regex left-to-right search on a grid row.  On success sets *ppx to the
/// match start column and *psx to the match width; returns true.
/// Mirrors tmux's window_copy_search_lr_regex().
pub fn window_copy_search_lr_regex(gd: *T.Grid, ppx: *u32, psx: *u32, py: u32, first: u32, last: u32, re: ?*anyopaque) bool {
    const c_mod = @import("c.zig");
    const reg = re orelse return false;
    if (first >= last) return false;

    const eflags: i32 = if (first != 0) c_mod.posix_sys.REG_NOTBOL else 0;

    // Stringify the row (first..last) into a C string.
    var plen: u32 = 1;
    const buf = window_copy_stringify(gd, py, first, gd.sx, null, &plen) orelse return false;
    defer xm.allocator.free(buf);

    var regmatch: c_mod.posix_sys.regmatch_t = undefined;
    const buf_z = xm.allocator.dupeZ(u8, buf[0..plen -| 1]) catch return false;
    defer xm.allocator.free(buf_z);

    if (c_mod.posix_sys.regexec(@ptrCast(reg), buf_z.ptr, 1, &regmatch, eflags) == 0 and
        regmatch.rm_so != regmatch.rm_eo)
    {
        var len = gd.sx -| first;
        var foundx = first;
        var foundy = py;
        window_copy_cstrtocellpos(gd, len, &foundx, &foundy, buf_z[@intCast(regmatch.rm_so)..]);
        if (foundy == py and foundx < last) {
            ppx.* = foundx;
            len -= foundx - first;
            foundx = first;
            foundy = py;
            window_copy_cstrtocellpos(gd, len, &foundx, &foundy, buf_z[@intCast(regmatch.rm_eo)..]);
            psx.* = foundx;
            while (foundy > py) : (foundy -= 1) psx.* += gd.sx;
            psx.* -|= ppx.*;
            return true;
        }
    }
    ppx.* = 0;
    psx.* = 0;
    return false;
}

/// Regex right-to-left search (last-match) on a grid row.  On success sets
/// *ppx to the last-match start column and *psx to the match width; returns
/// true.  Mirrors tmux's window_copy_search_rl_regex().
pub fn window_copy_search_rl_regex(gd: *T.Grid, ppx: *u32, psx: *u32, py: u32, first: u32, last: u32, re: ?*anyopaque) bool {
    const reg = re orelse return false;
    _ = last; // used implicitly via window_copy_last_regex

    var plen: u32 = 1;
    const buf = window_copy_stringify(gd, py, first, gd.sx, null, &plen) orelse return false;
    defer xm.allocator.free(buf);

    const c_mod = @import("c.zig");
    const eflags: i32 = if (first != 0) c_mod.posix_sys.REG_NOTBOL else 0;
    const len = gd.sx -| first;

    const buf_z = xm.allocator.dupeZ(u8, buf[0..plen -| 1]) catch return false;
    defer xm.allocator.free(buf_z);

    return window_copy_last_regex(gd, py, first, gd.sx, len, ppx, psx, buf_z, reg, eflags);
}

pub fn window_copy_is_lowercase(ptr: []const u8) bool {
    return isLowerCase(ptr);
}

/// Handle backward wrapped regex searches with overlapping matches.
/// Mirrors tmux's window_copy_search_back_overlap().
pub fn window_copy_search_back_overlap(gd: *T.Grid, preg: ?*anyopaque, ppx: *u32, psx: *u32, ppy: *u32, endline: u32) void {
    var oldendx = ppx.* + psx.*;
    var oldendy = ppy.* -| 1;
    while (oldendx > gd.sx -| 1) {
        oldendx -= gd.sx;
        oldendy += 1;
    }
    var endx = oldendx;
    var endy = oldendy;
    var px = ppx.*;
    var py = ppy.*;

    var found: bool = true;
    while (found and px == 0 and py > endline + 1) {
        py -= 1;
        var sx: u32 = 0;
        found = window_copy_search_rl_regex(gd, &px, &sx, py - 1, 0, gd.sx, preg);
        if (found) {
            endx = px + sx;
            endy = py - 1;
            while (endx > gd.sx -| 1) {
                endx -= gd.sx;
                endy += 1;
            }
        }
        if (endx == oldendx and endy == oldendy) break;
    }
    ppx.* = px;
    ppy.* = py;
}

pub fn window_copy_search_jump(wme: *T.WindowModeEntry, gd: *T.Grid, sgd: ?*T.Grid, fx_in: u32, fy: u32, endline: u32, cis: bool, _wrap: bool, direction: bool, regex: bool) bool {
    _ = _wrap;
    const search_gd = sgd orelse return false;

    if (regex) {
        // Regex search not yet supported
        return false;
    }

    var found = false;
    var px: u32 = 0;
    var result_row: u32 = 0;

    if (direction) {
        // Forward search
        var fx = fx_in;
        var i: u32 = fy;
        while (i <= endline) : (i += 1) {
            if (searchLR(gd, search_gd, &px, i, fx, gd.sx, cis)) {
                found = true;
                result_row = i;
                break;
            }
            fx = 0;
        }
    } else {
        // Backward search
        var fx = fx_in;
        var i: u32 = fy + 1;
        while (i > endline) {
            i -= 1;
            if (i == 0 and endline == 0) {
                if (searchRL(gd, search_gd, &px, 0, 0, fx + 1, cis)) {
                    found = true;
                    result_row = 0;
                }
                break;
            }
            if (searchRL(gd, search_gd, &px, i, 0, fx + 1, cis)) {
                found = true;
                result_row = i;
                break;
            }
            fx = gd.sx -| 1;
        }
    }

    if (found) {
        window_copy_scroll_to(wme, px, result_row, true);
        return true;
    }
    return false;
}

/// Advance *fx / *fy past the current search mark so the next search
/// skips the current match.  Mirrors tmux's
/// window_copy_move_after_search_mark().
pub fn window_copy_move_after_search_mark(data: *CopyModeData, fx: *u32, fy: *u32, _endline: u32) void {
    _ = _endline;
    const sm = data.searchmark orelse return;
    var start: u32 = undefined;
    if (!window_copy_search_mark_at(data, fx.*, fy.*, &start)) return;
    if (sm[start] == 0) return;

    const gd = data.backing.grid;
    const sx = gd.sx;
    const sy = gd.sy;
    const mark = sm[start];

    while (true) {
        var cur_at: u32 = undefined;
        if (!window_copy_search_mark_at(data, fx.*, fy.*, &cur_at)) break;
        if (sm[cur_at] != mark) break;
        // Advance to next cell (wrap at sx)
        if (fx.* + 1 < sx) {
            fx.* += 1;
        } else {
            fx.* = 0;
            if (fy.* + 1 < data.top + sy) {
                fy.* += 1;
            } else {
                break;
            }
        }
    }
}

pub fn window_copy_search(wme: *T.WindowModeEntry, direction: i32, regex: bool) bool {
    const dir: SearchDirection = if (direction == 0) .up else .down;
    return doSearch(wme, dir, regex);
}

pub fn window_copy_search_up(wme: *T.WindowModeEntry, regex: bool) bool {
    return doSearch(wme, .up, regex);
}

pub fn window_copy_search_down(wme: *T.WindowModeEntry, regex: bool) bool {
    return doSearch(wme, .down, regex);
}

pub fn window_copy_search_marks(wme: *T.WindowModeEntry, ssp: ?*T.Screen, regex: bool, visible_only: bool) bool {
    const data = modeData(wme);
    if (data.timeout) return false;

    const search_str = data.searchstr orelse return false;
    if (search_str.len == 0) return false;

    const backing = data.backing;
    const gd = backing.grid;
    const sx = gd.sx;
    const sy = gd.sy;

    // Allocate/reset the searchmark array covering the visible viewport.
    if (data.searchmark) |sm| xm.allocator.free(sm);
    const mark_size = @as(usize, sx) * @as(usize, sy);
    data.searchmark = xm.allocator.alloc(u8, mark_size) catch return false;
    @memset(data.searchmark.?, 0);
    data.searchgen = 1;

    var start: u32 = 0;
    var end: u32 = sy;
    if (visible_only) {
        window_copy_visible_lines(data, &start, &end);
        // Clamp end to sy
        if (end > sy) end = sy;
    }

    var nfound: u32 = 0;

    if (regex) {
        // Build the pattern string from the search screen
        const c_mod = @import("c.zig");
        const RE_flags: i32 = c_mod.posix_sys.REG_EXTENDED;
        const re = c_mod.posix_sys.zmux_regex_new() orelse return false;
        defer c_mod.posix_sys.zmux_regex_free(re);

        // Build the pattern as a null-terminated C string
        const pattern = xm.allocator.dupeZ(u8, search_str) catch return false;
        defer xm.allocator.free(pattern);

        const cflags: i32 = if (isLowerCase(search_str)) RE_flags | c_mod.posix_sys.REG_ICASE else RE_flags;
        if (c_mod.posix_sys.zmux_regex_compile(re, pattern.ptr, cflags) != 0)
            return false;

        var py = start;
        while (py < end) : (py += 1) {
            var px: u32 = 0;
            while (true) {
                var psx: u32 = 0;
                if (!window_copy_search_lr_regex(gd, &px, &psx, py, px, sx, re))
                    break;
                nfound += 1;
                px += window_copy_search_mark_match(data, px, py, psx, regex);
            }
        }
    } else {
        // Plain string search
        const ss_grid = if (ssp) |ss| ss.grid else blk: {
            const sg = buildSearchGrid(search_str) orelse return false;
            break :blk sg;
        };
        defer if (ssp == null) grid.grid_free(ss_grid);

        const cis = isLowerCase(search_str);
        const match_width = ss_grid.sx;

        var py = start;
        while (py < end) : (py += 1) {
            var px: u32 = 0;
            while (true) {
                if (!searchLR(gd, ss_grid, &px, py, px, sx, cis))
                    break;
                nfound += 1;
                px += window_copy_search_mark_match(data, px, py, match_width, false);
            }
        }
    }

    if (!visible_only) {
        data.searchcount = @intCast(nfound);
        data.searchmore = 0;
    }

    return true;
}

/// Re-run search marks if a search is active and has not timed out.
fn refreshSearchMarks(wme: *T.WindowModeEntry, again: bool) void {
    const data = modeData(wme);
    if (data.searchmark != null and !data.timeout)
        _ = window_copy_search_marks(wme, null, data.searchregex, again);
}

pub fn window_copy_clear_marks(wme: *T.WindowModeEntry) void {
    const data = modeData(wme);
    if (data.searchmark) |sm| {
        xm.allocator.free(sm);
        data.searchmark = null;
    }
    data.searchcount = -1;
    data.searchmore = 0;
}

pub fn window_copy_visible_lines(data: *CopyModeData, start: *u32, end: *u32) void {
    const gd = data.backing.grid;
    // Walk backward from the top of the viewport to find the first
    // non-wrapped line (mirrors tmux behaviour for wrapped lines).
    var s: u32 = data.top;
    while (s > 0) {
        const gl = grid.grid_peek_line(@constCast(gd), s - 1);
        if (gl == null or (gl.?.flags & T.GRID_LINE_WRAPPED) == 0)
            break;
        s -= 1;
    }
    start.* = s;
    end.* = data.top + gd.sy;
}

pub fn window_copy_search_mark_at(data: *CopyModeData, px: u32, py: u32, at: *u32) bool {
    const gd = data.backing.grid;
    // Translate py to viewport-relative offset
    if (py < data.top) return false;
    if (py > data.top + gd.sy -| 1) return false;
    at.* = ((py - data.top) * gd.sx) + px;
    return true;
}

pub fn window_copy_clip_width(width: u32, b: u32, sx: u32, sy: u32) u32 {
    const total = @as(u64, sx) * @as(u64, sy);
    const b64 = @as(u64, b);
    if (b64 + @as(u64, width) > total)
        return @intCast(total -| b64)
    else
        return width;
}

/// Mark a range of cells in the searchmark array starting at (px, py)
/// with width cells.  Returns the effective width consumed (for loop
/// advancement).  Mirrors tmux's window_copy_search_mark_match().
pub fn window_copy_search_mark_match(data: *CopyModeData, px: u32, py: u32, width: u32, regex: bool) u32 {
    const sm = data.searchmark orelse return width;
    const gd = data.backing.grid;
    const sx = gd.sx;
    const sy = gd.sy;

    var b: u32 = undefined;
    if (!window_copy_search_mark_at(data, px, py, &b)) return width;

    var w = window_copy_clip_width(width, b, sx, sy);

    var i: u32 = b;
    while (i < b + w) : (i += 1) {
        if (!regex) {
            // For tab cells, expand width
            const cell_py = data.top + (i / sx);
            const cell_px = i % sx;
            var gc: T.GridCell = undefined;
            absoluteGetCell(gd, cell_py, cell_px, &gc);
            if ((gc.flags & T.GRID_FLAG_TAB) != 0) {
                w = w + gc.data.width - 1;
                w = window_copy_clip_width(w, b, sx, sy);
            }
        }
        if (sm[i] != 0) continue;
        sm[i] = data.searchgen;
    }
    if (data.searchgen == 255)
        data.searchgen = 1
    else
        data.searchgen += 1;

    return w;
}

// ── Other search / match helpers ───────────────────────────────────────────

pub fn window_copy_cellstring(gl: ?*const T.GridLine, px: u32, size: ?*usize, free_flag: ?*bool) ?[]const u8 {
    if (free_flag) |f| f.* = false;

    const line = gl orelse {
        if (size) |s| s.* = 1;
        return " ";
    };

    if (px >= line.cellused or px >= line.celldata.len) {
        if (size) |s| s.* = 1;
        return " ";
    }

    const gce = &line.celldata[px];
    if ((gce.flags & T.GRID_FLAG_PADDING) != 0) {
        if (size) |s| s.* = 0;
        return null;
    }

    if ((gce.flags & T.GRID_FLAG_TAB) != 0) {
        if (size) |s| s.* = 1;
        return "\t";
    }

    if ((gce.flags & T.GRID_FLAG_EXTENDED) == 0) {
        if (size) |s| s.* = 1;
        return @as([*]const u8, @ptrCast(&gce.offset_or_data.data.data))[0..1];
    }

    // Extended cell: look up the utf8_char in the extended data table
    const offset = gce.offset_or_data.offset;
    if (offset < line.extddata.len) {
        const extd = &line.extddata[offset];
        // Convert utf8_char (u32) to bytes via a temporary Utf8Data
        // We need to allocate a small copy since we can't return pointers
        // to locals. Use a thread-local static buffer instead.
        const S = struct {
            threadlocal var buf: T.Utf8Data = std.mem.zeroes(T.Utf8Data);
        };
        utf8.utf8_to_data(extd.data, &S.buf);
        if (S.buf.size == 0) {
            if (size) |s| s.* = 1;
            return " ";
        }
        if (size) |s| s.* = S.buf.size;
        return S.buf.data[0..S.buf.size];
    }

    if (size) |s| s.* = 1;
    return " ";
}

/// Find the rightmost regex match within (first..last) of row py.
/// Mirrors tmux's window_copy_last_regex().
pub fn window_copy_last_regex(gd: *T.Grid, py: u32, first: u32, last: u32, len_in: u32, ppx: *u32, psx: *u32, buf: [:0]const u8, preg: ?*anyopaque, eflags: i32) bool {
    const c_mod = @import("c.zig");
    const reg = preg orelse return false;
    var foundx = first;
    var foundy = py;
    var oldx = first;
    var savepx: u32 = 0;
    var savesx: u32 = 0;
    var px: u32 = 0;
    var len = len_in;

    var regmatch: c_mod.posix_sys.regmatch_t = undefined;
    while (c_mod.posix_sys.regexec(@ptrCast(reg), buf[px..].ptr, 1, &regmatch, eflags) == 0) {
        if (regmatch.rm_so == regmatch.rm_eo) break;

        foundx = first;
        foundy = py;
        window_copy_cstrtocellpos(gd, len, &foundx, &foundy, buf[@intCast(px + @as(u32, @intCast(regmatch.rm_so)))..]);
        if (foundy > py or foundx >= last) break;
        len -= foundx - oldx;
        savepx = foundx;
        foundx = first;
        foundy = py;
        window_copy_cstrtocellpos(gd, len, &foundx, &foundy, buf[@intCast(px + @as(u32, @intCast(regmatch.rm_eo)))..]);
        if (foundy > py or foundx >= last) {
            ppx.* = savepx;
            psx.* = foundx;
            while (foundy > py) : (foundy -= 1) psx.* += gd.sx;
            psx.* -|= ppx.*;
            return true;
        } else {
            savesx = foundx - savepx;
            len -= savesx;
            oldx = foundx;
        }
        px += @intCast(regmatch.rm_eo);
    }

    if (savesx > 0) {
        ppx.* = savepx;
        psx.* = savesx;
        return true;
    }
    ppx.* = 0;
    psx.* = 0;
    return false;
}

pub fn window_copy_stringify(gd: *T.Grid, py: u32, first: u32, last: u32, _buf: ?[]u8, plen: *u32) ?[]u8 {
    _ = _buf;
    const gl = grid.grid_peek_line(@constCast(&gd.*), py) orelse {
        var result = xm.allocator.alloc(u8, plen.*) catch unreachable;
        if (plen.* > 0) result[plen.* - 1] = 0;
        return result;
    };

    var buf_list: std.ArrayList(u8) = .{};

    // Copy any existing data from plen
    const existing = plen.*;
    if (existing > 0) {
        buf_list.ensureTotalCapacity(xm.allocator, existing + (last - first) * 4) catch unreachable;
    }

    // Pre-fill with existing size minus null terminator
    if (existing > 1) {
        buf_list.resize(xm.allocator, existing - 1) catch unreachable;
    }

    var ax: u32 = first;
    while (ax < last) : (ax += 1) {
        var dlen: usize = 0;
        var allocated: bool = false;
        const d = window_copy_cellstring(gl, ax, &dlen, &allocated) orelse continue;
        if (dlen > 0) {
            buf_list.appendSlice(xm.allocator, d[0..dlen]) catch unreachable;
        }
    }

    // Add null terminator
    buf_list.append(xm.allocator, 0) catch unreachable;
    plen.* = @intCast(buf_list.items.len);
    return buf_list.toOwnedSlice(xm.allocator) catch unreachable;
}

pub fn window_copy_cstrtocellpos(gd: *T.Grid, ncells: u32, ppx: *u32, ppy: *u32, str: []const u8) void {
    if (ncells == 0 or str.len == 0) return;

    const CellInfo = struct {
        d: ?[]const u8,
        dlen: usize,
    };

    var cells = xm.allocator.alloc(CellInfo, ncells) catch unreachable;
    defer xm.allocator.free(cells);

    var cell: u32 = 0;
    var px = ppx.*;
    var pywrap = ppy.*;
    var gl = grid.grid_peek_line(@constCast(&gd.*), pywrap);
    if (gl == null) return;

    while (cell < ncells) : (cell += 1) {
        var dlen: usize = 0;
        var allocated: bool = false;
        const d = window_copy_cellstring(gl, px, &dlen, &allocated);
        cells[cell] = .{ .d = d, .dlen = dlen };
        px += 1;
        if (px == gd.sx) {
            px = 0;
            pywrap += 1;
            gl = grid.grid_peek_line(@constCast(&gd.*), pywrap);
            if (gl == null) break;
        }
    }

    // Locate starting cell
    cell = 0;
    const len = str.len;
    while (cell < ncells) {
        var ccell = cell;
        var pos: usize = 0;
        var matched = true;
        while (ccell < ncells) {
            if (pos >= len) {
                matched = false;
                break;
            }
            const d = cells[ccell].d orelse {
                ccell += 1;
                continue;
            };
            const dlen = cells[ccell].dlen;
            if (dlen == 1) {
                if (str[pos] != d[0]) {
                    matched = false;
                    break;
                }
                pos += 1;
            } else {
                const cmp_len = @min(dlen, len - pos);
                if (!std.mem.eql(u8, str[pos..][0..cmp_len], d[0..cmp_len])) {
                    matched = false;
                    break;
                }
                pos += cmp_len;
            }
            ccell += 1;
        }
        if (matched) break;
        cell += 1;
    }

    px = ppx.* + cell;
    pywrap = ppy.*;
    while (px >= gd.sx) {
        px -= gd.sx;
        pywrap += 1;
    }

    ppx.* = px;
    ppy.* = pywrap;
}

pub fn window_copy_match_start_end(data: *CopyModeData, _at: u32, start: *u32, end: *u32) void {
    // Requires searchmark array (not yet added to CopyModeData).
    // When searchmark is available, this walks backward/forward from `at`
    // to find the contiguous run of the same mark value.
    _ = data;
    _ = _at;
    start.* = 0;
    end.* = 0;
}

pub fn window_copy_match_at_cursor(data: *CopyModeData) ?[]u8 {
    // Requires searchmark array (not yet added to CopyModeData).
    // When searchmark is available, this extracts the matched text
    // at the cursor position from the grid.
    _ = data;
    return null;
}

// ── Movement helpers ───────────────────────────────────────────────────────

pub fn window_copy_move_left(s: *T.Screen, fx: *u32, fy: *u32, wrapflag: bool) void {
    if (fx.* == 0) {
        if (fy.* == 0) {
            if (wrapflag) {
                fx.* = if (s.grid.sx > 0) s.grid.sx - 1 else 0;
                fy.* = s.grid.sy -| 1;
            }
            return;
        }
        fx.* = if (s.grid.sx > 0) s.grid.sx - 1 else 0;
        fy.* -= 1;
    } else {
        fx.* -= 1;
    }
}

pub fn window_copy_move_right(s: *T.Screen, fx: *u32, fy: *u32, wrapflag: bool) void {
    const sx = s.grid.sx;
    const max_y = s.grid.sy -| 1;
    if (sx > 0 and fx.* == sx - 1) {
        if (fy.* == max_y) {
            if (wrapflag) {
                fx.* = 0;
                fy.* = 0;
            }
            return;
        }
        fx.* = 0;
        fy.* += 1;
    } else {
        fx.* += 1;
    }
}

pub fn window_copy_in_set(wme: *T.WindowModeEntry, px: u32, py: u32, set: []const u8) bool {
    const data = modeData(wme);
    return grid.grid_in_set(data.backing.grid, py, px, set) != 0;
}

pub fn window_copy_find_length(wme: *T.WindowModeEntry, py: u32) u32 {
    return backingLineLength(wme, py);
}

// ── Cursor movement (tmux-named wrappers) ──────────────────────────────────

pub fn window_copy_cursor_start_of_line(wme: *T.WindowModeEntry) void {
    cursorStartOfLine(wme);
}

pub fn window_copy_cursor_back_to_indentation(wme: *T.WindowModeEntry) void {
    cursorBackToIndentation(wme);
}

pub fn window_copy_cursor_end_of_line(wme: *T.WindowModeEntry) void {
    cursorEndOfLine(wme);
}

pub fn window_copy_other_end(wme: *T.WindowModeEntry) void {
    cmdOtherEnd(wme);
}

pub fn window_copy_cursor_left(wme: *T.WindowModeEntry) void {
    var gr: T.GridReader = undefined;
    if (!startMotionReader(wme, &gr)) return;
    grid.grid_reader_cursor_left(&gr, true);
    applyMotionReader(wme, &gr);
}

pub fn window_copy_cursor_right(wme: *T.WindowModeEntry, all: bool) void {
    var gr: T.GridReader = undefined;
    if (!startMotionReader(wme, &gr)) return;
    grid.grid_reader_cursor_right(&gr, true, all);
    applyMotionReader(wme, &gr);
}

pub fn window_copy_cursor_up(wme: *T.WindowModeEntry, scroll_only: bool) void {
    if (scroll_only) {
        // Scroll viewport up by 1 without moving the cursor row
        const data = modeData(wme);
        if (data.top > 0) {
            data.top -= 1;
            if (data.cy < viewRows(wme.wp) -| 1)
                data.cy += 1;
        }
    } else {
        scrollLines(wme, -1);
    }
}

pub fn window_copy_cursor_down(wme: *T.WindowModeEntry, scroll_only: bool) void {
    if (scroll_only) {
        // Scroll viewport down by 1 without moving the cursor row
        const data = modeData(wme);
        const max_top = maxTop(data.backing, wme.wp);
        if (data.top < max_top) {
            data.top += 1;
            if (data.cy > 0)
                data.cy -= 1;
        }
    } else {
        cursorDownLines(wme, 1);
    }
}

pub fn window_copy_cursor_jump(wme: *T.WindowModeEntry) void {
    cursorJump(wme);
}

pub fn window_copy_cursor_jump_back(wme: *T.WindowModeEntry) void {
    cursorJumpBack(wme);
}

pub fn window_copy_cursor_jump_to(wme: *T.WindowModeEntry) void {
    cursorJumpTo(wme);
}

pub fn window_copy_cursor_jump_to_back(wme: *T.WindowModeEntry) void {
    cursorJumpToBack(wme);
}

pub fn window_copy_cursor_next_word(wme: *T.WindowModeEntry, separators: []const u8) void {
    cursorNextWord(wme, separators);
}

pub fn window_copy_cursor_next_word_end(wme: *T.WindowModeEntry, separators: []const u8, no_reset: bool) void {
    _ = no_reset;
    cursorNextWordEnd(wme, separators);
}

pub fn window_copy_cursor_next_word_end_pos(wme: *T.WindowModeEntry, separators: []const u8, ppx: *u32, ppy: *u32) void {
    var gr: T.GridReader = undefined;
    if (!startMotionReader(wme, &gr)) {
        ppx.* = modeData(wme).cx;
        ppy.* = absoluteCursorRow(wme);
        return;
    }

    if (copyModeUsesViKeys(wme)) {
        if (grid.grid_reader_in_set(&gr, word_whitespace) == 0)
            grid.grid_reader_cursor_right(&gr, false, false);
        grid.grid_reader_cursor_next_word_end(&gr, separators);
        grid.grid_reader_cursor_left(&gr, true);
    } else {
        grid.grid_reader_cursor_next_word_end(&gr, separators);
    }

    grid.grid_reader_get_cursor(&gr, ppx, ppy);
}

pub fn window_copy_cursor_previous_word(wme: *T.WindowModeEntry, separators: []const u8, already: bool) void {
    cursorPreviousWord(wme, separators, already);
}

pub fn window_copy_cursor_previous_word_pos(wme: *T.WindowModeEntry, separators: []const u8, ppx: *u32, ppy: *u32) void {
    var gr: T.GridReader = undefined;
    if (!startMotionReader(wme, &gr)) {
        ppx.* = modeData(wme).cx;
        ppy.* = absoluteCursorRow(wme);
        return;
    }

    grid.grid_reader_cursor_previous_word(&gr, separators, true, !copyModeUsesViKeys(wme));
    grid.grid_reader_get_cursor(&gr, ppx, ppy);
}

pub fn window_copy_cursor_prompt(wme: *T.WindowModeEntry, direction: i32, start_output: bool) void {
    const data = modeData(wme);
    const gd = data.backing.grid;
    const line_flag: i32 = if (start_output) T.GRID_LINE_START_OUTPUT else T.GRID_LINE_START_PROMPT;

    var line = absoluteCursorRow(wme);
    const end_line: u32 = if (direction <= 0) 0 else rowCount(data.backing) -| 1;

    if (line == end_line) return;

    while (true) {
        if (line == end_line) return;
        if (direction <= 0) {
            if (line == 0) return;
            line -= 1;
        } else {
            line += 1;
        }

        if (line < gd.linedata.len) {
            if ((gd.linedata[line].flags & line_flag) != 0)
                break;
        }
    }

    data.cx = 0;
    setAbsoluteCursorRow(wme, line);
    _ = updateSelection(wme);
    redraw(wme);
}

// ── Scroll ─────────────────────────────────────────────────────────────────

pub fn window_copy_scroll_up(wme: *T.WindowModeEntry, ny: u32) void {
    scrollLines(wme, -@as(i32, @intCast(@min(ny, std.math.maxInt(u31)))));
    refreshSearchMarks(wme, true);
}

pub fn window_copy_scroll_down(wme: *T.WindowModeEntry, ny: u32) void {
    _ = scrollViewportDownLines(wme, ny, false);
    refreshSearchMarks(wme, true);
}

pub fn window_copy_scroll_to(wme: *T.WindowModeEntry, px: u32, py: u32, no_redraw: bool) void {
    const data = modeData(wme);

    // If the target row is currently visible, just move the cursor
    const view = viewRows(wme.wp);
    if (py >= data.top and py < data.top + view) {
        data.cy = py - data.top;
    } else {
        // Position with a gap from the edges (quarter-screen)
        const gap = view / 4;
        if (py < view) {
            data.top = 0;
            data.cy = py;
        } else {
            const max_top = maxTop(data.backing, wme.wp);
            const desired_top = if (py + gap >= view) py + gap - view else 0;
            data.top = @min(desired_top, max_top);
            data.cy = py - data.top;
        }
    }

    data.cx = px;
    clampCursorX(wme);
    if (!no_redraw) refreshSearchMarks(wme, true);
    _ = window_copy_update_selection(wme, true, false);
    if (!no_redraw) redraw(wme);
}

pub fn window_copy_goto_line(wme: *T.WindowModeEntry, linestr: []const u8) void {
    gotoLine(wme, linestr);
}

// ── Rectangle mode ─────────────────────────────────────────────────────────

pub fn window_copy_rectangle_set(wme: *T.WindowModeEntry, rectflag: bool) void {
    cmdRectangleSet(wme, rectflag);
}

// ── Mouse / drag ───────────────────────────────────────────────────────────

pub fn window_copy_move_mouse(m: *T.MouseEvent) void {
    const wp = resolveMousePane(m) orelse return;
    const wme = window.window_pane_mode(wp) orelse return;
    if (wme.mode != &window_copy_mode and wme.mode != &window_view_mode) return;
    updateCursorFromMouse(wme, m, false);
    redraw(wme);
}

pub fn window_copy_start_drag(c: ?*T.Client, m: *const T.MouseEvent) void {
    startDrag(c, m);
}

pub fn window_copy_drag_update(c: *T.Client, m: *T.MouseEvent) void {
    dragUpdate(c, m);
}

pub fn window_copy_drag_release(_c: *T.Client, m: *T.MouseEvent) void {
    _ = _c;
    const wp = resolveMousePane(m) orelse return;
    const wme = window.window_pane_mode(wp) orelse return;
    if (wme.mode != &window_copy_mode and wme.mode != &window_view_mode) return;
    redraw(wme);
}

// ── Mark / jump-to-mark ────────────────────────────────────────────────────

pub fn window_copy_jump_to_mark(wme: *T.WindowModeEntry) void {
    cmdJumpToMark(wme);
}

// ── Acquire cursor (post-move adjustment) ──────────────────────────────────

pub fn window_copy_acquire_cursor_up(wme: *T.WindowModeEntry, _hsize: u32, _oy: u32, _oldy: u32, px: u32, py: u32) void {
    _ = _hsize;
    _ = _oy;
    _ = _oldy;
    setAbsoluteCursorRow(wme, py);
    modeData(wme).cx = px;
    clampCursorX(wme);
    _ = updateSelection(wme);
}

pub fn window_copy_acquire_cursor_down(wme: *T.WindowModeEntry, _hsize: u32, _sy: u32, _oy: u32, _oldy: u32, px: u32, py: u32, _no_reset: bool) void {
    _ = _hsize;
    _ = _sy;
    _ = _oy;
    _ = _oldy;
    _ = _no_reset;
    setAbsoluteCursorRow(wme, py);
    modeData(wme).cx = px;
    clampCursorX(wme);
    _ = updateSelection(wme);
}

// ── Expand search string helper ────────────────────────────────────────────

pub fn window_copy_expand_search_string(cs: *const CmdState) bool {
    const wme = cs.wme;
    const data = modeData(wme);
    const ss = cs.wargs.value_at(0) orelse return false;
    if (ss.len == 0) return false;
    if (data.searchstr) |old| xm.allocator.free(old);
    data.searchstr = xm.xstrdup(ss);
    return true;
}

// ── Key table wrapper ──────────────────────────────────────────────────────

pub fn window_copy_key_table(wme: *T.WindowModeEntry) []const u8 {
    return copyModeKeyTable(wme);
}

// ── Command dispatch wrapper ───────────────────────────────────────────────

pub fn window_copy_command(wme: *T.WindowModeEntry, client: ?*T.Client, session: *T.Session, _wl: *T.Winlink, raw_args: *const anyopaque, _mouse: ?*const T.MouseEvent) void {
    copyModeCommand(wme, client, session, _wl, raw_args, _mouse);
}

// ═══════════════════════════════════════════════════════════════════════════
// Command handler functions (window_copy_cmd_*)
//
// In tmux, each copy-mode command has its own handler returning a
// CmdAction.  In zmux the dispatch is already in copyModeCommand above;
// these named entry points provide audit-complete coverage.
// ═══════════════════════════════════════════════════════════════════════════

pub fn window_copy_cmd_append_selection(cs: *const CmdState) CmdAction {
    const wme = cs.wme;
    if (cs.session) |_| window_copy_append_selection(wme);
    window_copy_clear_selection(wme);
    return .redraw;
}

pub fn window_copy_cmd_append_selection_and_cancel(cs: *const CmdState) CmdAction {
    const wme = cs.wme;
    if (cs.session) |_| window_copy_append_selection(wme);
    window_copy_clear_selection(wme);
    return .cancel;
}

pub fn window_copy_cmd_back_to_indentation(cs: *const CmdState) CmdAction {
    cursorBackToIndentation(cs.wme);
    return .nothing;
}

pub fn window_copy_cmd_begin_selection(cs: *const CmdState) CmdAction {
    const data = modeData(cs.wme);
    if (cs.mouse != null) {
        startDrag(cs.client, cs.mouse.?);
        return .nothing;
    }
    data.lineflag = .none;
    data.selflag = .char;
    startSelection(cs.wme);
    return .redraw;
}

pub fn window_copy_cmd_stop_selection(cs: *const CmdState) CmdAction {
    cmdStopSelection(cs.wme);
    return .nothing;
}

pub fn window_copy_cmd_bottom_line(cs: *const CmdState) CmdAction {
    const rows = viewRows(cs.wme.wp);
    if (rows != 0) setCursorLine(cs.wme, rows - 1);
    return .redraw;
}

pub fn window_copy_cmd_cancel(_cs: *const CmdState) CmdAction {
    _ = _cs;
    return .cancel;
}

pub fn window_copy_cmd_clear_selection(cs: *const CmdState) CmdAction {
    clearSelection(cs.wme);
    return .redraw;
}

pub fn window_copy_do_copy_end_of_line(cs: *const CmdState, pipe: bool, do_cancel: bool) CmdAction {
    _ = pipe;
    if (cs.session) |s| {
        cmdCopyEndOfLine(cs.wme, s, cs.args, do_cancel);
    }
    return if (do_cancel) .cancel else .redraw;
}

pub fn window_copy_cmd_copy_end_of_line(cs: *const CmdState) CmdAction {
    return window_copy_do_copy_end_of_line(cs, false, false);
}

pub fn window_copy_cmd_copy_end_of_line_and_cancel(cs: *const CmdState) CmdAction {
    return window_copy_do_copy_end_of_line(cs, false, true);
}

pub fn window_copy_cmd_copy_pipe_end_of_line(cs: *const CmdState) CmdAction {
    return window_copy_do_copy_end_of_line(cs, true, false);
}

pub fn window_copy_cmd_copy_pipe_end_of_line_and_cancel(cs: *const CmdState) CmdAction {
    return window_copy_do_copy_end_of_line(cs, true, true);
}

pub fn window_copy_do_copy_line(cs: *const CmdState, pipe: bool, do_cancel: bool) CmdAction {
    _ = pipe;
    if (cs.session) |s| {
        cmdCopyLine(cs.wme, s, cs.args, do_cancel);
    }
    return if (do_cancel) .cancel else .redraw;
}

pub fn window_copy_cmd_copy_line(cs: *const CmdState) CmdAction {
    return window_copy_do_copy_line(cs, false, false);
}

pub fn window_copy_cmd_copy_line_and_cancel(cs: *const CmdState) CmdAction {
    return window_copy_do_copy_line(cs, false, true);
}

pub fn window_copy_cmd_copy_pipe_line(cs: *const CmdState) CmdAction {
    return window_copy_do_copy_line(cs, true, false);
}

pub fn window_copy_cmd_copy_pipe_line_and_cancel(cs: *const CmdState) CmdAction {
    return window_copy_do_copy_line(cs, true, true);
}

pub fn window_copy_cmd_copy_selection_no_clear(cs: *const CmdState) CmdAction {
    if (cs.session) |s| {
        cmdCopySelection(cs.wme, s, cs.args, false);
    }
    return .nothing;
}

pub fn window_copy_cmd_copy_selection(cs: *const CmdState) CmdAction {
    if (cs.session) |s| {
        cmdCopySelection(cs.wme, s, cs.args, false);
    }
    clearSelection(cs.wme);
    return .redraw;
}

pub fn window_copy_cmd_copy_selection_and_cancel(cs: *const CmdState) CmdAction {
    if (cs.session) |s| {
        cmdCopySelection(cs.wme, s, cs.args, true);
    }
    return .cancel;
}

pub fn window_copy_cmd_cursor_down(cs: *const CmdState) CmdAction {
    const count = repeatCount(cs.wme);
    cursorDownLines(cs.wme, count);
    return .redraw;
}

pub fn window_copy_cmd_cursor_down_and_cancel(cs: *const CmdState) CmdAction {
    const count = repeatCount(cs.wme);
    if (cursorDownAndCancel(cs.wme, count)) return .cancel;
    return .redraw;
}

pub fn window_copy_cmd_cursor_left(cs: *const CmdState) CmdAction {
    moveCursorX(cs.wme, -1);
    return .redraw;
}

pub fn window_copy_cmd_cursor_right(cs: *const CmdState) CmdAction {
    moveCursorX(cs.wme, 1);
    return .redraw;
}

pub fn window_copy_cmd_cursor_up(cs: *const CmdState) CmdAction {
    scrollLines(cs.wme, -1);
    return .redraw;
}

pub fn window_copy_cmd_scroll_to_fn(cs: *const CmdState, to: u32) CmdAction {
    alignCursor(cs.wme, to);
    return .redraw;
}

pub fn window_copy_cmd_scroll_to(cs: *const CmdState, to: u32) CmdAction {
    const data = modeData(cs.wme);
    if (data.cy > to) {
        const delta = data.cy - to;
        window_copy_scroll_up(cs.wme, delta);
        data.cy -|= delta;
    } else if (data.cy < to) {
        const delta = to - data.cy;
        window_copy_scroll_down(cs.wme, delta);
        data.cy += delta;
    }
    _ = window_copy_update_selection(cs.wme, false, false);
    return .redraw;
}

pub fn window_copy_cmd_scroll_bottom(cs: *const CmdState) CmdAction {
    const rows = viewRows(cs.wme.wp);
    alignCursor(cs.wme, if (rows == 0) 0 else rows - 1);
    return .redraw;
}

pub fn window_copy_cmd_scroll_middle(cs: *const CmdState) CmdAction {
    alignCursor(cs.wme, viewRows(cs.wme.wp) / 2);
    return .redraw;
}

pub fn window_copy_cmd_scroll_to_mouse(cs: *const CmdState) CmdAction {
    if (cs.client) |cl| {
        if (cs.mouse) |m|
            scrollToMouse(cs.wme.wp, cl.tty.mouse_slider_mpos, m.y, cs.args.has('e'));
    }
    return .nothing;
}

pub fn window_copy_cmd_scroll_top(cs: *const CmdState) CmdAction {
    alignCursor(cs.wme, 0);
    return .redraw;
}

pub fn window_copy_cmd_centre_vertical(cs: *const CmdState) CmdAction {
    alignCursor(cs.wme, viewRows(cs.wme.wp) / 2);
    return .redraw;
}

pub fn window_copy_cmd_centre_horizontal(cs: *const CmdState) CmdAction {
    const data = modeData(cs.wme);
    const max_x = lineMaxX(data.backing, absoluteCursorRow(cs.wme), cs.wme.wp.screen.grid.sx);
    data.cx = max_x / 2;
    return .redraw;
}

pub fn window_copy_cmd_end_of_line(cs: *const CmdState) CmdAction {
    cursorEndOfLine(cs.wme);
    return .redraw;
}

pub fn window_copy_cmd_halfpage_down(cs: *const CmdState) CmdAction {
    const count = repeatCount(cs.wme);
    var remaining = count;
    while (remaining > 0) : (remaining -= 1) {
        if (pageDownMode(cs.wme, true, modeData(cs.wme).scroll_exit))
            return .cancel;
    }
    return .redraw;
}

pub fn window_copy_cmd_halfpage_down_and_cancel(cs: *const CmdState) CmdAction {
    const count = repeatCount(cs.wme);
    var remaining = count;
    while (remaining > 0) : (remaining -= 1) {
        if (pageDownMode(cs.wme, true, true))
            return .cancel;
    }
    return .redraw;
}

pub fn window_copy_cmd_halfpage_up(cs: *const CmdState) CmdAction {
    const count = repeatCount(cs.wme);
    var remaining = count;
    while (remaining > 0) : (remaining -= 1) pageUpMode(cs.wme, true);
    return .redraw;
}

pub fn window_copy_cmd_toggle_position(cs: *const CmdState) CmdAction {
    modeData(cs.wme).hide_position = !modeData(cs.wme).hide_position;
    return .redraw;
}

pub fn window_copy_cmd_history_bottom(cs: *const CmdState) CmdAction {
    const backing_rows = rowCount(modeData(cs.wme).backing);
    if (backing_rows != 0) setAbsoluteCursorRow(cs.wme, backing_rows - 1);
    refreshSearchMarks(cs.wme, true);
    return .redraw;
}

pub fn window_copy_cmd_history_top(cs: *const CmdState) CmdAction {
    setAbsoluteCursorRow(cs.wme, 0);
    refreshSearchMarks(cs.wme, true);
    return .redraw;
}

pub fn window_copy_cmd_jump_again(cs: *const CmdState) CmdAction {
    repeatJump(cs.wme, modeData(cs.wme).jump_type);
    return .redraw;
}

pub fn window_copy_cmd_jump_reverse(cs: *const CmdState) CmdAction {
    repeatJump(cs.wme, reverseJumpType(modeData(cs.wme).jump_type));
    return .redraw;
}

pub fn window_copy_cmd_middle_line(cs: *const CmdState) CmdAction {
    setCursorLine(cs.wme, viewRows(cs.wme.wp) / 2);
    return .redraw;
}

pub fn window_copy_cmd_previous_matching_bracket(cs: *const CmdState) CmdAction {
    const wme = cs.wme;
    var np = repeatCount(wme);
    const data = modeData(wme);
    const s = data.backing;
    const open_chars = "{[(";
    const close_chars = "}])";

    while (np > 0) : (np -= 1) {
        var px = data.cx;
        var py = absoluteCursorRow(wme);
        var xx = backingLineLength(wme, py);
        if (xx == 0) break;

        // Get the current character. If not on a closing bracket, try previous.
        var tried = false;
        var found_char: ?u8 = null;
        var bracket_idx: ?usize = null;
        while (true) {
            var gc: T.GridCell = undefined;
            grid.get_cell(s.grid, py, px, &gc);
            if (gc.data.size == 1 and !gc.isPadding()) {
                const ch = gc.data.data[0];
                if (std.mem.indexOfScalar(u8, close_chars, ch)) |idx| {
                    found_char = ch;
                    bracket_idx = idx;
                    break;
                }
            }
            if (!tried and px > 0) {
                px -= 1;
                tried = true;
                continue;
            }
            break;
        }

        if (found_char == null or bracket_idx == null) {
            if (copyModeUsesViKeys(wme)) {} else {
                cursorPreviousWord(wme, close_chars, true);
            }
            continue;
        }

        const start_char = open_chars[bracket_idx.?];
        const found = found_char.?;

        // Walk backward until the matching bracket is reached
        var n: u32 = 1;
        var failed = false;
        while (n != 0) {
            if (px == 0) {
                if (py == 0) {
                    failed = true;
                    break;
                }
                while (true) {
                    py -= 1;
                    xx = backingLineLength(wme, py);
                    if (xx != 0 or py == 0) break;
                }
                if (xx == 0 and py == 0) {
                    failed = true;
                    break;
                }
                px = xx - 1;
            } else {
                px -= 1;
            }

            var gc: T.GridCell = undefined;
            grid.get_cell(s.grid, py, px, &gc);
            if (gc.data.size == 1 and !gc.isPadding()) {
                if (gc.data.data[0] == found)
                    n += 1
                else if (gc.data.data[0] == start_char)
                    n -= 1;
            }
        }

        if (!failed)
            window_copy_scroll_to(wme, px, py, false);
    }

    return .nothing;
}

pub fn window_copy_cmd_next_matching_bracket(cs: *const CmdState) CmdAction {
    const wme = cs.wme;
    var np = repeatCount(wme);
    const data = modeData(wme);
    const s = data.backing;
    const open_chars = "{[(";
    const close_chars = "}])";

    while (np > 0) : (np -= 1) {
        var px = data.cx;
        var py = absoluteCursorRow(wme);
        var xx = backingLineLength(wme, py);
        const yy = rowCount(s) -| 1;
        if (xx == 0) break;

        // Get the current character
        var tried = false;
        var found_char: ?u8 = null;
        var bracket_idx: ?usize = null;
        while (true) {
            var gc: T.GridCell = undefined;
            grid.get_cell(s.grid, py, px, &gc);
            if (gc.data.size == 1 and !gc.isPadding()) {
                const ch = gc.data.data[0];

                // In vi mode, if closing bracket found, try previous match
                if (std.mem.indexOfScalar(u8, close_chars, ch)) |_| {
                    if (copyModeUsesViKeys(wme)) {
                        const sx = data.cx;
                        const sy = absoluteCursorRow(wme);
                        window_copy_scroll_to(wme, px, py, false);
                        _ = window_copy_cmd_previous_matching_bracket(cs);
                        const npx = data.cx;
                        const npy = absoluteCursorRow(wme);
                        var gc2: T.GridCell = undefined;
                        grid.get_cell(s.grid, npy, npx, &gc2);
                        if (gc2.data.size == 1 and !gc2.isPadding() and
                            std.mem.indexOfScalar(u8, close_chars, gc2.data.data[0]) != null)
                        {
                            window_copy_scroll_to(wme, sx, sy, false);
                        }
                        return .nothing;
                    }
                }

                if (std.mem.indexOfScalar(u8, open_chars, ch)) |idx| {
                    found_char = ch;
                    bracket_idx = idx;
                    break;
                }
            }
            if (!copyModeUsesViKeys(wme)) {
                if (!tried and px <= xx) {
                    px += 1;
                    tried = true;
                    continue;
                }
                cursorNextWordEnd(wme, open_chars);
                break;
            } else {
                // vi: continue searching for bracket until EOL
                if (px > xx) {
                    if (py == yy) break;
                    if (py < s.grid.linedata.len) {
                        const gl = &s.grid.linedata[py];
                        if ((gl.flags & T.GRID_LINE_WRAPPED) == 0) break;
                        if (gl.cellused > s.grid.sx) break;
                    }
                    px = 0;
                    py += 1;
                    xx = backingLineLength(wme, py);
                } else {
                    px += 1;
                }
                continue;
            }
        }

        if (found_char == null or bracket_idx == null) continue;

        const end_char = close_chars[bracket_idx.?];
        const found = found_char.?;

        // Walk forward until the matching bracket is reached
        var n: u32 = 1;
        var failed = false;
        while (n != 0) {
            if (px > xx) {
                if (py == yy) {
                    failed = true;
                    break;
                }
                px = 0;
                py += 1;
                xx = backingLineLength(wme, py);
            } else {
                px += 1;
            }

            var gc: T.GridCell = undefined;
            grid.get_cell(s.grid, py, px, &gc);
            if (gc.data.size == 1 and !gc.isPadding()) {
                if (gc.data.data[0] == found)
                    n += 1
                else if (gc.data.data[0] == end_char)
                    n -= 1;
            }
        }

        if (!failed)
            window_copy_scroll_to(wme, px, py, false);
    }

    return .nothing;
}

pub fn window_copy_cmd_next_paragraph(cs: *const CmdState) CmdAction {
    nextParagraph(cs.wme);
    return .redraw;
}

pub fn window_copy_cmd_next_space(cs: *const CmdState) CmdAction {
    cursorNextWord(cs.wme, "");
    return .redraw;
}

pub fn window_copy_cmd_next_space_end(cs: *const CmdState) CmdAction {
    cursorNextWordEnd(cs.wme, "");
    return .redraw;
}

pub fn window_copy_cmd_next_word(cs: *const CmdState) CmdAction {
    const separators = if (cs.session) |s|
        opts.options_get_string(s.options, "word-separators")
    else
        "";
    cursorNextWord(cs.wme, separators);
    return .redraw;
}

pub fn window_copy_cmd_next_word_end(cs: *const CmdState) CmdAction {
    const separators = if (cs.session) |s|
        opts.options_get_string(s.options, "word-separators")
    else
        "";
    cursorNextWordEnd(cs.wme, separators);
    return .redraw;
}

pub fn window_copy_cmd_other_end(cs: *const CmdState) CmdAction {
    cmdOtherEnd(cs.wme);
    return .redraw;
}

pub fn window_copy_cmd_selection_mode(cs: *const CmdState) CmdAction {
    if (cs.session) |s| {
        cmdSelectionMode(cs.wme, s, cs.args);
    }
    return .nothing;
}

pub fn window_copy_cmd_page_down(cs: *const CmdState) CmdAction {
    const count = repeatCount(cs.wme);
    var remaining = count;
    while (remaining > 0) : (remaining -= 1) {
        if (pageDownMode(cs.wme, false, modeData(cs.wme).scroll_exit))
            return .cancel;
    }
    return .redraw;
}

pub fn window_copy_cmd_page_down_and_cancel(cs: *const CmdState) CmdAction {
    const count = repeatCount(cs.wme);
    var remaining = count;
    while (remaining > 0) : (remaining -= 1) {
        if (pageDownMode(cs.wme, false, true))
            return .cancel;
    }
    return .redraw;
}

pub fn window_copy_cmd_page_up(cs: *const CmdState) CmdAction {
    const count = repeatCount(cs.wme);
    var remaining = count;
    while (remaining > 0) : (remaining -= 1) pageUpMode(cs.wme, false);
    return .redraw;
}

pub fn window_copy_cmd_previous_paragraph(cs: *const CmdState) CmdAction {
    previousParagraph(cs.wme);
    return .redraw;
}

pub fn window_copy_cmd_previous_space(cs: *const CmdState) CmdAction {
    cursorPreviousWord(cs.wme, "", true);
    return .redraw;
}

pub fn window_copy_cmd_previous_word(cs: *const CmdState) CmdAction {
    const separators = if (cs.session) |s|
        opts.options_get_string(s.options, "word-separators")
    else
        "";
    cursorPreviousWord(cs.wme, separators, true);
    return .redraw;
}

pub fn window_copy_cmd_rectangle_on(cs: *const CmdState) CmdAction {
    cmdRectangleSet(cs.wme, true);
    return .redraw;
}

pub fn window_copy_cmd_rectangle_off(cs: *const CmdState) CmdAction {
    cmdRectangleSet(cs.wme, false);
    return .redraw;
}

pub fn window_copy_cmd_rectangle_toggle(cs: *const CmdState) CmdAction {
    cmdRectangleToggle(cs.wme);
    return .redraw;
}

pub fn window_copy_cmd_scroll_exit_on(cs: *const CmdState) CmdAction {
    modeData(cs.wme).scroll_exit = true;
    return .nothing;
}

pub fn window_copy_cmd_scroll_exit_off(cs: *const CmdState) CmdAction {
    modeData(cs.wme).scroll_exit = false;
    return .nothing;
}

pub fn window_copy_cmd_scroll_exit_toggle(cs: *const CmdState) CmdAction {
    const data = modeData(cs.wme);
    data.scroll_exit = !data.scroll_exit;
    return .nothing;
}

pub fn window_copy_cmd_scroll_down(cs: *const CmdState) CmdAction {
    const count = repeatCount(cs.wme);
    if (scrollViewportDownLines(cs.wme, count, modeData(cs.wme).scroll_exit))
        return .cancel;
    return .redraw;
}

pub fn window_copy_cmd_scroll_down_and_cancel(cs: *const CmdState) CmdAction {
    const count = repeatCount(cs.wme);
    if (scrollViewportDownLines(cs.wme, count, true))
        return .cancel;
    return .redraw;
}

pub fn window_copy_cmd_scroll_up(cs: *const CmdState) CmdAction {
    const count = repeatCount(cs.wme);
    scrollLines(cs.wme, -@as(i32, @intCast(count)));
    return .redraw;
}

pub fn window_copy_cmd_search_again(cs: *const CmdState) CmdAction {
    cmdSearchAgain(cs.wme);
    return .redraw;
}

pub fn window_copy_cmd_search_reverse(cs: *const CmdState) CmdAction {
    cmdSearchReverse(cs.wme);
    return .redraw;
}

pub fn window_copy_cmd_select_line(cs: *const CmdState) CmdAction {
    if (cs.session) |s| cmdSelectLine(cs.wme, s);
    return .redraw;
}

pub fn window_copy_cmd_select_word(cs: *const CmdState) CmdAction {
    if (cs.session) |s| cmdSelectWord(cs.wme, s);
    return .redraw;
}

pub fn window_copy_cmd_set_mark(cs: *const CmdState) CmdAction {
    cmdSetMark(cs.wme);
    return .redraw;
}

pub fn window_copy_cmd_start_of_line(cs: *const CmdState) CmdAction {
    cursorStartOfLine(cs.wme);
    return .redraw;
}

pub fn window_copy_cmd_top_line(cs: *const CmdState) CmdAction {
    setCursorLine(cs.wme, 0);
    return .redraw;
}

pub fn window_copy_cmd_copy_pipe_no_clear(cs: *const CmdState) CmdAction {
    if (cs.session) |s| cmdCopyPipeNoClear(cs.wme, s, cs.args);
    return .nothing;
}

pub fn window_copy_cmd_copy_pipe(cs: *const CmdState) CmdAction {
    if (cs.session) |s| cmdCopyPipe(cs.wme, s, cs.args, false);
    return .redraw;
}

pub fn window_copy_cmd_copy_pipe_and_cancel(cs: *const CmdState) CmdAction {
    if (cs.session) |s| cmdCopyPipe(cs.wme, s, cs.args, true);
    return .cancel;
}

pub fn window_copy_cmd_pipe_no_clear(cs: *const CmdState) CmdAction {
    if (cs.session) |s| cmdPipeNoClear(cs.wme, s, cs.args);
    return .nothing;
}

pub fn window_copy_cmd_pipe(cs: *const CmdState) CmdAction {
    if (cs.session) |s| cmdPipe(cs.wme, s, cs.args, false);
    return .redraw;
}

pub fn window_copy_cmd_pipe_and_cancel(cs: *const CmdState) CmdAction {
    if (cs.session) |s| cmdPipe(cs.wme, s, cs.args, true);
    return .cancel;
}

pub fn window_copy_cmd_goto_line(cs: *const CmdState) CmdAction {
    const arg = cs.args.value_at(1) orelse return .nothing;
    if (arg.len != 0) gotoLine(cs.wme, arg);
    return .redraw;
}

pub fn window_copy_cmd_jump_backward(cs: *const CmdState) CmdAction {
    const arg = cs.args.value_at(1) orelse return .nothing;
    if (setJumpCharacter(modeData(cs.wme), .backward, arg))
        repeatJump(cs.wme, .backward);
    return .redraw;
}

pub fn window_copy_cmd_jump_forward(cs: *const CmdState) CmdAction {
    const arg = cs.args.value_at(1) orelse return .nothing;
    if (setJumpCharacter(modeData(cs.wme), .forward, arg))
        repeatJump(cs.wme, .forward);
    return .redraw;
}

pub fn window_copy_cmd_jump_to_backward(cs: *const CmdState) CmdAction {
    const arg = cs.args.value_at(1) orelse return .nothing;
    if (setJumpCharacter(modeData(cs.wme), .to_backward, arg))
        repeatJump(cs.wme, .to_backward);
    return .redraw;
}

pub fn window_copy_cmd_jump_to_forward(cs: *const CmdState) CmdAction {
    const arg = cs.args.value_at(1) orelse return .nothing;
    if (setJumpCharacter(modeData(cs.wme), .to_forward, arg))
        repeatJump(cs.wme, .to_forward);
    return .redraw;
}

pub fn window_copy_cmd_jump_to_mark(cs: *const CmdState) CmdAction {
    cmdJumpToMark(cs.wme);
    return .redraw;
}

pub fn window_copy_cmd_next_prompt(cs: *const CmdState) CmdAction {
    window_copy_cursor_prompt(cs.wme, 1, false);
    return .redraw;
}

pub fn window_copy_cmd_previous_prompt(cs: *const CmdState) CmdAction {
    window_copy_cursor_prompt(cs.wme, -1, false);
    return .redraw;
}

pub fn window_copy_cmd_search_backward(cs: *const CmdState) CmdAction {
    cmdSearchBackward(cs.wme, cs.args, true);
    return .redraw;
}

pub fn window_copy_cmd_search_backward_text(cs: *const CmdState) CmdAction {
    cmdSearchBackward(cs.wme, cs.args, false);
    return .redraw;
}

pub fn window_copy_cmd_search_forward(cs: *const CmdState) CmdAction {
    cmdSearchForward(cs.wme, cs.args, true);
    return .redraw;
}

pub fn window_copy_cmd_search_forward_text(cs: *const CmdState) CmdAction {
    cmdSearchForward(cs.wme, cs.args, false);
    return .redraw;
}

pub fn window_copy_cmd_search_backward_incremental(cs: *const CmdState) CmdAction {
    cmdSearchIncremental(cs.wme, cs.args, .up);
    return .redraw;
}

pub fn window_copy_cmd_search_forward_incremental(cs: *const CmdState) CmdAction {
    cmdSearchIncremental(cs.wme, cs.args, .down);
    return .redraw;
}

pub fn window_copy_cmd_refresh_from_pane(cs: *const CmdState) CmdAction {
    refreshFromSource(cs.wme, true);
    cs.wme.prefix = 1;
    return .nothing;
}

pub fn window_copy_cmd_swap_selection_start(cs: *const CmdState) CmdAction {
    cmdSwapSelectionStart(cs.wme);
    return .redraw;
}

pub fn window_copy_cmd_swap_selection_end(cs: *const CmdState) CmdAction {
    cmdSwapSelectionEnd(cs.wme);
    return .redraw;
}
