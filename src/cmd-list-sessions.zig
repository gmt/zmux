// Copyright (c) 2026 Greg Turner <gmt@be-evil.net>
// ISC licence – see COPYING.
// Ported from tmux/cmd-list-sessions.c
// Original copyright:
//   Copyright (c) 2007 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const cmd_mod = @import("cmd.zig");
const cmdq = @import("cmd-queue.zig");
const sess = @import("session.zig");

fn exec(cmd: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {
    const args = cmd_mod.cmd_get_args(cmd);
    const fmt = args.get('F') orelse "#{session_name}: #{session_windows} windows (created #{t:session_created}) #{?session_grouped, (group #{session_group}: #{session_group_list}),}#{?session_attached,(attached),}";

    var sorted: std.ArrayList(*T.Session) = .{};
    defer sorted.deinit(xm.allocator);
    var it = sess.sessions.valueIterator();
    while (it.next()) |v| sorted.append(xm.allocator, v.*) catch unreachable;
    std.sort.block(*T.Session, sorted.items, {}, struct {
        fn lessThan(_: void, a: *T.Session, b: *T.Session) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);

    for (sorted.items) |s| {
        var output = xm.xasprintf("{s}", .{fmt});
        defer xm.allocator.free(output);
        output = replace_placeholder(output, "#{session_name}", s.name);
        const ww = if (s.curw) |wl| wl.window.sx else @as(u32, 80);
        const wh = if (s.curw) |wl| wl.window.sy else @as(u32, 24);
        var ww_buf: [12]u8 = undefined;
        var wh_buf: [12]u8 = undefined;
        output = replace_placeholder(output, "#{window_width}", std.fmt.bufPrint(&ww_buf, "{d}", .{ww}) catch "80");
        output = replace_placeholder(output, "#{window_height}", std.fmt.bufPrint(&wh_buf, "{d}", .{wh}) catch "24");
        cmdq.cmdq_print(item, "{s}", .{output});
    }
    return .normal;
}

fn replace_placeholder(src: []u8, key: []const u8, val: []const u8) []u8 {
    const idx = std.mem.indexOf(u8, src, key) orelse return src;
    const new_len = src.len - key.len + val.len;
    var result = xm.allocator.alloc(u8, new_len) catch unreachable;
    @memcpy(result[0..idx], src[0..idx]);
    @memcpy(result[idx..idx + val.len], val);
    @memcpy(result[idx + val.len ..], src[idx + key.len ..]);
    xm.allocator.free(src);
    return result;
}

pub const entry: cmd_mod.CmdEntry = .{
    .name = "list-sessions",
    .alias = "ls",
    .template = "F:",
    .lower = 0,
    .upper = 0,
    .flags = 0,
    .exec = exec,
};
