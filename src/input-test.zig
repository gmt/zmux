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

//! input-test.zig – focused reply-buffer and request-queue tests for input.zig.

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const opts = @import("options.zig");
const input = @import("input.zig");
const env_mod = @import("environ.zig");
const win = @import("window.zig");

fn set_nonblocking_for_test(fd: i32) void {
    const flags = std.c.fcntl(fd, std.posix.F.GETFL, @as(c_int, 0));
    if (flags < 0) return;
    const O_NONBLOCK: c_int = 0x800;
    _ = std.c.fcntl(fd, std.posix.F.SETFL, flags | O_NONBLOCK);
}

fn read_pipe_best_effort(fd: i32, buf: []u8) ![]const u8 {
    const n = std.posix.read(fd, buf) catch |err| switch (err) {
        error.WouldBlock => return &.{},
        else => return err,
    };
    return buf[0..n];
}

const InputTestPane = struct {
    w: *T.Window,
    wp: *T.WindowPane,

    fn init(sx: u32, sy: u32) InputTestPane {
        opts.global_w_options = opts.options_create(null);
        opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
        win.window_init_globals(xm.allocator);

        const w = win.window_create(sx, sy, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
        const wp = win.window_add_pane(w, null, sx, sy);
        return .{ .w = w, .wp = wp };
    }

    fn deinit(self: *InputTestPane) void {
        while (self.w.panes.items.len > 0) {
            const pane = self.w.panes.items[self.w.panes.items.len - 1];
            win.window_remove_pane(self.w, pane);
        }
        self.w.panes.deinit(xm.allocator);
        self.w.last_panes.deinit(xm.allocator);
        opts.options_free(self.w.options);
        xm.allocator.free(self.w.name);
        _ = win.windows.remove(self.w.id);
        xm.allocator.destroy(self.w);
        opts.options_free(opts.global_w_options);
    }
};

test "input_reply formats and sends replies larger than the stack buffer" {
    var pane = InputTestPane.init(8, 3);
    defer pane.deinit();

    const pipe_fds = try std.posix.pipe();
    defer std.posix.close(pipe_fds[0]);
    defer {
        pane.wp.fd = -1;
        std.posix.close(pipe_fds[1]);
    }

    pane.wp.fd = pipe_fds[1];

    const payload = try xm.allocator.alloc(u8, 600);
    defer xm.allocator.free(payload);
    @memset(payload, 'x');

    input.input_reply(pane.wp, false, "prefix:{s}:suffix", .{payload});

    var buf: [640]u8 = undefined;
    const n = try std.posix.read(pipe_fds[0], &buf);
    try std.testing.expectEqual(@as(usize, 614), n);
    try std.testing.expectEqualStrings("prefix:", buf[0..7]);
    try std.testing.expectEqualStrings(":suffix", buf[n - 7 .. n]);
    for (buf[7 .. n - 7]) |ch| try std.testing.expectEqual(@as(u8, 'x'), ch);
}

test "input_reply queues add=true replies behind pending requests" {
    var pane = InputTestPane.init(8, 3);
    defer pane.deinit();

    const pipe_fds = try std.posix.pipe();
    defer std.posix.close(pipe_fds[0]);
    defer {
        pane.wp.fd = -1;
        std.posix.close(pipe_fds[1]);
    }
    set_nonblocking_for_test(pipe_fds[0]);
    pane.wp.fd = pipe_fds[1];

    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);

    var cl: T.Client = .{
        .environ = env,
        .tty = undefined,
        .status = .{},
    };
    cl.tty = .{ .client = &cl };
    defer cl.input_requests.deinit(xm.allocator);

    const pending = try xm.allocator.create(T.InputRequest);
    defer if (pane.wp.input_request_list.items.len != 0) {
        const leftover = pane.wp.input_request_list.items[0];
        _ = pane.wp.input_request_list.orderedRemove(0);
        pane.wp.input_request_count = 0;
        xm.allocator.destroy(leftover);
    };
    pending.* = .{
        .wp = pane.wp,
        .c = &cl,
        .type = .clipboard,
        .t = @intCast(@max(std.time.milliTimestamp(), 0)),
    };
    try pane.wp.input_request_list.append(xm.allocator, pending);
    pane.wp.input_request_count = 1;
    try cl.input_requests.append(xm.allocator, pending);

    input.input_reply(pane.wp, true, "queued-reply", .{});
    try std.testing.expectEqual(@as(usize, 2), pane.wp.input_request_list.items.len);

    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("", try read_pipe_best_effort(pipe_fds[0], &buf));

    input.input_request_reply(&cl, @intFromEnum(T.InputRequestType.clipboard), null);

    try std.testing.expectEqual(@as(usize, 0), pane.wp.input_request_list.items.len);
    try std.testing.expectEqual(@as(u32, 0), pane.wp.input_request_count);
    try std.testing.expectEqual(@as(usize, 0), cl.input_requests.items.len);
    try std.testing.expectEqualStrings("queued-reply", try read_pipe_best_effort(pipe_fds[0], &buf));
}

test "input_reply queued truncation respects stored send length" {
    var pane = InputTestPane.init(8, 3);
    defer pane.deinit();

    const pipe_fds = try std.posix.pipe();
    defer std.posix.close(pipe_fds[0]);
    defer {
        pane.wp.fd = -1;
        std.posix.close(pipe_fds[1]);
    }
    pane.wp.fd = pipe_fds[1];

    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);

    var cl: T.Client = .{
        .environ = env,
        .tty = undefined,
        .status = .{},
    };
    cl.tty = .{ .client = &cl };
    defer cl.input_requests.deinit(xm.allocator);

    const pending = try xm.allocator.create(T.InputRequest);
    defer if (pane.wp.input_request_list.items.len != 0) {
        while (pane.wp.input_request_list.items.len != 0) {
            const leftover = pane.wp.input_request_list.items[0];
            _ = pane.wp.input_request_list.orderedRemove(0);
            if (leftover.type == .queue) {
                if (leftover.data) |d| {
                    const bytes: [*]u8 = @ptrCast(@alignCast(d));
                    xm.allocator.free(bytes[0..@as(usize, @intCast(leftover.idx))]);
                }
            }
            xm.allocator.destroy(leftover);
        }
        pane.wp.input_request_count = 0;
    };
    pending.* = .{
        .wp = pane.wp,
        .c = &cl,
        .type = .clipboard,
        .t = @intCast(@max(std.time.milliTimestamp(), 0)),
    };
    try pane.wp.input_request_list.append(xm.allocator, pending);
    pane.wp.input_request_count = 1;
    try cl.input_requests.append(xm.allocator, pending);

    const payload = try xm.allocator.dupe(u8, "truncate-me");
    const queued = try xm.allocator.create(T.InputRequest);
    queued.* = .{
        .wp = pane.wp,
        .type = .queue,
        .t = @intCast(@max(std.time.milliTimestamp(), 0)),
        .idx = 8,
        .data = payload.ptr,
    };
    try pane.wp.input_request_list.append(xm.allocator, queued);
    pane.wp.input_request_count += 1;

    input.input_request_reply(&cl, @intFromEnum(T.InputRequestType.clipboard), null);

    var buf: [32]u8 = undefined;
    const n = try std.posix.read(pipe_fds[0], &buf);
    try std.testing.expectEqualStrings("truncate", buf[0..n]);
    try std.testing.expectEqual(@as(usize, 0), pane.wp.input_request_list.items.len);
    try std.testing.expectEqual(@as(u32, 0), pane.wp.input_request_count);
    try std.testing.expectEqual(@as(usize, 0), cl.input_requests.items.len);
}
