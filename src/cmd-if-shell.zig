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
// Ported in part from tmux/cmd-if-shell.c.
// Original copyright:
//   Copyright (c) 2009 Tiago Cunha <me@tiagocunha.org>
//   Copyright (c) 2009 Nicholas Marriott <nicm@openbsd.org>
//   ISC licence - same terms as above.

const std = @import("std");
const c = @import("c.zig");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const client_registry = @import("client-registry.zig");
const cmd_display = @import("cmd-display-message.zig");
const job_mod = @import("job.zig");
const cmd_mod = @import("cmd.zig");
const cmdq = @import("cmd-queue.zig");
const proc_mod = @import("proc.zig");
const server_client_mod = @import("server-client.zig");
const status_runtime = @import("status-runtime.zig");

const IfShellState = struct {
    item: ?*cmdq.CmdqItem = null,
    queue_client_id: ?u32 = null,
    if_command: []u8,
    else_command: ?[]u8 = null,
    shell_command: []u8,
    cwd: []u8,
    async_shell: ?*job_mod.AsyncShell = null,
    job: ?*job_mod.Job = null,
    success: bool = false,
    spawn_failed: bool = false,
};

fn freeState(state: *IfShellState) void {
    if (state.async_shell) |async_shell| job_mod.async_shell_free(async_shell);
    if (state.job) |job| job_mod.job_free(job);
    xm.allocator.free(state.if_command);
    if (state.else_command) |else_command| xm.allocator.free(else_command);
    xm.allocator.free(state.shell_command);
    xm.allocator.free(state.cwd);
    xm.allocator.destroy(state);
}

fn truthyFormat(text: []const u8) bool {
    return text.len != 0 and text[0] != '0';
}

fn findQueueClient(id: ?u32) ?*T.Client {
    const actual_id = id orelse return null;
    for (client_registry.clients.items) |client| {
        if (client.id == actual_id) return client;
    }
    return null;
}

fn commandParseError(item: ?*cmdq.CmdqItem, queue_client_id: ?u32, err: []const u8) void {
    if (item) |waiting_item| {
        cmdq.cmdq_error(waiting_item, "{s}", .{err});
        return;
    }

    status_runtime.present_client_message(findQueueClient(queue_client_id), err);
}

fn enqueueParsedBranch(state: *IfShellState, branch_text: ?[]const u8) void {
    const command_text = branch_text orelse return;
    const item = state.item;
    const queue_client = findQueueClient(state.queue_client_id);

    var pi = T.CmdParseInput{
        .item = if (item) |waiting_item| @ptrCast(waiting_item) else null,
        .c = if (item) |waiting_item|
            cmdq.cmdq_get_target_client(waiting_item) orelse cmdq.cmdq_get_client(waiting_item)
        else
            queue_client,
        .fs = if (item) |waiting_item| cmdq.cmdq_get_target(waiting_item) else .{},
    };
    const parsed = cmd_mod.cmd_parse_from_string(command_text, &pi);
    switch (parsed.status) {
        .success => {
            const cmdlist: *cmd_mod.CmdList = @ptrCast(@alignCast(parsed.cmdlist.?));
            if (item) |waiting_item| {
                const new_item = cmdq.cmdq_get_command(@ptrCast(cmdlist), cmdq.cmdq_get_state(waiting_item));
                _ = cmdq.cmdq_insert_after(waiting_item, new_item);
            } else {
                cmdq.cmdq_append(queue_client, cmdlist);
            }
        },
        .@"error" => {
            const err = parsed.@"error" orelse xm.xstrdup("parse error");
            defer xm.allocator.free(err);
            commandParseError(item, state.queue_client_id, err);
        },
    }
}

fn enqueueLiteralBranch(item: *cmdq.CmdqItem, command_text: []const u8) void {
    var pi = T.CmdParseInput{
        .item = @ptrCast(item),
        .c = cmdq.cmdq_get_target_client(item) orelse cmdq.cmdq_get_client(item),
        .fs = cmdq.cmdq_get_target(item),
    };
    const parsed = cmd_mod.cmd_parse_from_string(command_text, &pi);
    switch (parsed.status) {
        .success => {
            const cmdlist: *cmd_mod.CmdList = @ptrCast(@alignCast(parsed.cmdlist.?));
            const new_item = cmdq.cmdq_get_command(@ptrCast(cmdlist), cmdq.cmdq_get_state(item));
            _ = cmdq.cmdq_insert_after(item, new_item);
        },
        .@"error" => {
            const err = parsed.@"error" orelse xm.xstrdup("parse error");
            defer xm.allocator.free(err);
            cmdq.cmdq_error(item, "{s}", .{err});
        },
    }
}

