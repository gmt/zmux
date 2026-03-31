// Copyright (c) 2026 Greg Turner <gmt@be-evil.net>
// ISC licence – see COPYING.
// Ported from tmux/cmd-refresh-client.c
// Original copyright:
//   Copyright (c) 2007 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

const std = @import("std");
const T = @import("types.zig");
const args_mod = @import("arguments.zig");
const colour_mod = @import("colour.zig");
const cmd_mod = @import("cmd.zig");
const cmdq = @import("cmd-queue.zig");
const control = @import("control.zig");
const control_subscriptions = @import("control-subscriptions.zig");
const resize_mod = @import("resize.zig");
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

    if (args.has('l')) {
        tty_mod.tty_clipboard_query(&target_client.tty);
        return .normal;
    }

    if (args.get('F')) |flags_text|
        server_client_mod.server_client_set_flags(target_client, flags_text);
    if (args.get('f')) |flags_text|
        server_client_mod.server_client_set_flags(target_client, flags_text);

    if (args.get('r')) |report|
        updatePaneReportColours(report);

    if (args.has('A')) {
        if ((target_client.flags & T.CLIENT_CONTROL) == 0) {
            cmdq.cmdq_error(item, "not a control client", .{});
            return .@"error";
        }
        if (args.entry('A')) |flag_entry| {
            for (flag_entry.values.items) |value|
                updateControlPaneOffset(target_client, value);
        }
        return .normal;
    }

    if (args.has('B')) {
        if ((target_client.flags & T.CLIENT_CONTROL) == 0) {
            cmdq.cmdq_error(item, "not a control client", .{});
            return .@"error";
        }
        if (args.entry('B')) |flag_entry| {
            for (flag_entry.values.items) |value|
                updateControlSubscription(target_client, value);
        }
        return .normal;
    }

    if (args.get('C')) |size_str| {
        if ((target_client.flags & T.CLIENT_CONTROL) == 0) {
            cmdq.cmdq_error(item, "not a control client", .{});
            return .@"error";
        }
        const size = parseControlSize(item, size_str) orelse return .@"error";
        switch (size) {
            .global => |global_size| {
                tty_mod.tty_resize(&target_client.tty, global_size.sx, global_size.sy, target_client.tty.xpixel, target_client.tty.ypixel);
                target_client.flags |= T.CLIENT_SIZECHANGED;
                if (target_client.session) |session|
                    server_client_mod.server_client_apply_session_size(target_client, session)
                else
                    server_client_mod.server_client_force_redraw(target_client);
            },
            .window => |window_size| {
                if (window_size.size) |dims| {
                    const cw = server_client_mod.server_client_add_client_window(target_client, window_size.window);
                    cw.sx = dims.sx;
                    cw.sy = dims.sy;
                    target_client.flags |= T.CLIENT_WINDOWSIZECHANGED;
                    resize_mod.recalculate_sizes_now(true);
                } else if (server_client_mod.server_client_get_client_window(target_client, window_size.window)) |cw| {
                    cw.sx = 0;
                    cw.sy = 0;
                    resize_mod.recalculate_sizes_now(true);
                }
            },
        }
        return .normal;
    }

    if (args.has('S')) {
        server.server_status_client(target_client);
    } else {
        server_client_mod.server_client_force_redraw(target_client);
    }

    return .normal;
}

fn updateControlSubscription(target_client: *T.Client, value: []const u8) void {
    const first_colon = std.mem.indexOfScalar(u8, value, ':') orelse {
        control_subscriptions.control_remove_sub(target_client, value);
        return;
    };

    const name = value[0..first_colon];
    const remainder = value[first_colon + 1 ..];
    const second_colon = std.mem.indexOfScalar(u8, remainder, ':') orelse return;
    const what = remainder[0..second_colon];
    const format = remainder[second_colon + 1 ..];

    var sub_type: T.ControlSubType = .session;
    var sub_id: u32 = 0;

    if (std.mem.eql(u8, what, "%*")) {
        sub_type = .all_panes;
    } else if (parseSubscriptionTargetId(what, '%')) |id| {
        sub_type = .pane;
        sub_id = id;
    } else if (std.mem.eql(u8, what, "@*")) {
        sub_type = .all_windows;
    } else if (parseSubscriptionTargetId(what, '@')) |id| {
        sub_type = .window;
        sub_id = id;
    }

    control_subscriptions.control_add_sub(target_client, name, sub_type, sub_id, format);
}

fn parseSubscriptionTargetId(value: []const u8, prefix: u8) ?u32 {
    if (value.len < 2 or value[0] != prefix) return null;
    return std.fmt.parseInt(u32, value[1..], 10) catch null;
}

