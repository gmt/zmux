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
// Ported from tmux/cmd-new-session.c
// Original copyright:
//   Copyright (c) 2007 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

//! cmd-new-session.zig – new-session, has-session, start-server commands.

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const log = @import("log.zig");
const cmd_mod = @import("cmd.zig");
const cmd_format = @import("cmd-format.zig");
const cmdq = @import("cmd-queue.zig");
const cmd_find = @import("cmd-find.zig");
const client_registry = @import("client-registry.zig");
const sess = @import("session.zig");
const win_mod = @import("window.zig");
const spawn_mod = @import("spawn.zig");
const opts = @import("options.zig");
const env_mod = @import("environ.zig");
const protocol = @import("zmux-protocol.zig");
const server_client_mod = @import("server-client.zig");
const server_mod = @import("server.zig");
const cfg_mod = @import("cfg.zig");
const format_mod = @import("format.zig");
const notify = @import("notify.zig");

fn attach_existing_session(
    item: *cmdq.CmdqItem,
    cl: ?*T.Client,
    s: *T.Session,
    detach_other: bool,
    kill_other: bool,
    cwd_template: ?[]const u8,
    flags_text: ?[]const u8,
) T.CmdRetval {
    var cause: ?[]u8 = null;

    if (cl) |c| {
        if (cwd_template) |working_directory| {
            const expanded = format_mod.format_single(@ptrCast(item), working_directory, c, s, null, null);
            xm.allocator.free(@constCast(s.cwd));
            s.cwd = expanded;
        }
        if ((c.flags & T.CLIENT_CONTROL) == 0 and (c.flags & T.CLIENT_TERMINAL) == 0) {
            cmdq.cmdq_error(item, "not a terminal", .{});
            return .@"error";
        }
        if (flags_text) |flags|
            server_client_mod.server_client_set_flags(c, flags);
        if (detach_other or kill_other) {
            const msg_type: protocol.MsgType = if (kill_other) .detachkill else .detach;
            for (client_registry.clients.items) |loop| {
                if (loop.session != s or loop == c) continue;
                server_client_mod.server_client_detach(loop, msg_type);
            }
        }
        if (c.session == null and server_client_mod.server_client_open(c, &cause) != 0) {
            defer if (cause) |msg| xm.allocator.free(msg);
            cmdq.cmdq_error(item, "open terminal failed: {s}", .{cause orelse "unknown"});
            return .@"error";
        }
        server_client_mod.server_client_attach(c, s);
        if (cfg_mod.cfg_finished) cfg_mod.cfg_show_causes(c);
    }
    return .normal;
}

fn find_existing_attach_session(
    item: *cmdq.CmdqItem,
    session_name: ?[]u8,
    target_name: ?[]const u8,
) ?*T.Session {
    if (session_name) |name|
        return sess.session_find(name);

    var target: T.CmdFindState = .{};
    _ = cmd_find.cmd_find_target(&target, item, target_name, .session, T.CMD_FIND_CANFAIL);
    return target.s;
}

