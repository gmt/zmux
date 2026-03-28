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
// Ported in part from tmux/cmd-save-buffer.c.
// Original copyright:
//   Copyright (c) 2009 Tiago Cunha <me@tiagocunha.org>
//   ISC licence – same terms as above.

const std = @import("std");
const c = @import("c.zig");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const cmd_mod = @import("cmd.zig");
const cmdq = @import("cmd-queue.zig");
const file_mod = @import("file.zig");
const grid_mod = @import("grid.zig");
const paste_mod = @import("paste.zig");
const proc_mod = @import("proc.zig");
const protocol = @import("zmux-protocol.zig");
const screen_mod = @import("screen.zig");
const server_print = @import("server-print.zig");
const window_mod = @import("window.zig");

fn exec(cmd: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {
    const args = cmd_mod.cmd_get_args(cmd);
    const client = cmdq.cmdq_get_client(item);

    const pb = if (args.get('b')) |name|
        paste_mod.paste_get_name(name)
    else
        paste_mod.paste_get_top(null);

    if (pb == null) {
        if (args.get('b')) |name| {
            cmdq.cmdq_error(item, "no buffer {s}", .{name});
        } else {
            cmdq.cmdq_error(item, "no buffers", .{});
        }
        return .@"error";
    }

    const bufdata = paste_mod.paste_buffer_data(pb.?, null);
    if (cmd.entry == &entry_show) {
        if (show_uses_control_output(client)) {
            cmdq.cmdq_print_data(item, bufdata);
            return .normal;
        }
        if (show_needs_view_mode(client)) {
            if (!show_buffer_in_view_mode(client.?, bufdata)) {
                cmdq.cmdq_error(item, "show-buffer attached-client view mode unavailable while another pane mode is active", .{});
                return .@"error";
            }
            return .normal;
        }
    }

    const raw_path = if (cmd.entry == &entry_show) xm.xstrdup("-") else file_mod.formatPathFromClient(item, client, args.value_at(0).?);
    defer xm.allocator.free(raw_path);

    return write_buffer(item, client, raw_path, args.has('a'), bufdata);
}

fn show_uses_control_output(client: ?*T.Client) bool {
    if (client == null) return false;
    return (client.?.flags & T.CLIENT_CONTROL) != 0;
}

fn show_needs_view_mode(client: ?*T.Client) bool {
    if (client == null) return false;
    return client.?.session != null;
}

fn show_buffer_in_view_mode(client: *T.Client, data: []const u8) bool {
    return server_print.server_client_view_data(client, data, false);
}

fn close_show_buffer_view_mode(wp: *T.WindowPane) void {
    server_print.server_client_close_view_mode(wp);
}

fn write_buffer(
    item: *cmdq.CmdqItem,
    client: ?*T.Client,
    raw_path: []const u8,
    append: bool,
    data: []const u8,
) T.CmdRetval {
    const resolved = file_mod.resolvePath(client, raw_path);
    defer if (resolved.owned) xm.allocator.free(@constCast(resolved.path));

    return file_mod.writeResolvedPath(
        item,
        client,
        resolved.path,
        if (append) c.posix_sys.O_APPEND else c.posix_sys.O_TRUNC,
        data,
    );
}

pub const entry: cmd_mod.CmdEntry = .{
    .name = "save-buffer",
    .alias = "saveb",
    .usage = "[-a] [-b buffer-name] path",
    .template = "ab:",
    .lower = 1,
    .upper = 1,
    .flags = T.CMD_AFTERHOOK,
    .exec = exec,
};

pub const entry_show: cmd_mod.CmdEntry = .{
    .name = "show-buffer",
    .alias = "showb",
    .usage = "[-b buffer-name]",
    .template = "b:",
    .lower = 0,
    .upper = 0,
    .flags = T.CMD_AFTERHOOK,
    .exec = exec,
};

fn init_options_for_tests() void {
    const opts = @import("options.zig");
    opts.global_options = opts.options_create(null);
    opts.global_s_options = opts.options_create(null);
    opts.global_w_options = opts.options_create(null);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
}

fn free_options_for_tests() void {
    const opts = @import("options.zig");
    opts.options_free(opts.global_w_options);
    opts.options_free(opts.global_s_options);
    opts.options_free(opts.global_options);
}

fn test_peer_dispatch(_imsg: ?*c.imsg.imsg, _arg: ?*anyopaque) callconv(.c) void {
    _ = _imsg;
    _ = _arg;
}

test "save-buffer writes and appends a named buffer using client cwd for relative paths" {
    paste_mod.paste_reset_for_tests();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try tmp.dir.realpathAlloc(xm.allocator, ".");
    defer xm.allocator.free(cwd);

    var cause: ?[]u8 = null;
    try std.testing.expectEqual(@as(i32, 0), paste_mod.paste_set(xm.xstrdup("hello"), "named", &cause));

    var env = T.Environ.init(xm.allocator);
    defer env.deinit();

    var client = T.Client{
        .environ = &env,
        .cwd = cwd,
        .flags = T.CLIENT_ATTACHED,
        .tty = undefined,
        .status = .{ .screen = undefined },
    };

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &client, .cmdlist = &list };

    const save = try cmd_mod.cmd_parse_one(&.{ "save-buffer", "-b", "named", "buffer.txt" }, null, &cause);
    defer cmd_mod.cmd_free(save);
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(save, &item));

    const append = try cmd_mod.cmd_parse_one(&.{ "save-buffer", "-a", "-b", "named", "buffer.txt" }, null, &cause);
    defer cmd_mod.cmd_free(append);
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(append, &item));

    const saved_path = try std.fmt.allocPrint(xm.allocator, "{s}/buffer.txt", .{cwd});
    defer xm.allocator.free(saved_path);

    const file = try std.fs.openFileAbsolute(saved_path, .{});
    defer file.close();
    const contents = try file.readToEndAlloc(xm.allocator, 1024);
    defer xm.allocator.free(contents);
    try std.testing.expectEqualStrings("hellohello", contents);
}