fn updateControlPaneOffset(target_client: *T.Client, value: []const u8) void {
    if (value.len < 3 or value[0] != '%') return;

    const split = std.mem.indexOfScalar(u8, value, ':') orelse return;
    if (split <= 1 or split + 1 > value.len) return;

    const pane_id = std.fmt.parseInt(u32, value[1..split], 10) catch return;
    const wp = window_mod.window_pane_find_by_id(pane_id) orelse return;
    const state = value[split + 1 ..];

    if (std.mem.eql(u8, state, "on")) {
        control.control_set_pane_on(target_client, wp);
    } else if (std.mem.eql(u8, state, "off")) {
        control.control_set_pane_off(target_client, wp);
    } else if (std.mem.eql(u8, state, "continue")) {
        control.control_continue_pane(target_client, wp);
    } else if (std.mem.eql(u8, state, "pause")) {
        control.control_pause_pane(target_client, wp);
    }
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

const ReportColourSlot = enum {
    fg,
    bg,
};

const ReportColour = struct {
    slot: ReportColourSlot,
    colour: i32,
};

fn updatePaneReportColours(value: []const u8) void {
    if (value.len < 3 or value[0] != '%') return;

    const split = std.mem.indexOfScalar(u8, value, ':') orelse return;
    if (split <= 1 or split + 1 > value.len) return;

    const pane_id = std.fmt.parseInt(u32, value[1..split], 10) catch return;
    const wp = window_mod.window_pane_find_by_id(pane_id) orelse return;
    const report = parseOscReportColour(value[split + 1 ..]) orelse return;

    switch (report.slot) {
        .fg => wp.control_fg = report.colour,
        .bg => wp.control_bg = report.colour,
    }
}

fn parseOscReportColour(report: []const u8) ?ReportColour {
    if (report.len < 5) return null;
    if (report[0] != '\x1b' or report[1] != ']' or report[2] != '1') return null;

    const slot: ReportColourSlot = switch (report[3]) {
        '0' => .fg,
        '1' => .bg,
        else => return null,
    };
    if (report[4] != ';') return null;

    const payload_end = findOscPayloadEnd(report[5..]) orelse return null;
    const payload = report[5 .. 5 + payload_end];
    if (payload.len == 0) return null;

    const parsed = colour_mod.colour_parseX11(payload);
    if (parsed == -1) return null;
    return .{ .slot = slot, .colour = parsed };
}

fn findOscPayloadEnd(report: []const u8) ?usize {
    for (report, 0..) |ch, idx| {
        if (ch == '\x07') return idx;
        if (ch == '\\' and idx > 0 and report[idx - 1] == '\x1b') return idx - 1;
    }
    return null;
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

const GlobalControlSize = struct {
    sx: u32,
    sy: u32,
};

const WindowControlSize = struct {
    window: u32,
    size: ?GlobalControlSize,
};

const ControlSize = union(enum) {
    global: GlobalControlSize,
    window: WindowControlSize,
};

const ParseControlDimensionsError = error{
    Invalid,
    OutOfRange,
};

fn parseControlSize(item: *cmdq.CmdqItem, raw: []const u8) ?ControlSize {
    if (raw.len != 0 and raw[0] == '@')
        return parseWindowControlSize(item, raw);

    const size = parseGlobalControlSize(item, raw, ",x") orelse return null;
    return .{ .global = size };
}

fn parseWindowControlSize(item: *cmdq.CmdqItem, raw: []const u8) ?ControlSize {
    const colon = std.mem.indexOfScalar(u8, raw, ':') orelse {
        cmdq.cmdq_error(item, "bad size argument", .{});
        return null;
    };
    if (colon <= 1) {
        cmdq.cmdq_error(item, "bad size argument", .{});
        return null;
    }

    const window_id = std.fmt.parseInt(u32, raw[1..colon], 10) catch {
        cmdq.cmdq_error(item, "bad size argument", .{});
        return null;
    };
    const value = raw[colon + 1 ..];
    if (value.len == 0)
        return .{ .window = .{ .window = window_id, .size = null } };

    const size = parseControlDimensions(value, "x") catch |err| switch (err) {
        error.Invalid => return .{ .window = .{ .window = window_id, .size = null } },
        error.OutOfRange => {
            cmdq.cmdq_error(item, "size too small or too big", .{});
            return null;
        },
    };

    return .{ .window = .{ .window = window_id, .size = size } };
}

fn parseGlobalControlSize(item: *cmdq.CmdqItem, raw: []const u8, separators: []const u8) ?GlobalControlSize {
    return parseControlDimensions(raw, separators) catch |err| {
        switch (err) {
            error.Invalid => cmdq.cmdq_error(item, "bad size argument", .{}),
            error.OutOfRange => cmdq.cmdq_error(item, "size too small or too big", .{}),
        }
        return null;
    };
}

fn parseControlDimensions(raw: []const u8, separators: []const u8) ParseControlDimensionsError!GlobalControlSize {
    const sep = std.mem.indexOfAny(u8, raw, separators) orelse return error.Invalid;
    const sx = std.fmt.parseInt(u32, raw[0..sep], 10) catch return error.Invalid;
    const sy = std.fmt.parseInt(u32, raw[sep + 1 ..], 10) catch return error.Invalid;
    if (sx < T.WINDOW_MINIMUM or sx > T.WINDOW_MAXIMUM or sy < T.WINDOW_MINIMUM or sy > T.WINDOW_MAXIMUM)
        return error.OutOfRange;
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
        .status = .{},
    };
    queue_client.tty.client = &queue_client;
    tty_mod.tty_set_size(&queue_client.tty, 80, 24, 0, 0);

    var target_client = T.Client{
        .name = "target",
        .environ = &target_env,
        .tty = undefined,
        .status = .{},
    };
    target_client.tty.client = &target_client;
    tty_mod.tty_set_size(&target_client.tty, 90, 30, 0, 0);

    var cause: ?[]u8 = null;
    const refresh = try cmd_mod.cmd_parse_one(&.{"refresh-client"}, null, &cause);
    defer cmd_mod.cmd_free(refresh);

    var item = cmdq.CmdqItem{
        .client = &queue_client,
        .target_client = &target_client,
    };
    try std.testing.expectEqual(T.CmdRetval.normal, exec(refresh, &item));
    try std.testing.expect(queue_client.flags & T.CLIENT_REDRAW == 0);
    try std.testing.expect(target_client.flags & T.CLIENT_REDRAW != 0);
}

test "refresh-client ignores a stray adjustment unless pan mode is active" {
    var queue_env = T.Environ.init(std.testing.allocator);
    defer queue_env.deinit();
    var target_env = T.Environ.init(std.testing.allocator);
    defer target_env.deinit();

    var queue_client = T.Client{
        .name = "queue",
        .environ = &queue_env,
        .tty = undefined,
        .status = .{},
    };
    queue_client.tty.client = &queue_client;

    var target_client = T.Client{
        .name = "target",
        .environ = &target_env,
        .tty = undefined,
        .status = .{},
    };
    target_client.tty.client = &target_client;

    var cause: ?[]u8 = null;
    const refresh = try cmd_mod.cmd_parse_one(&.{ "refresh-client", "bogus" }, null, &cause);
    defer cmd_mod.cmd_free(refresh);

    var item = cmdq.CmdqItem{
        .client = &queue_client,
        .target_client = &target_client,
    };
    try std.testing.expectEqual(T.CmdRetval.normal, exec(refresh, &item));
    try std.testing.expect(queue_client.flags & T.CLIENT_REDRAW == 0);
    try std.testing.expect(target_client.flags & T.CLIENT_REDRAW != 0);
    try std.testing.expectEqual(@as(i32, 0), queue_client.retval);
}

test "refresh-client -S uses the shared status-only redraw seam for the target client" {
    var queue_env = T.Environ.init(std.testing.allocator);
    defer queue_env.deinit();
    var target_env = T.Environ.init(std.testing.allocator);
    defer target_env.deinit();

    var queue_client = T.Client{
        .name = "queue",
        .environ = &queue_env,
        .tty = undefined,
        .status = .{},
    };
    queue_client.tty.client = &queue_client;

    var target_client = T.Client{
        .name = "target",
        .environ = &target_env,
        .tty = undefined,
        .status = .{},
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

test "refresh-client -f and -F route client flags to the target client" {
    var queue_env = T.Environ.init(std.testing.allocator);
    defer queue_env.deinit();
    var target_env = T.Environ.init(std.testing.allocator);
    defer target_env.deinit();

    var queue_client = T.Client{
        .name = "queue",
        .environ = &queue_env,
        .tty = undefined,
        .status = .{},
    };
    queue_client.tty.client = &queue_client;

    var target_client = T.Client{
        .name = "target",
        .environ = &target_env,
        .tty = undefined,
        .status = .{},
    };
    target_client.tty.client = &target_client;

    var cause: ?[]u8 = null;
    const refresh = try cmd_mod.cmd_parse_one(&.{ "refresh-client", "-F", "read-only", "-f", "ignore-size" }, null, &cause);
    defer cmd_mod.cmd_free(refresh);

    var item = cmdq.CmdqItem{
        .client = &queue_client,
        .target_client = &target_client,
    };
    try std.testing.expectEqual(T.CmdRetval.normal, exec(refresh, &item));
    try std.testing.expect(queue_client.flags & (T.CLIENT_READONLY | T.CLIENT_IGNORESIZE) == 0);
    try std.testing.expect(target_client.flags & T.CLIENT_READONLY != 0);
    try std.testing.expect(target_client.flags & T.CLIENT_IGNORESIZE != 0);
}

test "refresh-client applies -F before -f when both are present" {
    var target_env = T.Environ.init(std.testing.allocator);
    defer target_env.deinit();

    var target_client = T.Client{
        .name = "target",
        .environ = &target_env,
        .tty = undefined,
        .status = .{},
    };
    target_client.tty.client = &target_client;

    var cause: ?[]u8 = null;
    const refresh = try cmd_mod.cmd_parse_one(
        &.{ "refresh-client", "-F", "ignore-size", "-f", "!ignore-size,active-pane" },
        null,
        &cause,
    );
    defer cmd_mod.cmd_free(refresh);

    var item = cmdq.CmdqItem{ .target_client = &target_client };
    try std.testing.expectEqual(T.CmdRetval.normal, exec(refresh, &item));
    try std.testing.expect(target_client.flags & T.CLIENT_ACTIVEPANE != 0);
    try std.testing.expect(target_client.flags & T.CLIENT_IGNORESIZE == 0);
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
        .status = .{},
    };
    queue_client.tty.client = &queue_client;

    var target_client = T.Client{
        .name = "control",
        .environ = &target_env,
        .tty = undefined,
        .status = .{},
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

test "refresh-client -C stores and clears per-window control sizes" {
    const sess = @import("session.zig");
    const win = @import("window.zig");
    const xm = @import("xmalloc.zig");

    sess.session_init_globals(xm.allocator);
    win.window_init_globals(xm.allocator);

    var queue_env = T.Environ.init(std.testing.allocator);
    defer queue_env.deinit();
    var target_env = T.Environ.init(std.testing.allocator);
    defer target_env.deinit();

    var queue_client = T.Client{
        .name = "queue",
        .environ = &queue_env,
        .tty = undefined,
        .status = .{},
    };
    queue_client.tty.client = &queue_client;

    var target_client = T.Client{
        .name = "control",
        .environ = &target_env,
        .tty = undefined,
        .status = .{},
        .flags = T.CLIENT_CONTROL,
    };
    defer target_client.client_windows.deinit(xm.allocator);
    target_client.tty.client = &target_client;
    tty_mod.tty_set_size(&target_client.tty, 80, 24, 0, 0);

    var cause: ?[]u8 = null;
    const set_size = try cmd_mod.cmd_parse_one(&.{ "refresh-client", "-C", "@7:120x40" }, null, &cause);
    defer cmd_mod.cmd_free(set_size);

    var item = cmdq.CmdqItem{
        .client = &queue_client,
        .target_client = &target_client,
    };
    try std.testing.expectEqual(T.CmdRetval.normal, exec(set_size, &item));
    try std.testing.expectEqual(@as(u32, 80), target_client.tty.sx);
    try std.testing.expectEqual(@as(u32, 24), target_client.tty.sy);
    try std.testing.expect(target_client.flags & T.CLIENT_WINDOWSIZECHANGED != 0);

    const cw = server_client_mod.server_client_get_client_window(&target_client, 7) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 120), cw.sx);
    try std.testing.expectEqual(@as(u32, 40), cw.sy);

    const clear_size = try cmd_mod.cmd_parse_one(&.{ "refresh-client", "-C", "@7:" }, null, &cause);
    defer cmd_mod.cmd_free(clear_size);

    try std.testing.expectEqual(T.CmdRetval.normal, exec(clear_size, &item));
    try std.testing.expectEqual(@as(u32, 0), cw.sx);
    try std.testing.expectEqual(@as(u32, 0), cw.sy);
}

test "refresh-client -l emits a clipboard query for the target tty" {
    const c = @import("c.zig");
    const proc_mod = @import("proc.zig");
    const protocol = @import("zmux-protocol.zig");
    const xm = @import("xmalloc.zig");

    var pair: [2]i32 = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &pair));

    var proc = T.ZmuxProc{ .name = "refresh-client-clipboard-query-test" };
    defer proc.peers.deinit(xm.allocator);

    var target_env = T.Environ.init(std.testing.allocator);
    defer target_env.deinit();

    var caps = [_][]u8{
        @constCast("Ms=\x1b]52;%p1%s;%p2%s\x07"),
    };
    var target_client = T.Client{
        .name = "plain",
        .environ = &target_env,
        .tty = undefined,
        .status = .{},
        .term_caps = caps[0..],
    };
    tty_mod.tty_init(&target_client.tty, &target_client);
    tty_mod.tty_start_tty(&target_client.tty);
    target_client.peer = proc_mod.proc_add_peer(&proc, pair[0], test_peer_dispatch, null);
    defer {
        const peer = target_client.peer.?;
        c.imsg.imsgbuf_clear(&peer.ibuf);
        std.posix.close(peer.ibuf.fd);
        xm.allocator.destroy(peer);
        proc.peers.clearRetainingCapacity();
    }

    var reader: c.imsg.imsgbuf = undefined;
    try std.testing.expectEqual(@as(i32, 0), c.imsg.imsgbuf_init(&reader, pair[1]));
    defer {
        c.imsg.imsgbuf_clear(&reader);
        std.posix.close(pair[1]);
    }

    var cause: ?[]u8 = null;
    const query = try cmd_mod.cmd_parse_one(&.{ "refresh-client", "-l" }, null, &cause);
    defer cmd_mod.cmd_free(query);

    var item = cmdq.CmdqItem{ .target_client = &target_client };
    try std.testing.expectEqual(T.CmdRetval.normal, exec(query, &item));

    try std.testing.expectEqual(@as(i32, 1), c.imsg.imsgbuf_read(&reader));

    var imsg_msg: c.imsg.imsg = undefined;
    try std.testing.expect(c.imsg.imsg_get(&reader, &imsg_msg) > 0);
    defer c.imsg.imsg_free(&imsg_msg);

    try std.testing.expectEqual(@as(u32, @intCast(@intFromEnum(protocol.MsgType.write))), c.imsg.imsg_get_type(&imsg_msg));

    const payload_len = c.imsg.imsg_get_len(&imsg_msg);
    var payload = try xm.allocator.alloc(u8, payload_len);
    defer xm.allocator.free(payload);
    try std.testing.expectEqual(@as(i32, 0), c.imsg.imsg_get_data(&imsg_msg, payload.ptr, payload.len));

    var stream: i32 = 0;
    @memcpy(std.mem.asBytes(&stream), payload[0..@sizeOf(i32)]);
    try std.testing.expectEqual(@as(i32, 1), stream);
    try std.testing.expectEqualStrings("\x1b]52;;?\x07", payload[@sizeOf(i32)..]);
}

