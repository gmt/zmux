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
// Ported in part from tmux/cmd-display-menu.c.
// Original copyright:
//   Copyright (c) 2019 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

const std = @import("std");
const T = @import("types.zig");
const args_mod = @import("arguments.zig");
const cmd_display_panes = @import("cmd-display-panes.zig");
const cmd_find = @import("cmd-find.zig");
const cmd_mod = @import("cmd.zig");
const cmdq = @import("cmd-queue.zig");
const opts = @import("options.zig");
const xm = @import("xmalloc.zig");

const ValidationResult = enum {
    ok,
    noop,
    err,
};

fn require_target_client(item: *cmdq.CmdqItem) ?*T.Client {
    const tc = cmdq.cmdq_get_target_client(item) orelse {
        cmdq.cmdq_error(item, "no target client", .{});
        return null;
    };
    if (tc.session == null) {
        cmdq.cmdq_error(item, "no target client", .{});
        return null;
    }
    return tc;
}

fn resolve_target(item: *cmdq.CmdqItem, target_name: ?[]const u8) ?T.CmdFindState {
    var target: T.CmdFindState = .{};
    if (cmd_find.cmd_find_target(&target, item, target_name, .pane, T.CMD_FIND_CANFAIL) != 0)
        return null;
    return target;
}

fn validate_choice(item: *cmdq.CmdqItem, option_name: []const u8, value: []const u8) bool {
    const oe = opts.options_table_entry(option_name) orelse {
        cmdq.cmdq_error(item, "{s} is unavailable", .{option_name});
        return false;
    };
    const idx = opts.options_choice_index(oe, value) orelse {
        cmdq.cmdq_error(item, "{s} invalid choice: {s}", .{ option_name, value });
        return false;
    };
    if (oe.choices) |choices| {
        if (idx >= choices.len) {
            cmdq.cmdq_error(item, "{s} invalid choice: {s}", .{ option_name, value });
            return false;
        }
    }
    return true;
}

fn validate_display_menu(args: *const args_mod.Arguments, item: *cmdq.CmdqItem) ValidationResult {
    if (args.has('C')) {
        const value = args.get('C').?;
        if (!std.mem.eql(u8, value, "-")) {
            var cause: ?[]u8 = null;
            _ = args_mod.args_strtonum(args, 'C', 0, std.math.maxInt(u32), &cause);
            if (cause) |msg| {
                defer xm.allocator.free(msg);
                cmdq.cmdq_error(item, "starting choice {s}", .{msg});
                return .err;
            }
        }
    }

    var count: usize = 0;
    var i: usize = 0;
    while (i < args.count()) {
        const name = args.value_at(i).?;
        i += 1;
        if (name.len == 0)
            continue;

        count += 1;
        if (args.count() - i < 2) {
            cmdq.cmdq_error(item, "not enough arguments", .{});
            return .err;
        }
        i += 2;
    }

    if (count == 0)
        return .noop;

    if (args.get('b')) |value| {
        if (!validate_choice(item, "menu-border-lines", value))
            return .err;
    }

    return .ok;
}

fn validate_display_popup(args: *const args_mod.Arguments, item: *cmdq.CmdqItem, tc: *T.Client) bool {
    if (args.has('h')) {
        var cause: ?[]u8 = null;
        _ = args_mod.args_percentage(args, 'h', 1, tc.tty.sy, tc.tty.sy, &cause);
        if (cause) |msg| {
            defer xm.allocator.free(msg);
            cmdq.cmdq_error(item, "height {s}", .{msg});
            return false;
        }
    }

    if (args.has('w')) {
        var cause: ?[]u8 = null;
        _ = args_mod.args_percentage(args, 'w', 1, tc.tty.sx, tc.tty.sx, &cause);
        if (cause) |msg| {
            defer xm.allocator.free(msg);
            cmdq.cmdq_error(item, "width {s}", .{msg});
            return false;
        }
    }

    if (!args.has('B')) {
        if (args.get('b')) |value| {
            if (!validate_choice(item, "popup-border-lines", value))
                return false;
        }
    }

    return true;
}

