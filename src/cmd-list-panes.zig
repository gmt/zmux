// Copyright (c) 2026 Greg Turner <gmt@be-evil.net>
// ISC licence – see COPYING.
// Ported from tmux/cmd-list-panes.c
// Ported from tmux/cmd-list-clients.c

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const cmd_mod = @import("cmd.zig");
const cmdq = @import("cmd-queue.zig");
const cmd_find = @import("cmd-find.zig");
const srv = @import("server.zig");
const sess = @import("session.zig");
const sort_mod = @import("sort.zig");

fn exec_lsp(cmd: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {
    const args = cmd_mod.cmd_get_args(cmd);
    const sort_crit = T.SortCriteria{
        .order = sort_mod.sort_order_from_string(args.get('O')),
        .reversed = args.has('r'),
    };
    if (sort_crit.order == .end and args.has('O')) {
        cmdq.cmdq_error(item, "invalid sort order", .{});
        return .@"error";
    }

    if (args.has('a')) {
        const sessions = sort_mod.sorted_sessions(.{});
        defer xm.allocator.free(sessions);
        for (sessions) |s| {
            const wl_items = sort_mod.sorted_winlinks_session(s, .{});
            defer xm.allocator.free(wl_items);
            for (wl_items) |wl| print_window_panes(item, wl.window, sort_crit, 2, s, wl);
        }
        return .normal;
    }

    var target: T.CmdFindState = .{};
    if (args.has('s')) {
        if (cmd_find.cmd_find_target(&target, item, args.get('t'), .session, 0) != 0)
            return .@"error";
        const s = target.s orelse return .@"error";
        const wl_items = sort_mod.sorted_winlinks_session(s, .{});
        defer xm.allocator.free(wl_items);
        for (wl_items) |wl| print_window_panes(item, wl.window, sort_crit, 1, s, wl);
        return .normal;
    }

    if (cmd_find.cmd_find_target(&target, item, args.get('t'), .window, 0) != 0)
        return .@"error";
    const w = target.w orelse return .@"error";
    print_window_panes(item, w, sort_crit, 0, target.s, target.wl);
    return .normal;
}

fn print_window_panes(item: *cmdq.CmdqItem, w: *T.Window, sort_crit: T.SortCriteria, scope: u2, s: ?*T.Session, wl: ?*T.Winlink) void {
    const panes = sort_mod.sorted_panes_window(w, sort_crit);
    defer xm.allocator.free(panes);
    for (panes, 0..) |wp, idx| {
        switch (scope) {
            0 => cmdq.cmdq_print(item, "{d}: {d}x{d} pid={d}", .{ idx, wp.sx, wp.sy, wp.pid }),
            1 => cmdq.cmdq_print(item, "{d}.{d}: {d}x{d} pid={d}", .{ wl.?.idx, idx, wp.sx, wp.sy, wp.pid }),
            2 => cmdq.cmdq_print(item, "{s}:{d}.{d}: {d}x{d} pid={d}", .{ s.?.name, wl.?.idx, idx, wp.sx, wp.sy, wp.pid }),
            else => unreachable,
        }
    }
}

pub const entry: cmd_mod.CmdEntry = .{
    .name = "list-panes",
    .alias = "lsp",
    .template = "aF:O:rs:t:",
    .lower = 0,
    .upper = 0,
    .flags = 0,
    .exec = exec_lsp,
};

fn exec_lsc(_cmd: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {
    const args = cmd_mod.cmd_get_args(_cmd);
    const sort_crit = T.SortCriteria{
        .order = sort_mod.sort_order_from_string(args.get('O')),
        .reversed = args.has('r'),
    };
    if (sort_crit.order == .end and args.has('O')) {
        cmdq.cmdq_error(item, "invalid sort order", .{});
        return .@"error";
    }
    const clients = sort_mod.sorted_clients(sort_crit);
    defer xm.allocator.free(clients);
    for (clients) |cl| {
        cmdq.cmdq_print(item, "{s} {d}x{d}", .{
            cl.ttyname orelse "/dev/unknown",
            cl.tty.sx,
            cl.tty.sy,
        });
    }
    return .normal;
}

pub const entry_lsc: cmd_mod.CmdEntry = .{
    .name = "list-clients",
    .alias = "lsc",
    .template = "F:O:rt:",
    .lower = 0,
    .upper = 0,
    .flags = 0,
    .exec = exec_lsc,
};
