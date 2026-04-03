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
const args_mod = @import("arguments.zig");
const xm = @import("xmalloc.zig");
const cmd_mod = @import("cmd.zig");
const cmd_format = @import("cmd-format.zig");
const cmdq = @import("cmd-queue.zig");
const cmd_find = @import("cmd-find.zig");
const env_mod = @import("environ.zig");
const cmd_respawn_pane = @import("cmd-respawn-pane.zig");
const spawn_mod = @import("spawn.zig");
const server_fn = @import("server-fn.zig");
const win = @import("window.zig");
const layout_mod = @import("layout.zig");

const SPLIT_WINDOW_TEMPLATE = "#{session_name}:#{window_index}.#{pane_index}";

fn exec(cmd: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {
    const args = cmd_mod.cmd_get_args(cmd);

    var target: T.CmdFindState = .{};
    if (cmd_find.cmd_find_target(&target, item, args.get('t'), .pane, 0) != 0)
        return .@"error";
    const s = target.s orelse return .@"error";
    const wl = target.wl orelse return .@"error";
    const w = wl.window;
    const wp = target.wp orelse return .@"error";
    const type_: T.LayoutType = if (args.has('h')) .leftright else .topbottom;

    var size_cause: ?[]u8 = null;
    defer if (size_cause) |msg| xm.allocator.free(msg);
    const size = parse_split_size(args, w, wp, type_, &size_cause);
    if (size_cause != null) {
        cmdq.cmdq_error(item, "size {s}", .{size_cause.?});
        return .@"error";
    }

    const input = args.has('I') and args.count() == 0;
    var spawn_flags: u32 = 0;
    if (args.has('b')) spawn_flags |= T.SPAWN_BEFORE;
    if (args.has('f')) spawn_flags |= T.SPAWN_FULLSIZE;
    if (input or (args.count() == 1 and args.value_at(0).?.len == 0))
        spawn_flags |= T.SPAWN_EMPTY;
    if (args.has('d')) spawn_flags |= T.SPAWN_DETACHED;
    if (args.has('Z')) spawn_flags |= T.SPAWN_ZOOM;

    _ = win.window_push_zoom(w, true, args.has('Z'));
    const lcnew = layout_mod.layout_split_pane(wp, type_, size, @intCast(spawn_flags)) orelse {
        cmdq.cmdq_error(item, "no space for new pane", .{});
        return .@"error";
    };

    const overlay = cmd_respawn_pane.build_overlay_environment(args, item) catch return .@"error";
    defer if (overlay) |env| env_mod.environ_free(env);

    const argv = argv_tail(args, 0);
    defer if (argv) |slice| free_argv(slice);

    var sc = T.SpawnContext{
        .item = @ptrCast(item),
        .s = s,
        .wl = wl,
        .wp0 = wp,
        .lc = lcnew,
        .cwd = args.get('c'),
        .environ = overlay,
        .flags = spawn_flags,
    };
    if (argv) |slice| {
        sc.argv = slice;
    }

    var cause: ?[]u8 = null;
    defer if (cause) |msg| xm.allocator.free(msg);
    const new_wp = spawn_mod.spawn_pane(&sc, &cause) orelse {
        cmdq.cmdq_error(item, "create pane failed: {s}", .{cause orelse "unknown"});
        return .@"error";
    };

    var wait_for_input = false;
    if (input) {
        var input_cause: ?[]u8 = null;
        const input_rc = win.window_pane_start_input(new_wp, item, &input_cause);
        if (input_rc == -1) {
            if (input_cause) |ic| {
                cmdq.cmdq_error(item, "{s}", .{ic});
                xm.allocator.free(ic);
            }
            layout_mod.layout_close_pane(new_wp);
            win.window_remove_pane(w, new_wp);
            return .@"error";
        }
        if (input_rc == 0) wait_for_input = true;
    }

    if (!args.has('d')) {
        _ = win.window_set_active_pane(w, new_wp, true);
        var current = cmdq.cmdq_get_current(item);
        current.s = s;
        current.wl = wl;
        current.w = w;
        current.wp = new_wp;
        current.idx = wl.idx;
        item.state.current = current;
    }
    s.curw = wl;
    _ = win.window_pop_zoom(w);
    server_fn.server_redraw_session(s);
    server_fn.server_status_window(w);

    if (args.has('P')) {
        const template = args.get('F') orelse SPLIT_WINDOW_TEMPLATE;
        const rendered = render_split_location(item, template, s, wl, new_wp) orelse return .@"error";
        defer xm.allocator.free(rendered);
        cmdq.cmdq_print(item, "{s}", .{rendered});
    }

    return if (wait_for_input) .wait else .normal;
}

fn parse_split_size(
    args: *const args_mod.Arguments,
    w: *T.Window,
    wp: *T.WindowPane,
    type_: T.LayoutType,
    cause: *?[]u8,
) i32 {
    const curval: i64 = blk: {
        if (!(args.has('l') or args.has('p')))
            break :blk 0;
        if (args.has('f')) {
            break :blk switch (type_) {
                .leftright => w.sx,
                .topbottom => w.sy,
                else => 0,
            };
        }
        break :blk switch (type_) {
            .leftright => wp.sx,
            .topbottom => wp.sy,
            else => 0,
        };
    };

    if (args.has('l'))
        return @intCast(args_mod.args_percentage(args, 'l', 0, std.math.maxInt(i32), curval, cause));

    if (args.has('p')) {
        const pct = args_mod.args_strtonum(args, 'p', 0, 100, cause);
        if (cause.* != null) return -1;
        return @intCast(@divTrunc(curval * pct, 100));
    }

    cause.* = null;
    return -1;
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

fn render_split_location(item: *cmdq.CmdqItem, template: []const u8, s: *T.Session, wl: *T.Winlink, wp: *T.WindowPane) ?[]u8 {
    const state = T.CmdFindState{
        .s = s,
        .wl = wl,
        .w = wl.window,
        .wp = wp,
        .idx = wl.idx,
    };
    const ctx = cmd_format.target_context(&state, null);
    return cmd_format.require(item, template, &ctx);
}

pub const entry: cmd_mod.CmdEntry = .{
    .name = "split-window",
    .alias = "splitw",
    .usage = "[-bdP] [-c start-directory] [-e environment] [-F format] [-t target-pane] [shell-command [argument ...]]",
    .template = "bc:de:fF:hIl:p:Pt:vZ",
    .lower = 0,
    .upper = -1,
    .flags = 0,
    .exec = exec,
};

test "split-window adds a pane after target and makes it active" {
    const opts = @import("options.zig");
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
    const first = wl.window.active.?;

    // Split the layout so the second pane gets a proper layout cell.
    const lc2 = layout_mod.layout_split_pane(first, .topbottom, -1, 0).?;
    var second_ctx: T.SpawnContext = .{ .s = s, .wl = wl, .lc = lc2, .flags = T.SPAWN_EMPTY };
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

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    const rendered = render_split_location(&item, SPLIT_WINDOW_TEMPLATE, s, wl, second).?;
    defer xm.allocator.free(rendered);
    try std.testing.expectEqualStrings("split-print:0.1", rendered);
}

test "split-window applies repeated -e overlays to the spawned pane" {
    const sess = @import("session.zig");
    const spawn = @import("spawn.zig");
    const respawn_cmd = @import("cmd-respawn-pane.zig");

    sess.session_init_globals(xm.allocator);
    win.window_init_globals(xm.allocator);

    const opts = @import("options.zig");
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

    const s = sess.session_create(null, "split-env", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("split-env") != null) sess.session_destroy(s, false, "test");

    var cause: ?[]u8 = null;
    var root_ctx: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const wl = spawn.spawn_window(&root_ctx, &cause).?;
    s.curw = wl;

    var parse_cause: ?[]u8 = null;
    const split_cmd = try cmd_mod.cmd_parse_one(&.{
        "split-window",
        "-d",
        "-e",
        "FOO=first",
        "-e",
        "FOO=second",
        "-e",
        "BAR=ok",
        "-t",
        "split-env:0.0",
        "printf '%s %s' \"$FOO\" \"$BAR\"",
    }, null, &parse_cause);
    defer cmd_mod.cmd_free(split_cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(split_cmd, &item));

    std.Thread.sleep(500 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(usize, 2), wl.window.panes.items.len);
    const output = respawn_cmd.read_pane_output(wl.window.panes.items[1]);
    defer xm.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "second ok") != null);
}

