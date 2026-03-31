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
// Ported in part from tmux/window.c.
// Original copyright:
//   Copyright (c) 2007 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

//! window-mode-runtime.zig – shared redraw fallout for pane mode transitions.

const std = @import("std");
const T = @import("types.zig");
const notify = @import("notify.zig");
const server = @import("server.zig");
const window = @import("window.zig");

pub fn noteModeRedraw(wp: *T.WindowPane) void {
    wp.flags |= T.PANE_REDRAW | T.PANE_CHANGED;
    server.server_redraw_pane(wp);
    server.server_redraw_window_borders(wp.window);
    server.server_status_window(wp.window);
}

pub fn noteModeChange(wp: *T.WindowPane) void {
    noteModeRedraw(wp);
    notify.notify_pane("pane-mode-changed", wp);
}

pub fn pushMode(
    wp: *T.WindowPane,
    mode: *const T.WindowMode,
    data: ?*anyopaque,
    swp: ?*T.WindowPane,
) *T.WindowModeEntry {
    const wme = window.window_pane_push_mode(wp, mode, data, swp);
    noteModeChange(wp);
    return wme;
}

pub fn popMode(wp: *T.WindowPane, wme: *T.WindowModeEntry) bool {
    const was_active = window.window_pane_mode(wp) == wme;
    const popped = window.window_pane_pop_mode(wp, wme);
    if (popped and was_active) noteModeChange(wp);
    return popped;
}

pub fn resetMode(wp: *T.WindowPane) bool {
    const wme = window.window_pane_mode(wp) orelse return false;
    if (wme.mode.close) |close_mode| close_mode(wme);
    _ = window.window_pane_pop_mode(wp, wme);
    noteModeChange(wp);
    return true;
}

pub fn resetModeAll(wp: *T.WindowPane) void {
    while (resetMode(wp)) {}
}

fn initTestGlobals() void {
    const env_mod = @import("environ.zig");
    const opts = @import("options.zig");
    const sess = @import("session.zig");

    sess.session_init_globals(@import("xmalloc.zig").allocator);
    window.window_init_globals(@import("xmalloc.zig").allocator);

    opts.global_options = opts.options_create(null);
    opts.global_s_options = opts.options_create(null);
    opts.global_w_options = opts.options_create(null);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);

    env_mod.global_environ = env_mod.environ_create();
}

fn deinitTestGlobals() void {
    const env_mod = @import("environ.zig");
    const opts = @import("options.zig");

    env_mod.environ_free(env_mod.global_environ);
    opts.options_free(opts.global_w_options);
    opts.options_free(opts.global_s_options);
    opts.options_free(opts.global_options);
}

const TestSetup = struct {
    session: *T.Session,
    pane: *T.WindowPane,
};

