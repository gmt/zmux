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
// Ported in part from tmux/cmd-run-shell.c.
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
const cmd_find = @import("cmd-find.zig");
const cmd_mod = @import("cmd.zig");
const cmdq = @import("cmd-queue.zig");
const proc_mod = @import("proc.zig");
const grid_mod = @import("grid.zig");
const screen_mod = @import("screen.zig");
const server_client_mod = @import("server-client.zig");
const server_print = @import("server-print.zig");
const session_mod = @import("session.zig");
const status_runtime = @import("status-runtime.zig");
const window_mod = @import("window.zig");

const TargetSnapshot = struct {
    session_id: ?u32 = null,
    window_id: ?u32 = null,
    pane_id: ?u32 = null,
};

const RunShellState = struct {
    item: ?*cmdq.CmdqItem = null,
    queue_client_id: ?u32 = null,
    target_snapshot: TargetSnapshot = .{},
    shell_command: ?[]u8 = null,
    command_text: ?[]u8 = null,
    cwd: []u8,
    target_pane_id: ?u32 = null,
    timer_event: ?*c.libevent.event = null,
    completion_event: ?*c.libevent.event = null,
    pipe_read: std.posix.fd_t = -1,
    pipe_write: std.posix.fd_t = -1,
    thread: ?std.Thread = null,
    output: std.ArrayList(u8) = .{},
    show_stderr: bool = false,
    spawned: bool = false,
    spawn_failed: bool = false,
    retcode: i32 = 0,
    signal_code: ?u32 = null,
};

fn freeState(state: *RunShellState) void {
    if (state.thread) |thread| thread.join();
    if (state.timer_event) |ev| {
        _ = c.libevent.event_del(ev);
        c.libevent.event_free(ev);
    }
    if (state.completion_event) |ev| {
        _ = c.libevent.event_del(ev);
        c.libevent.event_free(ev);
    }
    if (state.pipe_read >= 0) std.posix.close(state.pipe_read);
    if (state.pipe_write >= 0) std.posix.close(state.pipe_write);
    if (state.shell_command) |text| xm.allocator.free(text);
    if (state.command_text) |text| xm.allocator.free(text);
    xm.allocator.free(state.cwd);
    state.output.deinit(xm.allocator);
    xm.allocator.destroy(state);
}

fn captureTarget(target: *const T.CmdFindState) TargetSnapshot {
    return .{
        .session_id = if (target.s) |s| s.id else null,
        .window_id = if (target.w) |w| w.id else null,
        .pane_id = if (target.wp) |wp| wp.id else null,
    };
}

fn findQueueClient(id: ?u32) ?*T.Client {
    const actual_id = id orelse return null;
    for (client_registry.clients.items) |client| {
        if (client.id == actual_id) return client;
    }
    return null;
}

fn resolveSessionForWindow(preferred_session_id: ?u32, window: *T.Window) ?*T.Session {
    if (preferred_session_id) |session_id| {
        if (session_mod.session_find_by_id(session_id)) |session| {
            if (session_mod.winlink_find_by_window(&session.windows, window) != null)
                return session;
        }
    }

    for (window.winlinks.items) |wl| {
        const session = wl.session;
        if (!session_mod.session_alive(session)) continue;
        if (session_mod.winlink_find_by_window(&session.windows, window) == wl)
            return session;
    }
    return null;
}

fn restoreTarget(snapshot: TargetSnapshot) T.CmdFindState {
    var target: T.CmdFindState = .{ .idx = -1 };

    if (snapshot.pane_id) |pane_id| {
        if (window_mod.window_pane_find_by_id(pane_id)) |pane| {
            target.wp = pane;
            target.w = pane.window;
            if (resolveSessionForWindow(snapshot.session_id, pane.window)) |session| {
                session_mod.session_repair_current(session);
                target.s = session;
                target.wl = session_mod.winlink_find_by_window(&session.windows, pane.window);
            }
            return target;
        }
    }

    if (snapshot.window_id) |window_id| {
        if (window_mod.window_find_by_id(window_id)) |window| {
            target.w = window;
            target.wp = window.active;
            if (resolveSessionForWindow(snapshot.session_id, window)) |session| {
                session_mod.session_repair_current(session);
                target.s = session;
                target.wl = session_mod.winlink_find_by_window(&session.windows, window);
            }
            return target;
        }
    }

    if (snapshot.session_id) |session_id| {
        if (session_mod.session_find_by_id(session_id)) |session| {
            session_mod.session_repair_current(session);
            target.s = session;
            target.wl = session.curw;
            if (session.curw) |wl| {
                target.w = wl.window;
                target.wp = wl.window.active;
            }
        }
    }

    return target;
}

