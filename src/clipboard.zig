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
// Reduced clipboard export support for attached clients.

const std = @import("std");
const T = @import("types.zig");
const file_mod = @import("file.zig");
const xm = @import("xmalloc.zig");

pub fn export_selection(cl: ?*T.Client, clip: []const u8, data: []const u8) void {
    const client = cl orelse return;
    if (!can_export_selection(client)) return;

    const sequence = osc52_sequence(xm.allocator, clip, data) catch unreachable;
    defer xm.allocator.free(sequence);

    _ = file_mod.sendPeerStream(client.peer.?, 1, sequence);
}

fn can_export_selection(cl: *const T.Client) bool {
    if (cl.peer == null) return false;
    if (cl.flags & T.CLIENT_CONTROL != 0) return false;
    return (cl.flags & T.CLIENT_ATTACHED) != 0 or (cl.tty.flags & T.TTY_STARTED) != 0;
}

pub fn osc52_sequence(allocator: std.mem.Allocator, clip: []const u8, data: []const u8) ![]u8 {
    const encoded_len = std.base64.standard.Encoder.calcSize(data.len);
    const encoded = try allocator.alloc(u8, encoded_len);
    defer allocator.free(encoded);
    const encoded_slice = std.base64.standard.Encoder.encode(encoded, data);
    return try std.fmt.allocPrint(allocator, "\x1b]52;{s};{s}\x07", .{ clip, encoded_slice });
}

test "osc52 sequence base64-encodes clipboard data" {
    const sequence = try osc52_sequence(std.testing.allocator, "", "hello");
    defer std.testing.allocator.free(sequence);

    try std.testing.expectEqualStrings("\x1b]52;;aGVsbG8=\x07", sequence);
}
