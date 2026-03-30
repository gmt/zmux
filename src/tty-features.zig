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
const env_mod = @import("environ.zig");
const log = @import("log.zig");
const tty_term_mod = @import("tty-term.zig");

/// Mirrors tmux TERM_* flags merged by tty_apply_features.
pub const TERM_256COLOURS: i32 = 0x1;
pub const TERM_RGBCOLOURS: i32 = 0x10;
pub const TERM_DECSLRM: i32 = 0x4;
pub const TERM_DECFRA: i32 = 0x8;
pub const TERM_SIXEL: i32 = 0x40;

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

const base_modern_xterm = "256,RGB,bpaste,clipboard,mouse,strikethrough,title";

const default_terminals = [_]struct {
    name: []const u8,
    version: u32 = 0,
    features: []const u8,
}{
    .{ .name = "mintty", .features = base_modern_xterm ++ ",ccolour,cstyle,extkeys,margins,overline,usstyle" },
    .{ .name = "tmux", .features = base_modern_xterm ++ ",ccolour,cstyle,focus,overline,usstyle,hyperlinks" },
    .{ .name = "rxvt-unicode", .features = "256,bpaste,ccolour,cstyle,mouse,title,ignorefkeys" },
    .{ .name = "iTerm2", .features = base_modern_xterm ++ ",cstyle,extkeys,margins,usstyle,sync,osc7,hyperlinks" },
    .{ .name = "foot", .features = base_modern_xterm ++ ",cstyle,extkeys" },
    .{ .name = "XTerm", .features = base_modern_xterm ++ ",ccolour,cstyle,extkeys,focus" },
};

