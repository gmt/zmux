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

//! proc-test.zig – unit tests for [proc.zig](proc.zig).
//!
//! `proc_event_cb` and `proc_loop` still need a live libevent base; socketpair
//! tests below cover `proc_send`, `proc_peer_check_version`, and imsg wiring.

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const proc = @import("proc.zig");
const protocol = @import("zmux-protocol.zig");
const c = @import("c.zig");

fn noop_dispatch(_: ?*c.imsg.imsg, _: ?*anyopaque) callconv(.c) void {}

test "proc_get_peer_uid reads stored uid field" {
    var dummy_proc: T.ZmuxProc = .{ .name = "test" };
    var peer: T.ZmuxPeer = .{
        .parent = &dummy_proc,
        .ibuf = undefined,
        .uid = 4242,
        .flags = 0,
        .dispatchcb = undefined,
    };
    try std.testing.expectEqual(@as(std.posix.uid_t, 4242), proc.proc_get_peer_uid(&peer));
}

test "proc_kill_peer marks peer with PEER_BAD" {
    var dummy_proc: T.ZmuxProc = .{ .name = "test" };
    var peer: T.ZmuxPeer = .{
        .parent = &dummy_proc,
        .ibuf = undefined,
        .uid = 0,
        .flags = 0,
        .dispatchcb = undefined,
    };
    proc.proc_kill_peer(&peer);
    try std.testing.expect((peer.flags & T.PEER_BAD) != 0);
}

test "proc_peer_check_version accepts MsgType.version regardless of peerid low byte" {
    var dummy_proc: T.ZmuxProc = .{ .name = "test" };
    var peer: T.ZmuxPeer = .{
        .parent = &dummy_proc,
        .ibuf = undefined,
        .uid = 0,
        .flags = 0,
        .dispatchcb = noop_dispatch,
    };
    var imsg_msg: c.imsg.imsg = std.mem.zeroes(c.imsg.imsg);
    imsg_msg.hdr.type = @as(@TypeOf(imsg_msg.hdr.type), @intCast(@intFromEnum(protocol.MsgType.version)));
    imsg_msg.hdr.peerid = 0;
    try std.testing.expectEqual(@as(i32, 0), proc.proc_peer_check_version(&peer, &imsg_msg));
    try std.testing.expect((peer.flags & T.PEER_BAD) == 0);
}

test "proc_peer_check_version accepts non-version when peerid encodes PROTOCOL_VERSION" {
    var dummy_proc: T.ZmuxProc = .{ .name = "test" };
    var peer: T.ZmuxPeer = .{
        .parent = &dummy_proc,
        .ibuf = undefined,
        .uid = 0,
        .flags = 0,
        .dispatchcb = noop_dispatch,
    };
    var imsg_msg: c.imsg.imsg = std.mem.zeroes(c.imsg.imsg);
    imsg_msg.hdr.type = @as(@TypeOf(imsg_msg.hdr.type), @intCast(@intFromEnum(protocol.MsgType.command)));
    imsg_msg.hdr.peerid = protocol.PROTOCOL_VERSION;
    try std.testing.expectEqual(@as(i32, 0), proc.proc_peer_check_version(&peer, &imsg_msg));
    try std.testing.expect((peer.flags & T.PEER_BAD) == 0);
}

test "proc_peer_check_version rejects mismatch, marks peer bad, sends version imsg" {
    var dummy_proc: T.ZmuxProc = .{ .name = "test" };
    defer dummy_proc.peers.deinit(xm.allocator);

    var pair: [2]i32 = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &pair));

    var peer: T.ZmuxPeer = .{
        .parent = &dummy_proc,
        .ibuf = undefined,
        .uid = 0,
        .flags = 0,
        .dispatchcb = noop_dispatch,
    };
    try std.testing.expectEqual(@as(i32, 0), c.imsg.imsgbuf_init(&peer.ibuf, pair[0]));
    defer {
        c.imsg.imsgbuf_clear(&peer.ibuf);
        std.posix.close(pair[0]);
    }

    var reader: c.imsg.imsgbuf = undefined;
    try std.testing.expectEqual(@as(i32, 0), c.imsg.imsgbuf_init(&reader, pair[1]));
    defer {
        c.imsg.imsgbuf_clear(&reader);
        std.posix.close(pair[1]);
    }

    var imsg_msg: c.imsg.imsg = std.mem.zeroes(c.imsg.imsg);
    imsg_msg.hdr.type = @as(@TypeOf(imsg_msg.hdr.type), @intCast(@intFromEnum(protocol.MsgType.command)));
    imsg_msg.hdr.peerid = 0;

    try std.testing.expectEqual(@as(i32, -1), proc.proc_peer_check_version(&peer, &imsg_msg));
    try std.testing.expect((peer.flags & T.PEER_BAD) != 0);

    try std.testing.expectEqual(@as(i32, 1), c.imsg.imsgbuf_read(&reader));
    var got: c.imsg.imsg = undefined;
    try std.testing.expect(c.imsg.imsg_get(&reader, &got) > 0);
    defer c.imsg.imsg_free(&got);
    try std.testing.expectEqual(@as(u32, @intCast(@intFromEnum(protocol.MsgType.version))), c.imsg.imsg_get_type(&got));
}

