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

//! Behavioral and umbrella coverage for session/window command families.

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const cmd_mod = @import("cmd.zig");
const cmdq = @import("cmd-queue.zig");
const cmd_start_server = @import("cmd-start-server.zig");
const cmd_new_window = @import("cmd-new-window.zig");
const cmd_list_clients = @import("cmd-list-clients.zig");
const cmd_list_panes = @import("cmd-list-panes.zig");
const cmd_list_sessions = @import("cmd-list-sessions.zig");
const sess = @import("session.zig");
const win_mod = @import("window.zig");
const opts = @import("options.zig");
const env_mod = @import("environ.zig");
const spawn = @import("spawn.zig");
const client_registry = @import("client-registry.zig");
const tty_mod = @import("tty.zig");

fn parseName(argv: []const []const u8) ![]const u8 {
    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(argv, null, &cause);
    defer cmd_mod.cmd_free(cmd);
    return cmd.entry.name;
}

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

fn capture_stdout(argv: []const []const u8) ![]u8 {
    var stdout_pipe: [2]i32 = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.pipe(&stdout_pipe));
    defer {
        std.posix.close(stdout_pipe[0]);
        if (stdout_pipe[1] != -1) std.posix.close(stdout_pipe[1]);
    }

    const stdout_dup = try std.posix.dup(std.posix.STDOUT_FILENO);
    defer std.posix.close(stdout_dup);

    try std.posix.dup2(stdout_pipe[1], std.posix.STDOUT_FILENO);
    defer std.posix.dup2(stdout_dup, std.posix.STDOUT_FILENO) catch {};

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(argv, null, &cause);
    defer cmd_mod.cmd_free(cmd);
    defer if (cause) |msg| xm.allocator.free(msg);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));

    try std.posix.dup2(stdout_dup, std.posix.STDOUT_FILENO);
    std.posix.close(stdout_pipe[1]);
    stdout_pipe[1] = -1;

    var out: std.ArrayList(u8) = .{};
    errdefer out.deinit(xm.allocator);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = try std.posix.read(stdout_pipe[0], &buf);
        if (n == 0) break;
        try out.appendSlice(xm.allocator, buf[0..n]);
    }
    return out.toOwnedSlice(xm.allocator);
}

test {
    _ = @import("cmd-new-session.zig");
    _ = @import("cmd-kill-window.zig");
    _ = @import("cmd-select-window.zig");
    _ = @import("cmd-move-window.zig");
    _ = @import("cmd-swap-window.zig");
    _ = @import("cmd-resize-window.zig");
    _ = @import("cmd-resize-pane.zig");
    _ = @import("cmd-split-window.zig");
    _ = @import("cmd-join-pane.zig");
    _ = @import("cmd-break-pane.zig");
    _ = @import("cmd-respawn-pane.zig");
    _ = @import("cmd-respawn-window.zig");
    _ = @import("cmd-list-sessions.zig");
    _ = @import("cmd-list-panes.zig");
}

test "kill-window command parses target flag" {
    try std.testing.expectEqualStrings("kill-window", try parseName(&.{ "kill-window", "-t", "mysess:0" }));
}

test "move-window command parses session and window flags" {
    try std.testing.expectEqualStrings("move-window", try parseName(&.{ "move-window", "-s", "src:1", "-t", "dst:2" }));
}

test "kill-session command parses target flag" {
    try std.testing.expectEqualStrings("kill-session", try parseName(&.{ "kill-session", "-t", "foo" }));
}

test "new-window command parses shell flag" {
    try std.testing.expectEqualStrings("new-window", try parseName(&.{ "new-window", "-n", "win", "vi" }));
}

test "start-server command parses bare invocation" {
    try std.testing.expectEqualStrings("start-server", try parseName(&.{"start-server"}));
}

test "attach-session command parses target and cwd flags" {
    try std.testing.expectEqualStrings("attach-session", try parseName(&.{ "attach-session", "-t", "mysess", "-c", "/tmp" }));
}

test "list-clients command parses format flag" {
    try std.testing.expectEqualStrings("list-clients", try parseName(&.{ "list-clients", "-F", "#{client_name}" }));
}

test "select-window command parses target window" {
    try std.testing.expectEqualStrings("select-window", try parseName(&.{ "select-window", "-t", ":1" }));
}

test "next-window command parses session target" {
    try std.testing.expectEqualStrings("next-window", try parseName(&.{ "next-window", "-t", "foo" }));
}

test "list-sessions command parses format flag" {
    try std.testing.expectEqualStrings("list-sessions", try parseName(&.{ "list-sessions", "-F", "#{session_name}" }));
}

test "start-server command entry returns normal" {
    init_harness();
    defer deinit_harness();

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{"start-server"}, null, &cause);
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
    const cmd = try cmd_mod.cmd_parse_one(&.{"list-clients"}, null, &cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .cmdlist = &list };

    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));
}

