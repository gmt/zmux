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
// Ported from tmux/xmalloc.c (originally by Tatu Ylonen)
// Original copyright:
//   Author: Tatu Ylonen <ylo@cs.hut.fi>
//   Copyright (c) 1995 Tatu Ylonen, Espoo, Finland
//   Free software – see original for terms.
//   Also Copyright (c) 2007 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

//! xmalloc.zig – fatal-on-OOM allocator wrapper.
//!
//! In tmux, xmalloc/xcalloc/xrealloc abort on allocation failure rather than
//! returning an error.  We expose a std.mem.Allocator that has the same
//! behaviour.  All zmux heap allocations should use `alloc` from this module.

const std = @import("std");
const log = @import("log.zig");

// ── Fatal allocator ───────────────────────────────────────────────────────

/// Allocator that panics instead of returning OutOfMemory.
/// This matches tmux's xmalloc() contract.
var _gpa = std.heap.GeneralPurposeAllocator(.{}){};

/// The global general-purpose allocator used throughout zmux.
/// Uses libc malloc to avoid GPA debug-mode safety panics in the daemon
/// child after fork(), where the GPA's internal state may be stale.
pub const allocator: std.mem.Allocator = std.heap.c_allocator;

const FatalAllocator = struct {
    const alloc_inst: std.mem.Allocator = .{
        .ptr = undefined,
        .vtable = &vtable,
    };
    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc_fn,
        .resize = resize_fn,
        .remap = remap_fn,
        .free = free_fn,
    };

    fn alloc_fn(_: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        return _gpa.allocator().rawAlloc(len, alignment, ret_addr) orelse {
            log.fatalx("xmalloc: allocating {d} bytes: out of memory", .{len});
        };
    }
    fn resize_fn(_: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        return _gpa.allocator().rawResize(buf, alignment, new_len, ret_addr);
    }
    fn remap_fn(_: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        // Try in-place remap first
        if (_gpa.allocator().rawRemap(buf, alignment, new_len, ret_addr)) |p| return p;
        // remap returned null = need new alloc + copy + free (not a failure)
        const new_ptr = _gpa.allocator().rawAlloc(new_len, alignment, ret_addr) orelse {
            log.fatalx("xrealloc: allocating {d} bytes: out of memory", .{new_len});
        };
        const copy_len = @min(buf.len, new_len);
        @memcpy(new_ptr[0..copy_len], buf[0..copy_len]);
        _gpa.allocator().rawFree(buf, alignment, ret_addr);
        return new_ptr;
    }
    fn free_fn(_: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        _gpa.allocator().rawFree(buf, alignment, ret_addr);
    }
};

// ── Convenience helpers matching tmux's xmalloc API ──────────────────────

pub fn xmalloc(size: usize) []u8 {
    return allocator.alloc(u8, size) catch unreachable;
}

pub fn xcalloc(T: type, n: usize) []T {
    const s = allocator.alloc(T, n) catch unreachable;
    @memset(s, std.mem.zeroes(T));
    return s;
}

pub fn xstrdup(s: []const u8) []u8 {
    return allocator.dupe(u8, s) catch unreachable;
}

pub fn xm_dupeZ(s: []const u8) [:0]u8 {
    return allocator.dupeZ(u8, s) catch unreachable;
}

pub fn xstrndup(s: []const u8, maxlen: usize) []u8 {
    const n = @min(s.len, maxlen);
    return allocator.dupe(u8, s[0..n]) catch unreachable;
}

pub fn xfree(p: anytype) void {
    allocator.free(p);
}

/// Print-format a string into a newly allocated slice.
pub fn xasprintf(comptime fmt: []const u8, args: anytype) []u8 {
    return std.fmt.allocPrint(allocator, fmt, args) catch unreachable;
}