test "save-buffer writes a named buffer using session cwd when client cwd is missing" {
    paste_mod.paste_reset_for_tests();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try tmp.dir.realpathAlloc(xm.allocator, ".");
    defer xm.allocator.free(cwd);

    var cause: ?[]u8 = null;
    try std.testing.expectEqual(@as(i32, 0), paste_mod.paste_set(xm.xstrdup("from session cwd"), "named", &cause));

    var env = T.Environ.init(xm.allocator);
    defer env.deinit();
    var session_env = T.Environ.init(xm.allocator);
    defer session_env.deinit();

    const session_name = xm.xstrdup("save-session");
    defer xm.allocator.free(session_name);

    var session = T.Session{
        .id = 1,
        .name = session_name,
        .cwd = cwd,
        .lastw = .{},
        .windows = std.AutoHashMap(i32, *T.Winlink).init(xm.allocator),
        .options = undefined,
        .environ = &session_env,
    };
    defer session.windows.deinit();
    defer session.lastw.deinit(xm.allocator);

    var client = T.Client{
        .environ = &env,
        .flags = T.CLIENT_ATTACHED,
        .tty = undefined,
        .status = .{ .screen = undefined },
        .session = &session,
    };

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &client, .cmdlist = &list };

    const save = try cmd_mod.cmd_parse_one(&.{ "save-buffer", "-b", "named", "buffer.txt" }, null, &cause);
    defer cmd_mod.cmd_free(save);
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(save, &item));

    const saved_path = try std.fmt.allocPrint(xm.allocator, "{s}/buffer.txt", .{cwd});
    defer xm.allocator.free(saved_path);

    const file = try std.fs.openFileAbsolute(saved_path, .{});
    defer file.close();
    const contents = try file.readToEndAlloc(xm.allocator, 1024);
    defer xm.allocator.free(contents);
    try std.testing.expectEqualStrings("from session cwd", contents);
}

test "save-buffer uses the newest automatic buffer when no name is provided" {
    init_options_for_tests();
    defer free_options_for_tests();
    paste_mod.paste_reset_for_tests();
    paste_mod.paste_add(null, xm.xstrdup("older"));
    paste_mod.paste_add(null, xm.xstrdup("newer"));

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try tmp.dir.realpathAlloc(xm.allocator, ".");
    defer xm.allocator.free(cwd);

    var env = T.Environ.init(xm.allocator);
    defer env.deinit();

    var client = T.Client{
        .environ = &env,
        .cwd = cwd,
        .flags = T.CLIENT_ATTACHED,
        .tty = undefined,
        .status = .{ .screen = undefined },
    };

    var cause: ?[]u8 = null;
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &client, .cmdlist = &list };

    const save = try cmd_mod.cmd_parse_one(&.{ "save-buffer", "buffer.txt" }, null, &cause);
    defer cmd_mod.cmd_free(save);

    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(save, &item));

    const saved_path = try std.fmt.allocPrint(xm.allocator, "{s}/buffer.txt", .{cwd});
    defer xm.allocator.free(saved_path);

    const file = try std.fs.openFileAbsolute(saved_path, .{});
    defer file.close();
    const contents = try file.readToEndAlloc(xm.allocator, 1024);
    defer xm.allocator.free(contents);
    try std.testing.expectEqualStrings("newer", contents);
}

test "save-buffer expands the output path through the format context" {
    paste_mod.paste_reset_for_tests();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try tmp.dir.realpathAlloc(xm.allocator, ".");
    defer xm.allocator.free(cwd);

    var cause: ?[]u8 = null;
    try std.testing.expectEqual(@as(i32, 0), paste_mod.paste_set(xm.xstrdup("fmt"), "named", &cause));

    var env = T.Environ.init(xm.allocator);
    defer env.deinit();
    var session_env = T.Environ.init(xm.allocator);
    defer session_env.deinit();

    const session_name = xm.xstrdup("fmt-session");
    defer xm.allocator.free(session_name);

    var session = T.Session{
        .id = 1,
        .name = session_name,
        .cwd = cwd,
        .lastw = .{},
        .windows = std.AutoHashMap(i32, *T.Winlink).init(xm.allocator),
        .options = undefined,
        .environ = &session_env,
    };
    defer session.windows.deinit();
    defer session.lastw.deinit(xm.allocator);

    var client = T.Client{
        .environ = &env,
        .flags = T.CLIENT_ATTACHED,
        .tty = undefined,
        .status = .{ .screen = undefined },
        .session = &session,
    };

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &client, .cmdlist = &list };

    const save = try cmd_mod.cmd_parse_one(&.{ "save-buffer", "-b", "named", "#{session_name}.txt" }, null, &cause);
    defer cmd_mod.cmd_free(save);

    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(save, &item));

    const saved_path = try std.fmt.allocPrint(xm.allocator, "{s}/fmt-session.txt", .{cwd});
    defer xm.allocator.free(saved_path);

    const file = try std.fs.openFileAbsolute(saved_path, .{});
    defer file.close();
    const contents = try file.readToEndAlloc(xm.allocator, 1024);
    defer xm.allocator.free(contents);
    try std.testing.expectEqualStrings("fmt", contents);
}

