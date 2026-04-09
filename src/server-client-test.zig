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

//! server-client-test.zig – tests extracted from server-client.zig.

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const cmd_mod = @import("cmd.zig");
const cfg_mod = @import("cfg.zig");
const env_mod = @import("environ.zig");
const opts = @import("options.zig");
const sess = @import("session.zig");
const win_mod = @import("window.zig");
const tty_mod = @import("tty.zig");
const proc_mod = @import("proc.zig");
const protocol = @import("zmux-protocol.zig");
const cmdq_mod = @import("cmd-queue.zig");
const c = @import("c.zig");
const client_registry = @import("client-registry.zig");
const resize_mod = @import("resize.zig");
const sc = @import("server-client.zig");
const file_mod = @import("file.zig");

const server_client_resolve_cwd = sc.server_client_resolve_cwd;
const server_client_finalize_identify = sc.server_client_finalize_identify;
const server_client_open = sc.server_client_open;
const server_client_check_nested = sc.server_client_check_nested;
const server_client_lock = sc.server_client_lock;
const server_client_unlock = sc.server_client_unlock;
const server_client_detach = sc.server_client_detach;
const server_client_lost = sc.server_client_lost;
const server_client_attach = sc.server_client_attach;
const server_client_suspend = sc.server_client_suspend;
const server_client_exec = sc.server_client_exec;
const server_client_send_shell = sc.server_client_send_shell;
const server_client_dispatch_command = sc.server_client_dispatch_command;
const build_client_draw_payload = sc.build_client_draw_payload;

extern fn openpty(
    amaster: *c_int,
    aslave: *c_int,
    name: ?[*]u8,
    termp: ?*anyopaque,
    winp: ?*anyopaque,
) c_int;

fn test_peer_dispatch(_: ?*c.imsg.imsg, _: ?*anyopaque) callconv(.c) void {}

fn readPeerStreamPayloadAlloc(reader: *c.imsg.imsgbuf) ![]u8 {
    while (true) {
        var imsg_msg: c.imsg.imsg = undefined;
        const got = c.imsg.imsg_get(reader, &imsg_msg);
        if (got == 0) {
            try std.testing.expectEqual(@as(i32, 1), c.imsg.imsgbuf_read(reader));
            continue;
        }
        try std.testing.expect(got > 0);
        defer c.imsg.imsg_free(&imsg_msg);

        const data_len = imsg_msg.hdr.len -% @sizeOf(c.imsg.imsg_hdr);
        try std.testing.expect(data_len >= @sizeOf(i32));
        const raw: [*]const u8 = @ptrCast(imsg_msg.data.?);
        const stream: *const i32 = @ptrCast(@alignCast(imsg_msg.data.?));
        try std.testing.expectEqual(@as(i32, 1), stream.*);
        return try xm.allocator.dupe(u8, raw[@sizeOf(i32)..data_len]);
    }
}

test "server_client_resolve_cwd prefers accessible directories and falls back" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const real = try tmp.dir.realpathAlloc(xm.allocator, ".");
    defer xm.allocator.free(real);

    const resolved = server_client_resolve_cwd(real);
    try std.testing.expectEqualStrings(real, resolved);

    const missing = "/tmp/zmux-server-client-missing-cwd";
    const fallback = server_client_resolve_cwd(missing);
    try std.testing.expect(!std.mem.eql(u8, missing, fallback));
    if (std.posix.getenv("HOME")) |home|
        try std.testing.expectEqualStrings(home, fallback)
    else
        try std.testing.expectEqualStrings("/", fallback);
}

test "server_client_finalize_identify supplies client name and default term" {
    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);

    var cl = T.Client{
        .pid = 42,
        .environ = env,
        .tty = undefined,
        .status = .{},
    };
    cl.tty = .{ .client = &cl };
    defer {
        if (cl.name) |name| xm.allocator.free(@constCast(name));
        if (cl.term_name) |term_name| xm.allocator.free(term_name);
        if (cl.ttyname) |ttyname| xm.allocator.free(ttyname);
    }

    server_client_finalize_identify(&cl);
    try std.testing.expectEqualStrings("unknown", cl.term_name.?);
    try std.testing.expectEqualStrings("client-42", cl.name.?);

    cl.ttyname = xm.xstrdup("/dev/pts/test");
    server_client_finalize_identify(&cl);
    try std.testing.expectEqualStrings("/dev/pts/test", cl.name.?);
}

test "server_client_finalize_identify treats tty stdin as terminal and drops captured stdout" {
    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);

    var cl = T.Client{
        .pid = 77,
        .environ = env,
        .tty = undefined,
        .status = .{},
    };
    cl.tty = .{ .client = &cl };
    defer {
        if (cl.fd != -1) _ = c.posix_sys.close(cl.fd);
        if (cl.out_fd != -1) _ = c.posix_sys.close(cl.out_fd);
        deferFreeClientIdentifyState(&cl);
    }

    var master: c_int = undefined;
    var slave: c_int = undefined;
    var tty_name: [T.TTY_NAME_MAX]u8 = undefined;
    try std.testing.expectEqual(@as(c_int, 0), openpty(&master, &slave, &tty_name, null, null));
    defer _ = c.posix_sys.close(master);

    const pipe_fds = try std.posix.pipe();
    defer _ = c.posix_sys.close(pipe_fds[0]);

    const tty_len = std.mem.indexOfScalar(u8, &tty_name, 0) orelse tty_name.len;
    var tty_imsg = testImsg(.identify_ttyname, tty_name[0 .. tty_len + 1]);
    sc.server_client_dispatch_for_test(&tty_imsg, &cl);

    cl.fd = slave;
    cl.out_fd = pipe_fds[1];

    var done_imsg = testImsg(.identify_done, &.{});
    sc.server_client_dispatch_for_test(&done_imsg, &cl);

    try std.testing.expect((cl.flags & T.CLIENT_TERMINAL) != 0);
    try std.testing.expect(cl.fd != -1);
    try std.testing.expectEqual(@as(i32, -1), cl.out_fd);
    try std.testing.expect(c.posix_sys.isatty(cl.fd) != 0);
    try std.testing.expectEqualStrings(tty_name[0..tty_len], cl.name.?);
}

test "server_client_open rejects non-terminal clients but accepts reduced local-terminal path" {
    // tty_term_create reads global_options; initialize a minimal set.
    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);

    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);

    var cl = T.Client{
        .environ = env,
        .tty = undefined,
        .status = .{},
    };
    cl.tty = .{ .client = &cl };

    var cause: ?[]u8 = null;
    try std.testing.expectEqual(@as(i32, -1), server_client_open(&cl, &cause));
    try std.testing.expectEqualStrings("not a terminal", cause.?);
    xm.allocator.free(cause.?);

    cause = null;
    cl.ttyname = xm.xstrdup("/dev/tty");
    defer xm.allocator.free(cl.ttyname.?);
    cl.flags = T.CLIENT_TERMINAL;
    try std.testing.expectEqual(@as(i32, -1), server_client_open(&cl, &cause));
    try std.testing.expectEqualStrings("can't use /dev/tty", cause.?);
    xm.allocator.free(cause.?);

    cause = null;
    xm.allocator.free(cl.ttyname.?);
    cl.ttyname = xm.xstrdup("/tmp/zmux-test-tty");
    // Provide minimal terminfo caps so tty_term_create passes CLEAR/CUP validation.
    cl.term_name = xm.xstrdup("xterm");
    defer xm.allocator.free(cl.term_name.?);
    var test_caps = [_][]u8{
        xm.xstrdup("clear=\x1b[H\x1b[2J"),
        xm.xstrdup("cup=\x1b[%p1%d;%p2%dH"),
    };
    defer for (&test_caps) |cap| xm.allocator.free(cap);
    cl.term_caps = &test_caps;
    defer cl.term_caps = null;
    try std.testing.expectEqual(@as(i32, 0), server_client_open(&cl, &cause));
    try std.testing.expect(cause == null);
    try std.testing.expect((cl.tty.flags & @as(i32, @intCast(T.TTY_OPENED))) != 0);
    try std.testing.expect((cl.tty.flags & @as(i32, @intCast(T.TTY_STARTED))) != 0);

    cl.flags = T.CLIENT_CONTROL;
    try std.testing.expectEqual(@as(i32, 0), server_client_open(&cl, &cause));
}

