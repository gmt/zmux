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

//! Tests for small helpers: file-path, client-registry, marked-pane, proc, pane-input.

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const env_mod = @import("environ.zig");
const file_path = @import("file-path.zig");
const client_registry = @import("client-registry.zig");
const marked_pane_mod = @import("marked-pane.zig");
const proc_mod = @import("proc.zig");
const pane_input = @import("pane-input.zig");
const cmdq = @import("cmd-queue.zig");
const cmd_mod = @import("cmd.zig");
const c = @import("c.zig");

fn noop_imsg_dispatch(_: ?*c.imsg.imsg, _: ?*anyopaque) callconv(.c) void {}

test "file_path resolve_path handles stdin dash absolute and relative segments" {
    const dash = file_path.resolve_path(null, "-");
    try std.testing.expect(!dash.owned);
    try std.testing.expectEqualStrings("-", dash.path);

    const abs = file_path.resolve_path(null, "/tmp/zmux-abs");
    try std.testing.expect(!abs.owned);
    try std.testing.expectEqualStrings("/tmp/zmux-abs", abs.path);

    const rel = file_path.resolve_path(null, "relative-bit");
    defer if (rel.owned) xm.allocator.free(@constCast(rel.path));
    try std.testing.expect(rel.owned);
    try std.testing.expect(std.mem.endsWith(u8, rel.path, "/relative-bit"));
}

test "file_get_path joins relative files against client cwd" {
    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);

    var cl: T.Client = undefined;
    cl = .{
        .environ = env,
        .tty = undefined,
        .status = .{},
        .session = null,
        .cwd = try xm.allocator.dupe(u8, "/tmp/zmux-file-path"),
    };
    defer xm.allocator.free(cl.cwd.?);
    cl.tty = .{ .client = &cl };

    const got = file_path.file_get_path(&cl, "x.txt");
    defer xm.allocator.free(got);
    try std.testing.expectEqualStrings("/tmp/zmux-file-path/x.txt", got);
}

test "client_registry add and remove round-trip" {
    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);

    var cl: T.Client = undefined;
    cl = .{
        .environ = env,
        .tty = undefined,
        .status = .{},
    };
    cl.tty = .{ .client = &cl };

    const before = client_registry.clients.items.len;
    client_registry.add(&cl);
    try std.testing.expectEqual(before + 1, client_registry.clients.items.len);
    client_registry.remove(&cl);
    try std.testing.expectEqual(before, client_registry.clients.items.len);
}

test "marked_pane clear and is_marked nil guards" {
    marked_pane_mod.clear();
    try std.testing.expect(!marked_pane_mod.is_marked(null, null, null));
}

test "proc_get_peer_uid reads peer credential field" {
    var proc = T.ZmuxProc{ .name = "small-mod-test" };
    var peer = T.ZmuxPeer{
        .parent = &proc,
        .ibuf = undefined,
        .uid = 2002,
        .dispatchcb = noop_imsg_dispatch,
    };

    try std.testing.expectEqual(@as(std.posix.uid_t, 2002), proc_mod.proc_get_peer_uid(&peer));
}

test "pane_input write_all copies bytes to a writable fd" {
    const fds = try std.posix.pipe();
    defer {
        std.posix.close(fds[0]);
        std.posix.close(fds[1]);
    }

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };

    try pane_input.write_all(fds[1], "zmux", &item);

    var buf: [8]u8 = undefined;
    const n = try std.posix.read(fds[0], &buf);
    try std.testing.expectEqualStrings("zmux", buf[0..n]);
}

test "kill-session command entry parses standard flags" {
    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "kill-session", "-aC", "-t", "mysess" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);
    const args = cmd_mod.cmd_get_args(cmd);
    try std.testing.expect(args.has('a'));
    try std.testing.expect(args.has('C'));
    try std.testing.expectEqualStrings("mysess", args.get('t').?);
}

test "cmd_format target_context maps cmd_find fields into format context" {
    const cmd_format = @import("cmd-format.zig");

    var target: T.CmdFindState = .{ .idx = 3 };
    const ctx = cmd_format.target_context(&target, "hello");
    try std.testing.expectEqualStrings("hello", ctx.message_text.?);
    try std.testing.expect(ctx.session == null);
    try std.testing.expect(ctx.winlink == null);
    try std.testing.expect(ctx.window == null);
    try std.testing.expect(ctx.pane == null);
}

test "cmd_format require returns null when format expansion is incomplete" {
    const cmd_format = @import("cmd-format.zig");

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    var target: T.CmdFindState = .{ .idx = -1 };
    const ctx = cmd_format.target_context(&target, null);

    try std.testing.expect(cmd_format.require(&item, "#{session_name}", &ctx) == null);
}

test "cmd_format filter returns null when format expansion is incomplete" {
    const cmd_format = @import("cmd-format.zig");

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    var target: T.CmdFindState = .{ .idx = -1 };
    const ctx = cmd_format.target_context(&target, null);

    try std.testing.expect(cmd_format.filter(&item, "#{window_name}", &ctx) == null);
}
