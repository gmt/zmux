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
// Ported in part from tmux/cmd-select-layout.c.
// Original copyright:
//   Copyright (c) 2009 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const cmd_mod = @import("cmd.zig");
const cmdq = @import("cmd-queue.zig");
const cmd_find = @import("cmd-find.zig");
const layout_mod = @import("layout.zig");
const notify = @import("notify.zig");
const server_fn = @import("server-fn.zig");
const win = @import("window.zig");

fn exec(cmd: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {
    const args = cmd_mod.cmd_get_args(cmd);
    const entry_ptr = cmd_mod.cmd_get_entry(cmd);

    var target: T.CmdFindState = .{};
    const find_type: T.CmdFindType = if (entry_ptr == &entry_next or entry_ptr == &entry_previous) .window else .pane;
    if (cmd_find.cmd_find_target(&target, item, args.get('t'), find_type, 0) != 0)
        return .@"error";
    const wl = target.wl orelse return .@"error";
    const w = wl.window;
    const wp = target.wp orelse w.active orelse return .@"error";

    _ = win.window_unzoom(w);

    const next = entry_ptr == &entry_next or args.has('n');
    const previous = entry_ptr == &entry_previous or args.has('p');

    const oldlayout = w.old_layout;
    w.old_layout = snapshotLayout(w);

    if (next or previous) {
        if (next)
            _ = layout_mod.set_next(w)
        else
            _ = layout_mod.set_previous(w);
        return finish_success(w, oldlayout);
    }

    if (args.has('E')) {
        _ = layout_mod.spread_out(wp);
        return finish_success(w, oldlayout);
    }

    const layout_name: ?[]const u8 = if (args.count() != 0)
        args.value_at(0)
    else if (args.has('o'))
        oldlayout
    else
        null;

    if (!args.has('o')) {
        const layout_idx = if (layout_name) |name|
            layout_mod.set_lookup(name)
        else
            w.lastlayout;
        if (layout_idx != -1) {
            _ = layout_mod.set_select(w, @intCast(layout_idx));
            return finish_success(w, oldlayout);
        }
    }

    if (layout_name) |name| {
        var cause: ?[]u8 = null;
        defer if (cause) |msg| xm.allocator.free(msg);
        if (!layout_mod.parse_window(w, name, &cause)) {
            if (w.old_layout) |snapshot| xm.allocator.free(snapshot);
            w.old_layout = oldlayout;
            cmdq.cmdq_error(item, "{s}: {s}", .{ cause orelse "invalid layout", name });
            return .@"error";
        }
        return finish_success(w, oldlayout);
    }

    if (oldlayout) |snapshot| xm.allocator.free(snapshot);
    return .normal;
}

fn finish_success(w: *T.Window, oldlayout: ?[]u8) T.CmdRetval {
    if (oldlayout) |snapshot| xm.allocator.free(snapshot);
    server_fn.server_redraw_window(w);
    server_fn.server_status_window(w);
    notify.notify_window("window-layout-changed", w);
    return .normal;
}

fn snapshotLayout(w: *T.Window) ?[]u8 {
    if (w.layout_root) |root|
        return layout_mod.dump_root(root);
    return layout_mod.dump_window(w);
}

pub const entry: cmd_mod.CmdEntry = .{
    .name = "select-layout",
    .alias = "selectl",
    .usage = "[-Enop] [-t target-pane] [layout-name]",
    .template = "Enopt:",
    .lower = 0,
    .upper = 1,
    .flags = T.CMD_AFTERHOOK,
    .exec = exec,
};

pub const entry_next: cmd_mod.CmdEntry = .{
    .name = "next-layout",
    .alias = "nextl",
    .usage = "[-t target-window]",
    .template = "t:",
    .lower = 0,
    .upper = 0,
    .flags = T.CMD_AFTERHOOK,
    .exec = exec,
};

pub const entry_previous: cmd_mod.CmdEntry = .{
    .name = "previous-layout",
    .alias = "prevl",
    .usage = "[-t target-window]",
    .template = "t:",
    .lower = 0,
    .upper = 0,
    .flags = T.CMD_AFTERHOOK,
    .exec = exec,
};

fn init_test_globals() void {
    const opts = @import("options.zig");
    const env_mod = @import("environ.zig");
    const sess = @import("session.zig");

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
    const opts = @import("options.zig");
    const env_mod = @import("environ.zig");

    env_mod.environ_free(env_mod.global_environ);
    opts.options_free(opts.global_options);
    opts.options_free(opts.global_s_options);
    opts.options_free(opts.global_w_options);
}

fn set_pane_geometry(wp: *T.WindowPane, xoff: u32, yoff: u32, sx: u32, sy: u32) void {
    wp.xoff = xoff;
    wp.yoff = yoff;
    wp.sx = sx;
    wp.sy = sy;
}

test "select-layout and layout aliases are registered" {
    try std.testing.expectEqual(&entry, cmd_mod.cmd_find_entry("select-layout").?);
    try std.testing.expectEqual(&entry, cmd_mod.cmd_find_entry("selectl").?);
    try std.testing.expectEqual(&entry_next, cmd_mod.cmd_find_entry("next-layout").?);
    try std.testing.expectEqual(&entry_next, cmd_mod.cmd_find_entry("nextl").?);
    try std.testing.expectEqual(&entry_previous, cmd_mod.cmd_find_entry("previous-layout").?);
    try std.testing.expectEqual(&entry_previous, cmd_mod.cmd_find_entry("prevl").?);
}

test "select-layout applies presets and next-layout cycles forward" {
    const env_mod = @import("environ.zig");
    const opts = @import("options.zig");
    const sess = @import("session.zig");
    const spawn = @import("spawn.zig");

    init_test_globals();
    defer deinit_test_globals();

    const s = sess.session_create(null, "select-layout-cycle", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("select-layout-cycle") != null) sess.session_destroy(s, false, "test");

    var cause: ?[]u8 = null;
    var first_ctx: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const wl = spawn.spawn_window(&first_ctx, &cause).?;
    const first = wl.window.active.?;
    var second_ctx: T.SpawnContext = .{ .s = s, .wl = wl, .flags = T.SPAWN_EMPTY };
    const second = spawn.spawn_pane(&second_ctx, &cause).?;
    var third_ctx: T.SpawnContext = .{ .s = s, .wl = wl, .flags = T.SPAWN_EMPTY };
    const third = spawn.spawn_pane(&third_ctx, &cause).?;
    s.curw = wl;

    _ = second;
    _ = third;

    var parse_cause: ?[]u8 = null;
    const select_cmd = try cmd_mod.cmd_parse_one(&.{ "select-layout", "-t", "select-layout-cycle:0.0", "even-horizontal" }, null, &parse_cause);
    defer cmd_mod.cmd_free(select_cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(select_cmd, &item));

    try std.testing.expectEqual(@as(i32, 0), wl.window.lastlayout);
    try std.testing.expectEqual(@as(u32, 0), first.xoff);
    try std.testing.expectEqual(wl.window.sx, first.sx + 1 + wl.window.panes.items[1].sx + 1 + wl.window.panes.items[2].sx);
    try std.testing.expectEqual(@as(u32, 0), wl.window.panes.items[1].yoff);

    const next_cmd = try cmd_mod.cmd_parse_one(&.{ "next-layout", "-t", "select-layout-cycle:0" }, null, &parse_cause);
    defer cmd_mod.cmd_free(next_cmd);
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(next_cmd, &item));
    try std.testing.expectEqual(@as(i32, 1), wl.window.lastlayout);
    try std.testing.expectEqual(@as(u32, 0), first.yoff);
    try std.testing.expectEqual(wl.window.sy, first.sy + 1 + wl.window.panes.items[1].sy + 1 + wl.window.panes.items[2].sy);
}