fn completeState(state: *IfShellState) void {
    if (state.spawn_failed) {
        if (state.item) |item| {
            cmdq.cmdq_error(item, "failed to run command: {s}", .{state.shell_command});
        } else {
            const message = xm.xasprintf("failed to run command: {s}", .{state.shell_command});
            defer xm.allocator.free(message);
            status_runtime.present_client_message(findQueueClient(state.queue_client_id), message);
        }
    } else {
        enqueueParsedBranch(state, if (state.success) state.if_command else state.else_command);
    }

    if (state.item) |item| cmdq.cmdq_continue(item);
    freeState(state);
}

fn startShellCommand(state: *IfShellState) bool {
    state.async_shell = job_mod.async_shell_start(
        state.job,
        state.shell_command,
        .{
            .cwd = state.cwd,
            .capture_output = false,
        },
        cmd_if_shell_async_complete,
        state,
    );
    return state.async_shell != null;
}

fn cmd_if_shell_async_complete(async_shell: *job_mod.AsyncShell, arg: ?*anyopaque) void {
    const state: *IfShellState = @ptrCast(@alignCast(arg orelse return));
    state.spawn_failed = async_shell.result.spawn_failed;
    state.success = !async_shell.result.spawn_failed and async_shell.result.retcode == 0;
    completeState(state);
}

