// Copyright (c) 2026 Greg Turner <gmt@be-evil.net>
// ISC licence – see COPYING.
//
// Ported from tmux/cmd-switch-client.c
// Original copyright:
//   Copyright (c) 2007 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const cmd_mod = @import("cmd.zig");
const cmdq = @import("cmd-queue.zig");
const cmd_find = @import("cmd-find.zig");
const key_bindings = @import("key-bindings.zig");
const sess = @import("session.zig");
const sort_mod = @import("sort.zig");
const env_mod = @import("environ.zig");
const opts = @import("options.zig");
const server_client_mod = @import("server-client.zig");
const server_fn = @import("server-fn.zig");
const status_runtime = @import("status-runtime.zig");
const win_mod = @import("window.zig");

fn toggleReadonlyFlags(cl: *T.Client) void {
    if (cl.flags & T.CLIENT_READONLY != 0)
        cl.flags &= ~(T.CLIENT_READONLY | T.CLIENT_IGNORESIZE)
    else
        cl.flags |= T.CLIENT_READONLY | T.CLIENT_IGNORESIZE;
}

const TargetLookup = struct {
    find_type: T.CmdFindType,
    flags: u32,
};

fn switchClientTargetLookup(tflag: ?[]const u8) TargetLookup {
    const target = tflag orelse return .{
        .find_type = .session,
        .flags = T.CMD_FIND_PREFER_UNATTACHED,
    };

    if (std.mem.eql(u8, target, "=") or std.mem.indexOfAny(u8, target, ":.%") != null) {
        return .{
            .find_type = .pane,
            .flags = 0,
        };
    }

    return .{
        .find_type = .session,
        .flags = T.CMD_FIND_PREFER_UNATTACHED,
    };
}

fn switchClientResetKeyTable(item: *cmdq.CmdqItem, cl: *T.Client) void {
    if ((cmdq.cmdq_get_flags(item) & T.CMDQ_STATE_REPEAT) == 0)
        server_client_mod.server_client_set_key_table(cl, null);
}

fn switchClientFinish(item: *cmdq.CmdqItem, args: *const @import("arguments.zig").Arguments, cl: *T.Client, s: *T.Session) T.CmdRetval {
    const same_session = cl.session == s;

    if (!args.has('E'))
        env_mod.environ_update(s.options, cl.environ, s.environ);

    server_client_mod.server_client_set_session(cl, s);
    switchClientResetKeyTable(item, cl);
    if (same_session)
        server_client_mod.server_client_force_redraw(cl);
    server_fn.server_redraw_session(s);
    return .normal;
}

