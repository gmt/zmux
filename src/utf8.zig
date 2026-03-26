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
// Ported in part from tmux/utf8.c.
// Original copyright:
//   Copyright (c) 2008 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

const std = @import("std");
const T = @import("types.zig");
const c = @import("c.zig");
const opts = @import("options.zig");
const xm = @import("xmalloc.zig");

const WChar = c.posix_sys.wchar_t;

const Utf8Item = struct {
    index: u32,
    size: u8,
    data: [T.UTF8_SIZE]u8,
};

const WidthCacheItem = struct {
    wc: u32,
    width: u8,
};

const default_width_cache = [_]WidthCacheItem{
    .{ .wc = 0x0261D, .width = 2 },
    .{ .wc = 0x026F9, .width = 2 },
    .{ .wc = 0x0270A, .width = 2 },
    .{ .wc = 0x0270B, .width = 2 },
    .{ .wc = 0x0270C, .width = 2 },
    .{ .wc = 0x0270D, .width = 2 },
    .{ .wc = 0x1F1E6, .width = 1 },
    .{ .wc = 0x1F1E7, .width = 1 },
    .{ .wc = 0x1F1E8, .width = 1 },
    .{ .wc = 0x1F1E9, .width = 1 },
    .{ .wc = 0x1F1EA, .width = 1 },
    .{ .wc = 0x1F1EB, .width = 1 },
    .{ .wc = 0x1F1EC, .width = 1 },
    .{ .wc = 0x1F1ED, .width = 1 },
    .{ .wc = 0x1F1EE, .width = 1 },
    .{ .wc = 0x1F1EF, .width = 1 },
    .{ .wc = 0x1F1F0, .width = 1 },
    .{ .wc = 0x1F1F1, .width = 1 },
    .{ .wc = 0x1F1F2, .width = 1 },
    .{ .wc = 0x1F1F3, .width = 1 },
    .{ .wc = 0x1F1F4, .width = 1 },
    .{ .wc = 0x1F1F5, .width = 1 },
    .{ .wc = 0x1F1F6, .width = 1 },
    .{ .wc = 0x1F1F7, .width = 1 },
    .{ .wc = 0x1F1F8, .width = 1 },
    .{ .wc = 0x1F1F9, .width = 1 },
    .{ .wc = 0x1F1FA, .width = 1 },
    .{ .wc = 0x1F1FB, .width = 1 },
    .{ .wc = 0x1F1FC, .width = 1 },
    .{ .wc = 0x1F1FD, .width = 1 },
    .{ .wc = 0x1F1FE, .width = 1 },
    .{ .wc = 0x1F1FF, .width = 1 },
    .{ .wc = 0x1F385, .width = 2 },
    .{ .wc = 0x1F3C2, .width = 2 },
    .{ .wc = 0x1F3C3, .width = 2 },
    .{ .wc = 0x1F3C4, .width = 2 },
    .{ .wc = 0x1F3C7, .width = 2 },
    .{ .wc = 0x1F3CA, .width = 2 },
    .{ .wc = 0x1F3CB, .width = 2 },
    .{ .wc = 0x1F3CC, .width = 2 },
    .{ .wc = 0x1F3FB, .width = 2 },
    .{ .wc = 0x1F3FC, .width = 2 },
    .{ .wc = 0x1F3FD, .width = 2 },
    .{ .wc = 0x1F3FE, .width = 2 },
    .{ .wc = 0x1F3FF, .width = 2 },
    .{ .wc = 0x1F442, .width = 2 },
    .{ .wc = 0x1F443, .width = 2 },
    .{ .wc = 0x1F446, .width = 2 },
    .{ .wc = 0x1F447, .width = 2 },
    .{ .wc = 0x1F448, .width = 2 },
    .{ .wc = 0x1F449, .width = 2 },
    .{ .wc = 0x1F44A, .width = 2 },
    .{ .wc = 0x1F44B, .width = 2 },
    .{ .wc = 0x1F44C, .width = 2 },
    .{ .wc = 0x1F44D, .width = 2 },
    .{ .wc = 0x1F44E, .width = 2 },
    .{ .wc = 0x1F44F, .width = 2 },
    .{ .wc = 0x1F450, .width = 2 },
    .{ .wc = 0x1F466, .width = 2 },
    .{ .wc = 0x1F467, .width = 2 },
    .{ .wc = 0x1F468, .width = 2 },
    .{ .wc = 0x1F469, .width = 2 },
    .{ .wc = 0x1F46B, .width = 2 },
    .{ .wc = 0x1F46C, .width = 2 },
    .{ .wc = 0x1F46D, .width = 2 },
    .{ .wc = 0x1F46E, .width = 2 },
    .{ .wc = 0x1F470, .width = 2 },
    .{ .wc = 0x1F471, .width = 2 },
    .{ .wc = 0x1F472, .width = 2 },
    .{ .wc = 0x1F473, .width = 2 },
    .{ .wc = 0x1F474, .width = 2 },
    .{ .wc = 0x1F475, .width = 2 },
    .{ .wc = 0x1F476, .width = 2 },
    .{ .wc = 0x1F477, .width = 2 },
    .{ .wc = 0x1F478, .width = 2 },
    .{ .wc = 0x1F47C, .width = 2 },
    .{ .wc = 0x1F481, .width = 2 },
    .{ .wc = 0x1F482, .width = 2 },
    .{ .wc = 0x1F483, .width = 2 },
    .{ .wc = 0x1F485, .width = 2 },
    .{ .wc = 0x1F486, .width = 2 },
    .{ .wc = 0x1F487, .width = 2 },
    .{ .wc = 0x1F48F, .width = 2 },
    .{ .wc = 0x1F491, .width = 2 },
    .{ .wc = 0x1F4AA, .width = 2 },
    .{ .wc = 0x1F574, .width = 2 },
    .{ .wc = 0x1F575, .width = 2 },
    .{ .wc = 0x1F57A, .width = 2 },
    .{ .wc = 0x1F590, .width = 2 },
    .{ .wc = 0x1F595, .width = 2 },
    .{ .wc = 0x1F596, .width = 2 },
    .{ .wc = 0x1F645, .width = 2 },
    .{ .wc = 0x1F646, .width = 2 },
    .{ .wc = 0x1F647, .width = 2 },
    .{ .wc = 0x1F64B, .width = 2 },
    .{ .wc = 0x1F64C, .width = 2 },
    .{ .wc = 0x1F64D, .width = 2 },
    .{ .wc = 0x1F64E, .width = 2 },
    .{ .wc = 0x1F64F, .width = 2 },
    .{ .wc = 0x1F6A3, .width = 2 },
    .{ .wc = 0x1F6B4, .width = 2 },
    .{ .wc = 0x1F6B5, .width = 2 },
    .{ .wc = 0x1F6B6, .width = 2 },
    .{ .wc = 0x1F6C0, .width = 2 },
    .{ .wc = 0x1F6CC, .width = 2 },
    .{ .wc = 0x1F90C, .width = 2 },
    .{ .wc = 0x1F90F, .width = 2 },
    .{ .wc = 0x1F918, .width = 2 },
    .{ .wc = 0x1F919, .width = 2 },
    .{ .wc = 0x1F91A, .width = 2 },
    .{ .wc = 0x1F91B, .width = 2 },
    .{ .wc = 0x1F91C, .width = 2 },
    .{ .wc = 0x1F91D, .width = 2 },
    .{ .wc = 0x1F91E, .width = 2 },
    .{ .wc = 0x1F91F, .width = 2 },
    .{ .wc = 0x1F926, .width = 2 },
    .{ .wc = 0x1F930, .width = 2 },
    .{ .wc = 0x1F931, .width = 2 },
    .{ .wc = 0x1F932, .width = 2 },
    .{ .wc = 0x1F933, .width = 2 },
    .{ .wc = 0x1F934, .width = 2 },
    .{ .wc = 0x1F935, .width = 2 },
    .{ .wc = 0x1F936, .width = 2 },
    .{ .wc = 0x1F937, .width = 2 },
    .{ .wc = 0x1F938, .width = 2 },
    .{ .wc = 0x1F939, .width = 2 },
    .{ .wc = 0x1F93D, .width = 2 },
    .{ .wc = 0x1F93E, .width = 2 },
    .{ .wc = 0x1F977, .width = 2 },
    .{ .wc = 0x1F9B5, .width = 2 },
    .{ .wc = 0x1F9B6, .width = 2 },
    .{ .wc = 0x1F9B8, .width = 2 },
    .{ .wc = 0x1F9B9, .width = 2 },
    .{ .wc = 0x1F9BB, .width = 2 },
    .{ .wc = 0x1F9CD, .width = 2 },
    .{ .wc = 0x1F9CE, .width = 2 },
    .{ .wc = 0x1F9CF, .width = 2 },
    .{ .wc = 0x1F9D1, .width = 2 },
    .{ .wc = 0x1F9D2, .width = 2 },
    .{ .wc = 0x1F9D3, .width = 2 },
    .{ .wc = 0x1F9D4, .width = 2 },
    .{ .wc = 0x1F9D5, .width = 2 },
    .{ .wc = 0x1F9D6, .width = 2 },
    .{ .wc = 0x1F9D7, .width = 2 },
    .{ .wc = 0x1F9D8, .width = 2 },
    .{ .wc = 0x1F9D9, .width = 2 },
    .{ .wc = 0x1F9DA, .width = 2 },
    .{ .wc = 0x1F9DB, .width = 2 },
    .{ .wc = 0x1F9DC, .width = 2 },
    .{ .wc = 0x1F9DD, .width = 2 },
    .{ .wc = 0x1FAC3, .width = 2 },
    .{ .wc = 0x1FAC4, .width = 2 },
    .{ .wc = 0x1FAC5, .width = 2 },
    .{ .wc = 0x1FAF0, .width = 2 },
    .{ .wc = 0x1FAF1, .width = 2 },
    .{ .wc = 0x1FAF2, .width = 2 },
    .{ .wc = 0x1FAF3, .width = 2 },
    .{ .wc = 0x1FAF4, .width = 2 },
    .{ .wc = 0x1FAF5, .width = 2 },
    .{ .wc = 0x1FAF6, .width = 2 },
    .{ .wc = 0x1FAF7, .width = 2 },
    .{ .wc = 0x1FAF8, .width = 2 },
};