test "server_client_check_nested requires ZMUX and a live pane tty match" {
    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    sess.session_init_globals(xm.allocator);
    win_mod.window_init_globals(xm.allocator);
    win_mod.window_init_globals(xm.allocator);

    const s = sess.session_create(null, "server-client-nested-check", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("server-client-nested-check") != null) sess.session_destroy(s, false, "test");

    const w = win_mod.window_create(80, 24, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    var cause: ?[]u8 = null;
    const wl = sess.session_attach(s, w, 0, &cause) orelse unreachable;
    s.curw = wl;

    const wp = win_mod.window_add_pane(w, null, 80, 24);
    w.active = wp;
    const tty = "/dev/pts/server-client-nested";
    @memset(wp.tty_name[0..], 0);
    @memcpy(wp.tty_name[0..tty.len], tty);
    wp.fd = try std.posix.dup(std.posix.STDERR_FILENO);

    var client = T.Client{
        .environ = env_mod.environ_create(),
        .ttyname = xm.xstrdup(tty),
        .tty = undefined,
        .status = .{},
    };
    defer env_mod.environ_free(client.environ);
    defer xm.allocator.free(client.ttyname.?);
    client.tty = .{ .client = &client };

    try std.testing.expect(!server_client_check_nested(&client));

    env_mod.environ_set(client.environ, "ZMUX", 0, "/tmp/zmux.sock,1,0");
    try std.testing.expect(server_client_check_nested(&client));

    env_mod.environ_set(client.environ, "ZMUX", 0, "");
    try std.testing.expect(!server_client_check_nested(&client));

    xm.allocator.free(client.ttyname.?);
    client.ttyname = xm.xstrdup("/dev/pts/server-client-other");
    try std.testing.expect(!server_client_check_nested(&client));
}

test "server_client_lock sends lock message and unlock restores redraw state" {
    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);

    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    sess.session_init_globals(xm.allocator);
    win_mod.window_init_globals(xm.allocator);

    var pair: [2]i32 = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &pair));

    var proc = T.ZmuxProc{ .name = "server-client-lock-test" };
    defer proc.peers.deinit(xm.allocator);

    var options = T.Options.init(xm.allocator, null);
    defer options.deinit();
    opts.options_set_number(&options, "status", 1);
    opts.options_set_number(&options, "status-position", 0);
    var session_env = T.Environ.init(xm.allocator);
    defer session_env.deinit();
    var session = T.Session{
        .id = 1,
        .name = @constCast("lock-test"),
        .cwd = "/tmp",
        .options = &options,
        .environ = &session_env,
    };

    var client = T.Client{
        .fd = 1,
        .environ = env,
        .tty = undefined,
        .status = .{},
        .session = &session,
    };
    tty_mod.tty_init(&client.tty, &client);
    tty_mod.tty_start_tty(&client.tty);
    client.peer = proc_mod.proc_add_peer(&proc, pair[0], test_peer_dispatch, null);
    defer {
        const peer = client.peer.?;
        c.imsg.imsgbuf_clear(&peer.ibuf);
        std.posix.close(peer.ibuf.fd);
        xm.allocator.destroy(peer);
        proc.peers.clearRetainingCapacity();
    }

    var reader: c.imsg.imsgbuf = undefined;
    try std.testing.expectEqual(@as(i32, 0), c.imsg.imsgbuf_init(&reader, pair[1]));
    defer {
        c.imsg.imsgbuf_clear(&reader);
        std.posix.close(pair[1]);
    }

    server_client_lock(&client, "printf locked");
    try std.testing.expect(client.flags & T.CLIENT_SUSPENDED != 0);
    try std.testing.expect((client.tty.flags & @as(i32, @intCast(T.TTY_STARTED))) == 0);

    try std.testing.expectEqual(@as(i32, 1), c.imsg.imsgbuf_read(&reader));
    var imsg_msg: c.imsg.imsg = undefined;
    try std.testing.expect(c.imsg.imsg_get(&reader, &imsg_msg) > 0);
    defer c.imsg.imsg_free(&imsg_msg);

    try std.testing.expectEqual(@as(u32, @intCast(@intFromEnum(protocol.MsgType.lock))), c.imsg.imsg_get_type(&imsg_msg));
    const data_len = c.imsg.imsg_get_len(&imsg_msg);
    var payload = try xm.allocator.alloc(u8, data_len);
    defer xm.allocator.free(payload);
    try std.testing.expectEqual(@as(i32, 0), c.imsg.imsg_get_data(&imsg_msg, payload.ptr, payload.len));
    try std.testing.expectEqualStrings("printf locked", payload[0 .. payload.len - 1]);

    server_client_unlock(&client);
    try std.testing.expect(client.flags & T.CLIENT_SUSPENDED == 0);
    try std.testing.expect((client.tty.flags & @as(i32, @intCast(T.TTY_STARTED))) != 0);
    try std.testing.expect(client.flags & T.CLIENT_REDRAWWINDOW != 0);
}

test "server_client_detach sends detachkill payload and clears session state" {
    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);

    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);

    sess.session_init_globals(xm.allocator);

    var pair: [2]i32 = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &pair));

    var proc = T.ZmuxProc{ .name = "server-client-detach-test" };
    defer proc.peers.deinit(xm.allocator);

    const session = sess.session_create(null, "detach-test", "/tmp", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("detach-test") != null) sess.session_destroy(session, false, "test");
    session.attached = 1;

    var client = T.Client{
        .environ = env,
        .tty = undefined,
        .status = .{},
        .flags = T.CLIENT_ATTACHED,
        .session = session,
    };
    client.tty = .{ .client = &client };
    client.peer = proc_mod.proc_add_peer(&proc, pair[0], test_peer_dispatch, null);
    defer {
        const peer = client.peer.?;
        c.imsg.imsgbuf_clear(&peer.ibuf);
        std.posix.close(peer.ibuf.fd);
        xm.allocator.destroy(peer);
        proc.peers.clearRetainingCapacity();
        if (client.exit_session) |name| xm.allocator.free(name);
    }

    var reader: c.imsg.imsgbuf = undefined;
    try std.testing.expectEqual(@as(i32, 0), c.imsg.imsgbuf_init(&reader, pair[1]));
    defer {
        c.imsg.imsgbuf_clear(&reader);
        std.posix.close(pair[1]);
    }

    server_client_detach(&client, .detachkill);
    try std.testing.expect(client.session == null);
    try std.testing.expect(client.flags & T.CLIENT_ATTACHED == 0);
    try std.testing.expectEqual(T.ClientExitReason.detached_hup, client.exit_reason);
    try std.testing.expectEqualStrings("detach-test", client.exit_session.?);
    try std.testing.expectEqual(@as(u32, 0), session.attached);

    try std.testing.expectEqual(@as(i32, 1), c.imsg.imsgbuf_read(&reader));
    var imsg_msg: c.imsg.imsg = undefined;
    try std.testing.expect(c.imsg.imsg_get(&reader, &imsg_msg) > 0);
    defer c.imsg.imsg_free(&imsg_msg);

    try std.testing.expectEqual(@as(u32, @intCast(@intFromEnum(protocol.MsgType.detachkill))), c.imsg.imsg_get_type(&imsg_msg));
    const data_len = c.imsg.imsg_get_len(&imsg_msg);
    var payload = try xm.allocator.alloc(u8, data_len);
    defer xm.allocator.free(payload);
    try std.testing.expectEqual(@as(i32, 0), c.imsg.imsg_get_data(&imsg_msg, payload.ptr, payload.len));
    try std.testing.expectEqualStrings("detach-test", payload[0 .. payload.len - 1]);
}

test "server_client_lost clears attached socket execute bits" {
    const srv = @import("server.zig");

    client_registry.clients.clearRetainingCapacity();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const real = try tmp.dir.realpathAlloc(xm.allocator, ".");
    defer xm.allocator.free(real);

    const test_socket_path = try std.fs.path.join(xm.allocator, &.{ real, "server.sock" });
    defer xm.allocator.free(test_socket_path);

    const old_socket_path = srv.socket_path;
    defer srv.socket_path = old_socket_path;
    srv.socket_path = test_socket_path;

    const old_server_fd = srv.server_fd;
    defer srv.server_fd = old_server_fd;
    srv.server_fd = -1;
    defer if (srv.server_fd >= 0) std.posix.close(srv.server_fd);

    const old_server_client_flags = srv.server_client_flags;
    defer srv.server_client_flags = old_server_client_flags;
    srv.server_client_flags = T.CLIENT_DEFAULTSOCKET;

    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);

    sess.session_init_globals(xm.allocator);
    win_mod.window_init_globals(xm.allocator);

    const session = sess.session_create(null, "lost-socket-test", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    const window = win_mod.window_create(80, 24, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    defer {
        if (sess.session_find("lost-socket-test") != null) sess.session_destroy(session, false, "test");
        win_mod.window_remove_ref(window, "test");
    }

    var cause: ?[]u8 = null;
    const wl = sess.session_attach(session, window, -1, &cause).?;
    const wp = win_mod.window_add_pane(window, null, 80, 24);
    window.active = wp;
    session.curw = wl;

    srv.server_fd = srv.server_create_socket(srv.server_client_flags, &cause);
    defer if (cause) |msg| xm.allocator.free(msg);
    try std.testing.expect(srv.server_fd >= 0);

    const client = try xm.allocator.create(T.Client);
    client.* = .{
        .name = xm.xstrdup("lost-client"),
        .environ = env_mod.environ_create(),
        .tty = .{ .client = client },
        .status = .{},
        .flags = T.CLIENT_ATTACHED,
        .session = session,
    };
    tty_mod.tty_init(&client.tty, client);
    client_registry.add(client);

    resize_mod.recalculate_sizes();
    srv.server_update_socket();

    const before = try std.fs.cwd().statFile(srv.socket_path);
    try std.testing.expectEqual(@as(std.fs.File.Mode, 0o770), before.mode & 0o777);
    try std.testing.expectEqual(@as(u32, 1), session.attached);

    server_client_lost(client);

    const after = try std.fs.cwd().statFile(srv.socket_path);
    try std.testing.expectEqual(@as(std.fs.File.Mode, 0o660), after.mode & 0o777);
    try std.testing.expectEqual(@as(u32, 0), session.attached);
    try std.testing.expectEqual(@as(usize, 0), client_registry.clients.items.len);
}

test "server_client_attach updates socket execute bits for attach state" {
    const srv = @import("server.zig");

    client_registry.clients.clearRetainingCapacity();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const real = try tmp.dir.realpathAlloc(xm.allocator, ".");
    defer xm.allocator.free(real);

    const test_socket_path = try std.fs.path.join(xm.allocator, &.{ real, "server.sock" });
    defer xm.allocator.free(test_socket_path);

    const old_socket_path = srv.socket_path;
    defer srv.socket_path = old_socket_path;
    srv.socket_path = test_socket_path;

    const old_server_fd = srv.server_fd;
    defer srv.server_fd = old_server_fd;
    srv.server_fd = -1;
    defer if (srv.server_fd >= 0) std.posix.close(srv.server_fd);

    const old_server_client_flags = srv.server_client_flags;
    defer srv.server_client_flags = old_server_client_flags;
    srv.server_client_flags = 0;

    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);

    sess.session_init_globals(xm.allocator);
    win_mod.window_init_globals(xm.allocator);

    const session = sess.session_create(null, "attach-socket-test", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    const window = win_mod.window_create(80, 24, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    defer {
        if (sess.session_find("attach-socket-test") != null) sess.session_destroy(session, false, "test");
        win_mod.window_remove_ref(window, "test");
    }

    var cause: ?[]u8 = null;
    const wl = sess.session_attach(session, window, -1, &cause).?;
    const wp = win_mod.window_add_pane(window, null, 80, 24);
    window.active = wp;
    session.curw = wl;

    srv.server_fd = srv.server_create_socket(srv.server_client_flags, &cause);
    defer if (cause) |msg| xm.allocator.free(msg);
    try std.testing.expect(srv.server_fd >= 0);

    const before = try std.fs.cwd().statFile(srv.socket_path);
    try std.testing.expectEqual(@as(std.fs.File.Mode, 0o600), before.mode & 0o777);

    var client = T.Client{
        .name = xm.xstrdup("attach-client"),
        .environ = env_mod.environ_create(),
        .tty = .{ .client = undefined },
        .status = .{},
    };
    defer {
        client_registry.clients.clearRetainingCapacity();
        env_mod.environ_free(client.environ);
        if (client.name) |name| xm.allocator.free(@constCast(name));
    }
    client.tty.client = &client;
    tty_mod.tty_init(&client.tty, &client);
    client_registry.add(&client);

    server_client_attach(&client, session);

    const after = try std.fs.cwd().statFile(srv.socket_path);
    try std.testing.expectEqual(@as(std.fs.File.Mode, 0o700), after.mode & 0o777);
    try std.testing.expect(client.session == session);
    try std.testing.expect(client.flags & T.CLIENT_ATTACHED != 0);
    try std.testing.expectEqual(@as(u32, 1), session.attached);
}

test "server_client_suspend sends suspend message and leaves session attached" {
    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);

    var pair: [2]i32 = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &pair));

    var proc = T.ZmuxProc{ .name = "server-client-suspend-test" };
    defer proc.peers.deinit(xm.allocator);

    var options = T.Options.init(xm.allocator, null);
    defer options.deinit();
    var session_env = T.Environ.init(xm.allocator);
    defer session_env.deinit();
    var session = T.Session{
        .id = 1,
        .name = @constCast("suspend-test"),
        .cwd = "/tmp",
        .options = &options,
        .environ = &session_env,
        .attached = 1,
    };

    var client = T.Client{
        .fd = 1,
        .environ = env,
        .tty = undefined,
        .status = .{},
        .flags = T.CLIENT_ATTACHED,
        .session = &session,
    };
    tty_mod.tty_init(&client.tty, &client);
    tty_mod.tty_start_tty(&client.tty);
    client.peer = proc_mod.proc_add_peer(&proc, pair[0], test_peer_dispatch, null);
    defer {
        const peer = client.peer.?;
        c.imsg.imsgbuf_clear(&peer.ibuf);
        std.posix.close(peer.ibuf.fd);
        xm.allocator.destroy(peer);
        proc.peers.clearRetainingCapacity();
    }

    var reader: c.imsg.imsgbuf = undefined;
    try std.testing.expectEqual(@as(i32, 0), c.imsg.imsgbuf_init(&reader, pair[1]));
    defer {
        c.imsg.imsgbuf_clear(&reader);
        std.posix.close(pair[1]);
    }

    server_client_suspend(&client);
    try std.testing.expect(client.flags & T.CLIENT_SUSPENDED != 0);
    try std.testing.expect(client.session == &session);
    try std.testing.expect((client.tty.flags & @as(i32, @intCast(T.TTY_STARTED))) == 0);

    try std.testing.expectEqual(@as(i32, 1), c.imsg.imsgbuf_read(&reader));
    var imsg_msg: c.imsg.imsg = undefined;
    try std.testing.expect(c.imsg.imsg_get(&reader, &imsg_msg) > 0);
    defer c.imsg.imsg_free(&imsg_msg);

    try std.testing.expectEqual(@as(u32, @intCast(@intFromEnum(protocol.MsgType.@"suspend"))), c.imsg.imsg_get_type(&imsg_msg));
    try std.testing.expectEqual(@as(usize, 0), c.imsg.imsg_get_len(&imsg_msg));
}

