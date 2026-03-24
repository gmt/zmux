// Copyright (c) 2026 Greg Turner <gmt@pobox.com>
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
// Ported from tmux/client.c
// Original copyright:
//   Copyright (c) 2007 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

//! client.zig – client process: connect/start server, send commands.

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const log = @import("log.zig");
const proc_mod = @import("proc.zig");
const server_mod = @import("server.zig");
const protocol = @import("tmux-protocol.zig");
const c = @import("c.zig");
const opts = @import("options.zig");
const env_mod = @import("environ.zig");
const cmd_mod = @import("cmd.zig");

// ── Client globals ────────────────────────────────────────────────────────

var client_proc: ?*T.TmuxProc = null;
var client_peer: ?*T.TmuxPeer = null;
var client_flags: u64 = 0;
var client_exitreason: T.ClientExitReason = .none;
var client_exitsession: ?[]u8 = null;
var client_exitmessage: ?[]u8 = null;
var client_retval: i32 = 0;

// ── Socket connection ─────────────────────────────────────────────────────

fn client_get_lock(lockfile: []const u8) i32 {
    const lockfile_z = xm.xm_dupeZ(lockfile);
    defer xm.allocator.free(lockfile_z);
    const fd = std.c.open(lockfile_z, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o600));
    if (fd < 0) return -1;
    const LOCK_EX: c_int = 2;
    const LOCK_NB: c_int = 4;
    if (std.c.flock(fd, LOCK_EX | LOCK_NB) == -1) {
        if (std.c._errno().* == @intFromEnum(std.posix.E.AGAIN))
            return -2;
        std.posix.close(fd);
        return -1;
    }
    return fd;
}

/// Connect to the server socket, starting the server if necessary.
pub fn client_connect(
    base: *c.libevent.event_base,
    path: []const u8,
    flags: u64,
) i32 {
    var sa: std.posix.sockaddr.un = std.mem.zeroes(std.posix.sockaddr.un);
    sa.family = std.posix.AF.UNIX;
    if (path.len >= sa.path.len) {
        std.c._errno().* = @intFromEnum(std.posix.E.NAMETOOLONG);
        return -1;
    }
    @memcpy(sa.path[0..path.len], path);

    var locked = false;
    var lockfd: i32 = -1;
    var lockfile: ?[]u8 = null;

    retry: while (true) {
        const fd = std.c.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0);
        if (fd < 0) return -1;

        log.log_debug("trying connect to {s}", .{path});
        if (std.c.connect(fd, @ptrCast(&sa), @sizeOf(std.posix.sockaddr.un)) == 0) {
            if (locked and lockfd >= 0) {
                if (lockfile) |lf| xm.allocator.free(lf);
                std.posix.close(lockfd);
            }
            set_blocking(fd, false);
            return fd;
        }

        const errno_val: std.posix.E = @enumFromInt(std.c._errno().*);
        if (errno_val != .CONNREFUSED and errno_val != .NOENT) {
            std.posix.close(fd);
            return -1;
        }
        std.posix.close(fd);

        if (flags & T.CLIENT_NOSTARTSERVER != 0) return -1;
        if (flags & T.CLIENT_STARTSERVER == 0) return -1;

        if (!locked) {
            lockfile = xm.xasprintf("{s}.lock", .{path});
            lockfd = client_get_lock(lockfile.?);
            if (lockfd == -2) {
                if (lockfile) |lf| xm.allocator.free(lf);
                lockfile = null;
                continue :retry;
            }
            locked = true;
            continue :retry; // retry once with lock held
        }

        // Start the server
        if (lockfd >= 0) {
            _ = std.posix.unlink(path) catch {};
        }
        const server_fd = server_mod.server_start(client_proc.?, flags, base, lockfd, lockfile);
        if (lockfd >= 0) {
            lockfile = null; // ownership transferred to server_start
        }
        set_blocking(server_fd, false);
        return server_fd;
    }
}

