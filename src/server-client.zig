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
const sess_mod = @import("session.zig");
const tty_draw = @import("tty-draw.zig");
const input_keys = @import("input-keys.zig");
const server_fn = @import("server-fn.zig");
const c = @import("c.zig");
const notify = @import("notify.zig");
const client_registry = @import("client-registry.zig");

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
        .pane_cache = .{},
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
    server_client_cancel_escape_timer(cl);
    if (cl.escape_timer) |ev| {
        c.libevent.event_free(ev);
        cl.escape_timer = null;
    }
    if (cl.title) |title| xm.allocator.free(title);
    if (cl.key_table_name) |name| xm.allocator.free(name);
    cl.stdin_pending.deinit(xm.allocator);
    tty_draw.tty_draw_free(&cl.pane_cache);
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
        .resize => server_client_dispatch_resize(cl, imsg_msg),
        .stdin_data => server_client_dispatch_stdin(cl, imsg_msg),
        .exiting => {
            if (cl.peer) |peer| _ = proc_mod.proc_send(peer, .exited, -1, null, 0);
            server_client_lost(cl);
        },
        else => {
            log.log_debug("client {*} unexpected message {}", .{ cl, msg_type });
        },
    }
}

fn server_client_dispatch_resize(cl: *T.Client, imsg_msg: *c.imsg.imsg) void {
    if (imsg_msg.data == null) return;
    const data_len = imsg_msg.hdr.len -% @sizeOf(c.imsg.imsg_hdr);
    if (data_len < @sizeOf(protocol.MsgResize)) return;
    const msg: *const protocol.MsgResize = @ptrCast(@alignCast(imsg_msg.data.?));

    cl.tty.sx = @max(msg.sx, 1);
    cl.tty.sy = @max(msg.sy, 1);
    cl.tty.xpixel = if (msg.xpixel == 0) T.DEFAULT_XPIXEL else msg.xpixel;
    cl.tty.ypixel = if (msg.ypixel == 0) T.DEFAULT_YPIXEL else msg.ypixel;

    if (cl.session) |s| {
        server_client_apply_session_size(cl, s);
        server_client_force_redraw(cl);
    }
}

fn server_client_dispatch_stdin(cl: *T.Client, imsg_msg: *c.imsg.imsg) void {
    const data_len = imsg_msg.hdr.len -% @sizeOf(c.imsg.imsg_hdr);
    if (data_len == 0) return;
    const bytes: [*]const u8 = @ptrCast(imsg_msg.data.?);
    cl.stdin_pending.appendSlice(xm.allocator, bytes[0..data_len]) catch unreachable;
    server_client_process_stdin_pending(cl);
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
    var cause: ?[]u8 = null;
    const cmd_list = cmd_mod.cmd_parse_from_argv_with_cause(argv.items, cl, &cause) catch {
        defer if (cause) |msg| xm.allocator.free(msg);
        log.log_warn("client {*} parse error: {s}", .{ cl, cause orelse "parse error" });
        cmdq_mod.cmdq_write_client(cl, 2, "{s}", .{cause orelse "parse error"});
        if (cl.peer) |peer| {
            const retval: i32 = 1;
            _ = proc_mod.proc_send(peer, .exit, -1, @ptrCast(std.mem.asBytes(&retval)), @sizeOf(i32));
        }
        return;
    };
    cmdq_mod.cmdq_append(cl, cmd_list);
}

pub fn server_client_loop() void {
    for (client_registry.clients.items) |cl| {
        if (cl.flags & T.CLIENT_EXIT != 0) {
            if (cl.peer) |peer| {
                const retval: i32 = 0;
                _ = proc_mod.proc_send(peer, .exit, -1, @ptrCast(std.mem.asBytes(&retval)), @sizeOf(i32));
            }
            cl.flags &= ~@as(u64, T.CLIENT_EXIT);
        }
        if (cl.flags & T.CLIENT_ATTACHED == 0) continue;
        if (cl.flags & T.CLIENT_REDRAWWINDOW == 0) continue;
        if (cl.flags & T.CLIENT_CONTROL != 0) {
            cl.flags &= ~@as(u64, T.CLIENT_REDRAWWINDOW);
            continue;
        }
        server_client_draw(cl);
        cl.flags &= ~@as(u64, T.CLIENT_REDRAWWINDOW);
    }
}

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
    const old_session = cl.session;
    if (cl.session) |current| {
        if (current == s) {
            server_client_apply_session_size(cl, s);
            return;
        }
        if (current != s and current.attached > 0) current.attached -= 1;
        cl.last_session = current;
    }
    cl.session = s;
    s.attached += 1;
    tty_draw.tty_draw_invalidate(&cl.pane_cache);
    server_client_apply_session_size(cl, s);
    if (old_session != s) notify.notify_client("client-session-changed", cl);
}

pub fn server_client_force_redraw(cl: *T.Client) void {
    tty_draw.tty_draw_invalidate(&cl.pane_cache);
    cl.flags |= T.CLIENT_REDRAWWINDOW;
}

pub fn server_client_attach(cl: *T.Client, s: *T.Session) void {
    server_client_set_session(cl, s);
    server_client_set_key_table(cl, null);
    cl.flags |= T.CLIENT_ATTACHED | T.CLIENT_REDRAWWINDOW;
    if (cl.peer) |peer| {
        _ = proc_mod.proc_send(peer, .ready, -1, null, 0);
    }
}

