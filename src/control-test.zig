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

//! control-test.zig – tests for control.zig and control-subscriptions.zig.

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const c = @import("c.zig");
const env_mod = @import("environ.zig");
const opts = @import("options.zig");
const proc_mod = @import("proc.zig");
const cmdq = @import("cmd-queue.zig");
const client_registry = @import("client-registry.zig");
const sess = @import("session.zig");
const win_mod = @import("window.zig");
const ctl = @import("control.zig");
const ctl_sub = @import("control-subscriptions.zig");

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

test "control_pane_cmp and subscription comparators use stable ordering" {
    const pa = T.ControlPane{ .pane = 10 };
    const pb = T.ControlPane{ .pane = 20 };
    try std.testing.expectEqual(@as(i32, -1), ctl.control_pane_cmp(&pa, &pb));
    try std.testing.expectEqual(@as(i32, 1), ctl.control_pane_cmp(&pb, &pa));
    try std.testing.expectEqual(@as(i32, 0), ctl.control_pane_cmp(&pa, &pa));

    const spa = T.ControlSubscriptionPane{ .pane = 1, .idx = 2 };
    const spb = T.ControlSubscriptionPane{ .pane = 2, .idx = 0 };
    try std.testing.expectEqual(@as(i32, -1), ctl.control_sub_pane_cmp(&spa, &spb));

    const swa = T.ControlSubscriptionWindow{ .window = 3, .idx = -1 };
    const swb = T.ControlSubscriptionWindow{ .window = 4, .idx = -1 };
    try std.testing.expectEqual(@as(i32, -1), ctl.control_sub_window_cmp(&swa, &swb));

    var sa: T.ControlSubscription = .{
        .name = try xm.allocator.dupe(u8, "alpha"),
        .format = try xm.allocator.dupe(u8, "#{pane_id}"),
        .sub_type = .pane,
    };
    defer sa.deinit(xm.allocator);
    var sz: T.ControlSubscription = .{
        .name = try xm.allocator.dupe(u8, "zebra"),
        .format = try xm.allocator.dupe(u8, "#{window_id}"),
        .sub_type = .window,
    };
    defer sz.deinit(xm.allocator);

    try std.testing.expectEqual(@as(i32, -1), ctl.control_sub_cmp(&sa, &sz));
    try std.testing.expectEqual(@as(i32, 0), ctl.control_sub_cmp(&sa, &sa));
}

test "control_subscriptions replace same name and remove clears the list" {
    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);

    var cl: T.Client = undefined;
    cl = .{
        .environ = env,
        .tty = undefined,
        .status = .{},
    };
    cl.tty = .{ .client = &cl };

    ctl_sub.control_add_sub(&cl, "hook", T.ControlSubType.session, 7, "#{session_name}");
    try std.testing.expectEqual(@as(usize, 1), cl.control_subscriptions.items.len);
    try std.testing.expectEqualStrings("hook", cl.control_subscriptions.items[0].name);
    try std.testing.expectEqual(T.ControlSubType.session, cl.control_subscriptions.items[0].sub_type);
    try std.testing.expectEqual(@as(u32, 7), cl.control_subscriptions.items[0].id);

    ctl_sub.control_add_sub(&cl, "hook", T.ControlSubType.all_panes, 0, "#{pane_id}");
    try std.testing.expectEqual(@as(usize, 1), cl.control_subscriptions.items.len);
    try std.testing.expectEqual(T.ControlSubType.all_panes, cl.control_subscriptions.items[0].sub_type);

    ctl_sub.control_remove_sub(&cl, "hook");
    try std.testing.expectEqual(@as(usize, 0), cl.control_subscriptions.items.len);

    ctl_sub.control_subscriptions_deinit(&cl);
}

test "control_notify_session_created ignores session pointer and tolerates empty registry" {
    const cn = @import("control-notify.zig");
    const registry = @import("client-registry.zig");

    registry.clients.clearRetainingCapacity();
    defer registry.clients.clearRetainingCapacity();

    var dummy: T.Session = undefined;
    cn.control_notify_session_created(&dummy);
    try std.testing.expectEqual(@as(usize, 0), registry.clients.items.len);
}

test "control_notify_client_detached tolerates empty registry" {
    const cn = @import("control-notify.zig");
    const registry = @import("client-registry.zig");

    registry.clients.clearRetainingCapacity();
    defer registry.clients.clearRetainingCapacity();

    var dummy: T.Client = undefined;
    cn.control_notify_client_detached(&dummy);
    try std.testing.expectEqual(@as(usize, 0), registry.clients.items.len);
}

