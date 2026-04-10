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

//! Custom test runner for zmux.
//!
//! Extends the default Zig test runner with:
//!
//!   1. Per-test SIGALRM watchdog (PER_TEST_TIMEOUT_SECS).  A test that
//!      blocks indefinitely — e.g. waiting on a socket that will never
//!      receive data — is killed with a clear "test timed out" message
//!      rather than hanging the entire suite forever.
//!
//!   2. Process-group management.  The runner puts itself in its own
//!      process group at startup.  The SIGINT handler kills the whole
//!      group before exiting, so Ctrl-C during a test run also terminates
//!      any child processes the tests may have spawned (pty helpers,
//!      sleep guards, etc.) rather than leaving them as orphans.
//!
//! The runner is a drop-in replacement for the default test_runner.zig:
//! it speaks the same --listen=- server protocol so `zig build test`
//! still reports individual test results correctly.

const builtin = @import("builtin");
const std = @import("std");
const testing = std.testing;
const posix = std.posix;

/// Seconds allowed per individual test before SIGALRM fires.
/// Generous enough for slow CI machines; tight enough to catch hangs quickly.
const PER_TEST_TIMEOUT_SECS: c_uint = 30;

pub const std_options: std.Options = .{
    .logFn = log,
};

var log_err_count: usize = 0;
var fba = std.heap.FixedBufferAllocator.init(&fba_buffer);
var fba_buffer: [8192]u8 = undefined;
var stdin_buffer: [4096]u8 = undefined;
var stdout_buffer: [4096]u8 = undefined;

// Name of the currently-running test, set before each test_fn.func() call
// so the SIGALRM handler can print it.
var current_test_name: []const u8 = "<unknown>";

// ── Signal handlers ────────────────────────────────────────────────────────

/// SIGALRM: fired when a test exceeds PER_TEST_TIMEOUT_SECS.
/// Panics so the test runner reports a failure and moves on (in server mode
/// the panic is caught by the outer error handler).
fn handleAlarm(sig: c_int) callconv(.c) void {
    _ = sig;
    // Write directly to stderr — allocator may be in an inconsistent state.
    const msg = "FATAL: test timed out (SIGALRM)\n";
    _ = std.c.write(2, msg.ptr, msg.len);
    // Abort so the process exits with a non-zero status.  In server mode the
    // build system will see the connection drop and report the test as failed.
    std.process.abort();
}

/// SIGINT: Ctrl-C during the test run.  Kill the entire process group so
/// child processes spawned by tests (pty helpers, sleep guards, etc.) are
/// also terminated, then exit.
fn handleSigint(sig: c_int) callconv(.c) void {
    _ = sig;
    // Kill our entire process group (negative pid = process group).
    const pid = std.c.getpid();
    _ = std.c.kill(-pid, std.posix.SIG.TERM);
    std.process.exit(130); // 128 + SIGINT
}

fn installSignalHandlers() void {
    // Put ourselves in our own process group so kill(-pid) in handleSigint
    // reaches every child we spawn.
    _ = std.c.setpgid(0, 0);

    var sa_alarm = std.posix.Sigaction{
        .handler = .{ .handler = handleAlarm },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.ALRM, &sa_alarm, null);

    var sa_int = std.posix.Sigaction{
        .handler = .{ .handler = handleSigint },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &sa_int, null);
}

// ── Watchdog helpers ───────────────────────────────────────────────────────

fn armWatchdog(name: []const u8) void {
    current_test_name = name;
    _ = std.c.alarm(PER_TEST_TIMEOUT_SECS);
}

fn disarmWatchdog() void {
    _ = std.c.alarm(0);
    current_test_name = "<unknown>";
}

// ── Entry point ────────────────────────────────────────────────────────────

pub fn main() void {
    @disableInstrumentation();

    installSignalHandlers();

    const args = std.process.argsAlloc(fba.allocator()) catch
        @panic("unable to parse command line args");

    var listen = false;
    var opt_cache_dir: ?[]const u8 = null;

    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--listen=-")) {
            listen = true;
        } else if (std.mem.startsWith(u8, arg, "--seed=")) {
            testing.random_seed = std.fmt.parseUnsigned(u32, arg["--seed=".len..], 0) catch
                @panic("unable to parse --seed command line argument");
        } else if (std.mem.startsWith(u8, arg, "--cache-dir")) {
            opt_cache_dir = arg["--cache-dir=".len..];
        } else {
            @panic("unrecognized command line argument");
        }
    }

    fba.reset();

    if (listen) {
        return mainServer(opt_cache_dir) catch @panic("internal test runner failure");
    } else {
        return mainTerminal();
    }
}

// ── Server mode (used by `zig build test`) ─────────────────────────────────

