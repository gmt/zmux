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
// Ported in part from tmux/format-draw.c.
// Original copyright:
//   Copyright (c) 2019 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

//! format-draw.zig – fuller style-aware format rendering over shared cells.

const std = @import("std");
const T = @import("types.zig");
const grid = @import("grid.zig");
const screen_mod = @import("screen.zig");
const screen_write = @import("screen-write.zig");
const style_mod = @import("style.zig");
const utf8 = @import("utf8.zig");
const xm = @import("xmalloc.zig");

pub const DrawRange = T.StyleRange;
pub const DrawRanges = T.StyleRanges;

const Segment = enum(usize) {
    left,
    centre,
    right,
    absolute_centre,
    list,
    list_left,
    list_right,
    after,
};

const segment_count = @typeInfo(Segment).@"enum".fields.len;

fn segmentIndex(comptime segment: Segment) usize {
    return @intFromEnum(segment);
}

const InternalRange = struct {
    segment: Segment,
    start: u32,
    end: u32,
    type: T.StyleRangeType,
    argument: u32 = 0,
    string: [16]u8 = std.mem.zeroes([16]u8),
};

const ActiveRange = struct {
    segment: Segment,
    start: u32,
    type: T.StyleRangeType,
    argument: u32 = 0,
    string: [16]u8 = std.mem.zeroes([16]u8),
};

pub fn format_width(expanded: []const u8) u32 {
    var width: u32 = 0;
    var pos: usize = 0;
    var decoder = utf8.Decoder.init();

    while (pos < expanded.len) {
        if (expanded[pos] == '#') {
            const count = countHashes(expanded[pos..]);
            if (count > 1 or (pos + 1 < expanded.len and expanded[pos + 1] != '[')) {
                const hashes = leadingHashes(expanded[pos..]);
                width += hashes.literal_hashes;
                pos += hashes.advance;
                if (hashes.literal_bracket) width += 1;
                if (hashes.style or hashes.literal_bracket) continue;
            }
            if (pos + 1 < expanded.len and expanded[pos + 1] == '[') {
                const end = std.mem.indexOfScalarPos(u8, expanded, pos + 2, ']') orelse return 0;
                pos = end + 1;
                continue;
            }
        }

        switch (decoder.feed(expanded[pos..])) {
            .glyph => |step| {
                width += step.glyph.width();
                pos += step.consumed;
            },
            .invalid, .need_more => {
                if (expanded[pos] > 0x1f and expanded[pos] < 0x7f) width += 1;
                pos += 1;
                decoder.reset();
            },
        }
    }

    return width;
}

pub fn format_draw(
    ctx: *T.ScreenWriteCtx,
    base: *const T.GridCell,
    available: u32,
    expanded: []const u8,
) void {
    format_draw_ranges(ctx, base, available, expanded, null);
}

