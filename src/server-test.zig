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

//! server-test.zig – server lifecycle and signal coverage extracted from server.zig.

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const cmdq = @import("cmd-queue.zig");
const env_mod = @import("environ.zig");
const log = @import("log.zig");
const opts = @import("options.zig");
const sess = @import("session.zig");
const server = @import("server.zig");
const client_registry = @import("client-registry.zig");
const win = @import("window.zig");

extern fn server_signal(signo: c_int) void;

fn initServerTestState() void {
    cmdq.cmdq_reset_for_tests();
    client_registry.clients.clearRetainingCapacity();

    opts.global_options = opts.options_create(null);
    opts.global_s_options = opts.options_create(null);
    opts.global_w_options = opts.options_create(null);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);

    sess.session_init_globals(xm.allocator);
    win.window_init_globals(xm.allocator);
}

fn deinitServerTestState() void {
    cmdq.cmdq_reset_for_tests();
    client_registry.clients.clearRetainingCapacity();
    opts.options_free(opts.global_options);
    opts.options_free(opts.global_s_options);
    opts.options_free(opts.global_w_options);
}

test "server_signal ignores SIGHUP and leaves shutdown state untouched" {
    initServerTestState();
    defer deinitServerTestState();

    const old_server_exit = server.server_exit;
    defer server.server_exit = old_server_exit;
    server.server_exit = false;

    const shutdown_session = sess.session_create(null, "server-sighup-ignored", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("server-sighup-ignored") != null) sess.session_destroy(shutdown_session, false, "test");

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

    // tmux server_signal() has no SIGHUP branch in server.c, so this should be a no-op.
    server_signal(std.posix.SIG.HUP);

    try std.testing.expect(!server.server_exit);
    try std.testing.expect(client.session == shutdown_session);
    try std.testing.expect(client.flags & T.CLIENT_EXIT == 0);
    try std.testing.expect(sess.session_find("server-sighup-ignored") == shutdown_session);
}

test "server_add_client and server_remove_client update the live registry" {
    initServerTestState();
    defer deinitServerTestState();

    var client_a = T.Client{ .environ = env_mod.environ_create(), .tty = undefined, .status = .{} };
    defer env_mod.environ_free(client_a.environ);
    client_a.tty = .{ .client = &client_a };

    var client_b = T.Client{ .environ = env_mod.environ_create(), .tty = undefined, .status = .{} };
    defer env_mod.environ_free(client_b.environ);
    client_b.tty = .{ .client = &client_b };

    var client_c = T.Client{ .environ = env_mod.environ_create(), .tty = undefined, .status = .{} };
    defer env_mod.environ_free(client_c.environ);
    client_c.tty = .{ .client = &client_c };

    server.server_add_client(&client_a);
    server.server_add_client(&client_b);
    try std.testing.expectEqual(@as(usize, 2), client_registry.clients.items.len);
    try std.testing.expect(client_registry.clients.items[0] == &client_a);
    try std.testing.expect(client_registry.clients.items[1] == &client_b);

    server.server_remove_client(&client_c);
    try std.testing.expectEqual(@as(usize, 2), client_registry.clients.items.len);

    server.server_remove_client(&client_a);
    try std.testing.expectEqual(@as(usize, 1), client_registry.clients.items.len);
    try std.testing.expect(client_registry.clients.items[0] == &client_b);

    server.server_remove_client(&client_b);
    try std.testing.expectEqual(@as(usize, 0), client_registry.clients.items.len);
}

test "server_destroy_session detaches only clients bound to the target session" {
    initServerTestState();
    defer deinitServerTestState();

    const target = sess.session_create(null, "server-destroy-target", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("server-destroy-target") != null) sess.session_destroy(target, false, "test");
    const other = sess.session_create(null, "server-destroy-other", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("server-destroy-other") != null) sess.session_destroy(other, false, "test");

    target.attached = 2;
    other.attached = 1;

    var target_client = T.Client{
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{},
        .flags = T.CLIENT_ATTACHED,
        .session = target,
        .last_session = target,
    };
    defer env_mod.environ_free(target_client.environ);
    target_client.tty = .{ .client = &target_client };

    var second_target_client = T.Client{
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{},
        .flags = T.CLIENT_ATTACHED,
        .session = target,
    };
    defer env_mod.environ_free(second_target_client.environ);
    second_target_client.tty = .{ .client = &second_target_client };

    var other_client = T.Client{
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{},
        .flags = T.CLIENT_ATTACHED,
        .session = other,
        .last_session = other,
    };
    defer env_mod.environ_free(other_client.environ);
    other_client.tty = .{ .client = &other_client };

    server.server_add_client(&target_client);
    server.server_add_client(&second_target_client);
    server.server_add_client(&other_client);

    server.server_destroy_session(target);

    try std.testing.expectEqual(@as(u32, 0), target.attached);
    try std.testing.expect(target_client.session == null);
    try std.testing.expect(target_client.last_session == null);
    try std.testing.expect(target_client.flags & T.CLIENT_EXIT != 0);
    try std.testing.expect(second_target_client.session == null);
    try std.testing.expect(second_target_client.flags & T.CLIENT_EXIT != 0);

    try std.testing.expectEqual(@as(u32, 1), other.attached);
    try std.testing.expect(other_client.session == other);
    try std.testing.expect(other_client.last_session == other);
    try std.testing.expect(other_client.flags & T.CLIENT_EXIT == 0);
}

