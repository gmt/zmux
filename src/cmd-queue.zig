// Copyright (c) 2026 Greg Turner <gmt@pobox.com>
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
const cmd_mod = @import("cmd.zig");
const proc_mod = @import("proc.zig");
const protocol = @import("zmux-protocol.zig");

// ── Concrete types for the opaque T.CmdqItem / T.CmdqList ────────────────

pub const CmdqItem = struct {
    client: ?*T.Client,
    cmdlist: *cmd_mod.CmdList,
    cmd: ?*cmd_mod.Cmd = null,
    state_flags: u32 = 0,
    retval: i32 = 0,
    next: ?*CmdqItem = null,
};

pub const CmdqList = struct {
    head: ?*CmdqItem = null,
    tail: ?*CmdqItem = null,
};

// Per-process global queues – one per client + one for server
var server_queue: CmdqList = .{};
var client_queues: std.AutoHashMap(usize, CmdqList) = undefined;
var queues_init = false;

fn ensure_init() void {
    if (queues_init) return;
    client_queues = std.AutoHashMap(usize, CmdqList).init(xm.allocator);
    queues_init = true;
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
        xm.allocator.destroy(it);
    }
    xm.allocator.destroy(q);
}

/// Append a command list to the per-client (or server) queue.
pub fn cmdq_append(cl: ?*T.Client, cmdlist: *cmd_mod.CmdList) void {
    ensure_init();
    const item = xm.allocator.create(CmdqItem) catch unreachable;
    item.* = .{ .client = cl, .cmdlist = cmdlist, .retval = 0 };

    const q: *CmdqList = if (cl) |c| blk: {
        const key: usize = @intFromPtr(c);
        const gop = client_queues.getOrPut(key) catch unreachable;
        if (!gop.found_existing) gop.value_ptr.* = .{};
        break :blk gop.value_ptr;
    } else &server_queue;

    if (q.tail) |tail| {
        tail.next = item;
        q.tail = item;
    } else {
        q.head = item;
        q.tail = item;
    }
}

/// Drain one item from the queue for the given client (null = server queue).
/// Returns the number of items processed.
pub fn cmdq_next(cl: ?*T.Client) u32 {
    ensure_init();
    const q: *CmdqList = if (cl) |c| blk: {
        const key: usize = @intFromPtr(c);
        const q_ptr = client_queues.getPtr(key) orelse return 0;
        break :blk q_ptr;
    } else &server_queue;

    var count: u32 = 0;

    while (q.head) |item| {
        q.head = item.next;
        if (q.head == null) q.tail = null;

        var cmd_node = item.cmdlist.head;
        var overall_retval: T.CmdRetval = .normal;
        while (cmd_node) |cmd| {
            cmd_node = cmd.next;
            const result = cmd_mod.cmd_execute(cmd, item);
            switch (result) {
                .@"error" => {
                    log.log_warn("command error: {s}", .{cmd.entry.name});
                    overall_retval = .@"error";
                    break;
                },
                .wait => break,
                .stop => {
                    xm.allocator.destroy(item);
                    return count;
                },
                .normal => {},
            }
        }

        if (item.client) |c_ptr| {
            if (c_ptr.flags & T.CLIENT_CONTROL == 0 or c_ptr.flags & T.CLIENT_EXIT != 0) {
                if (c_ptr.peer) |peer| {
                    const retval: i32 = if (overall_retval == .@"error") 1 else 0;
                    _ = proc_mod.proc_send(peer, .exit, -1, @ptrCast(std.mem.asBytes(&retval)), @sizeOf(i32));
                }
            }
        }

        xm.allocator.destroy(item);
        count += 1;
    }
    return count;
}

pub fn cmdq_get_name(item: *CmdqItem) []const u8 {
    if (item.cmd) |cmd| return cmd.entry.name;
    return "(cmdq)";
}

pub fn cmdq_get_client(item: *CmdqItem) ?*T.Client {
    return item.client;
}

pub fn cmdq_get_target(item: *CmdqItem) T.CmdFindState {
    _ = item;
    return .{};
}

pub fn cmdq_get_current(item: *CmdqItem) T.CmdFindState {
    _ = item;
    return .{};
}

pub fn cmdq_get_flags(item: *CmdqItem) u32 {
    return item.state_flags;
}

pub fn cmdq_get_target_client(_item: *anyopaque) ?*T.Client {
    _ = _item;
    return null;
}

pub fn cmdq_error(item: *CmdqItem, comptime fmt: []const u8, args: anytype) void {
    log.log_warn(fmt, args);
    cmdq_write_client(item.client, 2, fmt, args);
}

pub fn cmdq_print(item: *CmdqItem, comptime fmt: []const u8, args: anytype) void {
    cmdq_write_client(item.client, 1, fmt, args);
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

pub fn cmd_wait_for_flush() void {}
