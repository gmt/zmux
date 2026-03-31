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
// Ported in part from tmux/cmd-display-panes.c.
// Original copyright:
//   Copyright (c) 2009 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence - same terms as above.

const std = @import("std");
const T = @import("types.zig");
const args_mod = @import("arguments.zig");
const c = @import("c.zig");
const cmd_mod = @import("cmd.zig");
const cmdq = @import("cmd-queue.zig");
const opts = @import("options.zig");
const popup = @import("popup.zig");
const proc_mod = @import("proc.zig");
const server = @import("server.zig");
const status_runtime = @import("status-runtime.zig");
const win = @import("window.zig");
const window_clock = @import("window-clock.zig");
const xm = @import("xmalloc.zig");

const DEFAULT_COMMAND_TEMPLATE = "select-pane -t \"%%%\"";

const DisplayPanesState = struct {
    item: ?*cmdq.CmdqItem = null,
    command_template: []u8,
    ignore_keys: bool = false,
};

pub fn overlay_active(client: *const T.Client) bool {
    return client.display_panes_data != null;
}

fn overlay_state(client: *const T.Client) ?*DisplayPanesState {
    const ptr = client.display_panes_data orelse return null;
    return @ptrCast(@alignCast(ptr));
}

pub fn clear_overlay(client: *T.Client) void {
    const state = overlay_state(client) orelse return;

    if (client.display_panes_timer) |ev| {
        _ = c.libevent.event_del(ev);
        c.libevent.event_free(ev);
        client.display_panes_timer = null;
    }

    client.display_panes_data = null;
    client.tty.flags &= ~@as(i32, @intCast(T.TTY_NOCURSOR | T.TTY_FREEZE));
    client.flags |= T.CLIENT_REDRAWOVERLAY;

    if (state.item) |item| cmdq.cmdq_continue(item);
    xm.allocator.free(state.command_template);
    xm.allocator.destroy(state);
}

fn start_overlay(
    client: *T.Client,
    delay_ms: u32,
    command_template: []const u8,
    item: ?*cmdq.CmdqItem,
    ignore_keys: bool,
) void {
    clear_overlay(client);

    const state = xm.allocator.create(DisplayPanesState) catch unreachable;
    state.* = .{
        .item = item,
        .command_template = xm.xstrdup(command_template),
        .ignore_keys = ignore_keys,
    };
    client.display_panes_data = state;
    client.tty.flags |= @intCast(T.TTY_FREEZE | T.TTY_NOCURSOR);
    client.flags |= T.CLIENT_REDRAWOVERLAY;

    if (delay_ms == 0) return;
    const base = proc_mod.libevent orelse return;
    const ev = c.libevent.event_new(
        base,
        -1,
        @intCast(c.libevent.EV_TIMEOUT),
        display_panes_timer_cb,
        client,
    ) orelse return;
    client.display_panes_timer = ev;

    var tv = std.posix.timeval{
        .sec = @divTrunc(delay_ms, 1000),
        .usec = @mod(delay_ms, 1000) * 1000,
    };
    _ = c.libevent.event_add(ev, @ptrCast(&tv));
}

export fn display_panes_timer_cb(_fd: c_int, _events: c_short, arg: ?*anyopaque) void {
    _ = _fd;
    _ = _events;
    const client: *T.Client = @ptrCast(@alignCast(arg orelse return));
    clear_overlay(client);
}

pub fn handle_key(client: *T.Client, event: *T.key_event) bool {
    const state = overlay_state(client) orelse return false;
    if (state.ignore_keys) {
        clear_overlay(client);
        return false;
    }

    const pane_index = pane_index_from_key(event) orelse {
        clear_overlay(client);
        return false;
    };

    const session = client.session orelse {
        clear_overlay(client);
        return true;
    };
    const wl = session.curw orelse {
        clear_overlay(client);
        return true;
    };
    const wp = win.window_pane_at_index(wl.window, pane_index) orelse {
        clear_overlay(client);
        return true;
    };

    queue_pane_command(client, state, wp);
    clear_overlay(client);
    return true;
}

