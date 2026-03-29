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

    if (args.has('R')) {
        reset_pane(wp);
        server_fn.server_redraw_pane(wp);
    }

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
        return .normal;
    }

    if (target.wp.fd < 0 or target.wp.flags & T.PANE_INPUTOFF != 0) return .normal;

    var mouse_buf: [40]u8 = undefined;
    const bytes = input_keys.input_key_mouse_pane(target.wp, &event.m, &mouse_buf);
    if (bytes.len == 0) return .normal;
    pane_input.write_all(target.wp.fd, bytes, item) catch return .@"error";
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
            } else if (wme.mode.key) |mode_key| {
                if (tc) |target_client| mode_key(wme, target_client, s, wl, key & ~T.KEYC_MASK_FLAGS, null);
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
