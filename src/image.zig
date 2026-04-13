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
// WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
// ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
// OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
//
// Ported from tmux/image.c.
// Original copyright:
//   Copyright (c) 2007 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

//! image.zig – image storage, placement tracking, and LRU eviction.
//!
//! Images are sixel pixel grids placed at a cell position on a screen.
//! A global list capped at MAX_IMAGE_COUNT provides LRU eviction: when the
//! count reaches the limit the oldest image is freed.

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const log_mod = @import("log.zig");
const sixel_mod = @import("image-sixel.zig");

// ── Global LRU list ───────────────────────────────────────────────────────

/// Maximum simultaneous images across all screens.
const MAX_IMAGE_COUNT: u32 = 20;

/// Global list of all live images (LRU order: oldest first).
var all_images: std.ArrayListUnmanaged(*T.Image) = .{};
var all_images_count: u32 = 0;

// ── Logging helper ────────────────────────────────────────────────────────

fn image_log(im: *const T.Image, from: []const u8) void {
    log_mod.log_debug("{s}: {} ({}x{} {},{} )", .{ from, @intFromPtr(im), im.sx, im.sy, im.px, im.py });
}

// ── Text fallback placeholder ─────────────────────────────────────────────

/// Create a text placeholder for an image (mirrors `image_fallback` in image.c).
///
/// Returns a heap-allocated byte slice containing the placeholder text.
/// The caller owns the memory and should free it with `xm.allocator.free`.
fn image_fallback(sx: u32, sy: u32) []u8 {
    // First line: "SIXEL IMAGE (WxH)\r\n", padded/truncated to `sx` columns.
    const label = std.fmt.allocPrint(xm.allocator, "SIXEL IMAGE ({d}x{d})\r\n", .{ sx, sy }) catch unreachable;
    defer xm.allocator.free(label);

    // lsize includes trailing \r\n and NUL from the C version.
    const lsize: u32 = @intCast(label.len + 1);
    const first_line_len: u32 = if (sx < lsize - 3) lsize - 1 else sx + 2;
    // Remaining (sy-1) lines are sx '+' chars plus "\r\n".
    const total: u32 = first_line_len + (sx + 2) * (sy -| 1) + 1;

    var buf = xm.allocator.alloc(u8, total) catch unreachable;
    var pos: usize = 0;

    // First line.
    if (sx < lsize - 3) {
        @memcpy(buf[pos .. pos + lsize - 1], label[0 .. lsize - 1]);
        pos += lsize - 1;
    } else {
        const prefix_len = lsize - 3;
        @memcpy(buf[pos .. pos + prefix_len], label[0..prefix_len]);
        pos += prefix_len;
        @memset(buf[pos .. pos + sx - prefix_len], '+');
        pos += sx - prefix_len;
        buf[pos] = '\r';
        buf[pos + 1] = '\n';
        pos += 2;
    }

    // Remaining lines.
    var py: u32 = 1;
    while (py < sy) : (py += 1) {
        @memset(buf[pos .. pos + sx], '+');
        pos += sx;
        buf[pos] = '\r';
        buf[pos + 1] = '\n';
        pos += 2;
    }

    buf[pos] = 0;
    return buf[0..pos];
}

// ── Internal free ─────────────────────────────────────────────────────────

/// Remove and deallocate a single image from both the screen list and the
/// global LRU list.
fn image_free_internal(im: *T.Image) void {
    image_log(im, "image_free");

    // Remove from global list.
    const idx = for (all_images.items, 0..) |item, i| {
        if (item == im) break i;
    } else all_images.items.len;
    if (idx < all_images.items.len) _ = all_images.orderedRemove(idx);
    if (all_images_count > 0) all_images_count -= 1;

    // Remove from screen list.
    const s = im.s;
    const sidx = for (s.images.items, 0..) |item, i| {
        if (item == im) break i;
    } else s.images.items.len;
    if (sidx < s.images.items.len) _ = s.images.orderedRemove(sidx);

    sixel_mod.sixel_free(im.data);
    if (im.fallback) |fb| xm.allocator.free(fb);
    xm.allocator.destroy(im);
}

// ── Public API ────────────────────────────────────────────────────────────

/// Remove all images from screen `s`, returning true if any were present
/// (indicating the screen should be redrawn).
pub fn image_free_all(s: *T.Screen) bool {
    const had = s.images.items.len > 0;
    if (had) log_mod.log_debug("image_free_all", .{});

    while (s.images.items.len > 0) {
        image_free_internal(s.images.items[0]);
    }
    return had;
}