fn exec_new_session(cmd: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {
    const args = cmd_mod.cmd_get_args(cmd);
    const cl = cmdq.cmdq_get_client(item);
    const no_attach = (cmdq.cmdq_get_flags(item) & T.CMDQ_STATE_NOATTACH) != 0;
    var target: T.CmdFindState = .{};
    var cause: ?[]u8 = null;
    const group_name = args.get('t');

    // has-session: just validate the -t target (cmd_find_target already did it)
    if (cmd.entry == &entry_has) {
        return .normal;
    }

    if (group_name != null and (args.count() != 0 or args.has('n'))) {
        cmdq.cmdq_error(item, "command or window name given with target", .{});
        return .@"error";
    }

    // Determine session name
    var session_name: ?[]u8 = null;
    if (args.get('s')) |name_template| {
        const expanded = format_mod.format_single(@ptrCast(item), name_template, cl, null, null, null);
        defer xm.allocator.free(expanded);

        session_name = sess.session_check_name(expanded);
        if (session_name == null) {
            cmdq.cmdq_error(item, "invalid session: {s}", .{expanded});
            return .@"error";
        }
    }
    defer if (session_name) |n| xm.allocator.free(n);

    // If name exists and -A flag set, attach instead
    if (args.has('A')) {
        if (find_existing_attach_session(item, session_name, args.get('t'))) |existing|
            return attach_existing_session(item, cl, existing, args.has('D'), args.has('X'), args.get('c'), args.get('f'));
    }

    if (session_name) |n| {
        if (sess.session_find(n)) |_| {
            cmdq.cmdq_error(item, "duplicate session: {s}", .{n});
            return .@"error";
        }
    }

    // Determine dimensions
    var sx: u32 = 80;
    var sy: u32 = 24;
    if (args.get('x')) |xs| {
        if (!std.mem.eql(u8, xs, "-")) {
            sx = std.fmt.parseInt(u32, xs, 10) catch {
                cmdq.cmdq_error(item, "bad width: {s}", .{xs});
                return .@"error";
            };
        } else if (cl) |c| sx = c.tty.sx;
    }
    if (args.get('y')) |ys| {
        if (!std.mem.eql(u8, ys, "-")) {
            sy = std.fmt.parseInt(u32, ys, 10) catch {
                cmdq.cmdq_error(item, "bad height: {s}", .{ys});
                return .@"error";
            };
        } else if (cl) |c| sy = c.tty.sy;
    }
    if (sx == 0) sx = 1;
    if (sy == 0) sy = 1;

    // Determine session CWD. tmux stores the formatted -c value on the session
    // but passes the raw -c argument to spawn for initial-pane resolution.
    const session_cwd_owned = if (args.get('c')) |working_directory|
        format_mod.format_single(@ptrCast(item), working_directory, cl, null, null, null)
    else
        null;
    defer if (session_cwd_owned) |cwd| xm.allocator.free(cwd);
    const session_cwd = session_cwd_owned orelse server_client_mod.server_client_get_cwd(cl, null);

    if (!args.has('d') and !no_attach) {
        if (cl) |c| {
            if (c.session == null and c.fd != -1 and (c.flags & T.CLIENT_CONTROL) == 0) {
                if (server_client_mod.server_client_check_nested(c)) {
                    cmdq.cmdq_error(item, "sessions should be nested with care, unset $TMUX to force", .{});
                    return .@"error";
                }
            }
            if (c.session == null and server_client_mod.server_client_open(c, &cause) != 0) {
                defer if (cause) |msg| xm.allocator.free(msg);
                cmdq.cmdq_error(item, "open terminal failed: {s}", .{cause orelse "unknown"});
                return .@"error";
            }
        }
    }

    var group_target: ?*T.Session = null;
    var group: ?*T.SessionGroup = null;
    var group_prefix: ?[]u8 = null;
    defer if (group_prefix) |prefix| xm.allocator.free(prefix);

    if (group_name) |target_name| {
        if (cmd_find.cmd_find_target(&target, item, target_name, .session, T.CMD_FIND_CANFAIL) != 0)
            return .@"error";
        group_target = target.s;

        if (group_target) |target_session| {
            if (sess.session_group_contains(target_session)) |existing_group| {
                group = existing_group;
                group_prefix = xm.xstrdup(existing_group.name);
            } else {
                group_prefix = xm.xstrdup(target_session.name);
            }
        } else if (sess.session_group_find(target_name)) |existing_group| {
            group = existing_group;
            group_prefix = xm.xstrdup(existing_group.name);
        } else {
            group_prefix = sess.session_check_name(target_name);
            if (group_prefix == null) {
                cmdq.cmdq_error(item, "invalid session group: {s}", .{target_name});
                return .@"error";
            }
        }
    }

    // Create session
    const new_env = build_session_environment(args, cl);

    const sess_opts = opts.options_create(opts.global_s_options);

    const s = sess.session_create(
        group_prefix,
        session_name,
        session_cwd,
        new_env,
        sess_opts,
        null,
    );

    // Spawn the initial window.
    var spawn_cause: ?[]u8 = null;
    var sc = T.SpawnContext{
        .item = @ptrCast(item),
        .s = s,
        .idx = -1,
        .cwd = args.get('c'),
        .name = args.get('n'),
        .flags = if (args.has('d')) T.SPAWN_DETACHED else 0,
    };
    const argv = argv_tail(args, 0);
    defer if (argv) |slice| free_argv(slice);
    if (argv) |slice| {
        sc.argv = slice;
        if (slice.len == 1 and slice[0].len == 0) sc.flags |= T.SPAWN_EMPTY;
    }
    var wl = spawn_mod.spawn_window(&sc, &spawn_cause);
    if (wl == null) {
        cmdq.cmdq_error(item, "create window failed: {s}", .{spawn_cause orelse "unknown"});
        sess.session_destroy(s, false, "exec_new_session");
        return .@"error";
    }

    if (group_name) |target_name| {
        if (group == null) {
            if (group_target) |target_session| {
                group = sess.session_group_new(target_session.name);
                sess.session_group_add(group.?, target_session);
            } else {
                group = sess.session_group_new(target_name);
            }
        }
        sess.session_group_add(group.?, s);
        sess.session_group_synchronize_to(s);
        if (sess.session_first_winlink(s)) |first_wl| {
            _ = sess.session_set_current(s, first_wl);
        }
        wl = s.curw;
    }

    notify.notify_session("session-created", s);

    // Apply explicit -x/-y dimensions
    if (wl) |created_wl| {
        if (args.has('x') or args.has('y')) {
            const w = created_wl.window;
            w.sx = sx;
            w.sy = sy;
            for (w.panes.items) |wp| {
                wp.sx = sx;
                wp.sy = sy;
            }
        }
    }

    // Attach client if not detached
    if (!args.has('d') and !no_attach) {
        if (cl) |c| {
            if (args.has('x') or args.has('y')) {
                c.tty.sx = sx;
                c.tty.sy = sy;
            }
            if (args.get('f')) |flags_text|
                server_client_mod.server_client_set_flags(c, flags_text);
            server_client_mod.server_client_attach(c, s);
        }
    }

    // Print new session name if -P flag
    if (args.has('P')) {
        const fmt = args.get('F') orelse "#{session_name}:";
        const print_wp = if (wl) |created_wl| created_wl.window.active else null;
        const ctx = format_mod.FormatContext{
            .item = @ptrCast(item),
            .client = cl,
            .session = s,
            .winlink = wl,
            .window = if (wl) |created_wl| created_wl.window else null,
            .pane = print_wp,
        };
        const expanded = cmd_format.require(item, fmt, &ctx) orelse return .@"error";
        defer xm.allocator.free(expanded);
        cmdq.cmdq_print(item, "{s}", .{expanded});
    }

    if (!args.has('d'))
        cmd_find.cmd_find_from_session(&cmdq.cmdq_get_state(item).current, s, 0);

    var hook_state: T.CmdFindState = .{ .idx = -1 };
    cmd_find.cmd_find_from_session(&hook_state, s, 0);
    notify.notify_hook(item, "after-new-session", &hook_state);

    if (cfg_mod.cfg_finished) cfg_mod.cfg_show_causes(cl);

    log.log_debug("new session ${d} {s}", .{ s.id, s.name });
    return .normal;
}

fn build_session_environment(
    args: *const @import("arguments.zig").Arguments,
    cl: ?*T.Client,
) *T.Environ {
    const env = env_mod.environ_create();
    if (cl) |client| {
        if (!args.has('E'))
            env_mod.environ_update(opts.global_s_options, client.environ, env);
    }
    if (args.entry('e')) |env_entry| {
        for (env_entry.values.items) |value|
            env_mod.environ_put(env, value, 0);
    }
    return env;
}

fn argv_tail(args: *const @import("arguments.zig").Arguments, start: usize) ?[][]u8 {
    if (args.count() <= start) return null;
    const out = xm.allocator.alloc([]u8, args.count() - start) catch unreachable;
    for (start..args.count()) |idx| out[idx - start] = xm.xstrdup(args.value_at(idx).?);
    return out;
}

fn free_argv(argv: [][]u8) void {
    for (argv) |arg| xm.allocator.free(arg);
    xm.allocator.free(argv);
}

fn exec_has_session(cmd: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {
    const args = cmd_mod.cmd_get_args(cmd);
    var target: T.CmdFindState = .{};
    // Resolve the -t target (quietly; not-found → error exit code)
    if (cmd_find.cmd_find_target(&target, item, args.get('t'), .session, T.CMD_FIND_QUIET) != 0)
        return .@"error";
    if (target.s == null) return .@"error";
    return .normal;
}

fn exec_start_server(_cmd: *cmd_mod.Cmd, _item: *cmdq.CmdqItem) T.CmdRetval {
    _ = _cmd;
    _ = _item;
    // Server is already running by the time we execute; just succeed.
    return .normal;
}

pub const entry: cmd_mod.CmdEntry = .{
    .name = "new-session",
    .alias = "new",
    .usage = "[-AdDEPX] [-c start-directory] [-e environment] [-F format] [-f flags] [-n window-name] [-s session-name] [-t target-session] [shell-command [argument ...]]",
    .template = "Ac:dDe:EF:f:n:Ps:t:x:Xy:",
    .lower = 0,
    .upper = -1,
    .flags = T.CMD_STARTSERVER,
    .exec = exec_new_session,
};

pub const entry_has: cmd_mod.CmdEntry = .{
    .name = "has-session",
    .alias = "has",
    .usage = "[-t target-session]",
    .template = "t:",
    .lower = 0,
    .upper = 0,
    .flags = 0,
    .exec = exec_has_session,
};

pub const entry_start: cmd_mod.CmdEntry = .{
    .name = "start-server",
    .alias = "start",
    .usage = "",
    .template = "",
    .lower = 0,
    .upper = 0,
    .flags = T.CMD_STARTSERVER,
    .exec = exec_start_server,
};

fn new_session_test_init() void {
    client_registry.clients.clearRetainingCapacity();

    opts.global_options = opts.options_create(null);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.global_s_options = opts.options_create(null);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_set_string(opts.global_s_options, false, "default-shell", "/bin/true");
    opts.global_w_options = opts.options_create(null);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);

    env_mod.global_environ = env_mod.environ_create();
    sess.session_init_globals(xm.allocator);
    win_mod.window_init_globals(xm.allocator);
}

fn new_session_test_finish() void {
    client_registry.clients.clearRetainingCapacity();
    env_mod.environ_free(env_mod.global_environ);
    opts.options_free(opts.global_options);
    opts.options_free(opts.global_s_options);
    opts.options_free(opts.global_w_options);
}

fn new_session_test_make_session(name: []const u8) struct {
    session: *T.Session,
    window: *T.Window,
} {
    const s = sess.session_create(null, name, "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    const w = win_mod.window_create(80, 24, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    var cause: ?[]u8 = null;
    const wl = sess.session_attach(s, w, -1, &cause).?;
    const wp = win_mod.window_add_pane(w, null, 80, 24);
    w.active = wp;
    s.curw = wl;

    return .{ .session = s, .window = w };
}

fn new_session_test_free_session(setup: *@TypeOf(new_session_test_make_session("unused"))) void {
    if (sess.session_find(setup.session.name) != null)
        sess.session_destroy(setup.session, false, "test");
    win_mod.window_remove_ref(setup.window, "test");
}

fn new_session_test_client(name: []const u8, session: ?*T.Session) T.Client {
    var client = T.Client{
        .name = xm.xstrdup(name),
        .environ = env_mod.environ_create(),
        .tty = .{
            .client = undefined,
            .sx = 80,
            .sy = 24,
            .xpixel = T.DEFAULT_XPIXEL,
            .ypixel = T.DEFAULT_YPIXEL,
        },
        .status = .{ .screen = undefined },
        .flags = T.CLIENT_TERMINAL | if (session != null) T.CLIENT_ATTACHED else 0,
        .session = session,
    };
    client.tty.client = &client;
    if (session) |s| s.attached += 1;
    return client;
}

fn new_session_test_free_client(client: *T.Client) void {
    env_mod.environ_free(client.environ);
    if (client.message_string) |message| xm.allocator.free(message);
    if (client.name) |name| xm.allocator.free(@constCast(name));
    if (client.cwd) |cwd| xm.allocator.free(@constCast(cwd));
    if (client.ttyname) |ttyname| xm.allocator.free(ttyname);
    if (client.exit_session) |name| xm.allocator.free(name);
}

fn new_session_test_set_pane_tty(wp: *T.WindowPane, tty: []const u8) void {
    std.debug.assert(tty.len < T.TTY_NAME_MAX);
    @memset(wp.tty_name[0..], 0);
    @memcpy(wp.tty_name[0..tty.len], tty);
}

test "new-session -A attaches to an existing named session" {
    new_session_test_init();
    defer new_session_test_finish();

    var current_setup = new_session_test_make_session("new-session-current");
    defer new_session_test_free_session(&current_setup);
    var existing_setup = new_session_test_make_session("new-session-existing");
    defer new_session_test_free_session(&existing_setup);

    var client = new_session_test_client("new-session-client", current_setup.session);
    defer new_session_test_free_client(&client);
    client_registry.add(&client);

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "new-session", "-A", "-s", "new-session-existing" }, &client, &cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &client, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));
    try std.testing.expectEqual(existing_setup.session, client.session.?);
    try std.testing.expectEqual(current_setup.session, client.last_session.?);
}

