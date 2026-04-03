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

test "options_parse extracts bracket index and copies plain names" {
    var idx: ?u32 = null;
    const plain = opts.options_parse("word-separators", &idx) orelse return error.TestUnexpectedResult;
    defer xm.allocator.free(plain);
    try std.testing.expectEqual(@as(?u32, null), idx);
    try std.testing.expectEqualStrings("word-separators", plain);

    const indexed = opts.options_parse("command-alias[2]", &idx) orelse return error.TestUnexpectedResult;
    defer xm.allocator.free(indexed);
    try std.testing.expectEqualStrings("command-alias", indexed);
    try std.testing.expectEqual(@as(?u32, 2), idx);
}

test "options_parse rejects empty and malformed bracket names" {
    var idx: ?u32 = null;
    try std.testing.expect(opts.options_parse("", &idx) == null);
    try std.testing.expect(opts.options_parse("x[1", &idx) == null);
    try std.testing.expect(opts.options_parse("x[a]", &idx) == null);
    try std.testing.expect(opts.options_parse("x[]", &idx) == null);
    try std.testing.expect(opts.options_parse("x[1]z", &idx) == null);
}

test "options_match preserves at-prefixed names" {
    var idx: ?u32 = null;
    var ambiguous = false;
    const name = opts.options_match("@myopt", &idx, &ambiguous) orelse return error.TestUnexpectedResult;
    defer xm.allocator.free(name);
    try std.testing.expect(!ambiguous);
    try std.testing.expectEqualStrings("@myopt", name);
}

test "options_match resolves exact table names" {
    var idx: ?u32 = null;
    var ambiguous = false;
    const name = opts.options_match("status", &idx, &ambiguous) orelse return error.TestUnexpectedResult;
    defer xm.allocator.free(name);
    try std.testing.expect(!ambiguous);
    try std.testing.expectEqualStrings("status", name);
}

test "options_match marks ambiguous when prefix matches multiple options" {
    var idx: ?u32 = null;
    var ambiguous = false;
    const name = opts.options_match("message", &idx, &ambiguous);
    defer if (name) |n| xm.allocator.free(n);
    try std.testing.expect(ambiguous);
    try std.testing.expect(name == null);
}

test "options_get_only sees mapped colour aliases without parent walk" {
    const oo = opts.options_create(null);
    defer opts.options_free(oo);
    opts.options_set_string(oo, false, "cursor-colour", "red");
    const v = opts.options_get_only(oo, "cursor-color");
    try std.testing.expect(v != null);
    try std.testing.expectEqualStrings("red", opts.options_get_string(oo, "cursor-colour"));
}

test "options_get walks parent options_get_only does not" {
    const parent = opts.options_create(null);
    defer opts.options_free(parent);
    opts.options_set_string(parent, false, "word-separators", "P");

    const child = opts.options_create(parent);
    defer opts.options_free(child);

    try std.testing.expectEqualStrings("P", opts.options_get_string(child, "word-separators"));
    try std.testing.expect(opts.options_get_only(child, "word-separators") == null);
}

test "options_parse_get and options_match_get resolve indexed and matched names" {
    const oo = opts.options_create(null);
    defer opts.options_free(oo);
    opts.options_default_all(oo, T.OPTIONS_TABLE_SERVER);
    const oe = opts.options_table_entry("command-alias").?;
    var cause: ?[]u8 = null;
    defer if (cause) |c| xm.allocator.free(c);
    try std.testing.expect(opts.options_set_from_string(oo, oe, "command-alias", null, "one,two", false, &cause));

    var idx: ?u32 = null;
    const v_parse = opts.options_parse_get(oo, "command-alias[0]", &idx, false);
    try std.testing.expect(v_parse != null);
    try std.testing.expectEqual(@as(?u32, 0), idx);

    var amb = false;
    idx = null;
    const v_match = opts.options_match_get(oo, "command-alias", &idx, false, &amb);
    try std.testing.expect(v_match != null);
    try std.testing.expect(!amb);
}

test "options_scope_has reflects server session window pane bits" {
    const oe_server = opts.options_table_entry("buffer-limit").?;
    const oe_sess = opts.options_table_entry("status").?;
    const oe_win = opts.options_table_entry("cursor-style").?;
    try std.testing.expect(opts.options_scope_has(T.OPTIONS_TABLE_SERVER, oe_server));
    try std.testing.expect(!opts.options_scope_has(T.OPTIONS_TABLE_SESSION, oe_server));
    try std.testing.expect(opts.options_scope_has(T.OPTIONS_TABLE_SESSION, oe_sess));
    try std.testing.expect(opts.options_scope_has(T.OPTIONS_TABLE_WINDOW, oe_win));
}

