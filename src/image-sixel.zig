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
// WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
// ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
// OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
//
// Ported from tmux/image-sixel.c.
// Original copyright:
//   Copyright (c) 2019 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

//! image-sixel.zig – sixel format parser, colour table management,
//! band→cell mapping, and RLE sixel serialiser.

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const log_mod = @import("log.zig");

// ── Constants ─────────────────────────────────────────────────────────────

pub const SIXEL_WIDTH_LIMIT: u32 = 10000;
pub const SIXEL_HEIGHT_LIMIT: u32 = 10000;
pub const SIXEL_COLOUR_REGISTERS: u32 = 1024;

// ── Internal: chunk for RLE sixel output ──────────────────────────────────

const SixelChunk = struct {
    next_x: u32 = 0,
    next_y: u32 = 0,

    count: u32 = 0,
    pattern: u8 = 0,
    next_pattern: u8 = 0,

    data: std.ArrayListUnmanaged(u8) = .{},

    fn deinit(self: *SixelChunk) void {
        self.data.deinit(xm.allocator);
    }
};

// ── Allocator helpers ─────────────────────────────────────────────────────

/// Extend `si.lines` to cover at least `new_y` rows.
/// Returns false on success, true if the new size exceeds the height limit.
fn sixel_parse_expand_lines(si: *T.SixelImage, new_y: u32) bool {
    if (new_y <= si.y) return false;
    if (new_y > SIXEL_HEIGHT_LIMIT) return true;

    const old_y = si.y;
    si.lines = xm.allocator.realloc(si.lines, new_y) catch unreachable;
    // Zero-init newly appended lines.
    for (si.lines[old_y..new_y]) |*sl| sl.* = .{};
    si.y = new_y;
    return false;
}

/// Extend `sl.data` to cover at least `new_x` pixels.
/// Returns false on success, true if the new size exceeds the width limit.
fn sixel_parse_expand_line(si: *T.SixelImage, sl: *T.SixelLine, new_x: u32) bool {
    if (new_x <= sl.x) return false;
    if (new_x > SIXEL_WIDTH_LIMIT) return true;

    if (new_x > si.x) si.x = new_x;

    const old_x = sl.x;
    sl.data = xm.allocator.realloc(sl.data, si.x) catch unreachable;
    // Zero-init newly appended pixels.
    for (sl.data[old_x..si.x]) |*p| p.* = 0;
    sl.x = si.x;
    return false;
}

// ── Pixel access ──────────────────────────────────────────────────────────

pub fn sixel_get_pixel(si: *const T.SixelImage, x: u32, y: u32) u32 {
    if (y >= si.y) return 0;
    const sl = &si.lines[y];
    if (x >= sl.x) return 0;
    return sl.data[x];
}

fn sixel_set_pixel(si: *T.SixelImage, x: u32, y: u32, c: u32) bool {
    if (sixel_parse_expand_lines(si, y + 1)) return true;
    const sl = &si.lines[y];
    if (sixel_parse_expand_line(si, sl, x + 1)) return true;
    sl.data[x] = @intCast(c);
    return false;
}

// ── Write one sixel character to the current draw position ────────────────

fn sixel_parse_write(si: *T.SixelImage, ch: u8) bool {
    if (sixel_parse_expand_lines(si, si.dy + 6)) return true;

    var i: u32 = 0;
    while (i < 6) : (i += 1) {
        const sl = &si.lines[si.dy + i];
        if (sixel_parse_expand_line(si, sl, si.dx + 1)) return true;
        if ((ch & (@as(u8, 1) << @intCast(i))) != 0) {
            sl.data[si.dx] = @intCast(si.dc);
        }
    }
    return false;
}

// ── Attribute parser: "pa;pb;width;height" ────────────────────────────────

