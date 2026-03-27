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
// Ported in part from tmux/job.c.
// Original copyright:
//   Copyright (c) 2009 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

//! job.zig – reduced shared async job registry and summary helpers.

const std = @import("std");
const c = @import("c.zig");
const proc_mod = @import("proc.zig");
const xm = @import("xmalloc.zig");

pub const JOB_NOWAIT: u32 = 0x1;

const JobState = enum {
    running,
    dead,
    closed,
};

pub const Job = struct {
    cmd: []u8,
    pid: i32 = -1,
    fd: i32 = -1,
    status: i32 = 0,
    flags: u32 = 0,
    state: JobState = .running,
};

pub const ShellRunOptions = struct {
    cwd: []const u8,
    merge_stderr: bool = false,
    capture_output: bool = false,
};

pub const ShellRunResult = struct {
    output: std.ArrayList(u8) = .{},
    retcode: i32 = 1,
    signal_code: ?u32 = null,
    spawn_failed: bool = false,

    pub fn deinit(self: *ShellRunResult) void {
        self.output.deinit(xm.allocator);
    }
};

pub const AsyncShellCallback = *const fn (*AsyncShell, ?*anyopaque) void;

pub const AsyncShell = struct {
    job: ?*Job = null,
    shell_command: []u8,
    cwd: []u8,
    merge_stderr: bool = false,
    capture_output: bool = false,
    pipe_read: std.posix.fd_t = -1,
    pipe_write: std.posix.fd_t = -1,
    output_fd: std.posix.fd_t = -1,
    child_pid: i32 = -1,
    event: ?*c.libevent.event = null,
    thread: ?std.Thread = null,
    callback: AsyncShellCallback,
    callback_arg: ?*anyopaque = null,
    result: ShellRunResult = .{},
    output_done: bool = false,
    status_known: bool = false,
    completion_sent: bool = false,
    server_reaper: bool = false,
    lock: std.Thread.Mutex = .{},
};

var jobs: std.ArrayListUnmanaged(*Job) = .{};
var jobs_lock: std.Thread.Mutex = .{};
var async_shells: std.ArrayListUnmanaged(*AsyncShell) = .{};
var async_shells_lock: std.Thread.Mutex = .{};
var server_reaper_enabled = false;

pub fn job_enable_server_reaper(enabled: bool) void {
    server_reaper_enabled = enabled;
}

pub fn async_shell_start(
    job: ?*Job,
    shell_command: []const u8,
    options: ShellRunOptions,
    callback: AsyncShellCallback,
    callback_arg: ?*anyopaque,
) ?*AsyncShell {
    const base = proc_mod.libevent orelse return null;
    const async = xm.allocator.create(AsyncShell) catch unreachable;
    async.* = .{
        .job = job,
        .shell_command = xm.xstrdup(shell_command),
        .cwd = xm.xstrdup(options.cwd),
        .merge_stderr = options.merge_stderr,
        .capture_output = options.capture_output,
        .callback = callback,
        .callback_arg = callback_arg,
    };
    errdefer async_shell_free(async);

    const pipe_fds = std.posix.pipe() catch return null;
    async.pipe_read = pipe_fds[0];
    async.pipe_write = pipe_fds[1];

    async.event = c.libevent.event_new(
        base,
        async.pipe_read,
        @intCast(c.libevent.EV_READ),
        async_shell_event_cb,
        async,
    );
    if (async.event == null) return null;
    if (c.libevent.event_add(async.event.?, null) != 0) return null;

    if (server_reaper_enabled) {
        if (!async_shell_start_server_reaper(async)) return null;
        return async;
    }

    async.thread = std.Thread.spawn(.{}, asyncShellThreadMain, .{async}) catch return null;
    return async;
}

pub fn async_shell_free(async: *AsyncShell) void {
    if (async.server_reaper)
        async_shell_unregister(async);
    if (async.thread) |thread| thread.join();
    if (async.event) |ev| {
        _ = c.libevent.event_del(ev);
        c.libevent.event_free(ev);
    }
    if (async.pipe_read >= 0) std.posix.close(async.pipe_read);
    if (async.pipe_write >= 0) std.posix.close(async.pipe_write);
    if (async.output_fd >= 0) std.posix.close(async.output_fd);
    async.result.deinit();
    xm.allocator.free(async.shell_command);
    xm.allocator.free(async.cwd);
    xm.allocator.destroy(async);
}

