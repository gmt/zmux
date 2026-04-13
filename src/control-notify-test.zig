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

//! control-notify-test.zig – tests for control-notify.zig event dispatch.
//!
//! Covers the event-to-protocol-message mapping, dispatch ordering,
//! empty-registry tolerance, and null-guard edge cases for all thirteen
//! control_notify_* functions ported from tmux control-notify.c.

const std = @import("std");
const T = @import("types.zig");
const cn = @import("control-notify.zig");
const registry = @import("client-registry.zig");
const ctl = @import("control.zig");
const xm = @import("xmalloc.zig");
const c = @import("c.zig");
const env_mod = @import("environ.zig");
const proc_mod = @import("proc.zig");

fn test_peer_dispatch(_: ?*c.imsg.imsg, _: ?*anyopaque) callconv(.c) void {}

/// Read one peer-stream message from the imsgbuf reader, returning
/// the payload after the 4-byte stream identifier.
fn readPeerStreamPayloadAlloc(reader: *c.imsg.imsgbuf) ![]u8 {
    while (true) {
        var imsg_msg: c.imsg.imsg = undefined;
        const got = c.imsg.imsg_get(reader, &imsg_msg);
        if (got == 0) {
            try std.testing.expectEqual(@as(i32, 1), c.imsg.imsgbuf_read(reader));
            continue;
        }
        try std.testing.expect(got > 0);
        defer c.imsg.imsg_free(&imsg_msg);

        const data_len = imsg_msg.hdr.len -% @sizeOf(c.imsg.imsg_hdr);
        try std.testing.expect(data_len >= @sizeOf(i32));
        const raw: [*]const u8 = @ptrCast(imsg_msg.data.?);
        const stream: *const i32 = @ptrCast(@alignCast(imsg_msg.data.?));
        try std.testing.expectEqual(@as(i32, 1), stream.*);
        return try xm.allocator.dupe(u8, raw[@sizeOf(i32)..data_len]);
    }
}

// ---- Test 1: empty registry tolerance ----

test "control-notify: all event dispatchers tolerate empty client registry" {
    registry.clients.clearRetainingCapacity();
    defer registry.clients.clearRetainingCapacity();

    // Session events (null curw triggers early return in session_window_changed)
    var s: T.Session = undefined;
    s.curw = null;
    cn.control_notify_session_created(&s);
    cn.control_notify_session_closed(&s);
    cn.control_notify_session_window_changed(&s);

    // Client events (null session triggers early return in client_session_changed)
    var cl: T.Client = .{ .environ = undefined, .tty = undefined, .status = undefined };
    cl.tty = .{ .client = &cl };
    cl.session = null;
    cn.control_notify_client_session_changed(&cl);
    cn.control_notify_client_detached(&cl);

    // Window events (null active triggers early return in window_pane_changed)
    var w: T.Window = undefined;
    w.active = null;
    cn.control_notify_window_pane_changed(&w);

    // Pane event
    var wp: T.WindowPane = undefined;
    cn.control_notify_pane_mode_changed(&wp);

    // Paste buffer events
    cn.control_notify_paste_buffer_changed("buf0");
    cn.control_notify_paste_buffer_deleted("buf0");

    try std.testing.expectEqual(@as(usize, 0), registry.clients.items.len);
}

// ---- Test 2: null optional guards ----

test "control-notify: null guards prevent dispatch when optional context is absent" {
    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);

    // A CLIENT_CONTROL client sits in the registry — the for-loop body
    // would execute (and crash on null dereference) if the guards
    // didn't return first.
    var observer: T.Client = .{
        .environ = env,
        .tty = undefined,
        .status = .{},
        .flags = T.CLIENT_CONTROL,
        .session = null,
        .peer = null,
    };
    observer.tty = .{ .client = &observer };

    registry.clients.clearRetainingCapacity();
    defer registry.clients.clearRetainingCapacity();
    registry.add(&observer);

    // session_window_changed: null curw -> returns before client loop
    var s: T.Session = undefined;
    s.curw = null;
    cn.control_notify_session_window_changed(&s);

    // window_pane_changed: null active -> returns before client loop
    var w: T.Window = undefined;
    w.active = null;
    cn.control_notify_window_pane_changed(&w);

    // client_session_changed: null session -> returns before client loop
    var changed: T.Client = .{
        .environ = env,
        .tty = undefined,
        .status = .{},
        .session = null,
    };
    changed.tty = .{ .client = &changed };
    cn.control_notify_client_session_changed(&changed);

    // All three returned early; observer still in registry, untouched.
    try std.testing.expectEqual(@as(usize, 1), registry.clients.items.len);
}

// ---- Test 3: non-control clients skipped ----

test "control-notify: non-control clients in registry are silently skipped" {
    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);

    var cl: T.Client = .{
        .environ = env,
        .tty = undefined,
        .status = .{},
        .flags = 0,
        .peer = null,
    };
    cl.tty = .{ .client = &cl };

    registry.clients.clearRetainingCapacity();
    defer registry.clients.clearRetainingCapacity();
    registry.add(&cl);

    // Loop body executes but should_notify_client returns false,
    // so write_control returns early for every notification type.
    cn.control_notify_paste_buffer_changed("test-buf");
    cn.control_notify_paste_buffer_deleted("test-buf");

    var s: T.Session = undefined;
    cn.control_notify_session_created(&s);
    cn.control_notify_session_closed(&s);

    var detaching: T.Client = .{ .environ = env, .tty = undefined, .status = .{} };
    detaching.tty = .{ .client = &detaching };
    cn.control_notify_client_detached(&detaching);

    try std.testing.expectEqual(@as(usize, 1), registry.clients.items.len);
}

