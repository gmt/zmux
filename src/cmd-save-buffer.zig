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
// Ported in part from tmux/cmd-save-buffer.c.
// Original copyright:
//   Copyright (c) 2009 Tiago Cunha <me@tiagocunha.org>
//   ISC licence – same terms as above.

const std = @import("std");
const c = @import("c.zig");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const cmd_mod = @import("cmd.zig");
const cmdq = @import("cmd-queue.zig");
const file_path_mod = @import("file-path.zig");
const paste_mod = @import("paste.zig");
const proc_mod = @import("proc.zig");
const protocol = @import("zmux-protocol.zig");

fn exec(cmd: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {
    const args = cmd_mod.cmd_get_args(cmd);
    const client = cmdq.cmdq_get_client(item);

    const pb = if (args.get('b')) |name|
        paste_mod.paste_get_name(name)
    else
        paste_mod.paste_get_top(null);

    if (pb == null) {
        if (args.get('b')) |name| {
            cmdq.cmdq_error(item, "no buffer {s}", .{name});
        } else {
            cmdq.cmdq_error(item, "no buffers", .{});
        }
        return .@"error";
    }

    const bufdata = paste_mod.paste_buffer_data(pb.?, null);
    if (cmd.entry == &entry_show) {
        if (show_uses_control_output(client)) {
            cmdq.cmdq_print_data(item, bufdata);
            return .normal;
        }
        if (show_needs_view_mode(client)) {
            cmdq.cmdq_error(item, "show-buffer attached-client view mode not supported yet", .{});
            return .@"error";
        }
    }

    const raw_path = if (cmd.entry == &entry_show) xm.xstrdup("-") else file_path_mod.format_path_from_client(item, client, args.value_at(0).?);
    defer xm.allocator.free(raw_path);

    write_buffer(item, client, raw_path, args.has('a'), bufdata) catch return .@"error";
    return .normal;
}

fn show_uses_control_output(client: ?*T.Client) bool {
    if (client == null) return false;
    return (client.?.flags & T.CLIENT_CONTROL) != 0;
}

fn show_needs_view_mode(client: ?*T.Client) bool {
    if (client == null) return false;
    return client.?.session != null;
}

fn write_buffer(
    item: *cmdq.CmdqItem,
    client: ?*T.Client,
    raw_path: []const u8,
    append: bool,
    data: []const u8,
) !void {
    const resolved = file_path_mod.resolve_path(client, raw_path);
    defer if (resolved.owned) xm.allocator.free(@constCast(resolved.path));

    if (std.mem.eql(u8, resolved.path, "-")) {
        if (client == null or (client.?.flags & (T.CLIENT_ATTACHED | T.CLIENT_CONTROL)) != 0) {
            report_errno_path(item, @intFromEnum(std.posix.E.BADF), resolved.path);
            return error.BadFileDescriptor;
        }
        cmdq.cmdq_write_client_data(client, 1, data);
        return;
    }

    const path_z = xm.xm_dupeZ(resolved.path);
    defer xm.allocator.free(path_z);

    const open_flags: c_int = c.posix_sys.O_WRONLY |
        c.posix_sys.O_CREAT |
        if (append) c.posix_sys.O_APPEND else c.posix_sys.O_TRUNC;
    const fd = c.posix_sys.open(path_z, open_flags, @as(c.posix_sys.mode_t, 0o666));
    if (fd == -1) {
        report_last_errno_path(item, resolved.path);
        return error.OpenFailed;
    }
    defer _ = c.posix_sys.close(fd);

    var remaining = data;
    while (remaining.len != 0) {
        const wrote = c.posix_sys.write(fd, @ptrCast(remaining.ptr), remaining.len);
        if (wrote == -1) {
            if (std.c._errno().* == @intFromEnum(std.posix.E.INTR)) continue;
            report_last_errno_path(item, resolved.path);
            return error.WriteFailed;
        }
        if (wrote == 0) {
            report_errno_path(item, @intFromEnum(std.posix.E.IO), resolved.path);
            return error.WriteFailed;
        }
        remaining = remaining[@as(usize, @intCast(wrote))..];
    }
}

fn report_last_errno_path(item: *cmdq.CmdqItem, path: []const u8) void {
    report_errno_path(item, std.c._errno().*, path);
}

fn report_errno_path(item: *cmdq.CmdqItem, errno_value: c_int, path: []const u8) void {
    const err = std.mem.span(c.posix_sys.strerror(errno_value));
    cmdq.cmdq_error(item, "{s}: {s}", .{ err, path });
}

pub const entry: cmd_mod.CmdEntry = .{
    .name = "save-buffer",
    .alias = "saveb",
    .usage = "[-a] [-b buffer-name] path",
    .template = "ab:",
    .lower = 1,
    .upper = 1,
    .flags = T.CMD_AFTERHOOK,
    .exec = exec,
};

pub const entry_show: cmd_mod.CmdEntry = .{
    .name = "show-buffer",
    .alias = "showb",
    .usage = "[-b buffer-name]",
    .template = "b:",
    .lower = 0,
    .upper = 0,
    .flags = T.CMD_AFTERHOOK,
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

test "save-buffer writes and appends a named buffer using client cwd for relative paths" {
    paste_mod.paste_reset_for_tests();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try tmp.dir.realpathAlloc(xm.allocator, ".");
    defer xm.allocator.free(cwd);

    var cause: ?[]u8 = null;
    try std.testing.expectEqual(@as(i32, 0), paste_mod.paste_set(xm.xstrdup("hello"), "named", &cause));

    var env = T.Environ.init(xm.allocator);
    defer env.deinit();

    var client = T.Client{
        .environ = &env,
        .cwd = cwd,
        .tty = undefined,
        .status = .{ .screen = undefined },
    };

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &client, .cmdlist = &list };

    const save = try cmd_mod.cmd_parse_one(&.{ "save-buffer", "-b", "named", "buffer.txt" }, null, &cause);
    defer cmd_mod.cmd_free(save);
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(save, &item));

    const append = try cmd_mod.cmd_parse_one(&.{ "save-buffer", "-a", "-b", "named", "buffer.txt" }, null, &cause);
    defer cmd_mod.cmd_free(append);
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(append, &item));

    const saved_path = try std.fmt.allocPrint(xm.allocator, "{s}/buffer.txt", .{cwd});
    defer xm.allocator.free(saved_path);

    const file = try std.fs.openFileAbsolute(saved_path, .{});
    defer file.close();
    const contents = try file.readToEndAlloc(xm.allocator, 1024);
    defer xm.allocator.free(contents);
    try std.testing.expectEqualStrings("hellohello", contents);
}

