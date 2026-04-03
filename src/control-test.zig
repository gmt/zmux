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

//! control-test.zig – tests for control.zig and control-subscriptions.zig.

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const env_mod = @import("environ.zig");
const ctl = @import("control.zig");
const ctl_sub = @import("control-subscriptions.zig");

test "control_pane_cmp and subscription comparators use stable ordering" {
    const pa = T.ControlPane{ .pane = 10 };
    const pb = T.ControlPane{ .pane = 20 };
    try std.testing.expectEqual(@as(i32, -1), ctl.control_pane_cmp(&pa, &pb));
    try std.testing.expectEqual(@as(i32, 1), ctl.control_pane_cmp(&pb, &pa));
    try std.testing.expectEqual(@as(i32, 0), ctl.control_pane_cmp(&pa, &pa));

    const spa = T.ControlSubscriptionPane{ .pane = 1, .idx = 2 };
    const spb = T.ControlSubscriptionPane{ .pane = 2, .idx = 0 };
    try std.testing.expectEqual(@as(i32, -1), ctl.control_sub_pane_cmp(&spa, &spb));

    const swa = T.ControlSubscriptionWindow{ .window = 3, .idx = -1 };
    const swb = T.ControlSubscriptionWindow{ .window = 4, .idx = -1 };
    try std.testing.expectEqual(@as(i32, -1), ctl.control_sub_window_cmp(&swa, &swb));

    var sa: T.ControlSubscription = .{
        .name = try xm.allocator.dupe(u8, "alpha"),
        .format = try xm.allocator.dupe(u8, "#{pane_id}"),
        .sub_type = .pane,
    };
    defer sa.deinit(xm.allocator);
    var sz: T.ControlSubscription = .{
        .name = try xm.allocator.dupe(u8, "zebra"),
        .format = try xm.allocator.dupe(u8, "#{window_id}"),
        .sub_type = .window,
    };
    defer sz.deinit(xm.allocator);

    try std.testing.expectEqual(@as(i32, -1), ctl.control_sub_cmp(&sa, &sz));
    try std.testing.expectEqual(@as(i32, 0), ctl.control_sub_cmp(&sa, &sa));
}

test "control_subscriptions replace same name and remove clears the list" {
    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);

    var cl: T.Client = undefined;
    cl = .{
        .environ = env,
        .tty = undefined,
        .status = .{},
    };
    cl.tty = .{ .client = &cl };

    ctl_sub.control_add_sub(&cl, "hook", T.ControlSubType.session, 7, "#{session_name}");
    try std.testing.expectEqual(@as(usize, 1), cl.control_subscriptions.items.len);
    try std.testing.expectEqualStrings("hook", cl.control_subscriptions.items[0].name);
    try std.testing.expectEqual(T.ControlSubType.session, cl.control_subscriptions.items[0].sub_type);
    try std.testing.expectEqual(@as(u32, 7), cl.control_subscriptions.items[0].id);

    ctl_sub.control_add_sub(&cl, "hook", T.ControlSubType.all_panes, 0, "#{pane_id}");
    try std.testing.expectEqual(@as(usize, 1), cl.control_subscriptions.items.len);
    try std.testing.expectEqual(T.ControlSubType.all_panes, cl.control_subscriptions.items[0].sub_type);

    ctl_sub.control_remove_sub(&cl, "hook");
    try std.testing.expectEqual(@as(usize, 0), cl.control_subscriptions.items.len);

    ctl_sub.control_subscriptions_deinit(&cl);
}

test "control_notify_session_created ignores session pointer and tolerates empty registry" {
    const cn = @import("control-notify.zig");
    const registry = @import("client-registry.zig");

    registry.clients.clearRetainingCapacity();
    defer registry.clients.clearRetainingCapacity();

    var dummy: T.Session = undefined;
    cn.control_notify_session_created(&dummy);
    try std.testing.expectEqual(@as(usize, 0), registry.clients.items.len);
}

test "control_notify_client_detached tolerates empty registry" {
    const cn = @import("control-notify.zig");
    const registry = @import("client-registry.zig");

    registry.clients.clearRetainingCapacity();
    defer registry.clients.clearRetainingCapacity();

    var dummy: T.Client = undefined;
    cn.control_notify_client_detached(&dummy);
    try std.testing.expectEqual(@as(usize, 0), registry.clients.items.len);
}

