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
const protocol = @import("zmux-protocol.zig");
const file_mod = @import("file.zig");
const c = @import("c.zig");
const cmd_mod = @import("cmd.zig");
const tty_term = @import("tty-term.zig");

extern fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern fn system(command: [*:0]const u8) c_int;

var client_proc: ?*T.ZmuxProc = null;
var client_peer: ?*T.ZmuxPeer = null;
var client_flags: u64 = 0;
var client_exitreason: T.ClientExitReason = .none;
var client_exitsession: ?[]u8 = null;
var client_exitmessage: ?[]u8 = null;
var client_exec_command: ?[]u8 = null;
var client_exec_shell: ?[]u8 = null;
var client_shell_command: ?[]u8 = null;
var client_retval: i32 = 0;
var client_control_input: std.ArrayList(u8) = .{};
var client_attached = false;
var client_suspended = false;
var client_suspend_restore_attached = false;
var client_saved_tio: c.posix_sys.termios = undefined;
var client_have_saved_tio = false;
var client_suspend_signal_hook: ?*const fn () void = null;

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
            continue :retry;
        }

        if (lockfd >= 0) {
            _ = std.posix.unlink(path) catch {};
        }
        const server_fd = server_mod.server_start(client_proc.?, flags, base, lockfd, lockfile);
        if (lockfd >= 0) {
            lockfile = null;
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

fn client_compat_tmux() bool {
    const zmux_mod = @import("zmux.zig");
    return std.mem.eql(u8, zmux_mod.compat_name, "tmux");
}

fn client_wire_longflags() u64 {
    if (!client_compat_tmux()) return client_flags;

    // tmux's client flag ABI is part of the wire contract in compat mode.
    // Translate the startup-relevant bits rather than sending zmux-local values.
    var out: u64 = 0;
    if (client_flags & T.CLIENT_TERMINAL != 0) out |= 0x1;
    if (client_flags & T.CLIENT_LOGIN != 0) out |= 0x2;
    if (client_flags & T.CLIENT_EXIT != 0) out |= 0x4;
    if (client_flags & T.CLIENT_CONTROL != 0) out |= 0x2000;
    if (client_flags & T.CLIENT_CONTROLCONTROL != 0) out |= 0x4000;
    if (client_flags & T.CLIENT_UTF8 != 0) out |= 0x10000;
    if (client_flags & T.CLIENT_IDENTIFIED != 0) out |= 0x40000;
    if (client_flags & T.CLIENT_ATTACHED != 0) out |= 0x80;
    if (client_flags & T.CLIENT_STARTSERVER != 0) out |= 0x10000000;
    if (client_flags & T.CLIENT_NOSTARTSERVER != 0) out |= 0x1000;
    if (client_flags & T.CLIENT_READONLY != 0) out |= 0x800;
    if (client_flags & T.CLIENT_IGNORESIZE != 0) out |= 0x20000;
    if (client_flags & T.CLIENT_NOFORK != 0) out |= 0x40000000;
    if (client_flags & T.CLIENT_DEFAULTSOCKET != 0) out |= 0x8000000;
    if (client_flags & T.CLIENT_SIZECHANGED != 0) out |= 0x400000;
    if (client_flags & T.CLIENT_STATUSOFF != 0) out |= 0x800000;
    if (client_flags & T.CLIENT_SUSPENDED != 0) out |= 0x40;
    if (client_flags & T.CLIENT_CONTROL_NOOUTPUT != 0) out |= 0x4000000;
    if (client_flags & T.CLIENT_ACTIVEPANE != 0) out |= 0x80000000;
    if (client_flags & T.CLIENT_CONTROL_PAUSEAFTER != 0) out |= 0x100000000;
    if (client_flags & T.CLIENT_CONTROL_WAITEXIT != 0) out |= 0x200000000;
    if (client_flags & T.CLIENT_WINDOWSIZECHANGED != 0) out |= 0x400000000;
    if (client_flags & T.CLIENT_NO_DETACH_ON_DESTROY != 0) out |= 0x8000000000;
    if (client_flags & T.CLIENT_DEAD != 0) out |= 0x200;
    if (client_flags & T.CLIENT_REPEAT != 0) out |= 0x20;
    return out;
}

fn client_send_identify(feat: i32) void {
    const peer = client_peer orelse return;
    const wire_flags = client_wire_longflags();
    const term = std.posix.getenv("TERM") orelse "";
    const ttyname = client_ttyname(std.posix.STDIN_FILENO) orelse "";
    const have_terminal = client_has_terminal();

    _ = proc_mod.proc_send(peer, .identify_longflags, -1, std.mem.asBytes(&wire_flags).ptr, @sizeOf(u64));
    if (client_compat_tmux()) {
        _ = proc_mod.proc_send(peer, .identify_longflags, -1, std.mem.asBytes(&wire_flags).ptr, @sizeOf(u64));
    }

    _ = proc_mod.proc_send(peer, .identify_term, -1, term.ptr, term.len + 1);
    _ = proc_mod.proc_send(peer, .identify_features, -1, std.mem.asBytes(&feat).ptr, @sizeOf(i32));

    _ = proc_mod.proc_send(peer, .identify_ttyname, -1, ttyname.ptr, ttyname.len + 1);

    var cwd_buf: [std.posix.PATH_MAX]u8 = undefined;
    if (std.posix.getcwd(&cwd_buf)) |cwd_slice| {
        _ = proc_mod.proc_send(peer, .identify_cwd, -1, cwd_slice.ptr, cwd_slice.len + 1);
    } else |_| {}

    if (have_terminal and term.len != 0) {
        const term_caps = tty_term.readTermCaps(term, std.posix.STDIN_FILENO) catch xm.allocator.alloc([]u8, 0) catch unreachable;
        defer tty_term.freeTermCaps(term_caps);
        for (term_caps) |cap| {
            _ = proc_mod.proc_send(peer, .identify_terminfo, -1, cap.ptr, cap.len + 1);
        }
    }

    const stdin_fd = c.posix_sys.dup(std.posix.STDIN_FILENO);
    if (stdin_fd != -1) {
        _ = proc_mod.proc_send(peer, .identify_stdin, stdin_fd, null, 0);
    }
    const stdout_fd = c.posix_sys.dup(std.posix.STDOUT_FILENO);
    if (stdout_fd != -1) {
        _ = proc_mod.proc_send(peer, .identify_stdout, stdout_fd, null, 0);
    }

    var env_ptr: [*c]const [*c]const u8 = std.c.environ;
    while (env_ptr.* != null) : (env_ptr += 1) {
        const var_str = std.mem.span(env_ptr.*);
        _ = proc_mod.proc_send(peer, .identify_environ, -1, var_str.ptr, var_str.len + 1);
    }

    const pid = std.os.linux.getpid();
    _ = proc_mod.proc_send(peer, .identify_clientpid, -1, std.mem.asBytes(&pid).ptr, @sizeOf(std.posix.pid_t));

    _ = proc_mod.proc_send(peer, .identify_done, -1, null, 0);
}

export fn client_dispatch(imsg_ptr: ?*c.imsg.imsg, _arg: ?*anyopaque) void {
    _ = _arg;
    if (imsg_ptr == null) {
        client_exitreason = .lost_server;
        proc_mod.proc_exit(client_proc.?);
        return;
    }
    const imsg_msg = imsg_ptr.?;
    const msg_type = std.meta.intToEnum(protocol.MsgType, imsg_msg.hdr.type) catch return;

    switch (msg_type) {
        .version => {
            const zmux_mod = @import("zmux.zig");
            var buf: [80]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "server protocol version mismatch; restart {s} server\n", .{zmux_mod.compat_name}) catch "server protocol version mismatch; restart zmux server\n";
            _ = std.fs.File.stderr().writeAll(msg) catch {};
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
        .shutdown => {
            client_exitreason = .lost_server;
            proc_mod.proc_exit(client_proc.?);
        },
        .write => file_mod.clientHandleWriteData(imsg_msg),
        .read_open => {
            const peer = client_peer orelse return;
            file_mod.clientHandleReadOpen(peer, imsg_msg, client_flags & T.CLIENT_CONTROL == 0, true);
        },
        .read_cancel => file_mod.clientHandleReadCancel(imsg_msg),
        .write_open => {
            const peer = client_peer orelse return;
            file_mod.clientHandleWriteOpen(peer, imsg_msg, client_flags & T.CLIENT_CONTROL == 0, true);
        },
        .write_close => file_mod.clientHandleWriteClose(imsg_msg),
        .flags => {
            const data_len = imsg_msg.hdr.len -% @sizeOf(c.imsg.imsg_hdr);
            if (data_len < @sizeOf(u64) or imsg_msg.data == null) return;
            @memcpy(std.mem.asBytes(&client_flags), @as([*]const u8, @ptrCast(imsg_msg.data.?))[0..@sizeOf(u64)]);
        },
        .shell => {
            const data_len = imsg_msg.hdr.len -% @sizeOf(c.imsg.imsg_hdr);
            if (data_len == 0 or imsg_msg.data == null) return;
            const raw: [*]const u8 = @ptrCast(imsg_msg.data.?);
            if (raw[data_len - 1] != 0) return;

            const command = client_shell_command orelse return;
            client_shell_command = null;
            client_exec(raw[0 .. data_len - 1], command);
        },
        .exited => {
            proc_mod.proc_exit(client_proc.?);
        },
        .detach, .detachkill => {
            const data_len = imsg_msg.hdr.len -% @sizeOf(c.imsg.imsg_hdr);
            if (imsg_msg.data == null or !client_record_detach(msg_type, @as([*]const u8, @ptrCast(imsg_msg.data.?))[0..data_len])) return;
            proc_mod.proc_exit(client_proc.?);
        },
        .exec => {
            const data_len = imsg_msg.hdr.len -% @sizeOf(c.imsg.imsg_hdr);
            if (imsg_msg.data == null or !client_record_exec(@as([*]const u8, @ptrCast(imsg_msg.data.?))[0..data_len])) return;
            proc_mod.proc_exit(client_proc.?);
        },
        .ready => {
            if (client_flags & T.CLIENT_CONTROL == 0) {
                client_enter_attached_mode();
                client_send_resize();
            }
        },
        .lock => {
            const data_len = imsg_msg.hdr.len -% @sizeOf(c.imsg.imsg_hdr);
            if (data_len == 0 or imsg_msg.data == null) return;
            const raw: [*]const u8 = @ptrCast(imsg_msg.data.?);
            if (raw[data_len - 1] != 0) return;
            client_handle_lock_command(raw[0 .. data_len - 1]);
        },
        .@"suspend" => {
            const data_len = imsg_msg.hdr.len -% @sizeOf(c.imsg.imsg_hdr);
            if (data_len != 0) return;
            client_handle_suspend();
        },
        else => {},
    }
}

fn client_clear_exec_request() void {
    if (client_exec_command) |cmd| xm.allocator.free(cmd);
    if (client_exec_shell) |shell| xm.allocator.free(shell);
    client_exec_command = null;
    client_exec_shell = null;
}

fn client_clear_shell_command() void {
    if (client_shell_command) |cmd| xm.allocator.free(cmd);
    client_shell_command = null;
}

fn client_set_shell_command(shell_command: ?[]const u8) void {
    client_clear_shell_command();
    if (shell_command) |cmd| client_shell_command = xm.xstrdup(cmd);
}

fn client_record_detach(msg_type: protocol.MsgType, data: []const u8) bool {
    if (data.len == 0 or data[data.len - 1] != 0) return false;

    if (client_exitsession) |session| xm.allocator.free(session);
    client_exitsession = xm.xstrdup(data[0 .. data.len - 1]);
    client_exitreason = switch (msg_type) {
        .detachkill => .detached_hup,
        else => .detached,
    };
    return true;
}

fn client_record_exec(data: []const u8) bool {
    if (data.len == 0 or data[data.len - 1] != 0) return false;

    const command_end = std.mem.indexOfScalar(u8, data, 0) orelse return false;
    if (command_end + 1 >= data.len) return false;

    const shell_field = data[command_end + 1 ..];
    const shell_end = std.mem.indexOfScalar(u8, shell_field, 0) orelse return false;
    if (shell_end == 0 or command_end + 1 + shell_end + 1 != data.len) return false;

    client_clear_exec_request();
    client_exec_command = xm.xstrdup(data[0..command_end]);
    client_exec_shell = xm.xstrdup(shell_field[0..shell_end]);
    return true;
}

fn client_exec(shell: []const u8, command: []const u8) noreturn {
    const shell_z = xm.xm_dupeZ(shell);
    const shell_name_z = xm.xm_dupeZ(std.fs.path.basename(shell));
    const command_z = xm.xm_dupeZ(command);

    _ = setenv("SHELL", shell_z.ptr, 1);
    var argv = [_:null]?[*:0]const u8{ shell_name_z.ptr, "-c", command_z.ptr, null };
    _ = std.c.execve(shell_z, @ptrCast(&argv), std.c.environ);
    std.process.exit(1);
}

fn client_enter_attached_mode() void {
    client_attached = true;
}

fn client_leave_attached_mode() void {
    if (client_have_saved_tio) {
        _ = c.posix_sys.tcsetattr(0, c.posix_sys.TCSANOW, &client_saved_tio);
    }
    client_attached = false;
}

fn client_send_resize() void {
    const peer = client_peer orelse return;
    _ = proc_mod.proc_send(peer, .resize, -1, null, 0);
}

fn client_has_terminal() bool {
    return c.posix_sys.isatty(std.posix.STDIN_FILENO) != 0;
}

fn client_ttyname(fd: i32) ?[]const u8 {
    const raw = c.posix_sys.ttyname(fd) orelse return null;
    return std.mem.span(raw);
}

fn client_send_command(argv: anytype) void {
    const peer = client_peer orelse return;

    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(xm.allocator);

    const msg_cmd = protocol.MsgCommand{ .argc = @intCast(argv.len) };
    buf.appendSlice(xm.allocator, std.mem.asBytes(&msg_cmd)) catch unreachable;
    for (argv) |arg| {
        buf.appendSlice(xm.allocator, arg) catch unreachable;
        buf.append(xm.allocator, 0) catch unreachable;
    }
    _ = proc_mod.proc_send(peer, .command, -1, buf.items.ptr, buf.items.len);
}

fn client_send_shell_request() void {
    const peer = client_peer orelse return;
    _ = proc_mod.proc_send(peer, .shell, -1, null, 0);
}

fn client_send_control_line(line: []const u8) void {
    var argv = cmd_mod.split_command_words(xm.allocator, line) catch {
        log.log_warn("control command parse failed: {s}", .{line});
        return;
    };
    defer cmd_mod.free_split_command_words(&argv);

    if (argv.items.len == 0) return;
    client_send_command(argv.items);
}

fn client_control_flush_lines(eof: bool) void {
    var consumed: usize = 0;
    while (std.mem.indexOfScalarPos(u8, client_control_input.items, consumed, '\n')) |nl| {
        const raw = client_control_input.items[consumed..nl];
        const line = std.mem.trimRight(u8, raw, "\r");
        if (line.len != 0) client_send_control_line(line);
        consumed = nl + 1;
    }

    if (eof and consumed < client_control_input.items.len) {
        const line = std.mem.trim(u8, client_control_input.items[consumed..], " \t\r\n");
        if (line.len != 0) client_send_control_line(line);
        consumed = client_control_input.items.len;
    }

    if (consumed != 0) {
        const remaining = client_control_input.items.len - consumed;
        std.mem.copyForwards(u8, client_control_input.items[0..remaining], client_control_input.items[consumed..]);
        client_control_input.shrinkRetainingCapacity(remaining);
    }
}

fn client_handle_lock_command(cmd: []const u8) void {
    const was_attached = client_attached;
    if (client_attached) client_leave_attached_mode();

    const cmd_z = xm.xm_dupeZ(cmd);
    defer xm.allocator.free(cmd_z);
    const status = system(cmd_z.ptr);

    if (was_attached) {
        client_enter_attached_mode();
        client_send_resize();
    }
    if (client_peer) |peer| _ = proc_mod.proc_send(peer, .unlock, -1, std.mem.asBytes(&status).ptr, @sizeOf(i32));
}

fn client_set_tstp_handler(sig_handler: ?*const fn (i32) callconv(.c) void) void {
    const action = std.posix.Sigaction{
        .handler = .{ .handler = sig_handler },
        .mask = std.posix.sigemptyset(),
        .flags = std.os.linux.SA.RESTART,
    };
    std.posix.sigaction(std.posix.SIG.TSTP, &action, null);
}

fn client_deliver_suspend_signal() void {
    if (client_suspend_signal_hook) |hook| {
        hook();
        return;
    }
    _ = std.c.kill(std.c.getpid(), std.posix.SIG.TSTP);
}

fn client_handle_suspend() void {
    client_suspend_restore_attached = client_attached;
    if (client_attached) client_leave_attached_mode();
    client_set_tstp_handler(std.posix.SIG.DFL);
    client_suspended = true;
    client_deliver_suspend_signal();
}

fn client_handle_continue() void {
    client_set_tstp_handler(std.posix.SIG.IGN);
    if (client_suspend_restore_attached) {
        client_enter_attached_mode();
        client_send_resize();
    }
    client_suspend_restore_attached = false;
    client_suspended = false;
    if (client_peer) |peer| _ = proc_mod.proc_send(peer, .wakeup, -1, null, 0);
}

/// Whether the client should set `CLIENT_STARTSERVER` before connecting (same
/// rules as `client_main`, without libevent or proc setup).
pub fn client_infer_start_server(shell_command: ?[]const u8, argc: i32, argv: [*]const [*:0]const u8) bool {
    if (shell_command != null) return true;
    if (argc == 0) return true;

    var argv_slice: std.ArrayList([]const u8) = .{};
    defer argv_slice.deinit(xm.allocator);
    var i: usize = 0;
    while (i < @as(usize, @intCast(argc))) : (i += 1) {
        argv_slice.append(xm.allocator, std.mem.span(argv[i])) catch unreachable;
    }
    var cause: ?[]u8 = null;
    if (cmd_mod.cmd_parse_one(argv_slice.items, null, &cause)) |parsed| {
        const want = (parsed.entry.flags & T.CMD_STARTSERVER) != 0;
        cmd_mod.cmd_free(parsed);
        return want;
    } else |_| {}
    if (cause) |c_err| xm.allocator.free(c_err);
    return false;
}

pub fn client_main(
    base: *c.libevent.event_base,
    shell_command: ?[]const u8,
    argc: i32,
    argv: [*]const [*:0]const u8,
    flags: u64,
    feat: i32,
) i32 {
    var client_mode_flags = flags;
    client_set_shell_command(shell_command);
    defer client_clear_shell_command();

    const start_server = client_infer_start_server(shell_command, argc, argv);

    if (client_has_terminal()) client_mode_flags |= T.CLIENT_TERMINAL;
    client_flags = client_mode_flags | if (start_server) T.CLIENT_STARTSERVER else 0;

    client_proc = proc_mod.proc_start("client");
    proc_mod.proc_set_signals(client_proc.?, client_signal);

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

    // Save terminal settings before sending identify — SIGKILL safety net.
    if (!client_have_saved_tio) {
        if (c.posix_sys.tcgetattr(std.posix.STDIN_FILENO, &client_saved_tio) == 0) {
            client_have_saved_tio = true;
        }
    }

    client_send_identify(feat);

    if (client_shell_command != null) {
        client_send_shell_request();
    } else if (argc > 0) {
        var argv_slice: std.ArrayList([]const u8) = .{};
        defer argv_slice.deinit(xm.allocator);

        var i: usize = 0;
        while (i < @as(usize, @intCast(argc))) : (i += 1) {
            argv_slice.append(xm.allocator, std.mem.span(argv[i])) catch unreachable;
        }
        client_send_command(argv_slice.items);
    } else {
        const no_args = [_][]const u8{};
        client_send_command(no_args[0..]);
    }

    if (client_flags & T.CLIENT_CONTROL != 0) {
        client_control_input = .{};
    }

    proc_mod.proc_loop(client_proc.?, null);
    file_mod.clientCleanup();
    if (client_attached) {
        client_leave_attached_mode();
    }
    client_control_input.deinit(xm.allocator);
    client_control_input = .{};
    proc_mod.proc_clear_signals(client_proc.?, true);

    if (client_exec_command != null and client_exec_shell != null) {
        const shell = client_exec_shell.?;
        const command = client_exec_command.?;
        client_exec_shell = null;
        client_exec_command = null;
        client_exec(shell, command);
    }

    if (client_exitreason == .detached_hup) {
        const ppid = std.c.getppid();
        if (ppid > 1) _ = std.c.kill(ppid, std.posix.SIG.HUP);
    }

    return client_retval;
}

export fn client_signal(signo: c_int) void {
    switch (signo) {
        std.posix.SIG.TERM, std.posix.SIG.INT => {
            if (!client_suspended) client_exitreason = .terminated;
            proc_mod.proc_exit(client_proc.?);
        },
        std.posix.SIG.CONT => client_handle_continue(),
        std.posix.SIG.WINCH => {
            if (client_attached) client_send_resize();
        },
        else => {},
    }
}

fn noopDispatch(_: ?*c.imsg.imsg, _: ?*anyopaque) callconv(.c) void {}

test "client_connect rejects overlong unix socket path" {
    const base = c.libevent.event_base_new() orelse return error.OutOfMemory;
    defer c.libevent.event_base_free(base);

    var path_buf: [std.posix.sockaddr.un.path_len_including_null]u8 = undefined;
    @memset(&path_buf, 'x');
    const rc = client_connect(base, &path_buf, T.CLIENT_NOSTARTSERVER);
    try std.testing.expectEqual(@as(i32, -1), rc);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(std.posix.E.NAMETOOLONG)), std.c._errno().*);
}