fn pane_index_from_key(event: *const T.key_event) ?usize {
    if (event.key >= '0' and event.key <= '9')
        return @intCast(event.key - '0');

    if ((event.key & T.KEYC_MASK_MODIFIERS) != 0) return null;
    const key = event.key & T.KEYC_MASK_KEY;
    if (key < 'a' or key > 'z') return null;
    return 10 + @as(usize, @intCast(key - 'a'));
}

fn queue_pane_command(client: *T.Client, state: *DisplayPanesState, wp: *T.WindowPane) void {
    const pane_target = std.fmt.allocPrint(xm.allocator, "%{d}", .{wp.id}) catch unreachable;
    defer xm.allocator.free(pane_target);

    const expanded = template_replace(state.command_template, pane_target, 1);
    defer xm.allocator.free(expanded);

    var pi = T.CmdParseInput{
        .c = client,
        .fs = if (state.item) |item| cmdq.cmdq_get_target(item) else current_find_state(client),
        .item = if (state.item) |item| @ptrCast(item) else null,
    };
    const parsed = cmd_mod.cmd_parse_from_string(expanded, &pi);
    switch (parsed.status) {
        .success => {
            const cmdlist: *cmd_mod.CmdList = @ptrCast(@alignCast(parsed.cmdlist.?));
            if (state.item) |item| {
                _ = cmdq.cmdq_insert_after(item, cmdq.cmdq_get_command(@ptrCast(cmdlist), cmdq.cmdq_get_state(item)));
            } else {
                cmdq.cmdq_append(client, cmdlist);
            }
        },
        .@"error" => {
            const err = parsed.@"error" orelse xm.xstrdup("parse error");
            defer xm.allocator.free(err);
            if (state.item) |item|
                cmdq.cmdq_error(item, "{s}", .{err})
            else
                status_runtime.present_client_message(client, err);
        },
    }
}

fn current_find_state(client: *T.Client) T.CmdFindState {
    const session = client.session;
    const wl = if (session) |s| s.curw else null;
    const window = if (wl) |link| link.window else null;
    const pane = if (window) |w| w.active else null;
    return .{
        .s = session,
        .wl = wl,
        .w = window,
        .wp = pane,
        .idx = if (wl) |link| link.idx else -1,
    };
}

fn template_replace(template: []const u8, replacement: []const u8, idx: usize) []u8 {
    if (std.mem.indexOfScalar(u8, template, '%') == null) return xm.xstrdup(template);

    var out: std.ArrayList(u8) = .{};
    defer out.deinit(xm.allocator);

    var i: usize = 0;
    var replaced = false;
    while (i < template.len) {
        if (template[i] != '%') {
            out.append(xm.allocator, template[i]) catch unreachable;
            i += 1;
            continue;
        }

        if (i + 1 >= template.len) {
            out.append(xm.allocator, '%') catch unreachable;
            i += 1;
            continue;
        }

        const next = template[i + 1];
        const matches_idx = next >= '1' and next <= '9' and (next - '0') == idx;
        const matches_escaped = next == '%' and !replaced;
        if (!matches_idx and !matches_escaped) {
            out.append(xm.allocator, '%') catch unreachable;
            i += 1;
            continue;
        }

        i += 2;
        var quoted = false;
        if (i < template.len and template[i] == '%') {
            quoted = true;
            i += 1;
        }
        if (matches_escaped) replaced = true;

        for (replacement) |ch| {
            if (quoted and std.mem.indexOfScalar(u8, "\"\\$;~", ch) != null)
                out.append(xm.allocator, '\\') catch unreachable;
            out.append(xm.allocator, ch) catch unreachable;
        }
    }

    return out.toOwnedSlice(xm.allocator) catch unreachable;
}

pub fn render_overlay_payload(client: *T.Client, tty_sx: u32, pane_area_sy: u32, row_offset: u32) !?[]u8 {
    return render_overlay_payload_region(client, 0, 0, tty_sx, pane_area_sy, row_offset);
}

