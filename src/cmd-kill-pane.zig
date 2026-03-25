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
// Ported in part from tmux/cmd-kill-pane.c.
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

fn exec(cmd: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {
    const args = cmd_mod.cmd_get_args(cmd);
    var target: T.CmdFindState = .{};
    if (cmd_find.cmd_find_target(&target, item, args.get('t'), .pane, 0) != 0)
        return .@"error";

    const wp = target.wp orelse return .@"error";
    if (args.has('a')) {
        const w = wp.window;
        const panes = xm.allocator.alloc(*T.WindowPane, w.panes.items.len) catch unreachable;
        defer xm.allocator.free(panes);
        @memcpy(panes, w.panes.items);

        for (panes) |other| {
            if (other == wp) continue;
            server_fn.server_destroy_pane(other, false);
        }
        return .normal;
    }

    server_fn.server_destroy_pane(wp, true);
    return .normal;
}

pub const entry: cmd_mod.CmdEntry = .{
    .name = "kill-pane",
    .alias = "killp",
    .usage = "[-a] [-t target-pane]",
    .template = "at:",
    .lower = 0,
    .upper = 0,
    .flags = T.CMD_AFTERHOOK,
    .exec = exec,
};

test "kill-pane removes a non-last pane and kill-pane -a leaves target pane" {
    const opts = @import("options.zig");
    const env_mod = @import("environ.zig");
    const sess = @import("session.zig");
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

    const s = sess.session_create(null, "kill-pane-test", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("kill-pane-test") != null) sess.session_destroy(s, false, "test");

    var cause: ?[]u8 = null;
    var first_ctx: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const wl = @import("spawn.zig").spawn_window(&first_ctx, &cause).?;
    var second_ctx: T.SpawnContext = .{ .s = s, .wl = wl, .flags = T.SPAWN_EMPTY };
    const second = @import("spawn.zig").spawn_pane(&second_ctx, &cause).?;
    var third_ctx: T.SpawnContext = .{ .s = s, .wl = wl, .flags = T.SPAWN_EMPTY };
    const third = @import("spawn.zig").spawn_pane(&third_ctx, &cause).?;
    _ = third;
    wl.window.active = second;
    s.curw = wl;

    const target_second = xm.xasprintf("%{d}", .{second.id});
    defer xm.allocator.free(target_second);
    var parse_cause: ?[]u8 = null;
    const kill_one = try cmd_mod.cmd_parse_one(&.{ "kill-pane", "-t", target_second }, null, &parse_cause);
    defer cmd_mod.cmd_free(kill_one);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(kill_one, &item));
    try std.testing.expectEqual(@as(usize, 2), wl.window.panes.items.len);

    const survivor = wl.window.panes.items[0];
    const target_survivor = xm.xasprintf("%{d}", .{survivor.id});
    defer xm.allocator.free(target_survivor);
    const kill_rest = try cmd_mod.cmd_parse_one(&.{ "kill-pane", "-a", "-t", target_survivor }, null, &parse_cause);
    defer cmd_mod.cmd_free(kill_rest);
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(kill_rest, &item));
    try std.testing.expectEqual(@as(usize, 1), wl.window.panes.items.len);
    try std.testing.expectEqual(survivor, wl.window.panes.items[0]);
}
