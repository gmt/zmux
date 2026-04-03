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

//! Unit tests for [xmalloc.zig](xmalloc.zig) helpers and safe [log.zig](log.zig) entrypoints.

const std = @import("std");
const xm = @import("xmalloc.zig");
const log_mod = @import("log.zig");

test "xstrdup copies and xstrndup truncates" {
    const s = xm.xstrdup("abc");
    defer xm.allocator.free(s);
    try std.testing.expectEqualStrings("abc", s);

    const t = xm.xstrndup("abcdef", 3);
    defer xm.allocator.free(t);
    try std.testing.expectEqualStrings("abc", t);
}

test "xasprintf formats into a new slice" {
    const s = xm.xasprintf("{s}-{d}", .{ "n", 7 });
    defer xm.allocator.free(s);
    try std.testing.expectEqualStrings("n-7", s);
}

test "xcalloc yields zeroed elements" {
    const xs = xm.xcalloc(u32, 4);
    defer xm.allocator.free(xs);
    for (xs) |v| try std.testing.expectEqual(@as(u32, 0), v);
}

test "xm_dupeZ is nul-terminated" {
    const z = xm.xm_dupeZ("hi");
    defer xm.allocator.free(z);
    try std.testing.expectEqual(@as(usize, 2), z.len);
    try std.testing.expectEqual(@as(u8, 0), z.ptr[2]);
}

test "log_close is idempotent when log is inactive" {
    log_mod.log_close();
    log_mod.log_close();
}