fn acceptOneIncomingConnection(listen_fd: i32) void {
    const cfd = std.c.accept(listen_fd, null, null);
    if (cfd >= 0) std.posix.close(@intCast(cfd));
}

test "client_connect succeeds against listening unix socket and sets nonblocking" {
    const base = c.libevent.event_base_new() orelse return error.OutOfMemory;
    defer c.libevent.event_base_free(base);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(xm.allocator, ".");
    defer xm.allocator.free(dir_path);
    const sock_path = try std.fs.path.join(xm.allocator, &.{ dir_path, "zmux-client-connect.sock" });
    defer xm.allocator.free(sock_path);

    try std.posix.unlink(sock_path) catch {};

    const listen_fd = try std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0);
    defer std.posix.close(listen_fd);

    var sa: std.posix.sockaddr.un = std.mem.zeroes(std.posix.sockaddr.un);
    sa.family = std.posix.AF.UNIX;
    if (sock_path.len >= sa.path.len) return error.NameTooLong;
    @memcpy(sa.path[0..sock_path.len], sock_path);

    try std.posix.bind(listen_fd, @as(*const std.posix.sockaddr, @ptrCast(&sa)), @sizeOf(std.posix.sockaddr.un));
    try std.posix.listen(listen_fd, 1);

    const thread = try std.Thread.spawn(.{}, acceptOneIncomingConnection, .{listen_fd});
    defer thread.join();

    const flags: u64 = 0;
    const rc = client_connect(base, sock_path, flags);
    try std.testing.expect(rc >= 0);
    defer std.posix.close(rc);

    const fl = std.c.fcntl(rc, std.posix.F.GETFL, @as(c_int, 0));
    try std.testing.expect(fl >= 0);
    const O_NONBLOCK: c_int = 0x800;
    try std.testing.expect(fl & O_NONBLOCK != 0);
}

