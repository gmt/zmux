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
// Shared marked-pane state for reduced tmux parity.

const T = @import("types.zig");
const sess = @import("session.zig");

pub var marked_pane: T.CmdFindState = .{ .idx = -1 };

pub fn clear() void {
    marked_pane = .{ .idx = -1 };
}

pub fn set(s: *T.Session, wl: *T.Winlink, wp: *T.WindowPane) void {
    marked_pane = .{
        .s = s,
        .wl = wl,
        .w = wl.window,
        .wp = wp,
        .idx = wl.idx,
    };
}

pub fn check() bool {
    const s = marked_pane.s orelse return false;
    const wl = marked_pane.wl orelse return false;
    const w = marked_pane.w orelse return false;
    const wp = marked_pane.wp orelse return false;

    if (!sess.session_alive(s)) return false;
    if (sess.winlink_find_by_window(&s.windows, w) != wl) return false;
    if (wl.window != w) return false;

    for (w.panes.items) |pane| {
        if (pane != wp) continue;
        marked_pane.w = wl.window;
        marked_pane.idx = wl.idx;
        return true;
    }
    return false;
}

pub fn is_marked(s: ?*T.Session, wl: ?*T.Winlink, wp: ?*T.WindowPane) bool {
    if (s == null or wl == null or wp == null) return false;
    if (marked_pane.s != s or marked_pane.wl != wl) return false;
    if (marked_pane.wp != wp) return false;
    return check();
}

pub fn clear_if_pane(wp: *T.WindowPane) void {
    if (marked_pane.wp == wp) clear();
}

pub fn clear_if_winlink(wl: *T.Winlink) void {
    if (marked_pane.wl == wl) clear();
}

pub fn rebind_winlink(src: *T.Winlink, dst: *T.Winlink) void {
    if (marked_pane.wl != src) return;
    marked_pane.wl = dst;
    marked_pane.w = dst.window;
    marked_pane.idx = dst.idx;
}
