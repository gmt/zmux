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
// Ported in part from tmux/format-draw.c.
// Original copyright:
//   Copyright (c) 2019 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

//! format-draw.zig – reduced style-aware format rendering over shared cells.

const std = @import("std");
const T = @import("types.zig");
const grid = @import("grid.zig");
const screen_mod = @import("screen.zig");
const screen_write = @import("screen-write.zig");
const style_mod = @import("style.zig");
const utf8 = @import("utf8.zig");
const xm = @import("xmalloc.zig");

pub fn format_width(expanded: []const u8) u32 {
    var width: u32 = 0;
    var pos: usize = 0;
    var decoder = utf8.Decoder.init();

    while (pos < expanded.len) {
        if (expanded[pos] == '#') {
            if (pos + 1 < expanded.len and expanded[pos + 1] == '#') {
                width += 1;
                pos += 2;
                continue;
            }
            if (pos + 1 < expanded.len and expanded[pos + 1] == '[') {
                const end = std.mem.indexOfScalarPos(u8, expanded, pos + 2, ']') orelse return 0;
                pos = end + 1;
                continue;
            }
        }

        switch (decoder.feed(expanded[pos..])) {
            .glyph => |step| {
                width += step.glyph.width;
                pos += step.consumed;
            },
            .invalid, .need_more => {
                if (expanded[pos] > 0x1f and expanded[pos] < 0x7f) width += 1;
                pos += 1;
                decoder.reset();
            },
        }
    }

    return width;
}

pub fn format_draw(
    ctx: *T.ScreenWriteCtx,
    base: *const T.GridCell,
    available: u32,
    expanded: []const u8,
) void {
    var base_default = base.*;
    var current_default = base.*;
    var sy: T.Style = undefined;
    style_mod.style_set(&sy, &current_default);

    const start_x = ctx.s.cx;
    const start_y = ctx.s.cy;
    var width: u32 = 0;
    var pos: usize = 0;
    var decoder = utf8.Decoder.init();
    var filled = false;

    while (pos < expanded.len and width < available) {
        if (expanded[pos] == '#') {
            if (pos + 1 < expanded.len and expanded[pos + 1] == '#') {
                drawAscii(ctx, &sy.gc, '#', available, &width);
                pos += 2;
                continue;
            }
            if (pos + 1 < expanded.len and expanded[pos + 1] == '[') {
                const end = std.mem.indexOfScalarPos(u8, expanded, pos + 2, ']') orelse break;
                const token = expanded[pos + 2 .. end];
                const saved_sy = sy;
                var next_sy = sy;
                if (style_mod.style_parse(&next_sy, &current_default, token) == 0) {
                    sy = next_sy;
                    if (!filled and sy.fill != 8) {
                        fillAvailable(ctx, sy.fill, available);
                        screen_write.cursor_to(ctx, start_y, start_x);
                        width = 0;
                        filled = true;
                    }
                    switch (sy.default_type) {
                        .push => {
                            current_default = saved_sy.gc;
                            sy.default_type = .base;
                        },
                        .pop => {
                            current_default = base_default;
                            sy.default_type = .base;
                        },
                        .set => {
                            base_default = saved_sy.gc;
                            current_default = saved_sy.gc;
                            sy.default_type = .base;
                        },
                        .base => {},
                    }
                }
                pos = end + 1;
                continue;
            }
        }

        if (sy.ignore) {
            pos += 1;
            continue;
        }

        switch (decoder.feed(expanded[pos..])) {
            .glyph => |step| {
                if (width + step.glyph.width > available) return;
                sy.gc.data = step.glyph.data;
                screen_write.putCell(ctx, &sy.gc);
                width += step.glyph.width;
                pos += step.consumed;
            },
            .invalid, .need_more => {
                const ch = expanded[pos];
                if (ch > 0x1f and ch < 0x7f) {
                    drawAscii(ctx, &sy.gc, ch, available, &width);
                }
                pos += 1;
                decoder.reset();
            },
        }
    }
}

fn fillAvailable(ctx: *T.ScreenWriteCtx, bg: i32, available: u32) void {
    var gc = T.grid_default_cell;
    gc.bg = bg;

    const start_x = ctx.s.cx;
    const start_y = ctx.s.cy;
    var remaining = available;
    while (remaining > 0) : (remaining -= 1) {
        screen_write.putCell(ctx, &gc);
    }
    screen_write.cursor_to(ctx, start_y, start_x);
}

fn drawAscii(
    ctx: *T.ScreenWriteCtx,
    gc: *T.GridCell,
    ch: u8,
    available: u32,
    width: *u32,
) void {
    if (width.* >= available) return;
    utf8.utf8_set(&gc.data, ch);
    screen_write.putCell(ctx, gc);
    width.* += 1;
}

test "format_width ignores style directives and counts utf8 cells" {
    try std.testing.expectEqual(@as(u32, 5), format_width("#[fg=red]a🙂bc"));
    try std.testing.expectEqual(@as(u32, 2), format_width("##["));
}

test "format_draw writes utf8 cells through the shared screen writer" {
    const screen = screen_mod.screen_init(6, 1, 0);
    defer {
        screen_mod.screen_free(screen);
        xm.allocator.destroy(screen);
    }

    var ctx = T.ScreenWriteCtx{ .s = screen };
    format_draw(&ctx, &T.grid_default_cell, 6, "#[bg=blue,fill=blue]é🙂");

    var stored: T.GridCell = undefined;
    grid.get_cell(screen.grid, 0, 0, &stored);
    try std.testing.expectEqualStrings("é", stored.payload().bytes());
    try std.testing.expectEqual(@as(i32, 4), stored.bg);

    grid.get_cell(screen.grid, 0, 1, &stored);
    try std.testing.expectEqualStrings("🙂", stored.payload().bytes());
    try std.testing.expectEqual(@as(u8, 2), stored.payload().width);

    grid.get_cell(screen.grid, 0, 2, &stored);
    try std.testing.expect(stored.isPadding());

    grid.get_cell(screen.grid, 0, 5, &stored);
    try std.testing.expectEqual(@as(u8, ' '), stored.payload().data[0]);
    try std.testing.expectEqual(@as(i32, 4), stored.bg);
}
