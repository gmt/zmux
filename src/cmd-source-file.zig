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
const cmd_find = @import("cmd-find.zig");
const cmd_format = @import("cmd-format.zig");
const cmdq = @import("cmd-queue.zig");
const cfg_mod = @import("cfg.zig");
const format_mod = @import("format.zig");
const file_mod = @import("file.zig");
const paste_mod = @import("paste.zig");
const proc_mod = @import("proc.zig");
const server_client_mod = @import("server-client.zig");
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
    const state = xm.allocator.create(SourceFileState) catch unreachable;
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
    const quoted_cwd = quote_cwd_for_glob(server_client_mod.server_client_get_cwd(cl, null));
    defer xm.allocator.free(quoted_cwd);

    var path_format_ctx: format_mod.FormatContext = undefined;
    const path_format_ctx_ptr = if (args.has('F')) blk: {
        path_format_ctx = build_path_format_context(item, args);
        break :blk &path_format_ctx;
    } else null;

    var idx: usize = 0;
    while (args.value_at(idx)) |raw_path| : (idx += 1) {
        const path = if (path_format_ctx_ptr) |ctx| blk: {
            break :blk cmd_format.require(item, raw_path, ctx) orelse {
                free_state(state);
                return .@"error";
            };
        } else null;
        defer if (path) |expanded| xm.allocator.free(expanded);

        expand_path_argument(state, quoted_cwd, path orelse raw_path);
    }

    return drive_state(state, false);
}

fn build_path_format_context(item: *cmdq.CmdqItem, args: *const @import("arguments.zig").Arguments) format_mod.FormatContext {
    var target: T.CmdFindState = .{};
    const has_lookup_context = args.get('t') != null or
        cmdq.cmdq_get_client(item) != null or
        cmd_find.cmd_find_valid_state(&cmdq.cmdq_get_target(item)) or
        cmd_find.cmd_find_valid_state(&cmdq.cmdq_get_current(item));
    if (has_lookup_context)
        _ = cmd_find.cmd_find_target(&target, item, args.get('t'), .pane, T.CMD_FIND_CANFAIL);

    var ctx = cmd_format.target_context(&target, null);
    ctx.item = @ptrCast(item);
    ctx.client = cmdq.cmdq_get_target_client(item) orelse cmdq.cmdq_get_client(item);
    return ctx;
}

fn expand_path_argument(state: *SourceFileState, quoted_cwd: []const u8, path: []const u8) void {
    if (std.mem.eql(u8, path, "-")) {
        add_path(state, path);
        return;
    }

    const pattern = if (std.mem.startsWith(u8, path, "/"))
        xm.xstrdup(path)
    else
        xm.xasprintf("{s}/{s}", .{ quoted_cwd, path });
    defer xm.allocator.free(pattern);

    const pattern_z = xm.xm_dupeZ(pattern);
    defer xm.allocator.free(pattern_z);

    var matches: c.posix_sys.glob_t = std.mem.zeroes(c.posix_sys.glob_t);
    defer c.posix_sys.globfree(&matches);

    const result = c.posix_sys.glob(pattern_z.ptr, 0, null, &matches);
    if (result != 0) {
        if (result == c.posix_sys.GLOB_NOMATCH and state.flags.quiet) return;

        const errno_value: c_int = if (result == c.posix_sys.GLOB_NOMATCH)
            @intFromEnum(std.posix.E.NOENT)
        else if (result == c.posix_sys.GLOB_NOSPACE)
            @intFromEnum(std.posix.E.NOMEM)
        else
            @intFromEnum(std.posix.E.INVAL);
        cfg_mod.cfg_note_path_error(path, errno_value, false);
        state.ok = false;
        return;
    }

    var idx: usize = 0;
    while (idx < matches.gl_pathc) : (idx += 1) {
        const matched = std.mem.span(matches.gl_pathv[idx]);
        add_path(state, matched);
    }
}

