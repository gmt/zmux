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
// Ported from tmux/tmux.h (type definitions only)
// Original copyright:
//   Copyright (c) 2007 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

//! types.zig – central type definitions for zmux, mirroring tmux.h.
//!
//! All core struct and enum types live here to avoid circular module imports.
//! Implementation files (session.zig, window.zig, etc.) @import("types.zig")
//! and provide the functions that operate on these types.

const std = @import("std");
const c = @import("c.zig");
const hyperlinks_mod = @import("hyperlinks.zig");
pub const protocol = @import("zmux-protocol.zig");

// ── Build constants ────────────────────────────────────────────────────────
const build_options = @import("build_options");

pub const ZMUX_VERSION: []const u8 = build_options.version;
pub const ZMUX_CONF: []const u8 = build_options.zmux_conf;
pub const ZMUX_SOCK: []const u8 = build_options.zmux_sock;
pub const ZMUX_TERM: []const u8 = build_options.zmux_term;
pub const ZMUX_LOCK_CMD: []const u8 = build_options.zmux_lock_cmd;

pub const PANE_MINIMUM: u32 = 1;
pub const WINDOW_MINIMUM: u32 = PANE_MINIMUM;
pub const WINDOW_MAXIMUM: u32 = 10000;
pub const NAME_INTERVAL: u64 = 500_000; // microseconds
pub const DEFAULT_XPIXEL: u32 = 16;
pub const DEFAULT_YPIXEL: u32 = 32;
pub const UTF8_SIZE: usize = 32;
pub const TTY_NAME_MAX: usize = 64;
pub const STATUS_LINES_LIMIT: u32 = 5;
pub const PANE_SCROLLBARS_DEFAULT_PADDING: i32 = 0;
pub const PANE_SCROLLBARS_DEFAULT_WIDTH: i32 = 1;
pub const PANE_SCROLLBARS_CHARACTER: u8 = ' ';
pub const PANE_SCROLLBARS_OFF: u32 = 0;
pub const PANE_SCROLLBARS_MODAL: u32 = 1;
pub const PANE_SCROLLBARS_ALWAYS: u32 = 2;
pub const PANE_SCROLLBARS_RIGHT: u32 = 0;
pub const PANE_SCROLLBARS_LEFT: u32 = 1;

// ── Key codes ─────────────────────────────────────────────────────────────

pub const key_code = u64;

pub const KEYC_NONE: key_code = 0x000ff000000000;
pub const KEYC_UNKNOWN: key_code = 0x000fe000000000;
pub const KEYC_BASE: key_code = 0x0000000010e000;
pub const KEYC_USER: key_code = 0x0000000010f000;
pub const KEYC_USER_END: key_code = KEYC_USER + KEYC_NUSER;
pub const KEYC_NUSER: u32 = 1000;

pub const KEYC_META: key_code = 0x00100000000000;
pub const KEYC_CTRL: key_code = 0x00200000000000;
pub const KEYC_SHIFT: key_code = 0x00400000000000;

pub const KEYC_LITERAL: key_code = 0x01000000000000;
pub const KEYC_KEYPAD: key_code = 0x02000000000000;
pub const KEYC_CURSOR: key_code = 0x04000000000000;
pub const KEYC_IMPLIED_META: key_code = 0x08000000000000;
pub const KEYC_BUILD_MODIFIERS: key_code = 0x10000000000000;
pub const KEYC_VI: key_code = 0x20000000000000;
pub const KEYC_SENT: key_code = 0x40000000000000;

pub const KEYC_MASK_MODIFIERS: key_code = 0x00f00000000000;
pub const KEYC_MASK_FLAGS: key_code = 0xff000000000000;
pub const KEYC_MASK_KEY: key_code = 0x000fffffffffff;

pub const KEYC_CLICK_TIMEOUT: u32 = 300;

pub const MOUSE_MASK_BUTTONS: u32 = 195;
pub const MOUSE_MASK_SHIFT: u32 = 4;
pub const MOUSE_MASK_META: u32 = 8;
pub const MOUSE_MASK_CTRL: u32 = 16;
pub const MOUSE_MASK_DRAG: u32 = 32;

pub const MOUSE_WHEEL_UP: u32 = 64;
pub const MOUSE_WHEEL_DOWN: u32 = 65;

pub const MOUSE_BUTTON_1: u32 = 0;
pub const MOUSE_BUTTON_2: u32 = 1;
pub const MOUSE_BUTTON_3: u32 = 2;
pub const MOUSE_BUTTON_6: u32 = 66;
pub const MOUSE_BUTTON_7: u32 = 67;
pub const MOUSE_BUTTON_8: u32 = 128;
pub const MOUSE_BUTTON_9: u32 = 129;
pub const MOUSE_BUTTON_10: u32 = 130;
pub const MOUSE_BUTTON_11: u32 = 131;

pub fn mouseButtons(b: u32) u32 {
    return b & MOUSE_MASK_BUTTONS;
}

pub fn mouseWheel(b: u32) bool {
    const buttons = mouseButtons(b);
    return buttons == MOUSE_WHEEL_UP or buttons == MOUSE_WHEEL_DOWN;
}

pub fn mouseDrag(b: u32) bool {
    return b & MOUSE_MASK_DRAG != 0;
}

pub fn mouseRelease(b: u32) bool {
    return mouseButtons(b) == 3;
}

pub const KeyMouseTarget = enum(key_code) {
    pane = 0,
    status = 1,
    status_left = 2,
    status_right = 3,
    status_default = 4,
    scrollbar_up = 5,
    scrollbar_slider = 6,
    scrollbar_down = 7,
    border = 8,
};

pub const KEYC_MOUSE_TARGET_COUNT: key_code = 9;

pub fn keycMouse(base: key_code, target: KeyMouseTarget) key_code {
    return base + @intFromEnum(target);
}

pub const C0_NUL: key_code = 0;
pub const C0_SOH: key_code = 1;
pub const C0_STX: key_code = 2;
pub const C0_ETX: key_code = 3;
pub const C0_EOT: key_code = 4;
pub const C0_ENQ: key_code = 5;
pub const C0_ASC: key_code = 6;
pub const C0_BEL: key_code = 7;
pub const C0_BS: key_code = 8;
pub const C0_HT: key_code = 9;
pub const C0_LF: key_code = 10;
pub const C0_VT: key_code = 11;
pub const C0_FF: key_code = 12;
pub const C0_CR: key_code = 13;
pub const C0_SO: key_code = 14;
pub const C0_SI: key_code = 15;
pub const C0_DLE: key_code = 16;
pub const C0_DC1: key_code = 17;
pub const C0_DC2: key_code = 18;
pub const C0_DC3: key_code = 19;
pub const C0_DC4: key_code = 20;
pub const C0_NAK: key_code = 21;
pub const C0_SYN: key_code = 22;
pub const C0_ETB: key_code = 23;
pub const C0_CAN: key_code = 24;
pub const C0_EM: key_code = 25;
pub const C0_SUB: key_code = 26;
pub const C0_ESC: key_code = 27;
pub const C0_FS: key_code = 28;
pub const C0_GS: key_code = 29;
pub const C0_RS: key_code = 30;
pub const C0_US: key_code = 31;

pub const KEYC_FOCUS_IN: key_code = KEYC_BASE;
pub const KEYC_FOCUS_OUT: key_code = KEYC_FOCUS_IN + 1;
pub const KEYC_ANY: key_code = KEYC_FOCUS_OUT + 1;
pub const KEYC_PASTE_START: key_code = KEYC_ANY + 1;
pub const KEYC_PASTE_END: key_code = KEYC_PASTE_START + 1;
pub const KEYC_MOUSE: key_code = KEYC_PASTE_END + 1;
pub const KEYC_DRAGGING: key_code = KEYC_MOUSE + 1;
pub const KEYC_DOUBLECLICK: key_code = KEYC_DRAGGING + 1;

