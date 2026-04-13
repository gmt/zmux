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

//! Umbrella coverage for buffer, environment, and option command families.

const std = @import("std");
const cmd_mod = @import("cmd.zig");

fn parseName(argv: []const []const u8) ![]const u8 {
    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(argv, null, &cause);
    defer cmd_mod.cmd_free(cmd);
    return cmd.entry.name;
}

test {
    _ = @import("cmd-set-buffer.zig");
    _ = @import("cmd-save-buffer.zig");
    _ = @import("cmd-load-buffer.zig");
    _ = @import("cmd-paste-buffer.zig");
    _ = @import("cmd-list-buffers.zig");
    _ = @import("cmd-set-environment.zig");
    _ = @import("cmd-show-environment.zig");
    _ = @import("cmd-set-option.zig");
    _ = @import("cmd-show-options.zig");
}

test "list-buffers command parses format flag" {
    try std.testing.expectEqualStrings("list-buffers", try parseName(&.{ "list-buffers", "-F", "#{buffer_name}" }));
}

test "save-buffer command parses buffer name and path" {
    try std.testing.expectEqualStrings("save-buffer", try parseName(&.{ "save-buffer", "-b", "paste1", "/tmp/zmux-save-test" }));
}

test "load-buffer command parses buffer name and path" {
    try std.testing.expectEqualStrings("load-buffer", try parseName(&.{ "load-buffer", "-b", "paste1", "/tmp/zmux-load-test" }));
}

test "show-buffer command parses buffer name" {
    try std.testing.expectEqualStrings("show-buffer", try parseName(&.{ "show-buffer", "-b", "buf0" }));
}

test "show-options command parses global and option name" {
    try std.testing.expectEqualStrings("show-options", try parseName(&.{ "show-options", "-g", "status-left" }));
}

test "show-environment command parses -g" {
    try std.testing.expectEqualStrings("show-environment", try parseName(&.{ "show-environment", "-g" }));
}

test "set-environment -g exec stores a variable in the global environ" {
    const T = @import("types.zig");
    const env_mod = @import("environ.zig");
    const cmdq = @import("cmd-queue.zig");

    env_mod.global_environ = env_mod.environ_create();
    defer env_mod.environ_free(env_mod.global_environ);

    var cause: ?[]u8 = null;
    const set_cmd = try cmd_mod.cmd_parse_one(&.{ "set-environment", "-g", "ZMUX_SWEEP_VAR", "sweep-value" }, null, &cause);
    defer cmd_mod.cmd_free(set_cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(set_cmd, &item));

    const found = env_mod.environ_find(env_mod.global_environ, "ZMUX_SWEEP_VAR");
    try std.testing.expect(found != null);
    try std.testing.expectEqualStrings("sweep-value", found.?.value.?);

    // Verify -u removes the entry entirely
    const unset_cmd = try cmd_mod.cmd_parse_one(&.{ "set-environment", "-gu", "ZMUX_SWEEP_VAR" }, null, &cause);
    defer cmd_mod.cmd_free(unset_cmd);
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(unset_cmd, &item));
    try std.testing.expect(env_mod.environ_find(env_mod.global_environ, "ZMUX_SWEEP_VAR") == null);
}
