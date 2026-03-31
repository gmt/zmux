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

pub fn getPath(client: ?*T.Client, file: []const u8) []u8 {
    return file_path_mod.file_get_path(client, file);
}

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

// ── Ported from tmux file.c ───────────────────────────────────────────────
//
// The types and functions below mirror the tmux client_file lifecycle.
// Callbacks that require libevent bufferevent (file_push, fire_done via
// event_once, bufferevent read/write callbacks) are stubbed because zmux
// does not yet integrate libevent's bufferevent layer.

const log = @import("log.zig");
const server_client_mod = @import("server-client.zig");
const protocol = @import("zmux-protocol.zig");

pub const ClientFile = T.ClientFile;
pub const ClientFiles = T.ClientFiles;
pub const ClientFileCb = T.ClientFileCb;

var file_next_stream: i32 = 3;

/// Tree comparison function. (tmux: file_cmp)
///
/// Orders ClientFile entries by stream id for use in sorted containers.
pub fn fileCmp(a: *const ClientFile, b: *const ClientFile) std.math.Order {
    return std.math.order(a.stream, b.stream);
}

/// Create a file object in the client process. (tmux: file_create_with_peer)
///
/// The peer is the server to send messages to.  The check callback is fired
/// when the file is finished so the process can decide whether to exit.
pub fn createWithPeer(
    peer: *T.ZmuxPeer,
    files: *ClientFiles,
    stream: i32,
    cb: ClientFileCb,
    cbdata: ?*anyopaque,
) *ClientFile {
    const cf = xm.allocator.create(ClientFile) catch unreachable;
    cf.* = .{
        .client = null,
        .peer = peer,
        .stream = stream,
        .cb = cb,
        .data = cbdata,
        .tree = files,
    };
    files.put(stream, cf) catch unreachable;
    return cf;
}

/// Create a file object in the server. (tmux: file_create_with_client)
///
/// Communicates with the given client.  If the client is attached we
/// clear it so file I/O falls back to direct server-side access.
pub fn createWithClient(
    client_in: ?*T.Client,
    stream: i32,
    cb: ClientFileCb,
    cbdata: ?*anyopaque,
) *ClientFile {
    var cl = client_in;
    if (cl) |cc| {
        if (cc.flags & T.CLIENT_ATTACHED != 0) cl = null;
    }

    const cf = xm.allocator.create(ClientFile) catch unreachable;
    cf.* = .{
        .client = cl,
        .stream = stream,
        .cb = cb,
        .data = cbdata,
    };

    if (cl) |cc| {
        cf.peer = cc.peer;
    }

    return cf;
}

/// Free a file object. (tmux: file_free)
///
/// Reference-counted; the file is only freed when the last reference is
/// released.
pub fn fileFree(cf: *ClientFile) void {
    cf.references -|= 1;
    if (cf.references != 0) return;

    cf.buffer.deinit(xm.allocator);
    if (cf.path) |p| xm.allocator.free(p);

    if (cf.tree) |tree| _ = tree.remove(cf.stream);
    if (cf.client) |cl| server_client_mod.server_client_unref(cl);

    xm.allocator.destroy(cf);
}

/// Fire the done callback directly. (tmux: file_fire_done_cb)
///
/// In tmux this is an event_once timeout callback.  We invoke it
/// synchronously since zmux does not yet use libevent event_once.
pub fn fireDoneCb(cf: *ClientFile) void {
    if (cf.cb) |cb| {
        if (cf.closed or cf.client == null) {
            cb(cf.client, if (cf.path) |p| p else null, cf.@"error", 1, cf.buffer.items, cf.data);
        }
    }
    fileFree(cf);
}

/// Schedule the done callback. (tmux: file_fire_done)
///
/// In tmux this uses event_once(-1, EV_TIMEOUT, ...) for deferred
/// execution.  Without libevent integration we call it synchronously.
pub fn fireDone(cf: *ClientFile) void {
    fireDoneCb(cf);
}

