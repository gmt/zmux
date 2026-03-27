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
// Ported from tmux/key-string.c
// Original copyright:
//   Copyright (c) 2007 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

const std = @import("std");
const T = @import("types.zig");
const utf8 = @import("utf8.zig");

const KeyString = struct {
    string: []const u8,
    key: T.key_code,
};

const MouseFamily = struct {
    name: []const u8,
    base: T.key_code,
};

const MouseTargetName = struct {
    name: []const u8,
    target: T.KeyMouseTarget,
};

const MouseMatch = struct {
    family: []const u8,
    target: []const u8,
};

threadlocal var out_buf: [64]u8 = undefined;

const key_string_table = [_]KeyString{
    .{ .string = "F1", .key = T.KEYC_F1 | T.KEYC_IMPLIED_META },
    .{ .string = "F2", .key = T.KEYC_F2 | T.KEYC_IMPLIED_META },
    .{ .string = "F3", .key = T.KEYC_F3 | T.KEYC_IMPLIED_META },
    .{ .string = "F4", .key = T.KEYC_F4 | T.KEYC_IMPLIED_META },
    .{ .string = "F5", .key = T.KEYC_F5 | T.KEYC_IMPLIED_META },
    .{ .string = "F6", .key = T.KEYC_F6 | T.KEYC_IMPLIED_META },
    .{ .string = "F7", .key = T.KEYC_F7 | T.KEYC_IMPLIED_META },
    .{ .string = "F8", .key = T.KEYC_F8 | T.KEYC_IMPLIED_META },
    .{ .string = "F9", .key = T.KEYC_F9 | T.KEYC_IMPLIED_META },
    .{ .string = "F10", .key = T.KEYC_F10 | T.KEYC_IMPLIED_META },
    .{ .string = "F11", .key = T.KEYC_F11 | T.KEYC_IMPLIED_META },
    .{ .string = "F12", .key = T.KEYC_F12 | T.KEYC_IMPLIED_META },
    .{ .string = "IC", .key = T.KEYC_IC | T.KEYC_IMPLIED_META },
    .{ .string = "Insert", .key = T.KEYC_IC | T.KEYC_IMPLIED_META },
    .{ .string = "DC", .key = T.KEYC_DC | T.KEYC_IMPLIED_META },
    .{ .string = "Delete", .key = T.KEYC_DC | T.KEYC_IMPLIED_META },
    .{ .string = "Home", .key = T.KEYC_HOME | T.KEYC_IMPLIED_META },
    .{ .string = "End", .key = T.KEYC_END | T.KEYC_IMPLIED_META },
    .{ .string = "NPage", .key = T.KEYC_NPAGE | T.KEYC_IMPLIED_META },
    .{ .string = "PageDown", .key = T.KEYC_NPAGE | T.KEYC_IMPLIED_META },
    .{ .string = "PgDn", .key = T.KEYC_NPAGE | T.KEYC_IMPLIED_META },
    .{ .string = "PPage", .key = T.KEYC_PPAGE | T.KEYC_IMPLIED_META },
    .{ .string = "PageUp", .key = T.KEYC_PPAGE | T.KEYC_IMPLIED_META },
    .{ .string = "PgUp", .key = T.KEYC_PPAGE | T.KEYC_IMPLIED_META },
    .{ .string = "BTab", .key = T.KEYC_BTAB },
    .{ .string = "Space", .key = ' ' },
    .{ .string = "BSpace", .key = T.KEYC_BSPACE },

    .{ .string = "[NUL]", .key = T.C0_NUL },
    .{ .string = "[SOH]", .key = T.C0_SOH },
    .{ .string = "[STX]", .key = T.C0_STX },
    .{ .string = "[ETX]", .key = T.C0_ETX },
    .{ .string = "[EOT]", .key = T.C0_EOT },
    .{ .string = "[ENQ]", .key = T.C0_ENQ },
    .{ .string = "[ASC]", .key = T.C0_ASC },
    .{ .string = "[BEL]", .key = T.C0_BEL },
    .{ .string = "[BS]", .key = T.C0_BS },
    .{ .string = "Tab", .key = T.C0_HT },
    .{ .string = "[LF]", .key = T.C0_LF },
    .{ .string = "[VT]", .key = T.C0_VT },
    .{ .string = "[FF]", .key = T.C0_FF },
    .{ .string = "Enter", .key = T.C0_CR },
    .{ .string = "[SO]", .key = T.C0_SO },
    .{ .string = "[SI]", .key = T.C0_SI },
    .{ .string = "[DLE]", .key = T.C0_DLE },
    .{ .string = "[DC1]", .key = T.C0_DC1 },
    .{ .string = "[DC2]", .key = T.C0_DC2 },
    .{ .string = "[DC3]", .key = T.C0_DC3 },
    .{ .string = "[DC4]", .key = T.C0_DC4 },
    .{ .string = "[NAK]", .key = T.C0_NAK },
    .{ .string = "[SYN]", .key = T.C0_SYN },
    .{ .string = "[ETB]", .key = T.C0_ETB },
    .{ .string = "[CAN]", .key = T.C0_CAN },
    .{ .string = "[EM]", .key = T.C0_EM },
    .{ .string = "[SUB]", .key = T.C0_SUB },
    .{ .string = "Escape", .key = T.C0_ESC },
    .{ .string = "[FS]", .key = T.C0_FS },
    .{ .string = "[GS]", .key = T.C0_GS },
    .{ .string = "[RS]", .key = T.C0_RS },
    .{ .string = "[US]", .key = T.C0_US },

    .{ .string = "Up", .key = T.KEYC_UP | T.KEYC_CURSOR | T.KEYC_IMPLIED_META },
    .{ .string = "Down", .key = T.KEYC_DOWN | T.KEYC_CURSOR | T.KEYC_IMPLIED_META },
    .{ .string = "Left", .key = T.KEYC_LEFT | T.KEYC_CURSOR | T.KEYC_IMPLIED_META },
    .{ .string = "Right", .key = T.KEYC_RIGHT | T.KEYC_CURSOR | T.KEYC_IMPLIED_META },

    .{ .string = "KP/", .key = T.KEYC_KP_SLASH | T.KEYC_KEYPAD },
    .{ .string = "KP*", .key = T.KEYC_KP_STAR | T.KEYC_KEYPAD },
    .{ .string = "KP-", .key = T.KEYC_KP_MINUS | T.KEYC_KEYPAD },
    .{ .string = "KP7", .key = T.KEYC_KP_SEVEN | T.KEYC_KEYPAD },
    .{ .string = "KP8", .key = T.KEYC_KP_EIGHT | T.KEYC_KEYPAD },
    .{ .string = "KP9", .key = T.KEYC_KP_NINE | T.KEYC_KEYPAD },
    .{ .string = "KP+", .key = T.KEYC_KP_PLUS | T.KEYC_KEYPAD },
    .{ .string = "KP4", .key = T.KEYC_KP_FOUR | T.KEYC_KEYPAD },
    .{ .string = "KP5", .key = T.KEYC_KP_FIVE | T.KEYC_KEYPAD },
    .{ .string = "KP6", .key = T.KEYC_KP_SIX | T.KEYC_KEYPAD },
    .{ .string = "KP1", .key = T.KEYC_KP_ONE | T.KEYC_KEYPAD },
    .{ .string = "KP2", .key = T.KEYC_KP_TWO | T.KEYC_KEYPAD },
    .{ .string = "KP3", .key = T.KEYC_KP_THREE | T.KEYC_KEYPAD },
    .{ .string = "KPEnter", .key = T.KEYC_KP_ENTER | T.KEYC_KEYPAD },
    .{ .string = "KP0", .key = T.KEYC_KP_ZERO | T.KEYC_KEYPAD },
    .{ .string = "KP.", .key = T.KEYC_KP_PERIOD | T.KEYC_KEYPAD },
};

