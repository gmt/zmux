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
const c_mod = @import("c.zig");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const log = @import("log.zig");
const args_mod = @import("arguments.zig");
const cmd_mod = @import("cmd.zig");
const cmd_find = @import("cmd-find.zig");
const client_registry = @import("client-registry.zig");
const cfg_mod = @import("cfg.zig");
const key_string = @import("key-string.zig");
const opts = @import("options.zig");
const server = @import("server.zig");
const server_print = @import("server-print.zig");
const status_runtime = @import("status-runtime.zig");

const CMDQ_FIRED: u32 = 0x1;
const CMDQ_WAITING: u32 = 0x2;

const CmdqType = enum {
    command,
    callback,
};

pub const CmdqCb = *const fn (*CmdqItem, ?*anyopaque) T.CmdRetval;

pub const HookInfo = struct {
    hook: ?[]const u8 = null,
    hook_client: ?[]const u8 = null,
    hook_session: ?[]const u8 = null,
    hook_session_name: ?[]const u8 = null,
    hook_window: ?[]const u8 = null,
    hook_window_name: ?[]const u8 = null,
    hook_pane: ?[]const u8 = null,
};

const HookInfoOwned = struct {
    hook: ?[]u8 = null,
    hook_client: ?[]u8 = null,
    hook_session: ?[]u8 = null,
    hook_session_name: ?[]u8 = null,
    hook_window: ?[]u8 = null,
    hook_window_name: ?[]u8 = null,
    hook_pane: ?[]u8 = null,

    fn deinit(self: *HookInfoOwned) void {
        freeOptional(&self.hook);
        freeOptional(&self.hook_client);
        freeOptional(&self.hook_session);
        freeOptional(&self.hook_session_name);
        freeOptional(&self.hook_window);
        freeOptional(&self.hook_window_name);
        freeOptional(&self.hook_pane);
    }

    fn borrow(self: *const HookInfoOwned) HookInfo {
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

    fn lookup(self: *const HookInfoOwned, key: []const u8) ?[]const u8 {
        if (std.mem.eql(u8, key, "hook")) return self.hook;
        if (std.mem.eql(u8, key, "hook_client")) return self.hook_client;
        if (std.mem.eql(u8, key, "hook_session")) return self.hook_session;
        if (std.mem.eql(u8, key, "hook_session_name")) return self.hook_session_name;
        if (std.mem.eql(u8, key, "hook_window")) return self.hook_window;
        if (std.mem.eql(u8, key, "hook_window_name")) return self.hook_window_name;
        if (std.mem.eql(u8, key, "hook_pane")) return self.hook_pane;
        return null;
    }
};

/// Flag descriptor for source/target resolution, mirrors tmux cmd_entry_flag.
pub const CmdEntryFlag = struct {
    flag: u8 = 0,
    find_type: T.CmdFindType = .pane,
    flags: u32 = 0,
};

pub const CmdqState = struct {
    references: u32 = 1,
    flags: u32 = 0,
    event: T.key_event = .{ .key = T.KEYC_NONE },
    current: T.CmdFindState = blankFindState(),
    hook_info: HookInfoOwned = .{},
    formats: ?std.StringHashMap([]u8) = null,
};

var default_state: CmdqState = .{};
var current_running_item: ?*CmdqItem = null;

// ── Concrete types for the opaque T.CmdqItem / T.CmdqList ────────────────

pub const CmdqItem = struct {
    name: []const u8 = "(cmdq)",
    queue: ?*CmdqList = null,
    next: ?*CmdqItem = null,

    client: ?*T.Client = null,
    target_client: ?*T.Client = null,

    item_type: CmdqType = .command,
    group: u32 = 0,
    number: u32 = 0,
    time: i64 = 0,
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
    free_data: ?*const fn (?*anyopaque) void = null,
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

fn freeOptional(value: *?[]u8) void {
    if (value.*) |owned| xm.allocator.free(owned);
    value.* = null;
}

fn setOptionalString(slot: *?[]u8, value: ?[]const u8) void {
    freeOptional(slot);
    if (value) |slice| slot.* = xm.xstrdup(slice);
}

fn freeFormats(map: *?std.StringHashMap([]u8)) void {
    var m = map.* orelse return;
    var it = m.iterator();
    while (it.next()) |entry| {
        xm.allocator.free(entry.key_ptr.*);
        xm.allocator.free(entry.value_ptr.*);
    }
    m.deinit();
    map.* = null;
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
    // When a callback item is destroyed without having been fired (e.g.
    // during cmdq_reset_for_tests), invoke its free_data hook so that any
    // heap-allocated data reachable only through the opaque `data` pointer
    // is released.  Fired items have already run their callback which is
    // responsible for freeing its own data.
    if (item.flags & CMDQ_FIRED == 0) {
        if (item.free_data) |free_fn| free_fn(item.data);
    }
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

fn clear_queue(queue: *CmdqList) void {
    var item = queue.head;
    while (item) |it| {
        item = it.next;
        destroy_item(it);
    }
    queue.* = .{};
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

var item_number_counter: u32 = 0;

fn fire_command(item: *CmdqItem) T.CmdRetval {
    if (cfg_mod.cfg_finished) cmdq_add_message(item);

    item.time = std.time.timestamp();
    item_number_counter += 1;
    item.number = item_number_counter;

    const flags_arg: i32 = if (item.state.flags & T.CMDQ_STATE_CONTROL != 0) 1 else 0;
    cmdq_guard(item, "begin", flags_arg);

    const retval = cmd_mod.cmd_execute(item.cmd.?, item);

    if (retval == .@"error")
        cmdq_guard(item, "error", flags_arg)
    else
        cmdq_guard(item, "end", flags_arg);

    return retval;
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
    const copied = cmdq_new_state(source, &state.event, state.flags);
    cmdq_set_hook_info(copied, state.hook_info.borrow());
    return copied;
}

pub fn cmdq_free_state(state: *CmdqState) void {
    if (state.references == 0) return;
    state.references -= 1;
    if (state.references == 0) {
        state.hook_info.deinit();
        freeFormats(&state.formats);
        xm.allocator.destroy(state);
    }
}

pub fn cmdq_set_hook_info(state: *CmdqState, info: HookInfo) void {
    setOptionalString(&state.hook_info.hook, info.hook);
    setOptionalString(&state.hook_info.hook_client, info.hook_client);
    setOptionalString(&state.hook_info.hook_session, info.hook_session);
    setOptionalString(&state.hook_info.hook_session_name, info.hook_session_name);
    setOptionalString(&state.hook_info.hook_window, info.hook_window);
    setOptionalString(&state.hook_info.hook_window_name, info.hook_window_name);
    setOptionalString(&state.hook_info.hook_pane, info.hook_pane);
}

pub fn cmdq_lookup_hook(item_ptr: ?*anyopaque, key: []const u8) ?[]const u8 {
    const item = if (item_ptr) |raw|
        @as(*CmdqItem, @ptrCast(@alignCast(raw)))
    else
        current_running_item orelse return null;
    if (item.state.hook_info.lookup(key)) |v| return v;
    if (item.state.formats) |*fmts| {
        if (fmts.get(key)) |v| return v;
    }
    return null;
}

pub fn cmdq_current_running() ?*CmdqItem {
    return current_running_item;
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
    return cmdq_get_callback2(name, cb, data, null);
}

/// Like `cmdq_get_callback1` but accepts an optional `free_data` function that
/// is called to release `data` when the item is destroyed without being fired
/// (e.g. during `cmdq_reset_for_tests`).  Callbacks that own heap-allocated
/// data reachable only through the opaque `data` pointer should supply this so
/// that queue teardown does not leak.
pub fn cmdq_get_callback2(name: []const u8, cb: CmdqCb, data: ?*anyopaque, free_data: ?*const fn (?*anyopaque) void) *CmdqItem {
    const item = xm.allocator.create(CmdqItem) catch unreachable;
    item.* = .{
        .name = name,
        .item_type = .callback,
        .state = cmdq_new_state(null, null, 0),
        .cb = cb,
        .data = data,
        .free_data = free_data,
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
            const retval = blk: {
                const previous_running = current_running_item;
                current_running_item = item;
                defer current_running_item = previous_running;

                break :blk switch (item.item_type) {
                    .command => fire_command(item),
                    .callback => fire_callback(item),
                };
            };
            item.flags |= CMDQ_FIRED;

            switch (retval) {
                .wait => {
                    item.flags |= CMDQ_WAITING;
                    return items;
                },
                .@"error" => {
                    // Propagate error exit code to non-attached (command-mode) clients.
                    // Mirrors tmux's cmdq_next: c->retval = 1 on CMD_RETURN_ERROR.
                    if (item.client) |err_cl| {
                        if (err_cl.session == null) err_cl.retval = 1;
                    }
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

    var had_error = false;
    var cmd_node = cmdlist.head;
    while (cmd_node) |cmd| {
        cmd_node = cmd.next;
        item.cmd = cmd;
        const result = blk: {
            const previous_running = current_running_item;
            current_running_item = &item;
            defer current_running_item = previous_running;
            break :blk cmd_mod.cmd_execute(cmd, &item);
        };
        switch (result) {
            .normal => {},
            .@"error" => had_error = true,
            .wait => {
                cmdq_write_client(cl, 2, "config command can't wait yet: {s}", .{cmd.entry.name});
                had_error = true;
            },
            .stop => return .stop,
        }
    }
    return if (had_error) .@"error" else .normal;
}

pub fn cmdq_run_immediate(cl: ?*T.Client, cmdlist: *cmd_mod.CmdList) T.CmdRetval {
    return cmdq_run_immediate_flags(cl, cmdlist, 0);
}

pub fn cmdq_reset_for_tests() void {
    clear_queue(&server_queue);
    current_running_item = null;

    if (!queues_init) return;

    var it = client_queues.valueIterator();
    while (it.next()) |queue| clear_queue(queue);
    client_queues.clearRetainingCapacity();
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

pub fn cmdq_has_pending(cl: ?*T.Client) bool {
    const queue = get_queue(cl, false) orelse return false;
    return queue.head != null;
}

pub fn cmdq_resolve_target_client(item: *CmdqItem, cmd: *cmd_mod.Cmd) ?*T.Client {
    const flags = cmd.entry.flags;
    if (flags & (T.CMD_CLIENT_CFLAG | T.CMD_CLIENT_TFLAG) == 0) return item.target_client;

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

fn cmdq_add_message(item: *CmdqItem) void {
    const cmd = item.cmd orelse return;
    const printed_args = args_mod.args_print(cmd_mod.cmd_get_args(cmd));
    defer xm.allocator.free(printed_args);

    const command_text = if (printed_args.len == 0)
        xm.xstrdup(cmd.entry.name)
    else
        xm.xasprintf("{s} {s}", .{ cmd.entry.name, printed_args });
    defer xm.allocator.free(command_text);

    if (item.client) |cl| {
        if (cl.session != null and item.state.event.key != T.KEYC_NONE) {
            server.server_add_message(
                "{s} key {s}: {s}",
                .{ cl.name orelse "client", key_string.key_string_lookup_key(item.state.event.key, 0), command_text },
            );
            return;
        }

        server.server_add_message("{s} command: {s}", .{ cl.name orelse "client", command_text });
        return;
    }

    server.server_add_message("command: {s}", .{command_text});
}

pub fn cmdq_error(item: *CmdqItem, comptime fmt: []const u8, args: anytype) void {
    log.log_warn(fmt, args);
    const msg = xm.xasprintf(fmt, args);
    defer xm.allocator.free(msg);

    if (item.client) |cl| {
        if (cl.session == null or (cl.flags & T.CLIENT_CONTROL) != 0) {
            status_runtime.present_client_message(cl, msg);
            cl.retval = 1;
            return;
        }

        status_runtime.present_client_message(cl, msg);
        return;
    }

    status_runtime.present_client_message(null, msg);
}

pub fn cmdq_print(item: *CmdqItem, comptime fmt: []const u8, args: anytype) void {
    const msg = xm.xasprintf(fmt, args);
    defer xm.allocator.free(msg);
    server_print.server_client_print(item.client, true, msg);
}

pub fn cmdq_print_data(item: *CmdqItem, data: []const u8) void {
    server_print.server_client_print(item.client, true, data);
}

pub fn cmdq_write_client(cl: ?*T.Client, stream: i32, comptime fmt: []const u8, args: anytype) void {
    const msg = xm.xasprintf(fmt, args);
    defer xm.allocator.free(msg);

    var line: std.ArrayList(u8) = .{};
    defer line.deinit(xm.allocator);
    line.appendSlice(xm.allocator, msg) catch unreachable;
    line.append(xm.allocator, '\n') catch unreachable;
    server_print.server_client_write_stream(cl, stream, line.items);
}

pub fn cmdq_write_client_data(cl: ?*T.Client, stream: i32, data: []const u8) void {
    server_print.server_client_write_stream(cl, stream, data);
}

// ── Ported from tmux cmd-queue.c ──────────────────────────────────────────

/// Get command queue name for a client (or "<global>" for the server queue).
/// Mirrors tmux `cmdq_name`.
pub fn cmdq_name(cl: ?*T.Client) []const u8 {
    if (cl) |c| return c.name orelse "<unknown>";
    return "<global>";
}

/// Add a format variable to a queue state's format store.
/// Mirrors tmux `cmdq_add_format`.
pub fn cmdq_add_format(state: *CmdqState, key: []const u8, value: []const u8) void {
    if (state.formats == null)
        state.formats = std.StringHashMap([]u8).init(xm.allocator);

    const owned_key = xm.xstrdup(key);
    const owned_val = xm.xstrdup(value);
    if (state.formats.?.fetchPut(owned_key, owned_val) catch unreachable) |old| {
        xm.allocator.free(old.key);
        xm.allocator.free(old.value);
    }
}

/// Merge format variables from another state's format store.
/// Mirrors tmux `cmdq_add_formats`.
pub fn cmdq_add_formats(state: *CmdqState, source: *const CmdqState) void {
    const src = source.formats orelse return;
    var it = src.iterator();
    while (it.next()) |entry| {
        cmdq_add_format(state, entry.key_ptr.*, entry.value_ptr.*);
    }
}

/// Merge format variables from an item (command name + state formats)
/// into a target state. Mirrors tmux `cmdq_merge_formats`.
pub fn cmdq_merge_formats(item: *CmdqItem, target_state: *CmdqState) void {
    if (item.cmd) |cmd| {
        cmdq_add_format(target_state, "command", cmd.entry.name);
    }
    if (item.state.formats) |*fmts| {
        var it = fmts.iterator();
        while (it.next()) |entry| {
            cmdq_add_format(target_state, entry.key_ptr.*, entry.value_ptr.*);
        }
    }
}

/// Empty command callback – returns CMD_RETURN_NORMAL.
/// Mirrors tmux `cmdq_empty_command`.
pub fn cmdq_empty_command(item: *CmdqItem, data: ?*anyopaque) T.CmdRetval {
    return empty_callback(item, data);
}

/// Generic error callback – displays the error and frees it.
/// Mirrors tmux `cmdq_error_callback`.
fn cmdq_error_callback(item: *CmdqItem, data: ?*anyopaque) T.CmdRetval {
    const err_ptr: *[]u8 = @ptrCast(@alignCast(data.?));
    cmdq_error(item, "{s}", .{err_ptr.*});
    xm.allocator.free(err_ptr.*);
    xm.allocator.destroy(err_ptr);
    return .normal;
}

/// free_data hook for cmdq_get_error items.
fn free_error_data(data: ?*anyopaque) void {
    const err_ptr: *[]u8 = @ptrCast(@alignCast(data orelse return));
    xm.allocator.free(err_ptr.*);
    xm.allocator.destroy(err_ptr);
}

/// Get an error callback item for the command queue.
/// Mirrors tmux `cmdq_get_error`.
pub fn cmdq_get_error(error_msg: []const u8) *CmdqItem {
    const owned = xm.allocator.create([]u8) catch unreachable;
    owned.* = xm.xstrdup(error_msg);
    return cmdq_get_callback2("cmdq-error", cmdq_error_callback, @ptrCast(owned), free_error_data);
}

/// Fill in a find state from a command entry flag descriptor.
/// Mirrors tmux `cmdq_find_flag`.
pub fn cmdq_find_flag(item: *CmdqItem, fs: *T.CmdFindState, flag: *const CmdEntryFlag) T.CmdRetval {
    if (flag.flag == 0) {
        _ = cmd_find.cmd_find_from_client(fs, item.target_client, 0);
        return .normal;
    }

    const value = if (item.cmd) |cmd|
        cmd_mod.cmd_get_args(cmd).get(flag.flag)
    else
        null;

    if (cmd_find.cmd_find_target(fs, item, value, flag.find_type, flag.flags) != 0) {
        fs.* = blankFindState();
        return .@"error";
    }
    return .normal;
}

/// Public wrapper: fire a callback-type queue item.
/// Mirrors tmux `cmdq_fire_callback`.
pub fn cmdq_fire_callback(item: *CmdqItem) T.CmdRetval {
    return fire_callback(item);
}

/// Public wrapper: fire a command-type queue item.
/// Mirrors tmux `cmdq_fire_command`.
pub fn cmdq_fire_command(item: *CmdqItem) T.CmdRetval {
    return fire_command(item);
}

/// Print a guard line for control-mode clients.
/// Mirrors tmux `cmdq_guard`.
pub fn cmdq_guard(item: *CmdqItem, guard: []const u8, flags: i32) void {
    const cl = item.client orelse return;
    if (cl.flags & T.CLIENT_CONTROL == 0) return;
    const line = xm.xasprintf("%{s} {d} {d} {d}\n", .{ guard, item.time, item.number, flags });
    defer xm.allocator.free(line);
    server_print.server_client_write_stream(cl, 1, line);
}

/// Insert hook commands into the queue after the given item.
/// Reduced implementation: resolves the hook option and enqueues any
/// matching command lists. Mirrors tmux `cmdq_insert_hook`.
pub fn cmdq_insert_hook(
    s: ?*T.Session,
    item: *CmdqItem,
    current: ?*const T.CmdFindState,
    name: []const u8,
) void {
    if (item.state.flags & T.CMDQ_STATE_NOHOOKS != 0) return;

    const session_options = if (s) |sess| sess.options else opts.global_s_options;
    const option_value = opts.options_get(session_options, name) orelse return;

    log.log_debug("running hook {s}", .{name});

    const new_state = cmdq_new_state(current, &item.state.event, T.CMDQ_STATE_NOHOOKS);
    defer cmdq_free_state(new_state);
    cmdq_add_format(new_state, "hook", name);

    if (item.cmd) |cmd| {
        const printed = args_mod.args_print(cmd_mod.cmd_get_args(cmd));
        defer xm.allocator.free(printed);
        cmdq_add_format(new_state, "hook_arguments", printed);
    }

    var tail: ?*CmdqItem = item;

    switch (option_value.*) {
        .array => |arr| {
            for (arr.items) |entry| {
                var pi: T.CmdParseInput = .{};
                const pr = cmd_mod.cmd_parse_from_string(entry.value, &pi);
                switch (pr.status) {
                    .success => {
                        if (pr.cmdlist) |raw| {
                            const cmdlist: *T.CmdList = @ptrCast(@alignCast(raw));
                            const new_item = cmdq_get_command(cmdlist, new_state);
                            if (tail) |t|
                                tail = cmdq_insert_after(t, new_item)
                            else
                                tail = cmdq_append_item(null, new_item);
                        }
                    },
                    .@"error" => {
                        if (pr.@"error") |err| {
                            log.log_debug("hook {s}: parse error: {s}", .{ name, err });
                            xm.allocator.free(err);
                        }
                    },
                }
            }
        },
        .string => |str| {
            var pi: T.CmdParseInput = .{};
            const pr = cmd_mod.cmd_parse_from_string(str, &pi);
            switch (pr.status) {
                .success => {
                    if (pr.cmdlist) |raw| {
                        const cmdlist: *T.CmdList = @ptrCast(@alignCast(raw));
                        const new_item = cmdq_get_command(cmdlist, new_state);
                        if (tail) |t|
                            _ = cmdq_insert_after(t, new_item)
                        else
                            _ = cmdq_append_item(null, new_item);
                    }
                },
                .@"error" => {
                    if (pr.@"error") |err| {
                        log.log_debug("hook {s}: parse error: {s}", .{ name, err });
                        xm.allocator.free(err);
                    }
                },
            }
        },
        else => {},
    }
}

/// Remove a queue item. Public wrapper around internal cleanup.
/// Mirrors tmux `cmdq_remove`.
pub fn cmdq_remove(item: *CmdqItem) void {
    if (item.queue) |queue| {
        var prev: ?*CmdqItem = null;
        var cur = queue.head;
        while (cur) |c| {
            if (c == item) {
                if (prev) |p|
                    p.next = item.next
                else
                    queue.head = item.next;
                if (queue.tail == item) queue.tail = prev;
                if (queue.item == item) queue.item = null;
                break;
            }
            prev = c;
            cur = c.next;
        }
    }
    item.next = null;
    destroy_item(item);
}

/// Remove all subsequent items that match this item's group.
/// Mirrors tmux `cmdq_remove_group`.
pub fn cmdq_remove_group(item: *CmdqItem) void {
    remove_group(item);
}

test "cmdq_append_event preserves the triggering key for queued commands" {
    const env_mod = @import("environ.zig");
    cmdq_reset_for_tests();
    defer cmdq_reset_for_tests();

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
        .status = .{},
    };
    cl.tty.client = &cl;

    capture.seen_key = T.KEYC_NONE;
    var event = T.key_event{ .key = 'x', .len = 1 };
    event.data[0] = 'x';

    cmdq_append_event(&cl, @ptrCast(list), &event);
    try std.testing.expectEqual(@as(u32, 1), cmdq_next(&cl));
    try std.testing.expectEqual(@as(T.key_code, 'x'), capture.seen_key);
}

test "cmdq_error routes control clients through the shared presenter path" {
    const env_mod = @import("environ.zig");
    const proc_mod = @import("proc.zig");
    const protocol = @import("zmux-protocol.zig");
    cmdq_reset_for_tests();
    defer cmdq_reset_for_tests();

    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    server.server_reset_message_log();
    defer server.server_reset_message_log();

    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);

    var pair: [2]i32 = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &pair));

    var proc = T.ZmuxProc{ .name = "cmdq-error-control-test" };
    defer proc.peers.deinit(xm.allocator);

    var client = T.Client{
        .name = "control-client",
        .environ = env,
        .tty = undefined,
        .status = .{},
        .flags = T.CLIENT_CONTROL | T.CLIENT_UTF8,
    };
    client.tty.client = &client;
    client.peer = proc_mod.proc_add_peer(&proc, pair[0], noopDispatch, null);
    defer {
        const peer = client.peer.?;
        c_mod.imsg.imsgbuf_clear(&peer.ibuf);
        std.posix.close(peer.ibuf.fd);
        xm.allocator.destroy(peer);
        proc.peers.clearRetainingCapacity();
    }

    var reader: c_mod.imsg.imsgbuf = undefined;
    try std.testing.expectEqual(@as(i32, 0), c_mod.imsg.imsgbuf_init(&reader, pair[1]));
    defer {
        c_mod.imsg.imsgbuf_clear(&reader);
        std.posix.close(pair[1]);
    }

    var item = CmdqItem{ .client = &client };
    cmdq_error(&item, "parse error", .{});

    try std.testing.expectEqual(@as(i32, 1), client.retval);
    try std.testing.expectEqual(@as(usize, 1), server.message_log.items.len);
    try std.testing.expectEqualStrings("control-client message: parse error", server.message_log.items[0].msg);
    try std.testing.expectEqual(@as(i32, 1), c_mod.imsg.imsgbuf_read(&reader));

    var imsg_msg: c_mod.imsg.imsg = undefined;
    try std.testing.expect(c_mod.imsg.imsg_get(&reader, &imsg_msg) > 0);
    defer c_mod.imsg.imsg_free(&imsg_msg);

    try std.testing.expectEqual(@as(u32, @intCast(@intFromEnum(protocol.MsgType.write))), c_mod.imsg.imsg_get_type(&imsg_msg));
    const payload_len = c_mod.imsg.imsg_get_len(&imsg_msg);
    var payload = try xm.allocator.alloc(u8, payload_len);
    defer xm.allocator.free(payload);
    try std.testing.expectEqual(@as(i32, 0), c_mod.imsg.imsg_get_data(&imsg_msg, payload.ptr, payload.len));

    const stream: *const i32 = @ptrCast(@alignCast(payload.ptr));
    try std.testing.expectEqual(@as(i32, 1), stream.*);
    try std.testing.expectEqualStrings("%message parse error\n", payload[@sizeOf(i32)..]);
}

test "cmdq_error keeps detached non-utf8 clients on the shared sanitized stderr path" {
    const env_mod = @import("environ.zig");
    cmdq_reset_for_tests();
    defer cmdq_reset_for_tests();

    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    server.server_reset_message_log();
    defer server.server_reset_message_log();

    var stderr_pipe: [2]i32 = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.pipe(&stderr_pipe));
    defer {
        std.posix.close(stderr_pipe[0]);
        if (stderr_pipe[1] != -1) std.posix.close(stderr_pipe[1]);
    }

    const stderr_dup = try std.posix.dup(std.posix.STDERR_FILENO);
    defer std.posix.close(stderr_dup);

    try std.posix.dup2(stderr_pipe[1], std.posix.STDERR_FILENO);
    defer std.posix.dup2(stderr_dup, std.posix.STDERR_FILENO) catch {};

    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);

    var client = T.Client{
        .name = "detached-client",
        .environ = env,
        .tty = undefined,
        .status = .{},
        .flags = 0,
    };
    client.tty.client = &client;

    var item = CmdqItem{ .client = &client };
    cmdq_error(&item, "bad \xc3(", .{});

    try std.testing.expectEqual(@as(i32, 1), client.retval);
    try std.testing.expectEqual(@as(usize, 1), server.message_log.items.len);
    try std.testing.expectEqualStrings("detached-client message: bad \xc3(", server.message_log.items[0].msg);

    std.posix.close(stderr_pipe[1]);
    stderr_pipe[1] = -1;

    var buf: [128]u8 = undefined;
    const read_len = try std.posix.read(stderr_pipe[0], &buf);
    try std.testing.expectEqualStrings("bad _(\n", buf[0..read_len]);
}

fn noopDispatch(_imsg: ?*c_mod.imsg.imsg, _arg: ?*anyopaque) callconv(.c) void {
    _ = _imsg;
    _ = _arg;
}

test "cmdq waiting items block later entries until continued" {
    cmdq_reset_for_tests();
    defer cmdq_reset_for_tests();

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

test "cmdq logs command execution into the shared message log once config is finished" {
    const env_mod = @import("environ.zig");
    cmdq_reset_for_tests();
    defer cmdq_reset_for_tests();

    const logged = struct {
        fn exec(_: *cmd_mod.Cmd, _: *CmdqItem) T.CmdRetval {
            return .normal;
        }
    };

    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    server.server_reset_message_log();
    defer server.server_reset_message_log();

    const old_cfg_finished = cfg_mod.cfg_finished;
    cfg_mod.cfg_finished = true;
    defer cfg_mod.cfg_finished = old_cfg_finished;

    const entry = cmd_mod.CmdEntry{
        .name = "cmdq-test-log",
        .exec = logged.exec,
    };

    var cause: ?[]u8 = null;
    const parsed_args = try args_mod.args_parse(xm.allocator, &.{ "one", "two" }, "", 0, -1, &cause);

    const list = xm.allocator.create(cmd_mod.CmdList) catch unreachable;
    list.* = .{};

    const cmd = xm.allocator.create(cmd_mod.Cmd) catch unreachable;
    cmd.* = .{
        .entry = &entry,
        .args = parsed_args,
    };
    list.append(cmd);

    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);
    var cl = T.Client{
        .name = "logger",
        .environ = env,
        .tty = undefined,
        .status = .{},
    };
    cl.tty.client = &cl;

    cmdq_append(&cl, list);
    try std.testing.expectEqual(@as(u32, 1), cmdq_next(&cl));
    try std.testing.expectEqual(@as(usize, 1), server.message_log.items.len);
    try std.testing.expectEqualStrings("logger command: cmdq-test-log one two", server.message_log.items[0].msg);
}

test "cmdq_next on empty queue returns zero" {
    cmdq_reset_for_tests();
    defer cmdq_reset_for_tests();
    try std.testing.expectEqual(@as(u32, 0), cmdq_next(null));
}
