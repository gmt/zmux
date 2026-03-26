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
// Ported from tmux/log.c
// Original copyright:
//   Copyright (c) 2007 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

//! log.zig – runtime logging for zmux.
//!
//! Logging is off unless -v flag was given (log_add_level).  When enabled,
//! a file named zmux-<name>-<pid>.log is opened in the current directory.
//! The behaviour mirrors tmux's log.c exactly.

const std = @import("std");

var log_file: ?std.fs.File = null;
var log_level: u32 = 0;

/// Increment the log verbosity level (each -v flag calls this once).
pub fn log_add_level() void {
    log_level += 1;
}

/// Return current log level.
pub fn log_get_level() u32 {
    return log_level;
}

/// Open the log file for the named process.  Does nothing when level == 0.
pub fn log_open(name: []const u8) void {
    if (log_level == 0) return;
    log_close();

    var buf: [256]u8 = undefined;
    const pid = std.os.linux.getpid();
    const path = std.fmt.bufPrintZ(&buf, "zmux-{s}-{d}.log", .{ name, pid }) catch return;
    log_file = std.fs.cwd().createFile(path, .{ .truncate = false }) catch null;
}

/// Toggle logging on/off.
pub fn log_toggle(name: []const u8) void {
    if (log_level == 0) {
        log_level = 1;
        log_open(name);
        log_debug("log opened", .{});
    } else {
        log_debug("log closed", .{});
        log_level = 0;
        log_close();
    }
}

/// Close the log file.
pub fn log_close() void {
    if (log_file) |f| {
        f.close();
        log_file = null;
    }
}

/// Write a formatted message to the log (no prefix).
pub fn log_debug(comptime fmt: []const u8, args: anytype) void {
    log_vwrite(fmt, args, "");
}

/// Write a formatted message with a "warning: " prefix.
pub fn log_warn(comptime fmt: []const u8, args: anytype) void {
    log_vwrite(fmt, args, "warning: ");
}

fn log_vwrite(comptime fmt: []const u8, args: anytype, prefix: []const u8) void {
    const f = log_file orelse return;
    const now = std.time.microTimestamp();
    const sec = @divTrunc(now, std.time.us_per_s);
    const us = @mod(now, std.time.us_per_s);
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    var out: [4096 + 64]u8 = undefined;
    const full = std.fmt.bufPrint(&out, "{d}.{d:0>6} {s}{s}\n", .{ sec, us, prefix, msg }) catch return;
    _ = f.writeAll(full) catch {};
}

/// Write a fatal-with-errno message to the log, then abort.
pub fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    const errno = std.c._errno().*;
    log_vwrite(fmt, args, "fatal: ");
    std.debug.print("zmux fatal: " ++ fmt ++ " (errno={d})\n", args ++ .{errno});
    std.process.abort();
}

/// Write a fatal message to the log (no errno), then abort.
pub fn fatalx(comptime fmt: []const u8, args: anytype) noreturn {
    log_vwrite(fmt, args, "fatal: ");
    std.debug.print("zmux fatal: " ++ fmt ++ "\n", args);
    std.process.abort();
}
