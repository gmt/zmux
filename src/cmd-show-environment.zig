// Copyright (c) 2026 Greg Turner <gmt@pobox.com>
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
// Ported in part from tmux/cmd-show-environment.c
// Original copyright:
//   Copyright (c) 2009 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const cmd_mod = @import("cmd.zig");
const cmdq = @import("cmd-queue.zig");
const cmd_find = @import("cmd-find.zig");
const env_mod = @import("environ.zig");

fn exec(cmd: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {
    const args = cmd_mod.cmd_get_args(cmd);
    const env = resolve_env(item, args) orelse return .@"error";

    if (args.value_at(0)) |name| {
        const env_entry = env_mod.environ_find(env, name) orelse {
            cmdq.cmdq_error(item, "unknown variable: {s}", .{name});
            return .@"error";
        };
        if (should_print(args, env_entry)) {
            const line = render_env_entry(args, env_entry);
            defer xm.allocator.free(line);
            cmdq.cmdq_print(item, "{s}", .{line});
        }
        return .normal;
    }

    const entries = env_mod.environ_sorted_entries(env);
    defer xm.allocator.free(entries);
    for (entries) |env_entry| {
        if (!should_print(args, env_entry)) continue;
        const line = render_env_entry(args, env_entry);
        defer xm.allocator.free(line);
        cmdq.cmdq_print(item, "{s}", .{line});
    }
    return .normal;
}

fn resolve_env(item: *cmdq.CmdqItem, args: *const @import("arguments.zig").Arguments) ?*T.Environ {
    if (args.has('g')) return env_mod.global_environ;

    var target: T.CmdFindState = .{};
    if (cmd_find.cmd_find_target(&target, item, args.get('t'), .session, T.CMD_FIND_QUIET) != 0 or target.s == null) {
        if (args.get('t')) |tflag|
            cmdq.cmdq_error(item, "no such session: {s}", .{tflag})
        else
            cmdq.cmdq_error(item, "no current session", .{});
        return null;
    }
    return target.s.?.environ;
}

fn should_print(args: *const @import("arguments.zig").Arguments, env_entry: *T.EnvironEntry) bool {
    if (args.has('h')) return env_entry.flags & T.ENVIRON_HIDDEN != 0;
    return env_entry.flags & T.ENVIRON_HIDDEN == 0;
}

fn render_env_entry(args: *const @import("arguments.zig").Arguments, env_entry: *T.EnvironEntry) []u8 {
    if (!args.has('s')) {
        return if (env_entry.value) |value|
            xm.xasprintf("{s}={s}", .{ env_entry.name, value })
        else
            xm.xasprintf("-{s}", .{env_entry.name});
    }
    return if (env_entry.value) |value| blk: {
        const escaped = escape_shell(value);
        defer xm.allocator.free(escaped);
        break :blk xm.xasprintf("{s}=\"{s}\"; export {s};", .{ env_entry.name, escaped, env_entry.name });
    } else xm.xasprintf("unset {s};", .{env_entry.name});
}

fn escape_shell(value: []const u8) []u8 {
    var out: std.ArrayList(u8) = .{};
    for (value) |ch| {
        if (ch == '$' or ch == '`' or ch == '"' or ch == '\\') out.append(xm.allocator, '\\') catch unreachable;
        out.append(xm.allocator, ch) catch unreachable;
    }
    return out.toOwnedSlice(xm.allocator) catch unreachable;
}

pub const entry: cmd_mod.CmdEntry = .{
    .name = "show-environment",
    .alias = "showenv",
    .usage = "[-hgs] [-t target-session] [variable]",
    .template = "hgst:",
    .lower = 0,
    .upper = 1,
    .flags = T.CMD_STARTSERVER | T.CMD_AFTERHOOK,
    .exec = exec,
};

test "show-environment renders shell output" {
    var entry_val = T.EnvironEntry{ .name = xm.xstrdup("EDITOR"), .value = xm.xstrdup("a\"b"), .flags = 0 };
    defer xm.allocator.free(entry_val.name);
    defer xm.allocator.free(entry_val.value.?);

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "show-environment", "-s" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);

    const line = render_env_entry(cmd_mod.cmd_get_args(cmd), &entry_val);
    defer xm.allocator.free(line);
    try std.testing.expectEqualStrings("EDITOR=\"a\\\"b\"; export EDITOR;", line);
}
