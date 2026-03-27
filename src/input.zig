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
// Ported in part from tmux/input.c.
// Original copyright:
//   Copyright (c) 2009 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

//! input.zig – reduced terminal-input parser feeding screen-write.

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const opts = @import("options.zig");
const screen_mod = @import("screen.zig");
const screen_write = @import("screen-write.zig");
const alerts = @import("alerts.zig");

pub fn input_parse_screen(wp: *T.WindowPane, bytes: []const u8) void {
    if (bytes.len == 0) return;
    wp.input_pending.appendSlice(@import("xmalloc.zig").allocator, bytes) catch unreachable;

    var ctx = T.ScreenWriteCtx{ .wp = wp, .s = screen_mod.screen_current(wp) };
    var i: usize = 0;
    while (i < wp.input_pending.items.len) {
        if (wp.input_pending.items[i] != 0x1b) {
            const start = i;
            var end = i;
            while (end < wp.input_pending.items.len and wp.input_pending.items[end] != 0x1b) : (end += 1) {}

            const keep_incomplete_tail = end == wp.input_pending.items.len;
            const consumed = handle_plain_bytes(&ctx, wp.input_pending.items[start..end], keep_incomplete_tail);
            i += consumed;
            if (consumed < end - start) break;
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
        if (next == '=') {
            ctx.s.mode |= T.MODE_KKEYPAD;
            i += 2;
            continue;
        }
        if (next == '>') {
            ctx.s.mode &= ~T.MODE_KKEYPAD;
            i += 2;
            continue;
        }
        if (next == '7') {
            screen_write.save_cursor(&ctx);
            i += 2;
            continue;
        }
        if (next == '8') {
            screen_write.restore_cursor(&ctx);
            i += 2;
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
}

fn handle_plain_bytes(ctx: *T.ScreenWriteCtx, bytes: []const u8, keep_incomplete_tail: bool) usize {
    var i: usize = 0;
    var chunk_start: usize = 0;

    while (i < bytes.len) {
        const ch = bytes[i];
        switch (ch) {
            0x07, '\r', '\n', 0x08, '\t' => {
                if (i > chunk_start) {
                    _ = screen_write.putBytes(ctx, bytes[chunk_start..i], false);
                }
                handle_plain_control(ctx, ch);
                i += 1;
                chunk_start = i;
            },
            else => i += 1,
        }
    }

    if (chunk_start < bytes.len) {
        return chunk_start + screen_write.putBytes(ctx, bytes[chunk_start..], keep_incomplete_tail);
    }
    return i;
}

fn handle_plain_control(ctx: *T.ScreenWriteCtx, ch: u8) void {
    switch (ch) {
        0x07 => if (ctx.wp) |wp| alerts.alerts_queue(wp.window, T.WINDOW_BELL),
        '\r' => screen_write.carriage_return(ctx),
        '\n' => screen_write.newline(ctx),
        0x08 => screen_write.backspace(ctx),
        '\t' => screen_write.tab(ctx),
        else => unreachable,
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
    var private = false;
    var modify_other_keys = false;
    var params_raw = raw_params;
    if (params_raw.len != 0 and params_raw[0] == '?') {
        private = true;
        params_raw = params_raw[1..];
    } else if (params_raw.len != 0 and params_raw[0] == '>') {
        modify_other_keys = true;
        params_raw = params_raw[1..];
    }

    var params_buf: [8]u32 = [_]u32{0} ** 8;
    const parsed = parse_csi_params(params_raw, &params_buf);
    const params = params_buf[0..parsed.count];

    if (modify_other_keys and final == 'm') {
        apply_modify_other_keys(ctx, params);
        return;
    }
    if (private and (final == 'h' or final == 'l')) {
        apply_private_modes(ctx, params, final == 'h');
        return;
    }

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
        'J' => switch (first_param(params, 0)) {
            0 => screen_write.erase_to_screen_end(ctx),
            1 => screen_write.erase_to_screen_beginning(ctx),
            2 => screen_write.erase_screen(ctx),
            else => {},
        },
        'K' => switch (first_param(params, 0)) {
            0 => screen_write.erase_to_eol(ctx),
            1 => screen_write.erase_to_bol(ctx),
            2 => screen_write.erase_line(ctx),
            else => {},
        },
        'L' => screen_write.insert_lines(ctx, first_param(params, 1)),
        'M' => screen_write.delete_lines(ctx, first_param(params, 1)),
        '@' => screen_write.insert_characters(ctx, first_param(params, 1)),
        'P' => screen_write.delete_characters(ctx, first_param(params, 1)),
        'X' => screen_write.erase_characters(ctx, first_param(params, 1)),
        'r' => {
            const top = first_param(params, 1) -| 1;
            const bottom = second_param(params, ctx.s.grid.sy) -| 1;
            screen_write.set_scroll_region(ctx, top, bottom);
        },
        's' => screen_write.save_cursor(ctx),
        'u' => screen_write.restore_cursor(ctx),
        'm', 'h', 'l' => {}, // reduced: ignore SGR and private modes for now
        else => {},
    }
}

fn apply_modify_other_keys(ctx: *T.ScreenWriteCtx, params: []const u32) void {
    if (first_param(params, 0) != 4) return;

    const configured = opts.options_get_number(opts.global_options, "extended-keys");
    if (params.len >= 2 and params[1] != 0) {
        if (configured == 0) return;
        ctx.s.mode &= ~T.EXTENDED_KEY_MODES;
        if (params[1] == 2)
            ctx.s.mode |= T.MODE_KEYS_EXTENDED_2
        else if (params[1] == 1 or configured == 2)
            ctx.s.mode |= T.MODE_KEYS_EXTENDED;
        return;
    }

    ctx.s.mode &= ~T.EXTENDED_KEY_MODES;
    if (configured == 2) ctx.s.mode |= T.MODE_KEYS_EXTENDED;
}

fn apply_private_modes(ctx: *T.ScreenWriteCtx, params: []const u32, set: bool) void {
    const wp = ctx.wp orelse return;
    const current = screen_mod.screen_current(wp);
    for (params) |mode| {
        switch (mode) {
            1 => {
                if (set)
                    current.mode |= T.MODE_KCURSOR
                else
                    current.mode &= ~T.MODE_KCURSOR;
            },
            25 => {
                current.cursor_visible = set;
                if (set)
                    current.mode |= T.MODE_CURSOR
                else
                    current.mode &= ~T.MODE_CURSOR;
            },
            1000, 1001 => {
                if (set) {
                    current.mode &= ~T.ALL_MOUSE_MODES;
                    current.mode |= T.MODE_MOUSE_STANDARD;
                } else current.mode &= ~T.ALL_MOUSE_MODES;
            },
            1002 => {
                if (set) {
                    current.mode &= ~T.ALL_MOUSE_MODES;
                    current.mode |= T.MODE_MOUSE_BUTTON;
                } else current.mode &= ~T.ALL_MOUSE_MODES;
            },
            1003 => {
                if (set) {
                    current.mode &= ~T.ALL_MOUSE_MODES;
                    current.mode |= T.MODE_MOUSE_ALL;
                } else current.mode &= ~T.ALL_MOUSE_MODES;
            },
            1005 => {
                if (set)
                    current.mode |= T.MODE_MOUSE_UTF8
                else
                    current.mode &= ~T.MODE_MOUSE_UTF8;
            },
            1006 => {
                if (set)
                    current.mode |= T.MODE_MOUSE_SGR
                else
                    current.mode &= ~T.MODE_MOUSE_SGR;
            },
            47, 1047 => {
                if (set)
                    screen_mod.screen_enter_alternate(wp, false)
                else
                    screen_mod.screen_leave_alternate(wp, false);
            },
            1049 => {
                if (set)
                    screen_mod.screen_enter_alternate(wp, true)
                else
                    screen_mod.screen_leave_alternate(wp, true);
            },
            2004 => {
                current.bracketed_paste = set;
                if (set)
                    current.mode |= T.MODE_BRACKETPASTE
                else
                    current.mode &= ~T.MODE_BRACKETPASTE;
            },
            else => {},
        }
        ctx.s = screen_mod.screen_current(wp);
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

test "input parses printable text and simple cursor movement" {
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

test "input supports cursor save restore and private alternate screen" {
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
    input_parse_screen(wp, "abc\x1b[s\x1b[2;2HZ\x1b[uQ");
    try std.testing.expectEqual(@as(u8, 'Q'), grid.ascii_at(wp.base.grid, 0, 3));

    input_parse_screen(wp, "\x1b[?1049hALT");
    try std.testing.expect(screen_mod.screen_alternate_active(wp));
    try std.testing.expectEqual(@as(u8, 'A'), grid.ascii_at(wp.screen.grid, 0, 0));
    try std.testing.expectEqual(@as(u8, 'a'), grid.ascii_at(wp.base.grid, 0, 0));

    input_parse_screen(wp, "\x1b[?1049l");
    try std.testing.expect(!screen_mod.screen_alternate_active(wp));
    try std.testing.expectEqual(@as(u8, 'a'), grid.ascii_at(wp.base.grid, 0, 0));
}

test "input keeps incomplete CSI pending across calls" {
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

test "input keeps incomplete UTF-8 pending across calls" {
    const win = @import("window.zig");
    const grid = @import("grid.zig");

    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    win.window_init_globals(@import("xmalloc.zig").allocator);

    const w = win.window_create(6, 2, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
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

    const wp = win.window_add_pane(w, null, 6, 2);
    input_parse_screen(wp, "\xf0\x9f");
    try std.testing.expectEqual(@as(usize, 2), wp.input_pending.items.len);

    input_parse_screen(wp, "\x99\x82A");
    try std.testing.expectEqual(@as(usize, 0), wp.input_pending.items.len);

    var cell: T.GridCell = undefined;
    grid.get_cell(wp.base.grid, 0, 0, &cell);
    try std.testing.expectEqual(@as(u8, 2), cell.data.width);
    grid.get_cell(wp.base.grid, 0, 1, &cell);
    try std.testing.expect(cell.isPadding());
    try std.testing.expectEqual(@as(u8, 'A'), grid.ascii_at(wp.base.grid, 0, 2));
}

test "input parses OSC pane title updates" {
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

test "input tracks keypad cursor mouse and extended-key modes" {
    const win = @import("window.zig");

    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    opts.options_set_number(opts.global_options, "extended-keys", 1);
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
    input_parse_screen(wp, "\x1b=\x1b[?1h\x1b[?1002h\x1b[?1006h\x1b[?2004h\x1b[>4;2m");

    const mode = screen_mod.screen_current(wp).mode;
    try std.testing.expect(mode & T.MODE_KKEYPAD != 0);
    try std.testing.expect(mode & T.MODE_KCURSOR != 0);
    try std.testing.expect(mode & T.MODE_MOUSE_BUTTON != 0);
    try std.testing.expect(mode & T.MODE_MOUSE_SGR != 0);
    try std.testing.expect(mode & T.MODE_BRACKETPASTE != 0);
    try std.testing.expect(mode & T.MODE_KEYS_EXTENDED_2 != 0);

    input_parse_screen(wp, "\x1b>\x1b[?1l\x1b[?1002l\x1b[?1006l\x1b[?2004l\x1b[>4m");
    const cleared = screen_mod.screen_current(wp).mode;
    try std.testing.expect(cleared & T.MODE_KKEYPAD == 0);
    try std.testing.expect(cleared & T.MODE_KCURSOR == 0);
    try std.testing.expect(cleared & T.MODE_MOUSE_BUTTON == 0);
    try std.testing.expect(cleared & T.MODE_MOUSE_SGR == 0);
    try std.testing.expect(cleared & T.MODE_BRACKETPASTE == 0);
    try std.testing.expect(cleared & T.EXTENDED_KEY_MODES == 0);
}
