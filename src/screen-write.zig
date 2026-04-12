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
// Ported in part from tmux/screen-write.c.
// Original copyright:
//   Copyright (c) 2009 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

//! screen-write.zig – reduced screen writer over the shared grid/screen model.

const std = @import("std");
const T = @import("types.zig");
const grid = @import("grid.zig");
const opts = @import("options.zig");
const screen_mod = @import("screen.zig");
const utf8 = @import("utf8.zig");
const xm = @import("xmalloc.zig");
const c = @import("c.zig");
const image_mod = @import("image.zig");
const sixel = @import("image-sixel.zig");
const log = @import("log.zig");
const client_registry = @import("client-registry.zig");
const tty_mod = @import("tty.zig");

const swp = @import("screen-write-primitives.zig");
pub const putc = swp.putc;
pub const putn = swp.putn;
pub const putBytes = swp.putBytes;
pub const putEscapedBytes = swp.putEscapedBytes;
pub const putGlyph = swp.putGlyph;
pub const putCell = swp.putCell;
pub const carriage_return = swp.carriage_return;
pub const backspace = swp.backspace;
pub const tab = swp.tab;
pub const newline = swp.newline;
pub const cursor_left = swp.cursor_left;
pub const cursor_right = swp.cursor_right;
pub const cursor_up = swp.cursor_up;
pub const cursor_down = swp.cursor_down;
pub const cursor_to = swp.cursor_to;
pub const erase_to_eol = swp.erase_to_eol;
pub const erase_to_bol = swp.erase_to_bol;
pub const erase_line = swp.erase_line;
pub const erase_screen = swp.erase_screen;
pub const preview = swp.preview;
pub const erase_to_screen_end = swp.erase_to_screen_end;
pub const erase_to_screen_beginning = swp.erase_to_screen_beginning;
pub const insert_characters = swp.insert_characters;
pub const delete_characters = swp.delete_characters;
pub const erase_characters = swp.erase_characters;
pub const insert_lines = swp.insert_lines;
pub const delete_lines = swp.delete_lines;
pub const set_scroll_region = swp.set_scroll_region;
pub const save_cursor = swp.save_cursor;
pub const restore_cursor = swp.restore_cursor;
pub const scrollup = swp.scrollup;
pub const scrolldown = swp.scrolldown;
pub const linefeed = swp.linefeed;
pub const reverseindex = swp.reverseindex;
pub const mode_set = swp.mode_set;
pub const mode_clear = swp.mode_clear;
pub const alignmenttest = swp.alignmenttest;
pub const reset = swp.reset;
pub const box_draw = swp.box_draw;
pub const hline = swp.hline;
pub const vline = swp.vline;
pub const fullredraw = swp.fullredraw;
pub const clearhistory = swp.clearhistory;
pub const clearcharacter = swp.clearcharacter;
pub const rawstring = swp.rawstring;
pub const setselection = swp.setselection;
pub const cursormove = swp.cursormove;
pub const cursorup = swp.cursorup;
pub const cursordown = swp.cursordown;
pub const cursorright = swp.cursorright;
pub const cursorleft = swp.cursorleft;
pub const putc_styled = swp.putc_styled;
pub const nputs = swp.nputs;
pub const fast_copy = swp.fast_copy;
pub const scrollregion = swp.scrollregion;
pub const screen_write_putc = swp.screen_write_putc;
pub const screen_write_nputs = swp.screen_write_nputs;
pub const screen_write_vnputs = swp.screen_write_vnputs;
pub const screen_write_fast_copy = swp.screen_write_fast_copy;
pub const screen_write_clearendofline = swp.screen_write_clearendofline;
pub const screen_write_clearstartofline = swp.screen_write_clearstartofline;
pub const screen_write_clearline = swp.screen_write_clearline;
pub const screen_write_clearscreen = swp.screen_write_clearscreen;
pub const screen_write_clearendofscreen = swp.screen_write_clearendofscreen;
pub const screen_write_clearstartofscreen = swp.screen_write_clearstartofscreen;
pub const screen_write_cursorup = swp.screen_write_cursorup;
pub const screen_write_cursordown = swp.screen_write_cursordown;
pub const screen_write_cursorleft = swp.screen_write_cursorleft;
pub const screen_write_cursorright = swp.screen_write_cursorright;
pub const screen_write_cursormove = swp.screen_write_cursormove;
pub const screen_write_linefeed = swp.screen_write_linefeed;
pub const screen_write_reverseindex = swp.screen_write_reverseindex;
pub const screen_write_carriagereturn = swp.screen_write_carriagereturn;
pub const screen_write_backspace = swp.screen_write_backspace;
pub const screen_write_scrollup = swp.screen_write_scrollup;
pub const screen_write_scrolldown = swp.screen_write_scrolldown;
pub const screen_write_scrollregion = swp.screen_write_scrollregion;
pub const screen_write_insertcharacter = swp.screen_write_insertcharacter;
pub const screen_write_deletecharacter = swp.screen_write_deletecharacter;
pub const screen_write_clearcharacter = swp.screen_write_clearcharacter;
pub const screen_write_insertline = swp.screen_write_insertline;
pub const screen_write_deleteline = swp.screen_write_deleteline;
pub const screen_write_mode_set = swp.screen_write_mode_set;
pub const screen_write_mode_clear = swp.screen_write_mode_clear;
pub const screen_write_alignmenttest = swp.screen_write_alignmenttest;
pub const screen_write_reset = swp.screen_write_reset;
pub const screen_write_box = swp.screen_write_box;
pub const screen_write_hline = swp.screen_write_hline;
pub const screen_write_vline = swp.screen_write_vline;
pub const screen_write_preview = swp.screen_write_preview;
pub const screen_write_fullredraw = swp.screen_write_fullredraw;
pub const screen_write_clearhistory = swp.screen_write_clearhistory;
pub const screen_write_rawstring = swp.screen_write_rawstring;
pub const screen_write_setselection = swp.screen_write_setselection;

// ── Citem doubly-linked list helpers ─────────────────────────────────────

fn cline_is_empty(cl: *const T.ScreenWriteCline) bool {
    return cl.first == null;
}

fn cline_insert_tail(cl: *T.ScreenWriteCline, ci: *T.ScreenWriteCitem) void {
    ci.next = null;
    ci.prev = cl.last;
    if (cl.last) |last| {
        last.next = ci;
    } else {
        cl.first = ci;
    }
    cl.last = ci;
}

fn cline_insert_before(cl: *T.ScreenWriteCline, before: *T.ScreenWriteCitem, ci: *T.ScreenWriteCitem) void {
    ci.next = before;
    ci.prev = before.prev;
    if (before.prev) |prev| {
        prev.next = ci;
    } else {
        cl.first = ci;
    }
    before.prev = ci;
}

fn cline_insert_after(cl: *T.ScreenWriteCline, after: *T.ScreenWriteCitem, ci: *T.ScreenWriteCitem) void {
    ci.prev = after;
    ci.next = after.next;
    if (after.next) |next_node| {
        next_node.prev = ci;
    } else {
        cl.last = ci;
    }
    after.next = ci;
}

fn cline_remove(cl: *T.ScreenWriteCline, ci: *T.ScreenWriteCitem) void {
    if (ci.prev) |prev| {
        prev.next = ci.next;
    } else {
        cl.first = ci.next;
    }
    if (ci.next) |next_node| {
        next_node.prev = ci.prev;
    } else {
        cl.last = ci.prev;
    }
    ci.prev = null;
    ci.next = null;
}

fn cline_concat(dst: *T.ScreenWriteCline, src: *T.ScreenWriteCline) void {
    if (src.first == null) return;
    if (dst.last) |last| {
        last.next = src.first;
        src.first.?.prev = last;
    } else {
        dst.first = src.first;
    }
    dst.last = src.last;
    src.first = null;
    src.last = null;
}

// ── Citem freelist (pool allocator for efficiency) ───────────────────────

var citem_freelist_head: ?*T.ScreenWriteCitem = null;