// ---- Test 4: event-to-message format matches tmux protocol ----

test "control-notify: event-to-message format matches tmux protocol" {
    registry.clients.clearRetainingCapacity();
    defer registry.clients.clearRetainingCapacity();

    var pair: [2]i32 = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.socketpair(
        std.posix.AF.UNIX,
        std.posix.SOCK.STREAM,
        0,
        &pair,
    ));

    var proc = T.ZmuxProc{ .name = "notify-fmt-test" };
    defer proc.peers.deinit(xm.allocator);

    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);

    var cl = T.Client{
        .environ = env,
        .tty = undefined,
        .status = .{},
        .flags = T.CLIENT_CONTROL,
        .session = null,
        .control_all_blocks = .{},
        .control_panes = .{},
    };
    cl.tty = .{ .client = &cl };
    cl.peer = proc_mod.proc_add_peer(&proc, pair[0], test_peer_dispatch, null);
    defer {
        ctl.control_stop(&cl);
        const peer = cl.peer.?;
        c.imsg.imsgbuf_clear(&peer.ibuf);
        std.posix.close(peer.ibuf.fd);
        xm.allocator.destroy(peer);
        proc.peers.clearRetainingCapacity();
        cl.peer = null;
    }
    ctl.control_start(&cl);

    var reader: c.imsg.imsgbuf = undefined;
    try std.testing.expectEqual(@as(i32, 0), c.imsg.imsgbuf_init(&reader, pair[1]));
    defer {
        c.imsg.imsgbuf_clear(&reader);
        std.posix.close(pair[1]);
    }

    registry.add(&cl);

    // %paste-buffer-changed <name>
    cn.control_notify_paste_buffer_changed("mybuf");
    {
        const payload = try readPeerStreamPayloadAlloc(&reader);
        defer xm.allocator.free(payload);
        try std.testing.expectEqualStrings("%paste-buffer-changed mybuf\n", payload);
    }

    // %sessions-changed (session_created ignores the session pointer)
    {
        var dummy: T.Session = undefined;
        cn.control_notify_session_created(&dummy);
        const payload = try readPeerStreamPayloadAlloc(&reader);
        defer xm.allocator.free(payload);
        try std.testing.expectEqualStrings("%sessions-changed\n", payload);
    }

    // %client-detached <name> — client_display_name falls back to "unknown"
    {
        var detaching: T.Client = .{ .environ = env, .tty = undefined, .status = .{} };
        detaching.tty = .{ .client = &detaching };
        cn.control_notify_client_detached(&detaching);
        const payload = try readPeerStreamPayloadAlloc(&reader);
        defer xm.allocator.free(payload);
        try std.testing.expectEqualStrings("%client-detached unknown\n", payload);
    }

    // %paste-buffer-deleted <name>
    cn.control_notify_paste_buffer_deleted("gone");
    {
        const payload = try readPeerStreamPayloadAlloc(&reader);
        defer xm.allocator.free(payload);
        try std.testing.expectEqualStrings("%paste-buffer-deleted gone\n", payload);
    }
}

// ---- Test 5: dispatch ordering under burst ----

test "control-notify: messages preserve dispatch order under burst" {
    registry.clients.clearRetainingCapacity();
    defer registry.clients.clearRetainingCapacity();

    var pair: [2]i32 = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.socketpair(
        std.posix.AF.UNIX,
        std.posix.SOCK.STREAM,
        0,
        &pair,
    ));

    var proc = T.ZmuxProc{ .name = "notify-order-test" };
    defer proc.peers.deinit(xm.allocator);

    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);

    var cl = T.Client{
        .environ = env,
        .tty = undefined,
        .status = .{},
        .flags = T.CLIENT_CONTROL,
        .session = null,
        .control_all_blocks = .{},
        .control_panes = .{},
    };
    cl.tty = .{ .client = &cl };
    cl.peer = proc_mod.proc_add_peer(&proc, pair[0], test_peer_dispatch, null);
    defer {
        ctl.control_stop(&cl);
        const peer = cl.peer.?;
        c.imsg.imsgbuf_clear(&peer.ibuf);
        std.posix.close(peer.ibuf.fd);
        xm.allocator.destroy(peer);
        proc.peers.clearRetainingCapacity();
        cl.peer = null;
    }
    ctl.control_start(&cl);

    var reader: c.imsg.imsgbuf = undefined;
    try std.testing.expectEqual(@as(i32, 0), c.imsg.imsgbuf_init(&reader, pair[1]));
    defer {
        c.imsg.imsgbuf_clear(&reader);
        std.posix.close(pair[1]);
    }

    registry.add(&cl);

    // Fire three buffer notifications in quick succession.
    cn.control_notify_paste_buffer_changed("alpha");
    cn.control_notify_paste_buffer_changed("beta");
    cn.control_notify_paste_buffer_changed("gamma");

    // Verify FIFO arrival order.
    {
        const p = try readPeerStreamPayloadAlloc(&reader);
        defer xm.allocator.free(p);
        try std.testing.expectEqualStrings("%paste-buffer-changed alpha\n", p);
    }
    {
        const p = try readPeerStreamPayloadAlloc(&reader);
        defer xm.allocator.free(p);
        try std.testing.expectEqualStrings("%paste-buffer-changed beta\n", p);
    }
    {
        const p = try readPeerStreamPayloadAlloc(&reader);
        defer xm.allocator.free(p);
        try std.testing.expectEqualStrings("%paste-buffer-changed gamma\n", p);
    }
}
