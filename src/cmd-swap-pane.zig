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
// Ported in part from tmux/cmd-swap-pane.c.
// Original copyright:
//   Copyright (c) 2009 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

const std = @import("std");
const T = @import("types.zig");
const cmd_mod = @import("cmd.zig");
const cmdq = @import("cmd-queue.zig");
const cmd_find = @import("cmd-find.zig");
const server_fn = @import("server-fn.zig");
const win = @import("window.zig");

fn exec(cmd: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {
    const args = cmd_mod.cmd_get_args(cmd);
    if (args.has('Z')) {
        cmdq.cmdq_error(item, "zoom-aware pane swapping not supported yet", .{});
        return .@"error";
    }

    var target: T.CmdFindState = .{};
    if (cmd_find.cmd_find_target(&target, item, args.get('t'), .pane, 0) != 0)
        return .@"error";
    const dst_s = target.s orelse return .@"error";
    const dst_wl = target.wl orelse return .@"error";
    const dst_w = dst_wl.window;
    const dst_wp = target.wp orelse return .@"error";

    var source: T.CmdFindState = .{};
    if (args.has('D') or args.has('U')) {
        source = target;
        source.wp = adjacent_pane(dst_w, dst_wp, args.has('D')) orelse dst_wp;
    } else {
        if (cmd_find.cmd_find_target(&source, item, args.get('s'), .pane, 0) != 0)
            return .@"error";
    }
    const src_s = source.s orelse return .@"error";
    const src_wl = source.wl orelse return .@"error";
    const src_w = src_wl.window;
    const src_wp = source.wp orelse return .@"error";

    if (src_wp == dst_wp) return .normal;

    if (src_w == dst_w) {
        swap_within_window(src_w, src_wp, dst_wp);
    } else {
        swap_across_windows(src_w, src_wp, dst_w, dst_wp);
    }

    if (!args.has('d')) {
        if (src_w != dst_w) {
            _ = win.window_set_active_pane(src_w, dst_wp, true);
            _ = win.window_set_active_pane(dst_w, src_wp, true);
        } else {
            _ = win.window_set_active_pane(src_w, dst_wp, true);
        }
        dst_s.curw = dst_wl;
    } else {
        if (src_w.active == src_wp) _ = win.window_set_active_pane(src_w, dst_wp, true);
        if (dst_w.active == dst_wp) _ = win.window_set_active_pane(dst_w, src_wp, true);
    }

    server_fn.server_status_window(src_w);
    server_fn.server_redraw_session(src_s);
    if (src_w != dst_w) {
        server_fn.server_status_window(dst_w);
        server_fn.server_redraw_session(dst_s);
    }
    return .normal;
}

fn adjacent_pane(w: *T.Window, pivot: *T.WindowPane, forward: bool) ?*T.WindowPane {
    const idx = win.window_pane_index(w, pivot) orelse return null;
    if (w.panes.items.len <= 1) return pivot;
    if (forward) {
        return if (idx + 1 < w.panes.items.len) w.panes.items[idx + 1] else w.panes.items[0];
    }
    return if (idx > 0) w.panes.items[idx - 1] else w.panes.items[w.panes.items.len - 1];
}

fn swap_within_window(w: *T.Window, a: *T.WindowPane, b: *T.WindowPane) void {
    const a_idx = win.window_pane_index(w, a) orelse return;
    const b_idx = win.window_pane_index(w, b) orelse return;
    if (a_idx == b_idx) return;

    const a_sx = a.sx;
    const a_sy = a.sy;
    const a_xoff = a.xoff;
    const a_yoff = a.yoff;
    a.sx = b.sx;
    a.sy = b.sy;
    a.xoff = b.xoff;
    a.yoff = b.yoff;
    b.sx = a_sx;
    b.sy = a_sy;
    b.xoff = a_xoff;
    b.yoff = a_yoff;

    w.panes.items[a_idx] = b;
    w.panes.items[b_idx] = a;
}

fn swap_across_windows(src_w: *T.Window, src_wp: *T.WindowPane, dst_w: *T.Window, dst_wp: *T.WindowPane) void {
    const src_idx = win.window_pane_index(src_w, src_wp) orelse return;
    const dst_idx = win.window_pane_index(dst_w, dst_wp) orelse return;

    const src_sx = src_wp.sx;
    const src_sy = src_wp.sy;
    const src_xoff = src_wp.xoff;
    const src_yoff = src_wp.yoff;

    src_w.panes.items[src_idx] = dst_wp;
    dst_w.panes.items[dst_idx] = src_wp;

    dst_wp.window = src_w;
    dst_wp.options.parent = src_w.options;
    win.window_pane_options_changed(dst_wp, null);

    src_wp.window = dst_w;
    src_wp.options.parent = dst_w.options;
    win.window_pane_options_changed(src_wp, null);

    src_wp.sx = dst_wp.sx;
    src_wp.sy = dst_wp.sy;
    src_wp.xoff = dst_wp.xoff;
    src_wp.yoff = dst_wp.yoff;
    dst_wp.sx = src_sx;
    dst_wp.sy = src_sy;
    dst_wp.xoff = src_xoff;
    dst_wp.yoff = src_yoff;

    win.window_forget_pane_history(src_w, src_wp);
    win.window_forget_pane_history(dst_w, dst_wp);
}

pub const entry: cmd_mod.CmdEntry = .{
    .name = "swap-pane",
    .alias = "swapp",
    .usage = "[-dDU] [-s src-pane] [-t dst-pane]",
    .template = "dDs:t:UZ",
    .lower = 0,
    .upper = 0,
    .flags = 0,
    .exec = exec,
};

test "swap-pane swaps panes across windows" {
    const opts = @import("options.zig");
    const env_mod = @import("environ.zig");
    const sess = @import("session.zig");
    const spawn = @import("spawn.zig");
    const xm = @import("xmalloc.zig");

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

    const s = sess.session_create(null, "swap-pane-test", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("swap-pane-test") != null) sess.session_destroy(s, false, "test");

    var cause: ?[]u8 = null;
    var src_ctx: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const src_wl = spawn.spawn_window(&src_ctx, &cause).?;
    const src_wp = src_wl.window.active.?;
    var dst_ctx: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const dst_wl = spawn.spawn_window(&dst_ctx, &cause).?;
    const dst_wp = dst_wl.window.active.?;

    const src_target = std.fmt.allocPrint(xm.allocator, "%{d}", .{src_wp.id}) catch unreachable;
    defer xm.allocator.free(src_target);
    const dst_target = std.fmt.allocPrint(xm.allocator, "%{d}", .{dst_wp.id}) catch unreachable;
    defer xm.allocator.free(dst_target);

    var parse_cause: ?[]u8 = null;
    const swap_cmd = try cmd_mod.cmd_parse_one(&.{ "swap-pane", "-s", src_target, "-t", dst_target }, null, &parse_cause);
    defer cmd_mod.cmd_free(swap_cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(swap_cmd, &item));

    try std.testing.expectEqual(dst_wl.window, src_wp.window);
    try std.testing.expectEqual(src_wl.window, dst_wp.window);
    try std.testing.expectEqual(src_wl.window.options, dst_wp.options.parent.?);
    try std.testing.expectEqual(dst_wl.window.options, src_wp.options.parent.?);
}

test "swap-pane -D and -U rotate within a window" {
    const opts = @import("options.zig");
    const env_mod = @import("environ.zig");
    const sess = @import("session.zig");
    const spawn = @import("spawn.zig");
    const xm = @import("xmalloc.zig");

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

    const s = sess.session_create(null, "swap-rotate", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("swap-rotate") != null) sess.session_destroy(s, false, "test");

    var cause: ?[]u8 = null;
    var ctx: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const wl = spawn.spawn_window(&ctx, &cause).?;
    const first = wl.window.active.?;
    var second_ctx: T.SpawnContext = .{ .s = s, .wl = wl, .flags = T.SPAWN_EMPTY };
    const second = spawn.spawn_pane(&second_ctx, &cause).?;
    var third_ctx: T.SpawnContext = .{ .s = s, .wl = wl, .flags = T.SPAWN_EMPTY };
    const third = spawn.spawn_pane(&third_ctx, &cause).?;
    _ = win.window_set_active_pane(wl.window, second, true);

    var parse_cause: ?[]u8 = null;
    const swap_down = try cmd_mod.cmd_parse_one(&.{ "swap-pane", "-D", "-t", "swap-rotate:0.1" }, null, &parse_cause);
    defer cmd_mod.cmd_free(swap_down);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(swap_down, &item));
    try std.testing.expectEqual(second, wl.window.panes.items[2]);

    const swap_up = try cmd_mod.cmd_parse_one(&.{ "swap-pane", "-U", "-t", "swap-rotate:0.2", "-d" }, null, &parse_cause);
    defer cmd_mod.cmd_free(swap_up);
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(swap_up, &item));
    try std.testing.expectEqual(second, wl.window.panes.items[1]);
    try std.testing.expectEqual(third, wl.window.active.?);
    _ = first;
}

test "swap-pane rejects unsupported zoom swap" {
    var parse_cause: ?[]u8 = null;
    const swap_cmd = try cmd_mod.cmd_parse_one(&.{ "swap-pane", "-Z" }, null, &parse_cause);
    defer cmd_mod.cmd_free(swap_cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.@"error", cmd_mod.cmd_execute(swap_cmd, &item));
}
