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
// Tests for cmd-send-keys.zig, split from the implementation file.

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const args_mod = @import("arguments.zig");
const cmd_mod = @import("cmd.zig");
const cmdq = @import("cmd-queue.zig");
const client_registry = @import("client-registry.zig");
const key_bindings = @import("key-bindings.zig");
const opts = @import("options.zig");
const format_mod = @import("format.zig");
const screen_mod = @import("screen.zig");
const window_mod = @import("window.zig");

fn test_session_with_empty_pane(name: []const u8) !struct { s: *T.Session, wp: *T.WindowPane } {
    const env_mod = @import("environ.zig");
    const sess = @import("session.zig");
    const spawn = @import("spawn.zig");
    const win = @import("window.zig");

    sess.session_init_globals(xm.allocator);
    win.window_init_globals(xm.allocator);

    opts.global_options = opts.options_create(null);
    opts.global_s_options = opts.options_create(null);
    opts.global_w_options = opts.options_create(null);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);

    env_mod.global_environ = env_mod.environ_create();

    const s = sess.session_create(null, name, "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    var cause: ?[]u8 = null;
    var sc: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const wl = spawn.spawn_window(&sc, &cause).?;
    s.curw = wl;
    return .{ .s = s, .wp = wl.window.active.? };
}

fn test_teardown_session(name: []const u8, s: *T.Session, fd_read: i32, fd_write: i32) void {
    const env_mod = @import("environ.zig");
    const sess = @import("session.zig");

    if (fd_read >= 0) std.posix.close(fd_read);
    if (fd_write >= 0) std.posix.close(fd_write);
    if (sess.session_find(name) != null) sess.session_destroy(s, false, "test");
    env_mod.environ_free(env_mod.global_environ);
    opts.options_free(opts.global_w_options);
    opts.options_free(opts.global_s_options);
    opts.options_free(opts.global_options);
}

const ModeKeyState = struct {
    calls: usize = 0,
    saw_client: bool = false,
    last_key: T.key_code = T.KEYC_NONE,
};

const ModeCommandState = struct {
    calls: usize = 0,
    saw_client: bool = false,
    saw_mouse: bool = false,
    prefix: u32 = 0,
    arg_count: usize = 0,
    first_arg_is_enter: bool = false,
};

fn test_mode_table_name(_: *T.WindowModeEntry) []const u8 {
    return "send-keys-mode";
}

fn test_mode_table_fallback_name(_: *T.WindowModeEntry) []const u8 {
    return "send-keys-mode-fallback";
}

fn test_mode_key(
    wme: *T.WindowModeEntry,
    tc: ?*T.Client,
    s: *T.Session,
    wl: *T.Winlink,
    key: T.key_code,
    mouse: ?*const T.MouseEvent,
) void {
    _ = s;
    _ = wl;
    _ = mouse;
    const state: *ModeKeyState = @ptrCast(@alignCast(wme.data.?));
    state.calls += 1;
    state.saw_client = tc != null;
    state.last_key = key;
}

fn test_mode_command(
    wme: *T.WindowModeEntry,
    tc: ?*T.Client,
    s: *T.Session,
    wl: *T.Winlink,
    raw_args: *const anyopaque,
    mouse: ?*const T.MouseEvent,
) void {
    _ = s;
    _ = wl;
    const state: *ModeCommandState = @ptrCast(@alignCast(wme.data.?));
    const args: *const args_mod.Arguments = @ptrCast(@alignCast(raw_args));
    state.calls += 1;
    state.saw_client = tc != null;
    state.saw_mouse = mouse != null;
    state.prefix = wme.prefix;
    state.arg_count = args.count();
    state.first_arg_is_enter = args.count() > 0 and std.mem.eql(u8, args.value_at(0).?, "Enter");
}

const test_mode_table: T.WindowMode = .{
    .name = "mode-table",
    .key_table = test_mode_table_name,
};

const test_mode_table_with_key: T.WindowMode = .{
    .name = "mode-table-key",
    .key = test_mode_key,
    .key_table = test_mode_table_fallback_name,
};

const test_mode_key_only: T.WindowMode = .{
    .name = "mode-key",
    .key = test_mode_key,
};

const test_mode_command_only: T.WindowMode = .{
    .name = "mode-command",
    .command = test_mode_command,
};

test "send-keys writes literal text and enter to pane fd" {
    const setup = try test_session_with_empty_pane("send-keys-test");
    const pipe_fds = try std.posix.pipe();
    defer test_teardown_session("send-keys-test", setup.s, pipe_fds[0], -1);

    setup.wp.fd = pipe_fds[1];

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "send-keys", "-t", "send-keys-test:0.0", "printf hi", "Enter" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));

    var buf: [64]u8 = undefined;
    const n = try std.posix.read(pipe_fds[0], &buf);
    try std.testing.expectEqualStrings("printf hi\r", buf[0..n]);
    std.posix.close(pipe_fds[1]);
    setup.wp.fd = -1;
}

test "send-prefix uses session prefix option bytes" {
    const setup = try test_session_with_empty_pane("send-prefix-test");
    const pipe_fds = try std.posix.pipe();
    defer test_teardown_session("send-prefix-test", setup.s, pipe_fds[0], -1);

    setup.wp.fd = pipe_fds[1];
    opts.options_set_string(setup.s.options, false, "prefix", "C-a");

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "send-prefix", "-t", "send-prefix-test:0.0" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));

    var buf: [8]u8 = undefined;
    const n = try std.posix.read(pipe_fds[0], &buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u8, 0x01), buf[0]);
    std.posix.close(pipe_fds[1]);
    setup.wp.fd = -1;
}

test "send-prefix -2 uses session prefix2 option bytes" {
    const setup = try test_session_with_empty_pane("send-prefix2-test");
    const pipe_fds = try std.posix.pipe();
    defer test_teardown_session("send-prefix2-test", setup.s, pipe_fds[0], -1);

    setup.wp.fd = pipe_fds[1];
    opts.options_set_string(setup.s.options, false, "prefix2", "C-z");

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "send-prefix", "-2", "-t", "send-prefix2-test:0.0" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));

    var buf: [8]u8 = undefined;
    const n = try std.posix.read(pipe_fds[0], &buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u8, 0x1a), buf[0]);
    std.posix.close(pipe_fds[1]);
    setup.wp.fd = -1;
}