fn splitAndPrintOutput(item: ?*cmdq.CmdqItem, client: ?*T.Client, text: []const u8) void {
    var start: usize = 0;
    for (text, 0..) |byte, idx| {
        if (byte != '\n') continue;
        const line = text[start..idx];
        if (item) |waiting_item|
            cmdq.cmdq_print(waiting_item, "{s}", .{line})
        else
            cmdq.cmdq_write_client(client, 1, "{s}", .{line});
        start = idx + 1;
    }
    if (start < text.len) {
        const line = text[start..];
        if (item) |waiting_item|
            cmdq.cmdq_print(waiting_item, "{s}", .{line})
        else
            cmdq.cmdq_write_client(client, 1, "{s}", .{line});
    }
}

fn currentPaneForClient(client: ?*T.Client) ?*T.WindowPane {
    const c_ptr = client orelse return null;
    const session = c_ptr.session orelse return null;
    session_mod.session_repair_current(session);
    const wl = session.curw orelse return null;
    return wl.window.active;
}

fn showOutputInPane(wp: *T.WindowPane, data: []const u8) void {
    _ = server_print.server_pane_view_data(wp, data, true);
}

fn deliverOutput(state: *RunShellState) void {
    const item = state.item;
    var target_pane: ?*T.WindowPane = null;

    if (state.target_pane_id) |pane_id| {
        target_pane = window_mod.window_pane_find_by_id(pane_id);
    }

    if (target_pane == null) {
        if (item != null) {
            splitAndPrintOutput(item, null, state.output.items);
            return;
        }
        const queue_client = findQueueClient(state.queue_client_id);
        target_pane = currentPaneForClient(queue_client) orelse cmd_find.cmd_find_best_pane(T.CMD_FIND_QUIET);
    }

    if (target_pane) |pane| {
        showOutputInPane(pane, state.output.items);
        return;
    }

    splitAndPrintOutput(null, findQueueClient(state.queue_client_id), state.output.items);
}

fn commandParseError(item: ?*cmdq.CmdqItem, queue_client_id: ?u32, err: []const u8) void {
    if (item) |waiting_item| {
        cmdq.cmdq_error(waiting_item, "{s}", .{err});
        return;
    }

    status_runtime.present_client_message(findQueueClient(queue_client_id), err);
}

fn runQueuedCommands(state: *RunShellState) void {
    const command_text = state.command_text orelse {
        if (state.item) |item| cmdq.cmdq_continue(item);
        freeState(state);
        return;
    };

    const item = state.item;
    const queue_client = findQueueClient(state.queue_client_id);
    const target = if (item) |waiting_item| cmdq.cmdq_get_target(waiting_item) else restoreTarget(state.target_snapshot);
    const expanded = cmd_display.expand_format(xm.allocator, command_text, &target);
    defer xm.allocator.free(expanded);

    var pi = T.CmdParseInput{
        .item = if (item) |waiting_item| @ptrCast(waiting_item) else null,
        .c = if (item) |waiting_item|
            cmdq.cmdq_get_target_client(waiting_item) orelse cmdq.cmdq_get_client(waiting_item)
        else
            queue_client,
        .fs = target,
    };
    const parsed = cmd_mod.cmd_parse_from_string(expanded, &pi);
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

    if (item) |waiting_item| cmdq.cmdq_continue(waiting_item);
    freeState(state);
}

