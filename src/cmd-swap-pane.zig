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
//   ISC licence - same terms as above.

const std = @import("std");
const T = @import("types.zig");
const cmd_mod = @import("cmd.zig");
const cmdq = @import("cmd-queue.zig");
const cmd_find = @import("cmd-find.zig");
const marked_pane_mod = @import("marked-pane.zig");
const server_fn = @import("server-fn.zig");
const win = @import("window.zig");

fn exec(cmd: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {
    const args = cmd_mod.cmd_get_args(cmd);

    var target: T.CmdFindState = .{};
    if (cmd_find.cmd_find_target(&target, item, args.get('t'), .pane, 0) != 0)
        return .@"error";
    const dst_wl = target.wl orelse return .@"error";
    const dst_w = dst_wl.window;
    const dst_wp = target.wp orelse return .@"error";

    if (win.window_push_zoom(dst_w, false, args.has('Z')))
        server_fn.server_redraw_window(dst_w);

    var source: T.CmdFindState = .{};
    if (args.has('D') or args.has('U')) {
        source = target;
        source.wp = adjacent_pane(dst_w, dst_wp, args.has('D')) orelse dst_wp;
    } else {
        if (cmd_find.cmd_find_target(&source, item, args.get('s'), .pane, T.CMD_FIND_DEFAULT_MARKED) != 0)
            return .@"error";
    }
    const src_wl = source.wl orelse return .@"error";
    const src_w = src_wl.window;
    const src_wp = source.wp orelse return .@"error";

    if (src_w != dst_w and win.window_push_zoom(src_w, false, args.has('Z')))
        server_fn.server_redraw_window(src_w);
    defer {
        if (win.window_pop_zoom(src_w))
            server_fn.server_redraw_window(src_w);
        if (src_w != dst_w and win.window_pop_zoom(dst_w))
            server_fn.server_redraw_window(dst_w);
    }

    if (src_wp == dst_wp) return .normal;

    if (src_w == dst_w) {
        swap_within_window(src_w, src_wp, dst_wp);
    } else {
        swap_across_windows(src_w, src_wp, dst_w, dst_wp);
        rebindMarkedPane(&source, src_wp, &target, dst_wp);
    }

    if (!args.has('d')) {
        if (src_w != dst_w) {
            _ = win.window_set_active_pane(src_w, dst_wp, true);
            _ = win.window_set_active_pane(dst_w, src_wp, true);
        } else {
            _ = win.window_set_active_pane(src_w, dst_wp, true);
        }
    } else {
        if (src_w.active == src_wp) _ = win.window_set_active_pane(src_w, dst_wp, true);
        if (dst_w.active == dst_wp) _ = win.window_set_active_pane(dst_w, src_wp, true);
    }

    if (src_w != dst_w) {
        server_fn.server_redraw_window(src_w);
        server_fn.server_status_window(src_w);
    }
    server_fn.server_redraw_window(dst_w);
    server_fn.server_status_window(dst_w);
    return .normal;
}

const PaneSlot = struct {
    layout_cell: ?*T.LayoutCell,
    sx: u32,
    sy: u32,
    xoff: u32,
    yoff: u32,
};

fn capture_pane_slot(wp: *T.WindowPane) PaneSlot {
    return .{
        .layout_cell = wp.layout_cell,
        .sx = wp.sx,
        .sy = wp.sy,
        .xoff = wp.xoff,
        .yoff = wp.yoff,
    };
}

fn apply_pane_slot(wp: *T.WindowPane, slot: PaneSlot) void {
    wp.layout_cell = slot.layout_cell;
    if (wp.layout_cell) |lc| lc.wp = wp;
    wp.xoff = slot.xoff;
    wp.yoff = slot.yoff;
    win.window_pane_resize(wp, slot.sx, slot.sy);
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

    const a_slot = capture_pane_slot(a);
    const b_slot = capture_pane_slot(b);

    w.panes.items[a_idx] = b;
    w.panes.items[b_idx] = a;

    apply_pane_slot(b, a_slot);
    apply_pane_slot(a, b_slot);
}

fn swap_across_windows(src_w: *T.Window, src_wp: *T.WindowPane, dst_w: *T.Window, dst_wp: *T.WindowPane) void {
    const src_idx = win.window_pane_index(src_w, src_wp) orelse return;
    const dst_idx = win.window_pane_index(dst_w, dst_wp) orelse return;

    const src_slot = capture_pane_slot(src_wp);
    const dst_slot = capture_pane_slot(dst_wp);

    src_w.panes.items[src_idx] = dst_wp;
    dst_w.panes.items[dst_idx] = src_wp;

    dst_wp.window = src_w;
    dst_wp.options.parent = src_w.options;
    dst_wp.flags |= T.PANE_STYLECHANGED | T.PANE_THEMECHANGED;
    win.window_pane_options_changed(dst_wp, null);

    src_wp.window = dst_w;
    src_wp.options.parent = dst_w.options;
    src_wp.flags |= T.PANE_STYLECHANGED | T.PANE_THEMECHANGED;
    win.window_pane_options_changed(src_wp, null);

    apply_pane_slot(dst_wp, src_slot);
    apply_pane_slot(src_wp, dst_slot);

    win.window_forget_pane_history(src_w, src_wp);
    win.window_forget_pane_history(dst_w, dst_wp);
}

fn rebindMarkedPane(source: *const T.CmdFindState, src_wp: *T.WindowPane, target: *const T.CmdFindState, dst_wp: *T.WindowPane) void {
    if (marked_pane_mod.marked_pane.wp == src_wp) {
        marked_pane_mod.set(target.s.?, target.wl.?, src_wp);
    } else if (marked_pane_mod.marked_pane.wp == dst_wp) {
        marked_pane_mod.set(source.s.?, source.wl.?, dst_wp);
    }
}

pub const entry: cmd_mod.CmdEntry = .{
    .name = "swap-pane",
    .alias = "swapp",
    .usage = "[-dDUZ] [-s src-pane] [-t dst-pane]",
    .template = "dDs:t:UZ",
    .lower = 0,
    .upper = 0,
    .flags = 0,
    .exec = exec,
};

fn init_test_state() void {
    const env_mod = @import("environ.zig");
    const opts = @import("options.zig");
    const sess = @import("session.zig");
    const xm = @import("xmalloc.zig");

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
    const env_mod = @import("environ.zig");
    const opts = @import("options.zig");

    env_mod.environ_free(env_mod.global_environ);
    opts.options_free(opts.global_w_options);
    opts.options_free(opts.global_s_options);
    opts.options_free(opts.global_options);
}

test "swap-pane swaps panes across windows" {
    const env_mod = @import("environ.zig");
    const opts = @import("options.zig");
    const sess = @import("session.zig");
    const spawn = @import("spawn.zig");
    const xm = @import("xmalloc.zig");

    init_test_state();
    defer deinit_test_state();

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

test "swap-pane swaps layout slots and keeps current window stable" {
    const env_mod = @import("environ.zig");
    const opts = @import("options.zig");
    const sess = @import("session.zig");
    const spawn = @import("spawn.zig");
    const xm = @import("xmalloc.zig");

    init_test_state();
    defer deinit_test_state();

    const s = sess.session_create(null, "swap-pane-layout", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("swap-pane-layout") != null) sess.session_destroy(s, false, "test");

    var cause: ?[]u8 = null;
    var src_ctx: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const src_wl = spawn.spawn_window(&src_ctx, &cause).?;
    const src_wp = src_wl.window.active.?;
    var dst_ctx: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const dst_wl = spawn.spawn_window(&dst_ctx, &cause).?;
    const dst_wp = dst_wl.window.active.?;
    s.curw = src_wl;

    var src_cell = T.LayoutCell{ .wp = src_wp, .sx = src_wp.sx, .sy = src_wp.sy };
    var dst_cell = T.LayoutCell{ .wp = dst_wp, .sx = dst_wp.sx, .sy = dst_wp.sy };
    src_wp.layout_cell = &src_cell;
    dst_wp.layout_cell = &dst_cell;

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

    try std.testing.expectEqual(src_wl, s.curw.?);
    try std.testing.expectEqual(&src_cell, dst_wp.layout_cell.?);
    try std.testing.expectEqual(&dst_cell, src_wp.layout_cell.?);
    try std.testing.expectEqual(dst_wp, src_cell.wp.?);
    try std.testing.expectEqual(src_wp, dst_cell.wp.?);
}

test "swap-pane -D and -U rotate within a window" {
    const env_mod = @import("environ.zig");
    const opts = @import("options.zig");
    const sess = @import("session.zig");
    const spawn = @import("spawn.zig");

    init_test_state();
    defer deinit_test_state();

    const s = sess.session_create(null, "swap-rotate", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("swap-rotate") != null) sess.session_destroy(s, false, "test");

    var cause: ?[]u8 = null;
    var ctx: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const wl = spawn.spawn_window(&ctx, &cause).?;
    var second_ctx: T.SpawnContext = .{ .s = s, .wl = wl, .flags = T.SPAWN_EMPTY };
    _ = spawn.spawn_pane(&second_ctx, &cause).?;
    var third_ctx: T.SpawnContext = .{ .s = s, .wl = wl, .flags = T.SPAWN_EMPTY };
    _ = spawn.spawn_pane(&third_ctx, &cause).?;

    const before0 = wl.window.panes.items[0];
    const before1 = wl.window.panes.items[1];
    const before2 = wl.window.panes.items[2];
    const pivot_target = std.fmt.allocPrint(@import("xmalloc.zig").allocator, "%{d}", .{before1.id}) catch unreachable;
    defer @import("xmalloc.zig").allocator.free(pivot_target);

    var parse_cause: ?[]u8 = null;
    const swap_down = try cmd_mod.cmd_parse_one(&.{ "swap-pane", "-D", "-t", pivot_target }, null, &parse_cause);
    defer cmd_mod.cmd_free(swap_down);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(swap_down, &item));
    try std.testing.expectEqual(before0, wl.window.panes.items[0]);
    try std.testing.expectEqual(before2, wl.window.panes.items[1]);
    try std.testing.expectEqual(before1, wl.window.panes.items[2]);
    try std.testing.expectEqual(before1, wl.window.active.?);

    const swap_up = try cmd_mod.cmd_parse_one(&.{ "swap-pane", "-U", "-t", pivot_target, "-d" }, null, &parse_cause);
    defer cmd_mod.cmd_free(swap_up);
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(swap_up, &item));
    try std.testing.expectEqual(before0, wl.window.panes.items[0]);
    try std.testing.expectEqual(before1, wl.window.panes.items[1]);
    try std.testing.expectEqual(before2, wl.window.panes.items[2]);
    try std.testing.expectEqual(before2, wl.window.active.?);
}

