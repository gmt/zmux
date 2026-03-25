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
// Ported in part from tmux/cmd-split-window.c.
// Original copyright:
//   Copyright (c) 2009 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const cmd_mod = @import("cmd.zig");
const cmdq = @import("cmd-queue.zig");
const cmd_find = @import("cmd-find.zig");
const cmd_display = @import("cmd-display-message.zig");
const spawn_mod = @import("spawn.zig");
const server_fn = @import("server-fn.zig");
const win = @import("window.zig");

const SPLIT_WINDOW_TEMPLATE = "#{session_name}:#{window_index}.#{pane_index}";

fn exec(cmd: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {
    const args = cmd_mod.cmd_get_args(cmd);
    if (args.has('e')) {
        cmdq.cmdq_error(item, "-e not supported yet", .{});
        return .@"error";
    }
    if (args.has('f')) {
        cmdq.cmdq_error(item, "-f not supported yet", .{});
        return .@"error";
    }
    if (args.has('h') or args.has('v')) {
        cmdq.cmdq_error(item, "split layout selection not supported yet", .{});
        return .@"error";
    }
    if (args.has('I')) {
        cmdq.cmdq_error(item, "-I not supported yet", .{});
        return .@"error";
    }
    if (args.has('l') or args.has('p')) {
        cmdq.cmdq_error(item, "split sizing not supported yet", .{});
        return .@"error";
    }
    if (args.has('Z')) {
        cmdq.cmdq_error(item, "-Z not supported yet", .{});
        return .@"error";
    }

    var target: T.CmdFindState = .{};
    if (cmd_find.cmd_find_target(&target, item, args.get('t'), .pane, 0) != 0)
        return .@"error";
    const s = target.s orelse return .@"error";
    const wl = target.wl orelse return .@"error";
    const wp = target.wp orelse return .@"error";

    var sc = T.SpawnContext{
        .item = @ptrCast(item),
        .s = s,
        .wl = wl,
        .wp0 = insertion_anchor(wl.window, wp, args.has('b')),
        .cwd = args.get('c'),
        .flags = if (args.has('d')) T.SPAWN_DETACHED else 0,
    };

    const argv = argv_tail(args, 0);
    defer if (argv) |slice| free_argv(slice);
    if (argv) |slice| {
        sc.argv = slice;
        if (slice.len == 1 and slice[0].len == 0) sc.flags |= T.SPAWN_EMPTY;
    }

    var cause: ?[]u8 = null;
    defer if (cause) |msg| xm.allocator.free(msg);
    const new_wp = spawn_mod.spawn_pane(&sc, &cause) orelse {
        cmdq.cmdq_error(item, "create pane failed: {s}", .{cause orelse "unknown"});
        return .@"error";
    };

    if (!args.has('d')) _ = win.window_set_active_pane(wl.window, new_wp, true);
    s.curw = wl;
    server_fn.server_redraw_session(s);
    server_fn.server_status_window(wl.window);

    if (args.has('P')) {
        const template = args.get('F') orelse SPLIT_WINDOW_TEMPLATE;
        const rendered = render_split_location(template, s, wl, new_wp);
        defer xm.allocator.free(rendered);
        cmdq.cmdq_print(item, "{s}", .{rendered});
    }
    return .normal;
}

fn insertion_anchor(w: *T.Window, wp: *T.WindowPane, before: bool) ?*T.WindowPane {
    if (before) return wp;
    for (w.panes.items, 0..) |pane, idx| {
        if (pane != wp) continue;
        if (idx + 1 >= w.panes.items.len) return null;
        return w.panes.items[idx + 1];
    }
    return null;
}

fn argv_tail(args: *const @import("arguments.zig").Arguments, start: usize) ?[][]u8 {
    if (args.count() <= start) return null;
    const out = xm.allocator.alloc([]u8, args.count() - start) catch unreachable;
    for (start..args.count()) |idx| out[idx - start] = xm.xstrdup(args.value_at(idx).?);
    return out;
}

fn free_argv(argv: [][]u8) void {
    for (argv) |arg| xm.allocator.free(arg);
    xm.allocator.free(argv);
}

fn render_split_location(template: []const u8, s: *T.Session, wl: *T.Winlink, wp: *T.WindowPane) []u8 {
    var state = T.CmdFindState{
        .s = s,
        .wl = wl,
        .w = wl.window,
        .wp = wp,
        .idx = wl.idx,
    };
    return cmd_display.expand_format(xm.allocator, template, &state);
}

pub const entry: cmd_mod.CmdEntry = .{
    .name = "split-window",
    .alias = "splitw",
    .usage = "[-bdP] [-c start-directory] [-F format] [-t target-pane] [shell-command [argument ...]]",
    .template = "bc:de:fF:hIl:p:Pt:vZ",
    .lower = 0,
    .upper = -1,
    .flags = 0,
    .exec = exec,
};

test "split-window adds a pane after target and makes it active" {
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

    const s = sess.session_create(null, "split-test", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("split-test") != null) sess.session_destroy(s, false, "test");

    var cause: ?[]u8 = null;
    var first_ctx: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const wl = spawn.spawn_window(&first_ctx, &cause).?;
    const first = wl.window.active.?;
    var second_ctx: T.SpawnContext = .{ .s = s, .wl = wl, .flags = T.SPAWN_EMPTY };
    const second = spawn.spawn_pane(&second_ctx, &cause).?;
    s.curw = wl;

    const target = xm.xasprintf("%{d}", .{first.id});
    defer xm.allocator.free(target);

    var parse_cause: ?[]u8 = null;
    const split_cmd = try cmd_mod.cmd_parse_one(&.{ "split-window", "-t", target }, null, &parse_cause);
    defer cmd_mod.cmd_free(split_cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(split_cmd, &item));

    try std.testing.expectEqual(@as(usize, 3), wl.window.panes.items.len);
    try std.testing.expectEqual(first, wl.window.panes.items[0]);
    try std.testing.expectEqual(second, wl.window.panes.items[2]);
    try std.testing.expectEqual(wl.window.panes.items[1], wl.window.active.?);
}

test "split-window -b inserts before target and -d preserves active pane" {
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

    const s = sess.session_create(null, "split-before", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("split-before") != null) sess.session_destroy(s, false, "test");

    var cause: ?[]u8 = null;
    var first_ctx: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const wl = spawn.spawn_window(&first_ctx, &cause).?;
    var second_ctx: T.SpawnContext = .{ .s = s, .wl = wl, .flags = T.SPAWN_EMPTY };
    const second = spawn.spawn_pane(&second_ctx, &cause).?;
    s.curw = wl;
    _ = win.window_set_active_pane(wl.window, second, true);

    const target = xm.xasprintf("%{d}", .{second.id});
    defer xm.allocator.free(target);

    var parse_cause: ?[]u8 = null;
    const split_cmd = try cmd_mod.cmd_parse_one(&.{ "split-window", "-b", "-d", "-t", target }, null, &parse_cause);
    defer cmd_mod.cmd_free(split_cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(split_cmd, &item));

    try std.testing.expectEqual(@as(usize, 3), wl.window.panes.items.len);
    try std.testing.expectEqual(second, wl.window.panes.items[2]);
    try std.testing.expectEqual(second, wl.window.active.?);
}

test "split-window location rendering uses pane ordinals" {
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

    const s = sess.session_create(null, "split-print", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("split-print") != null) sess.session_destroy(s, false, "test");

    var cause: ?[]u8 = null;
    var sc: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const wl = spawn.spawn_window(&sc, &cause).?;
    var second_ctx: T.SpawnContext = .{ .s = s, .wl = wl, .flags = T.SPAWN_EMPTY };
    const second = spawn.spawn_pane(&second_ctx, &cause).?;

    const rendered = render_split_location(SPLIT_WINDOW_TEMPLATE, s, wl, second);
    defer xm.allocator.free(rendered);
    try std.testing.expectEqualStrings("split-print:0.1", rendered);
}

test "split-window rejects unsupported sizing flags" {
    var parse_cause: ?[]u8 = null;
    const split_cmd = try cmd_mod.cmd_parse_one(&.{ "split-window", "-l", "10" }, null, &parse_cause);
    defer cmd_mod.cmd_free(split_cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.@"error", cmd_mod.cmd_execute(split_cmd, &item));
}
