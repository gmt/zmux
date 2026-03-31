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
// Ported in part from tmux/tty-acs.c.
// Original copyright:
//   Copyright (c) 2010 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

//! tty-acs.zig – ACS and line-drawing lookup helpers.

const std = @import("std");
const T = @import("types.zig");
const env_mod = @import("environ.zig");
const tty_term = @import("tty-term.zig");

pub const CELL_INSIDE: usize = 0;
pub const CELL_TOPBOTTOM: usize = 1;
pub const CELL_LEFTRIGHT: usize = 2;
pub const CELL_TOPLEFT: usize = 3;
pub const CELL_TOPRIGHT: usize = 4;
pub const CELL_BOTTOMLEFT: usize = 5;
pub const CELL_BOTTOMRIGHT: usize = 6;
pub const CELL_TOPJOIN: usize = 7;
pub const CELL_BOTTOMJOIN: usize = 8;
pub const CELL_LEFTJOIN: usize = 9;
pub const CELL_RIGHTJOIN: usize = 10;
pub const CELL_JOIN: usize = 11;
pub const CELL_OUTSIDE: usize = 12;

const AcsEntry = struct {
    key: u8,
    string: []const u8,
};

const AcsReverseEntry = struct {
    string: []const u8,
    key: u8,
};

const acs_table = [_]AcsEntry{
    .{ .key = '+', .string = "\xe2\x86\x92" },
    .{ .key = ',', .string = "\xe2\x86\x90" },
    .{ .key = '-', .string = "\xe2\x86\x91" },
    .{ .key = '.', .string = "\xe2\x86\x93" },
    .{ .key = '0', .string = "\xe2\x96\xae" },
    .{ .key = '`', .string = "\xe2\x97\x86" },
    .{ .key = 'a', .string = "\xe2\x96\x92" },
    .{ .key = 'b', .string = "\xe2\x90\x89" },
    .{ .key = 'c', .string = "\xe2\x90\x8c" },
    .{ .key = 'd', .string = "\xe2\x90\x8d" },
    .{ .key = 'e', .string = "\xe2\x90\x8a" },
    .{ .key = 'f', .string = "\xc2\xb0" },
    .{ .key = 'g', .string = "\xc2\xb1" },
    .{ .key = 'h', .string = "\xe2\x90\xa4" },
    .{ .key = 'i', .string = "\xe2\x90\x8b" },
    .{ .key = 'j', .string = "\xe2\x94\x98" },
    .{ .key = 'k', .string = "\xe2\x94\x90" },
    .{ .key = 'l', .string = "\xe2\x94\x8c" },
    .{ .key = 'm', .string = "\xe2\x94\x94" },
    .{ .key = 'n', .string = "\xe2\x94\xbc" },
    .{ .key = 'o', .string = "\xe2\x8e\xba" },
    .{ .key = 'p', .string = "\xe2\x8e\xbb" },
    .{ .key = 'q', .string = "\xe2\x94\x80" },
    .{ .key = 'r', .string = "\xe2\x8e\xbc" },
    .{ .key = 's', .string = "\xe2\x8e\xbd" },
    .{ .key = 't', .string = "\xe2\x94\x9c" },
    .{ .key = 'u', .string = "\xe2\x94\xa4" },
    .{ .key = 'v', .string = "\xe2\x94\xb4" },
    .{ .key = 'w', .string = "\xe2\x94\xac" },
    .{ .key = 'x', .string = "\xe2\x94\x82" },
    .{ .key = 'y', .string = "\xe2\x89\xa4" },
    .{ .key = 'z', .string = "\xe2\x89\xa5" },
    .{ .key = '{', .string = "\xcf\x80" },
    .{ .key = '|', .string = "\xe2\x89\xa0" },
    .{ .key = '}', .string = "\xc2\xa3" },
    .{ .key = '~', .string = "\xc2\xb7" },
};

const acs_reverse2 = [_]AcsReverseEntry{
    .{ .string = "\xc2\xb7", .key = '~' },
};

