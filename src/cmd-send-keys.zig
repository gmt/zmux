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
const args_mod = @import("arguments.zig");
const cmd_mod = @import("cmd.zig");
const cmd_format = @import("cmd-format.zig");
const cmdq = @import("cmd-queue.zig");
const cmd_find = @import("cmd-find.zig");
const client_registry = @import("client-registry.zig");
const input_keys = @import("input-keys.zig");
const key_bindings = @import("key-bindings.zig");
const key_string = @import("key-string.zig");
const pane_input = @import("pane-input.zig");
const opts = @import("options.zig");
const format_mod = @import("format.zig");
const screen_mod = @import("screen.zig");
const server_fn = @import("server-fn.zig");
const session_mod = @import("session.zig");
const colour_mod = @import("colour.zig");
const mouse_runtime = @import("mouse-runtime.zig");
const window_mod = @import("window.zig");

fn exec(cmd: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {
    const args = cmd_mod.cmd_get_args(cmd);

    var target: T.CmdFindState = .{};
    if (cmd_find.cmd_find_target(&target, item, args.get('t'), .pane, 0) != 0)
        return .@"error";
    const s = target.s orelse return .@"error";
    const wl = target.wl orelse return .@"error";
    const wp = target.wp orelse return .@"error";
    const wme = window_mod.window_pane_mode(wp);
    const tc = cmdq.cmdq_get_target_client(item);

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
    const repeat = parse_repeat_count(args.get('N'), &ctx, item) orelse return .@"error";
    if (args.has('N') and wme != null and (args.has('X') or args.count() == 0)) {
        if (wme.?.mode.command == null) {
            cmdq.cmdq_error(item, "not in a mode", .{});
            return .@"error";
        }
        wme.?.prefix = repeat;
    }

    if (cmd.entry == &entry_prefix) {
        const name = if (args.has('2')) "prefix2" else "prefix";
        const prefix_text = opts.options_get_string(s.options, name);
        if (prefix_text.len == 0) return .normal;
        const key = key_string.key_string_lookup_string(prefix_text);
        if (key == T.KEYC_UNKNOWN or key == T.KEYC_NONE) {
            cmdq.cmdq_error(item, "invalid {s} option: {s}", .{ name, prefix_text });
            return .@"error";
        }
        var after: ?*cmdq.CmdqItem = item;
        var n = repeat;
        while (n > 0) : (n -= 1) {
            if (inject_key(s, wl, wp, tc, key, false, false, item, &target, &after) != .normal) return .@"error";
        }
        return .normal;
    }

    if (args.has('X')) {
        if (wme == null or wme.?.mode.command == null) {
            cmdq.cmdq_error(item, "not in a mode", .{});
            return .@"error";
        }
        const event = cmdq.cmdq_get_event(item);
        const mouse: ?*const T.MouseEvent = if (event.m.valid) &event.m else null;
        wme.?.mode.command.?(wme.?, tc, s, wl, @ptrCast(args), mouse);
        return .normal;
    }

    if (args.has('M')) return inject_mouse(item, s, wl, tc);

    const expanded_values = if (args.has('F'))
        expand_values(args, &ctx, item) orelse return .@"error"
    else
        null;
    defer if (expanded_values) |values| free_expanded_values(values);

    if (args.has('R')) reset_pane(wp);

    if (args.count() == 0) {
        if (args.has('N') or args.has('R')) return .normal;
        const event = cmdq.cmdq_get_event(item);
        if (event.key == T.KEYC_NONE or event.key == T.KEYC_UNKNOWN) return .normal;

        var after: ?*cmdq.CmdqItem = null;
        var replay_count: u32 = repeat;
        while (replay_count > 0) : (replay_count -= 1) {
            if (inject_key(s, wl, wp, tc, event.key, false, args.has('K'), item, &target, &after) != .normal)
                return .@"error";
        }
        return .normal;
    }

    var after: ?*cmdq.CmdqItem = item;
    var n = repeat;
    while (n > 0) : (n -= 1) {
        var idx: usize = 0;
        while (idx < args.count()) : (idx += 1) {
            const value = if (expanded_values) |values| values[idx] else args.value_at(idx).?;
            if (args.has('H')) {
                if (inject_hex(s, wl, wp, tc, value, args.has('K'), item, &target, &after) != .normal)
                    return .@"error";
                continue;
            }
            if (inject_string(s, wl, wp, tc, value, args.has('l'), args.has('K'), item, &target, &after) != .normal)
                return .@"error";
        }
    }
    return .normal;
}

const MouseTarget = struct {
    s: *T.Session,
    wl: *T.Winlink,
    wp: *T.WindowPane,
};

fn inject_mouse(item: *cmdq.CmdqItem, default_session: *T.Session, default_wl: *T.Winlink, tc: ?*T.Client) T.CmdRetval {
    const event = cmdq.cmdq_get_event(item);
    const target = resolve_mouse_target(&event.m, default_session, default_wl) orelse {
        cmdq.cmdq_error(item, "no mouse target", .{});
        return .@"error";
    };

    if (window_mod.window_pane_mode(target.wp)) |wme| {
        if (wme.mode.key) |mode_key| {
            if (tc) |target_client|
                mode_key(wme, target_client, target.s, target.wl, event.m.key & ~T.KEYC_MASK_FLAGS, &event.m);
        }
    }

    // The reduced runtime can route queued mouse events to active pane modes,
    // but it still lacks tmux's coordinate-rich pane-input mouse encoder.
    return .normal;
}

fn resolve_mouse_target(mouse: *const T.MouseEvent, default_session: *T.Session, default_wl: *T.Winlink) ?MouseTarget {
    var mouse_session: ?*T.Session = null;
    var mouse_wl: ?*T.Winlink = null;
    if (mouse_runtime.cmd_mouse_pane(mouse, &mouse_session, &mouse_wl)) |wp| {
        return .{
            .s = mouse_session.?,
            .wl = mouse_wl.?,
            .wp = wp,
        };
    }

    if (!mouse.valid or mouse.wp == -1) return null;

    const pane_id: u32 = std.math.cast(u32, mouse.wp) orelse return null;
    const wp = window_mod.window_pane_find_by_id(pane_id) orelse return null;

    if (default_wl.window == wp.window and session_mod.session_has_window(default_session, wp.window)) {
        return .{
            .s = default_session,
            .wl = default_wl,
            .wp = wp,
        };
    }

    var sessions = session_mod.sessions.valueIterator();
    while (sessions.next()) |session_entry| {
        const candidate = session_entry.*;
        if (!session_mod.session_has_window(candidate, wp.window)) continue;
        const candidate_wl = session_mod.winlink_find_by_window(&candidate.windows, wp.window) orelse continue;
        return .{
            .s = candidate,
            .wl = candidate_wl,
            .wp = wp,
        };
    }
    return null;
}

fn reset_pane(wp: *T.WindowPane) void {
    colour_mod.colour_palette_clear(&wp.palette);
    window_mod.window_pane_reset_contents(wp);
    wp.flags |= T.PANE_STYLECHANGED | T.PANE_THEMECHANGED | T.PANE_REDRAW;
}

fn expand_values(args: *const args_mod.Arguments, ctx: *const format_mod.FormatContext, item: *cmdq.CmdqItem) ?[][]u8 {
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

fn parse_repeat_count(raw: ?[]const u8, ctx: *const format_mod.FormatContext, item: *cmdq.CmdqItem) ?u32 {
    const template = raw orelse return 1;
    const text = cmd_format.require(item, template, ctx) orelse return null;
    defer xm.allocator.free(text);

    const parsed = parse_repeat_count_value(text) catch |err| {
        const cause = switch (err) {
            error.Invalid => "invalid",
            error.TooSmall => "too small",
            error.TooLarge => "too large",
        };
        cmdq.cmdq_error(item, "repeat count {s}", .{cause});
        return null;
    };
    return parsed;
}

fn parse_repeat_count_value(text: []const u8) error{ Invalid, TooSmall, TooLarge }!u32 {
    if (text.len == 0) return error.Invalid;

    if (text[0] == '-') {
        if (text.len == 1) return error.Invalid;
        for (text[1..]) |ch| {
            if (!std.ascii.isDigit(ch)) return error.Invalid;
        }
        return error.TooSmall;
    }

    const digits = if (text[0] == '+') text[1..] else text;
    if (digits.len == 0) return error.Invalid;

    const parsed = std.fmt.parseInt(u32, digits, 10) catch |err| switch (err) {
        error.InvalidCharacter => return error.Invalid,
        error.Overflow => return error.TooLarge,
    };
    if (parsed == 0) return error.TooSmall;
    return parsed;
}

fn inject_hex(
    s: *T.Session,
    wl: *T.Winlink,
    wp: *T.WindowPane,
    tc: ?*T.Client,
    text: []const u8,
    dispatch_client: bool,
    item: *cmdq.CmdqItem,
    target: *const T.CmdFindState,
    after: *?*cmdq.CmdqItem,
) T.CmdRetval {
    const value = std.fmt.parseInt(u8, text, 16) catch return .normal;
    return inject_key(s, wl, wp, tc, T.KEYC_LITERAL | value, false, dispatch_client, item, target, after);
}

fn inject_string(
    s: *T.Session,
    wl: *T.Winlink,
    wp: *T.WindowPane,
    tc: ?*T.Client,
    value: []const u8,
    literal: bool,
    dispatch_client: bool,
    item: *cmdq.CmdqItem,
    target: *const T.CmdFindState,
    after: *?*cmdq.CmdqItem,
) T.CmdRetval {
    var use_literal = literal;
    if (!use_literal) {
        const key = key_string.key_string_lookup_string(value);
        if (key != T.KEYC_UNKNOWN and key != T.KEYC_NONE)
            return inject_key(s, wl, wp, tc, key, false, dispatch_client, item, target, after);
        use_literal = true;
    }

    if (!use_literal) return .normal;

    var index: usize = 0;
    while (index < value.len) {
        const key = next_literal_key(value, &index);
        if (inject_key(s, wl, wp, tc, key, false, dispatch_client, item, target, after) != .normal)
            return .@"error";
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

fn inject_key(
    s: *T.Session,
    wl: *T.Winlink,
    wp: *T.WindowPane,
    tc: ?*T.Client,
    key: T.key_code,
    allow_literal_fallback: bool,
    dispatch_client: bool,
    item: *cmdq.CmdqItem,
    target: *const T.CmdFindState,
    after: *?*cmdq.CmdqItem,
) T.CmdRetval {
    if (dispatch_client) {
        if (tc) |target_client| return dispatch_key(target_client, key);
        return .normal;
    }
    if (window_mod.window_pane_mode(wp)) |wme| {
        if (wme.mode.key_table) |key_table| {
            const table = key_bindings.key_bindings_get_table(key_table(wme), true).?;
            if (key_bindings.key_bindings_get(table, key & ~T.KEYC_MASK_FLAGS)) |binding| {
                const queue_after = if (after.*) |cursor|
                    if (cursor.queue != null) @as(?*T.CmdqItem, @ptrCast(cursor)) else null
                else
                    null;
                const inserted = key_bindings.key_bindings_dispatch(binding, queue_after, tc, null, @constCast(target));
                if (inserted) |cursor| after.* = @ptrCast(@alignCast(cursor));
            }
            return .normal;
        }
        if (wme.mode.key) |mode_key| {
            if (tc) |target_client| mode_key(wme, target_client, s, wl, key & ~T.KEYC_MASK_FLAGS, null);
            return .normal;
        }
        return .normal;
    }
    return send_key(wp, key, allow_literal_fallback, item);
}

fn dispatch_key(tc: *T.Client, key: T.key_code) T.CmdRetval {
    var event = T.key_event{ .key = key | T.KEYC_SENT };
    var buf: [16]u8 = undefined;
    if (input_keys.input_key_encode(key, &buf)) |bytes| {
        event.len = bytes.len;
        @memcpy(event.data[0..bytes.len], bytes);
    } else |_| {
        event.len = 0;
    }

    _ = server_fn.server_client_handle_key(tc, &event);
    return .normal;
}

fn send_key(wp: *T.WindowPane, key: T.key_code, allow_literal_fallback: bool, item: *cmdq.CmdqItem) T.CmdRetval {
    if (wp.fd < 0 or wp.flags & T.PANE_INPUTOFF != 0) return .normal;

    var buf: [32]u8 = undefined;
    const bytes = input_keys.input_key_encode_screen(screen_mod.screen_current(wp), key, &buf) catch |err| switch (err) {
        error.UnsupportedKey => {
            if (allow_literal_fallback) {
                const text = key_string.key_string_lookup_key(key, 0);
                pane_input.write_all(wp.fd, text, item) catch return .@"error";
                window_mod.window_pane_synchronize_key_bytes(wp, key, text);
                return .normal;
            }
            return .normal;
        },
    };
    if (bytes.len == 0) return .normal;
    pane_input.write_all(wp.fd, bytes, item) catch return .@"error";
    window_mod.window_pane_synchronize_key_bytes(wp, key, bytes);
    return .normal;
}

pub const entry: cmd_mod.CmdEntry = .{
    .name = "send-keys",
    .alias = "send",
    .usage = "[-FHKlMRX] [-c target-client] [-N repeat-count] [-t target-pane] [key ...]",
    .template = "c:FHKlMN:Rt:X",
    .lower = 0,
    .upper = -1,
    .flags = T.CMD_AFTERHOOK | T.CMD_CLIENT_CFLAG | T.CMD_CLIENT_CANFAIL | T.CMD_READONLY,
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

const ModeKeyState = struct {
    calls: usize = 0,
    saw_client: bool = false,
    last_key: T.key_code = T.KEYC_NONE,
};

const ModeCommandState = struct {
    calls: usize = 0,
    saw_client: bool = false,
    saw_mouse: bool = false,
    prefix: u32 = 0,
    arg_count: usize = 0,
    first_arg_is_enter: bool = false,
};

fn test_mode_table_name(_: *T.WindowModeEntry) []const u8 {
    return "send-keys-mode";
}

fn test_mode_key(
    wme: *T.WindowModeEntry,
    tc: ?*T.Client,
    s: *T.Session,
    wl: *T.Winlink,
    key: T.key_code,
    mouse: ?*const T.MouseEvent,
) void {
    _ = s;
    _ = wl;
    _ = mouse;
    const state: *ModeKeyState = @ptrCast(@alignCast(wme.data.?));
    state.calls += 1;
    state.saw_client = tc != null;
    state.last_key = key;
}

fn test_mode_command(
    wme: *T.WindowModeEntry,
    tc: ?*T.Client,
    s: *T.Session,
    wl: *T.Winlink,
    raw_args: *const anyopaque,
    mouse: ?*const T.MouseEvent,
) void {
    _ = s;
    _ = wl;
    const state: *ModeCommandState = @ptrCast(@alignCast(wme.data.?));
    const args: *const args_mod.Arguments = @ptrCast(@alignCast(raw_args));
    state.calls += 1;
    state.saw_client = tc != null;
    state.saw_mouse = mouse != null;
    state.prefix = wme.prefix;
    state.arg_count = args.count();
    state.first_arg_is_enter = args.count() > 0 and std.mem.eql(u8, args.value_at(0).?, "Enter");
}

const test_mode_table: T.WindowMode = .{
    .name = "mode-table",
    .key_table = test_mode_table_name,
};

const test_mode_key_only: T.WindowMode = .{
    .name = "mode-key",
    .key = test_mode_key,
};

const test_mode_command_only: T.WindowMode = .{
    .name = "mode-command",
    .command = test_mode_command,
};

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

test "send-prefix -2 uses session prefix2 option bytes" {
    const setup = try test_session_with_empty_pane("send-prefix2-test");
    const pipe_fds = try std.posix.pipe();
    defer test_teardown_session("send-prefix2-test", setup.s, pipe_fds[0], -1);

    setup.wp.fd = pipe_fds[1];
    opts.options_set_string(setup.s.options, false, "prefix2", "C-z");

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "send-prefix", "-2", "-t", "send-prefix2-test:0.0" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));

    var buf: [8]u8 = undefined;
    const n = try std.posix.read(pipe_fds[0], &buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u8, 0x1a), buf[0]);
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

test "send-keys uses the pane screen mode for cursor-key output" {
    const setup = try test_session_with_empty_pane("send-cursor-mode-test");
    const pipe_fds = try std.posix.pipe();
    defer test_teardown_session("send-cursor-mode-test", setup.s, pipe_fds[0], -1);

    setup.wp.fd = pipe_fds[1];
    screen_mod.screen_current(setup.wp).mode |= T.MODE_KCURSOR;

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "send-keys", "-t", "send-cursor-mode-test:0.0", "Up" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));

    var buf: [8]u8 = undefined;
    const n = try std.posix.read(pipe_fds[0], &buf);
    try std.testing.expectEqualStrings("\x1bOA", buf[0..n]);
    std.posix.close(pipe_fds[1]);
    setup.wp.fd = -1;
}

test "send-keys -H ignores invalid hex bytes and keeps later input" {
    const setup = try test_session_with_empty_pane("send-hex-ignore");
    const pipe_fds = try std.posix.pipe();
    defer test_teardown_session("send-hex-ignore", setup.s, pipe_fds[0], -1);

    setup.wp.fd = pipe_fds[1];

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "send-keys", "-H", "-t", "send-hex-ignore:0.0", "zz", "41" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));

    var buf: [8]u8 = undefined;
    const n = try std.posix.read(pipe_fds[0], &buf);
    try std.testing.expectEqualStrings("A", buf[0..n]);
    std.posix.close(pipe_fds[1]);
    setup.wp.fd = -1;
}

