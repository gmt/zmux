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
// Ported from tmux/proc.c
// Original copyright:
//   Copyright (c) 2015 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

//! proc.zig – process lifecycle and IPC peer management.

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const log = @import("log.zig");
const protocol = @import("zmux-protocol.zig");
const c = @import("c.zig");

pub var libevent: ?*c.libevent.event_base = null;

// Peers marked for deferred cleanup (freed between event loop iterations)
var dead_peers: std.ArrayList(*T.ZmuxPeer) = .{};

extern fn getsockopt(sockfd: c_int, level: c_int, optname: c_int, optval: ?*anyopaque, optlen: *c_uint) c_int;
const SOL_SOCKET: c_int = 1;
const SO_PEERCRED: c_int = 17;
const Ucred = extern struct { pid: c_int, uid: c_uint, gid: c_uint };

extern fn daemon(nochdir: c_int, noclose: c_int) c_int;

pub const DispatchCb = *const fn (?*c.imsg.imsg, ?*anyopaque) callconv(.c) void;

// ── Event callback ────────────────────────────────────────────────────────

export fn proc_event_cb(_fd: c_int, events: c_short, arg: ?*anyopaque) void {
    _ = _fd;
    const peer: *T.ZmuxPeer = @ptrCast(@alignCast(arg orelse return));

    if (peer.flags & T.PEER_BAD == 0 and events & @as(c_short, c.libevent.EV_READ) != 0) {
        if (c.imsg.imsgbuf_read(&peer.ibuf) != 1) {
            peer.dispatchcb(null, peer.arg);
            return;
        }
        while (true) {
            var imsg_msg: c.imsg.imsg = undefined;
            const n = c.imsg.imsg_get(&peer.ibuf, &imsg_msg);
            if (n == -1) {
                peer.dispatchcb(null, peer.arg);
                return;
            }
            if (n == 0) break;
            if (peer_check_version(peer, &imsg_msg) != 0) {
                c.imsg.imsg_free(&imsg_msg);
                break;
            }
            peer.dispatchcb(&imsg_msg, peer.arg);
            c.imsg.imsg_free(&imsg_msg);
        }
    }

    if (events & @as(c_short, c.libevent.EV_WRITE) != 0) {
        if (c.imsg.imsgbuf_write(&peer.ibuf) == -1) {
            peer.dispatchcb(null, peer.arg);
            return;
        }
    }

    if (peer.flags & T.PEER_BAD != 0 and c.imsg.imsgbuf_queuelen(&peer.ibuf) == 0) {
        peer.dispatchcb(null, peer.arg);
        return;
    }
}

export fn proc_signal_cb(signo: c_int, _: c_short, arg: ?*anyopaque) void {
    const tp: *T.ZmuxProc = @ptrCast(@alignCast(arg orelse return));
    if (tp.signalcb) |cb| cb(signo);
}

// ── Internal helpers ──────────────────────────────────────────────────────

fn peer_check_version(peer: *T.ZmuxPeer, imsg_msg: *c.imsg.imsg) i32 {
    const version: u32 = imsg_msg.hdr.peerid & 0xff;
    if (imsg_msg.hdr.type != @as(u32, @intCast(@intFromEnum(protocol.MsgType.version))) and
        version != protocol.PROTOCOL_VERSION)
    {
        _ = proc_send(peer, .version, -1, null, 0);
        peer.flags |= T.PEER_BAD;
        return -1;
    }
    return 0;
}

fn proc_update_event(peer: *T.ZmuxPeer) void {
    if (peer.event != null) return;
    const base = libevent orelse return;
    peer.event = c.libevent.event_new(
        base, peer.ibuf.fd,
        @intCast(c.libevent.EV_READ | c.libevent.EV_PERSIST),
        proc_event_cb, peer);
    if (peer.event) |ev| _ = c.libevent.event_add(ev, null);
}

// ── Public API ────────────────────────────────────────────────────────────

