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
// Ported from tmux/cmd-queue.c
// Original copyright:
//   Copyright (c) 2013 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

//! cmd-queue.zig – the command queue that serialises command execution.

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const log = @import("log.zig");
const args_mod = @import("arguments.zig");
const cmd_mod = @import("cmd.zig");
const client_registry = @import("client-registry.zig");
const proc_mod = @import("proc.zig");

const CMDQ_FIRED: u32 = 0x1;
const CMDQ_WAITING: u32 = 0x2;

const CmdqType = enum {
    command,
    callback,
};

pub const CmdqCb = *const fn (*CmdqItem, ?*anyopaque) T.CmdRetval;

pub const CmdqState = struct {
    references: u32 = 1,
    flags: u32 = 0,
    event: T.key_event = .{ .key = T.KEYC_NONE },
    current: T.CmdFindState = blankFindState(),
};

var default_state: CmdqState = .{};

// ── Concrete types for the opaque T.CmdqItem / T.CmdqList ────────────────

pub const CmdqItem = struct {
    name: []const u8 = "(cmdq)",
    queue: ?*CmdqList = null,
    next: ?*CmdqItem = null,

    client: ?*T.Client = null,
    target_client: ?*T.Client = null,

    item_type: CmdqType = .command,
    group: u32 = 0,
    flags: u32 = 0,

    state: *CmdqState = &default_state,
    event: T.key_event = .{ .key = T.KEYC_NONE },
    state_flags: u32 = 0,
    source: T.CmdFindState = blankFindState(),
    target: T.CmdFindState = blankFindState(),

    cmdlist: ?*cmd_mod.CmdList = null,
    cmd: ?*cmd_mod.Cmd = null,

    cb: ?CmdqCb = null,
    data: ?*anyopaque = null,
};

pub const CmdqList = struct {
    item: ?*CmdqItem = null,
    head: ?*CmdqItem = null,
    tail: ?*CmdqItem = null,
};

// Per-process global queues – one per client + one for server
var server_queue: CmdqList = .{};
var client_queues: std.AutoHashMap(usize, CmdqList) = undefined;
var queues_init = false;

fn blankFindState() T.CmdFindState {
    return .{ .idx = -1 };
}

fn copyFindState(src: *const T.CmdFindState) T.CmdFindState {
    var dst = src.*;
    dst.current = null;
    return dst;
}

fn ensure_init() void {
    if (queues_init) return;
    client_queues = std.AutoHashMap(usize, CmdqList).init(xm.allocator);
    queues_init = true;
}

fn get_queue(cl: ?*T.Client, create: bool) ?*CmdqList {
    ensure_init();
    if (cl) |c| {
        const key: usize = @intFromPtr(c);
        if (create) {
            const gop = client_queues.getOrPut(key) catch unreachable;
            if (!gop.found_existing) gop.value_ptr.* = .{};
            return gop.value_ptr;
        }
        return client_queues.getPtr(key);
    }
    return &server_queue;
}

fn destroy_item(item: *CmdqItem) void {
    if (item.cmdlist) |cmdlist| cmd_mod.cmd_list_unref(@ptrCast(cmdlist));
    cmdq_free_state(item.state);
    xm.allocator.destroy(item);
}

fn pop_head(queue: *CmdqList) ?*CmdqItem {
    const item = queue.head orelse return null;
    queue.head = item.next;
    if (queue.head == null) queue.tail = null;
    item.next = null;
    if (queue.item == item) queue.item = null;
    return item;
}

fn remove_group(item: *CmdqItem) void {
    if (item.group == 0) return;

    const queue = item.queue orelse return;
    var prev = item;
    var next = item.next;
    while (next) |candidate| {
        if (candidate.group == item.group) {
            prev.next = candidate.next;
            if (queue.tail == candidate) queue.tail = prev;
            next = candidate.next;
            candidate.next = null;
            destroy_item(candidate);
            continue;
        }
        prev = candidate;
        next = candidate.next;
    }
}

