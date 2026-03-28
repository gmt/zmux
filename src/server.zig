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
const names_mod = @import("names.zig");
const server_client_mod = @import("server-client.zig");
const cmdq = @import("cmd-queue.zig");
const job_mod = @import("job.zig");
const protocol = @import("zmux-protocol.zig");
const c = @import("c.zig");
const key_bindings = @import("key-bindings.zig");
const cfg_mod = @import("cfg.zig");
const build_options = @import("build_options");
const client_registry = @import("client-registry.zig");
const notify = @import("notify.zig");
const server_acl = @import("server-acl.zig");
const cmd_wait_for = @import("cmd-wait-for.zig");

// ── Global server state ───────────────────────────────────────────────────

pub var server_proc: ?*T.ZmuxProc = null;
pub var server_fd: i32 = -1;
pub var server_client_flags: u64 = 0;
pub var server_exit: bool = false;
pub var message_log: std.ArrayList(T.MessageEntry) = .{};
var message_next: u32 = 0;
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

pub fn server_update_socket() void {
    if (socket_path.len == 0) return;

    var attached = false;
    var sessions_it = sess.sessions.valueIterator();
    while (sessions_it.next()) |session_ptr| {
        if (session_ptr.*.attached != 0) {
            attached = true;
            break;
        }
    }

    const stat = std.fs.cwd().statFile(socket_path) catch return;
    var mode: std.fs.File.Mode = stat.mode & 0o777;
    if (attached) {
        if (mode & 0o400 != 0) mode |= 0o100;
        if (mode & 0o040 != 0) mode |= 0o010;
        if (mode & 0o004 != 0) mode |= 0o001;
    } else {
        mode &= ~@as(std.fs.File.Mode, 0o111);
    }

    std.posix.fchmodat(std.posix.AT.FDCWD, socket_path, mode, 0) catch return;
}

fn server_clear_accept() void {
    if (server_accept_ev) |ev| {
        _ = c.libevent.event_del(ev);
        c.libevent.event_free(ev);
        server_accept_ev = null;
    }
}

// ── Accept callback ───────────────────────────────────────────────────────

export fn server_accept_cb(fd: c_int, _events: c_short, _arg: ?*anyopaque) void {
    _ = _events;
    _ = _arg;

    var sa: std.posix.sockaddr.un = undefined;
    var sa_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.un);
    const new_fd = std.c.accept(fd, @ptrCast(&sa), &sa_len);
    if (new_fd < 0) return;
    if (server_exit) {
        std.posix.close(new_fd);
        return;
    }

    set_blocking(new_fd, false);

    const client_ptr = server_client_mod.server_client_create(new_fd);
    if (!server_acl.server_acl_join(client_ptr)) {
        client_ptr.exit_message = xm.xstrdup("access not allowed");
        client_ptr.flags |= T.CLIENT_EXIT;
    }
    log.log_debug("new client {*} on fd {d}", .{ client_ptr, new_fd });
}

fn server_add_accept(timeout_ms: u32) void {
    _ = timeout_ms;
    if (server_fd < 0) return;

    server_clear_accept();
    const ev = c.libevent;
    if (proc_mod.libevent) |base| {
        const ev_ptr = ev.event_new(base, server_fd, @intCast(ev.EV_READ | ev.EV_PERSIST), server_accept_cb, null);
        if (ev_ptr) |ep| {
            server_accept_ev = ep;
            _ = ev.event_add(ep, null);
        }
    }
}

fn server_reopen_socket() void {
    var cause: ?[]u8 = null;
    defer if (cause) |msg| xm.allocator.free(msg);

    server_clear_accept();

    const fd = server_create_socket(server_client_flags, &cause);
    if (fd != -1) {
        if (server_fd >= 0) std.posix.close(server_fd);
        server_fd = fd;
        server_update_socket();
    } else if (cause) |msg| {
        log.log_warn("server socket reopen failed: {s}", .{msg});
    }

    server_add_accept(0);
}

// ── Server loop callback ──────────────────────────────────────────────────

