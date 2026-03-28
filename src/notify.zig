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
// Ported in part from tmux/notify.c.
// Original copyright:
//   Copyright (c) 2012 George Nachman <tmux@georgester.com>
//   ISC licence – same terms as above.

const std = @import("std");
const T = @import("types.zig");
const cmd_find = @import("cmd-find.zig");
const cmd_mod = @import("cmd.zig");
const cmdq = @import("cmd-queue.zig");
const control_notify = @import("control-notify.zig");
const log = @import("log.zig");
const opts = @import("options.zig");
const sess = @import("session.zig");
const xm = @import("xmalloc.zig");

const OwnedHookInfo = struct {
    hook: ?[]u8 = null,
    hook_client: ?[]u8 = null,
    hook_session: ?[]u8 = null,
    hook_session_name: ?[]u8 = null,
    hook_window: ?[]u8 = null,
    hook_window_name: ?[]u8 = null,
    hook_pane: ?[]u8 = null,

    fn fromName(name: []const u8) OwnedHookInfo {
        return .{ .hook = xm.xstrdup(name) };
    }

    fn fromEvent(
        name: []const u8,
        cl: ?*T.Client,
        s: ?*T.Session,
        w: ?*T.Window,
        wp: ?*T.WindowPane,
    ) OwnedHookInfo {
        var info = fromName(name);
        if (cl) |client|
            info.hook_client = xm.xstrdup(clientDisplayName(client));
        if (s) |session| {
            info.hook_session = xm.xasprintf("${d}", .{session.id});
            info.hook_session_name = xm.xstrdup(session.name);
        }
        if (w) |window| {
            info.hook_window = xm.xasprintf("@{d}", .{window.id});
            info.hook_window_name = xm.xstrdup(window.name);
        }
        if (wp) |pane|
            info.hook_pane = xm.xasprintf("%{d}", .{pane.id});
        return info;
    }

    fn borrow(self: *const OwnedHookInfo) cmdq.HookInfo {
        return .{
            .hook = self.hook,
            .hook_client = self.hook_client,
            .hook_session = self.hook_session,
            .hook_session_name = self.hook_session_name,
            .hook_window = self.hook_window,
            .hook_window_name = self.hook_window_name,
            .hook_pane = self.hook_pane,
        };
    }

    fn deinit(self: *OwnedHookInfo) void {
        freeOwned(&self.hook);
        freeOwned(&self.hook_client);
        freeOwned(&self.hook_session);
        freeOwned(&self.hook_session_name);
        freeOwned(&self.hook_window);
        freeOwned(&self.hook_window_name);
        freeOwned(&self.hook_pane);
    }
};

const NotifyEntry = struct {
    fs: T.CmdFindState = .{ .idx = -1 },
    hook_info: OwnedHookInfo = .{},

    fn deinit(self: *NotifyEntry) void {
        self.hook_info.deinit();
    }
};

fn freeOwned(slot: *?[]u8) void {
    if (slot.*) |owned| xm.allocator.free(owned);
    slot.* = null;
}

fn clientDisplayName(cl: *T.Client) []const u8 {
    if (cl.name) |name| return name;
    if (cl.ttyname) |ttyname| return ttyname;
    return "unknown";
}

fn notificationsSuppressed() bool {
    const item = cmdq.cmdq_current_running() orelse return false;
    return (cmdq.cmdq_get_flags(item) & T.CMDQ_STATE_NOHOOKS) != 0;
}

fn canonicalHookState(source: *const T.CmdFindState) T.CmdFindState {
    if (cmd_find.cmd_find_valid_state(source)) return source.*;

    var fallback: T.CmdFindState = .{ .idx = -1 };
    if (cmd_find.cmd_find_from_nothing(&fallback, 0)) return fallback;
    return fallback;
}

