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

//! Parse coverage for high-traffic commands that lack dedicated suites.

const std = @import("std");
const cmd_mod = @import("cmd.zig");

fn parseName(argv: []const []const u8) ![]const u8 {
    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(argv, null, &cause);
    defer cmd_mod.cmd_free(cmd);
    return cmd.entry.name;
}

test "kill-window command parses target flag" {
    try std.testing.expectEqualStrings("kill-window", try parseName(&.{ "kill-window", "-t", "mysess:0" }));
}

test "kill-pane command parses target flag" {
    try std.testing.expectEqualStrings("kill-pane", try parseName(&.{ "kill-pane", "-t", "%42" }));
}

test "swap-pane command parses directional flag" {
    try std.testing.expectEqualStrings("swap-pane", try parseName(&.{ "swap-pane", "-D" }));
}

test "resize-pane command parses size flag" {
    try std.testing.expectEqualStrings("resize-pane", try parseName(&.{ "resize-pane", "-x", "120" }));
}

test "pipe-pane command parses no flag shell command" {
    try std.testing.expectEqualStrings("pipe-pane", try parseName(&.{ "pipe-pane", "cat" }));
}

test "kill-server command parses without arguments" {
    try std.testing.expectEqualStrings("kill-server", try parseName(&.{"kill-server"}));
}

test "capture-pane command parses target and line range" {
    try std.testing.expectEqualStrings("capture-pane", try parseName(&.{ "capture-pane", "-t", "%0", "-S", "-10" }));
}

test "find-window command parses match string and flags" {
    try std.testing.expectEqualStrings("find-window", try parseName(&.{ "find-window", "-N", "vim" }));
}

test "show-hooks command parses target pane" {
    try std.testing.expectEqualStrings("show-hooks", try parseName(&.{ "show-hooks", "-t", "%0" }));
}

test "list-commands command parses format flag" {
    try std.testing.expectEqualStrings("list-commands", try parseName(&.{ "list-commands", "-F", "#{command_list_name}" }));
}
