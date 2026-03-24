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
// Ported from tmux/server-client.c
// Original copyright:
//   Copyright (c) 2009 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

//! server-client.zig – per-client state and dispatch on the server side.

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const log = @import("log.zig");
const proc_mod = @import("proc.zig");
const protocol = @import("zmux-protocol.zig");
const opts = @import("options.zig");
const sess = @import("session.zig");
const env_mod = @import("environ.zig");
const cmd_mod = @import("cmd.zig");
const cmdq_mod = @import("cmd-queue.zig");
const win_mod = @import("window.zig");
const c = @import("c.zig");

var next_client_id: u32 = 0;

pub fn server_client_create(fd: i32) *T.Client {
    const cl = xm.allocator.create(T.Client) catch unreachable;
    const env = env_mod.environ_create();

    cl.* = T.Client{
        .id = next_client_id,
        .pid = std.os.linux.getpid(),
        .fd = fd,
        .environ = env,
        .tty = .{ .client = cl },
        .status = .{ .screen = undefined },
        .flags = 0,
    };
    next_client_id += 1;

    const srv = @import("server.zig");
    srv.server_add_client(cl);

    const peer = proc_mod.proc_add_peer(
        srv.server_proc.?,
        fd,
        server_client_dispatch,
        cl,
    );
    cl.peer = peer;

    log.log_debug("new client {*} fd={d}", .{ cl, fd });
    return cl;
}

pub fn server_client_lost(cl: *T.Client) void {
    log.log_debug("lost client {*}", .{cl});
    const srv = @import("server.zig");
    srv.server_remove_client(cl);
    if (cl.peer) |peer| proc_mod.proc_remove_peer(peer);
    cl.peer = null;
    env_mod.environ_free(cl.environ);
    xm.allocator.destroy(cl);
}

export fn server_client_dispatch(imsg_ptr: ?*c.imsg.imsg, arg: ?*anyopaque) void {
    const cl: *T.Client = @ptrCast(@alignCast(arg orelse return));

    if (imsg_ptr == null) {
        server_client_lost(cl);
        return;
    }
    const imsg_msg = imsg_ptr.?;
    const msg_type = std.meta.intToEnum(protocol.MsgType, imsg_msg.hdr.type) catch {
        log.log_warn("client {*} unknown message {d}", .{ cl, imsg_msg.hdr.type });
        return;
    };

    log.log_debug("client {*} message {}", .{ cl, msg_type });

    if (cl.flags & T.CLIENT_IDENTIFIED == 0) {
        server_client_dispatch_identify(cl, imsg_msg, msg_type);
        return;
    }

    switch (msg_type) {
        .command => server_client_dispatch_command(cl, imsg_msg),
        .resize => {},
        .exiting => {
            if (cl.peer) |peer| _ = proc_mod.proc_send(peer, .exited, -1, null, 0);
            server_client_lost(cl);
        },
        else => {
            log.log_debug("client {*} unexpected message {}", .{ cl, msg_type });
        },
    }
}

fn server_client_dispatch_identify(cl: *T.Client, imsg_msg: *c.imsg.imsg, msg_type: protocol.MsgType) void {
    const data_len = imsg_msg.hdr.len -% @sizeOf(c.imsg.imsg_hdr);
    const data: [*]const u8 = if (imsg_msg.data != null)
        @ptrCast(imsg_msg.data.?)
    else
        (&[0]u8{});

    switch (msg_type) {
        .identify_flags, .identify_longflags => {
            if (data_len >= @sizeOf(u64)) {
                var flags: u64 = 0;
                @memcpy(std.mem.asBytes(&flags), data[0..@sizeOf(u64)]);
                cl.flags |= flags;
            }
        },
        .identify_term => {
            if (data_len > 0) {
                const term = data[0 .. data_len - 1];
                if (cl.term_name) |old| xm.allocator.free(old);
                cl.term_name = xm.xstrdup(term);
            }
        },
        .identify_ttyname => {
            if (data_len > 0) {
                const ttyname = data[0 .. data_len - 1];
                if (cl.ttyname) |old| xm.allocator.free(old);
                cl.ttyname = xm.xstrdup(ttyname);
            }
        },
        .identify_cwd => {
            if (data_len > 0) {
                const cwd = data[0 .. data_len - 1];
                if (cl.cwd) |old| xm.allocator.free(@constCast(old));
                cl.cwd = xm.xstrdup(cwd);
            }
        },
        .identify_environ => {
            if (data_len > 0) {
                const var_str = data[0 .. data_len - 1];
                env_mod.environ_put(cl.environ, var_str, 0);
            }
        },
        .identify_clientpid => {
            if (data_len >= @sizeOf(std.posix.pid_t)) {
                @memcpy(std.mem.asBytes(&cl.pid), data[0..@sizeOf(std.posix.pid_t)]);
            }
        },
        .identify_done => {
            cl.flags |= T.CLIENT_IDENTIFIED;
            log.log_debug("client {*} identified", .{cl});
        },
        else => {},
    }
}

