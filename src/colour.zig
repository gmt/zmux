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
// Ported in part from tmux/colour.c.
// Original copyright:
//   Copyright (c) 2008 Nicholas Marriott <nicholas.marriott@gmail.com>
//   Copyright (c) 2016 Avi Halachmi <avihpit@yahoo.com>
//   ISC licence – same terms as above.

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const log = @import("log.zig");
const opts = @import("options.zig");

threadlocal var colour_buf: [32]u8 = undefined;

pub fn colour_find_rgb(r: u8, g: u8, b: u8) i32 {
    const q2c = [_]i32{ 0x00, 0x5f, 0x87, 0xaf, 0xd7, 0xff };
    const qr = colour_to_6cube(r);
    const qg = colour_to_6cube(g);
    const qb = colour_to_6cube(b);
    const cr = q2c[qr];
    const cg = q2c[qg];
    const cb = q2c[qb];

    if (cr == r and cg == g and cb == b)
        return (16 + (36 * qr) + (6 * qg) + qb) | T.COLOUR_FLAG_256;

    const grey_avg: i32 = (@as(i32, r) + @as(i32, g) + @as(i32, b)) / 3;
    const grey_idx: i32 = if (grey_avg > 238) 23 else @divTrunc(grey_avg - 3, 10);
    const grey = 8 + (10 * grey_idx);

    const cube_distance = colour_dist_sq(cr, cg, cb, r, g, b);
    const grey_distance = colour_dist_sq(grey, grey, grey, r, g, b);
    const idx: i32 = if (grey_distance < cube_distance)
        232 + grey_idx
    else
        16 + (36 * qr) + (6 * qg) + qb;
    return idx | T.COLOUR_FLAG_256;
}

pub fn colour_join_rgb(r: u8, g: u8, b: u8) i32 {
    return (@as(i32, r) << 16) | (@as(i32, g) << 8) | @as(i32, b) | T.COLOUR_FLAG_RGB;
}

pub fn colour_split_rgb(c: i32, r: *u8, g: *u8, b: *u8) void {
    r.* = @intCast((c >> 16) & 0xff);
    g.* = @intCast((c >> 8) & 0xff);
    b.* = @intCast(c & 0xff);
}

pub fn colour_force_rgb(c: i32) i32 {
    if (c & T.COLOUR_FLAG_RGB != 0) return c;
    if (c & T.COLOUR_FLAG_256 != 0) return colour_256toRGB(c);
    if (c >= 0 and c <= 7) return colour_256toRGB(c);
    if (c >= 90 and c <= 97) return colour_256toRGB(8 + c - 90);
    return -1;
}

pub fn colour_tostring(c: i32) []const u8 {
    if (c == -1) return "none";

    if (c & T.COLOUR_FLAG_RGB != 0) {
        var r: u8 = undefined;
        var g: u8 = undefined;
        var b: u8 = undefined;
        colour_split_rgb(c, &r, &g, &b);
        return std.fmt.bufPrint(&colour_buf, "#{x:0>2}{x:0>2}{x:0>2}", .{ r, g, b }) catch "invalid";
    }

    if (c & T.COLOUR_FLAG_256 != 0)
        return std.fmt.bufPrint(&colour_buf, "colour{d}", .{c & 0xff}) catch "invalid";

    return switch (c) {
        0 => "black",
        1 => "red",
        2 => "green",
        3 => "yellow",
        4 => "blue",
        5 => "magenta",
        6 => "cyan",
        7 => "white",
        8 => "default",
        9 => "terminal",
        90 => "brightblack",
        91 => "brightred",
        92 => "brightgreen",
        93 => "brightyellow",
        94 => "brightblue",
        95 => "brightmagenta",
        96 => "brightcyan",
        97 => "brightwhite",
        else => "invalid",
    };
}

pub fn colour_totheme(c: i32) T.ClientTheme {
    if (c == -1) return .unknown;

    if (c & T.COLOUR_FLAG_RGB != 0) {
        const r = (c >> 16) & 0xff;
        const g = (c >> 8) & 0xff;
        const b = c & 0xff;
        return if (r + g + b > 382) .light else .dark;
    }

    if (c & T.COLOUR_FLAG_256 != 0)
        return colour_totheme(colour_256toRGB(c));

    return switch (c) {
        0, 90 => .dark,
        7, 97 => .light,
        else => blk: {
            if (c >= 0 and c <= 7) break :blk colour_totheme(colour_256toRGB(c));
            if (c >= 90 and c <= 97) break :blk colour_totheme(colour_256toRGB(8 + c - 90));
            break :blk .unknown;
        },
    };
}

