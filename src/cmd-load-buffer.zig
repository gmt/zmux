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
// Ported in part from tmux/cmd-load-buffer.c.
// Original copyright:
//   Copyright (c) 2009 Tiago Cunha <me@tiagocunha.org>
//   ISC licence – same terms as above.

const std = @import("std");
const c = @import("c.zig");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const clipboard_mod = @import("clipboard.zig");
const cmd_mod = @import("cmd.zig");
const cmdq = @import("cmd-queue.zig");
const client_registry = @import("client-registry.zig");
const file_mod = @import("file.zig");
const paste_mod = @import("paste.zig");
const proc_mod = @import("proc.zig");
const protocol = @import("zmux-protocol.zig");

const LoadBufferRemoteState = struct {
    item: *cmdq.CmdqItem,
    target_client: ?*T.Client,
    name: ?[]u8,
    export_after_store: bool,
};

fn exec(cmd: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {
    const args = cmd_mod.cmd_get_args(cmd);
    const client = cmdq.cmdq_get_client(item);
    const target_client = cmdq.cmdq_get_target_client(item);
    const raw_path = file_mod.formatPathFromClient(item, client, args.value_at(0).?);
    defer xm.allocator.free(raw_path);

    if (file_mod.shouldUseRemotePathIO(client)) {
        const state = xm.allocator.create(LoadBufferRemoteState) catch unreachable;
        state.* = .{
            .item = item,
            .target_client = target_client,
            .name = if (args.get('b')) |name| xm.xstrdup(name) else null,
            .export_after_store = args.has('w'),
        };

        const resolved = file_mod.resolvePath(client, raw_path);
        defer if (resolved.owned) xm.allocator.free(@constCast(resolved.path));

        return switch (file_mod.startRemoteRead(client.?, resolved.path, load_buffer_done, state)) {
            .wait => .wait,
            .err => |errno_value| blk: {
                free_remote_state(state);
                file_mod.reportErrnoPath(item, errno_value, resolved.path);
                break :blk .@"error";
            },
        };
    }

    const data = read_buffer(item, client, raw_path) catch return .@"error";
    const export_after_store = args.has('w') and data.len != 0;

    var cause: ?[]u8 = null;
    defer if (cause) |msg| xm.allocator.free(msg);

    if (paste_mod.paste_set(data, args.get('b'), &cause) != 0) {
        xm.allocator.free(data);
        cmdq.cmdq_error(item, "{s}", .{cause orelse "load buffer failed"});
        return .@"error";
    }

    if (export_after_store) {
        clipboard_mod.export_selection(target_client, "", data);
    }

    return .normal;
}

fn load_buffer_done(path: []const u8, errno_value: c_int, data: []const u8, cbdata: ?*anyopaque) void {
    const state: *LoadBufferRemoteState = @ptrCast(@alignCast(cbdata orelse return));
    defer free_remote_state(state);

    if (errno_value != 0) {
        file_mod.reportErrnoPath(state.item, errno_value, path);
        cmdq.cmdq_continue(state.item);
        return;
    }

    var cause: ?[]u8 = null;
    defer if (cause) |msg| xm.allocator.free(msg);

    const copy = xm.allocator.alloc(u8, data.len) catch unreachable;
    @memcpy(copy, data);

    if (paste_mod.paste_set(copy, state.name, &cause) != 0) {
        xm.allocator.free(copy);
        cmdq.cmdq_error(state.item, "{s}", .{cause orelse "load buffer failed"});
        cmdq.cmdq_continue(state.item);
        return;
    }

    if (state.export_after_store and data.len != 0) {
        clipboard_mod.export_selection(state.target_client, "", data);
    }

    cmdq.cmdq_continue(state.item);
}

fn free_remote_state(state: *LoadBufferRemoteState) void {
    if (state.name) |name| xm.allocator.free(name);
    xm.allocator.destroy(state);
}

fn read_buffer(item: *cmdq.CmdqItem, client: ?*T.Client, raw_path: []const u8) ![]u8 {
    const resolved = file_mod.resolvePath(client, raw_path);
    defer if (resolved.owned) xm.allocator.free(@constCast(resolved.path));

    return switch (file_mod.readResolvedPathAlloc(client, resolved.path)) {
        .data => |data| data,
        .err => |errno_value| blk: {
            file_mod.reportErrnoPath(item, errno_value, resolved.path);
            break :blk error.ReadFailed;
        },
    };
}

pub const entry: cmd_mod.CmdEntry = .{
    .name = "load-buffer",
    .alias = "loadb",
    .usage = "[-w] [-b buffer-name] [-t target-client] path",
    .template = "b:t:w",
    .lower = 1,
    .upper = 1,
    .flags = T.CMD_AFTERHOOK | T.CMD_CLIENT_TFLAG | T.CMD_CLIENT_CANFAIL,
    .exec = exec,
};

fn init_options_for_tests() void {
    const opts = @import("options.zig");
    opts.global_options = opts.options_create(null);
    opts.global_s_options = opts.options_create(null);
    opts.global_w_options = opts.options_create(null);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
}

fn free_options_for_tests() void {
    const opts = @import("options.zig");
    opts.options_free(opts.global_w_options);
    opts.options_free(opts.global_s_options);
    opts.options_free(opts.global_options);
}

fn test_peer_dispatch(_imsg: ?*c.imsg.imsg, _arg: ?*anyopaque) callconv(.c) void {
    _ = _imsg;
    _ = _arg;
}

test "load-buffer reads a named buffer from a relative path using client cwd" {
    init_options_for_tests();
    defer free_options_for_tests();
    paste_mod.paste_reset_for_tests();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile("buffer.txt", .{});
    defer file.close();
    try file.writeAll("hello from disk");

    const cwd = try tmp.dir.realpathAlloc(xm.allocator, ".");
    defer xm.allocator.free(cwd);

    var env = T.Environ.init(xm.allocator);
    defer env.deinit();

    var client = T.Client{
        .environ = &env,
        .cwd = cwd,
        .tty = undefined,
        .status = .{ .screen = undefined },
    };

    var cause: ?[]u8 = null;
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &client, .cmdlist = &list };

    const load = try cmd_mod.cmd_parse_one(&.{ "load-buffer", "-b", "named", "buffer.txt" }, null, &cause);
    defer cmd_mod.cmd_free(load);

    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(load, &item));
    const pb = paste_mod.paste_get_name("named") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("hello from disk", paste_mod.paste_buffer_data(pb, null));
}