fn mainServer(opt_cache_dir: ?[]const u8) !void {
    @disableInstrumentation();
    _ = opt_cache_dir;
    var stdin_reader = std.fs.File.stdin().readerStreaming(&stdin_buffer);
    var stdout_writer = std.fs.File.stdout().writerStreaming(&stdout_buffer);
    var server = try std.zig.Server.init(.{
        .in = &stdin_reader.interface,
        .out = &stdout_writer.interface,
        .zig_version = builtin.zig_version_string,
    });

    while (true) {
        const hdr = try server.receiveMessage();
        switch (hdr.tag) {
            .exit => return std.process.exit(0),

            .query_test_metadata => {
                testing.allocator_instance = .{};
                defer if (testing.allocator_instance.deinit() == .leak) {
                    @panic("internal test runner memory leak");
                };

                var string_bytes: std.ArrayListUnmanaged(u8) = .empty;
                defer string_bytes.deinit(testing.allocator);
                try string_bytes.append(testing.allocator, 0);

                const test_fns = builtin.test_functions;
                const names = try testing.allocator.alloc(u32, test_fns.len);
                defer testing.allocator.free(names);
                const expected_panic_msgs = try testing.allocator.alloc(u32, test_fns.len);
                defer testing.allocator.free(expected_panic_msgs);

                for (test_fns, names, expected_panic_msgs) |test_fn, *name, *expected_panic_msg| {
                    name.* = @intCast(string_bytes.items.len);
                    try string_bytes.ensureUnusedCapacity(testing.allocator, test_fn.name.len + 1);
                    string_bytes.appendSliceAssumeCapacity(test_fn.name);
                    string_bytes.appendAssumeCapacity(0);
                    expected_panic_msg.* = 0;
                }

                try server.serveTestMetadata(.{
                    .names = names,
                    .expected_panic_msgs = expected_panic_msgs,
                    .string_bytes = string_bytes.items,
                });
            },

            .run_test => {
                testing.allocator_instance = .{};
                log_err_count = 0;
                const index = try server.receiveBody_u32();
                const test_fn = builtin.test_functions[index];
                var fail = false;
                var skip = false;

                armWatchdog(test_fn.name);
                test_fn.func() catch |err| switch (err) {
                    error.SkipZigTest => skip = true,
                    else => {
                        fail = true;
                        if (@errorReturnTrace()) |trace| {
                            std.debug.dumpStackTrace(trace.*);
                        }
                    },
                };
                disarmWatchdog();

                const leak = testing.allocator_instance.deinit() == .leak;
                try server.serveTestResults(.{
                    .index = index,
                    .flags = .{
                        .fail = fail,
                        .skip = skip,
                        .leak = leak,
                        .fuzz = false,
                        .log_err_count = std.math.lossyCast(
                            @FieldType(std.zig.Server.Message.TestResults.Flags, "log_err_count"),
                            log_err_count,
                        ),
                    },
                });
            },

            else => {
                std.debug.print("unsupported message: {x}\n", .{@intFromEnum(hdr.tag)});
                std.process.exit(1);
            },
        }
    }
}

// ── Terminal mode (standalone binary, no build system) ─────────────────────

fn mainTerminal() void {
    @disableInstrumentation();
    const test_fn_list = builtin.test_functions;
    var ok_count: usize = 0;
    var skip_count: usize = 0;
    var fail_count: usize = 0;

    for (test_fn_list, 0..) |test_fn, i| {
        std.debug.print("{d}/{d} {s}...", .{ i + 1, test_fn_list.len, test_fn.name });
        testing.allocator_instance = .{};
        log_err_count = 0;

        armWatchdog(test_fn.name);
        const result = test_fn.func();
        disarmWatchdog();

        if (testing.allocator_instance.deinit() == .leak) {
            std.debug.print("FAIL (memory leak)\n", .{});
            fail_count += 1;
            continue;
        }
        result catch |err| switch (err) {
            error.SkipZigTest => {
                std.debug.print("SKIP\n", .{});
                skip_count += 1;
                continue;
            },
            else => {
                std.debug.print("FAIL ({s})\n", .{@errorName(err)});
                fail_count += 1;
                continue;
            },
        };
        std.debug.print("OK\n", .{});
        ok_count += 1;
    }

    if (fail_count > 0) {
        std.debug.print("{d} passed; {d} skipped; {d} failed.\n", .{ ok_count, skip_count, fail_count });
        std.process.exit(1);
    } else {
        std.debug.print("{d} passed; {d} skipped.\n", .{ ok_count, skip_count });
    }
}

// ── Logging ────────────────────────────────────────────────────────────────

fn log(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    _ = scope;
    if (@intFromEnum(level) <= @intFromEnum(std.log.Level.err)) {
        log_err_count += 1;
    }
    const prefix = "[" ++ @tagName(level) ++ "] ";
    std.debug.print(prefix ++ format ++ "\n", args);
}