test "send-keys expands repeat count options before parsing" {
    const setup = try test_session_with_empty_pane("send-repeat-format");
    const pipe_fds = try std.posix.pipe();
    defer test_teardown_session("send-repeat-format", setup.s, pipe_fds[0], -1);

    setup.wp.fd = pipe_fds[1];

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "send-keys", "-N", "#{e|+:1,1}", "-t", "send-repeat-format:0.0", "x" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));

    var buf: [8]u8 = undefined;
    const n = try std.posix.read(pipe_fds[0], &buf);
    try std.testing.expectEqualStrings("xx", buf[0..n]);
    std.posix.close(pipe_fds[1]);
    setup.wp.fd = -1;
}

test "send-keys reports tmux-style too small repeat count errors" {
    const setup = try test_session_with_empty_pane("send-repeat-too-small");
    defer test_teardown_session("send-repeat-too-small", setup.s, -1, -1);

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "send-keys", "-N", "0", "-t", "send-repeat-too-small:0.0", "x" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };

    const saved_stderr = try std.posix.dup(std.posix.STDERR_FILENO);
    defer std.posix.close(saved_stderr);

    const stderr_pipe = try std.posix.pipe();
    defer std.posix.close(stderr_pipe[0]);

    try std.posix.dup2(stderr_pipe[1], std.posix.STDERR_FILENO);
    defer std.posix.dup2(saved_stderr, std.posix.STDERR_FILENO) catch {};

    try std.testing.expectEqual(T.CmdRetval.@"error", cmd_mod.cmd_execute(cmd, &item));
    try std.posix.dup2(saved_stderr, std.posix.STDERR_FILENO);
    std.posix.close(stderr_pipe[1]);

    var errbuf: [128]u8 = undefined;
    const errlen = try std.posix.read(stderr_pipe[0], errbuf[0..]);
    try std.testing.expect(std.mem.indexOf(u8, errbuf[0..errlen], "repeat count too small") != null);
}

