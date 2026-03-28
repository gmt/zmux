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
// Ported in part from tmux/tty.c.
// Original copyright:
//   Copyright (c) 2007 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

//! tty.zig – reduced server-side tty lifecycle and metadata helpers.

const std = @import("std");
const c = @import("c.zig");
const T = @import("types.zig");
const file_mod = @import("file.zig");
const proc_mod = @import("proc.zig");
const xm = @import("xmalloc.zig");
const tty_features = @import("tty-features.zig");
const tty_term = @import("tty-term.zig");

pub fn tty_init(tty: *T.Tty, cl: *T.Client) void {
    tty.* = .{ .client = cl };
}

pub fn tty_set_size(tty: *T.Tty, sx: u32, sy: u32, xpixel: u32, ypixel: u32) void {
    tty.sx = @max(sx, 1);
    tty.sy = @max(sy, 1);
    tty.xpixel = if (xpixel == 0) T.DEFAULT_XPIXEL else xpixel;
    tty.ypixel = if (ypixel == 0) T.DEFAULT_YPIXEL else ypixel;
}

pub fn tty_resize(tty: *T.Tty, sx: u32, sy: u32, xpixel: u32, ypixel: u32) void {
    tty_set_size(tty, sx, sy, xpixel, ypixel);
    tty_invalidate(tty);
}

pub fn tty_open(tty: *T.Tty, cause: *?[]u8) i32 {
    cause.* = null;
    tty.flags |= @intCast(T.TTY_OPENED);
    tty.flags &= ~@as(i32, @intCast(T.TTY_NOCURSOR | T.TTY_FREEZE | T.TTY_BLOCK));
    tty_start_tty(tty);
    return 0;
}

pub fn tty_close(tty: *T.Tty) void {
    tty_stop_tty(tty);
    freeClipboardTimer(tty);
    tty.flags &= ~@as(i32, @intCast(T.TTY_OPENED));
}

pub fn tty_start_tty(tty: *T.Tty) void {
    if ((tty.flags & @as(i32, @intCast(T.TTY_STARTED))) != 0) return;
    tty.flags |= @intCast(T.TTY_STARTED);
    tty_invalidate(tty);
}

pub fn tty_stop_tty(tty: *T.Tty) void {
    cancelClipboardQuery(tty);
    tty.flags &= ~@as(i32, @intCast(T.TTY_STARTED | T.TTY_BLOCK));
}

pub fn tty_invalidate(tty: *T.Tty) void {
    tty.cx = std.math.maxInt(u32);
    tty.cy = std.math.maxInt(u32);
    tty.cstyle = .default;
    tty.ccolour = -1;
    tty.mode = 0;
    tty.fg = 8;
    tty.bg = 8;
}

pub fn tty_set_title(tty: *T.Tty, title: []const u8) void {
    if (title.len == 0) return;
    if ((tty.flags & @as(i32, @intCast(T.TTY_STARTED))) == 0) return;
    if (!tty_features.supportsTty(tty, .title)) return;

    const sequence = if (tty_term.stringCapability(tty, "tsl")) |tsl| blk: {
        const fsl = tty_term.stringCapability(tty, "fsl") orelse break :blk null;
        break :blk std.fmt.allocPrint(xm.allocator, "{s}{s}{s}", .{ tsl, title, fsl }) catch return;
    } else std.fmt.allocPrint(xm.allocator, "\x1b]2;{s}\x07", .{title}) catch return;
    if (sequence == null) return;
    defer xm.allocator.free(sequence.?);
    tty_write(tty, sequence.?);
}

pub fn tty_clipboard_query(tty: *T.Tty) void {
    if ((tty.flags & @as(i32, @intCast(T.TTY_STARTED))) == 0) return;
    if ((tty.flags & @as(i32, @intCast(T.TTY_OSC52QUERY))) != 0) return;

    const ms = tty_term.stringCapability(tty, "Ms") orelse return;
    const sequence = formatClipboardCapability(ms, "", "?") orelse return;
    defer xm.allocator.free(sequence);

    tty_write(tty, sequence);
    armClipboardTimer(tty);
}