pub fn format_draw_ranges(
    ctx: *T.ScreenWriteCtx,
    base: *const T.GridCell,
    available: u32,
    expanded: []const u8,
    ranges: ?*DrawRanges,
) void {
    if (available == 0) return;
    if (ranges) |out| out.clearRetainingCapacity();

    const target_x = ctx.s.cx;
    const target_y = ctx.s.cy;
    const temp_width: u32 = @intCast(@max(expanded.len, 1));

    var screens: [segment_count]*T.Screen = undefined;
    var seg_ctx: [segment_count]T.ScreenWriteCtx = undefined;
    defer {
        for (screens) |screen| {
            screen_mod.screen_free(screen);
            xm.allocator.destroy(screen);
        }
    }
    for (0..segment_count) |idx| {
        screens[idx] = screen_mod.screen_init(temp_width, 1, 0);
        seg_ctx[idx] = .{ .s = screens[idx] };
    }

    var base_default = base.*;
    var current_default = base.*;
    var sy: T.Style = undefined;
    style_mod.style_set(&sy, &current_default);

    var align_map = [_]Segment{
        .left,
        .left,
        .centre,
        .right,
        .absolute_centre,
    };
    var current: Segment = .left;
    var list_align: T.StyleAlign = .default;
    var list_state: i32 = -1;
    var focus_start: i32 = -1;
    var focus_end: i32 = -1;
    var fill: i32 = -1;
    var pos: usize = 0;
    var decoder = utf8.Decoder.init();
    var active_range: ?ActiveRange = null;
    var internal_ranges: std.ArrayList(InternalRange) = .{};
    defer internal_ranges.deinit(xm.allocator);

    while (pos < expanded.len) {
        if (expanded[pos] == '#') {
            const count = countHashes(expanded[pos..]);
            if (count > 1 or (pos + 1 < expanded.len and expanded[pos + 1] != '[')) {
                const hashes = leadingHashes(expanded[pos..]);
                if (hashes.literal_hashes != 0) {
                    drawMany(&seg_ctx[@intFromEnum(current)], &sy.gc, '#', hashes.literal_hashes);
                }
                pos += hashes.advance;
                if (hashes.literal_bracket) {
                    drawAsciiToSegment(&seg_ctx[@intFromEnum(current)], &sy.gc, '[');
                    continue;
                }
                if (hashes.style) continue;
            }
        }

        if (!(expanded[pos] == '#' and pos + 1 < expanded.len and expanded[pos + 1] == '[') or sy.ignore) {
            switch (decoder.feed(expanded[pos..])) {
                .glyph => |step| {
                    sy.gc.data = step.glyph.data;
                    screen_write.putCell(&seg_ctx[@intFromEnum(current)], &sy.gc);
                    pos += step.consumed;
                },
                .invalid, .need_more => {
                    const ch = expanded[pos];
                    if (ch > 0x1f and ch < 0x7f) {
                        drawAsciiToSegment(&seg_ctx[@intFromEnum(current)], &sy.gc, ch);
                    }
                    pos += 1;
                    decoder.reset();
                },
            }
            continue;
        }

        const end = std.mem.indexOfScalarPos(u8, expanded, pos + 2, ']') orelse break;
        const token = expanded[pos + 2 .. end];
        const saved_sy = sy;
        var next_sy = sy;
        if (style_mod.style_parse(&next_sy, &current_default, token) == 0) {
            sy = next_sy;
            if (sy.fill != 8) fill = sy.fill;

            switch (sy.default_type) {
                .push => {
                    current_default = saved_sy.gc;
                    sy.default_type = .base;
                },
                .pop => {
                    current_default = base_default;
                    sy.default_type = .base;
                },
                .set => {
                    base_default = saved_sy.gc;
                    current_default = saved_sy.gc;
                    sy.default_type = .base;
                },
                .base => {},
            }

            switch (sy.list) {
                .on => {
                    if (list_state != 0) {
                        active_range = null;
                        list_state = 0;
                        list_align = sy.@"align";
                    }
                    if (focus_start != -1 and focus_end == -1) {
                        focus_end = @intCast(segmentWidth(screens[segmentIndex(.list)]));
                    }
                    current = .list;
                },
                .focus => {
                    if (list_state == 0 and focus_start == -1) {
                        focus_start = @intCast(segmentWidth(screens[segmentIndex(.list)]));
                    }
                },
                .off => {
                    if (list_state == 0) {
                        active_range = null;
                        if (focus_start != -1 and focus_end == -1) {
                            focus_end = @intCast(segmentWidth(screens[segmentIndex(.list)]));
                        }
                        align_map[@intFromEnum(list_align)] = .after;
                        if (list_align == .left) {
                            align_map[@intFromEnum(T.StyleAlign.default)] = .after;
                        }
                        list_state = 1;
                    }
                    current = align_map[@intFromEnum(sy.@"align")];
                },
                .left_marker => {
                    if (list_state == 0 and segmentWidth(screens[segmentIndex(.list_left)]) == 0) {
                        active_range = null;
                        if (focus_start != -1 and focus_end == -1) {
                            focus_start = -1;
                            focus_end = -1;
                        }
                        current = .list_left;
                    }
                },
                .right_marker => {
                    if (list_state == 0 and segmentWidth(screens[segmentIndex(.list_right)]) == 0) {
                        active_range = null;
                        if (focus_start != -1 and focus_end == -1) {
                            focus_start = -1;
                            focus_end = -1;
                        }
                        current = .list_right;
                    }
                },
            }

            if (ranges != null) {
                updateRangeState(&active_range, &internal_ranges, screens, current, &sy);
            }
        }
        pos = end + 1;
    }

    if (fill != -1) fillAvailable(ctx, fill, available);

    switch (list_align) {
        .default => drawWithoutList(ctx, target_x, target_y, available, screens, internal_ranges.items, ranges),
        .left => drawWithLeftList(ctx, target_x, target_y, available, screens, focus_start, focus_end, internal_ranges.items, ranges),
        .centre => drawWithCentreList(ctx, target_x, target_y, available, screens, focus_start, focus_end, internal_ranges.items, ranges),
        .right => drawWithRightList(ctx, target_x, target_y, available, screens, focus_start, focus_end, internal_ranges.items, ranges),
        .absolute_centre => drawWithAbsoluteCentreList(ctx, target_x, target_y, available, screens, focus_start, focus_end, internal_ranges.items, ranges),
    }

    screen_write.cursor_to(ctx, target_y, target_x);
}

