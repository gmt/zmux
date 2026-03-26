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
// Ported in part from tmux/cmd-resize-pane.c.
// Original copyright:
//   Copyright (c) 2009 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const cmd_mod = @import("cmd.zig");
const cmdq = @import("cmd-queue.zig");
const cmd_find = @import("cmd-find.zig");
const grid_mod = @import("grid.zig");
const server_fn = @import("server-fn.zig");
const win = @import("window.zig");

fn exec(cmd: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {
    const args = cmd_mod.cmd_get_args(cmd);

    var target: T.CmdFindState = .{};
    if (cmd_find.cmd_find_target(&target, item, args.get('t'), .pane, 0) != 0)
        return .@"error";
    const wp = target.wp orelse return .@"error";
    const wl = target.wl orelse return .@"error";
    const w = wl.window;

    if (args.has('T')) {
        trim_history(wp);
        return .normal;
    }
    if (args.has('M')) {
        cmdq.cmdq_error(item, "mouse resize not supported yet", .{});
        return .@"error";
    }
    if (args.has('Z')) {
        if (win.window_count_panes(w) > 1) {
            cmdq.cmdq_error(item, "zoom resize not supported yet", .{});
            return .@"error";
        }
        server_fn.server_status_window(w);
        return .normal;
    }

    if (has_layout_resize_request(args)) {
        cmdq.cmdq_error(item, "layout resize not supported yet", .{});
        return .@"error";
    }

    server_fn.server_status_window(wl.window);
    return .normal;
}

fn has_layout_resize_request(args: *const @import("arguments.zig").Arguments) bool {
    return args.has('x') or args.has('y') or
        args.has('L') or args.has('R') or args.has('U') or args.has('D');
}

fn trim_history(wp: *T.WindowPane) void {
    if (wp.modes.items.len != 0) return;

    const gd = wp.base.grid;
    if (gd.sy == 0) return;

    var adjust = gd.sy - 1 - @min(wp.base.cy, gd.sy - 1);
    if (adjust > gd.hsize) adjust = gd.hsize;
    if (adjust == 0) return;

    grid_mod.remove_history(gd, adjust);
    wp.base.cy += adjust;
    wp.flags |= T.PANE_REDRAW;
}

pub const entry: cmd_mod.CmdEntry = .{
    .name = "resize-pane",
    .alias = "resizep",
    .usage = "[-DLMRTUZ] [-x width] [-y height] [-t target-pane] [adjustment]",
    .template = "DLMRTt:Ux:y:Z",
    .lower = 0,
    .upper = 1,
    .flags = T.CMD_AFTERHOOK,
    .exec = exec,
};

fn init_test_globals() void {
    const opts = @import("options.zig");
    const env_mod = @import("environ.zig");
    const sess = @import("session.zig");
    const win_mod = @import("window.zig");

    sess.session_init_globals(xm.allocator);
    win_mod.window_init_globals(xm.allocator);

    opts.global_options = opts.options_create(null);
    opts.global_s_options = opts.options_create(null);
    opts.global_w_options = opts.options_create(null);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);

    env_mod.global_environ = env_mod.environ_create();
}

fn deinit_test_globals() void {
    const opts = @import("options.zig");
    const env_mod = @import("environ.zig");

    env_mod.environ_free(env_mod.global_environ);
    opts.options_free(opts.global_options);
    opts.options_free(opts.global_s_options);
    opts.options_free(opts.global_w_options);
}

test "resize-pane -T trims reduced history and advances the cursor" {
    const opts = @import("options.zig");
    const env_mod = @import("environ.zig");
    const sess = @import("session.zig");
    const spawn = @import("spawn.zig");

    init_test_globals();
    defer deinit_test_globals();

    const s = sess.session_create(null, "resize-pane-test", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("resize-pane-test") != null) sess.session_destroy(s, false, "test");

    var cause: ?[]u8 = null;
    var ctx: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const wl = spawn.spawn_window(&ctx, &cause).?;
    const wp = wl.window.active.?;

    const target = std.fmt.allocPrint(xm.allocator, "%{d}", .{wp.id}) catch unreachable;
    defer xm.allocator.free(target);

    wp.base.grid.hsize = 8;
    wp.base.cy = 3;

    var parse_cause: ?[]u8 = null;
    const resize_cmd = try cmd_mod.cmd_parse_one(&.{ "resize-pane", "-T", "-t", target }, null, &parse_cause);
    defer cmd_mod.cmd_free(resize_cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(resize_cmd, &item));

    try std.testing.expectEqual(@as(u32, 0), wp.base.grid.hsize);
    try std.testing.expectEqual(@as(u32, 11), wp.base.cy);
    try std.testing.expect(wp.flags & T.PANE_REDRAW != 0);
}

