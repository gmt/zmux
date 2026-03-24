// Copyright (c) 2026 Greg Turner <gmt@be-evil.net>
// ISC licence – see COPYING.
// Ported from tmux/cmd-refresh-client.c
// Original copyright:
//   Copyright (c) 2007 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const cmd_mod = @import("cmd.zig");
const cmdq = @import("cmd-queue.zig");

fn exec(cmd: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {
    const args = cmd_mod.cmd_get_args(cmd);

    // -C WxH: set control-mode client size
    if (args.get('C')) |size_str| {
        if (cmdq.cmdq_get_client(item)) |cl| {
            var sx: u32 = 80;
            var sy: u32 = 24;
            var it = std.mem.splitScalar(u8, size_str, ',');
            if (it.next()) |ws| sx = std.fmt.parseInt(u32, ws, 10) catch 80;
            if (it.next()) |hs| sy = std.fmt.parseInt(u32, hs, 10) catch 24;
            cl.tty.sx = sx;
            cl.tty.sy = sy;
            if (cl.session) |s| {
                if (s.curw) |wl| {
                    const w = wl.window;
                    w.sx = sx;
                    w.sy = sy;
                    for (w.panes.items) |wp| {
                        wp.sx = sx;
                        wp.sy = sy;
                    }
                }
            }
        }
    }

    return .normal;
}

pub const entry: cmd_mod.CmdEntry = .{
    .name = "refresh-client",
    .alias = "refresh",
    .template = "A:B:cC:Df:F:Hl:LN:pPrRst:U",
    .lower = 0,
    .upper = 0,
    .flags = T.CMD_READONLY,
    .exec = exec,
};