test "swap-pane -Z preserves the reduced zoom flag" {
    const env_mod = @import("environ.zig");
    const opts = @import("options.zig");
    const sess = @import("session.zig");
    const spawn = @import("spawn.zig");

    init_test_state();
    defer deinit_test_state();

    const s = sess.session_create(null, "swap-pane-zoom", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("swap-pane-zoom") != null) sess.session_destroy(s, false, "test");

    var cause: ?[]u8 = null;
    var ctx: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const wl = spawn.spawn_window(&ctx, &cause).?;
    var second_ctx: T.SpawnContext = .{ .s = s, .wl = wl, .flags = T.SPAWN_EMPTY };
    const second = spawn.spawn_pane(&second_ctx, &cause).?;

    wl.window.flags |= T.WINDOW_ZOOMED;

    var parse_cause: ?[]u8 = null;
    const swap_cmd = try cmd_mod.cmd_parse_one(&.{ "swap-pane", "-Z", "-s", "swap-pane-zoom:0.0", "-t", "swap-pane-zoom:0.1" }, null, &parse_cause);
    defer cmd_mod.cmd_free(swap_cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(swap_cmd, &item));

    try std.testing.expectEqual(second, wl.window.panes.items[0]);
    try std.testing.expectEqual(second, wl.window.active.?);
    try std.testing.expect(wl.window.flags & T.WINDOW_ZOOMED != 0);
    try std.testing.expectEqual(@as(u32, 0), wl.window.flags & T.WINDOW_WASZOOMED);
}