pub const KEYC_MOUSEMOVE: key_code = KEYC_DOUBLECLICK + 1;
pub const KEYC_MOUSEDOWN1: key_code = KEYC_MOUSEMOVE + KEYC_MOUSE_TARGET_COUNT;
pub const KEYC_MOUSEDOWN2: key_code = KEYC_MOUSEDOWN1 + KEYC_MOUSE_TARGET_COUNT;
pub const KEYC_MOUSEDOWN3: key_code = KEYC_MOUSEDOWN2 + KEYC_MOUSE_TARGET_COUNT;
pub const KEYC_MOUSEDOWN6: key_code = KEYC_MOUSEDOWN3 + KEYC_MOUSE_TARGET_COUNT;
pub const KEYC_MOUSEDOWN7: key_code = KEYC_MOUSEDOWN6 + KEYC_MOUSE_TARGET_COUNT;
pub const KEYC_MOUSEDOWN8: key_code = KEYC_MOUSEDOWN7 + KEYC_MOUSE_TARGET_COUNT;
pub const KEYC_MOUSEDOWN9: key_code = KEYC_MOUSEDOWN8 + KEYC_MOUSE_TARGET_COUNT;
pub const KEYC_MOUSEDOWN10: key_code = KEYC_MOUSEDOWN9 + KEYC_MOUSE_TARGET_COUNT;
pub const KEYC_MOUSEDOWN11: key_code = KEYC_MOUSEDOWN10 + KEYC_MOUSE_TARGET_COUNT;
pub const KEYC_MOUSEUP1: key_code = KEYC_MOUSEDOWN11 + KEYC_MOUSE_TARGET_COUNT;
pub const KEYC_MOUSEUP2: key_code = KEYC_MOUSEUP1 + KEYC_MOUSE_TARGET_COUNT;
pub const KEYC_MOUSEUP3: key_code = KEYC_MOUSEUP2 + KEYC_MOUSE_TARGET_COUNT;
pub const KEYC_MOUSEUP6: key_code = KEYC_MOUSEUP3 + KEYC_MOUSE_TARGET_COUNT;
pub const KEYC_MOUSEUP7: key_code = KEYC_MOUSEUP6 + KEYC_MOUSE_TARGET_COUNT;
pub const KEYC_MOUSEUP8: key_code = KEYC_MOUSEUP7 + KEYC_MOUSE_TARGET_COUNT;
pub const KEYC_MOUSEUP9: key_code = KEYC_MOUSEUP8 + KEYC_MOUSE_TARGET_COUNT;
pub const KEYC_MOUSEUP10: key_code = KEYC_MOUSEUP9 + KEYC_MOUSE_TARGET_COUNT;
pub const KEYC_MOUSEUP11: key_code = KEYC_MOUSEUP10 + KEYC_MOUSE_TARGET_COUNT;
pub const KEYC_MOUSEDRAG1: key_code = KEYC_MOUSEUP11 + KEYC_MOUSE_TARGET_COUNT;
pub const KEYC_MOUSEDRAG2: key_code = KEYC_MOUSEDRAG1 + KEYC_MOUSE_TARGET_COUNT;
pub const KEYC_MOUSEDRAG3: key_code = KEYC_MOUSEDRAG2 + KEYC_MOUSE_TARGET_COUNT;
pub const KEYC_MOUSEDRAG6: key_code = KEYC_MOUSEDRAG3 + KEYC_MOUSE_TARGET_COUNT;
pub const KEYC_MOUSEDRAG7: key_code = KEYC_MOUSEDRAG6 + KEYC_MOUSE_TARGET_COUNT;
pub const KEYC_MOUSEDRAG8: key_code = KEYC_MOUSEDRAG7 + KEYC_MOUSE_TARGET_COUNT;
pub const KEYC_MOUSEDRAG9: key_code = KEYC_MOUSEDRAG8 + KEYC_MOUSE_TARGET_COUNT;
pub const KEYC_MOUSEDRAG10: key_code = KEYC_MOUSEDRAG9 + KEYC_MOUSE_TARGET_COUNT;
pub const KEYC_MOUSEDRAG11: key_code = KEYC_MOUSEDRAG10 + KEYC_MOUSE_TARGET_COUNT;
pub const KEYC_MOUSEDRAGEND1: key_code = KEYC_MOUSEDRAG11 + KEYC_MOUSE_TARGET_COUNT;
pub const KEYC_MOUSEDRAGEND2: key_code = KEYC_MOUSEDRAGEND1 + KEYC_MOUSE_TARGET_COUNT;
pub const KEYC_MOUSEDRAGEND3: key_code = KEYC_MOUSEDRAGEND2 + KEYC_MOUSE_TARGET_COUNT;
pub const KEYC_MOUSEDRAGEND6: key_code = KEYC_MOUSEDRAGEND3 + KEYC_MOUSE_TARGET_COUNT;
pub const KEYC_MOUSEDRAGEND7: key_code = KEYC_MOUSEDRAGEND6 + KEYC_MOUSE_TARGET_COUNT;
pub const KEYC_MOUSEDRAGEND8: key_code = KEYC_MOUSEDRAGEND7 + KEYC_MOUSE_TARGET_COUNT;
pub const KEYC_MOUSEDRAGEND9: key_code = KEYC_MOUSEDRAGEND8 + KEYC_MOUSE_TARGET_COUNT;
pub const KEYC_MOUSEDRAGEND10: key_code = KEYC_MOUSEDRAGEND9 + KEYC_MOUSE_TARGET_COUNT;
pub const KEYC_MOUSEDRAGEND11: key_code = KEYC_MOUSEDRAGEND10 + KEYC_MOUSE_TARGET_COUNT;
pub const KEYC_WHEELUP: key_code = KEYC_MOUSEDRAGEND11 + KEYC_MOUSE_TARGET_COUNT;
pub const KEYC_WHEELDOWN: key_code = KEYC_WHEELUP + KEYC_MOUSE_TARGET_COUNT;
pub const KEYC_SECONDCLICK1: key_code = KEYC_WHEELDOWN + KEYC_MOUSE_TARGET_COUNT;
pub const KEYC_SECONDCLICK2: key_code = KEYC_SECONDCLICK1 + KEYC_MOUSE_TARGET_COUNT;
pub const KEYC_SECONDCLICK3: key_code = KEYC_SECONDCLICK2 + KEYC_MOUSE_TARGET_COUNT;
pub const KEYC_SECONDCLICK6: key_code = KEYC_SECONDCLICK3 + KEYC_MOUSE_TARGET_COUNT;
pub const KEYC_SECONDCLICK7: key_code = KEYC_SECONDCLICK6 + KEYC_MOUSE_TARGET_COUNT;
pub const KEYC_SECONDCLICK8: key_code = KEYC_SECONDCLICK7 + KEYC_MOUSE_TARGET_COUNT;
pub const KEYC_SECONDCLICK9: key_code = KEYC_SECONDCLICK8 + KEYC_MOUSE_TARGET_COUNT;
pub const KEYC_SECONDCLICK10: key_code = KEYC_SECONDCLICK9 + KEYC_MOUSE_TARGET_COUNT;
pub const KEYC_SECONDCLICK11: key_code = KEYC_SECONDCLICK10 + KEYC_MOUSE_TARGET_COUNT;
pub const KEYC_DOUBLECLICK1: key_code = KEYC_SECONDCLICK11 + KEYC_MOUSE_TARGET_COUNT;
pub const KEYC_DOUBLECLICK2: key_code = KEYC_DOUBLECLICK1 + KEYC_MOUSE_TARGET_COUNT;
pub const KEYC_DOUBLECLICK3: key_code = KEYC_DOUBLECLICK2 + KEYC_MOUSE_TARGET_COUNT;
pub const KEYC_DOUBLECLICK6: key_code = KEYC_DOUBLECLICK3 + KEYC_MOUSE_TARGET_COUNT;
pub const KEYC_DOUBLECLICK7: key_code = KEYC_DOUBLECLICK6 + KEYC_MOUSE_TARGET_COUNT;
pub const KEYC_DOUBLECLICK8: key_code = KEYC_DOUBLECLICK7 + KEYC_MOUSE_TARGET_COUNT;
pub const KEYC_DOUBLECLICK9: key_code = KEYC_DOUBLECLICK8 + KEYC_MOUSE_TARGET_COUNT;
pub const KEYC_DOUBLECLICK10: key_code = KEYC_DOUBLECLICK9 + KEYC_MOUSE_TARGET_COUNT;
pub const KEYC_DOUBLECLICK11: key_code = KEYC_DOUBLECLICK10 + KEYC_MOUSE_TARGET_COUNT;
pub const KEYC_TRIPLECLICK1: key_code = KEYC_DOUBLECLICK11 + KEYC_MOUSE_TARGET_COUNT;
pub const KEYC_TRIPLECLICK2: key_code = KEYC_TRIPLECLICK1 + KEYC_MOUSE_TARGET_COUNT;
pub const KEYC_TRIPLECLICK3: key_code = KEYC_TRIPLECLICK2 + KEYC_MOUSE_TARGET_COUNT;
pub const KEYC_TRIPLECLICK6: key_code = KEYC_TRIPLECLICK3 + KEYC_MOUSE_TARGET_COUNT;
pub const KEYC_TRIPLECLICK7: key_code = KEYC_TRIPLECLICK6 + KEYC_MOUSE_TARGET_COUNT;
pub const KEYC_TRIPLECLICK8: key_code = KEYC_TRIPLECLICK7 + KEYC_MOUSE_TARGET_COUNT;
pub const KEYC_TRIPLECLICK9: key_code = KEYC_TRIPLECLICK8 + KEYC_MOUSE_TARGET_COUNT;
pub const KEYC_TRIPLECLICK10: key_code = KEYC_TRIPLECLICK9 + KEYC_MOUSE_TARGET_COUNT;
pub const KEYC_TRIPLECLICK11: key_code = KEYC_TRIPLECLICK10 + KEYC_MOUSE_TARGET_COUNT;

