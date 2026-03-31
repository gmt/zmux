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
const client_registry = @import("client-registry.zig");
const cmd_mod = @import("cmd.zig");
const cmdq = @import("cmd-queue.zig");
const format_mod = @import("format.zig");
const job_mod = @import("job.zig");
const server = @import("server.zig");
const tty_features = @import("tty-features.zig");
const tty_term = @import("tty-term.zig");

const SHOW_MESSAGES_TEMPLATE = "#{t/p:message_time}: #{message_text}";

fn exec(cmd: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {
    const args = cmd_mod.cmd_get_args(cmd);
    if (args.has('J') or args.has('T')) {
        var out: std.ArrayList(u8) = .{};
        defer out.deinit(xm.allocator);

        if (args.has('T')) {
            const rendered = render_terminal_report(xm.allocator, client_registry.clients.items, cmdq.cmdq_get_target_client(item));
            defer xm.allocator.free(rendered);
            if (rendered.len != 0) out.appendSlice(xm.allocator, rendered) catch unreachable;
        }
        if (args.has('J')) {
            const rendered = job_mod.job_render_summary(xm.allocator);
            defer xm.allocator.free(rendered);
            if (rendered.len != 0) {
                if (out.items.len != 0) out.append( xm.allocator, '\n') catch unreachable;
                out.appendSlice(xm.allocator, rendered) catch unreachable;
            }
        }

        if (out.items.len != 0) cmdq.cmdq_print_data(item, out.items);
        return .normal;
    }

    const rendered = render_message_log(xm.allocator, cmdq.cmdq_get_target_client(item) orelse cmdq.cmdq_get_client(item), server.message_log.items);
    defer xm.allocator.free(rendered);
    if (rendered.len != 0) cmdq.cmdq_print_data(item, rendered);
    return .normal;
}

fn render_message_log(alloc: std.mem.Allocator, client: ?*T.Client, entries: []const T.MessageEntry) []u8 {
    var out: std.ArrayList(u8) = .{};
    errdefer out.deinit(alloc);

    var i = entries.len;
    while (i > 0) {
        i -= 1;
        const message = entries[i];
        const line = render_message_line(alloc, client, message);
        defer alloc.free(line);
        out.appendSlice(alloc, line) catch unreachable;
        out.append(alloc, '\n') catch unreachable;
    }

    return out.toOwnedSlice(alloc) catch unreachable;
}

fn render_message_line(alloc: std.mem.Allocator, client: ?*T.Client, message: T.MessageEntry) []u8 {
    const ctx = format_mod.FormatContext{
        .client = client,
        .message_text = message.msg,
        .message_number = message.msg_num,
        .message_time = message.msg_time,
    };
    const expanded = format_mod.format_expand(alloc, SHOW_MESSAGES_TEMPLATE, &ctx);
    if (expanded.complete) return expanded.text;
    defer alloc.free(expanded.text);
    return std.fmt.allocPrint(alloc, "{d}: {s}", .{ message.msg_num, message.msg }) catch unreachable;
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

fn render_terminal_report(alloc: std.mem.Allocator, clients: []const *T.Client, target_client: ?*T.Client) []u8 {
    var out: std.ArrayList(u8) = .{};
    errdefer out.deinit(alloc);

    var terminal_index: usize = 0;
    for (clients) |client| {
        if (target_client) |target| {
            if (client != target) continue;
        }
        if (terminal_index != 0) out.append(alloc, '\n') catch unreachable;
        const effective_features = tty_features.effectiveFeatures(client) orelse client.term_features;
        const feature_names = tty_features.featureString(alloc, effective_features);
        defer alloc.free(feature_names);

        if (feature_names.len != 0) {
            out.writer(alloc).print(
                "Terminal {d}: {s} for {s}, features=0x{x} ({s}):",
                .{
                    terminal_index,
                    client.term_name orelse "unknown",
                    client.name orelse "client",
                    @as(u32, @bitCast(effective_features)),
                    feature_names,
                },
            ) catch unreachable;
        } else {
            out.writer(alloc).print(
                "Terminal {d}: {s} for {s}, features=0x{x}:",
                .{
                    terminal_index,
                    client.term_name orelse "unknown",
                    client.name orelse "client",
                    @as(u32, @bitCast(effective_features)),
                },
            ) catch unreachable;
        }
        out.append(alloc, '\n') catch unreachable;

        if (client.term_caps) |caps| {
            for (caps, 0..) |cap, cap_index| {
                const line = tty_term.describeRecordedCapability(alloc, cap_index, cap);
                defer alloc.free(line);
                out.appendSlice(alloc, line) catch unreachable;
                out.append(alloc, '\n') catch unreachable;
            }
        }
        terminal_index += 1;
    }

    return out.toOwnedSlice(alloc) catch unreachable;
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

test "show-messages renders newest-first message log entries through shared format fields" {
    var messages = [_]T.MessageEntry{
        .{ .msg = try std.testing.allocator.dupe(u8, "older"), .msg_num = 11, .msg_time = local_timestamp(1970, 1, 5, 9, 5, 0) },
        .{ .msg = try std.testing.allocator.dupe(u8, "newer"), .msg_num = 12, .msg_time = local_timestamp(1971, 2, 6, 18, 45, 0) },
    };
    defer {
        for (&messages) |*message| std.testing.allocator.free(message.msg);
    }

    const rendered = render_message_log(xm.allocator, null, &messages);
    defer xm.allocator.free(rendered);

    try std.testing.expectEqualStrings(
        \\Feb71: newer
        \\Jan70: older
        \\
    ,
        rendered,
    );
}

test "show-messages renders reduced terminal capability reports from shared tty-term state" {
    var caps = [_][]u8{
        @constCast("U8=1"),
        @constCast("kmous=\x1b[M"),
        @constCast("tsl=\x1b]0;"),
        @constCast("fsl=\x07"),
    };
    var client = T.Client{
        .name = "tty-client",
        .environ = undefined,
        .tty = undefined,
        .status = .{},
        .term_name = try std.testing.allocator.dupe(u8, "xterm-256color"),
        .term_features = tty_features.featureBit(.bpaste),
        .term_caps = caps[0..],
    };
    defer std.testing.allocator.free(client.term_name.?);
    client.tty = .{ .client = &client };

    const rendered = render_terminal_report(xm.allocator, &.{&client}, null);
    defer xm.allocator.free(rendered);
    try std.testing.expectEqualStrings(
        "Terminal 0: xterm-256color for tty-client, features=0x40402 (bpaste,mouse,title):\n" ++
            "   0: U8: (number) 1\n" ++
            "   1: kmous: (string) \\x1B[M\n" ++
            "   2: tsl: (string) \\x1B]0;\n" ++
            "   3: fsl: (string) \\x07\n",
        rendered,
    );
}

test "show-messages renders reduced shared job summaries" {
    defer job_mod.job_reset_all();

    const job = job_mod.job_register("printf ready", 0);
    job_mod.job_started(job, 99, 5);
    job_mod.job_finished(job, 0);

    const rendered = job_mod.job_render_summary(std.testing.allocator);
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings("Job 0: printf ready [fd=5, pid=99, status=0]", rendered);
}
