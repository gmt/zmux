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

//! format-test.zig - test cases for format expansion.

const std = @import("std");
const T = @import("types.zig");
const c = @import("c.zig");
const cmd_render = @import("cmd-render.zig");
const cmdq = @import("cmd-queue.zig");
const colour = @import("colour.zig");
const grid = @import("grid.zig");
const opts = @import("options.zig");
const screen_mod = @import("screen.zig");
const sess = @import("session.zig");
const xm = @import("xmalloc.zig");
const client_registry = @import("client-registry.zig");
const window_mod = @import("window.zig");
const window_copy = @import("window-copy.zig");
const hyperlinks_mod = @import("hyperlinks.zig");
const hyperlinks = hyperlinks_mod;
const utf8 = @import("utf8.zig");
const marked_pane_mod = @import("marked-pane.zig");
const tty_features = @import("tty-features.zig");

const fmt = @import("format.zig");
const fmt_resolve = @import("format-resolve.zig");
const grid_storage_usage = fmt_resolve.grid_storage_usage;

const FormatContext = fmt.FormatContext;
const FormatExpandResult = fmt.FormatExpandResult;
const format_expand = fmt.format_expand;
const format_require_complete = fmt.format_require_complete;
const format_require = fmt.format_require;
const format_truthy = fmt.format_truthy;
const format_timestamp_local = fmt.format_timestamp_local;
const format_pretty_time_at = fmt.format_pretty_time_at;

fn write_format_test_line(gd: *T.Grid, row: u32, text: []const u8) void {
    for (text, 0..) |ch, col| {
        grid.set_ascii(gd, row, @intCast(col), ch);
    }
}

test "format_expand resolves mouse pane keys from queued item state" {
    const env_mod = @import("environ.zig");

    sess.session_init_globals(xm.allocator);
    window_mod.window_init_globals(xm.allocator);

    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);

    const s = sess.session_create(null, "format-mouse-pane", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer sess.session_destroy(s, false, "test");

    const w = window_mod.window_create(20, 6, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    var cause: ?[]u8 = null;
    const wl = sess.session_attach(s, w, 0, &cause).?;
    s.curw = wl;
    const wp = window_mod.window_add_pane(w, null, 20, 6);
    w.active = wp;
    wp.base.mode |= T.MODE_MOUSE_ALL | T.MODE_MOUSE_SGR | T.MODE_MOUSE_UTF8;

    var client = T.Client{
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{},
        .session = s,
    };
    defer env_mod.environ_free(client.environ);
    client.tty = .{
        .client = &client,
        .sx = 20,
        .sy = 6,
        .flags = T.TTY_STARTED,
    };

    var event = T.key_event{ .key = T.KEYC_MOUSE, .len = 1 };
    event.m = .{
        .valid = true,
        .key = T.KEYC_MOUSE,
        .x = 3,
        .y = 1,
        .s = @intCast(s.id),
        .w = @intCast(w.id),
        .wp = @intCast(wp.id),
    };

    const state = cmdq.cmdq_new_state(null, &event, 0);
    defer cmdq.cmdq_free_state(state);
    var item = cmdq.CmdqItem{ .state = state };

    const ctx = FormatContext{
        .item = @ptrCast(&item),
        .client = &client,
        .session = s,
        .winlink = wl,
        .window = w,
        .pane = wp,
    };

    const expanded = format_require_complete(
        xm.allocator,
        "#{mouse_pane} #{mouse_x} #{mouse_y} #{mouse_all_flag} #{mouse_any_flag} #{mouse_button_flag} #{mouse_sgr_flag} #{mouse_standard_flag} #{mouse_utf8_flag}",
        &ctx,
    ).?;
    defer xm.allocator.free(expanded);

    const expected = try std.fmt.allocPrint(
        xm.allocator,
        "%{d} 3 1 1 1 0 1 0 1",
        .{wp.id},
    );
    defer xm.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, expanded);
}

test "format_expand resolves mouse status range from explicit mouse context" {
    var client = T.Client{
        .environ = undefined,
        .tty = undefined,
        .status = .{},
    };
    client.tty = .{
        .client = &client,
        .flags = T.TTY_STARTED,
    };
    defer client.status.entries[0].ranges.deinit(xm.allocator);

    var user_string = std.mem.zeroes([16]u8);
    @memcpy(user_string[0..4], "menu");
    client.status.entries[0].ranges.append(xm.allocator, .{
        .type = .user,
        .string = user_string,
        .start = 0,
        .end = 4,
    }) catch unreachable;

    var mouse = T.MouseEvent{
        .valid = true,
        .statusat = 0,
        .statuslines = 1,
        .x = 1,
        .y = 0,
    };

    const ctx = FormatContext{
        .client = &client,
        .mouse_event = &mouse,
    };

    const expanded = format_require_complete(
        xm.allocator,
        "#{mouse_status_line}:#{mouse_status_range}:#{mouse_x}:#{mouse_y}",
        &ctx,
    ).?;
    defer xm.allocator.free(expanded);
    try std.testing.expectEqualStrings("0:menu:1:0", expanded);
}

