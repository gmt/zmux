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

//! options-test.zig – unit tests for options.zig.

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const opts = @import("options.zig");

test "options_create child inherits parent values until overridden" {
    const parent = opts.options_create(null);
    defer opts.options_free(parent);
    opts.options_default_all(parent, T.OPTIONS_TABLE_WINDOW);
    opts.options_set_string(parent, false, "word-separators", "PARENT");

    const child = opts.options_create(parent);
    defer opts.options_free(child);

    try std.testing.expectEqualStrings("PARENT", opts.options_get_string(child, "word-separators"));

    opts.options_set_string(child, false, "word-separators", "CHILD");
    try std.testing.expectEqualStrings("CHILD", opts.options_get_string(child, "word-separators"));
}

test "options_map_name normalizes documented color spellings" {
    try std.testing.expectEqualStrings("cursor-colour", opts.options_map_name("cursor-color"));
    try std.testing.expectEqualStrings("pane-colours", opts.options_map_name("pane-colors"));
}

test "options_set_from_string rejects invalid numbers for pane-base-index" {
    const oo = opts.options_create(null);
    defer opts.options_free(oo);
    opts.options_default_all(oo, T.OPTIONS_TABLE_WINDOW);

    const oe = opts.options_table_entry("pane-base-index").?;
    var cause: ?[]u8 = null;
    defer if (cause) |c| xm.allocator.free(c);

    try std.testing.expect(!opts.options_set_from_string(oo, oe, "pane-base-index", null, "not-a-number", false, &cause));
    try std.testing.expect(cause != null);

    try std.testing.expect(opts.options_set_from_string(oo, oe, "pane-base-index", null, "4", false, &cause));
    try std.testing.expectEqual(@as(i64, 4), opts.options_get_number(oo, "pane-base-index"));
}

test "options_parse_number and options_parse_boolish accept common forms" {
    try std.testing.expectEqual(@as(i64, -2), opts.options_parse_number("-2").?);
    try std.testing.expect(opts.options_parse_boolish("yes").? == true);
    try std.testing.expect(opts.options_parse_boolish("off").? == false);
}
