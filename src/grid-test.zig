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

//! grid-test.zig -- tests for grid.zig, extracted from grid.zig.

const std = @import("std");
const grid = @import("grid.zig");
const hyperlinks = @import("hyperlinks.zig");
const T = @import("types.zig");
const utf8 = @import("utf8.zig");
const xm = @import("xmalloc.zig");

const WHITESPACE = grid.WHITESPACE;

test "grid cells_look_equal treats identical cells as equal" {
    const a = T.grid_default_cell;
    try std.testing.expect(grid.cells_look_equal(&a, &a));
}

test "grid set_ascii and scroll_up keep content bounded" {
    const gd = grid.grid_create(4, 2, 100);
    defer grid.grid_free(gd);

    grid.set_ascii(gd, 0, 0, 'a');
    grid.set_ascii(gd, 1, 0, 'b');
    try std.testing.expectEqual(@as(u8, 'a'), grid.ascii_at(gd, 0, 0));
    try std.testing.expectEqual(@as(u8, 'b'), grid.ascii_at(gd, 1, 0));

    grid.scroll_up(gd, 0, 1);
    try std.testing.expectEqual(@as(u8, 'b'), grid.ascii_at(gd, 0, 0));
    try std.testing.expectEqual(@as(u8, ' '), grid.ascii_at(gd, 1, 0));
}

test "grid remove_history trims stored history rows and clamps hscrolled" {
    const gd = grid.grid_create(4, 2, 100);
    defer grid.grid_free(gd);

    grid.set_ascii(gd, 0, 0, 'a');
    grid.set_ascii(gd, 1, 0, 'b');
    grid.scroll_full_screen_into_history(gd);

    grid.set_ascii(gd, 0, 0, 'c');
    grid.set_ascii(gd, 1, 0, 'd');
    grid.scroll_full_screen_into_history(gd);

    gd.hscrolled = 7;

    grid.remove_history(gd, 1);
    try std.testing.expectEqual(@as(u32, 1), gd.hsize);
    try std.testing.expectEqual(@as(u32, 1), gd.hscrolled);
    try std.testing.expectEqual(@as(usize, 3), gd.linedata.len);

    const history_row = grid.absolute_row_to_storage(gd, 0).?;
    const rendered = grid.string_cells(gd, history_row, gd.sx, .{ .trim_trailing_spaces = true });
    defer xm.allocator.free(rendered);
    try std.testing.expectEqualStrings("c", rendered);

    grid.remove_history(gd, 3);
    try std.testing.expectEqual(@as(u32, 1), gd.hsize);
}

test "grid_clear_history drops stored history rows and offsets" {
    const gd = grid.grid_create(4, 2, 100);
    defer grid.grid_free(gd);

    grid.set_ascii(gd, 0, 0, 'a');
    grid.set_ascii(gd, 1, 0, 'b');
    grid.scroll_full_screen_into_history(gd);
    gd.hscrolled = 3;

    grid.grid_clear_history(gd);
    try std.testing.expectEqual(@as(u32, 0), gd.hsize);
    try std.testing.expectEqual(@as(u32, 0), gd.hscrolled);
    try std.testing.expectEqual(@as(usize, gd.sy), gd.linedata.len);
}

test "grid stores multibyte cells and padding through the shared cell API" {
    const gd = grid.grid_create(4, 1, 0);
    defer grid.grid_free(gd);

    const glyph = utf8.Glyph.fromCodepoint(0x1f642) orelse return error.ExpectedGlyph;
    const source = T.GridCell.fromPayload(glyph.payload());
    grid.set_cell(gd, 0, 0, &source);
    grid.set_padding(gd, 0, 1);

    var stored: T.GridCell = undefined;
    grid.get_cell(gd, 0, 0, &stored);
    try std.testing.expect(grid.cells_equal(&source, &stored));
    try std.testing.expectEqualStrings("🙂", stored.payload().bytes());
    try std.testing.expectEqual(@as(u8, 2), stored.payload().width);

    grid.get_cell(gd, 0, 1, &stored);
    try std.testing.expect(stored.isPadding());
    try std.testing.expectEqual(@as(u8, 0), stored.payload().width);
    try std.testing.expectEqual(@as(u32, 2), grid.line_length(gd, 0));
}

test "grid string_cells preserves utf8 payloads while skipping padding cells" {
    const gd = grid.grid_create(4, 1, 0);
    defer grid.grid_free(gd);

    const accent = utf8.Glyph.fromCodepoint('é').?;
    const emoji = utf8.Glyph.fromCodepoint(0x1f642).?;

    var accent_cell = T.GridCell.fromPayload(accent.payload());
    var emoji_cell = T.GridCell.fromPayload(emoji.payload());
    grid.set_cell(gd, 0, 0, &accent_cell);
    grid.set_cell(gd, 0, 1, &emoji_cell);
    grid.set_padding(gd, 0, 2);
    grid.set_ascii(gd, 0, 3, '!');

    const rendered = grid.string_cells(gd, 0, gd.sx, .{ .trim_trailing_spaces = true });
    defer xm.allocator.free(rendered);

    try std.testing.expectEqualStrings("é🙂!", rendered);
}

test "grid string_cells emits tmux-style sgr state transitions" {
    const gd = grid.grid_create(2, 1, 0);
    defer grid.grid_free(gd);

    var styled = T.grid_default_cell;
    styled.fg = 1;
    styled.attr = T.GRID_ATTR_BRIGHT;
    utf8.utf8_set(&styled.data, 'A');
    grid.set_cell(gd, 0, 0, &styled);
    grid.set_ascii(gd, 0, 1, 'B');

    const rendered = grid.string_cells(gd, 0, gd.sx, .{ .with_sequences = true });
    defer xm.allocator.free(rendered);

    try std.testing.expectEqualStrings("\x1b[1m\x1b[31mA\x1b[0mB", rendered);
}

