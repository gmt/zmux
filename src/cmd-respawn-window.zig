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
// Ported in part from tmux/cmd-respawn-window.c.
// Original copyright:
//   Copyright (c) 2008 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const cmd_mod = @import("cmd.zig");
const cmdq = @import("cmd-queue.zig");
const cmd_find = @import("cmd-find.zig");
const env_mod = @import("environ.zig");
const respawn_pane = @import("cmd-respawn-pane.zig");
const spawn_mod = @import("spawn.zig");
const server_fn = @import("server-fn.zig");

fn exec(cmd: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {
    const args = cmd_mod.cmd_get_args(cmd);
    var target: T.CmdFindState = .{};
    if (cmd_find.cmd_find_target(&target, item, args.get('t'), .window, 0) != 0)
        return .@"error";
    const s = target.s orelse return .@"error";
    const wl = target.wl orelse return .@"error";
    const w = target.w orelse return .@"error";

    const overlay = respawn_pane.build_overlay_environment(args, item) catch return .@"error";
    defer if (overlay) |env| env_mod.environ_free(env);

    const argv = respawn_pane.argv_tail(args, 0);
    defer if (argv) |slice| respawn_pane.free_argv(slice);

    var sc = T.SpawnContext{
        .item = @ptrCast(item),
        .s = s,
        .wl = wl,
        .argv = argv,
        .environ = overlay,
        .cwd = args.get('c'),
        .flags = T.SPAWN_RESPAWN,
    };
    if (args.has('k')) sc.flags |= T.SPAWN_KILL;

    var cause: ?[]u8 = null;
    defer if (cause) |msg| xm.allocator.free(msg);
    _ = spawn_mod.spawn_window(&sc, &cause) orelse {
        cmdq.cmdq_error(item, "respawn window failed: {s}", .{cause orelse "unknown"});
        return .@"error";
    };

    server_fn.server_redraw_session(s);
    server_fn.server_status_window(w);
    return .normal;
}

pub const entry: cmd_mod.CmdEntry = .{
    .name = "respawn-window",
    .alias = "respawnw",
    .usage = "[-k] [-c start-directory] [-e environment] [-t target-window] [shell-command [argument ...]]",
    .template = "c:e:kt:",
    .lower = 0,
    .upper = -1,
    .flags = 0,
    .exec = exec,
};

test "respawn-window collapses a multi-pane window onto the first pane" {
    const opts = @import("options.zig");
    const sess = @import("session.zig");
    const spawn = @import("spawn.zig");
    const win = @import("window.zig");

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

    const s = sess.session_create(null, "respawn-window-multi", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("respawn-window-multi") != null) sess.session_destroy(s, false, "test");

    var cause: ?[]u8 = null;
    var first: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const wl = spawn.spawn_window(&first, &cause).?;
    const pane_id = wl.window.panes.items[0].id;
    var second: T.SpawnContext = .{ .s = s, .wl = wl, .flags = T.SPAWN_EMPTY };
    _ = spawn.spawn_pane(&second, &cause).?;

    var parse_cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "respawn-window", "-t", "respawn-window-multi:0", "printf nope" }, null, &parse_cause);
    defer cmd_mod.cmd_free(cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));

    std.Thread.sleep(500 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(usize, 1), wl.window.panes.items.len);
    try std.testing.expectEqual(pane_id, wl.window.active.?.id);
    const output = respawn_pane.read_pane_output(wl.window.active.?);
    defer xm.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "nope") != null);
}

test "respawn-window restarts the only pane in a window" {
    const opts = @import("options.zig");
    const sess = @import("session.zig");
    const spawn = @import("spawn.zig");
    const win = @import("window.zig");

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

    const s = sess.session_create(null, "respawn-window-one", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("respawn-window-one") != null) sess.session_destroy(s, false, "test");

    var cause: ?[]u8 = null;
    var sc: T.SpawnContext = .{ .s = s, .idx = -1 };
    const wl = spawn.spawn_window(&sc, &cause).?;
    const pane_id = wl.window.active.?.id;

    var parse_cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "respawn-window", "-k", "-t", "respawn-window-one:0", "printf winhi" }, null, &parse_cause);
    defer cmd_mod.cmd_free(cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));

    std.Thread.sleep(500 * std.time.ns_per_ms);
    try std.testing.expectEqual(pane_id, wl.window.active.?.id);
    const output = respawn_pane.read_pane_output(wl.window.active.?);
    defer xm.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "winhi") != null);
}
