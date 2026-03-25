// Copyright (c) 2026 Greg Turner <gmt@pobox.com>
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
// Ported in part from tmux/cmd-break-pane.c.
// Original copyright:
//   Copyright (c) 2009 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const cmd_mod = @import("cmd.zig");
const cmd_format = @import("cmd-format.zig");
const cmdq = @import("cmd-queue.zig");
const cmd_find = @import("cmd-find.zig");
const sess = @import("session.zig");
const win = @import("window.zig");
const names_mod = @import("names.zig");
const opts = @import("options.zig");
const server_fn = @import("server-fn.zig");

const BREAK_PANE_TEMPLATE = "#{session_name}:#{window_index}.#{pane_index}";

fn exec(cmd: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {
    const args = cmd_mod.cmd_get_args(cmd);
    if (args.has('a')) {
        cmdq.cmdq_error(item, "-a not supported yet", .{});
        return .@"error";
    }
    if (args.has('b')) {
        cmdq.cmdq_error(item, "-b not supported yet", .{});
        return .@"error";
    }

    var source: T.CmdFindState = .{};
    if (cmd_find.cmd_find_target(&source, item, args.get('s'), .pane, 0) != 0)
        return .@"error";
    const src_s = source.s orelse return .@"error";
    const src_wl = source.wl orelse return .@"error";
    const src_wp = source.wp orelse return .@"error";
    const src_w = src_wl.window;
    const src_idx = src_wl.idx;

    var target: T.CmdFindState = .{};
    if (cmd_find.cmd_find_target(&target, item, args.get('t'), .window, T.CMD_FIND_WINDOW_INDEX) != 0)
        return .@"error";
    const dst_s = target.s orelse return .@"error";
    const dst_idx: i32 = if (args.get('t') == null) -1 else target.idx;

    var result_wl: ?*T.Winlink = null;
    const result_wp = src_wp;

    if (win.window_count_panes(src_w) == 1) {
        var cause: ?[]u8 = null;
        defer if (cause) |msg| xm.allocator.free(msg);

        if (server_fn.server_link_window(src_s, src_wl, dst_s, dst_idx, false, !args.has('d'), &cause) != 0) {
            cmdq.cmdq_error(item, "{s}", .{cause orelse "break-pane failed"});
            return .@"error";
        }

        if (args.get('n')) |name| {
            win.window_set_name(src_w, name);
            opts.options_set_number(src_w.options, "automatic-rename", 0);
        }

        result_wl = find_result_winlink(dst_s, src_w, dst_idx, if (src_s == dst_s) src_idx else -1);
        if (result_wl == null) {
            cmdq.cmdq_error(item, "break-pane could not locate new window link", .{});
            return .@"error";
        }

        server_fn.server_unlink_window(src_s, src_wl);
    } else {
        if (dst_idx != -1 and sess.winlink_find_by_index(&dst_s.windows, dst_idx) != null) {
            cmdq.cmdq_error(item, "index in use: {d}", .{dst_idx});
            return .@"error";
        }

        const new_w = win.window_create(src_w.sx, src_w.sy, src_w.xpixel, src_w.ypixel);
        _ = win.window_detach_pane(src_w, src_wp);
        win.window_adopt_pane(new_w, src_wp);

        if (args.get('n')) |name| {
            win.window_set_name(new_w, name);
            opts.options_set_number(new_w.options, "automatic-rename", 0);
        } else {
            const default_name = names_mod.default_window_name(new_w);
            defer xm.allocator.free(default_name);
            win.window_set_name(new_w, default_name);
        }

        var cause: ?[]u8 = null;
        result_wl = sess.session_attach(dst_s, new_w, dst_idx, &cause) orelse {
            if (cause) |msg| {
                defer xm.allocator.free(msg);
                cmdq.cmdq_error(item, "{s}", .{msg});
            } else {
                cmdq.cmdq_error(item, "break-pane attach failed", .{});
            }
            win.window_adopt_pane(src_w, src_wp);
            win.window_remove_ref(new_w, "cmd_break_pane attach failed");
            return .@"error";
        };

        if (!args.has('d')) dst_s.curw = result_wl;
        server_fn.server_redraw_session(src_s);
        if (src_s != dst_s) server_fn.server_redraw_session(dst_s);
        server_fn.server_status_window(src_w);
        server_fn.server_status_window(new_w);
    }

    if (args.has('P')) {
        const template = args.get('F') orelse BREAK_PANE_TEMPLATE;
        const rendered = render_break_pane_location(item, template, dst_s, result_wl.?, result_wp) orelse return .@"error";
        defer xm.allocator.free(rendered);
        cmdq.cmdq_print(item, "{s}", .{rendered});
    }

    return .normal;
}

fn render_break_pane_location(item: *cmdq.CmdqItem, template: []const u8, s: *T.Session, wl: *T.Winlink, wp: *T.WindowPane) ?[]u8 {
    const state = T.CmdFindState{
        .s = s,
        .wl = wl,
        .w = wl.window,
        .wp = wp,
        .idx = wl.idx,
    };
    const ctx = cmd_format.target_context(&state, null);
    return cmd_format.require(item, template, &ctx);
}

fn find_result_winlink(dst_s: *T.Session, w: *T.Window, explicit_idx: i32, exclude_idx: i32) ?*T.Winlink {
    if (explicit_idx != -1) return sess.winlink_find_by_index(&dst_s.windows, explicit_idx);
    if (dst_s.curw) |wl| {
        if (wl.window == w and wl.idx != exclude_idx) return wl;
    }

    var match: ?*T.Winlink = null;
    var it = dst_s.windows.valueIterator();
    while (it.next()) |wl| {
        if (wl.window != w or wl.idx == exclude_idx) continue;
        if (match == null or wl.idx < match.?.idx) match = wl;
    }
    return match;
}

pub const entry: cmd_mod.CmdEntry = .{
    .name = "break-pane",
    .alias = "breakp",
    .usage = "[-dP] [-F format] [-n window-name] [-s src-pane] [-t dst-window]",
    .template = "abdPF:n:s:t:",
    .lower = 0,
    .upper = 0,
    .flags = 0,
    .exec = exec,
};

test "break-pane moves a pane into a new window when source has multiple panes" {
    const env_mod = @import("environ.zig");
    const spawn = @import("spawn.zig");

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

    const s = sess.session_create(null, "break-split", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("break-split") != null) sess.session_destroy(s, false, "test");

    var cause: ?[]u8 = null;
    var first_ctx: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const wl = spawn.spawn_window(&first_ctx, &cause).?;
    var second_ctx: T.SpawnContext = .{ .s = s, .wl = wl, .flags = T.SPAWN_EMPTY };
    const second = spawn.spawn_pane(&second_ctx, &cause).?;
    s.curw = wl;

    const target = xm.xasprintf("%{d}", .{second.id});
    defer xm.allocator.free(target);

    var parse_cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "break-pane", "-s", target, "-t", "break-split:3" }, null, &parse_cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));

    try std.testing.expectEqual(@as(usize, 1), wl.window.panes.items.len);
    const broken = sess.winlink_find_by_index(&s.windows, 3).?;
    try std.testing.expectEqual(@as(usize, 1), broken.window.panes.items.len);
    try std.testing.expectEqual(second, broken.window.active.?);
    try std.testing.expectEqual(broken.window, second.window);
    try std.testing.expectEqual(broken.window.options, second.options.parent.?);
}