test "send-keys reports tmux-style too large repeat count errors" {
    const setup = try test_session_with_empty_pane("send-repeat-too-large");
    defer test_teardown_session("send-repeat-too-large", setup.s, -1, -1);

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "send-keys", "-N", "4294967296", "-t", "send-repeat-too-large:0.0", "x" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };

    const saved_stderr = try std.posix.dup(std.posix.STDERR_FILENO);
    defer std.posix.close(saved_stderr);

    const stderr_pipe = try std.posix.pipe();
    defer std.posix.close(stderr_pipe[0]);

    try std.posix.dup2(stderr_pipe[1], std.posix.STDERR_FILENO);
    defer std.posix.dup2(saved_stderr, std.posix.STDERR_FILENO) catch {};

    try std.testing.expectEqual(T.CmdRetval.@"error", cmd_mod.cmd_execute(cmd, &item));
    try std.posix.dup2(saved_stderr, std.posix.STDERR_FILENO);
    std.posix.close(stderr_pipe[1]);

    var errbuf: [128]u8 = undefined;
    const errlen = try std.posix.read(stderr_pipe[0], errbuf[0..]);
    try std.testing.expect(std.mem.indexOf(u8, errbuf[0..errlen], "repeat count too large") != null);
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

test "send-keys -R with no arguments resets pane state without replaying the triggering key" {
    const grid = @import("grid.zig");

    const setup = try test_session_with_empty_pane("send-reset-noargs");
    const pipe_fds = try std.posix.pipe();
    defer test_teardown_session("send-reset-noargs", setup.s, pipe_fds[0], -1);

    setup.wp.fd = pipe_fds[1];
    grid.set_ascii(setup.wp.base.grid, 0, 0, 'X');
    try setup.wp.input_pending.appendSlice(xm.allocator, "leftover");
    setup.wp.palette.fg = 2;
    setup.wp.palette.bg = 4;

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "send-keys", "-R", "-t", "send-reset-noargs:0.0" }, null, &cause);
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
    try std.testing.expectEqual(@as(usize, 0), try std.posix.poll(&poll_fds, 100));
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

