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

//! cmd-find-test.zig – tests for cmd-find.zig (extracted from cmd-find.zig).

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const sess = @import("session.zig");
const win_mod = @import("window.zig");
const opts = @import("options.zig");
const cmdq_mod = @import("cmd-queue.zig");
const client_registry = @import("client-registry.zig");
const env_mod = @import("environ.zig");
const cmd_find = @import("cmd-find.zig");
const cmd_mod = @import("cmd.zig");

test "cmd_find_target resolves current client state when target is omitted" {
    const spawn = @import("spawn.zig");

    sess.session_init_globals(xm.allocator);
    win_mod.window_init_globals(xm.allocator);

    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);

    env_mod.global_environ = env_mod.environ_create();
    defer env_mod.environ_free(env_mod.global_environ);

    const s = sess.session_create(null, "find-current", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("find-current") != null) sess.session_destroy(s, false, "test");

    var cause: ?[]u8 = null;
    var first_ctx: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const wl = spawn.spawn_window(&first_ctx, &cause).?;
    var second_ctx: T.SpawnContext = .{ .s = s, .wl = wl, .flags = T.SPAWN_EMPTY };
    const second = spawn.spawn_pane(&second_ctx, &cause).?;
    _ = win_mod.window_set_active_pane(wl.window, second, true);
    s.curw = wl;

    var client = T.Client{
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{},
        .session = s,
    };
    defer env_mod.environ_free(client.environ);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq_mod.CmdqItem{ .client = &client, .cmdlist = &list };
    var target: T.CmdFindState = .{};

    try std.testing.expectEqual(@as(i32, 0), cmd_find.cmd_find_target(&target, &item, null, .pane, 0));
    try std.testing.expectEqual(s, target.s.?);
    try std.testing.expectEqual(wl, target.wl.?);
    try std.testing.expectEqual(wl.window, target.w.?);
    try std.testing.expectEqual(second, target.wp.?);
}

test "cmd_find_target resolves session prefixes and patterns" {
    const spawn = @import("spawn.zig");

    sess.session_init_globals(xm.allocator);
    win_mod.window_init_globals(xm.allocator);

    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);

    env_mod.global_environ = env_mod.environ_create();
    defer env_mod.environ_free(env_mod.global_environ);

    const alpha = sess.session_create(null, "alpha", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("alpha") != null) sess.session_destroy(alpha, false, "test");
    const beta = sess.session_create(null, "beta", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("beta") != null) sess.session_destroy(beta, false, "test");

    var cause: ?[]u8 = null;
    var alpha_ctx: T.SpawnContext = .{ .s = alpha, .idx = -1, .flags = T.SPAWN_EMPTY };
    const alpha_wl = spawn.spawn_window(&alpha_ctx, &cause).?;
    alpha.curw = alpha_wl;
    var beta_ctx: T.SpawnContext = .{ .s = beta, .idx = -1, .flags = T.SPAWN_EMPTY };
    const beta_wl = spawn.spawn_window(&beta_ctx, &cause).?;
    beta.curw = beta_wl;

    var client = T.Client{
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{},
        .session = alpha,
    };
    defer env_mod.environ_free(client.environ);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq_mod.CmdqItem{ .client = &client, .cmdlist = &list };
    var target: T.CmdFindState = .{};

    try std.testing.expectEqual(@as(i32, 0), cmd_find.cmd_find_target(&target, &item, "alp", .session, 0));
    try std.testing.expectEqual(alpha, target.s.?);
    try std.testing.expectEqual(@as(i32, 0), cmd_find.cmd_find_target(&target, &item, "b*", .session, 0));
    try std.testing.expectEqual(beta, target.s.?);
}

