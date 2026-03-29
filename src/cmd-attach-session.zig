// Copyright (c) 2026 Greg Turner <gmt@be-evil.net>
// ISC licence – see COPYING.
//
// Ported from tmux/cmd-attach-session.c
// Original copyright:
//   Copyright (c) 2007 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const cfg_mod = @import("cfg.zig");
const cmd_mod = @import("cmd.zig");
const cmdq = @import("cmd-queue.zig");
const cmd_find = @import("cmd-find.zig");
const format_mod = @import("format.zig");
const sess = @import("session.zig");
const win = @import("window.zig");
const opts = @import("options.zig");
const env_mod = @import("environ.zig");
const client_registry = @import("client-registry.zig");
const notify = @import("notify.zig");
const proc_mod = @import("proc.zig");
const server_client_mod = @import("server-client.zig");
const protocol = @import("zmux-protocol.zig");
const c_mod = @import("c.zig");
const tty_mod = @import("tty.zig");

fn detach_test_peer_dispatch(_: ?*c_mod.imsg.imsg, _: ?*anyopaque) callconv(.c) void {}

fn detach_other_clients(invoker: *T.Client, s: *T.Session, msg_type: protocol.MsgType) void {
    for (client_registry.clients.items) |loop| {
        if (loop.session != s or loop == invoker) continue;
        server_client_mod.server_client_detach(loop, msg_type);
    }
}