test "server_client_exec sends command and shell payload" {
    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);

    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);

    var pair: [2]i32 = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &pair));

    var proc = T.ZmuxProc{ .name = "server-client-exec-test" };
    defer proc.peers.deinit(xm.allocator);

    var options = T.Options.init(xm.allocator, null);
    defer options.deinit();
    opts.options_set_string(&options, false, "default-shell", "/bin/sh");
    var session_env = T.Environ.init(xm.allocator);
    defer session_env.deinit();
    var session = T.Session{
        .id = 1,
        .name = @constCast("exec-test"),
        .cwd = "/tmp",
        .options = &options,
        .environ = &session_env,
    };

    var client = T.Client{
        .environ = env,
        .tty = undefined,
        .status = .{},
        .session = &session,
    };
    client.tty = .{ .client = &client };
    client.peer = proc_mod.proc_add_peer(&proc, pair[0], test_peer_dispatch, null);
    defer {
        const peer = client.peer.?;
        c.imsg.imsgbuf_clear(&peer.ibuf);
        std.posix.close(peer.ibuf.fd);
        xm.allocator.destroy(peer);
        proc.peers.clearRetainingCapacity();
    }

    var reader: c.imsg.imsgbuf = undefined;
    try std.testing.expectEqual(@as(i32, 0), c.imsg.imsgbuf_init(&reader, pair[1]));
    defer {
        c.imsg.imsgbuf_clear(&reader);
        std.posix.close(pair[1]);
    }

    server_client_exec(&client, "printf exec");

    try std.testing.expectEqual(@as(i32, 1), c.imsg.imsgbuf_read(&reader));
    var imsg_msg: c.imsg.imsg = undefined;
    try std.testing.expect(c.imsg.imsg_get(&reader, &imsg_msg) > 0);
    defer c.imsg.imsg_free(&imsg_msg);

    try std.testing.expectEqual(@as(u32, @intCast(@intFromEnum(protocol.MsgType.exec))), c.imsg.imsg_get_type(&imsg_msg));
    const data_len = c.imsg.imsg_get_len(&imsg_msg);
    var payload = try xm.allocator.alloc(u8, data_len);
    defer xm.allocator.free(payload);
    try std.testing.expectEqual(@as(i32, 0), c.imsg.imsg_get_data(&imsg_msg, payload.ptr, payload.len));
    try std.testing.expectEqualStrings("printf exec", payload[0.."printf exec".len]);
    try std.testing.expectEqual(@as(u8, 0), payload["printf exec".len]);
    try std.testing.expectEqualStrings("/bin/sh", payload["printf exec".len + 1 .. payload.len - 1]);
}

test "server_client_send_shell returns default shell over shell message" {
    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    opts.options_set_string(opts.global_s_options, false, "default-shell", "/bin/sh");

    var pair: [2]i32 = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &pair));

    var proc = T.ZmuxProc{ .name = "server-client-shell-test" };
    defer proc.peers.deinit(xm.allocator);

    var client = T.Client{
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{},
        .pane_cache = .{},
        .stdin_pending = .{},
    };
    client.tty = .{ .client = &client };
    client.peer = proc_mod.proc_add_peer(&proc, pair[0], test_peer_dispatch, null);
    defer {
        env_mod.environ_free(client.environ);
        client.stdin_pending.deinit(xm.allocator);
        const peer = client.peer.?;
        c.imsg.imsgbuf_clear(&peer.ibuf);
        std.posix.close(peer.ibuf.fd);
        xm.allocator.destroy(peer);
        proc.peers.clearRetainingCapacity();
    }

    var reader: c.imsg.imsgbuf = undefined;
    try std.testing.expectEqual(@as(i32, 0), c.imsg.imsgbuf_init(&reader, pair[1]));
    defer {
        c.imsg.imsgbuf_clear(&reader);
        std.posix.close(pair[1]);
    }

    server_client_send_shell(&client);

    try std.testing.expectEqual(@as(i32, 1), c.imsg.imsgbuf_read(&reader));
    var imsg_msg: c.imsg.imsg = undefined;
    try std.testing.expect(c.imsg.imsg_get(&reader, &imsg_msg) > 0);
    defer c.imsg.imsg_free(&imsg_msg);

    try std.testing.expectEqual(@as(u32, @intCast(@intFromEnum(protocol.MsgType.shell))), c.imsg.imsg_get_type(&imsg_msg));
    const data_len = c.imsg.imsg_get_len(&imsg_msg);
    var payload = try xm.allocator.alloc(u8, data_len);
    defer xm.allocator.free(payload);
    try std.testing.expectEqual(@as(i32, 0), c.imsg.imsg_get_data(&imsg_msg, payload.ptr, payload.len));
    try std.testing.expectEqualStrings("/bin/sh", payload[0 .. payload.len - 1]);
    try std.testing.expectEqual(@as(u8, 0), payload[payload.len - 1]);
}

test "server_client_dispatch_command queues default-client-command when argc is zero" {
    cmdq_mod.cmdq_reset_for_tests();
    defer cmdq_mod.cmdq_reset_for_tests();

    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    opts.options_set_command(opts.global_options, "default-client-command", "list-commands");

    var client = T.Client{
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{},
        .pane_cache = .{},
        .stdin_pending = .{},
    };
    defer env_mod.environ_free(client.environ);
    defer client.stdin_pending.deinit(xm.allocator);
    client.tty = .{ .client = &client };

    var payload = protocol.MsgCommand{ .argc = 0 };
    var imsg_msg = std.mem.zeroes(c.imsg.imsg);
    imsg_msg.hdr.type = @as(@TypeOf(imsg_msg.hdr.type), @intCast(@intFromEnum(protocol.MsgType.command)));
    imsg_msg.hdr.len = @as(@TypeOf(imsg_msg.hdr.len), @sizeOf(c.imsg.imsg_hdr) + @sizeOf(protocol.MsgCommand));
    imsg_msg.data = @ptrCast(&payload);

    server_client_dispatch_command(&client, &imsg_msg);

    try std.testing.expect(cmdq_mod.cmdq_has_pending(&client));
}

