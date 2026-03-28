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
// Ported in part from tmux/cmd-source-file.c
// Original copyright:
//   Copyright (c) 2008 Tiago Cunha <me@tiagocunha.org>
//   ISC licence – same terms as above.

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const cmd_mod = @import("cmd.zig");
const cmd_format = @import("cmd-format.zig");
const cmdq = @import("cmd-queue.zig");
const cfg_mod = @import("cfg.zig");
const format_mod = @import("format.zig");
const file_mod = @import("file.zig");
const paste_mod = @import("paste.zig");
const proc_mod = @import("proc.zig");
const protocol = @import("zmux-protocol.zig");
const c = @import("c.zig");
const build_options = @import("build_options");

const SourceFileState = struct {
    item: *cmdq.CmdqItem,
    client: ?*T.Client,
    flags: cfg_mod.CfgFlags,
    files: std.ArrayList([]u8),
    current: usize = 0,
    ok: bool = true,
};

fn exec(cmd: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {
    const args = cmd_mod.cmd_get_args(cmd);
    const cl = cmdq.cmdq_get_client(item);
    var state = xm.allocator.create(SourceFileState) catch unreachable;
    state.* = .{
        .item = item,
        .client = cl,
        .flags = .{
            .quiet = args.has('q'),
            .parse_only = args.has('n'),
            .verbose = args.has('v'),
        },
        .files = .{},
    };

    var idx: usize = 0;
    while (args.value_at(idx)) |raw_path| : (idx += 1) {
        const path = if (args.has('F')) blk: {
            const ctx = format_mod.FormatContext{
                .item = @ptrCast(item),
                .client = cl,
            };
            break :blk cmd_format.require(item, raw_path, &ctx) orelse {
                free_state(state);
                return .@"error";
            };
        } else null;
        defer if (path) |expanded| xm.allocator.free(expanded);

        state.files.append(xm.allocator, xm.xstrdup(path orelse raw_path)) catch unreachable;
    }

    return drive_state(state, false);
}

fn drive_state(state: *SourceFileState, from_callback: bool) T.CmdRetval {
    while (state.current < state.files.items.len) {
        const path = state.files.items[state.current];
        if (file_mod.shouldUseRemotePathIO(state.client)) {
            switch (file_mod.startRemoteRead(state.client.?, path, source_file_done, state)) {
                .wait => return .wait,
                .err => |errno_value| {
                    cfg_mod.cfg_note_path_error(path, errno_value, state.flags.quiet);
                    state.ok = false;
                    state.current += 1;
                    continue;
                },
            }
        }

        if (!cfg_mod.cfg_source_path(state.client, path, state.flags))
            state.ok = false;
        state.current += 1;
    }

    cfg_mod.cfg_show_causes(state.client);
    const retval: T.CmdRetval = if (state.ok) .normal else .@"error";
    const item = state.item;
    free_state(state);
    if (from_callback) cmdq.cmdq_continue(item);
    return retval;
}

fn source_file_done(path: []const u8, errno_value: c_int, data: []const u8, cbdata: ?*anyopaque) void {
    const state: *SourceFileState = @ptrCast(@alignCast(cbdata orelse return));
    if (errno_value != 0) {
        cfg_mod.cfg_note_path_error(path, errno_value, state.flags.quiet);
        state.ok = false;
    } else if (data.len != 0) {
        if (!cfg_mod.cfg_source_content(state.client, path, data, state.flags))
            state.ok = false;
    }
    state.current += 1;
    _ = drive_state(state, true);
}

fn free_state(state: *SourceFileState) void {
    for (state.files.items) |path| xm.allocator.free(path);
    state.files.deinit(xm.allocator);
    xm.allocator.destroy(state);
}

pub const entry: cmd_mod.CmdEntry = .{
    .name = "source-file",
    .alias = "source",
    .usage = "[-Fnqv] path ...",
    .template = "Fnqvt:",
    .lower = 1,
    .upper = -1,
    .flags = T.CMD_STARTSERVER | T.CMD_AFTERHOOK,
    .exec = exec,
};

test "source-file rejects unresolved format references" {
    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "source-file", "-F", "#{pane_title}" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.@"error", cmd_mod.cmd_execute(cmd, &item));
}

