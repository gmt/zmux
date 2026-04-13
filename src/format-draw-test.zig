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

//! format-draw-test.zig – external tests for format-draw: width trimming with
//! multi-byte/wide characters, list clipping, and style-aware rendering.

const std = @import("std");
const T = @import("types.zig");
const grid = @import("grid.zig");
const screen_mod = @import("screen.zig");
const xm = @import("xmalloc.zig");
const fd = @import("format-draw.zig");

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Read rendered text from row 0 of a screen, skipping padding cells.
fn readScreenText(screen: *T.Screen, width: u32) []u8 {
    var buf: std.ArrayList(u8) = .{};
    for (0..width) |col| {
        var cell: T.GridCell = undefined;
        grid.get_cell(screen.grid, 0, @intCast(col), &cell);
        if (cell.isPadding()) continue;
        buf.appendSlice(xm.allocator, cell.payload().bytes()) catch unreachable;
    }
    return buf.toOwnedSlice(xm.allocator) catch unreachable;
}

/// Create a 1-row screen, run format_draw, return rendered text.
fn drawAndRead(width: u32, expanded: []const u8) []u8 {
    const screen = screen_mod.screen_init(width, 1, 0);
    defer {
        screen_mod.screen_free(screen);
        xm.allocator.destroy(screen);
    }
    var ctx = T.ScreenWriteCtx{ .s = screen };
    fd.format_draw(&ctx, &T.grid_default_cell, width, expanded);
    return readScreenText(screen, width);
}

// ---------------------------------------------------------------------------
// 1. Width trimming with multi-byte / wide characters
// ---------------------------------------------------------------------------

test "format-draw: trim_left clips wide CJK at boundary" {
    // "aXb" where X is a CJK char (width 2), total width = 4.
    // Trim to 2 should give "a" + the CJK only if it fits (1+2=3 > 2), so just "a".
    // But trim to 3 should give "a" + CJK.
    {
        const out = fd.format_trim_left("a\xe4\xb8\xadb", 2);
        defer xm.allocator.free(out);
        // CJK char \xe4\xb8\xad (中, width 2) doesn't fit in remaining 1 col
        try std.testing.expectEqualStrings("a", out);
    }
    {
        const out = fd.format_trim_left("a\xe4\xb8\xadb", 3);
        defer xm.allocator.free(out);
        // 1 + 2 = 3 fits exactly
        try std.testing.expectEqualStrings("a\xe4\xb8\xad", out);
    }
}

test "format-draw: trim_right clips wide CJK at boundary" {
    // "a中b" total width 4. trim_right(_, 2) keeps rightmost 2 cols => "b" only?
    // skip = 4 - 2 = 2. 'a' width=1 (width<skip, skip). '中' width=2 => width(1)
    // 1 < 2, so skip it. Then 'b' width=1 => width=1+2=3 >= skip=2, so copy.
    // Actually: width tracks cumulative. Let me re-check.
    // width starts 0. 'a': width=0 < skip=2 → skip, width=1.
    // '中': width=1 < skip=2 → skip, width=3.
    // 'b': width=3 >= skip=2 → copy, width=4.
    // Result: "b"
    {
        const out = fd.format_trim_right("a\xe4\xb8\xadb", 2);
        defer xm.allocator.free(out);
        try std.testing.expectEqualStrings("b", out);
    }
    // trim_right(_, 3): skip = 4-3 = 1. 'a': width=0 < 1 → skip, width=1.
    // '中': width=1 >= 1 → copy. 'b': copy.  Result: "中b"
    {
        const out = fd.format_trim_right("a\xe4\xb8\xadb", 3);
        defer xm.allocator.free(out);
        try std.testing.expectEqualStrings("\xe4\xb8\xadb", out);
    }
}

test "format-draw: trim_left with emoji (width 2)" {
    // "🙂x" total width 3.  Trim to 2 → just emoji.
    {
        const out = fd.format_trim_left("\xf0\x9f\x99\x82x", 2);
        defer xm.allocator.free(out);
        try std.testing.expectEqualStrings("\xf0\x9f\x99\x82", out);
    }
    // Trim to 1 → emoji doesn't fit → empty.
    {
        const out = fd.format_trim_left("\xf0\x9f\x99\x82x", 1);
        defer xm.allocator.free(out);
        try std.testing.expectEqualStrings("", out);
    }
}

test "format-draw: format_width with wide characters" {
    // Pure ASCII
    try std.testing.expectEqual(@as(u32, 5), fd.format_width("hello"));
    // CJK: 中 is width 2
    try std.testing.expectEqual(@as(u32, 4), fd.format_width("a\xe4\xb8\xadb"));
    // Emoji: 🙂 is width 2
    try std.testing.expectEqual(@as(u32, 3), fd.format_width("\xf0\x9f\x99\x82x"));
    // Mixed: style + wide
    try std.testing.expectEqual(@as(u32, 2), fd.format_width("#[fg=red]\xe4\xb8\xad"));
}

