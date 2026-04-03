// Copyright (c) 2024 Greg Turner <gmt@be-evil.net>
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
// Ported from tmux/tty-keys.c.
// Original copyright:
//   Copyright (c) 2007 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

//! tty-keys.zig – server-side terminal input decoder.
//!
//! Implements:
//!   - A ternary search tree (TST) for key sequence lookup.
//!   - tty_keys_build / tty_keys_free: tree construction from key tables.
//!   - tty_keys_next: main decode function that processes one key from a
//!     byte buffer, handles ambiguity timers (partial-match), produces
//!     key_event output.
//!   - tty_keys_extended_key: CSI u / modifyOtherKeys (xterm) parsing.
//!   - tty_keys_mouse: X10 and SGR mouse protocol parsing.
//!   - tty_keys_clipboard: OSC 52 bracketed-paste / clipboard response.
//!   - tty_keys_device_attributes: DA1 / DA2 / XDA response parsers.
//!   - tty_keys_winsz: window size report (CSI 8;...t).
//!   - tty_keys_colours: fg/bg colour report (OSC 10/11).
//!   - tty_keys_palette: palette colour response (OSC 4).

const std = @import("std");
const T = @import("types.zig");
const utf8_mod = @import("utf8.zig");
const tty_term_mod = @import("tty-term.zig");
const xm = @import("xmalloc.zig");

// Mouse parameter offsets (from tmux.h)
pub const MOUSE_PARAM_MAX: u32 = 0xff;
pub const MOUSE_PARAM_UTF8_MAX: u32 = 0x7ff;
pub const MOUSE_PARAM_BTN_OFF: u32 = 0x20;
pub const MOUSE_PARAM_POS_OFF: u32 = 0x21;

// ── Ternary search tree ───────────────────────────────────────────────────

/// One node in the ternary search tree (TST).
///
/// The TST stores key escape sequences.  Each node matches one byte.
/// `left`/`right` navigate the binary search level among siblings at the
/// same position in the input string.  `next` descends to the next
/// character of the sequence.  `key` holds the decoded key when this node
/// terminates a valid sequence; KEYC_UNKNOWN otherwise.
pub const TtyKey = struct {
    ch: u8,
    key: T.key_code,
    left: ?*TtyKey = null,
    right: ?*TtyKey = null,
    next: ?*TtyKey = null,
};

// ── Default key tables ─────────────────────────────────────────────────────

const DefaultKeyRaw = struct {
    string: []const u8,
    key: T.key_code,
};

const DefaultKeyXterm = struct {
    template: []const u8,
    key: T.key_code,
};

const DefaultKeyCode = struct {
    code: tty_term_mod.TTYC,
    key: T.key_code,
};

const tty_default_raw_keys = [_]DefaultKeyRaw{
    // Application escape.
    .{ .string = "\x1bO[", .key = '\x1b' },

    // Numeric keypad (vt100 escape sequences).
    .{ .string = "\x1bOo", .key = T.KEYC_KP_SLASH | T.KEYC_KEYPAD },
    .{ .string = "\x1bOj", .key = T.KEYC_KP_STAR | T.KEYC_KEYPAD },
    .{ .string = "\x1bOm", .key = T.KEYC_KP_MINUS | T.KEYC_KEYPAD },
    .{ .string = "\x1bOw", .key = T.KEYC_KP_SEVEN | T.KEYC_KEYPAD },
    .{ .string = "\x1bOx", .key = T.KEYC_KP_EIGHT | T.KEYC_KEYPAD },
    .{ .string = "\x1bOy", .key = T.KEYC_KP_NINE | T.KEYC_KEYPAD },
    .{ .string = "\x1bOk", .key = T.KEYC_KP_PLUS | T.KEYC_KEYPAD },
    .{ .string = "\x1bOt", .key = T.KEYC_KP_FOUR | T.KEYC_KEYPAD },
    .{ .string = "\x1bOu", .key = T.KEYC_KP_FIVE | T.KEYC_KEYPAD },
    .{ .string = "\x1bOv", .key = T.KEYC_KP_SIX | T.KEYC_KEYPAD },
    .{ .string = "\x1bOq", .key = T.KEYC_KP_ONE | T.KEYC_KEYPAD },
    .{ .string = "\x1bOr", .key = T.KEYC_KP_TWO | T.KEYC_KEYPAD },
    .{ .string = "\x1bOs", .key = T.KEYC_KP_THREE | T.KEYC_KEYPAD },
    .{ .string = "\x1bOM", .key = T.KEYC_KP_ENTER | T.KEYC_KEYPAD },
    .{ .string = "\x1bOp", .key = T.KEYC_KP_ZERO | T.KEYC_KEYPAD },
    .{ .string = "\x1bOn", .key = T.KEYC_KP_PERIOD | T.KEYC_KEYPAD },

    // Arrow keys.
    .{ .string = "\x1bOA", .key = T.KEYC_UP | T.KEYC_CURSOR },
    .{ .string = "\x1bOB", .key = T.KEYC_DOWN | T.KEYC_CURSOR },
    .{ .string = "\x1bOC", .key = T.KEYC_RIGHT | T.KEYC_CURSOR },
    .{ .string = "\x1bOD", .key = T.KEYC_LEFT | T.KEYC_CURSOR },

    .{ .string = "\x1b[A", .key = T.KEYC_UP | T.KEYC_CURSOR },
    .{ .string = "\x1b[B", .key = T.KEYC_DOWN | T.KEYC_CURSOR },
    .{ .string = "\x1b[C", .key = T.KEYC_RIGHT | T.KEYC_CURSOR },
    .{ .string = "\x1b[D", .key = T.KEYC_LEFT | T.KEYC_CURSOR },

    // Meta arrow keys (no IMPLIED_META flag so Esc+Up stays Esc+Up not M-Up).
    .{ .string = "\x1b\x1bOA", .key = T.KEYC_UP | T.KEYC_CURSOR | T.KEYC_META },
    .{ .string = "\x1b\x1bOB", .key = T.KEYC_DOWN | T.KEYC_CURSOR | T.KEYC_META },
    .{ .string = "\x1b\x1bOC", .key = T.KEYC_RIGHT | T.KEYC_CURSOR | T.KEYC_META },
    .{ .string = "\x1b\x1bOD", .key = T.KEYC_LEFT | T.KEYC_CURSOR | T.KEYC_META },

    .{ .string = "\x1b\x1b[A", .key = T.KEYC_UP | T.KEYC_CURSOR | T.KEYC_META },
    .{ .string = "\x1b\x1b[B", .key = T.KEYC_DOWN | T.KEYC_CURSOR | T.KEYC_META },
    .{ .string = "\x1b\x1b[C", .key = T.KEYC_RIGHT | T.KEYC_CURSOR | T.KEYC_META },
    .{ .string = "\x1b\x1b[D", .key = T.KEYC_LEFT | T.KEYC_CURSOR | T.KEYC_META },

    // Other xterm keys.
    .{ .string = "\x1bOH", .key = T.KEYC_HOME },
    .{ .string = "\x1bOF", .key = T.KEYC_END },

    .{ .string = "\x1b\x1bOH", .key = T.KEYC_HOME | T.KEYC_META | T.KEYC_IMPLIED_META },
    .{ .string = "\x1b\x1bOF", .key = T.KEYC_END | T.KEYC_META | T.KEYC_IMPLIED_META },

    .{ .string = "\x1b[H", .key = T.KEYC_HOME },
    .{ .string = "\x1b[F", .key = T.KEYC_END },

    .{ .string = "\x1b\x1b[H", .key = T.KEYC_HOME | T.KEYC_META | T.KEYC_IMPLIED_META },
    .{ .string = "\x1b\x1b[F", .key = T.KEYC_END | T.KEYC_META | T.KEYC_IMPLIED_META },

    // rxvt arrow keys.
    .{ .string = "\x1bOa", .key = T.KEYC_UP | T.KEYC_CTRL },
    .{ .string = "\x1bOb", .key = T.KEYC_DOWN | T.KEYC_CTRL },
    .{ .string = "\x1bOc", .key = T.KEYC_RIGHT | T.KEYC_CTRL },
    .{ .string = "\x1bOd", .key = T.KEYC_LEFT | T.KEYC_CTRL },

    .{ .string = "\x1b[a", .key = T.KEYC_UP | T.KEYC_SHIFT },
    .{ .string = "\x1b[b", .key = T.KEYC_DOWN | T.KEYC_SHIFT },
    .{ .string = "\x1b[c", .key = T.KEYC_RIGHT | T.KEYC_SHIFT },
    .{ .string = "\x1b[d", .key = T.KEYC_LEFT | T.KEYC_SHIFT },

    // rxvt function keys.
    .{ .string = "\x1b[11~", .key = T.KEYC_F1 },
    .{ .string = "\x1b[12~", .key = T.KEYC_F2 },
    .{ .string = "\x1b[13~", .key = T.KEYC_F3 },
    .{ .string = "\x1b[14~", .key = T.KEYC_F4 },
    .{ .string = "\x1b[15~", .key = T.KEYC_F5 },
    .{ .string = "\x1b[17~", .key = T.KEYC_F6 },
    .{ .string = "\x1b[18~", .key = T.KEYC_F7 },
    .{ .string = "\x1b[19~", .key = T.KEYC_F8 },
    .{ .string = "\x1b[20~", .key = T.KEYC_F9 },
    .{ .string = "\x1b[21~", .key = T.KEYC_F10 },

    .{ .string = "\x1b[23~", .key = T.KEYC_F1 | T.KEYC_SHIFT },
    .{ .string = "\x1b[24~", .key = T.KEYC_F2 | T.KEYC_SHIFT },
    .{ .string = "\x1b[25~", .key = T.KEYC_F3 | T.KEYC_SHIFT },
    .{ .string = "\x1b[26~", .key = T.KEYC_F4 | T.KEYC_SHIFT },
    .{ .string = "\x1b[28~", .key = T.KEYC_F5 | T.KEYC_SHIFT },
    .{ .string = "\x1b[29~", .key = T.KEYC_F6 | T.KEYC_SHIFT },
    .{ .string = "\x1b[31~", .key = T.KEYC_F7 | T.KEYC_SHIFT },
    .{ .string = "\x1b[32~", .key = T.KEYC_F8 | T.KEYC_SHIFT },
    .{ .string = "\x1b[33~", .key = T.KEYC_F9 | T.KEYC_SHIFT },
    .{ .string = "\x1b[34~", .key = T.KEYC_F10 | T.KEYC_SHIFT },
    .{ .string = "\x1b[23$", .key = T.KEYC_F11 | T.KEYC_SHIFT },
    .{ .string = "\x1b[24$", .key = T.KEYC_F12 | T.KEYC_SHIFT },

    .{ .string = "\x1b[11^", .key = T.KEYC_F1 | T.KEYC_CTRL },
    .{ .string = "\x1b[12^", .key = T.KEYC_F2 | T.KEYC_CTRL },
    .{ .string = "\x1b[13^", .key = T.KEYC_F3 | T.KEYC_CTRL },
    .{ .string = "\x1b[14^", .key = T.KEYC_F4 | T.KEYC_CTRL },
    .{ .string = "\x1b[15^", .key = T.KEYC_F5 | T.KEYC_CTRL },
    .{ .string = "\x1b[17^", .key = T.KEYC_F6 | T.KEYC_CTRL },
    .{ .string = "\x1b[18^", .key = T.KEYC_F7 | T.KEYC_CTRL },
    .{ .string = "\x1b[19^", .key = T.KEYC_F8 | T.KEYC_CTRL },
    .{ .string = "\x1b[20^", .key = T.KEYC_F9 | T.KEYC_CTRL },
    .{ .string = "\x1b[21^", .key = T.KEYC_F10 | T.KEYC_CTRL },
    .{ .string = "\x1b[23^", .key = T.KEYC_F11 | T.KEYC_CTRL },
    .{ .string = "\x1b[24^", .key = T.KEYC_F12 | T.KEYC_CTRL },

    .{ .string = "\x1b[11@", .key = T.KEYC_F1 | T.KEYC_CTRL | T.KEYC_SHIFT },
    .{ .string = "\x1b[12@", .key = T.KEYC_F2 | T.KEYC_CTRL | T.KEYC_SHIFT },
    .{ .string = "\x1b[13@", .key = T.KEYC_F3 | T.KEYC_CTRL | T.KEYC_SHIFT },
    .{ .string = "\x1b[14@", .key = T.KEYC_F4 | T.KEYC_CTRL | T.KEYC_SHIFT },
    .{ .string = "\x1b[15@", .key = T.KEYC_F5 | T.KEYC_CTRL | T.KEYC_SHIFT },
    .{ .string = "\x1b[17@", .key = T.KEYC_F6 | T.KEYC_CTRL | T.KEYC_SHIFT },
    .{ .string = "\x1b[18@", .key = T.KEYC_F7 | T.KEYC_CTRL | T.KEYC_SHIFT },
    .{ .string = "\x1b[19@", .key = T.KEYC_F8 | T.KEYC_CTRL | T.KEYC_SHIFT },
    .{ .string = "\x1b[20@", .key = T.KEYC_F9 | T.KEYC_CTRL | T.KEYC_SHIFT },
    .{ .string = "\x1b[21@", .key = T.KEYC_F10 | T.KEYC_CTRL | T.KEYC_SHIFT },
    .{ .string = "\x1b[23@", .key = T.KEYC_F11 | T.KEYC_CTRL | T.KEYC_SHIFT },
    .{ .string = "\x1b[24@", .key = T.KEYC_F12 | T.KEYC_CTRL | T.KEYC_SHIFT },

    // Focus tracking.
    .{ .string = "\x1b[I", .key = T.KEYC_FOCUS_IN },
    .{ .string = "\x1b[O", .key = T.KEYC_FOCUS_OUT },

    // Paste keys.
    .{ .string = "\x1b[200~", .key = T.KEYC_PASTE_START | T.KEYC_IMPLIED_META },
    .{ .string = "\x1b[201~", .key = T.KEYC_PASTE_END | T.KEYC_IMPLIED_META },

    // Extended keys.
    .{ .string = "\x1b[1;5Z", .key = '\x09' | T.KEYC_CTRL | T.KEYC_SHIFT },

    // Theme reporting.
    .{ .string = "\x1b[?997;1n", .key = T.KEYC_REPORT_DARK_THEME },
    .{ .string = "\x1b[?997;2n", .key = T.KEYC_REPORT_LIGHT_THEME },
};