fn server_loop() bool {
    // Drain command queues
    var items: u32 = 1;
    while (items != 0) {
        items = cmdq.cmdq_next(null);
        for (client_registry.clients.items) |cl| {
            if (cl.flags & T.CLIENT_IDENTIFIED != 0)
                items += cmdq.cmdq_next(cl);
        }
    }

    server_client_mod.server_client_loop();

    var windows_it = win.windows.valueIterator();
    while (windows_it.next()) |w| {
        names_mod.check_window_name(w.*);
    }

    const exit_empty = opts.options_get_number(opts.global_options, "exit-empty");
    const exit_unattached = opts.options_get_number(opts.global_options, "exit-unattached");
    const nsess = sess.sessions.count();
    const ncli = client_registry.clients.items.len;
    var attached_clients: usize = 0;
    for (client_registry.clients.items) |cl| {
        if (cl.session != null) attached_clients += 1;
    }

    log.log_debug("server_loop: exit_empty={d} exit_unattached={d} nsess={d} ncli={d} attached={d} server_exit={}", .{
        exit_empty, exit_unattached, nsess, ncli, attached_clients, server_exit,
    });

    // If exit-empty is off and we haven't been told to exit, stay alive
    if (exit_empty != 1 and !server_exit)
        return false;

    // While sessions exist and exit-unattached is off, stay alive
    if (exit_unattached != 1) {
        if (nsess > 0) return false;
    }

    if (attached_clients > 0)
        return false;

    // Wake any detached wait-for clients before deciding if the server can exit.
    cmd_wait_for.cmd_wait_for_flush();
    if (client_registry.clients.items.len > 0)
        return false;

    if (job_mod.job_still_running())
        return false;

    log.log_debug("server_loop: exiting", .{});
    return true;
}

pub fn server_reset_message_log() void {
    for (message_log.items) |entry| {
        xm.allocator.free(entry.msg);
    }
    message_log.deinit(xm.allocator);
    message_log = .{};
    message_next = 0;
}

pub fn server_add_message(comptime fmt: []const u8, args: anytype) void {
    const rendered = xm.xasprintf(fmt, args);
    log.log_debug("message: {s}", .{rendered});

    message_log.append(xm.allocator, .{
        .msg = rendered,
        .msg_num = message_next,
        .msg_time = std.time.timestamp(),
    }) catch unreachable;
    message_next += 1;

    const limit_raw = @max(opts.options_get_number(opts.global_options, "message-limit"), 0);
    const limit: usize = @intCast(limit_raw);
    while (message_log.items.len > limit) {
        const removed = message_log.orderedRemove(0);
        xm.allocator.free(removed.msg);
    }
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
    job_mod.job_enable_server_reaper(true);

    // Initialise global state
    server_reset_message_log();
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

    server_acl.server_acl_init();
    server_add_accept(0);

    // Load config files (queued via cmdq, will run in the first loop iteration)
    cfg_mod.cfg_load(startup_client);

    proc_mod.proc_loop(server_proc.?, server_loop);

    job_mod.job_kill_all();
    std.process.exit(0);
}

fn server_send_exit() void {
    cmd_wait_for.cmd_wait_for_flush();

    var clients = std.ArrayList(*T.Client){};
    defer clients.deinit(xm.allocator);
    for (client_registry.clients.items) |cl|
        clients.append(xm.allocator, cl) catch unreachable;

    for (clients.items) |cl| {
        cl.session = null;
        if (cl.flags & T.CLIENT_SUSPENDED != 0) {
            server_client_mod.server_client_lost(cl);
            continue;
        }
        cl.flags |= T.CLIENT_EXIT;
        cl.exit_reason = .server_exited;
    }

    var sessions = std.ArrayList(*T.Session){};
    defer sessions.deinit(xm.allocator);
    var it = sess.sessions.valueIterator();
    while (it.next()) |session_ptr|
        sessions.append(xm.allocator, session_ptr.*) catch unreachable;

    for (sessions.items) |session_ptr| {
        if (sess.session_alive(session_ptr))
            sess.session_destroy(session_ptr, true, "server_send_exit");
    }
}

pub fn server_request_exit() void {
    server_exit = true;
    server_send_exit();
}

