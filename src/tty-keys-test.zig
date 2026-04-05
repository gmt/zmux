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

//! tty-keys-test.zig – focused winsz and adjacent tty key parser tests.

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const env_mod = @import("environ.zig");
const tty_keys = @import("tty-keys.zig");
const tty_mod = @import("tty.zig");

const TtyKeysHarness = struct {
    env: *T.Environ,
    cl: T.Client,

    fn init() TtyKeysHarness {
        const env = env_mod.environ_create();
        var self = TtyKeysHarness{
            .env = env,
            .cl = .{
                .environ = env,
                .tty = undefined,
                .status = .{},
            },
        };
        tty_mod.tty_init(&self.cl.tty, &self.cl);
        return self;
    }

    fn deinit(self: *TtyKeysHarness) void {
        self.cl.tty.in_buf.deinit(xm.allocator);
        env_mod.environ_free(self.env);
    }
};

test "tty_winsz helper keeps fragmented character replies pending until terminator" {
    var size: usize = 99;
    const fragments = [_][]const u8{
        "\x1b",
        "\x1b[",
        "\x1b[8;",
        "\x1b[8;24;",
        "\x1b[8;24;80",
    };

    for (fragments) |fragment| {
        try std.testing.expect(tty_keys.tty_keys_winsz(fragment, &size) == null);
        try std.testing.expectEqual(@as(usize, 0), size);
    }

    const reply = tty_keys.tty_keys_winsz("\x1b[8;24;80t", &size);
    try std.testing.expect(reply != null);
    try std.testing.expectEqual(@as(usize, 10), size);
    try std.testing.expectEqual(tty_keys.WinszKind.chars, reply.?.kind);
    try std.testing.expectEqual(@as(u32, 80), reply.?.v1);
    try std.testing.expectEqual(@as(u32, 24), reply.?.v2);
}

test "tty_winsz helper keeps fragmented pixel replies pending until terminator" {
    var size: usize = 99;
    const fragments = [_][]const u8{
        "\x1b",
        "\x1b[",
        "\x1b[4;",
        "\x1b[4;768;",
        "\x1b[4;768;1024",
    };

    for (fragments) |fragment| {
        try std.testing.expect(tty_keys.tty_keys_winsz(fragment, &size) == null);
        try std.testing.expectEqual(@as(usize, 0), size);
    }

    const reply = tty_keys.tty_keys_winsz("\x1b[4;768;1024t", &size);
    try std.testing.expect(reply != null);
    try std.testing.expectEqual(@as(usize, 13), size);
    try std.testing.expectEqual(tty_keys.WinszKind.pixels, reply.?.kind);
    try std.testing.expectEqual(@as(u32, 1024), reply.?.v1);
    try std.testing.expectEqual(@as(u32, 768), reply.?.v2);
}

test "tty_winsz helper rejects malformed adjacent replies without consuming bytes" {
    var size: usize = 99;

    try std.testing.expect(tty_keys.tty_keys_winsz("\x1b[8;24;80x", &size) == null);
    try std.testing.expectEqual(@as(usize, 0), size);

    try std.testing.expect(tty_keys.tty_keys_winsz("\x1b[4;768;1024x", &size) == null);
    try std.testing.expectEqual(@as(usize, 0), size);

    try std.testing.expect(tty_keys.tty_keys_winsz("\x1b[9;24;80t", &size) == null);
    try std.testing.expectEqual(@as(usize, 0), size);
}

test "tty_keys_next keeps fragmented winsz bytes buffered until the reply is complete" {
    var harness = TtyKeysHarness.init();
    defer harness.deinit();

    try harness.cl.tty.in_buf.appendSlice(xm.allocator, "\x1b");
    try std.testing.expect(!tty_mod.tty_keys_next(&harness.cl.tty));
    try std.testing.expectEqualStrings("\x1b", harness.cl.tty.in_buf.items);

    try harness.cl.tty.in_buf.appendSlice(xm.allocator, "[");
    try std.testing.expect(!tty_mod.tty_keys_next(&harness.cl.tty));
    try std.testing.expectEqualStrings("\x1b[", harness.cl.tty.in_buf.items);

    try harness.cl.tty.in_buf.appendSlice(xm.allocator, "8;31;91");
    try std.testing.expect(!tty_mod.tty_keys_next(&harness.cl.tty));
    try std.testing.expectEqualStrings("\x1b[8;31;91", harness.cl.tty.in_buf.items);
}

test "tty_keys_next reclassifies unsolicited winsz replies into ordinary input" {
    var harness = TtyKeysHarness.init();
    defer harness.deinit();

    try std.testing.expectEqual(@as(u32, 80), harness.cl.tty.sx);
    try std.testing.expectEqual(@as(u32, 24), harness.cl.tty.sy);

    try harness.cl.tty.in_buf.appendSlice(xm.allocator, "\x1b[8;31;91t");

    try std.testing.expect(tty_mod.tty_keys_next(&harness.cl.tty));
    try std.testing.expectEqualStrings("8;31;91t", harness.cl.tty.in_buf.items);
    try std.testing.expectEqual(@as(u32, 80), harness.cl.tty.sx);
    try std.testing.expectEqual(@as(u32, 24), harness.cl.tty.sy);
    try std.testing.expect(harness.cl.tty.flags & @as(i32, @intCast(T.TTY_WINSIZEQUERY)) == 0);
}

test "tty_keys_next does not pin later input behind unsolicited winsz replies" {
    var harness = TtyKeysHarness.init();
    defer harness.deinit();

    try harness.cl.tty.in_buf.appendSlice(xm.allocator, "\x1b[8;31;91ta");

    try std.testing.expect(tty_mod.tty_keys_next(&harness.cl.tty));
    try std.testing.expectEqualStrings("8;31;91ta", harness.cl.tty.in_buf.items);

    while (tty_mod.tty_keys_next(&harness.cl.tty)) {}

    try std.testing.expectEqualStrings("", harness.cl.tty.in_buf.items);
    try std.testing.expectEqual(@as(u32, 80), harness.cl.tty.sx);
    try std.testing.expectEqual(@as(u32, 24), harness.cl.tty.sy);
}

test "tty_keys_next consumes winsz replies only while query gate is active" {
    var harness = TtyKeysHarness.init();
    defer harness.deinit();

    harness.cl.tty.flags |= @as(i32, @intCast(T.TTY_WINSIZEQUERY));

    try harness.cl.tty.in_buf.appendSlice(xm.allocator, "\x1b[8;31;91t");
    try std.testing.expect(tty_mod.tty_keys_next(&harness.cl.tty));
    try std.testing.expectEqualStrings("", harness.cl.tty.in_buf.items);
    try std.testing.expectEqual(@as(u32, 91), harness.cl.tty.sx);
    try std.testing.expectEqual(@as(u32, 31), harness.cl.tty.sy);
    try std.testing.expect(harness.cl.tty.flags & @as(i32, @intCast(T.TTY_WINSIZEQUERY)) != 0);

    try harness.cl.tty.in_buf.appendSlice(xm.allocator, "\x1b[4;1240;1820t");
    try std.testing.expect(tty_mod.tty_keys_next(&harness.cl.tty));
    try std.testing.expectEqualStrings("", harness.cl.tty.in_buf.items);
    try std.testing.expectEqual(@as(u32, 20), harness.cl.tty.xpixel);
    try std.testing.expectEqual(@as(u32, 40), harness.cl.tty.ypixel);
    try std.testing.expect(harness.cl.tty.flags & @as(i32, @intCast(T.TTY_WINSIZEQUERY)) == 0);
}
