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
// Ported in part from tmux/cmd-move-window.c.
// Original copyright:
//   Copyright (c) 2008 Nicholas Marriott <nicholas.marriott@gmail.com>
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
    if (args.has('a')) {
        cmdq.cmdq_error(item, "-a not supported yet", .{});
        return .@"error";
    }
    if (args.has('b')) {
        cmdq.cmdq_error(item, "-b not supported yet", .{});
        return .@"error";
    }

    if (cmd.entry == &entry_move and args.has('r')) {
        var target_session: T.CmdFindState = .{};
        if (cmd_find.cmd_find_target(&target_session, item, args.get('t'), .session, 0) != 0)
            return .@"error";
        const s = target_session.s orelse return .@"error";
        sess.session_renumber_windows(s);
        server_fn.server_status_session(s);
        return .normal;
    }

    var source: T.CmdFindState = .{};
    if (cmd_find.cmd_find_target(&source, item, args.get('s'), .window, 0) != 0)
        return .@"error";
    const src_s = source.s orelse return .@"error";
    const src_wl = source.wl orelse return .@"error";
    const src_idx = src_wl.idx;

    var target: T.CmdFindState = .{};
    if (cmd_find.cmd_find_target(&target, item, args.get('t'), .window, T.CMD_FIND_WINDOW_INDEX) != 0)
        return .@"error";
    const dst_s = target.s orelse return .@"error";

    var cause: ?[]u8 = null;
    defer if (cause) |msg| xm.allocator.free(msg);
    if (server_fn.server_link_window(src_s, src_wl, dst_s, target.idx, args.has('k'), !args.has('d'), &cause) != 0) {
        cmdq.cmdq_error(item, "{s}", .{cause orelse "link window failed"});
        return .@"error";
    }

    if (cmd.entry == &entry_move) {
        const original = sess.winlink_find_by_index(&src_s.windows, src_idx) orelse return .normal;
        server_fn.server_unlink_window(src_s, original);
    }
    return .normal;
}

pub const entry_move: cmd_mod.CmdEntry = .{
    .name = "move-window",
    .alias = "movew",
    .usage = "[-dkr] [-s source-window] [-t target-window]",
    .template = "abdkrs:t:",
    .lower = 0,
    .upper = 0,
    .flags = 0,
    .exec = exec,
};

pub const entry_link: cmd_mod.CmdEntry = .{
    .name = "link-window",
    .alias = "linkw",
    .usage = "[-dk] [-s source-window] [-t target-window]",
    .template = "abdks:t:",
    .lower = 0,
    .upper = 0,
    .flags = 0,
    .exec = exec,
};

test "link-window and move-window support destination indexes and renumbering" {
    const opts = @import("options.zig");
    const env_mod = @import("environ.zig");
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

    const src = sess.session_create(null, "src-link", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("src-link") != null) sess.session_destroy(src, false, "test");
    const dst = sess.session_create(null, "dst-link", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("dst-link") != null) sess.session_destroy(dst, false, "test");

    var cause: ?[]u8 = null;
    var src_a: T.SpawnContext = .{ .s = src, .idx = -1, .flags = T.SPAWN_EMPTY };
    _ = spawn.spawn_window(&src_a, &cause).?;
    var src_b: T.SpawnContext = .{ .s = src, .idx = -1, .flags = T.SPAWN_EMPTY };
    _ = spawn.spawn_window(&src_b, &cause).?;
    var dst_a: T.SpawnContext = .{ .s = dst, .idx = -1, .flags = T.SPAWN_EMPTY };
    _ = spawn.spawn_window(&dst_a, &cause).?;

    var parse_cause: ?[]u8 = null;
    const link_cmd = try cmd_mod.cmd_parse_one(&.{ "link-window", "-s", "src-link:0", "-t", "dst-link:3" }, null, &parse_cause);
    defer cmd_mod.cmd_free(link_cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(link_cmd, &item));
    try std.testing.expect(sess.winlink_find_by_index(&dst.windows, 3) != null);

    const move_cmd = try cmd_mod.cmd_parse_one(&.{ "move-window", "-s", "src-link:1", "-t", "dst-link:4" }, null, &parse_cause);
    defer cmd_mod.cmd_free(move_cmd);
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(move_cmd, &item));
    try std.testing.expect(sess.winlink_find_by_index(&src.windows, 1) == null);
    try std.testing.expect(sess.winlink_find_by_index(&dst.windows, 4) != null);

    const renumber_cmd = try cmd_mod.cmd_parse_one(&.{ "move-window", "-r", "-t", "dst-link" }, null, &parse_cause);
    defer cmd_mod.cmd_free(renumber_cmd);
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(renumber_cmd, &item));
    try std.testing.expect(sess.winlink_find_by_index(&dst.windows, 0) != null);
    try std.testing.expect(sess.winlink_find_by_index(&dst.windows, 1) != null);
    try std.testing.expect(sess.winlink_find_by_index(&dst.windows, 2) != null);
}