fn exec(cmd: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {
    const args = cmd_mod.cmd_get_args(cmd);
    const tc = cmdq.cmdq_get_target_client(item) orelse cmdq.cmdq_get_client(item);
    const cl = cmdq.cmdq_get_client(item);

    if (args.has('r')) {
        if (tc) |c| toggleReadonlyFlags(c);
    }

    if (args.get('T')) |tablename| {
        const table = key_bindings.key_bindings_get_table(tablename, false) orelse {
            cmdq.cmdq_error(item, "table {s} doesn't exist", .{tablename});
            return .@"error";
        };
        if (tc) |c| server_client_mod.server_client_set_key_table(c, table.name);
        return .normal;
    }

    const sort_crit = T.SortCriteria{
        .order = sort_mod.sort_order_from_string(args.get('O')),
        .reversed = args.has('r'),
    };
    if (sort_crit.order == .end and args.has('O')) {
        cmdq.cmdq_error(item, "invalid sort order", .{});
        return .@"error";
    }

    var target: T.CmdFindState = .{};
    const tflag = args.get('t');
    const target_lookup = switchClientTargetLookup(tflag);
    if (cmd_find.cmd_find_target(&target, item, tflag, target_lookup.find_type, target_lookup.flags) != 0) {
        return .@"error";
    }

    var s = target.s orelse {
        cmdq.cmdq_error(item, "no session", .{});
        return .@"error";
    };
    const wl = target.wl;
    const wp = target.wp;

    if (args.has('n')) {
        const cur_s = if (tc) |c| c.session else null;
        s = if (cur_s) |cs|
            sess.session_next_session(cs, &sort_crit) orelse {
                cmdq.cmdq_error(item, "can't find next session", .{});
                return .@"error";
            }
        else {
            cmdq.cmdq_error(item, "can't find next session", .{});
            return .@"error";
        };
    } else if (args.has('p')) {
        const cur_s = if (tc) |c| c.session else null;
        s = if (cur_s) |cs|
            sess.session_previous_session(cs, &sort_crit) orelse {
                cmdq.cmdq_error(item, "can't find previous session", .{});
                return .@"error";
            }
        else {
            cmdq.cmdq_error(item, "can't find previous session", .{});
            return .@"error";
        };
    } else if (args.has('l')) {
        const last_session = if (tc) |c| blk: {
            if (c.last_session) |ls| {
                if (sess.session_alive(ls))
                    break :blk ls;
            }
            break :blk null;
        } else null;
        s = last_session orelse {
            cmdq.cmdq_error(item, "can't find last session", .{});
            return .@"error";
        };
    } else {
        if (cl == null)
            return .normal;

        if (wl != null and wp != null and wp.? != wl.?.window.active) {
            const w = wl.?.window;
            if (win_mod.window_push_zoom(w, false, args.has('Z')))
                server_fn.server_redraw_window(w);
            win_mod.window_redraw_active_switch(w, wp.?);
            _ = win_mod.window_set_active_pane(w, wp.?, true);
            if (win_mod.window_pop_zoom(w))
                server_fn.server_redraw_window(w);
        }
        if (wl) |target_wl| {
            _ = sess.session_set_current(s, target_wl);
            cmd_find.cmd_find_from_session(&cmdq.cmdq_get_state(item).current, s, 0);
        }
    }

    const target_client = tc orelse return .normal;
    return switchClientFinish(item, args, target_client, s);
}

pub const entry: cmd_mod.CmdEntry = .{
    .name = "switch-client",
    .alias = "switchc",
    .usage = "[-ElnprZ] [-c target-client] [-t target-session] [-T key-table] [-O order]",
    .template = "c:EFlnO:pt:rT:Z",
    .lower = 0,
    .upper = 0,
    .flags = T.CMD_READONLY | T.CMD_CLIENT_CFLAG,
    .exec = exec,
};

fn switchClientTestInit() void {
    sess.session_init_globals(xm.allocator);
    win_mod.window_init_globals(xm.allocator);

    opts.global_options = opts.options_create(null);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.global_s_options = opts.options_create(null);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.global_w_options = opts.options_create(null);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);

    env_mod.global_environ = env_mod.environ_create();
    key_bindings.key_bindings_init();
}

fn switchClientTestFinish() void {
    env_mod.environ_free(env_mod.global_environ);
    opts.options_free(opts.global_options);
    opts.options_free(opts.global_s_options);
    opts.options_free(opts.global_w_options);
}

