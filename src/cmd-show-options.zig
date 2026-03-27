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
// Ported in part from tmux/cmd-show-options.c
// Original copyright:
//   Copyright (c) 2007 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const cmd_mod = @import("cmd.zig");
const cmdq = @import("cmd-queue.zig");
const opts = @import("options.zig");
const cmd_opts = @import("cmd-options.zig");

fn exec(cmd: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {
    const args = cmd_mod.cmd_get_args(cmd);
    if (args.has('H')) {
        cmdq.cmdq_error(item, "-H not supported yet", .{});
        return .@"error";
    }

    const name = args.value_at(0);
    if (name) |option_name| {
        const oe = opts.options_table_entry(option_name);
        if (oe == null and !cmd_opts.is_custom_option(option_name)) {
            if (args.has('q')) return .normal;
            cmdq.cmdq_error(item, "invalid option: {s}", .{option_name});
            return .@"error";
        }
    }

    const target = cmd_opts.resolve_target(item, args, cmd.entry == &entry_window) orelse return .@"error";
    if (name) |option_name| {
        const oe = opts.options_table_entry(option_name);
        if (!cmd_opts.option_allowed(oe, target.kind)) {
            if (args.has('q')) return .normal;
            cmdq.cmdq_error(item, "invalid option: {s}", .{option_name});
            return .@"error";
        }
    }

    const lines = cmd_opts.collect_lines(target, name, args.has('v'), args.has('A'));
    defer free_lines(lines);
    if (name != null and lines.len == 0) {
        if (cmd_opts.is_custom_option(name.?)) {
            if (args.has('q')) return .normal;
            cmdq.cmdq_error(item, "invalid option: {s}", .{name.?});
            return .@"error";
        }
        return .normal;
    }

    for (lines) |line| cmdq.cmdq_print(item, "{s}", .{line});
    return .normal;
}

fn free_lines(lines: [][]u8) void {
    for (lines) |line| xm.allocator.free(line);
    xm.allocator.free(lines);
}

pub const entry: cmd_mod.CmdEntry = .{
    .name = "show-options",
    .alias = "show",
    .usage = "[-AgHpqsvw] [-t target] [option]",
    .template = "AgHpqst:vw",
    .lower = 0,
    .upper = 1,
    .flags = T.CMD_STARTSERVER | T.CMD_AFTERHOOK,
    .exec = exec,
};

pub const entry_window: cmd_mod.CmdEntry = .{
    .name = "show-window-options",
    .alias = "showw",
    .usage = "[-gv] [-t target-window] [option]",
    .template = "gvt:",
    .lower = 0,
    .upper = 1,
    .flags = T.CMD_STARTSERVER | T.CMD_AFTERHOOK,
    .exec = exec,
};
