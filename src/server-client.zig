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
const file_mod = @import("file.zig");
const opts = @import("options.zig");
const sess = @import("session.zig");
const env_mod = @import("environ.zig");
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
const control = @import("control.zig");
const control_subscriptions = @import("control-subscriptions.zig");
const popup = @import("popup.zig");

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
        .fd = fd,
        .environ = env,
        .tty = .{ .client = cl },
        .status = .{ .screen = undefined },
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
    const was_attached = (cl.flags & T.CLIENT_ATTACHED) != 0;
    file_mod.failPendingReadsForClient(cl);
    file_mod.failPendingWritesForClient(cl);
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
    if (cl.name) |name| xm.allocator.free(@constCast(name));
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
    cl.stdin_pending.deinit(xm.allocator);
    tty_mod.tty_close(&cl.tty);
    tty_draw.tty_draw_free(&cl.pane_cache);
    resize_mod.recalculate_sizes();
    srv.server_update_socket();
    env_mod.environ_free(cl.environ);
    xm.allocator.destroy(cl);
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
        .stdin_data => server_client_dispatch_stdin(cl, imsg_msg),
        .unlock, .wakeup => server_client_unlock(cl),
        .read => file_mod.handleReadData(imsg_msg),
        .read_done => file_mod.handleReadDone(imsg_msg),
        .write_ready => file_mod.handleWriteReady(imsg_msg),
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

    tty_mod.tty_resize(&cl.tty, msg.sx, msg.sy, msg.xpixel, msg.ypixel);
    cl.flags |= T.CLIENT_SIZECHANGED;

    if (cl.session) |s| {
        server_client_apply_session_size(cl, s);
        server_client_force_redraw(cl);
    }
}

