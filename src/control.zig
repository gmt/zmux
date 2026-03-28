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
// Ported in part from tmux/control.c.
// Original copyright:
//   Copyright (c) 2012 Nicholas Marriott <nicholas.marriott@gmail.com>
//   Copyright (c) 2012 George Nachman <tmux@georgester.com>
//   ISC licence – same terms as above.

//! control.zig - reduced control-client pane offset bookkeeping.

const std = @import("std");
const T = @import("types.zig");
const file_mod = @import("file.zig");
const xm = @import("xmalloc.zig");

pub fn control_panes_deinit(cl: *T.Client) void {
    cl.control_panes.deinit(xm.allocator);
}

fn control_find_pane(cl: *T.Client, pane_id: u32) ?*T.ControlPane {
    for (cl.control_panes.items) |*pane| {
        if (pane.pane == pane_id) return pane;
    }
    return null;
}

fn control_add_pane(cl: *T.Client, wp: *T.WindowPane) *T.ControlPane {
    if (control_find_pane(cl, wp.id)) |pane| return pane;

    cl.control_panes.append(xm.allocator, .{
        .pane = wp.id,
        .offset = wp.offset,
        .queued = wp.offset,
    }) catch unreachable;
    return &cl.control_panes.items[cl.control_panes.items.len - 1];
}

fn sync_pane_offsets(cp: *T.ControlPane, wp: *T.WindowPane) void {
    cp.offset = wp.offset;
    cp.queued = wp.offset;
}

fn write_control_line(cl: *T.Client, comptime fmt: []const u8, args: anytype) void {
    const peer = cl.peer orelse return;
    const line = std.fmt.allocPrint(xm.allocator, fmt ++ "\n", args) catch unreachable;
    defer xm.allocator.free(line);
    _ = file_mod.sendPeerStream(peer, 1, line);
}

pub fn control_set_pane_on(cl: *T.Client, wp: *T.WindowPane) void {
    const cp = control_find_pane(cl, wp.id) orelse return;
    if ((cp.flags & T.CONTROL_PANE_OFF) == 0) return;

    cp.flags &= ~@as(u8, T.CONTROL_PANE_OFF);
    sync_pane_offsets(cp, wp);
}

pub fn control_set_pane_off(cl: *T.Client, wp: *T.WindowPane) void {
    const cp = control_add_pane(cl, wp);
    cp.flags |= T.CONTROL_PANE_OFF;
}

pub fn control_continue_pane(cl: *T.Client, wp: *T.WindowPane) void {
    const cp = control_find_pane(cl, wp.id) orelse return;
    if ((cp.flags & T.CONTROL_PANE_PAUSED) == 0) return;

    cp.flags &= ~@as(u8, T.CONTROL_PANE_PAUSED);
    sync_pane_offsets(cp, wp);
    write_control_line(cl, "%continue %{d}", .{wp.id});
}

pub fn control_pause_pane(cl: *T.Client, wp: *T.WindowPane) void {
    const cp = control_add_pane(cl, wp);
    if ((cp.flags & T.CONTROL_PANE_PAUSED) != 0) return;

    cp.flags |= T.CONTROL_PANE_PAUSED;
    write_control_line(cl, "%pause %{d}", .{wp.id});
}