test "list-clients sorts by name and scopes results to the target session" {
    init_harness();
    defer deinit_harness();

    client_registry.clients.clearRetainingCapacity();
    defer client_registry.clients.clearRetainingCapacity();

    const alpha = sess.session_create(null, "coverage-alpha", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("coverage-alpha") != null) sess.session_destroy(alpha, false, "test");
    const beta = sess.session_create(null, "coverage-beta", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("coverage-beta") != null) sess.session_destroy(beta, false, "test");

    var cause: ?[]u8 = null;
    var alpha_sc: T.SpawnContext = .{ .s = alpha, .idx = -1, .flags = T.SPAWN_EMPTY };
    alpha.curw = spawn.spawn_window(&alpha_sc, &cause).?;
    var beta_sc: T.SpawnContext = .{ .s = beta, .idx = -1, .flags = T.SPAWN_EMPTY };
    beta.curw = spawn.spawn_window(&beta_sc, &cause).?;

    var zed = T.Client{
        .name = "zed",
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{},
        .flags = T.CLIENT_ATTACHED,
        .session = alpha,
    };
    defer env_mod.environ_free(zed.environ);
    zed.tty = .{ .client = &zed, .sx = 90, .sy = 25 };

    var amy = T.Client{
        .name = "amy",
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{},
        .flags = T.CLIENT_ATTACHED,
        .session = alpha,
    };
    defer env_mod.environ_free(amy.environ);
    amy.tty = .{ .client = &amy, .sx = 120, .sy = 30 };

    var bob = T.Client{
        .name = "bob",
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{},
        .flags = T.CLIENT_ATTACHED,
        .session = beta,
    };
    defer env_mod.environ_free(bob.environ);
    bob.tty = .{ .client = &bob, .sx = 200, .sy = 40 };

    client_registry.add(&zed);
    client_registry.add(&amy);
    client_registry.add(&bob);

    const output = try capture_stdout(&.{ "list-clients", "-t", "coverage-alpha", "-O", "name", "-F", "#{client_name}:#{session_name}" });
    defer xm.allocator.free(output);

    try std.testing.expectEqualStrings(
        "amy:coverage-alpha\n" ++
            "zed:coverage-alpha\n",
        output,
    );
}

test "list-clients applies filters before printing and honors size ordering" {
    init_harness();
    defer deinit_harness();

    client_registry.clients.clearRetainingCapacity();
    defer client_registry.clients.clearRetainingCapacity();

    const alpha = sess.session_create(null, "coverage-filter-alpha", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("coverage-filter-alpha") != null) sess.session_destroy(alpha, false, "test");
    const beta = sess.session_create(null, "coverage-filter-beta", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("coverage-filter-beta") != null) sess.session_destroy(beta, false, "test");

    var cause: ?[]u8 = null;
    var alpha_sc: T.SpawnContext = .{ .s = alpha, .idx = -1, .flags = T.SPAWN_EMPTY };
    alpha.curw = spawn.spawn_window(&alpha_sc, &cause).?;
    var beta_sc: T.SpawnContext = .{ .s = beta, .idx = -1, .flags = T.SPAWN_EMPTY };
    beta.curw = spawn.spawn_window(&beta_sc, &cause).?;

    var tall = T.Client{
        .name = "tall",
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{},
        .flags = T.CLIENT_ATTACHED,
        .session = alpha,
    };
    defer env_mod.environ_free(tall.environ);
    tall.tty = .{ .client = &tall, .sx = 80, .sy = 40 };

    var wide = T.Client{
        .name = "wide",
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{},
        .flags = T.CLIENT_ATTACHED,
        .session = alpha,
    };
    defer env_mod.environ_free(wide.environ);
    wide.tty = .{ .client = &wide, .sx = 120, .sy = 24 };

    var outsider = T.Client{
        .name = "outsider",
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{},
        .flags = T.CLIENT_ATTACHED,
        .session = beta,
    };
    defer env_mod.environ_free(outsider.environ);
    outsider.tty = .{ .client = &outsider, .sx = 200, .sy = 50 };

    client_registry.add(&tall);
    client_registry.add(&wide);
    client_registry.add(&outsider);

    const output = try capture_stdout(&.{
        "list-clients",
        "-f",
        "#{==:#{session_name},coverage-filter-alpha}",
        "-O",
        "size",
        "-r",
        "-F",
        "#{client_name}:#{client_width}x#{client_height}",
    });
    defer xm.allocator.free(output);

    try std.testing.expectEqualStrings(
        "wide:120x24\n" ++
            "tall:80x40\n",
        output,
    );
}

test "list-sessions command entry succeeds with no sessions" {
    init_harness();
    defer deinit_harness();

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{"list-sessions"}, null, &cause);
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

// ── list-panes tests ─────────────────────────────────────────────────

test "list-panes command parses target and format flags" {
    try std.testing.expectEqualStrings("list-panes", try parseName(&.{ "list-panes", "-t", "mysess:0", "-F", "#{pane_index}" }));
}