var utf8_items: std.ArrayList(Utf8Item) = .{};
var utf8_width_cache: std.ArrayList(WidthCacheItem) = .{};
var utf8_next_index: u32 = 0;
var locale_ready = false;
var utf8_no_width = false;
var utf8_width_cache_ready = false;

pub const VIS_OCTAL: u32 = 0x01;
pub const VIS_CSTYLE: u32 = 0x02;
pub const VIS_SP: u32 = 0x04;
pub const VIS_TAB: u32 = 0x08;
pub const VIS_NL: u32 = 0x10;
pub const VIS_SAFE: u32 = 0x20;
pub const VIS_NOSLASH: u32 = 0x40;
pub const VIS_GLOB: u32 = 0x100;
pub const VIS_DQ: u32 = 0x200;
pub const VIS_ALL: u32 = 0x400;

pub fn utf8_update_width_cache() void {
    resetWidthCache();
    for (opts.options_get_array(opts.global_options, "codepoint-widths")) |entry| {
        utf8_add_to_width_cache(entry);
    }
}

pub fn utf8_from_data(ud: *const T.Utf8Data, uc: *T.utf8_char) T.Utf8State {
    if (ud.width > 2 or ud.size > T.UTF8_SIZE) return utf8PackFailure(ud, uc);

    const index: u32 = if (ud.size <= 3)
        (@as(u32, ud.data[2]) << 16) | (@as(u32, ud.data[1]) << 8) | @as(u32, ud.data[0])
    else
        putUtf8Item(ud.data[0..ud.size]) orelse return utf8PackFailure(ud, uc);

    uc.* = utf8SetSize(ud.size) | utf8SetWidth(ud.width) | index;
    return .done;
}

