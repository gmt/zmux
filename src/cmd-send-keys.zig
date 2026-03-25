// Copyright (c) 2026 Greg Turner <gmt@pobox.com>
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
// Ported in part from tmux/cmd-send-keys.c.
// Original copyright:
//   Copyright (c) 2008 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const cmd_mod = @import("cmd.zig");
const cmd_format = @import("cmd-format.zig");
const cmdq = @import("cmd-queue.zig");
const cmd_find = @import("cmd-find.zig");
const input_keys = @import("input-keys.zig");
const key_string = @import("key-string.zig");
const opts = @import("options.zig");
const format_mod = @import("format.zig");

fn exec(cmd: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {
    const args = cmd_mod.cmd_get_args(cmd);
    if (args.has('c')) {
        cmdq.cmdq_error(item, "target client selection not supported yet", .{});
        return .@"error";
    }
    if (args.has('K')) {
        cmdq.cmdq_error(item, "key-table dispatch send-keys not supported yet", .{});
        return .@"error";
    }
    if (args.has('M')) {
        cmdq.cmdq_error(item, "mouse event send-keys not supported yet", .{});
        return .@"error";
    }
    if (args.has('R')) {
        cmdq.cmdq_error(item, "terminal reset send-keys not supported yet", .{});
        return .@"error";
    }
    if (args.has('X')) {
        cmdq.cmdq_error(item, "mode-command send-keys not supported yet", .{});
        return .@"error";
    }

    var target: T.CmdFindState = .{};
    if (cmd_find.cmd_find_target(&target, item, args.get('t'), .pane, 0) != 0)
        return .@"error";
    const s = target.s orelse return .@"error";
    const wl = target.wl orelse return .@"error";
    const wp = target.wp orelse return .@"error";
    if (wp.fd < 0) {
        cmdq.cmdq_error(item, "pane is not accepting input", .{});
        return .@"error";
    }

    const ctx = format_mod.FormatContext{
        .item = @ptrCast(item),
        .client = cmdq.cmdq_get_client(item),
        .session = s,
        .winlink = wl,
        .window = wl.window,
        .pane = wp,
    };
    const expanded_values = if (args.has('F'))
        expand_values(args, &ctx, item) orelse return .@"error"
    else
        null;
    defer if (expanded_values) |values| free_expanded_values(values);

    const repeat = parse_repeat_count(args.get('N'), item) orelse return .@"error";

    if (cmd.entry == &entry_prefix) {
        const name = if (args.has('2')) "prefix2" else "prefix";
        const prefix_text = opts.options_get_string(s.options, name);
        if (prefix_text.len == 0) return .normal;
        const key = key_string.key_string_lookup_string(prefix_text);
        if (key == T.KEYC_UNKNOWN or key == T.KEYC_NONE) {
            cmdq.cmdq_error(item, "invalid {s} option: {s}", .{ name, prefix_text });
            return .@"error";
        }
        var n = repeat;
        while (n > 0) : (n -= 1) {
            if (send_key(wp, key, false, item) != .normal) return .@"error";
        }
        return .normal;
    }

    if (args.count() == 0) {
        cmdq.cmdq_error(item, "implicit key replay not supported yet", .{});
        return .@"error";
    }

    var n = repeat;
    while (n > 0) : (n -= 1) {
        var idx: usize = 0;
        while (idx < args.count()) : (idx += 1) {
            const value = if (expanded_values) |values| values[idx] else args.value_at(idx).?;
            if (args.has('H')) {
                if (send_hex_byte(wp, value, item) != .normal) return .@"error";
                continue;
            }
            if (send_arg(wp, value, args.has('l'), item) != .normal) return .@"error";
        }
    }
    return .normal;
}

fn expand_values(args: *const @import("arguments.zig").Arguments, ctx: *const format_mod.FormatContext, item: *cmdq.CmdqItem) ?[][]u8 {
    const values = xm.allocator.alloc([]u8, args.count()) catch unreachable;
    for (0..args.count()) |idx| {
        values[idx] = cmd_format.require(item, args.value_at(idx).?, ctx) orelse {
            for (values[0..idx]) |expanded| xm.allocator.free(expanded);
            xm.allocator.free(values);
            return null;
        };
    }
    return values;
}

fn free_expanded_values(values: [][]u8) void {
    for (values) |value| xm.allocator.free(value);
    xm.allocator.free(values);
}

fn parse_repeat_count(raw: ?[]const u8, item: *cmdq.CmdqItem) ?u32 {
    const text = raw orelse return 1;
    const parsed = std.fmt.parseInt(u32, text, 10) catch {
        cmdq.cmdq_error(item, "repeat count invalid: {s}", .{text});
        return null;
    };
    if (parsed == 0) {
        cmdq.cmdq_error(item, "repeat count invalid: {s}", .{text});
        return null;
    }
    return parsed;
}

fn send_hex_byte(wp: *T.WindowPane, text: []const u8, item: *cmdq.CmdqItem) T.CmdRetval {
    const value = std.fmt.parseInt(u8, text, 16) catch {
        cmdq.cmdq_error(item, "invalid hex byte: {s}", .{text});
        return .@"error";
    };
    write_all(wp.fd, &.{value}, item) catch return .@"error";
    return .normal;
}

fn send_arg(wp: *T.WindowPane, value: []const u8, literal: bool, item: *cmdq.CmdqItem) T.CmdRetval {
    if (literal) {
        write_all(wp.fd, value, item) catch return .@"error";
        return .normal;
    }

    const key = key_string.key_string_lookup_string(value);
    if (key != T.KEYC_UNKNOWN and key != T.KEYC_NONE and key != T.KEYC_ANY) {
        return send_key(wp, key, true, item);
    }

    write_all(wp.fd, value, item) catch return .@"error";
    return .normal;
}

fn send_key(wp: *T.WindowPane, key: T.key_code, allow_literal_fallback: bool, item: *cmdq.CmdqItem) T.CmdRetval {
    var buf: [16]u8 = undefined;
    const bytes = input_keys.input_key_encode(key, &buf) catch |err| switch (err) {
        error.UnsupportedKey => {
            if (allow_literal_fallback) {
                const text = key_string.key_string_lookup_key(key, 0);
                write_all(wp.fd, text, item) catch return .@"error";
                return .normal;
            }
            cmdq.cmdq_error(item, "unsupported key: {s}", .{key_string.key_string_lookup_key(key, 0)});
            return .@"error";
        },
    };
    write_all(wp.fd, bytes, item) catch return .@"error";
    return .normal;
}

fn write_all(fd: i32, bytes: []const u8, item: *cmdq.CmdqItem) !void {
    var rest = bytes;
    while (rest.len > 0) {
        const written = std.posix.write(fd, rest) catch |err| {
            switch (err) {
                error.WouldBlock => cmdq.cmdq_error(item, "pane input would block", .{}),
                else => cmdq.cmdq_error(item, "pane input failed", .{}),
            }
            return err;
        };
        if (written == 0) {
            cmdq.cmdq_error(item, "pane input closed", .{});
            return error.BrokenPipe;
        }
        rest = rest[written..];
    }
}

pub const entry: cmd_mod.CmdEntry = .{
    .name = "send-keys",
    .alias = "send",
    .usage = "[-Hl] [-N repeat-count] [-t target-pane] key ...",
    .template = "c:FHKlMN:Rt:X",
    .lower = 0,
    .upper = -1,
    .flags = T.CMD_AFTERHOOK,
    .exec = exec,
};

pub const entry_prefix: cmd_mod.CmdEntry = .{
    .name = "send-prefix",
    .alias = null,
    .usage = "[-2] [-N repeat-count] [-t target-pane]",
    .template = "2N:t:",
    .lower = 0,
    .upper = 0,
    .flags = T.CMD_AFTERHOOK,
    .exec = exec,
};

fn test_session_with_empty_pane(name: []const u8) !struct { s: *T.Session, wp: *T.WindowPane } {
    const env_mod = @import("environ.zig");
    const sess = @import("session.zig");
    const spawn = @import("spawn.zig");
    const win = @import("window.zig");

    sess.session_init_globals(xm.allocator);
    win.window_init_globals(xm.allocator);

    opts.global_options = opts.options_create(null);
    opts.global_s_options = opts.options_create(null);
    opts.global_w_options = opts.options_create(null);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);

    env_mod.global_environ = env_mod.environ_create();

    const s = sess.session_create(null, name, "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    var cause: ?[]u8 = null;
    var sc: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const wl = spawn.spawn_window(&sc, &cause).?;
    s.curw = wl;
    return .{ .s = s, .wp = wl.window.active.? };
}

fn test_teardown_session(name: []const u8, s: *T.Session, fd_read: i32, fd_write: i32) void {
    const env_mod = @import("environ.zig");
    const sess = @import("session.zig");

    if (fd_read >= 0) std.posix.close(fd_read);
    if (fd_write >= 0) std.posix.close(fd_write);
    if (sess.session_find(name) != null) sess.session_destroy(s, false, "test");
    env_mod.environ_free(env_mod.global_environ);
    opts.options_free(opts.global_w_options);
    opts.options_free(opts.global_s_options);
    opts.options_free(opts.global_options);
}

test "send-keys writes literal text and enter to pane fd" {
    const setup = try test_session_with_empty_pane("send-keys-test");
    const pipe_fds = try std.posix.pipe();
    defer test_teardown_session("send-keys-test", setup.s, pipe_fds[0], -1);

    setup.wp.fd = pipe_fds[1];

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "send-keys", "-t", "send-keys-test:0.0", "printf hi", "Enter" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));

    var buf: [64]u8 = undefined;
    const n = try std.posix.read(pipe_fds[0], &buf);
    try std.testing.expectEqualStrings("printf hi\r", buf[0..n]);
    std.posix.close(pipe_fds[1]);
    setup.wp.fd = -1;
}

