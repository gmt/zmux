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
// Ported in part from tmux/notify.c.
// Original copyright:
//   Copyright (c) 2012 George Nachman <tmux@georgester.com>
//   ISC licence – same terms as above.

const std = @import("std");
const T = @import("types.zig");
const control_notify = @import("control-notify.zig");

pub fn notify_client(name: []const u8, cl: *T.Client) void {
    if (std.mem.eql(u8, name, "client-session-changed"))
        control_notify.control_notify_client_session_changed(cl)
    else if (std.mem.eql(u8, name, "client-detached"))
        control_notify.control_notify_client_detached(cl);
}

pub fn notify_session(name: []const u8, s: *T.Session) void {
    if (std.mem.eql(u8, name, "session-renamed"))
        control_notify.control_notify_session_renamed(s)
    else if (std.mem.eql(u8, name, "session-created"))
        control_notify.control_notify_session_created(s)
    else if (std.mem.eql(u8, name, "session-closed"))
        control_notify.control_notify_session_closed(s);
}

pub fn notify_winlink(name: []const u8, wl: *T.Winlink) void {
    notify_session_window(name, wl.session, wl.window);
}

pub fn notify_session_window(name: []const u8, s: *T.Session, w: *T.Window) void {
    if (std.mem.eql(u8, name, "window-unlinked"))
        control_notify.control_notify_window_unlinked(s, w)
    else if (std.mem.eql(u8, name, "window-linked"))
        control_notify.control_notify_window_linked(s, w);
}

pub fn notify_window(name: []const u8, w: *T.Window) void {
    if (std.mem.eql(u8, name, "window-renamed"))
        control_notify.control_notify_window_renamed(w);
}

pub fn notify_pane(_name: []const u8, _wp: *T.WindowPane) void {
    _ = _name;
    _ = _wp;
}

pub fn notify_paste_buffer(pbname: []const u8, deleted: bool) void {
    if (deleted)
        control_notify.control_notify_paste_buffer_deleted(pbname)
    else
        control_notify.control_notify_paste_buffer_changed(pbname);
}