const tty_default_xterm_keys = [_]DefaultKeyXterm{
    .{ .template = "\x1b[1;_P", .key = T.KEYC_F1 },
    .{ .template = "\x1bO1;_P", .key = T.KEYC_F1 },
    .{ .template = "\x1bO_P", .key = T.KEYC_F1 },
    .{ .template = "\x1b[1;_Q", .key = T.KEYC_F2 },
    .{ .template = "\x1bO1;_Q", .key = T.KEYC_F2 },
    .{ .template = "\x1bO_Q", .key = T.KEYC_F2 },
    .{ .template = "\x1b[1;_R", .key = T.KEYC_F3 },
    .{ .template = "\x1bO1;_R", .key = T.KEYC_F3 },
    .{ .template = "\x1bO_R", .key = T.KEYC_F3 },
    .{ .template = "\x1b[1;_S", .key = T.KEYC_F4 },
    .{ .template = "\x1bO1;_S", .key = T.KEYC_F4 },
    .{ .template = "\x1bO_S", .key = T.KEYC_F4 },
    .{ .template = "\x1b[15;_~", .key = T.KEYC_F5 },
    .{ .template = "\x1b[17;_~", .key = T.KEYC_F6 },
    .{ .template = "\x1b[18;_~", .key = T.KEYC_F7 },
    .{ .template = "\x1b[19;_~", .key = T.KEYC_F8 },
    .{ .template = "\x1b[20;_~", .key = T.KEYC_F9 },
    .{ .template = "\x1b[21;_~", .key = T.KEYC_F10 },
    .{ .template = "\x1b[23;_~", .key = T.KEYC_F11 },
    .{ .template = "\x1b[24;_~", .key = T.KEYC_F12 },
    .{ .template = "\x1b[1;_A", .key = T.KEYC_UP },
    .{ .template = "\x1b[1;_B", .key = T.KEYC_DOWN },
    .{ .template = "\x1b[1;_C", .key = T.KEYC_RIGHT },
    .{ .template = "\x1b[1;_D", .key = T.KEYC_LEFT },
    .{ .template = "\x1b[1;_H", .key = T.KEYC_HOME },
    .{ .template = "\x1b[1;_F", .key = T.KEYC_END },
    .{ .template = "\x1b[5;_~", .key = T.KEYC_PPAGE },
    .{ .template = "\x1b[6;_~", .key = T.KEYC_NPAGE },
    .{ .template = "\x1b[2;_~", .key = T.KEYC_IC },
    .{ .template = "\x1b[3;_~", .key = T.KEYC_DC },
};

// Index 0 and 1 are unused (modifier=0 and modifier=1 are not valid).
const tty_default_xterm_modifiers = [_]T.key_code{
    0,
    0,
    T.KEYC_SHIFT,
    T.KEYC_META | T.KEYC_IMPLIED_META,
    T.KEYC_SHIFT | T.KEYC_META | T.KEYC_IMPLIED_META,
    T.KEYC_CTRL,
    T.KEYC_SHIFT | T.KEYC_CTRL,
    T.KEYC_META | T.KEYC_IMPLIED_META | T.KEYC_CTRL,
    T.KEYC_SHIFT | T.KEYC_META | T.KEYC_IMPLIED_META | T.KEYC_CTRL,
    T.KEYC_META | T.KEYC_IMPLIED_META,
};