fn get_citem() *T.ScreenWriteCitem {
    if (citem_freelist_head) |ci| {
        citem_freelist_head = ci.next;
        ci.* = .{};
        return ci;
    }
    const ci = xm.allocator.create(T.ScreenWriteCitem) catch unreachable;
    ci.* = .{};
    return ci;
}

fn free_citem(ci: *T.ScreenWriteCitem) void {
    ci.* = .{};
    ci.next = citem_freelist_head;
    citem_freelist_head = ci;
}

// ── Collect/flush real implementations ported from tmux screen-write.c ──

pub fn screen_write_make_list(s: *T.Screen) void {
    const sy = s.grid.sy;
    if (sy == 0) return;
    const wl = xm.allocator.alloc(T.ScreenWriteCline, sy) catch unreachable;
    for (wl) |*cl| cl.* = .{};
    s.write_list = wl;
}

pub fn screen_write_free_list(s: *T.Screen) void {
    const wl = s.write_list orelse return;
    for (wl) |*cl| {
        if (cl.data) |d| xm.allocator.free(d);
        var ci = cl.first;
        while (ci) |item| {
            ci = item.next;
            free_citem(item);
        }
        cl.* = .{};
    }
    xm.allocator.free(wl);
    s.write_list = null;
}

fn screen_write_init_internal(ctx: *T.ScreenWriteCtx, s: *T.Screen) void {
    ctx.* = .{ .s = s };
    if (s.write_list == null)
        screen_write_make_list(s);
    ctx.item = get_citem();
    ctx.scrolled = 0;
    ctx.bg = 8;
}

pub fn screen_write_start_pane(ctx: *T.ScreenWriteCtx, wp: *T.WindowPane, s_opt: ?*T.Screen) void {
    const s = s_opt orelse wp.screen;
    screen_write_init_internal(ctx, s);
    ctx.wp = wp;
}

pub fn screen_write_start_callback(
    ctx: *T.ScreenWriteCtx,
    s: *T.Screen,
    cb: ?T.ScreenWriteInitCtxCb,
    arg: ?*anyopaque,
) void {
    screen_write_init_internal(ctx, s);
    ctx.init_ctx_cb = cb;
    ctx.arg = arg;
}

pub fn screen_write_start(ctx: *T.ScreenWriteCtx, s: *T.Screen) void {
    screen_write_init_internal(ctx, s);
}

pub fn screen_write_init(ctx: *T.ScreenWriteCtx, s: *T.Screen) void {
    screen_write_init_internal(ctx, s);
}

pub fn screen_write_stop(ctx: *T.ScreenWriteCtx) void {
    screen_write_collect_end(ctx);
    screen_write_collect_flush(ctx, 0, "screen_write_stop");
    if (ctx.item) |item| free_citem(item);
    ctx.item = null;
}

pub fn screen_write_initctx(ctx: *T.ScreenWriteCtx, ttyctx: *T.TtyCtx, sync: i32) void {
    const s = ctx.s;
    ttyctx.* = .{};

    ttyctx.s = s;
    ttyctx.sx = s.grid.sx;
    ttyctx.sy = s.grid.sy;
    ttyctx.ocx = s.cx;
    ttyctx.ocy = s.cy;
    ttyctx.orlower = s.rlower;
    ttyctx.orupper = s.rupper;
    ttyctx.defaults = T.grid_default_cell;

    if (ctx.init_ctx_cb) |cb| {
        cb(ctx, ttyctx);
    }

    if (ctx.flags & T.SCREEN_WRITE_SYNC == 0) {
        ttyctx.num = @intCast(@as(i32, sync));
        ctx.flags |= T.SCREEN_WRITE_SYNC;
    }
}

pub fn screen_write_set_cursor(ctx: *T.ScreenWriteCtx, cx: i32, cy: i32) void {
    const s = ctx.s;
    const gd = s.grid;

    if (cx != -1) {
        if (gd.sx > 0) {
            const ucx: u32 = @intCast(cx);
            if (ucx > gd.sx)
                s.cx = gd.sx - 1
            else
                s.cx = ucx;
        }
    }
    if (cy != -1) {
        if (gd.sy > 0)
            s.cy = @min(@as(u32, @intCast(cy)), gd.sy - 1);
    }
}

pub fn screen_write_collect_trim(
    ctx: *T.ScreenWriteCtx,
    y: u32,
    x: u32,
    used: u32,
    wrapped: ?*bool,
) ?*T.ScreenWriteCitem {
    const wl = ctx.s.write_list orelse return null;
    if (y >= wl.len) return null;
    const cl = &wl[y];
    if (used == 0) return null;

    const sx = x;
    const ex = x + used - 1;
    var before: ?*T.ScreenWriteCitem = null;

    var ci = cl.first;
    while (ci) |item| {
        const next = item.next;
        const csx = item.x;
        const cex = item.x + item.used -| 1;

        if (cex < sx) {
            ci = next;
            continue;
        }

        if (csx > ex) {
            before = item;
            break;
        }

        if (csx >= sx and cex <= ex) {
            cline_remove(cl, item);
            if (csx == 0 and item.wrapped and wrapped != null)
                wrapped.?.* = true;
            free_citem(item);
            ci = next;
            continue;
        }

        if (csx < sx and cex >= sx and cex <= ex) {
            item.used = sx - csx;
            ci = next;
            continue;
        }

        if (cex > ex and csx >= sx and csx <= ex) {
            item.x = ex + 1;
            item.used = cex - ex;
            before = item;
            break;
        }

        const ci2 = get_citem();
        ci2.ctype = item.ctype;
        ci2.bg = item.bg;
        ci2.gc = item.gc;
        cline_insert_after(cl, item, ci2);

        item.used = sx - csx;
        ci2.x = ex + 1;
        ci2.used = cex - ex;

        before = ci2;
        break;
    }
    return before;
}

pub fn screen_write_collect_clear(ctx: *T.ScreenWriteCtx, y: u32, n: u32) void {
    const wl = ctx.s.write_list orelse return;
    var i = y;
    while (i < y + n and i < wl.len) : (i += 1) {
        const cl = &wl[i];
        var ci = cl.first;
        while (ci) |item| {
            ci = item.next;
            free_citem(item);
        }
        cl.first = null;
        cl.last = null;
    }
}

pub fn screen_write_collect_scroll(ctx: *T.ScreenWriteCtx, bg: u32) void {
    const s = ctx.s;
    const wl = s.write_list orelse return;
    if (s.rupper >= wl.len) return;
    if (s.rlower >= wl.len) return;

    screen_write_collect_clear(ctx, s.rupper, 1);
    const saved = wl[s.rupper].data;

    var y = s.rupper;
    while (y < s.rlower) : (y += 1) {
        cline_concat(&wl[y], &wl[y + 1]);
        wl[y].data = wl[y + 1].data;
    }
    wl[s.rlower].data = saved;

    const ci = get_citem();
    ci.x = 0;
    ci.used = s.grid.sx;
    ci.ctype = .CLEAR;
    ci.bg = bg;
    cline_insert_tail(&wl[s.rlower], ci);
}

pub fn screen_write_collect_flush(ctx: *T.ScreenWriteCtx, scroll_only: i32, _: [*:0]const u8) void {
    const s = ctx.s;
    const wl = s.write_list orelse {
        ctx.scrolled = 0;
        ctx.bg = 8;
        return;
    };

    if (s.mode & T.MODE_SYNC != 0) {
        var y: u32 = 0;
        while (y < @min(s.grid.sy, @as(u32, @intCast(wl.len)))) : (y += 1) {
            const cl = &wl[y];
            var ci = cl.first;
            while (ci) |item| {
                ci = item.next;
                free_citem(item);
            }
            cl.first = null;
            cl.last = null;
        }
        return;
    }

    ctx.scrolled = 0;
    ctx.bg = 8;

    if (scroll_only != 0) return;

    const save_cx = s.cx;
    const save_cy = s.cy;

    var y: u32 = 0;
    while (y < @min(s.grid.sy, @as(u32, @intCast(wl.len)))) : (y += 1) {
        const cl = &wl[y];
        var ci = cl.first;
        while (ci) |item| {
            ci = item.next;
            cline_remove(cl, item);
            free_citem(item);
        }
    }

    s.cx = save_cx;
    s.cy = save_cy;
}