fn set_blocking(fd: i32, state: bool) void {
    const flags = std.c.fcntl(fd, std.posix.F.GETFL, @as(c_int, 0));
    if (flags < 0) return;
    const O_NONBLOCK: c_int = 0x800;
    const new_flags: c_int = if (state) flags & ~O_NONBLOCK else flags | O_NONBLOCK;
    _ = std.c.fcntl(fd, std.posix.F.SETFL, new_flags);
}

// ── Identify messages ─────────────────────────────────────────────────────

fn client_send_identify(feat: i32) void {
    const peer = client_peer orelse return;

    // Flags
    _ = proc_mod.proc_send(peer, .identify_longflags, -1, std.mem.asBytes(&client_flags).ptr, @sizeOf(u64));

    // TERM
    const term = std.posix.getenv("TERM") orelse "screen";
    _ = proc_mod.proc_send(peer, .identify_term, -1, term.ptr, term.len + 1);

    // Identify - TTY name (via /proc/self/fd/0)
    var ttyname_buf: [64]u8 = std.mem.zeroes([64]u8);
    if (std.posix.readlink("/proc/self/fd/0", &ttyname_buf)) |name| {
        _ = proc_mod.proc_send(peer, .identify_ttyname, -1, name.ptr, name.len + 1);
    } else |_| {}

    // CWD
    var cwd_buf: [std.posix.PATH_MAX]u8 = undefined;
    if (std.posix.getcwd(&cwd_buf)) |cwd_slice| {
        _ = proc_mod.proc_send(peer, .identify_cwd, -1, cwd_slice.ptr, cwd_slice.len + 1);
    } else |_| {}

    // Env
    var env_ptr: [*c]const [*c]const u8 = std.c.environ;
    while (env_ptr.* != null) : (env_ptr += 1) {
        const var_str = std.mem.span(env_ptr.*);
        _ = proc_mod.proc_send(peer, .identify_environ, -1, var_str.ptr, var_str.len + 1);
    }

    // Client PID
    const pid = std.os.linux.getpid();
    _ = proc_mod.proc_send(peer, .identify_clientpid, -1, std.mem.asBytes(&pid).ptr, @sizeOf(std.posix.pid_t));

    // Features
    _ = proc_mod.proc_send(peer, .identify_features, -1, std.mem.asBytes(&feat).ptr, @sizeOf(i32));

    // Done
    _ = proc_mod.proc_send(peer, .identify_done, -1, null, 0);
}

// ── Dispatch (client side) ────────────────────────────────────────────────

export fn client_dispatch(imsg_ptr: ?*c.imsg.imsg, _arg: ?*anyopaque) void {
    _ = _arg;
    if (imsg_ptr == null) {
        // Server disconnected
        client_exitreason = .lost_server;
        proc_mod.proc_exit(client_proc.?);
        return;
    }
    const imsg_msg = imsg_ptr.?;
    const msg_type = std.meta.intToEnum(protocol.MsgType, imsg_msg.hdr.type) catch return;

    switch (msg_type) {
        .version => {
            log.log_warn("server version mismatch", .{});
            client_exitreason = .lost_server;
            proc_mod.proc_exit(client_proc.?);
        },
        .exit, .exiting => {
            client_exitreason = .exited;
            const data_len = imsg_msg.hdr.len -% @sizeOf(c.imsg.imsg_hdr);
            if (data_len >= @sizeOf(i32) and imsg_msg.data != null) {
                const data: *const i32 = @ptrCast(@alignCast(imsg_msg.data.?));
                client_retval = data.*;
            }
            proc_mod.proc_exit(client_proc.?);
        },
        .write => {
            // Server sent output text for us to print (stream_id:i32 + text)
            const data_len = imsg_msg.hdr.len -% @sizeOf(c.imsg.imsg_hdr);
            if (data_len > @sizeOf(i32) and imsg_msg.data != null) {
                const raw: [*]const u8 = @ptrCast(imsg_msg.data.?);
                const text = raw[@sizeOf(i32)..data_len];
                _ = std.fs.File.stdout().writeAll(text) catch {};
            }
        },
        .exited => {
            proc_mod.proc_exit(client_proc.?);
        },
        .detach => {
            client_exitreason = .detached;
            proc_mod.proc_exit(client_proc.?);
        },
        .ready => {
            // Server is ready
        },
        else => {},
    }
}

