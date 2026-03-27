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
// Ported in part from tmux/server-client.c.
// Original copyright:
//   Copyright (c) 2009 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence - same terms as above.

//! server-print.zig - shared reduced command-output/view-mode helpers.

const std = @import("std");
const T = @import("types.zig");
const file_mod = @import("file.zig");
const grid_mod = @import("grid.zig");
const screen_mod = @import("screen.zig");
const screen_write = @import("screen-write.zig");
const utf8 = @import("utf8.zig");
const window_mod = @import("window.zig");
const window_mode_runtime = @import("window-mode-runtime.zig");
const server = @import("server.zig");
const xm = @import("xmalloc.zig");

const server_print_view_mode = T.WindowMode{
    .name = "server-print-view",
    .key = server_print_view_key,
};

const DirectPrintData = struct {
    text: []const u8,
    owned: ?[]u8 = null,

    fn deinit(self: *DirectPrintData) void {
        if (self.owned) |slice| xm.allocator.free(slice);
    }
};

pub fn server_client_write_stream(client: ?*T.Client, stream: i32, data: []const u8) void {
    if (client) |cl| {
        if (cl.peer) |peer| {
            _ = file_mod.sendPeerStream(peer, stream, data);
            return;
        }
    }

    const file = if (stream == 2) std.fs.File.stderr() else std.fs.File.stdout();
    _ = file.writeAll(data) catch {};
}

pub fn server_client_control_message(client: *T.Client, message: []const u8) void {
    var line: std.ArrayList(u8) = .{};
    defer line.deinit(xm.allocator);

    line.appendSlice(xm.allocator, "%message ") catch unreachable;
    line.appendSlice(xm.allocator, message) catch unreachable;
    line.append(xm.allocator, '\n') catch unreachable;
    server_client_write_stream(client, 1, line.items);
}

pub fn server_client_print(client: ?*T.Client, parse: bool, data: []const u8) void {
    if (client) |cl| {
        if (cl.session != null and (cl.flags & T.CLIENT_CONTROL) == 0) {
            if (server_client_view_data(cl, data, parse)) return;
        }
    }

    var direct = prepareDirectPrintData(client, parse, data);
    defer direct.deinit();

    if (!parse or direct.text.len == 0 or direct.text[direct.text.len - 1] == '\n') {
        server_client_write_stream(client, 1, direct.text);
        return;
    }

    var line: std.ArrayList(u8) = .{};
    defer line.deinit(xm.allocator);
    line.appendSlice(xm.allocator, direct.text) catch unreachable;
    line.append(xm.allocator, '\n') catch unreachable;
    server_client_write_stream(client, 1, line.items);
}

fn prepareDirectPrintData(client: ?*const T.Client, parse: bool, data: []const u8) DirectPrintData {
    const prepared = if (parse)
        xm.xstrdup(data)
    else
        utf8.utf8_strvisx(data, utf8.VIS_OCTAL | utf8.VIS_CSTYLE | utf8.VIS_NOSLASH);

    if (client) |cl| {
        if ((cl.flags & T.CLIENT_UTF8) == 0) {
            const sanitized = utf8.utf8_sanitize(prepared);
            xm.allocator.free(prepared);
            return .{ .text = sanitized, .owned = sanitized };
        }
    }

    return .{ .text = prepared, .owned = prepared };
}

pub fn server_client_view_data(client: *T.Client, data: []const u8, parse: bool) bool {
    const session = client.session orelse return false;
    const wl = session.curw orelse return false;
    const wp = wl.window.active orelse return false;

    return server_pane_view_data(wp, data, parse);
}

pub fn server_pane_view_data(wp: *T.WindowPane, data: []const u8, parse: bool) bool {
    if (!ensure_view_mode(wp)) return false;
    render_view_data(wp, data, parse);
    wp.flags |= T.PANE_REDRAW;
    server.server_redraw_pane(wp);
    return true;
}

