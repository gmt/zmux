// Copyright (c) 2026 Greg Turner <gmt@pobox.com>
// ISC licence – see COPYING.
// Ported from tmux/cmd-select-window.c and cmd-new-window.c

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const cmd_mod = @import("cmd.zig");
const cmdq = @import("cmd-queue.zig");
const cmd_find = @import("cmd-find.zig");
const sess = @import("session.zig");
const win_mod = @import("window.zig");
const spawn_mod = @import("spawn.zig");
const server_client_mod = @import("server-client.zig");

fn exec_selectw(cmd: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {
    const args = cmd_mod.cmd_get_args(cmd);
    var target: T.CmdFindState = .{};
    const cl = cmdq.cmdq_get_client(item);

    if (cmd_find.cmd_find_target(&target, item, args.get('t'), .window, 0) != 0)
        return .@"error";
    const s = target.s orelse return .@"error";
    const wl = target.wl orelse return .@"error";

    s.curw = wl;
    // Update client if one is attached
    if (cl) |c| {
        if (c.session == s) {
            server_client_mod.server_client_apply_session_size(c, s);
        }
    }
    return .normal;
}

fn exec_neww(cmd: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {
    const args = cmd_mod.cmd_get_args(cmd);
    var target: T.CmdFindState = .{};
    if (cmd_find.cmd_find_target(&target, item, args.get('t'), .session, T.CMD_FIND_CANFAIL) != 0)
        return .@"error";
    const s = target.s orelse return .@"error";

    var cause: ?[]u8 = null;
    var sc = T.SpawnContext{
        .item = @ptrCast(item),
        .s = s,
        .idx = -1,
        .name = args.get('n'),
        .flags = if (args.has('d')) T.SPAWN_DETACHED else 0,
    };
    const wl = spawn_mod.spawn_window(&sc, &cause) orelse {
        cmdq.cmdq_error(item, "create window failed: {s}", .{cause orelse "unknown"});
        return .@"error";
    };
    if (!args.has('d')) s.curw = wl;
    return .normal;
}

pub const entry: cmd_mod.CmdEntry = .{
    .name = "select-window",
    .alias = "selectw",
    .usage = "[-lnpT] [-t target-window]",
    .template = "lnpTt:",
    .lower = 0,
    .upper = 0,
    .flags = 0,
    .exec = exec_selectw,
};

pub const entry_neww: cmd_mod.CmdEntry = .{
    .name = "new-window",
    .alias = "neww",
    .usage = "[-abdkPS] [-c start-directory] [-e environment] [-F format] [-n window-name] [-t target-session] [shell-command]",
    .template = "abc:dF:kn:St:P",
    .lower = 0,
    .upper = -1,
    .flags = 0,
    .exec = exec_neww,
};
