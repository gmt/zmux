// Copyright (c) 2026 Greg Turner <gmt@be-evil.net>
// ISC licence – see COPYING.
// Ported from tmux/cmd-list-panes.c
// Ported from tmux/cmd-list-clients.c

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const cmd_mod = @import("cmd.zig");
const cmdq = @import("cmd-queue.zig");
const cmd_find = @import("cmd-find.zig");
const srv = @import("server.zig");

fn exec_lsp(cmd: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {
    const args = cmd_mod.cmd_get_args(cmd);
    var target: T.CmdFindState = .{};
    if (cmd_find.cmd_find_target(&target, item, args.get('t'), .window, 0) != 0)
        return .@"error";
    const w = target.w orelse return .@"error";
    for (w.panes.items) |wp| {
        cmdq.cmdq_print(item, "{d}: {d}x{d} pid={d}", .{ wp.id, wp.sx, wp.sy, wp.pid });
    }
    return .normal;
}

pub const entry: cmd_mod.CmdEntry = .{
    .name = "list-panes",
    .alias = "lsp",
    .template = "aF:s:t:",
    .lower = 0,
    .upper = 0,
    .flags = 0,
    .exec = exec_lsp,
};

fn exec_lsc(_cmd: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {
    _ = _cmd;
    for (srv.clients.items) |cl| {
        cmdq.cmdq_print(item, "{s} {d}x{d}", .{
            cl.ttyname orelse "/dev/unknown",
            cl.tty.sx,
            cl.tty.sy,
        });
    }
    return .normal;
}

pub const entry_lsc: cmd_mod.CmdEntry = .{
    .name = "list-clients",
    .alias = "lsc",
    .template = "F:t:",
    .lower = 0,
    .upper = 0,
    .flags = 0,
    .exec = exec_lsc,
};