test "save-buffer writes a named buffer using session cwd when client cwd is missing" {
    paste_mod.paste_reset_for_tests();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try tmp.dir.realpathAlloc(xm.allocator, ".");
    defer xm.allocator.free(cwd);

    var cause: ?[]u8 = null;
    try std.testing.expectEqual(@as(i32, 0), paste_mod.paste_set(xm.xstrdup("from session cwd"), "named", &cause));

    var env = T.Environ.init(xm.allocator);
    defer env.deinit();
    var session_env = T.Environ.init(xm.allocator);
    defer session_env.deinit();

    const session_name = xm.xstrdup("save-session");
    defer xm.allocator.free(session_name);

    var session = T.Session{
        .id = 1,
        .name = session_name,
        .cwd = cwd,
        .lastw = .{},
        .windows = std.AutoHashMap(i32, *T.Winlink).init(xm.allocator),
        .options = undefined,
        .environ = &session_env,
    };
    defer session.windows.deinit();
    defer session.lastw.deinit(xm.allocator);

    var client = T.Client{
        .environ = &env,
        .tty = undefined,
        .status = .{ .screen = undefined },
        .session = &session,
    };

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &client, .cmdlist = &list };

    const save = try cmd_mod.cmd_parse_one(&.{ "save-buffer", "-b", "named", "buffer.txt" }, null, &cause);
    defer cmd_mod.cmd_free(save);
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(save, &item));

    const saved_path = try std.fmt.allocPrint(xm.allocator, "{s}/buffer.txt", .{cwd});
    defer xm.allocator.free(saved_path);

    const file = try std.fs.openFileAbsolute(saved_path, .{});
    defer file.close();
    const contents = try file.readToEndAlloc(xm.allocator, 1024);
    defer xm.allocator.free(contents);
    try std.testing.expectEqualStrings("from session cwd", contents);
}

