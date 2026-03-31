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
// Ported in part from tmux/cmd-display-message.c.
// Original copyright:
//   Copyright (c) 2009 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

const std = @import("std");
const T = @import("types.zig");
const args_mod = @import("arguments.zig");
const log = @import("log.zig");
const xm = @import("xmalloc.zig");
const cmd_mod = @import("cmd.zig");
const cmdq = @import("cmd-queue.zig");
const cmd_find = @import("cmd-find.zig");
const format_mod = @import("format.zig");
const pane_empty_input = @import("pane-empty-input.zig");
const server_print = @import("server-print.zig");
const status_runtime = @import("status-runtime.zig");

const DISPLAY_MESSAGE_TEMPLATE =
    "[#{session_name}] #{window_index}:#{window_name}, current pane #{pane_index} " ++
    "- (%H:%M %d-%b-%y)";

pub fn expand_format(alloc: std.mem.Allocator, fmt: []const u8, target: *const T.CmdFindState) []u8 {
    var ctx = target_context(target);
    return format_mod.format_expand(alloc, fmt, &ctx).text;
}

pub fn require_format(
    alloc: std.mem.Allocator,
    fmt: []const u8,
    target: *const T.CmdFindState,
    message_text: ?[]const u8,
) ?[]u8 {
    var ctx = target_context(target);
    ctx.message_text = message_text;
    return format_mod.format_require(alloc, fmt, &ctx) catch null;
}

pub fn target_context(target: *const T.CmdFindState) format_mod.FormatContext {
    return .{
        .session = target.s,
        .winlink = target.wl,
        .window = target.w,
        .pane = target.wp,
    };
}

fn cmd_display_message_each(key: []const u8, value: []const u8, arg: ?*anyopaque) void {
    const item: *cmdq.CmdqItem = @ptrCast(@alignCast(arg orelse return));
    cmdq.cmdq_print(item, "{s}={s}", .{ key, value });
}

fn exec(cmd: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {
    const args = cmd_mod.cmd_get_args(cmd);

    var target: T.CmdFindState = .{};
    if (cmd_find.cmd_find_target(&target, item, args.get('t'), .pane, T.CMD_FIND_CANFAIL) != 0)
        return .@"error";

    if (args.has('I')) {
        const wp = target.wp orelse return .normal;
        return pane_empty_input.start(item, wp);
    }

    if (args.has('F') and args.count() != 0) {
        cmdq.cmdq_error(item, "only one of -F or argument must be given", .{});
        return .@"error";
    }

    var delay: i32 = -1;
    if (args.has('d')) {
        var cause: ?[]u8 = null;
        const parsed = args_mod.args_strtonum(args, 'd', 0, @as(i64, std.math.maxInt(u32)), &cause);
        if (cause) |msg| {
            defer xm.allocator.free(msg);
            cmdq.cmdq_error(item, "delay {s}", .{msg});
            return .@"error";
        }
        delay = @intCast(parsed);
    }

    const template = args.value_at(0) orelse args.get('F') orelse DISPLAY_MESSAGE_TEMPLATE;
    const target_client = cmdq.cmdq_get_target_client(item);
    const ctx = formatContext(item, &target, target_client);
    if (args.has('v'))
        format_mod.format_log_defaults(xm.allocator, "display-message", &ctx);

    if (args.has('a')) {
        format_mod.format_each(xm.allocator, &ctx, cmd_display_message_each, item);
        return .normal;
    }

    const expanded = expandMessage(template, &ctx, args.has('l'));
    defer xm.allocator.free(expanded);
    if (args.has('v'))
        log.log_debug("display-message result: {s}", .{expanded});

    if (cmdq.cmdq_get_client(item) == null) {
        cmdq.cmdq_error(item, "{s}", .{expanded});
    } else if (args.has('p')) {
        cmdq.cmdq_print(item, "{s}", .{expanded});
    } else if (target_client) |tc| {
        if ((tc.flags & T.CLIENT_CONTROL) != 0)
            server_print.server_client_control_message(tc, expanded)
        else
            status_runtime.status_message_set_text(tc, delay, false, args.has('N'), args.has('C'), expanded);
    }
    return .normal;
}

fn formatClient(target: *const T.CmdFindState, target_client: ?*T.Client) ?*T.Client {
    if (target_client) |client| {
        if (client.session == target.s) return client;
    }
    if (target.s == null) return null;
    return cmd_find.cmd_find_best_client(target.s);
}

fn formatContext(item: *cmdq.CmdqItem, target: *const T.CmdFindState, target_client: ?*T.Client) format_mod.FormatContext {
    var ctx = target_context(target);
    ctx.item = @ptrCast(item);
    ctx.client = formatClient(target, target_client);
    return ctx;
}

fn expandMessage(template: []const u8, ctx: *const format_mod.FormatContext, literal: bool) []u8 {
    if (literal) return xm.xstrdup(template);
    return format_mod.format_expand_time(xm.allocator, template, ctx).text;
}

pub const entry: cmd_mod.CmdEntry = .{
    .name = "display-message",
    .alias = "display",
    .usage = "[-aCIlNpv] [-c target-client] [-d delay] [-F format] [-t target-pane] [message]",
    .template = "ac:d:F:INpPRt:v",
    .lower = 0,
    .upper = 1,
    .flags = T.CMD_AFTERHOOK | T.CMD_CLIENT_CFLAG | T.CMD_CLIENT_CANFAIL,
    .exec = exec,
};

test "display-message routes attached clients through the shared status runtime" {
    const env_mod = @import("environ.zig");
    const opts = @import("options.zig");
    const sess = @import("session.zig");
    const win_mod = @import("window.zig");

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

    const session = sess.session_create(
        null,
        "display-message-runtime",
        "/",
        env_mod.environ_create(),
        opts.options_create(opts.global_s_options),
        null,
    );
    defer sess.session_destroy(session, false, "test");

    const window = win_mod.window_create(80, 23, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    var attach_cause: ?[]u8 = null;
    const wl = sess.session_attach(session, window, -1, &attach_cause).?;
    session.curw = wl;
    const pane = win_mod.window_add_pane(window, null, 80, 23);
    window.active = pane;

    var client = T.Client{
        .name = "display-message-client",
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{},
        .flags = T.CLIENT_ATTACHED,
        .session = session,
    };
    defer {
        status_runtime.status_message_clear(&client);
        env_mod.environ_free(client.environ);
    }
    client.tty = .{ .client = &client, .sx = 80, .sy = 24 };

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "display-message", "-d", "0", "hello runtime" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);
    defer if (cause) |msg| xm.allocator.free(msg);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &client, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));
    try std.testing.expectEqualStrings("hello runtime", client.message_string.?);
    try std.testing.expect(client.flags & T.CLIENT_REDRAWSTATUS != 0);
}