test "cmd_find_target resolves window names, last window, and window-index targets" {
    const spawn = @import("spawn.zig");

    sess.session_init_globals(xm.allocator);
    win_mod.window_init_globals(xm.allocator);

    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);

    env_mod.global_environ = env_mod.environ_create();
    defer env_mod.environ_free(env_mod.global_environ);

    const s = sess.session_create(null, "find-window", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("find-window") != null) sess.session_destroy(s, false, "test");

    var cause: ?[]u8 = null;
    var first_ctx: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const wl0 = spawn.spawn_window(&first_ctx, &cause).?;
    xm.allocator.free(wl0.window.name);
    wl0.window.name = xm.xstrdup("editor");

    var second_ctx: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const wl1 = spawn.spawn_window(&second_ctx, &cause).?;
    xm.allocator.free(wl1.window.name);
    wl1.window.name = xm.xstrdup("logs");

    _ = sess.session_set_current(s, wl1);

    var client = T.Client{
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{},
        .session = s,
    };
    defer env_mod.environ_free(client.environ);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq_mod.CmdqItem{ .client = &client, .cmdlist = &list };
    var target: T.CmdFindState = .{};

    try std.testing.expectEqual(@as(i32, 0), cmd_find.cmd_find_target(&target, &item, "ed", .window, 0));
    try std.testing.expectEqual(wl0, target.wl.?);

    try std.testing.expectEqual(@as(i32, 0), cmd_find.cmd_find_target(&target, &item, "l*", .window, 0));
    try std.testing.expectEqual(wl1, target.wl.?);

    try std.testing.expectEqual(@as(i32, 0), cmd_find.cmd_find_target(&target, &item, "!", .window, 0));
    try std.testing.expectEqual(wl0, target.wl.?);

    try std.testing.expectEqual(@as(i32, 0), cmd_find.cmd_find_target(&target, &item, "find-window:5", .window, T.CMD_FIND_WINDOW_INDEX));
    try std.testing.expectEqual(s, target.s.?);
    try std.testing.expectEqual(@as(i32, 5), target.idx);
}

test "cmd_find_target resolves explicit pane indexes within a window" {
    const spawn = @import("spawn.zig");

    sess.session_init_globals(xm.allocator);
    win_mod.window_init_globals(xm.allocator);

    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);

    env_mod.global_environ = env_mod.environ_create();
    defer env_mod.environ_free(env_mod.global_environ);

    const s = sess.session_create(null, "find-pane", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("find-pane") != null) sess.session_destroy(s, false, "test");

    var cause: ?[]u8 = null;
    var first_ctx: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const wl = spawn.spawn_window(&first_ctx, &cause).?;
    var second_ctx: T.SpawnContext = .{ .s = s, .wl = wl, .flags = T.SPAWN_EMPTY };
    _ = spawn.spawn_pane(&second_ctx, &cause).?;
    s.curw = wl;

    var list: cmd_mod.CmdList = .{};
    var item = cmdq_mod.CmdqItem{ .client = null, .cmdlist = &list };
    var target: T.CmdFindState = .{};
    try std.testing.expectEqual(@as(i32, 0), cmd_find.cmd_find_target(&target, &item, "find-pane:0.1", .pane, 0));
    try std.testing.expectEqual(wl.window.panes.items[1], target.wp.?);
}

test "cmd_find_target resolves last pane in the current window" {
    const spawn = @import("spawn.zig");

    sess.session_init_globals(xm.allocator);
    win_mod.window_init_globals(xm.allocator);

    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);

    env_mod.global_environ = env_mod.environ_create();
    defer env_mod.environ_free(env_mod.global_environ);

    const s = sess.session_create(null, "find-last-pane", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("find-last-pane") != null) sess.session_destroy(s, false, "test");

    var cause: ?[]u8 = null;
    var first_ctx: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const wl = spawn.spawn_window(&first_ctx, &cause).?;
    var second_ctx: T.SpawnContext = .{ .s = s, .wl = wl, .flags = T.SPAWN_EMPTY };
    const second = spawn.spawn_pane(&second_ctx, &cause).?;
    _ = win_mod.window_set_active_pane(wl.window, second, true);
    _ = win_mod.window_set_active_pane(wl.window, wl.window.panes.items[0], true);
    s.curw = wl;

    var client = T.Client{
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{},
        .session = s,
    };
    defer env_mod.environ_free(client.environ);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq_mod.CmdqItem{ .client = &client, .cmdlist = &list };
    var target: T.CmdFindState = .{};
    try std.testing.expectEqual(@as(i32, 0), cmd_find.cmd_find_target(&target, &item, "!", .pane, 0));
    try std.testing.expectEqual(second, target.wp.?);
}