const tty_default_code_keys = [_]DefaultKeyCode{
    // Function keys.
    .{ .code = .KF1, .key = T.KEYC_F1 },
    .{ .code = .KF2, .key = T.KEYC_F2 },
    .{ .code = .KF3, .key = T.KEYC_F3 },
    .{ .code = .KF4, .key = T.KEYC_F4 },
    .{ .code = .KF5, .key = T.KEYC_F5 },
    .{ .code = .KF6, .key = T.KEYC_F6 },
    .{ .code = .KF7, .key = T.KEYC_F7 },
    .{ .code = .KF8, .key = T.KEYC_F8 },
    .{ .code = .KF9, .key = T.KEYC_F9 },
    .{ .code = .KF10, .key = T.KEYC_F10 },
    .{ .code = .KF11, .key = T.KEYC_F11 },
    .{ .code = .KF12, .key = T.KEYC_F12 },

    .{ .code = .KF13, .key = T.KEYC_F1 | T.KEYC_SHIFT },
    .{ .code = .KF14, .key = T.KEYC_F2 | T.KEYC_SHIFT },
    .{ .code = .KF15, .key = T.KEYC_F3 | T.KEYC_SHIFT },
    .{ .code = .KF16, .key = T.KEYC_F4 | T.KEYC_SHIFT },
    .{ .code = .KF17, .key = T.KEYC_F5 | T.KEYC_SHIFT },
    .{ .code = .KF18, .key = T.KEYC_F6 | T.KEYC_SHIFT },
    .{ .code = .KF19, .key = T.KEYC_F7 | T.KEYC_SHIFT },
    .{ .code = .KF20, .key = T.KEYC_F8 | T.KEYC_SHIFT },
    .{ .code = .KF21, .key = T.KEYC_F9 | T.KEYC_SHIFT },
    .{ .code = .KF22, .key = T.KEYC_F10 | T.KEYC_SHIFT },
    .{ .code = .KF23, .key = T.KEYC_F11 | T.KEYC_SHIFT },
    .{ .code = .KF24, .key = T.KEYC_F12 | T.KEYC_SHIFT },

    .{ .code = .KF25, .key = T.KEYC_F1 | T.KEYC_CTRL },
    .{ .code = .KF26, .key = T.KEYC_F2 | T.KEYC_CTRL },
    .{ .code = .KF27, .key = T.KEYC_F3 | T.KEYC_CTRL },
    .{ .code = .KF28, .key = T.KEYC_F4 | T.KEYC_CTRL },
    .{ .code = .KF29, .key = T.KEYC_F5 | T.KEYC_CTRL },
    .{ .code = .KF30, .key = T.KEYC_F6 | T.KEYC_CTRL },
    .{ .code = .KF31, .key = T.KEYC_F7 | T.KEYC_CTRL },
    .{ .code = .KF32, .key = T.KEYC_F8 | T.KEYC_CTRL },
    .{ .code = .KF33, .key = T.KEYC_F9 | T.KEYC_CTRL },
    .{ .code = .KF34, .key = T.KEYC_F10 | T.KEYC_CTRL },
    .{ .code = .KF35, .key = T.KEYC_F11 | T.KEYC_CTRL },
    .{ .code = .KF36, .key = T.KEYC_F12 | T.KEYC_CTRL },

    .{ .code = .KF37, .key = T.KEYC_F1 | T.KEYC_SHIFT | T.KEYC_CTRL },
    .{ .code = .KF38, .key = T.KEYC_F2 | T.KEYC_SHIFT | T.KEYC_CTRL },
    .{ .code = .KF39, .key = T.KEYC_F3 | T.KEYC_SHIFT | T.KEYC_CTRL },
    .{ .code = .KF40, .key = T.KEYC_F4 | T.KEYC_SHIFT | T.KEYC_CTRL },
    .{ .code = .KF41, .key = T.KEYC_F5 | T.KEYC_SHIFT | T.KEYC_CTRL },
    .{ .code = .KF42, .key = T.KEYC_F6 | T.KEYC_SHIFT | T.KEYC_CTRL },
    .{ .code = .KF43, .key = T.KEYC_F7 | T.KEYC_SHIFT | T.KEYC_CTRL },
    .{ .code = .KF44, .key = T.KEYC_F8 | T.KEYC_SHIFT | T.KEYC_CTRL },
    .{ .code = .KF45, .key = T.KEYC_F9 | T.KEYC_SHIFT | T.KEYC_CTRL },
    .{ .code = .KF46, .key = T.KEYC_F10 | T.KEYC_SHIFT | T.KEYC_CTRL },
    .{ .code = .KF47, .key = T.KEYC_F11 | T.KEYC_SHIFT | T.KEYC_CTRL },
    .{ .code = .KF48, .key = T.KEYC_F12 | T.KEYC_SHIFT | T.KEYC_CTRL },

    .{ .code = .KF49, .key = T.KEYC_F1 | T.KEYC_META | T.KEYC_IMPLIED_META },
    .{ .code = .KF50, .key = T.KEYC_F2 | T.KEYC_META | T.KEYC_IMPLIED_META },
    .{ .code = .KF51, .key = T.KEYC_F3 | T.KEYC_META | T.KEYC_IMPLIED_META },
    .{ .code = .KF52, .key = T.KEYC_F4 | T.KEYC_META | T.KEYC_IMPLIED_META },
    .{ .code = .KF53, .key = T.KEYC_F5 | T.KEYC_META | T.KEYC_IMPLIED_META },
    .{ .code = .KF54, .key = T.KEYC_F6 | T.KEYC_META | T.KEYC_IMPLIED_META },
    .{ .code = .KF55, .key = T.KEYC_F7 | T.KEYC_META | T.KEYC_IMPLIED_META },
    .{ .code = .KF56, .key = T.KEYC_F8 | T.KEYC_META | T.KEYC_IMPLIED_META },
    .{ .code = .KF57, .key = T.KEYC_F9 | T.KEYC_META | T.KEYC_IMPLIED_META },
    .{ .code = .KF58, .key = T.KEYC_F10 | T.KEYC_META | T.KEYC_IMPLIED_META },
    .{ .code = .KF59, .key = T.KEYC_F11 | T.KEYC_META | T.KEYC_IMPLIED_META },
    .{ .code = .KF60, .key = T.KEYC_F12 | T.KEYC_META | T.KEYC_IMPLIED_META },

    .{ .code = .KF61, .key = T.KEYC_F1 | T.KEYC_META | T.KEYC_IMPLIED_META | T.KEYC_SHIFT },
    .{ .code = .KF62, .key = T.KEYC_F2 | T.KEYC_META | T.KEYC_IMPLIED_META | T.KEYC_SHIFT },
    .{ .code = .KF63, .key = T.KEYC_F3 | T.KEYC_META | T.KEYC_IMPLIED_META | T.KEYC_SHIFT },

    .{ .code = .KICH1, .key = T.KEYC_IC },
    .{ .code = .KDCH1, .key = T.KEYC_DC },
    .{ .code = .KHOME, .key = T.KEYC_HOME },
    .{ .code = .KEND, .key = T.KEYC_END },
    .{ .code = .KNP, .key = T.KEYC_NPAGE },
    .{ .code = .KPP, .key = T.KEYC_PPAGE },
    .{ .code = .KCBT, .key = T.KEYC_BTAB },

    // Arrow keys from terminfo.
    .{ .code = .KCUU1, .key = T.KEYC_UP | T.KEYC_CURSOR },
    .{ .code = .KCUD1, .key = T.KEYC_DOWN | T.KEYC_CURSOR },
    .{ .code = .KCUB1, .key = T.KEYC_LEFT | T.KEYC_CURSOR },
    .{ .code = .KCUF1, .key = T.KEYC_RIGHT | T.KEYC_CURSOR },

    // Key and modifier capabilities.
    .{ .code = .KDC2, .key = T.KEYC_DC | T.KEYC_SHIFT },
    .{ .code = .KDC3, .key = T.KEYC_DC | T.KEYC_META | T.KEYC_IMPLIED_META },
    .{ .code = .KDC4, .key = T.KEYC_DC | T.KEYC_SHIFT | T.KEYC_META | T.KEYC_IMPLIED_META },
    .{ .code = .KDC5, .key = T.KEYC_DC | T.KEYC_CTRL },
    .{ .code = .KDC6, .key = T.KEYC_DC | T.KEYC_SHIFT | T.KEYC_CTRL },
    .{ .code = .KDC7, .key = T.KEYC_DC | T.KEYC_META | T.KEYC_IMPLIED_META | T.KEYC_CTRL },
    .{ .code = .KIND, .key = T.KEYC_DOWN | T.KEYC_SHIFT },
    .{ .code = .KDN2, .key = T.KEYC_DOWN | T.KEYC_SHIFT },
    .{ .code = .KDN3, .key = T.KEYC_DOWN | T.KEYC_META | T.KEYC_IMPLIED_META },
    .{ .code = .KDN4, .key = T.KEYC_DOWN | T.KEYC_SHIFT | T.KEYC_META | T.KEYC_IMPLIED_META },
    .{ .code = .KDN5, .key = T.KEYC_DOWN | T.KEYC_CTRL },
    .{ .code = .KDN6, .key = T.KEYC_DOWN | T.KEYC_SHIFT | T.KEYC_CTRL },
    .{ .code = .KDN7, .key = T.KEYC_DOWN | T.KEYC_META | T.KEYC_IMPLIED_META | T.KEYC_CTRL },
    .{ .code = .KEND2, .key = T.KEYC_END | T.KEYC_SHIFT },
    .{ .code = .KEND3, .key = T.KEYC_END | T.KEYC_META | T.KEYC_IMPLIED_META },
    .{ .code = .KEND4, .key = T.KEYC_END | T.KEYC_SHIFT | T.KEYC_META | T.KEYC_IMPLIED_META },
    .{ .code = .KEND5, .key = T.KEYC_END | T.KEYC_CTRL },
    .{ .code = .KEND6, .key = T.KEYC_END | T.KEYC_SHIFT | T.KEYC_CTRL },
    .{ .code = .KEND7, .key = T.KEYC_END | T.KEYC_META | T.KEYC_IMPLIED_META | T.KEYC_CTRL },
    .{ .code = .KHOM2, .key = T.KEYC_HOME | T.KEYC_SHIFT },
    .{ .code = .KHOM3, .key = T.KEYC_HOME | T.KEYC_META | T.KEYC_IMPLIED_META },
    .{ .code = .KHOM4, .key = T.KEYC_HOME | T.KEYC_SHIFT | T.KEYC_META | T.KEYC_IMPLIED_META },
    .{ .code = .KHOM5, .key = T.KEYC_HOME | T.KEYC_CTRL },
    .{ .code = .KHOM6, .key = T.KEYC_HOME | T.KEYC_SHIFT | T.KEYC_CTRL },
    .{ .code = .KHOM7, .key = T.KEYC_HOME | T.KEYC_META | T.KEYC_IMPLIED_META | T.KEYC_CTRL },
    .{ .code = .KIC2, .key = T.KEYC_IC | T.KEYC_SHIFT },
    .{ .code = .KIC3, .key = T.KEYC_IC | T.KEYC_META | T.KEYC_IMPLIED_META },
    .{ .code = .KIC4, .key = T.KEYC_IC | T.KEYC_SHIFT | T.KEYC_META | T.KEYC_IMPLIED_META },
    .{ .code = .KIC5, .key = T.KEYC_IC | T.KEYC_CTRL },
    .{ .code = .KIC6, .key = T.KEYC_IC | T.KEYC_SHIFT | T.KEYC_CTRL },
    .{ .code = .KIC7, .key = T.KEYC_IC | T.KEYC_META | T.KEYC_IMPLIED_META | T.KEYC_CTRL },
    .{ .code = .KLFT2, .key = T.KEYC_LEFT | T.KEYC_SHIFT },
    .{ .code = .KLFT3, .key = T.KEYC_LEFT | T.KEYC_META | T.KEYC_IMPLIED_META },
    .{ .code = .KLFT4, .key = T.KEYC_LEFT | T.KEYC_SHIFT | T.KEYC_META | T.KEYC_IMPLIED_META },
    .{ .code = .KLFT5, .key = T.KEYC_LEFT | T.KEYC_CTRL },
    .{ .code = .KLFT6, .key = T.KEYC_LEFT | T.KEYC_SHIFT | T.KEYC_CTRL },
    .{ .code = .KLFT7, .key = T.KEYC_LEFT | T.KEYC_META | T.KEYC_IMPLIED_META | T.KEYC_CTRL },
    .{ .code = .KNXT2, .key = T.KEYC_NPAGE | T.KEYC_SHIFT },
    .{ .code = .KNXT3, .key = T.KEYC_NPAGE | T.KEYC_META | T.KEYC_IMPLIED_META },
    .{ .code = .KNXT4, .key = T.KEYC_NPAGE | T.KEYC_SHIFT | T.KEYC_META | T.KEYC_IMPLIED_META },
    .{ .code = .KNXT5, .key = T.KEYC_NPAGE | T.KEYC_CTRL },
    .{ .code = .KNXT6, .key = T.KEYC_NPAGE | T.KEYC_SHIFT | T.KEYC_CTRL },
    .{ .code = .KNXT7, .key = T.KEYC_NPAGE | T.KEYC_META | T.KEYC_IMPLIED_META | T.KEYC_CTRL },
    .{ .code = .KPRV2, .key = T.KEYC_PPAGE | T.KEYC_SHIFT },
    .{ .code = .KPRV3, .key = T.KEYC_PPAGE | T.KEYC_META | T.KEYC_IMPLIED_META },
    .{ .code = .KPRV4, .key = T.KEYC_PPAGE | T.KEYC_SHIFT | T.KEYC_META | T.KEYC_IMPLIED_META },
    .{ .code = .KPRV5, .key = T.KEYC_PPAGE | T.KEYC_CTRL },
    .{ .code = .KPRV6, .key = T.KEYC_PPAGE | T.KEYC_SHIFT | T.KEYC_CTRL },
    .{ .code = .KPRV7, .key = T.KEYC_PPAGE | T.KEYC_META | T.KEYC_IMPLIED_META | T.KEYC_CTRL },
    .{ .code = .KRIT2, .key = T.KEYC_RIGHT | T.KEYC_SHIFT },
    .{ .code = .KRIT3, .key = T.KEYC_RIGHT | T.KEYC_META | T.KEYC_IMPLIED_META },
    .{ .code = .KRIT4, .key = T.KEYC_RIGHT | T.KEYC_SHIFT | T.KEYC_META | T.KEYC_IMPLIED_META },
    .{ .code = .KRIT5, .key = T.KEYC_RIGHT | T.KEYC_CTRL },
    .{ .code = .KRIT6, .key = T.KEYC_RIGHT | T.KEYC_SHIFT | T.KEYC_CTRL },
    .{ .code = .KRIT7, .key = T.KEYC_RIGHT | T.KEYC_META | T.KEYC_IMPLIED_META | T.KEYC_CTRL },
    .{ .code = .KRI, .key = T.KEYC_UP | T.KEYC_SHIFT },
    .{ .code = .KUP2, .key = T.KEYC_UP | T.KEYC_SHIFT },
    .{ .code = .KUP3, .key = T.KEYC_UP | T.KEYC_META | T.KEYC_IMPLIED_META },
    .{ .code = .KUP4, .key = T.KEYC_UP | T.KEYC_SHIFT | T.KEYC_META | T.KEYC_IMPLIED_META },
    .{ .code = .KUP5, .key = T.KEYC_UP | T.KEYC_CTRL },
    .{ .code = .KUP6, .key = T.KEYC_UP | T.KEYC_SHIFT | T.KEYC_CTRL },
    .{ .code = .KUP7, .key = T.KEYC_UP | T.KEYC_META | T.KEYC_IMPLIED_META | T.KEYC_CTRL },
};