const mouse_family_names = [_]MouseFamily{
    .{ .name = "MouseMove", .base = T.KEYC_MOUSEMOVE },
    .{ .name = "MouseDown1", .base = T.KEYC_MOUSEDOWN1 },
    .{ .name = "MouseDown2", .base = T.KEYC_MOUSEDOWN2 },
    .{ .name = "MouseDown3", .base = T.KEYC_MOUSEDOWN3 },
    .{ .name = "MouseDown6", .base = T.KEYC_MOUSEDOWN6 },
    .{ .name = "MouseDown7", .base = T.KEYC_MOUSEDOWN7 },
    .{ .name = "MouseDown8", .base = T.KEYC_MOUSEDOWN8 },
    .{ .name = "MouseDown9", .base = T.KEYC_MOUSEDOWN9 },
    .{ .name = "MouseDown10", .base = T.KEYC_MOUSEDOWN10 },
    .{ .name = "MouseDown11", .base = T.KEYC_MOUSEDOWN11 },
    .{ .name = "MouseUp1", .base = T.KEYC_MOUSEUP1 },
    .{ .name = "MouseUp2", .base = T.KEYC_MOUSEUP2 },
    .{ .name = "MouseUp3", .base = T.KEYC_MOUSEUP3 },
    .{ .name = "MouseUp6", .base = T.KEYC_MOUSEUP6 },
    .{ .name = "MouseUp7", .base = T.KEYC_MOUSEUP7 },
    .{ .name = "MouseUp8", .base = T.KEYC_MOUSEUP8 },
    .{ .name = "MouseUp9", .base = T.KEYC_MOUSEUP9 },
    .{ .name = "MouseUp10", .base = T.KEYC_MOUSEUP10 },
    .{ .name = "MouseUp11", .base = T.KEYC_MOUSEUP11 },
    .{ .name = "MouseDrag1", .base = T.KEYC_MOUSEDRAG1 },
    .{ .name = "MouseDrag2", .base = T.KEYC_MOUSEDRAG2 },
    .{ .name = "MouseDrag3", .base = T.KEYC_MOUSEDRAG3 },
    .{ .name = "MouseDrag6", .base = T.KEYC_MOUSEDRAG6 },
    .{ .name = "MouseDrag7", .base = T.KEYC_MOUSEDRAG7 },
    .{ .name = "MouseDrag8", .base = T.KEYC_MOUSEDRAG8 },
    .{ .name = "MouseDrag9", .base = T.KEYC_MOUSEDRAG9 },
    .{ .name = "MouseDrag10", .base = T.KEYC_MOUSEDRAG10 },
    .{ .name = "MouseDrag11", .base = T.KEYC_MOUSEDRAG11 },
    .{ .name = "MouseDragEnd1", .base = T.KEYC_MOUSEDRAGEND1 },
    .{ .name = "MouseDragEnd2", .base = T.KEYC_MOUSEDRAGEND2 },
    .{ .name = "MouseDragEnd3", .base = T.KEYC_MOUSEDRAGEND3 },
    .{ .name = "MouseDragEnd6", .base = T.KEYC_MOUSEDRAGEND6 },
    .{ .name = "MouseDragEnd7", .base = T.KEYC_MOUSEDRAGEND7 },
    .{ .name = "MouseDragEnd8", .base = T.KEYC_MOUSEDRAGEND8 },
    .{ .name = "MouseDragEnd9", .base = T.KEYC_MOUSEDRAGEND9 },
    .{ .name = "MouseDragEnd10", .base = T.KEYC_MOUSEDRAGEND10 },
    .{ .name = "MouseDragEnd11", .base = T.KEYC_MOUSEDRAGEND11 },
    .{ .name = "WheelUp", .base = T.KEYC_WHEELUP },
    .{ .name = "WheelDown", .base = T.KEYC_WHEELDOWN },
    .{ .name = "SecondClick1", .base = T.KEYC_SECONDCLICK1 },
    .{ .name = "SecondClick2", .base = T.KEYC_SECONDCLICK2 },
    .{ .name = "SecondClick3", .base = T.KEYC_SECONDCLICK3 },
    .{ .name = "SecondClick6", .base = T.KEYC_SECONDCLICK6 },
    .{ .name = "SecondClick7", .base = T.KEYC_SECONDCLICK7 },
    .{ .name = "SecondClick8", .base = T.KEYC_SECONDCLICK8 },
    .{ .name = "SecondClick9", .base = T.KEYC_SECONDCLICK9 },
    .{ .name = "SecondClick10", .base = T.KEYC_SECONDCLICK10 },
    .{ .name = "SecondClick11", .base = T.KEYC_SECONDCLICK11 },
    .{ .name = "DoubleClick1", .base = T.KEYC_DOUBLECLICK1 },
    .{ .name = "DoubleClick2", .base = T.KEYC_DOUBLECLICK2 },
    .{ .name = "DoubleClick3", .base = T.KEYC_DOUBLECLICK3 },
    .{ .name = "DoubleClick6", .base = T.KEYC_DOUBLECLICK6 },
    .{ .name = "DoubleClick7", .base = T.KEYC_DOUBLECLICK7 },
    .{ .name = "DoubleClick8", .base = T.KEYC_DOUBLECLICK8 },
    .{ .name = "DoubleClick9", .base = T.KEYC_DOUBLECLICK9 },
    .{ .name = "DoubleClick10", .base = T.KEYC_DOUBLECLICK10 },
    .{ .name = "DoubleClick11", .base = T.KEYC_DOUBLECLICK11 },
    .{ .name = "TripleClick1", .base = T.KEYC_TRIPLECLICK1 },
    .{ .name = "TripleClick2", .base = T.KEYC_TRIPLECLICK2 },
    .{ .name = "TripleClick3", .base = T.KEYC_TRIPLECLICK3 },
    .{ .name = "TripleClick6", .base = T.KEYC_TRIPLECLICK6 },
    .{ .name = "TripleClick7", .base = T.KEYC_TRIPLECLICK7 },
    .{ .name = "TripleClick8", .base = T.KEYC_TRIPLECLICK8 },
    .{ .name = "TripleClick9", .base = T.KEYC_TRIPLECLICK9 },
    .{ .name = "TripleClick10", .base = T.KEYC_TRIPLECLICK10 },
    .{ .name = "TripleClick11", .base = T.KEYC_TRIPLECLICK11 },
};

