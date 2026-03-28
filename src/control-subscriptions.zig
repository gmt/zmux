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
// Ported in part from tmux/control.c.
// Original copyright:
//   Copyright (c) 2015 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

//! control-subscriptions.zig – reduced control-client format subscriptions.

const std = @import("std");
const T = @import("types.zig");
const c = @import("c.zig");
const format_mod = @import("format.zig");
const proc_mod = @import("proc.zig");
const server_print = @import("server-print.zig");
const window_mod = @import("window.zig");
const xm = @import("xmalloc.zig");

pub fn control_add_sub(client: *T.Client, name: []const u8, sub_type: T.ControlSubType, id: u32, format: []const u8) void {
    if (find_subscription_index(client, name)) |idx|
        remove_subscription_by_index(client, idx);

    client.control_subscriptions.append(xm.allocator, .{
        .name = xm.xstrdup(name),
        .format = xm.xstrdup(format),
        .sub_type = sub_type,
        .id = id,
    }) catch unreachable;
    arm_subscriptions_timer(client);
}

pub fn control_remove_sub(client: *T.Client, name: []const u8) void {
    if (find_subscription_index(client, name)) |idx|
        remove_subscription_by_index(client, idx);

    if (client.control_subscriptions.items.len == 0)
        cancel_subscriptions_timer(client);
}

pub fn control_check_subscriptions(client: *T.Client) void {
    const session = client.session orelse return;

    for (client.control_subscriptions.items) |*sub| {
        switch (sub.sub_type) {
            .session => check_session_subscription(client, session, sub),
            .pane => check_pane_subscription(client, session, sub),
            .all_panes => check_all_panes_subscription(client, session, sub),
            .window => check_window_subscription(client, session, sub),
            .all_windows => check_all_windows_subscription(client, session, sub),
        }
    }
}

pub fn control_subscriptions_deinit(client: *T.Client) void {
    cancel_subscriptions_timer(client);
    if (client.control_subs_timer) |ev| {
        c.libevent.event_free(ev);
        client.control_subs_timer = null;
    }

    for (client.control_subscriptions.items) |*sub| sub.deinit(xm.allocator);
    client.control_subscriptions.deinit(xm.allocator);
    client.control_subscriptions = .{};
}

export fn control_subscriptions_timer_cb(_fd: c_int, _events: c_short, arg: ?*anyopaque) void {
    _ = _fd;
    _ = _events;
    const client: *T.Client = @ptrCast(@alignCast(arg orelse return));

    if (client.control_subscriptions.items.len == 0) return;

    arm_subscriptions_timer(client);
    control_check_subscriptions(client);
}

fn arm_subscriptions_timer(client: *T.Client) void {
    if (client.control_subscriptions.items.len == 0) return;

    if (client.control_subs_timer == null) {
        const base = proc_mod.libevent orelse return;
        client.control_subs_timer = c.libevent.event_new(
            base,
            -1,
            @intCast(c.libevent.EV_TIMEOUT),
            control_subscriptions_timer_cb,
            client,
        );
    }

    if (client.control_subs_timer) |ev| {
        _ = c.libevent.event_del(ev);
        var tv = std.posix.timeval{ .sec = 1, .usec = 0 };
        _ = c.libevent.event_add(ev, @ptrCast(&tv));
    }
}

fn cancel_subscriptions_timer(client: *T.Client) void {
    if (client.control_subs_timer) |ev|
        _ = c.libevent.event_del(ev);
}

fn find_subscription_index(client: *const T.Client, name: []const u8) ?usize {
    for (client.control_subscriptions.items, 0..) |sub, idx| {
        if (std.mem.eql(u8, sub.name, name)) return idx;
    }
    return null;
}

fn remove_subscription_by_index(client: *T.Client, idx: usize) void {
    var sub = client.control_subscriptions.orderedRemove(idx);
    sub.deinit(xm.allocator);
}

fn check_session_subscription(client: *T.Client, session: *T.Session, sub: *T.ControlSubscription) void {
    const value = subscription_format_value(client, session, null, null, sub.format);
    if (!replace_value_if_changed(&sub.last, value)) return;
    write_session_subscription(client, sub.name, session.id, sub.last.?);
}

fn check_pane_subscription(client: *T.Client, session: *T.Session, sub: *T.ControlSubscription) void {
    const pane = window_mod.window_pane_find_by_id(sub.id) orelse return;
    if (pane.fd == -1) return;

    const window = pane.window;
    for (window.winlinks.items) |wl| {
        if (wl.session != session) continue;

        const value = subscription_format_value(client, session, wl, pane, sub.format);
        const pane_state = get_or_create_pane_state(sub, pane.id, wl.idx);
        if (!replace_value_if_changed(&pane_state.last, value)) continue;
        write_pane_subscription(client, sub.name, session.id, window.id, wl.idx, pane.id, pane_state.last.?);
    }
}