pub fn screen_write_collect_insert(ctx: *T.ScreenWriteCtx, ci: *T.ScreenWriteCitem) void {
    const s = ctx.s;
    const wl = s.write_list orelse return;
    if (s.cy >= wl.len) return;
    const cl = &wl[s.cy];

    var wrapped_flag: bool = false;
    const before = screen_write_collect_trim(ctx, s.cy, ci.x, ci.used, &wrapped_flag);
    if (wrapped_flag) ci.wrapped = true;
    if (before) |b| {
        cline_insert_before(cl, b, ci);
    } else {
        cline_insert_tail(cl, ci);
    }
    ctx.item = get_citem();
}

pub fn screen_write_collect_end(ctx: *T.ScreenWriteCtx) void {
    const s = ctx.s;
    const ci = ctx.item orelse return;
    if (ci.used == 0) return;

    ci.x = s.cx;
    screen_write_collect_insert(ctx, ci);

    if (s.cx != 0) {
        var xx = s.cx;
        while (xx > 0) : (xx -= 1) {
            var gc: T.GridCell = undefined;
            grid.get_cell(s.grid, s.cy, xx, &gc);
            if (gc.flags & T.GRID_FLAG_PADDING == 0) break;
            grid.set_cell(s.grid, s.cy, xx, &T.grid_default_cell);
        }
        if (xx != s.cx) {
            if (xx == 0) {
                var gc: T.GridCell = undefined;
                grid.get_cell(s.grid, s.cy, 0, &gc);
                if (gc.data.width > 1 or (gc.flags & T.GRID_FLAG_PADDING != 0))
                    grid.set_cell(s.grid, s.cy, 0, &T.grid_default_cell);
            } else {
                var gc: T.GridCell = undefined;
                grid.get_cell(s.grid, s.cy, xx, &gc);
                if (gc.data.width > 1 or (gc.flags & T.GRID_FLAG_PADDING != 0))
                    grid.set_cell(s.grid, s.cy, xx, &T.grid_default_cell);
            }
        }
    }

    const wl = s.write_list orelse return;
    if (s.cy < wl.len) {
        const cl = &wl[s.cy];
        if (cl.data) |data| {
            const start = ci.x;
            const end = @min(start + ci.used, @as(u32, @intCast(data.len)));
            if (end > start) {
                grid.set_cells(s.grid, s.cy, s.cx, &ci.gc, data[start..end]);
            }
        }
    }

    screen_write_set_cursor(ctx, @intCast(s.cx + ci.used), -1);

    var xx = s.cx;
    while (xx < s.grid.sx) : (xx += 1) {
        var gc: T.GridCell = undefined;
        grid.get_cell(s.grid, s.cy, xx, &gc);
        if (gc.flags & T.GRID_FLAG_PADDING == 0) break;
        grid.set_cell(s.grid, s.cy, xx, &T.grid_default_cell);
    }
}

pub fn screen_write_collect_add(ctx: *T.ScreenWriteCtx, gc: *const T.GridCell) void {
    const s = ctx.s;
    const sx = s.grid.sx;
    if (sx == 0) return;

    var collect = true;
    if (gc.data.width != 1 or gc.data.size != 1 or gc.data.data[0] >= 0x7f)
        collect = false
    else if (gc.flags & T.GRID_FLAG_TAB != 0)
        collect = false
    else if (gc.attr & T.GRID_ATTR_CHARSET != 0)
        collect = false
    else if (s.mode & T.MODE_WRAP == 0)
        collect = false
    else if (s.mode & T.MODE_INSERT != 0)
        collect = false
    else if (s.sel != null)
        collect = false;

    if (!collect) {
        screen_write_collect_end(ctx);
        screen_write_collect_flush(ctx, 0, "screen_write_collect_add");
        screen_write_cell(ctx, gc);
        return;
    }

    const ci_used = if (ctx.item) |ci| ci.used else 0;
    if (s.cx > sx - 1 or ci_used > sx - 1 - s.cx)
        screen_write_collect_end(ctx);

    const ci = ctx.item orelse return;

    if (s.cx > sx - 1) {
        ci.wrapped = true;
        linefeed(ctx, true);
        screen_write_set_cursor(ctx, 0, -1);
    }

    if (ci.used == 0)
        ci.gc = gc.*;

    const wl = s.write_list orelse return;
    if (s.cy >= wl.len) return;
    const cl = &wl[s.cy];
    if (cl.data == null)
        cl.data = xm.allocator.alloc(u8, sx) catch unreachable;
    if (s.cx + ci.used < sx)
        cl.data.?[s.cx + ci.used] = gc.data.data[0];
    ci.used += 1;
}

pub fn screen_write_cell(ctx: *T.ScreenWriteCtx, gc: *const T.GridCell) void {
    const s = ctx.s;
    const gd = s.grid;
    if (gd.sx == 0 or gd.sy == 0) return;
    const ud = &gc.data;
    const sx = gd.sx;
    const sy = gd.sy;
    const width: u32 = ud.width;

    if (gc.flags & T.GRID_FLAG_PADDING != 0) return;

    if (swp.combineCell(ctx, gc)) return;

    screen_write_collect_flush(ctx, 1, "screen_write_cell");

    if ((s.mode & T.MODE_WRAP == 0) and
        width > 1 and
        (width > sx or (s.cx != sx and s.cx > sx - width)))
        return;

    if ((s.mode & T.MODE_INSERT) != 0) {
        var dest = sx;
        while (dest > s.cx + width) {
            dest -= 1;
            var from: T.GridCell = undefined;
            grid.get_cell(gd, s.cy, dest - width, &from);
            grid.set_cell(gd, s.cy, dest, &from);
        }
        var col: u32 = 0;
        while (col < width) : (col += 1)
            grid.set_cell(gd, s.cy, s.cx + col, &T.grid_default_cell);
    }

    if ((s.mode & T.MODE_WRAP) != 0 and s.cx > sx - width) {
        linefeed(ctx, true);
        screen_write_set_cursor(ctx, 0, -1);
        screen_write_collect_flush(ctx, 0, "screen_write_cell");
    }

    if (s.cx > sx - width or s.cy > sy - 1) return;

    var now_gc: T.GridCell = undefined;
    grid.get_cell(gd, s.cy, s.cx, &now_gc);
    _ = swp.overwriteCells(ctx, &now_gc, width);

    var xx = s.cx + 1;
    while (xx < s.cx + width) : (xx += 1) {
        grid.set_padding(gd, s.cy, xx);
    }

    const selected = screen_mod.screen_check_selection(s, s.cx, s.cy);
    if (selected and (gc.flags & T.GRID_FLAG_SELECTED == 0)) {
        var tmp_gc = gc.*;
        tmp_gc.flags |= T.GRID_FLAG_SELECTED;
        grid.set_cell(gd, s.cy, s.cx, &tmp_gc);
    } else if (!selected and (gc.flags & T.GRID_FLAG_SELECTED != 0)) {
        var tmp_gc = gc.*;
        tmp_gc.flags &= ~T.GRID_FLAG_SELECTED;
        grid.set_cell(gd, s.cy, s.cx, &tmp_gc);
    } else {
        grid.set_cell(gd, s.cy, s.cx, gc);
    }

    const not_wrap: u32 = if (s.mode & T.MODE_WRAP == 0) @as(u32, 1) else 0;
    if (s.cx <= sx - not_wrap - width)
        screen_write_set_cursor(ctx, @intCast(s.cx + width), -1)
    else
        screen_write_set_cursor(ctx, @intCast(sx - not_wrap), -1);
}

pub fn screen_write_combine(ctx: *T.ScreenWriteCtx, gc: *const T.GridCell) i32 {
    return if (swp.combineCell(ctx, gc)) 1 else 0;
}

pub fn screen_write_overwrite(ctx: *T.ScreenWriteCtx, gc: *T.GridCell, width: u32) i32 {
    return if (swp.overwriteCells(ctx, gc, width)) 1 else 0;
}

