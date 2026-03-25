// Copyright (c) 2026 Greg Turner <gmt@pobox.com>
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
const format_mod = @import("format.zig");

const DEFAULT_PANE_TEMPLATE = "#{pane_index}: #{pane_width}x#{pane_height} pid=#{pane_pid}";
const DEFAULT_WINDOW_PANE_TEMPLATE = "#{window_index}.#{pane_index}: #{pane_width}x#{pane_height} pid=#{pane_pid}";
const DEFAULT_SESSION_PANE_TEMPLATE = "#{session_name}:#{window_index}.#{pane_index}: #{pane_width}x#{pane_height} pid=#{pane_pid}";
const DEFAULT_CLIENT_TEMPLATE = "#{client_tty} #{client_width}x#{client_height}";

fn exec_lsp(cmd: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {
    const args = cmd_mod.cmd_get_args(cmd);
    const filter = args.get('f');
    const sort_crit = T.SortCriteria{
        .order = sort_mod.sort_order_from_string(args.get('O')),
        .reversed = args.has('r'),
    };
    if (sort_crit.order == .end and args.has('O')) {
        cmdq.cmdq_error(item, "invalid sort order", .{});
        return .@"error";
    }

    if (args.has('a')) {
        const fmt = args.get('F') orelse DEFAULT_SESSION_PANE_TEMPLATE;
        const sessions = sort_mod.sorted_sessions(.{});
        defer xm.allocator.free(sessions);
        for (sessions) |s| {
            const wl_items = sort_mod.sorted_winlinks_session(s, .{});
            defer xm.allocator.free(wl_items);
            for (wl_items) |wl| {
                if (print_window_panes(item, wl.window, sort_crit, s, wl, fmt, filter) != .normal)
                    return .@"error";
            }
        }
        return .normal;
    }

    var target: T.CmdFindState = .{};
    if (args.has('s')) {
        const fmt = args.get('F') orelse DEFAULT_WINDOW_PANE_TEMPLATE;
        if (cmd_find.cmd_find_target(&target, item, args.get('t'), .session, 0) != 0)
            return .@"error";
        const s = target.s orelse return .@"error";
        const wl_items = sort_mod.sorted_winlinks_session(s, .{});
        defer xm.allocator.free(wl_items);
        for (wl_items) |wl| {
            if (print_window_panes(item, wl.window, sort_crit, s, wl, fmt, filter) != .normal)
                return .@"error";
        }
        return .normal;
    }

    const fmt = args.get('F') orelse DEFAULT_PANE_TEMPLATE;
    if (cmd_find.cmd_find_target(&target, item, args.get('t'), .window, 0) != 0)
        return .@"error";
    const w = target.w orelse return .@"error";
    return print_window_panes(item, w, sort_crit, target.s, target.wl, fmt, filter);
}

fn print_window_panes(item: *cmdq.CmdqItem, w: *T.Window, sort_crit: T.SortCriteria, s: ?*T.Session, wl: ?*T.Winlink, fmt: []const u8, filter: ?[]const u8) T.CmdRetval {
    const panes = sort_mod.sorted_panes_window(w, sort_crit);
    defer xm.allocator.free(panes);
    for (panes) |wp| {
        const ctx = format_mod.FormatContext{
            .session = s,
            .winlink = wl,
            .window = w,
            .pane = wp,
        };
        if (filter) |expr| {
            const matched = format_mod.format_filter_match(xm.allocator, expr, &ctx) orelse {
                cmdq.cmdq_error(item, "format expansion not supported yet", .{});
                return .@"error";
            };
            if (!matched) continue;
        }
        const line = format_mod.format_require_complete(xm.allocator, fmt, &ctx) orelse {
            cmdq.cmdq_error(item, "format expansion not supported yet", .{});
            return .@"error";
        };
        defer xm.allocator.free(line);
        cmdq.cmdq_print(item, "{s}", .{line});
    }
    return .normal;
}

pub const entry: cmd_mod.CmdEntry = .{
    .name = "list-panes",
    .alias = "lsp",
    .usage = "[-asr] [-F format] [-f filter] [-O order] [-s] [-t target-pane]",
    .template = "aF:O:rs:t:",
    .lower = 0,
    .upper = 0,
    .flags = 0,
    .exec = exec_lsp,
};

fn exec_lsc(_cmd: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {
    const args = cmd_mod.cmd_get_args(_cmd);
    const filter = args.get('f');
    const sort_crit = T.SortCriteria{
        .order = sort_mod.sort_order_from_string(args.get('O')),
        .reversed = args.has('r'),
    };
    if (sort_crit.order == .end and args.has('O')) {
        cmdq.cmdq_error(item, "invalid sort order", .{});
        return .@"error";
    }
    var target: T.CmdFindState = .{};
    const target_session = if (args.get('t') != null)
        blk: {
            if (cmd_find.cmd_find_target(&target, item, args.get('t'), .session, 0) != 0)
                return .@"error";
            break :blk target.s;
        }
    else
        null;

    const clients = sort_mod.sorted_clients(sort_crit);
    defer xm.allocator.free(clients);
    for (clients) |cl| {
        if (target_session) |session_target| {
            if (cl.session != session_target) continue;
        }
        const ctx = format_mod.FormatContext{
            .client = cl,
            .session = cl.session,
            .winlink = if (cl.session) |s| s.curw else null,
            .window = if (cl.session) |s| if (s.curw) |wl| wl.window else null else null,
            .pane = if (cl.session) |s| if (s.curw) |wl| wl.window.active else null else null,
        };
        if (filter) |expr| {
            const matched = format_mod.format_filter_match(xm.allocator, expr, &ctx) orelse {
                cmdq.cmdq_error(item, "format expansion not supported yet", .{});
                return .@"error";
            };
            if (!matched) continue;
        }
        const line = format_mod.format_require_complete(xm.allocator, args.get('F') orelse DEFAULT_CLIENT_TEMPLATE, &ctx) orelse {
            cmdq.cmdq_error(item, "format expansion not supported yet", .{});
            return .@"error";
        };
        defer xm.allocator.free(line);
        cmdq.cmdq_print(item, "{s}", .{line});
    }
    return .normal;
}

pub const entry_lsc: cmd_mod.CmdEntry = .{
    .name = "list-clients",
    .alias = "lsc",
    .usage = "[-F format] [-f filter] [-O order] [-t target-session]",
    .template = "F:O:rt:",
    .lower = 0,
    .upper = 0,
    .flags = 0,
    .exec = exec_lsc,
};
