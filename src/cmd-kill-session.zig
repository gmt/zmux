// Copyright (c) 2026 Greg Turner <gmt@be-evil.net>
// ISC licence – see COPYING.
//
// Ported from tmux/cmd-kill-session.c
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
const srv = @import("server.zig");

fn exec(cmd: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {
    const args = cmd_mod.cmd_get_args(cmd);
    var target = cmdq.cmdq_get_target(item);

    if (cmd_find.cmd_find_target(&target, item, args.get('t'), .session, 0) != 0)
        return .@"error";
    const s = target.s orelse return .@"error";

    if (args.has('C')) {
        // clear alerts only
        srv.server_redraw_session(s);
        return .normal;
    } else if (args.has('a')) {
        // kill all OTHER sessions
        var it = sess.sessions.iterator();
        while (it.next()) |kv| {
            if (kv.value_ptr.* != s) {
                srv.server_destroy_session(kv.value_ptr.*);
                sess.session_destroy(kv.value_ptr.*, true, "kill-session -a");
            }
        }
    } else {
        srv.server_destroy_session(s);
        sess.session_destroy(s, true, "kill-session");
    }
    return .normal;
}

pub const entry: cmd_mod.CmdEntry = .{
    .name = "kill-session",
    .alias = null,
    .template = "aCt:",
    .lower = 0,
    .upper = 0,
    .flags = 0,
    .exec = exec,
};