pub const KEYC_BSPACE: key_code = KEYC_TRIPLECLICK11 + KEYC_MOUSE_TARGET_COUNT;
pub const KEYC_F1: key_code = KEYC_BSPACE + 1;
pub const KEYC_F2: key_code = KEYC_F1 + 1;
pub const KEYC_F3: key_code = KEYC_F2 + 1;
pub const KEYC_F4: key_code = KEYC_F3 + 1;
pub const KEYC_F5: key_code = KEYC_F4 + 1;
pub const KEYC_F6: key_code = KEYC_F5 + 1;
pub const KEYC_F7: key_code = KEYC_F6 + 1;
pub const KEYC_F8: key_code = KEYC_F7 + 1;
pub const KEYC_F9: key_code = KEYC_F8 + 1;
pub const KEYC_F10: key_code = KEYC_F9 + 1;
pub const KEYC_F11: key_code = KEYC_F10 + 1;
pub const KEYC_F12: key_code = KEYC_F11 + 1;
pub const KEYC_IC: key_code = KEYC_F12 + 1;
pub const KEYC_DC: key_code = KEYC_IC + 1;
pub const KEYC_HOME: key_code = KEYC_DC + 1;
pub const KEYC_END: key_code = KEYC_HOME + 1;
pub const KEYC_NPAGE: key_code = KEYC_END + 1;
pub const KEYC_PPAGE: key_code = KEYC_NPAGE + 1;
pub const KEYC_BTAB: key_code = KEYC_PPAGE + 1;
pub const KEYC_UP: key_code = KEYC_BTAB + 1;
pub const KEYC_DOWN: key_code = KEYC_UP + 1;
pub const KEYC_LEFT: key_code = KEYC_DOWN + 1;
pub const KEYC_RIGHT: key_code = KEYC_LEFT + 1;
pub const KEYC_KP_SLASH: key_code = KEYC_RIGHT + 1;
pub const KEYC_KP_STAR: key_code = KEYC_KP_SLASH + 1;
pub const KEYC_KP_MINUS: key_code = KEYC_KP_STAR + 1;
pub const KEYC_KP_SEVEN: key_code = KEYC_KP_MINUS + 1;
pub const KEYC_KP_EIGHT: key_code = KEYC_KP_SEVEN + 1;
pub const KEYC_KP_NINE: key_code = KEYC_KP_EIGHT + 1;
pub const KEYC_KP_PLUS: key_code = KEYC_KP_NINE + 1;
pub const KEYC_KP_FOUR: key_code = KEYC_KP_PLUS + 1;
pub const KEYC_KP_FIVE: key_code = KEYC_KP_FOUR + 1;
pub const KEYC_KP_SIX: key_code = KEYC_KP_FIVE + 1;
pub const KEYC_KP_ONE: key_code = KEYC_KP_SIX + 1;
pub const KEYC_KP_TWO: key_code = KEYC_KP_ONE + 1;
pub const KEYC_KP_THREE: key_code = KEYC_KP_TWO + 1;
pub const KEYC_KP_ENTER: key_code = KEYC_KP_THREE + 1;
pub const KEYC_KP_ZERO: key_code = KEYC_KP_ENTER + 1;
pub const KEYC_KP_PERIOD: key_code = KEYC_KP_ZERO + 1;
pub const KEYC_REPORT_DARK_THEME: key_code = KEYC_KP_PERIOD + 1;
pub const KEYC_REPORT_LIGHT_THEME: key_code = KEYC_REPORT_DARK_THEME + 1;
pub const KEYC_BASE_END: key_code = KEYC_REPORT_LIGHT_THEME + 1;

pub fn keycIsMouse(key: key_code) bool {
    const masked = key & KEYC_MASK_KEY;
    return masked >= KEYC_MOUSE and masked < KEYC_BSPACE;
}

pub fn keycIsUnicode(key: key_code) bool {
    const masked = key & KEYC_MASK_KEY;
    return masked > 0x7f and
        (masked < KEYC_BASE or masked >= KEYC_BASE_END) and
        (masked < KEYC_USER or masked >= KEYC_USER_END);
}

pub fn keycIsPaste(key: key_code) bool {
    const masked = key & KEYC_MASK_KEY;
    return masked == KEYC_PASTE_START or masked == KEYC_PASTE_END;
}

pub const MODEKEY_EMACS: u32 = 0;
pub const MODEKEY_VI: u32 = 1;

pub const MODE_CURSOR: i32 = 0x1;
pub const MODE_INSERT: i32 = 0x2;
pub const MODE_KCURSOR: i32 = 0x4;
pub const MODE_KKEYPAD: i32 = 0x8;
pub const MODE_WRAP: i32 = 0x10;
pub const MODE_MOUSE_STANDARD: i32 = 0x20;
pub const MODE_MOUSE_BUTTON: i32 = 0x40;
pub const MODE_CURSOR_BLINKING: i32 = 0x80;
pub const MODE_MOUSE_UTF8: i32 = 0x100;
pub const MODE_MOUSE_SGR: i32 = 0x200;
pub const MODE_BRACKETPASTE: i32 = 0x400;
pub const MODE_FOCUSON: i32 = 0x800;
pub const MODE_MOUSE_ALL: i32 = 0x1000;
pub const MODE_ORIGIN: i32 = 0x2000;
pub const MODE_CRLF: i32 = 0x4000;
pub const MODE_KEYS_EXTENDED: i32 = 0x8000;
pub const MODE_CURSOR_VERY_VISIBLE: i32 = 0x10000;
pub const MODE_CURSOR_BLINKING_SET: i32 = 0x20000;
pub const MODE_KEYS_EXTENDED_2: i32 = 0x40000;
pub const MODE_THEME_UPDATES: i32 = 0x80000;
pub const MODE_SYNC: i32 = 0x100000;

pub const ALL_MOUSE_MODES: i32 = MODE_MOUSE_STANDARD | MODE_MOUSE_BUTTON | MODE_MOUSE_ALL;
pub const MOTION_MOUSE_MODES: i32 = MODE_MOUSE_BUTTON | MODE_MOUSE_ALL;
pub const EXTENDED_KEY_MODES: i32 = MODE_KEYS_EXTENDED | MODE_KEYS_EXTENDED_2;

pub const SortOrder = enum {
    activity,
    creation,
    index,
    modifier,
    name,
    order,
    size,
    end,
};

pub const SortCriteria = struct {
    order: SortOrder = .end,
    reversed: bool = false,
    /// When non-null, `sort_next_order` cycles through this sequence (tmux `order_seq`).
    order_seq: ?[]const SortOrder = null,
};

// ── UTF-8 ─────────────────────────────────────────────────────────────────

pub const utf8_char = u32;

pub const Utf8Data = extern struct {
    data: [UTF8_SIZE]u8,
    have: u8,
    size: u8,
    width: u8, // 0xff if invalid

    pub fn bytes(self: *const Utf8Data) []const u8 {
        return self.data[0..self.size];
    }

    pub fn isEmpty(self: *const Utf8Data) bool {
        return self.size == 0;
    }
};

pub const Utf8State = enum(u32) {
    more,
    done,
    @"error",
};

pub const HangulJamoState = enum(u8) {
    not_hanguljamo,
    choseong,
    composable,
    not_composable,
};

// ── Colour / attributes ───────────────────────────────────────────────────

pub const COLOUR_FLAG_256: u32 = 0x01000000;
pub const COLOUR_FLAG_RGB: u32 = 0x02000000;

pub const ColourPalette = struct {
    fg: i32 = 8,
    bg: i32 = 8,
    palette: ?[]i32 = null,
    default_palette: ?[]i32 = null,
};

pub const ClientTheme = enum {
    unknown,
    light,
    dark,
};

pub const GRID_ATTR_BRIGHT: u16 = 0x0001;
pub const GRID_ATTR_DIM: u16 = 0x0002;
pub const GRID_ATTR_UNDERSCORE: u16 = 0x0004;
pub const GRID_ATTR_BLINK: u16 = 0x0008;
pub const GRID_ATTR_REVERSE: u16 = 0x0010;
pub const GRID_ATTR_HIDDEN: u16 = 0x0020;
pub const GRID_ATTR_ITALICS: u16 = 0x0040;
pub const GRID_ATTR_CHARSET: u16 = 0x0080;
pub const GRID_ATTR_STRIKETHROUGH: u16 = 0x0100;
pub const GRID_ATTR_UNDERSCORE_2: u16 = 0x0200;
pub const GRID_ATTR_UNDERSCORE_3: u16 = 0x0400;
pub const GRID_ATTR_UNDERSCORE_4: u16 = 0x0800;
pub const GRID_ATTR_UNDERSCORE_5: u16 = 0x1000;
pub const GRID_ATTR_OVERLINE: u16 = 0x2000;
pub const GRID_ATTR_NOATTR: u16 = 0x4000;
pub const GRID_ATTR_ALL_UNDERSCORE: u16 =
    GRID_ATTR_UNDERSCORE |
    GRID_ATTR_UNDERSCORE_2 |
    GRID_ATTR_UNDERSCORE_3 |
    GRID_ATTR_UNDERSCORE_4 |
    GRID_ATTR_UNDERSCORE_5;

pub const GRID_FLAG_FG256: u8 = 0x01;
pub const GRID_FLAG_BG256: u8 = 0x02;
pub const GRID_FLAG_PADDING: u8 = 0x04;
pub const GRID_FLAG_EXTENDED: u8 = 0x08;
pub const GRID_FLAG_SELECTED: u8 = 0x10;
pub const GRID_FLAG_NOPALETTE: u8 = 0x20;
pub const GRID_FLAG_CLEARED: u8 = 0x40;
pub const GRID_FLAG_TAB: u8 = 0x80;
pub const GRID_HISTORY: i32 = 0x01;

