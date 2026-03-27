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

//! file.zig – shared reduced file read/write helpers over local IO and IPC.

const std = @import("std");
const c = @import("c.zig");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const cmdq = @import("cmd-queue.zig");
const proc_mod = @import("proc.zig");
const file_path_mod = @import("file-path.zig");
const file_read_mod = @import("file-read.zig");
const file_write_mod = @import("file-write.zig");

pub const ResolvedPath = file_path_mod.ResolvedPath;
pub const ReadDoneCallback = file_read_mod.ReadDoneCallback;
pub const RemoteReadStart = file_read_mod.StartResult;

const max_stream_payload = c.imsg.MAX_IMSGSIZE - c.imsg.IMSG_HEADER_SIZE - @sizeOf(i32);

pub const ReadResult = union(enum) {
    data: []u8,
    err: c_int,
};

pub fn formatPathFromClient(item: *cmdq.CmdqItem, client: ?*T.Client, raw_path: []const u8) []u8 {
    return file_path_mod.format_path_from_client(item, client, raw_path);
}

pub fn resolvePath(client: ?*T.Client, raw_path: []const u8) ResolvedPath {
    return file_path_mod.resolve_path(client, raw_path);
}

pub fn shouldUseRemotePathIO(client: ?*T.Client) bool {
    return client != null and client.?.peer != null and (client.?.flags & T.CLIENT_ATTACHED) == 0;
}

pub fn strerror(errno_value: c_int) []const u8 {
    return std.mem.span(c.posix_sys.strerror(errno_value));
}

pub fn sendPeerStream(peer: *T.ZmuxPeer, stream: i32, data: []const u8) bool {
    var remaining = data;
    while (remaining.len != 0) {
        const chunk_len = @min(remaining.len, max_stream_payload);
        var payload = std.ArrayList(u8){};
        defer payload.deinit(xm.allocator);

        payload.appendSlice(xm.allocator, std.mem.asBytes(&stream)) catch return false;
        payload.appendSlice(xm.allocator, remaining[0..chunk_len]) catch return false;
        if (proc_mod.proc_send(peer, .write, -1, payload.items.ptr, payload.items.len) != 0)
            return false;
        remaining = remaining[chunk_len..];
    }
    return true;
}

pub fn reportErrnoPath(item: *cmdq.CmdqItem, errno_value: c_int, path: []const u8) void {
    cmdq.cmdq_error(item, "{s}: {s}", .{ strerror(errno_value), path });
}

pub fn readResolvedPathAlloc(client: ?*T.Client, path: []const u8) ReadResult {
    if (std.mem.eql(u8, path, "-")) {
        if (client == null or (client.?.flags & (T.CLIENT_ATTACHED | T.CLIENT_CONTROL)) != 0)
            return .{ .err = @intFromEnum(std.posix.E.BADF) };
        return readFdAlloc(std.posix.STDIN_FILENO);
    }

    const path_z = xm.xm_dupeZ(path);
    defer xm.allocator.free(path_z);

    const fd = c.posix_sys.open(path_z, c.posix_sys.O_RDONLY, @as(c.posix_sys.mode_t, 0));
    if (fd == -1) return .{ .err = std.c._errno().* };
    defer _ = c.posix_sys.close(fd);

    return readFdAlloc(fd);
}

fn readFdAlloc(fd: i32) ReadResult {
    var out = std.ArrayList(u8){};
    errdefer out.deinit(xm.allocator);

    var buf: [4096]u8 = undefined;
    while (true) {
        const got = c.posix_sys.read(fd, @ptrCast(buf[0..].ptr), buf.len);
        if (got == -1) {
            if (std.c._errno().* == @intFromEnum(std.posix.E.INTR)) continue;
            return .{ .err = std.c._errno().* };
        }
        if (got == 0) break;
        out.appendSlice(xm.allocator, buf[0..@as(usize, @intCast(got))]) catch {
            return .{ .err = @intFromEnum(std.posix.E.NOMEM) };
        };
    }

    const owned = out.toOwnedSlice(xm.allocator) catch {
        return .{ .err = @intFromEnum(std.posix.E.NOMEM) };
    };
    return .{ .data = owned };
}

pub fn writeResolvedPath(
    item: *cmdq.CmdqItem,
    client: ?*T.Client,
    path: []const u8,
    flags: c_int,
    data: []const u8,
) T.CmdRetval {
    if (std.mem.eql(u8, path, "-")) {
        if (client == null or (client.?.flags & (T.CLIENT_ATTACHED | T.CLIENT_CONTROL)) != 0) {
            reportErrnoPath(item, @intFromEnum(std.posix.E.BADF), path);
            return .@"error";
        }
        return file_write_mod.start_remote_write(item, client.?, path, flags, data);
    }

    if (client != null and (client.?.flags & T.CLIENT_ATTACHED) == 0) {
        return file_write_mod.start_remote_write(item, client.?, path, flags, data);
    }

    const path_z = xm.xm_dupeZ(path);
    defer xm.allocator.free(path_z);

    const open_flags: c_int = c.posix_sys.O_WRONLY |
        c.posix_sys.O_CREAT |
        flags;
    const fd = c.posix_sys.open(path_z, open_flags, @as(c.posix_sys.mode_t, 0o666));
    if (fd == -1) {
        reportErrnoPath(item, std.c._errno().*, path);
        return .@"error";
    }
    defer _ = c.posix_sys.close(fd);

    var remaining = data;
    while (remaining.len != 0) {
        const wrote = c.posix_sys.write(fd, @ptrCast(remaining.ptr), remaining.len);
        if (wrote == -1) {
            if (std.c._errno().* == @intFromEnum(std.posix.E.INTR)) continue;
            reportErrnoPath(item, std.c._errno().*, path);
            return .@"error";
        }
        if (wrote == 0) {
            reportErrnoPath(item, @intFromEnum(std.posix.E.IO), path);
            return .@"error";
        }
        remaining = remaining[@as(usize, @intCast(wrote))..];
    }

    return .normal;
}

