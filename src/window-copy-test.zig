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
const args_mod = @import("arguments.zig");
const c = @import("c.zig");
const grid = @import("grid.zig");
const key_bindings_data = @import("key-bindings-data.zig");
const os_mod = @import("os/linux.zig");
const opts = @import("options.zig");
const proc_mod = @import("proc.zig");
const screen = @import("screen.zig");
const screen_write = @import("screen-write.zig");
const T = @import("types.zig");
const window = @import("window.zig");
const window_mode_runtime = @import("window-mode-runtime.zig");
const xm = @import("xmalloc.zig");
const wc = @import("window-copy.zig");

fn setGridLineText(gd: *T.Grid, row: u32, text: []const u8) void {
    var col: u32 = 0;
    while (col < text.len and col < gd.sx) : (col += 1) {
        var cell = T.grid_default_cell;
        cell.data = T.grid_default_cell.data;
        cell.data.data[0] = text[col];
        grid.set_cell(gd, row, col, &cell);
    }
}

fn runCopyModeTestCommand(wme: *T.WindowModeEntry, command: []const u8) !void {
    return runCopyModeTestCommandArgs(wme, null, &.{command});
}

fn runCopyModeTestCommandWithSession(wme: *T.WindowModeEntry, session: *T.Session, command: []const u8) !void {
    return runCopyModeTestCommandArgs(wme, session, &.{command});
}

fn runCopyModeTestCommandArgsWithClient(
    wme: *T.WindowModeEntry,
    client: ?*T.Client,
    session: ?*T.Session,
    values: []const []const u8,
) !void {
    var args = args_mod.Arguments.init(xm.allocator);
    defer args.deinit();
    for (values) |value|
        try args.values.append(xm.allocator, xm.xstrdup(value));
    wc.copyModeCommand(wme, client, if (session) |s| s else undefined, undefined, @ptrCast(&args), null);
}

fn runCopyModeTestCommandArgs(wme: *T.WindowModeEntry, session: ?*T.Session, values: []const []const u8) !void {
    return runCopyModeTestCommandArgsWithClient(wme, null, session, values);
}

fn runCopyModeMouseCommandArgs(
    wme: *T.WindowModeEntry,
    session: ?*T.Session,
    mouse: *const T.MouseEvent,
    values: []const []const u8,
) !void {
    var args = args_mod.Arguments.init(xm.allocator);
    defer args.deinit();
    for (values) |value|
        try args.values.append(xm.allocator, xm.xstrdup(value));
    wc.copyModeCommand(wme, null, if (session) |s| s else undefined, undefined, @ptrCast(&args), mouse);
}

fn initWindowCopyTestGlobals() void {
    const sess = @import("session.zig");

    sess.session_init_globals(xm.allocator);
    window.window_init_globals(xm.allocator);
}

fn installTestEventBase() ?*c.libevent.event_base {
    const old_base = proc_mod.libevent;
    proc_mod.libevent = os_mod.osdep_event_init();
    return old_base;
}

fn restoreTestEventBase(old_base: ?*c.libevent.event_base) void {
    if (proc_mod.libevent) |base| c.libevent.event_base_free(base);
    proc_mod.libevent = old_base;
}

fn collectCopyModeBuiltinCommandHeads(list: *std.ArrayList([]const u8)) !void {
    for (key_bindings_data.default_binding_specs) |spec| {
        if (!std.mem.eql(u8, spec.table, "copy-mode") and !std.mem.eql(u8, spec.table, "copy-mode-vi"))
            continue;
        const command = spec.command orelse continue;
        const send_at = std.mem.indexOf(u8, command, "send -X ") orelse continue;
        const rest = command[send_at + "send -X ".len ..];
        const end = std.mem.indexOfAny(u8, rest, " ;\"") orelse rest.len;
        const head = rest[0..end];
        if (head.len == 0) continue;

        var seen = false;
        for (list.items) |existing| {
            if (std.mem.eql(u8, existing, head)) {
                seen = true;
                break;
            }
        }
        if (!seen) try list.append(xm.allocator, head);
    }
}

fn copyModeClipboardTestPeerDispatch(_: ?*c.imsg.imsg, _: ?*anyopaque) callconv(.c) void {}

test "window-copy tracks source pane updates without explicit refresh" {
    const opts_mod = @import("options.zig");

    initWindowCopyTestGlobals();

    // Initialize global options so redraw can access copy-mode-position-format.
    opts_mod.global_w_options = opts_mod.options_create(null);
    defer opts_mod.options_free(opts_mod.global_w_options);
    opts_mod.options_default_all(opts_mod.global_w_options, T.OPTIONS_TABLE_WINDOW);

    const source_grid = grid.grid_create(6, 2, 0);
    defer grid.grid_free(source_grid);
    const target_grid = grid.grid_create(6, 2, 0);
    defer grid.grid_free(target_grid);
    const source_screen = screen.screen_init(6, 2, 0);
    defer {
        screen.screen_free(source_screen);
        xm.allocator.destroy(source_screen);
    }
    const target_screen = screen.screen_init(6, 2, 0);
    defer {
        screen.screen_free(target_screen);
        xm.allocator.destroy(target_screen);
    }

    const source_window_options = opts_mod.options_create(opts_mod.global_w_options);
    defer opts_mod.options_free(source_window_options);
    const target_window_options = opts_mod.options_create(opts_mod.global_w_options);
    defer opts_mod.options_free(target_window_options);

    var source_window = T.Window{
        .id = 1,
        .name = xm.xstrdup("copy-source"),
        .sx = 6,
        .sy = 2,
        .options = source_window_options,
    };
    defer xm.allocator.free(source_window.name);
    defer source_window.panes.deinit(xm.allocator);
    defer source_window.last_panes.deinit(xm.allocator);
    defer source_window.winlinks.deinit(xm.allocator);

    var target_window = T.Window{
        .id = 2,
        .name = xm.xstrdup("copy-target"),
        .sx = 6,
        .sy = 2,
        .options = target_window_options,
    };
    defer xm.allocator.free(target_window.name);
    defer target_window.panes.deinit(xm.allocator);
    defer target_window.last_panes.deinit(xm.allocator);
    defer target_window.winlinks.deinit(xm.allocator);

    var source = T.WindowPane{
        .id = 3,
        .window = &source_window,
        .options = undefined,
        .sx = 6,
        .sy = 2,
        .screen = source_screen,
        .base = .{ .grid = source_grid, .rlower = 1 },
    };
    defer window_mode_runtime.resetModeAll(&source);

    var target = T.WindowPane{
        .id = 4,
        .window = &target_window,
        .options = undefined,
        .sx = 6,
        .sy = 2,
        .screen = target_screen,
        .base = .{ .grid = target_grid, .rlower = 1 },
    };
    defer window_mode_runtime.resetModeAll(&target);

    try source_window.panes.append(xm.allocator, &source);
    try target_window.panes.append(xm.allocator, &target);
    source_window.active = &source;
    target_window.active = &target;

    setGridLineText(source.base.grid, 0, "alpha");
    setGridLineText(source.base.grid, 1, "beta");

    var args = args_mod.Arguments.init(xm.allocator);
    defer args.deinit();

    const wme = wc.enterMode(&target, &source, &args);
    try std.testing.expectEqual(&wc.window_copy_mode, wme.mode);
    try std.testing.expect(screen.screen_alternate_active(&target));
    {
        const captured = grid.string_cells(wc.modeData(wme).backing.grid, 0, 6, .{ .trim_trailing_spaces = true });
        defer xm.allocator.free(captured);
        try std.testing.expectEqualStrings("alpha", captured);
    }

    setGridLineText(source.base.grid, 0, "omega");
    wc.window_copy_redraw_screen(wme);
    {
        const synced = grid.string_cells(wc.modeData(wme).backing.grid, 0, 6, .{ .trim_trailing_spaces = true });
        defer xm.allocator.free(synced);
        try std.testing.expectEqualStrings("omega", synced);
    }

    var refresh_args = args_mod.Arguments.init(xm.allocator);
    defer refresh_args.deinit();
    try refresh_args.values.append(xm.allocator, xm.xstrdup("refresh-from-pane"));
    wc.copyModeCommand(wme, null, undefined, undefined, @ptrCast(&refresh_args), null);

    {
        const refreshed = grid.string_cells(wc.modeData(wme).backing.grid, 0, 6, .{ .trim_trailing_spaces = true });
        defer xm.allocator.free(refreshed);
        try std.testing.expectEqualStrings("omega", refreshed);
    }
}

test "window-copy backing carries source history rows" {
    const opts_mod = @import("options.zig");

    initWindowCopyTestGlobals();

    opts_mod.global_w_options = opts_mod.options_create(null);
    defer opts_mod.options_free(opts_mod.global_w_options);
    opts_mod.options_default_all(opts_mod.global_w_options, T.OPTIONS_TABLE_WINDOW);

    const source_grid = grid.grid_create(5, 2, 10);
    defer grid.grid_free(source_grid);
    const target_grid = grid.grid_create(5, 2, 0);
    defer grid.grid_free(target_grid);
    const source_screen = screen.screen_init(5, 2, 10);
    defer {
        screen.screen_free(source_screen);
        xm.allocator.destroy(source_screen);
    }
    const target_screen = screen.screen_init(5, 2, 0);
    defer {
        screen.screen_free(target_screen);
        xm.allocator.destroy(target_screen);
    }

    var source_window = T.Window{
        .id = 11,
        .name = xm.xstrdup("copy-history-source"),
        .sx = 5,
        .sy = 2,
        .options = opts_mod.options_create(opts_mod.global_w_options),
    };
    defer xm.allocator.free(source_window.name);
    defer opts_mod.options_free(source_window.options);
    defer source_window.panes.deinit(xm.allocator);
    defer source_window.last_panes.deinit(xm.allocator);
    defer source_window.winlinks.deinit(xm.allocator);

    var target_window = T.Window{
        .id = 12,
        .name = xm.xstrdup("copy-history-target"),
        .sx = 5,
        .sy = 2,
        .options = opts_mod.options_create(opts_mod.global_w_options),
    };
    defer xm.allocator.free(target_window.name);
    defer opts_mod.options_free(target_window.options);
    defer target_window.panes.deinit(xm.allocator);
    defer target_window.last_panes.deinit(xm.allocator);
    defer target_window.winlinks.deinit(xm.allocator);

    var source = T.WindowPane{
        .id = 13,
        .window = &source_window,
        .options = undefined,
        .sx = 5,
        .sy = 2,
        .screen = source_screen,
        .base = .{ .grid = source_grid, .rlower = 1 },
    };
    defer window_mode_runtime.resetModeAll(&source);

    var target = T.WindowPane{
        .id = 14,
        .window = &target_window,
        .options = undefined,
        .sx = 5,
        .sy = 2,
        .screen = target_screen,
        .base = .{ .grid = target_grid, .rlower = 1 },
    };
    defer window_mode_runtime.resetModeAll(&target);

    try source_window.panes.append(xm.allocator, &source);
    try target_window.panes.append(xm.allocator, &target);
    source_window.active = &source;
    target_window.active = &target;

    var ctx = T.ScreenWriteCtx{ .s = &source.base };
    screen_write.putn(&ctx, "one\r\ntwo\r\nthree");

    var args = args_mod.Arguments.init(xm.allocator);
    defer args.deinit();

    const wme = wc.enterMode(&target, &source, &args);
    try std.testing.expectEqual(@as(u32, 1), wc.modeData(wme).backing.grid.hsize);

    try runCopyModeTestCommand(wme, "history-top");

    const top_line = grid.string_cells(target.screen.grid, 0, 5, .{ .trim_trailing_spaces = true });
    defer xm.allocator.free(top_line);
    try std.testing.expectEqualStrings("one", top_line);
}

test "window-copy navigation commands move through a taller source snapshot" {
    const opts_mod = @import("options.zig");

    initWindowCopyTestGlobals();

    opts_mod.global_w_options = opts_mod.options_create(null);
    defer opts_mod.options_free(opts_mod.global_w_options);
    opts_mod.options_default_all(opts_mod.global_w_options, T.OPTIONS_TABLE_WINDOW);

    const source_grid = grid.grid_create(6, 4, 0);
    defer grid.grid_free(source_grid);
    const target_grid = grid.grid_create(6, 2, 0);
    defer grid.grid_free(target_grid);
    const source_screen = screen.screen_init(6, 4, 0);
    defer {
        screen.screen_free(source_screen);
        xm.allocator.destroy(source_screen);
    }
    const target_screen = screen.screen_init(6, 2, 0);
    defer {
        screen.screen_free(target_screen);
        xm.allocator.destroy(target_screen);
    }

    const source_window_options = opts_mod.options_create(opts_mod.global_w_options);
    defer opts_mod.options_free(source_window_options);
    const target_window_options = opts_mod.options_create(opts_mod.global_w_options);
    defer opts_mod.options_free(target_window_options);

    var source_window = T.Window{
        .id = 10,
        .name = xm.xstrdup("copy-source-nav"),
        .sx = 6,
        .sy = 4,
        .options = source_window_options,
    };
    defer xm.allocator.free(source_window.name);
    defer source_window.panes.deinit(xm.allocator);
    defer source_window.last_panes.deinit(xm.allocator);
    defer source_window.winlinks.deinit(xm.allocator);

    var target_window = T.Window{
        .id = 11,
        .name = xm.xstrdup("copy-target-nav"),
        .sx = 6,
        .sy = 2,
        .options = target_window_options,
    };
    defer xm.allocator.free(target_window.name);
    defer target_window.panes.deinit(xm.allocator);
    defer target_window.last_panes.deinit(xm.allocator);
    defer target_window.winlinks.deinit(xm.allocator);

    var source = T.WindowPane{
        .id = 12,
        .window = &source_window,
        .options = undefined,
        .sx = 6,
        .sy = 4,
        .screen = source_screen,
        .base = .{ .grid = source_grid, .rlower = 3 },
    };
    defer window_mode_runtime.resetModeAll(&source);

    var target = T.WindowPane{
        .id = 13,
        .window = &target_window,
        .options = undefined,
        .sx = 6,
        .sy = 2,
        .screen = target_screen,
        .base = .{ .grid = target_grid, .rlower = 1 },
    };
    defer window_mode_runtime.resetModeAll(&target);

    try source_window.panes.append(xm.allocator, &source);
    try target_window.panes.append(xm.allocator, &target);
    source_window.active = &source;
    target_window.active = &target;

    setGridLineText(source.base.grid, 0, "one");
    setGridLineText(source.base.grid, 1, "two");
    setGridLineText(source.base.grid, 2, "tri");
    setGridLineText(source.base.grid, 3, "for");

    var args = args_mod.Arguments.init(xm.allocator);
    defer args.deinit();
    const wme = wc.enterMode(&target, &source, &args);

    var bottom_args = args_mod.Arguments.init(xm.allocator);
    defer bottom_args.deinit();
    try bottom_args.values.append(xm.allocator, xm.xstrdup("history-bottom"));
    wc.copyModeCommand(wme, null, undefined, undefined, @ptrCast(&bottom_args), null);
    try std.testing.expectEqual(@as(u32, 2), wc.modeData(wme).top);
    try std.testing.expectEqual(@as(u32, 1), wc.modeData(wme).cy);

    var top_args = args_mod.Arguments.init(xm.allocator);
    defer top_args.deinit();
    try top_args.values.append(xm.allocator, xm.xstrdup("history-top"));
    wc.copyModeCommand(wme, null, undefined, undefined, @ptrCast(&top_args), null);
    try std.testing.expectEqual(@as(u32, 0), wc.modeData(wme).top);
    try std.testing.expectEqual(@as(u32, 0), wc.modeData(wme).cy);

    var page_args = args_mod.Arguments.init(xm.allocator);
    defer page_args.deinit();
    try page_args.values.append(xm.allocator, xm.xstrdup("page-down"));
    wc.copyModeCommand(wme, null, undefined, undefined, @ptrCast(&page_args), null);
    try std.testing.expectEqual(@as(u32, 1), wc.modeData(wme).top);
    try std.testing.expectEqual(@as(u32, 0), wc.modeData(wme).cy);
}

test "window-copy wrapped line motions follow the shared grid reader" {
    const opts_mod = @import("options.zig");

    initWindowCopyTestGlobals();

    opts_mod.global_w_options = opts_mod.options_create(null);
    defer opts_mod.options_free(opts_mod.global_w_options);
    opts_mod.options_default_all(opts_mod.global_w_options, T.OPTIONS_TABLE_WINDOW);

    const source_grid = grid.grid_create(5, 2, 0);
    defer grid.grid_free(source_grid);
    const target_grid = grid.grid_create(5, 2, 0);
    defer grid.grid_free(target_grid);
    const source_screen = screen.screen_init(5, 2, 0);
    defer {
        screen.screen_free(source_screen);
        xm.allocator.destroy(source_screen);
    }
    const target_screen = screen.screen_init(5, 2, 0);
    defer {
        screen.screen_free(target_screen);
        xm.allocator.destroy(target_screen);
    }

    const window_options = opts_mod.options_create(opts_mod.global_w_options);
    defer opts_mod.options_free(window_options);

    var window_ = T.Window{
        .id = 14,
        .name = xm.xstrdup("copy-window-wrapped"),
        .sx = 5,
        .sy = 2,
        .options = window_options,
    };
    defer xm.allocator.free(window_.name);
    defer window_.panes.deinit(xm.allocator);
    defer window_.last_panes.deinit(xm.allocator);
    defer window_.winlinks.deinit(xm.allocator);

    var source = T.WindowPane{
        .id = 15,
        .window = &window_,
        .options = undefined,
        .sx = 5,
        .sy = 2,
        .screen = source_screen,
        .base = .{ .grid = source_grid, .rlower = 1 },
    };
    defer window_mode_runtime.resetModeAll(&source);

    var target = T.WindowPane{
        .id = 16,
        .window = &window_,
        .options = undefined,
        .sx = 5,
        .sy = 2,
        .screen = target_screen,
        .base = .{ .grid = target_grid, .rlower = 1 },
    };
    defer window_mode_runtime.resetModeAll(&target);

    try window_.panes.append(xm.allocator, &source);
    try window_.panes.append(xm.allocator, &target);
    window_.active = &target;

    grid.set_ascii(source.base.grid, 0, 0, ' ');
    grid.set_ascii(source.base.grid, 0, 1, ' ');
    grid.set_ascii(source.base.grid, 0, 2, 'a');
    grid.set_ascii(source.base.grid, 0, 3, 'b');
    source.base.grid.linedata[0].flags |= T.GRID_LINE_WRAPPED;
    grid.set_ascii(source.base.grid, 1, 0, ' ');
    grid.set_ascii(source.base.grid, 1, 1, 'c');

    var args = args_mod.Arguments.init(xm.allocator);
    defer args.deinit();
    const wme = wc.enterMode(&target, &source, &args);

    wc.modeData(wme).cx = 1;
    wc.modeData(wme).cy = 1;
    try runCopyModeTestCommand(wme, "back-to-indentation");
    try std.testing.expectEqual(@as(u32, 2), wc.modeData(wme).cx);
    try std.testing.expectEqual(@as(u32, 0), wc.absoluteCursorRow(wme));

    wc.modeData(wme).cx = 1;
    wc.modeData(wme).cy = 1;
    try runCopyModeTestCommand(wme, "start-of-line");
    try std.testing.expectEqual(@as(u32, 0), wc.modeData(wme).cx);
    try std.testing.expectEqual(@as(u32, 0), wc.absoluteCursorRow(wme));

    wc.modeData(wme).cx = 0;
    wc.modeData(wme).cy = 0;
    try runCopyModeTestCommand(wme, "end-of-line");
    try std.testing.expectEqual(@as(u32, 1), wc.modeData(wme).cx);
    try std.testing.expectEqual(@as(u32, 1), wc.absoluteCursorRow(wme));
}