pub fn render_overlay_payload_region(
    client: *T.Client,
    view_x: u32,
    view_y: u32,
    tty_sx: u32,
    pane_area_sy: u32,
    row_offset: u32,
) !?[]u8 {
    if (!overlay_active(client) or tty_sx == 0 or pane_area_sy == 0) return null;

    const session = client.session orelse return null;
    const wl = session.curw orelse return null;
    const w = wl.window;

    const colour: i32 = @intCast(opts.options_get_number(session.options, "display-panes-colour"));
    const active_colour: i32 = @intCast(opts.options_get_number(session.options, "display-panes-active-colour"));

    var out: std.ArrayList(u8) = .{};
    errdefer out.deinit(xm.allocator);

    for (w.panes.items) |wp| {
        if (!win.window_pane_visible(wp)) continue;
        const bounds = clipped_bounds_region(win.window_pane_draw_bounds(wp), view_x, view_y, tty_sx, pane_area_sy) orelse continue;
        const pane_index = win.window_pane_index(w, wp) orelse continue;
        const pane_colour = if (w.active == wp) active_colour else colour;
        try append_pane_overlay(&out, bounds, row_offset, pane_index, wp.sx, wp.sy, pane_colour);
    }

    if (out.items.len == 0) return null;
    try out.appendSlice(xm.allocator, "\x1b[0m");
    return try out.toOwnedSlice(xm.allocator);
}

const ClippedBounds = struct {
    xoff: u32,
    yoff: u32,
    sx: u32,
    sy: u32,
};

fn clipped_bounds_region(bounds: win.PaneDrawBounds, view_x: u32, view_y: u32, max_sx: u32, max_sy: u32) ?ClippedBounds {
    const start_x = @max(bounds.xoff, view_x);
    const start_y = @max(bounds.yoff, view_y);
    const end_x = @min(bounds.xoff + bounds.sx, view_x + max_sx);
    const end_y = @min(bounds.yoff + bounds.sy, view_y + max_sy);
    if (start_x >= end_x or start_y >= end_y) return null;
    const sx = end_x - start_x;
    const sy = end_y - start_y;
    if (sx == 0 or sy == 0) return null;
    return .{
        .xoff = start_x - view_x,
        .yoff = start_y - view_y,
        .sx = sx,
        .sy = sy,
    };
}

