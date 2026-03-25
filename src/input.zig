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
// Ported in part from tmux/input.c.
// Original copyright:
//   Copyright (c) 2009 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

//! input.zig – reduced terminal-input parser feeding screen-write.

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const screen_write = @import("screen-write.zig");

pub fn input_parse_screen(wp: *T.WindowPane, bytes: []const u8) void {
    if (bytes.len == 0) return;
    wp.input_pending.appendSlice(@import("xmalloc.zig").allocator, bytes) catch unreachable;

    var ctx = T.ScreenWriteCtx{ .wp = wp, .s = &wp.base };
    var i: usize = 0;
    while (i < wp.input_pending.items.len) {
        const ch = wp.input_pending.items[i];
        if (ch != 0x1b) {
            handle_plain(&ctx, ch);
            i += 1;
            continue;
        }

        if (i + 1 >= wp.input_pending.items.len) break;
        const next = wp.input_pending.items[i + 1];
        if (next == '[') {
            const consumed = parse_csi(&ctx, wp.input_pending.items[i..]) orelse break;
            i += consumed;
            continue;
        }
        if (next == ']') {
            const consumed = parse_osc(wp, wp.input_pending.items[i..]) orelse break;
            i += consumed;
            continue;
        }

        // Reduced default: swallow other ESC sequences for now.
        i += 2;
    }

    if (i > 0) {
        const remaining = wp.input_pending.items.len - i;
        std.mem.copyForwards(u8, wp.input_pending.items[0..remaining], wp.input_pending.items[i..]);
        wp.input_pending.shrinkRetainingCapacity(remaining);
    }
    sync_pane_screen(wp);
}

fn handle_plain(ctx: *T.ScreenWriteCtx, ch: u8) void {
    switch (ch) {
        '\r' => screen_write.carriage_return(ctx),
        '\n' => screen_write.newline(ctx),
        0x08 => screen_write.backspace(ctx),
        '\t' => screen_write.tab(ctx),
        else => {
            if (ch < ' ' and ch != 0x1b) return;
            screen_write.putc(ctx, ch);
        },
    }
}

fn parse_csi(ctx: *T.ScreenWriteCtx, bytes: []const u8) ?usize {
    var idx: usize = 2; // ESC [
    while (idx < bytes.len) : (idx += 1) {
        const ch = bytes[idx];
        if (ch >= '@' and ch <= '~') {
            apply_csi(ctx, bytes[2..idx], ch);
            return idx + 1;
        }
    }
    return null;
}

fn parse_osc(wp: *T.WindowPane, bytes: []const u8) ?usize {
    var idx: usize = 2; // ESC ]
    while (idx < bytes.len) : (idx += 1) {
        if (bytes[idx] == 0x07) {
            apply_osc(wp, bytes[2..idx]);
            return idx + 1;
        }
        if (idx + 1 < bytes.len and bytes[idx] == 0x1b and bytes[idx + 1] == '\\') {
            apply_osc(wp, bytes[2..idx]);
            return idx + 2;
        }
    }
    return null;
}

fn apply_osc(wp: *T.WindowPane, payload: []const u8) void {
    const semi = std.mem.indexOfScalar(u8, payload, ';') orelse return;
    const kind = payload[0..semi];
    const value = payload[semi + 1 ..];
    if (!(std.mem.eql(u8, kind, "0") or std.mem.eql(u8, kind, "1") or std.mem.eql(u8, kind, "2"))) return;

    if (wp.screen.title) |old| xm.allocator.free(old);
    wp.screen.title = if (value.len != 0) xm.xstrdup(value) else null;
}

fn apply_csi(ctx: *T.ScreenWriteCtx, raw_params: []const u8, final: u8) void {
    var params_buf: [8]u32 = [_]u32{0} ** 8;
    const parsed = parse_csi_params(raw_params, &params_buf);
    const params = params_buf[0..parsed.count];

    switch (final) {
        'A' => screen_write.cursor_up(ctx, first_param(params, 1)),
        'B' => screen_write.cursor_down(ctx, first_param(params, 1)),
        'C' => screen_write.cursor_right(ctx, first_param(params, 1)),
        'D' => screen_write.cursor_left(ctx, first_param(params, 1)),
        'E' => {
            screen_write.cursor_down(ctx, first_param(params, 1));
            screen_write.carriage_return(ctx);
        },
        'F' => {
            screen_write.cursor_up(ctx, first_param(params, 1));
            screen_write.carriage_return(ctx);
        },
        'G' => screen_write.cursor_to(ctx, ctx.s.cy, first_param(params, 1) -| 1),
        'H', 'f' => {
            const row = first_param(params, 1) -| 1;
            const col = second_param(params, 1) -| 1;
            screen_write.cursor_to(ctx, row, col);
        },
        'J' => {
            const mode = first_param(params, 0);
            if (mode == 0 or mode == 2) screen_write.erase_screen(ctx);
        },
        'K' => {
            const mode = first_param(params, 0);
            if (mode == 0 or mode == 2) screen_write.erase_to_eol(ctx);
        },
        'm', 'h', 'l' => {}, // reduced: ignore SGR and private modes for now
        else => {},
    }
}

