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
const notify = @import("notify.zig");
const resize_mod = @import("resize.zig");
const tty_mod = @import("tty.zig");

const NEW_WINDOW_TEMPLATE = "#{session_name}:#{window_index}.#{pane_index}";

fn exec_selectw(cmd: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {
    const args = cmd_mod.cmd_get_args(cmd);
    const cl = cmdq.cmdq_get_client(item);
    const state = cmdq.cmdq_get_state(item);
    const entry_ptr = cmd.entry;
    const dedicated_cycle = entry_ptr == &entry_next or entry_ptr == &entry_previous or entry_ptr == &entry_last;
    const next = entry_ptr == &entry_next or args.has('n');
    const previous = entry_ptr == &entry_previous or args.has('p');
    const last = entry_ptr == &entry_last or args.has('l');

    var target: T.CmdFindState = .{};
    const find_type: T.CmdFindType = if (dedicated_cycle) .session else .window;

    if (cmd_find.cmd_find_target(&target, item, args.get('t'), find_type, 0) != 0)
        return .@"error";
    const s = target.s orelse return .@"error";
    const wl = target.wl;

    if (next) {
        if (!sess.session_next(s, args.has('a'))) {
            cmdq.cmdq_error(item, "no next window", .{});
            return .@"error";
        }
        cmd_find.cmd_find_from_session(&state.current, s, 0);
    } else if (previous) {
        if (!sess.session_previous(s, args.has('a'))) {
            cmdq.cmdq_error(item, "no previous window", .{});
            return .@"error";
        }
        cmd_find.cmd_find_from_session(&state.current, s, 0);
    } else if (last or (args.has('T') and wl != null and wl == s.curw)) {
        if (!sess.session_last(s)) {
            cmdq.cmdq_error(item, "no last window", .{});
            return .@"error";
        }
        if (state.current.s == s)
            cmd_find.cmd_find_from_session(&state.current, s, 0);
    } else if (sess.session_select(s, (wl orelse return .@"error").idx)) {
        cmd_find.cmd_find_from_session(&state.current, s, 0);
    }

    if (cl) |c| {
        if (c.session != null and s.curw != null)
            s.curw.?.window.latest = @ptrCast(c);
        if (c.session == s) {
            server_client_mod.server_client_apply_session_size(c, s);
            server_client_mod.server_client_force_redraw(c);
        }
    }
    server_fn.server_redraw_session(s);
    notify.notify_hook(item, "after-select-window", &state.current);
    resize_mod.recalculate_sizes();
    return .normal;
}

fn exec_neww(cmd: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {
    const args = cmd_mod.cmd_get_args(cmd);
    var target: T.CmdFindState = .{};
    if (cmd_find.cmd_find_target(&target, item, args.get('t'), .window, T.CMD_FIND_CANFAIL | T.CMD_FIND_WINDOW_INDEX) != 0)
        return .@"error";
    const s = target.s orelse return .@"error";
    var idx = target.idx;

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

    const before = args.has('b');
    if (args.has('a') or before) {
        idx = sess.winlink_shuffle_up(s, target.wl, before);
        if (idx == -1)
            idx = target.idx;
    }

    var cause: ?[]u8 = null;
    var sc = T.SpawnContext{
        .item = @ptrCast(item),
        .s = s,
        .idx = idx,
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

    var hook_state: T.CmdFindState = .{ .idx = -1 };
    std.debug.assert(cmd_find.cmd_find_from_winlink(&hook_state, wl, 0));
    notify.notify_hook(item, "after-new-window", &hook_state);

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

pub const entry_next: cmd_mod.CmdEntry = .{
    .name = "next-window",
    .alias = "next",
    .usage = "[-a] [-t target-session]",
    .template = "at:",
    .lower = 0,
    .upper = 0,
    .flags = 0,
    .exec = exec_selectw,
};

pub const entry_previous: cmd_mod.CmdEntry = .{
    .name = "previous-window",
    .alias = "prev",
    .usage = "[-a] [-t target-session]",
    .template = "at:",
    .lower = 0,
    .upper = 0,
    .flags = 0,
    .exec = exec_selectw,
};

pub const entry_last: cmd_mod.CmdEntry = .{
    .name = "last-window",
    .alias = "last",
    .usage = "[-t target-session]",
    .template = "t:",
    .lower = 0,
    .upper = 0,
    .flags = 0,
    .exec = exec_selectw,
};

pub const entry_neww: cmd_mod.CmdEntry = .{
    .name = "new-window",
    .alias = "neww",
    .usage = "[-abdkPS] [-c start-directory] [-e environment] [-F format] [-n window-name] [-t target-window] [shell-command]",
    .template = "abc:de:F:kn:PSt:",
    .lower = 0,
    .upper = -1,
    .flags = 0,
    .exec = exec_neww,
};

fn make_select_window_test_session(name: []const u8) struct {
    session: *T.Session,
    first: *T.Winlink,
    second: *T.Winlink,
    third: *T.Winlink,
} {
    const opts = @import("options.zig");

    const session = sess.session_create(null, name, "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    var cause: ?[]u8 = null;

    var first_sc: T.SpawnContext = .{ .s = session, .idx = -1, .flags = T.SPAWN_EMPTY };
    const first = spawn_mod.spawn_window(&first_sc, &cause).?;
    var second_sc: T.SpawnContext = .{ .s = session, .idx = -1, .flags = T.SPAWN_EMPTY };
    const second = spawn_mod.spawn_window(&second_sc, &cause).?;
    var third_sc: T.SpawnContext = .{ .s = session, .idx = -1, .flags = T.SPAWN_EMPTY };
    const third = spawn_mod.spawn_window(&third_sc, &cause).?;

    session.curw = first;
    return .{
        .session = session,
        .first = first,
        .second = second,
        .third = third,
    };
}

test "select-window honors next previous last and toggle flags" {
    init_test_state();
    defer deinit_test_state();

    const setup = make_select_window_test_session("select-window-cycle");
    defer if (sess.session_find("select-window-cycle") != null) sess.session_destroy(setup.session, false, "test");

    var cause: ?[]u8 = null;

    const next_cmd = try cmd_mod.cmd_parse_one(&.{ "select-window", "-n", "-t", "select-window-cycle:0" }, null, &cause);
    defer cmd_mod.cmd_free(next_cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(next_cmd, &item));
    try std.testing.expectEqual(setup.second, setup.session.curw.?);
    try std.testing.expectEqual(@as(usize, 1), setup.session.lastw.items.len);
    try std.testing.expectEqual(setup.first, setup.session.lastw.items[0]);

    const previous_cmd = try cmd_mod.cmd_parse_one(&.{ "select-window", "-p", "-t", "select-window-cycle:1" }, null, &cause);
    defer cmd_mod.cmd_free(previous_cmd);
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(previous_cmd, &item));
    try std.testing.expectEqual(setup.first, setup.session.curw.?);

    const last_cmd = try cmd_mod.cmd_parse_one(&.{ "last-window", "-t", "select-window-cycle" }, null, &cause);
    defer cmd_mod.cmd_free(last_cmd);
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(last_cmd, &item));
    try std.testing.expectEqual(setup.second, setup.session.curw.?);

    const toggle_cmd = try cmd_mod.cmd_parse_one(&.{ "select-window", "-T", "-t", "select-window-cycle:1" }, null, &cause);
    defer cmd_mod.cmd_free(toggle_cmd);
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(toggle_cmd, &item));
    try std.testing.expectEqual(setup.first, setup.session.curw.?);
}

test "next-window and previous-window honor alert-only selection" {
    init_test_state();
    defer deinit_test_state();

    const setup = make_select_window_test_session("select-window-alerts");
    defer if (sess.session_find("select-window-alerts") != null) sess.session_destroy(setup.session, false, "test");

    setup.first.flags |= T.WINLINK_ACTIVITY;
    setup.third.flags |= T.WINLINK_BELL;
    setup.session.curw = setup.first;

    var cause: ?[]u8 = null;
    const next_cmd = try cmd_mod.cmd_parse_one(&.{ "next-window", "-a", "-t", "select-window-alerts" }, null, &cause);
    defer cmd_mod.cmd_free(next_cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(next_cmd, &item));
    try std.testing.expectEqual(setup.third, setup.session.curw.?);

    const previous_cmd = try cmd_mod.cmd_parse_one(&.{ "previous-window", "-a", "-t", "select-window-alerts" }, null, &cause);
    defer cmd_mod.cmd_free(previous_cmd);
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(previous_cmd, &item));
    try std.testing.expectEqual(setup.first, setup.session.curw.?);
}

test "select-window queues after-select-window hooks for direct, cycle, and toggle paths" {
    const opts = @import("options.zig");

    cmdq.cmdq_reset_for_tests();
    defer cmdq.cmdq_reset_for_tests();

    init_test_state();
    defer deinit_test_state();

    opts.options_set_array(opts.global_s_options, "after-select-window", &.{
        "set-environment -g -F AFTER_SELECT_WINDOW '#{session_name}:#{window_index}'",
    });

    const setup = make_select_window_test_session("select-window-hook");
    defer if (sess.session_find("select-window-hook") != null) sess.session_destroy(setup.session, false, "test");

    while (cmdq.cmdq_next(null) != 0) {}

    var direct_cause: ?[]u8 = null;
    const direct_list = try cmd_mod.cmd_parse_from_argv_with_cause(&.{ "select-window", "-t", "select-window-hook:2" }, null, &direct_cause);
    defer if (direct_cause) |msg| xm.allocator.free(msg);
    cmdq.cmdq_append(null, direct_list);
    while (cmdq.cmdq_next(null) != 0) {}
    try std.testing.expectEqualStrings("select-window-hook:2", env_mod.environ_find(env_mod.global_environ, "AFTER_SELECT_WINDOW").?.value.?);

    env_mod.environ_unset(env_mod.global_environ, "AFTER_SELECT_WINDOW");

    var cycle_cause: ?[]u8 = null;
    const cycle_list = try cmd_mod.cmd_parse_from_argv_with_cause(&.{ "next-window", "-t", "select-window-hook" }, null, &cycle_cause);
    defer if (cycle_cause) |msg| xm.allocator.free(msg);
    cmdq.cmdq_append(null, cycle_list);
    while (cmdq.cmdq_next(null) != 0) {}
    try std.testing.expectEqualStrings("select-window-hook:0", env_mod.environ_find(env_mod.global_environ, "AFTER_SELECT_WINDOW").?.value.?);

    env_mod.environ_unset(env_mod.global_environ, "AFTER_SELECT_WINDOW");

    var current: T.CmdFindState = .{ .idx = -1 };
    cmd_find.cmd_find_from_session(&current, setup.session, 0);
    const state = cmdq.cmdq_new_state(&current, null, 0);
    defer cmdq.cmdq_free_state(state);

    var toggle_cause: ?[]u8 = null;
    const toggle_cmd = try cmd_mod.cmd_parse_one(&.{ "select-window", "-T", "-t", "select-window-hook:0" }, null, &toggle_cause);
    defer cmd_mod.cmd_free(toggle_cmd);
    defer if (toggle_cause) |msg| xm.allocator.free(msg);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .cmdlist = &list, .state = state };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(toggle_cmd, &item));
    try std.testing.expectEqualStrings("select-window-hook:2", env_mod.environ_find(env_mod.global_environ, "AFTER_SELECT_WINDOW").?.value.?);
}

