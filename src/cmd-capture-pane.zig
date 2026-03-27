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
// Ported in part from tmux/cmd-capture-pane.c.
// Original copyright:
//   Copyright (c) 2009 Jonathan Alvarado <radobobo@users.sourceforge.net>
//   ISC licence – same terms as above.

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const cmd_mod = @import("cmd.zig");
const cmdq = @import("cmd-queue.zig");
const cmd_find = @import("cmd-find.zig");
const paste_mod = @import("paste.zig");
const grid_mod = @import("grid.zig");
const screen_mod = @import("screen.zig");
const screen_write = @import("screen-write.zig");
const window_mod = @import("window.zig");

fn exec(cmd: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {
    const args = cmd_mod.cmd_get_args(cmd);
    var target: T.CmdFindState = .{};
    if (cmd_find.cmd_find_target(&target, item, args.get('t'), .pane, 0) != 0)
        return .@"error";
    const wp = target.wp orelse return .@"error";

    if (cmd.entry == &entry_clear) {
        clear_history(wp, args.has('H'));
        return .normal;
    }

    const buf = if (args.has('P'))
        capture_pending(wp, args.has('C'))
    else blk: {
        if (args.has('a')) {
            if (!screen_mod.screen_alternate_active(wp)) {
                if (args.has('q')) break :blk xm.xstrdup("");
                cmdq.cmdq_error(item, "no alternate screen", .{});
                return .@"error";
            }
        }

        const target_screen = if (args.has('a'))
            &wp.base
        else if (args.has('M'))
            capture_mode_screen(wp)
        else
            screen_mod.screen_current(wp);

        break :blk capture_grid(
            target_screen,
            args.get('S'),
            args.get('E'),
            args.has('J'),
            args.has('T'),
            args.has('N'),
            args.has('e'),
            args.has('C'),
        );
    };

    if (args.has('p')) {
        defer xm.allocator.free(buf);
        var printable = buf;
        if (printable.len > 0 and printable[printable.len - 1] == '\n') printable = printable[0 .. printable.len - 1];
        cmdq.cmdq_print(item, "{s}", .{printable});
        return .normal;
    }

    var cause: ?[]u8 = null;
    if (paste_mod.paste_set(buf, args.get('b'), &cause) != 0) {
        defer if (cause) |msg| xm.allocator.free(msg);
        cmdq.cmdq_error(item, "{s}", .{cause orelse "capture-pane failed"});
        return .@"error";
    }
    return .normal;
}

fn clear_history(wp: *T.WindowPane, clear_hyperlinks: bool) void {
    while (window_mod.window_pane_mode(wp)) |wme| {
        _ = window_mod.window_pane_pop_mode(wp, wme);
    }
    grid_mod.grid_clear_history(wp.base.grid);
    if (clear_hyperlinks) screen_mod.screen_reset_hyperlinks(screen_mod.screen_current(wp));
}

fn capture_pending(wp: *T.WindowPane, escape_sequences: bool) []u8 {
    if (wp.input_pending.items.len == 0) return xm.xstrdup("");
    if (!escape_sequences) return xm.allocator.dupe(u8, wp.input_pending.items) catch unreachable;

    var out: std.ArrayList(u8) = .{};
    defer out.deinit(xm.allocator);

    for (wp.input_pending.items) |byte| {
        if (byte >= ' ' and byte != '\\') {
            out.append(xm.allocator, byte) catch unreachable;
            continue;
        }

        const escaped = [_]u8{
            '\\',
            @as(u8, '0') + ((byte >> 6) & 0x7),
            @as(u8, '0') + ((byte >> 3) & 0x7),
            @as(u8, '0') + (byte & 0x7),
        };
        out.appendSlice(xm.allocator, &escaped) catch unreachable;
    }

    return out.toOwnedSlice(xm.allocator) catch unreachable;
}

fn capture_grid(
    s: *T.Screen,
    start_raw: ?[]const u8,
    end_raw: ?[]const u8,
    join_lines: bool,
    preserve_incomplete: bool,
    keep_spaces: bool,
    with_sequences: bool,
    escape_sequences: bool,
) []u8 {
    const gd = s.grid;
    if (gd.sy == 0) return xm.xstrdup("");

    var top = parse_bound(gd, start_raw, true);
    var bottom = parse_bound(gd, end_raw, false);
    if (bottom < top) std.mem.swap(u32, &top, &bottom);

    var out: std.ArrayList(u8) = .{};
    defer out.deinit(xm.allocator);
    var last_cell = T.grid_default_cell;

    var absolute_row = top;
    while (absolute_row <= bottom) : (absolute_row += 1) {
        const row = grid_storage_row(gd, absolute_row) orelse {
            if (!join_lines) out.append(xm.allocator, '\n') catch unreachable;
            continue;
        };

        const line = render_grid_line(s, row, join_lines, preserve_incomplete, keep_spaces, with_sequences, escape_sequences, &last_cell);
        defer xm.allocator.free(line);
        out.appendSlice(xm.allocator, line) catch unreachable;

        if (!join_lines or !grid_line_wrapped(gd, row)) {
            out.append(xm.allocator, '\n') catch unreachable;
        }
    }
    return out.toOwnedSlice(xm.allocator) catch unreachable;
}

fn capture_mode_screen(wp: *T.WindowPane) *T.Screen {
    if (window_mod.window_pane_mode(wp)) |wme| {
        if (wme.mode.get_screen) |get_screen| return get_screen(wme);
    }
    return screen_mod.screen_current(wp);
}

fn parse_bound(gd: *T.Grid, raw: ?[]const u8, is_start: bool) u32 {
    const last_row = gd.hsize + gd.sy - 1;
    const default_row = if (is_start) gd.hsize else last_row;
    const text = raw orelse return default_row;
    if (std.mem.eql(u8, text, "-")) return if (is_start) 0 else last_row;

    const parsed = std.fmt.parseInt(i64, text, 10) catch return default_row;
    if (parsed < 0 and @as(u64, @intCast(-parsed)) > gd.hsize) return 0;
    const absolute = @as(i64, @intCast(gd.hsize)) + parsed;
    return @min(if (absolute < 0) 0 else @as(u32, @intCast(absolute)), last_row);
}

fn grid_storage_row(gd: *T.Grid, absolute_row: u32) ?u32 {
    if (absolute_row < gd.hsize) return null;
    const row = absolute_row - gd.hsize;
    if (row >= gd.sy) return null;
    return row;
}

fn grid_line_wrapped(gd: *T.Grid, row: u32) bool {
    return row < gd.linedata.len and (gd.linedata[row].flags & T.GRID_LINE_WRAPPED) != 0;
}

fn render_grid_line(
    s: *T.Screen,
    row: u32,
    join_lines: bool,
    preserve_incomplete: bool,
    keep_spaces: bool,
    with_sequences: bool,
    escape_sequences: bool,
    last_cell: *T.GridCell,
) []u8 {
    return grid_mod.string_cells(s.grid, row, s.grid.sx, .{
        .trim_trailing_spaces = !keep_spaces,
        .include_empty_cells = !join_lines and !preserve_incomplete,
        .escape_sequences = escape_sequences,
        .with_sequences = with_sequences,
        .screen = s,
        .last_cell = last_cell,
    });
}

pub const entry: cmd_mod.CmdEntry = .{
    .name = "capture-pane",
    .alias = "capturep",
    .usage = "[-aCeJMNpPqT] [-b buffer-name] [-E end-line] [-S start-line] [-t target-pane]",
    .template = "ab:CeE:JMNpPqS:Tt:",
    .lower = 0,
    .upper = 0,
    .flags = T.CMD_AFTERHOOK,
    .exec = exec,
};

pub const entry_clear: cmd_mod.CmdEntry = .{
    .name = "clear-history",
    .alias = "clearhist",
    .usage = "[-H] [-t target-pane]",
    .template = "Ht:",
    .lower = 0,
    .upper = 0,
    .flags = T.CMD_AFTERHOOK,
    .exec = exec,
};

fn set_grid_line_text(gd: *T.Grid, row: usize, text: []const u8) void {
    grid_mod.ensure_line_capacity(gd, @intCast(row));
    grid_mod.clear_line(&gd.linedata[row]);
    for (text, 0..) |ch, idx| {
        grid_mod.set_ascii(gd, @intCast(row), @intCast(idx), ch);
    }
}

test "capture-pane helper captures current grid lines and trims spaces by default" {
    const opts = @import("options.zig");
    const env_mod = @import("environ.zig");
    const sess = @import("session.zig");
    const spawn = @import("spawn.zig");

    sess.session_init_globals(xm.allocator);
    @import("window.zig").window_init_globals(xm.allocator);

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

    const s = sess.session_create(null, "capture-pane-test", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("capture-pane-test") != null) sess.session_destroy(s, false, "test");

    var cause: ?[]u8 = null;
    var ctx: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const wl = spawn.spawn_window(&ctx, &cause).?;
    const wp = wl.window.active.?;

    set_grid_line_text(wp.base.grid, 0, "hello   ");
    set_grid_line_text(wp.base.grid, 1, "world");

    const captured = capture_grid(&wp.base, null, null, false, false, false, false, false);
    defer xm.allocator.free(captured);
    try std.testing.expectEqualStrings("hello\nworld\n", captured[0..12]);
}

test "capture-pane helper supports line bounds and sequence escaping" {
    const opts = @import("options.zig");
    const env_mod = @import("environ.zig");
    const sess = @import("session.zig");
    const spawn = @import("spawn.zig");

    sess.session_init_globals(xm.allocator);
    @import("window.zig").window_init_globals(xm.allocator);

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

    const s = sess.session_create(null, "capture-pane-esc", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("capture-pane-esc") != null) sess.session_destroy(s, false, "test");

    var cause: ?[]u8 = null;
    var ctx: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const wl = spawn.spawn_window(&ctx, &cause).?;
    const wp = wl.window.active.?;

    set_grid_line_text(wp.base.grid, 0, "one");
    set_grid_line_text(wp.base.grid, 1, "\\x");

    const captured = capture_grid(&wp.base, "1", "1", false, false, false, false, true);
    defer xm.allocator.free(captured);
    try std.testing.expectEqualStrings("\\\\x\n", captured);
}

test "capture-pane helper can target saved primary grid while alternate screen is active" {
    const opts = @import("options.zig");
    const env_mod = @import("environ.zig");
    const sess = @import("session.zig");
    const spawn = @import("spawn.zig");
    const input_mod = @import("input.zig");

    sess.session_init_globals(xm.allocator);
    @import("window.zig").window_init_globals(xm.allocator);

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

    const s = sess.session_create(null, "capture-pane-alt", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("capture-pane-alt") != null) sess.session_destroy(s, false, "test");

    var cause: ?[]u8 = null;
    var ctx: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const wl = spawn.spawn_window(&ctx, &cause).?;
    const wp = wl.window.active.?;

    set_grid_line_text(wp.base.grid, 0, "main");
    input_mod.input_parse_screen(wp, "\x1b[?1049hALT");

    const visible = capture_grid(screen_mod.screen_current(wp), "0", "2", false, false, false, false, false);
    defer xm.allocator.free(visible);
    try std.testing.expectEqualStrings("ALT\n\n\n", visible);

    const primary = capture_grid(&wp.base, "0", "2", false, false, false, false, false);
    defer xm.allocator.free(primary);
    try std.testing.expectEqualStrings("main\n\n\n", primary);
}

test "capture-pane helper preserves combined and wide utf8 grid payloads" {
    const screen = screen_mod.screen_init(8, 1, 0);
    defer {
        screen_mod.screen_free(screen);
        xm.allocator.destroy(screen);
    }

    var ctx = T.ScreenWriteCtx{ .s = screen };
    screen_write.putn(&ctx, "e\xcc\x81🙂");

    const captured = capture_grid(screen, "0", "0", false, false, false, false, false);
    defer xm.allocator.free(captured);

    try std.testing.expectEqualStrings("é🙂\n", captured);
}

test "capture-pane helper captures pending pane input bytes" {
    const opts = @import("options.zig");
    const env_mod = @import("environ.zig");
    const sess = @import("session.zig");
    const spawn = @import("spawn.zig");

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

    env_mod.global_environ = env_mod.environ_create();
    defer env_mod.environ_free(env_mod.global_environ);

    const s = sess.session_create(null, "capture-pane-pending", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("capture-pane-pending") != null) sess.session_destroy(s, false, "test");

    var cause: ?[]u8 = null;
    var ctx: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const wl = spawn.spawn_window(&ctx, &cause).?;
    const wp = wl.window.active.?;

    try wp.input_pending.appendSlice(xm.allocator, "abc");

    const captured = capture_pending(wp, false);
    defer xm.allocator.free(captured);
    try std.testing.expectEqualStrings("abc", captured);
}

test "capture-pane helper octal-escapes pending pane input with -C" {
    const opts = @import("options.zig");
    const env_mod = @import("environ.zig");
    const sess = @import("session.zig");
    const spawn = @import("spawn.zig");

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

    env_mod.global_environ = env_mod.environ_create();
    defer env_mod.environ_free(env_mod.global_environ);

    const s = sess.session_create(null, "capture-pane-pending-escaped", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("capture-pane-pending-escaped") != null) sess.session_destroy(s, false, "test");

    var cause: ?[]u8 = null;
    var ctx: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const wl = spawn.spawn_window(&ctx, &cause).?;
    const wp = wl.window.active.?;

    try wp.input_pending.appendSlice(xm.allocator, &[_]u8{ 0x01, '\\', 'A', 0x7f });

    const captured = capture_pending(wp, true);
    defer xm.allocator.free(captured);
    try std.testing.expectEqualStrings("\\001\\134A\x7f", captured);
}

test "clear-history helper drops history, resets modes, and clears current screen hyperlinks" {
    const hyperlinks = @import("hyperlinks.zig");
    const opts = @import("options.zig");
    const env_mod = @import("environ.zig");
    const sess = @import("session.zig");
    const spawn = @import("spawn.zig");

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

    env_mod.global_environ = env_mod.environ_create();
    defer env_mod.environ_free(env_mod.global_environ);

    const s = sess.session_create(null, "clear-history-test", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("clear-history-test") != null) sess.session_destroy(s, false, "test");

    var cause: ?[]u8 = null;
    var ctx: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const wl = spawn.spawn_window(&ctx, &cause).?;
    const wp = wl.window.active.?;

    const dummy_mode = T.WindowMode{ .name = "dummy" };
    _ = window_mod.window_pane_push_mode(wp, &dummy_mode, null, null);
    wp.base.grid.hsize = 4;
    wp.base.grid.hscrolled = 2;
    const first = hyperlinks.hyperlinks_put(wp.base.hyperlinks.?, "https://example.com", "pane");
    try std.testing.expect(hyperlinks.hyperlinks_get(wp.base.hyperlinks.?, first, null, null, null));

    clear_history(wp, true);

    try std.testing.expectEqual(@as(u32, 0), wp.base.grid.hsize);
    try std.testing.expectEqual(@as(u32, 0), wp.base.grid.hscrolled);
    try std.testing.expectEqual(@as(usize, 0), wp.modes.items.len);
    try std.testing.expect(!hyperlinks.hyperlinks_get(wp.base.hyperlinks.?, first, null, null, null));
}
test "capture-pane helper preserves sgr state and hyperlinks with -e" {
    const screen = screen_mod.screen_init(2, 1, 0);
    defer {
        screen_mod.screen_free(screen);
        xm.allocator.destroy(screen);
    }

    var styled = T.grid_default_cell;
    styled.fg = 1;
    styled.attr = T.GRID_ATTR_BRIGHT;
    styled.link = @import("hyperlinks.zig").hyperlinks_put(screen.hyperlinks.?, "https://example.com", "pane");
    styled.data = T.grid_default_cell.data;
    styled.data.data[0] = 'A';
    grid_mod.set_cell(screen.grid, 0, 0, &styled);
    grid_mod.set_ascii(screen.grid, 0, 1, 'B');

    const captured = capture_grid(screen, "0", "0", false, false, false, true, false);
    defer xm.allocator.free(captured);

    try std.testing.expectEqualStrings("\x1b[1m\x1b[31m\x1b]8;id=pane;https://example.com\x1b\\A\x1b[0m\x1b]8;;\x1b\\B\n", captured);
}

test "capture-pane helper joins only wrapped rows with -J" {
    const screen = screen_mod.screen_init(4, 3, 0);
    defer {
        screen_mod.screen_free(screen);
        xm.allocator.destroy(screen);
    }

    set_grid_line_text(screen.grid, 0, "abc");
    set_grid_line_text(screen.grid, 1, "def");
    set_grid_line_text(screen.grid, 2, "ghi");
    screen.grid.linedata[0].flags |= T.GRID_LINE_WRAPPED;

    const captured = capture_grid(screen, "0", "2", true, false, false, false, false);
    defer xm.allocator.free(captured);

    try std.testing.expectEqualStrings("abcdef\nghi\n", captured);
}

test "capture-pane helper preserves incomplete lines only with -T" {
    const screen = screen_mod.screen_init(5, 1, 0);
    defer {
        screen_mod.screen_free(screen);
        xm.allocator.destroy(screen);
    }

    set_grid_line_text(screen.grid, 0, "ab");

    const default_capture = capture_grid(screen, "0", "0", false, false, true, false, false);
    defer xm.allocator.free(default_capture);
    try std.testing.expectEqualStrings("ab   \n", default_capture);

    const preserved_capture = capture_grid(screen, "0", "0", false, true, true, false, false);
    defer xm.allocator.free(preserved_capture);
    try std.testing.expectEqualStrings("ab\n", preserved_capture);
}

test "capture-pane helper maps absolute pane rows onto visible rows" {
    const screen = screen_mod.screen_init(4, 3, 0);
    defer {
        screen_mod.screen_free(screen);
        xm.allocator.destroy(screen);
    }

    screen.grid.hsize = 4;
    set_grid_line_text(screen.grid, 0, "one");
    set_grid_line_text(screen.grid, 1, "two");
    set_grid_line_text(screen.grid, 2, "tri");

    const captured = capture_grid(screen, "0", "2", false, false, false, false, false);
    defer xm.allocator.free(captured);

    try std.testing.expectEqualStrings("one\ntwo\ntri\n", captured);
}

test "capture-pane mode screen helper prefers the active mode screen for -M" {
    const mode_screen = screen_mod.screen_init(4, 1, 0);
    defer {
        screen_mod.screen_free(mode_screen);
        xm.allocator.destroy(mode_screen);
    }
    set_grid_line_text(mode_screen.grid, 0, "mode");

    const ModeData = struct {
        screen: *T.Screen,
    };
    const mode_callbacks = struct {
        fn get_screen(wme: *T.WindowModeEntry) *T.Screen {
            const data: *ModeData = @ptrCast(@alignCast(wme.data.?));
            return data.screen;
        }
    };
    const mode = T.WindowMode{
        .name = "capture-mode-screen",
        .get_screen = mode_callbacks.get_screen,
    };

    const base_grid = grid_mod.grid_create(4, 1, 0);
    defer grid_mod.grid_free(base_grid);
    const pane_screen = screen_mod.screen_init(4, 1, 0);
    defer {
        screen_mod.screen_free(pane_screen);
        xm.allocator.destroy(pane_screen);
    }

    var window = T.Window{
        .id = 1,
        .name = xm.xstrdup("capture-pane-mode"),
        .sx = 4,
        .sy = 1,
        .options = undefined,
    };
    defer xm.allocator.free(window.name);
    defer window.panes.deinit(xm.allocator);
    defer window.last_panes.deinit(xm.allocator);
    defer window.winlinks.deinit(xm.allocator);

    var pane = T.WindowPane{
        .id = 2,
        .window = &window,
        .options = undefined,
        .sx = 4,
        .sy = 1,
        .screen = pane_screen,
        .base = .{ .grid = base_grid, .rlower = 0 },
    };
    defer {
        while (window_mod.window_pane_mode(&pane)) |wme| {
            _ = window_mod.window_pane_pop_mode(&pane, wme);
        }
    }

    try window.panes.append(xm.allocator, &pane);

    var data = ModeData{ .screen = mode_screen };
    _ = window_mod.window_pane_push_mode(&pane, &mode, @ptrCast(&data), null);

    const captured = capture_grid(capture_mode_screen(&pane), "0", "0", false, false, false, false, false);
    defer xm.allocator.free(captured);

    try std.testing.expectEqualStrings("mode\n", captured);
}