fn switchClientTestMakeSession(name: []const u8) struct {
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

fn switchClientTestFreeSession(setup: *@TypeOf(switchClientTestMakeSession("unused"))) void {
    if (sess.session_find(setup.session.name) != null) sess.session_destroy(setup.session, false, "test");
    win_mod.window_remove_ref(setup.window, "test");
}

fn switchClientTestMakeClient(name: []const u8, session: ?*T.Session) T.Client {
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

fn switchClientTestFreeClient(client: *T.Client) void {
    status_runtime.status_message_clear(client);
    status_runtime.status_cleanup(client);
    if (client.session) |s| {
        if (s.attached > 0) s.attached -= 1;
    }
    env_mod.environ_free(client.environ);
    if (client.name) |name| xm.allocator.free(@constCast(name));
    if (client.key_table_name) |name| xm.allocator.free(name);
}

test "switch-client -T selects an existing key table" {
    switchClientTestInit();
    defer switchClientTestFinish();

    var setup = switchClientTestMakeSession("switch-client-table");
    defer switchClientTestFreeSession(&setup);

    var client = switchClientTestMakeClient("switch-client-table-client", setup.session);
    defer switchClientTestFreeClient(&client);

    _ = key_bindings.key_bindings_get_table("copy-mode-test", true);

    var cause: ?[]u8 = null;
    defer if (cause) |msg| xm.allocator.free(msg);
    const cmd = try cmd_mod.cmd_parse_one(&.{ "switch-client", "-T", "copy-mode-test" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &client, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));
    try std.testing.expectEqualStrings("copy-mode-test", client.key_table_name.?);
    try std.testing.expect(client.session == setup.session);
}

test "switch-client -T rejects a missing key table" {
    switchClientTestInit();
    defer switchClientTestFinish();

    var setup = switchClientTestMakeSession("switch-client-missing-table");
    defer switchClientTestFreeSession(&setup);

    var client = switchClientTestMakeClient("switch-client-missing-client", setup.session);
    defer switchClientTestFreeClient(&client);
    client.key_table_name = xm.xstrdup("prefix");

    var cause: ?[]u8 = null;
    defer if (cause) |msg| xm.allocator.free(msg);
    const cmd = try cmd_mod.cmd_parse_one(&.{ "switch-client", "-T", "no-such-table" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &client, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.@"error", cmd_mod.cmd_execute(cmd, &item));
    try std.testing.expectEqualStrings("prefix", client.key_table_name.?);
    try std.testing.expect(client.session == setup.session);
}

test "switch-client -r toggles readonly flags on the target client before switching to the next session" {
    switchClientTestInit();
    defer switchClientTestFinish();

    var alpha = switchClientTestMakeSession("switch-client-alpha");
    defer switchClientTestFreeSession(&alpha);
    var beta = switchClientTestMakeSession("switch-client-beta");
    defer switchClientTestFreeSession(&beta);

    var queue_client = switchClientTestMakeClient("switch-client-queue-client", alpha.session);
    defer switchClientTestFreeClient(&queue_client);
    var target_client = switchClientTestMakeClient("switch-client-target-client", alpha.session);
    defer switchClientTestFreeClient(&target_client);

    var cause: ?[]u8 = null;
    defer if (cause) |msg| xm.allocator.free(msg);
    const cmd = try cmd_mod.cmd_parse_one(&.{ "switch-client", "-r", "-n" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{
        .client = &queue_client,
        .target_client = &target_client,
        .cmdlist = &list,
    };
    try std.testing.expectEqual(T.CmdRetval.normal, exec(cmd, &item));
    try std.testing.expect(target_client.flags & T.CLIENT_READONLY != 0);
    try std.testing.expect(target_client.flags & T.CLIENT_IGNORESIZE != 0);
    try std.testing.expect(queue_client.flags & (T.CLIENT_READONLY | T.CLIENT_IGNORESIZE) == 0);
    try std.testing.expect(target_client.session == beta.session);
}

test "switch-client -r clears readonly flags on the target client before switching to the last session" {
    switchClientTestInit();
    defer switchClientTestFinish();

    var alpha = switchClientTestMakeSession("switch-client-last-alpha");
    defer switchClientTestFreeSession(&alpha);
    var beta = switchClientTestMakeSession("switch-client-last-beta");
    defer switchClientTestFreeSession(&beta);

    var queue_client = switchClientTestMakeClient("switch-client-last-queue-client", beta.session);
    defer switchClientTestFreeClient(&queue_client);
    var target_client = switchClientTestMakeClient("switch-client-last-target-client", alpha.session);
    defer switchClientTestFreeClient(&target_client);
    target_client.last_session = beta.session;
    target_client.flags |= T.CLIENT_READONLY | T.CLIENT_IGNORESIZE;

    var cause: ?[]u8 = null;
    defer if (cause) |msg| xm.allocator.free(msg);
    const cmd = try cmd_mod.cmd_parse_one(&.{ "switch-client", "-r", "-l" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{
        .client = &queue_client,
        .target_client = &target_client,
        .cmdlist = &list,
    };
    try std.testing.expectEqual(T.CmdRetval.normal, exec(cmd, &item));
    try std.testing.expect(target_client.flags & T.CLIENT_READONLY == 0);
    try std.testing.expect(target_client.flags & T.CLIENT_IGNORESIZE == 0);
    try std.testing.expect(queue_client.flags & (T.CLIENT_READONLY | T.CLIENT_IGNORESIZE) == 0);
    try std.testing.expect(target_client.session == beta.session);
}

test "switch-client -n honors -O sort order for session cycling" {
    switchClientTestInit();
    defer switchClientTestFinish();

    var beta = switchClientTestMakeSession("switch-client-order-beta");
    defer switchClientTestFreeSession(&beta);
    var alpha = switchClientTestMakeSession("switch-client-order-alpha");
    defer switchClientTestFreeSession(&alpha);
    var gamma = switchClientTestMakeSession("switch-client-order-gamma");
    defer switchClientTestFreeSession(&gamma);

    var client = switchClientTestMakeClient("switch-client-order-client", beta.session);
    defer switchClientTestFreeClient(&client);

    var cause: ?[]u8 = null;
    defer if (cause) |msg| xm.allocator.free(msg);
    const cmd = try cmd_mod.cmd_parse_one(&.{ "switch-client", "-n", "-O", "name" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &client, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, exec(cmd, &item));
    try std.testing.expect(client.session == gamma.session);
}

test "switch-client -r -p reverses ordered session cycling and toggles readonly flags" {
    switchClientTestInit();
    defer switchClientTestFinish();

    var beta = switchClientTestMakeSession("switch-client-reversed-beta");
    defer switchClientTestFreeSession(&beta);
    var alpha = switchClientTestMakeSession("switch-client-reversed-alpha");
    defer switchClientTestFreeSession(&alpha);
    var gamma = switchClientTestMakeSession("switch-client-reversed-gamma");
    defer switchClientTestFreeSession(&gamma);

    var queue_client = switchClientTestMakeClient("switch-client-reversed-queue-client", beta.session);
    defer switchClientTestFreeClient(&queue_client);
    var target_client = switchClientTestMakeClient("switch-client-reversed-target-client", beta.session);
    defer switchClientTestFreeClient(&target_client);

    var cause: ?[]u8 = null;
    defer if (cause) |msg| xm.allocator.free(msg);
    const cmd = try cmd_mod.cmd_parse_one(&.{ "switch-client", "-r", "-p", "-O", "name" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{
        .client = &queue_client,
        .target_client = &target_client,
        .cmdlist = &list,
    };
    try std.testing.expectEqual(T.CmdRetval.normal, exec(cmd, &item));
    try std.testing.expect(target_client.flags & T.CLIENT_READONLY != 0);
    try std.testing.expect(target_client.flags & T.CLIENT_IGNORESIZE != 0);
    try std.testing.expect(queue_client.flags & (T.CLIENT_READONLY | T.CLIENT_IGNORESIZE) == 0);
    try std.testing.expect(target_client.session == gamma.session);
}

test "switch-client rejects invalid sort order" {
    switchClientTestInit();
    defer switchClientTestFinish();

    var setup = switchClientTestMakeSession("switch-client-invalid-order");
    defer switchClientTestFreeSession(&setup);

    var client = switchClientTestMakeClient("switch-client-invalid-order-client", setup.session);
    defer switchClientTestFreeClient(&client);

    var cause: ?[]u8 = null;
    defer if (cause) |msg| xm.allocator.free(msg);
    const cmd = try cmd_mod.cmd_parse_one(&.{ "switch-client", "-n", "-O", "bogus" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &client, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.@"error", exec(cmd, &item));
    try std.testing.expect(client.session == setup.session);
}

test "switch-client -t @windowid prefers an unattached session" {
    switchClientTestInit();
    defer switchClientTestFinish();

    var attached = switchClientTestMakeSession("switch-client-shared-window-attached");
    defer switchClientTestFreeSession(&attached);
    attached.session.activity_time = 500;

    const unattached = sess.session_create(null, "switch-client-shared-window-unattached", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("switch-client-shared-window-unattached") != null) sess.session_destroy(unattached, false, "test");
    unattached.activity_time = 100;

    var cause: ?[]u8 = null;
    defer if (cause) |msg| xm.allocator.free(msg);
    const unattached_wl = sess.session_attach(unattached, attached.window, -1, &cause).?;
    unattached.curw = unattached_wl;

    var client = switchClientTestMakeClient("switch-client-shared-window-client", attached.session);
    defer switchClientTestFreeClient(&client);

    const window_id = try std.fmt.allocPrint(xm.allocator, "@{d}", .{attached.window.id});
    defer xm.allocator.free(window_id);

    const cmd = try cmd_mod.cmd_parse_one(&.{ "switch-client", "-t", window_id }, null, &cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &client, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, exec(cmd, &item));
    try std.testing.expectEqual(unattached, client.session.?);
    try std.testing.expectEqual(unattached_wl, client.session.?.curw.?);
}

test "switch-client -t = uses the hovered pane target" {
    switchClientTestInit();
    defer switchClientTestFinish();

    var setup = switchClientTestMakeSession("switch-client-mouse-pane-target");
    defer switchClientTestFreeSession(&setup);
    const first = setup.window.active.?;
    const second = win_mod.window_add_pane(setup.window, null, 80, 24);
    if (setup.window.active != first)
        try std.testing.expect(win_mod.window_set_active_pane(setup.window, first, true));
    try std.testing.expect(setup.window.active == first);

    var client = switchClientTestMakeClient("switch-client-mouse-client", setup.session);
    defer switchClientTestFreeClient(&client);

    var cause: ?[]u8 = null;
    defer if (cause) |msg| xm.allocator.free(msg);
    const cmd = try cmd_mod.cmd_parse_one(&.{ "switch-client", "-t", "=" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &client, .cmdlist = &list };
    item.event.m = .{
        .valid = true,
        .key = T.keycMouse(T.KEYC_MOUSEDOWN1, .status),
        .s = @intCast(setup.session.id),
        .w = @intCast(setup.window.id),
        .wp = @intCast(second.id),
    };

    try std.testing.expectEqual(T.CmdRetval.normal, exec(cmd, &item));
    try std.testing.expectEqual(second, setup.window.active.?);
}

test "switch-client -n updates environment and preserves key table for repeat items" {
    switchClientTestInit();
    defer switchClientTestFinish();

    var alpha = switchClientTestMakeSession("switch-client-repeat-alpha");
    defer switchClientTestFreeSession(&alpha);
    var beta = switchClientTestMakeSession("switch-client-repeat-beta");
    defer switchClientTestFreeSession(&beta);

    opts.options_set_array(beta.session.options, "update-environment", &.{"DISPLAY"});
    env_mod.environ_set(beta.session.environ, "DISPLAY", 0, ":0");

    var queue_client = switchClientTestMakeClient("switch-client-repeat-queue-client", alpha.session);
    defer switchClientTestFreeClient(&queue_client);
    var target_client = switchClientTestMakeClient("switch-client-repeat-target-client", alpha.session);
    defer switchClientTestFreeClient(&target_client);
    target_client.key_table_name = xm.xstrdup("copy-mode");
    env_mod.environ_set(target_client.environ, "DISPLAY", 0, ":1");

    var cause: ?[]u8 = null;
    defer if (cause) |msg| xm.allocator.free(msg);
    const cmd = try cmd_mod.cmd_parse_one(&.{ "switch-client", "-n" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{
        .client = &queue_client,
        .target_client = &target_client,
        .cmdlist = &list,
        .state_flags = T.CMDQ_STATE_REPEAT,
    };
    try std.testing.expectEqual(T.CmdRetval.normal, exec(cmd, &item));
    try std.testing.expectEqual(beta.session, target_client.session.?);
    try std.testing.expectEqualStrings("copy-mode", target_client.key_table_name.?);
    try std.testing.expectEqualStrings(":1", env_mod.environ_find(beta.session.environ, "DISPLAY").?.value.?);
}

test "switch-client without -Z drops zoom when switching panes" {
    switchClientTestInit();
    defer switchClientTestFinish();

    var setup = switchClientTestMakeSession("switch-client-drop-zoom");
    defer switchClientTestFreeSession(&setup);
    const first = setup.window.active.?;
    const second = win_mod.window_add_pane(setup.window, null, 80, 24);

    try std.testing.expect(win_mod.window_zoom(first));

    const pane_target = try std.fmt.allocPrint(xm.allocator, "%{d}", .{second.id});
    defer xm.allocator.free(pane_target);

    var client = switchClientTestMakeClient("switch-client-drop-zoom-client", setup.session);
    defer switchClientTestFreeClient(&client);

    var cause: ?[]u8 = null;
    defer if (cause) |msg| xm.allocator.free(msg);
    const cmd = try cmd_mod.cmd_parse_one(&.{ "switch-client", "-t", pane_target }, null, &cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &client, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, exec(cmd, &item));
    try std.testing.expectEqual(second, setup.window.active.?);
    try std.testing.expect(setup.window.flags & T.WINDOW_ZOOMED == 0);
    try std.testing.expect(setup.window.flags & T.WINDOW_WASZOOMED == 0);
}

test "switch-client -Z preserves zoom and refreshes active-pane redraw state" {
    switchClientTestInit();
    defer switchClientTestFinish();

    var setup = switchClientTestMakeSession("switch-client-preserve-zoom");
    defer switchClientTestFreeSession(&setup);
    const first = setup.window.active.?;
    const second = win_mod.window_add_pane(setup.window, null, 80, 24);

    try std.testing.expect(win_mod.window_zoom(first));

    const pane_target = try std.fmt.allocPrint(xm.allocator, "%{d}", .{second.id});
    defer xm.allocator.free(pane_target);

    var client = switchClientTestMakeClient("switch-client-preserve-zoom-client", setup.session);
    defer switchClientTestFreeClient(&client);

    var cause: ?[]u8 = null;
    defer if (cause) |msg| xm.allocator.free(msg);
    const cmd = try cmd_mod.cmd_parse_one(&.{ "switch-client", "-Z", "-t", pane_target }, null, &cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var state = cmdq.CmdqState{};
    cmd_find.cmd_find_from_session(&state.current, setup.session, 0);
    var item = cmdq.CmdqItem{ .client = &client, .cmdlist = &list, .state = &state };
    try std.testing.expectEqual(T.CmdRetval.normal, exec(cmd, &item));
    try std.testing.expectEqual(second, setup.window.active.?);
    try std.testing.expect(setup.window.flags & T.WINDOW_ZOOMED != 0);
    try std.testing.expect(setup.window.flags & T.WINDOW_WASZOOMED == 0);
    try std.testing.expect(first.flags & T.PANE_REDRAW != 0);
    try std.testing.expect(second.flags & T.PANE_REDRAW != 0);
    try std.testing.expectEqual(setup.session, state.current.s.?);
    try std.testing.expectEqual(setup.session.curw.?, state.current.wl.?);
    try std.testing.expectEqual(second, state.current.wp.?);
}