fn drawWithoutList(
    ctx: *T.ScreenWriteCtx,
    target_x: u32,
    target_y: u32,
    available: u32,
    screens: [segment_count]*T.Screen,
    internal_ranges: []const InternalRange,
    ranges: ?*DrawRanges,
) void {
    var width_left = segmentWidth(screens[segmentIndex(.left)]);
    var width_centre = segmentWidth(screens[segmentIndex(.centre)]);
    var width_right = segmentWidth(screens[segmentIndex(.right)]);
    var width_abs_centre = segmentWidth(screens[segmentIndex(.absolute_centre)]);

    while (width_left + width_centre + width_right > available) {
        if (width_centre > 0)
            width_centre -= 1
        else if (width_right > 0)
            width_right -= 1
        else
            width_left -= 1;
    }

    copySegment(ctx, target_x, target_y, screens[segmentIndex(.left)], internal_ranges, ranges, .left, 0, 0, width_left);
    copySegment(
        ctx,
        target_x,
        target_y,
        screens[segmentIndex(.right)],
        internal_ranges,
        ranges,
        .right,
        available - width_right,
        segmentWidth(screens[segmentIndex(.right)]) - width_right,
        width_right,
    );
    copySegment(
        ctx,
        target_x,
        target_y,
        screens[segmentIndex(.centre)],
        internal_ranges,
        ranges,
        .centre,
        width_left + ((available - width_right) - width_left) / 2 - width_centre / 2,
        segmentWidth(screens[segmentIndex(.centre)]) / 2 - width_centre / 2,
        width_centre,
    );
    if (width_abs_centre > available) width_abs_centre = available;
    copySegment(
        ctx,
        target_x,
        target_y,
        screens[segmentIndex(.absolute_centre)],
        internal_ranges,
        ranges,
        .absolute_centre,
        (available - width_abs_centre) / 2,
        0,
        width_abs_centre,
    );
}

fn drawWithLeftList(
    ctx: *T.ScreenWriteCtx,
    target_x: u32,
    target_y: u32,
    available: u32,
    screens: [segment_count]*T.Screen,
    focus_start: i32,
    focus_end: i32,
    internal_ranges: []const InternalRange,
    ranges: ?*DrawRanges,
) void {
    var width_left = segmentWidth(screens[segmentIndex(.left)]);
    var width_centre = segmentWidth(screens[segmentIndex(.centre)]);
    var width_right = segmentWidth(screens[segmentIndex(.right)]);
    var width_abs_centre = segmentWidth(screens[segmentIndex(.absolute_centre)]);
    var width_list = segmentWidth(screens[segmentIndex(.list)]);
    var width_after = segmentWidth(screens[segmentIndex(.after)]);

    while (width_left + width_centre + width_right + width_list + width_after > available) {
        if (width_centre > 0)
            width_centre -= 1
        else if (width_list > 0)
            width_list -= 1
        else if (width_right > 0)
            width_right -= 1
        else if (width_after > 0)
            width_after -= 1
        else
            width_left -= 1;
    }

    if (width_list == 0) {
        appendScreen(screens[segmentIndex(.left)], screens[segmentIndex(.after)], width_after);
        drawWithoutList(ctx, target_x, target_y, available, screens, internal_ranges, ranges);
        return;
    }

    copySegment(ctx, target_x, target_y, screens[segmentIndex(.left)], internal_ranges, ranges, .left, 0, 0, width_left);
    copySegment(
        ctx,
        target_x,
        target_y,
        screens[segmentIndex(.right)],
        internal_ranges,
        ranges,
        .right,
        available - width_right,
        segmentWidth(screens[segmentIndex(.right)]) - width_right,
        width_right,
    );
    copySegment(
        ctx,
        target_x,
        target_y,
        screens[segmentIndex(.after)],
        internal_ranges,
        ranges,
        .after,
        width_left + width_list,
        0,
        width_after,
    );
    copySegment(
        ctx,
        target_x,
        target_y,
        screens[segmentIndex(.centre)],
        internal_ranges,
        ranges,
        .centre,
        width_left + width_list + width_after + ((available - width_right) - (width_left + width_list + width_after)) / 2 - width_centre / 2,
        segmentWidth(screens[segmentIndex(.centre)]) / 2 - width_centre / 2,
        width_centre,
    );

    var list_focus_start = focus_start;
    var list_focus_end = focus_end;
    if (list_focus_start == -1 or list_focus_end == -1) {
        list_focus_start = 0;
        list_focus_end = 0;
    }
    copyList(
        ctx,
        target_x,
        target_y,
        width_left,
        width_list,
        screens,
        @intCast(list_focus_start),
        @intCast(list_focus_end),
        internal_ranges,
        ranges,
    );

    if (width_abs_centre > available) width_abs_centre = available;
    copySegment(
        ctx,
        target_x,
        target_y,
        screens[segmentIndex(.absolute_centre)],
        internal_ranges,
        ranges,
        .absolute_centre,
        (available - width_abs_centre) / 2,
        0,
        width_abs_centre,
    );
}