pub fn utf8_to_data(uc: T.utf8_char, ud: *T.Utf8Data) void {
    ud.* = std.mem.zeroes(T.Utf8Data);
    ud.size = utf8GetSize(uc);
    ud.have = ud.size;
    ud.width = utf8GetWidth(uc);

    if (ud.size == 0) return;

    if (ud.size <= 3) {
        ud.data[2] = @intCast((uc >> 16) & 0xff);
        ud.data[1] = @intCast((uc >> 8) & 0xff);
        ud.data[0] = @intCast(uc & 0xff);
        return;
    }

    if (findUtf8ItemByIndex(@intCast(uc & 0x00ff_ffff))) |item| {
        @memcpy(ud.data[0..item.size], item.data[0..item.size]);
    } else {
        @memset(ud.data[0..ud.size], ' ');
    }
}

pub fn utf8_build_one(ch: u8) T.utf8_char {
    return utf8SetSize(1) | utf8SetWidth(1) | ch;
}

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

pub fn utf8_towc(ud: *const T.Utf8Data, wc: *WChar) T.Utf8State {
    if (ud.size == 0 or ud.size > T.UTF8_SIZE) return .@"error";
    const cp = std.unicode.utf8Decode(ud.data[0..ud.size]) catch return .@"error";
    wc.* = @intCast(cp);
    return .done;
}

pub fn utf8_fromwc(wc: WChar, ud: *T.Utf8Data) T.Utf8State {
    const cp = wcharToCodepoint(wc) orelse return .@"error";

    ud.* = std.mem.zeroes(T.Utf8Data);
    const size = std.unicode.utf8Encode(cp, ud.data[0..]) catch return .@"error";
    ud.size = @intCast(size);
    ud.have = ud.size;

    var width: u8 = 0;
    if (utf8Width(ud, &width) != .done) return .@"error";
    ud.width = width;
    return .done;
}

pub fn utf8_open(ud: *T.Utf8Data, ch: u8) T.Utf8State {
    ud.* = std.mem.zeroes(T.Utf8Data);
    if (ch >= 0xc2 and ch <= 0xdf) {
        ud.size = 2;
    } else if (ch >= 0xe0 and ch <= 0xef) {
        ud.size = 3;
    } else if (ch >= 0xf0 and ch <= 0xf4) {
        ud.size = 4;
    } else {
        return .@"error";
    }
    _ = utf8_append(ud, ch);
    return .more;
}

pub fn utf8_append(ud: *T.Utf8Data, ch: u8) T.Utf8State {
    if (ud.have >= ud.size or ud.size > T.UTF8_SIZE) return .@"error";

    if (ud.have != 0 and (ch & 0xc0) != 0x80) ud.width = 0xff;

    ud.data[ud.have] = ch;
    ud.have += 1;
    if (ud.have != ud.size) return .more;

    if (!utf8_no_width) {
        var width: u8 = 0;
        if (ud.width == 0xff) return .@"error";
        if (utf8Width(ud, &width) != .done) return .@"error";
        ud.width = width;
    }
    return .done;
}

pub fn utf8_strvis(src: []const u8, flag: u32) []u8 {
    return utf8_stravisx(src, flag);
}

pub fn utf8_stravis(src: []const u8, flag: u32) []u8 {
    return utf8_stravisx(src, flag);
}

pub fn utf8_strvisx(src: []const u8, flag: u32) []u8 {
    return utf8_stravisx(src, flag);
}

