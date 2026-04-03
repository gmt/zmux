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

test "move-window command parses session and window flags" {
    try std.testing.expectEqualStrings("move-window", try parseName(&.{ "move-window", "-s", "src:1", "-t", "dst:2" }));
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

test "list-buffers command parses format flag" {
    try std.testing.expectEqualStrings("list-buffers", try parseName(&.{ "list-buffers", "-F", "#{buffer_name}" }));
}

test "kill-server command parses without arguments" {
    try std.testing.expectEqualStrings("kill-server", try parseName(&.{"kill-server"}));
}

test "kill-session command parses target flag" {
    try std.testing.expectEqualStrings("kill-session", try parseName(&.{ "kill-session", "-t", "foo" }));
}

test "list-clients command parses format flag" {
    try std.testing.expectEqualStrings("list-clients", try parseName(&.{ "list-clients", "-F", "#{client_name}" }));
}

test "new-window command parses shell flag" {
    try std.testing.expectEqualStrings("new-window", try parseName(&.{ "new-window", "-n", "win", "vi" }));
}

test "start-server command parses bare invocation" {
    try std.testing.expectEqualStrings("start-server", try parseName(&.{"start-server"}));
}

test "attach-session command parses target and cwd flags" {
    try std.testing.expectEqualStrings("attach-session", try parseName(&.{ "attach-session", "-t", "mysess", "-c", "/tmp" }));
}

test "switch-client command parses target session flag" {
    try std.testing.expectEqualStrings("switch-client", try parseName(&.{ "switch-client", "-t", "mysess" }));
}

test "display-message command parses format and message" {
    try std.testing.expectEqualStrings("display-message", try parseName(&.{ "display-message", "-F", "#{pane_id}", "hello" }));
}

test "capture-pane command parses target and line range" {
    try std.testing.expectEqualStrings("capture-pane", try parseName(&.{ "capture-pane", "-t", "%0", "-S", "-10" }));
}

test "save-buffer command parses buffer name and path" {
    try std.testing.expectEqualStrings("save-buffer", try parseName(&.{ "save-buffer", "-b", "paste1", "/tmp/zmux-save-test" }));
}

test "load-buffer command parses buffer name and path" {
    try std.testing.expectEqualStrings("load-buffer", try parseName(&.{ "load-buffer", "-b", "paste1", "/tmp/zmux-load-test" }));
}

test "refresh-client command parses target flag" {
    try std.testing.expectEqualStrings("refresh-client", try parseName(&.{ "refresh-client", "-t", "client0" }));
}

test "find-window command parses match string and flags" {
    try std.testing.expectEqualStrings("find-window", try parseName(&.{ "find-window", "-N", "vim" }));
}

test "show-buffer command parses buffer name" {
    try std.testing.expectEqualStrings("show-buffer", try parseName(&.{ "show-buffer", "-b", "buf0" }));
}

test "select-window command parses target window" {
    try std.testing.expectEqualStrings("select-window", try parseName(&.{ "select-window", "-t", ":1" }));
}

test "show-options command parses global and option name" {
    try std.testing.expectEqualStrings("show-options", try parseName(&.{ "show-options", "-g", "status-left" }));
}

test "next-window command parses session target" {
    try std.testing.expectEqualStrings("next-window", try parseName(&.{ "next-window", "-t", "foo" }));
}

test "show-hooks command parses target pane" {
    try std.testing.expectEqualStrings("show-hooks", try parseName(&.{ "show-hooks", "-t", "%0" }));
}

test "list-commands command parses format flag" {
    try std.testing.expectEqualStrings("list-commands", try parseName(&.{ "list-commands", "-F", "#{command_list_name}" }));
}

test "show-environment command parses -g" {
    try std.testing.expectEqualStrings("show-environment", try parseName(&.{ "show-environment", "-g" }));
}

test "list-sessions command parses format flag" {
    try std.testing.expectEqualStrings("list-sessions", try parseName(&.{ "list-sessions", "-F", "#{session_name}" }));
}