pub fn colour_fromstring(s: []const u8) i32 {
    if (s.len == 7 and s[0] == '#') {
        const r = parse_hex_byte(s[1..3]) orelse return -1;
        const g = parse_hex_byte(s[3..5]) orelse return -1;
        const b = parse_hex_byte(s[5..7]) orelse return -1;
        return colour_join_rgb(r, g, b);
    }

    if (std.ascii.startsWithIgnoreCase(s, "colour")) {
        const n = std.fmt.parseInt(i32, s["colour".len..], 10) catch return -1;
        if (n < 0 or n > 255) return -1;
        return n | T.COLOUR_FLAG_256;
    }
    if (std.ascii.startsWithIgnoreCase(s, "color")) {
        const n = std.fmt.parseInt(i32, s["color".len..], 10) catch return -1;
        if (n < 0 or n > 255) return -1;
        return n | T.COLOUR_FLAG_256;
    }

    if (std.ascii.eqlIgnoreCase(s, "default")) return 8;
    if (std.ascii.eqlIgnoreCase(s, "terminal")) return 9;

    inline for (basic_colour_names) |entry| {
        if (std.ascii.eqlIgnoreCase(s, entry.name) or std.mem.eql(u8, s, entry.alt))
            return entry.value;
    }

    return colour_byname(s);
}

pub fn colour_256toRGB(c: i32) i32 {
    return colour_256_table[@intCast(c & 0xff)] | T.COLOUR_FLAG_RGB;
}

pub fn colour_256to16(c: i32) i32 {
    return colour_256_to_16_table[@intCast(c & 0xff)];
}

pub fn colour_byname(name: []const u8) i32 {
    if (std.ascii.startsWithIgnoreCase(name, "grey") or std.ascii.startsWithIgnoreCase(name, "gray")) {
        if (name.len == 4) return 0xbebebe | T.COLOUR_FLAG_RGB;
        const percent = std.fmt.parseInt(i32, name[4..], 10) catch return -1;
        if (percent < 0 or percent > 100) return -1;
        const c = @as(u8, @intFromFloat(@round(2.55 * @as(f64, @floatFromInt(percent)))));
        return colour_join_rgb(c, c, c);
    }

    inline for (x11_colour_names) |entry| {
        if (std.ascii.eqlIgnoreCase(name, entry.name))
            return entry.value | T.COLOUR_FLAG_RGB;
    }
    return -1;
}

pub fn colour_parseX11(p: []const u8) i32 {
    if (parse_rgb_triplet(p)) |rgb| return rgb;

    const trimmed = std.mem.trim(u8, p, " ");
    const colour = colour_byname(trimmed);
    log.log_debug("colour_parseX11: {s} = {s}", .{ trimmed, colour_tostring(colour) });
    return colour;
}

pub fn colour_palette_init(p: *T.ColourPalette) void {
    p.fg = 8;
    p.bg = 8;
    p.palette = null;
    p.default_palette = null;
}

pub fn colour_palette_clear(p: ?*T.ColourPalette) void {
    if (p) |palette| {
        palette.fg = 8;
        palette.bg = 8;
        if (palette.palette) |entries| xm.allocator.free(entries);
        palette.palette = null;
    }
}

pub fn colour_palette_free(p: ?*T.ColourPalette) void {
    if (p) |palette| {
        if (palette.palette) |entries| xm.allocator.free(entries);
        palette.palette = null;
        if (palette.default_palette) |entries| xm.allocator.free(entries);
        palette.default_palette = null;
    }
}

pub fn colour_palette_get(p: ?*T.ColourPalette, n_in: i32) i32 {
    const palette = p orelse return -1;
    var n = n_in;

    if (n >= 90 and n <= 97)
        n = 8 + n - 90
    else if (n & T.COLOUR_FLAG_256 != 0)
        n &= ~@as(i32, T.COLOUR_FLAG_256)
    else if (n >= 8)
        return -1;

    if (palette.palette) |entries| {
        if (entries[@intCast(n)] != -1) return entries[@intCast(n)];
    }
    if (palette.default_palette) |entries| {
        if (entries[@intCast(n)] != -1) return entries[@intCast(n)];
    }
    return -1;
}

