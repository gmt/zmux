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
// Ported in part from tmux/cmd-display-message.c.
// Original copyright:
//   Copyright (c) 2009 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const cmd_mod = @import("cmd.zig");
const cmd_format = @import("cmd-format.zig");
const cmdq = @import("cmd-queue.zig");
const cmd_find = @import("cmd-find.zig");
const format_mod = @import("format.zig");

pub fn expand_format(alloc: std.mem.Allocator, fmt: []const u8, target: *const T.CmdFindState) []u8 {
    var ctx = target_context(target);
    return format_mod.format_expand(alloc, fmt, &ctx).text;
}

pub fn require_format(
    alloc: std.mem.Allocator,
    fmt: []const u8,
    target: *const T.CmdFindState,
    message_text: ?[]const u8,
) ?[]u8 {
    var ctx = cmd_format.target_context(target, message_text);
    return format_mod.format_require(alloc, fmt, &ctx) catch null;
}

pub fn target_context(target: *const T.CmdFindState) format_mod.FormatContext {
    return cmd_format.target_context(target, null);
}

fn exec(cmd: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {
    const args = cmd_mod.cmd_get_args(cmd);
    var target: T.CmdFindState = .{};
    _ = cmd_find.cmd_find_target(&target, item, args.get('t'), .pane, T.CMD_FIND_CANFAIL);

    const fmt = args.value_at(0) orelse "#{message_text}";
    const ctx = cmd_format.target_context(&target, args.value_at(0));
    const expanded = cmd_format.require(item, fmt, &ctx) orelse return .@"error";
    defer xm.allocator.free(expanded);

    cmdq.cmdq_print(item, "{s}", .{expanded});
    return .normal;
}

pub const entry: cmd_mod.CmdEntry = .{
    .name = "display-message",
    .alias = "display",
    .usage = "[-aCIlNpv] [-c target-client] [-d delay] [-F format] [-t target-pane] [message]",
    .template = "ac:d:F:INpPRt:v",
    .lower = 0,
    .upper = 1,
    .flags = T.CMD_READONLY,
    .exec = exec,
};
