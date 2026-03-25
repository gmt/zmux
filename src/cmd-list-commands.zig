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
// Ported from tmux/cmd-list-commands.c
// Original copyright:
//   Copyright (c) 2007 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const cmd_mod = @import("cmd.zig");
const cmdq = @import("cmd-queue.zig");

fn exec(cmd: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {
    const args = cmd_mod.cmd_get_args(cmd);
    if (args.has('F')) {
        cmdq.cmdq_error(item, "format not supported yet", .{});
        return .@"error";
    }

    const lines = collect_lines(args.value_at(0)) catch |err| {
        switch (err) {
            error.UnknownCommand => cmdq.cmdq_error(item, "unknown command: {s}", .{args.value_at(0).?}),
            else => unreachable,
        }
        return .@"error";
    };
    defer free_lines(lines);

    for (lines) |line| {
        cmdq.cmdq_print(item, "{s}", .{line});
    }
    return .normal;
}

fn collect_lines(name: ?[]const u8) ![][]u8 {
    var lines: std.ArrayList([]u8) = .{};
    if (name) |command_name| {
        const found_entry = cmd_mod.cmd_find_entry(command_name) orelse return error.UnknownCommand;
        lines.append(xm.allocator, render_entry(found_entry)) catch unreachable;
        return lines.toOwnedSlice(xm.allocator) catch unreachable;
    }

    for (cmd_mod.cmd_entries()) |cmd_entry| {
        lines.append(xm.allocator, render_entry(cmd_entry)) catch unreachable;
    }
    return lines.toOwnedSlice(xm.allocator) catch unreachable;
}

fn render_entry(cmd_entry: *const cmd_mod.CmdEntry) []u8 {
    if (cmd_entry.alias) |alias| {
        if (cmd_entry.usage.len == 0) return xm.xasprintf("{s} ({s})", .{ cmd_entry.name, alias });
        return xm.xasprintf("{s} ({s}) {s}", .{ cmd_entry.name, alias, cmd_entry.usage });
    }
    if (cmd_entry.usage.len == 0) return xm.xasprintf("{s}", .{cmd_entry.name});
    return xm.xasprintf("{s} {s}", .{ cmd_entry.name, cmd_entry.usage });
}

fn free_lines(lines: [][]u8) void {
    for (lines) |line| xm.allocator.free(line);
    xm.allocator.free(lines);
}

pub const entry: cmd_mod.CmdEntry = .{
    .name = "list-commands",
    .alias = "lscm",
    .usage = "[-F format] [command]",
    .template = "F:",
    .lower = 0,
    .upper = 1,
    .flags = T.CMD_STARTSERVER | T.CMD_AFTERHOOK,
    .exec = exec,
};

test "list-commands renders alias and usage metadata" {
    const line = render_entry(cmd_mod.cmd_find_entry("list-keys").?);
    defer xm.allocator.free(line);
    try std.testing.expectEqualStrings(
        "list-keys (lsk) [-1aNr] [-F format] [-O order] [-P prefix-string] [-T key-table] [key]",
        line,
    );

    const kill_line = render_entry(cmd_mod.cmd_find_entry("kill-server").?);
    defer xm.allocator.free(kill_line);
    try std.testing.expectEqualStrings("kill-server", kill_line);
}

test "list-commands single lookup and unknown command behavior" {
    const single = try collect_lines("bind-key");
    defer free_lines(single);
    try std.testing.expectEqual(@as(usize, 1), single.len);
    try std.testing.expectEqualStrings(
        "bind-key (bind) [-nr] [-T key-table] [-N note] key [command [arguments]]",
        single[0],
    );

    try std.testing.expectError(error.UnknownCommand, collect_lines("definitely-not-real"));
}

test "list-commands rejects format for now" {
    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "list-commands", "-F", "#{command_list_name}" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.@"error", cmd_mod.cmd_execute(cmd, &item));
}

test "cmd entries include list-commands metadata" {
    const entries = cmd_mod.cmd_entries();
    try std.testing.expect(entries.len > 0);
    const entry_ptr = cmd_mod.cmd_find_entry("list-commands").?;
    try std.testing.expectEqualStrings("list-commands", entry_ptr.name);
    try std.testing.expectEqualStrings("[-F format] [command]", entry_ptr.usage);
}