test "client_get_lock returns exclusive fd then EAGAIN when lock already held" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(xm.allocator, ".");
    defer xm.allocator.free(dir_path);
    const lock_path = try std.fs.path.join(xm.allocator, &.{ dir_path, "zmux-test.lock" });
    defer xm.allocator.free(lock_path);

    const fd1 = client_get_lock(lock_path);
    try std.testing.expect(fd1 >= 0);
    defer std.posix.close(fd1);

    const fd2 = client_get_lock(lock_path);
    try std.testing.expectEqual(@as(i32, -2), fd2);
}

test "client_connect returns -1 on non-socket path when start-server is disabled" {
    const base = c.libevent.event_base_new() orelse return error.OutOfMemory;
    defer c.libevent.event_base_free(base);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const not_sock = try tmp.dir.realpathAlloc(xm.allocator, ".");
    defer xm.allocator.free(not_sock);

    const rc = client_connect(base, not_sock, T.CLIENT_NOSTARTSERVER);
    try std.testing.expectEqual(@as(i32, -1), rc);
}

test "client detach payload preserves session name and kill reason" {
    defer if (client_exitsession) |session| {
        xm.allocator.free(session);
        client_exitsession = null;
    };

    try std.testing.expect(client_record_detach(.detachkill, "victim\x00"));
    try std.testing.expectEqual(T.ClientExitReason.detached_hup, client_exitreason);
    try std.testing.expectEqualStrings("victim", client_exitsession.?);
}