// ── Main client entry ─────────────────────────────────────────────────────

pub fn client_main(
    base: *c.libevent.event_base,
    argc: i32,
    argv: [*]const [*:0]const u8,
    flags: u64,
    feat: i32,
) i32 {
    // Determine what message to send
    var msg_type: protocol.MsgType = .command;
    var start_server = false;

    if (argc == 0) {
        msg_type = .command;
        start_server = true;
    } else {
        // Parse to see if the command requests server start
    var argv_slice: std.ArrayList([]const u8) = .{};
    defer argv_slice.deinit(xm.allocator);
        var i: usize = 0;
        while (i < @as(usize, @intCast(argc))) : (i += 1) {
            argv_slice.append(xm.allocator, std.mem.span(argv[i])) catch unreachable;
        }
        var cause: ?[]u8 = null;
        if (cmd_mod.cmd_parse_one(argv_slice.items, null, &cause)) |parsed| {
            if (parsed.entry.flags & T.CMD_STARTSERVER != 0) start_server = true;
            cmd_mod.cmd_free(parsed);
        } else |_| {}
        if (cause) |c_err| xm.allocator.free(c_err);
    }

    client_flags = flags | if (start_server) T.CLIENT_STARTSERVER else 0;

    // Start client proc
    client_proc = proc_mod.proc_start("client");
    proc_mod.proc_set_signals(client_proc.?, client_signal);

    // Connect
    const fd = client_connect(base, server_mod.socket_path, client_flags);
    if (fd < 0) {
        const errno_val: std.posix.E = @enumFromInt(std.c._errno().*);
        if (errno_val == .CONNREFUSED) {
            log.log_warn("no server running on {s}", .{server_mod.socket_path});
        } else {
            log.log_warn("error connecting to {s}: {}", .{ server_mod.socket_path, errno_val });
        }
        return 1;
    }

    client_peer = proc_mod.proc_add_peer(client_proc.?, fd, client_dispatch, null);

    // Send identity
    client_send_identify(feat);

    // Send the command
    if (argc > 0) {
        // Pack argc + argv into MSG_COMMAND
        var buf: std.ArrayList(u8) = .{};
        defer buf.deinit(xm.allocator);
        const msg_cmd = protocol.MsgCommand{ .argc = argc };
        buf.appendSlice(xm.allocator, std.mem.asBytes(&msg_cmd)) catch unreachable;
        var i: usize = 0;
        while (i < @as(usize, @intCast(argc))) : (i += 1) {
            const s = std.mem.span(argv[i]);
            buf.appendSlice(xm.allocator, s) catch unreachable;
            buf.append(xm.allocator, 0) catch unreachable;
        }
        _ = proc_mod.proc_send(client_peer.?, .command, -1, buf.items.ptr, buf.items.len);
    } else {
        // Default command: new-session or attach
        const cmd_str = "new-session";
        var buf: std.ArrayList(u8) = .{};
        defer buf.deinit(xm.allocator);
        const msg_cmd = protocol.MsgCommand{ .argc = 1 };
        buf.appendSlice(xm.allocator, std.mem.asBytes(&msg_cmd)) catch unreachable;
        buf.appendSlice(xm.allocator, cmd_str) catch unreachable;
        buf.append(xm.allocator, 0) catch unreachable;
        _ = proc_mod.proc_send(client_peer.?, .command, -1, buf.items.ptr, buf.items.len);
    }

    // Run the event loop until done
    proc_mod.proc_loop(client_proc.?, null);
    proc_mod.proc_clear_signals(client_proc.?, true);

    return client_retval;
}

export fn client_signal(signo: c_int) void {
    switch (signo) {
        std.posix.SIG.TERM, std.posix.SIG.INT => {
            client_exitreason = .terminated;
            proc_mod.proc_exit(client_proc.?);
        },
        else => {},
    }
}
