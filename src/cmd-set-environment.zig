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
// Ported in part from tmux/cmd-set-environment.c
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
const format_mod = @import("format.zig");

fn exec(cmd: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {
    const args = cmd_mod.cmd_get_args(cmd);
    const name = args.value_at(0) orelse {
        cmdq.cmdq_error(item, "empty variable name", .{});
        return .@"error";
    };
    if (name.len == 0) {
        cmdq.cmdq_error(item, "empty variable name", .{});
        return .@"error";
    }
    if (std.mem.indexOfScalar(u8, name, '=')) |_| {
        cmdq.cmdq_error(item, "variable name contains =", .{});
        return .@"error";
    }

    const env = resolve_env(item, args) orelse return .@"error";
    const raw_value = args.value_at(1);
    const value = if (args.has('F') and raw_value != null) blk: {
        var target: T.CmdFindState = .{};
        _ = cmd_find.cmd_find_target(&target, item, args.get('t'), .session, T.CMD_FIND_QUIET | T.CMD_FIND_CANFAIL);
        const ctx = format_mod.FormatContext{
            .item = @ptrCast(item),
            .client = cmdq.cmdq_get_client(item),
            .session = target.s,
            .winlink = target.wl,
            .window = target.w,
            .pane = target.wp,
        };
        break :blk format_mod.format_require_complete(xm.allocator, raw_value.?, &ctx) orelse {
            cmdq.cmdq_error(item, "format expansion not supported yet", .{});
            return .@"error";
        };
    } else null;
    defer if (value) |expanded| xm.allocator.free(expanded);
    const actual_value = value orelse raw_value;

    if (args.has('u')) {
        if (actual_value != null) {
            cmdq.cmdq_error(item, "can't specify a value with -u", .{});
            return .@"error";
        }
        env_mod.environ_unset(env, name);
        return .normal;
    }
    if (args.has('r')) {
        if (actual_value != null) {
            cmdq.cmdq_error(item, "can't specify a value with -r", .{});
            return .@"error";
        }
        env_mod.environ_clear(env, name);
        return .normal;
    }
    if (actual_value == null) {
        cmdq.cmdq_error(item, "no value specified", .{});
        return .@"error";
    }

    env_mod.environ_set(env, name, if (args.has('h')) T.ENVIRON_HIDDEN else 0, actual_value.?);
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

pub const entry: cmd_mod.CmdEntry = .{
    .name = "set-environment",
    .alias = "setenv",
    .usage = "[-Fhgru] [-t target-session] variable [value]",
    .template = "Fhgrt:u",
    .lower = 1,
    .upper = 2,
    .flags = T.CMD_STARTSERVER | T.CMD_AFTERHOOK,
    .exec = exec,
};

test "set-environment sets and clears session environment" {
    env_mod.global_environ = env_mod.environ_create();
    defer env_mod.environ_free(env_mod.global_environ);

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "set-environment", "-g", "EDITOR", "nvim" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));
    try std.testing.expectEqualStrings("nvim", env_mod.environ_find(env_mod.global_environ, "EDITOR").?.value.?);
}