test "send-keys supports hex mode and repeat counts" {
    const setup = try test_session_with_empty_pane("send-hex-test");
    const pipe_fds = try std.posix.pipe();
    defer test_teardown_session("send-hex-test", setup.s, pipe_fds[0], -1);

    setup.wp.fd = pipe_fds[1];

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "send-keys", "-N", "2", "-H", "-t", "send-hex-test:0.0", "41", "0d" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));

    var buf: [16]u8 = undefined;
    const n = try std.posix.read(pipe_fds[0], &buf);
    try std.testing.expectEqualStrings("A\rA\r", buf[0..n]);
    std.posix.close(pipe_fds[1]);
    setup.wp.fd = -1;
}

test "send-keys -l writes key-name bytes without special-key expansion" {
    const setup = try test_session_with_empty_pane("send-keys-l-flag-test");
    const pipe_fds = try std.posix.pipe();
    defer test_teardown_session("send-keys-l-flag-test", setup.s, pipe_fds[0], -1);

    setup.wp.fd = pipe_fds[1];

    var cause: ?[]u8 = null;
    const cmd_lit = try cmd_mod.cmd_parse_one(&.{ "send-keys", "-l", "-t", "send-keys-l-flag-test:0.0", "Up" }, null, &cause);
    defer cmd_mod.cmd_free(cmd_lit);
    var list_lit: cmd_mod.CmdList = .{};
    var item_lit = cmdq.CmdqItem{ .client = null, .cmdlist = &list_lit };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd_lit, &item_lit));

    var buf: [32]u8 = undefined;
    const n_lit = try std.posix.read(pipe_fds[0], &buf);
    try std.testing.expectEqualStrings("Up", buf[0..n_lit]);

    const cmd_seq = try cmd_mod.cmd_parse_one(&.{ "send-keys", "-t", "send-keys-l-flag-test:0.0", "Up" }, null, &cause);
    defer cmd_mod.cmd_free(cmd_seq);
    var list_seq: cmd_mod.CmdList = .{};
    var item_seq = cmdq.CmdqItem{ .client = null, .cmdlist = &list_seq };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd_seq, &item_seq));

    const n_seq = try std.posix.read(pipe_fds[0], &buf);
    try std.testing.expect(n_seq > n_lit);

    std.posix.close(pipe_fds[1]);
    setup.wp.fd = -1;
}

test "send-keys uses the pane screen mode for cursor-key output" {
    const setup = try test_session_with_empty_pane("send-cursor-mode-test");
    const pipe_fds = try std.posix.pipe();
    defer test_teardown_session("send-cursor-mode-test", setup.s, pipe_fds[0], -1);

    setup.wp.fd = pipe_fds[1];
    screen_mod.screen_current(setup.wp).mode |= T.MODE_KCURSOR;

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "send-keys", "-t", "send-cursor-mode-test:0.0", "Up" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));

    var buf: [8]u8 = undefined;
    const n = try std.posix.read(pipe_fds[0], &buf);
    try std.testing.expectEqualStrings("\x1bOA", buf[0..n]);
    std.posix.close(pipe_fds[1]);
    setup.wp.fd = -1;
}

test "send-keys -H ignores invalid hex bytes and keeps later input" {
    const setup = try test_session_with_empty_pane("send-hex-ignore");
    const pipe_fds = try std.posix.pipe();
    defer test_teardown_session("send-hex-ignore", setup.s, pipe_fds[0], -1);

    setup.wp.fd = pipe_fds[1];

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "send-keys", "-H", "-t", "send-hex-ignore:0.0", "zz", "41" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));

    var buf: [8]u8 = undefined;
    const n = try std.posix.read(pipe_fds[0], &buf);
    try std.testing.expectEqualStrings("A", buf[0..n]);
    std.posix.close(pipe_fds[1]);
    setup.wp.fd = -1;
}

test "send-keys expands repeat count options before parsing" {
    const setup = try test_session_with_empty_pane("send-repeat-format");
    const pipe_fds = try std.posix.pipe();
    defer test_teardown_session("send-repeat-format", setup.s, pipe_fds[0], -1);

    setup.wp.fd = pipe_fds[1];

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "send-keys", "-N", "#{e|+:1,1}", "-t", "send-repeat-format:0.0", "x" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));

    var buf: [8]u8 = undefined;
    const n = try std.posix.read(pipe_fds[0], &buf);
    try std.testing.expectEqualStrings("xx", buf[0..n]);
    std.posix.close(pipe_fds[1]);
    setup.wp.fd = -1;
}

test "send-keys reports tmux-style too small repeat count errors" {
    const setup = try test_session_with_empty_pane("send-repeat-too-small");
    defer test_teardown_session("send-repeat-too-small", setup.s, -1, -1);

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "send-keys", "-N", "0", "-t", "send-repeat-too-small:0.0", "x" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };

    const saved_stderr = try std.posix.dup(std.posix.STDERR_FILENO);
    defer std.posix.close(saved_stderr);

    const stderr_pipe = try std.posix.pipe();
    defer std.posix.close(stderr_pipe[0]);

    try std.posix.dup2(stderr_pipe[1], std.posix.STDERR_FILENO);
    defer std.posix.dup2(saved_stderr, std.posix.STDERR_FILENO) catch {};

    try std.testing.expectEqual(T.CmdRetval.@"error", cmd_mod.cmd_execute(cmd, &item));
    try std.posix.dup2(saved_stderr, std.posix.STDERR_FILENO);
    std.posix.close(stderr_pipe[1]);

    var errbuf: [128]u8 = undefined;
    const errlen = try std.posix.read(stderr_pipe[0], errbuf[0..]);
    try std.testing.expect(std.mem.indexOf(u8, errbuf[0..errlen], "repeat count too small") != null);
}

test "send-keys reports tmux-style too large repeat count errors" {
    const setup = try test_session_with_empty_pane("send-repeat-too-large");
    defer test_teardown_session("send-repeat-too-large", setup.s, -1, -1);

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "send-keys", "-N", "4294967296", "-t", "send-repeat-too-large:0.0", "x" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };

    const saved_stderr = try std.posix.dup(std.posix.STDERR_FILENO);
    defer std.posix.close(saved_stderr);

    const stderr_pipe = try std.posix.pipe();
    defer std.posix.close(stderr_pipe[0]);

    try std.posix.dup2(stderr_pipe[1], std.posix.STDERR_FILENO);
    defer std.posix.dup2(saved_stderr, std.posix.STDERR_FILENO) catch {};

    try std.testing.expectEqual(T.CmdRetval.@"error", cmd_mod.cmd_execute(cmd, &item));
    try std.posix.dup2(saved_stderr, std.posix.STDERR_FILENO);
    std.posix.close(stderr_pipe[1]);

    var errbuf: [128]u8 = undefined;
    const errlen = try std.posix.read(stderr_pipe[0], errbuf[0..]);
    try std.testing.expect(std.mem.indexOf(u8, errbuf[0..errlen], "repeat count too large") != null);
}