test "refresh-client rejects control-only flags on non-control clients" {
    var target_env = T.Environ.init(std.testing.allocator);
    defer target_env.deinit();

    var target_client = T.Client{
        .name = "plain",
        .environ = &target_env,
        .tty = undefined,
        .status = .{},
    };
    target_client.tty.client = &target_client;

    var cause: ?[]u8 = null;
    const resize = try cmd_mod.cmd_parse_one(&.{ "refresh-client", "-C", "120x40" }, null, &cause);
    defer cmd_mod.cmd_free(resize);
    var resize_item = cmdq.CmdqItem{ .target_client = &target_client };
    try std.testing.expectEqual(T.CmdRetval.@"error", exec(resize, &resize_item));

    const subscription = try cmd_mod.cmd_parse_one(&.{ "refresh-client", "-B", "watch::#{session_name}" }, null, &cause);
    defer cmd_mod.cmd_free(subscription);
    var subscription_item = cmdq.CmdqItem{ .target_client = &target_client };
    try std.testing.expectEqual(T.CmdRetval.@"error", exec(subscription, &subscription_item));

    const offset = try cmd_mod.cmd_parse_one(&.{ "refresh-client", "-A", "%1:pause" }, null, &cause);
    defer cmd_mod.cmd_free(offset);
    var offset_item = cmdq.CmdqItem{ .target_client = &target_client };
    try std.testing.expectEqual(T.CmdRetval.@"error", exec(offset, &offset_item));
}