const mouse_target_names = [_]MouseTargetName{
    .{ .name = "Pane", .target = .pane },
    .{ .name = "Status", .target = .status },
    .{ .name = "StatusLeft", .target = .status_left },
    .{ .name = "StatusRight", .target = .status_right },
    .{ .name = "StatusDefault", .target = .status_default },
    .{ .name = "ScrollbarUp", .target = .scrollbar_up },
    .{ .name = "ScrollbarSlider", .target = .scrollbar_slider },
    .{ .name = "ScrollbarDown", .target = .scrollbar_down },
    .{ .name = "Border", .target = .border },
};

pub fn key_string_lookup_string(string: []const u8) T.key_code {
    var s = string;
    var modifiers: T.key_code = 0;

    if (std.ascii.eqlIgnoreCase(s, "None")) return T.KEYC_NONE;
    if (std.ascii.eqlIgnoreCase(s, "Any")) return T.KEYC_ANY;

    if (s.len > 2 and s[0] == '0' and (s[1] == 'x' or s[1] == 'X')) {
        const value = std.fmt.parseInt(u32, s[2..], 16) catch return T.KEYC_UNKNOWN;
        if (value < 32) return value;
        return keyCodeFromCodepoint(value) orelse T.KEYC_UNKNOWN;
    }

    if (s.len >= 2 and s[0] == '^') {
        if (s.len == 2) return std.ascii.toLower(s[1]) | T.KEYC_CTRL;
        modifiers |= T.KEYC_CTRL;
        s = s[1..];
    }

    if (key_string_get_modifiers(&s)) |more| {
        modifiers |= more;
    } else {
        return T.KEYC_UNKNOWN;
    }
    if (s.len == 0) return T.KEYC_UNKNOWN;

    if (s.len == 1 and s[0] <= 127) {
        const key = s[0];
        if (key < 32) return T.KEYC_UNKNOWN;
        return key | modifiers;
    }

    var ud: T.Utf8Data = undefined;
    if (utf8.utf8_open(&ud, s[0]) == .more) {
        if (s.len != ud.size) return T.KEYC_UNKNOWN;
        var state: T.Utf8State = .more;
        var i: usize = 1;
        while (i < ud.size and state == .more) : (i += 1) {
            state = utf8.utf8_append(&ud, s[i]);
        }
        if (state == .done) {
            var uc: T.utf8_char = 0;
            if (utf8.utf8_from_data(&ud, &uc) == .done)
                return @as(T.key_code, uc) | modifiers;
            return T.KEYC_UNKNOWN;
        }
    }

    var key = key_string_search_table(s);
    if (key == T.KEYC_UNKNOWN) return T.KEYC_UNKNOWN;
    if (modifiers & T.KEYC_META == 0) key &= ~T.KEYC_IMPLIED_META;
    return key | modifiers;
}

