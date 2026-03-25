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
const cmd_mod = @import("cmd.zig");
const cmdq = @import("cmd-queue.zig");
const cmd_find = @import("cmd-find.zig");
const server_fn = @import("server-fn.zig");
const win = @import("window.zig");

fn exec(cmd: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {
    const args = cmd_mod.cmd_get_args(cmd);
    if (args.has('M')) {
        cmdq.cmdq_error(item, "mouse resize not supported yet", .{});
        return .@"error";
    }
    if (args.has('T')) {
        cmdq.cmdq_error(item, "history trim resize not supported yet", .{});
        return .@"error";
    }
    if (args.has('Z')) {
        cmdq.cmdq_error(item, "zoom resize not supported yet", .{});
        return .@"error";
    }

    var target: T.CmdFindState = .{};
    if (cmd_find.cmd_find_target(&target, item, args.get('t'), .pane, 0) != 0)
        return .@"error";
    const wp = target.wp orelse return .@"error";
    const wl = target.wl orelse return .@"error";
    const w = wl.window;

    const adjust = parse_adjustment(args.value_at(0), item) orelse return .@"error";
    var new_sx: ?u32 = null;
    var new_sy: ?u32 = null;

    if (args.get('x')) |width_str| {
        new_sx = parse_dimension(width_str, w.sx, "width", item) orelse return .@"error";
    }
    if (args.get('y')) |height_str| {
        new_sy = parse_dimension(height_str, w.sy, "height", item) orelse return .@"error";
    }

    if (args.has('L')) {
        new_sx = clamp_adjust(wp.sx, -adjust);
    } else if (args.has('R')) {
        new_sx = clamp_adjust(wp.sx, adjust);
    } else if (args.has('U')) {
        new_sy = clamp_adjust(wp.sy, -adjust);
    } else if (args.has('D')) {
        new_sy = clamp_adjust(wp.sy, adjust);
    }

    if (new_sx == null and new_sy == null) {
        cmdq.cmdq_error(item, "resize direction or dimension required", .{});
        return .@"error";
    }

    win.window_pane_resize(wp, new_sx, new_sy);
    server_fn.server_redraw_session(target.s.?);
    server_fn.server_status_window(w);
    return .normal;
}

fn parse_adjustment(raw: ?[]const u8, item: *cmdq.CmdqItem) ?i32 {
    const text = raw orelse return 1;
    const value = std.fmt.parseInt(i32, text, 10) catch {
        cmdq.cmdq_error(item, "adjustment invalid", .{});
        return null;
    };
    if (value < 1) {
        cmdq.cmdq_error(item, "adjustment invalid", .{});
        return null;
    }
    return value;
}

fn parse_dimension(raw: []const u8, limit: u32, label: []const u8, item: *cmdq.CmdqItem) ?u32 {
    const value = std.fmt.parseInt(u32, raw, 10) catch {
        cmdq.cmdq_error(item, "{s} invalid", .{label});
        return null;
    };
    if (value == 0) {
        cmdq.cmdq_error(item, "{s} invalid", .{label});
        return null;
    }
    return @min(value, limit);
}

fn clamp_adjust(current: u32, delta: i32) u32 {
    const signed: i64 = @as(i64, current) + delta;
    if (signed < 1) return 1;
    return @intCast(signed);
}

pub const entry: cmd_mod.CmdEntry = .{
    .name = "resize-pane",
    .alias = "resizep",
    .usage = "[-DLRU] [-x width] [-y height] [-t target-pane] [adjustment]",
    .template = "DLMRTt:Ux:y:Z",
    .lower = 0,
    .upper = 1,
    .flags = T.CMD_AFTERHOOK,
    .exec = exec,
};

test "resize-pane adjusts pane width and height directly" {
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

    const s = sess.session_create(null, "resize-pane-test", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("resize-pane-test") != null) sess.session_destroy(s, false, "test");

    var cause: ?[]u8 = null;
    var ctx: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const wl = spawn.spawn_window(&ctx, &cause).?;
    const wp = wl.window.active.?;

    const target = std.fmt.allocPrint(xm.allocator, "%{d}", .{wp.id}) catch unreachable;
    defer xm.allocator.free(target);

    var parse_cause: ?[]u8 = null;
    const resize_cmd = try cmd_mod.cmd_parse_one(&.{ "resize-pane", "-t", target, "-x", "70", "-y", "10" }, null, &parse_cause);
    defer cmd_mod.cmd_free(resize_cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(resize_cmd, &item));

    try std.testing.expectEqual(@as(u32, 70), wp.sx);
    try std.testing.expectEqual(@as(u32, 10), wp.sy);
}

test "resize-pane directional adjustment works and clamps at one" {
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

    const s = sess.session_create(null, "resize-pane-dir", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("resize-pane-dir") != null) sess.session_destroy(s, false, "test");

    var cause: ?[]u8 = null;
    var ctx: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const wl = spawn.spawn_window(&ctx, &cause).?;
    const wp = wl.window.active.?;
    wp.sx = 5;

    const target = std.fmt.allocPrint(xm.allocator, "%{d}", .{wp.id}) catch unreachable;
    defer xm.allocator.free(target);

    var parse_cause: ?[]u8 = null;
    const left_cmd = try cmd_mod.cmd_parse_one(&.{ "resize-pane", "-t", target, "-L", "10" }, null, &parse_cause);
    defer cmd_mod.cmd_free(left_cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(left_cmd, &item));
    try std.testing.expectEqual(@as(u32, 1), wp.sx);
}

test "resize-pane rejects unsupported zoom resize" {
    var parse_cause: ?[]u8 = null;
    const resize_cmd = try cmd_mod.cmd_parse_one(&.{ "resize-pane", "-Z" }, null, &parse_cause);
    defer cmd_mod.cmd_free(resize_cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.@"error", cmd_mod.cmd_execute(resize_cmd, &item));
}
