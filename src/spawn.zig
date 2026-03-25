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
// Ported in part from tmux/spawn.c.
// Original copyright:
//   Copyright (c) 2019 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

//! spawn.zig – create new windows and panes (fork/exec shells).

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const log = @import("log.zig");
const opts = @import("options.zig");
const win = @import("window.zig");
const sess = @import("session.zig");
const env_mod = @import("environ.zig");
const format_mod = @import("format.zig");
const names_mod = @import("names.zig");
const pane_io = @import("pane-io.zig");
const c = @import("c.zig");

extern fn openpty(
    amaster: *c_int,
    aslave: *c_int,
    name: ?[*]u8,
    termp: ?*anyopaque,
    winp: ?*anyopaque,
) c_int;

extern fn setsid() c_int;
extern fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

// ── spawn_window ──────────────────────────────────────────────────────────

/// Create a new window (and initial pane) in session sc.s.
pub fn spawn_window(sc: *T.SpawnContext, cause: *?[]u8) ?*T.Winlink {
    const s = sc.s orelse {
        cause.* = xm.xstrdup("no session");
        return null;
    };

    const sx, const sy = client_size(sc);
    const w = win.window_create(sx, sy, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);

    const wl = sess.session_attach(s, w, sc.idx, cause) orelse {
        win.window_remove_ref(w, "spawn_window");
        return null;
    };

    const wp = win.window_add_pane(w, null, sx, sy);
    w.active = wp;

    // Always exec the pane shell (even for detached sessions)
    if (sc.flags & T.SPAWN_EMPTY == 0) {
        spawn_pane_exec(wp, sc) catch |err| {
            log.log_warn("spawn_pane_exec failed: {}", .{err});
        };
    }

    if (w.name.len == 0) {
        xm.allocator.free(w.name);
        if (sc.name) |name| {
            w.name = format_mod.format_single(sc.item, name, null, s, null, null);
            opts.options_set_number(w.options, "automatic-rename", 0);
        } else {
            w.name = names_mod.default_window_name(w);
        }
    }

    if (s.curw == null) s.curw = wl;

    return wl;
}

// ── spawn_pane ────────────────────────────────────────────────────────────

/// Create a new pane in an existing window.
pub fn spawn_pane(sc: *T.SpawnContext, cause: *?[]u8) ?*T.WindowPane {
    _ = cause;
    const wl = sc.wl orelse return null;
    const w = wl.window;

    const sx = w.sx;
    const sy = w.sy;

    const wp = win.window_add_pane(w, sc.wp0, sx, sy);

    if (sc.flags & T.SPAWN_EMPTY == 0) {
        spawn_pane_exec(wp, sc) catch |err| {
            log.log_warn("spawn_pane_exec failed: {}", .{err});
        };
    }

    return wp;
}

// ── Internal: fork/exec for a pane ────────────────────────────────────────

fn spawn_pane_exec(wp: *T.WindowPane, sc: *T.SpawnContext) !void {
    const s = sc.s;
    const alloc = xm.allocator;

    const shell = blk: {
        const default_shell = opts.options_get_string(opts.global_s_options, "default-shell");
        break :blk if (default_shell.len > 0) default_shell else "/bin/sh";
    };

    const cwd: []const u8 = sc.cwd orelse (if (s) |ss| ss.cwd else "/");

    const argv = if (sc.argv) |argv_in|
        duplicate_argv(argv_in)
    else
        duplicate_argv(&.{shell});

    wp.argv = argv;
    wp.shell = xm.xstrdup(shell);
    wp.cwd = xm.xstrdup(cwd);

    // Open PTY
    var master: i32 = -1;
    var slave: i32 = -1;
    open_pty(&master, &slave, &wp.tty_name) catch {
        log.log_warn("open_pty failed", .{});
        return error.OpenPtyFailed;
    };
    wp.fd = master;

    // Fork
    const pid = std.posix.fork() catch {
        log.log_warn("fork failed", .{});
        return error.ForkFailed;
    };
    if (pid == 0) {
        // ── child ────────────────────────────────────────────────────────
        std.posix.close(master);
        _ = setsid();
        _ = std.c.ioctl(slave, 0x540e, @as(c_int, 0)); // TIOCSCTTY
        _ = std.c.dup2(slave, 0);
        _ = std.c.dup2(slave, 1);
        _ = std.c.dup2(slave, 2);
        if (slave > 2) std.posix.close(@intCast(slave));

        // Change directory
        _ = std.c.chdir(alloc.dupeZ(u8, cwd) catch "/");

        // Exec the shell
        const shell_z = alloc.dupeZ(u8, shell) catch "/bin/sh";
        var nargv_buf: [16:null]?[*:0]const u8 = .{null} ** 16;
        for (argv, 0..) |arg, idx| {
            if (idx >= 15) break;
            nargv_buf[idx] = (alloc.dupeZ(u8, arg) catch null);
        }
        _ = std.c.execve(shell_z, @ptrCast(&nargv_buf), std.c.environ);
        std.c._exit(1);
    }

    // ── parent ─────────────────────────────────────────────────────────
    std.posix.close(slave);
    wp.pid = pid;
    set_blocking(wp.fd, false);
    pane_io.pane_io_start(wp);
    log.log_debug("new pane %%%{d} pid={d}", .{ wp.id, pid });
}

fn set_blocking(fd: i32, state: bool) void {
    const flags = std.c.fcntl(fd, std.posix.F.GETFL, @as(c_int, 0));
    if (flags < 0) return;
    const O_NONBLOCK: c_int = 0x800;
    const new_flags: c_int = if (state) flags & ~O_NONBLOCK else flags | O_NONBLOCK;
    _ = std.c.fcntl(fd, std.posix.F.SETFL, new_flags);
}

fn duplicate_argv(argv: []const []const u8) [][]u8 {
    var out = xm.allocator.alloc([]u8, argv.len) catch unreachable;
    for (argv, 0..) |arg, idx| {
        out[idx] = xm.xstrdup(arg);
    }
    return out;
}

fn open_pty(master: *i32, slave: *i32, tty_name: *[T.TTY_NAME_MAX]u8) !void {
    var m: c_int = undefined;
    var s_fd: c_int = undefined;
    var name_buf: [T.TTY_NAME_MAX]u8 = undefined;

    if (openpty(&m, &s_fd, &name_buf, null, null) != 0)
        return error.OpenPtyFailed;

    master.* = @intCast(m);
    slave.* = @intCast(s_fd);

    const name_len = std.mem.indexOfScalar(u8, &name_buf, 0) orelse T.TTY_NAME_MAX;
    @memcpy(tty_name[0..name_len], name_buf[0..name_len]);
    if (name_len < T.TTY_NAME_MAX) tty_name[name_len] = 0;
}

fn client_size(sc: *T.SpawnContext) struct { u32, u32 } {
    if (sc.s) |s| {
        const dw = opts.options_get_string(opts.global_s_options, "default-size");
        var sx: u32 = 80;
        var sy: u32 = 24;
        var it = std.mem.splitScalar(u8, dw, 'x');
        if (it.next()) |ws| sx = std.fmt.parseInt(u32, ws, 10) catch 80;
        if (it.next()) |hs| sy = std.fmt.parseInt(u32, hs, 10) catch 24;
        _ = s;
        return .{ sx, sy };
    }
    return .{ 80, 24 };
}
