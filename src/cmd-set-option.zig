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
// Ported in part from tmux/cmd-set-option.c
// Original copyright:
//   Copyright (c) 2007 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const cmd_mod = @import("cmd.zig");
const cmdq = @import("cmd-queue.zig");
const opts = @import("options.zig");
const format_mod = @import("format.zig");
const cmd_opts = @import("cmd-options.zig");

fn exec(cmd: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {
    const args = cmd_mod.cmd_get_args(cmd);
    if (args.has('o')) {
        cmdq.cmdq_error(item, "-o not supported yet", .{});
        return .@"error";
    }
    if (args.has('U')) {
        cmdq.cmdq_error(item, "-U not supported yet", .{});
        return .@"error";
    }

    const option_name = args.value_at(0) orelse {
        cmdq.cmdq_error(item, "invalid option", .{});
        return .@"error";
    };
    const oe = opts.options_table_entry(option_name);
    const custom = cmd_opts.is_custom_option(option_name);
    if (oe == null and !custom) {
        if (args.has('q')) return .normal;
        cmdq.cmdq_error(item, "invalid option: {s}", .{option_name});
        return .@"error";
    }

    const target = cmd_opts.resolve_target(item, args, cmd.entry == &entry_window) orelse return .@"error";
    if (!cmd_opts.option_allowed(oe, target.kind)) {
        if (args.has('q')) return .normal;
        cmdq.cmdq_error(item, "invalid option: {s}", .{option_name});
        return .@"error";
    }

    if (args.has('u')) {
        unset_option(target, option_name, oe);
        return .normal;
    }

    const raw_value = args.value_at(1);
    const expanded = if (args.has('F') and raw_value != null)
        format_mod.format_single(@ptrCast(item), raw_value.?, cmdq.cmdq_get_client(item), null, null, null)
    else
        null;
    defer if (expanded) |value| xm.allocator.free(value);
    const value = expanded orelse raw_value;

    if (args.has('F') and value != null and std.mem.indexOf(u8, value.?, "#{") != null) {
        cmdq.cmdq_error(item, "format expansion not supported yet", .{});
        return .@"error";
    }

    if (args.has('a') and oe != null and oe.?.@"type" != .string and oe.?.@"type" != .style and oe.?.@"type" != .array) {
        cmdq.cmdq_error(item, "-a only supported for string and array options", .{});
        return .@"error";
    }

    var cause: ?[]u8 = null;
    defer if (cause) |msg| xm.allocator.free(msg);
    if (!opts.options_set_from_string(target.options, oe, option_name, value, args.has('a'), &cause)) {
        if (args.has('q')) return .normal;
        cmdq.cmdq_error(item, "{s}", .{cause orelse "invalid option value"});
        return .@"error";
    }
    return .normal;
}

fn unset_option(target: cmd_opts.ResolvedTarget, name: []const u8, oe: ?*const T.OptionsTableEntry) void {
    if (oe == null) {
        opts.options_remove(target.options, name);
        return;
    }
    if (target.global) {
        opts.options_remove(target.options, name);
        opts.options_default(target.options, oe.?);
    } else {
        opts.options_remove(target.options, name);
    }
}

pub const entry: cmd_mod.CmdEntry = .{
    .name = "set-option",
    .alias = "set",
    .usage = "[-aFgopqsuUw] [-t target] option [value]",
    .template = "aFgopqst:uUw",
    .lower = 1,
    .upper = 2,
    .flags = T.CMD_STARTSERVER | T.CMD_AFTERHOOK,
    .exec = exec,
};

pub const entry_window: cmd_mod.CmdEntry = .{
    .name = "set-window-option",
    .alias = "setw",
    .usage = "[-aFgoqu] [-t target-window] option [value]",
    .template = "aFgoqt:u",
    .lower = 1,
    .upper = 2,
    .flags = T.CMD_STARTSERVER | T.CMD_AFTERHOOK,
    .exec = exec,
};
