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

//! input-keys-test.zig – sequence parsing and reply generation tests for input-keys.zig.
//!
//! Focuses on:
//!   - Streamed/partial key sequence parsing (fragmented input across reads)
//!   - Mode transition correctness (application vs normal cursor keys, bracketed paste)
//!   - Reply generation for DA/DSR-like sequences (theme reports, OSC 52)
//!   - Edge cases: unknown sequences, ambiguous sequences at buffer boundary

const std = @import("std");
const T = @import("types.zig");
const input_keys = @import("input-keys.zig");
const opts = @import("options.zig");

// ---------------------------------------------------------------------------
// Test 1: Fragmented CSI tilde sequences stay pending until the terminator
// ---------------------------------------------------------------------------

test "input-keys: fragmented paste-start sequence returns null for each prefix" {
    var event: T.key_event = .{};

    // \x1b[200~ = paste start — build it up byte by byte
    const prefixes = [_][]const u8{
        "\x1b",
        "\x1b[",
        "\x1b[2",
        "\x1b[20",
        "\x1b[200",
    };
    for (prefixes) |prefix| {
        try std.testing.expect(input_keys.input_key_get(prefix, &event) == null);
    }

    // Full sequence resolves
    const consumed = input_keys.input_key_get("\x1b[200~", &event).?;
    try std.testing.expectEqual(@as(usize, 6), consumed);
    try std.testing.expectEqual(T.KEYC_PASTE_START | T.KEYC_IMPLIED_META, event.key);
}

test "input-keys: fragmented delete-key sequence returns null for each prefix" {
    var event: T.key_event = .{};

    // \x1b[3~ = DC (delete)
    try std.testing.expect(input_keys.input_key_get("\x1b", &event) == null);
    try std.testing.expect(input_keys.input_key_get("\x1b[", &event) == null);
    try std.testing.expect(input_keys.input_key_get("\x1b[3", &event) == null);

    const consumed = input_keys.input_key_get("\x1b[3~", &event).?;
    try std.testing.expectEqual(@as(usize, 4), consumed);
    try std.testing.expectEqual(T.KEYC_DC | T.KEYC_IMPLIED_META, event.key);
}

test "input-keys: fragmented theme report stays pending until final n" {
    var event: T.key_event = .{};

    // \x1b[?997;2n = light theme report
    const prefixes = [_][]const u8{
        "\x1b",
        "\x1b[",
        "\x1b[?",
        "\x1b[?9",
        "\x1b[?99",
        "\x1b[?997",
        "\x1b[?997;",
        "\x1b[?997;2",
    };
    for (prefixes) |prefix| {
        try std.testing.expect(input_keys.input_key_get(prefix, &event) == null);
    }

    const consumed = input_keys.input_key_get("\x1b[?997;2n", &event).?;
    try std.testing.expectEqual(@as(usize, 9), consumed);
    try std.testing.expectEqual(T.KEYC_REPORT_LIGHT_THEME, event.key);
}

// ---------------------------------------------------------------------------
// Test 2: Multi-key buffer — consumed count lets caller advance correctly
// ---------------------------------------------------------------------------

test "input-keys: multi-key buffer parses each sequence with correct consumed count" {
    var event: T.key_event = .{};

    // Two keys concatenated: 'a' + cursor-up (\x1b[A)
    const buf = "a\x1b[A";

    const first = input_keys.input_key_get(buf, &event).?;
    try std.testing.expectEqual(@as(usize, 1), first);
    try std.testing.expectEqual(@as(T.key_code, 'a'), event.key);

    const second = input_keys.input_key_get(buf[first..], &event).?;
    try std.testing.expectEqual(@as(usize, 3), second);
    try std.testing.expectEqual(T.KEYC_UP | T.KEYC_CURSOR | T.KEYC_IMPLIED_META, event.key);
}

test "input-keys: three keys in one buffer parse sequentially" {
    var event: T.key_event = .{};

    // Tab + ESC-x (Meta-x) + backspace
    const buf = "\t\x1bx\x7f";

    var off: usize = 0;
    off += input_keys.input_key_get(buf[off..], &event).?;
    try std.testing.expectEqual(@as(T.key_code, T.C0_HT), event.key);

    off += input_keys.input_key_get(buf[off..], &event).?;
    try std.testing.expectEqual(@as(T.key_code, 'x') | T.KEYC_META, event.key);

    off += input_keys.input_key_get(buf[off..], &event).?;
    try std.testing.expectEqual(T.KEYC_BSPACE, event.key);

    try std.testing.expectEqual(buf.len, off);
}

// ---------------------------------------------------------------------------
// Test 3: Mode transition — cursor and keypad mode in encode_screen
// ---------------------------------------------------------------------------