pub fn tty_append_mode_update(tty: *T.Tty, mode: i32, out: *std.ArrayList(u8)) !void {
    var actual = mode;
    if ((tty.flags & @as(i32, @intCast(T.TTY_NOCURSOR))) != 0)
        actual &= ~@as(i32, T.MODE_CURSOR);

    const supports_mouse = tty_features.supportsTty(tty, .mouse);
    const supports_bpaste = tty_features.supportsTty(tty, .bpaste);
    const supports_focus = tty_features.supportsTty(tty, .focus);
    if (!supports_mouse)
        actual &= ~@as(i32, T.ALL_MOUSE_MODES);
    if (!supports_bpaste)
        actual &= ~@as(i32, T.MODE_BRACKETPASTE);
    if (!supports_focus)
        actual &= ~@as(i32, T.MODE_FOCUSON);

    const changed = actual ^ tty.mode;
    if ((changed & T.ALL_MOUSE_MODES) != 0 and (supports_mouse or (tty.mode & T.ALL_MOUSE_MODES) != 0)) {
        try out.appendSlice(xm.allocator, "\x1b[?1006l\x1b[?1005l\x1b[?1000l\x1b[?1002l\x1b[?1003l");
        if (supports_mouse and (actual & T.ALL_MOUSE_MODES) != 0)
            try out.appendSlice(xm.allocator, "\x1b[?1006h");
        if (supports_mouse and (actual & T.MODE_MOUSE_ALL) != 0)
            try out.appendSlice(xm.allocator, "\x1b[?1000h\x1b[?1002h\x1b[?1003h")
        else if (supports_mouse and (actual & T.MODE_MOUSE_BUTTON) != 0)
            try out.appendSlice(xm.allocator, "\x1b[?1000h\x1b[?1002h")
        else if (supports_mouse and (actual & T.MODE_MOUSE_STANDARD) != 0)
            try out.appendSlice(xm.allocator, "\x1b[?1000h");
    }
    if ((changed & T.MODE_BRACKETPASTE) != 0 and (supports_bpaste or (tty.mode & T.MODE_BRACKETPASTE) != 0)) {
        try appendCapabilityToggle(
            tty,
            out,
            "Enbp",
            "Dsbp",
            "\x1b[?2004h",
            "\x1b[?2004l",
            (actual & T.MODE_BRACKETPASTE) != 0,
        );
    }
    if ((changed & T.MODE_FOCUSON) != 0 and (supports_focus or (tty.mode & T.MODE_FOCUSON) != 0)) {
        try appendCapabilityToggle(
            tty,
            out,
            "Enfcs",
            "Dsfcs",
            "\x1b[?1004h",
            "\x1b[?1004l",
            (actual & T.MODE_FOCUSON) != 0,
        );
    }

    tty.mode = actual;
}

fn appendCapabilityToggle(
    tty: *const T.Tty,
    out: *std.ArrayList(u8),
    enable_cap: []const u8,
    disable_cap: []const u8,
    fallback_enable: []const u8,
    fallback_disable: []const u8,
    enabled: bool,
) !void {
    const cap_name = if (enabled) enable_cap else disable_cap;
    const fallback = if (enabled) fallback_enable else fallback_disable;
    const sequence = tty_term.stringCapability(tty, cap_name) orelse fallback;
    try out.appendSlice(xm.allocator, sequence);
}

fn formatClipboardCapability(template: []const u8, clip: []const u8, value: []const u8) ?[]u8 {
    var out: std.ArrayList(u8) = .{};
    errdefer out.deinit(xm.allocator);

    var idx: usize = 0;
    while (idx < template.len) {
        if (std.mem.startsWith(u8, template[idx..], "%p1%s")) {
            out.appendSlice(xm.allocator, clip) catch return null;
            idx += "%p1%s".len;
            continue;
        }
        if (std.mem.startsWith(u8, template[idx..], "%p2%s")) {
            out.appendSlice(xm.allocator, value) catch return null;
            idx += "%p2%s".len;
            continue;
        }
        if (std.mem.startsWith(u8, template[idx..], "%%")) {
            out.append(xm.allocator, '%') catch return null;
            idx += 2;
            continue;
        }
        if (template[idx] == '%') return null;

        out.append(xm.allocator, template[idx]) catch return null;
        idx += 1;
    }

    return out.toOwnedSlice(xm.allocator) catch null;
}

fn armClipboardTimer(tty: *T.Tty) void {
    const base = proc_mod.libevent orelse return;

    if (tty.clipboard_timer == null) {
        tty.clipboard_timer = c.libevent.event_new(
            base,
            -1,
            @intCast(c.libevent.EV_TIMEOUT),
            tty_clipboard_query_timeout_cb,
            tty,
        );
    }
    if (tty.clipboard_timer) |ev| {
        tty.flags |= @as(i32, @intCast(T.TTY_OSC52QUERY));
        var tv = std.posix.timeval{ .sec = 5, .usec = 0 };
        _ = c.libevent.event_add(ev, @ptrCast(&tv));
    }
}