const empty_capabilities = [_][]const u8{};
const tty_feature_title_capabilities = [_][]const u8{ "tsl=\x1b]0;", "fsl=\x07" };
const tty_feature_osc7_capabilities = [_][]const u8{ "Swd=\x1b]7;", "fsl=\x07" };
const tty_feature_mouse_capabilities = [_][]const u8{"kmous=\x1b[M"};
const tty_feature_clipboard_capabilities = [_][]const u8{"Ms=\x1b]52;%p1%s;%p2%s\x07"};
const tty_feature_hyperlinks_capabilities = [_][]const u8{"*:Hls=\x1b]8;%?%p1%l%tid=%p1%s%;;%p2%s\x1b\\"};
const tty_feature_rgb_capabilities = [_][]const u8{
    "AX",
    "setrgbf=\x1b[38;2;%p1%d;%p2%d;%p3%dm",
    "setrgbb=\x1b[48;2;%p1%d;%p2%d;%p3%dm",
    "setab=\x1b[%?%p1%{8}%<%t4%p1%d%e%p1%{16}%<%t10%p1%{8}%-%d%e48;5;%p1%d%;m",
    "setaf=\x1b[%?%p1%{8}%<%t3%p1%d%e%p1%{16}%<%t9%p1%{8}%-%d%e38;5;%p1%d%;m",
};
const tty_feature_256_capabilities = [_][]const u8{
    "AX",
    "setab=\x1b[%?%p1%{8}%<%t4%p1%d%e%p1%{16}%<%t10%p1%{8}%-%d%e48;5;%p1%d%;m",
    "setaf=\x1b[%?%p1%{8}%<%t3%p1%d%e%p1%{16}%<%t9%p1%{8}%-%d%e38;5;%p1%d%;m",
};
const tty_feature_overline_capabilities = [_][]const u8{"Smol=\x1b[53m"};
const tty_feature_usstyle_capabilities = [_][]const u8{
    "Smulx=\x1b[4::%p1%dm",
    "Setulc=\x1b[58::2::%p1%{65536}%/%d::%p1%{256}%/%{255}%&%d::%p1%{255}%&%d%;m",
    "Setulc1=\x1b[58::5::%p1%dm",
    "ol=\x1b[59m",
};
const tty_feature_bpaste_capabilities = [_][]const u8{ "Enbp=\x1b[?2004h", "Dsbp=\x1b[?2004l" };
const tty_feature_focus_capabilities = [_][]const u8{ "Enfcs=\x1b[?1004h", "Dsfcs=\x1b[?1004l" };
const tty_feature_cstyle_capabilities = [_][]const u8{ "Ss=\x1b[%p1%d q", "Se=\x1b[2 q" };
const tty_feature_ccolour_capabilities = [_][]const u8{ "Cs=\x1b]12;%p1%s\x07", "Cr=\x1b]112\x07" };
const tty_feature_strikethrough_capabilities = [_][]const u8{"smxx=\x1b[9m"};
const tty_feature_sync_capabilities = [_][]const u8{"Sync=\x1b[?2026%?%p1%{1}%-%tl%eh%;"};
const tty_feature_extkeys_capabilities = [_][]const u8{ "Eneks=\x1b[>4;2m", "Dseks=\x1b[>4m" };
const tty_feature_margins_capabilities = [_][]const u8{
    "Enmg=\x1b[?69h",
    "Dsmg=\x1b[?69l",
    "Clmg=\x1b[s",
    "Cmg=\x1b[%i%p1%d;%p2%ds",
};
const tty_feature_rectfill_capabilities = [_][]const u8{"Rect"};
const tty_feature_ignorefkeys_capabilities = [_][]const u8{
    "kf0@",  "kf1@",  "kf2@",  "kf3@",  "kf4@",  "kf5@",  "kf6@",  "kf7@",
    "kf8@",  "kf9@",  "kf10@", "kf11@", "kf12@", "kf13@", "kf14@", "kf15@",
    "kf16@", "kf17@", "kf18@", "kf19@", "kf20@", "kf21@", "kf22@", "kf23@",
    "kf24@", "kf25@", "kf26@", "kf27@", "kf28@", "kf29@", "kf30@", "kf31@",
    "kf32@", "kf33@", "kf34@", "kf35@", "kf36@", "kf37@", "kf38@", "kf39@",
    "kf40@", "kf41@", "kf42@", "kf43@", "kf44@", "kf45@", "kf46@", "kf47@",
    "kf48@", "kf49@", "kf50@", "kf51@", "kf52@", "kf53@", "kf54@", "kf55@",
    "kf56@", "kf57@", "kf58@", "kf59@", "kf60@", "kf61@", "kf62@", "kf63@",
};
const tty_feature_sixel_capabilities = [_][]const u8{"Sxl"};

const FeatureSpec = struct {
    name: []const u8,
    feature: Feature,
    capabilities: []const []const u8,
    term_flags: i32 = 0,
};

const feature_specs = [_]FeatureSpec{
    .{ .name = "256", .feature = .@"256", .capabilities = tty_feature_256_capabilities[0..], .term_flags = TERM_256COLOURS },
    .{ .name = "bpaste", .feature = .bpaste, .capabilities = tty_feature_bpaste_capabilities[0..] },
    .{ .name = "ccolour", .feature = .ccolour, .capabilities = tty_feature_ccolour_capabilities[0..] },
    .{ .name = "clipboard", .feature = .clipboard, .capabilities = tty_feature_clipboard_capabilities[0..] },
    .{ .name = "hyperlinks", .feature = .hyperlinks, .capabilities = tty_feature_hyperlinks_capabilities[0..] },
    .{ .name = "cstyle", .feature = .cstyle, .capabilities = tty_feature_cstyle_capabilities[0..] },
    .{ .name = "extkeys", .feature = .extkeys, .capabilities = tty_feature_extkeys_capabilities[0..] },
    .{ .name = "focus", .feature = .focus, .capabilities = tty_feature_focus_capabilities[0..] },
    .{ .name = "ignorefkeys", .feature = .ignorefkeys, .capabilities = tty_feature_ignorefkeys_capabilities[0..] },
    .{ .name = "margins", .feature = .margins, .capabilities = tty_feature_margins_capabilities[0..], .term_flags = TERM_DECSLRM },
    .{ .name = "mouse", .feature = .mouse, .capabilities = tty_feature_mouse_capabilities[0..] },
    .{ .name = "osc7", .feature = .osc7, .capabilities = tty_feature_osc7_capabilities[0..] },
    .{ .name = "overline", .feature = .overline, .capabilities = tty_feature_overline_capabilities[0..] },
    .{ .name = "rectfill", .feature = .rectfill, .capabilities = tty_feature_rectfill_capabilities[0..], .term_flags = TERM_DECFRA },
    .{ .name = "rgb", .feature = .rgb, .capabilities = tty_feature_rgb_capabilities[0..], .term_flags = TERM_256COLOURS | TERM_RGBCOLOURS },
    .{ .name = "sixel", .feature = .sixel, .capabilities = tty_feature_sixel_capabilities[0..], .term_flags = TERM_SIXEL },
    .{ .name = "strikethrough", .feature = .strikethrough, .capabilities = tty_feature_strikethrough_capabilities[0..] },
    .{ .name = "sync", .feature = .sync, .capabilities = tty_feature_sync_capabilities[0..] },
    .{ .name = "title", .feature = .title, .capabilities = tty_feature_title_capabilities[0..] },
    .{ .name = "usstyle", .feature = .usstyle, .capabilities = tty_feature_usstyle_capabilities[0..] },
};