test "send-keys expands formats before writing" {
    const setup = try test_session_with_empty_pane("send-format-test");
    const pipe_fds = try std.posix.pipe();
    defer test_teardown_session("send-format-test", setup.s, pipe_fds[0], -1);

    setup.wp.fd = pipe_fds[1];
    setup.wp.screen.title = xm.xstrdup("logs");

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "send-keys", "-F", "-t", "send-format-test:0.0", "#{session_name}:#{pane_title}", "Enter" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));

    var buf: [64]u8 = undefined;
    const n = try std.posix.read(pipe_fds[0], &buf);
    try std.testing.expectEqualStrings("send-format-test:logs\r", buf[0..n]);
    std.posix.close(pipe_fds[1]);
    setup.wp.fd = -1;
}

test "send-keys -R resets pane state before writing keys" {
    const grid = @import("grid.zig");

    const setup = try test_session_with_empty_pane("send-reset-test");
    const pipe_fds = try std.posix.pipe();
    defer test_teardown_session("send-reset-test", setup.s, pipe_fds[0], -1);

    setup.wp.fd = pipe_fds[1];
    grid.set_ascii(setup.wp.base.grid, 0, 0, 'X');
    try setup.wp.input_pending.appendSlice(xm.allocator, "leftover");
    setup.wp.palette.fg = 2;
    setup.wp.palette.bg = 4;

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "send-keys", "-R", "-t", "send-reset-test:0.0", "Enter" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));

    var buf: [8]u8 = undefined;
    const n = try std.posix.read(pipe_fds[0], &buf);
    try std.testing.expectEqualStrings("\r", buf[0..n]);
    try std.testing.expectEqual(@as(u8, ' '), grid.ascii_at(setup.wp.base.grid, 0, 0));
    try std.testing.expectEqual(@as(usize, 0), setup.wp.input_pending.items.len);
    try std.testing.expectEqual(@as(i32, 8), setup.wp.palette.fg);
    try std.testing.expectEqual(@as(i32, 8), setup.wp.palette.bg);
    try std.testing.expect(setup.wp.flags & T.PANE_REDRAW != 0);
    try std.testing.expect(setup.wp.flags & T.PANE_STYLECHANGED != 0);
    try std.testing.expect(setup.wp.flags & T.PANE_THEMECHANGED != 0);
    std.posix.close(pipe_fds[1]);
    setup.wp.fd = -1;
}

test "send-keys -R with no arguments resets pane state without replaying the triggering key" {
    const grid = @import("grid.zig");

    const setup = try test_session_with_empty_pane("send-reset-noargs");
    const pipe_fds = try std.posix.pipe();
    defer test_teardown_session("send-reset-noargs", setup.s, pipe_fds[0], -1);

    setup.wp.fd = pipe_fds[1];
    grid.set_ascii(setup.wp.base.grid, 0, 0, 'X');
    try setup.wp.input_pending.appendSlice(xm.allocator, "leftover");
    setup.wp.palette.fg = 2;
    setup.wp.palette.bg = 4;

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "send-keys", "-R", "-t", "send-reset-noargs:0.0" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{
        .client = null,
        .cmdlist = &list,
        .event = .{ .key = 'x', .len = 1 },
    };
    item.event.data[0] = 'x';

    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));

    var poll_fds = [_]std.posix.pollfd{.{
        .fd = pipe_fds[0],
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    try std.testing.expectEqual(@as(usize, 0), try std.posix.poll(&poll_fds, 100));
    try std.testing.expectEqual(@as(u8, ' '), grid.ascii_at(setup.wp.base.grid, 0, 0));
    try std.testing.expectEqual(@as(usize, 0), setup.wp.input_pending.items.len);
    try std.testing.expectEqual(@as(i32, 8), setup.wp.palette.fg);
    try std.testing.expectEqual(@as(i32, 8), setup.wp.palette.bg);
    try std.testing.expect(setup.wp.flags & T.PANE_REDRAW != 0);
    try std.testing.expect(setup.wp.flags & T.PANE_STYLECHANGED != 0);
    try std.testing.expect(setup.wp.flags & T.PANE_THEMECHANGED != 0);
    std.posix.close(pipe_fds[1]);
    setup.wp.fd = -1;
}

test "send-keys -K dispatches through a named target client key table" {
    const env_mod = @import("environ.zig");
    const sess = @import("session.zig");
    const spawn = @import("spawn.zig");
    const win = @import("window.zig");

    sess.session_init_globals(xm.allocator);
    win.window_init_globals(xm.allocator);
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

    env_mod.global_environ = env_mod.environ_create();
    defer env_mod.environ_free(env_mod.global_environ);
    key_bindings.key_bindings_init();

    const s = sess.session_create(null, "send-k-client", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("send-k-client") != null) sess.session_destroy(s, false, "test");

    var cause: ?[]u8 = null;
    var sc: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    _ = spawn.spawn_window(&sc, &cause).?;

    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);
    var cl = T.Client{
        .name = xm.xstrdup("remote"),
        .environ = env,
        .tty = undefined,
        .status = .{},
        .flags = T.CLIENT_ATTACHED,
        .session = s,
    };
    defer xm.allocator.free(cl.name.?);
    cl.tty.client = &cl;
    client_registry.add(&cl);

    const cmd = try cmd_mod.cmd_parse_one(&.{ "send-keys", "-c", "remote", "-K", "-t", "send-k-client:0.0", "C-b", "c" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));

    _ = cmdq.cmdq_next(&cl);
    try std.testing.expectEqual(@as(usize, 2), s.windows.count());
}