test "control subscriptions keep multiple distinct hooks ordered by insertion" {
    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);

    var cl: T.Client = undefined;
    cl = .{
        .environ = env,
        .tty = undefined,
        .status = .{},
    };
    cl.tty = .{ .client = &cl };

    ctl.control_add_sub(&cl, "a", T.ControlSubType.session, 0, "#{session_id}");
    ctl.control_add_sub(&cl, "b", T.ControlSubType.window, 3, "#{window_id}");
    try std.testing.expectEqual(@as(usize, 2), cl.control_subscriptions.items.len);
    try std.testing.expectEqualStrings("a", cl.control_subscriptions.items[0].name);
    try std.testing.expectEqualStrings("b", cl.control_subscriptions.items[1].name);
    try std.testing.expectEqual(T.ControlSubType.window, cl.control_subscriptions.items[1].sub_type);
    try std.testing.expectEqual(@as(u32, 3), cl.control_subscriptions.items[1].id);

    ctl_sub.control_subscriptions_deinit(&cl);
}

test "control_check_subscriptions no-ops without an attached session" {
    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);

    var cl: T.Client = undefined;
    cl = .{
        .environ = env,
        .tty = undefined,
        .status = .{},
        .session = null,
    };
    cl.tty = .{ .client = &cl };

    ctl.control_add_sub(&cl, "hook", T.ControlSubType.session, 0, "#{session_name}");
    ctl_sub.control_check_subscriptions(&cl);
    try std.testing.expectEqual(@as(usize, 1), cl.control_subscriptions.items.len);

    ctl_sub.control_subscriptions_deinit(&cl);
}

test "control_free_sub removes the targeted subscription pointer" {
    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);

    var cl: T.Client = undefined;
    cl = .{
        .environ = env,
        .tty = undefined,
        .status = .{},
    };
    cl.tty = .{ .client = &cl };

    ctl.control_add_sub(&cl, "first", T.ControlSubType.session, 0, "fmt1");
    ctl.control_add_sub(&cl, "second", T.ControlSubType.session, 0, "fmt2");
    const ptr = &cl.control_subscriptions.items[1];
    ctl.control_free_sub(&cl, ptr);
    try std.testing.expectEqual(@as(usize, 1), cl.control_subscriptions.items.len);
    try std.testing.expectEqualStrings("first", cl.control_subscriptions.items[0].name);

    ctl_sub.control_subscriptions_deinit(&cl);
}

test "control_start control_stop and control_all_done manage block queues" {
    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);

    var cl: T.Client = undefined;
    cl = .{
        .environ = env,
        .tty = undefined,
        .status = .{},
        .peer = null,
        .control_all_blocks = .{},
        .control_panes = .{},
    };
    cl.tty = .{ .client = &cl };

    ctl.control_start(&cl);
    try std.testing.expect(ctl.control_all_done(&cl));
    // control_stop deinits control_all_blocks without re-init; all_done is only valid while started.
    ctl.control_stop(&cl);
}

test "control_window_pane returns null without session" {
    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);

    var cl: T.Client = undefined;
    cl = .{
        .environ = env,
        .tty = undefined,
        .status = .{},
        .session = null,
    };
    cl.tty = .{ .client = &cl };

    try std.testing.expect(ctl.control_window_pane(&cl, 999) == null);
}

test "control_discard on empty client is safe" {
    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);

    var cl: T.Client = undefined;
    cl = .{
        .environ = env,
        .tty = undefined,
        .status = .{},
    };
    cl.tty = .{ .client = &cl };

    ctl.control_discard(&cl);
}

test "control_check_subs_session returns early when session is null" {
    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);

    var cl: T.Client = undefined;
    cl = .{
        .environ = env,
        .tty = undefined,
        .status = .{},
        .session = null,
    };
    cl.tty = .{ .client = &cl };

    var sub: T.ControlSubscription = .{
        .name = try xm.allocator.dupe(u8, "x"),
        .format = try xm.allocator.dupe(u8, "y"),
        .sub_type = .session,
    };
    defer sub.deinit(xm.allocator);

    ctl.control_check_subs_session(&cl, &sub);
}

