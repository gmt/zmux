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
// Ported in part from tmux/file.c.
// Original copyright:
//   Copyright (c) 2019 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence - same terms as above.

const std = @import("std");
const c = @import("c.zig");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const proc_mod = @import("proc.zig");
const protocol = @import("zmux-protocol.zig");

const max_imsg_payload = c.imsg.MAX_IMSGSIZE - c.imsg.IMSG_HEADER_SIZE - @sizeOf(protocol.MsgReadData);

pub const ReadDoneCallback = *const fn ([]const u8, c_int, []const u8, ?*anyopaque) void;

pub const StartResult = union(enum) {
    wait,
    err: c_int,
};

const PendingRead = struct {
    stream: i32,
    client: *T.Client,
    path: []u8,
    callback: ReadDoneCallback,
    data: ?*anyopaque,
    buffer: std.ArrayList(u8),
};

var next_stream: i32 = 3;
var pending_reads: std.AutoHashMap(i32, *PendingRead) = undefined;
var pending_reads_init = false;

fn ensure_pending_reads() void {
    if (pending_reads_init) return;
    pending_reads = std.AutoHashMap(i32, *PendingRead).init(xm.allocator);
    pending_reads_init = true;
}

fn free_pending_read(pending: *PendingRead) void {
    pending.buffer.deinit(xm.allocator);
    xm.allocator.free(pending.path);
    xm.allocator.destroy(pending);
}

fn finish_pending_read(pending: *PendingRead, errno_value: c_int) void {
    _ = pending_reads.remove(pending.stream);
    pending.callback(pending.path, errno_value, pending.buffer.items, pending.data);
    free_pending_read(pending);
}

fn client_parse_read_path(data_len: usize, data_ptr: *const protocol.MsgReadOpen) []const u8 {
    if (data_len == @sizeOf(protocol.MsgReadOpen)) return "-";
    const raw: [*]const u8 = @ptrCast(data_ptr);
    return raw[@sizeOf(protocol.MsgReadOpen) .. data_len - 1];
}

fn send_read_done(peer: *T.ZmuxPeer, stream: i32, errno_value: c_int) void {
    const done = protocol.MsgReadDone{
        .stream = stream,
        .@"error" = errno_value,
    };
    _ = proc_mod.proc_send(peer, .read_done, -1, std.mem.asBytes(&done).ptr, @sizeOf(protocol.MsgReadDone));
}

fn send_read_chunk(peer: *T.ZmuxPeer, stream: i32, data: []const u8) bool {
    var payload = std.ArrayList(u8){};
    defer payload.deinit(xm.allocator);

    const header = protocol.MsgReadData{ .stream = stream };
    payload.appendSlice(xm.allocator, std.mem.asBytes(&header)) catch return false;
    payload.appendSlice(xm.allocator, data) catch return false;
    return proc_mod.proc_send(peer, .read, -1, payload.items.ptr, payload.items.len) == 0;
}

pub fn start_remote_read(client: *T.Client, path: []const u8, callback: ReadDoneCallback, data: ?*anyopaque) StartResult {
    if (std.mem.eql(u8, path, "-") and (client.flags & T.CLIENT_CONTROL) != 0) {
        return .{ .err = @intFromEnum(std.posix.E.BADF) };
    }

    const peer = client.peer orelse return .{ .err = @intFromEnum(std.posix.E.BADF) };

    ensure_pending_reads();

    const stream = next_stream;
    next_stream += 1;

    const pending = xm.allocator.create(PendingRead) catch unreachable;
    pending.* = .{
        .stream = stream,
        .client = client,
        .path = xm.xstrdup(path),
        .callback = callback,
        .data = data,
        .buffer = .{},
    };
    pending_reads.put(stream, pending) catch unreachable;

    var payload = std.ArrayList(u8){};
    defer payload.deinit(xm.allocator);

    const open_msg = protocol.MsgReadOpen{
        .stream = stream,
        .fd = if (std.mem.eql(u8, path, "-")) std.posix.STDIN_FILENO else -1,
    };
    payload.appendSlice(xm.allocator, std.mem.asBytes(&open_msg)) catch unreachable;
    payload.appendSlice(xm.allocator, path) catch unreachable;
    payload.append(xm.allocator, 0) catch unreachable;

    if (proc_mod.proc_send(peer, .read_open, -1, payload.items.ptr, payload.items.len) != 0) {
        finish_pending_read(pending, @intFromEnum(std.posix.E.PIPE));
        return .{ .err = @intFromEnum(std.posix.E.PIPE) };
    }
    return .wait;
}

