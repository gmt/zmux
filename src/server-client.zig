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
const zmux_mod = @import("zmux.zig");
const protocol = @import("zmux-protocol.zig");
const file_mod = @import("file.zig");
const opts = @import("options.zig");
const sess = @import("session.zig");
const env_mod = @import("environ.zig");
const editor_handoff = @import("editor-handoff.zig");
const cmd_mod = @import("cmd.zig");
const cmd_display_panes = @import("cmd-display-panes.zig");
const cmdq_mod = @import("cmd-queue.zig");
const menu = @import("menu.zig");
const win_mod = @import("window.zig");
const tty_mod = @import("tty.zig");
const tty_draw = @import("tty-draw.zig");
const input_keys = @import("input-keys.zig");
const mouse_runtime = @import("mouse-runtime.zig");
const resize_mod = @import("resize.zig");
const server_fn = @import("server-fn.zig");
const c = @import("c.zig");
const notify = @import("notify.zig");
const client_registry = @import("client-registry.zig");
const alerts = @import("alerts.zig");
const status = @import("status.zig");
const status_prompt = @import("status-prompt.zig");
const status_runtime = @import("status-runtime.zig");
const screen_mod = @import("screen.zig");
const screen_redraw = @import("screen-redraw.zig");
const control = @import("control.zig");
const control_subscriptions = @import("control-subscriptions.zig");
const sc_visible = @import("server-client-visible.zig");
const popup = @import("popup.zig");
const key_bindings = @import("key-bindings.zig");

var next_client_id: u32 = 0;

pub fn server_client_create(fd: i32) *T.Client {
    const cl = xm.allocator.create(T.Client) catch unreachable;
    const env = env_mod.environ_create();
    const now = std.time.milliTimestamp();

    cl.* = T.Client{
        .id = next_client_id,
        .creation_time = now,
        .activity_time = now,
        .last_activity_time = now,
        .pid = std.os.linux.getpid(),
        .fd = -1,
        .environ = env,
        .tty = .{ .client = cl },
        .status = .{},
        .pane_cache = .{},
        .flags = 0,
    };
    tty_mod.tty_init(&cl.tty, cl);
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
    cl.flags |= T.CLIENT_DEAD;
    const was_attached = (cl.flags & T.CLIENT_ATTACHED) != 0;
    file_mod.cleanupServerStreamFilesForClient(cl);
    file_mod.failPendingReadsForClient(cl);
    file_mod.failPendingWritesForClient(cl);
    editor_handoff.clearClient(cl);
    cmd_display_panes.clear_overlay(cl);
    menu.clear_overlay(cl);
    popup.clear_overlay(cl);
    status_prompt.status_prompt_clear(cl);
    status_runtime.status_message_clear(cl);
    status_runtime.status_cleanup(cl);
    status.status_free(cl);
    const srv = @import("server.zig");
    srv.server_remove_client(cl);
    if (was_attached)
        notify.notify_client("client-detached", cl);
    if (cl.peer) |peer| proc_mod.proc_remove_peer(peer);
    cl.peer = null;
    server_client_cancel_escape_timer(cl);
    server_client_cancel_click_timer(cl);
    if (cl.escape_timer) |ev| {
        c.libevent.event_free(ev);
        cl.escape_timer = null;
    }
    if (cl.click_timer) |ev| {
        c.libevent.event_free(ev);
        cl.click_timer = null;
    }
    if (cl.cwd) |cwd| xm.allocator.free(@constCast(cwd));
    if (cl.term_name) |term_name| xm.allocator.free(term_name);
    if (cl.term_caps) |caps| {
        for (caps) |cap| xm.allocator.free(cap);
        xm.allocator.free(caps);
    }
    if (cl.ttyname) |ttyname| xm.allocator.free(ttyname);
    if (cl.title) |title| xm.allocator.free(title);
    if (cl.path) |path| xm.allocator.free(path);
    if (cl.key_table_name) |name| xm.allocator.free(name);
    cl.client_windows.deinit(xm.allocator);
    control.control_panes_deinit(cl);
    control_subscriptions.control_subscriptions_deinit(cl);
    if (cl.control_read_event) |ev| {
        _ = c.libevent.event_del(ev);
        c.libevent.event_free(ev);
        cl.control_read_event = null;
    }
    cl.control_input_buf.deinit(xm.allocator);
    cl.stdin_pending.deinit(xm.allocator);
    tty_mod.tty_close(&cl.tty);
    server_client_close_terminal_fds(cl);
    tty_draw.tty_draw_free(&cl.pane_cache);
    resize_mod.recalculate_sizes();
    srv.server_update_socket();
    env_mod.environ_free(cl.environ);
    server_client_unref(cl);
}

pub fn server_client_get_client_window(cl: *T.Client, id: u32) ?*T.ClientWindow {
    for (cl.client_windows.items) |*cw| {
        if (cw.window == id) return cw;
    }
    return null;
}

pub fn server_client_add_client_window(cl: *T.Client, id: u32) *T.ClientWindow {
    if (server_client_get_client_window(cl, id)) |cw|
        return cw;

    cl.client_windows.append(xm.allocator, .{ .window = id }) catch unreachable;
    return &cl.client_windows.items[cl.client_windows.items.len - 1];
}

pub fn server_client_get_pane(cl: *T.Client) ?*T.WindowPane {
    const s = cl.session orelse return null;
    const wl = s.curw orelse return null;
    const active = wl.window.active;

    if (cl.flags & T.CLIENT_ACTIVEPANE == 0)
        return active;
    if (server_client_get_client_window(cl, wl.window.id)) |cw| {
        if (cw.pane) |pane| return pane;
    }
    return active;
}

pub fn server_client_set_pane(cl: *T.Client, wp: *T.WindowPane) void {
    const s = cl.session orelse return;
    const wl = s.curw orelse return;
    const cw = server_client_add_client_window(cl, wl.window.id);
    cw.pane = wp;
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
        .shell => server_client_dispatch_shell(cl, imsg_msg),
        .resize => server_client_dispatch_resize(cl, imsg_msg),
        .unlock => {
            var unlock_status: i32 = 0;
            const data_len = imsg_msg.hdr.len -% @sizeOf(c.imsg.imsg_hdr);
            if (data_len >= @sizeOf(i32) and imsg_msg.data != null)
                @memcpy(std.mem.asBytes(&unlock_status), @as([*]const u8, @ptrCast(imsg_msg.data.?))[0..@sizeOf(i32)]);
            editor_handoff.handleUnlock(cl, unlock_status);
            server_client_unlock(cl);
        },
        .wakeup => server_client_unlock(cl),
        .read => file_mod.handleReadData(imsg_msg),
        .read_done => file_mod.handleReadDone(imsg_msg),
        .write_ready => file_mod.handleWriteReadyForClient(cl, imsg_msg),
        .exiting => {
            if (cl.peer) |peer| _ = proc_mod.proc_send(peer, .exited, -1, null, 0);
            server_client_lost(cl);
        },
        else => {
            log.log_debug("client {*} unexpected message {}", .{ cl, msg_type });
        },
    }
}

/// Same as `server_client_dispatch` libevent callback; exposed for Zig unit tests.
pub fn server_client_dispatch_for_test(imsg_ptr: ?*c.imsg.imsg, cl: *T.Client) void {
    server_client_dispatch(imsg_ptr, @ptrCast(cl));
}

fn server_client_dispatch_resize(cl: *T.Client, imsg_msg: *c.imsg.imsg) void {
    const data_len = imsg_msg.hdr.len -% @sizeOf(c.imsg.imsg_hdr);
    if (data_len != 0) return;

    var sx: u32 = 80;
    var sy: u32 = 24;
    var xpixel: u32 = 0;
    var ypixel: u32 = 0;

    if (cl.fd >= 0) {
        var ws: c.posix_sys.winsize = undefined;
        if (c.posix_sys.ioctl(cl.fd, c.posix_sys.TIOCGWINSZ, &ws) == 0) {
            sx = @max(@as(u32, ws.ws_col), 1);
            sy = @max(@as(u32, ws.ws_row), 1);
            xpixel = ws.ws_xpixel;
            ypixel = ws.ws_ypixel;
        }
    }

    tty_mod.tty_resize(&cl.tty, sx, sy, xpixel, ypixel);
    tty_mod.tty_repeat_requests(&cl.tty, 0);
    cl.flags |= T.CLIENT_SIZECHANGED;
    if (popup.overlay_active(cl))
        popup.popup_resize_cb(cl, cl.popup_data);

    if (cl.session) |s| {
        server_client_apply_session_size(cl, s);
        server_client_force_redraw(cl);
    }
}

/// libevent callback for reading control client input directly from cl.fd.
/// Buffers bytes in cl.control_input_buf and dispatches each complete
/// newline-terminated line via control_read_callback.
export fn control_stdin_read_cb(_fd: c_int, _events: c_short, arg: ?*anyopaque) void {
    _ = _events;
    const cl: *T.Client = @ptrCast(@alignCast(arg orelse return));
    if (!cl.control_ready_flag) return;
    const fd: std.posix.fd_t = if (_fd >= 0) _fd else cl.fd;
    if (fd < 0) return;

    var buf: [4096]u8 = undefined;
    const n = std.posix.read(@intCast(fd), &buf) catch return;
    if (n == 0) {
        // EOF — flag client for exit.
        cl.flags |= T.CLIENT_EXIT;
        return;
    }

    cl.control_input_buf.appendSlice(xm.allocator, buf[0..n]) catch return;

    while (true) {
        const items = cl.control_input_buf.items;
        const nl = std.mem.indexOfScalar(u8, items, '\n') orelse break;
        var line_end = nl;
        if (line_end > 0 and items[line_end - 1] == '\r')
            line_end -= 1;
        const line = items[0..line_end];

        control.control_read_callback(cl, line);

        const remaining = items.len - nl - 1;
        if (remaining > 0)
            std.mem.copyForwards(u8, cl.control_input_buf.items[0..remaining], items[nl + 1 ..]);
        cl.control_input_buf.shrinkRetainingCapacity(remaining);
    }
}

pub fn server_client_lock(cl: *T.Client, cmd: []const u8) void {
    const peer = cl.peer orelse return;

    tty_mod.tty_stop_tty(&cl.tty);
    tty_draw.tty_draw_invalidate(&cl.pane_cache);
    cl.flags |= T.CLIENT_SUSPENDED;

    const cmd_z = xm.xm_dupeZ(cmd);
    defer xm.allocator.free(cmd_z);
    _ = proc_mod.proc_send(peer, .lock, -1, cmd_z.ptr, cmd.len + 1);
}

pub fn server_client_suspend(cl: *T.Client) void {
    const peer = cl.peer orelse return;
    _ = cl.session orelse return;
    if (cl.flags & (T.CLIENT_SUSPENDED | T.CLIENT_EXIT) != 0) return;

    tty_mod.tty_stop_tty(&cl.tty);
    tty_draw.tty_draw_invalidate(&cl.pane_cache);
    cl.flags |= T.CLIENT_SUSPENDED;
    _ = proc_mod.proc_send(peer, .@"suspend", -1, null, 0);
}

pub fn server_client_unlock(cl: *T.Client) void {
    if (cl.flags & T.CLIENT_SUSPENDED == 0) return;
    cl.flags &= ~@as(u64, T.CLIENT_SUSPENDED);

    if (cl.fd == -1) return;
    const s = cl.session orelse return;

    const now = std.time.milliTimestamp();
    cl.last_activity_time = cl.activity_time;
    cl.activity_time = now;
    sess.session_update_activity(s, now);

    tty_mod.tty_start_tty(&cl.tty);
    server_client_force_redraw(cl);
    resize_mod.recalculate_sizes();
}

pub fn server_client_detach(cl: *T.Client, msg_type: protocol.MsgType) void {
    const s = cl.session orelse return;

    if (s.attached > 0) s.attached -= 1;
    cl.last_session = s;
    cl.session = null;
    cl.flags &= ~@as(u64, T.CLIENT_ATTACHED);
    cl.exit_reason = switch (msg_type) {
        .detachkill => .detached_hup,
        else => .detached,
    };

    if (cl.exit_session) |old| xm.allocator.free(old);
    cl.exit_session = xm.xstrdup(s.name);

    notify.notify_client("client-detached", cl);
    const srv = @import("server.zig");
    srv.server_update_socket();
    cl.flags |= T.CLIENT_EXIT;
}

fn server_client_exec_shell(s: ?*T.Session) []const u8 {
    const shell = if (s) |session|
        opts.options_get_string(session.options, "default-shell")
    else
        opts.options_get_string(opts.global_s_options, "default-shell");

    if (shell.len == 0 or shell[0] != '/') return "/bin/sh";
    std.fs.accessAbsolute(shell, .{}) catch return "/bin/sh";
    return shell;
}

pub fn server_client_exec(cl: *T.Client, cmd: []const u8) void {
    if (cmd.len == 0) return;

    const shell = server_client_exec_shell(cl.session);
    var payload = std.ArrayList(u8){};
    defer payload.deinit(xm.allocator);

    payload.appendSlice(xm.allocator, cmd) catch unreachable;
    payload.append(xm.allocator, 0) catch unreachable;
    payload.appendSlice(xm.allocator, shell) catch unreachable;
    payload.append(xm.allocator, 0) catch unreachable;

    if (cl.peer) |peer| {
        _ = proc_mod.proc_send(peer, .exec, -1, payload.items.ptr, payload.items.len);
    }
}

