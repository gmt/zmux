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
//   ISC licence – same terms as above.

const std = @import("std");
const c = @import("c.zig");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const cmdq = @import("cmd-queue.zig");
const proc_mod = @import("proc.zig");
const protocol = @import("zmux-protocol.zig");
const file_mod = @import("file.zig");

const max_imsg_payload = c.imsg.MAX_IMSGSIZE - c.imsg.IMSG_HEADER_SIZE - @sizeOf(protocol.MsgWriteData);

const PendingWrite = struct {
    stream: i32,
    client: *T.Client,
    item: *cmdq.CmdqItem,
    path: []u8,
    data: []u8,
    flags: c_int,
};

var next_stream: i32 = 3;
var pending_writes: std.AutoHashMap(i32, *PendingWrite) = undefined;
var pending_writes_init = false;

var client_write_files: T.ClientFiles = undefined;
var client_write_files_init = false;

fn ensure_pending_writes() void {
    if (pending_writes_init) return;
    pending_writes = std.AutoHashMap(i32, *PendingWrite).init(xm.allocator);
    pending_writes_init = true;
}

fn ensure_client_write_files() void {
    if (client_write_files_init) return;
    client_write_files = T.ClientFiles.init(xm.allocator);
    client_write_files_init = true;
}

const set_nonblocking = file_mod.setNonblocking;

fn write_errno_path(item: *cmdq.CmdqItem, errno_value: c_int, path: []const u8) void {
    const err = std.mem.span(c.posix_sys.strerror(errno_value));
    cmdq.cmdq_error(item, "{s}: {s}", .{ err, path });
}

fn free_pending_write(pending: *PendingWrite) void {
    xm.allocator.free(pending.path);
    xm.allocator.free(pending.data);
    xm.allocator.destroy(pending);
}

fn finish_pending_write(pending: *PendingWrite, maybe_errno: ?c_int) void {
    _ = pending_writes.remove(pending.stream);
    if (maybe_errno) |errno_value| write_errno_path(pending.item, errno_value, pending.path);
    cmdq.cmdq_continue(pending.item);
    free_pending_write(pending);
}

fn send_pending_write_data(pending: *PendingWrite) void {
    const peer = pending.client.peer orelse {
        finish_pending_write(pending, @intFromEnum(std.posix.E.PIPE));
        return;
    };

    var remaining = pending.data;
    while (remaining.len != 0) {
        const chunk_len = @min(remaining.len, max_imsg_payload);
        var payload = std.ArrayList(u8){};
        defer payload.deinit(xm.allocator);

        const header = protocol.MsgWriteData{ .stream = pending.stream };
        payload.appendSlice(xm.allocator, std.mem.asBytes(&header)) catch unreachable;
        payload.appendSlice(xm.allocator, remaining[0..chunk_len]) catch unreachable;

        if (proc_mod.proc_send(peer, .write, -1, payload.items.ptr, payload.items.len) != 0) {
            finish_pending_write(pending, @intFromEnum(std.posix.E.PIPE));
            return;
        }
        remaining = remaining[chunk_len..];
    }

    const close_msg = protocol.MsgWriteClose{ .stream = pending.stream };
    if (proc_mod.proc_send(peer, .write_close, -1, std.mem.asBytes(&close_msg).ptr, @sizeOf(protocol.MsgWriteClose)) != 0) {
        finish_pending_write(pending, @intFromEnum(std.posix.E.PIPE));
        return;
    }

    finish_pending_write(pending, null);
}

fn client_close_write_file(stream: i32) void {
    if (!client_write_files_init) return;
    const cf = client_write_files.get(stream) orelse return;
    if (cf.event) |bev| {
        c.libevent.bufferevent_free(bev);
        cf.event = null;
    }
    if (cf.fd != -1) {
        _ = c.posix_sys.close(cf.fd);
        cf.fd = -1;
    }
    _ = client_write_files.remove(stream);
    file_mod.fileFree(cf);
}