/// Fire the read callback. (tmux: file_fire_read)
pub fn fireRead(cf: *ClientFile) void {
    if (cf.cb) |cb| {
        cb(cf.client, if (cf.path) |p| p else null, cf.@"error", 0, cf.buffer.items, cf.data);
    }
}

/// Check whether a client can be printed to. (tmux: file_can_print)
///
/// Returns true only for connected, unattached, non-control clients.
pub fn canPrint(client: ?*T.Client) bool {
    const cl = client orelse return false;
    if (cl.flags & T.CLIENT_ATTACHED != 0) return false;
    if (cl.flags & T.CLIENT_CONTROL != 0) return false;
    return true;
}

/// Print formatted text to a client's stdout stream (tmux `file_vprint` / `file_print`).
///
/// Uses stream 1 (stdout).  Sends MSG_WRITE_OPEN on first use; subsequent
/// calls push buffered data.
pub fn file_vprint(client: ?*T.Client, comptime fmt: []const u8, args: anytype) void {
    if (!canPrint(client)) return;
    const text = std.fmt.allocPrint(xm.allocator, fmt, args) catch return;
    defer xm.allocator.free(text);
    printToStream(client.?, 1, text, std.posix.STDOUT_FILENO);
}

/// Print formatted text to a client's stdout stream. (tmux: file_print)
pub fn filePrint(client: ?*T.Client, comptime fmt: []const u8, args: anytype) void {
    file_vprint(client, fmt, args);
}

/// Print a raw buffer to a client's stdout stream. (tmux: file_print_buffer)
pub fn printBuffer(client: ?*T.Client, data: []const u8) void {
    if (!canPrint(client)) return;
    printToStream(client.?, 1, data, std.posix.STDOUT_FILENO);
}

/// Report an error to a client's stderr stream. (tmux: file_error)
///
/// Uses stream 2 (stderr).
pub fn fileError(client: ?*T.Client, comptime fmt: []const u8, args: anytype) void {
    if (!canPrint(client)) return;
    const text = std.fmt.allocPrint(xm.allocator, fmt, args) catch return;
    defer xm.allocator.free(text);
    printToStream(client.?, 2, text, std.posix.STDERR_FILENO);
}

fn printToStream(client: *T.Client, stream: i32, data: []const u8, fd_hint: i32) void {
    const peer = client.peer orelse return;

    var payload = std.ArrayList(u8){};
    defer payload.deinit(xm.allocator);

    const open_msg = protocol.MsgWriteOpen{
        .stream = stream,
        .fd = fd_hint,
        .flags = 0,
    };
    payload.appendSlice(xm.allocator, std.mem.asBytes(&open_msg)) catch return;
    payload.appendSlice(xm.allocator, "-") catch return;
    payload.append(xm.allocator, 0) catch return;

    if (proc_mod.proc_send(peer, .write_open, -1, payload.items.ptr, payload.items.len) != 0)
        return;

    var remaining = data;
    while (remaining.len != 0) {
        const chunk_len = @min(remaining.len, max_stream_payload);
        var dpayload = std.ArrayList(u8){};
        defer dpayload.deinit(xm.allocator);

        const header = protocol.MsgWriteData{ .stream = stream };
        dpayload.appendSlice(xm.allocator, std.mem.asBytes(&header)) catch return;
        dpayload.appendSlice(xm.allocator, remaining[0..chunk_len]) catch return;
        if (proc_mod.proc_send(peer, .write, -1, dpayload.items.ptr, dpayload.items.len) != 0)
            return;
        remaining = remaining[chunk_len..];
    }

    const close_msg = protocol.MsgWriteClose{ .stream = stream };
    _ = proc_mod.proc_send(peer, .write_close, -1, std.mem.asBytes(&close_msg).ptr, @sizeOf(protocol.MsgWriteClose));
}

