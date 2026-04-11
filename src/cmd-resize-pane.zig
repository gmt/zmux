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
const args_mod = @import("arguments.zig");
const xm = @import("xmalloc.zig");
const cmd_mod = @import("cmd.zig");
const cmdq = @import("cmd-queue.zig");
const cmd_find = @import("cmd-find.zig");
const grid_mod = @import("grid.zig");
const layout_mod = @import("layout.zig");
const mouse_runtime = @import("mouse-runtime.zig");
const options_mod = @import("options.zig");
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
        if (trim_history(wp)) server_fn.server_redraw_pane(wp);
        return .normal;
    }
    if (args.has('M')) {
        const event = cmdq.cmdq_get_event(item);
        var mouse_session: ?*T.Session = null;
        if (!event.m.valid or mouse_runtime.cmd_mouse_window(&event.m, &mouse_session) == null)
            return .normal;
        const c = cmdq.cmdq_get_client(item) orelse return .normal;
        if (c.session != mouse_session)
            return .normal;
        c.tty.mouse_drag_update = cmd_resize_pane_mouse_update;
        cmd_resize_pane_mouse_update(c, &event.m);
        return .normal;
    }
    if (args.has('Z')) {
        if (!win.window_unzoom(w)) _ = win.window_zoom(wp);
        server_fn.server_redraw_window(w);
        server_fn.server_status_window(w);
        return .normal;
    }
    _ = win.window_unzoom(w);

    const adjust = parse_adjustment(args.value_at(0), item) orelse return .@"error";

    if (args.has('x')) {
        var cause: ?[]u8 = null;
        defer if (cause) |msg| xm.allocator.free(msg);
        const width = args_mod.args_percentage(args, 'x', 0, std.math.maxInt(i32), w.sx, &cause);
        if (cause != null) {
            cmdq.cmdq_error(item, "width {s}", .{cause.?});
            return .@"error";
        }
        _ = layout_mod.resize_pane_to(wp, .leftright, @intCast(width));
    }
    if (args.has('y')) {
        var cause: ?[]u8 = null;
        defer if (cause) |msg| xm.allocator.free(msg);
        const height = args_mod.args_percentage(args, 'y', 0, std.math.maxInt(i32), w.sy, &cause);
        if (cause != null) {
            cmdq.cmdq_error(item, "height {s}", .{cause.?});
            return .@"error";
        }
        _ = layout_mod.resize_pane_to(wp, .topbottom, @intCast(adjust_resize_height_for_border_status(wp, height)));
    }

    if (args.has('L'))
        _ = layout_mod.resize_pane(wp, .leftright, -@as(i32, @intCast(adjust)), true)
    else if (args.has('R'))
        _ = layout_mod.resize_pane(wp, .leftright, @intCast(adjust), true)
    else if (args.has('U'))
        _ = layout_mod.resize_pane(wp, .topbottom, -@as(i32, @intCast(adjust)), true)
    else if (args.has('D'))
        _ = layout_mod.resize_pane(wp, .topbottom, @intCast(adjust), true);

    server_fn.server_redraw_window(wl.window);
    return .normal;
}

