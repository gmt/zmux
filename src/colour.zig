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

    for (x11_colour_names) |entry| {
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
    .{ .name = "AntiqueWhite", .value = 0xfaebd7 },
    .{ .name = "AntiqueWhite1", .value = 0xffefdb },
    .{ .name = "AntiqueWhite2", .value = 0xeedfcc },
    .{ .name = "AntiqueWhite3", .value = 0xcdc0b0 },
    .{ .name = "AntiqueWhite4", .value = 0x8b8378 },
    .{ .name = "BlanchedAlmond", .value = 0xffebcd },
    .{ .name = "BlueViolet", .value = 0x8a2be2 },
    .{ .name = "CadetBlue", .value = 0x5f9ea0 },
    .{ .name = "CadetBlue1", .value = 0x98f5ff },
    .{ .name = "CadetBlue2", .value = 0x8ee5ee },
    .{ .name = "CadetBlue3", .value = 0x7ac5cd },
    .{ .name = "CadetBlue4", .value = 0x53868b },
    .{ .name = "CornflowerBlue", .value = 0x6495ed },
    .{ .name = "DarkBlue", .value = 0x00008b },
    .{ .name = "DarkCyan", .value = 0x008b8b },
    .{ .name = "DarkGoldenrod", .value = 0xb8860b },
    .{ .name = "DarkGoldenrod1", .value = 0xffb90f },
    .{ .name = "DarkGoldenrod2", .value = 0xeead0e },
    .{ .name = "DarkGoldenrod3", .value = 0xcd950c },
    .{ .name = "DarkGoldenrod4", .value = 0x8b6508 },
    .{ .name = "DarkGray", .value = 0xa9a9a9 },
    .{ .name = "DarkGreen", .value = 0x006400 },
    .{ .name = "DarkGrey", .value = 0xa9a9a9 },
    .{ .name = "DarkKhaki", .value = 0xbdb76b },
    .{ .name = "DarkMagenta", .value = 0x8b008b },
    .{ .name = "DarkOliveGreen", .value = 0x556b2f },
    .{ .name = "DarkOliveGreen1", .value = 0xcaff70 },
    .{ .name = "DarkOliveGreen2", .value = 0xbcee68 },
    .{ .name = "DarkOliveGreen3", .value = 0xa2cd5a },
    .{ .name = "DarkOliveGreen4", .value = 0x6e8b3d },
    .{ .name = "DarkOrange", .value = 0xff8c00 },
    .{ .name = "DarkOrange1", .value = 0xff7f00 },
    .{ .name = "DarkOrange2", .value = 0xee7600 },
    .{ .name = "DarkOrange3", .value = 0xcd6600 },
    .{ .name = "DarkOrange4", .value = 0x8b4500 },
    .{ .name = "DarkOrchid", .value = 0x9932cc },
    .{ .name = "DarkOrchid1", .value = 0xbf3eff },
    .{ .name = "DarkOrchid2", .value = 0xb23aee },
    .{ .name = "DarkOrchid3", .value = 0x9a32cd },
    .{ .name = "DarkOrchid4", .value = 0x68228b },
    .{ .name = "DarkRed", .value = 0x8b0000 },
    .{ .name = "DarkSalmon", .value = 0xe9967a },
    .{ .name = "DarkSeaGreen", .value = 0x8fbc8f },
    .{ .name = "DarkSeaGreen1", .value = 0xc1ffc1 },
    .{ .name = "DarkSeaGreen2", .value = 0xb4eeb4 },
    .{ .name = "DarkSeaGreen3", .value = 0x9bcd9b },
    .{ .name = "DarkSeaGreen4", .value = 0x698b69 },
    .{ .name = "DarkSlateBlue", .value = 0x483d8b },
    .{ .name = "DarkSlateGray", .value = 0x2f4f4f },
    .{ .name = "DarkSlateGray1", .value = 0x97ffff },
    .{ .name = "DarkSlateGray2", .value = 0x8deeee },
    .{ .name = "DarkSlateGray3", .value = 0x79cdcd },
    .{ .name = "DarkSlateGray4", .value = 0x528b8b },
    .{ .name = "DarkSlateGrey", .value = 0x2f4f4f },
    .{ .name = "DarkTurquoise", .value = 0x00ced1 },
    .{ .name = "DarkViolet", .value = 0x9400d3 },
    .{ .name = "DeepPink", .value = 0xff1493 },
    .{ .name = "DeepPink1", .value = 0xff1493 },
    .{ .name = "DeepPink2", .value = 0xee1289 },
    .{ .name = "DeepPink3", .value = 0xcd1076 },
    .{ .name = "DeepPink4", .value = 0x8b0a50 },
    .{ .name = "DeepSkyBlue", .value = 0x00bfff },
    .{ .name = "DeepSkyBlue1", .value = 0x00bfff },
    .{ .name = "DeepSkyBlue2", .value = 0x00b2ee },
    .{ .name = "DeepSkyBlue3", .value = 0x009acd },
    .{ .name = "DeepSkyBlue4", .value = 0x00688b },
    .{ .name = "DimGray", .value = 0x696969 },
    .{ .name = "DimGrey", .value = 0x696969 },
    .{ .name = "DodgerBlue", .value = 0x1e90ff },
    .{ .name = "DodgerBlue1", .value = 0x1e90ff },
    .{ .name = "DodgerBlue2", .value = 0x1c86ee },
    .{ .name = "DodgerBlue3", .value = 0x1874cd },
    .{ .name = "DodgerBlue4", .value = 0x104e8b },
    .{ .name = "FloralWhite", .value = 0xfffaf0 },
    .{ .name = "ForestGreen", .value = 0x228b22 },
    .{ .name = "GhostWhite", .value = 0xf8f8ff },
    .{ .name = "GreenYellow", .value = 0xadff2f },
    .{ .name = "HotPink", .value = 0xff69b4 },
    .{ .name = "HotPink1", .value = 0xff6eb4 },
    .{ .name = "HotPink2", .value = 0xee6aa7 },
    .{ .name = "HotPink3", .value = 0xcd6090 },
    .{ .name = "HotPink4", .value = 0x8b3a62 },
    .{ .name = "IndianRed", .value = 0xcd5c5c },
    .{ .name = "IndianRed1", .value = 0xff6a6a },
    .{ .name = "IndianRed2", .value = 0xee6363 },
    .{ .name = "IndianRed3", .value = 0xcd5555 },
    .{ .name = "IndianRed4", .value = 0x8b3a3a },
    .{ .name = "LavenderBlush", .value = 0xfff0f5 },
    .{ .name = "LavenderBlush1", .value = 0xfff0f5 },
    .{ .name = "LavenderBlush2", .value = 0xeee0e5 },
    .{ .name = "LavenderBlush3", .value = 0xcdc1c5 },
    .{ .name = "LavenderBlush4", .value = 0x8b8386 },
    .{ .name = "LawnGreen", .value = 0x7cfc00 },
    .{ .name = "LemonChiffon", .value = 0xfffacd },
    .{ .name = "LemonChiffon1", .value = 0xfffacd },
    .{ .name = "LemonChiffon2", .value = 0xeee9bf },
    .{ .name = "LemonChiffon3", .value = 0xcdc9a5 },
    .{ .name = "LemonChiffon4", .value = 0x8b8970 },
    .{ .name = "LightBlue", .value = 0xadd8e6 },
    .{ .name = "LightBlue1", .value = 0xbfefff },
    .{ .name = "LightBlue2", .value = 0xb2dfee },
    .{ .name = "LightBlue3", .value = 0x9ac0cd },
    .{ .name = "LightBlue4", .value = 0x68838b },
    .{ .name = "LightCoral", .value = 0xf08080 },
    .{ .name = "LightCyan", .value = 0xe0ffff },
    .{ .name = "LightCyan1", .value = 0xe0ffff },
    .{ .name = "LightCyan2", .value = 0xd1eeee },
    .{ .name = "LightCyan3", .value = 0xb4cdcd },
    .{ .name = "LightCyan4", .value = 0x7a8b8b },
    .{ .name = "LightGoldenrod", .value = 0xeedd82 },
    .{ .name = "LightGoldenrod1", .value = 0xffec8b },
    .{ .name = "LightGoldenrod2", .value = 0xeedc82 },
    .{ .name = "LightGoldenrod3", .value = 0xcdbe70 },
    .{ .name = "LightGoldenrod4", .value = 0x8b814c },
    .{ .name = "LightGoldenrodYellow", .value = 0xfafad2 },
    .{ .name = "LightGray", .value = 0xd3d3d3 },
    .{ .name = "LightGreen", .value = 0x90ee90 },
    .{ .name = "LightGrey", .value = 0xd3d3d3 },
    .{ .name = "LightPink", .value = 0xffb6c1 },
    .{ .name = "LightPink1", .value = 0xffaeb9 },
    .{ .name = "LightPink2", .value = 0xeea2ad },
    .{ .name = "LightPink3", .value = 0xcd8c95 },
    .{ .name = "LightPink4", .value = 0x8b5f65 },
    .{ .name = "LightSalmon", .value = 0xffa07a },
    .{ .name = "LightSalmon1", .value = 0xffa07a },
    .{ .name = "LightSalmon2", .value = 0xee9572 },
    .{ .name = "LightSalmon3", .value = 0xcd8162 },
    .{ .name = "LightSalmon4", .value = 0x8b5742 },
    .{ .name = "LightSeaGreen", .value = 0x20b2aa },
    .{ .name = "LightSkyBlue", .value = 0x87cefa },
    .{ .name = "LightSkyBlue1", .value = 0xb0e2ff },
    .{ .name = "LightSkyBlue2", .value = 0xa4d3ee },
    .{ .name = "LightSkyBlue3", .value = 0x8db6cd },
    .{ .name = "LightSkyBlue4", .value = 0x607b8b },
    .{ .name = "LightSlateBlue", .value = 0x8470ff },
    .{ .name = "LightSlateGray", .value = 0x778899 },
    .{ .name = "LightSlateGrey", .value = 0x778899 },
    .{ .name = "LightSteelBlue", .value = 0xb0c4de },
    .{ .name = "LightSteelBlue1", .value = 0xcae1ff },
    .{ .name = "LightSteelBlue2", .value = 0xbcd2ee },
    .{ .name = "LightSteelBlue3", .value = 0xa2b5cd },
    .{ .name = "LightSteelBlue4", .value = 0x6e7b8b },
    .{ .name = "LightYellow", .value = 0xffffe0 },
    .{ .name = "LightYellow1", .value = 0xffffe0 },
    .{ .name = "LightYellow2", .value = 0xeeeed1 },
    .{ .name = "LightYellow3", .value = 0xcdcdb4 },
    .{ .name = "LightYellow4", .value = 0x8b8b7a },
    .{ .name = "LimeGreen", .value = 0x32cd32 },
    .{ .name = "MediumAquamarine", .value = 0x66cdaa },
    .{ .name = "MediumBlue", .value = 0x0000cd },
    .{ .name = "MediumOrchid", .value = 0xba55d3 },
    .{ .name = "MediumOrchid1", .value = 0xe066ff },
    .{ .name = "MediumOrchid2", .value = 0xd15fee },
    .{ .name = "MediumOrchid3", .value = 0xb452cd },
    .{ .name = "MediumOrchid4", .value = 0x7a378b },
    .{ .name = "MediumPurple", .value = 0x9370db },
    .{ .name = "MediumPurple1", .value = 0xab82ff },
    .{ .name = "MediumPurple2", .value = 0x9f79ee },
    .{ .name = "MediumPurple3", .value = 0x8968cd },
    .{ .name = "MediumPurple4", .value = 0x5d478b },
    .{ .name = "MediumSeaGreen", .value = 0x3cb371 },
    .{ .name = "MediumSlateBlue", .value = 0x7b68ee },
    .{ .name = "MediumSpringGreen", .value = 0x00fa9a },
    .{ .name = "MediumTurquoise", .value = 0x48d1cc },
    .{ .name = "MediumVioletRed", .value = 0xc71585 },
    .{ .name = "MidnightBlue", .value = 0x191970 },
    .{ .name = "MintCream", .value = 0xf5fffa },
    .{ .name = "MistyRose", .value = 0xffe4e1 },
    .{ .name = "MistyRose1", .value = 0xffe4e1 },
    .{ .name = "MistyRose2", .value = 0xeed5d2 },
    .{ .name = "MistyRose3", .value = 0xcdb7b5 },
    .{ .name = "MistyRose4", .value = 0x8b7d7b },
    .{ .name = "NavajoWhite", .value = 0xffdead },
    .{ .name = "NavajoWhite1", .value = 0xffdead },
    .{ .name = "NavajoWhite2", .value = 0xeecfa1 },
    .{ .name = "NavajoWhite3", .value = 0xcdb38b },
    .{ .name = "NavajoWhite4", .value = 0x8b795e },
    .{ .name = "NavyBlue", .value = 0x000080 },
    .{ .name = "OldLace", .value = 0xfdf5e6 },
    .{ .name = "OliveDrab", .value = 0x6b8e23 },
    .{ .name = "OliveDrab1", .value = 0xc0ff3e },
    .{ .name = "OliveDrab2", .value = 0xb3ee3a },
    .{ .name = "OliveDrab3", .value = 0x9acd32 },
    .{ .name = "OliveDrab4", .value = 0x698b22 },
    .{ .name = "OrangeRed", .value = 0xff4500 },
    .{ .name = "OrangeRed1", .value = 0xff4500 },
    .{ .name = "OrangeRed2", .value = 0xee4000 },
    .{ .name = "OrangeRed3", .value = 0xcd3700 },
    .{ .name = "OrangeRed4", .value = 0x8b2500 },
    .{ .name = "PaleGoldenrod", .value = 0xeee8aa },
    .{ .name = "PaleGreen", .value = 0x98fb98 },
    .{ .name = "PaleGreen1", .value = 0x9aff9a },
    .{ .name = "PaleGreen2", .value = 0x90ee90 },
    .{ .name = "PaleGreen3", .value = 0x7ccd7c },
    .{ .name = "PaleGreen4", .value = 0x548b54 },
    .{ .name = "PaleTurquoise", .value = 0xafeeee },
    .{ .name = "PaleTurquoise1", .value = 0xbbffff },
    .{ .name = "PaleTurquoise2", .value = 0xaeeeee },
    .{ .name = "PaleTurquoise3", .value = 0x96cdcd },
    .{ .name = "PaleTurquoise4", .value = 0x668b8b },
    .{ .name = "PaleVioletRed", .value = 0xdb7093 },
    .{ .name = "PaleVioletRed1", .value = 0xff82ab },
    .{ .name = "PaleVioletRed2", .value = 0xee799f },
    .{ .name = "PaleVioletRed3", .value = 0xcd6889 },
    .{ .name = "PaleVioletRed4", .value = 0x8b475d },
    .{ .name = "PapayaWhip", .value = 0xffefd5 },
    .{ .name = "PeachPuff", .value = 0xffdab9 },
    .{ .name = "PeachPuff1", .value = 0xffdab9 },
    .{ .name = "PeachPuff2", .value = 0xeecbad },
    .{ .name = "PeachPuff3", .value = 0xcdaf95 },
    .{ .name = "PeachPuff4", .value = 0x8b7765 },
    .{ .name = "PowderBlue", .value = 0xb0e0e6 },
    .{ .name = "RebeccaPurple", .value = 0x663399 },
    .{ .name = "RosyBrown", .value = 0xbc8f8f },
    .{ .name = "RosyBrown1", .value = 0xffc1c1 },
    .{ .name = "RosyBrown2", .value = 0xeeb4b4 },
    .{ .name = "RosyBrown3", .value = 0xcd9b9b },
    .{ .name = "RosyBrown4", .value = 0x8b6969 },
    .{ .name = "RoyalBlue", .value = 0x4169e1 },
    .{ .name = "RoyalBlue1", .value = 0x4876ff },
    .{ .name = "RoyalBlue2", .value = 0x436eee },
    .{ .name = "RoyalBlue3", .value = 0x3a5fcd },
    .{ .name = "RoyalBlue4", .value = 0x27408b },
    .{ .name = "SaddleBrown", .value = 0x8b4513 },
    .{ .name = "SandyBrown", .value = 0xf4a460 },
    .{ .name = "SeaGreen", .value = 0x2e8b57 },
    .{ .name = "SeaGreen1", .value = 0x54ff9f },
    .{ .name = "SeaGreen2", .value = 0x4eee94 },
    .{ .name = "SeaGreen3", .value = 0x43cd80 },
    .{ .name = "SeaGreen4", .value = 0x2e8b57 },
    .{ .name = "SkyBlue", .value = 0x87ceeb },
    .{ .name = "SkyBlue1", .value = 0x87ceff },
    .{ .name = "SkyBlue2", .value = 0x7ec0ee },
    .{ .name = "SkyBlue3", .value = 0x6ca6cd },
    .{ .name = "SkyBlue4", .value = 0x4a708b },
    .{ .name = "SlateBlue", .value = 0x6a5acd },
    .{ .name = "SlateBlue1", .value = 0x836fff },
    .{ .name = "SlateBlue2", .value = 0x7a67ee },
    .{ .name = "SlateBlue3", .value = 0x6959cd },
    .{ .name = "SlateBlue4", .value = 0x473c8b },
    .{ .name = "SlateGray", .value = 0x708090 },
    .{ .name = "SlateGray1", .value = 0xc6e2ff },
    .{ .name = "SlateGray2", .value = 0xb9d3ee },
    .{ .name = "SlateGray3", .value = 0x9fb6cd },
    .{ .name = "SlateGray4", .value = 0x6c7b8b },
    .{ .name = "SlateGrey", .value = 0x708090 },
    .{ .name = "SpringGreen", .value = 0x00ff7f },
    .{ .name = "SpringGreen1", .value = 0x00ff7f },
    .{ .name = "SpringGreen2", .value = 0x00ee76 },
    .{ .name = "SpringGreen3", .value = 0x00cd66 },
    .{ .name = "SpringGreen4", .value = 0x008b45 },
    .{ .name = "SteelBlue", .value = 0x4682b4 },
    .{ .name = "SteelBlue1", .value = 0x63b8ff },
    .{ .name = "SteelBlue2", .value = 0x5cacee },
    .{ .name = "SteelBlue3", .value = 0x4f94cd },
    .{ .name = "SteelBlue4", .value = 0x36648b },
    .{ .name = "VioletRed", .value = 0xd02090 },
    .{ .name = "VioletRed1", .value = 0xff3e96 },
    .{ .name = "VioletRed2", .value = 0xee3a8c },
    .{ .name = "VioletRed3", .value = 0xcd3278 },
    .{ .name = "VioletRed4", .value = 0x8b2252 },
    .{ .name = "WebGray", .value = 0x808080 },
    .{ .name = "WebGreen", .value = 0x008000 },
    .{ .name = "WebGrey", .value = 0x808080 },
    .{ .name = "WebMaroon", .value = 0x800000 },
    .{ .name = "WebPurple", .value = 0x800080 },
    .{ .name = "WhiteSmoke", .value = 0xf5f5f5 },
    .{ .name = "X11Gray", .value = 0xbebebe },
    .{ .name = "X11Green", .value = 0x00ff00 },
    .{ .name = "X11Grey", .value = 0xbebebe },
    .{ .name = "X11Maroon", .value = 0xb03060 },
    .{ .name = "X11Purple", .value = 0xa020f0 },
    .{ .name = "YellowGreen", .value = 0x9acd32 },
    .{ .name = "alice blue", .value = 0xf0f8ff },
    .{ .name = "antique white", .value = 0xfaebd7 },
    .{ .name = "aqua", .value = 0x00ffff },
    .{ .name = "aquamarine", .value = 0x7fffd4 },
    .{ .name = "aquamarine1", .value = 0x7fffd4 },
    .{ .name = "aquamarine2", .value = 0x76eec6 },
    .{ .name = "aquamarine3", .value = 0x66cdaa },
    .{ .name = "aquamarine4", .value = 0x458b74 },
    .{ .name = "azure", .value = 0xf0ffff },
    .{ .name = "azure1", .value = 0xf0ffff },
    .{ .name = "azure2", .value = 0xe0eeee },
    .{ .name = "azure3", .value = 0xc1cdcd },
    .{ .name = "azure4", .value = 0x838b8b },
    .{ .name = "beige", .value = 0xf5f5dc },
    .{ .name = "bisque", .value = 0xffe4c4 },
    .{ .name = "bisque1", .value = 0xffe4c4 },
    .{ .name = "bisque2", .value = 0xeed5b7 },
    .{ .name = "bisque3", .value = 0xcdb79e },
    .{ .name = "bisque4", .value = 0x8b7d6b },
    .{ .name = "black", .value = 0x000000 },
    .{ .name = "blanched almond", .value = 0xffebcd },
    .{ .name = "blue violet", .value = 0x8a2be2 },
    .{ .name = "blue", .value = 0x0000ff },
    .{ .name = "blue1", .value = 0x0000ff },
    .{ .name = "blue2", .value = 0x0000ee },
    .{ .name = "blue3", .value = 0x0000cd },
    .{ .name = "blue4", .value = 0x00008b },
    .{ .name = "brown", .value = 0xa52a2a },
    .{ .name = "brown1", .value = 0xff4040 },
    .{ .name = "brown2", .value = 0xee3b3b },
    .{ .name = "brown3", .value = 0xcd3333 },
    .{ .name = "brown4", .value = 0x8b2323 },
    .{ .name = "burlywood", .value = 0xdeb887 },
    .{ .name = "burlywood1", .value = 0xffd39b },
    .{ .name = "burlywood2", .value = 0xeec591 },
    .{ .name = "burlywood3", .value = 0xcdaa7d },
    .{ .name = "burlywood4", .value = 0x8b7355 },
    .{ .name = "cadet blue", .value = 0x5f9ea0 },
    .{ .name = "chartreuse", .value = 0x7fff00 },
    .{ .name = "chartreuse1", .value = 0x7fff00 },
    .{ .name = "chartreuse2", .value = 0x76ee00 },
    .{ .name = "chartreuse3", .value = 0x66cd00 },
    .{ .name = "chartreuse4", .value = 0x458b00 },
    .{ .name = "chocolate", .value = 0xd2691e },
    .{ .name = "chocolate1", .value = 0xff7f24 },
    .{ .name = "chocolate2", .value = 0xee7621 },
    .{ .name = "chocolate3", .value = 0xcd661d },
    .{ .name = "chocolate4", .value = 0x8b4513 },
    .{ .name = "coral", .value = 0xff7f50 },
    .{ .name = "coral1", .value = 0xff7256 },
    .{ .name = "coral2", .value = 0xee6a50 },
    .{ .name = "coral3", .value = 0xcd5b45 },
    .{ .name = "coral4", .value = 0x8b3e2f },
    .{ .name = "cornflower blue", .value = 0x6495ed },
    .{ .name = "cornsilk", .value = 0xfff8dc },
    .{ .name = "cornsilk1", .value = 0xfff8dc },
    .{ .name = "cornsilk2", .value = 0xeee8cd },
    .{ .name = "cornsilk3", .value = 0xcdc8b1 },
    .{ .name = "cornsilk4", .value = 0x8b8878 },
    .{ .name = "crimson", .value = 0xdc143c },
    .{ .name = "cyan", .value = 0x00ffff },
    .{ .name = "cyan1", .value = 0x00ffff },
    .{ .name = "cyan2", .value = 0x00eeee },
    .{ .name = "cyan3", .value = 0x00cdcd },
    .{ .name = "cyan4", .value = 0x008b8b },
    .{ .name = "dark blue", .value = 0x00008b },
    .{ .name = "dark cyan", .value = 0x008b8b },
    .{ .name = "dark goldenrod", .value = 0xb8860b },
    .{ .name = "dark gray", .value = 0xa9a9a9 },
    .{ .name = "dark green", .value = 0x006400 },
    .{ .name = "dark grey", .value = 0xa9a9a9 },
    .{ .name = "dark khaki", .value = 0xbdb76b },
    .{ .name = "dark magenta", .value = 0x8b008b },
    .{ .name = "dark olive green", .value = 0x556b2f },
    .{ .name = "dark orange", .value = 0xff8c00 },
    .{ .name = "dark orchid", .value = 0x9932cc },
    .{ .name = "dark red", .value = 0x8b0000 },
    .{ .name = "dark salmon", .value = 0xe9967a },
    .{ .name = "dark sea green", .value = 0x8fbc8f },
    .{ .name = "dark slate blue", .value = 0x483d8b },
    .{ .name = "dark slate gray", .value = 0x2f4f4f },
    .{ .name = "dark slate grey", .value = 0x2f4f4f },
    .{ .name = "dark turquoise", .value = 0x00ced1 },
    .{ .name = "dark violet", .value = 0x9400d3 },
    .{ .name = "deep pink", .value = 0xff1493 },
    .{ .name = "deep sky blue", .value = 0x00bfff },
    .{ .name = "dim gray", .value = 0x696969 },
    .{ .name = "dim grey", .value = 0x696969 },
    .{ .name = "dodger blue", .value = 0x1e90ff },
    .{ .name = "firebrick", .value = 0xb22222 },
    .{ .name = "firebrick1", .value = 0xff3030 },
    .{ .name = "firebrick2", .value = 0xee2c2c },
    .{ .name = "firebrick3", .value = 0xcd2626 },
    .{ .name = "firebrick4", .value = 0x8b1a1a },
    .{ .name = "floral white", .value = 0xfffaf0 },
    .{ .name = "forest green", .value = 0x228b22 },
    .{ .name = "fuchsia", .value = 0xff00ff },
    .{ .name = "gainsboro", .value = 0xdcdcdc },
    .{ .name = "ghost white", .value = 0xf8f8ff },
    .{ .name = "gold", .value = 0xffd700 },
    .{ .name = "gold1", .value = 0xffd700 },
    .{ .name = "gold2", .value = 0xeec900 },
    .{ .name = "gold3", .value = 0xcdad00 },
    .{ .name = "gold4", .value = 0x8b7500 },
    .{ .name = "goldenrod", .value = 0xdaa520 },
    .{ .name = "goldenrod1", .value = 0xffc125 },
    .{ .name = "goldenrod2", .value = 0xeeb422 },
    .{ .name = "goldenrod3", .value = 0xcd9b1d },
    .{ .name = "goldenrod4", .value = 0x8b6914 },
    .{ .name = "green yellow", .value = 0xadff2f },
    .{ .name = "green", .value = 0x00ff00 },
    .{ .name = "green1", .value = 0x00ff00 },
    .{ .name = "green2", .value = 0x00ee00 },
    .{ .name = "green3", .value = 0x00cd00 },
    .{ .name = "green4", .value = 0x008b00 },
    .{ .name = "honeydew", .value = 0xf0fff0 },
    .{ .name = "honeydew1", .value = 0xf0fff0 },
    .{ .name = "honeydew2", .value = 0xe0eee0 },
    .{ .name = "honeydew3", .value = 0xc1cdc1 },
    .{ .name = "honeydew4", .value = 0x838b83 },
    .{ .name = "hot pink", .value = 0xff69b4 },
    .{ .name = "indian red", .value = 0xcd5c5c },
    .{ .name = "indigo", .value = 0x4b0082 },
    .{ .name = "ivory", .value = 0xfffff0 },
    .{ .name = "ivory1", .value = 0xfffff0 },
    .{ .name = "ivory2", .value = 0xeeeee0 },
    .{ .name = "ivory3", .value = 0xcdcdc1 },
    .{ .name = "ivory4", .value = 0x8b8b83 },
    .{ .name = "khaki", .value = 0xf0e68c },
    .{ .name = "khaki1", .value = 0xfff68f },
    .{ .name = "khaki2", .value = 0xeee685 },
    .{ .name = "khaki3", .value = 0xcdc673 },
    .{ .name = "khaki4", .value = 0x8b864e },
    .{ .name = "lavender blush", .value = 0xfff0f5 },
    .{ .name = "lavender", .value = 0xe6e6fa },
    .{ .name = "lawn green", .value = 0x7cfc00 },
    .{ .name = "lemon chiffon", .value = 0xfffacd },
    .{ .name = "light blue", .value = 0xadd8e6 },
    .{ .name = "light coral", .value = 0xf08080 },
    .{ .name = "light cyan", .value = 0xe0ffff },
    .{ .name = "light goldenrod yellow", .value = 0xfafad2 },
    .{ .name = "light goldenrod", .value = 0xeedd82 },
    .{ .name = "light gray", .value = 0xd3d3d3 },
    .{ .name = "light green", .value = 0x90ee90 },
    .{ .name = "light grey", .value = 0xd3d3d3 },
    .{ .name = "light pink", .value = 0xffb6c1 },
    .{ .name = "light salmon", .value = 0xffa07a },
    .{ .name = "light sea green", .value = 0x20b2aa },
    .{ .name = "light sky blue", .value = 0x87cefa },
    .{ .name = "light slate blue", .value = 0x8470ff },
    .{ .name = "light slate gray", .value = 0x778899 },
    .{ .name = "light slate grey", .value = 0x778899 },
    .{ .name = "light steel blue", .value = 0xb0c4de },
    .{ .name = "light yellow", .value = 0xffffe0 },
    .{ .name = "lime green", .value = 0x32cd32 },
    .{ .name = "lime", .value = 0x00ff00 },
    .{ .name = "linen", .value = 0xfaf0e6 },
    .{ .name = "magenta", .value = 0xff00ff },
    .{ .name = "magenta1", .value = 0xff00ff },
    .{ .name = "magenta2", .value = 0xee00ee },
    .{ .name = "magenta3", .value = 0xcd00cd },
    .{ .name = "magenta4", .value = 0x8b008b },
    .{ .name = "maroon", .value = 0xb03060 },
    .{ .name = "maroon1", .value = 0xff34b3 },
    .{ .name = "maroon2", .value = 0xee30a7 },
    .{ .name = "maroon3", .value = 0xcd2990 },
    .{ .name = "maroon4", .value = 0x8b1c62 },
    .{ .name = "medium aquamarine", .value = 0x66cdaa },
    .{ .name = "medium blue", .value = 0x0000cd },
    .{ .name = "medium orchid", .value = 0xba55d3 },
    .{ .name = "medium purple", .value = 0x9370db },
    .{ .name = "medium sea green", .value = 0x3cb371 },
    .{ .name = "medium slate blue", .value = 0x7b68ee },
    .{ .name = "medium spring green", .value = 0x00fa9a },
    .{ .name = "medium turquoise", .value = 0x48d1cc },
    .{ .name = "medium violet red", .value = 0xc71585 },
    .{ .name = "midnight blue", .value = 0x191970 },
    .{ .name = "mint cream", .value = 0xf5fffa },
    .{ .name = "misty rose", .value = 0xffe4e1 },
    .{ .name = "moccasin", .value = 0xffe4b5 },
    .{ .name = "navajo white", .value = 0xffdead },
    .{ .name = "navy blue", .value = 0x000080 },
    .{ .name = "navy", .value = 0x000080 },
    .{ .name = "old lace", .value = 0xfdf5e6 },
    .{ .name = "olive drab", .value = 0x6b8e23 },
    .{ .name = "olive", .value = 0x808000 },
    .{ .name = "orange red", .value = 0xff4500 },
    .{ .name = "orange", .value = 0xffa500 },
    .{ .name = "orange1", .value = 0xffa500 },
    .{ .name = "orange2", .value = 0xee9a00 },
    .{ .name = "orange3", .value = 0xcd8500 },
    .{ .name = "orange4", .value = 0x8b5a00 },
    .{ .name = "orchid", .value = 0xda70d6 },
    .{ .name = "orchid1", .value = 0xff83fa },
    .{ .name = "orchid2", .value = 0xee7ae9 },
    .{ .name = "orchid3", .value = 0xcd69c9 },
    .{ .name = "orchid4", .value = 0x8b4789 },
    .{ .name = "pale goldenrod", .value = 0xeee8aa },
    .{ .name = "pale green", .value = 0x98fb98 },
    .{ .name = "pale turquoise", .value = 0xafeeee },
    .{ .name = "pale violet red", .value = 0xdb7093 },
    .{ .name = "papaya whip", .value = 0xffefd5 },
    .{ .name = "peach puff", .value = 0xffdab9 },
    .{ .name = "peru", .value = 0xcd853f },
    .{ .name = "pink", .value = 0xffc0cb },
    .{ .name = "pink1", .value = 0xffb5c5 },
    .{ .name = "pink2", .value = 0xeea9b8 },
    .{ .name = "pink3", .value = 0xcd919e },
    .{ .name = "pink4", .value = 0x8b636c },
    .{ .name = "plum", .value = 0xdda0dd },
    .{ .name = "plum1", .value = 0xffbbff },
    .{ .name = "plum2", .value = 0xeeaeee },
    .{ .name = "plum3", .value = 0xcd96cd },
    .{ .name = "plum4", .value = 0x8b668b },
    .{ .name = "powder blue", .value = 0xb0e0e6 },
    .{ .name = "purple", .value = 0xa020f0 },
    .{ .name = "purple1", .value = 0x9b30ff },
    .{ .name = "purple2", .value = 0x912cee },
    .{ .name = "purple3", .value = 0x7d26cd },
    .{ .name = "purple4", .value = 0x551a8b },
    .{ .name = "rebecca purple", .value = 0x663399 },
    .{ .name = "red", .value = 0xff0000 },
    .{ .name = "red1", .value = 0xff0000 },
    .{ .name = "red2", .value = 0xee0000 },
    .{ .name = "red3", .value = 0xcd0000 },
    .{ .name = "red4", .value = 0x8b0000 },
    .{ .name = "rosy brown", .value = 0xbc8f8f },
    .{ .name = "royal blue", .value = 0x4169e1 },
    .{ .name = "saddle brown", .value = 0x8b4513 },
    .{ .name = "salmon", .value = 0xfa8072 },
    .{ .name = "salmon1", .value = 0xff8c69 },
    .{ .name = "salmon2", .value = 0xee8262 },
    .{ .name = "salmon3", .value = 0xcd7054 },
    .{ .name = "salmon4", .value = 0x8b4c39 },
    .{ .name = "sandy brown", .value = 0xf4a460 },
    .{ .name = "sea green", .value = 0x2e8b57 },
    .{ .name = "seashell", .value = 0xfff5ee },
    .{ .name = "seashell1", .value = 0xfff5ee },
    .{ .name = "seashell2", .value = 0xeee5de },
    .{ .name = "seashell3", .value = 0xcdc5bf },
    .{ .name = "seashell4", .value = 0x8b8682 },
    .{ .name = "sienna", .value = 0xa0522d },
    .{ .name = "sienna1", .value = 0xff8247 },
    .{ .name = "sienna2", .value = 0xee7942 },
    .{ .name = "sienna3", .value = 0xcd6839 },
    .{ .name = "sienna4", .value = 0x8b4726 },
    .{ .name = "silver", .value = 0xc0c0c0 },
    .{ .name = "sky blue", .value = 0x87ceeb },
    .{ .name = "slate blue", .value = 0x6a5acd },
    .{ .name = "slate gray", .value = 0x708090 },
    .{ .name = "slate grey", .value = 0x708090 },
    .{ .name = "snow", .value = 0xfffafa },
    .{ .name = "snow1", .value = 0xfffafa },
    .{ .name = "snow2", .value = 0xeee9e9 },
    .{ .name = "snow3", .value = 0xcdc9c9 },
    .{ .name = "snow4", .value = 0x8b8989 },
    .{ .name = "spring green", .value = 0x00ff7f },
    .{ .name = "steel blue", .value = 0x4682b4 },
    .{ .name = "tan", .value = 0xd2b48c },
    .{ .name = "tan1", .value = 0xffa54f },
    .{ .name = "tan2", .value = 0xee9a49 },
    .{ .name = "tan3", .value = 0xcd853f },
    .{ .name = "tan4", .value = 0x8b5a2b },
    .{ .name = "teal", .value = 0x008080 },
    .{ .name = "thistle", .value = 0xd8bfd8 },
    .{ .name = "thistle1", .value = 0xffe1ff },
    .{ .name = "thistle2", .value = 0xeed2ee },
    .{ .name = "thistle3", .value = 0xcdb5cd },
    .{ .name = "thistle4", .value = 0x8b7b8b },
    .{ .name = "tomato", .value = 0xff6347 },
    .{ .name = "tomato1", .value = 0xff6347 },
    .{ .name = "tomato2", .value = 0xee5c42 },
    .{ .name = "tomato3", .value = 0xcd4f39 },
    .{ .name = "tomato4", .value = 0x8b3626 },
    .{ .name = "turquoise", .value = 0x40e0d0 },
    .{ .name = "turquoise1", .value = 0x00f5ff },
    .{ .name = "turquoise2", .value = 0x00e5ee },
    .{ .name = "turquoise3", .value = 0x00c5cd },
    .{ .name = "turquoise4", .value = 0x00868b },
    .{ .name = "violet red", .value = 0xd02090 },
    .{ .name = "violet", .value = 0xee82ee },
    .{ .name = "web gray", .value = 0x808080 },
    .{ .name = "web green", .value = 0x008000 },
    .{ .name = "web grey", .value = 0x808080 },
    .{ .name = "web maroon", .value = 0x800000 },
    .{ .name = "web purple", .value = 0x800080 },
    .{ .name = "wheat", .value = 0xf5deb3 },
    .{ .name = "wheat1", .value = 0xffe7ba },
    .{ .name = "wheat2", .value = 0xeed8ae },
    .{ .name = "wheat3", .value = 0xcdba96 },
    .{ .name = "wheat4", .value = 0x8b7e66 },
    .{ .name = "white smoke", .value = 0xf5f5f5 },
    .{ .name = "white", .value = 0xffffff },
    .{ .name = "x11 gray", .value = 0xbebebe },
    .{ .name = "x11 green", .value = 0x00ff00 },
    .{ .name = "x11 grey", .value = 0xbebebe },
    .{ .name = "x11 maroon", .value = 0xb03060 },
    .{ .name = "x11 purple", .value = 0xa020f0 },
    .{ .name = "yellow green", .value = 0x9acd32 },
    .{ .name = "yellow", .value = 0xffff00 },
    .{ .name = "yellow1", .value = 0xffff00 },
    .{ .name = "yellow2", .value = 0xeeee00 },
    .{ .name = "yellow3", .value = 0xcdcd00 },
    .{ .name = "yellow4", .value = 0x8b8b00 },
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