fn hookOptionValue(name: []const u8, fs: *const T.CmdFindState) ?*const T.OptionsValue {
    const session_options = if (fs.s) |s| s.options else opts.global_s_options;
    if (opts.options_get(session_options, name)) |value| return value;
    if (fs.wp) |wp| {
        if (opts.options_get(wp.options, name)) |value| return value;
    }
    if (fs.wl) |wl| {
        if (opts.options_get(wl.window.options, name)) |value| return value;
    }
    return null;
}

fn enqueueHookCommand(
    after: ?*cmdq.CmdqItem,
    hook_name: []const u8,
    command: []const u8,
    state: *cmdq.CmdqState,
) ?*cmdq.CmdqItem {
    if (log.log_get_level() != 0)
        log.log_debug("notify hook {s}: {s}", .{ hook_name, command });

    var pi: T.CmdParseInput = .{};
    const parsed = cmd_mod.cmd_parse_from_string(command, &pi);
    switch (parsed.status) {
        .success => {
            const cmdlist_ptr = parsed.cmdlist orelse return after;
            const cmdlist: *T.CmdList = @ptrCast(@alignCast(cmdlist_ptr));
            const new_item = cmdq.cmdq_get_command(cmdlist, state);
            if (after) |item|
                return cmdq.cmdq_insert_after(item, new_item);
            return cmdq.cmdq_append_item(null, new_item);
        },
        .@"error" => {
            if (parsed.@"error") |err| {
                log.log_debug("notify hook {s}: {s}", .{ hook_name, err });
                xm.allocator.free(err);
            }
            return after;
        },
    }
}

fn insertHookCommands(
    after: ?*cmdq.CmdqItem,
    name: []const u8,
    fs: *const T.CmdFindState,
    hook_info: cmdq.HookInfo,
) void {
    var hook_state = canonicalHookState(fs);
    const state = cmdq.cmdq_new_state(if (cmd_find.cmd_find_valid_state(&hook_state)) &hook_state else null, null, T.CMDQ_STATE_NOHOOKS);
    defer cmdq.cmdq_free_state(state);
    cmdq.cmdq_set_hook_info(state, hook_info);

    const value = hookOptionValue(name, &hook_state) orelse return;

    var tail = after;
    switch (value.*) {
        .array => |arr| {
            for (arr.items) |command|
                tail = enqueueHookCommand(tail, name, command.value, state);
        },
        .string => |command| {
            if (name.len != 0 and name[0] == '@')
                _ = enqueueHookCommand(tail, name, command, state);
        },
        else => {},
    }
}

fn notifyCallback(item: *cmdq.CmdqItem, data: ?*anyopaque) T.CmdRetval {
    const entry: *NotifyEntry = @ptrCast(@alignCast(data orelse return .normal));
    defer {
        entry.deinit();
        xm.allocator.destroy(entry);
    }

    const name = entry.hook_info.hook orelse return .normal;
    insertHookCommands(item, name, &entry.fs, entry.hook_info.borrow());
    return .normal;
}

fn queueNotify(fs: *const T.CmdFindState, hook_info: OwnedHookInfo) void {
    const entry = xm.allocator.create(NotifyEntry) catch unreachable;
    entry.* = .{
        .fs = fs.*,
        .hook_info = hook_info,
    };
    _ = cmdq.cmdq_append_item(null, cmdq.cmdq_get_callback1("notify-hook", notifyCallback, entry));
}

pub fn notify_hook(item: *cmdq.CmdqItem, name: []const u8, current: ?*const T.CmdFindState) void {
    var info = OwnedHookInfo.fromName(name);
    defer info.deinit();

    var fs: T.CmdFindState = .{ .idx = -1 };
    if (current) |state| fs = state.*;

    if (item.queue != null) {
        insertHookCommands(item, name, &fs, info.borrow());
        return;
    }

    insertHookCommands(null, name, &fs, info.borrow());
    _ = cmdq.cmdq_next(null);
}

