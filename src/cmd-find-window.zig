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
// Ported in part from tmux/cmd-find-window.c.
// Original copyright:
//   Copyright (c) 2009 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

const std = @import("std");
const T = @import("types.zig");
const args_mod = @import("arguments.zig");
const cmd_find = @import("cmd-find.zig");
const cmd_mod = @import("cmd.zig");
const cmdq = @import("cmd-queue.zig");
const window_tree = @import("window-tree.zig");
const xm = @import("xmalloc.zig");

const ModeIntent = struct {
    filter: []u8,
    zoom: bool,
};

fn exec(cmd: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {
    const args = cmd_mod.cmd_get_args(cmd);

    var target: T.CmdFindState = .{};
    if (cmd_find.cmd_find_target(&target, item, args.get('t'), .pane, 0) != 0)
        return .@"error";
    const wp = target.wp orelse return .@"error";

    const intent = buildModeIntent(args);
    defer xm.allocator.free(intent.filter);

    _ = window_tree.enterMode(wp, .{
        .fs = &target,
        .kind = .pane,
        .filter = intent.filter,
        .zoom = intent.zoom,
    });
    return .normal;
}

fn buildModeIntent(args: *const args_mod.Arguments) ModeIntent {
    return .{
        .filter = buildFilter(args),
        .zoom = args.has('Z'),
    };
}

fn buildFilter(args: *const args_mod.Arguments) []u8 {
    const search = args.value_at(0) orelse unreachable;

    var match_content = args.has('C');
    var match_name = args.has('N');
    var match_title = args.has('T');
    if (!match_content and !match_name and !match_title) {
        match_content = true;
        match_name = true;
        match_title = true;
    }

    const regex = args.has('r');
    const ignore_case = args.has('i');
    const star = if (regex) "" else "*";
    const suffix = if (regex and ignore_case)
        "/ri"
    else if (regex)
        "/r"
    else if (ignore_case)
        "/i"
    else
        "";

    var out: std.ArrayList(u8) = .{};
    appendFilter(&out, if (match_content and match_name and match_title)
        &.{
            "#{||:#{C",             suffix, ":", search, "},#{||:#{m", suffix, ":",                 star, search, star,
            ",#{window_name}},#{m", suffix, ":", star,   search,       star,   ",#{pane_title}}}}",
        }
    else if (match_content and match_name)
        &.{
            "#{||:#{C", suffix, ":", search, "},#{m", suffix, ":", star, search, star, ",#{window_name}}}",
        }
    else if (match_content and match_title)
        &.{
            "#{||:#{C", suffix, ":", search, "},#{m", suffix, ":", star, search, star, ",#{pane_title}}}",
        }
    else if (match_name and match_title)
        &.{
            "#{||:#{m", suffix, ":", star, search, star, ",#{window_name}},#{m", suffix, ":", star, search, star, ",#{pane_title}}}",
        }
    else if (match_content)
        &.{ "#{C", suffix, ":", search, "}" }
    else if (match_name)
        &.{ "#{m", suffix, ":", star, search, star, ",#{window_name}}" }
    else
        &.{ "#{m", suffix, ":", star, search, star, ",#{pane_title}}" });
    return out.toOwnedSlice(xm.allocator) catch unreachable;
}

fn appendFilter(out: *std.ArrayList(u8), pieces: []const []const u8) void {
    for (pieces) |piece| out.appendSlice(xm.allocator, piece) catch unreachable;
}

pub const entry: cmd_mod.CmdEntry = .{
    .name = "find-window",
    .alias = "findw",
    .usage = "[-CiNrTZ] [-t target-pane] match-string",
    .template = "CiNrt:TZ",
    .lower = 1,
    .upper = 1,
    .flags = 0,
    .exec = exec,
};

fn init_test_globals() void {
    const env_mod = @import("environ.zig");
    const opts = @import("options.zig");
    const sess = @import("session.zig");
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
}

fn deinit_test_globals() void {
    const env_mod = @import("environ.zig");
    const opts = @import("options.zig");

    env_mod.environ_free(env_mod.global_environ);
    opts.options_free(opts.global_w_options);
    opts.options_free(opts.global_s_options);
    opts.options_free(opts.global_options);
}

const TestSetup = struct {
    session: *T.Session,
    pane: *T.WindowPane,
};

fn test_setup(session_name: []const u8) !TestSetup {
    const env_mod = @import("environ.zig");
    const opts = @import("options.zig");
    const sess = @import("session.zig");
    const spawn = @import("spawn.zig");

    const session = sess.session_create(
        null,
        session_name,
        "/",
        env_mod.environ_create(),
        opts.options_create(opts.global_s_options),
        null,
    );
    var cause: ?[]u8 = null;
    var ctx: T.SpawnContext = .{ .s = session, .idx = -1, .flags = T.SPAWN_EMPTY };
    const wl = spawn.spawn_window(&ctx, &cause).?;
    return .{
        .session = session,
        .pane = wl.window.active.?,
    };
}

fn expectFilter(argv: []const []const u8, expected: []const u8) !void {
    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(argv, null, &cause);
    defer cmd_mod.cmd_free(cmd);

    const filter = buildFilter(cmd_mod.cmd_get_args(cmd));
    defer xm.allocator.free(filter);
    try std.testing.expectEqualStrings(expected, filter);
}

test "find-window command is registered with its alias" {
    try std.testing.expectEqual(&entry, cmd_mod.cmd_find_entry("find-window").?);
    try std.testing.expectEqual(&entry, cmd_mod.cmd_find_entry("findw").?);
}

test "find-window builds tmux-style filter strings" {
    try expectFilter(
        &.{ "find-window", "needle" },
        "#{||:#{C:needle},#{||:#{m:*needle*,#{window_name}},#{m:*needle*,#{pane_title}}}}",
    );
    try expectFilter(
        &.{ "find-window", "-N", "needle" },
        "#{m:*needle*,#{window_name}}",
    );
    try expectFilter(
        &.{ "find-window", "-T", "-i", "needle" },
        "#{m/i:*needle*,#{pane_title}}",
    );
    try expectFilter(
        &.{ "find-window", "-C", "-r", "a.*b" },
        "#{C/r:a.*b}",
    );
    try expectFilter(
        &.{ "find-window", "-N", "-T", "-r", "-i", "a.*b" },
        "#{||:#{m/ri:a.*b,#{window_name}},#{m/ri:a.*b,#{pane_title}}}",
    );
}

test "find-window enters the reduced window-tree runtime" {
    const sess = @import("session.zig");
    const win = @import("window.zig");

    init_test_globals();
    defer deinit_test_globals();

    const setup = try test_setup("find-window-live");
    defer if (sess.session_find("find-window-live") != null)
        sess.session_destroy(setup.session, false, "test");

    const target = try std.fmt.allocPrint(xm.allocator, "%{d}", .{setup.pane.id});
    defer xm.allocator.free(target);

    var env = T.Environ.init(xm.allocator);
    defer env.deinit();

    var client = T.Client{
        .name = "find-window-client",
        .environ = &env,
        .tty = undefined,
        .status = .{},
        .flags = T.CLIENT_ATTACHED,
        .session = setup.session,
    };
    client.tty = .{ .client = &client };

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "find-window", "-t", target, "sh" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &client, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));
    try std.testing.expectEqual(&window_tree.window_tree_mode, win.window_pane_mode(setup.pane).?.mode);
}

