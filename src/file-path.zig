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

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const cmdq = @import("cmd-queue.zig");
const format_mod = @import("format.zig");
const server_client_mod = @import("server-client.zig");

pub const ResolvedPath = struct {
    path: []const u8,
    owned: bool = false,
};

pub fn format_path_from_client(item: *cmdq.CmdqItem, client: ?*T.Client, raw_path: []const u8) []u8 {
    const session = if (client) |cl| cl.session else null;
    const winlink = if (session) |s| s.curw else null;
    const pane = if (winlink) |wl| wl.window.active else null;
    return format_mod.format_single(item, raw_path, client, session, winlink, pane);
}

pub fn resolve_path(client: ?*T.Client, raw_path: []const u8) ResolvedPath {
    if (std.mem.eql(u8, raw_path, "-")) return .{ .path = raw_path };
    if (std.mem.startsWith(u8, raw_path, "~/")) {
        const home = std.posix.getenv("HOME") orelse "";
        return .{ .path = xm.xasprintf("{s}/{s}", .{ home, raw_path[2..] }), .owned = true };
    }
    if (std.mem.startsWith(u8, raw_path, "/")) return .{ .path = raw_path };

    const cwd = server_client_mod.server_client_get_cwd(client, null);
    return .{ .path = xm.xasprintf("{s}/{s}", .{ cwd, raw_path }), .owned = true };
}
