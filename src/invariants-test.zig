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

//! Lightweight cross-module sanity checks (types, static tables).
//! Platform glue in `os/linux.zig` and `c.zig` stays under smoke/regress;
//! unit tests there are deferred unless pure helpers are split out.

const std = @import("std");
const T = @import("types.zig");

test "zmux version string is non-empty" {
    try std.testing.expect(T.ZMUX_VERSION.len > 0);
}

test "options scope flags are single-purpose bits" {
    const s = T.OPTIONS_TABLE_SERVER;
    const w = T.OPTIONS_TABLE_WINDOW;
    try std.testing.expect(s.server and !s.window);
    try std.testing.expect(w.window and !w.server);
}

test "OPTIONS_TABLE_SESSION and PANE markers are single-scope" {
    const ses = T.OPTIONS_TABLE_SESSION;
    try std.testing.expect(ses.session and !ses.server and !ses.window and !ses.pane);
    const pane = T.OPTIONS_TABLE_PANE;
    try std.testing.expect(pane.pane and !pane.server and !pane.session and !pane.window);
}

test "key-bindings-data module parses at comptime" {
    comptime {
        _ = @import("key-bindings-data.zig");
    }
}
