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
// Ported in part from tmux/input-keys.c.
// Original copyright:
//   Copyright (c) 2007 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

//! input-keys.zig – reduced attached-client key decoder.

const std = @import("std");
const T = @import("types.zig");
const utf8 = @import("utf8.zig");
const key_string = @import("key-string.zig");

pub fn input_key_get(bytes: []const u8, event: *T.key_event) ?usize {
    if (bytes.len == 0) return null;
    if (bytes[0] == 0x1b) return parse_escape(bytes, event);
    return parse_plain(bytes, event);
}

pub fn input_key_encode(key_in: T.key_code, buf: *[16]u8) error{UnsupportedKey}![]const u8 {
    const key = key_in & ~T.KEYC_IMPLIED_META;
    if (T.keycIsMouse(key) or T.keycIsPaste(key)) return error.UnsupportedKey;

    if (key & T.KEYC_LITERAL != 0) {
        buf[0] = @intCast(key & 0xff);
        return buf[0..1];
    }

    const masked = key & T.KEYC_MASK_KEY;
    const modifiers = key & T.KEYC_MASK_MODIFIERS;

    if (masked == T.KEYC_NONE or masked == T.KEYC_UNKNOWN or masked == T.KEYC_ANY)
        return error.UnsupportedKey;

    if (masked <= 0x7f)
        return encode_ascii_key(masked, modifiers, buf);
    if (T.keycIsUnicode(masked))
        return encode_unicode_key(masked, modifiers, buf);
    return encode_special_key(masked, modifiers, buf);
}

fn parse_escape(bytes: []const u8, event: *T.key_event) ?usize {
    if (bytes.len == 1) return null;
    if (bytes[1] == '[') return parse_csi(bytes, event);
    if (bytes[1] == 'O') return parse_ss3(bytes, event);

    var inner: T.key_event = .{};
    const consumed = parse_plain(bytes[1..], &inner) orelse return null;
    if (inner.len == 0 or inner.key == T.KEYC_UNKNOWN) return null;

    event.* = inner;
    event.key |= T.KEYC_META;
    event.len = 1 + inner.len;
    event.data[0] = 0x1b;
    @memcpy(event.data[1 .. 1 + inner.len], inner.data[0..inner.len]);
    return 1 + consumed;
}

fn parse_plain(bytes: []const u8, event: *T.key_event) ?usize {
    const ch = bytes[0];
    event.* = .{};

    switch (ch) {
        '\r', '\n' => return fill_event(event, T.C0_CR, bytes[0..1]),
        '\t' => return fill_event(event, T.C0_HT, bytes[0..1]),
        0x7f => return fill_event(event, T.KEYC_BSPACE, bytes[0..1]),
        else => {},
    }

    if (ctrl_key(ch)) |key| return fill_event(event, key, bytes[0..1]);
    if (ch >= ' ' and ch <= '~') return fill_event(event, ch, bytes[0..1]);

    if (ch < 0x80) return fill_event(event, T.KEYC_UNKNOWN, bytes[0..1]);

    var ud: T.Utf8Data = undefined;
    if (utf8.utf8_open(&ud, ch) != .more) return fill_event(event, T.KEYC_UNKNOWN, bytes[0..1]);
    if (bytes.len < ud.size) return null;

    var idx: usize = 1;
    var state: T.Utf8State = .more;
    while (idx < ud.size and state == .more) : (idx += 1) {
        state = utf8.utf8_append(&ud, bytes[idx]);
    }
    if (state != .done) return fill_event(event, T.KEYC_UNKNOWN, bytes[0..1]);

    var uc: T.utf8_char = 0;
    if (utf8.utf8_from_data(&ud, &uc) != .done) return fill_event(event, T.KEYC_UNKNOWN, bytes[0..1]);
    return fill_event(event, @as(T.key_code, uc), bytes[0..ud.size]);
}