test "new-session -f applies client flags before attaching a new session" {
    new_session_test_init();
    defer new_session_test_finish();

    var current_setup = new_session_test_make_session("new-session-flags-current");
    defer new_session_test_free_session(&current_setup);

    var client = new_session_test_client("new-session-flags-client", current_setup.session);
    defer new_session_test_free_client(&client);
    client_registry.add(&client);

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{
        "new-session",
        "-f",
        "read-only,ignore-size",
        "-s",
        "new-session-flags",
    }, &client, &cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &client, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));
    try std.testing.expect(client.flags & T.CLIENT_READONLY != 0);
    try std.testing.expect(client.flags & T.CLIENT_IGNORESIZE != 0);
    try std.testing.expectEqual(current_setup.session, client.last_session.?);
    try std.testing.expectEqual(sess.session_find("new-session-flags").?, client.session.?);
}

test "new-session -A -f applies client flags to the invoking client" {
    new_session_test_init();
    defer new_session_test_finish();

    var current_setup = new_session_test_make_session("new-session-attach-flags-current");
    defer new_session_test_free_session(&current_setup);
    var existing_setup = new_session_test_make_session("new-session-attach-flags-existing");
    defer new_session_test_free_session(&existing_setup);

    var client = new_session_test_client("new-session-attach-flags-client", current_setup.session);
    defer new_session_test_free_client(&client);
    var peer = new_session_test_client("new-session-attach-flags-peer", existing_setup.session);
    defer new_session_test_free_client(&peer);
    client_registry.add(&client);
    client_registry.add(&peer);

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{
        "new-session",
        "-A",
        "-f",
        "read-only,ignore-size",
        "-s",
        "new-session-attach-flags-existing",
    }, &client, &cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &client, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));
    try std.testing.expect(client.flags & T.CLIENT_READONLY != 0);
    try std.testing.expect(client.flags & T.CLIENT_IGNORESIZE != 0);
    try std.testing.expect(peer.flags & (T.CLIENT_READONLY | T.CLIENT_IGNORESIZE) == 0);
    try std.testing.expectEqual(existing_setup.session, client.session.?);
    try std.testing.expectEqual(current_setup.session, client.last_session.?);
}