pub fn proc_send(peer: *T.ZmuxPeer, msg_type: protocol.MsgType, fd: i32, buf: ?[*]const u8, len: usize) i32 {
    if (peer.flags & T.PEER_BAD != 0) return -1;
    const retval = c.imsg.imsg_compose(
        &peer.ibuf,
        @as(u32, @intCast(@as(c_int, @intFromEnum(msg_type)))),
        protocol.PROTOCOL_VERSION,
        -1,
        fd,
        @constCast(buf),
        len,
    );
    if (retval != 1) return -1;
    _ = c.imsg.imsgbuf_flush(&peer.ibuf);
    return 0;
}

pub fn proc_start(name: []const u8) *T.ZmuxProc {
    log.log_open(name);

    const u = std.posix.uname();
    log.log_debug("{s} started ({d}): version {s}, protocol {d}", .{
        name, std.os.linux.getpid(), T.ZMUX_VERSION, protocol.PROTOCOL_VERSION,
    });
    log.log_debug("on {s}", .{std.mem.sliceTo(&u.sysname, 0)});

    const tp = xm.allocator.create(T.ZmuxProc) catch unreachable;
    tp.* = T.ZmuxProc{
        .name = xm.xstrdup(name),
        .peers = .{},
    };
    return tp;
}

pub fn proc_loop(tp: *T.ZmuxProc, loopcb: ?*const fn () bool) void {
    log.log_debug("{s} loop enter", .{tp.name});
    while (!tp.exit) {
        // Reap dead peers from the PREVIOUS iteration (not from this one)
        reap_dead_peers();
        _ = c.libevent.event_loop(c.libevent.EVLOOP_ONCE);
        if (loopcb) |cb| {
            if (cb()) break;
        }
    }
    reap_dead_peers();
    log.log_debug("{s} loop exit", .{tp.name});
}

pub fn proc_exit(tp: *T.ZmuxProc) void {
    for (tp.peers.items) |peer| {
        _ = c.imsg.imsgbuf_flush(&peer.ibuf);
    }
    tp.exit = true;
}

pub fn proc_set_signals(tp: *T.ZmuxProc, signalcb: *const fn (i32) callconv(.c) void) void {
    tp.signalcb = signalcb;

    const sa_ign = std.posix.Sigaction{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.posix.sigemptyset(),
        .flags = std.os.linux.SA.RESTART,
    };
    std.posix.sigaction(std.posix.SIG.PIPE, &sa_ign, null);
    std.posix.sigaction(std.posix.SIG.TSTP, &sa_ign, null);
    std.posix.sigaction(std.posix.SIG.TTIN, &sa_ign, null);
    std.posix.sigaction(std.posix.SIG.TTOU, &sa_ign, null);
    std.posix.sigaction(std.posix.SIG.QUIT, &sa_ign, null);

    const sig_list: []const c_int = &.{
        @intCast(std.posix.SIG.INT),  @intCast(std.posix.SIG.HUP),
        @intCast(std.posix.SIG.CHLD), @intCast(std.posix.SIG.CONT),
        @intCast(std.posix.SIG.TERM), @intCast(std.posix.SIG.USR1),
        @intCast(std.posix.SIG.USR2), @intCast(std.posix.SIG.WINCH),
    };
    for (sig_list) |sig| {
        if (libevent) |base| {
            const sig_ev = c.libevent.event_new(
                base, sig,
                @intCast(c.libevent.EV_SIGNAL | c.libevent.EV_PERSIST),
                proc_signal_cb, tp);
            if (sig_ev) |sev| {
                _ = c.libevent.event_add(sev, null);
                tp.sig_events.append(xm.allocator, sev) catch unreachable;
            }
        }
    }
}

pub fn proc_clear_signals(tp: *T.ZmuxProc, defaults: bool) void {
    for (tp.sig_events.items) |sig_ev| {
        _ = c.libevent.event_del(sig_ev);
        c.libevent.event_free(sig_ev);
    }
    tp.sig_events.clearRetainingCapacity();
    if (defaults) {
        const sa_dfl = std.posix.Sigaction{
            .handler = .{ .handler = std.posix.SIG.DFL },
            .mask = std.posix.sigemptyset(),
            .flags = std.os.linux.SA.RESTART,
        };
        const sigs: []const u8 = &.{
            std.posix.SIG.INT,  std.posix.SIG.HUP,  std.posix.SIG.CHLD,
            std.posix.SIG.CONT, std.posix.SIG.TERM,  std.posix.SIG.USR1,
            std.posix.SIG.USR2, std.posix.SIG.WINCH, std.posix.SIG.PIPE,
            std.posix.SIG.TSTP,
        };
        for (sigs) |sig| std.posix.sigaction(sig, &sa_dfl, null);
    }
}

