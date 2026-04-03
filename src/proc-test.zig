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

//! proc-test.zig – narrow unit tests for [proc.zig](proc.zig).
//!
//! `proc_event_cb`, `proc_add_peer`, `proc_loop`, and `proc_send` on live peers
//! need a valid `imsg` buffer and libevent base; those paths are covered by
//! [job.zig](job.zig) tests and the shell regress/smoke harnesses.

const std = @import("std");
const T = @import("types.zig");
const proc = @import("proc.zig");

test "proc_get_peer_uid reads stored uid field" {
    var dummy_proc: T.ZmuxProc = .{ .name = "test" };
    var peer: T.ZmuxPeer = .{
        .parent = &dummy_proc,
        .ibuf = undefined,
        .uid = 4242,
        .flags = 0,
        .dispatchcb = undefined,
    };
    try std.testing.expectEqual(@as(std.posix.uid_t, 4242), proc.proc_get_peer_uid(&peer));
}

test "proc_kill_peer marks peer with PEER_BAD" {
    var dummy_proc: T.ZmuxProc = .{ .name = "test" };
    var peer: T.ZmuxPeer = .{
        .parent = &dummy_proc,
        .ibuf = undefined,
        .uid = 0,
        .flags = 0,
        .dispatchcb = undefined,
    };
    proc.proc_kill_peer(&peer);
    try std.testing.expect((peer.flags & T.PEER_BAD) != 0);
}
