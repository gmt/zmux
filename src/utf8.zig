// Copyright (c) 2026 Greg Turner <gmt@pobox.com>
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
// Ported from tmux/utf8.c (minimal helper slice)
// Original copyright:
//   Copyright (c) 2008 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

const std = @import("std");
const T = @import("types.zig");

pub fn utf8_set(ud: *T.Utf8Data, ch: u8) void {
    ud.* = .{
        .data = std.mem.zeroes([T.UTF8_SIZE]u8),
        .have = 1,
        .size = 1,
        .width = 1,
    };
    ud.data[0] = ch;
}

pub fn utf8_copy(to: *T.Utf8Data, from: *const T.Utf8Data) void {
    to.* = from.*;
    for (to.data[to.size..]) |*b| b.* = 0;
}

test "utf8_set populates single-width ASCII data" {
    var ud: T.Utf8Data = undefined;
    utf8_set(&ud, 'x');

    try std.testing.expectEqual(@as(u8, 'x'), ud.data[0]);
    try std.testing.expectEqual(@as(u8, 1), ud.have);
    try std.testing.expectEqual(@as(u8, 1), ud.size);
    try std.testing.expectEqual(@as(u8, 1), ud.width);
}

test "utf8_copy zeroes trailing bytes" {
    var src: T.Utf8Data = .{
        .data = std.mem.zeroes([T.UTF8_SIZE]u8),
        .have = 2,
        .size = 2,
        .width = 1,
    };
    src.data[0] = 0xc3;
    src.data[1] = 0xa9;
    src.data[2] = 0xff;

    var dst: T.Utf8Data = undefined;
    utf8_copy(&dst, &src);

    try std.testing.expectEqual(@as(u8, 0xc3), dst.data[0]);
    try std.testing.expectEqual(@as(u8, 0xa9), dst.data[1]);
    try std.testing.expectEqual(@as(u8, 0), dst.data[2]);
}