test "select-window records latest client on the newly selected window across sessions" {
    init_test_state();
    defer deinit_test_state();

    client_registry.clients.clearRetainingCapacity();
    defer client_registry.clients.clearRetainingCapacity();

    const driver = make_select_window_test_session("select-window-latest-driver");
    defer if (sess.session_find("select-window-latest-driver") != null) sess.session_destroy(driver.session, false, "test");

    const target = make_select_window_test_session("select-window-latest-target");
    defer if (sess.session_find("select-window-latest-target") != null) sess.session_destroy(target.session, false, "test");

    var client = T.Client{
        .name = "select-window-latest-client",
        .environ = env_mod.environ_create(),
        .tty = .{ .client = undefined },
        .status = .{ .screen = undefined },
        .flags = T.CLIENT_ATTACHED,
        .session = driver.session,
    };
    defer {
        if (client.message_string) |message| xm.allocator.free(message);
        env_mod.environ_free(client.environ);
    }
    tty_mod.tty_init(&client.tty, &client);
    client_registry.add(&client);

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "select-window", "-t", "select-window-latest-target:1" }, &client, &cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &client, .target_client = &client, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));

    try std.testing.expectEqual(target.second, target.session.curw.?);
    try std.testing.expectEqual(@as(?*anyopaque, @ptrCast(&client)), target.second.window.latest);
    try std.testing.expectEqual(driver.first, driver.session.curw.?);
}

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
        .tty = .{ .client = undefined },
        .status = .{ .screen = undefined },
        .flags = T.CLIENT_ATTACHED,
        .session = leader,
    };
    defer env_mod.environ_free(leader_client.environ);
    tty_mod.tty_init(&leader_client.tty, &leader_client);

    var peer_client = T.Client{
        .name = "new-window-group-peer",
        .environ = env_mod.environ_create(),
        .tty = .{ .client = undefined },
        .status = .{ .screen = undefined },
        .flags = T.CLIENT_ATTACHED,
        .session = peer,
    };
    defer env_mod.environ_free(peer_client.environ);
    tty_mod.tty_init(&peer_client.tty, &peer_client);

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
        .tty = .{ .client = undefined },
        .status = .{ .screen = undefined },
        .flags = T.CLIENT_ATTACHED,
        .session = session,
    };
    defer {
        if (client.message_string) |message| xm.allocator.free(message);
        env_mod.environ_free(client.environ);
    }
    tty_mod.tty_init(&client.tty, &client);
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
        .tty = .{ .client = undefined },
        .status = .{ .screen = undefined },
        .flags = T.CLIENT_ATTACHED,
        .session = session,
    };
    defer {
        if (client.message_string) |message| xm.allocator.free(message);
        env_mod.environ_free(client.environ);
    }
    tty_mod.tty_init(&client.tty, &client);
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