test "send-keys with -c still writes directly to the target pane unless -K is set" {
    const env_mod = @import("environ.zig");
    const sess = @import("session.zig");
    const spawn = @import("spawn.zig");
    const win = @import("window.zig");

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

    const s = sess.session_create(null, "send-c-pane", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("send-c-pane") != null) sess.session_destroy(s, false, "test");

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
        .name = xm.xstrdup("direct-client"),
        .environ = env,
        .tty = undefined,
        .status = .{ .screen = undefined },
        .flags = T.CLIENT_ATTACHED,
        .session = s,
    };
    defer xm.allocator.free(cl.name.?);
    cl.tty.client = &cl;
    client_registry.add(&cl);

    const cmd = try cmd_mod.cmd_parse_one(&.{ "send-keys", "-c", "direct-client", "-t", "send-c-pane:0.0", "C-b", "c" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));

    _ = cmdq.cmdq_next(&cl);
    try std.testing.expectEqual(@as(usize, 1), s.windows.count());

    var buf: [8]u8 = undefined;
    const n = try std.posix.read(pipe_fds[0], &buf);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual(@as(u8, 0x02), buf[0]);
    try std.testing.expectEqual(@as(u8, 'c'), buf[1]);
}

test "send-keys quietly ignores an unknown target client when not using -K" {
    const setup = try test_session_with_empty_pane("send-missing-client");
    const pipe_fds = try std.posix.pipe();
    defer test_teardown_session("send-missing-client", setup.s, pipe_fds[0], -1);
    client_registry.clients.clearRetainingCapacity();
    defer client_registry.clients.clearRetainingCapacity();

    setup.wp.fd = pipe_fds[1];

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "send-keys", "-c", "ghost", "-t", "send-missing-client:0.0", "x" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));

    var buf: [8]u8 = undefined;
    const n = try std.posix.read(pipe_fds[0], &buf);
    try std.testing.expectEqualStrings("x", buf[0..n]);
    std.posix.close(pipe_fds[1]);
    setup.wp.fd = -1;
}