fn check_all_panes_subscription(client: *T.Client, session: *T.Session, sub: *T.ControlSubscription) void {
    var it = session.windows.valueIterator();
    while (it.next()) |wl_ptr| {
        const wl = wl_ptr.*;
        for (wl.window.panes.items) |pane| {
            const value = subscription_format_value(client, session, wl, pane, sub.format);
            const pane_state = get_or_create_pane_state(sub, pane.id, wl.idx);
            if (!replace_value_if_changed(&pane_state.last, value)) continue;
            write_pane_subscription(client, sub.name, session.id, wl.window.id, wl.idx, pane.id, pane_state.last.?);
        }
    }
}

fn check_window_subscription(client: *T.Client, session: *T.Session, sub: *T.ControlSubscription) void {
    const window = window_mod.window_find_by_id(sub.id) orelse return;

    for (window.winlinks.items) |wl| {
        if (wl.session != session) continue;

        const value = subscription_format_value(client, session, wl, null, sub.format);
        const window_state = get_or_create_window_state(sub, window.id, wl.idx);
        if (!replace_value_if_changed(&window_state.last, value)) continue;
        write_window_subscription(client, sub.name, session.id, window.id, wl.idx, window_state.last.?);
    }
}

fn check_all_windows_subscription(client: *T.Client, session: *T.Session, sub: *T.ControlSubscription) void {
    var it = session.windows.valueIterator();
    while (it.next()) |wl_ptr| {
        const wl = wl_ptr.*;
        const value = subscription_format_value(client, session, wl, null, sub.format);
        const window_state = get_or_create_window_state(sub, wl.window.id, wl.idx);
        if (!replace_value_if_changed(&window_state.last, value)) continue;
        write_window_subscription(client, sub.name, session.id, wl.window.id, wl.idx, window_state.last.?);
    }
}

fn subscription_format_value(
    client: *T.Client,
    session: *T.Session,
    wl: ?*T.Winlink,
    pane: ?*T.WindowPane,
    template: []const u8,
) []u8 {
    const window = if (wl) |winlink| winlink.window else if (pane) |wp| wp.window else null;
    const ctx = format_mod.FormatContext{
        .client = client,
        .session = session,
        .winlink = wl,
        .window = window,
        .pane = pane,
    };
    return format_mod.format_expand(xm.allocator, template, &ctx).text;
}

fn replace_value_if_changed(slot: *?[]u8, next: []u8) bool {
    if (slot.*) |previous| {
        if (std.mem.eql(u8, previous, next)) {
            xm.allocator.free(next);
            return false;
        }
        xm.allocator.free(previous);
    }
    slot.* = next;
    return true;
}

fn get_or_create_pane_state(sub: *T.ControlSubscription, pane_id: u32, idx: i32) *T.ControlSubscriptionPane {
    for (sub.panes.items) |*pane_state| {
        if (pane_state.pane == pane_id and pane_state.idx == idx) return pane_state;
    }
    sub.panes.append(xm.allocator, .{ .pane = pane_id, .idx = idx }) catch unreachable;
    return &sub.panes.items[sub.panes.items.len - 1];
}

fn get_or_create_window_state(sub: *T.ControlSubscription, window_id: u32, idx: i32) *T.ControlSubscriptionWindow {
    for (sub.windows.items) |*window_state| {
        if (window_state.window == window_id and window_state.idx == idx) return window_state;
    }
    sub.windows.append(xm.allocator, .{ .window = window_id, .idx = idx }) catch unreachable;
    return &sub.windows.items[sub.windows.items.len - 1];
}

fn write_session_subscription(client: *T.Client, name: []const u8, session_id: u32, value: []const u8) void {
    const line = xm.xasprintf("%subscription-changed {s} ${d} - - - : {s}\n", .{ name, session_id, value });
    defer xm.allocator.free(line);
    server_print.server_client_write_stream(client, 1, line);
}

fn write_pane_subscription(
    client: *T.Client,
    name: []const u8,
    session_id: u32,
    window_id: u32,
    idx: i32,
    pane_id: u32,
    value: []const u8,
) void {
    const line = xm.xasprintf(
        "%subscription-changed {s} ${d} @{d} {d} %{d} : {s}\n",
        .{ name, session_id, window_id, idx, pane_id, value },
    );
    defer xm.allocator.free(line);
    server_print.server_client_write_stream(client, 1, line);
}

fn write_window_subscription(
    client: *T.Client,
    name: []const u8,
    session_id: u32,
    window_id: u32,
    idx: i32,
    value: []const u8,
) void {
    const line = xm.xasprintf("%subscription-changed {s} ${d} @{d} {d} - : {s}\n", .{ name, session_id, window_id, idx, value });
    defer xm.allocator.free(line);
    server_print.server_client_write_stream(client, 1, line);
}
