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
// Ported from tmux/regsub.c.
// Original copyright:
//   Copyright (c) 2019 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

const std = @import("std");
const c = @import("c.zig");
const xm = @import("xmalloc.zig");

pub fn regsub(
    alloc: std.mem.Allocator,
    pattern: []const u8,
    with: []const u8,
    text: []const u8,
    flags: c_int,
) ?[]u8 {
    if (text.len == 0) return alloc.dupe(u8, "") catch unreachable;

    const pattern_z = alloc.dupeZ(u8, pattern) catch unreachable;
    defer alloc.free(pattern_z);
    const text_z = alloc.dupeZ(u8, text) catch unreachable;
    defer alloc.free(text_z);

    const regex = c.posix_sys.zmux_regex_new() orelse return null;
    defer c.posix_sys.zmux_regex_free(regex);
    if (c.posix_sys.zmux_regex_compile(regex, pattern_z.ptr, flags) != 0) return null;

    var matches: [10]c.posix_sys.regmatch_t = undefined;
    var buf: std.ArrayList(u8) = .{};
    var start: usize = 0;
    var last: usize = 0;
    const end = text.len;
    var empty = false;

    while (start <= end) {
        const rc = c.posix_sys.zmux_regex_exec(
            regex,
            @ptrCast(text_z.ptr + start),
            matches.len,
            &matches,
        );
        if (rc != 0) {
            buf.appendSlice(alloc, text[last..end]) catch unreachable;
            break;
        }

        const match_start: usize = @intCast(matches[0].rm_so);
        const match_end: usize = @intCast(matches[0].rm_eo);
        buf.appendSlice(alloc, text[last .. start + match_start]) catch unreachable;

        if (empty or start + match_start != last or match_start != match_end) {
            regsub_expand(alloc, &buf, with, text[start..], &matches);
            last = start + match_end;
            start += match_end;
            empty = false;
        } else {
            last = start + match_end;
            start += match_end + 1;
            empty = true;
        }

        if (pattern.len > 0 and pattern[0] == '^') {
            if (start <= end) buf.appendSlice(alloc, text[start..end]) catch unreachable;
            break;
        }
    }

    return buf.toOwnedSlice(alloc) catch unreachable;
}

fn regsub_expand(
    alloc: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    with: []const u8,
    text: []const u8,
    matches: *const [10]c.posix_sys.regmatch_t,
) void {
    var i: usize = 0;
    while (i < with.len) : (i += 1) {
        if (with[i] == '\\' and i + 1 < with.len) {
            const next = with[i + 1];
            if (next >= '0' and next <= '9') {
                const idx: usize = next - '0';
                const match = matches[idx];
                if (match.rm_so >= 0 and match.rm_eo >= 0 and match.rm_so != match.rm_eo) {
                    const start: usize = @intCast(match.rm_so);
                    const end: usize = @intCast(match.rm_eo);
                    buf.appendSlice(alloc, text[start..end]) catch unreachable;
                    i += 1;
                    continue;
                }
            }
            i += 1;
            if (i >= with.len) break;
        }
        buf.append(alloc, with[i]) catch unreachable;
    }
}

test "regsub replaces matches and captures" {
    const out = regsub(xm.allocator, "a(.)", "\\1x", "abABab", c.posix_sys.REG_EXTENDED | c.posix_sys.REG_ICASE).?;
    defer xm.allocator.free(out);
    try std.testing.expectEqualStrings("bxBxbx", out);
}

test "regsub respects anchored replacement" {
    const out = regsub(xm.allocator, "^foo", "bar", "foobar", c.posix_sys.REG_EXTENDED).?;
    defer xm.allocator.free(out);
    try std.testing.expectEqualStrings("barbar", out);
}
