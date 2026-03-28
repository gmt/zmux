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
// Ported in part from tmux/cmd-rotate-window.c.
// Original copyright:
//   Copyright (c) 2009 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const cmd_mod = @import("cmd.zig");
const cmdq = @import("cmd-queue.zig");
const cmd_find = @import("cmd-find.zig");
const server_fn = @import("server-fn.zig");
const win = @import("window.zig");

fn exec(cmd: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {
    const args = cmd_mod.cmd_get_args(cmd);

    var target: T.CmdFindState = .{};
    if (cmd_find.cmd_find_target(&target, item, args.get('t'), .window, 0) != 0)
        return .@"error";
    const s = target.s orelse return .@"error";
    const wl = target.wl orelse return .@"error";
    const w = wl.window;

    const reverse = args.has('D');
    _ = win.window_push_zoom(w, false, args.has('Z'));
    defer _ = win.window_pop_zoom(w);

    const active = win.window_rotate_panes(w, reverse) orelse return .normal;
    s.curw = wl;
    target.wp = active;
    item.state.current = target;

    server_fn.server_redraw_session(s);
    server_fn.server_status_window(w);
    return .normal;
}

pub const entry: cmd_mod.CmdEntry = .{
    .name = "rotate-window",
    .alias = "rotatew",
    .usage = "[-DU] [-t target-window]",
    .template = "Dt:UZ",
    .lower = 0,
    .upper = 0,
    .flags = 0,
    .exec = exec,
};

test "rotate-window rotates pane order in both directions" {
    const opts = @import("options.zig");
    const env_mod = @import("environ.zig");
    const sess = @import("session.zig");
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

    const s = sess.session_create(null, "rotate-window-test", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("rotate-window-test") != null) sess.session_destroy(s, false, "test");

    var cause: ?[]u8 = null;
    var first_ctx: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const wl = spawn.spawn_window(&first_ctx, &cause).?;
    const first = wl.window.active.?;
    var second_ctx: T.SpawnContext = .{ .s = s, .wl = wl, .flags = T.SPAWN_EMPTY };
    const second = spawn.spawn_pane(&second_ctx, &cause).?;
    var third_ctx: T.SpawnContext = .{ .s = s, .wl = wl, .flags = T.SPAWN_EMPTY };
    const third = spawn.spawn_pane(&third_ctx, &cause).?;
    _ = win.window_set_active_pane(wl.window, second, true);
    s.curw = wl;

    var parse_cause: ?[]u8 = null;
    const rotate_up = try cmd_mod.cmd_parse_one(&.{ "rotate-window", "-t", "rotate-window-test:0" }, null, &parse_cause);
    defer cmd_mod.cmd_free(rotate_up);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(rotate_up, &item));
    try std.testing.expectEqual(second, wl.window.panes.items[0]);
    try std.testing.expectEqual(third, wl.window.active.?);

    const rotate_down = try cmd_mod.cmd_parse_one(&.{ "rotate-window", "-D", "-t", "rotate-window-test:0" }, null, &parse_cause);
    defer cmd_mod.cmd_free(rotate_down);
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(rotate_down, &item));
    try std.testing.expectEqual(first, wl.window.panes.items[0]);
    try std.testing.expectEqual(second, wl.window.active.?);
}

test "rotate-window -Z preserves the reduced zoom flag while rotating" {
    const opts = @import("options.zig");
    const env_mod = @import("environ.zig");
    const sess = @import("session.zig");
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

    const s = sess.session_create(null, "rotate-window-zoom", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("rotate-window-zoom") != null) sess.session_destroy(s, false, "test");

    var cause: ?[]u8 = null;
    var first_ctx: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const wl = spawn.spawn_window(&first_ctx, &cause).?;
    var second_ctx: T.SpawnContext = .{ .s = s, .wl = wl, .flags = T.SPAWN_EMPTY };
    const second = spawn.spawn_pane(&second_ctx, &cause).?;
    var third_ctx: T.SpawnContext = .{ .s = s, .wl = wl, .flags = T.SPAWN_EMPTY };
    const third = spawn.spawn_pane(&third_ctx, &cause).?;
    _ = win.window_set_active_pane(wl.window, second, true);
    s.curw = wl;

    wl.window.flags |= T.WINDOW_ZOOMED;

    var parse_cause: ?[]u8 = null;
    const rotate_cmd = try cmd_mod.cmd_parse_one(&.{ "rotate-window", "-Z", "-t", "rotate-window-zoom:0" }, null, &parse_cause);
    defer cmd_mod.cmd_free(rotate_cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(rotate_cmd, &item));
    try std.testing.expectEqual(second, wl.window.panes.items[0]);
    try std.testing.expectEqual(third, wl.window.active.?);
    try std.testing.expect(wl.window.flags & T.WINDOW_ZOOMED != 0);
    try std.testing.expect(wl.window.flags & T.WINDOW_WASZOOMED == 0);
    try std.testing.expectEqual(third, item.state.current.wp.?);
}