fn drawWithCentreList(
    ctx: *T.ScreenWriteCtx,
    target_x: u32,
    target_y: u32,
    available: u32,
    screens: [segment_count]*T.Screen,
    focus_start: i32,
    focus_end: i32,
    internal_ranges: []const InternalRange,
    ranges: ?*DrawRanges,
) void {
    var width_left = segmentWidth(screens[segmentIndex(.left)]);
    var width_centre = segmentWidth(screens[segmentIndex(.centre)]);
    var width_right = segmentWidth(screens[segmentIndex(.right)]);
    var width_abs_centre = segmentWidth(screens[segmentIndex(.absolute_centre)]);
    var width_list = segmentWidth(screens[segmentIndex(.list)]);
    var width_after = segmentWidth(screens[segmentIndex(.after)]);

    while (width_left + width_centre + width_right + width_list + width_after > available) {
        if (width_list > 0)
            width_list -= 1
        else if (width_after > 0)
            width_after -= 1
        else if (width_centre > 0)
            width_centre -= 1
        else if (width_right > 0)
            width_right -= 1
        else
            width_left -= 1;
    }

    if (width_list == 0) {
        appendScreen(screens[segmentIndex(.centre)], screens[segmentIndex(.after)], width_after);
        drawWithoutList(ctx, target_x, target_y, available, screens, internal_ranges, ranges);
        return;
    }

    copySegment(ctx, target_x, target_y, screens[segmentIndex(.left)], internal_ranges, ranges, .left, 0, 0, width_left);
    copySegment(
        ctx,
        target_x,
        target_y,
        screens[segmentIndex(.right)],
        internal_ranges,
        ranges,
        .right,
        available - width_right,
        segmentWidth(screens[segmentIndex(.right)]) - width_right,
        width_right,
    );

    const middle = width_left + ((available - width_right) - width_left) / 2;
    copySegment(
        ctx,
        target_x,
        target_y,
        screens[segmentIndex(.centre)],
        internal_ranges,
        ranges,
        .centre,
        middle - width_list / 2 - width_centre,
        0,
        width_centre,
    );
    copySegment(
        ctx,
        target_x,
        target_y,
        screens[segmentIndex(.after)],
        internal_ranges,
        ranges,
        .after,
        middle - width_list / 2 + width_list,
        0,
        width_after,
    );

    var list_focus_start = focus_start;
    var list_focus_end = focus_end;
    if (list_focus_start == -1 or list_focus_end == -1) {
        const middle_focus: i32 = @intCast(segmentWidth(screens[segmentIndex(.list)]) / 2);
        list_focus_start = middle_focus;
        list_focus_end = middle_focus;
    }
    copyList(
        ctx,
        target_x,
        target_y,
        middle - width_list / 2,
        width_list,
        screens,
        @intCast(list_focus_start),
        @intCast(list_focus_end),
        internal_ranges,
        ranges,
    );

    if (width_abs_centre > available) width_abs_centre = available;
    copySegment(
        ctx,
        target_x,
        target_y,
        screens[segmentIndex(.absolute_centre)],
        internal_ranges,
        ranges,
        .absolute_centre,
        (available - width_abs_centre) / 2,
        0,
        width_abs_centre,
    );
}