const acs_reverse3 = [_]AcsReverseEntry{
    .{ .string = "\xe2\x94\x80", .key = 'q' },
    .{ .string = "\xe2\x94\x81", .key = 'q' },
    .{ .string = "\xe2\x94\x82", .key = 'x' },
    .{ .string = "\xe2\x94\x83", .key = 'x' },
    .{ .string = "\xe2\x94\x8c", .key = 'l' },
    .{ .string = "\xe2\x94\x8f", .key = 'k' },
    .{ .string = "\xe2\x94\x90", .key = 'k' },
    .{ .string = "\xe2\x94\x93", .key = 'l' },
    .{ .string = "\xe2\x94\x94", .key = 'm' },
    .{ .string = "\xe2\x94\x97", .key = 'm' },
    .{ .string = "\xe2\x94\x98", .key = 'j' },
    .{ .string = "\xe2\x94\x9b", .key = 'j' },
    .{ .string = "\xe2\x94\x9c", .key = 't' },
    .{ .string = "\xe2\x94\xa3", .key = 't' },
    .{ .string = "\xe2\x94\xa4", .key = 'u' },
    .{ .string = "\xe2\x94\xab", .key = 'u' },
    .{ .string = "\xe2\x94\xb3", .key = 'w' },
    .{ .string = "\xe2\x94\xb4", .key = 'v' },
    .{ .string = "\xe2\x94\xbb", .key = 'v' },
    .{ .string = "\xe2\x94\xbc", .key = 'n' },
    .{ .string = "\xe2\x95\x8b", .key = 'n' },
    .{ .string = "\xe2\x95\x90", .key = 'q' },
    .{ .string = "\xe2\x95\x91", .key = 'x' },
    .{ .string = "\xe2\x95\x94", .key = 'l' },
    .{ .string = "\xe2\x95\x97", .key = 'k' },
    .{ .string = "\xe2\x95\x9a", .key = 'm' },
    .{ .string = "\xe2\x95\x9d", .key = 'j' },
    .{ .string = "\xe2\x95\xa0", .key = 't' },
    .{ .string = "\xe2\x95\xa3", .key = 'u' },
    .{ .string = "\xe2\x95\xa6", .key = 'w' },
    .{ .string = "\xe2\x95\xa9", .key = 'v' },
    .{ .string = "\xe2\x95\xac", .key = 'n' },
};

const double_borders_list = [_]T.Utf8Data{
    utf8Data(""),
    utf8Data("\xe2\x95\x91"),
    utf8Data("\xe2\x95\x90"),
    utf8Data("\xe2\x95\x94"),
    utf8Data("\xe2\x95\x97"),
    utf8Data("\xe2\x95\x9a"),
    utf8Data("\xe2\x95\x9d"),
    utf8Data("\xe2\x95\xa6"),
    utf8Data("\xe2\x95\xa9"),
    utf8Data("\xe2\x95\xa0"),
    utf8Data("\xe2\x95\xa3"),
    utf8Data("\xe2\x95\xac"),
    utf8Data("\xc2\xb7"),
};

const heavy_borders_list = [_]T.Utf8Data{
    utf8Data(""),
    utf8Data("\xe2\x94\x83"),
    utf8Data("\xe2\x94\x81"),
    utf8Data("\xe2\x94\x8f"),
    utf8Data("\xe2\x94\x93"),
    utf8Data("\xe2\x94\x97"),
    utf8Data("\xe2\x94\x9b"),
    utf8Data("\xe2\x94\xb3"),
    utf8Data("\xe2\x94\xbb"),
    utf8Data("\xe2\x94\xa3"),
    utf8Data("\xe2\x94\xab"),
    utf8Data("\xe2\x95\x8b"),
    utf8Data("\xc2\xb7"),
};

const rounded_borders_list = [_]T.Utf8Data{
    utf8Data(""),
    utf8Data("\xe2\x94\x82"),
    utf8Data("\xe2\x94\x80"),
    utf8Data("\xe2\x95\xad"),
    utf8Data("\xe2\x95\xae"),
    utf8Data("\xe2\x95\xb0"),
    utf8Data("\xe2\x95\xaf"),
    utf8Data("\xe2\x94\xb3"),
    utf8Data("\xe2\x94\xbb"),
    utf8Data("\xe2\x94\x9c"),
    utf8Data("\xe2\x94\xa4"),
    utf8Data("\xe2\x95\x8b"),
    utf8Data("\xc2\xb7"),
};

pub fn tty_acs_double_borders(cell_type: usize) *const T.Utf8Data {
    return &double_borders_list[cell_type];
}

pub fn tty_acs_heavy_borders(cell_type: usize) *const T.Utf8Data {
    return &heavy_borders_list[cell_type];
}