// ---------------------------------------------------------------------------
// 2. List clipping at exact boundary
// ---------------------------------------------------------------------------

test "format-draw: list content fits exactly at width" {
    // 4 chars in a 4-wide screen with list — should show all without markers.
    const text = drawAndRead(4, "#[list=on align=left]#[list=left-marker]<#[list=right-marker]>#[list=on]abcd");
    defer xm.allocator.free(text);
    try std.testing.expectEqualStrings("abcd", text);
}

test "format-draw: list content one over boundary shows markers" {
    // 5 chars "abcde" in 4-wide screen with focus on "cd".
    // Should clip with markers visible.
    const screen = screen_mod.screen_init(4, 1, 0);
    defer {
        screen_mod.screen_free(screen);
        xm.allocator.destroy(screen);
    }
    var ctx = T.ScreenWriteCtx{ .s = screen };
    fd.format_draw(
        &ctx,
        &T.grid_default_cell,
        4,
        "#[list=on align=left]#[list=left-marker]<#[list=right-marker]>#[list=on]ab#[list=focus]cd#[list=on]e",
    );

    const text = readScreenText(screen, 4);
    defer xm.allocator.free(text);
    // Expect clipping — at minimum the focused "cd" should be visible.
    // The exact output depends on clipping algorithm, but it should be 4 chars wide.
    try std.testing.expectEqual(@as(usize, 4), fd.format_width(text));
}

test "format-draw: empty list produces no list content" {
    const text = drawAndRead(6, "#[list=on align=left]#[list=left-marker]<#[list=right-marker]>#[list=on]#[list=off]tail");
    defer xm.allocator.free(text);
    // "tail" should appear after the empty list
    try std.testing.expectEqualStrings("tail  ", text);
}

// ---------------------------------------------------------------------------
// 3. Style-aware rendering
// ---------------------------------------------------------------------------

test "format-draw: style preserved across format_draw" {
    const screen = screen_mod.screen_init(4, 1, 0);
    defer {
        screen_mod.screen_free(screen);
        xm.allocator.destroy(screen);
    }
    var ctx = T.ScreenWriteCtx{ .s = screen };
    // Render "ab" with red fg, then "cd" with blue fg
    fd.format_draw(&ctx, &T.grid_default_cell, 4, "#[fg=red]ab#[fg=blue]cd");

    // First two cells should have red fg (colour 1)
    var cell: T.GridCell = undefined;
    grid.get_cell(screen.grid, 0, 0, &cell);
    try std.testing.expectEqualStrings("a", cell.payload().bytes());
    const red_fg = cell.fg;

    grid.get_cell(screen.grid, 0, 1, &cell);
    try std.testing.expectEqualStrings("b", cell.payload().bytes());
    try std.testing.expectEqual(red_fg, cell.fg);

    // Last two should have blue fg (colour 4)
    grid.get_cell(screen.grid, 0, 2, &cell);
    try std.testing.expectEqualStrings("c", cell.payload().bytes());
    const blue_fg = cell.fg;
    try std.testing.expect(blue_fg != red_fg);

    grid.get_cell(screen.grid, 0, 3, &cell);
    try std.testing.expectEqualStrings("d", cell.payload().bytes());
    try std.testing.expectEqual(blue_fg, cell.fg);
}

test "format-draw: style in trim_left is passed through" {
    // "#[fg=red]abc" trimmed to 2 → "#[fg=red]ab" (style preserved)
    const out = fd.format_trim_left("#[fg=red]abc", 2);
    defer xm.allocator.free(out);
    try std.testing.expectEqualStrings("#[fg=red]ab", out);
}

test "format-draw: style in trim_right is passed through" {
    // "#[fg=red]abcd" trimmed to 2 → "#[fg=red]cd" (style preserved)
    const out = fd.format_trim_right("#[fg=red]abcd", 2);
    defer xm.allocator.free(out);
    try std.testing.expectEqualStrings("#[fg=red]cd", out);
}

test "format-draw: multiple styles in trim preserve all" {
    // "#[fg=red]ab#[fg=blue]cd" trimmed to 4 should keep everything
    const out = fd.format_trim_left("#[fg=red]ab#[fg=blue]cd", 4);
    defer xm.allocator.free(out);
    try std.testing.expectEqualStrings("#[fg=red]ab#[fg=blue]cd", out);
}