test "show-buffer renders attached clients in the reduced view mode" {
    paste_mod.paste_reset_for_tests();

    var cause: ?[]u8 = null;
    try std.testing.expectEqual(@as(i32, 0), paste_mod.paste_set(xm.xstrdup("a\nb"), "named", &cause));

    var env = T.Environ.init(xm.allocator);
    defer env.deinit();

    const session_name = xm.xstrdup("show-buffer-attached");
    defer xm.allocator.free(session_name);
    const window_name = xm.xstrdup("pane");
    defer xm.allocator.free(window_name);

    const base_grid = grid_mod.grid_create(8, 4, 2000);
    defer grid_mod.grid_free(base_grid);
    const alt_screen = screen_mod.screen_init(8, 4, 2000);
    defer {
        screen_mod.screen_free(alt_screen);
        xm.allocator.destroy(alt_screen);
    }

    var window = T.Window{
        .id = 1,
        .name = window_name,
        .sx = 8,
        .sy = 4,
        .options = undefined,
    };
    defer window.panes.deinit(xm.allocator);

    var pane = T.WindowPane{
        .id = 2,
        .window = &window,
        .options = undefined,
        .sx = 8,
        .sy = 4,
        .screen = alt_screen,
        .base = .{ .grid = base_grid, .rlower = 3 },
    };
    defer if (window_mod.window_pane_mode(&pane)) |_| close_show_buffer_view_mode(&pane);

    try window.panes.append(xm.allocator, &pane);
    window.active = &pane;

    var session = T.Session{
        .id = 0,
        .name = session_name,
        .cwd = "",
        .lastw = .{},
        .windows = std.AutoHashMap(i32, *T.Winlink).init(xm.allocator),
        .options = undefined,
        .environ = &env,
    };
    defer session.windows.deinit();
    defer session.lastw.deinit(xm.allocator);

    var winlink = T.Winlink{
        .idx = 0,
        .session = &session,
        .window = &window,
    };
    session.curw = &winlink;

    var client = T.Client{
        .environ = &env,
        .tty = undefined,
        .status = .{ .screen = undefined },
        .session = &session,
        .flags = T.CLIENT_ATTACHED,
    };

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &client, .cmdlist = &list };

    const show = try cmd_mod.cmd_parse_one(&.{ "show-buffer", "-b", "named" }, null, &cause);
    defer cmd_mod.cmd_free(show);

    const saved_stderr = try std.posix.dup(std.posix.STDERR_FILENO);
    defer std.posix.close(saved_stderr);

    const pipe_fds = try std.posix.pipe();
    defer std.posix.close(pipe_fds[0]);

    try std.posix.dup2(pipe_fds[1], std.posix.STDERR_FILENO);
    defer std.posix.dup2(saved_stderr, std.posix.STDERR_FILENO) catch {};

    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(show, &item));
    try std.posix.dup2(saved_stderr, std.posix.STDERR_FILENO);
    std.posix.close(pipe_fds[1]);

    var output: [96]u8 = undefined;
    const got = try std.posix.read(pipe_fds[0], output[0..]);
    try std.testing.expectEqual(@as(usize, 0), got);
    try std.testing.expect(screen_mod.screen_alternate_active(&pane));
    try std.testing.expect(window_mod.window_pane_mode(&pane) != null);

    const first_row = try grid_row_string(pane.screen.grid, 0);
    defer xm.allocator.free(first_row);
    const second_row = try grid_row_string(pane.screen.grid, 1);
    defer xm.allocator.free(second_row);
    try std.testing.expectEqualStrings("a", first_row);
    try std.testing.expectEqualStrings("b", second_row);
}

