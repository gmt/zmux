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
// Ported from tmux/cmd-bind-key.c
// Original copyright:
//   Copyright (c) 2007 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const cmd_mod = @import("cmd.zig");
const cmdq = @import("cmd-queue.zig");
const key_string = @import("key-string.zig");
const key_bindings = @import("key-bindings.zig");

fn exec_bind_key(cmd: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {
    const args = cmd_mod.cmd_get_args(cmd);
    const key_name = args.value_at(0) orelse {
        cmdq.cmdq_error(item, "missing key", .{});
        return .@"error";
    };
    const key = key_string.key_string_lookup_string(key_name);
    if (key == T.KEYC_NONE or key == T.KEYC_UNKNOWN) {
        cmdq.cmdq_error(item, "unknown key: {s}", .{key_name});
        return .@"error";
    }

    const tablename = if (args.get('T')) |table|
        table
    else if (args.has('n'))
        "root"
    else
        "prefix";
    const note = args.get('N');
    const repeat = args.has('r');

    if (args.count() == 1) {
        key_bindings.key_bindings_add(tablename, key, note, repeat, null);
        return .normal;
    }

    const subargv = argv_tail(args, 1);
    defer xm.allocator.free(subargv);

    const cmdlist = cmd_mod.cmd_parse_from_argv(subargv, null) catch {
        cmdq.cmdq_error(item, "invalid command", .{});
        return .@"error";
    };
    key_bindings.key_bindings_add(tablename, key, note, repeat, @ptrCast(cmdlist));
    return .normal;
}

fn argv_tail(args: *const @import("arguments.zig").Arguments, start: usize) []const []const u8 {
    const count = args.count();
    const out = xm.allocator.alloc([]const u8, count - start) catch unreachable;
    for (start..count) |idx| {
        out[idx - start] = args.value_at(idx).?;
    }
    return out;
}

pub const entry: cmd_mod.CmdEntry = .{
    .name = "bind-key",
    .alias = "bind",
    .usage = "[-nr] [-T key-table] [-N note] key [command [arguments]]",
    .template = "nrN:T:",
    .lower = 1,
    .upper = -1,
    .flags = T.CMD_AFTERHOOK,
    .exec = exec_bind_key,
};

test "bind-key stores explicit binding in selected table" {
    key_bindings.key_bindings_init();

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "bind-key", "-T", "root", "C-b", "display-message", "hi" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));

    const root = key_bindings.key_bindings_get_table("root", false).?;
    const binding = key_bindings.key_bindings_get(root, T.KEYC_CTRL | 'b').?;
    try std.testing.expect(binding.cmdlist != null);
}

test "bind-key metadata-only path updates note and repeat" {
    key_bindings.key_bindings_init();

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "bind-key", "-n", "-r", "-N", "note", "F1" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));

    const root = key_bindings.key_bindings_get_table("root", false).?;
    const binding = key_bindings.key_bindings_get(root, T.KEYC_F1).?;
    try std.testing.expectEqualStrings("note", binding.note.?);
    try std.testing.expect(binding.flags & T.KEY_BINDING_REPEAT != 0);
}

test "bind-key overrides built in default without touching stored default" {
    key_bindings.key_bindings_init();

    const prefix = key_bindings.key_bindings_get_table("prefix", false).?;
    const default_binding = key_bindings.key_bindings_get_default(prefix, '?').?;
    const default_list = default_binding.cmdlist;

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "bind-key", "?", "display-message", "override" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));

    const explicit = key_bindings.key_bindings_get(prefix, '?').?;
    try std.testing.expect(explicit.cmdlist != null);
    try std.testing.expect(explicit.cmdlist != default_list);
    try std.testing.expect(key_bindings.key_bindings_get_default(prefix, '?').?.cmdlist == default_list);
}