pub fn screen_write_get_citem() *T.ScreenWriteCitem {
    return get_citem();
}

pub fn screen_write_free_citem(ci: *T.ScreenWriteCitem) void {
    free_citem(ci);
}

/// Calculate the display width of a sentinel-terminated string
/// (screen_write_strlen). Handles UTF-8 multi-byte characters.
pub fn screen_write_strlen(fmt: [*:0]const u8) usize {
    return utf8.utf8_cstrwidth(std.mem.span(fmt));
}

/// Write a string with word-wrapping into a rectangular region
/// (screen_write_text). Returns 1 on success (text fits), 0 on failure
/// (text was truncated or the region ran out of lines).
pub fn screen_write_text(
    ctx: *T.ScreenWriteCtx,
    cx: u32,
    width: u32,
    lines: u32,
    more: i32,
    gcp: *const T.GridCell,
    fmt: [*:0]const u8,
) i32 {
    return text(ctx, cx, width, lines, more != 0, gcp, std.mem.span(fmt));
}

/// Write a string with word-wrapping into a rectangular region
/// (Zig-native equivalent of screen_write_text). Returns 1 on success,
/// 0 if the text was truncated or the region ran out of lines.
pub fn text(
    ctx: *T.ScreenWriteCtx,
    cx: u32,
    width: u32,
    lines_avail: u32,
    more_to_come: bool,
    gcp: *const T.GridCell,
    str: []const u8,
) i32 {
    const s = ctx.s;
    const cy = s.cy;
    var gc = gcp.*;

    const uds = utf8.utf8_fromcstr(str);
    defer xm.allocator.free(uds);

    var left: u32 = (cx + width) -| s.cx;
    var idx: usize = 0;

    while (true) {
        // Find the end of what can fit on the line.
        var at: u32 = 0;
        var end: usize = idx;
        while (uds[end].size != 0) {
            if (uds[end].size == 1 and uds[end].data[0] == '\n')
                break;
            if (at + uds[end].width > left)
                break;
            at += uds[end].width;
            end += 1;
        }

        // If we're on a space, that's the end. If not, walk back to
        // try and find one.
        var next: usize = undefined;
        if (uds[end].size == 0) {
            next = end;
        } else if (uds[end].size == 1 and uds[end].data[0] == '\n') {
            next = end + 1;
        } else if (uds[end].size == 1 and uds[end].data[0] == ' ') {
            next = end + 1;
        } else {
            var i: usize = end;
            while (i > idx) : (i -= 1) {
                if (uds[i].size == 1 and uds[i].data[0] == ' ')
                    break;
            }
            if (i != idx) {
                next = i + 1;
                end = i;
            } else {
                next = end;
            }
        }

        // Print the line.
        var i: usize = idx;
        while (i < end) : (i += 1) {
            utf8.utf8_copy(&gc.data, &uds[i]);
            putCell(ctx, &gc);
        }

        // If at the bottom, stop.
        idx = next;
        if (s.cy == cy + lines_avail - 1 or uds[idx].size == 0)
            break;

        cursormove(ctx, cx, s.cy + 1, false);
        left = width;
    }

    // Fail if on the last line and there is more to come or at the end,
    // or if the text was not entirely consumed.
    if ((s.cy == cy + lines_avail - 1 and (!more_to_come or s.cx == cx + width)) or
        uds[idx].size != 0)
    {
        return 0;
    }

    // If no more to come, move to the next line. Otherwise, leave on
    // the same line (except if at the end).
    if (!more_to_come or s.cx == cx + width)
        cursormove(ctx, cx, s.cy + 1, false);
    return 1;
}

/// Write simple string with grid cell styling, no length limit
/// (screen_write_puts). C-compatible wrapper.
pub fn screen_write_puts(ctx: *T.ScreenWriteCtx, gcp: *const T.GridCell, fmt: [*:0]const u8) void {
    nputs(ctx, -1, gcp, std.mem.span(fmt));
}

/// Write a Zig slice string with grid cell styling, no length limit
/// (Zig-native equivalent of screen_write_puts).
pub fn puts(ctx: *T.ScreenWriteCtx, gcp: *const T.GridCell, str: []const u8) void {
    nputs(ctx, -1, gcp, str);
}

pub fn screen_write_alternateon(ctx: *T.ScreenWriteCtx, gc: *T.GridCell, cursor: i32) void {
    screen_mod.screen_alternate_on(ctx.s, gc, cursor != 0);
}

pub fn screen_write_alternateoff(ctx: *T.ScreenWriteCtx, gc: *T.GridCell, cursor: i32) void {
    screen_mod.screen_alternate_off(ctx.s, gc, cursor != 0);
}

pub fn screen_write_menu(
    ctx: *T.ScreenWriteCtx,
    menu: ?*anyopaque,
    choice: i32,
    lines: i32,
    menu_gc: ?*const T.GridCell,
    border_gc: ?*const T.GridCell,
    choice_gc: ?*const T.GridCell,
) void {
    _ = .{ ctx, menu, choice, lines, menu_gc, border_gc, choice_gc };
}

pub fn screen_write_box_border_set(lines: i32, cell_type: i32, gc: *T.GridCell) void {
    _ = lines;
    _ = cell_type;
    _ = gc;
}

/// Write a sixel image to the screen at the current cursor position.
/// Mirrors tmux's screen_write_sixelimage.
pub fn screen_write_sixelimage(ctx: *T.ScreenWriteCtx, si_arg: *T.SixelImage, bg: u32) void {
    const s = ctx.s;
    const gd = s.grid;
    const cy = s.cy;

    if (gd.sy <= 1) {
        sixel.sixel_free(si_arg);
        return;
    }

    var si = si_arg;

    var x: u32 = 0;
    var y: u32 = 0;
    sixel.sixel_size_in_cells(si, &x, &y);
    if (x > gd.sx - s.cx or y > gd.sy - 1) {
        const sx = if (x > gd.sx - s.cx) gd.sx - s.cx else x;
        const sy = if (y > gd.sy - 1) gd.sy - 1 else y;
        const new = sixel.sixel_scale(si, 0, 0, 0, y - sy, sx, sy, true) orelse {
            sixel.sixel_free(si);
            return;
        };
        sixel.sixel_free(si);
        si = new;
        sixel.sixel_size_in_cells(si, &x, &y);
    }

    const sy = gd.sy - cy;
    if (sy <= y) {
        const lines = y - sy + 1;
        if (image_mod.image_scroll_up(s, lines)) {
            if (ctx.wp) |wp| wp.flags |= T.PANE_REDRAW;
        }
        var i: u32 = 0;
        while (i < lines) : (i += 1) {
            grid.grid_view_scroll_region_up(gd, 0, gd.sy - 1, bg);
            screen_write_collect_scroll(ctx, bg);
        }
        ctx.scrolled += lines;
        if (lines > cy)
            screen_write_set_cursor(ctx, -1, 0)
        else
            screen_write_set_cursor(ctx, -1, @intCast(cy - lines));
    }
    screen_write_collect_flush(ctx, 0, "screen_write_sixelimage");

    _ = image_mod.image_store(s, si);
    screen_write_set_cursor(ctx, 0, @intCast(cy + y));
}

pub fn screen_write_set_client_cb(_: *T.TtyCtx, _: ?*T.Client) i32 {
    return 0;
}

pub fn screen_write_sync_callback(_: i32, _: i32, wp: ?*T.WindowPane) void {
    if (wp) |w| w.base.mode &= ~T.MODE_SYNC;
}

pub fn screen_write_start_sync(wp: ?*T.WindowPane) void {
    if (wp) |w| w.base.mode |= T.MODE_SYNC;
}

pub fn screen_write_stop_sync(wp: ?*T.WindowPane) void {
    if (wp) |w| w.base.mode &= ~T.MODE_SYNC;
}