test "list-panes command entry rejects invalid sort order" {
    init_harness();
    defer deinit_harness();

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "list-panes", "-a", "-O", "not-a-valid-order" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .cmdlist = &list };

    try std.testing.expectEqual(cmd_list_panes.entry.exec, cmd_mod.cmd_get_entry(cmd).exec);
    try std.testing.expectEqual(T.CmdRetval.@"error", cmd_mod.cmd_execute(cmd, &item));
}

test "list-panes -a lists all session panes with session-qualified format" {
    init_harness();
    defer deinit_harness();

    client_registry.clients.clearRetainingCapacity();
    defer client_registry.clients.clearRetainingCapacity();

    const s = sess.session_create(null, "lsp-fmt", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("lsp-fmt") != null) sess.session_destroy(s, false, "test");

    var cause: ?[]u8 = null;
    var sc: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    s.curw = spawn.spawn_window(&sc, &cause).?;

    const output = try capture_stdout(&.{
        "list-panes", "-a",
        "-F",         "#{session_name}:#{window_index}.#{pane_index}: #{pane_width}x#{pane_height}",
    });
    defer xm.allocator.free(output);

    try std.testing.expectEqualStrings("lsp-fmt:0.0: 80x24\n", output);
}

test "list-panes -a with filter excludes non-matching session panes" {
    init_harness();
    defer deinit_harness();

    client_registry.clients.clearRetainingCapacity();
    defer client_registry.clients.clearRetainingCapacity();

    const alpha = sess.session_create(null, "lsp-filter-keep", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("lsp-filter-keep") != null) sess.session_destroy(alpha, false, "test");
    const beta = sess.session_create(null, "lsp-filter-drop", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("lsp-filter-drop") != null) sess.session_destroy(beta, false, "test");

    var cause: ?[]u8 = null;
    var alpha_sc: T.SpawnContext = .{ .s = alpha, .idx = -1, .flags = T.SPAWN_EMPTY };
    alpha.curw = spawn.spawn_window(&alpha_sc, &cause).?;
    var beta_sc: T.SpawnContext = .{ .s = beta, .idx = -1, .flags = T.SPAWN_EMPTY };
    beta.curw = spawn.spawn_window(&beta_sc, &cause).?;

    const output = try capture_stdout(&.{
        "list-panes", "-a",
        "-f",         "#{==:#{session_name},lsp-filter-keep}",
        "-F",         "#{session_name}:#{pane_index}",
    });
    defer xm.allocator.free(output);

    try std.testing.expectEqualStrings("lsp-filter-keep:0\n", output);
}

test "list-panes -a produces empty output when no sessions exist" {
    init_harness();
    defer deinit_harness();

    const output = try capture_stdout(&.{ "list-panes", "-a", "-F", "#{session_name}" });
    defer xm.allocator.free(output);

    try std.testing.expectEqualStrings("", output);
}

test "list-sessions output includes created session names" {
    init_harness();
    defer deinit_harness();

    const alpha = sess.session_create(null, "sweep-alpha", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("sweep-alpha") != null) sess.session_destroy(alpha, false, "test");
    const beta = sess.session_create(null, "sweep-beta", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("sweep-beta") != null) sess.session_destroy(beta, false, "test");

    var cause: ?[]u8 = null;
    var alpha_sc: T.SpawnContext = .{ .s = alpha, .idx = -1, .flags = T.SPAWN_EMPTY };
    alpha.curw = spawn.spawn_window(&alpha_sc, &cause).?;
    var beta_sc: T.SpawnContext = .{ .s = beta, .idx = -1, .flags = T.SPAWN_EMPTY };
    beta.curw = spawn.spawn_window(&beta_sc, &cause).?;

    const output = try capture_stdout(&.{ "list-sessions", "-F", "#{session_name}" });
    defer xm.allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "sweep-alpha") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "sweep-beta") != null);
}

test "show-messages command entry succeeds on attached client" {
    init_harness();
    defer deinit_harness();

    client_registry.clients.clearRetainingCapacity();
    defer client_registry.clients.clearRetainingCapacity();

    const session = sess.session_create(null, "show-msg-test", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("show-msg-test") != null) sess.session_destroy(session, false, "test");

    var cause: ?[]u8 = null;
    var sc: T.SpawnContext = .{ .s = session, .idx = -1, .flags = T.SPAWN_EMPTY };
    session.curw = spawn.spawn_window(&sc, &cause).?;

    var client = T.Client{
        .name = "show-msg-client",
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{},
        .flags = T.CLIENT_ATTACHED,
        .session = session,
    };
    defer env_mod.environ_free(client.environ);
    tty_mod.tty_init(&client.tty, &client);
    client_registry.add(&client);

    const cmd = try cmd_mod.cmd_parse_one(&.{"show-messages"}, &client, &cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &client, .target_client = &client, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));
}
