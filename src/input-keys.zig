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

const FixedSequence = struct {
    key: T.key_code,
    seq: []const u8,
};

const ModifierTemplate = struct {
    key: T.key_code,
    template: []const u8,
};

const fixed_sequences = [_]FixedSequence{
    .{ .key = T.KEYC_F1, .seq = "\x1bOP" },
    .{ .key = T.KEYC_F2, .seq = "\x1bOQ" },
    .{ .key = T.KEYC_F3, .seq = "\x1bOR" },
    .{ .key = T.KEYC_F4, .seq = "\x1bOS" },
    .{ .key = T.KEYC_F5, .seq = "\x1b[15~" },
    .{ .key = T.KEYC_F6, .seq = "\x1b[17~" },
    .{ .key = T.KEYC_F7, .seq = "\x1b[18~" },
    .{ .key = T.KEYC_F8, .seq = "\x1b[19~" },
    .{ .key = T.KEYC_F9, .seq = "\x1b[20~" },
    .{ .key = T.KEYC_F10, .seq = "\x1b[21~" },
    .{ .key = T.KEYC_F11, .seq = "\x1b[23~" },
    .{ .key = T.KEYC_F12, .seq = "\x1b[24~" },
    .{ .key = T.KEYC_IC, .seq = "\x1b[2~" },
    .{ .key = T.KEYC_DC, .seq = "\x1b[3~" },
    .{ .key = T.KEYC_HOME, .seq = "\x1b[1~" },
    .{ .key = T.KEYC_END, .seq = "\x1b[4~" },
    .{ .key = T.KEYC_NPAGE, .seq = "\x1b[6~" },
    .{ .key = T.KEYC_PPAGE, .seq = "\x1b[5~" },
    .{ .key = T.KEYC_BTAB, .seq = "\x1b[Z" },
    .{ .key = T.KEYC_UP, .seq = "\x1b[A" },
    .{ .key = T.KEYC_DOWN, .seq = "\x1b[B" },
    .{ .key = T.KEYC_RIGHT, .seq = "\x1b[C" },
    .{ .key = T.KEYC_LEFT, .seq = "\x1b[D" },
    .{ .key = T.KEYC_KP_SLASH, .seq = "/" },
    .{ .key = T.KEYC_KP_STAR, .seq = "*" },
    .{ .key = T.KEYC_KP_MINUS, .seq = "-" },
    .{ .key = T.KEYC_KP_SEVEN, .seq = "7" },
    .{ .key = T.KEYC_KP_EIGHT, .seq = "8" },
    .{ .key = T.KEYC_KP_NINE, .seq = "9" },
    .{ .key = T.KEYC_KP_PLUS, .seq = "+" },
    .{ .key = T.KEYC_KP_FOUR, .seq = "4" },
    .{ .key = T.KEYC_KP_FIVE, .seq = "5" },
    .{ .key = T.KEYC_KP_SIX, .seq = "6" },
    .{ .key = T.KEYC_KP_ONE, .seq = "1" },
    .{ .key = T.KEYC_KP_TWO, .seq = "2" },
    .{ .key = T.KEYC_KP_THREE, .seq = "3" },
    .{ .key = T.KEYC_KP_ENTER, .seq = "\n" },
    .{ .key = T.KEYC_KP_ZERO, .seq = "0" },
    .{ .key = T.KEYC_KP_PERIOD, .seq = "." },
};