test "options_choice_index accepts case-insensitive choice names and numeric indices" {
    const oe = opts.options_table_entry("extended-keys").?;
    try std.testing.expectEqual(@as(u32, 1), opts.options_choice_index(oe, "on").?);
    try std.testing.expectEqual(@as(u32, 2), opts.options_choice_index(oe, "ALWAYS").?);
    try std.testing.expectEqual(@as(u32, 0), opts.options_choice_index(oe, "0").?);
    try std.testing.expect(opts.options_choice_index(oe, "nope") == null);
}

test "options_find_choice is case sensitive" {
    const oe = opts.options_table_entry("extended-keys").?;
    var cause: ?[]u8 = null;
    defer if (cause) |c| xm.allocator.free(c);
    try std.testing.expectEqual(@as(u32, 1), opts.options_find_choice(oe, "on", &cause).?);
    try std.testing.expect(opts.options_find_choice(oe, "ON", &cause) == null);
    try std.testing.expect(cause != null);
}

test "options_set_from_string bool flag and choice paths" {
    const oo = opts.options_create(null);
    defer opts.options_free(oo);
    var cause: ?[]u8 = null;
    defer if (cause) |c| xm.allocator.free(c);

    const oe_mouse = opts.options_table_entry("mouse").?; // session flag
    try std.testing.expect(opts.options_set_from_string(oo, oe_mouse, "mouse", null, "off", false, &cause));
    try std.testing.expectEqual(@as(i64, 0), opts.options_get_number(oo, "mouse"));

    const oe_ext = opts.options_table_entry("extended-keys").?;
    try std.testing.expect(opts.options_set_from_string(oo, oe_ext, "extended-keys", null, "always", false, &cause));
    try std.testing.expectEqual(@as(i64, 2), opts.options_get_number(oo, "extended-keys"));
}

test "options_set_from_string colour accepts named colour" {
    const oo = opts.options_create(null);
    defer opts.options_free(oo);
    const oe = opts.options_table_entry("message-style").?;
    var cause: ?[]u8 = null;
    defer if (cause) |c| xm.allocator.free(c);
    try std.testing.expect(opts.options_set_from_string(oo, oe, "message-style", null, "bg=black,fg=red", false, &cause));
    const s = opts.options_to_string(oo, "message-style", null, false);
    defer xm.allocator.free(s);
    try std.testing.expect(s.len > 0);
}

test "options_set_array append_array get_array_item and to_string" {
    const oo = opts.options_create(null);
    defer opts.options_free(oo);
    opts.options_set_array(oo, "user-keys", &.{ "a", "b" });
    try std.testing.expectEqualStrings("a", opts.options_get_array_item(oo, "user-keys", 0).?);
    try std.testing.expectEqualStrings("b", opts.options_get_array_item(oo, "user-keys", 1).?);
    opts.options_append_array(oo, "user-keys", "c");
    try std.testing.expectEqualStrings("c", opts.options_get_array_item(oo, "user-keys", 2).?);
    const joined = opts.options_to_string(oo, "user-keys", null, false);
    defer xm.allocator.free(joined);
    try std.testing.expect(std.mem.indexOf(u8, joined, "a") != null);
    try std.testing.expect(std.mem.indexOf(u8, joined, "c") != null);
}

test "options_remove_or_default removes whole option or array slot" {
    const oo = opts.options_create(null);
    defer opts.options_free(oo);
    const oe = opts.options_table_entry("command-alias").?;
    var cause: ?[]u8 = null;
    defer if (cause) |c| xm.allocator.free(c);
    try std.testing.expect(opts.options_set_from_string(oo, oe, "command-alias", null, "x,y", false, &cause));
    try std.testing.expect(opts.options_remove_or_default(oo, oe, "command-alias", 0, false, &cause));
    try std.testing.expect(opts.options_get_array_item(oo, "command-alias", 0) == null);

    try std.testing.expect(opts.options_remove_or_default(oo, oe, "command-alias", null, false, &cause));
    try std.testing.expect(opts.options_get(oo, "command-alias") == null);
}

