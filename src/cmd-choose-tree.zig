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
// Ported in part from tmux/cmd-choose-tree.c.
// Original copyright:
//   Copyright (c) 2012 Thomas Adam <thomas@xteddy.org>
//   ISC licence – same terms as above.

const std = @import("std");
const T = @import("types.zig");
const client_registry = @import("client-registry.zig");
const cmd_find = @import("cmd-find.zig");
const cmd_mod = @import("cmd.zig");
const cmdq = @import("cmd-queue.zig");
const paste_mod = @import("paste.zig");
const sort_mod = @import("sort.zig");
const window_buffer = @import("window-buffer.zig");
const window_client = @import("window-client.zig");
const window_customize = @import("window-customize.zig");
const window_tree = @import("window-tree.zig");
const xm = @import("xmalloc.zig");

fn exec(cmd: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {
    const args = cmd_mod.cmd_get_args(cmd);

    var target: T.CmdFindState = .{};
    if (cmd_find.cmd_find_target(&target, item, args.get('t'), .pane, 0) != 0)
        return .@"error";
    const wp = target.wp orelse return .@"error";

    const order = sort_mod.sort_order_from_string(args.get('O'));
    if (order == .end and args.has('O')) {
        cmdq.cmdq_error(item, "invalid sort order", .{});
        return .@"error";
    }

    if (cmd.entry == &entry_buffer and paste_mod.paste_is_empty())
        return .normal;
    if (cmd.entry == &entry_client and !window_client.hasSelectableClients())
        return .normal;

    if (cmd.entry == &entry_client) {
        if (args.has('K')) {
            cmdq.cmdq_error(item, "choose-client custom key format not supported yet", .{});
            return .@"error";
        }
        if (args.has('N') or args.has('Z') or args.has('y')) {
            cmdq.cmdq_error(item, "choose-client preview flags not supported yet", .{});
            return .@"error";
        }
        _ = window_client.enterMode(wp, args);
        return .normal;
    }

    if (cmd.entry == &entry_buffer) {
        if (args.has('K')) {
            cmdq.cmdq_error(item, "choose-buffer custom key format not supported yet", .{});
            return .@"error";
        }
        if (args.has('N') or args.has('y')) {
            cmdq.cmdq_error(item, "choose-buffer preview flags not supported yet", .{});
            return .@"error";
        }
        _ = window_buffer.enterMode(wp, &target, args);
        return .normal;
    }
    if (cmd.entry == &entry_customize_mode) {
        _ = window_customize.enterMode(wp, &target, args);
        return .normal;
    }
    if (args.has('K')) {
        cmdq.cmdq_error(item, "choose-tree custom key format not supported yet", .{});
        return .@"error";
    }

    _ = window_tree.enterMode(wp, .{
        .fs = &target,
        .kind = if (args.has('s'))
            .session
        else if (args.has('w'))
            .window
        else
            .pane,
        .format = args.get('F'),
        .filter = args.get('f'),
        .command = args.value_at(0),
        .sort_crit = .{
            .order = order,
            .reversed = args.has('r'),
        },
        .squash_groups = !args.has('G'),
        .zoom = args.has('Z'),
    });
    return .normal;
}

pub const entry: cmd_mod.CmdEntry = .{
    .name = "choose-tree",
    .usage = "[-GNrswZ] [-F format] [-f filter] [-K key-format] [-O sort-order] [-t target-pane] [template]",
    .template = "F:f:GK:NO:rst:wyZ",
    .lower = 0,
    .upper = 1,
    .flags = 0,
    .exec = exec,
};

pub const entry_client: cmd_mod.CmdEntry = .{
    .name = "choose-client",
    .usage = "[-NrZ] [-F format] [-f filter] [-K key-format] [-O sort-order] [-t target-pane] [template]",
    .template = "F:f:K:NO:rt:yZ",
    .lower = 0,
    .upper = 1,
    .flags = 0,
    .exec = exec,
};

pub const entry_buffer: cmd_mod.CmdEntry = .{
    .name = "choose-buffer",
    .usage = "[-NrZ] [-F format] [-f filter] [-K key-format] [-O sort-order] [-t target-pane] [template]",
    .template = "F:f:K:NO:rt:yZ",
    .lower = 0,
    .upper = 1,
    .flags = 0,
    .exec = exec,
};

pub const entry_customize_mode: cmd_mod.CmdEntry = .{
    .name = "customize-mode",
    .usage = "[-NZ] [-F format] [-f filter] [-t target-pane]",
    .template = "F:f:Nt:yZ",
    .lower = 0,
    .upper = 0,
    .flags = 0,
    .exec = exec,
};

fn init_test_globals() void {
    const env_mod = @import("environ.zig");
    const opts = @import("options.zig");
    const sess = @import("session.zig");
    const win_mod = @import("window.zig");

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
};

fn test_setup(session_name: []const u8) !TestSetup {
    const env_mod = @import("environ.zig");
    const opts = @import("options.zig");
    const sess = @import("session.zig");
    const spawn = @import("spawn.zig");

    const s = sess.session_create(null, session_name, "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    var cause: ?[]u8 = null;
    var ctx: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const wl = spawn.spawn_window(&ctx, &cause).?;
    return .{ .session = s, .pane = wl.window.active.? };
}

fn test_target(alloc: std.mem.Allocator, session_name: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}:0.0", .{session_name});
}

test "choose-tree family commands are registered" {
    try std.testing.expectEqual(&entry, cmd_mod.cmd_find_entry("choose-tree").?);
    try std.testing.expectEqual(&entry_client, cmd_mod.cmd_find_entry("choose-client").?);
    try std.testing.expectEqual(&entry_buffer, cmd_mod.cmd_find_entry("choose-buffer").?);
    try std.testing.expectEqual(&entry_customize_mode, cmd_mod.cmd_find_entry("customize-mode").?);
}

test "customize-mode enters the reduced options mode" {
    const sess = @import("session.zig");
    const window = @import("window.zig");

    init_test_globals();
    defer deinit_test_globals();

    const setup = try test_setup("customize-mode-live");
    defer if (sess.session_find("customize-mode-live") != null) sess.session_destroy(setup.session, false, "test");

    const target = try test_target(xm.allocator, "customize-mode-live");
    defer xm.allocator.free(target);

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "customize-mode", "-t", target }, null, &cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));
    try std.testing.expect(window.window_pane_mode(setup.pane) != null);
    try std.testing.expectEqual(&window_customize.window_customize_mode, window.window_pane_mode(setup.pane).?.mode);
}