test "screen-write handles cursor movement and erase" {
    const screen = @import("screen.zig");
    const s = screen.screen_init(4, 2, 100);
    defer {
        screen.screen_free(s);
        @import("xmalloc.zig").allocator.destroy(s);
    }

    var ctx = T.ScreenWriteCtx{ .s = s };
    putn(&ctx, "ab");
    carriage_return(&ctx);
    putc(&ctx, 'Z');
    try std.testing.expectEqual(@as(u8, 'Z'), grid.ascii_at(s.grid, 0, 0));
    try std.testing.expectEqual(@as(u8, 'b'), grid.ascii_at(s.grid, 0, 1));

    cursor_to(&ctx, 1, 1);
    putc(&ctx, 'x');
    erase_to_eol(&ctx);
    try std.testing.expectEqual(@as(u8, 'x'), grid.ascii_at(s.grid, 1, 1));
    try std.testing.expectEqual(@as(u8, ' '), grid.ascii_at(s.grid, 1, 2));
}

test "screen-write supports insert delete and save restore cursor" {
    const screen = @import("screen.zig");
    const s = screen.screen_init(5, 3, 100);
    defer {
        screen.screen_free(s);
        @import("xmalloc.zig").allocator.destroy(s);
    }

    var ctx = T.ScreenWriteCtx{ .s = s };
    putn(&ctx, "abc");
    cursor_to(&ctx, 0, 1);
    insert_characters(&ctx, 1);
    try std.testing.expectEqual(@as(u8, 'a'), grid.ascii_at(s.grid, 0, 0));
    try std.testing.expectEqual(@as(u8, ' '), grid.ascii_at(s.grid, 0, 1));
    try std.testing.expectEqual(@as(u8, 'b'), grid.ascii_at(s.grid, 0, 2));

    delete_characters(&ctx, 1);
    try std.testing.expectEqual(@as(u8, 'b'), grid.ascii_at(s.grid, 0, 1));

    cursor_to(&ctx, 1, 2);
    save_cursor(&ctx);
    cursor_to(&ctx, 2, 4);
    restore_cursor(&ctx);
    try std.testing.expectEqual(@as(u32, 1), s.cy);
    try std.testing.expectEqual(@as(u32, 2), s.cx);
}

test "screen-write stores wide glyphs and combines modifier cells" {
    const screen = @import("screen.zig");
    const s = screen.screen_init(6, 2, 100);
    defer {
        screen.screen_free(s);
        @import("xmalloc.zig").allocator.destroy(s);
    }

    var ctx = T.ScreenWriteCtx{ .s = s };
    putn(&ctx, "🙂");

    var stored: T.GridCell = undefined;
    grid.get_cell(s.grid, 0, 0, &stored);
    try std.testing.expectEqual(@as(u8, 2), stored.data.width);
    grid.get_cell(s.grid, 0, 1, &stored);
    try std.testing.expect(stored.isPadding());
    try std.testing.expectEqual(@as(u32, 2), s.cx);

    cursor_to(&ctx, 1, 0);
    putn(&ctx, "👋");
    putn(&ctx, "🏽");
    grid.get_cell(s.grid, 1, 0, &stored);
    try std.testing.expectEqual(@as(u8, 2), stored.data.width);
    try std.testing.expectEqual(@as(u8, 8), stored.data.size);
    grid.get_cell(s.grid, 1, 1, &stored);
    try std.testing.expect(stored.isPadding());
    try std.testing.expectEqual(@as(u32, 2), s.cx);
}

test "screen-write escaped byte path keeps utf8 glyphs but visualizes raw control and invalid bytes" {
    const screen = @import("screen.zig");
    const s = screen.screen_init(16, 2, 100);
    defer {
        screen.screen_free(s);
        @import("xmalloc.zig").allocator.destroy(s);
    }

    var ctx = T.ScreenWriteCtx{ .s = s };
    _ = putEscapedBytes(&ctx, "\x1b🙂\xc3(", false);

    const rendered = grid.string_cells(s.grid, 0, s.grid.sx, .{
        .trim_trailing_spaces = true,
    });
    defer xm.allocator.free(rendered);

    try std.testing.expectEqualStrings("\\033🙂\\303(", rendered);
}

test "screen-write preview copies a cursor-centered viewport" {
    const screen = @import("screen.zig");

    const src = screen.screen_init(8, 4, 100);
    defer {
        screen.screen_free(src);
        @import("xmalloc.zig").allocator.destroy(src);
    }
    const dst = screen.screen_init(4, 2, 100);
    defer {
        screen.screen_free(dst);
        @import("xmalloc.zig").allocator.destroy(dst);
    }

    {
        var src_ctx = T.ScreenWriteCtx{ .s = src };
        putn(&src_ctx, "abcdefgh\r\nijklmnop\r\nqrstuvwx\r\nyz012345");
        src.cx = 5;
        src.cy = 2;
        src.mode |= T.MODE_CURSOR;
        src.cursor_visible = true;
    }

    var dst_ctx = T.ScreenWriteCtx{ .s = dst };
    preview(&dst_ctx, src, 4, 2);

    const first = grid.string_cells(dst.grid, 0, dst.grid.sx, .{ .trim_trailing_spaces = true });
    defer xm.allocator.free(first);
    const second = grid.string_cells(dst.grid, 1, dst.grid.sx, .{ .trim_trailing_spaces = true });
    defer xm.allocator.free(second);

    try std.testing.expectEqualStrings("uvwx", first);
    try std.testing.expectEqualStrings("2345", second);
}

test "screen-write box_draw draws four corners and borders with ACS charset" {
    const screen = @import("screen.zig");
    const s = screen.screen_init(6, 4, 100);
    defer {
        screen.screen_free(s);
        xm.allocator.destroy(s);
    }

    var ctx = T.ScreenWriteCtx{ .s = s };
    box_draw(&ctx, 6, 4);

    // Top-left corner should be 'l' with CHARSET attr
    var gc: T.GridCell = undefined;
    grid.get_cell(s.grid, 0, 0, &gc);
    try std.testing.expect(gc.attr & T.GRID_ATTR_CHARSET != 0);
    try std.testing.expectEqual(@as(u8, 'l'), gc.data.data[0]);

    // Top-right corner should be 'k'
    grid.get_cell(s.grid, 0, 5, &gc);
    try std.testing.expectEqual(@as(u8, 'k'), gc.data.data[0]);

    // Bottom-left corner should be 'm'
    grid.get_cell(s.grid, 3, 0, &gc);
    try std.testing.expectEqual(@as(u8, 'm'), gc.data.data[0]);

    // Bottom-right corner should be 'j'
    grid.get_cell(s.grid, 3, 5, &gc);
    try std.testing.expectEqual(@as(u8, 'j'), gc.data.data[0]);

    // Top edge middle should be 'q' (horizontal)
    grid.get_cell(s.grid, 0, 3, &gc);
    try std.testing.expectEqual(@as(u8, 'q'), gc.data.data[0]);

    // Left side should be 'x' (vertical)
    grid.get_cell(s.grid, 1, 0, &gc);
    try std.testing.expectEqual(@as(u8, 'x'), gc.data.data[0]);

    // Right side should be 'x' (vertical)
    grid.get_cell(s.grid, 2, 5, &gc);
    try std.testing.expectEqual(@as(u8, 'x'), gc.data.data[0]);

    // Cursor should be restored to original position
    try std.testing.expectEqual(@as(u32, 0), s.cx);
    try std.testing.expectEqual(@as(u32, 0), s.cy);
}

test "screen-write hline draws horizontal line with join characters" {
    const screen = @import("screen.zig");
    const s = screen.screen_init(10, 3, 100);
    defer {
        screen.screen_free(s);
        xm.allocator.destroy(s);
    }

    var ctx = T.ScreenWriteCtx{ .s = s };
    cursor_to(&ctx, 1, 1);
    hline(&ctx, 6, true, true);

    // Left join at start
    var gc: T.GridCell = undefined;
    grid.get_cell(s.grid, 1, 1, &gc);
    try std.testing.expect(gc.attr & T.GRID_ATTR_CHARSET != 0);
    try std.testing.expectEqual(@as(u8, 't'), gc.data.data[0]);

    // Horizontal in the middle
    grid.get_cell(s.grid, 1, 3, &gc);
    try std.testing.expectEqual(@as(u8, 'q'), gc.data.data[0]);

    // Right join at end
    grid.get_cell(s.grid, 1, 6, &gc);
    try std.testing.expectEqual(@as(u8, 'u'), gc.data.data[0]);

    // Cursor restored
    try std.testing.expectEqual(@as(u32, 1), s.cx);
    try std.testing.expectEqual(@as(u32, 1), s.cy);
}