test "show-buffer attached view preserves shared utf8 grid payloads" {
    paste_mod.paste_reset_for_tests();

    var cause: ?[]u8 = null;
    try std.testing.expectEqual(@as(i32, 0), paste_mod.paste_set(xm.xstrdup("\xf0\x9f\x99\x82\n\xce\xb2"), "named", &cause));

    var env = T.Environ.init(xm.allocator);
    defer env.deinit();

    const session_name = xm.xstrdup("show-buffer-utf8");
    defer xm.allocator.free(session_name);
    const window_name = xm.xstrdup("pane");
    defer xm.allocator.free(window_name);

    const base_grid = grid_mod.grid_create(8, 4, 2000);
    defer grid_mod.grid_free(base_grid);
    const alt_screen = screen_mod.screen_init(8, 4, 2000);
    defer {
        screen_mod.screen_free(alt_screen);
        xm.allocator.destroy(alt_screen);
    }

    var window = T.Window{
        .id = 70,
        .name = window_name,
        .sx = 8,
        .sy = 4,
        .options = undefined,
    };
    defer window.panes.deinit(xm.allocator);

    var pane = T.WindowPane{
        .id = 71,
        .window = &window,
        .options = undefined,
        .sx = 8,
        .sy = 4,
        .screen = alt_screen,
        .base = .{ .grid = base_grid, .rlower = 3 },
    };
    defer if (window_mod.window_pane_mode(&pane)) |_| close_show_buffer_view_mode(&pane);

    try window.panes.append(xm.allocator, &pane);
    window.active = &pane;

    var session = T.Session{
        .id = 72,
        .name = session_name,
        .cwd = "",
        .lastw = .{},
        .windows = std.AutoHashMap(i32, *T.Winlink).init(xm.allocator),
        .options = undefined,
        .environ = &env,
    };
    defer session.windows.deinit();
    defer session.lastw.deinit(xm.allocator);

    var winlink = T.Winlink{
        .idx = 0,
        .session = &session,
        .window = &window,
    };
    session.curw = &winlink;

    var client = T.Client{
        .environ = &env,
        .tty = undefined,
        .status = .{ .screen = undefined },
        .session = &session,
        .flags = T.CLIENT_ATTACHED,
    };

    try std.testing.expect(show_buffer_in_view_mode(&client, "\xf0\x9f\x99\x82\n\xce\xb2"));

    const first_row = try grid_row_string(pane.screen.grid, 0);
    defer xm.allocator.free(first_row);
    const second_row = try grid_row_string(pane.screen.grid, 1);
    defer xm.allocator.free(second_row);
    try std.testing.expectEqualStrings("\xf0\x9f\x99\x82", first_row);
    try std.testing.expectEqualStrings("\xce\xb2", second_row);
}

test "show-buffer attached view mode dismisses on the next key" {
    var env = T.Environ.init(xm.allocator);
    defer env.deinit();

    const session_name = xm.xstrdup("show-buffer-view");
    defer xm.allocator.free(session_name);
    const window_name = xm.xstrdup("pane");
    defer xm.allocator.free(window_name);

    const base_grid = grid_mod.grid_create(8, 4, 2000);
    defer grid_mod.grid_free(base_grid);
    const alt_screen = screen_mod.screen_init(8, 4, 2000);
    defer {
        screen_mod.screen_free(alt_screen);
        xm.allocator.destroy(alt_screen);
    }

    var window = T.Window{
        .id = 7,
        .name = window_name,
        .sx = 8,
        .sy = 4,
        .options = undefined,
    };
    defer window.panes.deinit(xm.allocator);

    var pane = T.WindowPane{
        .id = 9,
        .window = &window,
        .options = undefined,
        .sx = 8,
        .sy = 4,
        .screen = alt_screen,
        .base = .{ .grid = base_grid, .rlower = 3 },
    };
    defer if (window_mod.window_pane_mode(&pane)) |_| close_show_buffer_view_mode(&pane);

    try window.panes.append(xm.allocator, &pane);
    window.active = &pane;

    var session = T.Session{
        .id = 5,
        .name = session_name,
        .cwd = "",
        .lastw = .{},
        .windows = std.AutoHashMap(i32, *T.Winlink).init(xm.allocator),
        .options = undefined,
        .environ = &env,
    };
    defer session.windows.deinit();
    defer session.lastw.deinit(xm.allocator);

    var winlink = T.Winlink{
        .idx = 0,
        .session = &session,
        .window = &window,
    };
    session.curw = &winlink;

    var client = T.Client{
        .environ = &env,
        .tty = undefined,
        .status = .{ .screen = undefined },
        .session = &session,
        .flags = T.CLIENT_ATTACHED,
    };

    try std.testing.expect(show_buffer_in_view_mode(&client, "view"));
    const mode = window_mod.window_pane_mode(&pane) orelse return error.TestUnexpectedResult;
    close_show_buffer_view_mode(mode.wp);

    try std.testing.expect(!screen_mod.screen_alternate_active(&pane));
    try std.testing.expect(window_mod.window_pane_mode(&pane) == null);
}

