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
// Grid row → C string / cell helpers for copy-mode search (tmux/window-copy.c).

const std = @import("std");
const grid = @import("grid.zig");
const T = @import("types.zig");
const utf8 = @import("utf8.zig");
const wc_grid = @import("window-copy-grid.zig");
const xm = @import("xmalloc.zig");

pub fn window_copy_cellstring(gl: ?*const T.GridLine, px: u32, size: ?*usize, free_flag: ?*bool) ?[]const u8 {
    if (free_flag) |f| f.* = false;

    const line = gl orelse {
        if (size) |s| s.* = 1;
        return " ";
    };

    if (px >= line.cellused or px >= line.celldata.len) {
        if (size) |s| s.* = 1;
        return " ";
    }

    const gce = &line.celldata[px];
    if ((gce.flags & T.GRID_FLAG_PADDING) != 0) {
        if (size) |s| s.* = 0;
        return null;
    }

    if ((gce.flags & T.GRID_FLAG_TAB) != 0) {
        if (size) |s| s.* = 1;
        return "\t";
    }

    if ((gce.flags & T.GRID_FLAG_EXTENDED) == 0) {
        if (size) |s| s.* = 1;
        return @as([*]const u8, @ptrCast(&gce.offset_or_data.data.data))[0..1];
    }

    const offset = gce.offset_or_data.offset;
    if (offset < line.extddata.len) {
        const extd = &line.extddata[offset];
        const S = struct {
            threadlocal var buf: T.Utf8Data = std.mem.zeroes(T.Utf8Data);
        };
        utf8.utf8_to_data(extd.data, &S.buf);
        if (S.buf.size == 0) {
            if (size) |s| s.* = 1;
            return " ";
        }
        if (size) |s| s.* = S.buf.size;
        return S.buf.data[0..S.buf.size];
    }

    if (size) |s| s.* = 1;
    return " ";
}

pub fn window_copy_cstrtocellpos(gd: *T.Grid, ncells: u32, ppx: *u32, ppy: *u32, str: []const u8) void {
    if (ncells == 0 or str.len == 0) return;

    const CellInfo = struct {
        d: ?[]const u8,
        dlen: usize,
    };

    var cells = xm.allocator.alloc(CellInfo, ncells) catch unreachable;
    defer xm.allocator.free(cells);

    var cell: u32 = 0;
    var px = ppx.*;
    var pywrap = ppy.*;
    var gl = if (wc_grid.absoluteStorageRow(gd, pywrap)) |row|
        grid.grid_peek_line(@constCast(&gd.*), row)
    else
        null;
    if (gl == null) return;

    while (cell < ncells) : (cell += 1) {
        var dlen: usize = 0;
        var allocated: bool = false;
        const d = window_copy_cellstring(gl, px, &dlen, &allocated);
        cells[cell] = .{ .d = d, .dlen = dlen };
        px += 1;
        if (px == gd.sx) {
            px = 0;
            pywrap += 1;
            gl = if (wc_grid.absoluteStorageRow(gd, pywrap)) |row|
                grid.grid_peek_line(@constCast(&gd.*), row)
            else
                null;
            if (gl == null) break;
        }
    }

    cell = 0;
    const len = str.len;
    while (cell < ncells) {
        var ccell = cell;
        var pos: usize = 0;
        var matched = true;
        while (ccell < ncells) {
            if (pos >= len) {
                matched = false;
                break;
            }
            const d = cells[ccell].d orelse {
                ccell += 1;
                continue;
            };
            const dlen = cells[ccell].dlen;
            if (dlen == 1) {
                if (str[pos] != d[0]) {
                    matched = false;
                    break;
                }
                pos += 1;
            } else {
                const cmp_len = @min(dlen, len - pos);
                if (!std.mem.eql(u8, str[pos..][0..cmp_len], d[0..cmp_len])) {
                    matched = false;
                    break;
                }
                pos += cmp_len;
            }
            ccell += 1;
        }
        if (matched) break;
        cell += 1;
    }

    px = ppx.* + cell;
    pywrap = ppy.*;
    while (px >= gd.sx) {
        px -= gd.sx;
        pywrap += 1;
    }

    ppx.* = px;
    ppy.* = pywrap;
}