test "send-keys -K without a dispatchable client is a no-op" {
    const setup = try test_session_with_empty_pane("send-k-noclient");
    const pipe_fds = try std.posix.pipe();
    defer test_teardown_session("send-k-noclient", setup.s, pipe_fds[0], -1);

    setup.wp.fd = pipe_fds[1];

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "send-keys", "-K", "-t", "send-k-noclient:0.0", "x" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));

    var poll_fds = [_]std.posix.pollfd{.{
        .fd = pipe_fds[0],
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    try std.testing.expectEqual(@as(usize, 0), try std.posix.poll(&poll_fds, 100));
    std.posix.close(pipe_fds[1]);
    setup.wp.fd = -1;
}

test "send-keys dispatches active mode table bindings instead of writing to the pane" {
    key_bindings.key_bindings_init();

    const setup = try test_session_with_empty_pane("send-mode-table");
    const pipe_fds = try std.posix.pipe();
    defer test_teardown_session("send-mode-table", setup.s, pipe_fds[0], -1);

    setup.wp.fd = pipe_fds[1];
    _ = window_mod.window_pane_push_mode(setup.wp, &test_mode_table, null, null);

    var cause: ?[]u8 = null;
    const bound = try cmd_mod.cmd_parse_from_argv_with_cause(&.{ "new-window", "-d", "-t", "send-mode-table:0", "-n", "bound" }, null, &cause);
    key_bindings.key_bindings_add("send-keys-mode", 'x', null, false, @ptrCast(bound));

    const cmd = try cmd_mod.cmd_parse_one(&.{ "send-keys", "-t", "send-mode-table:0.0", "x" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));

    _ = cmdq.cmdq_next(null);
    try std.testing.expectEqual(@as(usize, 2), setup.s.windows.count());

    var poll_fds = [_]std.posix.pollfd{.{
        .fd = pipe_fds[0],
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    try std.testing.expectEqual(@as(usize, 0), try std.posix.poll(&poll_fds, 100));
    std.posix.close(pipe_fds[1]);
    setup.wp.fd = -1;
}

test "send-keys preserves mode binding queue order across multiple keys" {
    key_bindings.key_bindings_init();

    const setup = try test_session_with_empty_pane("send-mode-order");
    defer test_teardown_session("send-mode-order", setup.s, -1, -1);

    _ = window_mod.window_pane_push_mode(setup.wp, &test_mode_table, null, null);
    window_mod.window_set_name(setup.wp.window, "before");

    var cause: ?[]u8 = null;
    const rename_first = try cmd_mod.cmd_parse_from_argv_with_cause(&.{ "rename-window", "first" }, null, &cause);
    const rename_second = try cmd_mod.cmd_parse_from_argv_with_cause(&.{ "rename-window", "second" }, null, &cause);
    key_bindings.key_bindings_add("send-keys-mode", 'a', null, false, @ptrCast(rename_first));
    key_bindings.key_bindings_add("send-keys-mode", 'b', null, false, @ptrCast(rename_second));

    const cmd = try cmd_mod.cmd_parse_one(&.{ "send-keys", "-t", "send-mode-order:0.0", "a", "b" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));

    _ = cmdq.cmdq_next(null);
    try std.testing.expectEqualStrings("second", setup.wp.window.name);
}

test "send-keys mode bindings inherit the target pane state" {
    const env_mod = @import("environ.zig");
    const sess = @import("session.zig");
    const spawn = @import("spawn.zig");
    const win = @import("window.zig");

    sess.session_init_globals(xm.allocator);
    win.window_init_globals(xm.allocator);
    key_bindings.key_bindings_init();

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

    const target_session = sess.session_create(null, "send-mode-target", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("send-mode-target") != null) sess.session_destroy(target_session, false, "test");
    const decoy_session = sess.session_create(null, "send-mode-decoy", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("send-mode-decoy") != null) sess.session_destroy(decoy_session, false, "test");

    var cause: ?[]u8 = null;
    var target_ctx: T.SpawnContext = .{ .s = target_session, .idx = -1, .flags = T.SPAWN_EMPTY };
    const target_wl = spawn.spawn_window(&target_ctx, &cause).?;
    target_session.curw = target_wl;
    window_mod.window_set_name(target_wl.window, "target-before");

    var decoy_ctx: T.SpawnContext = .{ .s = decoy_session, .idx = -1, .flags = T.SPAWN_EMPTY };
    const decoy_wl = spawn.spawn_window(&decoy_ctx, &cause).?;
    decoy_session.curw = decoy_wl;
    window_mod.window_set_name(decoy_wl.window, "decoy-before");

    _ = window_mod.window_pane_push_mode(target_wl.window.active.?, &test_mode_table, null, null);

    const rename_target = try cmd_mod.cmd_parse_from_argv_with_cause(&.{ "rename-window", "target-after" }, null, &cause);
    key_bindings.key_bindings_add("send-keys-mode", 'x', null, false, @ptrCast(rename_target));

    const cmd = try cmd_mod.cmd_parse_one(&.{ "send-keys", "-t", "send-mode-target:0.0", "x" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));

    _ = cmdq.cmdq_next(null);
    try std.testing.expectEqualStrings("target-after", target_wl.window.name);
    try std.testing.expectEqualStrings("decoy-before", decoy_wl.window.name);
}

test "send-keys routes active mode keys through the target client instead of writing to the pane" {
    const env_mod = @import("environ.zig");

    client_registry.clients.clearRetainingCapacity();
    defer client_registry.clients.clearRetainingCapacity();

    const setup = try test_session_with_empty_pane("send-mode-key");
    const pipe_fds = try std.posix.pipe();
    defer test_teardown_session("send-mode-key", setup.s, pipe_fds[0], -1);

    setup.wp.fd = pipe_fds[1];
    var state = ModeKeyState{};
    _ = window_mod.window_pane_push_mode(setup.wp, &test_mode_key_only, @ptrCast(&state), null);

    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);
    var cl = T.Client{
        .name = xm.xstrdup("mode-client"),
        .environ = env,
        .tty = undefined,
        .status = .{ .screen = undefined },
        .flags = T.CLIENT_ATTACHED,
        .session = setup.s,
    };
    defer xm.allocator.free(cl.name.?);
    cl.tty.client = &cl;
    client_registry.add(&cl);

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "send-keys", "-c", "mode-client", "-t", "send-mode-key:0.0", "x" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));

    try std.testing.expectEqual(@as(usize, 1), state.calls);
    try std.testing.expect(state.saw_client);
    try std.testing.expectEqual(@as(T.key_code, 'x'), state.last_key);

    var poll_fds = [_]std.posix.pollfd{.{
        .fd = pipe_fds[0],
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    try std.testing.expectEqual(@as(usize, 0), try std.posix.poll(&poll_fds, 100));
    std.posix.close(pipe_fds[1]);
    setup.wp.fd = -1;
}

test "send-keys -M routes mouse events through active mode keys" {
    const env_mod = @import("environ.zig");

    client_registry.clients.clearRetainingCapacity();
    defer client_registry.clients.clearRetainingCapacity();

    const setup = try test_session_with_empty_pane("send-mode-mouse");
    const pipe_fds = try std.posix.pipe();
    defer test_teardown_session("send-mode-mouse", setup.s, pipe_fds[0], -1);

    setup.wp.fd = pipe_fds[1];
    var state = ModeKeyState{};
    _ = window_mod.window_pane_push_mode(setup.wp, &test_mode_key_only, @ptrCast(&state), null);

    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);
    var cl = T.Client{
        .name = xm.xstrdup("mode-mouse-client"),
        .environ = env,
        .tty = undefined,
        .status = .{ .screen = undefined },
        .flags = T.CLIENT_ATTACHED,
        .session = setup.s,
    };
    defer xm.allocator.free(cl.name.?);
    cl.tty.client = &cl;
    client_registry.add(&cl);

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "send-keys", "-M", "-c", "mode-mouse-client", "-t", "send-mode-mouse:0.0" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{
        .client = null,
        .cmdlist = &list,
        .event = .{
            .m = .{
                .valid = true,
                .key = T.keycMouse(T.KEYC_MOUSEDOWN1, .pane),
                .wp = @intCast(setup.wp.id),
            },
        },
    };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));

    try std.testing.expectEqual(@as(usize, 1), state.calls);
    try std.testing.expect(state.saw_client);
    try std.testing.expectEqual(T.keycMouse(T.KEYC_MOUSEDOWN1, .pane), state.last_key);

    var poll_fds = [_]std.posix.pollfd{.{
        .fd = pipe_fds[0],
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    try std.testing.expectEqual(@as(usize, 0), try std.posix.poll(&poll_fds, 100));
    std.posix.close(pipe_fds[1]);
    setup.wp.fd = -1;
}

test "send-keys -X uses the active mode command and repeat prefix" {
    const setup = try test_session_with_empty_pane("send-mode-command");
    defer test_teardown_session("send-mode-command", setup.s, -1, -1);

    var state = ModeCommandState{};
    _ = window_mod.window_pane_push_mode(setup.wp, &test_mode_command_only, @ptrCast(&state), null);

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "send-keys", "-X", "-N", "3", "-t", "send-mode-command:0.0", "Enter" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{
        .client = null,
        .cmdlist = &list,
        .event = .{
            .key = T.KEYC_NONE,
            .m = .{ .valid = true, .key = T.KEYC_MOUSEMOVE },
        },
    };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));

    try std.testing.expectEqual(@as(usize, 1), state.calls);
    try std.testing.expectEqual(@as(u32, 3), state.prefix);
    try std.testing.expectEqual(@as(usize, 1), state.arg_count);
    try std.testing.expect(state.first_arg_is_enter);
    try std.testing.expect(state.saw_mouse);
}