test "cmd_find_target uses unattached inside-pane context to choose a session" {
    const spawn = @import("spawn.zig");

    sess.session_init_globals(xm.allocator);
    win_mod.window_init_globals(xm.allocator);
    client_registry.clients.clearRetainingCapacity();

    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);

    env_mod.global_environ = env_mod.environ_create();
    defer env_mod.environ_free(env_mod.global_environ);

    const pane_session = sess.session_create(null, "pane-session", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("pane-session") != null) sess.session_destroy(pane_session, false, "test");
    const newer_session = sess.session_create(null, "newer-session", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("newer-session") != null) sess.session_destroy(newer_session, false, "test");

    var cause: ?[]u8 = null;
    var pane_ctx: T.SpawnContext = .{ .s = pane_session, .idx = -1, .flags = T.SPAWN_EMPTY };
    const pane_wl = spawn.spawn_window(&pane_ctx, &cause).?;
    var current_ctx: T.SpawnContext = .{ .s = pane_session, .idx = -1, .flags = T.SPAWN_EMPTY };
    const current_wl = spawn.spawn_window(&current_ctx, &cause).?;
    pane_session.curw = current_wl;
    var newer_ctx: T.SpawnContext = .{ .s = newer_session, .idx = -1, .flags = T.SPAWN_EMPTY };
    _ = spawn.spawn_window(&newer_ctx, &cause).?;

    pane_wl.window.panes.items[0].fd = 7;
    defer pane_wl.window.panes.items[0].fd = -1;
    @memset(&pane_wl.window.panes.items[0].tty_name, 0);
    const tty = "/tmp/inside-pane-tty";
    @memcpy(pane_wl.window.panes.items[0].tty_name[0..tty.len], tty);

    const client_env = env_mod.environ_create();
    defer env_mod.environ_free(client_env);
    var client = T.Client{
        .environ = client_env,
        .tty = undefined,
        .status = .{},
        .ttyname = xm.xstrdup(tty),
    };
    defer xm.allocator.free(client.ttyname.?);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq_mod.CmdqItem{ .client = &client, .cmdlist = &list };
    var target: T.CmdFindState = .{};

    try std.testing.expectEqual(@as(i32, 0), cmd_find.cmd_find_target(&target, &item, null, .pane, 0));
    try std.testing.expectEqual(pane_session, target.s.?);
    try std.testing.expectEqual(current_wl, target.wl.?);
    try std.testing.expectEqual(current_wl.window.active.?, target.wp.?);
}

test "cmd_find_target uses ZMUX_PANE for unattached clients without tty matches" {
    const spawn = @import("spawn.zig");

    sess.session_init_globals(xm.allocator);
    win_mod.window_init_globals(xm.allocator);
    client_registry.clients.clearRetainingCapacity();

    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);

    env_mod.global_environ = env_mod.environ_create();
    defer env_mod.environ_free(env_mod.global_environ);

    const s = sess.session_create(null, "zmux-pane-session", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("zmux-pane-session") != null) sess.session_destroy(s, false, "test");

    var cause: ?[]u8 = null;
    var ctx: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const wl = spawn.spawn_window(&ctx, &cause).?;
    s.curw = wl;

    const client_env = env_mod.environ_create();
    defer env_mod.environ_free(client_env);
    const pane_id = try std.fmt.allocPrint(xm.allocator, "%{d}", .{wl.window.panes.items[0].id});
    defer xm.allocator.free(pane_id);
    env_mod.environ_set(client_env, "ZMUX_PANE", 0, pane_id);

    var client = T.Client{
        .environ = client_env,
        .tty = undefined,
        .status = .{},
    };

    var list: cmd_mod.CmdList = .{};
    var item = cmdq_mod.CmdqItem{ .client = &client, .cmdlist = &list };
    var target: T.CmdFindState = .{};

    try std.testing.expectEqual(@as(i32, 0), cmd_find.cmd_find_target(&target, &item, null, .pane, 0));
    try std.testing.expectEqual(s, target.s.?);
    try std.testing.expectEqual(wl.window.active.?, target.wp.?);
}