pub fn server_client_send_shell(cl: *T.Client) void {
    const peer = cl.peer orelse return;
    const shell = server_client_exec_shell(null);
    _ = proc_mod.proc_send(peer, .shell, -1, shell.ptr, shell.len + 1);
    proc_mod.proc_kill_peer(peer);
}

fn server_client_dispatch_shell(cl: *T.Client, imsg_msg: *c.imsg.imsg) void {
    const data_len = imsg_msg.hdr.len -% @sizeOf(c.imsg.imsg_hdr);
    if (data_len != 0) {
        if (cl.peer) |peer| proc_mod.proc_kill_peer(peer);
        return;
    }
    server_client_send_shell(cl);
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
        .identify_terminfo => {
            if (data_len > 0) {
                const cap = data[0 .. data_len - 1];
                if (cl.term_caps) |old| {
                    const resized = xm.allocator.realloc(old, old.len + 1) catch unreachable;
                    resized[old.len] = xm.xstrdup(cap);
                    cl.term_caps = resized;
                } else {
                    const caps = xm.allocator.alloc([]u8, 1) catch unreachable;
                    caps[0] = xm.xstrdup(cap);
                    cl.term_caps = caps;
                }
            }
        },
        .identify_ttyname => {
            if (data_len > 0) {
                const ttyname = data[0 .. data_len - 1];
                if (cl.ttyname) |old| xm.allocator.free(old);
                cl.ttyname = xm.xstrdup(ttyname);
            }
        },
        .identify_stdin => {
            if (data_len == 0) {
                const fd = c.imsg.imsg_get_fd(imsg_msg);
                if (fd != -1) {
                    if (cl.fd != -1) _ = c.posix_sys.close(cl.fd);
                    cl.fd = fd;
                }
            }
        },
        .identify_features => {
            if (data_len >= @sizeOf(i32)) {
                var features: i32 = 0;
                @memcpy(std.mem.asBytes(&features), data[0..@sizeOf(i32)]);
                cl.term_features |= features;
            }
        },
        .identify_stdout => {
            if (data_len == 0) {
                const fd = c.imsg.imsg_get_fd(imsg_msg);
                if (fd != -1) {
                    if (cl.out_fd != -1) _ = c.posix_sys.close(cl.out_fd);
                    cl.out_fd = fd;
                }
            }
        },
        .identify_cwd => {
            if (data_len > 0) {
                const cwd = data[0 .. data_len - 1];
                server_client_set_cwd(cl, server_client_resolve_cwd(cwd));
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
            server_client_finalize_identify(cl);
            log.log_debug("client {*} identified", .{cl});
        },
        else => {},
    }
}

pub fn server_client_finalize_identify(cl: *T.Client) void {
    if (cl.term_name == null or cl.term_name.?.len == 0) {
        if (cl.term_name) |old| xm.allocator.free(old);
        cl.term_name = xm.xstrdup("unknown");
    }
    if (cl.term_caps == null)
        cl.term_caps = xm.allocator.alloc([]u8, 0) catch unreachable;
    if (cl.name) |old| {
        xm.allocator.free(@constCast(old));
        cl.name = null;
    }
    cl.name = server_client_build_name(cl);

    if ((cl.flags & T.CLIENT_CONTROL) != 0) {
        control.control_start(cl);

        // Register a libevent read event on the client fd so the server
        // reads control input directly, mirroring tmux's bufferevent on
        // c->fd set up in control_start().
        if (cl.fd >= 0) {
            const base = proc_mod.libevent orelse {
                server_client_close_terminal_fds(cl);
                return;
            };
            const ev = c.libevent.event_new(
                base,
                cl.fd,
                @intCast(c.libevent.EV_PERSIST | c.libevent.EV_READ),
                control_stdin_read_cb,
                cl,
            );
            if (ev) |e| {
                cl.control_read_event = e;
            }
        }

        // Close out_fd but keep cl.fd open — it is now monitored by the
        // control read event (like tmux keeps c->fd for the bufferevent).
        if (cl.out_fd != -1) {
            _ = c.posix_sys.close(cl.out_fd);
            cl.out_fd = -1;
        }
        return;
    }

    if (cl.fd != -1 and c.posix_sys.isatty(cl.fd) != 0) {
        cl.flags |= T.CLIENT_TERMINAL;
        var tio: c.posix_sys.termios = undefined;
        if (c.posix_sys.tcgetattr(cl.fd, &tio) == 0) {
            cl.tty.saved_tio = tio;
        }
        if (cl.out_fd != -1) {
            _ = c.posix_sys.close(cl.out_fd);
            cl.out_fd = -1;
        }
        return;
    }

    server_client_close_terminal_fds(cl);
}

fn server_client_close_terminal_fds(cl: *T.Client) void {
    if (cl.out_fd != -1) {
        _ = c.posix_sys.close(cl.out_fd);
        cl.out_fd = -1;
    }
    if (cl.fd != -1) {
        _ = c.posix_sys.close(cl.fd);
        cl.fd = -1;
    }
}

fn server_client_build_name(cl: *const T.Client) []const u8 {
    if (cl.ttyname) |ttyname| {
        if (ttyname.len != 0) return xm.xstrdup(ttyname);
    }
    return xm.xasprintf("client-{d}", .{cl.pid});
}

fn server_client_control_flags(cl: *T.Client, next: []const u8) u64 {
    if (std.mem.eql(u8, next, "pause-after")) {
        cl.pause_age = 0;
        return T.CLIENT_CONTROL_PAUSEAFTER;
    }
    if (std.mem.startsWith(u8, next, "pause-after=")) {
        const seconds = std.fmt.parseInt(u32, next["pause-after=".len..], 10) catch return 0;
        cl.pause_age = std.math.mul(u32, seconds, 1000) catch std.math.maxInt(u32);
        return T.CLIENT_CONTROL_PAUSEAFTER;
    }
    if (std.mem.eql(u8, next, "no-output")) return T.CLIENT_CONTROL_NOOUTPUT;
    if (std.mem.eql(u8, next, "wait-exit")) return T.CLIENT_CONTROL_WAITEXIT;
    return 0;
}

pub fn server_client_set_flags(cl: *T.Client, flags_text: []const u8) void {
    var it = std.mem.splitScalar(u8, flags_text, ',');
    while (it.next()) |raw_flag| {
        if (raw_flag.len == 0) continue;

        const negate = raw_flag[0] == '!';
        const next = if (negate) raw_flag[1..] else raw_flag;
        if (next.len == 0) continue;

        var flag: u64 = if (cl.flags & T.CLIENT_CONTROL != 0)
            server_client_control_flags(cl, next)
        else
            0;
        if (std.mem.eql(u8, next, "read-only"))
            flag = T.CLIENT_READONLY
        else if (std.mem.eql(u8, next, "ignore-size"))
            flag = T.CLIENT_IGNORESIZE
        else if (std.mem.eql(u8, next, "active-pane"))
            flag = T.CLIENT_ACTIVEPANE
        else if (std.mem.eql(u8, next, "no-detach-on-destroy"))
            flag = T.CLIENT_NO_DETACH_ON_DESTROY;
        if (flag == 0) continue;

        if (negate) {
            if (cl.flags & T.CLIENT_READONLY != 0)
                flag &= ~@as(u64, T.CLIENT_READONLY);
            cl.flags &= ~flag;
        } else {
            cl.flags |= flag;
        }
    }

    if (cl.peer) |peer| {
        _ = proc_mod.proc_send(peer, .flags, -1, std.mem.asBytes(&cl.flags).ptr, @sizeOf(u64));
    }
}

pub fn server_client_resolve_cwd(candidate: []const u8) []const u8 {
    if (server_client_cwd_exists(candidate)) return candidate;
    if (std.posix.getenv("HOME")) |home| return home;
    return "/";
}

fn server_client_cwd_exists(path: []const u8) bool {
    if (!std.fs.path.isAbsolute(path)) return false;
    var dir = std.fs.openDirAbsolute(path, .{}) catch return false;
    dir.close();
    return true;
}

fn server_client_set_cwd(cl: *T.Client, cwd: []const u8) void {
    if (cl.cwd) |old| xm.allocator.free(@constCast(old));
    cl.cwd = xm.xstrdup(cwd);
}

fn server_client_send_exit_status(cl: *T.Client, retval: i32) void {
    if (cl.peer) |peer| {
        _ = proc_mod.proc_send(peer, .exit, -1, @ptrCast(std.mem.asBytes(&retval)), @sizeOf(i32));
    }
}

fn server_client_command_done(item: *cmdq_mod.CmdqItem, _: ?*anyopaque) T.CmdRetval {
    const cl = cmdq_mod.cmdq_get_client(item) orelse return .normal;
    if (cl.flags & T.CLIENT_ATTACHED == 0) {
        cl.flags |= T.CLIENT_EXIT;
    } else if (cl.flags & T.CLIENT_EXIT == 0) {
        if (cl.flags & T.CLIENT_CONTROL != 0)
            control.control_ready(cl);
        tty_mod.tty_send_requests(&cl.tty);
    }
    return .normal;
}

fn server_client_enqueue_command_list(cl: *T.Client, cmd_list: *cmd_mod.CmdList) void {
    if (cl.flags & T.CLIENT_READONLY != 0 and !cmd_mod.cmd_list_all_have(@ptrCast(cmd_list), T.CMD_READONLY)) {
        cmd_mod.cmd_list_free(cmd_list);
        status_runtime.present_client_message(cl, "client is read-only");
        server_client_send_exit_status(cl, 1);
        return;
    }
    cmdq_mod.cmdq_append(cl, cmd_list);
    _ = cmdq_mod.cmdq_append_item(cl, cmdq_mod.cmdq_get_callback1("server-client-command-done", server_client_command_done, null));
}

/// Exposed for Zig unit tests (`server-client-test.zig`).
pub fn server_client_enqueue_command_list_for_tests(cl: *T.Client, cmd_list: *cmd_mod.CmdList) void {
    server_client_enqueue_command_list(cl, cmd_list);
}

fn server_client_dispatch_default_command(cl: *T.Client) void {
    const command = opts.options_get_command_string(opts.global_options, "default-client-command");
    var parse_input = T.CmdParseInput{ .c = cl };
    const parsed = cmd_mod.cmd_parse_from_string(command, &parse_input);
    switch (parsed.status) {
        .success => {
            const cmd_list: *cmd_mod.CmdList = @ptrCast(@alignCast(parsed.cmdlist.?));
            server_client_enqueue_command_list(cl, cmd_list);
        },
        .@"error" => {
            const message = parsed.@"error" orelse xm.xstrdup("parse error");
            defer xm.allocator.free(message);
            log.log_warn("client {*} default command parse error: {s}", .{ cl, message });
            status_runtime.present_client_message(cl, message);
            server_client_send_exit_status(cl, 1);
        },
    }
}

pub fn server_client_dispatch_command(cl: *T.Client, imsg_msg: *c.imsg.imsg) void {
    if (cl.flags & T.CLIENT_EXIT != 0)
        return;

    const data_len = imsg_msg.hdr.len -% @sizeOf(c.imsg.imsg_hdr);
    if (data_len < @sizeOf(protocol.MsgCommand)) {
        log.log_warn("client {*} short MSG_COMMAND", .{cl});
        return;
    }
    const msg_cmd: *const protocol.MsgCommand = @ptrCast(@alignCast(imsg_msg.data));
    const argc: i32 = msg_cmd.argc;
    if (argc < 0) return;
    if (argc == 0) {
        log.log_debug("client {*} command argc=0 uses default-client-command", .{cl});
        server_client_dispatch_default_command(cl);
        return;
    }

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
        status_runtime.present_client_message(cl, cause orelse "parse error");
        server_client_send_exit_status(cl, 1);
        return;
    };
    server_client_enqueue_command_list(cl, cmd_list);
}

pub fn server_client_loop() void {
    var wit = win_mod.windows.valueIterator();
    while (wit.next()) |w_ptr| {
        server_client_check_window_resize(w_ptr.*);
    }

    for (client_registry.clients.items) |cl| {
        server_client_check_exit(cl);

        if (cl.flags & T.CLIENT_CONTROL != 0)
            control.control_write_callback(cl);

        if (cl.session == null) continue;
        if (cl.flags & T.CLIENT_ATTACHED == 0) continue;
        if (cl.flags & T.CLIENT_SUSPENDED != 0) continue;

        server_client_check_modes(cl);
        server_client_check_redraw(cl);
        server_client_reset_state(cl);
    }

    wit = win_mod.windows.valueIterator();
    while (wit.next()) |w_ptr| {
        const w = w_ptr.*;
        for (w.panes.items) |wp| {
            if (wp.fd != -1) {
                server_client_check_pane_resize(wp);
                server_client_check_pane_buffer(wp);
            }
            wp.flags &= ~@as(u32, T.PANE_REDRAW);
        }
    }
}