test "client_record_detach uses detached reason for non-kill detach" {
    if (client_exitsession) |old| xm.allocator.free(old);
    client_exitsession = null;
    client_exitreason = .none;
    defer if (client_exitsession) |session| {
        xm.allocator.free(session);
        client_exitsession = null;
    };

    try std.testing.expect(client_record_detach(.detach, "plain-sess\x00"));
    try std.testing.expectEqual(T.ClientExitReason.detached, client_exitreason);
    try std.testing.expectEqualStrings("plain-sess", client_exitsession.?);
}

test "client_record_detach rejects payload without trailing nul" {
    if (client_exitsession) |old| xm.allocator.free(old);
    client_exitsession = null;
    client_exitreason = .none;
    defer if (client_exitsession) |session| {
        xm.allocator.free(session);
        client_exitsession = null;
    };

    try std.testing.expect(!client_record_detach(.detach, "no-nul"));
    try std.testing.expectEqual(T.ClientExitReason.none, client_exitreason);
    try std.testing.expect(client_exitsession == null);
}

test "client exec payload preserves command and shell" {
    defer client_clear_exec_request();

    try std.testing.expect(client_record_exec("printf exec\x00/bin/sh\x00"));
    try std.testing.expectEqualStrings("printf exec", client_exec_command.?);
    try std.testing.expectEqualStrings("/bin/sh", client_exec_shell.?);
}

test "client shell request uses shell message" {
    var pair: [2]i32 = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &pair));

    var proc = T.ZmuxProc{ .name = "client-shell-request-test" };
    defer proc.peers.deinit(xm.allocator);

    client_proc = &proc;
    client_peer = proc_mod.proc_add_peer(&proc, pair[0], noopDispatch, null);
    defer {
        const peer = client_peer.?;
        c.imsg.imsgbuf_clear(&peer.ibuf);
        std.posix.close(peer.ibuf.fd);
        xm.allocator.destroy(peer);
        proc.peers.clearRetainingCapacity();
        client_peer = null;
        client_proc = null;
    }

    var reader: c.imsg.imsgbuf = undefined;
    try std.testing.expectEqual(@as(i32, 0), c.imsg.imsgbuf_init(&reader, pair[1]));
    defer {
        c.imsg.imsgbuf_clear(&reader);
        std.posix.close(pair[1]);
    }

    client_send_shell_request();

    try std.testing.expectEqual(@as(i32, 1), c.imsg.imsgbuf_read(&reader));
    var imsg_msg: c.imsg.imsg = undefined;
    try std.testing.expect(c.imsg.imsg_get(&reader, &imsg_msg) > 0);
    defer c.imsg.imsg_free(&imsg_msg);

    try std.testing.expectEqual(@as(u32, @intCast(@intFromEnum(protocol.MsgType.shell))), c.imsg.imsg_get_type(&imsg_msg));
    try std.testing.expectEqual(@as(usize, 0), c.imsg.imsg_get_len(&imsg_msg));
}

test "client empty command request sends zero argc command payload" {
    var pair: [2]i32 = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &pair));

    var proc = T.ZmuxProc{ .name = "client-empty-command-test" };
    defer proc.peers.deinit(xm.allocator);

    client_proc = &proc;
    client_peer = proc_mod.proc_add_peer(&proc, pair[0], noopDispatch, null);
    defer {
        const peer = client_peer.?;
        c.imsg.imsgbuf_clear(&peer.ibuf);
        std.posix.close(peer.ibuf.fd);
        xm.allocator.destroy(peer);
        proc.peers.clearRetainingCapacity();
        client_peer = null;
        client_proc = null;
    }

    var reader: c.imsg.imsgbuf = undefined;
    try std.testing.expectEqual(@as(i32, 0), c.imsg.imsgbuf_init(&reader, pair[1]));
    defer {
        c.imsg.imsgbuf_clear(&reader);
        std.posix.close(pair[1]);
    }

    const no_args = [_][]const u8{};
    client_send_command(no_args[0..]);

    try std.testing.expectEqual(@as(i32, 1), c.imsg.imsgbuf_read(&reader));
    var imsg_msg: c.imsg.imsg = undefined;
    try std.testing.expect(c.imsg.imsg_get(&reader, &imsg_msg) > 0);
    defer c.imsg.imsg_free(&imsg_msg);

    try std.testing.expectEqual(@as(u32, @intCast(@intFromEnum(protocol.MsgType.command))), c.imsg.imsg_get_type(&imsg_msg));
    try std.testing.expectEqual(@as(usize, @sizeOf(protocol.MsgCommand)), c.imsg.imsg_get_len(&imsg_msg));

    var msg_cmd: protocol.MsgCommand = undefined;
    try std.testing.expectEqual(@as(i32, 0), c.imsg.imsg_get_data(&imsg_msg, std.mem.asBytes(&msg_cmd).ptr, @sizeOf(protocol.MsgCommand)));
    try std.testing.expectEqual(@as(i32, 0), msg_cmd.argc);
}

