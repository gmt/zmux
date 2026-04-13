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

//! cmd-format-test.zig – tests for cmd-format.zig helpers.

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const cmdq = @import("cmd-queue.zig");
const cmd_mod = @import("cmd.zig");
const cmd_format = @import("cmd-format.zig");
const format_mod = @import("format.zig");

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn makeDummyItem() cmdq.CmdqItem {
    return .{ .client = null };
}

fn emptyContext() format_mod.FormatContext {
    return .{};
}

// ---------------------------------------------------------------------------
// Tests: target_context
// ---------------------------------------------------------------------------

test "cmd-format: target_context maps CmdFindState fields into FormatContext" {
    var fs: T.CmdFindState = .{};
    const ctx = cmd_format.target_context(&fs, null);

    // All pointers nil when CmdFindState is default-initialised.
    try std.testing.expectEqual(@as(?*T.Session, null), ctx.session);
    try std.testing.expectEqual(@as(?*T.Winlink, null), ctx.winlink);
    try std.testing.expectEqual(@as(?*T.Window, null), ctx.window);
    try std.testing.expectEqual(@as(?*T.WindowPane, null), ctx.pane);
    try std.testing.expectEqual(@as(?[]const u8, null), ctx.message_text);
    try std.testing.expectEqual(format_mod.FormatType.unknown, ctx.format_type);
}

test "cmd-format: target_context forwards message_text" {
    var fs: T.CmdFindState = .{};
    const msg = "hello world";
    const ctx = cmd_format.target_context(&fs, msg);

    try std.testing.expect(ctx.message_text != null);
    try std.testing.expectEqualStrings("hello world", ctx.message_text.?);
}

// ---------------------------------------------------------------------------
// Tests: require (format string forwarding)
// ---------------------------------------------------------------------------

test "cmd-format: require returns literal text when no variables present" {
    var item = makeDummyItem();
    var ctx = emptyContext();

    const result = cmd_format.require(&item, "plain text", &ctx);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("plain text", result.?);
    xm.allocator.free(result.?);
}

test "cmd-format: require returns null for incomplete expansion" {
    var item = makeDummyItem();
    var ctx = emptyContext();

    // #{nonexistent_variable} is not resolvable → Incomplete → null.
    const result = cmd_format.require(&item, "#{nonexistent_variable}", &ctx);
    try std.testing.expectEqual(@as(?[]u8, null), result);
}

// ---------------------------------------------------------------------------
// Tests: filter
// ---------------------------------------------------------------------------

test "cmd-format: filter returns true for truthy literal" {
    var item = makeDummyItem();
    var ctx = emptyContext();

    // A bare "1" is truthy per format_truthy.
    const result = cmd_format.filter(&item, "1", &ctx);
    try std.testing.expect(result != null);
    try std.testing.expect(result.?);
}

test "cmd-format: filter returns false for falsy literal" {
    var item = makeDummyItem();
    var ctx = emptyContext();

    const result = cmd_format.filter(&item, "0", &ctx);
    try std.testing.expect(result != null);
    try std.testing.expect(!result.?);
}

test "cmd-format: filter returns null for incomplete filter expression" {
    var item = makeDummyItem();
    var ctx = emptyContext();

    const result = cmd_format.filter(&item, "#{nonexistent_variable}", &ctx);
    try std.testing.expectEqual(@as(?bool, null), result);
}

// ---------------------------------------------------------------------------
// Tests: unsupported_message constant
// ---------------------------------------------------------------------------

test "cmd-format: unsupported_message is the expected string" {
    try std.testing.expectEqualStrings(
        "format expansion not supported yet",
        cmd_format.unsupported_message,
    );
}