pub fn featureBit(feature: Feature) i32 {
    return @as(i32, 1) << @as(std.math.Log2Int(i32), @intCast(@intFromEnum(feature)));
}

fn featureName(f: Feature) []const u8 {
    for (feature_specs) |spec| {
        if (spec.feature == f) return spec.name;
    }
    unreachable;
}

/// Parse a comma-/separator-delimited feature list into a feature bitset (tmux tty_add_features).
pub fn tty_add_features(bits: *i32, spec: []const u8, separators: []const u8) void {
    log.log_debug("adding terminal features {s}", .{spec});
    var it = std.mem.splitAny(u8, spec, separators);
    while (it.next()) |token| {
        const feature = featureByName(token) orelse {
            log.log_debug("unknown terminal feature: {s}", .{token});
            break;
        };
        const bit = featureBit(feature);
        if ((bits.* & bit) == 0) {
            log.log_debug("adding terminal feature: {s}", .{featureName(feature)});
            bits.* |= bit;
        }
    }
}

pub fn addFeatures(bits: *i32, spec: []const u8, separators: []const u8) void {
    tty_add_features(bits, spec, separators);
}

/// Comma-separated enabled feature names in tmux tty_features[] order (tmux tty_get_features).
threadlocal var tty_get_features_buffer: [512]u8 = undefined;

pub fn tty_get_features(feat: i32) [:0]const u8 {
    var len: usize = 0;
    for (feature_specs) |spec| {
        if ((feat & featureBit(spec.feature)) == 0) continue;
        if (len != 0) {
            if (len + 1 >= tty_get_features_buffer.len) break;
            tty_get_features_buffer[len] = ',';
            len += 1;
        }
        if (len + spec.name.len >= tty_get_features_buffer.len) break;
        @memcpy(tty_get_features_buffer[len .. len + spec.name.len], spec.name);
        len += spec.name.len;
    }
    tty_get_features_buffer[len] = 0;
    return tty_get_features_buffer[0..len :0];
}

/// Merge synthetic capabilities and term flags for requested features (tmux tty_apply_features).
/// Returns 1 if `applied_features` changed, 0 if already satisfied.
pub fn tty_apply_features(term: *tty_term_mod.TtyTerm, feat: i32) i32 {
    if (feat == 0) return 0;
    log.log_debug("applying terminal features: {s}", .{tty_get_features(feat)});

    for (feature_specs) |spec| {
        const bit = featureBit(spec.feature);
        if ((term.applied_features & bit) != 0) continue;
        if ((feat & bit) == 0) continue;

        log.log_debug("applying terminal feature: {s}", .{spec.name});
        for (spec.capabilities) |cap| {
            log.log_debug("adding capability: {s}", .{cap});
            term.tty_term_apply(cap, true);
        }
        term.term_flags |= spec.term_flags;
    }

    if ((term.applied_features | feat) == term.applied_features)
        return 0;
    term.applied_features |= feat;
    return 1;
}