test "find-window -Z zooms tree mode and unzooms on exit when it created the zoom" {
    const sess = @import("session.zig");
    const win = @import("window.zig");
    const window_mode_runtime = @import("window-mode-runtime.zig");

    init_test_globals();
    defer deinit_test_globals();

    const setup = try test_setup("find-window-zoom");
    defer if (sess.session_find("find-window-zoom") != null)
        sess.session_destroy(setup.session, false, "test");

    const extra = win.window_add_pane(setup.pane.window, null, 80, 24);
    setup.pane.window.active = extra;

    const target = try std.fmt.allocPrint(xm.allocator, "%{d}", .{extra.id});
    defer xm.allocator.free(target);

    var env = T.Environ.init(xm.allocator);
    defer env.deinit();

    var client = T.Client{
        .name = "find-window-zoom-client",
        .environ = &env,
        .tty = undefined,
        .status = .{},
        .flags = T.CLIENT_ATTACHED,
        .session = setup.session,
    };
    client.tty = .{ .client = &client };

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "find-window", "-Z", "-t", target, "sh" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &client, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));
    try std.testing.expect(extra.window.flags & T.WINDOW_ZOOMED != 0);

    try std.testing.expect(window_mode_runtime.resetMode(extra));
    try std.testing.expectEqual(@as(u32, 0), extra.window.flags & T.WINDOW_ZOOMED);
}

test "find-window -Z preserves an already zoomed window after tree mode closes" {
    const sess = @import("session.zig");
    const win = @import("window.zig");
    const window_mode_runtime = @import("window-mode-runtime.zig");

    init_test_globals();
    defer deinit_test_globals();

    const setup = try test_setup("find-window-keep-zoom");
    defer if (sess.session_find("find-window-keep-zoom") != null)
        sess.session_destroy(setup.session, false, "test");

    const extra = win.window_add_pane(setup.pane.window, null, 80, 24);
    setup.pane.window.active = extra;
    try std.testing.expect(win.window_zoom(extra));
    try std.testing.expect(extra.window.flags & T.WINDOW_ZOOMED != 0);

    const target = try std.fmt.allocPrint(xm.allocator, "%{d}", .{extra.id});
    defer xm.allocator.free(target);

    var env = T.Environ.init(xm.allocator);
    defer env.deinit();

    var client = T.Client{
        .name = "find-window-keep-zoom-client",
        .environ = &env,
        .tty = undefined,
        .status = .{},
        .flags = T.CLIENT_ATTACHED,
        .session = setup.session,
    };
    client.tty = .{ .client = &client };

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "find-window", "-Z", "-t", target, "sh" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &client, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));

    try std.testing.expect(window_mode_runtime.resetMode(extra));
    try std.testing.expect(extra.window.flags & T.WINDOW_ZOOMED != 0);
}
