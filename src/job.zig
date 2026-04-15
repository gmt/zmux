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

//! job.zig – shared async job registry, libevent-integrated job runtime,
//! and summary helpers.
//!
//! Two execution paths coexist:
//!
//! 1. **AsyncShell** – thread/pipe bridge for simple command execution
//!    (used by `cmd-run-shell`, `cmd-if-shell`, etc.).  This path is
//!    unchanged from before.
//!
//! 2. **job_run** – libevent bufferevent-backed runtime that mirrors
//!    tmux's `job_run()`.  The job's output fd is registered with the
//!    event loop so data streams incrementally via `job_read_callback`.
//!    PTY-backed jobs support resize via `job_resize()`.

const std = @import("std");
const c = @import("c.zig");
const env_mod = @import("environ.zig");
const opts = @import("options.zig");
const proc_mod = @import("proc.zig");
const xm = @import("xmalloc.zig");

// ── Job flags (matches tmux JOB_* constants) ─────────────────────────────

pub const JOB_NOWAIT: u32 = 0x1;
pub const JOB_KEEPWRITE: u32 = 0x2;
pub const JOB_PTY: u32 = 0x4;
pub const JOB_DEFAULTSHELL: u32 = 0x8;
pub const JOB_SHOWSTDERR: u32 = 0x10;

// ── Callback types (match tmux typedefs) ─────────────────────────────────

pub const JobUpdateCb = *const fn (*Job) void;
pub const JobCompleteCb = *const fn (*Job) void;
pub const JobFreeCb = *const fn (?*anyopaque) void;

// ── TTY name buffer size ─────────────────────────────────────────────────

const TTY_NAME_MAX = 256;

// ── Job states ───────────────────────────────────────────────────────────

const JobState = enum {
    running,
    dead,
    closed,
};

// ── Job struct ───────────────────────────────────────────────────────────

pub const Job = struct {
    cmd: []u8,
    pid: i32 = -1,
    fd: i32 = -1,
    status: i32 = 0,
    flags: u32 = 0,
    state: JobState = .running,
    tty: [TTY_NAME_MAX]u8 = std.mem.zeroes([TTY_NAME_MAX]u8),

    /// libevent bufferevent for streaming I/O (null for AsyncShell jobs).
    event: ?*c.libevent.bufferevent = null,

    /// Called when data is available on the job's output fd.
    updatecb: ?JobUpdateCb = null,
    /// Called when the job completes (both fd closed and process exited).
    completecb: ?JobCompleteCb = null,
    /// Called to free the opaque `data` pointer when the job is freed.
    freecb: ?JobFreeCb = null,
    /// Opaque data pointer passed to callbacks.
    data: ?*anyopaque = null,
};

// ── Existing AsyncShell types (unchanged) ────────────────────────────────

