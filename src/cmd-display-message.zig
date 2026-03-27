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
const xm = @import("xmalloc.zig");
const cmd_mod = @import("cmd.zig");
const cmdq = @import("cmd-queue.zig");
const cmd_find = @import("cmd-find.zig");
const format_mod = @import("format.zig");
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

fn exec(cmd: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {
    const args = cmd_mod.cmd_get_args(cmd);
    if (args.has('I')) {
        cmdq.cmdq_error(item, "display-message -I is not supported yet", .{});
        return .@"error";
    }
    if (args.has('v')) {
        cmdq.cmdq_error(item, "display-message -v is not supported yet", .{});
        return .@"error";
    }
    if (args.has('a')) {
        cmdq.cmdq_error(item, "display-message -a is not supported yet", .{});
        return .@"error";
    }

    if (args.has('F') and args.count() != 0) {
        cmdq.cmdq_error(item, "only one of -F or argument must be given", .{});
        return .@"error";
    }

    var target: T.CmdFindState = .{};
    if (cmd_find.cmd_find_target(&target, item, args.get('t'), .pane, T.CMD_FIND_CANFAIL) != 0)
        return .@"error";

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
    const format_client = formatClient(item, &target, target_client);
    const expanded = expandMessage(template, &target, format_client, args.has('l'));
    defer xm.allocator.free(expanded);

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

fn formatClient(item: *cmdq.CmdqItem, target: *const T.CmdFindState, target_client: ?*T.Client) ?*T.Client {
    if (target_client) |client| {
        if (target.s == null or client.session == target.s) return client;
    }
    if (cmdq.cmdq_get_client(item)) |client| {
        if (target.s == null or client.session == target.s) return client;
    }
    return if (target.s == null) target_client else null;
}

fn expandMessage(template: []const u8, target: *const T.CmdFindState, client: ?*T.Client, literal: bool) []u8 {
    if (literal) return xm.xstrdup(template);
    var ctx = target_context(target);
    ctx.client = client;
    return format_mod.format_expand(xm.allocator, template, &ctx).text;
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
        .status = .{ .screen = undefined },
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

test "display-message -p reuses the shared print view-mode path" {
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
        .status = .{ .screen = undefined },
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
