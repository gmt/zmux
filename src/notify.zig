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
const win_mod = @import("window.zig");
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
    client: ?*T.Client = null,
    session: ?*T.Session = null,
    window: ?*T.Window = null,
    pane: ?*T.WindowPane = null,
    pbname: ?[]u8 = null,

    fn deinit(self: *NotifyEntry) void {
        freeOwned(&self.pbname);
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

fn hookOptionContext(name: []const u8, fs: *const T.CmdFindState) ?struct { oo: *T.Options, value: *const T.OptionsValue } {
    const session_options = if (fs.s) |s| s.options else opts.global_s_options;
    if (opts.options_get(session_options, name)) |value|
        return .{ .oo = session_options, .value = value };
    if (fs.wp) |wp| {
        if (opts.options_get(wp.options, name)) |value|
            return .{ .oo = wp.options, .value = value };
    }
    if (fs.wl) |wl| {
        if (opts.options_get(wl.window.options, name)) |value|
            return .{ .oo = wl.window.options, .value = value };
    }
    return null;
}

/// Insert a parsed hook command list after `after` (or onto the server queue if `after` is null).
/// Mirrors tmux `notify_insert_one_hook`.
fn notify_insert_one_hook(
    after: ?*cmdq.CmdqItem,
    ne: *const NotifyEntry,
    cmdlist: *T.CmdList,
    state: *cmdq.CmdqState,
) ?*cmdq.CmdqItem {
    if (log.log_get_level() != 0)
        log.log_debug("notify_insert_one_hook: hook {s}", .{ne.hook_info.hook orelse "?"});

    const new_first = cmdq.cmdq_get_command(cmdlist, state);
    if (after) |item|
        return cmdq.cmdq_insert_after(item, new_first);
    return cmdq.cmdq_append_item(null, new_first);
}

/// Resolve hook option, parse hook bodies, and enqueue commands. Mirrors tmux `notify_insert_hook`.
fn notify_insert_hook(after: ?*cmdq.CmdqItem, ne: *const NotifyEntry) void {
    const hook_name = ne.hook_info.hook orelse return;
    log.log_debug("notify_insert_hook: inserting hook {s}", .{hook_name});

    var fs: T.CmdFindState = .{ .idx = -1 };
    if (cmd_find.cmd_find_valid_state(&ne.fs))
        fs = ne.fs
    else
        _ = cmd_find.cmd_find_from_nothing(&fs, 0);

    const ctx = hookOptionContext(hook_name, &fs) orelse {
        log.log_debug("notify_insert_hook: hook {s} not found", .{hook_name});
        return;
    };

    const state = cmdq.cmdq_new_state(if (cmd_find.cmd_find_valid_state(&fs)) &fs else null, null, T.CMDQ_STATE_NOHOOKS);
    defer cmdq.cmdq_free_state(state);
    cmdq.cmdq_set_hook_info(state, ne.hook_info.borrow());

    var tail: ?*cmdq.CmdqItem = after;

    if (hook_name.len != 0 and hook_name[0] == '@') {
        const value = opts.options_get_string(ctx.oo, hook_name);
        var pi: T.CmdParseInput = .{};
        const pr = cmd_mod.cmd_parse_from_string(value, &pi);
        switch (pr.status) {
            .success => {
                if (pr.cmdlist) |raw| {
                    const cmdlist: *T.CmdList = @ptrCast(@alignCast(raw));
                    tail = notify_insert_one_hook(tail, ne, cmdlist, state);
                }
            },
            .@"error" => {
                if (pr.@"error") |err| {
                    log.log_debug("notify_insert_hook: cannot parse hook {s}: {s}", .{ hook_name, err });
                    xm.allocator.free(err);
                }
            },
        }
        return;
    }

    switch (ctx.value.*) {
        .array => |arr| {
            for (arr.items) |entry| {
                var pi: T.CmdParseInput = .{};
                const pr = cmd_mod.cmd_parse_from_string(entry.value, &pi);
                switch (pr.status) {
                    .success => {
                        if (pr.cmdlist) |raw| {
                            const cmdlist: *T.CmdList = @ptrCast(@alignCast(raw));
                            tail = notify_insert_one_hook(tail, ne, cmdlist, state);
                        }
                    },
                    .@"error" => {
                        if (pr.@"error") |err| {
                            log.log_debug("notify_insert_hook: cannot parse hook {s}: {s}", .{ hook_name, err });
                            xm.allocator.free(err);
                        }
                    },
                }
            }
        },
        else => {},
    }
}

fn dispatchControlNotifications(entry: *const NotifyEntry) void {
    const name = entry.hook_info.hook orelse return;
    if (std.mem.eql(u8, name, "pane-mode-changed")) {
        if (entry.pane) |wp| control_notify.control_notify_pane_mode_changed(wp);
    } else if (std.mem.eql(u8, name, "window-layout-changed")) {
        if (entry.window) |w| control_notify.control_notify_window_layout_changed(w);
    } else if (std.mem.eql(u8, name, "window-pane-changed")) {
        if (entry.window) |w| control_notify.control_notify_window_pane_changed(w);
    } else if (std.mem.eql(u8, name, "window-unlinked")) {
        if (entry.session) |s| if (entry.window) |w|
            control_notify.control_notify_window_unlinked(s, w);
    } else if (std.mem.eql(u8, name, "window-linked")) {
        if (entry.session) |s| if (entry.window) |w|
            control_notify.control_notify_window_linked(s, w);
    } else if (std.mem.eql(u8, name, "window-renamed")) {
        if (entry.window) |w| control_notify.control_notify_window_renamed(w);
    } else if (std.mem.eql(u8, name, "client-session-changed")) {
        if (entry.client) |cl| control_notify.control_notify_client_session_changed(cl);
    } else if (std.mem.eql(u8, name, "client-detached")) {
        if (entry.client) |cl| control_notify.control_notify_client_detached(cl);
    } else if (std.mem.eql(u8, name, "session-renamed")) {
        if (entry.session) |s| control_notify.control_notify_session_renamed(s);
    } else if (std.mem.eql(u8, name, "session-created")) {
        if (entry.session) |s| control_notify.control_notify_session_created(s);
    } else if (std.mem.eql(u8, name, "session-closed")) {
        if (entry.session) |s| control_notify.control_notify_session_closed(s);
    } else if (std.mem.eql(u8, name, "session-window-changed")) {
        if (entry.session) |s| control_notify.control_notify_session_window_changed(s);
    } else if (std.mem.eql(u8, name, "paste-buffer-changed")) {
        if (entry.pbname) |pb| control_notify.control_notify_paste_buffer_changed(pb);
    } else if (std.mem.eql(u8, name, "paste-buffer-deleted")) {
        if (entry.pbname) |pb| control_notify.control_notify_paste_buffer_deleted(pb);
    }
}

/// Release a NotifyEntry and its associated session/window references.
/// Used both by the normal callback path and by the free_data hook when
/// the queue item is destroyed without being fired.
fn freeNotifyEntry(entry: *NotifyEntry) void {
    if (entry.session) |s| sess.session_remove_ref(s, "notify_callback");
    if (entry.window) |w| win_mod.window_remove_ref(w, "notify_callback");
    if (entry.fs.s) |s| sess.session_remove_ref(s, "notify_callback");
    entry.deinit();
    xm.allocator.destroy(entry);
}

/// free_data hook passed to cmdq_get_callback2 so that NotifyEntry is
/// released even when the queue item is destroyed without being fired.
fn freeNotifyData(data: ?*anyopaque) void {
    const entry: *NotifyEntry = @ptrCast(@alignCast(data orelse return));
    freeNotifyEntry(entry);
}

fn notifyCallback(item: *cmdq.CmdqItem, data: ?*anyopaque) T.CmdRetval {
    const entry: *NotifyEntry = @ptrCast(@alignCast(data orelse return .normal));
    defer freeNotifyEntry(entry);

    dispatchControlNotifications(entry);
    notify_insert_hook(item, entry);
    return .normal;
}

/// Core notification dispatcher: queues a callback that runs control-mode output and hook commands
/// (mirrors tmux `notify_add`).
pub fn notify_add(
    name: []const u8,
    fs: *const T.CmdFindState,
    client: ?*T.Client,
    session: ?*T.Session,
    window: ?*T.Window,
    pane: ?*T.WindowPane,
    pbname: ?[]const u8,
) void {
    if (notificationsSuppressed()) return;

    const entry = xm.allocator.create(NotifyEntry) catch unreachable;
    entry.* = .{
        .fs = fs.*,
        .hook_info = OwnedHookInfo.fromEvent(name, client, session, window, pane),
        .client = client,
        .session = session,
        .window = window,
        .pane = pane,
        .pbname = if (pbname) |p| xm.xstrdup(p) else null,
    };

    if (session) |s| sess.session_add_ref(s, "notify_add");
    if (window) |w| win_mod.window_add_ref(w, "notify_add");
    if (entry.fs.s) |s| sess.session_add_ref(s, "notify_add");

    _ = cmdq.cmdq_append_item(null, cmdq.cmdq_get_callback2("notify", notifyCallback, entry, freeNotifyData));
}

pub fn notify_hook(item: *cmdq.CmdqItem, name: []const u8, current: ?*const T.CmdFindState) void {
    var ne: NotifyEntry = .{
        .hook_info = OwnedHookInfo.fromName(name),
        .fs = blk: {
            var fs: T.CmdFindState = .{ .idx = -1 };
            if (current) |state| fs = state.*;
            break :blk fs;
        },
    };
    defer ne.deinit();

    if (item.queue != null) {
        notify_insert_hook(item, &ne);
        return;
    }
    notify_insert_hook(null, &ne);
    _ = cmdq.cmdq_next(null);
}

pub fn notify_client(name: []const u8, cl: *T.Client) void {
    var fs: T.CmdFindState = .{ .idx = -1 };
    if (!cmd_find.cmd_find_from_client(&fs, cl, 0))
        _ = cmd_find.cmd_find_from_nothing(&fs, 0);
    notify_add(name, &fs, cl, null, null, null, null);
}

pub fn notify_session(name: []const u8, s: *T.Session) void {
    var fs: T.CmdFindState = .{ .idx = -1 };
    if (sess.session_alive(s))
        cmd_find.cmd_find_from_session(&fs, s, 0)
    else
        _ = cmd_find.cmd_find_from_nothing(&fs, 0);
    notify_add(name, &fs, null, s, null, null, null);
}

pub fn notify_winlink(name: []const u8, wl: *T.Winlink) void {
    var fs: T.CmdFindState = .{ .idx = -1 };
    if (!cmd_find.cmd_find_from_winlink(&fs, wl, 0))
        _ = cmd_find.cmd_find_from_nothing(&fs, 0);
    notify_add(name, &fs, null, wl.session, wl.window, null, null);
}

pub fn notify_session_window(name: []const u8, s: *T.Session, w: *T.Window) void {
    var fs: T.CmdFindState = .{ .idx = -1 };
    if (!cmd_find.cmd_find_from_session_window(&fs, s, w, 0))
        _ = cmd_find.cmd_find_from_nothing(&fs, 0);
    notify_add(name, &fs, null, s, w, null, null);
}

pub fn notify_window(name: []const u8, w: *T.Window) void {
    var fs: T.CmdFindState = .{ .idx = -1 };
    if (!cmd_find.cmd_find_from_window(&fs, w, 0))
        _ = cmd_find.cmd_find_from_nothing(&fs, 0);
    notify_add(name, &fs, null, null, w, null, null);
}

pub fn notify_pane(name: []const u8, wp: *T.WindowPane) void {
    var fs: T.CmdFindState = .{ .idx = -1 };
    if (!cmd_find.cmd_find_from_pane(&fs, wp, 0))
        _ = cmd_find.cmd_find_from_nothing(&fs, 0);
    notify_add(name, &fs, null, null, wp.window, wp, null);
}

pub fn notify_paste_buffer(pbname: []const u8, deleted: bool) void {
    const name = if (deleted) "paste-buffer-deleted" else "paste-buffer-changed";
    var fs: T.CmdFindState = .{ .idx = -1 };
    notify_add(name, &fs, null, null, null, null, pbname);
}

test "notify_window queues hook commands with window metadata" {
    const env_mod = @import("environ.zig");
    cmdq.cmdq_reset_for_tests();
    defer cmdq.cmdq_reset_for_tests();

    sess.session_init_globals(xm.allocator);
    win_mod.window_init_globals(xm.allocator);

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
    const window = win_mod.window_create(80, 24, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    xm.allocator.free(window.name);
    window.name = xm.xstrdup("hooked-window");
    const pane = win_mod.window_add_pane(window, null, 80, 24);
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
    win_mod.window_init_globals(xm.allocator);

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
    const window = win_mod.window_create(80, 24, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    xm.allocator.free(window.name);
    window.name = xm.xstrdup("ordered-window");
    const pane = win_mod.window_add_pane(window, null, 80, 24);
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
    const registry = @import("client-registry.zig");

    const helpers = struct {
        fn noopDispatch(_: ?*c.imsg.imsg, _: ?*anyopaque) callconv(.c) void {}
    };

    cmdq.cmdq_reset_for_tests();
    defer cmdq.cmdq_reset_for_tests();

    sess.session_init_globals(xm.allocator);
    win_mod.window_init_globals(xm.allocator);

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
    const window = win_mod.window_create(80, 24, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    const pane = win_mod.window_add_pane(window, null, 80, 24);
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
    while (cmdq.cmdq_next(null) != 0) {}

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
    const registry = @import("client-registry.zig");

    const helpers = struct {
        fn noopDispatch(_: ?*c.imsg.imsg, _: ?*anyopaque) callconv(.c) void {}
    };

    cmdq.cmdq_reset_for_tests();
    defer cmdq.cmdq_reset_for_tests();
    registry.clients.clearRetainingCapacity();
    defer registry.clients.clearRetainingCapacity();

    sess.session_init_globals(xm.allocator);
    win_mod.window_init_globals(xm.allocator);

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

    const first = win_mod.window_create(80, 24, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    const first_pane = win_mod.window_add_pane(first, null, 80, 24);
    first.active = first_pane;

    const second = win_mod.window_create(80, 24, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    const second_pane = win_mod.window_add_pane(second, null, 80, 24);
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
    while (cmdq.cmdq_next(null) != 0) {}

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
