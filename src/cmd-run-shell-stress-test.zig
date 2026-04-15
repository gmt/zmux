const std = @import("std");
const c = @import("c.zig");
const T = @import("types.zig");
const cmd_run_shell = @import("cmd-run-shell.zig");
const client_registry = @import("client-registry.zig");
const cmd_mod = @import("cmd.zig");
const cmdq = @import("cmd-queue.zig");
const env_mod = @import("environ.zig");
const job_mod = @import("job.zig");
const opts = @import("options.zig");
const proc_mod = @import("proc.zig");
const screen_mod = @import("screen.zig");
const session_mod = @import("session.zig");
const window_mod = @import("window.zig");
const xm = @import("xmalloc.zig");

const TestSetup = struct {
    session: *T.Session,
    window: *T.Window,
    pane: *T.WindowPane,
    client: T.Client,
};

var test_globals_initialized = false;

fn resetSharedTestState() void {
    cmdq.cmdq_reset_for_tests();
    client_registry.clients.clearRetainingCapacity();
    job_mod.job_reset_all();
}

fn initTestGlobals() void {
    if (test_globals_initialized) {
        env_mod.environ_free(env_mod.global_environ);
        opts.options_free(opts.global_options);
        opts.options_free(opts.global_s_options);
        opts.options_free(opts.global_w_options);
    }

    resetSharedTestState();

    opts.global_options = opts.options_create(null);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.global_s_options = opts.options_create(null);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.global_w_options = opts.options_create(null);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);

    env_mod.global_environ = env_mod.environ_create();
    test_globals_initialized = true;
}