pub fn notify_client(name: []const u8, cl: *T.Client) void {
    if (notificationsSuppressed()) return;

    if (std.mem.eql(u8, name, "client-session-changed"))
        control_notify.control_notify_client_session_changed(cl)
    else if (std.mem.eql(u8, name, "client-detached"))
        control_notify.control_notify_client_detached(cl);

    var fs: T.CmdFindState = .{ .idx = -1 };
    if (!cmd_find.cmd_find_from_client(&fs, cl, 0))
        _ = cmd_find.cmd_find_from_nothing(&fs, 0);
    queueNotify(&fs, OwnedHookInfo.fromEvent(name, cl, null, null, null));
}

pub fn notify_session(name: []const u8, s: *T.Session) void {
    if (notificationsSuppressed()) return;

    if (std.mem.eql(u8, name, "session-renamed"))
        control_notify.control_notify_session_renamed(s)
    else if (std.mem.eql(u8, name, "session-created"))
        control_notify.control_notify_session_created(s)
    else if (std.mem.eql(u8, name, "session-closed"))
        control_notify.control_notify_session_closed(s)
    else if (std.mem.eql(u8, name, "session-window-changed"))
        control_notify.control_notify_session_window_changed(s);

    var fs: T.CmdFindState = .{ .idx = -1 };
    if (sess.session_alive(s))
        cmd_find.cmd_find_from_session(&fs, s, 0)
    else
        _ = cmd_find.cmd_find_from_nothing(&fs, 0);
    queueNotify(&fs, OwnedHookInfo.fromEvent(name, null, s, null, null));
}

pub fn notify_winlink(name: []const u8, wl: *T.Winlink) void {
    notify_session_window(name, wl.session, wl.window);
}

pub fn notify_session_window(name: []const u8, s: *T.Session, w: *T.Window) void {
    if (notificationsSuppressed()) return;

    if (std.mem.eql(u8, name, "window-unlinked"))
        control_notify.control_notify_window_unlinked(s, w)
    else if (std.mem.eql(u8, name, "window-linked"))
        control_notify.control_notify_window_linked(s, w);

    var fs: T.CmdFindState = .{ .idx = -1 };
    if (!cmd_find.cmd_find_from_session_window(&fs, s, w, 0))
        _ = cmd_find.cmd_find_from_nothing(&fs, 0);
    queueNotify(&fs, OwnedHookInfo.fromEvent(name, null, s, w, null));
}

pub fn notify_window(name: []const u8, w: *T.Window) void {
    if (notificationsSuppressed()) return;

    if (std.mem.eql(u8, name, "window-layout-changed"))
        control_notify.control_notify_window_layout_changed(w)
    else if (std.mem.eql(u8, name, "window-renamed"))
        control_notify.control_notify_window_renamed(w);

    var fs: T.CmdFindState = .{ .idx = -1 };
    if (!cmd_find.cmd_find_from_window(&fs, w, 0))
        _ = cmd_find.cmd_find_from_nothing(&fs, 0);
    queueNotify(&fs, OwnedHookInfo.fromEvent(name, null, null, w, null));
}

pub fn notify_pane(name: []const u8, wp: *T.WindowPane) void {
    if (notificationsSuppressed()) return;

    if (std.mem.eql(u8, name, "pane-mode-changed"))
        control_notify.control_notify_pane_mode_changed(wp);

    var fs: T.CmdFindState = .{ .idx = -1 };
    if (!cmd_find.cmd_find_from_pane(&fs, wp, 0))
        _ = cmd_find.cmd_find_from_nothing(&fs, 0);
    queueNotify(&fs, OwnedHookInfo.fromEvent(name, null, null, wp.window, wp));
}

pub fn notify_paste_buffer(pbname: []const u8, deleted: bool) void {
    if (notificationsSuppressed()) return;

    const name = if (deleted) "paste-buffer-deleted" else "paste-buffer-changed";
    if (deleted)
        control_notify.control_notify_paste_buffer_deleted(pbname)
    else
        control_notify.control_notify_paste_buffer_changed(pbname);

    var fs: T.CmdFindState = .{ .idx = -1 };
    queueNotify(&fs, OwnedHookInfo.fromName(name));
}