test "save-buffer uses the newest automatic buffer when no name is provided" {
    init_options_for_tests();
    defer free_options_for_tests();
    paste_mod.paste_reset_for_tests();
    paste_mod.paste_add(null, xm.xstrdup("older"));
    paste_mod.paste_add(null, xm.xstrdup("newer"));

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

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

    const save = try cmd_mod.cmd_parse_one(&.{ "save-buffer", "buffer.txt" }, null, &cause);
    defer cmd_mod.cmd_free(save);

    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(save, &item));

    const saved_path = try std.fmt.allocPrint(xm.allocator, "{s}/buffer.txt", .{cwd});
    defer xm.allocator.free(saved_path);

    const file = try std.fs.openFileAbsolute(saved_path, .{});
    defer file.close();
    const contents = try file.readToEndAlloc(xm.allocator, 1024);
    defer xm.allocator.free(contents);
    try std.testing.expectEqualStrings("newer", contents);
}

test "save-buffer expands the output path through the format context" {
    paste_mod.paste_reset_for_tests();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try tmp.dir.realpathAlloc(xm.allocator, ".");
    defer xm.allocator.free(cwd);

    var cause: ?[]u8 = null;
    try std.testing.expectEqual(@as(i32, 0), paste_mod.paste_set(xm.xstrdup("fmt"), "named", &cause));

    var env = T.Environ.init(xm.allocator);
    defer env.deinit();
    var session_env = T.Environ.init(xm.allocator);
    defer session_env.deinit();

    const session_name = xm.xstrdup("fmt-session");
    defer xm.allocator.free(session_name);

    var session = T.Session{
        .id = 1,
        .name = session_name,
        .cwd = cwd,
        .lastw = .{},
        .windows = std.AutoHashMap(i32, *T.Winlink).init(xm.allocator),
        .options = undefined,
        .environ = &session_env,
    };
    defer session.windows.deinit();
    defer session.lastw.deinit(xm.allocator);

    var client = T.Client{
        .environ = &env,
        .tty = undefined,
        .status = .{ .screen = undefined },
        .session = &session,
    };

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &client, .cmdlist = &list };

    const save = try cmd_mod.cmd_parse_one(&.{ "save-buffer", "-b", "named", "#{session_name}.txt" }, null, &cause);
    defer cmd_mod.cmd_free(save);

    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(save, &item));

    const saved_path = try std.fmt.allocPrint(xm.allocator, "{s}/fmt-session.txt", .{cwd});
    defer xm.allocator.free(saved_path);

    const file = try std.fs.openFileAbsolute(saved_path, .{});
    defer file.close();
    const contents = try file.readToEndAlloc(xm.allocator, 1024);
    defer xm.allocator.free(contents);
    try std.testing.expectEqualStrings("fmt", contents);
}

test "show-buffer rejects attached clients until view mode exists" {
    paste_mod.paste_reset_for_tests();

    var cause: ?[]u8 = null;
    try std.testing.expectEqual(@as(i32, 0), paste_mod.paste_set(xm.xstrdup("a\nb"), "named", &cause));

    var env = T.Environ.init(xm.allocator);
    defer env.deinit();

    var session = T.Session{
        .id = 0,
        .name = &.{},
        .cwd = "",
        .lastw = .{},
        .windows = std.AutoHashMap(i32, *T.Winlink).init(xm.allocator),
        .options = undefined,
        .environ = &env,
    };
    defer session.windows.deinit();
    defer session.lastw.deinit(xm.allocator);

    var client = T.Client{
        .environ = &env,
        .tty = undefined,
        .status = .{ .screen = undefined },
        .session = &session,
    };

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &client, .cmdlist = &list };

    const show = try cmd_mod.cmd_parse_one(&.{ "show-buffer", "-b", "named" }, null, &cause);
    defer cmd_mod.cmd_free(show);

    const saved_stderr = try std.posix.dup(std.posix.STDERR_FILENO);
    defer std.posix.close(saved_stderr);

    const pipe_fds = try std.posix.pipe();
    defer std.posix.close(pipe_fds[0]);

    try std.posix.dup2(pipe_fds[1], std.posix.STDERR_FILENO);
    defer std.posix.dup2(saved_stderr, std.posix.STDERR_FILENO) catch {};

    try std.testing.expectEqual(T.CmdRetval.@"error", cmd_mod.cmd_execute(show, &item));
    try std.posix.dup2(saved_stderr, std.posix.STDERR_FILENO);
    std.posix.close(pipe_fds[1]);

    var output: [96]u8 = undefined;
    const got = try std.posix.read(pipe_fds[0], output[0..]);
    try std.testing.expectEqualStrings("show-buffer attached-client view mode not supported yet\n", output[0..got]);
}

