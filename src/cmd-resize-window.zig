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
// Ported in part from tmux/cmd-resize-window.c.
// Original copyright:
//   Copyright (c) 2018 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const cmd_mod = @import("cmd.zig");
const cmdq = @import("cmd-queue.zig");
const cmd_find = @import("cmd-find.zig");
const opts = @import("options.zig");
const resize_mod = @import("resize.zig");

fn exec(cmd: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {
    const args = cmd_mod.cmd_get_args(cmd);

    var target: T.CmdFindState = .{};
    if (cmd_find.cmd_find_target(&target, item, args.get('t'), .window, 0) != 0)
        return .@"error";

    const s = target.s orelse return .@"error";
    const wl = target.wl orelse return .@"error";
    const w = wl.window;

    const adjust = parse_adjustment(args.value_at(0), item) orelse return .@"error";

    var sx = w.sx;
    var sy = w.sy;
    var xpixel: u32 = 0;
    var ypixel: u32 = 0;

    if (args.get('x')) |width_text| {
        sx = parse_dimension(width_text, "width", item) orelse return .@"error";
    }
    if (args.get('y')) |height_text| {
        sy = parse_dimension(height_text, "height", item) orelse return .@"error";
    }

    if (args.has('L')) {
        if (sx >= adjust) sx -= adjust;
    } else if (args.has('R')) {
        sx = std.math.add(u32, sx, adjust) catch std.math.maxInt(u32);
    } else if (args.has('U')) {
        if (sy >= adjust) sy -= adjust;
    } else if (args.has('D')) {
        sy = std.math.add(u32, sy, adjust) catch std.math.maxInt(u32);
    }

    if (args.has('A')) {
        resize_mod.default_window_size(null, s, w, &sx, &sy, &xpixel, &ypixel, T.WINDOW_SIZE_LARGEST);
    } else if (args.has('a')) {
        resize_mod.default_window_size(null, s, w, &sx, &sy, &xpixel, &ypixel, T.WINDOW_SIZE_SMALLEST);
    }

    opts.options_set_number(w.options, "window-size", T.WINDOW_SIZE_MANUAL);
    w.manual_sx = sx;
    w.manual_sy = sy;
    resize_mod.recalculate_size(w, true);
    return .normal;
}

fn parse_adjustment(raw: ?[]const u8, item: *cmdq.CmdqItem) ?u32 {
    const text = raw orelse return 1;
    const value = std.fmt.parseInt(i64, text, 10) catch {
        cmdq.cmdq_error(item, "adjustment invalid", .{});
        return null;
    };
    if (value < 1) {
        cmdq.cmdq_error(item, "adjustment too small", .{});
        return null;
    }
    if (value > std.math.maxInt(i32)) {
        cmdq.cmdq_error(item, "adjustment too large", .{});
        return null;
    }
    return @intCast(value);
}

fn parse_dimension(raw: []const u8, label: []const u8, item: *cmdq.CmdqItem) ?u32 {
    const value = std.fmt.parseInt(i64, raw, 10) catch {
        cmdq.cmdq_error(item, "{s} invalid", .{label});
        return null;
    };
    if (value < T.WINDOW_MINIMUM) {
        cmdq.cmdq_error(item, "{s} too small", .{label});
        return null;
    }
    if (value > T.WINDOW_MAXIMUM) {
        cmdq.cmdq_error(item, "{s} too large", .{label});
        return null;
    }
    return @intCast(value);
}

pub const entry: cmd_mod.CmdEntry = .{
    .name = "resize-window",
    .alias = "resizew",
    .usage = "[-aADLRU] [-x width] [-y height] [-t target-window] [adjustment]",
    .template = "aADLRt:Ux:y:",
    .lower = 0,
    .upper = 1,
    .flags = T.CMD_AFTERHOOK,
    .exec = exec,
};

fn init_test_globals() void {
    const env_mod = @import("environ.zig");
    const sess = @import("session.zig");
    const win = @import("window.zig");
    const client_registry = @import("client-registry.zig");

    client_registry.clients.clearRetainingCapacity();
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

fn deinit_test_globals() void {
    const env_mod = @import("environ.zig");
    const client_registry = @import("client-registry.zig");

    client_registry.clients.clearRetainingCapacity();
    env_mod.environ_free(env_mod.global_environ);
    opts.options_free(opts.global_options);
    opts.options_free(opts.global_s_options);
    opts.options_free(opts.global_w_options);
}

test "resize-window sets explicit manual dimensions" {
    const env_mod = @import("environ.zig");
    const sess = @import("session.zig");
    const spawn = @import("spawn.zig");

    init_test_globals();
    defer deinit_test_globals();

    const s = sess.session_create(null, "resize-window-explicit", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("resize-window-explicit") != null) sess.session_destroy(s, false, "test");

    var cause: ?[]u8 = null;
    var ctx: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const wl = spawn.spawn_window(&ctx, &cause).?;
    s.curw = wl;
    const w = wl.window;
    const wp = w.active.?;

    var parse_cause: ?[]u8 = null;
    const resize_cmd = try cmd_mod.cmd_parse_one(&.{ "resize-window", "-t", "resize-window-explicit:0", "-x", "70", "-y", "10" }, null, &parse_cause);
    defer cmd_mod.cmd_free(resize_cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(resize_cmd, &item));

    try std.testing.expectEqual(@as(u32, 70), w.sx);
    try std.testing.expectEqual(@as(u32, 10), w.sy);
    try std.testing.expectEqual(@as(u32, 70), w.manual_sx);
    try std.testing.expectEqual(@as(u32, 10), w.manual_sy);
    try std.testing.expectEqual(@as(i64, T.WINDOW_SIZE_MANUAL), opts.options_get_number(w.options, "window-size"));
    try std.testing.expectEqual(@as(u32, 70), wp.sx);
    try std.testing.expectEqual(@as(u32, 10), wp.sy);
}

test "resize-window directional adjustment uses default and explicit steps" {
    const env_mod = @import("environ.zig");
    const sess = @import("session.zig");
    const spawn = @import("spawn.zig");

    init_test_globals();
    defer deinit_test_globals();

    const s = sess.session_create(null, "resize-window-direction", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("resize-window-direction") != null) sess.session_destroy(s, false, "test");

    var cause: ?[]u8 = null;
    var ctx: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const wl = spawn.spawn_window(&ctx, &cause).?;
    s.curw = wl;
    const w = wl.window;

    var parse_cause: ?[]u8 = null;
    const grow_cmd = try cmd_mod.cmd_parse_one(&.{ "resize-window", "-t", "resize-window-direction:0", "-R" }, null, &parse_cause);
    defer cmd_mod.cmd_free(grow_cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(grow_cmd, &item));
    try std.testing.expectEqual(@as(u32, 81), w.sx);

    const shrink_cmd = try cmd_mod.cmd_parse_one(&.{ "resize-window", "-t", "resize-window-direction:0", "-U", "1000" }, null, &parse_cause);
    defer cmd_mod.cmd_free(shrink_cmd);
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(shrink_cmd, &item));
    try std.testing.expectEqual(@as(u32, 24), w.sy);
}

test "resize-window picks smallest and largest attached client sizes" {
    const env_mod = @import("environ.zig");
    const sess = @import("session.zig");
    const spawn = @import("spawn.zig");
    const client_registry = @import("client-registry.zig");

    init_test_globals();
    defer deinit_test_globals();

    const s = sess.session_create(null, "resize-window-clients", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("resize-window-clients") != null) sess.session_destroy(s, false, "test");

    var cause: ?[]u8 = null;
    var ctx: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const wl = spawn.spawn_window(&ctx, &cause).?;
    s.curw = wl;
    const w = wl.window;
    const wp = w.active.?;

    var big: T.Client = .{
        .name = "big",
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{ .screen = undefined },
    };
    defer env_mod.environ_free(big.environ);
    big.tty = .{ .client = &big, .sx = 120, .sy = 40, .xpixel = 17, .ypixel = 34 };
    big.session = s;

    var small: T.Client = .{
        .name = "small",
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{ .screen = undefined },
    };
    defer env_mod.environ_free(small.environ);
    small.tty = .{ .client = &small, .sx = 90, .sy = 30, .xpixel = 18, .ypixel = 36 };
    small.session = s;

    try client_registry.clients.append(xm.allocator, &big);
    try client_registry.clients.append(xm.allocator, &small);

    var parse_cause: ?[]u8 = null;
    const smallest_cmd = try cmd_mod.cmd_parse_one(&.{ "resize-window", "-t", "resize-window-clients:0", "-a" }, null, &parse_cause);
    defer cmd_mod.cmd_free(smallest_cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(smallest_cmd, &item));
    try std.testing.expectEqual(@as(u32, 90), w.sx);
    try std.testing.expectEqual(@as(u32, 29), w.sy);
    try std.testing.expectEqual(@as(u32, 90), wp.sx);
    try std.testing.expectEqual(@as(u32, 29), wp.sy);

    const largest_cmd = try cmd_mod.cmd_parse_one(&.{ "resize-window", "-t", "resize-window-clients:0", "-A" }, null, &parse_cause);
    defer cmd_mod.cmd_free(largest_cmd);
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(largest_cmd, &item));
    try std.testing.expectEqual(@as(u32, 120), w.sx);
    try std.testing.expectEqual(@as(u32, 39), w.sy);
    try std.testing.expectEqual(@as(u32, 120), w.manual_sx);
    try std.testing.expectEqual(@as(u32, 39), w.manual_sy);
}