/// Check if client should be exited and send the appropriate message.
pub fn server_client_check_exit(cl: *T.Client) void {
    if (cl.flags & T.CLIENT_EXIT == 0) return;
    if (file_mod.clientWriteLeft(cl)) return;

    if (cl.flags & T.CLIENT_CONTROL != 0) {
        control.control_discard(cl);
        if (!control.control_all_done(cl)) return;
    }

    const peer = cl.peer orelse return;

    switch (cl.exit_reason) {
        .detached, .detached_hup => {
            const name = cl.exit_session orelse "";
            const msg_type: protocol.MsgType = if (cl.exit_reason == .detached_hup) .detachkill else .detach;
            _ = proc_mod.proc_send(peer, msg_type, -1, name.ptr, name.len + 1);
        },
        .none, .lost_tty, .terminated, .lost_server => {
            const retval: i32 = cl.retval;
            _ = proc_mod.proc_send(peer, .exit, -1, @ptrCast(std.mem.asBytes(&retval)), @sizeOf(i32));
        },
        .exited => {
            _ = proc_mod.proc_send(peer, .exiting, -1, null, 0);
        },
        .server_exited => {
            _ = proc_mod.proc_send(peer, .shutdown, -1, null, 0);
        },
        .message_provided => {
            const msg = cl.exit_message orelse "";
            const payload_len = @sizeOf(i32) + msg.len + 1;
            const payload = xm.allocator.alloc(u8, payload_len) catch unreachable;
            defer xm.allocator.free(payload);
            @memcpy(payload[0..@sizeOf(i32)], std.mem.asBytes(&cl.retval));
            @memcpy(payload[@sizeOf(i32) .. @sizeOf(i32) + msg.len], msg);
            payload[payload.len - 1] = 0;
            _ = proc_mod.proc_send(peer, .exit, -1, payload.ptr, payload.len);
        },
    }
    cl.flags &= ~@as(u64, T.CLIENT_EXIT);
    if (cl.exit_message) |msg| {
        xm.allocator.free(msg);
        cl.exit_message = null;
    }
    if (cl.exit_session) |name| {
        xm.allocator.free(name);
        cl.exit_session = null;
    }
}

/// Check if pane modes need updating during status redraw.
pub fn server_client_check_modes(cl: *T.Client) void {
    if (cl.flags & T.CLIENT_CONTROL != 0) return;
    if (cl.flags & T.CLIENT_SUSPENDED != 0) return;
    if (cl.flags & T.CLIENT_REDRAWSTATUS == 0) return;

    const s = cl.session orelse return;
    const wl = s.curw orelse return;
    const w = wl.window;

    for (w.panes.items) |wp| {
        if (wp.modes.items.len == 0) continue;
        const wme = wp.modes.items[0];
        if (wme.mode.update) |update_fn| update_fn(wme);
    }
}

/// Check if client needs a redraw and perform it if output buffer is clear.
///
/// Two draw paths run in sequence:
///  - screen-redraw dispatch (per-pane and full-screen via tty-level drawing)
///  - payload-based IPC fallback (build_client_draw_payload -> sendPeerStream)
pub fn server_client_check_redraw(cl: *T.Client) void {
    if (cl.flags & T.CLIENT_CONTROL != 0) return;
    if (cl.flags & T.CLIENT_SUSPENDED != 0) return;

    var needed: bool = false;
    if (cl.flags & T.CLIENT_ALLREDRAWFLAGS != 0) {
        needed = true;
    }

    if (!needed) {
        const s = cl.session orelse return;
        const wl = s.curw orelse return;
        const w = wl.window;
        for (w.panes.items) |wp| {
            if (wp.flags & T.PANE_REDRAW != 0) {
                needed = true;
                break;
            }
        }
    }

    if (!needed) return;

    // Per-pane redraw when the full window is not being redrawn.
    if (cl.flags & T.CLIENT_REDRAWWINDOW == 0) {
        if (cl.session) |s| {
            if (s.curw) |wl| {
                const w = wl.window;
                for (w.panes.items) |wp| {
                    if (wp.flags & T.PANE_REDRAW != 0) {
                        log.log_debug("server_client_check_redraw: pane %%{d}", .{wp.id});
                        screen_redraw.screen_redraw_pane(cl, wp, false);
                    }
                }
            }
        }
    }

    if (cl.flags & T.CLIENT_ALLREDRAWFLAGS != 0) {
        server_client_set_title(cl);
        server_client_set_path(cl);
        screen_redraw.screen_redraw_screen(cl);
    }

    // Payload-based fallback for borders, scrollbars, status, overlay.
    const redraw_flags = cl.flags & T.CLIENT_ALLREDRAWFLAGS;
    server_client_draw(cl, redraw_flags);
    tty_mod.tty_sync_end(&cl.tty);

    cl.flags &= ~@as(u64, T.CLIENT_ALLREDRAWFLAGS);
}

/// Reset terminal cursor and mode state between events.
pub fn server_client_reset_state(cl: *T.Client) void {
    if (cl.flags & (T.CLIENT_CONTROL | T.CLIENT_SUSPENDED) != 0) return;

    if (log.log_get_level() != 0) {
        log.log_debug("server_client_reset_state: client {s} mode {s}", .{
            cl.name orelse "(unknown)",
            screen_mod.screen_mode_to_string(cl.tty.mode),
        });
    }

    // If an overlay or the prompt is active, ensure cursor is hidden.
    const overlay_active = cmd_display_panes.overlay_active(cl) or menu.overlay_active(cl) or popup.overlay_active(cl);
    const prompt_active = cl.message_string != null;
    if (overlay_active or prompt_active) {
        cl.tty.flags |= T.TTY_NOCURSOR;
    } else {
        cl.tty.flags &= ~@as(i32, T.TTY_NOCURSOR);
    }
}

/// Track the latest (most recently active) client per window.
pub fn server_client_update_latest(cl: *T.Client) void {
    const s = cl.session orelse return;
    const wl = s.curw orelse return;
    const w = wl.window;
    if (w.latest == @as(?*anyopaque, @ptrCast(cl))) return;
    w.latest = @ptrCast(cl);

    notify.notify_client("client-active", cl);
    _ = &s; // suppress unused parameter warning
}

/// Set client title from the window title template.
pub fn server_client_set_title(cl: *T.Client) void {
    const s = cl.session orelse return;
    const wl = s.curw orelse return;
    const wp = wl.window.active orelse return;

    const title = if (wp.screen.title) |pane_title| pane_title else wl.window.name;
    if (title.len == 0) return;

    if (cl.title) |old| {
        if (std.mem.eql(u8, old, title)) return;
        xm.allocator.free(old);
    }
    cl.title = xm.xstrdup(title);
    tty_mod.tty_set_title(&cl.tty, title);
}

/// Set client path from the active pane's working directory.
pub fn server_client_set_path(cl: *T.Client) void {
    const s = cl.session orelse return;
    const wl = s.curw orelse return;
    const wp = wl.window.active orelse return;

    const path: []const u8 = if (wp.screen.path) |p| p else "";
    if (cl.path) |old| {
        if (std.mem.eql(u8, old, path)) return;
        xm.allocator.free(old);
    }
    cl.path = if (path.len != 0) xm.xstrdup(path) else null;
}

/// Write raw bytes to client's output peer stream.
pub fn server_client_write(cl: *T.Client, data: []const u8) void {
    if ((cl.flags & T.CLIENT_TERMINAL) != 0) {
        tty_mod.tty_add(&cl.tty, data.ptr, data.len);
        return;
    }

    const peer = cl.peer orelse return;
    if (file_mod.writeStreamData(cl, 1, data)) return;
    _ = file_mod.sendPeerStream(peer, 1, data);
}

/// Write a formatted string to client's output peer stream.
pub fn server_client_write_fmt(cl: *T.Client, comptime fmt: []const u8, args: anytype) void {
    const msg = xm.xasprintf(fmt, args);
    defer xm.allocator.free(msg);
    server_client_write(cl, msg);
}

pub fn server_client_apply_session_size(cl: *T.Client, s: *T.Session) void {
    if (s.curw) |wl| wl.window.latest = @ptrCast(cl);
    resize_mod.recalculate_sizes_now(true);
}

pub fn server_client_set_session(cl: *T.Client, s: *T.Session) void {
    const srv = @import("server.zig");
    const old_session = cl.session;
    const now = std.time.milliTimestamp();

    if (old_session) |current| {
        if (current != s and current.attached > 0)
            current.attached -= 1;
        if (current != s)
            cl.last_session = current;
        if (current.curw) |wl|
            win_mod.window_update_focus(wl.window);
    }

    cl.session = s;
    cl.flags |= T.CLIENT_FOCUSED;
    if (old_session != s)
        s.attached += 1;

    tty_draw.tty_draw_invalidate(&cl.pane_cache);
    if (s.curw) |wl| {
        wl.window.latest = @ptrCast(cl);
        resize_mod.recalculate_sizes();
        win_mod.window_update_focus(wl.window);
        sess.session_update_activity(s, now);
        sess.session_theme_changed(s);
        s.last_attached_time = now;
        wl.flags &= ~@as(u32, T.WINLINK_ALERTFLAGS);
        alerts.alerts_check_session(s);
        tty_mod.tty_update_client_offset(cl);
        status.status_timer_start(cl);
        server_fn.server_redraw_client(cl);
    }
    if (old_session != s)
        notify.notify_client("client-session-changed", cl);
    server_fn.server_check_unattached();
    srv.server_update_socket();
}

pub fn server_client_force_redraw(cl: *T.Client) void {
    tty_mod.tty_invalidate(&cl.tty);
    tty_draw.tty_draw_invalidate(&cl.pane_cache);
    cl.flags |= T.CLIENT_REDRAW;
}

pub fn server_client_attach(cl: *T.Client, s: *T.Session) void {
    server_client_set_session(cl, s);
    server_client_set_key_table(cl, null);
    cl.flags |= T.CLIENT_ATTACHED | T.CLIENT_REDRAW;
    if (cl.peer) |peer| {
        _ = proc_mod.proc_send(peer, .ready, -1, null, 0);
    }
}

