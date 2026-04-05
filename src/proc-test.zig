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
const os_mod = @import("os/linux.zig");
const c = @import("c.zig");

fn noop_dispatch(_: ?*c.imsg.imsg, _: ?*anyopaque) callconv(.c) void {}

const DispatchRecorder = struct {
    null_calls: usize = 0,
    msg_calls: usize = 0,
    last_type: ?u32 = null,
};

fn record_dispatch(imsg_msg: ?*c.imsg.imsg, arg: ?*anyopaque) callconv(.c) void {
    const recorder: *DispatchRecorder = @ptrCast(@alignCast(arg.?));
    if (imsg_msg) |msg| {
        recorder.msg_calls += 1;
        recorder.last_type = c.imsg.imsg_get_type(msg);
    } else {
        recorder.null_calls += 1;
    }
}

extern fn setsockopt(sockfd: c_int, level: c_int, optname: c_int, optval: ?*const anyopaque, optlen: c_uint) c_int;
extern fn proc_event_cb(fd: c_int, events: c_short, arg: ?*anyopaque) void;
const SOL_SOCKET: c_int = 1;
const SO_SNDBUF: c_int = 7;

fn setNonblocking(fd: i32, enabled: bool) void {
    const flags = std.c.fcntl(fd, std.posix.F.GETFL, @as(c_int, 0));
    if (flags < 0) return;
    const O_NONBLOCK: c_int = 0x800;
    const next: c_int = if (enabled) flags | O_NONBLOCK else flags & ~O_NONBLOCK;
    _ = std.c.fcntl(fd, std.posix.F.SETFL, next);
}

fn setSendBuffer(fd: i32, size: c_int) void {
    var value = size;
    _ = setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &value, @sizeOf(c_int));
}

fn drainSocket(fd: i32) !usize {
    var total: usize = 0;
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = std.posix.read(fd, &buf) catch |err| switch (err) {
            error.WouldBlock => break,
            else => return err,
        };
        if (n == 0) break;
        total += n;
    }
    return total;
}

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

test "proc_send re-arms EV_WRITE when flush leaves queued backlog" {
    var dummy_proc: T.ZmuxProc = .{ .name = "test" };
    defer dummy_proc.peers.deinit(xm.allocator);

    const old_base = proc.libevent;
    proc.libevent = os_mod.osdep_event_init();
    defer {
        c.libevent.event_base_free(proc.libevent.?);
        proc.libevent = old_base;
    }

    var pair: [2]i32 = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &pair));
    setSendBuffer(pair[0], 4096);
    setNonblocking(pair[0], true);
    setNonblocking(pair[1], true);

    const peer = proc.proc_add_peer(&dummy_proc, pair[0], noop_dispatch, null);
    defer {
        if (peer.event) |ev| {
            _ = c.libevent.event_del(ev);
            c.libevent.event_free(ev);
            peer.event = null;
        }
        c.imsg.imsgbuf_clear(&peer.ibuf);
        std.posix.close(peer.ibuf.fd);
        std.posix.close(pair[1]);
        xm.allocator.destroy(peer);
        dummy_proc.peers.clearRetainingCapacity();
    }

    const payload = [_]u8{'x'} ** 2048;
    var attempts: usize = 0;
    while (c.imsg.imsgbuf_queuelen(&peer.ibuf) == 0 and attempts < 256) : (attempts += 1) {
        try std.testing.expectEqual(@as(i32, 0), proc.proc_send(peer, .command, -1, payload[0..].ptr, payload.len));
    }

    try std.testing.expect(attempts < 256);
    const queued_before = c.imsg.imsgbuf_queuelen(&peer.ibuf);
    try std.testing.expect(queued_before > 0);

    _ = try drainSocket(pair[1]);

    var queued_after = queued_before;
    var flushed_after_loop: usize = 0;
    var spins: usize = 0;
    while (spins < 64 and queued_after > 0) : (spins += 1) {
        _ = c.libevent.event_base_loop(proc.libevent.?, c.libevent.EVLOOP_NONBLOCK);
        flushed_after_loop += try drainSocket(pair[1]);
        queued_after = c.imsg.imsgbuf_queuelen(&peer.ibuf);
        if (queued_after < queued_before and flushed_after_loop > 0) break;
    }

    try std.testing.expect(flushed_after_loop > 0);
    try std.testing.expect(queued_after < queued_before);
}

test "proc_event_cb dispatches null when EV_READ hits peer EOF" {
    var dummy_proc: T.ZmuxProc = .{ .name = "test" };
    defer dummy_proc.peers.deinit(xm.allocator);

    var pair: [2]i32 = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &pair));

    var recorder = DispatchRecorder{};
    var peer: T.ZmuxPeer = .{
        .parent = &dummy_proc,
        .ibuf = undefined,
        .uid = 0,
        .flags = 0,
        .dispatchcb = record_dispatch,
        .arg = &recorder,
    };
    try std.testing.expectEqual(@as(i32, 0), c.imsg.imsgbuf_init(&peer.ibuf, pair[0]));
    defer {
        c.imsg.imsgbuf_clear(&peer.ibuf);
        std.posix.close(pair[0]);
    }

    std.posix.close(pair[1]);
    proc_event_cb(peer.ibuf.fd, @intCast(c.libevent.EV_READ), &peer);

    try std.testing.expectEqual(@as(usize, 1), recorder.null_calls);
    try std.testing.expectEqual(@as(usize, 0), recorder.msg_calls);
}

test "proc_event_cb dispatches null immediately for drained bad peers" {
    var dummy_proc: T.ZmuxProc = .{ .name = "test" };
    defer dummy_proc.peers.deinit(xm.allocator);

    var pair: [2]i32 = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &pair));

    var recorder = DispatchRecorder{};
    var peer: T.ZmuxPeer = .{
        .parent = &dummy_proc,
        .ibuf = undefined,
        .uid = 0,
        .flags = T.PEER_BAD,
        .dispatchcb = record_dispatch,
        .arg = &recorder,
    };
    try std.testing.expectEqual(@as(i32, 0), c.imsg.imsgbuf_init(&peer.ibuf, pair[0]));
    defer {
        c.imsg.imsgbuf_clear(&peer.ibuf);
        std.posix.close(pair[0]);
        std.posix.close(pair[1]);
    }

    proc_event_cb(peer.ibuf.fd, 0, &peer);

    try std.testing.expectEqual(@as(usize, 1), recorder.null_calls);
    try std.testing.expectEqual(@as(usize, 0), recorder.msg_calls);
}
