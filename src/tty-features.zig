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
// Written for zmux by Greg Turner. This file is new zmux runtime work that
// keeps reduced tty capability decisions out of higher-level redraw code.

//! tty-features.zig – reduced terminal feature inference for outer tty policy.

const std = @import("std");
const T = @import("types.zig");

pub const Feature = enum(u5) {
    @"256",
    bpaste,
    ccolour,
    clipboard,
    hyperlinks,
    cstyle,
    extkeys,
    focus,
    ignorefkeys,
    margins,
    mouse,
    osc7,
    overline,
    rectfill,
    rgb,
    sixel,
    strikethrough,
    sync,
    title,
    usstyle,
};

pub fn featureBit(feature: Feature) i32 {
    return @as(i32, 1) << @as(std.math.Log2Int(i32), @intCast(@intFromEnum(feature)));
}

pub fn supportsClient(cl: *const T.Client, feature: Feature) bool {
    const features = effectiveFeatures(cl) orelse return true;
    return (features & featureBit(feature)) != 0;
}

pub fn supportsTty(tty: *const T.Tty, feature: Feature) bool {
    return supportsClient(tty.client, feature);
}

pub fn effectiveFeatures(cl: *const T.Client) ?i32 {
    var features: i32 = cl.term_features;
    if (cl.term_name) |term_name| {
        features |= inferredFeatures(term_name);
        return features;
    }
    return if (features != 0) features else null;
}

fn inferredFeatures(term_name: []const u8) i32 {
    if (!isLikelyModernTerm(term_name)) return 0;

    var features = mask(&.{ .bpaste, .mouse, .title });
    if (supportsFocusByDefault(term_name))
        features |= featureBit(.focus);
    return features;
}

fn mask(features: []const Feature) i32 {
    var value: i32 = 0;
    for (features) |feature| value |= featureBit(feature);
    return value;
}

fn isLikelyModernTerm(term_name: []const u8) bool {
    return containsIgnoreCase(term_name, "xterm") or
        containsIgnoreCase(term_name, "screen") or
        containsIgnoreCase(term_name, "tmux") or
        containsIgnoreCase(term_name, "rxvt") or
        containsIgnoreCase(term_name, "foot") or
        containsIgnoreCase(term_name, "kitty") or
        containsIgnoreCase(term_name, "wezterm") or
        containsIgnoreCase(term_name, "alacritty") or
        containsIgnoreCase(term_name, "ghostty") or
        containsIgnoreCase(term_name, "iterm") or
        containsIgnoreCase(term_name, "mintty") or
        containsIgnoreCase(term_name, "st");
}

fn supportsFocusByDefault(term_name: []const u8) bool {
    return containsIgnoreCase(term_name, "tmux") or
        containsIgnoreCase(term_name, "xterm") or
        containsIgnoreCase(term_name, "wezterm") or
        containsIgnoreCase(term_name, "kitty") or
        containsIgnoreCase(term_name, "ghostty") or
        containsIgnoreCase(term_name, "alacritty");
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;

    var start: usize = 0;
    while (start + needle.len <= haystack.len) : (start += 1) {
        var matched = true;
        for (needle, 0..) |needle_ch, offset| {
            if (std.ascii.toLower(haystack[start + offset]) != std.ascii.toLower(needle_ch)) {
                matched = false;
                break;
            }
        }
        if (matched) return true;
    }
    return false;
}

test "known modern terminals infer reduced mouse, bracketed paste, and title support" {
    var client = T.Client{
        .environ = undefined,
        .tty = undefined,
        .status = .{ .screen = undefined },
        .term_name = @constCast("xterm-256color"),
    };
    try std.testing.expect(supportsClient(&client, .mouse));
    try std.testing.expect(supportsClient(&client, .bpaste));
    try std.testing.expect(supportsClient(&client, .title));
    try std.testing.expect(supportsClient(&client, .focus));
}

test "explicit client feature bits augment reduced term inference" {
    var client = T.Client{
        .environ = undefined,
        .tty = undefined,
        .status = .{ .screen = undefined },
        .term_name = @constCast("dumb"),
        .term_features = featureBit(.bpaste) | featureBit(.mouse),
    };
    try std.testing.expect(supportsClient(&client, .mouse));
    try std.testing.expect(supportsClient(&client, .bpaste));
    try std.testing.expect(!supportsClient(&client, .title));
}

test "missing capability context preserves the legacy always-emit fallback" {
    var client = T.Client{
        .environ = undefined,
        .tty = undefined,
        .status = .{ .screen = undefined },
    };
    try std.testing.expect(supportsClient(&client, .mouse));
    try std.testing.expect(supportsClient(&client, .bpaste));
    try std.testing.expect(supportsClient(&client, .title));
}