fn server_client_dispatch_stdin(cl: *T.Client, imsg_msg: *c.imsg.imsg) void {
    if (cl.flags & T.CLIENT_SUSPENDED != 0) return;
    const data_len = imsg_msg.hdr.len -% @sizeOf(c.imsg.imsg_hdr);
    if (data_len == 0) return;
    const bytes: [*]const u8 = @ptrCast(imsg_msg.data.?);
    cl.stdin_pending.appendSlice(xm.allocator, bytes[0..data_len]) catch unreachable;
    server_client_process_stdin_pending(cl);
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
    const srv = @import("server.zig");

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
    srv.server_update_socket();
    if (cl.peer) |peer| {
        _ = proc_mod.proc_send(peer, msg_type, -1, cl.exit_session.?.ptr, cl.exit_session.?.len + 1);
    } else {
        cl.flags |= T.CLIENT_EXIT;
    }
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

fn server_client_send_shell(cl: *T.Client) void {
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
        .identify_features => {
            if (data_len >= @sizeOf(i32)) {
                var features: i32 = 0;
                @memcpy(std.mem.asBytes(&features), data[0..@sizeOf(i32)]);
                cl.term_features |= features;
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

fn server_client_finalize_identify(cl: *T.Client) void {
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

fn server_client_resolve_cwd(candidate: []const u8) []const u8 {
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

fn server_client_enqueue_command_list(cl: *T.Client, cmd_list: *cmd_mod.CmdList) void {
    if (cl.flags & T.CLIENT_READONLY != 0 and !cmd_mod.cmd_list_all_have(@ptrCast(cmd_list), T.CMD_READONLY)) {
        cmd_mod.cmd_list_free(cmd_list);
        status_runtime.present_client_message(cl, "client is read-only");
        server_client_send_exit_status(cl, 1);
        return;
    }
    cmdq_mod.cmdq_append(cl, cmd_list);
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

fn server_client_dispatch_command(cl: *T.Client, imsg_msg: *c.imsg.imsg) void {
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
    for (client_registry.clients.items) |cl| {
        if (cl.flags & T.CLIENT_EXIT != 0) {
            if (cl.peer) |peer| {
                const retval: i32 = 0;
                _ = proc_mod.proc_send(peer, .exit, -1, @ptrCast(std.mem.asBytes(&retval)), @sizeOf(i32));
            }
            cl.flags &= ~@as(u64, T.CLIENT_EXIT);
        }
        if (cl.flags & T.CLIENT_ATTACHED == 0) continue;
        if (cl.flags & T.CLIENT_SUSPENDED != 0) continue;
        const redraw_flags = cl.flags & T.CLIENT_REDRAW;
        if (redraw_flags == 0) continue;
        if (cl.flags & T.CLIENT_CONTROL != 0) {
            cl.flags &= ~@as(u64, T.CLIENT_REDRAW);
            continue;
        }
        server_client_draw(cl, redraw_flags);
        cl.flags &= ~@as(u64, T.CLIENT_REDRAW);
    }
}

pub fn server_client_apply_session_size(cl: *T.Client, s: *T.Session) void {
    if (s.curw) |wl| wl.window.latest = @ptrCast(cl);
    resize_mod.recalculate_sizes_now(true);
}

pub fn server_client_set_session(cl: *T.Client, s: *T.Session) void {
    const srv = @import("server.zig");
    const old_session = cl.session;
    const now = std.time.milliTimestamp();
    if (cl.session) |current| {
        if (current == s) {
            s.last_attached_time = now;
            sess.session_update_activity(s, now);
            server_client_apply_session_size(cl, s);
            return;
        }
        if (current != s and current.attached > 0) current.attached -= 1;
        cl.last_session = current;
    }
    cl.session = s;
    s.attached += 1;
    if (s.curw) |wl| wl.flags &= ~@as(u32, T.WINLINK_ALERTFLAGS);
    s.last_attached_time = now;
    sess.session_update_activity(s, now);
    alerts.alerts_check_session(s);
    tty_draw.tty_draw_invalidate(&cl.pane_cache);
    server_client_apply_session_size(cl, s);
    srv.server_update_socket();
    if (old_session != s) notify.notify_client("client-session-changed", cl);
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
    if (env_mod.environ_find(cl.environ, "ZMUX")) |entry| {
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

fn build_client_draw_payload(cl: *T.Client, redraw_flags: u64) ?[]u8 {
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

    if (mode_payload.items.len == 0 and body.payload.len == 0 and border_payload.len == 0 and scrollbar_payload.len == 0 and status_render.payload.len == 0 and overlay_payload == null) return null;

    var buf: std.ArrayList(u8) = .{};
    errdefer buf.deinit(xm.allocator);
    buf.appendSlice(xm.allocator, mode_payload.items) catch return null;
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
        const cursor = std.fmt.allocPrint(
            xm.allocator,
            "\x1b[{d};{d}H\x1b[?25h",
            .{ status_render.cursor_y + 1, status_render.cursor_x + 1 },
        ) catch return null;
        defer xm.allocator.free(cursor);
        buf.appendSlice(xm.allocator, cursor) catch return null;
    } else if (body.cursor_visible) {
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

    if (payload) |bytes| {
        if (cl.peer) |peer| {
            _ = file_mod.sendPeerStream(peer, 1, bytes);
        }
    }

    const s = cl.session orelse return;
    const wl = s.curw orelse return;
    const wp = wl.window.active orelse return;
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
    if (title_changed and title.len != 0) tty_mod.tty_set_title(&cl.tty, title);
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

test "server_client_resolve_cwd prefers accessible directories and falls back" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const real = try tmp.dir.realpathAlloc(xm.allocator, ".");
    defer xm.allocator.free(real);

    const resolved = server_client_resolve_cwd(real);
    try std.testing.expectEqualStrings(real, resolved);

    const missing = "/tmp/zmux-server-client-missing-cwd";
    const fallback = server_client_resolve_cwd(missing);
    try std.testing.expect(!std.mem.eql(u8, missing, fallback));
    if (std.posix.getenv("HOME")) |home|
        try std.testing.expectEqualStrings(home, fallback)
    else
        try std.testing.expectEqualStrings("/", fallback);
}

test "server_client_finalize_identify supplies client name and default term" {
    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);

    var cl = T.Client{
        .pid = 42,
        .environ = env,
        .tty = undefined,
        .status = .{ .screen = undefined },
    };
    cl.tty = .{ .client = &cl };
    defer {
        if (cl.name) |name| xm.allocator.free(@constCast(name));
        if (cl.term_name) |term_name| xm.allocator.free(term_name);
        if (cl.ttyname) |ttyname| xm.allocator.free(ttyname);
    }

    server_client_finalize_identify(&cl);
    try std.testing.expectEqualStrings("unknown", cl.term_name.?);
    try std.testing.expectEqualStrings("client-42", cl.name.?);

    cl.ttyname = xm.xstrdup("/dev/pts/test");
    server_client_finalize_identify(&cl);
    try std.testing.expectEqualStrings("/dev/pts/test", cl.name.?);
}

test "server_client_open rejects non-terminal clients but accepts reduced local-terminal path" {
    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);

    var cl = T.Client{
        .environ = env,
        .tty = undefined,
        .status = .{ .screen = undefined },
    };
    cl.tty = .{ .client = &cl };

    var cause: ?[]u8 = null;
    try std.testing.expectEqual(@as(i32, -1), server_client_open(&cl, &cause));
    try std.testing.expectEqualStrings("not a terminal", cause.?);
    xm.allocator.free(cause.?);

    cause = null;
    cl.ttyname = xm.xstrdup("/dev/tty");
    defer xm.allocator.free(cl.ttyname.?);
    cl.flags = T.CLIENT_TERMINAL;
    try std.testing.expectEqual(@as(i32, -1), server_client_open(&cl, &cause));
    try std.testing.expectEqualStrings("can't use /dev/tty", cause.?);
    xm.allocator.free(cause.?);

    cause = null;
    xm.allocator.free(cl.ttyname.?);
    cl.ttyname = xm.xstrdup("/tmp/zmux-test-tty");
    try std.testing.expectEqual(@as(i32, 0), server_client_open(&cl, &cause));
    try std.testing.expect(cause == null);
    try std.testing.expect((cl.tty.flags & @as(i32, @intCast(T.TTY_OPENED))) != 0);
    try std.testing.expect((cl.tty.flags & @as(i32, @intCast(T.TTY_STARTED))) != 0);

    cl.flags = T.CLIENT_CONTROL;
    try std.testing.expectEqual(@as(i32, 0), server_client_open(&cl, &cause));
}

test "server_client_check_nested requires ZMUX and a live pane tty match" {
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
    win_mod.window_init_globals(xm.allocator);

    const s = sess.session_create(null, "server-client-nested-check", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("server-client-nested-check") != null) sess.session_destroy(s, false, "test");

    const w = win_mod.window_create(80, 24, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    var cause: ?[]u8 = null;
    const wl = sess.session_attach(s, w, 0, &cause) orelse unreachable;
    s.curw = wl;

    const wp = win_mod.window_add_pane(w, null, 80, 24);
    w.active = wp;
    const tty = "/dev/pts/server-client-nested";
    @memset(wp.tty_name[0..], 0);
    @memcpy(wp.tty_name[0..tty.len], tty);
    wp.fd = try std.posix.dup(std.posix.STDERR_FILENO);

    var client = T.Client{
        .environ = env_mod.environ_create(),
        .ttyname = xm.xstrdup(tty),
        .tty = undefined,
        .status = .{ .screen = undefined },
    };
    defer env_mod.environ_free(client.environ);
    defer xm.allocator.free(client.ttyname.?);
    client.tty = .{ .client = &client };

    try std.testing.expect(!server_client_check_nested(&client));

    env_mod.environ_set(client.environ, "ZMUX", 0, "/tmp/zmux.sock,1,0");
    try std.testing.expect(server_client_check_nested(&client));

    env_mod.environ_set(client.environ, "ZMUX", 0, "");
    try std.testing.expect(!server_client_check_nested(&client));

    xm.allocator.free(client.ttyname.?);
    client.ttyname = xm.xstrdup("/dev/pts/server-client-other");
    try std.testing.expect(!server_client_check_nested(&client));
}

fn test_peer_dispatch(_: ?*c.imsg.imsg, _: ?*anyopaque) callconv(.c) void {}

test "server_client_lock sends lock message and unlock restores redraw state" {
    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);

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
    win_mod.window_init_globals(xm.allocator);

    var pair: [2]i32 = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &pair));

    var proc = T.ZmuxProc{ .name = "server-client-lock-test" };
    defer proc.peers.deinit(xm.allocator);

    var options = T.Options.init(xm.allocator, null);
    defer options.deinit();
    opts.options_set_number(&options, "status", 1);
    opts.options_set_number(&options, "status-position", 0);
    var session_env = T.Environ.init(xm.allocator);
    defer session_env.deinit();
    var session = T.Session{
        .id = 1,
        .name = @constCast("lock-test"),
        .cwd = "/tmp",
        .options = &options,
        .environ = &session_env,
    };

    var client = T.Client{
        .fd = 1,
        .environ = env,
        .tty = undefined,
        .status = .{ .screen = undefined },
        .session = &session,
    };
    tty_mod.tty_init(&client.tty, &client);
    tty_mod.tty_start_tty(&client.tty);
    client.peer = proc_mod.proc_add_peer(&proc, pair[0], test_peer_dispatch, null);
    defer {
        const peer = client.peer.?;
        c.imsg.imsgbuf_clear(&peer.ibuf);
        std.posix.close(peer.ibuf.fd);
        xm.allocator.destroy(peer);
        proc.peers.clearRetainingCapacity();
    }

    var reader: c.imsg.imsgbuf = undefined;
    try std.testing.expectEqual(@as(i32, 0), c.imsg.imsgbuf_init(&reader, pair[1]));
    defer {
        c.imsg.imsgbuf_clear(&reader);
        std.posix.close(pair[1]);
    }

    server_client_lock(&client, "printf locked");
    try std.testing.expect(client.flags & T.CLIENT_SUSPENDED != 0);
    try std.testing.expect((client.tty.flags & @as(i32, @intCast(T.TTY_STARTED))) == 0);

    try std.testing.expectEqual(@as(i32, 1), c.imsg.imsgbuf_read(&reader));
    var imsg_msg: c.imsg.imsg = undefined;
    try std.testing.expect(c.imsg.imsg_get(&reader, &imsg_msg) > 0);
    defer c.imsg.imsg_free(&imsg_msg);

    try std.testing.expectEqual(@as(u32, @intCast(@intFromEnum(protocol.MsgType.lock))), c.imsg.imsg_get_type(&imsg_msg));
    const data_len = c.imsg.imsg_get_len(&imsg_msg);
    var payload = try xm.allocator.alloc(u8, data_len);
    defer xm.allocator.free(payload);
    try std.testing.expectEqual(@as(i32, 0), c.imsg.imsg_get_data(&imsg_msg, payload.ptr, payload.len));
    try std.testing.expectEqualStrings("printf locked", payload[0 .. payload.len - 1]);

    server_client_unlock(&client);
    try std.testing.expect(client.flags & T.CLIENT_SUSPENDED == 0);
    try std.testing.expect((client.tty.flags & @as(i32, @intCast(T.TTY_STARTED))) != 0);
    try std.testing.expect(client.flags & T.CLIENT_REDRAWWINDOW != 0);
}

test "server_client_detach sends detachkill payload and clears session state" {
    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);

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

    var pair: [2]i32 = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &pair));

    var proc = T.ZmuxProc{ .name = "server-client-detach-test" };
    defer proc.peers.deinit(xm.allocator);

    const session = sess.session_create(null, "detach-test", "/tmp", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("detach-test") != null) sess.session_destroy(session, false, "test");
    session.attached = 1;

    var client = T.Client{
        .environ = env,
        .tty = undefined,
        .status = .{ .screen = undefined },
        .flags = T.CLIENT_ATTACHED,
        .session = session,
    };
    client.tty = .{ .client = &client };
    client.peer = proc_mod.proc_add_peer(&proc, pair[0], test_peer_dispatch, null);
    defer {
        const peer = client.peer.?;
        c.imsg.imsgbuf_clear(&peer.ibuf);
        std.posix.close(peer.ibuf.fd);
        xm.allocator.destroy(peer);
        proc.peers.clearRetainingCapacity();
        if (client.exit_session) |name| xm.allocator.free(name);
    }

    var reader: c.imsg.imsgbuf = undefined;
    try std.testing.expectEqual(@as(i32, 0), c.imsg.imsgbuf_init(&reader, pair[1]));
    defer {
        c.imsg.imsgbuf_clear(&reader);
        std.posix.close(pair[1]);
    }

    server_client_detach(&client, .detachkill);
    try std.testing.expect(client.session == null);
    try std.testing.expect(client.flags & T.CLIENT_ATTACHED == 0);
    try std.testing.expectEqual(T.ClientExitReason.detached_hup, client.exit_reason);
    try std.testing.expectEqualStrings("detach-test", client.exit_session.?);
    try std.testing.expectEqual(@as(u32, 0), session.attached);

    try std.testing.expectEqual(@as(i32, 1), c.imsg.imsgbuf_read(&reader));
    var imsg_msg: c.imsg.imsg = undefined;
    try std.testing.expect(c.imsg.imsg_get(&reader, &imsg_msg) > 0);
    defer c.imsg.imsg_free(&imsg_msg);

    try std.testing.expectEqual(@as(u32, @intCast(@intFromEnum(protocol.MsgType.detachkill))), c.imsg.imsg_get_type(&imsg_msg));
    const data_len = c.imsg.imsg_get_len(&imsg_msg);
    var payload = try xm.allocator.alloc(u8, data_len);
    defer xm.allocator.free(payload);
    try std.testing.expectEqual(@as(i32, 0), c.imsg.imsg_get_data(&imsg_msg, payload.ptr, payload.len));
    try std.testing.expectEqualStrings("detach-test", payload[0 .. payload.len - 1]);
}

test "server_client_lost clears attached socket execute bits" {
    const srv = @import("server.zig");

    client_registry.clients.clearRetainingCapacity();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const real = try tmp.dir.realpathAlloc(xm.allocator, ".");
    defer xm.allocator.free(real);

    const test_socket_path = try std.fs.path.join(xm.allocator, &.{ real, "server.sock" });
    defer xm.allocator.free(test_socket_path);

    const old_socket_path = srv.socket_path;
    defer srv.socket_path = old_socket_path;
    srv.socket_path = test_socket_path;

    const old_server_fd = srv.server_fd;
    defer srv.server_fd = old_server_fd;
    srv.server_fd = -1;
    defer if (srv.server_fd >= 0) std.posix.close(srv.server_fd);

    const old_server_client_flags = srv.server_client_flags;
    defer srv.server_client_flags = old_server_client_flags;
    srv.server_client_flags = T.CLIENT_DEFAULTSOCKET;

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
    win_mod.window_init_globals(xm.allocator);

    const session = sess.session_create(null, "lost-socket-test", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    const window = win_mod.window_create(80, 24, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    defer {
        if (sess.session_find("lost-socket-test") != null) sess.session_destroy(session, false, "test");
        win_mod.window_remove_ref(window, "test");
    }

    var cause: ?[]u8 = null;
    const wl = sess.session_attach(session, window, -1, &cause).?;
    const wp = win_mod.window_add_pane(window, null, 80, 24);
    window.active = wp;
    session.curw = wl;

    srv.server_fd = srv.server_create_socket(srv.server_client_flags, &cause);
    defer if (cause) |msg| xm.allocator.free(msg);
    try std.testing.expect(srv.server_fd >= 0);

    const client = try xm.allocator.create(T.Client);
    client.* = .{
        .name = xm.xstrdup("lost-client"),
        .environ = env_mod.environ_create(),
        .tty = .{ .client = client },
        .status = .{ .screen = undefined },
        .flags = T.CLIENT_ATTACHED,
        .session = session,
    };
    tty_mod.tty_init(&client.tty, client);
    client_registry.add(client);

    resize_mod.recalculate_sizes();
    srv.server_update_socket();

    const before = try std.fs.cwd().statFile(srv.socket_path);
    try std.testing.expectEqual(@as(std.fs.File.Mode, 0o770), before.mode & 0o777);
    try std.testing.expectEqual(@as(u32, 1), session.attached);

    server_client_lost(client);

    const after = try std.fs.cwd().statFile(srv.socket_path);
    try std.testing.expectEqual(@as(std.fs.File.Mode, 0o660), after.mode & 0o777);
    try std.testing.expectEqual(@as(u32, 0), session.attached);
    try std.testing.expectEqual(@as(usize, 0), client_registry.clients.items.len);
}

test "server_client_suspend sends suspend message and leaves session attached" {
    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);

    var pair: [2]i32 = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &pair));

    var proc = T.ZmuxProc{ .name = "server-client-suspend-test" };
    defer proc.peers.deinit(xm.allocator);

    var options = T.Options.init(xm.allocator, null);
    defer options.deinit();
    var session_env = T.Environ.init(xm.allocator);
    defer session_env.deinit();
    var session = T.Session{
        .id = 1,
        .name = @constCast("suspend-test"),
        .cwd = "/tmp",
        .options = &options,
        .environ = &session_env,
        .attached = 1,
    };

    var client = T.Client{
        .fd = 1,
        .environ = env,
        .tty = undefined,
        .status = .{ .screen = undefined },
        .flags = T.CLIENT_ATTACHED,
        .session = &session,
    };
    tty_mod.tty_init(&client.tty, &client);
    tty_mod.tty_start_tty(&client.tty);
    client.peer = proc_mod.proc_add_peer(&proc, pair[0], test_peer_dispatch, null);
    defer {
        const peer = client.peer.?;
        c.imsg.imsgbuf_clear(&peer.ibuf);
        std.posix.close(peer.ibuf.fd);
        xm.allocator.destroy(peer);
        proc.peers.clearRetainingCapacity();
    }

    var reader: c.imsg.imsgbuf = undefined;
    try std.testing.expectEqual(@as(i32, 0), c.imsg.imsgbuf_init(&reader, pair[1]));
    defer {
        c.imsg.imsgbuf_clear(&reader);
        std.posix.close(pair[1]);
    }

    server_client_suspend(&client);
    try std.testing.expect(client.flags & T.CLIENT_SUSPENDED != 0);
    try std.testing.expect(client.session == &session);
    try std.testing.expect((client.tty.flags & @as(i32, @intCast(T.TTY_STARTED))) == 0);

    try std.testing.expectEqual(@as(i32, 1), c.imsg.imsgbuf_read(&reader));
    var imsg_msg: c.imsg.imsg = undefined;
    try std.testing.expect(c.imsg.imsg_get(&reader, &imsg_msg) > 0);
    defer c.imsg.imsg_free(&imsg_msg);

    try std.testing.expectEqual(@as(u32, @intCast(@intFromEnum(protocol.MsgType.@"suspend"))), c.imsg.imsg_get_type(&imsg_msg));
    try std.testing.expectEqual(@as(usize, 0), c.imsg.imsg_get_len(&imsg_msg));
}

test "server_client_exec sends command and shell payload" {
    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);

    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);

    var pair: [2]i32 = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &pair));

    var proc = T.ZmuxProc{ .name = "server-client-exec-test" };
    defer proc.peers.deinit(xm.allocator);

    var options = T.Options.init(xm.allocator, null);
    defer options.deinit();
    opts.options_set_string(&options, false, "default-shell", "/bin/sh");
    var session_env = T.Environ.init(xm.allocator);
    defer session_env.deinit();
    var session = T.Session{
        .id = 1,
        .name = @constCast("exec-test"),
        .cwd = "/tmp",
        .options = &options,
        .environ = &session_env,
    };

    var client = T.Client{
        .environ = env,
        .tty = undefined,
        .status = .{ .screen = undefined },
        .session = &session,
    };
    client.tty = .{ .client = &client };
    client.peer = proc_mod.proc_add_peer(&proc, pair[0], test_peer_dispatch, null);
    defer {
        const peer = client.peer.?;
        c.imsg.imsgbuf_clear(&peer.ibuf);
        std.posix.close(peer.ibuf.fd);
        xm.allocator.destroy(peer);
        proc.peers.clearRetainingCapacity();
    }

    var reader: c.imsg.imsgbuf = undefined;
    try std.testing.expectEqual(@as(i32, 0), c.imsg.imsgbuf_init(&reader, pair[1]));
    defer {
        c.imsg.imsgbuf_clear(&reader);
        std.posix.close(pair[1]);
    }

    server_client_exec(&client, "printf exec");

    try std.testing.expectEqual(@as(i32, 1), c.imsg.imsgbuf_read(&reader));
    var imsg_msg: c.imsg.imsg = undefined;
    try std.testing.expect(c.imsg.imsg_get(&reader, &imsg_msg) > 0);
    defer c.imsg.imsg_free(&imsg_msg);

    try std.testing.expectEqual(@as(u32, @intCast(@intFromEnum(protocol.MsgType.exec))), c.imsg.imsg_get_type(&imsg_msg));
    const data_len = c.imsg.imsg_get_len(&imsg_msg);
    var payload = try xm.allocator.alloc(u8, data_len);
    defer xm.allocator.free(payload);
    try std.testing.expectEqual(@as(i32, 0), c.imsg.imsg_get_data(&imsg_msg, payload.ptr, payload.len));
    try std.testing.expectEqualStrings("printf exec", payload[0.."printf exec".len]);
    try std.testing.expectEqual(@as(u8, 0), payload["printf exec".len]);
    try std.testing.expectEqualStrings("/bin/sh", payload["printf exec".len + 1 .. payload.len - 1]);
}