fn drawWithRightList(
    ctx: *T.ScreenWriteCtx,
    target_x: u32,
    target_y: u32,
    available: u32,
    screens: [segment_count]*T.Screen,
    focus_start: i32,
    focus_end: i32,
    internal_ranges: []const InternalRange,
    ranges: ?*DrawRanges,
) void {
    var width_left = segmentWidth(screens[segmentIndex(.left)]);
    var width_centre = segmentWidth(screens[segmentIndex(.centre)]);
    var width_right = segmentWidth(screens[segmentIndex(.right)]);
    var width_abs_centre = segmentWidth(screens[segmentIndex(.absolute_centre)]);
    var width_list = segmentWidth(screens[segmentIndex(.list)]);
    var width_after = segmentWidth(screens[segmentIndex(.after)]);

    while (width_left + width_centre + width_right + width_list + width_after > available) {
        if (width_centre > 0)
            width_centre -= 1
        else if (width_list > 0)
            width_list -= 1
        else if (width_right > 0)
            width_right -= 1
        else if (width_after > 0)
            width_after -= 1
        else
            width_left -= 1;
    }

    if (width_list == 0) {
        appendScreen(screens[segmentIndex(.right)], screens[segmentIndex(.after)], width_after);
        drawWithoutList(ctx, target_x, target_y, available, screens, internal_ranges, ranges);
        return;
    }

    copySegment(ctx, target_x, target_y, screens[segmentIndex(.left)], internal_ranges, ranges, .left, 0, 0, width_left);
    copySegment(
        ctx,
        target_x,
        target_y,
        screens[segmentIndex(.after)],
        internal_ranges,
        ranges,
        .after,
        available - width_after,
        segmentWidth(screens[segmentIndex(.after)]) - width_after,
        width_after,
    );
    copySegment(
        ctx,
        target_x,
        target_y,
        screens[segmentIndex(.right)],
        internal_ranges,
        ranges,
        .right,
        available - width_right - width_list - width_after,
        0,
        width_right,
    );
    copySegment(
        ctx,
        target_x,
        target_y,
        screens[segmentIndex(.centre)],
        internal_ranges,
        ranges,
        .centre,
        width_left + ((available - width_right - width_list - width_after) - width_left) / 2 - width_centre / 2,
        segmentWidth(screens[segmentIndex(.centre)]) / 2 - width_centre / 2,
        width_centre,
    );

    var list_focus_start = focus_start;
    var list_focus_end = focus_end;
    if (list_focus_start == -1 or list_focus_end == -1) {
        list_focus_start = 0;
        list_focus_end = 0;
    }
    copyList(
        ctx,
        target_x,
        target_y,
        available - width_list - width_after,
        width_list,
        screens,
        @intCast(list_focus_start),
        @intCast(list_focus_end),
        internal_ranges,
        ranges,
    );

    if (width_abs_centre > available) width_abs_centre = available;
    copySegment(
        ctx,
        target_x,
        target_y,
        screens[segmentIndex(.absolute_centre)],
        internal_ranges,
        ranges,
        .absolute_centre,
        (available - width_abs_centre) / 2,
        0,
        width_abs_centre,
    );
}