test "control subscriptions keep multiple distinct hooks ordered by insertion" {
    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);

    var cl: T.Client = undefined;
    cl = .{
        .environ = env,
        .tty = undefined,
        .status = .{},
    };
    cl.tty = .{ .client = &cl };

    ctl.control_add_sub(&cl, "a", T.ControlSubType.session, 0, "#{session_id}");
    ctl.control_add_sub(&cl, "b", T.ControlSubType.window, 3, "#{window_id}");
    try std.testing.expectEqual(@as(usize, 2), cl.control_subscriptions.items.len);
    try std.testing.expectEqualStrings("a", cl.control_subscriptions.items[0].name);
    try std.testing.expectEqualStrings("b", cl.control_subscriptions.items[1].name);
    try std.testing.expectEqual(T.ControlSubType.window, cl.control_subscriptions.items[1].sub_type);
    try std.testing.expectEqual(@as(u32, 3), cl.control_subscriptions.items[1].id);

    ctl_sub.control_subscriptions_deinit(&cl);
}

test "control_check_subscriptions no-ops without an attached session" {
    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);

    var cl: T.Client = undefined;
    cl = .{
        .environ = env,
        .tty = undefined,
        .status = .{},
        .session = null,
    };
    cl.tty = .{ .client = &cl };

    ctl.control_add_sub(&cl, "hook", T.ControlSubType.session, 0, "#{session_name}");
    ctl_sub.control_check_subscriptions(&cl);
    try std.testing.expectEqual(@as(usize, 1), cl.control_subscriptions.items.len);

    ctl_sub.control_subscriptions_deinit(&cl);
}

test "control_free_sub removes the targeted subscription pointer" {
    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);

    var cl: T.Client = undefined;
    cl = .{
        .environ = env,
        .tty = undefined,
        .status = .{},
    };
    cl.tty = .{ .client = &cl };

    ctl.control_add_sub(&cl, "first", T.ControlSubType.session, 0, "fmt1");
    ctl.control_add_sub(&cl, "second", T.ControlSubType.session, 0, "fmt2");
    const ptr = &cl.control_subscriptions.items[1];
    ctl.control_free_sub(&cl, ptr);
    try std.testing.expectEqual(@as(usize, 1), cl.control_subscriptions.items.len);
    try std.testing.expectEqualStrings("first", cl.control_subscriptions.items[0].name);

    ctl_sub.control_subscriptions_deinit(&cl);
}

test "control_start control_stop and control_all_done manage block queues" {
    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);

    var cl: T.Client = undefined;
    cl = .{
        .environ = env,
        .tty = undefined,
        .status = .{},
        .peer = null,
        .control_all_blocks = .{},
        .control_panes = .{},
    };
    cl.tty = .{ .client = &cl };

    ctl.control_start(&cl);
    try std.testing.expect(ctl.control_all_done(&cl));
    // control_stop deinits control_all_blocks without re-init; all_done is only valid while started.
    ctl.control_stop(&cl);
}

test "control_window_pane returns null without session" {
    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);

    var cl: T.Client = undefined;
    cl = .{
        .environ = env,
        .tty = undefined,
        .status = .{},
        .session = null,
    };
    cl.tty = .{ .client = &cl };

    try std.testing.expect(ctl.control_window_pane(&cl, 999) == null);
}

test "control_discard on empty client is safe" {
    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);

    var cl: T.Client = undefined;
    cl = .{
        .environ = env,
        .tty = undefined,
        .status = .{},
    };
    cl.tty = .{ .client = &cl };

    ctl.control_discard(&cl);
}

test "control_check_subs_session returns early when session is null" {
    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);

    var cl: T.Client = undefined;
    cl = .{
        .environ = env,
        .tty = undefined,
        .status = .{},
        .session = null,
    };
    cl.tty = .{ .client = &cl };

    var sub: T.ControlSubscription = .{
        .name = try xm.allocator.dupe(u8, "x"),
        .format = try xm.allocator.dupe(u8, "y"),
        .sub_type = .session,
    };
    defer sub.deinit(xm.allocator);

    ctl.control_check_subs_session(&cl, &sub);
}

test "control_error_callback flags client exit" {
    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);

    var cl: T.Client = undefined;
    cl = .{
        .environ = env,
        .tty = undefined,
        .status = .{},
        .flags = 0,
    };
    cl.tty = .{ .client = &cl };

    ctl.control_error_callback(&cl);
    try std.testing.expect((cl.flags & T.CLIENT_EXIT) != 0);
}
