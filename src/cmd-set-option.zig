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
// Ported in part from tmux/cmd-set-option.c.
// Original copyright:
//   Copyright (c) 2007 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const cmd_format = @import("cmd-format.zig");
const cmd_find = @import("cmd-find.zig");
const cmd_mod = @import("cmd.zig");
const cmd_opts = @import("cmd-options.zig");
const cmdq = @import("cmd-queue.zig");
const format_mod = @import("format.zig");
const opts = @import("options.zig");
const notify = @import("notify.zig");
const win = @import("window.zig");

fn exec(cmd: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {
    const args = cmd_mod.cmd_get_args(cmd);
    const entry_ptr = cmd_mod.cmd_get_entry(cmd);
    const hook_command = entry_ptr == &entry_hook;
    const raw_option_name = args.value_at(0) orelse {
        cmdq.cmdq_error(item, "invalid option", .{});
        return .@"error";
    };
    const current = cmdq.cmdq_get_target(item);
    const option_ctx = format_mod.FormatContext{
        .item = @ptrCast(item),
        .client = cmdq.cmdq_get_client(item),
        .session = current.s,
        .winlink = current.wl,
        .window = current.w,
        .pane = current.wp,
    };
    const expanded_option = cmd_format.require(item, raw_option_name, &option_ctx) orelse return .@"error";
    defer xm.allocator.free(expanded_option);

    var idx: ?u32 = null;
    var ambiguous = false;
    const option_name = opts.options_match(expanded_option, &idx, &ambiguous) orelse {
        if (args.has('q')) return .normal;
        if (ambiguous)
            cmdq.cmdq_error(item, "ambiguous option: {s}", .{expanded_option})
        else
            cmdq.cmdq_error(item, "invalid option: {s}", .{expanded_option});
        return .@"error";
    };
    defer xm.allocator.free(option_name);

    const oe = opts.options_table_entry(option_name);
    const custom = cmd_opts.is_custom_option(option_name);
    if (oe == null and !custom) {
        if (args.has('q')) return .normal;
        cmdq.cmdq_error(item, "invalid option: {s}", .{option_name});
        return .@"error";
    }
    if (idx != null and (custom or oe == null or oe.?.type != .array)) {
        cmdq.cmdq_error(item, "not an array: {s}", .{expanded_option});
        return .@"error";
    }
    if (hook_command and (oe == null or !oe.?.is_hook)) {
        cmdq.cmdq_error(item, "invalid option: {s}", .{option_name});
        return .@"error";
    }
    if (hook_command and args.has('R')) {
        var hook_target: T.CmdFindState = .{ .idx = -1 };
        _ = cmd_find.cmd_find_target(&hook_target, item, args.get('t'), .pane, T.CMD_FIND_QUIET | T.CMD_FIND_CANFAIL);
        notify.notify_hook(item, option_name, &hook_target);
        return .normal;
    }

    const target = cmd_opts.resolve_target_for_name(item, args, entry_ptr == &entry_window, option_name) orelse return .@"error";
    if (!cmd_opts.option_allowed(oe, target.kind)) {
        if (args.has('q')) return .normal;
        cmdq.cmdq_error(item, "invalid option: {s}", .{option_name});
        return .@"error";
    }

    if (!args.has('u') and args.has('o') and option_is_set_locally(target.options, option_name, idx)) {
        if (args.has('q')) return .normal;
        cmdq.cmdq_error(item, "already set: {s}", .{expanded_option});
        return .@"error";
    }

    var cause: ?[]u8 = null;
    defer if (cause) |msg| xm.allocator.free(msg);

    if (args.has('u') or args.has('U')) {
        if (args.has('U') and target.kind == .window) {
            if (!clear_window_option_overrides(target, option_name, oe, idx, &cause)) {
                cmdq.cmdq_error(item, "{s}", .{cause orelse "invalid option"});
                return .@"error";
            }
        }
        if (!unset_option(target, option_name, oe, idx, &cause)) {
            cmdq.cmdq_error(item, "{s}", .{cause orelse "invalid option"});
            return .@"error";
        }
        cmd_opts.apply_target_side_effects(target, option_name);
        return .normal;
    }

    const raw_value = args.value_at(1);
    const expanded = if (args.has('F') and raw_value != null) blk: {
        const ctx = format_mod.FormatContext{
            .item = @ptrCast(item),
            .client = cmdq.cmdq_get_client(item),
            .session = target.session,
            .winlink = target.winlink,
            .window = target.window,
            .pane = target.pane,
        };
        break :blk cmd_format.require(item, raw_value.?, &ctx) orelse return .@"error";
    } else null;
    defer if (expanded) |value| xm.allocator.free(value);
    const value = expanded orelse raw_value;

    if (args.has('a') and oe != null and oe.?.type != .string and oe.?.type != .style and oe.?.type != .array) {
        cmdq.cmdq_error(item, "-a only supported for string and array options", .{});
        return .@"error";
    }

    if (!validate_command_option_value(oe, value, &cause)) {
        if (args.has('q')) return .normal;
        cmdq.cmdq_error(item, "{s}", .{cause orelse "invalid option value"});
        return .@"error";
    }

    if (!opts.options_set_from_string(target.options, oe, option_name, idx, value, args.has('a'), &cause)) {
        if (args.has('q')) return .normal;
        cmdq.cmdq_error(item, "{s}", .{cause orelse "invalid option value"});
        return .@"error";
    }
    cmd_opts.apply_target_side_effects(target, option_name);
    return .normal;
}

fn option_is_set_locally(oo: *T.Options, name: []const u8, idx: ?u32) bool {
    const value = opts.options_get_only(oo, name) orelse return false;
    if (idx) |array_idx| return opts.options_array_get_value(value, array_idx) != null;
    return true;
}

fn unset_option(
    target: cmd_opts.ResolvedTarget,
    name: []const u8,
    oe: ?*const T.OptionsTableEntry,
    idx: ?u32,
    cause: *?[]u8,
) bool {
    return opts.options_remove_or_default(target.options, oe, name, idx, target.global, cause);
}

fn clear_window_option_overrides(
    target: cmd_opts.ResolvedTarget,
    name: []const u8,
    oe: ?*const T.OptionsTableEntry,
    idx: ?u32,
    cause: *?[]u8,
) bool {
    const w = target.window orelse return true;
    for (w.panes.items) |wp| {
        if (opts.options_get_only(wp.options, name) == null) continue;
        if (!opts.options_remove_or_default(wp.options, oe, name, idx, false, cause)) return false;
        win.window_pane_options_changed(wp, name);
    }
    return true;
}

fn validate_command_option_value(
    oe: ?*const T.OptionsTableEntry,
    value: ?[]const u8,
    cause: *?[]u8,
) bool {
    if (oe == null or oe.?.type != .command) return true;

    const command = value orelse {
        cause.* = xm.xstrdup("empty value");
        return false;
    };

    var parse_input = T.CmdParseInput{};
    const parsed = cmd_mod.cmd_parse_from_string(command, &parse_input);
    switch (parsed.status) {
        .success => {
            if (parsed.cmdlist) |cmdlist|
                cmd_mod.cmd_list_free(@ptrCast(@alignCast(cmdlist)));
            return true;
        },
        .@"error" => {
            cause.* = parsed.@"error" orelse xm.xstrdup("parse error");
            return false;
        },
    }
}

pub const entry: cmd_mod.CmdEntry = .{
    .name = "set-option",
    .alias = "set",
    .usage = "[-aFgopqsuUw] [-t target] option [value]",
    .template = "aFgopqst:uUw",
    .lower = 1,
    .upper = 2,
    .flags = T.CMD_STARTSERVER | T.CMD_AFTERHOOK,
    .exec = exec,
};

pub const entry_window: cmd_mod.CmdEntry = .{
    .name = "set-window-option",
    .alias = "setw",
    .usage = "[-aFgoqu] [-t target-window] option [value]",
    .template = "aFgoqt:u",
    .lower = 1,
    .upper = 2,
    .flags = T.CMD_STARTSERVER | T.CMD_AFTERHOOK,
    .exec = exec,
};

pub const entry_hook: cmd_mod.CmdEntry = .{
    .name = "set-hook",
    .usage = "[-agpRuw] [-t target-pane] hook [command]",
    .template = "agpRt:uw",
    .lower = 1,
    .upper = 2,
    .flags = T.CMD_STARTSERVER | T.CMD_AFTERHOOK,
    .exec = exec,
};

const CapturedStderr = struct {
    retval: T.CmdRetval,
    stderr: []u8,
};

fn capture_stderr(argv: []const []const u8) !CapturedStderr {
    var stderr_pipe: [2]i32 = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.pipe(&stderr_pipe));
    defer {
        std.posix.close(stderr_pipe[0]);
        if (stderr_pipe[1] != -1) std.posix.close(stderr_pipe[1]);
    }

    const stderr_dup = try std.posix.dup(std.posix.STDERR_FILENO);
    defer std.posix.close(stderr_dup);

    try std.posix.dup2(stderr_pipe[1], std.posix.STDERR_FILENO);
    defer std.posix.dup2(stderr_dup, std.posix.STDERR_FILENO) catch {};

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(argv, null, &cause);
    defer cmd_mod.cmd_free(cmd);
    defer if (cause) |msg| xm.allocator.free(msg);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    const retval = cmd_mod.cmd_execute(cmd, &item);

    try std.posix.dup2(stderr_dup, std.posix.STDERR_FILENO);
    std.posix.close(stderr_pipe[1]);
    stderr_pipe[1] = -1;

    var out: std.ArrayList(u8) = .{};
    errdefer out.deinit(xm.allocator);
    var buf: [256]u8 = undefined;
    while (true) {
        const n = try std.posix.read(stderr_pipe[0], &buf);
        if (n == 0) break;
        try out.appendSlice(xm.allocator, buf[0..n]);
    }

    return .{
        .retval = retval,
        .stderr = try out.toOwnedSlice(xm.allocator),
    };
}