pub fn key_string_lookup_key(key_in: T.key_code, with_flags: i32) []const u8 {
    var key = key_in;
    const saved = key;
    var stream = std.io.fixedBufferStream(&out_buf);
    const writer = stream.writer();

    if (key & T.KEYC_LITERAL != 0) {
        writer.writeByte(@intCast(key & 0xff)) catch unreachable;
        return stream.getWritten();
    }

    if (key & T.KEYC_CTRL != 0) writer.writeAll("C-") catch unreachable;
    if (key & T.KEYC_META != 0) writer.writeAll("M-") catch unreachable;
    if (key & T.KEYC_SHIFT != 0) writer.writeAll("S-") catch unreachable;
    key &= T.KEYC_MASK_KEY;

    if (key == T.KEYC_NONE) {
        writer.writeAll("None") catch unreachable;
        return finishFlags(saved, with_flags, &stream);
    }
    if (key == T.KEYC_UNKNOWN) {
        writer.writeAll("Unknown") catch unreachable;
        return finishFlags(saved, with_flags, &stream);
    }
    if (key == T.KEYC_ANY) {
        writer.writeAll("Any") catch unreachable;
        return finishFlags(saved, with_flags, &stream);
    }
    if (key == T.KEYC_FOCUS_IN) {
        writer.writeAll("FocusIn") catch unreachable;
        return finishFlags(saved, with_flags, &stream);
    }
    if (key == T.KEYC_FOCUS_OUT) {
        writer.writeAll("FocusOut") catch unreachable;
        return finishFlags(saved, with_flags, &stream);
    }
    if (key == T.KEYC_PASTE_START) {
        writer.writeAll("PasteStart") catch unreachable;
        return finishFlags(saved, with_flags, &stream);
    }
    if (key == T.KEYC_PASTE_END) {
        writer.writeAll("PasteEnd") catch unreachable;
        return finishFlags(saved, with_flags, &stream);
    }
    if (key == T.KEYC_REPORT_DARK_THEME) {
        writer.writeAll("ReportDarkTheme") catch unreachable;
        return finishFlags(saved, with_flags, &stream);
    }
    if (key == T.KEYC_REPORT_LIGHT_THEME) {
        writer.writeAll("ReportLightTheme") catch unreachable;
        return finishFlags(saved, with_flags, &stream);
    }
    if (key == T.KEYC_MOUSE) {
        writer.writeAll("Mouse") catch unreachable;
        return finishFlags(saved, with_flags, &stream);
    }
    if (key == T.KEYC_DRAGGING) {
        writer.writeAll("Dragging") catch unreachable;
        return finishFlags(saved, with_flags, &stream);
    }
    if (key >= T.KEYC_USER and key < T.KEYC_USER_END) {
        writer.print("User{d}", .{key - T.KEYC_USER}) catch unreachable;
        return finishFlags(saved, with_flags, &stream);
    }

    if (mouseKeyName(key)) |match| {
        writer.writeAll(match.family) catch unreachable;
        writer.writeAll(match.target) catch unreachable;
        return finishFlags(saved, with_flags, &stream);
    }

    for (key_string_table) |entry| {
        if (key == (entry.key & T.KEYC_MASK_KEY)) {
            writer.writeAll(entry.string) catch unreachable;
            return finishFlags(saved, with_flags, &stream);
        }
    }

    if (T.keycIsUnicode(key)) {
        var ud: T.Utf8Data = undefined;
        utf8.utf8_to_data(@intCast(key), &ud);
        writer.writeAll(ud.data[0..ud.size]) catch unreachable;
        return finishFlags(saved, with_flags, &stream);
    }

    if (key > 255) {
        writer.print("Invalid#{x}", .{saved}) catch unreachable;
        return finishFlags(saved, with_flags, &stream);
    }

    if (key > 32 and key <= 126) {
        writer.writeByte(@intCast(key)) catch unreachable;
    } else if (key == 127) {
        writer.writeAll("C-?") catch unreachable;
    } else if (key >= 128) {
        writer.print("\\{o}", .{key}) catch unreachable;
    }
    return finishFlags(saved, with_flags, &stream);
}