fn appendExitMessage(state: *RunShellState) void {
    if (state.signal_code) |signal_code| {
        const message = xm.xasprintf("'{s}' terminated by signal {d}", .{ state.shell_command.?, signal_code });
        defer xm.allocator.free(message);
        if (state.output.items.len != 0) state.output.append(xm.allocator, '\n') catch unreachable;
        state.output.appendSlice(xm.allocator, message) catch unreachable;
        return;
    }

    if (state.retcode != 0) {
        const message = xm.xasprintf("'{s}' returned {d}", .{ state.shell_command.?, state.retcode });
        defer xm.allocator.free(message);
        if (state.output.items.len != 0) state.output.append(xm.allocator, '\n') catch unreachable;
        state.output.appendSlice(xm.allocator, message) catch unreachable;
    }
}

fn completeShellCommand(state: *RunShellState) void {
    if (state.spawn_failed) {
        if (state.item) |item| {
            cmdq.cmdq_error(item, "failed to run command: {s}", .{state.shell_command.?});
            cmdq.cmdq_continue(item);
        } else {
            const message = xm.xasprintf("failed to run command: {s}", .{state.shell_command.?});
            defer xm.allocator.free(message);
            status_runtime.present_client_message(findQueueClient(state.queue_client_id), message);
        }
        freeState(state);
        return;
    }

    appendExitMessage(state);
    deliverOutput(state);

    if (state.item) |item| {
        if (cmdq.cmdq_get_client(item)) |item_client| {
            if (item_client.session == null) item_client.retval = state.retcode;
        }
        cmdq.cmdq_continue(item);
    }
    freeState(state);
}

fn notifyCompletion(state: *RunShellState) void {
    if (state.pipe_write < 0) return;
    _ = std.posix.write(state.pipe_write, &[1]u8{1}) catch {};
    std.posix.close(state.pipe_write);
    state.pipe_write = -1;
}