pub fn handle_read_data(imsg_msg: *c.imsg.imsg) void {
    if (!pending_reads_init) return;

    const data_len = imsg_msg.hdr.len -% @sizeOf(c.imsg.imsg_hdr);
    if (data_len < @sizeOf(protocol.MsgReadData) or imsg_msg.data == null) return;

    const msg: *const protocol.MsgReadData = @ptrCast(@alignCast(imsg_msg.data.?));
    const pending = pending_reads.get(msg.stream) orelse return;
    const raw: [*]const u8 = @ptrCast(imsg_msg.data.?);
    const chunk = raw[@sizeOf(protocol.MsgReadData)..data_len];

    pending.buffer.appendSlice(xm.allocator, chunk) catch {
        finish_pending_read(pending, @intFromEnum(std.posix.E.NOMEM));
    };
}

pub fn handle_read_done(imsg_msg: *c.imsg.imsg) void {
    if (!pending_reads_init) return;

    const data_len = imsg_msg.hdr.len -% @sizeOf(c.imsg.imsg_hdr);
    if (data_len != @sizeOf(protocol.MsgReadDone) or imsg_msg.data == null) return;

    const msg: *const protocol.MsgReadDone = @ptrCast(@alignCast(imsg_msg.data.?));
    const pending = pending_reads.get(msg.stream) orelse return;
    finish_pending_read(pending, msg.@"error");
}

pub fn fail_pending_reads_for_client(client: *T.Client) void {
    if (!pending_reads_init) return;

    var doomed = std.ArrayList(i32){};
    defer doomed.deinit(xm.allocator);

    var it = pending_reads.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.*.client == client) doomed.append(xm.allocator, entry.key_ptr.*) catch unreachable;
    }

    for (doomed.items) |stream| {
        const pending = pending_reads.get(stream) orelse continue;
        finish_pending_read(pending, @intFromEnum(std.posix.E.PIPE));
    }
}

pub fn client_handle_read_open(peer: *T.ZmuxPeer, imsg_msg: *c.imsg.imsg, allow_streams: bool, close_received: bool) void {
    _ = close_received;

    const data_len = imsg_msg.hdr.len -% @sizeOf(c.imsg.imsg_hdr);
    if (data_len < @sizeOf(protocol.MsgReadOpen) or imsg_msg.data == null) return;

    const msg: *const protocol.MsgReadOpen = @ptrCast(@alignCast(imsg_msg.data.?));
    const path = client_parse_read_path(data_len, msg);

    var fd: i32 = -1;
    if (msg.fd == -1) {
        const path_z = xm.xm_dupeZ(path);
        defer xm.allocator.free(path_z);
        fd = c.posix_sys.open(path_z, c.posix_sys.O_RDONLY, @as(c.posix_sys.mode_t, 0));
    } else if (allow_streams and msg.fd == std.posix.STDIN_FILENO) {
        fd = c.posix_sys.dup(msg.fd);
    } else {
        std.c._errno().* = @intFromEnum(std.posix.E.BADF);
    }

    if (fd == -1) {
        send_read_done(peer, msg.stream, std.c._errno().*);
        return;
    }
    defer _ = c.posix_sys.close(fd);

    var buf: [4096]u8 = undefined;
    while (true) {
        const got = c.posix_sys.read(fd, @ptrCast(buf[0..].ptr), @min(buf.len, max_imsg_payload));
        if (got == -1) {
            if (std.c._errno().* == @intFromEnum(std.posix.E.INTR)) continue;
            send_read_done(peer, msg.stream, std.c._errno().*);
            return;
        }
        if (got == 0) break;
        if (!send_read_chunk(peer, msg.stream, buf[0..@as(usize, @intCast(got))])) {
            send_read_done(peer, msg.stream, @intFromEnum(std.posix.E.PIPE));
            return;
        }
    }

    send_read_done(peer, msg.stream, 0);
}

pub fn client_handle_read_cancel(imsg_msg: *c.imsg.imsg) void {
    _ = imsg_msg;
}

pub fn reset_for_tests() void {
    if (!pending_reads_init) {
        next_stream = 3;
        return;
    }

    var it = pending_reads.valueIterator();
    while (it.next()) |pending_ptr| free_pending_read(pending_ptr.*);
    pending_reads.deinit();
    pending_reads_init = false;
    next_stream = 3;
}