const modifier_templates = [_]ModifierTemplate{
    .{ .key = T.KEYC_F1, .template = "\x1b[1;_P" },
    .{ .key = T.KEYC_F2, .template = "\x1b[1;_Q" },
    .{ .key = T.KEYC_F3, .template = "\x1b[1;_R" },
    .{ .key = T.KEYC_F4, .template = "\x1b[1;_S" },
    .{ .key = T.KEYC_F5, .template = "\x1b[15;_~" },
    .{ .key = T.KEYC_F6, .template = "\x1b[17;_~" },
    .{ .key = T.KEYC_F7, .template = "\x1b[18;_~" },
    .{ .key = T.KEYC_F8, .template = "\x1b[19;_~" },
    .{ .key = T.KEYC_F9, .template = "\x1b[20;_~" },
    .{ .key = T.KEYC_F10, .template = "\x1b[21;_~" },
    .{ .key = T.KEYC_F11, .template = "\x1b[23;_~" },
    .{ .key = T.KEYC_F12, .template = "\x1b[24;_~" },
    .{ .key = T.KEYC_UP, .template = "\x1b[1;_A" },
    .{ .key = T.KEYC_DOWN, .template = "\x1b[1;_B" },
    .{ .key = T.KEYC_RIGHT, .template = "\x1b[1;_C" },
    .{ .key = T.KEYC_LEFT, .template = "\x1b[1;_D" },
    .{ .key = T.KEYC_HOME, .template = "\x1b[1;_H" },
    .{ .key = T.KEYC_END, .template = "\x1b[1;_F" },
    .{ .key = T.KEYC_PPAGE, .template = "\x1b[5;_~" },
    .{ .key = T.KEYC_NPAGE, .template = "\x1b[6;_~" },
    .{ .key = T.KEYC_IC, .template = "\x1b[2;_~" },
    .{ .key = T.KEYC_DC, .template = "\x1b[3;_~" },
};

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

    if (encode_fixed_key(masked, modifiers, buf)) |seq|
        return seq;
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
    const want_meta = modifiers & T.KEYC_META != 0;
    const local_modifiers = modifiers & ~T.KEYC_META;
    const start: usize = if (want_meta) 1 else 0;

    if (want_meta) {
        buf[0] = 0x1b;
    }

    const tail = try encode_ascii_key_tail(masked, local_modifiers, buf[start..]);
    return buf[0 .. start + tail.len];
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

fn encode_fixed_key(masked: T.key_code, modifiers: T.key_code, buf: *[16]u8) ?[]const u8 {
    if (modifierTemplateFor(masked)) |template| {
        if (modifierParameter(modifiers)) |parameter| {
            return apply_modifier_template(template, parameter, buf);
        }
    }

    if (fixedSequenceFor(masked)) |seq| {
        return switch (modifiers) {
            0 => copy_sequence(seq, buf),
            T.KEYC_META => copy_sequence_with_meta(seq, buf),
            else => null,
        };
    }
    return null;
}

fn encode_ascii_key_tail(masked: T.key_code, modifiers: T.key_code, out: []u8) error{UnsupportedKey}![]const u8 {
    switch (modifiers) {
        0 => {
            out[0] = @intCast(masked);
            return out[0..1];
        },
        T.KEYC_SHIFT => {
            if (masked >= 'a' and masked <= 'z') {
                out[0] = std.ascii.toUpper(@intCast(masked));
                return out[0..1];
            }
            out[0] = @intCast(masked);
            return out[0..1];
        },
        T.KEYC_CTRL, T.KEYC_SHIFT | T.KEYC_CTRL => {
            out[0] = ctrl_ascii_byte(masked) orelse return error.UnsupportedKey;
            return out[0..1];
        },
        else => return error.UnsupportedKey,
    }
}

fn ctrl_ascii_byte(masked: T.key_code) ?u8 {
    return switch (masked) {
        '1', '!' => '1',
        '9', '(' => '9',
        '0', ')' => '0',
        '=', '+' => '=',
        ';', ':' => ';',
        '\'', '"' => '\'',
        ',', '<' => ',',
        '.', '>' => '.',
        '/', '-' => 0x1f,
        '8', '?' => 0x7f,
        ' ', '2' => 0x00,
        '3'...'7' => @as(u8, @intCast(masked - '\x18')),
        '@'...'~' => @as(u8, @intCast(masked & 0x1f)),
        else => null,
    };
}

fn fixedSequenceFor(masked: T.key_code) ?[]const u8 {
    for (fixed_sequences) |entry| {
        if (entry.key == masked) return entry.seq;
    }
    return null;
}

fn modifierTemplateFor(masked: T.key_code) ?[]const u8 {
    for (modifier_templates) |entry| {
        if (entry.key == masked) return entry.template;
    }
    return null;
}

