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
// Ported in part from tmux/cmd-load-buffer.c.
// Original copyright:
//   Copyright (c) 2009 Tiago Cunha <me@tiagocunha.org>
//   ISC licence – same terms as above.

const std = @import("std");
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

    if (args.has('w') or args.get('t') != null) {
        cmdq.cmdq_error(item, "buffer selection export not supported yet", .{});
        return .@"error";
    }

    const raw_path = format_path_from_client(item, client, args.value_at(0).?);
    defer xm.allocator.free(raw_path);

    const data = read_buffer(item, client, raw_path) catch return .@"error";

    var cause: ?[]u8 = null;
    defer if (cause) |msg| xm.allocator.free(msg);

    if (paste_mod.paste_set(data, args.get('b'), &cause) != 0) {
        xm.allocator.free(data);
        cmdq.cmdq_error(item, "{s}", .{cause orelse "load buffer failed"});
        return .@"error";
    }

    return .normal;
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

fn read_buffer(item: *cmdq.CmdqItem, client: ?*T.Client, raw_path: []const u8) ![]u8 {
    const resolved = resolve_path(client, raw_path);
    defer if (resolved.owned) xm.allocator.free(@constCast(resolved.path));

    if (std.mem.eql(u8, resolved.path, "-")) {
        if (client == null or (client.?.flags & (T.CLIENT_ATTACHED | T.CLIENT_CONTROL)) != 0) {
            cmdq.cmdq_error(item, "BadFileDescriptor: {s}", .{resolved.path});
            return error.BadFileDescriptor;
        }
        return read_fd_alloc(item, std.posix.STDIN_FILENO, resolved.path);
    }

    const file = std.fs.openFileAbsolute(resolved.path, .{}) catch |err| {
        cmdq.cmdq_error(item, "{s}: {s}", .{ @errorName(err), resolved.path });
        return err;
    };
    defer file.close();

    return file.readToEndAlloc(xm.allocator, std.math.maxInt(usize)) catch |err| {
        cmdq.cmdq_error(item, "{s}: {s}", .{ @errorName(err), resolved.path });
        return err;
    };
}

fn read_fd_alloc(item: *cmdq.CmdqItem, fd: i32, path: []const u8) ![]u8 {
    var out = std.ArrayList(u8){};
    errdefer out.deinit(xm.allocator);

    var buf: [4096]u8 = undefined;
    while (true) {
        const got = std.posix.read(fd, buf[0..]) catch |err| {
            cmdq.cmdq_error(item, "{s}: {s}", .{ @errorName(err), path });
            return err;
        };
        if (got == 0) break;
        out.appendSlice(xm.allocator, buf[0..got]) catch |err| {
            cmdq.cmdq_error(item, "{s}: {s}", .{ @errorName(err), path });
            return err;
        };
    }

    return out.toOwnedSlice(xm.allocator);
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

test "load-buffer reads stdin when path is dash" {
    init_options_for_tests();
    defer free_options_for_tests();
    paste_mod.paste_reset_for_tests();

    var env = T.Environ.init(xm.allocator);
    defer env.deinit();

    var client = T.Client{
        .environ = &env,
        .tty = undefined,
        .status = .{ .screen = undefined },
    };

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

    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(load, &item));
    try std.posix.dup2(saved_stdin, std.posix.STDIN_FILENO);

    const pb = paste_mod.paste_get_name("stdin-buffer") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("from stdin", paste_mod.paste_buffer_data(pb, null));
}

test "load-buffer rejects unsupported clipboard export flag" {
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

    try std.testing.expectEqual(T.CmdRetval.@"error", cmd_mod.cmd_execute(load, &item));
    try std.testing.expect(paste_mod.paste_get_name("buffer0") == null);
}