pub fn utf8_stravisx(src: []const u8, flag: u32) []u8 {
    var out: std.ArrayList(u8) = .{};

    var pos: usize = 0;
    while (pos < src.len) {
        const start = pos;
        var ud: T.Utf8Data = undefined;
        if (utf8_open(&ud, src[pos]) == .more) {
            pos += 1;
            var state: T.Utf8State = .more;
            while (pos < src.len and state == .more) : (pos += 1) {
                state = utf8_append(&ud, src[pos]);
            }
            if (state == .done) {
                out.appendSlice(xm.allocator, ud.data[0..ud.size]) catch unreachable;
                continue;
            }
            pos = start;
        }

        if ((flag & VIS_DQ) != 0 and src[pos] == '$' and pos + 1 < src.len) {
            const next = src[pos + 1];
            if (std.ascii.isAlphabetic(next) or next == '_' or next == '{') {
                out.append(xm.allocator, '\\') catch unreachable;
                out.append(xm.allocator, '$') catch unreachable;
                pos += 1;
                continue;
            }
        }

        const nextc: u8 = if (pos + 1 < src.len) src[pos + 1] else 0;
        appendVisByte(&out, src[pos], flag, nextc);
        pos += 1;
    }

    return out.toOwnedSlice(xm.allocator) catch unreachable;
}

pub fn utf8_isvalid(s: []const u8) bool {
    var pos: usize = 0;
    while (pos < s.len) {
        var ud: T.Utf8Data = undefined;
        if (utf8_open(&ud, s[pos]) == .more) {
            pos += 1;
            var state: T.Utf8State = .more;
            while (pos < s.len and state == .more) : (pos += 1) {
                state = utf8_append(&ud, s[pos]);
            }
            if (state == .done) continue;
            return false;
        }
        if (s[pos] < 0x20 or s[pos] > 0x7e) return false;
        pos += 1;
    }
    return true;
}

pub fn utf8_sanitize(src: []const u8) []u8 {
    var out: std.ArrayList(u8) = .{};

    var pos: usize = 0;
    while (pos < src.len) {
        const start = pos;
        var ud: T.Utf8Data = undefined;
        if (utf8_open(&ud, src[pos]) == .more) {
            pos += 1;
            var state: T.Utf8State = .more;
            while (pos < src.len and state == .more) : (pos += 1) {
                state = utf8_append(&ud, src[pos]);
            }
            if (state == .done) {
                for (0..ud.width) |_| out.append(xm.allocator, '_') catch unreachable;
                continue;
            }
            pos = start;
        }

        out.append(xm.allocator, if (src[pos] > 0x1f and src[pos] < 0x7f) src[pos] else '_') catch unreachable;
        pos += 1;
    }

    return out.toOwnedSlice(xm.allocator) catch unreachable;
}

pub fn utf8_strlen(s: []const T.Utf8Data) usize {
    var i: usize = 0;
    while (i < s.len and s[i].size != 0) : (i += 1) {}
    return i;
}

pub fn utf8_strwidth(s: []const T.Utf8Data, n: isize) u32 {
    var width: u32 = 0;
    var i: usize = 0;
    while (i < s.len and s[i].size != 0) : (i += 1) {
        if (n != -1 and @as(isize, @intCast(i)) == n) break;
        width += s[i].width;
    }
    return width;
}

pub fn utf8_fromcstr(src: []const u8) []T.Utf8Data {
    var out: std.ArrayList(T.Utf8Data) = .{};
    var pos: usize = 0;

    while (pos < src.len) {
        const start = pos;
        var ud: T.Utf8Data = undefined;
        if (utf8_open(&ud, src[pos]) == .more) {
            pos += 1;
            var state: T.Utf8State = .more;
            while (pos < src.len and state == .more) : (pos += 1) {
                state = utf8_append(&ud, src[pos]);
            }
            if (state == .done) {
                out.append(xm.allocator, ud) catch unreachable;
                continue;
            }
            pos = start;
        }

        utf8_set(&ud, src[pos]);
        out.append(xm.allocator, ud) catch unreachable;
        pos += 1;
    }

    out.append(xm.allocator, std.mem.zeroes(T.Utf8Data)) catch unreachable;
    return out.toOwnedSlice(xm.allocator) catch unreachable;
}

pub fn utf8_tocstr(src: []const T.Utf8Data) []u8 {
    var size: usize = 0;
    for (src) |ud| {
        if (ud.size == 0) break;
        size += ud.size;
    }

    const out = xm.allocator.alloc(u8, size) catch unreachable;
    var pos: usize = 0;
    for (src) |ud| {
        if (ud.size == 0) break;
        @memcpy(out[pos .. pos + ud.size], ud.data[0..ud.size]);
        pos += ud.size;
    }
    return out;
}

pub fn utf8_cstrwidth(s: []const u8) u32 {
    var width: u32 = 0;
    var pos: usize = 0;

    while (pos < s.len) {
        const start = pos;
        var ud: T.Utf8Data = undefined;
        if (utf8_open(&ud, s[pos]) == .more) {
            pos += 1;
            var state: T.Utf8State = .more;
            while (pos < s.len and state == .more) : (pos += 1) {
                state = utf8_append(&ud, s[pos]);
            }
            if (state == .done) {
                width += ud.width;
                continue;
            }
            pos = start;
        }

        if (s[pos] > 0x1f and s[pos] != 0x7f) width += 1;
        pos += 1;
    }
    return width;
}

