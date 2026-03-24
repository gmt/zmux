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
// Ported from tmux/names.c
// Original copyright:
//   Copyright (c) 2009 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");

pub fn check_window_name(_w: *T.Window) void {
    _ = _w;
    // Full automatic-rename timer and redraw logic is deferred.
}

pub fn default_window_name(w: *T.Window) []u8 {
    const wp = w.active orelse return xm.xstrdup("");
    if (wp.argv) |argv| {
        if (cmd_stringify_argv(argv)) |cmd| {
            defer xm.allocator.free(cmd);
            return parse_window_name(cmd);
        }
    }
    return parse_window_name(wp.shell orelse "");
}

pub fn parse_window_name(input: []const u8) []u8 {
    var name = input;
    if (name.len > 0 and name[0] == '"') name = name[1..];
    if (std.mem.indexOfScalar(u8, name, '"')) |idx| name = name[0..idx];

    if (std.mem.startsWith(u8, name, "exec "))
        name = name["exec ".len..];

    while (name.len > 0 and (name[0] == ' ' or name[0] == '-'))
        name = name[1..];

    if (std.mem.indexOfScalar(u8, name, ' ')) |idx|
        name = name[0..idx];

    if (name.len > 0) {
        var end = name.len;
        while (end > 1 and !is_name_char(name[end - 1]))
            end -= 1;
        name = name[0..end];
    }

    if (name.len > 0 and name[0] == '/')
        name = std.fs.path.basenamePosix(name);

    return xm.xstrdup(name);
}

fn cmd_stringify_argv(argv: []const []u8) ?[]u8 {
    if (argv.len == 0) return null;

    var len: usize = 0;
    for (argv, 0..) |arg, i| {
        len += arg.len;
        if (i + 1 < argv.len) len += 1;
    }

    var buf = xm.allocator.alloc(u8, len) catch unreachable;
    var pos: usize = 0;
    for (argv, 0..) |arg, i| {
        @memcpy(buf[pos .. pos + arg.len], arg);
        pos += arg.len;
        if (i + 1 < argv.len) {
            buf[pos] = ' ';
            pos += 1;
        }
    }
    return buf;
}

fn is_name_char(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or is_ascii_punctuation(ch);
}

fn is_ascii_punctuation(ch: u8) bool {
    return (ch >= '!' and ch <= '/') or
        (ch >= ':' and ch <= '@') or
        (ch >= '[' and ch <= '`') or
        (ch >= '{' and ch <= '~');
}

test "parse_window_name strips quotes exec prefix and path" {
    const out = parse_window_name("\"exec /usr/bin/zsh -l\"");
    defer xm.allocator.free(out);
    try std.testing.expectEqualStrings("zsh", out);
}

test "parse_window_name trims leading dashes and trailing junk" {
    const out = parse_window_name("  -git!!!   ");
    defer xm.allocator.free(out);
    try std.testing.expectEqualStrings("git!!!", out);
}