test "control_error_callback flags client exit" {
    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);

    var cl: T.Client = undefined;
    cl = .{
        .environ = env,
        .tty = undefined,
        .status = .{},
        .flags = 0,
    };
    cl.tty = .{ .client = &cl };

    ctl.control_error_callback(&cl);
    try std.testing.expect((cl.flags & T.CLIENT_EXIT) != 0);
}

test "control_remove_sub is safe for unknown subscription names" {
    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);

    var cl: T.Client = undefined;
    cl = .{
        .environ = env,
        .tty = undefined,
        .status = .{},
    };
    cl.tty = .{ .client = &cl };

    ctl_sub.control_remove_sub(&cl, "nonexistent");
    try std.testing.expectEqual(@as(usize, 0), cl.control_subscriptions.items.len);

    ctl_sub.control_subscriptions_deinit(&cl);
}

test "control_sub_cmp orders subscriptions lexicographically by name" {
    var m = T.ControlSubscription{
        .name = try xm.allocator.dupe(u8, "middle"),
        .format = try xm.allocator.dupe(u8, "f"),
        .sub_type = .session,
    };
    defer m.deinit(xm.allocator);
    var z = T.ControlSubscription{
        .name = try xm.allocator.dupe(u8, "zebra"),
        .format = try xm.allocator.dupe(u8, "f"),
        .sub_type = .session,
    };
    defer z.deinit(xm.allocator);

    try std.testing.expectEqual(@as(i32, -1), ctl.control_sub_cmp(&m, &z));
    try std.testing.expectEqual(@as(i32, 1), ctl.control_sub_cmp(&z, &m));
}

test "control_check_subscriptions only emits session updates when the formatted value changes" {
    var session_env = T.Environ.init(xm.allocator);
    defer session_env.deinit();
    var session_options = T.Options.init(xm.allocator, null);
    defer session_options.deinit();

    var session = T.Session{
        .id = 41,
        .name = xm.xstrdup("alpha"),
        .cwd = "/",
        .options = &session_options,
        .environ = &session_env,
    };
    defer xm.allocator.free(session.name);

    var client = T.Client{
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{},
        .session = &session,
    };
    defer env_mod.environ_free(client.environ);
    client.tty = .{ .client = &client };

    ctl.control_add_sub(&client, "watch", T.ControlSubType.session, 0, "#{session_name}");
    defer ctl_sub.control_subscriptions_deinit(&client);

    var first_pipe: [2]i32 = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.pipe(&first_pipe));
    defer {
        std.posix.close(first_pipe[0]);
        if (first_pipe[1] != -1) std.posix.close(first_pipe[1]);
    }
    const stdout_dup = try std.posix.dup(std.posix.STDOUT_FILENO);
    defer std.posix.close(stdout_dup);
    try std.posix.dup2(first_pipe[1], std.posix.STDOUT_FILENO);
    ctl_sub.control_check_subscriptions(&client);
    try std.posix.dup2(stdout_dup, std.posix.STDOUT_FILENO);
    std.posix.close(first_pipe[1]);
    first_pipe[1] = -1;

    var first_buf: [256]u8 = undefined;
    const first_len = try std.posix.read(first_pipe[0], &first_buf);
    try std.testing.expectEqualStrings(
        "%subscription-changed watch $41 - - - : alpha\n",
        first_buf[0..first_len],
    );

    var second_pipe: [2]i32 = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.pipe(&second_pipe));
    defer {
        std.posix.close(second_pipe[0]);
        if (second_pipe[1] != -1) std.posix.close(second_pipe[1]);
    }
    try std.posix.dup2(second_pipe[1], std.posix.STDOUT_FILENO);
    ctl_sub.control_check_subscriptions(&client);
    try std.posix.dup2(stdout_dup, std.posix.STDOUT_FILENO);
    std.posix.close(second_pipe[1]);
    second_pipe[1] = -1;

    var second_buf: [64]u8 = undefined;
    const second_len = try std.posix.read(second_pipe[0], &second_buf);
    try std.testing.expectEqual(@as(usize, 0), second_len);

    xm.allocator.free(session.name);
    session.name = xm.xstrdup("beta");

    var third_pipe: [2]i32 = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.pipe(&third_pipe));
    defer {
        std.posix.close(third_pipe[0]);
        if (third_pipe[1] != -1) std.posix.close(third_pipe[1]);
    }
    try std.posix.dup2(third_pipe[1], std.posix.STDOUT_FILENO);
    ctl_sub.control_check_subscriptions(&client);
    try std.posix.dup2(stdout_dup, std.posix.STDOUT_FILENO);
    std.posix.close(third_pipe[1]);
    third_pipe[1] = -1;

    var third_buf: [256]u8 = undefined;
    const third_len = try std.posix.read(third_pipe[0], &third_buf);
    try std.testing.expectEqualStrings(
        "%subscription-changed watch $41 - - - : beta\n",
        third_buf[0..third_len],
    );
}

