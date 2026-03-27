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

    xm.allocator.free(job.cmd);
    xm.allocator.destroy(job);
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