pub fn colour_palette_set(p: ?*T.ColourPalette, n: i32, c: i32) bool {
    const palette = p orelse return false;
    if (n < 0 or n > 255) return false;
    if (c == -1 and palette.palette == null) return false;

    if (palette.palette == null) {
        const entries = xm.allocator.alloc(i32, 256) catch unreachable;
        @memset(entries, -1);
        palette.palette = entries;
    }
    palette.palette.?[@intCast(n)] = c;
    return true;
}

pub fn colour_palette_from_option(p: ?*T.ColourPalette, oo: *T.Options) void {
    const palette = p orelse return;
    const value = opts.options_get_only(oo, "pane-colours");
    if (value == null or value.?.* != .array or value.?.array.items.len == 0) {
        if (palette.default_palette) |entries| xm.allocator.free(entries);
        palette.default_palette = null;
        return;
    }

    if (palette.default_palette) |entries| xm.allocator.free(entries);
    const entries = xm.allocator.alloc(i32, 256) catch unreachable;
    @memset(entries, -1);

    var have_entries = false;
    for (value.?.array.items) |item| {
        const eq = std.mem.indexOfScalar(u8, item.value, '=') orelse continue;
        const raw_idx = std.mem.trim(u8, item.value[0..eq], " \t");
        const raw_colour = std.mem.trim(u8, item.value[eq + 1 ..], " \t");
        const idx = std.fmt.parseInt(u8, raw_idx, 10) catch continue;
        const parsed = colour_fromstring(raw_colour);
        if (parsed == -1) continue;
        entries[idx] = parsed;
        have_entries = true;
    }

    if (!have_entries) {
        xm.allocator.free(entries);
        palette.default_palette = null;
        return;
    }
    palette.default_palette = entries;
}

fn colour_dist_sq(R: i32, G: i32, B: i32, r: u8, g: u8, b: u8) i32 {
    const dr = R - @as(i32, r);
    const dg = G - @as(i32, g);
    const db = B - @as(i32, b);
    return (dr * dr) + (dg * dg) + (db * db);
}

fn colour_to_6cube(v: u8) i32 {
    if (v < 48) return 0;
    if (v < 114) return 1;
    return @divTrunc(@as(i32, v) - 35, 40);
}

fn parse_hex_byte(s: []const u8) ?u8 {
    if (s.len != 2) return null;
    return std.fmt.parseInt(u8, s, 16) catch null;
}

fn parse_rgb_triplet(p: []const u8) ?i32 {
    if (p.len == 7 and p[0] == '#') {
        const r = parse_hex_byte(p[1..3]) orelse return null;
        const g = parse_hex_byte(p[3..5]) orelse return null;
        const b = parse_hex_byte(p[5..7]) orelse return null;
        return colour_join_rgb(r, g, b);
    }

    if (std.ascii.startsWithIgnoreCase(p, "rgb:")) {
        const rest = p[4..];
        if (rest.len == 8 and rest[2] == '/' and rest[5] == '/') {
            const r = parse_hex_byte(rest[0..2]) orelse return null;
            const g = parse_hex_byte(rest[3..5]) orelse return null;
            const b = parse_hex_byte(rest[6..8]) orelse return null;
            return colour_join_rgb(r, g, b);
        }
        if (rest.len == 14 and rest[4] == '/' and rest[9] == '/') {
            const r16 = std.fmt.parseInt(u16, rest[0..4], 16) catch return null;
            const g16 = std.fmt.parseInt(u16, rest[5..9], 16) catch return null;
            const b16 = std.fmt.parseInt(u16, rest[10..14], 16) catch return null;
            return colour_join_rgb(@intCast(r16 >> 8), @intCast(g16 >> 8), @intCast(b16 >> 8));
        }
    }

    var it = std.mem.splitScalar(u8, p, ',');
    const a = it.next() orelse return null;
    const b = it.next() orelse return null;
    const c = it.next() orelse return null;
    if (it.next() != null) return null;

    const r = std.fmt.parseInt(u8, std.mem.trim(u8, a, " "), 10) catch return null;
    const g = std.fmt.parseInt(u8, std.mem.trim(u8, b, " "), 10) catch return null;
    const blue = std.fmt.parseInt(u8, std.mem.trim(u8, c, " "), 10) catch return null;
    return colour_join_rgb(r, g, blue);
}

const BasicColourName = struct {
    name: []const u8,
    alt: []const u8,
    value: i32,
};

