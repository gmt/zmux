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
// Ported in part from tmux/cmd-swap-window.c.
// Original copyright:
//   Copyright (c) 2007 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const cmd_mod = @import("cmd.zig");
const cmdq = @import("cmd-queue.zig");
const cmd_find = @import("cmd-find.zig");
const resize_mod = @import("resize.zig");
const server_fn = @import("server-fn.zig");
const sess = @import("session.zig");
const win = @import("window.zig");

fn exec(cmd: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {
    const args = cmd_mod.cmd_get_args(cmd);

    var source: T.CmdFindState = .{};
    if (cmd_find.cmd_find_target(&source, item, args.get('s'), .window, 0) != 0)
        return .@"error";
    const src = source.s orelse return .@"error";
    const wl_src = source.wl orelse return .@"error";

    var target: T.CmdFindState = .{};
    if (cmd_find.cmd_find_target(&target, item, args.get('t'), .window, T.CMD_FIND_WINDOW_INDEX) != 0)
        return .@"error";
    const dst = target.s orelse return .@"error";
    const wl_dst = target.wl orelse return .@"error";

    const sg_src = sess.session_group_contains(src);
    const sg_dst = sess.session_group_contains(dst);
    if (src != dst and sg_src != null and sg_dst != null and sg_src.? == sg_dst.?) {
        cmdq.cmdq_error(item, "can't move window, sessions are grouped", .{});
        return .@"error";
    }

    if (wl_src.window == wl_dst.window) return .normal;

    const w_src = wl_src.window;
    const w_dst = wl_dst.window;
    sess.session_rebind_winlink(wl_dst, w_src);
    sess.session_rebind_winlink(wl_src, w_dst);

    if (args.has('d')) {
        _ = sess.session_set_current(dst, wl_dst);
        if (src != dst)
            _ = sess.session_set_current(src, wl_src);
    }

    sess.session_group_synchronize_from(src);
    server_fn.server_redraw_session_group(src);
    if (src != dst) {
        sess.session_group_synchronize_from(dst);
        server_fn.server_redraw_session_group(dst);
    }
    resize_mod.recalculate_sizes();
    return .normal;
}

pub const entry: cmd_mod.CmdEntry = .{
    .name = "swap-window",
    .alias = "swapw",
    .usage = "[-d] [-s source-window] [-t target-window]",
    .template = "ds:t:",
    .lower = 0,
    .upper = 0,
    .flags = 0,
    .exec = exec,
};

fn init_test_state() void {
    const opts = @import("options.zig");
    const env_mod = @import("environ.zig");

    sess.session_init_globals(xm.allocator);
    win.window_init_globals(xm.allocator);

    opts.global_options = opts.options_create(null);
    opts.global_s_options = opts.options_create(null);
    opts.global_w_options = opts.options_create(null);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);

    env_mod.global_environ = env_mod.environ_create();
}

fn deinit_test_state() void {
    const opts = @import("options.zig");
    const env_mod = @import("environ.zig");

    env_mod.environ_free(env_mod.global_environ);
    opts.options_free(opts.global_w_options);
    opts.options_free(opts.global_s_options);
    opts.options_free(opts.global_options);
}

test "swap-window exchanges linked windows without disturbing current winlink" {
    const env_mod = @import("environ.zig");
    const opts = @import("options.zig");
    const spawn = @import("spawn.zig");

    init_test_state();
    defer deinit_test_state();

    const s = sess.session_create(null, "swap-window-local", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("swap-window-local") != null) sess.session_destroy(s, false, "test");

    var cause: ?[]u8 = null;
    var first_ctx: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const first = spawn.spawn_window(&first_ctx, &cause).?;
    var second_ctx: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const second = spawn.spawn_window(&second_ctx, &cause).?;
    s.curw = first;

    const first_window = first.window;
    const second_window = second.window;

    var parse_cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "swap-window", "-s", "swap-window-local:0", "-t", "swap-window-local:1" }, null, &parse_cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));

    try std.testing.expectEqual(first, s.curw.?);
    try std.testing.expectEqual(second_window, first.window);
    try std.testing.expectEqual(first_window, second.window);
    try std.testing.expectEqual(@as(usize, 1), first_window.winlinks.items.len);
    try std.testing.expectEqual(@as(usize, 1), second_window.winlinks.items.len);
    try std.testing.expectEqual(second, first_window.winlinks.items[0]);
    try std.testing.expectEqual(first, second_window.winlinks.items[0]);
}

