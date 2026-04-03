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

test "zmux protocol version and extern payload sizes stay C-compatible" {
    try std.testing.expectEqual(@as(u32, 9), p.PROTOCOL_VERSION);

    try std.testing.expectEqual(@sizeOf(c_int), @sizeOf(p.MsgCommand));

    try std.testing.expectEqual(2 * @sizeOf(c_int), @sizeOf(p.MsgReadOpen));
    try std.testing.expectEqual(@sizeOf(c_int), @sizeOf(p.MsgReadData));
    try std.testing.expectEqual(2 * @sizeOf(c_int), @sizeOf(p.MsgReadDone));
    try std.testing.expectEqual(@sizeOf(c_int), @sizeOf(p.MsgReadCancel));

    try std.testing.expectEqual(3 * @sizeOf(c_int), @sizeOf(p.MsgWriteOpen));
    try std.testing.expectEqual(@sizeOf(c_int), @sizeOf(p.MsgWriteData));
    try std.testing.expectEqual(2 * @sizeOf(c_int), @sizeOf(p.MsgWriteReady));
    try std.testing.expectEqual(@sizeOf(c_int), @sizeOf(p.MsgWriteClose));

    try std.testing.expectEqual(4 * @sizeOf(u32), @sizeOf(p.MsgResize));

    try std.testing.expectEqual(@alignOf(c_int), @alignOf(p.MsgCommand));
    try std.testing.expectEqual(@alignOf(u32), @alignOf(p.MsgResize));
}