test "input-keys: encode_screen cursor mode transitions change arrow encoding" {
    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);

    var dummy_grid: T.Grid = undefined;
    var screen = T.Screen{ .grid = &dummy_grid };
    var buf: [32]u8 = undefined;

    // Normal mode: CSI A
    screen.mode = 0;
    const normal = try input_keys.input_key_encode_screen(&screen, T.KEYC_UP | T.KEYC_CURSOR, &buf);
    try std.testing.expectEqualStrings("\x1b[A", normal);

    // Application cursor mode: SS3 A
    screen.mode = T.MODE_KCURSOR;
    const app = try input_keys.input_key_encode_screen(&screen, T.KEYC_UP | T.KEYC_CURSOR, &buf);
    try std.testing.expectEqualStrings("\x1bOA", app);

    // All four arrow keys in application cursor mode
    try std.testing.expectEqualStrings("\x1bOB", try input_keys.input_key_encode_screen(&screen, T.KEYC_DOWN | T.KEYC_CURSOR, &buf));
    try std.testing.expectEqualStrings("\x1bOC", try input_keys.input_key_encode_screen(&screen, T.KEYC_RIGHT | T.KEYC_CURSOR, &buf));
    try std.testing.expectEqualStrings("\x1bOD", try input_keys.input_key_encode_screen(&screen, T.KEYC_LEFT | T.KEYC_CURSOR, &buf));
}

test "input-keys: encode_screen keypad mode transitions change numpad encoding" {
    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);

    var dummy_grid: T.Grid = undefined;
    var screen = T.Screen{ .grid = &dummy_grid };
    var buf: [32]u8 = undefined;

    // Normal mode: literal digit
    screen.mode = 0;
    const normal = try input_keys.input_key_encode_screen(&screen, T.KEYC_KP_FIVE | T.KEYC_KEYPAD, &buf);
    try std.testing.expectEqualStrings("5", normal);

    // Application keypad mode: SS3 sequence
    screen.mode = T.MODE_KKEYPAD;
    const app = try input_keys.input_key_encode_screen(&screen, T.KEYC_KP_FIVE | T.KEYC_KEYPAD, &buf);
    try std.testing.expectEqualStrings("\x1bOu", app);

    // Enter key in application keypad mode
    const enter = try input_keys.input_key_encode_screen(&screen, T.KEYC_KP_ENTER | T.KEYC_KEYPAD, &buf);
    try std.testing.expectEqualStrings("\x1bOM", enter);
}

test "input-keys: encode_screen bracketed paste mode gates paste sequence emission" {
    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);

    var dummy_grid: T.Grid = undefined;
    var screen = T.Screen{ .grid = &dummy_grid };
    var buf: [32]u8 = undefined;

    // Without bracket paste: empty output (suppressed)
    screen.mode = 0;
    const suppressed = try input_keys.input_key_encode_screen(&screen, T.KEYC_PASTE_START, &buf);
    try std.testing.expectEqual(@as(usize, 0), suppressed.len);

    // With bracket paste: emit the sequence
    screen.mode = T.MODE_BRACKETPASTE;
    const emitted_start = try input_keys.input_key_encode_screen(&screen, T.KEYC_PASTE_START, &buf);
    try std.testing.expectEqualStrings("\x1b[200~", emitted_start);

    const emitted_end = try input_keys.input_key_encode_screen(&screen, T.KEYC_PASTE_END, &buf);
    try std.testing.expectEqualStrings("\x1b[201~", emitted_end);
}

// ---------------------------------------------------------------------------
// Test 4: Extended key encoding — CSI u format vs legacy
// ---------------------------------------------------------------------------

test "input-keys: encode_screen extended-keys-2 mode emits CSI u sequences" {
    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);

    var dummy_grid: T.Grid = undefined;
    var screen = T.Screen{ .grid = &dummy_grid };
    var buf: [32]u8 = undefined;

    // extended-keys-format defaults to 1 (legacy); set to 0 for CSI u
    opts.options_set_number(opts.global_options, "extended-keys-format", 0);

    // Extended keys mode 2 with Shift modifier
    screen.mode = T.MODE_KEYS_EXTENDED_2;
    const shifted_tab = try input_keys.input_key_encode_screen(&screen, T.KEYC_BTAB, &buf);
    // BTAB in extended-keys-2 becomes HT|SHIFT, encoded as CSI u: \x1b[9;2u
    try std.testing.expectEqualStrings("\x1b[9;2u", shifted_tab);
}

test "input-keys: encode_screen extended-keys-format=1 uses legacy CSI 27 format" {
    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);

    var dummy_grid: T.Grid = undefined;
    var screen = T.Screen{ .grid = &dummy_grid };
    var buf: [32]u8 = undefined;

    // Set legacy format
    opts.options_set_number(opts.global_options, "extended-keys-format", 1);
    screen.mode = T.MODE_KEYS_EXTENDED_2;

    const shifted_tab = try input_keys.input_key_encode_screen(&screen, T.KEYC_BTAB, &buf);
    // Legacy format: \x1b[27;2;9~
    try std.testing.expectEqualStrings("\x1b[27;2;9~", shifted_tab);
}