// ── TST operations ─────────────────────────────────────────────────────────

/// Add node at (or below) `*tkp` for the escape sequence `s` → `key`.
fn tty_keys_add1(tkp: *?*TtyKey, s: []const u8, key: T.key_code) void {
    if (s.len == 0) return;

    var tk = tkp.*;
    if (tk == null) {
        tk = xm.allocator.create(TtyKey) catch unreachable;
        tk.?.* = .{ .ch = s[0], .key = T.KEYC_UNKNOWN };
        tkp.* = tk;
    }

    const node = tk.?;
    if (s[0] == node.ch) {
        // Matched – advance to next character.
        if (s.len == 1) {
            node.key = key;
            return;
        }
        tty_keys_add1(&node.next, s[1..], key);
    } else if (s[0] < node.ch) {
        tty_keys_add1(&node.left, s, key);
    } else {
        tty_keys_add1(&node.right, s, key);
    }
}

/// Insert key sequence `s` into the tty's key tree, replacing any existing
/// binding for the same sequence.
pub fn tty_keys_add(key_tree: *?*TtyKey, s: []const u8, key: T.key_code) void {
    if (s.len == 0) return;
    var size: usize = 0;
    const existing = tty_keys_find(key_tree.*, s, &size);
    if (existing != null and existing.?.key != T.KEYC_UNKNOWN) {
        existing.?.key = key;
    } else {
        tty_keys_add1(key_tree, s, key);
    }
}

/// Free the entire TST rooted at `tk`.
fn tty_keys_free1(tk: *TtyKey) void {
    if (tk.next) |next| tty_keys_free1(next);
    if (tk.left) |left| tty_keys_free1(left);
    if (tk.right) |right| tty_keys_free1(right);
    xm.allocator.destroy(tk);
}

/// Recursive find: walk the TST from `tk` matching `buf`; on success returns
/// the terminating node.  `size` accumulates bytes consumed.
fn tty_keys_find1(tk: ?*TtyKey, buf: []const u8, size: *usize) ?*TtyKey {
    if (buf.len == 0) return null;
    const node = tk orelse return null;

    if (buf[0] == node.ch) {
        size.* += 1;
        // At end of input, or no deeper node and we have a valid key: done.
        if (buf.len == 1 or (node.next == null and node.key != T.KEYC_UNKNOWN))
            return node;
        return tty_keys_find1(node.next, buf[1..], size);
    } else if (buf[0] < node.ch) {
        return tty_keys_find1(node.left, buf, size);
    } else {
        return tty_keys_find1(node.right, buf, size);
    }
}

/// Find the longest matching prefix of `buf` in the tree.  Returns null if
/// there is no match.
pub fn tty_keys_find(root: ?*TtyKey, buf: []const u8, size: *usize) ?*TtyKey {
    size.* = 0;
    return tty_keys_find1(root, buf, size);
}

// ── Tree construction ──────────────────────────────────────────────────────