test "load-buffer reads a named buffer from session cwd when client cwd is missing" {
    init_options_for_tests();
    defer free_options_for_tests();
    paste_mod.paste_reset_for_tests();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile("buffer.txt", .{});
    defer file.close();
    try file.writeAll("hello from session cwd");

    const cwd = try tmp.dir.realpathAlloc(xm.allocator, ".");
    defer xm.allocator.free(cwd);

    var env = T.Environ.init(xm.allocator);
    defer env.deinit();
    var session_env = T.Environ.init(xm.allocator);
    defer session_env.deinit();

    const session_name = xm.xstrdup("cwd-session");
    defer xm.allocator.free(session_name);

    var session = T.Session{
        .id = 1,
        .name = session_name,
        .cwd = cwd,
        .options = @import("options.zig").global_s_options,
        .environ = &session_env,
    };

    var client = T.Client{
        .environ = &env,
        .tty = undefined,
        .status = .{ .screen = undefined },
        .session = &session,
    };

    var cause: ?[]u8 = null;
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &client, .cmdlist = &list };

    const load = try cmd_mod.cmd_parse_one(&.{ "load-buffer", "-b", "session-cwd", "buffer.txt" }, null, &cause);
    defer cmd_mod.cmd_free(load);

    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(load, &item));
    const pb = paste_mod.paste_get_name("session-cwd") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("hello from session cwd", paste_mod.paste_buffer_data(pb, null));
}