test "break-pane moves a single-pane window to another session and can rename it" {
    const env_mod = @import("environ.zig");
    const spawn = @import("spawn.zig");

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

    const src = sess.session_create(null, "break-src", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("break-src") != null) sess.session_destroy(src, false, "test");
    const dst = sess.session_create(null, "break-dst", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("break-dst") != null) sess.session_destroy(dst, false, "test");

    var cause: ?[]u8 = null;
    var first_ctx: T.SpawnContext = .{ .s = src, .idx = -1, .flags = T.SPAWN_EMPTY };
    const wl = spawn.spawn_window(&first_ctx, &cause).?;
    const source_window = wl.window;
    src.curw = wl;

    const pane_target = xm.xasprintf("%{d}", .{wl.window.active.?.id});
    defer xm.allocator.free(pane_target);

    var parse_cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "break-pane", "-s", pane_target, "-t", "break-dst:2", "-n", "moved" }, null, &parse_cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));

    try std.testing.expect(sess.session_find("break-src") == null);
    const moved = sess.winlink_find_by_index(&dst.windows, 2).?;
    try std.testing.expectEqual(source_window, moved.window);
    try std.testing.expectEqualStrings("moved", moved.window.name);
    try std.testing.expectEqual(@as(i64, 0), opts.options_get_number(moved.window.options, "automatic-rename"));
}

test "break-pane location rendering uses session window and pane indexes" {
    const env_mod = @import("environ.zig");
    const spawn = @import("spawn.zig");

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

    const s = sess.session_create(null, "break-print", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("break-print") != null) sess.session_destroy(s, false, "test");

    var cause: ?[]u8 = null;
    var sc: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const wl = spawn.spawn_window(&sc, &cause).?;
    var second_ctx: T.SpawnContext = .{ .s = s, .wl = wl, .flags = T.SPAWN_EMPTY };
    const second = spawn.spawn_pane(&second_ctx, &cause).?;

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    const rendered = render_break_pane_location(&item, BREAK_PANE_TEMPLATE, s, wl, second).?;
    defer xm.allocator.free(rendered);
    try std.testing.expectEqualStrings("break-print:0.1", rendered);
}

test "break-pane rejects unsupported shuffle flags" {
    var parse_cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "break-pane", "-a" }, null, &parse_cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.@"error", cmd_mod.cmd_execute(cmd, &item));
}
