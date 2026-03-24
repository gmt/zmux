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
// Ported from tmux/attributes.c
// Original copyright:
//   Copyright (c) 2009 Joshua Elsasser <josh@elsasser.org>
//   ISC licence – same terms as above.

const std = @import("std");
const T = @import("types.zig");

const AttrName = struct {
    name: []const u8,
    attr: u16,
};

const attr_table = [_]AttrName{
    .{ .name = "acs", .attr = T.GRID_ATTR_CHARSET },
    .{ .name = "bright", .attr = T.GRID_ATTR_BRIGHT },
    .{ .name = "dim", .attr = T.GRID_ATTR_DIM },
    .{ .name = "underscore", .attr = T.GRID_ATTR_UNDERSCORE },
    .{ .name = "blink", .attr = T.GRID_ATTR_BLINK },
    .{ .name = "reverse", .attr = T.GRID_ATTR_REVERSE },
    .{ .name = "hidden", .attr = T.GRID_ATTR_HIDDEN },
    .{ .name = "italics", .attr = T.GRID_ATTR_ITALICS },
    .{ .name = "strikethrough", .attr = T.GRID_ATTR_STRIKETHROUGH },
    .{ .name = "double-underscore", .attr = T.GRID_ATTR_UNDERSCORE_2 },
    .{ .name = "curly-underscore", .attr = T.GRID_ATTR_UNDERSCORE_3 },
    .{ .name = "dotted-underscore", .attr = T.GRID_ATTR_UNDERSCORE_4 },
    .{ .name = "dashed-underscore", .attr = T.GRID_ATTR_UNDERSCORE_5 },
    .{ .name = "overline", .attr = T.GRID_ATTR_OVERLINE },
};

threadlocal var attr_buf: [512]u8 = undefined;

pub fn attributes_tostring(attr: u16) []const u8 {
    if (attr == 0) return "none";

    var stream = std.io.fixedBufferStream(&attr_buf);
    const writer = stream.writer();
    var first = true;

    for (attr_table) |entry| {
        if (attr & entry.attr == 0) continue;
        if (!first) writer.writeByte(',') catch unreachable;
        writer.writeAll(entry.name) catch unreachable;
        first = false;
    }

    return stream.getWritten();
}

pub fn attributes_fromstring(str: []const u8) i32 {
    if (str.len == 0 or is_delimiter(str[0]) or is_delimiter(str[str.len - 1]))
        return -1;
    if (std.ascii.eqlIgnoreCase(str, "default") or std.ascii.eqlIgnoreCase(str, "none"))
        return 0;

    var attr: u16 = 0;
    var start: usize = 0;
    while (start < str.len) {
        const end_rel = std.mem.indexOfAny(u8, str[start..], " ,|") orelse (str.len - start);
        const token = str[start .. start + end_rel];
        if (token.len == 0) return -1;

        var matched = false;
        for (attr_table) |entry| {
            if (std.ascii.eqlIgnoreCase(token, entry.name)) {
                attr |= entry.attr;
                matched = true;
                break;
            }
        }
        if (!matched and std.ascii.eqlIgnoreCase(token, "bold")) {
            attr |= T.GRID_ATTR_BRIGHT;
            matched = true;
        }
        if (!matched) return -1;

        start += end_rel;
        while (start < str.len and is_delimiter(str[start])) start += 1;
    }

    return attr;
}

fn is_delimiter(ch: u8) bool {
    return ch == ' ' or ch == ',' or ch == '|';
}

test "attributes_tostring renders a comma-separated list" {
    try std.testing.expectEqualStrings(
        "bright,italics,overline",
        attributes_tostring(T.GRID_ATTR_BRIGHT | T.GRID_ATTR_ITALICS | T.GRID_ATTR_OVERLINE),
    );
}

test "attributes_fromstring parses aliases and delimiters" {
    try std.testing.expectEqual(
        @as(i32, T.GRID_ATTR_BRIGHT | T.GRID_ATTR_UNDERSCORE | T.GRID_ATTR_OVERLINE),
        attributes_fromstring("bold|underscore overline"),
    );
}

test "attributes_fromstring rejects malformed input" {
    try std.testing.expectEqual(@as(i32, -1), attributes_fromstring("bright,"));
    try std.testing.expectEqual(@as(i32, -1), attributes_fromstring("mystery"));
}