fn parse_csi(bytes: []const u8, event: *T.key_event) ?usize {
    if (bytes.len < 3) return null;

    const final = bytes[2];
    switch (final) {
        'A' => return fill_event(event, T.KEYC_UP | T.KEYC_CURSOR | T.KEYC_IMPLIED_META, bytes[0..3]),
        'B' => return fill_event(event, T.KEYC_DOWN | T.KEYC_CURSOR | T.KEYC_IMPLIED_META, bytes[0..3]),
        'C' => return fill_event(event, T.KEYC_RIGHT | T.KEYC_CURSOR | T.KEYC_IMPLIED_META, bytes[0..3]),
        'D' => return fill_event(event, T.KEYC_LEFT | T.KEYC_CURSOR | T.KEYC_IMPLIED_META, bytes[0..3]),
        'H' => return fill_event(event, T.KEYC_HOME | T.KEYC_IMPLIED_META, bytes[0..3]),
        'F' => return fill_event(event, T.KEYC_END | T.KEYC_IMPLIED_META, bytes[0..3]),
        else => {},
    }

    var idx: usize = 2;
    while (idx < bytes.len) : (idx += 1) {
        const ch = bytes[idx];
        if (ch == '~') {
            const number = std.fmt.parseInt(u32, bytes[2..idx], 10) catch return fill_event(event, T.KEYC_UNKNOWN, bytes[0 .. idx + 1]);
            const key = switch (number) {
                1, 7 => T.KEYC_HOME | T.KEYC_IMPLIED_META,
                2 => T.KEYC_IC | T.KEYC_IMPLIED_META,
                3 => T.KEYC_DC | T.KEYC_IMPLIED_META,
                4, 8 => T.KEYC_END | T.KEYC_IMPLIED_META,
                5 => T.KEYC_PPAGE | T.KEYC_IMPLIED_META,
                6 => T.KEYC_NPAGE | T.KEYC_IMPLIED_META,
                else => T.KEYC_UNKNOWN,
            };
            return fill_event(event, key, bytes[0 .. idx + 1]);
        }
        if ((ch < '0' or ch > '9') and ch != ';') break;
    }
    return null;
}

fn parse_ss3(bytes: []const u8, event: *T.key_event) ?usize {
    if (bytes.len < 3) return null;
    const key = switch (bytes[2]) {
        'A' => T.KEYC_UP | T.KEYC_CURSOR | T.KEYC_IMPLIED_META,
        'B' => T.KEYC_DOWN | T.KEYC_CURSOR | T.KEYC_IMPLIED_META,
        'C' => T.KEYC_RIGHT | T.KEYC_CURSOR | T.KEYC_IMPLIED_META,
        'D' => T.KEYC_LEFT | T.KEYC_CURSOR | T.KEYC_IMPLIED_META,
        'H' => T.KEYC_HOME | T.KEYC_IMPLIED_META,
        'F' => T.KEYC_END | T.KEYC_IMPLIED_META,
        else => T.KEYC_UNKNOWN,
    };
    return fill_event(event, key, bytes[0..3]);
}

fn fill_event(event: *T.key_event, key: T.key_code, bytes: []const u8) usize {
    event.key = key;
    event.len = @min(bytes.len, event.data.len);
    @memset(&event.data, 0);
    @memcpy(event.data[0..event.len], bytes[0..event.len]);
    return bytes.len;
}

fn ctrl_key(ch: u8) ?T.key_code {
    return switch (ch) {
        0x00 => '@' | T.KEYC_CTRL,
        0x01...0x1a => (@as(T.key_code, 'a') + (ch - 1)) | T.KEYC_CTRL,
        0x1c...0x1f => (@as(T.key_code, ch) + 0x40) | T.KEYC_CTRL,
        else => null,
    };
}

fn encode_ascii_key(masked: T.key_code, modifiers: T.key_code, buf: *[16]u8) error{UnsupportedKey}![]const u8 {
    if (modifiers == 0) {
        buf[0] = @intCast(masked);
        return buf[0..1];
    }
    if (modifiers == T.KEYC_CTRL) {
        if (masked == '?') {
            buf[0] = 0x7f;
            return buf[0..1];
        }
        if ((masked >= '@' and masked <= '_') or (masked >= 'a' and masked <= 'z') or (masked >= 'A' and masked <= 'Z')) {
            buf[0] = @intCast(std.ascii.toUpper(@intCast(masked)) & 0x1f);
            return buf[0..1];
        }
        return error.UnsupportedKey;
    }
    if (modifiers == T.KEYC_META) {
        buf[0] = 0x1b;
        buf[1] = @intCast(masked);
        return buf[0..2];
    }
    if (modifiers == T.KEYC_SHIFT) {
        if (masked >= 'a' and masked <= 'z') {
            buf[0] = std.ascii.toUpper(@intCast(masked));
            return buf[0..1];
        }
        buf[0] = @intCast(masked);
        return buf[0..1];
    }
    if (modifiers == (T.KEYC_META | T.KEYC_CTRL)) {
        var ctrl_buf: [16]u8 = undefined;
        const ctrl = try encode_ascii_key(masked, T.KEYC_CTRL, &ctrl_buf);
        buf[0] = 0x1b;
        std.mem.copyForwards(u8, buf[1 .. 1 + ctrl.len], ctrl);
        return buf[0 .. 1 + ctrl.len];
    }
    return error.UnsupportedKey;
}