pub fn startRemoteRead(client: *T.Client, path: []const u8, callback: ReadDoneCallback, cbdata: ?*anyopaque) RemoteReadStart {
    return file_read_mod.start_remote_read(client, path, callback, cbdata);
}

pub fn handleReadData(imsg_msg: *c.imsg.imsg) void {
    file_read_mod.handle_read_data(imsg_msg);
}

pub fn handleReadDone(imsg_msg: *c.imsg.imsg) void {
    file_read_mod.handle_read_done(imsg_msg);
}

pub fn handleWriteReady(imsg_msg: *c.imsg.imsg) void {
    file_write_mod.handle_write_ready(imsg_msg);
}

pub fn failPendingReadsForClient(client: *T.Client) void {
    file_read_mod.fail_pending_reads_for_client(client);
}

pub fn failPendingWritesForClient(client: *T.Client) void {
    file_write_mod.fail_pending_writes_for_client(client);
}

pub fn clientHandleReadOpen(peer: *T.ZmuxPeer, imsg_msg: *c.imsg.imsg, allow_streams: bool, close_received: bool) void {
    file_read_mod.client_handle_read_open(peer, imsg_msg, allow_streams, close_received);
}

pub fn clientHandleReadCancel(imsg_msg: *c.imsg.imsg) void {
    file_read_mod.client_handle_read_cancel(imsg_msg);
}

pub fn clientHandleWriteOpen(peer: *T.ZmuxPeer, imsg_msg: *c.imsg.imsg, allow_streams: bool, close_received: bool) void {
    file_write_mod.client_handle_write_open(peer, imsg_msg, allow_streams, close_received);
}

pub fn clientHandleWriteData(imsg_msg: *c.imsg.imsg) void {
    file_write_mod.client_handle_write_data(imsg_msg);
}

pub fn clientHandleWriteClose(imsg_msg: *c.imsg.imsg) void {
    file_write_mod.client_handle_write_close(imsg_msg);
}

pub fn resetForTests() void {
    file_read_mod.reset_for_tests();
    file_write_mod.reset_for_tests();
}

pub fn clientCleanup() void {
    file_read_mod.client_cleanup();
    file_write_mod.client_cleanup();
}

test "readResolvedPathAlloc reads stdin for reduced detached consumers" {
    const saved_stdin = try std.posix.dup(std.posix.STDIN_FILENO);
    defer {
        std.posix.dup2(saved_stdin, std.posix.STDIN_FILENO) catch {};
        std.posix.close(saved_stdin);
    }

    const pipe_fds = try std.posix.pipe();

    try std.posix.dup2(pipe_fds[0], std.posix.STDIN_FILENO);
    std.posix.close(pipe_fds[0]);
    _ = try std.posix.write(pipe_fds[1], "source stdin\n");
    std.posix.close(pipe_fds[1]);

    var env = T.Environ.init(xm.allocator);
    defer env.deinit();
    var client = T.Client{
        .environ = &env,
        .tty = undefined,
        .status = .{ .screen = undefined },
    };

    switch (readResolvedPathAlloc(&client, "-")) {
        .data => |data| {
            defer xm.allocator.free(data);
            try std.testing.expectEqualStrings("source stdin\n", data);
        },
        .err => |errno_value| return std.posix.unexpectedErrno(@enumFromInt(errno_value)),
    }
}

fn noopDispatch(_imsg: ?*c.imsg.imsg, _arg: ?*anyopaque) callconv(.c) void {
    _ = _imsg;
    _ = _arg;
}

test "sendPeerStream chunks oversized write payloads across imsg boundaries" {
    var pair: [2]i32 = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &pair));

    var proc = T.ZmuxProc{ .name = "file-stream-test" };
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

    const total_len = max_stream_payload * 2 + 17;
    const payload = try xm.allocator.alloc(u8, total_len);
    defer xm.allocator.free(payload);
    for (payload, 0..) |*byte, idx| byte.* = @intCast('a' + @as(u8, @intCast(idx % 26)));

    try std.testing.expect(sendPeerStream(peer, 2, payload));

    var collected: std.ArrayList(u8) = .{};
    defer collected.deinit(xm.allocator);

    var chunks: usize = 0;
    while (collected.items.len < payload.len) {
        var imsg_msg: c.imsg.imsg = undefined;
        const got = c.imsg.imsg_get(&reader, &imsg_msg);
        if (got == 0) {
            try std.testing.expectEqual(@as(i32, 1), c.imsg.imsgbuf_read(&reader));
            continue;
        }
        try std.testing.expect(got > 0);
        defer c.imsg.imsg_free(&imsg_msg);

        const data_len = imsg_msg.hdr.len -% @sizeOf(c.imsg.imsg_hdr);
        try std.testing.expect(data_len > @sizeOf(i32));
        const raw: [*]const u8 = @ptrCast(imsg_msg.data.?);
        const stream: *const i32 = @ptrCast(@alignCast(imsg_msg.data.?));
        try std.testing.expectEqual(@as(i32, 2), stream.*);
        try collected.appendSlice(xm.allocator, raw[@sizeOf(i32)..data_len]);
        chunks += 1;
    }

    try std.testing.expectEqual(@as(usize, 3), chunks);
    try std.testing.expectEqualSlices(u8, payload, collected.items);
}