fn exec_attach(cmd: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {
    const args = cmd_mod.cmd_get_args(cmd);
    const cl = cmdq.cmdq_get_client(item);
    var cause: ?[]u8 = null;
    var target = cmdq.cmdq_get_target(item);

    if (sess.sessions.count() == 0) {
        cmdq.cmdq_error(item, "no sessions", .{});
        return .@"error";
    }

    const c = cl orelse return .normal;
    if (server_client_mod.server_client_check_nested(c)) {
        cmdq.cmdq_error(item, "sessions should be nested with care, unset $ZMUX to force", .{});
        return .@"error";
    }

    const tflag = args.get('t');
    const find_type: T.CmdFindType = if (tflag) |target_name|
        if (std.mem.indexOfAny(u8, target_name, ":.") != null) .pane else .session
    else
        .session;
    const find_flags: u32 = if (find_type == .session) T.CMD_FIND_PREFER_UNATTACHED else 0;
    if (cmd_find.cmd_find_target(&target, item, tflag, find_type, find_flags) != 0)
        return .@"error";

    const s = target.s orelse return .@"error";
    const wl = target.wl;
    const wp = target.wp;

    if (wl) |target_wl| {
        if (wp) |target_wp| _ = win.window_set_active_pane(target_wp.window, target_wp, true);
        _ = sess.session_set_current(s, target_wl);
    }

    if (args.get('c')) |working_directory| {
        const expanded = format_mod.format_single(@ptrCast(item), working_directory, c, s, wl, wp);
        xm.allocator.free(@constCast(s.cwd));
        s.cwd = expanded;
    }

    if ((c.flags & T.CLIENT_CONTROL) == 0 and (c.flags & T.CLIENT_TERMINAL) == 0) {
        cmdq.cmdq_error(item, "not a terminal", .{});
        return .@"error";
    }

    if (args.get('f')) |flags_text|
        server_client_mod.server_client_set_flags(c, flags_text);
    if (args.has('r'))
        c.flags |= T.CLIENT_READONLY | T.CLIENT_IGNORESIZE;

    c.last_session = c.session;
    const newly_attached = c.session == null;
    if (newly_attached and server_client_mod.server_client_open(c, &cause) != 0) {
        defer if (cause) |msg| xm.allocator.free(msg);
        cmdq.cmdq_error(item, "open terminal failed: {s}", .{cause orelse "unknown"});
        return .@"error";
    }

    if (args.has('d') or args.has('x')) {
        const msg_type: protocol.MsgType = if (args.has('x')) .detachkill else .detach;
        detach_other_clients(c, s, msg_type);
    }
    if (!args.has('E'))
        env_mod.environ_update(s.options, c.environ, s.environ);

    server_client_mod.server_client_set_session(c, s);
    if (!newly_attached) {
        if ((cmdq.cmdq_get_flags(item) & T.CMDQ_STATE_REPEAT) == 0)
            server_client_mod.server_client_set_key_table(c, null);
    } else {
        server_client_mod.server_client_set_key_table(c, null);
        if ((c.flags & T.CLIENT_CONTROL) == 0) {
            if (c.peer) |peer| _ = proc_mod.proc_send(peer, .ready, -1, null, 0);
        }
        notify.notify_client("client-attached", c);
        c.flags |= T.CLIENT_ATTACHED | T.CLIENT_REDRAW;
    }

    if (cfg_mod.cfg_finished) cfg_mod.cfg_show_causes(c);
    return .normal;
}

fn exec_detach(cmd: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {
    const args = cmd_mod.cmd_get_args(cmd);
    const entry_ptr = cmd_mod.cmd_get_entry(cmd);
    const exec_command = args.get('E');
    const msg_type: protocol.MsgType = if (args.has('P')) .detachkill else .detach;
    const tc = cmdq.cmdq_get_target_client(item) orelse cmdq.cmdq_get_client(item);

    if (entry_ptr == &entry_suspend) {
        const target_client = tc orelse {
            cmdq.cmdq_error(item, "no client", .{});
            return .@"error";
        };
        server_client_mod.server_client_suspend(target_client);
        return .normal;
    }

    if (args.has('s')) {
        var target = cmdq.cmdq_get_target(item);
        if (cmd_find.cmd_find_target(&target, item, args.get('s'), .session, T.CMD_FIND_CANFAIL) != 0)
            return .@"error";

        const s = target.s orelse return .normal;
        for (client_registry.clients.items) |loop| {
            if (loop.session != s) continue;
            if (exec_command) |command|
                server_client_mod.server_client_exec(loop, command)
            else
                server_client_mod.server_client_detach(loop, msg_type);
        }
        return .stop;
    }

    if (args.has('a')) {
        for (client_registry.clients.items) |loop| {
            if (loop.session == null or loop == tc) continue;
            if (exec_command) |command|
                server_client_mod.server_client_exec(loop, command)
            else
                server_client_mod.server_client_detach(loop, msg_type);
        }
        return .normal;
    }

    const target_client = tc orelse {
        cmdq.cmdq_error(item, "no client", .{});
        return .@"error";
    };

    if (exec_command) |command|
        server_client_mod.server_client_exec(target_client, command)
    else
        server_client_mod.server_client_detach(target_client, msg_type);
    return .stop;
}

pub const entry: cmd_mod.CmdEntry = .{
    .name = "attach-session",
    .alias = "attach",
    .usage = "[-dErx] [-c working-directory] [-f flags] [-t target-session]",
    .template = "c:dEf:rt:x",
    .lower = 0,
    .upper = 0,
    .flags = T.CMD_STARTSERVER | T.CMD_READONLY,
    .exec = exec_attach,
};

pub const entry_detach: cmd_mod.CmdEntry = .{
    .name = "detach-client",
    .alias = "detach",
    .usage = "[-aP] [-E shell-command] [-s target-session] [-t target-client]",
    .template = "aE:Ps:t:",
    .lower = 0,
    .upper = 0,
    .flags = T.CMD_READONLY | T.CMD_CLIENT_TFLAG,
    .exec = exec_detach,
};

pub const entry_suspend: cmd_mod.CmdEntry = .{
    .name = "suspend-client",
    .alias = "suspendc",
    .usage = "[-t target-client]",
    .template = "t:",
    .lower = 0,
    .upper = 0,
    .flags = T.CMD_CLIENT_TFLAG,
    .exec = exec_detach,
};

fn detach_test_init() void {
    client_registry.clients.clearRetainingCapacity();

    opts.global_options = opts.options_create(null);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.global_s_options = opts.options_create(null);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.global_w_options = opts.options_create(null);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);

    env_mod.global_environ = env_mod.environ_create();
    sess.session_init_globals(xm.allocator);
    win.window_init_globals(xm.allocator);
}

fn detach_test_make_session(name: []const u8) struct {
    session: *T.Session,
    window: *T.Window,
} {
    const s = sess.session_create(null, name, "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    const w = win.window_create(80, 24, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    var cause: ?[]u8 = null;
    const wl = sess.session_attach(s, w, -1, &cause).?;
    const wp = win.window_add_pane(w, null, 80, 24);
    w.active = wp;
    s.curw = wl;

    return .{ .session = s, .window = w };
}

fn detach_test_free_session(setup: *@TypeOf(detach_test_make_session("unused"))) void {
    if (sess.session_find(setup.session.name) != null) sess.session_destroy(setup.session, false, "test");
    win.window_remove_ref(setup.window, "test");
}

fn detach_test_finish() void {
    client_registry.clients.clearRetainingCapacity();
    env_mod.environ_free(env_mod.global_environ);
    opts.options_free(opts.global_options);
    opts.options_free(opts.global_s_options);
    opts.options_free(opts.global_w_options);
}

fn detach_test_client(name: []const u8, session: ?*T.Session) T.Client {
    var client = T.Client{
        .name = xm.xstrdup(name),
        .environ = env_mod.environ_create(),
        .tty = .{ .client = undefined },
        .status = .{ .screen = undefined },
        .flags = if (session != null) T.CLIENT_ATTACHED else 0,
        .session = session,
    };
    tty_mod.tty_init(&client.tty, &client);
    if (session) |s| s.attached += 1;
    return client;
}

fn detach_test_free_client(client: *T.Client) void {
    env_mod.environ_free(client.environ);
    if (client.name) |name| xm.allocator.free(@constCast(name));
    if (client.exit_session) |name| xm.allocator.free(name);
}

test "attach-session applies cwd, environment, and readonly flags" {
    detach_test_init();
    defer detach_test_finish();

    var source_setup = detach_test_make_session("attach-source");
    defer detach_test_free_session(&source_setup);
    var target_setup = detach_test_make_session("attach-target");
    defer detach_test_free_session(&target_setup);

    opts.options_set_array(target_setup.session.options, "update-environment", &.{ "DISPLAY", "SSH_AUTH_SOCK", "MISSING" });
    env_mod.environ_set(target_setup.session.environ, "DISPLAY", 0, ":0");
    env_mod.environ_set(target_setup.session.environ, "SSH_AUTH_SOCK", 0, "/tmp/old-agent");
    env_mod.environ_set(target_setup.session.environ, "UNCHANGED", 0, "session");

    var invoker = detach_test_client("invoker", source_setup.session);
    defer detach_test_free_client(&invoker);
    invoker.flags |= T.CLIENT_TERMINAL;
    env_mod.environ_set(invoker.environ, "DISPLAY", 0, ":1");
    env_mod.environ_set(invoker.environ, "SSH_AUTH_SOCK", 0, "/tmp/new-agent");

    client_registry.add(&invoker);

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{
        "attach-session",
        "-t",
        "attach-target",
        "-c",
        "#{session_name}",
        "-f",
        "ignore-size",
        "-r",
    }, &invoker, &cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &invoker, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));
    try std.testing.expect(invoker.session == target_setup.session);
    try std.testing.expect(invoker.last_session == source_setup.session);
    try std.testing.expectEqualStrings("attach-target", target_setup.session.cwd);
    try std.testing.expect(invoker.flags & T.CLIENT_READONLY != 0);
    try std.testing.expect(invoker.flags & T.CLIENT_IGNORESIZE != 0);
    try std.testing.expectEqualStrings(":1", env_mod.environ_find(target_setup.session.environ, "DISPLAY").?.value.?);
    try std.testing.expectEqualStrings("/tmp/new-agent", env_mod.environ_find(target_setup.session.environ, "SSH_AUTH_SOCK").?.value.?);
    try std.testing.expect(env_mod.environ_find(target_setup.session.environ, "MISSING").?.value == null);
    try std.testing.expectEqualStrings("session", env_mod.environ_find(target_setup.session.environ, "UNCHANGED").?.value.?);
}

