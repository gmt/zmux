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

fn exec(cmd: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {
    const args = cmd_mod.cmd_get_args(cmd);
    if (args.has('I')) {
        cmdq.cmdq_error(item, "pipe-pane input forwarding not supported yet", .{});
        return .@"error";
    }

    var target: T.CmdFindState = .{};
    if (cmd_find.cmd_find_target(&target, item, args.get('t'), .pane, 0) != 0)
        return .@"error";
    const wp = target.wp orelse return .@"error";

    const had_pipe = wp.pipe_fd >= 0;
    close_pipe(wp);

    if (args.count() == 0) return .normal;
    const shell_command = args.value_at(0).?;
    if (shell_command.len == 0) return .normal;
    if (args.has('o') and had_pipe) return .normal;

    if (args.has('O') or !args.has('I')) {
        open_output_pipe(wp, shell_command, item) catch return .@"error";
        return .normal;
    }

    cmdq.cmdq_error(item, "pipe-pane input forwarding not supported yet", .{});
    return .@"error";
}

fn open_output_pipe(wp: *T.WindowPane, shell_command: []const u8, item: *cmdq.CmdqItem) !void {
    const pipe_fds = try std.posix.pipe();
    const read_fd = pipe_fds[0];
    const write_fd = pipe_fds[1];

    const pid = std.posix.fork() catch |err| {
        std.posix.close(read_fd);
        std.posix.close(write_fd);
        cmdq.cmdq_error(item, "pipe-pane fork failed", .{});
        return err;
    };

    if (pid == 0) {
        std.posix.close(write_fd);
        _ = std.c.dup2(read_fd, 0);

        const devnull = std.posix.open("/dev/null", .{ .ACCMODE = .WRONLY }, 0) catch -1;
        if (devnull >= 0) {
            _ = std.c.dup2(devnull, 1);
            _ = std.c.dup2(devnull, 2);
            if (devnull > 2) std.posix.close(devnull);
        }
        if (read_fd > 2) std.posix.close(read_fd);

        const shell_z = xm.allocator.dupeZ(u8, "/bin/sh") catch unreachable;
        const dash_c = xm.allocator.dupeZ(u8, "-c") catch unreachable;
        const cmd_z = xm.allocator.dupeZ(u8, shell_command) catch unreachable;
        var argv = [_:null]?[*:0]const u8{ shell_z, dash_c, cmd_z, null };
        _ = std.c.execve(shell_z, @ptrCast(&argv), std.c.environ);
        std.c._exit(1);
    }

    std.posix.close(read_fd);
    set_blocking(write_fd, false);
    wp.pipe_fd = write_fd;
    wp.pipe_pid = pid;
}

fn close_pipe(wp: *T.WindowPane) void {
    if (wp.pipe_fd >= 0) {
        std.posix.close(wp.pipe_fd);
        wp.pipe_fd = -1;
    }
    if (wp.pipe_pid > 0) {
        _ = std.c.kill(wp.pipe_pid, std.posix.SIG.HUP);
        _ = std.c.kill(wp.pipe_pid, std.posix.SIG.TERM);
        _ = std.posix.waitpid(wp.pipe_pid, 0);
        wp.pipe_pid = -1;
    }
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
    .usage = "[-Oo] [-t target-pane] [shell-command]",
    .template = "IOot:",
    .lower = 0,
    .upper = 1,
    .flags = T.CMD_AFTERHOOK,
    .exec = exec,
};