test "server_client_dispatch_command marks unattached clients for exit after command completion" {
    cmdq_mod.cmdq_reset_for_tests();
    defer cmdq_mod.cmdq_reset_for_tests();

    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);

    var client = T.Client{
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{},
        .pane_cache = .{},
        .stdin_pending = .{},
    };
    defer env_mod.environ_free(client.environ);
    defer client.stdin_pending.deinit(xm.allocator);
    client.tty = .{ .client = &client };

    var payload = std.ArrayList(u8){};
    defer payload.deinit(xm.allocator);
    const msg_cmd = protocol.MsgCommand{ .argc = 1 };
    try payload.appendSlice(xm.allocator, std.mem.asBytes(&msg_cmd));
    try payload.appendSlice(xm.allocator, "start-server");
    try payload.append(xm.allocator, 0);

    var imsg_msg = std.mem.zeroes(c.imsg.imsg);
    imsg_msg.hdr.type = @as(@TypeOf(imsg_msg.hdr.type), @intCast(@intFromEnum(protocol.MsgType.command)));
    imsg_msg.hdr.len = @intCast(@sizeOf(c.imsg.imsg_hdr) + payload.items.len);
    imsg_msg.data = payload.items.ptr;

    server_client_dispatch_command(&client, &imsg_msg);

    try std.testing.expect(cmdq_mod.cmdq_has_pending(&client));
    try std.testing.expectEqual(@as(u32, 2), cmdq_mod.cmdq_next(&client));
    try std.testing.expect(client.flags & T.CLIENT_EXIT != 0);
}