test "set-option -p stores pane local custom options and updates consumers" {
    const sess = @import("session.zig");
    const colour_mod = @import("colour.zig");
    const env_mod = @import("environ.zig");

    sess.session_init_globals(xm.allocator);
    win.window_init_globals(xm.allocator);

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

    const session_opts = opts.options_create(opts.global_s_options);
    const session_env = env_mod.environ_create();
    const s = sess.session_create(null, "pane-test", "/", session_env, session_opts, null);
    defer sess.session_destroy(s, false, "test");

    const w = win.window_create(80, 24, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    var attach_cause: ?[]u8 = null;
    const wl = sess.session_attach(s, w, -1, &attach_cause).?;
    _ = wl;
    const wp = win.window_add_pane(w, null, 80, 24);
    w.active = wp;
    s.curw = sess.winlink_find_by_window(&s.windows, w).?;

    const target = xm.xasprintf("%{d}", .{wp.id});
    defer xm.allocator.free(target);

    var cause: ?[]u8 = null;
    const set_custom = try cmd_mod.cmd_parse_one(&.{ "set-option", "-p", "-t", target, "@flavour", "vanilla" }, null, &cause);
    defer cmd_mod.cmd_free(set_custom);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(set_custom, &item));
    try std.testing.expectEqualStrings("vanilla", opts.options_get_string(wp.options, "@flavour"));

    const set_style = try cmd_mod.cmd_parse_one(&.{ "set-option", "-p", "-t", target, "pane-scrollbars-style", "fg=blue,pad=6" }, null, &cause);
    defer cmd_mod.cmd_free(set_style);
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(set_style, &item));
    try std.testing.expectEqual(@as(i32, 6), wp.scrollbar_style.pad);
    try std.testing.expectEqual(@as(i32, 4), wp.scrollbar_style.gc.fg);

    const set_palette = try cmd_mod.cmd_parse_one(&.{ "set-option", "-p", "-t", target, "pane-colours", "1=#020304" }, null, &cause);
    defer cmd_mod.cmd_free(set_palette);
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(set_palette, &item));
    try std.testing.expectEqual(colour_mod.colour_join_rgb(0x02, 0x03, 0x04), colour_mod.colour_palette_get(&wp.palette, 1));
}