test "server_request_exit marks the server exiting and tears down sessions" {
    initServerTestState();
    defer deinitServerTestState();

    const old_server_exit = server.server_exit;
    defer server.server_exit = old_server_exit;
    server.server_exit = false;

    const left = sess.session_create(null, "server-request-exit-left", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    const right = sess.session_create(null, "server-request-exit-right", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);

    var client_a = T.Client{
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{},
        .flags = T.CLIENT_ATTACHED,
        .session = left,
    };
    defer env_mod.environ_free(client_a.environ);
    client_a.tty = .{ .client = &client_a };

    var client_b = T.Client{
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{},
        .flags = 0,
        .session = right,
    };
    defer env_mod.environ_free(client_b.environ);
    client_b.tty = .{ .client = &client_b };

    server.server_add_client(&client_a);
    server.server_add_client(&client_b);

    server.server_request_exit();

    try std.testing.expect(server.server_exit);
    try std.testing.expect(client_a.session == null);
    try std.testing.expect(client_b.session == null);
    try std.testing.expect(client_a.flags & T.CLIENT_EXIT != 0);
    try std.testing.expect(client_b.flags & T.CLIENT_EXIT != 0);
    try std.testing.expectEqual(T.ClientExitReason.server_exited, client_a.exit_reason);
    try std.testing.expectEqual(T.ClientExitReason.server_exited, client_b.exit_reason);
    try std.testing.expect(sess.session_find("server-request-exit-left") == null);
    try std.testing.expect(sess.session_find("server-request-exit-right") == null);
}

test "server_signal SIGUSR1 keeps the old socket when reopen fails" {
    initServerTestState();
    defer deinitServerTestState();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const real = try tmp.dir.realpathAlloc(xm.allocator, ".");
    defer xm.allocator.free(real);

    const valid_socket_path = try std.fs.path.join(xm.allocator, &.{ real, "server.sock" });
    defer xm.allocator.free(valid_socket_path);

    const old_socket_path = server.socket_path;
    defer server.socket_path = old_socket_path;
    const old_server_fd = server.server_fd;
    defer if (server.server_fd >= 0 and server.server_fd != old_server_fd) std.posix.close(server.server_fd);
    defer server.server_fd = old_server_fd;
    const old_server_client_flags = server.server_client_flags;
    defer server.server_client_flags = old_server_client_flags;

    server.socket_path = valid_socket_path;
    server.server_client_flags = T.CLIENT_DEFAULTSOCKET;

    var cause: ?[]u8 = null;
    server.server_fd = server.server_create_socket(server.server_client_flags, &cause);
    defer if (cause) |msg| xm.allocator.free(msg);
    try std.testing.expect(server.server_fd >= 0);

    const original_fd = server.server_fd;
    const too_long_path = try xm.allocator.alloc(u8, 200);
    defer xm.allocator.free(too_long_path);
    @memset(too_long_path, 'x');
    server.socket_path = too_long_path;

    server_signal(std.posix.SIG.USR1);

    try std.testing.expectEqual(original_fd, server.server_fd);
    try std.testing.expect(std.c.fcntl(original_fd, std.posix.F.GETFD, @as(c_int, 0)) != -1);
}

test "server_signal SIGUSR2 is a no-op when no server proc exists" {
    const old_server_proc = server.server_proc;
    defer server.server_proc = old_server_proc;
    server.server_proc = null;

    const before = log.log_get_level();
    server_signal(std.posix.SIG.USR2);
    try std.testing.expectEqual(before, log.log_get_level());
}
