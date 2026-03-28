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

//! pane-empty-input.zig - shared reduced stdin->empty-pane input bridge.

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const cmdq = @import("cmd-queue.zig");
const file_mod = @import("file.zig");
const pane_io = @import("pane-io.zig");
const server = @import("server.zig");

const EmptyPaneInputState = struct {
    item: *cmdq.CmdqItem,
    wp: *T.WindowPane,
};

fn done(path: []const u8, errno_value: c_int, data: []const u8, cbdata: ?*anyopaque) void {
    const state: *EmptyPaneInputState = @ptrCast(@alignCast(cbdata orelse return));
    defer xm.allocator.destroy(state);

    if (errno_value != 0) {
        cmdq.cmdq_error(state.item, "{s}: {s}", .{ file_mod.strerror(errno_value), path });
    } else if (data.len != 0) {
        pane_io.pane_io_display(state.wp, data);
        server.server_redraw_window(state.wp.window);
    }

    cmdq.cmdq_continue(state.item);
}

pub fn start(item: *cmdq.CmdqItem, wp: *T.WindowPane) T.CmdRetval {
    if ((wp.flags & T.PANE_EMPTY) == 0) {
        cmdq.cmdq_error(item, "pane is not empty", .{});
        return .@"error";
    }

    const client = cmdq.cmdq_get_client(item) orelse return .normal;
    if ((client.flags & T.CLIENT_EXIT) != 0) return .normal;
    if (client.session != null) return .normal;

    if (file_mod.shouldUseRemotePathIO(client)) {
        const state = xm.allocator.create(EmptyPaneInputState) catch unreachable;
        state.* = .{ .item = item, .wp = wp };

        return switch (file_mod.startRemoteRead(client, "-", done, state)) {
            .wait => .wait,
            .err => |errno_value| blk: {
                xm.allocator.destroy(state);
                cmdq.cmdq_error(item, "{s}: -", .{file_mod.strerror(errno_value)});
                break :blk .@"error";
            },
        };
    }

    return switch (file_mod.readResolvedPathAlloc(client, "-")) {
        .data => |data| blk: {
            defer xm.allocator.free(data);
            if (data.len != 0) {
                pane_io.pane_io_display(wp, data);
                server.server_redraw_window(wp.window);
            }
            break :blk .normal;
        },
        .err => |errno_value| blk: {
            cmdq.cmdq_error(item, "{s}: -", .{file_mod.strerror(errno_value)});
            break :blk .@"error";
        },
    };
}