fn client_parse_write_path(data_len: usize, data_ptr: *const protocol.MsgWriteOpen) []const u8 {
    if (data_len == @sizeOf(protocol.MsgWriteOpen)) return "-";
    const raw: [*]const u8 = @ptrCast(data_ptr);
    return raw[@sizeOf(protocol.MsgWriteOpen) .. data_len - 1];
}

pub fn start_remote_write(
    item: *cmdq.CmdqItem,
    client: *T.Client,
    path: []const u8,
    flags: c_int,
    data: []const u8,
) T.CmdRetval {
    const peer = client.peer orelse {
        write_errno_path(item, @intFromEnum(std.posix.E.BADF), path);
        return .@"error";
    };

    ensure_pending_writes();

    const stream = next_stream;
    next_stream += 1;

    const pending = xm.allocator.create(PendingWrite) catch unreachable;
    pending.* = .{
        .stream = stream,
        .client = client,
        .item = item,
        .path = xm.xstrdup(path),
        .data = xm.allocator.alloc(u8, data.len) catch unreachable,
        .flags = flags,
    };
    @memcpy(pending.data, data);
    pending_writes.put(stream, pending) catch unreachable;

    var payload = std.ArrayList(u8){};
    defer payload.deinit(xm.allocator);

    const open_msg = protocol.MsgWriteOpen{
        .stream = stream,
        .fd = if (std.mem.eql(u8, path, "-")) std.posix.STDOUT_FILENO else -1,
        .flags = flags,
    };
    payload.appendSlice(xm.allocator, std.mem.asBytes(&open_msg)) catch unreachable;
    payload.appendSlice(xm.allocator, path) catch unreachable;
    payload.append(xm.allocator, 0) catch unreachable;

    if (proc_mod.proc_send(peer, .write_open, -1, payload.items.ptr, payload.items.len) != 0) {
        finish_pending_write(pending, @intFromEnum(std.posix.E.PIPE));
        return .@"error";
    }
    return .wait;
}

pub fn handle_write_ready(imsg_msg: *c.imsg.imsg) void {
    ensure_pending_writes();

    const data_len = imsg_msg.hdr.len -% @sizeOf(c.imsg.imsg_hdr);
    if (data_len != @sizeOf(protocol.MsgWriteReady) or imsg_msg.data == null) return;

    const msg: *const protocol.MsgWriteReady = @ptrCast(@alignCast(imsg_msg.data.?));
    const pending = pending_writes.get(msg.stream) orelse return;

    if (msg.@"error" != 0) {
        finish_pending_write(pending, msg.@"error");
        return;
    }
    send_pending_write_data(pending);
}

pub fn fail_pending_writes_for_client(client: *T.Client) void {
    if (!pending_writes_init) return;

    var doomed = std.ArrayList(i32){};
    defer doomed.deinit(xm.allocator);

    var it = pending_writes.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.*.client == client) doomed.append(xm.allocator, entry.key_ptr.*) catch unreachable;
    }

    for (doomed.items) |stream| {
        const pending = pending_writes.get(stream) orelse continue;
        finish_pending_write(pending, @intFromEnum(std.posix.E.PIPE));
    }
}