pub const ShellRunOptions = struct {
    cwd: []const u8,
    merge_stderr: bool = false,
    capture_output: bool = false,
    env_map: ?*const std.process.EnvMap = null,
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

// ── Global state ─────────────────────────────────────────────────────────

var jobs: std.ArrayListUnmanaged(*Job) = .{};
var jobs_lock: std.Thread.Mutex = .{};
var async_shells: std.ArrayListUnmanaged(*AsyncShell) = .{};
var async_shells_lock: std.Thread.Mutex = .{};
var server_reaper_enabled = false;

pub fn job_enable_server_reaper(enabled: bool) void {
    server_reaper_enabled = enabled;
}

// ── C externs for fork/exec/pty ──────────────────────────────────────────

extern fn openpty(
    amaster: *c_int,
    aslave: *c_int,
    name: ?[*]u8,
    termp: ?*anyopaque,
    winp: ?*c.posix_sys.struct_winsize,
) c_int;

extern fn setsid() c_int;
extern fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

// ── job_run – libevent-integrated job runtime ────────────────────────────

/// Run a job with output streaming via the libevent loop.
///
/// This is the Zig port of tmux's `job_run()`.  For PTY jobs
/// (`JOB_PTY`), a pseudoterminal is allocated with the given size.
/// For pipe jobs, a `socketpair` is used.  In both cases, the parent's
/// end of the fd is registered as a libevent bufferevent so output
/// streams incrementally through `job_read_callback`.
pub fn job_run(
    cmd: []const u8,
    cwd: ?[]const u8,
    env_map: ?*const std.process.EnvMap,
    updatecb: ?JobUpdateCb,
    completecb: ?JobCompleteCb,
    freecb: ?JobFreeCb,
    data: ?*anyopaque,
    flags: u32,
    sx: u32,
    sy: u32,
) ?*Job {
    const base = proc_mod.libevent orelse return null;

    var tty_buf: [TTY_NAME_MAX]u8 = std.mem.zeroes([TTY_NAME_MAX]u8);
    var parent_fd: c_int = -1;
    var pid_raw: std.posix.pid_t = undefined;

    if (flags & JOB_PTY != 0) {
        var ws = std.mem.zeroes(c.posix_sys.struct_winsize);
        ws.ws_col = @intCast(sx);
        ws.ws_row = @intCast(sy);
        var master: c_int = -1;
        var slave: c_int = undefined;
        if (openpty(&master, &slave, &tty_buf, null, &ws) != 0)
            return null;
        pid_raw = std.posix.fork() catch {
            std.posix.close(@intCast(master));
            std.posix.close(@intCast(slave));
            return null;
        };
        if (pid_raw == 0) {
            std.posix.close(@intCast(master));
            _ = setsid();
            _ = std.c.ioctl(slave, 0x540e, @as(c_int, 0)); // TIOCSCTTY
            _ = std.c.dup2(slave, 0);
            _ = std.c.dup2(slave, 1);
            _ = std.c.dup2(slave, 2);
            if (slave > 2) std.posix.close(@intCast(slave));
            job_run_child(cmd, cwd, env_map, flags);
        }
        std.posix.close(@intCast(slave));
        parent_fd = master;
    } else {
        var out: [2]c_int = .{ -1, -1 };
        if (std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &out) != 0)
            return null;
        pid_raw = std.posix.fork() catch {
            std.posix.close(@intCast(out[0]));
            std.posix.close(@intCast(out[1]));
            return null;
        };
        if (pid_raw == 0) {
            std.posix.close(@intCast(out[0]));
            _ = std.c.dup2(out[1], 0);
            _ = std.c.dup2(out[1], 1);
            if (flags & JOB_SHOWSTDERR != 0) {
                _ = std.c.dup2(out[1], 2);
            } else {
                const devnull = std.c.open("/dev/null", .{ .ACCMODE = .RDWR }, @as(std.c.mode_t, 0));
                if (devnull >= 0) {
                    _ = std.c.dup2(devnull, 2);
                    if (devnull > 2) std.posix.close(@intCast(devnull));
                }
            }
            if (out[1] > 2) std.posix.close(@intCast(out[1]));
            job_run_child(cmd, cwd, env_map, flags);
        }
        std.posix.close(@intCast(out[1]));
        parent_fd = out[0];
    }

    const job = job_alloc(cmd, flags, @intCast(pid_raw), @intCast(parent_fd), tty_buf);
    job.updatecb = updatecb;
    job.completecb = completecb;
    job.freecb = freecb;
    job.data = data;
    job_setup_bufferevent(job, base) orelse {
        job_free(job);
        return null;
    };
    return job;
}

