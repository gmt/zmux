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
// Grid cursor motion on a backing screen (tmux/window-copy.c correlate).

const T = @import("types.zig");

pub fn window_copy_move_left(s: *T.Screen, fx: *u32, fy: *u32, wrapflag: bool) void {
    if (fx.* == 0) {
        if (fy.* == 0) {
            if (wrapflag) {
                fx.* = if (s.grid.sx > 0) s.grid.sx - 1 else 0;
                fy.* = s.grid.sy -| 1;
            }
            return;
        }
        fx.* = if (s.grid.sx > 0) s.grid.sx - 1 else 0;
        fy.* -= 1;
    } else {
        fx.* -= 1;
    }
}

pub fn window_copy_move_right(s: *T.Screen, fx: *u32, fy: *u32, wrapflag: bool) void {
    const sx = s.grid.sx;
    const max_y = s.grid.sy -| 1;
    if (sx > 0 and fx.* == sx - 1) {
        if (fy.* == max_y) {
            if (wrapflag) {
                fx.* = 0;
                fy.* = 0;
            }
            return;
        }
        fx.* = 0;
        fy.* += 1;
    } else {
        fx.* += 1;
    }
}