test "show-buffer attached view escapes control bytes instead of replacing them" {
    var env = T.Environ.init(xm.allocator);
    defer env.deinit();

    const session_name = xm.xstrdup("show-buffer-escapes");
    defer xm.allocator.free(session_name);
    const window_name = xm.xstrdup("pane");
    defer xm.allocator.free(window_name);

    const base_grid = grid_mod.grid_create(16, 4, 2000);
    defer grid_mod.grid_free(base_grid);
    const alt_screen = screen_mod.screen_init(16, 4, 2000);
    defer {
        screen_mod.screen_free(alt_screen);
        xm.allocator.destroy(alt_screen);
    }

    var window = T.Window{
        .id = 11,
        .name = window_name,
        .sx = 16,
        .sy = 4,
        .options = undefined,
    };
    defer window.panes.deinit(xm.allocator);

    var pane = T.WindowPane{
        .id = 13,
        .window = &window,
        .options = undefined,
        .sx = 16,
        .sy = 4,
        .screen = alt_screen,
        .base = .{ .grid = base_grid, .rlower = 3 },
    };
    defer if (window_mod.window_pane_mode(&pane)) |_| close_show_buffer_view_mode(&pane);

    try window.panes.append(xm.allocator, &pane);
    window.active = &pane;

    var session = T.Session{
        .id = 6,
        .name = session_name,
        .cwd = "",
        .lastw = .{},
        .windows = std.AutoHashMap(i32, *T.Winlink).init(xm.allocator),
        .options = undefined,
        .environ = &env,
    };
    defer session.windows.deinit();
    defer session.lastw.deinit(xm.allocator);

    var winlink = T.Winlink{
        .idx = 0,
        .session = &session,
        .window = &window,
    };
    session.curw = &winlink;

    var client = T.Client{
        .environ = &env,
        .tty = undefined,
        .status = .{ .screen = undefined },
        .session = &session,
        .flags = T.CLIENT_ATTACHED,
    };

    try std.testing.expect(show_buffer_in_view_mode(&client, &.{ 'A', 0x01, 0x7f, 'B' }));

    const first_row = try grid_row_string(pane.screen.grid, 0);
    defer xm.allocator.free(first_row);
    try std.testing.expectEqualStrings("A\\001\\177B", first_row);
}

test "show-buffer uses the remote write-open handshake for detached clients" {
    paste_mod.paste_reset_for_tests();
    file_mod.resetForTests();
    defer file_mod.resetForTests();

    var cause: ?[]u8 = null;
    try std.testing.expectEqual(@as(i32, 0), paste_mod.paste_set(xm.xstrdup("detached"), "named", &cause));

    var env = T.Environ.init(xm.allocator);
    defer env.deinit();

    var pair: [2]i32 = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &pair));

    var proc = T.ZmuxProc{ .name = "show-buffer-test-stdout" };
    defer proc.peers.deinit(xm.allocator);

    var client = T.Client{
        .environ = &env,
        .tty = undefined,
        .status = .{ .screen = undefined },
    };
    client.peer = proc_mod.proc_add_peer(&proc, pair[0], test_peer_dispatch, null);
    defer {
        const peer = client.peer.?;
        c.imsg.imsgbuf_clear(&peer.ibuf);
        std.posix.close(peer.ibuf.fd);
        xm.allocator.destroy(peer);
        proc.peers.clearRetainingCapacity();
    }

    var reader: c.imsg.imsgbuf = undefined;
    try std.testing.expectEqual(@as(i32, 0), c.imsg.imsgbuf_init(&reader, pair[1]));
    defer {
        c.imsg.imsgbuf_clear(&reader);
        std.posix.close(pair[1]);
    }

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &client, .cmdlist = &list };

    const show = try cmd_mod.cmd_parse_one(&.{ "show-buffer", "-b", "named" }, null, &cause);
    defer cmd_mod.cmd_free(show);

    try std.testing.expectEqual(T.CmdRetval.wait, cmd_mod.cmd_execute(show, &item));
    try std.testing.expectEqual(@as(i32, 1), c.imsg.imsgbuf_read(&reader));

    var open_imsg: c.imsg.imsg = undefined;
    try std.testing.expect(c.imsg.imsg_get(&reader, &open_imsg) > 0);
    defer c.imsg.imsg_free(&open_imsg);

    try std.testing.expectEqual(@as(u32, @intCast(@intFromEnum(protocol.MsgType.write_open))), c.imsg.imsg_get_type(&open_imsg));
    const open_len = c.imsg.imsg_get_len(&open_imsg);
    var open_payload = try xm.allocator.alloc(u8, open_len);
    defer xm.allocator.free(open_payload);
    try std.testing.expectEqual(@as(i32, 0), c.imsg.imsg_get_data(&open_imsg, open_payload.ptr, open_payload.len));

    var open_msg: protocol.MsgWriteOpen = undefined;
    @memcpy(std.mem.asBytes(&open_msg), open_payload[0..@sizeOf(protocol.MsgWriteOpen)]);
    try std.testing.expectEqual(@as(i32, std.posix.STDOUT_FILENO), open_msg.fd);
    try std.testing.expectEqualStrings("-", open_payload[@sizeOf(protocol.MsgWriteOpen) .. open_payload.len - 1]);
}

