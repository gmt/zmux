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
const cmd_mod = @import("cmd.zig");
const cmdq = @import("cmd-queue.zig");
const format_mod = @import("format.zig");

const DEFAULT_TEMPLATE = "#{command_name}#{?command_alias, (#{command_alias}),}#{?command_usage, #{command_usage},}";

fn exec(cmd: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {
    const args = cmd_mod.cmd_get_args(cmd);
    const template = args.get('F') orelse DEFAULT_TEMPLATE;

    if (args.value_at(0)) |command_name| {
        const found_entry = cmd_mod.cmd_find_entry(command_name) orelse {
            cmdq.cmdq_error(item, "unknown command: {s}", .{command_name});
            return .@"error";
        };
        const line = render_entry(found_entry, template) orelse {
            cmdq.cmdq_error(item, "format expansion not supported yet", .{});
            return .@"error";
        };
        defer std.heap.c_allocator.free(line);
        cmdq.cmdq_print(item, "{s}", .{line});
        return .normal;
    }

    for (cmd_mod.cmd_entries()) |cmd_entry| {
        const line = render_entry(cmd_entry, template) orelse {
            cmdq.cmdq_error(item, "format expansion not supported yet", .{});
            return .@"error";
        };
        defer std.heap.c_allocator.free(line);
        cmdq.cmdq_print(item, "{s}", .{line});
    }
    return .normal;
}

fn render_entry(cmd_entry: *const cmd_mod.CmdEntry, template: []const u8) ?[]u8 {
    const ctx = format_mod.FormatContext{
        .command_name = cmd_entry.name,
        .command_alias = cmd_entry.alias,
        .command_usage = cmd_entry.usage,
    };
    return format_mod.format_require_complete(std.heap.c_allocator, template, &ctx);
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
    const line = render_entry(cmd_mod.cmd_find_entry("list-keys").?, DEFAULT_TEMPLATE).?;
    defer std.heap.c_allocator.free(line);
    try std.testing.expectEqualStrings(
        "list-keys (lsk) [-1aNr] [-F format] [-O order] [-P prefix-string] [-T key-table] [key]",
        line,
    );

    const kill_line = render_entry(cmd_mod.cmd_find_entry("kill-server").?, DEFAULT_TEMPLATE).?;
    defer std.heap.c_allocator.free(kill_line);
    try std.testing.expectEqualStrings("kill-server", kill_line);
}

test "list-commands single lookup and unknown command behavior" {
    const single = render_entry(cmd_mod.cmd_find_entry("bind-key").?, DEFAULT_TEMPLATE).?;
    defer std.heap.c_allocator.free(single);
    try std.testing.expectEqualStrings(
        "bind-key (bind) [-nr] [-T key-table] [-N note] key [command [arguments]]",
        single,
    );

    try std.testing.expect(cmd_mod.cmd_find_entry("definitely-not-real") == null);
}

test "list-commands supports custom format templates" {
    const line = render_entry(cmd_mod.cmd_find_entry("list-commands").?, "#{command_name}:#{command_alias}").?;
    defer std.heap.c_allocator.free(line);
    try std.testing.expectEqualStrings("list-commands:lscm", line);

    const unresolved = render_entry(cmd_mod.cmd_find_entry("list-commands").?, "#{command_name}:#{definitely_missing}");
    try std.testing.expect(unresolved == null);
}

test "cmd entries include list-commands metadata" {
    const entries = cmd_mod.cmd_entries();
    try std.testing.expect(entries.len > 0);
    const entry_ptr = cmd_mod.cmd_find_entry("list-commands").?;
    try std.testing.expectEqualStrings("list-commands", entry_ptr.name);
    try std.testing.expectEqualStrings("[-F format] [command]", entry_ptr.usage);
}