/// Render a pane number/label overlay onto `out`.
/// Mirrors tmux cmd_display_panes_draw_pane(): large digit art when the pane
/// is wide enough (sx >= digit_count*6, sy >= 5), else small text fallback.
fn append_pane_overlay(
    out: *std.ArrayList(u8),
    bounds: ClippedBounds,
    row_offset: u32,
    pane_index: usize,
    pane_sx: u32,
    pane_sy: u32,
    colour: i32,
) !void {
    var num_buf: [16]u8 = undefined;
    const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{pane_index}) catch unreachable;
    const digit_count: u32 = @intCast(num_str.len);

    var lbuf: [4]u8 = undefined;
    const llen: u32 = if (pane_index > 9 and pane_index < 35) blk: {
        lbuf[0] = @as(u8, @intCast('a' + (pane_index - 10)));
        break :blk 1;
    } else 0;

    var size_buf: [16]u8 = undefined;
    const size_str = std.fmt.bufPrint(&size_buf, "{d}x{d}", .{ pane_sx, pane_sy }) catch unreachable;
    const rlen: u32 = @intCast(size_str.len);

    if (bounds.sx < digit_count) return;

    // ── Large digit art path ─────────────────────────────────────────────
    if (bounds.sx >= digit_count * 6 and bounds.sy >= 5) {
        // Centre the digit block.  Each digit is 5 cols wide + 1 gap = 6.
        // py: top of the 5-row digit block centred vertically.
        var px: u32 = bounds.sx / 2;
        if (px >= digit_count * 3) px -= digit_count * 3 else px = 0;
        var py: u32 = bounds.sy / 2;
        if (py >= 2) py -= 2 else py = 0;

        // Draw filled blocks using background colour.
        try append_sgr(out, null, colour);
        for (num_str) |ch| {
            if (ch < '0' or ch > '9') continue;
            const idx: usize = @intCast(ch - '0');
            for (0..5) |j| {
                for (0..5) |i| {
                    if (window_clock.window_clock_table[idx][j][i] == 0) continue;
                    const col = bounds.xoff + px + @as(u32, @intCast(i));
                    const row = bounds.yoff + py + @as(u32, @intCast(j));
                    try append_move(out, row_offset + row + 1, col + 1);
                    try out.append(xm.allocator, ' ');
                }
            }
            px += 6;
        }

        if (bounds.sy <= 6) return;

        // Size string at top-right corner in foreground colour.
        try append_sgr(out, colour, null);
        if (rlen != 0 and bounds.sx >= rlen) {
            const rx = bounds.xoff + bounds.sx - rlen;
            try append_move(out, row_offset + bounds.yoff + 1, rx + 1);
            try out.appendSlice(xm.allocator, size_str);
        }

        // Letter label below the digit art.
        // C formula: xoff + sx/2 + len*3 - llen - 1, yoff + py + 5
        if (llen != 0) {
            const half_sx = bounds.sx / 2;
            const lx = bounds.xoff + half_sx + digit_count * 3 - llen - 1;
            const ly = bounds.yoff + py + 5;
            try append_move(out, row_offset + ly + 1, lx + 1);
            try out.appendSlice(xm.allocator, lbuf[0..llen]);
        }

        return;
    }

    // ── Small text fallback ──────────────────────────────────────────────
    // Show "N" or "N a" centred, and size text if there is room.
    const cx = bounds.sx / 2;
    const cy = bounds.sy / 2;

    try append_sgr(out, colour, null);
    if (bounds.sx >= digit_count + llen + 1 and llen != 0) {
        const total = digit_count + 1 + llen;
        const x = bounds.xoff + (if (cx >= total / 2) cx - total / 2 else 0);
        try append_move(out, row_offset + bounds.yoff + cy + 1, x + 1);
        try out.appendSlice(xm.allocator, num_str);
        try out.append(xm.allocator, ' ');
        try out.appendSlice(xm.allocator, lbuf[0..llen]);
    } else {
        const x = bounds.xoff + (if (cx >= digit_count / 2) cx - digit_count / 2 else 0);
        try append_move(out, row_offset + bounds.yoff + cy + 1, x + 1);
        try out.appendSlice(xm.allocator, num_str);
    }
}

fn append_move(out: *std.ArrayList(u8), row: u32, col: u32) !void {
    const seq = try std.fmt.allocPrint(xm.allocator, "\x1b[{d};{d}H", .{ row, col });
    defer xm.allocator.free(seq);
    try out.appendSlice(xm.allocator, seq);
}

fn append_sgr(out: *std.ArrayList(u8), fg: ?i32, bg: ?i32) !void {
    try out.appendSlice(xm.allocator, "\x1b[0");
    if (fg) |colour| try append_colour_code(out, colour, false);
    if (bg) |colour| try append_colour_code(out, colour, true);
    try out.append(xm.allocator, 'm');
}

fn append_colour_code(out: *std.ArrayList(u8), colour: i32, background: bool) !void {
    const code = if (colour >= 0 and colour < 8)
        @as(i32, if (background) 40 else 30) + colour
    else if (colour >= 8 and colour < 16)
        @as(i32, if (background) 100 else 90) + (colour - 8)
    else
        return;

    const seq = try std.fmt.allocPrint(xm.allocator, ";{d}", .{code});
    defer xm.allocator.free(seq);
    try out.appendSlice(xm.allocator, seq);
}