pub const GRID_LINE_WRAPPED: i32 = 0x01;
pub const GRID_LINE_EXTENDED: i32 = 0x02;
pub const GRID_LINE_DEAD: i32 = 0x04;
pub const GRID_LINE_START_PROMPT: i32 = 0x08;
pub const GRID_LINE_START_OUTPUT: i32 = 0x10;

// ── Grid cell ─────────────────────────────────────────────────────────────

pub const GridCell = extern struct {
    data: Utf8Data,
    attr: u16,
    flags: u8,
    fg: i32,
    bg: i32,
    us: i32, // underline colour
    link: u32,

    pub fn payload(self: *const GridCell) *const Utf8Data {
        return &self.data;
    }

    pub fn fromPayload(ud: *const Utf8Data) GridCell {
        var cell = grid_default_cell;
        cell.data = ud.*;
        return cell;
    }

    pub fn isPadding(self: *const GridCell) bool {
        return (self.flags & GRID_FLAG_PADDING) != 0;
    }

    pub fn isCleared(self: *const GridCell) bool {
        return (self.flags & GRID_FLAG_CLEARED) != 0;
    }
};

pub const grid_default_cell = GridCell{
    .data = .{
        .data = [_]u8{' '} ++ [_]u8{0} ** (UTF8_SIZE - 1),
        .have = 0,
        .size = 1,
        .width = 1,
    },
    .attr = 0,
    .flags = 0,
    .fg = 8,
    .bg = 8,
    .us = 8,
    .link = 0,
};

pub const grid_padding_cell = GridCell{
    .data = .{
        .data = [_]u8{'!'} ++ [_]u8{0} ** (UTF8_SIZE - 1),
        .have = 0,
        .size = 0,
        .width = 0,
    },
    .attr = 0,
    .flags = GRID_FLAG_PADDING,
    .fg = 8,
    .bg = 8,
    .us = 8,
    .link = 0,
};

pub const grid_cleared_cell = GridCell{
    .data = .{
        .data = [_]u8{' '} ++ [_]u8{0} ** (UTF8_SIZE - 1),
        .have = 0,
        .size = 1,
        .width = 1,
    },
    .attr = 0,
    .flags = GRID_FLAG_CLEARED,
    .fg = 8,
    .bg = 8,
    .us = 8,
    .link = 0,
};

pub const GridExtdEntry = extern struct {
    data: utf8_char,
    attr: u16,
    flags: u8,
    fg: i32,
    bg: i32,
    us: i32,
    link: u32,
};

/// Compact inline cell entry – fits common ASCII case in 5 bytes.
pub const GridCellEntryData = packed struct {
    attr: u8,
    fg: u8,
    bg: u8,
    data: u8,
};
pub const GridCellEntry = extern struct {
    offset_or_data: extern union {
        offset: u32,
        data: GridCellEntryData,
    },
    flags: u8,
};

pub const GridLine = struct {
    celldata: []GridCellEntry = &.{},
    cellused: u32 = 0,
    extddata: []GridExtdEntry = &.{},
    flags: i32 = 0,
    time: i64 = 0,
};

pub const Grid = struct {
    flags: i32 = 0,
    sx: u32,
    sy: u32,
    hscrolled: u32 = 0,
    hsize: u32 = 0,
    hlimit: u32 = 2000,
    linedata: []GridLine,
};

pub const GridReader = struct {
    gd: *Grid,
    cx: u32 = 0,
    cy: u32 = 0,
};

// ── Style ─────────────────────────────────────────────────────────────────

pub const StyleAlign = enum {
    default,
    left,
    centre,
    right,
    absolute_centre,
};

pub const StyleList = enum {
    off,
    on,
    focus,
    left_marker,
    right_marker,
};

pub const StyleRangeType = enum {
    none,
    left,
    right,
    pane,
    window,
    session,
    user,
};

pub const StyleDefaultType = enum {
    base,
    push,
    pop,
    set,
};

pub const Style = struct {
    gc: GridCell = grid_default_cell,
    ignore: bool = false,
    fill: i32 = 8,
    @"align": StyleAlign = .default,
    list: StyleList = .off,
    range_type: StyleRangeType = .none,
    range_argument: u32 = 0,
    range_string: [16]u8 = std.mem.zeroes([16]u8),
    width: i32 = -1,
    width_percentage: i32 = 0,
    pad: i32 = -1,
    default_type: StyleDefaultType = .base,
};

pub const StyleRange = struct {
    type: StyleRangeType = .none,
    argument: u32 = 0,
    string: [16]u8 = std.mem.zeroes([16]u8),
    start: u32 = 0,
    end: u32 = 0,
};

pub const StyleRanges = std.ArrayList(StyleRange);

// ── Sixel image types ─────────────────────────────────────────────────────

/// One horizontal band of sixel pixel data.
/// Mirrors `struct sixel_line` in image-sixel.c.
pub const SixelLine = struct {
    x: u32 = 0,
    data: []u16 = &.{},
};

/// A decoded sixel image: pixel grid + colour table.
/// Mirrors `struct sixel_image` in image-sixel.c.
pub const SixelImage = struct {
    x: u32 = 0,
    y: u32 = 0,
    xpixel: u32 = 0,
    ypixel: u32 = 0,

    set_ra: u32 = 0,
    ra_x: u32 = 0,
    ra_y: u32 = 0,

    colours: []u32 = &.{},
    ncolours: u32 = 0,
    used_colours: u32 = 0,
    p2: u32 = 0,

    /// Current draw cursor (pixels).
    dx: u32 = 0,
    dy: u32 = 0,
    /// Current colour index + 1 (0 means unset).
    dc: u32 = 0,

    lines: []SixelLine = &.{},
};

/// A placed image on a screen.
/// Mirrors `struct image` in image.c.
pub const Image = struct {
    s: *Screen,
    data: *SixelImage,
    fallback: ?[]u8 = null,

    /// Cell position of top-left corner.
    px: u32 = 0,
    py: u32 = 0,
    /// Size in cells.
    sx: u32 = 0,
    sy: u32 = 0,
};

// ── Screen ────────────────────────────────────────────────────────────────

pub const ScreenCursorStyle = enum {
    default,
    block,
    underline,
    bar,
};

/// Selection state for a screen (mirrors tmux's struct screen_sel).
pub const ScreenSel = struct {
    hidden: bool = false,
    rectangle: bool = false,
    modekeys: u32 = MODEKEY_EMACS,
    sx: u32 = 0,
    sy: u32 = 0,
    ex: u32 = 0,
    ey: u32 = 0,
    cell: GridCell = std.mem.zeroes(GridCell),
};

/// Title stack entry (mirrors tmux's struct screen_title_entry).
pub const ScreenTitleEntry = struct {
    text: []u8,
};

pub fn colour_is_default(colour: i32) bool {
    return colour == 8 or colour == 9;
}

pub const Screen = struct {
    title: ?[]u8 = null,
    path: ?[]u8 = null,
    grid: *Grid,
    hyperlinks: ?*hyperlinks_mod.Hyperlinks = null,
    cx: u32 = 0,
    cy: u32 = 0,
    cstyle: ScreenCursorStyle = .default,
    default_cstyle: ScreenCursorStyle = .default,
    ccolour: i32 = -1,
    default_ccolour: i32 = -1,
    rupper: u32 = 0,
    rlower: u32 = 0,
    mode: i32 = 0,
    default_mode: i32 = 0,
    cursor_visible: bool = true,
    bracketed_paste: bool = false,
    saved_cx: u32 = 0,
    saved_cy: u32 = 0,
    saved_grid: ?*Grid = null,
    saved_cell: GridCell = std.mem.zeroes(GridCell),
    saved_flags: i32 = 0,
    tabs: ?[]u8 = null,
    sel: ?*ScreenSel = null,
    titles: std.ArrayList(ScreenTitleEntry) = .{},
    cell_fg: u32 = 8,
    cell_bg: u32 = 8,
    cell_us: u32 = 8,
    cell_attr: u16 = 0,
    g0set: u8 = 0,
    g1set: u8 = 0,
    saved_cell_fg: u32 = 8,
    saved_cell_bg: u32 = 8,
    saved_cell_us: u32 = 8,
    saved_cell_attr: u16 = 0,
    saved_g0set: u8 = 0,
    saved_g1set: u8 = 0,
    saved_mode: i32 = 0,
    input_last_valid: bool = false,
    last_glyph: Utf8Data = std.mem.zeroes(Utf8Data),
    write_list: ?[]ScreenWriteCline = null,

    /// Images placed on this screen (mirrors tmux `struct images`).
    images: std.ArrayListUnmanaged(*Image) = .{},
    /// Saved images (for alternate-screen switch).
    saved_images: std.ArrayListUnmanaged(*Image) = .{},
};

// ── Terminal ──────────────────────────────────────────────────────────────