test "cmd_find_current_client prefers attached clients in the inside-pane session" {
    const spawn = @import("spawn.zig");

    sess.session_init_globals(xm.allocator);
    win_mod.window_init_globals(xm.allocator);
    client_registry.clients.clearRetainingCapacity();

    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);

    env_mod.global_environ = env_mod.environ_create();
    defer env_mod.environ_free(env_mod.global_environ);

    const s = sess.session_create(null, "client-session", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("client-session") != null) sess.session_destroy(s, false, "test");
    s.attached = 2;
    const other = sess.session_create(null, "other-session", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("other-session") != null) sess.session_destroy(other, false, "test");
    other.attached = 1;

    var cause: ?[]u8 = null;
    var ctx: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const wl = spawn.spawn_window(&ctx, &cause).?;
    s.curw = wl;
    wl.window.panes.items[0].fd = 9;
    defer wl.window.panes.items[0].fd = -1;
    @memset(&wl.window.panes.items[0].tty_name, 0);
    const tty = "/tmp/current-client-tty";
    @memcpy(wl.window.panes.items[0].tty_name[0..tty.len], tty);

    const attached_old_env = env_mod.environ_create();
    defer env_mod.environ_free(attached_old_env);
    var attached_old = T.Client{
        .id = 1,
        .environ = attached_old_env,
        .tty = undefined,
        .status = .{},
        .session = s,
    };
    const attached_new_env = env_mod.environ_create();
    defer env_mod.environ_free(attached_new_env);
    var attached_new = T.Client{
        .id = 2,
        .environ = attached_new_env,
        .tty = undefined,
        .status = .{},
        .session = s,
    };
    const other_env = env_mod.environ_create();
    defer env_mod.environ_free(other_env);
    var other_client = T.Client{
        .id = 3,
        .environ = other_env,
        .tty = undefined,
        .status = .{},
        .session = other,
    };

    client_registry.add(&attached_old);
    client_registry.add(&attached_new);
    client_registry.add(&other_client);
    defer client_registry.clients.clearRetainingCapacity();

    const query_env = env_mod.environ_create();
    defer env_mod.environ_free(query_env);
    var query_client = T.Client{
        .environ = query_env,
        .tty = undefined,
        .status = .{},
        .ttyname = xm.xstrdup(tty),
    };
    defer xm.allocator.free(query_client.ttyname.?);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq_mod.CmdqItem{ .client = &query_client, .cmdlist = &list };

    try std.testing.expectEqual(&attached_new, cmd_find.cmd_find_current_client(&item, false).?);
    try std.testing.expectEqual(&attached_new, cmd_find.cmd_find_client(&item, null, false).?);
}