pub fn server_client_close_view_mode(wp: *T.WindowPane) void {
    if (window_mod.window_pane_mode(wp)) |wme| {
        if (wme.mode == &server_print_view_mode) {
            _ = window_mode_runtime.popMode(wp, wme);
        }
    }
    screen_mod.screen_leave_alternate(wp, true);
    window_mode_runtime.noteModeChange(wp);
}

fn ensure_view_mode(wp: *T.WindowPane) bool {
    if (window_mod.window_pane_mode(wp)) |wme| {
        return wme.mode == &server_print_view_mode;
    }

    screen_mod.screen_enter_alternate(wp, true);
    _ = window_mode_runtime.pushMode(wp, &server_print_view_mode, null, null);
    return true;
}

fn render_view_data(wp: *T.WindowPane, data: []const u8, parse: bool) void {
    if (!parse) screen_mod.screen_reset_active(wp.screen);
    wp.screen.cursor_visible = false;

    var ctx = T.ScreenWriteCtx{ .s = wp.screen };
    if (parse) {
        screen_write.putn(&ctx, data);
        if (data.len != 0 and data[data.len - 1] != '\n') {
            screen_write.newline(&ctx);
        }
        return;
    }

    _ = screen_write.putEscapedBytes(&ctx, data, false);
}

fn server_print_view_key(
    wme: *T.WindowModeEntry,
    _client: ?*T.Client,
    _session: *T.Session,
    _wl: *T.Winlink,
    _key: T.key_code,
    _mouse: ?*const T.MouseEvent,
) void {
    _ = _client;
    _ = _session;
    _ = _wl;
    _ = _key;
    _ = _mouse;
    server_client_close_view_mode(wme.wp);
}

fn clearClientRedrawFlags(client: *T.Client) void {
    client.flags &= ~@as(u64, T.CLIENT_REDRAW);
}

test "server_client_print appends parsed output in the shared view mode" {
    const client_registry = @import("client-registry.zig");
    var env = T.Environ.init(xm.allocator);
    defer env.deinit();

    const session_name = xm.xstrdup("server-print");
    defer xm.allocator.free(session_name);
    const window_name = xm.xstrdup("pane");
    defer xm.allocator.free(window_name);

    const base_grid = grid_mod.grid_create(10, 4, 2000);
    defer grid_mod.grid_free(base_grid);
    const alt_screen = screen_mod.screen_init(10, 4, 2000);
    defer {
        grid_mod.grid_free(alt_screen.grid);
        xm.allocator.destroy(alt_screen);
    }

    var window = T.Window{
        .id = 1,
        .name = window_name,
        .sx = 10,
        .sy = 4,
        .options = undefined,
    };
    defer window.panes.deinit(xm.allocator);
    defer window.winlinks.deinit(xm.allocator);

    var pane = T.WindowPane{
        .id = 2,
        .window = &window,
        .options = undefined,
        .sx = 10,
        .sy = 4,
        .screen = alt_screen,
        .base = .{ .grid = base_grid, .rlower = 3 },
    };
    defer if (window_mod.window_pane_mode(&pane)) |_| server_client_close_view_mode(&pane);

    try window.panes.append(xm.allocator, &pane);
    window.active = &pane;

    var session = T.Session{
        .id = 0,
        .name = session_name,
        .cwd = "",
        .lastw = .{},
        .windows = std.AutoHashMap(i32, *T.Winlink).init(xm.allocator),
        .options = undefined,
        .environ = &env,
    };
    defer session.windows.deinit();
    defer session.lastw.deinit(xm.allocator);

    var winlink = T.Winlink{
        .idx = 0,
        .session = &session,
        .window = &window,
    };
    try session.windows.put(0, &winlink);
    try window.winlinks.append(xm.allocator, &winlink);
    session.curw = &winlink;

    var client = T.Client{
        .environ = &env,
        .tty = undefined,
        .status = .{ .screen = undefined },
        .session = &session,
        .flags = T.CLIENT_ATTACHED,
    };
    client_registry.add(&client);
    defer {
        client_registry.remove(&client);
        clearClientRedrawFlags(&client);
    }

    server_client_print(&client, true, "alpha");
    server_client_print(&client, true, "beta");

    try std.testing.expect(screen_mod.screen_alternate_active(&pane));
    try std.testing.expect(pane.flags & T.PANE_REDRAW != 0);
    try std.testing.expect(client.flags & T.CLIENT_REDRAWWINDOW == 0);
    try std.testing.expect(client.flags & T.CLIENT_REDRAWSTATUS != 0);
    try std.testing.expect(client.flags & T.CLIENT_REDRAWBORDERS != 0);

    const first_row = try grid_row_string(pane.screen.grid, 0);
    defer xm.allocator.free(first_row);
    const second_row = try grid_row_string(pane.screen.grid, 1);
    defer xm.allocator.free(second_row);
    try std.testing.expectEqualStrings("alpha", first_row);
    try std.testing.expectEqualStrings("beta", second_row);
}