test "build_client_draw_payload keeps multi-pane status-only redraw off the full-clear body path" {
    const pane_io = @import("pane-io.zig");

    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    sess.session_init_globals(xm.allocator);
    win_mod.window_init_globals(xm.allocator);

    const s = sess.session_create(null, "server-client-status-only", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("server-client-status-only") != null) sess.session_destroy(s, false, "test");

    const w = win_mod.window_create(6, 2, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    var cause: ?[]u8 = null;
    const wl = sess.session_attach(s, w, 0, &cause) orelse unreachable;
    s.curw = wl;

    const left = win_mod.window_add_pane(w, null, 3, 2);
    const right = win_mod.window_add_pane(w, null, 3, 2);
    left.xoff = 0;
    left.yoff = 0;
    right.xoff = 3;
    right.yoff = 0;
    w.active = right;

    pane_io.pane_io_feed(left, "L1\r\nL2");
    pane_io.pane_io_feed(right, "R1\r\nR2");

    var client = T.Client{
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{},
        .flags = T.CLIENT_ATTACHED,
        .session = s,
    };
    defer env_mod.environ_free(client.environ);
    client.tty = .{ .client = &client, .sx = 6, .sy = 3 };

    const status_only = build_client_draw_payload(&client, T.CLIENT_REDRAWSTATUS) orelse unreachable;
    defer xm.allocator.free(status_only);
    try std.testing.expect(status_only.len != 0);
    try std.testing.expect(std.mem.indexOf(u8, status_only, "\x1b[H\x1b[2J") == null);
    try std.testing.expect(std.mem.indexOf(u8, status_only, "L1") == null);
    try std.testing.expect(std.mem.indexOf(u8, status_only, "R1") == null);

    const full_window = build_client_draw_payload(&client, T.CLIENT_REDRAWWINDOW) orelse unreachable;
    defer xm.allocator.free(full_window);
    try std.testing.expect(std.mem.indexOf(u8, full_window, "\x1b[H\x1b[2J") != null);
    try std.testing.expect(std.mem.indexOf(u8, full_window, "L1") != null);
    try std.testing.expect(std.mem.indexOf(u8, full_window, "R1") != null);
}

test "build_client_draw_payload crops a panned multi-pane viewport" {
    const pane_io = @import("pane-io.zig");

    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    sess.session_init_globals(xm.allocator);
    win_mod.window_init_globals(xm.allocator);

    const s = sess.session_create(null, "server-client-panned-window", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("server-client-panned-window") != null) sess.session_destroy(s, false, "test");

    const w = win_mod.window_create(6, 2, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    var cause: ?[]u8 = null;
    const wl = sess.session_attach(s, w, 0, &cause) orelse unreachable;
    s.curw = wl;

    const left = win_mod.window_add_pane(w, null, 3, 2);
    const right = win_mod.window_add_pane(w, null, 3, 2);
    left.xoff = 0;
    left.yoff = 0;
    right.xoff = 3;
    right.yoff = 0;
    w.active = right;

    pane_io.pane_io_feed(left, "L1\r\nL2");
    pane_io.pane_io_feed(right, "R1\r\nR2");

    var client = T.Client{
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{},
        .flags = T.CLIENT_ATTACHED | T.CLIENT_UTF8 | T.CLIENT_STATUSOFF,
        .session = s,
        .pan_window = w,
        .pan_ox = 3,
    };
    defer env_mod.environ_free(client.environ);
    client.tty = .{ .client = &client, .sx = 3, .sy = 2 };

    const payload = build_client_draw_payload(&client, T.CLIENT_REDRAWWINDOW) orelse unreachable;
    defer xm.allocator.free(payload);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\x1b[H\x1b[2J") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "R1") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "R2") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "L1") == null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "L2") == null);
}

test "build_client_draw_payload keeps border-only redraw off the full-clear body path" {
    const pane_io = @import("pane-io.zig");

    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    sess.session_init_globals(xm.allocator);
    win_mod.window_init_globals(xm.allocator);

    const s = sess.session_create(null, "server-client-borders-only", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("server-client-borders-only") != null) sess.session_destroy(s, false, "test");

    const w = win_mod.window_create(6, 2, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    var cause: ?[]u8 = null;
    const wl = sess.session_attach(s, w, 0, &cause) orelse unreachable;
    s.curw = wl;

    const left = win_mod.window_add_pane(w, null, 3, 2);
    const right = win_mod.window_add_pane(w, null, 3, 2);
    left.xoff = 0;
    left.yoff = 0;
    right.xoff = 3;
    right.yoff = 0;
    w.active = right;

    pane_io.pane_io_feed(left, "L1\r\nL2");
    pane_io.pane_io_feed(right, "R1\r\nR2");

    var client = T.Client{
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{},
        .flags = T.CLIENT_ATTACHED | T.CLIENT_UTF8 | T.CLIENT_STATUSOFF,
        .session = s,
    };
    defer env_mod.environ_free(client.environ);
    client.tty = .{ .client = &client, .sx = 6, .sy = 2 };

    const borders_only = build_client_draw_payload(&client, T.CLIENT_REDRAWBORDERS) orelse unreachable;
    defer xm.allocator.free(borders_only);
    try std.testing.expect(borders_only.len != 0);
    try std.testing.expect(std.mem.indexOf(u8, borders_only, "\x1b[H\x1b[2J") == null);
    try std.testing.expect(std.mem.indexOf(u8, borders_only, "L1") == null);
    try std.testing.expect(std.mem.indexOf(u8, borders_only, "R1") == null);
    try std.testing.expect(std.mem.indexOf(u8, borders_only, "\x1b[1;4H") != null);
}

test "build_client_draw_payload keeps scrollbar-only redraw off the full-clear body path" {
    const screen_write = @import("screen-write.zig");

    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    sess.session_init_globals(xm.allocator);
    win_mod.window_init_globals(xm.allocator);

    const s = sess.session_create(null, "server-client-scrollbars-only", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("server-client-scrollbars-only") != null) sess.session_destroy(s, false, "test");

    const w = win_mod.window_create(4, 4, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    var cause: ?[]u8 = null;
    const wl = sess.session_attach(s, w, 0, &cause) orelse unreachable;
    s.curw = wl;

    const wp = win_mod.window_add_pane(w, null, 4, 4);
    w.active = wp;
    opts.options_set_number(wp.options, "pane-scrollbars", T.PANE_SCROLLBARS_ALWAYS);
    opts.options_set_string(wp.options, false, "pane-scrollbars-style", "fg=blue,pad=1");
    win_mod.window_pane_options_changed(wp, "pane-scrollbars-style");
    wp.base.grid.hsize = 4;

    var ctx = T.ScreenWriteCtx{ .wp = wp, .s = &wp.base };
    screen_write.putn(&ctx, "abcd");

    var client = T.Client{
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{},
        .flags = T.CLIENT_ATTACHED | T.CLIENT_UTF8 | T.CLIENT_STATUSOFF,
        .session = s,
    };
    defer env_mod.environ_free(client.environ);
    client.tty = .{ .client = &client, .sx = win_mod.window_pane_total_width(wp), .sy = 4 };

    const scrollbars_only = build_client_draw_payload(&client, T.CLIENT_REDRAWSCROLLBARS) orelse unreachable;
    defer xm.allocator.free(scrollbars_only);
    try std.testing.expect(scrollbars_only.len != 0);
    try std.testing.expect(std.mem.indexOf(u8, scrollbars_only, "\x1b[H\x1b[2J") == null);
    try std.testing.expect(std.mem.indexOf(u8, scrollbars_only, "abcd") == null);
    try std.testing.expect(std.mem.indexOf(u8, scrollbars_only, "\x1b[0;34m ") != null);
}

test "build_client_draw_payload can redraw only dirty panes without clearing the whole window" {
    const pane_io = @import("pane-io.zig");

    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    sess.session_init_globals(xm.allocator);
    win_mod.window_init_globals(xm.allocator);

    const s = sess.session_create(null, "server-client-dirty-pane", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("server-client-dirty-pane") != null) sess.session_destroy(s, false, "test");

    const w = win_mod.window_create(6, 2, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    var cause: ?[]u8 = null;
    const wl = sess.session_attach(s, w, 0, &cause) orelse unreachable;
    s.curw = wl;

    const left = win_mod.window_add_pane(w, null, 3, 2);
    const right = win_mod.window_add_pane(w, null, 3, 2);
    left.xoff = 0;
    left.yoff = 0;
    right.xoff = 3;
    right.yoff = 0;
    w.active = right;

    pane_io.pane_io_feed(left, "L1\r\nL2");
    pane_io.pane_io_feed(right, "R1\r\nR2");
    right.flags |= T.PANE_REDRAW;

    var client = T.Client{
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{},
        .flags = T.CLIENT_ATTACHED | T.CLIENT_UTF8 | T.CLIENT_STATUSOFF,
        .session = s,
    };
    defer env_mod.environ_free(client.environ);
    client.tty = .{ .client = &client, .sx = 6, .sy = 2 };

    const dirty = build_client_draw_payload(&client, T.CLIENT_REDRAWPANES) orelse unreachable;
    defer xm.allocator.free(dirty);
    try std.testing.expect(dirty.len != 0);
    try std.testing.expect(std.mem.indexOf(u8, dirty, "\x1b[H\x1b[2J") == null);
    try std.testing.expect(std.mem.indexOf(u8, dirty, "L1") == null);
    try std.testing.expect(std.mem.indexOf(u8, dirty, "R1") != null);
    try std.testing.expect(right.flags & T.PANE_REDRAW == 0);
}

test "server_client_add_client_window deduplicates entries for the same window id" {
    var cl = T.Client{
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{},
    };
    defer {
        env_mod.environ_free(cl.environ);
        cl.client_windows.deinit(xm.allocator);
    }
    cl.tty = .{ .client = &cl };

    try std.testing.expect(sc.server_client_get_client_window(&cl, 42) == null);

    const a = sc.server_client_add_client_window(&cl, 42);
    const b = sc.server_client_add_client_window(&cl, 42);
    try std.testing.expect(a == b);
    try std.testing.expectEqual(@as(usize, 1), cl.client_windows.items.len);
    try std.testing.expect(sc.server_client_get_client_window(&cl, 42).? == a);
}

test "server_client_get_pane respects active pane override when CLIENT_ACTIVEPANE is set" {
    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);

    sess.session_init_globals(xm.allocator);
    win_mod.window_init_globals(xm.allocator);

    const s = sess.session_create(null, "server-client-pane-ov", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    const w = win_mod.window_create(80, 24, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    defer {
        if (sess.session_find("server-client-pane-ov") != null) sess.session_destroy(s, false, "test");
        win_mod.window_remove_ref(w, "test");
    }

    var cause: ?[]u8 = null;
    const wl = sess.session_attach(s, w, 0, &cause).?;
    const p1 = win_mod.window_add_pane(w, null, 80, 24);
    const p2 = win_mod.window_add_pane(w, null, 80, 24);
    w.active = p1;
    s.curw = wl;

    var cl = T.Client{
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{},
        .session = s,
        .flags = 0,
    };
    defer env_mod.environ_free(cl.environ);
    cl.tty = .{ .client = &cl };

    try std.testing.expect(sc.server_client_get_pane(&cl) == p1);

    cl.flags |= T.CLIENT_ACTIVEPANE;
    sc.server_client_set_pane(&cl, p2);
    try std.testing.expect(sc.server_client_get_pane(&cl) == p2);
}

test "server_client_set_flags sets read-only active-pane and ignore-size bits" {
    var cl = T.Client{
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{},
        .flags = 0,
    };
    defer env_mod.environ_free(cl.environ);
    cl.tty = .{ .client = &cl };

    sc.server_client_set_flags(&cl, "read-only,active-pane");
    try std.testing.expect(cl.flags & T.CLIENT_READONLY != 0);
    try std.testing.expect(cl.flags & T.CLIENT_ACTIVEPANE != 0);

    sc.server_client_set_flags(&cl, "ignore-size");
    try std.testing.expect(cl.flags & T.CLIENT_IGNORESIZE != 0);
    try std.testing.expect(cl.flags & T.CLIENT_READONLY != 0);
    try std.testing.expect(cl.flags & T.CLIENT_ACTIVEPANE != 0);
}

test "server_client_get_cwd prefers detached client cwd then session cwd" {
    const tmp_cwd = try xm.allocator.dupe(u8, "/tmp/zmux-sc-cwd-test");
    defer xm.allocator.free(tmp_cwd);

    var cl = T.Client{
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{},
        .session = null,
        .cwd = tmp_cwd,
    };
    defer env_mod.environ_free(cl.environ);
    cl.tty = .{ .client = &cl };

    try std.testing.expectEqualStrings("/tmp/zmux-sc-cwd-test", sc.server_client_get_cwd(&cl, null));

    var env = T.Environ.init(xm.allocator);
    defer env.deinit();
    var so = T.Options.init(xm.allocator, null);
    defer so.deinit();
    var session = T.Session{
        .id = 9,
        .name = @constCast("cwd-test"),
        .cwd = "/session/cwd",
        .options = &so,
        .environ = &env,
    };
    cl.session = &session;
    cl.cwd = null;
    try std.testing.expectEqualStrings("/session/cwd", sc.server_client_get_cwd(&cl, null));
}

test "server_client_ranges_is_empty and ensure_ranges track allocation" {
    var r: sc.VisibleRanges = .{};
    defer if (r.ranges) |slice| xm.allocator.free(slice);

    try std.testing.expect(sc.server_client_ranges_is_empty(&r));

    sc.server_client_ensure_ranges(&r, 4);
    try std.testing.expectEqual(@as(u32, 4), r.size);
    try std.testing.expect(r.ranges != null);

    r.used = 1;
    r.ranges.?[0] = .{ .px = 0, .nx = 0 };
    try std.testing.expect(sc.server_client_ranges_is_empty(&r));

    r.ranges.?[0].nx = 3;
    try std.testing.expect(!sc.server_client_ranges_is_empty(&r));
}

test "server_client_window_cmp orders by window id" {
    const a = T.ClientWindow{ .window = 1, .pane = null };
    const b = T.ClientWindow{ .window = 2, .pane = null };
    try std.testing.expectEqual(@as(i32, -1), sc.server_client_window_cmp(&a, &b));
    try std.testing.expectEqual(@as(i32, 1), sc.server_client_window_cmp(&b, &a));
    try std.testing.expectEqual(@as(i32, 0), sc.server_client_window_cmp(&a, &a));
}

test "server_client_reset_state hides tty cursor while a client message is shown" {
    var cl: T.Client = undefined;
    cl = .{
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{},
        .flags = 0,
    };
    defer {
        env_mod.environ_free(cl.environ);
        if (cl.message_string) |m| xm.allocator.free(m);
    }
    cl.tty = .{ .client = &cl, .flags = 0 };

    cl.message_string = xm.xstrdup("status message");
    sc.server_client_reset_state(&cl);
    try std.testing.expect(cl.tty.flags & T.TTY_NOCURSOR != 0);

    xm.allocator.free(cl.message_string.?);
    cl.message_string = null;
    sc.server_client_reset_state(&cl);
    try std.testing.expect(cl.tty.flags & T.TTY_NOCURSOR == 0);
}

test "server_client_set_key_table replaces the stored table name" {
    var cl = T.Client{
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{},
        .key_table_name = null,
    };
    defer {
        env_mod.environ_free(cl.environ);
        if (cl.key_table_name) |k| xm.allocator.free(k);
    }
    cl.tty = .{ .client = &cl };

    sc.server_client_set_key_table(&cl, "vi-edit");
    try std.testing.expectEqualStrings("vi-edit", cl.key_table_name.?);

    sc.server_client_set_key_table(&cl, null);
    try std.testing.expect(cl.key_table_name == null);
}

test "server_client_get_flags lists attached and UTF-8 bits" {
    var cl = T.Client{
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{},
        .flags = T.CLIENT_ATTACHED | T.CLIENT_UTF8 | T.CLIENT_READONLY,
    };
    defer env_mod.environ_free(cl.environ);
    cl.tty = .{ .client = &cl };

    const f = sc.server_client_get_flags(&cl);
    defer xm.allocator.free(@constCast(f));
    try std.testing.expect(std.mem.indexOf(u8, f, "attached") != null);
    try std.testing.expect(std.mem.indexOf(u8, f, "UTF-8") != null);
    try std.testing.expect(std.mem.indexOf(u8, f, "read-only") != null);
}

test "server_client_get_key_table uses root without session" {
    var cl = T.Client{
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{},
        .session = null,
    };
    defer env_mod.environ_free(cl.environ);
    cl.tty = .{ .client = &cl };
    try std.testing.expectEqualStrings("root", sc.server_client_get_key_table(&cl));
}

test "server_client_get_key_table reads session key-table option" {
    var so = T.Options.init(xm.allocator, null);
    defer so.deinit();
    opts.options_set_string(&so, false, "key-table", "vi");

    var env = T.Environ.init(xm.allocator);
    defer env.deinit();
    var session = T.Session{
        .id = 77,
        .name = @constCast("kt-test"),
        .cwd = "/",
        .options = &so,
        .environ = &env,
    };

    var cl = T.Client{
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{},
        .session = &session,
    };
    defer env_mod.environ_free(cl.environ);
    cl.tty = .{ .client = &cl };

    try std.testing.expectEqualStrings("vi", sc.server_client_get_key_table(&cl));
}

test "server_client_is_bracket_paste toggles CLIENT_FOCUSED across paste markers" {
    var cl = T.Client{
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{},
        .flags = 0,
    };
    defer env_mod.environ_free(cl.environ);
    cl.tty = .{ .client = &cl };

    try std.testing.expect(!sc.server_client_is_bracket_paste(&cl, T.KEYC_PASTE_START));
    try std.testing.expect((cl.flags & T.CLIENT_FOCUSED) != 0);

    try std.testing.expect(!sc.server_client_is_bracket_paste(&cl, T.KEYC_PASTE_END));
    try std.testing.expect((cl.flags & T.CLIENT_FOCUSED) == 0);

    cl.flags |= T.CLIENT_FOCUSED;
    try std.testing.expect(sc.server_client_is_bracket_paste(&cl, T.KEYC_FOCUS_IN));
}

fn buildDispatchImsg(msg_type: u32, payload: []const u8) c.imsg.imsg {
    return .{
        .hdr = .{
            .type = msg_type,
            .len = @as(u32, @intCast(@sizeOf(c.imsg.imsg_hdr) + payload.len)),
            .peerid = protocol.PROTOCOL_VERSION,
            .pid = 0,
        },
        .data = if (payload.len == 0) null else @constCast(payload.ptr),
        .buf = null,
    };
}

const ReadCbCtx = struct {
    errno_val: c_int = -9999,
    data: std.ArrayList(u8) = .{},

    fn callback(path: []const u8, errno_value: c_int, buf: []const u8, ud: ?*anyopaque) void {
        _ = path;
        const self: *ReadCbCtx = @ptrCast(@alignCast(ud));
        self.errno_val = errno_value;
        self.data.appendSlice(xm.allocator, buf) catch {};
    }
};

test "server_client_dispatch_for_test routes read and read_done through file read pending map" {
    file_mod.resetForTests();
    defer file_mod.resetForTests();

    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);

    var pair: [2]i32 = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &pair));

    var proc = T.ZmuxProc{ .name = "server-client-dispatch-read-test" };
    defer proc.peers.deinit(xm.allocator);

    var client = T.Client{
        .environ = env,
        .tty = undefined,
        .status = .{},
        .flags = T.CLIENT_IDENTIFIED,
        .fd = -1,
    };
    client.tty = .{ .client = &client };
    client.peer = proc_mod.proc_add_peer(&proc, pair[0], test_peer_dispatch, null);
    defer {
        const peer = client.peer.?;
        c.imsg.imsgbuf_clear(&peer.ibuf);
        std.posix.close(peer.ibuf.fd);
        xm.allocator.destroy(peer);
        proc.peers.clearRetainingCapacity();
    }

    var reader: c.imsg.imsgbuf = undefined;
    try std.testing.expectEqual(@as(i32, 0), c.imsg.imsgbuf_init(&reader, pair[1]));
    defer {
        c.imsg.imsgbuf_clear(&reader);
        std.posix.close(pair[1]);
    }

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try tmp.dir.realpathAlloc(xm.allocator, ".");
    defer xm.allocator.free(cwd);
    const fpath = try std.fmt.allocPrint(xm.allocator, "{s}/dispatch-read.txt", .{cwd});
    defer xm.allocator.free(fpath);
    {
        const file = try std.fs.createFileAbsolute(fpath, .{});
        defer file.close();
        try file.writeAll("zmux-read");
    }

    var cb_ctx = ReadCbCtx{};
    defer cb_ctx.data.deinit(xm.allocator);

    const start = file_mod.startRemoteRead(&client, fpath, ReadCbCtx.callback, &cb_ctx);
    switch (start) {
        .wait => {},
        .err => |e| {
            std.debug.print("startRemoteRead unexpected err {d}\n", .{e});
            return error.StartRemoteReadFailed;
        },
    }

    while (c.imsg.imsgbuf_read(&reader) == 1) {
        var open_imsg: c.imsg.imsg = undefined;
        if (c.imsg.imsg_get(&reader, &open_imsg) <= 0) continue;
        defer c.imsg.imsg_free(&open_imsg);
        if (c.imsg.imsg_get_type(&open_imsg) != @intFromEnum(protocol.MsgType.read_open)) continue;

        const data_len = c.imsg.imsg_get_len(&open_imsg);
        const open_buf = try xm.allocator.alloc(u8, data_len);
        defer xm.allocator.free(open_buf);
        _ = c.imsg.imsg_get_data(&open_imsg, open_buf.ptr, open_buf.len);
        const ro: *const protocol.MsgReadOpen = @ptrCast(@alignCast(open_buf.ptr));
        const stream_id = ro.stream;

        var chunk = std.ArrayList(u8){};
        defer chunk.deinit(xm.allocator);
        const hdr = protocol.MsgReadData{ .stream = stream_id };
        chunk.appendSlice(xm.allocator, std.mem.asBytes(&hdr)) catch unreachable;
        chunk.appendSlice(xm.allocator, "chunk") catch unreachable;
        var read_imsg = buildDispatchImsg(@intFromEnum(protocol.MsgType.read), chunk.items);
        sc.server_client_dispatch_for_test(&read_imsg, &client);

        const done = protocol.MsgReadDone{ .stream = stream_id, .@"error" = 0 };
        var done_imsg = buildDispatchImsg(@intFromEnum(protocol.MsgType.read_done), std.mem.asBytes(&done));
        sc.server_client_dispatch_for_test(&done_imsg, &client);
        break;
    }

    try std.testing.expectEqual(@as(c_int, 0), cb_ctx.errno_val);
    try std.testing.expectEqualStrings("chunk", cb_ctx.data.items);
}

test "server_client_dispatch_for_test wakeup clears CLIENT_SUSPENDED" {
    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);

    var client = T.Client{
        .environ = env,
        .tty = undefined,
        .status = .{},
        .flags = T.CLIENT_IDENTIFIED | T.CLIENT_SUSPENDED,
        .fd = -1,
        .session = null,
    };
    client.tty = .{ .client = &client };

    var imsg = buildDispatchImsg(@intFromEnum(protocol.MsgType.wakeup), &.{});
    sc.server_client_dispatch_for_test(&imsg, &client);
    try std.testing.expect(client.flags & T.CLIENT_SUSPENDED == 0);
}

test "server_client_dispatch_for_test ignores unknown wire message type" {
    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);

    var client = T.Client{
        .environ = env,
        .tty = undefined,
        .status = .{},
        .flags = T.CLIENT_IDENTIFIED,
    };
    client.tty = .{ .client = &client };

    var imsg = buildDispatchImsg(7, &.{});
    sc.server_client_dispatch_for_test(&imsg, &client);
    try std.testing.expect((client.flags & T.CLIENT_DEAD) == 0);
}

test "server_client_dispatch_resize updates tty geometry and sets CLIENT_SIZECHANGED" {
    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);

    var cl = T.Client{
        .environ = env,
        .tty = undefined,
        .status = .{},
        .session = null,
        .flags = T.CLIENT_IDENTIFIED,
    };
    cl.tty = .{ .client = &cl };
    tty_mod.tty_init(&cl.tty, &cl);
    tty_mod.tty_set_size(&cl.tty, 10, 5, 0, 0);

    var msg_st: protocol.MsgResize = .{
        .sx = 72,
        .sy = 24,
        .xpixel = 100,
        .ypixel = 200,
    };
    var imsg = buildDispatchImsg(@intFromEnum(protocol.MsgType.resize), std.mem.asBytes(&msg_st));
    sc.server_client_dispatch_for_test(&imsg, &cl);

    try std.testing.expectEqual(@as(u32, 72), cl.tty.sx);
    try std.testing.expectEqual(@as(u32, 24), cl.tty.sy);
    // tty_resize passes derived cell pixel sizes into tty_set_size (see tty_resize in tty.zig).
    try std.testing.expectEqual(@as(u32, 100 / 72), cl.tty.xpixel);
    try std.testing.expectEqual(@as(u32, 200 / 24), cl.tty.ypixel);
    try std.testing.expect((cl.flags & T.CLIENT_SIZECHANGED) != 0);
}

test "server_client_dispatch_stdin ignores payload while client suspended" {
    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);

    var cl = T.Client{
        .environ = env,
        .tty = undefined,
        .status = .{},
        .flags = T.CLIENT_IDENTIFIED | T.CLIENT_SUSPENDED,
    };
    cl.tty = .{ .client = &cl };
    tty_mod.tty_init(&cl.tty, &cl);
    const before = cl.tty.in_buf.items.len;

    var imsg = buildDispatchImsg(@intFromEnum(protocol.MsgType.stdin_data), "zzz");
    sc.server_client_dispatch_for_test(&imsg, &cl);
    try std.testing.expectEqual(before, cl.tty.in_buf.items.len);
}

test "server_client_dispatch_shell with payload marks peer bad" {
    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);

    var pair: [2]i32 = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &pair));

    var proc = T.ZmuxProc{ .name = "sc-dispatch-shell-bad" };
    defer proc.peers.deinit(xm.allocator);

    var cl = T.Client{
        .environ = env,
        .tty = undefined,
        .status = .{},
        .flags = T.CLIENT_IDENTIFIED,
    };
    cl.tty = .{ .client = &cl };
    cl.peer = proc_mod.proc_add_peer(&proc, pair[0], test_peer_dispatch, null);
    defer {
        const peer = cl.peer.?;
        c.imsg.imsgbuf_clear(&peer.ibuf);
        std.posix.close(peer.ibuf.fd);
        xm.allocator.destroy(peer);
        proc.peers.clearRetainingCapacity();
    }

    var imsg = buildDispatchImsg(@intFromEnum(protocol.MsgType.shell), "unexpected");
    sc.server_client_dispatch_for_test(&imsg, &cl);
    try std.testing.expect((cl.peer.?.flags & T.PEER_BAD) != 0);
    std.posix.close(pair[1]);
}

