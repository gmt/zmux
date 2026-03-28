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
// Ported from tmux/cmd-wait-for.c
// Original copyright:
//   Copyright (c) 2013 Nicholas Marriott <nicholas.marriott@gmail.com>
//   Copyright (c) 2013 Thiago de Arruda <tpadilha84@gmail.com>
//   ISC licence - same terms as above.

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const log = @import("log.zig");
const cmd_mod = @import("cmd.zig");
const cmdq = @import("cmd-queue.zig");

const WaitChannel = struct {
    name: []const u8,
    locked: bool = false,
    woken: bool = false,
    waiters: std.ArrayListUnmanaged(*cmdq.CmdqItem) = .{},
    lockers: std.ArrayListUnmanaged(*cmdq.CmdqItem) = .{},
};

var wait_channels: std.ArrayListUnmanaged(*WaitChannel) = .{};

fn findWaitChannelIndex(name: []const u8) ?usize {
    for (wait_channels.items, 0..) |wc, idx| {
        if (std.mem.eql(u8, wc.name, name)) return idx;
    }
    return null;
}

fn findWaitChannel(name: []const u8) ?*WaitChannel {
    const idx = findWaitChannelIndex(name) orelse return null;
    return wait_channels.items[idx];
}

fn addWaitChannel(name: []const u8) *WaitChannel {
    const wc = xm.allocator.create(WaitChannel) catch unreachable;
    wc.* = .{
        .name = xm.xstrdup(name),
    };
    wait_channels.append(xm.allocator, wc) catch unreachable;
    log.log_debug("add wait channel {s}", .{wc.name});
    return wc;
}

fn removeWaitChannel(wc: *WaitChannel) bool {
    if (wc.locked) return false;
    if (wc.waiters.items.len != 0 or !wc.woken) return false;

    const idx = findWaitChannelIndex(wc.name) orelse return false;
    _ = wait_channels.swapRemove(idx);

    std.debug.assert(wc.lockers.items.len == 0);
    log.log_debug("remove wait channel {s}", .{wc.name});

    wc.waiters.deinit(xm.allocator);
    wc.lockers.deinit(xm.allocator);
    xm.allocator.free(wc.name);
    xm.allocator.destroy(wc);
    return true;
}

fn signalWaitChannel(_: *cmdq.CmdqItem, name: []const u8, existing: ?*WaitChannel) T.CmdRetval {
    const wc = existing orelse addWaitChannel(name);

    if (wc.waiters.items.len == 0 and !wc.woken) {
        log.log_debug("signal wait channel {s}, no waiters", .{wc.name});
        wc.woken = true;
        return .normal;
    }
    log.log_debug("signal wait channel {s}, with waiters", .{wc.name});

    for (wc.waiters.items) |waiter| cmdq.cmdq_continue(waiter);
    wc.waiters.clearRetainingCapacity();

    _ = removeWaitChannel(wc);
    return .normal;
}

fn waitOnChannel(item: *cmdq.CmdqItem, name: []const u8, existing: ?*WaitChannel) T.CmdRetval {
    const client = cmdq.cmdq_get_client(item);
    if (client == null) {
        cmdq.cmdq_error(item, "not able to wait", .{});
        return .@"error";
    }

    const wc = existing orelse addWaitChannel(name);

    if (wc.woken) {
        log.log_debug("wait channel {s} already woken ({*})", .{ wc.name, client.? });
        _ = removeWaitChannel(wc);
        return .normal;
    }
    log.log_debug("wait channel {s} not woken ({*})", .{ wc.name, client.? });

    wc.waiters.append(xm.allocator, item) catch unreachable;
    return .wait;
}

fn lockChannel(item: *cmdq.CmdqItem, name: []const u8, existing: ?*WaitChannel) T.CmdRetval {
    if (cmdq.cmdq_get_client(item) == null) {
        cmdq.cmdq_error(item, "not able to lock", .{});
        return .@"error";
    }

    const wc = existing orelse addWaitChannel(name);
    if (wc.locked) {
        wc.lockers.append(xm.allocator, item) catch unreachable;
        return .wait;
    }

    wc.locked = true;
    return .normal;
}

fn unlockChannel(item: *cmdq.CmdqItem, name: []const u8, existing: ?*WaitChannel) T.CmdRetval {
    const wc = existing orelse {
        cmdq.cmdq_error(item, "channel {s} not locked", .{name});
        return .@"error";
    };
    if (!wc.locked) {
        cmdq.cmdq_error(item, "channel {s} not locked", .{name});
        return .@"error";
    }

    if (wc.lockers.items.len != 0) {
        const locker = wc.lockers.orderedRemove(0);
        cmdq.cmdq_continue(locker);
    } else {
        wc.locked = false;
        _ = removeWaitChannel(wc);
    }
    return .normal;
}