pub fn proc_add_peer(
    tp: *T.ZmuxProc,
    fd: i32,
    dispatchcb: DispatchCb,
    arg: ?*anyopaque,
) *T.ZmuxPeer {
    const peer = xm.allocator.create(T.ZmuxPeer) catch unreachable;
    peer.* = .{
        .parent = tp,
        .ibuf = undefined,
        .event = null,
        .uid = 0,
        .flags = 0,
        .dispatchcb = dispatchcb,
        .arg = arg,
    };

    if (c.imsg.imsgbuf_init(&peer.ibuf, fd) == -1)
        log.fatalx("imsgbuf_init failed", .{});
    c.imsg.imsgbuf_allow_fdpass(&peer.ibuf);

    var cred: Ucred = undefined;
    var cred_len: c_uint = @sizeOf(Ucred);
    if (getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &cred, &cred_len) == 0)
        peer.uid = @intCast(cred.uid)
    else
        peer.uid = ~@as(std.posix.uid_t, 0);

    tp.peers.append(xm.allocator, peer) catch unreachable;
    proc_update_event(peer);
    return peer;
}

/// Mark a peer for deferred cleanup. Safe to call from inside event callbacks.
pub fn proc_remove_peer(peer: *T.ZmuxPeer) void {
    // Remove from parent's live list
    const peers = &peer.parent.peers;
    for (peers.items, 0..) |p, i| {
        if (p == peer) {
            _ = peers.swapRemove(i);
            break;
        }
    }
    // Mark dead -- actual cleanup happens in reap_dead_peers()
    peer.flags |= T.PEER_BAD;
    dead_peers.append(xm.allocator, peer) catch unreachable;
}

fn reap_dead_peers() void {
    for (dead_peers.items) |peer| {
        if (peer.event) |ev| {
            _ = c.libevent.event_del(ev);
            c.libevent.event_free(ev);
            peer.event = null;
        }
        c.imsg.imsgbuf_clear(&peer.ibuf);
        std.posix.close(peer.ibuf.fd);
        xm.allocator.destroy(peer);
    }
    dead_peers.clearRetainingCapacity();
}

pub fn proc_kill_peer(peer: *T.ZmuxPeer) void {
    peer.flags |= T.PEER_BAD;
}

pub fn proc_flush_peer(peer: *T.ZmuxPeer) void {
    _ = c.imsg.imsgbuf_flush(&peer.ibuf);
}

pub fn proc_toggle_log(tp: *T.ZmuxProc) void {
    log.log_toggle(tp.name);
}

pub fn proc_get_peer_uid(peer: *const T.ZmuxPeer) std.posix.uid_t {
    return peer.uid;
}

pub fn proc_fork_and_daemon(fd_out: *i32) std.posix.pid_t {
    var pair: [2]i32 = undefined;
    if (std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &pair) != 0)
        log.fatal("socketpair failed", .{});

    const pid = std.posix.fork() catch log.fatal("fork failed", .{});
    if (pid == 0) {
        // Child: will become the server
        std.posix.close(pair[0]);
        fd_out.* = pair[1];
        // Manual daemonization instead of daemon(3):
        // 1. setsid to detach from controlling terminal
        _ = std.c.setsid();
        // 2. Redirect stdin/stdout/stderr to /dev/null
        const devnull = std.c.open("/dev/null", .{ .ACCMODE = .RDWR }, @as(std.c.mode_t, 0));
        if (devnull >= 0) {
            _ = std.c.dup2(devnull, 0);
            _ = std.c.dup2(devnull, 1);
            _ = std.c.dup2(devnull, 2);
            if (devnull > 2) std.posix.close(@intCast(devnull));
        }
        return 0;
    } else {
        std.posix.close(pair[1]);
        fd_out.* = pair[0];
        return pid;
    }
}