test "client lock command runs shell command then sends unlock" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try tmp.dir.realpathAlloc(xm.allocator, ".");
    defer xm.allocator.free(cwd);
    const marker_path = try std.fmt.allocPrint(xm.allocator, "{s}/lock-ran.txt", .{cwd});
    defer xm.allocator.free(marker_path);
    const command = try std.fmt.allocPrint(xm.allocator, "printf locked > '{s}'", .{marker_path});
    defer xm.allocator.free(command);

    var pair: [2]i32 = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &pair));

    var proc = T.ZmuxProc{ .name = "client-lock-test" };
    defer proc.peers.deinit(xm.allocator);

    client_proc = &proc;
    client_peer = proc_mod.proc_add_peer(&proc, pair[0], noopDispatch, null);
    client_attached = false;
    client_have_saved_tio = false;
    defer {
        const peer = client_peer.?;
        c.imsg.imsgbuf_clear(&peer.ibuf);
        std.posix.close(peer.ibuf.fd);
        xm.allocator.destroy(peer);
        proc.peers.clearRetainingCapacity();
        client_peer = null;
        client_proc = null;
    }

    var reader: c.imsg.imsgbuf = undefined;
    try std.testing.expectEqual(@as(i32, 0), c.imsg.imsgbuf_init(&reader, pair[1]));
    defer {
        c.imsg.imsgbuf_clear(&reader);
        std.posix.close(pair[1]);
    }

    client_handle_lock_command(command);

    const marker = try std.fs.cwd().readFileAlloc(xm.allocator, marker_path, 64);
    defer xm.allocator.free(marker);
    try std.testing.expectEqualStrings("locked", marker);

    try std.testing.expectEqual(@as(i32, 1), c.imsg.imsgbuf_read(&reader));
    var imsg_msg: c.imsg.imsg = undefined;
    try std.testing.expect(c.imsg.imsg_get(&reader, &imsg_msg) > 0);
    defer c.imsg.imsg_free(&imsg_msg);
    try std.testing.expectEqual(@as(u32, @intCast(@intFromEnum(protocol.MsgType.unlock))), c.imsg.imsg_get_type(&imsg_msg));
    try std.testing.expectEqual(@as(usize, @sizeOf(i32)), c.imsg.imsg_get_len(&imsg_msg));

    var unlock_status: i32 = -1;
    try std.testing.expectEqual(@as(i32, 0), c.imsg.imsg_get_data(&imsg_msg, std.mem.asBytes(&unlock_status).ptr, @sizeOf(i32)));
    try std.testing.expectEqual(@as(i32, 0), unlock_status);
}

fn client_test_suspend_hook() void {}

test "client suspend and continue round-trip wakeup state" {
    var pair: [2]i32 = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &pair));

    var proc = T.ZmuxProc{ .name = "client-suspend-test" };
    defer proc.peers.deinit(xm.allocator);

    client_proc = &proc;
    client_peer = proc_mod.proc_add_peer(&proc, pair[0], noopDispatch, null);
    client_attached = true;
    client_suspended = false;
    client_suspend_restore_attached = false;
    client_have_saved_tio = false;
    client_suspend_signal_hook = client_test_suspend_hook;
    defer {
        const peer = client_peer.?;
        c.imsg.imsgbuf_clear(&peer.ibuf);
        std.posix.close(peer.ibuf.fd);
        xm.allocator.destroy(peer);
        proc.peers.clearRetainingCapacity();
        client_peer = null;
        client_proc = null;
        client_attached = false;
        client_suspended = false;
        client_suspend_restore_attached = false;
        client_suspend_signal_hook = null;
    }

    var reader: c.imsg.imsgbuf = undefined;
    try std.testing.expectEqual(@as(i32, 0), c.imsg.imsgbuf_init(&reader, pair[1]));
    defer {
        c.imsg.imsgbuf_clear(&reader);
        std.posix.close(pair[1]);
    }

    client_handle_suspend();
    try std.testing.expect(client_suspended);
    try std.testing.expect(!client_attached);
    try std.testing.expect(client_suspend_restore_attached);

    client_handle_continue();
    try std.testing.expect(!client_suspended);
    try std.testing.expect(client_attached);
    try std.testing.expect(!client_suspend_restore_attached);

    try std.testing.expectEqual(@as(i32, 1), c.imsg.imsgbuf_read(&reader));
    var imsg_msg: c.imsg.imsg = undefined;
    try std.testing.expect(c.imsg.imsg_get(&reader, &imsg_msg) > 0);
    defer c.imsg.imsg_free(&imsg_msg);
    try std.testing.expectEqual(@as(u32, @intCast(@intFromEnum(protocol.MsgType.wakeup))), c.imsg.imsg_get_type(&imsg_msg));
}

fn clientDispatchTestResetProc(proc: *T.ZmuxProc) void {
    proc.exit = false;
    proc.peers.clearRetainingCapacity();
}

test "client_connect returns -1 with NOSTARTSERVER when unix socket path is missing" {
    const base = c.libevent.event_base_new() orelse return error.OutOfMemory;
    defer c.libevent.event_base_free(base);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const sock_path = try tmp.dir.realpathAlloc(xm.allocator, ".");
    defer xm.allocator.free(sock_path);
    const path = try std.fs.path.join(xm.allocator, &.{ sock_path, "no-such-zmux.sock" });
    defer xm.allocator.free(path);

    const rc = client_connect(base, path, T.CLIENT_NOSTARTSERVER);
    try std.testing.expectEqual(@as(i32, -1), rc);
}

test "client_dispatch null imsg sets lost_server and marks proc exit" {
    var proc = T.ZmuxProc{ .name = "client-dispatch-null" };
    defer clientDispatchTestResetProc(&proc);
    client_proc = &proc;
    defer {
        client_proc = null;
        client_exitreason = .none;
    }

    client_exitreason = .none;
    client_dispatch(null, null);
    try std.testing.expectEqual(T.ClientExitReason.lost_server, client_exitreason);
    try std.testing.expect(proc.exit);
}

test "client_dispatch flags replaces client_flags from payload" {
    var proc = T.ZmuxProc{ .name = "client-dispatch-flags" };
    defer clientDispatchTestResetProc(&proc);
    client_proc = &proc;
    defer {
        client_proc = null;
        client_flags = 0;
    }

    const want: u64 = T.CLIENT_UTF8 | T.CLIENT_READONLY;
    var imsg: c.imsg.imsg = .{
        .hdr = .{
            .type = @intCast(@intFromEnum(protocol.MsgType.flags)),
            .len = @as(u32, @intCast(@sizeOf(c.imsg.imsg_hdr) + @sizeOf(u64))),
            .peerid = protocol.PROTOCOL_VERSION,
            .pid = 0,
        },
        .data = @ptrCast(@constCast(&want)),
        .buf = null,
    };
    client_dispatch(&imsg, null);
    try std.testing.expectEqual(want, client_flags);
    try std.testing.expect(!proc.exit);
}