fn fire_command(item: *CmdqItem) T.CmdRetval {
    return cmd_mod.cmd_execute(item.cmd.?, item);
}

fn fire_callback(item: *CmdqItem) T.CmdRetval {
    return item.cb.?(item, item.data);
}

fn empty_callback(_: *CmdqItem, _: ?*anyopaque) T.CmdRetval {
    return .normal;
}

// ── Queue operations ──────────────────────────────────────────────────────

pub fn cmdq_new() *CmdqList {
    const q = xm.allocator.create(CmdqList) catch unreachable;
    q.* = .{};
    return q;
}

pub fn cmdq_free(q: *CmdqList) void {
    var item = q.head;
    while (item) |it| {
        item = it.next;
        destroy_item(it);
    }
    xm.allocator.destroy(q);
}

pub fn cmdq_new_state(current: ?*const T.CmdFindState, event: ?*const T.key_event, flags: u32) *CmdqState {
    const state = xm.allocator.create(CmdqState) catch unreachable;
    state.* = .{
        .flags = flags,
        .event = if (event) |ev| ev.* else .{ .key = T.KEYC_NONE },
        .current = if (current) |fs| copyFindState(fs) else blankFindState(),
    };
    return state;
}

pub fn cmdq_link_state(state: *CmdqState) *CmdqState {
    state.references += 1;
    return state;
}

pub fn cmdq_copy_state(state: *CmdqState, current: ?*const T.CmdFindState) *CmdqState {
    const source = current orelse &state.current;
    return cmdq_new_state(source, &state.event, state.flags);
}

pub fn cmdq_free_state(state: *CmdqState) void {
    if (state.references == 0) return;
    state.references -= 1;
    if (state.references == 0) xm.allocator.destroy(state);
}

pub fn cmdq_get_command(cmdlist_ptr: *T.CmdList, state: ?*CmdqState) *CmdqItem {
    const cmdlist: *cmd_mod.CmdList = @ptrCast(@alignCast(cmdlist_ptr));
    if (cmdlist.head == null) {
        cmd_mod.cmd_list_unref(cmdlist_ptr);
        return cmdq_get_callback1("cmdq-empty-command", empty_callback, null);
    }

    const actual_state = state orelse cmdq_new_state(null, null, 0);
    const created_state = state == null;
    defer if (created_state) cmdq_free_state(actual_state);

    var first: ?*CmdqItem = null;
    var last: ?*CmdqItem = null;
    var first_cmd = true;
    var cmd = cmdlist.head;
    while (cmd) |current_cmd| : (cmd = current_cmd.next) {
        if (!first_cmd) _ = cmd_mod.cmd_list_ref(cmdlist_ptr);

        const item = xm.allocator.create(CmdqItem) catch unreachable;
        item.* = .{
            .name = current_cmd.entry.name,
            .item_type = .command,
            .group = cmdlist.group,
            .state = cmdq_link_state(actual_state),
            .event = actual_state.event,
            .state_flags = actual_state.flags,
            .cmdlist = cmdlist,
            .cmd = current_cmd,
        };

        if (last) |previous| {
            previous.next = item;
        } else {
            first = item;
        }
        last = item;
        first_cmd = false;
    }

    return first.?;
}

pub fn cmdq_get_callback1(name: []const u8, cb: CmdqCb, data: ?*anyopaque) *CmdqItem {
    const item = xm.allocator.create(CmdqItem) catch unreachable;
    item.* = .{
        .name = name,
        .item_type = .callback,
        .state = cmdq_new_state(null, null, 0),
        .cb = cb,
        .data = data,
    };
    return item;
}

pub fn cmdq_get_callback(cb: CmdqCb, data: ?*anyopaque) *CmdqItem {
    return cmdq_get_callback1("cmdq-callback", cb, data);
}