fn testSetup(name: []const u8) TestSetup {
    session_mod.session_init_globals(xm.allocator);
    window_mod.window_init_globals(xm.allocator);
    initTestGlobals();

    const session = session_mod.session_create(null, name, "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    const window = window_mod.window_create(80, 24, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    var cause: ?[]u8 = null;
    const wl = session_mod.session_attach(session, window, -1, &cause).?;
    const pane = window_mod.window_add_pane(window, null, 80, 24);
    window.active = pane;
    session.curw = wl;

    var client = T.Client{
        .id = 1979,
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
        .pane = pane,
        .client = client,
    };
}

fn testTeardown(setup: *TestSetup) void {
    env_mod.environ_free(setup.client.environ);
    if (setup.client.name) |name| xm.allocator.free(@constCast(name));
    if (session_mod.session_find(setup.session.name)) |_| session_mod.session_destroy(setup.session, false, "test");
    window_mod.window_remove_ref(setup.window, "test");
    resetSharedTestState();
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
    var buf: [4096]u8 = undefined;
    while (true) {
        const amt = try std.posix.read(pipe_fds[0], &buf);
        if (amt == 0) break;
        try out.appendSlice(xm.allocator, buf[0..amt]);
    }
    return out.toOwnedSlice(xm.allocator);
}

fn gridRowString(grid: *T.Grid, row: u32) ![]u8 {
    const grid_mod = @import("grid.zig");
    return grid_mod.string_cells(grid, row, grid.sx, .{ .trim_trailing_spaces = true });
}

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

test "run-shell writes output to stdout for detached clients when no target pane is forced" {
    try cmd_run_shell.StressTests.runShellWritesOutputToStdoutForDetachedClientsWhenNoTargetPaneIsForced();
}

test "run-shell -E forwards stderr into detached stdout output" {
    try cmd_run_shell.StressTests.runShellEForwardsStderrIntoDetachedStdoutOutput();
}

test "run-shell without -t shows shell output in the attached current pane view mode" {
    try cmd_run_shell.StressTests.runShellWithoutTShowsShellOutputInTheAttachedCurrentPaneViewMode();
}

test "run-shell without output does not enter view mode" {
    try cmd_run_shell.StressTests.runShellWithoutOutputDoesNotEnterViewMode();
}

test "run-shell -t shows shell output in the target pane view mode" {
    try cmd_run_shell.StressTests.runShellTShowsShellOutputInTheTargetPaneViewMode();
}

test "run-shell target-pane output preserves shared utf8 grid payloads" {
    try cmd_run_shell.StressTests.runShellTargetPaneOutputPreservesSharedUtf8GridPayloads();
}

test "run-shell -bC preserves the original target context for delayed commands" {
    try cmd_run_shell.StressTests.runShellBCPreservesTheOriginalTargetContextForDelayedCommands();
}

test "run-shell -bC preserves quoted semicolons inside delayed commands" {
    try cmd_run_shell.StressTests.runShellBCPreservesQuotedSemicolonsInsideDelayedCommands();
}

test "run-shell registers the shared reduced job summary while work is active" {
    try cmd_run_shell.StressTests.runShellRegistersTheSharedReducedJobSummaryWhileWorkIsActive();
}

test "run-shell -b without a client falls back to the best session pane" {
    try cmd_run_shell.StressTests.runShellBWithoutAClientFallsBackToTheBestSessionPane();
}

test "run-shell does not truncate large target-pane output" {
    try cmd_run_shell.StressTests.runShellDoesNotTruncateLargeTargetPaneOutput();
}

test "run-shell detached large output reaches stdout without truncation" {
    const old_base = installEventBase();
    defer restoreEventBase(old_base);

    var setup = testSetup("run-shell-detached-large-stdout");
    defer testTeardown(&setup);
    setup.client.flags = 0;
    setup.client.session = null;
    setup.client.cwd = "/";

    const output = try captureStdout(&setup.client, struct {
        fn run(client: *T.Client) !void {
            try appendCommand(client, &.{
                "run-shell",
                "python3 -c \"import sys; sys.stdout.write('x' * 60000 + '\\nEND')\"",
            });
            try appendCommand(client, &.{
                "rename-window",
                "-t",
                "run-shell-detached-large-stdout:0",
                "detached-large-finished",
            });
            try std.testing.expectEqual(@as(u32, 0), cmdq.cmdq_next(client));
            try waitForQueueProgress(client, 1);
        }
    }.run);
    defer xm.allocator.free(output);

    try std.testing.expectEqual(@as(usize, 60_005), output.len);
    try std.testing.expect(std.mem.endsWith(u8, output, "\nEND\n"));
    try std.testing.expectEqualStrings("detached-large-finished", setup.window.name);
}

test "run-shell detached stdout sanitizes binary payload bytes for non-utf8 clients" {
    const old_base = installEventBase();
    defer restoreEventBase(old_base);

    var setup = testSetup("run-shell-detached-binary");
    defer testTeardown(&setup);
    setup.client.flags = 0;
    setup.client.session = null;
    setup.client.cwd = "/";

    const output = try captureStdout(&setup.client, struct {
        fn run(client: *T.Client) !void {
            try appendCommand(client, &.{
                "run-shell",
                "python3 -c \"import sys; sys.stdout.buffer.write(b'\\x00\\x01A\\xff\\n')\"",
            });
            try appendCommand(client, &.{
                "rename-window",
                "-t",
                "run-shell-detached-binary:0",
                "detached-binary-finished",
            });
            try std.testing.expectEqual(@as(u32, 0), cmdq.cmdq_next(client));
            try waitForQueueProgress(client, 1);
        }
    }.run);
    defer xm.allocator.free(output);

    try std.testing.expectEqualSlices(u8, "__A_\n", output);
    try std.testing.expectEqualStrings("detached-binary-finished", setup.window.name);
}

test "run-shell attached pane output marks redraw status and emits pane-mode notification" {
    const old_base = installEventBase();
    defer restoreEventBase(old_base);

    var setup = testSetup("run-shell-pane-side-effects");
    defer testTeardown(&setup);
    client_registry.add(&setup.client);

    var pair: [2]i32 = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &pair));

    var proc = T.ZmuxProc{ .name = "run-shell-pane-side-effects" };
    defer proc.peers.deinit(xm.allocator);

    const control_env = env_mod.environ_create();
    defer env_mod.environ_free(control_env);

    var control_client = T.Client{
        .environ = control_env,
        .tty = undefined,
        .status = .{},
        .flags = T.CLIENT_CONTROL,
        .session = null,
        .control_all_blocks = .{},
        .control_panes = .{},
    };
    control_client.tty = .{ .client = &control_client };
    control_client.peer = proc_mod.proc_add_peer(&proc, pair[0], test_peer_dispatch, null);
    defer {
        const peer = control_client.peer.?;
        c.imsg.imsgbuf_clear(&peer.ibuf);
        std.posix.close(peer.ibuf.fd);
        xm.allocator.destroy(peer);
        proc.peers.clearRetainingCapacity();
        control_client.peer = null;
    }

    var reader: c.imsg.imsgbuf = undefined;
    try std.testing.expectEqual(@as(i32, 0), c.imsg.imsgbuf_init(&reader, pair[1]));
    defer {
        c.imsg.imsgbuf_clear(&reader);
        std.posix.close(pair[1]);
    }

    client_registry.add(&control_client);
    setup.client.flags &= ~@as(u64, T.CLIENT_REDRAW);

    try appendCommand(&setup.client, &.{
        "run-shell",
        "printf 'notify-pane'",
    });
    try appendCommand(&setup.client, &.{
        "rename-window",
        "-t",
        "run-shell-pane-side-effects:0",
        "pane-side-effects-finished",
    });
    try std.testing.expectEqual(@as(u32, 0), cmdq.cmdq_next(&setup.client));
    try waitForQueueProgress(&setup.client, 1);

    const payload = try readPeerStreamPayloadAlloc(&reader);
    defer xm.allocator.free(payload);

    const row = try gridRowString(setup.pane.screen.grid, 0);
    defer xm.allocator.free(row);

    var expected_buf: [64]u8 = undefined;
    const expected = try std.fmt.bufPrint(&expected_buf, "%pane-mode-changed %{d}\n", .{setup.pane.id});

    try std.testing.expect(screen_mod.screen_alternate_active(setup.pane));
    try std.testing.expectEqualStrings("notify-pane", row);
    try std.testing.expectEqualStrings("pane-side-effects-finished", setup.window.name);
    try std.testing.expect(setup.client.flags & T.CLIENT_REDRAWPANES != 0);
    try std.testing.expect(setup.client.flags & T.CLIENT_REDRAWSTATUS != 0);
    try std.testing.expectEqualStrings(expected, payload);
}

test "run-shell detached output appends signal termination notice after partial output" {
    const old_base = installEventBase();
    defer restoreEventBase(old_base);

    var setup = testSetup("run-shell-detached-signal");
    defer testTeardown(&setup);
    setup.client.flags = 0;
    setup.client.session = null;
    setup.client.cwd = "/";

    const output = try captureStdout(&setup.client, struct {
        fn run(client: *T.Client) !void {
            try appendCommand(client, &.{
                "run-shell",
                "printf partial; kill -TERM $$",
            });
            try appendCommand(client, &.{
                "rename-window",
                "-t",
                "run-shell-detached-signal:0",
                "detached-signal-finished",
            });
            try std.testing.expectEqual(@as(u32, 0), cmdq.cmdq_next(client));
            try waitForQueueProgress(client, 1);
        }
    }.run);
    defer xm.allocator.free(output);

    try std.testing.expect(std.mem.startsWith(u8, output, "partial\n'"));
    try std.testing.expect(std.mem.indexOf(u8, output, "terminated by signal 15\n") != null);
    try std.testing.expectEqualStrings("detached-signal-finished", setup.window.name);
}
