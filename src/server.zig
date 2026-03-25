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
// Ported from tmux/server.c
// Original copyright:
//   Copyright (c) 2007 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

//! server.zig – server process: socket, accept loop, state management.

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const log = @import("log.zig");
const proc_mod = @import("proc.zig");
const opts = @import("options.zig");
const sess = @import("session.zig");
const win = @import("window.zig");
const server_client_mod = @import("server-client.zig");
const cmdq = @import("cmd-queue.zig");
const protocol = @import("zmux-protocol.zig");
const c = @import("c.zig");
const key_bindings = @import("key-bindings.zig");
const cfg_mod = @import("cfg.zig");
const build_options = @import("build_options");

// ── Global server state ───────────────────────────────────────────────────

pub var server_proc: ?*T.ZmuxProc = null;
pub var server_fd: i32 = -1;
pub var server_client_flags: u64 = 0;
pub var server_exit: bool = false;
pub var clients: std.ArrayList(*T.Client) = .{};
pub var message_log: std.ArrayList(T.MessageEntry) = .{};
var server_accept_ev: ?*c.libevent.event = null;

// Globals exported to the rest of the codebase
pub var socket_path: []const u8 = "";
pub var start_time: std.posix.timeval = .{ .sec = 0, .usec = 0 };

// ── Socket creation ────────────────────────────────────────────────────────

pub fn server_create_socket(flags: u64, cause: *?[]u8) i32 {
    var sa: std.posix.sockaddr.un = std.mem.zeroes(std.posix.sockaddr.un);
    sa.family = std.posix.AF.UNIX;

    if (socket_path.len >= sa.path.len) {
        cause.* = xm.xasprintf("socket path too long: {s}", .{socket_path});
        return -1;
    }
    @memcpy(sa.path[0..socket_path.len], socket_path);

    const fd = std.c.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0);
    if (fd < 0) {
        cause.* = xm.xasprintf("socket: {s}", .{"failed"});
        return -1;
    }

    // unlink any stale socket
    _ = std.posix.unlink(socket_path) catch {};

    // Set permissions based on flags
    const IXUSR: c_uint = 0o100;
    const IXGRP: c_uint = 0o010;
    const IRWXG: c_uint = 0o070;
    const IRWXO: c_uint = 0o007;
    const umask_flags: c_uint = if (flags & T.CLIENT_DEFAULTSOCKET != 0)
        (IXUSR | IXGRP | IRWXO)
    else
        (IXUSR | IRWXG | IRWXO);
    const old_umask = std.c.umask(@as(std.c.mode_t, @intCast(umask_flags)));
    defer _ = std.c.umask(old_umask);

    const addr_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.un);
    if (std.c.bind(fd, @ptrCast(&sa), addr_len) != 0) {
        cause.* = xm.xasprintf("bind {s}: failed", .{socket_path});
        std.posix.close(fd);
        return -1;
    }

    if (std.c.listen(fd, 128) != 0) {
        std.posix.close(fd);
        return -1;
    }

    set_blocking(fd, false);
    return fd;
}

fn set_blocking(fd: i32, state: bool) void {
    const flags = std.c.fcntl(fd, std.posix.F.GETFL, @as(c_int, 0));
    if (flags < 0) return;
    const O_NONBLOCK: c_int = 0x800; // O_NONBLOCK on Linux x86_64
    const new_flags: c_int = if (state) flags & ~O_NONBLOCK else flags | O_NONBLOCK;
    _ = std.c.fcntl(fd, std.posix.F.SETFL, new_flags);
}

// ── Accept callback ───────────────────────────────────────────────────────

export fn server_accept_cb(fd: c_int, _events: c_short, _arg: ?*anyopaque) void {
    _ = _events;
    _ = _arg;

    var sa: std.posix.sockaddr.un = undefined;
    var sa_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.un);
    const new_fd = std.c.accept(fd, @ptrCast(&sa), &sa_len);
    if (new_fd < 0) return;

    set_blocking(new_fd, false);

    const client_ptr = server_client_mod.server_client_create(new_fd);
    log.log_debug("new client {*} on fd {d}", .{ client_ptr, new_fd });
}

fn server_add_accept(timeout_ms: u32) void {
    _ = timeout_ms;
    if (server_fd < 0) return;
    const ev = c.libevent;
    if (proc_mod.libevent) |base| {
        const ev_ptr = ev.event_new(base, server_fd, @intCast(ev.EV_READ | ev.EV_PERSIST), server_accept_cb, null);
        if (ev_ptr) |ep| {
            server_accept_ev = ep;
            _ = ev.event_add(ep, null);
        }
    }
}

// ── Server loop callback ──────────────────────────────────────────────────

fn server_loop() bool {
    // Drain command queues
    var items: u32 = 1;
    while (items != 0) {
        items = cmdq.cmdq_next(null);
        for (clients.items) |cl| {
            if (cl.flags & T.CLIENT_IDENTIFIED != 0)
                items += cmdq.cmdq_next(cl);
        }
    }

    server_client_mod.server_client_loop();

    const exit_empty = opts.options_get_number(opts.global_options, "exit-empty");
    const exit_unattached = opts.options_get_number(opts.global_options, "exit-unattached");
    const nsess = sess.sessions.count();
    const ncli = clients.items.len;

    log.log_debug("server_loop: exit_empty={d} exit_unattached={d} nsess={d} ncli={d} server_exit={}", .{
        exit_empty, exit_unattached, nsess, ncli, server_exit,
    });

    // If exit-empty is off and we haven't been told to exit, stay alive
    if (exit_empty != 1 and !server_exit)
        return false;

    // While clients are connected, stay alive
    if (ncli > 0)
        return false;

    // While sessions exist and exit-unattached is off, stay alive
    if (exit_unattached != 1) {
        if (nsess > 0) return false;
    }

    log.log_debug("server_loop: exiting", .{});
    return true;
}