test "client_dispatch exit carries retval and exits proc" {
    var proc = T.ZmuxProc{ .name = "client-dispatch-exit" };
    defer clientDispatchTestResetProc(&proc);
    client_proc = &proc;
    defer {
        client_proc = null;
        client_retval = 0;
        client_exitreason = .none;
    }

    client_retval = 0;
    client_exitreason = .none;
    const rv: i32 = 17;
    var imsg: c.imsg.imsg = .{
        .hdr = .{
            .type = @intCast(@intFromEnum(protocol.MsgType.exit)),
            .len = @as(u32, @intCast(@sizeOf(c.imsg.imsg_hdr) + @sizeOf(i32))),
            .peerid = protocol.PROTOCOL_VERSION,
            .pid = 0,
        },
        .data = @ptrCast(@constCast(&rv)),
        .buf = null,
    };
    client_dispatch(&imsg, null);
    try std.testing.expectEqual(@as(i32, 17), client_retval);
    try std.testing.expectEqual(T.ClientExitReason.exited, client_exitreason);
    try std.testing.expect(proc.exit);
}

test "client_dispatch shutdown sets lost_server" {
    var proc = T.ZmuxProc{ .name = "client-dispatch-shutdown" };
    defer clientDispatchTestResetProc(&proc);
    client_proc = &proc;
    defer {
        client_proc = null;
        client_exitreason = .none;
    }

    client_exitreason = .none;
    var imsg: c.imsg.imsg = .{
        .hdr = .{
            .type = @intCast(@intFromEnum(protocol.MsgType.shutdown)),
            .len = @as(u32, @intCast(@sizeOf(c.imsg.imsg_hdr))),
            .peerid = protocol.PROTOCOL_VERSION,
            .pid = 0,
        },
        .data = null,
        .buf = null,
    };
    client_dispatch(&imsg, null);
    try std.testing.expectEqual(T.ClientExitReason.lost_server, client_exitreason);
    try std.testing.expect(proc.exit);
}

test "client_dispatch write to stdout stream ignores short payload" {
    var proc = T.ZmuxProc{ .name = "client-dispatch-write-short" };
    defer clientDispatchTestResetProc(&proc);
    client_proc = &proc;
    defer client_proc = null;

    var imsg: c.imsg.imsg = .{
        .hdr = .{
            .type = @intCast(@intFromEnum(protocol.MsgType.write)),
            .len = @as(u32, @intCast(@sizeOf(c.imsg.imsg_hdr) + @sizeOf(i32))),
            .peerid = protocol.PROTOCOL_VERSION,
            .pid = 0,
        },
        .data = null,
        .buf = null,
    };
    client_dispatch(&imsg, null);
    try std.testing.expect(!proc.exit);
}

test "client_dispatch malformed write returns without exit" {
    var proc = T.ZmuxProc{ .name = "client-dispatch-write-bad" };
    defer clientDispatchTestResetProc(&proc);
    client_proc = &proc;
    defer client_proc = null;

    const stream: i32 = 1;
    var imsg: c.imsg.imsg = .{
        .hdr = .{
            .type = @intCast(@intFromEnum(protocol.MsgType.write)),
            .len = @as(u32, @intCast(@sizeOf(c.imsg.imsg_hdr) + @sizeOf(i32))),
            .peerid = protocol.PROTOCOL_VERSION,
            .pid = 0,
        },
        .data = @ptrCast(@constCast(&stream)),
        .buf = null,
    };
    client_dispatch(&imsg, null);
    try std.testing.expect(!proc.exit);
}

test "client_dispatch version sets lost_server and exits proc" {
    var proc = T.ZmuxProc{ .name = "client-dispatch-version" };
    defer clientDispatchTestResetProc(&proc);
    client_proc = &proc;
    defer {
        client_proc = null;
        client_exitreason = .none;
    }

    client_exitreason = .none;
    var imsg: c.imsg.imsg = .{
        .hdr = .{
            .type = @intCast(@intFromEnum(protocol.MsgType.version)),
            .len = @as(u32, @intCast(@sizeOf(c.imsg.imsg_hdr))),
            .peerid = protocol.PROTOCOL_VERSION,
            .pid = 0,
        },
        .data = null,
        .buf = null,
    };
    client_dispatch(&imsg, null);
    try std.testing.expectEqual(T.ClientExitReason.lost_server, client_exitreason);
    try std.testing.expect(proc.exit);
}

test "client_dispatch shell returns without trailing nul and does not exit proc" {
    var proc = T.ZmuxProc{ .name = "client-dispatch-shell-bad" };
    defer clientDispatchTestResetProc(&proc);
    client_proc = &proc;
    defer client_proc = null;

    const payload = "nope-no-nul";
    var imsg: c.imsg.imsg = .{
        .hdr = .{
            .type = @intCast(@intFromEnum(protocol.MsgType.shell)),
            .len = @as(u32, @intCast(@sizeOf(c.imsg.imsg_hdr) + payload.len)),
            .peerid = protocol.PROTOCOL_VERSION,
            .pid = 0,
        },
        .data = @constCast(payload.ptr),
        .buf = null,
    };
    client_dispatch(&imsg, null);
    try std.testing.expect(!proc.exit);
}

test "client_dispatch lock ignores payload without trailing nul" {
    var proc = T.ZmuxProc{ .name = "client-dispatch-lock-bad" };
    defer clientDispatchTestResetProc(&proc);
    client_proc = &proc;
    defer {
        client_peer = null;
        client_proc = null;
    }

    var pair: [2]i32 = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &pair));
    defer {
        std.posix.close(pair[0]);
        std.posix.close(pair[1]);
    }

    client_peer = proc_mod.proc_add_peer(&proc, pair[0], noopDispatch, null);
    defer {
        const peer = client_peer.?;
        c.imsg.imsgbuf_clear(&peer.ibuf);
        std.posix.close(peer.ibuf.fd);
        xm.allocator.destroy(peer);
        proc.peers.clearRetainingCapacity();
    }

    const payload = "no-nul-lock";
    var imsg: c.imsg.imsg = .{
        .hdr = .{
            .type = @intCast(@intFromEnum(protocol.MsgType.lock)),
            .len = @as(u32, @intCast(@sizeOf(c.imsg.imsg_hdr) + payload.len)),
            .peerid = protocol.PROTOCOL_VERSION,
            .pid = 0,
        },
        .data = @constCast(payload.ptr),
        .buf = null,
    };
    client_dispatch(&imsg, null);
    try std.testing.expect(!proc.exit);
}

