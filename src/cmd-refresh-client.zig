// Copyright (c) 2026 Greg Turner <gmt@be-evil.net>
// ISC licence – see COPYING.
// Ported from tmux/cmd-refresh-client.c
// Original copyright:
//   Copyright (c) 2007 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

const std = @import("std");
const T = @import("types.zig");
const args_mod = @import("arguments.zig");
const cmd_mod = @import("cmd.zig");
const cmdq = @import("cmd-queue.zig");
const server = @import("server.zig");
const server_client_mod = @import("server-client.zig");
const tty_mod = @import("tty.zig");
const window_mod = @import("window.zig");

fn exec(cmd: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {
    const args = cmd_mod.cmd_get_args(cmd);
    const target_client = cmdq.cmdq_get_target_client(item) orelse cmdq.cmdq_get_client(item) orelse {
        cmdq.cmdq_error(item, "no client", .{});
        return .@"error";
    };

    if (args.has('c') or args.has('L') or args.has('R') or args.has('U') or args.has('D'))
        return execPanCommand(args, target_client, item);

    if (unsupportedFlag(args, 'A', item) or
        unsupportedFlag(args, 'B', item) or
        unsupportedFlag(args, 'f', item) or
        unsupportedFlag(args, 'F', item) or
        unsupportedFlag(args, 'l', item) or
        unsupportedFlag(args, 'r', item) or
        false)
    {
        return .@"error";
    }

    if (args.count() != 0) {
        cmdq.cmdq_error(item, "refresh-client adjustment is not supported yet", .{});
        return .@"error";
    }

    if (args.get('C')) |size_str| {
        if ((target_client.flags & T.CLIENT_CONTROL) == 0) {
            cmdq.cmdq_error(item, "not a control client", .{});
            return .@"error";
        }
        const size = parseControlSize(item, size_str) orelse return .@"error";
        tty_mod.tty_resize(&target_client.tty, size.sx, size.sy, target_client.tty.xpixel, target_client.tty.ypixel);
        target_client.flags |= T.CLIENT_SIZECHANGED;
        if (target_client.session) |session|
            server_client_mod.server_client_apply_session_size(target_client, session)
        else
            server_client_mod.server_client_force_redraw(target_client);
        return .normal;
    }

    if (args.has('S')) {
        server.server_status_client(target_client);
    } else {
        server_client_mod.server_client_force_redraw(target_client);
    }

    return .normal;
}

fn execPanCommand(args: *const args_mod.Arguments, target_client: *T.Client, item: *cmdq.CmdqItem) T.CmdRetval {
    const adjust = parseAdjustment(args, item) orelse return .@"error";

    if (args.has('c')) {
        target_client.pan_window = null;
        target_client.pan_ox = 0;
        target_client.pan_oy = 0;
        server_client_mod.server_client_force_redraw(target_client);
        return .normal;
    }

    const session = target_client.session orelse {
        cmdq.cmdq_error(item, "no current session", .{});
        return .@"error";
    };
    const wl = session.curw orelse {
        cmdq.cmdq_error(item, "no current window", .{});
        return .@"error";
    };

    const viewport = server_client_mod.server_client_viewport(target_client) orelse {
        cmdq.cmdq_error(item, "no current window", .{});
        return .@"error";
    };
    const window = wl.window;

    if (target_client.pan_window != window) {
        target_client.pan_window = window;
        target_client.pan_ox = viewport.x;
        target_client.pan_oy = viewport.y;
    }

    if (args.has('L')) {
        target_client.pan_ox = target_client.pan_ox -| adjust;
    } else if (args.has('R')) {
        const max_x = windowVisibleWidth(window) -| viewport.sx;
        target_client.pan_ox = @min(target_client.pan_ox + adjust, max_x);
    } else if (args.has('U')) {
        target_client.pan_oy = target_client.pan_oy -| adjust;
    } else if (args.has('D')) {
        const max_y = windowVisibleHeight(window) -| viewport.sy;
        target_client.pan_oy = @min(target_client.pan_oy + adjust, max_y);
    }

    server_client_mod.server_client_force_redraw(target_client);
    return .normal;
}

fn unsupportedFlag(args: *const args_mod.Arguments, flag: u8, item: *cmdq.CmdqItem) bool {
    if (!args.has(flag)) return false;
    cmdq.cmdq_error(item, "refresh-client -{c} is not supported yet", .{flag});
    return true;
}

fn parseAdjustment(args: *const args_mod.Arguments, item: *cmdq.CmdqItem) ?u32 {
    if (args.count() == 0) return 1;
    const raw = args.value_at(0) orelse return 1;
    const parsed = std.fmt.parseInt(u32, raw, 10) catch |err| {
        const reason = switch (err) {
            error.InvalidCharacter => "invalid",
            error.Overflow => "too large",
        };
        cmdq.cmdq_error(item, "adjustment {s}", .{reason});
        return null;
    };
    if (parsed == 0) {
        cmdq.cmdq_error(item, "adjustment too small", .{});
        return null;
    }
    return parsed;
}

fn windowVisibleWidth(w: *T.Window) u32 {
    var width = w.sx;
    for (w.panes.items) |pane| {
        if (!window_mod.window_pane_visible(pane)) continue;
        const bounds = window_mod.window_pane_draw_bounds(pane);
        width = @max(width, bounds.xoff + bounds.sx);
    }
    return width;
}

fn windowVisibleHeight(w: *T.Window) u32 {
    var height = w.sy;
    for (w.panes.items) |pane| {
        if (!window_mod.window_pane_visible(pane)) continue;
        const bounds = window_mod.window_pane_draw_bounds(pane);
        height = @max(height, bounds.yoff + bounds.sy);
    }
    return height;
}

const ControlSize = struct {
    sx: u32,
    sy: u32,
};

fn parseControlSize(item: *cmdq.CmdqItem, raw: []const u8) ?ControlSize {
    if (raw.len != 0 and raw[0] == '@') {
        cmdq.cmdq_error(item, "refresh-client window-specific control sizes are not supported yet", .{});
        return null;
    }

    const sep = std.mem.indexOfAny(u8, raw, ",x") orelse {
        cmdq.cmdq_error(item, "bad size argument", .{});
        return null;
    };
    const sx = std.fmt.parseInt(u32, raw[0..sep], 10) catch {
        cmdq.cmdq_error(item, "bad size argument", .{});
        return null;
    };
    const sy = std.fmt.parseInt(u32, raw[sep + 1 ..], 10) catch {
        cmdq.cmdq_error(item, "bad size argument", .{});
        return null;
    };
    if (sx < T.WINDOW_MINIMUM or sx > T.WINDOW_MAXIMUM or sy < T.WINDOW_MINIMUM or sy > T.WINDOW_MAXIMUM) {
        cmdq.cmdq_error(item, "size too small or too big", .{});
        return null;
    }
    return .{ .sx = sx, .sy = sy };
}

pub const entry: cmd_mod.CmdEntry = .{
    .name = "refresh-client",
    .alias = "refresh",
    .usage = "[-cDlLRSU] [-A pane:state] [-B name:what:format] [-C XxY] [-f flags] [-r pane:report] [-t target-client] [adjustment]",
    .template = "A:B:cC:Df:r:F:lLRSt:U",
    .lower = 0,
    .upper = 1,
    .flags = T.CMD_AFTERHOOK | T.CMD_CLIENT_TFLAG,
    .exec = exec,
};

test "refresh-client redraws the target client instead of the queue client" {
    var queue_env = T.Environ.init(std.testing.allocator);
    defer queue_env.deinit();
    var target_env = T.Environ.init(std.testing.allocator);
    defer target_env.deinit();

    var queue_client = T.Client{
        .name = "queue",
        .environ = &queue_env,
        .tty = undefined,
        .status = .{ .screen = undefined },
    };
    queue_client.tty.client = &queue_client;
    tty_mod.tty_set_size(&queue_client.tty, 80, 24, 0, 0);

    var target_client = T.Client{
        .name = "target",
        .environ = &target_env,
        .tty = undefined,
        .status = .{ .screen = undefined },
    };
    target_client.tty.client = &target_client;
    tty_mod.tty_set_size(&target_client.tty, 90, 30, 0, 0);

    var cause: ?[]u8 = null;
    const refresh = try cmd_mod.cmd_parse_one(&.{ "refresh-client" }, null, &cause);
    defer cmd_mod.cmd_free(refresh);

    var item = cmdq.CmdqItem{
        .client = &queue_client,
        .target_client = &target_client,
    };
    try std.testing.expectEqual(T.CmdRetval.normal, exec(refresh, &item));
    try std.testing.expect(queue_client.flags & T.CLIENT_REDRAW == 0);
    try std.testing.expect(target_client.flags & T.CLIENT_REDRAW != 0);
}

test "refresh-client -S uses the shared status-only redraw path for the target client" {
    var queue_env = T.Environ.init(std.testing.allocator);
    defer queue_env.deinit();
    var target_env = T.Environ.init(std.testing.allocator);
    defer target_env.deinit();

    var queue_client = T.Client{
        .name = "queue",
        .environ = &queue_env,
        .tty = undefined,
        .status = .{ .screen = undefined },
    };
    queue_client.tty.client = &queue_client;

    var target_client = T.Client{
        .name = "target",
        .environ = &target_env,
        .tty = undefined,
        .status = .{ .screen = undefined },
    };
    target_client.tty.client = &target_client;

    var cause: ?[]u8 = null;
    const refresh = try cmd_mod.cmd_parse_one(&.{ "refresh-client", "-S" }, null, &cause);
    defer cmd_mod.cmd_free(refresh);

    var item = cmdq.CmdqItem{
        .client = &queue_client,
        .target_client = &target_client,
    };
    try std.testing.expectEqual(T.CmdRetval.normal, exec(refresh, &item));
    try std.testing.expect(queue_client.flags & T.CLIENT_REDRAWSTATUS == 0);
    try std.testing.expect(target_client.flags & T.CLIENT_REDRAWSTATUS != 0);
    try std.testing.expect(target_client.flags & T.CLIENT_REDRAWWINDOW == 0);
}

test "refresh-client -C resizes only control clients" {
    var queue_env = T.Environ.init(std.testing.allocator);
    defer queue_env.deinit();
    var target_env = T.Environ.init(std.testing.allocator);
    defer target_env.deinit();

    var queue_client = T.Client{
        .name = "queue",
        .environ = &queue_env,
        .tty = undefined,
        .status = .{ .screen = undefined },
    };
    queue_client.tty.client = &queue_client;

    var target_client = T.Client{
        .name = "control",
        .environ = &target_env,
        .tty = undefined,
        .status = .{ .screen = undefined },
        .flags = T.CLIENT_CONTROL,
    };
    target_client.tty.client = &target_client;
    tty_mod.tty_set_size(&target_client.tty, 80, 24, 0, 0);

    var cause: ?[]u8 = null;
    const resize = try cmd_mod.cmd_parse_one(&.{ "refresh-client", "-C", "120x40" }, null, &cause);
    defer cmd_mod.cmd_free(resize);

    var item = cmdq.CmdqItem{
        .client = &queue_client,
        .target_client = &target_client,
    };
    try std.testing.expectEqual(T.CmdRetval.normal, exec(resize, &item));
    try std.testing.expectEqual(@as(u32, 120), target_client.tty.sx);
    try std.testing.expectEqual(@as(u32, 40), target_client.tty.sy);
    try std.testing.expect(target_client.flags & T.CLIENT_SIZECHANGED != 0);
}

test "refresh-client rejects unsupported panes and non-control size requests" {
    var target_env = T.Environ.init(std.testing.allocator);
    defer target_env.deinit();

    var target_client = T.Client{
        .name = "plain",
        .environ = &target_env,
        .tty = undefined,
        .status = .{ .screen = undefined },
    };
    target_client.tty.client = &target_client;

    var cause: ?[]u8 = null;
    const unsupported = try cmd_mod.cmd_parse_one(&.{ "refresh-client", "-l" }, null, &cause);
    defer cmd_mod.cmd_free(unsupported);
    var unsupported_item = cmdq.CmdqItem{ .target_client = &target_client };
    try std.testing.expectEqual(T.CmdRetval.@"error", exec(unsupported, &unsupported_item));

    const resize = try cmd_mod.cmd_parse_one(&.{ "refresh-client", "-C", "120x40" }, null, &cause);
    defer cmd_mod.cmd_free(resize);
    var resize_item = cmdq.CmdqItem{ .target_client = &target_client };
    try std.testing.expectEqual(T.CmdRetval.@"error", exec(resize, &resize_item));
}

test "refresh-client pan commands update and clear the target client viewport" {
    const env_mod = @import("environ.zig");
    const opts = @import("options.zig");
    const session_mod = @import("session.zig");
    const xm = @import("xmalloc.zig");

    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    session_mod.session_init_globals(xm.allocator);
    window_mod.window_init_globals(xm.allocator);

    const session = session_mod.session_create(null, "refresh-pan", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (session_mod.session_find("refresh-pan") != null) session_mod.session_destroy(session, false, "test");

    const window = window_mod.window_create(6, 2, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    var attach_cause: ?[]u8 = null;
    const wl = session_mod.session_attach(session, window, 0, &attach_cause) orelse unreachable;
    session.curw = wl;

    const left = window_mod.window_add_pane(window, null, 3, 2);
    const right = window_mod.window_add_pane(window, null, 3, 2);
    left.xoff = 0;
    right.xoff = 3;
    window.active = right;

    var queue_env = T.Environ.init(std.testing.allocator);
    defer queue_env.deinit();
    var target_env = T.Environ.init(std.testing.allocator);
    defer target_env.deinit();

    var queue_client = T.Client{
        .name = "queue",
        .environ = &queue_env,
        .tty = undefined,
        .status = .{ .screen = undefined },
    };
    queue_client.tty.client = &queue_client;

    var target_client = T.Client{
        .name = "target",
        .environ = &target_env,
        .tty = undefined,
        .status = .{ .screen = undefined },
        .flags = T.CLIENT_ATTACHED | T.CLIENT_UTF8 | T.CLIENT_STATUSOFF,
        .session = session,
    };
    target_client.tty.client = &target_client;
    tty_mod.tty_set_size(&target_client.tty, 3, 2, 0, 0);

    var cause: ?[]u8 = null;
    const pan_right = try cmd_mod.cmd_parse_one(&.{ "refresh-client", "-R" }, null, &cause);
    defer cmd_mod.cmd_free(pan_right);

    var item = cmdq.CmdqItem{
        .client = &queue_client,
        .target_client = &target_client,
    };
    try std.testing.expectEqual(T.CmdRetval.normal, exec(pan_right, &item));
    try std.testing.expect(target_client.pan_window == window);
    try std.testing.expectEqual(@as(u32, 3), target_client.pan_ox);
    try std.testing.expect(target_client.flags & T.CLIENT_REDRAW != 0);

    target_client.flags = T.CLIENT_ATTACHED | T.CLIENT_UTF8 | T.CLIENT_STATUSOFF;
    const clear_pan = try cmd_mod.cmd_parse_one(&.{ "refresh-client", "-c" }, null, &cause);
    defer cmd_mod.cmd_free(clear_pan);
    try std.testing.expectEqual(T.CmdRetval.normal, exec(clear_pan, &item));
    try std.testing.expect(target_client.pan_window == null);
    try std.testing.expectEqual(@as(u32, 0), target_client.pan_ox);
    try std.testing.expectEqual(@as(u32, 0), target_client.pan_oy);
    try std.testing.expect(target_client.flags & T.CLIENT_REDRAW != 0);
}