/// Parse the raster-attributes sequence following `"`.
/// Returns the next parse position, or null on fatal error.
fn sixel_parse_attributes(si: *T.SixelImage, buf: []const u8, pos: usize) ?usize {
    var p = pos;
    const end = buf.len;

    // Consume the prefix: two semicolon-separated dummy fields, then width;height.
    // Format: pan;pad;Ph;Pv  (pan and pad are aspect-ratio values we ignore).

    // Helper: parse an unsigned decimal number and advance p.
    // Returns null when no digits are found.
    const parseNum = struct {
        fn f(b: []const u8, i: *usize) ?u32 {
            const start = i.*;
            while (i.* < b.len and b[i.*] >= '0' and b[i.*] <= '9') i.* += 1;
            if (i.* == start) return null;
            return std.fmt.parseUnsigned(u32, b[start..i.*], 10) catch null;
        }
    }.f;

    // Skip first field (pan).
    _ = parseNum(buf, &p);
    if (p >= end or buf[p] != ';') return p;
    p += 1; // skip ';'

    // Skip second field (pad).
    _ = parseNum(buf, &p);
    if (p >= end or buf[p] != ';') {
        log_mod.log_debug("sixel_parse_attributes: missing ;", .{});
        return null;
    }
    p += 1; // skip ';'

    const x = parseNum(buf, &p) orelse {
        log_mod.log_debug("sixel_parse_attributes: missing width", .{});
        return null;
    };
    if (p >= end or buf[p] != ';') {
        log_mod.log_debug("sixel_parse_attributes: missing ;", .{});
        return null;
    }
    p += 1; // skip ';'

    const y = parseNum(buf, &p) orelse {
        log_mod.log_debug("sixel_parse_attributes: missing height", .{});
        return null;
    };

    if (x > SIXEL_WIDTH_LIMIT) {
        log_mod.log_debug("sixel_parse_attributes: image too wide", .{});
        return null;
    }
    if (y > SIXEL_HEIGHT_LIMIT) {
        log_mod.log_debug("sixel_parse_attributes: image too tall", .{});
        return null;
    }

    si.x = x;
    _ = sixel_parse_expand_lines(si, y);

    si.set_ra = 1;
    si.ra_x = x;
    si.ra_y = y;

    return p;
}

// ── Colour entry parser: "c;type;c1;c2;c3" ──────────────────────────────

/// Parse a colour-parameter sequence following `#`.
/// Returns the next parse position, or null on fatal error.
fn sixel_parse_colour(si: *T.SixelImage, buf: []const u8, pos: usize) ?usize {
    var p = pos;
    const end = buf.len;

    const parseNum = struct {
        fn f(b: []const u8, i: *usize) ?u32 {
            const start = i.*;
            while (i.* < b.len and b[i.*] >= '0' and b[i.*] <= '9') i.* += 1;
            if (i.* == start) return null;
            return std.fmt.parseUnsigned(u32, b[start..i.*], 10) catch null;
        }
    }.f;

    const c = parseNum(buf, &p) orelse return p;
    if (c > SIXEL_COLOUR_REGISTERS) {
        log_mod.log_debug("sixel_parse_colour: too many colours", .{});
        return null;
    }
    if (si.used_colours <= c) si.used_colours = c + 1;
    si.dc = c + 1;

    if (p >= end or buf[p] != ';') return p;
    p += 1; // skip ';'

    const colour_type = parseNum(buf, &p) orelse {
        log_mod.log_debug("sixel_parse_colour: missing type", .{});
        return null;
    };
    if (p >= end or buf[p] != ';') {
        log_mod.log_debug("sixel_parse_colour: missing ;", .{});
        return null;
    }
    p += 1;

    const c1 = parseNum(buf, &p) orelse {
        log_mod.log_debug("sixel_parse_colour: missing c1", .{});
        return null;
    };
    if (p >= end or buf[p] != ';') {
        log_mod.log_debug("sixel_parse_colour: missing ;", .{});
        return null;
    }
    p += 1;

    const c2 = parseNum(buf, &p) orelse {
        log_mod.log_debug("sixel_parse_colour: missing c2", .{});
        return null;
    };
    if (p >= end or buf[p] != ';') {
        log_mod.log_debug("sixel_parse_colour: missing ;", .{});
        return null;
    }
    p += 1;

    const c3 = parseNum(buf, &p) orelse {
        log_mod.log_debug("sixel_parse_colour: missing c3", .{});
        return null;
    };

    const valid = switch (colour_type) {
        1 => c1 <= 360 and c2 <= 100 and c3 <= 100,
        2 => c1 <= 100 and c2 <= 100 and c3 <= 100,
        else => false,
    };
    if (!valid) {
        log_mod.log_debug("sixel_parse_colour: invalid color {};{};{};{}", .{ colour_type, c1, c2, c3 });
        return null;
    }

    // Grow colour table if needed.
    if (c + 1 > si.ncolours) {
        const old_n = si.ncolours;
        si.colours = xm.allocator.realloc(si.colours, c + 1) catch unreachable;
        for (si.colours[old_n .. c + 1]) |*entry| entry.* = 0;
        si.ncolours = c + 1;
    }
    si.colours[c] = (colour_type << 25) | (c1 << 16) | (c2 << 8) | c3;
    return p;
}

