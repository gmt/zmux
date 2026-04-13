// Copyright (c) 2026 Greg Turner <gmt@be-evil.net>
// ISC licence – see COPYING.

//! cmd-refresh-client-test.zig – external tests for subscription wiring
//! and control-side deltas in cmd-refresh-client.zig.

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const cmd_mod = @import("cmd.zig");
const cmdq = @import("cmd-queue.zig");
const control_subscriptions = @import("control-subscriptions.zig");
const env_mod = @import("environ.zig");

/// Execute a refresh-client command with the given client as both
/// the queue and target (no -t flag).
fn execCmd(target: *T.Client, argv: []const []const u8) !T.CmdRetval {
    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(argv, null, &cause);
    defer cmd_mod.cmd_free(cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{
        .client = target,
        .target_client = target,
        .cmdlist = &list,
    };
    return cmd_mod.cmd_execute(cmd, &item);
}

test "cmd-refresh-client -B re-registration replaces subscription format" {
    var env = T.Environ.init(std.testing.allocator);
    defer env.deinit();

    var client = T.Client{
        .name = "control",
        .environ = &env,
        .tty = undefined,
        .status = .{},
        .flags = T.CLIENT_CONTROL,
    };
    defer control_subscriptions.control_subscriptions_deinit(&client);
    client.tty.client = &client;

    // Add session subscription
    try std.testing.expectEqual(T.CmdRetval.normal, try execCmd(&client, &.{ "refresh-client", "-B", "watch::#{session_name}" }));
    try std.testing.expectEqual(@as(usize, 1), client.control_subscriptions.items.len);
    try std.testing.expectEqual(T.ControlSubType.session, client.control_subscriptions.items[0].sub_type);
    try std.testing.expectEqualStrings("#{session_name}", client.control_subscriptions.items[0].format);

    // Re-register same name with all-panes type and different format
    try std.testing.expectEqual(T.CmdRetval.normal, try execCmd(&client, &.{ "refresh-client", "-B", "watch:%*:#{pane_id}" }));
    try std.testing.expectEqual(@as(usize, 1), client.control_subscriptions.items.len);
    try std.testing.expectEqual(T.ControlSubType.all_panes, client.control_subscriptions.items[0].sub_type);
    try std.testing.expectEqualStrings("#{pane_id}", client.control_subscriptions.items[0].format);
}

test "cmd-refresh-client -B removal of unknown subscription is safe" {
    var env = T.Environ.init(std.testing.allocator);
    defer env.deinit();

    var client = T.Client{
        .name = "control",
        .environ = &env,
        .tty = undefined,
        .status = .{},
        .flags = T.CLIENT_CONTROL,
    };
    defer control_subscriptions.control_subscriptions_deinit(&client);
    client.tty.client = &client;

    // Removal of a name that was never registered should be a harmless no-op
    try std.testing.expectEqual(T.CmdRetval.normal, try execCmd(&client, &.{ "refresh-client", "-B", "nonexistent" }));
    try std.testing.expectEqual(@as(usize, 0), client.control_subscriptions.items.len);
}

test "cmd-refresh-client -B on sessionless control client registers subscription safely" {
    var env = T.Environ.init(std.testing.allocator);
    defer env.deinit();

    var client = T.Client{
        .name = "control",
        .environ = &env,
        .tty = undefined,
        .status = .{},
        .flags = T.CLIENT_CONTROL,
        .session = null,
    };
    defer control_subscriptions.control_subscriptions_deinit(&client);
    client.tty.client = &client;

    // Subscription registers even without a session attached
    try std.testing.expectEqual(T.CmdRetval.normal, try execCmd(&client, &.{ "refresh-client", "-B", "watch::#{session_name}" }));
    try std.testing.expectEqual(@as(usize, 1), client.control_subscriptions.items.len);
    try std.testing.expectEqualStrings("watch", client.control_subscriptions.items[0].name);

    // control_check_subscriptions returns early with null session — no delta
    control_subscriptions.control_check_subscriptions(&client);
    try std.testing.expect(client.control_subscriptions.items[0].last == null);
}

test "cmd-refresh-client control delta resets on subscription re-registration" {
    var session_env = T.Environ.init(xm.allocator);
    defer session_env.deinit();
    var session_options = T.Options.init(xm.allocator, null);
    defer session_options.deinit();

    var session = T.Session{
        .id = 99,
        .name = xm.xstrdup("delta-test"),
        .cwd = "/",
        .options = &session_options,
        .environ = &session_env,
    };
    defer xm.allocator.free(session.name);

    var client_env = T.Environ.init(xm.allocator);
    defer client_env.deinit();

    var client = T.Client{
        .name = "control",
        .environ = &client_env,
        .tty = undefined,
        .status = .{},
        .session = &session,
        .flags = T.CLIENT_CONTROL,
    };
    defer control_subscriptions.control_subscriptions_deinit(&client);
    client.tty.client = &client;

    // Wire subscription via refresh-client -B
    try std.testing.expectEqual(T.CmdRetval.normal, try execCmd(&client, &.{ "refresh-client", "-B", "watch::#{session_name}" }));
    try std.testing.expect(client.control_subscriptions.items[0].last == null);

    // Evaluate subscriptions — temporarily clear CLIENT_CONTROL so output
    // goes to stdout instead of the (absent) peer imsg path.
    client.flags &= ~T.CLIENT_CONTROL;

    var pipe1: [2]i32 = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.pipe(&pipe1));
    defer std.posix.close(pipe1[0]);
    const stdout_dup = try std.posix.dup(std.posix.STDOUT_FILENO);
    defer std.posix.close(stdout_dup);
    try std.posix.dup2(pipe1[1], std.posix.STDOUT_FILENO);
    control_subscriptions.control_check_subscriptions(&client);
    try std.posix.dup2(stdout_dup, std.posix.STDOUT_FILENO);
    std.posix.close(pipe1[1]);
    var discard1: [512]u8 = undefined;
    _ = try std.posix.read(pipe1[0], &discard1);

    // last should now be set to the session name
    try std.testing.expect(client.control_subscriptions.items[0].last != null);
    try std.testing.expectEqualStrings("delta-test", client.control_subscriptions.items[0].last.?);

    // Re-register with different format — resets cached delta
    client.flags |= T.CLIENT_CONTROL;
    try std.testing.expectEqual(T.CmdRetval.normal, try execCmd(&client, &.{ "refresh-client", "-B", "watch::#{session_id}" }));
    try std.testing.expect(client.control_subscriptions.items[0].last == null);

    // Second check evaluates the new format
    client.flags &= ~T.CLIENT_CONTROL;
    var pipe2: [2]i32 = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.pipe(&pipe2));
    defer std.posix.close(pipe2[0]);
    try std.posix.dup2(pipe2[1], std.posix.STDOUT_FILENO);
    control_subscriptions.control_check_subscriptions(&client);
    try std.posix.dup2(stdout_dup, std.posix.STDOUT_FILENO);
    std.posix.close(pipe2[1]);
    var discard2: [512]u8 = undefined;
    _ = try std.posix.read(pipe2[0], &discard2);

    // last should be set to the new format's value (session id, not name)
    try std.testing.expect(client.control_subscriptions.items[0].last != null);
    try std.testing.expect(!std.mem.eql(u8, "delta-test", client.control_subscriptions.items[0].last.?));
}
