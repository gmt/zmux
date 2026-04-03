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

//! imsg-roundtrip-test.zig – compose → flush → read → imsg_get coverage.

const std = @import("std");
const protocol = @import("zmux-protocol.zig");
const c = @import("c.zig");

fn imsgRoundtripPayload(msg_type: protocol.MsgType, payload: []const u8) !void {
    var pair: [2]i32 = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &pair));

    var sender: c.imsg.imsgbuf = undefined;
    try std.testing.expectEqual(@as(i32, 0), c.imsg.imsgbuf_init(&sender, pair[0]));
    defer {
        c.imsg.imsgbuf_clear(&sender);
        std.posix.close(pair[0]);
    }

    var reader: c.imsg.imsgbuf = undefined;
    try std.testing.expectEqual(@as(i32, 0), c.imsg.imsgbuf_init(&reader, pair[1]));
    defer {
        c.imsg.imsgbuf_clear(&reader);
        std.posix.close(pair[1]);
    }

    const p: ?[*]const u8 = if (payload.len == 0) null else payload.ptr;
    try std.testing.expectEqual(
        @as(i32, 1),
        c.imsg.imsg_compose(
            &sender,
            @intCast(@intFromEnum(msg_type)),
            protocol.PROTOCOL_VERSION,
            -1,
            -1,
            @constCast(p),
            payload.len,
        ),
    );
    try std.testing.expectEqual(@as(i32, 0), c.imsg.imsgbuf_flush(&sender));

    try std.testing.expectEqual(@as(i32, 1), c.imsg.imsgbuf_read(&reader));
    var got: c.imsg.imsg = undefined;
    try std.testing.expect(c.imsg.imsg_get(&reader, &got) > 0);
    defer c.imsg.imsg_free(&got);

    try std.testing.expectEqual(@as(u32, @intCast(@intFromEnum(msg_type))), c.imsg.imsg_get_type(&got));
    try std.testing.expectEqual(payload.len, c.imsg.imsg_get_len(&got));
    if (payload.len > 0) {
        var stack: [16384]u8 = undefined;
        try std.testing.expect(payload.len <= stack.len);
        try std.testing.expectEqual(
            @as(i32, 0),
            c.imsg.imsg_get_buf(&got, stack[0..payload.len].ptr, payload.len),
        );
        try std.testing.expectEqualSlices(u8, payload, stack[0..payload.len]);
    }
}

const MaxPayloadBuf = struct {
    const cap = 16384;
    bytes: [cap]u8 = undefined,
};

test "imsg roundtrip empty version payload" {
    try imsgRoundtripPayload(.version, &.{});
}

test "imsg roundtrip resize struct" {
    const m: protocol.MsgResize = .{
        .sx = 132,
        .sy = 43,
        .xpixel = 1056,
        .ypixel = 344,
    };
    try imsgRoundtripPayload(.resize, std.mem.asBytes(&m));
}

test "imsg roundtrip command argc and packed argv" {
    const cmd: protocol.MsgCommand = .{ .argc = 3 };
    const tail = "list-keys\x00-t\x00*\x00";
    var buf: [64]u8 = undefined;
    @memcpy(buf[0..@sizeOf(protocol.MsgCommand)], std.mem.asBytes(&cmd));
    @memcpy(buf[@sizeOf(protocol.MsgCommand)..][0..tail.len], tail);
    const total = @sizeOf(protocol.MsgCommand) + tail.len;
    try imsgRoundtripPayload(.command, buf[0..total]);
}

test "imsg roundtrip read_open header and path" {
    const ro: protocol.MsgReadOpen = .{ .stream = 2, .fd = -1 };
    const path = "/tmp/zmux-imsg-ro-test\x00";
    var buf: [128]u8 = undefined;
    @memcpy(buf[0..@sizeOf(protocol.MsgReadOpen)], std.mem.asBytes(&ro));
    @memcpy(buf[@sizeOf(protocol.MsgReadOpen)..][0..path.len], path);
    const total = @sizeOf(protocol.MsgReadOpen) + path.len;
    try imsgRoundtripPayload(.read_open, buf[0..total]);
}

test "imsg roundtrip write_open header path and flags" {
    const wo: protocol.MsgWriteOpen = .{ .stream = 3, .fd = 7, .flags = 42 };
    const path = "./relative-write-path\x00";
    var buf: [128]u8 = undefined;
    @memcpy(buf[0..@sizeOf(protocol.MsgWriteOpen)], std.mem.asBytes(&wo));
    @memcpy(buf[@sizeOf(protocol.MsgWriteOpen)..][0..path.len], path);
    const total = @sizeOf(protocol.MsgWriteOpen) + path.len;
    try imsgRoundtripPayload(.write_open, buf[0..total]);
}

test "imsg roundtrip large command argv within max imsg size" {
    var buf: MaxPayloadBuf = undefined;
    const cmd: protocol.MsgCommand = .{ .argc = 1 };
    @memcpy(buf.bytes[0..@sizeOf(protocol.MsgCommand)], std.mem.asBytes(&cmd));

    const inner_len = 15000;
    const prefix = @sizeOf(protocol.MsgCommand);
    var i: usize = 0;
    while (i < inner_len) : (i += 1) {
        buf.bytes[prefix + i] = @as(u8, @intCast('a' + @as(u8, @intCast(i % 26))));
    }
    buf.bytes[prefix + inner_len] = 0;
    const total = prefix + inner_len + 1;
    try std.testing.expect(total + @sizeOf(c.imsg.imsg_hdr) <= 16384);
    try imsgRoundtripPayload(.command, buf.bytes[0..total]);
}

test "imsg read rejects oversize declared length in header" {
    var pair: [2]i32 = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &pair));
    defer {
        std.posix.close(pair[0]);
        std.posix.close(pair[1]);
    }

    var reader: c.imsg.imsgbuf = undefined;
    try std.testing.expectEqual(@as(i32, 0), c.imsg.imsgbuf_init(&reader, pair[1]));
    defer c.imsg.imsgbuf_clear(&reader);

    const bad: c.imsg.imsg_hdr = .{
        .type = @intCast(@intFromEnum(protocol.MsgType.command)),
        .len = 50_000,
        .peerid = protocol.PROTOCOL_VERSION,
        .pid = 0,
    };
    _ = try std.posix.write(pair[0], std.mem.asBytes(&bad));
    try std.testing.expectEqual(@as(i32, -1), c.imsg.imsgbuf_read(&reader));
}

test "imsg partial header yields no complete message yet" {
    var pair: [2]i32 = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &pair));
    defer {
        std.posix.close(pair[0]);
        std.posix.close(pair[1]);
    }

    var reader: c.imsg.imsgbuf = undefined;
    try std.testing.expectEqual(@as(i32, 0), c.imsg.imsgbuf_init(&reader, pair[1]));
    defer c.imsg.imsgbuf_clear(&reader);

    const hdr: c.imsg.imsg_hdr = .{
        .type = @intCast(@intFromEnum(protocol.MsgType.detach)),
        .len = @sizeOf(c.imsg.imsg_hdr),
        .peerid = protocol.PROTOCOL_VERSION,
        .pid = 0,
    };
    _ = try std.posix.write(pair[0], std.mem.asBytes(&hdr)[0..8]);

    try std.testing.expectEqual(@as(i32, 1), c.imsg.imsgbuf_read(&reader));
    var got: c.imsg.imsg = undefined;
    try std.testing.expectEqual(@as(isize, 0), c.imsg.imsg_get(&reader, &got));
}
