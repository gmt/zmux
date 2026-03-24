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
// Ported from tmux/server-fn.c
// Original copyright:
//   Copyright (c) 2007 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

//! server-fn.zig – cross-cutting server helper functions.

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const log = @import("log.zig");
const srv = @import("server.zig");

pub fn server_redraw_session(s: *T.Session) void {
    _ = s;
    // TODO: mark all clients attached to this session for redraw
}

pub fn server_redraw_session_group(s: *T.Session) void {
    _ = s;
}

pub fn server_status_session(s: *T.Session) void {
    _ = s;
}

pub fn server_status_window(w: *T.Window) void {
    _ = w;
}

pub fn server_lock_session(s: *T.Session) void {
    _ = s;
}

pub fn server_kill_window(w: *T.Window, detach_last: bool) void {
    _ = w;
    _ = detach_last;
}

pub fn server_link_window(
    _src: *T.Session,
    _srcwl: *T.Winlink,
    _dst: *T.Session,
    _dst_idx: i32,
    _to_last: bool,
    _detach_other: bool,
    _cause: *?[]u8,
) i32 {
    _ = _src;
    _ = _srcwl;
    _ = _dst;
    _ = _dst_idx;
    _ = _to_last;
    _ = _detach_other;
    _ = _cause;
    return 0;
}

pub fn server_unlink_window(s: *T.Session, wl: *T.Winlink) void {
    _ = s;
    _ = wl;
}

pub fn server_destroy_pane(wp: *T.WindowPane, notify: bool) void {
    _ = wp;
    _ = notify;
}

pub fn server_client_handle_key(cl: *T.Client, event: *T.key_event) void {
    _ = cl;
    _ = event;
}

// Placeholder for format_tree.zig integration
pub fn server_format_session(
    _ft: ?*anyopaque,
    _s: *T.Session,
) void {
    _ = _ft;
    _ = _s;
}
