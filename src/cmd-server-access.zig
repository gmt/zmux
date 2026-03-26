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
// Ported from tmux/cmd-server-access.c
// Original copyright:
//   Copyright (c) 2021 Dallas Lyons <dallasdlyons@gmail.com>
//   ISC licence – same terms as above.

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const c = @import("c.zig");
const args_mod = @import("arguments.zig");
const cmd_mod = @import("cmd.zig");
const cmdq = @import("cmd-queue.zig");
const format_mod = @import("format.zig");
const proc_mod = @import("proc.zig");
const server_acl = @import("server-acl.zig");
const client_registry = @import("client-registry.zig");

const UserInfo = struct {
    uid: std.posix.uid_t,
    name: []const u8,
};

fn lookup_user(name: []const u8) ?UserInfo {
    const name_z = xm.xm_dupeZ(name);
    defer xm.allocator.free(name_z);

    const pw = c.posix_sys.getpwnam(name_z.ptr);
    if (pw == null) return null;

    return .{
        .uid = pw.?.*.pw_uid,
        .name = std.mem.span(@as([*:0]const u8, @ptrCast(pw.?.*.pw_name))),
    };
}

fn cmd_server_access_deny(item: *cmdq.CmdqItem, uid: std.posix.uid_t, user_name: []const u8) T.CmdRetval {
    if (!server_acl.server_acl_user_exists(uid)) {
        cmdq.cmdq_error(item, "user {s} not found", .{user_name});
        return .@"error";
    }

    for (client_registry.clients.items) |loop| {
        const peer = loop.peer orelse continue;
        if (proc_mod.proc_get_peer_uid(peer) != uid) continue;
        if (loop.exit_message) |message| xm.allocator.free(message);
        loop.exit_message = xm.xstrdup("access not allowed");
        loop.flags |= T.CLIENT_EXIT;
    }
    server_acl.server_acl_user_deny(uid);
    return .normal;
}

fn apply_access(args: *const args_mod.Arguments, item: *cmdq.CmdqItem, uid: std.posix.uid_t, user_name: []const u8) T.CmdRetval {
    const owner_uid: std.posix.uid_t = @intCast(std.os.linux.getuid());

    if (uid == 0 or uid == owner_uid) {
        cmdq.cmdq_error(item, "{s} owns the server, can't change access", .{user_name});
        return .@"error";
    }

    if (args.has('a') and args.has('d')) {
        cmdq.cmdq_error(item, "-a and -d cannot be used together", .{});
        return .@"error";
    }
    if (args.has('w') and args.has('r')) {
        cmdq.cmdq_error(item, "-r and -w cannot be used together", .{});
        return .@"error";
    }

    if (args.has('d'))
        return cmd_server_access_deny(item, uid, user_name);

    if (args.has('a')) {
        if (server_acl.server_acl_user_exists(uid)) {
            cmdq.cmdq_error(item, "user {s} is already added", .{user_name});
            return .@"error";
        }
        server_acl.server_acl_user_allow(uid);
    } else if (args.has('r') or args.has('w')) {
        if (!server_acl.server_acl_user_exists(uid))
            server_acl.server_acl_user_allow(uid);
    }

    if (args.has('w')) {
        if (!server_acl.server_acl_user_exists(uid)) {
            cmdq.cmdq_error(item, "user {s} not found", .{user_name});
            return .@"error";
        }
        server_acl.server_acl_user_allow_write(uid);
        return .normal;
    }

    if (args.has('r')) {
        if (!server_acl.server_acl_user_exists(uid)) {
            cmdq.cmdq_error(item, "user {s} not found", .{user_name});
            return .@"error";
        }
        server_acl.server_acl_user_deny_write(uid);
        return .normal;
    }

    return .normal;
}

fn exec(cmd: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {
    const args = cmd_mod.cmd_get_args(cmd);
    const target_client = cmdq.cmdq_get_target_client(item) orelse cmdq.cmdq_get_client(item);

    if (args.has('l')) {
        server_acl.server_acl_display(item);
        return .normal;
    }
    if (args.count() == 0) {
        cmdq.cmdq_error(item, "missing user argument", .{});
        return .@"error";
    }

    const expanded = format_mod.format_single(item, args.value_at(0).?, target_client, null, null, null);
    defer xm.allocator.free(expanded);

    const user = if (expanded.len != 0) lookup_user(expanded) else null;
    if (user == null) {
        cmdq.cmdq_error(item, "unknown user: {s}", .{expanded});
        return .@"error";
    }

    return apply_access(args, item, user.?.uid, user.?.name);
}

pub const entry: cmd_mod.CmdEntry = .{
    .name = "server-access",
    .usage = "[-adlrw] [user]",
    .template = "adlrw",
    .lower = 0,
    .upper = 1,
    .flags = T.CMD_CLIENT_CANFAIL,
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

test "server-access rejects missing user without -l" {
    init_options_for_tests();
    defer free_options_for_tests();
    server_acl.server_acl_reset_for_tests();

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{"server-access"}, null, &cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.@"error", cmd_mod.cmd_execute(cmd, &item));
}

test "server-access list mode succeeds without user" {
    init_options_for_tests();
    defer free_options_for_tests();
    server_acl.server_acl_reset_for_tests();

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "server-access", "-l" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));
}

