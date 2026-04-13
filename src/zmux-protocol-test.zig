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

//! Compile-time checks for zmux IPC wire layout (see tmux-protocol.h).

const std = @import("std");
const p = @import("zmux-protocol.zig");

fn expectSequentialCInts(comptime T: type) !void {
    const fields = std.meta.fields(T);
    try std.testing.expect(fields.len > 0);
    try std.testing.expectEqual(@as(usize, fields.len) * @sizeOf(c_int), @sizeOf(T));
    try std.testing.expectEqual(@alignOf(c_int), @alignOf(T));

    inline for (fields, 0..) |field, i| {
        try std.testing.expect(field.type == c_int);
        try std.testing.expectEqual(i * @sizeOf(c_int), @offsetOf(T, field.name));
    }
}

fn roundTripStruct(comptime T: type, value: T) !void {
    var encoded: [@sizeOf(T)]u8 = undefined;
    @memcpy(encoded[0..], std.mem.asBytes(&value));
    const decoded = std.mem.bytesAsValue(T, encoded[0..]);
    try std.testing.expectEqual(value, decoded.*);
}

fn roundTripEnvelope(comptime T: type, value: T, payload: []const u8) !void {
    var buf: [16 * 1024]u8 = undefined;
    const used = @sizeOf(T) + payload.len;
    try std.testing.expect(used <= buf.len);

    @memcpy(buf[0..@sizeOf(T)], std.mem.asBytes(&value));
    @memcpy(buf[@sizeOf(T)..used], payload);

    const decoded = std.mem.bytesAsValue(T, buf[0..@sizeOf(T)]);
    try std.testing.expectEqual(value, decoded.*);
    try std.testing.expectEqualSlices(u8, payload, buf[@sizeOf(T)..used]);
}

test "zmux protocol version and enum numbering stay C-compatible" {
    try std.testing.expectEqual(@as(u32, 8), p.PROTOCOL_VERSION);

    try std.testing.expectEqual(@as(i32, 12), @intFromEnum(p.MsgType.version));
    try std.testing.expectEqual(@as(i32, 100), @intFromEnum(p.MsgType.identify_flags));
    try std.testing.expectEqual(@as(i32, 112), @intFromEnum(p.MsgType.identify_terminfo));
    try std.testing.expectEqual(@as(i32, 200), @intFromEnum(p.MsgType.command));
    try std.testing.expectEqual(@as(i32, 201), @intFromEnum(p.MsgType.detach));
    try std.testing.expectEqual(@as(i32, 208), @intFromEnum(p.MsgType.resize));
    try std.testing.expectEqual(@as(i32, 218), @intFromEnum(p.MsgType.flags));
    try std.testing.expectEqual(@as(i32, 300), @intFromEnum(p.MsgType.read_open));
}

test "zmux identify message types stay contiguous after identify_flags" {
    try std.testing.expectEqual(@intFromEnum(p.MsgType.identify_flags) + 1, @intFromEnum(p.MsgType.identify_term));
    try std.testing.expectEqual(@intFromEnum(p.MsgType.identify_term) + 1, @intFromEnum(p.MsgType.identify_ttyname));
}

test "zmux wire structs match tmux layout exactly" {
    try expectSequentialCInts(p.MsgCommand);
    try expectSequentialCInts(p.MsgReadOpen);
    try expectSequentialCInts(p.MsgReadData);
    try expectSequentialCInts(p.MsgReadDone);
    try expectSequentialCInts(p.MsgReadCancel);
    try expectSequentialCInts(p.MsgWriteOpen);
    try expectSequentialCInts(p.MsgWriteData);
    try expectSequentialCInts(p.MsgWriteReady);
    try expectSequentialCInts(p.MsgWriteClose);
}

test "zmux wire structs round-trip through raw bytes" {
    try roundTripStruct(p.MsgCommand, .{ .argc = std.math.maxInt(c_int) });
    try roundTripStruct(p.MsgReadOpen, .{ .stream = 0, .fd = -1 });
    try roundTripStruct(p.MsgReadData, .{ .stream = std.math.minInt(c_int) });
    try roundTripStruct(p.MsgReadDone, .{ .stream = 2, .@"error" = std.math.maxInt(c_int) });
    try roundTripStruct(p.MsgReadCancel, .{ .stream = 7 });
    try roundTripStruct(p.MsgWriteOpen, .{ .stream = 3, .fd = 4, .flags = std.math.maxInt(c_int) });
    try roundTripStruct(p.MsgWriteData, .{ .stream = 9 });
    try roundTripStruct(p.MsgWriteReady, .{ .stream = 11, .@"error" = std.math.minInt(c_int) });
    try roundTripStruct(p.MsgWriteClose, .{ .stream = 13 });
}

test "zmux wire envelopes preserve empty and max payloads" {
    try roundTripEnvelope(p.MsgReadData, .{ .stream = 0 }, &.{});
    try roundTripEnvelope(p.MsgWriteData, .{ .stream = 1 }, &.{});

    var max_argv_payload: [15 * 1024]u8 = undefined;
    for (&max_argv_payload, 0..) |*b, i| {
        b.* = @as(u8, @intCast(i % 251));
    }
    try roundTripEnvelope(p.MsgCommand, .{ .argc = 2048 }, max_argv_payload[0..]);

    var max_data_payload: [15 * 1024]u8 = undefined;
    for (&max_data_payload, 0..) |*b, i| {
        b.* = @as(u8, @intCast(255 - (i % 251)));
    }
    try roundTripEnvelope(p.MsgWriteData, .{ .stream = 42 }, max_data_payload[0..]);
}