test "new-session -A -c updates the attached session cwd" {
    new_session_test_init();
    defer new_session_test_finish();

    var current_setup = new_session_test_make_session("new-session-attach-cwd-current");
    defer new_session_test_free_session(&current_setup);
    var existing_setup = new_session_test_make_session("new-session-attach-cwd-existing");
    defer new_session_test_free_session(&existing_setup);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("attach-cwd");
    const attach_cwd = try tmp.dir.realpathAlloc(xm.allocator, "attach-cwd");
    defer xm.allocator.free(attach_cwd);

    var client = new_session_test_client("new-session-attach-cwd-client", current_setup.session);
    defer new_session_test_free_client(&client);
    client_registry.add(&client);

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{
        "new-session",
        "-A",
        "-c",
        attach_cwd,
        "-s",
        "new-session-attach-cwd-existing",
    }, &client, &cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &client, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));
    try std.testing.expectEqual(existing_setup.session, client.session.?);
    try std.testing.expectEqualStrings(attach_cwd, existing_setup.session.cwd);
}

test "new-session -A -t attaches to the target session and detaches peers with -D" {
    new_session_test_init();
    defer new_session_test_finish();

    var current_setup = new_session_test_make_session("new-session-target-current");
    defer new_session_test_free_session(&current_setup);
    var target_setup = new_session_test_make_session("new-session-target-existing");
    defer new_session_test_free_session(&target_setup);

    var client = new_session_test_client("new-session-target-client", current_setup.session);
    defer new_session_test_free_client(&client);
    var peer = new_session_test_client("new-session-target-peer", target_setup.session);
    defer new_session_test_free_client(&peer);
    client_registry.add(&client);
    client_registry.add(&peer);

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{
        "new-session",
        "-A",
        "-D",
        "-t",
        "new-session-target-existing",
    }, &client, &cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &client, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));
    try std.testing.expectEqual(target_setup.session, client.session.?);
    try std.testing.expectEqual(current_setup.session, client.last_session.?);
    try std.testing.expect(peer.session == null);
    try std.testing.expectEqual(T.ClientExitReason.detached, peer.exit_reason);
    try std.testing.expectEqualStrings("new-session-target-existing", peer.exit_session.?);
}

