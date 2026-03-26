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
const format_mod = @import("format.zig");
const paste_mod = @import("paste.zig");
const server_client_mod = @import("server-client.zig");

const ResolvedPath = struct {
    path: []const u8,
    owned: bool = false,
};

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
    if (cmd.entry == &entry_show and show_uses_direct_output(client)) {
        cmdq.cmdq_print_data(item, bufdata);
        return .normal;
    }

    const raw_path = if (cmd.entry == &entry_show) xm.xstrdup("-") else format_path_from_client(item, client, args.value_at(0).?);
    defer xm.allocator.free(raw_path);

    write_buffer(item, client, raw_path, args.has('a'), bufdata) catch return .@"error";
    return .normal;
}

fn show_uses_direct_output(client: ?*T.Client) bool {
    if (client == null) return false;
    return client.?.session != null or (client.?.flags & T.CLIENT_CONTROL) != 0;
}

fn format_path_from_client(item: *cmdq.CmdqItem, client: ?*T.Client, raw_path: []const u8) []u8 {
    const session = if (client) |cl| cl.session else null;
    const winlink = if (session) |s| s.curw else null;
    const pane = if (winlink) |wl| wl.window.active else null;
    return format_mod.format_single(item, raw_path, client, session, winlink, pane);
}

fn resolve_path(client: ?*T.Client, raw_path: []const u8) ResolvedPath {
    if (std.mem.eql(u8, raw_path, "-")) return .{ .path = raw_path };
    if (std.mem.startsWith(u8, raw_path, "~/")) {
        const home = std.posix.getenv("HOME") orelse "";
        return .{ .path = xm.xasprintf("{s}/{s}", .{ home, raw_path[2..] }), .owned = true };
    }
    if (std.mem.startsWith(u8, raw_path, "/")) return .{ .path = raw_path };

    const cwd = server_client_mod.server_client_get_cwd(client, null);
    return .{ .path = xm.xasprintf("{s}/{s}", .{ cwd, raw_path }), .owned = true };
}

fn write_buffer(
    item: *cmdq.CmdqItem,
    client: ?*T.Client,
    raw_path: []const u8,
    append: bool,
    data: []const u8,
) !void {
    const resolved = resolve_path(client, raw_path);
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

test "show-buffer writes raw bytes for attached clients" {
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
    try std.testing.expectEqualStrings("a\nb", output[0..got]);
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