fn exec(cmd: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {
    const args = cmd_mod.cmd_get_args(cmd);
    const target_client = cmdq.cmdq_get_target_client(item) orelse {
        cmdq.cmdq_error(item, "no target client", .{});
        return .@"error";
    };
    const session = target_client.session orelse {
        cmdq.cmdq_error(item, "no target client", .{});
        return .@"error";
    };

    if (overlay_active(target_client) or popup.overlay_active(target_client)) return .normal;

    var delay_ms: u32 = @intCast(opts.options_get_number(session.options, "display-panes-time"));
    if (args.has('d')) {
        var cause: ?[]u8 = null;
        const parsed = args_mod.args_strtonum(args, 'd', 0, std.math.maxInt(u32), &cause);
        if (cause) |msg| {
            defer xm.allocator.free(msg);
            cmdq.cmdq_error(item, "delay {s}", .{msg});
            return .@"error";
        }
        delay_ms = @intCast(parsed);
    }

    start_overlay(
        target_client,
        delay_ms,
        args.value_at(0) orelse DEFAULT_COMMAND_TEMPLATE,
        if (args.has('b')) null else item,
        args.has('N'),
    );

    return if (args.has('b')) .normal else .wait;
}

pub const entry: cmd_mod.CmdEntry = .{
    .name = "display-panes",
    .alias = "displayp",
    .usage = "[-bN] [-d duration] [-t target-client] [template]",
    .template = "bd:Nt:",
    .lower = 0,
    .upper = 1,
    .flags = T.CMD_AFTERHOOK | T.CMD_CLIENT_TFLAG,
    .exec = exec,
};

fn test_setup(name: []const u8) struct {
    session: *T.Session,
    window: *T.Window,
    source_client: T.Client,
    target_client: T.Client,
} {
    const env_mod = @import("environ.zig");
    const opts_mod = @import("options.zig");
    const sess = @import("session.zig");

    sess.session_init_globals(xm.allocator);
    win.window_init_globals(xm.allocator);

    opts_mod.global_options = opts_mod.options_create(null);
    opts_mod.options_default_all(opts_mod.global_options, T.OPTIONS_TABLE_SERVER);
    opts_mod.global_s_options = opts_mod.options_create(null);
    opts_mod.options_default_all(opts_mod.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts_mod.global_w_options = opts_mod.options_create(null);
    opts_mod.options_default_all(opts_mod.global_w_options, T.OPTIONS_TABLE_WINDOW);

    env_mod.global_environ = env_mod.environ_create();

    const session = sess.session_create(null, name, "/", env_mod.environ_create(), opts_mod.options_create(opts_mod.global_s_options), null);
    const window = win.window_create(80, 24, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    var attach_cause: ?[]u8 = null;
    const wl = sess.session_attach(session, window, -1, &attach_cause).?;
    session.curw = wl;
    const first = win.window_add_pane(window, null, 80, 24);
    window.active = first;

    var source_client = T.Client{
        .name = xm.xstrdup("source"),
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{},
        .flags = T.CLIENT_ATTACHED,
        .session = session,
    };
    source_client.tty.client = &source_client;
    source_client.tty.sx = 80;
    source_client.tty.sy = 24;

    var target_client = T.Client{
        .name = xm.xstrdup("target"),
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{},
        .flags = T.CLIENT_ATTACHED,
        .session = session,
    };
    target_client.tty.client = &target_client;
    target_client.tty.sx = 80;
    target_client.tty.sy = 24;

    return .{
        .session = session,
        .window = window,
        .source_client = source_client,
        .target_client = target_client,
    };
}

fn test_teardown(setup: *@TypeOf(test_setup("unused"))) void {
    const client_registry = @import("client-registry.zig");
    const env_mod = @import("environ.zig");
    const opts_mod = @import("options.zig");
    const sess = @import("session.zig");

    clear_overlay(&setup.source_client);
    clear_overlay(&setup.target_client);
    client_registry.remove(&setup.source_client);
    client_registry.remove(&setup.target_client);

    env_mod.environ_free(setup.source_client.environ);
    env_mod.environ_free(setup.target_client.environ);
    if (setup.source_client.name) |name| xm.allocator.free(@constCast(name));
    if (setup.target_client.name) |name| xm.allocator.free(@constCast(name));

    if (sess.session_find(setup.session.name) != null) sess.session_destroy(setup.session, false, "test");
    win.window_remove_ref(setup.window, "test");
    env_mod.environ_free(env_mod.global_environ);
    opts_mod.options_free(opts_mod.global_options);
    opts_mod.options_free(opts_mod.global_s_options);
    opts_mod.options_free(opts_mod.global_w_options);
}

test "display-panes uses the target client overlay and waits by default" {
    const client_registry = @import("client-registry.zig");

    var setup = test_setup("display-panes-target-client");
    defer test_teardown(&setup);
    client_registry.add(&setup.source_client);
    client_registry.add(&setup.target_client);

    var parse_cause: ?[]u8 = null;
    const display_cmd = try cmd_mod.cmd_parse_one(&.{ "display-panes", "-t", "target", "-d", "0" }, null, &parse_cause);
    defer cmd_mod.cmd_free(display_cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &setup.source_client, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.wait, cmd_mod.cmd_execute(display_cmd, &item));
    try std.testing.expect(!overlay_active(&setup.source_client));
    try std.testing.expect(overlay_active(&setup.target_client));
}

test "display-panes background mode leaves the queue running" {
    var setup = test_setup("display-panes-background");
    defer test_teardown(&setup);

    var parse_cause: ?[]u8 = null;
    const display_cmd = try cmd_mod.cmd_parse_one(&.{ "display-panes", "-b", "-d", "0" }, null, &parse_cause);
    defer cmd_mod.cmd_free(display_cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &setup.target_client, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(display_cmd, &item));
    try std.testing.expect(overlay_active(&setup.target_client));
}

test "display-panes timer clears the overlay" {
    const os_mod = @import("os/linux.zig");

    const old_base = proc_mod.libevent;
    proc_mod.libevent = os_mod.osdep_event_init();
    defer {
        if (proc_mod.libevent) |base| c.libevent.event_base_free(base);
        proc_mod.libevent = old_base;
    }

    var setup = test_setup("display-panes-timer");
    defer test_teardown(&setup);

    var parse_cause: ?[]u8 = null;
    const display_cmd = try cmd_mod.cmd_parse_one(&.{ "display-panes", "-d", "5" }, null, &parse_cause);
    defer cmd_mod.cmd_free(display_cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &setup.target_client, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.wait, cmd_mod.cmd_execute(display_cmd, &item));
    try std.testing.expect(overlay_active(&setup.target_client));

    std.Thread.sleep(20 * std.time.ns_per_ms);
    _ = c.libevent.event_loop(c.libevent.EVLOOP_ONCE);
    try std.testing.expect(!overlay_active(&setup.target_client));
}

test "display-panes key selection runs the default select-pane command" {
    var setup = test_setup("display-panes-key-select");
    defer test_teardown(&setup);

    _ = win.window_add_pane(setup.window, null, 80, 24);

    var parse_cause: ?[]u8 = null;
    const display_cmd = try cmd_mod.cmd_parse_one(&.{ "display-panes", "-b", "-d", "0" }, null, &parse_cause);
    defer cmd_mod.cmd_free(display_cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &setup.target_client, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(display_cmd, &item));
    try std.testing.expect(overlay_active(&setup.target_client));

    var event = T.key_event{ .key = '1', .data = std.mem.zeroes([16]u8), .len = 1 };
    event.data[0] = '1';
    try std.testing.expect(handle_key(&setup.target_client, &event));
    try std.testing.expect(!overlay_active(&setup.target_client));

    _ = cmdq.cmdq_next(&setup.target_client);
    try std.testing.expectEqual(setup.window.panes.items[1], setup.window.active.?);
}

test "display-panes overlay renders centered pane labels" {
    var setup = test_setup("display-panes-render");
    defer test_teardown(&setup);

    var parse_cause: ?[]u8 = null;
    const display_cmd = try cmd_mod.cmd_parse_one(&.{ "display-panes", "-b", "-d", "0" }, null, &parse_cause);
    defer cmd_mod.cmd_free(display_cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &setup.target_client, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(display_cmd, &item));

    const payload = (try render_overlay_payload(&setup.target_client, 80, 24, 0)).?;
    defer xm.allocator.free(payload);
    try std.testing.expect(std.mem.indexOf(u8, payload, " 0 ") == null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "80x24") != null);
}
