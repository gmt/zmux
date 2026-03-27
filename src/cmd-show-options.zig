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

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const cmd_mod = @import("cmd.zig");
const cmdq = @import("cmd-queue.zig");
const opts = @import("options.zig");
const cmd_opts = @import("cmd-options.zig");

fn exec(cmd: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {
    const args = cmd_mod.cmd_get_args(cmd);
    const hooks_only = cmd.entry == &entry_hooks;
    const hook_mode: cmd_opts.HookMode = if (hooks_only)
        .only
    else if (args.has('H'))
        .include
    else
        .exclude;

    const name = args.value_at(0);
    if (name) |option_name| {
        const oe = opts.options_table_entry(option_name);
        if (oe == null and !cmd_opts.is_custom_option(option_name)) {
            if (args.has('q')) return .normal;
            cmdq.cmdq_error(item, "invalid option: {s}", .{option_name});
            return .@"error";
        }
        if (hooks_only and (oe == null or !oe.?.is_hook)) {
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

    const lines = cmd_opts.collect_lines(target, name, args.has('v'), args.has('A'), hook_mode);
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

pub const entry_hooks: cmd_mod.CmdEntry = .{
    .name = "show-hooks",
    .usage = "[-gpw] [-t target-pane] [hook]",
    .template = "gpt:w",
    .lower = 0,
    .upper = 1,
    .flags = T.CMD_STARTSERVER | T.CMD_AFTERHOOK,
    .exec = exec,
};

fn capture_stdout(argv: []const []const u8) ![]u8 {
    var stdout_pipe: [2]i32 = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.pipe(&stdout_pipe));
    defer {
        std.posix.close(stdout_pipe[0]);
        if (stdout_pipe[1] != -1) std.posix.close(stdout_pipe[1]);
    }

    const stdout_dup = try std.posix.dup(std.posix.STDOUT_FILENO);
    defer std.posix.close(stdout_dup);

    try std.posix.dup2(stdout_pipe[1], std.posix.STDOUT_FILENO);
    defer std.posix.dup2(stdout_dup, std.posix.STDOUT_FILENO) catch {};

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(argv, null, &cause);
    defer cmd_mod.cmd_free(cmd);
    defer if (cause) |msg| xm.allocator.free(msg);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));

    try std.posix.dup2(stdout_dup, std.posix.STDOUT_FILENO);
    std.posix.close(stdout_pipe[1]);
    stdout_pipe[1] = -1;

    var out: std.ArrayList(u8) = .{};
    errdefer out.deinit(xm.allocator);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = try std.posix.read(stdout_pipe[0], &buf);
        if (n == 0) break;
        try out.appendSlice(xm.allocator, buf[0..n]);
    }
    return out.toOwnedSlice(xm.allocator);
}

test "show-options -g excludes hooks unless -H is present" {
    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);

    const without_hooks = try capture_stdout(&.{ "show-options", "-g" });
    defer xm.allocator.free(without_hooks);
    try std.testing.expect(std.mem.containsAtLeast(u8, without_hooks, 1, "status-left "));
    try std.testing.expectEqual(@as(?usize, null), std.mem.indexOf(u8, without_hooks, "after-show-options"));

    const with_hooks = try capture_stdout(&.{ "show-options", "-gH" });
    defer xm.allocator.free(with_hooks);
    try std.testing.expect(std.mem.containsAtLeast(u8, with_hooks, 1, "status-left "));
    try std.testing.expect(std.mem.containsAtLeast(u8, with_hooks, 1, "after-show-options"));
}

test "show-hooks -g only prints hook options" {
    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);

    const output = try capture_stdout(&.{ "show-hooks", "-g" });
    defer xm.allocator.free(output);
    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "after-show-options"));
    try std.testing.expectEqual(@as(?usize, null), std.mem.indexOf(u8, output, "status-left "));
}