// ---------------------------------------------------------------------------
// Test 5: Edge cases — unknown sequences, ambiguous boundaries
// ---------------------------------------------------------------------------

test "input-keys: unknown CSI tilde number consumed as KEYC_UNKNOWN" {
    var event: T.key_event = .{};

    // \x1b[99~ — not a recognized key number
    const consumed = input_keys.input_key_get("\x1b[99~", &event).?;
    try std.testing.expectEqual(@as(usize, 5), consumed);
    try std.testing.expectEqual(T.KEYC_UNKNOWN, event.key);
}

test "input-keys: unknown SS3 final byte produces KEYC_UNKNOWN" {
    var event: T.key_event = .{};

    // \x1bOZ — Z is not a recognized SS3 key
    const consumed = input_keys.input_key_get("\x1bOZ", &event).?;
    try std.testing.expectEqual(@as(usize, 3), consumed);
    try std.testing.expectEqual(T.KEYC_UNKNOWN, event.key);
}

test "input-keys: empty input returns null" {
    var event: T.key_event = .{};
    try std.testing.expect(input_keys.input_key_get("", &event) == null);
}

test "input-keys: bare ESC returns null awaiting next byte" {
    var event: T.key_event = .{};
    try std.testing.expect(input_keys.input_key_get("\x1b", &event) == null);
}

test "input-keys: non-matching CSI private sequence stays pending" {
    var event: T.key_event = .{};

    // \x1b[?1 — could be a valid private mode prefix, needs more bytes
    try std.testing.expect(input_keys.input_key_get("\x1b[?1", &event) == null);
    try std.testing.expect(input_keys.input_key_get("\x1b[?", &event) == null);
}

test "input-keys: all navigation CSI tilde numbers decode correctly" {
    var event: T.key_event = .{};

    const cases = [_]struct { seq: []const u8, key: T.key_code }{
        .{ .seq = "\x1b[1~", .key = T.KEYC_HOME | T.KEYC_IMPLIED_META },
        .{ .seq = "\x1b[2~", .key = T.KEYC_IC | T.KEYC_IMPLIED_META },
        .{ .seq = "\x1b[3~", .key = T.KEYC_DC | T.KEYC_IMPLIED_META },
        .{ .seq = "\x1b[4~", .key = T.KEYC_END | T.KEYC_IMPLIED_META },
        .{ .seq = "\x1b[5~", .key = T.KEYC_PPAGE | T.KEYC_IMPLIED_META },
        .{ .seq = "\x1b[6~", .key = T.KEYC_NPAGE | T.KEYC_IMPLIED_META },
        .{ .seq = "\x1b[7~", .key = T.KEYC_HOME | T.KEYC_IMPLIED_META },
        .{ .seq = "\x1b[8~", .key = T.KEYC_END | T.KEYC_IMPLIED_META },
    };
    for (cases) |case| {
        const consumed = input_keys.input_key_get(case.seq, &event).?;
        try std.testing.expectEqual(case.seq.len, consumed);
        try std.testing.expectEqual(case.key, event.key);
    }
}

// ---------------------------------------------------------------------------
// Test 6: SS3 cursor keys decode with CURSOR flag (application mode format)
// ---------------------------------------------------------------------------

test "input-keys: SS3 arrow sequences carry KEYC_CURSOR flag" {
    var event: T.key_event = .{};

    const cases = [_]struct { seq: []const u8, key: T.key_code }{
        .{ .seq = "\x1bOA", .key = T.KEYC_UP | T.KEYC_CURSOR | T.KEYC_IMPLIED_META },
        .{ .seq = "\x1bOB", .key = T.KEYC_DOWN | T.KEYC_CURSOR | T.KEYC_IMPLIED_META },
        .{ .seq = "\x1bOC", .key = T.KEYC_RIGHT | T.KEYC_CURSOR | T.KEYC_IMPLIED_META },
        .{ .seq = "\x1bOD", .key = T.KEYC_LEFT | T.KEYC_CURSOR | T.KEYC_IMPLIED_META },
        .{ .seq = "\x1bOH", .key = T.KEYC_HOME | T.KEYC_IMPLIED_META },
        .{ .seq = "\x1bOF", .key = T.KEYC_END | T.KEYC_IMPLIED_META },
    };
    for (cases) |case| {
        const consumed = input_keys.input_key_get(case.seq, &event).?;
        try std.testing.expectEqual(@as(usize, 3), consumed);
        try std.testing.expectEqual(case.key, event.key);
    }
}

