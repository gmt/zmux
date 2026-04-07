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
const builtin = @import("builtin");
const T = @import("types.zig");
const file_mod = @import("file.zig");
const grid_mod = @import("grid.zig");
const screen_mod = @import("screen.zig");
const screen_write = @import("screen-write.zig");
const utf8 = @import("utf8.zig");
const window_copy = @import("window-copy.zig");
const window_mod = @import("window.zig");
const window_mode_runtime = @import("window-mode-runtime.zig");
const server = @import("server.zig");
const xm = @import("xmalloc.zig");

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

    if (builtin.is_test and stream == 2 and suppressExpectedTestStderr(data)) return;

    const file = if (stream == 2) std.fs.File.stderr() else std.fs.File.stdout();
    _ = file.writeAll(data) catch {};
}

fn suppressExpectedTestStderr(data: []const u8) bool {
    const exact = [_][]const u8{
        "No such file or directory: /zmux-unit-test-nonexistent-config-path/.conf\n",
        "no current target\n",
        "invalid sort order\n",
        "pane input failed\n",
        "format expansion not supported yet\n",
        "pane is not empty\n",
        "sessions should be nested with care, unset $TMUX to force\n",
        "missing user argument\n",
        "-a and -d cannot be used together\n",
        "-r and -w cannot be used together\n",
        "owner owns the server, can't change access\n",
        "not a control client\n",
        "Bad file descriptor\n",
        "invalid confirm key\n",
        "invalid type: bogus\n",
        "create window failed: index in use: 0\n",
        "invalid option: status-left\n",
        "already set: after-show-options[2]\n",
        "not an array: status-left[0]\n",
        "not an array: @local[1]\n",
        "already set: status-left\n",
        "duplicate session: beta\n",
        "window only linked to one session\n",
        "invalid environment: BROKEN\n",
        "can't move window, sessions are grouped\n",
        "target pane has exited\n",
        "respawn pane failed: pane respawn-pane-live:0.0 still active\n",
        "not able to wait\n",
    };
    for (exact) |line| {
        if (std.mem.eql(u8, data, line)) return true;
    }
    return false;
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

    // For raw (non-parsed) data, escape control bytes first (matching
    // tmux's utf8_stravisx in server_client_print).
    const text: []const u8 = if (parse) data else blk: {
        break :blk utf8.utf8_strvisx(data, utf8.VIS_OCTAL | utf8.VIS_CSTYLE | utf8.VIS_NOSLASH);
    };
    defer if (!parse) xm.allocator.free(text);

    // Split by newline so each resulting line gets its own row on the
    // backing screen (mirrors tmux's evbuffer_readln loop).
    var rest = text;
    while (std.mem.indexOfScalar(u8, rest, '\n')) |nl| {
        window_copy.window_copy_add(wp, true, rest[0..nl]);
        rest = rest[nl + 1 ..];
    }
    if (rest.len > 0)
        window_copy.window_copy_add(wp, true, rest);
    return true;
}

pub fn server_client_close_view_mode(wp: *T.WindowPane) void {
    if (window_mod.window_pane_mode(wp)) |wme| {
        if (wme.mode == &window_copy.window_view_mode) {
            if (wme.mode.close) |close_fn| close_fn(wme);
            _ = window_mode_runtime.popMode(wp, wme);
            return;
        }
    }
    window_mode_runtime.noteModeRedraw(wp);
}

fn ensure_view_mode(wp: *T.WindowPane) bool {
    if (window_mod.window_pane_mode(wp)) |wme| {
        return wme.mode == &window_copy.window_view_mode;
    }

    _ = window_mod.window_pane_set_mode(wp, null, &window_copy.window_view_mode, null);
    window_mode_runtime.noteModeChange(wp);
    return true;
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
        screen_mod.screen_free(alt_screen);
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
        .status = .{},
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

    try std.testing.expect(window_mod.window_pane_mode(&pane) != null);
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

test "server_client_close_view_mode keeps pane-mode redraw fallout on the shared runtime path" {
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
        screen_mod.screen_free(alt_screen);
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
        .status = .{},
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
        .status = .{},
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
        .status = .{},
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

test "server_client_print preserves utf8 payloads on the shared attached view-mode path" {
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
        screen_mod.screen_free(alt_screen);
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
        .status = .{},
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

test "server_client_print raw attached output uses the shared escaped-byte writer path" {
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
        screen_mod.screen_free(alt_screen);
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
        .status = .{},
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
