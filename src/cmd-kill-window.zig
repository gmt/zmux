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
// Ported in part from tmux/cmd-kill-window.c.
// Original copyright:
//   Copyright (c) 2007 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const cmd_mod = @import("cmd.zig");
const cmdq = @import("cmd-queue.zig");
const cmd_find = @import("cmd-find.zig");
const sess = @import("session.zig");
const server_fn = @import("server-fn.zig");

fn exec(cmd: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {
    const args = cmd_mod.cmd_get_args(cmd);
    var target: T.CmdFindState = .{};
    if (cmd_find.cmd_find_target(&target, item, args.get('t'), .window, 0) != 0)
        return .@"error";

    const s = target.s orelse return .@"error";
    const wl = target.wl orelse return .@"error";

    if (args.has('a')) {
        var other_windows: std.ArrayList(*T.Window) = .{};
        defer other_windows.deinit(xm.allocator);
        var duplicate_links: std.ArrayList(i32) = .{};
        defer duplicate_links.deinit(xm.allocator);

        var it = s.windows.valueIterator();
        while (it.next()) |current| {
            if (current.*.idx == wl.idx) continue;
            if (current.*.window == wl.window) {
                duplicate_links.append(xm.allocator, current.*.idx) catch unreachable;
                continue;
            }
            if (!contains_window(other_windows.items, current.*.window))
                other_windows.append(xm.allocator, current.*.window) catch unreachable;
        }

        for (duplicate_links.items) |idx| {
            _ = sess.session_detach_index(s, idx, "cmd_kill_window -a");
        }
        for (other_windows.items) |other| {
            server_fn.server_kill_window(other, false);
        }
        return .normal;
    }

    server_fn.server_kill_window(wl.window, true);
    return .normal;
}

fn contains_window(items: []const *T.Window, needle: *T.Window) bool {
    for (items) |item| {
        if (item == needle) return true;
    }
    return false;
}

pub const entry: cmd_mod.CmdEntry = .{
    .name = "kill-window",
    .alias = "killw",
    .usage = "[-a] [-t target-window]",
    .template = "at:",
    .lower = 0,
    .upper = 0,
    .flags = 0,
    .exec = exec,
};

test "kill-window removes the targeted window" {
    const opts = @import("options.zig");
    const env_mod = @import("environ.zig");
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

    const s = sess.session_create(null, "kill-window-test", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("kill-window-test") != null) sess.session_destroy(s, false, "test");

    var cause: ?[]u8 = null;
    var first_ctx: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const first = @import("spawn.zig").spawn_window(&first_ctx, &cause).?;
    var second_ctx: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const second = @import("spawn.zig").spawn_window(&second_ctx, &cause).?;
    s.curw = first;

    var parse_cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "kill-window", "-t", "kill-window-test:1" }, null, &parse_cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));
    try std.testing.expectEqual(@as(usize, 1), s.windows.count());
    try std.testing.expectEqual(first, s.curw.?);
    try std.testing.expect(sess.winlink_find_by_index(&s.windows, second.idx) == null);
}

test "kill-window destroys session when last window is removed" {
    const opts = @import("options.zig");
    const env_mod = @import("environ.zig");
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

    const s = sess.session_create(null, "kill-last-window-test", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    var cause: ?[]u8 = null;
    var first_ctx: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    _ = @import("spawn.zig").spawn_window(&first_ctx, &cause).?;

    var parse_cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "kill-window", "-t", "kill-last-window-test:0" }, null, &parse_cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));
    try std.testing.expect(sess.session_find("kill-last-window-test") == null);
}