fn adjust_resize_height_for_border_status(wp: *T.WindowPane, requested: i64) i64 {
    if (requested == std.math.maxInt(i32)) return requested;

    const status = @as(u32, @intCast(@max(options_mod.options_get_number(wp.window.options, "pane-border-status"), 0)));
    switch (status) {
        T.PANE_STATUS_TOP => {
            if (wp.yoff == 1) return requested + 1;
        },
        T.PANE_STATUS_BOTTOM => {
            if (wp.window.sy > 0 and wp.yoff + wp.sy == wp.window.sy - 1) return requested + 1;
        },
        else => {},
    }
    return requested;
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

fn trim_history(wp: *T.WindowPane) bool {
    if (wp.modes.items.len != 0) return false;

    const gd = wp.base.grid;
    if (gd.sy == 0) return false;

    var adjust = gd.sy - 1 - @min(wp.base.cy, gd.sy - 1);
    if (adjust > gd.hsize) adjust = gd.hsize;
    if (adjust == 0) return false;

    grid_mod.remove_history(gd, adjust);
    wp.base.cy += adjust;
    wp.flags |= T.PANE_REDRAW;
    return true;
}

fn cmd_resize_pane_mouse_update(c: *T.Client, m: *T.MouseEvent) void {
    const wl = mouse_runtime.cmd_mouse_window(m, null) orelse {
        c.tty.mouse_drag_update = null;
        c.tty.mouse_drag_release = null;
        return;
    };
    const w = wl.window;

    var y = m.y + m.oy;
    const x = m.x + m.ox;
    if (m.statusat == 0 and y >= m.statuslines)
        y -= m.statuslines
    else if (m.statusat > 0 and y >= @as(u32, @intCast(m.statusat)))
        y = @as(u32, @intCast(m.statusat - 1));

    var ly = m.ly + m.oy;
    const lx = m.lx + m.ox;
    if (m.statusat == 0 and ly >= m.statuslines)
        ly -= m.statuslines
    else if (m.statusat > 0 and ly >= @as(u32, @intCast(m.statusat)))
        ly = @as(u32, @intCast(m.statusat - 1));

    if (layout_mod.resize_by_border_drag(w, x, y, lx, ly))
        server_fn.server_redraw_window(w);
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

fn set_pane_geometry(wp: *T.WindowPane, xoff: u32, yoff: u32, sx: u32, sy: u32) void {
    wp.xoff = xoff;
    wp.yoff = yoff;
    wp.sx = sx;
    wp.sy = sy;
}

test "resize-pane -R grows only the matching horizontal branch" {
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
    const top_left = wl.window.active.?;
    var right_ctx: T.SpawnContext = .{ .s = s, .wl = wl, .flags = T.SPAWN_EMPTY };
    const top_right = spawn.spawn_pane(&right_ctx, &cause).?;
    var bottom_ctx: T.SpawnContext = .{ .s = s, .wl = wl, .flags = T.SPAWN_EMPTY };
    const bottom = spawn.spawn_pane(&bottom_ctx, &cause).?;
    s.curw = wl;

    set_pane_geometry(top_left, 0, 0, 40, 12);
    set_pane_geometry(top_right, 41, 0, 39, 12);
    set_pane_geometry(bottom, 0, 13, 80, 11);

    var parse_cause: ?[]u8 = null;
    const resize_cmd = try cmd_mod.cmd_parse_one(&.{ "resize-pane", "-R", "-t", "resize-pane-layout:0.0", "5" }, null, &parse_cause);
    defer cmd_mod.cmd_free(resize_cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(resize_cmd, &item));
    try std.testing.expectEqual(@as(u32, 45), top_left.sx);
    try std.testing.expectEqual(@as(u32, 46), top_right.xoff);
    try std.testing.expectEqual(@as(u32, 34), top_right.sx);
    try std.testing.expectEqual(@as(u32, 0), bottom.xoff);
    try std.testing.expectEqual(@as(u32, 13), bottom.yoff);
    try std.testing.expectEqual(@as(u32, 80), bottom.sx);
    try std.testing.expectEqual(@as(u32, 11), bottom.sy);
}

test "resize-pane -R grows the whole left column when horizontal resize climbs past a vertical split" {
    const opts = @import("options.zig");
    const env_mod = @import("environ.zig");
    const sess = @import("session.zig");
    const spawn = @import("spawn.zig");

    init_test_globals();
    defer deinit_test_globals();

    const s = sess.session_create(null, "resize-pane-column", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("resize-pane-column") != null) sess.session_destroy(s, false, "test");

    var cause: ?[]u8 = null;
    var ctx: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const wl = spawn.spawn_window(&ctx, &cause).?;
    const top_left = wl.window.active.?;
    var bottom_ctx: T.SpawnContext = .{ .s = s, .wl = wl, .flags = T.SPAWN_EMPTY };
    const bottom_left = spawn.spawn_pane(&bottom_ctx, &cause).?;
    var right_ctx: T.SpawnContext = .{ .s = s, .wl = wl, .flags = T.SPAWN_EMPTY };
    const right = spawn.spawn_pane(&right_ctx, &cause).?;
    s.curw = wl;

    set_pane_geometry(top_left, 0, 0, 39, 11);
    set_pane_geometry(bottom_left, 0, 12, 39, 12);
    set_pane_geometry(right, 40, 0, 40, 24);

    var parse_cause: ?[]u8 = null;
    const resize_cmd = try cmd_mod.cmd_parse_one(&.{ "resize-pane", "-R", "-t", "resize-pane-column:0.0", "3" }, null, &parse_cause);
    defer cmd_mod.cmd_free(resize_cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(resize_cmd, &item));
    try std.testing.expectEqual(@as(u32, 42), top_left.sx);
    try std.testing.expectEqual(@as(u32, 42), bottom_left.sx);
    try std.testing.expectEqual(@as(u32, 43), right.xoff);
    try std.testing.expectEqual(@as(u32, 37), right.sx);
}

test "resize-pane -R prefers layout_root over stale pane rectangles" {
    const opts = @import("options.zig");
    const env_mod = @import("environ.zig");
    const sess = @import("session.zig");
    const spawn = @import("spawn.zig");

    init_test_globals();
    defer deinit_test_globals();

    const s = sess.session_create(null, "resize-pane-root", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("resize-pane-root") != null) sess.session_destroy(s, false, "test");

    var cause: ?[]u8 = null;
    var ctx: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const wl = spawn.spawn_window(&ctx, &cause).?;
    const left = wl.window.active.?;
    const lc2 = layout_mod.layout_split_pane(left, .leftright, -1, 0).?;
    var right_ctx: T.SpawnContext = .{ .s = s, .wl = wl, .lc = lc2, .flags = T.SPAWN_EMPTY };
    const right = spawn.spawn_pane(&right_ctx, &cause).?;
    s.curw = wl;

    set_pane_geometry(left, 0, 0, 10, 24);
    set_pane_geometry(right, 11, 0, 69, 24);

    var parse_cause: ?[]u8 = null;
    const resize_cmd = try cmd_mod.cmd_parse_one(&.{ "resize-pane", "-R", "-t", "resize-pane-root:0.0", "5" }, null, &parse_cause);
    defer cmd_mod.cmd_free(resize_cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(resize_cmd, &item));
    try std.testing.expectEqual(@as(u32, 45), left.sx);
    try std.testing.expectEqual(@as(u32, 46), right.xoff);
    try std.testing.expectEqual(@as(u32, 34), right.sx);
}

test "resize-pane -x resizes the last pane by moving its left border" {
    const opts = @import("options.zig");
    const env_mod = @import("environ.zig");
    const sess = @import("session.zig");
    const spawn = @import("spawn.zig");

    init_test_globals();
    defer deinit_test_globals();

    const s = sess.session_create(null, "resize-pane-width", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("resize-pane-width") != null) sess.session_destroy(s, false, "test");

    var cause: ?[]u8 = null;
    var ctx: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const wl = spawn.spawn_window(&ctx, &cause).?;
    const left = wl.window.active.?;
    var right_ctx: T.SpawnContext = .{ .s = s, .wl = wl, .flags = T.SPAWN_EMPTY };
    const right = spawn.spawn_pane(&right_ctx, &cause).?;
    s.curw = wl;

    set_pane_geometry(left, 0, 0, 40, 24);
    set_pane_geometry(right, 41, 0, 39, 24);

    var parse_cause: ?[]u8 = null;
    const resize_cmd = try cmd_mod.cmd_parse_one(&.{ "resize-pane", "-x", "30", "-t", "resize-pane-width:0.1" }, null, &parse_cause);
    defer cmd_mod.cmd_free(resize_cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(resize_cmd, &item));
    try std.testing.expectEqual(@as(u32, 49), left.sx);
    try std.testing.expectEqual(@as(u32, 50), right.xoff);
    try std.testing.expectEqual(@as(u32, 30), right.sx);
}

test "resize-pane -y adjusts a vertical split to the requested height" {
    const opts = @import("options.zig");
    const env_mod = @import("environ.zig");
    const sess = @import("session.zig");
    const spawn = @import("spawn.zig");

    init_test_globals();
    defer deinit_test_globals();

    const s = sess.session_create(null, "resize-pane-height", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("resize-pane-height") != null) sess.session_destroy(s, false, "test");

    var cause: ?[]u8 = null;
    var ctx: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const wl = spawn.spawn_window(&ctx, &cause).?;
    const top = wl.window.active.?;
    var bottom_ctx: T.SpawnContext = .{ .s = s, .wl = wl, .flags = T.SPAWN_EMPTY };
    const bottom = spawn.spawn_pane(&bottom_ctx, &cause).?;
    s.curw = wl;

    set_pane_geometry(top, 0, 0, 80, 12);
    set_pane_geometry(bottom, 0, 13, 80, 11);

    var parse_cause: ?[]u8 = null;
    const resize_cmd = try cmd_mod.cmd_parse_one(&.{ "resize-pane", "-y", "8", "-t", "resize-pane-height:0.0" }, null, &parse_cause);
    defer cmd_mod.cmd_free(resize_cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(resize_cmd, &item));
    try std.testing.expectEqual(@as(u32, 8), top.sy);
    try std.testing.expectEqual(@as(u32, 9), bottom.yoff);
    try std.testing.expectEqual(@as(u32, 15), bottom.sy);
}

test "resize-pane -y counts the top pane-border status row for the owning pane" {
    const opts = @import("options.zig");
    const env_mod = @import("environ.zig");
    const sess = @import("session.zig");
    const spawn = @import("spawn.zig");

    init_test_globals();
    defer deinit_test_globals();

    const s = sess.session_create(null, "resize-pane-height-top-status", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("resize-pane-height-top-status") != null) sess.session_destroy(s, false, "test");

    var cause: ?[]u8 = null;
    var ctx: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const wl = spawn.spawn_window(&ctx, &cause).?;
    const top = wl.window.active.?;
    var bottom_ctx: T.SpawnContext = .{ .s = s, .wl = wl, .flags = T.SPAWN_EMPTY };
    const bottom = spawn.spawn_pane(&bottom_ctx, &cause).?;
    s.curw = wl;
    opts.options_set_number(wl.window.options, "pane-border-status", T.PANE_STATUS_TOP);

    set_pane_geometry(top, 0, 1, 80, 11);
    set_pane_geometry(bottom, 0, 13, 80, 11);

    var parse_cause: ?[]u8 = null;
    const resize_cmd = try cmd_mod.cmd_parse_one(&.{ "resize-pane", "-y", "8", "-t", "resize-pane-height-top-status:0.0" }, null, &parse_cause);
    defer cmd_mod.cmd_free(resize_cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(resize_cmd, &item));
    try std.testing.expectEqual(@as(u32, 9), top.sy);
    try std.testing.expectEqual(@as(u32, 11), bottom.yoff);
    try std.testing.expectEqual(@as(u32, 13), bottom.sy);
}

test "resize-pane -y counts the bottom pane-border status row for the owning pane" {
    const opts = @import("options.zig");
    const env_mod = @import("environ.zig");
    const sess = @import("session.zig");
    const spawn = @import("spawn.zig");

    init_test_globals();
    defer deinit_test_globals();

    const s = sess.session_create(null, "resize-pane-height-bottom-status", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("resize-pane-height-bottom-status") != null) sess.session_destroy(s, false, "test");

    var cause: ?[]u8 = null;
    var ctx: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const wl = spawn.spawn_window(&ctx, &cause).?;
    const top = wl.window.active.?;
    var bottom_ctx: T.SpawnContext = .{ .s = s, .wl = wl, .flags = T.SPAWN_EMPTY };
    const bottom = spawn.spawn_pane(&bottom_ctx, &cause).?;
    s.curw = wl;
    opts.options_set_number(wl.window.options, "pane-border-status", T.PANE_STATUS_BOTTOM);

    set_pane_geometry(top, 0, 0, 80, 11);
    set_pane_geometry(bottom, 0, 12, 80, 11);

    var parse_cause: ?[]u8 = null;
    const resize_cmd = try cmd_mod.cmd_parse_one(&.{ "resize-pane", "-y", "8", "-t", "resize-pane-height-bottom-status:0.1" }, null, &parse_cause);
    defer cmd_mod.cmd_free(resize_cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(resize_cmd, &item));
    try std.testing.expectEqual(@as(u32, 13), top.sy);
    try std.testing.expectEqual(@as(u32, 14), bottom.yoff);
    try std.testing.expectEqual(@as(u32, 9), bottom.sy);
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

test "resize-pane -Z toggles the reduced zoom flag and targets the requested pane" {
    const opts = @import("options.zig");
    const env_mod = @import("environ.zig");
    const sess = @import("session.zig");
    const spawn = @import("spawn.zig");

    init_test_globals();
    defer deinit_test_globals();

    const s = sess.session_create(null, "resize-pane-zoom-toggle", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("resize-pane-zoom-toggle") != null) sess.session_destroy(s, false, "test");

    var cause: ?[]u8 = null;
    var root_ctx: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const wl = spawn.spawn_window(&root_ctx, &cause).?;
    const first = wl.window.active.?;
    var split_ctx: T.SpawnContext = .{ .s = s, .wl = wl, .flags = T.SPAWN_EMPTY };
    const second = spawn.spawn_pane(&split_ctx, &cause).?;

    const target = std.fmt.allocPrint(xm.allocator, "%{d}", .{second.id}) catch unreachable;
    defer xm.allocator.free(target);

    var parse_cause: ?[]u8 = null;
    const zoom_cmd = try cmd_mod.cmd_parse_one(&.{ "resize-pane", "-t", target, "-Z" }, null, &parse_cause);
    defer cmd_mod.cmd_free(zoom_cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };

    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(zoom_cmd, &item));
    try std.testing.expectEqual(second, wl.window.active.?);
    try std.testing.expect(wl.window.flags & T.WINDOW_ZOOMED != 0);
    try std.testing.expect(!win.window_pane_visible(first));
    try std.testing.expect(win.window_pane_visible(second));

    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(zoom_cmd, &item));
    try std.testing.expectEqual(second, wl.window.active.?);
    try std.testing.expectEqual(@as(u32, 0), wl.window.flags & T.WINDOW_ZOOMED);
    try std.testing.expect(win.window_pane_visible(first));
    try std.testing.expect(win.window_pane_visible(second));
}

test "resize-pane -M installs the mouse drag callback and resizes the border path" {
    const env_mod = @import("environ.zig");
    const opts = @import("options.zig");
    const sess = @import("session.zig");
    const spawn = @import("spawn.zig");

    init_test_globals();
    defer deinit_test_globals();

    const s = sess.session_create(null, "resize-pane-mouse", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("resize-pane-mouse") != null) sess.session_destroy(s, false, "test");

    var cause: ?[]u8 = null;
    var ctx: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const wl = spawn.spawn_window(&ctx, &cause).?;
    const left = wl.window.active.?;
    var right_ctx: T.SpawnContext = .{ .s = s, .wl = wl, .flags = T.SPAWN_EMPTY };
    const right = spawn.spawn_pane(&right_ctx, &cause).?;
    s.curw = wl;

    set_pane_geometry(left, 0, 0, 40, 24);
    set_pane_geometry(right, 41, 0, 39, 24);

    var client = T.Client{
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{},
        .session = s,
    };
    defer env_mod.environ_free(client.environ);
    client.tty = .{ .client = &client, .sx = 80, .sy = 24 };

    const target = std.fmt.allocPrint(xm.allocator, "%{d}", .{left.id}) catch unreachable;
    defer xm.allocator.free(target);

    var parse_cause: ?[]u8 = null;
    const resize_cmd = try cmd_mod.cmd_parse_one(&.{ "resize-pane", "-M", "-t", target }, null, &parse_cause);
    defer cmd_mod.cmd_free(resize_cmd);

    var event = T.key_event{ .key = T.keycMouse(T.KEYC_MOUSEDRAG1, .border), .len = 1 };
    event.m = .{
        .valid = true,
        .key = T.keycMouse(T.KEYC_MOUSEDRAG1, .border),
        .s = @intCast(s.id),
        .w = @intCast(wl.window.id),
        .wp = @intCast(left.id),
        .x = 45,
        .y = 5,
        .lx = 40,
        .ly = 5,
        .lb = T.MOUSE_BUTTON_1,
        .b = T.MOUSE_BUTTON_1 | T.MOUSE_MASK_DRAG,
    };

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &client, .cmdlist = &list, .event = event };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(resize_cmd, &item));
    try std.testing.expect(client.tty.mouse_drag_update != null);
    try std.testing.expectEqual(@as(u32, 45), left.sx);
    try std.testing.expectEqual(@as(u32, 46), right.xoff);
    try std.testing.expectEqual(@as(u32, 34), right.sx);

    var followup = T.key_event{ .key = T.KEYC_MOUSE, .len = 1 };
    followup.m = .{
        .x = 47,
        .y = 5,
        .lx = 45,
        .ly = 5,
        .lb = T.MOUSE_BUTTON_1,
        .b = T.MOUSE_BUTTON_1 | T.MOUSE_MASK_DRAG,
    };
    try std.testing.expect(server_fn.server_client_handle_key(&client, &followup));
    try std.testing.expectEqual(@as(u32, 47), left.sx);
    try std.testing.expectEqual(@as(u32, 48), right.xoff);
    try std.testing.expectEqual(@as(u32, 32), right.sx);
}