test "server_client_dispatch_shell empty sends default shell path then marks peer bad" {
    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);

    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    _ = opts.options_set_string(opts.global_s_options, false, "default-shell", "/bin/sh");

    var pair: [2]i32 = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &pair));

    var proc = T.ZmuxProc{ .name = "sc-dispatch-shell-ok" };
    defer proc.peers.deinit(xm.allocator);

    var cl = T.Client{
        .environ = env,
        .tty = undefined,
        .status = .{},
        .flags = T.CLIENT_IDENTIFIED,
    };
    cl.tty = .{ .client = &cl };
    cl.peer = proc_mod.proc_add_peer(&proc, pair[0], test_peer_dispatch, null);
    defer {
        const peer = cl.peer.?;
        c.imsg.imsgbuf_clear(&peer.ibuf);
        std.posix.close(peer.ibuf.fd);
        xm.allocator.destroy(peer);
        proc.peers.clearRetainingCapacity();
    }

    var reader: c.imsg.imsgbuf = undefined;
    try std.testing.expectEqual(@as(i32, 0), c.imsg.imsgbuf_init(&reader, pair[1]));
    defer {
        c.imsg.imsgbuf_clear(&reader);
        std.posix.close(pair[1]);
    }

    var imsg = buildDispatchImsg(@intFromEnum(protocol.MsgType.shell), &.{});
    sc.server_client_dispatch_for_test(&imsg, &cl);

    try std.testing.expectEqual(@as(i32, 1), c.imsg.imsgbuf_read(&reader));
    var out: c.imsg.imsg = undefined;
    try std.testing.expect(c.imsg.imsg_get(&reader, &out) > 0);
    defer c.imsg.imsg_free(&out);
    try std.testing.expectEqual(@as(u32, @intCast(@intFromEnum(protocol.MsgType.shell))), c.imsg.imsg_get_type(&out));
    const dlen = c.imsg.imsg_get_len(&out);
    try std.testing.expect(dlen > 1);
    const buf = try xm.allocator.alloc(u8, dlen);
    defer xm.allocator.free(buf);
    _ = c.imsg.imsg_get_data(&out, buf.ptr, buf.len);
    try std.testing.expectEqualStrings("/bin/sh", std.mem.sliceTo(@as([*:0]const u8, @ptrCast(buf.ptr)), 0));

    try std.testing.expect((cl.peer.?.flags & T.PEER_BAD) != 0);
}