pub fn utf8_trim_left(s: []const u8, limit: u32) []u8 {
    if (limit == 0 or s.len == 0) return xm.xstrdup("");

    var out: std.ArrayList(u8) = .{};
    var width: u32 = 0;
    var pos: usize = 0;

    while (pos < s.len and width < limit) {
        const start = pos;
        var ud: T.Utf8Data = undefined;
        if (utf8_open(&ud, s[pos]) == .more) {
            pos += 1;
            var state: T.Utf8State = .more;
            while (pos < s.len and state == .more) : (pos += 1) {
                state = utf8_append(&ud, s[pos]);
            }
            if (state == .done) {
                if (width + ud.width > limit) break;
                out.appendSlice(xm.allocator, s[start..pos]) catch unreachable;
                width += ud.width;
                continue;
            }
            pos = start;
        }

        if (s[pos] > 0x1f and s[pos] != 0x7f) {
            if (width + 1 > limit) break;
            out.append(xm.allocator, s[pos]) catch unreachable;
            width += 1;
        }
        pos += 1;
    }

    return out.toOwnedSlice(xm.allocator) catch unreachable;
}

pub fn utf8_trim_right(s: []const u8, limit: u32) []u8 {
    if (limit == 0 or s.len == 0) return xm.xstrdup("");

    const total_width = utf8_cstrwidth(s);
    if (total_width <= limit) return xm.xstrdup(s);

    const skip = total_width - limit;
    var out: std.ArrayList(u8) = .{};
    var width: u32 = 0;
    var pos: usize = 0;

    while (pos < s.len) {
        const start = pos;
        var ud: T.Utf8Data = undefined;
        if (utf8_open(&ud, s[pos]) == .more) {
            pos += 1;
            var state: T.Utf8State = .more;
            while (pos < s.len and state == .more) : (pos += 1) {
                state = utf8_append(&ud, s[pos]);
            }
            if (state == .done) {
                if (width >= skip) out.appendSlice(xm.allocator, s[start..pos]) catch unreachable;
                width += ud.width;
                continue;
            }
            pos = start;
        }

        if (s[pos] > 0x1f and s[pos] != 0x7f) {
            if (width >= skip) out.append(xm.allocator, s[pos]) catch unreachable;
            width += 1;
        }
        pos += 1;
    }

    return out.toOwnedSlice(xm.allocator) catch unreachable;
}

pub fn utf8_padcstr(s: []const u8, width: u32) []u8 {
    const current = utf8_cstrwidth(s);
    if (current >= width) return xm.xstrdup(s);

    const extra = width - current;
    const out = xm.allocator.alloc(u8, s.len + extra) catch unreachable;
    @memcpy(out[0..s.len], s);
    @memset(out[s.len..], ' ');
    return out;
}

pub fn utf8_rpadcstr(s: []const u8, width: u32) []u8 {
    const current = utf8_cstrwidth(s);
    if (current >= width) return xm.xstrdup(s);

    const extra = width - current;
    const out = xm.allocator.alloc(u8, s.len + extra) catch unreachable;
    @memset(out[0..extra], ' ');
    @memcpy(out[extra .. extra + s.len], s);
    return out;
}

pub fn utf8_cstrhas(s: []const u8, ud: *const T.Utf8Data) bool {
    const copy = utf8_fromcstr(s);
    defer xm.allocator.free(copy);

    for (copy) |item| {
        if (item.size == 0) break;
        if (item.size != ud.size) continue;
        if (std.mem.eql(u8, item.data[0..item.size], ud.data[0..ud.size])) return true;
    }
    return false;
}

fn utf8PackFailure(ud: *const T.Utf8Data, uc: *T.utf8_char) T.Utf8State {
    if (ud.width == 0)
        uc.* = utf8SetSize(0) | utf8SetWidth(0)
    else if (ud.width == 1)
        uc.* = utf8SetSize(1) | utf8SetWidth(1) | 0x20
    else
        uc.* = utf8SetSize(1) | utf8SetWidth(1) | 0x2020;
    return .@"error";
}

fn appendVisByte(out: *std.ArrayList(u8), ch: u8, flag: u32, nextc: u8) void {
    if (isVisVisible(ch, flag)) {
        if ((ch == '"' and (flag & VIS_DQ) != 0) or (ch == '\\' and (flag & VIS_NOSLASH) == 0))
            out.append(xm.allocator, '\\') catch unreachable;
        out.append(xm.allocator, ch) catch unreachable;
        return;
    }

    if ((flag & VIS_CSTYLE) != 0) {
        switch (ch) {
            '\n' => return out.appendSlice(xm.allocator, "\\n") catch unreachable,
            '\r' => return out.appendSlice(xm.allocator, "\\r") catch unreachable,
            0x08 => return out.appendSlice(xm.allocator, "\\b") catch unreachable,
            0x07 => return out.appendSlice(xm.allocator, "\\a") catch unreachable,
            0x0b => return out.appendSlice(xm.allocator, "\\v") catch unreachable,
            '\t' => return out.appendSlice(xm.allocator, "\\t") catch unreachable,
            0x0c => return out.appendSlice(xm.allocator, "\\f") catch unreachable,
            ' ' => return out.appendSlice(xm.allocator, "\\s") catch unreachable,
            0 => {
                out.appendSlice(xm.allocator, "\\0") catch unreachable;
                if (isOctal(nextc))
                    out.appendSlice(xm.allocator, "00") catch unreachable;
                return;
            },
            else => {},
        }
    }

    const glob_magic = ch == '*' or ch == '?' or ch == '[' or ch == '#';
    if ((ch & 0x7f) == ' ' or (flag & VIS_OCTAL) != 0 or ((flag & VIS_GLOB) != 0 and glob_magic)) {
        out.append(xm.allocator, '\\') catch unreachable;
        out.append(xm.allocator, '0' + ((ch >> 6) & 0x07)) catch unreachable;
        out.append(xm.allocator, '0' + ((ch >> 3) & 0x07)) catch unreachable;
        out.append(xm.allocator, '0' + (ch & 0x07)) catch unreachable;
        return;
    }

    if ((flag & VIS_NOSLASH) == 0)
        out.append(xm.allocator, '\\') catch unreachable;

    if ((ch & 0x80) != 0) {
        out.append(xm.allocator, 'M') catch unreachable;
        appendMetaOrControl(out, ch & 0x7f);
        return;
    }

    appendMetaOrControl(out, ch);
}