/// Build (or rebuild) the key lookup tree for `tty` from the default tables
/// plus terminfo strings.
///
/// `term` may be null (e.g. in unit tests where terminfo is not available).
pub fn tty_keys_build(key_tree: *?*TtyKey, term: ?*const tty_term_mod.TtyTerm) void {
    if (key_tree.*) |root| {
        tty_keys_free1(root);
    }
    key_tree.* = null;

    // 1. xterm modifier sequences (modifiers 2..9).
    for (tty_default_xterm_keys) |tdkx| {
        var j: usize = 2;
        while (j < tty_default_xterm_modifiers.len) : (j += 1) {
            var copy: [16]u8 = undefined;
            const tlen = tdkx.template.len;
            if (tlen >= copy.len) continue;
            @memcpy(copy[0..tlen], tdkx.template);

            // Replace '_' with the modifier digit.
            var idx: usize = 0;
            while (idx < tlen) : (idx += 1) {
                if (copy[idx] == '_') {
                    copy[idx] = @as(u8, @intCast('0' + j));
                    break;
                }
            }

            const key = tdkx.key | tty_default_xterm_modifiers[j];
            tty_keys_add(key_tree, copy[0..tlen], key);
        }
    }

    // 2. Raw (hardcoded) key sequences.
    for (tty_default_raw_keys) |tdkr| {
        if (tdkr.string.len > 0)
            tty_keys_add(key_tree, tdkr.string, tdkr.key);
    }

    // 3. Terminfo-derived keys.
    if (term) |t| {
        for (tty_default_code_keys) |tdkc| {
            const s = tty_term_mod.tty_term_string(t, tdkc.code);
            if (s.len > 0)
                tty_keys_add(key_tree, s, tdkc.key);
        }
    }
}

/// Free the key tree.
pub fn tty_keys_free(key_tree: *?*TtyKey) void {
    if (key_tree.*) |root| {
        tty_keys_free1(root);
    }
    key_tree.* = null;
}

// ── Return values for parser sub-functions ─────────────────────────────────

/// Result of tty_keys_next1 and helper parsers.
/// Mirrors C conventions: 0=match, 1=partial, -1=no-match.
pub const ParseResult = enum(i32) {
    match = 0,
    partial = 1,
    no_match = -1,
    discard = -2,
};

// ── Low-level key lookup (tty_keys_next1) ─────────────────────────────────

/// Attempt to consume at least one key from `buf`.
/// Returns:
///   .match   – `key` and `size` set; caller removes `size` bytes.
///   .partial – sequence is a valid prefix; wait for more data (or timer).
///   .no_match – not a known sequence; caller falls through to UTF-8 / raw.
///
/// `expired` should be true when the ambiguity timer has fired – in that case
/// partial matches are not returned and the first byte is treated as the key.
pub fn tty_keys_next1(
    root: ?*TtyKey,
    buf: []const u8,
    key: *T.key_code,
    size: *usize,
    expired: bool,
) ParseResult {
    const tk = tty_keys_find(root, buf, size);

    if (tk != null and tk.?.key != T.KEYC_UNKNOWN) {
        // Found a complete key.
        if (tk.?.next != null and !expired) {
            // There is a longer sequence that starts the same way; wait.
            return .partial;
        }
        key.* = tk.?.key;
        return .match;
    }

    // Try UTF-8 fallback.
    var ud: T.Utf8Data = undefined;
    const state = utf8_mod.utf8_open(&ud, buf[0]);
    if (state == .more) {
        size.* = ud.size;
        if (buf.len < ud.size) {
            if (!expired) return .partial;
            return .no_match;
        }
        var i: usize = 1;
        var cur_state = state;
        while (i < ud.size) : (i += 1) {
            cur_state = utf8_mod.utf8_append(&ud, buf[i]);
        }
        if (cur_state != .done) return .no_match;

        var uc: T.utf8_char = 0;
        if (utf8_mod.utf8_from_data(&ud, &uc) != .done) return .no_match;
        key.* = uc;
        return .match;
    }

    return .no_match;
}

// ── Extended key parsing (CSI u / modifyOtherKeys) ─────────────────────────

/// Parse CSI u or CSI 27;m;k~ (xterm modifyOtherKeys) sequences.
///
/// Returns .match (key/size set), .partial, or .no_match.
pub fn tty_keys_extended_key(
    buf: []const u8,
    size: *usize,
    key: *T.key_code,
    verase: ?u8,
) ParseResult {
    size.* = 0;

    if (buf.len < 1 or buf[0] != '\x1b') return .no_match;
    if (buf.len == 1) return .partial;
    if (buf[1] != '[') return .no_match;
    if (buf.len == 2) return .partial;

    // Scan until terminator: '~' or 'u', anything else that isn't digit/'}'.
    const TMP_MAX = 64;
    var end: usize = 2;
    while (end < buf.len and end < TMP_MAX) : (end += 1) {
        if (buf[end] == '~') break;
        if (!std.ascii.isDigit(buf[end]) and buf[end] != ';') break;
    }
    if (end == buf.len) return .partial;
    if (end >= TMP_MAX) return .no_match;
    if (buf[end] != '~' and buf[end] != 'u') return .no_match;

    // Parse the numeric part.
    const tmp = buf[2..end];
    var number: u32 = 0;
    var modifiers: u32 = 0;

    if (buf[end] == '~') {
        // CSI 27;modifiers;key~
        if (!parseTwoUints(tmp, &modifiers, &number, ';', ';')) return .no_match;
        if (!std.mem.startsWith(u8, buf[2..], "27;")) return .no_match;
        // Re-parse: format is "27;modifiers;key"
        var it = std.mem.splitScalar(u8, tmp, ';');
        const p0s = it.next() orelse return .no_match;
        const p1s = it.next() orelse return .no_match;
        const p2s = it.next() orelse return .no_match;
        if (!std.mem.eql(u8, p0s, "27")) return .no_match;
        modifiers = std.fmt.parseInt(u32, p1s, 10) catch return .no_match;
        number = std.fmt.parseInt(u32, p2s, 10) catch return .no_match;
    } else {
        // CSI key;modifiers u
        var it = std.mem.splitScalar(u8, tmp, ';');
        const p0s = it.next() orelse return .no_match;
        const p1s = it.next() orelse return .no_match;
        number = std.fmt.parseInt(u32, p0s, 10) catch return .no_match;
        modifiers = std.fmt.parseInt(u32, p1s, 10) catch return .no_match;
    }

    size.* = end + 1;

    // Resolve the key code.
    var nkey: T.key_code = blk: {
        if (verase) |bsp| {
            if (number == bsp) break :blk T.KEYC_BSPACE;
        }
        break :blk @as(T.key_code, number);
    };

    // Convert wide codepoints (> 0x7f) to internal utf8_char representation.
    if (nkey != T.KEYC_BSPACE and (nkey & ~@as(T.key_code, 0x7f)) != 0) {
        const c = @import("c.zig");
        var ud: T.Utf8Data = undefined;
        if (utf8_mod.utf8_fromwc(@as(c.posix_sys.wchar_t, @intCast(number)), &ud) == .done) {
            var uc: T.utf8_char = 0;
            if (utf8_mod.utf8_from_data(&ud, &uc) == .done) {
                nkey = uc;
            } else {
                return .no_match;
            }
        } else {
            return .no_match;
        }
    }

    // Apply modifiers (xterm convention: modifier param - 1, bitmask).
    if (modifiers > 0) {
        modifiers -= 1;
        if (modifiers & 1 != 0) nkey |= T.KEYC_SHIFT;
        if (modifiers & 2 != 0) nkey |= T.KEYC_META | T.KEYC_IMPLIED_META;
        if (modifiers & 4 != 0) nkey |= T.KEYC_CTRL;
        if (modifiers & 8 != 0) nkey |= T.KEYC_META | T.KEYC_IMPLIED_META;
    }

    // S-Tab → Backtab.
    if ((nkey & T.KEYC_MASK_KEY) == '\x09' and (nkey & T.KEYC_SHIFT) != 0)
        nkey = T.KEYC_BTAB | (nkey & ~T.KEYC_MASK_KEY & ~T.KEYC_SHIFT);

    // Drop Shift alone for printable characters (see tmux comment in source).
    const onlykey = nkey & T.KEYC_MASK_KEY;
    if (((onlykey > 0x20 and onlykey < 0x7f) or T.keycIsUnicode(nkey)) and
        (nkey & T.KEYC_MASK_MODIFIERS) == T.KEYC_SHIFT)
    {
        nkey &= ~T.KEYC_SHIFT;
    }

    key.* = nkey;
    return .match;
}

/// Helper: parse two semicolon-separated unsigned integers from `s`.
fn parseTwoUints(s: []const u8, a: *u32, b: *u32, sep_a: u8, sep_b: u8) bool {
    _ = sep_a;
    _ = sep_b;
    var it = std.mem.splitScalar(u8, s, ';');
    const as = it.next() orelse return false;
    const bs = it.next() orelse return false;
    a.* = std.fmt.parseInt(u32, as, 10) catch return false;
    b.* = std.fmt.parseInt(u32, bs, 10) catch return false;
    return true;
}

// ── Mouse protocol parsing ─────────────────────────────────────────────────

/// Mouse parse result, parallel to C's tty_keys_mouse return conventions.
pub const MouseParseResult = struct {
    result: ParseResult,
    m: T.MouseEvent = .{},
};

