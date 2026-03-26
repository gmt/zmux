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
// WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER
// IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING
// OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

//! cmd-format.zig – shared strict formatter command helpers.

const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const cmdq = @import("cmd-queue.zig");
const format_mod = @import("format.zig");

pub const unsupported_message = "format expansion not supported yet";

pub fn require(
    item: *cmdq.CmdqItem,
    template: []const u8,
    ctx: *const format_mod.FormatContext,
) ?[]u8 {
    return format_mod.format_require(xm.allocator, template, ctx) catch {
        cmdq.cmdq_error(item, unsupported_message, .{});
        return null;
    };
}

pub fn filter(
    item: *cmdq.CmdqItem,
    expr: []const u8,
    ctx: *const format_mod.FormatContext,
) ?bool {
    return format_mod.format_filter_require(xm.allocator, expr, ctx) catch {
        cmdq.cmdq_error(item, unsupported_message, .{});
        return null;
    };
}

pub fn target_context(target: *const T.CmdFindState, message_text: ?[]const u8) format_mod.FormatContext {
    return .{
        .session = target.s,
        .winlink = target.wl,
        .window = target.w,
        .pane = target.wp,
        .message_text = message_text,
    };
}
