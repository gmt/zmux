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
const log = @import("log.zig");

pub const ServerAclEntry = struct {
    uid: std.posix.uid_t,
    deny: bool = false,
};

var acl_entries: std.AutoHashMap(std.posix.uid_t, ServerAclEntry) = undefined;
var acl_initialised = false;

pub fn server_acl_init() void {
    acl_entries = std.AutoHashMap(std.posix.uid_t, ServerAclEntry).init(xm.allocator);
    acl_initialised = true;
}

pub fn server_acl_join(uid: std.posix.uid_t) bool {
    if (!acl_initialised) return true;
    if (acl_entries.get(uid)) |entry| {
        return !entry.deny;
    }
    return true; // default allow
}

pub fn server_acl_get_uid(peer: *T.TmuxPeer) std.posix.uid_t {
    return peer.uid;
}