test "server_client_send_shell returns default shell over shell message" {
    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    opts.options_set_string(opts.global_s_options, false, "default-shell", "/bin/sh");

    var pair: [2]i32 = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &pair));

    var proc = T.ZmuxProc{ .name = "server-client-shell-test" };
    defer proc.peers.deinit(xm.allocator);

    var client = T.Client{
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{ .screen = undefined },
        .pane_cache = .{},
        .stdin_pending = .{},
    };
    client.tty = .{ .client = &client };
    client.peer = proc_mod.proc_add_peer(&proc, pair[0], test_peer_dispatch, null);
    defer {
        env_mod.environ_free(client.environ);
        client.stdin_pending.deinit(xm.allocator);
        const peer = client.peer.?;
        c.imsg.imsgbuf_clear(&peer.ibuf);
        std.posix.close(peer.ibuf.fd);
        xm.allocator.destroy(peer);
        proc.peers.clearRetainingCapacity();
    }

    var reader: c.imsg.imsgbuf = undefined;
    try std.testing.expectEqual(@as(i32, 0), c.imsg.imsgbuf_init(&reader, pair[1]));
    defer {
        c.imsg.imsgbuf_clear(&reader);
        std.posix.close(pair[1]);
    }

    server_client_send_shell(&client);

    try std.testing.expectEqual(@as(i32, 1), c.imsg.imsgbuf_read(&reader));
    var imsg_msg: c.imsg.imsg = undefined;
    try std.testing.expect(c.imsg.imsg_get(&reader, &imsg_msg) > 0);
    defer c.imsg.imsg_free(&imsg_msg);

    try std.testing.expectEqual(@as(u32, @intCast(@intFromEnum(protocol.MsgType.shell))), c.imsg.imsg_get_type(&imsg_msg));
    const data_len = c.imsg.imsg_get_len(&imsg_msg);
    var payload = try xm.allocator.alloc(u8, data_len);
    defer xm.allocator.free(payload);
    try std.testing.expectEqual(@as(i32, 0), c.imsg.imsg_get_data(&imsg_msg, payload.ptr, payload.len));
    try std.testing.expectEqualStrings("/bin/sh", payload[0 .. payload.len - 1]);
    try std.testing.expectEqual(@as(u8, 0), payload[payload.len - 1]);
}