test "choose-buffer is a no-op when there are no paste buffers" {
    const sess = @import("session.zig");

    init_test_globals();
    defer deinit_test_globals();
    paste_mod.paste_reset_for_tests();

    const setup = try test_setup("choose-buffer-empty");
    defer if (sess.session_find("choose-buffer-empty") != null) sess.session_destroy(setup.session, false, "test");

    const target = try test_target(xm.allocator, "choose-buffer-empty");
    defer xm.allocator.free(target);

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "choose-buffer", "-t", target }, null, &cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));
}

test "choose-buffer enters the reduced buffer mode when paste buffers exist" {
    const sess = @import("session.zig");
    const win = @import("window.zig");

    init_test_globals();
    defer deinit_test_globals();
    paste_mod.paste_reset_for_tests();
    paste_mod.paste_add(null, xm.xstrdup("buffer body"));

    const setup = try test_setup("choose-buffer-live");
    defer if (sess.session_find("choose-buffer-live") != null) sess.session_destroy(setup.session, false, "test");

    const target = try test_target(xm.allocator, "choose-buffer-live");
    defer xm.allocator.free(target);

    var env = T.Environ.init(xm.allocator);
    defer env.deinit();

    var client = T.Client{
        .name = "choose-buffer-client",
        .environ = &env,
        .tty = undefined,
        .status = .{ .screen = undefined },
        .flags = T.CLIENT_ATTACHED,
        .session = setup.session,
    };
    client.tty = .{ .client = &client };

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "choose-buffer", "-t", target }, null, &cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &client, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));
    try std.testing.expectEqual(&window_buffer.window_buffer_mode, win.window_pane_mode(setup.pane).?.mode);
}