test "display-message -p reuses the shared print view-mode seam" {
    const env_mod = @import("environ.zig");
    const opts = @import("options.zig");
    const sess = @import("session.zig");
    const win_mod = @import("window.zig");

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

    const session = sess.session_create(
        null,
        "display-message-print",
        "/",
        env_mod.environ_create(),
        opts.options_create(opts.global_s_options),
        null,
    );
    defer sess.session_destroy(session, false, "test");

    const window = win_mod.window_create(80, 23, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    var attach_cause: ?[]u8 = null;
    const wl = sess.session_attach(session, window, -1, &attach_cause).?;
    session.curw = wl;
    const pane = win_mod.window_add_pane(window, null, 80, 23);
    window.active = pane;

    var client = T.Client{
        .name = "display-message-print-client",
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{},
        .flags = T.CLIENT_ATTACHED,
        .session = session,
    };
    defer env_mod.environ_free(client.environ);
    client.tty = .{ .client = &client, .sx = 80, .sy = 24 };

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "display-message", "-p", "hello print" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);
    defer if (cause) |msg| xm.allocator.free(msg);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &client, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));
    try std.testing.expect(client.message_string == null);
    const wme = win_mod.window_pane_mode(pane) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("server-print-view", wme.mode.name);
    server_print.server_client_close_view_mode(pane);
}

