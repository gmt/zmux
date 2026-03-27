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
// Ported in part from tmux/cmd-show-prompt-history.c.
// Original copyright:
//   Copyright (c) 2021 Anindya Mukherjee <anindya49@hotmail.com>
//   ISC licence – same terms as above.

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const cmd_mod = @import("cmd.zig");
const cmdq = @import("cmd-queue.zig");
const opts = @import("options.zig");
const status_prompt = @import("status-prompt.zig");

fn exec(cmd: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {
    const args = cmd_mod.cmd_get_args(cmd);
    const prompt_type = if (args.get('T')) |raw| blk: {
        const parsed = status_prompt.status_prompt_type(raw);
        if (parsed == .invalid) {
            cmdq.cmdq_error(item, "invalid type: {s}", .{raw});
            return .@"error";
        }
        break :blk parsed;
    } else null;

    if (cmd.entry == &entry_clear) {
        status_prompt.status_prompt_history_clear(prompt_type);
        return .normal;
    }

    const rendered = render_prompt_history(xm.allocator, prompt_type);
    defer xm.allocator.free(rendered);
    cmdq.cmdq_print_data(item, rendered);
    return .normal;
}

fn append_type_history(alloc: std.mem.Allocator, out: *std.ArrayList(u8), prompt_type: status_prompt.PromptType) void {
    out.writer(alloc).print("History for {s}:\n", .{
        status_prompt.status_prompt_type_string(prompt_type),
    }) catch unreachable;

    const count = status_prompt.status_prompt_history_count(prompt_type);
    for (0..count) |idx| {
        out.writer(alloc).print("{d}: {s}\n", .{
            idx + 1,
            status_prompt.status_prompt_history_item(prompt_type, idx).?,
        }) catch unreachable;
    }
    out.append(alloc, '\n') catch unreachable;
}

fn render_prompt_history(alloc: std.mem.Allocator, prompt_type: ?status_prompt.PromptType) []u8 {
    var out: std.ArrayList(u8) = .{};
    errdefer out.deinit(alloc);

    if (prompt_type) |kind| {
        append_type_history(alloc, &out, kind);
    } else {
        append_type_history(alloc, &out, .command);
        append_type_history(alloc, &out, .search);
        append_type_history(alloc, &out, .target);
        append_type_history(alloc, &out, .window_target);
    }
    return out.toOwnedSlice(alloc) catch unreachable;
}

pub const entry: cmd_mod.CmdEntry = .{
    .name = "show-prompt-history",
    .alias = "showphist",
    .usage = "[-T prompt-type]",
    .template = "T:",
    .lower = 0,
    .upper = 0,
    .flags = T.CMD_AFTERHOOK,
    .exec = exec,
};

pub const entry_clear: cmd_mod.CmdEntry = .{
    .name = "clear-prompt-history",
    .alias = "clearphist",
    .usage = "[-T prompt-type]",
    .template = "T:",
    .lower = 0,
    .upper = 0,
    .flags = T.CMD_AFTERHOOK,
    .exec = exec,
};

fn init_options_for_tests() void {
    opts.global_options = opts.options_create(null);
    opts.global_s_options = opts.options_create(null);
    opts.global_w_options = opts.options_create(null);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
}

fn free_options_for_tests() void {
    opts.options_free(opts.global_w_options);
    opts.options_free(opts.global_s_options);
    opts.options_free(opts.global_options);
}

test "show-prompt-history renders all prompt types in tmux order" {
    init_options_for_tests();
    defer free_options_for_tests();
    status_prompt.status_prompt_history_clear(null);
    defer status_prompt.status_prompt_history_clear(null);

    status_prompt.status_prompt_history_add("cmd one", .command);
    status_prompt.status_prompt_history_add("find me", .search);
    status_prompt.status_prompt_history_add("session:1", .target);
    status_prompt.status_prompt_history_add("@2", .window_target);

    const rendered = render_prompt_history(std.testing.allocator, null);
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings(
        \\History for command:
        \\1: cmd one
        \\
        \\History for search:
        \\1: find me
        \\
        \\History for target:
        \\1: session:1
        \\
        \\History for window-target:
        \\1: @2
        \\
        \\
    ,
        rendered,
    );
}

test "show-prompt-history renders a single prompt type and clear uses the same parser" {
    init_options_for_tests();
    defer free_options_for_tests();
    status_prompt.status_prompt_history_clear(null);
    defer status_prompt.status_prompt_history_clear(null);
    status_prompt.status_prompt_history_add("alpha", .command);
    status_prompt.status_prompt_history_add("beta", .command);

    const rendered = render_prompt_history(std.testing.allocator, .command);
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings(
        \\History for command:
        \\1: alpha
        \\2: beta
        \\
        \\
    ,
        rendered,
    );

    var cause: ?[]u8 = null;
    const clear_cmd = try cmd_mod.cmd_parse_one(&.{ "clear-prompt-history", "-T", "command" }, null, &cause);
    defer cmd_mod.cmd_free(clear_cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(clear_cmd, &item));
    try std.testing.expectEqual(@as(usize, 0), status_prompt.status_prompt_history_count(.command));
}

test "show-prompt-history rejects invalid types" {
    init_options_for_tests();
    defer free_options_for_tests();
    var cause: ?[]u8 = null;
    const show_cmd = try cmd_mod.cmd_parse_one(&.{ "show-prompt-history", "-T", "bogus" }, null, &cause);
    defer cmd_mod.cmd_free(show_cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.@"error", cmd_mod.cmd_execute(show_cmd, &item));
}
