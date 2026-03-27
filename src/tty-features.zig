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
const tty_term = @import("tty-term.zig");

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
    if (cl.term_caps != null) {
        features |= inferredFeatures(cl);
        return features;
    }
    return if (features != 0) features else null;
}

fn inferredFeatures(cl: *const T.Client) i32 {
    var tty = T.Tty{ .client = @constCast(cl) };
    var features: i32 = 0;
    if (tty_term.hasCapability(&tty, "kmous"))
        features |= featureBit(.mouse);
    if (tty_term.hasCapability(&tty, "Enbp") and tty_term.hasCapability(&tty, "Dsbp"))
        features |= featureBit(.bpaste);
    if (tty_term.hasCapability(&tty, "Enfcs") and tty_term.hasCapability(&tty, "Dsfcs"))
        features |= featureBit(.focus);
    if (tty_term.hasCapability(&tty, "tsl") and tty_term.hasCapability(&tty, "fsl"))
        features |= featureBit(.title);
    return features;
}

fn mask(features: []const Feature) i32 {
    var value: i32 = 0;
    for (features) |feature| value |= featureBit(feature);
    return value;
}

test "loaded reduced terminfo drives outer tty feature truth" {
    var caps = [_][]u8{
        @constCast("kmous=\x1b[M"),
        @constCast("Enbp=\x1b[?2004h"),
        @constCast("Dsbp=\x1b[?2004l"),
        @constCast("Enfcs=\x1b[?1004h"),
        @constCast("Dsfcs=\x1b[?1004l"),
        @constCast("tsl=\x1b]0;"),
        @constCast("fsl=\x07"),
    };
    var client = T.Client{
        .environ = undefined,
        .tty = undefined,
        .status = .{ .screen = undefined },
        .term_caps = caps[0..],
    };
    try std.testing.expect(supportsClient(&client, .mouse));
    try std.testing.expect(supportsClient(&client, .bpaste));
    try std.testing.expect(supportsClient(&client, .title));
    try std.testing.expect(supportsClient(&client, .focus));
}

test "explicit client feature bits augment reduced terminfo truth" {
    var caps = [_][]u8{ @constCast("tsl=\x1b]0;"), @constCast("fsl=\x07") };
    var client = T.Client{
        .environ = undefined,
        .tty = undefined,
        .status = .{ .screen = undefined },
        .term_caps = caps[0..],
        .term_features = featureBit(.bpaste) | featureBit(.mouse),
    };
    try std.testing.expect(supportsClient(&client, .mouse));
    try std.testing.expect(supportsClient(&client, .bpaste));
    try std.testing.expect(supportsClient(&client, .title));
}

test "empty reduced terminfo disables unsupported outer modes" {
    var client = T.Client{
        .environ = undefined,
        .tty = undefined,
        .status = .{ .screen = undefined },
        .term_caps = &.{},
    };
    try std.testing.expect(!supportsClient(&client, .mouse));
    try std.testing.expect(!supportsClient(&client, .bpaste));
    try std.testing.expect(!supportsClient(&client, .title));
}

test "missing capability context preserves the legacy always-emit fallback" {
    var client = T.Client{
        .environ = undefined,
        .tty = undefined,
        .status = .{ .screen = undefined },
    };
    try std.testing.expect(supportsClient(&client, .mouse));
}