/// Place a new image on screen `s` backed by sixel data `si`.
///
/// The image is positioned at the current cursor, added to the screen's image
/// list and to the global LRU. If the global count reaches `MAX_IMAGE_COUNT`
/// the oldest image is evicted first.
///
/// Ownership of `si` transfers to the returned `Image`; do NOT call
/// `sixel_free(si)` after this succeeds.
pub fn image_store(s: *T.Screen, si: *T.SixelImage) *T.Image {
    const im = xm.allocator.create(T.Image) catch unreachable;
    im.* = .{
        .s = s,
        .data = si,
        .px = s.cx,
        .py = s.cy,
    };
    sixel_mod.sixel_size_in_cells(si, &im.sx, &im.sy);
    im.fallback = image_fallback(im.sx, im.sy);

    image_log(im, "image_store");

    s.images.append(xm.allocator, im) catch unreachable;

    all_images.append(xm.allocator, im) catch unreachable;
    all_images_count += 1;

    // LRU eviction: free the oldest (first in list) when over capacity.
    if (all_images_count == MAX_IMAGE_COUNT) {
        image_free_internal(all_images.items[0]);
    }

    return im;
}

/// Check whether any image on screen `s` overlaps the horizontal band
/// `[py, py+ny)` and free any that do.
/// Returns true if any images were freed (caller should redraw).
pub fn image_check_line(s: *T.Screen, py: u32, ny: u32) bool {
    var redraw = false;
    var i: usize = 0;
    while (i < s.images.items.len) {
        const im = s.images.items[i];
        const overlaps = (py + ny > im.py) and (py < im.py + im.sy);
        log_mod.log_debug("image_check_line: {} py={d} ny={d} in={}", .{ @intFromPtr(im), py, ny, overlaps });
        if (overlaps) {
            image_free_internal(im);
            redraw = true;
            // Don't advance i; the item was removed.
        } else {
            i += 1;
        }
    }
    return redraw;
}

/// Check whether any image on screen `s` overlaps the rectangle
/// `(px, py, px+nx, py+ny)` and free any that do.
/// Returns true if any images were freed (caller should redraw).
pub fn image_check_area(s: *T.Screen, px: u32, py: u32, nx: u32, ny: u32) bool {
    var redraw = false;
    var i: usize = 0;
    while (i < s.images.items.len) {
        const im = s.images.items[i];
        const overlaps = (py < im.py + im.sy) and
            (py + ny > im.py) and
            (px < im.px + im.sx) and
            (px + nx > im.px);
        log_mod.log_debug("image_check_area: {} py={d} ny={d} in={}", .{ @intFromPtr(im), py, ny, overlaps });
        if (overlaps) {
            image_free_internal(im);
            redraw = true;
            // Don't advance i; the item was removed.
        } else {
            i += 1;
        }
    }
    return redraw;
}

/// Scroll all images on screen `s` up by `lines` rows.
///
/// Images that move fully off the top are freed. Images that are partially
/// cropped are re-scaled. Returns true if a redraw is required.
pub fn image_scroll_up(s: *T.Screen, lines: u32) bool {
    var redraw = false;
    var i: usize = 0;
    while (i < s.images.items.len) {
        const im = s.images.items[i];

        if (im.py >= lines) {
            // Image is entirely below the scroll region – shift up.
            log_mod.log_debug("image_scroll_up: {} 1, lines={d}", .{ @intFromPtr(im), lines });
            im.py -= lines;
            redraw = true;
            i += 1;
            continue;
        }

        if (im.py + im.sy <= lines) {
            // Image is entirely above the new top – discard it.
            log_mod.log_debug("image_scroll_up: {} 2, lines={d}", .{ @intFromPtr(im), lines });
            image_free_internal(im);
            redraw = true;
            continue; // swapRemove shifted items; don't advance i.
        }

        // Image straddles the boundary – crop the top `lines` rows.
        const sx = im.sx;
        const sy = (im.py + im.sy) - lines;
        log_mod.log_debug("image_scroll_up: {} 3, lines={d}, sy={d}", .{ @intFromPtr(im), lines, sy });

        const new_si = sixel_mod.sixel_scale(im.data, 0, 0, 0, im.sy - sy, sx, sy, true) orelse {
            image_free_internal(im);
            redraw = true;
            continue;
        };
        sixel_mod.sixel_free(im.data);
        im.data = new_si;
        im.py = 0;
        sixel_mod.sixel_size_in_cells(im.data, &im.sx, &im.sy);

        if (im.fallback) |fb| xm.allocator.free(fb);
        im.fallback = image_fallback(im.sx, im.sy);

        redraw = true;
        i += 1;
    }
    return redraw;
}

// ── Tests ──────────────────────────────────────────────────────────────────

