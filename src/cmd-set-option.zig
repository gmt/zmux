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
// Ported in part from tmux/cmd-set-option.c.
// Original copyright:
//   Copyright (c) 2007 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const cmd_mod = @import("cmd.zig");
const cmd_format = @import("cmd-format.zig");
const cmdq = @import("cmd-queue.zig");
const opts = @import("options.zig");
const format_mod = @import("format.zig");
const cmd_opts = @import("cmd-options.zig");
const win = @import("window.zig");

fn exec(cmd: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {
    const args = cmd_mod.cmd_get_args(cmd);
    if (args.has('o')) {
        cmdq.cmdq_error(item, "-o not supported yet", .{});
        return .@"error";
    }
    if (args.has('U')) {
        cmdq.cmdq_error(item, "-U not supported yet", .{});
        return .@"error";
    }

    const option_name = args.value_at(0) orelse {
        cmdq.cmdq_error(item, "invalid option", .{});
        return .@"error";
    };
    const oe = opts.options_table_entry(option_name);
    const custom = cmd_opts.is_custom_option(option_name);
    if (oe == null and !custom) {
        if (args.has('q')) return .normal;
        cmdq.cmdq_error(item, "invalid option: {s}", .{option_name});
        return .@"error";
    }

    const target = cmd_opts.resolve_target(item, args, cmd.entry == &entry_window) orelse return .@"error";
    if (!cmd_opts.option_allowed(oe, target.kind)) {
        if (args.has('q')) return .normal;
        cmdq.cmdq_error(item, "invalid option: {s}", .{option_name});
        return .@"error";
    }

    if (args.has('u')) {
        unset_option(target, option_name, oe);
        apply_target_side_effects(target, option_name);
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

    if (args.has('a') and oe != null and oe.?.@"type" != .string and oe.?.@"type" != .style and oe.?.@"type" != .array) {
        cmdq.cmdq_error(item, "-a only supported for string and array options", .{});
        return .@"error";
    }

    var cause: ?[]u8 = null;
    defer if (cause) |msg| xm.allocator.free(msg);
    if (!opts.options_set_from_string(target.options, oe, option_name, value, args.has('a'), &cause)) {
        if (args.has('q')) return .normal;
        cmdq.cmdq_error(item, "{s}", .{cause orelse "invalid option value"});
        return .@"error";
    }
    apply_target_side_effects(target, option_name);
    return .normal;
}

fn unset_option(target: cmd_opts.ResolvedTarget, name: []const u8, oe: ?*const T.OptionsTableEntry) void {
    if (oe == null) {
        opts.options_remove(target.options, name);
        return;
    }
    if (target.global) {
        opts.options_remove(target.options, name);
        opts.options_default(target.options, oe.?);
    } else {
        opts.options_remove(target.options, name);
    }
}

fn apply_target_side_effects(target: cmd_opts.ResolvedTarget, name: []const u8) void {
    if (target.pane) |wp| {
        win.window_pane_options_changed(wp, name);
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
