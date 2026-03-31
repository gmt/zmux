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
// Ported in part from tmux/cmd-copy-mode.c.
// Original copyright:
//   Copyright (c) 2007 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

const std = @import("std");
const T = @import("types.zig");
const cmd_mod = @import("cmd.zig");
const cmd_find = @import("cmd-find.zig");
const cmdq = @import("cmd-queue.zig");
const mouse_runtime = @import("mouse-runtime.zig");
const window_clock = @import("window-clock.zig");
const window_copy = @import("window-copy.zig");
const window_mode_runtime = @import("window-mode-runtime.zig");

fn exec(cmd: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {
    const args = cmd_mod.cmd_get_args(cmd);
    const is_clock = cmd_mod.cmd_get_entry(cmd) == &entry_clock;

    if (args.has('q')) {
        var target: T.CmdFindState = .{};
        if (cmd_find.cmd_find_target(&target, item, args.get('t'), .pane, 0) != 0)
            return .@"error";
        const wp = target.wp orelse return .@"error";
        window_mode_runtime.resetModeAll(wp);
        return .normal;
    }

    var target_wp: *T.WindowPane = undefined;
    if (args.has('M')) {
        const client = cmdq.cmdq_get_client(item);
        const event = cmdq.cmdq_get_event(item);

        var mouse_session: ?*T.Session = null;
        var mouse_wl: ?*T.Winlink = null;
        target_wp = mouse_runtime.cmd_mouse_pane(&event.m, &mouse_session, &mouse_wl) orelse return .normal;
        if (client == null or client.?.session != mouse_session.?) return .normal;
    } else {
        var target: T.CmdFindState = .{};
        if (cmd_find.cmd_find_target(&target, item, args.get('t'), .pane, 0) != 0)
            return .@"error";
        target_wp = target.wp orelse return .@"error";
    }

    var source_wp: ?*T.WindowPane = null;
    if (args.has('s')) {
        var source: T.CmdFindState = .{};
        if (cmd_find.cmd_find_target(&source, item, args.get('s'), .pane, 0) != 0)
            return .@"error";
        source_wp = source.wp orelse return .@"error";
    }

    if (is_clock) {
        window_clock.enter_mode(target_wp);
        return .normal;
    }

    const client = cmdq.cmdq_get_client(item);
    const event = cmdq.cmdq_get_event(item);

    _ = window_copy.enterMode(target_wp, source_wp orelse target_wp, args);
    if (args.has('M')) window_copy.startDrag(client, &event.m);
    if (args.has('u')) window_copy.pageUp(target_wp, false);
    if (args.has('d')) window_copy.pageDown(target_wp, false, args.has('e'));
    if (args.has('S')) {
        if (client) |cl| window_copy.scrollToMouse(target_wp, cl.tty.mouse_slider_mpos, event.m.y, args.has('e'));
        return .normal;
    }
    return .normal;
}

pub const entry: cmd_mod.CmdEntry = .{
    .name = "copy-mode",
    .usage = "[-deHMqSu] [-s src-pane] [-t target-pane]",
    .template = "deHMqSs:t:u",
    .lower = 0,
    .upper = 0,
    .flags = T.CMD_AFTERHOOK | T.CMD_READONLY,
    .exec = exec,
};

pub const entry_clock: cmd_mod.CmdEntry = .{
    .name = "clock-mode",
    .usage = "[-t target-pane]",
    .template = "t:",
    .lower = 0,
    .upper = 0,
    .flags = T.CMD_AFTERHOOK,
    .exec = exec,
};

fn init_test_globals() void {
    const env_mod = @import("environ.zig");
    const opts = @import("options.zig");
    const sess = @import("session.zig");
    const win = @import("window.zig");

    sess.session_init_globals(@import("xmalloc.zig").allocator);
    win.window_init_globals(@import("xmalloc.zig").allocator);

    opts.global_options = opts.options_create(null);
    opts.global_s_options = opts.options_create(null);
    opts.global_w_options = opts.options_create(null);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);

    env_mod.global_environ = env_mod.environ_create();
}

