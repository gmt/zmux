// Copyright (c) 2026 Greg Turner <gmt@be-evil.net>
// ISC licence – see COPYING.
// Ported from tmux/cmd-list-windows.c
// Original copyright:
//   Copyright (c) 2007 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const cmd_mod = @import("cmd.zig");
const cmdq = @import("cmd-queue.zig");
const cmd_find = @import("cmd-find.zig");
const sess = @import("session.zig");

fn exec(cmd: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {
    const args = cmd_mod.cmd_get_args(cmd);
    const fmt = args.get('F') orelse "#{window_index}: #{window_name}#{?window_flags,#{window_flags}, }#{?window_active, (active),}";
    const all_sessions = args.has('a');

    if (all_sessions) {
        var sit = sess.sessions.valueIterator();
        while (sit.next()) |sv| {
            list_windows_session(sv.*, fmt, item);
        }
    } else {
        var target: T.CmdFindState = .{};
        if (cmd_find.cmd_find_target(&target, item, args.get('t'), .session, 0) != 0)
            return .@"error";
        if (target.s) |s| list_windows_session(s, fmt, item);
    }
    return .normal;
}

fn list_windows_session(s: *T.Session, fmt: []const u8, item: *cmdq.CmdqItem) void {
    _ = fmt;
    // List by sorted window index
    var keys: std.ArrayList(i32) = .{};
    defer keys.deinit(xm.allocator);
    var it = s.windows.keyIterator();
    while (it.next()) |k| keys.append(xm.allocator, k.*) catch unreachable;
    std.sort.block(i32, keys.items, {}, std.sort.asc(i32));
    for (keys.items) |idx| {
        const wl = s.windows.get(idx) orelse continue;
        cmdq.cmdq_print(item, "{d}: {s}", .{ wl.idx, wl.window.name });
    }
}

pub const entry: cmd_mod.CmdEntry = .{
    .name = "list-windows",
    .alias = "lsw",
    .template = "aF:t:",
    .lower = 0,
    .upper = 0,
    .flags = 0,
    .exec = exec,
};
