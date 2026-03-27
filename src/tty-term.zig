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
// Written for zmux by Greg Turner. This file is new zmux runtime work that
// gives the reduced tty/runtime path one real terminfo-backed capability seam.

//! tty-term.zig – reduced terminfo capture and capability queries.

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const c = @import("c.zig");

const CapabilityType = enum {
    string,
    number,
};

const CapabilitySpec = struct {
    name: []const u8,
    kind: CapabilityType,
};

const selected_caps = [_]CapabilitySpec{
    .{ .name = "U8", .kind = .number },
    .{ .name = "acsc", .kind = .string },
    .{ .name = "tsl", .kind = .string },
    .{ .name = "fsl", .kind = .string },
    .{ .name = "kmous", .kind = .string },
    .{ .name = "Enbp", .kind = .string },
    .{ .name = "Dsbp", .kind = .string },
    .{ .name = "Enfcs", .kind = .string },
    .{ .name = "Dsfcs", .kind = .string },
};

pub fn readTermCaps(term_name: []const u8, fd: i32) ![][]u8 {
    const term_z = xm.xm_dupeZ(term_name);
    defer xm.allocator.free(term_z);

    var err: c_int = 0;
    if (c.ncurses.setupterm(term_z.ptr, fd, &err) != c.ncurses.OK)
        return xm.allocator.alloc([]u8, 0);
    defer {
        if (@hasDecl(c.ncurses, "del_curterm") and @hasDecl(c.ncurses, "cur_term")) {
            if (c.ncurses.cur_term != null)
                _ = c.ncurses.del_curterm(c.ncurses.cur_term);
        }
    }

    var caps: std.ArrayList([]u8) = .{};
    errdefer {
        for (caps.items) |cap| xm.allocator.free(cap);
        caps.deinit(xm.allocator);
    }

    for (selected_caps) |spec| {
        const value = switch (spec.kind) {
            .string => readStringCapability(spec.name),
            .number => readNumberCapability(spec.name),
        } orelse continue;

        const cap_entry = try std.fmt.allocPrint(xm.allocator, "{s}={s}", .{ spec.name, value });
        try caps.append(xm.allocator, cap_entry);
        if (spec.kind == .number)
            xm.allocator.free(value);
    }

    return caps.toOwnedSlice(xm.allocator);
}

pub fn freeTermCaps(caps: [][]u8) void {
    for (caps) |cap| xm.allocator.free(cap);
    xm.allocator.free(caps);
}

pub fn hasCapability(tty: *const T.Tty, name: []const u8) bool {
    return capabilityValue(tty.client, name) != null;
}

pub fn stringCapability(tty: *const T.Tty, name: []const u8) ?[]const u8 {
    return capabilityValue(tty.client, name);
}

pub fn numberCapability(tty: *const T.Tty, name: []const u8) ?i32 {
    const value = capabilityValue(tty.client, name) orelse return null;
    return std.fmt.parseInt(i32, value, 10) catch null;
}

pub fn acsCapability(tty: *const T.Tty, ch: u8) ?[]const u8 {
    const mapping = stringCapability(tty, "acsc") orelse return null;

    var idx: usize = 0;
    while (idx + 1 < mapping.len) : (idx += 2) {
        if (mapping[idx] != ch) continue;
        return mapping[idx + 1 .. idx + 2];
    }
    return null;
}

fn capabilityValue(cl: *const T.Client, name: []const u8) ?[]const u8 {
    const caps = cl.term_caps orelse return null;
    for (caps) |cap| {
        if (!std.mem.startsWith(u8, cap, name)) continue;
        if (cap.len <= name.len or cap[name.len] != '=') continue;
        return cap[name.len + 1 ..];
    }
    return null;
}

fn readStringCapability(name: []const u8) ?[]const u8 {
    const name_z = xm.xm_dupeZ(name);
    defer xm.allocator.free(name_z);

    const raw = c.ncurses.tigetstr(name_z.ptr);
    if (raw == null) return null;
    if (@intFromPtr(raw.?) == std.math.maxInt(usize)) return null;
    return xm.xstrdup(std.mem.span(raw.?));
}

fn readNumberCapability(name: []const u8) ?[]u8 {
    const name_z = xm.xm_dupeZ(name);
    defer xm.allocator.free(name_z);

    const value = c.ncurses.tigetnum(name_z.ptr);
    if (value == -1 or value == -2) return null;
    return xm.xasprintf("{d}", .{value});
}

test "tty_term parses numeric, string, and ACS capabilities from reduced terminfo state" {
    var caps = [_][]u8{
        @constCast("U8=0"),
        @constCast("acsc=qx"),
        @constCast("tsl=\x1b]0;"),
        @constCast("fsl=\x07"),
    };
    var client = T.Client{
        .environ = undefined,
        .tty = undefined,
        .status = .{ .screen = undefined },
        .term_caps = caps[0..],
    };
    client.tty = .{ .client = &client };

    try std.testing.expectEqual(@as(i32, 0), numberCapability(&client.tty, "U8").?);
    try std.testing.expectEqualStrings("\x1b]0;", stringCapability(&client.tty, "tsl").?);
    try std.testing.expectEqualStrings("x", acsCapability(&client.tty, 'q').?);
    try std.testing.expect(hasCapability(&client.tty, "fsl"));
    try std.testing.expect(!hasCapability(&client.tty, "kmous"));
}