fn drawWithAbsoluteCentreList(
    ctx: *T.ScreenWriteCtx,
    target_x: u32,
    target_y: u32,
    available: u32,
    screens: [segment_count]*T.Screen,
    focus_start: i32,
    focus_end: i32,
    internal_ranges: []const InternalRange,
    ranges: ?*DrawRanges,
) void {
    var width_left = segmentWidth(screens[segmentIndex(.left)]);
    var width_centre = segmentWidth(screens[segmentIndex(.centre)]);
    var width_right = segmentWidth(screens[segmentIndex(.right)]);
    var width_abs_centre = segmentWidth(screens[segmentIndex(.absolute_centre)]);
    var width_list = segmentWidth(screens[segmentIndex(.list)]);
    var width_after = segmentWidth(screens[segmentIndex(.after)]);

    while (width_left + width_centre + width_right > available) {
        if (width_centre > 0)
            width_centre -= 1
        else if (width_right > 0)
            width_right -= 1
        else
            width_left -= 1;
    }
    while (width_list + width_after + width_abs_centre > available) {
        if (width_list > 0)
            width_list -= 1
        else if (width_after > 0)
            width_after -= 1
        else
            width_abs_centre -= 1;
    }

    copySegment(ctx, target_x, target_y, screens[segmentIndex(.left)], internal_ranges, ranges, .left, 0, 0, width_left);
    copySegment(
        ctx,
        target_x,
        target_y,
        screens[segmentIndex(.right)],
        internal_ranges,
        ranges,
        .right,
        available - width_right,
        segmentWidth(screens[segmentIndex(.right)]) - width_right,
        width_right,
    );

    const middle = width_left + ((available - width_right) - width_left) / 2;
    copySegment(
        ctx,
        target_x,
        target_y,
        screens[segmentIndex(.centre)],
        internal_ranges,
        ranges,
        .centre,
        middle - width_centre,
        0,
        width_centre,
    );

    var list_focus_start = focus_start;
    var list_focus_end = focus_end;
    if (list_focus_start == -1 or list_focus_end == -1) {
        const middle_focus: i32 = @intCast(segmentWidth(screens[segmentIndex(.list)]) / 2);
        list_focus_start = middle_focus;
        list_focus_end = middle_focus;
    }

    var offset = (available - width_list - width_abs_centre) / 2;
    copySegment(
        ctx,
        target_x,
        target_y,
        screens[segmentIndex(.absolute_centre)],
        internal_ranges,
        ranges,
        .absolute_centre,
        offset,
        0,
        width_abs_centre,
    );
    offset += width_abs_centre;
    copyList(
        ctx,
        target_x,
        target_y,
        offset,
        width_list,
        screens,
        @intCast(list_focus_start),
        @intCast(list_focus_end),
        internal_ranges,
        ranges,
    );
    offset += width_list;
    copySegment(
        ctx,
        target_x,
        target_y,
        screens[segmentIndex(.after)],
        internal_ranges,
        ranges,
        .after,
        offset,
        0,
        width_after,
    );
}

fn copyList(
    ctx: *T.ScreenWriteCtx,
    target_x: u32,
    target_y: u32,
    offset: u32,
    width: u32,
    screens: [segment_count]*T.Screen,
    focus_start: u32,
    focus_end: u32,
    internal_ranges: []const InternalRange,
    ranges: ?*DrawRanges,
) void {
    const list = screens[segmentIndex(.list)];
    const list_left = screens[segmentIndex(.list_left)];
    const list_right = screens[segmentIndex(.list_right)];

    if (width >= segmentWidth(list)) {
        copySegment(ctx, target_x, target_y, list, internal_ranges, ranges, .list, offset, 0, segmentWidth(list));
        return;
    }

    var start = focus_start + (focus_end - focus_start) / 2;
    if (start < width / 2)
        start = 0
    else
        start -= width / 2;
    if (start + width > segmentWidth(list))
        start = segmentWidth(list) - width;

    var copy_offset = offset;
    var copy_start = start;
    var copy_width = width;

    if (copy_start != 0 and copy_width > segmentWidth(list_left)) {
        copyScreenRaw(ctx.s, target_x + copy_offset, target_y, list_left, 0, segmentWidth(list_left));
        copy_offset += segmentWidth(list_left);
        copy_start += segmentWidth(list_left);
        copy_width -= segmentWidth(list_left);
    }
    if (copy_start + copy_width < segmentWidth(list) and copy_width > segmentWidth(list_right)) {
        copyScreenRaw(
            ctx.s,
            target_x + copy_offset + copy_width - segmentWidth(list_right),
            target_y,
            list_right,
            0,
            segmentWidth(list_right),
        );
        copy_width -= segmentWidth(list_right);
    }

    copySegment(ctx, target_x, target_y, list, internal_ranges, ranges, .list, copy_offset, copy_start, copy_width);
}

fn copySegment(
    ctx: *T.ScreenWriteCtx,
    target_x: u32,
    target_y: u32,
    src: *T.Screen,
    internal_ranges: []const InternalRange,
    ranges: ?*DrawRanges,
    segment: Segment,
    offset: u32,
    start: u32,
    width: u32,
) void {
    if (width == 0) return;
    copyScreenRaw(ctx.s, target_x + offset, target_y, src, start, width);
    if (ranges) |out| translateRanges(out, internal_ranges, segment, offset, start, width);
}