fn appendMetaOrControl(out: *std.ArrayList(u8), ch: u8) void {
    if (std.ascii.isControl(ch) or ch == 0x7f) {
        out.append(xm.allocator, '^') catch unreachable;
        out.append(xm.allocator, if (ch == 0x7f) '?' else ch + '@') catch unreachable;
        return;
    }

    out.append(xm.allocator, '-') catch unreachable;
    out.append(xm.allocator, ch) catch unreachable;
}

fn isVisVisible(ch: u8, flag: u32) bool {
    if (ch != '\\' and (flag & VIS_ALL) != 0) return false;

    const graph = isAsciiGraph(ch);
    const glob_graph = graph and (((ch != '*' and ch != '?' and ch != '[' and ch != '#') or (flag & VIS_GLOB) == 0));
    if (glob_graph) return true;
    if ((flag & VIS_SP) == 0 and ch == ' ') return true;
    if ((flag & VIS_TAB) == 0 and ch == '\t') return true;
    if ((flag & VIS_NL) == 0 and ch == '\n') return true;
    if ((flag & VIS_SAFE) != 0 and (ch == 0x08 or ch == 0x07 or ch == '\r' or graph)) return true;
    return false;
}

fn isAsciiGraph(ch: u8) bool {
    return ch <= 0x7f and ch != ' ' and std.ascii.isPrint(ch);
}

fn isOctal(ch: u8) bool {
    return ch >= '0' and ch <= '7';
}

fn utf8SetSize(size: anytype) T.utf8_char {
    return @as(T.utf8_char, @intCast(size)) << 24;
}

fn utf8SetWidth(width: anytype) T.utf8_char {
    return (@as(T.utf8_char, @intCast(width)) + 1) << 29;
}

fn utf8GetSize(uc: T.utf8_char) u8 {
    return @intCast((uc >> 24) & 0x1f);
}

fn utf8GetWidth(uc: T.utf8_char) u8 {
    return @intCast((uc >> 29) - 1);
}

fn putUtf8Item(data: []const u8) ?u32 {
    if (findUtf8ItemByData(data)) |item| return item.index;
    if (utf8_next_index == 0x00ff_ffff + 1) return null;

    var entry = Utf8Item{
        .index = utf8_next_index,
        .size = @intCast(data.len),
        .data = std.mem.zeroes([T.UTF8_SIZE]u8),
    };
    @memcpy(entry.data[0..data.len], data);
    utf8_items.append(xm.allocator, entry) catch unreachable;
    utf8_next_index += 1;
    return entry.index;
}

fn findUtf8ItemByData(data: []const u8) ?Utf8Item {
    for (utf8_items.items) |item| {
        if (item.size != data.len) continue;
        if (std.mem.eql(u8, item.data[0..item.size], data)) return item;
    }
    return null;
}

fn findUtf8ItemByIndex(index: u32) ?Utf8Item {
    for (utf8_items.items) |item| {
        if (item.index == index) return item;
    }
    return null;
}

fn utf8Width(ud: *const T.Utf8Data, width: *u8) T.Utf8State {
    var wc: WChar = undefined;
    if (utf8_towc(ud, &wc) != .done) return .@"error";

    ensureDefaultWidthCache();
    if (findWidthInCache(wcharKey(wc))) |cached| {
        width.* = cached;
        return .done;
    }

    ensureLocale();
    var resolved = c.posix_sys.wcwidth(wc);
    if (resolved < 0) {
        const cp = wcharToCodepoint(wc) orelse return .@"error";
        resolved = if (cp >= 0x80 and cp <= 0x9f) 0 else 1;
    }
    if (resolved < 0 or resolved > 0xff) return .@"error";

    width.* = @intCast(resolved);
    return .done;
}

fn ensureLocale() void {
    if (locale_ready) return;
    _ = std.c.setlocale(std.c.LC.CTYPE, "");
    locale_ready = true;
}

fn ensureDefaultWidthCache() void {
    if (utf8_width_cache_ready) return;
    resetWidthCache();
}

fn resetWidthCache() void {
    utf8_width_cache.clearRetainingCapacity();
    utf8_width_cache.appendSlice(xm.allocator, &default_width_cache) catch unreachable;
    utf8_width_cache_ready = true;
}

fn findWidthInCache(wc: u32) ?u8 {
    for (utf8_width_cache.items) |item| {
        if (item.wc == wc) return item.width;
    }
    return null;
}