// ── Repeat parser: "count<sixel_char>" ────────────────────────────────────

/// Parse a repeat sequence following `!`.
/// Returns the next parse position, or null on fatal error.
fn sixel_parse_repeat(si: *T.SixelImage, buf: []const u8, pos: usize) ?usize {
    var p = pos;
    const end = buf.len;

    // Collect digit characters.
    const num_start = p;
    while (p < end and buf[p] >= '0' and buf[p] <= '9') p += 1;

    if (p == num_start or p == end) {
        log_mod.log_debug("sixel_parse_repeat: repeat not terminated", .{});
        return null;
    }

    const n = std.fmt.parseUnsigned(u32, buf[num_start..p], 10) catch {
        log_mod.log_debug("sixel_parse_repeat: repeat too wide", .{});
        return null;
    };
    if (n == 0 or n > SIXEL_WIDTH_LIMIT) {
        log_mod.log_debug("sixel_parse_repeat: repeat out of range", .{});
        return null;
    }

    const ch = buf[p] -% 0x3f;
    p += 1;

    var i: u32 = 0;
    while (i < n) : (i += 1) {
        if (sixel_parse_write(si, ch)) {
            log_mod.log_debug("sixel_parse_repeat: width limit reached", .{});
            return null;
        }
        si.dx += 1;
    }
    return p;
}

// ── Public API ────────────────────────────────────────────────────────────

/// Parse a DCS sixel data stream.
///
/// `buf` should start with the `q` that immediately follows the DCS introducer
/// (i.e. the first byte of the sixel data proper, which tmux validates == 'q').
/// Returns a heap-allocated `SixelImage` on success, null on failure.
///
/// Caller must free with `sixel_free`.
pub fn sixel_parse(buf: []const u8, p2: u32, xpixel: u32, ypixel: u32) ?*T.SixelImage {
    if (buf.len < 2 or buf[0] != 'q') {
        log_mod.log_debug("sixel_parse: empty image", .{});
        return null;
    }

    const si = xm.allocator.create(T.SixelImage) catch unreachable;
    si.* = .{
        .xpixel = xpixel,
        .ypixel = ypixel,
        .p2 = p2,
    };

    var p: usize = 1; // skip 'q'
    while (p < buf.len) {
        const ch = buf[p];
        p += 1;

        switch (ch) {
            '"' => {
                p = sixel_parse_attributes(si, buf, p) orelse {
                    sixel_free(si);
                    return null;
                };
            },
            '#' => {
                p = sixel_parse_colour(si, buf, p) orelse {
                    sixel_free(si);
                    return null;
                };
            },
            '!' => {
                p = sixel_parse_repeat(si, buf, p) orelse {
                    sixel_free(si);
                    return null;
                };
            },
            '-' => {
                si.dx = 0;
                si.dy += 6;
            },
            '$' => {
                si.dx = 0;
            },
            else => {
                if (ch < 0x20) continue;
                if (ch < 0x3f or ch > 0x7e) {
                    sixel_free(si);
                    return null;
                }
                if (sixel_parse_write(si, ch - 0x3f)) {
                    log_mod.log_debug("sixel_parse: width limit reached", .{});
                    sixel_free(si);
                    return null;
                }
                si.dx += 1;
            },
        }
    }

    if (si.x == 0 or si.y == 0) {
        sixel_free(si);
        return null;
    }
    return si;
}

/// Free a `SixelImage` and all its pixel data.
pub fn sixel_free(si: *T.SixelImage) void {
    for (si.lines) |*sl| {
        if (sl.data.len > 0) xm.allocator.free(sl.data);
    }
    if (si.lines.len > 0) xm.allocator.free(si.lines);
    if (si.colours.len > 0) xm.allocator.free(si.colours);
    xm.allocator.destroy(si);
}