pub fn client_cleanup() void {
    if (!pending_reads_init) return;

    var it = pending_reads.iterator();
    var doomed = std.ArrayList(i32){};
    defer doomed.deinit(xm.allocator);
    while (it.next()) |entry| {
        doomed.append(xm.allocator, entry.key_ptr.*) catch unreachable;
    }
    for (doomed.items) |stream| {
        const pending = pending_reads.get(stream) orelse continue;
        finish_pending_read(pending, @intFromEnum(std.posix.E.PIPE));
    }
}

fn noopDispatch(_imsg: ?*c.imsg.imsg, _arg: ?*anyopaque) callconv(.c) void {
    _ = _imsg;
    _ = _arg;
}

fn buildImsg(msg_type: u32, payload: []const u8) c.imsg.imsg {
    return .{
        .hdr = .{
            .type = msg_type,
            .len = @as(u32, @intCast(@sizeOf(c.imsg.imsg_hdr) + payload.len)),
            .peerid = protocol.PROTOCOL_VERSION,
            .pid = 0,
        },
        .data = if (payload.len == 0) null else @constCast(payload.ptr),
        .buf = null,
    };
}

test "client read handler opens files and streams chunks back to the peer" {
    reset_for_tests();
    defer reset_for_tests();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try tmp.dir.realpathAlloc(xm.allocator, ".");
    defer xm.allocator.free(cwd);
    const path = try std.fmt.allocPrint(xm.allocator, "{s}/client-read.txt", .{cwd});
    defer xm.allocator.free(path);

    const file = try std.fs.createFileAbsolute(path, .{});
    defer file.close();
    try file.writeAll("client-read");

    var pair: [2]i32 = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &pair));

    var proc = T.ZmuxProc{ .name = "file-read-client-test" };
    defer proc.peers.deinit(xm.allocator);

    const peer = proc_mod.proc_add_peer(&proc, pair[0], noopDispatch, null);
    defer {
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

    var open_payload = std.ArrayList(u8){};
    defer open_payload.deinit(xm.allocator);
    const open_msg = protocol.MsgReadOpen{
        .stream = 23,
        .fd = -1,
    };
    open_payload.appendSlice(xm.allocator, std.mem.asBytes(&open_msg)) catch unreachable;
    open_payload.appendSlice(xm.allocator, path) catch unreachable;
    open_payload.append(xm.allocator, 0) catch unreachable;

    var open_imsg = buildImsg(@intFromEnum(protocol.MsgType.read_open), open_payload.items);
    client_handle_read_open(peer, &open_imsg, true, false);

    try std.testing.expectEqual(@as(i32, 1), c.imsg.imsgbuf_read(&reader));

    var read_imsg: c.imsg.imsg = undefined;
    try std.testing.expect(c.imsg.imsg_get(&reader, &read_imsg) > 0);
    defer c.imsg.imsg_free(&read_imsg);
    try std.testing.expectEqual(@as(u32, @intCast(@intFromEnum(protocol.MsgType.read))), c.imsg.imsg_get_type(&read_imsg));

    const read_len = c.imsg.imsg_get_len(&read_imsg);
    var read_payload = try xm.allocator.alloc(u8, read_len);
    defer xm.allocator.free(read_payload);
    try std.testing.expectEqual(@as(i32, 0), c.imsg.imsg_get_data(&read_imsg, read_payload.ptr, read_payload.len));

    var read_msg: protocol.MsgReadData = undefined;
    @memcpy(std.mem.asBytes(&read_msg), read_payload[0..@sizeOf(protocol.MsgReadData)]);
    try std.testing.expectEqual(@as(i32, 23), read_msg.stream);
    try std.testing.expectEqualStrings("client-read", read_payload[@sizeOf(protocol.MsgReadData)..]);

    var done_imsg: c.imsg.imsg = undefined;
    if (c.imsg.imsg_get(&reader, &done_imsg) == 0) {
        try std.testing.expectEqual(@as(i32, 1), c.imsg.imsgbuf_read(&reader));
        try std.testing.expect(c.imsg.imsg_get(&reader, &done_imsg) > 0);
    }
    defer c.imsg.imsg_free(&done_imsg);

    try std.testing.expectEqual(@as(u32, @intCast(@intFromEnum(protocol.MsgType.read_done))), c.imsg.imsg_get_type(&done_imsg));
    const done: *const protocol.MsgReadDone = @ptrCast(@alignCast(done_imsg.data.?));
    try std.testing.expectEqual(@as(i32, 23), done.stream);
    try std.testing.expectEqual(@as(i32, 0), done.@"error");
}