// ── Signal handler ────────────────────────────────────────────────────────

export fn server_signal(signo: c_int) void {
    switch (signo) {
        std.posix.SIG.TERM, std.posix.SIG.INT => server_request_exit(),
        std.posix.SIG.CHLD => server_child_signal(),
        std.posix.SIG.USR1 => server_reopen_socket(),
        std.posix.SIG.USR2 => if (server_proc) |proc| proc_mod.proc_toggle_log(proc),
        else => {},
    }
}

fn server_child_signal() void {
    while (true) {
        var status: i32 = 0;
        const pid = std.c.waitpid(-1, &status, std.posix.W.NOHANG | std.posix.W.UNTRACED);
        if (pid <= 0) break;
        log.log_debug("child {d} exited", .{pid});
        job_mod.job_check_died(@intCast(pid), status);
    }
}

// ── Utility ───────────────────────────────────────────────────────────────

pub fn server_add_client(cl: *T.Client) void {
    client_registry.add(cl);
}

pub fn server_remove_client(cl: *T.Client) void {
    client_registry.remove(cl);
}

pub fn server_destroy_session(s: *T.Session) void {
    for (client_registry.clients.items) |cl| {
        if (cl.session == s) {
            if (s.attached > 0) s.attached -= 1;
            cl.session = null;
            if (cl.last_session == s) cl.last_session = null;
            notify.notify_client("client-detached", cl);
            cl.flags |= T.CLIENT_EXIT;
            if (cl.peer) |peer| {
                const retval: i32 = 0;
                _ = proc_mod.proc_send(peer, .exit, -1, @ptrCast(std.mem.asBytes(&retval)), @sizeOf(i32));
            }
        }
    }
}

pub fn server_redraw_session(s: *T.Session) void {
    for (client_registry.clients.items) |cl| {
        if (cl.flags & T.CLIENT_ATTACHED == 0) continue;
        if (cl.session != s) continue;
        cl.flags |= T.CLIENT_REDRAW;
    }
}

pub fn server_redraw_session_group(s: *T.Session) void {
    if (sess.session_group_contains(s)) |group| {
        for (group.sessions.items) |member| {
            server_redraw_session(member);
        }
        return;
    }
    server_redraw_session(s);
}

pub fn server_redraw_window(w: *T.Window) void {
    for (client_registry.clients.items) |cl| {
        if (cl.flags & T.CLIENT_ATTACHED == 0) continue;
        const s = cl.session orelse continue;
        if (!sess.session_has_window(s, w)) continue;
        cl.flags |= T.CLIENT_REDRAWWINDOW;
    }
}

pub fn server_redraw_window_borders(w: *T.Window) void {
    for (client_registry.clients.items) |cl| {
        if (cl.flags & T.CLIENT_ATTACHED == 0) continue;
        const s = cl.session orelse continue;
        if (s.curw == null or s.curw.?.window != w) continue;
        cl.flags |= T.CLIENT_REDRAWBORDERS;
    }
}

pub fn server_redraw_pane(wp: *T.WindowPane) void {
    for (client_registry.clients.items) |cl| {
        if (cl.flags & T.CLIENT_ATTACHED == 0) continue;
        const s = cl.session orelse continue;
        if (s.curw == null or s.curw.?.window != wp.window) continue;
        cl.flags |= T.CLIENT_REDRAWPANES;
    }
}

pub fn server_status_client(cl: *T.Client) void {
    cl.flags |= T.CLIENT_REDRAWSTATUS;
}

pub fn server_status_session(s: *T.Session) void {
    for (client_registry.clients.items) |cl| {
        if (cl.flags & T.CLIENT_ATTACHED == 0) continue;
        if (cl.session != s) continue;
        cl.flags |= T.CLIENT_REDRAWSTATUS;
    }
}

pub fn server_status_session_group(s: *T.Session) void {
    if (sess.session_group_contains(s)) |group| {
        for (group.sessions.items) |member| {
            server_status_session(member);
        }
        return;
    }
    server_status_session(s);
}

