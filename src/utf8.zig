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
// Ported from tmux/utf8.c (key-string support slice)
// Original copyright:
//   Copyright (c) 2008 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

const std = @import("std");
const T = @import("types.zig");
const c = @import("c.zig");
const xm = @import("xmalloc.zig");

const Utf8Item = struct {
    index: u32,
    size: u8,
    data: [T.UTF8_SIZE]u8,
};

var utf8_items: std.ArrayList(Utf8Item) = .{};
var utf8_next_index: u32 = 0;
var locale_ready = false;

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

    if (ud.width == 0xff) return .@"error";
    ud.width = widthOfBytes(ud.data[0..ud.size]) orelse return .@"error";
    return .done;
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

fn utf8PackFailure(ud: *const T.Utf8Data, uc: *T.utf8_char) T.Utf8State {
    if (ud.width == 0)
        uc.* = utf8SetSize(0) | utf8SetWidth(0)
    else
        uc.* = utf8BuildOne(' ');
    return .@"error";
}

fn utf8BuildOne(ch: u8) T.utf8_char {
    return utf8SetSize(1) | utf8SetWidth(1) | ch;
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

    const store = itemStore();
    var entry = Utf8Item{
        .index = utf8_next_index,
        .size = @intCast(data.len),
        .data = std.mem.zeroes([T.UTF8_SIZE]u8),
    };
    @memcpy(entry.data[0..data.len], data);
    store.append(xm.allocator, entry) catch unreachable;
    utf8_next_index += 1;
    return entry.index;
}

fn findUtf8ItemByData(data: []const u8) ?Utf8Item {
    const store = itemStore();
    for (store.items) |item| {
        if (item.size != data.len) continue;
        if (std.mem.eql(u8, item.data[0..item.size], data)) return item;
    }
    return null;
}

fn findUtf8ItemByIndex(index: u32) ?Utf8Item {
    const store = itemStore();
    for (store.items) |item| {
        if (item.index == index) return item;
    }
    return null;
}

fn itemStore() *std.ArrayList(Utf8Item) {
    return &utf8_items;
}

fn widthOfBytes(bytes: []const u8) ?u8 {
    const cp = std.unicode.utf8Decode(bytes) catch return null;
    return widthOfCodepoint(cp);
}

fn widthOfCodepoint(cp: u21) ?u8 {
    ensureLocale();
    const width = c.posix_sys.wcwidth(@as(c.posix_sys.wchar_t, @intCast(cp)));
    if (width >= 0 and width <= 2) return @intCast(width);
    if (cp >= 0x80 and cp <= 0x9f) return 0;
    return if (isWide(cp)) 2 else 1;
}

fn ensureLocale() void {
    if (locale_ready) return;
    _ = std.c.setlocale(std.c.LC.CTYPE, "");
    locale_ready = true;
}

fn isWide(cp: u21) bool {
    return cp >= 0x1100 and (
        cp <= 0x115f or
        cp == 0x2329 or
        cp == 0x232a or
        (cp >= 0x2e80 and cp <= 0xa4cf and cp != 0x303f) or
        (cp >= 0xac00 and cp <= 0xd7a3) or
        (cp >= 0xf900 and cp <= 0xfaff) or
        (cp >= 0xfe10 and cp <= 0xfe19) or
        (cp >= 0xfe30 and cp <= 0xfe6f) or
        (cp >= 0xff00 and cp <= 0xff60) or
        (cp >= 0xffe0 and cp <= 0xffe6) or
        (cp >= 0x1f300 and cp <= 0x1faff) or
        (cp >= 0x20000 and cp <= 0x3fffd)
    );
}

test "utf8_set and utf8_copy handle single-byte data" {
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
    var ud: T.Utf8Data = std.mem.zeroes(T.Utf8Data);
    const text = "🙂";
    @memcpy(ud.data[0..text.len], text);
    ud.size = text.len;
    ud.have = text.len;
    ud.width = widthOfBytes(text) orelse unreachable;

    var uc: T.utf8_char = 0;
    try std.testing.expectEqual(T.Utf8State.done, utf8_from_data(&ud, &uc));

    var back: T.Utf8Data = undefined;
    utf8_to_data(uc, &back);
    try std.testing.expectEqualSlices(u8, text, back.data[0..back.size]);
}

test "utf8_fromcstr splits mixed strings and terminates with sentinel" {
    const seq = utf8_fromcstr("Aé🙂");
    defer xm.allocator.free(seq);

    try std.testing.expectEqual(@as(u8, 1), seq[0].size);
    try std.testing.expectEqual(@as(u8, 2), seq[1].size);
    try std.testing.expectEqual(@as(u8, 4), seq[2].size);
    try std.testing.expectEqual(@as(u8, 0), seq[3].size);
}

test "utf8_cstrwidth counts ASCII and wide characters" {
    try std.testing.expectEqual(@as(u32, 3), utf8_cstrwidth("abc"));
    try std.testing.expectEqual(@as(u32, 3), utf8_cstrwidth("a🙂"));
}