test "zmux PROTOCOL_VERSION fits in peerid low byte" {
    try std.testing.expect(p.PROTOCOL_VERSION <= 0xff);
}

test "MsgType values match tmux-protocol.h exactly — all 34 message types" {
    // version band
    try std.testing.expectEqual(@as(i32, 12), @intFromEnum(p.MsgType.version));

    // identify band: 100–112 (13 values)
    try std.testing.expectEqual(@as(i32, 100), @intFromEnum(p.MsgType.identify_flags));
    try std.testing.expectEqual(@as(i32, 101), @intFromEnum(p.MsgType.identify_term));
    try std.testing.expectEqual(@as(i32, 102), @intFromEnum(p.MsgType.identify_ttyname));
    try std.testing.expectEqual(@as(i32, 103), @intFromEnum(p.MsgType.identify_oldcwd));
    try std.testing.expectEqual(@as(i32, 104), @intFromEnum(p.MsgType.identify_stdin));
    try std.testing.expectEqual(@as(i32, 105), @intFromEnum(p.MsgType.identify_environ));
    try std.testing.expectEqual(@as(i32, 106), @intFromEnum(p.MsgType.identify_done));
    try std.testing.expectEqual(@as(i32, 107), @intFromEnum(p.MsgType.identify_clientpid));
    try std.testing.expectEqual(@as(i32, 108), @intFromEnum(p.MsgType.identify_cwd));
    try std.testing.expectEqual(@as(i32, 109), @intFromEnum(p.MsgType.identify_features));
    try std.testing.expectEqual(@as(i32, 110), @intFromEnum(p.MsgType.identify_stdout));
    try std.testing.expectEqual(@as(i32, 111), @intFromEnum(p.MsgType.identify_longflags));
    try std.testing.expectEqual(@as(i32, 112), @intFromEnum(p.MsgType.identify_terminfo));

    // command band: 200–218 (19 values)
    try std.testing.expectEqual(@as(i32, 200), @intFromEnum(p.MsgType.command));
    try std.testing.expectEqual(@as(i32, 201), @intFromEnum(p.MsgType.detach));
    try std.testing.expectEqual(@as(i32, 202), @intFromEnum(p.MsgType.detachkill));
    try std.testing.expectEqual(@as(i32, 203), @intFromEnum(p.MsgType.exit));
    try std.testing.expectEqual(@as(i32, 204), @intFromEnum(p.MsgType.exited));
    try std.testing.expectEqual(@as(i32, 205), @intFromEnum(p.MsgType.exiting));
    try std.testing.expectEqual(@as(i32, 206), @intFromEnum(p.MsgType.lock));
    try std.testing.expectEqual(@as(i32, 207), @intFromEnum(p.MsgType.ready));
    try std.testing.expectEqual(@as(i32, 208), @intFromEnum(p.MsgType.resize));
    try std.testing.expectEqual(@as(i32, 209), @intFromEnum(p.MsgType.shell));
    try std.testing.expectEqual(@as(i32, 210), @intFromEnum(p.MsgType.shutdown));
    try std.testing.expectEqual(@as(i32, 211), @intFromEnum(p.MsgType.oldstderr));
    try std.testing.expectEqual(@as(i32, 212), @intFromEnum(p.MsgType.oldstdin));
    try std.testing.expectEqual(@as(i32, 213), @intFromEnum(p.MsgType.oldstdout));
    try std.testing.expectEqual(@as(i32, 214), @intFromEnum(p.MsgType.@"suspend"));
    try std.testing.expectEqual(@as(i32, 215), @intFromEnum(p.MsgType.unlock));
    try std.testing.expectEqual(@as(i32, 216), @intFromEnum(p.MsgType.wakeup));
    try std.testing.expectEqual(@as(i32, 217), @intFromEnum(p.MsgType.exec));
    try std.testing.expectEqual(@as(i32, 218), @intFromEnum(p.MsgType.flags));

    // read/write band: 300–307 (8 values)
    try std.testing.expectEqual(@as(i32, 300), @intFromEnum(p.MsgType.read_open));
    try std.testing.expectEqual(@as(i32, 301), @intFromEnum(p.MsgType.read));
    try std.testing.expectEqual(@as(i32, 302), @intFromEnum(p.MsgType.read_done));
    try std.testing.expectEqual(@as(i32, 303), @intFromEnum(p.MsgType.write_open));
    try std.testing.expectEqual(@as(i32, 304), @intFromEnum(p.MsgType.write));
    try std.testing.expectEqual(@as(i32, 305), @intFromEnum(p.MsgType.write_ready));
    try std.testing.expectEqual(@as(i32, 306), @intFromEnum(p.MsgType.write_close));
    try std.testing.expectEqual(@as(i32, 307), @intFromEnum(p.MsgType.read_cancel));

    // Total enum field count must equal 1 + 13 + 19 + 8 = 41.
    // (tmux has exactly this many entries in enum msgtype.)
    try std.testing.expectEqual(@as(usize, 41), @typeInfo(p.MsgType).@"enum".fields.len);
}

test "zmux has no stdin_data message type at value 400" {
    // stdin_data was a zmux-only extension that has been removed.
    // Verify no MsgType discriminant has value 400.
    inline for (@typeInfo(p.MsgType).@"enum".fields) |field| {
        try std.testing.expect(field.value != 400);
    }
}

test "zmux MSG_RESIZE carries no struct payload (MsgResize does not exist)" {
    // tmux MSG_RESIZE is an empty message — the server reads geometry
    // from the client fd via ioctl(TIOCGWINSZ).  No MsgResize struct
    // should exist in the protocol definition.
    comptime try std.testing.expect(!@hasDecl(p, "MsgResize"));
}
