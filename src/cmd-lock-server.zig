// Copyright (c) 2026 Greg Turner <gmt@be-evil.net>
// ISC licence – see COPYING.
//
// Ported from tmux/cmd-lock-server.c
// Original copyright:
//   Copyright (c) 2008 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

const std = @import("std");
const T = @import("types.zig");
const cmd_mod = @import("cmd.zig");
const cmdq = @import("cmd-queue.zig");
const cmd_find = @import("cmd-find.zig");
const resize_mod = @import("resize.zig");
const server_fn = @import("server-fn.zig");

fn exec(cmd: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {
    const entry_ptr = cmd_mod.cmd_get_entry(cmd);

    if (entry_ptr == &entry) {
        server_fn.server_lock();
    } else if (entry_ptr == &entry_session) {
        var target = cmdq.cmdq_get_target(item);
        if (cmd_find.cmd_find_target(&target, item, cmd_mod.cmd_get_args(cmd).get('t'), .session, 0) != 0)
            return .@"error";
        const s = target.s orelse return .@"error";
        server_fn.server_lock_session(s);
    } else {
        const tc = cmdq.cmdq_get_target_client(item) orelse cmdq.cmdq_get_client(item) orelse {
            cmdq.cmdq_error(item, "no client", .{});
            return .@"error";
        };
        server_fn.server_lock_client(tc);
    }

    resize_mod.recalculate_sizes();
    return .normal;
}

pub const entry: cmd_mod.CmdEntry = .{
    .name = "lock-server",
    .alias = "lock",
    .usage = "",
    .template = "",
    .lower = 0,
    .upper = 0,
    .flags = T.CMD_AFTERHOOK,
    .exec = exec,
};

pub const entry_session: cmd_mod.CmdEntry = .{
    .name = "lock-session",
    .alias = "locks",
    .usage = "[-t target-session]",
    .template = "t:",
    .lower = 0,
    .upper = 0,
    .flags = T.CMD_AFTERHOOK,
    .exec = exec,
};

pub const entry_client: cmd_mod.CmdEntry = .{
    .name = "lock-client",
    .alias = "lockc",
    .usage = "[-t target-client]",
    .template = "t:",
    .lower = 0,
    .upper = 0,
    .flags = T.CMD_AFTERHOOK | T.CMD_CLIENT_TFLAG,
    .exec = exec,
};

test "lock commands are registered under tmux names and aliases" {
    try std.testing.expectEqual(&entry, cmd_mod.cmd_find_entry("lock-server").?);
    try std.testing.expectEqual(&entry, cmd_mod.cmd_find_entry("lock").?);
    try std.testing.expectEqual(&entry_session, cmd_mod.cmd_find_entry("lock-session").?);
    try std.testing.expectEqual(&entry_session, cmd_mod.cmd_find_entry("locks").?);
    try std.testing.expectEqual(&entry_client, cmd_mod.cmd_find_entry("lock-client").?);
    try std.testing.expectEqual(&entry_client, cmd_mod.cmd_find_entry("lockc").?);
}