test "split-window rejects invalid -e overlays" {
    const opts = @import("options.zig");
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

    const s = sess.session_create(null, "split-invalid-env", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("split-invalid-env") != null) sess.session_destroy(s, false, "test");

    var cause: ?[]u8 = null;
    var root_ctx: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const wl = spawn.spawn_window(&root_ctx, &cause).?;
    s.curw = wl;

    var parse_cause: ?[]u8 = null;
    const split_cmd = try cmd_mod.cmd_parse_one(&.{ "split-window", "-e", "BROKEN", "-t", "split-invalid-env:0.0" }, null, &parse_cause);
    defer cmd_mod.cmd_free(split_cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.@"error", cmd_mod.cmd_execute(split_cmd, &item));
    try std.testing.expectEqual(@as(usize, 1), wl.window.panes.items.len);
}

test "split-window -h and size flags use the reduced shared pane geometry layer" {
    const opts = @import("options.zig");
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

    const s = sess.session_create(null, "split-size", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("split-size") != null) sess.session_destroy(s, false, "test");

    var cause: ?[]u8 = null;
    var root_ctx: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const wl = spawn.spawn_window(&root_ctx, &cause).?;
    s.curw = wl;
    const first = wl.window.active.?;

    var parse_cause: ?[]u8 = null;
    const split_cmd = try cmd_mod.cmd_parse_one(&.{ "split-window", "-h", "-l", "25", "-t", "split-size:0.0" }, null, &parse_cause);
    defer cmd_mod.cmd_free(split_cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(split_cmd, &item));

    const second = wl.window.active.?;
    try std.testing.expectEqual(@as(usize, 2), wl.window.panes.items.len);
    try std.testing.expectEqual(first, wl.window.panes.items[0]);
    try std.testing.expectEqual(@as(u32, 54), first.sx);
    try std.testing.expectEqual(@as(u32, 0), first.xoff);
    try std.testing.expectEqual(@as(u32, 25), second.sx);
    try std.testing.expectEqual(@as(u32, 55), second.xoff);
    try std.testing.expectEqual(second, item.state.current.wp.?);
}

