// Stress tests for pipe-pane directionality and lifecycle.
//
// These exercise the pipe subsystem through pane-io primitives rather than
// the full cmd exec path, because the cmd layer is already covered by the
// unit tests in cmd-pipe-pane.zig.

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const pane_io = @import("pane-io.zig");
const win = @import("window.zig");
const opts = @import("options.zig");
const grid = @import("grid.zig");

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

fn init_globals() void {
    opts.global_w_options = opts.options_create(null);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    win.window_init_globals(xm.allocator);
}

fn teardown_globals() void {
    opts.options_free(opts.global_w_options);
}

const PaneFixture = struct {
    w: *T.Window,
    wp: *T.WindowPane,

    fn create(sx: u32, sy: u32) PaneFixture {
        const w = win.window_create(sx, sy, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
        const wp = win.window_add_pane(w, null, sx, sy);
        return .{ .w = w, .wp = wp };
    }

    fn destroy(self: PaneFixture) void {
        const w = self.w;
        while (w.panes.items.len > 0) {
            const p = w.panes.items[w.panes.items.len - 1];
            win.window_remove_pane(w, p);
        }
        w.panes.deinit(xm.allocator);
        w.last_panes.deinit(xm.allocator);
        opts.options_free(w.options);
        xm.allocator.free(w.name);
        _ = win.windows.remove(w.id);
        xm.allocator.destroy(w);
    }
};

fn set_nonblocking(fd: i32) void {
    const flags = std.c.fcntl(fd, std.posix.F.GETFL, @as(c_int, 0));
    if (flags < 0) return;
    const O_NONBLOCK: c_int = 0x800;
    _ = std.c.fcntl(fd, std.posix.F.SETFL, flags | O_NONBLOCK);
}

fn ignore_sigpipe() void {
    const sa_ign = std.posix.Sigaction{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.posix.sigemptyset(),
        .flags = std.os.linux.SA.RESTART,
    };
    std.posix.sigaction(std.posix.SIG.PIPE, &sa_ign, null);
}

fn make_socketpair() ![2]i32 {
    var pair: [2]i32 = undefined;
    if (std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &pair) != 0)
        return error.SocketPairFailed;
    return pair;
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

test "pipe direction flags control write routing to child process" {
    init_globals();
    defer teardown_globals();
    const f = PaneFixture.create(10, 3);
    defer f.destroy();

    const pair = try make_socketpair();
    defer std.posix.close(pair[0]);
    defer std.posix.close(pair[1]);
    set_nonblocking(pair[0]);
    set_nonblocking(pair[1]);

    f.wp.pipe_fd = pair[0];
    f.wp.pipe_flags = T.PANE_PIPE_WRITE;
    defer {
        // Prevent pane cleanup from closing an already-closed fd.
        f.wp.pipe_fd = -1;
        f.wp.pipe_flags = 0;
    }

    // With WRITE flag: pane_io_feed should forward bytes into the pipe.
    pane_io.pane_io_feed(f.wp, "hello");

    var buf: [32]u8 = undefined;
    const n = try std.posix.read(pair[1], &buf);
    try std.testing.expectEqualStrings("hello", buf[0..n]);

    // Switch to READ-only: further pane_io_feed must NOT write to the pipe.
    f.wp.pipe_flags = T.PANE_PIPE_READ;
    pane_io.pane_io_feed(f.wp, "nope");

    try std.testing.expectError(error.WouldBlock, std.posix.read(pair[1], &buf));
}

test "pane_pipe_close terminates child process and resets all pipe state" {
    init_globals();
    defer teardown_globals();
    const f = PaneFixture.create(8, 2);
    defer f.destroy();

    const pair = try make_socketpair();
    // pair[1] simulates the child end; close it before fork.
    std.posix.close(pair[1]);

    const pid = try std.posix.fork();
    if (pid == 0) {
        // Child: sleep briefly then exit.
        std.posix.close(pair[0]);
        std.Thread.sleep(50 * std.time.ns_per_ms);
        std.c._exit(0);
    }

    f.wp.pipe_fd = pair[0];
    f.wp.pipe_pid = pid;
    f.wp.pipe_flags = T.PANE_PIPE_WRITE | T.PANE_PIPE_READ;
    f.wp.pipe_offset = .{ .used = 42 };

    pane_io.pane_pipe_close(f.wp);

    try std.testing.expectEqual(@as(i32, -1), f.wp.pipe_fd);
    try std.testing.expectEqual(@as(std.posix.pid_t, -1), f.wp.pipe_pid);
    try std.testing.expectEqual(@as(u8, 0), f.wp.pipe_flags);
}

test "writing to a pipe whose remote end is closed triggers automatic cleanup" {
    ignore_sigpipe();
    init_globals();
    defer teardown_globals();
    const f = PaneFixture.create(8, 2);
    defer f.destroy();

    const pair = try make_socketpair();
    // Close the "child" end immediately to make the write fail.
    std.posix.close(pair[1]);

    f.wp.pipe_fd = pair[0];
    f.wp.pipe_pid = -1; // no child to signal
    f.wp.pipe_flags = T.PANE_PIPE_WRITE;

    // pane_io_feed -> pipe_bytes -> write to dead socket -> BrokenPipe/EPIPE ->
    // pane_pipe_close called internally.
    pane_io.pane_io_feed(f.wp, "this goes nowhere");

    try std.testing.expectEqual(@as(i32, -1), f.wp.pipe_fd);
    try std.testing.expectEqual(@as(u8, 0), f.wp.pipe_flags);
}

test "rapid pipe open and close cycles leave pane in clean state" {
    init_globals();
    defer teardown_globals();
    const f = PaneFixture.create(8, 2);
    defer f.destroy();

    var i: usize = 0;
    while (i < 30) : (i += 1) {
        const pair = try make_socketpair();
        std.posix.close(pair[1]);
        f.wp.pipe_fd = pair[0];
        f.wp.pipe_pid = -1;
        f.wp.pipe_flags = if (i % 2 == 0) T.PANE_PIPE_WRITE else T.PANE_PIPE_READ;
        f.wp.pipe_offset = .{ .used = @intCast(i) };

        pane_io.pane_pipe_close(f.wp);

        try std.testing.expectEqual(@as(i32, -1), f.wp.pipe_fd);
        try std.testing.expectEqual(@as(u8, 0), f.wp.pipe_flags);
    }
}

test "pipe read direction feeds child output into pane grid" {
    init_globals();
    defer teardown_globals();
    const f = PaneFixture.create(12, 3);
    defer f.destroy();

    const pair = try make_socketpair();
    defer std.posix.close(pair[1]);
    set_nonblocking(pair[0]);

    f.wp.pipe_fd = pair[0];
    f.wp.pipe_flags = T.PANE_PIPE_READ;
    defer {
        f.wp.pipe_fd = -1;
        f.wp.pipe_flags = 0;
    }

    // Simulate child writing output.
    _ = try std.posix.write(pair[1], "world");

    pane_io.pane_pipe_read_ready(f.wp);

    const expected = "world";
    for (expected, 0..) |ch, idx| {
        try std.testing.expectEqual(ch, grid.ascii_at(f.wp.base.grid, 0, @intCast(idx)));
    }
}

test "pane_pipe_read_ready is harmless when pipe_fd is already closed" {
    init_globals();
    defer teardown_globals();
    const f = PaneFixture.create(8, 2);
    defer f.destroy();

    // pipe_fd starts at -1 by default; call should be a no-op.
    f.wp.pipe_fd = -1;
    f.wp.pipe_flags = T.PANE_PIPE_READ;
    defer f.wp.pipe_flags = 0;

    // Must not crash or panic.
    pane_io.pane_pipe_read_ready(f.wp);

    // Grid should be untouched (all spaces).
    try std.testing.expectEqual(@as(u8, ' '), grid.ascii_at(f.wp.base.grid, 0, 0));
}
