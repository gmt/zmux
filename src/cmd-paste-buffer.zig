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
// Ported in part from tmux/cmd-paste-buffer.c.
// Original copyright:
//   Copyright (c) 2007 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const cmd_mod = @import("cmd.zig");
const cmdq = @import("cmd-queue.zig");
const cmd_find = @import("cmd-find.zig");
const pane_input = @import("pane-input.zig");
const paste_mod = @import("paste.zig");
const screen_mod = @import("screen.zig");
const utf8_mod = @import("utf8.zig");

fn exec(cmd: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {
    const args = cmd_mod.cmd_get_args(cmd);

    var target: T.CmdFindState = .{};
    if (cmd_find.cmd_find_target(&target, item, args.get('t'), .pane, 0) != 0)
        return .@"error";
    const wp = target.wp orelse return .@"error";

    if (wp.fd < 0 or (wp.flags & T.PANE_EXITED) != 0) {
        cmdq.cmdq_error(item, "target pane has exited", .{});
        return .@"error";
    }

    const bufname = args.get('b');
    const pb = if (bufname) |name|
        paste_mod.paste_get_name(name)
    else
        paste_mod.paste_get_top(null);

    if (bufname != null and pb == null) {
        cmdq.cmdq_error(item, "no buffer {s}", .{bufname.?});
        return .@"error";
    }

    if (pb != null and (wp.flags & T.PANE_INPUTOFF) == 0) {
        const separator = resolve_separator(args);
        if (args.has('p') and screen_mod.screen_current(wp).bracketed_paste) {
            pane_input.write_all(wp.fd, "\x1b[200~", item) catch return .@"error";
        }

        const bufdata = paste_mod.paste_buffer_data(pb.?, null);
        if (args.has('S')) {
            paste_raw(wp.fd, bufdata, separator, item) catch return .@"error";
        } else {
            paste_escaped(wp.fd, bufdata, separator, item) catch return .@"error";
        }

        if (args.has('p') and screen_mod.screen_current(wp).bracketed_paste) {
            pane_input.write_all(wp.fd, "\x1b[201~", item) catch return .@"error";
        }
    }

    if (pb != null and args.has('d'))
        paste_mod.paste_free(pb.?);

    return .normal;
}

fn resolve_separator(args: *const @import("arguments.zig").Arguments) []const u8 {
    if (args.get('s')) |separator| return separator;
    if (args.has('r')) return "\n";
    return "\r";
}

fn paste_raw(fd: i32, data: []const u8, separator: []const u8, item: *cmdq.CmdqItem) !void {
    var start: usize = 0;
    while (start < data.len) {
        const newline_offset = std.mem.indexOfScalarPos(u8, data, start, '\n');
        if (newline_offset) |line_end| {
            try pane_input.write_all(fd, data[start..line_end], item);
            try pane_input.write_all(fd, separator, item);
            start = line_end + 1;
            continue;
        }
        try pane_input.write_all(fd, data[start..], item);
        return;
    }
}

fn paste_escaped(fd: i32, data: []const u8, separator: []const u8, item: *cmdq.CmdqItem) !void {
    var start: usize = 0;
    while (start < data.len) {
        const newline_offset = std.mem.indexOfScalarPos(u8, data, start, '\n');
        if (newline_offset) |line_end| {
            const escaped = try escape_for_paste(data[start..line_end]);
            defer xm.allocator.free(escaped);
            try pane_input.write_all(fd, escaped, item);
            try pane_input.write_all(fd, separator, item);
            start = line_end + 1;
            continue;
        }
        const escaped = try escape_for_paste(data[start..]);
        defer xm.allocator.free(escaped);
        try pane_input.write_all(fd, escaped, item);
        return;
    }
}

fn escape_for_paste(data: []const u8) ![]u8 {
    return utf8_mod.utf8_stravisx(data, utf8_mod.VIS_SAFE | utf8_mod.VIS_NOSLASH);
}

pub const entry: cmd_mod.CmdEntry = .{
    .name = "paste-buffer",
    .alias = "pasteb",
    .usage = "[-dprS] [-s separator] [-b buffer-name] [-t target-pane]",
    .template = "db:prSs:t:",
    .lower = 0,
    .upper = 0,
    .flags = T.CMD_AFTERHOOK,
    .exec = exec,
};

fn test_session_with_empty_pane(name: []const u8) !struct { s: *T.Session, wp: *T.WindowPane } {
    const env_mod = @import("environ.zig");
    const opts = @import("options.zig");
    const sess = @import("session.zig");
    const spawn = @import("spawn.zig");
    const win = @import("window.zig");

    paste_mod.paste_reset_for_tests();
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
    const opts = @import("options.zig");
    const sess = @import("session.zig");

    if (fd_read >= 0) std.posix.close(fd_read);
    if (fd_write >= 0) std.posix.close(fd_write);
    if (sess.session_find(name) != null) sess.session_destroy(s, false, "test");
    env_mod.environ_free(env_mod.global_environ);
    opts.options_free(opts.global_w_options);
    opts.options_free(opts.global_s_options);
    opts.options_free(opts.global_options);
    paste_mod.paste_reset_for_tests();
}

test "paste-buffer writes raw bytes with a custom separator" {
    const setup = try test_session_with_empty_pane("paste-buffer-raw");
    const pipe_fds = try std.posix.pipe();
    defer test_teardown_session("paste-buffer-raw", setup.s, pipe_fds[0], -1);

    setup.wp.fd = pipe_fds[1];
    var cause: ?[]u8 = null;
    try std.testing.expectEqual(@as(i32, 0), paste_mod.paste_set(xm.xstrdup("one\ntwo"), "named", &cause));

    const cmd = try cmd_mod.cmd_parse_one(&.{ "paste-buffer", "-S", "-s", "|", "-b", "named", "-t", "paste-buffer-raw:0.0" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));

    var buf: [32]u8 = undefined;
    const n = try std.posix.read(pipe_fds[0], &buf);
    try std.testing.expectEqualStrings("one|two", buf[0..n]);
    std.posix.close(pipe_fds[1]);
    setup.wp.fd = -1;
}

test "paste-buffer uses the most recent automatic buffer by default" {
    const setup = try test_session_with_empty_pane("paste-buffer-top");
    const pipe_fds = try std.posix.pipe();
    defer test_teardown_session("paste-buffer-top", setup.s, pipe_fds[0], -1);

    setup.wp.fd = pipe_fds[1];
    var cause: ?[]u8 = null;
    try std.testing.expectEqual(@as(i32, 0), paste_mod.paste_set(xm.xstrdup("top\nbuffer"), null, &cause));

    const cmd = try cmd_mod.cmd_parse_one(&.{ "paste-buffer", "-S", "-t", "paste-buffer-top:0.0" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));

    var buf: [32]u8 = undefined;
    const n = try std.posix.read(pipe_fds[0], &buf);
    try std.testing.expectEqualStrings("top\rbuffer", buf[0..n]);
    std.posix.close(pipe_fds[1]);
    setup.wp.fd = -1;
}

test "paste-buffer escapes invalid bytes and wraps bracketed paste when requested" {
    const setup = try test_session_with_empty_pane("paste-buffer-bracket");
    const pipe_fds = try std.posix.pipe();
    defer test_teardown_session("paste-buffer-bracket", setup.s, pipe_fds[0], -1);

    setup.wp.fd = pipe_fds[1];
    screen_mod.screen_current(setup.wp).bracketed_paste = true;

    var cause: ?[]u8 = null;
    const data = try xm.allocator.dupe(u8, "A\nB\r\x00\xC3\xA9");
    try std.testing.expectEqual(@as(i32, 0), paste_mod.paste_set(data, "named", &cause));

    const cmd = try cmd_mod.cmd_parse_one(&.{ "paste-buffer", "-p", "-b", "named", "-t", "paste-buffer-bracket:0.0" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));

    var buf: [64]u8 = undefined;
    const n = try std.posix.read(pipe_fds[0], &buf);
    try std.testing.expectEqualSlices(u8, "\x1b[200~A\rB\r^@\xC3\xA9\x1b[201~", buf[0..n]);
    std.posix.close(pipe_fds[1]);
    setup.wp.fd = -1;
}

test "paste-buffer deletes a named buffer even when pane input is disabled" {
    const setup = try test_session_with_empty_pane("paste-buffer-delete");
    const pipe_fds = try std.posix.pipe();
    defer test_teardown_session("paste-buffer-delete", setup.s, pipe_fds[0], -1);

    setup.wp.fd = pipe_fds[1];
    setup.wp.flags |= T.PANE_INPUTOFF;

    var cause: ?[]u8 = null;
    try std.testing.expectEqual(@as(i32, 0), paste_mod.paste_set(xm.xstrdup("hidden"), "named", &cause));

    const cmd = try cmd_mod.cmd_parse_one(&.{ "paste-buffer", "-d", "-b", "named", "-t", "paste-buffer-delete:0.0" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));
    try std.testing.expect(paste_mod.paste_get_name("named") == null);

    std.posix.close(pipe_fds[1]);
    setup.wp.fd = -1;

    var buf: [8]u8 = undefined;
    const n = try std.posix.read(pipe_fds[0], &buf);
    try std.testing.expectEqual(@as(usize, 0), n);
}

test "paste-buffer errors when the target pane has exited" {
    const setup = try test_session_with_empty_pane("paste-buffer-exited");
    defer test_teardown_session("paste-buffer-exited", setup.s, -1, -1);

    var cause: ?[]u8 = null;
    try std.testing.expectEqual(@as(i32, 0), paste_mod.paste_set(xm.xstrdup("named"), "named", &cause));

    const cmd = try cmd_mod.cmd_parse_one(&.{ "paste-buffer", "-b", "named", "-t", "paste-buffer-exited:0.0" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.@"error", cmd_mod.cmd_execute(cmd, &item));
}

test "paste-buffer errors when a named buffer does not exist" {
    const setup = try test_session_with_empty_pane("paste-buffer-missing");
    defer test_teardown_session("paste-buffer-missing", setup.s, -1, -1);

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "paste-buffer", "-b", "missing", "-t", "paste-buffer-missing:0.0" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.@"error", cmd_mod.cmd_execute(cmd, &item));
}