test "attach-session -E skips update-environment" {
    detach_test_init();
    defer detach_test_finish();

    var source_setup = detach_test_make_session("attach-e-source");
    defer detach_test_free_session(&source_setup);
    var target_setup = detach_test_make_session("attach-e-target");
    defer detach_test_free_session(&target_setup);

    opts.options_set_array(target_setup.session.options, "update-environment", &.{"DISPLAY"});
    env_mod.environ_set(target_setup.session.environ, "DISPLAY", 0, ":0");

    var invoker = detach_test_client("invoker", source_setup.session);
    defer detach_test_free_client(&invoker);
    invoker.flags |= T.CLIENT_TERMINAL;
    env_mod.environ_set(invoker.environ, "DISPLAY", 0, ":1");

    client_registry.add(&invoker);

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "attach-session", "-E", "-t", "attach-e-target" }, &invoker, &cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &invoker, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));
    try std.testing.expectEqualStrings(":0", env_mod.environ_find(target_setup.session.environ, "DISPLAY").?.value.?);
}

test "attach-session -d detaches other clients in the target session" {
    detach_test_init();
    defer detach_test_finish();

    var source_setup = detach_test_make_session("attach-d-source");
    defer detach_test_free_session(&source_setup);
    var target_setup = detach_test_make_session("attach-d-target");
    defer detach_test_free_session(&target_setup);
    var other_setup = detach_test_make_session("attach-d-other");
    defer detach_test_free_session(&other_setup);

    var invoker = detach_test_client("invoker", source_setup.session);
    defer detach_test_free_client(&invoker);
    invoker.flags |= T.CLIENT_TERMINAL;
    var peer = detach_test_client("peer", target_setup.session);
    defer detach_test_free_client(&peer);
    var outsider = detach_test_client("outsider", other_setup.session);
    defer detach_test_free_client(&outsider);

    client_registry.add(&invoker);
    client_registry.add(&peer);
    client_registry.add(&outsider);

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "attach-session", "-d", "-t", "attach-d-target" }, &invoker, &cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &invoker, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));
    try std.testing.expect(invoker.session == target_setup.session);
    try std.testing.expect(peer.session == null);
    try std.testing.expectEqual(T.ClientExitReason.detached, peer.exit_reason);
    try std.testing.expect(peer.flags & T.CLIENT_EXIT != 0);
    try std.testing.expect(outsider.session == other_setup.session);
}