// ---------------------------------------------------------------------------
// Test 7: Encode round-trip — encode then decode, verify key identity
// ---------------------------------------------------------------------------

test "input-keys: encode then decode round-trip preserves key identity for cursor keys" {
    var enc_buf: [16]u8 = undefined;
    var event: T.key_event = .{};

    // Encode UP as a fixed sequence, then decode it back
    const encoded = try input_keys.input_key_encode(T.KEYC_UP, &enc_buf);
    try std.testing.expectEqualStrings("\x1b[A", encoded);

    const consumed = input_keys.input_key_get(encoded, &event).?;
    try std.testing.expectEqual(encoded.len, consumed);
    // Decoded key has CURSOR and IMPLIED_META flags added by the parser
    try std.testing.expectEqual(T.KEYC_UP | T.KEYC_CURSOR | T.KEYC_IMPLIED_META, event.key);
    // The base key matches
    try std.testing.expectEqual(T.KEYC_UP, event.key & T.KEYC_MASK_KEY);
}

test "input-keys: encode then decode round-trip for navigation keys" {
    var enc_buf: [16]u8 = undefined;
    var event: T.key_event = .{};

    const nav_keys = [_]T.key_code{
        T.KEYC_IC,
        T.KEYC_DC,
        T.KEYC_HOME,
        T.KEYC_END,
        T.KEYC_PPAGE,
        T.KEYC_NPAGE,
    };

    for (nav_keys) |key| {
        const encoded = try input_keys.input_key_encode(key, &enc_buf);
        const consumed = input_keys.input_key_get(encoded, &event).?;
        try std.testing.expectEqual(encoded.len, consumed);
        try std.testing.expectEqual(key, event.key & T.KEYC_MASK_KEY);
    }
}

// ---------------------------------------------------------------------------
// Test 8: Control key parsing covers full range
// ---------------------------------------------------------------------------

test "input-keys: control keys 0x01-0x1a decode as Ctrl+letter (except HT, LF, CR)" {
    var event: T.key_event = .{};

    // Ctrl+A = 0x01, Ctrl+Z = 0x1a
    // 0x09 (HT), 0x0a (LF), 0x0d (CR) are intercepted by parse_plain as
    // C0_HT and C0_CR respectively, before ctrl_key is consulted.
    var ch: u8 = 0x01;
    while (ch <= 0x1a) : (ch += 1) {
        const consumed = input_keys.input_key_get(&.{ch}, &event).?;
        try std.testing.expectEqual(@as(usize, 1), consumed);
        if (ch == 0x09) {
            try std.testing.expectEqual(T.C0_HT, event.key);
        } else if (ch == 0x0a or ch == 0x0d) {
            try std.testing.expectEqual(T.C0_CR, event.key);
        } else {
            const expected_letter = @as(T.key_code, 'a') + (ch - 1);
            try std.testing.expectEqual(expected_letter | T.KEYC_CTRL, event.key);
        }
    }
}

test "input-keys: Ctrl+@ (NUL byte) decodes correctly" {
    var event: T.key_event = .{};

    const consumed = input_keys.input_key_get(&.{0x00}, &event).?;
    try std.testing.expectEqual(@as(usize, 1), consumed);
    try std.testing.expectEqual(@as(T.key_code, '@') | T.KEYC_CTRL, event.key);
}

// ---------------------------------------------------------------------------
// Test 9: Mouse screen encoding with SGR mode
// ---------------------------------------------------------------------------

test "input-keys: mouse_screen encodes SGR format when mode is set" {
    var screen = T.Screen{ .grid = undefined };
    screen.mode = T.MODE_MOUSE_ALL | T.MODE_MOUSE_SGR;
    var buf: [40]u8 = undefined;

    const mouse = T.MouseEvent{
        .valid = true,
        .x = 10,
        .y = 20,
        .b = T.MOUSE_BUTTON_1,
        .sgr_type = 'M',
        .sgr_b = T.MOUSE_BUTTON_1,
    };

    const result = input_keys.input_key_mouse_screen(&screen, &mouse, 10, 20, &buf);
    try std.testing.expectEqualStrings("\x1b[<0;11;21M", result);
}

test "input-keys: mouse_screen returns empty when no mouse mode active" {
    var screen = T.Screen{ .grid = undefined };
    screen.mode = 0;
    var buf: [40]u8 = undefined;

    const mouse = T.MouseEvent{
        .valid = true,
        .x = 5,
        .y = 5,
        .b = T.MOUSE_BUTTON_1,
        .sgr_type = 'M',
        .sgr_b = T.MOUSE_BUTTON_1,
    };

    const result = input_keys.input_key_mouse_screen(&screen, &mouse, 5, 5, &buf);
    try std.testing.expectEqual(@as(usize, 0), result.len);
}
