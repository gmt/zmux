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

fn exec(cmd: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {
    const args = cmd_mod.cmd_get_args(cmd);
    var target: T.CmdFindState = .{};
    if (cmd_find.cmd_find_target(&target, item, args.get('t'), .pane, 0) != 0)
        return .@"error";
    const wp = target.wp orelse return .@"error";

    if (cmd.entry == &entry_clear) {
        if (args.has('H')) {
            cmdq.cmdq_error(item, "hyperlink history clearing not supported yet", .{});
            return .@"error";
        }
        wp.base.grid.hsize = 0;
        return .normal;
    }

    if (args.has('e')) {
        cmdq.cmdq_error(item, "escape-sequence capture not supported yet", .{});
        return .@"error";
    }
    if (args.has('M')) {
        cmdq.cmdq_error(item, "mode screen capture not supported yet", .{});
        return .@"error";
    }
    if (args.has('P')) {
        cmdq.cmdq_error(item, "pending input capture not supported yet", .{});
        return .@"error";
    }
    if (args.has('T')) {
        cmdq.cmdq_error(item, "incomplete-line preservation not supported yet", .{});
        return .@"error";
    }

    const target_grid = if (args.has('a')) blk: {
        if (!screen_mod.screen_alternate_active(wp)) {
            cmdq.cmdq_error(item, "no alternate screen", .{});
            return .@"error";
        }
        break :blk wp.base.grid;
    } else screen_mod.screen_current(wp).grid;

    const buf = capture_grid(
        target_grid,
        args.get('S'),
        args.get('E'),
        args.has('J'),
        args.has('N'),
        args.has('C'),
        item,
    ) orelse return .@"error";

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

fn capture_grid(
    gd: *T.Grid,
    start_raw: ?[]const u8,
    end_raw: ?[]const u8,
    join_lines: bool,
    keep_spaces: bool,
    escape_sequences: bool,
    item: *cmdq.CmdqItem,
) ?[]u8 {
    if (gd.sy == 0) return xm.xstrdup("");

    var top = parse_bound(start_raw, gd.sy, true, item) orelse return null;
    var bottom = parse_bound(end_raw, gd.sy, false, item) orelse return null;
    if (bottom < top) std.mem.swap(u32, &top, &bottom);

    var out: std.ArrayList(u8) = .{};
    defer out.deinit(xm.allocator);

    var row = top;
    while (row <= bottom) : (row += 1) {
        const line = render_grid_line(gd, row, keep_spaces, escape_sequences);
        defer xm.allocator.free(line);
        out.appendSlice(xm.allocator, line) catch unreachable;
        if (!join_lines or row == bottom) out.append(xm.allocator, '\n') catch unreachable;
    }
    return out.toOwnedSlice(xm.allocator) catch unreachable;
}

fn parse_bound(raw: ?[]const u8, sy: u32, is_start: bool, item: *cmdq.CmdqItem) ?u32 {
    const text = raw orelse return if (is_start) 0 else sy - 1;
    if (std.mem.eql(u8, text, "-")) return if (is_start) 0 else sy - 1;

    const parsed = std.fmt.parseInt(i32, text, 10) catch {
        cmdq.cmdq_error(item, "{s} line invalid", .{if (is_start) "start" else "end"});
        return null;
    };
    if (parsed < 0) return 0;
    return @min(@as(u32, @intCast(parsed)), sy - 1);
}

fn render_grid_line(gd: *T.Grid, row: u32, keep_spaces: bool, escape_sequences: bool) []u8 {
    return grid_mod.string_cells(gd, row, gd.sx, .{
        .trim_trailing_spaces = !keep_spaces,
        .escape_sequences = escape_sequences,
    });
}

pub const entry: cmd_mod.CmdEntry = .{
    .name = "capture-pane",
    .alias = "capturep",
    .usage = "[-CJNpq] [-b buffer-name] [-E end-line] [-S start-line] [-t target-pane]",
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

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    const captured = capture_grid(wp.base.grid, null, null, false, false, false, &item).?;
    defer xm.allocator.free(captured);
    try std.testing.expectEqualStrings("hello\nworld\n", captured[0..12]);
}

test "capture-pane helper supports line bounds and octal escapes" {
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

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    const captured = capture_grid(wp.base.grid, "1", "1", false, false, true, &item).?;
    defer xm.allocator.free(captured);
    try std.testing.expectEqualStrings("\\134x\n", captured);
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

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    const visible = capture_grid(screen_mod.screen_current(wp).grid, "0", "2", false, false, false, &item).?;
    defer xm.allocator.free(visible);
    try std.testing.expectEqualStrings("ALT\n\n\n", visible);

    const primary = capture_grid(wp.base.grid, "0", "2", false, false, false, &item).?;
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

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    const captured = capture_grid(screen.grid, "0", "0", false, false, false, &item).?;
    defer xm.allocator.free(captured);

    try std.testing.expectEqualStrings("é🙂\n", captured);
}
