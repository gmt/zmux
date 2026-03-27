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
// Ported from tmux/utf8-combined.c.
// Original copyright:
//   Copyright (c) 2023 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

const std = @import("std");
const T = @import("types.zig");

const HangulJamoSubclass = enum(u8) {
    not_hanguljamo,
    choseong,
    old_choseong,
    choseong_filler,
    jungseong_filler,
    jungseong,
    old_jungseong,
    jongseong,
    old_jongseong,
    extended_old_choseong,
    extended_old_jungseong,
    extended_old_jongseong,
};

const HangulJamoClass = enum(u8) {
    not_hanguljamo,
    choseong,
    jungseong,
    jongseong,
};

pub fn utf8_has_zwj(ud: *const T.Utf8Data) bool {
    if (ud.size < 3) return false;
    return std.mem.eql(u8, ud.data[ud.size - 3 .. ud.size], &.{ 0xe2, 0x80, 0x8d });
}

pub fn utf8_is_zwj(ud: *const T.Utf8Data) bool {
    if (ud.size != 3) return false;
    return std.mem.eql(u8, ud.data[0..3], &.{ 0xe2, 0x80, 0x8d });
}

pub fn utf8_is_vs(ud: *const T.Utf8Data) bool {
    if (ud.size != 3) return false;
    return std.mem.eql(u8, ud.data[0..3], &.{ 0xef, 0xb8, 0x8f });
}

pub fn utf8_is_hangul_filler(ud: *const T.Utf8Data) bool {
    if (ud.size != 3) return false;
    return std.mem.eql(u8, ud.data[0..3], &.{ 0xe3, 0x85, 0xa4 });
}

pub fn utf8_should_combine(with: *const T.Utf8Data, add: *const T.Utf8Data) bool {
    const w = utf8ToCodepoint(with) orelse return false;
    const a = utf8ToCodepoint(add) orelse return false;

    if (isRegionalIndicator(a) and isRegionalIndicator(w)) return true;

    switch (a) {
        0x1F44B,
        0x1F44C,
        0x1F44D,
        0x1F44E,
        0x1F44F,
        0x1F450,
        0x1F466,
        0x1F467,
        0x1F468,
        0x1F469,
        0x1F46E,
        0x1F470,
        0x1F471,
        0x1F472,
        0x1F473,
        0x1F474,
        0x1F475,
        0x1F476,
        0x1F477,
        0x1F478,
        0x1F47C,
        0x1F481,
        0x1F482,
        0x1F483,
        0x1F485,
        0x1F486,
        0x1F487,
        0x1F4AA,
        0x1F575,
        0x1F57A,
        0x1F590,
        0x1F595,
        0x1F596,
        0x1F645,
        0x1F646,
        0x1F647,
        0x1F64B,
        0x1F64C,
        0x1F64D,
        0x1F64E,
        0x1F64F,
        0x1F6B4,
        0x1F6B5,
        0x1F6B6,
        0x1F926,
        0x1F937,
        0x1F938,
        0x1F939,
        0x1F93D,
        0x1F93E,
        0x1F9B5,
        0x1F9B6,
        0x1F9B8,
        0x1F9B9,
        0x1F9CD,
        0x1F9CE,
        0x1F9CF,
        0x1F9D1,
        0x1F9D2,
        0x1F9D3,
        0x1F9D4,
        0x1F9D5,
        0x1F9D6,
        0x1F9D7,
        0x1F9D8,
        0x1F9D9,
        0x1F9DA,
        0x1F9DB,
        0x1F9DC,
        0x1F9DD,
        0x1F9DE,
        0x1F9DF,
        => return w >= 0x1F3FB and w <= 0x1F3FF,
        else => return false,
    }
}

pub fn hanguljamo_check_state(previous: *const T.Utf8Data, ud: *const T.Utf8Data) T.HangulJamoState {
    if (ud.size != 3) return .not_hanguljamo;

    switch (hanguljamo_get_class(ud.data[0..3])) {
        .choseong => return .choseong,
        .jungseong => {
            if (previous.size < 3) return .not_composable;
            if (hanguljamo_get_class(previous.data[previous.size - 3 .. previous.size]) == .choseong)
                return .composable;
            return .not_composable;
        },
        .jongseong => {
            if (previous.size < 3) return .not_composable;
            if (hanguljamo_get_class(previous.data[previous.size - 3 .. previous.size]) == .jungseong)
                return .composable;
            return .not_composable;
        },
        .not_hanguljamo => return .not_hanguljamo,
    }
}

fn utf8ToCodepoint(ud: *const T.Utf8Data) ?u21 {
    if (ud.size == 0 or ud.size > 4 or ud.size > T.UTF8_SIZE) return null;
    const expected = std.unicode.utf8ByteSequenceLength(ud.data[0]) catch return null;
    if (ud.size != expected) return null;
    return std.unicode.utf8Decode(ud.data[0..ud.size]) catch null;
}

fn isRegionalIndicator(cp: u21) bool {
    return cp >= 0x1F1E6 and cp <= 0x1F1FF;
}