test "send-prefix uses session prefix option bytes" {
    const setup = try test_session_with_empty_pane("send-prefix-test");
    const pipe_fds = try std.posix.pipe();
    defer test_teardown_session("send-prefix-test", setup.s, pipe_fds[0], -1);

    setup.wp.fd = pipe_fds[1];
    opts.options_set_string(setup.s.options, false, "prefix", "C-a");

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "send-prefix", "-t", "send-prefix-test:0.0" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));

    var buf: [8]u8 = undefined;
    const n = try std.posix.read(pipe_fds[0], &buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u8, 0x01), buf[0]);
    std.posix.close(pipe_fds[1]);
    setup.wp.fd = -1;
}

test "send-keys supports hex mode and repeat counts" {
    const setup = try test_session_with_empty_pane("send-hex-test");
    const pipe_fds = try std.posix.pipe();
    defer test_teardown_session("send-hex-test", setup.s, pipe_fds[0], -1);

    setup.wp.fd = pipe_fds[1];

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "send-keys", "-N", "2", "-H", "-t", "send-hex-test:0.0", "41", "0d" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));

    var buf: [16]u8 = undefined;
    const n = try std.posix.read(pipe_fds[0], &buf);
    try std.testing.expectEqualStrings("A\rA\r", buf[0..n]);
    std.posix.close(pipe_fds[1]);
    setup.wp.fd = -1;
}

test "send-keys expands formats before writing" {
    const setup = try test_session_with_empty_pane("send-format-test");
    const pipe_fds = try std.posix.pipe();
    defer test_teardown_session("send-format-test", setup.s, pipe_fds[0], -1);

    setup.wp.fd = pipe_fds[1];
    setup.wp.screen.title = xm.xstrdup("logs");

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "send-keys", "-F", "-t", "send-format-test:0.0", "#{session_name}:#{pane_title}", "Enter" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));

    var buf: [64]u8 = undefined;
    const n = try std.posix.read(pipe_fds[0], &buf);
    try std.testing.expectEqualStrings("send-format-test:logs\r", buf[0..n]);
    std.posix.close(pipe_fds[1]);
    setup.wp.fd = -1;
}