fn test_session_with_empty_pane(name: []const u8) !struct { s: *T.Session, wp: *T.WindowPane } {
    const env_mod = @import("environ.zig");
    const opts = @import("options.zig");
    const sess = @import("session.zig");
    const spawn = @import("spawn.zig");
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

    const s = sess.session_create(null, name, "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    var cause: ?[]u8 = null;
    defer if (cause) |msg| xm.allocator.free(msg);
    var sc: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const wl = spawn.spawn_window(&sc, &cause).?;
    s.curw = wl;
    return .{ .s = s, .wp = wl.window.active.? };
}

fn test_teardown_session(name: []const u8, s: *T.Session) void {
    const env_mod = @import("environ.zig");
    const opts = @import("options.zig");
    const sess = @import("session.zig");

    if (sess.session_find(name) != null) sess.session_destroy(s, false, "test");
    env_mod.environ_free(env_mod.global_environ);
    opts.options_free(opts.global_w_options);
    opts.options_free(opts.global_s_options);
    opts.options_free(opts.global_options);
}

test "display-message expands default template time directives" {
    const setup = try test_session_with_empty_pane("display-message-template");
    defer test_teardown_session("display-message-template", setup.s);

    var target = T.CmdFindState{
        .s = setup.s,
        .wl = setup.s.curw,
        .w = setup.s.curw.?.window,
        .wp = setup.wp,
    };
    var item = cmdq.CmdqItem{};
    const ctx = formatContext(&item, &target, null);
    const expanded = expandMessage(DISPLAY_MESSAGE_TEMPLATE, &ctx, false);
    defer xm.allocator.free(expanded);

    try std.testing.expect(std.mem.indexOfScalar(u8, expanded, '%') == null);
    try std.testing.expect(std.mem.indexOf(u8, expanded, "display-message-template") != null);
}

test "display-message -a prints available format pairs" {
    const setup = try test_session_with_empty_pane("display-message-format-dump");
    defer test_teardown_session("display-message-format-dump", setup.s);

    var stdout_pipe: [2]i32 = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.pipe(&stdout_pipe));
    defer {
        std.posix.close(stdout_pipe[0]);
        if (stdout_pipe[1] != -1) std.posix.close(stdout_pipe[1]);
    }

    const stdout_dup = try std.posix.dup(std.posix.STDOUT_FILENO);
    defer std.posix.close(stdout_dup);

    try std.posix.dup2(stdout_pipe[1], std.posix.STDOUT_FILENO);
    defer std.posix.dup2(stdout_dup, std.posix.STDOUT_FILENO) catch {};

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "display-message", "-a", "-t", "display-message-format-dump:0.0" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);
    defer if (cause) |msg| xm.allocator.free(msg);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));

    std.posix.close(stdout_pipe[1]);
    stdout_pipe[1] = -1;

    var buf: [4096]u8 = undefined;
    const read_len = try std.posix.read(stdout_pipe[0], &buf);
    const output = buf[0..read_len];
    try std.testing.expect(std.mem.indexOf(u8, output, "session_name=display-message-format-dump") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "pane_index=0") != null);
}

test "display-message -v keeps ordinary expansion working" {
    const env_mod = @import("environ.zig");
    const opts = @import("options.zig");
    const sess = @import("session.zig");
    const win_mod = @import("window.zig");

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

    const session = sess.session_create(
        null,
        "display-message-verbose",
        "/",
        env_mod.environ_create(),
        opts.options_create(opts.global_s_options),
        null,
    );
    defer sess.session_destroy(session, false, "test");

    const window = win_mod.window_create(80, 23, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    var attach_cause: ?[]u8 = null;
    const wl = sess.session_attach(session, window, -1, &attach_cause).?;
    session.curw = wl;
    const pane = win_mod.window_add_pane(window, null, 80, 23);
    window.active = pane;

    var client = T.Client{
        .name = "display-message-verbose-client",
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{},
        .flags = T.CLIENT_ATTACHED,
        .session = session,
    };
    defer {
        status_runtime.status_message_clear(&client);
        env_mod.environ_free(client.environ);
    }
    client.tty = .{ .client = &client, .sx = 80, .sy = 24 };

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "display-message", "-v", "-d", "0", "#{session_name}" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);
    defer if (cause) |msg| xm.allocator.free(msg);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &client, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));
    try std.testing.expectEqualStrings("display-message-verbose", client.message_string.?);
}

test "display-message -I feeds detached stdin into the empty pane parser" {
    const env_mod = @import("environ.zig");
    const grid = @import("grid.zig");
    const win_mod = @import("window.zig");

    const setup = try test_session_with_empty_pane("display-message-input");
    defer test_teardown_session("display-message-input", setup.s);
    setup.wp.flags |= T.PANE_EMPTY;
    win_mod.window_pane_reset_contents(setup.wp);

    const saved_stdin = try std.posix.dup(std.posix.STDIN_FILENO);
    defer {
        std.posix.dup2(saved_stdin, std.posix.STDIN_FILENO) catch {};
        std.posix.close(saved_stdin);
    }

    const pipe_fds = try std.posix.pipe();
    defer std.posix.close(pipe_fds[0]);

    _ = try std.posix.write(pipe_fds[1], "pane stdin\r\n");
    std.posix.close(pipe_fds[1]);

    try std.posix.dup2(pipe_fds[0], std.posix.STDIN_FILENO);

    var client = T.Client{
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{},
    };
    defer env_mod.environ_free(client.environ);

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "display-message", "-I", "-t", "display-message-input:0.0" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);
    defer if (cause) |msg| xm.allocator.free(msg);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &client, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));

    try std.testing.expectEqual(@as(u8, 'p'), grid.ascii_at(setup.wp.base.grid, 0, 0));
    try std.testing.expectEqual(@as(u8, 's'), grid.ascii_at(setup.wp.base.grid, 0, 5));
    try std.testing.expectEqual(@as(usize, 0), setup.wp.input_pending.items.len);
}