fn insertWidthCache(wc: u32, width: u8) void {
    ensureDefaultWidthCache();
    for (utf8_width_cache.items) |*item| {
        if (item.wc != wc) continue;
        item.width = width;
        return;
    }
    utf8_width_cache.append(xm.allocator, .{ .wc = wc, .width = width }) catch unreachable;
}

fn utf8_add_to_width_cache(s: []const u8) void {
    const eq = std.mem.indexOfScalar(u8, s, '=') orelse return;
    const key = s[0..eq];
    const value = s[eq + 1 ..];
    const width = std.fmt.parseInt(u8, value, 10) catch return;
    if (width > 2) return;

    if (std.mem.startsWith(u8, key, "U+")) {
        const range = parseCodepointRange(key) orelse return;
        var wc = range.start;
        while (wc <= range.end) : (wc += 1) {
            insertWidthCache(wc, width);
        }
        return;
    }

    const old_no_width = utf8_no_width;
    utf8_no_width = true;
    defer utf8_no_width = old_no_width;

    const ud = utf8_fromcstr(key);
    defer xm.allocator.free(ud);
    if (ud[0].size == 0 or ud[1].size != 0) return;

    var wc: WChar = undefined;
    if (utf8_towc(&ud[0], &wc) != .done) return;
    insertWidthCache(wcharKey(wc), width);
}

fn parseCodepointRange(spec: []const u8) ?struct { start: u32, end: u32 } {
    if (!std.mem.startsWith(u8, spec, "U+")) return null;

    if (std.mem.indexOfScalar(u8, spec, '-')) |dash| {
        const start = parseCodepoint(spec[2..dash]) orelse return null;
        const rest = spec[dash + 1 ..];
        if (!std.mem.startsWith(u8, rest, "U+")) return null;
        const end = parseCodepoint(rest[2..]) orelse return null;
        if (end < start) return null;
        return .{ .start = start, .end = end };
    }

    const value = parseCodepoint(spec[2..]) orelse return null;
    return .{ .start = value, .end = value };
}

fn parseCodepoint(hex: []const u8) ?u32 {
    if (hex.len == 0) return null;
    const value = std.fmt.parseInt(u32, hex, 16) catch return null;
    if (value == 0 or value > 0x10ffff) return null;
    return value;
}

fn wcharKey(wc: WChar) u32 {
    const cp = wcharToCodepoint(wc) orelse return 0;
    return cp;
}

fn wcharToCodepoint(wc: WChar) ?u21 {
    const info = @typeInfo(WChar).int;
    return switch (info.signedness) {
        .signed => blk: {
            const value: i64 = @intCast(wc);
            if (value < 0) break :blk null;
            break :blk std.math.cast(u21, @as(u32, @intCast(value)));
        },
        .unsigned => std.math.cast(u21, @as(u32, @intCast(wc))),
    };
}

fn resetUtf8StateForTests() void {
    utf8_items.clearRetainingCapacity();
    utf8_next_index = 0;
    utf8_no_width = false;
    resetWidthCache();
}

fn init_options_for_utf8_tests() void {
    opts.global_options = opts.options_create(null);
    opts.global_s_options = opts.options_create(null);
    opts.global_w_options = opts.options_create(null);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
}

fn free_options_for_utf8_tests() void {
    opts.options_free(opts.global_w_options);
    opts.options_free(opts.global_s_options);
    opts.options_free(opts.global_options);
}

test "utf8_set and utf8_copy handle single-byte data" {
    resetUtf8StateForTests();

    var ud: T.Utf8Data = undefined;
    utf8_set(&ud, 'x');

    try std.testing.expectEqual(@as(u8, 'x'), ud.data[0]);
    try std.testing.expectEqual(@as(u8, 1), ud.have);
    try std.testing.expectEqual(@as(u8, 1), ud.size);
    try std.testing.expectEqual(@as(u8, 1), ud.width);

    var dst: T.Utf8Data = undefined;
    utf8_copy(&dst, &ud);
    try std.testing.expectEqual(@as(u8, 'x'), dst.data[0]);
    try std.testing.expectEqual(@as(u8, 0), dst.data[1]);
}

test "utf8_open and append decode multibyte sequences" {
    resetUtf8StateForTests();

    var ud: T.Utf8Data = undefined;
    try std.testing.expectEqual(T.Utf8State.more, utf8_open(&ud, 0xc3));
    try std.testing.expectEqual(T.Utf8State.done, utf8_append(&ud, 0xa9));

    var uc: T.utf8_char = 0;
    try std.testing.expectEqual(T.Utf8State.done, utf8_from_data(&ud, &uc));

    var back: T.Utf8Data = undefined;
    utf8_to_data(uc, &back);
    try std.testing.expectEqualSlices(u8, "é", back.data[0..back.size]);
}

test "utf8_from_data and to_data roundtrip four-byte characters" {
    resetUtf8StateForTests();

    var ud: T.Utf8Data = std.mem.zeroes(T.Utf8Data);
    const text = "🙂";
    @memcpy(ud.data[0..text.len], text);
    ud.size = text.len;
    ud.have = text.len;

    var width: u8 = 0;
    try std.testing.expectEqual(T.Utf8State.done, utf8Width(&ud, &width));
    ud.width = width;

    var uc: T.utf8_char = 0;
    try std.testing.expectEqual(T.Utf8State.done, utf8_from_data(&ud, &uc));

    var back: T.Utf8Data = undefined;
    utf8_to_data(uc, &back);
    try std.testing.expectEqualSlices(u8, text, back.data[0..back.size]);
}

