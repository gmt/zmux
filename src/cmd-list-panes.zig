// Copyright (c) 2026 Greg Turner <gmt@be-evil.net>
// ISC licence – see COPYING.
// Ported from tmux/cmd-list-panes.c
// Ported from tmux/cmd-list-clients.c

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const cmd_mod = @import("cmd.zig");
const cmd_format = @import("cmd-format.zig");
const cmdq = @import("cmd-queue.zig");
const cmd_find = @import("cmd-find.zig");
const srv = @import("server.zig");
const sess = @import("session.zig");
const sort_mod = @import("sort.zig");
const format_mod = @import("format.zig");

const DEFAULT_PANE_TEMPLATE = "#{pane_index}: #{pane_width}x#{pane_height} pid=#{pane_pid}";
const DEFAULT_WINDOW_PANE_TEMPLATE = "#{window_index}.#{pane_index}: #{pane_width}x#{pane_height} pid=#{pane_pid}";
const DEFAULT_SESSION_PANE_TEMPLATE = "#{session_name}:#{window_index}.#{pane_index}: #{pane_width}x#{pane_height} pid=#{pane_pid}";
const DEFAULT_CLIENT_TEMPLATE =
    "#{client_name}: #{session_name} " ++
    "[#{client_width}x#{client_height} #{client_termname}] " ++
    "#{?#{!=:#{client_uid},#{uid}}," ++
    "[user #{?client_user,#{client_user},#{client_uid},}] ,}" ++
    "#{?client_flags,(,}#{client_flags}#{?client_flags,),}";

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
            .format_type = .pane,
        };
        if (filter) |expr| {
            const matched = cmd_format.filter(item, expr, &ctx) orelse return .@"error";
            if (!matched) continue;
        }
        const line = cmd_format.require(item, fmt, &ctx) orelse return .@"error";
        defer xm.allocator.free(line);
        cmdq.cmdq_print(item, "{s}", .{line});
    }
    return .normal;
}

pub const entry: cmd_mod.CmdEntry = .{
    .name = "list-panes",
    .alias = "lsp",
    .usage = "[-asr] [-F format] [-f filter] [-O order] [-s] [-t target-pane]",
    .template = "aF:O:f:rs:t:",
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
            const matched = cmd_format.filter(item, expr, &ctx) orelse return .@"error";
            if (!matched) continue;
        }
        const line = cmd_format.require(item, args.get('F') orelse DEFAULT_CLIENT_TEMPLATE, &ctx) orelse return .@"error";
        defer xm.allocator.free(line);
        cmdq.cmdq_print(item, "{s}", .{line});
    }
    return .normal;
}

pub const entry_lsc: cmd_mod.CmdEntry = .{
    .name = "list-clients",
    .alias = "lsc",
    .usage = "[-F format] [-f filter] [-O order] [-t target-session]",
    .template = "F:O:f:rt:",
    .lower = 0,
    .upper = 0,
    .flags = 0,
    .exec = exec_lsc,
};

test "list-panes templates and filters use shared formatter" {
    const opts = @import("options.zig");
    const env_mod = @import("environ.zig");
    const spawn = @import("spawn.zig");
    const win = @import("window.zig");

    sess.session_init_globals(xm.allocator);
    win.window_init_globals(xm.allocator);

    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);

    env_mod.global_environ = env_mod.environ_create();
    defer env_mod.environ_free(env_mod.global_environ);

    const s = sess.session_create(null, "list-panes-test", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("list-panes-test") != null) sess.session_destroy(s, false, "test");

    var cause: ?[]u8 = null;
    var sc: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const wl = spawn.spawn_window(&sc, &cause).?;
    s.curw = wl;

    const ctx = format_mod.FormatContext{
        .session = s,
        .winlink = wl,
        .window = wl.window,
        .pane = wl.window.active.?,
    };
    const line = format_mod.format_require_complete(xm.allocator, DEFAULT_SESSION_PANE_TEMPLATE, &ctx).?;
    defer xm.allocator.free(line);
    try std.testing.expect(std.mem.indexOf(u8, line, "list-panes-test:0.0: 80x24 pid=-1") != null);

    const matched = format_mod.format_filter_match(xm.allocator, "#{==:pane_width,80}", &ctx).?;
    try std.testing.expect(matched);
}