test "server-access core ACL transitions stay honest" {
    init_options_for_tests();
    defer free_options_for_tests();
    server_acl.server_acl_reset_for_tests();
    client_registry.clients.clearRetainingCapacity();
    defer client_registry.clients.clearRetainingCapacity();

    var peer = T.ZmuxPeer{
        .parent = undefined,
        .ibuf = undefined,
        .event = null,
        .uid = 31001,
        .flags = 0,
        .dispatchcb = undefined,
        .arg = null,
    };
    var client = T.Client{
        .peer = &peer,
        .environ = undefined,
        .tty = undefined,
        .status = undefined,
    };
    client_registry.add(&client);

    var cause: ?[]u8 = null;
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };

    {
        const cmd = try cmd_mod.cmd_parse_one(&.{ "server-access", "-a", "alice" }, null, &cause);
        defer cmd_mod.cmd_free(cmd);
        try std.testing.expectEqual(T.CmdRetval.normal, apply_access(cmd_mod.cmd_get_args(cmd), &item, peer.uid, "alice"));
    }
    try std.testing.expect(server_acl.server_acl_user_exists(peer.uid));
    try std.testing.expect(!server_acl.server_acl_user_is_readonly(peer.uid));

    {
        const cmd = try cmd_mod.cmd_parse_one(&.{ "server-access", "-r", "alice" }, null, &cause);
        defer cmd_mod.cmd_free(cmd);
        try std.testing.expectEqual(T.CmdRetval.normal, apply_access(cmd_mod.cmd_get_args(cmd), &item, peer.uid, "alice"));
    }
    try std.testing.expect(server_acl.server_acl_user_is_readonly(peer.uid));
    try std.testing.expect(client.flags & T.CLIENT_READONLY != 0);

    {
        const cmd = try cmd_mod.cmd_parse_one(&.{ "server-access", "-w", "alice" }, null, &cause);
        defer cmd_mod.cmd_free(cmd);
        try std.testing.expectEqual(T.CmdRetval.normal, apply_access(cmd_mod.cmd_get_args(cmd), &item, peer.uid, "alice"));
    }
    try std.testing.expect(!server_acl.server_acl_user_is_readonly(peer.uid));
    try std.testing.expect(client.flags & T.CLIENT_READONLY == 0);

    {
        const cmd = try cmd_mod.cmd_parse_one(&.{ "server-access", "-d", "alice" }, null, &cause);
        defer cmd_mod.cmd_free(cmd);
        try std.testing.expectEqual(T.CmdRetval.normal, apply_access(cmd_mod.cmd_get_args(cmd), &item, peer.uid, "alice"));
    }
    try std.testing.expect(!server_acl.server_acl_user_exists(peer.uid));
    try std.testing.expect(client.flags & T.CLIENT_EXIT != 0);
    try std.testing.expectEqualStrings("access not allowed", client.exit_message.?);
    xm.allocator.free(client.exit_message.?);
}

test "server-access rejects conflicting flags and server owner changes" {
    init_options_for_tests();
    defer free_options_for_tests();
    server_acl.server_acl_reset_for_tests();

    var cause: ?[]u8 = null;
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };

    {
        const cmd = try cmd_mod.cmd_parse_one(&.{ "server-access", "-a", "-d", "alice" }, null, &cause);
        defer cmd_mod.cmd_free(cmd);
        try std.testing.expectEqual(T.CmdRetval.@"error", apply_access(cmd_mod.cmd_get_args(cmd), &item, 32001, "alice"));
    }

    {
        const cmd = try cmd_mod.cmd_parse_one(&.{ "server-access", "-r", "-w", "alice" }, null, &cause);
        defer cmd_mod.cmd_free(cmd);
        try std.testing.expectEqual(T.CmdRetval.@"error", apply_access(cmd_mod.cmd_get_args(cmd), &item, 32001, "alice"));
    }

    {
        const cmd = try cmd_mod.cmd_parse_one(&.{ "server-access", "-a", "owner" }, null, &cause);
        defer cmd_mod.cmd_free(cmd);
        const owner_uid: std.posix.uid_t = @intCast(std.os.linux.getuid());
        try std.testing.expectEqual(T.CmdRetval.@"error", apply_access(cmd_mod.cmd_get_args(cmd), &item, owner_uid, "owner"));
    }
}