pub const TTY_NOCURSOR: u32 = 0x0001;
pub const TTY_FREEZE: u32 = 0x0002;
pub const TTY_TIMER: u32 = 0x0004;
pub const TTY_NOBLOCK: u32 = 0x0008;
pub const TTY_STARTED: u32 = 0x0010;
pub const TTY_OPENED: u32 = 0x0020;
pub const TTY_OSC52QUERY: u32 = 0x0040;
pub const TTY_BLOCK: u32 = 0x0080;
pub const TTY_HAVEDA: u32 = 0x0100;
pub const TTY_HAVEXDA: u32 = 0x0200;
pub const TTY_SYNCING: u32 = 0x0400;
pub const TTY_HAVEDA2: u32 = 0x0800;
pub const TTY_WAITFG: u32 = 0x2000;
pub const TTY_WAITBG: u32 = 0x4000;
/// Combination of all DA/XDA/XTVERSION request-complete flags.
pub const TTY_ALL_REQUEST_FLAGS: u32 = TTY_HAVEDA | TTY_HAVEDA2 | TTY_HAVEXDA;
/// Minimum seconds between repeated tty_repeat_requests calls.
pub const TTY_REQUEST_LIMIT: u32 = 30;
/// Seconds to wait for a query response before giving up.
pub const TTY_QUERY_TIMEOUT: u32 = 5;

pub const Tty = struct {
    client: *Client,
    sx: u32 = 80,
    sy: u32 = 24,
    xpixel: u32 = DEFAULT_XPIXEL,
    ypixel: u32 = DEFAULT_YPIXEL,
    cx: u32 = 0,
    cy: u32 = 0,
    cstyle: ScreenCursorStyle = .default,
    ccolour: i32 = -1,
    mode: i32 = 0,
    fg: i32 = 8,
    bg: i32 = 8,
    us: i32 = 8,
    flags: i32 = 0,

    /// Current TTY attribute/colour state (tracks what the terminal has set).
    cell: GridCell = grid_default_cell,
    /// Last cell rendered via tty_attributes (used to skip redundant output).
    last_cell: GridCell = grid_default_cell,

    /// Scrolling region top (csr).
    rupper: u32 = 0,
    /// Scrolling region bottom (csr).
    rlower: u32 = 0,
    /// Left margin (DECSLRM).
    rleft: u32 = 0,
    /// Right margin (DECSLRM).
    rright: u32 = 0,

    ttyname: ?[]u8 = null,
    term_name: ?[]u8 = null,
    acs: [256][2]u8 = [_][2]u8{[_]u8{ 0, 0 }} ** 256,
    u8_cap_present: bool = false,
    u8_cap: i32 = 0,
    mouse_last_x: u32 = 0,
    mouse_last_y: u32 = 0,
    mouse_last_b: u32 = 0,
    mouse_drag_flag: u32 = 0,
    mouse_drag_update: ?*const fn (*Client, *MouseEvent) void = null,
    mouse_drag_release: ?*const fn (*Client, *MouseEvent) void = null,
    mouse_scrolling_flag: bool = false,
    mouse_slider_mpos: i32 = -1,
    clipboard_timer: ?*c.libevent.event = null,
    /// libevent timer that fires after TTY_QUERY_TIMEOUT to send DA/XDA requests.
    start_timer: ?*c.libevent.event = null,
    /// Timestamp (seconds since epoch) of the last tty_send_requests call.
    last_requests: i64 = 0,
};

// ── Layout ────────────────────────────────────────────────────────────────

pub const LayoutType = enum {
    leftright,
    topbottom,
    windowpane,
};

pub const LayoutCell = struct {
    type: LayoutType = .windowpane,
    parent: ?*LayoutCell = null,
    sx: u32 = 0,
    sy: u32 = 0,
    xoff: u32 = 0,
    yoff: u32 = 0,
    wp: ?*WindowPane = null,
    cells: std.ArrayList(*LayoutCell) = .{},
};

// ── WindowPane ────────────────────────────────────────────────────────────

pub const PANE_REDRAW: u32 = 0x0001;
pub const PANE_FOCUSED: u32 = 0x0004;
pub const PANE_VISITED: u32 = 0x0008;
pub const PANE_INPUTOFF: u32 = 0x0040;
pub const PANE_CHANGED: u32 = 0x0080;
pub const PANE_EXITED: u32 = 0x0100;
pub const PANE_STATUSREADY: u32 = 0x0200;
pub const PANE_STATUSDRAWN: u32 = 0x0400;
pub const PANE_EMPTY: u32 = 0x0800;
pub const PANE_STYLECHANGED: u32 = 0x1000;
pub const PANE_THEMECHANGED: u32 = 0x2000;
pub const PANE_UNSEENCHANGES: u32 = 0x4000;

pub const WindowMode = struct {
    name: []const u8 = "",
    key: ?*const fn (*WindowModeEntry, ?*Client, *Session, *Winlink, key_code, ?*const MouseEvent) void = null,
    key_table: ?*const fn (*WindowModeEntry) []const u8 = null,
    command: ?*const fn (*WindowModeEntry, ?*Client, *Session, *Winlink, *const anyopaque, ?*const MouseEvent) void = null,
    close: ?*const fn (*WindowModeEntry) void = null,
    get_screen: ?*const fn (*WindowModeEntry) *Screen = null,
};

pub const WindowModeEntry = struct {
    wp: *WindowPane,
    swp: ?*WindowPane = null,
    mode: *const WindowMode,
    data: ?*anyopaque = null,
    prefix: u32 = 0,
};

pub const WindowPane = struct {
    id: u32,
    active_point: u32 = 0,

    window: *Window,
    options: *Options,

    layout_cell: ?*LayoutCell = null,
    saved_layout_cell: ?*LayoutCell = null,

    sx: u32,
    sy: u32,
    xoff: u32 = 0,
    yoff: u32 = 0,

    flags: u32 = 0,

    // PTY
    argv: ?[][]u8 = null,
    shell: ?[]u8 = null,
    cwd: ?[]u8 = null,
    pid: std.posix.pid_t = -1,
    tty_name: [TTY_NAME_MAX]u8 = std.mem.zeroes([TTY_NAME_MAX]u8),
    status: i32 = 0,
    dead_time: i64 = 0,
    fd: i32 = -1,
    event: ?*c.libevent.event = null,

    // Screen
    screen: *Screen,
    base: Screen,
    input_pending: std.ArrayList(u8) = .{},
    modes: std.ArrayList(*WindowModeEntry) = .{},
    searchstr: ?[]u8 = null,
    searchregex: bool = false,

    // Colour palette
    palette: ColourPalette = .{},
    control_bg: i32 = -1,
    control_fg: i32 = -1,
    scrollbar_style: Style = .{},
    sb_slider_y: u32 = 0,
    sb_slider_h: u32 = 0,
    offset: WindowPaneOffset = .{},
    base_offset: usize = 0,

    // Pipe (pipe-pane)
    pipe_fd: i32 = -1,
    pipe_pid: std.posix.pid_t = -1,
    pipe_event: ?*c.libevent.event = null,
    pipe_flags: u8 = 0,
    pipe_offset: WindowPaneOffset = .{},

    // Resize queue (ported from tmux's TAILQ-based resize_queue)
    resize_queue: std.ArrayListUnmanaged(WindowPaneResize) = .{},
    resize_timer: ?*c.libevent.event = null,

    // Input request queue — pending outer-terminal queries (DA, clipboard, palette).
    // Mirrors tmux's per-input_ctx request TAILQ.  Each element is a heap pointer
    // so that Client.input_requests can hold a stable cross-reference.
    input_request_list: std.ArrayListUnmanaged(*InputRequest) = .{},
    input_request_count: u32 = 0,
    input_request_timer: ?*c.libevent.event = null,
};

// ── Window ────────────────────────────────────────────────────────────────

pub const WINDOW_BELL: u32 = 0x01;
pub const WINDOW_ACTIVITY: u32 = 0x02;
pub const WINDOW_SILENCE: u32 = 0x04;
pub const WINDOW_ALERTFLAGS: u32 = WINDOW_BELL | WINDOW_ACTIVITY | WINDOW_SILENCE;
pub const WINDOW_ZOOMED: u32 = 0x08;
pub const WINDOW_WASZOOMED: u32 = 0x10;
pub const WINDOW_RESIZE: u32 = 0x20;
pub const PANE_PIPE_READ: u8 = 0x01;
pub const PANE_PIPE_WRITE: u8 = 0x02;

pub const Window = struct {
    id: u32,
    latest: ?*anyopaque = null,

    name: []u8,

    active: ?*WindowPane = null,
    panes: std.ArrayList(*WindowPane) = .{},
    last_panes: std.ArrayList(*WindowPane) = .{},

    lastlayout: i32 = -1,
    layout_root: ?*LayoutCell = null,
    saved_layout_root: ?*LayoutCell = null,
    old_layout: ?[]u8 = null,

    sx: u32,
    sy: u32,
    manual_sx: u32 = 0,
    manual_sy: u32 = 0,
    xpixel: u32 = DEFAULT_XPIXEL,
    ypixel: u32 = DEFAULT_YPIXEL,

    new_sx: u32 = 0,
    new_sy: u32 = 0,

    flags: u32 = 0,
    options: *Options,
    fill_character: ?[]Utf8Data = null,
    references: u32 = 0,
    winlinks: std.ArrayList(*Winlink) = .{},
    alerts_timer: ?*c.libevent.event = null,
    name_event: ?*c.libevent.event = null,
    name_time: std.posix.timeval = .{ .sec = 0, .usec = 0 },
    alerts_queued: bool = false,
    activity_time: i64 = 0,
    creation_time: i64 = 0,
};

