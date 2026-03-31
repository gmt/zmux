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
// Ported from tmux/cmd-unbind-key.c
// Original copyright:
//   Copyright (c) 2007 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

const std = @import("std");
const T = @import("types.zig");
const cmd_mod = @import("cmd.zig");
const cmdq = @import("cmd-queue.zig");
const key_string = @import("key-string.zig");
const key_bindings = @import("key-bindings.zig");

fn exec_unbind_key(cmd: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {
    const args = cmd_mod.cmd_get_args(cmd);
    const quiet = args.has('q');

    if (args.has('a')) {
        if (args.value_at(0) != null) {
            if (!quiet) cmdq.cmdq_error(item, "key given with -a", .{});
            return .@"error";
        }

        const tablename = if (args.get('T')) |table|
            table
        else if (args.has('n'))
            "root"
        else
            "prefix";
        if (key_bindings.key_bindings_get_table(tablename, false) == null) {
            if (!quiet) cmdq.cmdq_error(item, "table {s} doesn't exist", .{tablename});
            return .@"error";
        }
        key_bindings.key_bindings_remove_table(tablename);
        return .normal;
    }

    const key_name = args.value_at(0) orelse {
        if (!quiet) cmdq.cmdq_error(item, "missing key", .{});
        return .@"error";
    };
    const key = key_string.key_string_lookup_string(key_name);
    if (key == T.KEYC_NONE or key == T.KEYC_UNKNOWN) {
        if (!quiet) cmdq.cmdq_error(item, "unknown key: {s}", .{key_name});
        return .@"error";
    }

    const tablename = if (args.get('T')) |table|
        blk: {
            if (key_bindings.key_bindings_get_table(table, false) == null) {
                if (!quiet) cmdq.cmdq_error(item, "table {s} doesn't exist", .{table});
                return .@"error";
            }
            break :blk table;
        }
    else if (args.has('n'))
        "root"
    else
        "prefix";

    key_bindings.key_bindings_remove(tablename, key);
    return .normal;
}

pub const entry: cmd_mod.CmdEntry = .{
    .name = "unbind-key",
    .alias = "unbind",
    .usage = "[-anq] [-T key-table] key",
    .template = "anqT:",
    .lower = 0,
    .upper = 1,
    .flags = T.CMD_AFTERHOOK,
    .exec = exec_unbind_key,
};

test "unbind-key removes a specific key binding" {
    cmdq.cmdq_reset_for_tests();
    defer cmdq.cmdq_reset_for_tests();

    key_bindings.key_bindings_init();
    key_bindings.key_bindings_add("root", 'x', null, false, null);

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "unbind-key", "-n", "x" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));

    try std.testing.expect(key_bindings.key_bindings_get_table("root", false) == null);
}

test "unbind-key -a removes a table entirely" {
    cmdq.cmdq_reset_for_tests();
    defer cmdq.cmdq_reset_for_tests();

    key_bindings.key_bindings_init();
    key_bindings.key_bindings_add("root", 'x', null, false, null);
    key_bindings.key_bindings_add("root", 'y', null, false, null);

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "unbind-key", "-a", "-n" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));

    try std.testing.expect(key_bindings.key_bindings_get_table("root", false) == null);
}

test "unbind-key removes explicit built in binding only" {
    cmdq.cmdq_reset_for_tests();
    defer cmdq.cmdq_reset_for_tests();

    key_bindings.key_bindings_init();

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "unbind-key", "?" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));

    const prefix = key_bindings.key_bindings_get_table("prefix", false).?;
    try std.testing.expect(key_bindings.key_bindings_get(prefix, '?') == null);
    try std.testing.expect(key_bindings.key_bindings_get_default(prefix, '?') != null);
}
