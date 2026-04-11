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

//! window-test.zig – tests for window.zig, extracted from window.zig.

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const opts = @import("options.zig");
const win = @import("window.zig");
const colour_mod = @import("colour.zig");
const client_registry = @import("client-registry.zig");
const env_mod = @import("environ.zig");
const layout_mod = @import("layout.zig");
const screen_mod = @import("screen.zig");
const grid_mod = @import("grid.zig");
const sess = @import("session.zig");
const c = @import("c.zig");

// ── Test helpers ─────────────────────────────────────────────────────────

fn set_nonblocking_for_test(fd: i32) void {
    const flags = std.c.fcntl(fd, std.posix.F.GETFL, @as(c_int, 0));
    if (flags < 0) return;
    const O_NONBLOCK: c_int = 0x800;
    _ = std.c.fcntl(fd, std.posix.F.SETFL, flags | O_NONBLOCK);
}

fn read_pipe_best_effort(fd: i32, buf: []u8) ![]const u8 {
    const n = std.posix.read(fd, buf) catch |err| switch (err) {
        error.WouldBlock => return &.{},
        else => return err,
    };
    return buf[0..n];
}

fn write_test_line(gd: *T.Grid, row: u32, text: []const u8) void {
    for (text, 0..) |ch, col| {
        grid_mod.set_ascii(gd, row, @intCast(col), ch);
    }
}

const TestPaneGeometry = struct {
    xoff: u32,
    yoff: u32,
    sx: u32,
    sy: u32,
};

fn pane_geometry_for_test(wp: *T.WindowPane) TestPaneGeometry {
    return .{
        .xoff = wp.xoff,
        .yoff = wp.yoff,
        .sx = wp.sx,
        .sy = wp.sy,
    };
}

fn set_pane_geometry_for_test(wp: *T.WindowPane, geometry: TestPaneGeometry) void {
    wp.xoff = geometry.xoff;
    wp.yoff = geometry.yoff;
    win.window_pane_resize(wp, geometry.sx, geometry.sy);
}

fn init_session_window_test_globals() void {
    opts.global_options = opts.options_create(null);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.global_s_options = opts.options_create(null);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_set_string(opts.global_s_options, false, "default-shell", "/bin/true");
    opts.global_w_options = opts.options_create(null);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);

    env_mod.global_environ = env_mod.environ_create();
    sess.session_init_globals(xm.allocator);
    win.window_init_globals(xm.allocator);
}

fn deinit_session_window_test_globals() void {
    env_mod.environ_free(env_mod.global_environ);
    opts.options_free(opts.global_options);
    opts.options_free(opts.global_s_options);
    opts.options_free(opts.global_w_options);
}

// ── Tests ────────────────────────────────────────────────────────────────

test "window panes inherit from their window options and refresh cached pane state" {
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    win.window_init_globals(xm.allocator);

    const w = win.window_create(80, 24, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);

    const wp = win.window_add_pane(w, null, 80, 24);
    defer {
        _ = win.all_window_panes.remove(wp.id);
        win.window_pane_destroy(wp);
        opts.options_free(w.options);
        xm.allocator.free(w.name);
        _ = win.windows.remove(w.id);
        xm.allocator.destroy(w);
    }

    try std.testing.expect(wp.options != opts.global_w_options);
    try std.testing.expectEqual(w.options, wp.options.parent.?);

    opts.options_set_string(wp.options, false, "pane-scrollbars-style", "fg=blue,pad=4");
    win.window_pane_options_changed(wp, "pane-scrollbars-style");
    try std.testing.expectEqual(@as(i32, 4), wp.scrollbar_style.pad);
    try std.testing.expectEqual(@as(i32, 4), wp.scrollbar_style.gc.fg);

    opts.options_set_array(wp.options, "pane-colours", &.{ "1=#010203", "2=brightred" });
    win.window_pane_options_changed(wp, "pane-colours");
    try std.testing.expectEqual(colour_mod.colour_join_rgb(0x01, 0x02, 0x03), colour_mod.colour_palette_get(&wp.palette, 1));
    try std.testing.expectEqual(@as(i32, 91), colour_mod.colour_palette_get(&wp.palette, 2));
}