test "swap-pane uses the marked pane as the default source" {
    const env_mod = @import("environ.zig");
    const opts = @import("options.zig");
    const sess = @import("session.zig");
    const spawn = @import("spawn.zig");
    const xm = @import("xmalloc.zig");

    init_test_state();
    defer deinit_test_state();
    marked_pane_mod.clear();
    defer marked_pane_mod.clear();

    const s = sess.session_create(null, "swap-pane-marked", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("swap-pane-marked") != null) sess.session_destroy(s, false, "test");

    var cause: ?[]u8 = null;
    var src_ctx: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const src_wl = spawn.spawn_window(&src_ctx, &cause).?;
    const src_wp = src_wl.window.active.?;
    var dst_ctx: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const dst_wl = spawn.spawn_window(&dst_ctx, &cause).?;
    const dst_wp = dst_wl.window.active.?;

    marked_pane_mod.set(s, src_wl, src_wp);

    const dst_target = std.fmt.allocPrint(xm.allocator, "%{d}", .{dst_wp.id}) catch unreachable;
    defer xm.allocator.free(dst_target);

    var parse_cause: ?[]u8 = null;
    const swap_cmd = try cmd_mod.cmd_parse_one(&.{ "swap-pane", "-t", dst_target }, null, &parse_cause);
    defer cmd_mod.cmd_free(swap_cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(swap_cmd, &item));

    try std.testing.expectEqual(dst_wl.window, src_wp.window);
    try std.testing.expectEqual(src_wl.window, dst_wp.window);
    try std.testing.expectEqual(dst_wl, marked_pane_mod.marked_pane.wl.?);
    try std.testing.expectEqual(src_wp, marked_pane_mod.marked_pane.wp.?);
}