test "notify_window queues hook commands with window metadata" {
    const env_mod = @import("environ.zig");
    const win = @import("window.zig");
    cmdq.cmdq_reset_for_tests();
    defer cmdq.cmdq_reset_for_tests();

    sess.session_init_globals(xm.allocator);
    win.window_init_globals(xm.allocator);

    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    opts.options_set_array(opts.global_w_options, "window-renamed", &.{
        "set-environment -g -F HOOK_VALUE '#{hook_window_name}'",
    });

    env_mod.global_environ = env_mod.environ_create();
    defer env_mod.environ_free(env_mod.global_environ);

    const session = sess.session_create(null, "notify-window-hook", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer sess.session_destroy(session, false, "test");
    const window = win.window_create(80, 24, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    xm.allocator.free(window.name);
    window.name = xm.xstrdup("hooked-window");
    const pane = win.window_add_pane(window, null, 80, 24);
    window.active = pane;
    var cause: ?[]u8 = null;
    _ = sess.session_attach(session, window, -1, &cause).?;
    while (cmdq.cmdq_next(null) != 0) {}

    notify_window("window-renamed", window);
    try std.testing.expectEqual(@as(u32, 2), cmdq.cmdq_next(null));
    try std.testing.expectEqualStrings("hooked-window", env_mod.environ_find(env_mod.global_environ, "HOOK_VALUE").?.value.?);
}

test "notify hooks from client queue run after the client tail" {
    const env_mod = @import("environ.zig");
    const win = @import("window.zig");
    cmdq.cmdq_reset_for_tests();
    defer cmdq.cmdq_reset_for_tests();

    const callbacks = struct {
        var target_window: ?*T.Window = null;

        fn trigger(_: *cmdq.CmdqItem, _: ?*anyopaque) T.CmdRetval {
            notify_window("window-renamed", target_window.?);
            return .normal;
        }

        fn mark(_: *cmdq.CmdqItem, _: ?*anyopaque) T.CmdRetval {
            env_mod.environ_set(env_mod.global_environ, "ORDER", 0, "client-tail");
            return .normal;
        }
    };

    sess.session_init_globals(xm.allocator);
    win.window_init_globals(xm.allocator);

    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    opts.options_set_array(opts.global_w_options, "window-renamed", &.{
        "set-environment -g ORDER hook",
    });

    env_mod.global_environ = env_mod.environ_create();
    defer env_mod.environ_free(env_mod.global_environ);

    const session = sess.session_create(null, "notify-client-order", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer sess.session_destroy(session, false, "test");
    const window = win.window_create(80, 24, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    xm.allocator.free(window.name);
    window.name = xm.xstrdup("ordered-window");
    const pane = win.window_add_pane(window, null, 80, 24);
    window.active = pane;
    var cause: ?[]u8 = null;
    _ = sess.session_attach(session, window, -1, &cause).?;
    while (cmdq.cmdq_next(null) != 0) {}
    callbacks.target_window = window;

    var cl = T.Client{
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{ .screen = undefined },
    };
    defer env_mod.environ_free(cl.environ);
    cl.tty = .{ .client = &cl };

    _ = cmdq.cmdq_append_item(&cl, cmdq.cmdq_get_callback1("notify-trigger", callbacks.trigger, null));
    _ = cmdq.cmdq_append_item(&cl, cmdq.cmdq_get_callback1("notify-tail", callbacks.mark, null));

    try std.testing.expectEqual(@as(u32, 2), cmdq.cmdq_next(&cl));
    try std.testing.expectEqualStrings("client-tail", env_mod.environ_find(env_mod.global_environ, "ORDER").?.value.?);

    try std.testing.expectEqual(@as(u32, 2), cmdq.cmdq_next(null));
    try std.testing.expectEqualStrings("hook", env_mod.environ_find(env_mod.global_environ, "ORDER").?.value.?);
}

test "notify_window emits %layout-change to matching control clients" {
    const c = @import("c.zig");
    const env_mod = @import("environ.zig");
    const layout_mod = @import("layout.zig");
    const proc_mod = @import("proc.zig");
    const protocol = @import("zmux-protocol.zig");
    const win = @import("window.zig");
    const registry = @import("client-registry.zig");

    const helpers = struct {
        fn noopDispatch(_: ?*c.imsg.imsg, _: ?*anyopaque) callconv(.c) void {}
    };

    cmdq.cmdq_reset_for_tests();
    defer cmdq.cmdq_reset_for_tests();

    sess.session_init_globals(xm.allocator);
    win.window_init_globals(xm.allocator);

    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);

    env_mod.global_environ = env_mod.environ_create();
    defer env_mod.environ_free(env_mod.global_environ);

    const session = sess.session_create(null, "notify-layout-control", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer sess.session_destroy(session, false, "test");
    const window = win.window_create(80, 24, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    const pane = win.window_add_pane(window, null, 80, 24);
    window.active = pane;
    var cause: ?[]u8 = null;
    const wl = sess.session_attach(session, window, -1, &cause).?;
    session.curw = wl;
    while (cmdq.cmdq_next(null) != 0) {}

    const dumped = layout_mod.dump_window(window).?;
    defer xm.allocator.free(dumped);

    var pair: [2]i32 = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &pair));

    var proc = T.ZmuxProc{ .name = "notify-layout-control-test" };
    defer proc.peers.deinit(xm.allocator);

    var client = T.Client{
        .name = "layout-client",
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{ .screen = undefined },
        .session = session,
        .flags = T.CLIENT_CONTROL | T.CLIENT_UTF8,
    };
    defer env_mod.environ_free(client.environ);
    client.tty = .{ .client = &client };
    client.peer = proc_mod.proc_add_peer(&proc, pair[0], helpers.noopDispatch, null);
    defer {
        registry.remove(&client);
        const peer = client.peer.?;
        c.imsg.imsgbuf_clear(&peer.ibuf);
        std.posix.close(peer.ibuf.fd);
        xm.allocator.destroy(peer);
        proc.peers.clearRetainingCapacity();
    }
    registry.add(&client);

    var reader: c.imsg.imsgbuf = undefined;
    try std.testing.expectEqual(@as(i32, 0), c.imsg.imsgbuf_init(&reader, pair[1]));
    defer {
        c.imsg.imsgbuf_clear(&reader);
        std.posix.close(pair[1]);
    }

    notify_window("window-layout-changed", window);

    try std.testing.expectEqual(@as(i32, 1), c.imsg.imsgbuf_read(&reader));

    var imsg_msg: c.imsg.imsg = undefined;
    try std.testing.expect(c.imsg.imsg_get(&reader, &imsg_msg) > 0);
    defer c.imsg.imsg_free(&imsg_msg);

    try std.testing.expectEqual(@as(u32, @intCast(@intFromEnum(protocol.MsgType.write))), c.imsg.imsg_get_type(&imsg_msg));
    const payload_len = c.imsg.imsg_get_len(&imsg_msg);
    var payload = try xm.allocator.alloc(u8, payload_len);
    defer xm.allocator.free(payload);
    try std.testing.expectEqual(@as(i32, 0), c.imsg.imsg_get_data(&imsg_msg, payload.ptr, payload.len));

    var stream: i32 = 0;
    @memcpy(std.mem.asBytes(&stream), payload[0..@sizeOf(i32)]);
    try std.testing.expectEqual(@as(i32, 1), stream);

    const expected = xm.xasprintf("%layout-change @{d} {s} {s} *\n", .{ window.id, dumped, dumped });
    defer xm.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, payload[@sizeOf(i32)..]);
}

test "session_set_current emits %session-window-changed to control clients" {
    const c = @import("c.zig");
    const env_mod = @import("environ.zig");
    const proc_mod = @import("proc.zig");
    const protocol = @import("zmux-protocol.zig");
    const win = @import("window.zig");
    const registry = @import("client-registry.zig");

    const helpers = struct {
        fn noopDispatch(_: ?*c.imsg.imsg, _: ?*anyopaque) callconv(.c) void {}
    };

    cmdq.cmdq_reset_for_tests();
    defer cmdq.cmdq_reset_for_tests();
    registry.clients.clearRetainingCapacity();
    defer registry.clients.clearRetainingCapacity();

    sess.session_init_globals(xm.allocator);
    win.window_init_globals(xm.allocator);

    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);

    env_mod.global_environ = env_mod.environ_create();
    defer env_mod.environ_free(env_mod.global_environ);

    const session = sess.session_create(null, "notify-session-window-control", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("notify-session-window-control") != null) sess.session_destroy(session, false, "test");

    const first = win.window_create(80, 24, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    const first_pane = win.window_add_pane(first, null, 80, 24);
    first.active = first_pane;

    const second = win.window_create(80, 24, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    const second_pane = win.window_add_pane(second, null, 80, 24);
    second.active = second_pane;

    var cause: ?[]u8 = null;
    const first_wl = sess.session_attach(session, first, -1, &cause).?;
    const second_wl = sess.session_attach(session, second, -1, &cause).?;
    session.curw = first_wl;
    while (cmdq.cmdq_next(null) != 0) {}

    var pair: [2]i32 = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &pair));

    var proc = T.ZmuxProc{ .name = "notify-session-window-control-test" };
    defer proc.peers.deinit(xm.allocator);

    var client = T.Client{
        .name = "session-window-client",
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{ .screen = undefined },
        .session = session,
        .flags = T.CLIENT_CONTROL | T.CLIENT_UTF8,
    };
    defer env_mod.environ_free(client.environ);
    client.tty = .{ .client = &client };
    client.peer = proc_mod.proc_add_peer(&proc, pair[0], helpers.noopDispatch, null);
    defer {
        registry.remove(&client);
        const peer = client.peer.?;
        c.imsg.imsgbuf_clear(&peer.ibuf);
        std.posix.close(peer.ibuf.fd);
        xm.allocator.destroy(peer);
        proc.peers.clearRetainingCapacity();
    }
    registry.add(&client);

    var reader: c.imsg.imsgbuf = undefined;
    try std.testing.expectEqual(@as(i32, 0), c.imsg.imsgbuf_init(&reader, pair[1]));
    defer {
        c.imsg.imsgbuf_clear(&reader);
        std.posix.close(pair[1]);
    }

    try std.testing.expect(sess.session_set_current(session, second_wl));
    try std.testing.expectEqual(second_wl, session.curw.?);

    try std.testing.expectEqual(@as(i32, 1), c.imsg.imsgbuf_read(&reader));

    var imsg_msg: c.imsg.imsg = undefined;
    try std.testing.expect(c.imsg.imsg_get(&reader, &imsg_msg) > 0);
    defer c.imsg.imsg_free(&imsg_msg);

    try std.testing.expectEqual(@as(u32, @intCast(@intFromEnum(protocol.MsgType.write))), c.imsg.imsg_get_type(&imsg_msg));
    const payload_len = c.imsg.imsg_get_len(&imsg_msg);
    var payload = try xm.allocator.alloc(u8, payload_len);
    defer xm.allocator.free(payload);
    try std.testing.expectEqual(@as(i32, 0), c.imsg.imsg_get_data(&imsg_msg, payload.ptr, payload.len));

    var stream: i32 = 0;
    @memcpy(std.mem.asBytes(&stream), payload[0..@sizeOf(i32)]);
    try std.testing.expectEqual(@as(i32, 1), stream);

    const expected = xm.xasprintf("%session-window-changed ${d} @{d}\n", .{ session.id, second.id });
    defer xm.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, payload[@sizeOf(i32)..]);
}