test "proc_send delivers message to peer socket" {
    var dummy_proc: T.ZmuxProc = .{ .name = "test" };
    defer dummy_proc.peers.deinit(xm.allocator);

    var pair: [2]i32 = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &pair));

    var peer: T.ZmuxPeer = .{
        .parent = &dummy_proc,
        .ibuf = undefined,
        .uid = 0,
        .flags = 0,
        .dispatchcb = noop_dispatch,
    };
    try std.testing.expectEqual(@as(i32, 0), c.imsg.imsgbuf_init(&peer.ibuf, pair[0]));
    defer {
        c.imsg.imsgbuf_clear(&peer.ibuf);
        std.posix.close(pair[0]);
    }

    var reader: c.imsg.imsgbuf = undefined;
    try std.testing.expectEqual(@as(i32, 0), c.imsg.imsgbuf_init(&reader, pair[1]));
    defer {
        c.imsg.imsgbuf_clear(&reader);
        std.posix.close(pair[1]);
    }

    try std.testing.expectEqual(@as(i32, 0), proc.proc_send(&peer, .detach, -1, null, 0));

    try std.testing.expectEqual(@as(i32, 1), c.imsg.imsgbuf_read(&reader));
    var got: c.imsg.imsg = undefined;
    try std.testing.expect(c.imsg.imsg_get(&reader, &got) > 0);
    defer c.imsg.imsg_free(&got);
    try std.testing.expectEqual(@as(u32, @intCast(@intFromEnum(protocol.MsgType.detach))), c.imsg.imsg_get_type(&got));
}

test "proc_send returns -1 when peer is PEER_BAD" {
    var dummy_proc: T.ZmuxProc = .{ .name = "test" };
    defer dummy_proc.peers.deinit(xm.allocator);

    var pair: [2]i32 = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &pair));

    var peer: T.ZmuxPeer = .{
        .parent = &dummy_proc,
        .ibuf = undefined,
        .uid = 0,
        .flags = T.PEER_BAD,
        .dispatchcb = noop_dispatch,
    };
    try std.testing.expectEqual(@as(i32, 0), c.imsg.imsgbuf_init(&peer.ibuf, pair[0]));
    defer {
        c.imsg.imsgbuf_clear(&peer.ibuf);
        std.posix.close(pair[0]);
        std.posix.close(pair[1]);
    }

    try std.testing.expectEqual(@as(i32, -1), proc.proc_send(&peer, .detach, -1, null, 0));
}

test "proc_send delivers identify_longflags with 8-byte payload" {
    var dummy_proc: T.ZmuxProc = .{ .name = "test" };
    defer dummy_proc.peers.deinit(xm.allocator);

    var pair: [2]i32 = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &pair));

    var peer: T.ZmuxPeer = .{
        .parent = &dummy_proc,
        .ibuf = undefined,
        .uid = 0,
        .flags = 0,
        .dispatchcb = noop_dispatch,
    };
    try std.testing.expectEqual(@as(i32, 0), c.imsg.imsgbuf_init(&peer.ibuf, pair[0]));
    defer {
        c.imsg.imsgbuf_clear(&peer.ibuf);
        std.posix.close(pair[0]);
    }

    var reader: c.imsg.imsgbuf = undefined;
    try std.testing.expectEqual(@as(i32, 0), c.imsg.imsgbuf_init(&reader, pair[1]));
    defer {
        c.imsg.imsgbuf_clear(&reader);
        std.posix.close(pair[1]);
    }

    const flags: u64 = 0xc0ffee11deadbeef;
    try std.testing.expectEqual(@as(i32, 0), proc.proc_send(&peer, .identify_longflags, -1, std.mem.asBytes(&flags).ptr, @sizeOf(u64)));

    try std.testing.expectEqual(@as(i32, 1), c.imsg.imsgbuf_read(&reader));
    var got: c.imsg.imsg = undefined;
    try std.testing.expect(c.imsg.imsg_get(&reader, &got) > 0);
    defer c.imsg.imsg_free(&got);
    try std.testing.expectEqual(@as(u32, @intCast(@intFromEnum(protocol.MsgType.identify_longflags))), c.imsg.imsg_get_type(&got));
    try std.testing.expectEqual(@as(usize, @sizeOf(u64)), c.imsg.imsg_get_len(&got));
    var round: u64 = undefined;
    try std.testing.expectEqual(@as(i32, 0), c.imsg.imsg_get_data(&got, std.mem.asBytes(&round).ptr, @sizeOf(u64)));
    try std.testing.expectEqual(flags, round);
}