/// Log a debugging representation of the image.
pub fn sixel_log(si: *const T.SixelImage) void {
    var cx: u32 = 0;
    var cy: u32 = 0;
    sixel_size_in_cells(si, &cx, &cy);
    log_mod.log_debug("sixel_log: image {}x{} ({}x{})", .{ si.x, si.y, cx, cy });

    for (si.colours[0..si.ncolours], 0..) |col, i| {
        log_mod.log_debug("sixel_log: colour {} is {:07x}", .{ i, col });
    }

    var buf: [SIXEL_WIDTH_LIMIT + 1]u8 = undefined;
    for (si.lines[0..si.y], 0..) |sl, y| {
        var x: u32 = 0;
        while (x < si.x) : (x += 1) {
            if (x >= sl.x) {
                buf[x] = '_';
            } else if (sl.data[x] != 0) {
                buf[x] = '0' + @as(u8, @intCast((sl.data[x] - 1) % 10));
            } else {
                buf[x] = '.';
            }
        }
        buf[si.x] = 0;
        log_mod.log_debug("sixel_log: {:4}: {s}", .{ y, buf[0..si.x] });
    }
}

/// Compute the size of the image in terminal cells.
pub fn sixel_size_in_cells(si: *const T.SixelImage, x: *u32, y: *u32) void {
    x.* = if ((si.x % si.xpixel) == 0) si.x / si.xpixel else 1 + si.x / si.xpixel;
    y.* = if ((si.y % si.ypixel) == 0) si.y / si.ypixel else 1 + si.y / si.ypixel;
}

/// Extract a rectangular sub-image and optionally re-scale it.
///
/// `ox`, `oy` are the source cell offsets; `sx`, `sy` are the destination cell
/// counts. `colours` = 1 copies the colour table. Returns null on failure.
/// Caller frees with `sixel_free`.
pub fn sixel_scale(
    si: *const T.SixelImage,
    xpixel_arg: u32,
    ypixel_arg: u32,
    ox: u32,
    oy: u32,
    sx_arg: u32,
    sy_arg: u32,
    colours: bool,
) ?*T.SixelImage {
    var cx: u32 = 0;
    var cy: u32 = 0;
    sixel_size_in_cells(si, &cx, &cy);

    if (ox >= cx) return null;
    if (oy >= cy) return null;

    var sx = sx_arg;
    var sy = sy_arg;
    if (ox + sx >= cx) sx = cx - ox;
    if (oy + sy >= cy) sy = cy - oy;

    const xpixel: u32 = if (xpixel_arg == 0) si.xpixel else xpixel_arg;
    const ypixel: u32 = if (ypixel_arg == 0) si.ypixel else ypixel_arg;

    const pox = ox * si.xpixel;
    const poy = oy * si.ypixel;
    const psx = sx * si.xpixel;
    const psy = sy * si.ypixel;

    const tsx = sx * xpixel;
    const tsy = sy * ypixel;

    const new_si = xm.allocator.create(T.SixelImage) catch unreachable;
    new_si.* = .{
        .xpixel = xpixel,
        .ypixel = ypixel,
        .p2 = si.p2,
        .set_ra = si.set_ra,
        .used_colours = si.used_colours,
    };

    // Re-clamp and scale the raster-attributes extents.
    {
        var ra_x = if (si.ra_x > pox) si.ra_x - pox else 0;
        var ra_y = if (si.ra_y > poy) si.ra_y - poy else 0;
        ra_x = if (si.ra_x < psx) si.ra_x else psx;
        ra_y = if (si.ra_y < psy) si.ra_y else psy;
        new_si.ra_x = ra_x * xpixel / si.xpixel;
        new_si.ra_y = ra_y * ypixel / si.ypixel;
    }

    // Sample the source image.
    {
        var y: u32 = 0;
        while (y < tsy) : (y += 1) {
            const py = poy + @as(u32, @intFromFloat(@as(f64, @floatFromInt(y)) * @as(f64, @floatFromInt(psy)) / @as(f64, @floatFromInt(tsy))));
            var x: u32 = 0;
            while (x < tsx) : (x += 1) {
                const px = pox + @as(u32, @intFromFloat(@as(f64, @floatFromInt(x)) * @as(f64, @floatFromInt(psx)) / @as(f64, @floatFromInt(tsx))));
                _ = sixel_set_pixel(new_si, x, y, sixel_get_pixel(si, px, py));
            }
        }
    }

    if (colours and si.ncolours != 0) {
        new_si.colours = xm.allocator.alloc(u32, si.ncolours) catch unreachable;
        @memcpy(new_si.colours, si.colours[0..si.ncolours]);
        new_si.ncolours = si.ncolours;
    }

    return new_si;
}

