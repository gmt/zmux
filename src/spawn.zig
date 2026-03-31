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
const cmdq = @import("cmd-queue.zig");
const win = @import("window.zig");
const layout_mod = @import("layout.zig");
const sess = @import("session.zig");
const env_mod = @import("environ.zig");
const format_mod = @import("format.zig");
const names_mod = @import("names.zig");
const pane_io = @import("pane-io.zig");
const resize_mod = @import("resize.zig");
const server_mod = @import("server.zig");
const server_client_mod = @import("server-client.zig");
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

// ── spawn_log ─────────────────────────────────────────────────────────────

/// Debug logging for spawn operations (mirrors tmux spawn_log).
pub fn spawn_log(from: []const u8, sc: *const T.SpawnContext) void {
    const name = if (sc.item) |item| cmdq.cmdq_get_name(@ptrCast(@alignCast(item))) else "(no item)";
    log.log_debug("{s}: {s}, flags={x}", .{ from, name, sc.flags });

    const wl = sc.wl;
    const wp0 = sc.wp0;

    if (wl != null and wp0 != null) {
        log.log_debug("{s}: wl={d} wp0=%%{d}", .{ from, wl.?.idx, wp0.?.id });
    } else if (wl != null) {
        log.log_debug("{s}: wl={d} wp0=none", .{ from, wl.?.idx });
    } else if (wp0 != null) {
        log.log_debug("{s}: wl=none wp0=%%{d}", .{ from, wp0.?.id });
    } else {
        log.log_debug("{s}: wl=none wp0=none", .{from});
    }

    if (sc.s) |s| {
        log.log_debug("{s}: s=${d} idx={d}", .{ from, s.id, sc.idx });
    } else {
        log.log_debug("{s}: s=none idx={d}", .{ from, sc.idx });
    }

    log.log_debug("{s}: name={s}", .{ from, sc.name orelse "none" });
}

// ── spawn_window ──────────────────────────────────────────────────────────