test "image_store and image_free_all" {
    const testing = std.testing;

    // Allocate a small dummy SixelImage by parsing a minimal sixel stream.
    const data = "q#0;2;100;0;0~";
    const si = sixel_mod.sixel_parse(data, 0, 8, 16) orelse return error.TestUnexpectedResult;

    // Create a minimal Screen.
    const grid_mod = @import("grid.zig");
    const s = blk: {
        const screen = xm.allocator.create(T.Screen) catch unreachable;
        screen.* = .{ .grid = grid_mod.grid_create(80, 24, 0) };
        break :blk screen;
    };
    defer {
        grid_mod.grid_free(s.grid);
        xm.allocator.destroy(s);
    }

    _ = image_store(s, si);
    try testing.expectEqual(@as(usize, 1), s.images.items.len);

    const had = image_free_all(s);
    try testing.expect(had);
    try testing.expectEqual(@as(usize, 0), s.images.items.len);
}

test "image_check_line overlap" {
    const testing = std.testing;
    const grid_mod = @import("grid.zig");

    const s = blk: {
        const screen = xm.allocator.create(T.Screen) catch unreachable;
        screen.* = .{ .grid = grid_mod.grid_create(80, 24, 0) };
        break :blk screen;
    };
    defer {
        grid_mod.grid_free(s.grid);
        xm.allocator.destroy(s);
    }

    // Create two sixel images.
    const data = "q#0;2;100;0;0~";
    const si1 = sixel_mod.sixel_parse(data, 0, 8, 16) orelse return error.TestUnexpectedResult;
    const si2 = sixel_mod.sixel_parse(data, 0, 8, 16) orelse {
        sixel_mod.sixel_free(si1);
        return error.TestUnexpectedResult;
    };

    // Place first image at row 2, second at row 10.
    s.cx = 0;
    s.cy = 2;
    _ = image_store(s, si1);
    s.cx = 0;
    s.cy = 10;
    _ = image_store(s, si2);
    try testing.expectEqual(@as(usize, 2), s.images.items.len);

    // Check line 2: should hit the first image.
    const redraw = image_check_line(s, 2, 1);
    try testing.expect(redraw);
    try testing.expectEqual(@as(usize, 1), s.images.items.len);

    // Clean up remaining.
    _ = image_free_all(s);
}

test "image_free_all on empty screen returns false" {
    const grid_mod = @import("grid.zig");
    const s = blk: {
        const screen = xm.allocator.create(T.Screen) catch unreachable;
        screen.* = .{ .grid = grid_mod.grid_create(8, 4, 0) };
        break :blk screen;
    };
    defer {
        grid_mod.grid_free(s.grid);
        xm.allocator.destroy(s);
    }

    try std.testing.expect(!image_free_all(s));
}

test "image_check_line with no stored images returns false" {
    const grid_mod = @import("grid.zig");
    const s = blk: {
        const screen = xm.allocator.create(T.Screen) catch unreachable;
        screen.* = .{ .grid = grid_mod.grid_create(40, 20, 0) };
        break :blk screen;
    };
    defer {
        grid_mod.grid_free(s.grid);
        xm.allocator.destroy(s);
    }

    try std.testing.expect(!image_check_line(s, 3, 2));
}

test "image_check_area frees only overlapping rectangles" {
    const grid_mod = @import("grid.zig");

    const s = blk: {
        const screen = xm.allocator.create(T.Screen) catch unreachable;
        screen.* = .{ .grid = grid_mod.grid_create(80, 24, 0) };
        break :blk screen;
    };
    defer {
        grid_mod.grid_free(s.grid);
        xm.allocator.destroy(s);
    }

    const data = "q#0;2;100;0;0~";
    const si1 = sixel_mod.sixel_parse(data, 0, 8, 16) orelse return error.TestUnexpectedResult;
    const si2 = sixel_mod.sixel_parse(data, 0, 8, 16) orelse {
        sixel_mod.sixel_free(si1);
        return error.TestUnexpectedResult;
    };

    s.cx = 0;
    s.cy = 2;
    _ = image_store(s, si1);
    s.cx = 20;
    s.cy = 10;
    _ = image_store(s, si2);
    try std.testing.expectEqual(@as(usize, 2), s.images.items.len);

    try std.testing.expect(!image_check_area(s, 0, 0, 1, 1));
    try std.testing.expectEqual(@as(usize, 2), s.images.items.len);

    const redraw = image_check_area(s, 0, 2, 80, 1);
    try std.testing.expect(redraw);
    try std.testing.expectEqual(@as(usize, 1), s.images.items.len);

    _ = image_free_all(s);
}
