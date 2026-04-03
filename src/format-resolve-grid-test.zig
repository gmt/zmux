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

//! Direct tests for format-resolve grid helpers (complementing format-test.zig).

const std = @import("std");
const T = @import("types.zig");
const grid = @import("grid.zig");
const fmt_resolve = @import("format-resolve.zig");
const xm = @import("xmalloc.zig");

test "grid_storage_usage sums line and cell backing for a small grid" {
    const gd = grid.grid_create(4, 2, 0);
    defer grid.grid_free(gd);

    const u = fmt_resolve.grid_storage_usage(gd);
    try std.testing.expectEqual(gd.linedata.len, u.lines);
    try std.testing.expect(u.totalBytes() >= u.line_bytes);
}

test "format_grid_line joins non-padding cells on a row" {
    const gd = grid.grid_create(8, 1, 0);
    defer grid.grid_free(gd);

    const text = "zmux";
    for (text, 0..) |ch, i| {
        grid.set_ascii(gd, 0, @intCast(i), ch);
    }

    const got = fmt_resolve.format_grid_line(xm.allocator, gd, 0).?;
    defer xm.allocator.free(got);
    try std.testing.expectEqualStrings(text, got);
}

test "format_grid_word collects word bounded by separators" {
    const gd = grid.grid_create(16, 1, 0);
    defer grid.grid_free(gd);

    // "foo bar" — pick the middle of "bar"
    const line = "foo bar";
    for (line, 0..) |ch, i| {
        grid.set_ascii(gd, 0, @intCast(i), ch);
    }

    // Column 5 is inside "bar" in "foo bar"
    const got = fmt_resolve.format_grid_word(xm.allocator, gd, 5, 0, " \t").?;
    defer xm.allocator.free(got);
    try std.testing.expectEqualStrings("bar", got);
}