/// Child-side exec (called after fork, never returns).
fn job_run_child(cmd: []const u8, cwd: ?[]const u8, env_map: ?*const std.process.EnvMap, flags: u32) noreturn {
    // Reset signals to defaults
    const sa_dfl = std.posix.Sigaction{
        .handler = .{ .handler = std.posix.SIG.DFL },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    const reset_sigs: []const u8 = &.{
        std.posix.SIG.INT,   std.posix.SIG.HUP,  std.posix.SIG.CHLD,
        std.posix.SIG.CONT,  std.posix.SIG.TERM, std.posix.SIG.PIPE,
        std.posix.SIG.TSTP,  std.posix.SIG.TTIN, std.posix.SIG.TTOU,
        std.posix.SIG.QUIT,  std.posix.SIG.USR1, std.posix.SIG.USR2,
        std.posix.SIG.WINCH,
    };
    for (reset_sigs) |sig| std.posix.sigaction(sig, &sa_dfl, null);

    // Unmask all signals
    var full_set = std.posix.sigfillset();
    _ = std.c.sigprocmask(std.posix.SIG.UNBLOCK, &full_set, null);

    // Change working directory
    if (cwd) |dir| {
        const dir_z = xm.allocator.dupeZ(u8, dir) catch "/";
        _ = std.c.chdir(dir_z);
    }

    // Close fds > stderr
    closefrom(3);

    // Determine shell
    const shell: [*:0]const u8 = if (flags & JOB_DEFAULTSHELL != 0) blk: {
        const opt = opts.options_get_string(opts.global_s_options, "default-shell");
        if (opt.len > 0)
            break :blk xm.allocator.dupeZ(u8, opt) catch "/bin/sh"
        else
            break :blk "/bin/sh";
    } else "/bin/sh";

    if (flags & JOB_DEFAULTSHELL != 0)
        _ = setenv("SHELL", shell, 1);

    if (env_map) |map| {
        var it = map.iterator();
        while (it.next()) |entry| {
            const name = xm.allocator.dupeZ(u8, entry.key_ptr.*) catch continue;
            const value = xm.allocator.dupeZ(u8, entry.value_ptr.*) catch continue;
            _ = setenv(name, value, 1);
        }
    }

    const cmd_z = xm.allocator.dupeZ(u8, cmd) catch {
        std.c._exit(1);
    };
    _ = std.c.execve(shell, &[_:null]?[*:0]const u8{ shell, "-c", cmd_z, null }, std.c.environ);
    std.c._exit(1);
}

fn closefrom(lowfd: c_int) void {
    // Best-effort: close fds from lowfd up to some reasonable limit
    var fd = lowfd;
    while (fd < 1024) : (fd += 1) {
        _ = std.c.close(fd);
    }
}

fn set_nonblocking(fd: i32) void {
    const flags = std.c.fcntl(fd, std.posix.F.GETFL, @as(c_int, 0));
    if (flags < 0) return;
    const O_NONBLOCK: c_int = 0x800;
    _ = std.c.fcntl(fd, std.posix.F.SETFL, flags | O_NONBLOCK);
}

fn job_alloc(cmd: []const u8, flags: u32, pid: i32, fd: i32, tty_buf: [TTY_NAME_MAX]u8) *Job {
    const job = xm.allocator.create(Job) catch unreachable;
    job.* = .{
        .cmd = xm.xstrdup(cmd),
        .flags = flags,
        .pid = pid,
        .fd = fd,
        .tty = tty_buf,
    };
    jobs_lock.lock();
    defer jobs_lock.unlock();
    jobs.append(xm.allocator, job) catch unreachable;
    return job;
}

fn job_setup_bufferevent(job: *Job, base: *c.libevent.event_base) ?void {
    set_nonblocking(job.fd);
    job.event = c.libevent.bufferevent_socket_new(base, job.fd, 0);
    if (job.event == null) return null;
    c.libevent.bufferevent_setcb(
        job.event.?,
        job_read_callback,
        job_write_callback,
        job_error_callback,
        job,
    );
    _ = c.libevent.bufferevent_enable(job.event.?, c.libevent.EV_READ | c.libevent.EV_WRITE);
}

// ── Bufferevent callbacks (match tmux job.c) ─────────────────────────────

export fn job_read_callback(_bufev: ?*c.libevent.bufferevent, arg: ?*anyopaque) void {
    _ = _bufev;
    const job: *Job = @ptrCast(@alignCast(arg orelse return));
    if (job.updatecb) |cb| cb(job);
}

export fn job_write_callback(bufev: ?*c.libevent.bufferevent, arg: ?*anyopaque) void {
    const job: *Job = @ptrCast(@alignCast(arg orelse return));
    const bev = bufev orelse return;

    const output = c.libevent.bufferevent_get_output(bev);
    const len = if (output != null) c.libevent.evbuffer_get_length(output) else 0;

    if (len == 0 and (job.flags & JOB_KEEPWRITE == 0)) {
        _ = std.c.shutdown(job.fd, std.posix.SHUT.WR);
        _ = c.libevent.bufferevent_disable(bev, c.libevent.EV_WRITE);
    }
}

export fn job_error_callback(_bufev: ?*c.libevent.bufferevent, _events: c_short, arg: ?*anyopaque) void {
    _ = _bufev;
    _ = _events;
    const job: *Job = @ptrCast(@alignCast(arg orelse return));

    if (job.state == .dead) {
        if (job.completecb) |cb| cb(job);
        job_free(job);
    } else {
        if (job.event) |bev|
            _ = c.libevent.bufferevent_disable(bev, c.libevent.EV_READ);
        job.state = .closed;
    }
}

// ── Job resize ───────────────────────────────────────────────────────────

/// Send TIOCSWINSZ to a PTY-backed job.  No-op for pipe jobs or if fd
/// is already closed.  Matches tmux `job_resize()`.
pub fn job_resize(job: *Job, sx: u32, sy: u32) void {
    if (job.fd == -1 or (job.flags & JOB_PTY == 0))
        return;

    var ws = std.mem.zeroes(c.posix_sys.struct_winsize);
    ws.ws_col = @intCast(sx);
    ws.ws_row = @intCast(sy);
    _ = c.posix_sys.ioctl(job.fd, c.posix_sys.TIOCSWINSZ, &ws);
}

// ── Job transfer ─────────────────────────────────────────────────────────

/// Take a job's file descriptor and free the job.  Returns the fd.
/// The caller owns the fd after this call.  Matches tmux `job_transfer()`.
pub fn job_transfer(job: *Job, pid_out: ?*i32, tty_out: ?*[TTY_NAME_MAX]u8) i32 {
    const fd = job.fd;

    if (pid_out) |p| p.* = job.pid;
    if (tty_out) |t| t.* = job.tty;

    // Remove from global list
    jobs_lock.lock();
    for (jobs.items, 0..) |candidate, idx| {
        if (candidate != job) continue;
        _ = jobs.swapRemove(idx);
        break;
    }
    jobs_lock.unlock();

    if (job.freecb) |cb| {
        if (job.data) |d| cb(d);
    }

    if (job.event) |bev| c.libevent.bufferevent_free(bev);

    xm.allocator.free(job.cmd);
    xm.allocator.destroy(job);
    return fd;
}

// ── Job accessors (match tmux API) ───────────────────────────────────────

pub fn job_get_status(job: *const Job) i32 {
    return job.status;
}

pub fn job_get_data(job: *const Job) ?*anyopaque {
    return job.data;
}

pub fn job_get_event(job: *const Job) ?*c.libevent.bufferevent {
    return job.event;
}

// ── AsyncShell (unchanged from original) ─────────────────────────────────

pub fn async_shell_start(
    job: ?*Job,
    shell_command: []const u8,
    options: ShellRunOptions,
    callback: AsyncShellCallback,
    callback_arg: ?*anyopaque,
) ?*AsyncShell {
    const base = proc_mod.libevent orelse return null;
    const async_s = xm.allocator.create(AsyncShell) catch unreachable;
    async_s.* = .{
        .job = job,
        .shell_command = xm.xstrdup(shell_command),
        .cwd = xm.xstrdup(options.cwd),
        .merge_stderr = options.merge_stderr,
        .capture_output = options.capture_output,
        .callback = callback,
        .callback_arg = callback_arg,
    };
    errdefer async_shell_free(async_s);

    const pipe_fds = std.posix.pipe() catch return null;
    async_s.pipe_read = pipe_fds[0];
    async_s.pipe_write = pipe_fds[1];

    async_s.event = c.libevent.event_new(
        base,
        async_s.pipe_read,
        @intCast(c.libevent.EV_READ),
        async_shell_event_cb,
        async_s,
    );
    if (async_s.event == null) return null;
    if (c.libevent.event_add(async_s.event.?, null) != 0) return null;

    if (server_reaper_enabled) {
        if (!async_shell_start_server_reaper(async_s)) return null;
        return async_s;
    }

    async_s.thread = std.Thread.spawn(.{}, asyncShellThreadMain, .{async_s}) catch return null;
    return async_s;
}

pub fn async_shell_free(async_s: *AsyncShell) void {
    if (async_s.server_reaper)
        async_shell_unregister(async_s);
    if (async_s.thread) |thread| thread.join();
    if (async_s.event) |ev| {
        _ = c.libevent.event_del(ev);
        c.libevent.event_free(ev);
    }
    if (async_s.pipe_read >= 0) std.posix.close(async_s.pipe_read);
    if (async_s.pipe_write >= 0) std.posix.close(async_s.pipe_write);
    if (async_s.output_fd >= 0) std.posix.close(async_s.output_fd);
    async_s.result.deinit();
    xm.allocator.free(async_s.shell_command);
    xm.allocator.free(async_s.cwd);
    xm.allocator.destroy(async_s);
}

fn asyncShellThreadMain(async_s: *AsyncShell) void {
    defer asyncShellNotifyComplete(async_s);

    var result = job_run_shell_command(async_s.job, async_s.shell_command, .{
        .cwd = async_s.cwd,
        .merge_stderr = async_s.merge_stderr,
        .capture_output = async_s.capture_output,
    });
    async_s.result = result;
    result.output = .{};
}

fn asyncShellNotifyComplete(async_s: *AsyncShell) void {
    if (async_s.pipe_write < 0) return;
    _ = std.posix.write(async_s.pipe_write, &[1]u8{1}) catch {};
    std.posix.close(async_s.pipe_write);
    async_s.pipe_write = -1;
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

    // Build child environment: process env + global/session environ.
    // This mirrors tmux's job_run which calls environ_for_session() then
    // environ_push() in the forked child, ensuring run-shell commands
    // see variables set via set-environment -g.
    var env_map = if (options.env_map) |m| m.* else buildGlobalEnvMap();
    defer if (options.env_map == null) env_map.deinit();

    var child = std.process.Child.init(&.{ "/bin/sh", "-c", command_to_run }, xm.allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = if (options.capture_output) .Pipe else .Ignore;
    child.stderr_behavior = .Ignore;
    child.cwd = options.cwd;
    child.env_map = &env_map;

    try child.spawn();
    return .{
        .pid = @intCast(child.id),
        .stdout_fd = if (options.capture_output) child.stdout.?.handle else -1,
    };
}

/// Build an EnvMap containing the process environment merged with the zmux
/// global environ.  This matches tmux's environ_for_session + environ_push
/// pattern that propagates set-environment -g variables to job children.
fn buildGlobalEnvMap() std.process.EnvMap {
    const cfg_mod = @import("cfg.zig");

    var map = std.process.EnvMap.init(xm.allocator);

    // Copy the process environment.
    {
        const envp = std.c.environ;
        var i: usize = 0;
        while (envp[i]) |entry_ptr| : (i += 1) {
            const entry = std.mem.span(entry_ptr);
            if (std.mem.indexOfScalar(u8, entry, '=')) |eq| {
                map.put(entry[0..eq], entry[eq + 1 ..]) catch continue;
            }
        }
    }

    // Layer the zmux global environ on top.
    const global_env = env_mod.environ_for_session(null, !cfg_mod.cfg_finished);
    defer env_mod.environ_free(global_env);
    var it = global_env.entries.valueIterator();
    while (it.next()) |entry| {
        if (entry.name.len == 0) continue;
        if (entry.flags & 0x01 != 0) continue; // ENVIRON_HIDDEN
        if (entry.value) |val| {
            map.put(entry.name, val) catch continue;
        } else {
            map.remove(entry.name);
        }
    }

    return map;
}

fn async_shell_register(async_s: *AsyncShell) void {
    async_shells_lock.lock();
    defer async_shells_lock.unlock();
    async_shells.append(xm.allocator, async_s) catch unreachable;
}

fn async_shell_unregister(async_s: *AsyncShell) void {
    async_shells_lock.lock();
    defer async_shells_lock.unlock();

    for (async_shells.items, 0..) |candidate, idx| {
        if (candidate != async_s) continue;
        _ = async_shells.swapRemove(idx);
        break;
    }
}

fn async_shell_take_by_pid(pid: i32) ?*AsyncShell {
    async_shells_lock.lock();
    defer async_shells_lock.unlock();

    for (async_shells.items, 0..) |async_s, idx| {
        if (async_s.child_pid != pid) continue;
        _ = async_shells.swapRemove(idx);
        return async_s;
    }
    return null;
}

fn async_shell_start_server_reaper(async_s: *AsyncShell) bool {
    const spawned = spawnShellProcess(async_s.shell_command, .{
        .cwd = async_s.cwd,
        .merge_stderr = async_s.merge_stderr,
        .capture_output = async_s.capture_output,
    }) catch {
        if (async_s.job) |job| job_finished(job, 1);
        return false;
    };

    async_s.server_reaper = true;
    async_s.child_pid = spawned.pid;
    async_s.output_fd = spawned.stdout_fd;

    if (async_s.job) |job|
        job_started(job, spawned.pid, spawned.stdout_fd);

    async_shell_register(async_s);

    if (!async_s.capture_output) {
        async_s.lock.lock();
        async_s.output_done = true;
        async_s.lock.unlock();
        return true;
    }

    async_s.thread = std.Thread.spawn(.{}, asyncShellReadThreadMain, .{async_s}) catch {
        async_shell_unregister(async_s);
        if (async_s.output_fd >= 0) {
            std.posix.close(async_s.output_fd);
            async_s.output_fd = -1;
        }
        _ = std.c.kill(async_s.child_pid, std.posix.SIG.TERM);
        var raw_status: i32 = 0;
        _ = std.c.waitpid(async_s.child_pid, &raw_status, 0);
        if (async_s.job) |job| {
            job_output_closed(job);
            job_finished(job, 1);
        }
        async_s.child_pid = -1;
        return false;
    };
    return true;
}

fn asyncShellReadThreadMain(async_s: *AsyncShell) void {
    var buf: [4096]u8 = undefined;
    while (async_s.output_fd >= 0) {
        const amt = std.posix.read(async_s.output_fd, &buf) catch break;
        if (amt == 0) break;
        async_s.result.output.appendSlice(xm.allocator, buf[0..amt]) catch unreachable;
    }

    if (async_s.output_fd >= 0) {
        std.posix.close(async_s.output_fd);
        async_s.output_fd = -1;
    }
    if (async_s.job) |job|
        job_output_closed(job);

    async_s.lock.lock();
    async_s.output_done = true;
    const should_notify = async_s.status_known and !async_s.completion_sent;
    if (should_notify) async_s.completion_sent = true;
    async_s.lock.unlock();

    if (should_notify)
        asyncShellNotifyComplete(async_s);
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

/// Called when waitpid reports a child has exited.  Handles both
/// AsyncShell jobs and bufferevent-backed jobs.
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

    // Check async shells first
    if (async_shell_take_by_pid(pid)) |async_s| {
        if (async_s.job) |job|
            job_finished(job, exit_status.retcode);

        async_s.lock.lock();
        async_s.result.retcode = exit_status.retcode;
        async_s.result.signal_code = exit_status.signal_code;
        async_s.status_known = true;
        const should_notify = async_s.output_done and !async_s.completion_sent;
        if (should_notify) async_s.completion_sent = true;
        async_s.lock.unlock();

        if (should_notify)
            asyncShellNotifyComplete(async_s);
        return;
    }

    // Check bufferevent-backed jobs (matches tmux job_check_died)
    jobs_lock.lock();
    for (jobs.items) |job| {
        if (job.pid != pid) continue;
        job.status = status_raw;

        if (job.state == .closed) {
            // fd already closed; job is complete -- unlock before
            // calling back into user code that may re-enter.
            jobs_lock.unlock();
            if (job.completecb) |cb| cb(job);
            job_free(job);
            return;
        } else {
            job.pid = -1;
            job.state = .dead;
        }
        jobs_lock.unlock();
        return;
    }
    jobs_lock.unlock();
}

export fn async_shell_event_cb(fd: c_int, _events: c_short, arg: ?*anyopaque) void {
    _ = _events;
    const async_s: *AsyncShell = @ptrCast(@alignCast(arg orelse return));

    var discard: [16]u8 = undefined;
    _ = std.posix.read(fd, &discard) catch {};

    if (async_s.event) |ev| {
        _ = c.libevent.event_del(ev);
        c.libevent.event_free(ev);
        async_s.event = null;
    }
    if (async_s.pipe_read >= 0) {
        std.posix.close(async_s.pipe_read);
        async_s.pipe_read = -1;
    }

    async_s.callback(async_s, async_s.callback_arg);
}

// ── Job registry (simple jobs without bufferevent) ───────────────────────

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
    child.env_map = options.env_map;

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
    const exit_s = shellExitStatus(term);
    result.retcode = exit_s.retcode;
    result.signal_code = exit_s.signal_code;

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

/// Free a job, removing it from the global list.  Acquires the lock.
pub fn job_free(job: *Job) void {
    jobs_lock.lock();
    defer jobs_lock.unlock();
    job_free_inner(job);
}

/// Free a job; caller must hold `jobs_lock`.
fn job_free_inner(job: *Job) void {
    for (jobs.items, 0..) |candidate, idx| {
        if (candidate != job) continue;
        _ = jobs.swapRemove(idx);
        break;
    }

    if (job.freecb) |cb| {
        if (job.data) |d| cb(d);
    }

    if (job.pid != -1 and job.state == .running) {
        _ = std.c.kill(job.pid, std.posix.SIG.TERM);
    }
    if (job.event) |bev| c.libevent.bufferevent_free(bev);
    if (job.fd != -1) {
        _ = std.c.close(job.fd);
        job.fd = -1;
    }

    xm.allocator.free(job.cmd);
    xm.allocator.destroy(job);
}

pub fn job_tidy() void {
    jobs_lock.lock();
    defer jobs_lock.unlock();

    var i: usize = 0;
    while (i < jobs.items.len) {
        const job = jobs.items[i];
        if (job.state != .running) {
            if (job.freecb) |cb| {
                if (job.data) |d| cb(d);
            }
            if (job.event) |bev| c.libevent.bufferevent_free(bev);
            if (job.fd != -1) {
                _ = std.c.close(job.fd);
            }
            xm.allocator.free(job.cmd);
            xm.allocator.destroy(job);
            _ = jobs.swapRemove(i);
        } else {
            i += 1;
        }
    }
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
        if (job.freecb) |cb| {
            if (job.data) |d| cb(d);
        }
        if (job.event) |bev| c.libevent.bufferevent_free(bev);
        if (job.fd != -1) {
            _ = std.c.close(job.fd);
        }
        xm.allocator.free(job.cmd);
        xm.allocator.destroy(job);
    }
    jobs.clearRetainingCapacity();
}

// ── Test helpers ─────────────────────────────────────────────────────────

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

// ── Tests ────────────────────────────────────────────────────────────────

test "job_register returns distinct heap jobs with copied commands" {
    defer job_reset_all();

    const a = job_register("alpha", JOB_NOWAIT);
    const b = job_register("beta", JOB_NOWAIT);
    defer {
        job_free(a);
        job_free(b);
    }

    try std.testing.expect(a != b);
    try std.testing.expectEqualStrings("alpha", a.cmd);
    try std.testing.expectEqualStrings("beta", b.cmd);
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

pub const StressTests = struct {
    pub fn jobSharedShellRunnerCapturesStdoutAndMergedStderr() !void {
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

    pub fn jobFreeTerminatesALiveSharedJobProcess() !void {
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

    pub fn jobKillAllTerminatesAllLiveSharedJobProcesses() !void {
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

    pub fn jobServerReaperAsyncShellCapturesOutputAndCompletion() !void {
        const old_base = installEventBase();
        defer restoreEventBase(old_base);
        job_enable_server_reaper(true);
        defer job_enable_server_reaper(false);
        defer job_reset_all();
        env_mod.global_environ = env_mod.environ_create();
        defer env_mod.environ_free(env_mod.global_environ);

        var completed = false;
        const job = job_register("printf 'out'; printf 'err' >&2", 0);
        defer job_free(job);

        const async_s = async_shell_start(job, "printf 'out'; printf 'err' >&2", .{
            .cwd = "/",
            .merge_stderr = true,
            .capture_output = true,
        }, testAsyncComplete, &completed) orelse return error.TestUnexpectedResult;
        defer async_shell_free(async_s);

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
        try std.testing.expectEqual(@as(i32, 0), async_s.result.retcode);
        try std.testing.expectEqualStrings("outerr", async_s.result.output.items);
    }

    pub fn jobRunStreamsOutputViaBufferevent() !void {
        const old_base = installEventBase();
        defer restoreEventBase(old_base);
        defer job_reset_all();

        const TestCtx = struct {
            update_count: u32 = 0,
            completed: bool = false,
        };
        var ctx = TestCtx{};

        const update_cb = struct {
            fn cb(job: *Job) void {
                const tc: *TestCtx = @ptrCast(@alignCast(job.data orelse return));
                tc.update_count += 1;
                if (job.event) |bev| {
                    const input = c.libevent.bufferevent_get_input(bev);
                    if (input != null) {
                        const len = c.libevent.evbuffer_get_length(input);
                        if (len > 0)
                            _ = c.libevent.evbuffer_drain(input, len);
                    }
                }
            }
        }.cb;

        const complete_cb = struct {
            fn cb(job: *Job) void {
                const tc: *TestCtx = @ptrCast(@alignCast(job.data orelse return));
                tc.completed = true;
            }
        }.cb;

        const job = job_run(
            "printf 'hello world'",
            "/",
            null,
            update_cb,
            complete_cb,
            null,
            &ctx,
            JOB_SHOWSTDERR,
            80,
            24,
        ) orelse return error.TestUnexpectedResult;

        var spins: usize = 0;
        while (job.state != .dead and job.state != .closed and spins < 400) : (spins += 1) {
            _ = c.libevent.event_base_loop(proc_mod.libevent.?, c.libevent.EVLOOP_NONBLOCK);
            std.Thread.sleep(5 * std.time.ns_per_ms);
            var raw_status: i32 = 0;
            const waited = std.c.waitpid(-1, &raw_status, std.c.W.NOHANG);
            if (waited > 0)
                job_check_died(@intCast(waited), raw_status);
        }

        spins = 0;
        while (spins < 50) : (spins += 1) {
            _ = c.libevent.event_base_loop(proc_mod.libevent.?, c.libevent.EVLOOP_NONBLOCK);
            std.Thread.sleep(2 * std.time.ns_per_ms);
        }

        try std.testing.expect(job.state == .dead or job.state == .closed);
    }
};

test "job_resize is no-op for non-PTY jobs" {
    defer job_reset_all();

    const job = job_register("echo test", 0);
    defer job_free(job);
    job_started(job, 99, 5);

    // Should not crash; no-op because JOB_PTY is not set
    job_resize(job, 120, 40);
}

test "job flags match tmux constants" {
    try std.testing.expectEqual(@as(u32, 0x1), JOB_NOWAIT);
    try std.testing.expectEqual(@as(u32, 0x2), JOB_KEEPWRITE);
    try std.testing.expectEqual(@as(u32, 0x4), JOB_PTY);
    try std.testing.expectEqual(@as(u32, 0x8), JOB_DEFAULTSHELL);
    try std.testing.expectEqual(@as(u32, 0x10), JOB_SHOWSTDERR);
}

test "job accessors return correct values" {
    defer job_reset_all();

    const job = job_register("test cmd", 0);
    defer job_free(job);
    job.status = 42;
    job.data = @ptrFromInt(0xdeadbeef);

    try std.testing.expectEqual(@as(i32, 42), job_get_status(job));
    try std.testing.expectEqual(@as(?*anyopaque, @ptrFromInt(0xdeadbeef)), job_get_data(job));
    try std.testing.expectEqual(@as(?*c.libevent.bufferevent, null), job_get_event(job));
}

test "job_finished overwrites status when invoked repeatedly" {
    defer job_reset_all();

    const j = job_register("noop", 0);
    defer job_free(j);
    job_started(j, 1, -1);
    job_finished(j, 3);
    try std.testing.expectEqual(@as(i32, 3), job_get_status(j));
    job_finished(j, 7);
    try std.testing.expectEqual(@as(i32, 7), job_get_status(j));
}

test "job_render_summary lists multiple registered jobs in order" {
    defer job_reset_all();

    const first = job_register("echo one", 0);
    const second = job_register("echo two", JOB_NOWAIT);
    defer job_free(first);
    defer job_free(second);

    const rendered = job_render_summary(std.testing.allocator);
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "Job 0:") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Job 1:") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "echo one") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "echo two") != null);
}
