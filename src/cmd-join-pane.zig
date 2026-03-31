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
// Ported in part from tmux/cmd-join-pane.c.
// Original copyright:
//   Copyright (c) 2011 George Nachman <tmux@georgester.com>
//   Copyright (c) 2009 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

const std = @import("std");
const T = @import("types.zig");
const args_mod = @import("arguments.zig");
const cmd_mod = @import("cmd.zig");
const cmdq = @import("cmd-queue.zig");
const cmd_find = @import("cmd-find.zig");
const server_fn = @import("server-fn.zig");
const win = @import("window.zig");
const layout_mod = @import("layout.zig");
const xm = @import("xmalloc.zig");

fn exec(cmd: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {
    const args = cmd_mod.cmd_get_args(cmd);

    var source: T.CmdFindState = .{};
    if (cmd_find.cmd_find_target(&source, item, args.get('s'), .pane, 0) != 0)
        return .@"error";
    const src_s = source.s orelse return .@"error";
    const src_wl = source.wl orelse return .@"error";
    const src_wp = source.wp orelse return .@"error";
    const src_w = src_wl.window;

    var target: T.CmdFindState = .{};
    if (cmd_find.cmd_find_target(&target, item, args.get('t'), .pane, 0) != 0)
        return .@"error";
    const dst_s = target.s orelse return .@"error";
    const dst_wl = target.wl orelse return .@"error";
    const dst_wp = target.wp orelse return .@"error";
    const dst_w = dst_wl.window;

    if (src_wp == dst_wp) {
        cmdq.cmdq_error(item, "source and target panes must be different", .{});
        return .@"error";
    }

    const type_: T.LayoutType = if (args.has('h')) .leftright else .topbottom;
    var size_cause: ?[]u8 = null;
    defer if (size_cause) |msg| xm.allocator.free(msg);
    const size = parse_join_size(args, dst_w, dst_wp, type_, &size_cause);
    if (size_cause != null) {
        cmdq.cmdq_error(item, "size {s}", .{size_cause.?});
        return .@"error";
    }

    var spawn_flags: u32 = 0;
    if (args.has('b')) spawn_flags |= T.SPAWN_BEFORE;
    if (args.has('f')) spawn_flags |= T.SPAWN_FULLSIZE;

    const lcnew = layout_mod.layout_split_pane(dst_wp, type_, size, @intCast(spawn_flags)) orelse {
        cmdq.cmdq_error(item, "create pane failed: pane too small", .{});
        return .@"error";
    };

    const source_was_last = win.window_count_panes(src_w) == 1;
    layout_mod.layout_close_pane(src_wp);
    _ = win.window_detach_pane(src_w, src_wp);
    win.window_adopt_pane_before(dst_w, src_wp, insertion_anchor(dst_w, dst_wp, args.has('b')));
    layout_mod.layout_assign_pane(lcnew, src_wp, 0);

    if (!args.has('d')) {
        _ = win.window_set_active_pane(dst_w, src_wp, true);
        dst_s.curw = dst_wl;
        var current = cmdq.cmdq_get_current(item);
        current.s = dst_s;
        current.wl = dst_wl;
        current.w = dst_w;
        current.wp = src_wp;
        current.idx = dst_wl.idx;
        item.state.current = current;
    }

    if (source_was_last) {
        server_fn.server_kill_window(src_w, true);
    } else {
        server_fn.server_status_window(src_w);
        server_fn.server_redraw_session(src_s);
    }

    server_fn.server_status_window(dst_w);
    server_fn.server_redraw_session(dst_s);
    return .normal;
}

fn parse_join_size(
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

fn insertion_anchor(w: *T.Window, target: *T.WindowPane, before: bool) ?*T.WindowPane {
    if (before) return target;
    for (w.panes.items, 0..) |pane, idx| {
        if (pane != target) continue;
        if (idx + 1 >= w.panes.items.len) return null;
        return w.panes.items[idx + 1];
    }
    return null;
}

pub const entry_join: cmd_mod.CmdEntry = .{
    .name = "join-pane",
    .alias = "joinp",
    .usage = "[-bd] [-s src-pane] [-t dst-pane]",
    .template = "bdfhvp:l:s:t:",
    .lower = 0,
    .upper = 0,
    .flags = 0,
    .exec = exec,
};

pub const entry_move: cmd_mod.CmdEntry = .{
    .name = "move-pane",
    .alias = "movep",
    .usage = "[-bd] [-s src-pane] [-t dst-pane]",
    .template = "bdfhvp:l:s:t:",
    .lower = 0,
    .upper = 0,
    .flags = 0,
    .exec = exec,
};

test "join-pane moves a pane into another window and keeps source window alive when needed" {
    const opts = @import("options.zig");
    const env_mod = @import("environ.zig");
    const sess = @import("session.zig");
    const spawn = @import("spawn.zig");

    sess.session_init_globals(@import("xmalloc.zig").allocator);
    win.window_init_globals(@import("xmalloc.zig").allocator);

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

    const s = sess.session_create(null, "join-pane-test", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("join-pane-test") != null) sess.session_destroy(s, false, "test");

    var cause: ?[]u8 = null;
    var src_ctx: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const src_wl = spawn.spawn_window(&src_ctx, &cause).?;
    var src_split_ctx: T.SpawnContext = .{ .s = s, .wl = src_wl, .flags = T.SPAWN_EMPTY };
    const moved = spawn.spawn_pane(&src_split_ctx, &cause).?;
    var dst_ctx: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const dst_wl = spawn.spawn_window(&dst_ctx, &cause).?;
    s.curw = src_wl;

    const src_target = std.fmt.allocPrint(@import("xmalloc.zig").allocator, "%{d}", .{moved.id}) catch unreachable;
    defer @import("xmalloc.zig").allocator.free(src_target);
    const dst_target = "join-pane-test:1.0";

    var parse_cause: ?[]u8 = null;
    const join_cmd = try cmd_mod.cmd_parse_one(&.{ "join-pane", "-s", src_target, "-t", dst_target }, null, &parse_cause);
    defer cmd_mod.cmd_free(join_cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(join_cmd, &item));

    try std.testing.expectEqual(@as(usize, 1), src_wl.window.panes.items.len);
    try std.testing.expectEqual(@as(usize, 2), dst_wl.window.panes.items.len);
    try std.testing.expectEqual(dst_wl.window, moved.window);
}

test "move-pane removes the source window when its last pane moves out" {
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

    const s = sess.session_create(null, "move-pane-test", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("move-pane-test") != null) sess.session_destroy(s, false, "test");

    var cause: ?[]u8 = null;
    var src_ctx: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const src_wl = spawn.spawn_window(&src_ctx, &cause).?;
    const src_wp = src_wl.window.active.?;
    var dst_ctx: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const dst_wl = spawn.spawn_window(&dst_ctx, &cause).?;

    const src_target = std.fmt.allocPrint(xm.allocator, "%{d}", .{src_wp.id}) catch unreachable;
    defer xm.allocator.free(src_target);

    var parse_cause: ?[]u8 = null;
    const move_cmd = try cmd_mod.cmd_parse_one(&.{ "move-pane", "-s", src_target, "-t", "move-pane-test:1.0" }, null, &parse_cause);
    defer cmd_mod.cmd_free(move_cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(move_cmd, &item));

    try std.testing.expect(sess.winlink_find_by_index(&s.windows, 0) == null);
    try std.testing.expectEqual(@as(usize, 2), dst_wl.window.panes.items.len);
    try std.testing.expectEqual(dst_wl.window, src_wp.window);
}

test "join-pane -b inserts before the destination and -d preserves current pane" {
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

    const s = sess.session_create(null, "join-before", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("join-before") != null) sess.session_destroy(s, false, "test");

    var cause: ?[]u8 = null;
    var src_ctx: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const src_wl = spawn.spawn_window(&src_ctx, &cause).?;
    const src_wp = src_wl.window.active.?;
    var dst_ctx: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const dst_wl = spawn.spawn_window(&dst_ctx, &cause).?;
    var dst_split_ctx: T.SpawnContext = .{ .s = s, .wl = dst_wl, .flags = T.SPAWN_EMPTY };
    const dst_second = spawn.spawn_pane(&dst_split_ctx, &cause).?;
    _ = win.window_set_active_pane(dst_wl.window, dst_second, true);

    const src_target = std.fmt.allocPrint(xm.allocator, "%{d}", .{src_wp.id}) catch unreachable;
    defer xm.allocator.free(src_target);
    const dst_target = std.fmt.allocPrint(xm.allocator, "%{d}", .{dst_second.id}) catch unreachable;
    defer xm.allocator.free(dst_target);

    var parse_cause: ?[]u8 = null;
    const join_cmd = try cmd_mod.cmd_parse_one(&.{ "join-pane", "-b", "-d", "-s", src_target, "-t", dst_target }, null, &parse_cause);
    defer cmd_mod.cmd_free(join_cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(join_cmd, &item));

    try std.testing.expectEqual(@as(usize, 3), dst_wl.window.panes.items.len);
    try std.testing.expectEqual(src_wp, dst_wl.window.panes.items[1]);
    try std.testing.expectEqual(dst_second, dst_wl.window.active.?);
}

test "join-pane applies horizontal sizing flags and closes the source gap" {
    const opts = @import("options.zig");
    const env_mod = @import("environ.zig");
    const sess = @import("session.zig");
    const spawn = @import("spawn.zig");
    const xm_local = @import("xmalloc.zig");

    sess.session_init_globals(xm_local.allocator);
    win.window_init_globals(xm_local.allocator);

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

    const s = sess.session_create(null, "join-size", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("join-size") != null) sess.session_destroy(s, false, "test");

    var cause: ?[]u8 = null;
    var src_ctx: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const src_wl = spawn.spawn_window(&src_ctx, &cause).?;
    const src_first = src_wl.window.active.?;
    var src_second_ctx: T.SpawnContext = .{ .s = s, .wl = src_wl, .flags = T.SPAWN_EMPTY };
    const moved = spawn.spawn_pane(&src_second_ctx, &cause).?;
    const src_plan = try win.window_plan_split(src_first, .leftright, 25, 0);
    win.window_apply_split_plan(src_first, moved, src_plan);

    var dst_ctx: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const dst_wl = spawn.spawn_window(&dst_ctx, &cause).?;
    s.curw = src_wl;

    const src_target = std.fmt.allocPrint(xm_local.allocator, "%{d}", .{moved.id}) catch unreachable;
    defer xm_local.allocator.free(src_target);
    const dst_target = std.fmt.allocPrint(xm_local.allocator, "%{d}", .{dst_wl.window.active.?.id}) catch unreachable;
    defer xm_local.allocator.free(dst_target);

    var parse_cause: ?[]u8 = null;
    const join_cmd = try cmd_mod.cmd_parse_one(&.{ "join-pane", "-h", "-l", "25", "-s", src_target, "-t", dst_target }, null, &parse_cause);
    defer cmd_mod.cmd_free(join_cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(join_cmd, &item));

    try std.testing.expectEqual(@as(usize, 1), src_wl.window.panes.items.len);
    try std.testing.expectEqual(@as(u32, 80), src_first.sx);
    try std.testing.expectEqual(@as(u32, 24), src_first.sy);
    try std.testing.expectEqual(@as(usize, 2), dst_wl.window.panes.items.len);
    try std.testing.expectEqual(@as(u32, 54), dst_wl.window.panes.items[0].sx);
    try std.testing.expectEqual(@as(u32, 25), moved.sx);
    try std.testing.expectEqual(@as(u32, 55), moved.xoff);
}

test "join-pane -f full-size sizing succeeds on both single-pane and multi-pane targets" {
    const opts = @import("options.zig");
    const env_mod = @import("environ.zig");
    const sess = @import("session.zig");
    const spawn = @import("spawn.zig");
    const xm_local = @import("xmalloc.zig");

    sess.session_init_globals(xm_local.allocator);
    win.window_init_globals(xm_local.allocator);

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

    const s = sess.session_create(null, "join-fullsize", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("join-fullsize") != null) sess.session_destroy(s, false, "test");

    var cause: ?[]u8 = null;
    var src_ctx: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const src_wl = spawn.spawn_window(&src_ctx, &cause).?;
    const moved = src_wl.window.active.?;

    var dst_ctx: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const dst_wl = spawn.spawn_window(&dst_ctx, &cause).?;

    const src_target = std.fmt.allocPrint(xm_local.allocator, "%{d}", .{moved.id}) catch unreachable;
    defer xm_local.allocator.free(src_target);
    const dst_target = std.fmt.allocPrint(xm_local.allocator, "%{d}", .{dst_wl.window.active.?.id}) catch unreachable;
    defer xm_local.allocator.free(dst_target);

    var parse_cause: ?[]u8 = null;
    const ok_cmd = try cmd_mod.cmd_parse_one(&.{ "join-pane", "-f", "-s", src_target, "-t", dst_target }, null, &parse_cause);
    defer cmd_mod.cmd_free(ok_cmd);
    var ok_list: cmd_mod.CmdList = .{};
    var ok_item = cmdq.CmdqItem{ .client = null, .cmdlist = &ok_list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(ok_cmd, &ok_item));

    // After the full-size join the destination window has two panes.
    try std.testing.expectEqual(@as(usize, 2), dst_wl.window.panes.items.len);

    // A second full-size join into the same (now multi-pane) target also works.
    var second_src_ctx: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const second_src_wl = spawn.spawn_window(&second_src_ctx, &cause).?;
    const second_moved = second_src_wl.window.active.?;

    const still_dst = dst_wl.window.panes.items[0];
    const second_src_target = std.fmt.allocPrint(xm_local.allocator, "%{d}", .{second_moved.id}) catch unreachable;
    defer xm_local.allocator.free(second_src_target);
    const same_dst_target = std.fmt.allocPrint(xm_local.allocator, "%{d}", .{still_dst.id}) catch unreachable;
    defer xm_local.allocator.free(same_dst_target);

    parse_cause = null;
    const also_ok_cmd = try cmd_mod.cmd_parse_one(&.{ "join-pane", "-f", "-s", second_src_target, "-t", same_dst_target }, null, &parse_cause);
    defer cmd_mod.cmd_free(also_ok_cmd);
    var also_ok_list: cmd_mod.CmdList = .{};
    var also_ok_item = cmdq.CmdqItem{ .client = null, .cmdlist = &also_ok_list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(also_ok_cmd, &also_ok_item));
    try std.testing.expectEqual(@as(usize, 3), dst_wl.window.panes.items.len);
}