pub fn featureString(alloc: std.mem.Allocator, bits: i32) []u8 {
    var out: std.ArrayList(u8) = .{};
    errdefer out.deinit(alloc);

    for (feature_specs) |spec| {
        if ((bits & featureBit(spec.feature)) == 0) continue;
        if (out.items.len != 0) out.append(alloc, ',') catch unreachable;
        out.appendSlice(alloc, spec.name) catch unreachable;
    }

    return out.toOwnedSlice(alloc) catch unreachable;
}

pub fn defaultFeatures(bits: *i32, name: []const u8, version: u32) void {
    for (default_terminals) |entry| {
        if (!std.mem.eql(u8, entry.name, name)) continue;
        if (version != 0 and version < entry.version) continue;
        tty_add_features(bits, entry.features, ",");
    }
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

pub fn hasCapability(cl: *const T.Client, name: []const u8) bool {
    if (recordedCapabilityPresent(cl, name)) return true;

    const features = effectiveFeatures(cl) orelse return false;
    for (feature_specs) |spec| {
        if ((features & featureBit(spec.feature)) == 0) continue;
        for (spec.capabilities) |entry| {
            const parsed = parseCapabilityEntry(entry);
            if (std.mem.eql(u8, parsed.name, name))
                return true;
        }
    }
    return false;
}

pub fn stringCapability(cl: *const T.Client, name: []const u8) ?[]const u8 {
    if (recordedCapabilityValue(cl, name)) |value| return value;

    const features = effectiveFeatures(cl) orelse return null;
    for (feature_specs) |spec| {
        if ((features & featureBit(spec.feature)) == 0) continue;
        for (spec.capabilities) |entry| {
            const parsed = parseCapabilityEntry(entry);
            if (std.mem.eql(u8, parsed.name, name))
                return parsed.value;
        }
    }
    return null;
}

fn inferredFeatures(cl: *const T.Client) i32 {
    var features: i32 = 0;
    for (feature_specs) |spec| {
        if (featureProvidedByRecordedCaps(cl, spec))
            features |= featureBit(spec.feature);
    }
    return features;
}

fn featureByName(name: []const u8) ?Feature {
    for (feature_specs) |spec| {
        if (std.ascii.eqlIgnoreCase(spec.name, name))
            return spec.feature;
    }
    return null;
}

fn recordedCapabilityPresent(cl: *const T.Client, name: []const u8) bool {
    const caps = cl.term_caps orelse return false;
    for (caps) |cap| {
        const parsed = parseCapabilityEntry(cap);
        if (std.mem.eql(u8, parsed.name, name))
            return true;
    }
    return false;
}

fn recordedCapabilityValue(cl: *const T.Client, name: []const u8) ?[]const u8 {
    const caps = cl.term_caps orelse return null;
    for (caps) |cap| {
        const parsed = parseCapabilityEntry(cap);
        if (std.mem.eql(u8, parsed.name, name))
            return parsed.value;
    }
    return null;
}

fn featureProvidedByRecordedCaps(cl: *const T.Client, spec: FeatureSpec) bool {
    if (spec.feature == .ignorefkeys or spec.capabilities.len == 0)
        return false;
    for (spec.capabilities) |entry| {
        const parsed = parseCapabilityEntry(entry);
        if (!recordedCapabilityPresent(cl, parsed.name))
            return false;
    }
    return true;
}

const ParsedCapability = struct {
    name: []const u8,
    value: ?[]const u8,
};

fn parseCapabilityEntry(entry: []const u8) ParsedCapability {
    const body = if (std.mem.startsWith(u8, entry, "*:")) entry[2..] else entry;
    if (std.mem.indexOfScalar(u8, body, '=')) |eq|
        return .{ .name = body[0..eq], .value = body[eq + 1 ..] };
    if (std.mem.indexOfScalar(u8, body, '@')) |at|
        return .{ .name = body[0..at], .value = null };
    return .{ .name = body, .value = null };
}

fn mask(features: []const Feature) i32 {
    var value: i32 = 0;
    for (features) |feature| value |= featureBit(feature);
    return value;
}

test "tty_features parses tmux-style feature lists into explicit bits" {
    var features: i32 = 0;
    addFeatures(&features, "bpaste,focus:RGB,title", ":,");

    try std.testing.expectEqual(
        mask(&.{ .bpaste, .focus, .rgb, .title }),
        features,
    );
}

test "tty_features renders enabled feature names in tmux order" {
    const rendered = featureString(
        std.testing.allocator,
        mask(&.{ .@"256", .bpaste, .title }),
    );
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings("256,bpaste,title", rendered);
}

test "tty_get_features matches tty_features render order" {
    const bits = mask(&.{ .@"256", .bpaste, .title });
    try std.testing.expectEqualStrings("256,bpaste,title", tty_get_features(bits));
}

test "tty_apply_features merges capabilities and term flags" {
    var term = tty_term_mod.TtyTerm.init();
    defer term.deinit();

    const rgb_feat = featureBit(.rgb);
    try std.testing.expectEqual(@as(i32, 1), tty_apply_features(&term, rgb_feat));
    try std.testing.expect(term.has(.AX));
    try std.testing.expect((term.term_flags & (TERM_256COLOURS | TERM_RGBCOLOURS)) == (TERM_256COLOURS | TERM_RGBCOLOURS));
    try std.testing.expectEqual(@as(i32, 0), tty_apply_features(&term, rgb_feat));
}

test "loaded reduced terminfo drives outer tty feature truth" {
    var caps = [_][]u8{
        @constCast("kmous=\x1b[M"),
        @constCast("Enbp=\x1b[?2004h"),
        @constCast("Dsbp=\x1b[?2004l"),
        @constCast("Enfcs=\x1b[?1004h"),
        @constCast("Dsfcs=\x1b[?1004l"),
        @constCast("Ms=\x1b]52;%p1%s;%p2%s\x07"),
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
    try std.testing.expect(supportsClient(&client, .clipboard));
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

test "feature bits synthesize tty capability strings" {
    var client = T.Client{
        .environ = undefined,
        .tty = undefined,
        .status = .{ .screen = undefined },
        .term_features = featureBit(.title) | featureBit(.focus) | featureBit(.clipboard),
    };

    try std.testing.expect(hasCapability(&client, "tsl"));
    try std.testing.expect(hasCapability(&client, "Enfcs"));
    try std.testing.expect(hasCapability(&client, "Ms"));
    try std.testing.expectEqualStrings("\x1b]0;", stringCapability(&client, "tsl").?);
    try std.testing.expectEqualStrings("\x1b[?1004l", stringCapability(&client, "Dsfcs").?);
    try std.testing.expectEqualStrings("\x1b]52;%p1%s;%p2%s\x07", stringCapability(&client, "Ms").?);
}

test "tty_default_features matches tmux terminal presets" {
    var features: i32 = 0;
    defaultFeatures(&features, "iTerm2", 0);

    try std.testing.expect((features & featureBit(.@"256")) != 0);
    try std.testing.expect((features & featureBit(.rgb)) != 0);
    try std.testing.expect((features & featureBit(.clipboard)) != 0);
    try std.testing.expect((features & featureBit(.sync)) != 0);
    try std.testing.expect((features & featureBit(.osc7)) != 0);
    try std.testing.expect((features & featureBit(.title)) != 0);
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

test "COLORTERM is not treated as a tty-features default" {
    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);
    env_mod.environ_set(env, "COLORTERM", 0, "truecolor");

    var client = T.Client{
        .environ = env,
        .tty = undefined,
        .status = .{ .screen = undefined },
    };

    try std.testing.expect(effectiveFeatures(&client) == null);
}