pub fn client_handle_write_open(peer: *T.ZmuxPeer, imsg_msg: *c.imsg.imsg, allow_streams: bool, close_received: bool) void {
    ensure_client_write_files();

    const data_len = imsg_msg.hdr.len -% @sizeOf(c.imsg.imsg_hdr);
    if (data_len < @sizeOf(protocol.MsgWriteOpen) or imsg_msg.data == null) return;

    const msg: *const protocol.MsgWriteOpen = @ptrCast(@alignCast(imsg_msg.data.?));
    const path = client_parse_write_path(data_len, msg);
    var reply = protocol.MsgWriteReady{
        .stream = msg.stream,
        .@"error" = 0,
    };

    if (client_write_files.contains(msg.stream)) {
        reply.@"error" = @intFromEnum(std.posix.E.BADF);
        _ = proc_mod.proc_send(peer, .write_ready, -1, std.mem.asBytes(&reply).ptr, @sizeOf(protocol.MsgWriteReady));
        return;
    }

    var fd: i32 = -1;
    if (msg.fd == -1) {
        const path_z = xm.xm_dupeZ(path);
        defer xm.allocator.free(path_z);
        fd = c.posix_sys.open(path_z, c.posix_sys.O_NONBLOCK | c.posix_sys.O_WRONLY | c.posix_sys.O_CREAT | msg.flags, @as(c.posix_sys.mode_t, 0o644));
    } else if (allow_streams and (msg.fd == std.posix.STDOUT_FILENO or msg.fd == std.posix.STDERR_FILENO)) {
        fd = c.posix_sys.dup(msg.fd);
        if (fd != -1 and close_received) _ = c.posix_sys.close(msg.fd);
    } else {
        std.c._errno().* = @intFromEnum(std.posix.E.BADF);
    }

    if (fd == -1) {
        reply.@"error" = std.c._errno().*;
        _ = proc_mod.proc_send(peer, .write_ready, -1, std.mem.asBytes(&reply).ptr, @sizeOf(protocol.MsgWriteReady));
        return;
    }

    const cf = file_mod.createWithPeer(peer, &client_write_files, msg.stream, null, null);
    cf.fd = fd;

    if (proc_mod.libevent) |base| {
        set_nonblocking(fd);
        cf.event = c.libevent.bufferevent_socket_new(base, fd, 0);
        if (cf.event) |bev| {
            c.libevent.bufferevent_setcb(
                bev,
                null,
                file_mod.fileWriteCallback,
                file_mod.fileWriteErrorCallback,
                cf,
            );
            _ = c.libevent.bufferevent_enable(bev, c.libevent.EV_WRITE);
        }
    }

    _ = proc_mod.proc_send(peer, .write_ready, -1, std.mem.asBytes(&reply).ptr, @sizeOf(protocol.MsgWriteReady));
}

pub fn client_handle_write_data(imsg_msg: *c.imsg.imsg) void {
    if (!client_write_files_init) return;

    const data_len = imsg_msg.hdr.len -% @sizeOf(c.imsg.imsg_hdr);
    if (data_len < @sizeOf(protocol.MsgWriteData) or imsg_msg.data == null) return;

    const msg: *const protocol.MsgWriteData = @ptrCast(@alignCast(imsg_msg.data.?));
    const cf = client_write_files.get(msg.stream) orelse return;
    const raw: [*]const u8 = @ptrCast(imsg_msg.data.?);
    const payload = raw[@sizeOf(protocol.MsgWriteData)..data_len];

    if (cf.event) |bev| {
        _ = c.libevent.bufferevent_write(bev, @ptrCast(payload.ptr), payload.len);
    } else {
        var remaining = payload;
        while (remaining.len != 0) {
            const written = c.posix_sys.write(cf.fd, @ptrCast(remaining.ptr), remaining.len);
            if (written == -1) {
                if (std.c._errno().* == @intFromEnum(std.posix.E.INTR)) continue;
                client_close_write_file(msg.stream);
                return;
            }
            if (written == 0) {
                client_close_write_file(msg.stream);
                return;
            }
            remaining = remaining[@as(usize, @intCast(written))..];
        }
    }
}

pub fn client_handle_write_close(imsg_msg: *c.imsg.imsg) void {
    if (!client_write_files_init) return;

    const data_len = imsg_msg.hdr.len -% @sizeOf(c.imsg.imsg_hdr);
    if (data_len != @sizeOf(protocol.MsgWriteClose) or imsg_msg.data == null) return;

    const msg: *const protocol.MsgWriteClose = @ptrCast(@alignCast(imsg_msg.data.?));
    const cf = client_write_files.get(msg.stream) orelse return;

    cf.closed = true;
    if (cf.event) |bev| {
        const output = c.libevent.bufferevent_get_output(bev);
        const pending = if (output != null) c.libevent.evbuffer_get_length(output) else 0;
        if (pending == 0) {
            client_close_write_file(msg.stream);
        }
    } else {
        client_close_write_file(msg.stream);
    }
}

