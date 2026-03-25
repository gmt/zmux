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
// Written for zmux by Greg Turner. This file is new shared rendering work
// for shell-quoted words, argv joining, and argument rendering.

const std = @import("std");
const args_mod = @import("arguments.zig");
const xm = @import("xmalloc.zig");

pub fn stringify_argv(alloc: std.mem.Allocator, argv: []const []const u8) []u8 {
    if (argv.len == 0) return alloc.dupe(u8, "") catch unreachable;

    var len: usize = 0;
    for (argv, 0..) |arg, idx| {
        len += arg.len;
        if (idx + 1 < argv.len) len += 1;
    }

    const out = alloc.alloc(u8, len) catch unreachable;
    var pos: usize = 0;
    for (argv, 0..) |arg, idx| {
        @memcpy(out[pos .. pos + arg.len], arg);
        pos += arg.len;
        if (idx + 1 < argv.len) {
            out[pos] = ' ';
            pos += 1;
        }
    }
    return out;
}

pub fn append_arguments(out: *std.ArrayList(u8), args: *const args_mod.Arguments) void {
    var flags: std.ArrayList(u8) = .{};
    defer flags.deinit(xm.allocator);

    var it = args.flags.iterator();
    while (it.next()) |flag_entry| flags.append(xm.allocator, flag_entry.key_ptr.*) catch unreachable;
    std.sort.block(u8, flags.items, {}, less_than_u8);

    for (flags.items) |flag| {
        const values = args.flags.get(flag).?;
        for (values.items) |value| {
            out.appendSlice(xm.allocator, " -") catch unreachable;
            out.append(xm.allocator, flag) catch unreachable;
            if (value.len != 0) {
                out.append(xm.allocator, ' ') catch unreachable;
                append_shell_word(out, value);
            }
        }
    }

    for (args.values.items) |value| {
        out.append(xm.allocator, ' ') catch unreachable;
        append_shell_word(out, value);
    }
}

pub fn append_shell_word(out: *std.ArrayList(u8), word: []const u8) void {
    if (!needs_quotes(word)) {
        out.appendSlice(xm.allocator, word) catch unreachable;
        return;
    }

    out.append(xm.allocator, '"') catch unreachable;
    for (word) |ch| {
        switch (ch) {
            '\\', '"' => {
                out.append(xm.allocator, '\\') catch unreachable;
                out.append(xm.allocator, ch) catch unreachable;
            },
            '\n' => out.appendSlice(xm.allocator, "\\n") catch unreachable,
            '\t' => out.appendSlice(xm.allocator, "\\t") catch unreachable,
            else => out.append(xm.allocator, ch) catch unreachable,
        }
    }
    out.append(xm.allocator, '"') catch unreachable;
}

pub fn needs_quotes(word: []const u8) bool {
    if (word.len == 0) return true;
    for (word) |ch| {
        if (std.ascii.isWhitespace(ch) or ch == '"' or ch == '\\' or ch == ';')
            return true;
    }
    return false;
}

fn less_than_u8(_: void, a: u8, b: u8) bool {
    return a < b;
}

test "append_arguments renders flags and quoted values" {
    var args = args_mod.Arguments.init(xm.allocator);
    defer args.deinit();

    var a_values: std.ArrayList([]u8) = .{};
    a_values.append(xm.allocator, xm.xstrdup("hello world")) catch unreachable;
    args.flags.put('a', a_values) catch unreachable;
    args.values.append(xm.allocator, xm.xstrdup("plain")) catch unreachable;

    var out: std.ArrayList(u8) = .{};
    defer out.deinit(xm.allocator);
    append_arguments(&out, &args);
    const rendered = out.toOwnedSlice(xm.allocator) catch unreachable;
    defer xm.allocator.free(rendered);
    try std.testing.expectEqualStrings(" -a \"hello world\" plain", rendered);
}

test "stringify_argv joins words with spaces" {
    const rendered = stringify_argv(xm.allocator, &.{ "exec", "/bin/sh", "-l" });
    defer xm.allocator.free(rendered);
    try std.testing.expectEqualStrings("exec /bin/sh -l", rendered);
}