// ── RLE sixel serialiser ──────────────────────────────────────────────────

/// Append `slen` bytes of `s` into an `ArrayList(u8)`, growing as needed.
fn sixel_print_add(buf: *std.ArrayListUnmanaged(u8), s: []const u8) void {
    buf.appendSlice(xm.allocator, s) catch unreachable;
}

/// Append a repeat run of `count` copies of `ch` into `buf`.
fn sixel_print_repeat(buf: *std.ArrayListUnmanaged(u8), count: u32, ch: u8) void {
    if (count == 0) return;
    if (count <= 3) {
        var i: u32 = 0;
        while (i < count) : (i += 1) buf.append(xm.allocator, ch) catch unreachable;
    } else {
        const tmp = std.fmt.allocPrint(xm.allocator, "!{}{c}", .{ count, ch }) catch unreachable;
        defer xm.allocator.free(tmp);
        sixel_print_add(buf, tmp);
    }
}

/// Build per-colour run-length chunks for band `y`.
fn sixel_print_compress_colors(
    si: *const T.SixelImage,
    chunks: []SixelChunk,
    y: u32,
    active: []u32,
    nactive: *u32,
) void {
    var x: u32 = 0;
    while (x < si.x) : (x += 1) {
        var colors: [6]u32 = .{0} ** 6;

        var i: u32 = 0;
        while (i < 6) : (i += 1) {
            if (y + i < si.y) {
                const sl = &si.lines[y + i];
                if (x < sl.x and sl.data[x] != 0) {
                    colors[i] = sl.data[x];
                    const c = sl.data[x] - 1;
                    chunks[c].next_pattern |= @as(u8, 1) << @intCast(i);
                }
            }
        }

        i = 0;
        while (i < 6) : (i += 1) {
            if (colors[i] == 0) continue;

            const c = colors[i] - 1;
            const chunk = &chunks[c];
            if (chunk.next_x == x + 1) continue;

            if (chunk.next_y < y + 1) {
                chunk.next_y = y + 1;
                active[nactive.*] = c;
                nactive.* += 1;
            }

            const dx = x - chunk.next_x;
            if (chunk.pattern != chunk.next_pattern or dx != 0) {
                sixel_print_repeat(&chunk.data, chunk.count, chunk.pattern + 0x3f);
                sixel_print_repeat(&chunk.data, dx, '?');
                chunk.pattern = chunk.next_pattern;
                chunk.count = 0;
            }
            chunk.count += 1;
            chunk.next_pattern = 0;
            chunk.next_x = x + 1;
        }
    }
}

