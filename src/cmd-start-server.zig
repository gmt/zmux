// Copyright (c) 2026 Greg Turner <gmt@pobox.com>
// ISC licence – see COPYING.

const std = @import("std");
const T = @import("types.zig");
const cmd_mod = @import("cmd.zig");
const cmdq = @import("cmd-queue.zig");

fn exec(_cmd: *cmd_mod.Cmd, _item: *cmdq.CmdqItem) T.CmdRetval {
    _ = _cmd;
    _ = _item;
    return .normal;
}

pub const entry: cmd_mod.CmdEntry = .{
    .name = "start-server",
    .alias = "start",
    .usage = "",
    .template = "",
    .lower = 0,
    .upper = 0,
    .flags = T.CMD_STARTSERVER,
    .exec = exec,
};