test "set-option -p stores pane local copy-mode position format overrides" {
    const sess = @import("session.zig");
    const env_mod = @import("environ.zig");

    sess.session_init_globals(xm.allocator);
    win.window_init_globals(xm.allocator);

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

    const session_opts = opts.options_create(opts.global_s_options);
    const session_env = env_mod.environ_create();
    const s = sess.session_create(null, "copy-mode-position-format", "/", session_env, session_opts, null);
    defer sess.session_destroy(s, false, "test");

    const w = win.window_create(80, 24, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    var attach_cause: ?[]u8 = null;
    _ = sess.session_attach(s, w, -1, &attach_cause).?;
    const wp = win.window_add_pane(w, null, 80, 24);
    w.active = wp;
    s.curw = sess.winlink_find_by_window(&s.windows, w).?;

    const target = try std.fmt.allocPrint(xm.allocator, "%{d}", .{wp.id});
    defer xm.allocator.free(target);

    const before = opts.options_get_string(wp.options, "copy-mode-position-format");
    try std.testing.expectEqualStrings(
        "#[align=right]#{t/p:top_line_time}#{?#{e|>:#{top_line_time},0}, ,}[#{scroll_position}/#{history_size}]#{?search_timed_out, (timed out),#{?search_count, (#{search_count}#{?search_count_partial,+,} results),}}",
        before,
    );

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "set-option", "-p", "-t", target, "copy-mode-position-format", "#[align=left]#{scroll_position}" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);
    defer if (cause) |msg| xm.allocator.free(msg);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));
    try std.testing.expectEqualStrings("#[align=left]#{scroll_position}", opts.options_get_string(wp.options, "copy-mode-position-format"));
    try std.testing.expectEqualStrings(
        "#[align=right]#{t/p:top_line_time}#{?#{e|>:#{top_line_time},0}, ,}[#{scroll_position}/#{history_size}]#{?search_timed_out, (timed out),#{?search_count, (#{search_count}#{?search_count_partial,+,} results),}}",
        opts.options_get_string(w.options, "copy-mode-position-format"),
    );
}