fn finishFlags(saved: T.key_code, with_flags: i32, stream: *std.io.FixedBufferStream([]u8)) []const u8 {
    if (with_flags != 0 and (saved & T.KEYC_MASK_FLAGS) != 0) {
        const writer = stream.writer();
        writer.writeByte('[') catch unreachable;
        if (saved & T.KEYC_LITERAL != 0) writer.writeByte('L') catch unreachable;
        if (saved & T.KEYC_KEYPAD != 0) writer.writeByte('K') catch unreachable;
        if (saved & T.KEYC_CURSOR != 0) writer.writeByte('C') catch unreachable;
        if (saved & T.KEYC_IMPLIED_META != 0) writer.writeByte('I') catch unreachable;
        if (saved & T.KEYC_BUILD_MODIFIERS != 0) writer.writeByte('B') catch unreachable;
        if (saved & T.KEYC_SENT != 0) writer.writeByte('S') catch unreachable;
        writer.writeByte(']') catch unreachable;
    }
    return stream.getWritten();
}

fn key_string_search_table(string: []const u8) T.key_code {
    for (key_string_table) |entry| {
        if (std.ascii.eqlIgnoreCase(string, entry.string)) return entry.key;
    }

    if (mouseKeyFromString(string)) |key| return key;

    if (string.len > 4 and std.ascii.startsWithIgnoreCase(string, "User")) {
        const user = std.fmt.parseInt(u32, string[4..], 10) catch return T.KEYC_UNKNOWN;
        if (user < T.KEYC_NUSER) return T.KEYC_USER + user;
    }

    return T.KEYC_UNKNOWN;
}