test "save-buffer writes detached file paths through write-ready then write-close" {
    paste_mod.paste_reset_for_tests();
    file_mod.resetForTests();
    defer file_mod.resetForTests();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try tmp.dir.realpathAlloc(xm.allocator, ".");
    defer xm.allocator.free(cwd);

    var cause: ?[]u8 = null;
    try std.testing.expectEqual(@as(i32, 0), paste_mod.paste_set(xm.xstrdup("remote-save"), "named", &cause));

    var env = T.Environ.init(xm.allocator);
    defer env.deinit();

    var pair: [2]i32 = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &pair));

    var proc = T.ZmuxProc{ .name = "save-buffer-test-remote-file" };
    defer proc.peers.deinit(xm.allocator);

    var client = T.Client{
        .environ = &env,
        .cwd = cwd,
        .tty = undefined,
        .status = .{ .screen = undefined },
    };
    client.peer = proc_mod.proc_add_peer(&proc, pair[0], test_peer_dispatch, null);
    defer {
        const peer = client.peer.?;
        c.imsg.imsgbuf_clear(&peer.ibuf);
        std.posix.close(peer.ibuf.fd);
        xm.allocator.destroy(peer);
        proc.peers.clearRetainingCapacity();
    }

    var reader: c.imsg.imsgbuf = undefined;
    try std.testing.expectEqual(@as(i32, 0), c.imsg.imsgbuf_init(&reader, pair[1]));
    defer {
        c.imsg.imsgbuf_clear(&reader);
        std.posix.close(pair[1]);
    }

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &client, .cmdlist = &list };

    const save = try cmd_mod.cmd_parse_one(&.{ "save-buffer", "-b", "named", "buffer.txt" }, null, &cause);
    defer cmd_mod.cmd_free(save);

    try std.testing.expectEqual(T.CmdRetval.wait, cmd_mod.cmd_execute(save, &item));
    try std.testing.expectEqual(@as(i32, 1), c.imsg.imsgbuf_read(&reader));

    var open_imsg: c.imsg.imsg = undefined;
    try std.testing.expect(c.imsg.imsg_get(&reader, &open_imsg) > 0);
    defer c.imsg.imsg_free(&open_imsg);

    try std.testing.expectEqual(@as(u32, @intCast(@intFromEnum(protocol.MsgType.write_open))), c.imsg.imsg_get_type(&open_imsg));
    const open_len = c.imsg.imsg_get_len(&open_imsg);
    var open_payload = try xm.allocator.alloc(u8, open_len);
    defer xm.allocator.free(open_payload);
    try std.testing.expectEqual(@as(i32, 0), c.imsg.imsg_get_data(&open_imsg, open_payload.ptr, open_payload.len));

    var open_msg: protocol.MsgWriteOpen = undefined;
    @memcpy(std.mem.asBytes(&open_msg), open_payload[0..@sizeOf(protocol.MsgWriteOpen)]);
    try std.testing.expectEqual(@as(i32, -1), open_msg.fd);
    try std.testing.expectEqual(@as(c_int, c.posix_sys.O_TRUNC), open_msg.flags);
    const resolved_path = open_payload[@sizeOf(protocol.MsgWriteOpen) .. open_payload.len - 1];
    const expected_path = try std.fmt.allocPrint(xm.allocator, "{s}/buffer.txt", .{cwd});
    defer xm.allocator.free(expected_path);
    try std.testing.expectEqualStrings(expected_path, resolved_path);

    const ready = protocol.MsgWriteReady{
        .stream = open_msg.stream,
        .@"error" = 0,
    };
    var ready_imsg = buildImsg(protocol.MsgType.write_ready, std.mem.asBytes(&ready));
    file_mod.handleWriteReady(&ready_imsg);

    try std.testing.expectEqual(@as(i32, 1), c.imsg.imsgbuf_read(&reader));
    var write_imsg: c.imsg.imsg = undefined;
    try std.testing.expect(c.imsg.imsg_get(&reader, &write_imsg) > 0);
    defer c.imsg.imsg_free(&write_imsg);

    try std.testing.expectEqual(@as(u32, @intCast(@intFromEnum(protocol.MsgType.write))), c.imsg.imsg_get_type(&write_imsg));
    const write_len = c.imsg.imsg_get_len(&write_imsg);
    var write_payload = try xm.allocator.alloc(u8, write_len);
    defer xm.allocator.free(write_payload);
    try std.testing.expectEqual(@as(i32, 0), c.imsg.imsg_get_data(&write_imsg, write_payload.ptr, write_payload.len));

    var write_msg: protocol.MsgWriteData = undefined;
    @memcpy(std.mem.asBytes(&write_msg), write_payload[0..@sizeOf(protocol.MsgWriteData)]);
    try std.testing.expectEqual(open_msg.stream, write_msg.stream);
    try std.testing.expectEqualStrings("remote-save", write_payload[@sizeOf(protocol.MsgWriteData)..]);

    var close_imsg: c.imsg.imsg = undefined;
    if (c.imsg.imsg_get(&reader, &close_imsg) == 0) {
        try std.testing.expectEqual(@as(i32, 1), c.imsg.imsgbuf_read(&reader));
        try std.testing.expect(c.imsg.imsg_get(&reader, &close_imsg) > 0);
    }
    defer c.imsg.imsg_free(&close_imsg);

    try std.testing.expectEqual(@as(u32, @intCast(@intFromEnum(protocol.MsgType.write_close))), c.imsg.imsg_get_type(&close_imsg));
}

