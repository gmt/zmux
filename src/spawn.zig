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
const resize_mod = @import("resize.zig");
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
    sess.session_group_synchronize_from(s);

    return wl;
}

// ── spawn_pane ────────────────────────────────────────────────────────────

/// Create a new pane in an existing window.
pub fn spawn_pane(sc: *T.SpawnContext, cause: *?[]u8) ?*T.WindowPane {
    if (sc.flags & T.SPAWN_RESPAWN != 0) return respawn_pane(sc, cause);
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

pub fn respawn_pane(sc: *T.SpawnContext, cause: *?[]u8) ?*T.WindowPane {
    const wl = sc.wl orelse {
        cause.* = xm.xstrdup("no window");
        return null;
    };
    const s = sc.s orelse wl.session;
    const wp = sc.wp0 orelse wl.window.active orelse {
        cause.* = xm.xstrdup("no pane");
        return null;
    };

    if (wp.fd >= 0 and sc.flags & T.SPAWN_KILL == 0) {
        cause.* = xm.xasprintf("pane {s}:{d}.{d} still active", .{
            s.name,
            wl.idx,
            pane_index(wl.window, wp),
        });
        return null;
    }

    if (wp.fd >= 0 or wp.pid > 0) stop_pane_process(wp);
    prepare_pane_for_respawn(wp);

    if (sc.flags & T.SPAWN_EMPTY == 0) {
        spawn_pane_exec(wp, sc) catch |err| {
            cause.* = xm.xasprintf("respawn failed: {}", .{err});
            return null;
        };
    } else {
        wp.flags |= T.PANE_EMPTY;
    }

    return wp;
}

// ── Internal: fork/exec for a pane ────────────────────────────────────────

fn spawn_pane_exec(wp: *T.WindowPane, sc: *T.SpawnContext) !void {
    const s = sc.s;
    const alloc = xm.allocator;

    const shell = blk: {
        if (sc.flags & T.SPAWN_RESPAWN != 0 and sc.argv == null) {
            if (wp.shell) |existing| break :blk existing;
        }
        const default_shell = opts.options_get_string(opts.global_s_options, "default-shell");
        break :blk if (default_shell.len > 0) default_shell else "/bin/sh";
    };

    const cwd: []const u8 = sc.cwd orelse blk: {
        if (sc.flags & T.SPAWN_RESPAWN != 0) {
            if (wp.cwd) |existing| break :blk existing;
        }
        break :blk if (s) |ss| ss.cwd else "/";
    };

    const argv: ?[][]u8 = if (sc.argv) |argv_in|
        duplicate_argv(argv_in)
    else if (sc.flags & T.SPAWN_RESPAWN != 0)
        if (wp.argv) |argv_in| duplicate_argv_const(argv_in) else null
    else
        null;

    if (wp.argv) |old_argv| free_argv(old_argv);
    if (wp.shell) |old_shell| xm.allocator.free(old_shell);
    if (wp.cwd) |old_cwd| xm.allocator.free(old_cwd);
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

        if (sc.environ) |env| env_mod.environ_push(env);

        const shell_z = alloc.dupeZ(u8, shell) catch "/bin/sh";
        _ = setenv("SHELL", shell_z, 1);

        if (argv) |argv_items| {
            if (argv_items.len > 1) {
                const argv_buf = alloc.alloc(?[*:0]const u8, argv_items.len + 1) catch unreachable;
                for (argv_items, 0..) |arg, idx| argv_buf[idx] = alloc.dupeZ(u8, arg) catch null;
                argv_buf[argv_items.len] = null;
                _ = c.posix_sys.execvp(argv_buf[0], @ptrCast(argv_buf.ptr));
                std.c._exit(1);
            }

            const shell_name = shell_basename(shell);
            const shell_name_z = alloc.dupeZ(u8, shell_name) catch shell_z;
            const command_z = alloc.dupeZ(u8, argv_items[0]) catch null;
            var shell_argv = [_:null]?[*:0]const u8{ shell_name_z.ptr, "-c", if (command_z) |cmd| cmd.ptr else null, null };
            _ = std.c.execve(shell_z, @ptrCast(&shell_argv), std.c.environ);
            std.c._exit(1);
        }

        const login_name = alloc.dupeZ(u8, shell_login_name(shell)) catch shell_z;
        var login_argv = [_:null]?[*:0]const u8{ login_name.ptr, null };
        _ = std.c.execve(shell_z, @ptrCast(&login_argv), std.c.environ);
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

fn duplicate_argv_const(argv: [][]u8) [][]u8 {
    var out = xm.allocator.alloc([]u8, argv.len) catch unreachable;
    for (argv, 0..) |arg, idx| out[idx] = xm.xstrdup(arg);
    return out;
}

fn free_argv(argv: [][]u8) void {
    for (argv) |arg| xm.allocator.free(arg);
    xm.allocator.free(argv);
}

fn stop_pane_process(wp: *T.WindowPane) void {
    pane_io.pane_io_stop(wp);
    if (wp.pid > 0) {
        _ = std.c.kill(wp.pid, std.posix.SIG.HUP);
        _ = std.c.kill(wp.pid, std.posix.SIG.TERM);
        wp.pid = -1;
    }
    if (wp.fd >= 0) {
        std.posix.close(wp.fd);
        wp.fd = -1;
    }
}

fn prepare_pane_for_respawn(wp: *T.WindowPane) void {
    wp.flags &= ~(T.PANE_EXITED | T.PANE_EMPTY);
    wp.status = 0;
    win.window_pane_reset_contents(wp);
}

fn pane_index(w: *T.Window, wp: *T.WindowPane) usize {
    return win.window_pane_index(w, wp) orelse 0;
}

fn shell_basename(shell: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, shell, '/')) |idx| {
        if (idx + 1 < shell.len) return shell[idx + 1 ..];
    }
    return shell;
}

fn shell_login_name(shell: []const u8) []u8 {
    const base = shell_basename(shell);
    return xm.xasprintf("-{s}", .{base});
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
        var sx: u32 = 80;
        var sy: u32 = 24;
        var xpixel: u32 = 0;
        var ypixel: u32 = 0;
        resize_mod.default_window_size(null, s, null, &sx, &sy, &xpixel, &ypixel, -1);
        return .{ sx, sy };
    }
    return .{ 80, 24 };
}
