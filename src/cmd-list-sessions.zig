// Copyright (c) 2026 Greg Turner <gmt@pobox.com>
// ISC licence – see COPYING.
// Ported from tmux/cmd-list-sessions.c
// Original copyright:
//   Copyright (c) 2007 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const cmd_mod = @import("cmd.zig");
const cmdq = @import("cmd-queue.zig");
const sess = @import("session.zig");
const sort_mod = @import("sort.zig");
const format_mod = @import("format.zig");

const DEFAULT_TEMPLATE = "#{session_name}: #{session_windows} windows (created #{t:session_created})#{?session_grouped, (group #{session_group}: #{session_group_list}),}#{?session_attached, (attached),}";

fn exec(cmd: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {
    const args = cmd_mod.cmd_get_args(cmd);
    const fmt = args.get('F') orelse DEFAULT_TEMPLATE;
    const filter = args.get('f');

    const sort_crit = T.SortCriteria{
        .order = sort_mod.sort_order_from_string(args.get('O')),
        .reversed = args.has('r'),
    };
    if (sort_crit.order == .end and args.has('O')) {
        cmdq.cmdq_error(item, "invalid sort order", .{});
        return .@"error";
    }
    const sorted = sort_mod.sorted_sessions(sort_crit);
    defer xm.allocator.free(sorted);

    for (sorted) |s| {
        const ctx = session_context(s);
        if (filter) |expr| {
            const matched = format_mod.format_filter_match(xm.allocator, expr, &ctx) orelse {
                cmdq.cmdq_error(item, "format expansion not supported yet", .{});
                return .@"error";
            };
            if (!matched) continue;
        }

        const output = format_mod.format_require_complete(xm.allocator, fmt, &ctx) orelse {
            cmdq.cmdq_error(item, "format expansion not supported yet", .{});
            return .@"error";
        };
        defer xm.allocator.free(output);
        cmdq.cmdq_print(item, "{s}", .{output});
    }
    return .normal;
}

fn session_context(s: *T.Session) format_mod.FormatContext {
    return .{
        .session = s,
        .winlink = s.curw,
        .window = if (s.curw) |wl| wl.window else null,
        .pane = if (s.curw) |wl| wl.window.active else null,
    };
}

pub const entry: cmd_mod.CmdEntry = .{
    .name = "list-sessions",
    .alias = "ls",
    .usage = "[-r] [-F format] [-f filter] [-O order]",
    .template = "F:O:r",
    .lower = 0,
    .upper = 0,
    .flags = 0,
    .exec = exec,
};
