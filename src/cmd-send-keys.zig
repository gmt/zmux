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
const client_registry = @import("client-registry.zig");
const input_keys = @import("input-keys.zig");
const key_string = @import("key-string.zig");
const pane_input = @import("pane-input.zig");
const opts = @import("options.zig");
const format_mod = @import("format.zig");
const server_fn = @import("server-fn.zig");
const colour_mod = @import("colour.zig");
const window_mod = @import("window.zig");

fn exec(cmd: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {
    const args = cmd_mod.cmd_get_args(cmd);
    if (args.has('M')) {
        cmdq.cmdq_error(item, "mouse event send-keys not supported yet", .{});
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
    const tc = blk: {
        const found = find_target_client(item, args.get('c'));
        if (found == null and args.has('c')) return .@"error";
        break :blk found;
    };

    if (tc != null and tc.?.flags & T.CLIENT_READONLY != 0 and !args.has('X')) {
        cmdq.cmdq_error(item, "client is read-only", .{});
        return .@"error";
    }

    const ctx = format_mod.FormatContext{
        .item = @ptrCast(item),
        .client = tc orelse cmdq.cmdq_get_client(item),
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
        if (wp.fd < 0) {
            cmdq.cmdq_error(item, "pane is not accepting input", .{});
            return .@"error";
        }
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

    if (args.has('R')) reset_pane(wp);

    if (args.count() == 0) {
        if (args.has('N') or args.has('R')) return .normal;
        const event = cmdq.cmdq_get_event(item);
        if (event.key == T.KEYC_NONE or event.key == T.KEYC_UNKNOWN) {
            cmdq.cmdq_error(item, "send-keys requires a triggering key event when no keys are given", .{});
            return .@"error";
        }

        var replay_count: u32 = repeat;
        while (replay_count > 0) : (replay_count -= 1) {
            if (inject_key(wp, tc, event.key, false, item) != .normal) return .@"error";
        }
        return .normal;
    }

    if (!args.has('K') and wp.fd < 0) {
        cmdq.cmdq_error(item, "pane is not accepting input", .{});
        return .@"error";
    }

    var n = repeat;
    while (n > 0) : (n -= 1) {
        var idx: usize = 0;
        while (idx < args.count()) : (idx += 1) {
            const value = if (expanded_values) |values| values[idx] else args.value_at(idx).?;
            if (args.has('H')) {
                if (inject_hex(wp, tc, value, item) != .normal) return .@"error";
                continue;
            }
            if (inject_string(wp, tc, value, args.has('l'), item) != .normal) return .@"error";
        }
    }
    return .normal;
}

fn find_target_client(item: *cmdq.CmdqItem, explicit: ?[]const u8) ?*T.Client {
    if (explicit == null) return cmdq.cmdq_get_client(item);

    var target = explicit.?;
    if (target.len != 0 and target[target.len - 1] == ':')
        target = target[0 .. target.len - 1];

    for (client_registry.clients.items) |cl| {
        if (cl.session == null) continue;
        if (cl.name) |name| {
            if (std.mem.eql(u8, target, name)) return cl;
        }
        if (cl.ttyname) |ttyname| {
            if (std.mem.eql(u8, target, ttyname)) return cl;
            if (std.mem.startsWith(u8, ttyname, "/dev/") and std.mem.eql(u8, target, ttyname["/dev/".len..]))
                return cl;
        }
    }

    cmdq.cmdq_error(item, "can't find client: {s}", .{target});
    return null;
}

fn reset_pane(wp: *T.WindowPane) void {
    colour_mod.colour_palette_clear(&wp.palette);
    window_mod.window_pane_reset_contents(wp);
    wp.flags |= T.PANE_STYLECHANGED | T.PANE_THEMECHANGED | T.PANE_REDRAW;
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

fn inject_hex(wp: *T.WindowPane, tc: ?*T.Client, text: []const u8, item: *cmdq.CmdqItem) T.CmdRetval {
    const value = std.fmt.parseInt(u8, text, 16) catch {
        cmdq.cmdq_error(item, "invalid hex byte: {s}", .{text});
        return .@"error";
    };
    return inject_key(wp, tc, T.KEYC_LITERAL | value, false, item);
}

fn inject_string(wp: *T.WindowPane, tc: ?*T.Client, value: []const u8, literal: bool, item: *cmdq.CmdqItem) T.CmdRetval {
    var use_literal = literal;
    if (!use_literal) {
        const key = key_string.key_string_lookup_string(value);
        if (key != T.KEYC_UNKNOWN and key != T.KEYC_NONE and key != T.KEYC_ANY)
            return inject_key(wp, tc, key, true, item);
        use_literal = true;
    }

    if (!use_literal) return .normal;

    var index: usize = 0;
    while (index < value.len) {
        const key = next_literal_key(value, &index);
        if (inject_key(wp, tc, key, false, item) != .normal) return .@"error";
    }
    return .normal;
}

fn next_literal_key(value: []const u8, index: *usize) T.key_code {
    const first = value[index.*];
    if (first <= 0x7f) {
        index.* += 1;
        return first;
    }

    const seq_len = std.unicode.utf8ByteSequenceLength(first) catch {
        index.* += 1;
        return first;
    };
    if (index.* + seq_len > value.len) {
        index.* += 1;
        return first;
    }

    const cp = std.unicode.utf8Decode(value[index.* .. index.* + seq_len]) catch {
        index.* += 1;
        return first;
    };
    index.* += seq_len;
    return cp;
}

fn inject_key(wp: *T.WindowPane, tc: ?*T.Client, key: T.key_code, allow_literal_fallback: bool, item: *cmdq.CmdqItem) T.CmdRetval {
    if (tc) |target_client| return dispatch_key(target_client, key, item);
    return send_key(wp, key, allow_literal_fallback, item);
}

fn dispatch_key(tc: *T.Client, key: T.key_code, item: *cmdq.CmdqItem) T.CmdRetval {
    var event = T.key_event{ .key = key | T.KEYC_SENT };
    var buf: [16]u8 = undefined;
    if (input_keys.input_key_encode(key, &buf)) |bytes| {
        event.len = bytes.len;
        @memcpy(event.data[0..bytes.len], bytes);
    } else |_| {
        event.len = 0;
    }

    if (server_fn.server_client_handle_key(tc, &event)) return .normal;
    cmdq.cmdq_error(item, "unsupported key for client dispatch: {s}", .{key_string.key_string_lookup_key(key, 0)});
    return .@"error";
}

fn send_key(wp: *T.WindowPane, key: T.key_code, allow_literal_fallback: bool, item: *cmdq.CmdqItem) T.CmdRetval {
    var buf: [16]u8 = undefined;
    const bytes = input_keys.input_key_encode(key, &buf) catch |err| switch (err) {
        error.UnsupportedKey => {
            if (allow_literal_fallback) {
                const text = key_string.key_string_lookup_key(key, 0);
                pane_input.write_all(wp.fd, text, item) catch return .@"error";
                return .normal;
            }
            cmdq.cmdq_error(item, "unsupported key: {s}", .{key_string.key_string_lookup_key(key, 0)});
            return .@"error";
        },
    };
    pane_input.write_all(wp.fd, bytes, item) catch return .@"error";
    return .normal;
}

pub const entry: cmd_mod.CmdEntry = .{
    .name = "send-keys",
    .alias = "send",
    .usage = "[-FHKlMRX] [-c target-client] [-N repeat-count] [-t target-pane] [key ...]",
    .template = "c:FHKlMN:Rt:X",
    .lower = 0,
    .upper = -1,
    .flags = T.CMD_AFTERHOOK,
    .exec = exec,
};

pub const entry_prefix: cmd_mod.CmdEntry = .{
    .name = "send-prefix",
    .alias = null,
    .usage = "[-2] [-t target-pane]",
    .template = "2t:",
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

test "send-keys -R resets pane state before writing keys" {
    const grid = @import("grid.zig");

    const setup = try test_session_with_empty_pane("send-reset-test");
    const pipe_fds = try std.posix.pipe();
    defer test_teardown_session("send-reset-test", setup.s, pipe_fds[0], -1);

    setup.wp.fd = pipe_fds[1];
    grid.set_ascii(setup.wp.base.grid, 0, 0, 'X');
    try setup.wp.input_pending.appendSlice(xm.allocator, "leftover");
    setup.wp.palette.fg = 2;
    setup.wp.palette.bg = 4;

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "send-keys", "-R", "-t", "send-reset-test:0.0", "Enter" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));

    var buf: [8]u8 = undefined;
    const n = try std.posix.read(pipe_fds[0], &buf);
    try std.testing.expectEqualStrings("\r", buf[0..n]);
    try std.testing.expectEqual(@as(u8, ' '), grid.ascii_at(setup.wp.base.grid, 0, 0));
    try std.testing.expectEqual(@as(usize, 0), setup.wp.input_pending.items.len);
    try std.testing.expectEqual(@as(i32, 8), setup.wp.palette.fg);
    try std.testing.expectEqual(@as(i32, 8), setup.wp.palette.bg);
    try std.testing.expect(setup.wp.flags & T.PANE_REDRAW != 0);
    try std.testing.expect(setup.wp.flags & T.PANE_STYLECHANGED != 0);
    try std.testing.expect(setup.wp.flags & T.PANE_THEMECHANGED != 0);
    std.posix.close(pipe_fds[1]);
    setup.wp.fd = -1;
}

test "send-keys -K dispatches through a named target client key table" {
    const env_mod = @import("environ.zig");
    const sess = @import("session.zig");
    const spawn = @import("spawn.zig");
    const win = @import("window.zig");
    const key_bindings = @import("key-bindings.zig");

    sess.session_init_globals(xm.allocator);
    win.window_init_globals(xm.allocator);
    client_registry.clients.clearRetainingCapacity();
    defer client_registry.clients.clearRetainingCapacity();

    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);

    env_mod.global_environ = env_mod.environ_create();
    defer env_mod.environ_free(env_mod.global_environ);
    key_bindings.key_bindings_init();

    const s = sess.session_create(null, "send-k-client", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("send-k-client") != null) sess.session_destroy(s, false, "test");

    var cause: ?[]u8 = null;
    var sc: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    _ = spawn.spawn_window(&sc, &cause).?;

    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);
    var cl = T.Client{
        .name = xm.xstrdup("remote"),
        .environ = env,
        .tty = undefined,
        .status = .{ .screen = undefined },
        .flags = T.CLIENT_ATTACHED,
        .session = s,
    };
    defer xm.allocator.free(cl.name.?);
    cl.tty.client = &cl;
    client_registry.add(&cl);

    const cmd = try cmd_mod.cmd_parse_one(&.{ "send-keys", "-c", "remote", "-K", "-t", "send-k-client:0.0", "C-b", "c" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));

    _ = cmdq.cmdq_next(&cl);
    try std.testing.expectEqual(@as(usize, 2), s.windows.count());
}

test "send-keys -K forwards unbound keys to the named client pane" {
    const env_mod = @import("environ.zig");
    const sess = @import("session.zig");
    const spawn = @import("spawn.zig");
    const win = @import("window.zig");
    const key_bindings = @import("key-bindings.zig");

    sess.session_init_globals(xm.allocator);
    win.window_init_globals(xm.allocator);
    client_registry.clients.clearRetainingCapacity();
    defer client_registry.clients.clearRetainingCapacity();

    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);

    env_mod.global_environ = env_mod.environ_create();
    defer env_mod.environ_free(env_mod.global_environ);
    key_bindings.key_bindings_init();

    const s = sess.session_create(null, "send-k-forward", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("send-k-forward") != null) sess.session_destroy(s, false, "test");

    var cause: ?[]u8 = null;
    var sc: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const wl = spawn.spawn_window(&sc, &cause).?;
    const wp = wl.window.active.?;

    const pipe_fds = try std.posix.pipe();
    defer std.posix.close(pipe_fds[0]);
    wp.fd = pipe_fds[1];
    defer {
        if (wp.fd >= 0) std.posix.close(wp.fd);
        wp.fd = -1;
    }

    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);
    var cl = T.Client{
        .name = xm.xstrdup("named-client"),
        .environ = env,
        .tty = undefined,
        .status = .{ .screen = undefined },
        .flags = T.CLIENT_ATTACHED,
        .session = s,
    };
    defer xm.allocator.free(cl.name.?);
    cl.tty.client = &cl;
    client_registry.add(&cl);

    const cmd = try cmd_mod.cmd_parse_one(&.{ "send-keys", "-c", "named-client", "-K", "-t", "send-k-forward:0.0", "x" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));

    var buf: [8]u8 = undefined;
    const n = try std.posix.read(pipe_fds[0], &buf);
    try std.testing.expectEqualStrings("x", buf[0..n]);
}

