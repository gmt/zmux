// Copyright (c) 2026 Greg Turner <gmt@be-evil.net>
//
// Permission to use, copy, modify, and distribute this software for any
// purpose with or without fee is hereby granted, provided that the above
// copyright notice and this permission notice appear in all copies.
//
// THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
// WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
// MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
// ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
// WHATSOEVER RESULTING FROM LOSS OF MIND, USE, DATA OR PROFITS, WHETHER
// IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING
// OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
//
// Ported in part from tmux/cmd-select-pane.c.
// Original copyright:
//   Copyright (c) 2009 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const cmd_mod = @import("cmd.zig");
const cmdq = @import("cmd-queue.zig");
const cmd_find = @import("cmd-find.zig");
const server_client_mod = @import("server-client.zig");
const server_fn = @import("server-fn.zig");
const notify = @import("notify.zig");
const win = @import("window.zig");

fn exec(cmd: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {
    const args = cmd_mod.cmd_get_args(cmd);
    if (args.has('D') or args.has('L') or args.has('R') or args.has('U')) {
        cmdq.cmdq_error(item, "directional pane selection not supported yet", .{});
        return .@"error";
    }
    if (args.has('d') or args.has('e')) {
        cmdq.cmdq_error(item, "pane input toggling not supported yet", .{});
        return .@"error";
    }
    if (args.has('g') or args.has('P')) {
        cmdq.cmdq_error(item, "pane style selection not supported yet", .{});
        return .@"error";
    }
    if (args.has('m') or args.has('M')) {
        cmdq.cmdq_error(item, "marked pane support not supported yet", .{});
        return .@"error";
    }
    if (args.has('Z')) {
        cmdq.cmdq_error(item, "zoom-aware pane selection not supported yet", .{});
        return .@"error";
    }

    if (cmd.entry == &entry_last or args.has('l')) {
        return exec_last_pane(item, args.get('t'));
    }

    var target: T.CmdFindState = .{};
    if (cmd_find.cmd_find_target(&target, item, args.get('t'), .pane, 0) != 0)
        return .@"error";
    const s = target.s orelse return .@"error";
    const wl = target.wl orelse return .@"error";
    const wp = target.wp orelse return .@"error";

    if (args.get('T')) |title| {
        set_pane_title(wp, title);
        server_fn.server_status_window(wl.window);
        notify.notify_pane("pane-title-changed", wp);
        return .normal;
    }

    s.curw = wl;
    _ = win.window_set_active_pane(wl.window, wp, true);

    const cl = cmdq.cmdq_get_client(item);
    if (cl) |c| {
        if (c.session == s) server_client_mod.server_client_apply_session_size(c, s);
    }
    server_fn.server_redraw_session(s);
    server_fn.server_status_window(wl.window);
    return .normal;
}

fn exec_last_pane(item: *cmdq.CmdqItem, target_flag: ?[]const u8) T.CmdRetval {
    var target: T.CmdFindState = .{};
    if (cmd_find.cmd_find_target(&target, item, target_flag, .window, 0) != 0)
        return .@"error";
    const s = target.s orelse return .@"error";
    const wl = target.wl orelse return .@"error";
    const last = win.window_get_last_pane(wl.window) orelse {
        cmdq.cmdq_error(item, "no last pane", .{});
        return .@"error";
    };

    s.curw = wl;
    if (!win.window_set_active_pane(wl.window, last, true)) return .normal;

    const cl = cmdq.cmdq_get_client(item);
    if (cl) |c| {
        if (c.session == s) server_client_mod.server_client_apply_session_size(c, s);
    }
    server_fn.server_redraw_session(s);
    server_fn.server_status_window(wl.window);
    return .normal;
}

fn set_pane_title(wp: *T.WindowPane, title: []const u8) void {
    if (wp.screen.title) |old| xm.allocator.free(old);
    wp.screen.title = xm.xstrdup(title);
}

pub const entry: cmd_mod.CmdEntry = .{
    .name = "select-pane",
    .alias = "selectp",
    .usage = "[-lT title] [-t target-pane]",
    .template = "DdegLlMmP:RT:t:UZ",
    .lower = 0,
    .upper = 0,
    .flags = 0,
    .exec = exec,
};

pub const entry_last: cmd_mod.CmdEntry = .{
    .name = "last-pane",
    .alias = "lastp",
    .usage = "[-t target-window]",
    .template = "det:Z",
    .lower = 0,
    .upper = 0,
    .flags = 0,
    .exec = exec,
};

test "select-pane switches active pane and last-pane switches back" {
    const opts = @import("options.zig");
    const env_mod = @import("environ.zig");
    const sess = @import("session.zig");
    const spawn = @import("spawn.zig");

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

    const s = sess.session_create(null, "select-pane-test", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("select-pane-test") != null) sess.session_destroy(s, false, "test");

    var cause: ?[]u8 = null;
    var first_ctx: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const wl = spawn.spawn_window(&first_ctx, &cause).?;
    var second_ctx: T.SpawnContext = .{ .s = s, .wl = wl, .flags = T.SPAWN_EMPTY };
    const second = spawn.spawn_pane(&second_ctx, &cause).?;
    s.curw = wl;

    const pane_target = xm.xasprintf("%{d}", .{second.id});
    defer xm.allocator.free(pane_target);

    var parse_cause: ?[]u8 = null;
    const select_cmd = try cmd_mod.cmd_parse_one(&.{ "select-pane", "-t", pane_target }, null, &parse_cause);
    defer cmd_mod.cmd_free(select_cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(select_cmd, &item));
    try std.testing.expectEqual(second, wl.window.active.?);

    const last_cmd = try cmd_mod.cmd_parse_one(&.{ "last-pane", "-t", "select-pane-test:0" }, null, &parse_cause);
    defer cmd_mod.cmd_free(last_cmd);
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(last_cmd, &item));
    try std.testing.expectEqual(wl.window.panes.items[0], wl.window.active.?);
}

test "select-pane can set pane title" {
    const opts = @import("options.zig");
    const env_mod = @import("environ.zig");
    const sess = @import("session.zig");
    const spawn = @import("spawn.zig");

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

    const s = sess.session_create(null, "select-pane-title", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("select-pane-title") != null) sess.session_destroy(s, false, "test");

    var cause: ?[]u8 = null;
    var sc: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const wl = spawn.spawn_window(&sc, &cause).?;
    s.curw = wl;

    var parse_cause: ?[]u8 = null;
    const select_cmd = try cmd_mod.cmd_parse_one(&.{ "select-pane", "-t", "select-pane-title:0.0", "-T", "logs" }, null, &parse_cause);
    defer cmd_mod.cmd_free(select_cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(select_cmd, &item));
    try std.testing.expectEqualStrings("logs", wl.window.active.?.screen.title.?);
}

test "select-pane rejects directional selection for now" {
    var parse_cause: ?[]u8 = null;
    const select_cmd = try cmd_mod.cmd_parse_one(&.{ "select-pane", "-L" }, null, &parse_cause);
    defer cmd_mod.cmd_free(select_cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.@"error", cmd_mod.cmd_execute(select_cmd, &item));
}
