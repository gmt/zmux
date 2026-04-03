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
// Ported from tmux/server-acl.c
// Original copyright:
//   Copyright (c) 2022 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

//! server-acl.zig – server access control list.

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const c = @import("c.zig");
const cmdq = @import("cmd-queue.zig");
const proc_mod = @import("proc.zig");
const client_registry = @import("client-registry.zig");

pub const ServerAclEntry = struct {
    uid: std.posix.uid_t,
    flags: u32 = 0,
};

pub const SERVER_ACL_READONLY: u32 = 0x1;

var acl_entries: std.AutoHashMap(std.posix.uid_t, ServerAclEntry) = undefined;
var acl_initialised = false;

fn invalid_uid() std.posix.uid_t {
    return std.math.maxInt(std.posix.uid_t);
}

fn server_acl_user_find(uid: std.posix.uid_t) ?*ServerAclEntry {
    if (!acl_initialised) return null;
    return acl_entries.getPtr(uid);
}

pub fn server_acl_init() void {
    if (acl_initialised) {
        acl_entries.clearRetainingCapacity();
    } else {
        acl_entries = std.AutoHashMap(std.posix.uid_t, ServerAclEntry).init(xm.allocator);
        acl_initialised = true;
    }

    const owner_uid: std.posix.uid_t = @intCast(std.os.linux.getuid());
    if (owner_uid != 0)
        server_acl_user_allow(0);
    server_acl_user_allow(owner_uid);
}

pub fn server_acl_user_exists(uid: std.posix.uid_t) bool {
    return server_acl_user_find(uid) != null;
}

pub fn server_acl_user_is_readonly(uid: std.posix.uid_t) bool {
    const user = server_acl_user_find(uid) orelse return false;
    return (user.flags & SERVER_ACL_READONLY) != 0;
}

pub fn server_acl_display(item: *cmdq.CmdqItem) void {
    var entries = std.ArrayList(ServerAclEntry){};
    defer entries.deinit(xm.allocator);

    var it = acl_entries.valueIterator();
    while (it.next()) |entry| {
        if (entry.uid == 0) continue;
        entries.append(xm.allocator, entry.*) catch unreachable;
    }

    std.mem.sort(ServerAclEntry, entries.items, {}, struct {
        fn lessThan(_: void, lhs: ServerAclEntry, rhs: ServerAclEntry) bool {
            return lhs.uid < rhs.uid;
        }
    }.lessThan);

    for (entries.items) |entry| {
        const pw = c.posix_sys.getpwuid(entry.uid);
        const name = if (pw != null)
            std.mem.span(@as([*:0]const u8, @ptrCast(pw.?.*.pw_name)))
        else
            "unknown";
        const access_mode: u8 = if ((entry.flags & SERVER_ACL_READONLY) != 0) 'R' else 'W';
        cmdq.cmdq_print(item, "{s} ({c})", .{ name, access_mode });
    }
}

pub fn server_acl_user_allow(uid: std.posix.uid_t) void {
    if (!acl_initialised) server_acl_init();
    const gop = acl_entries.getOrPut(uid) catch unreachable;
    if (!gop.found_existing)
        gop.value_ptr.* = .{ .uid = uid };
}

pub fn server_acl_user_deny(uid: std.posix.uid_t) void {
    if (!acl_initialised) return;
    _ = acl_entries.remove(uid);
}

pub fn server_acl_user_allow_write(uid: std.posix.uid_t) void {
    const user = server_acl_user_find(uid) orelse return;
    user.flags &= ~@as(u32, SERVER_ACL_READONLY);

    for (client_registry.clients.items) |cl| {
        const peer = cl.peer orelse continue;
        const peer_uid = proc_mod.proc_get_peer_uid(peer);
        if (peer_uid != invalid_uid() and peer_uid == uid)
            cl.flags &= ~@as(u64, T.CLIENT_READONLY);
    }
}

pub fn server_acl_user_deny_write(uid: std.posix.uid_t) void {
    const user = server_acl_user_find(uid) orelse return;
    user.flags |= SERVER_ACL_READONLY;

    for (client_registry.clients.items) |cl| {
        const peer = cl.peer orelse continue;
        const peer_uid = proc_mod.proc_get_peer_uid(peer);
        if (peer_uid != invalid_uid() and peer_uid == uid)
            cl.flags |= T.CLIENT_READONLY;
    }
}

pub fn server_acl_join(cl: *T.Client) bool {
    const peer = cl.peer orelse return false;
    const uid = proc_mod.proc_get_peer_uid(peer);
    if (uid == invalid_uid()) return false;

    const user = server_acl_user_find(uid) orelse return false;
    if ((user.flags & SERVER_ACL_READONLY) != 0)
        cl.flags |= T.CLIENT_READONLY
    else
        cl.flags &= ~@as(u64, T.CLIENT_READONLY);
    return true;
}

pub fn server_acl_reset_for_tests() void {
    server_acl_init();
}

test "server_acl_user_exists is false for arbitrary unknown uids" {
    server_acl_init();
    try std.testing.expect(!server_acl_user_exists(std.math.maxInt(std.posix.uid_t) - 12345));
}

test "server ACL join and readonly toggles follow stored entries" {
    server_acl_reset_for_tests();

    var peer = T.ZmuxPeer{
        .parent = undefined,
        .ibuf = undefined,
        .event = null,
        .uid = 12345,
        .flags = 0,
        .dispatchcb = undefined,
        .arg = null,
    };
    var client = T.Client{
        .peer = &peer,
        .environ = undefined,
        .tty = undefined,
        .status = undefined,
    };

    try std.testing.expect(!server_acl_join(&client));

    server_acl_user_allow(peer.uid);
    try std.testing.expect(server_acl_join(&client));
    try std.testing.expect(client.flags & T.CLIENT_READONLY == 0);

    server_acl_user_deny_write(peer.uid);
    client.flags &= ~@as(u64, T.CLIENT_READONLY);
    try std.testing.expect(server_acl_join(&client));
    try std.testing.expect(client.flags & T.CLIENT_READONLY != 0);
}

test "server_acl_user_deny removes a previously allowed uid" {
    server_acl_reset_for_tests();
    const uid: std.posix.uid_t = 88888;
    server_acl_user_allow(uid);
    try std.testing.expect(server_acl_user_exists(uid));
    server_acl_user_deny(uid);
    try std.testing.expect(!server_acl_user_exists(uid));
}

test "server ACL write toggles update live client flags" {
    server_acl_reset_for_tests();
    client_registry.clients.clearRetainingCapacity();
    defer client_registry.clients.clearRetainingCapacity();

    var peer = T.ZmuxPeer{
        .parent = undefined,
        .ibuf = undefined,
        .event = null,
        .uid = 22334,
        .flags = 0,
        .dispatchcb = undefined,
        .arg = null,
    };
    var client = T.Client{
        .peer = &peer,
        .environ = undefined,
        .tty = undefined,
        .status = undefined,
    };
    client_registry.add(&client);

    server_acl_user_allow(peer.uid);
    server_acl_user_deny_write(peer.uid);
    try std.testing.expect(client.flags & T.CLIENT_READONLY != 0);
    try std.testing.expect(server_acl_user_is_readonly(peer.uid));

    server_acl_user_allow_write(peer.uid);
    try std.testing.expect(client.flags & T.CLIENT_READONLY == 0);
    try std.testing.expect(!server_acl_user_is_readonly(peer.uid));
}