test "server_client_check_exit sends exit with retval and clears CLIENT_EXIT" {
    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);

    var pair: [2]i32 = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &pair));

    var proc = T.ZmuxProc{ .name = "sc-check-exit" };
    defer proc.peers.deinit(xm.allocator);

    var cl = T.Client{
        .environ = env,
        .tty = undefined,
        .status = .{},
        .flags = T.CLIENT_EXIT,
        .exit_reason = .detached,
        .retval = 9,
    };
    cl.tty = .{ .client = &cl };
    cl.peer = proc_mod.proc_add_peer(&proc, pair[0], test_peer_dispatch, null);
    defer {
        const peer = cl.peer.?;
        c.imsg.imsgbuf_clear(&peer.ibuf);
        std.posix.close(peer.ibuf.fd);
        xm.allocator.destroy(peer);
        proc.peers.clearRetainingCapacity();
    }

    var reader: c.imsg.imsgbuf = undefined;
    try std.testing.expectEqual(@as(i32, 0), c.imsg.imsgbuf_init(&reader, pair[1]));
    defer {
        c.imsg.imsgbuf_clear(&reader);
        std.posix.close(pair[1]);
    }

    sc.server_client_check_exit(&cl);
    try std.testing.expect((cl.flags & T.CLIENT_EXIT) == 0);

    try std.testing.expectEqual(@as(i32, 1), c.imsg.imsgbuf_read(&reader));
    var out: c.imsg.imsg = undefined;
    try std.testing.expect(c.imsg.imsg_get(&reader, &out) > 0);
    defer c.imsg.imsg_free(&out);
    try std.testing.expectEqual(@as(u32, @intCast(@intFromEnum(protocol.MsgType.exit))), c.imsg.imsg_get_type(&out));
    var rv: i32 = -1;
    _ = c.imsg.imsg_get_data(&out, std.mem.asBytes(&rv).ptr, @sizeOf(i32));
    try std.testing.expectEqual(@as(i32, 9), rv);
}

test "server_client_check_modes returns early without REDRAWSTATUS" {
    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);

    var cl = T.Client{
        .environ = env,
        .tty = undefined,
        .status = .{},
        .flags = T.CLIENT_ATTACHED,
        .session = null,
    };
    cl.tty = .{ .client = &cl };
    sc.server_client_check_modes(&cl);
}

test "server_client_check_redraw returns early for control clients" {
    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);

    var cl = T.Client{
        .environ = env,
        .tty = undefined,
        .status = .{},
        .flags = T.CLIENT_CONTROL | T.CLIENT_REDRAWWINDOW,
        .session = null,
    };
    cl.tty = .{ .client = &cl };
    sc.server_client_check_redraw(&cl);
    try std.testing.expect((cl.flags & T.CLIENT_REDRAWWINDOW) != 0);
}

fn imsgReaderSetNonblock(fd: i32) void {
    const fl = std.c.fcntl(fd, std.posix.F.GETFL, @as(c_int, 0));
    if (fl < 0) return;
    const O_NONBLOCK: c_int = 0x800;
    _ = std.c.fcntl(fd, std.posix.F.SETFL, fl | O_NONBLOCK);
}

fn drainPeerUntilExit(reader: *c.imsg.imsgbuf, reader_fd: i32) !i32 {
    imsgReaderSetNonblock(reader_fd);
    var iter: u32 = 0;
    while (iter < 64) : (iter += 1) {
        const nr = c.imsg.imsgbuf_read(reader);
        if (nr < 0) {
            if (std.c._errno().* == @intFromEnum(std.posix.E.AGAIN))
                return error.TestExpectedExit;
            return error.TestExpectedExit;
        }
        if (nr == 0) return error.TestExpectedExit;
        var out: c.imsg.imsg = undefined;
        if (c.imsg.imsg_get(reader, &out) <= 0) return error.TestExpectedExit;
        const ty = c.imsg.imsg_get_type(&out);
        if (ty == @intFromEnum(protocol.MsgType.exit)) {
            var rv: i32 = 0;
            _ = c.imsg.imsg_get_data(&out, std.mem.asBytes(&rv).ptr, @sizeOf(i32));
            c.imsg.imsg_free(&out);
            return rv;
        }
        c.imsg.imsg_free(&out);
    }
    return error.TestExpectedExit;
}

fn testImsg(msg_type: protocol.MsgType, payload: []u8) c.imsg.imsg {
    return .{
        .hdr = .{
            .type = @intCast(@intFromEnum(msg_type)),
            .len = @as(u32, @intCast(@sizeOf(c.imsg.imsg_hdr) + payload.len)),
            .peerid = protocol.PROTOCOL_VERSION,
            .pid = 0,
        },
        .data = if (payload.len == 0) null else payload.ptr,
        .buf = null,
    };
}

fn deferFreeClientIdentifyState(cl: *T.Client) void {
    if (cl.term_name) |p| xm.allocator.free(p);
    if (cl.ttyname) |p| xm.allocator.free(p);
    if (cl.cwd) |p| xm.allocator.free(@constCast(p));
    if (cl.name) |p| xm.allocator.free(@constCast(p));
    if (cl.term_caps) |caps| {
        for (caps) |s| xm.allocator.free(s);
        xm.allocator.free(caps);
    }
    cl.term_name = null;
    cl.ttyname = null;
    cl.cwd = null;
    cl.name = null;
    cl.term_caps = null;
}

test "server_client identify messages merge client identity and done sets flag" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const real = try tmp.dir.realpathAlloc(xm.allocator, ".");
    defer xm.allocator.free(real);
    const cwd_z = try xm.allocator.dupe(u8, real);
    defer xm.allocator.free(cwd_z);
    const cwd_payload = try std.mem.concat(xm.allocator, u8, &.{ cwd_z, &[_]u8{0} });
    defer xm.allocator.free(cwd_payload);

    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);

    var cl = T.Client{
        .pid = 9001,
        .environ = env,
        .tty = undefined,
        .status = .{},
        .flags = 0,
        .session = null,
        .term_features = 0,
    };
    cl.tty = .{ .client = &cl };
    defer deferFreeClientIdentifyState(&cl);

    var pay: [512]u8 = undefined;

    const lf: u64 = T.CLIENT_UTF8;
    @memcpy(pay[0..@sizeOf(u64)], std.mem.asBytes(&lf));
    var im = testImsg(.identify_longflags, pay[0..@sizeOf(u64)]);
    sc.server_client_dispatch_for_test(&im, &cl);
    try std.testing.expect((cl.flags & T.CLIENT_UTF8) != 0);

    const term = "unit-term\x00";
    @memcpy(pay[0..term.len], term);
    im = testImsg(.identify_term, pay[0..term.len]);
    sc.server_client_dispatch_for_test(&im, &cl);
    try std.testing.expectEqualStrings("unit-term", cl.term_name.?);

    const tty = "/dev/pts/fake\x00";
    @memcpy(pay[0..tty.len], tty);
    im = testImsg(.identify_ttyname, pay[0..tty.len]);
    sc.server_client_dispatch_for_test(&im, &cl);
    try std.testing.expectEqualStrings("/dev/pts/fake", cl.ttyname.?);

    const c1 = "cap_a\x00";
    @memcpy(pay[0..c1.len], c1);
    im = testImsg(.identify_terminfo, pay[0..c1.len]);
    sc.server_client_dispatch_for_test(&im, &cl);
    const c2 = "cap_b\x00";
    @memcpy(pay[0..c2.len], c2);
    im = testImsg(.identify_terminfo, pay[0..c2.len]);
    sc.server_client_dispatch_for_test(&im, &cl);
    try std.testing.expectEqual(@as(usize, 2), cl.term_caps.?.len);
    try std.testing.expectEqualStrings("cap_a", cl.term_caps.?[0]);
    try std.testing.expectEqualStrings("cap_b", cl.term_caps.?[1]);

    im = testImsg(.identify_cwd, cwd_payload);
    sc.server_client_dispatch_for_test(&im, &cl);
    try std.testing.expectEqualStrings(real, cl.cwd.?);

    const ev = "TRANCHE4=z\x00";
    @memcpy(pay[0..ev.len], ev);
    im = testImsg(.identify_environ, pay[0..ev.len]);
    sc.server_client_dispatch_for_test(&im, &cl);
    const ev_ent = env_mod.environ_find(cl.environ, "TRANCHE4").?;
    try std.testing.expectEqualStrings("z", ev_ent.value.?);

    const pid = std.os.linux.getpid();
    @memcpy(pay[0..@sizeOf(std.posix.pid_t)], std.mem.asBytes(&pid));
    im = testImsg(.identify_clientpid, pay[0..@sizeOf(std.posix.pid_t)]);
    sc.server_client_dispatch_for_test(&im, &cl);
    try std.testing.expectEqual(pid, cl.pid);

    const feat: i32 = 0x55;
    @memcpy(pay[0..@sizeOf(i32)], std.mem.asBytes(&feat));
    im = testImsg(.identify_features, pay[0..@sizeOf(i32)]);
    sc.server_client_dispatch_for_test(&im, &cl);
    try std.testing.expectEqual(@as(i32, 0x55), cl.term_features);

    im = testImsg(.identify_done, pay[0..0]);
    sc.server_client_dispatch_for_test(&im, &cl);
    try std.testing.expect((cl.flags & T.CLIENT_IDENTIFIED) != 0);
    try std.testing.expectEqualStrings("/dev/pts/fake", cl.name.?);
}