fn copyScreenRaw(dst: *T.Screen, dst_x: u32, dst_y: u32, src: *T.Screen, start: u32, width: u32) void {
    var dx: u32 = 0;
    while (dx < width and dst_x + dx < dst.grid.sx and start + dx < src.grid.sx) : (dx += 1) {
        var cell: T.GridCell = undefined;
        grid.get_cell(src.grid, 0, start + dx, &cell);
        grid.set_cell(dst.grid, dst_y, dst_x + dx, &cell);
    }
}

fn translateRanges(
    out: *DrawRanges,
    internal_ranges: []const InternalRange,
    segment: Segment,
    offset: u32,
    start: u32,
    width: u32,
) void {
    const end = start + width;
    for (internal_ranges) |entry| {
        if (entry.segment != segment) continue;
        const clip_start = @max(entry.start, start);
        const clip_end = @min(entry.end, end);
        if (clip_start >= clip_end) continue;
        out.append(xm.allocator, .{
            .type = entry.type,
            .argument = entry.argument,
            .string = entry.string,
            .start = offset + clip_start - start,
            .end = offset + clip_end - start,
        }) catch unreachable;
    }
}

fn updateRangeState(
    active_range: *?ActiveRange,
    internal_ranges: *std.ArrayList(InternalRange),
    screens: [segment_count]*T.Screen,
    current: Segment,
    sy: *const T.Style,
) void {
    if (active_range.*) |active| {
        if (active.segment != current or !rangeMatches(active, sy)) {
            closeRange(internal_ranges, active, segmentWidth(screens[@intFromEnum(active.segment)]));
            active_range.* = null;
        }
    }
    if (active_range.* == null and sy.range_type != .none) {
        active_range.* = .{
            .segment = current,
            .start = segmentWidth(screens[@intFromEnum(current)]),
            .type = sy.range_type,
            .argument = sy.range_argument,
            .string = sy.range_string,
        };
    }
}

fn closeRange(
    internal_ranges: *std.ArrayList(InternalRange),
    active: ActiveRange,
    end: u32,
) void {
    if (end <= active.start) return;
    internal_ranges.append(xm.allocator, .{
        .segment = active.segment,
        .start = active.start,
        .end = end,
        .type = active.type,
        .argument = active.argument,
        .string = active.string,
    }) catch unreachable;
}

fn rangeMatches(active: ActiveRange, sy: *const T.Style) bool {
    if (active.type != sy.range_type) return false;
    return switch (active.type) {
        .none, .left, .right => true,
        .pane, .window, .session => active.argument == sy.range_argument,
        .user => std.mem.eql(u8, std.mem.sliceTo(&active.string, 0), std.mem.sliceTo(&sy.range_string, 0)),
    };
}

fn appendScreen(dst: *T.Screen, src: *T.Screen, width: u32) void {
    const offset = segmentWidth(dst);
    copyScreenRaw(dst, offset, 0, src, 0, width);
    dst.cx += width;
}

fn fillAvailable(ctx: *T.ScreenWriteCtx, bg: i32, available: u32) void {
    var gc = T.grid_default_cell;
    gc.bg = bg;

    const start_x = ctx.s.cx;
    const start_y = ctx.s.cy;
    var remaining = available;
    while (remaining > 0) : (remaining -= 1) {
        screen_write.putCell(ctx, &gc);
    }
    screen_write.cursor_to(ctx, start_y, start_x);
}

fn segmentWidth(screen: *T.Screen) u32 {
    return screen.cx;
}

fn countHashes(input: []const u8) usize {
    var count: usize = 0;
    while (count < input.len and input[count] == '#') : (count += 1) {}
    return count;
}

fn leadingHashes(input: []const u8) struct {
    advance: usize,
    literal_hashes: u32,
    literal_bracket: bool,
    style: bool,
} {
    const count = countHashes(input);
    if (count == 0) return .{ .advance = 0, .literal_hashes = 0, .literal_bracket = false, .style = false };
    if (count >= input.len or input[count] != '[') {
        return .{
            .advance = count,
            .literal_hashes = @intCast((count / 2) + (count % 2)),
            .literal_bracket = false,
            .style = false,
        };
    }
    if ((count % 2) == 0) {
        return .{
            .advance = count + 1,
            .literal_hashes = @intCast(count / 2),
            .literal_bracket = true,
            .style = false,
        };
    }
    return .{
        .advance = count - 1,
        .literal_hashes = @intCast(count / 2),
        .literal_bracket = false,
        .style = true,
    };
}