test "send-keys pane_in_mode reflects the reduced active mode stack" {
    const setup = try test_session_with_empty_pane("send-pane-in-mode");
    defer test_teardown_session("send-pane-in-mode", setup.s, -1, -1);

    const before = format_mod.format_single(null, "#{pane_in_mode}", null, setup.s, setup.s.curw, setup.wp);
    defer xm.allocator.free(before);
    try std.testing.expectEqualStrings("0", before);

    _ = window_mod.window_pane_push_mode(setup.wp, &test_mode_command_only, null, null);

    const after = format_mod.format_single(null, "#{pane_in_mode}", null, setup.s, setup.s.curw, setup.wp);
    defer xm.allocator.free(after);
    try std.testing.expectEqualStrings("1", after);
}

test "send-keys rejects read-only target clients before writing" {
    const env_mod = @import("environ.zig");
    const sess = @import("session.zig");
    const spawn = @import("spawn.zig");
    const win = @import("window.zig");

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

    const s = sess.session_create(null, "send-readonly", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("send-readonly") != null) sess.session_destroy(s, false, "test");

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
        .name = xm.xstrdup("readonly-client"),
        .environ = env,
        .tty = undefined,
        .status = .{ .screen = undefined },
        .flags = T.CLIENT_ATTACHED | T.CLIENT_READONLY,
        .session = s,
    };
    defer xm.allocator.free(cl.name.?);
    cl.tty.client = &cl;
    client_registry.add(&cl);

    const cmd = try cmd_mod.cmd_parse_one(&.{ "send-keys", "-c", "readonly-client", "-t", "send-readonly:0.0", "x" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };

    const saved_stderr = try std.posix.dup(std.posix.STDERR_FILENO);
    defer std.posix.close(saved_stderr);

    const stderr_pipe = try std.posix.pipe();
    defer std.posix.close(stderr_pipe[0]);

    try std.posix.dup2(stderr_pipe[1], std.posix.STDERR_FILENO);
    defer std.posix.dup2(saved_stderr, std.posix.STDERR_FILENO) catch {};

    try std.testing.expectEqual(T.CmdRetval.@"error", cmd_mod.cmd_execute(cmd, &item));
    try std.posix.dup2(saved_stderr, std.posix.STDERR_FILENO);
    std.posix.close(stderr_pipe[1]);

    var errbuf: [128]u8 = undefined;
    const errlen = try std.posix.read(stderr_pipe[0], errbuf[0..]);
    try std.testing.expect(std.mem.indexOf(u8, errbuf[0..errlen], "client is read-only") != null);

    var poll_fds = [_]std.posix.pollfd{.{
        .fd = pipe_fds[0],
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    try std.testing.expectEqual(@as(usize, 0), try std.posix.poll(&poll_fds, 100));
}

test "send-prefix ignores panes that are not accepting input" {
    const setup = try test_session_with_empty_pane("send-prefix-closed");
    defer test_teardown_session("send-prefix-closed", setup.s, -1, -1);

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "send-prefix", "-t", "send-prefix-closed:0.0" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));
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

test "send-keys with no arguments and no triggering key is a quiet no-op" {
    const setup = try test_session_with_empty_pane("send-replay-missing");
    const pipe_fds = try std.posix.pipe();
    defer test_teardown_session("send-replay-missing", setup.s, pipe_fds[0], -1);

    setup.wp.fd = pipe_fds[1];

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "send-keys", "-t", "send-replay-missing:0.0" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{
        .client = null,
        .cmdlist = &list,
        .event = .{ .key = T.KEYC_NONE },
    };

    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));

    var poll_fds = [_]std.posix.pollfd{.{
        .fd = pipe_fds[0],
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    try std.testing.expectEqual(@as(usize, 0), try std.posix.poll(&poll_fds, 100));
    std.posix.close(pipe_fds[1]);
    setup.wp.fd = -1;
}

test "send-keys -K replays the triggering key through the target client" {
    const env_mod = @import("environ.zig");
    const sess = @import("session.zig");
    const spawn = @import("spawn.zig");
    const win = @import("window.zig");

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

    const s = sess.session_create(null, "send-replay-k-client", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("send-replay-k-client") != null) sess.session_destroy(s, false, "test");

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
        .name = xm.xstrdup("replay-client"),
        .environ = env,
        .tty = undefined,
        .status = .{ .screen = undefined },
        .flags = T.CLIENT_ATTACHED,
        .session = s,
    };
    defer xm.allocator.free(cl.name.?);
    cl.tty.client = &cl;
    client_registry.add(&cl);

    const cmd = try cmd_mod.cmd_parse_one(&.{ "send-keys", "-c", "replay-client", "-K", "-t", "send-replay-k-client:0.0" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{
        .client = null,
        .cmdlist = &list,
        .event = .{ .key = 'x', .len = 1 },
    };
    item.event.data[0] = 'x';

    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));

    var buf: [8]u8 = undefined;
    const n = try std.posix.read(pipe_fds[0], &buf);
    try std.testing.expectEqualStrings("x", buf[0..n]);
}