test "new-session -c stores the session cwd and resolves the first pane from the client cwd" {
    new_session_test_init();
    defer new_session_test_finish();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("client-root/child");
    const client_root = try tmp.dir.realpathAlloc(xm.allocator, "client-root");
    defer xm.allocator.free(client_root);
    const expected_pane_cwd = try tmp.dir.realpathAlloc(xm.allocator, "client-root/child");
    defer xm.allocator.free(expected_pane_cwd);

    var client = new_session_test_client("new-session-cwd-client", null);
    defer new_session_test_free_client(&client);
    client.cwd = xm.xstrdup(client_root);
    client_registry.add(&client);

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{
        "new-session",
        "-d",
        "-c",
        "child",
        "-s",
        "new-session-cwd-relative",
    }, &client, &cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &client, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));

    const created = sess.session_find("new-session-cwd-relative").?;
    const created_wl = created.curw.?;
    const created_wp = created_wl.window.active.?;
    try std.testing.expectEqualStrings("child", created.cwd);
    try std.testing.expectEqualStrings(expected_pane_cwd, created_wp.cwd.?);
}

test "new-session -n names the initial window and disables automatic rename" {
    new_session_test_init();
    defer new_session_test_finish();

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{
        "new-session",
        "-d",
        "-s",
        "new-session-named-window",
        "-n",
        "seed-window",
    }, null, &cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));

    const created = sess.session_find("new-session-named-window").?;
    defer if (sess.session_find("new-session-named-window") != null)
        sess.session_destroy(created, false, "test");

    const created_wl = created.curw.?;
    try std.testing.expectEqualStrings("seed-window", created_wl.window.name);
    try std.testing.expectEqual(@as(i64, 0), opts.options_get_number(created_wl.window.options, "automatic-rename"));
}