pub fn cmdq_append_item(cl: ?*T.Client, first: *CmdqItem) *CmdqItem {
    const queue = get_queue(cl, true).?;
    var item: ?*CmdqItem = first;
    var last = first;
    while (item) |current| : (item = current.next) {
        current.client = cl;
        current.queue = queue;
        last = current;
    }

    if (queue.tail) |tail| {
        tail.next = first;
    } else {
        queue.head = first;
    }
    queue.tail = last;
    return last;
}

pub fn cmdq_insert_after(after: *CmdqItem, first: *CmdqItem) *CmdqItem {
    const queue = after.queue orelse unreachable;
    var item: ?*CmdqItem = first;
    var last = first;
    while (item) |current| : (item = current.next) {
        current.client = after.client;
        current.queue = queue;
        last = current;
    }

    last.next = after.next;
    after.next = first;
    if (queue.tail == after) queue.tail = last;
    return last;
}

/// Append a command list to the per-client (or server) queue.
pub fn cmdq_append(cl: ?*T.Client, cmdlist: *cmd_mod.CmdList) void {
    cmdq_append_event(cl, cmdlist, null);
}

pub fn cmdq_append_event(cl: ?*T.Client, cmdlist: *cmd_mod.CmdList, event: ?*const T.key_event) void {
    const state = cmdq_new_state(null, event, 0);
    defer cmdq_free_state(state);
    _ = cmdq_append_item(cl, cmdq_get_command(@ptrCast(cmdlist), state));
}

/// Drain items from the queue for the given client (null = server queue).
/// Returns the number of non-waiting items processed.
pub fn cmdq_next(cl: ?*T.Client) u32 {
    const queue = get_queue(cl, false) orelse return 0;
    const first = queue.head orelse return 0;
    if (first.flags & CMDQ_WAITING != 0) return 0;

    var items: u32 = 0;
    while (queue.head) |item| {
        queue.item = item;

        if (item.flags & CMDQ_WAITING != 0) return items;

        if (item.flags & CMDQ_FIRED == 0) {
            const retval = switch (item.item_type) {
                .command => fire_command(item),
                .callback => fire_callback(item),
            };
            item.flags |= CMDQ_FIRED;

            switch (retval) {
                .wait => {
                    item.flags |= CMDQ_WAITING;
                    return items;
                },
                .@"error" => {
                    remove_group(item);
                    items += 1;
                },
                .stop => {
                    _ = pop_head(queue);
                    destroy_item(item);
                    return items;
                },
                .normal => items += 1,
            }
        }

        _ = pop_head(queue);
        destroy_item(item);
    }

    queue.item = null;
    return items;
}

pub fn cmdq_continue(item: *CmdqItem) void {
    item.flags &= ~CMDQ_WAITING;
}

pub fn cmdq_run_immediate_flags(cl: ?*T.Client, cmdlist: *cmd_mod.CmdList, state_flags: u32) T.CmdRetval {
    defer cmd_mod.cmd_list_free(cmdlist);

    const state = cmdq_new_state(null, null, state_flags);
    defer cmdq_free_state(state);

    var item = CmdqItem{
        .item_type = .command,
        .client = cl,
        .state = state,
        .state_flags = state_flags,
        .cmdlist = cmdlist,
    };

    var cmd_node = cmdlist.head;
    while (cmd_node) |cmd| {
        cmd_node = cmd.next;
        item.cmd = cmd;
        const result = cmd_mod.cmd_execute(cmd, &item);
        switch (result) {
            .normal => {},
            .@"error" => return .@"error",
            .wait => {
                cmdq_write_client(cl, 2, "config command can't wait yet: {s}", .{cmd.entry.name});
                return .@"error";
            },
            .stop => return .stop,
        }
    }
    return .normal;
}

pub fn cmdq_run_immediate(cl: ?*T.Client, cmdlist: *cmd_mod.CmdList) T.CmdRetval {
    return cmdq_run_immediate_flags(cl, cmdlist, 0);
}