test "choose-buffer rejects unsupported custom key format" {
    const sess = @import("session.zig");

    init_test_globals();
    defer deinit_test_globals();
    paste_mod.paste_reset_for_tests();
    paste_mod.paste_add(null, xm.xstrdup("buffer body"));

    const setup = try test_setup("choose-buffer-key-format");
    defer if (sess.session_find("choose-buffer-key-format") != null) sess.session_destroy(setup.session, false, "test");

    const target = try test_target(xm.allocator, "choose-buffer-key-format");
    defer xm.allocator.free(target);

    var env = T.Environ.init(xm.allocator);
    defer env.deinit();

    var client = T.Client{
        .name = "choose-buffer-key-format-client",
        .environ = &env,
        .tty = undefined,
        .status = .{ .screen = undefined },
        .flags = T.CLIENT_ATTACHED,
        .session = setup.session,
    };
    client.tty = .{ .client = &client };

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "choose-buffer", "-K", "#{line}", "-t", target }, null, &cause);
    defer cmd_mod.cmd_free(cmd);
    defer if (client.message_string) |msg| xm.allocator.free(msg);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &client, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.@"error", cmd_mod.cmd_execute(cmd, &item));
    try std.testing.expectEqualStrings("Choose-buffer custom key format not supported yet", client.message_string.?);
}

test "choose-client is a no-op when there are no clients" {
    const sess = @import("session.zig");

    init_test_globals();
    defer deinit_test_globals();
    defer client_registry.clients.clearRetainingCapacity();

    const setup = try test_setup("choose-client-empty");
    defer if (sess.session_find("choose-client-empty") != null) sess.session_destroy(setup.session, false, "test");

    const target = try test_target(xm.allocator, "choose-client-empty");
    defer xm.allocator.free(target);

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "choose-client", "-t", target }, null, &cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));
}

test "choose-client enters the reduced client mode when clients exist" {
    const sess = @import("session.zig");
    const win = @import("window.zig");

    init_test_globals();
    defer deinit_test_globals();
    defer client_registry.clients.clearRetainingCapacity();

    const setup = try test_setup("choose-client-live");
    defer if (sess.session_find("choose-client-live") != null) sess.session_destroy(setup.session, false, "test");

    var env = T.Environ.init(xm.allocator);
    defer env.deinit();
    var target_client = T.Client{
        .name = "target-client",
        .ttyname = xm.xstrdup("/dev/pts/451"),
        .environ = &env,
        .tty = undefined,
        .status = .{ .screen = undefined },
        .flags = T.CLIENT_ATTACHED,
        .session = setup.session,
    };
    defer xm.allocator.free(target_client.ttyname.?);
    target_client.tty = .{ .client = &target_client };
    client_registry.add(&target_client);

    const target = try test_target(xm.allocator, "choose-client-live");
    defer xm.allocator.free(target);

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "choose-client", "-t", target }, null, &cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));
    try std.testing.expectEqual(&window_client.window_client_mode, win.window_pane_mode(setup.pane).?.mode);
}

test "choose-client rejects unsupported custom key format flags" {
    const sess = @import("session.zig");

    init_test_globals();
    defer deinit_test_globals();
    defer client_registry.clients.clearRetainingCapacity();

    const setup = try test_setup("choose-client-key-format");
    defer if (sess.session_find("choose-client-key-format") != null) sess.session_destroy(setup.session, false, "test");

    var env = T.Environ.init(xm.allocator);
    defer env.deinit();
    var current_client = T.Client{
        .name = "choose-client-current",
        .environ = &env,
        .tty = undefined,
        .status = .{ .screen = undefined },
        .flags = T.CLIENT_ATTACHED,
        .session = setup.session,
    };
    current_client.tty = .{ .client = &current_client };
    defer if (current_client.message_string) |msg| xm.allocator.free(msg);

    var target_client = T.Client{
        .name = "target-client",
        .ttyname = xm.xstrdup("/dev/pts/452"),
        .environ = &env,
        .tty = undefined,
        .status = .{ .screen = undefined },
        .flags = T.CLIENT_ATTACHED,
        .session = setup.session,
    };
    defer xm.allocator.free(target_client.ttyname.?);
    target_client.tty = .{ .client = &target_client };
    client_registry.add(&target_client);

    const target = try test_target(xm.allocator, "choose-client-key-format");
    defer xm.allocator.free(target);

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "choose-client", "-K", "#{line}", "-t", target }, null, &cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &current_client, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.@"error", cmd_mod.cmd_execute(cmd, &item));
    try std.testing.expectEqualStrings("Choose-client custom key format not supported yet", current_client.message_string.?);
}