test "server_client_close_view_mode keeps pane-mode redraw fallout on the shared runtime seam" {
    const client_registry = @import("client-registry.zig");
    var env = T.Environ.init(xm.allocator);
    defer env.deinit();

    const session_name = xm.xstrdup("server-print-close");
    defer xm.allocator.free(session_name);
    const window_name = xm.xstrdup("pane");
    defer xm.allocator.free(window_name);

    const base_grid = grid_mod.grid_create(10, 4, 2000);
    defer grid_mod.grid_free(base_grid);
    const alt_screen = screen_mod.screen_init(10, 4, 2000);
    defer {
        grid_mod.grid_free(alt_screen.grid);
        xm.allocator.destroy(alt_screen);
    }

    var window = T.Window{
        .id = 11,
        .name = window_name,
        .sx = 10,
        .sy = 4,
        .options = undefined,
    };
    defer window.panes.deinit(xm.allocator);
    defer window.winlinks.deinit(xm.allocator);

    var pane = T.WindowPane{
        .id = 12,
        .window = &window,
        .options = undefined,
        .sx = 10,
        .sy = 4,
        .screen = alt_screen,
        .base = .{ .grid = base_grid, .rlower = 3 },
    };

    try window.panes.append(xm.allocator, &pane);
    window.active = &pane;

    var session = T.Session{
        .id = 1,
        .name = session_name,
        .cwd = "",
        .lastw = .{},
        .windows = std.AutoHashMap(i32, *T.Winlink).init(xm.allocator),
        .options = undefined,
        .environ = &env,
    };
    defer session.windows.deinit();
    defer session.lastw.deinit(xm.allocator);

    var winlink = T.Winlink{
        .idx = 0,
        .session = &session,
        .window = &window,
    };
    try session.windows.put(0, &winlink);
    try window.winlinks.append(xm.allocator, &winlink);
    session.curw = &winlink;

    var client = T.Client{
        .environ = &env,
        .tty = undefined,
        .status = .{ .screen = undefined },
        .session = &session,
        .flags = T.CLIENT_ATTACHED,
    };
    client_registry.add(&client);
    defer client_registry.remove(&client);

    try std.testing.expect(server_pane_view_data(&pane, "alpha", true));
    clearClientRedrawFlags(&client);
    pane.flags = 0;

    server_client_close_view_mode(&pane);

    try std.testing.expect(!screen_mod.screen_alternate_active(&pane));
    try std.testing.expect(pane.flags & T.PANE_REDRAW != 0);
    try std.testing.expect(client.flags & T.CLIENT_REDRAWSTATUS != 0);
    try std.testing.expect(client.flags & T.CLIENT_REDRAWBORDERS != 0);
    try std.testing.expect(client.flags & T.CLIENT_REDRAWPANES != 0);
}

