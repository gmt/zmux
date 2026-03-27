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
// Ported in part from tmux/cmd-pipe-pane.c.
// Original copyright:
//   Copyright (c) 2009 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const cmd_mod = @import("cmd.zig");
const cmdq = @import("cmd-queue.zig");
const cmd_find = @import("cmd-find.zig");
const format_mod = @import("format.zig");
const pane_io = @import("pane-io.zig");

fn exec(cmd: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {
    const args = cmd_mod.cmd_get_args(cmd);

    var target: T.CmdFindState = .{};
    if (cmd_find.cmd_find_target(&target, item, args.get('t'), .pane, 0) != 0)
        return .@"error";
    const wp = target.wp orelse return .@"error";
    const tc = cmdq.cmdq_get_target_client(item) orelse cmdq.cmdq_get_client(item);

    if (wp.fd < 0 or (wp.flags & T.PANE_EXITED) != 0) {
        cmdq.cmdq_error(item, "target pane has exited", .{});
        return .@"error";
    }

    const had_pipe = wp.pipe_fd >= 0 or wp.pipe_pid > 0;
    pane_io.pane_pipe_close(wp);

    if (args.count() == 0) return .normal;
    const command_template = args.value_at(0).?;
    if (command_template.len == 0) return .normal;
    if (args.has('o') and had_pipe) return .normal;

    const shell_command = format_mod.format_single(@ptrCast(item), command_template, tc, target.s, target.wl, wp);
    defer xm.allocator.free(shell_command);

    const pipe_in = args.has('I');
    const pipe_out = args.has('O') or !pipe_in;
    open_pipe(wp, shell_command, item, pipe_in, pipe_out) catch return .@"error";
    return .normal;
}

fn open_pipe(
    wp: *T.WindowPane,
    shell_command: []const u8,
    item: *cmdq.CmdqItem,
    pipe_in: bool,
    pipe_out: bool,
) !void {
    var pair: [2]i32 = undefined;
    if (std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &pair) != 0) {
        cmdq.cmdq_error(item, "pipe-pane socketpair failed", .{});
        return error.SocketPairFailed;
    }

    const pid = std.posix.fork() catch |err| {
        std.posix.close(pair[0]);
        std.posix.close(pair[1]);
        cmdq.cmdq_error(item, "pipe-pane fork failed", .{});
        return err;
    };

    if (pid == 0) {
        std.posix.close(pair[0]);
        if (std.c.setpgid(0, 0) != 0)
            std.c._exit(1);

        const devnull = std.posix.open("/dev/null", .{ .ACCMODE = .WRONLY }, 0) catch std.c._exit(1);
        if (pipe_out) {
            if (std.c.dup2(pair[1], std.posix.STDIN_FILENO) == -1)
                std.c._exit(1);
        } else if (std.c.dup2(devnull, std.posix.STDIN_FILENO) == -1) {
            std.c._exit(1);
        }
        if (pipe_in) {
            if (std.c.dup2(pair[1], std.posix.STDOUT_FILENO) == -1)
                std.c._exit(1);
        } else if (std.c.dup2(devnull, std.posix.STDOUT_FILENO) == -1) {
            std.c._exit(1);
        }
        if (std.c.dup2(devnull, std.posix.STDERR_FILENO) == -1)
            std.c._exit(1);
        if (pair[1] > std.posix.STDERR_FILENO) std.posix.close(pair[1]);
        if (devnull > std.posix.STDERR_FILENO) std.posix.close(devnull);

        const shell_z = xm.allocator.dupeZ(u8, "/bin/sh") catch unreachable;
        const dash_c = xm.allocator.dupeZ(u8, "-c") catch unreachable;
        const cmd_z = xm.allocator.dupeZ(u8, shell_command) catch unreachable;
        var argv = [_:null]?[*:0]const u8{ shell_z, dash_c, cmd_z, null };
        _ = std.c.execve(shell_z, @ptrCast(&argv), std.c.environ);
        std.c._exit(1);
    }

    std.posix.close(pair[1]);
    set_blocking(pair[0], false);
    wp.pipe_fd = pair[0];
    wp.pipe_pid = pid;
    if (pipe_in)
        pane_io.pane_pipe_start(wp);
}

fn set_blocking(fd: i32, state: bool) void {
    const flags = std.c.fcntl(fd, std.posix.F.GETFL, @as(c_int, 0));
    if (flags < 0) return;
    const O_NONBLOCK: c_int = 0x800;
    const new_flags: c_int = if (state) flags & ~O_NONBLOCK else flags | O_NONBLOCK;
    _ = std.c.fcntl(fd, std.posix.F.SETFL, new_flags);
}

pub const entry: cmd_mod.CmdEntry = .{
    .name = "pipe-pane",
    .alias = "pipep",
    .usage = "[-IOo] [-t target-pane] [shell-command]",
    .template = "IOot:",
    .lower = 0,
    .upper = 1,
    .flags = T.CMD_AFTERHOOK,
    .exec = exec,
};

fn test_session_with_empty_pane(name: []const u8) !struct { s: *T.Session, wp: *T.WindowPane } {
    const env_mod = @import("environ.zig");
    const opts = @import("options.zig");
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

fn test_teardown_session(name: []const u8, s: *T.Session) void {
    const env_mod = @import("environ.zig");
    const opts = @import("options.zig");
    const sess = @import("session.zig");

    if (sess.session_find(name) != null) sess.session_destroy(s, false, "test");
    env_mod.environ_free(env_mod.global_environ);
    opts.options_free(opts.global_w_options);
    opts.options_free(opts.global_s_options);
    opts.options_free(opts.global_options);
}

test "pipe-pane errors when the target pane has exited" {
    const setup = try test_session_with_empty_pane("pipe-pane-exited");
    defer test_teardown_session("pipe-pane-exited", setup.s);

    setup.wp.flags |= T.PANE_EXITED;

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "pipe-pane", "-t", "pipe-pane-exited:0.0", "cat" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.@"error", cmd_mod.cmd_execute(cmd, &item));
}

test "pipe-pane -I feeds child stdout back into the pane and expands formats" {
    const grid = @import("grid.zig");

    const setup = try test_session_with_empty_pane("pipe-pane-input");
    defer test_teardown_session("pipe-pane-input", setup.s);
    const live_pipe = try std.posix.pipe();
    defer {
        std.posix.close(live_pipe[0]);
        if (setup.wp.fd >= 0) {
            std.posix.close(setup.wp.fd);
            setup.wp.fd = -1;
        }
    }
    setup.wp.fd = live_pipe[1];

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(
        &.{ "pipe-pane", "-I", "-t", "pipe-pane-input:0.0", "printf %s '#{session_name}'" },
        null,
        &cause,
    );
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));
    defer pane_io.pane_pipe_close(setup.wp);

    var spins: usize = 0;
    while (spins < 50) : (spins += 1) {
        pane_io.pane_pipe_read_ready(setup.wp);
        if (grid.ascii_at(setup.wp.base.grid, 0, 0) == 'p') break;
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }

    const expected = "pipe-pane-input";
    for (expected, 0..) |ch, idx| {
        try std.testing.expectEqual(ch, grid.ascii_at(setup.wp.base.grid, 0, @intCast(idx)));
    }
}