/// Find the rightmost regex match within (first..last) of row py.
pub fn window_copy_last_regex(gd: *T.Grid, py: u32, first: u32, last: u32, len_in: u32, ppx: *u32, psx: *u32, buf: [:0]const u8, preg: ?*anyopaque, eflags: i32) bool {
    const c_mod = @import("c.zig");
    const reg = preg orelse return false;
    var foundx = first;
    var foundy = py;
    var oldx = first;
    var savepx: u32 = 0;
    var savesx: u32 = 0;
    var px: u32 = 0;
    var len = len_in;

    var regmatch: c_mod.posix_sys.regmatch_t = undefined;
    while (c_mod.posix_sys.regexec(@ptrCast(reg), buf[px..].ptr, 1, &regmatch, eflags) == 0) {
        if (regmatch.rm_so == regmatch.rm_eo) break;

        foundx = first;
        foundy = py;
        window_copy_cstrtocellpos(gd, len, &foundx, &foundy, buf[@intCast(px + @as(u32, @intCast(regmatch.rm_so)))..]);
        if (foundy > py or foundx >= last) break;
        len -= foundx - oldx;
        savepx = foundx;
        foundx = first;
        foundy = py;
        window_copy_cstrtocellpos(gd, len, &foundx, &foundy, buf[@intCast(px + @as(u32, @intCast(regmatch.rm_eo)))..]);
        if (foundy > py or foundx >= last) {
            ppx.* = savepx;
            psx.* = foundx;
            while (foundy > py) : (foundy -= 1) psx.* += gd.sx;
            psx.* -|= ppx.*;
            return true;
        } else {
            savesx = foundx - savepx;
            len -= savesx;
            oldx = foundx;
        }
        px += @intCast(regmatch.rm_eo);
    }

    if (savesx > 0) {
        ppx.* = savepx;
        psx.* = savesx;
        return true;
    }
    ppx.* = 0;
    psx.* = 0;
    return false;
}

pub fn window_copy_stringify(gd: *T.Grid, py: u32, first: u32, last: u32, _buf: ?[]u8, plen: *u32) ?[]u8 {
    _ = _buf;
    const storage_row = wc_grid.absoluteStorageRow(gd, py) orelse {
        var result = xm.allocator.alloc(u8, plen.*) catch unreachable;
        if (plen.* > 0) result[plen.* - 1] = 0;
        return result;
    };
    const gl = grid.grid_peek_line(@constCast(&gd.*), storage_row) orelse {
        var result = xm.allocator.alloc(u8, plen.*) catch unreachable;
        if (plen.* > 0) result[plen.* - 1] = 0;
        return result;
    };

    var buf_list: std.ArrayList(u8) = .{};

    const existing = plen.*;
    if (existing > 0) {
        buf_list.ensureTotalCapacity(xm.allocator, existing + (last - first) * 4) catch unreachable;
    }

    if (existing > 1) {
        buf_list.resize(xm.allocator, existing - 1) catch unreachable;
    }

    var ax: u32 = first;
    while (ax < last) : (ax += 1) {
        var dlen: usize = 0;
        var allocated: bool = false;
        const d = window_copy_cellstring(gl, ax, &dlen, &allocated) orelse continue;
        if (dlen > 0) {
            buf_list.appendSlice(xm.allocator, d[0..dlen]) catch unreachable;
        }
    }

    buf_list.append(xm.allocator, 0) catch unreachable;
    plen.* = @intCast(buf_list.items.len);
    return buf_list.toOwnedSlice(xm.allocator) catch unreachable;
}