const basic_colour_names = [_]BasicColourName{
    .{ .name = "black", .alt = "0", .value = 0 },
    .{ .name = "red", .alt = "1", .value = 1 },
    .{ .name = "green", .alt = "2", .value = 2 },
    .{ .name = "yellow", .alt = "3", .value = 3 },
    .{ .name = "blue", .alt = "4", .value = 4 },
    .{ .name = "magenta", .alt = "5", .value = 5 },
    .{ .name = "cyan", .alt = "6", .value = 6 },
    .{ .name = "white", .alt = "7", .value = 7 },
    .{ .name = "brightblack", .alt = "90", .value = 90 },
    .{ .name = "brightred", .alt = "91", .value = 91 },
    .{ .name = "brightgreen", .alt = "92", .value = 92 },
    .{ .name = "brightyellow", .alt = "93", .value = 93 },
    .{ .name = "brightblue", .alt = "94", .value = 94 },
    .{ .name = "brightmagenta", .alt = "95", .value = 95 },
    .{ .name = "brightcyan", .alt = "96", .value = 96 },
    .{ .name = "brightwhite", .alt = "97", .value = 97 },
};

const NamedColour = struct {
    name: []const u8,
    value: i32,
};

const x11_colour_names = [_]NamedColour{
    .{ .name = "AliceBlue", .value = 0xf0f8ff },
    .{ .name = "DarkBlue", .value = 0x00008b },
    .{ .name = "RebeccaPurple", .value = 0x663399 },
    .{ .name = "alice blue", .value = 0xf0f8ff },
    .{ .name = "aqua", .value = 0x00ffff },
    .{ .name = "black", .value = 0x000000 },
    .{ .name = "blue", .value = 0x0000ff },
    .{ .name = "cyan", .value = 0x00ffff },
    .{ .name = "fuchsia", .value = 0xff00ff },
    .{ .name = "green", .value = 0x00ff00 },
    .{ .name = "grey", .value = 0xbebebe },
    .{ .name = "gray", .value = 0xbebebe },
    .{ .name = "magenta", .value = 0xff00ff },
    .{ .name = "navy", .value = 0x000080 },
    .{ .name = "orange", .value = 0xffa500 },
    .{ .name = "purple", .value = 0xa020f0 },
    .{ .name = "red", .value = 0xff0000 },
    .{ .name = "teal", .value = 0x008080 },
    .{ .name = "white", .value = 0xffffff },
    .{ .name = "yellow", .value = 0xffff00 },
};