test "send-keys -K forwards unbound keys to the named client pane" {
    const env_mod = @import("environ.zig");
    const sess = @import("session.zig");
    const spawn = @import("spawn.zig");
    const win = @import("window.zig");

    sess.session_init_globals(xm.allocator);
    win.window_init_globals(xm.allocator);
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

    env_mod.global_environ = env_mod.environ_create();
    defer env_mod.environ_free(env_mod.global_environ);
    key_bindings.key_bindings_init();

    const s = sess.session_create(null, "send-k-forward", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("send-k-forward") != null) sess.session_destroy(s, false, "test");

    var cause: ?[]u8 = null;
    var sc: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const wl = spawn.spawn_window(&sc, &cause).?;
    const wp = wl.window.active.?;

    const pipe_fds = try std.posix.pipe();
    defer std.posix.close(pipe_fds[0]);
    wp.fd = pipe_fds[1];
    defer {
        if (wp.fd >= 0) std.posix.close(wp.fd);
        wp.fd = -1;
    }

    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);
    var cl = T.Client{
        .name = xm.xstrdup("named-client"),
        .environ = env,
        .tty = undefined,
        .status = .{},
        .flags = T.CLIENT_ATTACHED,
        .session = s,
    };
    defer xm.allocator.free(cl.name.?);
    cl.tty.client = &cl;
    client_registry.add(&cl);

    const cmd = try cmd_mod.cmd_parse_one(&.{ "send-keys", "-c", "named-client", "-K", "-t", "send-k-forward:0.0", "x" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));

    var buf: [8]u8 = undefined;
    const n = try std.posix.read(pipe_fds[0], &buf);
    try std.testing.expectEqualStrings("x", buf[0..n]);
}

test "send-keys with -c still writes directly to the target pane unless -K is set" {
    const env_mod = @import("environ.zig");
    const sess = @import("session.zig");
    const spawn = @import("spawn.zig");
    const win = @import("window.zig");

    sess.session_init_globals(xm.allocator);
    win.window_init_globals(xm.allocator);
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

    env_mod.global_environ = env_mod.environ_create();
    defer env_mod.environ_free(env_mod.global_environ);
    key_bindings.key_bindings_init();

    const s = sess.session_create(null, "send-c-pane", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("send-c-pane") != null) sess.session_destroy(s, false, "test");

    var cause: ?[]u8 = null;
    var sc: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const wl = spawn.spawn_window(&sc, &cause).?;
    const wp = wl.window.active.?;

    const pipe_fds = try std.posix.pipe();
    defer std.posix.close(pipe_fds[0]);
    wp.fd = pipe_fds[1];
    defer {
        if (wp.fd >= 0) std.posix.close(wp.fd);
        wp.fd = -1;
    }

    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);
    var cl = T.Client{
        .name = xm.xstrdup("direct-client"),
        .environ = env,
        .tty = undefined,
        .status = .{},
        .flags = T.CLIENT_ATTACHED,
        .session = s,
    };
    defer xm.allocator.free(cl.name.?);
    cl.tty.client = &cl;
    client_registry.add(&cl);

    const cmd = try cmd_mod.cmd_parse_one(&.{ "send-keys", "-c", "direct-client", "-t", "send-c-pane:0.0", "C-b", "c" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));

    _ = cmdq.cmdq_next(&cl);
    try std.testing.expectEqual(@as(usize, 1), s.windows.count());

    var buf: [8]u8 = undefined;
    const n = try std.posix.read(pipe_fds[0], &buf);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual(@as(u8, 0x02), buf[0]);
    try std.testing.expectEqual(@as(u8, 'c'), buf[1]);
}

test "send-keys quietly ignores an unknown target client when not using -K" {
    const setup = try test_session_with_empty_pane("send-missing-client");
    const pipe_fds = try std.posix.pipe();
    defer test_teardown_session("send-missing-client", setup.s, pipe_fds[0], -1);
    client_registry.clients.clearRetainingCapacity();
    defer client_registry.clients.clearRetainingCapacity();

    setup.wp.fd = pipe_fds[1];

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "send-keys", "-c", "ghost", "-t", "send-missing-client:0.0", "x" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));

    var buf: [8]u8 = undefined;
    const n = try std.posix.read(pipe_fds[0], &buf);
    try std.testing.expectEqualStrings("x", buf[0..n]);
    std.posix.close(pipe_fds[1]);
    setup.wp.fd = -1;
}