test "screen-write hline without joins uses plain horizontal" {
    const screen = @import("screen.zig");
    const s = screen.screen_init(6, 1, 100);
    defer {
        screen.screen_free(s);
        xm.allocator.destroy(s);
    }

    var ctx = T.ScreenWriteCtx{ .s = s };
    hline(&ctx, 4, false, false);

    var gc: T.GridCell = undefined;
    grid.get_cell(s.grid, 0, 0, &gc);
    try std.testing.expectEqual(@as(u8, 'q'), gc.data.data[0]);

    grid.get_cell(s.grid, 0, 3, &gc);
    try std.testing.expectEqual(@as(u8, 'q'), gc.data.data[0]);
}

test "screen-write vline draws vertical line with join characters" {
    const screen = @import("screen.zig");
    const s = screen.screen_init(5, 6, 100);
    defer {
        screen.screen_free(s);
        xm.allocator.destroy(s);
    }

    var ctx = T.ScreenWriteCtx{ .s = s };
    cursor_to(&ctx, 0, 2);
    vline(&ctx, 5, true, true);

    // Top join at start
    var gc: T.GridCell = undefined;
    grid.get_cell(s.grid, 0, 2, &gc);
    try std.testing.expect(gc.attr & T.GRID_ATTR_CHARSET != 0);
    try std.testing.expectEqual(@as(u8, 'w'), gc.data.data[0]);

    // Vertical in the middle
    grid.get_cell(s.grid, 2, 2, &gc);
    try std.testing.expectEqual(@as(u8, 'x'), gc.data.data[0]);

    // Bottom join at end
    grid.get_cell(s.grid, 4, 2, &gc);
    try std.testing.expectEqual(@as(u8, 'v'), gc.data.data[0]);

    // Cursor restored
    try std.testing.expectEqual(@as(u32, 2), s.cx);
    try std.testing.expectEqual(@as(u32, 0), s.cy);
}

test "screen-write vline without joins uses plain vertical" {
    const screen = @import("screen.zig");
    const s = screen.screen_init(3, 4, 100);
    defer {
        screen.screen_free(s);
        xm.allocator.destroy(s);
    }

    var ctx = T.ScreenWriteCtx{ .s = s };
    cursor_to(&ctx, 0, 1);
    vline(&ctx, 3, false, false);

    var gc: T.GridCell = undefined;
    grid.get_cell(s.grid, 0, 1, &gc);
    try std.testing.expectEqual(@as(u8, 'x'), gc.data.data[0]);

    grid.get_cell(s.grid, 2, 1, &gc);
    try std.testing.expectEqual(@as(u8, 'x'), gc.data.data[0]);
}

test "screen-write fullredraw is a no-op that doesn't corrupt content" {
    const screen = @import("screen.zig");
    const s = screen.screen_init(3, 2, 100);
    defer {
        screen.screen_free(s);
        xm.allocator.destroy(s);
    }

    var ctx = T.ScreenWriteCtx{ .s = s };
    putn(&ctx, "abc");

    // fullredraw is a no-op stub; just verify it doesn't crash
    fullredraw(&ctx);

    // Content should be unchanged
    try std.testing.expectEqual(@as(u8, 'a'), grid.ascii_at(s.grid, 0, 0));
    try std.testing.expectEqual(@as(u8, 'b'), grid.ascii_at(s.grid, 0, 1));
    try std.testing.expectEqual(@as(u8, 'c'), grid.ascii_at(s.grid, 0, 2));
}

fn screenWriteTestPeerDispatch(_: ?*c.imsg.imsg, _: ?*anyopaque) callconv(.c) void {}

test "screen-write setselection forwards OSC 52 to attached pane viewers" {
    const env_mod = @import("environ.zig");
    const proc_mod = @import("proc.zig");
    const protocol = @import("zmux-protocol.zig");
    const tty_features = @import("tty-features.zig");
    const screen = @import("screen.zig");
    const window_mod = @import("window.zig");
    const session_mod = @import("session.zig");

    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    window_mod.window_init_globals(xm.allocator);
    session_mod.session_init_globals(xm.allocator);
    client_registry.clients.clearRetainingCapacity();
    defer client_registry.clients.clearRetainingCapacity();

    const base_grid = grid.grid_create(20, 4, 0);
    defer grid.grid_free(base_grid);
    const alt_screen = screen.screen_init(20, 4, 0);
    defer {
        screen.screen_free(alt_screen);
        xm.allocator.destroy(alt_screen);
    }

    var window = T.Window{
        .id = 91,
        .name = xm.xstrdup("screen-write-selection"),
        .sx = 20,
        .sy = 4,
        .options = opts.options_create(opts.global_w_options),
    };
    defer xm.allocator.free(window.name);
    defer opts.options_free(window.options);
    defer window.panes.deinit(xm.allocator);
    defer window.last_panes.deinit(xm.allocator);
    defer window.winlinks.deinit(xm.allocator);

    var pane = T.WindowPane{
        .id = 92,
        .window = &window,
        .options = opts.options_create(window.options),
        .sx = 20,
        .sy = 4,
        .screen = alt_screen,
        .base = .{ .grid = base_grid, .rlower = 3 },
    };
    defer opts.options_free(pane.options);
    try window.panes.append(xm.allocator, &pane);
    window.active = &pane;

    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);
    const session_name = xm.xstrdup("screen-write-selection");
    defer xm.allocator.free(session_name);
    var session = T.Session{
        .id = 7,
        .name = session_name,
        .cwd = "",
        .options = opts.options_create(opts.global_s_options),
        .environ = env,
        .lastw = .{},
        .windows = std.AutoHashMap(i32, *T.Winlink).init(xm.allocator),
    };
    defer opts.options_free(session.options);
    defer session.windows.deinit();
    defer session.lastw.deinit(xm.allocator);

    var wl = T.Winlink{
        .idx = 0,
        .session = &session,
        .window = &window,
    };
    try session.windows.put(0, &wl);
    try window.winlinks.append(xm.allocator, &wl);
    session.curw = &wl;

    var pair: [2]i32 = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &pair));

    var proc = T.ZmuxProc{ .name = "screen-write-setselection" };
    defer proc.peers.deinit(xm.allocator);

    const client_env = env_mod.environ_create();
    defer env_mod.environ_free(client_env);
    var client = T.Client{
        .name = "clip-viewer",
        .environ = client_env,
        .tty = undefined,
        .status = .{},
        .flags = T.CLIENT_ATTACHED,
        .session = &session,
        .term_features = tty_features.featureBit(.clipboard),
    };
    client.tty = .{ .client = &client };
    client.tty.flags |= @intCast(T.TTY_STARTED);
    client.peer = proc_mod.proc_add_peer(&proc, pair[0], screenWriteTestPeerDispatch, null);
    defer {
        const peer = client.peer.?;
        c.imsg.imsgbuf_clear(&peer.ibuf);
        std.posix.close(peer.ibuf.fd);
        xm.allocator.destroy(peer);
        proc.peers.clearRetainingCapacity();
    }
    client_registry.add(&client);

    var reader: c.imsg.imsgbuf = undefined;
    try std.testing.expectEqual(@as(i32, 0), c.imsg.imsgbuf_init(&reader, pair[1]));
    defer {
        c.imsg.imsgbuf_clear(&reader);
        std.posix.close(pair[1]);
    }

    var ctx = T.ScreenWriteCtx{ .wp = &pane, .s = pane.screen };
    setselection(&ctx, "", "clipboard data");

    try std.testing.expectEqual(@as(i32, 1), c.imsg.imsgbuf_read(&reader));

    var imsg_msg: c.imsg.imsg = undefined;
    try std.testing.expect(c.imsg.imsg_get(&reader, &imsg_msg) > 0);
    defer c.imsg.imsg_free(&imsg_msg);
    try std.testing.expectEqual(@as(u32, @intCast(@intFromEnum(protocol.MsgType.write))), c.imsg.imsg_get_type(&imsg_msg));

    const payload_len = imsg_msg.hdr.len -% @sizeOf(c.imsg.imsg_hdr);
    const payload = try xm.allocator.alloc(u8, payload_len);
    defer xm.allocator.free(payload);
    _ = c.imsg.imsg_get_data(&imsg_msg, payload.ptr, payload.len);

    var stream: i32 = 0;
    @memcpy(std.mem.asBytes(&stream), payload[0..@sizeOf(i32)]);
    try std.testing.expectEqual(@as(i32, 1), stream);

    const data = "clipboard data";
    const b64_len = std.base64.standard.Encoder.calcSize(data.len);
    const b64 = try xm.allocator.alloc(u8, b64_len);
    defer xm.allocator.free(b64);
    _ = std.base64.standard.Encoder.encode(b64, data);
    const expected = try std.fmt.allocPrint(xm.allocator, "\x1b]52;;{s}\x07", .{b64});
    defer xm.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, payload[@sizeOf(i32)..]);
}