const colour_256_table = [_]i32{
    0x000000, 0x800000, 0x008000, 0x808000, 0x000080, 0x800080, 0x008080, 0xc0c0c0,
    0x808080, 0xff0000, 0x00ff00, 0xffff00, 0x0000ff, 0xff00ff, 0x00ffff, 0xffffff,
    0x000000, 0x00005f, 0x000087, 0x0000af, 0x0000d7, 0x0000ff, 0x005f00, 0x005f5f,
    0x005f87, 0x005faf, 0x005fd7, 0x005fff, 0x008700, 0x00875f, 0x008787, 0x0087af,
    0x0087d7, 0x0087ff, 0x00af00, 0x00af5f, 0x00af87, 0x00afaf, 0x00afd7, 0x00afff,
    0x00d700, 0x00d75f, 0x00d787, 0x00d7af, 0x00d7d7, 0x00d7ff, 0x00ff00, 0x00ff5f,
    0x00ff87, 0x00ffaf, 0x00ffd7, 0x00ffff, 0x5f0000, 0x5f005f, 0x5f0087, 0x5f00af,
    0x5f00d7, 0x5f00ff, 0x5f5f00, 0x5f5f5f, 0x5f5f87, 0x5f5faf, 0x5f5fd7, 0x5f5fff,
    0x5f8700, 0x5f875f, 0x5f8787, 0x5f87af, 0x5f87d7, 0x5f87ff, 0x5faf00, 0x5faf5f,
    0x5faf87, 0x5fafaf, 0x5fafd7, 0x5fafff, 0x5fd700, 0x5fd75f, 0x5fd787, 0x5fd7af,
    0x5fd7d7, 0x5fd7ff, 0x5fff00, 0x5fff5f, 0x5fff87, 0x5fffaf, 0x5fffd7, 0x5fffff,
    0x870000, 0x87005f, 0x870087, 0x8700af, 0x8700d7, 0x8700ff, 0x875f00, 0x875f5f,
    0x875f87, 0x875faf, 0x875fd7, 0x875fff, 0x878700, 0x87875f, 0x878787, 0x8787af,
    0x8787d7, 0x8787ff, 0x87af00, 0x87af5f, 0x87af87, 0x87afaf, 0x87afd7, 0x87afff,
    0x87d700, 0x87d75f, 0x87d787, 0x87d7af, 0x87d7d7, 0x87d7ff, 0x87ff00, 0x87ff5f,
    0x87ff87, 0x87ffaf, 0x87ffd7, 0x87ffff, 0xaf0000, 0xaf005f, 0xaf0087, 0xaf00af,
    0xaf00d7, 0xaf00ff, 0xaf5f00, 0xaf5f5f, 0xaf5f87, 0xaf5faf, 0xaf5fd7, 0xaf5fff,
    0xaf8700, 0xaf875f, 0xaf8787, 0xaf87af, 0xaf87d7, 0xaf87ff, 0xafaf00, 0xafaf5f,
    0xafaf87, 0xafafaf, 0xafafd7, 0xafafff, 0xafd700, 0xafd75f, 0xafd787, 0xafd7af,
    0xafd7d7, 0xafd7ff, 0xafff00, 0xafff5f, 0xafff87, 0xafffaf, 0xafffd7, 0xafffff,
    0xd70000, 0xd7005f, 0xd70087, 0xd700af, 0xd700d7, 0xd700ff, 0xd75f00, 0xd75f5f,
    0xd75f87, 0xd75faf, 0xd75fd7, 0xd75fff, 0xd78700, 0xd7875f, 0xd78787, 0xd787af,
    0xd787d7, 0xd787ff, 0xd7af00, 0xd7af5f, 0xd7af87, 0xd7afaf, 0xd7afd7, 0xd7afff,
    0xd7d700, 0xd7d75f, 0xd7d787, 0xd7d7af, 0xd7d7d7, 0xd7d7ff, 0xd7ff00, 0xd7ff5f,
    0xd7ff87, 0xd7ffaf, 0xd7ffd7, 0xd7ffff, 0xff0000, 0xff005f, 0xff0087, 0xff00af,
    0xff00d7, 0xff00ff, 0xff5f00, 0xff5f5f, 0xff5f87, 0xff5faf, 0xff5fd7, 0xff5fff,
    0xff8700, 0xff875f, 0xff8787, 0xff87af, 0xff87d7, 0xff87ff, 0xffaf00, 0xffaf5f,
    0xffaf87, 0xffafaf, 0xffafd7, 0xffafff, 0xffd700, 0xffd75f, 0xffd787, 0xffd7af,
    0xffd7d7, 0xffd7ff, 0xffff00, 0xffff5f, 0xffff87, 0xffffaf, 0xffffd7, 0xffffff,
    0x080808, 0x121212, 0x1c1c1c, 0x262626, 0x303030, 0x3a3a3a, 0x444444, 0x4e4e4e,
    0x585858, 0x626262, 0x6c6c6c, 0x767676, 0x808080, 0x8a8a8a, 0x949494, 0x9e9e9e,
    0xa8a8a8, 0xb2b2b2, 0xbcbcbc, 0xc6c6c6, 0xd0d0d0, 0xdadada, 0xe4e4e4, 0xeeeeee,
};

const colour_256_to_16_table = [_]i32{
    0,  1,  2,  3,  4,  5,  6,  7,  8,  9,  10, 11, 12, 13, 14, 15,
    0,  4,  4,  4,  12, 12, 2,  6,  4,  4,  12, 12, 2,  2,  6,  4,
    12, 12, 2,  2,  2,  6,  12, 12, 10, 10, 10, 10, 14, 12, 10, 10,
    10, 10, 10, 14, 1,  5,  4,  4,  12, 12, 3,  8,  4,  4,  12, 12,
    2,  2,  6,  4,  12, 12, 2,  2,  2,  6,  12, 12, 10, 10, 10, 10,
    14, 12, 10, 10, 10, 10, 10, 14, 1,  1,  5,  4,  12, 12, 1,  1,
    5,  4,  12, 12, 3,  3,  8,  4,  12, 12, 2,  2,  2,  6,  12, 12,
    10, 10, 10, 10, 14, 12, 10, 10, 10, 10, 10, 14, 1,  1,  1,  5,
    12, 12, 1,  1,  1,  5,  12, 12, 1,  1,  1,  5,  12, 12, 3,  3,
    3,  7,  12, 12, 10, 10, 10, 10, 14, 12, 10, 10, 10, 10, 10, 14,
    9,  9,  9,  9,  13, 12, 9,  9,  9,  9,  13, 12, 9,  9,  9,  9,
    13, 12, 9,  9,  9,  9,  13, 12, 11, 11, 11, 11, 7,  12, 10, 10,
    10, 10, 10, 14, 9,  9,  9,  9,  9,  13, 9,  9,  9,  9,  9,  13,
    9,  9,  9,  9,  9,  13, 9,  9,  9,  9,  9,  13, 9,  9,  9,  9,
    9,  13, 11, 11, 11, 11, 11, 15, 0,  0,  0,  0,  0,  0,  8,  8,
    8,  8,  8,  8,  7,  7,  7,  7,  7,  7,  15, 15, 15, 15, 15, 15,
};

