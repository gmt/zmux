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

var jobs: std.ArrayListUnmanaged(*Job) = .{};
var jobs_lock: std.Thread.Mutex = .{};

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