test "resize-pane -T is a no-op while a pane mode is active" {
    const opts = @import("options.zig");
    const env_mod = @import("environ.zig");
    const sess = @import("session.zig");
    const spawn = @import("spawn.zig");

    init_test_globals();
    defer deinit_test_globals();

    const s = sess.session_create(null, "resize-pane-dir", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("resize-pane-dir") != null) sess.session_destroy(s, false, "test");

    var cause: ?[]u8 = null;
    var ctx: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const wl = spawn.spawn_window(&ctx, &cause).?;
    const wp = wl.window.active.?;
    wp.base.grid.hsize = 8;
    wp.base.cy = 3;

    const dummy_mode = T.WindowMode{ .name = "dummy" };
    const wme = win.window_pane_push_mode(wp, &dummy_mode, null, null);
    defer _ = win.window_pane_pop_mode(wp, wme);

    const target = std.fmt.allocPrint(xm.allocator, "%{d}", .{wp.id}) catch unreachable;
    defer xm.allocator.free(target);

    var parse_cause: ?[]u8 = null;
    const trim_cmd = try cmd_mod.cmd_parse_one(&.{ "resize-pane", "-T", "-t", target }, null, &parse_cause);
    defer cmd_mod.cmd_free(trim_cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(trim_cmd, &item));
    try std.testing.expectEqual(@as(u32, 8), wp.base.grid.hsize);
    try std.testing.expectEqual(@as(u32, 3), wp.base.cy);
    try std.testing.expectEqual(@as(u32, 0), wp.flags & T.PANE_REDRAW);
}

test "resize-pane rejects layout-dependent geometry changes" {
    const opts = @import("options.zig");
    const env_mod = @import("environ.zig");
    const sess = @import("session.zig");
    const spawn = @import("spawn.zig");

    init_test_globals();
    defer deinit_test_globals();

    const s = sess.session_create(null, "resize-pane-layout", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("resize-pane-layout") != null) sess.session_destroy(s, false, "test");

    var cause: ?[]u8 = null;
    var ctx: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const wl = spawn.spawn_window(&ctx, &cause).?;
    const wp = wl.window.active.?;
    const old_sx = wp.sx;
    const old_sy = wp.sy;

    const target = std.fmt.allocPrint(xm.allocator, "%{d}", .{wp.id}) catch unreachable;
    defer xm.allocator.free(target);

    var parse_cause: ?[]u8 = null;
    const resize_cmd = try cmd_mod.cmd_parse_one(&.{ "resize-pane", "-t", target, "-x", "70", "-L", "2" }, null, &parse_cause);
    defer cmd_mod.cmd_free(resize_cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.@"error", cmd_mod.cmd_execute(resize_cmd, &item));
    try std.testing.expectEqual(old_sx, wp.sx);
    try std.testing.expectEqual(old_sy, wp.sy);
}

test "resize-pane -Z is a no-op for a single-pane window" {
    const opts = @import("options.zig");
    const env_mod = @import("environ.zig");
    const sess = @import("session.zig");
    const spawn = @import("spawn.zig");

    init_test_globals();
    defer deinit_test_globals();

    const s = sess.session_create(null, "resize-pane-zoom", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("resize-pane-zoom") != null) sess.session_destroy(s, false, "test");

    var cause: ?[]u8 = null;
    var ctx: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const wl = spawn.spawn_window(&ctx, &cause).?;

    var parse_cause: ?[]u8 = null;
    const resize_cmd = try cmd_mod.cmd_parse_one(&.{ "resize-pane", "-t", "resize-pane-zoom:0.0", "-Z" }, null, &parse_cause);
    defer cmd_mod.cmd_free(resize_cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(resize_cmd, &item));
    try std.testing.expectEqual(@as(u32, 1), @as(u32, @intCast(win.window_count_panes(wl.window))));
    try std.testing.expectEqual(@as(u32, 0), wl.window.flags & T.WINDOW_ZOOMED);
}