test "send-keys rejects an unknown target client" {
    const setup = try test_session_with_empty_pane("send-missing-client");
    defer test_teardown_session("send-missing-client", setup.s, -1, -1);
    client_registry.clients.clearRetainingCapacity();
    defer client_registry.clients.clearRetainingCapacity();

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "send-keys", "-c", "ghost", "-t", "send-missing-client:0.0", "x" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.@"error", cmd_mod.cmd_execute(cmd, &item));
}

test "send-keys replays the triggering key when no arguments are given" {
    const setup = try test_session_with_empty_pane("send-replay-test");
    const pipe_fds = try std.posix.pipe();
    defer test_teardown_session("send-replay-test", setup.s, pipe_fds[0], -1);

    setup.wp.fd = pipe_fds[1];

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "send-keys", "-t", "send-replay-test:0.0" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{
        .client = null,
        .cmdlist = &list,
        .event = .{ .key = 'x', .len = 1 },
    };
    item.event.data[0] = 'x';

    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));

    var poll_fds = [_]std.posix.pollfd{.{
        .fd = pipe_fds[0],
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    try std.testing.expectEqual(@as(usize, 1), try std.posix.poll(&poll_fds, 100));

    var buf: [8]u8 = undefined;
    const n = try std.posix.read(pipe_fds[0], &buf);
    try std.testing.expectEqualStrings("x", buf[0..n]);
    std.posix.close(pipe_fds[1]);
    setup.wp.fd = -1;
}