fn shellThreadMain(state: *RunShellState) void {
    defer notifyCompletion(state);

    const command_to_run = if (state.show_stderr)
        xm.xasprintf("exec 2>&1; {s}", .{state.shell_command.?})
    else
        xm.xstrdup(state.shell_command.?);
    defer xm.allocator.free(command_to_run);

    var child = std.process.Child.init(&.{ "/bin/sh", "-c", command_to_run }, xm.allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.cwd = state.cwd;

    child.spawn() catch {
        state.spawn_failed = true;
        return;
    };
    state.spawned = true;

    const stdout_pipe = child.stdout orelse {
        state.spawn_failed = true;
        _ = child.wait() catch {};
        return;
    };

    var buf: [4096]u8 = undefined;
    while (true) {
        const amt = stdout_pipe.read(&buf) catch {
            state.spawn_failed = true;
            _ = child.wait() catch {};
            return;
        };
        if (amt == 0) break;
        state.output.appendSlice(xm.allocator, buf[0..amt]) catch unreachable;
    }

    const term = child.wait() catch {
        state.spawn_failed = true;
        return;
    };
    switch (term) {
        .Exited => |code| {
            state.retcode = code;
        },
        .Signal => |signal_code| {
            state.signal_code = signal_code;
            state.retcode = @as(i32, @intCast(signal_code)) + 128;
        },
        else => {
            state.retcode = 1;
        },
    }
}

fn armCompletionEvent(state: *RunShellState) bool {
    const base = proc_mod.libevent orelse return false;
    const pipe_fds = std.posix.pipe() catch return false;
    state.pipe_read = pipe_fds[0];
    state.pipe_write = pipe_fds[1];

    state.completion_event = c.libevent.event_new(
        base,
        state.pipe_read,
        @intCast(c.libevent.EV_READ),
        cmd_run_shell_event_cb,
        state,
    );
    if (state.completion_event == null) return false;
    if (c.libevent.event_add(state.completion_event.?, null) != 0) return false;
    return true;
}

fn startShellCommand(state: *RunShellState) bool {
    if (!armCompletionEvent(state)) return false;
    state.thread = std.Thread.spawn(.{}, shellThreadMain, .{state}) catch return false;
    return true;
}

fn parseDelay(text: []const u8) ?f64 {
    return std.fmt.parseFloat(f64, text) catch null;
}

fn armTimer(state: *RunShellState, delay_seconds: ?f64) bool {
    const base = proc_mod.libevent orelse return false;
    state.timer_event = c.libevent.event_new(
        base,
        -1,
        @intCast(c.libevent.EV_TIMEOUT),
        cmd_run_shell_timer_cb,
        state,
    );
    if (state.timer_event == null) return false;

    var tv = std.posix.timeval{
        .sec = 0,
        .usec = 0,
    };
    if (delay_seconds) |delay| {
        const whole_seconds = @floor(delay);
        const micros = @as(i64, @intFromFloat(@round((delay - whole_seconds) * 1_000_000.0)));
        tv.sec = @intFromFloat(whole_seconds);
        tv.usec = @intCast(micros);
    }

    return c.libevent.event_add(state.timer_event.?, @ptrCast(&tv)) == 0;
}

export fn cmd_run_shell_timer_cb(_fd: c_int, _events: c_short, arg: ?*anyopaque) void {
    _ = _fd;
    _ = _events;
    const state: *RunShellState = @ptrCast(@alignCast(arg orelse return));

    if (state.timer_event) |ev| {
        _ = c.libevent.event_del(ev);
        c.libevent.event_free(ev);
        state.timer_event = null;
    }

    if (state.command_text != null) {
        runQueuedCommands(state);
        return;
    }

    if (state.shell_command == null) {
        if (state.item) |item| cmdq.cmdq_continue(item);
        freeState(state);
        return;
    }

    if (!startShellCommand(state)) {
        if (state.item) |item| {
            cmdq.cmdq_error(item, "failed to run command: {s}", .{state.shell_command.?});
            cmdq.cmdq_continue(item);
        } else {
            const message = xm.xasprintf("failed to run command: {s}", .{state.shell_command.?});
            defer xm.allocator.free(message);
            status_runtime.present_client_message(findQueueClient(state.queue_client_id), message);
        }
        freeState(state);
    }
}

export fn cmd_run_shell_event_cb(fd: c_int, _events: c_short, arg: ?*anyopaque) void {
    _ = _events;
    const state: *RunShellState = @ptrCast(@alignCast(arg orelse return));

    var discard: [16]u8 = undefined;
    _ = std.posix.read(fd, &discard) catch {};

    if (state.completion_event) |ev| {
        _ = c.libevent.event_del(ev);
        c.libevent.event_free(ev);
        state.completion_event = null;
    }
    if (state.pipe_read >= 0) {
        std.posix.close(state.pipe_read);
        state.pipe_read = -1;
    }

    completeShellCommand(state);
}

fn exec(self: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {
    const args = cmd_mod.cmd_get_args(self);
    var target: T.CmdFindState = .{};
    const wait = !args.has('b');
    const delay = if (args.get('d')) |text| parseDelay(text) else null;

    _ = cmd_find.cmd_find_target(&target, item, args.get('t'), .pane, T.CMD_FIND_CANFAIL);

    if (args.get('d') != null and delay == null) {
        cmdq.cmdq_error(item, "invalid delay time: {s}", .{args.get('d').?});
        return .@"error";
    }
    if (args.count() == 0 and delay == null) return .normal;

    const state = xm.allocator.create(RunShellState) catch unreachable;
    state.* = .{
        .item = if (wait) item else null,
        .queue_client_id = if (cmdq.cmdq_get_target_client(item)) |queue_client| queue_client.id else if (cmdq.cmdq_get_client(item)) |queue_client| queue_client.id else null,
        .target_snapshot = captureTarget(&target),
        .cwd = if (args.get('c')) |cwd| xm.xstrdup(cwd) else xm.xstrdup(server_client_mod.server_client_get_cwd(cmdq.cmdq_get_client(item), target.s)),
        .target_pane_id = if (args.has('t') and target.wp != null) target.wp.?.id else null,
        .output = .{},
        .show_stderr = args.has('E'),
    };
    errdefer freeState(state);

    if (args.has('C')) {
        if (args.value_at(0)) |text| state.command_text = xm.xstrdup(text);
    } else if (args.value_at(0)) |text| {
        const expanded = cmd_display.expand_format(xm.allocator, text, &target);
        defer xm.allocator.free(expanded);
        state.shell_command = xm.xstrdup(expanded);
    }

    if (!armTimer(state, delay)) {
        cmdq.cmdq_error(item, "failed to schedule run-shell", .{});
        return .@"error";
    }

    return if (wait) .wait else .normal;
}

pub const entry: cmd_mod.CmdEntry = .{
    .name = "run-shell",
    .alias = "run",
    .usage = "[-bCE] [-c start-directory] [-d delay] [-t target-pane] [shell-command]",
    .template = "bd:Ct:Es:c:",
    .lower = 0,
    .upper = 1,
    .exec = exec,
};

const TestSetup = struct {
    session: *T.Session,
    window: *T.Window,
    pane: *T.WindowPane,
    client: T.Client,
};

const SessionPaneSetup = struct {
    session: *T.Session,
    window: *T.Window,
    pane: *T.WindowPane,
};

fn testSetup(name: []const u8) TestSetup {
    const env_mod = @import("environ.zig");
    const opts = @import("options.zig");

    session_mod.session_init_globals(xm.allocator);
    window_mod.window_init_globals(xm.allocator);

    opts.global_options = opts.options_create(null);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.global_s_options = opts.options_create(null);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.global_w_options = opts.options_create(null);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);

    env_mod.global_environ = env_mod.environ_create();

    const session = session_mod.session_create(null, name, "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    const window = window_mod.window_create(80, 24, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    var cause: ?[]u8 = null;
    const wl = session_mod.session_attach(session, window, -1, &cause).?;
    const pane = window_mod.window_add_pane(window, null, 80, 24);
    window.active = pane;
    session.curw = wl;

    var client = T.Client{
        .id = 878,
        .name = xm.xstrdup(name),
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{ .screen = undefined },
        .flags = T.CLIENT_ATTACHED,
        .session = session,
    };
    client.tty.client = &client;

    return .{
        .session = session,
        .window = window,
        .pane = pane,
        .client = client,
    };
}

fn testTeardown(setup: *TestSetup) void {
    const env_mod = @import("environ.zig");
    const opts = @import("options.zig");

    env_mod.environ_free(setup.client.environ);
    if (setup.client.name) |name| xm.allocator.free(@constCast(name));
    if (session_mod.session_find(setup.session.name)) |_| session_mod.session_destroy(setup.session, false, "test");
    window_mod.window_remove_ref(setup.window, "test");
    env_mod.environ_free(env_mod.global_environ);
    opts.options_free(opts.global_options);
    opts.options_free(opts.global_s_options);
    opts.options_free(opts.global_w_options);
}

fn addSessionPane(name: []const u8) SessionPaneSetup {
    const env_mod = @import("environ.zig");
    const opts = @import("options.zig");

    const session = session_mod.session_create(null, name, "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    const window = window_mod.window_create(80, 24, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    var cause: ?[]u8 = null;
    const wl = session_mod.session_attach(session, window, -1, &cause).?;
    const pane = window_mod.window_add_pane(window, null, 80, 24);
    window.active = pane;
    session.curw = wl;

    return .{
        .session = session,
        .window = window,
        .pane = pane,
    };
}

fn removeSessionPane(setup: *SessionPaneSetup) void {
    if (session_mod.session_find(setup.session.name)) |_| session_mod.session_destroy(setup.session, false, "test");
    window_mod.window_remove_ref(setup.window, "test");
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

fn pumpAsyncNonblock() void {
    _ = c.libevent.event_loop(c.libevent.EVLOOP_NONBLOCK);
}

fn waitForAlternateScreen(wp: *T.WindowPane) !void {
    for (0..200) |_| {
        pumpAsyncNonblock();
        if (screen_mod.screen_alternate_active(wp)) return;
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
    return error.TestExpectedEqual;
}

fn waitForQueueProgress(client: ?*T.Client, expected: u32) !void {
    var processed: u32 = 0;
    var primed = false;
    for (0..200) |_| {
        processed = cmdq.cmdq_next(client);
        if (processed != 0) break;
        if (!primed) {
            _ = c.libevent.event_loop(c.libevent.EVLOOP_ONCE);
            primed = true;
        } else {
            pumpAsyncNonblock();
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }
    }
    try std.testing.expectEqual(expected, processed);
}

fn captureStdout(ctx: anytype, comptime run: fn (@TypeOf(ctx)) anyerror!void) ![]u8 {
    const saved_stdout = try std.posix.dup(std.posix.STDOUT_FILENO);
    defer std.posix.close(saved_stdout);

    const pipe_fds = try std.posix.pipe();
    defer std.posix.close(pipe_fds[0]);

    try std.posix.dup2(pipe_fds[1], std.posix.STDOUT_FILENO);
    defer std.posix.dup2(saved_stdout, std.posix.STDOUT_FILENO) catch {};

    try run(ctx);
    try std.posix.dup2(saved_stdout, std.posix.STDOUT_FILENO);
    std.posix.close(pipe_fds[1]);

    var out: std.ArrayList(u8) = .{};
    errdefer out.deinit(xm.allocator);
    var buf: [256]u8 = undefined;
    while (true) {
        const amt = try std.posix.read(pipe_fds[0], &buf);
        if (amt == 0) break;
        try out.appendSlice(xm.allocator, buf[0..amt]);
    }
    return out.toOwnedSlice(xm.allocator);
}

fn gridRowString(grid: *T.Grid, row: u32) ![]u8 {
    const used = grid_mod.line_used(grid, row);
    const out = try xm.allocator.alloc(u8, used);
    errdefer xm.allocator.free(out);

    for (0..used) |idx| {
        out[idx] = grid_mod.ascii_at(grid, row, @intCast(idx));
    }
    return out;
}

test "run-shell writes output to stdout when no target pane is forced" {
    const old_base = installEventBase();
    defer restoreEventBase(old_base);

    var setup = testSetup("run-shell-stdout");
    defer testTeardown(&setup);

    const output = try captureStdout(&setup.client, struct {
        fn run(client: *T.Client) !void {
            try appendCommand(client, &.{
                "run-shell",
                "printf 'foo\\nbar'",
            });
            try appendCommand(client, &.{
                "rename-window",
                "-t",
                "run-shell-stdout:0",
                "stdout-finished",
            });
            try std.testing.expectEqual(@as(u32, 0), cmdq.cmdq_next(client));
            try waitForQueueProgress(client, 1);
        }
    }.run);
    defer xm.allocator.free(output);

    try std.testing.expectEqualStrings("foo\nbar\n", output);
    try std.testing.expectEqualStrings("stdout-finished", setup.window.name);
}

test "run-shell -E forwards stderr into stdout output" {
    const old_base = installEventBase();
    defer restoreEventBase(old_base);

    var setup = testSetup("run-shell-stderr");
    defer testTeardown(&setup);

    const output = try captureStdout(&setup.client, struct {
        fn run(client: *T.Client) !void {
            try appendCommand(client, &.{
                "run-shell",
                "-E",
                "printf 'out\\n'; printf 'err\\n' >&2",
            });
            try appendCommand(client, &.{
                "rename-window",
                "-t",
                "run-shell-stderr:0",
                "stderr-finished",
            });
            try std.testing.expectEqual(@as(u32, 0), cmdq.cmdq_next(client));
            try waitForQueueProgress(client, 1);
        }
    }.run);
    defer xm.allocator.free(output);

    try std.testing.expectEqualStrings("out\nerr\n", output);
    try std.testing.expectEqualStrings("stderr-finished", setup.window.name);
}

test "run-shell -t shows shell output in the target pane view mode" {
    const old_base = installEventBase();
    defer restoreEventBase(old_base);

    var setup = testSetup("run-shell-pane");
    defer testTeardown(&setup);
    defer if (window_mod.window_pane_mode(setup.pane)) |_| server_print.server_client_close_view_mode(setup.pane);

    const target = try std.fmt.allocPrint(xm.allocator, "%{d}", .{setup.pane.id});
    defer xm.allocator.free(target);

    try appendCommand(&setup.client, &.{
        "run-shell",
        "-t",
        target,
        "printf 'pane\\noutput'",
    });
    try appendCommand(&setup.client, &.{
        "rename-window",
        "-t",
        "run-shell-pane:0",
        "pane-finished",
    });

    try std.testing.expectEqual(@as(u32, 0), cmdq.cmdq_next(&setup.client));
    try waitForQueueProgress(&setup.client, 1);
    try std.testing.expectEqualStrings("pane-finished", setup.window.name);
    try std.testing.expect(screen_mod.screen_alternate_active(setup.pane));
    try std.testing.expect(window_mod.window_pane_mode(setup.pane) != null);

    const first = try gridRowString(setup.pane.screen.grid, 0);
    defer xm.allocator.free(first);
    const second = try gridRowString(setup.pane.screen.grid, 1);
    defer xm.allocator.free(second);
    try std.testing.expectEqualStrings("pane", first);
    try std.testing.expectEqualStrings("output", second);
}

test "run-shell -bC preserves the original target context for delayed commands" {
    const old_base = installEventBase();
    defer restoreEventBase(old_base);

    var setup = testSetup("run-shell-background-command");
    defer testTeardown(&setup);

    try appendCommand(&setup.client, &.{
        "run-shell",
        "-bC",
        "rename-window -t #{session_name}:#{window_index} queued-from-run-shell",
    });

    try std.testing.expectEqual(@as(u32, 1), cmdq.cmdq_next(&setup.client));
    try waitForQueueProgress(null, 1);
    try std.testing.expectEqualStrings("queued-from-run-shell", setup.window.name);
}

test "run-shell -bC preserves quoted semicolons inside delayed commands" {
    const old_base = installEventBase();
    defer restoreEventBase(old_base);

    var setup = testSetup("run-shell-quoted-semicolon");
    defer testTeardown(&setup);

    try appendCommand(&setup.client, &.{
        "run-shell",
        "-bC",
        "rename-window -t #{session_name}:#{window_index} 'semi;colon'",
    });

    try std.testing.expectEqual(@as(u32, 1), cmdq.cmdq_next(&setup.client));
    try waitForQueueProgress(null, 1);
    try std.testing.expectEqualStrings("semi;colon", setup.window.name);
}

test "run-shell -b without a client falls back to the best session pane" {
    const old_base = installEventBase();
    defer restoreEventBase(old_base);

    var first = testSetup("run-shell-no-client-first");
    defer testTeardown(&first);
    defer if (window_mod.window_pane_mode(first.pane)) |_| server_print.server_client_close_view_mode(first.pane);

    var second = addSessionPane("run-shell-no-client-second");
    defer removeSessionPane(&second);
    defer if (window_mod.window_pane_mode(second.pane)) |_| server_print.server_client_close_view_mode(second.pane);

    first.session.activity_time = 100;
    second.session.activity_time = 200;

    try appendCommand(null, &.{
        "run-shell",
        "-b",
        "printf 'best-pane'",
    });

    try std.testing.expectEqual(@as(u32, 1), cmdq.cmdq_next(null));
    try waitForAlternateScreen(second.pane);
    try std.testing.expect(!screen_mod.screen_alternate_active(first.pane));

    const line = try gridRowString(second.pane.screen.grid, 0);
    defer xm.allocator.free(line);
    try std.testing.expectEqualStrings("best-pane", line);
}

test "run-shell does not truncate large target-pane output" {
    const old_base = installEventBase();
    defer restoreEventBase(old_base);

    var setup = testSetup("run-shell-large-output");
    defer testTeardown(&setup);
    defer if (window_mod.window_pane_mode(setup.pane)) |_| server_print.server_client_close_view_mode(setup.pane);

    const target = try std.fmt.allocPrint(xm.allocator, "%{d}", .{setup.pane.id});
    defer xm.allocator.free(target);

    try appendCommand(&setup.client, &.{
        "run-shell",
        "-t",
        target,
        "python3 -c \"import sys; sys.stdout.write('a' * 1100000 + '\\nEND')\"",
    });
    try appendCommand(&setup.client, &.{
        "rename-window",
        "-t",
        "run-shell-large-output:0",
        "large-output-finished",
    });

    try std.testing.expectEqual(@as(u32, 0), cmdq.cmdq_next(&setup.client));
    try waitForQueueProgress(&setup.client, 1);

    var found_end = false;
    for (0..setup.pane.screen.grid.sy) |row| {
        const line = try gridRowString(setup.pane.screen.grid, @intCast(row));
        defer xm.allocator.free(line);
        if (std.mem.eql(u8, line, "END")) {
            found_end = true;
            break;
        }
    }

    try std.testing.expect(found_end);
    try std.testing.expectEqualStrings("large-output-finished", setup.window.name);
}