test "set-option -gp ignores -g for pane custom options" {
    const sess = @import("session.zig");
    const env_mod = @import("environ.zig");

    sess.session_init_globals(xm.allocator);
    win.window_init_globals(xm.allocator);

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

    const session_opts = opts.options_create(opts.global_s_options);
    const session_env = env_mod.environ_create();
    const s = sess.session_create(null, "set-gp-pane", "/", session_env, session_opts, null);
    defer sess.session_destroy(s, false, "test");

    const w = win.window_create(80, 24, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    var attach_cause: ?[]u8 = null;
    _ = sess.session_attach(s, w, -1, &attach_cause).?;
    const wp = win.window_add_pane(w, null, 80, 24);
    w.active = wp;
    s.curw = sess.winlink_find_by_window(&s.windows, w).?;

    const target = try std.fmt.allocPrint(xm.allocator, "%{d}", .{wp.id});
    defer xm.allocator.free(target);

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "set-option", "-g", "-p", "-t", target, "@sticky", "yes" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);
    defer if (cause) |msg| xm.allocator.free(msg);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));
    try std.testing.expectEqualStrings("yes", opts.options_get_string(wp.options, "@sticky"));
}

test "set-option stores session hook options" {
    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "set-option", "-g", "after-show-options", "display-message hi" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);
    defer if (cause) |msg| xm.allocator.free(msg);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));
    const hook = opts.options_get_array_items(opts.global_s_options, "after-show-options");
    try std.testing.expectEqual(@as(usize, 1), hook.len);
    try std.testing.expectEqual(@as(u32, 0), hook[0].index);
    try std.testing.expectEqualStrings("display-message hi", hook[0].value);
}

test "set-option stores validated server command options" {
    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "set-option", "-s", "default-client-command", "display-message hi" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);
    defer if (cause) |msg| xm.allocator.free(msg);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));
    try std.testing.expectEqualStrings("display-message hi", opts.options_get_command_string(opts.global_options, "default-client-command"));
}

test "set-option rejects invalid server command option syntax" {
    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);

    const result = try capture_stderr(&.{ "set-option", "-s", "default-client-command", "display-message \"unterminated" });
    defer xm.allocator.free(result.stderr);

    try std.testing.expectEqual(T.CmdRetval.@"error", result.retval);
    try std.testing.expect(std.mem.containsAtLeast(u8, result.stderr, 1, "unterminated quote"));
    try std.testing.expectEqualStrings("new-session", opts.options_get_command_string(opts.global_options, "default-client-command"));
}

test "set-hook stores window-scoped hooks in global window options" {
    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "set-hook", "-g", "pane-focus-out", "display-message bye" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);
    defer if (cause) |msg| xm.allocator.free(msg);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));
    const hook = opts.options_get_array_items(opts.global_w_options, "pane-focus-out");
    try std.testing.expectEqual(@as(usize, 1), hook.len);
    try std.testing.expectEqual(@as(u32, 0), hook[0].index);
    try std.testing.expectEqualStrings("display-message bye", hook[0].value);
}

test "set-hook rejects non-hook options" {
    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "set-hook", "-g", "status-left", "nope" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);
    defer if (cause) |msg| xm.allocator.free(msg);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.@"error", cmd_mod.cmd_execute(cmd, &item));
}

