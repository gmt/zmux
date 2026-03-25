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
// Ported in part from tmux/cmd-respawn-pane.c.
// Original copyright:
//   Copyright (c) 2008 Nicholas Marriott <nicholas.marriott@gmail.com>
//   Copyright (c) 2011 Marcel P. Partap <mpartap@gmx.net>
//   ISC licence – same terms as above.

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const cmd_mod = @import("cmd.zig");
const cmdq = @import("cmd-queue.zig");
const cmd_find = @import("cmd-find.zig");
const env_mod = @import("environ.zig");
const spawn_mod = @import("spawn.zig");
const server_fn = @import("server-fn.zig");
const grid_mod = @import("grid.zig");

fn exec(cmd: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {
    const args = cmd_mod.cmd_get_args(cmd);
    var target: T.CmdFindState = .{};
    if (cmd_find.cmd_find_target(&target, item, args.get('t'), .pane, 0) != 0)
        return .@"error";
    const s = target.s orelse return .@"error";
    const wl = target.wl orelse return .@"error";
    const wp = target.wp orelse return .@"error";

    const overlay = build_overlay_environment(args, item) catch return .@"error";
    defer if (overlay) |env| env_mod.environ_free(env);

    const argv = argv_tail(args, 0);
    defer if (argv) |slice| free_argv(slice);

    var sc = T.SpawnContext{
        .item = @ptrCast(item),
        .s = s,
        .wl = wl,
        .wp0 = wp,
        .argv = argv,
        .environ = overlay,
        .cwd = args.get('c'),
        .flags = T.SPAWN_RESPAWN,
    };
    if (args.has('k')) sc.flags |= T.SPAWN_KILL;

    var cause: ?[]u8 = null;
    defer if (cause) |msg| xm.allocator.free(msg);
    _ = spawn_mod.respawn_pane(&sc, &cause) orelse {
        cmdq.cmdq_error(item, "respawn pane failed: {s}", .{cause orelse "unknown"});
        return .@"error";
    };

    server_fn.server_redraw_session(s);
    server_fn.server_status_window(wl.window);
    return .normal;
}

pub fn build_overlay_environment(args: *const @import("arguments.zig").Arguments, item: *cmdq.CmdqItem) !?*T.Environ {
    const values = args.flags.get('e') orelse return null;
    const env = env_mod.environ_create();
    errdefer env_mod.environ_free(env);
    for (values.items) |env_entry| {
        if (std.mem.indexOfScalar(u8, env_entry, '=')) |_| {
            env_mod.environ_put(env, env_entry, 0);
        } else {
            cmdq.cmdq_error(item, "invalid environment: {s}", .{env_entry});
            return error.InvalidEnvironment;
        }
    }
    return env;
}

pub fn argv_tail(args: *const @import("arguments.zig").Arguments, start: usize) ?[][]u8 {
    if (args.count() <= start) return null;
    const out = xm.allocator.alloc([]u8, args.count() - start) catch unreachable;
    for (start..args.count()) |idx| out[idx - start] = xm.xstrdup(args.value_at(idx).?);
    return out;
}

pub fn free_argv(argv: [][]u8) void {
    for (argv) |arg| xm.allocator.free(arg);
    xm.allocator.free(argv);
}

pub const entry: cmd_mod.CmdEntry = .{
    .name = "respawn-pane",
    .alias = "respawnp",
    .usage = "[-k] [-c start-directory] [-e environment] [-t target-pane] [shell-command [argument ...]]",
    .template = "c:e:kt:",
    .lower = 0,
    .upper = -1,
    .flags = 0,
    .exec = exec,
};

pub fn pane_line_text(wp: *T.WindowPane, row: usize) []u8 {
    const gd = wp.base.grid;
    if (row >= gd.linedata.len) return xm.xstrdup("");
    var used = grid_mod.line_used(gd, @intCast(row));
    while (used > 0 and grid_mod.ascii_at(gd, @intCast(row), used - 1) == ' ') used -= 1;
    const out = xm.allocator.alloc(u8, used) catch unreachable;
    for (0..used) |idx| {
        out[idx] = grid_mod.ascii_at(gd, @intCast(row), @intCast(idx));
    }
    return out;
}

pub fn pane_contains(wp: *T.WindowPane, needle: []const u8) bool {
    const gd = wp.base.grid;
    for (0..gd.linedata.len) |row| {
        const line = pane_line_text(wp, row);
        defer xm.allocator.free(line);
        if (std.mem.indexOf(u8, line, needle) != null) return true;
    }
    return false;
}

pub fn read_pane_output(wp: *T.WindowPane) []u8 {
    var out: std.ArrayList(u8) = .{};
    var buf: [1024]u8 = undefined;
    while (true) {
        const n = std.posix.read(wp.fd, &buf) catch |err| switch (err) {
            error.WouldBlock => break,
            else => break,
        };
        if (n == 0) break;
        out.appendSlice(xm.allocator, buf[0..n]) catch unreachable;
    }
    return out.toOwnedSlice(xm.allocator) catch unreachable;
}

test "respawn-pane requires -k for a live pane" {
    const opts = @import("options.zig");
    const sess = @import("session.zig");
    const win = @import("window.zig");
    const spawn = @import("spawn.zig");

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

    const s = sess.session_create(null, "respawn-pane-live", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("respawn-pane-live") != null) sess.session_destroy(s, false, "test");

    var cause: ?[]u8 = null;
    var sc: T.SpawnContext = .{ .s = s, .idx = -1 };
    _ = spawn.spawn_window(&sc, &cause).?;

    var parse_cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "respawn-pane", "-t", "respawn-pane-live:0.0", "printf hi" }, null, &parse_cause);
    defer cmd_mod.cmd_free(cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.@"error", cmd_mod.cmd_execute(cmd, &item));
}

test "respawn-pane with -k preserves pane identity and applies cwd/env overlay" {
    const opts = @import("options.zig");
    const sess = @import("session.zig");
    const win = @import("window.zig");
    const spawn = @import("spawn.zig");

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

    const s = sess.session_create(null, "respawn-pane-kill", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("respawn-pane-kill") != null) sess.session_destroy(s, false, "test");

    var cause: ?[]u8 = null;
    var sc: T.SpawnContext = .{ .s = s, .idx = -1 };
    const wl = spawn.spawn_window(&sc, &cause).?;
    const wp = wl.window.active.?;
    const pane_id = wp.id;

    var parse_cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{
        "respawn-pane",
        "-k",
        "-c",
        "/tmp",
        "-e",
        "FOO=bar",
        "-t",
        "respawn-pane-kill:0.0",
        "printf %s \"$FOO\"",
    }, null, &parse_cause);
    defer cmd_mod.cmd_free(cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));

    std.Thread.sleep(500 * std.time.ns_per_ms);
    try std.testing.expectEqual(pane_id, wl.window.active.?.id);
    try std.testing.expectEqualStrings("/tmp", wl.window.active.?.cwd.?);
    const output = read_pane_output(wl.window.active.?);
    defer xm.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "bar") != null);
}