pub fn cmdq_get_name(item: *CmdqItem) []const u8 {
    if (item.cmd) |cmd| return cmd.entry.name;
    return item.name;
}

pub fn cmdq_get_client(item: *CmdqItem) ?*T.Client {
    return item.client;
}

pub fn cmdq_get_target_client(item_ptr: *anyopaque) ?*T.Client {
    const item: *CmdqItem = @ptrCast(@alignCast(item_ptr));
    return item.target_client;
}

pub fn cmdq_get_state(item: *CmdqItem) *CmdqState {
    return item.state;
}

pub fn cmdq_get_target(item: *CmdqItem) T.CmdFindState {
    return item.target;
}

pub fn cmdq_get_source(item: *CmdqItem) T.CmdFindState {
    return item.source;
}

pub fn cmdq_get_current(item: *CmdqItem) T.CmdFindState {
    return item.state.current;
}

pub fn cmdq_get_event(item: *CmdqItem) *T.key_event {
    if (item.state == &default_state) return &item.event;
    return &item.state.event;
}

pub fn cmdq_get_flags(item: *CmdqItem) u32 {
    if (item.state == &default_state) return item.state_flags;
    return item.state.flags;
}

pub fn cmdq_running(cl: ?*T.Client) ?*CmdqItem {
    const queue = get_queue(cl, false) orelse return null;
    const item = queue.item orelse return null;
    if (item.flags & CMDQ_WAITING != 0) return null;
    return item;
}

pub fn cmdq_resolve_target_client(item: *CmdqItem, cmd: *cmd_mod.Cmd) ?*T.Client {
    const flags = cmd.entry.flags;
    if (flags & (T.CMD_CLIENT_CFLAG | T.CMD_CLIENT_TFLAG) == 0) return null;

    const args = cmd_mod.cmd_get_args(cmd);
    const explicit = if (flags & T.CMD_CLIENT_CFLAG != 0) args.get('c') else args.get('t');
    return cmdq_find_client(item, explicit, flags & T.CMD_CLIENT_CANFAIL != 0);
}

fn cmdq_find_client(item: *CmdqItem, explicit: ?[]const u8, quiet: bool) ?*T.Client {
    if (explicit == null) return item.client;

    var target = explicit.?;
    if (target.len != 0 and target[target.len - 1] == ':')
        target = target[0 .. target.len - 1];

    for (client_registry.clients.items) |cl| {
        if (cl.session == null) continue;
        if (cl.name) |name| {
            if (std.mem.eql(u8, target, name)) return cl;
        }
        if (cl.ttyname) |ttyname| {
            if (std.mem.eql(u8, target, ttyname)) return cl;
            if (std.mem.startsWith(u8, ttyname, "/dev/") and std.mem.eql(u8, target, ttyname["/dev/".len..]))
                return cl;
        }
    }

    if (!quiet) cmdq_error(item, "can't find client: {s}", .{target});
    return null;
}

pub fn cmdq_error(item: *CmdqItem, comptime fmt: []const u8, args: anytype) void {
    log.log_warn(fmt, args);
    cmdq_write_client(item.client, 2, fmt, args);
}

pub fn cmdq_print(item: *CmdqItem, comptime fmt: []const u8, args: anytype) void {
    cmdq_write_client(item.client, 1, fmt, args);
}

pub fn cmdq_print_data(item: *CmdqItem, data: []const u8) void {
    cmdq_write_client_data(item.client, 1, data);
}

pub fn cmdq_write_client(cl: ?*T.Client, stream: i32, comptime fmt: []const u8, args: anytype) void {
    const msg = xm.xasprintf(fmt, args);
    defer xm.allocator.free(msg);

    if (cl) |c_ptr| {
        if (c_ptr.peer) |peer| {
            var buf: std.ArrayList(u8) = .{};
            defer buf.deinit(xm.allocator);
            buf.appendSlice(xm.allocator, std.mem.asBytes(&stream)) catch unreachable;
            buf.appendSlice(xm.allocator, msg) catch unreachable;
            buf.append(xm.allocator, '\n') catch unreachable;
            _ = proc_mod.proc_send(peer, .write, -1, buf.items.ptr, buf.items.len);
            return;
        }
    }
    const file = if (stream == 2) std.fs.File.stderr() else std.fs.File.stdout();
    _ = file.writeAll(msg) catch {};
    _ = file.writeAll("\n") catch {};
}