fn test_peer_dispatch(_imsg: ?*c.imsg.imsg, _arg: ?*anyopaque) callconv(.c) void {
    _ = _imsg;
    _ = _arg;
}

fn read_single_peer_imsg(reader: *c.imsg.imsgbuf) c.imsg.imsg {
    var imsg_msg: c.imsg.imsg = undefined;
    if (c.imsg.imsg_get(reader, &imsg_msg) > 0) return imsg_msg;
    if (c.imsg.imsgbuf_read(reader) != 1) unreachable;
    if (c.imsg.imsg_get(reader, &imsg_msg) <= 0) unreachable;
    return imsg_msg;
}

fn requireStressTests() !void {
    if (!build_options.stress_tests)
        return error.SkipZigTest;
}

test "source-file waits for detached client reads and loads remote content" {
    try requireStressTests();
    paste_mod.paste_reset_for_tests();
    file_mod.resetForTests();
    defer file_mod.resetForTests();

    var env = T.Environ.init(xm.allocator);
    defer env.deinit();

    var pair: [2]i32 = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &pair));

    var proc = T.ZmuxProc{ .name = "source-file-remote-test" };
    defer proc.peers.deinit(xm.allocator);

    var client = T.Client{
        .environ = &env,
        .tty = undefined,
        .status = .{ .screen = undefined },
    };
    client.peer = proc_mod.proc_add_peer(&proc, pair[0], test_peer_dispatch, null);
    defer {
        const peer = client.peer.?;
        c.imsg.imsgbuf_clear(&peer.ibuf);
        std.posix.close(peer.ibuf.fd);
        xm.allocator.destroy(peer);
        proc.peers.clearRetainingCapacity();
    }

    var reader: c.imsg.imsgbuf = undefined;
    try std.testing.expectEqual(@as(i32, 0), c.imsg.imsgbuf_init(&reader, pair[1]));
    defer {
        c.imsg.imsgbuf_clear(&reader);
        std.posix.close(pair[1]);
    }

    const saved_stdin = try std.posix.dup(std.posix.STDIN_FILENO);
    defer std.posix.close(saved_stdin);

    const pipe_fds = try std.posix.pipe();
    defer std.posix.close(pipe_fds[0]);

    _ = try std.posix.write(pipe_fds[1], "set-buffer -b sourced loaded\n");
    std.posix.close(pipe_fds[1]);

    try std.posix.dup2(pipe_fds[0], std.posix.STDIN_FILENO);
    defer std.posix.dup2(saved_stdin, std.posix.STDIN_FILENO) catch {};

    var cause: ?[]u8 = null;
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &client, .cmdlist = &list };

    const cmd = try cmd_mod.cmd_parse_one(&.{ "source-file", "-" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);

    try std.testing.expectEqual(T.CmdRetval.wait, cmd_mod.cmd_execute(cmd, &item));

    var open_imsg = read_single_peer_imsg(&reader);
    defer c.imsg.imsg_free(&open_imsg);
    try std.testing.expectEqual(@as(u32, @intCast(@intFromEnum(protocol.MsgType.read_open))), c.imsg.imsg_get_type(&open_imsg));

    file_mod.clientHandleReadOpen(client.peer.?, &open_imsg, true, false);

    while (true) {
        var imsg_msg = read_single_peer_imsg(&reader);
        defer c.imsg.imsg_free(&imsg_msg);

        const msg_type = std.meta.intToEnum(protocol.MsgType, imsg_msg.hdr.type) catch unreachable;
        switch (msg_type) {
            .read => file_mod.handleReadData(&imsg_msg),
            .read_done => {
                file_mod.handleReadDone(&imsg_msg);
                break;
            },
            else => unreachable,
        }
    }

    try std.posix.dup2(saved_stdin, std.posix.STDIN_FILENO);

    const pb = paste_mod.paste_get_name("sourced") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("loaded", paste_mod.paste_buffer_data(pb, null));
}