test "send-keys -K with no replay client is a quiet no-op" {
    const setup = try test_session_with_empty_pane("send-replay-k-noclient");
    const pipe_fds = try std.posix.pipe();
    defer test_teardown_session("send-replay-k-noclient", setup.s, pipe_fds[0], -1);

    setup.wp.fd = pipe_fds[1];

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "send-keys", "-K", "-t", "send-replay-k-noclient:0.0" }, null, &cause);
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
    try std.testing.expectEqual(@as(usize, 0), try std.posix.poll(&poll_fds, 100));
    std.posix.close(pipe_fds[1]);
    setup.wp.fd = -1;
}

test "send-keys with -N and no arguments is a quiet no-op" {
    const setup = try test_session_with_empty_pane("send-replay-repeat");
    const pipe_fds = try std.posix.pipe();
    defer test_teardown_session("send-replay-repeat", setup.s, pipe_fds[0], -1);

    setup.wp.fd = pipe_fds[1];

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "send-keys", "-N", "2", "-t", "send-replay-repeat:0.0" }, null, &cause);
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
    try std.testing.expectEqual(@as(usize, 0), try std.posix.poll(&poll_fds, 100));
    std.posix.close(pipe_fds[1]);
    setup.wp.fd = -1;
}

test "send-keys with an unsupported triggering key is a quiet no-op" {
    const setup = try test_session_with_empty_pane("send-replay-unsupported");
    const pipe_fds = try std.posix.pipe();
    defer test_teardown_session("send-replay-unsupported", setup.s, pipe_fds[0], -1);

    setup.wp.fd = pipe_fds[1];

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "send-keys", "-t", "send-replay-unsupported:0.0" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{
        .client = null,
        .cmdlist = &list,
        .event = .{ .key = T.keycMouse(T.KEYC_MOUSEDOWN1, .pane) },
    };

    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));

    var poll_fds = [_]std.posix.pollfd{.{
        .fd = pipe_fds[0],
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    try std.testing.expectEqual(@as(usize, 0), try std.posix.poll(&poll_fds, 100));
    std.posix.close(pipe_fds[1]);
    setup.wp.fd = -1;
}

test "send-keys treats Any as a special key and quietly skips pane output" {
    const setup = try test_session_with_empty_pane("send-any-noop");
    const pipe_fds = try std.posix.pipe();
    defer test_teardown_session("send-any-noop", setup.s, pipe_fds[0], -1);

    setup.wp.fd = pipe_fds[1];

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "send-keys", "-t", "send-any-noop:0.0", "Any" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };

    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));

    var poll_fds = [_]std.posix.pollfd{.{
        .fd = pipe_fds[0],
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    try std.testing.expectEqual(@as(usize, 0), try std.posix.poll(&poll_fds, 100));
    std.posix.close(pipe_fds[1]);
    setup.wp.fd = -1;
}

test "send-keys -K dispatches Any through target-client wildcard bindings" {
    const env_mod = @import("environ.zig");
    const sess = @import("session.zig");
    const spawn = @import("spawn.zig");
    const win = @import("window.zig");

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

    const s = sess.session_create(null, "send-k-any", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("send-k-any") != null) sess.session_destroy(s, false, "test");

    var cause: ?[]u8 = null;
    var sc: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    _ = spawn.spawn_window(&sc, &cause).?;

    const bound = try cmd_mod.cmd_parse_from_argv_with_cause(&.{ "new-window", "-d", "-t", "send-k-any:0", "-n", "wildcard" }, null, &cause);
    key_bindings.key_bindings_add("root", T.KEYC_ANY, null, false, @ptrCast(bound));

    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);
    var cl = T.Client{
        .name = xm.xstrdup("wildcard-client"),
        .environ = env,
        .tty = undefined,
        .status = .{ .screen = undefined },
        .flags = T.CLIENT_ATTACHED,
        .session = s,
    };
    defer xm.allocator.free(cl.name.?);
    cl.tty.client = &cl;
    client_registry.add(&cl);

    const cmd = try cmd_mod.cmd_parse_one(&.{ "send-keys", "-c", "wildcard-client", "-K", "-t", "send-k-any:0.0", "Any" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };

    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));

    _ = cmdq.cmdq_next(&cl);
    try std.testing.expectEqual(@as(usize, 2), s.windows.count());
}