test "refresh-client -A tracks control pane state and emits pause transitions" {
    const c = @import("c.zig");
    const env_mod = @import("environ.zig");
    const opts = @import("options.zig");
    const proc_mod = @import("proc.zig");
    const protocol = @import("zmux-protocol.zig");
    const session_mod = @import("session.zig");
    const xm = @import("xmalloc.zig");

    const helpers = struct {
        fn expectControlLine(reader: *c.imsg.imsgbuf, expected: []const u8) !void {
            try std.testing.expectEqual(@as(i32, 1), c.imsg.imsgbuf_read(reader));

            var imsg_msg: c.imsg.imsg = undefined;
            try std.testing.expect(c.imsg.imsg_get(reader, &imsg_msg) > 0);
            defer c.imsg.imsg_free(&imsg_msg);

            try std.testing.expectEqual(@as(u32, @intCast(@intFromEnum(protocol.MsgType.write))), c.imsg.imsg_get_type(&imsg_msg));

            const payload_len = c.imsg.imsg_get_len(&imsg_msg);
            var payload = try xm.allocator.alloc(u8, payload_len);
            defer xm.allocator.free(payload);
            try std.testing.expectEqual(@as(i32, 0), c.imsg.imsg_get_data(&imsg_msg, payload.ptr, payload.len));

            var stream: i32 = 0;
            @memcpy(std.mem.asBytes(&stream), payload[0..@sizeOf(i32)]);
            try std.testing.expectEqual(@as(i32, 1), stream);
            try std.testing.expectEqualStrings(expected, payload[@sizeOf(i32)..]);
        }
    };

    session_mod.session_init_globals(xm.allocator);
    window_mod.window_init_globals(xm.allocator);

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

    const session = session_mod.session_create(null, "refresh-offsets", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (session_mod.session_find("refresh-offsets") != null) session_mod.session_destroy(session, false, "test");

    const window = window_mod.window_create(80, 24, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    const pane = window_mod.window_add_pane(window, null, 80, 24);
    window.active = pane;

    var attach_cause: ?[]u8 = null;
    const wl = session_mod.session_attach(session, window, -1, &attach_cause).?;
    session.curw = wl;

    var pair: [2]i32 = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &pair));

    var proc = T.ZmuxProc{ .name = "refresh-client-offset-test" };
    defer proc.peers.deinit(xm.allocator);

    var target_client = T.Client{
        .name = "control",
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{},
        .session = session,
        .flags = T.CLIENT_CONTROL | T.CLIENT_UTF8,
    };
    defer env_mod.environ_free(target_client.environ);
    defer control.control_panes_deinit(&target_client);
    target_client.tty = .{ .client = &target_client };
    target_client.peer = proc_mod.proc_add_peer(&proc, pair[0], test_peer_dispatch, null);
    defer {
        const peer = target_client.peer.?;
        c.imsg.imsgbuf_clear(&peer.ibuf);
        std.posix.close(peer.ibuf.fd);
        xm.allocator.destroy(peer);
        proc.peers.clearRetainingCapacity();
    }

    var reader: c.imsg.imsgbuf = undefined;
    try std.testing.expectEqual(@as(i32, 0), c.imsg.imsgbuf_init(&reader, pair[1]));
    defer {
        c.imsg.imsgbuf_clear(&reader);
        std.posix.close(pair[1]);
    }

    pane.offset.used = 17;
    var off_buf: [64]u8 = undefined;
    const off_arg = try std.fmt.bufPrint(&off_buf, "%{d}:off", .{pane.id});
    var cause: ?[]u8 = null;
    const off_cmd = try cmd_mod.cmd_parse_one(&.{ "refresh-client", "-A", off_arg }, null, &cause);
    defer cmd_mod.cmd_free(off_cmd);

    var item = cmdq.CmdqItem{ .target_client = &target_client };
    try std.testing.expectEqual(T.CmdRetval.normal, exec(off_cmd, &item));
    try std.testing.expectEqual(@as(usize, 1), target_client.control_panes.items.len);
    try std.testing.expectEqual(@as(u8, T.CONTROL_PANE_OFF), target_client.control_panes.items[0].flags);
    try std.testing.expectEqual(@as(usize, 17), target_client.control_panes.items[0].offset.used);
    try std.testing.expectEqual(@as(usize, 17), target_client.control_panes.items[0].queued.used);

    pane.offset.used = 29;
    var on_buf: [64]u8 = undefined;
    const on_arg = try std.fmt.bufPrint(&on_buf, "%{d}:on", .{pane.id});
    const on_cmd = try cmd_mod.cmd_parse_one(&.{ "refresh-client", "-A", on_arg }, null, &cause);
    defer cmd_mod.cmd_free(on_cmd);

    try std.testing.expectEqual(T.CmdRetval.normal, exec(on_cmd, &item));
    try std.testing.expectEqual(@as(u8, 0), target_client.control_panes.items[0].flags);
    try std.testing.expectEqual(@as(usize, 29), target_client.control_panes.items[0].offset.used);
    try std.testing.expectEqual(@as(usize, 29), target_client.control_panes.items[0].queued.used);

    var missing_buf: [64]u8 = undefined;
    const missing_arg = try std.fmt.bufPrint(&missing_buf, "%{d}:pause", .{pane.id + 999});
    const missing_cmd = try cmd_mod.cmd_parse_one(&.{ "refresh-client", "-A", missing_arg }, null, &cause);
    defer cmd_mod.cmd_free(missing_cmd);
    try std.testing.expectEqual(T.CmdRetval.normal, exec(missing_cmd, &item));
    try std.testing.expectEqual(@as(usize, 1), target_client.control_panes.items.len);

    pane.offset.used = 41;
    var pause_buf: [64]u8 = undefined;
    const pause_arg = try std.fmt.bufPrint(&pause_buf, "%{d}:pause", .{pane.id});
    const pause_cmd = try cmd_mod.cmd_parse_one(&.{ "refresh-client", "-A", pause_arg }, null, &cause);
    defer cmd_mod.cmd_free(pause_cmd);

    try std.testing.expectEqual(T.CmdRetval.normal, exec(pause_cmd, &item));
    try std.testing.expectEqual(@as(u8, T.CONTROL_PANE_PAUSED), target_client.control_panes.items[0].flags);
    var expected_pause: [64]u8 = undefined;
    const expected_pause_line = try std.fmt.bufPrint(&expected_pause, "%pause %{d}\n", .{pane.id});
    try helpers.expectControlLine(&reader, expected_pause_line);

    pane.offset.used = 55;
    var continue_buf: [64]u8 = undefined;
    const continue_arg = try std.fmt.bufPrint(&continue_buf, "%{d}:continue", .{pane.id});
    const continue_cmd = try cmd_mod.cmd_parse_one(&.{ "refresh-client", "-A", continue_arg }, null, &cause);
    defer cmd_mod.cmd_free(continue_cmd);

    try std.testing.expectEqual(T.CmdRetval.normal, exec(continue_cmd, &item));
    try std.testing.expectEqual(@as(u8, 0), target_client.control_panes.items[0].flags);
    try std.testing.expectEqual(@as(usize, 55), target_client.control_panes.items[0].offset.used);
    try std.testing.expectEqual(@as(usize, 55), target_client.control_panes.items[0].queued.used);
    var expected_continue: [64]u8 = undefined;
    const expected_continue_line = try std.fmt.bufPrint(&expected_continue, "%continue %{d}\n", .{pane.id});
    try helpers.expectControlLine(&reader, expected_continue_line);
}