fn exec_display_menu(cmd: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {
    const args = cmd_mod.cmd_get_args(cmd);
    _ = resolve_target(item, args.get('t')) orelse return .@"error";
    const tc = require_target_client(item) orelse return .@"error";

    if (cmd_display_panes.overlay_active(tc))
        return .normal;

    switch (validate_display_menu(args, item)) {
        .err => return .@"error",
        .noop => return .normal,
        .ok => {},
    }

    cmdq.cmdq_error(item, "display-menu overlay not supported yet", .{});
    return .@"error";
}

fn exec_display_popup(cmd: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {
    const args = cmd_mod.cmd_get_args(cmd);
    if (args.has('C'))
        return .normal;

    _ = resolve_target(item, args.get('t')) orelse return .@"error";
    const tc = require_target_client(item) orelse return .@"error";

    if (cmd_display_panes.overlay_active(tc))
        return .normal;

    if (!validate_display_popup(args, item, tc))
        return .@"error";

    cmdq.cmdq_error(item, "display-popup overlay not supported yet", .{});
    return .@"error";
}

pub const entry: cmd_mod.CmdEntry = .{
    .name = "display-menu",
    .alias = "menu",
    .usage = "[-MO] [-b border-lines] [-c target-client] [-C starting-choice] [-H selected-style] [-s style] [-S border-style] [-t target-pane] [-T title] [-x position] [-y position] name [key] [command] ...",
    .template = "b:c:C:H:s:S:MOt:T:x:y:",
    .lower = 1,
    .upper = -1,
    .flags = T.CMD_AFTERHOOK | T.CMD_CLIENT_CFLAG,
    .exec = exec_display_menu,
};

pub const entry_popup: cmd_mod.CmdEntry = .{
    .name = "display-popup",
    .alias = "popup",
    .usage = "[-BCEkN] [-b border-lines] [-c target-client] [-d start-directory] [-e environment] [-h height] [-s style] [-S border-style] [-t target-pane] [-T title] [-w width] [-x position] [-y position] [shell-command [argument ...]]",
    .template = "Bb:Cc:d:e:Eh:kNs:S:t:T:w:x:y:",
    .lower = 0,
    .upper = -1,
    .flags = T.CMD_AFTERHOOK | T.CMD_CLIENT_CFLAG,
    .exec = exec_display_popup,
};

fn test_setup(name: []const u8) struct {
    session: *T.Session,
    window: *T.Window,
    client: T.Client,
} {
    const env_mod = @import("environ.zig");
    const opts_mod = @import("options.zig");
    const sess = @import("session.zig");
    const win = @import("window.zig");

    sess.session_init_globals(xm.allocator);
    win.window_init_globals(xm.allocator);

    opts_mod.global_options = opts_mod.options_create(null);
    opts_mod.options_default_all(opts_mod.global_options, T.OPTIONS_TABLE_SERVER);
    opts_mod.global_s_options = opts_mod.options_create(null);
    opts_mod.options_default_all(opts_mod.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts_mod.global_w_options = opts_mod.options_create(null);
    opts_mod.options_default_all(opts_mod.global_w_options, T.OPTIONS_TABLE_WINDOW);

    env_mod.global_environ = env_mod.environ_create();

    const session = sess.session_create(null, name, "/", env_mod.environ_create(), opts_mod.options_create(opts_mod.global_s_options), null);
    const window = win.window_create(80, 24, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    var attach_cause: ?[]u8 = null;
    defer if (attach_cause) |msg| xm.allocator.free(msg);
    const wl = sess.session_attach(session, window, -1, &attach_cause).?;
    session.curw = wl;
    const pane = win.window_add_pane(window, null, 80, 24);
    window.active = pane;

    var client = T.Client{
        .name = xm.xstrdup(name),
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{ .screen = undefined },
        .flags = T.CLIENT_ATTACHED,
        .session = session,
    };
    client.tty.client = &client;
    client.tty.sx = 80;
    client.tty.sy = 24;

    return .{
        .session = session,
        .window = window,
        .client = client,
    };
}

fn test_teardown(setup: *@TypeOf(test_setup("unused"))) void {
    const env_mod = @import("environ.zig");
    const opts_mod = @import("options.zig");
    const sess = @import("session.zig");
    const status_runtime = @import("status-runtime.zig");
    const win = @import("window.zig");

    cmd_display_panes.clear_overlay(&setup.client);
    status_runtime.status_message_clear(&setup.client);
    env_mod.environ_free(setup.client.environ);
    if (setup.client.name) |name| xm.allocator.free(@constCast(name));

    if (sess.session_find(setup.session.name) != null)
        sess.session_destroy(setup.session, false, "test");
    win.window_remove_ref(setup.window, "test");

    env_mod.environ_free(env_mod.global_environ);
    opts_mod.options_free(opts_mod.global_options);
    opts_mod.options_free(opts_mod.global_s_options);
    opts_mod.options_free(opts_mod.global_w_options);
}

test "display-menu and display-popup commands are registered" {
    try std.testing.expectEqual(&entry, cmd_mod.cmd_find_entry("display-menu").?);
    try std.testing.expectEqual(&entry, cmd_mod.cmd_find_entry("menu").?);
    try std.testing.expectEqual(&entry_popup, cmd_mod.cmd_find_entry("display-popup").?);
    try std.testing.expectEqual(&entry_popup, cmd_mod.cmd_find_entry("popup").?);
}

test "display-menu reports the reduced overlay runtime" {
    var setup = test_setup("display-menu-runtime");
    defer test_teardown(&setup);

    var parse_cause: ?[]u8 = null;
    defer if (parse_cause) |msg| xm.allocator.free(msg);
    const cmd = try cmd_mod.cmd_parse_one(&.{ "display-menu", "Item", "x", "display-message ok" }, null, &parse_cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &setup.client, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.@"error", cmd_mod.cmd_execute(cmd, &item));
    try std.testing.expectEqualStrings("Display-menu overlay not supported yet", setup.client.message_string.?);
}

test "display-menu rejects invalid starting choice before the reduced runtime error" {
    var setup = test_setup("display-menu-start");
    defer test_teardown(&setup);

    var parse_cause: ?[]u8 = null;
    defer if (parse_cause) |msg| xm.allocator.free(msg);
    const cmd = try cmd_mod.cmd_parse_one(&.{ "display-menu", "-C", "-2", "Item", "x", "display-message ok" }, null, &parse_cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &setup.client, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.@"error", cmd_mod.cmd_execute(cmd, &item));
    try std.testing.expectEqualStrings("Starting choice too small", setup.client.message_string.?);
}

test "display-menu with only separators is a no-op" {
    var setup = test_setup("display-menu-separator");
    defer test_teardown(&setup);

    var parse_cause: ?[]u8 = null;
    defer if (parse_cause) |msg| xm.allocator.free(msg);
    const cmd = try cmd_mod.cmd_parse_one(&.{ "display-menu", "" }, null, &parse_cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &setup.client, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));
    try std.testing.expect(setup.client.message_string == null);
}

test "display-menu validates menu border lines before the reduced runtime error" {
    var setup = test_setup("display-menu-border");
    defer test_teardown(&setup);

    var parse_cause: ?[]u8 = null;
    defer if (parse_cause) |msg| xm.allocator.free(msg);
    const cmd = try cmd_mod.cmd_parse_one(&.{ "display-menu", "-b", "mystery", "Item", "x", "display-message ok" }, null, &parse_cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &setup.client, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.@"error", cmd_mod.cmd_execute(cmd, &item));
    try std.testing.expectEqualStrings("Menu-border-lines invalid choice: mystery", setup.client.message_string.?);
}

test "display-menu is a no-op while another overlay owns the target client" {
    var setup = test_setup("display-menu-overlay");
    defer test_teardown(&setup);

    var display_parse_cause: ?[]u8 = null;
    defer if (display_parse_cause) |msg| xm.allocator.free(msg);
    const display_cmd = try cmd_mod.cmd_parse_one(&.{ "display-panes", "-b", "-d", "0" }, null, &display_parse_cause);
    defer cmd_mod.cmd_free(display_cmd);

    var display_list: cmd_mod.CmdList = .{};
    var display_item = cmdq.CmdqItem{ .client = &setup.client, .cmdlist = &display_list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(display_cmd, &display_item));
    try std.testing.expect(cmd_display_panes.overlay_active(&setup.client));

    var menu_parse_cause: ?[]u8 = null;
    defer if (menu_parse_cause) |msg| xm.allocator.free(msg);
    const menu_cmd = try cmd_mod.cmd_parse_one(&.{ "display-menu", "Item", "x", "display-message ok" }, null, &menu_parse_cause);
    defer cmd_mod.cmd_free(menu_cmd);

    var menu_list: cmd_mod.CmdList = .{};
    var menu_item = cmdq.CmdqItem{ .client = &setup.client, .cmdlist = &menu_list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(menu_cmd, &menu_item));
    try std.testing.expect(setup.client.message_string == null);
}

test "display-popup close is a no-op without popup runtime" {
    var setup = test_setup("display-popup-close");
    defer test_teardown(&setup);

    var parse_cause: ?[]u8 = null;
    defer if (parse_cause) |msg| xm.allocator.free(msg);
    const cmd = try cmd_mod.cmd_parse_one(&.{ "display-popup", "-C" }, null, &parse_cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &setup.client, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));
    try std.testing.expect(setup.client.message_string == null);
}

test "display-popup reports the reduced overlay runtime" {
    var setup = test_setup("display-popup-runtime");
    defer test_teardown(&setup);

    var parse_cause: ?[]u8 = null;
    defer if (parse_cause) |msg| xm.allocator.free(msg);
    const cmd = try cmd_mod.cmd_parse_one(&.{"display-popup"}, null, &parse_cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &setup.client, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.@"error", cmd_mod.cmd_execute(cmd, &item));
    try std.testing.expectEqualStrings("Display-popup overlay not supported yet", setup.client.message_string.?);
}

test "display-popup validates size before the reduced runtime error" {
    var setup = test_setup("display-popup-height");
    defer test_teardown(&setup);

    var parse_cause: ?[]u8 = null;
    defer if (parse_cause) |msg| xm.allocator.free(msg);
    const cmd = try cmd_mod.cmd_parse_one(&.{ "display-popup", "-h", "101%" }, null, &parse_cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &setup.client, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.@"error", cmd_mod.cmd_execute(cmd, &item));
    try std.testing.expectEqualStrings("Height too large", setup.client.message_string.?);
}

test "display-popup validates popup border lines before the reduced runtime error" {
    var setup = test_setup("display-popup-border");
    defer test_teardown(&setup);

    var parse_cause: ?[]u8 = null;
    defer if (parse_cause) |msg| xm.allocator.free(msg);
    const cmd = try cmd_mod.cmd_parse_one(&.{ "display-popup", "-b", "mystery" }, null, &parse_cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &setup.client, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.@"error", cmd_mod.cmd_execute(cmd, &item));
    try std.testing.expectEqualStrings("Popup-border-lines invalid choice: mystery", setup.client.message_string.?);
}

test "display-popup is a no-op while another overlay owns the target client" {
    var setup = test_setup("display-popup-overlay");
    defer test_teardown(&setup);

    var display_parse_cause: ?[]u8 = null;
    defer if (display_parse_cause) |msg| xm.allocator.free(msg);
    const display_cmd = try cmd_mod.cmd_parse_one(&.{ "display-panes", "-b", "-d", "0" }, null, &display_parse_cause);
    defer cmd_mod.cmd_free(display_cmd);

    var display_list: cmd_mod.CmdList = .{};
    var display_item = cmdq.CmdqItem{ .client = &setup.client, .cmdlist = &display_list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(display_cmd, &display_item));
    try std.testing.expect(cmd_display_panes.overlay_active(&setup.client));

    var popup_parse_cause: ?[]u8 = null;
    defer if (popup_parse_cause) |msg| xm.allocator.free(msg);
    const popup_cmd = try cmd_mod.cmd_parse_one(&.{"display-popup"}, null, &popup_parse_cause);
    defer cmd_mod.cmd_free(popup_cmd);

    var popup_list: cmd_mod.CmdList = .{};
    var popup_item = cmdq.CmdqItem{ .client = &setup.client, .cmdlist = &popup_list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(popup_cmd, &popup_item));
    try std.testing.expect(setup.client.message_string == null);
}