fn server_client_process_stdin_pending(cl: *T.Client) void {
    server_client_cancel_escape_timer(cl);

    var consumed: usize = 0;
    while (consumed < cl.stdin_pending.items.len) {
        var event: T.key_event = .{};
        const used = input_keys.input_key_get_client(cl, cl.stdin_pending.items[consumed..], &event) orelse break;
        if (used == 0) break;
        consumed += used;
        if (event.key == T.KEYC_NONE and event.len == 0) continue;
        _ = server_fn.server_client_handle_key(cl, &event);
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

fn server_client_cancel_click_timer(cl: *T.Client) void {
    if (cl.click_timer) |ev| {
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
    _ = server_fn.server_client_handle_key(cl, &event);

    const remaining = cl.stdin_pending.items.len - 1;
    if (remaining != 0) {
        std.mem.copyForwards(u8, cl.stdin_pending.items[0..remaining], cl.stdin_pending.items[1..]);
    }
    cl.stdin_pending.shrinkRetainingCapacity(remaining);
    server_client_process_stdin_pending(cl);
}

pub fn server_client_refresh_click_timer(cl: *T.Client) void {
    if (cl.click_state == .none or T.KEYC_CLICK_TIMEOUT == 0) {
        server_client_cancel_click_timer(cl);
        return;
    }

    if (cl.click_timer == null) {
        const base = proc_mod.libevent orelse return;
        cl.click_timer = c.libevent.event_new(base, -1, @intCast(c.libevent.EV_TIMEOUT), server_client_click_timeout_cb, cl);
    }
    if (cl.click_timer) |ev| {
        var tv = std.posix.timeval{
            .sec = @intCast(@divFloor(T.KEYC_CLICK_TIMEOUT, 1000)),
            .usec = @intCast(@mod(T.KEYC_CLICK_TIMEOUT, 1000) * 1000),
        };
        _ = c.libevent.event_del(ev);
        _ = c.libevent.event_add(ev, @ptrCast(&tv));
    }
}

export fn server_client_click_timeout_cb(_fd: c_int, _events: c_short, arg: ?*anyopaque) void {
    _ = _fd;
    _ = _events;
    const cl: *T.Client = @ptrCast(@alignCast(arg orelse return));
    server_client_cancel_click_timer(cl);

    if (mouse_runtime.click_timeout_event(cl)) |event| {
        var translated = event;
        _ = server_fn.server_client_handle_key(cl, &translated);
    }
}

pub fn server_client_set_key_table(cl: *T.Client, name: ?[]const u8) void {
    if (cl.key_table_name) |old| {
        xm.allocator.free(old);
        cl.key_table_name = null;
    }
    if (name) |new_name| cl.key_table_name = xm.xstrdup(new_name);
    cl.key_table_activity_time = std.time.milliTimestamp();
}

pub fn server_client_get_cwd(cl: ?*T.Client, s: ?*T.Session) []const u8 {
    if (cl) |c_val| {
        if (c_val.session == null) {
            if (c_val.cwd) |cwd| return cwd;
        }
    }
    if (s) |session| {
        if (session.cwd.len != 0) return session.cwd;
    }
    if (cl) |c_val| {
        if (c_val.session) |session| {
            if (session.cwd.len != 0) return session.cwd;
        }
    }
    if (std.posix.getenv("HOME")) |home| return home;
    return "/";
}

fn client_has_nested_marker(cl: *T.Client) bool {
    if (env_mod.environ_find(cl.environ, zmux_mod.compat_env())) |entry| {
        if (entry.value) |value| {
            if (value.len != 0) return true;
        }
    }
    return false;
}

fn pane_tty_name(wp: *T.WindowPane) []const u8 {
    const len = std.mem.indexOfScalar(u8, &wp.tty_name, 0) orelse wp.tty_name.len;
    return wp.tty_name[0..len];
}

pub fn server_client_check_nested(cl: *T.Client) bool {
    if (!client_has_nested_marker(cl)) return false;

    const ttyname = cl.ttyname orelse return false;
    if (ttyname.len == 0) return false;

    var panes = win_mod.all_window_panes.valueIterator();
    while (panes.next()) |entry| {
        const wp = entry.*;
        if (wp.fd == -1) continue;
        if (std.mem.eql(u8, pane_tty_name(wp), ttyname))
            return true;
    }
    return false;
}

pub fn server_client_open(cl: *T.Client, cause: *?[]u8) i32 {
    if (cl.flags & T.CLIENT_CONTROL != 0) return 0;
    if (server_client_uses_server_tty(cl)) {
        cause.* = xm.xasprintf("can't use {s}", .{cl.ttyname orelse "/dev/tty"});
        return -1;
    }
    if (cl.flags & T.CLIENT_TERMINAL == 0) {
        cause.* = xm.xstrdup("not a terminal");
        return -1;
    }
    return tty_mod.tty_open(&cl.tty, cause);
}

const BodyRenderResult = struct {
    payload: []u8 = &.{},
    cursor_visible: bool = false,
    cursor_x: u32 = 0,
    cursor_y: u32 = 0,
};

pub const ClientViewport = struct {
    x: u32 = 0,
    y: u32 = 0,
    sx: u32 = 0,
    sy: u32 = 0,
};

fn visiblePaneCount(w: *T.Window) usize {
    var count: usize = 0;
    for (w.panes.items) |pane| {
        if (win_mod.window_pane_visible(pane)) count += 1;
    }
    return count;
}

fn canUseCachedPaneDraw(w: *T.Window, wp: *T.WindowPane, viewport: ClientViewport) bool {
    if (visiblePaneCount(w) != 1) return false;
    const bounds = win_mod.window_pane_draw_bounds(wp);
    return bounds.xoff == 0 and bounds.yoff == 0 and viewport.x == 0 and viewport.y == 0;
}

fn redraw_needs_body(redraw_flags: u64) bool {
    return (redraw_flags & (T.CLIENT_REDRAWWINDOW |
        T.CLIENT_REDRAWPANES |
        T.CLIENT_REDRAWOVERLAY)) != 0;
}

fn redraw_needs_full_body(redraw_flags: u64) bool {
    return (redraw_flags & (T.CLIENT_REDRAWWINDOW | T.CLIENT_REDRAWOVERLAY)) != 0;
}

fn redraw_needs_dirty_panes(redraw_flags: u64) bool {
    return (redraw_flags & T.CLIENT_REDRAWPANES) != 0 and !redraw_needs_full_body(redraw_flags);
}

fn redraw_needs_borders(redraw_flags: u64, w: *T.Window) bool {
    return (redraw_flags & T.CLIENT_REDRAWBORDERS) != 0 or
        ((redraw_flags & T.CLIENT_REDRAWWINDOW) != 0 and visiblePaneCount(w) > 1);
}

fn redraw_needs_scrollbars(redraw_flags: u64, body_draw: bool) bool {
    if (body_draw) return false;
    return (redraw_flags & T.CLIENT_REDRAWSCROLLBARS) != 0;
}

fn redraw_needs_status(redraw_flags: u64, body_draw: bool, overlay_rows: u32) bool {
    if (overlay_rows == 0) return false;
    if (body_draw) return true;
    return (redraw_flags & (T.CLIENT_REDRAWSTATUS | T.CLIENT_REDRAWSTATUSALWAYS)) != 0;
}

fn clear_rendered_pane_flags(w: *T.Window, dirty_only: bool) void {
    for (w.panes.items) |pane| {
        if (!win_mod.window_pane_visible(pane)) continue;
        if (dirty_only and pane.flags & T.PANE_REDRAW == 0) continue;
        pane.flags &= ~@as(u32, T.PANE_REDRAW);
    }
}

fn current_body_cursor(
    w: *T.Window,
    view_x: u32,
    view_y: u32,
    sx_limit: u32,
    sy_limit: u32,
    row_offset: u32,
) BodyRenderResult {
    var result = BodyRenderResult{};
    const active = w.active orelse return result;
    if (!win_mod.window_pane_visible(active)) return result;

    const screen = screen_mod.screen_current(active);
    if (!screen.cursor_visible or screen.cx >= active.sx or screen.cy >= active.sy) return result;

    const bounds = win_mod.window_pane_draw_bounds(active);
    const scrollbar = win_mod.window_pane_scrollbar_layout(active);
    const cursor_prefix = if (scrollbar != null and scrollbar.?.left)
        @min(bounds.sx, scrollbar.?.width + scrollbar.?.pad)
    else
        0;
    const cursor_x = bounds.xoff + cursor_prefix + screen.cx;
    const cursor_y = bounds.yoff + screen.cy;
    if (cursor_x < view_x or cursor_x >= view_x + sx_limit or
        cursor_y < view_y or cursor_y >= view_y + sy_limit)
        return result;

    result.cursor_visible = true;
    result.cursor_x = cursor_x - view_x;
    result.cursor_y = row_offset + (cursor_y - view_y);
    return result;
}

fn visibleWindowWidth(w: *T.Window) u32 {
    var width = w.sx;
    for (w.panes.items) |pane| {
        if (!win_mod.window_pane_visible(pane)) continue;
        const bounds = win_mod.window_pane_draw_bounds(pane);
        width = @max(width, bounds.xoff + bounds.sx);
    }
    return width;
}

fn visibleWindowHeight(w: *T.Window) u32 {
    var height = w.sy;
    for (w.panes.items) |pane| {
        if (!win_mod.window_pane_visible(pane)) continue;
        const bounds = win_mod.window_pane_draw_bounds(pane);
        height = @max(height, bounds.yoff + bounds.sy);
    }
    return height;
}

pub fn server_client_viewport(cl: *T.Client) ?ClientViewport {
    const s = cl.session orelse return null;
    const wl = s.curw orelse return null;
    const w = wl.window;
    const wp = w.active orelse return null;
    const overlay_rows = status.overlay_rows(cl);
    const tty_sx = if (cl.tty.sx == 0) win_mod.window_pane_total_width(wp) else cl.tty.sx;
    const tty_sy = if (cl.tty.sy == 0) wp.base.grid.sy + overlay_rows else cl.tty.sy;
    const pane_area_sy = if (tty_sy > overlay_rows) tty_sy - overlay_rows else 0;
    const full_sx = visibleWindowWidth(w);
    const full_sy = visibleWindowHeight(w);

    var viewport = ClientViewport{
        .sx = if (tty_sx >= full_sx) full_sx else tty_sx,
        .sy = if (pane_area_sy >= full_sy) full_sy else pane_area_sy,
    };
    if (viewport.sx == 0 or viewport.sy == 0) return viewport;

    if (tty_sx >= full_sx and pane_area_sy >= full_sy) {
        cl.pan_window = null;
        cl.pan_ox = 0;
        cl.pan_oy = 0;
        return viewport;
    }

    if (cl.pan_window == w) {
        if (viewport.sx >= full_sx)
            cl.pan_ox = 0
        else if (cl.pan_ox + viewport.sx > full_sx)
            cl.pan_ox = full_sx - viewport.sx;
        if (viewport.sy >= full_sy)
            cl.pan_oy = 0
        else if (cl.pan_oy + viewport.sy > full_sy)
            cl.pan_oy = full_sy - viewport.sy;
        viewport.x = cl.pan_ox;
        viewport.y = cl.pan_oy;
        return viewport;
    }

    const screen = screen_mod.screen_current(wp);
    if (!screen.cursor_visible) {
        cl.pan_window = null;
        return viewport;
    }

    const bounds = win_mod.window_pane_draw_bounds(wp);
    const scrollbar = win_mod.window_pane_scrollbar_layout(wp);
    const cursor_prefix = if (scrollbar != null and scrollbar.?.left)
        @min(bounds.sx, scrollbar.?.width + scrollbar.?.pad)
    else
        0;
    const cursor_x = bounds.xoff + cursor_prefix + screen.cx;
    const cursor_y = bounds.yoff + screen.cy;

    if (viewport.sx < full_sx) {
        if (cursor_x < viewport.sx)
            viewport.x = 0
        else if (cursor_x > full_sx - viewport.sx)
            viewport.x = full_sx - viewport.sx
        else
            viewport.x = cursor_x - viewport.sx / 2;
    }
    if (viewport.sy < full_sy) {
        if (cursor_y < viewport.sy)
            viewport.y = 0
        else if (cursor_y > full_sy - viewport.sy)
            viewport.y = full_sy - viewport.sy
        else
            viewport.y = cursor_y - viewport.sy / 2;
    }

    cl.pan_window = null;
    return viewport;
}

pub fn build_client_draw_payload(cl: *T.Client, redraw_flags: u64) ?[]u8 {
    const s = cl.session orelse return null;
    const wl = s.curw orelse return null;
    const wp = wl.window.active orelse return null;
    const overlay_rows = status.overlay_rows(cl);
    const pane_row_offset = status.pane_row_offset(cl);
    const tty_sx = if (cl.tty.sx == 0) win_mod.window_pane_total_width(wp) else cl.tty.sx;
    const viewport = server_client_viewport(cl) orelse return null;
    if (tty_sx == 0) return null;

    const body_needs_draw = redraw_needs_body(redraw_flags);
    const full_body_needs_draw = redraw_needs_full_body(redraw_flags);
    const dirty_pane_needs_draw = redraw_needs_dirty_panes(redraw_flags);
    const border_needs_draw = redraw_needs_borders(redraw_flags, wl.window);
    const scrollbar_needs_draw = redraw_needs_scrollbars(redraw_flags, body_needs_draw);
    const status_needs_draw = redraw_needs_status(redraw_flags, body_needs_draw, overlay_rows);
    const overlay_active = cmd_display_panes.overlay_active(cl) or menu.overlay_active(cl) or popup.overlay_active(cl);

    var body = BodyRenderResult{};
    if (full_body_needs_draw and viewport.sy != 0) {
        if (canUseCachedPaneDraw(wl.window, wp, viewport)) {
            win_mod.window_pane_update_scrollbar_geometry(wp);
            const pane_width = win_mod.window_pane_total_width(wp);
            const sx = @min(viewport.sx, pane_width);
            const sy = @min(viewport.sy, wp.base.grid.sy);
            if (sx != 0 and sy != 0) {
                body.payload = tty_draw.tty_draw_pane_offset(&cl.pane_cache, wp, sx, sy, pane_row_offset) catch return null;
                body.cursor_visible = cl.pane_cache.cursor_visible;
                body.cursor_x = cl.pane_cache.cursor_x;
                body.cursor_y = pane_row_offset + cl.pane_cache.cursor_y;
            }
        } else {
            const rendered = tty_draw.tty_draw_render_window_region(
                wl.window,
                viewport.x,
                viewport.y,
                viewport.sx,
                viewport.sy,
                pane_row_offset,
            ) catch return null;
            body = .{
                .payload = rendered.payload,
                .cursor_visible = rendered.cursor_visible,
                .cursor_x = rendered.cursor_x,
                .cursor_y = rendered.cursor_y,
            };
            tty_draw.tty_draw_invalidate(&cl.pane_cache);
        }
    } else if (dirty_pane_needs_draw and viewport.sy != 0) {
        if (canUseCachedPaneDraw(wl.window, wp, viewport) and wp.flags & T.PANE_REDRAW != 0) {
            win_mod.window_pane_update_scrollbar_geometry(wp);
            const pane_width = win_mod.window_pane_total_width(wp);
            const sx = @min(viewport.sx, pane_width);
            const sy = @min(viewport.sy, wp.base.grid.sy);
            if (sx != 0 and sy != 0) {
                body.payload = tty_draw.tty_draw_pane_offset(&cl.pane_cache, wp, sx, sy, pane_row_offset) catch return null;
            }
        } else {
            body.payload = tty_draw.tty_draw_render_dirty_panes_region(
                wl.window,
                viewport.x,
                viewport.y,
                viewport.sx,
                viewport.sy,
                pane_row_offset,
            ) catch return null;
            if (body.payload.len != 0) tty_draw.tty_draw_invalidate(&cl.pane_cache);
        }
        const cursor = current_body_cursor(wl.window, viewport.x, viewport.y, viewport.sx, viewport.sy, pane_row_offset);
        body.cursor_visible = cursor.cursor_visible;
        body.cursor_x = cursor.cursor_x;
        body.cursor_y = cursor.cursor_y;
    } else {
        body = current_body_cursor(wl.window, viewport.x, viewport.y, viewport.sx, viewport.sy, pane_row_offset);
    }
    defer if (body.payload.len != 0) xm.allocator.free(body.payload);

    const border_payload = if (border_needs_draw and viewport.sy != 0)
        tty_draw.tty_draw_render_borders_region(&cl.tty, wl.window, viewport.x, viewport.y, viewport.sx, viewport.sy, pane_row_offset) catch return null
    else
        &[_]u8{};
    defer if (border_payload.len != 0) xm.allocator.free(border_payload);

    const scrollbar_payload = if (scrollbar_needs_draw and viewport.sy != 0)
        tty_draw.tty_draw_render_scrollbars_region(wl.window, viewport.x, viewport.y, viewport.sx, viewport.sy, pane_row_offset) catch return null
    else
        &[_]u8{};
    defer if (scrollbar_payload.len != 0) xm.allocator.free(scrollbar_payload);

    const overlay_payload = if (overlay_active and viewport.sy != 0 and
        (body_needs_draw or border_needs_draw or scrollbar_needs_draw or (redraw_flags & T.CLIENT_REDRAWOVERLAY) != 0))
    blk: {
        if (popup.overlay_active(cl))
            break :blk popup.render_overlay_payload_region(
                cl,
                viewport.x,
                viewport.y,
                tty_sx,
                viewport.sy,
                pane_row_offset,
            ) catch return null;
        if (menu.overlay_active(cl))
            break :blk menu.render_overlay_payload_region(
                cl,
                viewport.x,
                viewport.y,
                tty_sx,
                viewport.sy,
                pane_row_offset,
            ) catch return null;
        break :blk cmd_display_panes.render_overlay_payload_region(
            cl,
            viewport.x,
            viewport.y,
            tty_sx,
            viewport.sy,
            pane_row_offset,
        ) catch return null;
    } else null;
    defer if (overlay_payload) |payload| xm.allocator.free(payload);

    const status_render = if (status_needs_draw) status.render(cl) else status.RenderResult{};
    defer if (status_render.payload.len != 0) xm.allocator.free(status_render.payload);

    var mode_payload: std.ArrayList(u8) = .{};
    defer mode_payload.deinit(xm.allocator);
    tty_mod.tty_append_mode_update(&cl.tty, mouse_runtime.client_outer_tty_mode(cl), &mode_payload) catch return null;

    // Drain DCS passthrough data from all panes in this window.
    var passthrough: std.ArrayList(u8) = .{};
    defer passthrough.deinit(xm.allocator);
    for (wl.window.panes.items) |pane| {
        if (pane.passthrough_pending.items.len != 0) {
            passthrough.appendSlice(xm.allocator, pane.passthrough_pending.items) catch {};
            pane.passthrough_pending.clearRetainingCapacity();
        }
    }

    if (mode_payload.items.len == 0 and body.payload.len == 0 and border_payload.len == 0 and scrollbar_payload.len == 0 and status_render.payload.len == 0 and overlay_payload == null and passthrough.items.len == 0) return null;

    var buf: std.ArrayList(u8) = .{};
    errdefer buf.deinit(xm.allocator);
    buf.appendSlice(xm.allocator, mode_payload.items) catch return null;
    buf.appendSlice(xm.allocator, passthrough.items) catch return null;
    buf.appendSlice(xm.allocator, body.payload) catch return null;
    buf.appendSlice(xm.allocator, scrollbar_payload) catch return null;
    buf.appendSlice(xm.allocator, border_payload) catch return null;
    if (overlay_payload) |payload| buf.appendSlice(xm.allocator, payload) catch return null;
    if (status_render.payload.len != 0) {
        buf.appendSlice(xm.allocator, "\x1b[?25l") catch return null;
        buf.appendSlice(xm.allocator, status_render.payload) catch return null;
    }

    if (overlay_active) {
        if (body.payload.len != 0 or border_payload.len != 0 or scrollbar_payload.len != 0 or status_render.payload.len != 0 or overlay_payload != null)
            buf.appendSlice(xm.allocator, "\x1b[?25l") catch return null;
    } else if (status_render.cursor_visible) {
        if (status_render.cursor_screen) |screen| {
            _ = tty_mod.tty_append_cursor_update(&cl.tty, cl.tty.mode | screen.mode, screen, &buf) catch return null;
        }
        const cursor = std.fmt.allocPrint(
            xm.allocator,
            "\x1b[{d};{d}H\x1b[?25h",
            .{ status_render.cursor_y + 1, status_render.cursor_x + 1 },
        ) catch return null;
        defer xm.allocator.free(cursor);
        buf.appendSlice(xm.allocator, cursor) catch return null;
    } else if (body.cursor_visible) {
        if (cl.status.screen) |screen| {
            _ = tty_mod.tty_append_cursor_update(&cl.tty, cl.tty.mode | T.MODE_CURSOR, screen, &buf) catch return null;
        }
        const cursor = std.fmt.allocPrint(
            xm.allocator,
            "\x1b[{d};{d}H\x1b[?25h",
            .{ body.cursor_y + 1, body.cursor_x + 1 },
        ) catch return null;
        defer xm.allocator.free(cursor);
        buf.appendSlice(xm.allocator, cursor) catch return null;
    } else if (body.payload.len != 0 or border_payload.len != 0 or scrollbar_payload.len != 0 or status_render.payload.len != 0) {
        buf.appendSlice(xm.allocator, "\x1b[?25l") catch return null;
    }

    if (body.payload.len != 0) {
        if (full_body_needs_draw)
            clear_rendered_pane_flags(wl.window, false)
        else if (dirty_pane_needs_draw)
            clear_rendered_pane_flags(wl.window, true);
    }

    return buf.toOwnedSlice(xm.allocator) catch return null;
}

fn server_client_draw(cl: *T.Client, redraw_flags: u64) void {
    const payload = build_client_draw_payload(cl, redraw_flags);
    defer if (payload) |bytes| xm.allocator.free(bytes);

    if (payload) |bytes| server_client_write(cl, bytes);
}

fn wl_name(w: *T.Window) []const u8 {
    return w.name;
}

fn server_client_uses_server_tty(cl: *const T.Client) bool {
    const ttyname = cl.ttyname orelse return false;
    if (std.mem.eql(u8, ttyname, "/dev/tty")) return true;

    for ([_]c_int{ 0, 1, 2 }) |fd| {
        if (c.posix_sys.isatty(fd) == 0) continue;
        const current = c.posix_sys.ttyname(fd) orelse continue;
        if (std.mem.eql(u8, ttyname, std.mem.span(current))) return true;
    }
    return false;
}

pub fn server_client_set_overlay(
    cl: *T.Client,
    delay: u32,
    checkcb: ?T.OverlayCheckCb,
    modecb: ?T.OverlayModeCb,
    drawcb: ?T.OverlayDrawCb,
    keycb: ?T.OverlayKeyCb,
    freecb: ?T.OverlayFreeCb,
    resizecb: ?T.OverlayResizeCb,
    data: ?*anyopaque,
) void {
    if (cl.overlay_draw != null)
        server_client_clear_overlay(cl);

    if (cl.overlay_timer) |ev| {
        _ = c.libevent.event_del(ev);
    } else {
        const base = proc_mod.libevent orelse return;
        cl.overlay_timer = c.libevent.event_new(
            base,
            -1,
            @intCast(c.libevent.EV_TIMEOUT),
            server_client_overlay_timer,
            cl,
        );
    }
    if (delay != 0) {
        if (cl.overlay_timer) |ev| {
            var tv = std.posix.timeval{
                .sec = @intCast(@divFloor(delay, 1000)),
                .usec = @intCast(@mod(delay, 1000) * 1000),
            };
            _ = c.libevent.event_add(ev, @ptrCast(&tv));
        }
    }

    cl.overlay_check = checkcb;
    cl.overlay_mode = modecb;
    cl.overlay_draw = drawcb;
    cl.overlay_key = keycb;
    cl.overlay_free = freecb;
    cl.overlay_resize = resizecb;
    cl.overlay_data = data;

    if (cl.overlay_check == null)
        cl.tty.flags |= T.TTY_FREEZE;
    if (cl.overlay_mode == null)
        cl.tty.flags |= T.TTY_NOCURSOR;

    if (cl.session) |s| if (s.curw) |wl| win_mod.window_update_focus(wl.window);
    server_client_force_redraw(cl);
}

pub fn server_client_clear_overlay(cl: *T.Client) void {
    if (cl.overlay_draw == null) return;

    if (cl.overlay_timer) |ev|
        _ = c.libevent.event_del(ev);

    if (cl.overlay_free) |free_cb|
        free_cb(cl, cl.overlay_data);

    cl.overlay_check = null;
    cl.overlay_mode = null;
    cl.overlay_draw = null;
    cl.overlay_key = null;
    cl.overlay_free = null;
    cl.overlay_resize = null;
    cl.overlay_data = null;

    const mask: i32 = @intCast(@as(u32, T.TTY_FREEZE | T.TTY_NOCURSOR));
    cl.tty.flags &= ~mask;
    if (cl.session) |s| if (s.curw) |wl| win_mod.window_update_focus(wl.window);
    server_client_force_redraw(cl);
}

export fn server_client_overlay_timer(_fd: c_int, _events: c_short, arg: ?*anyopaque) void {
    _ = _fd;
    _ = _events;
    const cl: *T.Client = @ptrCast(@alignCast(arg orelse return));
    log.log_debug("server_client_overlay_timer fired", .{});
    server_client_clear_overlay(cl);
}

pub const VisibleRange = sc_visible.VisibleRange;
pub const VisibleRanges = sc_visible.VisibleRanges;
pub const server_client_overlay_range = sc_visible.server_client_overlay_range;
pub const server_client_ranges_is_empty = sc_visible.server_client_ranges_is_empty;
pub const server_client_ensure_ranges = sc_visible.server_client_ensure_ranges;

const MouseWhere = enum {
    nowhere,
    pane,
    status_area,
    status_left,
    status_right,
    status_default,
    border,
    scrollbar_up,
    scrollbar_slider,
    scrollbar_down,
};

pub fn server_client_check_mouse(cl: *T.Client, event: *T.key_event) T.key_code {
    const s = cl.session orelse return T.KEYC_UNKNOWN;
    const wl = s.curw orelse return T.KEYC_UNKNOWN;
    const w = wl.window;
    const m = &event.m;

    log.log_debug("check_mouse {x:0>2} at {d},{d} (last {d},{d})", .{ m.b, m.x, m.y, m.lx, m.ly });

    const effective = classifyMouseEvent(cl, event) orelse return T.KEYC_UNKNOWN;
    const x = effective.x;
    const y = effective.y;
    const b = effective.buttons;
    var kind = effective.kind;
    var where: MouseWhere = .nowhere;

    m.s = @intCast(s.id);
    m.w = -1;
    m.wp = -1;
    m.ignore = effective.ignore;

    m.statusat = status.status_at_line(cl);
    m.statuslines = resize_mod.status_line_size(cl);
    if (m.statusat != -1 and
        y >= @as(u32, @intCast(m.statusat)) and
        y < @as(u32, @intCast(m.statusat)) + m.statuslines)
    {
        if (status.status_get_range(cl, x, y - @as(u32, @intCast(m.statusat)))) |sr| {
            switch (sr.type) {
                .none => return T.KEYC_UNKNOWN,
                .left => {
                    log.log_debug("mouse range: left", .{});
                    where = .status_left;
                },
                .right => {
                    log.log_debug("mouse range: right", .{});
                    where = .status_right;
                },
                .pane => {
                    _ = win_mod.window_pane_find_by_id(sr.argument) orelse return T.KEYC_UNKNOWN;
                    m.wp = @intCast(sr.argument);
                    log.log_debug("mouse range: pane %%{d}", .{m.wp});
                    where = .status_area;
                },
                .window => {
                    const fwl = sess.winlink_find_by_index(&s.windows, @intCast(sr.argument)) orelse return T.KEYC_UNKNOWN;
                    m.w = @intCast(fwl.window.id);
                    log.log_debug("mouse range: window @{d}", .{m.w});
                    where = .status_area;
                },
                .session => {
                    _ = sess.session_find_by_id(sr.argument) orelse return T.KEYC_UNKNOWN;
                    m.s = @intCast(sr.argument);
                    log.log_debug("mouse range: session ${d}", .{m.s});
                    where = .status_area;
                },
                .user => {
                    where = .status_area;
                },
            }
        } else {
            where = .status_default;
        }
    }

    if (where == .nowhere) {
        if (cl.tty.mouse_scrolling_flag) {
            where = .scrollbar_slider;
        } else {
            var px = x;
            var py: u32 = undefined;
            if (m.statusat == 0 and y >= m.statuslines)
                py = y - m.statuslines
            else if (m.statusat > 0 and y >= @as(u32, @intCast(m.statusat)))
                py = @as(u32, @intCast(m.statusat)) -| 1
            else
                py = y;

            var win_sx: u32 = 0;
            var win_sy: u32 = 0;
            _ = tty_mod.tty_window_offset(&cl.tty, &m.ox, &m.oy, &win_sx, &win_sy);

            px = px + m.ox;
            py = py + m.oy;

            const wp_opt = win_mod.window_get_active_at(w, px, py);
            if (wp_opt == null) return T.KEYC_UNKNOWN;
            const wp = wp_opt.?;
            var sl_mpos: u32 = 0;
            where = server_client_check_mouse_in_pane(wp, px, py, &sl_mpos);

            if (where == .pane)
                log.log_debug("mouse {d},{d} on pane %%{d}", .{ x, y, wp.id })
            else if (where == .border)
                log.log_debug("mouse on pane %%{d} border", .{wp.id})
            else if (where == .scrollbar_up or where == .scrollbar_slider or where == .scrollbar_down)
                log.log_debug("mouse on pane %%{d} scrollbar", .{wp.id});
            m.wp = @intCast(wp.id);
            m.w = @intCast(wp.window.id);
        }
    }

    if (kind == .down or kind == .second or kind == .triple) {
        if (kind != .down and
            (m.b != cl.click_button or
                @intFromEnum(where) != @intFromEnum(mouseWhereToTarget(where) orelse .pane) or
                m.wp != cl.click_wp))
        {
            kind = .down;
            log.log_debug("click sequence reset at {d},{d}", .{ x, y });
        }
    }

    if (kind != .drag and
        kind != .wheel and
        kind != .double and
        kind != .triple and
        cl.tty.mouse_drag_flag != 0)
    {
        if (cl.tty.mouse_drag_release) |release|
            release(cl, m);

        cl.tty.mouse_drag_update = null;
        cl.tty.mouse_drag_release = null;
        cl.tty.mouse_scrolling_flag = false;

        const drag_end_key = mouseKeyForDragEnd(cl.tty.mouse_drag_flag -| 1, where);
        cl.tty.mouse_drag_flag = 0;
        if (drag_end_key != T.KEYC_UNKNOWN) return drag_end_key;
    }

    var key: T.key_code = T.KEYC_UNKNOWN;
    const target = mouseWhereToTarget(where);
    switch (kind) {
        .move => {
            if (target) |t| key = T.keycMouse(T.KEYC_MOUSEMOVE, t);
        },
        .drag => {
            if (cl.tty.mouse_drag_update != null)
                key = T.KEYC_DRAGGING
            else if (target) |t|
                key = mouseKeyForDrag(T.mouseButtons(b), t);
        },
        .wheel => {
            if (target) |t| {
                if (T.mouseButtons(b) == T.MOUSE_WHEEL_UP)
                    key = T.keycMouse(T.KEYC_WHEELUP, t)
                else
                    key = T.keycMouse(T.KEYC_WHEELDOWN, t);
            }
        },
        .up => {
            if (target) |t| key = mouseKeyForUp(T.mouseButtons(b), t);
        },
        .down => {
            if (target) |t| key = mouseKeyForDown(T.mouseButtons(b), t);
        },
        .second => {
            if (target) |t| key = mouseKeyForSecond(T.mouseButtons(b), t);
        },
        .double => {
            if (target) |t| key = mouseKeyForDouble(T.mouseButtons(b), t);
        },
        .triple => {
            if (target) |t| key = mouseKeyForTriple(T.mouseButtons(b), t);
        },
    }
    return key;
}

fn mouseWhereToTarget(where: MouseWhere) ?T.KeyMouseTarget {
    return switch (where) {
        .pane => .pane,
        .status_area => .status,
        .status_left => .status_left,
        .status_right => .status_right,
        .status_default => .status_default,
        .border => .border,
        .scrollbar_up => .scrollbar_up,
        .scrollbar_slider => .scrollbar_slider,
        .scrollbar_down => .scrollbar_down,
        .nowhere => null,
    };
}

fn mouseKeyForDown(buttons: u32, target: T.KeyMouseTarget) T.key_code {
    return switch (buttons) {
        T.MOUSE_BUTTON_1 => T.keycMouse(T.KEYC_MOUSEDOWN1, target),
        T.MOUSE_BUTTON_2 => T.keycMouse(T.KEYC_MOUSEDOWN2, target),
        T.MOUSE_BUTTON_3 => T.keycMouse(T.KEYC_MOUSEDOWN3, target),
        T.MOUSE_BUTTON_6 => T.keycMouse(T.KEYC_MOUSEDOWN6, target),
        T.MOUSE_BUTTON_7 => T.keycMouse(T.KEYC_MOUSEDOWN7, target),
        T.MOUSE_BUTTON_8 => T.keycMouse(T.KEYC_MOUSEDOWN8, target),
        T.MOUSE_BUTTON_9 => T.keycMouse(T.KEYC_MOUSEDOWN9, target),
        T.MOUSE_BUTTON_10 => T.keycMouse(T.KEYC_MOUSEDOWN10, target),
        T.MOUSE_BUTTON_11 => T.keycMouse(T.KEYC_MOUSEDOWN11, target),
        else => T.KEYC_MOUSE,
    };
}

fn mouseKeyForUp(buttons: u32, target: T.KeyMouseTarget) T.key_code {
    return switch (buttons) {
        T.MOUSE_BUTTON_1 => T.keycMouse(T.KEYC_MOUSEUP1, target),
        T.MOUSE_BUTTON_2 => T.keycMouse(T.KEYC_MOUSEUP2, target),
        T.MOUSE_BUTTON_3 => T.keycMouse(T.KEYC_MOUSEUP3, target),
        T.MOUSE_BUTTON_6 => T.keycMouse(T.KEYC_MOUSEUP6, target),
        T.MOUSE_BUTTON_7 => T.keycMouse(T.KEYC_MOUSEUP7, target),
        T.MOUSE_BUTTON_8 => T.keycMouse(T.KEYC_MOUSEUP8, target),
        T.MOUSE_BUTTON_9 => T.keycMouse(T.KEYC_MOUSEUP9, target),
        T.MOUSE_BUTTON_10 => T.keycMouse(T.KEYC_MOUSEUP10, target),
        T.MOUSE_BUTTON_11 => T.keycMouse(T.KEYC_MOUSEUP11, target),
        else => T.KEYC_MOUSE,
    };
}

fn mouseKeyForDrag(buttons: u32, target: T.KeyMouseTarget) T.key_code {
    return switch (buttons) {
        T.MOUSE_BUTTON_1 => T.keycMouse(T.KEYC_MOUSEDRAG1, target),
        T.MOUSE_BUTTON_2 => T.keycMouse(T.KEYC_MOUSEDRAG2, target),
        T.MOUSE_BUTTON_3 => T.keycMouse(T.KEYC_MOUSEDRAG3, target),
        T.MOUSE_BUTTON_6 => T.keycMouse(T.KEYC_MOUSEDRAG6, target),
        T.MOUSE_BUTTON_7 => T.keycMouse(T.KEYC_MOUSEDRAG7, target),
        T.MOUSE_BUTTON_8 => T.keycMouse(T.KEYC_MOUSEDRAG8, target),
        T.MOUSE_BUTTON_9 => T.keycMouse(T.KEYC_MOUSEDRAG9, target),
        T.MOUSE_BUTTON_10 => T.keycMouse(T.KEYC_MOUSEDRAG10, target),
        T.MOUSE_BUTTON_11 => T.keycMouse(T.KEYC_MOUSEDRAG11, target),
        else => T.KEYC_MOUSE,
    };
}

fn mouseKeyForDragEnd(flag: u32, where: MouseWhere) T.key_code {
    const target = mouseWhereToTarget(where) orelse return T.KEYC_MOUSE;
    return switch (flag) {
        T.MOUSE_BUTTON_1 => T.keycMouse(T.KEYC_MOUSEDRAGEND1, target),
        T.MOUSE_BUTTON_2 => T.keycMouse(T.KEYC_MOUSEDRAGEND2, target),
        T.MOUSE_BUTTON_3 => T.keycMouse(T.KEYC_MOUSEDRAGEND3, target),
        T.MOUSE_BUTTON_6 => T.keycMouse(T.KEYC_MOUSEDRAGEND6, target),
        T.MOUSE_BUTTON_7 => T.keycMouse(T.KEYC_MOUSEDRAGEND7, target),
        T.MOUSE_BUTTON_8 => T.keycMouse(T.KEYC_MOUSEDRAGEND8, target),
        T.MOUSE_BUTTON_9 => T.keycMouse(T.KEYC_MOUSEDRAGEND9, target),
        T.MOUSE_BUTTON_10 => T.keycMouse(T.KEYC_MOUSEDRAGEND10, target),
        T.MOUSE_BUTTON_11 => T.keycMouse(T.KEYC_MOUSEDRAGEND11, target),
        else => T.KEYC_MOUSE,
    };
}

fn mouseKeyForSecond(buttons: u32, target: T.KeyMouseTarget) T.key_code {
    return switch (buttons) {
        T.MOUSE_BUTTON_1 => T.keycMouse(T.KEYC_SECONDCLICK1, target),
        T.MOUSE_BUTTON_2 => T.keycMouse(T.KEYC_SECONDCLICK2, target),
        T.MOUSE_BUTTON_3 => T.keycMouse(T.KEYC_SECONDCLICK3, target),
        T.MOUSE_BUTTON_6 => T.keycMouse(T.KEYC_SECONDCLICK6, target),
        T.MOUSE_BUTTON_7 => T.keycMouse(T.KEYC_SECONDCLICK7, target),
        T.MOUSE_BUTTON_8 => T.keycMouse(T.KEYC_SECONDCLICK8, target),
        T.MOUSE_BUTTON_9 => T.keycMouse(T.KEYC_SECONDCLICK9, target),
        T.MOUSE_BUTTON_10 => T.keycMouse(T.KEYC_SECONDCLICK10, target),
        T.MOUSE_BUTTON_11 => T.keycMouse(T.KEYC_SECONDCLICK11, target),
        else => T.KEYC_MOUSE,
    };
}

fn mouseKeyForDouble(buttons: u32, target: T.KeyMouseTarget) T.key_code {
    return switch (buttons) {
        T.MOUSE_BUTTON_1 => T.keycMouse(T.KEYC_DOUBLECLICK1, target),
        T.MOUSE_BUTTON_2 => T.keycMouse(T.KEYC_DOUBLECLICK2, target),
        T.MOUSE_BUTTON_3 => T.keycMouse(T.KEYC_DOUBLECLICK3, target),
        T.MOUSE_BUTTON_6 => T.keycMouse(T.KEYC_DOUBLECLICK6, target),
        T.MOUSE_BUTTON_7 => T.keycMouse(T.KEYC_DOUBLECLICK7, target),
        T.MOUSE_BUTTON_8 => T.keycMouse(T.KEYC_DOUBLECLICK8, target),
        T.MOUSE_BUTTON_9 => T.keycMouse(T.KEYC_DOUBLECLICK9, target),
        T.MOUSE_BUTTON_10 => T.keycMouse(T.KEYC_DOUBLECLICK10, target),
        T.MOUSE_BUTTON_11 => T.keycMouse(T.KEYC_DOUBLECLICK11, target),
        else => T.KEYC_MOUSE,
    };
}

fn mouseKeyForTriple(buttons: u32, target: T.KeyMouseTarget) T.key_code {
    return switch (buttons) {
        T.MOUSE_BUTTON_1 => T.keycMouse(T.KEYC_TRIPLECLICK1, target),
        T.MOUSE_BUTTON_2 => T.keycMouse(T.KEYC_TRIPLECLICK2, target),
        T.MOUSE_BUTTON_3 => T.keycMouse(T.KEYC_TRIPLECLICK3, target),
        T.MOUSE_BUTTON_6 => T.keycMouse(T.KEYC_TRIPLECLICK6, target),
        T.MOUSE_BUTTON_7 => T.keycMouse(T.KEYC_TRIPLECLICK7, target),
        T.MOUSE_BUTTON_8 => T.keycMouse(T.KEYC_TRIPLECLICK8, target),
        T.MOUSE_BUTTON_9 => T.keycMouse(T.KEYC_TRIPLECLICK9, target),
        T.MOUSE_BUTTON_10 => T.keycMouse(T.KEYC_TRIPLECLICK10, target),
        T.MOUSE_BUTTON_11 => T.keycMouse(T.KEYC_TRIPLECLICK11, target),
        else => T.KEYC_MOUSE,
    };
}

const ClassifiedEvent = struct {
    kind: MouseEventKind,
    x: u32,
    y: u32,
    buttons: u32,
    ignore: bool = false,
};

const MouseEventKind = enum { move, down, up, drag, wheel, second, double, triple };

fn classifyMouseEvent(cl: *T.Client, event: *T.key_event) ?ClassifiedEvent {
    const m = &event.m;

    if (event.key == T.KEYC_DOUBLECLICK) {
        return ClassifiedEvent{ .kind = .double, .x = m.x, .y = m.y, .buttons = m.b, .ignore = true };
    }

    if ((m.sgr_type != ' ' and T.mouseDrag(m.sgr_b) and T.mouseRelease(m.sgr_b)) or
        (m.sgr_type == ' ' and T.mouseDrag(m.b) and T.mouseRelease(m.b) and T.mouseRelease(m.lb)))
    {
        return ClassifiedEvent{ .kind = .move, .x = m.x, .y = m.y, .buttons = 0 };
    }

    if (T.mouseDrag(m.b)) {
        if (cl.tty.mouse_drag_flag != 0) {
            if (m.x == m.lx and m.y == m.ly) return null;
            return ClassifiedEvent{ .kind = .drag, .x = m.x, .y = m.y, .buttons = m.b };
        }
        return ClassifiedEvent{ .kind = .drag, .x = m.lx, .y = m.ly, .buttons = m.lb };
    }

    if (T.mouseWheel(m.b))
        return ClassifiedEvent{ .kind = .wheel, .x = m.x, .y = m.y, .buttons = m.b };

    if (T.mouseRelease(m.b)) {
        var up_b = m.lb;
        if (m.sgr_type == 'm') up_b = m.sgr_b;
        return ClassifiedEvent{ .kind = .up, .x = m.x, .y = m.y, .buttons = up_b };
    }

    if (cl.click_state == .double_pending) {
        server_client_cancel_click_timer(cl);
        cl.click_state = .triple_pending;
        return ClassifiedEvent{ .kind = .second, .x = m.x, .y = m.y, .buttons = m.b };
    }
    if (cl.click_state == .triple_pending) {
        server_client_cancel_click_timer(cl);
        cl.click_state = .none;
        return ClassifiedEvent{ .kind = .triple, .x = m.x, .y = m.y, .buttons = m.b };
    }

    cl.click_state = .double_pending;
    return ClassifiedEvent{ .kind = .down, .x = m.x, .y = m.y, .buttons = m.b };
}

pub fn server_client_check_mouse_in_pane(
    wp: *T.WindowPane,
    px: u32,
    py: u32,
    sl_mpos: *u32,
) MouseWhere {
    sl_mpos.* = 0;
    const bounds = win_mod.window_pane_draw_bounds(wp);
    const scrollbar = win_mod.window_pane_scrollbar_layout(wp);

    if (scrollbar) |sb| {
        const sb_x: u32 = if (sb.left) bounds.xoff else bounds.xoff + bounds.sx + sb.pad;
        if (px >= sb_x and px < sb_x + sb.width and
            py >= bounds.yoff and py < bounds.yoff + bounds.sy)
        {
            const rel_y = py - bounds.yoff;
            if (rel_y < wp.sb_slider_y)
                return .scrollbar_up;
            if (rel_y < wp.sb_slider_y + wp.sb_slider_h) {
                sl_mpos.* = rel_y - wp.sb_slider_y;
                return .scrollbar_slider;
            }
            return .scrollbar_down;
        }
    }

    const content_xoff = if (scrollbar != null and scrollbar.?.left)
        bounds.xoff + scrollbar.?.width + scrollbar.?.pad
    else
        bounds.xoff;
    const content_sx = bounds.sx;

    if (px >= content_xoff and px < content_xoff + content_sx and
        py >= bounds.yoff and py < bounds.yoff + bounds.sy)
    {
        return .pane;
    }

    if ((px == content_xoff +| content_sx or (content_xoff > 0 and px == content_xoff - 1)) and
        py >= bounds.yoff and py < bounds.yoff + bounds.sy)
    {
        return .border;
    }
    if (px >= content_xoff and px < content_xoff + content_sx and
        (py == bounds.yoff +| bounds.sy or (bounds.yoff > 0 and py == bounds.yoff - 1)))
    {
        return .border;
    }

    return .nowhere;
}

pub fn server_client_key_callback(item: *cmdq_mod.CmdqItem, data: ?*anyopaque) T.CmdRetval {
    const cl = cmdq_mod.cmdq_get_client(item) orelse return .normal;
    const s = cl.session orelse {
        freeKeyEventData(data);
        return .normal;
    };

    if (cl.flags & T.CLIENT_UNATTACHEDFLAGS != 0) {
        freeKeyEventData(data);
        return .normal;
    }

    const wl = s.curw orelse {
        freeKeyEventData(data);
        return .normal;
    };

    const now = std.time.milliTimestamp();
    cl.last_activity_time = cl.activity_time;
    cl.activity_time = now;
    sess.session_update_activity(s, now);

    const event_ptr = if (data) |d| @as(*T.key_event, @ptrCast(@alignCast(d))) else null;
    var key: T.key_code = if (event_ptr) |e| e.key else T.KEYC_NONE;

    if (key == T.KEYC_MOUSE or key == T.KEYC_DOUBLECLICK) {
        if (cl.flags & T.CLIENT_READONLY != 0) {
            freeKeyEventData(data);
            return .normal;
        }
        if (event_ptr) |e| {
            key = server_client_check_mouse(cl, e);
            if (key == T.KEYC_UNKNOWN) {
                freeKeyEventData(data);
                return .normal;
            }
            e.m.valid = true;
            e.m.key = key;
            if ((key & T.KEYC_MASK_KEY) == T.KEYC_DRAGGING) {
                if (cl.tty.mouse_drag_update) |update|
                    update(cl, &e.m);
                freeKeyEventData(data);
                return .normal;
            }
            e.key = key;
        }
    }

    const wp = wl.window.active;

    if (T.keycIsMouse(key) and opts.options_get_number(s.options, "mouse") == 0) {
        if (cl.flags & T.CLIENT_READONLY == 0 and wp != null) {
            if (event_ptr) |e| {
                _ = win_mod.window_pane_key(wp.?, key, &e.m);
            }
        }
        freeKeyEventData(data);
        return .normal;
    }

    if (server_client_is_bracket_paste(cl, key)) {
        if (cl.flags & T.CLIENT_READONLY == 0 and wp != null) {
            if (event_ptr) |e| {
                win_mod.window_pane_paste(wp.?, key, e.data[0..e.len]);
            }
        }
        freeKeyEventData(data);
        return .normal;
    }

    if (!T.keycIsMouse(key) and
        key != T.KEYC_FOCUS_IN and
        key != T.KEYC_FOCUS_OUT and
        (key & T.KEYC_SENT == 0) and
        server_client_is_assume_paste(cl))
    {
        if (cl.flags & T.CLIENT_READONLY == 0 and wp != null) {
            if (event_ptr) |e| {
                win_mod.window_pane_paste(wp.?, key, e.data[0..e.len]);
            }
        }
        freeKeyEventData(data);
        return .normal;
    }

    // Check for focus events.
    if (key == T.KEYC_FOCUS_OUT) {
        cl.flags &= ~@as(u64, T.CLIENT_FOCUSED);
        win_mod.window_update_focus(wl.window);
        notify.notify_client("client-focus-out", cl);
    } else if (key == T.KEYC_FOCUS_IN) {
        cl.flags |= T.CLIENT_FOCUSED;
        notify.notify_client("client-focus-in", cl);
        win_mod.window_update_focus(wl.window);
    }

    const client_table_name = if (cl.key_table_name) |name| name else blk: {
        const configured = opts.options_get_string(s.options, "key-table");
        break :blk if (configured.len != 0) configured else "root";
    };

    const key0 = key & (T.KEYC_MASK_KEY | T.KEYC_MASK_MODIFIERS);
    const prefix: T.key_code = @intCast(@as(u64, @bitCast(opts.options_get_number(s.options, "prefix"))));
    const prefix2: T.key_code = @intCast(@as(u64, @bitCast(opts.options_get_number(s.options, "prefix2"))));
    if ((prefix != T.KEYC_NONE and key0 == (prefix & (T.KEYC_MASK_KEY | T.KEYC_MASK_MODIFIERS))) or
        (prefix2 != T.KEYC_NONE and key0 == (prefix2 & (T.KEYC_MASK_KEY | T.KEYC_MASK_MODIFIERS))))
    {
        if (!std.mem.eql(u8, client_table_name, "prefix")) {
            server_client_set_key_table(cl, "prefix");
            cl.flags |= T.CLIENT_REDRAWSTATUS;
            freeKeyEventData(data);
            return .normal;
        }
    }

    if (key_bindings.key_bindings_get_table(client_table_name, false)) |table| {
        if (key_bindings.key_bindings_get(table, key0)) |bd| {
            if (cl.flags & T.CLIENT_REPEAT != 0 and bd.flags & T.KEY_BINDING_REPEAT == 0) {
                server_client_set_key_table(cl, null);
                cl.flags &= ~@as(u64, T.CLIENT_REPEAT);
                cl.flags |= T.CLIENT_REDRAWSTATUS;
            } else {
                table.references += 1;
                const repeat = server_client_repeat_time(cl, bd);
                if (repeat != 0) {
                    cl.flags |= T.CLIENT_REPEAT;
                    cl.last_key = bd.key;
                    server_client_arm_repeat_timer(cl, repeat);
                } else {
                    cl.flags &= ~@as(u64, T.CLIENT_REPEAT);
                    server_client_set_key_table(cl, null);
                }
                cl.flags |= T.CLIENT_REDRAWSTATUS;
                _ = key_bindings.key_bindings_dispatch(bd, item, cl, event_ptr orelse &T.key_event{}, null);
                key_bindings.key_bindings_unref_table(table);
                if (s != cl.session orelse s) {
                    freeKeyEventData(data);
                    return .normal;
                }
                server_client_update_latest(cl);
                freeKeyEventData(data);
                return .normal;
            }
        }
    }

    if (!std.mem.eql(u8, client_table_name, server_client_get_key_table(cl)) or
        (cl.flags & T.CLIENT_REPEAT != 0))
    {
        server_client_set_key_table(cl, null);
        cl.flags &= ~@as(u64, T.CLIENT_REPEAT);
        cl.flags |= T.CLIENT_REDRAWSTATUS;
    }

    if (cl.flags & T.CLIENT_READONLY == 0 and wp != null) {
        if (event_ptr) |e|
            _ = win_mod.window_pane_key(wp.?, key, &e.m)
        else
            _ = win_mod.window_pane_key(wp.?, key, null);
    }

    if (key != T.KEYC_FOCUS_OUT)
        server_client_update_latest(cl);
    freeKeyEventData(data);
    return .normal;
}

fn freeKeyEventData(data: ?*anyopaque) void {
    if (data) |d| {
        const event: *T.key_event = @ptrCast(@alignCast(d));
        xm.allocator.destroy(event);
    }
}

fn server_client_arm_repeat_timer(cl: *T.Client, repeat_ms: u32) void {
    if (cl.repeat_timer == null) {
        const base = proc_mod.libevent orelse return;
        cl.repeat_timer = c.libevent.event_new(
            base,
            -1,
            @intCast(c.libevent.EV_TIMEOUT),
            server_client_repeat_timer,
            cl,
        );
    }
    if (cl.repeat_timer) |ev| {
        var tv = std.posix.timeval{
            .sec = @intCast(@divFloor(repeat_ms, 1000)),
            .usec = @intCast(@mod(repeat_ms, 1000) * 1000),
        };
        _ = c.libevent.event_del(ev);
        _ = c.libevent.event_add(ev, @ptrCast(&tv));
    }
}

pub fn server_client_is_bracket_paste(cl: *T.Client, key: T.key_code) bool {
    if ((key & T.KEYC_MASK_KEY) == T.KEYC_PASTE_START) {
        cl.flags |= T.CLIENT_FOCUSED;
        log.log_debug("bracket paste on", .{});
        return false;
    }
    if ((key & T.KEYC_MASK_KEY) == T.KEYC_PASTE_END) {
        cl.flags &= ~@as(u64, T.CLIENT_FOCUSED);
        log.log_debug("bracket paste off", .{});
        return false;
    }
    return (cl.flags & T.CLIENT_FOCUSED) != 0;
}

pub fn server_client_is_assume_paste(cl: *T.Client) bool {
    _ = cl.session orelse return false;
    const diff_ms = cl.activity_time - cl.last_activity_time;
    if (diff_ms >= 0 and diff_ms < 1) {
        log.log_debug("assume paste detected", .{});
        return true;
    }
    return false;
}

pub fn server_client_key_table_activity_diff(cl: *T.Client) u64 {
    // Milliseconds between client activity and key table activity.
    // Mirrors tmux: timersub(&c->activity_time, &c->keytable->activity_time, &diff)
    const c_ms: u64 = @intCast(@max(cl.activity_time, 0));
    const kt_ms: u64 = @intCast(@max(cl.key_table_activity_time, 0));
    return if (c_ms >= kt_ms) c_ms - kt_ms else 0;
}

pub fn server_client_get_key_table(cl: *T.Client) []const u8 {
    const s = cl.session orelse return "root";
    const name = opts.options_get_string(s.options, "key-table");
    if (name.len == 0) return "root";
    return name;
}

pub fn server_client_is_default_key_table(cl: *T.Client, table: *T.KeyTable) bool {
    return std.mem.eql(u8, table.name, server_client_get_key_table(cl));
}

pub fn server_client_repeat_time(cl: *T.Client, bd: *T.KeyBinding) u32 {
    const s = cl.session orelse return 0;
    if (bd.flags & T.KEY_BINDING_REPEAT == 0) return 0;
    const repeat = opts.options_get_number(s.options, "repeat-time");
    if (repeat <= 0) return 0;
    return @intCast(repeat);
}

pub fn server_client_check_window_resize(w: *T.Window) void {
    if (w.flags & T.WINDOW_RESIZE == 0) return;
    log.log_debug("server_client_check_window_resize: @{d}", .{w.id});
    w.flags &= ~@as(u32, T.WINDOW_RESIZE);
    resize_mod.resize_window(w, w.new_sx, w.new_sy, 0, 0);
}

pub fn server_client_check_pane_resize(wp: *T.WindowPane) void {
    if (wp.resize_queue.items.len == 0) return;

    if (wp.resize_timer != null) {
        if (c.libevent.event_pending(wp.resize_timer.?, @as(c_short, @intCast(c.libevent.EV_TIMEOUT)), null) != 0) return;
    } else {
        const base = proc_mod.libevent orelse return;
        wp.resize_timer = c.libevent.event_new(
            base,
            -1,
            @intCast(c.libevent.EV_TIMEOUT),
            server_client_resize_timer,
            wp,
        );
    }

    log.log_debug("check_pane_resize: %%{d} needs to be resized", .{wp.id});

    const queue = wp.resize_queue.items;
    const first = queue[0];
    const last = queue[queue.len - 1];
    var timer_usec: i64 = 250000;

    if (queue.len == 1) {
        win_mod.window_pane_send_resize(wp, first.sx, first.sy);
        _ = wp.resize_queue.orderedRemove(0);
    } else if (last.sx != first.osx or last.sy != first.osy) {
        win_mod.window_pane_send_resize(wp, last.sx, last.sy);
        wp.resize_queue.clearRetainingCapacity();
    } else {
        const penultimate = queue[queue.len - 2];
        win_mod.window_pane_send_resize(wp, penultimate.sx, penultimate.sy);
        const keep = wp.resize_queue.items[queue.len - 1];
        wp.resize_queue.clearRetainingCapacity();
        wp.resize_queue.append(xm.allocator, keep) catch unreachable;
        timer_usec = 10000;
    }

    if (wp.resize_timer) |ev| {
        var tv = std.posix.timeval{
            .sec = 0,
            .usec = @intCast(timer_usec),
        };
        _ = c.libevent.event_add(ev, @ptrCast(&tv));
    }
}

pub fn server_client_check_pane_buffer(wp: *T.WindowPane) void {
    if (wp.fd < 0) return;

    var minimum: usize = wp.offset.used;
    if (wp.pipe_fd != -1 and wp.pipe_offset.used < minimum)
        minimum = wp.pipe_offset.used;

    var off: bool = true;
    var attached_clients: u32 = 0;
    for (client_registry.clients.items) |cl| {
        if (cl.session == null) continue;
        attached_clients += 1;

        if (cl.flags & T.CLIENT_CONTROL == 0) {
            off = false;
            continue;
        }

        var flag: bool = false;
        const wpo = control.control_pane_offset(cl, wp, &flag);
        if (wpo == null) {
            if (!flag) off = false;
            continue;
        }
        if (!flag) off = false;

        var new_size: usize = 0;
        _ = win_mod.window_pane_get_new_data(wp, wpo.?, &new_size);
        log.log_debug("check_pane_buffer: {s} has {d} bytes used and {d} left for %%{d}", .{
            cl.name orelse "?",
            wpo.?.used -| wp.base_offset,
            new_size,
            wp.id,
        });
        if (wpo.?.used < minimum)
            minimum = wpo.?.used;
    }
    if (attached_clients == 0)
        off = false;

    minimum -|= wp.base_offset;
    if (minimum == 0) {
        if (off) {
            log.log_debug("check_pane_buffer: pane %%{d} is off", .{wp.id});
        }
        return;
    }

    log.log_debug("check_pane_buffer: %%{d} has {d} minimum bytes used", .{ wp.id, minimum });

    if (wp.input_pending.items.len >= minimum) {
        const remaining = wp.input_pending.items.len - minimum;
        if (remaining != 0) {
            std.mem.copyForwards(
                u8,
                wp.input_pending.items[0..remaining],
                wp.input_pending.items[minimum..],
            );
        }
        wp.input_pending.shrinkRetainingCapacity(remaining);
    }

    if (wp.base_offset > std.math.maxInt(usize) - minimum) {
        log.log_debug("check_pane_buffer: %%{d} base offset has wrapped", .{wp.id});
        wp.offset.used -|= wp.base_offset;
        if (wp.pipe_fd != -1)
            wp.pipe_offset.used -|= wp.base_offset;
        for (client_registry.clients.items) |cl| {
            if (cl.session == null or (cl.flags & T.CLIENT_CONTROL == 0)) continue;
            var flag: bool = false;
            const wpo = control.control_pane_offset(cl, wp, &flag);
            if (wpo != null and !flag)
                wpo.?.used -|= wp.base_offset;
        }
        wp.base_offset = minimum;
    } else {
        wp.base_offset += minimum;
    }

    log.log_debug("check_pane_buffer: pane %%{d} is {s}", .{ wp.id, if (off) "off" else "on" });

    // Backpressure: stop reading from the pane fd when all attached clients
    // are blocked (off), resume when at least one can consume data (on).
    // In C this is bufferevent_disable/enable(wp->event, EV_READ); here we
    // use plain event_del/event_add since zmux uses non-buffered events.
    //
    // Do not re-arm events during server shutdown: EVLOOP_ONCE would block
    // indefinitely waiting for data from a shell that nobody is killing yet.
    const srv = @import("server.zig");
    if (wp.event) |ev| {
        if (off or srv.server_exit)
            _ = c.libevent.event_del(ev)
        else
            _ = c.libevent.event_add(ev, null);
    }
}

export fn server_client_repeat_timer(_fd: c_int, _events: c_short, arg: ?*anyopaque) void {
    _ = _fd;
    _ = _events;
    const cl: *T.Client = @ptrCast(@alignCast(arg orelse return));
    log.log_debug("server_client_repeat_timer fired", .{});

    if (cl.flags & T.CLIENT_REPEAT != 0) {
        server_client_set_key_table(cl, null);
        cl.flags &= ~@as(u64, T.CLIENT_REPEAT);
        cl.flags |= T.CLIENT_REDRAWSTATUS;
    }
}

export fn server_client_resize_timer(_fd: c_int, _events: c_short, arg: ?*anyopaque) void {
    _ = _fd;
    _ = _events;
    const wp: *T.WindowPane = @ptrCast(@alignCast(arg orelse return));
    log.log_debug("server_client_resize_timer: %%{d} timer expired", .{wp.id});
    if (wp.resize_timer) |ev|
        _ = c.libevent.event_del(ev);
    server_client_check_pane_resize(wp);
}

export fn server_client_redraw_timer(_fd: c_int, _events: c_short, arg: ?*anyopaque) void {
    _ = _fd;
    _ = _events;
    _ = arg;
    log.log_debug("server_client_redraw_timer fired", .{});
}

export fn server_client_click_timer(_fd: c_int, _events: c_short, arg: ?*anyopaque) void {
    _ = _fd;
    _ = _events;
    const cl: *T.Client = @ptrCast(@alignCast(arg orelse return));
    server_client_cancel_click_timer(cl);
    log.log_debug("server_client_click_timer fired", .{});

    // If we were waiting for a third click that never came, emit KEYC_DOUBLECLICK.
    if (mouse_runtime.click_timeout_event(cl)) |event| {
        var translated = event;
        _ = server_fn.server_client_handle_key(cl, &translated);
    }
}

/// Decrement the client reference count and free when it reaches zero.
/// The final free is synchronous (zmux has no event_once).
pub fn server_client_unref(cl: *T.Client) void {
    log.log_debug("server_client_unref: {*} ({d} references)", .{ cl, cl.references });
    if (cl.references == 0) return;
    cl.references -= 1;
    if (cl.references == 0)
        server_client_free(-1, 0, @ptrCast(cl));
}

export fn server_client_free(_fd: c_int, _events: c_short, arg: ?*anyopaque) void {
    _ = _fd;
    _ = _events;
    const cl: *T.Client = @ptrCast(@alignCast(arg orelse return));
    log.log_debug("server_client_free: freeing client {*}", .{cl});
    if (cl.name) |name| xm.allocator.free(@constCast(name));
    xm.allocator.destroy(cl);
}

pub fn server_client_attached_lost(cl: *T.Client) void {
    log.log_debug("lost attached client {*}", .{cl});

    var wit = win_mod.windows.valueIterator();
    while (wit.next()) |w_ptr| {
        const w = w_ptr.*;
        if (w.latest != @as(?*anyopaque, @ptrCast(cl))) continue;

        var found: ?*T.Client = null;
        for (client_registry.clients.items) |loop| {
            if (loop == cl) continue;
            const s = loop.session orelse continue;
            const wl = s.curw orelse continue;
            if (wl.window != w) continue;
            if (found == null or loop.activity_time > found.?.activity_time)
                found = loop;
        }
        if (found) |best|
            server_client_update_latest(best);
    }
}

pub fn server_client_remove_pane(wp: *T.WindowPane) void {
    const w_id = wp.window.id;
    for (client_registry.clients.items) |cl| {
        var i: usize = 0;
        while (i < cl.client_windows.items.len) {
            const cw = &cl.client_windows.items[i];
            if (cw.window == w_id and cw.pane != null and cw.pane.? == wp) {
                _ = cl.client_windows.orderedRemove(i);
            } else {
                i += 1;
            }
        }
    }
}

pub fn server_client_how_many() u32 {
    var n: u32 = 0;
    for (client_registry.clients.items) |cl| {
        if (cl.session != null and (cl.flags & T.CLIENT_ATTACHED != 0))
            n += 1;
    }
    return n;
}

pub fn server_client_get_flags(cl: *T.Client) []const u8 {
    var buf: std.ArrayList(u8) = .{};
    if (cl.flags & T.CLIENT_ATTACHED != 0)
        buf.appendSlice(xm.allocator, "attached,") catch {};
    if (cl.flags & T.CLIENT_FOCUSED != 0)
        buf.appendSlice(xm.allocator, "focused,") catch {};
    if (cl.flags & T.CLIENT_CONTROL != 0)
        buf.appendSlice(xm.allocator, "control-mode,") catch {};
    if (cl.flags & T.CLIENT_IGNORESIZE != 0)
        buf.appendSlice(xm.allocator, "ignore-size,") catch {};
    if (cl.flags & T.CLIENT_NO_DETACH_ON_DESTROY != 0)
        buf.appendSlice(xm.allocator, "no-detach-on-destroy,") catch {};
    if (cl.flags & T.CLIENT_CONTROL_NOOUTPUT != 0)
        buf.appendSlice(xm.allocator, "no-output,") catch {};
    if (cl.flags & T.CLIENT_CONTROL_WAITEXIT != 0)
        buf.appendSlice(xm.allocator, "wait-exit,") catch {};
    if (cl.flags & T.CLIENT_CONTROL_PAUSEAFTER != 0) {
        const s = xm.xasprintf("pause-after={d},", .{cl.pause_age / 1000});
        defer xm.allocator.free(s);
        buf.appendSlice(xm.allocator, s) catch {};
    }
    if (cl.flags & T.CLIENT_READONLY != 0)
        buf.appendSlice(xm.allocator, "read-only,") catch {};
    if (cl.flags & T.CLIENT_ACTIVEPANE != 0)
        buf.appendSlice(xm.allocator, "active-pane,") catch {};
    if (cl.flags & T.CLIENT_SUSPENDED != 0)
        buf.appendSlice(xm.allocator, "suspended,") catch {};
    if (cl.flags & T.CLIENT_UTF8 != 0)
        buf.appendSlice(xm.allocator, "UTF-8,") catch {};

    if (buf.items.len > 0) {
        const result = xm.xstrdup(buf.items[0 .. buf.items.len - 1]);
        buf.deinit(xm.allocator);
        return result;
    }
    buf.deinit(xm.allocator);
    return xm.xstrdup("");
}

pub fn server_client_report_theme(cl: *T.Client, theme: T.ClientTheme) void {
    if (theme == .light) {
        cl.theme = .light;
        notify.notify_client("client-light-theme", cl);
    } else {
        cl.theme = .dark;
        notify.notify_client("client-dark-theme", cl);
    }
    log.log_debug("server_client_report_theme: {s}", .{if (theme == .light) "light" else "dark"});

    // Re-request foreground and background colour after theme change.
    tty_mod.tty_repeat_requests(&cl.tty, 1);
}

pub fn server_client_window_cmp(cw1: *const T.ClientWindow, cw2: *const T.ClientWindow) i32 {
    if (cw1.window < cw2.window) return -1;
    if (cw1.window > cw2.window) return 1;
    return 0;
}

pub fn server_client_read_only(item: *cmdq_mod.CmdqItem, _data: ?*anyopaque) T.CmdRetval {
    _ = _data;
    _ = item;
    log.log_debug("server_client_read_only: client is read-only", .{});
    return .@"error";
}

pub fn server_client_default_command(item: *cmdq_mod.CmdqItem, _data: ?*anyopaque) T.CmdRetval {
    _ = _data;
    const cl = cmdq_mod.cmdq_get_client(item) orelse return .normal;
    log.log_debug("server_client_default_command: client {*}", .{cl});
    server_client_dispatch_default_command(cl);
    return .normal;
}