test "refresh-client -B stores and removes control subscriptions" {
    var target_env = T.Environ.init(std.testing.allocator);
    defer target_env.deinit();

    var target_client = T.Client{
        .name = "control",
        .environ = &target_env,
        .tty = undefined,
        .status = .{},
        .flags = T.CLIENT_CONTROL,
    };
    defer control_subscriptions.control_subscriptions_deinit(&target_client);
    target_client.tty.client = &target_client;

    var cause: ?[]u8 = null;
    const add = try cmd_mod.cmd_parse_one(&.{ "refresh-client", "-B", "watch::#{session_name}" }, null, &cause);
    defer cmd_mod.cmd_free(add);

    var item = cmdq.CmdqItem{ .target_client = &target_client };
    try std.testing.expectEqual(T.CmdRetval.normal, exec(add, &item));
    try std.testing.expectEqual(@as(usize, 1), target_client.control_subscriptions.items.len);
    try std.testing.expectEqualStrings("watch", target_client.control_subscriptions.items[0].name);
    try std.testing.expectEqual(T.ControlSubType.session, target_client.control_subscriptions.items[0].sub_type);
    try std.testing.expectEqualStrings("#{session_name}", target_client.control_subscriptions.items[0].format);

    const remove = try cmd_mod.cmd_parse_one(&.{ "refresh-client", "-B", "watch" }, null, &cause);
    defer cmd_mod.cmd_free(remove);

    try std.testing.expectEqual(T.CmdRetval.normal, exec(remove, &item));
    try std.testing.expectEqual(@as(usize, 0), target_client.control_subscriptions.items.len);
}