/// Parse a mouse event from `buf`.  Updates `tty_mouse_last_*` state if a
/// valid event is decoded.  Returns .match (with `m` populated), .partial,
/// .no_match, or .discard.
pub fn tty_keys_mouse(
    buf: []const u8,
    size: *usize,
    mouse_last_x: *u32,
    mouse_last_y: *u32,
    mouse_last_b: *u32,
) MouseParseResult {
    size.* = 0;

    if (buf.len < 1 or buf[0] != '\x1b') return .{ .result = .no_match };
    if (buf.len == 1) return .{ .result = .partial };
    if (buf[1] != '[') return .{ .result = .no_match };
    if (buf.len == 2) return .{ .result = .partial };

    var x: u32 = 0;
    var y: u32 = 0;
    var b: u32 = 0;
    var sgr_b: u32 = 0;
    var sgr_type: u8 = ' ';

    if (buf[2] == 'M') {
        // X10 / standard mouse: \033[M followed by three raw bytes.
        size.* = 3;
        var i: usize = 0;
        while (i < 3) : (i += 1) {
            if (buf.len <= size.*) return .{ .result = .partial };
            const ch: u8 = buf[size.*];
            size.* += 1;
            if (i == 0) {
                b = ch;
            } else if (i == 1) {
                x = ch;
            } else {
                y = ch;
            }
        }

        if (b < MOUSE_PARAM_BTN_OFF or x < MOUSE_PARAM_POS_OFF or y < MOUSE_PARAM_POS_OFF)
            return .{ .result = .discard };

        b -= MOUSE_PARAM_BTN_OFF;
        x -= MOUSE_PARAM_POS_OFF;
        y -= MOUSE_PARAM_POS_OFF;
    } else if (buf[2] == '<') {
        // SGR extended mouse: \033[<b;x;yM or \033[<b;x;ym
        size.* = 3;

        // Read sgr_b.
        while (true) {
            if (buf.len <= size.*) return .{ .result = .partial };
            const ch: u8 = buf[size.*];
            size.* += 1;
            if (ch == ';') break;
            if (ch < '0' or ch > '9') return .{ .result = .no_match };
            sgr_b = 10 * sgr_b + (ch - '0');
        }
        // Read x.
        while (true) {
            if (buf.len <= size.*) return .{ .result = .partial };
            const ch: u8 = buf[size.*];
            size.* += 1;
            if (ch == ';') break;
            if (ch < '0' or ch > '9') return .{ .result = .no_match };
            x = 10 * x + (ch - '0');
        }
        // Read y + final terminator.
        var final_ch: u8 = ' ';
        while (true) {
            if (buf.len <= size.*) return .{ .result = .partial };
            const ch: u8 = buf[size.*];
            size.* += 1;
            if (ch == 'M' or ch == 'm') {
                final_ch = ch;
                break;
            }
            if (ch < '0' or ch > '9') return .{ .result = .no_match };
            y = 10 * y + (ch - '0');
        }

        if (x < 1 or y < 1) return .{ .result = .discard };
        x -= 1;
        y -= 1;
        b = sgr_b;
        sgr_type = final_ch;

        if (sgr_type == 'm') b = 3;

        // Discard spurious release events for scroll wheels (PuTTY bug).
        if (sgr_type == 'm' and T.mouseWheel(sgr_b))
            return .{ .result = .discard };
    } else {
        return .{ .result = .no_match };
    }

    const m = T.MouseEvent{
        .lx = mouse_last_x.*,
        .x = x,
        .ly = mouse_last_y.*,
        .y = y,
        .lb = mouse_last_b.*,
        .b = b,
        .sgr_type = sgr_type,
        .sgr_b = sgr_b,
    };

    mouse_last_x.* = x;
    mouse_last_y.* = y;
    mouse_last_b.* = b;

    return .{ .result = .match, .m = m };
}

// ── Clipboard / OSC 52 parsing ─────────────────────────────────────────────

/// Parse an OSC 52 clipboard response from `buf`.
///
/// Returns .match (size consumed), .partial, or .no_match.
/// `out_data` is set to the decoded base64 payload (caller owns; may be null
/// if nothing to decode).  `out_clip` is the clipboard character.
pub fn tty_keys_clipboard(
    buf: []const u8,
    size: *usize,
    out_clip: *u8,
    out_data: *?[]u8,
) ParseResult {
    size.* = 0;
    out_data.* = null;
    out_clip.* = 0;

    // First five bytes must be \033]52;
    if (buf.len < 1 or buf[0] != '\x1b') return .no_match;
    if (buf.len == 1) return .partial;
    if (buf[1] != ']') return .no_match;
    if (buf.len == 2) return .partial;
    if (buf[2] != '5') return .no_match;
    if (buf.len == 3) return .partial;
    if (buf[3] != '2') return .no_match;
    if (buf.len == 4) return .partial;
    if (buf[4] != ';') return .no_match;
    if (buf.len == 5) return .partial;

    // Find terminator: BEL (0x07) or ST (ESC \).
    var end: usize = 5;
    var terminator: usize = 0;
    while (end < buf.len) : (end += 1) {
        if (buf[end] == '\x07') {
            terminator = 1;
            break;
        }
        if (end > 5 and buf[end - 1] == '\x1b' and buf[end] == '\\') {
            terminator = 2;
            break;
        }
    }
    if (end == buf.len) return .partial;
    size.* = end + 1;

    // Remaining payload (after "\033]52;").
    const payload = buf[5..];
    var payload_end: usize = end - 5;
    payload_end -= terminator - 1;

    // Extract clipboard char from first argument.
    if (payload_end >= 2 and payload[0] != ';' and payload[1] == ';')
        out_clip.* = payload[0];

    // Skip past first argument separator.
    var pos: usize = 0;
    while (pos < payload_end and payload[pos] != ';') pos += 1;
    if (pos == payload_end or pos + 1 > payload_end) return .match;
    pos += 1; // skip ';'

    const b64_slice = payload[pos..payload_end];
    if (b64_slice.len == 0) return .match;

    // Decode base64.
    const needed = (b64_slice.len / 4) * 3 + 4;
    const out = xm.allocator.alloc(u8, needed) catch return .match;
    const decoded_len = decodeBase64(b64_slice, out) catch {
        xm.allocator.free(out);
        return .match;
    };
    if (decoded_len == 0) {
        xm.allocator.free(out);
        return .match;
    }
    out_data.* = xm.allocator.realloc(out, decoded_len) catch out[0..decoded_len];
    return .match;
}

/// Minimal base64 decoder.  Returns number of bytes written, error on invalid.
fn decodeBase64(src: []const u8, dst: []u8) !usize {
    const alpha = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    var dst_idx: usize = 0;
    var src_idx: usize = 0;

    while (src_idx + 3 < src.len) {
        const c0 = lookupB64(alpha, src[src_idx]) orelse return error.InvalidBase64;
        const c1 = lookupB64(alpha, src[src_idx + 1]) orelse return error.InvalidBase64;
        const c2 = if (src[src_idx + 2] == '=') @as(u8, 0) else (lookupB64(alpha, src[src_idx + 2]) orelse return error.InvalidBase64);
        const c3 = if (src[src_idx + 3] == '=') @as(u8, 0) else (lookupB64(alpha, src[src_idx + 3]) orelse return error.InvalidBase64);

        if (dst_idx >= dst.len) return error.OutputTooSmall;
        dst[dst_idx] = (c0 << 2) | (c1 >> 4);
        dst_idx += 1;
        if (src[src_idx + 2] != '=') {
            if (dst_idx >= dst.len) return error.OutputTooSmall;
            dst[dst_idx] = (c1 << 4) | (c2 >> 2);
            dst_idx += 1;
        }
        if (src[src_idx + 3] != '=') {
            if (dst_idx >= dst.len) return error.OutputTooSmall;
            dst[dst_idx] = (c2 << 6) | c3;
            dst_idx += 1;
        }
        src_idx += 4;
    }
    return dst_idx;
}

fn lookupB64(alpha: []const u8, c: u8) ?u8 {
    for (alpha, 0..) |ch, i| {
        if (ch == c) return @as(u8, @intCast(i));
    }
    return null;
}

fn matchPrefix(buf: []const u8, prefix: []const u8) ParseResult {
    for (prefix, 0..) |ch, i| {
        if (buf.len == i) return .partial;
        if (buf[i] != ch) return .no_match;
    }
    return .match;
}

fn parseDeviceAttributes(
    buf: []const u8,
    prefix_last: u8,
    size: *usize,
    params_out: []u32,
    n_out: *usize,
) ParseResult {
    const prefix = [3]u8{ '\x1b', '[', prefix_last };

    size.* = 0;
    n_out.* = 0;

    switch (matchPrefix(buf, &prefix)) {
        .match => {},
        .partial => return .partial,
        .no_match, .discard => return .no_match,
    }

    const max_params_len = 128;
    var params_len: usize = 0;
    while (params_len < max_params_len) : (params_len += 1) {
        const idx = prefix.len + params_len;
        if (idx == buf.len) return .partial;
        if (buf[idx] >= 'a' and buf[idx] <= 'z') break;
    }
    if (params_len == max_params_len or buf[prefix.len + params_len] != 'c') return .no_match;

    size.* = prefix.len + params_len + 1;

    var it = std.mem.splitScalar(u8, buf[prefix.len .. prefix.len + params_len], ';');
    var n: usize = 0;
    while (it.next()) |tok| {
        if (n >= params_out.len) break;
        params_out[n] = std.fmt.parseInt(u32, tok, 10) catch 0;
        n += 1;
    }
    n_out.* = n;
    return .match;
}

const PayloadTerminator = enum {
    st_only,
    st_or_bel,
};