test "send-keys mirrors pane writes to synchronized sibling panes" {
    const win = @import("window.zig");

    const setup = try test_session_with_empty_pane("send-sync");
    defer test_teardown_session("send-sync", setup.s, -1, -1);

    const sibling = win.window_add_pane(setup.wp.window, null, setup.wp.sx, setup.wp.sy);
    const source_pipe = try std.posix.pipe();
    const sibling_pipe = try std.posix.pipe();
    defer std.posix.close(source_pipe[0]);
    defer std.posix.close(sibling_pipe[0]);
    setup.wp.fd = source_pipe[1];
    sibling.fd = sibling_pipe[1];
    defer {
        if (setup.wp.fd >= 0) std.posix.close(setup.wp.fd);
        if (sibling.fd >= 0) std.posix.close(sibling.fd);
        setup.wp.fd = -1;
        sibling.fd = -1;
    }

    opts.options_set_number(setup.wp.options, "synchronize-panes", 1);
    opts.options_set_number(sibling.options, "synchronize-panes", 1);

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "send-keys", "-t", "send-sync:0.0", "x" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));

    var source_buf: [8]u8 = undefined;
    const source_len = try std.posix.read(source_pipe[0], &source_buf);
    try std.testing.expectEqualStrings("x", source_buf[0..source_len]);

    var sibling_buf: [8]u8 = undefined;
    const sibling_len = try std.posix.read(sibling_pipe[0], &sibling_buf);
    try std.testing.expectEqualStrings("x", sibling_buf[0..sibling_len]);
}

test "send-keys -M errors when the queued event has no mouse target pane" {
    const setup = try test_session_with_empty_pane("send-mode-missing-mouse");
    defer test_teardown_session("send-mode-missing-mouse", setup.s, -1, -1);

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "send-keys", "-M", "-t", "send-mode-missing-mouse:0.0" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{
        .client = null,
        .cmdlist = &list,
        .event = .{
            .m = .{
                .valid = true,
                .key = T.keycMouse(T.KEYC_MOUSEDOWN1, .pane),
                .wp = -1,
            },
        },
    };

    const saved_stderr = try std.posix.dup(std.posix.STDERR_FILENO);
    defer std.posix.close(saved_stderr);

    const stderr_pipe = try std.posix.pipe();
    defer std.posix.close(stderr_pipe[0]);

    try std.posix.dup2(stderr_pipe[1], std.posix.STDERR_FILENO);
    defer std.posix.dup2(saved_stderr, std.posix.STDERR_FILENO) catch {};

    try std.testing.expectEqual(T.CmdRetval.@"error", cmd_mod.cmd_execute(cmd, &item));
    try std.posix.dup2(saved_stderr, std.posix.STDERR_FILENO);
    std.posix.close(stderr_pipe[1]);

    var errbuf: [128]u8 = undefined;
    const errlen = try std.posix.read(stderr_pipe[0], errbuf[0..]);
    try std.testing.expect(std.mem.indexOf(u8, errbuf[0..errlen], "no mouse target") != null);
}