test "refresh-client -B parses pane and window subscription targets" {
    var target_env = T.Environ.init(std.testing.allocator);
    defer target_env.deinit();

    var target_client = T.Client{
        .name = "control",
        .environ = &target_env,
        .tty = undefined,
        .status = .{},
        .flags = T.CLIENT_CONTROL,
    };
    defer control_subscriptions.control_subscriptions_deinit(&target_client);
    target_client.tty.client = &target_client;

    var cause: ?[]u8 = null;
    const refresh = try cmd_mod.cmd_parse_one(
        &.{
            "refresh-client",
            "-B",
            "pane:%7:#{pane_id}",
            "-B",
            "panes:%*:#{pane_id}",
            "-B",
            "window:@3:#{window_id}",
            "-B",
            "windows:@*:#{window_id}",
        },
        null,
        &cause,
    );
    defer cmd_mod.cmd_free(refresh);

    var item = cmdq.CmdqItem{ .target_client = &target_client };
    try std.testing.expectEqual(T.CmdRetval.normal, exec(refresh, &item));
    try std.testing.expectEqual(@as(usize, 4), target_client.control_subscriptions.items.len);
    try std.testing.expectEqual(T.ControlSubType.pane, target_client.control_subscriptions.items[0].sub_type);
    try std.testing.expectEqual(@as(u32, 7), target_client.control_subscriptions.items[0].id);
    try std.testing.expectEqual(T.ControlSubType.all_panes, target_client.control_subscriptions.items[1].sub_type);
    try std.testing.expectEqual(T.ControlSubType.window, target_client.control_subscriptions.items[2].sub_type);
    try std.testing.expectEqual(@as(u32, 3), target_client.control_subscriptions.items[2].id);
    try std.testing.expectEqual(T.ControlSubType.all_windows, target_client.control_subscriptions.items[3].sub_type);
}

