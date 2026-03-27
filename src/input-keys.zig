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
const opts = @import("options.zig");
const screen_mod = @import("screen.zig");

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

const MOUSE_PARAM_MAX: u32 = 0xff;
const MOUSE_PARAM_UTF8_MAX: u32 = 0x7ff;
const MOUSE_PARAM_BTN_OFF: u32 = 0x20;
const MOUSE_PARAM_POS_OFF: u32 = 0x21;

pub fn input_key_get(bytes: []const u8, event: *T.key_event) ?usize {
    return input_key_get_client(null, bytes, event);
}

pub fn input_key_get_client(client: ?*T.Client, bytes: []const u8, event: *T.key_event) ?usize {
    if (bytes.len == 0) return null;
    if (bytes[0] == 0x1b) return parse_escape(client, bytes, event);
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

pub fn input_key_encode_screen(screen: *const T.Screen, key_in: T.key_code, buf: *[32]u8) error{UnsupportedKey}![]const u8 {
    var key = key_in;
    if (T.keycIsMouse(key)) return buf[0..0];

    if (key & T.KEYC_LITERAL != 0) {
        buf[0] = @intCast(key & 0xff);
        return buf[0..1];
    }

    if ((key & T.KEYC_MASK_KEY) == T.KEYC_BSPACE) {
        const remapped = configured_backspace_key();
        if ((key & T.KEYC_MASK_MODIFIERS) == 0) {
            if (backspace_byte_for_key(remapped)) |byte| {
                buf[0] = byte;
                return buf[0..1];
            }
            return buf[0..0];
        }
        key = remapped | (key & (T.KEYC_MASK_FLAGS | T.KEYC_MASK_MODIFIERS));
    }

    if ((key & T.KEYC_MASK_KEY) == T.KEYC_BTAB) {
        if (effective_screen_mode(screen) & T.MODE_KEYS_EXTENDED_2 != 0) {
            key = T.C0_HT | (key & ~T.KEYC_MASK_KEY) | T.KEYC_SHIFT;
        } else {
            key &= ~T.KEYC_MASK_MODIFIERS;
        }
    }

    if (key & ~T.KEYC_MASK_KEY == 0) {
        if (key == T.C0_HT or key == T.C0_CR or key == T.C0_ESC or (key >= 0x20 and key <= 0x7f)) {
            buf[0] = @intCast(key);
            return buf[0..1];
        }
        if (T.keycIsUnicode(key & T.KEYC_MASK_KEY)) {
            var data: T.Utf8Data = undefined;
            utf8.utf8_to_data(@intCast(key & T.KEYC_MASK_KEY), &data);
            std.mem.copyForwards(u8, buf[0..data.size], data.data[0..data.size]);
            return buf[0..data.size];
        }
    }

    var lookup_key = key;
    const mode = effective_screen_mode(screen);
    if (mode & T.MODE_KKEYPAD == 0) lookup_key &= ~T.KEYC_KEYPAD;
    if (mode & T.MODE_KCURSOR == 0) lookup_key &= ~T.KEYC_CURSOR;

    if (encode_lookup_key(lookup_key, buf)) |seq| {
        if (T.keycIsPaste(lookup_key) and mode & T.MODE_BRACKETPASTE == 0) return buf[0..0];
        return seq;
    }

    const masked = lookup_key & T.KEYC_MASK_KEY;
    if ((masked >= T.KEYC_BASE and masked < T.KEYC_BASE_END) or
        (masked >= T.KEYC_USER and masked < T.KEYC_USER_END))
        return buf[0..0];

    switch (mode & T.EXTENDED_KEY_MODES) {
        T.MODE_KEYS_EXTENDED_2 => return encode_extended_key(lookup_key, buf),
        T.MODE_KEYS_EXTENDED => {
            if (encode_mode1_key(lookup_key, buf)) |seq| return seq;
            return encode_extended_key(lookup_key, buf);
        },
        else => return encode_vt10x_key(lookup_key, buf),
    }
}

pub fn input_key_mouse_pane(wp: *T.WindowPane, m: *const T.MouseEvent, buf: *[40]u8) []const u8 {
    if (!m.valid or m.ignore) return buf[0..0];

    const pane_id: u32 = std.math.cast(u32, m.wp) orelse return buf[0..0];
    if (pane_id != wp.id) return buf[0..0];
    if (!input_key_pane_visible(wp)) return buf[0..0];

    const point = input_key_mouse_at(wp, m, false) orelse return buf[0..0];
    return input_key_get_mouse(screen_mod.screen_current(wp), m, point.x, point.y, buf);
}

fn parse_escape(client: ?*T.Client, bytes: []const u8, event: *T.key_event) ?usize {
    if (bytes.len == 1) return null;
    if (bytes[1] == '[') return parse_csi(client, bytes, event);
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

    var decoder = utf8.Decoder.init();
    switch (decoder.feed(bytes)) {
        .glyph => |step| {
            const compact = step.glyph.compact() orelse return fill_event(event, T.KEYC_UNKNOWN, bytes[0..1]);
            return fill_event(event, @as(T.key_code, compact), bytes[0..step.consumed]);
        },
        .need_more => return null,
        .invalid => return fill_event(event, T.KEYC_UNKNOWN, bytes[0..1]),
    }
}

fn parse_csi(client: ?*T.Client, bytes: []const u8, event: *T.key_event) ?usize {
    if (bytes.len < 3) return null;
    if (bytes[2] == 'M' or bytes[2] == '<') {
        return parse_mouse(if (client) |cl| &cl.tty else null, bytes, event);
    }

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

fn parse_mouse(tty: ?*T.Tty, bytes: []const u8, event: *T.key_event) ?usize {
    if (bytes.len < 3 or bytes[0] != 0x1b or bytes[1] != '[') return null;

    var idx: usize = 3;
    var x: u32 = 0;
    var y: u32 = 0;
    var b: u32 = 0;
    var sgr_b: u32 = 0;
    var sgr_type: u8 = ' ';

    if (bytes[2] == 'M') {
        if (bytes.len < idx + 3) return null;
        b = bytes[idx];
        x = bytes[idx + 1];
        y = bytes[idx + 2];
        idx += 3;

        if (b < 0x20 or x < 0x21 or y < 0x21) return ignore_event(event, idx);
        b -= 0x20;
        x -= 0x21;
        y -= 0x21;
    } else if (bytes[2] == '<') {
        sgr_b = parse_mouse_number(bytes, &idx) orelse return null;
        if (idx >= bytes.len or bytes[idx] != ';') return ignore_event(event, idx);
        idx += 1;

        x = parse_mouse_number(bytes, &idx) orelse return null;
        if (idx >= bytes.len or bytes[idx] != ';') return ignore_event(event, idx);
        idx += 1;

        y = parse_mouse_number(bytes, &idx) orelse return null;
        if (idx >= bytes.len) return null;
        sgr_type = bytes[idx];
        idx += 1;

        if (sgr_type != 'M' and sgr_type != 'm') return ignore_event(event, idx);
        if (x < 1 or y < 1) return ignore_event(event, idx);

        x -= 1;
        y -= 1;
        b = sgr_b;
        if (sgr_type == 'm') b = 3;
        if (sgr_type == 'm' and T.mouseWheel(sgr_b)) return ignore_event(event, idx);
    } else return null;

    const last_x = if (tty) |t| t.mouse_last_x else 0;
    const last_y = if (tty) |t| t.mouse_last_y else 0;
    const last_b = if (tty) |t| t.mouse_last_b else 0;
    if (tty) |t| {
        t.mouse_last_x = x;
        t.mouse_last_y = y;
        t.mouse_last_b = b;
    }

    _ = fill_event(event, T.KEYC_MOUSE, bytes[0..idx]);
    event.m = .{
        .x = x,
        .y = y,
        .b = b,
        .lx = last_x,
        .ly = last_y,
        .lb = last_b,
        .sgr_type = sgr_type,
        .sgr_b = sgr_b,
    };
    return idx;
}

fn parse_mouse_number(bytes: []const u8, idx: *usize) ?u32 {
    var value: u32 = 0;
    var saw_digit = false;
    while (idx.* < bytes.len) : (idx.* += 1) {
        const ch = bytes[idx.*];
        if (ch < '0' or ch > '9') break;
        saw_digit = true;
        value = value * 10 + (ch - '0');
    }
    if (!saw_digit) return null;
    return value;
}

fn ignore_event(event: *T.key_event, consumed: usize) usize {
    event.* = .{};
    return consumed;
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

fn input_key_pane_visible(wp: *T.WindowPane) bool {
    if (wp.window.flags & T.WINDOW_ZOOMED == 0) return true;
    return wp.window.active == wp;
}

fn input_key_mouse_at(wp: *T.WindowPane, m: *const T.MouseEvent, last: bool) ?struct { x: u32, y: u32 } {
    const x = (if (last) m.lx else m.x) + m.ox;
    var y = (if (last) m.ly else m.y) + m.oy;

    if (m.statusat == 0 and y >= m.statuslines)
        y -= m.statuslines;

    if (x < wp.xoff or x >= wp.xoff + wp.sx) return null;
    if (y < wp.yoff or y >= wp.yoff + wp.sy) return null;

    return .{
        .x = x - wp.xoff,
        .y = y - wp.yoff,
    };
}

fn input_key_get_mouse(screen: *const T.Screen, m: *const T.MouseEvent, x: u32, y: u32, buf: *[40]u8) []const u8 {
    if (T.mouseDrag(m.b) and (screen.mode & T.MOTION_MOUSE_MODES) == 0)
        return buf[0..0];
    if ((screen.mode & T.ALL_MOUSE_MODES) == 0)
        return buf[0..0];

    if (m.sgr_type != ' ') {
        if (T.mouseDrag(m.sgr_b) and T.mouseRelease(m.sgr_b) and (screen.mode & T.MODE_MOUSE_ALL) == 0)
            return buf[0..0];
    } else {
        if (T.mouseDrag(m.b) and T.mouseRelease(m.b) and T.mouseRelease(m.lb) and (screen.mode & T.MODE_MOUSE_ALL) == 0)
            return buf[0..0];
    }

    if (m.sgr_type != ' ' and (screen.mode & T.MODE_MOUSE_SGR) != 0) {
        return std.fmt.bufPrint(buf, "\x1b[<{d};{d};{d}{c}", .{
            m.sgr_b,
            x + 1,
            y + 1,
            m.sgr_type,
        }) catch buf[0..0];
    }

    var len: usize = 0;
    buf[len] = 0x1b;
    len += 1;
    buf[len] = '[';
    len += 1;
    buf[len] = 'M';
    len += 1;

    if ((screen.mode & T.MODE_MOUSE_UTF8) != 0) {
        if (m.b > MOUSE_PARAM_UTF8_MAX - MOUSE_PARAM_BTN_OFF or
            x > MOUSE_PARAM_UTF8_MAX - MOUSE_PARAM_POS_OFF or
            y > MOUSE_PARAM_UTF8_MAX - MOUSE_PARAM_POS_OFF)
        {
            return buf[0..0];
        }

        len += input_key_split2(m.b + MOUSE_PARAM_BTN_OFF, buf[len..]);
        len += input_key_split2(x + MOUSE_PARAM_POS_OFF, buf[len..]);
        len += input_key_split2(y + MOUSE_PARAM_POS_OFF, buf[len..]);
        return buf[0..len];
    }

    if (m.b + MOUSE_PARAM_BTN_OFF > MOUSE_PARAM_MAX)
        return buf[0..0];

    buf[len] = @intCast(m.b + MOUSE_PARAM_BTN_OFF);
    len += 1;
    buf[len] = @intCast(@min(MOUSE_PARAM_MAX, x + MOUSE_PARAM_POS_OFF));
    len += 1;
    buf[len] = @intCast(@min(MOUSE_PARAM_MAX, y + MOUSE_PARAM_POS_OFF));
    len += 1;
    return buf[0..len];
}

fn input_key_split2(c: u32, dst: []u8) usize {
    if (c > 0x7f) {
        dst[0] = @intCast((c >> 6) | 0xc0);
        dst[1] = @intCast((c & 0x3f) | 0x80);
        return 2;
    }
    dst[0] = @intCast(c);
    return 1;
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

fn effective_screen_mode(screen: *const T.Screen) i32 {
    var mode = screen.mode;
    if (opts.options_get_number(opts.global_options, "extended-keys") == 2 and
        mode & T.EXTENDED_KEY_MODES == 0)
        mode |= T.MODE_KEYS_EXTENDED;
    return mode;
}

fn configured_backspace_key() T.key_code {
    const raw = opts.options_get_string(opts.global_options, "backspace");
    if (raw.len == 0) return 0x7f;

    const parsed = key_string.key_string_lookup_string(raw);
    if (parsed != T.KEYC_UNKNOWN and parsed != T.KEYC_NONE) return parsed;
    if (raw.len == 1) return raw[0];
    return 0x7f;
}

fn backspace_byte_for_key(key: T.key_code) ?u8 {
    const modifiers = key & T.KEYC_MASK_MODIFIERS;
    if (modifiers == 0) {
        const masked = key & T.KEYC_MASK_KEY;
        if (masked <= 0xff) return @intCast(masked);
        return null;
    }
    if (modifiers != T.KEYC_CTRL) return null;

    const masked = key & T.KEYC_MASK_KEY;
    if (masked == '?') return 0x7f;
    if (masked >= '@' and masked <= '_') return @intCast(masked - 0x40);
    if (masked >= 'a' and masked <= 'z') return @intCast(masked - 0x60);
    return null;
}

fn encode_lookup_key(key: T.key_code, buf: *[32]u8) ?[]const u8 {
    if (encode_exact_lookup_key(key, buf)) |seq| return seq;

    if (key & T.KEYC_META != 0 and key & T.KEYC_IMPLIED_META == 0) {
        if (encode_exact_lookup_key(key & ~T.KEYC_META, buf[1..])) |seq| {
            buf[0] = 0x1b;
            return buf[0 .. 1 + seq.len];
        }
    }
    if (key & T.KEYC_CURSOR != 0) return encode_exact_lookup_key(key & ~T.KEYC_CURSOR, buf);
    if (key & T.KEYC_KEYPAD != 0) return encode_exact_lookup_key(key & ~T.KEYC_KEYPAD, buf);
    return null;
}

fn encode_exact_lookup_key(key: T.key_code, buf: []u8) ?[]const u8 {
    const key_no_implied = key & ~T.KEYC_IMPLIED_META;
    const masked = key_no_implied & T.KEYC_MASK_KEY;
    const modifiers = key_no_implied & T.KEYC_MASK_MODIFIERS;
    const flags = key_no_implied & (T.KEYC_CURSOR | T.KEYC_KEYPAD);

    if (flags == 0) {
        if (modifierTemplateFor(masked)) |template| {
            if (modifierParameter(modifiers)) |parameter| {
                if (template.len > buf.len) return null;
                for (template, 0..) |ch, idx| {
                    buf[idx] = if (ch == '_') parameter else ch;
                }
                return buf[0..template.len];
            }
        }
    }

    if (flags == 0 and modifiers == 0) {
        if (fixedSequenceFor(masked)) |seq| {
            if (seq.len > buf.len) return null;
            std.mem.copyForwards(u8, buf[0..seq.len], seq);
            return buf[0..seq.len];
        }
        if (pasteSequenceFor(masked)) |seq| {
            if (seq.len > buf.len) return null;
            std.mem.copyForwards(u8, buf[0..seq.len], seq);
            return buf[0..seq.len];
        }
    }

    if (flags == T.KEYC_CURSOR and modifiers == 0) {
        if (cursorSequenceFor(masked)) |seq| {
            if (seq.len > buf.len) return null;
            std.mem.copyForwards(u8, buf[0..seq.len], seq);
            return buf[0..seq.len];
        }
    }

    if (flags == T.KEYC_KEYPAD and modifiers == 0) {
        if (keypadApplicationSequenceFor(masked)) |seq| {
            if (seq.len > buf.len) return null;
            std.mem.copyForwards(u8, buf[0..seq.len], seq);
            return buf[0..seq.len];
        }
    }

    return null;
}

fn pasteSequenceFor(masked: T.key_code) ?[]const u8 {
    return switch (masked) {
        T.KEYC_PASTE_START => "\x1b[200~",
        T.KEYC_PASTE_END => "\x1b[201~",
        else => null,
    };
}

fn cursorSequenceFor(masked: T.key_code) ?[]const u8 {
    return switch (masked) {
        T.KEYC_UP => "\x1bOA",
        T.KEYC_DOWN => "\x1bOB",
        T.KEYC_RIGHT => "\x1bOC",
        T.KEYC_LEFT => "\x1bOD",
        else => null,
    };
}

fn keypadApplicationSequenceFor(masked: T.key_code) ?[]const u8 {
    return switch (masked) {
        T.KEYC_KP_SLASH => "\x1bOo",
        T.KEYC_KP_STAR => "\x1bOj",
        T.KEYC_KP_MINUS => "\x1bOm",
        T.KEYC_KP_SEVEN => "\x1bOw",
        T.KEYC_KP_EIGHT => "\x1bOx",
        T.KEYC_KP_NINE => "\x1bOy",
        T.KEYC_KP_PLUS => "\x1bOk",
        T.KEYC_KP_FOUR => "\x1bOt",
        T.KEYC_KP_FIVE => "\x1bOu",
        T.KEYC_KP_SIX => "\x1bOv",
        T.KEYC_KP_ONE => "\x1bOq",
        T.KEYC_KP_TWO => "\x1bOr",
        T.KEYC_KP_THREE => "\x1bOs",
        T.KEYC_KP_ENTER => "\x1bOM",
        T.KEYC_KP_ZERO => "\x1bOp",
        T.KEYC_KP_PERIOD => "\x1bOn",
        else => null,
    };
}

fn encode_extended_key(key_in: T.key_code, buf: *[32]u8) error{UnsupportedKey}![]const u8 {
    const key = key_in & ~T.KEYC_IMPLIED_META;
    const modifier = modifierParameter(key & T.KEYC_MASK_MODIFIERS) orelse return error.UnsupportedKey;

    var base_key = key & T.KEYC_MASK_KEY;
    if (T.keycIsUnicode(key)) {
        var ud: T.Utf8Data = undefined;
        var wc: u32 = 0;
        utf8.utf8_to_data(@intCast(base_key), &ud);
        if (utf8.utf8_from_data(&ud, &wc) != .done) return error.UnsupportedKey;
        base_key = wc;
    }

    return if (opts.options_get_number(opts.global_options, "extended-keys-format") == 1)
        std.fmt.bufPrint(buf, "\x1b[27;{c};{}~", .{ modifier, base_key }) catch error.UnsupportedKey
    else
        std.fmt.bufPrint(buf, "\x1b[{};{c}u", .{ base_key, modifier }) catch error.UnsupportedKey;
}

fn encode_vt10x_key(key_in: T.key_code, buf: *[32]u8) error{UnsupportedKey}![]const u8 {
    var key = key_in & ~T.KEYC_IMPLIED_META;
    var start: usize = 0;

    if (key & T.KEYC_META != 0) {
        buf[0] = 0x1b;
        start = 1;
    }

    if (T.keycIsUnicode(key)) {
        const codepoint: u21 = std.math.cast(u21, key & T.KEYC_MASK_KEY) orelse return error.UnsupportedKey;
        const size = std.unicode.utf8Encode(codepoint, buf[start..]) catch return error.UnsupportedKey;
        return buf[0 .. start + size];
    }

    const onlykey = key & T.KEYC_MASK_KEY;
    if (onlykey == '\r' or onlykey == '\n' or onlykey == '\t') key &= ~T.KEYC_CTRL;

    if (key & T.KEYC_CTRL != 0) {
        key = ctrl_ascii_byte(onlykey) orelse return error.UnsupportedKey;
    } else {
        key = onlykey;
    }

    if (key > 0x7f) return error.UnsupportedKey;
    buf[start] = @intCast(key);
    return buf[0 .. start + 1];
}

fn encode_mode1_key(key: T.key_code, buf: *[32]u8) ?[]const u8 {
    const onlykey = key & T.KEYC_MASK_KEY;

    if ((key & (T.KEYC_CTRL | T.KEYC_META)) == T.KEYC_META)
        return encode_vt10x_key(key, buf) catch null;

    if (key & T.KEYC_CTRL != 0 and
        (onlykey == ' ' or
            onlykey == '/' or
            onlykey == '@' or
            onlykey == '^' or
            (onlykey >= '2' and onlykey <= '8') or
            (onlykey >= '@' and onlykey <= '~')))
        return encode_vt10x_key(key, buf) catch null;

    return null;
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

test "input_key_get_client decodes mouse sequences and tracks the previous state" {
    const env_mod = @import("environ.zig");

    var client = T.Client{
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{ .screen = undefined },
    };
    defer env_mod.environ_free(client.environ);
    client.tty = .{ .client = &client };

    var event: T.key_event = .{};
    const down = "\x1b[<0;3;4M";
    try std.testing.expectEqual(down.len, input_key_get_client(&client, down, &event).?);
    try std.testing.expectEqual(T.KEYC_MOUSE, event.key);
    try std.testing.expectEqual(@as(u32, 2), event.m.x);
    try std.testing.expectEqual(@as(u32, 3), event.m.y);
    try std.testing.expectEqual(@as(u32, 0), event.m.b);
    try std.testing.expectEqual(@as(u32, 0), event.m.lx);
    try std.testing.expectEqual(@as(u32, 0), event.m.ly);
    try std.testing.expectEqual(@as(u32, 0), event.m.lb);

    var release: T.key_event = .{};
    const up = "\x1b[<0;5;6m";
    try std.testing.expectEqual(up.len, input_key_get_client(&client, up, &release).?);
    try std.testing.expectEqual(T.KEYC_MOUSE, release.key);
    try std.testing.expectEqual(@as(u32, 4), release.m.x);
    try std.testing.expectEqual(@as(u32, 5), release.m.y);
    try std.testing.expectEqual(@as(u32, 2), release.m.lx);
    try std.testing.expectEqual(@as(u32, 3), release.m.ly);
    try std.testing.expectEqual(@as(u32, 0), release.m.lb);
    try std.testing.expectEqual(@as(u32, 3), release.m.b);
    try std.testing.expectEqual(@as(u32, 0), release.m.sgr_b);
    try std.testing.expectEqual(@as(u8, 'm'), release.m.sgr_type);
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

test "input_key_encode_screen honors screen mode dependent mappings" {
    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);

    var dummy_grid: T.Grid = undefined;
    var screen = T.Screen{ .grid = &dummy_grid };
    var buf: [32]u8 = undefined;

    try std.testing.expectEqualStrings("\x1b[A", try input_key_encode_screen(&screen, T.KEYC_UP | T.KEYC_CURSOR, &buf));
    screen.mode = T.MODE_KCURSOR;
    try std.testing.expectEqualStrings("\x1bOA", try input_key_encode_screen(&screen, T.KEYC_UP | T.KEYC_CURSOR, &buf));

    screen.mode = 0;
    try std.testing.expectEqualStrings("1", try input_key_encode_screen(&screen, T.KEYC_KP_ONE | T.KEYC_KEYPAD, &buf));
    screen.mode = T.MODE_KKEYPAD;
    try std.testing.expectEqualStrings("\x1bOq", try input_key_encode_screen(&screen, T.KEYC_KP_ONE | T.KEYC_KEYPAD, &buf));

    screen.mode = 0;
    try std.testing.expectEqual(@as(usize, 0), (try input_key_encode_screen(&screen, T.KEYC_PASTE_START, &buf)).len);
    screen.mode = T.MODE_BRACKETPASTE;
    try std.testing.expectEqualStrings("\x1b[200~", try input_key_encode_screen(&screen, T.KEYC_PASTE_START, &buf));
}

test "input_key_encode_screen ports backspace and extended-key options" {
    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);

    var dummy_grid: T.Grid = undefined;
    var screen = T.Screen{ .grid = &dummy_grid };
    var buf: [32]u8 = undefined;

    opts.options_set_string(opts.global_options, false, "backspace", "C-h");
    const backspace = try input_key_encode_screen(&screen, T.KEYC_BSPACE, &buf);
    try std.testing.expectEqual(@as(usize, 1), backspace.len);
    try std.testing.expectEqual(@as(u8, 0x08), backspace[0]);

    screen.mode = T.MODE_KEYS_EXTENDED_2;
    try std.testing.expectEqualStrings("\x1b[27;2;9~", try input_key_encode_screen(&screen, T.KEYC_BTAB, &buf));
}

test "input_key_mouse_pane encodes SGR mouse bytes with pane-relative coordinates" {
    const win = @import("window.zig");
    const xm = @import("xmalloc.zig");

    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    win.window_init_globals(xm.allocator);

    const w = win.window_create(4, 2, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    defer {
        while (w.panes.items.len > 0) {
            const pane = w.panes.items[w.panes.items.len - 1];
            win.window_remove_pane(w, pane);
        }
        w.panes.deinit(xm.allocator);
        w.last_panes.deinit(xm.allocator);
        opts.options_free(w.options);
        xm.allocator.free(w.name);
        _ = win.windows.remove(w.id);
        xm.allocator.destroy(w);
    }

    const wp = win.window_add_pane(w, null, 4, 2);
    w.active = wp;
    wp.base.mode |= T.MODE_MOUSE_ALL | T.MODE_MOUSE_SGR;
    wp.xoff = 3;
    wp.yoff = 2;

    var mouse = T.MouseEvent{
        .valid = true,
        .wp = @intCast(wp.id),
        .x = 4,
        .y = 4,
        .b = T.MOUSE_BUTTON_1,
        .statusat = 0,
        .statuslines = 1,
        .sgr_type = 'M',
        .sgr_b = T.MOUSE_BUTTON_1,
    };
    var buf: [40]u8 = undefined;
    try std.testing.expectEqualStrings("\x1b[<0;2;2M", input_key_mouse_pane(wp, &mouse, &buf));
}
