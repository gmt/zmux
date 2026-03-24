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
const xm = @import("../xmalloc.zig");
const c = @import("../c.zig");

// Extern declarations for libc functions not in Zig's std.c
extern fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern fn unsetenv(name: [*:0]const u8) c_int;

/// Get the name of the foreground process for a TTY fd via /proc.
/// Returns a newly allocated slice or null on failure.
pub fn osdep_get_name(fd: i32) ?[]u8 {
    const pgrp = std.c.tcgetpgrp(fd);
    if (pgrp < 0) return null;

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

    const pgrp = std.c.tcgetpgrp(fd);
    if (pgrp < 0) return null;

    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/cwd", .{pgrp}) catch return null;

    const n = std.posix.readlink(path, &Static.target) catch blk: {
        // Fallback: try the session ID
        var sid: std.posix.pid_t = undefined;
        const rc = std.c.ioctl(fd, std.os.linux.T.IOCGSID, &sid);
        if (rc < 0) return null;
        const path2 = std.fmt.bufPrint(&path_buf, "/proc/{d}/cwd", .{sid}) catch return null;
        break :blk std.posix.readlink(path2, &Static.target) catch return null;
    };

    if (n == 0) return null;
    Static.target[n] = 0;
    return Static.target[0..n];
}

/// Initialise a libevent event_base for Linux.
/// On Linux, epoll doesn't work on /dev/null, so we disable it.
pub fn osdep_event_init() *c.libevent.event_base {
    _ = setenv("EVENT_NOEPOLL", "1", 1);
    const base = c.libevent.event_init() orelse @panic("event_init failed");
    _ = unsetenv("EVENT_NOEPOLL");
    return base;
}