test "new-window -d -a inserts after the target window and shifts following indexes" {
    init_test_state();
    defer deinit_test_state();

    client_registry.clients.clearRetainingCapacity();
    defer client_registry.clients.clearRetainingCapacity();

    const session = sess.session_create(null, "new-window-after-target", "/", env_mod.environ_create(), @import("options.zig").options_create(@import("options.zig").global_s_options), null);
    defer if (sess.session_find("new-window-after-target") != null) sess.session_destroy(session, false, "test");

    var cause: ?[]u8 = null;
    var first_sc: T.SpawnContext = .{ .s = session, .idx = -1, .flags = T.SPAWN_EMPTY };
    const first_wl = spawn_mod.spawn_window(&first_sc, &cause).?;
    var second_sc: T.SpawnContext = .{ .s = session, .idx = -1, .flags = T.SPAWN_EMPTY };
    const second_wl = spawn_mod.spawn_window(&second_sc, &cause).?;
    var third_sc: T.SpawnContext = .{ .s = session, .idx = -1, .flags = T.SPAWN_EMPTY };
    const third_wl = spawn_mod.spawn_window(&third_sc, &cause).?;
    session.curw = second_wl;

    const cmd = try cmd_mod.cmd_parse_one(&.{ "new-window", "-d", "-a", "-t", "new-window-after-target:0" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));

    const inserted = sess.winlink_find_by_index(&session.windows, 1).?;
    try std.testing.expectEqual(@as(usize, 4), session.windows.count());
    try std.testing.expect(inserted != first_wl);
    try std.testing.expect(inserted != second_wl);
    try std.testing.expect(inserted != third_wl);
    try std.testing.expectEqual(@as(i32, 0), first_wl.idx);
    try std.testing.expectEqual(@as(i32, 2), second_wl.idx);
    try std.testing.expectEqual(@as(i32, 3), third_wl.idx);
    try std.testing.expectEqual(second_wl, session.curw.?);
}