fn hanguljamo_get_subclass(s: []const u8) HangulJamoSubclass {
    std.debug.assert(s.len == 3);

    switch (s[0]) {
        0xe1 => switch (s[1]) {
            0x84 => {
                if (s[2] >= 0x80 and s[2] <= 0x92) return .choseong;
                if (s[2] >= 0x93 and s[2] <= 0xbf) return .old_choseong;
            },
            0x85 => {
                if (s[2] == 0x9f) return .choseong_filler;
                if (s[2] == 0xa0) return .jungseong_filler;
                if (s[2] >= 0x80 and s[2] <= 0x9e) return .old_choseong;
                if (s[2] >= 0xa1 and s[2] <= 0xb5) return .jungseong;
                if (s[2] >= 0xb6 and s[2] <= 0xbf) return .old_jungseong;
            },
            0x86 => {
                if (s[2] >= 0x80 and s[2] <= 0xa7) return .old_jungseong;
                if (s[2] >= 0xa8 and s[2] <= 0xbf) return .jongseong;
            },
            0x87 => {
                if (s[2] >= 0x80 and s[2] <= 0x82) return .jongseong;
                if (s[2] >= 0x83 and s[2] <= 0xbf) return .old_jongseong;
            },
            else => {},
        },
        0xea => {
            if (s[1] == 0xa5 and s[2] >= 0xa0 and s[2] <= 0xbc) return .extended_old_choseong;
        },
        0xed => {
            if (s[1] == 0x9e and s[2] >= 0xb0 and s[2] <= 0xbf) return .extended_old_jungseong;
            if (s[1] != 0x9f) return .not_hanguljamo;
            if (s[2] >= 0x80 and s[2] <= 0x86) return .extended_old_jungseong;
            if (s[2] >= 0x8b and s[2] <= 0xbb) return .extended_old_jongseong;
        },
        else => {},
    }

    return .not_hanguljamo;
}

fn hanguljamo_get_class(s: []const u8) HangulJamoClass {
    return switch (hanguljamo_get_subclass(s)) {
        .choseong, .choseong_filler, .old_choseong, .extended_old_choseong => .choseong,
        .jungseong, .jungseong_filler, .old_jungseong, .extended_old_jungseong => .jungseong,
        .jongseong, .old_jongseong, .extended_old_jongseong => .jongseong,
        .not_hanguljamo => .not_hanguljamo,
    };
}

fn makeUtf8Data(bytes: []const u8) T.Utf8Data {
    var ud = std.mem.zeroes(T.Utf8Data);
    std.debug.assert(bytes.len <= T.UTF8_SIZE);
    @memcpy(ud.data[0..bytes.len], bytes);
    ud.size = @intCast(bytes.len);
    ud.have = ud.size;
    return ud;
}

test "utf8 combined detects zwj variation selector and hangul filler" {
    const zwj = makeUtf8Data(&.{ 0xe2, 0x80, 0x8d });
    const vs = makeUtf8Data(&.{ 0xef, 0xb8, 0x8f });
    const filler = makeUtf8Data(&.{ 0xe3, 0x85, 0xa4 });
    const family = makeUtf8Data(&.{ 0xf0, 0x9f, 0x91, 0xa9, 0xe2, 0x80, 0x8d });

    try std.testing.expect(utf8_is_zwj(&zwj));
    try std.testing.expect(utf8_has_zwj(&family));
    try std.testing.expect(utf8_is_vs(&vs));
    try std.testing.expect(utf8_is_hangul_filler(&filler));
}

test "utf8 combined handles regional indicators and skin tone modifiers" {
    const regional_a = makeUtf8Data(&.{ 0xf0, 0x9f, 0x87, 0xa6 });
    const regional_b = makeUtf8Data(&.{ 0xf0, 0x9f, 0x87, 0xa7 });
    const tone = makeUtf8Data(&.{ 0xf0, 0x9f, 0x8f, 0xbb });
    const wave = makeUtf8Data(&.{ 0xf0, 0x9f, 0x91, 0x8b });
    var combined_wave = makeUtf8Data(&.{ 0xf0, 0x9f, 0x91, 0x8b, 0xf0, 0x9f, 0x8f, 0xbb });
    combined_wave.width = 2;

    try std.testing.expect(utf8_should_combine(&regional_a, &regional_b));
    try std.testing.expect(utf8_should_combine(&tone, &wave));
    try std.testing.expect(!utf8_should_combine(&wave, &tone));
    try std.testing.expect(!utf8_should_combine(&combined_wave, &regional_b));
}

test "utf8 combined classifies hangul jamo composition state" {
    const ascii = makeUtf8Data("A");
    const choseong = makeUtf8Data(&.{ 0xe1, 0x84, 0x80 });
    const jungseong = makeUtf8Data(&.{ 0xe1, 0x85, 0xa1 });
    const jongseong = makeUtf8Data(&.{ 0xe1, 0x86, 0xa8 });
    const ext_old_choseong = makeUtf8Data(&.{ 0xea, 0xa5, 0xa0 });
    const ext_old_jungseong = makeUtf8Data(&.{ 0xed, 0x9e, 0xb0 });
    const ext_old_jongseong = makeUtf8Data(&.{ 0xed, 0x9f, 0x8b });

    try std.testing.expectEqual(T.HangulJamoState.not_hanguljamo, hanguljamo_check_state(&ascii, &ascii));
    try std.testing.expectEqual(T.HangulJamoState.choseong, hanguljamo_check_state(&ascii, &choseong));
    try std.testing.expectEqual(T.HangulJamoState.composable, hanguljamo_check_state(&choseong, &jungseong));
    try std.testing.expectEqual(T.HangulJamoState.composable, hanguljamo_check_state(&jungseong, &jongseong));
    try std.testing.expectEqual(T.HangulJamoState.not_composable, hanguljamo_check_state(&ascii, &jungseong));
    try std.testing.expectEqual(T.HangulJamoState.not_composable, hanguljamo_check_state(&choseong, &jongseong));
    try std.testing.expectEqual(T.HangulJamoState.choseong, hanguljamo_check_state(&ascii, &ext_old_choseong));
    try std.testing.expectEqual(T.HangulJamoState.composable, hanguljamo_check_state(&choseong, &ext_old_jungseong));
    try std.testing.expectEqual(T.HangulJamoState.composable, hanguljamo_check_state(&jungseong, &ext_old_jongseong));
}