const ParsedParams = struct {
    count: usize,
};

fn parse_csi_params(raw: []const u8, out: *[8]u32) ParsedParams {
    var count: usize = 0;
    var current: u32 = 0;
    var have_current = false;
    for (raw) |ch| {
        if (ch >= '0' and ch <= '9') {
            current = current * 10 + (ch - '0');
            have_current = true;
            continue;
        }
        if (ch == ';') {
            if (count < out.len) {
                out[count] = if (have_current) current else 0;
                count += 1;
            }
            current = 0;
            have_current = false;
            continue;
        }
        // Ignore private-mode markers like '?' and stray text.
    }
    if (have_current or count == 0) {
        if (count < out.len) {
            out[count] = if (have_current) current else 0;
            count += 1;
        }
    }
    return .{ .count = count };
}

fn first_param(params: []const u32, fallback: u32) u32 {
    if (params.len == 0 or params[0] == 0) return fallback;
    return params[0];
}

fn second_param(params: []const u32, fallback: u32) u32 {
    if (params.len < 2 or params[1] == 0) return fallback;
    return params[1];
}

fn sync_pane_screen(wp: *T.WindowPane) void {
    wp.screen.cx = wp.base.cx;
    wp.screen.cy = wp.base.cy;
}

test "input parses printable text and simple cursor movement" {
    const opts = @import("options.zig");
    const win = @import("window.zig");
    const grid = @import("grid.zig");

    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    win.window_init_globals(@import("xmalloc.zig").allocator);

    const w = win.window_create(8, 3, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    defer {
        while (w.panes.items.len > 0) {
            const pane = w.panes.items[w.panes.items.len - 1];
            win.window_remove_pane(w, pane);
        }
        w.panes.deinit(@import("xmalloc.zig").allocator);
        w.last_panes.deinit(@import("xmalloc.zig").allocator);
        opts.options_free(w.options);
        @import("xmalloc.zig").allocator.free(w.name);
        _ = win.windows.remove(w.id);
        @import("xmalloc.zig").allocator.destroy(w);
    }

    const wp = win.window_add_pane(w, null, 8, 3);
    input_parse_screen(wp, "ab\x1b[2;3HZ");
    try std.testing.expectEqual(@as(u8, 'a'), grid.ascii_at(wp.base.grid, 0, 0));
    try std.testing.expectEqual(@as(u8, 'b'), grid.ascii_at(wp.base.grid, 0, 1));
    try std.testing.expectEqual(@as(u8, 'Z'), grid.ascii_at(wp.base.grid, 1, 2));
}

test "input keeps incomplete CSI pending across calls" {
    const opts = @import("options.zig");
    const win = @import("window.zig");
    const grid = @import("grid.zig");

    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    win.window_init_globals(@import("xmalloc.zig").allocator);

    const w = win.window_create(4, 2, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    defer {
        while (w.panes.items.len > 0) {
            const pane = w.panes.items[w.panes.items.len - 1];
            win.window_remove_pane(w, pane);
        }
        w.panes.deinit(@import("xmalloc.zig").allocator);
        w.last_panes.deinit(@import("xmalloc.zig").allocator);
        opts.options_free(w.options);
        @import("xmalloc.zig").allocator.free(w.name);
        _ = win.windows.remove(w.id);
        @import("xmalloc.zig").allocator.destroy(w);
    }

    const wp = win.window_add_pane(w, null, 4, 2);
    input_parse_screen(wp, "\x1b[2");
    try std.testing.expectEqual(@as(usize, 3), wp.input_pending.items.len);
    input_parse_screen(wp, ";2HZ");
    try std.testing.expectEqual(@as(usize, 0), wp.input_pending.items.len);
    try std.testing.expectEqual(@as(u8, 'Z'), grid.ascii_at(wp.base.grid, 1, 1));
}

test "input parses OSC pane title updates" {
    const opts = @import("options.zig");
    const win = @import("window.zig");

    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    win.window_init_globals(@import("xmalloc.zig").allocator);

    const w = win.window_create(4, 2, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    defer {
        while (w.panes.items.len > 0) {
            const pane = w.panes.items[w.panes.items.len - 1];
            win.window_remove_pane(w, pane);
        }
        w.panes.deinit(@import("xmalloc.zig").allocator);
        w.last_panes.deinit(@import("xmalloc.zig").allocator);
        opts.options_free(w.options);
        @import("xmalloc.zig").allocator.free(w.name);
        _ = win.windows.remove(w.id);
        @import("xmalloc.zig").allocator.destroy(w);
    }

    const wp = win.window_add_pane(w, null, 4, 2);
    input_parse_screen(wp, "\x1b]2;logs\x07");
    try std.testing.expectEqualStrings("logs", wp.screen.title.?);
}
