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
const cmd_mod = @import("cmd.zig");
const cmdq = @import("cmd-queue.zig");
const cmd_find = @import("cmd-find.zig");
const sess = @import("session.zig");
const win = @import("window.zig");
const opts = @import("options.zig");
const env_mod = @import("environ.zig");
const client_registry = @import("client-registry.zig");
const server_client_mod = @import("server-client.zig");
const protocol = @import("zmux-protocol.zig");

fn exec_attach(cmd: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {
    const args = cmd_mod.cmd_get_args(cmd);
    var target = cmdq.cmdq_get_target(item);
    const cl = cmdq.cmdq_get_client(item);
    var cause: ?[]u8 = null;

    if (cmd_find.cmd_find_target(&target, item, args.get('t'), .session, 0) != 0)
        return .@"error";
    const s = target.s orelse return .@"error";

    const detach_other = args.has('d');
    const read_only = args.has('r');
    _ = detach_other;
    _ = read_only;

    if (cl) |c| {
        if ((c.flags & T.CLIENT_CONTROL) == 0 and (c.flags & T.CLIENT_TERMINAL) == 0) {
            cmdq.cmdq_error(item, "not a terminal", .{});
            return .@"error";
        }
        if (c.session == null and server_client_mod.server_client_open(c, &cause) != 0) {
            defer if (cause) |msg| xm.allocator.free(msg);
            cmdq.cmdq_error(item, "open terminal failed: {s}", .{cause orelse "unknown"});
            return .@"error";
        }
        server_client_mod.server_client_attach(c, s);
    }
    return .normal;
}

fn exec_detach(cmd: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {
    const args = cmd_mod.cmd_get_args(cmd);
    const exec_command = args.get('E');
    const msg_type: protocol.MsgType = if (args.has('P')) .detachkill else .detach;

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

    const tc = cmdq.cmdq_get_target_client(item) orelse cmdq.cmdq_get_client(item);
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
    .template = "c:dEf:rt:",
    .lower = 0,
    .upper = 0,
    .flags = T.CMD_STARTSERVER,
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
        .tty = undefined,
        .status = .{ .screen = undefined },
        .flags = if (session != null) T.CLIENT_ATTACHED else 0,
        .session = session,
    };
    client.tty.client = &client;
    if (session) |s| s.attached += 1;
    return client;
}

fn detach_test_free_client(client: *T.Client) void {
    env_mod.environ_free(client.environ);
    if (client.name) |name| xm.allocator.free(@constCast(name));
    if (client.exit_session) |name| xm.allocator.free(name);
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