test "send-keys -K without a dispatchable client is a no-op" {
    const setup = try test_session_with_empty_pane("send-k-noclient");
    const pipe_fds = try std.posix.pipe();
    defer test_teardown_session("send-k-noclient", setup.s, pipe_fds[0], -1);

    setup.wp.fd = pipe_fds[1];

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "send-keys", "-K", "-t", "send-k-noclient:0.0", "x" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));

    var poll_fds = [_]std.posix.pollfd{.{
        .fd = pipe_fds[0],
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    try std.testing.expectEqual(@as(usize, 0), try std.posix.poll(&poll_fds, 100));
    std.posix.close(pipe_fds[1]);
    setup.wp.fd = -1;
}

test "send-keys dispatches active mode table bindings instead of writing to the pane" {
    cmdq.cmdq_reset_for_tests();
    defer cmdq.cmdq_reset_for_tests();
    key_bindings.key_bindings_init();

    const setup = try test_session_with_empty_pane("send-mode-table");
    const pipe_fds = try std.posix.pipe();
    defer test_teardown_session("send-mode-table", setup.s, pipe_fds[0], -1);

    setup.wp.fd = pipe_fds[1];
    _ = window_mod.window_pane_push_mode(setup.wp, &test_mode_table, null, null);

    var cause: ?[]u8 = null;
    const bound = try cmd_mod.cmd_parse_from_argv_with_cause(&.{ "new-window", "-d", "-t", "send-mode-table", "-n", "bound" }, null, &cause);
    key_bindings.key_bindings_add("send-keys-mode", 'x', null, false, @ptrCast(bound));

    const cmd = try cmd_mod.cmd_parse_one(&.{ "send-keys", "-t", "send-mode-table:0.0", "x" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));

    _ = cmdq.cmdq_next(null);
    try std.testing.expectEqual(@as(usize, 2), setup.s.windows.count());

    var poll_fds = [_]std.posix.pollfd{.{
        .fd = pipe_fds[0],
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    try std.testing.expectEqual(@as(usize, 0), try std.posix.poll(&poll_fds, 100));
    std.posix.close(pipe_fds[1]);
    setup.wp.fd = -1;
}

test "send-keys preserves mode binding queue order across multiple keys" {
    cmdq.cmdq_reset_for_tests();
    defer cmdq.cmdq_reset_for_tests();
    key_bindings.key_bindings_init();

    const setup = try test_session_with_empty_pane("send-mode-order");
    defer test_teardown_session("send-mode-order", setup.s, -1, -1);

    _ = window_mod.window_pane_push_mode(setup.wp, &test_mode_table, null, null);
    window_mod.window_set_name(setup.wp.window, "before");

    var cause: ?[]u8 = null;
    const rename_first = try cmd_mod.cmd_parse_from_argv_with_cause(&.{ "rename-window", "first" }, null, &cause);
    const rename_second = try cmd_mod.cmd_parse_from_argv_with_cause(&.{ "rename-window", "second" }, null, &cause);
    key_bindings.key_bindings_add("send-keys-mode", 'a', null, false, @ptrCast(rename_first));
    key_bindings.key_bindings_add("send-keys-mode", 'b', null, false, @ptrCast(rename_second));

    const cmd = try cmd_mod.cmd_parse_one(&.{ "send-keys", "-t", "send-mode-order:0.0", "a", "b" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));

    _ = cmdq.cmdq_next(null);
    try std.testing.expectEqualStrings("second", setup.wp.window.name);
}

test "send-keys mode bindings inherit the target pane state" {
    cmdq.cmdq_reset_for_tests();
    defer cmdq.cmdq_reset_for_tests();

    const env_mod = @import("environ.zig");
    const sess = @import("session.zig");
    const spawn = @import("spawn.zig");
    const win = @import("window.zig");

    sess.session_init_globals(xm.allocator);
    win.window_init_globals(xm.allocator);
    key_bindings.key_bindings_init();

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

    const target_session = sess.session_create(null, "send-mode-target", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("send-mode-target") != null) sess.session_destroy(target_session, false, "test");
    const decoy_session = sess.session_create(null, "send-mode-decoy", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("send-mode-decoy") != null) sess.session_destroy(decoy_session, false, "test");

    var cause: ?[]u8 = null;
    var target_ctx: T.SpawnContext = .{ .s = target_session, .idx = -1, .flags = T.SPAWN_EMPTY };
    const target_wl = spawn.spawn_window(&target_ctx, &cause).?;
    target_session.curw = target_wl;
    window_mod.window_set_name(target_wl.window, "target-before");

    var decoy_ctx: T.SpawnContext = .{ .s = decoy_session, .idx = -1, .flags = T.SPAWN_EMPTY };
    const decoy_wl = spawn.spawn_window(&decoy_ctx, &cause).?;
    decoy_session.curw = decoy_wl;
    window_mod.window_set_name(decoy_wl.window, "decoy-before");

    _ = window_mod.window_pane_push_mode(target_wl.window.active.?, &test_mode_table, null, null);

    const rename_target = try cmd_mod.cmd_parse_from_argv_with_cause(&.{ "rename-window", "target-after" }, null, &cause);
    key_bindings.key_bindings_add("send-keys-mode", 'x', null, false, @ptrCast(rename_target));

    const cmd = try cmd_mod.cmd_parse_one(&.{ "send-keys", "-t", "send-mode-target:0.0", "x" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));

    _ = cmdq.cmdq_next(null);
    try std.testing.expectEqualStrings("target-after", target_wl.window.name);
    try std.testing.expectEqualStrings("decoy-before", decoy_wl.window.name);
}

test "send-keys routes active mode keys through the target client instead of writing to the pane" {
    const env_mod = @import("environ.zig");

    client_registry.clients.clearRetainingCapacity();
    defer client_registry.clients.clearRetainingCapacity();

    const setup = try test_session_with_empty_pane("send-mode-key");
    const pipe_fds = try std.posix.pipe();
    defer test_teardown_session("send-mode-key", setup.s, pipe_fds[0], -1);

    setup.wp.fd = pipe_fds[1];
    var state = ModeKeyState{};
    _ = window_mod.window_pane_push_mode(setup.wp, &test_mode_key_only, @ptrCast(&state), null);

    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);
    var cl = T.Client{
        .name = xm.xstrdup("mode-client"),
        .environ = env,
        .tty = undefined,
        .status = .{},
        .flags = T.CLIENT_ATTACHED,
        .session = setup.s,
    };
    defer xm.allocator.free(cl.name.?);
    cl.tty.client = &cl;
    client_registry.add(&cl);

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "send-keys", "-c", "mode-client", "-t", "send-mode-key:0.0", "x" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));

    try std.testing.expectEqual(@as(usize, 1), state.calls);
    try std.testing.expect(state.saw_client);
    try std.testing.expectEqual(@as(T.key_code, 'x'), state.last_key);

    var poll_fds = [_]std.posix.pollfd{.{
        .fd = pipe_fds[0],
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    try std.testing.expectEqual(@as(usize, 0), try std.posix.poll(&poll_fds, 100));
    std.posix.close(pipe_fds[1]);
    setup.wp.fd = -1;
}

test "send-keys falls back to an active mode key handler when the mode table has no binding" {
    const env_mod = @import("environ.zig");

    client_registry.clients.clearRetainingCapacity();
    defer client_registry.clients.clearRetainingCapacity();

    const setup = try test_session_with_empty_pane("send-mode-key-fallback");
    const pipe_fds = try std.posix.pipe();
    defer test_teardown_session("send-mode-key-fallback", setup.s, pipe_fds[0], -1);

    setup.wp.fd = pipe_fds[1];
    var state = ModeKeyState{};
    _ = window_mod.window_pane_push_mode(setup.wp, &test_mode_table_with_key, @ptrCast(&state), null);

    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);
    var cl = T.Client{
        .name = xm.xstrdup("mode-fallback-client"),
        .environ = env,
        .tty = undefined,
        .status = .{},
        .flags = T.CLIENT_ATTACHED,
        .session = setup.s,
    };
    defer xm.allocator.free(cl.name.?);
    cl.tty.client = &cl;
    client_registry.add(&cl);

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "send-keys", "-c", "mode-fallback-client", "-t", "send-mode-key-fallback:0.0", "x" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));

    try std.testing.expectEqual(@as(usize, 1), state.calls);
    try std.testing.expect(state.saw_client);
    try std.testing.expectEqual(@as(T.key_code, 'x'), state.last_key);

    var poll_fds = [_]std.posix.pollfd{.{
        .fd = pipe_fds[0],
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    try std.testing.expectEqual(@as(usize, 0), try std.posix.poll(&poll_fds, 100));
    std.posix.close(pipe_fds[1]);
    setup.wp.fd = -1;
}

test "send-keys -M routes mouse events through active mode keys" {
    const env_mod = @import("environ.zig");

    client_registry.clients.clearRetainingCapacity();
    defer client_registry.clients.clearRetainingCapacity();

    const setup = try test_session_with_empty_pane("send-mode-mouse");
    const pipe_fds = try std.posix.pipe();
    defer test_teardown_session("send-mode-mouse", setup.s, pipe_fds[0], -1);

    setup.wp.fd = pipe_fds[1];
    var state = ModeKeyState{};
    _ = window_mod.window_pane_push_mode(setup.wp, &test_mode_key_only, @ptrCast(&state), null);

    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);
    var cl = T.Client{
        .name = xm.xstrdup("mode-mouse-client"),
        .environ = env,
        .tty = undefined,
        .status = .{},
        .flags = T.CLIENT_ATTACHED,
        .session = setup.s,
    };
    defer xm.allocator.free(cl.name.?);
    cl.tty.client = &cl;
    client_registry.add(&cl);

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "send-keys", "-M", "-c", "mode-mouse-client", "-t", "send-mode-mouse:0.0" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{
        .client = null,
        .cmdlist = &list,
        .event = .{
            .m = .{
                .valid = true,
                .key = T.keycMouse(T.KEYC_MOUSEDOWN1, .pane),
                .wp = @intCast(setup.wp.id),
            },
        },
    };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));

    try std.testing.expectEqual(@as(usize, 1), state.calls);
    try std.testing.expect(state.saw_client);
    try std.testing.expectEqual(T.keycMouse(T.KEYC_MOUSEDOWN1, .pane), state.last_key);

    var poll_fds = [_]std.posix.pollfd{.{
        .fd = pipe_fds[0],
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    try std.testing.expectEqual(@as(usize, 0), try std.posix.poll(&poll_fds, 100));
    std.posix.close(pipe_fds[1]);
    setup.wp.fd = -1;
}

test "send-keys -M encodes pane mouse bytes when no mode owns them" {
    const setup = try test_session_with_empty_pane("send-mode-pane-bytes");
    const pipe_fds = try std.posix.pipe();
    defer test_teardown_session("send-mode-pane-bytes", setup.s, pipe_fds[0], -1);

    setup.wp.fd = pipe_fds[1];
    defer {
        if (setup.wp.fd >= 0) {
            std.posix.close(setup.wp.fd);
            setup.wp.fd = -1;
        }
    }
    setup.wp.base.mode |= T.MODE_MOUSE_ALL | T.MODE_MOUSE_SGR;

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "send-keys", "-M", "-t", "send-mode-pane-bytes:0.0" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{
        .client = null,
        .cmdlist = &list,
        .event = .{
            .m = .{
                .valid = true,
                .key = T.keycMouse(T.KEYC_MOUSEDOWN1, .pane),
                .wp = @intCast(setup.wp.id),
                .x = 1,
                .y = 1,
                .b = T.MOUSE_BUTTON_1,
                .sgr_type = 'M',
                .sgr_b = T.MOUSE_BUTTON_1,
            },
        },
    };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));

    var got: [64]u8 = undefined;
    const nread = try std.posix.read(pipe_fds[0], &got);
    try std.testing.expectEqualStrings("\x1b[<0;2;2M", got[0..nread]);
}