// ── Winlink ───────────────────────────────────────────────────────────────

pub const WINLINK_BELL: u32 = 0x01;
pub const WINLINK_ACTIVITY: u32 = 0x02;
pub const WINLINK_SILENCE: u32 = 0x04;
pub const WINLINK_ALERTFLAGS: u32 = WINLINK_BELL | WINLINK_ACTIVITY | WINLINK_SILENCE;
pub const WINLINK_VISITED: u32 = 0x08;

pub const Winlink = struct {
    idx: i32,
    session: *Session,
    window: *Window,
    flags: u32 = 0,
};

// ── Session ───────────────────────────────────────────────────────────────

pub const SESSION_ALERTED: u32 = 0x01;

pub const SessionGroup = struct {
    name: []const u8,
    sessions: std.ArrayList(*Session) = .{},
};

pub const Session = struct {
    id: u32,
    name: []u8,
    cwd: []const u8,
    created: i64 = 0,
    activity_time: i64 = 0,
    last_attached_time: i64 = 0,

    curw: ?*Winlink = null,
    lastw: std.ArrayList(*Winlink) = .{},
    windows: std.AutoHashMap(i32, *Winlink) = undefined, // keyed by idx

    statusat: i32 = 0,
    statuslines: u32 = 1,

    options: *Options,
    flags: u32 = 0,
    attached: u32 = 0,

    tio: ?*std.posix.termios = null,
    environ: *Environ,
    references: i32 = 1,
};

// ── Options ───────────────────────────────────────────────────────────────

pub const OptionsType = enum {
    string,
    number,
    bool,
    choice,
    colour,
    style,
    flag,
    array,
    command,
};

pub const OptionsScope = packed struct {
    server: bool = false,
    session: bool = false,
    window: bool = false,
    pane: bool = false,
};

pub const OPTIONS_TABLE_SERVER: OptionsScope = .{ .server = true };
pub const OPTIONS_TABLE_SESSION: OptionsScope = .{ .session = true };
pub const OPTIONS_TABLE_WINDOW: OptionsScope = .{ .window = true };
pub const OPTIONS_TABLE_PANE: OptionsScope = .{ .pane = true };

pub const OptionsTableEntry = struct {
    name: []const u8,
    type: OptionsType,
    scope: OptionsScope,
    is_hook: bool = false,
    default_num: i64 = 0,
    default_str: ?[]const u8 = null,
    default_arr: ?[]const []const u8 = null,
    choices: ?[]const []const u8 = null,
    minimum: ?i64 = null,
    maximum: ?i64 = null,
    unit: ?[]const u8 = null,
    text: ?[]const u8 = null,
    separator: ?[]const u8 = null,
};

pub const OptionsArrayItem = struct {
    index: u32,
    value: []u8,
};

pub const OptionsValue = union(OptionsType) {
    string: []u8,
    number: i64,
    bool: bool,
    choice: u32,
    colour: i32,
    style: Style,
    flag: bool,
    array: std.ArrayList(OptionsArrayItem),
    command: []u8,
};

pub const Options = struct {
    parent: ?*Options,
    entries: std.StringHashMap(OptionsValue),

    pub fn init(alloc: std.mem.Allocator, parent: ?*Options) Options {
        return .{ .parent = parent, .entries = std.StringHashMap(OptionsValue).init(alloc) };
    }
    pub fn deinit(self: *Options) void {
        self.entries.deinit();
    }
};

// ── Environ ───────────────────────────────────────────────────────────────

pub const ENVIRON_HIDDEN: u32 = 0x01;

pub const EnvironEntry = struct {
    name: []u8,
    value: ?[]u8,
    flags: u32 = 0,
};

pub const Environ = struct {
    entries: std.StringHashMap(EnvironEntry),

    pub fn init(alloc: std.mem.Allocator) Environ {
        return .{ .entries = std.StringHashMap(EnvironEntry).init(alloc) };
    }
    pub fn deinit(self: *Environ) void {
        self.entries.deinit();
    }
};

// ── Input request queue ───────────────────────────────────────────────────
//
// Mirrors tmux's `input_request` / `input_request_type` from input.c.
// A pane can have pending requests to the outer terminal (palette colour
// lookups, clipboard reads). Each request carries a type and optional
// payload data; replies are dispatched through input_request_reply.

/// Type of request sent to the outer terminal on behalf of a pane.
pub const InputRequestType = enum {
    palette,   // OSC 4 colour-index query
    clipboard, // OSC 52 clipboard read
    queue,     // deferred reply queued behind another request
};

/// Timeout in milliseconds after which an unanswered request is discarded.
pub const INPUT_REQUEST_TIMEOUT: u64 = 500;

/// Per-request payload for a palette colour query (OSC 4 reply).
pub const InputRequestPaletteData = struct {
    idx: i32,
    c: i32,
};

/// Per-request payload for a clipboard query (OSC 52 reply).
pub const InputRequestClipboardData = struct {
    buf: ?[]u8 = null,
    clip: u8 = 0,
};

/// Whether the originating OSC string was terminated by BEL (0x07) or ST.
pub const InputEndType = enum(u8) {
    st = 0,  // ESC backslash  (String Terminator)
    bel = 1, // BEL (0x07)
};

/// A single pending request from a pane to the outer terminal.
pub const InputRequest = struct {
    /// The pane whose parser issued this request.  Null if the pane
    /// has been destroyed before the reply arrived.
    wp: ?*WindowPane = null,
    /// The client whose tty should receive / forward the reply.
    c: ?*Client = null,
    type: InputRequestType,
    /// Monotonic timestamp (ms) when the request was created.
    t: u64 = 0,
    end: InputEndType = .st,
    /// Colour-index (for .palette) or ignored.
    idx: i32 = 0,
    /// Optional per-type payload allocated via xmalloc; freed on discard.
    data: ?*anyopaque = null,
};

// ── Client ────────────────────────────────────────────────────────────────

pub const CLIENT_TERMINAL: u64 = 0x000001;
pub const CLIENT_LOGIN: u64 = 0x000002;
pub const CLIENT_EXIT: u64 = 0x000004;
pub const CLIENT_REDRAWWINDOW: u64 = 0x000008;
pub const CLIENT_REDRAWSTATUS: u64 = 0x000010;
pub const CLIENT_REDRAWSTATUSALWAYS: u64 = 0x000020;
pub const CLIENT_REDRAWBORDERS: u64 = 0x000040;
pub const CLIENT_REDRAWPANES: u64 = 0x000080;
pub const CLIENT_REDRAWOVERLAY: u64 = 0x000100;
pub const CLIENT_REDRAWSCROLLBARS: u64 = 0x000200;
pub const CLIENT_REDRAW: u64 = CLIENT_REDRAWWINDOW | CLIENT_REDRAWSTATUS | CLIENT_REDRAWSTATUSALWAYS | CLIENT_REDRAWBORDERS | CLIENT_REDRAWPANES | CLIENT_REDRAWOVERLAY | CLIENT_REDRAWSCROLLBARS;
pub const CLIENT_CONTROL: u64 = 0x000400;
pub const CLIENT_CONTROLCONTROL: u64 = 0x000800;
pub const CLIENT_FOCUSED: u64 = 0x001000;
pub const CLIENT_UTF8: u64 = 0x002000;
pub const CLIENT_IDENTIFIED: u64 = 0x004000;
pub const CLIENT_ATTACHED: u64 = 0x008000;
pub const CLIENT_STARTSERVER: u64 = 0x010000;
pub const CLIENT_NOSTARTSERVER: u64 = 0x020000;
pub const CLIENT_READONLY: u64 = 0x040000;
pub const CLIENT_IGNORESIZE: u64 = 0x080000;
pub const CLIENT_NOFORK: u64 = 0x100000;
pub const CLIENT_DEFAULTSOCKET: u64 = 0x200000;
pub const CLIENT_SIZECHANGED: u64 = 0x400000;
pub const CLIENT_STATUSOFF: u64 = 0x800000;
pub const CLIENT_SUSPENDED: u64 = 0x1000000;
pub const CLIENT_CONTROL_NOOUTPUT: u64 = 0x4000000;
pub const CLIENT_ACTIVEPANE: u64 = 0x80000000;
pub const CLIENT_CONTROL_PAUSEAFTER: u64 = 0x100000000;
pub const CLIENT_CONTROL_WAITEXIT: u64 = 0x200000000;
pub const CLIENT_WINDOWSIZECHANGED: u64 = 0x400000000;
pub const CLIENT_NO_DETACH_ON_DESTROY: u64 = 0x8000000000;
pub const CLIENT_DEAD: u64 = 0x10000000000;
pub const CLIENT_REPEAT: u64 = 0x20000000000;

pub const CLIENT_UNATTACHEDFLAGS: u64 = CLIENT_DEAD | CLIENT_SUSPENDED | CLIENT_EXIT;

pub const ClientExitReason = enum {
    none,
    detached,
    detached_hup,
    lost_tty,
    terminated,
    lost_server,
    exited,
    server_exited,
    message_provided,
};

pub const MouseClickState = enum {
    none,
    double_pending,
    triple_pending,
};