test "server_client_dispatch_command queues default-client-command when argc is zero" {
    cmdq_mod.cmdq_reset_for_tests();
    defer cmdq_mod.cmdq_reset_for_tests();

    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    opts.options_set_command(opts.global_options, "default-client-command", "list-commands");

    var client = T.Client{
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{ .screen = undefined },
        .pane_cache = .{},
        .stdin_pending = .{},
    };
    defer env_mod.environ_free(client.environ);
    defer client.stdin_pending.deinit(xm.allocator);
    client.tty = .{ .client = &client };

    var payload = protocol.MsgCommand{ .argc = 0 };
    var imsg_msg = std.mem.zeroes(c.imsg.imsg);
    imsg_msg.hdr.type = @as(@TypeOf(imsg_msg.hdr.type), @intCast(@intFromEnum(protocol.MsgType.command)));
    imsg_msg.hdr.len = @as(@TypeOf(imsg_msg.hdr.len), @sizeOf(c.imsg.imsg_hdr) + @sizeOf(protocol.MsgCommand));
    imsg_msg.data = @ptrCast(&payload);

    server_client_dispatch_command(&client, &imsg_msg);

    try std.testing.expect(cmdq_mod.cmdq_has_pending(&client));
}

test "build_client_draw_payload keeps multi-pane status-only redraw off the full-clear body path" {
    const pane_io = @import("pane-io.zig");

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
    win_mod.window_init_globals(xm.allocator);

    const s = sess.session_create(null, "server-client-status-only", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("server-client-status-only") != null) sess.session_destroy(s, false, "test");

    const w = win_mod.window_create(6, 2, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    var cause: ?[]u8 = null;
    const wl = sess.session_attach(s, w, 0, &cause) orelse unreachable;
    s.curw = wl;

    const left = win_mod.window_add_pane(w, null, 3, 2);
    const right = win_mod.window_add_pane(w, null, 3, 2);
    left.xoff = 0;
    left.yoff = 0;
    right.xoff = 3;
    right.yoff = 0;
    w.active = right;

    pane_io.pane_io_feed(left, "L1\nL2");
    pane_io.pane_io_feed(right, "R1\nR2");

    var client = T.Client{
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{ .screen = undefined },
        .flags = T.CLIENT_ATTACHED,
        .session = s,
    };
    defer env_mod.environ_free(client.environ);
    client.tty = .{ .client = &client, .sx = 6, .sy = 3 };

    const status_only = build_client_draw_payload(&client, T.CLIENT_REDRAWSTATUS) orelse unreachable;
    defer xm.allocator.free(status_only);
    try std.testing.expect(status_only.len != 0);
    try std.testing.expect(std.mem.indexOf(u8, status_only, "\x1b[H\x1b[2J") == null);
    try std.testing.expect(std.mem.indexOf(u8, status_only, "L1") == null);
    try std.testing.expect(std.mem.indexOf(u8, status_only, "R1") == null);

    const full_window = build_client_draw_payload(&client, T.CLIENT_REDRAWWINDOW) orelse unreachable;
    defer xm.allocator.free(full_window);
    try std.testing.expect(std.mem.indexOf(u8, full_window, "\x1b[H\x1b[2J") != null);
    try std.testing.expect(std.mem.indexOf(u8, full_window, "L1") != null);
    try std.testing.expect(std.mem.indexOf(u8, full_window, "R1") != null);
}

test "build_client_draw_payload crops a panned multi-pane viewport" {
    const pane_io = @import("pane-io.zig");

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
    win_mod.window_init_globals(xm.allocator);

    const s = sess.session_create(null, "server-client-panned-window", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("server-client-panned-window") != null) sess.session_destroy(s, false, "test");

    const w = win_mod.window_create(6, 2, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    var cause: ?[]u8 = null;
    const wl = sess.session_attach(s, w, 0, &cause) orelse unreachable;
    s.curw = wl;

    const left = win_mod.window_add_pane(w, null, 3, 2);
    const right = win_mod.window_add_pane(w, null, 3, 2);
    left.xoff = 0;
    left.yoff = 0;
    right.xoff = 3;
    right.yoff = 0;
    w.active = right;

    pane_io.pane_io_feed(left, "L1\nL2");
    pane_io.pane_io_feed(right, "R1\nR2");

    var client = T.Client{
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{ .screen = undefined },
        .flags = T.CLIENT_ATTACHED | T.CLIENT_UTF8 | T.CLIENT_STATUSOFF,
        .session = s,
        .pan_window = w,
        .pan_ox = 3,
    };
    defer env_mod.environ_free(client.environ);
    client.tty = .{ .client = &client, .sx = 3, .sy = 2 };

    const payload = build_client_draw_payload(&client, T.CLIENT_REDRAWWINDOW) orelse unreachable;
    defer xm.allocator.free(payload);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\x1b[H\x1b[2J") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "R1") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "R2") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "L1") == null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "L2") == null);
}

test "build_client_draw_payload keeps border-only redraw off the full-clear body path" {
    const pane_io = @import("pane-io.zig");

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
    win_mod.window_init_globals(xm.allocator);

    const s = sess.session_create(null, "server-client-borders-only", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("server-client-borders-only") != null) sess.session_destroy(s, false, "test");

    const w = win_mod.window_create(6, 2, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    var cause: ?[]u8 = null;
    const wl = sess.session_attach(s, w, 0, &cause) orelse unreachable;
    s.curw = wl;

    const left = win_mod.window_add_pane(w, null, 3, 2);
    const right = win_mod.window_add_pane(w, null, 3, 2);
    left.xoff = 0;
    left.yoff = 0;
    right.xoff = 3;
    right.yoff = 0;
    w.active = right;

    pane_io.pane_io_feed(left, "L1\nL2");
    pane_io.pane_io_feed(right, "R1\nR2");

    var client = T.Client{
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{ .screen = undefined },
        .flags = T.CLIENT_ATTACHED | T.CLIENT_UTF8 | T.CLIENT_STATUSOFF,
        .session = s,
    };
    defer env_mod.environ_free(client.environ);
    client.tty = .{ .client = &client, .sx = 6, .sy = 2 };

    const borders_only = build_client_draw_payload(&client, T.CLIENT_REDRAWBORDERS) orelse unreachable;
    defer xm.allocator.free(borders_only);
    try std.testing.expect(borders_only.len != 0);
    try std.testing.expect(std.mem.indexOf(u8, borders_only, "\x1b[H\x1b[2J") == null);
    try std.testing.expect(std.mem.indexOf(u8, borders_only, "L1") == null);
    try std.testing.expect(std.mem.indexOf(u8, borders_only, "R1") == null);
    try std.testing.expect(std.mem.indexOf(u8, borders_only, "\x1b[1;4H") != null);
}

test "build_client_draw_payload keeps scrollbar-only redraw off the full-clear body path" {
    const screen_write = @import("screen-write.zig");

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
    win_mod.window_init_globals(xm.allocator);

    const s = sess.session_create(null, "server-client-scrollbars-only", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("server-client-scrollbars-only") != null) sess.session_destroy(s, false, "test");

    const w = win_mod.window_create(4, 4, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    var cause: ?[]u8 = null;
    const wl = sess.session_attach(s, w, 0, &cause) orelse unreachable;
    s.curw = wl;

    const wp = win_mod.window_add_pane(w, null, 4, 4);
    w.active = wp;
    opts.options_set_number(wp.options, "pane-scrollbars", T.PANE_SCROLLBARS_ALWAYS);
    opts.options_set_string(wp.options, false, "pane-scrollbars-style", "fg=blue,pad=1");
    win_mod.window_pane_options_changed(wp, "pane-scrollbars-style");
    wp.base.grid.hsize = 4;

    var ctx = T.ScreenWriteCtx{ .wp = wp, .s = &wp.base };
    screen_write.putn(&ctx, "abcd");

    var client = T.Client{
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{ .screen = undefined },
        .flags = T.CLIENT_ATTACHED | T.CLIENT_UTF8 | T.CLIENT_STATUSOFF,
        .session = s,
    };
    defer env_mod.environ_free(client.environ);
    client.tty = .{ .client = &client, .sx = win_mod.window_pane_total_width(wp), .sy = 4 };

    const scrollbars_only = build_client_draw_payload(&client, T.CLIENT_REDRAWSCROLLBARS) orelse unreachable;
    defer xm.allocator.free(scrollbars_only);
    try std.testing.expect(scrollbars_only.len != 0);
    try std.testing.expect(std.mem.indexOf(u8, scrollbars_only, "\x1b[H\x1b[2J") == null);
    try std.testing.expect(std.mem.indexOf(u8, scrollbars_only, "abcd") == null);
    try std.testing.expect(std.mem.indexOf(u8, scrollbars_only, "\x1b[0;34m ") != null);
}

test "build_client_draw_payload can redraw only dirty panes without clearing the whole window" {
    const pane_io = @import("pane-io.zig");

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
    win_mod.window_init_globals(xm.allocator);

    const s = sess.session_create(null, "server-client-dirty-pane", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("server-client-dirty-pane") != null) sess.session_destroy(s, false, "test");

    const w = win_mod.window_create(6, 2, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    var cause: ?[]u8 = null;
    const wl = sess.session_attach(s, w, 0, &cause) orelse unreachable;
    s.curw = wl;

    const left = win_mod.window_add_pane(w, null, 3, 2);
    const right = win_mod.window_add_pane(w, null, 3, 2);
    left.xoff = 0;
    left.yoff = 0;
    right.xoff = 3;
    right.yoff = 0;
    w.active = right;

    pane_io.pane_io_feed(left, "L1\nL2");
    pane_io.pane_io_feed(right, "R1\nR2");
    right.flags |= T.PANE_REDRAW;

    var client = T.Client{
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{ .screen = undefined },
        .flags = T.CLIENT_ATTACHED | T.CLIENT_UTF8 | T.CLIENT_STATUSOFF,
        .session = s,
    };
    defer env_mod.environ_free(client.environ);
    client.tty = .{ .client = &client, .sx = 6, .sy = 2 };

    const dirty = build_client_draw_payload(&client, T.CLIENT_REDRAWPANES) orelse unreachable;
    defer xm.allocator.free(dirty);
    try std.testing.expect(dirty.len != 0);
    try std.testing.expect(std.mem.indexOf(u8, dirty, "\x1b[H\x1b[2J") == null);
    try std.testing.expect(std.mem.indexOf(u8, dirty, "L1") == null);
    try std.testing.expect(std.mem.indexOf(u8, dirty, "R1") != null);
    try std.testing.expect(right.flags & T.PANE_REDRAW == 0);
}
