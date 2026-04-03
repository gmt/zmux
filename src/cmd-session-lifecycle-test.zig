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

//! Behavioral tests for thin command wrappers and session startup entrypoints.

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const cmd_mod = @import("cmd.zig");
const cmdq = @import("cmd-queue.zig");
const cmd_start_server = @import("cmd-start-server.zig");
const cmd_new_window = @import("cmd-new-window.zig");
const cmd_list_clients = @import("cmd-list-clients.zig");
const cmd_list_sessions = @import("cmd-list-sessions.zig");
const sess = @import("session.zig");
const win_mod = @import("window.zig");
const opts = @import("options.zig");
const env_mod = @import("environ.zig");
const spawn = @import("spawn.zig");
const client_registry = @import("client-registry.zig");
const tty_mod = @import("tty.zig");

fn init_harness() void {
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
}

test "start-server command entry returns normal" {
    init_harness();
    defer deinit_harness();

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "start-server" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .cmdlist = &list };

    try std.testing.expectEqual(T.CmdRetval.normal, cmd_start_server.entry.exec(cmd, &item));
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));
}

test "new-window command entry delegates to select-window neww and creates a detached window" {
    init_harness();
    defer deinit_harness();

    client_registry.clients.clearRetainingCapacity();
    defer client_registry.clients.clearRetainingCapacity();

    const session = sess.session_create(null, "lifecycle-neww", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("lifecycle-neww") != null) sess.session_destroy(session, false, "test");

    var cause: ?[]u8 = null;
    var first_sc: T.SpawnContext = .{ .s = session, .idx = -1, .flags = T.SPAWN_EMPTY };
    _ = spawn.spawn_window(&first_sc, &cause).?;
    session.curw = session.windows.get(0).?;

    var client = T.Client{
        .name = "lifecycle-neww-client",
        .environ = env_mod.environ_create(),
        .tty = .{ .client = undefined },
        .status = .{},
        .flags = T.CLIENT_ATTACHED,
        .session = session,
    };
    defer env_mod.environ_free(client.environ);
    tty_mod.tty_init(&client.tty, &client);
    client_registry.add(&client);

    const cmd = try cmd_mod.cmd_parse_one(&.{ "new-window", "-d" }, &client, &cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &client, .target_client = &client, .cmdlist = &list };

    try std.testing.expectEqual(cmd_new_window.entry.exec, cmd_mod.cmd_get_entry(cmd).exec);
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));
    try std.testing.expectEqual(@as(usize, 2), session.windows.count());
}

test "list-clients command entry rejects invalid sort order" {
    init_harness();
    defer deinit_harness();

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "list-clients", "-O", "not-a-valid-order" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .cmdlist = &list };

    try std.testing.expectEqual(cmd_list_clients.entry.exec, cmd_mod.cmd_get_entry(cmd).exec);
    try std.testing.expectEqual(T.CmdRetval.@"error", cmd_mod.cmd_execute(cmd, &item));
}

test "list-clients command entry succeeds with no registered clients" {
    init_harness();
    defer deinit_harness();

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "list-clients" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .cmdlist = &list };

    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));
}

test "list-sessions command entry succeeds with no sessions" {
    init_harness();
    defer deinit_harness();

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "list-sessions" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .cmdlist = &list };

    try std.testing.expectEqual(cmd_list_sessions.entry.exec, cmd_mod.cmd_get_entry(cmd).exec);
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));
}

test "list-sessions with format flag executes" {
    init_harness();
    defer deinit_harness();

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "list-sessions", "-F", "#{session_name}" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .cmdlist = &list };

    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));
}