pub fn server_status_window(w: *T.Window) void {
    for (client_registry.clients.items) |cl| {
        if (cl.flags & T.CLIENT_ATTACHED == 0) continue;
        const s = cl.session orelse continue;
        if (!sess.session_has_window(s, w)) continue;
        cl.flags |= T.CLIENT_REDRAWSTATUS;
    }
}

test "server status helpers mark attached clients for status-only redraw" {
    const env_mod = @import("environ.zig");

    client_registry.clients.clearRetainingCapacity();
    defer client_registry.clients.clearRetainingCapacity();

    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);

    sess.session_init_globals(xm.allocator);
    win.window_init_globals(xm.allocator);

    const s1 = sess.session_create(null, "server-status-session-1", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("server-status-session-1") != null) sess.session_destroy(s1, false, "test");
    const s2 = sess.session_create(null, "server-status-session-2", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("server-status-session-2") != null) sess.session_destroy(s2, false, "test");
    const s3 = sess.session_create(null, "server-status-session-3", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("server-status-session-3") != null) sess.session_destroy(s3, false, "test");

    const w = win.window_create(8, 2, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    var cause: ?[]u8 = null;
    _ = sess.session_attach(s1, w, 0, &cause) orelse unreachable;
    _ = sess.session_attach(s2, w, 0, &cause) orelse unreachable;
    const w3 = win.window_create(8, 2, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    _ = sess.session_attach(s3, w3, 0, &cause) orelse unreachable;
    s1.curw = sess.winlink_find_by_window(&s1.windows, w);
    s2.curw = sess.winlink_find_by_window(&s2.windows, w);
    s3.curw = sess.winlink_find_by_window(&s3.windows, w3);

    var client1 = T.Client{
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{ .screen = undefined },
        .flags = T.CLIENT_ATTACHED,
        .session = s1,
    };
    defer env_mod.environ_free(client1.environ);
    client1.tty = .{ .client = &client1 };

    var client2 = T.Client{
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{ .screen = undefined },
        .flags = T.CLIENT_ATTACHED,
        .session = s2,
    };
    defer env_mod.environ_free(client2.environ);
    client2.tty = .{ .client = &client2 };

    var client3 = T.Client{
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{ .screen = undefined },
        .flags = T.CLIENT_ATTACHED,
        .session = s3,
    };
    defer env_mod.environ_free(client3.environ);
    client3.tty = .{ .client = &client3 };

    client_registry.add(&client1);
    client_registry.add(&client2);
    client_registry.add(&client3);

    server_status_session(s1);
    try std.testing.expect(client1.flags & T.CLIENT_REDRAWSTATUS != 0);
    try std.testing.expect(client1.flags & T.CLIENT_REDRAWWINDOW == 0);
    try std.testing.expect(client2.flags & T.CLIENT_REDRAWSTATUS == 0);
    try std.testing.expect(client3.flags & T.CLIENT_REDRAWSTATUS == 0);

    client1.flags = T.CLIENT_ATTACHED;
    client2.flags = T.CLIENT_ATTACHED;
    client3.flags = T.CLIENT_ATTACHED;

    server_status_window(w);
    try std.testing.expect(client1.flags & T.CLIENT_REDRAWSTATUS != 0);
    try std.testing.expect(client2.flags & T.CLIENT_REDRAWSTATUS != 0);
    try std.testing.expect(client3.flags & T.CLIENT_REDRAWSTATUS == 0);
    try std.testing.expect(client1.flags & T.CLIENT_REDRAWWINDOW == 0);
    try std.testing.expect(client2.flags & T.CLIENT_REDRAWWINDOW == 0);
}

test "server loop keeps server alive while shared jobs still run" {
    client_registry.clients.clearRetainingCapacity();
    defer client_registry.clients.clearRetainingCapacity();
    defer job_mod.job_reset_all();

    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);

    sess.session_init_globals(xm.allocator);
    win.window_init_globals(xm.allocator);

    opts.options_set_number(opts.global_options, "exit-empty", 1);
    opts.options_set_number(opts.global_options, "exit-unattached", 1);
    const old_server_exit = server_exit;
    defer server_exit = old_server_exit;
    server_exit = false;

    const job = job_mod.job_register("sleep 30", 0);
    job_mod.job_started(job, 99, -1);

    try std.testing.expect(!server_loop());

    job_mod.job_finished(job, 0);
    try std.testing.expect(server_loop());
}