test "choose-tree enters the reduced window-tree mode" {
    const sess = @import("session.zig");
    const win = @import("window.zig");

    init_test_globals();
    defer deinit_test_globals();

    const setup = try test_setup("choose-tree-live");
    defer if (sess.session_find("choose-tree-live") != null) sess.session_destroy(setup.session, false, "test");

    const target = try test_target(xm.allocator, "choose-tree-live");
    defer xm.allocator.free(target);

    var env = T.Environ.init(xm.allocator);
    defer env.deinit();

    var client = T.Client{
        .name = "choose-tree-client",
        .environ = &env,
        .tty = undefined,
        .status = .{ .screen = undefined },
        .flags = T.CLIENT_ATTACHED,
        .session = setup.session,
    };
    client.tty = .{ .client = &client };

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "choose-tree", "-t", target }, null, &cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &client, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));
    try std.testing.expectEqual(&window_tree.window_tree_mode, win.window_pane_mode(setup.pane).?.mode);
}

test "choose-tree -Z passes zoom through to the reduced tree mode" {
    const sess = @import("session.zig");
    const win = @import("window.zig");
    const window_mode_runtime = @import("window-mode-runtime.zig");

    init_test_globals();
    defer deinit_test_globals();

    const setup = try test_setup("choose-tree-zoom");
    defer if (sess.session_find("choose-tree-zoom") != null) sess.session_destroy(setup.session, false, "test");

    const extra = win.window_add_pane(setup.pane.window, null, 80, 24);
    setup.pane.window.active = extra;

    const target = try test_target(xm.allocator, "choose-tree-zoom");
    defer xm.allocator.free(target);

    var env = T.Environ.init(xm.allocator);
    defer env.deinit();

    var client = T.Client{
        .name = "choose-tree-zoom-client",
        .environ = &env,
        .tty = undefined,
        .status = .{ .screen = undefined },
        .flags = T.CLIENT_ATTACHED,
        .session = setup.session,
    };
    client.tty = .{ .client = &client };

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "choose-tree", "-Z", "-t", target }, null, &cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &client, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));
    try std.testing.expect(setup.pane.window.flags & T.WINDOW_ZOOMED != 0);

    try std.testing.expect(window_mode_runtime.resetMode(setup.pane));
    try std.testing.expectEqual(@as(u32, 0), setup.pane.window.flags & T.WINDOW_ZOOMED);
}

test "choose-tree rejects invalid sort order before the reduced mode error" {
    const sess = @import("session.zig");

    init_test_globals();
    defer deinit_test_globals();

    const setup = try test_setup("choose-tree-sort");
    defer if (sess.session_find("choose-tree-sort") != null) sess.session_destroy(setup.session, false, "test");

    const target = try test_target(xm.allocator, "choose-tree-sort");
    defer xm.allocator.free(target);

    var env = T.Environ.init(xm.allocator);
    defer env.deinit();

    var client = T.Client{
        .name = "choose-tree-sort-client",
        .environ = &env,
        .tty = undefined,
        .status = .{ .screen = undefined },
        .flags = T.CLIENT_ATTACHED,
        .session = setup.session,
    };
    client.tty = .{ .client = &client };

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "choose-tree", "-t", target, "-O", "mystery" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);
    defer if (client.message_string) |msg| xm.allocator.free(msg);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &client, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.@"error", cmd_mod.cmd_execute(cmd, &item));
    try std.testing.expectEqualStrings("Invalid sort order", client.message_string.?);
}

test "choose-tree rejects unsupported custom key format" {
    const sess = @import("session.zig");

    init_test_globals();
    defer deinit_test_globals();

    const setup = try test_setup("choose-tree-key-format");
    defer if (sess.session_find("choose-tree-key-format") != null) sess.session_destroy(setup.session, false, "test");

    const target = try test_target(xm.allocator, "choose-tree-key-format");
    defer xm.allocator.free(target);

    var env = T.Environ.init(xm.allocator);
    defer env.deinit();

    var client = T.Client{
        .name = "choose-tree-key-format-client",
        .environ = &env,
        .tty = undefined,
        .status = .{ .screen = undefined },
        .flags = T.CLIENT_ATTACHED,
        .session = setup.session,
    };
    client.tty = .{ .client = &client };

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "choose-tree", "-K", "#{line}", "-t", target }, null, &cause);
    defer cmd_mod.cmd_free(cmd);
    defer if (client.message_string) |msg| xm.allocator.free(msg);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &client, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.@"error", cmd_mod.cmd_execute(cmd, &item));
    try std.testing.expectEqualStrings("Choose-tree custom key format not supported yet", client.message_string.?);
}