test "save-buffer reports bad file descriptor for dash on attached clients" {
    paste_mod.paste_reset_for_tests();
    init_options_for_tests();
    defer free_options_for_tests();

    var cause: ?[]u8 = null;
    try std.testing.expectEqual(@as(i32, 0), paste_mod.paste_set(xm.xstrdup("attached-save"), "named", &cause));

    var env = T.Environ.init(xm.allocator);
    defer env.deinit();

    var client = T.Client{
        .environ = &env,
        .flags = T.CLIENT_ATTACHED,
        .tty = undefined,
        .status = .{ .screen = undefined },
    };

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &client, .cmdlist = &list };

    const save = try cmd_mod.cmd_parse_one(&.{ "save-buffer", "-b", "named", "-" }, null, &cause);
    defer cmd_mod.cmd_free(save);

    const saved_stderr = try std.posix.dup(std.posix.STDERR_FILENO);
    defer std.posix.close(saved_stderr);

    const pipe_fds = try std.posix.pipe();
    defer std.posix.close(pipe_fds[0]);

    try std.posix.dup2(pipe_fds[1], std.posix.STDERR_FILENO);
    defer std.posix.dup2(saved_stderr, std.posix.STDERR_FILENO) catch {};

    try std.testing.expectEqual(T.CmdRetval.@"error", cmd_mod.cmd_execute(save, &item));
    try std.posix.dup2(saved_stderr, std.posix.STDERR_FILENO);
    std.posix.close(pipe_fds[1]);

    var output: [64]u8 = undefined;
    const got = try std.posix.read(pipe_fds[0], output[0..]);
    try std.testing.expectEqualStrings("Bad file descriptor: -\n", output[0..got]);
}

test "save-buffer reports client-side open errors from write-ready" {
    paste_mod.paste_reset_for_tests();
    file_mod.resetForTests();
    defer file_mod.resetForTests();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try tmp.dir.realpathAlloc(xm.allocator, ".");
    defer xm.allocator.free(cwd);

    var cause: ?[]u8 = null;
    try std.testing.expectEqual(@as(i32, 0), paste_mod.paste_set(xm.xstrdup("remote-error"), "named", &cause));

    var env = T.Environ.init(xm.allocator);
    defer env.deinit();

    var pair: [2]i32 = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &pair));

    var proc = T.ZmuxProc{ .name = "save-buffer-test-remote-error" };
    defer proc.peers.deinit(xm.allocator);

    var client = T.Client{
        .environ = &env,
        .cwd = cwd,
        .tty = undefined,
        .status = .{ .screen = undefined },
    };
    client.peer = proc_mod.proc_add_peer(&proc, pair[0], test_peer_dispatch, null);
    defer {
        const peer = client.peer.?;
        c.imsg.imsgbuf_clear(&peer.ibuf);
        std.posix.close(peer.ibuf.fd);
        xm.allocator.destroy(peer);
        proc.peers.clearRetainingCapacity();
    }

    var reader: c.imsg.imsgbuf = undefined;
    try std.testing.expectEqual(@as(i32, 0), c.imsg.imsgbuf_init(&reader, pair[1]));
    defer {
        c.imsg.imsgbuf_clear(&reader);
        std.posix.close(pair[1]);
    }

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &client, .cmdlist = &list };

    const save = try cmd_mod.cmd_parse_one(&.{ "save-buffer", "-b", "named", "missing/buffer.txt" }, null, &cause);
    defer cmd_mod.cmd_free(save);

    try std.testing.expectEqual(T.CmdRetval.wait, cmd_mod.cmd_execute(save, &item));
    try std.testing.expectEqual(@as(i32, 1), c.imsg.imsgbuf_read(&reader));

    var open_imsg: c.imsg.imsg = undefined;
    try std.testing.expect(c.imsg.imsg_get(&reader, &open_imsg) > 0);
    defer c.imsg.imsg_free(&open_imsg);

    const open_len = c.imsg.imsg_get_len(&open_imsg);
    var open_payload = try xm.allocator.alloc(u8, open_len);
    defer xm.allocator.free(open_payload);
    try std.testing.expectEqual(@as(i32, 0), c.imsg.imsg_get_data(&open_imsg, open_payload.ptr, open_payload.len));

    var open_msg: protocol.MsgWriteOpen = undefined;
    @memcpy(std.mem.asBytes(&open_msg), open_payload[0..@sizeOf(protocol.MsgWriteOpen)]);

    const ready = protocol.MsgWriteReady{
        .stream = open_msg.stream,
        .@"error" = @intFromEnum(std.posix.E.NOENT),
    };
    var ready_imsg = buildImsg(protocol.MsgType.write_ready, std.mem.asBytes(&ready));
    file_mod.handleWriteReady(&ready_imsg);

    try std.testing.expectEqual(@as(i32, 1), c.imsg.imsgbuf_read(&reader));
    var error_imsg: c.imsg.imsg = undefined;
    try std.testing.expect(c.imsg.imsg_get(&reader, &error_imsg) > 0);
    defer c.imsg.imsg_free(&error_imsg);

    try std.testing.expectEqual(@as(u32, @intCast(@intFromEnum(protocol.MsgType.write))), c.imsg.imsg_get_type(&error_imsg));
    const error_len = c.imsg.imsg_get_len(&error_imsg);
    var error_payload = try xm.allocator.alloc(u8, error_len);
    defer xm.allocator.free(error_payload);
    try std.testing.expectEqual(@as(i32, 0), c.imsg.imsg_get_data(&error_imsg, error_payload.ptr, error_payload.len));

    var stream: i32 = 0;
    @memcpy(std.mem.asBytes(&stream), error_payload[0..@sizeOf(i32)]);
    try std.testing.expectEqual(@as(i32, 2), stream);
    const text = error_payload[@sizeOf(i32)..];
    try std.testing.expect(std.mem.indexOf(u8, text, "No such file or directory") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "missing/buffer.txt") != null);
}