test "send-keys -X uses the active mode command and repeat prefix" {
    const setup = try test_session_with_empty_pane("send-mode-command");
    defer test_teardown_session("send-mode-command", setup.s, -1, -1);

    var state = ModeCommandState{};
    _ = window_mod.window_pane_push_mode(setup.wp, &test_mode_command_only, @ptrCast(&state), null);

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "send-keys", "-X", "-N", "3", "-t", "send-mode-command:0.0", "Enter" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{
        .client = null,
        .cmdlist = &list,
        .event = .{
            .key = T.KEYC_NONE,
            .m = .{ .valid = true, .key = T.KEYC_MOUSEMOVE },
        },
    };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));

    try std.testing.expectEqual(@as(usize, 1), state.calls);
    try std.testing.expectEqual(@as(u32, 3), state.prefix);
    try std.testing.expectEqual(@as(usize, 1), state.arg_count);
    try std.testing.expect(state.first_arg_is_enter);
    try std.testing.expect(state.saw_mouse);
}

test "send-keys pane_in_mode reflects the reduced active mode stack" {
    const setup = try test_session_with_empty_pane("send-pane-in-mode");
    defer test_teardown_session("send-pane-in-mode", setup.s, -1, -1);

    const before = format_mod.format_single(null, "#{pane_in_mode}", null, setup.s, setup.s.curw, setup.wp);
    defer xm.allocator.free(before);
    try std.testing.expectEqualStrings("0", before);

    _ = window_mod.window_pane_push_mode(setup.wp, &test_mode_command_only, null, null);

    const after = format_mod.format_single(null, "#{pane_in_mode}", null, setup.s, setup.s.curw, setup.wp);
    defer xm.allocator.free(after);
    try std.testing.expectEqualStrings("1", after);
}

test "send-keys rejects read-only target clients before writing" {
    const env_mod = @import("environ.zig");
    const sess = @import("session.zig");
    const spawn = @import("spawn.zig");
    const win = @import("window.zig");

    sess.session_init_globals(xm.allocator);
    win.window_init_globals(xm.allocator);
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

    env_mod.global_environ = env_mod.environ_create();
    defer env_mod.environ_free(env_mod.global_environ);

    const s = sess.session_create(null, "send-readonly", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("send-readonly") != null) sess.session_destroy(s, false, "test");

    var cause: ?[]u8 = null;
    var sc: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const wl = spawn.spawn_window(&sc, &cause).?;
    const wp = wl.window.active.?;

    const pipe_fds = try std.posix.pipe();
    defer std.posix.close(pipe_fds[0]);
    wp.fd = pipe_fds[1];
    defer {
        if (wp.fd >= 0) std.posix.close(wp.fd);
        wp.fd = -1;
    }

    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);
    var cl = T.Client{
        .name = xm.xstrdup("readonly-client"),
        .environ = env,
        .tty = undefined,
        .status = .{},
        .flags = T.CLIENT_ATTACHED | T.CLIENT_READONLY,
        .session = s,
    };
    defer xm.allocator.free(cl.name.?);
    cl.tty.client = &cl;
    client_registry.add(&cl);

    const cmd = try cmd_mod.cmd_parse_one(&.{ "send-keys", "-c", "readonly-client", "-t", "send-readonly:0.0", "x" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };

    const saved_stderr = try std.posix.dup(std.posix.STDERR_FILENO);
    defer std.posix.close(saved_stderr);

    const stderr_pipe = try std.posix.pipe();
    defer std.posix.close(stderr_pipe[0]);

    try std.posix.dup2(stderr_pipe[1], std.posix.STDERR_FILENO);
    defer std.posix.dup2(saved_stderr, std.posix.STDERR_FILENO) catch {};

    try std.testing.expectEqual(T.CmdRetval.@"error", cmd_mod.cmd_execute(cmd, &item));
    try std.posix.dup2(saved_stderr, std.posix.STDERR_FILENO);
    std.posix.close(stderr_pipe[1]);

    var errbuf: [128]u8 = undefined;
    const errlen = try std.posix.read(stderr_pipe[0], errbuf[0..]);
    try std.testing.expect(std.mem.indexOf(u8, errbuf[0..errlen], "client is read-only") != null);

    var poll_fds = [_]std.posix.pollfd{.{
        .fd = pipe_fds[0],
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    try std.testing.expectEqual(@as(usize, 0), try std.posix.poll(&poll_fds, 100));
}

test "send-prefix ignores panes that are not accepting input" {
    const setup = try test_session_with_empty_pane("send-prefix-closed");
    defer test_teardown_session("send-prefix-closed", setup.s, -1, -1);

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "send-prefix", "-t", "send-prefix-closed:0.0" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));
}

