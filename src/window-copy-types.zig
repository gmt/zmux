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
// Copy-mode shared types (tmux/window-copy.c correlate).

const std = @import("std");
const c = @import("c.zig");
const T = @import("types.zig");

pub const word_whitespace = "\t ";

pub const invalid_search_origin = std.math.maxInt(u32);

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

pub const LineSelFlag = enum {
    none,
    left_right,
    right_left,
};

pub const SelFlag = enum {
    char,
    word,
    line,
};

pub const SearchDirection = enum {
    up,
    down,
};

pub const CopyModeData = struct {
    backing: *T.Screen,
    drag_timer: ?*c.libevent.event = null,
    separators: []const u8 = word_whitespace,
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
    searchx: u32 = invalid_search_origin,
    searchy: u32 = invalid_search_origin,
    searcho: u32 = invalid_search_origin,
    searchgen: u8 = 1,
    timeout: bool = false,

    // Mark state
    mark_x: u32 = 0,
    mark_y: u32 = 0,
    show_mark: bool = false,
};