test "window-copy word and space motions use session separators and mode keys" {
    const opts_mod = @import("options.zig");

    initWindowCopyTestGlobals();

    opts_mod.global_options = opts_mod.options_create(null);
    defer opts_mod.options_free(opts_mod.global_options);
    opts_mod.global_s_options = opts_mod.options_create(null);
    defer opts_mod.options_free(opts_mod.global_s_options);
    opts_mod.global_w_options = opts_mod.options_create(null);
    defer opts_mod.options_free(opts_mod.global_w_options);
    opts_mod.options_default_all(opts_mod.global_options, T.OPTIONS_TABLE_SERVER);
    opts_mod.options_default_all(opts_mod.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts_mod.options_default_all(opts_mod.global_w_options, T.OPTIONS_TABLE_WINDOW);

    const source_grid = grid.grid_create(14, 1, 0);
    defer grid.grid_free(source_grid);
    const target_grid = grid.grid_create(14, 1, 0);
    defer grid.grid_free(target_grid);
    const source_screen = screen.screen_init(14, 1, 0);
    defer {
        screen.screen_free(source_screen);
        xm.allocator.destroy(source_screen);
    }
    const target_screen = screen.screen_init(14, 1, 0);
    defer {
        screen.screen_free(target_screen);
        xm.allocator.destroy(target_screen);
    }

    var env = T.Environ.init(xm.allocator);
    defer env.deinit();

    const session_options = opts_mod.options_create(opts_mod.global_s_options);
    defer opts_mod.options_free(session_options);
    opts_mod.options_set_string(session_options, false, "word-separators", ",");

    var session = T.Session{
        .id = 60,
        .name = xm.xstrdup("copy-word-session"),
        .cwd = "/",
        .lastw = .{},
        .windows = std.AutoHashMap(i32, *T.Winlink).init(xm.allocator),
        .options = session_options,
        .environ = &env,
    };
    defer xm.allocator.free(session.name);
    defer session.lastw.deinit(xm.allocator);
    defer session.windows.deinit();

    var window_ = T.Window{
        .id = 61,
        .name = xm.xstrdup("copy-word-window"),
        .sx = 14,
        .sy = 1,
        .options = opts_mod.options_create(opts_mod.global_w_options),
    };
    defer xm.allocator.free(window_.name);
    defer opts_mod.options_free(window_.options);
    defer window_.panes.deinit(xm.allocator);
    defer window_.last_panes.deinit(xm.allocator);
    defer window_.winlinks.deinit(xm.allocator);

    var source = T.WindowPane{
        .id = 62,
        .window = &window_,
        .options = opts_mod.options_create(window_.options),
        .sx = 14,
        .sy = 1,
        .screen = source_screen,
        .base = .{ .grid = source_grid, .rlower = 0 },
    };
    defer opts_mod.options_free(source.options);
    defer window_mode_runtime.resetModeAll(&source);

    var target = T.WindowPane{
        .id = 63,
        .window = &window_,
        .options = opts_mod.options_create(window_.options),
        .sx = 14,
        .sy = 1,
        .screen = target_screen,
        .base = .{ .grid = target_grid, .rlower = 0 },
    };
    defer opts_mod.options_free(target.options);
    defer window_mode_runtime.resetModeAll(&target);

    try window_.panes.append(xm.allocator, &source);
    try window_.panes.append(xm.allocator, &target);
    window_.active = &target;

    setGridLineText(source.base.grid, 0, "foo,  bar baz");

    var args = args_mod.Arguments.init(xm.allocator);
    defer args.deinit();
    const wme = wc.enterMode(&target, &source, &args);

    try runCopyModeTestCommandWithSession(wme, &session, "next-word");
    try std.testing.expectEqual(@as(u32, 3), wc.modeData(wme).cx);
    try std.testing.expectEqual(@as(u32, 0), wc.absoluteCursorRow(wme));

    try runCopyModeTestCommandWithSession(wme, &session, "next-word");
    try std.testing.expectEqual(@as(u32, 6), wc.modeData(wme).cx);

    try runCopyModeTestCommandWithSession(wme, &session, "previous-word");
    try std.testing.expectEqual(@as(u32, 3), wc.modeData(wme).cx);

    wc.modeData(wme).cx = 0;
    try runCopyModeTestCommandWithSession(wme, &session, "next-space");
    try std.testing.expectEqual(@as(u32, 6), wc.modeData(wme).cx);

    try runCopyModeTestCommandWithSession(wme, &session, "previous-space");
    try std.testing.expectEqual(@as(u32, 0), wc.modeData(wme).cx);

    wc.modeData(wme).cx = 6;
    try runCopyModeTestCommandWithSession(wme, &session, "next-word-end");
    try std.testing.expectEqual(@as(u32, 9), wc.modeData(wme).cx);

    opts_mod.options_set_number(window_.options, "mode-keys", T.MODEKEY_VI);

    wc.modeData(wme).cx = 0;
    try runCopyModeTestCommandWithSession(wme, &session, "next-word-end");
    try std.testing.expectEqual(@as(u32, 2), wc.modeData(wme).cx);

    wc.modeData(wme).cx = 0;
    try runCopyModeTestCommandWithSession(wme, &session, "next-space-end");
    try std.testing.expectEqual(@as(u32, 3), wc.modeData(wme).cx);
}

test "window-copy select-word keeps separator-delimited selection bounds" {
    const opts_mod = @import("options.zig");

    initWindowCopyTestGlobals();

    opts_mod.global_options = opts_mod.options_create(null);
    defer opts_mod.options_free(opts_mod.global_options);
    opts_mod.global_s_options = opts_mod.options_create(null);
    defer opts_mod.options_free(opts_mod.global_s_options);
    opts_mod.global_w_options = opts_mod.options_create(null);
    defer opts_mod.options_free(opts_mod.global_w_options);
    opts_mod.options_default_all(opts_mod.global_options, T.OPTIONS_TABLE_SERVER);
    opts_mod.options_default_all(opts_mod.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts_mod.options_default_all(opts_mod.global_w_options, T.OPTIONS_TABLE_WINDOW);

    const source_grid = grid.grid_create(14, 1, 0);
    defer grid.grid_free(source_grid);
    const target_grid = grid.grid_create(14, 1, 0);
    defer grid.grid_free(target_grid);
    const source_screen = screen.screen_init(14, 1, 0);
    defer {
        screen.screen_free(source_screen);
        xm.allocator.destroy(source_screen);
    }
    const target_screen = screen.screen_init(14, 1, 0);
    defer {
        screen.screen_free(target_screen);
        xm.allocator.destroy(target_screen);
    }

    var env = T.Environ.init(xm.allocator);
    defer env.deinit();

    const session_options = opts_mod.options_create(opts_mod.global_s_options);
    defer opts_mod.options_free(session_options);
    opts_mod.options_set_string(session_options, false, "word-separators", ",");

    var session = T.Session{
        .id = 64,
        .name = xm.xstrdup("copy-select-word-session"),
        .cwd = "/",
        .lastw = .{},
        .windows = std.AutoHashMap(i32, *T.Winlink).init(xm.allocator),
        .options = session_options,
        .environ = &env,
    };
    defer xm.allocator.free(session.name);
    defer session.lastw.deinit(xm.allocator);
    defer session.windows.deinit();

    var window_ = T.Window{
        .id = 65,
        .name = xm.xstrdup("copy-select-word-window"),
        .sx = 14,
        .sy = 1,
        .options = opts_mod.options_create(opts_mod.global_w_options),
    };
    defer xm.allocator.free(window_.name);
    defer opts_mod.options_free(window_.options);
    defer window_.panes.deinit(xm.allocator);
    defer window_.last_panes.deinit(xm.allocator);
    defer window_.winlinks.deinit(xm.allocator);

    var source = T.WindowPane{
        .id = 66,
        .window = &window_,
        .options = opts_mod.options_create(window_.options),
        .sx = 14,
        .sy = 1,
        .screen = source_screen,
        .base = .{ .grid = source_grid, .rlower = 0 },
    };
    defer opts_mod.options_free(source.options);
    defer window_mode_runtime.resetModeAll(&source);

    var target = T.WindowPane{
        .id = 67,
        .window = &window_,
        .options = opts_mod.options_create(window_.options),
        .sx = 14,
        .sy = 1,
        .screen = target_screen,
        .base = .{ .grid = target_grid, .rlower = 0 },
    };
    defer opts_mod.options_free(target.options);
    defer window_mode_runtime.resetModeAll(&target);

    try window_.panes.append(xm.allocator, &source);
    try window_.panes.append(xm.allocator, &target);
    window_.active = &target;

    setGridLineText(source.base.grid, 0, "foo,  bar baz");

    var args = args_mod.Arguments.init(xm.allocator);
    defer args.deinit();
    const wme = wc.enterMode(&target, &source, &args);

    wc.modeData(wme).cx = 7;
    try runCopyModeTestCommandWithSession(wme, &session, "select-word");

    try std.testing.expectEqual(wc.CursorDrag.endsel, wc.modeData(wme).cursordrag);
    try std.testing.expectEqual(@as(u32, 6), wc.modeData(wme).selrx);
    try std.testing.expectEqual(@as(u32, 0), wc.modeData(wme).selry);
    try std.testing.expectEqual(@as(u32, 9), wc.modeData(wme).endselrx);
    try std.testing.expectEqual(@as(u32, 0), wc.modeData(wme).endselry);
    try std.testing.expectEqual(@as(u32, 9), wc.modeData(wme).cx);
    try std.testing.expectEqual(@as(u32, 0), wc.absoluteCursorRow(wme));
}

test "window-copy startDrag keeps session word separators when extending a word selection" {
    const opts_mod = @import("options.zig");

    initWindowCopyTestGlobals();

    opts_mod.global_options = opts_mod.options_create(null);
    defer opts_mod.options_free(opts_mod.global_options);
    opts_mod.global_s_options = opts_mod.options_create(null);
    defer opts_mod.options_free(opts_mod.global_s_options);
    opts_mod.global_w_options = opts_mod.options_create(null);
    defer opts_mod.options_free(opts_mod.global_w_options);
    opts_mod.options_default_all(opts_mod.global_options, T.OPTIONS_TABLE_SERVER);
    opts_mod.options_default_all(opts_mod.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts_mod.options_default_all(opts_mod.global_w_options, T.OPTIONS_TABLE_WINDOW);

    const source_grid = grid.grid_create(14, 1, 0);
    defer grid.grid_free(source_grid);
    const target_grid = grid.grid_create(14, 1, 0);
    defer grid.grid_free(target_grid);
    const source_screen = screen.screen_init(14, 1, 0);
    defer {
        screen.screen_free(source_screen);
        xm.allocator.destroy(source_screen);
    }
    const target_screen = screen.screen_init(14, 1, 0);
    defer {
        screen.screen_free(target_screen);
        xm.allocator.destroy(target_screen);
    }

    var env = T.Environ.init(xm.allocator);
    defer env.deinit();

    const session_options = opts_mod.options_create(opts_mod.global_s_options);
    defer opts_mod.options_free(session_options);
    opts_mod.options_set_string(session_options, false, "word-separators", ",");

    var session = T.Session{
        .id = 78,
        .name = xm.xstrdup("copy-drag-word-session"),
        .cwd = "/",
        .lastw = .{},
        .windows = std.AutoHashMap(i32, *T.Winlink).init(xm.allocator),
        .options = session_options,
        .environ = &env,
    };
    defer xm.allocator.free(session.name);
    defer session.lastw.deinit(xm.allocator);
    defer session.windows.deinit();

    var window_ = T.Window{
        .id = 79,
        .name = xm.xstrdup("copy-drag-word-window"),
        .sx = 14,
        .sy = 1,
        .options = opts_mod.options_create(opts_mod.global_w_options),
    };
    defer xm.allocator.free(window_.name);
    defer opts_mod.options_free(window_.options);
    defer window_.panes.deinit(xm.allocator);
    defer window_.last_panes.deinit(xm.allocator);
    defer window_.winlinks.deinit(xm.allocator);
    opts_mod.options_set_number(window_.options, "mode-keys", T.MODEKEY_VI);

    var source = T.WindowPane{
        .id = 80,
        .window = &window_,
        .options = opts_mod.options_create(window_.options),
        .sx = 14,
        .sy = 1,
        .screen = source_screen,
        .base = .{ .grid = source_grid, .rlower = 0 },
    };
    defer opts_mod.options_free(source.options);
    defer window_mode_runtime.resetModeAll(&source);

    var target = T.WindowPane{
        .id = 81,
        .window = &window_,
        .options = opts_mod.options_create(window_.options),
        .sx = 14,
        .sy = 1,
        .screen = target_screen,
        .base = .{ .grid = target_grid, .rlower = 0 },
    };
    defer opts_mod.options_free(target.options);
    defer window_mode_runtime.resetModeAll(&target);

    try window_.panes.append(xm.allocator, &source);
    try window_.panes.append(xm.allocator, &target);
    window_.active = &target;
    try window.all_window_panes.put(target.id, &target);
    defer _ = window.all_window_panes.remove(target.id);

    setGridLineText(source.base.grid, 0, "foo,  bar baz");

    var args = args_mod.Arguments.init(xm.allocator);
    defer args.deinit();
    const wme = wc.enterMode(&target, &source, &args);

    wc.modeData(wme).cx = 7;
    try runCopyModeTestCommandWithSession(wme, &session, "select-word");

    var client = T.Client{
        .name = "copy-drag-word-client",
        .environ = &env,
        .tty = undefined,
        .status = .{},
        .flags = T.CLIENT_ATTACHED,
        .session = &session,
    };
    client.tty = .{ .client = &client };

    var start_mouse = T.MouseEvent{
        .valid = true,
        .wp = @intCast(target.id),
        .x = 7,
        .y = 0,
    };
    wc.startDrag(&client, &start_mouse);

    try std.testing.expect(target.screen.sel != null);
    try std.testing.expect(client.tty.mouse_drag_release != null);
}

test "window-copy previous-word-pos respects custom separators" {
    const opts_mod = @import("options.zig");

    initWindowCopyTestGlobals();

    opts_mod.global_w_options = opts_mod.options_create(null);
    defer opts_mod.options_free(opts_mod.global_w_options);
    opts_mod.options_default_all(opts_mod.global_w_options, T.OPTIONS_TABLE_WINDOW);

    const source_grid = grid.grid_create(14, 1, 0);
    defer grid.grid_free(source_grid);
    const target_grid = grid.grid_create(14, 1, 0);
    defer grid.grid_free(target_grid);
    const source_screen = screen.screen_init(14, 1, 0);
    defer {
        screen.screen_free(source_screen);
        xm.allocator.destroy(source_screen);
    }
    const target_screen = screen.screen_init(14, 1, 0);
    defer {
        screen.screen_free(target_screen);
        xm.allocator.destroy(target_screen);
    }

    var window_ = T.Window{
        .id = 82,
        .name = xm.xstrdup("copy-prev-word-pos-window"),
        .sx = 14,
        .sy = 1,
        .options = opts_mod.options_create(opts_mod.global_w_options),
    };
    defer xm.allocator.free(window_.name);
    defer opts_mod.options_free(window_.options);
    defer window_.panes.deinit(xm.allocator);
    defer window_.last_panes.deinit(xm.allocator);
    defer window_.winlinks.deinit(xm.allocator);

    var source = T.WindowPane{
        .id = 83,
        .window = &window_,
        .options = opts_mod.options_create(window_.options),
        .sx = 14,
        .sy = 1,
        .screen = source_screen,
        .base = .{ .grid = source_grid, .rlower = 0 },
    };
    defer opts_mod.options_free(source.options);
    defer window_mode_runtime.resetModeAll(&source);

    var target = T.WindowPane{
        .id = 84,
        .window = &window_,
        .options = opts_mod.options_create(window_.options),
        .sx = 14,
        .sy = 1,
        .screen = target_screen,
        .base = .{ .grid = target_grid, .rlower = 0 },
    };
    defer opts_mod.options_free(target.options);
    defer window_mode_runtime.resetModeAll(&target);

    try window_.panes.append(xm.allocator, &source);
    try window_.panes.append(xm.allocator, &target);
    window_.active = &target;

    setGridLineText(source.base.grid, 0, "foo,  bar baz");

    var args = args_mod.Arguments.init(xm.allocator);
    defer args.deinit();
    const wme = wc.enterMode(&target, &source, &args);

    wc.modeData(wme).cx = 7;
    var px: u32 = 0;
    var py: u32 = 0;
    wc.window_copy_cursor_previous_word_pos(wme, ",", &px, &py);

    try std.testing.expectEqual(@as(u32, 6), px);
    try std.testing.expectEqual(@as(u32, 0), py);
}

test "window-copy jump char motions remember direction and target character" {
    initWindowCopyTestGlobals();

    const source_grid = grid.grid_create(16, 1, 0);
    defer grid.grid_free(source_grid);
    const target_grid = grid.grid_create(16, 1, 0);
    defer grid.grid_free(target_grid);
    const source_screen = screen.screen_init(16, 1, 0);
    defer {
        screen.screen_free(source_screen);
        xm.allocator.destroy(source_screen);
    }
    const target_screen = screen.screen_init(16, 1, 0);
    defer {
        screen.screen_free(target_screen);
        xm.allocator.destroy(target_screen);
    }

    var window_ = T.Window{
        .id = 70,
        .name = xm.xstrdup("copy-window-jump"),
        .sx = 16,
        .sy = 1,
        .options = undefined,
    };
    defer xm.allocator.free(window_.name);
    defer window_.panes.deinit(xm.allocator);
    defer window_.last_panes.deinit(xm.allocator);
    defer window_.winlinks.deinit(xm.allocator);

    var source = T.WindowPane{
        .id = 71,
        .window = &window_,
        .options = undefined,
        .sx = 16,
        .sy = 1,
        .screen = source_screen,
        .base = .{ .grid = source_grid, .rlower = 0 },
    };
    defer window_mode_runtime.resetModeAll(&source);

    var target = T.WindowPane{
        .id = 72,
        .window = &window_,
        .options = undefined,
        .sx = 16,
        .sy = 1,
        .screen = target_screen,
        .base = .{ .grid = target_grid, .rlower = 0 },
    };
    defer window_mode_runtime.resetModeAll(&target);

    try window_.panes.append(xm.allocator, &source);
    try window_.panes.append(xm.allocator, &target);
    window_.active = &target;

    setGridLineText(source.base.grid, 0, "abc def ghi def");

    var args = args_mod.Arguments.init(xm.allocator);
    defer args.deinit();
    const wme = wc.enterMode(&target, &source, &args);

    try runCopyModeTestCommandArgs(wme, null, &.{ "jump-forward", "d" });
    try std.testing.expectEqual(@as(u32, 4), wc.modeData(wme).cx);
    try std.testing.expectEqual(wc.JumpType.forward, wc.modeData(wme).jump_type);
    try std.testing.expectEqual(@as(u8, 'd'), wc.modeData(wme).jump_char.data[0]);

    try runCopyModeTestCommand(wme, "jump-again");
    try std.testing.expectEqual(@as(u32, 12), wc.modeData(wme).cx);

    try runCopyModeTestCommand(wme, "jump-reverse");
    try std.testing.expectEqual(@as(u32, 4), wc.modeData(wme).cx);

    wc.modeData(wme).cx = 0;
    try runCopyModeTestCommandArgs(wme, null, &.{ "jump-to-forward", "d" });
    try std.testing.expectEqual(@as(u32, 3), wc.modeData(wme).cx);
    try std.testing.expectEqual(wc.JumpType.to_forward, wc.modeData(wme).jump_type);

    wc.modeData(wme).cx = 12;
    try runCopyModeTestCommandArgs(wme, null, &.{ "jump-to-backward", "d" });
    try std.testing.expectEqual(@as(u32, 5), wc.modeData(wme).cx);
    try std.testing.expectEqual(wc.JumpType.to_backward, wc.modeData(wme).jump_type);

    wc.modeData(wme).cx = 12;
    try runCopyModeTestCommandArgs(wme, null, &.{ "jump-backward", "d" });
    try std.testing.expectEqual(@as(u32, 4), wc.modeData(wme).cx);
    try std.testing.expectEqual(wc.JumpType.backward, wc.modeData(wme).jump_type);
}

test "window-copy downward commands keep viewport scrolling separate from cancel variants" {
    initWindowCopyTestGlobals();

    const source_grid = grid.grid_create(6, 8, 0);
    defer grid.grid_free(source_grid);
    const target_grid = grid.grid_create(6, 5, 0);
    defer grid.grid_free(target_grid);
    const source_screen = screen.screen_init(6, 8, 0);
    defer {
        screen.screen_free(source_screen);
        xm.allocator.destroy(source_screen);
    }
    const target_screen = screen.screen_init(6, 5, 0);
    defer {
        screen.screen_free(target_screen);
        xm.allocator.destroy(target_screen);
    }

    var source_window = T.Window{
        .id = 50,
        .name = xm.xstrdup("copy-source-downward"),
        .sx = 6,
        .sy = 8,
        .options = undefined,
    };
    defer xm.allocator.free(source_window.name);
    defer source_window.panes.deinit(xm.allocator);
    defer source_window.last_panes.deinit(xm.allocator);
    defer source_window.winlinks.deinit(xm.allocator);

    var target_window = T.Window{
        .id = 51,
        .name = xm.xstrdup("copy-target-downward"),
        .sx = 6,
        .sy = 5,
        .options = undefined,
    };
    defer xm.allocator.free(target_window.name);
    defer target_window.panes.deinit(xm.allocator);
    defer target_window.last_panes.deinit(xm.allocator);
    defer target_window.winlinks.deinit(xm.allocator);

    var source = T.WindowPane{
        .id = 52,
        .window = &source_window,
        .options = undefined,
        .sx = 6,
        .sy = 8,
        .screen = source_screen,
        .base = .{ .grid = source_grid, .rlower = 7 },
    };
    defer window_mode_runtime.resetModeAll(&source);

    var target = T.WindowPane{
        .id = 53,
        .window = &target_window,
        .options = undefined,
        .sx = 6,
        .sy = 5,
        .screen = target_screen,
        .base = .{ .grid = target_grid, .rlower = 4 },
    };
    defer window_mode_runtime.resetModeAll(&target);

    try source_window.panes.append(xm.allocator, &source);
    try target_window.panes.append(xm.allocator, &target);
    source_window.active = &source;
    target_window.active = &target;

    var row: u32 = 0;
    while (row < 8) : (row += 1) {
        setGridLineText(source.base.grid, row, "line");
        source.base.grid.linedata[row].cellused = 4;
    }

    var args = args_mod.Arguments.init(xm.allocator);
    defer args.deinit();

    var wme = wc.enterMode(&target, &source, &args);
    try runCopyModeTestCommand(wme, "scroll-down");
    try std.testing.expectEqual(@as(u32, 1), wc.modeData(wme).top);
    try std.testing.expectEqual(@as(u32, 0), wc.modeData(wme).cy);

    try runCopyModeTestCommand(wme, "cursor-down");
    try std.testing.expectEqual(@as(u32, 1), wc.modeData(wme).top);
    try std.testing.expectEqual(@as(u32, 1), wc.modeData(wme).cy);

    _ = window_mode_runtime.resetMode(&target);
    try std.testing.expect(window.window_pane_mode(&target) == null);

    wme = wc.enterMode(&target, &source, &args);
    wme.prefix = 3;
    try runCopyModeTestCommand(wme, "scroll-down-and-cancel");
    try std.testing.expect(window.window_pane_mode(&target) == null);

    wme = wc.enterMode(&target, &source, &args);
    try runCopyModeTestCommand(wme, "page-down-and-cancel");
    try std.testing.expect(window.window_pane_mode(&target) == null);

    wme = wc.enterMode(&target, &source, &args);
    try runCopyModeTestCommand(wme, "halfpage-down");
    try std.testing.expectEqual(@as(u32, 2), wc.modeData(wme).top);
    try runCopyModeTestCommand(wme, "halfpage-down-and-cancel");
    try std.testing.expect(window.window_pane_mode(&target) == null);

    wme = wc.enterMode(&target, &source, &args);
    try runCopyModeTestCommand(wme, "history-bottom");
    try std.testing.expectEqual(@as(u32, 3), wc.modeData(wme).top);
    try std.testing.expectEqual(@as(u32, 4), wc.modeData(wme).cy);
    try runCopyModeTestCommand(wme, "cursor-down-and-cancel");
    try std.testing.expect(window.window_pane_mode(&target) == null);
}

test "window-copy paragraph motions follow tmux blank-line paragraph scans" {
    initWindowCopyTestGlobals();

    const source_grid = grid.grid_create(8, 8, 0);
    defer grid.grid_free(source_grid);
    const target_grid = grid.grid_create(8, 5, 0);
    defer grid.grid_free(target_grid);
    const source_screen = screen.screen_init(8, 8, 0);
    defer {
        screen.screen_free(source_screen);
        xm.allocator.destroy(source_screen);
    }
    const target_screen = screen.screen_init(8, 5, 0);
    defer {
        screen.screen_free(target_screen);
        xm.allocator.destroy(target_screen);
    }

    var source_window = T.Window{
        .id = 70,
        .name = xm.xstrdup("copy-source-paragraph"),
        .sx = 8,
        .sy = 8,
        .options = undefined,
    };
    defer xm.allocator.free(source_window.name);
    defer source_window.panes.deinit(xm.allocator);
    defer source_window.last_panes.deinit(xm.allocator);
    defer source_window.winlinks.deinit(xm.allocator);

    var target_window = T.Window{
        .id = 71,
        .name = xm.xstrdup("copy-target-paragraph"),
        .sx = 8,
        .sy = 5,
        .options = undefined,
    };
    defer xm.allocator.free(target_window.name);
    defer target_window.panes.deinit(xm.allocator);
    defer target_window.last_panes.deinit(xm.allocator);
    defer target_window.winlinks.deinit(xm.allocator);

    var source = T.WindowPane{
        .id = 72,
        .window = &source_window,
        .options = undefined,
        .sx = 8,
        .sy = 8,
        .screen = source_screen,
        .base = .{ .grid = source_grid, .rlower = 7 },
    };
    defer window_mode_runtime.resetModeAll(&source);

    var target = T.WindowPane{
        .id = 73,
        .window = &target_window,
        .options = undefined,
        .sx = 8,
        .sy = 5,
        .screen = target_screen,
        .base = .{ .grid = target_grid, .rlower = 4 },
    };
    defer window_mode_runtime.resetModeAll(&target);

    try source_window.panes.append(xm.allocator, &source);
    try target_window.panes.append(xm.allocator, &target);
    source_window.active = &source;
    target_window.active = &target;

    setGridLineText(source.base.grid, 0, "alpha");
    setGridLineText(source.base.grid, 1, "beta");
    setGridLineText(source.base.grid, 3, "gamma");
    setGridLineText(source.base.grid, 4, "delta");
    setGridLineText(source.base.grid, 7, "omega");

    var args = args_mod.Arguments.init(xm.allocator);
    defer args.deinit();
    const wme = wc.enterMode(&target, &source, &args);

    try runCopyModeTestCommand(wme, "next-paragraph");
    try std.testing.expectEqual(@as(u32, 2), wc.absoluteCursorRow(wme));
    try std.testing.expectEqual(@as(u32, 0), wc.modeData(wme).cx);

    wme.prefix = 2;
    try runCopyModeTestCommand(wme, "next-paragraph");
    try std.testing.expectEqual(@as(u32, 7), wc.absoluteCursorRow(wme));
    try std.testing.expectEqual(@as(u32, 4), wc.modeData(wme).cx);
    try std.testing.expectEqual(@as(u32, 3), wc.modeData(wme).top);
    try std.testing.expectEqual(@as(u32, 4), wc.modeData(wme).cy);

    try runCopyModeTestCommand(wme, "previous-paragraph");
    try std.testing.expectEqual(@as(u32, 6), wc.absoluteCursorRow(wme));
    try std.testing.expectEqual(@as(u32, 0), wc.modeData(wme).cx);

    wme.prefix = 2;
    try runCopyModeTestCommand(wme, "previous-paragraph");
    try std.testing.expectEqual(@as(u32, 0), wc.absoluteCursorRow(wme));
    try std.testing.expectEqual(@as(u32, 0), wc.modeData(wme).cx);
    try std.testing.expectEqual(@as(u32, 0), wc.modeData(wme).top);
    try std.testing.expectEqual(@as(u32, 0), wc.modeData(wme).cy);
}

test "window-copy goto-line accepts numeric offsets and clamps within the reduced snapshot" {
    initWindowCopyTestGlobals();

    const source_grid = grid.grid_create(6, 8, 0);
    defer grid.grid_free(source_grid);
    const target_grid = grid.grid_create(6, 5, 0);
    defer grid.grid_free(target_grid);
    const source_screen = screen.screen_init(6, 8, 0);
    defer {
        screen.screen_free(source_screen);
        xm.allocator.destroy(source_screen);
    }
    const target_screen = screen.screen_init(6, 5, 0);
    defer {
        screen.screen_free(target_screen);
        xm.allocator.destroy(target_screen);
    }

    var source_window = T.Window{
        .id = 54,
        .name = xm.xstrdup("copy-source-goto-line"),
        .sx = 6,
        .sy = 8,
        .options = undefined,
    };
    defer xm.allocator.free(source_window.name);
    defer source_window.panes.deinit(xm.allocator);
    defer source_window.last_panes.deinit(xm.allocator);
    defer source_window.winlinks.deinit(xm.allocator);

    var target_window = T.Window{
        .id = 55,
        .name = xm.xstrdup("copy-target-goto-line"),
        .sx = 6,
        .sy = 5,
        .options = undefined,
    };
    defer xm.allocator.free(target_window.name);
    defer target_window.panes.deinit(xm.allocator);
    defer target_window.last_panes.deinit(xm.allocator);
    defer target_window.winlinks.deinit(xm.allocator);

    var source = T.WindowPane{
        .id = 56,
        .window = &source_window,
        .options = undefined,
        .sx = 6,
        .sy = 8,
        .screen = source_screen,
        .base = .{ .grid = source_grid, .rlower = 7 },
    };
    defer window_mode_runtime.resetModeAll(&source);

    var target = T.WindowPane{
        .id = 57,
        .window = &target_window,
        .options = undefined,
        .sx = 6,
        .sy = 5,
        .screen = target_screen,
        .base = .{ .grid = target_grid, .rlower = 4 },
    };
    defer window_mode_runtime.resetModeAll(&target);

    try source_window.panes.append(xm.allocator, &source);
    try target_window.panes.append(xm.allocator, &target);
    source_window.active = &source;
    target_window.active = &target;

    var row: u32 = 0;
    while (row < 8) : (row += 1) {
        setGridLineText(source.base.grid, row, "line");
        source.base.grid.linedata[row].cellused = 4;
    }
    source.base.cx = 3;
    source.base.cy = 4;

    var args = args_mod.Arguments.init(xm.allocator);
    defer args.deinit();
    const wme = wc.enterMode(&target, &source, &args);
    try std.testing.expectEqual(@as(u32, 0), wc.modeData(wme).top);
    try std.testing.expectEqual(@as(u32, 4), wc.modeData(wme).cy);
    try std.testing.expectEqual(@as(u32, 4), wc.absoluteCursorRow(wme));

    try runCopyModeTestCommandArgs(wme, null, &.{ "goto-line", "1" });
    try std.testing.expectEqual(@as(u32, 2), wc.modeData(wme).top);
    try std.testing.expectEqual(@as(u32, 4), wc.modeData(wme).cy);
    try std.testing.expectEqual(@as(u32, 6), wc.absoluteCursorRow(wme));

    try runCopyModeTestCommandArgs(wme, null, &.{ "goto-line", "bogus" });
    try std.testing.expectEqual(@as(u32, 2), wc.modeData(wme).top);
    try std.testing.expectEqual(@as(u32, 4), wc.modeData(wme).cy);

    try runCopyModeTestCommandArgs(wme, null, &.{ "goto-line", "99" });
    try std.testing.expectEqual(@as(u32, 0), wc.modeData(wme).top);
    try std.testing.expectEqual(@as(u32, 4), wc.modeData(wme).cy);
    try std.testing.expectEqual(@as(u32, 4), wc.absoluteCursorRow(wme));
}

test "window-copy startDrag keeps the cursor under reduced mouse drags" {
    const opts_mod = @import("options.zig");

    initWindowCopyTestGlobals();

    opts_mod.global_options = opts_mod.options_create(null);
    defer opts_mod.options_free(opts_mod.global_options);
    opts_mod.global_s_options = opts_mod.options_create(null);
    defer opts_mod.options_free(opts_mod.global_s_options);
    opts_mod.global_w_options = opts_mod.options_create(null);
    defer opts_mod.options_free(opts_mod.global_w_options);
    opts_mod.options_default_all(opts_mod.global_options, T.OPTIONS_TABLE_SERVER);
    opts_mod.options_default_all(opts_mod.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts_mod.options_default_all(opts_mod.global_w_options, T.OPTIONS_TABLE_WINDOW);
    window.window_init_globals(xm.allocator);

    const source_grid = grid.grid_create(6, 2, 0);
    defer grid.grid_free(source_grid);
    const target_grid = grid.grid_create(6, 2, 0);
    defer grid.grid_free(target_grid);
    const source_screen = screen.screen_init(6, 2, 0);
    defer {
        screen.screen_free(source_screen);
        xm.allocator.destroy(source_screen);
    }
    const target_screen = screen.screen_init(6, 2, 0);
    defer {
        screen.screen_free(target_screen);
        xm.allocator.destroy(target_screen);
    }

    var window_ = T.Window{
        .id = 30,
        .name = xm.xstrdup("copy-drag"),
        .sx = 6,
        .sy = 2,
        .options = opts_mod.options_create(opts_mod.global_w_options),
    };
    defer xm.allocator.free(window_.name);
    defer opts_mod.options_free(window_.options);
    defer window_.panes.deinit(xm.allocator);
    defer window_.last_panes.deinit(xm.allocator);
    defer window_.winlinks.deinit(xm.allocator);

    var source = T.WindowPane{
        .id = 31,
        .window = &window_,
        .options = opts_mod.options_create(window_.options),
        .sx = 6,
        .sy = 2,
        .screen = source_screen,
        .base = .{ .grid = source_grid, .rlower = 1 },
    };
    defer opts_mod.options_free(source.options);
    defer window_mode_runtime.resetModeAll(&source);

    var target = T.WindowPane{
        .id = 32,
        .window = &window_,
        .options = opts_mod.options_create(window_.options),
        .sx = 6,
        .sy = 2,
        .screen = target_screen,
        .base = .{ .grid = target_grid, .rlower = 1 },
    };
    defer opts_mod.options_free(target.options);
    defer window_mode_runtime.resetModeAll(&target);

    try window_.panes.append(xm.allocator, &source);
    try window_.panes.append(xm.allocator, &target);
    window_.active = &target;
    try window.all_window_panes.put(target.id, &target);
    defer _ = window.all_window_panes.remove(target.id);

    grid.set_ascii(source.base.grid, 1, 0, 'a');
    grid.set_ascii(source.base.grid, 1, 1, 'b');
    grid.set_ascii(source.base.grid, 1, 2, 'c');
    grid.set_ascii(source.base.grid, 1, 3, 'd');
    grid.set_ascii(source.base.grid, 1, 4, 'e');
    grid.set_ascii(source.base.grid, 0, 0, 'v');
    grid.set_ascii(source.base.grid, 0, 1, 'w');
    grid.set_ascii(source.base.grid, 0, 2, 'x');

    var args = args_mod.Arguments.init(xm.allocator);
    defer args.deinit();
    _ = wc.enterMode(&target, &source, &args);

    var env = T.Environ.init(xm.allocator);
    defer env.deinit();

    var client = T.Client{
        .name = "copy-mode-drag-client",
        .environ = &env,
        .tty = undefined,
        .status = .{},
        .flags = T.CLIENT_ATTACHED,
    };
    client.tty = .{ .client = &client };

    var start_mouse = T.MouseEvent{
        .valid = true,
        .s = -1,
        .w = -1,
        .wp = @intCast(target.id),
        .x = 5,
        .y = 1,
        .lx = 4,
        .ly = 1,
    };
    wc.startDrag(&client, &start_mouse);
    try std.testing.expect(client.tty.mouse_drag_update != null);
    try std.testing.expect(client.tty.mouse_drag_release != null);
    try std.testing.expectEqual(@as(u32, 4), target.screen.cx);
    try std.testing.expectEqual(@as(u32, 1), target.screen.cy);
    try std.testing.expectEqual(wc.CursorDrag.endsel, wc.modeData(window.window_pane_mode(&target).?).cursordrag);

    var drag_mouse = T.MouseEvent{
        .valid = true,
        .s = -1,
        .w = -1,
        .wp = @intCast(target.id),
        .x = 2,
        .y = 0,
    };
    client.tty.mouse_drag_update.?(&client, &drag_mouse);
    try std.testing.expectEqual(@as(u32, 2), target.screen.cx);
    try std.testing.expectEqual(@as(u32, 0), target.screen.cy);
    try std.testing.expect(target.screen.sel != null);
    try std.testing.expectEqual(@as(u32, 4), target.screen.sel.?.sx);
    try std.testing.expectEqual(@as(u32, 1), target.screen.sel.?.sy);
    try std.testing.expectEqual(@as(u32, 2), target.screen.sel.?.ex);
    try std.testing.expectEqual(@as(u32, 0), target.screen.sel.?.ey);
}

test "window-copy dragUpdate scrolls when dragging at the viewport edge" {
    const opts_mod = @import("options.zig");

    initWindowCopyTestGlobals();

    opts_mod.global_options = opts_mod.options_create(null);
    defer opts_mod.options_free(opts_mod.global_options);
    opts_mod.global_s_options = opts_mod.options_create(null);
    defer opts_mod.options_free(opts_mod.global_s_options);
    opts_mod.global_w_options = opts_mod.options_create(null);
    defer opts_mod.options_free(opts_mod.global_w_options);
    opts_mod.options_default_all(opts_mod.global_options, T.OPTIONS_TABLE_SERVER);
    opts_mod.options_default_all(opts_mod.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts_mod.options_default_all(opts_mod.global_w_options, T.OPTIONS_TABLE_WINDOW);
    window.window_init_globals(xm.allocator);

    const source_grid = grid.grid_create(6, 4, 0);
    defer grid.grid_free(source_grid);
    const target_grid = grid.grid_create(6, 2, 0);
    defer grid.grid_free(target_grid);
    const source_screen = screen.screen_init(6, 4, 0);
    defer {
        screen.screen_free(source_screen);
        xm.allocator.destroy(source_screen);
    }
    const target_screen = screen.screen_init(6, 2, 0);
    defer {
        screen.screen_free(target_screen);
        xm.allocator.destroy(target_screen);
    }

    var window_ = T.Window{
        .id = 33,
        .name = xm.xstrdup("copy-drag-edge"),
        .sx = 6,
        .sy = 2,
        .options = opts_mod.options_create(opts_mod.global_w_options),
    };
    defer xm.allocator.free(window_.name);
    defer opts_mod.options_free(window_.options);
    defer window_.panes.deinit(xm.allocator);
    defer window_.last_panes.deinit(xm.allocator);
    defer window_.winlinks.deinit(xm.allocator);

    var source = T.WindowPane{
        .id = 34,
        .window = &window_,
        .options = opts_mod.options_create(window_.options),
        .sx = 6,
        .sy = 4,
        .screen = source_screen,
        .base = .{ .grid = source_grid, .rlower = 3 },
    };
    defer opts_mod.options_free(source.options);
    defer window_mode_runtime.resetModeAll(&source);

    var target = T.WindowPane{
        .id = 35,
        .window = &window_,
        .options = opts_mod.options_create(window_.options),
        .sx = 6,
        .sy = 2,
        .screen = target_screen,
        .base = .{ .grid = target_grid, .rlower = 1 },
    };
    defer opts_mod.options_free(target.options);
    defer window_mode_runtime.resetModeAll(&target);

    try window_.panes.append(xm.allocator, &source);
    try window_.panes.append(xm.allocator, &target);
    window_.active = &target;
    try window.all_window_panes.put(target.id, &target);
    defer _ = window.all_window_panes.remove(target.id);

    setGridLineText(source.base.grid, 0, "row0");
    setGridLineText(source.base.grid, 1, "row1");
    setGridLineText(source.base.grid, 2, "row2");
    setGridLineText(source.base.grid, 3, "row3");

    var args = args_mod.Arguments.init(xm.allocator);
    defer args.deinit();
    _ = wc.enterMode(&target, &source, &args);

    var env = T.Environ.init(xm.allocator);
    defer env.deinit();

    var client = T.Client{
        .name = "copy-mode-edge-client",
        .environ = &env,
        .tty = undefined,
        .status = .{},
        .flags = T.CLIENT_ATTACHED,
    };
    client.tty = .{ .client = &client };

    var mouse = T.MouseEvent{
        .valid = true,
        .s = -1,
        .w = -1,
        .wp = @intCast(target.id),
        .x = 0,
        .y = 1,
        .lx = 0,
        .ly = 1,
    };
    wc.startDrag(&client, &mouse);

    const wme = window.window_pane_mode(&target).?;
    try std.testing.expectEqual(@as(u32, 1), wc.modeData(wme).top);
    try std.testing.expectEqual(@as(u32, 2), wc.absoluteCursorRow(wme));

    wc.modeData(wme).top = 1;
    wc.modeData(wme).cy = 0;
    mouse.y = 0;
    mouse.ly = 0;
    client.tty.mouse_drag_update.?(&client, &mouse);

    try std.testing.expectEqual(@as(u32, 0), wc.modeData(wme).top);
    try std.testing.expect(target.screen.sel != null);
}

test "window-copy scroll timer repeats edge drag scrolling" {
    const opts_mod = @import("options.zig");

    initWindowCopyTestGlobals();

    const old_base = installTestEventBase();
    defer restoreTestEventBase(old_base);

    opts_mod.global_options = opts_mod.options_create(null);
    defer opts_mod.options_free(opts_mod.global_options);
    opts_mod.global_s_options = opts_mod.options_create(null);
    defer opts_mod.options_free(opts_mod.global_s_options);
    opts_mod.global_w_options = opts_mod.options_create(null);
    defer opts_mod.options_free(opts_mod.global_w_options);
    opts_mod.options_default_all(opts_mod.global_options, T.OPTIONS_TABLE_SERVER);
    opts_mod.options_default_all(opts_mod.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts_mod.options_default_all(opts_mod.global_w_options, T.OPTIONS_TABLE_WINDOW);
    window.window_init_globals(xm.allocator);

    const source_grid = grid.grid_create(6, 4, 0);
    defer grid.grid_free(source_grid);
    const target_grid = grid.grid_create(6, 2, 0);
    defer grid.grid_free(target_grid);
    const source_screen = screen.screen_init(6, 4, 0);
    defer {
        screen.screen_free(source_screen);
        xm.allocator.destroy(source_screen);
    }
    const target_screen = screen.screen_init(6, 2, 0);
    defer {
        screen.screen_free(target_screen);
        xm.allocator.destroy(target_screen);
    }

    var window_ = T.Window{
        .id = 36,
        .name = xm.xstrdup("copy-drag-repeat"),
        .sx = 6,
        .sy = 2,
        .options = opts_mod.options_create(opts_mod.global_w_options),
    };
    defer xm.allocator.free(window_.name);
    defer opts_mod.options_free(window_.options);
    defer window_.panes.deinit(xm.allocator);
    defer window_.last_panes.deinit(xm.allocator);
    defer window_.winlinks.deinit(xm.allocator);

    var source = T.WindowPane{
        .id = 37,
        .window = &window_,
        .options = opts_mod.options_create(window_.options),
        .sx = 6,
        .sy = 4,
        .screen = source_screen,
        .base = .{ .grid = source_grid, .rlower = 3 },
    };
    defer opts_mod.options_free(source.options);
    defer window_mode_runtime.resetModeAll(&source);

    var target = T.WindowPane{
        .id = 38,
        .window = &window_,
        .options = opts_mod.options_create(window_.options),
        .sx = 6,
        .sy = 2,
        .screen = target_screen,
        .base = .{ .grid = target_grid, .rlower = 1 },
    };
    defer opts_mod.options_free(target.options);
    defer window_mode_runtime.resetModeAll(&target);

    try window_.panes.append(xm.allocator, &source);
    try window_.panes.append(xm.allocator, &target);
    window_.active = &target;
    try window.all_window_panes.put(target.id, &target);
    defer _ = window.all_window_panes.remove(target.id);

    setGridLineText(source.base.grid, 0, "row0");
    setGridLineText(source.base.grid, 1, "row1");
    setGridLineText(source.base.grid, 2, "row2");
    setGridLineText(source.base.grid, 3, "row3");

    var args = args_mod.Arguments.init(xm.allocator);
    defer args.deinit();
    _ = wc.enterMode(&target, &source, &args);

    var env = T.Environ.init(xm.allocator);
    defer env.deinit();

    var client = T.Client{
        .name = "copy-mode-repeat-client",
        .environ = &env,
        .tty = undefined,
        .status = .{},
        .flags = T.CLIENT_ATTACHED,
    };
    client.tty = .{ .client = &client };

    var mouse = T.MouseEvent{
        .valid = true,
        .s = -1,
        .w = -1,
        .wp = @intCast(target.id),
        .x = 0,
        .y = 1,
        .lx = 0,
        .ly = 1,
    };
    wc.startDrag(&client, &mouse);

    const wme = window.window_pane_mode(&target).?;
    try std.testing.expect(wc.modeData(wme).drag_timer != null);
    try std.testing.expectEqual(@as(u32, 1), wc.modeData(wme).top);
    try std.testing.expectEqual(@as(u32, 2), wc.absoluteCursorRow(wme));

    wc.window_copy_scroll_timer(-1, 0, @ptrCast(wme));

    try std.testing.expectEqual(@as(u32, 2), wc.modeData(wme).top);
    try std.testing.expectEqual(@as(u32, 3), wc.absoluteCursorRow(wme));
    try std.testing.expect(target.screen.sel != null);
}

test "window-copy scrollToMouse maps the reduced viewport onto scrollbar drags" {
    const opts_mod = @import("options.zig");

    initWindowCopyTestGlobals();

    opts_mod.global_options = opts_mod.options_create(null);
    defer opts_mod.options_free(opts_mod.global_options);
    opts_mod.global_s_options = opts_mod.options_create(null);
    defer opts_mod.options_free(opts_mod.global_s_options);
    opts_mod.global_w_options = opts_mod.options_create(null);
    defer opts_mod.options_free(opts_mod.global_w_options);
    opts_mod.options_default_all(opts_mod.global_options, T.OPTIONS_TABLE_SERVER);
    opts_mod.options_default_all(opts_mod.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts_mod.options_default_all(opts_mod.global_w_options, T.OPTIONS_TABLE_WINDOW);

    const source_grid = grid.grid_create(6, 4, 0);
    defer grid.grid_free(source_grid);
    const target_grid = grid.grid_create(6, 2, 0);
    defer grid.grid_free(target_grid);
    const source_screen = screen.screen_init(6, 4, 0);
    defer {
        screen.screen_free(source_screen);
        xm.allocator.destroy(source_screen);
    }
    const target_screen = screen.screen_init(6, 2, 0);
    defer {
        screen.screen_free(target_screen);
        xm.allocator.destroy(target_screen);
    }

    var window_ = T.Window{
        .id = 40,
        .name = xm.xstrdup("copy-scroll"),
        .sx = 6,
        .sy = 2,
        .options = opts_mod.options_create(opts_mod.global_w_options),
    };
    defer xm.allocator.free(window_.name);
    defer opts_mod.options_free(window_.options);
    defer window_.panes.deinit(xm.allocator);
    defer window_.last_panes.deinit(xm.allocator);
    defer window_.winlinks.deinit(xm.allocator);

    var source = T.WindowPane{
        .id = 41,
        .window = &window_,
        .options = opts_mod.options_create(window_.options),
        .sx = 6,
        .sy = 4,
        .screen = source_screen,
        .base = .{ .grid = source_grid, .rlower = 3 },
    };
    defer opts_mod.options_free(source.options);
    defer window_mode_runtime.resetModeAll(&source);

    var target = T.WindowPane{
        .id = 42,
        .window = &window_,
        .options = opts_mod.options_create(window_.options),
        .sx = 6,
        .sy = 2,
        .screen = target_screen,
        .base = .{ .grid = target_grid, .rlower = 1 },
    };
    defer opts_mod.options_free(target.options);
    defer window_mode_runtime.resetModeAll(&target);

    try window_.panes.append(xm.allocator, &source);
    try window_.panes.append(xm.allocator, &target);
    window_.active = &source;

    var args = args_mod.Arguments.init(xm.allocator);
    defer args.deinit();
    const wme = wc.enterMode(&target, &source, &args);
    try std.testing.expectEqual(@as(u32, 0), wc.modeData(wme).top);

    wc.scrollToMouse(&target, 0, 1, false);
    try std.testing.expectEqual(@as(u32, 2), wc.modeData(wme).top);
    try std.testing.expectEqual(@as(u32, 0), target.screen.cy);

    wc.scrollToMouse(&target, 0, 0, false);
    try std.testing.expectEqual(@as(u32, 0), wc.modeData(wme).top);
}

test "unknown window-copy commands surface a status message" {
    const opts_mod = @import("options.zig");
    var env = T.Environ.init(xm.allocator);
    defer env.deinit();

    initWindowCopyTestGlobals();

    opts_mod.global_options = opts_mod.options_create(null);
    defer opts_mod.options_free(opts_mod.global_options);
    opts_mod.global_s_options = opts_mod.options_create(null);
    defer opts_mod.options_free(opts_mod.global_s_options);
    opts_mod.global_w_options = opts_mod.options_create(null);
    defer opts_mod.options_free(opts_mod.global_w_options);
    opts_mod.options_default_all(opts_mod.global_options, T.OPTIONS_TABLE_SERVER);
    opts_mod.options_default_all(opts_mod.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts_mod.options_default_all(opts_mod.global_w_options, T.OPTIONS_TABLE_WINDOW);

    const source_grid = grid.grid_create(4, 1, 0);
    defer grid.grid_free(source_grid);
    const target_grid = grid.grid_create(4, 1, 0);
    defer grid.grid_free(target_grid);
    const source_screen = screen.screen_init(4, 1, 0);
    defer {
        screen.screen_free(source_screen);
        xm.allocator.destroy(source_screen);
    }
    const target_screen = screen.screen_init(4, 1, 0);
    defer {
        screen.screen_free(target_screen);
        xm.allocator.destroy(target_screen);
    }

    var source_window = T.Window{
        .id = 20,
        .name = xm.xstrdup("copy-source-unsupported"),
        .sx = 4,
        .sy = 1,
        .options = undefined,
    };
    defer xm.allocator.free(source_window.name);
    defer source_window.panes.deinit(xm.allocator);
    defer source_window.last_panes.deinit(xm.allocator);
    defer source_window.winlinks.deinit(xm.allocator);

    var target_window = T.Window{
        .id = 21,
        .name = xm.xstrdup("copy-target-unsupported"),
        .sx = 4,
        .sy = 1,
        .options = undefined,
    };
    defer xm.allocator.free(target_window.name);
    defer target_window.panes.deinit(xm.allocator);
    defer target_window.last_panes.deinit(xm.allocator);
    defer target_window.winlinks.deinit(xm.allocator);

    var source = T.WindowPane{
        .id = 22,
        .window = &source_window,
        .options = undefined,
        .sx = 4,
        .sy = 1,
        .screen = source_screen,
        .base = .{ .grid = source_grid, .rlower = 0 },
    };
    defer window_mode_runtime.resetModeAll(&source);

    var target = T.WindowPane{
        .id = 23,
        .window = &target_window,
        .options = undefined,
        .sx = 4,
        .sy = 1,
        .screen = target_screen,
        .base = .{ .grid = target_grid, .rlower = 0 },
    };
    defer window_mode_runtime.resetModeAll(&target);

    try source_window.panes.append(xm.allocator, &source);
    try target_window.panes.append(xm.allocator, &target);
    source_window.active = &source;
    target_window.active = &target;

    var args = args_mod.Arguments.init(xm.allocator);
    defer args.deinit();
    const wme = wc.enterMode(&target, &source, &args);

    var client = T.Client{
        .name = "copy-mode-status-client",
        .environ = &env,
        .tty = undefined,
        .status = .{},
        .flags = T.CLIENT_ATTACHED,
    };
    client.tty = .{ .client = &client };
    defer if (client.message_string) |msg| xm.allocator.free(msg);

    var unsupported = args_mod.Arguments.init(xm.allocator);
    defer unsupported.deinit();
    try unsupported.values.append(xm.allocator, xm.xstrdup("definitely-not-a-tmux-command"));
    wc.copyModeCommand(wme, &client, undefined, undefined, @ptrCast(&unsupported), null);

    try std.testing.expectEqualStrings("Copy-mode command not supported yet: definitely-not-a-tmux-command", client.message_string.?);
}

test "copy-mode default tables only use supported send -X command heads" {
    const env_mod = @import("environ.zig");
    const opts_mod = @import("options.zig");
    const sess = @import("session.zig");

    initWindowCopyTestGlobals();

    opts_mod.global_options = opts_mod.options_create(null);
    defer opts_mod.options_free(opts_mod.global_options);
    opts_mod.global_s_options = opts_mod.options_create(null);
    defer opts_mod.options_free(opts_mod.global_s_options);
    opts_mod.global_w_options = opts_mod.options_create(null);
    defer opts_mod.options_free(opts_mod.global_w_options);
    opts_mod.options_default_all(opts_mod.global_options, T.OPTIONS_TABLE_SERVER);
    opts_mod.options_default_all(opts_mod.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts_mod.options_default_all(opts_mod.global_w_options, T.OPTIONS_TABLE_WINDOW);

    env_mod.global_environ = env_mod.environ_create();
    defer env_mod.environ_free(env_mod.global_environ);

    const session = sess.session_create(null, "copy-mode-builtins", "/", env_mod.environ_create(), opts_mod.options_create(opts_mod.global_s_options), null);
    defer if (sess.session_find("copy-mode-builtins") != null) sess.session_destroy(session, false, "test");

    const source_grid = grid.grid_create(16, 4, 0);
    defer grid.grid_free(source_grid);
    const target_grid = grid.grid_create(16, 4, 0);
    defer grid.grid_free(target_grid);
    const source_screen = screen.screen_init(16, 4, 0);
    defer {
        screen.screen_free(source_screen);
        xm.allocator.destroy(source_screen);
    }
    const target_screen = screen.screen_init(16, 4, 0);
    defer {
        screen.screen_free(target_screen);
        xm.allocator.destroy(target_screen);
    }

    var window_ = T.Window{
        .id = 24,
        .name = xm.xstrdup("copy-mode-builtins-window"),
        .sx = 16,
        .sy = 4,
        .options = opts_mod.options_create(opts_mod.global_w_options),
    };
    defer xm.allocator.free(window_.name);
    defer opts_mod.options_free(window_.options);
    defer window_.panes.deinit(xm.allocator);
    defer window_.last_panes.deinit(xm.allocator);
    defer window_.winlinks.deinit(xm.allocator);

    var source = T.WindowPane{
        .id = 25,
        .window = &window_,
        .options = opts_mod.options_create(window_.options),
        .sx = 16,
        .sy = 4,
        .screen = source_screen,
        .base = .{ .grid = source_grid, .rlower = 3 },
    };
    defer opts_mod.options_free(source.options);
    defer window_mode_runtime.resetModeAll(&source);

    var target = T.WindowPane{
        .id = 26,
        .window = &window_,
        .options = opts_mod.options_create(window_.options),
        .sx = 16,
        .sy = 4,
        .screen = target_screen,
        .base = .{ .grid = target_grid, .rlower = 3 },
    };
    defer opts_mod.options_free(target.options);
    defer window_mode_runtime.resetModeAll(&target);

    try window_.panes.append(xm.allocator, &source);
    try window_.panes.append(xm.allocator, &target);
    window_.active = &target;
    setGridLineText(source.base.grid, 0, "alpha beta");
    setGridLineText(source.base.grid, 1, "gamma delta");
    setGridLineText(source.base.grid, 2, "epsilon zeta");
    setGridLineText(source.base.grid, 3, "eta theta");

    var env = T.Environ.init(xm.allocator);
    defer env.deinit();

    var client = T.Client{
        .name = "copy-mode-builtin-client",
        .environ = &env,
        .tty = undefined,
        .status = .{},
        .flags = T.CLIENT_ATTACHED,
        .session = session,
    };
    client.tty = .{ .client = &client };

    var commands: std.ArrayList([]const u8) = .{};
    defer commands.deinit(xm.allocator);
    try collectCopyModeBuiltinCommandHeads(&commands);
    try std.testing.expect(commands.items.len != 0);

    var args = args_mod.Arguments.init(xm.allocator);
    defer args.deinit();
    var wme = wc.enterMode(&target, &source, &args);

    for (commands.items) |command| {
        wme = window.window_pane_mode(&target) orelse wc.enterMode(&target, &source, &args);
        if (client.message_string) |msg| {
            xm.allocator.free(msg);
            client.message_string = null;
        }
        try runCopyModeTestCommandArgsWithClient(wme, &client, session, &.{command});
        try std.testing.expect(client.message_string == null);
    }
}

test "window-copy set-mark and jump-to-mark swap cursor with saved mark" {
    initWindowCopyTestGlobals();

    const source_grid = grid.grid_create(6, 6, 0);
    defer grid.grid_free(source_grid);
    const target_grid = grid.grid_create(6, 3, 0);
    defer grid.grid_free(target_grid);
    const source_screen = screen.screen_init(6, 6, 0);
    defer {
        screen.screen_free(source_screen);
        xm.allocator.destroy(source_screen);
    }
    const target_screen = screen.screen_init(6, 3, 0);
    defer {
        screen.screen_free(target_screen);
        xm.allocator.destroy(target_screen);
    }

    var source_window = T.Window{
        .id = 80,
        .name = xm.xstrdup("copy-source-mark"),
        .sx = 6,
        .sy = 6,
        .options = undefined,
    };
    defer xm.allocator.free(source_window.name);
    defer source_window.panes.deinit(xm.allocator);
    defer source_window.last_panes.deinit(xm.allocator);
    defer source_window.winlinks.deinit(xm.allocator);

    var target_window = T.Window{
        .id = 81,
        .name = xm.xstrdup("copy-target-mark"),
        .sx = 6,
        .sy = 3,
        .options = undefined,
    };
    defer xm.allocator.free(target_window.name);
    defer target_window.panes.deinit(xm.allocator);
    defer target_window.last_panes.deinit(xm.allocator);
    defer target_window.winlinks.deinit(xm.allocator);

    var source = T.WindowPane{
        .id = 82,
        .window = &source_window,
        .options = undefined,
        .sx = 6,
        .sy = 6,
        .screen = source_screen,
        .base = .{ .grid = source_grid, .rlower = 5 },
    };
    defer window_mode_runtime.resetModeAll(&source);

    var target = T.WindowPane{
        .id = 83,
        .window = &target_window,
        .options = undefined,
        .sx = 6,
        .sy = 3,
        .screen = target_screen,
        .base = .{ .grid = target_grid, .rlower = 2 },
    };
    defer window_mode_runtime.resetModeAll(&target);

    try source_window.panes.append(xm.allocator, &source);
    try target_window.panes.append(xm.allocator, &target);
    source_window.active = &source;
    target_window.active = &target;

    var row: u32 = 0;
    while (row < 6) : (row += 1) {
        setGridLineText(source.base.grid, row, "line");
        source.base.grid.linedata[row].cellused = 4;
    }

    var args = args_mod.Arguments.init(xm.allocator);
    defer args.deinit();
    const wme = wc.enterMode(&target, &source, &args);

    // Mark initialises to the cursor position on entry.
    try std.testing.expect(wc.modeData(wme).show_mark == false);
    try std.testing.expectEqual(@as(u32, 0), wc.modeData(wme).mark_x);
    try std.testing.expectEqual(wc.absoluteCursorRow(wme), wc.modeData(wme).mark_y);

    // Move cursor away from initial position.
    var nav_args = args_mod.Arguments.init(xm.allocator);
    defer nav_args.deinit();
    try nav_args.values.append(xm.allocator, xm.xstrdup("cursor-right"));
    wc.copyModeCommand(wme, null, undefined, undefined, @ptrCast(&nav_args), null);
    try std.testing.expectEqual(@as(u32, 1), wc.modeData(wme).cx);

    try runCopyModeTestCommand(wme, "cursor-down");
    try std.testing.expectEqual(@as(u32, 1), wc.modeData(wme).cy);

    // Set mark at the new position.
    try runCopyModeTestCommand(wme, "set-mark");
    try std.testing.expect(wc.modeData(wme).show_mark);
    try std.testing.expectEqual(@as(u32, 1), wc.modeData(wme).mark_x);
    try std.testing.expectEqual(@as(u32, 1), wc.modeData(wme).mark_y);

    // Move the cursor further down.
    try runCopyModeTestCommand(wme, "cursor-down");
    try std.testing.expectEqual(@as(u32, 2), wc.modeData(wme).cy);
    try std.testing.expectEqual(@as(u32, 1), wc.modeData(wme).cx);

    // Jump-to-mark swaps: cursor goes to mark, mark takes old cursor position.
    try runCopyModeTestCommand(wme, "jump-to-mark");
    try std.testing.expectEqual(@as(u32, 1), wc.modeData(wme).cx);
    try std.testing.expectEqual(@as(u32, 1), wc.absoluteCursorRow(wme));
    try std.testing.expectEqual(@as(u32, 1), wc.modeData(wme).mark_x);
    try std.testing.expectEqual(@as(u32, 2), wc.modeData(wme).mark_y);

    // Jump again returns to where we were.
    try runCopyModeTestCommand(wme, "jump-to-mark");
    try std.testing.expectEqual(@as(u32, 1), wc.modeData(wme).cx);
    try std.testing.expectEqual(@as(u32, 2), wc.absoluteCursorRow(wme));
    try std.testing.expectEqual(@as(u32, 1), wc.modeData(wme).mark_x);
    try std.testing.expectEqual(@as(u32, 1), wc.modeData(wme).mark_y);
}

test "window-copy history-top and history-bottom bound absolute cursor row" {
    initWindowCopyTestGlobals();

    const source_grid = grid.grid_create(6, 6, 0);
    defer grid.grid_free(source_grid);
    const target_grid = grid.grid_create(6, 3, 0);
    defer grid.grid_free(target_grid);
    const source_screen = screen.screen_init(6, 6, 0);
    defer {
        screen.screen_free(source_screen);
        xm.allocator.destroy(source_screen);
    }
    const target_screen = screen.screen_init(6, 3, 0);
    defer {
        screen.screen_free(target_screen);
        xm.allocator.destroy(target_screen);
    }

    var source_window = T.Window{
        .id = 90,
        .name = xm.xstrdup("copy-hist-src"),
        .sx = 6,
        .sy = 6,
        .options = undefined,
    };
    defer xm.allocator.free(source_window.name);
    defer source_window.panes.deinit(xm.allocator);
    defer source_window.last_panes.deinit(xm.allocator);
    defer source_window.winlinks.deinit(xm.allocator);

    var target_window = T.Window{
        .id = 91,
        .name = xm.xstrdup("copy-hist-tgt"),
        .sx = 6,
        .sy = 3,
        .options = undefined,
    };
    defer xm.allocator.free(target_window.name);
    defer target_window.panes.deinit(xm.allocator);
    defer target_window.last_panes.deinit(xm.allocator);
    defer target_window.winlinks.deinit(xm.allocator);

    var source = T.WindowPane{
        .id = 92,
        .window = &source_window,
        .options = undefined,
        .sx = 6,
        .sy = 6,
        .screen = source_screen,
        .base = .{ .grid = source_grid, .rlower = 5 },
    };
    defer window_mode_runtime.resetModeAll(&source);

    var target = T.WindowPane{
        .id = 93,
        .window = &target_window,
        .options = undefined,
        .sx = 6,
        .sy = 3,
        .screen = target_screen,
        .base = .{ .grid = target_grid, .rlower = 2 },
    };
    defer window_mode_runtime.resetModeAll(&target);

    try source_window.panes.append(xm.allocator, &source);
    try target_window.panes.append(xm.allocator, &target);
    source_window.active = &source;
    target_window.active = &target;

    var r: u32 = 0;
    while (r < 6) : (r += 1) {
        setGridLineText(source.base.grid, r, "row");
        source.base.grid.linedata[r].cellused = 3;
    }

    var args = args_mod.Arguments.init(xm.allocator);
    defer args.deinit();
    const wme = wc.enterMode(&target, &source, &args);

    try runCopyModeTestCommand(wme, "history-bottom");
    try std.testing.expectEqual(@as(u32, 5), wc.absoluteCursorRow(wme));

    try runCopyModeTestCommand(wme, "history-top");
    try std.testing.expectEqual(@as(u32, 0), wc.absoluteCursorRow(wme));
}

test "window-copy start-of-line end-of-line and back-to-indentation" {
    initWindowCopyTestGlobals();

    const source_grid = grid.grid_create(12, 2, 0);
    defer grid.grid_free(source_grid);
    const target_grid = grid.grid_create(12, 2, 0);
    defer grid.grid_free(target_grid);
    const source_screen = screen.screen_init(12, 2, 0);
    defer {
        screen.screen_free(source_screen);
        xm.allocator.destroy(source_screen);
    }
    const target_screen = screen.screen_init(12, 2, 0);
    defer {
        screen.screen_free(target_screen);
        xm.allocator.destroy(target_screen);
    }

    var window_ = T.Window{
        .id = 100,
        .name = xm.xstrdup("copy-line-edges"),
        .sx = 12,
        .sy = 2,
        .options = undefined,
    };
    defer xm.allocator.free(window_.name);
    defer window_.panes.deinit(xm.allocator);
    defer window_.last_panes.deinit(xm.allocator);
    defer window_.winlinks.deinit(xm.allocator);

    var source = T.WindowPane{
        .id = 101,
        .window = &window_,
        .options = undefined,
        .sx = 12,
        .sy = 2,
        .screen = source_screen,
        .base = .{ .grid = source_grid, .rlower = 1 },
    };
    defer window_mode_runtime.resetModeAll(&source);

    var target = T.WindowPane{
        .id = 102,
        .window = &window_,
        .options = undefined,
        .sx = 12,
        .sy = 2,
        .screen = target_screen,
        .base = .{ .grid = target_grid, .rlower = 1 },
    };
    defer window_mode_runtime.resetModeAll(&target);

    try window_.panes.append(xm.allocator, &source);
    try window_.panes.append(xm.allocator, &target);
    window_.active = &target;

    setGridLineText(source.base.grid, 0, "hello world");
    source.base.grid.linedata[0].cellused = 11;
    setGridLineText(source.base.grid, 1, "    body");
    source.base.grid.linedata[1].cellused = 8;

    var args = args_mod.Arguments.init(xm.allocator);
    defer args.deinit();
    const wme = wc.enterMode(&target, &source, &args);

    wc.modeData(wme).cx = 5;
    try runCopyModeTestCommand(wme, "end-of-line");
    try std.testing.expectEqual(@as(u32, 10), wc.modeData(wme).cx);

    try runCopyModeTestCommand(wme, "start-of-line");
    try std.testing.expectEqual(@as(u32, 0), wc.modeData(wme).cx);

    try runCopyModeTestCommand(wme, "cursor-down");
    wc.modeData(wme).cx = 0;
    try runCopyModeTestCommand(wme, "back-to-indentation");
    try std.testing.expectEqual(@as(u32, 4), wc.modeData(wme).cx);
}

test "window-copy begin-selection updates end with cursor motion clear-selection ends drag" {
    const opts_mod = @import("options.zig");

    initWindowCopyTestGlobals();

    opts_mod.global_w_options = opts_mod.options_create(null);
    defer opts_mod.options_free(opts_mod.global_w_options);
    opts_mod.options_default_all(opts_mod.global_w_options, T.OPTIONS_TABLE_WINDOW);

    const source_grid = grid.grid_create(8, 1, 0);
    defer grid.grid_free(source_grid);
    const target_grid = grid.grid_create(8, 1, 0);
    defer grid.grid_free(target_grid);
    const source_screen = screen.screen_init(8, 1, 0);
    defer {
        screen.screen_free(source_screen);
        xm.allocator.destroy(source_screen);
    }
    const target_screen = screen.screen_init(8, 1, 0);
    defer {
        screen.screen_free(target_screen);
        xm.allocator.destroy(target_screen);
    }

    const window_options = opts_mod.options_create(opts_mod.global_w_options);
    defer opts_mod.options_free(window_options);

    var window_ = T.Window{
        .id = 110,
        .name = xm.xstrdup("copy-sel"),
        .sx = 8,
        .sy = 1,
        .options = window_options,
    };
    defer xm.allocator.free(window_.name);
    defer window_.panes.deinit(xm.allocator);
    defer window_.last_panes.deinit(xm.allocator);
    defer window_.winlinks.deinit(xm.allocator);

    var source = T.WindowPane{
        .id = 111,
        .window = &window_,
        .options = undefined,
        .sx = 8,
        .sy = 1,
        .screen = source_screen,
        .base = .{ .grid = source_grid, .rlower = 0 },
    };
    defer window_mode_runtime.resetModeAll(&source);

    var target = T.WindowPane{
        .id = 112,
        .window = &window_,
        .options = undefined,
        .sx = 8,
        .sy = 1,
        .screen = target_screen,
        .base = .{ .grid = target_grid, .rlower = 0 },
    };
    defer window_mode_runtime.resetModeAll(&target);

    try window_.panes.append(xm.allocator, &source);
    try window_.panes.append(xm.allocator, &target);
    window_.active = &target;

    setGridLineText(source.base.grid, 0, "abcdefgh");
    source.base.grid.linedata[0].cellused = 8;

    var args = args_mod.Arguments.init(xm.allocator);
    defer args.deinit();
    const wme = wc.enterMode(&target, &source, &args);

    try runCopyModeTestCommand(wme, "begin-selection");
    try std.testing.expectEqual(&wc.window_copy_mode, wme.mode);
    try std.testing.expectEqual(wc.CursorDrag.endsel, wc.modeData(wme).cursordrag);
    try std.testing.expectEqual(@as(u32, 0), wc.modeData(wme).selx);
    try std.testing.expectEqual(@as(u32, 0), wc.modeData(wme).endselx);

    try runCopyModeTestCommand(wme, "cursor-right");
    try runCopyModeTestCommand(wme, "cursor-right");
    _ = wc.window_copy_update_selection(wme, false, false);
    try std.testing.expect(wc.modeData(wme).endselx != wc.modeData(wme).selx);

    try runCopyModeTestCommand(wme, "clear-selection");
    try std.testing.expectEqual(wc.CursorDrag.none, wc.modeData(wme).cursordrag);
}

test "window-copy rectangle-toggle flips rectflag" {
    initWindowCopyTestGlobals();

    const source_grid = grid.grid_create(4, 2, 0);
    defer grid.grid_free(source_grid);
    const target_grid = grid.grid_create(4, 2, 0);
    defer grid.grid_free(target_grid);
    const source_screen = screen.screen_init(4, 2, 0);
    defer {
        screen.screen_free(source_screen);
        xm.allocator.destroy(source_screen);
    }
    const target_screen = screen.screen_init(4, 2, 0);
    defer {
        screen.screen_free(target_screen);
        xm.allocator.destroy(target_screen);
    }

    var window_ = T.Window{
        .id = 120,
        .name = xm.xstrdup("copy-rect"),
        .sx = 4,
        .sy = 2,
        .options = undefined,
    };
    defer xm.allocator.free(window_.name);
    defer window_.panes.deinit(xm.allocator);
    defer window_.last_panes.deinit(xm.allocator);
    defer window_.winlinks.deinit(xm.allocator);

    var source = T.WindowPane{
        .id = 121,
        .window = &window_,
        .options = undefined,
        .sx = 4,
        .sy = 2,
        .screen = source_screen,
        .base = .{ .grid = source_grid, .rlower = 1 },
    };
    defer window_mode_runtime.resetModeAll(&source);

    var target = T.WindowPane{
        .id = 122,
        .window = &window_,
        .options = undefined,
        .sx = 4,
        .sy = 2,
        .screen = target_screen,
        .base = .{ .grid = target_grid, .rlower = 1 },
    };
    defer window_mode_runtime.resetModeAll(&target);

    try window_.panes.append(xm.allocator, &source);
    try window_.panes.append(xm.allocator, &target);
    window_.active = &target;

    setGridLineText(source.base.grid, 0, "abcd");
    setGridLineText(source.base.grid, 1, "abcd");

    var args = args_mod.Arguments.init(xm.allocator);
    defer args.deinit();
    const wme = wc.enterMode(&target, &source, &args);

    try std.testing.expect(!wc.modeData(wme).rectflag);
    try runCopyModeTestCommand(wme, "rectangle-toggle");
    try std.testing.expect(wc.modeData(wme).rectflag);
    try runCopyModeTestCommand(wme, "rectangle-off");
    try std.testing.expect(!wc.modeData(wme).rectflag);
    try runCopyModeTestCommand(wme, "rectangle-on");
    try std.testing.expect(wc.modeData(wme).rectflag);
}

test "window-copy next-paragraph and previous-paragraph cross blank lines" {
    initWindowCopyTestGlobals();

    const source_grid = grid.grid_create(6, 5, 0);
    defer grid.grid_free(source_grid);
    const target_grid = grid.grid_create(6, 3, 0);
    defer grid.grid_free(target_grid);
    const source_screen = screen.screen_init(6, 5, 0);
    defer {
        screen.screen_free(source_screen);
        xm.allocator.destroy(source_screen);
    }
    const target_screen = screen.screen_init(6, 3, 0);
    defer {
        screen.screen_free(target_screen);
        xm.allocator.destroy(target_screen);
    }

    var source_window = T.Window{
        .id = 130,
        .name = xm.xstrdup("copy-para-src"),
        .sx = 6,
        .sy = 5,
        .options = undefined,
    };
    defer xm.allocator.free(source_window.name);
    defer source_window.panes.deinit(xm.allocator);
    defer source_window.last_panes.deinit(xm.allocator);
    defer source_window.winlinks.deinit(xm.allocator);

    var target_window = T.Window{
        .id = 131,
        .name = xm.xstrdup("copy-para-tgt"),
        .sx = 6,
        .sy = 3,
        .options = undefined,
    };
    defer xm.allocator.free(target_window.name);
    defer target_window.panes.deinit(xm.allocator);
    defer target_window.last_panes.deinit(xm.allocator);
    defer target_window.winlinks.deinit(xm.allocator);

    var source = T.WindowPane{
        .id = 132,
        .window = &source_window,
        .options = undefined,
        .sx = 6,
        .sy = 5,
        .screen = source_screen,
        .base = .{ .grid = source_grid, .rlower = 4 },
    };
    defer window_mode_runtime.resetModeAll(&source);

    var target = T.WindowPane{
        .id = 133,
        .window = &target_window,
        .options = undefined,
        .sx = 6,
        .sy = 3,
        .screen = target_screen,
        .base = .{ .grid = target_grid, .rlower = 2 },
    };
    defer window_mode_runtime.resetModeAll(&target);

    try source_window.panes.append(xm.allocator, &source);
    try target_window.panes.append(xm.allocator, &target);
    source_window.active = &source;
    target_window.active = &target;

    setGridLineText(source.base.grid, 0, "block1");
    source.base.grid.linedata[0].cellused = 5;
    source.base.grid.linedata[1].cellused = 0;
    setGridLineText(source.base.grid, 2, "blk2");
    source.base.grid.linedata[2].cellused = 4;
    source.base.grid.linedata[3].cellused = 0;
    source.base.grid.linedata[4].cellused = 0;

    var args = args_mod.Arguments.init(xm.allocator);
    defer args.deinit();
    const wme = wc.enterMode(&target, &source, &args);

    try runCopyModeTestCommand(wme, "next-paragraph");
    try std.testing.expectEqual(@as(u32, 1), wc.absoluteCursorRow(wme));

    try runCopyModeTestCommand(wme, "next-paragraph");
    try std.testing.expectEqual(@as(u32, 3), wc.absoluteCursorRow(wme));

    try runCopyModeTestCommand(wme, "previous-paragraph");
    try std.testing.expectEqual(@as(u32, 1), wc.absoluteCursorRow(wme));

    try runCopyModeTestCommand(wme, "previous-paragraph");
    try std.testing.expectEqual(@as(u32, 0), wc.absoluteCursorRow(wme));
}

test "window-copy search-forward jumps to matching line" {
    const opts_mod = @import("options.zig");

    initWindowCopyTestGlobals();

    opts_mod.global_w_options = opts_mod.options_create(null);
    defer opts_mod.options_free(opts_mod.global_w_options);
    opts_mod.options_default_all(opts_mod.global_w_options, T.OPTIONS_TABLE_WINDOW);

    const source_grid = grid.grid_create(8, 4, 0);
    defer grid.grid_free(source_grid);
    const target_grid = grid.grid_create(8, 4, 0);
    defer grid.grid_free(target_grid);
    const source_screen = screen.screen_init(8, 4, 0);
    defer {
        screen.screen_free(source_screen);
        xm.allocator.destroy(source_screen);
    }
    const target_screen = screen.screen_init(8, 4, 0);
    defer {
        screen.screen_free(target_screen);
        xm.allocator.destroy(target_screen);
    }

    const source_window_options = opts_mod.options_create(opts_mod.global_w_options);
    defer opts_mod.options_free(source_window_options);
    const target_window_options = opts_mod.options_create(opts_mod.global_w_options);
    defer opts_mod.options_free(target_window_options);

    var source_window = T.Window{
        .id = 2001,
        .name = xm.xstrdup("copy-search-src"),
        .sx = 8,
        .sy = 4,
        .options = source_window_options,
    };
    defer xm.allocator.free(source_window.name);
    defer source_window.panes.deinit(xm.allocator);
    defer source_window.last_panes.deinit(xm.allocator);
    defer source_window.winlinks.deinit(xm.allocator);

    var target_window = T.Window{
        .id = 2002,
        .name = xm.xstrdup("copy-search-tgt"),
        .sx = 8,
        .sy = 4,
        .options = target_window_options,
    };
    defer xm.allocator.free(target_window.name);
    defer target_window.panes.deinit(xm.allocator);
    defer target_window.last_panes.deinit(xm.allocator);
    defer target_window.winlinks.deinit(xm.allocator);

    var source = T.WindowPane{
        .id = 2003,
        .window = &source_window,
        .options = undefined,
        .sx = 8,
        .sy = 4,
        .screen = source_screen,
        .base = .{ .grid = source_grid, .rlower = 3 },
    };
    defer window_mode_runtime.resetModeAll(&source);

    var target = T.WindowPane{
        .id = 2004,
        .window = &target_window,
        .options = undefined,
        .sx = 8,
        .sy = 4,
        .screen = target_screen,
        .base = .{ .grid = target_grid, .rlower = 3 },
    };
    defer window_mode_runtime.resetModeAll(&target);

    try source_window.panes.append(xm.allocator, &source);
    try target_window.panes.append(xm.allocator, &target);
    source_window.active = &source;
    target_window.active = &target;

    setGridLineText(source.base.grid, 0, "aaa");
    setGridLineText(source.base.grid, 1, "needle");
    setGridLineText(source.base.grid, 2, "bbb");
    setGridLineText(source.base.grid, 3, "ccc");

    var args = args_mod.Arguments.init(xm.allocator);
    defer args.deinit();
    const wme = wc.enterMode(&target, &source, &args);

    try runCopyModeTestCommandArgs(wme, null, &.{ "search-forward", "needle" });
    try std.testing.expectEqual(@as(u32, 1), wc.absoluteCursorRow(wme));
}

test "window-copy regex search uses regex semantics and emacs cursor placement" {
    const opts_mod = @import("options.zig");

    initWindowCopyTestGlobals();

    opts_mod.global_w_options = opts_mod.options_create(null);
    defer opts_mod.options_free(opts_mod.global_w_options);
    opts_mod.options_default_all(opts_mod.global_w_options, T.OPTIONS_TABLE_WINDOW);

    const source_grid = grid.grid_create(12, 4, 0);
    defer grid.grid_free(source_grid);
    const target_grid = grid.grid_create(12, 4, 0);
    defer grid.grid_free(target_grid);
    const source_screen = screen.screen_init(12, 4, 0);
    defer {
        screen.screen_free(source_screen);
        xm.allocator.destroy(source_screen);
    }
    const target_screen = screen.screen_init(12, 4, 0);
    defer {
        screen.screen_free(target_screen);
        xm.allocator.destroy(target_screen);
    }

    var source_window = T.Window{
        .id = 2051,
        .name = xm.xstrdup("copy-regex-src"),
        .sx = 12,
        .sy = 4,
        .options = opts_mod.options_create(opts_mod.global_w_options),
    };
    defer xm.allocator.free(source_window.name);
    defer opts_mod.options_free(source_window.options);
    defer source_window.panes.deinit(xm.allocator);
    defer source_window.last_panes.deinit(xm.allocator);
    defer source_window.winlinks.deinit(xm.allocator);

    var target_window = T.Window{
        .id = 2052,
        .name = xm.xstrdup("copy-regex-tgt"),
        .sx = 12,
        .sy = 4,
        .options = opts_mod.options_create(opts_mod.global_w_options),
    };
    defer xm.allocator.free(target_window.name);
    defer opts_mod.options_free(target_window.options);
    defer target_window.panes.deinit(xm.allocator);
    defer target_window.last_panes.deinit(xm.allocator);
    defer target_window.winlinks.deinit(xm.allocator);

    var source = T.WindowPane{
        .id = 2053,
        .window = &source_window,
        .options = undefined,
        .sx = 12,
        .sy = 4,
        .screen = source_screen,
        .base = .{ .grid = source_grid, .rlower = 3 },
    };
    defer window_mode_runtime.resetModeAll(&source);

    var target = T.WindowPane{
        .id = 2054,
        .window = &target_window,
        .options = undefined,
        .sx = 12,
        .sy = 4,
        .screen = target_screen,
        .base = .{ .grid = target_grid, .rlower = 3 },
    };
    defer window_mode_runtime.resetModeAll(&target);

    try source_window.panes.append(xm.allocator, &source);
    try target_window.panes.append(xm.allocator, &target);
    source_window.active = &source;
    target_window.active = &target;

    setGridLineText(source.base.grid, 0, "nope");
    setGridLineText(source.base.grid, 1, "needle");
    setGridLineText(source.base.grid, 2, "still");
    setGridLineText(source.base.grid, 3, "done");

    var args = args_mod.Arguments.init(xm.allocator);
    defer args.deinit();
    const wme = wc.enterMode(&target, &source, &args);

    try runCopyModeTestCommandArgs(wme, null, &.{ "search-forward-text", "n..d" });
    try std.testing.expectEqual(@as(u32, 0), wc.absoluteCursorRow(wme));
    try std.testing.expectEqual(@as(u32, 0), wc.modeData(wme).cx);

    try runCopyModeTestCommandArgs(wme, null, &.{ "search-forward", "n..d" });
    try std.testing.expectEqual(@as(u32, 1), wc.absoluteCursorRow(wme));
    try std.testing.expectEqual(@as(u32, 4), wc.modeData(wme).cx);

    wc.window_copy_scroll_to(wme, 0, 3, true);
    wc.modeData(wme).cx = 3;
    try runCopyModeTestCommandArgs(wme, null, &.{ "search-backward", "n..d" });
    try std.testing.expectEqual(@as(u32, 1), wc.absoluteCursorRow(wme));
    try std.testing.expectEqual(@as(u32, 0), wc.modeData(wme).cx);
}

test "window-copy emacs-only clear commands clear active search marks" {
    const opts_mod = @import("options.zig");

    initWindowCopyTestGlobals();

    opts_mod.global_w_options = opts_mod.options_create(null);
    defer opts_mod.options_free(opts_mod.global_w_options);
    opts_mod.options_default_all(opts_mod.global_w_options, T.OPTIONS_TABLE_WINDOW);

    const source_grid = grid.grid_create(12, 4, 0);
    defer grid.grid_free(source_grid);
    const target_grid = grid.grid_create(12, 4, 0);
    defer grid.grid_free(target_grid);
    const source_screen = screen.screen_init(12, 4, 0);
    defer {
        screen.screen_free(source_screen);
        xm.allocator.destroy(source_screen);
    }
    const target_screen = screen.screen_init(12, 4, 0);
    defer {
        screen.screen_free(target_screen);
        xm.allocator.destroy(target_screen);
    }

    var source_window = T.Window{
        .id = 2059,
        .name = xm.xstrdup("copy-clear-emacs-src"),
        .sx = 12,
        .sy = 4,
        .options = opts_mod.options_create(opts_mod.global_w_options),
    };
    defer xm.allocator.free(source_window.name);
    defer opts_mod.options_free(source_window.options);
    defer source_window.panes.deinit(xm.allocator);
    defer source_window.last_panes.deinit(xm.allocator);
    defer source_window.winlinks.deinit(xm.allocator);

    var target_window = T.Window{
        .id = 2060,
        .name = xm.xstrdup("copy-clear-emacs-tgt"),
        .sx = 12,
        .sy = 4,
        .options = opts_mod.options_create(opts_mod.global_w_options),
    };
    defer xm.allocator.free(target_window.name);
    defer opts_mod.options_free(target_window.options);
    defer target_window.panes.deinit(xm.allocator);
    defer target_window.last_panes.deinit(xm.allocator);
    defer target_window.winlinks.deinit(xm.allocator);

    var source = T.WindowPane{
        .id = 2061,
        .window = &source_window,
        .options = undefined,
        .sx = 12,
        .sy = 4,
        .screen = source_screen,
        .base = .{ .grid = source_grid, .rlower = 3 },
    };
    defer window_mode_runtime.resetModeAll(&source);

    var target = T.WindowPane{
        .id = 2062,
        .window = &target_window,
        .options = undefined,
        .sx = 12,
        .sy = 4,
        .screen = target_screen,
        .base = .{ .grid = target_grid, .rlower = 3 },
    };
    defer window_mode_runtime.resetModeAll(&target);

    try source_window.panes.append(xm.allocator, &source);
    try target_window.panes.append(xm.allocator, &target);
    source_window.active = &source;
    target_window.active = &target;

    setGridLineText(source.base.grid, 0, "needle one");
    setGridLineText(source.base.grid, 1, "needle two");

    var args = args_mod.Arguments.init(xm.allocator);
    defer args.deinit();
    const wme = wc.enterMode(&target, &source, &args);

    try runCopyModeTestCommandArgs(wme, null, &.{ "search-forward", "needle" });
    try std.testing.expect(wc.modeData(wme).searchmark != null);

    try runCopyModeTestCommand(wme, "search-again");
    try std.testing.expect(wc.modeData(wme).searchmark != null);

    try runCopyModeTestCommand(wme, "cursor-right");
    try std.testing.expect(wc.modeData(wme).searchmark == null);
    try std.testing.expectEqual(std.math.maxInt(u32), wc.modeData(wme).searchx);
    try std.testing.expectEqual(std.math.maxInt(u32), wc.modeData(wme).searchy);
    try std.testing.expectEqual(std.math.maxInt(u32), wc.modeData(wme).searcho);
}

test "window-copy vi keeps emacs-only marks and clears always-clear marks" {
    const opts_mod = @import("options.zig");

    initWindowCopyTestGlobals();

    opts_mod.global_w_options = opts_mod.options_create(null);
    defer opts_mod.options_free(opts_mod.global_w_options);
    opts_mod.options_default_all(opts_mod.global_w_options, T.OPTIONS_TABLE_WINDOW);

    const source_grid = grid.grid_create(12, 4, 0);
    defer grid.grid_free(source_grid);
    const target_grid = grid.grid_create(12, 4, 0);
    defer grid.grid_free(target_grid);
    const source_screen = screen.screen_init(12, 4, 0);
    defer {
        screen.screen_free(source_screen);
        xm.allocator.destroy(source_screen);
    }
    const target_screen = screen.screen_init(12, 4, 0);
    defer {
        screen.screen_free(target_screen);
        xm.allocator.destroy(target_screen);
    }

    var source_window = T.Window{
        .id = 2063,
        .name = xm.xstrdup("copy-clear-vi-src"),
        .sx = 12,
        .sy = 4,
        .options = opts_mod.options_create(opts_mod.global_w_options),
    };
    defer xm.allocator.free(source_window.name);
    defer opts_mod.options_free(source_window.options);
    defer source_window.panes.deinit(xm.allocator);
    defer source_window.last_panes.deinit(xm.allocator);
    defer source_window.winlinks.deinit(xm.allocator);
    opts_mod.options_set_number(source_window.options, "mode-keys", T.MODEKEY_VI);

    var target_window = T.Window{
        .id = 2064,
        .name = xm.xstrdup("copy-clear-vi-tgt"),
        .sx = 12,
        .sy = 4,
        .options = opts_mod.options_create(opts_mod.global_w_options),
    };
    defer xm.allocator.free(target_window.name);
    defer opts_mod.options_free(target_window.options);
    defer target_window.panes.deinit(xm.allocator);
    defer target_window.last_panes.deinit(xm.allocator);
    defer target_window.winlinks.deinit(xm.allocator);
    opts_mod.options_set_number(target_window.options, "mode-keys", T.MODEKEY_VI);

    var source = T.WindowPane{
        .id = 2065,
        .window = &source_window,
        .options = undefined,
        .sx = 12,
        .sy = 4,
        .screen = source_screen,
        .base = .{ .grid = source_grid, .rlower = 3 },
    };
    defer window_mode_runtime.resetModeAll(&source);

    var target = T.WindowPane{
        .id = 2066,
        .window = &target_window,
        .options = undefined,
        .sx = 12,
        .sy = 4,
        .screen = target_screen,
        .base = .{ .grid = target_grid, .rlower = 3 },
    };
    defer window_mode_runtime.resetModeAll(&target);

    try source_window.panes.append(xm.allocator, &source);
    try target_window.panes.append(xm.allocator, &target);
    source_window.active = &source;
    target_window.active = &target;

    setGridLineText(source.base.grid, 0, "needle one");
    setGridLineText(source.base.grid, 1, "needle two");

    var args = args_mod.Arguments.init(xm.allocator);
    defer args.deinit();
    const wme = wc.enterMode(&target, &source, &args);

    try runCopyModeTestCommandArgs(wme, null, &.{ "search-forward", "needle" });
    try std.testing.expect(wc.modeData(wme).searchmark != null);

    try runCopyModeTestCommand(wme, "cursor-right");
    try std.testing.expect(wc.modeData(wme).searchmark != null);

    try runCopyModeTestCommand(wme, "set-mark");
    try std.testing.expect(wc.modeData(wme).searchmark == null);
    try std.testing.expectEqual(std.math.maxInt(u32), wc.modeData(wme).searchx);
    try std.testing.expectEqual(std.math.maxInt(u32), wc.modeData(wme).searchy);
    try std.testing.expectEqual(std.math.maxInt(u32), wc.modeData(wme).searcho);
}

test "window-copy incremental search restores origin when the text changes" {
    const opts_mod = @import("options.zig");

    initWindowCopyTestGlobals();

    opts_mod.global_w_options = opts_mod.options_create(null);
    defer opts_mod.options_free(opts_mod.global_w_options);
    opts_mod.options_default_all(opts_mod.global_w_options, T.OPTIONS_TABLE_WINDOW);

    const source_grid = grid.grid_create(12, 4, 0);
    defer grid.grid_free(source_grid);
    const target_grid = grid.grid_create(12, 4, 0);
    defer grid.grid_free(target_grid);
    const source_screen = screen.screen_init(12, 4, 0);
    defer {
        screen.screen_free(source_screen);
        xm.allocator.destroy(source_screen);
    }
    const target_screen = screen.screen_init(12, 4, 0);
    defer {
        screen.screen_free(target_screen);
        xm.allocator.destroy(target_screen);
    }

    var source_window = T.Window{
        .id = 2055,
        .name = xm.xstrdup("copy-incremental-src"),
        .sx = 12,
        .sy = 4,
        .options = opts_mod.options_create(opts_mod.global_w_options),
    };
    defer xm.allocator.free(source_window.name);
    defer opts_mod.options_free(source_window.options);
    defer source_window.panes.deinit(xm.allocator);
    defer source_window.last_panes.deinit(xm.allocator);
    defer source_window.winlinks.deinit(xm.allocator);
    opts_mod.options_set_number(source_window.options, "wrap-search", 0);

    var target_window = T.Window{
        .id = 2056,
        .name = xm.xstrdup("copy-incremental-tgt"),
        .sx = 12,
        .sy = 4,
        .options = opts_mod.options_create(opts_mod.global_w_options),
    };
    defer xm.allocator.free(target_window.name);
    defer opts_mod.options_free(target_window.options);
    defer target_window.panes.deinit(xm.allocator);
    defer target_window.last_panes.deinit(xm.allocator);
    defer target_window.winlinks.deinit(xm.allocator);
    opts_mod.options_set_number(target_window.options, "wrap-search", 0);

    var source = T.WindowPane{
        .id = 2057,
        .window = &source_window,
        .options = undefined,
        .sx = 12,
        .sy = 4,
        .screen = source_screen,
        .base = .{ .grid = source_grid, .rlower = 3 },
    };
    defer window_mode_runtime.resetModeAll(&source);

    var target = T.WindowPane{
        .id = 2058,
        .window = &target_window,
        .options = undefined,
        .sx = 12,
        .sy = 4,
        .screen = target_screen,
        .base = .{ .grid = target_grid, .rlower = 3 },
    };
    defer window_mode_runtime.resetModeAll(&target);

    try source_window.panes.append(xm.allocator, &source);
    try target_window.panes.append(xm.allocator, &target);
    source_window.active = &source;
    target_window.active = &target;

    setGridLineText(source.base.grid, 0, "alpha");
    setGridLineText(source.base.grid, 1, "bravo");
    setGridLineText(source.base.grid, 2, "beta");
    setGridLineText(source.base.grid, 3, "omega");

    var args = args_mod.Arguments.init(xm.allocator);
    defer args.deinit();
    const wme = wc.enterMode(&target, &source, &args);

    try runCopyModeTestCommandArgs(wme, null, &.{ "search-forward-incremental", "=be" });
    try std.testing.expectEqual(@as(u32, 2), wc.absoluteCursorRow(wme));
    try std.testing.expectEqual(@as(u32, 2), wc.modeData(wme).cx);
    try std.testing.expect(wc.modeData(wme).searchmark != null);

    try runCopyModeTestCommandArgs(wme, null, &.{ "search-forward-incremental", "=br" });
    try std.testing.expectEqual(@as(u32, 1), wc.absoluteCursorRow(wme));
    try std.testing.expectEqual(@as(u32, 2), wc.modeData(wme).cx);

    try runCopyModeTestCommandArgs(wme, null, &.{ "search-forward-incremental", "=" });
    try std.testing.expectEqual(@as(u32, 0), wc.absoluteCursorRow(wme));
    try std.testing.expectEqual(@as(u32, 0), wc.modeData(wme).cx);
    try std.testing.expect(wc.modeData(wme).searchmark == null);
}

test "window-copy public match helpers expose the current search hit" {
    const opts_mod = @import("options.zig");

    initWindowCopyTestGlobals();

    opts_mod.global_w_options = opts_mod.options_create(null);
    defer opts_mod.options_free(opts_mod.global_w_options);
    opts_mod.options_default_all(opts_mod.global_w_options, T.OPTIONS_TABLE_WINDOW);

    const source_grid = grid.grid_create(8, 4, 0);
    defer grid.grid_free(source_grid);
    const target_grid = grid.grid_create(8, 4, 0);
    defer grid.grid_free(target_grid);
    const source_screen = screen.screen_init(8, 4, 0);
    defer {
        screen.screen_free(source_screen);
        xm.allocator.destroy(source_screen);
    }
    const target_screen = screen.screen_init(8, 4, 0);
    defer {
        screen.screen_free(target_screen);
        xm.allocator.destroy(target_screen);
    }

    var source_window = T.Window{
        .id = 2101,
        .name = xm.xstrdup("copy-match-src"),
        .sx = 8,
        .sy = 4,
        .options = opts_mod.options_create(opts_mod.global_w_options),
    };
    defer xm.allocator.free(source_window.name);
    defer opts_mod.options_free(source_window.options);
    defer source_window.panes.deinit(xm.allocator);
    defer source_window.last_panes.deinit(xm.allocator);
    defer source_window.winlinks.deinit(xm.allocator);

    var target_window = T.Window{
        .id = 2102,
        .name = xm.xstrdup("copy-match-tgt"),
        .sx = 8,
        .sy = 4,
        .options = opts_mod.options_create(opts_mod.global_w_options),
    };
    defer xm.allocator.free(target_window.name);
    defer opts_mod.options_free(target_window.options);
    defer target_window.panes.deinit(xm.allocator);
    defer target_window.last_panes.deinit(xm.allocator);
    defer target_window.winlinks.deinit(xm.allocator);

    var source = T.WindowPane{
        .id = 2103,
        .window = &source_window,
        .options = undefined,
        .sx = 8,
        .sy = 4,
        .screen = source_screen,
        .base = .{ .grid = source_grid, .rlower = 3 },
    };
    defer window_mode_runtime.resetModeAll(&source);

    var target = T.WindowPane{
        .id = 2104,
        .window = &target_window,
        .options = undefined,
        .sx = 8,
        .sy = 4,
        .screen = target_screen,
        .base = .{ .grid = target_grid, .rlower = 3 },
    };
    defer window_mode_runtime.resetModeAll(&target);

    try source_window.panes.append(xm.allocator, &source);
    try target_window.panes.append(xm.allocator, &target);
    source_window.active = &source;
    target_window.active = &target;

    setGridLineText(source.base.grid, 0, "needle");

    var args = args_mod.Arguments.init(xm.allocator);
    defer args.deinit();
    const wme = wc.enterMode(&target, &source, &args);

    try runCopyModeTestCommandArgs(wme, null, &.{ "search-forward", "needle" });
    const matched = wc.window_copy_match_at_cursor(wc.modeData(wme)) orelse return error.TestUnexpectedResult;
    defer xm.allocator.free(matched);
    try std.testing.expectEqualStrings("needle", matched);

    var at: u32 = undefined;
    try std.testing.expect(wc.window_copy_search_mark_at(wc.modeData(wme), wc.modeData(wme).cx, wc.absoluteCursorRow(wme), &at));
    var start: u32 = 0;
    var end: u32 = 0;
    wc.window_copy_match_start_end(wc.modeData(wme), at, &start, &end);
    try std.testing.expect(end >= start);
}

test "window-copy built-in command aliases no longer fall into unsupported-command" {
    initWindowCopyTestGlobals();

    const source_grid = grid.grid_create(8, 4, 0);
    defer grid.grid_free(source_grid);
    const target_grid = grid.grid_create(8, 4, 0);
    defer grid.grid_free(target_grid);
    const source_screen = screen.screen_init(8, 4, 0);
    defer {
        screen.screen_free(source_screen);
        xm.allocator.destroy(source_screen);
    }
    const target_screen = screen.screen_init(8, 4, 0);
    defer {
        screen.screen_free(target_screen);
        xm.allocator.destroy(target_screen);
    }

    var source_window = T.Window{
        .id = 2201,
        .name = xm.xstrdup("copy-alias-src"),
        .sx = 8,
        .sy = 4,
        .options = undefined,
    };
    defer xm.allocator.free(source_window.name);
    defer source_window.panes.deinit(xm.allocator);
    defer source_window.last_panes.deinit(xm.allocator);
    defer source_window.winlinks.deinit(xm.allocator);

    var target_window = T.Window{
        .id = 2202,
        .name = xm.xstrdup("copy-alias-tgt"),
        .sx = 8,
        .sy = 4,
        .options = undefined,
    };
    defer xm.allocator.free(target_window.name);
    defer target_window.panes.deinit(xm.allocator);
    defer target_window.last_panes.deinit(xm.allocator);
    defer target_window.winlinks.deinit(xm.allocator);

    var source = T.WindowPane{
        .id = 2203,
        .window = &source_window,
        .options = undefined,
        .sx = 8,
        .sy = 4,
        .screen = source_screen,
        .base = .{ .grid = source_grid, .rlower = 3 },
    };
    defer window_mode_runtime.resetModeAll(&source);

    var target = T.WindowPane{
        .id = 2204,
        .window = &target_window,
        .options = undefined,
        .sx = 8,
        .sy = 4,
        .screen = target_screen,
        .base = .{ .grid = target_grid, .rlower = 3 },
    };
    defer window_mode_runtime.resetModeAll(&target);

    try source_window.panes.append(xm.allocator, &source);
    try target_window.panes.append(xm.allocator, &target);
    source_window.active = &source;
    target_window.active = &target;

    setGridLineText(source.base.grid, 0, "alpha");

    var args = args_mod.Arguments.init(xm.allocator);
    defer args.deinit();
    const wme = wc.enterMode(&target, &source, &args);

    var env = T.Environ.init(xm.allocator);
    defer env.deinit();
    var client = T.Client{
        .name = "copy-alias-client",
        .environ = &env,
        .tty = undefined,
        .status = .{},
        .flags = T.CLIENT_ATTACHED,
    };
    client.tty = .{ .client = &client };
    defer if (client.message_string) |msg| xm.allocator.free(msg);

    var vertical_args = args_mod.Arguments.init(xm.allocator);
    defer vertical_args.deinit();
    try vertical_args.values.append(xm.allocator, xm.xstrdup("cursor-centre-vertical"));
    wc.copyModeCommand(wme, &client, undefined, undefined, @ptrCast(&vertical_args), null);

    var horizontal_args = args_mod.Arguments.init(xm.allocator);
    defer horizontal_args.deinit();
    try horizontal_args.values.append(xm.allocator, xm.xstrdup("cursor-centre-horizontal"));
    wc.copyModeCommand(wme, &client, undefined, undefined, @ptrCast(&horizontal_args), null);

    // The built-in alias commands above should complete without surfacing the unsupported status message.
    try std.testing.expect(client.message_string == null);
}

test "window-copy cursor movement grows an active keyboard selection" {
    const opts_mod = @import("options.zig");

    initWindowCopyTestGlobals();

    opts_mod.global_w_options = opts_mod.options_create(null);
    defer opts_mod.options_free(opts_mod.global_w_options);
    opts_mod.options_default_all(opts_mod.global_w_options, T.OPTIONS_TABLE_WINDOW);

    const source_grid = grid.grid_create(8, 1, 0);
    defer grid.grid_free(source_grid);
    const target_grid = grid.grid_create(8, 1, 0);
    defer grid.grid_free(target_grid);
    const source_screen = screen.screen_init(8, 1, 0);
    defer {
        screen.screen_free(source_screen);
        xm.allocator.destroy(source_screen);
    }
    const target_screen = screen.screen_init(8, 1, 0);
    defer {
        screen.screen_free(target_screen);
        xm.allocator.destroy(target_screen);
    }

    var source_window = T.Window{
        .id = 2111,
        .name = xm.xstrdup("copy-selection-grow-src"),
        .sx = 8,
        .sy = 1,
        .options = opts_mod.options_create(opts_mod.global_w_options),
    };
    defer xm.allocator.free(source_window.name);
    defer opts_mod.options_free(source_window.options);
    defer source_window.panes.deinit(xm.allocator);
    defer source_window.last_panes.deinit(xm.allocator);
    defer source_window.winlinks.deinit(xm.allocator);

    var target_window = T.Window{
        .id = 2112,
        .name = xm.xstrdup("copy-selection-grow-tgt"),
        .sx = 8,
        .sy = 1,
        .options = opts_mod.options_create(opts_mod.global_w_options),
    };
    defer xm.allocator.free(target_window.name);
    defer opts_mod.options_free(target_window.options);
    defer target_window.panes.deinit(xm.allocator);
    defer target_window.last_panes.deinit(xm.allocator);
    defer target_window.winlinks.deinit(xm.allocator);

    var source = T.WindowPane{
        .id = 2113,
        .window = &source_window,
        .options = undefined,
        .sx = 8,
        .sy = 1,
        .screen = source_screen,
        .base = .{ .grid = source_grid, .rlower = 0 },
    };
    defer window_mode_runtime.resetModeAll(&source);

    var target = T.WindowPane{
        .id = 2114,
        .window = &target_window,
        .options = undefined,
        .sx = 8,
        .sy = 1,
        .screen = target_screen,
        .base = .{ .grid = target_grid, .rlower = 0 },
    };
    defer window_mode_runtime.resetModeAll(&target);

    try source_window.panes.append(xm.allocator, &source);
    try target_window.panes.append(xm.allocator, &target);
    source_window.active = &source;
    target_window.active = &target;

    setGridLineText(source.base.grid, 0, "abcd");

    var args = args_mod.Arguments.init(xm.allocator);
    defer args.deinit();
    const wme = wc.enterMode(&target, &source, &args);

    try runCopyModeTestCommand(wme, "begin-selection");
    try runCopyModeTestCommand(wme, "cursor-right");

    const selected = wc.window_copy_get_selection(wme, null) orelse return error.TestUnexpectedResult;
    defer xm.allocator.free(selected);
    try std.testing.expectEqualStrings("a", selected);
}

test "window-copy mouse select-word uses the clicked position" {
    const env_mod = @import("environ.zig");
    const opts_mod = @import("options.zig");
    const sess = @import("session.zig");

    initWindowCopyTestGlobals();

    opts_mod.global_options = opts_mod.options_create(null);
    defer opts_mod.options_free(opts_mod.global_options);
    opts_mod.global_s_options = opts_mod.options_create(null);
    defer opts_mod.options_free(opts_mod.global_s_options);
    opts_mod.global_w_options = opts_mod.options_create(null);
    defer opts_mod.options_free(opts_mod.global_w_options);
    opts_mod.options_default_all(opts_mod.global_options, T.OPTIONS_TABLE_SERVER);
    opts_mod.options_default_all(opts_mod.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts_mod.options_default_all(opts_mod.global_w_options, T.OPTIONS_TABLE_WINDOW);

    env_mod.global_environ = env_mod.environ_create();
    defer env_mod.environ_free(env_mod.global_environ);

    const session = sess.session_create(null, "copy-mouse-select-word", "/", env_mod.environ_create(), opts_mod.options_create(opts_mod.global_s_options), null);
    defer if (sess.session_find("copy-mouse-select-word") != null) sess.session_destroy(session, false, "test");

    const source_grid = grid.grid_create(12, 1, 0);
    defer grid.grid_free(source_grid);
    const target_grid = grid.grid_create(12, 1, 0);
    defer grid.grid_free(target_grid);
    const source_screen = screen.screen_init(12, 1, 0);
    defer {
        screen.screen_free(source_screen);
        xm.allocator.destroy(source_screen);
    }
    const target_screen = screen.screen_init(12, 1, 0);
    defer {
        screen.screen_free(target_screen);
        xm.allocator.destroy(target_screen);
    }

    var window_ = T.Window{
        .id = 2115,
        .name = xm.xstrdup("copy-mouse-select-word-window"),
        .sx = 12,
        .sy = 1,
        .options = opts_mod.options_create(opts_mod.global_w_options),
    };
    defer xm.allocator.free(window_.name);
    defer opts_mod.options_free(window_.options);
    defer window_.panes.deinit(xm.allocator);
    defer window_.last_panes.deinit(xm.allocator);
    defer window_.winlinks.deinit(xm.allocator);

    var source = T.WindowPane{
        .id = 2116,
        .window = &window_,
        .options = opts_mod.options_create(window_.options),
        .sx = 12,
        .sy = 1,
        .screen = source_screen,
        .base = .{ .grid = source_grid, .rlower = 0 },
    };
    defer opts_mod.options_free(source.options);
    defer window_mode_runtime.resetModeAll(&source);

    var target = T.WindowPane{
        .id = 2117,
        .window = &window_,
        .options = opts_mod.options_create(window_.options),
        .sx = 12,
        .sy = 1,
        .screen = target_screen,
        .base = .{ .grid = target_grid, .rlower = 0 },
    };
    defer opts_mod.options_free(target.options);
    defer window_mode_runtime.resetModeAll(&target);

    try window_.panes.append(xm.allocator, &source);
    try window_.panes.append(xm.allocator, &target);
    window_.active = &target;
    setGridLineText(source.base.grid, 0, "alpha beta");

    var args = args_mod.Arguments.init(xm.allocator);
    defer args.deinit();
    const wme = wc.enterMode(&target, &source, &args);

    const mouse = T.MouseEvent{
        .valid = true,
        .wp = @intCast(target.id),
        .x = 7,
        .y = 0,
    };
    try runCopyModeMouseCommandArgs(wme, session, &mouse, &.{"select-word"});

    const selected = wc.window_copy_get_selection(wme, null) orelse return error.TestUnexpectedResult;
    defer xm.allocator.free(selected);
    try std.testing.expectEqualStrings("beta", selected);
}

test "copy-mode resize rewraps the cursor and preserves an active selection" {
    const opts_mod = @import("options.zig");

    initWindowCopyTestGlobals();

    opts_mod.global_w_options = opts_mod.options_create(null);
    defer opts_mod.options_free(opts_mod.global_w_options);
    opts_mod.options_default_all(opts_mod.global_w_options, T.OPTIONS_TABLE_WINDOW);

    const source_grid = grid.grid_create(10, 2, 0);
    defer grid.grid_free(source_grid);
    const target_grid = grid.grid_create(10, 2, 0);
    defer grid.grid_free(target_grid);
    const source_screen = screen.screen_init(10, 2, 0);
    defer {
        screen.screen_free(source_screen);
        xm.allocator.destroy(source_screen);
    }
    const target_screen = screen.screen_init(10, 2, 0);
    defer {
        screen.screen_free(target_screen);
        xm.allocator.destroy(target_screen);
    }

    var window_ = T.Window{
        .id = 2300,
        .name = xm.xstrdup("copy-resize-window"),
        .sx = 10,
        .sy = 2,
        .options = opts_mod.options_create(opts_mod.global_w_options),
    };
    defer xm.allocator.free(window_.name);
    defer opts_mod.options_free(window_.options);
    defer window_.panes.deinit(xm.allocator);
    defer window_.last_panes.deinit(xm.allocator);
    defer window_.winlinks.deinit(xm.allocator);

    var source = T.WindowPane{
        .id = 2301,
        .window = &window_,
        .options = opts_mod.options_create(window_.options),
        .sx = 10,
        .sy = 2,
        .screen = source_screen,
        .base = .{ .grid = source_grid, .rlower = 1 },
    };
    defer opts_mod.options_free(source.options);
    defer window_mode_runtime.resetModeAll(&source);

    var target = T.WindowPane{
        .id = 2302,
        .window = &window_,
        .options = opts_mod.options_create(window_.options),
        .sx = 10,
        .sy = 2,
        .screen = target_screen,
        .base = .{ .grid = target_grid, .rlower = 1 },
    };
    defer opts_mod.options_free(target.options);
    defer window_mode_runtime.resetModeAll(&target);

    try window_.panes.append(xm.allocator, &source);
    try window_.panes.append(xm.allocator, &target);
    window_.active = &target;

    setGridLineText(source.base.grid, 0, "abcdefghij");
    source.base.grid.linedata[0].cellused = 10;

    var args = args_mod.Arguments.init(xm.allocator);
    defer args.deinit();
    const wme = wc.enterMode(&target, &source, &args);

    wc.modeData(wme).cx = 2;
    try runCopyModeTestCommand(wme, "begin-selection");
    for (0..6) |_| try runCopyModeTestCommand(wme, "cursor-right");

    const before = wc.window_copy_get_selection(wme, null) orelse return error.TestUnexpectedResult;
    defer xm.allocator.free(before);
    try std.testing.expectEqualStrings("cdefgh", before);

    window.window_pane_resize(&source, 5, 4);
    window.window_pane_resize(&target, 5, 4);
    wc.window_copy_size_changed(wme);

    try std.testing.expectEqual(@as(u32, 1), wc.absoluteCursorRow(wme));
    try std.testing.expectEqual(@as(u32, 3), wc.modeData(wme).cx);
    try std.testing.expect(target.screen.sel != null);

    const after = wc.window_copy_get_selection(wme, null) orelse return error.TestUnexpectedResult;
    defer xm.allocator.free(after);
    try std.testing.expectEqualStrings("cdefgh", after);
}

/// Enter view mode on the given pane, creating the CopyModeData and pushing
/// window_view_mode onto the mode stack using the production entry path.
fn enterViewMode(wp: *T.WindowPane) *T.WindowModeEntry {
    _ = window.window_pane_set_mode(wp, null, &wc.window_view_mode, null);
    return window.window_pane_mode(wp).?;
}

test "view mode init sets up backing screen and uses window_view_mode" {
    initWindowCopyTestGlobals();

    const target_grid = grid.grid_create(10, 4, 0);
    defer grid.grid_free(target_grid);
    const target_screen = screen.screen_init(10, 4, 0);
    defer {
        screen.screen_free(target_screen);
        xm.allocator.destroy(target_screen);
    }

    var window_ = T.Window{
        .id = 3001,
        .name = xm.xstrdup("view-init-window"),
        .sx = 10,
        .sy = 4,
        .options = undefined,
    };
    defer xm.allocator.free(window_.name);
    defer window_.panes.deinit(xm.allocator);
    defer window_.last_panes.deinit(xm.allocator);
    defer window_.winlinks.deinit(xm.allocator);

    var pane = T.WindowPane{
        .id = 3002,
        .window = &window_,
        .options = undefined,
        .sx = 10,
        .sy = 4,
        .screen = target_screen,
        .base = .{ .grid = target_grid, .rlower = 3 },
    };
    defer window_mode_runtime.resetModeAll(&pane);

    try window_.panes.append(xm.allocator, &pane);
    window_.active = &pane;

    const wme = enterViewMode(&pane);

    // The active mode should be window_view_mode, not window_copy_mode.
    try std.testing.expectEqual(&wc.window_view_mode, wme.mode);
    try std.testing.expect(wme.mode != &wc.window_copy_mode);

    // Alternate screen should be active (view mode takes over the display).
    try std.testing.expect(screen.screen_alternate_active(&pane));

    // The backing screen should exist and have the pane's dimensions.
    const data = wc.modeData(wme);
    try std.testing.expectEqual(@as(u32, 10), data.backing.grid.sx);
    try std.testing.expectEqual(@as(u32, 4), data.backing.grid.sy);

    // The view mode uses its own CopyModeData with a separate backing screen,
    // distinct from the pane's base screen.
    try std.testing.expect(data.backing != target_screen);
    try std.testing.expect(data.backing.grid != target_grid);
}

test "view mode: window_copy_add writes to backing screen" {
    initWindowCopyTestGlobals();

    const target_grid = grid.grid_create(10, 4, 0);
    defer grid.grid_free(target_grid);
    const target_screen = screen.screen_init(10, 4, 0);
    defer {
        screen.screen_free(target_screen);
        xm.allocator.destroy(target_screen);
    }

    var window_ = T.Window{
        .id = 3010,
        .name = xm.xstrdup("view-add-window"),
        .sx = 10,
        .sy = 4,
        .options = undefined,
    };
    defer xm.allocator.free(window_.name);
    defer window_.panes.deinit(xm.allocator);
    defer window_.last_panes.deinit(xm.allocator);
    defer window_.winlinks.deinit(xm.allocator);

    var pane = T.WindowPane{
        .id = 3011,
        .window = &window_,
        .options = undefined,
        .sx = 10,
        .sy = 4,
        .screen = target_screen,
        .base = .{ .grid = target_grid, .rlower = 3 },
    };
    defer window_mode_runtime.resetModeAll(&pane);

    try window_.panes.append(xm.allocator, &pane);
    window_.active = &pane;

    const wme = enterViewMode(&pane);

    // Write several lines via window_copy_add (the view-mode content API).
    wc.window_copy_add(&pane, false, "hello");
    wc.window_copy_add(&pane, false, "world");

    // The text should appear on the backing screen, not the pane's base screen.
    const data = wc.modeData(wme);
    const backing = data.backing;

    // The first line skips the leading CRLF (backing_written starts false),
    // so "hello" lands on row 0 and "world" on row 1.
    const row0 = grid.string_cells(backing.grid, 0, 10, .{ .trim_trailing_spaces = true });
    defer xm.allocator.free(row0);
    try std.testing.expectEqualStrings("hello", row0);

    const row1 = grid.string_cells(backing.grid, 1, 10, .{ .trim_trailing_spaces = true });
    defer xm.allocator.free(row1);
    try std.testing.expectEqualStrings("world", row1);

    // The base screen should be untouched.
    const base_row0 = grid.string_cells(target_grid, 0, 10, .{ .trim_trailing_spaces = true });
    defer xm.allocator.free(base_row0);
    try std.testing.expectEqualStrings("", base_row0);
}

test "view mode: re-entry appends instead of creating new mode" {
    initWindowCopyTestGlobals();

    const target_grid = grid.grid_create(10, 4, 0);
    defer grid.grid_free(target_grid);
    const target_screen = screen.screen_init(10, 4, 0);
    defer {
        screen.screen_free(target_screen);
        xm.allocator.destroy(target_screen);
    }

    var window_ = T.Window{
        .id = 3020,
        .name = xm.xstrdup("view-reenter-window"),
        .sx = 10,
        .sy = 4,
        .options = undefined,
    };
    defer xm.allocator.free(window_.name);
    defer window_.panes.deinit(xm.allocator);
    defer window_.last_panes.deinit(xm.allocator);
    defer window_.winlinks.deinit(xm.allocator);

    var pane = T.WindowPane{
        .id = 3021,
        .window = &window_,
        .options = undefined,
        .sx = 10,
        .sy = 4,
        .screen = target_screen,
        .base = .{ .grid = target_grid, .rlower = 3 },
    };
    defer window_mode_runtime.resetModeAll(&pane);

    try window_.panes.append(xm.allocator, &pane);
    window_.active = &pane;

    const wme1 = enterViewMode(&pane);
    wc.window_copy_add(&pane, false, "line1");

    // Simulate re-entry: the server_client_print path checks if view mode
    // is already active and skips pushing a new mode.
    const existing_wme = window.window_pane_mode(&pane);
    try std.testing.expect(existing_wme != null);
    try std.testing.expectEqual(&wc.window_view_mode, existing_wme.?.mode);

    // Since view mode is already active, just add more content (no new push).
    wc.window_copy_add(&pane, false, "line2");

    // Both lines should be on the same backing screen.
    const data = wc.modeData(wme1);
    const backing = data.backing;
    const row0 = grid.string_cells(backing.grid, 0, 10, .{ .trim_trailing_spaces = true });
    defer xm.allocator.free(row0);
    try std.testing.expectEqualStrings("line1", row0);

    const row1 = grid.string_cells(backing.grid, 1, 10, .{ .trim_trailing_spaces = true });
    defer xm.allocator.free(row1);
    try std.testing.expectEqualStrings("line2", row1);

    // Mode stack should have exactly one entry.
    try std.testing.expectEqual(@as(usize, 1), pane.modes.items.len);
}

test "view mode: format variables resolve for window_view_mode" {
    // copyModeDataFromCtx in format-resolve.zig only checks for
    // window_copy_mode, not window_view_mode.  This test documents
    // the expected behaviour: copy-mode format variables (like
    // copy_cursor_x) should resolve when view mode is active too.

    const format_resolve = @import("format-resolve.zig");
    const format_mod = @import("format.zig");

    initWindowCopyTestGlobals();

    // --- Part 1: verify copy_cursor_x resolves in regular copy-mode ---
    const copy_src_grid = grid.grid_create(10, 4, 0);
    defer grid.grid_free(copy_src_grid);
    const copy_src_screen = screen.screen_init(10, 4, 0);
    defer {
        screen.screen_free(copy_src_screen);
        xm.allocator.destroy(copy_src_screen);
    }
    const copy_pane_grid = grid.grid_create(10, 4, 0);
    defer grid.grid_free(copy_pane_grid);
    const copy_pane_screen = screen.screen_init(10, 4, 0);
    defer {
        screen.screen_free(copy_pane_screen);
        xm.allocator.destroy(copy_pane_screen);
    }

    var copy_src_window = T.Window{
        .id = 3032,
        .name = xm.xstrdup("view-fmt-copysrc"),
        .sx = 10,
        .sy = 4,
        .options = undefined,
    };
    defer xm.allocator.free(copy_src_window.name);
    defer copy_src_window.panes.deinit(xm.allocator);
    defer copy_src_window.last_panes.deinit(xm.allocator);
    defer copy_src_window.winlinks.deinit(xm.allocator);

    var copy_src_pane = T.WindowPane{
        .id = 3033,
        .window = &copy_src_window,
        .options = undefined,
        .sx = 10,
        .sy = 4,
        .screen = copy_src_screen,
        .base = .{ .grid = copy_src_grid, .rlower = 3 },
    };
    defer window_mode_runtime.resetModeAll(&copy_src_pane);
    try copy_src_window.panes.append(xm.allocator, &copy_src_pane);
    copy_src_window.active = &copy_src_pane;

    var copy_window = T.Window{
        .id = 3034,
        .name = xm.xstrdup("view-fmt-copyw"),
        .sx = 10,
        .sy = 4,
        .options = undefined,
    };
    defer xm.allocator.free(copy_window.name);
    defer copy_window.panes.deinit(xm.allocator);
    defer copy_window.last_panes.deinit(xm.allocator);
    defer copy_window.winlinks.deinit(xm.allocator);

    var copy_pane = T.WindowPane{
        .id = 3035,
        .window = &copy_window,
        .options = undefined,
        .sx = 10,
        .sy = 4,
        .screen = copy_pane_screen,
        .base = .{ .grid = copy_pane_grid, .rlower = 3 },
    };
    defer window_mode_runtime.resetModeAll(&copy_pane);
    try copy_window.panes.append(xm.allocator, &copy_pane);
    copy_window.active = &copy_pane;

    var args = args_mod.Arguments.init(xm.allocator);
    defer args.deinit();
    const copy_wme = wc.enterMode(&copy_pane, &copy_src_pane, &args);
    wc.modeData(copy_wme).cx = 5;

    // Use the resolver_table to find the copy_cursor_x resolver.
    const resolver = blk: {
        for (format_resolve.resolver_table) |r| {
            if (std.mem.eql(u8, r.name, "copy_cursor_x")) break :blk r;
        }
        unreachable;
    };

    const copy_ctx = format_mod.FormatContext{ .pane = &copy_pane };
    const copy_result = resolver.func(xm.allocator, &copy_ctx);
    try std.testing.expect(copy_result != null);
    defer xm.allocator.free(copy_result.?);
    try std.testing.expectEqualStrings("5", copy_result.?);

    // --- Part 2: verify same resolver in view mode ---
    // NOTE: This documents a known bug — copyModeDataFromCtx only checks
    // window_copy_mode, not window_view_mode.  When fixed, the expectation
    // below should change to: expectEqualStrings("3", view_result.?)

    const view_grid = grid.grid_create(10, 4, 0);
    defer grid.grid_free(view_grid);
    const view_screen = screen.screen_init(10, 4, 0);
    defer {
        screen.screen_free(view_screen);
        xm.allocator.destroy(view_screen);
    }

    var view_window = T.Window{
        .id = 3030,
        .name = xm.xstrdup("view-fmt-window"),
        .sx = 10,
        .sy = 4,
        .options = undefined,
    };
    defer xm.allocator.free(view_window.name);
    defer view_window.panes.deinit(xm.allocator);
    defer view_window.last_panes.deinit(xm.allocator);
    defer view_window.winlinks.deinit(xm.allocator);

    var view_pane = T.WindowPane{
        .id = 3031,
        .window = &view_window,
        .options = undefined,
        .sx = 10,
        .sy = 4,
        .screen = view_screen,
        .base = .{ .grid = view_grid, .rlower = 3 },
    };
    defer window_mode_runtime.resetModeAll(&view_pane);
    try view_window.panes.append(xm.allocator, &view_pane);
    view_window.active = &view_pane;

    const view_wme = enterViewMode(&view_pane);
    wc.modeData(view_wme).cx = 3;

    const view_ctx = format_mod.FormatContext{ .pane = &view_pane };
    const view_result = resolver.func(xm.allocator, &view_ctx);

    // copyModeDataFromCtx recognizes both window_copy_mode and
    // window_view_mode, so the resolver returns data.cx as expected.
    try std.testing.expectEqualStrings("3", view_result.?);
    defer xm.allocator.free(view_result.?);
}

test "view mode: resize updates backing screen dimensions" {
    initWindowCopyTestGlobals();

    const target_grid = grid.grid_create(10, 4, 0);
    defer grid.grid_free(target_grid);
    const target_screen = screen.screen_init(10, 4, 0);
    defer {
        screen.screen_free(target_screen);
        xm.allocator.destroy(target_screen);
    }

    var window_ = T.Window{
        .id = 3040,
        .name = xm.xstrdup("view-resize-window"),
        .sx = 10,
        .sy = 4,
        .options = undefined,
    };
    defer xm.allocator.free(window_.name);
    defer window_.panes.deinit(xm.allocator);
    defer window_.last_panes.deinit(xm.allocator);
    defer window_.winlinks.deinit(xm.allocator);

    var pane = T.WindowPane{
        .id = 3041,
        .window = &window_,
        .options = undefined,
        .sx = 10,
        .sy = 4,
        .screen = target_screen,
        .base = .{ .grid = target_grid, .rlower = 3 },
    };
    defer window_mode_runtime.resetModeAll(&pane);

    try window_.panes.append(xm.allocator, &pane);
    window_.active = &pane;

    const wme = enterViewMode(&pane);
    const data = wc.modeData(wme);

    // Verify initial dimensions.
    try std.testing.expectEqual(@as(u32, 10), data.backing.grid.sx);
    try std.testing.expectEqual(@as(u32, 4), data.backing.grid.sy);

    // Resize via the public API used for both copy and view modes.
    wc.window_copy_resize(wme, 20, 8);

    // Backing screen should now have the new dimensions.
    try std.testing.expectEqual(@as(u32, 20), data.backing.grid.sx);
    try std.testing.expectEqual(@as(u32, 8), data.backing.grid.sy);
}

test "view mode uses the live resized pane height on the real entry path" {
    initWindowCopyTestGlobals();

    const target_grid = grid.grid_create(80, 24, 0);
    defer grid.grid_free(target_grid);
    const target_screen = screen.screen_init(80, 24, 0);
    defer {
        screen.screen_free(target_screen);
        xm.allocator.destroy(target_screen);
    }

    var window_ = T.Window{
        .id = 3042,
        .name = xm.xstrdup("view-resized-pane-window"),
        .sx = 80,
        .sy = 24,
        .options = undefined,
    };
    defer xm.allocator.free(window_.name);
    defer window_.panes.deinit(xm.allocator);
    defer window_.last_panes.deinit(xm.allocator);
    defer window_.winlinks.deinit(xm.allocator);

    var pane = T.WindowPane{
        .id = 3043,
        .window = &window_,
        .options = undefined,
        .sx = 80,
        .sy = 24,
        .screen = target_screen,
        .base = .{ .grid = target_grid, .rlower = 23 },
    };
    defer window_mode_runtime.resetModeAll(&pane);

    try window_.panes.append(xm.allocator, &pane);
    window_.active = &pane;

    window.window_pane_resize(&pane, 120, 39);
    try std.testing.expectEqual(@as(u32, 120), pane.base.grid.sx);
    try std.testing.expectEqual(@as(u32, 39), pane.base.grid.sy);

    const wme = enterViewMode(&pane);
    const data = wc.modeData(wme);
    try std.testing.expectEqual(@as(u32, 120), data.backing.grid.sx);
    try std.testing.expectEqual(@as(u32, 39), data.backing.grid.sy);
    try std.testing.expectEqual(@as(u32, 120), pane.screen.grid.sx);
    try std.testing.expectEqual(@as(u32, 39), pane.screen.grid.sy);

    var line_no: u32 = 0;
    while (line_no < 39) : (line_no += 1) {
        const text = try std.fmt.allocPrint(xm.allocator, "line-{d:0>2}", .{line_no});
        defer xm.allocator.free(text);
        wc.window_copy_add(&pane, false, text);
    }

    const lower = grid.string_cells(pane.screen.grid, 30, 120, .{ .trim_trailing_spaces = true });
    defer xm.allocator.free(lower);
    try std.testing.expectEqualStrings("line-30", lower);

    const bottom = grid.string_cells(pane.screen.grid, 38, 120, .{ .trim_trailing_spaces = true });
    defer xm.allocator.free(bottom);
    try std.testing.expectEqualStrings("line-38", bottom);
}

test "view mode follows the newest appended lines past the viewport" {
    initWindowCopyTestGlobals();

    const target_grid = grid.grid_create(10, 4, 0);
    defer grid.grid_free(target_grid);
    const target_screen = screen.screen_init(10, 4, 0);
    defer {
        screen.screen_free(target_screen);
        xm.allocator.destroy(target_screen);
    }

    var window_ = T.Window{
        .id = 3044,
        .name = xm.xstrdup("view-tail-window"),
        .sx = 10,
        .sy = 4,
        .options = undefined,
    };
    defer xm.allocator.free(window_.name);
    defer window_.panes.deinit(xm.allocator);
    defer window_.last_panes.deinit(xm.allocator);
    defer window_.winlinks.deinit(xm.allocator);

    var pane = T.WindowPane{
        .id = 3045,
        .window = &window_,
        .options = undefined,
        .sx = 10,
        .sy = 4,
        .screen = target_screen,
        .base = .{ .grid = target_grid, .rlower = 3 },
    };
    defer window_mode_runtime.resetModeAll(&pane);

    try window_.panes.append(xm.allocator, &pane);
    window_.active = &pane;

    _ = enterViewMode(&pane);

    for (0..6) |line_no| {
        const text = try std.fmt.allocPrint(xm.allocator, "line-{d}", .{line_no});
        defer xm.allocator.free(text);
        wc.window_copy_add(&pane, false, text);
    }

    const first_visible = grid.string_cells(pane.screen.grid, 0, 10, .{ .trim_trailing_spaces = true });
    defer xm.allocator.free(first_visible);
    const last_visible = grid.string_cells(pane.screen.grid, 3, 10, .{ .trim_trailing_spaces = true });
    defer xm.allocator.free(last_visible);

    try std.testing.expectEqualStrings("line-2", first_visible);
    try std.testing.expectEqualStrings("line-5", last_visible);
}

test "view mode: refresh-from-pane leaves view content intact" {
    const opts_mod = @import("options.zig");

    initWindowCopyTestGlobals();

    opts_mod.global_w_options = opts_mod.options_create(null);
    defer opts_mod.options_free(opts_mod.global_w_options);
    opts_mod.options_default_all(opts_mod.global_w_options, T.OPTIONS_TABLE_WINDOW);

    const target_grid = grid.grid_create(10, 4, 0);
    defer grid.grid_free(target_grid);
    const target_screen = screen.screen_init(10, 4, 0);
    defer {
        screen.screen_free(target_screen);
        xm.allocator.destroy(target_screen);
    }

    var window_ = T.Window{
        .id = 3050,
        .name = xm.xstrdup("view-refresh-window"),
        .sx = 10,
        .sy = 4,
        .options = opts_mod.options_create(opts_mod.global_w_options),
    };
    defer xm.allocator.free(window_.name);
    defer opts_mod.options_free(window_.options);
    defer window_.panes.deinit(xm.allocator);
    defer window_.last_panes.deinit(xm.allocator);
    defer window_.winlinks.deinit(xm.allocator);

    var pane = T.WindowPane{
        .id = 3051,
        .window = &window_,
        .options = undefined,
        .sx = 10,
        .sy = 4,
        .screen = target_screen,
        .base = .{ .grid = target_grid, .rlower = 3 },
    };
    defer window_mode_runtime.resetModeAll(&pane);

    try window_.panes.append(xm.allocator, &pane);
    window_.active = &pane;

    const wme = enterViewMode(&pane);

    // Add some content via view mode.
    wc.window_copy_add(&pane, false, "viewtext");

    const data = wc.modeData(wme);
    const row0 = grid.string_cells(data.backing.grid, 0, 10, .{ .trim_trailing_spaces = true });
    defer xm.allocator.free(row0);
    try std.testing.expectEqualStrings("viewtext", row0);

    try runCopyModeTestCommand(wme, "refresh-from-pane");

    const row0_after = grid.string_cells(data.backing.grid, 0, 10, .{ .trim_trailing_spaces = true });
    defer xm.allocator.free(row0_after);
    try std.testing.expectEqualStrings("viewtext", row0_after);
}

test "copy-mode copy-selection-no-clear keeps the active selection" {
    const env_mod = @import("environ.zig");
    const paste_mod = @import("paste.zig");
    const sess = @import("session.zig");

    initWindowCopyTestGlobals();
    paste_mod.paste_reset_for_tests();

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

    const source_grid = grid.grid_create(8, 1, 0);
    defer grid.grid_free(source_grid);
    const target_grid = grid.grid_create(8, 1, 0);
    defer grid.grid_free(target_grid);
    const source_screen = screen.screen_init(8, 1, 0);
    defer {
        screen.screen_free(source_screen);
        xm.allocator.destroy(source_screen);
    }
    const target_screen = screen.screen_init(8, 1, 0);
    defer {
        screen.screen_free(target_screen);
        xm.allocator.destroy(target_screen);
    }

    const session = sess.session_create(null, "copy-selection-no-clear", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("copy-selection-no-clear") != null) sess.session_destroy(session, false, "test");

    var window_ = T.Window{
        .id = 3100,
        .name = xm.xstrdup("copy-selection-no-clear-window"),
        .sx = 8,
        .sy = 1,
        .options = opts.options_create(opts.global_w_options),
    };
    defer xm.allocator.free(window_.name);
    defer opts.options_free(window_.options);
    defer window_.panes.deinit(xm.allocator);
    defer window_.last_panes.deinit(xm.allocator);
    defer window_.winlinks.deinit(xm.allocator);

    var source = T.WindowPane{
        .id = 3101,
        .window = &window_,
        .options = opts.options_create(window_.options),
        .sx = 8,
        .sy = 1,
        .screen = source_screen,
        .base = .{ .grid = source_grid, .rlower = 0 },
    };
    defer opts.options_free(source.options);
    defer window_mode_runtime.resetModeAll(&source);

    var target = T.WindowPane{
        .id = 3102,
        .window = &window_,
        .options = opts.options_create(window_.options),
        .sx = 8,
        .sy = 1,
        .screen = target_screen,
        .base = .{ .grid = target_grid, .rlower = 0 },
    };
    defer opts.options_free(target.options);
    defer window_mode_runtime.resetModeAll(&target);

    try window_.panes.append(xm.allocator, &source);
    try window_.panes.append(xm.allocator, &target);
    window_.active = &target;
    setGridLineText(source.base.grid, 0, "copyme");
    source.base.grid.linedata[0].cellused = 6;

    var args = args_mod.Arguments.init(xm.allocator);
    defer args.deinit();
    const wme = wc.enterMode(&target, &source, &args);

    try runCopyModeTestCommand(wme, "select-line");
    try runCopyModeTestCommandWithSession(wme, session, "copy-selection-no-clear");

    const top = paste_mod.paste_get_top(null) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("copyme", paste_mod.paste_buffer_data(top, null));
    try std.testing.expect(wc.modeData(wme).lineflag != .none);
}

test "copy-mode copy-selection exports clipboard data to attached viewers" {
    const client_registry = @import("client-registry.zig");
    const env_mod = @import("environ.zig");
    const paste_mod = @import("paste.zig");
    const protocol = @import("zmux-protocol.zig");
    const tty_features = @import("tty-features.zig");

    initWindowCopyTestGlobals();
    paste_mod.paste_reset_for_tests();
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

    const source_grid = grid.grid_create(8, 1, 0);
    defer grid.grid_free(source_grid);
    const target_grid = grid.grid_create(8, 1, 0);
    defer grid.grid_free(target_grid);
    const source_screen = screen.screen_init(8, 1, 0);
    defer {
        screen.screen_free(source_screen);
        xm.allocator.destroy(source_screen);
    }
    const target_screen = screen.screen_init(8, 1, 0);
    defer {
        screen.screen_free(target_screen);
        xm.allocator.destroy(target_screen);
    }

    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);
    const session_name = xm.xstrdup("copy-selection-clipboard");
    defer xm.allocator.free(session_name);
    var session = T.Session{
        .id = 3103,
        .name = session_name,
        .cwd = "/",
        .options = opts.options_create(opts.global_s_options),
        .environ = env,
        .lastw = .{},
        .windows = std.AutoHashMap(i32, *T.Winlink).init(xm.allocator),
    };
    defer opts.options_free(session.options);
    defer session.windows.deinit();
    defer session.lastw.deinit(xm.allocator);

    var window_ = T.Window{
        .id = 3104,
        .name = xm.xstrdup("copy-selection-clipboard-window"),
        .sx = 8,
        .sy = 1,
        .options = opts.options_create(opts.global_w_options),
    };
    defer xm.allocator.free(window_.name);
    defer opts.options_free(window_.options);
    defer window_.panes.deinit(xm.allocator);
    defer window_.last_panes.deinit(xm.allocator);
    defer window_.winlinks.deinit(xm.allocator);

    var source = T.WindowPane{
        .id = 3105,
        .window = &window_,
        .options = opts.options_create(window_.options),
        .sx = 8,
        .sy = 1,
        .screen = source_screen,
        .base = .{ .grid = source_grid, .rlower = 0 },
    };
    defer opts.options_free(source.options);
    defer window_mode_runtime.resetModeAll(&source);

    var target = T.WindowPane{
        .id = 3106,
        .window = &window_,
        .options = opts.options_create(window_.options),
        .sx = 8,
        .sy = 1,
        .screen = target_screen,
        .base = .{ .grid = target_grid, .rlower = 0 },
    };
    defer opts.options_free(target.options);
    defer window_mode_runtime.resetModeAll(&target);

    try window_.panes.append(xm.allocator, &source);
    try window_.panes.append(xm.allocator, &target);
    window_.active = &target;
    setGridLineText(source.base.grid, 0, "copyme");
    source.base.grid.linedata[0].cellused = 6;

    var wl = T.Winlink{
        .idx = 0,
        .session = &session,
        .window = &window_,
    };
    try session.windows.put(0, &wl);
    try window_.winlinks.append(xm.allocator, &wl);
    session.curw = &wl;

    var pair: [2]i32 = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &pair));

    var proc = T.ZmuxProc{ .name = "copy-mode-clipboard" };
    defer proc.peers.deinit(xm.allocator);

    const client_env = env_mod.environ_create();
    defer env_mod.environ_free(client_env);
    var client = T.Client{
        .name = "copy-mode-clipboard-client",
        .environ = client_env,
        .tty = undefined,
        .status = .{},
        .flags = T.CLIENT_ATTACHED,
        .session = &session,
        .term_features = tty_features.featureBit(.clipboard),
    };
    client.tty = .{ .client = &client };
    client.tty.flags |= @intCast(T.TTY_STARTED);
    client.peer = proc_mod.proc_add_peer(&proc, pair[0], copyModeClipboardTestPeerDispatch, null);
    defer {
        const peer = client.peer.?;
        c.imsg.imsgbuf_clear(&peer.ibuf);
        std.posix.close(peer.ibuf.fd);
        xm.allocator.destroy(peer);
        proc.peers.clearRetainingCapacity();
    }
    client_registry.add(&client);

    var reader: c.imsg.imsgbuf = undefined;
    try std.testing.expectEqual(@as(i32, 0), c.imsg.imsgbuf_init(&reader, pair[1]));
    defer {
        c.imsg.imsgbuf_clear(&reader);
        std.posix.close(pair[1]);
    }

    var args = args_mod.Arguments.init(xm.allocator);
    defer args.deinit();
    const wme = wc.enterMode(&target, &source, &args);

    try runCopyModeTestCommand(wme, "select-line");
    try runCopyModeTestCommandWithSession(wme, &session, "copy-selection");

    try std.testing.expectEqual(@as(i32, 1), c.imsg.imsgbuf_read(&reader));

    var imsg_msg: c.imsg.imsg = undefined;
    try std.testing.expect(c.imsg.imsg_get(&reader, &imsg_msg) > 0);
    defer c.imsg.imsg_free(&imsg_msg);
    try std.testing.expectEqual(@as(u32, @intCast(@intFromEnum(protocol.MsgType.write))), c.imsg.imsg_get_type(&imsg_msg));

    const payload_len = imsg_msg.hdr.len -% @sizeOf(c.imsg.imsg_hdr);
    const payload = try xm.allocator.alloc(u8, payload_len);
    defer xm.allocator.free(payload);
    _ = c.imsg.imsg_get_data(&imsg_msg, payload.ptr, payload.len);

    var stream: i32 = 0;
    @memcpy(std.mem.asBytes(&stream), payload[0..@sizeOf(i32)]);
    try std.testing.expectEqual(@as(i32, 1), stream);

    const data = "copyme";
    const b64_len = std.base64.standard.Encoder.calcSize(data.len);
    const b64 = try xm.allocator.alloc(u8, b64_len);
    defer xm.allocator.free(b64);
    _ = std.base64.standard.Encoder.encode(b64, data);
    const expected = try std.fmt.allocPrint(xm.allocator, "\x1b]52;;{s}\x07", .{b64});
    defer xm.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, payload[@sizeOf(i32)..]);
}

test "copy-mode append-selection appends onto the current top paste buffer" {
    const env_mod = @import("environ.zig");
    const paste_mod = @import("paste.zig");
    const sess = @import("session.zig");

    initWindowCopyTestGlobals();
    paste_mod.paste_reset_for_tests();

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

    const session = sess.session_create(null, "copy-append-selection", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("copy-append-selection") != null) sess.session_destroy(session, false, "test");

    const source_grid = grid.grid_create(8, 1, 0);
    defer grid.grid_free(source_grid);
    const target_grid = grid.grid_create(8, 1, 0);
    defer grid.grid_free(target_grid);
    const source_screen = screen.screen_init(8, 1, 0);
    defer {
        screen.screen_free(source_screen);
        xm.allocator.destroy(source_screen);
    }
    const target_screen = screen.screen_init(8, 1, 0);
    defer {
        screen.screen_free(target_screen);
        xm.allocator.destroy(target_screen);
    }

    var window_ = T.Window{
        .id = 3120,
        .name = xm.xstrdup("copy-append-selection-window"),
        .sx = 8,
        .sy = 1,
        .options = opts.options_create(opts.global_w_options),
    };
    defer xm.allocator.free(window_.name);
    defer opts.options_free(window_.options);
    defer window_.panes.deinit(xm.allocator);
    defer window_.last_panes.deinit(xm.allocator);
    defer window_.winlinks.deinit(xm.allocator);

    var source = T.WindowPane{
        .id = 3121,
        .window = &window_,
        .options = opts.options_create(window_.options),
        .sx = 8,
        .sy = 1,
        .screen = source_screen,
        .base = .{ .grid = source_grid, .rlower = 0 },
    };
    defer opts.options_free(source.options);
    defer window_mode_runtime.resetModeAll(&source);

    var target = T.WindowPane{
        .id = 3122,
        .window = &window_,
        .options = opts.options_create(window_.options),
        .sx = 8,
        .sy = 1,
        .screen = target_screen,
        .base = .{ .grid = target_grid, .rlower = 0 },
    };
    defer opts.options_free(target.options);
    defer window_mode_runtime.resetModeAll(&target);

    try window_.panes.append(xm.allocator, &source);
    try window_.panes.append(xm.allocator, &target);
    window_.active = &target;
    setGridLineText(source.base.grid, 0, "tail");
    source.base.grid.linedata[0].cellused = 4;

    paste_mod.paste_add(null, xm.xstrdup("head"));
    var args = args_mod.Arguments.init(xm.allocator);
    defer args.deinit();
    const wme = wc.enterMode(&target, &source, &args);

    try runCopyModeTestCommand(wme, "select-line");
    try runCopyModeTestCommandWithSession(wme, session, "append-selection");

    const top = paste_mod.paste_get_top(null) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("headtail", paste_mod.paste_buffer_data(top, null));
}

test "copy-mode copy-selection falls back to the current search match" {
    const env_mod = @import("environ.zig");
    const paste_mod = @import("paste.zig");
    const sess = @import("session.zig");

    initWindowCopyTestGlobals();
    paste_mod.paste_reset_for_tests();

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

    const session = sess.session_create(null, "copy-selection-match", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("copy-selection-match") != null) sess.session_destroy(session, false, "test");

    const source_grid = grid.grid_create(12, 1, 0);
    defer grid.grid_free(source_grid);
    const target_grid = grid.grid_create(12, 1, 0);
    defer grid.grid_free(target_grid);
    const source_screen = screen.screen_init(12, 1, 0);
    defer {
        screen.screen_free(source_screen);
        xm.allocator.destroy(source_screen);
    }
    const target_screen = screen.screen_init(12, 1, 0);
    defer {
        screen.screen_free(target_screen);
        xm.allocator.destroy(target_screen);
    }

    var window_ = T.Window{
        .id = 3130,
        .name = xm.xstrdup("copy-selection-match-window"),
        .sx = 12,
        .sy = 1,
        .options = opts.options_create(opts.global_w_options),
    };
    defer xm.allocator.free(window_.name);
    defer opts.options_free(window_.options);
    defer window_.panes.deinit(xm.allocator);
    defer window_.last_panes.deinit(xm.allocator);
    defer window_.winlinks.deinit(xm.allocator);

    var source = T.WindowPane{
        .id = 3131,
        .window = &window_,
        .options = opts.options_create(window_.options),
        .sx = 12,
        .sy = 1,
        .screen = source_screen,
        .base = .{ .grid = source_grid, .rlower = 0 },
    };
    defer opts.options_free(source.options);
    defer window_mode_runtime.resetModeAll(&source);

    var target = T.WindowPane{
        .id = 3132,
        .window = &window_,
        .options = opts.options_create(window_.options),
        .sx = 12,
        .sy = 1,
        .screen = target_screen,
        .base = .{ .grid = target_grid, .rlower = 0 },
    };
    defer opts.options_free(target.options);
    defer window_mode_runtime.resetModeAll(&target);

    try window_.panes.append(xm.allocator, &source);
    try window_.panes.append(xm.allocator, &target);
    window_.active = &target;
    setGridLineText(source.base.grid, 0, "foo bar foo");
    source.base.grid.linedata[0].cellused = 11;

    var args = args_mod.Arguments.init(xm.allocator);
    defer args.deinit();
    const wme = wc.enterMode(&target, &source, &args);

    try runCopyModeTestCommandArgs(wme, session, &.{ "search-forward", "bar" });
    try runCopyModeTestCommandWithSession(wme, session, "copy-selection");

    const top = paste_mod.paste_get_top(null) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("bar", paste_mod.paste_buffer_data(top, null));
}

test "copy-mode recognizes copy-pipe line aliases" {
    const env_mod = @import("environ.zig");
    const paste_mod = @import("paste.zig");
    const sess = @import("session.zig");

    initWindowCopyTestGlobals();
    paste_mod.paste_reset_for_tests();

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

    const session = sess.session_create(null, "copy-pipe-line-alias", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("copy-pipe-line-alias") != null) sess.session_destroy(session, false, "test");

    const source_grid = grid.grid_create(8, 1, 0);
    defer grid.grid_free(source_grid);
    const target_grid = grid.grid_create(8, 1, 0);
    defer grid.grid_free(target_grid);
    const source_screen = screen.screen_init(8, 1, 0);
    defer {
        screen.screen_free(source_screen);
        xm.allocator.destroy(source_screen);
    }
    const target_screen = screen.screen_init(8, 1, 0);
    defer {
        screen.screen_free(target_screen);
        xm.allocator.destroy(target_screen);
    }

    var window_ = T.Window{
        .id = 3110,
        .name = xm.xstrdup("copy-pipe-line-window"),
        .sx = 8,
        .sy = 1,
        .options = opts.options_create(opts.global_w_options),
    };
    defer xm.allocator.free(window_.name);
    defer opts.options_free(window_.options);
    defer window_.panes.deinit(xm.allocator);
    defer window_.last_panes.deinit(xm.allocator);
    defer window_.winlinks.deinit(xm.allocator);

    var source = T.WindowPane{
        .id = 3111,
        .window = &window_,
        .options = opts.options_create(window_.options),
        .sx = 8,
        .sy = 1,
        .screen = source_screen,
        .base = .{ .grid = source_grid, .rlower = 0 },
    };
    defer opts.options_free(source.options);
    defer window_mode_runtime.resetModeAll(&source);

    var target = T.WindowPane{
        .id = 3112,
        .window = &window_,
        .options = opts.options_create(window_.options),
        .sx = 8,
        .sy = 1,
        .screen = target_screen,
        .base = .{ .grid = target_grid, .rlower = 0 },
    };
    defer opts.options_free(target.options);
    defer window_mode_runtime.resetModeAll(&target);

    try window_.panes.append(xm.allocator, &source);
    try window_.panes.append(xm.allocator, &target);
    window_.active = &target;
    setGridLineText(source.base.grid, 0, "linecopy");
    source.base.grid.linedata[0].cellused = 8;

    var args = args_mod.Arguments.init(xm.allocator);
    defer args.deinit();
    const wme = wc.enterMode(&target, &source, &args);

    try runCopyModeTestCommandWithSession(wme, session, "copy-pipe-line");
    const line_top = paste_mod.paste_get_top(null) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("linecop", paste_mod.paste_buffer_data(line_top, null));

    paste_mod.paste_reset_for_tests();
    wc.modeData(wme).cx = 4;
    try runCopyModeTestCommandWithSession(wme, session, "copy-pipe-end-of-line");
    const tail_top = paste_mod.paste_get_top(null) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("cop", paste_mod.paste_buffer_data(tail_top, null));
}
