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
// Ported from tmux/cmd-list-buffers.c.
// Original copyright:
//   Copyright (c) 2007 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence - same terms as above.

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const cmd_mod = @import("cmd.zig");
const cmd_format = @import("cmd-format.zig");
const cmdq = @import("cmd-queue.zig");
const format_mod = @import("format.zig");
const paste_mod = @import("paste.zig");
const sort_mod = @import("sort.zig");

const DEFAULT_TEMPLATE = "#{buffer_name}: #{buffer_size} bytes: \"#{buffer_sample}\"";

fn exec(cmd: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {
    const args = cmd_mod.cmd_get_args(cmd);
    const fmt = args.get('F') orelse DEFAULT_TEMPLATE;
    const filter = args.get('f');
    const sort_crit = T.SortCriteria{
        .order = sort_mod.sort_order_from_string(args.get('O')),
        .reversed = args.has('r'),
    };
    if (sort_crit.order == .end and args.has('O')) {
        cmdq.cmdq_error(item, "invalid sort order", .{});
        return .@"error";
    }

    const sorted = sort_mod.sorted_buffers(sort_crit);
    defer xm.allocator.free(sorted);

    for (sorted) |pb| {
        const ctx = format_mod.FormatContext{ .paste_buffer = pb };
        if (filter) |expr| {
            const matched = cmd_format.filter(item, expr, &ctx) orelse return .@"error";
            if (!matched) continue;
        }

        const line = cmd_format.require(item, fmt, &ctx) orelse return .@"error";
        defer xm.allocator.free(line);
        cmdq.cmdq_print(item, "{s}", .{line});
    }
    return .normal;
}

fn render_matching_buffers(
    alloc: std.mem.Allocator,
    template: []const u8,
    filter: ?[]const u8,
    sort_crit: T.SortCriteria,
) ?[]u8 {
    const sorted = sort_mod.sorted_buffers(sort_crit);
    defer xm.allocator.free(sorted);

    var out: std.ArrayList(u8) = .{};
    for (sorted) |pb| {
        const ctx = format_mod.FormatContext{ .paste_buffer = pb };
        if (filter) |expr| {
            const matched = format_mod.format_filter_require(alloc, expr, &ctx) catch return null;
            if (!matched) continue;
        }

        const line = format_mod.format_require(alloc, template, &ctx) catch return null;
        defer alloc.free(line);

        if (out.items.len != 0) out.append(alloc, '\n') catch unreachable;
        out.appendSlice(alloc, line) catch unreachable;
    }
    return out.toOwnedSlice(alloc) catch unreachable;
}

pub const entry: cmd_mod.CmdEntry = .{
    .name = "list-buffers",
    .alias = "lsb",
    .usage = "[-F format] [-f filter] [-O order]",
    .template = "F:f:O:r",
    .lower = 0,
    .upper = 0,
    .flags = T.CMD_AFTERHOOK,
    .exec = exec,
};

test "list-buffers default template renders newest-first buffer lines" {
    paste_mod.paste_reset_for_tests();

    var cause: ?[]u8 = null;
    try std.testing.expectEqual(@as(i32, 0), paste_mod.paste_set(xm.xstrdup("one"), "alpha", &cause));
    try std.testing.expectEqual(@as(i32, 0), paste_mod.paste_set(xm.xstrdup("g\n"), "gamma", &cause));
    try std.testing.expectEqual(@as(i32, 0), paste_mod.paste_set(xm.xstrdup("zzzz"), "beta", &cause));

    const rendered = render_matching_buffers(xm.allocator, DEFAULT_TEMPLATE, null, .{}).?;
    defer xm.allocator.free(rendered);
    try std.testing.expectEqualStrings(
        "beta: 4 bytes: \"zzzz\"\ngamma: 2 bytes: \"g\\n\"\nalpha: 3 bytes: \"one\"",
        rendered,
    );
}

test "list-buffers supports sorting and filtering through buffer format keys" {
    paste_mod.paste_reset_for_tests();

    var cause: ?[]u8 = null;
    try std.testing.expectEqual(@as(i32, 0), paste_mod.paste_set(xm.xstrdup("bbb"), "beta", &cause));
    try std.testing.expectEqual(@as(i32, 0), paste_mod.paste_set(xm.xstrdup("a"), "alpha", &cause));
    try std.testing.expectEqual(@as(i32, 0), paste_mod.paste_set(xm.xstrdup("cccc"), "gamma", &cause));

    const filtered = render_matching_buffers(
        xm.allocator,
        "#{buffer_name}:#{buffer_size}",
        "#{>=:buffer_size,3}",
        .{ .order = .name },
    ).?;
    defer xm.allocator.free(filtered);
    try std.testing.expectEqualStrings("beta:3\ngamma:4", filtered);

    const created = render_matching_buffers(
        xm.allocator,
        "#{buffer_name}",
        null,
        .{ .order = .creation, .reversed = true },
    ).?;
    defer xm.allocator.free(created);
    try std.testing.expectEqualStrings("gamma\nalpha\nbeta", created);
}