test "show-buffer writes raw bytes over the peer transport for control clients" {
    paste_mod.paste_reset_for_tests();

    var cause: ?[]u8 = null;
    try std.testing.expectEqual(@as(i32, 0), paste_mod.paste_set(xm.xstrdup("peer-data"), "named", &cause));

    var env = T.Environ.init(xm.allocator);
    defer env.deinit();

    var pair: [2]i32 = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &pair));

    var proc = T.ZmuxProc{ .name = "save-buffer-test-peer" };
    defer proc.peers.deinit(xm.allocator);

    var client = T.Client{
        .environ = &env,
        .flags = T.CLIENT_CONTROL,
        .tty = undefined,
        .status = .{ .screen = undefined },
    };
    client.peer = proc_mod.proc_add_peer(&proc, pair[0], test_peer_dispatch, null);
    defer {
        const peer = client.peer.?;
        c.imsg.imsgbuf_clear(&peer.ibuf);
        std.posix.close(peer.ibuf.fd);
        xm.allocator.destroy(peer);
        proc.peers.clearRetainingCapacity();
    }

    var reader: c.imsg.imsgbuf = undefined;
    try std.testing.expectEqual(@as(i32, 0), c.imsg.imsgbuf_init(&reader, pair[1]));
    defer {
        c.imsg.imsgbuf_clear(&reader);
        std.posix.close(pair[1]);
    }

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &client, .cmdlist = &list };

    const show = try cmd_mod.cmd_parse_one(&.{ "show-buffer", "-b", "named" }, null, &cause);
    defer cmd_mod.cmd_free(show);

    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(show, &item));
    try std.testing.expectEqual(@as(i32, 1), c.imsg.imsgbuf_read(&reader));

    var imsg_msg: c.imsg.imsg = undefined;
    try std.testing.expect(c.imsg.imsg_get(&reader, &imsg_msg) > 0);
    defer c.imsg.imsg_free(&imsg_msg);

    try std.testing.expectEqual(@as(u32, @intCast(@intFromEnum(protocol.MsgType.write))), c.imsg.imsg_get_type(&imsg_msg));

    const payload_len = c.imsg.imsg_get_len(&imsg_msg);
    var payload = try xm.allocator.alloc(u8, payload_len);
    defer xm.allocator.free(payload);
    try std.testing.expectEqual(@as(i32, 0), c.imsg.imsg_get_data(&imsg_msg, payload.ptr, payload.len));

    var stream: i32 = 0;
    @memcpy(std.mem.asBytes(&stream), payload[0..@sizeOf(i32)]);
    try std.testing.expectEqual(@as(i32, 1), stream);
    try std.testing.expectEqualStrings("peer-data", payload[@sizeOf(i32)..]);
}

test "save-buffer reports strerror text for write failures" {
    paste_mod.paste_reset_for_tests();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try tmp.dir.realpathAlloc(xm.allocator, ".");
    defer xm.allocator.free(cwd);

    var cause: ?[]u8 = null;
    try std.testing.expectEqual(@as(i32, 0), paste_mod.paste_set(xm.xstrdup("hello"), "named", &cause));

    var env = T.Environ.init(xm.allocator);
    defer env.deinit();

    var client = T.Client{
        .environ = &env,
        .cwd = cwd,
        .flags = T.CLIENT_ATTACHED,
        .tty = undefined,
        .status = .{ .screen = undefined },
    };

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &client, .cmdlist = &list };

    const save = try cmd_mod.cmd_parse_one(&.{ "save-buffer", "-b", "named", "missing/buffer.txt" }, null, &cause);
    defer cmd_mod.cmd_free(save);

    const saved_stderr = try std.posix.dup(std.posix.STDERR_FILENO);
    defer std.posix.close(saved_stderr);

    const pipe_fds = try std.posix.pipe();
    defer std.posix.close(pipe_fds[0]);

    try std.posix.dup2(pipe_fds[1], std.posix.STDERR_FILENO);
    defer std.posix.dup2(saved_stderr, std.posix.STDERR_FILENO) catch {};

    try std.testing.expectEqual(T.CmdRetval.@"error", cmd_mod.cmd_execute(save, &item));
    try std.posix.dup2(saved_stderr, std.posix.STDERR_FILENO);
    std.posix.close(pipe_fds[1]);

    var output: [256]u8 = undefined;
    const got = try std.posix.read(pipe_fds[0], output[0..]);
    try std.testing.expect(std.mem.indexOf(u8, output[0..got], "No such file or directory") != null);
    try std.testing.expect(std.mem.indexOf(u8, output[0..got], "FileNotFound") == null);
}

fn grid_row_string(gd: *T.Grid, row: u32) ![]u8 {
    return grid_mod.string_cells(gd, row, gd.sx, .{
        .trim_trailing_spaces = true,
    });
}

fn buildImsg(msg_type: protocol.MsgType, payload: []const u8) c.imsg.imsg {
    return .{
        .hdr = .{
            .type = @intCast(@intFromEnum(msg_type)),
            .len = @as(u32, @intCast(@sizeOf(c.imsg.imsg_hdr) + payload.len)),
            .peerid = protocol.PROTOCOL_VERSION,
            .pid = 0,
        },
        .data = if (payload.len == 0) null else @constCast(payload.ptr),
        .buf = null,
    };
}