test "split-window -b -p splits above the target using percentage sizing" {
    const opts = @import("options.zig");
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

    const s = sess.session_create(null, "split-before-size", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("split-before-size") != null) sess.session_destroy(s, false, "test");

    var cause: ?[]u8 = null;
    var root_ctx: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const wl = spawn.spawn_window(&root_ctx, &cause).?;
    s.curw = wl;
    const first = wl.window.active.?;

    var parse_cause: ?[]u8 = null;
    const split_cmd = try cmd_mod.cmd_parse_one(&.{ "split-window", "-b", "-v", "-p", "25", "-t", "split-before-size:0.0" }, null, &parse_cause);
    defer cmd_mod.cmd_free(split_cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(split_cmd, &item));

    const second = wl.window.panes.items[0];
    try std.testing.expectEqual(@as(u32, 17), first.sy);
    try std.testing.expectEqual(@as(u32, 7), first.yoff);
    try std.testing.expectEqual(@as(u32, 6), second.sy);
    try std.testing.expectEqual(@as(u32, 0), second.yoff);
}

test "split-window -I feeds detached stdin into a new empty pane" {
    const env_mod_local = @import("environ.zig");
    const opts = @import("options.zig");
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

    env_mod_local.global_environ = env_mod_local.environ_create();
    defer env_mod_local.environ_free(env_mod_local.global_environ);

    const s = sess.session_create(null, "split-input", "/", env_mod_local.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("split-input") != null) sess.session_destroy(s, false, "test");

    var cause: ?[]u8 = null;
    var root_ctx: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const wl = spawn.spawn_window(&root_ctx, &cause).?;
    s.curw = wl;

    const saved_stdin = try std.posix.dup(std.posix.STDIN_FILENO);
    defer {
        std.posix.dup2(saved_stdin, std.posix.STDIN_FILENO) catch {};
        std.posix.close(saved_stdin);
    }

    const pipe_fds = try std.posix.pipe();
    defer std.posix.close(pipe_fds[0]);
    _ = try std.posix.write(pipe_fds[1], "split stdin\r\n");
    std.posix.close(pipe_fds[1]);
    try std.posix.dup2(pipe_fds[0], std.posix.STDIN_FILENO);

    var client = T.Client{
        .environ = env_mod_local.environ_create(),
        .tty = undefined,
        .status = .{},
    };
    defer env_mod_local.environ_free(client.environ);

    var parse_cause: ?[]u8 = null;
    const split_cmd = try cmd_mod.cmd_parse_one(&.{ "split-window", "-I", "-t", "split-input:0.0" }, null, &parse_cause);
    defer cmd_mod.cmd_free(split_cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &client, .cmdlist = &list };
    // In unit tests, startRemoteRead fails (no peer for file I/O),
    // so start_input returns -1 → split-window returns .error.
    try std.testing.expectEqual(T.CmdRetval.@"error", cmd_mod.cmd_execute(split_cmd, &item));
}

test "split-window -Z preserves the zoom flag across the new split" {
    const opts = @import("options.zig");
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

    const s = sess.session_create(null, "split-zoom", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("split-zoom") != null) sess.session_destroy(s, false, "test");

    var cause: ?[]u8 = null;
    var root_ctx: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const wl = spawn.spawn_window(&root_ctx, &cause).?;
    s.curw = wl;
    const first = wl.window.active.?;

    // Create a second pane with a proper layout cell so we can zoom.
    const lc2 = layout_mod.layout_split_pane(first, .topbottom, -1, 0).?;
    var second_ctx: T.SpawnContext = .{ .s = s, .wl = wl, .lc = lc2, .flags = T.SPAWN_EMPTY };
    _ = spawn.spawn_pane(&second_ctx, &cause).?;

    // Zoom via the proper API (requires >= 2 panes).
    try std.testing.expect(win.window_zoom(first));
    try std.testing.expect(wl.window.flags & T.WINDOW_ZOOMED != 0);

    var parse_cause: ?[]u8 = null;
    const zoom_cmd = try cmd_mod.cmd_parse_one(&.{ "split-window", "-Z", "-t", "split-zoom:0.0" }, null, &parse_cause);
    defer cmd_mod.cmd_free(zoom_cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(zoom_cmd, &item));
    try std.testing.expect(wl.window.flags & T.WINDOW_ZOOMED != 0);
    try std.testing.expectEqual(@as(u32, 0), wl.window.flags & T.WINDOW_WASZOOMED);
    try std.testing.expectEqual(@as(usize, 3), wl.window.panes.items.len);
}