fn exec(self: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {
    const args = cmd_mod.cmd_get_args(self);
    const count = args.count();
    var target = cmdq.cmdq_get_target(item);

    const shell_command = cmd_display.expand_format(xm.allocator, args.value_at(0).?, &target);
    defer xm.allocator.free(shell_command);

    if (args.has('F')) {
        if (truthyFormat(shell_command)) {
            enqueueLiteralBranch(item, args.value_at(1).?);
        } else if (count == 3) {
            enqueueLiteralBranch(item, args.value_at(2).?);
        }
        return .normal;
    }

    const state = xm.allocator.create(IfShellState) catch unreachable;
    state.* = .{
        .item = if (args.has('b')) null else item,
        .queue_client_id = if (cmdq.cmdq_get_target_client(item)) |queue_client| queue_client.id else null,
        .if_command = xm.xstrdup(args.value_at(1).?),
        .else_command = if (count == 3) xm.xstrdup(args.value_at(2).?) else null,
        .shell_command = xm.xstrdup(shell_command),
        .cwd = xm.xstrdup(server_client_mod.server_client_get_cwd(cmdq.cmdq_get_client(item), target.s)),
    };
    state.job = job_mod.job_register(state.shell_command, if (args.has('b')) job_mod.JOB_NOWAIT else 0);

    if (!startShellCommand(state)) {
        freeState(state);
        cmdq.cmdq_error(item, "failed to run command: {s}", .{shell_command});
        return .@"error";
    }

    return if (state.item == null) .normal else .wait;
}

pub const entry: cmd_mod.CmdEntry = .{
    .name = "if-shell",
    .alias = "if",
    .usage = "[-bF] [-t target-pane] shell-command command [command]",
    .template = "bFt:",
    .lower = 2,
    .upper = 3,
    .exec = exec,
};

const TestSetup = struct {
    session: *T.Session,
    window: *T.Window,
    client: T.Client,
};

fn testSetup(name: []const u8) TestSetup {
    const env_mod = @import("environ.zig");
    const opts = @import("options.zig");
    const sess = @import("session.zig");
    const win = @import("window.zig");

    cmdq.cmdq_reset_for_tests();
    sess.session_init_globals(xm.allocator);
    win.window_init_globals(xm.allocator);

    opts.global_options = opts.options_create(null);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.global_s_options = opts.options_create(null);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.global_w_options = opts.options_create(null);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);

    env_mod.global_environ = env_mod.environ_create();

    const session = sess.session_create(null, name, "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    const window = win.window_create(80, 24, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    var cause: ?[]u8 = null;
    const wl = sess.session_attach(session, window, -1, &cause).?;
    const pane = win.window_add_pane(window, null, 80, 24);
    window.active = pane;
    session.curw = wl;
    while (cmdq.cmdq_next(null) != 0) {}

    var client = T.Client{
        .id = 777,
        .name = xm.xstrdup(name),
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{},
        .flags = T.CLIENT_ATTACHED,
        .session = session,
    };
    client.tty.client = &client;

    return .{
        .session = session,
        .window = window,
        .client = client,
    };
}

fn testTeardown(setup: *TestSetup) void {
    const env_mod = @import("environ.zig");
    const opts = @import("options.zig");
    const sess = @import("session.zig");
    const win = @import("window.zig");

    env_mod.environ_free(setup.client.environ);
    if (setup.client.name) |name| xm.allocator.free(@constCast(name));
    if (sess.session_find(setup.session.name)) |_| sess.session_destroy(setup.session, false, "test");
    win.window_remove_ref(setup.window, "test");
    cmdq.cmdq_reset_for_tests();
    env_mod.environ_free(env_mod.global_environ);
    opts.options_free(opts.global_options);
    opts.options_free(opts.global_s_options);
    opts.options_free(opts.global_w_options);
}

fn installEventBase() ?*c.libevent.event_base {
    const os_mod = @import("os/linux.zig");
    const old_base = proc_mod.libevent;
    proc_mod.libevent = os_mod.osdep_event_init();
    return old_base;
}

fn restoreEventBase(old_base: ?*c.libevent.event_base) void {
    if (proc_mod.libevent) |base| c.libevent.event_base_free(base);
    proc_mod.libevent = old_base;
}

fn appendCommand(client: ?*T.Client, argv: []const []const u8) !void {
    var cause: ?[]u8 = null;
    defer if (cause) |msg| xm.allocator.free(msg);
    const cmdlist = try cmd_mod.cmd_parse_from_argv_with_cause(argv, client, &cause);
    cmdq.cmdq_append(client, cmdlist);
}

fn pumpAsyncOnce() void {
    _ = c.libevent.event_loop(c.libevent.EVLOOP_ONCE);
}

test "if-shell -F queues the then command when the format is nonzero" {
    var setup = testSetup("if-shell-format-true");
    defer testTeardown(&setup);

    try appendCommand(&setup.client, &.{
        "if-shell",
        "-F",
        "1",
        "rename-window -t if-shell-format-true:0 format-then",
    });

    try std.testing.expectEqual(@as(u32, 2), cmdq.cmdq_next(&setup.client));
    try std.testing.expectEqualStrings("format-then", setup.window.name);
}

test "if-shell -F queues the else command when the format is zero" {
    var setup = testSetup("if-shell-format-false");
    defer testTeardown(&setup);

    try appendCommand(&setup.client, &.{
        "if-shell",
        "-F",
        "0",
        "rename-window -t if-shell-format-false:0 ignored",
        "rename-window -t if-shell-format-false:0 format-else",
    });

    try std.testing.expectEqual(@as(u32, 2), cmdq.cmdq_next(&setup.client));
    try std.testing.expectEqualStrings("format-else", setup.window.name);
}

test "if-shell waits for a shell success and then queues the command" {
    const old_base = installEventBase();
    defer restoreEventBase(old_base);

    var setup = testSetup("if-shell-async-true");
    defer testTeardown(&setup);

    try appendCommand(&setup.client, &.{
        "if-shell",
        "exit 0",
        "rename-window -t if-shell-async-true:0 shell-then",
    });

    try std.testing.expectEqual(@as(u32, 0), cmdq.cmdq_next(&setup.client));
    pumpAsyncOnce();
    try std.testing.expectEqual(@as(u32, 1), cmdq.cmdq_next(&setup.client));
    try std.testing.expectEqualStrings("shell-then", setup.window.name);
}

test "if-shell waits for a shell failure and then queues the else command" {
    const old_base = installEventBase();
    defer restoreEventBase(old_base);

    var setup = testSetup("if-shell-async-false");
    defer testTeardown(&setup);

    try appendCommand(&setup.client, &.{
        "if-shell",
        "exit 1",
        "rename-window -t if-shell-async-false:0 ignored",
        "rename-window -t if-shell-async-false:0 shell-else",
    });

    try std.testing.expectEqual(@as(u32, 0), cmdq.cmdq_next(&setup.client));
    pumpAsyncOnce();
    try std.testing.expectEqual(@as(u32, 1), cmdq.cmdq_next(&setup.client));
    try std.testing.expectEqualStrings("shell-else", setup.window.name);
}

test "if-shell parse separates shell command and then command" {
    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "if-shell", "/bin/true", "select-window -t:.0" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);

    const args = cmd_mod.cmd_get_args(cmd);
    try std.testing.expectEqualStrings("/bin/true", args.value_at(0).?);
    try std.testing.expectEqualStrings("select-window -t:.0", args.value_at(1).?);
}

test "if-shell -b leaves the caller queue running and appends the branch later" {
    const old_base = installEventBase();
    defer restoreEventBase(old_base);

    var setup = testSetup("if-shell-background");
    defer testTeardown(&setup);

    try appendCommand(&setup.client, &.{
        "if-shell",
        "-b",
        "exit 0",
        "rename-window -t if-shell-background:0 background-then",
    });
    try appendCommand(&setup.client, &.{
        "rename-window",
        "-t",
        "if-shell-background:0",
        "foreground-ran",
    });

    try std.testing.expectEqual(@as(u32, 2), cmdq.cmdq_next(&setup.client));
    try std.testing.expectEqualStrings("foreground-ran", setup.window.name);

    pumpAsyncOnce();
    try std.testing.expect(cmdq.cmdq_next(null) >= 1);
    try std.testing.expectEqualStrings("background-then", setup.window.name);
}