/// Cancel a pending file read. (tmux: file_cancel)
///
/// Sends MSG_READ_CANCEL to the peer and marks the file as closed.
pub fn fileCancel(cf: *ClientFile) void {
    log.log_debug("read cancel file {d}", .{cf.stream});

    if (cf.closed) return;
    cf.closed = true;

    if (cf.peer) |peer| {
        const msg = protocol.MsgReadCancel{ .stream = cf.stream };
        _ = proc_mod.proc_send(peer, .read_cancel, -1, std.mem.asBytes(&msg).ptr, @sizeOf(protocol.MsgReadCancel));
    }
}

/// Push unwritten data to the client for a file. (tmux: file_push)
///
/// Stub: In tmux this drains the evbuffer by sending MSG_WRITE chunks
/// and uses event_once for retry.  Full implementation requires libevent
/// bufferevent integration.
pub fn filePush(cf: *ClientFile) void {
    const peer = cf.peer orelse return;

    while (cf.buffer.items.len != 0) {
        const left = cf.buffer.items.len;
        const sent = @min(left, max_stream_payload);

        var payload = std.ArrayList(u8){};
        defer payload.deinit(xm.allocator);

        const header = protocol.MsgWriteData{ .stream = cf.stream };
        payload.appendSlice(xm.allocator, std.mem.asBytes(&header)) catch break;
        payload.appendSlice(xm.allocator, cf.buffer.items[0..sent]) catch break;
        if (proc_mod.proc_send(peer, .write, -1, payload.items.ptr, payload.items.len) != 0)
            break;

        std.mem.copyForwards(u8, cf.buffer.items[0 .. cf.buffer.items.len - sent], cf.buffer.items[sent..]);
        cf.buffer.items.len -= sent;

        log.log_debug("file {d} sent {d}, left {d}", .{ cf.stream, sent, cf.buffer.items.len });
    }

    if (cf.buffer.items.len != 0) {
        cf.references += 1;
        log.log_debug("file {d} push deferred, {d} bytes remain", .{ cf.stream, cf.buffer.items.len });
    } else if (cf.stream > 2) {
        const close_msg = protocol.MsgWriteClose{ .stream = cf.stream };
        _ = proc_mod.proc_send(peer, .write_close, -1, std.mem.asBytes(&close_msg).ptr, @sizeOf(protocol.MsgWriteClose));
        fireDone(cf);
    }
}

/// Push callback, fired if there is more writing to do. (tmux: file_push_cb)
///
/// Stub: requires libevent event_once for deferred scheduling.
pub fn filePushCb(cf: *ClientFile) void {
    if (cf.client == null) {
        filePush(cf);
    }
    fileFree(cf);
}

/// Check if any files have data left to write. (tmux: file_write_left)
///
/// Iterates the file tree and returns true if any file still has pending
/// output data.
pub fn writeLeft(files: *ClientFiles) bool {
    var it = files.valueIterator();
    while (it.next()) |cf_ptr| {
        const cf = cf_ptr.*;
        if (cf.buffer.items.len != 0) {
            log.log_debug("file {d} {d} bytes left", .{ cf.stream, cf.buffer.items.len });
            return true;
        }
    }
    return false;
}

/// Client file write error callback. (tmux: file_write_error_callback)
///
/// Stub: requires libevent bufferevent.  Logs the error and cleans up
/// the fd.
pub fn fileWriteErrorCallback(cf: *ClientFile) void {
    log.log_debug("write error file {d}", .{cf.stream});

    if (cf.fd != -1) {
        _ = c.posix_sys.close(cf.fd);
        cf.fd = -1;
    }

    if (cf.cb) |cb| cb(null, null, 0, -1, null, cf.data);
}

/// Client file write callback. (tmux: file_write_callback)
///
/// Stub: requires libevent bufferevent.  Fires the check callback and
/// cleans up when all data has been written.
pub fn fileWriteCallback(cf: *ClientFile) void {
    log.log_debug("write check file {d}", .{cf.stream});

    if (cf.cb) |cb| cb(null, null, 0, -1, null, cf.data);

    if (cf.closed and cf.buffer.items.len == 0) {
        if (cf.fd != -1) {
            _ = c.posix_sys.close(cf.fd);
            cf.fd = -1;
        }
        if (cf.tree) |tree| _ = tree.remove(cf.stream);
        fileFree(cf);
    }
}