fn testSetup(session_name: []const u8) !TestSetup {
    const cmdq = @import("cmd-queue.zig");
    const env_mod = @import("environ.zig");
    const opts = @import("options.zig");
    const sess = @import("session.zig");

    const session = sess.session_create(null, session_name, "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    const pane_window = window.window_create(80, 24, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    const pane = window.window_add_pane(pane_window, null, 80, 24);
    pane_window.active = pane;

    var cause: ?[]u8 = null;
    const wl = sess.session_attach(session, pane_window, -1, &cause).?;
    session.curw = wl;
    while (cmdq.cmdq_next(null) != 0) {}

    return .{
        .session = session,
        .pane = pane,
    };
}

test "window-mode-runtime push and pop emit pane-mode-changed hooks" {
    const cmdq = @import("cmd-queue.zig");
    const env_mod = @import("environ.zig");
    const opts = @import("options.zig");
    const sess = @import("session.zig");
    const xm = @import("xmalloc.zig");

    cmdq.cmdq_reset_for_tests();
    defer cmdq.cmdq_reset_for_tests();

    initTestGlobals();
    defer deinitTestGlobals();

    const setup = try testSetup("mode-runtime-hook");
    defer if (sess.session_find("mode-runtime-hook") != null) sess.session_destroy(setup.session, false, "test");

    opts.options_set_array(setup.pane.options, "pane-mode-changed", &.{
        "set-environment -g -F HOOK_VALUE '#{hook_pane}:#{pane_in_mode}'",
    });

    const mode = T.WindowMode{ .name = "mode-runtime-hook" };

    const pushed = pushMode(setup.pane, &mode, null, null);
    while (cmdq.cmdq_next(null) != 0) {}

    const expected_push = xm.xasprintf("%{d}:1", .{setup.pane.id});
    defer xm.allocator.free(expected_push);
    try std.testing.expectEqualStrings(expected_push, env_mod.environ_find(env_mod.global_environ, "HOOK_VALUE").?.value.?);
    try std.testing.expect((setup.pane.flags & T.PANE_REDRAW) != 0);
    try std.testing.expect((setup.pane.flags & T.PANE_CHANGED) != 0);

    setup.pane.flags = 0;
    try std.testing.expect(popMode(setup.pane, pushed));
    while (cmdq.cmdq_next(null) != 0) {}

    const expected_pop = xm.xasprintf("%{d}:0", .{setup.pane.id});
    defer xm.allocator.free(expected_pop);
    try std.testing.expectEqualStrings(expected_pop, env_mod.environ_find(env_mod.global_environ, "HOOK_VALUE").?.value.?);
    try std.testing.expect(window.window_pane_mode(setup.pane) == null);
    try std.testing.expect((setup.pane.flags & T.PANE_REDRAW) != 0);
    try std.testing.expect((setup.pane.flags & T.PANE_CHANGED) != 0);
}

test "window-mode-runtime transitions emit pane-mode-changed control messages" {
    const c = @import("c.zig");
    const cmdq = @import("cmd-queue.zig");
    const env_mod = @import("environ.zig");
    const proc_mod = @import("proc.zig");
    const protocol = @import("zmux-protocol.zig");
    const registry = @import("client-registry.zig");
    const sess = @import("session.zig");
    const xm = @import("xmalloc.zig");

    const helpers = struct {
        fn noopDispatch(_: ?*c.imsg.imsg, _: ?*anyopaque) callconv(.c) void {}

        fn expectPaneModeChanged(reader: *c.imsg.imsgbuf, pane_id: u32) !void {
            var imsg_msg: c.imsg.imsg = undefined;
            while (c.imsg.imsg_get(reader, &imsg_msg) <= 0)
                try std.testing.expectEqual(@as(i32, 1), c.imsg.imsgbuf_read(reader));
            defer c.imsg.imsg_free(&imsg_msg);

            try std.testing.expectEqual(@as(u32, @intCast(@intFromEnum(protocol.MsgType.write))), c.imsg.imsg_get_type(&imsg_msg));

            const payload_len = c.imsg.imsg_get_len(&imsg_msg);
            var payload = try xm.allocator.alloc(u8, payload_len);
            defer xm.allocator.free(payload);
            try std.testing.expectEqual(@as(i32, 0), c.imsg.imsg_get_data(&imsg_msg, payload.ptr, payload.len));

            var stream: i32 = 0;
            @memcpy(std.mem.asBytes(&stream), payload[0..@sizeOf(i32)]);
            try std.testing.expectEqual(@as(i32, 1), stream);

            const expected = xm.xasprintf("%pane-mode-changed %{d}\n", .{pane_id});
            defer xm.allocator.free(expected);
            try std.testing.expectEqualStrings(expected, payload[@sizeOf(i32)..]);
        }
    };

    cmdq.cmdq_reset_for_tests();
    defer cmdq.cmdq_reset_for_tests();
    registry.clients.clearRetainingCapacity();
    defer registry.clients.clearRetainingCapacity();

    initTestGlobals();
    defer deinitTestGlobals();

    const setup = try testSetup("mode-runtime-control");
    defer if (sess.session_find("mode-runtime-control") != null) sess.session_destroy(setup.session, false, "test");

    var pair: [2]i32 = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &pair));

    var proc = T.ZmuxProc{ .name = "mode-runtime-control-test" };
    defer proc.peers.deinit(xm.allocator);

    var client = T.Client{
        .name = "mode-runtime-client",
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{ .screen = undefined },
        .session = setup.session,
        .flags = T.CLIENT_CONTROL | T.CLIENT_UTF8,
    };
    defer env_mod.environ_free(client.environ);
    client.tty = .{ .client = &client };
    client.peer = proc_mod.proc_add_peer(&proc, pair[0], helpers.noopDispatch, null);
    defer {
        registry.remove(&client);
        const peer = client.peer.?;
        c.imsg.imsgbuf_clear(&peer.ibuf);
        std.posix.close(peer.ibuf.fd);
        xm.allocator.destroy(peer);
        proc.peers.clearRetainingCapacity();
    }
    registry.add(&client);

    var reader: c.imsg.imsgbuf = undefined;
    try std.testing.expectEqual(@as(i32, 0), c.imsg.imsgbuf_init(&reader, pair[1]));
    defer {
        c.imsg.imsgbuf_clear(&reader);
        std.posix.close(pair[1]);
    }

    const first_mode = T.WindowMode{ .name = "first-mode" };
    const second_mode = T.WindowMode{ .name = "second-mode" };

    const pushed = pushMode(setup.pane, &first_mode, null, null);
    try helpers.expectPaneModeChanged(&reader, setup.pane.id);
    while (cmdq.cmdq_next(null) != 0) {}

    try std.testing.expect(popMode(setup.pane, pushed));
    try helpers.expectPaneModeChanged(&reader, setup.pane.id);
    while (cmdq.cmdq_next(null) != 0) {}

    _ = pushMode(setup.pane, &first_mode, null, null);
    try helpers.expectPaneModeChanged(&reader, setup.pane.id);
    while (cmdq.cmdq_next(null) != 0) {}

    _ = pushMode(setup.pane, &second_mode, null, null);
    try helpers.expectPaneModeChanged(&reader, setup.pane.id);
    while (cmdq.cmdq_next(null) != 0) {}

    resetModeAll(setup.pane);
    try helpers.expectPaneModeChanged(&reader, setup.pane.id);
    try helpers.expectPaneModeChanged(&reader, setup.pane.id);
    while (cmdq.cmdq_next(null) != 0) {}
}