test "load-buffer reports tmux-style strerror text for read failures" {
    paste_mod.paste_reset_for_tests();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try tmp.dir.realpathAlloc(xm.allocator, ".");
    defer xm.allocator.free(cwd);
    const missing_path = try std.fmt.allocPrint(xm.allocator, "{s}/missing-buffer.txt", .{cwd});
    defer xm.allocator.free(missing_path);

    var cause: ?[]u8 = null;
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };

    const load = try cmd_mod.cmd_parse_one(&.{ "load-buffer", missing_path }, null, &cause);
    defer cmd_mod.cmd_free(load);

    const saved_stderr = try std.posix.dup(std.posix.STDERR_FILENO);
    defer std.posix.close(saved_stderr);

    const pipe_fds = try std.posix.pipe();
    defer std.posix.close(pipe_fds[0]);

    try std.posix.dup2(pipe_fds[1], std.posix.STDERR_FILENO);
    defer std.posix.dup2(saved_stderr, std.posix.STDERR_FILENO) catch {};

    try std.testing.expectEqual(T.CmdRetval.@"error", cmd_mod.cmd_execute(load, &item));
    try std.posix.dup2(saved_stderr, std.posix.STDERR_FILENO);
    std.posix.close(pipe_fds[1]);

    var output: [256]u8 = undefined;
    const got = try std.posix.read(pipe_fds[0], output[0..]);

    const expected = try std.fmt.allocPrint(xm.allocator, "No such file or directory: {s}\n", .{missing_path});
    defer xm.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, output[0..got]);
}

test "load-buffer reads stdin when path is dash" {
    init_options_for_tests();
    defer free_options_for_tests();
    paste_mod.paste_reset_for_tests();
    file_mod.resetForTests();
    defer file_mod.resetForTests();

    var env = T.Environ.init(xm.allocator);
    defer env.deinit();

    var pair: [2]i32 = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &pair));

    var proc = T.ZmuxProc{ .name = "load-buffer-stdin-test" };
    defer proc.peers.deinit(xm.allocator);

    var client = T.Client{
        .environ = &env,
        .tty = undefined,
        .status = .{ .screen = undefined },
    };
    client.peer = proc_mod.proc_add_peer(&proc, pair[0], test_peer_dispatch, null);
    defer {
        const peer = client.peer.?;
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

    var cause: ?[]u8 = null;
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &client, .cmdlist = &list };

    const load = try cmd_mod.cmd_parse_one(&.{ "load-buffer", "-b", "stdin-buffer", "-" }, null, &cause);
    defer cmd_mod.cmd_free(load);

    const saved_stdin = try std.posix.dup(std.posix.STDIN_FILENO);
    defer std.posix.close(saved_stdin);

    const pipe_fds = try std.posix.pipe();
    defer std.posix.close(pipe_fds[0]);

    _ = try std.posix.write(pipe_fds[1], "from stdin");
    std.posix.close(pipe_fds[1]);

    try std.posix.dup2(pipe_fds[0], std.posix.STDIN_FILENO);
    defer std.posix.dup2(saved_stdin, std.posix.STDIN_FILENO) catch {};

    try std.testing.expectEqual(T.CmdRetval.wait, cmd_mod.cmd_execute(load, &item));

    var open_imsg = read_single_peer_imsg(&reader);
    defer c.imsg.imsg_free(&open_imsg);
    try std.testing.expectEqual(@as(u32, @intCast(@intFromEnum(protocol.MsgType.read_open))), c.imsg.imsg_get_type(&open_imsg));

    file_mod.clientHandleReadOpen(client.peer.?, &open_imsg, true, false);

    while (true) {
        var imsg_msg = read_single_peer_imsg(&reader);
        defer c.imsg.imsg_free(&imsg_msg);

        const msg_type = std.meta.intToEnum(protocol.MsgType, imsg_msg.hdr.type) catch unreachable;
        switch (msg_type) {
            .read => file_mod.handleReadData(&imsg_msg),
            .read_done => {
                file_mod.handleReadDone(&imsg_msg);
                break;
            },
            else => unreachable,
        }
    }

    try std.posix.dup2(saved_stdin, std.posix.STDIN_FILENO);

    const pb = paste_mod.paste_get_name("stdin-buffer") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("from stdin", paste_mod.paste_buffer_data(pb, null));
}