test "set-hook -R runs the stored hook immediately" {
    const env_mod = @import("environ.zig");
    const sess = @import("session.zig");
    cmdq.cmdq_reset_for_tests();
    defer cmdq.cmdq_reset_for_tests();

    sess.session_init_globals(xm.allocator);
    win.window_init_globals(xm.allocator);

    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    opts.options_set_array(opts.global_s_options, "after-show-options", &.{
        "set-environment -g HOOK_RESULT fired",
    });

    env_mod.global_environ = env_mod.environ_create();
    defer env_mod.environ_free(env_mod.global_environ);

    var cause: ?[]u8 = null;
    const list = try cmd_mod.cmd_parse_from_argv_with_cause(&.{ "set-hook", "-R", "after-show-options" }, null, &cause);
    defer if (cause) |msg| xm.allocator.free(msg);

    cmdq.cmdq_append(null, list);
    try std.testing.expectEqual(@as(u32, 2), cmdq.cmdq_next(null));
    try std.testing.expectEqualStrings("fired", env_mod.environ_find(env_mod.global_environ, "HOOK_RESULT").?.value.?);
}

test "set-option preserves explicit array indexes and appends at the first free slot" {
    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);

    var cause: ?[]u8 = null;
    const indexed = try cmd_mod.cmd_parse_one(&.{ "set-option", "-g", "after-show-options[3]", "display-message high" }, null, &cause);
    defer cmd_mod.cmd_free(indexed);
    const appended = try cmd_mod.cmd_parse_one(&.{ "set-option", "-ag", "after-show-options", "display-message low" }, null, &cause);
    defer cmd_mod.cmd_free(appended);
    defer if (cause) |msg| xm.allocator.free(msg);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(indexed, &item));
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(appended, &item));

    const hook = opts.options_get_array_items(opts.global_s_options, "after-show-options");
    try std.testing.expectEqual(@as(usize, 2), hook.len);
    try std.testing.expectEqual(@as(u32, 0), hook[0].index);
    try std.testing.expectEqualStrings("display-message low", hook[0].value);
    try std.testing.expectEqual(@as(u32, 3), hook[1].index);
    try std.testing.expectEqualStrings("display-message high", hook[1].value);
}

test "set-option -o checks indexed array elements independently" {
    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);

    var cause: ?[]u8 = null;
    const first = try cmd_mod.cmd_parse_one(&.{ "set-option", "-go", "after-show-options[2]", "display-message first" }, null, &cause);
    defer cmd_mod.cmd_free(first);
    const second = try cmd_mod.cmd_parse_one(&.{ "set-option", "-go", "after-show-options[2]", "display-message second" }, null, &cause);
    defer cmd_mod.cmd_free(second);
    const other = try cmd_mod.cmd_parse_one(&.{ "set-option", "-go", "after-show-options[1]", "display-message other" }, null, &cause);
    defer cmd_mod.cmd_free(other);
    defer if (cause) |msg| xm.allocator.free(msg);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(first, &item));
    try std.testing.expectEqual(T.CmdRetval.@"error", cmd_mod.cmd_execute(second, &item));
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(other, &item));

    const hook = opts.options_get_array_items(opts.global_s_options, "after-show-options");
    try std.testing.expectEqual(@as(usize, 2), hook.len);
    try std.testing.expectEqual(@as(u32, 1), hook[0].index);
    try std.testing.expectEqual(@as(u32, 2), hook[1].index);
}

test "set-option -u removes a single indexed array element" {
    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);

    var cause: ?[]u8 = null;
    const first = try cmd_mod.cmd_parse_one(&.{ "set-option", "-g", "after-show-options[0]", "display-message zero" }, null, &cause);
    defer cmd_mod.cmd_free(first);
    const second = try cmd_mod.cmd_parse_one(&.{ "set-option", "-g", "after-show-options[3]", "display-message three" }, null, &cause);
    defer cmd_mod.cmd_free(second);
    const unset = try cmd_mod.cmd_parse_one(&.{ "set-option", "-gu", "after-show-options[0]" }, null, &cause);
    defer cmd_mod.cmd_free(unset);
    defer if (cause) |msg| xm.allocator.free(msg);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(first, &item));
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(second, &item));
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(unset, &item));

    const hook = opts.options_get_array_items(opts.global_s_options, "after-show-options");
    try std.testing.expectEqual(@as(usize, 1), hook.len);
    try std.testing.expectEqual(@as(u32, 3), hook[0].index);
    try std.testing.expectEqualStrings("display-message three", hook[0].value);
}

