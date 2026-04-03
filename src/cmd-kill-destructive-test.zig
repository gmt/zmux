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

//! Execution tests for kill-session and kill-server.

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const cmd_mod = @import("cmd.zig");
const cmdq = @import("cmd-queue.zig");
const cmd_kill_session = @import("cmd-kill-session.zig");
const cmd_kill_server = @import("cmd-kill-server.zig");
const sess = @import("session.zig");
const win_mod = @import("window.zig");
const opts = @import("options.zig");
const env_mod = @import("environ.zig");
const client_registry = @import("client-registry.zig");
const tty_mod = @import("tty.zig");
const srv = @import("server.zig");
const cfg_mod = @import("cfg.zig");

fn attach_placeholder_window(s: *T.Session) void {
    const w = win_mod.window_create(80, 24, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    _ = win_mod.window_add_pane(w, null, 80, 24);
    var cause: ?[]u8 = null;
    const wl = sess.session_attach(s, w, -1, &cause).?;
    s.curw = wl;
}

fn init_harness() void {
    cfg_mod.cfg_reset_files();
    cmdq.cmdq_reset_for_tests();
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

fn deinit_harness() void {
    env_mod.environ_free(env_mod.global_environ);
    opts.options_free(opts.global_w_options);
    opts.options_free(opts.global_s_options);
    opts.options_free(opts.global_options);
    cmdq.cmdq_reset_for_tests();
    cfg_mod.cfg_reset_files();
}

test "kill-server command marks exit and tears down sessions and clients" {
    init_harness();
    defer deinit_harness();

    client_registry.clients.clearRetainingCapacity();
    defer client_registry.clients.clearRetainingCapacity();

    const old_server_exit = srv.server_exit;
    defer srv.server_exit = old_server_exit;
    srv.server_exit = false;

    const shutdown_session = sess.session_create(null, "kill-server-cmd", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    attach_placeholder_window(shutdown_session);

    var client = T.Client{
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{},
        .flags = T.CLIENT_ATTACHED,
        .session = shutdown_session,
    };
    defer env_mod.environ_free(client.environ);
    client.tty = .{ .client = &client };
    client_registry.add(&client);

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{"kill-server"}, null, &cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .cmdlist = &list };

    try std.testing.expectEqual(cmd_kill_server.entry.exec, cmd_mod.cmd_get_entry(cmd).exec);
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));

    try std.testing.expect(srv.server_exit);
    try std.testing.expect(client.flags & T.CLIENT_EXIT != 0);
    try std.testing.expectEqual(T.ClientExitReason.server_exited, client.exit_reason);
    try std.testing.expect(client.session == null);
    try std.testing.expect(sess.session_find("kill-server-cmd") == null);

    client_registry.clients.clearRetainingCapacity();
    srv.server_exit = false;
}

test "kill-session -t destroys the named session" {
    init_harness();
    defer deinit_harness();

    const session = sess.session_create(null, "kill-session-one", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("kill-session-one") != null) sess.session_destroy(session, false, "test");
    attach_placeholder_window(session);

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "kill-session", "-t", "kill-session-one" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .cmdlist = &list };

    try std.testing.expectEqual(cmd_kill_session.entry.exec, cmd_mod.cmd_get_entry(cmd).exec);
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));
    try std.testing.expect(sess.session_find("kill-session-one") == null);
}

test "kill-session -a -t keeps target session and destroys others" {
    init_harness();
    defer deinit_harness();

    const keeper = sess.session_create(null, "kill-a-keeper", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("kill-a-keeper") != null) sess.session_destroy(keeper, false, "test");
    const victim = sess.session_create(null, "kill-a-victim", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("kill-a-victim") != null) sess.session_destroy(victim, false, "test");
    attach_placeholder_window(keeper);
    attach_placeholder_window(victim);

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "kill-session", "-a", "-t", "kill-a-keeper" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .cmdlist = &list };

    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));
    try std.testing.expect(sess.session_find("kill-a-victim") == null);
    try std.testing.expect(sess.session_find("kill-a-keeper") != null);
}

test "kill-session -C -t clears alerts and redraws attached clients" {
    init_harness();
    defer deinit_harness();

    client_registry.clients.clearRetainingCapacity();
    defer client_registry.clients.clearRetainingCapacity();

    const s = sess.session_create(null, "kill-c-alerts", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("kill-c-alerts") != null) sess.session_destroy(s, false, "test");

    attach_placeholder_window(s);
    const wl = s.curw.?;
    const w = wl.window;

    w.flags = T.WINDOW_ALERTFLAGS;
    wl.flags = T.WINLINK_ALERTFLAGS;
    s.flags = T.SESSION_ALERTED;

    var client = T.Client{
        .name = "kill-c-client",
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{},
        .flags = T.CLIENT_ATTACHED,
        .session = s,
    };
    defer env_mod.environ_free(client.environ);
    tty_mod.tty_init(&client.tty, &client);
    client_registry.add(&client);

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "kill-session", "-C", "-t", "kill-c-alerts" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .cmdlist = &list };

    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));

    try std.testing.expectEqual(@as(u32, 0), w.flags & T.WINDOW_ALERTFLAGS);
    try std.testing.expectEqual(@as(u32, 0), wl.flags & T.WINLINK_ALERTFLAGS);
    try std.testing.expectEqual(@as(u32, 0), s.flags & T.SESSION_ALERTED);
    try std.testing.expect(sess.session_find("kill-c-alerts") != null);
    try std.testing.expect(client.flags & T.CLIENT_REDRAW != 0);
}
