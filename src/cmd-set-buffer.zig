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
// Ported in part from tmux/cmd-set-buffer.c.
// Original copyright:
//   Copyright (c) 2007 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const cmd_mod = @import("cmd.zig");
const cmdq = @import("cmd-queue.zig");
const client_registry = @import("client-registry.zig");
const paste_mod = @import("paste.zig");

fn exec(cmd: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {
    const args = cmd_mod.cmd_get_args(cmd);
    const target_client = cmdq.cmdq_get_target_client(item);

    if (args.has('w') and target_client != null) {
        cmdq.cmdq_error(item, "buffer selection export not supported yet", .{});
        return .@"error";
    }

    var pb: ?*paste_mod.PasteBuffer = null;
    var bufname: ?[]u8 = null;
    defer if (bufname) |name| xm.allocator.free(name);

    if (args.get('b')) |name| {
        bufname = xm.xstrdup(name);
        pb = paste_mod.paste_get_name(name);
    }

    if (cmd.entry == &entry_delete) {
        if (!resolve_named_or_top_buffer(item, &pb, &bufname)) return .@"error";
        paste_mod.paste_free(pb.?);
        return .normal;
    }

    var cause: ?[]u8 = null;
    defer if (cause) |msg| xm.allocator.free(msg);

    if (args.has('n')) {
        if (!resolve_named_or_top_buffer(item, &pb, &bufname)) return .@"error";
        if (paste_mod.paste_rename(bufname, args.get('n'), &cause) != 0) {
            cmdq.cmdq_error(item, "{s}", .{cause orelse "rename buffer failed"});
            return .@"error";
        }
        return .normal;
    }

    if (args.count() != 1) {
        cmdq.cmdq_error(item, "no data specified", .{});
        return .@"error";
    }

    const new_data = args.value_at(0).?;
    if (new_data.len == 0) return .normal;

    var bufdata = std.ArrayList(u8){};
    defer bufdata.deinit(xm.allocator);

    if (args.has('a') and pb != null) {
        bufdata.appendSlice(xm.allocator, paste_mod.paste_buffer_data(pb.?, null)) catch unreachable;
    }
    bufdata.appendSlice(xm.allocator, new_data) catch unreachable;

    if (paste_mod.paste_set(bufdata.toOwnedSlice(xm.allocator) catch unreachable, bufname, &cause) != 0) {
        cmdq.cmdq_error(item, "{s}", .{cause orelse "set buffer failed"});
        return .@"error";
    }
    return .normal;
}

fn resolve_named_or_top_buffer(item: *cmdq.CmdqItem, pb: *?*paste_mod.PasteBuffer, bufname: *?[]u8) bool {
    if (pb.* == null) {
        if (bufname.*) |name| {
            cmdq.cmdq_error(item, "unknown buffer: {s}", .{name});
            return false;
        }
        pb.* = paste_mod.paste_get_top(bufname);
    }
    if (pb.* == null) {
        cmdq.cmdq_error(item, "no buffer", .{});
        return false;
    }
    return true;
}

pub const entry: cmd_mod.CmdEntry = .{
    .name = "set-buffer",
    .alias = "setb",
    .usage = "[-aw] [-b buffer-name] [-n new-buffer-name] [-t target-client] [data]",
    .template = "ab:t:n:w",
    .lower = 0,
    .upper = 1,
    .flags = T.CMD_AFTERHOOK | T.CMD_CLIENT_TFLAG | T.CMD_CLIENT_CANFAIL,
    .exec = exec,
};

pub const entry_delete: cmd_mod.CmdEntry = .{
    .name = "delete-buffer",
    .alias = "deleteb",
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

test "set-buffer creates and appends named buffer data" {
    init_options_for_tests();
    defer free_options_for_tests();
    paste_mod.paste_reset_for_tests();

    var cause: ?[]u8 = null;
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    {
        const cmd = try cmd_mod.cmd_parse_one(&.{ "set-buffer", "-b", "named", "hello" }, null, &cause);
        defer cmd_mod.cmd_free(cmd);
        try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));
    }
    try std.testing.expectEqualStrings("hello", paste_mod.paste_buffer_data(paste_mod.paste_get_name("named").?, null));

    {
        const cmd = try cmd_mod.cmd_parse_one(&.{ "set-buffer", "-a", "-b", "named", " world" }, null, &cause);
        defer cmd_mod.cmd_free(cmd);
        try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));
    }
    try std.testing.expectEqualStrings("hello world", paste_mod.paste_buffer_data(paste_mod.paste_get_name("named").?, null));
}

test "set-buffer renames the top automatic buffer" {
    init_options_for_tests();
    defer free_options_for_tests();
    paste_mod.paste_reset_for_tests();

    var cause: ?[]u8 = null;
    const create = try cmd_mod.cmd_parse_one(&.{ "set-buffer", "auto-data" }, null, &cause);
    defer cmd_mod.cmd_free(create);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(create, &item));
    try std.testing.expect(paste_mod.paste_get_top(null) != null);

    const rename = try cmd_mod.cmd_parse_one(&.{ "set-buffer", "-n", "renamed" }, null, &cause);
    defer cmd_mod.cmd_free(rename);
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(rename, &item));

    const renamed = paste_mod.paste_get_name("renamed") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("auto-data", paste_mod.paste_buffer_data(renamed, null));
    try std.testing.expect(paste_mod.paste_get_top(null) == null);
}

test "delete-buffer removes the current top automatic buffer" {
    init_options_for_tests();
    defer free_options_for_tests();
    paste_mod.paste_reset_for_tests();

    var cause: ?[]u8 = null;
    const create = try cmd_mod.cmd_parse_one(&.{ "set-buffer", "auto-data" }, null, &cause);
    defer cmd_mod.cmd_free(create);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(create, &item));

    const delete = try cmd_mod.cmd_parse_one(&.{"delete-buffer"}, null, &cause);
    defer cmd_mod.cmd_free(delete);
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(delete, &item));
    try std.testing.expect(paste_mod.paste_get_top(null) == null);
}

test "set-buffer write flag rejects resolved target-client export seam" {
    init_options_for_tests();
    defer free_options_for_tests();
    paste_mod.paste_reset_for_tests();
    client_registry.clients.clearRetainingCapacity();
    defer client_registry.clients.clearRetainingCapacity();

    var env = T.Environ.init(xm.allocator);
    defer env.deinit();
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
        .environ = &env,
        .tty = undefined,
        .status = .{ .screen = undefined },
    };
    target.session = &session;
    client_registry.add(&target);

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "set-buffer", "-w", "-t", "clip", "hello" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.@"error", cmd_mod.cmd_execute(cmd, &item));
    try std.testing.expect(paste_mod.paste_get_top(null) == null);
}