test "attach-session -x detach-kills other clients in the target session" {
    detach_test_init();
    defer detach_test_finish();

    var source_setup = detach_test_make_session("attach-x-source");
    defer detach_test_free_session(&source_setup);
    var target_setup = detach_test_make_session("attach-x-target");
    defer detach_test_free_session(&target_setup);

    var invoker = detach_test_client("invoker", source_setup.session);
    defer detach_test_free_client(&invoker);
    invoker.flags |= T.CLIENT_TERMINAL;
    var peer = detach_test_client("peer", target_setup.session);
    defer detach_test_free_client(&peer);

    client_registry.add(&invoker);
    client_registry.add(&peer);

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "attach-session", "-x", "-t", "attach-x-target" }, &invoker, &cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &invoker, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));
    try std.testing.expect(peer.session == null);
    try std.testing.expectEqual(T.ClientExitReason.detached_hup, peer.exit_reason);
    try std.testing.expect(peer.flags & T.CLIENT_EXIT != 0);
}

test "detach-client -t resolves target-client and detaches only that client" {
    detach_test_init();
    defer detach_test_finish();

    var session_setup = detach_test_make_session("detach-target");
    defer detach_test_free_session(&session_setup);

    var invoker = detach_test_client("invoker", session_setup.session);
    defer detach_test_free_client(&invoker);
    var target = detach_test_client("target", session_setup.session);
    defer detach_test_free_client(&target);

    client_registry.add(&invoker);
    client_registry.add(&target);

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "detach-client", "-t", "target" }, &invoker, &cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &invoker, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.stop, cmd_mod.cmd_execute(cmd, &item));
    try std.testing.expect(invoker.session == session_setup.session);
    try std.testing.expect(target.session == null);
    try std.testing.expect(target.flags & T.CLIENT_EXIT != 0);
}