fn drawMany(ctx: *T.ScreenWriteCtx, gc: *T.GridCell, ch: u8, count: u32) void {
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        drawAsciiToSegment(ctx, gc, ch);
    }
}

fn drawAsciiToSegment(ctx: *T.ScreenWriteCtx, gc: *T.GridCell, ch: u8) void {
    utf8.utf8_set(&gc.data, ch);
    screen_write.putCell(ctx, gc);
}

test "format_width ignores style directives and counts utf8 cells" {
    try std.testing.expectEqual(@as(u32, 5), format_width("#[fg=red]a🙂bc"));
    try std.testing.expectEqual(@as(u32, 2), format_width("##["));
    try std.testing.expectEqual(@as(u32, 2), format_width("###[fg=red]x"));
}

test "format_draw writes utf8 cells through the shared screen writer" {
    const screen = screen_mod.screen_init(6, 1, 0);
    defer {
        screen_mod.screen_free(screen);
        xm.allocator.destroy(screen);
    }

    var ctx = T.ScreenWriteCtx{ .s = screen };
    format_draw(&ctx, &T.grid_default_cell, 6, "#[bg=blue,fill=blue]é🙂");

    var stored: T.GridCell = undefined;
    grid.get_cell(screen.grid, 0, 0, &stored);
    try std.testing.expectEqualStrings("é", stored.payload().bytes());
    try std.testing.expectEqual(@as(i32, 4), stored.bg);

    grid.get_cell(screen.grid, 0, 1, &stored);
    try std.testing.expectEqualStrings("🙂", stored.payload().bytes());
    try std.testing.expectEqual(@as(u8, 2), stored.payload().width);

    grid.get_cell(screen.grid, 0, 2, &stored);
    try std.testing.expect(stored.isPadding());

    grid.get_cell(screen.grid, 0, 5, &stored);
    try std.testing.expectEqual(@as(u8, ' '), stored.payload().data[0]);
    try std.testing.expectEqual(@as(i32, 4), stored.bg);
}

test "format_draw trims list output with markers around focus" {
    const screen = screen_mod.screen_init(6, 1, 0);
    defer {
        screen_mod.screen_free(screen);
        xm.allocator.destroy(screen);
    }

    var ctx = T.ScreenWriteCtx{ .s = screen };
    format_draw(
        &ctx,
        &T.grid_default_cell,
        6,
        "#[list=on align=left]#[list=left-marker]<#[list=right-marker]>#[list=on]abc#[list=focus]de#[list=on]fgh",
    );

    var rendered: std.ArrayList(u8) = .{};
    defer rendered.deinit(xm.allocator);
    for (0..6) |col| {
        var cell: T.GridCell = undefined;
        grid.get_cell(screen.grid, 0, @intCast(col), &cell);
        if (cell.isPadding()) continue;
        rendered.appendSlice(xm.allocator, cell.payload().bytes()) catch unreachable;
    }
    const text = rendered.toOwnedSlice(xm.allocator) catch unreachable;
    defer xm.allocator.free(text);
    try std.testing.expectEqualStrings("<cdef>", text);
}

test "format_draw_ranges translates clipped list ranges" {
    const screen = screen_mod.screen_init(6, 1, 0);
    defer {
        screen_mod.screen_free(screen);
        xm.allocator.destroy(screen);
    }

    var ctx = T.ScreenWriteCtx{ .s = screen };
    var ranges: DrawRanges = .{};
    defer ranges.deinit(xm.allocator);

    format_draw_ranges(
        &ctx,
        &T.grid_default_cell,
        6,
        "#[list=on align=left]#[list=left-marker]<#[list=right-marker]>#[list=on]abc#[range=window|7 list=focus]de#[norange list=on]fgh",
        &ranges,
    );

    try std.testing.expectEqual(@as(usize, 1), ranges.items.len);
    try std.testing.expectEqual(T.StyleRangeType.window, ranges.items[0].type);
    try std.testing.expectEqual(@as(u32, 7), ranges.items[0].argument);
    try std.testing.expectEqual(@as(u32, 2), ranges.items[0].start);
    try std.testing.expectEqual(@as(u32, 4), ranges.items[0].end);
}