fn add_path(state: *SourceFileState, path: []const u8) void {
    state.files.append(xm.allocator, xm.xstrdup(path)) catch unreachable;
}

fn quote_cwd_for_glob(path: []const u8) []u8 {
    var quoted = std.ArrayList(u8){};
    errdefer quoted.deinit(xm.allocator);

    for (path) |ch| {
        if (ch < 128 and !std.ascii.isAlphanumeric(ch) and ch != '/')
            quoted.append(xm.allocator, '\\') catch unreachable;
        quoted.append(xm.allocator, ch) catch unreachable;
    }

    return quoted.toOwnedSlice(xm.allocator) catch unreachable;
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
        .status = .{},
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

test "source-file expands relative glob patterns from the client cwd" {
    paste_mod.paste_reset_for_tests();
    defer paste_mod.paste_reset_for_tests();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "one.conf", .data = "set-buffer -b one loaded-one\n" });
    try tmp.dir.writeFile(.{ .sub_path = "two.conf", .data = "set-buffer -b two loaded-two\n" });

    const cwd = try tmp.dir.realpathAlloc(xm.allocator, ".");
    defer xm.allocator.free(cwd);

    var env = T.Environ.init(xm.allocator);
    defer env.deinit();
    var client = T.Client{
        .environ = &env,
        .tty = undefined,
        .status = .{},
        .cwd = cwd,
    };

    var cause: ?[]u8 = null;
    defer if (cause) |msg| xm.allocator.free(msg);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &client, .cmdlist = &list };

    const cmd = try cmd_mod.cmd_parse_one(&.{ "source-file", "*.conf" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);

    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));

    const one = paste_mod.paste_get_name("one") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("loaded-one", paste_mod.paste_buffer_data(one, null));

    const two = paste_mod.paste_get_name("two") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("loaded-two", paste_mod.paste_buffer_data(two, null));
}

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

test "source-file -F expands paths from the target pane context" {
    paste_mod.paste_reset_for_tests();
    defer paste_mod.paste_reset_for_tests();

    const setup = try test_session_with_empty_pane("source-file-target-format");
    defer test_teardown_session("source-file-target-format", setup.s);

    setup.wp.screen.title = xm.xstrdup("target-pane");

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "target-pane.conf", .data = "set-buffer -b target loaded-target\n" });

    const cwd = try tmp.dir.realpathAlloc(xm.allocator, ".");
    defer xm.allocator.free(cwd);

    var env = T.Environ.init(xm.allocator);
    defer env.deinit();
    var client = T.Client{
        .environ = &env,
        .tty = undefined,
        .status = .{},
        .cwd = cwd,
    };
    client.tty.client = &client;

    var cause: ?[]u8 = null;
    defer if (cause) |msg| xm.allocator.free(msg);

    const cmd = try cmd_mod.cmd_parse_one(
        &.{ "source-file", "-F", "-t", "source-file-target-format:0.0", "#{pane_title}.conf" },
        null,
        &cause,
    );
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &client, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));

    const pb = paste_mod.paste_get_name("target") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("loaded-target", paste_mod.paste_buffer_data(pb, null));
}

test "source-file quiet glob nomatch does not fail" {
    paste_mod.paste_reset_for_tests();
    defer paste_mod.paste_reset_for_tests();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try tmp.dir.realpathAlloc(xm.allocator, ".");
    defer xm.allocator.free(cwd);

    var env = T.Environ.init(xm.allocator);
    defer env.deinit();
    var client = T.Client{
        .environ = &env,
        .tty = undefined,
        .status = .{},
        .cwd = cwd,
    };

    var cause: ?[]u8 = null;
    defer if (cause) |msg| xm.allocator.free(msg);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &client, .cmdlist = &list };

    const cmd = try cmd_mod.cmd_parse_one(&.{ "source-file", "-q", "*.missing" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);

    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));
}