fn modifierParameter(modifiers: T.key_code) ?u8 {
    return switch (modifiers) {
        T.KEYC_SHIFT => '2',
        T.KEYC_META => '3',
        T.KEYC_SHIFT | T.KEYC_META => '4',
        T.KEYC_CTRL => '5',
        T.KEYC_SHIFT | T.KEYC_CTRL => '6',
        T.KEYC_META | T.KEYC_CTRL => '7',
        T.KEYC_SHIFT | T.KEYC_META | T.KEYC_CTRL => '8',
        else => null,
    };
}

fn apply_modifier_template(template: []const u8, parameter: u8, buf: *[16]u8) []const u8 {
    for (template, 0..) |ch, idx| {
        buf[idx] = if (ch == '_') parameter else ch;
    }
    return buf[0..template.len];
}

fn copy_sequence(seq: []const u8, buf: *[16]u8) []const u8 {
    std.mem.copyForwards(u8, buf[0..seq.len], seq);
    return buf[0..seq.len];
}

fn copy_sequence_with_meta(seq: []const u8, buf: *[16]u8) []const u8 {
    buf[0] = 0x1b;
    std.mem.copyForwards(u8, buf[1 .. 1 + seq.len], seq);
    return buf[0 .. 1 + seq.len];
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

test "input_key_encode ports tmux fixed function and keypad sequences" {
    var buf: [16]u8 = undefined;

    try std.testing.expectEqualStrings("\x1bOP", try input_key_encode(T.KEYC_F1 | T.KEYC_IMPLIED_META, &buf));
    try std.testing.expectEqualStrings("\x1b[23~", try input_key_encode(T.KEYC_F11, &buf));
    try std.testing.expectEqualStrings("1", try input_key_encode(T.KEYC_KP_ONE | T.KEYC_KEYPAD, &buf));
    try std.testing.expectEqualStrings("\x1b1", try input_key_encode(T.KEYC_KP_ONE | T.KEYC_KEYPAD | T.KEYC_META, &buf));
    try std.testing.expectEqualStrings("\n", try input_key_encode(T.KEYC_KP_ENTER, &buf));
}

test "input_key_encode ports tmux modifier-built special sequences" {
    var buf: [16]u8 = undefined;

    try std.testing.expectEqualStrings("\x1b[1;2P", try input_key_encode(T.KEYC_F1 | T.KEYC_SHIFT, &buf));
    try std.testing.expectEqualStrings("\x1b[1;3A", try input_key_encode(T.KEYC_UP | T.KEYC_META, &buf));
    try std.testing.expectEqualStrings("\x1b[1;5F", try input_key_encode(T.KEYC_END | T.KEYC_CTRL, &buf));
    try std.testing.expectEqualStrings("\x1b[3;8~", try input_key_encode(T.KEYC_DC | T.KEYC_SHIFT | T.KEYC_META | T.KEYC_CTRL, &buf));
}

test "input_key_encode matches tmux vt10x ctrl remapping edge cases" {
    var buf: [16]u8 = undefined;

    try std.testing.expectEqualStrings("1", try input_key_encode(@as(T.key_code, '1') | T.KEYC_CTRL, &buf));
    try std.testing.expectEqual(@as(usize, 1), (try input_key_encode(@as(T.key_code, '2') | T.KEYC_CTRL, &buf)).len);
    try std.testing.expectEqual(@as(u8, 0x00), buf[0]);
    try std.testing.expectEqualStrings("\x1b", try input_key_encode(@as(T.key_code, '3') | T.KEYC_CTRL, &buf));
    try std.testing.expectEqual(@as(usize, 1), (try input_key_encode(@as(T.key_code, '/') | T.KEYC_CTRL, &buf)).len);
    try std.testing.expectEqual(@as(u8, 0x1f), buf[0]);
    try std.testing.expectEqual(@as(usize, 2), (try input_key_encode(@as(T.key_code, '?') | T.KEYC_META | T.KEYC_CTRL, &buf)).len);
    try std.testing.expectEqual(@as(u8, 0x1b), buf[0]);
    try std.testing.expectEqual(@as(u8, 0x7f), buf[1]);
}