test "cmd_find_current_client prefers higher activity over client id" {
    const opts_mod = @import("options.zig");
    const spawn = @import("spawn.zig");

    sess.session_init_globals(xm.allocator);
    win_mod.window_init_globals(xm.allocator);
    client_registry.clients.clearRetainingCapacity();

    opts_mod.global_options = opts_mod.options_create(null);
    defer opts_mod.options_free(opts_mod.global_options);
    opts_mod.global_s_options = opts_mod.options_create(null);
    defer opts_mod.options_free(opts_mod.global_s_options);
    opts_mod.global_w_options = opts_mod.options_create(null);
    defer opts_mod.options_free(opts_mod.global_w_options);
    opts_mod.options_default_all(opts_mod.global_options, T.OPTIONS_TABLE_SERVER);
    opts_mod.options_default_all(opts_mod.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts_mod.options_default_all(opts_mod.global_w_options, T.OPTIONS_TABLE_WINDOW);

    env_mod.global_environ = env_mod.environ_create();
    defer env_mod.environ_free(env_mod.global_environ);

    const s = sess.session_create(null, "activity-client-session", "/", env_mod.environ_create(), opts_mod.options_create(opts_mod.global_s_options), null);
    defer if (sess.session_find("activity-client-session") != null) sess.session_destroy(s, false, "test");
    s.attached = 2;

    var cause: ?[]u8 = null;
    var ctx: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const wl = spawn.spawn_window(&ctx, &cause).?;
    s.curw = wl;

    const old_env = env_mod.environ_create();
    defer env_mod.environ_free(old_env);
    var older_id_newer_activity = T.Client{
        .id = 1,
        .activity_time = 200,
        .environ = old_env,
        .tty = undefined,
        .status = .{},
        .session = s,
    };
    const new_env = env_mod.environ_create();
    defer env_mod.environ_free(new_env);
    var newer_id_older_activity = T.Client{
        .id = 9,
        .activity_time = 100,
        .environ = new_env,
        .tty = undefined,
        .status = .{},
        .session = s,
    };

    client_registry.add(&newer_id_older_activity);
    client_registry.add(&older_id_newer_activity);
    defer client_registry.clients.clearRetainingCapacity();

    try std.testing.expectEqual(&older_id_newer_activity, cmd_find.cmd_find_current_client(null, false).?);
    try std.testing.expectEqual(&older_id_newer_activity, cmd_find.cmd_find_client(null, null, false).?);
}

test "cmd_find_target prefers unattached session for shared window ids" {
    const opts_mod = @import("options.zig");
    const spawn = @import("spawn.zig");

    sess.session_init_globals(xm.allocator);
    win_mod.window_init_globals(xm.allocator);

    opts_mod.global_options = opts_mod.options_create(null);
    defer opts_mod.options_free(opts_mod.global_options);
    opts_mod.global_s_options = opts_mod.options_create(null);
    defer opts_mod.options_free(opts_mod.global_s_options);
    opts_mod.global_w_options = opts_mod.options_create(null);
    defer opts_mod.options_free(opts_mod.global_w_options);
    opts_mod.options_default_all(opts_mod.global_options, T.OPTIONS_TABLE_SERVER);
    opts_mod.options_default_all(opts_mod.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts_mod.options_default_all(opts_mod.global_w_options, T.OPTIONS_TABLE_WINDOW);

    env_mod.global_environ = env_mod.environ_create();
    defer env_mod.environ_free(env_mod.global_environ);

    const attached = sess.session_create(null, "shared-window-attached", "/", env_mod.environ_create(), opts_mod.options_create(opts_mod.global_s_options), null);
    defer if (sess.session_find("shared-window-attached") != null) sess.session_destroy(attached, false, "test");
    const unattached = sess.session_create(null, "shared-window-unattached", "/", env_mod.environ_create(), opts_mod.options_create(opts_mod.global_s_options), null);
    defer if (sess.session_find("shared-window-unattached") != null) sess.session_destroy(unattached, false, "test");

    var cause: ?[]u8 = null;
    var attached_ctx: T.SpawnContext = .{ .s = attached, .idx = -1, .flags = T.SPAWN_EMPTY };
    const attached_wl = spawn.spawn_window(&attached_ctx, &cause).?;
    attached.curw = attached_wl;
    attached.attached = 1;
    attached.activity_time = 500;

    const unattached_wl = sess.session_attach(unattached, attached_wl.window, -1, &cause).?;
    unattached.curw = unattached_wl;
    unattached.attached = 0;
    unattached.activity_time = 100;

    const query_env = env_mod.environ_create();
    defer env_mod.environ_free(query_env);
    var query_client = T.Client{
        .environ = query_env,
        .tty = undefined,
        .status = .{},
        .session = attached,
    };

    var list: cmd_mod.CmdList = .{};
    var item = cmdq_mod.CmdqItem{ .client = &query_client, .cmdlist = &list };
    var target: T.CmdFindState = .{};
    const window_id = try std.fmt.allocPrint(xm.allocator, "@{d}", .{attached_wl.window.id});
    defer xm.allocator.free(window_id);

    try std.testing.expectEqual(@as(i32, 0), cmd_find.cmd_find_target(&target, &item, window_id, .window, T.CMD_FIND_PREFER_UNATTACHED));
    try std.testing.expectEqual(unattached, target.s.?);
    try std.testing.expectEqual(unattached_wl, target.wl.?);
    try std.testing.expectEqual(attached_wl.window.active.?, target.wp.?);
}

test "cmd_find_target resolves {mouse} through the shared mouse runtime state" {
    const opts_mod = @import("options.zig");
    const spawn = @import("spawn.zig");

    sess.session_init_globals(xm.allocator);
    win_mod.window_init_globals(xm.allocator);

    opts_mod.global_options = opts_mod.options_create(null);
    defer opts_mod.options_free(opts_mod.global_options);
    opts_mod.global_s_options = opts_mod.options_create(null);
    defer opts_mod.options_free(opts_mod.global_s_options);
    opts_mod.global_w_options = opts_mod.options_create(null);
    defer opts_mod.options_free(opts_mod.global_w_options);
    opts_mod.options_default_all(opts_mod.global_options, T.OPTIONS_TABLE_SERVER);
    opts_mod.options_default_all(opts_mod.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts_mod.options_default_all(opts_mod.global_w_options, T.OPTIONS_TABLE_WINDOW);

    env_mod.global_environ = env_mod.environ_create();
    defer env_mod.environ_free(env_mod.global_environ);

    const s = sess.session_create(null, "mouse-target", "/", env_mod.environ_create(), opts_mod.options_create(opts_mod.global_s_options), null);
    defer if (sess.session_find("mouse-target") != null) sess.session_destroy(s, false, "test");

    var cause: ?[]u8 = null;
    var spawn_ctx: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const wl = spawn.spawn_window(&spawn_ctx, &cause).?;
    s.curw = wl;
    const wp = wl.window.active.?;

    const query_env = env_mod.environ_create();
    defer env_mod.environ_free(query_env);
    var query_client = T.Client{
        .environ = query_env,
        .tty = undefined,
        .status = .{},
        .session = s,
    };

    var list: cmd_mod.CmdList = .{};
    var item = cmdq_mod.CmdqItem{ .client = &query_client, .cmdlist = &list };
    item.event.m = .{
        .valid = true,
        .key = T.keycMouse(T.KEYC_MOUSEDOWN1, .status),
        .s = @intCast(s.id),
        .w = @intCast(wl.window.id),
        .wp = @intCast(wp.id),
    };

    var target: T.CmdFindState = .{};
    try std.testing.expectEqual(@as(i32, 0), cmd_find.cmd_find_target(&target, &item, "{mouse}", .pane, 0));
    try std.testing.expectEqual(s, target.s.?);
    try std.testing.expectEqual(wl, target.wl.?);
    try std.testing.expectEqual(wp, target.wp.?);
}

test "cmd_find_valid_state rejects incomplete find state" {
    var fs: T.CmdFindState = .{};
    try std.testing.expect(!cmd_find.cmd_find_valid_state(&fs));
}

test "cmd_find_target @ requires a client on the queue item" {
    cmdq_mod.cmdq_reset_for_tests();
    defer cmdq_mod.cmdq_reset_for_tests();

    var list: cmd_mod.CmdList = .{};
    var item = cmdq_mod.CmdqItem{ .cmdlist = &list };
    var target: T.CmdFindState = .{};
    try std.testing.expectEqual(@as(i32, -1), cmd_find.cmd_find_target(&target, &item, "@", .pane, 0));
}

test "cmd_find_target {mouse} fails when the mouse event is invalid" {
    const opts_mod = @import("options.zig");
    const spawn = @import("spawn.zig");

    sess.session_init_globals(xm.allocator);
    win_mod.window_init_globals(xm.allocator);

    opts_mod.global_options = opts_mod.options_create(null);
    defer opts_mod.options_free(opts_mod.global_options);
    opts_mod.global_s_options = opts_mod.options_create(null);
    defer opts_mod.options_free(opts_mod.global_s_options);
    opts_mod.global_w_options = opts_mod.options_create(null);
    defer opts_mod.options_free(opts_mod.global_w_options);
    opts_mod.options_default_all(opts_mod.global_options, T.OPTIONS_TABLE_SERVER);
    opts_mod.options_default_all(opts_mod.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts_mod.options_default_all(opts_mod.global_w_options, T.OPTIONS_TABLE_WINDOW);

    env_mod.global_environ = env_mod.environ_create();
    defer env_mod.environ_free(env_mod.global_environ);

    const s = sess.session_create(null, "mouse-invalid", "/", env_mod.environ_create(), opts_mod.options_create(opts_mod.global_s_options), null);
    defer if (sess.session_find("mouse-invalid") != null) sess.session_destroy(s, false, "test");

    var cause: ?[]u8 = null;
    var spawn_ctx: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const wl = spawn.spawn_window(&spawn_ctx, &cause).?;
    s.curw = wl;

    const query_env = env_mod.environ_create();
    defer env_mod.environ_free(query_env);
    var query_client = T.Client{
        .environ = query_env,
        .tty = undefined,
        .status = .{},
        .session = s,
    };

    var list: cmd_mod.CmdList = .{};
    var item = cmdq_mod.CmdqItem{ .client = &query_client, .cmdlist = &list };
    item.event.m = .{ .valid = false };

    var target: T.CmdFindState = .{};
    try std.testing.expectEqual(@as(i32, -1), cmd_find.cmd_find_target(&target, &item, "{mouse}", .pane, 0));
}

test "cmd_find_valid_state false when session set but winlink missing" {
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

    const s = sess.session_create(null, "find-partial", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("find-partial") != null) sess.session_destroy(s, false, "test");

    var fs: T.CmdFindState = .{ .s = s };
    try std.testing.expect(!cmd_find.cmd_find_valid_state(&fs));
}

test "cmd_find_target rejects malformed session window index" {
    const spawn = @import("spawn.zig");

    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);

    env_mod.global_environ = env_mod.environ_create();
    defer env_mod.environ_free(env_mod.global_environ);

    sess.session_init_globals(xm.allocator);
    win_mod.window_init_globals(xm.allocator);

    const s = sess.session_create(null, "find-bad-idx", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("find-bad-idx") != null) sess.session_destroy(s, false, "test");

    var cause: ?[]u8 = null;
    var spawn_ctx: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    _ = spawn.spawn_window(&spawn_ctx, &cause).?;

    const query_env = env_mod.environ_create();
    defer env_mod.environ_free(query_env);
    var query_client = T.Client{
        .environ = query_env,
        .tty = undefined,
        .status = .{},
        .session = s,
    };

    var list: cmd_mod.CmdList = .{};
    var item = cmdq_mod.CmdqItem{ .client = &query_client, .cmdlist = &list };

    var target: T.CmdFindState = .{};
    try std.testing.expectEqual(@as(i32, -1), cmd_find.cmd_find_target(&target, &item, "find-bad-idx:999", .pane, 0));
}