fn deinit_test_globals() void {
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
    winlink: *T.Winlink,
};

fn test_setup(session_name: []const u8) !TestSetup {
    const env_mod = @import("environ.zig");
    const opts = @import("options.zig");
    const sess = @import("session.zig");
    const spawn = @import("spawn.zig");

    const session = sess.session_create(null, session_name, "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    var cause: ?[]u8 = null;
    var ctx: T.SpawnContext = .{ .s = session, .idx = -1, .flags = T.SPAWN_EMPTY };
    const wl = spawn.spawn_window(&ctx, &cause).?;
    return .{
        .session = session,
        .pane = wl.window.active.?,
        .winlink = wl,
    };
}

test "copy-mode and clock-mode are registered" {
    try std.testing.expectEqual(&entry, cmd_mod.cmd_find_entry("copy-mode").?);
    try std.testing.expectEqual(&entry_clock, cmd_mod.cmd_find_entry("clock-mode").?);
}

test "copy-mode -q clears the reduced pane mode stack" {
    const screen_mod = @import("screen.zig");
    const server_print = @import("server-print.zig");
    const sess = @import("session.zig");
    const win = @import("window.zig");
    const xm = @import("xmalloc.zig");

    init_test_globals();
    defer deinit_test_globals();

    const setup = try test_setup("copy-mode-quit");
    defer if (sess.session_find("copy-mode-quit") != null) sess.session_destroy(setup.session, false, "test");

    try std.testing.expect(server_print.server_pane_view_data(setup.pane, "hello", true));
    try std.testing.expect(win.window_pane_mode(setup.pane) != null);
    try std.testing.expect(screen_mod.screen_alternate_active(setup.pane));

    const target = try std.fmt.allocPrint(xm.allocator, "%{d}", .{setup.pane.id});
    defer xm.allocator.free(target);

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "copy-mode", "-q", "-t", target }, null, &cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));
    try std.testing.expect(win.window_pane_mode(setup.pane) == null);
    try std.testing.expect(!screen_mod.screen_alternate_active(setup.pane));
}

test "copy-mode enters the reduced window-copy runtime" {
    const sess = @import("session.zig");
    const xm = @import("xmalloc.zig");
    const screen_mod = @import("screen.zig");
    const win = @import("window.zig");

    init_test_globals();
    defer deinit_test_globals();

    const setup = try test_setup("copy-mode-missing");
    defer if (sess.session_find("copy-mode-missing") != null) sess.session_destroy(setup.session, false, "test");

    const target = try std.fmt.allocPrint(xm.allocator, "%{d}", .{setup.pane.id});
    defer xm.allocator.free(target);

    var env = T.Environ.init(xm.allocator);
    defer env.deinit();

    var client = T.Client{
        .name = "copy-mode-client",
        .environ = &env,
        .tty = undefined,
        .status = .{},
        .flags = T.CLIENT_ATTACHED,
        .session = setup.session,
    };
    client.tty = .{ .client = &client };
    defer if (client.message_string) |msg| xm.allocator.free(msg);

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "copy-mode", "-t", target }, null, &cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &client, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));
    try std.testing.expect(client.message_string == null);
    try std.testing.expect(screen_mod.screen_alternate_active(setup.pane));
    try std.testing.expectEqual(&window_copy.window_copy_mode, win.window_pane_mode(setup.pane).?.mode);
}

test "clock-mode enters the shared window clock mode" {
    const screen_mod = @import("screen.zig");
    const sess = @import("session.zig");
    const win = @import("window.zig");
    const xm = @import("xmalloc.zig");

    init_test_globals();
    defer deinit_test_globals();

    const setup = try test_setup("clock-mode-missing");
    defer if (sess.session_find("clock-mode-missing") != null) sess.session_destroy(setup.session, false, "test");

    const target = try std.fmt.allocPrint(xm.allocator, "%{d}", .{setup.pane.id});
    defer xm.allocator.free(target);

    var env = T.Environ.init(xm.allocator);
    defer env.deinit();

    var client = T.Client{
        .name = "clock-mode-client",
        .environ = &env,
        .tty = undefined,
        .status = .{},
        .flags = T.CLIENT_ATTACHED,
        .session = setup.session,
    };
    client.tty = .{ .client = &client };
    defer if (client.message_string) |msg| xm.allocator.free(msg);

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "clock-mode", "-t", target }, null, &cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &client, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));
    try std.testing.expect(client.message_string == null);
    try std.testing.expect(screen_mod.screen_alternate_active(setup.pane));
    try std.testing.expectEqual(&window_clock.window_clock_mode, win.window_pane_mode(setup.pane).?.mode);
}