fn exec(self: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {
    const args = cmd_mod.cmd_get_args(self);
    const name = args.value_at(0).?;
    const wc = findWaitChannel(name);

    if (args.has('S')) return signalWaitChannel(item, name, wc);
    if (args.has('L')) return lockChannel(item, name, wc);
    if (args.has('U')) return unlockChannel(item, name, wc);
    return waitOnChannel(item, name, wc);
}

pub fn cmd_wait_for_flush() void {
    var idx: usize = 0;
    while (idx < wait_channels.items.len) {
        const wc = wait_channels.items[idx];

        for (wc.waiters.items) |waiter| cmdq.cmdq_continue(waiter);
        wc.waiters.clearRetainingCapacity();
        wc.woken = true;

        for (wc.lockers.items) |locker| cmdq.cmdq_continue(locker);
        wc.lockers.clearRetainingCapacity();

        wc.locked = false;
        if (!removeWaitChannel(wc)) idx += 1;
    }
}

pub const entry: cmd_mod.CmdEntry = .{
    .name = "wait-for",
    .alias = "wait",
    .usage = "[-L|-S|-U] channel",
    .template = "LSU",
    .lower = 1,
    .upper = 1,
    .flags = 0,
    .exec = exec,
};

fn runDirect(argv: []const []const u8, client: ?*T.Client) !T.CmdRetval {
    var cause: ?[]u8 = null;
    defer if (cause) |msg| xm.allocator.free(msg);

    const args = try cmd_mod.cmd_parse_one(argv, client, &cause);
    defer cmd_mod.cmd_free(args);

    const state = cmdq.cmdq_new_state(null, null, 0);
    defer cmdq.cmdq_free_state(state);

    var item = cmdq.CmdqItem{
        .name = args.entry.name,
        .client = client,
        .state = state,
        .cmd = args,
    };
    return exec(args, &item);
}

const TestClient = struct {
    env: *T.Environ,
    client: T.Client,
};

fn newTestClient() !TestClient {
    const env_mod = @import("environ.zig");
    const env = env_mod.environ_create();
    const client = T.Client{
        .environ = env,
        .tty = undefined,
        .status = .{ .screen = undefined },
    };
    return .{ .env = env, .client = client };
}

fn freeTestClient(bundle: *TestClient) void {
    const env_mod = @import("environ.zig");
    env_mod.environ_free(bundle.env);
}

fn makeCommandList(argv: []const []const u8, client: ?*T.Client) !*cmd_mod.CmdList {
    var cause: ?[]u8 = null;
    defer if (cause) |msg| xm.allocator.free(msg);
    return try cmd_mod.cmd_parse_from_argv_with_cause(argv, client, &cause);
}

test "wait-for signal wake token is consumed by the first waiter" {
    cmdq.cmdq_reset_for_tests();
    defer cmdq.cmdq_reset_for_tests();
    defer cmd_wait_for_flush();

    var test_client = try newTestClient();
    defer freeTestClient(&test_client);
    test_client.client.tty.client = &test_client.client;

    try std.testing.expectEqual(T.CmdRetval.normal, try runDirect(&.{ "wait-for", "-S", "wait-token" }, null));
    try std.testing.expectEqual(T.CmdRetval.normal, try runDirect(&.{ "wait-for", "wait-token" }, &test_client.client));
    try std.testing.expectEqual(@as(usize, 0), wait_channels.items.len);
    try std.testing.expectEqual(T.CmdRetval.wait, try runDirect(&.{ "wait-for", "wait-token" }, &test_client.client));
}

test "wait-for resumes a queued waiter after signal" {
    cmdq.cmdq_reset_for_tests();
    defer cmdq.cmdq_reset_for_tests();
    defer {
        cmd_wait_for_flush();
        while (cmdq.cmdq_next(null) != 0) {}
    }

    var test_client = try newTestClient();
    defer freeTestClient(&test_client);
    test_client.client.tty.client = &test_client.client;

    const callbacks = struct {
        var ran_after: u32 = 0;

        fn after(_: *cmdq.CmdqItem, _: ?*anyopaque) T.CmdRetval {
            ran_after += 1;
            return .normal;
        }
    };

    callbacks.ran_after = 0;

    const list = try makeCommandList(&.{ "wait-for", "queue-signal" }, &test_client.client);
    const waiting = cmdq.cmdq_get_command(@ptrCast(list), null);
    _ = cmdq.cmdq_append_item(&test_client.client, waiting);
    _ = cmdq.cmdq_insert_after(waiting, cmdq.cmdq_get_callback1("wait-after", callbacks.after, null));

    try std.testing.expectEqual(@as(u32, 0), cmdq.cmdq_next(&test_client.client));
    try std.testing.expectEqual(@as(u32, 0), callbacks.ran_after);

    try std.testing.expectEqual(T.CmdRetval.normal, try runDirect(&.{ "wait-for", "-S", "queue-signal" }, null));

    try std.testing.expectEqual(@as(u32, 1), cmdq.cmdq_next(&test_client.client));
    try std.testing.expectEqual(@as(u32, 1), callbacks.ran_after);
}

test "wait-for unlock continues the next locker" {
    cmdq.cmdq_reset_for_tests();
    defer cmdq.cmdq_reset_for_tests();
    defer {
        cmd_wait_for_flush();
        while (cmdq.cmdq_next(null) != 0) {}
    }

    var owner_client = try newTestClient();
    defer freeTestClient(&owner_client);
    owner_client.client.tty.client = &owner_client.client;
    var waiter_client = try newTestClient();
    defer freeTestClient(&waiter_client);
    waiter_client.client.tty.client = &waiter_client.client;

    const callbacks = struct {
        var ran_after: u32 = 0;

        fn after(_: *cmdq.CmdqItem, _: ?*anyopaque) T.CmdRetval {
            ran_after += 1;
            return .normal;
        }
    };

    callbacks.ran_after = 0;

    try std.testing.expectEqual(T.CmdRetval.normal, try runDirect(&.{ "wait-for", "-L", "queue-lock" }, &owner_client.client));

    const list = try makeCommandList(&.{ "wait-for", "-L", "queue-lock" }, &waiter_client.client);
    const waiting = cmdq.cmdq_get_command(@ptrCast(list), null);
    _ = cmdq.cmdq_append_item(&waiter_client.client, waiting);
    _ = cmdq.cmdq_insert_after(waiting, cmdq.cmdq_get_callback1("lock-after", callbacks.after, null));

    try std.testing.expectEqual(@as(u32, 0), cmdq.cmdq_next(&waiter_client.client));
    try std.testing.expectEqual(@as(u32, 0), callbacks.ran_after);

    try std.testing.expectEqual(T.CmdRetval.normal, try runDirect(&.{ "wait-for", "-U", "queue-lock" }, null));

    try std.testing.expectEqual(@as(u32, 1), cmdq.cmdq_next(&waiter_client.client));
    try std.testing.expectEqual(@as(u32, 1), callbacks.ran_after);
    try std.testing.expectEqual(T.CmdRetval.normal, try runDirect(&.{ "wait-for", "-U", "queue-lock" }, null));
    try std.testing.expectEqual(@as(usize, 1), wait_channels.items.len);
}

test "wait-for flush resumes queued waiters and lockers" {
    cmdq.cmdq_reset_for_tests();
    defer cmdq.cmdq_reset_for_tests();
    defer {
        cmd_wait_for_flush();
        while (cmdq.cmdq_next(null) != 0) {}
    }

    var wait_client = try newTestClient();
    defer freeTestClient(&wait_client);
    wait_client.client.tty.client = &wait_client.client;
    var owner_client = try newTestClient();
    defer freeTestClient(&owner_client);
    owner_client.client.tty.client = &owner_client.client;
    var locker_client = try newTestClient();
    defer freeTestClient(&locker_client);
    locker_client.client.tty.client = &locker_client.client;

    const callbacks = struct {
        var waiter_after: u32 = 0;
        var locker_after: u32 = 0;

        fn waiterAfter(_: *cmdq.CmdqItem, _: ?*anyopaque) T.CmdRetval {
            waiter_after += 1;
            return .normal;
        }

        fn lockerAfter(_: *cmdq.CmdqItem, _: ?*anyopaque) T.CmdRetval {
            locker_after += 1;
            return .normal;
        }
    };

    callbacks.waiter_after = 0;
    callbacks.locker_after = 0;

    const wait_list = try makeCommandList(&.{ "wait-for", "flush-wait" }, &wait_client.client);
    const wait_item = cmdq.cmdq_get_command(@ptrCast(wait_list), null);
    _ = cmdq.cmdq_append_item(&wait_client.client, wait_item);
    _ = cmdq.cmdq_insert_after(wait_item, cmdq.cmdq_get_callback1("wait-flush-after", callbacks.waiterAfter, null));
    try std.testing.expectEqual(@as(u32, 0), cmdq.cmdq_next(&wait_client.client));

    try std.testing.expectEqual(T.CmdRetval.normal, try runDirect(&.{ "wait-for", "-L", "flush-lock" }, &owner_client.client));

    const lock_list = try makeCommandList(&.{ "wait-for", "-L", "flush-lock" }, &locker_client.client);
    const lock_item = cmdq.cmdq_get_command(@ptrCast(lock_list), null);
    _ = cmdq.cmdq_append_item(&locker_client.client, lock_item);
    _ = cmdq.cmdq_insert_after(lock_item, cmdq.cmdq_get_callback1("lock-flush-after", callbacks.lockerAfter, null));
    try std.testing.expectEqual(@as(u32, 0), cmdq.cmdq_next(&locker_client.client));

    cmd_wait_for_flush();

    try std.testing.expectEqual(@as(u32, 1), cmdq.cmdq_next(&wait_client.client));
    try std.testing.expectEqual(@as(u32, 1), cmdq.cmdq_next(&locker_client.client));
    try std.testing.expectEqual(@as(u32, 1), callbacks.waiter_after);
    try std.testing.expectEqual(@as(u32, 1), callbacks.locker_after);
    try std.testing.expectEqual(@as(usize, 0), wait_channels.items.len);
}