/// Create a new window (and initial pane) in session sc.s.
pub fn spawn_window(sc: *T.SpawnContext, cause: *?[]u8) ?*T.Winlink {
    spawn_log("spawn_window", sc);
    var select_new_window = false;

    if (sc.flags & T.SPAWN_RESPAWN != 0) {
        const wl = sc.wl orelse {
            cause.* = xm.xstrdup("no window");
            return null;
        };
        const s = sc.s orelse wl.session;
        const w = wl.window;

        if (sc.flags & T.SPAWN_KILL == 0) {
            for (w.panes.items) |wp| {
                if (wp.fd >= 0) {
                    cause.* = xm.xasprintf("window {s}:{d} still active", .{ s.name, wl.idx });
                    return null;
                }
            }
        }

        const survivor = w.panes.items[0];
        while (w.panes.items.len > 1) {
            const pane = w.panes.items[1];
            win.window_remove_pane(w, pane);
        }

        survivor.xoff = 0;
        survivor.yoff = 0;
        win.window_pane_resize(survivor, w.sx, w.sy);
        w.active = survivor;
        sc.wp0 = survivor;

        _ = respawn_pane(sc, cause) orelse return null;
        return wl;
    }

    const s = sc.s orelse {
        cause.* = xm.xstrdup("no session");
        return null;
    };

    if (sc.idx != -1) {
        if (sess.winlink_find_by_index(&s.windows, sc.idx)) |existing_wl| {
            if (sc.flags & T.SPAWN_KILL == 0) {
                cause.* = xm.xasprintf("index in use: {d}", .{sc.idx});
                return null;
            }
            select_new_window = s.curw == existing_wl;
            _ = sess.session_detach_index(s, sc.idx, "spawn_window -k");
        }
    }

    const sx, const sy = client_size(sc);
    const w = win.window_create(sx, sy, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);

    const wl = sess.session_attach(s, w, sc.idx, cause) orelse {
        win.window_remove_ref(w, "spawn_window");
        return null;
    };

    const wp = win.window_add_pane(w, null, sx, sy);
    layout_mod.layout_init(w, wp);
    w.active = wp;

    if (sc.flags & T.SPAWN_EMPTY == 0) {
        spawn_pane_exec(wp, sc) catch |err| {
            log.log_warn("spawn_pane_exec failed: {}", .{err});
        };
    } else {
        init_empty_pane(wp);
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

    if (select_new_window) {
        _ = sess.session_set_current(s, wl);
    } else if (s.curw == null) {
        s.curw = wl;
    }

    return wl;
}

// ── spawn_pane ────────────────────────────────────────────────────────────

/// Create a new pane in an existing window.
pub fn spawn_pane(sc: *T.SpawnContext, cause: *?[]u8) ?*T.WindowPane {
    spawn_log("spawn_pane", sc);
    if (sc.flags & T.SPAWN_RESPAWN != 0) return respawn_pane(sc, cause);
    const wl = sc.wl orelse return null;
    const w = wl.window;

    const sx = w.sx;
    const sy = w.sy;

    const wp = win.window_add_pane_with_flags(w, sc.wp0, sx, sy, sc.flags);

    if (sc.lc) |lc| {
        const zoom_flag: i32 = if (sc.flags & T.SPAWN_ZOOM != 0) 1 else 0;
        layout_mod.layout_assign_pane(lc, wp, zoom_flag);
    }

    if (sc.flags & T.SPAWN_EMPTY == 0) {
        spawn_pane_exec(wp, sc) catch |err| {
            log.log_warn("spawn_pane_exec failed: {}", .{err});
        };
    } else {
        init_empty_pane(wp);
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

    wp.flags &= ~@as(u32, T.PANE_EMPTY);
    wp.base.mode |= T.MODE_CURSOR;
    wp.base.mode &= ~@as(i32, T.MODE_CRLF);

    const shell = blk: {
        if (sc.flags & T.SPAWN_RESPAWN != 0 and sc.argv == null) {
            if (wp.shell) |existing| break :blk existing;
        }
        const default_shell = opts.options_get_string(opts.global_s_options, "default-shell");
        break :blk if (default_shell.len > 0) default_shell else "/bin/sh";
    };

    const item = sc.item;
    const target = if (item) |cmd_item| cmdq.cmdq_get_target(@ptrCast(@alignCast(cmd_item))) else T.CmdFindState{};
    const cl = if (item) |cmd_item| cmdq.cmdq_get_client(@ptrCast(@alignCast(cmd_item))) else null;

    const cwd_owned = if (sc.cwd) |raw_cwd|
        resolve_spawn_cwd(raw_cwd, item, cl, target.s)
    else if (sc.flags & T.SPAWN_RESPAWN == 0)
        xm.xstrdup(server_client_mod.server_client_get_cwd(cl, target.s))
    else
        null;
    defer if (cwd_owned) |owned| xm.allocator.free(owned);

    const cwd: []const u8 = cwd_owned orelse blk: {
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

    const child_env = build_child_environment(sc, wp, cl, shell);
    defer env_mod.environ_free(child_env);

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
        const cwd_z = alloc.dupeZ(u8, cwd) catch unreachable;
        if (std.c.chdir(cwd_z) == 0)
            env_mod.environ_set(child_env, "PWD", 0, cwd);

        env_mod.environ_push(child_env);

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

fn build_child_environment(
    sc: *const T.SpawnContext,
    wp: *T.WindowPane,
    cl: ?*T.Client,
    shell: []const u8,
) *T.Environ {
    const child = env_mod.environ_create();
    env_mod.environ_copy(env_mod.global_environ, child);
    if (sc.s) |session|
        env_mod.environ_copy(session.environ, child);
    if (sc.environ) |overlay|
        env_mod.environ_copy(overlay, child);

    if (cl) |client| {
        if (client.session == null) {
            if (env_mod.environ_find(client.environ, "PATH")) |entry| {
                if (entry.value) |value|
                    env_mod.environ_set(child, "PATH", 0, value)
                else
                    env_mod.environ_clear(child, "PATH");
            }
        }
    }
    if (env_mod.environ_find(child, "PATH") == null)
        env_mod.environ_set(child, "PATH", 0, "/usr/bin:/bin");

    if (server_mod.socket_path.len != 0) {
        const session_id: i32 = if (sc.s) |session| @intCast(session.id) else -1;
        const zmux_value = xm.xasprintf("{s},{d},{d}", .{ server_mod.socket_path, std.c.getpid(), session_id });
        defer xm.allocator.free(zmux_value);
        env_mod.environ_set(child, "ZMUX", 0, zmux_value);
    }

    var pane_buf: [32]u8 = undefined;
    const pane_id = std.fmt.bufPrint(&pane_buf, "%{d}", .{wp.id}) catch unreachable;
    env_mod.environ_set(child, "ZMUX_PANE", 0, pane_id);
    env_mod.environ_set(child, "SHELL", 0, shell);
    return child;
}

fn init_empty_pane(wp: *T.WindowPane) void {
    wp.flags |= T.PANE_EMPTY;
    wp.base.mode &= ~@as(i32, T.MODE_CURSOR);
    wp.base.mode |= T.MODE_CRLF;
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
    wp.flags &= ~(T.PANE_EXITED | T.PANE_STATUSREADY | T.PANE_STATUSDRAWN | T.PANE_EMPTY);
    wp.status = 0;
    wp.dead_time = 0;
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

fn resolve_spawn_cwd(
    raw_cwd: []const u8,
    item: ?*T.CmdqItem,
    cl: ?*T.Client,
    target_session: ?*T.Session,
) []u8 {
    const expanded = if (item) |cmd_item|
        format_mod.format_single(cmd_item, raw_cwd, cl, target_session, null, null)
    else
        xm.xstrdup(raw_cwd);

    if (expanded.len != 0 and expanded[0] == '/') return expanded;

    const base = server_client_mod.server_client_get_cwd(cl, target_session);
    const resolved = xm.xasprintf("{s}{s}{s}", .{
        base,
        if (expanded.len != 0) "/" else "",
        expanded,
    });
    xm.allocator.free(expanded);
    return resolved;
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

test "build_child_environment carries the zmux session marker into pane children" {
    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    env_mod.global_environ = env_mod.environ_create();
    defer env_mod.environ_free(env_mod.global_environ);
    sess.session_init_globals(xm.allocator);
    win.window_init_globals(xm.allocator);

    const previous_socket_path = server_mod.socket_path;
    defer server_mod.socket_path = previous_socket_path;
    server_mod.socket_path = "/tmp/zmux-test.sock";

    const s = sess.session_create(null, "spawn-child-env", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("spawn-child-env") != null) sess.session_destroy(s, false, "test");

    const w = win.window_create(80, 24, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    var cause: ?[]u8 = null;
    const wl = sess.session_attach(s, w, 0, &cause) orelse unreachable;
    s.curw = wl;
    const wp = win.window_add_pane(w, null, 80, 24);
    w.active = wp;

    const sc = T.SpawnContext{ .s = s };
    const child = build_child_environment(&sc, wp, null, "/bin/sh");
    defer env_mod.environ_free(child);

    const expected = xm.xasprintf("{s},{d},{d}", .{ server_mod.socket_path, std.c.getpid(), s.id });
    defer xm.allocator.free(expected);
    const expected_pane = try std.fmt.allocPrint(xm.allocator, "%{d}", .{wp.id});
    defer xm.allocator.free(expected_pane);

    try std.testing.expectEqualStrings(expected, env_mod.environ_find(child, "ZMUX").?.value.?);
    try std.testing.expectEqualStrings("/bin/sh", env_mod.environ_find(child, "SHELL").?.value.?);
    try std.testing.expectEqualStrings(expected_pane, env_mod.environ_find(child, "ZMUX_PANE").?.value.?);
}