fn server_client_process_stdin_pending(cl: *T.Client) void {
    server_client_cancel_escape_timer(cl);

    var consumed: usize = 0;
    while (consumed < cl.stdin_pending.items.len) {
        var event: T.key_event = .{};
        const used = input_keys.input_key_get(cl.stdin_pending.items[consumed..], &event) orelse break;
        if (used == 0) break;
        consumed += used;
        server_fn.server_client_handle_key(cl, &event);
    }

    if (consumed != 0) {
        const remaining = cl.stdin_pending.items.len - consumed;
        std.mem.copyForwards(u8, cl.stdin_pending.items[0..remaining], cl.stdin_pending.items[consumed..]);
        cl.stdin_pending.shrinkRetainingCapacity(remaining);
    }

    if (cl.stdin_pending.items.len != 0 and cl.stdin_pending.items[0] == 0x1b) {
        server_client_arm_escape_timer(cl);
    }
}

fn server_client_arm_escape_timer(cl: *T.Client) void {
    const timeout = opts.options_get_number(opts.global_options, "escape-time");
    if (timeout <= 0) {
        server_client_escape_timeout_cb(-1, 0, cl);
        return;
    }

    if (cl.escape_timer == null) {
        const base = proc_mod.libevent orelse return;
        cl.escape_timer = c.libevent.event_new(base, -1, @intCast(c.libevent.EV_TIMEOUT), server_client_escape_timeout_cb, cl);
    }
    if (cl.escape_timer) |ev| {
        var tv = std.posix.timeval{
            .sec = @intCast(@divFloor(timeout, 1000)),
            .usec = @intCast(@mod(timeout, 1000) * 1000),
        };
        _ = c.libevent.event_add(ev, @ptrCast(&tv));
    }
}

fn server_client_cancel_escape_timer(cl: *T.Client) void {
    if (cl.escape_timer) |ev| {
        _ = c.libevent.event_del(ev);
    }
}

export fn server_client_escape_timeout_cb(_fd: c_int, _events: c_short, arg: ?*anyopaque) void {
    _ = _fd;
    _ = _events;
    const cl: *T.Client = @ptrCast(@alignCast(arg orelse return));
    server_client_cancel_escape_timer(cl);
    if (cl.stdin_pending.items.len == 0 or cl.stdin_pending.items[0] != 0x1b) return;

    var event = T.key_event{ .key = T.C0_ESC, .len = 1 };
    event.data[0] = 0x1b;
    server_fn.server_client_handle_key(cl, &event);

    const remaining = cl.stdin_pending.items.len - 1;
    if (remaining != 0) {
        std.mem.copyForwards(u8, cl.stdin_pending.items[0..remaining], cl.stdin_pending.items[1..]);
    }
    cl.stdin_pending.shrinkRetainingCapacity(remaining);
    server_client_process_stdin_pending(cl);
}

pub fn server_client_set_key_table(cl: *T.Client, name: ?[]const u8) void {
    if (cl.key_table_name) |old| {
        xm.allocator.free(old);
        cl.key_table_name = null;
    }
    if (name) |new_name| cl.key_table_name = xm.xstrdup(new_name);
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

fn server_client_draw(cl: *T.Client) void {
    const s = cl.session orelse return;
    const wl = s.curw orelse return;
    const wp = wl.window.active orelse return;
    const sx = if (cl.tty.sx == 0) wp.sx else @min(cl.tty.sx, wp.base.grid.sx);
    const sy = if (cl.tty.sy == 0) wp.sy else @min(cl.tty.sy, wp.base.grid.sy);
    if (sx == 0 or sy == 0) return;
    const payload = tty_draw.tty_draw_pane(&cl.pane_cache, wp, sx, sy) catch return;
    defer xm.allocator.free(payload);

    if (payload.len != 0) {
        if (cl.peer) |peer| {
            var buf: std.ArrayList(u8) = .{};
            defer buf.deinit(xm.allocator);
            const stream: i32 = 1;
            buf.appendSlice(xm.allocator, std.mem.asBytes(&stream)) catch unreachable;
            buf.appendSlice(xm.allocator, payload) catch unreachable;
            _ = proc_mod.proc_send(peer, .write, -1, buf.items.ptr, buf.items.len);
        }
    }
    const title = if (wp.screen.title) |pane_title| pane_title else wl_name(wp.window);
    const title_changed = blk: {
        if (title.len == 0) break :blk cl.title != null;
        if (cl.title) |old| break :blk !std.mem.eql(u8, old, title);
        break :blk true;
    };
    if (title_changed) {
        if (cl.title) |old| xm.allocator.free(old);
        cl.title = if (title.len != 0) xm.xstrdup(title) else null;
    }
    if (title_changed and title.len != 0) {
        const title_seq = std.fmt.allocPrint(xm.allocator, "\x1b]2;{s}\x07", .{title}) catch return;
        defer xm.allocator.free(title_seq);
        if (cl.peer) |peer| {
            var title_buf: std.ArrayList(u8) = .{};
            defer title_buf.deinit(xm.allocator);
            const stream: i32 = 1;
            title_buf.appendSlice(xm.allocator, std.mem.asBytes(&stream)) catch unreachable;
            title_buf.appendSlice(xm.allocator, title_seq) catch unreachable;
            _ = proc_mod.proc_send(peer, .write, -1, title_buf.items.ptr, title_buf.items.len);
        }
    }
}

fn wl_name(w: *T.Window) []const u8 {
    return w.name;
}