pub const StatusLine = struct {
    screen: ?*Screen = null,
    active: ?*Screen = null,
    references: u32 = 0,
    timer: ?*c.libevent.event = null,
    style: GridCell = std.mem.zeroes(GridCell),
    entries: [STATUS_LINES_LIMIT]StatusLineEntry = [_]StatusLineEntry{.{}} ** STATUS_LINES_LIMIT,
};

pub const StatusLineEntry = struct {
    expanded: ?[]u8 = null,
    ranges: StyleRanges = .{},
};

pub const ClientWindow = struct {
    window: u32,
    pane: ?*WindowPane = null,
    sx: u32 = 0,
    sy: u32 = 0,
};

pub const ControlSubType = enum {
    session,
    pane,
    all_panes,
    window,
    all_windows,
};

pub const ControlSubscriptionPane = struct {
    pane: u32,
    idx: i32,
    last: ?[]u8 = null,
};

pub const ControlSubscriptionWindow = struct {
    window: u32,
    idx: i32,
    last: ?[]u8 = null,
};

pub const ControlSubscription = struct {
    name: []u8,
    format: []u8,
    sub_type: ControlSubType,
    id: u32 = 0,
    last: ?[]u8 = null,
    panes: std.ArrayListUnmanaged(ControlSubscriptionPane) = .{},
    windows: std.ArrayListUnmanaged(ControlSubscriptionWindow) = .{},

    pub fn deinit(self: *ControlSubscription, alloc: std.mem.Allocator) void {
        alloc.free(self.name);
        alloc.free(self.format);
        if (self.last) |last| alloc.free(last);
        for (self.panes.items) |pane| {
            if (pane.last) |last| alloc.free(last);
        }
        self.panes.deinit(alloc);
        for (self.windows.items) |window| {
            if (window.last) |last| alloc.free(last);
        }
        self.windows.deinit(alloc);
    }
};

pub const WindowPaneOffset = struct {
    used: usize = 0,
};

pub const WindowPaneResize = struct {
    osx: u32,
    osy: u32,
    sx: u32,
    sy: u32,
};

pub const CONTROL_PANE_OFF: u8 = 0x1;
pub const CONTROL_PANE_PAUSED: u8 = 0x2;

pub const ControlBlock = struct {
    size: usize = 0,
    line: ?[]u8 = null,
    t: i64 = 0,
    pane_id: ?u32 = null,
};

pub const ControlPane = struct {
    pane: u32,
    offset: WindowPaneOffset = .{},
    queued: WindowPaneOffset = .{},
    flags: u8 = 0,
    pending_flag: bool = false,
    blocks: std.ArrayListUnmanaged(*ControlBlock) = .{},
};

pub const ClientPaneCache = struct {
    pane_id: ?u32 = null,
    sx: u32 = 0,
    sy: u32 = 0,
    scrollbar_left: bool = false,
    scrollbar_width: u32 = 0,
    scrollbar_pad: u32 = 0,
    scrollbar_slider_y: u32 = 0,
    scrollbar_slider_h: u32 = 0,
    rows: std.ArrayList([]u8) = .{},
    cursor_x: u32 = 0,
    cursor_y: u32 = 0,
    cursor_visible: bool = true,
    valid: bool = false,
};

pub const MouseEvent = struct {
    valid: bool = false,
    ignore: bool = false,
    key: key_code = KEYC_NONE,
    statusat: i32 = -1,
    statuslines: u32 = 0,
    x: u32 = 0,
    y: u32 = 0,
    b: u32 = 0,
    lx: u32 = 0,
    ly: u32 = 0,
    lb: u32 = 0,
    ox: u32 = 0,
    oy: u32 = 0,
    s: i32 = -1,
    w: i32 = -1,
    wp: i32 = -1,
    sgr_type: u8 = ' ',
    sgr_b: u32 = 0,
};

pub const key_event = struct {
    key: key_code = KEYC_UNKNOWN,
    data: [16]u8 = std.mem.zeroes([16]u8),
    len: usize = 0,
    m: MouseEvent = .{},
};

pub const OverlayCheckCb = *const fn (*Client, ?*anyopaque, u32, u32) bool;
pub const OverlayModeCb = *const fn (*Client, ?*anyopaque, *u32, *u32) ?*anyopaque;
pub const OverlayDrawCb = *const fn (*Client, ?*anyopaque, *anyopaque) void;
pub const OverlayKeyCb = *const fn (*Client, ?*anyopaque, *key_event) i32;
pub const OverlayFreeCb = *const fn (*Client, ?*anyopaque) void;
pub const OverlayResizeCb = *const fn (*Client, ?*anyopaque) void;

pub const Client = struct {
    id: u32 = 0,
    name: ?[]const u8 = null,
    peer: ?*ZmuxPeer = null,

    creation_time: i64 = 0,
    activity_time: i64 = 0,
    last_activity_time: i64 = 0,

    pid: std.posix.pid_t = 0,
    fd: i32 = -1,
    out_fd: i32 = -1,
    retval: i32 = 0,

    environ: *Environ,
    title: ?[]u8 = null,
    path: ?[]u8 = null,
    cwd: ?[]const u8 = null,

    term_name: ?[]u8 = null,
    term_features: i32 = 0,
    term_type: ?[]u8 = null,
    term_caps: ?[][]u8 = null,
    ttyname: ?[]u8 = null,
    discarded: usize = 0,
    theme: ClientTheme = .unknown,

    tty: Tty,
    status: StatusLine,
    pane_cache: ClientPaneCache = .{},
    stdin_pending: std.ArrayList(u8) = .{},
    key_table_name: ?[]u8 = null,
    escape_timer: ?*c.libevent.event = null,
    click_timer: ?*c.libevent.event = null,
    message_timer: ?*c.libevent.event = null,
    display_panes_timer: ?*c.libevent.event = null,
    display_panes_data: ?*anyopaque = null,
    menu_data: ?*anyopaque = null,
    popup_data: ?*anyopaque = null,

    overlay_check: ?OverlayCheckCb = null,
    overlay_mode: ?OverlayModeCb = null,
    overlay_draw: ?OverlayDrawCb = null,
    overlay_key: ?OverlayKeyCb = null,
    overlay_free: ?OverlayFreeCb = null,
    overlay_resize: ?OverlayResizeCb = null,
    overlay_data: ?*anyopaque = null,
    overlay_timer: ?*c.libevent.event = null,

    repeat_timer: ?*c.libevent.event = null,
    last_key: key_code = KEYC_NONE,

    flags: u64 = 0,
    session: ?*Session = null,
    last_session: ?*Session = null,
    client_windows: std.ArrayListUnmanaged(ClientWindow) = .{},
    control_panes: std.ArrayListUnmanaged(ControlPane) = .{},
    control_subscriptions: std.ArrayListUnmanaged(ControlSubscription) = .{},
    control_subs_timer: ?*c.libevent.event = null,
    control_all_blocks: std.ArrayListUnmanaged(*ControlBlock) = .{},
    control_pending_count: u32 = 0,
    control_ready_flag: bool = false,
    pan_window: ?*Window = null,
    pan_ox: u32 = 0,
    pan_oy: u32 = 0,

    exit_reason: ClientExitReason = .none,
    exit_message: ?[]u8 = null,
    exit_session: ?[]u8 = null,

    message_string: ?[]u8 = null,
    message_ignore_keys: bool = false,
    message_ignore_styles: bool = false,
    click_event: MouseEvent = .{},
    click_button: u32 = 0,
    click_target: ?KeyMouseTarget = null,
    click_wp: i32 = -1,
    click_state: MouseClickState = .none,
    pause_age: u32 = 0,

    /// Pending input requests associated with this client (cross-reference into
    /// WindowPane.input_request_list entries whose .c == this client).
    /// Mirrors tmux's client.input_requests TAILQ.
    input_requests: std.ArrayListUnmanaged(*InputRequest) = .{},
};

// ── Client file IPC ───────────────────────────────────────────────────────

pub const ClientFileCb = ?*const fn (?*Client, ?[]const u8, c_int, i32, ?[]const u8, ?*anyopaque) void;

pub const ClientFile = struct {
    client: ?*Client = null,
    peer: ?*ZmuxPeer = null,
    tree: ?*ClientFiles = null,

    references: u32 = 1,
    stream: i32 = 0,
    path: ?[]u8 = null,

    buffer: std.ArrayList(u8) = .{},
    cb: ClientFileCb = null,
    data: ?*anyopaque = null,

    fd: i32 = -1,
    @"error": c_int = 0,
    closed: bool = false,
};

pub const ClientFiles = std.AutoHashMap(i32, *ClientFile);

// ── IPC proc layer ────────────────────────────────────────────────────────

pub const PEER_BAD: u32 = 0x1;

pub const ZmuxPeer = struct {
    parent: *ZmuxProc,
    ibuf: c.imsg.imsgbuf,
    event: ?*c.libevent.event = null,
    uid: std.posix.uid_t = 0,
    flags: u32 = 0,
    dispatchcb: *const fn (?*c.imsg.imsg, ?*anyopaque) callconv(.c) void,
    arg: ?*anyopaque = null,
};

pub const ZmuxProc = struct {
    name: []const u8,
    exit: bool = false,
    signalcb: ?*const fn (i32) callconv(.c) void = null,
    peers: std.ArrayList(*ZmuxPeer) = .{},
    sig_events: std.ArrayList(*c.libevent.event) = .{},
};