test "show-buffer writes stdout for detached clients without sessions" {
    paste_mod.paste_reset_for_tests();

    var cause: ?[]u8 = null;
    try std.testing.expectEqual(@as(i32, 0), paste_mod.paste_set(xm.xstrdup("detached"), "named", &cause));

    var env = T.Environ.init(xm.allocator);
    defer env.deinit();

    var client = T.Client{
        .environ = &env,
        .tty = undefined,
        .status = .{ .screen = undefined },
    };

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &client, .cmdlist = &list };

    const show = try cmd_mod.cmd_parse_one(&.{ "show-buffer", "-b", "named" }, null, &cause);
    defer cmd_mod.cmd_free(show);

    const saved_stdout = try std.posix.dup(std.posix.STDOUT_FILENO);
    defer std.posix.close(saved_stdout);

    const pipe_fds = try std.posix.pipe();
    defer std.posix.close(pipe_fds[0]);

    try std.posix.dup2(pipe_fds[1], std.posix.STDOUT_FILENO);
    defer std.posix.dup2(saved_stdout, std.posix.STDOUT_FILENO) catch {};

    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(show, &item));
    try std.posix.dup2(saved_stdout, std.posix.STDOUT_FILENO);
    std.posix.close(pipe_fds[1]);

    var output: [32]u8 = undefined;
    const got = try std.posix.read(pipe_fds[0], output[0..]);
    try std.testing.expectEqualStrings("detached", output[0..got]);
}

test "save-buffer writes stdout when given dash for detached clients" {
    paste_mod.paste_reset_for_tests();

    var cause: ?[]u8 = null;
    try std.testing.expectEqual(@as(i32, 0), paste_mod.paste_set(xm.xstrdup("stdout-save"), "named", &cause));

    var env = T.Environ.init(xm.allocator);
    defer env.deinit();

    var client = T.Client{
        .environ = &env,
        .tty = undefined,
        .status = .{ .screen = undefined },
    };

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &client, .cmdlist = &list };

    const save = try cmd_mod.cmd_parse_one(&.{ "save-buffer", "-b", "named", "-" }, null, &cause);
    defer cmd_mod.cmd_free(save);

    const saved_stdout = try std.posix.dup(std.posix.STDOUT_FILENO);
    defer std.posix.close(saved_stdout);

    const pipe_fds = try std.posix.pipe();
    defer std.posix.close(pipe_fds[0]);

    try std.posix.dup2(pipe_fds[1], std.posix.STDOUT_FILENO);
    defer std.posix.dup2(saved_stdout, std.posix.STDOUT_FILENO) catch {};

    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(save, &item));
    try std.posix.dup2(saved_stdout, std.posix.STDOUT_FILENO);
    std.posix.close(pipe_fds[1]);

    var output: [32]u8 = undefined;
    const got = try std.posix.read(pipe_fds[0], output[0..]);
    try std.testing.expectEqualStrings("stdout-save", output[0..got]);
}

test "save-buffer writes dash output over the peer transport for detached clients" {
    paste_mod.paste_reset_for_tests();

    var cause: ?[]u8 = null;
    try std.testing.expectEqual(@as(i32, 0), paste_mod.paste_set(xm.xstrdup("peer-save"), "named", &cause));

    var env = T.Environ.init(xm.allocator);
    defer env.deinit();

    var pair: [2]i32 = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &pair));

    var proc = T.ZmuxProc{ .name = "save-buffer-test-detached-peer" };
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

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &client, .cmdlist = &list };

    const save = try cmd_mod.cmd_parse_one(&.{ "save-buffer", "-b", "named", "-" }, null, &cause);
    defer cmd_mod.cmd_free(save);

    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(save, &item));
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
    try std.testing.expectEqualStrings("peer-save", payload[@sizeOf(i32)..]);
}