fn cancelClipboardQuery(tty: *T.Tty) void {
    if (tty.clipboard_timer) |ev| _ = c.libevent.event_del(ev);
    tty.flags &= ~@as(i32, @intCast(T.TTY_OSC52QUERY));
}

fn freeClipboardTimer(tty: *T.Tty) void {
    cancelClipboardQuery(tty);
    if (tty.clipboard_timer) |ev| {
        c.libevent.event_free(ev);
        tty.clipboard_timer = null;
    }
}

export fn tty_clipboard_query_timeout_cb(_fd: c_int, _events: c_short, arg: ?*anyopaque) void {
    _ = _fd;
    _ = _events;
    const tty: *T.Tty = @ptrCast(@alignCast(arg orelse return));
    cancelClipboardQuery(tty);
}

fn tty_write(tty: *T.Tty, payload: []const u8) void {
    const peer = tty.client.peer orelse return;
    if ((tty.client.flags & T.CLIENT_CONTROL) != 0) return;

    _ = file_mod.sendPeerStream(peer, 1, payload);
}

test "tty_open starts reduced tty lifecycle" {
    const env_mod = @import("environ.zig");

    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);

    var cl = T.Client{
        .environ = env,
        .tty = undefined,
        .status = .{ .screen = undefined },
    };
    tty_init(&cl.tty, &cl);

    cl.tty.cx = 7;
    cl.tty.cy = 9;
    cl.tty.mode = 123;
    cl.tty.fg = 3;
    cl.tty.bg = 4;

    var cause: ?[]u8 = null;
    try std.testing.expectEqual(@as(i32, 0), tty_open(&cl.tty, &cause));
    try std.testing.expect(cause == null);
    try std.testing.expect((cl.tty.flags & @as(i32, @intCast(T.TTY_OPENED))) != 0);
    try std.testing.expect((cl.tty.flags & @as(i32, @intCast(T.TTY_STARTED))) != 0);
    try std.testing.expectEqual(std.math.maxInt(u32), cl.tty.cx);
    try std.testing.expectEqual(std.math.maxInt(u32), cl.tty.cy);
    try std.testing.expectEqual(@as(i32, 8), cl.tty.fg);
    try std.testing.expectEqual(@as(i32, 8), cl.tty.bg);

    tty_close(&cl.tty);
    try std.testing.expect((cl.tty.flags & @as(i32, @intCast(T.TTY_OPENED))) == 0);
    try std.testing.expect((cl.tty.flags & @as(i32, @intCast(T.TTY_STARTED))) == 0);
}

test "tty_resize clamps size and restores default pixels" {
    const env_mod = @import("environ.zig");

    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);

    var cl = T.Client{
        .environ = env,
        .tty = undefined,
        .status = .{ .screen = undefined },
    };
    tty_init(&cl.tty, &cl);

    tty_resize(&cl.tty, 0, 0, 0, 0);
    try std.testing.expectEqual(@as(u32, 1), cl.tty.sx);
    try std.testing.expectEqual(@as(u32, 1), cl.tty.sy);
    try std.testing.expectEqual(T.DEFAULT_XPIXEL, cl.tty.xpixel);
    try std.testing.expectEqual(T.DEFAULT_YPIXEL, cl.tty.ypixel);
}

test "tty_append_mode_update emits reduced outer mouse, bracketed-paste, and focus negotiation" {
    const env_mod = @import("environ.zig");

    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);

    var caps = [_][]u8{
        @constCast("kmous=\x1b[M"),
        @constCast("Enbp=\x1b[?2004h"),
        @constCast("Dsbp=\x1b[?2004l"),
        @constCast("Enfcs=\x1b[?1004h"),
        @constCast("Dsfcs=\x1b[?1004l"),
    };
    var cl = T.Client{
        .environ = env,
        .tty = undefined,
        .status = .{ .screen = undefined },
        .term_caps = caps[0..],
    };
    tty_init(&cl.tty, &cl);

    var out: std.ArrayList(u8) = .{};
    defer out.deinit(xm.allocator);

    try tty_append_mode_update(&cl.tty, T.MODE_MOUSE_BUTTON | T.MODE_BRACKETPASTE | T.MODE_FOCUSON, &out);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\x1b[?1006h") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\x1b[?1002h") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\x1b[?2004h") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\x1b[?1004h") != null);

    out.clearRetainingCapacity();
    try tty_append_mode_update(&cl.tty, 0, &out);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\x1b[?1006l") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\x1b[?2004l") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\x1b[?1004l") != null);
}