test "select-layout -E spreads sibling panes evenly" {
    const env_mod = @import("environ.zig");
    const opts = @import("options.zig");
    const sess = @import("session.zig");
    const spawn = @import("spawn.zig");

    init_test_globals();
    defer deinit_test_globals();

    const s = sess.session_create(null, "select-layout-spread", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("select-layout-spread") != null) sess.session_destroy(s, false, "test");

    var cause: ?[]u8 = null;
    var first_ctx: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const wl = spawn.spawn_window(&first_ctx, &cause).?;
    const first = wl.window.active.?;
    var second_ctx: T.SpawnContext = .{ .s = s, .wl = wl, .flags = T.SPAWN_EMPTY };
    const second = spawn.spawn_pane(&second_ctx, &cause).?;
    s.curw = wl;

    set_pane_geometry(first, 0, 0, 60, wl.window.sy);
    set_pane_geometry(second, 61, 0, 19, wl.window.sy);

    const target = xm.xasprintf("%{d}", .{first.id});
    defer xm.allocator.free(target);

    var parse_cause: ?[]u8 = null;
    const spread_cmd = try cmd_mod.cmd_parse_one(&.{ "select-layout", "-E", "-t", target }, null, &parse_cause);
    defer cmd_mod.cmd_free(spread_cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(spread_cmd, &item));

    try std.testing.expectEqual(@as(u32, 40), first.sx);
    try std.testing.expectEqual(@as(u32, 41), second.xoff);
    try std.testing.expectEqual(@as(u32, 39), second.sx);
}