test "new-session seeds the session environment from update-environment and repeated -e overrides" {
    new_session_test_init();
    defer new_session_test_finish();

    opts.options_set_array(opts.global_s_options, "update-environment", &.{ "DISPLAY", "SSH_AUTH_SOCK", "MISSING" });

    var client = new_session_test_client("new-session-env-client", null);
    defer new_session_test_free_client(&client);
    env_mod.environ_set(client.environ, "DISPLAY", 0, ":1");
    env_mod.environ_set(client.environ, "SSH_AUTH_SOCK", 0, "/tmp/agent");
    env_mod.environ_set(client.environ, "EXTRA", 0, "ignore-me");

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{
        "new-session",
        "-d",
        "-s",
        "new-session-env",
        "-e",
        "DISPLAY=:2",
        "-e",
        "FOO=first",
        "-e",
        "FOO=second",
    }, &client, &cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &client, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));

    const created = sess.session_find("new-session-env").?;
    defer if (sess.session_find("new-session-env") != null) sess.session_destroy(created, false, "test");

    try std.testing.expectEqualStrings(":2", env_mod.environ_find(created.environ, "DISPLAY").?.value.?);
    try std.testing.expectEqualStrings("/tmp/agent", env_mod.environ_find(created.environ, "SSH_AUTH_SOCK").?.value.?);
    try std.testing.expect(env_mod.environ_find(created.environ, "MISSING").?.value == null);
    try std.testing.expectEqualStrings("second", env_mod.environ_find(created.environ, "FOO").?.value.?);
    try std.testing.expect(env_mod.environ_find(created.environ, "EXTRA") == null);
}

test "new-session -E skips update-environment and applies repeated -e overrides to the initial pane" {
    const respawn_cmd = @import("cmd-respawn-pane.zig");

    new_session_test_init();
    defer new_session_test_finish();

    opts.options_set_array(opts.global_s_options, "update-environment", &.{"DISPLAY"});

    var client = new_session_test_client("new-session-pane-env-client", null);
    defer new_session_test_free_client(&client);
    env_mod.environ_set(client.environ, "DISPLAY", 0, ":1");

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{
        "new-session",
        "-d",
        "-E",
        "-s",
        "new-session-pane-env",
        "-e",
        "FOO=first",
        "-e",
        "FOO=second",
        "-e",
        "BAR=ok",
        "/bin/sh",
        "-c",
        "printf '%s %s' \"$FOO\" \"$BAR\"",
    }, &client, &cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &client, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));

    const created = sess.session_find("new-session-pane-env").?;
    defer if (sess.session_find("new-session-pane-env") != null) sess.session_destroy(created, false, "test");

    try std.testing.expect(env_mod.environ_find(created.environ, "DISPLAY") == null);
    try std.testing.expectEqualStrings("second", env_mod.environ_find(created.environ, "FOO").?.value.?);
    try std.testing.expectEqualStrings("ok", env_mod.environ_find(created.environ, "BAR").?.value.?);

    std.Thread.sleep(500 * std.time.ns_per_ms);
    const output = respawn_cmd.read_pane_output(created.curw.?.window.active.?);
    defer xm.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "second ok") != null);
}