test "detach-client -a detaches every other attached client" {
    detach_test_init();
    defer detach_test_finish();

    var primary_setup = detach_test_make_session("detach-all-primary");
    defer detach_test_free_session(&primary_setup);
    var secondary_setup = detach_test_make_session("detach-all-secondary");
    defer detach_test_free_session(&secondary_setup);

    var invoker = detach_test_client("invoker", primary_setup.session);
    defer detach_test_free_client(&invoker);
    var peer = detach_test_client("peer", primary_setup.session);
    defer detach_test_free_client(&peer);
    var outsider = detach_test_client("outsider", secondary_setup.session);
    defer detach_test_free_client(&outsider);

    client_registry.add(&invoker);
    client_registry.add(&peer);
    client_registry.add(&outsider);

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "detach-client", "-a" }, &invoker, &cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &invoker, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));
    try std.testing.expect(invoker.session == primary_setup.session);
    try std.testing.expect(peer.session == null);
    try std.testing.expect(outsider.session == null);
}

test "detach-client -s detaches every client in the target session" {
    detach_test_init();
    defer detach_test_finish();

    var target_setup = detach_test_make_session("detach-session-target");
    defer detach_test_free_session(&target_setup);
    var other_setup = detach_test_make_session("detach-session-other");
    defer detach_test_free_session(&other_setup);

    var session_member_a = detach_test_client("member-a", target_setup.session);
    defer detach_test_free_client(&session_member_a);
    var session_member_b = detach_test_client("member-b", target_setup.session);
    defer detach_test_free_client(&session_member_b);
    var outsider = detach_test_client("outsider", other_setup.session);
    defer detach_test_free_client(&outsider);

    client_registry.add(&session_member_a);
    client_registry.add(&session_member_b);
    client_registry.add(&outsider);

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "detach-client", "-s", "detach-session-target" }, &outsider, &cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &outsider, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.stop, cmd_mod.cmd_execute(cmd, &item));
    try std.testing.expect(session_member_a.session == null);
    try std.testing.expect(session_member_b.session == null);
    try std.testing.expect(outsider.session == other_setup.session);
}

test "suspend-client -t resolves target-client and marks it suspended" {
    detach_test_init();
    defer detach_test_finish();

    var session_setup = detach_test_make_session("suspend-target");
    defer detach_test_free_session(&session_setup);

    var invoker = detach_test_client("invoker", session_setup.session);
    defer detach_test_free_client(&invoker);
    invoker.flags |= T.CLIENT_TERMINAL;
    var target = detach_test_client("target", session_setup.session);
    defer detach_test_free_client(&target);
    target.flags |= T.CLIENT_TERMINAL;
    tty_mod.tty_init(&target.tty, &target);

    var pair: [2]i32 = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &pair));
    var proc = T.ZmuxProc{ .name = "cmd-suspend-client-test" };
    defer proc.peers.deinit(xm.allocator);
    target.peer = proc_mod.proc_add_peer(&proc, pair[0], detach_test_peer_dispatch, null);
    defer {
        const peer = target.peer.?;
        c_mod.imsg.imsgbuf_clear(&peer.ibuf);
        std.posix.close(peer.ibuf.fd);
        std.posix.close(pair[1]);
        xm.allocator.destroy(peer);
        proc.peers.clearRetainingCapacity();
        target.peer = null;
    }

    client_registry.add(&invoker);
    client_registry.add(&target);

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "suspend-client", "-t", "target" }, &invoker, &cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &invoker, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));
    try std.testing.expect(invoker.flags & T.CLIENT_SUSPENDED == 0);
    try std.testing.expect(target.flags & T.CLIENT_SUSPENDED != 0);
    try std.testing.expect(target.session == session_setup.session);
}