test "set-option rejects indexes on non-array options" {
    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);

    var cause: ?[]u8 = null;
    const builtin = try cmd_mod.cmd_parse_one(&.{ "set-option", "-g", "status-left[0]", "bad" }, null, &cause);
    defer cmd_mod.cmd_free(builtin);
    const custom = try cmd_mod.cmd_parse_one(&.{ "set-option", "@local[1]", "bad" }, null, &cause);
    defer cmd_mod.cmd_free(custom);
    defer if (cause) |msg| xm.allocator.free(msg);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.@"error", cmd_mod.cmd_execute(builtin, &item));
    try std.testing.expectEqual(T.CmdRetval.@"error", cmd_mod.cmd_execute(custom, &item));
}

test "set-option -w -U clears pane local overrides before unsetting window options" {
    const sess = @import("session.zig");
    const env_mod = @import("environ.zig");

    sess.session_init_globals(xm.allocator);
    win.window_init_globals(xm.allocator);

    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    opts.options_set_string(opts.global_w_options, false, "pane-scrollbars-style", "fg=red,pad=2");

    env_mod.global_environ = env_mod.environ_create();
    defer env_mod.environ_free(env_mod.global_environ);

    const session_opts = opts.options_create(opts.global_s_options);
    const session_env = env_mod.environ_create();
    const s = sess.session_create(null, "unset-window-override", "/", session_env, session_opts, null);
    defer sess.session_destroy(s, false, "test");

    const w = win.window_create(80, 24, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    var attach_cause: ?[]u8 = null;
    _ = sess.session_attach(s, w, -1, &attach_cause).?;
    const pane_with_override = win.window_add_pane(w, null, 80, 24);
    const inherited_pane = win.window_add_pane(w, null, 80, 24);
    w.active = pane_with_override;
    s.curw = sess.winlink_find_by_window(&s.windows, w).?;

    opts.options_set_string(w.options, false, "pane-scrollbars-style", "fg=blue,pad=5");
    win.window_pane_options_changed(pane_with_override, "pane-scrollbars-style");
    win.window_pane_options_changed(inherited_pane, "pane-scrollbars-style");
    opts.options_set_string(pane_with_override.options, false, "pane-scrollbars-style", "fg=yellow,pad=7");
    win.window_pane_options_changed(pane_with_override, "pane-scrollbars-style");

    try std.testing.expectEqual(@as(i32, 7), pane_with_override.scrollbar_style.pad);
    try std.testing.expectEqual(@as(i32, 5), inherited_pane.scrollbar_style.pad);

    const target = try std.fmt.allocPrint(xm.allocator, "@{d}", .{w.id});
    defer xm.allocator.free(target);

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "set-option", "-w", "-U", "-t", target, "pane-scrollbars-style" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));

    try std.testing.expect(opts.options_get_only(w.options, "pane-scrollbars-style") == null);
    try std.testing.expect(opts.options_get_only(pane_with_override.options, "pane-scrollbars-style") == null);
    try std.testing.expectEqual(@as(i32, 2), pane_with_override.scrollbar_style.pad);
    try std.testing.expectEqual(@as(i32, 2), inherited_pane.scrollbar_style.pad);
}

test "set-option -o allows the first local override and rejects a second write" {
    const sess = @import("session.zig");
    const env_mod = @import("environ.zig");
    const server = @import("server.zig");

    sess.session_init_globals(xm.allocator);
    win.window_init_globals(xm.allocator);

    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    opts.options_set_string(opts.global_s_options, false, "status-left", "global left");
    server.server_reset_message_log();
    defer server.server_reset_message_log();

    env_mod.global_environ = env_mod.environ_create();
    defer env_mod.environ_free(env_mod.global_environ);

    const session_opts = opts.options_create(opts.global_s_options);
    const session_env = env_mod.environ_create();
    const s = sess.session_create(null, "set-option-o", "/", session_env, session_opts, null);
    defer sess.session_destroy(s, false, "test");
    const w = win.window_create(80, 24, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    var attach_cause: ?[]u8 = null;
    _ = sess.session_attach(s, w, -1, &attach_cause).?;
    const wp = win.window_add_pane(w, null, 80, 24);
    w.active = wp;
    s.curw = sess.winlink_find_by_window(&s.windows, w).?;

    var cause: ?[]u8 = null;
    const first = try cmd_mod.cmd_parse_one(&.{ "set-option", "-o", "status-left", "local left" }, null, &cause);
    defer cmd_mod.cmd_free(first);
    const second = try cmd_mod.cmd_parse_one(&.{ "set-option", "-o", "status-left", "second left" }, null, &cause);
    defer cmd_mod.cmd_free(second);

    var list: cmd_mod.CmdList = .{};
    var state = cmdq.CmdqState{
        .current = .{
            .s = s,
            .wl = s.curw,
            .idx = s.curw.?.idx,
            .w = w,
            .wp = wp,
        },
    };
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list, .state = &state };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(first, &item));
    try std.testing.expectEqualStrings("local left", opts.options_get_string(s.options, "status-left"));

    try std.testing.expectEqual(T.CmdRetval.@"error", cmd_mod.cmd_execute(second, &item));
    try std.testing.expectEqualStrings("local left", opts.options_get_string(s.options, "status-left"));
}