test "send-keys replays the triggering key when no arguments are given" {
    const setup = try test_session_with_empty_pane("send-replay-test");
    const pipe_fds = try std.posix.pipe();
    defer test_teardown_session("send-replay-test", setup.s, pipe_fds[0], -1);

    setup.wp.fd = pipe_fds[1];

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "send-keys", "-t", "send-replay-test:0.0" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{
        .client = null,
        .cmdlist = &list,
        .event = .{ .key = 'x', .len = 1 },
    };
    item.event.data[0] = 'x';

    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));

    var poll_fds = [_]std.posix.pollfd{.{
        .fd = pipe_fds[0],
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    try std.testing.expectEqual(@as(usize, 1), try std.posix.poll(&poll_fds, 100));

    var buf: [8]u8 = undefined;
    const n = try std.posix.read(pipe_fds[0], &buf);
    try std.testing.expectEqualStrings("x", buf[0..n]);
    std.posix.close(pipe_fds[1]);
    setup.wp.fd = -1;
}

test "send-keys with no arguments and no triggering key is a quiet no-op" {
    const setup = try test_session_with_empty_pane("send-replay-missing");
    const pipe_fds = try std.posix.pipe();
    defer test_teardown_session("send-replay-missing", setup.s, pipe_fds[0], -1);

    setup.wp.fd = pipe_fds[1];

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "send-keys", "-t", "send-replay-missing:0.0" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{
        .client = null,
        .cmdlist = &list,
        .event = .{ .key = T.KEYC_NONE },
    };

    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));

    var poll_fds = [_]std.posix.pollfd{.{
        .fd = pipe_fds[0],
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    try std.testing.expectEqual(@as(usize, 0), try std.posix.poll(&poll_fds, 100));
    std.posix.close(pipe_fds[1]);
    setup.wp.fd = -1;
}

test "send-keys -K replays the triggering key through the target client" {
    const env_mod = @import("environ.zig");
    const sess = @import("session.zig");
    const spawn = @import("spawn.zig");
    const win = @import("window.zig");

    sess.session_init_globals(xm.allocator);
    win.window_init_globals(xm.allocator);
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

    env_mod.global_environ = env_mod.environ_create();
    defer env_mod.environ_free(env_mod.global_environ);
    key_bindings.key_bindings_init();

    const s = sess.session_create(null, "send-replay-k-client", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("send-replay-k-client") != null) sess.session_destroy(s, false, "test");

    var cause: ?[]u8 = null;
    var sc: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const wl = spawn.spawn_window(&sc, &cause).?;
    const wp = wl.window.active.?;

    const pipe_fds = try std.posix.pipe();
    defer std.posix.close(pipe_fds[0]);
    wp.fd = pipe_fds[1];
    defer {
        if (wp.fd >= 0) std.posix.close(wp.fd);
        wp.fd = -1;
    }

    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);
    var cl = T.Client{
        .name = xm.xstrdup("replay-client"),
        .environ = env,
        .tty = undefined,
        .status = .{},
        .flags = T.CLIENT_ATTACHED,
        .session = s,
    };
    defer xm.allocator.free(cl.name.?);
    cl.tty.client = &cl;
    client_registry.add(&cl);

    const cmd = try cmd_mod.cmd_parse_one(&.{ "send-keys", "-c", "replay-client", "-K", "-t", "send-replay-k-client:0.0" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{
        .client = null,
        .cmdlist = &list,
        .event = .{ .key = 'x', .len = 1 },
    };
    item.event.data[0] = 'x';

    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));

    var buf: [8]u8 = undefined;
    const n = try std.posix.read(pipe_fds[0], &buf);
    try std.testing.expectEqualStrings("x", buf[0..n]);
}