test "format_expand resolves mouse word line and hyperlink in copy mode" {
    const args_mod = @import("arguments.zig");
    const env_mod = @import("environ.zig");

    sess.session_init_globals(xm.allocator);
    window_mod.window_init_globals(xm.allocator);

    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);

    const s = sess.session_create(null, "format-mouse-copy", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer sess.session_destroy(s, false, "test");

    const w = window_mod.window_create(12, 3, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    var cause: ?[]u8 = null;
    const wl = sess.session_attach(s, w, 0, &cause).?;
    s.curw = wl;
    const wp = window_mod.window_add_pane(w, null, 12, 3);
    w.active = wp;

    var cell = T.grid_default_cell;
    inline for ("alpha beta", 0..) |ch, idx| {
        utf8.utf8_set(&cell.data, ch);
        grid.set_cell(wp.base.grid, 0, @intCast(idx), &cell);
    }

    var link_cell = T.grid_default_cell;
    utf8.utf8_set(&link_cell.data, 'L');
    link_cell.link = hyperlinks.hyperlinks_put(wp.base.hyperlinks.?, "https://example.com/docs", "copy");
    grid.set_cell(wp.base.grid, 1, 0, &link_cell);

    var args = args_mod.Arguments.init(xm.allocator);
    defer args.deinit();
    _ = window_copy.enterMode(wp, wp, &args);

    var word_mouse = T.MouseEvent{
        .valid = true,
        .x = 1,
        .y = 0,
        .s = @intCast(s.id),
        .w = @intCast(w.id),
        .wp = @intCast(wp.id),
    };
    var link_mouse = T.MouseEvent{
        .valid = true,
        .x = 0,
        .y = 1,
        .s = @intCast(s.id),
        .w = @intCast(w.id),
        .wp = @intCast(wp.id),
    };

    const word_ctx = FormatContext{
        .session = s,
        .winlink = wl,
        .window = w,
        .pane = wp,
        .mouse_event = &word_mouse,
    };
    const word_line = format_require_complete(xm.allocator, "#{mouse_word}|#{mouse_line}", &word_ctx).?;
    defer xm.allocator.free(word_line);
    try std.testing.expectEqualStrings("alpha|alpha beta", word_line);

    const link_ctx = FormatContext{
        .session = s,
        .winlink = wl,
        .window = w,
        .pane = wp,
        .mouse_event = &link_mouse,
    };
    const hyperlink = format_require_complete(xm.allocator, "#{mouse_hyperlink}", &link_ctx).?;
    defer xm.allocator.free(hyperlink);
    try std.testing.expectEqualStrings("https://example.com/docs", hyperlink);
}

test "format_expand resolves pane mode and marked flags" {
    const args_mod = @import("arguments.zig");
    const env_mod = @import("environ.zig");

    sess.session_init_globals(xm.allocator);
    window_mod.window_init_globals(xm.allocator);

    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);

    const s = sess.session_create(null, "format-pane-mode", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer sess.session_destroy(s, false, "test");

    const w = window_mod.window_create(20, 6, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    var cause: ?[]u8 = null;
    const wl = sess.session_attach(s, w, 0, &cause).?;
    s.curw = wl;
    const wp = window_mod.window_add_pane(w, null, 20, 6);
    w.active = wp;

    marked_pane_mod.set(s, wl, wp);
    defer marked_pane_mod.clear();

    var args = args_mod.Arguments.init(xm.allocator);
    defer args.deinit();
    _ = window_copy.enterMode(wp, wp, &args);

    const ctx = FormatContext{
        .session = s,
        .winlink = wl,
        .window = w,
        .pane = wp,
    };

    const expanded = format_require_complete(
        xm.allocator,
        "#{pane_in_mode}:#{pane_mode}:#{pane_marked}:#{pane_marked_set}",
        &ctx,
    ).?;
    defer xm.allocator.free(expanded);
    try std.testing.expectEqualStrings("1:copy-mode:1:1", expanded);
}

test "format_expand resolves pane runtime keys" {
    const env_mod = @import("environ.zig");

    client_registry.clients.clearRetainingCapacity();
    defer client_registry.clients.clearRetainingCapacity();

    sess.session_init_globals(xm.allocator);
    window_mod.window_init_globals(xm.allocator);

    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);

    const s = sess.session_create(null, "format-pane-runtime", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer sess.session_destroy(s, false, "test");

    const w = window_mod.window_create(20, 7, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    var cause: ?[]u8 = null;
    const wl = sess.session_attach(s, w, 0, &cause).?;
    s.curw = wl;

    const left = window_mod.window_add_pane(w, null, 10, 6);
    const right = window_mod.window_add_pane(w, null, 9, 6);
    left.xoff = 0;
    left.yoff = 1;
    left.sx = 10;
    left.sy = 6;
    right.xoff = 11;
    right.yoff = 1;
    right.sx = 9;
    right.sy = 6;

    w.active = left;
    try std.testing.expect(window_mod.window_set_active_pane(w, right, false));

    opts.options_set_number(w.options, "pane-border-status", T.PANE_STATUS_TOP);
    opts.options_set_number(left.options, "synchronize-panes", 1);
    left.flags |= T.PANE_INPUTOFF | T.PANE_UNSEENCHANGES;
    left.searchstr = xm.xstrdup("needle");

    screen_mod.screen_set_path(&left.base, "/tracked/base");
    screen_mod.screen_enter_alternate(left, true);
    screen_mod.screen_set_path(left.screen, "/tracked/current");
    screen_mod.screen_set_tab(&left.base, 3);
    screen_mod.screen_current(left).mode |= T.MODE_KEYS_EXTENDED_2;

    var client = T.Client{
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{},
        .flags = T.CLIENT_ATTACHED,
        .session = s,
    };
    defer env_mod.environ_free(client.environ);
    client.tty = .{
        .client = &client,
        .fg = 91,
        .bg = 96,
    };
    client_registry.add(&client);

    const ctx = FormatContext{
        .session = s,
        .winlink = wl,
        .window = w,
        .pane = left,
    };

    const expanded = format_require_complete(
        xm.allocator,
        "#{pane_at_top}:#{pane_at_bottom}:#{pane_at_left}:#{pane_at_right}:#{pane_bottom}:#{pane_top}:#{pane_left}:#{pane_right}:#{pane_current_path}:#{pane_path}:#{pane_fg}:#{pane_bg}:#{pane_input_off}:#{pane_key_mode}:#{pane_last}:#{pane_search_string}:#{pane_synchronized}:#{pane_tabs}:#{pane_unseen_changes}",
        &ctx,
    ).?;
    defer xm.allocator.free(expanded);

    try std.testing.expectEqualStrings(
        "1:1:1:0:6:1:0:9:/tracked/current:/tracked/base:brightred:brightcyan:1:Ext 2:1:needle:1:3,8:1",
        expanded,
    );
}

test "format_expand resolves cursor history and screen mode keys" {
    const env_mod = @import("environ.zig");

    sess.session_init_globals(xm.allocator);
    window_mod.window_init_globals(xm.allocator);

    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);

    const s = sess.session_create(null, "format-screen-keys", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer sess.session_destroy(s, false, "test");

    const w = window_mod.window_create(8, 3, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    var cause: ?[]u8 = null;
    const wl = sess.session_attach(s, w, 0, &cause).?;
    s.curw = wl;
    const wp = window_mod.window_add_pane(w, null, 8, 3);
    w.active = wp;

    wp.base.cx = 1;
    wp.base.cy = 0;
    wp.base.mode |= T.MODE_CURSOR | T.MODE_INSERT | T.MODE_KCURSOR | T.MODE_KKEYPAD | T.MODE_ORIGIN | T.MODE_SYNC;
    wp.base.grid.hsize = 5;
    wp.base.grid.hlimit = 120;
    var cursor_cell = T.grid_default_cell;
    utf8.utf8_set(&cursor_cell.data, 'Z');
    grid.set_cell(wp.base.grid, 0, 1, &cursor_cell);
    grid.ensure_line_capacity(wp.base.grid, 1);
    var extd = T.grid_default_cell;
    extd.data.size = 2;
    extd.data.width = 2;
    extd.data.have = 2;
    extd.data.data[0] = 0xc3;
    extd.data.data[1] = 0xa9;
    grid.set_cell(wp.base.grid, 1, 0, &extd);

    wp.base.cstyle = .underline;
    wp.base.default_cstyle = .bar;
    wp.base.ccolour = 90;
    wp.base.default_ccolour = 91;
    wp.base.mode |= T.MODE_CURSOR_BLINKING | T.MODE_CURSOR_VERY_VISIBLE;

    const usage = grid_storage_usage(wp.base.grid);
    const expected = try std.fmt.allocPrint(
        xm.allocator,
        "1:Z:brightblack:underline:1:1:1:5:{d}:{d},{d},{d},{d},{d},{d}:1:1:1:1:1",
        .{ usage.totalBytes(), usage.lines, usage.line_bytes, usage.cells, usage.cell_bytes, usage.extended_cells, usage.extended_bytes },
    );
    defer xm.allocator.free(expected);

    const ctx = FormatContext{
        .session = s,
        .winlink = wl,
        .window = w,
        .pane = wp,
    };

    const expanded = format_require_complete(
        xm.allocator,
        "#{cursor_flag}:#{cursor_character}:#{cursor_colour}:#{cursor_shape}:#{cursor_very_visible}:#{cursor_blinking}:#{cursor_x}:#{history_size}:#{history_bytes}:#{history_all_bytes}:#{insert_flag}:#{keypad_cursor_flag}:#{keypad_flag}:#{origin_flag}:#{synchronized_output_flag}",
        &ctx,
    ).?;
    defer xm.allocator.free(expanded);
    try std.testing.expectEqualStrings(expected, expanded);
}

test "format_expand prefers the active alternate screen for pane screen keys" {
    const env_mod = @import("environ.zig");

    sess.session_init_globals(xm.allocator);
    window_mod.window_init_globals(xm.allocator);

    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);

    const s = sess.session_create(null, "format-alt-screen-keys", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer sess.session_destroy(s, false, "test");

    const w = window_mod.window_create(8, 3, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    var cause: ?[]u8 = null;
    const wl = sess.session_attach(s, w, 0, &cause).?;
    s.curw = wl;
    const wp = window_mod.window_add_pane(w, null, 8, 3);
    w.active = wp;

    wp.base.cx = 0;
    wp.base.cy = 0;
    wp.base.mode |= T.MODE_CURSOR;
    var base_cell = T.grid_default_cell;
    utf8.utf8_set(&base_cell.data, 'B');
    grid.set_cell(wp.base.grid, 0, 0, &base_cell);

    screen_mod.screen_enter_alternate(wp, true);
    wp.screen.cx = 2;
    wp.screen.cy = 1;
    wp.screen.mode |= T.MODE_CURSOR | T.MODE_INSERT | T.MODE_ORIGIN;
    wp.screen.mode &= ~@as(i32, T.MODE_KCURSOR | T.MODE_KKEYPAD | T.MODE_SYNC);
    wp.screen.cstyle = .bar;
    wp.screen.default_ccolour = 96;
    wp.screen.ccolour = -1;
    wp.screen.grid.hsize = 9;
    wp.screen.grid.hlimit = 240;
    var alt_cell = T.grid_default_cell;
    utf8.utf8_set(&alt_cell.data, 'A');
    grid.set_cell(wp.screen.grid, 1, 2, &alt_cell);

    const usage = grid_storage_usage(wp.screen.grid);
    const expected = try std.fmt.allocPrint(
        xm.allocator,
        "A:2:1:9:240:{d}:bar:brightcyan:1:0:0:1:0:{d},{d},{d},{d},{d},{d}",
        .{ usage.totalBytes(), usage.lines, usage.line_bytes, usage.cells, usage.cell_bytes, usage.extended_cells, usage.extended_bytes },
    );
    defer xm.allocator.free(expected);

    const ctx = FormatContext{
        .session = s,
        .winlink = wl,
        .window = w,
        .pane = wp,
    };

    const expanded = format_require_complete(
        xm.allocator,
        "#{cursor_character}:#{cursor_x}:#{cursor_y}:#{history_size}:#{history_limit}:#{history_bytes}:#{cursor_shape}:#{cursor_colour}:#{insert_flag}:#{keypad_cursor_flag}:#{keypad_flag}:#{origin_flag}:#{synchronized_output_flag}:#{history_all_bytes}",
        &ctx,
    ).?;
    defer xm.allocator.free(expanded);
    try std.testing.expectEqualStrings(expected, expanded);
}

test "format_expand resolves pane dead status signal and time keys" {
    const env_mod = @import("environ.zig");

    sess.session_init_globals(xm.allocator);
    window_mod.window_init_globals(xm.allocator);

    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);

    const s = sess.session_create(null, "format-pane-dead", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer sess.session_destroy(s, false, "test");

    const w = window_mod.window_create(10, 3, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    var cause: ?[]u8 = null;
    const wl = sess.session_attach(s, w, 0, &cause).?;
    s.curw = wl;
    const wp = window_mod.window_add_pane(w, null, 10, 3);
    w.active = wp;

    wp.flags |= T.PANE_EXITED | T.PANE_STATUSREADY;
    wp.status = 7 << 8;
    wp.dead_time = 1234567890;

    const ctx = FormatContext{
        .session = s,
        .winlink = wl,
        .window = w,
        .pane = wp,
    };

    const exited = format_require_complete(xm.allocator, "#{pane_dead_status}:#{pane_dead_signal}:#{t:pane_dead_time}", &ctx).?;
    defer xm.allocator.free(exited);
    const expected_time = format_timestamp_local(xm.allocator, "1234567890", "%Y-%m-%d %H:%M:%S").?;
    defer xm.allocator.free(expected_time);
    const expected_exit = try std.fmt.allocPrint(xm.allocator, "7::{s}", .{expected_time});
    defer xm.allocator.free(expected_exit);
    try std.testing.expectEqualStrings(expected_exit, exited);

    wp.status = @intCast(std.posix.SIG.TERM);
    const signaled = format_require_complete(xm.allocator, "#{pane_dead_status}:#{pane_dead_signal}", &ctx).?;
    defer xm.allocator.free(signaled);
    try std.testing.expectEqualStrings(":15", signaled);
}

test "format_expand resolves direct keys and aliases" {
    var s = T.Session{
        .id = 7,
        .name = xm.xstrdup("alpha"),
        .cwd = "",
        .created = 1234567890,
        .windows = std.AutoHashMap(i32, *T.Winlink).init(xm.allocator),
        .options = undefined,
        .environ = undefined,
    };
    defer {
        s.windows.deinit();
        xm.allocator.free(s.name);
    }

    var w = T.Window{
        .id = 4,
        .name = xm.xstrdup("main"),
        .sx = 80,
        .sy = 24,
        .options = undefined,
    };
    defer {
        w.panes.deinit(xm.allocator);
        w.last_panes.deinit(xm.allocator);
        w.winlinks.deinit(xm.allocator);
        xm.allocator.free(w.name);
    }

    const wl = xm.allocator.create(T.Winlink) catch unreachable;
    defer xm.allocator.destroy(wl);
    wl.* = .{ .idx = 2, .session = &s, .window = &w };
    s.curw = wl;

    var gd = T.Grid{
        .sx = 80,
        .sy = 24,
        .linedata = &.{},
    };
    var screen = T.Screen{ .grid = &gd };
    var wp = T.WindowPane{
        .id = 9,
        .window = &w,
        .options = undefined,
        .sx = 80,
        .sy = 24,
        .screen = &screen,
        .base = screen,
    };
    w.active = &wp;
    w.panes.append(xm.allocator, &wp) catch unreachable;

    const ctx = FormatContext{
        .session = &s,
        .winlink = wl,
        .window = &w,
        .pane = &wp,
        .message_text = "hello",
    };
    const out = format_expand(xm.allocator, "#S:#I.#P @ #{window_name} #{message_text}", &ctx);
    defer xm.allocator.free(out.text);
    try std.testing.expect(out.complete);
    try std.testing.expectEqualStrings("alpha:2.0 @ main hello", out.text);
}

test "format_expand handles conditionals and comparisons" {
    var s = T.Session{
        .id = 1,
        .name = xm.xstrdup("beta"),
        .cwd = "",
        .created = 1,
        .windows = std.AutoHashMap(i32, *T.Winlink).init(xm.allocator),
        .options = undefined,
        .environ = undefined,
        .attached = 1,
    };
    defer {
        s.windows.deinit();
        xm.allocator.free(s.name);
    }

    const ctx = FormatContext{ .session = &s };
    const out = format_expand(
        xm.allocator,
        "#{?session_attached,attached,detached} #{==:session_name,beta} #{!=:session_name,alpha} #{&&:session_attached,1} #{||:0,session_attached}",
        &ctx,
    );
    defer xm.allocator.free(out.text);
    try std.testing.expect(out.complete);
    try std.testing.expectEqualStrings("attached 1 1 1 1", out.text);
}

test "format_expand handles upstream escape and literal round-trips" {
    const ctx = FormatContext{};

    const plain_cases = [_]struct {
        template: []const u8,
        expected: []const u8,
    }{
        .{ .template = "##", .expected = "#" },
        .{ .template = "#,", .expected = "," },
        .{ .template = "##{", .expected = "#{" },
        .{ .template = "#}", .expected = "}" },
        .{ .template = "###}", .expected = "#}" },
    };
    inline for (plain_cases) |case| {
        const expanded = format_require_complete(xm.allocator, case.template, &ctx).?;
        defer xm.allocator.free(expanded);
        try std.testing.expectEqualStrings(case.expected, expanded);
    }

    const literal_cases = [_]struct {
        template: []const u8,
        expected: []const u8,
    }{
        .{ .template = "#{l:#{}}", .expected = "#{}" },
        .{ .template = "#{l:#{pane_in_mode}}", .expected = "#{pane_in_mode}" },
        .{ .template = "#{l:##{}", .expected = "#{" },
        .{ .template = "#{l:#{#}}}", .expected = "#{#}}" },
    };
    inline for (literal_cases) |case| {
        const expanded = format_require_complete(xm.allocator, case.template, &ctx).?;
        defer xm.allocator.free(expanded);
        try std.testing.expectEqualStrings(case.expected, expanded);
    }
}

test "format_expand handles upstream conditional escape branches" {
    const args_mod = @import("arguments.zig");
    const env_mod = @import("environ.zig");

    sess.session_init_globals(xm.allocator);
    window_mod.window_init_globals(xm.allocator);

    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);

    const s = sess.session_create(null, "Summer", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer sess.session_destroy(s, false, "test");

    const w = window_mod.window_create(20, 6, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    var cause: ?[]u8 = null;
    const wl = sess.session_attach(s, w, 0, &cause).?;
    s.curw = wl;
    const wp = window_mod.window_add_pane(w, null, 20, 6);
    w.active = wp;

    const false_ctx = FormatContext{
        .session = s,
        .winlink = wl,
        .window = w,
        .pane = wp,
    };
    const false_cases = [_]struct {
        template: []const u8,
        expected: []const u8,
    }{
        .{ .template = "#{?pane_in_mode,##{,xyz}", .expected = "xyz" },
        .{ .template = "#{?pane_in_mode,###},xyz}", .expected = "xyz" },
        .{ .template = "#{?pane_in_mode,abc,##{}", .expected = "#{" },
        .{ .template = "#{?pane_in_mode,abc,###}}", .expected = "#}" },
        .{ .template = "#{?pane_in_mode,##{,###}}", .expected = "#}" },
    };
    inline for (false_cases) |case| {
        const expanded = format_require_complete(xm.allocator, case.template, &false_ctx).?;
        defer xm.allocator.free(expanded);
        try std.testing.expectEqualStrings(case.expected, expanded);
    }

    var args = args_mod.Arguments.init(xm.allocator);
    defer args.deinit();
    _ = window_copy.enterMode(wp, wp, &args);

    const true_ctx = FormatContext{
        .session = s,
        .winlink = wl,
        .window = w,
        .pane = wp,
    };
    const true_cases = [_]struct {
        template: []const u8,
        expected: []const u8,
    }{
        .{ .template = "#{?pane_in_mode,##{,xyz}", .expected = "#{" },
        .{ .template = "#{?pane_in_mode,###},xyz}", .expected = "#}" },
        .{ .template = "#{?pane_in_mode,abc,##{}", .expected = "abc" },
        .{ .template = "#{?pane_in_mode,abc,###}}", .expected = "abc" },
        .{ .template = "#{?pane_in_mode,##{,###}}", .expected = "#{" },
    };
    inline for (true_cases) |case| {
        const expanded = format_require_complete(xm.allocator, case.template, &true_ctx).?;
        defer xm.allocator.free(expanded);
        try std.testing.expectEqualStrings(case.expected, expanded);
    }

    xm.allocator.free(s.name);
    s.name = xm.xstrdup(",");

    const comparison = format_require_complete(
        xm.allocator,
        "#{?#{==:#,,#{session_name}},abc,xyz}",
        &true_ctx,
    ).?;
    defer xm.allocator.free(comparison);
    try std.testing.expectEqualStrings("abc", comparison);
}

test "format_expand renders tmux-style session_alerts per window index" {
    var s = T.Session{
        .id = 12,
        .name = xm.xstrdup("alerts"),
        .cwd = "",
        .created = 1,
        .windows = std.AutoHashMap(i32, *T.Winlink).init(xm.allocator),
        .options = undefined,
        .environ = undefined,
    };
    defer {
        var it = s.windows.valueIterator();
        while (it.next()) |wl| xm.allocator.destroy(wl.*);
        s.windows.deinit();
        xm.allocator.free(s.name);
    }

    var w1 = T.Window{ .id = 1, .name = xm.xstrdup("one"), .sx = 80, .sy = 24, .options = undefined };
    var w2 = T.Window{ .id = 2, .name = xm.xstrdup("two"), .sx = 80, .sy = 24, .options = undefined };
    var w3 = T.Window{ .id = 3, .name = xm.xstrdup("three"), .sx = 80, .sy = 24, .options = undefined };
    defer {
        w1.panes.deinit(xm.allocator);
        w1.last_panes.deinit(xm.allocator);
        w1.winlinks.deinit(xm.allocator);
        xm.allocator.free(w1.name);
        w2.panes.deinit(xm.allocator);
        w2.last_panes.deinit(xm.allocator);
        w2.winlinks.deinit(xm.allocator);
        xm.allocator.free(w2.name);
        w3.panes.deinit(xm.allocator);
        w3.last_panes.deinit(xm.allocator);
        w3.winlinks.deinit(xm.allocator);
        xm.allocator.free(w3.name);
    }

    const wl3 = xm.allocator.create(T.Winlink) catch unreachable;
    const wl1 = xm.allocator.create(T.Winlink) catch unreachable;
    const wl2 = xm.allocator.create(T.Winlink) catch unreachable;
    wl3.* = .{ .idx = 3, .session = &s, .window = &w3, .flags = T.WINLINK_BELL };
    wl1.* = .{ .idx = 1, .session = &s, .window = &w1, .flags = T.WINLINK_ACTIVITY };
    wl2.* = .{ .idx = 2, .session = &s, .window = &w2, .flags = T.WINLINK_BELL | T.WINLINK_SILENCE };
    s.windows.put(wl3.idx, wl3) catch unreachable;
    s.windows.put(wl1.idx, wl1) catch unreachable;
    s.windows.put(wl2.idx, wl2) catch unreachable;

    const ctx = FormatContext{ .session = &s };
    const out = format_expand(xm.allocator, "#{session_alerts}", &ctx);
    defer xm.allocator.free(out.text);
    try std.testing.expect(out.complete);
    try std.testing.expectEqualStrings("1#,2!~,3!", out.text);
}

test "format_expand handles time modifier and incomplete formats" {
    var s = T.Session{
        .id = 1,
        .name = xm.xstrdup("gamma"),
        .cwd = "",
        .created = 0,
        .windows = std.AutoHashMap(i32, *T.Winlink).init(xm.allocator),
        .options = undefined,
        .environ = undefined,
    };
    defer {
        s.windows.deinit();
        xm.allocator.free(s.name);
    }

    const ctx = FormatContext{ .session = &s };
    const timed = format_expand(xm.allocator, "#{t:session_created}", &ctx);
    defer xm.allocator.free(timed.text);
    try std.testing.expect(timed.complete);
    const expected = format_timestamp_local(xm.allocator, "0", "%Y-%m-%d %H:%M:%S").?;
    defer xm.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, timed.text);

    const unresolved = format_expand(xm.allocator, "#{definitely_missing}", &ctx);
    defer xm.allocator.free(unresolved.text);
    try std.testing.expect(!unresolved.complete);
    try std.testing.expectEqualStrings("#{definitely_missing}", unresolved.text);
    try std.testing.expect(format_require_complete(xm.allocator, "#{definitely_missing}", &ctx) == null);
}

test "format_expand handles pretty message time and explicit message fields" {
    const ctx = FormatContext{
        .message_text = "runtime",
        .message_number = 7,
        .message_time = 0,
    };

    const out = format_expand(xm.allocator, "#{t/p:message_time}:#{message_number}:#{message_text}", &ctx);
    defer xm.allocator.free(out.text);
    try std.testing.expect(out.complete);
    const expected_time = format_pretty_time_at(xm.allocator, std.time.timestamp(), 0, false).?;
    defer xm.allocator.free(expected_time);
    const expected = try std.fmt.allocPrint(xm.allocator, "{s}:7:runtime", .{expected_time});
    defer xm.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, out.text);
}

test "format_expand handles width, pad, repeat, and comparisons" {
    var screen = T.Screen{
        .grid = undefined,
        .title = xm.xstrdup("abcdef"),
    };
    defer xm.allocator.free(screen.title.?);

    var w = T.Window{
        .id = 1,
        .name = xm.xstrdup("main"),
        .sx = 80,
        .sy = 24,
        .options = undefined,
    };
    defer {
        w.panes.deinit(xm.allocator);
        w.last_panes.deinit(xm.allocator);
        w.winlinks.deinit(xm.allocator);
        xm.allocator.free(w.name);
    }

    var wp = T.WindowPane{
        .id = 1,
        .window = &w,
        .options = undefined,
        .sx = 80,
        .sy = 24,
        .cwd = xm.xstrdup("/tmp/demo"),
        .screen = &screen,
        .base = screen,
    };
    defer xm.allocator.free(wp.cwd.?);
    w.active = &wp;
    w.panes.append(xm.allocator, &wp) catch unreachable;

    const ctx = FormatContext{ .window = &w, .pane = &wp, .message_text = "a b" };

    const rendered = format_expand(
        xm.allocator,
        "#{=4:pane_title}|#{p6:pane_title}|#{b:pane_path}|#{d:pane_path}|#{q:message_text}|#{R:xy,3}|#{<:aaa,bbb}|#{>=:bbb,bbb}",
        &ctx,
    );
    defer xm.allocator.free(rendered.text);
    try std.testing.expect(rendered.complete);
    try std.testing.expectEqualStrings("abcd|abcdef|demo|/tmp|a\\ b|xyxyxy|1|1", rendered.text);
}

test "format_expand handles pane search modifiers" {
    const base_grid = grid.grid_create(24, 3, 0);
    defer grid.grid_free(base_grid);

    const alt_screen = screen_mod.screen_init(24, 3, 0);
    defer {
        screen_mod.screen_free(alt_screen);
        xm.allocator.destroy(alt_screen);
    }

    var base = T.Screen{
        .grid = base_grid,
        .mode = T.MODE_CURSOR | T.MODE_WRAP,
        .rlower = 2,
    };
    screen_mod.screen_reset_tabs(&base);
    screen_mod.screen_reset_hyperlinks(&base);
    defer {
        if (base.tabs) |tabs| xm.allocator.free(tabs);
        if (base.hyperlinks) |hl| hyperlinks.hyperlinks_free(hl);
    }

    var w = T.Window{
        .id = 7,
        .name = xm.xstrdup("search"),
        .sx = 24,
        .sy = 3,
        .options = undefined,
    };
    defer {
        w.panes.deinit(xm.allocator);
        w.last_panes.deinit(xm.allocator);
        w.winlinks.deinit(xm.allocator);
        xm.allocator.free(w.name);
    }

    var wp = T.WindowPane{
        .id = 9,
        .window = &w,
        .options = undefined,
        .sx = 24,
        .sy = 3,
        .screen = alt_screen,
        .base = base,
    };
    w.active = &wp;
    w.panes.append(xm.allocator, &wp) catch unreachable;

    write_format_test_line(wp.base.grid, 0, "zero");
    write_format_test_line(wp.base.grid, 1, "Alpha Beta   ");
    write_format_test_line(wp.base.grid, 2, "Gamma");

    const ctx = FormatContext{ .window = &w, .pane = &wp };
    const out = format_expand(
        xm.allocator,
        "#{C:Beta} #{C/i:beta} #{C/r:^alpha beta$} #{C/ri:^alpha beta$}",
        &ctx,
    );
    defer xm.allocator.free(out.text);
    try std.testing.expect(out.complete);
    try std.testing.expectEqualStrings("2 2 0 2", out.text);

    const no_pane = format_expand(xm.allocator, "#{C:Beta}", &FormatContext{});
    defer xm.allocator.free(no_pane.text);
    try std.testing.expect(no_pane.complete);
    try std.testing.expectEqualStrings("0", no_pane.text);
}

test "format_expand handles match and arithmetic modifiers" {
    var s = T.Session{
        .id = 11,
        .name = xm.xstrdup("fmtbox"),
        .cwd = "",
        .created = 1,
        .windows = std.AutoHashMap(i32, *T.Winlink).init(xm.allocator),
        .options = undefined,
        .environ = undefined,
    };
    defer {
        s.windows.deinit();
        xm.allocator.free(s.name);
    }

    const ctx = FormatContext{ .session = &s };
    const out = format_expand(
        xm.allocator,
        "#{m:*fmt*,#{session_name}} #{m/ri:^FMT,fmtbox} #{e|+:1,2} #{e|*|f|4:5.5,3} #{e|%%:7,3}",
        &ctx,
    );
    defer xm.allocator.free(out.text);
    try std.testing.expect(out.complete);
    try std.testing.expectEqualStrings("1 1 3 16.5000 1", out.text);
}

test "format_expand handles substitution modifiers" {
    const ctx = FormatContext{ .message_text = "foobar" };
    const out = format_expand(
        xm.allocator,
        "#{s/foo/bar/:#{message_text}} #{s/a(.)/\\1x/i:#{message_text}} #{s/foo/bar/;=5:#{message_text}}",
        &ctx,
    );
    defer xm.allocator.free(out.text);
    try std.testing.expect(out.complete);
    try std.testing.expectEqualStrings("barbar foobrx barba", out.text);
}

test "format_expand uses tmux runtime fallback for bad arithmetic and substitution regex" {
    const ctx = FormatContext{ .message_text = "keepme" };
    const arithmetic = format_expand(xm.allocator, "x#{e|nope:1,2}y", &ctx);
    defer xm.allocator.free(arithmetic.text);
    try std.testing.expect(arithmetic.complete);
    try std.testing.expectEqualStrings("xy", arithmetic.text);

    const substitution = format_expand(xm.allocator, "#{s/[/x/:#{message_text}}", &ctx);
    defer xm.allocator.free(substitution.text);
    try std.testing.expect(substitution.complete);
    try std.testing.expectEqualStrings("keepme", substitution.text);
}

test "format_expand supports option indirection and loops" {
    const env_mod = @import("environ.zig");
    const win_mod = @import("window.zig");

    sess.session_init_globals(xm.allocator);
    win_mod.window_init_globals(xm.allocator);

    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);

    env_mod.global_environ = env_mod.environ_create();
    defer env_mod.environ_free(env_mod.global_environ);

    const session_opts_a = opts.options_create(opts.global_s_options);
    const session_env_a = env_mod.environ_create();
    const sa = sess.session_create(null, "alpha", "/", session_env_a, session_opts_a, null);
    defer sess.session_destroy(sa, false, "test");

    const session_opts_b = opts.options_create(opts.global_s_options);
    const session_env_b = env_mod.environ_create();
    const sb = sess.session_create(null, "beta", "/", session_env_b, session_opts_b, null);
    defer sess.session_destroy(sb, false, "test");

    opts.options_set_string(sa.options, false, "@clock", "%H:%M");

    const w1 = win_mod.window_create(80, 24, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    xm.allocator.free(w1.name);
    w1.name = xm.xstrdup("one");
    var cause_a: ?[]u8 = null;
    const wl1 = sess.session_attach(sa, w1, 0, &cause_a).?;
    sa.curw = wl1;
    w1.active = win_mod.window_add_pane(w1, null, 80, 24);
    w1.active.?.screen.title = xm.xstrdup("pane-a");

    const w2 = win_mod.window_create(80, 24, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    xm.allocator.free(w2.name);
    w2.name = xm.xstrdup("two");
    var cause_b: ?[]u8 = null;
    _ = sess.session_attach(sa, w2, 1, &cause_b).?;
    w2.active = win_mod.window_add_pane(w2, null, 80, 24);
    w2.active.?.screen.title = xm.xstrdup("pane-b");

    const ctx = FormatContext{
        .session = sa,
        .winlink = wl1,
        .window = w1,
        .pane = w1.active.?,
    };

    const left = format_require_complete(xm.allocator, "#{E:status-left}", &ctx).?;
    defer xm.allocator.free(left);
    try std.testing.expectEqualStrings("[alpha] ", left);

    const clock = format_require_complete(xm.allocator, "#{T:@clock}", &ctx).?;
    defer xm.allocator.free(clock);
    try std.testing.expectEqual(@as(usize, 5), clock.len);
    try std.testing.expect(clock[2] == ':');

    const loop = format_require_complete(xm.allocator, "#{W:#{window_name}#{?loop_last_flag,,|},[#{window_name}]#{?loop_last_flag,,|}}", &ctx).?;
    defer xm.allocator.free(loop);
    try std.testing.expectEqualStrings("[one]|two", loop);

    const sessions_loop = format_require_complete(xm.allocator, "#{S:#{session_name}#{?loop_last_flag,,|},[#{session_name}]#{?loop_last_flag,,|}}", &ctx).?;
    defer xm.allocator.free(sessions_loop);
    try std.testing.expectEqualStrings("[alpha]|beta", sessions_loop);
}

test "format_expand covers key option-table defaults" {
    const env_mod = @import("environ.zig");
    const win_mod = @import("window.zig");

    sess.session_init_globals(xm.allocator);
    win_mod.window_init_globals(xm.allocator);

    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);

    env_mod.global_environ = env_mod.environ_create();
    defer env_mod.environ_free(env_mod.global_environ);

    const session_opts = opts.options_create(opts.global_s_options);
    const session_env = env_mod.environ_create();
    const s = sess.session_create(null, "defaults", "/", session_env, session_opts, null);
    defer sess.session_destroy(s, false, "test");

    const w = win_mod.window_create(80, 24, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    xm.allocator.free(w.name);
    w.name = xm.xstrdup("editor");
    var cause: ?[]u8 = null;
    const wl = sess.session_attach(s, w, 0, &cause).?;
    s.curw = wl;
    const wp = win_mod.window_add_pane(w, null, 80, 24);
    w.active = wp;
    wp.shell = xm.xstrdup("sh");
    wp.screen.title = xm.xstrdup("pane-title");

    const ctx = FormatContext{
        .session = s,
        .winlink = wl,
        .window = w,
        .pane = wp,
    };

    const automatic = format_require_complete(xm.allocator, "#{E:automatic-rename-format}", &ctx).?;
    defer xm.allocator.free(automatic);
    try std.testing.expectEqualStrings("sh", automatic);

    wp.flags |= T.PANE_EXITED | T.PANE_STATUSREADY;
    wp.status = 7 << 8;
    const remain = format_require_complete(xm.allocator, "#{E:remain-on-exit-format}", &ctx).?;
    defer xm.allocator.free(remain);
    try std.testing.expectEqualStrings("Pane is dead (7)", remain);
    wp.flags &= ~(T.PANE_EXITED | T.PANE_STATUSREADY);

    const border = format_require_complete(xm.allocator, "#{E:pane-border-format}", &ctx).?;
    defer xm.allocator.free(border);
    try std.testing.expectEqualStrings("#[reverse]0#[default] \"pane-title\"", border);

    const window_status = format_require_complete(xm.allocator, "#{E:window-status-format}", &ctx).?;
    defer xm.allocator.free(window_status);
    try std.testing.expectEqualStrings("0:editor*", window_status);

    const status_justify = format_require_complete(xm.allocator, "#{status-justify}", &ctx).?;
    defer xm.allocator.free(status_justify);
    try std.testing.expectEqualStrings("left", status_justify);

    const status_left_length = format_require_complete(xm.allocator, "#{status-left-length}", &ctx).?;
    defer xm.allocator.free(status_left_length);
    try std.testing.expectEqualStrings("10", status_left_length);

    const status_format = format_require_complete(xm.allocator, opts.options_get_array_item(s.options, "status-format", 0).?, &ctx).?;
    defer xm.allocator.free(status_format);
    try std.testing.expect(std.mem.indexOf(u8, status_format, "#{") == null);
    try std.testing.expect(std.mem.indexOf(u8, status_format, "[defaults]") != null);

    const status_format_panes = format_require_complete(xm.allocator, opts.options_get_array_item(s.options, "status-format", 1).?, &ctx).?;
    defer xm.allocator.free(status_format_panes);
    try std.testing.expect(std.mem.indexOf(u8, status_format_panes, "#{") == null);
    try std.testing.expect(std.mem.indexOf(u8, status_format_panes, "0[80x24]*") != null);

    const status_format_sessions = format_require_complete(xm.allocator, opts.options_get_array_item(s.options, "status-format", 2).?, &ctx).?;
    defer xm.allocator.free(status_format_sessions);
    try std.testing.expect(std.mem.indexOf(u8, status_format_sessions, "#{") == null);
    try std.testing.expect(std.mem.indexOf(u8, status_format_sessions, "defaults") != null);
    try std.testing.expect(std.mem.indexOf(u8, status_format_sessions, "*") != null);

    const titles = format_require_complete(xm.allocator, "#{T:set-titles-string}", &ctx).?;
    defer xm.allocator.free(titles);
    try std.testing.expect(std.mem.indexOf(u8, titles, "#{") == null);
    try std.testing.expect(std.mem.indexOf(u8, titles, "defaults") != null);

    const status_right = format_require_complete(xm.allocator, "#{T:status-right}", &ctx).?;
    defer xm.allocator.free(status_right);
    try std.testing.expect(std.mem.indexOf(u8, status_right, "#{") == null);
    try std.testing.expect(std.mem.indexOf(u8, status_right, "pane-title") != null);
}

test "format_expand resolves session, window, and global parity extras" {
    const env_mod = @import("environ.zig");
    const win_mod = @import("window.zig");

    sess.session_init_globals(xm.allocator);
    win_mod.window_init_globals(xm.allocator);
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

    env_mod.global_environ = env_mod.environ_create();
    defer env_mod.environ_free(env_mod.global_environ);

    const primary = sess.session_create(null, "primary", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer sess.session_destroy(primary, false, "test");
    const peer = sess.session_create(null, "peer", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer sess.session_destroy(peer, false, "test");

    var cause: ?[]u8 = null;

    const main_window = win_mod.window_create(80, 24, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    xm.allocator.free(main_window.name);
    main_window.name = xm.xstrdup("main");
    const main_wl = sess.session_attach(primary, main_window, 1, &cause).?;
    primary.curw = main_wl;
    main_window.active = win_mod.window_add_pane(main_window, null, 80, 24);
    main_wl.flags = T.WINLINK_ACTIVITY;

    const alert_window = win_mod.window_create(80, 24, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    xm.allocator.free(alert_window.name);
    alert_window.name = xm.xstrdup("alert");
    const alert_wl = sess.session_attach(primary, alert_window, 3, &cause).?;
    alert_window.active = win_mod.window_add_pane(alert_window, null, 80, 24);
    alert_wl.flags = T.WINLINK_BELL | T.WINLINK_SILENCE;

    const peer_window = win_mod.window_create(80, 24, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    xm.allocator.free(peer_window.name);
    peer_window.name = xm.xstrdup("peer");
    const peer_wl = sess.session_attach(peer, peer_window, 2, &cause).?;
    peer.curw = peer_wl;
    peer_window.active = win_mod.window_add_pane(peer_window, null, 80, 24);

    primary.activity_time = 123_456_789_000;
    primary.last_attached_time = 234_567_890_000;
    primary.attached = 2;
    peer.attached = 1;

    const group = sess.session_group_new("shared");
    sess.session_group_add(group, primary);
    sess.session_group_add(group, peer);

    var alpha = T.Client{
        .name = xm.xstrdup("alpha"),
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{},
        .session = primary,
    };
    defer {
        env_mod.environ_free(alpha.environ);
        xm.allocator.free(@constCast(alpha.name.?));
    }
    alpha.tty.client = &alpha;

    var beta = T.Client{
        .name = xm.xstrdup("beta"),
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{},
        .session = primary,
    };
    defer {
        env_mod.environ_free(beta.environ);
        xm.allocator.free(@constCast(beta.name.?));
    }
    beta.tty.client = &beta;

    var gamma = T.Client{
        .name = xm.xstrdup("gamma"),
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{},
        .session = peer,
    };
    defer {
        env_mod.environ_free(gamma.environ);
        xm.allocator.free(@constCast(gamma.name.?));
    }
    gamma.tty.client = &gamma;

    client_registry.add(&alpha);
    client_registry.add(&beta);
    client_registry.add(&gamma);

    const ctx = FormatContext{
        .session = primary,
        .winlink = main_wl,
        .window = main_window,
        .pane = main_window.active.?,
    };

    const expanded = format_require_complete(
        xm.allocator,
        "#{active_window_index} #{last_window_index} #{next_session_id} #{server_sessions} #{session_activity} #{session_alert} #{session_attached} #{session_attached_list} #{session_group_attached} #{session_group_attached_list} #{session_group_many_attached} #{session_group_size} #{session_last_attached}",
        &ctx,
    ).?;
    defer xm.allocator.free(expanded);

    try std.testing.expectEqualStrings("1 3 $2 2 123456789 #!~ 2 alpha,beta 3 alpha,beta,gamma 1 2 234567890", expanded);
}

test "format_expand resolves tmux-style client metadata keys" {
    const env_mod = @import("environ.zig");
    const win_mod = @import("window.zig");

    const dispatch = struct {
        fn call(_imsg: ?*c.imsg.imsg, _arg: ?*anyopaque) callconv(.c) void {
            _ = _imsg;
            _ = _arg;
        }
    }.call;

    const uid: std.posix.uid_t = @intCast(std.os.linux.getuid());
    const pw = c.posix_sys.getpwuid(uid) orelse return error.SkipZigTest;
    const user_name = std.mem.span(@as([*:0]const u8, @ptrCast(pw.*.pw_name)));

    sess.session_init_globals(xm.allocator);
    win_mod.window_init_globals(xm.allocator);

    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);

    env_mod.global_environ = env_mod.environ_create();
    defer env_mod.environ_free(env_mod.global_environ);

    const current = sess.session_create(null, "current", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer sess.session_destroy(current, false, "test");
    const previous = sess.session_create(null, "previous", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer sess.session_destroy(previous, false, "test");

    var proc = T.ZmuxProc{ .name = "format-client-keys-test" };
    var peer = T.ZmuxPeer{
        .parent = &proc,
        .ibuf = undefined,
        .uid = uid,
        .dispatchcb = dispatch,
    };

    var client = T.Client{
        .name = xm.xstrdup("client-42"),
        .peer = &peer,
        .creation_time = 98_765_432_000,
        .activity_time = 123_456_789_000,
        .pid = 4321,
        .environ = env_mod.environ_create(),
        .term_name = xm.xstrdup("xterm-256color"),
        .term_features = tty_features.featureBit(.@"256") | tty_features.featureBit(.clipboard) | tty_features.featureBit(.focus),
        .term_type = xm.xstrdup("screen"),
        .ttyname = xm.xstrdup("/dev/pts/42"),
        .discarded = 42,
        .theme = .dark,
        .tty = .{
            .client = undefined,
            .sx = 90,
            .sy = 30,
            .xpixel = 11,
            .ypixel = 24,
            .flags = @as(i32, @intCast(T.TTY_STARTED)),
        },
        .status = .{},
        .flags = T.CLIENT_ATTACHED |
            T.CLIENT_FOCUSED |
            T.CLIENT_CONTROL |
            T.CLIENT_IGNORESIZE |
            T.CLIENT_NO_DETACH_ON_DESTROY |
            T.CLIENT_CONTROL_NOOUTPUT |
            T.CLIENT_CONTROL_WAITEXIT |
            T.CLIENT_CONTROL_PAUSEAFTER |
            T.CLIENT_READONLY |
            T.CLIENT_ACTIVEPANE |
            T.CLIENT_SUSPENDED |
            T.CLIENT_UTF8,
        .session = current,
        .last_session = previous,
        .pause_age = 3_000,
    };
    defer env_mod.environ_free(client.environ);
    defer xm.allocator.free(@constCast(client.name.?));
    defer xm.allocator.free(client.term_name.?);
    defer xm.allocator.free(client.term_type.?);
    defer xm.allocator.free(client.ttyname.?);
    client.tty.client = &client;

    const ctx = FormatContext{ .client = &client };
    const expanded = format_require_complete(
        xm.allocator,
        "#{client_activity} #{client_cell_height} #{client_cell_width} #{client_created} #{client_discarded} #{client_flags} #{client_last_session} #{client_name} #{client_pid} #{client_session} #{client_termfeatures} #{client_termtype} #{client_theme} #{client_tty} #{client_uid} #{client_user} #{client_width} #{client_height}",
        &ctx,
    ).?;
    defer xm.allocator.free(expanded);

    const expected = std.fmt.allocPrint(
        xm.allocator,
        "123456789 24 11 98765432 42 attached,focused,control-mode,ignore-size,no-detach-on-destroy,no-output,wait-exit,pause-after=3,read-only,active-pane,suspended,UTF-8 previous client-42 4321 current 256,clipboard,focus screen dark /dev/pts/42 {d} {s} 90 30",
        .{ uid, user_name },
    ) catch unreachable;
    defer xm.allocator.free(expected);

    try std.testing.expectEqualStrings(expected, expanded);
}

test "format_expand resolves client_control_mode prefix readonly utf aliases termname and written" {
    const env_mod = @import("environ.zig");

    var session_env = T.Environ.init(xm.allocator);
    defer session_env.deinit();
    var session_options = T.Options.init(xm.allocator, null);
    defer session_options.deinit();

    var session = T.Session{
        .id = 88,
        .name = xm.xstrdup("fmt-client-extra"),
        .cwd = "/",
        .options = &session_options,
        .environ = &session_env,
    };
    defer xm.allocator.free(session.name);

    var client = T.Client{
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{},
        .flags = T.CLIENT_CONTROL | T.CLIENT_READONLY | T.CLIENT_UTF8,
        .session = &session,
        .term_name = xm.xstrdup("ansi"),
        .key_table_name = xm.xstrdup("prefix"),
    };
    defer {
        env_mod.environ_free(client.environ);
        xm.allocator.free(client.term_name.?);
        xm.allocator.free(client.key_table_name.?);
    }
    client.tty = .{ .client = &client };

    const ctx = FormatContext{ .client = &client };
    const expanded = format_require_complete(
        xm.allocator,
        "#{client_control_mode}:#{client_readonly}:#{client_prefix}:#{client_key_table}:#{client_utf8}:#{client_utf}:#{client_session_name}:#{client_termname}:#{client_written}",
        &ctx,
    ).?;
    defer xm.allocator.free(expanded);

    try std.testing.expectEqualStrings("1:1:1:prefix:1:1:fmt-client-extra:ansi:0", expanded);
}

test "format_expand resolves client_mode_format to the tmux choose-client default" {
    const ctx = FormatContext{};
    const expanded = format_require_complete(
        xm.allocator,
        "#{client_mode_format}",
        &ctx,
    ).?;
    defer xm.allocator.free(expanded);

    try std.testing.expectEqualStrings("#{t/p:client_activity}: session #{session_name}", expanded);
}

test "format_expand multi-pair conditional #{?c1,v1,c2,v2,...}" {
    var s = T.Session{
        .id = 1,
        .name = xm.xstrdup("demo"),
        .cwd = "",
        .created = 1,
        .windows = std.AutoHashMap(i32, *T.Winlink).init(xm.allocator),
        .options = undefined,
        .environ = undefined,
        .attached = 1,
    };
    defer {
        s.windows.deinit();
        xm.allocator.free(s.name);
    }

    const ctx = FormatContext{ .session = &s };

    // Classic 3-arg form still works.
    const classic = format_require_complete(
        xm.allocator,
        "#{?session_attached,yes,no}",
        &ctx,
    ).?;
    defer xm.allocator.free(classic);
    try std.testing.expectEqualStrings("yes", classic);

    // 5-arg multi-pair: first condition true, first value returned.
    const multi_first = format_require_complete(
        xm.allocator,
        "#{?session_attached,A,0,B,default}",
        &ctx,
    ).?;
    defer xm.allocator.free(multi_first);
    try std.testing.expectEqualStrings("A", multi_first);

    // 5-arg multi-pair: first false, second true, second value returned.
    const multi_second = format_require_complete(
        xm.allocator,
        "#{?0,A,session_attached,B,default}",
        &ctx,
    ).?;
    defer xm.allocator.free(multi_second);
    try std.testing.expectEqualStrings("B", multi_second);

    // 5-arg multi-pair: both conditions false, trailing default returned.
    const multi_default = format_require_complete(
        xm.allocator,
        "#{?0,A,0,B,fallback}",
        &ctx,
    ).?;
    defer xm.allocator.free(multi_default);
    try std.testing.expectEqualStrings("fallback", multi_default);

    // Even-arg form with no match: empty string returned.
    const multi_empty = format_require_complete(
        xm.allocator,
        "#{?0,A,0,B}",
        &ctx,
    ).?;
    defer xm.allocator.free(multi_empty);
    try std.testing.expectEqualStrings("", multi_empty);
}

test "format_expand window loop neighbor variables" {
    const env_mod = @import("environ.zig");
    const win_mod = @import("window.zig");

    sess.session_init_globals(xm.allocator);
    win_mod.window_init_globals(xm.allocator);

    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);

    env_mod.global_environ = env_mod.environ_create();
    defer env_mod.environ_free(env_mod.global_environ);

    const session_opts = opts.options_create(opts.global_s_options);
    const session_env = env_mod.environ_create();
    const s = sess.session_create(null, "ntest", "/", session_env, session_opts, null);
    defer sess.session_destroy(s, false, "test");

    // Windows at indices 0, 1, 2; make index 1 active.
    const w1 = win_mod.window_create(80, 24, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    xm.allocator.free(w1.name);
    w1.name = xm.xstrdup("win0");
    var ca: ?[]u8 = null;
    _ = sess.session_attach(s, w1, 0, &ca).?;
    w1.active = win_mod.window_add_pane(w1, null, 80, 24);

    const w2 = win_mod.window_create(80, 24, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    xm.allocator.free(w2.name);
    w2.name = xm.xstrdup("win1");
    var cb: ?[]u8 = null;
    const wl_active = sess.session_attach(s, w2, 1, &cb).?;
    w2.active = win_mod.window_add_pane(w2, null, 80, 24);
    s.curw = wl_active;

    const w3 = win_mod.window_create(80, 24, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    xm.allocator.free(w3.name);
    w3.name = xm.xstrdup("win2");
    var cc: ?[]u8 = null;
    _ = sess.session_attach(s, w3, 2, &cc).?;
    w3.active = win_mod.window_add_pane(w3, null, 80, 24);

    const ctx = FormatContext{ .session = s };

    // Sorted windows [0,1,2] with active=index 1:
    //   win0(i=0): after_active=false, before_active=items[1]==curw=true
    //   win1(i=1): after_active=items[0]==curw=false, before_active=items[2]==curw=false
    //   win2(i=2): after_active=items[1]==curw=true, before_active=false (boundary)
    const loop_out = format_require_complete(
        xm.allocator,
        "#{W:#{window_name}:#{window_after_active}:#{window_before_active} }",
        &ctx,
    ).?;
    defer xm.allocator.free(loop_out);
    try std.testing.expectEqualStrings("win0:0:1 win1:0:0 win2:1:0 ", loop_out);

    // next/prev window index: absent at boundaries.
    // Use #{?#{next_window_index},...} so an absent key (incomplete expansion)
    // is treated as false by the multi-pair ? conditional.
    const neighbor_idx = format_require_complete(
        xm.allocator,
        "#{W:#{window_index}:#{?#{next_window_index},#{next_window_index},-}:#{?#{prev_window_index},#{prev_window_index},-} }",
        &ctx,
    ).?;
    defer xm.allocator.free(neighbor_idx);
    // win0(idx=0): next_window_index="1" (truthy), no prev_window_index → next=1, prev=-
    // win1(idx=1): next_window_index="2" (truthy), prev_window_index="0" (falsy) → next=2, prev=-
    // win2(idx=2): no next_window_index, prev_window_index="1" (truthy) → next=-, prev=1
    // Note: prev_window_index="0" is falsy per format_truthy, so win1 prev shows "-"
    try std.testing.expectEqualStrings("0:1:- 1:2:- 2:-:1 ", neighbor_idx);
}

test "format_truthy normalizes common false spellings" {
    try std.testing.expect(!format_truthy(""));
    try std.testing.expect(!format_truthy("0"));
    try std.testing.expect(!format_truthy("false"));
    try std.testing.expect(!format_truthy("OFF"));
    try std.testing.expect(!format_truthy("No"));
    try std.testing.expect(format_truthy("yes"));
    try std.testing.expect(format_truthy("1"));
}

test "format_timestamp_local rejects non-numeric seconds" {
    try std.testing.expect(format_timestamp_local(xm.allocator, "not-a-timestamp", "%Y") == null);
}

test "format_expand handles name checks and pane loops with active template" {
    const env_mod = @import("environ.zig");

    sess.session_init_globals(xm.allocator);
    window_mod.window_init_globals(xm.allocator);

    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);

    const alpha = sess.session_create(null, "alpha", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer sess.session_destroy(alpha, false, "test");
    const beta = sess.session_create(null, "beta", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer sess.session_destroy(beta, false, "test");

    const w = window_mod.window_create(20, 6, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    xm.allocator.free(w.name);
    w.name = xm.xstrdup("editor");
    var cause: ?[]u8 = null;
    const wl = sess.session_attach(alpha, w, 0, &cause).?;
    alpha.curw = wl;
    const first = window_mod.window_add_pane(w, null, 10, 6);
    const second = window_mod.window_add_pane(w, null, 9, 6);
    w.active = second;

    const ctx = FormatContext{
        .session = alpha,
        .winlink = wl,
        .window = w,
        .pane = second,
    };

    const names = format_require_complete(xm.allocator, "#{N:editor}:#{N:missing}:#{N/s:alpha}:#{N/s:missing}", &ctx).?;
    defer xm.allocator.free(names);
    try std.testing.expectEqualStrings("1:0:1:0", names);

    const panes = format_require_complete(xm.allocator, "#{P:#{pane_index}#{?loop_last_flag,,|},[#{pane_index}]#{?loop_last_flag,,|}}", &ctx).?;
    defer xm.allocator.free(panes);
    try std.testing.expectEqualStrings("0|[1]", panes);

    _ = first;
}

test "format_expand handles client loops plus multibyte width and style quoting" {
    const env_mod = @import("environ.zig");

    client_registry.clients.clearRetainingCapacity();
    defer client_registry.clients.clearRetainingCapacity();

    var first = T.Client{
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{},
    };
    defer env_mod.environ_free(first.environ);
    first.tty = .{ .client = &first, .sx = 81, .sy = 24 };

    var second = T.Client{
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{},
    };
    defer env_mod.environ_free(second.environ);
    second.tty = .{ .client = &second, .sx = 92, .sy = 30 };

    client_registry.add(&first);
    client_registry.add(&second);

    const loop_ctx = FormatContext{ .client = &second };
    const loop = format_require_complete(xm.allocator, "#{L:#{client_width}#{?loop_last_flag,,|},[#{client_width}]#{?loop_last_flag,,|}}", &loop_ctx).?;
    defer xm.allocator.free(loop);
    try std.testing.expectEqualStrings("81|[92]", loop);

    const text_ctx = FormatContext{ .message_text = "é#" };
    const rendered = format_require_complete(xm.allocator, "#{n:message_text}:#{w:message_text}:#{q/h:message_text}", &text_ctx).?;
    defer xm.allocator.free(rendered);
    try std.testing.expectEqualStrings("3:2:é##", rendered);
}