test "screen-write cursormove respects origin mode" {
    const screen = @import("screen.zig");
    const s = screen.screen_init(10, 10, 100);
    defer {
        screen.screen_free(s);
        xm.allocator.destroy(s);
    }

    var ctx = T.ScreenWriteCtx{ .s = s };
    s.rupper = 2;
    s.rlower = 7;

    cursormove(&ctx, 3, 1, false);
    try std.testing.expectEqual(@as(u32, 3), s.cx);
    try std.testing.expectEqual(@as(u32, 1), s.cy);

    s.mode |= T.MODE_ORIGIN;
    cursormove(&ctx, 0, 0, true);
    try std.testing.expectEqual(@as(u32, 0), s.cx);
    try std.testing.expectEqual(@as(u32, 2), s.cy);

    cursormove(&ctx, null, 3, true);
    try std.testing.expectEqual(@as(u32, 0), s.cx);
    try std.testing.expectEqual(@as(u32, 5), s.cy);
}

test "screen-write cursorup and cursordown respect scroll region" {
    const screen = @import("screen.zig");
    const s = screen.screen_init(10, 10, 100);
    defer {
        screen.screen_free(s);
        xm.allocator.destroy(s);
    }

    var ctx = T.ScreenWriteCtx{ .s = s };
    s.rupper = 2;
    s.rlower = 7;

    s.cy = 5;
    cursorup(&ctx, 10);
    try std.testing.expectEqual(@as(u32, 2), s.cy);

    s.cy = 1;
    cursorup(&ctx, 10);
    try std.testing.expectEqual(@as(u32, 0), s.cy);

    s.cy = 5;
    cursordown(&ctx, 10);
    try std.testing.expectEqual(@as(u32, 7), s.cy);

    s.cy = 8;
    cursordown(&ctx, 10);
    try std.testing.expectEqual(@as(u32, 9), s.cy);
}

test "screen-write cursorleft and cursorright clamp at edges" {
    const screen = @import("screen.zig");
    const s = screen.screen_init(10, 5, 100);
    defer {
        screen.screen_free(s);
        xm.allocator.destroy(s);
    }

    var ctx = T.ScreenWriteCtx{ .s = s };
    s.cx = 5;
    cursorright(&ctx, 100);
    try std.testing.expectEqual(@as(u32, 9), s.cx);

    cursorleft(&ctx, 100);
    try std.testing.expectEqual(@as(u32, 0), s.cx);

    cursorleft(&ctx, 0);
    try std.testing.expectEqual(@as(u32, 0), s.cx);
}

test "screen-write putc_styled writes character with cell attributes" {
    const screen = @import("screen.zig");
    const s = screen.screen_init(6, 2, 100);
    defer {
        screen.screen_free(s);
        xm.allocator.destroy(s);
    }

    var ctx = T.ScreenWriteCtx{ .s = s };
    var gc = T.grid_default_cell;
    gc.attr |= T.GRID_ATTR_BRIGHT;
    putc_styled(&ctx, &gc, 'A');

    var stored: T.GridCell = undefined;
    grid.get_cell(s.grid, 0, 0, &stored);
    try std.testing.expectEqual(@as(u8, 'A'), stored.data.data[0]);
    try std.testing.expect(stored.attr & T.GRID_ATTR_BRIGHT != 0);
}

test "screen-write nputs writes styled string with width limit" {
    const screen = @import("screen.zig");
    const s = screen.screen_init(10, 2, 100);
    defer {
        screen.screen_free(s);
        xm.allocator.destroy(s);
    }

    var ctx = T.ScreenWriteCtx{ .s = s };
    var gc = T.grid_default_cell;
    gc.attr |= T.GRID_ATTR_ITALICS;
    nputs(&ctx, 4, &gc, "Hello!");

    try std.testing.expectEqual(@as(u8, 'H'), grid.ascii_at(s.grid, 0, 0));
    try std.testing.expectEqual(@as(u8, 'e'), grid.ascii_at(s.grid, 0, 1));
    try std.testing.expectEqual(@as(u8, 'l'), grid.ascii_at(s.grid, 0, 2));
    try std.testing.expectEqual(@as(u8, 'l'), grid.ascii_at(s.grid, 0, 3));
    try std.testing.expectEqual(@as(u8, ' '), grid.ascii_at(s.grid, 0, 4));

    var stored: T.GridCell = undefined;
    grid.get_cell(s.grid, 0, 0, &stored);
    try std.testing.expect(stored.attr & T.GRID_ATTR_ITALICS != 0);
}

test "screen-write fast_copy copies cells between screens" {
    const screen = @import("screen.zig");
    const src = screen.screen_init(6, 3, 100);
    defer {
        screen.screen_free(src);
        xm.allocator.destroy(src);
    }
    const dst = screen.screen_init(6, 3, 100);
    defer {
        screen.screen_free(dst);
        xm.allocator.destroy(dst);
    }

    {
        var src_ctx = T.ScreenWriteCtx{ .s = src };
        putn(&src_ctx, "abcdef");
        cursor_to(&src_ctx, 1, 0);
        putn(&src_ctx, "ghijkl");
    }

    var dst_ctx = T.ScreenWriteCtx{ .s = dst };
    cursor_to(&dst_ctx, 0, 0);
    fast_copy(&dst_ctx, src, 2, 0, 3, 2);

    try std.testing.expectEqual(@as(u8, 'c'), grid.ascii_at(dst.grid, 0, 0));
    try std.testing.expectEqual(@as(u8, 'd'), grid.ascii_at(dst.grid, 0, 1));
    try std.testing.expectEqual(@as(u8, 'e'), grid.ascii_at(dst.grid, 0, 2));
    try std.testing.expectEqual(@as(u8, 'i'), grid.ascii_at(dst.grid, 1, 0));
    try std.testing.expectEqual(@as(u8, 'j'), grid.ascii_at(dst.grid, 1, 1));
    try std.testing.expectEqual(@as(u8, 'k'), grid.ascii_at(dst.grid, 1, 2));

    try std.testing.expectEqual(@as(u32, 0), dst.cx);
    try std.testing.expectEqual(@as(u32, 0), dst.cy);
}

test "screen-write scrollregion resets cursor to top-left" {
    const screen = @import("screen.zig");
    const s = screen.screen_init(10, 10, 100);
    defer {
        screen.screen_free(s);
        xm.allocator.destroy(s);
    }

    var ctx = T.ScreenWriteCtx{ .s = s };
    s.cx = 5;
    s.cy = 5;

    scrollregion(&ctx, 2, 7);
    try std.testing.expectEqual(@as(u32, 0), s.cx);
    try std.testing.expectEqual(@as(u32, 0), s.cy);
    try std.testing.expectEqual(@as(u32, 2), s.rupper);
    try std.testing.expectEqual(@as(u32, 7), s.rlower);
}