test "utf8_towc and fromwc honor default width cache overrides" {
    resetUtf8StateForTests();

    var ud: T.Utf8Data = undefined;
    try std.testing.expectEqual(T.Utf8State.done, utf8_fromwc(@as(WChar, @intCast(0x1F1E6)), &ud));
    try std.testing.expectEqual(@as(u8, 1), ud.width);

    var wc: WChar = undefined;
    try std.testing.expectEqual(T.Utf8State.done, utf8_towc(&ud, &wc));
    try std.testing.expectEqual(@as(WChar, @intCast(0x1F1E6)), wc);
}

test "utf8 update width cache honors codepoint-widths option" {
    resetUtf8StateForTests();
    init_options_for_utf8_tests();
    defer free_options_for_utf8_tests();

    opts.options_set_array(opts.global_options, "codepoint-widths", &.{ "U+2603=2", "A=0" });
    utf8_update_width_cache();

    var snowman: T.Utf8Data = undefined;
    try std.testing.expectEqual(T.Utf8State.done, utf8_fromwc(@as(WChar, @intCast(0x2603)), &snowman));
    try std.testing.expectEqual(@as(u8, 2), snowman.width);

    var letter: T.Utf8Data = undefined;
    try std.testing.expectEqual(T.Utf8State.done, utf8_fromwc('A', &letter));
    try std.testing.expectEqual(@as(u8, 0), letter.width);
}

test "utf8 validation and sanitize follow tmux-style rules" {
    resetUtf8StateForTests();

    try std.testing.expect(utf8_isvalid("hello"));
    try std.testing.expect(!utf8_isvalid(&.{ 'A', 0x1f }));
    try std.testing.expect(!utf8_isvalid(&.{ 'A', 0xff }));

    const sanitized = utf8_sanitize(&.{ 'A', 0xf0, 0x9f, 0x99, 0x82, 0x01, 0xff });
    defer xm.allocator.free(sanitized);
    try std.testing.expectEqualStrings("A____", sanitized);
}

test "utf8 strvis keeps valid utf8 and escapes invalid bytes" {
    resetUtf8StateForTests();

    const escaped = utf8_strvisx(&.{ 'A', '\n', 0xc3, '(', 0xf0, 0x9f, 0x99, 0x82 }, VIS_OCTAL | VIS_CSTYLE | VIS_TAB | VIS_NL);
    defer xm.allocator.free(escaped);

    try std.testing.expectEqualStrings("A\\n\\303(🙂", escaped);
}

test "utf8 strvis handles dollar quoting and exact-length NUL escapes" {
    resetUtf8StateForTests();

    const shell = utf8_stravis("$HOME", VIS_DQ | VIS_OCTAL | VIS_CSTYLE | VIS_TAB | VIS_NL);
    defer xm.allocator.free(shell);
    try std.testing.expectEqualStrings("\\$HOME", shell);

    const nul = utf8_strvisx(&.{ 0, '7' }, VIS_CSTYLE);
    defer xm.allocator.free(nul);
    try std.testing.expectEqualStrings("\\0007", nul);
}

test "utf8_strlen strwidth and cstrhas cover utf8_data strings" {
    resetUtf8StateForTests();

    const seq = utf8_fromcstr("a🙂b");
    defer xm.allocator.free(seq);

    try std.testing.expectEqual(@as(usize, 3), utf8_strlen(seq));
    try std.testing.expectEqual(@as(u32, 4), utf8_strwidth(seq, -1));
    try std.testing.expectEqual(@as(u32, 3), utf8_strwidth(seq, 2));
    try std.testing.expect(utf8_cstrhas("a🙂b", &seq[1]));
}

test "utf8_fromcstr splits mixed strings and terminates with sentinel" {
    resetUtf8StateForTests();

    const seq = utf8_fromcstr("Aé🙂");
    defer xm.allocator.free(seq);

    try std.testing.expectEqual(@as(u8, 1), seq[0].size);
    try std.testing.expectEqual(@as(u8, 2), seq[1].size);
    try std.testing.expectEqual(@as(u8, 4), seq[2].size);
    try std.testing.expectEqual(@as(u8, 0), seq[3].size);
}

test "utf8_cstrwidth counts ASCII and wide characters" {
    resetUtf8StateForTests();

    try std.testing.expectEqual(@as(u32, 3), utf8_cstrwidth("abc"));
    try std.testing.expectEqual(@as(u32, 3), utf8_cstrwidth("a🙂"));
}

test "utf8 trim helpers keep left and right display widths" {
    resetUtf8StateForTests();

    const left = utf8_trim_left("a🙂bc", 3);
    defer xm.allocator.free(left);
    try std.testing.expectEqualStrings("a🙂", left);

    const right = utf8_trim_right("a🙂bc", 3);
    defer xm.allocator.free(right);
    try std.testing.expectEqualStrings("bc", right);
}

test "utf8 padding helpers pad by display width" {
    resetUtf8StateForTests();

    const padded = utf8_padcstr("x🙂", 4);
    defer xm.allocator.free(padded);
    try std.testing.expectEqualStrings("x🙂 ", padded);

    const rpad = utf8_rpadcstr("x🙂", 4);
    defer xm.allocator.free(rpad);
    try std.testing.expectEqualStrings(" x🙂", rpad);
}