pub fn tty_acs_rounded_borders(cell_type: usize) *const T.Utf8Data {
    return &rounded_borders_list[cell_type];
}

pub fn tty_acs_needed(tty: ?*const T.Tty) bool {
    const real_tty = tty orelse return false;

    if (tty_term.numberCapability(real_tty, "U8")) |u8_cap|
        if (u8_cap == 0) return true;
    return (real_tty.client.flags & T.CLIENT_UTF8) == 0;
}

pub fn tty_acs_get(tty: ?*const T.Tty, ch: u8) ?[]const u8 {
    if (tty_acs_needed(tty)) {
        const real_tty = tty orelse return null;
        return tty_term.acsCapability(real_tty, ch);
    }

    for (acs_table) |entry| {
        if (entry.key == ch) return entry.string;
    }
    return null;
}

pub fn tty_acs_reverse_get(s: []const u8) i32 {
    const table = switch (s.len) {
        2 => acs_reverse2[0..],
        3 => acs_reverse3[0..],
        else => return -1,
    };

    for (table) |entry| {
        if (std.mem.eql(u8, s, entry.string)) return entry.key;
    }
    return -1;
}

fn utf8Data(comptime bytes: []const u8) T.Utf8Data {
    var ud = std.mem.zeroes(T.Utf8Data);
    inline for (bytes, 0..) |byte, idx| ud.data[idx] = byte;
    ud.size = @intCast(bytes.len);
    ud.width = if (bytes.len == 0) 0 else 1;
    return ud;
}

fn makeClient(flags: u64) struct {
    env: *T.Environ,
    client: T.Client,
} {
    const env = env_mod.environ_create();
    const client = T.Client{
        .environ = env,
        .tty = undefined,
        .status = .{},
        .flags = flags,
    };
    return .{ .env = env, .client = client };
}

test "tty_acs_get returns unicode line drawing when utf8 is usable" {
    try std.testing.expectEqualStrings("\xe2\x94\x80", tty_acs_get(null, 'q').?);

    var owned = makeClient(T.CLIENT_UTF8);
    defer env_mod.environ_free(owned.env);

    owned.client.tty = .{ .client = &owned.client };
    try std.testing.expectEqualStrings("\xe2\x94\x82", tty_acs_get(&owned.client.tty, 'x').?);
    try std.testing.expect(!tty_acs_needed(&owned.client.tty));
}

test "tty_acs_get falls back to tty ACS table when U8 disables utf8 drawing" {
    var caps = [_][]u8{
        @constCast("U8=0"),
        @constCast("acsc=q-"),
    };
    var owned = makeClient(T.CLIENT_UTF8);
    defer env_mod.environ_free(owned.env);

    owned.client.tty = .{ .client = &owned.client };
    owned.client.term_caps = caps[0..];

    try std.testing.expect(tty_acs_needed(&owned.client.tty));
    try std.testing.expectEqualStrings("-", tty_acs_get(&owned.client.tty, 'q').?);
    try std.testing.expect(tty_acs_get(&owned.client.tty, 'x') == null);
}

test "tty_acs_reverse_get accepts single, heavy, and double line variants" {
    try std.testing.expectEqual(@as(i32, 'q'), tty_acs_reverse_get("\xe2\x94\x80"));
    try std.testing.expectEqual(@as(i32, 'x'), tty_acs_reverse_get("\xe2\x94\x83"));
    try std.testing.expectEqual(@as(i32, 'n'), tty_acs_reverse_get("\xe2\x95\xac"));
    try std.testing.expectEqual(@as(i32, '~'), tty_acs_reverse_get("\xc2\xb7"));
    try std.testing.expectEqual(@as(i32, -1), tty_acs_reverse_get("abc\x00"[0..4]));
}

test "tty_acs border helpers expose the tmux border glyph tables" {
    const double = tty_acs_double_borders(CELL_TOPLEFT);
    const heavy = tty_acs_heavy_borders(CELL_RIGHTJOIN);
    const rounded = tty_acs_rounded_borders(CELL_BOTTOMRIGHT);

    try std.testing.expectEqualStrings("\xe2\x95\x94", double.data[0..double.size]);
    try std.testing.expectEqualStrings("\xe2\x94\xab", heavy.data[0..heavy.size]);
    try std.testing.expectEqualStrings("\xe2\x95\xaf", rounded.data[0..rounded.size]);
    try std.testing.expectEqual(@as(u8, 1), rounded.width);
}