pub fn reset_for_tests() void {
    if (pending_writes_init) {
        var it = pending_writes.valueIterator();
        while (it.next()) |pending_ptr| free_pending_write(pending_ptr.*);
        pending_writes.deinit();
        pending_writes_init = false;
    }

    if (client_write_files_init) {
        var streams_to_close = std.ArrayList(i32){};
        defer streams_to_close.deinit(xm.allocator);
        var it = client_write_files.keyIterator();
        while (it.next()) |key| streams_to_close.append(xm.allocator, key.*) catch unreachable;
        for (streams_to_close.items) |stream| client_close_write_file(stream);
        client_write_files.deinit();
        client_write_files_init = false;
    }

    next_stream = 3;
}

pub fn client_cleanup() void {
    if (!client_write_files_init) return;

    var streams_to_close = std.ArrayList(i32){};
    defer streams_to_close.deinit(xm.allocator);
    var it = client_write_files.keyIterator();
    while (it.next()) |key| streams_to_close.append(xm.allocator, key.*) catch unreachable;
    for (streams_to_close.items) |stream| client_close_write_file(stream);
    client_write_files.deinit();
    client_write_files_init = false;
}

test "file write reset clears state without pending work" {
    reset_for_tests();
    defer reset_for_tests();
}

pub const StressTests = struct {
    pub fn clientWriteHandlersOpenWriteAndCloseFiles() !void {
        reset_for_tests();
        defer reset_for_tests();

        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        const cwd = try tmp.dir.realpathAlloc(xm.allocator, ".");
        defer xm.allocator.free(cwd);
        const path = try std.fmt.allocPrint(xm.allocator, "{s}/client-write.txt", .{cwd});
        defer xm.allocator.free(path);

        var pair: [2]i32 = undefined;
        try std.testing.expectEqual(@as(i32, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &pair));

        var proc = T.ZmuxProc{ .name = "file-write-client-test" };
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
        const open_msg = protocol.MsgWriteOpen{
            .stream = 19,
            .fd = -1,
            .flags = c.posix_sys.O_TRUNC,
        };
        open_payload.appendSlice(xm.allocator, std.mem.asBytes(&open_msg)) catch unreachable;
        open_payload.appendSlice(xm.allocator, path) catch unreachable;
        open_payload.append(xm.allocator, 0) catch unreachable;

        var open_imsg = buildImsg(@intFromEnum(protocol.MsgType.write_open), open_payload.items);
        client_handle_write_open(peer, &open_imsg, true, false);

        try std.testing.expectEqual(@as(i32, 1), c.imsg.imsgbuf_read(&reader));
        var reply_imsg: c.imsg.imsg = undefined;
        try std.testing.expect(c.imsg.imsg_get(&reader, &reply_imsg) > 0);
        defer c.imsg.imsg_free(&reply_imsg);

        const reply: *const protocol.MsgWriteReady = @ptrCast(@alignCast(reply_imsg.data.?));
        try std.testing.expectEqual(@as(i32, 19), reply.stream);
        try std.testing.expectEqual(@as(i32, 0), reply.@"error");

        var data_payload = std.ArrayList(u8){};
        defer data_payload.deinit(xm.allocator);
        const data_msg = protocol.MsgWriteData{ .stream = 19 };
        data_payload.appendSlice(xm.allocator, std.mem.asBytes(&data_msg)) catch unreachable;
        data_payload.appendSlice(xm.allocator, "client-write") catch unreachable;

        var data_imsg = buildImsg(@intFromEnum(protocol.MsgType.write), data_payload.items);
        client_handle_write_data(&data_imsg);

        const close_msg = protocol.MsgWriteClose{ .stream = 19 };
        var close_imsg = buildImsg(@intFromEnum(protocol.MsgType.write_close), std.mem.asBytes(&close_msg));
        client_handle_write_close(&close_imsg);

        const file = try std.fs.openFileAbsolute(path, .{});
        defer file.close();
        const contents = try file.readToEndAlloc(xm.allocator, 1024);
        defer xm.allocator.free(contents);
        try std.testing.expectEqualStrings("client-write", contents);
    }
};

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