test "new-session rejects nested unattached clients before opening a terminal" {
    new_session_test_init();
    defer new_session_test_finish();
    server_mod.server_reset_message_log();
    defer server_mod.server_reset_message_log();

    var current_setup = new_session_test_make_session("new-session-nested-current");
    defer new_session_test_free_session(&current_setup);
    const tty = "/dev/pts/new-session-nested";
    new_session_test_set_pane_tty(current_setup.window.active.?, tty);
    current_setup.window.active.?.fd = try std.posix.dup(std.posix.STDERR_FILENO);

    var client = new_session_test_client("new-session-nested-client", null);
    defer new_session_test_free_client(&client);
    client.fd = std.posix.STDIN_FILENO;
    client.ttyname = xm.xstrdup(tty);
    env_mod.environ_set(client.environ, "ZMUX", 0, "/tmp/zmux.sock,1,0");
    client_registry.add(&client);

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "new-session", "-s", "new-session-nested-blocked" }, &client, &cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &client, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.@"error", cmd_mod.cmd_execute(cmd, &item));
    try std.testing.expect(sess.session_find("new-session-nested-blocked") == null);
    try std.testing.expectEqual(@as(usize, 1), server_mod.message_log.items.len);
    try std.testing.expectEqualStrings(
        "new-session-nested-client message: sessions should be nested with care, unset $TMUX to force",
        server_mod.message_log.items[0].msg,
    );
}

test "new-session -d skips the nested-session guard" {
    new_session_test_init();
    defer new_session_test_finish();

    var current_setup = new_session_test_make_session("new-session-detached-nested-current");
    defer new_session_test_free_session(&current_setup);
    const tty = "/dev/pts/new-session-detached-nested";
    new_session_test_set_pane_tty(current_setup.window.active.?, tty);
    current_setup.window.active.?.fd = try std.posix.dup(std.posix.STDERR_FILENO);

    var client = new_session_test_client("new-session-detached-nested-client", null);
    defer new_session_test_free_client(&client);
    client.fd = std.posix.STDIN_FILENO;
    client.ttyname = xm.xstrdup(tty);
    env_mod.environ_set(client.environ, "ZMUX", 0, "/tmp/zmux.sock,1,0");
    client_registry.add(&client);

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "new-session", "-d", "-s", "new-session-detached-nested-ok" }, &client, &cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &client, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));
    try std.testing.expect(sess.session_find("new-session-detached-nested-ok") != null);
}

test "new-session -t creates a fresh session group when the target name does not exist" {
    new_session_test_init();
    defer new_session_test_finish();

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "new-session", "-d", "-t", "fresh-group" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));

    var sessions_it = sess.sessions.valueIterator();
    const created = sessions_it.next().?;
    try std.testing.expect(sessions_it.next() == null);
    try std.testing.expect(std.mem.startsWith(u8, created.*.name, "fresh-group-"));

    const group = sess.session_group_find("fresh-group").?;
    try std.testing.expectEqual(group, sess.session_group_contains(created.*).?);
}

test "new-session -t joins the target session group and synchronizes windows" {
    new_session_test_init();
    defer new_session_test_finish();

    var leader_setup = new_session_test_make_session("group-leader");
    defer new_session_test_free_session(&leader_setup);

    const extra_window = win_mod.window_create(80, 24, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    var extra_cause: ?[]u8 = null;
    const extra_wl = sess.session_attach(leader_setup.session, extra_window, -1, &extra_cause).?;
    const extra_wp = win_mod.window_add_pane(extra_window, null, 80, 24);
    extra_window.active = extra_wp;
    _ = sess.session_set_current(leader_setup.session, extra_wl);
    defer win_mod.window_remove_ref(extra_window, "test");

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "new-session", "-d", "-s", "group-peer", "-t", "group-leader" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));

    const peer = sess.session_find("group-peer").?;
    const group = sess.session_group_contains(leader_setup.session).?;
    try std.testing.expectEqual(group, sess.session_group_contains(peer).?);
    try std.testing.expectEqual(leader_setup.session.windows.count(), peer.windows.count());

    var leader_it = leader_setup.session.windows.iterator();
    while (leader_it.next()) |leader_entry| {
        const peer_wl = sess.winlink_find_by_index(&peer.windows, leader_entry.key_ptr.*).?;
        try std.testing.expectEqual(leader_entry.value_ptr.*.window, peer_wl.window);
    }
}

