// Copyright (c) 2026 Greg Turner <gmt@be-evil.net>
// ISC licence – see COPYING.
// Ported from tmux/cmd-list-windows.c
// Original copyright:
//   Copyright (c) 2007 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const cmd_mod = @import("cmd.zig");
const cmd_format = @import("cmd-format.zig");
const cmdq = @import("cmd-queue.zig");
const cmd_find = @import("cmd-find.zig");
const sess = @import("session.zig");
const sort_mod = @import("sort.zig");
const format_mod = @import("format.zig");

const DEFAULT_TEMPLATE =
    "#{window_index}: #{window_name}#{window_raw_flags} " ++
    "(#{window_panes} panes) " ++
    "[#{window_width}x#{window_height}] " ++
    "[layout #{window_layout}] #{window_id}" ++
    "#{?window_active, (active),}";
const DEFAULT_ALL_TEMPLATE =
    "#{session_name}:#{window_index}: #{window_name}#{window_raw_flags} " ++
    "(#{window_panes} panes) " ++
    "[#{window_width}x#{window_height}]";

fn exec(cmd: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {
    const args = cmd_mod.cmd_get_args(cmd);
    const all_sessions = args.has('a');
    const fmt = args.get('F') orelse if (all_sessions) DEFAULT_ALL_TEMPLATE else DEFAULT_TEMPLATE;
    const filter = args.get('f');
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
            const ctx = window_context(wl.session, wl);
            if (filter) |expr| {
                const matched = cmd_format.filter(item, expr, &ctx) orelse return .@"error";
                if (!matched) continue;
            }
            const line = cmd_format.require(item, fmt, &ctx) orelse return .@"error";
            defer xm.allocator.free(line);
            cmdq.cmdq_print(item, "{s}", .{line});
        }
    } else {
        var target: T.CmdFindState = .{};
        if (cmd_find.cmd_find_target(&target, item, args.get('t'), .session, 0) != 0)
            return .@"error";
        if (target.s) |s| {
            if (list_windows_session(s, fmt, filter, item, sort_crit) != .normal)
                return .@"error";
        }
    }
    return .normal;
}

fn list_windows_session(s: *T.Session, fmt: []const u8, filter: ?[]const u8, item: *cmdq.CmdqItem, sort_crit: T.SortCriteria) T.CmdRetval {
    const winlinks = sort_mod.sorted_winlinks_session(s, sort_crit);
    defer xm.allocator.free(winlinks);
    for (winlinks) |wl| {
        const ctx = window_context(s, wl);
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

fn window_context(s: *T.Session, wl: *T.Winlink) format_mod.FormatContext {
    return .{
        .session = s,
        .winlink = wl,
        .window = wl.window,
        .pane = wl.window.active,
        .format_type = .window,
    };
}

pub const entry: cmd_mod.CmdEntry = .{
    .name = "list-windows",
    .alias = "lsw",
    .usage = "[-ar] [-F format] [-f filter] [-O order] [-t target-session]",
    .template = "aF:O:f:rt:",
    .lower = 0,
    .upper = 0,
    .flags = 0,
    .exec = exec,
};

test "list-windows templates and filters use shared formatter" {
    const opts = @import("options.zig");
    const env_mod = @import("environ.zig");
    const win = @import("window.zig");

    cmdq.cmdq_reset_for_tests();
    defer cmdq.cmdq_reset_for_tests();

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

    const s = sess.session_create(null, "list-windows-test", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("list-windows-test") != null) sess.session_destroy(s, false, "test");

    const w = win.window_create(80, 24, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    win.window_set_name(w, "editor");
    _ = win.window_add_pane(w, null, 80, 24);
    var cause: ?[]u8 = null;
    const wl = sess.session_attach(s, w, 3, &cause).?;
    s.curw = wl;

    const ctx = window_context(s, wl);
    const line = format_mod.format_require_complete(xm.allocator, DEFAULT_TEMPLATE, &ctx).?;
    defer xm.allocator.free(line);
    try std.testing.expect(std.mem.startsWith(u8, line, "3: editor* (1 panes) [80x24] [layout "));
    try std.testing.expect(std.mem.endsWith(u8, line, "] @0 (active)"));

    const all_line = format_mod.format_require_complete(xm.allocator, DEFAULT_ALL_TEMPLATE, &ctx).?;
    defer xm.allocator.free(all_line);
    try std.testing.expectEqualStrings("list-windows-test:3: editor* (1 panes) [80x24]", all_line);

    const matched = format_mod.format_filter_match(xm.allocator, "#{window_active}", &ctx).?;
    try std.testing.expect(matched);
}