// ── Server startup ────────────────────────────────────────────────────────

/// Fork the server daemon, initialise state, run the event loop.
/// Returns the fd to communicate with the new server (in the parent),
/// or runs forever in the server child.
pub fn server_start(
    client_proc: *T.ZmuxProc,
    flags: u64,
    _base: *c.libevent.event_base,
    lockfd: i32,
    lockfile: ?[]u8,
) i32 {
    _ = _base;
    var fd: i32 = -1;

    if (flags & T.CLIENT_NOFORK == 0) {
        const pid = proc_mod.proc_fork_and_daemon(&fd);
        if (pid != 0) {
            // Parent: clean up lock and return the socket fd.
            if (lockfd >= 0) {
                if (lockfile) |lf| {
                    _ = std.posix.unlink(lf) catch {};
                    xm.allocator.free(lf);
                }
                std.posix.close(lockfd);
            }
            return fd;
        }
    }

    // ── Server child ────────────────────────────────────────────────────
    proc_mod.proc_clear_signals(client_proc, false);
    server_client_flags = flags;

    // After fork+daemon, the inherited event base is stale (epoll fd, etc).
    // Create a fresh base instead of reinit (matches tmux behaviour on Linux
    // where EVENT_NOEPOLL is toggled around event_init).
    {
        const os_mod = @import("os/linux.zig");
        const fresh_base = os_mod.osdep_event_init();
        proc_mod.libevent = fresh_base;
    }

    server_proc = proc_mod.proc_start("server");
    proc_mod.proc_set_signals(server_proc.?, server_signal);

    // Initialise global state
    message_log = .{};
    sess.session_init_globals(xm.allocator);
    win.window_init_globals(xm.allocator);

    opts.global_options = opts.options_create(null);
    opts.global_s_options = opts.options_create(null);
    opts.global_w_options = opts.options_create(null);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);

    key_bindings.key_bindings_init();

    std.posix.gettimeofday(&start_time, null);

    // Create the server socket
    var cause: ?[]u8 = null;
    server_fd = blk: {
        if (build_options.have_systemd) {
            // TODO: systemd socket activation
            break :blk server_create_socket(flags, &cause);
        } else {
            break :blk server_create_socket(flags, &cause);
        }
    };

    if (server_fd < 0) {
        log.log_warn("server socket failed: {s}", .{cause orelse "unknown"});
    }

    // Create the initial client connection (fd from the fork socketpair)
    const startup_client = if (flags & T.CLIENT_NOFORK == 0)
        server_client_mod.server_client_create(fd)
    else blk: {
        opts.options_set_number(opts.global_options, "exit-empty", 0);
        break :blk null;
    };

    if (lockfd >= 0) {
        if (lockfile) |lf| {
            _ = std.posix.unlink(lf) catch {};
            xm.allocator.free(lf);
        }
        std.posix.close(lockfd);
    }

    server_add_accept(0);

    // Load config files (queued via cmdq, will run in the first loop iteration)
    cfg_mod.cfg_load(startup_client);

    proc_mod.proc_loop(server_proc.?, server_loop);

    std.process.exit(0);
}

// ── Signal handler ────────────────────────────────────────────────────────

export fn server_signal(signo: c_int) void {
    switch (signo) {
        std.posix.SIG.TERM, std.posix.SIG.INT => {
            server_exit = true;
            proc_mod.proc_exit(server_proc.?);
        },
        std.posix.SIG.CHLD => server_child_signal(),
        else => {},
    }
}

fn server_child_signal() void {
    // Reap all exited children
    while (true) {
        const pid = std.c.waitpid(-1, null, std.posix.W.NOHANG);
        if (pid <= 0) break;
        log.log_debug("child {d} exited", .{pid});
    }
}

// ── Utility ───────────────────────────────────────────────────────────────

pub fn server_add_client(cl: *T.Client) void {
    clients.append(xm.allocator, cl) catch unreachable;
}

pub fn server_remove_client(cl: *T.Client) void {
    for (clients.items, 0..) |c_ptr, i| {
        if (c_ptr == cl) {
            _ = clients.swapRemove(i);
            return;
        }
    }
}

pub fn server_destroy_session(s: *T.Session) void {
    for (clients.items) |cl| {
        if (cl.session == s) {
            if (s.attached > 0) s.attached -= 1;
            cl.session = null;
            if (cl.last_session == s) cl.last_session = null;
            cl.flags |= T.CLIENT_EXIT;
            if (cl.peer) |peer| {
                const retval: i32 = 0;
                _ = proc_mod.proc_send(peer, .exit, -1, @ptrCast(std.mem.asBytes(&retval)), @sizeOf(i32));
            }
        }
    }
}

pub fn server_redraw_session(s: *T.Session) void {
    for (clients.items) |cl| {
        if (cl.flags & T.CLIENT_ATTACHED == 0) continue;
        if (cl.session != s) continue;
        cl.flags |= T.CLIENT_REDRAWWINDOW;
    }
}

pub fn server_redraw_window(w: *T.Window) void {
    for (clients.items) |cl| {
        if (cl.flags & T.CLIENT_ATTACHED == 0) continue;
        const s = cl.session orelse continue;
        if (!sess.session_has_window(s, w)) continue;
        cl.flags |= T.CLIENT_REDRAWWINDOW;
    }
}