test "new-session queues session-created after the initial window exists" {
    cmdq.cmdq_reset_for_tests();
    defer cmdq.cmdq_reset_for_tests();

    new_session_test_init();
    defer new_session_test_finish();

    opts.options_set_array(opts.global_s_options, "session-created", &.{
        "set-environment -g -F SESSION_CREATED_HOOK '#{session_name}:#{window_name}:#{window_index}'",
    });

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{
        "new-session",
        "-d",
        "-s",
        "session-created-hook",
        "-n",
        "seed-window",
    }, null, &cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));
    while (cmdq.cmdq_next(null) != 0) {}

    const created = sess.session_find("session-created-hook").?;
    defer if (sess.session_find("session-created-hook") != null)
        sess.session_destroy(created, false, "test");

    try std.testing.expectEqualStrings(
        "session-created-hook:seed-window:0",
        env_mod.environ_find(env_mod.global_environ, "SESSION_CREATED_HOOK").?.value.?,
    );
}

test "new-session queues after-new-session hook with the new session context" {
    cmdq.cmdq_reset_for_tests();
    defer cmdq.cmdq_reset_for_tests();

    new_session_test_init();
    defer new_session_test_finish();

    opts.options_set_array(opts.global_s_options, "after-new-session", &.{
        "set-environment -g -F AFTER_NEW_SESSION '#{session_name}:#{window_name}:#{window_index}'",
    });

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{
        "new-session",
        "-d",
        "-s",
        "after-new-session-hook",
        "-n",
        "seed-window",
    }, null, &cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));
    while (cmdq.cmdq_next(null) != 0) {}

    const created = sess.session_find("after-new-session-hook").?;
    defer if (sess.session_find("after-new-session-hook") != null)
        sess.session_destroy(created, false, "test");

    try std.testing.expectEqualStrings(
        "after-new-session-hook:seed-window:0",
        env_mod.environ_find(env_mod.global_environ, "AFTER_NEW_SESSION").?.value.?,
    );
}

test "new-session updates the current state to the created session" {
    new_session_test_init();
    defer new_session_test_finish();

    var current_setup = new_session_test_make_session("new-session-current-state");
    defer new_session_test_free_session(&current_setup);

    var client = new_session_test_client("new-session-current-client", current_setup.session);
    defer new_session_test_free_client(&client);
    client_registry.add(&client);

    var current: T.CmdFindState = .{ .idx = -1 };
    cmd_find.cmd_find_from_session(&current, current_setup.session, 0);

    const state = cmdq.cmdq_new_state(&current, null, 0);
    defer cmdq.cmdq_free_state(state);

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{
        "new-session",
        "-s",
        "new-session-current-target",
    }, &client, &cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{
        .client = &client,
        .cmdlist = &list,
        .state = state,
    };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));

    const created = sess.session_find("new-session-current-target").?;
    defer if (sess.session_find("new-session-current-target") != null)
        sess.session_destroy(created, false, "test");

    try std.testing.expectEqual(created, item.state.current.s.?);
    try std.testing.expectEqual(created.curw.?, item.state.current.wl.?);
    try std.testing.expectEqual(created.curw.?.window.active.?, item.state.current.wp.?);
}

test "new-session rejects -t combined with a window name" {
    new_session_test_init();
    defer new_session_test_finish();

    var current_setup = new_session_test_make_session("target-validation-current");
    defer new_session_test_free_session(&current_setup);
    var client = new_session_test_client("target-validation-client", current_setup.session);
    defer new_session_test_free_client(&client);
    client_registry.add(&client);

    const session_count_before = sess.sessions.count();

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{
        "new-session",
        "-d",
        "-t",
        "target-validation-current",
        "-n",
        "forbidden",
    }, &client, &cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &client, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.@"error", cmd_mod.cmd_execute(cmd, &item));
    try std.testing.expectEqualStrings("Command or window name given with target", client.message_string.?);
    try std.testing.expectEqual(session_count_before, sess.sessions.count());
}

test "new-session rejects -t combined with a shell command" {
    new_session_test_init();
    defer new_session_test_finish();

    var current_setup = new_session_test_make_session("target-validation-command");
    defer new_session_test_free_session(&current_setup);
    var client = new_session_test_client("target-validation-command-client", current_setup.session);
    defer new_session_test_free_client(&client);
    client_registry.add(&client);

    const session_count_before = sess.sessions.count();

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{
        "new-session",
        "-d",
        "-t",
        "target-validation-command",
        "echo",
    }, &client, &cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &client, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.@"error", cmd_mod.cmd_execute(cmd, &item));
    try std.testing.expectEqualStrings("Command or window name given with target", client.message_string.?);
    try std.testing.expectEqual(session_count_before, sess.sessions.count());
}