test "select-layout undo and explicit layout strings restore dumped geometry" {
    const env_mod = @import("environ.zig");
    const opts = @import("options.zig");
    const sess = @import("session.zig");
    const spawn = @import("spawn.zig");

    init_test_globals();
    defer deinit_test_globals();

    const s = sess.session_create(null, "select-layout-restore", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("select-layout-restore") != null) sess.session_destroy(s, false, "test");

    var cause: ?[]u8 = null;
    var first_ctx: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const wl = spawn.spawn_window(&first_ctx, &cause).?;
    const first = wl.window.active.?;
    const lc2 = layout_mod.layout_split_pane(first, .leftright, -1, 0).?;
    var second_ctx: T.SpawnContext = .{ .s = s, .wl = wl, .lc = lc2, .flags = T.SPAWN_EMPTY };
    const second = spawn.spawn_pane(&second_ctx, &cause).?;
    s.curw = wl;

    const original_first_sx = first.sx;
    const original_second_xoff = second.xoff;
    const original_second_sx = second.sx;
    const dumped = snapshotLayout(wl.window).?;
    defer xm.allocator.free(dumped);
    const first_target = xm.xasprintf("%{d}", .{first.id});
    defer xm.allocator.free(first_target);

    var parse_cause: ?[]u8 = null;
    const preset_cmd = try cmd_mod.cmd_parse_one(&.{ "select-layout", "-t", first_target, "even-vertical" }, null, &parse_cause);
    defer cmd_mod.cmd_free(preset_cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(preset_cmd, &item));
    try std.testing.expectEqual(@as(u32, 0), second.xoff);
    try std.testing.expectEqual(@as(u32, first.sy + 1), second.yoff);

    const undo_cmd = try cmd_mod.cmd_parse_one(&.{ "select-layout", "-o", "-t", first_target }, null, &parse_cause);
    defer cmd_mod.cmd_free(undo_cmd);
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(undo_cmd, &item));
    try std.testing.expectEqual(original_first_sx, first.sx);
    try std.testing.expectEqual(original_second_xoff, second.xoff);
    try std.testing.expectEqual(original_second_sx, second.sx);

    const second_target = xm.xasprintf("%{d}", .{second.id});
    defer xm.allocator.free(second_target);
    const custom_cmd = try cmd_mod.cmd_parse_one(&.{ "select-layout", "-t", second_target, dumped }, null, &parse_cause);
    defer cmd_mod.cmd_free(custom_cmd);
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(custom_cmd, &item));
    try std.testing.expectEqual(original_first_sx, first.sx);
    try std.testing.expectEqual(original_second_xoff, second.xoff);
    try std.testing.expectEqual(original_second_sx, second.sx);
}

test "select-layout snapshots undo state from layout_root even with stale pane rectangles" {
    const env_mod = @import("environ.zig");
    const opts = @import("options.zig");
    const sess = @import("session.zig");
    const spawn = @import("spawn.zig");

    init_test_globals();
    defer deinit_test_globals();

    const s = sess.session_create(null, "select-layout-root-snapshot", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("select-layout-root-snapshot") != null) sess.session_destroy(s, false, "test");

    var cause: ?[]u8 = null;
    var first_ctx: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const wl = spawn.spawn_window(&first_ctx, &cause).?;
    const first = wl.window.active.?;
    const lc2 = layout_mod.layout_split_pane(first, .leftright, -1, 0).?;
    var second_ctx: T.SpawnContext = .{ .s = s, .wl = wl, .lc = lc2, .flags = T.SPAWN_EMPTY };
    const second = spawn.spawn_pane(&second_ctx, &cause).?;
    s.curw = wl;

    const authoritative = snapshotLayout(wl.window).?;
    defer xm.allocator.free(authoritative);
    const original_first_sx = first.sx;
    const original_second_xoff = second.xoff;
    const original_second_sx = second.sx;

    set_pane_geometry(first, 0, 0, 70, wl.window.sy);
    set_pane_geometry(second, 71, 0, 9, wl.window.sy);

    const first_target = xm.xasprintf("%{d}", .{first.id});
    defer xm.allocator.free(first_target);
    const second_target = xm.xasprintf("%{d}", .{second.id});
    defer xm.allocator.free(second_target);

    var parse_cause: ?[]u8 = null;
    const preset_cmd = try cmd_mod.cmd_parse_one(&.{ "select-layout", "-t", first_target, "even-vertical" }, null, &parse_cause);
    defer cmd_mod.cmd_free(preset_cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(preset_cmd, &item));

    const undo_cmd = try cmd_mod.cmd_parse_one(&.{ "select-layout", "-o", "-t", first_target }, null, &parse_cause);
    defer cmd_mod.cmd_free(undo_cmd);
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(undo_cmd, &item));
    try std.testing.expectEqual(original_first_sx, first.sx);
    try std.testing.expectEqual(original_second_xoff, second.xoff);
    try std.testing.expectEqual(original_second_sx, second.sx);

    const custom_cmd = try cmd_mod.cmd_parse_one(&.{ "select-layout", "-t", second_target, authoritative }, null, &parse_cause);
    defer cmd_mod.cmd_free(custom_cmd);
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(custom_cmd, &item));
    try std.testing.expectEqual(original_first_sx, first.sx);
    try std.testing.expectEqual(original_second_xoff, second.xoff);
    try std.testing.expectEqual(original_second_sx, second.sx);
}
