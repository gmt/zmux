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
// Ported in part from tmux/cmd-source-file.c
// Original copyright:
//   Copyright (c) 2008 Tiago Cunha <me@tiagocunha.org>
//   ISC licence – same terms as above.

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const cmd_mod = @import("cmd.zig");
const cmdq = @import("cmd-queue.zig");
const cfg_mod = @import("cfg.zig");
const format_mod = @import("format.zig");

fn exec(cmd: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {
    const args = cmd_mod.cmd_get_args(cmd);
    const cl = cmdq.cmdq_get_client(item);
    var ok = true;

    var idx: usize = 0;
    while (args.value_at(idx)) |raw_path| : (idx += 1) {
        const path = if (args.has('F'))
            format_mod.format_single(@ptrCast(item), raw_path, cl, null, null, null)
        else
            null;
        defer if (path) |expanded| xm.allocator.free(expanded);

        const resolved = path orelse raw_path;
        if (args.has('F') and std.mem.indexOf(u8, resolved, "#{") != null) {
            cmdq.cmdq_error(item, "format expansion not supported yet", .{});
            return .@"error";
        }

        if (!cfg_mod.cfg_source_path(cl, resolved, .{
            .quiet = args.has('q'),
            .parse_only = args.has('n'),
            .verbose = args.has('v'),
        })) ok = false;
    }

    cfg_mod.cfg_show_causes(cl);
    return if (ok) .normal else .@"error";
}

pub const entry: cmd_mod.CmdEntry = .{
    .name = "source-file",
    .alias = "source",
    .usage = "[-Fnqv] path ...",
    .template = "Fnqvt:",
    .lower = 1,
    .upper = -1,
    .flags = T.CMD_STARTSERVER | T.CMD_AFTERHOOK,
    .exec = exec,
};

test "source-file rejects unresolved format references" {
    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "source-file", "-F", "#{pane_title}" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.@"error", cmd_mod.cmd_execute(cmd, &item));
}