test "window_hit_test derives scrollbar regions from shared pane geometry" {
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    win.window_init_globals(xm.allocator);

    const w = win.window_create(4, 4, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    defer {
        while (w.panes.items.len > 0) {
            const pane = w.panes.items[w.panes.items.len - 1];
            win.window_remove_pane(w, pane);
        }
        w.panes.deinit(xm.allocator);
        w.last_panes.deinit(xm.allocator);
        opts.options_free(w.options);
        xm.allocator.free(w.name);
        _ = win.windows.remove(w.id);
        xm.allocator.destroy(w);
    }

    const wp = win.window_add_pane(w, null, 4, 4);
    w.active = wp;
    opts.options_set_number(wp.options, "pane-scrollbars", T.PANE_SCROLLBARS_ALWAYS);
    wp.base.grid.hsize = 12;

    const upper = win.window_hit_test(w, wp.xoff + wp.sx, wp.yoff).?;
    try std.testing.expectEqual(win.PaneHitRegion.scrollbar_up, upper.region);

    const slider = win.window_hit_test(w, wp.xoff + wp.sx, wp.yoff + wp.sy - 1).?;
    try std.testing.expectEqual(win.PaneHitRegion.scrollbar_slider, slider.region);
    try std.testing.expectEqual(@as(i32, 0), slider.slider_mpos);
    try std.testing.expectEqual(@as(u32, 1), wp.sb_slider_h);
    try std.testing.expectEqual(@as(u32, wp.sy - 1), wp.sb_slider_y);
}

test "window_set_active_pane tracks last pane history and detach prunes it" {
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    win.window_init_globals(xm.allocator);

    const w = win.window_create(80, 24, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    defer {
        while (w.panes.items.len > 0) {
            const wp = w.panes.items[w.panes.items.len - 1];
            win.window_remove_pane(w, wp);
        }
        w.panes.deinit(xm.allocator);
        w.last_panes.deinit(xm.allocator);
        opts.options_free(w.options);
        xm.allocator.free(w.name);
        _ = win.windows.remove(w.id);
        xm.allocator.destroy(w);
    }

    const first = win.window_add_pane(w, null, 80, 24);
    const second = win.window_add_pane(w, null, 80, 24);
    const third = win.window_add_pane(w, null, 80, 24);
    _ = third;

    try std.testing.expectEqual(first, w.active.?);
    try std.testing.expect(win.window_set_active_pane(w, second, true));
    try std.testing.expectEqual(second, w.active.?);
    try std.testing.expectEqual(first, win.window_get_last_pane(w).?);

    try std.testing.expect(win.window_set_active_pane(w, first, true));
    try std.testing.expectEqual(first, w.active.?);
    try std.testing.expectEqual(second, win.window_get_last_pane(w).?);

    try std.testing.expect(win.window_detach_pane(w, second));
    try std.testing.expect(win.window_get_last_pane(w) == null);
}

test "window_pane_search matches visible base rows with tmux-style flags" {
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    win.window_init_globals(xm.allocator);

    const w = win.window_create(24, 3, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    defer {
        while (w.panes.items.len > 0) {
            const wp = w.panes.items[w.panes.items.len - 1];
            win.window_remove_pane(w, wp);
        }
        w.panes.deinit(xm.allocator);
        w.last_panes.deinit(xm.allocator);
        opts.options_free(w.options);
        xm.allocator.free(w.name);
        _ = win.windows.remove(w.id);
        xm.allocator.destroy(w);
    }

    const wp = win.window_add_pane(w, null, 24, 3);
    write_test_line(wp.base.grid, 0, "zero");
    write_test_line(wp.base.grid, 1, "Alpha Beta   ");
    write_test_line(wp.base.grid, 2, "Gamma");

    try std.testing.expectEqual(@as(u32, 2), win.window_pane_search(wp, "Beta", false, false));
    try std.testing.expectEqual(@as(u32, 2), win.window_pane_search(wp, "beta", false, true));
    try std.testing.expectEqual(@as(u32, 2), win.window_pane_search(wp, "^alpha beta$", true, true));
    try std.testing.expectEqual(@as(u32, 0), win.window_pane_search(wp, "^alpha beta$", true, false));

    screen_mod.screen_enter_alternate(wp, true);
    write_test_line(wp.screen.grid, 0, "alternate only");
    try std.testing.expectEqual(@as(u32, 0), win.window_pane_search(wp, "alternate", false, false));
}

test "window_pane_key mirrors encoded bytes to synchronized sibling panes" {
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    win.window_init_globals(xm.allocator);

    const w = win.window_create(20, 4, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    defer {
        while (w.panes.items.len > 0) {
            const wp = w.panes.items[w.panes.items.len - 1];
            win.window_remove_pane(w, wp);
        }
        w.panes.deinit(xm.allocator);
        w.last_panes.deinit(xm.allocator);
        opts.options_free(w.options);
        xm.allocator.free(w.name);
        _ = win.windows.remove(w.id);
        xm.allocator.destroy(w);
    }

    const source = win.window_add_pane(w, null, 20, 4);
    const sibling = win.window_add_pane(w, null, 20, 4);
    w.active = source;

    const source_pipe = try std.posix.pipe();
    const sibling_pipe = try std.posix.pipe();
    defer std.posix.close(source_pipe[0]);
    defer std.posix.close(sibling_pipe[0]);
    source.fd = source_pipe[1];
    sibling.fd = sibling_pipe[1];
    defer {
        if (source.fd >= 0) std.posix.close(source.fd);
        if (sibling.fd >= 0) std.posix.close(sibling.fd);
        source.fd = -1;
        sibling.fd = -1;
    }

    opts.options_set_number(source.options, "synchronize-panes", 1);
    opts.options_set_number(sibling.options, "synchronize-panes", 1);

    try std.testing.expectEqual(@as(i32, 0), win.window_pane_key(source, 'x', null));

    var source_buf: [16]u8 = undefined;
    const source_len = try std.posix.read(source_pipe[0], &source_buf);
    try std.testing.expectEqualStrings("x", source_buf[0..source_len]);

    var sibling_buf: [16]u8 = undefined;
    const sibling_len = try std.posix.read(sibling_pipe[0], &sibling_buf);
    try std.testing.expectEqualStrings("x", sibling_buf[0..sibling_len]);
}

test "window_detach_pane promotes the last active pane and marks it changed" {
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    win.window_init_globals(xm.allocator);

    const w = win.window_create(80, 24, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    defer {
        while (w.panes.items.len > 0) {
            const wp = w.panes.items[w.panes.items.len - 1];
            win.window_remove_pane(w, wp);
        }
        w.panes.deinit(xm.allocator);
        w.last_panes.deinit(xm.allocator);
        opts.options_free(w.options);
        xm.allocator.free(w.name);
        _ = win.windows.remove(w.id);
        xm.allocator.destroy(w);
    }

    const first = win.window_add_pane(w, null, 80, 24);
    const second = win.window_add_pane(w, null, 80, 24);
    const third = win.window_add_pane(w, null, 80, 24);

    try std.testing.expect(win.window_set_active_pane(w, second, true));
    try std.testing.expect(win.window_set_active_pane(w, third, true));
    try std.testing.expect(win.window_detach_pane(w, third));
    try std.testing.expectEqual(second, w.active.?);
    try std.testing.expectEqual(first, win.window_get_last_pane(w).?);
    try std.testing.expect((second.flags & T.PANE_CHANGED) != 0);
}

test "window_detach_pane clears client-local active pane references" {
    var env = T.Environ.init(xm.allocator);
    defer env.deinit();

    client_registry.clients.clearRetainingCapacity();
    defer client_registry.clients.clearRetainingCapacity();

    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    win.window_init_globals(xm.allocator);

    const w = win.window_create(80, 24, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    defer {
        while (w.panes.items.len > 0) {
            const wp = w.panes.items[w.panes.items.len - 1];
            win.window_remove_pane(w, wp);
        }
        w.panes.deinit(xm.allocator);
        w.last_panes.deinit(xm.allocator);
        opts.options_free(w.options);
        xm.allocator.free(w.name);
        _ = win.windows.remove(w.id);
        xm.allocator.destroy(w);
    }

    _ = win.window_add_pane(w, null, 80, 24);
    const second = win.window_add_pane(w, null, 80, 24);

    var client = T.Client{
        .environ = &env,
        .tty = undefined,
        .status = .{},
    };
    defer {
        client_registry.remove(&client);
        client.client_windows.deinit(xm.allocator);
    }
    try client.client_windows.append(xm.allocator, .{ .window = w.id, .pane = second });
    client_registry.add(&client);

    try std.testing.expect(win.window_detach_pane(w, second));
    try std.testing.expectEqual(@as(usize, 0), client.client_windows.items.len);
}

test "window_set_active_pane updates active metadata, focus hooks, and redraw flags" {
    const cmdq = @import("cmd-queue.zig");

    cmdq.cmdq_reset_for_tests();
    defer cmdq.cmdq_reset_for_tests();

    client_registry.clients.clearRetainingCapacity();
    defer client_registry.clients.clearRetainingCapacity();

    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    opts.options_set_number(opts.global_options, "focus-events", 1);
    opts.options_set_array(opts.global_w_options, "window-pane-changed", &.{
        "set-environment -g -F WINDOW_HOOK '#{hook_window_name}'",
    });
    opts.options_set_array(opts.global_w_options, "pane-focus-in", &.{
        "set-environment -g -F FOCUS_IN '#{hook_pane}'",
    });
    opts.options_set_array(opts.global_w_options, "pane-focus-out", &.{
        "set-environment -g -F FOCUS_OUT '#{hook_pane}'",
    });

    env_mod.global_environ = env_mod.environ_create();
    defer env_mod.environ_free(env_mod.global_environ);

    sess.session_init_globals(xm.allocator);
    win.window_init_globals(xm.allocator);

    const s = sess.session_create(null, "window-active-focus", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("window-active-focus") != null) sess.session_destroy(s, false, "test");

    const w = win.window_create(80, 24, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    xm.allocator.free(w.name);
    w.name = xm.xstrdup("focus-window");

    const first = win.window_add_pane(w, null, 80, 24);
    const second = win.window_add_pane(w, null, 80, 24);
    first.base.mode |= T.MODE_FOCUSON;
    second.base.mode |= T.MODE_FOCUSON;

    var cause: ?[]u8 = null;
    const wl = sess.session_attach(s, w, -1, &cause).?;
    s.curw = wl;
    s.attached = 1;
    while (cmdq.cmdq_next(null) != 0) {}

    var client = T.Client{
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{},
        .flags = T.CLIENT_ATTACHED | T.CLIENT_TERMINAL | T.CLIENT_FOCUSED,
        .session = s,
    };
    defer env_mod.environ_free(client.environ);
    client.tty = .{ .client = &client, .sx = 40, .sy = 10 };
    client_registry.add(&client);

    const first_pipe = try std.posix.pipe();
    defer std.posix.close(first_pipe[0]);
    const second_pipe = try std.posix.pipe();
    defer std.posix.close(second_pipe[0]);
    set_nonblocking_for_test(first_pipe[0]);
    set_nonblocking_for_test(second_pipe[0]);
    first.fd = first_pipe[1];
    second.fd = second_pipe[1];

    win.window_update_focus(w);
    while (cmdq.cmdq_next(null) != 0) {}
    try std.testing.expect((first.flags & T.PANE_FOCUSED) != 0);
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("\x1b[I", try read_pipe_best_effort(first_pipe[0], &buf));
    const first_hook = env_mod.environ_find(env_mod.global_environ, "FOCUS_IN").?.value.?;
    const first_hook_expected = xm.xasprintf("%{d}", .{first.id});
    defer xm.allocator.free(first_hook_expected);
    try std.testing.expectEqualStrings(first_hook_expected, first_hook);

    try std.testing.expect(win.window_set_active_pane(w, second, true));
    while (cmdq.cmdq_next(null) != 0) {}

    try std.testing.expectEqual(second, w.active.?);
    try std.testing.expectEqual(@as(u32, 0), second.active_point);
    try std.testing.expect((second.flags & T.PANE_CHANGED) != 0);
    try std.testing.expect((first.flags & T.PANE_FOCUSED) == 0);
    try std.testing.expect((second.flags & T.PANE_FOCUSED) != 0);
    try std.testing.expect((client.flags & T.CLIENT_REDRAWWINDOW) != 0);
    try std.testing.expect((client.flags & T.CLIENT_REDRAWSTATUS) != 0);
    try std.testing.expectEqualStrings("\x1b[O", try read_pipe_best_effort(first_pipe[0], &buf));
    try std.testing.expectEqualStrings("\x1b[I", try read_pipe_best_effort(second_pipe[0], &buf));

    const focus_out_hook = env_mod.environ_find(env_mod.global_environ, "FOCUS_OUT").?.value.?;
    const focus_out_expected = xm.xasprintf("%{d}", .{first.id});
    defer xm.allocator.free(focus_out_expected);
    try std.testing.expectEqualStrings(focus_out_expected, focus_out_hook);

    const focus_in_hook = env_mod.environ_find(env_mod.global_environ, "FOCUS_IN").?.value.?;
    const focus_in_expected = xm.xasprintf("%{d}", .{second.id});
    defer xm.allocator.free(focus_in_expected);
    try std.testing.expectEqualStrings(focus_in_expected, focus_in_hook);
    try std.testing.expectEqualStrings("focus-window", env_mod.environ_find(env_mod.global_environ, "WINDOW_HOOK").?.value.?);
}

test "window_pane_resize queues resize and updates screen" {
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    win.window_init_globals(xm.allocator);

    const w = win.window_create(80, 24, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    defer {
        while (w.panes.items.len > 0) {
            const wp = w.panes.items[w.panes.items.len - 1];
            win.window_remove_pane(w, wp);
        }
        w.panes.deinit(xm.allocator);
        w.last_panes.deinit(xm.allocator);
        opts.options_free(w.options);
        xm.allocator.free(w.name);
        _ = win.windows.remove(w.id);
        xm.allocator.destroy(w);
    }

    const wp = win.window_add_pane(w, null, 80, 24);
    win.window_pane_resize(wp, 60, 12);
    // Pane dimensions updated
    try std.testing.expectEqual(@as(u32, 60), wp.sx);
    try std.testing.expectEqual(@as(u32, 12), wp.sy);
    // Resize queued for TIOCSWINSZ delivery
    try std.testing.expectEqual(@as(usize, 1), wp.resize_queue.items.len);
    try std.testing.expectEqual(@as(u32, 80), wp.resize_queue.items[0].osx);
    try std.testing.expectEqual(@as(u32, 24), wp.resize_queue.items[0].osy);
    try std.testing.expectEqual(@as(u32, 60), wp.resize_queue.items[0].sx);
    try std.testing.expectEqual(@as(u32, 12), wp.resize_queue.items[0].sy);
    // No-op when size unchanged
    win.window_pane_resize(wp, 60, 12);
    try std.testing.expectEqual(@as(usize, 1), wp.resize_queue.items.len);
}

test "window_pane_resize keeps the active alternate screen in sync" {
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    win.window_init_globals(xm.allocator);

    const w = win.window_create(80, 24, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    defer {
        while (w.panes.items.len > 0) {
            const wp = w.panes.items[w.panes.items.len - 1];
            win.window_remove_pane(w, wp);
        }
        w.panes.deinit(xm.allocator);
        w.last_panes.deinit(xm.allocator);
        opts.options_free(w.options);
        xm.allocator.free(w.name);
        _ = win.windows.remove(w.id);
        xm.allocator.destroy(w);
    }

    const wp = win.window_add_pane(w, null, 80, 24);
    screen_mod.screen_enter_alternate(wp, true);
    try std.testing.expect(screen_mod.screen_alternate_active(wp));

    win.window_pane_resize(wp, 60, 12);

    try std.testing.expectEqual(@as(u32, 60), wp.base.grid.sx);
    try std.testing.expectEqual(@as(u32, 12), wp.base.grid.sy);
    try std.testing.expectEqual(@as(u32, 60), wp.screen.grid.sx);
    try std.testing.expectEqual(@as(u32, 12), wp.screen.grid.sy);
}

test "window_rotate_panes rotates order and active pane" {
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    win.window_init_globals(xm.allocator);

    const w = win.window_create(80, 24, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    defer {
        while (w.panes.items.len > 0) {
            const wp = w.panes.items[w.panes.items.len - 1];
            win.window_remove_pane(w, wp);
        }
        w.panes.deinit(xm.allocator);
        w.last_panes.deinit(xm.allocator);
        opts.options_free(w.options);
        xm.allocator.free(w.name);
        _ = win.windows.remove(w.id);
        xm.allocator.destroy(w);
    }

    const first = win.window_add_pane(w, null, 80, 24);
    const second = win.window_add_pane(w, null, 40, 12);
    _ = win.window_set_active_pane(w, second, true);
    const third = win.window_add_pane(w, null, 20, 10);

    try std.testing.expectEqual(first, w.panes.items[0]);
    try std.testing.expectEqual(second, w.panes.items[1]);
    try std.testing.expectEqual(third, w.panes.items[2]);

    _ = win.window_rotate_panes(w, false);
    try std.testing.expectEqual(second, w.panes.items[0]);
    try std.testing.expectEqual(third, w.panes.items[1]);
    try std.testing.expectEqual(first, w.panes.items[2]);
    try std.testing.expectEqual(third, w.active.?);

    _ = win.window_rotate_panes(w, true);
    try std.testing.expectEqual(first, w.panes.items[0]);
    try std.testing.expectEqual(second, w.panes.items[1]);
    try std.testing.expectEqual(third, w.panes.items[2]);
    try std.testing.expectEqual(second, w.active.?);
}

test "window_zoom switches to the target pane and window_unzoom clears the reduced flag" {
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    win.window_init_globals(xm.allocator);

    const w = win.window_create(80, 24, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    defer {
        while (w.panes.items.len > 0) {
            const wp = w.panes.items[w.panes.items.len - 1];
            win.window_remove_pane(w, wp);
        }
        w.panes.deinit(xm.allocator);
        w.last_panes.deinit(xm.allocator);
        opts.options_free(w.options);
        xm.allocator.free(w.name);
        _ = win.windows.remove(w.id);
        xm.allocator.destroy(w);
    }

    const first = win.window_add_pane(w, null, 80, 24);
    const second = win.window_add_pane(w, null, 80, 24);

    try std.testing.expectEqual(first, w.active.?);
    try std.testing.expect(win.window_zoom(second));
    try std.testing.expectEqual(second, w.active.?);
    try std.testing.expect(w.flags & T.WINDOW_ZOOMED != 0);
    try std.testing.expect(!win.window_pane_visible(first));
    try std.testing.expect(win.window_pane_visible(second));

    try std.testing.expect(win.window_unzoom(w));
    try std.testing.expectEqual(@as(u32, 0), w.flags & T.WINDOW_ZOOMED);
    try std.testing.expect(win.window_pane_visible(first));
    try std.testing.expect(win.window_pane_visible(second));
}

test "window_plan_split computes reduced split geometry for horizontal and before splits" {
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    win.window_init_globals(xm.allocator);

    const w = win.window_create(80, 24, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    defer {
        while (w.panes.items.len > 0) {
            const wp = w.panes.items[w.panes.items.len - 1];
            win.window_remove_pane(w, wp);
        }
        w.panes.deinit(xm.allocator);
        w.last_panes.deinit(xm.allocator);
        opts.options_free(w.options);
        xm.allocator.free(w.name);
        _ = win.windows.remove(w.id);
        xm.allocator.destroy(w);
    }

    const wp = win.window_add_pane(w, null, 80, 24);

    const after_plan = try win.window_plan_split(wp, .leftright, 25, 0);
    try std.testing.expectEqual(@as(u32, 54), after_plan.target_after.sx);
    try std.testing.expectEqual(@as(u32, 0), after_plan.target_after.xoff);
    try std.testing.expectEqual(@as(u32, 25), after_plan.new_pane.sx);
    try std.testing.expectEqual(@as(u32, 55), after_plan.new_pane.xoff);

    const before_plan = try win.window_plan_split(wp, .topbottom, 6, T.SPAWN_BEFORE);
    try std.testing.expectEqual(@as(u32, 17), before_plan.target_after.sy);
    try std.testing.expectEqual(@as(u32, 7), before_plan.target_after.yoff);
    try std.testing.expectEqual(@as(u32, 6), before_plan.new_pane.sy);
    try std.testing.expectEqual(@as(u32, 0), before_plan.new_pane.yoff);
}

test "window_plan_split rejects full-size reduced splits once a window already has multiple panes" {
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    win.window_init_globals(xm.allocator);

    const w = win.window_create(80, 24, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    defer {
        while (w.panes.items.len > 0) {
            const wp = w.panes.items[w.panes.items.len - 1];
            win.window_remove_pane(w, wp);
        }
        w.panes.deinit(xm.allocator);
        w.last_panes.deinit(xm.allocator);
        opts.options_free(w.options);
        xm.allocator.free(w.name);
        _ = win.windows.remove(w.id);
        xm.allocator.destroy(w);
    }

    const first = win.window_add_pane(w, null, 80, 24);
    _ = win.window_add_pane(w, null, 80, 24);

    try std.testing.expectError(error.FullSizeNeedsLayout, win.window_plan_split(first, .leftright, -1, T.SPAWN_FULLSIZE));
}

test "window_detach_pane collapses the removed gap back into the remaining layout" {
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    win.window_init_globals(xm.allocator);

    const w = win.window_create(80, 24, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    defer {
        while (w.panes.items.len > 0) {
            const wp = w.panes.items[w.panes.items.len - 1];
            win.window_remove_pane(w, wp);
        }
        w.panes.deinit(xm.allocator);
        w.last_panes.deinit(xm.allocator);
        opts.options_free(w.options);
        xm.allocator.free(w.name);
        _ = win.windows.remove(w.id);
        xm.allocator.destroy(w);
    }

    const first = win.window_add_pane(w, null, 80, 24);
    const second = win.window_add_pane(w, null, 80, 24);
    const plan = try win.window_plan_split(first, .leftright, 25, 0);
    win.window_apply_split_plan(first, second, plan);

    try std.testing.expectEqual(@as(u32, 54), first.sx);
    try std.testing.expectEqual(@as(u32, 25), second.sx);
    try std.testing.expect(win.window_detach_pane(w, second));
    try std.testing.expectEqual(@as(usize, 1), w.panes.items.len);
    try std.testing.expectEqual(@as(u32, 0), first.xoff);
    try std.testing.expectEqual(@as(u32, 0), first.yoff);
    try std.testing.expectEqual(@as(u32, 80), first.sx);
    try std.testing.expectEqual(@as(u32, 24), first.sy);
}

test "window_detach_pane leaves layout-managed windows on the repaired tree geometry" {
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    win.window_init_globals(xm.allocator);

    const w = win.window_create(80, 24, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    defer destroyTestWindow(w);

    const first = win.window_add_pane(w, null, 80, 24);
    layout_mod.layout_init(w, first);

    const second_cell = layout_mod.layout_split_pane(first, .leftright, 25, 0).?;
    const second = win.window_add_pane(w, null, second_cell.sx, second_cell.sy);
    layout_mod.layout_assign_pane(second_cell, second, 0);

    const third_cell = layout_mod.layout_split_pane(second, .leftright, 12, 0).?;
    const third = win.window_add_pane(w, null, third_cell.sx, third_cell.sy);
    layout_mod.layout_assign_pane(third_cell, third, 0);

    const first_before = pane_geometry_for_test(first);
    const second_before = pane_geometry_for_test(second);
    const third_before = pane_geometry_for_test(third);

    try std.testing.expect(layout_mod.layout_close_pane(second));

    const first_expected = pane_geometry_for_test(first);
    const third_expected = pane_geometry_for_test(third);

    try std.testing.expect(second.layout_cell == null);
    try std.testing.expect(first_expected.sx != first_before.sx or third_expected.xoff != third_before.xoff);

    set_pane_geometry_for_test(first, first_before);
    set_pane_geometry_for_test(second, second_before);
    set_pane_geometry_for_test(third, third_before);

    try std.testing.expect(win.window_detach_pane(w, second));
    try std.testing.expectEqual(@as(usize, 2), w.panes.items.len);

    try std.testing.expectEqual(first_expected.xoff, first.xoff);
    try std.testing.expectEqual(first_expected.yoff, first.yoff);
    try std.testing.expectEqual(first_expected.sx, first.sx);
    try std.testing.expectEqual(first_expected.sy, first.sy);

    try std.testing.expectEqual(third_expected.xoff, third.xoff);
    try std.testing.expectEqual(third_expected.yoff, third.yoff);
    try std.testing.expectEqual(third_expected.sx, third.sx);
    try std.testing.expectEqual(third_expected.sy, third.sy);
}

fn destroyTestWindow(w: *T.Window) void {
    while (w.panes.items.len > 0) {
        const wp = w.panes.items[w.panes.items.len - 1];
        win.window_remove_pane(w, wp);
    }
    w.panes.deinit(xm.allocator);
    w.last_panes.deinit(xm.allocator);
    opts.options_free(w.options);
    xm.allocator.free(w.name);
    _ = win.windows.remove(w.id);
    xm.allocator.destroy(w);
}

test "window_resize updates size while honoring default and unchanged pixel dimensions" {
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    win.window_init_globals(xm.allocator);

    const w = win.window_create(80, 24, 900, 700);
    defer destroyTestWindow(w);

    win.window_resize(w, 100, 30, 1440, 960);
    try std.testing.expectEqual(@as(u32, 100), w.sx);
    try std.testing.expectEqual(@as(u32, 30), w.sy);
    try std.testing.expectEqual(@as(u32, 1440), w.xpixel);
    try std.testing.expectEqual(@as(u32, 960), w.ypixel);

    win.window_resize(w, 90, 20, 0, 0);
    try std.testing.expectEqual(@as(u32, 90), w.sx);
    try std.testing.expectEqual(@as(u32, 20), w.sy);
    try std.testing.expectEqual(@as(u32, T.DEFAULT_XPIXEL), w.xpixel);
    try std.testing.expectEqual(@as(u32, T.DEFAULT_YPIXEL), w.ypixel);

    win.window_resize(w, 70, 10, -1, -1);
    try std.testing.expectEqual(@as(u32, 70), w.sx);
    try std.testing.expectEqual(@as(u32, 10), w.sy);
    try std.testing.expectEqual(@as(u32, T.DEFAULT_XPIXEL), w.xpixel);
    try std.testing.expectEqual(@as(u32, T.DEFAULT_YPIXEL), w.ypixel);
}

test "window_push_zoom restores split geometry and window_pop_zoom reapplies zoom" {
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    win.window_init_globals(xm.allocator);

    const w = win.window_create(80, 24, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    defer destroyTestWindow(w);

    const first = win.window_add_pane(w, null, 80, 24);
    layout_mod.layout_init(w, first);

    const second_cell = layout_mod.layout_split_pane(first, .leftright, -1, 0) orelse
        return error.SplitFailed;
    const second = win.window_add_pane(w, null, 40, 24);
    layout_mod.layout_assign_pane(second_cell, second, 0);

    const original_first_width = first.sx;
    const original_second_width = second.sx;

    try std.testing.expect(win.window_zoom(second));
    try std.testing.expect(!win.window_pane_visible(first));
    try std.testing.expect(win.window_pane_visible(second));

    try std.testing.expect(win.window_push_zoom(w, false, true));
    try std.testing.expectEqual(@as(u32, 0), w.flags & T.WINDOW_ZOOMED);
    try std.testing.expect(w.flags & T.WINDOW_WASZOOMED != 0);
    try std.testing.expect(win.window_pane_visible(first));
    try std.testing.expect(win.window_pane_visible(second));
    try std.testing.expectEqual(original_first_width, first.sx);
    try std.testing.expectEqual(original_second_width, second.sx);

    try std.testing.expect(win.window_pop_zoom(w));
    try std.testing.expect(w.flags & T.WINDOW_ZOOMED != 0);
    try std.testing.expectEqual(@as(u32, 0), w.flags & T.WINDOW_WASZOOMED);
    try std.testing.expect(!win.window_pane_visible(first));
    try std.testing.expect(win.window_pane_visible(second));
    try std.testing.expectEqual(second, w.active.?);
}

test "window_destroy_all_panes clears pane membership active state and history" {
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    win.window_init_globals(xm.allocator);

    const w = win.window_create(80, 24, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    defer destroyTestWindow(w);

    const first = win.window_add_pane(w, null, 80, 24);
    const second = win.window_add_pane(w, null, 80, 24);
    const third = win.window_add_pane(w, null, 80, 24);

    try std.testing.expect(win.window_set_active_pane(w, second, true));
    try std.testing.expect(win.window_set_active_pane(w, third, true));
    try std.testing.expectEqual(second, win.window_get_last_pane(w).?);

    win.window_destroy_all_panes(w);

    try std.testing.expectEqual(@as(usize, 0), win.window_count_panes(w));
    try std.testing.expect(w.active == null);
    try std.testing.expectEqual(@as(usize, 0), w.last_panes.items.len);
    try std.testing.expect(win.window_pane_find_by_id(first.id) == null);
    try std.testing.expect(win.window_pane_find_by_id(second.id) == null);
    try std.testing.expect(win.window_pane_find_by_id(third.id) == null);
}

test "window_lost_pane promotes pane history and prunes stale last references" {
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    win.window_init_globals(xm.allocator);

    const w = win.window_create(80, 24, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    defer destroyTestWindow(w);

    const first = win.window_add_pane(w, null, 80, 24);
    const second = win.window_add_pane(w, null, 80, 24);
    const third = win.window_add_pane(w, null, 80, 24);

    try std.testing.expect(win.window_set_active_pane(w, second, true));
    try std.testing.expect(win.window_set_active_pane(w, third, true));
    try std.testing.expectEqual(second, win.window_get_last_pane(w).?);

    win.window_lost_pane(w, third);
    try std.testing.expectEqual(second, w.active.?);
    try std.testing.expectEqual(first, win.window_get_last_pane(w).?);
    try std.testing.expect((second.flags & T.PANE_CHANGED) != 0);

    win.window_lost_pane(w, first);
    try std.testing.expect(win.window_get_last_pane(w) == null);
}

test "grouped session attach and detach keep peer current window while pruning stale history" {
    init_session_window_test_globals();
    defer deinit_session_window_test_globals();

    const leader = sess.session_create(null, "window-group-leader", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("window-group-leader") != null) sess.session_destroy(leader, false, "test");
    const peer = sess.session_create(null, "window-group-peer", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("window-group-peer") != null) sess.session_destroy(peer, false, "test");

    const group = sess.session_group_new("window-group-sync");
    sess.session_group_add(group, leader);
    sess.session_group_add(group, peer);

    var cause: ?[]u8 = null;

    const first_window = win.window_create(80, 24, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    const first_wl = sess.session_attach(leader, first_window, -1, &cause).?;
    first_window.active = win.window_add_pane(first_window, null, 80, 24);
    leader.curw = first_wl;
    const leader_first = sess.winlink_find_by_index(&leader.windows, first_wl.idx).?;
    const peer_first = sess.winlink_find_by_index(&peer.windows, first_wl.idx).?;
    peer.curw = peer_first;

    const second_window = win.window_create(80, 24, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    const second_wl = sess.session_attach(leader, second_window, -1, &cause).?;
    second_window.active = win.window_add_pane(second_window, null, 80, 24);
    const second_idx = second_wl.idx;

    try std.testing.expectEqual(@as(usize, 2), leader.windows.count());
    try std.testing.expectEqual(@as(usize, 2), peer.windows.count());

    const leader_second = sess.winlink_find_by_index(&leader.windows, second_idx).?;
    const peer_second = sess.winlink_find_by_index(&peer.windows, second_idx).?;
    try std.testing.expect(sess.session_set_current(peer, peer_second));
    try std.testing.expect(sess.session_set_current(peer, peer_first));
    try std.testing.expect(sess.session_set_current(leader, leader_second));
    try std.testing.expectEqual(peer_first, peer.curw.?);
    try std.testing.expectEqual(@as(usize, 1), peer.lastw.items.len);
    try std.testing.expectEqual(peer_second, peer.lastw.items[0]);

    const third_window = win.window_create(80, 24, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    const third_wl = sess.session_attach(leader, third_window, -1, &cause).?;
    third_window.active = win.window_add_pane(third_window, null, 80, 24);

    try std.testing.expectEqual(@as(usize, 3), leader.windows.count());
    try std.testing.expectEqual(@as(usize, 3), peer.windows.count());
    try std.testing.expectEqual(peer_first, peer.curw.?);
    try std.testing.expectEqual(@as(usize, 1), peer.lastw.items.len);
    try std.testing.expectEqual(second_idx, peer.lastw.items[0].idx);
    try std.testing.expectEqual(third_wl.window, sess.winlink_find_by_index(&peer.windows, third_wl.idx).?.window);

    try std.testing.expect(!sess.session_detach(leader, leader_second));
    try std.testing.expectEqual(@as(usize, 2), leader.windows.count());
    try std.testing.expectEqual(@as(usize, 2), peer.windows.count());
    try std.testing.expect(sess.winlink_find_by_index(&leader.windows, second_idx) == null);
    try std.testing.expect(sess.winlink_find_by_index(&peer.windows, second_idx) == null);
    try std.testing.expectEqual(leader_first.window, peer.curw.?.window);
    try std.testing.expectEqual(peer_first.idx, peer.curw.?.idx);
    try std.testing.expectEqual(@as(usize, 0), peer.lastw.items.len);
}

test "window_cmp orders windows by id" {
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    win.window_init_globals(xm.allocator);

    const wa = win.window_create(10, 10, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    const wb = win.window_create(10, 10, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    defer destroyTestWindow(wa);
    defer destroyTestWindow(wb);

    if (wa.id < wb.id) {
        try std.testing.expectEqual(std.math.Order.lt, win.window_cmp(wa, wb));
    } else {
        try std.testing.expectEqual(std.math.Order.gt, win.window_cmp(wa, wb));
    }
}

test "window_pane_search finds third row and regex Gamma" {
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    win.window_init_globals(xm.allocator);

    const w = win.window_create(20, 4, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    defer destroyTestWindow(w);

    const wp = win.window_add_pane(w, null, 20, 4);
    write_test_line(wp.base.grid, 0, "aaa");
    write_test_line(wp.base.grid, 1, "bbb");
    write_test_line(wp.base.grid, 2, "ccc");
    write_test_line(wp.base.grid, 3, "Gamma-ray");

    try std.testing.expectEqual(@as(u32, 3), win.window_pane_search(wp, "ccc", false, false));
    try std.testing.expectEqual(@as(u32, 4), win.window_pane_search(wp, "Gamma", false, false));
    try std.testing.expectEqual(@as(u32, 4), win.window_pane_search(wp, "^Gamma", true, false));
}

test "window_adopt_pane moves detached pane into another window" {
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    win.window_init_globals(xm.allocator);

    const w1 = win.window_create(40, 10, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    const w2 = win.window_create(40, 10, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    defer destroyTestWindow(w1);
    defer destroyTestWindow(w2);

    const p = win.window_add_pane(w1, null, 40, 10);
    try std.testing.expect(win.window_detach_pane(w1, p));
    try std.testing.expectEqual(@as(usize, 0), win.window_count_panes(w1));

    win.window_adopt_pane(w2, p);
    try std.testing.expectEqual(@as(usize, 1), win.window_count_panes(w2));
    try std.testing.expectEqual(w2, p.window);
}

test "window_count_panes window_has_pane and directional pane neighbors after horizontal split" {
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    win.window_init_globals(xm.allocator);

    const w = win.window_create(80, 24, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    defer destroyTestWindow(w);

    const left = win.window_add_pane(w, null, 40, 24);
    const right = win.window_add_pane(w, null, 40, 24);
    const plan = try win.window_plan_split(left, .leftright, 40, 0);
    win.window_apply_split_plan(left, right, plan);

    try std.testing.expectEqual(std.math.Order.lt, win.window_pane_cmp(left, right));
    try std.testing.expectEqual(@as(usize, 2), win.window_count_panes(w));
    try std.testing.expect(win.window_has_pane(w, left));
    try std.testing.expect(win.window_has_pane(w, right));
    try std.testing.expect(win.window_pane_find_right(left).? == right);
    try std.testing.expect(win.window_pane_find_left(right).? == left);
    try std.testing.expectEqual(@as(usize, 0), win.window_pane_index(w, left).?);
    try std.testing.expectEqual(@as(usize, 1), win.window_pane_index(w, right).?);
    try std.testing.expect(win.window_pane_at_index(w, 1).? == right);
}