test "screen-write collect lifecycle: start, add, end, flush, stop" {
    const screen = @import("screen.zig");
    const s = screen.screen_init(10, 4, 100);
    defer {
        screen.screen_free(s);
        xm.allocator.destroy(s);
    }

    var ctx: T.ScreenWriteCtx = undefined;
    screen_write_start(&ctx, s);
    defer screen_write_stop(&ctx);

    try std.testing.expect(ctx.item != null);
    try std.testing.expect(s.write_list != null);
    try std.testing.expectEqual(@as(u32, 0), ctx.scrolled);
    try std.testing.expectEqual(@as(u32, 8), ctx.bg);

    var gc = T.grid_default_cell;
    utf8.utf8_set(&gc.data, 'A');
    screen_write_collect_add(&ctx, &gc);
    utf8.utf8_set(&gc.data, 'B');
    screen_write_collect_add(&ctx, &gc);
    utf8.utf8_set(&gc.data, 'C');
    screen_write_collect_add(&ctx, &gc);

    try std.testing.expectEqual(@as(u32, 3), ctx.item.?.used);

    screen_write_collect_end(&ctx);

    try std.testing.expectEqual(@as(u8, 'A'), grid.ascii_at(s.grid, 0, 0));
    try std.testing.expectEqual(@as(u8, 'B'), grid.ascii_at(s.grid, 0, 1));
    try std.testing.expectEqual(@as(u8, 'C'), grid.ascii_at(s.grid, 0, 2));
    try std.testing.expectEqual(@as(u32, 3), s.cx);
}

test "screen-write collect_scroll moves items between lines" {
    const screen = @import("screen.zig");
    const s = screen.screen_init(6, 4, 100);
    defer {
        screen.screen_free(s);
        xm.allocator.destroy(s);
    }

    var ctx: T.ScreenWriteCtx = undefined;
    screen_write_start(&ctx, s);
    defer screen_write_stop(&ctx);

    s.rupper = 0;
    s.rlower = 3;

    screen_write_collect_scroll(&ctx, 8);
    const wl = s.write_list.?;

    try std.testing.expect(!cline_is_empty(&wl[3]));
    const ci = wl[3].first.?;
    try std.testing.expectEqual(T.ScreenWriteCitemType.CLEAR, ci.ctype);
    try std.testing.expectEqual(@as(u32, 6), ci.used);
}

test "screen-write collect_clear frees items from a line" {
    const screen = @import("screen.zig");
    const s = screen.screen_init(6, 3, 100);
    defer {
        screen.screen_free(s);
        xm.allocator.destroy(s);
    }

    var ctx: T.ScreenWriteCtx = undefined;
    screen_write_start(&ctx, s);
    defer screen_write_stop(&ctx);

    const ci = get_citem();
    ci.x = 0;
    ci.used = 3;
    ci.ctype = .TEXT;
    const wl = s.write_list.?;
    cline_insert_tail(&wl[0], ci);

    try std.testing.expect(!cline_is_empty(&wl[0]));
    screen_write_collect_clear(&ctx, 0, 1);
    try std.testing.expect(cline_is_empty(&wl[0]));
}

test "screen-write collect_trim splits overlapping items" {
    const screen = @import("screen.zig");
    const s = screen.screen_init(20, 3, 100);
    defer {
        screen.screen_free(s);
        xm.allocator.destroy(s);
    }

    var ctx: T.ScreenWriteCtx = undefined;
    screen_write_start(&ctx, s);
    defer screen_write_stop(&ctx);

    const ci = get_citem();
    ci.x = 2;
    ci.used = 10;
    ci.ctype = .TEXT;
    const wl = s.write_list.?;
    cline_insert_tail(&wl[0], ci);

    _ = screen_write_collect_trim(&ctx, 0, 5, 3, null);

    const first_item = wl[0].first.?;
    try std.testing.expectEqual(@as(u32, 2), first_item.x);
    try std.testing.expectEqual(@as(u32, 3), first_item.used);

    const second_item = first_item.next.?;
    try std.testing.expectEqual(@as(u32, 8), second_item.x);
    try std.testing.expectEqual(@as(u32, 4), second_item.used);
}

test "screen-write screen_write_cell writes cell to grid with collect tracking" {
    const screen = @import("screen.zig");
    const s = screen.screen_init(10, 3, 100);
    defer {
        screen.screen_free(s);
        xm.allocator.destroy(s);
    }

    var ctx: T.ScreenWriteCtx = undefined;
    screen_write_start(&ctx, s);
    defer screen_write_stop(&ctx);

    var gc = T.grid_default_cell;
    utf8.utf8_set(&gc.data, 'X');
    screen_write_cell(&ctx, &gc);

    try std.testing.expectEqual(@as(u8, 'X'), grid.ascii_at(s.grid, 0, 0));
    try std.testing.expectEqual(@as(u32, 1), s.cx);
}

test "screen-write make_list and free_list manage write_list lifecycle" {
    const screen = @import("screen.zig");
    const s = screen.screen_init(5, 3, 100);
    defer {
        screen.screen_free(s);
        xm.allocator.destroy(s);
    }

    try std.testing.expect(s.write_list == null);
    screen_write_make_list(s);
    try std.testing.expect(s.write_list != null);
    try std.testing.expectEqual(@as(usize, 3), s.write_list.?.len);

    screen_write_free_list(s);
    try std.testing.expect(s.write_list == null);
}

test "screen-write newline without MODE_CRLF moves cursor down but preserves cx" {
    const screen = @import("screen.zig");
    const s = screen.screen_init(10, 5, 100);
    defer {
        screen.screen_free(s);
        xm.allocator.destroy(s);
    }

    var ctx: T.ScreenWriteCtx = undefined;
    screen_write_start(&ctx, s);
    defer screen_write_stop(&ctx);

    // Ensure MODE_CRLF is not set
    s.mode &= ~T.MODE_CRLF;
    s.cx = 5;
    s.cy = 1;

    newline(&ctx);

    // LF without CRLF mode: cy advances, cx unchanged
    try std.testing.expectEqual(@as(u32, 5), s.cx);
    try std.testing.expectEqual(@as(u32, 2), s.cy);
}

test "screen-write newline with MODE_CRLF moves cursor down and resets cx" {
    const screen = @import("screen.zig");
    const s = screen.screen_init(10, 5, 100);
    defer {
        screen.screen_free(s);
        xm.allocator.destroy(s);
    }

    var ctx: T.ScreenWriteCtx = undefined;
    screen_write_start(&ctx, s);
    defer screen_write_stop(&ctx);

    // Enable MODE_CRLF
    s.mode |= T.MODE_CRLF;
    s.cx = 5;
    s.cy = 1;

    newline(&ctx);

    // LF with CRLF mode: cy advances, cx reset to 0
    try std.testing.expectEqual(@as(u32, 0), s.cx);
    try std.testing.expectEqual(@as(u32, 2), s.cy);
}

test "screen-write linefeed never touches cx regardless of MODE_CRLF" {
    const screen = @import("screen.zig");
    const s = screen.screen_init(10, 5, 100);
    defer {
        screen.screen_free(s);
        xm.allocator.destroy(s);
    }

    var ctx: T.ScreenWriteCtx = undefined;
    screen_write_start(&ctx, s);
    defer screen_write_stop(&ctx);

    // Test without MODE_CRLF
    s.mode &= ~T.MODE_CRLF;
    s.cx = 7;
    s.cy = 0;
    linefeed(&ctx, false);
    try std.testing.expectEqual(@as(u32, 7), s.cx);
    try std.testing.expectEqual(@as(u32, 1), s.cy);

    // Test with MODE_CRLF — linefeed still must not touch cx
    s.mode |= T.MODE_CRLF;
    s.cx = 7;
    s.cy = 1;
    linefeed(&ctx, false);
    try std.testing.expectEqual(@as(u32, 7), s.cx);
    try std.testing.expectEqual(@as(u32, 2), s.cy);
}