test "set-option -qo leaves an existing local value untouched" {
    const sess = @import("session.zig");
    const env_mod = @import("environ.zig");
    const server = @import("server.zig");

    sess.session_init_globals(xm.allocator);
    win.window_init_globals(xm.allocator);

    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    server.server_reset_message_log();
    defer server.server_reset_message_log();

    env_mod.global_environ = env_mod.environ_create();
    defer env_mod.environ_free(env_mod.global_environ);

    const session_opts = opts.options_create(opts.global_s_options);
    const session_env = env_mod.environ_create();
    const s = sess.session_create(null, "set-option-qo", "/", session_env, session_opts, null);
    defer sess.session_destroy(s, false, "test");
    const w = win.window_create(80, 24, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    var attach_cause: ?[]u8 = null;
    _ = sess.session_attach(s, w, -1, &attach_cause).?;
    const wp = win.window_add_pane(w, null, 80, 24);
    w.active = wp;
    s.curw = sess.winlink_find_by_window(&s.windows, w).?;
    opts.options_set_string(s.options, false, "status-left", "present");

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "set-option", "-q", "-o", "status-left", "ignored" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var state = cmdq.CmdqState{
        .current = .{
            .s = s,
            .wl = s.curw,
            .idx = s.curw.?.idx,
            .w = w,
            .wp = wp,
        },
    };
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list, .state = &state };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));
    try std.testing.expectEqualStrings("present", opts.options_get_string(s.options, "status-left"));
    try std.testing.expectEqual(@as(usize, 0), server.message_log.items.len);
}

test "set-option rejects ambiguous option prefixes before scope resolution" {
    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);

    const result = try capture_stderr(&.{ "set-option", "-g", "status-l", "ambiguous" });
    defer xm.allocator.free(result.stderr);

    try std.testing.expectEqual(T.CmdRetval.@"error", result.retval);
    try std.testing.expectEqualStrings("ambiguous option: status-l\n", result.stderr);
    try std.testing.expectEqualStrings("[#{session_name}] ", opts.options_get_string(opts.global_s_options, "status-left"));
}

test "set-window-option exact matches win over longer prefixed names" {
    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    win.window_init_globals(xm.allocator);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "set-window-option", "-g", "automatic-rename", "off" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);
    defer if (cause) |msg| xm.allocator.free(msg);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));
    try std.testing.expectEqual(@as(i64, 0), opts.options_get_number(opts.global_w_options, "automatic-rename"));
    try std.testing.expectEqualStrings(
        "#{?pane_in_mode,[zmux],#{pane_current_command}}#{?pane_dead,dead,}",
        opts.options_get_string(opts.global_w_options, "automatic-rename-format"),
    );
}

