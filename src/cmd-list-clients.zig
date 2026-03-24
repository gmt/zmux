// Copyright (c) 2026 Greg Turner <gmt@pobox.com>
// ISC licence – see COPYING.

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const cmd_mod = @import("cmd.zig");
const cmdq = @import("cmd-queue.zig");
const lsp = @import("cmd-list-panes.zig");

fn exec(cmd: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {
    return lsp.entry_lsc.exec(cmd, item);
}

pub const entry: cmd_mod.CmdEntry = .{
    .name = "list-clients",
    .alias = "lsc",
    .template = "F:t:",
    .lower = 0,
    .upper = 0,
    .flags = 0,
    .exec = exec,
};