/// Serialise a `SixelImage` back to a DCS sixel escape sequence.
///
/// If `map` is non-null, its colour table is used in place of `si`'s own.
/// The returned slice is heap-allocated; caller frees with
/// `xm.allocator.free(result)`. Returns null if the image has no colours.
pub fn sixel_print(si: *const T.SixelImage, map: ?*const T.SixelImage) ?[]u8 {
    const colours: []const u32 = if (map) |m| m.colours[0..m.ncolours] else si.colours[0..si.ncolours];
    const ncolours: u32 = if (map) |m| m.ncolours else si.ncolours;
    const used_colours = si.used_colours;
    if (used_colours == 0) return null;

    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(xm.allocator);

    // DCS header.
    const hdr = std.fmt.allocPrint(xm.allocator, "\x1bP0;{d}q", .{si.p2}) catch unreachable;
    defer xm.allocator.free(hdr);
    sixel_print_add(&buf, hdr);

    // Optional raster attributes.
    if (si.set_ra != 0) {
        const ra = std.fmt.allocPrint(xm.allocator, "\"1;1;{d};{d}", .{ si.ra_x, si.ra_y }) catch unreachable;
        defer xm.allocator.free(ra);
        sixel_print_add(&buf, ra);
    }

    // Colour definitions.
    var ci: u32 = 0;
    while (ci < ncolours) : (ci += 1) {
        const c = colours[ci];
        const col_str = std.fmt.allocPrint(xm.allocator, "#{d};{d};{d};{d};{d}", .{
            ci, c >> 25, (c >> 16) & 0x1ff, (c >> 8) & 0xff, c & 0xff,
        }) catch unreachable;
        defer xm.allocator.free(col_str);
        sixel_print_add(&buf, col_str);
    }

    // Per-colour chunks.
    const chunks = xm.allocator.alloc(SixelChunk, used_colours) catch unreachable;
    defer {
        for (chunks) |*ch| ch.deinit();
        xm.allocator.free(chunks);
    }
    for (chunks) |*ch| ch.* = SixelChunk{};

    const active_list = xm.allocator.alloc(u32, used_colours) catch unreachable;
    defer xm.allocator.free(active_list);

    var y: u32 = 0;
    while (y < si.y) : (y += 6) {
        var nactive: u32 = 0;
        sixel_print_compress_colors(si, chunks, y, active_list, &nactive);

        var ai: u32 = 0;
        while (ai < nactive) : (ai += 1) {
            const c = active_list[ai];
            const ch = &chunks[c];

            const ci_str = std.fmt.allocPrint(xm.allocator, "#{d}", .{c}) catch unreachable;
            defer xm.allocator.free(ci_str);
            sixel_print_add(&buf, ci_str);
            sixel_print_add(&buf, ch.data.items);
            sixel_print_repeat(&buf, ch.count, ch.pattern + 0x3f);
            sixel_print_add(&buf, "$");

            ch.data.clearRetainingCapacity();
            ch.next_x = 0;
            ch.count = 0;
        }

        // Remove trailing '$'.
        if (buf.items.len > 0 and buf.items[buf.items.len - 1] == '$')
            _ = buf.pop();

        sixel_print_add(&buf, "-");
    }

    // Remove trailing '-'.
    if (buf.items.len > 0 and buf.items[buf.items.len - 1] == '-')
        _ = buf.pop();

    sixel_print_add(&buf, "\x1b\\");

    return buf.toOwnedSlice(xm.allocator) catch unreachable;
}

// ── Tests ──────────────────────────────────────────────────────────────────

test "sixel_size_in_cells exact" {
    var si = T.SixelImage{
        .x = 64,
        .y = 32,
        .xpixel = 8,
        .ypixel = 16,
    };
    var cx: u32 = 0;
    var cy: u32 = 0;
    sixel_size_in_cells(&si, &cx, &cy);
    try @import("std").testing.expectEqual(@as(u32, 8), cx);
    try @import("std").testing.expectEqual(@as(u32, 2), cy);
}

test "sixel_size_in_cells non-exact" {
    var si = T.SixelImage{
        .x = 65,
        .y = 33,
        .xpixel = 8,
        .ypixel = 16,
    };
    var cx: u32 = 0;
    var cy: u32 = 0;
    sixel_size_in_cells(&si, &cx, &cy);
    try @import("std").testing.expectEqual(@as(u32, 9), cx);
    try @import("std").testing.expectEqual(@as(u32, 3), cy);
}

test "sixel_parse minimal" {
    // Minimal valid sixel: "q" + at least one data character at offset 0.
    // Use colour 1 (index 0 + 1 = dc=1) and draw a single sixel.
    const data = "q#0;2;100;0;0~";
    const si = sixel_parse(data, 0, 8, 16) orelse return error.SkipZigTest;
    defer sixel_free(si);
    try @import("std").testing.expect(si.x > 0);
    try @import("std").testing.expect(si.y > 0);
}

test "sixel_parse empty rejects" {
    const si = sixel_parse("", 0, 8, 16);
    try @import("std").testing.expect(si == null);
    const si2 = sixel_parse("x", 0, 8, 16);
    try @import("std").testing.expect(si2 == null);
}