test "server_client_print keeps detached non-utf8 direct output on the shared sanitized stdout path" {
    const env_mod = @import("environ.zig");

    var stdout_pipe: [2]i32 = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.pipe(&stdout_pipe));
    defer {
        std.posix.close(stdout_pipe[0]);
        if (stdout_pipe[1] != -1) std.posix.close(stdout_pipe[1]);
    }

    const stdout_dup = try std.posix.dup(std.posix.STDOUT_FILENO);
    defer std.posix.close(stdout_dup);

    try std.posix.dup2(stdout_pipe[1], std.posix.STDOUT_FILENO);
    defer std.posix.dup2(stdout_dup, std.posix.STDOUT_FILENO) catch {};

    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);

    var client = T.Client{
        .name = "direct-print-client",
        .environ = env,
        .tty = undefined,
        .status = .{ .screen = undefined },
        .flags = 0,
    };
    client.tty.client = &client;

    server_client_print(&client, true, "bad \xc3(");

    std.posix.close(stdout_pipe[1]);
    stdout_pipe[1] = -1;

    var buf: [128]u8 = undefined;
    const read_len = try std.posix.read(stdout_pipe[0], &buf);
    try std.testing.expectEqualStrings("bad _(\n", buf[0..read_len]);
}

test "server_client_print keeps direct control-client output on the shared sanitized path" {
    const env_mod = @import("environ.zig");

    var stdout_pipe: [2]i32 = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.pipe(&stdout_pipe));
    defer {
        std.posix.close(stdout_pipe[0]);
        if (stdout_pipe[1] != -1) std.posix.close(stdout_pipe[1]);
    }

    const stdout_dup = try std.posix.dup(std.posix.STDOUT_FILENO);
    defer std.posix.close(stdout_dup);

    try std.posix.dup2(stdout_pipe[1], std.posix.STDOUT_FILENO);
    defer std.posix.dup2(stdout_dup, std.posix.STDOUT_FILENO) catch {};

    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);

    var client = T.Client{
        .name = "control-print-client",
        .environ = env,
        .tty = undefined,
        .status = .{ .screen = undefined },
        .flags = T.CLIENT_CONTROL,
    };
    client.tty.client = &client;

    server_client_print(&client, true, "bad \xc3(");

    std.posix.close(stdout_pipe[1]);
    stdout_pipe[1] = -1;

    var buf: [128]u8 = undefined;
    const read_len = try std.posix.read(stdout_pipe[0], &buf);
    try std.testing.expectEqualStrings("bad _(\n", buf[0..read_len]);
}

test "server_client_print preserves utf8 payloads on the shared attached view-mode seam" {
    const client_registry = @import("client-registry.zig");
    var env = T.Environ.init(xm.allocator);
    defer env.deinit();

    const session_name = xm.xstrdup("server-print-utf8");
    defer xm.allocator.free(session_name);
    const window_name = xm.xstrdup("pane");
    defer xm.allocator.free(window_name);

    const base_grid = grid_mod.grid_create(8, 4, 2000);
    defer grid_mod.grid_free(base_grid);
    const alt_screen = screen_mod.screen_init(8, 4, 2000);
    defer {
        grid_mod.grid_free(alt_screen.grid);
        xm.allocator.destroy(alt_screen);
    }

    var window = T.Window{
        .id = 21,
        .name = window_name,
        .sx = 8,
        .sy = 4,
        .options = undefined,
    };
    defer window.panes.deinit(xm.allocator);
    defer window.winlinks.deinit(xm.allocator);

    var pane = T.WindowPane{
        .id = 22,
        .window = &window,
        .options = undefined,
        .sx = 8,
        .sy = 4,
        .screen = alt_screen,
        .base = .{ .grid = base_grid, .rlower = 3 },
    };
    defer if (window_mod.window_pane_mode(&pane)) |_| server_client_close_view_mode(&pane);

    try window.panes.append(xm.allocator, &pane);
    window.active = &pane;

    var session = T.Session{
        .id = 20,
        .name = session_name,
        .cwd = "",
        .lastw = .{},
        .windows = std.AutoHashMap(i32, *T.Winlink).init(xm.allocator),
        .options = undefined,
        .environ = &env,
    };
    defer session.windows.deinit();
    defer session.lastw.deinit(xm.allocator);

    var winlink = T.Winlink{
        .idx = 0,
        .session = &session,
        .window = &window,
    };
    try session.windows.put(0, &winlink);
    try window.winlinks.append(xm.allocator, &winlink);
    session.curw = &winlink;

    var client = T.Client{
        .environ = &env,
        .tty = undefined,
        .status = .{ .screen = undefined },
        .session = &session,
        .flags = T.CLIENT_ATTACHED,
    };
    client_registry.add(&client);
    defer {
        client_registry.remove(&client);
        clearClientRedrawFlags(&client);
    }

    server_client_print(&client, true, "\xf0\x9f\x99\x82");
    server_client_print(&client, true, "\xce\xb2");

    const first_row = try grid_row_string(pane.screen.grid, 0);
    defer xm.allocator.free(first_row);
    const second_row = try grid_row_string(pane.screen.grid, 1);
    defer xm.allocator.free(second_row);
    try std.testing.expectEqualStrings("\xf0\x9f\x99\x82", first_row);
    try std.testing.expectEqualStrings("\xce\xb2", second_row);
}