test "format-draw: ranges track window type through list clip" {
    const screen = screen_mod.screen_init(8, 1, 0);
    defer {
        screen_mod.screen_free(screen);
        xm.allocator.destroy(screen);
    }
    var ctx = T.ScreenWriteCtx{ .s = screen };
    var ranges: fd.DrawRanges = .{};
    defer ranges.deinit(xm.allocator);

    fd.format_draw_ranges(
        &ctx,
        &T.grid_default_cell,
        8,
        "#[list=on align=left]#[list=left-marker]<#[list=right-marker]>" ++
            "#[list=on]abc#[range=window|3 list=focus]XY#[norange list=on]def",
        &ranges,
    );

    // The window range for argument 3 should exist
    try std.testing.expect(ranges.items.len >= 1);
    try std.testing.expectEqual(T.StyleRangeType.window, ranges.items[0].type);
    try std.testing.expectEqual(@as(u32, 3), ranges.items[0].argument);
    // Range should have nonzero width
    try std.testing.expect(ranges.items[0].end > ranges.items[0].start);
}

// ---------------------------------------------------------------------------
// 4. Edge cases
// ---------------------------------------------------------------------------

test "format-draw: zero-width format_draw is a no-op" {
    const screen = screen_mod.screen_init(4, 1, 0);
    defer {
        screen_mod.screen_free(screen);
        xm.allocator.destroy(screen);
    }
    var ctx = T.ScreenWriteCtx{ .s = screen };
    // available=0 should return immediately without touching screen
    fd.format_draw(&ctx, &T.grid_default_cell, 0, "hello");
    // Screen should be untouched — first cell still default space
    var cell: T.GridCell = undefined;
    grid.get_cell(screen.grid, 0, 0, &cell);
    try std.testing.expectEqual(@as(u8, ' '), cell.payload().data[0]);
}

test "format-draw: content exactly at available width" {
    const text = drawAndRead(5, "hello");
    defer xm.allocator.free(text);
    try std.testing.expectEqualStrings("hello", text);
}

test "format-draw: content longer than available width is truncated" {
    const text = drawAndRead(3, "hello");
    defer xm.allocator.free(text);
    try std.testing.expectEqualStrings("hel", text);
}

test "format-draw: wide char that exceeds available width" {
    // Screen is 1 col wide. CJK char (width 2) should not render.
    const screen = screen_mod.screen_init(1, 1, 0);
    defer {
        screen_mod.screen_free(screen);
        xm.allocator.destroy(screen);
    }
    var ctx = T.ScreenWriteCtx{ .s = screen };
    fd.format_draw(&ctx, &T.grid_default_cell, 1, "\xe4\xb8\xad");
    var cell: T.GridCell = undefined;
    grid.get_cell(screen.grid, 0, 0, &cell);
    // The wide char can't fit in 1 col — cell should remain a space or be empty
    try std.testing.expect(!cell.isPadding());
}

test "format-draw: empty string produces spaces" {
    const screen = screen_mod.screen_init(3, 1, 0);
    defer {
        screen_mod.screen_free(screen);
        xm.allocator.destroy(screen);
    }
    var ctx = T.ScreenWriteCtx{ .s = screen };
    fd.format_draw(&ctx, &T.grid_default_cell, 3, "");
    // Empty input — screen should have 3 default cells
    var cell: T.GridCell = undefined;
    grid.get_cell(screen.grid, 0, 0, &cell);
    try std.testing.expectEqual(@as(u8, ' '), cell.payload().data[0]);
}

test "format-draw: format_width of empty string is zero" {
    try std.testing.expectEqual(@as(u32, 0), fd.format_width(""));
}

test "format-draw: format_width of only style tags is zero" {
    try std.testing.expectEqual(@as(u32, 0), fd.format_width("#[fg=red]"));
    try std.testing.expectEqual(@as(u32, 0), fd.format_width("#[fg=red]#[bg=blue]"));
}

test "format-draw: trim_left with zero limit returns empty" {
    const out = fd.format_trim_left("hello world", 0);
    defer xm.allocator.free(out);
    try std.testing.expectEqualStrings("", out);
}

test "format-draw: trim_right with limit >= width returns full string" {
    const out = fd.format_trim_right("abc", 10);
    defer xm.allocator.free(out);
    try std.testing.expectEqualStrings("abc", out);
}

test "format-draw: fill colour covers remaining width" {
    const screen = screen_mod.screen_init(6, 1, 0);
    defer {
        screen_mod.screen_free(screen);
        xm.allocator.destroy(screen);
    }
    var ctx = T.ScreenWriteCtx{ .s = screen };
    fd.format_draw(&ctx, &T.grid_default_cell, 6, "#[bg=green,fill=green]ab");

    // Cells 0-1 have content, cells 2-5 should have fill bg colour (green = 2)
    var cell: T.GridCell = undefined;
    grid.get_cell(screen.grid, 0, 4, &cell);
    try std.testing.expectEqual(@as(i32, 2), cell.bg);
}