fn key_string_get_modifiers(string: *[]const u8) ?T.key_code {
    var s = string.*;
    var modifiers: T.key_code = 0;

    while (s.len >= 2 and s[1] == '-') {
        switch (s[0]) {
            'C', 'c' => modifiers |= T.KEYC_CTRL,
            'M', 'm' => modifiers |= T.KEYC_META,
            'S', 's' => modifiers |= T.KEYC_SHIFT,
            else => return null,
        }
        s = s[2..];
    }
    string.* = s;
    return modifiers;
}

fn mouseKeyFromString(string: []const u8) ?T.key_code {
    for (mouse_family_names) |family| {
        if (!std.ascii.startsWithIgnoreCase(string, family.name)) continue;
        const suffix = string[family.name.len..];
        for (mouse_target_names) |target| {
            if (std.ascii.eqlIgnoreCase(suffix, target.name))
                return T.keycMouse(family.base, target.target);
        }
    }
    return null;
}

fn mouseKeyName(key: T.key_code) ?MouseMatch {
    for (mouse_family_names) |family| {
        if (key < family.base or key >= family.base + T.KEYC_MOUSE_TARGET_COUNT) continue;
        const offset = key - family.base;
        for (mouse_target_names) |target| {
            if (offset == @intFromEnum(target.target)) {
                return .{ .family = family.name, .target = target.name };
            }
        }
    }
    return null;
}

fn keyCodeFromCodepoint(value: u32) ?T.key_code {
    const cp: u21 = std.math.cast(u21, value) orelse return null;
    var buf: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(cp, &buf) catch return null;

    var ud = std.mem.zeroes(T.Utf8Data);
    @memcpy(ud.data[0..len], buf[0..len]);
    ud.size = @intCast(len);
    ud.have = @intCast(len);
    ud.width = if (utf8.displayWidth(buf[0..len]) == 2) 2 else 1;

    var uc: T.utf8_char = 0;
    if (utf8.utf8_from_data(&ud, &uc) != .done) return null;
    return uc;
}

test "key_string_lookup_string parses fixed and modified keys" {
    try std.testing.expectEqual(T.KEYC_F1, key_string_lookup_string("F1"));
    try std.testing.expectEqual(T.KEYC_LEFT | T.KEYC_META | T.KEYC_CURSOR | T.KEYC_IMPLIED_META, key_string_lookup_string("M-Left"));
    try std.testing.expectEqual(@as(T.key_code, 'b') | T.KEYC_CTRL, key_string_lookup_string("^B"));
    try std.testing.expectEqual(T.KEYC_NONE, key_string_lookup_string("None"));
}

test "key_string lookup roundtrips unicode and mouse names" {
    const emoji = key_string_lookup_string("🙂");
    try std.testing.expect(T.keycIsUnicode(emoji));
    try std.testing.expectEqualStrings("🙂", key_string_lookup_key(emoji, 0));

    const mouse = key_string_lookup_string("MouseDown1Pane");
    try std.testing.expectEqual(T.keycMouse(T.KEYC_MOUSEDOWN1, .pane), mouse);
    try std.testing.expectEqualStrings("MouseDown1Pane", key_string_lookup_key(mouse, 0));
}

test "key_string_lookup_key renders flags and user keys" {
    try std.testing.expectEqualStrings("KP1[K]", key_string_lookup_key(T.KEYC_KP_ONE | T.KEYC_KEYPAD, 1));
    try std.testing.expectEqualStrings("User7", key_string_lookup_key(T.KEYC_USER + 7, 0));
    try std.testing.expectEqualStrings("ReportDarkTheme", key_string_lookup_key(T.KEYC_REPORT_DARK_THEME, 0));
}

test "key_string_lookup_string rejects unknown keys" {
    try std.testing.expectEqual(T.KEYC_UNKNOWN, key_string_lookup_string("mystery-key"));
}