test "server_client_set_flags merges control options and notifies peer" {
    cfg_mod.cfg_reset_files();
    defer cfg_mod.cfg_reset_files();

    var pair: [2]i32 = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &pair));

    var proc = T.ZmuxProc{ .name = "server-client-set-flags" };
    defer proc.peers.deinit(xm.allocator);

    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);

    var cl = T.Client{
        .environ = env,
        .tty = undefined,
        .status = .{},
        .flags = T.CLIENT_CONTROL,
        .session = null,
    };
    cl.tty = .{ .client = &cl };
    cl.peer = proc_mod.proc_add_peer(&proc, pair[0], test_peer_dispatch, null);
    defer {
        const peer = cl.peer.?;
        c.imsg.imsgbuf_clear(&peer.ibuf);
        std.posix.close(peer.ibuf.fd);
        xm.allocator.destroy(peer);
        proc.peers.clearRetainingCapacity();
        cl.peer = null;
    }

    var reader: c.imsg.imsgbuf = undefined;
    try std.testing.expectEqual(@as(i32, 0), c.imsg.imsgbuf_init(&reader, pair[1]));
    defer {
        c.imsg.imsgbuf_clear(&reader);
        std.posix.close(pair[1]);
    }

    sc.server_client_set_flags(&cl, "read-only,no-output,pause-after=2");

    try std.testing.expect((cl.flags & T.CLIENT_READONLY) != 0);
    try std.testing.expect((cl.flags & T.CLIENT_CONTROL_NOOUTPUT) != 0);
    try std.testing.expect((cl.flags & T.CLIENT_CONTROL_PAUSEAFTER) != 0);

    try std.testing.expectEqual(@as(i32, 1), c.imsg.imsgbuf_read(&reader));
    var out: c.imsg.imsg = undefined;
    try std.testing.expect(c.imsg.imsg_get(&reader, &out) > 0);
    defer c.imsg.imsg_free(&out);
    try std.testing.expectEqual(@as(u32, @intCast(@intFromEnum(protocol.MsgType.flags))), c.imsg.imsg_get_type(&out));
}

test "server_client_set_path follows the active pane path and clears when absent" {
    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    sess.session_init_globals(xm.allocator);
    win_mod.window_init_globals(xm.allocator);

    const s = sess.session_create(null, "client-path", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("client-path") != null) sess.session_destroy(s, false, "test");

    const w = win_mod.window_create(80, 24, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    var cause: ?[]u8 = null;
    const wl = sess.session_attach(s, w, 0, &cause) orelse unreachable;
    s.curw = wl;

    const wp = win_mod.window_add_pane(w, null, 80, 24);
    w.active = wp;

    var cl = T.Client{
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{},
        .session = s,
    };
    defer env_mod.environ_free(cl.environ);
    defer if (cl.path) |path| xm.allocator.free(path);
    cl.tty = .{ .client = &cl };

    wp.screen.path = xm.xstrdup("/tmp/zmux-pane-path");
    sc.server_client_set_path(&cl);
    try std.testing.expectEqualStrings("/tmp/zmux-pane-path", cl.path.?);

    xm.allocator.free(wp.screen.path.?);
    wp.screen.path = xm.xstrdup("/tmp/zmux-pane-next");
    sc.server_client_set_path(&cl);
    try std.testing.expectEqualStrings("/tmp/zmux-pane-next", cl.path.?);

    xm.allocator.free(wp.screen.path.?);
    wp.screen.path = null;
    sc.server_client_set_path(&cl);
    try std.testing.expect(cl.path == null);
}

test "server_client_set_session emits control notification for peer clients" {
    client_registry.clients.clearRetainingCapacity();
    defer client_registry.clients.clearRetainingCapacity();

    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    sess.session_init_globals(xm.allocator);
    win_mod.window_init_globals(xm.allocator);

    const alpha = sess.session_create(null, "alpha", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("alpha") != null) sess.session_destroy(alpha, false, "test");
    const beta = sess.session_create(null, "beta", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("beta") != null) sess.session_destroy(beta, false, "test");

    var pair: [2]i32 = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &pair));

    var proc = T.ZmuxProc{ .name = "server-client-session-change" };
    defer proc.peers.deinit(xm.allocator);

    var changed = T.Client{
        .name = "mover",
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{},
        .session = alpha,
    };
    defer env_mod.environ_free(changed.environ);
    changed.tty = .{ .client = &changed };

    var observer = T.Client{
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{},
        .flags = T.CLIENT_CONTROL,
        .session = alpha,
    };
    defer env_mod.environ_free(observer.environ);
    observer.tty = .{ .client = &observer };
    observer.peer = proc_mod.proc_add_peer(&proc, pair[0], test_peer_dispatch, null);
    defer {
        const peer = observer.peer.?;
        c.imsg.imsgbuf_clear(&peer.ibuf);
        std.posix.close(peer.ibuf.fd);
        xm.allocator.destroy(peer);
        proc.peers.clearRetainingCapacity();
        observer.peer = null;
    }

    alpha.attached = 2;
    beta.attached = 0;
    client_registry.add(&changed);
    client_registry.add(&observer);

    var reader: c.imsg.imsgbuf = undefined;
    try std.testing.expectEqual(@as(i32, 0), c.imsg.imsgbuf_init(&reader, pair[1]));
    defer {
        c.imsg.imsgbuf_clear(&reader);
        std.posix.close(pair[1]);
    }

    sc.server_client_set_session(&changed, beta);

    try std.testing.expect(changed.session == beta);
    try std.testing.expectEqual(alpha, changed.last_session.?);
    try std.testing.expectEqual(@as(u32, 1), alpha.attached);
    try std.testing.expectEqual(@as(u32, 1), beta.attached);

    const payload = try readPeerStreamPayloadAlloc(&reader);
    defer xm.allocator.free(payload);
    const expected = try std.fmt.allocPrint(xm.allocator, "%client-session-changed mover ${d} beta\n", .{beta.id});
    defer xm.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, payload);
}

test "server_client_dispatch_command bad default-client-command sends exit" {
    cfg_mod.cfg_reset_files();
    defer cfg_mod.cfg_reset_files();

    cmdq_mod.cmdq_reset_for_tests();
    defer cmdq_mod.cmdq_reset_for_tests();

    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    opts.options_set_command(opts.global_options, "default-client-command", "not-a-valid-zmux-command-xyz");

    var pair: [2]i32 = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &pair));

    var proc = T.ZmuxProc{ .name = "server-client-bad-default" };
    defer proc.peers.deinit(xm.allocator);

    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);

    var client = T.Client{
        .environ = env,
        .tty = undefined,
        .status = .{},
        .flags = T.CLIENT_IDENTIFIED,
        .session = null,
        .pane_cache = .{},
        .stdin_pending = .{},
    };
    defer client.stdin_pending.deinit(xm.allocator);
    client.tty = .{ .client = &client };
    client.peer = proc_mod.proc_add_peer(&proc, pair[0], test_peer_dispatch, null);
    defer {
        const peer = client.peer.?;
        c.imsg.imsgbuf_clear(&peer.ibuf);
        std.posix.close(peer.ibuf.fd);
        xm.allocator.destroy(peer);
        proc.peers.clearRetainingCapacity();
        client.peer = null;
    }

    var reader: c.imsg.imsgbuf = undefined;
    try std.testing.expectEqual(@as(i32, 0), c.imsg.imsgbuf_init(&reader, pair[1]));
    defer {
        c.imsg.imsgbuf_clear(&reader);
        std.posix.close(pair[1]);
    }

    var payload = protocol.MsgCommand{ .argc = 0 };
    var imsg_msg = std.mem.zeroes(c.imsg.imsg);
    imsg_msg.hdr.type = @as(@TypeOf(imsg_msg.hdr.type), @intCast(@intFromEnum(protocol.MsgType.command)));
    imsg_msg.hdr.len = @as(@TypeOf(imsg_msg.hdr.len), @sizeOf(c.imsg.imsg_hdr) + @sizeOf(protocol.MsgCommand));
    imsg_msg.data = @ptrCast(&payload);

    server_client_dispatch_command(&client, &imsg_msg);

    const rv = try drainPeerUntilExit(&reader, pair[1]);
    try std.testing.expectEqual(@as(i32, 1), rv);
}

test "server_client readonly enqueue rejects non-readonly command list" {
    cfg_mod.cfg_reset_files();
    defer cfg_mod.cfg_reset_files();

    cmdq_mod.cmdq_reset_for_tests();
    defer cmdq_mod.cmdq_reset_for_tests();

    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);

    var pair: [2]i32 = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &pair));

    var proc = T.ZmuxProc{ .name = "server-client-ro-enq" };
    defer proc.peers.deinit(xm.allocator);

    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);

    var cl = T.Client{
        .environ = env,
        .tty = undefined,
        .status = .{},
        .flags = T.CLIENT_IDENTIFIED | T.CLIENT_READONLY,
        .session = null,
    };
    cl.tty = .{ .client = &cl };
    cl.peer = proc_mod.proc_add_peer(&proc, pair[0], test_peer_dispatch, null);
    defer {
        const peer = cl.peer.?;
        c.imsg.imsgbuf_clear(&peer.ibuf);
        std.posix.close(peer.ibuf.fd);
        xm.allocator.destroy(peer);
        proc.peers.clearRetainingCapacity();
        cl.peer = null;
    }

    var reader: c.imsg.imsgbuf = undefined;
    try std.testing.expectEqual(@as(i32, 0), c.imsg.imsgbuf_init(&reader, pair[1]));
    defer {
        c.imsg.imsgbuf_clear(&reader);
        std.posix.close(pair[1]);
    }

    var cause: ?[]u8 = null;
    const parsed = try cmd_mod.cmd_parse_one(&.{ "new-session", "-s", "tr4ro" }, null, &cause);

    const list_on_heap = try xm.allocator.create(cmd_mod.CmdList);
    list_on_heap.* = .{};
    list_on_heap.append(parsed);

    sc.server_client_enqueue_command_list_for_tests(&cl, list_on_heap);

    try std.testing.expect(!cmdq_mod.cmdq_has_pending(&cl));
    const rv = try drainPeerUntilExit(&reader, pair[1]);
    try std.testing.expectEqual(@as(i32, 1), rv);
}