test "refresh-client -B emits %subscription-changed for control clients" {
    const c = @import("c.zig");
    const env_mod = @import("environ.zig");
    const opts = @import("options.zig");
    const proc_mod = @import("proc.zig");
    const protocol = @import("zmux-protocol.zig");
    const session_mod = @import("session.zig");
    const xm = @import("xmalloc.zig");

    const helpers = struct {
        fn noopDispatch(_: ?*c.imsg.imsg, _: ?*anyopaque) callconv(.c) void {}
    };

    session_mod.session_init_globals(xm.allocator);
    window_mod.window_init_globals(xm.allocator);

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

    const session = session_mod.session_create(null, "refresh-subscriptions", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (session_mod.session_find("refresh-subscriptions") != null) session_mod.session_destroy(session, false, "test");

    const window = window_mod.window_create(80, 24, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    const pane = window_mod.window_add_pane(window, null, 80, 24);
    window.active = pane;

    var attach_cause: ?[]u8 = null;
    const wl = session_mod.session_attach(session, window, -1, &attach_cause).?;
    session.curw = wl;

    var pair: [2]i32 = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &pair));

    var proc = T.ZmuxProc{ .name = "refresh-client-subscription-test" };
    defer proc.peers.deinit(xm.allocator);

    var target_client = T.Client{
        .name = "control",
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{},
        .session = session,
        .flags = T.CLIENT_CONTROL | T.CLIENT_UTF8,
    };
    defer env_mod.environ_free(target_client.environ);
    defer control_subscriptions.control_subscriptions_deinit(&target_client);
    target_client.tty = .{ .client = &target_client };
    target_client.peer = proc_mod.proc_add_peer(&proc, pair[0], helpers.noopDispatch, null);
    defer {
        const peer = target_client.peer.?;
        c.imsg.imsgbuf_clear(&peer.ibuf);
        std.posix.close(peer.ibuf.fd);
        xm.allocator.destroy(peer);
        proc.peers.clearRetainingCapacity();
    }

    var reader: c.imsg.imsgbuf = undefined;
    try std.testing.expectEqual(@as(i32, 0), c.imsg.imsgbuf_init(&reader, pair[1]));
    defer {
        c.imsg.imsgbuf_clear(&reader);
        std.posix.close(pair[1]);
    }

    var cause: ?[]u8 = null;
    const refresh = try cmd_mod.cmd_parse_one(&.{ "refresh-client", "-B", "watch:%*:#{pane_id}" }, null, &cause);
    defer cmd_mod.cmd_free(refresh);

    var item = cmdq.CmdqItem{ .target_client = &target_client };
    try std.testing.expectEqual(T.CmdRetval.normal, exec(refresh, &item));

    control_subscriptions.control_check_subscriptions(&target_client);

    try std.testing.expectEqual(@as(i32, 1), c.imsg.imsgbuf_read(&reader));

    var imsg_msg: c.imsg.imsg = undefined;
    try std.testing.expect(c.imsg.imsg_get(&reader, &imsg_msg) > 0);
    defer c.imsg.imsg_free(&imsg_msg);

    try std.testing.expectEqual(@as(u32, @intCast(@intFromEnum(protocol.MsgType.write))), c.imsg.imsg_get_type(&imsg_msg));

    const payload_len = c.imsg.imsg_get_len(&imsg_msg);
    var payload = try xm.allocator.alloc(u8, payload_len);
    defer xm.allocator.free(payload);
    try std.testing.expectEqual(@as(i32, 0), c.imsg.imsg_get_data(&imsg_msg, payload.ptr, payload.len));

    var stream: i32 = 0;
    @memcpy(std.mem.asBytes(&stream), payload[0..@sizeOf(i32)]);
    try std.testing.expectEqual(@as(i32, 1), stream);

    const expected = xm.xasprintf("%subscription-changed watch ${d} @{d} {d} %{d} : %{d}\n", .{ session.id, window.id, wl.idx, pane.id, pane.id });
    defer xm.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, payload[@sizeOf(i32)..]);
}