test "grid string_cells escapes emitted sequences and hyperlinks" {
    const screen = @import("screen.zig");
    const s = screen.screen_init(1, 1, 0);
    defer {
        screen.screen_free(s);
        xm.allocator.destroy(s);
    }

    var linked = T.grid_default_cell;
    utf8.utf8_set(&linked.data, 'X');
    linked.link = hyperlinks.hyperlinks_put(s.hyperlinks.?, "https://example.com", "pane");
    grid.set_cell(s.grid, 0, 0, &linked);

    const rendered = grid.string_cells(s.grid, 0, s.grid.sx, .{
        .with_sequences = true,
        .escape_sequences = true,
        .screen = s,
    });
    defer xm.allocator.free(rendered);

    try std.testing.expectEqualStrings("\\033]8;id=pane;https://example.com\\033\\\\X\\033]8;;\\033\\\\", rendered);
}

test "grid overwriting an extended slot with ascii preserves readable content" {
    const gd = grid.grid_create(4, 1, 0);
    defer grid.grid_free(gd);

    const glyph = utf8.Glyph.fromCodepoint(0x00e9) orelse return error.ExpectedGlyph;
    var cell = T.GridCell.fromPayload(glyph.payload());
    grid.set_cell(gd, 0, 0, &cell);

    grid.set_ascii(gd, 0, 0, 'x');

    var stored: T.GridCell = undefined;
    grid.get_cell(gd, 0, 0, &stored);
    try std.testing.expectEqual(@as(u8, 'x'), grid.ascii_at(gd, 0, 0));
    try std.testing.expectEqual(@as(u8, 1), stored.payload().size);
    try std.testing.expectEqual(@as(u8, 'x'), stored.payload().data[0]);
}

test "grid_in_set follows stored tab width across padding cells" {
    const gd = grid.grid_create(4, 1, 0);
    defer grid.grid_free(gd);

    var tab = T.grid_default_cell;
    grid.set_tab(&tab, 4);
    grid.set_cell(gd, 0, 0, &tab);
    grid.set_padding(gd, 0, 1);
    grid.set_padding(gd, 0, 2);
    grid.set_padding(gd, 0, 3);

    try std.testing.expectEqual(@as(u32, 4), grid.grid_in_set(gd, 0, 0, "\t"));
    try std.testing.expectEqual(@as(u32, 2), grid.grid_in_set(gd, 0, 2, "\t"));
    try std.testing.expectEqual(@as(u32, 2), grid.grid_in_set(gd, 0, 2, WHITESPACE));
}

test "grid reader word helpers respect wrapped rows and stored cell widths" {
    const gd = grid.grid_create(6, 2, 0);
    defer grid.grid_free(gd);

    grid.set_ascii(gd, 0, 0, 'a');
    grid.set_ascii(gd, 0, 1, 'b');
    grid.set_ascii(gd, 0, 2, 'c');
    grid.set_ascii(gd, 0, 3, 'd');
    grid.set_ascii(gd, 0, 4, 'e');
    gd.linedata[0].flags |= T.GRID_LINE_WRAPPED;
    grid.set_ascii(gd, 1, 0, ' ');
    grid.set_ascii(gd, 1, 1, 'f');
    grid.set_ascii(gd, 1, 2, 'g');

    var gr: T.GridReader = undefined;
    grid.grid_reader_start(&gr, gd, 0, 0);
    grid.grid_reader_cursor_next_word_end(&gr, "");
    try std.testing.expectEqual(@as(u32, 5), gr.cx);
    try std.testing.expectEqual(@as(u32, 0), gr.cy);

    grid.grid_reader_start(&gr, gd, 0, 0);
    grid.grid_reader_cursor_next_word(&gr, "");
    try std.testing.expectEqual(@as(u32, 1), gr.cx);
    try std.testing.expectEqual(@as(u32, 1), gr.cy);

    grid.grid_reader_cursor_previous_word(&gr, "", true, false);
    try std.testing.expectEqual(@as(u32, 0), gr.cx);
    try std.testing.expectEqual(@as(u32, 0), gr.cy);
}

test "grid reader jump and indentation helpers stay on stored utf8 cells" {
    const gd = grid.grid_create(5, 2, 0);
    defer grid.grid_free(gd);

    var emoji = T.GridCell.fromPayload(utf8.Glyph.fromCodepoint(0x1f642).?.payload());
    grid.set_ascii(gd, 0, 0, ' ');
    grid.set_ascii(gd, 0, 1, ' ');
    grid.set_cell(gd, 0, 2, &emoji);
    grid.set_padding(gd, 0, 3);
    gd.linedata[0].flags |= T.GRID_LINE_WRAPPED;
    grid.set_ascii(gd, 1, 0, ' ');
    grid.set_ascii(gd, 1, 1, 'x');

    var gr: T.GridReader = undefined;
    grid.grid_reader_start(&gr, gd, 4, 1);
    grid.grid_reader_cursor_back_to_indentation(&gr);
    try std.testing.expectEqual(@as(u32, 2), gr.cx);
    try std.testing.expectEqual(@as(u32, 0), gr.cy);

    const jump = emoji.payload();
    try std.testing.expect(grid.grid_reader_cursor_jump(&gr, jump));
    try std.testing.expectEqual(@as(u32, 2), gr.cx);
    try std.testing.expectEqual(@as(u32, 0), gr.cy);

    grid.grid_reader_start(&gr, gd, 4, 1);
    try std.testing.expect(grid.grid_reader_cursor_jump_back(&gr, jump));
    try std.testing.expectEqual(@as(u32, 2), gr.cx);
    try std.testing.expectEqual(@as(u32, 0), gr.cy);
}