test "tty_append_mode_update suppresses unsupported outer modes on reduced dumb terminals" {
    const env_mod = @import("environ.zig");

    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);

    var cl = T.Client{
        .environ = env,
        .tty = undefined,
        .status = .{ .screen = undefined },
        .term_caps = &.{},
    };
    tty_init(&cl.tty, &cl);

    var out: std.ArrayList(u8) = .{};
    defer out.deinit(xm.allocator);

    try tty_append_mode_update(&cl.tty, T.MODE_MOUSE_BUTTON | T.MODE_BRACKETPASTE | T.MODE_FOCUSON, &out);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
    try std.testing.expectEqual(@as(i32, 0), cl.tty.mode);
}

test "tty_append_mode_update falls back to standard toggles when only feature bits are known" {
    const env_mod = @import("environ.zig");

    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);

    var cl = T.Client{
        .environ = env,
        .tty = undefined,
        .status = .{ .screen = undefined },
        .term_features = tty_features.featureBit(.bpaste) | tty_features.featureBit(.focus),
    };
    tty_init(&cl.tty, &cl);

    var out: std.ArrayList(u8) = .{};
    defer out.deinit(xm.allocator);

    try tty_append_mode_update(&cl.tty, T.MODE_BRACKETPASTE | T.MODE_FOCUSON, &out);
    try std.testing.expectEqualStrings("\x1b[?2004h\x1b[?1004h", out.items);

    out.clearRetainingCapacity();
    try tty_append_mode_update(&cl.tty, 0, &out);
    try std.testing.expectEqualStrings("\x1b[?2004l\x1b[?1004l", out.items);
}

test "tty_set_title honours the reduced title capability layer" {
    const env_mod = @import("environ.zig");

    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);

    var cl = T.Client{
        .environ = env,
        .tty = undefined,
        .status = .{ .screen = undefined },
        .term_caps = &.{},
    };
    tty_init(&cl.tty, &cl);
    cl.tty.flags |= @as(i32, @intCast(T.TTY_STARTED));

    tty_set_title(&cl.tty, "suppressed");
}

test "tty_clipboard_query emits the recorded Ms capability query" {
    const proc_mod_local = @import("proc.zig");

    var pair: [2]i32 = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &pair));

    var proc = T.ZmuxProc{ .name = "tty-clipboard-query-test" };
    defer proc.peers.deinit(xm.allocator);

    var caps = [_][]u8{
        @constCast("Ms=\x1b]52;c;!\x07\x1b]52;c;%p2%s\x07"),
    };
    var cl = T.Client{
        .environ = undefined,
        .tty = undefined,
        .status = .{ .screen = undefined },
        .term_caps = caps[0..],
    };
    tty_init(&cl.tty, &cl);
    tty_start_tty(&cl.tty);
    cl.peer = proc_mod_local.proc_add_peer(&proc, pair[0], test_peer_dispatch, null);
    defer {
        const peer = cl.peer.?;
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

    tty_clipboard_query(&cl.tty);

    try std.testing.expectEqual(@as(i32, 1), c.imsg.imsgbuf_read(&reader));

    var imsg_msg: c.imsg.imsg = undefined;
    try std.testing.expect(c.imsg.imsg_get(&reader, &imsg_msg) > 0);
    defer c.imsg.imsg_free(&imsg_msg);

    try std.testing.expectEqual(@as(u32, @intCast(@intFromEnum(@import("zmux-protocol.zig").MsgType.write))), c.imsg.imsg_get_type(&imsg_msg));

    const payload_len = c.imsg.imsg_get_len(&imsg_msg);
    var payload = try xm.allocator.alloc(u8, payload_len);
    defer xm.allocator.free(payload);
    try std.testing.expectEqual(@as(i32, 0), c.imsg.imsg_get_data(&imsg_msg, payload.ptr, payload.len));

    var stream: i32 = 0;
    @memcpy(std.mem.asBytes(&stream), payload[0..@sizeOf(i32)]);
    try std.testing.expectEqual(@as(i32, 1), stream);
    try std.testing.expectEqualStrings("\x1b]52;c;!\x07\x1b]52;c;?\x07", payload[@sizeOf(i32)..]);
}

fn test_peer_dispatch(_: ?*c.imsg.imsg, _: ?*anyopaque) callconv(.c) void {}