test "new-window -d -b inserts before the target window and shifts that slot upward" {
    init_test_state();
    defer deinit_test_state();

    client_registry.clients.clearRetainingCapacity();
    defer client_registry.clients.clearRetainingCapacity();

    const session = sess.session_create(null, "new-window-before-target", "/", env_mod.environ_create(), @import("options.zig").options_create(@import("options.zig").global_s_options), null);
    defer if (sess.session_find("new-window-before-target") != null) sess.session_destroy(session, false, "test");

    var cause: ?[]u8 = null;
    var first_sc: T.SpawnContext = .{ .s = session, .idx = -1, .flags = T.SPAWN_EMPTY };
    const first_wl = spawn_mod.spawn_window(&first_sc, &cause).?;
    var second_sc: T.SpawnContext = .{ .s = session, .idx = -1, .flags = T.SPAWN_EMPTY };
    const second_wl = spawn_mod.spawn_window(&second_sc, &cause).?;
    var third_sc: T.SpawnContext = .{ .s = session, .idx = -1, .flags = T.SPAWN_EMPTY };
    const third_wl = spawn_mod.spawn_window(&third_sc, &cause).?;
    session.curw = second_wl;

    const cmd = try cmd_mod.cmd_parse_one(&.{ "new-window", "-d", "-b", "-t", "new-window-before-target:1" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));

    const inserted = sess.winlink_find_by_index(&session.windows, 1).?;
    try std.testing.expectEqual(@as(usize, 4), session.windows.count());
    try std.testing.expect(inserted != first_wl);
    try std.testing.expect(inserted != second_wl);
    try std.testing.expect(inserted != third_wl);
    try std.testing.expectEqual(@as(i32, 0), first_wl.idx);
    try std.testing.expectEqual(@as(i32, 2), second_wl.idx);
    try std.testing.expectEqual(@as(i32, 3), third_wl.idx);
    try std.testing.expectEqual(second_wl, session.curw.?);
}

