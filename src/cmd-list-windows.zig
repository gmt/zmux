// Copyright (c) 2026 Greg Turner <gmt@pobox.com>
// ISC licence – see COPYING.
// Ported from tmux/cmd-list-windows.c
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
const sort_mod = @import("sort.zig");

fn exec(cmd: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {
    const args = cmd_mod.cmd_get_args(cmd);
    const fmt = args.get('F') orelse "#{window_index}: #{window_name}#{?window_flags,#{window_flags}, }#{?window_active, (active),}";
    const all_sessions = args.has('a');
    const sort_crit = T.SortCriteria{
        .order = sort_mod.sort_order_from_string(args.get('O')),
        .reversed = args.has('r'),
    };
    if (sort_crit.order == .end and args.has('O')) {
        cmdq.cmdq_error(item, "invalid sort order", .{});
        return .@"error";
    }

    if (all_sessions) {
        const winlinks = sort_mod.sorted_winlinks(sort_crit);
        defer xm.allocator.free(winlinks);
        for (winlinks) |wl| {
            cmdq.cmdq_print(item, "{d}: {s}", .{ wl.idx, wl.window.name });
        }
    } else {
        var target: T.CmdFindState = .{};
        if (cmd_find.cmd_find_target(&target, item, args.get('t'), .session, 0) != 0)
            return .@"error";
        if (target.s) |s| list_windows_session(s, fmt, item, sort_crit);
    }
    return .normal;
}

fn list_windows_session(s: *T.Session, fmt: []const u8, item: *cmdq.CmdqItem, sort_crit: T.SortCriteria) void {
    _ = fmt;
    const winlinks = sort_mod.sorted_winlinks_session(s, sort_crit);
    defer xm.allocator.free(winlinks);
    for (winlinks) |wl| {
        cmdq.cmdq_print(item, "{d}: {s}", .{ wl.idx, wl.window.name });
    }
}

pub const entry: cmd_mod.CmdEntry = .{
    .name = "list-windows",
    .alias = "lsw",
    .template = "aF:O:rt:",
    .lower = 0,
    .upper = 0,
    .flags = 0,
    .exec = exec,
};