fn asyncShellThreadMain(async: *AsyncShell) void {
    defer asyncShellNotifyComplete(async);

    var result = job_run_shell_command(async.job, async.shell_command, .{
        .cwd = async.cwd,
        .merge_stderr = async.merge_stderr,
        .capture_output = async.capture_output,
    });
    async.result = result;
    result.output = .{};
}

fn asyncShellNotifyComplete(async: *AsyncShell) void {
    if (async.pipe_write < 0) return;
    _ = std.posix.write(async.pipe_write, &[1]u8{1}) catch {};
    std.posix.close(async.pipe_write);
    async.pipe_write = -1;
}

const SpawnedShell = struct {
    pid: i32,
    stdout_fd: i32 = -1,
};

fn spawnShellProcess(shell_command: []const u8, options: ShellRunOptions) !SpawnedShell {
    const command_to_run = if (options.merge_stderr)
        xm.xasprintf("exec 2>&1; {s}", .{shell_command})
    else
        xm.xstrdup(shell_command);
    defer xm.allocator.free(command_to_run);

    var child = std.process.Child.init(&.{ "/bin/sh", "-c", command_to_run }, xm.allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = if (options.capture_output) .Pipe else .Ignore;
    child.stderr_behavior = .Ignore;
    child.cwd = options.cwd;

    try child.spawn();
    return .{
        .pid = @intCast(child.id),
        .stdout_fd = if (options.capture_output) child.stdout.?.handle else -1,
    };
}

fn async_shell_register(async: *AsyncShell) void {
    async_shells_lock.lock();
    defer async_shells_lock.unlock();
    async_shells.append(xm.allocator, async) catch unreachable;
}

fn async_shell_unregister(async: *AsyncShell) void {
    async_shells_lock.lock();
    defer async_shells_lock.unlock();

    for (async_shells.items, 0..) |candidate, idx| {
        if (candidate != async) continue;
        _ = async_shells.swapRemove(idx);
        break;
    }
}

fn async_shell_take_by_pid(pid: i32) ?*AsyncShell {
    async_shells_lock.lock();
    defer async_shells_lock.unlock();

    for (async_shells.items, 0..) |async, idx| {
        if (async.child_pid != pid) continue;
        _ = async_shells.swapRemove(idx);
        return async;
    }
    return null;
}

fn async_shell_start_server_reaper(async: *AsyncShell) bool {
    const spawned = spawnShellProcess(async.shell_command, .{
        .cwd = async.cwd,
        .merge_stderr = async.merge_stderr,
        .capture_output = async.capture_output,
    }) catch {
        if (async.job) |job| job_finished(job, 1);
        return false;
    };

    async.server_reaper = true;
    async.child_pid = spawned.pid;
    async.output_fd = spawned.stdout_fd;

    if (async.job) |job|
        job_started(job, spawned.pid, spawned.stdout_fd);

    async_shell_register(async);

    if (!async.capture_output) {
        async.lock.lock();
        async.output_done = true;
        async.lock.unlock();
        return true;
    }

    async.thread = std.Thread.spawn(.{}, asyncShellReadThreadMain, .{async}) catch {
        async_shell_unregister(async);
        if (async.output_fd >= 0) {
            std.posix.close(async.output_fd);
            async.output_fd = -1;
        }
        _ = std.c.kill(async.child_pid, std.posix.SIG.TERM);
        var raw_status: i32 = 0;
        _ = std.c.waitpid(async.child_pid, &raw_status, 0);
        if (async.job) |job| {
            job_output_closed(job);
            job_finished(job, 1);
        }
        async.child_pid = -1;
        return false;
    };
    return true;
}

fn asyncShellReadThreadMain(async: *AsyncShell) void {
    var buf: [4096]u8 = undefined;
    while (async.output_fd >= 0) {
        const amt = std.posix.read(async.output_fd, &buf) catch break;
        if (amt == 0) break;
        async.result.output.appendSlice(xm.allocator, buf[0..amt]) catch unreachable;
    }

    if (async.output_fd >= 0) {
        std.posix.close(async.output_fd);
        async.output_fd = -1;
    }
    if (async.job) |job|
        job_output_closed(job);

    async.lock.lock();
    async.output_done = true;
    const should_notify = async.status_known and !async.completion_sent;
    if (should_notify) async.completion_sent = true;
    async.lock.unlock();

    if (should_notify)
        asyncShellNotifyComplete(async);
}

fn job_output_closed(job: *Job) void {
    jobs_lock.lock();
    defer jobs_lock.unlock();

    job.fd = -1;
    if (job.state == .running)
        job.state = .closed;
}

fn rawWaitStatusToExit(status_raw: i32) struct {
    retcode: i32,
    signal_code: ?u32,
} {
    const status: u32 = @bitCast(status_raw);
    return if (std.posix.W.IFEXITED(status))
        .{ .retcode = std.posix.W.EXITSTATUS(status), .signal_code = null }
    else if (std.posix.W.IFSIGNALED(status))
        .{
            .retcode = @as(i32, @intCast(std.posix.W.TERMSIG(status))) + 128,
            .signal_code = std.posix.W.TERMSIG(status),
        }
    else
        .{ .retcode = 1, .signal_code = null };
}

pub fn job_check_died(pid: i32, status_raw: i32) void {
    const status = @as(u32, @bitCast(status_raw));
    if (std.posix.W.IFSTOPPED(status)) {
        const sig = std.posix.W.STOPSIG(status);
        if (sig == std.posix.SIG.TTIN or sig == std.posix.SIG.TTOU)
            return;
        _ = std.c.kill(pid, std.posix.SIG.CONT);
        return;
    }

    const exit_status = rawWaitStatusToExit(status_raw);

    if (async_shell_take_by_pid(pid)) |async| {
        if (async.job) |job|
            job_finished(job, exit_status.retcode);

        async.lock.lock();
        async.result.retcode = exit_status.retcode;
        async.result.signal_code = exit_status.signal_code;
        async.status_known = true;
        const should_notify = async.output_done and !async.completion_sent;
        if (should_notify) async.completion_sent = true;
        async.lock.unlock();

        if (should_notify)
            asyncShellNotifyComplete(async);
        return;
    }

    jobs_lock.lock();
    defer jobs_lock.unlock();
    for (jobs.items) |job| {
        if (job.pid != pid) continue;
        job.status = exit_status.retcode;
        if (job.state == .running)
            job.state = .dead;
        return;
    }
}

export fn async_shell_event_cb(fd: c_int, _events: c_short, arg: ?*anyopaque) void {
    _ = _events;
    const async: *AsyncShell = @ptrCast(@alignCast(arg orelse return));

    var discard: [16]u8 = undefined;
    _ = std.posix.read(fd, &discard) catch {};

    if (async.event) |ev| {
        _ = c.libevent.event_del(ev);
        c.libevent.event_free(ev);
        async.event = null;
    }
    if (async.pipe_read >= 0) {
        std.posix.close(async.pipe_read);
        async.pipe_read = -1;
    }

    async.callback(async, async.callback_arg);
}

pub fn job_register(cmd: []const u8, flags: u32) *Job {
    const job = xm.allocator.create(Job) catch unreachable;
    job.* = .{
        .cmd = xm.xstrdup(cmd),
        .flags = flags,
    };

    jobs_lock.lock();
    defer jobs_lock.unlock();
    jobs.append(xm.allocator, job) catch unreachable;
    return job;
}

pub fn job_started(job: *Job, pid: i32, fd: i32) void {
    jobs_lock.lock();
    defer jobs_lock.unlock();
    job.pid = pid;
    job.fd = fd;
    job.state = .running;
}

pub fn job_finished(job: *Job, status: i32) void {
    jobs_lock.lock();
    defer jobs_lock.unlock();
    job.status = status;
    job.state = .dead;
}

pub fn job_closed(job: *Job) void {
    jobs_lock.lock();
    defer jobs_lock.unlock();
    job.state = .closed;
}

fn shellExitStatus(term: std.process.Child.Term) struct {
    retcode: i32,
    signal_code: ?u32,
} {
    return switch (term) {
        .Exited => |code| .{ .retcode = code, .signal_code = null },
        .Signal => |signal_code| .{
            .retcode = @as(i32, @intCast(signal_code)) + 128,
            .signal_code = signal_code,
        },
        else => .{ .retcode = 1, .signal_code = null },
    };
}

pub fn job_run_shell_command(job: ?*Job, shell_command: []const u8, options: ShellRunOptions) ShellRunResult {
    var result = ShellRunResult{};

    const command_to_run = if (options.merge_stderr)
        xm.xasprintf("exec 2>&1; {s}", .{shell_command})
    else
        xm.xstrdup(shell_command);
    defer xm.allocator.free(command_to_run);

    var child = std.process.Child.init(&.{ "/bin/sh", "-c", command_to_run }, xm.allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = if (options.capture_output) .Pipe else .Ignore;
    child.stderr_behavior = .Ignore;
    child.cwd = options.cwd;

    child.spawn() catch {
        result.spawn_failed = true;
        if (job) |registered| job_finished(registered, 1);
        return result;
    };

    const stdout_fd = if (options.capture_output) fd: {
        const stdout_pipe = child.stdout orelse {
            result.spawn_failed = true;
            if (job) |registered| job_finished(registered, 1);
            _ = child.wait() catch {};
            return result;
        };
        break :fd stdout_pipe.handle;
    } else -1;

    if (job) |registered| job_started(registered, @intCast(child.id), stdout_fd);

    if (options.capture_output) {
        const stdout_pipe = child.stdout.?;
        var buf: [4096]u8 = undefined;
        while (true) {
            const amt = stdout_pipe.read(&buf) catch {
                result.spawn_failed = true;
                if (job) |registered| job_finished(registered, 1);
                _ = child.wait() catch {};
                return result;
            };
            if (amt == 0) break;
            result.output.appendSlice(xm.allocator, buf[0..amt]) catch unreachable;
        }
    }

    const term = child.wait() catch {
        result.spawn_failed = true;
        if (job) |registered| job_finished(registered, 1);
        return result;
    };
    const status = shellExitStatus(term);
    result.retcode = status.retcode;
    result.signal_code = status.signal_code;

    if (job) |registered| job_finished(registered, result.retcode);
    return result;
}

pub fn job_still_running() bool {
    jobs_lock.lock();
    defer jobs_lock.unlock();

    for (jobs.items) |job| {
        if ((job.flags & JOB_NOWAIT) == 0 and job.state == .running)
            return true;
    }
    return false;
}

pub fn job_render_summary(alloc: std.mem.Allocator) []u8 {
    var out: std.ArrayList(u8) = .{};
    errdefer out.deinit(alloc);

    jobs_lock.lock();
    defer jobs_lock.unlock();

    for (jobs.items, 0..) |job, idx| {
        if (idx != 0) out.append(alloc, '\n') catch unreachable;
        out.writer(alloc).print(
            "Job {d}: {s} [fd={d}, pid={d}, status={d}]",
            .{ idx, job.cmd, job.fd, job.pid, job.status },
        ) catch unreachable;
    }
    return out.toOwnedSlice(alloc) catch unreachable;
}

pub fn job_free(job: *Job) void {
    jobs_lock.lock();
    defer jobs_lock.unlock();

    for (jobs.items, 0..) |candidate, idx| {
        if (candidate != job) continue;
        _ = jobs.swapRemove(idx);
        break;
    }

    if (job.pid != -1 and job.state == .running) {
        _ = std.c.kill(job.pid, std.posix.SIG.TERM);
    }
    if (job.fd != -1) {
        _ = std.c.close(job.fd);
        job.fd = -1;
    }

    xm.allocator.free(job.cmd);
    xm.allocator.destroy(job);
}

pub fn job_kill_all() void {
    jobs_lock.lock();
    defer jobs_lock.unlock();

    for (jobs.items) |job| {
        if (job.pid != -1 and job.state == .running)
            _ = std.c.kill(job.pid, std.posix.SIG.TERM);
    }
}

pub fn job_reset_all() void {
    jobs_lock.lock();
    defer jobs_lock.unlock();

    for (jobs.items) |job| {
        xm.allocator.free(job.cmd);
        xm.allocator.destroy(job);
    }
    jobs.clearRetainingCapacity();
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

fn testAsyncComplete(async_shell: *AsyncShell, arg: ?*anyopaque) void {
    _ = async_shell;
    const done: *bool = @ptrCast(@alignCast(arg orelse return));
    done.* = true;
}

test "job registry renders reduced tmux-style summaries" {
    defer job_reset_all();

    const first = job_register("sleep 1", 0);
    job_started(first, 41, 7);
    job_finished(first, 0);

    const second = job_register("echo ready", JOB_NOWAIT);
    job_started(second, 42, -1);

    const rendered = job_render_summary(std.testing.allocator);
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings(
        "Job 0: sleep 1 [fd=7, pid=41, status=0]\n" ++
            "Job 1: echo ready [fd=-1, pid=42, status=0]",
        rendered,
    );
    try std.testing.expect(!job_still_running());

    job_free(first);
    job_free(second);
}

test "job shared shell runner captures stdout and merged stderr" {
    defer job_reset_all();

    const job = job_register("printf 'out'; printf 'err' >&2", 0);
    defer job_free(job);

    var result = job_run_shell_command(job, "printf 'out'; printf 'err' >&2", .{
        .cwd = "/",
        .merge_stderr = true,
        .capture_output = true,
    });
    defer result.deinit();

    try std.testing.expect(!result.spawn_failed);
    try std.testing.expectEqual(@as(i32, 0), result.retcode);
    try std.testing.expectEqualStrings("outerr", result.output.items);
}

test "job_free terminates a live shared job process" {
    defer job_reset_all();

    var child = std.process.Child.init(&.{ "/bin/sh", "-c", "exec sleep 30" }, std.testing.allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    try child.spawn();

    const job = job_register("sleep 30", 0);
    job_started(job, @intCast(child.id), -1);
    job_free(job);

    const term = try child.wait();
    switch (term) {
        .Signal => |signal_code| try std.testing.expectEqual(std.posix.SIG.TERM, signal_code),
        else => return error.TestUnexpectedResult,
    }
}

test "job_kill_all terminates all live shared job processes" {
    defer job_reset_all();

    var first_child = std.process.Child.init(&.{ "/bin/sh", "-c", "exec sleep 30" }, std.testing.allocator);
    first_child.stdin_behavior = .Ignore;
    first_child.stdout_behavior = .Ignore;
    first_child.stderr_behavior = .Ignore;
    try first_child.spawn();

    var second_child = std.process.Child.init(&.{ "/bin/sh", "-c", "exec sleep 30" }, std.testing.allocator);
    second_child.stdin_behavior = .Ignore;
    second_child.stdout_behavior = .Ignore;
    second_child.stderr_behavior = .Ignore;
    try second_child.spawn();

    const first = job_register("sleep 30", 0);
    const second = job_register("sleep 30", JOB_NOWAIT);
    job_started(first, @intCast(first_child.id), -1);
    job_started(second, @intCast(second_child.id), -1);

    job_kill_all();

    const first_term = try first_child.wait();
    const second_term = try second_child.wait();

    switch (first_term) {
        .Signal => |signal_code| try std.testing.expectEqual(std.posix.SIG.TERM, signal_code),
        else => return error.TestUnexpectedResult,
    }
    switch (second_term) {
        .Signal => |signal_code| try std.testing.expectEqual(std.posix.SIG.TERM, signal_code),
        else => return error.TestUnexpectedResult,
    }
}

test "job server reaper async shell captures output and completion" {
    const old_base = installEventBase();
    defer restoreEventBase(old_base);
    job_enable_server_reaper(true);
    defer job_enable_server_reaper(false);
    defer job_reset_all();

    var completed = false;
    const job = job_register("printf 'out'; printf 'err' >&2", 0);
    defer job_free(job);

    const async = async_shell_start(job, "printf 'out'; printf 'err' >&2", .{
        .cwd = "/",
        .merge_stderr = true,
        .capture_output = true,
    }, testAsyncComplete, &completed) orelse return error.TestUnexpectedResult;
    defer async_shell_free(async);

    var raw_status: i32 = 0;
    const waited = std.c.waitpid(job.pid, &raw_status, 0);
    try std.testing.expectEqual(job.pid, waited);
    job_check_died(@intCast(waited), raw_status);

    var spins: usize = 0;
    while (!completed and spins < 200) : (spins += 1) {
        _ = c.libevent.event_loop(c.libevent.EVLOOP_NONBLOCK);
        std.Thread.sleep(5 * std.time.ns_per_ms);
    }

    try std.testing.expect(completed);
    try std.testing.expectEqual(@as(i32, 0), async.result.retcode);
    try std.testing.expectEqualStrings("outerr", async.result.output.items);
}
