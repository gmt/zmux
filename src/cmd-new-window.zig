// Copyright (c) 2026 Greg Turner <gmt@pobox.com>
// ISC licence – see COPYING.

const std = @import("std");
const T = @import("types.zig");
const cmd_mod = @import("cmd.zig");
const cmdq = @import("cmd-queue.zig");
const sw = @import("cmd-select-window.zig");

fn exec(cmd: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {
    return sw.entry_neww.exec(cmd, item);
}

pub const entry: cmd_mod.CmdEntry = .{
    .name = "new-window",
    .alias = "neww",
    .usage = "[-abdkPS] [-c start-directory] [-e environment] [-F format] [-n window-name] [-t target-session] [shell-command]",
    .template = "abc:dF:kn:St:P",
    .lower = 0,
    .upper = -1,
    .flags = 0,
    .exec = exec,
};