test "load-buffer ignores target-client without clipboard export" {
    init_options_for_tests();
    defer free_options_for_tests();
    paste_mod.paste_reset_for_tests();
    client_registry.clients.clearRetainingCapacity();
    defer client_registry.clients.clearRetainingCapacity();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile("buffer.txt", .{});
    defer file.close();
    try file.writeAll("clipboard seam");

    const cwd = try tmp.dir.realpathAlloc(xm.allocator, ".");
    defer xm.allocator.free(cwd);

    var env = T.Environ.init(xm.allocator);
    defer env.deinit();
    var target_env = T.Environ.init(xm.allocator);
    defer target_env.deinit();
    var session_env = T.Environ.init(xm.allocator);
    defer session_env.deinit();

    const session_name = xm.xstrdup("clip-session");
    defer xm.allocator.free(session_name);

    var session = T.Session{
        .id = 1,
        .name = session_name,
        .cwd = "",
        .options = @import("options.zig").global_s_options,
        .environ = &session_env,
    };

    var target = T.Client{
        .name = "clip",
        .environ = &target_env,
        .tty = undefined,
        .status = .{ .screen = undefined },
    };
    target.session = &session;
    client_registry.add(&target);

    var client = T.Client{
        .environ = &env,
        .cwd = cwd,
        .tty = undefined,
        .status = .{ .screen = undefined },
    };

    var cause: ?[]u8 = null;
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &client, .cmdlist = &list };

    const load = try cmd_mod.cmd_parse_one(&.{ "load-buffer", "-t", "clip", "buffer.txt" }, null, &cause);
    defer cmd_mod.cmd_free(load);

    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(load, &item));
    const pb = paste_mod.paste_get_name("buffer0") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("clipboard seam", paste_mod.paste_buffer_data(pb, null));
}

fn read_single_peer_imsg(reader: *c.imsg.imsgbuf) c.imsg.imsg {
    var imsg_msg: c.imsg.imsg = undefined;
    if (c.imsg.imsg_get(reader, &imsg_msg) > 0) return imsg_msg;
    if (c.imsg.imsgbuf_read(reader) != 1) unreachable;
    if (c.imsg.imsg_get(reader, &imsg_msg) <= 0) unreachable;
    return imsg_msg;
}

test "load-buffer write flag is a no-op without a sessionful target client" {
    init_options_for_tests();
    defer free_options_for_tests();
    paste_mod.paste_reset_for_tests();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile("buffer.txt", .{});
    defer file.close();
    try file.writeAll("clipboard seam");

    const cwd = try tmp.dir.realpathAlloc(xm.allocator, ".");
    defer xm.allocator.free(cwd);

    var env = T.Environ.init(xm.allocator);
    defer env.deinit();

    var client = T.Client{
        .environ = &env,
        .cwd = cwd,
        .tty = undefined,
        .status = .{ .screen = undefined },
    };

    var cause: ?[]u8 = null;
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &client, .cmdlist = &list };

    const load = try cmd_mod.cmd_parse_one(&.{ "load-buffer", "-w", "buffer.txt" }, null, &cause);
    defer cmd_mod.cmd_free(load);

    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(load, &item));
    const pb = paste_mod.paste_get_name("buffer0") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("clipboard seam", paste_mod.paste_buffer_data(pb, null));
}