fn copyTerminatedPayload(
    buf: []const u8,
    prefix: []const u8,
    size: *usize,
    tmp_out: []u8,
    terminator: PayloadTerminator,
) ParseResult {
    size.* = 0;

    switch (matchPrefix(buf, prefix)) {
        .match => {},
        .partial => return .partial,
        .no_match, .discard => return .no_match,
    }

    var i: usize = 0;
    while (i < tmp_out.len - 1) : (i += 1) {
        const idx = prefix.len + i;
        if (idx == buf.len) return .partial;
        if (i > 0 and buf[idx - 1] == '\x1b' and buf[idx] == '\\') break;
        if (terminator == .st_or_bel and buf[idx] == '\x07') break;
        tmp_out[i] = buf[idx];
    }
    if (i == tmp_out.len - 1) return .no_match;

    size.* = prefix.len + i + 1;
    if (i == 0) {
        tmp_out[0] = 0;
        return .match;
    }
    if (tmp_out[i - 1] == '\x1b')
        tmp_out[i - 1] = 0
    else
        tmp_out[i] = 0;
    return .match;
}

// ── DA1 / DA2 / XDA / XTVERSION / window-size parsers (stubs) ──────────────

/// Parse a primary device attributes response: \033[?...c
/// Returns .match (size set), .partial, or .no_match.
///
/// The C version calls tty_update_features to set terminal feature flags.
/// TODO: wire to tty_update_features when that is available.
pub fn tty_keys_device_attributes(
    buf: []const u8,
    size: *usize,
    have_da: bool,
    params_out: []u32,
    n_out: *usize,
) ParseResult {
    if (have_da) return .no_match;
    return parseDeviceAttributes(buf, '?', size, params_out, n_out);
}

/// Parse a secondary device attributes response: \033[>...c
/// Returns .match (size set), .partial, or .no_match.
///
/// TODO: wire to tty_update_features when available.
pub fn tty_keys_device_attributes2(
    buf: []const u8,
    size: *usize,
    have_da2: bool,
    params_out: []u32,
    n_out: *usize,
) ParseResult {
    if (have_da2) return .no_match;
    return parseDeviceAttributes(buf, '>', size, params_out, n_out);
}

/// Parse an extended device attributes response (XDA): \033P>|...\033\\
/// Returns .match (size set), .partial, or .no_match.
///
/// The payload string is written into `tmp_out` (null-terminated).
/// TODO: wire feature detection to tty_update_features.
pub fn tty_keys_extended_device_attributes(
    buf: []const u8,
    size: *usize,
    have_xda: bool,
    tmp_out: []u8,
) ParseResult {
    if (have_xda) return .no_match;
    return copyTerminatedPayload(buf, "\x1bP>|", size, tmp_out, .st_only);
}

/// Parse a window size report: \033[8;sy;sxt or \033[4;ypixel;xpixelt
/// Returns .match (size and out_sx/out_sy set), .partial, or .no_match.
pub const WinszKind = enum { chars, pixels };

pub const WinszResult = struct {
    kind: WinszKind,
    v1: u32,
    v2: u32,
};

pub fn tty_keys_winsz(
    buf: []const u8,
    size: *usize,
) ?WinszResult {
    size.* = 0;

    if (buf.len < 1 or buf[0] != '\x1b') return null;
    if (buf.len == 1) return null; // partial – but we return null for simplicity
    if (buf[1] != '[') return null;
    if (buf.len == 2) return null;

    const TMP_MAX = 64;
    var end: usize = 2;
    while (end < buf.len and end < TMP_MAX) : (end += 1) {
        if (buf[end] == 't') break;
        if (!std.ascii.isDigit(buf[end]) and buf[end] != ';') break;
    }
    if (end == buf.len) return null;
    if (end >= TMP_MAX or buf[end] != 't') return null;

    size.* = end + 1;
    const tmp = buf[2..end];

    // \033[8;sy;sxt – window size in characters.
    if (std.mem.startsWith(u8, tmp, "8;")) {
        var it = std.mem.splitScalar(u8, tmp[2..], ';');
        const sys = it.next() orelse return null;
        const sxs = it.next() orelse return null;
        const sy = std.fmt.parseInt(u32, sys, 10) catch return null;
        const sx = std.fmt.parseInt(u32, sxs, 10) catch return null;
        return .{ .kind = .chars, .v1 = sx, .v2 = sy };
    }

    // \033[4;ypixel;xpixelt – window size in pixels.
    if (std.mem.startsWith(u8, tmp, "4;")) {
        var it = std.mem.splitScalar(u8, tmp[2..], ';');
        const yps = it.next() orelse return null;
        const xps = it.next() orelse return null;
        const ypixel = std.fmt.parseInt(u32, yps, 10) catch return null;
        const xpixel = std.fmt.parseInt(u32, xps, 10) catch return null;
        return .{ .kind = .pixels, .v1 = xpixel, .v2 = ypixel };
    }

    return null;
}

/// Parse a foreground/background colour response: \033]10;rgb:rr/gg/bb\033\\ or BEL.
/// If `is_fg` is true, parses OSC 10 (fg); else OSC 11 (bg).
/// Returns .match (size set, colour written to `out_colour`), .partial, .no_match.
///
/// TODO: wire colour_parseX11 when available.
pub fn tty_keys_colours(
    buf: []const u8,
    size: *usize,
    is_fg: bool,
    tmp_out: []u8,
) ParseResult {
    return copyTerminatedPayload(buf, if (is_fg) "\x1b]10;" else "\x1b]11;", size, tmp_out, .st_or_bel);
}

/// Parse an OSC 4 palette colour response: \033]4;idx;rgb:...\033\\ or BEL.
/// Returns .match (size set), .partial, or .no_match.
///
/// TODO: wire colour_parseX11 when available.
pub fn tty_keys_palette(
    buf: []const u8,
    size: *usize,
    tmp_out: []u8,
) ParseResult {
    return copyTerminatedPayload(buf, "\x1b]4;", size, tmp_out, .st_or_bel);
}

// ── Unit tests ─────────────────────────────────────────────────────────────

test "TST: build from raw table, find known sequences" {
    var tree: ?*TtyKey = null;
    defer tty_keys_free(&tree);

    tty_keys_build(&tree, null);

    // F1 is \x1bOP from raw table (index = T.KEYC_F1)... but raw table uses
    // \x1bO[1;2P etc.  The raw F1 is not directly listed in tty_default_raw_keys.
    // However \x1b[A should map to KEYC_UP | KEYC_CURSOR.
    var size: usize = 0;
    const tk = tty_keys_find(tree, "\x1b[A", &size);
    try std.testing.expect(tk != null);
    try std.testing.expectEqual(@as(usize, 3), size);
    try std.testing.expectEqual(T.KEYC_UP | T.KEYC_CURSOR, tk.?.key);
}

test "TST: focus-in sequence" {
    var tree: ?*TtyKey = null;
    defer tty_keys_free(&tree);
    tty_keys_build(&tree, null);

    var size: usize = 0;
    const tk = tty_keys_find(tree, "\x1b[I", &size);
    try std.testing.expect(tk != null);
    try std.testing.expectEqual(T.KEYC_FOCUS_IN, tk.?.key);
}

test "TST: paste-start sequence" {
    var tree: ?*TtyKey = null;
    defer tty_keys_free(&tree);
    tty_keys_build(&tree, null);

    var size: usize = 0;
    const tk = tty_keys_find(tree, "\x1b[200~", &size);
    try std.testing.expect(tk != null);
    try std.testing.expectEqual(T.KEYC_PASTE_START | T.KEYC_IMPLIED_META, tk.?.key);
}

test "TST: xterm modifier F1 shift (modifier 2)" {
    var tree: ?*TtyKey = null;
    defer tty_keys_free(&tree);
    tty_keys_build(&tree, null);

    // template "\x1b[1;_P" with _ = '2' → \x1b[1;2P → F1|SHIFT
    var size: usize = 0;
    const tk = tty_keys_find(tree, "\x1b[1;2P", &size);
    try std.testing.expect(tk != null);
    try std.testing.expectEqual(T.KEYC_F1 | T.KEYC_SHIFT, tk.?.key);
}

test "tty_keys_next1: single ASCII byte is no_match (handled by caller)" {
    var tree: ?*TtyKey = null;
    defer tty_keys_free(&tree);
    tty_keys_build(&tree, null);

    var key: T.key_code = T.KEYC_UNKNOWN;
    var size: usize = 0;
    // 'a' is not in the key tree and is not a multibyte UTF-8 sequence.
    // tty_keys_next1 returns no_match; the caller (tty_keys_next) handles
    // raw ASCII bytes directly.
    const r = tty_keys_next1(tree, "a", &key, &size, false);
    try std.testing.expectEqual(ParseResult.no_match, r);
}

test "tty_keys_next1: multibyte UTF-8 sequence" {
    var tree: ?*TtyKey = null;
    defer tty_keys_free(&tree);
    tty_keys_build(&tree, null);

    var key: T.key_code = T.KEYC_UNKNOWN;
    var size: usize = 0;
    // U+00E9 é = 0xc3 0xa9 (two-byte UTF-8)
    const r = tty_keys_next1(tree, "\xc3\xa9", &key, &size, false);
    try std.testing.expectEqual(ParseResult.match, r);
    try std.testing.expectEqual(@as(usize, 2), size);
}

test "tty_keys_next1: known escape sequence" {
    var tree: ?*TtyKey = null;
    defer tty_keys_free(&tree);
    tty_keys_build(&tree, null);

    var key: T.key_code = T.KEYC_UNKNOWN;
    var size: usize = 0;
    const r = tty_keys_next1(tree, "\x1b[B", &key, &size, false);
    try std.testing.expectEqual(ParseResult.match, r);
    try std.testing.expectEqual(T.KEYC_DOWN | T.KEYC_CURSOR, key);
    try std.testing.expectEqual(@as(usize, 3), size);
}