fn encode_unicode_key(masked: T.key_code, modifiers: T.key_code, buf: *[16]u8) error{UnsupportedKey}![]const u8 {
    if (modifiers != 0 and modifiers != T.KEYC_META) return error.UnsupportedKey;
    const codepoint: u21 = std.math.cast(u21, masked) orelse return error.UnsupportedKey;
    const start: usize = if (modifiers == T.KEYC_META) 1 else 0;
    if (start == 1) buf[0] = 0x1b;
    const size = std.unicode.utf8Encode(codepoint, buf[start..]) catch return error.UnsupportedKey;
    return buf[0 .. start + size];
}

fn encode_special_key(masked: T.key_code, modifiers: T.key_code, buf: *[16]u8) error{UnsupportedKey}![]const u8 {
    if (modifiers != 0 and modifiers != T.KEYC_META) return error.UnsupportedKey;
    const seq = switch (masked) {
        T.C0_HT => "\t",
        T.C0_CR => "\r",
        T.C0_ESC => "\x1b",
        T.C0_BS, T.KEYC_BSPACE => "\x7f",
        T.KEYC_UP => "\x1b[A",
        T.KEYC_DOWN => "\x1b[B",
        T.KEYC_RIGHT => "\x1b[C",
        T.KEYC_LEFT => "\x1b[D",
        T.KEYC_HOME => "\x1b[H",
        T.KEYC_END => "\x1b[F",
        T.KEYC_PPAGE => "\x1b[5~",
        T.KEYC_NPAGE => "\x1b[6~",
        T.KEYC_IC => "\x1b[2~",
        T.KEYC_DC => "\x1b[3~",
        else => return error.UnsupportedKey,
    };
    if (modifiers == T.KEYC_META) {
        buf[0] = 0x1b;
        std.mem.copyForwards(u8, buf[1 .. 1 + seq.len], seq);
        return buf[0 .. 1 + seq.len];
    }
    std.mem.copyForwards(u8, buf[0..seq.len], seq);
    return buf[0..seq.len];
}

test "input_key_get decodes printable control and cursor keys" {
    var event: T.key_event = .{};

    try std.testing.expectEqual(@as(usize, 1), input_key_get("a", &event).?);
    try std.testing.expectEqual(@as(T.key_code, 'a'), event.key);

    try std.testing.expectEqual(@as(usize, 1), input_key_get(&.{0x02}, &event).?);
    try std.testing.expectEqual(@as(T.key_code, 'b') | T.KEYC_CTRL, event.key);

    try std.testing.expectEqual(@as(usize, 3), input_key_get("\x1b[A", &event).?);
    try std.testing.expectEqual(T.KEYC_UP | T.KEYC_CURSOR | T.KEYC_IMPLIED_META, event.key);
}

test "input_key_get handles meta and utf8 input" {
    var event: T.key_event = .{};

    try std.testing.expectEqual(@as(usize, 2), input_key_get("\x1bx", &event).?);
    try std.testing.expectEqual(@as(T.key_code, 'x') | T.KEYC_META, event.key);

    try std.testing.expectEqual(@as(usize, 2), input_key_get("é", &event).?);
    try std.testing.expectEqual(key_string.key_string_lookup_string("é"), event.key);
}

test "input_key_encode matches supported VT-style special keys" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("\x1b[A", try input_key_encode(T.KEYC_UP, &buf));
    try std.testing.expectEqualStrings("\x1b[5~", try input_key_encode(T.KEYC_PPAGE, &buf));
    try std.testing.expectEqualStrings("\x1bx", try input_key_encode(@as(T.key_code, 'x') | T.KEYC_META, &buf));
}
