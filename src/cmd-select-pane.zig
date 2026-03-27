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
const format_mod = @import("format.zig");
const opts = @import("options.zig");
const screen = @import("screen.zig");
const server_client_mod = @import("server-client.zig");
const server_fn = @import("server-fn.zig");
const style_mod = @import("style.zig");
const notify = @import("notify.zig");
const win = @import("window.zig");

fn exec(cmd: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {
    const args = cmd_mod.cmd_get_args(cmd);
    if (args.has('m') or args.has('M')) {
        cmdq.cmdq_error(item, "marked pane support not supported yet", .{});
        return .@"error";
    }
    if (args.has('Z')) {
        cmdq.cmdq_error(item, "zoom-aware pane selection not supported yet", .{});
        return .@"error";
    }

    if (cmd.entry == &entry_last or args.has('l')) {
        return exec_last_pane(item, args);
    }

    var target: T.CmdFindState = .{};
    if (cmd_find.cmd_find_target(&target, item, args.get('t'), .pane, 0) != 0)
        return .@"error";
    const wl = target.wl orelse return .@"error";
    const s = target.s orelse return .@"error";
    var wp = target.wp orelse return .@"error";

    if (args.get('P')) |style| {
        if (!set_pane_style(item, wp, style))
            return .@"error";
    }
    if (args.has('g')) {
        cmdq.cmdq_print(item, "{s}", .{opts.options_get_string(wp.options, "window-style")});
        return .normal;
    }

    if (args.has('L')) {
        wp = win.window_pane_find_left(wp) orelse return .normal;
    } else if (args.has('R')) {
        wp = win.window_pane_find_right(wp) orelse return .normal;
    } else if (args.has('U')) {
        wp = win.window_pane_find_up(wp) orelse return .normal;
    } else if (args.has('D')) {
        wp = win.window_pane_find_down(wp) orelse return .normal;
    }

    if (args.has('e')) {
        wp.flags &= ~T.PANE_INPUTOFF;
        server_fn.server_redraw_window_borders(wl.window);
        server_fn.server_status_window(wl.window);
        return .normal;
    }
    if (args.has('d')) {
        wp.flags |= T.PANE_INPUTOFF;
        server_fn.server_redraw_window_borders(wl.window);
        server_fn.server_status_window(wl.window);
        return .normal;
    }

    if (args.get('T')) |title| {
        const expanded = format_mod.format_single(item, title, cmdq.cmdq_get_client(item), s, wl, wp);
        defer xm.allocator.free(expanded);

        if (screen.screen_set_title(wp.screen, expanded)) {
            server_fn.server_redraw_window_borders(wl.window);
            server_fn.server_status_window(wl.window);
            notify.notify_pane("pane-title-changed", wp);
        }
        return .normal;
    }

    if (wp == wl.window.active) return .normal;
    _ = win.window_set_active_pane(wl.window, wp, true);

    const cl = cmdq.cmdq_get_client(item);
    if (cl) |c| {
        if (c.session == s) server_client_mod.server_client_apply_session_size(c, s);
    }
    server_fn.server_redraw_session(s);
    server_fn.server_status_window(wl.window);
    return .normal;
}

fn exec_last_pane(item: *cmdq.CmdqItem, args: *const @import("arguments.zig").Arguments) T.CmdRetval {
    var target: T.CmdFindState = .{};
    if (cmd_find.cmd_find_target(&target, item, args.get('t'), .window, 0) != 0)
        return .@"error";
    const s = target.s orelse return .@"error";
    const wl = target.wl orelse return .@"error";
    const last = last_pane_fallback(wl.window) orelse {
        cmdq.cmdq_error(item, "no last pane", .{});
        return .@"error";
    };

    if (args.has('e')) {
        last.flags &= ~T.PANE_INPUTOFF;
        server_fn.server_status_window(wl.window);
        return .normal;
    }
    if (args.has('d')) {
        last.flags |= T.PANE_INPUTOFF;
        server_fn.server_status_window(wl.window);
        return .normal;
    }

    if (!win.window_set_active_pane(wl.window, last, true)) return .normal;

    const cl = cmdq.cmdq_get_client(item);
    if (cl) |c| {
        if (c.session == s) server_client_mod.server_client_apply_session_size(c, s);
    }
    server_fn.server_redraw_session(s);
    server_fn.server_status_window(wl.window);
    return .normal;
}

fn set_pane_style(item: *cmdq.CmdqItem, wp: *T.WindowPane, raw: []const u8) bool {
    var parsed: T.Style = undefined;
    style_mod.style_set(&parsed, &T.grid_default_cell);
    if (style_mod.style_parse(&parsed, &T.grid_default_cell, raw) != 0) {
        cmdq.cmdq_error(item, "bad style: {s}", .{raw});
        return false;
    }

    opts.options_set_string(wp.options, false, "window-style", raw);
    opts.options_set_string(wp.options, false, "window-active-style", raw);
    wp.flags |= T.PANE_REDRAW | T.PANE_STYLECHANGED | T.PANE_THEMECHANGED;
    server_fn.server_redraw_pane(wp);
    server_fn.server_redraw_window_borders(wp.window);
    server_fn.server_status_window(wp.window);
    return true;
}

fn last_pane_fallback(w: *T.Window) ?*T.WindowPane {
    if (win.window_get_last_pane(w)) |last| return last;
    if (win.window_count_panes(w) != 2) return null;
    for (w.panes.items) |pane| {
        if (pane != w.active.?) return pane;
    }
    return null;
}

pub const entry: cmd_mod.CmdEntry = .{
    .name = "select-pane",
    .alias = "selectp",
    .usage = "[-DdeLlMmRUZ] [-P style] [-T title] [-t target-pane]",
    .template = "DdegLlMmP:RT:t:UZ",
    .lower = 0,
    .upper = 0,
    .flags = 0,
    .exec = exec,
};

pub const entry_last: cmd_mod.CmdEntry = .{
    .name = "last-pane",
    .alias = "lastp",
    .usage = "[-deZ] [-t target-window]",
    .template = "det:Z",
    .lower = 0,
    .upper = 0,
    .flags = 0,
    .exec = exec,
};

test "select-pane switches active pane and last-pane switches back" {
    const opts_mod = @import("options.zig");
    const env_mod = @import("environ.zig");
    const sess_mod = @import("session.zig");
    const spawn = @import("spawn.zig");

    sess_mod.session_init_globals(xm.allocator);
    win.window_init_globals(xm.allocator);

    opts_mod.global_options = opts_mod.options_create(null);
    defer opts_mod.options_free(opts_mod.global_options);
    opts_mod.global_s_options = opts_mod.options_create(null);
    defer opts_mod.options_free(opts_mod.global_s_options);
    opts_mod.global_w_options = opts_mod.options_create(null);
    defer opts_mod.options_free(opts_mod.global_w_options);
    opts_mod.options_default_all(opts_mod.global_options, T.OPTIONS_TABLE_SERVER);
    opts_mod.options_default_all(opts_mod.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts_mod.options_default_all(opts_mod.global_w_options, T.OPTIONS_TABLE_WINDOW);

    env_mod.global_environ = env_mod.environ_create();
    defer env_mod.environ_free(env_mod.global_environ);

    const s = sess_mod.session_create(null, "select-pane-test", "/", env_mod.environ_create(), opts_mod.options_create(opts_mod.global_s_options), null);
    defer if (sess_mod.session_find("select-pane-test") != null) sess_mod.session_destroy(s, false, "test");

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
    const opts_mod = @import("options.zig");
    const env_mod = @import("environ.zig");
    const sess_mod = @import("session.zig");
    const spawn = @import("spawn.zig");

    sess_mod.session_init_globals(xm.allocator);
    win.window_init_globals(xm.allocator);

    opts_mod.global_options = opts_mod.options_create(null);
    defer opts_mod.options_free(opts_mod.global_options);
    opts_mod.global_s_options = opts_mod.options_create(null);
    defer opts_mod.options_free(opts_mod.global_s_options);
    opts_mod.global_w_options = opts_mod.options_create(null);
    defer opts_mod.options_free(opts_mod.global_w_options);
    opts_mod.options_default_all(opts_mod.global_options, T.OPTIONS_TABLE_SERVER);
    opts_mod.options_default_all(opts_mod.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts_mod.options_default_all(opts_mod.global_w_options, T.OPTIONS_TABLE_WINDOW);

    env_mod.global_environ = env_mod.environ_create();
    defer env_mod.environ_free(env_mod.global_environ);

    const s = sess_mod.session_create(null, "select-pane-title", "/", env_mod.environ_create(), opts_mod.options_create(opts_mod.global_s_options), null);
    defer if (sess_mod.session_find("select-pane-title") != null) sess_mod.session_destroy(s, false, "test");

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

test "select-pane formats pane titles" {
    const opts_mod = @import("options.zig");
    const env_mod = @import("environ.zig");
    const sess_mod = @import("session.zig");
    const spawn = @import("spawn.zig");

    sess_mod.session_init_globals(xm.allocator);
    win.window_init_globals(xm.allocator);

    opts_mod.global_options = opts_mod.options_create(null);
    defer opts_mod.options_free(opts_mod.global_options);
    opts_mod.global_s_options = opts_mod.options_create(null);
    defer opts_mod.options_free(opts_mod.global_s_options);
    opts_mod.global_w_options = opts_mod.options_create(null);
    defer opts_mod.options_free(opts_mod.global_w_options);
    opts_mod.options_default_all(opts_mod.global_options, T.OPTIONS_TABLE_SERVER);
    opts_mod.options_default_all(opts_mod.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts_mod.options_default_all(opts_mod.global_w_options, T.OPTIONS_TABLE_WINDOW);

    env_mod.global_environ = env_mod.environ_create();
    defer env_mod.environ_free(env_mod.global_environ);

    const s = sess_mod.session_create(null, "select-pane-format-title", "/", env_mod.environ_create(), opts_mod.options_create(opts_mod.global_s_options), null);
    defer if (sess_mod.session_find("select-pane-format-title") != null) sess_mod.session_destroy(s, false, "test");

    var cause: ?[]u8 = null;
    var sc: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const wl = spawn.spawn_window(&sc, &cause).?;
    s.curw = wl;

    var parse_cause: ?[]u8 = null;
    const select_cmd = try cmd_mod.cmd_parse_one(&.{ "select-pane", "-t", "select-pane-format-title:0.0", "-T", "#{session_name}-#{window_index}" }, null, &parse_cause);
    defer cmd_mod.cmd_free(select_cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(select_cmd, &item));
    try std.testing.expectEqualStrings("select-pane-format-title-0", wl.window.active.?.screen.title.?);
}

test "select-pane selects directional neighbours and toggles pane input" {
    const opts_mod = @import("options.zig");
    const env_mod = @import("environ.zig");
    const sess_mod = @import("session.zig");
    const spawn = @import("spawn.zig");

    sess_mod.session_init_globals(xm.allocator);
    win.window_init_globals(xm.allocator);

    opts_mod.global_options = opts_mod.options_create(null);
    defer opts_mod.options_free(opts_mod.global_options);
    opts_mod.global_s_options = opts_mod.options_create(null);
    defer opts_mod.options_free(opts_mod.global_s_options);
    opts_mod.global_w_options = opts_mod.options_create(null);
    defer opts_mod.options_free(opts_mod.global_w_options);
    opts_mod.options_default_all(opts_mod.global_options, T.OPTIONS_TABLE_SERVER);
    opts_mod.options_default_all(opts_mod.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts_mod.options_default_all(opts_mod.global_w_options, T.OPTIONS_TABLE_WINDOW);

    env_mod.global_environ = env_mod.environ_create();
    defer env_mod.environ_free(env_mod.global_environ);

    const s = sess_mod.session_create(null, "select-pane-directional", "/", env_mod.environ_create(), opts_mod.options_create(opts_mod.global_s_options), null);
    defer if (sess_mod.session_find("select-pane-directional") != null) sess_mod.session_destroy(s, false, "test");

    var cause: ?[]u8 = null;
    var first_ctx: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const wl = spawn.spawn_window(&first_ctx, &cause).?;
    const first = wl.window.active.?;
    var second_ctx: T.SpawnContext = .{ .s = s, .wl = wl, .flags = T.SPAWN_EMPTY };
    const right = spawn.spawn_pane(&second_ctx, &cause).?;
    var third_ctx: T.SpawnContext = .{ .s = s, .wl = wl, .flags = T.SPAWN_EMPTY };
    const down = spawn.spawn_pane(&third_ctx, &cause).?;
    s.curw = wl;

    first.xoff = 0;
    first.yoff = 0;
    first.sx = 40;
    first.sy = 12;
    right.xoff = 41;
    right.yoff = 0;
    right.sx = 39;
    right.sy = 12;
    down.xoff = 0;
    down.yoff = 13;
    down.sx = 40;
    down.sy = 11;

    var parse_cause: ?[]u8 = null;
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };

    const right_cmd = try cmd_mod.cmd_parse_one(&.{ "select-pane", "-R", "-t", "select-pane-directional:0.0" }, null, &parse_cause);
    defer cmd_mod.cmd_free(right_cmd);
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(right_cmd, &item));
    try std.testing.expectEqual(right, wl.window.active.?);

    const down_input_off = try cmd_mod.cmd_parse_one(&.{ "select-pane", "-d", "-D", "-t", "select-pane-directional:0.0" }, null, &parse_cause);
    defer cmd_mod.cmd_free(down_input_off);
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(down_input_off, &item));
    try std.testing.expect(down.flags & T.PANE_INPUTOFF != 0);
    try std.testing.expectEqual(right, wl.window.active.?);

    const down_input_on = try cmd_mod.cmd_parse_one(&.{ "select-pane", "-e", "-D", "-t", "select-pane-directional:0.0" }, null, &parse_cause);
    defer cmd_mod.cmd_free(down_input_on);
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(down_input_on, &item));
    try std.testing.expect(down.flags & T.PANE_INPUTOFF == 0);
}

test "select-pane sets pane styles and last-pane falls back to the only other pane" {
    const opts_mod = @import("options.zig");
    const env_mod = @import("environ.zig");
    const sess_mod = @import("session.zig");
    const spawn = @import("spawn.zig");

    sess_mod.session_init_globals(xm.allocator);
    win.window_init_globals(xm.allocator);

    opts_mod.global_options = opts_mod.options_create(null);
    defer opts_mod.options_free(opts_mod.global_options);
    opts_mod.global_s_options = opts_mod.options_create(null);
    defer opts_mod.options_free(opts_mod.global_s_options);
    opts_mod.global_w_options = opts_mod.options_create(null);
    defer opts_mod.options_free(opts_mod.global_w_options);
    opts_mod.options_default_all(opts_mod.global_options, T.OPTIONS_TABLE_SERVER);
    opts_mod.options_default_all(opts_mod.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts_mod.options_default_all(opts_mod.global_w_options, T.OPTIONS_TABLE_WINDOW);

    env_mod.global_environ = env_mod.environ_create();
    defer env_mod.environ_free(env_mod.global_environ);

    const s = sess_mod.session_create(null, "select-pane-style", "/", env_mod.environ_create(), opts_mod.options_create(opts_mod.global_s_options), null);
    defer if (sess_mod.session_find("select-pane-style") != null) sess_mod.session_destroy(s, false, "test");

    var cause: ?[]u8 = null;
    var first_ctx: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const wl = spawn.spawn_window(&first_ctx, &cause).?;
    const first = wl.window.active.?;
    var second_ctx: T.SpawnContext = .{ .s = s, .wl = wl, .flags = T.SPAWN_EMPTY };
    const second = spawn.spawn_pane(&second_ctx, &cause).?;
    s.curw = wl;

    var parse_cause: ?[]u8 = null;
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };

    const style_cmd = try cmd_mod.cmd_parse_one(&.{ "select-pane", "-t", "select-pane-style:0.0", "-P", "fg=red,bg=blue" }, null, &parse_cause);
    defer cmd_mod.cmd_free(style_cmd);
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(style_cmd, &item));
    try std.testing.expectEqualStrings("fg=red,bg=blue", opts_mod.options_get_string(first.options, "window-style"));
    try std.testing.expectEqualStrings("fg=red,bg=blue", opts_mod.options_get_string(first.options, "window-active-style"));

    const last_cmd = try cmd_mod.cmd_parse_one(&.{ "last-pane", "-t", "select-pane-style:0" }, null, &parse_cause);
    defer cmd_mod.cmd_free(last_cmd);
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(last_cmd, &item));
    try std.testing.expectEqual(second, wl.window.active.?);
}

test "select-pane rejects invalid pane styles" {
    var parse_cause: ?[]u8 = null;
    const select_cmd = try cmd_mod.cmd_parse_one(&.{ "select-pane", "-P", "mystery-token" }, null, &parse_cause);
    defer cmd_mod.cmd_free(select_cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.@"error", cmd_mod.cmd_execute(select_cmd, &item));
}