fn server_client_dispatch_command(cl: *T.Client, imsg_msg: *c.imsg.imsg) void {
    const data_len = imsg_msg.hdr.len -% @sizeOf(c.imsg.imsg_hdr);
    if (data_len < @sizeOf(protocol.MsgCommand)) {
        log.log_warn("client {*} short MSG_COMMAND", .{cl});
        return;
    }
    const msg_cmd: *const protocol.MsgCommand = @ptrCast(@alignCast(imsg_msg.data));
    const argc: i32 = msg_cmd.argc;
    if (argc < 0) return;

    const argv_ptr: [*]const u8 = @ptrCast(@alignCast(@as([*]const u8, @ptrCast(imsg_msg.data)) + @sizeOf(protocol.MsgCommand)));
    const argv_len = data_len - @sizeOf(protocol.MsgCommand);

    var argv: std.ArrayList([]const u8) = .{};
    defer argv.deinit(xm.allocator);

    var pos: usize = 0;
    var count: i32 = 0;
    while (count < argc and pos < argv_len) : (count += 1) {
        const nul_pos = std.mem.indexOfScalarPos(u8, argv_ptr[0..argv_len], pos, 0) orelse argv_len;
        argv.append(xm.allocator, argv_ptr[pos..nul_pos]) catch unreachable;
        pos = nul_pos + 1;
    }

    log.log_debug("client {*} command argc={d}", .{ cl, argc });
    const cmd_list = cmd_mod.cmd_parse_from_argv(argv.items, cl) catch {
        log.log_warn("client {*} parse error", .{cl});
        if (cl.peer) |peer| {
            _ = proc_mod.proc_send(peer, .exit, -1, null, 0);
        }
        return;
    };
    cmdq_mod.cmdq_append(cl, cmd_list);
}

pub fn server_client_loop() void {}

pub fn server_client_apply_session_size(cl: *T.Client, s: *T.Session) void {
    const wl = s.curw orelse return;
    const sx = if (cl.tty.sx == 0) @as(u32, 80) else cl.tty.sx;
    const sy = if (cl.tty.sy == 0) @as(u32, 24) else cl.tty.sy;
    const w = wl.window;

    win_mod.window_resize(w, sx, sy, @intCast(w.xpixel), @intCast(w.ypixel));
    for (w.panes.items) |wp| {
        wp.sx = sx;
        wp.sy = sy;
    }
}

pub fn server_client_set_session(cl: *T.Client, s: *T.Session) void {
    if (cl.session) |old| {
        if (old == s) {
            server_client_apply_session_size(cl, s);
            return;
        }
        if (old != s and old.attached > 0) old.attached -= 1;
        cl.last_session = old;
    }
    cl.session = s;
    s.attached += 1;
    server_client_apply_session_size(cl, s);
}

pub fn server_client_set_key_table(_cl: *T.Client, _name: ?[]const u8) void {
    _ = _cl;
    _ = _name;
}

pub fn server_client_get_cwd(cl: ?*T.Client, _s: ?*T.Session) []const u8 {
    _ = _s;
    if (cl) |c_val| {
        if (c_val.cwd) |cwd| return cwd;
    }
    return "/";
}

pub fn server_client_check_nested(cl: *T.Client) bool {
    if (cl.environ.entries.get("ZMUX")) |entry| {
        if (entry.value != null) return true;
    }
    return false;
}

pub fn server_client_open(_cl: *T.Client, _cause: *?[]u8) i32 {
    _ = _cl;
    _ = _cause;
    return 0;
}