test "set-option accepts tty compatibility options across scopes" {
    const sess = @import("session.zig");
    const env_mod = @import("environ.zig");

    sess.session_init_globals(xm.allocator);
    win.window_init_globals(xm.allocator);

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

    const session = sess.session_create(null, "set-option-tty-compat", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer sess.session_destroy(session, false, "test");

    const window = win.window_create(80, 24, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    var attach_cause: ?[]u8 = null;
    const wl = sess.session_attach(session, window, 0, &attach_cause).?;
    session.curw = wl;
    const pane = win.window_add_pane(window, null, 80, 24);
    window.active = pane;

    const pane_target = try std.fmt.allocPrint(xm.allocator, "%{d}", .{pane.id});
    defer xm.allocator.free(pane_target);

    var cause: ?[]u8 = null;
    defer if (cause) |msg| xm.allocator.free(msg);

    var list: cmd_mod.CmdList = .{};
    var state = cmdq.CmdqState{
        .current = .{
            .s = session,
            .wl = wl,
            .idx = wl.idx,
            .w = window,
            .wp = pane,
        },
    };
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list, .state = &state };

    const set_get_clipboard = try cmd_mod.cmd_parse_one(&.{ "set-option", "-g", "get-clipboard", "both" }, null, &cause);
    defer cmd_mod.cmd_free(set_get_clipboard);
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(set_get_clipboard, &item));
    try std.testing.expectEqual(@as(i64, 3), opts.options_get_number(opts.global_options, "get-clipboard"));

    const set_input_buffer_size = try cmd_mod.cmd_parse_one(&.{ "set-option", "-g", "input-buffer-size", "1048576" }, null, &cause);
    defer cmd_mod.cmd_free(set_input_buffer_size);
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(set_input_buffer_size, &item));
    try std.testing.expectEqual(@as(i64, 1048576), opts.options_get_number(opts.global_options, "input-buffer-size"));

    const set_prefix_timeout = try cmd_mod.cmd_parse_one(&.{ "set-option", "-g", "prefix-timeout", "123" }, null, &cause);
    defer cmd_mod.cmd_free(set_prefix_timeout);
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(set_prefix_timeout, &item));
    try std.testing.expectEqual(@as(i64, 123), opts.options_get_number(opts.global_options, "prefix-timeout"));

    const set_initial_repeat_time = try cmd_mod.cmd_parse_one(&.{ "set-option", "initial-repeat-time", "250" }, null, &cause);
    defer cmd_mod.cmd_free(set_initial_repeat_time);
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(set_initial_repeat_time, &item));
    try std.testing.expectEqual(@as(i64, 250), opts.options_get_number(session.options, "initial-repeat-time"));

    const set_allow_set_title = try cmd_mod.cmd_parse_one(&.{ "set-window-option", "allow-set-title", "off" }, null, &cause);
    defer cmd_mod.cmd_free(set_allow_set_title);
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(set_allow_set_title, &item));
    try std.testing.expectEqual(@as(i64, 0), opts.options_get_number(window.options, "allow-set-title"));

    const set_cursor_style = try cmd_mod.cmd_parse_one(&.{ "set-option", "-p", "-t", pane_target, "cursor-style", "blinking-bar" }, null, &cause);
    defer cmd_mod.cmd_free(set_cursor_style);
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(set_cursor_style, &item));
    try std.testing.expectEqual(@as(i64, 5), opts.options_get_number(pane.options, "cursor-style"));

    const set_xterm_keys = try cmd_mod.cmd_parse_one(&.{ "set-window-option", "-g", "xterm-keys", "off" }, null, &cause);
    defer cmd_mod.cmd_free(set_xterm_keys);
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(set_xterm_keys, &item));
    try std.testing.expectEqual(@as(i64, 0), opts.options_get_number(opts.global_w_options, "xterm-keys"));
}

test "set-option -a appends to existing string options" {
    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    opts.options_set_string(opts.global_s_options, false, "status-right", "prefix");

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "set-option", "-ag", "status-right", " suffix" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);
    defer if (cause) |msg| xm.allocator.free(msg);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));
    try std.testing.expectEqualStrings("prefix suffix", opts.options_get_string(opts.global_s_options, "status-right"));
}

test "set-window-option marks active panes changed when automatic rename is enabled globally" {
    const sess = @import("session.zig");
    const env_mod = @import("environ.zig");

    sess.session_init_globals(xm.allocator);
    win.window_init_globals(xm.allocator);

    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    opts.options_set_number(opts.global_w_options, "automatic-rename", 0);

    env_mod.global_environ = env_mod.environ_create();
    defer env_mod.environ_free(env_mod.global_environ);

    const session = sess.session_create(null, "set-window-option-automatic-rename", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer sess.session_destroy(session, false, "test");

    const window = win.window_create(80, 24, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    var attach_cause: ?[]u8 = null;
    const wl = sess.session_attach(session, window, 0, &attach_cause).?;
    session.curw = wl;
    const pane = win.window_add_pane(window, null, 80, 24);
    window.active = pane;
    pane.flags &= ~@as(u32, T.PANE_CHANGED);

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "set-window-option", "-g", "automatic-rename", "on" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);
    defer if (cause) |msg| xm.allocator.free(msg);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));
    try std.testing.expectEqual(@as(i64, 1), opts.options_get_number(opts.global_w_options, "automatic-rename"));
    try std.testing.expect(pane.flags & T.PANE_CHANGED != 0);
}