// ── Command framework ─────────────────────────────────────────────────────

pub const CmdRetval = enum(i32) {
    @"error" = -1,
    normal = 0,
    wait = 1,
    stop = 2,
};

pub const CMD_STARTSERVER: u32 = 0x01;
pub const CMD_READONLY: u32 = 0x02;
pub const CMD_AFTERHOOK: u32 = 0x04;
pub const CMD_CLIENT_CFLAG: u32 = 0x08;
pub const CMD_CLIENT_TFLAG: u32 = 0x10;
pub const CMD_CLIENT_CANFAIL: u32 = 0x20;

pub const CmdFindType = enum {
    pane,
    window,
    session,
};

pub const CMD_FIND_PREFER_UNATTACHED: u32 = 0x01;
pub const CMD_FIND_QUIET: u32 = 0x02;
pub const CMD_FIND_WINDOW_INDEX: u32 = 0x04;
pub const CMD_FIND_DEFAULT_MARKED: u32 = 0x08;
pub const CMD_FIND_EXACT_SESSION: u32 = 0x10;
pub const CMD_FIND_EXACT_WINDOW: u32 = 0x20;
pub const CMD_FIND_CANFAIL: u32 = 0x40;

pub const CmdFindState = struct {
    flags: u32 = 0,
    current: ?*CmdFindState = null,
    s: ?*Session = null,
    wl: ?*Winlink = null,
    w: ?*Window = null,
    wp: ?*WindowPane = null,
    idx: i32 = 0,
};

pub const CmdParseStatus = enum {
    @"error",
    success,
};

pub const CmdParseResult = struct {
    status: CmdParseStatus,
    cmdlist: ?*anyopaque = null,
    @"error": ?[]u8 = null,
};

pub const CmdParseInput = struct {
    flags: u32 = 0,
    file: ?[]const u8 = null,
    line: u32 = 0,
    item: ?*CmdqItem = null,
    c: ?*Client = null,
    fs: CmdFindState = .{},
};

// cmd_parse flags (matching tmux tmux.h values)
pub const CMD_PARSE_PARSEONLY: u32 = 0x2;
pub const CMD_PARSE_ONEGROUP: u32 = 0x10;
pub const CMD_PARSE_VERBOSE: u32 = 0x20;
pub const CMD_PARSE_NOALIAS: u32 = 0x40;

pub const CMDQ_STATE_REPEAT: u32 = 0x1;
pub const CMDQ_STATE_CONTROL: u32 = 0x2;
pub const CMDQ_STATE_NOHOOKS: u32 = 0x4;
pub const CMDQ_STATE_NOATTACH: u32 = 0x8;

pub const KEY_BINDING_REPEAT: u32 = 0x1;

pub const KeyBinding = struct {
    key: key_code,
    tablename: []const u8,
    note: ?[]u8 = null,
    flags: u32 = 0,
    cmdlist: ?*CmdList = null,
};

pub const KeyTable = struct {
    name: []u8,
    references: u32 = 1,
    key_bindings: std.AutoHashMap(key_code, *KeyBinding),
    default_key_bindings: std.AutoHashMap(key_code, *KeyBinding),
    order: std.ArrayList(*KeyBinding) = .{},
    default_order: std.ArrayList(*KeyBinding) = .{},

    pub fn init(alloc: std.mem.Allocator, name: []u8) KeyTable {
        return .{
            .name = name,
            .key_bindings = std.AutoHashMap(key_code, *KeyBinding).init(alloc),
            .default_key_bindings = std.AutoHashMap(key_code, *KeyBinding).init(alloc),
        };
    }

    pub fn deinit(self: *KeyTable) void {
        self.key_bindings.deinit();
        self.default_key_bindings.deinit();
        self.order.deinit(std.heap.c_allocator);
        self.default_order.deinit(std.heap.c_allocator);
    }
};

// Opaque forward references – filled in by cmd.zig and cmd-queue.zig
pub const CmdList = opaque {};
pub const CmdqItem = opaque {};
pub const Cmd = opaque {};
pub const CmdqList = opaque {};

pub const ArgsType = enum {
    none,
    string,
    commands,
};

pub const ArgsValue = struct {
    type: ArgsType = .none,
    data: union {
        string: []u8,
        cmdlist: *CmdList,
        none: void,
    } = .{ .none = {} },
    cached: ?[]u8 = null,
};

pub const Args = struct {
    flags: std.AutoHashMap(u8, []ArgsValue),
    values: std.ArrayList(ArgsValue),
};

// ── Spawn context ─────────────────────────────────────────────────────────

pub const SPAWN_KILL: u32 = 0x01;
pub const SPAWN_DETACHED: u32 = 0x02;
pub const SPAWN_RESPAWN: u32 = 0x04;
pub const SPAWN_CANFAIL: u32 = 0x08;
pub const SPAWN_EMPTY: u32 = 0x10;
pub const SPAWN_NONOTIFY: u32 = 0x20;
pub const SPAWN_BEFORE: u32 = 0x40;
pub const SPAWN_FULLSIZE: u32 = 0x80;
pub const SPAWN_NEWWINDOW: u32 = 0x100;
pub const SPAWN_ZOOM: u32 = 0x200;

pub const SpawnContext = struct {
    item: ?*CmdqItem = null,
    s: ?*Session = null,
    wl: ?*Winlink = null,
    wp0: ?*WindowPane = null,
    lc: ?*LayoutCell = null,
    name: ?[]const u8 = null,
    argv: ?[][]u8 = null,
    environ: ?*Environ = null,
    idx: i32 = -1,
    cwd: ?[]const u8 = null,
    flags: u32 = 0,
};

// ── Message log ───────────────────────────────────────────────────────────

pub const MessageEntry = struct {
    msg: []u8,
    msg_num: u32,
    msg_time: i64, // unix timestamp
};

// ── Alert and window-size constants ───────────────────────────────────────

pub const ALERT_NONE: u32 = 0;
pub const ALERT_ANY: u32 = 1;
pub const ALERT_CURRENT: u32 = 2;
pub const ALERT_OTHER: u32 = 3;
pub const VISUAL_OFF: u32 = 0;
pub const VISUAL_ON: u32 = 1;
pub const VISUAL_BOTH: u32 = 2;

pub const WINDOW_SIZE_LARGEST: u32 = 0;
pub const WINDOW_SIZE_SMALLEST: u32 = 1;
pub const WINDOW_SIZE_MANUAL: u32 = 2;
pub const WINDOW_SIZE_LATEST: u32 = 3;

pub const PANE_STATUS_OFF: u32 = 0;
pub const PANE_STATUS_TOP: u32 = 1;
pub const PANE_STATUS_BOTTOM: u32 = 2;

// ── Screen write collect types ────────────────────────────────────────────

pub const SCREEN_WRITE_SYNC: u32 = 0x4;

pub const ScreenWriteCitemType = enum(u8) {
    TEXT = 0,
    CLEAR = 1,
};

pub const ScreenWriteCitem = struct {
    x: u32 = 0,
    wrapped: bool = false,
    ctype: ScreenWriteCitemType = .TEXT,
    used: u32 = 0,
    bg: u32 = 8,
    gc: GridCell = grid_default_cell,
    prev: ?*ScreenWriteCitem = null,
    next: ?*ScreenWriteCitem = null,
};

pub const ScreenWriteCline = struct {
    data: ?[]u8 = null,
    first: ?*ScreenWriteCitem = null,
    last: ?*ScreenWriteCitem = null,
};

pub const ScreenWriteInitCtxCb = *const fn (*ScreenWriteCtx, *TtyCtx) void;

pub const TtyCtx = struct {
    s: ?*Screen = null,
    sx: u32 = 0,
    sy: u32 = 0,
    ocx: u32 = 0,
    ocy: u32 = 0,
    orlower: u32 = 0,
    orupper: u32 = 0,
    num: u32 = 0,
    bg: u32 = 8,
    cell: ?*const GridCell = null,
    wrapped: bool = false,
    ptr: ?[*]const u8 = null,
    ptr2: ?[*:0]const u8 = null,
    defaults: GridCell = grid_default_cell,
    bigger: bool = false,
    wox: u32 = 0,
    woy: u32 = 0,
    wsx: u32 = 0,
    wsy: u32 = 0,
    xoff: u32 = 0,
    yoff: u32 = 0,
    rxoff: u32 = 0,
    ryoff: u32 = 0,
    palette: ?*ColourPalette = null,
    redraw_cb: ?*const fn (*const TtyCtx) void = null,
    set_client_cb: ?*const fn (*TtyCtx, *Client) i32 = null,
    arg: ?*anyopaque = null,
    allow_invisible_panes: bool = false,
};

// ── Screen write context ──────────────────────────────────────────────────

pub const ScreenWriteCtx = struct {
    wp: ?*WindowPane = null,
    s: *Screen,
    flags: u32 = 0,
    item: ?*ScreenWriteCitem = null,
    scrolled: u32 = 0,
    bg: u32 = 8,
    init_ctx_cb: ?ScreenWriteInitCtxCb = null,
    arg: ?*anyopaque = null,
};
