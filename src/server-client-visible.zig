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

//! Visible range bookkeeping for client overlay drawing (server-client.c correlate).

const xm = @import("xmalloc.zig");

pub const VisibleRange = struct {
    px: u32 = 0,
    nx: u32 = 0,
};

pub const VisibleRanges = struct {
    ranges: ?[]VisibleRange = null,
    size: u32 = 0,
    used: u32 = 0,
};

pub fn server_client_overlay_range(
    x: u32,
    y: u32,
    sx: u32,
    sy: u32,
    px: u32,
    py: u32,
    nx: u32,
    r: *VisibleRanges,
) void {
    if (py < y or py > y + sy -| 1) {
        server_client_ensure_ranges(r, 1);
        r.ranges.?[0].px = px;
        r.ranges.?[0].nx = nx;
        r.used = 1;
        return;
    }
    server_client_ensure_ranges(r, 2);

    if (px < x) {
        r.ranges.?[0].px = px;
        r.ranges.?[0].nx = @min(x - px, nx);
    } else {
        r.ranges.?[0].px = 0;
        r.ranges.?[0].nx = 0;
    }

    const ox = if (px > x + sx) px else x + sx;
    const onx = px + nx;
    if (onx > ox) {
        r.ranges.?[1].px = ox;
        r.ranges.?[1].nx = onx - ox;
    } else {
        r.ranges.?[1].px = 0;
        r.ranges.?[1].nx = 0;
    }
    r.used = 2;
}

pub fn server_client_ranges_is_empty(r: *const VisibleRanges) bool {
    if (r.ranges == null or r.used == 0) return true;
    for (r.ranges.?[0..r.used]) |rng| {
        if (rng.nx != 0) return false;
    }
    return true;
}

pub fn server_client_ensure_ranges(r: *VisibleRanges, n: u32) void {
    if (r.size >= n) return;
    if (r.ranges) |old| {
        const new = xm.allocator.realloc(old, n) catch unreachable;
        for (new[r.size..n]) |*slot| slot.* = .{};
        r.ranges = new;
    } else {
        const new = xm.allocator.alloc(VisibleRange, n) catch unreachable;
        for (new) |*slot| slot.* = .{};
        r.ranges = new;
    }
    r.size = n;
}