test "options_remove_or_default rejects index on non-array" {
    const oo = opts.options_create(null);
    defer opts.options_free(oo);
    opts.options_set_string(oo, false, "word-separators", "x");
    var cause: ?[]u8 = null;
    defer if (cause) |c| xm.allocator.free(c);
    try std.testing.expect(!opts.options_remove_or_default(oo, null, "word-separators", 0, false, &cause));
    try std.testing.expect(cause != null);
}

test "options_default resets a single entry from table" {
    const oo = opts.options_create(null);
    defer opts.options_free(oo);
    const oe = opts.options_table_entry("pane-base-index").?;
    opts.options_default(oo, oe);
    try std.testing.expectEqual(@as(i64, 0), opts.options_get_number(oo, "pane-base-index"));
    opts.options_set_number(oo, "pane-base-index", 9);
    opts.options_default(oo, oe);
    try std.testing.expectEqual(@as(i64, 0), opts.options_get_number(oo, "pane-base-index"));
}

test "options_parent_table_entry finds upstream table entry" {
    const parent = opts.options_create(null);
    defer opts.options_free(parent);
    opts.options_set_string(parent, false, "word-separators", "UP");

    const child = opts.options_create(parent);
    defer opts.options_free(child);

    const oe = opts.options_parent_table_entry(child, "word-separators");
    try std.testing.expect(oe != null);
    try std.testing.expectEqualStrings("word-separators", oe.?.name);
}

test "options_first and options_next iterate local keys in order" {
    const oo = opts.options_create(null);
    defer opts.options_free(oo);
    opts.options_set_string(oo, false, "zebra", "z");
    opts.options_set_string(oo, false, "alpha", "a");

    const first = opts.options_first(oo) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("alpha", opts.options_name(first));

    const second = opts.options_next(first) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("zebra", opts.options_name(second));
    try std.testing.expect(opts.options_next(second) == null);
}

test "options_empty creates typed empty slot" {
    const oo = opts.options_create(null);
    defer opts.options_free(oo);
    const oe = opts.options_table_entry("command-alias").?;
    opts.options_empty(oo, oe);
    const items = opts.options_get_array_items(oo, "command-alias");
    try std.testing.expectEqual(@as(usize, 0), items.len);
}

test "options_is_string and options_is_array match table kinds" {
    try std.testing.expect(opts.options_is_string(null));
    try std.testing.expect(opts.options_is_string(opts.options_table_entry("word-separators")));
    try std.testing.expect(!opts.options_is_array(opts.options_table_entry("word-separators")));
    try std.testing.expect(opts.options_is_array(opts.options_table_entry("command-alias")));
}

test "options_from_string_flag toggles and parses boolish" {
    const oo = opts.options_create(null);
    defer opts.options_free(oo);
    opts.options_default_all(oo, T.OPTIONS_TABLE_SESSION);
    var cause: ?[]u8 = null;
    defer if (cause) |c| xm.allocator.free(c);
    try std.testing.expect(opts.options_from_string_flag(oo, "mouse", "no", &cause));
    try std.testing.expectEqual(@as(i64, 0), opts.options_get_number(oo, "mouse"));
}

test "options_value_to_string formats choice and bool-like numbers" {
    const oo = opts.options_create(null);
    defer opts.options_free(oo);
    const oe = opts.options_table_entry("extended-keys").?;
    opts.options_set_number(oo, "extended-keys", 2);
    const v = opts.options_get(oo, "extended-keys").?;
    const s = opts.options_value_to_string("extended-keys", v, oe);
    defer xm.allocator.free(s);
    try std.testing.expectEqualStrings("always", s);
}

test "options_cmp orders entry names" {
    const oo = opts.options_create(null);
    defer opts.options_free(oo);
    opts.options_set_string(oo, false, "b", "1");
    opts.options_set_string(oo, false, "a", "2");
    const ea = opts.OptionsEntry{ .oo = oo, .name = "a" };
    const eb = opts.OptionsEntry{ .oo = oo, .name = "b" };
    try std.testing.expect(opts.options_cmp(ea, eb) == .lt);
}

test "options_get_number reads back set numeric option" {
    const oo = opts.options_create(null);
    defer opts.options_free(oo);
    opts.options_default_all(oo, T.OPTIONS_TABLE_WINDOW);
    opts.options_set_number(oo, "pane-base-index", 7);
    try std.testing.expectEqual(@as(i64, 7), opts.options_get_number(oo, "pane-base-index"));
}