test "server_client_print raw attached output uses the shared escaped-byte writer seam" {
    const client_registry = @import("client-registry.zig");
    var env = T.Environ.init(xm.allocator);
    defer env.deinit();

    const session_name = xm.xstrdup("server-print-raw");
    defer xm.allocator.free(session_name);
    const window_name = xm.xstrdup("pane");
    defer xm.allocator.free(window_name);

    const base_grid = grid_mod.grid_create(16, 4, 2000);
    defer grid_mod.grid_free(base_grid);
    const alt_screen = screen_mod.screen_init(16, 4, 2000);
    defer {
        grid_mod.grid_free(alt_screen.grid);
        xm.allocator.destroy(alt_screen);
    }

    var window = T.Window{
        .id = 31,
        .name = window_name,
        .sx = 16,
        .sy = 4,
        .options = undefined,
    };
    defer window.panes.deinit(xm.allocator);
    defer window.winlinks.deinit(xm.allocator);

    var pane = T.WindowPane{
        .id = 32,
        .window = &window,
        .options = undefined,
        .sx = 16,
        .sy = 4,
        .screen = alt_screen,
        .base = .{ .grid = base_grid, .rlower = 3 },
    };
    defer if (window_mod.window_pane_mode(&pane)) |_| server_client_close_view_mode(&pane);

    try window.panes.append(xm.allocator, &pane);
    window.active = &pane;

    var session = T.Session{
        .id = 30,
        .name = session_name,
        .cwd = "",
        .lastw = .{},
        .windows = std.AutoHashMap(i32, *T.Winlink).init(xm.allocator),
        .options = undefined,
        .environ = &env,
    };
    defer session.windows.deinit();
    defer session.lastw.deinit(xm.allocator);

    var winlink = T.Winlink{
        .idx = 0,
        .session = &session,
        .window = &window,
    };
    try session.windows.put(0, &winlink);
    try window.winlinks.append(xm.allocator, &winlink);
    session.curw = &winlink;

    var client = T.Client{
        .environ = &env,
        .tty = undefined,
        .status = .{ .screen = undefined },
        .session = &session,
        .flags = T.CLIENT_ATTACHED,
    };
    client_registry.add(&client);
    defer {
        client_registry.remove(&client);
        clearClientRedrawFlags(&client);
    }

    server_client_print(&client, false, "\x1b🙂\xc3(");

    const row = try grid_row_string(pane.screen.grid, 0);
    defer xm.allocator.free(row);
    try std.testing.expectEqualStrings("\\033🙂\\303(", row);
}

fn grid_row_string(gd: *T.Grid, row: u32) ![]u8 {
    return grid_mod.string_cells(gd, row, gd.sx, .{
        .trim_trailing_spaces = true,
    });
}
