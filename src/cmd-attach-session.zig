// Copyright (c) 2026 Greg Turner <gmt@be-evil.net>
// ISC licence – see COPYING.
//
// Ported from tmux/cmd-attach-session.c
// Original copyright:
//   Copyright (c) 2007 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const cmd_mod = @import("cmd.zig");
const cmdq = @import("cmd-queue.zig");
const cmd_find = @import("cmd-find.zig");
const sess = @import("session.zig");
const server_client_mod = @import("server-client.zig");
const proc_mod = @import("proc.zig");
const protocol = @import("zmux-protocol.zig");

fn exec_attach(cmd: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {
    const args = cmd_mod.cmd_get_args(cmd);
    var target = cmdq.cmdq_get_target(item);
    const cl = cmdq.cmdq_get_client(item);

    if (cmd_find.cmd_find_target(&target, item, args.get('t'), .session, 0) != 0)
        return .@"error";
    const s = target.s orelse return .@"error";

    const detach_other = args.has('d');
    const read_only = args.has('r');
    _ = detach_other;
    _ = read_only;

    if (cl) |c| {
        server_client_mod.server_client_attach(c, s);
    }
    return .normal;
}

fn exec_detach(cmd: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {
    _ = cmd;
    const cl = cmdq.cmdq_get_client(item);
    if (cl) |c| {
        c.session = null;
        c.flags |= T.CLIENT_EXIT;
        if (c.peer) |peer| {
            _ = proc_mod.proc_send(peer, .detach, -1, null, 0);
        }
    }
    return .normal;
}

pub const entry: cmd_mod.CmdEntry = .{
    .name = "attach-session",
    .alias = "attach",
    .usage = "[-dErx] [-c working-directory] [-f flags] [-t target-session]",
    .template = "c:dEf:rt:",
    .lower = 0,
    .upper = 0,
    .flags = T.CMD_STARTSERVER,
    .exec = exec_attach,
};

pub const entry_detach: cmd_mod.CmdEntry = .{
    .name = "detach-client",
    .alias = "detach",
    .usage = "[-aP] [-E shell-command] [-s target-session] [-t target-client]",
    .template = "aE:Ps:t:",
    .lower = 0,
    .upper = 0,
    .flags = 0,
    .exec = exec_detach,
};
