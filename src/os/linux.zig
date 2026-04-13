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
// Ported from tmux/osdep-linux.c
// Original copyright:
//   Copyright (c) 2009 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

//! os/linux.zig – Linux platform-specific helpers.

const std = @import("std");
const builtin = @import("builtin");
const xm = @import("../xmalloc.zig");
const c = @import("../c.zig");

// Extern declarations for libc functions not in Zig's std.c
extern fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern fn unsetenv(name: [*:0]const u8) c_int;
extern fn openpty(
    amaster: *c_int,
    aslave: *c_int,
    name: ?[*]u8,
    termp: ?*anyopaque,
    winp: ?*c.posix_sys.struct_winsize,
) c_int;
extern fn setsid() c_int;

const linux_TIOCSCTTY: u32 = 0x540E;

fn errno_from_syscall(rc: usize) std.posix.E {
    const signed: isize = @bitCast(rc);
    const int = if (signed > -4096 and signed < 0) -signed else 0;
    return @enumFromInt(int);
}

fn tcgetpgrp_or_null(fd: i32) ?std.posix.pid_t {
    var pgrp: std.posix.pid_t = undefined;
    const rc = std.os.linux.tcgetpgrp(fd, &pgrp);
    return switch (errno_from_syscall(rc)) {
        .SUCCESS => pgrp,
        else => null,
    };
}

/// Get the name of the foreground process for a TTY fd via /proc.
/// Returns a newly allocated slice or null on failure.
pub fn osdep_get_name(fd: i32) ?[]u8 {
    const pgrp = tcgetpgrp_or_null(fd) orelse return null;

    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/cmdline", .{pgrp}) catch return null;

    const file = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer file.close();

    var buf: [1024]u8 = undefined;
    const n = file.read(&buf) catch return null;
    if (n == 0) return null;

    // cmdline is NUL-separated; take first token
    const end = std.mem.indexOfScalar(u8, buf[0..n], 0) orelse n;
    if (end == 0) return null;
    return xm.xstrdup(buf[0..end]);
}

/// Get the CWD of the foreground process for a TTY fd via /proc symlink.
/// Returns a pointer into a static buffer.
pub fn osdep_get_cwd(fd: i32) ?[]const u8 {
    const Static = struct {
        var target: [std.posix.PATH_MAX + 1]u8 = undefined;
    };

    const pgrp = tcgetpgrp_or_null(fd) orelse return null;

    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/cwd", .{pgrp}) catch return null;

    const link = std.posix.readlink(path, &Static.target) catch blk: {
        // Fallback: try the session ID
        var sid: std.posix.pid_t = undefined;
        const rc = std.os.linux.ioctl(fd, std.os.linux.T.IOCGSID, @intFromPtr(&sid));
        if (errno_from_syscall(rc) != .SUCCESS) return null;
        const path2 = std.fmt.bufPrint(&path_buf, "/proc/{d}/cwd", .{sid}) catch return null;
        break :blk std.posix.readlink(path2, &Static.target) catch return null;
    };

    if (link.len == 0) return null;
    Static.target[link.len] = 0;
    return link;
}

/// Initialise a libevent event_base for Linux.
/// On Linux, epoll doesn't work on /dev/null, so we disable it.
pub fn osdep_event_init() *c.libevent.event_base {
    _ = setenv("EVENT_NOEPOLL", "1", 1);
    const base = c.libevent.event_init() orelse @panic("event_init failed");
    _ = unsetenv("EVENT_NOEPOLL");
    return base;
}

test "linux osdep_get_name returns null on non-tty fd" {
    if (builtin.os.tag != .linux) return;
    const fd = try std.posix.open("/dev/null", .{ .ACCMODE = .RDONLY }, 0);
    defer std.posix.close(fd);
    try std.testing.expect(osdep_get_name(fd) == null);
}

test "linux osdep_event_init returns a live libevent base" {
    if (builtin.os.tag != .linux) return;
    const base = osdep_event_init();
    defer c.libevent.event_base_free(base);
}

test "linux osdep_get_name and osdep_get_cwd observe pty foreground child" {
    if (builtin.os.tag != .linux) return;
    std.fs.accessAbsolute("/bin/sleep", .{}) catch return;

    if (std.fs.openFileAbsolute("/proc/self/status", .{})) |status_file| {
        defer status_file.close();
        if (status_file.readToEndAlloc(std.testing.allocator, 64 * 1024)) |status| {
            defer std.testing.allocator.free(status);
            if (std.mem.indexOf(u8, status, "NSpid:\t")) |start| {
                const line_end = std.mem.indexOfScalarPos(u8, status, start, '\n') orelse status.len;
                var tab_count: usize = 0;
                for (status[start..line_end]) |ch| {
                    if (ch == '\t') tab_count += 1;
                }
                if (tab_count > 1) return;
            }
        } else |_| {}
    } else |_| {}

    var tmp = std.testing.tmpDir(.{});
    const dir = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir);
    var dirz_buf: [std.posix.PATH_MAX]u8 = undefined;
    const dirz = try std.fmt.bufPrintZ(&dirz_buf, "{s}", .{dir});
    _ = setenv("ZMUX_PTY_TEST_CWD", dirz.ptr, 1);
    defer _ = unsetenv("ZMUX_PTY_TEST_CWD");

    var master: c_int = -1;
    var slave: c_int = -1;
    var tty_raw: [256]u8 = std.mem.zeroes([256]u8);
    if (openpty(&master, &slave, &tty_raw, null, null) != 0)
        return;

    const pid = try std.posix.fork();
    if (pid == 0) {
        _ = std.posix.close(@intCast(master));
        _ = setsid();
        const rc = std.os.linux.ioctl(@intCast(slave), linux_TIOCSCTTY, @as(usize, 0));
        if (errno_from_syscall(rc) != .SUCCESS)
            std.process.exit(1);
        std.posix.dup2(@intCast(slave), std.posix.STDIN_FILENO) catch std.process.exit(1);
        std.posix.dup2(@intCast(slave), std.posix.STDOUT_FILENO) catch std.process.exit(1);
        std.posix.dup2(@intCast(slave), std.posix.STDERR_FILENO) catch std.process.exit(1);
        std.posix.close(@intCast(slave));
        if (std.posix.getenv("ZMUX_PTY_TEST_CWD")) |d|
            std.posix.chdir(d) catch std.process.exit(1);
        const argv_exec = [_:null]?[*:0]const u8{ "/bin/sleep", "30", null };
        _ = std.c.execve("/bin/sleep", @ptrCast(&argv_exec), std.c.environ);
        std.process.exit(1);
    }

    _ = std.posix.close(@intCast(slave));
    defer {
        _ = std.c.kill(pid, std.posix.SIG.TERM);
        _ = std.posix.waitpid(pid, 0);
        _ = std.posix.close(@intCast(master));
    }

    var saw_sleep = false;
    for (0..200) |_| {
        std.Thread.sleep(20 * std.time.ns_per_ms);
        if (osdep_get_name(@intCast(master))) |n| {
            defer xm.allocator.free(n);
            if (std.mem.indexOf(u8, n, "sleep") != null) {
                saw_sleep = true;
                break;
            }
        }
    }
    try std.testing.expect(saw_sleep);

    var saw_cwd = false;
    for (0..100) |_| {
        if (osdep_get_cwd(@intCast(master))) |cwd| {
            if (std.mem.eql(u8, cwd, dir)) {
                saw_cwd = true;
                break;
            }
        }
        std.Thread.sleep(20 * std.time.ns_per_ms);
    }
    try std.testing.expect(saw_cwd);
}