test "copy-mode -M is a quiet no-op when the mouse pane is in another session" {
    const sess = @import("session.zig");
    const xm = @import("xmalloc.zig");

    init_test_globals();
    defer deinit_test_globals();

    const local = try test_setup("copy-mode-local");
    defer if (sess.session_find("copy-mode-local") != null) sess.session_destroy(local.session, false, "test");
    const foreign = try test_setup("copy-mode-foreign");
    defer if (sess.session_find("copy-mode-foreign") != null) sess.session_destroy(foreign.session, false, "test");

    var env = T.Environ.init(xm.allocator);
    defer env.deinit();

    var client = T.Client{
        .name = "copy-mode-mouse-client",
        .environ = &env,
        .tty = undefined,
        .status = .{},
        .flags = T.CLIENT_ATTACHED,
        .session = local.session,
    };
    client.tty = .{ .client = &client };
    defer if (client.message_string) |msg| xm.allocator.free(msg);

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "copy-mode", "-M" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{
        .client = &client,
        .cmdlist = &list,
        .event = .{
            .m = .{
                .valid = true,
                .key = T.keycMouse(T.KEYC_MOUSEDOWN1, .pane),
                .s = @intCast(foreign.session.id),
                .w = @intCast(foreign.winlink.window.id),
                .wp = @intCast(foreign.pane.id),
            },
        },
    };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));
    try std.testing.expect(client.message_string == null);
}

test "copy-mode -M starts reduced cursor drag tracking on the mouse pane" {
    const grid = @import("grid.zig");
    const screen_mod = @import("screen.zig");
    const sess = @import("session.zig");
    const win = @import("window.zig");
    const xm = @import("xmalloc.zig");

    init_test_globals();
    defer deinit_test_globals();

    const setup = try test_setup("copy-mode-drag");
    defer if (sess.session_find("copy-mode-drag") != null) sess.session_destroy(setup.session, false, "test");

    grid.set_ascii(setup.pane.base.grid, 1, 0, 'a');
    grid.set_ascii(setup.pane.base.grid, 1, 1, 'b');
    grid.set_ascii(setup.pane.base.grid, 1, 2, 'c');

    var env = T.Environ.init(xm.allocator);
    defer env.deinit();

    var client = T.Client{
        .name = "copy-mode-drag-client",
        .environ = &env,
        .tty = undefined,
        .status = .{},
        .flags = T.CLIENT_ATTACHED,
        .session = setup.session,
    };
    client.tty = .{ .client = &client };
    defer if (client.message_string) |msg| xm.allocator.free(msg);

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "copy-mode", "-M" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{
        .client = &client,
        .cmdlist = &list,
        .event = .{
            .m = .{
                .valid = true,
                .key = T.keycMouse(T.KEYC_MOUSEDRAG1, .pane),
                .s = @intCast(setup.session.id),
                .w = @intCast(setup.winlink.window.id),
                .wp = @intCast(setup.pane.id),
                .x = 3,
                .y = 1,
                .lx = 2,
                .ly = 1,
            },
        },
    };

    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));
    try std.testing.expect(client.message_string == null);
    try std.testing.expect(screen_mod.screen_alternate_active(setup.pane));
    try std.testing.expectEqual(&window_copy.window_copy_mode, win.window_pane_mode(setup.pane).?.mode);
    try std.testing.expect(client.tty.mouse_drag_update != null);
    try std.testing.expectEqual(@as(u32, 2), setup.pane.screen.cx);
    try std.testing.expectEqual(@as(u32, 1), setup.pane.screen.cy);
}
