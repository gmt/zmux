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
// Ported in part from tmux/cmd-show-messages.c.
// Original copyright:
//   Copyright (c) 2009 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

const std = @import("std");
const c = @import("c.zig");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const cmd_mod = @import("cmd.zig");
const cmdq = @import("cmd-queue.zig");
const server = @import("server.zig");

fn exec(cmd: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {
    const args = cmd_mod.cmd_get_args(cmd);
    if (args.has('J') and args.has('T')) {
        cmdq.cmdq_error(item, "show-messages -J and -T are not supported yet", .{});
        return .@"error";
    }
    if (args.has('J')) {
        cmdq.cmdq_error(item, "show-messages -J is not supported yet", .{});
        return .@"error";
    }
    if (args.has('T')) {
        cmdq.cmdq_error(item, "show-messages -T is not supported yet", .{});
        return .@"error";
    }

    const rendered = render_message_log_at(xm.allocator, server.message_log.items, std.time.timestamp());
    defer xm.allocator.free(rendered);
    if (rendered.len != 0) cmdq.cmdq_print_data(item, rendered);
    return .normal;
}

fn render_message_log_at(alloc: std.mem.Allocator, entries: []const T.MessageEntry, now_seconds: i64) []u8 {
    var out: std.ArrayList(u8) = .{};
    errdefer out.deinit(alloc);

    var i = entries.len;
    while (i > 0) {
        i -= 1;
        const message = entries[i];
        const pretty = format_pretty_time_at(alloc, now_seconds, message.msg_time) orelse
            std.fmt.allocPrint(alloc, "{d}", .{message.msg_time}) catch unreachable;
        defer alloc.free(pretty);
        out.writer(alloc).print("{s}: {s}\n", .{ pretty, message.msg }) catch unreachable;
    }

    return out.toOwnedSlice(alloc) catch unreachable;
}

fn format_pretty_time_at(alloc: std.mem.Allocator, now_seconds: i64, when_seconds: i64) ?[]u8 {
    const effective_now = @max(now_seconds, when_seconds);
    const age = effective_now - when_seconds;

    var now_time: c.posix_sys.time_t = @intCast(effective_now);
    var when_time: c.posix_sys.time_t = @intCast(when_seconds);
    var now_tm: c.posix_sys.struct_tm = undefined;
    var when_tm: c.posix_sys.struct_tm = undefined;

    if (c.posix_sys.localtime_r(&now_time, &now_tm) == null) return null;
    if (c.posix_sys.localtime_r(&when_time, &when_tm) == null) return null;

    const fmt = if (age < 24 * 3600)
        "%H:%M"
    else if ((when_tm.tm_year == now_tm.tm_year and when_tm.tm_mon == now_tm.tm_mon) or age < 28 * 24 * 3600)
        "%a%d"
    else if ((when_tm.tm_year == now_tm.tm_year and when_tm.tm_mon < now_tm.tm_mon) or
        (when_tm.tm_year == now_tm.tm_year - 1 and when_tm.tm_mon > now_tm.tm_mon))
        "%d%b"
    else
        "%h%y";

    return format_strftime_tm(alloc, fmt, &when_tm);
}

fn format_strftime_tm(alloc: std.mem.Allocator, fmt: []const u8, tm_value: *c.posix_sys.struct_tm) ?[]u8 {
    var cap: usize = 16;
    while (cap <= 256) : (cap *= 2) {
        const buf = alloc.alloc(u8, cap) catch unreachable;
        const fmt_z = alloc.dupeZ(u8, fmt) catch unreachable;
        defer alloc.free(fmt_z);
        const written = c.posix_sys.strftime(buf.ptr, cap, fmt_z.ptr, tm_value);
        if (written != 0) {
            const out = alloc.dupe(u8, buf[0..written]) catch unreachable;
            alloc.free(buf);
            return out;
        }
        alloc.free(buf);
    }
    return null;
}

fn local_timestamp(year: c_int, month: c_int, day: c_int, hour: c_int, minute: c_int, second: c_int) i64 {
    var tm_value: c.posix_sys.struct_tm = std.mem.zeroes(c.posix_sys.struct_tm);
    tm_value.tm_year = year - 1900;
    tm_value.tm_mon = month - 1;
    tm_value.tm_mday = day;
    tm_value.tm_hour = hour;
    tm_value.tm_min = minute;
    tm_value.tm_sec = second;
    tm_value.tm_isdst = -1;
    return @intCast(c.posix_sys.mktime(&tm_value));
}

pub const entry: cmd_mod.CmdEntry = .{
    .name = "show-messages",
    .alias = "showmsgs",
    .usage = "[-JT] [-t target-client]",
    .template = "JTt:",
    .lower = 0,
    .upper = 0,
    .flags = T.CMD_AFTERHOOK | T.CMD_CLIENT_TFLAG | T.CMD_CLIENT_CANFAIL,
    .exec = exec,
};

test "show-messages renders newest-first message log entries" {
    const now = local_timestamp(2026, 3, 27, 20, 15, 0);
    var messages = [_]T.MessageEntry{
        .{ .msg = try std.testing.allocator.dupe(u8, "older"), .msg_num = 11, .msg_time = local_timestamp(2026, 3, 27, 9, 5, 0) },
        .{ .msg = try std.testing.allocator.dupe(u8, "newer"), .msg_num = 12, .msg_time = local_timestamp(2026, 3, 27, 18, 45, 0) },
    };
    defer {
        for (&messages) |*message| std.testing.allocator.free(message.msg);
    }

    const rendered = render_message_log_at(std.testing.allocator, &messages, now);
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings(
        \\18:45: newer
        \\09:05: older
        \\
    ,
        rendered,
    );
}

test "show-messages rejects unsupported job and terminal flags" {
    var cause: ?[]u8 = null;
    const show_jobs = try cmd_mod.cmd_parse_one(&.{ "show-messages", "-J" }, null, &cause);
    defer cmd_mod.cmd_free(show_jobs);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.@"error", cmd_mod.cmd_execute(show_jobs, &item));

    const show_terminals = try cmd_mod.cmd_parse_one(&.{ "show-messages", "-T" }, null, &cause);
    defer cmd_mod.cmd_free(show_terminals);
    try std.testing.expectEqual(T.CmdRetval.@"error", cmd_mod.cmd_execute(show_terminals, &item));
}