test "colour join and split roundtrip" {
    const c = colour_join_rgb(0x12, 0x34, 0x56);
    var r: u8 = undefined;
    var g: u8 = undefined;
    var b: u8 = undefined;
    colour_split_rgb(c, &r, &g, &b);
    try std.testing.expectEqual(@as(u8, 0x12), r);
    try std.testing.expectEqual(@as(u8, 0x34), g);
    try std.testing.expectEqual(@as(u8, 0x56), b);
}

test "colour_fromstring parses core formats" {
    try std.testing.expectEqual(colour_join_rgb(0x12, 0x34, 0x56), colour_fromstring("#123456"));
    try std.testing.expectEqual(@as(i32, 42 | T.COLOUR_FLAG_256), colour_fromstring("colour42"));
    try std.testing.expectEqual(@as(i32, 84 | T.COLOUR_FLAG_256), colour_fromstring("color84"));
    try std.testing.expectEqual(@as(i32, 91), colour_fromstring("brightred"));
    try std.testing.expectEqual(@as(i32, -1), colour_fromstring("mystery"));
}

test "colour_parseX11 handles rgb and csv formats" {
    try std.testing.expectEqual(colour_join_rgb(0xaa, 0xbb, 0xcc), colour_parseX11("rgb:aa/bb/cc"));
    try std.testing.expectEqual(colour_join_rgb(1, 2, 3), colour_parseX11("1,2,3"));
    try std.testing.expectEqual(@as(i32, 0xa020f0 | T.COLOUR_FLAG_RGB), colour_parseX11("purple"));
}

test "colour_tostring renders expected forms" {
    try std.testing.expectEqualStrings("none", colour_tostring(-1));
    try std.testing.expectEqualStrings("colour5", colour_tostring(5 | T.COLOUR_FLAG_256));
    try std.testing.expectEqualStrings("#010203", colour_tostring(colour_join_rgb(1, 2, 3)));
    try std.testing.expectEqualStrings("brightwhite", colour_tostring(97));
}

test "colour_palette get set clear lifecycle" {
    var palette: T.ColourPalette = .{};
    colour_palette_init(&palette);
    try std.testing.expectEqual(@as(i32, -1), colour_palette_get(&palette, 1));
    try std.testing.expect(colour_palette_set(&palette, 1, 123));
    try std.testing.expect(colour_palette_set(&palette, 9, 456));
    try std.testing.expectEqual(@as(i32, 123), colour_palette_get(&palette, 1));
    try std.testing.expectEqual(@as(i32, 456), colour_palette_get(&palette, 91));
    colour_palette_clear(&palette);
    try std.testing.expectEqual(@as(i32, -1), colour_palette_get(&palette, 1));
    colour_palette_free(&palette);
}

test "colour_palette_from_option loads reduced pane-colours entries" {
    const oo = opts.options_create(null);
    defer opts.options_free(oo);

    opts.options_set_array(oo, "pane-colours", &.{ "1=#010203", "2=brightred", "bad", "256=#ffffff" });

    var palette: T.ColourPalette = .{};
    colour_palette_init(&palette);
    defer colour_palette_free(&palette);

    colour_palette_from_option(&palette, oo);
    try std.testing.expectEqual(colour_join_rgb(0x01, 0x02, 0x03), colour_palette_get(&palette, 1));
    try std.testing.expectEqual(@as(i32, 91), colour_palette_get(&palette, 2));
    try std.testing.expectEqual(@as(i32, -1), colour_palette_get(&palette, 3));
}

test "colour_totheme classifies light and dark" {
    try std.testing.expectEqual(T.ClientTheme.dark, colour_totheme(0));
    try std.testing.expectEqual(T.ClientTheme.light, colour_totheme(7));
    try std.testing.expectEqual(T.ClientTheme.light, colour_totheme(colour_join_rgb(255, 255, 255)));
}
