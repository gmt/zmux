// Copyright (c) 2026 Greg Turner <gmt@be-evil.net>
// ISC licence – see COPYING.
//
// Ported from tmux/cmd-kill-server.c
// Original copyright:
//   Copyright (c) 2007 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

const std = @import("std");
const T = @import("types.zig");
const cmd_mod = @import("cmd.zig");
const cmdq = @import("cmd-queue.zig");
const srv = @import("server.zig");
const proc_mod = @import("proc.zig");

fn exec(_cmd: *cmd_mod.Cmd, _item: *cmdq.CmdqItem) T.CmdRetval {
    _ = _cmd;
    _ = _item;
    // Signal the server event loop to exit immediately.
    srv.server_exit = true;
    if (srv.server_proc) |sp| proc_mod.proc_exit(sp);
    return .normal;
}

pub const entry: cmd_mod.CmdEntry = .{
    .name = "kill-server",
    .alias = null,
    .template = "",
    .lower = 0,
    .upper = 0,
    .flags = 0,
    .exec = exec,
};