test "tty_keys_extended_key: CSI u form" {
    // \033[97;5u → 'a' | CTRL (modifier=5, number=97='a')
    var key: T.key_code = T.KEYC_UNKNOWN;
    var size: usize = 0;
    const r = tty_keys_extended_key("\x1b[97;5u", &size, &key, null);
    try std.testing.expectEqual(ParseResult.match, r);
    try std.testing.expectEqual(@as(usize, 7), size);
    try std.testing.expect((key & T.KEYC_CTRL) != 0);
    try std.testing.expectEqual(@as(T.key_code, 'a'), key & T.KEYC_MASK_KEY);
}

test "tty_keys_extended_key: modifyOtherKeys ~ form" {
    // \033[27;5;97~ → 'a' | CTRL
    var key: T.key_code = T.KEYC_UNKNOWN;
    var size: usize = 0;
    const r = tty_keys_extended_key("\x1b[27;5;97~", &size, &key, null);
    try std.testing.expectEqual(ParseResult.match, r);
    try std.testing.expect((key & T.KEYC_CTRL) != 0);
    try std.testing.expectEqual(@as(T.key_code, 'a'), key & T.KEYC_MASK_KEY);
}

test "tty_keys_mouse: SGR press event" {
    // \033[<0;1;1M → button 1 press at (0,0) in 0-based coords
    var size: usize = 0;
    var lx: u32 = 0;
    var ly: u32 = 0;
    var lb: u32 = 0;
    const res = tty_keys_mouse("\x1b[<0;1;1M", &size, &lx, &ly, &lb);
    try std.testing.expectEqual(ParseResult.match, res.result);
    try std.testing.expectEqual(@as(u32, 0), res.m.x);
    try std.testing.expectEqual(@as(u32, 0), res.m.y);
    try std.testing.expectEqual(@as(u8, 'M'), res.m.sgr_type);
}

test "tty_keys_mouse: X10 mouse event" {
    // \033[M + btn(32) + x(33) + y(33) → button 0 at (0,0)
    var size: usize = 0;
    var lx: u32 = 0;
    var ly: u32 = 0;
    var lb: u32 = 0;
    const seq = [_]u8{ '\x1b', '[', 'M', 32, 33, 33 };
    const res = tty_keys_mouse(&seq, &size, &lx, &ly, &lb);
    try std.testing.expectEqual(ParseResult.match, res.result);
    try std.testing.expectEqual(@as(u32, 0), res.m.b);
    try std.testing.expectEqual(@as(u32, 0), res.m.x);
    try std.testing.expectEqual(@as(u32, 0), res.m.y);
}

test "tty_keys_device_attributes: basic DA1" {
    var size: usize = 0;
    var params: [32]u32 = undefined;
    var n: usize = 0;
    // \033[?62;1;6;8;9;15c
    const r = tty_keys_device_attributes("\x1b[?62;1;6c", &size, false, &params, &n);
    try std.testing.expectEqual(ParseResult.match, r);
    try std.testing.expect(n >= 1);
    try std.testing.expectEqual(@as(u32, 62), params[0]);
}

test "tty_keys_clipboard: basic OSC 52 BEL-terminated" {
    // \033]52;c;aGVsbG8=\007  →  "hello" (base64 aGVsbG8=)
    var size: usize = 0;
    var clip: u8 = 0;
    var data: ?[]u8 = null;
    defer if (data) |d| xm.allocator.free(d);
    const r = tty_keys_clipboard("\x1b]52;c;aGVsbG8=\x07", &size, &clip, &data);
    try std.testing.expectEqual(ParseResult.match, r);
    try std.testing.expectEqual(@as(u8, 'c'), clip);
    try std.testing.expect(data != null);
    if (data) |d| {
        try std.testing.expectEqualStrings("hello", d);
    }
}

test "tty_keys_winsz: character mode" {
    var size: usize = 0;
    const r = tty_keys_winsz("\x1b[8;24;80t", &size);
    try std.testing.expect(r != null);
    try std.testing.expectEqual(WinszKind.chars, r.?.kind);
    try std.testing.expectEqual(@as(u32, 80), r.?.v1); // sx
    try std.testing.expectEqual(@as(u32, 24), r.?.v2); // sy
}

test "tty_keys_device_attributes2: secondary DA" {
    var size: usize = 0;
    var params: [16]u32 = undefined;
    var n: usize = 0;
    // \033[>77;30802;0c — mintty identity (type=77, version=30802)
    const r = tty_keys_device_attributes2("\x1b[>77;30802;0c", &size, false, &params, &n);
    try std.testing.expectEqual(ParseResult.match, r);
    try std.testing.expect(n >= 2);
    try std.testing.expectEqual(@as(u32, 77), params[0]); // terminal type
    try std.testing.expectEqual(@as(u32, 30802), params[1]); // version
}

test "tty_keys_device_attributes2: already received" {
    var size: usize = 0;
    var params: [16]u32 = undefined;
    var n: usize = 0;
    // With have_da2=true, should return no_match.
    const r = tty_keys_device_attributes2("\x1b[>77;30802;0c", &size, true, &params, &n);
    try std.testing.expectEqual(ParseResult.no_match, r);
}

test "tty_keys_extended_device_attributes: XDA/XTVERSION" {
    var size: usize = 0;
    var tmp: [256]u8 = undefined;
    // \033P>|foot(1.18.1)\033\\ — foot terminal identity
    const r = tty_keys_extended_device_attributes("\x1bP>|foot(1.18.1)\x1b\\", &size, false, &tmp);
    try std.testing.expectEqual(ParseResult.match, r);
    try std.testing.expect(size > 0);
    const name = std.mem.sliceTo(&tmp, 0);
    try std.testing.expect(std.mem.indexOf(u8, name, "foot") != null);
}

test "tty_keys_colours: OSC 10 foreground colour" {
    var size: usize = 0;
    var tmp: [128]u8 = undefined;
    // \033]10;rgb:ffff/ffff/ffff\033\\ — white foreground
    const r = tty_keys_colours("\x1b]10;rgb:ffff/ffff/ffff\x1b\\", &size, true, &tmp);
    try std.testing.expectEqual(ParseResult.match, r);
    try std.testing.expect(size > 0);
    const colour_str = std.mem.sliceTo(&tmp, 0);
    try std.testing.expect(colour_str.len > 0);
}

test "tty_keys_colours: OSC 11 background colour BEL-terminated" {
    var size: usize = 0;
    var tmp: [128]u8 = undefined;
    // \033]11;rgb:0000/0000/0000\007 — black background
    const r = tty_keys_colours("\x1b]11;rgb:0000/0000/0000\x07", &size, false, &tmp);
    try std.testing.expectEqual(ParseResult.match, r);
    try std.testing.expect(size > 0);
}

test "tty_keys_palette: OSC 4 palette response" {
    var size: usize = 0;
    var tmp: [128]u8 = undefined;
    // \033]4;1;rgb:cccc/0000/0000\033\\ — palette entry 1 = red
    const r = tty_keys_palette("\x1b]4;1;rgb:cccc/0000/0000\x1b\\", &size, &tmp);
    try std.testing.expectEqual(ParseResult.match, r);
    try std.testing.expect(size > 0);
    const colour_str = std.mem.sliceTo(&tmp, 0);
    try std.testing.expect(colour_str.len > 0);
}

test "tty_keys_winsz: pixel mode" {
    var size: usize = 0;
    const r = tty_keys_winsz("\x1b[4;768;1024t", &size);
    try std.testing.expect(r != null);
    try std.testing.expectEqual(WinszKind.pixels, r.?.kind);
    try std.testing.expectEqual(@as(u32, 1024), r.?.v1); // xpixel
    try std.testing.expectEqual(@as(u32, 768), r.?.v2); // ypixel
}

test "tty_keys_clipboard: OSC 52 ST-terminated" {
    var size: usize = 0;
    var clip: u8 = 0;
    var data: ?[]u8 = null;
    defer if (data) |d| xm.allocator.free(d);
    // \033]52;p;dGVzdA==\033\\ → "test"
    const r = tty_keys_clipboard("\x1b]52;p;dGVzdA==\x1b\\", &size, &clip, &data);
    try std.testing.expectEqual(ParseResult.match, r);
    try std.testing.expectEqual(@as(u8, 'p'), clip);
    try std.testing.expect(data != null);
    if (data) |d| {
        try std.testing.expectEqualStrings("test", d);
    }
}

test "partial sequences return partial" {
    var size: usize = 0;
    var params: [16]u32 = undefined;
    var n: usize = 0;
    // Partial DA1: just \033[?
    try std.testing.expectEqual(ParseResult.partial, tty_keys_device_attributes("\x1b[?", &size, false, &params, &n));
    // Partial DA2: just \033[>
    try std.testing.expectEqual(ParseResult.partial, tty_keys_device_attributes2("\x1b[>", &size, false, &params, &n));
    // Partial XDA: just \033P>|
    var tmp: [256]u8 = undefined;
    try std.testing.expectEqual(ParseResult.partial, tty_keys_extended_device_attributes("\x1bP>|", &size, false, &tmp));
    // Partial colour: just \033]10;
    var ctmp: [128]u8 = undefined;
    try std.testing.expectEqual(ParseResult.partial, tty_keys_colours("\x1b]10;", &size, true, &ctmp));
}