pub fn cmdq_write_client_data(cl: ?*T.Client, stream: i32, data: []const u8) void {
    if (cl) |c_ptr| {
        if (c_ptr.peer) |peer| {
            var buf: std.ArrayList(u8) = .{};
            defer buf.deinit(xm.allocator);
            buf.appendSlice(xm.allocator, std.mem.asBytes(&stream)) catch unreachable;
            buf.appendSlice(xm.allocator, data) catch unreachable;
            _ = proc_mod.proc_send(peer, .write, -1, buf.items.ptr, buf.items.len);
            return;
        }
    }

    const file = if (stream == 2) std.fs.File.stderr() else std.fs.File.stdout();
    _ = file.writeAll(data) catch {};
}

test "cmdq_append_event preserves the triggering key for queued commands" {
    const env_mod = @import("environ.zig");

    const capture = struct {
        var seen_key: T.key_code = T.KEYC_NONE;

        fn exec(_: *cmd_mod.Cmd, item: *CmdqItem) T.CmdRetval {
            seen_key = cmdq_get_event(item).key;
            return .normal;
        }
    };

    const entry = cmd_mod.CmdEntry{
        .name = "cmdq-test-capture-event",
        .exec = capture.exec,
    };

    const list = xm.allocator.create(cmd_mod.CmdList) catch unreachable;
    list.* = .{};

    const cmd = xm.allocator.create(cmd_mod.Cmd) catch unreachable;
    cmd.* = .{
        .entry = &entry,
        .args = args_mod.Arguments.init(xm.allocator),
    };
    list.append(cmd);

    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);
    var cl = T.Client{
        .environ = env,
        .tty = undefined,
        .status = .{ .screen = undefined },
    };
    cl.tty.client = &cl;

    capture.seen_key = T.KEYC_NONE;
    var event = T.key_event{ .key = 'x', .len = 1 };
    event.data[0] = 'x';

    cmdq_append_event(&cl, @ptrCast(list), &event);
    try std.testing.expectEqual(@as(u32, 1), cmdq_next(&cl));
    try std.testing.expectEqual(@as(T.key_code, 'x'), capture.seen_key);
}

test "cmdq waiting items block later entries until continued" {
    const callbacks = struct {
        var waited: u32 = 0;
        var ran_after: u32 = 0;

        fn wait(item: *CmdqItem, _: ?*anyopaque) T.CmdRetval {
            _ = item;
            waited += 1;
            return .wait;
        }

        fn after(item: *CmdqItem, _: ?*anyopaque) T.CmdRetval {
            _ = item;
            ran_after += 1;
            return .normal;
        }
    };

    callbacks.waited = 0;
    callbacks.ran_after = 0;

    const waiting = cmdq_get_callback1("cmdq-test-wait", callbacks.wait, null);
    _ = cmdq_append_item(null, waiting);
    _ = cmdq_append_item(null, cmdq_get_callback1("cmdq-test-after", callbacks.after, null));

    try std.testing.expectEqual(@as(u32, 0), cmdq_next(null));
    try std.testing.expectEqual(@as(u32, 1), callbacks.waited);
    try std.testing.expectEqual(@as(u32, 0), callbacks.ran_after);

    cmdq_continue(waiting);
    try std.testing.expectEqual(@as(u32, 1), cmdq_next(null));
    try std.testing.expectEqual(@as(u32, 1), callbacks.waited);
    try std.testing.expectEqual(@as(u32, 1), callbacks.ran_after);
}

pub fn cmd_wait_for_flush() void {}