test "control_reset_offsets clears an empty control pane list" {
    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);

    var cl: T.Client = undefined;
    cl = .{
        .environ = env,
        .tty = undefined,
        .status = .{},
        .control_panes = .{},
    };
    cl.tty = .{ .client = &cl };

    ctl.control_reset_offsets(&cl);
    try std.testing.expectEqual(@as(usize, 0), cl.control_panes.items.len);
}

test "control_ready sets control_ready_flag" {
    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);

    var cl: T.Client = undefined;
    cl = .{
        .environ = env,
        .tty = undefined,
        .status = .{},
        .control_ready_flag = false,
    };
    cl.tty = .{ .client = &cl };

    ctl.control_ready(&cl);
    try std.testing.expect(cl.control_ready_flag);
}

test "control_write_output flushes escaped pane data for control clients" {
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

    const s = sess.session_create(null, "control-output", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("control-output") != null) sess.session_destroy(s, false, "test");

    const w = win_mod.window_create(80, 24, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    var cause: ?[]u8 = null;
    const wl = sess.session_attach(s, w, 0, &cause) orelse unreachable;
    s.curw = wl;

    const wp = win_mod.window_add_pane(w, null, 80, 24);
    w.active = wp;
    wp.fd = try std.posix.dup(std.posix.STDERR_FILENO);
    try wp.input_pending.appendSlice(xm.allocator, "A\x01\\B");

    var pair: [2]i32 = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &pair));

    var proc = T.ZmuxProc{ .name = "control-output-test" };
    defer proc.peers.deinit(xm.allocator);

    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);

    var cl = T.Client{
        .environ = env,
        .tty = undefined,
        .status = .{},
        .flags = T.CLIENT_CONTROL,
        .session = s,
        .control_all_blocks = .{},
        .control_panes = .{},
    };
    cl.tty = .{ .client = &cl };
    cl.peer = proc_mod.proc_add_peer(&proc, pair[0], test_peer_dispatch, null);
    defer {
        ctl.control_stop(&cl);
        const peer = cl.peer.?;
        c.imsg.imsgbuf_clear(&peer.ibuf);
        std.posix.close(peer.ibuf.fd);
        xm.allocator.destroy(peer);
        proc.peers.clearRetainingCapacity();
        cl.peer = null;
    }
    ctl.control_start(&cl);

    var reader: c.imsg.imsgbuf = undefined;
    try std.testing.expectEqual(@as(i32, 0), c.imsg.imsgbuf_init(&reader, pair[1]));
    defer {
        c.imsg.imsgbuf_clear(&reader);
        std.posix.close(pair[1]);
    }

    ctl.control_write_output(&cl, wp);
    try std.testing.expectEqual(@as(u32, 1), cl.control_pending_count);
    try std.testing.expectEqual(@as(usize, 1), cl.control_panes.items.len);
    try std.testing.expectEqual(@as(usize, 4), cl.control_panes.items[0].queued.used);

    ctl.control_write_callback(&cl);

    const payload = try readPeerStreamPayloadAlloc(&reader);
    defer xm.allocator.free(payload);
    const expected = try std.fmt.allocPrint(xm.allocator, "%output %{d} A\\001\\134B\n", .{wp.id});
    defer xm.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, payload);
    try std.testing.expectEqual(@as(u32, 0), cl.control_pending_count);
    try std.testing.expectEqual(@as(usize, 0), cl.control_all_blocks.items.len);
    try std.testing.expectEqual(@as(usize, 4), cl.control_panes.items[0].offset.used);
}

