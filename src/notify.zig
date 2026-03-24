// Copyright (c) 2026 Greg Turner <gmt@pobox.com>
// ISC licence – see COPYING.
// Ported from tmux/notify.c (skeleton)

const std = @import("std");
const T = @import("types.zig");

pub fn notify_client(_name: []const u8, _cl: *T.Client) void { _ = _name; _ = _cl; }
pub fn notify_session(_name: []const u8, _s: *T.Session) void { _ = _name; _ = _s; }
pub fn notify_window(_name: []const u8, _w: *T.Window) void { _ = _name; _ = _w; }
pub fn notify_pane(_name: []const u8, _wp: *T.WindowPane) void { _ = _name; _ = _wp; }
pub fn notify_paste_buffer(_pbname: []const u8, _deleted: bool) void {
    _ = _pbname;
    _ = _deleted;
}
