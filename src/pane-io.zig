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
// Written for zmux by Greg Turner. This file is new zmux runtime work rather
// than a direct port of a single tmux source file.

//! pane-io.zig – libevent PTY readers feeding pane grids.

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const c = @import("c.zig");
const proc_mod = @import("proc.zig");
const server_mod = @import("server.zig");
const input_mod = @import("input.zig");

pub fn pane_io_start(wp: *T.WindowPane) void {
    if (wp.fd < 0 or wp.event != null) return;
    const base = proc_mod.libevent orelse return;
    wp.event = c.libevent.event_new(
        base,
        wp.fd,
        @intCast(c.libevent.EV_READ | c.libevent.EV_PERSIST),
        pane_read_cb,
        wp,
    );
    if (wp.event) |ev| _ = c.libevent.event_add(ev, null);
}

pub fn pane_io_stop(wp: *T.WindowPane) void {
    if (wp.event) |ev| {
        _ = c.libevent.event_del(ev);
        c.libevent.event_free(ev);
        wp.event = null;
    }
}

export fn pane_read_cb(fd: c_int, _: c_short, arg: ?*anyopaque) void {
    _ = fd;
    const wp: *T.WindowPane = @ptrCast(@alignCast(arg orelse return));

    var buf: [4096]u8 = undefined;
    while (true) {
        const n = std.posix.read(wp.fd, &buf) catch |err| switch (err) {
            error.WouldBlock => return,
            else => {
                pane_io_stop(wp);
                if (wp.fd >= 0) {
                    std.posix.close(wp.fd);
                    wp.fd = -1;
                }
                return;
            },
        };
        if (n == 0) {
            pane_io_stop(wp);
            if (wp.fd >= 0) {
                std.posix.close(wp.fd);
                wp.fd = -1;
            }
            return;
        }
        pane_io_feed(wp, buf[0..n]);
        server_mod.server_redraw_window(wp.window);
    }
}

pub fn pane_io_feed(wp: *T.WindowPane, bytes: []const u8) void {
    pipe_bytes(wp, bytes);
    input_mod.input_parse_screen(wp, bytes);
}

fn pipe_bytes(wp: *T.WindowPane, bytes: []const u8) void {
    if (wp.pipe_fd < 0 or bytes.len == 0) return;

    var rest = bytes;
    while (rest.len > 0) {
        const written = std.posix.write(wp.pipe_fd, rest) catch {
            close_pipe(wp);
            return;
        };
        if (written == 0) {
            close_pipe(wp);
            return;
        }
        rest = rest[written..];
    }
}

fn close_pipe(wp: *T.WindowPane) void {
    if (wp.pipe_fd >= 0) {
        std.posix.close(wp.pipe_fd);
        wp.pipe_fd = -1;
    }
    if (wp.pipe_pid > 0) {
        _ = std.c.kill(wp.pipe_pid, std.posix.SIG.HUP);
        _ = std.c.kill(wp.pipe_pid, std.posix.SIG.TERM);
        wp.pipe_pid = -1;
    }
}

test "pane_io_feed writes printable bytes into the grid and advances cursor" {
    const opts = @import("options.zig");
    const win = @import("window.zig");
    const grid = @import("grid.zig");

    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    win.window_init_globals(xm.allocator);

    const w = win.window_create(8, 3, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    defer {
        while (w.panes.items.len > 0) {
            const wp = w.panes.items[w.panes.items.len - 1];
            win.window_remove_pane(w, wp);
        }
        w.panes.deinit(xm.allocator);
        w.last_panes.deinit(xm.allocator);
        opts.options_free(w.options);
        xm.allocator.free(w.name);
        _ = win.windows.remove(w.id);
        xm.allocator.destroy(w);
    }

    const wp = win.window_add_pane(w, null, 8, 3);
    pane_io_feed(wp, "abc");
    try std.testing.expectEqual(@as(u8, 'a'), grid.ascii_at(wp.base.grid, 0, 0));
    try std.testing.expectEqual(@as(u8, 'c'), grid.ascii_at(wp.base.grid, 0, 2));
    try std.testing.expectEqual(@as(u32, 3), wp.base.cx);
}

test "pane_io_feed handles newline and scrolls when reaching the bottom" {
    const opts = @import("options.zig");
    const win = @import("window.zig");
    const grid = @import("grid.zig");

    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    win.window_init_globals(xm.allocator);

    const w = win.window_create(4, 2, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    defer {
        while (w.panes.items.len > 0) {
            const wp = w.panes.items[w.panes.items.len - 1];
            win.window_remove_pane(w, wp);
        }
        w.panes.deinit(xm.allocator);
        w.last_panes.deinit(xm.allocator);
        opts.options_free(w.options);
        xm.allocator.free(w.name);
        _ = win.windows.remove(w.id);
        xm.allocator.destroy(w);
    }

    const wp = win.window_add_pane(w, null, 4, 2);
    pane_io_feed(wp, "one\ntwo\ntri");
    try std.testing.expectEqual(@as(u8, 't'), grid.ascii_at(wp.base.grid, 0, 0));
    try std.testing.expectEqual(@as(u8, 't'), grid.ascii_at(wp.base.grid, 1, 0));
    try std.testing.expectEqual(@as(u8, 'r'), grid.ascii_at(wp.base.grid, 1, 1));
}

test "pane_io_feed mirrors raw bytes into pane pipe fd" {
    const opts = @import("options.zig");
    const win = @import("window.zig");

    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    win.window_init_globals(xm.allocator);

    const w = win.window_create(8, 3, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    defer {
        while (w.panes.items.len > 0) {
            const wp = w.panes.items[w.panes.items.len - 1];
            win.window_remove_pane(w, wp);
        }
        w.panes.deinit(xm.allocator);
        w.last_panes.deinit(xm.allocator);
        opts.options_free(w.options);
        xm.allocator.free(w.name);
        _ = win.windows.remove(w.id);
        xm.allocator.destroy(w);
    }

    const wp = win.window_add_pane(w, null, 8, 3);
    const pipe_fds = try std.posix.pipe();
    defer std.posix.close(pipe_fds[0]);
    wp.pipe_fd = pipe_fds[1];
    pane_io_feed(wp, "abc\r\n");

    var buf: [16]u8 = undefined;
    const n = try std.posix.read(pipe_fds[0], &buf);
    try std.testing.expectEqualStrings("abc\r\n", buf[0..n]);
    std.posix.close(pipe_fds[1]);
    wp.pipe_fd = -1;
}
