// Copyright (c) 2026 Greg Turner <gmt@pobox.com>
// ISC licence – see COPYING.
//
// Ported from tmux/cmd-switch-client.c
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
const win_mod = @import("window.zig");

fn exec(cmd: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {
    const args = cmd_mod.cmd_get_args(cmd);
    const tc = cmdq.cmdq_get_target_client(item);
    const cl = tc orelse cmdq.cmdq_get_client(item);

    var target: T.CmdFindState = .{};

    // -n: next session
    if (args.has('n')) {
        const cur_s = if (cl) |c| c.session else null;
        if (cur_s) |cs| {
            if (sess.session_next_session(cs, null)) |next| {
                if (cl) |c| server_client_mod.server_client_set_session(c, next);
                return .normal;
            }
        }
        cmdq.cmdq_error(item, "can't find next session", .{});
        return .@"error";
    }

    // -p: previous session
    if (args.has('p')) {
        const cur_s = if (cl) |c| c.session else null;
        if (cur_s) |cs| {
            if (sess.session_previous_session(cs, null)) |prev| {
                if (cl) |c| server_client_mod.server_client_set_session(c, prev);
                return .normal;
            }
        }
        cmdq.cmdq_error(item, "can't find previous session", .{});
        return .@"error";
    }

    // -l: last session
    if (args.has('l')) {
        if (cl) |c| {
            if (c.last_session) |ls| {
                if (sess.session_alive(ls)) {
                    server_client_mod.server_client_set_session(c, ls);
                    return .normal;
                }
            }
        }
        cmdq.cmdq_error(item, "can't find last session", .{});
        return .@"error";
    }

    // Resolve -t target
    const tflag = args.get('t');
    if (cmd_find.cmd_find_target(&target, item, tflag, .session, 0) != 0)
        return .@"error";

    const s = target.s orelse {
        cmdq.cmdq_error(item, "no session", .{});
        return .@"error";
    };
    const wl = target.wl;
    const wp = target.wp;

    // Switch pane if pane was specified
    if (wl != null and wp != null) {
        const w = wl.?.window;
        if (wp.? != w.active) {
            win_mod.window_set_active_pane(w, wp.?, true);
        }
        if (cl) |c| {
            _ = c;
            // TODO: select window
        }
    }

    if (cl) |c| server_client_mod.server_client_set_session(c, s);
    if (cl) |c| server_client_mod.server_client_set_key_table(c, null);
    return .normal;
}

pub const entry: cmd_mod.CmdEntry = .{
    .name = "switch-client",
    .alias = "switchc",
    .template = "c:EFlnO:pt:rT:Z",
    .lower = 0,
    .upper = 0,
    .flags = T.CMD_READONLY | T.CMD_CLIENT_CFLAG,
    .exec = exec,
};
