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
// Ported in part from tmux/cmd-display-message.c.
// Original copyright:
//   Copyright (c) 2009 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const cmd_mod = @import("cmd.zig");
const cmdq = @import("cmd-queue.zig");
const cmd_find = @import("cmd-find.zig");
const sess = @import("session.zig");
const win_mod = @import("window.zig");

/// Minimal format expansion: replaces known #{...} placeholders.
pub fn expand_format(alloc: std.mem.Allocator, fmt: []const u8, target: *const T.CmdFindState) []u8 {
    var result = alloc.dupe(u8, fmt) catch unreachable;
    result = subst(alloc, result, "#{window_width}", blk: {
        if (target.w) |w| break :blk std.fmt.allocPrint(alloc, "{d}", .{w.sx}) catch unreachable;
        break :blk alloc.dupe(u8, "80") catch unreachable;
    });
    result = subst(alloc, result, "#{window_height}", blk: {
        if (target.w) |w| break :blk std.fmt.allocPrint(alloc, "{d}", .{w.sy}) catch unreachable;
        break :blk alloc.dupe(u8, "24") catch unreachable;
    });
    result = subst(alloc, result, "#{window_index}", blk: {
        if (target.wl) |wl| break :blk std.fmt.allocPrint(alloc, "{d}", .{wl.idx}) catch unreachable;
        break :blk alloc.dupe(u8, "0") catch unreachable;
    });
    result = subst(alloc, result, "#{session_name}", blk: {
        if (target.s) |s| break :blk alloc.dupe(u8, s.name) catch unreachable;
        break :blk alloc.dupe(u8, "") catch unreachable;
    });
    result = subst(alloc, result, "#{pane_pid}", blk: {
        if (target.wp) |wp| break :blk std.fmt.allocPrint(alloc, "{d}", .{wp.pid}) catch unreachable;
        break :blk alloc.dupe(u8, "0") catch unreachable;
    });
    result = subst(alloc, result, "#{pane_width}", blk: {
        if (target.wp) |wp| break :blk std.fmt.allocPrint(alloc, "{d}", .{wp.sx}) catch unreachable;
        break :blk alloc.dupe(u8, "0") catch unreachable;
    });
    result = subst(alloc, result, "#{pane_height}", blk: {
        if (target.wp) |wp| break :blk std.fmt.allocPrint(alloc, "{d}", .{wp.sy}) catch unreachable;
        break :blk alloc.dupe(u8, "0") catch unreachable;
    });
    result = subst(alloc, result, "#{pane_index}", blk: {
        if (target.w) |w| {
            if (target.wp) |wp| {
                for (w.panes.items, 0..) |pane, idx| {
                    if (pane == wp) break :blk std.fmt.allocPrint(alloc, "{d}", .{idx}) catch unreachable;
                }
            }
        }
        break :blk alloc.dupe(u8, "0") catch unreachable;
    });
    result = subst(alloc, result, "#{pane_title}", blk: {
        if (target.wp) |wp| {
            if (wp.screen.title) |title| break :blk alloc.dupe(u8, title) catch unreachable;
        }
        break :blk alloc.dupe(u8, "") catch unreachable;
    });
    result = subst(alloc, result, "#{window_name}", blk: {
        if (target.w) |w| break :blk alloc.dupe(u8, w.name) catch unreachable;
        break :blk alloc.dupe(u8, "") catch unreachable;
    });
    return result;
}

fn subst(alloc: std.mem.Allocator, src: []u8, key: []const u8, val: []u8) []u8 {
    defer alloc.free(val);
    const idx = std.mem.indexOf(u8, src, key) orelse {
        return src;
    };
    const new_len = src.len - key.len + val.len;
    var out = alloc.alloc(u8, new_len) catch unreachable;
    @memcpy(out[0..idx], src[0..idx]);
    @memcpy(out[idx..idx + val.len], val);
    @memcpy(out[idx + val.len ..], src[idx + key.len ..]);
    alloc.free(src);
    return out;
}

fn exec(cmd: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {
    const args = cmd_mod.cmd_get_args(cmd);
    var target: T.CmdFindState = .{};
    _ = cmd_find.cmd_find_target(&target, item, args.get('t'), .pane, T.CMD_FIND_CANFAIL);

    const print_flag = args.has('p');
    const fmt = args.get(0) orelse args.value_at(0) orelse "#{message_text}";

    const expanded = expand_format(xm.allocator, fmt, &target);
    defer xm.allocator.free(expanded);

    if (print_flag) {
        cmdq.cmdq_print(item, "{s}", .{expanded});
    } else {
        // display as message (for now just print)
        cmdq.cmdq_print(item, "{s}", .{expanded});
    }
    return .normal;
}

pub const entry: cmd_mod.CmdEntry = .{
    .name = "display-message",
    .alias = "display",
    .usage = "[-aCIlNpv] [-c target-client] [-d delay] [-F format] [-t target-pane] [message]",
    .template = "ac:d:F:INpPRt:v",
    .lower = 0,
    .upper = 1,
    .flags = T.CMD_READONLY,
    .exec = exec,
};