test "server SIGTERM drains sessions and leaves the loop to exit naturally" {
    const env_mod = @import("environ.zig");

    client_registry.clients.clearRetainingCapacity();
    defer client_registry.clients.clearRetainingCapacity();

    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    opts.options_set_number(opts.global_options, "exit-empty", 1);
    opts.options_set_number(opts.global_options, "exit-unattached", 1);

    sess.session_init_globals(xm.allocator);
    win.window_init_globals(xm.allocator);

    const old_server_exit = server_exit;
    defer server_exit = old_server_exit;
    server_exit = false;

    const shutdown_session = sess.session_create(null, "server-signal-shutdown", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);

    var client = T.Client{
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{ .screen = undefined },
        .flags = T.CLIENT_ATTACHED,
        .session = shutdown_session,
    };
    defer env_mod.environ_free(client.environ);
    client.tty = .{ .client = &client };
    client_registry.add(&client);

    server_signal(std.posix.SIG.TERM);

    try std.testing.expect(server_exit);
    try std.testing.expect(client.flags & T.CLIENT_EXIT != 0);
    try std.testing.expectEqual(T.ClientExitReason.server_exited, client.exit_reason);
    try std.testing.expect(client.session == null);
    try std.testing.expect(sess.session_find("server-signal-shutdown") == null);
    try std.testing.expect(!server_loop());

    client_registry.clients.clearRetainingCapacity();
    try std.testing.expect(server_loop());
}

test "server SIGUSR1 reopens the socket and restores attached execute bits" {
    const env_mod = @import("environ.zig");

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const real = try tmp.dir.realpathAlloc(xm.allocator, ".");
    defer xm.allocator.free(real);

    const test_socket_path = try std.fs.path.join(xm.allocator, &.{ real, "server.sock" });
    defer xm.allocator.free(test_socket_path);

    const old_socket_path = socket_path;
    defer socket_path = old_socket_path;
    socket_path = test_socket_path;

    const old_server_fd = server_fd;
    defer server_fd = old_server_fd;
    server_fd = -1;
    defer if (server_fd >= 0) std.posix.close(server_fd);

    const old_server_client_flags = server_client_flags;
    defer server_client_flags = old_server_client_flags;
    server_client_flags = T.CLIENT_DEFAULTSOCKET;

    const old_server_accept_ev = server_accept_ev;
    defer server_accept_ev = old_server_accept_ev;
    server_accept_ev = null;

    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);

    sess.session_init_globals(xm.allocator);

    const s = sess.session_create(null, "server-signal-usr1", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("server-signal-usr1") != null) sess.session_destroy(s, false, "test");
    s.attached = 1;

    var cause: ?[]u8 = null;
    server_fd = server_create_socket(server_client_flags, &cause);
    defer if (cause) |msg| xm.allocator.free(msg);
    try std.testing.expect(server_fd >= 0);

    const before = try std.fs.cwd().statFile(socket_path);
    try std.testing.expectEqual(@as(std.fs.File.Mode, 0o660), before.mode & 0o777);

    const original_fd = server_fd;
    server_signal(std.posix.SIG.USR1);

    try std.testing.expect(server_fd >= 0);
    try std.testing.expect(server_fd != original_fd);
    try std.testing.expect(std.c.fcntl(original_fd, std.posix.F.GETFD, @as(c_int, 0)) == -1);

    const after = try std.fs.cwd().statFile(socket_path);
    try std.testing.expectEqual(@as(std.fs.File.Mode, 0o770), after.mode & 0o777);
}

test "server SIGUSR2 toggles server proc logging" {
    const old_server_proc = server_proc;
    defer server_proc = old_server_proc;

    try std.testing.expectEqual(@as(u32, 0), log.log_get_level());

    var server_proc_value = T.ZmuxProc{
        .name = "server",
        .peers = .{},
    };
    defer server_proc_value.peers.deinit(xm.allocator);

    server_proc = &server_proc_value;

    server_signal(std.posix.SIG.USR2);
    try std.testing.expectEqual(@as(u32, 1), log.log_get_level());

    server_signal(std.posix.SIG.USR2);
    try std.testing.expectEqual(@as(u32, 0), log.log_get_level());
}

