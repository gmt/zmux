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
// Ported in part from tmux/cmd-rename-session.c.
// Original copyright:
//   Copyright (c) 2007 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const cmd_mod = @import("cmd.zig");
const cmdq = @import("cmd-queue.zig");
const cmd_find = @import("cmd-find.zig");
const format_mod = @import("format.zig");
const sess = @import("session.zig");
const server_fn = @import("server-fn.zig");
const notify = @import("notify.zig");

fn exec(cmd: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {
    const args = cmd_mod.cmd_get_args(cmd);
    var target: T.CmdFindState = .{};
    if (cmd_find.cmd_find_target(&target, item, args.get('t'), .session, 0) != 0)
        return .@"error";

    const s = target.s orelse return .@"error";
    const raw_name = args.value_at(0) orelse {
        cmdq.cmdq_error(item, "new name required", .{});
        return .@"error";
    };
    const ctx = format_mod.FormatContext{
        .item = @ptrCast(item),
        .client = cmdq.cmdq_get_client(item),
        .session = target.s,
        .winlink = target.wl,
        .window = target.w,
        .pane = target.wp,
    };
    const expanded = format_mod.format_require(xm.allocator, raw_name, &ctx) catch {
        cmdq.cmdq_error(item, "format expansion not supported yet", .{});
        return .@"error";
    };
    defer xm.allocator.free(expanded);

    const new_name = sess.session_check_name(expanded) orelse {
        cmdq.cmdq_error(item, "invalid session: {s}", .{expanded});
        return .@"error";
    };
    errdefer xm.allocator.free(new_name);

    if (std.mem.eql(u8, new_name, s.name)) {
        xm.allocator.free(new_name);
        return .normal;
    }
    if (sess.session_find(new_name) != null) {
        cmdq.cmdq_error(item, "duplicate session: {s}", .{new_name});
        return .@"error";
    }

    const old_name = s.name;
    _ = sess.sessions.remove(old_name);
    s.name = new_name;
    sess.sessions.put(s.name, s) catch unreachable;
    xm.allocator.free(old_name);

    server_fn.server_status_session(s);
    notify.notify_session("session-renamed", s);
    return .normal;
}

pub const entry: cmd_mod.CmdEntry = .{
    .name = "rename-session",
    .alias = "rename",
    .usage = "[-t target-session] new-name",
    .template = "t:",
    .lower = 1,
    .upper = 1,
    .flags = T.CMD_STARTSERVER | T.CMD_AFTERHOOK,
    .exec = exec,
};

test "rename-session renames target session and rejects duplicates" {
    const env_mod = @import("environ.zig");
    const opts = @import("options.zig");

    sess.session_init_globals(xm.allocator);

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

    const s1 = sess.session_create(null, "alpha", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer sess.session_destroy(s1, false, "test");
    const s2 = sess.session_create(null, "beta", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer sess.session_destroy(s2, false, "test");

    var cause: ?[]u8 = null;
    const rename_ok = try cmd_mod.cmd_parse_one(&.{ "rename-session", "-t", "alpha", "gamma" }, null, &cause);
    defer cmd_mod.cmd_free(rename_ok);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(rename_ok, &item));
    try std.testing.expectEqualStrings("gamma", s1.name);
    try std.testing.expect(sess.session_find("alpha") == null);
    try std.testing.expectEqual(s1, sess.session_find("gamma").?);

    const rename_dup = try cmd_mod.cmd_parse_one(&.{ "rename-session", "-t", "gamma", "beta" }, null, &cause);
    defer cmd_mod.cmd_free(rename_dup);
    try std.testing.expectEqual(T.CmdRetval.@"error", cmd_mod.cmd_execute(rename_dup, &item));
    try std.testing.expectEqualStrings("gamma", s1.name);
}