test "control_read_callback seeds current state for relative targets" {
    cmdq.cmdq_reset_for_tests();
    defer cmdq.cmdq_reset_for_tests();

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

    const s = sess.session_create(null, "control-relative", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("control-relative") != null) sess.session_destroy(s, false, "test");

    var cause: ?[]u8 = null;
    const w0 = win_mod.window_create(20, 6, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    defer win_mod.window_remove_ref(w0, "test");
    const wl0 = sess.session_attach(s, w0, 0, &cause) orelse unreachable;
    const wp0 = win_mod.window_add_pane(w0, null, 20, 6);
    w0.active = wp0;

    const w1 = win_mod.window_create(20, 6, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    defer win_mod.window_remove_ref(w1, "test");
    const wl1 = sess.session_attach(s, w1, 1, &cause) orelse unreachable;
    const wp1 = win_mod.window_add_pane(w1, null, 20, 6);
    w1.active = wp1;
    s.curw = wl0;

    var cl = T.Client{
        .name = "control-relative-client",
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{},
        .flags = T.CLIENT_CONTROL | T.CLIENT_SIZECHANGED | T.CLIENT_ATTACHED,
        .session = s,
    };
    defer env_mod.environ_free(cl.environ);
    cl.tty = .{ .client = &cl, .sx = 20, .sy = 6 };
    try client_registry.clients.append(xm.allocator, &cl);

    ctl.control_read_callback(&cl, "select-window -t :1");
    while (cmdq.cmdq_next(&cl) != 0) {}

    try std.testing.expectEqual(wl1, s.curw.?);
}

test "control_remove_sub from middle preserves remaining order" {
    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);

    var cl: T.Client = undefined;
    cl = .{
        .environ = env,
        .tty = undefined,
        .status = .{},
    };
    cl.tty = .{ .client = &cl };

    ctl_sub.control_add_sub(&cl, "alpha", T.ControlSubType.session, 0, "fmt-a");
    ctl_sub.control_add_sub(&cl, "bravo", T.ControlSubType.pane, 1, "fmt-b");
    ctl_sub.control_add_sub(&cl, "charlie", T.ControlSubType.window, 2, "fmt-c");
    try std.testing.expectEqual(@as(usize, 3), cl.control_subscriptions.items.len);

    ctl_sub.control_remove_sub(&cl, "bravo");
    try std.testing.expectEqual(@as(usize, 2), cl.control_subscriptions.items.len);
    try std.testing.expectEqualStrings("alpha", cl.control_subscriptions.items[0].name);
    try std.testing.expectEqualStrings("charlie", cl.control_subscriptions.items[1].name);
    try std.testing.expectEqual(T.ControlSubType.session, cl.control_subscriptions.items[0].sub_type);
    try std.testing.expectEqual(T.ControlSubType.window, cl.control_subscriptions.items[1].sub_type);

    ctl_sub.control_subscriptions_deinit(&cl);
}

test "control_add_sub re-registration moves subscription to end of list" {
    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);

    var cl: T.Client = undefined;
    cl = .{
        .environ = env,
        .tty = undefined,
        .status = .{},
    };
    cl.tty = .{ .client = &cl };

    ctl_sub.control_add_sub(&cl, "first", T.ControlSubType.session, 0, "#{session_name}");
    ctl_sub.control_add_sub(&cl, "second", T.ControlSubType.window, 5, "#{window_id}");
    try std.testing.expectEqual(@as(usize, 2), cl.control_subscriptions.items.len);
    try std.testing.expectEqualStrings("first", cl.control_subscriptions.items[0].name);

    // Re-add "first" with different type and format — old entry removed, new appended at end
    ctl_sub.control_add_sub(&cl, "first", T.ControlSubType.all_panes, 0, "#{pane_id}");
    try std.testing.expectEqual(@as(usize, 2), cl.control_subscriptions.items.len);
    try std.testing.expectEqualStrings("second", cl.control_subscriptions.items[0].name);
    try std.testing.expectEqualStrings("first", cl.control_subscriptions.items[1].name);
    try std.testing.expectEqual(T.ControlSubType.all_panes, cl.control_subscriptions.items[1].sub_type);
    try std.testing.expectEqualStrings("#{pane_id}", cl.control_subscriptions.items[1].format);

    ctl_sub.control_subscriptions_deinit(&cl);
}