test "new-window queues after-new-window hook with the new window context" {
    const opts = @import("options.zig");

    cmdq.cmdq_reset_for_tests();
    defer cmdq.cmdq_reset_for_tests();

    init_test_state();
    defer deinit_test_state();

    opts.options_set_array(opts.global_s_options, "after-new-window", &.{
        "set-environment -g -F NEW_WINDOW_HOOK '#{session_name}:#{window_name}:#{window_index}'",
    });

    const session = sess.session_create(null, "new-window-hook", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("new-window-hook") != null) sess.session_destroy(session, false, "test");

    var cause: ?[]u8 = null;
    var initial_sc: T.SpawnContext = .{ .s = session, .idx = -1, .flags = T.SPAWN_EMPTY };
    const initial_wl = spawn_mod.spawn_window(&initial_sc, &cause).?;
    session.curw = initial_wl;

    while (cmdq.cmdq_next(null) != 0) {}

    const list = try cmd_mod.cmd_parse_from_argv_with_cause(&.{ "new-window", "-d", "-t", "new-window-hook", "-n", "hooked-window" }, null, &cause);
    defer if (cause) |msg| xm.allocator.free(msg);

    cmdq.cmdq_append(null, list);
    while (cmdq.cmdq_next(null) != 0) {}

    var hooked_wl: ?*T.Winlink = null;
    var it = session.windows.valueIterator();
    while (it.next()) |match| {
        if (std.mem.eql(u8, match.*.window.name, "hooked-window")) {
            hooked_wl = match.*;
            break;
        }
    }

    const wl = hooked_wl orelse return error.TestExpectedEqual;
    const expected = try std.fmt.allocPrint(xm.allocator, "{s}:{s}:{d}", .{
        session.name,
        wl.window.name,
        wl.idx,
    });
    defer xm.allocator.free(expected);

    try std.testing.expectEqualStrings(expected, env_mod.environ_find(env_mod.global_environ, "NEW_WINDOW_HOOK").?.value.?);
}

test "new-window applies repeated -e overlays to the spawned pane" {
    const opts = @import("options.zig");
    const respawn_cmd = @import("cmd-respawn-pane.zig");

    init_test_state();
    defer deinit_test_state();

    const session = sess.session_create(null, "new-window-env", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("new-window-env") != null) sess.session_destroy(session, false, "test");

    var cause: ?[]u8 = null;
    var root_ctx: T.SpawnContext = .{ .s = session, .idx = -1, .flags = T.SPAWN_EMPTY };
    _ = spawn_mod.spawn_window(&root_ctx, &cause).?;

    const cmd = try cmd_mod.cmd_parse_one(&.{
        "new-window",
        "-d",
        "-n",
        "env-window",
        "-e",
        "FOO=first",
        "-e",
        "FOO=second",
        "-e",
        "BAR=ok",
        "-t",
        "new-window-env",
        "printf '%s %s' \"$FOO\" \"$BAR\"",
    }, null, &cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));

    std.Thread.sleep(500 * std.time.ns_per_ms);
    const wl = sess.winlink_find_by_index(&session.windows, 1).?;
    try std.testing.expectEqualStrings("env-window", wl.window.name);
    const output = respawn_cmd.read_pane_output(wl.window.active.?);
    defer xm.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "second ok") != null);
}