test "client_dispatch routes write stream over 2 through file write handler" {
    file_mod.resetForTests();
    defer file_mod.resetForTests();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try tmp.dir.realpathAlloc(xm.allocator, ".");
    defer xm.allocator.free(cwd);
    const out_path = try std.fmt.allocPrint(xm.allocator, "{s}/dispatch-stream.bin", .{cwd});
    defer xm.allocator.free(out_path);

    var pair: [2]i32 = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &pair));

    var proc = T.ZmuxProc{ .name = "client-dispatch-write3" };
    defer proc.peers.deinit(xm.allocator);

    client_peer = proc_mod.proc_add_peer(&proc, pair[0], noopDispatch, null);
    defer {
        const peer = client_peer.?;
        c.imsg.imsgbuf_clear(&peer.ibuf);
        std.posix.close(peer.ibuf.fd);
        xm.allocator.destroy(peer);
        proc.peers.clearRetainingCapacity();
        client_peer = null;
    }

    client_proc = &proc;
    client_flags = 0;
    defer {
        client_proc = null;
        client_flags = 0;
    }

    var reader: c.imsg.imsgbuf = undefined;
    try std.testing.expectEqual(@as(i32, 0), c.imsg.imsgbuf_init(&reader, pair[1]));
    defer {
        c.imsg.imsgbuf_clear(&reader);
        std.posix.close(pair[1]);
    }

    const stream: i32 = 19;
    var open_buf = std.ArrayList(u8){};
    defer open_buf.deinit(xm.allocator);
    const open_msg = protocol.MsgWriteOpen{
        .stream = stream,
        .fd = -1,
        .flags = 0,
    };
    open_buf.appendSlice(xm.allocator, std.mem.asBytes(&open_msg)) catch unreachable;
    open_buf.appendSlice(xm.allocator, out_path) catch unreachable;
    open_buf.append(xm.allocator, 0) catch unreachable;

    var open_imsg: c.imsg.imsg = .{
        .hdr = .{
            .type = @intCast(@intFromEnum(protocol.MsgType.write_open)),
            .len = @as(u32, @intCast(@sizeOf(c.imsg.imsg_hdr) + open_buf.items.len)),
            .peerid = protocol.PROTOCOL_VERSION,
            .pid = 0,
        },
        .data = open_buf.items.ptr,
        .buf = null,
    };
    client_dispatch(&open_imsg, null);

    try std.testing.expectEqual(@as(i32, 1), c.imsg.imsgbuf_read(&reader));
    var ready_imsg: c.imsg.imsg = undefined;
    try std.testing.expect(c.imsg.imsg_get(&reader, &ready_imsg) > 0);
    defer c.imsg.imsg_free(&ready_imsg);

    const chunk = "dispatch-write-payload";
    var data_buf = std.ArrayList(u8){};
    defer data_buf.deinit(xm.allocator);
    const head = protocol.MsgWriteData{ .stream = stream };
    data_buf.appendSlice(xm.allocator, std.mem.asBytes(&head)) catch unreachable;
    data_buf.appendSlice(xm.allocator, chunk) catch unreachable;

    var data_imsg: c.imsg.imsg = .{
        .hdr = .{
            .type = @intCast(@intFromEnum(protocol.MsgType.write)),
            .len = @as(u32, @intCast(@sizeOf(c.imsg.imsg_hdr) + data_buf.items.len)),
            .peerid = protocol.PROTOCOL_VERSION,
            .pid = 0,
        },
        .data = data_buf.items.ptr,
        .buf = null,
    };
    client_dispatch(&data_imsg, null);

    const disk = try std.fs.cwd().readFileAlloc(xm.allocator, out_path, 64);
    defer xm.allocator.free(disk);
    try std.testing.expectEqualStrings(chunk, disk);
}

test "client_dispatch read_open forwards to file read handler" {
    file_mod.resetForTests();
    defer file_mod.resetForTests();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try tmp.dir.realpathAlloc(xm.allocator, ".");
    defer xm.allocator.free(cwd);
    const path = try std.fmt.allocPrint(xm.allocator, "{s}/dispatch-read.txt", .{cwd});
    defer xm.allocator.free(path);

    const file = try std.fs.createFileAbsolute(path, .{});
    try file.writeAll("via-dispatch");
    file.close();

    var pair: [2]i32 = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &pair));

    var proc = T.ZmuxProc{ .name = "client-dispatch-readopen" };
    defer proc.peers.deinit(xm.allocator);

    client_peer = proc_mod.proc_add_peer(&proc, pair[0], noopDispatch, null);
    defer {
        const peer = client_peer.?;
        c.imsg.imsgbuf_clear(&peer.ibuf);
        std.posix.close(peer.ibuf.fd);
        xm.allocator.destroy(peer);
        proc.peers.clearRetainingCapacity();
        client_peer = null;
    }

    client_proc = &proc;
    client_flags = 0;
    defer {
        client_proc = null;
        client_flags = 0;
    }

    var reader: c.imsg.imsgbuf = undefined;
    try std.testing.expectEqual(@as(i32, 0), c.imsg.imsgbuf_init(&reader, pair[1]));
    defer {
        c.imsg.imsgbuf_clear(&reader);
        std.posix.close(pair[1]);
    }

    var open_buf = std.ArrayList(u8){};
    defer open_buf.deinit(xm.allocator);
    const open_msg = protocol.MsgReadOpen{ .stream = 41, .fd = -1 };
    open_buf.appendSlice(xm.allocator, std.mem.asBytes(&open_msg)) catch unreachable;
    open_buf.appendSlice(xm.allocator, path) catch unreachable;
    open_buf.append(xm.allocator, 0) catch unreachable;

    var open_imsg: c.imsg.imsg = .{
        .hdr = .{
            .type = @intCast(@intFromEnum(protocol.MsgType.read_open)),
            .len = @as(u32, @intCast(@sizeOf(c.imsg.imsg_hdr) + open_buf.items.len)),
            .peerid = protocol.PROTOCOL_VERSION,
            .pid = 0,
        },
        .data = open_buf.items.ptr,
        .buf = null,
    };
    client_dispatch(&open_imsg, null);

    try std.testing.expectEqual(@as(i32, 1), c.imsg.imsgbuf_read(&reader));
    var read_imsg: c.imsg.imsg = undefined;
    try std.testing.expect(c.imsg.imsg_get(&reader, &read_imsg) > 0);
    defer c.imsg.imsg_free(&read_imsg);
    try std.testing.expectEqual(@as(u32, @intCast(@intFromEnum(protocol.MsgType.read))), c.imsg.imsg_get_type(&read_imsg));
    const rlen = c.imsg.imsg_get_len(&read_imsg);
    var rbuf = try xm.allocator.alloc(u8, rlen);
    defer xm.allocator.free(rbuf);
    try std.testing.expectEqual(@as(i32, 0), c.imsg.imsg_get_data(&read_imsg, rbuf.ptr, rbuf.len));
    var rd: protocol.MsgReadData = undefined;
    @memcpy(std.mem.asBytes(&rd), rbuf[0..@sizeOf(protocol.MsgReadData)]);
    try std.testing.expectEqual(@as(i32, 41), rd.stream);
    try std.testing.expectEqualStrings("via-dispatch", rbuf[@sizeOf(protocol.MsgReadData)..]);
}