test "send-keys -K with no replay client is a quiet no-op" {
    const setup = try test_session_with_empty_pane("send-replay-k-noclient");
    const pipe_fds = try std.posix.pipe();
    defer test_teardown_session("send-replay-k-noclient", setup.s, pipe_fds[0], -1);

    setup.wp.fd = pipe_fds[1];

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "send-keys", "-K", "-t", "send-replay-k-noclient:0.0" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{
        .client = null,
        .cmdlist = &list,
        .event = .{ .key = 'x', .len = 1 },
    };
    item.event.data[0] = 'x';

    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));

    var poll_fds = [_]std.posix.pollfd{.{
        .fd = pipe_fds[0],
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    try std.testing.expectEqual(@as(usize, 0), try std.posix.poll(&poll_fds, 100));
    std.posix.close(pipe_fds[1]);
    setup.wp.fd = -1;
}

test "send-keys with -N and no arguments is a quiet no-op" {
    const setup = try test_session_with_empty_pane("send-replay-repeat");
    const pipe_fds = try std.posix.pipe();
    defer test_teardown_session("send-replay-repeat", setup.s, pipe_fds[0], -1);

    setup.wp.fd = pipe_fds[1];

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "send-keys", "-N", "2", "-t", "send-replay-repeat:0.0" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{
        .client = null,
        .cmdlist = &list,
        .event = .{ .key = 'x', .len = 1 },
    };
    item.event.data[0] = 'x';

    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));

    var poll_fds = [_]std.posix.pollfd{.{
        .fd = pipe_fds[0],
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    try std.testing.expectEqual(@as(usize, 0), try std.posix.poll(&poll_fds, 100));
    std.posix.close(pipe_fds[1]);
    setup.wp.fd = -1;
}

test "send-keys with an unsupported triggering key is a quiet no-op" {
    const setup = try test_session_with_empty_pane("send-replay-unsupported");
    const pipe_fds = try std.posix.pipe();
    defer test_teardown_session("send-replay-unsupported", setup.s, pipe_fds[0], -1);

    setup.wp.fd = pipe_fds[1];

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "send-keys", "-t", "send-replay-unsupported:0.0" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{
        .client = null,
        .cmdlist = &list,
        .event = .{ .key = T.keycMouse(T.KEYC_MOUSEDOWN1, .pane) },
    };

    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));

    var poll_fds = [_]std.posix.pollfd{.{
        .fd = pipe_fds[0],
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    try std.testing.expectEqual(@as(usize, 0), try std.posix.poll(&poll_fds, 100));
    std.posix.close(pipe_fds[1]);
    setup.wp.fd = -1;
}

test "send-keys treats Any as a special key and quietly skips pane output" {
    const setup = try test_session_with_empty_pane("send-any-noop");
    const pipe_fds = try std.posix.pipe();
    defer test_teardown_session("send-any-noop", setup.s, pipe_fds[0], -1);

    setup.wp.fd = pipe_fds[1];

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "send-keys", "-t", "send-any-noop:0.0", "Any" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };

    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));

    var poll_fds = [_]std.posix.pollfd{.{
        .fd = pipe_fds[0],
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    try std.testing.expectEqual(@as(usize, 0), try std.posix.poll(&poll_fds, 100));
    std.posix.close(pipe_fds[1]);
    setup.wp.fd = -1;
}

test "send-keys -K dispatches Any through target-client wildcard bindings" {
    cmdq.cmdq_reset_for_tests();
    defer cmdq.cmdq_reset_for_tests();

    const env_mod = @import("environ.zig");
    const sess = @import("session.zig");
    const spawn = @import("spawn.zig");
    const win = @import("window.zig");

    sess.session_init_globals(xm.allocator);
    win.window_init_globals(xm.allocator);
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

    env_mod.global_environ = env_mod.environ_create();
    defer env_mod.environ_free(env_mod.global_environ);
    key_bindings.key_bindings_init();

    const s = sess.session_create(null, "send-k-any", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("send-k-any") != null) sess.session_destroy(s, false, "test");

    var cause: ?[]u8 = null;
    var sc: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    _ = spawn.spawn_window(&sc, &cause).?;

    const bound = try cmd_mod.cmd_parse_from_argv_with_cause(&.{ "new-window", "-d", "-t", "send-k-any", "-n", "wildcard" }, null, &cause);
    key_bindings.key_bindings_add("root", T.KEYC_ANY, null, false, @ptrCast(bound));

    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);
    var cl = T.Client{
        .name = xm.xstrdup("wildcard-client"),
        .environ = env,
        .tty = undefined,
        .status = .{},
        .flags = T.CLIENT_ATTACHED,
        .session = s,
    };
    defer xm.allocator.free(cl.name.?);
    cl.tty.client = &cl;
    client_registry.add(&cl);

    const cmd = try cmd_mod.cmd_parse_one(&.{ "send-keys", "-c", "wildcard-client", "-K", "-t", "send-k-any:0.0", "Any" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };

    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));

    _ = cmdq.cmdq_next(&cl);
    try std.testing.expectEqual(@as(usize, 2), s.windows.count());
}

test "send-keys mirrors pane writes to synchronized sibling panes" {
    const win = @import("window.zig");

    const setup = try test_session_with_empty_pane("send-sync");
    defer test_teardown_session("send-sync", setup.s, -1, -1);

    const sibling = win.window_add_pane(setup.wp.window, null, setup.wp.sx, setup.wp.sy);
    const source_pipe = try std.posix.pipe();
    const sibling_pipe = try std.posix.pipe();
    defer std.posix.close(source_pipe[0]);
    defer std.posix.close(sibling_pipe[0]);
    setup.wp.fd = source_pipe[1];
    sibling.fd = sibling_pipe[1];
    defer {
        if (setup.wp.fd >= 0) std.posix.close(setup.wp.fd);
        if (sibling.fd >= 0) std.posix.close(sibling.fd);
        setup.wp.fd = -1;
        sibling.fd = -1;
    }

    opts.options_set_number(setup.wp.options, "synchronize-panes", 1);
    opts.options_set_number(sibling.options, "synchronize-panes", 1);

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "send-keys", "-t", "send-sync:0.0", "x" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));

    var source_buf: [8]u8 = undefined;
    const source_len = try std.posix.read(source_pipe[0], &source_buf);
    try std.testing.expectEqualStrings("x", source_buf[0..source_len]);

    var sibling_buf: [8]u8 = undefined;
    const sibling_len = try std.posix.read(sibling_pipe[0], &sibling_buf);
    try std.testing.expectEqualStrings("x", sibling_buf[0..sibling_len]);
}

test "send-keys -M errors when the queued event has no mouse target pane" {
    const setup = try test_session_with_empty_pane("send-mode-missing-mouse");
    defer test_teardown_session("send-mode-missing-mouse", setup.s, -1, -1);

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "send-keys", "-M", "-t", "send-mode-missing-mouse:0.0" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{
        .client = null,
        .cmdlist = &list,
        .event = .{
            .m = .{
                .valid = true,
                .key = T.keycMouse(T.KEYC_MOUSEDOWN1, .pane),
                .wp = -1,
            },
        },
    };

    const saved_stderr = try std.posix.dup(std.posix.STDERR_FILENO);
    defer std.posix.close(saved_stderr);

    const stderr_pipe = try std.posix.pipe();
    defer std.posix.close(stderr_pipe[0]);

    try std.posix.dup2(stderr_pipe[1], std.posix.STDERR_FILENO);
    defer std.posix.dup2(saved_stderr, std.posix.STDERR_FILENO) catch {};

    try std.testing.expectEqual(T.CmdRetval.@"error", cmd_mod.cmd_execute(cmd, &item));
    try std.posix.dup2(saved_stderr, std.posix.STDERR_FILENO);
    std.posix.close(stderr_pipe[1]);

    var errbuf: [128]u8 = undefined;
    const errlen = try std.posix.read(stderr_pipe[0], errbuf[0..]);
    try std.testing.expect(std.mem.indexOf(u8, errbuf[0..errlen], "no mouse target") != null);
}
