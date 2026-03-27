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
const file_write_mod = @import("file-write.zig");
const opts = @import("options.zig");
const sess = @import("session.zig");
const env_mod = @import("environ.zig");
const cmd_mod = @import("cmd.zig");
const cmdq_mod = @import("cmd-queue.zig");
const win_mod = @import("window.zig");
const sess_mod = @import("session.zig");
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
    file_write_mod.fail_pending_writes_for_client(cl);
    status_prompt.status_prompt_clear(cl);
    status_runtime.status_message_clear(cl);
    status_runtime.status_cleanup(cl);
    status.status_free(cl);
    const srv = @import("server.zig");
    srv.server_remove_client(cl);
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
    if (cl.ttyname) |ttyname| xm.allocator.free(ttyname);
    if (cl.title) |title| xm.allocator.free(title);
    if (cl.path) |path| xm.allocator.free(path);
    if (cl.key_table_name) |name| xm.allocator.free(name);
    cl.stdin_pending.deinit(xm.allocator);
    tty_mod.tty_close(&cl.tty);
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
        .unlock, .wakeup => server_client_unlock(cl),
        .write_ready => file_write_mod.handle_write_ready(imsg_msg),
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
        status_runtime.present_client_message(cl, cause orelse "parse error");
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
        if (cl.flags & T.CLIENT_SUSPENDED != 0) continue;
        if (cl.flags & T.CLIENT_REDRAW == 0) continue;
        if (cl.flags & T.CLIENT_CONTROL != 0) {
            cl.flags &= ~@as(u64, T.CLIENT_REDRAW);
            continue;
        }
        server_client_draw(cl);
        cl.flags &= ~@as(u64, T.CLIENT_REDRAW);
    }
}

pub fn server_client_apply_session_size(cl: *T.Client, s: *T.Session) void {
    if (s.curw) |wl| wl.window.latest = @ptrCast(cl);
    resize_mod.recalculate_sizes_now(true);
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
    if (s.curw) |wl| wl.flags &= ~@as(u32, T.WINLINK_ALERTFLAGS);
    sess.session_update_activity(s, null);
    alerts.alerts_check_session(s);
    tty_draw.tty_draw_invalidate(&cl.pane_cache);
    server_client_apply_session_size(cl, s);
    if (old_session != s) notify.notify_client("client-session-changed", cl);
}

pub fn server_client_force_redraw(cl: *T.Client) void {
    tty_mod.tty_invalidate(&cl.tty);
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

pub fn server_client_check_nested(cl: *T.Client) bool {
    if (cl.environ.entries.get("ZMUX")) |entry| {
        if (entry.value != null) return true;
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

fn visiblePaneCount(w: *T.Window) usize {
    var count: usize = 0;
    for (w.panes.items) |pane| {
        if (win_mod.window_pane_visible(pane)) count += 1;
    }
    return count;
}

fn canUseCachedPaneDraw(w: *T.Window, wp: *T.WindowPane) bool {
    if (visiblePaneCount(w) != 1) return false;
    const bounds = win_mod.window_pane_draw_bounds(wp);
    return bounds.xoff == 0 and bounds.yoff == 0;
}

fn server_client_draw(cl: *T.Client) void {
    const s = cl.session orelse return;
    const wl = s.curw orelse return;
    const wp = wl.window.active orelse return;
    const overlay_rows = status.overlay_rows(cl);
    const pane_row_offset = status.pane_row_offset(cl);
    const tty_sx = if (cl.tty.sx == 0) win_mod.window_pane_total_width(wp) else cl.tty.sx;
    const tty_sy = if (cl.tty.sy == 0) wp.base.grid.sy + overlay_rows else cl.tty.sy;
    const pane_area_sy = if (tty_sy > overlay_rows) tty_sy - overlay_rows else 0;
    if (tty_sx == 0 or pane_area_sy == 0) return;

    var body = BodyRenderResult{};
    if (canUseCachedPaneDraw(wl.window, wp)) {
        win_mod.window_pane_update_scrollbar_geometry(wp);
        const pane_width = win_mod.window_pane_total_width(wp);
        const sx = @min(tty_sx, pane_width);
        const sy = @min(pane_area_sy, wp.base.grid.sy);
        if (sx == 0 or sy == 0) return;

        body.payload = tty_draw.tty_draw_pane_offset(&cl.pane_cache, wp, sx, sy, pane_row_offset) catch return;
        body.cursor_visible = cl.pane_cache.cursor_visible;
        body.cursor_x = cl.pane_cache.cursor_x;
        body.cursor_y = pane_row_offset + cl.pane_cache.cursor_y;
    } else {
        const rendered = tty_draw.tty_draw_render_window(wl.window, tty_sx, pane_area_sy, pane_row_offset) catch return;
        body = .{
            .payload = rendered.payload,
            .cursor_visible = rendered.cursor_visible,
            .cursor_x = rendered.cursor_x,
            .cursor_y = rendered.cursor_y,
        };
        tty_draw.tty_draw_invalidate(&cl.pane_cache);
    }
    defer if (body.payload.len != 0) xm.allocator.free(body.payload);

    const status_render = status.render(cl);
    defer if (status_render.payload.len != 0) xm.allocator.free(status_render.payload);

    var mode_payload: std.ArrayList(u8) = .{};
    defer mode_payload.deinit(xm.allocator);
    tty_mod.tty_append_mode_update(&cl.tty, mouse_runtime.client_outer_tty_mode(cl), &mode_payload) catch return;

    if (mode_payload.items.len != 0 or body.payload.len != 0 or status_render.payload.len != 0) {
        if (cl.peer) |peer| {
            var buf: std.ArrayList(u8) = .{};
            defer buf.deinit(xm.allocator);
            const stream: i32 = 1;
            buf.appendSlice(xm.allocator, std.mem.asBytes(&stream)) catch unreachable;
            buf.appendSlice(xm.allocator, mode_payload.items) catch unreachable;
            buf.appendSlice(xm.allocator, body.payload) catch unreachable;
            if (status_render.payload.len != 0) {
                buf.appendSlice(xm.allocator, "\x1b[?25l") catch unreachable;
                buf.appendSlice(xm.allocator, status_render.payload) catch unreachable;
                if (status_render.cursor_visible) {
                    const cursor = std.fmt.allocPrint(
                        xm.allocator,
                        "\x1b[{d};{d}H\x1b[?25h",
                        .{ status_render.cursor_y + 1, status_render.cursor_x + 1 },
                    ) catch unreachable;
                    defer xm.allocator.free(cursor);
                    buf.appendSlice(xm.allocator, cursor) catch unreachable;
                } else if (body.cursor_visible) {
                    const cursor = std.fmt.allocPrint(
                        xm.allocator,
                        "\x1b[{d};{d}H\x1b[?25h",
                        .{ body.cursor_y + 1, body.cursor_x + 1 },
                    ) catch unreachable;
                    defer xm.allocator.free(cursor);
                    buf.appendSlice(xm.allocator, cursor) catch unreachable;
                }
            }
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