test "client_dispatch write_open no peer is a no-op" {
    var proc = T.ZmuxProc{ .name = "client-dispatch-wo-nopeer" };
    defer clientDispatchTestResetProc(&proc);
    client_proc = &proc;
    client_peer = null;
    defer client_proc = null;

    var open_buf = std.ArrayList(u8){};
    defer open_buf.deinit(xm.allocator);
    const open_msg = protocol.MsgWriteOpen{ .stream = 3, .fd = -1, .flags = 0 };
    open_buf.appendSlice(xm.allocator, std.mem.asBytes(&open_msg)) catch unreachable;
    open_buf.append(xm.allocator, "/tmp/nonexistent-zmux-test-path\x00") catch unreachable;

    var open_imsg: c.imsg.imsg = .{
        .hdr = .{
            .type = @intCast(@intFromEnum(protocol.MsgType.write_open)),
            .len = @as(u32, @intCast(@sizeOf(c.imsg.imsg_hdr) + open_buf.items.len)),
            .peerid = protocol.PROTOCOL_VERSION,
            .pid = 0,
        },
        .data = open_buf.items.ptr,
        .buf = null,
    };
    client_dispatch(&open_imsg, null);
    try std.testing.expect(!proc.exit);
}

test "client_infer_start_server follows shell argv and parse results" {
    const empty_argv: [*:0]const u8 = "";
    try std.testing.expect(client_infer_start_server("sh -c true", 0, @ptrCast(&empty_argv)));
    try std.testing.expect(client_infer_start_server(null, 0, @ptrCast(&empty_argv)));

    const arg_new: [:0]const u8 = "new-session";
    const argv_new: [1][*:0]const u8 = .{arg_new.ptr};
    try std.testing.expect(client_infer_start_server(null, 1, @ptrCast(&argv_new)));

    const arg_kill: [:0]const u8 = "kill-server";
    const argv_kill: [1][*:0]const u8 = .{arg_kill.ptr};
    try std.testing.expect(!client_infer_start_server(null, 1, @ptrCast(&argv_kill)));

    const arg_ls: [:0]const u8 = "list-sessions";
    const argv_ls: [1][*:0]const u8 = .{arg_ls.ptr};
    try std.testing.expect(!client_infer_start_server(null, 1, @ptrCast(&argv_ls)));
}

test "client_send_identify ends with identify_done after capability stream" {
    var pair: [2]i32 = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &pair));

    var proc = T.ZmuxProc{ .name = "client-identify-stream" };
    defer proc.peers.deinit(xm.allocator);

    client_proc = &proc;
    client_peer = proc_mod.proc_add_peer(&proc, pair[0], noopDispatch, null);
    client_flags = T.CLIENT_UTF8;
    defer {
        const peer = client_peer.?;
        c.imsg.imsgbuf_clear(&peer.ibuf);
        std.posix.close(peer.ibuf.fd);
        xm.allocator.destroy(peer);
        proc.peers.clearRetainingCapacity();
        client_peer = null;
        client_proc = null;
        client_flags = 0;
    }

    const fl_r = std.c.fcntl(pair[1], std.posix.F.GETFL, @as(c_int, 0));
    try std.testing.expect(fl_r >= 0);
    const O_NONBLOCK: c_int = 0x800;
    _ = std.c.fcntl(pair[1], std.posix.F.SETFL, fl_r | O_NONBLOCK);

    var reader: c.imsg.imsgbuf = undefined;
    try std.testing.expectEqual(@as(i32, 0), c.imsg.imsgbuf_init(&reader, pair[1]));
    defer {
        c.imsg.imsgbuf_clear(&reader);
        std.posix.close(pair[1]);
    }

    client_send_identify(7);

    var count: u32 = 0;
    var first_type: u32 = 0;
    var last_type: u32 = 0;
    var saw_stdin = false;
    var saw_stdout = false;
    while (true) {
        const nr = c.imsg.imsgbuf_read(&reader);
        if (nr < 0) {
            if (std.c._errno().* == @intFromEnum(std.posix.E.AGAIN)) break;
            break;
        }
        if (nr == 0) break;
        var im: c.imsg.imsg = undefined;
        if (c.imsg.imsg_get(&reader, &im) <= 0) break;
        const ty = c.imsg.imsg_get_type(&im);
        if (count == 0) first_type = ty;
        last_type = ty;
        count += 1;
        if (ty == @as(u32, @intCast(@intFromEnum(protocol.MsgType.identify_stdin)))) {
            const fd = c.imsg.imsg_get_fd(&im);
            try std.testing.expect(fd != -1);
            _ = c.posix_sys.close(fd);
            saw_stdin = true;
        }
        if (ty == @as(u32, @intCast(@intFromEnum(protocol.MsgType.identify_stdout)))) {
            const fd = c.imsg.imsg_get_fd(&im);
            try std.testing.expect(fd != -1);
            _ = c.posix_sys.close(fd);
            saw_stdout = true;
        }
        c.imsg.imsg_free(&im);
    }

    try std.testing.expect(count >= 4);
    try std.testing.expectEqual(@as(u32, @intCast(@intFromEnum(protocol.MsgType.identify_longflags))), first_type);
    try std.testing.expectEqual(@as(u32, @intCast(@intFromEnum(protocol.MsgType.identify_done))), last_type);
    try std.testing.expect(saw_stdin);
    try std.testing.expect(saw_stdout);
}

test "client_dispatch read_open with control client rejects stdin dup" {
    file_mod.resetForTests();
    defer file_mod.resetForTests();

    var pair: [2]i32 = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &pair));

    var proc = T.ZmuxProc{ .name = "client-dispatch-readopen-ctl" };
    defer proc.peers.deinit(xm.allocator);

    client_peer = proc_mod.proc_add_peer(&proc, pair[0], noopDispatch, null);
    defer {
        const peer = client_peer.?;
        c.imsg.imsgbuf_clear(&peer.ibuf);
        std.posix.close(peer.ibuf.fd);
        xm.allocator.destroy(peer);
        proc.peers.clearRetainingCapacity();
        client_peer = null;
    }

    client_proc = &proc;
    client_flags = T.CLIENT_CONTROL;
    defer {
        client_proc = null;
        client_flags = 0;
    }

    var reader: c.imsg.imsgbuf = undefined;
    try std.testing.expectEqual(@as(i32, 0), c.imsg.imsgbuf_init(&reader, pair[1]));
    defer {
        c.imsg.imsgbuf_clear(&reader);
        std.posix.close(pair[1]);
    }

    var open_msg = protocol.MsgReadOpen{ .stream = 55, .fd = std.posix.STDIN_FILENO };
    var open_imsg: c.imsg.imsg = .{
        .hdr = .{
            .type = @intCast(@intFromEnum(protocol.MsgType.read_open)),
            .len = @as(u32, @intCast(@sizeOf(c.imsg.imsg_hdr) + @sizeOf(protocol.MsgReadOpen))),
            .peerid = protocol.PROTOCOL_VERSION,
            .pid = 0,
        },
        .data = @ptrCast(&open_msg),
        .buf = null,
    };
    client_dispatch(&open_imsg, null);

    try std.testing.expectEqual(@as(i32, 1), c.imsg.imsgbuf_read(&reader));
    var done_imsg: c.imsg.imsg = undefined;
    try std.testing.expect(c.imsg.imsg_get(&reader, &done_imsg) > 0);
    defer c.imsg.imsg_free(&done_imsg);
    try std.testing.expectEqual(@as(u32, @intCast(@intFromEnum(protocol.MsgType.read_done))), c.imsg.imsg_get_type(&done_imsg));
    const done: *const protocol.MsgReadDone = @ptrCast(@alignCast(done_imsg.data.?));
    try std.testing.expectEqual(@as(i32, 55), done.stream);
    try std.testing.expectEqual(@as(i32, @intFromEnum(std.posix.E.BADF)), done.@"error");
}
