// Copyright (c) 2026 Greg Turner <gmt@be-evil.net>
// ISC licence – see COPYING.
// Ported from tmux/cmd-select-window.c and cmd-new-window.c

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const cmd_mod = @import("cmd.zig");
const cmd_format = @import("cmd-format.zig");
const cmdq = @import("cmd-queue.zig");
const cmd_find = @import("cmd-find.zig");
const sess = @import("session.zig");
const env_mod = @import("environ.zig");
const win_mod = @import("window.zig");
const spawn_mod = @import("spawn.zig");
const server_client_mod = @import("server-client.zig");
const server_fn = @import("server-fn.zig");
const format_mod = @import("format.zig");
const client_registry = @import("client-registry.zig");
const resize_mod = @import("resize.zig");

const NEW_WINDOW_TEMPLATE = "#{session_name}:#{window_index}.#{pane_index}";

fn exec_selectw(cmd: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {
    const args = cmd_mod.cmd_get_args(cmd);
    var target: T.CmdFindState = .{};
    const cl = cmdq.cmdq_get_client(item);

    if (cmd_find.cmd_find_target(&target, item, args.get('t'), .window, 0) != 0)
        return .@"error";
    const s = target.s orelse return .@"error";
    const wl = target.wl orelse return .@"error";

    _ = sess.session_set_current(s, wl);
    // Update client if one is attached
    if (cl) |c| {
        if (c.session == s) {
            server_client_mod.server_client_apply_session_size(c, s);
            server_client_mod.server_client_force_redraw(c);
        }
    }
    server_fn.server_redraw_session(s);
    return .normal;
}

fn exec_neww(cmd: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {
    const args = cmd_mod.cmd_get_args(cmd);
    var target: T.CmdFindState = .{};
    if (cmd_find.cmd_find_target(&target, item, args.get('t'), .window, T.CMD_FIND_CANFAIL | T.CMD_FIND_WINDOW_INDEX) != 0)
        return .@"error";
    const s = target.s orelse return .@"error";

    if (args.has('S')) {
        if (args.get('n')) |raw_name| {
            if (target.idx == -1) {
                const existing = find_reusable_window(item, s, raw_name) catch return .@"error";
                if (existing) |wl| {
                    if (args.has('d')) return .normal;

                    _ = sess.session_set_current(s, wl);
                    server_fn.server_redraw_session(s);
                    if (cmdq.cmdq_get_client(item)) |cl| {
                        if (cl.session != null)
                            wl.window.latest = @ptrCast(cl);
                    }
                    resize_mod.recalculate_sizes();
                    return .normal;
                }
            }
        }
    }

    var cause: ?[]u8 = null;
    var sc = T.SpawnContext{
        .item = @ptrCast(item),
        .s = s,
        .idx = target.idx,
        .cwd = args.get('c'),
        .name = args.get('n'),
        .flags = 0,
    };
    if (args.has('d')) sc.flags |= T.SPAWN_DETACHED;
    if (args.has('k')) sc.flags |= T.SPAWN_KILL;
    const argv = argv_tail(args, 0);
    defer if (argv) |slice| free_argv(slice);
    if (argv) |slice| {
        sc.argv = slice;
        if (slice.len == 1 and slice[0].len == 0) sc.flags |= T.SPAWN_EMPTY;
    }
    const overlay = build_overlay_environment(args, item) catch return .@"error";
    defer if (overlay) |env| env_mod.environ_free(env);
    sc.environ = overlay;
    const wl = spawn_mod.spawn_window(&sc, &cause) orelse {
        cmdq.cmdq_error(item, "create window failed: {s}", .{cause orelse "unknown"});
        return .@"error";
    };
    if (!args.has('d')) _ = sess.session_set_current(s, wl);
    if (!args.has('d') or s.curw == wl)
        server_fn.server_redraw_session_group(s)
    else
        server_fn.server_status_session_group(s);
    if (args.has('P')) {
        const state = T.CmdFindState{
            .s = s,
            .wl = wl,
            .w = wl.window,
            .wp = wl.window.active,
            .idx = wl.idx,
        };
        const ctx = cmd_format.target_context(&state, null);
        const rendered = cmd_format.require(item, args.get('F') orelse NEW_WINDOW_TEMPLATE, &ctx) orelse return .@"error";
        defer xm.allocator.free(rendered);
        cmdq.cmdq_print(item, "{s}", .{rendered});
    }
    return .normal;
}

fn build_overlay_environment(args: *const @import("arguments.zig").Arguments, item: *cmdq.CmdqItem) !?*T.Environ {
    const env_entry = args.entry('e') orelse return null;
    const env = env_mod.environ_create();
    errdefer env_mod.environ_free(env);
    for (env_entry.values.items) |value| {
        if (std.mem.indexOfScalar(u8, value, '=')) |_| {
            env_mod.environ_put(env, value, 0);
        } else {
            cmdq.cmdq_error(item, "invalid environment: {s}", .{value});
            return error.InvalidEnvironment;
        }
    }
    return env;
}

fn find_reusable_window(item: *cmdq.CmdqItem, s: *T.Session, raw_name: []const u8) error{AmbiguousName}!?*T.Winlink {
    const expanded = format_mod.format_single(item, raw_name, cmdq.cmdq_get_client(item), s, null, null);
    defer xm.allocator.free(expanded);

    var matched: ?*T.Winlink = null;
    var it = s.windows.valueIterator();
    while (it.next()) |match_entry| {
        const wl = match_entry.*;
        if (!std.mem.eql(u8, wl.window.name, expanded)) continue;
        if (matched != null) {
            cmdq.cmdq_error(item, "multiple windows named {s}", .{raw_name});
            return error.AmbiguousName;
        }
        matched = wl;
    }
    return matched;
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

fn init_test_state() void {
    const opts = @import("options.zig");

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

fn deinit_test_state() void {
    const opts = @import("options.zig");

    env_mod.environ_free(env_mod.global_environ);
    opts.options_free(opts.global_w_options);
    opts.options_free(opts.global_s_options);
    opts.options_free(opts.global_options);
}

pub const entry: cmd_mod.CmdEntry = .{
    .name = "select-window",
    .alias = "selectw",
    .usage = "[-lnpT] [-t target-window]",
    .template = "lnpTt:",
    .lower = 0,
    .upper = 0,
    .flags = 0,
    .exec = exec_selectw,
};

pub const entry_neww: cmd_mod.CmdEntry = .{
    .name = "new-window",
    .alias = "neww",
    .usage = "[-abdkPS] [-c start-directory] [-e environment] [-F format] [-n window-name] [-t target-session] [shell-command]",
    .template = "abc:dF:kn:St:P",
    .lower = 0,
    .upper = -1,
    .flags = 0,
    .exec = exec_neww,
};

test "new-window synchronizes grouped peers and uses shared group status-only invalidation for detached creates" {
    const opts = @import("options.zig");

    init_test_state();
    defer deinit_test_state();

    client_registry.clients.clearRetainingCapacity();
    defer client_registry.clients.clearRetainingCapacity();

    const leader = sess.session_create(null, "new-window-group-a", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("new-window-group-a") != null) sess.session_destroy(leader, false, "test");
    const peer = sess.session_create(null, "new-window-group-b", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("new-window-group-b") != null) sess.session_destroy(peer, false, "test");

    const group = sess.session_group_new("new-window-group");
    sess.session_group_add(group, leader);
    sess.session_group_add(group, peer);

    var cause: ?[]u8 = null;
    var initial_sc: T.SpawnContext = .{ .s = leader, .idx = -1, .flags = T.SPAWN_EMPTY };
    const initial_wl = spawn_mod.spawn_window(&initial_sc, &cause).?;
    leader.curw = initial_wl;
    peer.curw = sess.winlink_find_by_index(&peer.windows, initial_wl.idx).?;

    var leader_client = T.Client{
        .name = "new-window-group-leader",
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{ .screen = undefined },
        .flags = T.CLIENT_ATTACHED,
        .session = leader,
    };
    defer env_mod.environ_free(leader_client.environ);
    leader_client.tty.client = &leader_client;

    var peer_client = T.Client{
        .name = "new-window-group-peer",
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{ .screen = undefined },
        .flags = T.CLIENT_ATTACHED,
        .session = peer,
    };
    defer env_mod.environ_free(peer_client.environ);
    peer_client.tty.client = &peer_client;

    client_registry.add(&leader_client);
    client_registry.add(&peer_client);

    const cmd = try cmd_mod.cmd_parse_one(&.{ "new-window", "-d", "-t", "new-window-group-a" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &leader_client, .target_client = &leader_client, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, exec_neww(cmd, &item));

    try std.testing.expectEqual(@as(usize, 2), leader.windows.count());
    try std.testing.expectEqual(@as(usize, 2), peer.windows.count());
    try std.testing.expectEqual(initial_wl.idx, peer.curw.?.idx);
    try std.testing.expect(leader_client.flags & T.CLIENT_REDRAWSTATUS != 0);
    try std.testing.expect(peer_client.flags & T.CLIENT_REDRAWSTATUS != 0);
    try std.testing.expect(leader_client.flags & T.CLIENT_REDRAWWINDOW == 0);
    try std.testing.expect(peer_client.flags & T.CLIENT_REDRAWWINDOW == 0);
}

test "new-window -S -n reuses one matching existing window" {
    init_test_state();
    defer deinit_test_state();

    client_registry.clients.clearRetainingCapacity();
    defer client_registry.clients.clearRetainingCapacity();

    const session = sess.session_create(null, "new-window-reuse", "/", env_mod.environ_create(), @import("options.zig").options_create(@import("options.zig").global_s_options), null);
    defer if (sess.session_find("new-window-reuse") != null) sess.session_destroy(session, false, "test");

    var cause: ?[]u8 = null;
    var first_sc: T.SpawnContext = .{ .s = session, .idx = -1, .flags = T.SPAWN_EMPTY };
    const current_wl = spawn_mod.spawn_window(&first_sc, &cause).?;
    win_mod.window_set_name(current_wl.window, "current");

    var second_sc: T.SpawnContext = .{ .s = session, .idx = -1, .flags = T.SPAWN_EMPTY };
    const existing_wl = spawn_mod.spawn_window(&second_sc, &cause).?;
    win_mod.window_set_name(existing_wl.window, "shared");
    session.curw = current_wl;

    var client = T.Client{
        .name = "new-window-reuse-client",
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{ .screen = undefined },
        .flags = T.CLIENT_ATTACHED,
        .session = session,
    };
    defer {
        if (client.message_string) |message| xm.allocator.free(message);
        env_mod.environ_free(client.environ);
    }
    client.tty.client = &client;
    client_registry.add(&client);

    const cmd = try cmd_mod.cmd_parse_one(&.{ "new-window", "-S", "-n", "shared" }, &client, &cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &client, .target_client = &client, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, exec_neww(cmd, &item));

    try std.testing.expectEqual(@as(usize, 2), session.windows.count());
    try std.testing.expectEqual(existing_wl, session.curw.?);
    try std.testing.expectEqual(@as(?*anyopaque, @ptrCast(&client)), existing_wl.window.latest);
}

test "new-window -S -n errors when multiple windows share the name" {
    init_test_state();
    defer deinit_test_state();

    client_registry.clients.clearRetainingCapacity();
    defer client_registry.clients.clearRetainingCapacity();

    const session = sess.session_create(null, "new-window-reuse-ambiguous", "/", env_mod.environ_create(), @import("options.zig").options_create(@import("options.zig").global_s_options), null);
    defer if (sess.session_find("new-window-reuse-ambiguous") != null) sess.session_destroy(session, false, "test");

    var cause: ?[]u8 = null;
    var current_sc: T.SpawnContext = .{ .s = session, .idx = -1, .flags = T.SPAWN_EMPTY };
    const current_wl = spawn_mod.spawn_window(&current_sc, &cause).?;
    win_mod.window_set_name(current_wl.window, "current");

    var first_match_sc: T.SpawnContext = .{ .s = session, .idx = -1, .flags = T.SPAWN_EMPTY };
    const first_match = spawn_mod.spawn_window(&first_match_sc, &cause).?;
    win_mod.window_set_name(first_match.window, "dup");

    var second_match_sc: T.SpawnContext = .{ .s = session, .idx = -1, .flags = T.SPAWN_EMPTY };
    const second_match = spawn_mod.spawn_window(&second_match_sc, &cause).?;
    win_mod.window_set_name(second_match.window, "dup");
    session.curw = current_wl;

    var client = T.Client{
        .name = "new-window-reuse-ambiguous-client",
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{ .screen = undefined },
        .flags = T.CLIENT_ATTACHED,
        .session = session,
    };
    defer {
        if (client.message_string) |message| xm.allocator.free(message);
        env_mod.environ_free(client.environ);
    }
    client.tty.client = &client;
    client_registry.add(&client);

    const cmd = try cmd_mod.cmd_parse_one(&.{ "new-window", "-S", "-n", "dup" }, &client, &cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &client, .target_client = &client, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.@"error", exec_neww(cmd, &item));

    try std.testing.expectEqual(@as(usize, 3), session.windows.count());
    try std.testing.expectEqual(current_wl, session.curw.?);
    try std.testing.expectEqualStrings("Multiple windows named dup", client.message_string.?);
}

test "new-window rejects occupied target index without -k" {
    init_test_state();
    defer deinit_test_state();

    client_registry.clients.clearRetainingCapacity();
    defer client_registry.clients.clearRetainingCapacity();

    const session = sess.session_create(null, "new-window-index-in-use", "/", env_mod.environ_create(), @import("options.zig").options_create(@import("options.zig").global_s_options), null);
    defer if (sess.session_find("new-window-index-in-use") != null) sess.session_destroy(session, false, "test");

    var cause: ?[]u8 = null;
    var occupied_sc: T.SpawnContext = .{ .s = session, .idx = -1, .flags = T.SPAWN_EMPTY };
    const occupied_wl = spawn_mod.spawn_window(&occupied_sc, &cause).?;
    session.curw = occupied_wl;

    const cmd = try cmd_mod.cmd_parse_one(&.{ "new-window", "-d", "-t", "new-window-index-in-use:0" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.@"error", cmd_mod.cmd_execute(cmd, &item));

    try std.testing.expectEqual(@as(usize, 1), session.windows.count());
    try std.testing.expectEqual(occupied_wl, session.curw.?);
}

test "new-window -d -k replaces the current target slot and selects the replacement" {
    init_test_state();
    defer deinit_test_state();

    client_registry.clients.clearRetainingCapacity();
    defer client_registry.clients.clearRetainingCapacity();

    const session = sess.session_create(null, "new-window-kill-existing", "/", env_mod.environ_create(), @import("options.zig").options_create(@import("options.zig").global_s_options), null);
    defer if (sess.session_find("new-window-kill-existing") != null) sess.session_destroy(session, false, "test");

    var cause: ?[]u8 = null;
    var current_sc: T.SpawnContext = .{ .s = session, .idx = -1, .flags = T.SPAWN_EMPTY };
    const current_wl = spawn_mod.spawn_window(&current_sc, &cause).?;
    const replaced_window_id = current_wl.window.id;
    var other_sc: T.SpawnContext = .{ .s = session, .idx = -1, .flags = T.SPAWN_EMPTY };
    _ = spawn_mod.spawn_window(&other_sc, &cause).?;
    session.curw = current_wl;

    const cmd = try cmd_mod.cmd_parse_one(&.{ "new-window", "-d", "-k", "-t", "new-window-kill-existing:0" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));

    const replacement = sess.winlink_find_by_index(&session.windows, 0).?;
    try std.testing.expectEqual(@as(usize, 2), session.windows.count());
    try std.testing.expect(replacement.window.id != replaced_window_id);
    try std.testing.expectEqual(replacement, session.curw.?);
}