test "swap-window -d selects the swapped winlinks in both sessions" {
    const env_mod = @import("environ.zig");
    const opts = @import("options.zig");
    const spawn = @import("spawn.zig");

    init_test_state();
    defer deinit_test_state();

    const src = sess.session_create(null, "swap-window-src", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("swap-window-src") != null) sess.session_destroy(src, false, "test");
    const dst = sess.session_create(null, "swap-window-dst", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("swap-window-dst") != null) sess.session_destroy(dst, false, "test");

    var cause: ?[]u8 = null;
    var src_a_ctx: T.SpawnContext = .{ .s = src, .idx = -1, .flags = T.SPAWN_EMPTY };
    const src_a = spawn.spawn_window(&src_a_ctx, &cause).?;
    var src_b_ctx: T.SpawnContext = .{ .s = src, .idx = -1, .flags = T.SPAWN_EMPTY };
    const src_b = spawn.spawn_window(&src_b_ctx, &cause).?;
    var dst_a_ctx: T.SpawnContext = .{ .s = dst, .idx = -1, .flags = T.SPAWN_EMPTY };
    const dst_a = spawn.spawn_window(&dst_a_ctx, &cause).?;
    var dst_b_ctx: T.SpawnContext = .{ .s = dst, .idx = -1, .flags = T.SPAWN_EMPTY };
    const dst_b = spawn.spawn_window(&dst_b_ctx, &cause).?;

    const src_a_window = src_a.window;
    const dst_a_window = dst_a.window;

    src.curw = src_b;
    dst.curw = dst_b;

    var parse_cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "swap-window", "-d", "-s", "swap-window-src:0", "-t", "swap-window-dst:0" }, null, &parse_cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));

    try std.testing.expectEqual(src_a, src.curw.?);
    try std.testing.expectEqual(dst_a, dst.curw.?);
    try std.testing.expectEqual(dst_a_window, src_a.window);
    try std.testing.expectEqual(src_a_window, dst_a.window);
}

test "swap-window rejects swapping sessions inside the same group" {
    const env_mod = @import("environ.zig");
    const opts = @import("options.zig");
    const spawn = @import("spawn.zig");

    init_test_state();
    defer deinit_test_state();

    const src = sess.session_create(null, "swap-window-group-a", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("swap-window-group-a") != null) sess.session_destroy(src, false, "test");
    const dst = sess.session_create(null, "swap-window-group-b", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("swap-window-group-b") != null) sess.session_destroy(dst, false, "test");

    const group = sess.session_group_new("swap-window-group");
    sess.session_group_add(group, src);
    sess.session_group_add(group, dst);

    var cause: ?[]u8 = null;
    var src_ctx: T.SpawnContext = .{ .s = src, .idx = -1, .flags = T.SPAWN_EMPTY };
    const src_wl = spawn.spawn_window(&src_ctx, &cause).?;
    var dst_ctx: T.SpawnContext = .{ .s = dst, .idx = -1, .flags = T.SPAWN_EMPTY };
    const dst_wl = spawn.spawn_window(&dst_ctx, &cause).?;

    const src_window = src_wl.window;
    const dst_window = dst_wl.window;

    var parse_cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "swap-window", "-s", "swap-window-group-a:0", "-t", "swap-window-group-b:0" }, null, &parse_cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.@"error", cmd_mod.cmd_execute(cmd, &item));
    try std.testing.expectEqual(src_window, src_wl.window);
    try std.testing.expectEqual(dst_window, dst_wl.window);
}

test "swap-window synchronizes grouped peers after a cross-session swap" {
    const env_mod = @import("environ.zig");
    const opts = @import("options.zig");
    const spawn = @import("spawn.zig");

    init_test_state();
    defer deinit_test_state();

    const src = sess.session_create(null, "swap-window-sync-src", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("swap-window-sync-src") != null) sess.session_destroy(src, false, "test");
    const src_peer = sess.session_create(null, "swap-window-sync-src-peer", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("swap-window-sync-src-peer") != null) sess.session_destroy(src_peer, false, "test");
    const dst = sess.session_create(null, "swap-window-sync-dst", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("swap-window-sync-dst") != null) sess.session_destroy(dst, false, "test");
    const dst_peer = sess.session_create(null, "swap-window-sync-dst-peer", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("swap-window-sync-dst-peer") != null) sess.session_destroy(dst_peer, false, "test");

    const src_group = sess.session_group_new("swap-window-sync-group-src");
    sess.session_group_add(src_group, src);
    sess.session_group_add(src_group, src_peer);
    const dst_group = sess.session_group_new("swap-window-sync-group-dst");
    sess.session_group_add(dst_group, dst);
    sess.session_group_add(dst_group, dst_peer);

    var cause: ?[]u8 = null;
    var src_ctx: T.SpawnContext = .{ .s = src, .idx = -1, .flags = T.SPAWN_EMPTY };
    const src_wl = spawn.spawn_window(&src_ctx, &cause).?;
    var dst_ctx: T.SpawnContext = .{ .s = dst, .idx = -1, .flags = T.SPAWN_EMPTY };
    const dst_wl = spawn.spawn_window(&dst_ctx, &cause).?;

    sess.session_group_synchronize_from(src);
    sess.session_group_synchronize_from(dst);

    var parse_cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "swap-window", "-s", "swap-window-sync-src:0", "-t", "swap-window-sync-dst:0" }, null, &parse_cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));

    const src_peer_wl = sess.winlink_find_by_index(&src_peer.windows, 0).?;
    const dst_peer_wl = sess.winlink_find_by_index(&dst_peer.windows, 0).?;
    try std.testing.expectEqual(src_wl.window, src_peer_wl.window);
    try std.testing.expectEqual(dst_wl.window, dst_peer_wl.window);
}