test "save-buffer reports bad file descriptor for dash on attached clients" {
    paste_mod.paste_reset_for_tests();

    var cause: ?[]u8 = null;
    try std.testing.expectEqual(@as(i32, 0), paste_mod.paste_set(xm.xstrdup("attached-save"), "named", &cause));

    var env = T.Environ.init(xm.allocator);
    defer env.deinit();

    var client = T.Client{
        .environ = &env,
        .flags = T.CLIENT_ATTACHED,
        .tty = undefined,
        .status = .{ .screen = undefined },
    };

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &client, .cmdlist = &list };

    const save = try cmd_mod.cmd_parse_one(&.{ "save-buffer", "-b", "named", "-" }, null, &cause);
    defer cmd_mod.cmd_free(save);

    const saved_stderr = try std.posix.dup(std.posix.STDERR_FILENO);
    defer std.posix.close(saved_stderr);

    const pipe_fds = try std.posix.pipe();
    defer std.posix.close(pipe_fds[0]);

    try std.posix.dup2(pipe_fds[1], std.posix.STDERR_FILENO);
    defer std.posix.dup2(saved_stderr, std.posix.STDERR_FILENO) catch {};

    try std.testing.expectEqual(T.CmdRetval.@"error", cmd_mod.cmd_execute(save, &item));
    try std.posix.dup2(saved_stderr, std.posix.STDERR_FILENO);
    std.posix.close(pipe_fds[1]);

    var output: [64]u8 = undefined;
    const got = try std.posix.read(pipe_fds[0], output[0..]);
    try std.testing.expectEqualStrings("Bad file descriptor: -\n", output[0..got]);
}

test "show-buffer writes raw bytes over the peer transport for control clients" {
    paste_mod.paste_reset_for_tests();

    var cause: ?[]u8 = null;
    try std.testing.expectEqual(@as(i32, 0), paste_mod.paste_set(xm.xstrdup("peer-data"), "named", &cause));

    var env = T.Environ.init(xm.allocator);
    defer env.deinit();

    var pair: [2]i32 = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &pair));

    var proc = T.ZmuxProc{ .name = "save-buffer-test-peer" };
    defer proc.peers.deinit(xm.allocator);

    var client = T.Client{
        .environ = &env,
        .flags = T.CLIENT_CONTROL,
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

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &client, .cmdlist = &list };

    const show = try cmd_mod.cmd_parse_one(&.{ "show-buffer", "-b", "named" }, null, &cause);
    defer cmd_mod.cmd_free(show);

    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(show, &item));
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
    try std.testing.expectEqualStrings("peer-data", payload[@sizeOf(i32)..]);
}

test "save-buffer reports strerror text for write failures" {
    paste_mod.paste_reset_for_tests();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try tmp.dir.realpathAlloc(xm.allocator, ".");
    defer xm.allocator.free(cwd);

    var cause: ?[]u8 = null;
    try std.testing.expectEqual(@as(i32, 0), paste_mod.paste_set(xm.xstrdup("hello"), "named", &cause));

    var env = T.Environ.init(xm.allocator);
    defer env.deinit();

    var client = T.Client{
        .environ = &env,
        .cwd = cwd,
        .tty = undefined,
        .status = .{ .screen = undefined },
    };

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &client, .cmdlist = &list };

    const save = try cmd_mod.cmd_parse_one(&.{ "save-buffer", "-b", "named", "missing/buffer.txt" }, null, &cause);
    defer cmd_mod.cmd_free(save);

    const saved_stderr = try std.posix.dup(std.posix.STDERR_FILENO);
    defer std.posix.close(saved_stderr);

    const pipe_fds = try std.posix.pipe();
    defer std.posix.close(pipe_fds[0]);

    try std.posix.dup2(pipe_fds[1], std.posix.STDERR_FILENO);
    defer std.posix.dup2(saved_stderr, std.posix.STDERR_FILENO) catch {};

    try std.testing.expectEqual(T.CmdRetval.@"error", cmd_mod.cmd_execute(save, &item));
    try std.posix.dup2(saved_stderr, std.posix.STDERR_FILENO);
    std.posix.close(pipe_fds[1]);

    var output: [256]u8 = undefined;
    const got = try std.posix.read(pipe_fds[0], output[0..]);
    try std.testing.expect(std.mem.indexOf(u8, output[0..got], "No such file or directory") != null);
    try std.testing.expect(std.mem.indexOf(u8, output[0..got], "FileNotFound") == null);
}
