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
// Ported in part from tmux/control-notify.c.
// Original copyright:
//   Copyright (c) 2012 Nicholas Marriott <nicholas.marriott@gmail.com>
//   Copyright (c) 2012 George Nachman <tmux@georgester.com>
//   ISC licence – same terms as above.

//! control-notify.zig – reduced control-mode event notifications.

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const registry = @import("client-registry.zig");
const proc_mod = @import("proc.zig");
const protocol = @import("zmux-protocol.zig");

fn should_notify_client(cl: *T.Client) bool {
    return (cl.flags & T.CLIENT_CONTROL) != 0;
}

fn client_display_name(cl: *T.Client) []const u8 {
    if (cl.name) |name| return name;
    if (cl.ttyname) |ttyname| return ttyname;
    return "unknown";
}

fn session_has_window(s: *T.Session, w: *T.Window) bool {
    var it = s.windows.valueIterator();
    while (it.next()) |wl| {
        if (wl.*.window == w) return true;
    }
    return false;
}

fn write_control(cl: *T.Client, comptime fmt: []const u8, args: anytype) void {
    if (!should_notify_client(cl)) return;
    const msg = xm.xasprintf(fmt, args);
    defer xm.allocator.free(msg);

    if (cl.peer) |peer| {
        var stream: i32 = 1;
        var buf: std.ArrayList(u8) = .{};
        defer buf.deinit(xm.allocator);
        buf.appendSlice(xm.allocator, std.mem.asBytes(&stream)) catch unreachable;
        buf.appendSlice(xm.allocator, msg) catch unreachable;
        buf.append(xm.allocator, '\n') catch unreachable;
        _ = proc_mod.proc_send(peer, .write, -1, buf.items.ptr, buf.items.len);
    }
}

pub fn control_notify_session_created(_s: *T.Session) void {
    _ = _s;
    for (registry.clients.items) |cl| write_control(cl, "%sessions-changed", .{});
}

pub fn control_notify_session_closed(_s: *T.Session) void {
    _ = _s;
    for (registry.clients.items) |cl| write_control(cl, "%sessions-changed", .{});
}

pub fn control_notify_session_renamed(s: *T.Session) void {
    for (registry.clients.items) |cl| write_control(cl, "%session-renamed ${d} {s}", .{ s.id, s.name });
}

pub fn control_notify_client_session_changed(changed: *T.Client) void {
    const s = changed.session orelse return;
    for (registry.clients.items) |cl| {
        if (!should_notify_client(cl) or cl.session == null) continue;
        if (cl == changed) {
            write_control(cl, "%session-changed ${d} {s}", .{ s.id, s.name });
        } else {
            write_control(cl, "%client-session-changed {s} ${d} {s}", .{ client_display_name(changed), s.id, s.name });
        }
    }
}

pub fn control_notify_client_detached(changed: *T.Client) void {
    for (registry.clients.items) |cl| write_control(cl, "%client-detached {s}", .{client_display_name(changed)});
}

pub fn control_notify_window_renamed(w: *T.Window) void {
    for (registry.clients.items) |cl| {
        if (!should_notify_client(cl) or cl.session == null) continue;
        if (session_has_window(cl.session.?, w)) {
            write_control(cl, "%window-renamed @{d} {s}", .{ w.id, w.name });
        } else {
            write_control(cl, "%unlinked-window-renamed @{d} {s}", .{ w.id, w.name });
        }
    }
}

pub fn control_notify_window_unlinked(_s: *T.Session, w: *T.Window) void {
    _ = _s;
    for (registry.clients.items) |cl| {
        if (!should_notify_client(cl) or cl.session == null) continue;
        if (session_has_window(cl.session.?, w)) {
            write_control(cl, "%window-close @{d}", .{w.id});
        } else {
            write_control(cl, "%unlinked-window-close @{d}", .{w.id});
        }
    }
}

pub fn control_notify_window_linked(_s: *T.Session, w: *T.Window) void {
    _ = _s;
    for (registry.clients.items) |cl| {
        if (!should_notify_client(cl) or cl.session == null) continue;
        if (session_has_window(cl.session.?, w)) {
            write_control(cl, "%window-add @{d}", .{w.id});
        } else {
            write_control(cl, "%unlinked-window-add @{d}", .{w.id});
        }
    }
}

pub fn control_notify_paste_buffer_changed(name: []const u8) void {
    for (registry.clients.items) |cl| write_control(cl, "%paste-buffer-changed {s}", .{name});
}

pub fn control_notify_paste_buffer_deleted(name: []const u8) void {
    for (registry.clients.items) |cl| write_control(cl, "%paste-buffer-deleted {s}", .{name});
}

test "client display name falls back sanely" {
    var cl: T.Client = .{ .environ = undefined, .tty = undefined, .status = undefined };
    cl.tty = .{ .client = &cl };
    try std.testing.expectEqualStrings("unknown", client_display_name(&cl));
    cl.ttyname = @constCast("tty0");
    try std.testing.expectEqualStrings("tty0", client_display_name(&cl));
    cl.name = "named";
    try std.testing.expectEqualStrings("named", client_display_name(&cl));
}

test "session_has_window checks current session membership" {
    const xm_mod = @import("xmalloc.zig");
    const opts = @import("options.zig");
    const env_mod = @import("environ.zig");
    const sess = @import("session.zig");
    const win = @import("window.zig");

    opts.global_options = opts.options_create(null);
    opts.global_s_options = opts.options_create(null);
    opts.global_w_options = opts.options_create(null);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    sess.session_init_globals(xm_mod.allocator);
    win.window_init_globals(xm_mod.allocator);

    const env = env_mod.environ_create();
    const s = sess.session_create(null, "notify-membership", "/", env, opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("notify-membership") != null) sess.session_destroy(s, false, "test");

    const w = win.window_create(80, 24, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    var cause: ?[]u8 = null;
    _ = sess.session_attach(s, w, -1, &cause);

    try std.testing.expect(session_has_window(s, w));
    _ = sess.session_detach_index(s, 0, "test");
    try std.testing.expect(!session_has_window(s, w));
    win.window_remove_ref(w, "test");
}