test "control_subscriptions_deinit frees nested pane and window tracking state" {
    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);

    var cl: T.Client = undefined;
    cl = .{
        .environ = env,
        .tty = undefined,
        .status = .{},
    };
    cl.tty = .{ .client = &cl };

    ctl_sub.control_add_sub(&cl, "pane-watch", T.ControlSubType.all_panes, 0, "#{pane_id}");
    ctl_sub.control_add_sub(&cl, "win-watch", T.ControlSubType.all_windows, 0, "#{window_id}");

    // Manually populate nested pane/window tracking state with cached values,
    // simulating what control_check_subscriptions would build up over time.
    var pane_sub = &cl.control_subscriptions.items[0];
    pane_sub.panes.append(xm.allocator, .{
        .pane = 42,
        .idx = 0,
        .last = xm.allocator.dupe(u8, "cached-pane-val") catch unreachable,
    }) catch unreachable;
    pane_sub.panes.append(xm.allocator, .{
        .pane = 43,
        .idx = 1,
        .last = null,
    }) catch unreachable;

    var win_sub = &cl.control_subscriptions.items[1];
    win_sub.windows.append(xm.allocator, .{
        .window = 99,
        .idx = 0,
        .last = xm.allocator.dupe(u8, "cached-win-val") catch unreachable,
    }) catch unreachable;

    // deinit must free all nested state — names, formats, cached values, sub-lists
    ctl_sub.control_subscriptions_deinit(&cl);

    // After deinit the list is reset to empty
    try std.testing.expectEqual(@as(usize, 0), cl.control_subscriptions.items.len);
}

test "control_check_subscriptions emits all registered subscriptions in insertion order" {
    var session_env = T.Environ.init(xm.allocator);
    defer session_env.deinit();
    var session_options = T.Options.init(xm.allocator, null);
    defer session_options.deinit();

    var session = T.Session{
        .id = 77,
        .name = xm.xstrdup("ordered"),
        .cwd = "/",
        .options = &session_options,
        .environ = &session_env,
    };
    defer xm.allocator.free(session.name);

    var client = T.Client{
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{},
        .session = &session,
    };
    defer env_mod.environ_free(client.environ);
    client.tty = .{ .client = &client };

    // Two session subscriptions — both should fire on first check, in insertion order
    ctl_sub.control_add_sub(&client, "first", T.ControlSubType.session, 0, "#{session_name}");
    ctl_sub.control_add_sub(&client, "second", T.ControlSubType.session, 0, "#{session_name}");
    defer ctl_sub.control_subscriptions_deinit(&client);

    var pipe_fds: [2]i32 = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.pipe(&pipe_fds));
    defer {
        std.posix.close(pipe_fds[0]);
        if (pipe_fds[1] != -1) std.posix.close(pipe_fds[1]);
    }
    const stdout_dup = try std.posix.dup(std.posix.STDOUT_FILENO);
    defer std.posix.close(stdout_dup);
    try std.posix.dup2(pipe_fds[1], std.posix.STDOUT_FILENO);
    ctl_sub.control_check_subscriptions(&client);
    try std.posix.dup2(stdout_dup, std.posix.STDOUT_FILENO);
    std.posix.close(pipe_fds[1]);
    pipe_fds[1] = -1;

    var buf: [512]u8 = undefined;
    const len = try std.posix.read(pipe_fds[0], &buf);
    const output = buf[0..len];

    // "first" emitted before "second", matching insertion order
    const expected =
        "%subscription-changed first $77 - - - : ordered\n" ++
        "%subscription-changed second $77 - - - : ordered\n";
    try std.testing.expectEqualStrings(expected, output);
}

test "control_check_subs_timer_fire with subscriptions but no session is safe" {
    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);

    var cl: T.Client = undefined;
    cl = .{
        .environ = env,
        .tty = undefined,
        .status = .{},
        .session = null,
    };
    cl.tty = .{ .client = &cl };

    // Register subscriptions but leave session null — timer fire should no-op
    ctl_sub.control_add_sub(&cl, "watch-a", T.ControlSubType.session, 0, "#{session_name}");
    ctl_sub.control_add_sub(&cl, "watch-b", T.ControlSubType.all_panes, 0, "#{pane_id}");
    try std.testing.expectEqual(@as(usize, 2), cl.control_subscriptions.items.len);

    // Timer fire dispatches to control_check_subscriptions which returns early on null session
    ctl_sub.control_check_subs_timer_fire(&cl);

    // Subscriptions still present, no cached values populated
    try std.testing.expectEqual(@as(usize, 2), cl.control_subscriptions.items.len);
    try std.testing.expect(cl.control_subscriptions.items[0].last == null);
    try std.testing.expect(cl.control_subscriptions.items[1].last == null);

    ctl_sub.control_subscriptions_deinit(&cl);
}