test "server session-group redraw and status helpers fan out across grouped sessions" {
    const env_mod = @import("environ.zig");

    client_registry.clients.clearRetainingCapacity();

    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);

    sess.session_init_globals(xm.allocator);
    win.window_init_globals(xm.allocator);

    const leader = sess.session_create(null, "server-group-a", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("server-group-a") != null) sess.session_destroy(leader, false, "test");
    const peer = sess.session_create(null, "server-group-b", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("server-group-b") != null) sess.session_destroy(peer, false, "test");
    const outsider = sess.session_create(null, "server-group-c", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("server-group-c") != null) sess.session_destroy(outsider, false, "test");

    const group = sess.session_group_new("server-group");
    sess.session_group_add(group, leader);
    sess.session_group_add(group, peer);

    const shared_w = win.window_create(8, 2, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    var cause: ?[]u8 = null;
    const leader_wl = sess.session_attach(leader, shared_w, 0, &cause).?;
    leader.curw = leader_wl;
    peer.curw = sess.winlink_find_by_index(&peer.windows, leader_wl.idx).?;

    const outsider_w = win.window_create(8, 2, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    outsider.curw = sess.session_attach(outsider, outsider_w, 0, &cause).?;

    var leader_client = T.Client{
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{ .screen = undefined },
        .flags = T.CLIENT_ATTACHED,
        .session = leader,
    };
    defer env_mod.environ_free(leader_client.environ);
    leader_client.tty = .{ .client = &leader_client };

    var peer_client = T.Client{
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{ .screen = undefined },
        .flags = T.CLIENT_ATTACHED,
        .session = peer,
    };
    defer env_mod.environ_free(peer_client.environ);
    peer_client.tty = .{ .client = &peer_client };

    var outsider_client = T.Client{
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{ .screen = undefined },
        .flags = T.CLIENT_ATTACHED,
        .session = outsider,
    };
    defer env_mod.environ_free(outsider_client.environ);
    outsider_client.tty = .{ .client = &outsider_client };

    client_registry.add(&leader_client);
    client_registry.add(&peer_client);
    client_registry.add(&outsider_client);
    defer client_registry.clients.clearRetainingCapacity();

    server_redraw_session_group(leader);
    try std.testing.expect(leader_client.flags & T.CLIENT_REDRAW != 0);
    try std.testing.expect(peer_client.flags & T.CLIENT_REDRAW != 0);
    try std.testing.expect(outsider_client.flags & T.CLIENT_REDRAW == 0);

    leader_client.flags = T.CLIENT_ATTACHED;
    peer_client.flags = T.CLIENT_ATTACHED;
    outsider_client.flags = T.CLIENT_ATTACHED;

    server_status_session_group(leader);
    try std.testing.expect(leader_client.flags & T.CLIENT_REDRAWSTATUS != 0);
    try std.testing.expect(peer_client.flags & T.CLIENT_REDRAWSTATUS != 0);
    try std.testing.expect(outsider_client.flags & T.CLIENT_REDRAWSTATUS == 0);
    try std.testing.expect(leader_client.flags & T.CLIENT_REDRAWWINDOW == 0);
    try std.testing.expect(peer_client.flags & T.CLIENT_REDRAWWINDOW == 0);
}

test "server border redraw helper only marks attached clients viewing the target window" {
    const env_mod = @import("environ.zig");

    client_registry.clients.clearRetainingCapacity();
    defer client_registry.clients.clearRetainingCapacity();

    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);

    sess.session_init_globals(xm.allocator);
    win.window_init_globals(xm.allocator);

    const s1 = sess.session_create(null, "server-border-session-1", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("server-border-session-1") != null) sess.session_destroy(s1, false, "test");
    const s2 = sess.session_create(null, "server-border-session-2", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("server-border-session-2") != null) sess.session_destroy(s2, false, "test");

    const w1 = win.window_create(80, 24, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    const w2 = win.window_create(80, 24, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    var cause: ?[]u8 = null;
    const wl1 = sess.session_attach(s1, w1, -1, &cause).?;
    const wl2 = sess.session_attach(s2, w2, -1, &cause).?;
    s1.curw = wl1;
    s2.curw = wl2;

    const env1 = env_mod.environ_create();
    defer env_mod.environ_free(env1);
    const env2 = env_mod.environ_create();
    defer env_mod.environ_free(env2);
    const env3 = env_mod.environ_create();
    defer env_mod.environ_free(env3);

    var client1 = T.Client{ .environ = env1, .tty = undefined, .status = .{ .screen = undefined }, .session = s1, .flags = T.CLIENT_ATTACHED };
    var client2 = T.Client{ .environ = env2, .tty = undefined, .status = .{ .screen = undefined }, .session = s2, .flags = T.CLIENT_ATTACHED };
    var client3 = T.Client{ .environ = env3, .tty = undefined, .status = .{ .screen = undefined }, .session = s1, .flags = 0 };
    client_registry.clients.append(xm.allocator, &client1) catch unreachable;
    client_registry.clients.append(xm.allocator, &client2) catch unreachable;
    client_registry.clients.append(xm.allocator, &client3) catch unreachable;

    server_redraw_window_borders(w1);

    try std.testing.expect(client1.flags & T.CLIENT_REDRAWBORDERS != 0);
    try std.testing.expect(client2.flags & T.CLIENT_REDRAWBORDERS == 0);
    try std.testing.expect(client3.flags & T.CLIENT_REDRAWBORDERS == 0);
}

test "server pane redraw helper only marks attached clients viewing the target pane window" {
    const env_mod = @import("environ.zig");

    client_registry.clients.clearRetainingCapacity();
    defer client_registry.clients.clearRetainingCapacity();

    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);

    sess.session_init_globals(xm.allocator);
    win.window_init_globals(xm.allocator);

    const s1 = sess.session_create(null, "server-pane-session-1", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("server-pane-session-1") != null) sess.session_destroy(s1, false, "test");
    const s2 = sess.session_create(null, "server-pane-session-2", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("server-pane-session-2") != null) sess.session_destroy(s2, false, "test");

    const w1 = win.window_create(80, 24, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    const w2 = win.window_create(80, 24, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    var cause: ?[]u8 = null;
    const wl1 = sess.session_attach(s1, w1, -1, &cause).?;
    const wl2 = sess.session_attach(s2, w2, -1, &cause).?;
    s1.curw = wl1;
    s2.curw = wl2;

    const pane = win.window_add_pane(w1, null, 80, 24);

    const env1 = env_mod.environ_create();
    defer env_mod.environ_free(env1);
    const env2 = env_mod.environ_create();
    defer env_mod.environ_free(env2);
    const env3 = env_mod.environ_create();
    defer env_mod.environ_free(env3);

    var client1 = T.Client{ .environ = env1, .tty = undefined, .status = .{ .screen = undefined }, .session = s1, .flags = T.CLIENT_ATTACHED };
    var client2 = T.Client{ .environ = env2, .tty = undefined, .status = .{ .screen = undefined }, .session = s2, .flags = T.CLIENT_ATTACHED };
    var client3 = T.Client{ .environ = env3, .tty = undefined, .status = .{ .screen = undefined }, .session = s1, .flags = 0 };
    client_registry.clients.append(xm.allocator, &client1) catch unreachable;
    client_registry.clients.append(xm.allocator, &client2) catch unreachable;
    client_registry.clients.append(xm.allocator, &client3) catch unreachable;

    server_redraw_pane(pane);

    try std.testing.expect(client1.flags & T.CLIENT_REDRAWPANES != 0);
    try std.testing.expect(client1.flags & T.CLIENT_REDRAWWINDOW == 0);
    try std.testing.expect(client2.flags & T.CLIENT_REDRAWPANES == 0);
    try std.testing.expect(client3.flags & T.CLIENT_REDRAWPANES == 0);
}