/// Client file read error callback. (tmux: file_read_error_callback)
///
/// Stub: requires libevent bufferevent.  Sends MSG_READ_DONE and cleans
/// up the fd.
pub fn fileReadErrorCallback(cf: *ClientFile) void {
    log.log_debug("read error file {d}", .{cf.stream});

    if (cf.peer) |peer| {
        const msg = protocol.MsgReadDone{
            .stream = cf.stream,
            .@"error" = 0,
        };
        _ = proc_mod.proc_send(peer, .read_done, -1, std.mem.asBytes(&msg).ptr, @sizeOf(protocol.MsgReadDone));
    }

    if (cf.fd != -1) {
        _ = c.posix_sys.close(cf.fd);
        cf.fd = -1;
    }
    if (cf.tree) |tree| _ = tree.remove(cf.stream);
    fileFree(cf);
}

/// Client file read callback. (tmux: file_read_callback)
///
/// Stub: requires libevent bufferevent.  Reads data from the
/// bufferevent input and sends MSG_READ chunks to the peer.
pub fn fileReadCallback(cf: *ClientFile) void {
    log.log_debug("read callback file {d} (stub)", .{cf.stream});
}

// ── tmux `file.c` entry-point names (server/client imsg dispatch) ─────────

/// Server: append read payload to the pending client file (tmux `file_read_data`).
pub fn file_read_data(files: *ClientFiles, imsg_msg: *c.imsg.imsg) void {
    _ = files;
    handleReadData(imsg_msg);
}

/// Server: finish a remote read (tmux `file_read_done`).
pub fn file_read_done(files: *ClientFiles, imsg_msg: *c.imsg.imsg) void {
    _ = files;
    handleReadDone(imsg_msg);
}

/// Server: write-ready notification from client (tmux `file_write_ready`).
pub fn file_write_ready(files: *ClientFiles, imsg_msg: *c.imsg.imsg) void {
    _ = files;
    handleWriteReady(imsg_msg);
}

/// Client: open a read stream (tmux `file_read_open`).
pub fn file_read_open(
    files: *ClientFiles,
    peer: *T.ZmuxPeer,
    imsg_msg: *c.imsg.imsg,
    allow_streams: bool,
    close_received: bool,
    cb: ClientFileCb,
    cbdata: ?*anyopaque,
) void {
    _ = files;
    _ = cb;
    _ = cbdata;
    file_read_mod.client_handle_read_open(peer, imsg_msg, allow_streams, close_received);
}

/// Client: cancel a read (tmux `file_read_cancel`).
pub fn file_read_cancel(files: *ClientFiles, imsg_msg: *c.imsg.imsg) void {
    _ = files;
    file_read_mod.client_handle_read_cancel(imsg_msg);
}

/// Client: open a write stream (tmux `file_write_open`).
pub fn file_write_open(
    files: *ClientFiles,
    peer: *T.ZmuxPeer,
    imsg_msg: *c.imsg.imsg,
    allow_streams: bool,
    close_received: bool,
    cb: ClientFileCb,
    cbdata: ?*anyopaque,
) void {
    _ = files;
    _ = cb;
    _ = cbdata;
    file_write_mod.client_handle_write_open(peer, imsg_msg, allow_streams, close_received);
}

/// Client: write payload to an open stream (tmux `file_write_data`).
pub fn file_write_data(files: *ClientFiles, imsg_msg: *c.imsg.imsg) void {
    _ = files;
    file_write_mod.client_handle_write_data(imsg_msg);
}

/// Client: close a write stream (tmux `file_write_close`).
pub fn file_write_close(files: *ClientFiles, imsg_msg: *c.imsg.imsg) void {
    _ = files;
    file_write_mod.client_handle_write_close(imsg_msg);
}

/// Allocate the next stream id. (helper for file_write / file_read)
pub fn nextStream() i32 {
    const s = file_next_stream;
    file_next_stream += 1;
    return s;
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
        .status = .{},
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