test "refresh-client -r stores OSC report colours on the target pane" {
    const opts = @import("options.zig");
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
    window_mod.window_init_globals(xm.allocator);

    const window = window_mod.window_create(80, 24, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    defer {
        window_mod.window_destroy_all_panes(window);
        _ = window_mod.windows.remove(window.id);
        opts.options_free(window.options);
        xm.allocator.free(window.name);
        xm.allocator.destroy(window);
    }
    const wp = window_mod.window_add_pane(window, null, 80, 24);

    var queue_env = T.Environ.init(std.testing.allocator);
    defer queue_env.deinit();
    var target_env = T.Environ.init(std.testing.allocator);
    defer target_env.deinit();

    var queue_client = T.Client{
        .name = "queue",
        .environ = &queue_env,
        .tty = undefined,
        .status = .{},
    };
    queue_client.tty.client = &queue_client;

    var target_client = T.Client{
        .name = "target",
        .environ = &target_env,
        .tty = undefined,
        .status = .{},
    };
    target_client.tty.client = &target_client;

    var fg_buf: [128]u8 = undefined;
    const fg_report = try std.fmt.bufPrint(&fg_buf, "%{d}:\x1b]10;rgb:01/02/03\x07", .{wp.id});
    var cause: ?[]u8 = null;
    const fg_cmd = try cmd_mod.cmd_parse_one(&.{ "refresh-client", "-r", fg_report }, null, &cause);
    defer cmd_mod.cmd_free(fg_cmd);

    var item = cmdq.CmdqItem{
        .client = &queue_client,
        .target_client = &target_client,
    };
    try std.testing.expectEqual(T.CmdRetval.normal, exec(fg_cmd, &item));
    try std.testing.expectEqual(colour_mod.colour_join_rgb(0x01, 0x02, 0x03), wp.control_fg);
    try std.testing.expectEqual(@as(i32, -1), wp.control_bg);
    try std.testing.expect(target_client.flags & T.CLIENT_REDRAW != 0);

    target_client.flags = 0;
    var bg_buf: [128]u8 = undefined;
    const bg_report = try std.fmt.bufPrint(&bg_buf, "%{d}:\x1b]11;rgb:0a/0b/0c\x1b\\", .{wp.id});
    const bg_cmd = try cmd_mod.cmd_parse_one(&.{ "refresh-client", "-r", bg_report }, null, &cause);
    defer cmd_mod.cmd_free(bg_cmd);

    try std.testing.expectEqual(T.CmdRetval.normal, exec(bg_cmd, &item));
    try std.testing.expectEqual(colour_mod.colour_join_rgb(0x0a, 0x0b, 0x0c), wp.control_bg);
    try std.testing.expect(target_client.flags & T.CLIENT_REDRAW != 0);
}

test "refresh-client -r ignores malformed reports and missing panes" {
    const opts = @import("options.zig");
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
    window_mod.window_init_globals(xm.allocator);

    const window = window_mod.window_create(80, 24, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    defer {
        window_mod.window_destroy_all_panes(window);
        _ = window_mod.windows.remove(window.id);
        opts.options_free(window.options);
        xm.allocator.free(window.name);
        xm.allocator.destroy(window);
    }
    const wp = window_mod.window_add_pane(window, null, 80, 24);
    wp.control_fg = colour_mod.colour_join_rgb(0xaa, 0xbb, 0xcc);
    wp.control_bg = colour_mod.colour_join_rgb(0x11, 0x22, 0x33);

    var target_env = T.Environ.init(std.testing.allocator);
    defer target_env.deinit();
    var target_client = T.Client{
        .name = "target",
        .environ = &target_env,
        .tty = undefined,
        .status = .{},
    };
    target_client.tty.client = &target_client;

    var bad_buf: [128]u8 = undefined;
    const bad_report = try std.fmt.bufPrint(&bad_buf, "%{d}:\x1b]10;not-a-colour\x07", .{wp.id});
    var cause: ?[]u8 = null;
    const bad_cmd = try cmd_mod.cmd_parse_one(&.{ "refresh-client", "-r", bad_report }, null, &cause);
    defer cmd_mod.cmd_free(bad_cmd);

    var item = cmdq.CmdqItem{ .target_client = &target_client };
    try std.testing.expectEqual(T.CmdRetval.normal, exec(bad_cmd, &item));
    try std.testing.expectEqual(colour_mod.colour_join_rgb(0xaa, 0xbb, 0xcc), wp.control_fg);
    try std.testing.expectEqual(colour_mod.colour_join_rgb(0x11, 0x22, 0x33), wp.control_bg);

    target_client.flags = 0;
    var missing_buf: [128]u8 = undefined;
    const missing_report = try std.fmt.bufPrint(&missing_buf, "%99999:\x1b]11;rgb:de/ad/be\x07", .{});
    const missing_cmd = try cmd_mod.cmd_parse_one(&.{ "refresh-client", "-r", missing_report }, null, &cause);
    defer cmd_mod.cmd_free(missing_cmd);

    try std.testing.expectEqual(T.CmdRetval.normal, exec(missing_cmd, &item));
    try std.testing.expectEqual(colour_mod.colour_join_rgb(0xaa, 0xbb, 0xcc), wp.control_fg);
    try std.testing.expectEqual(colour_mod.colour_join_rgb(0x11, 0x22, 0x33), wp.control_bg);
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
        .status = .{},
    };
    queue_client.tty.client = &queue_client;

    var target_client = T.Client{
        .name = "target",
        .environ = &target_env,
        .tty = undefined,
        .status = .{},
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

fn test_peer_dispatch(_: ?*@import("c.zig").imsg.imsg, _: ?*anyopaque) callconv(.c) void {}