test "load-buffer write flag exports selection for an attached target client" {
    init_options_for_tests();
    defer free_options_for_tests();
    paste_mod.paste_reset_for_tests();
    client_registry.clients.clearRetainingCapacity();
    defer client_registry.clients.clearRetainingCapacity();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile("buffer.txt", .{});
    defer file.close();
    try file.writeAll("clipboard seam");

    const cwd = try tmp.dir.realpathAlloc(xm.allocator, ".");
    defer xm.allocator.free(cwd);

    var env = T.Environ.init(xm.allocator);
    defer env.deinit();
    var target_env = T.Environ.init(xm.allocator);
    defer target_env.deinit();
    var session_env = T.Environ.init(xm.allocator);
    defer session_env.deinit();

    const session_name = xm.xstrdup("clip-session");
    defer xm.allocator.free(session_name);

    var session = T.Session{
        .id = 1,
        .name = session_name,
        .cwd = "",
        .options = @import("options.zig").global_s_options,
        .environ = &session_env,
    };

    var pair: [2]i32 = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &pair));

    var proc = T.ZmuxProc{ .name = "load-buffer-test-peer" };
    defer proc.peers.deinit(xm.allocator);

    var target = T.Client{
        .name = "clip",
        .environ = &target_env,
        .tty = undefined,
        .status = .{ .screen = undefined },
        .flags = T.CLIENT_ATTACHED,
    };
    target.session = &session;
    target.peer = proc_mod.proc_add_peer(&proc, pair[0], test_peer_dispatch, null);
    defer {
        const peer = target.peer.?;
        c.imsg.imsgbuf_clear(&peer.ibuf);
        std.posix.close(peer.ibuf.fd);
        xm.allocator.destroy(peer);
        proc.peers.clearRetainingCapacity();
    }
    client_registry.add(&target);

    var client = T.Client{
        .environ = &env,
        .cwd = cwd,
        .tty = undefined,
        .status = .{ .screen = undefined },
    };

    var cause: ?[]u8 = null;
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &client, .cmdlist = &list };

    var reader: c.imsg.imsgbuf = undefined;
    try std.testing.expectEqual(@as(i32, 0), c.imsg.imsgbuf_init(&reader, pair[1]));
    defer {
        c.imsg.imsgbuf_clear(&reader);
        std.posix.close(pair[1]);
    }

    const load = try cmd_mod.cmd_parse_one(&.{ "load-buffer", "-w", "-t", "clip", "buffer.txt" }, null, &cause);
    defer cmd_mod.cmd_free(load);

    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(load, &item));

    const pb = paste_mod.paste_get_name("buffer0") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("clipboard seam", paste_mod.paste_buffer_data(pb, null));

    try std.testing.expectEqual(@as(i32, 1), c.imsg.imsgbuf_read(&reader));

    var imsg_msg: c.imsg.imsg = undefined;
    try std.testing.expect(c.imsg.imsg_get(&reader, &imsg_msg) > 0);
    defer c.imsg.imsg_free(&imsg_msg);

    try std.testing.expectEqual(@as(u32, @intCast(@intFromEnum(protocol.MsgType.write))), c.imsg.imsg_get_type(&imsg_msg));

    const payload_len = c.imsg.imsg_get_len(&imsg_msg);
    var payload = try xm.allocator.alloc(u8, payload_len);
    defer xm.allocator.free(payload);
    try std.testing.expectEqual(@as(i32, 0), c.imsg.imsg_get_data(&imsg_msg, payload.ptr, payload.len));

    var stream: i32 = 0;
    @memcpy(std.mem.asBytes(&stream), payload[0..@sizeOf(i32)]);
    try std.testing.expectEqual(@as(i32, 1), stream);

    const expected = try clipboard_mod.osc52_sequence(xm.allocator, "", "clipboard seam");
    defer xm.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, payload[@sizeOf(i32)..]);
}
