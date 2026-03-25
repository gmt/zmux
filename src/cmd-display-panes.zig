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
//   ISC licence – same terms as above.

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const cmd_mod = @import("cmd.zig");
const cmdq = @import("cmd-queue.zig");
const cmd_find = @import("cmd-find.zig");
const cmd_display = @import("cmd-display-message.zig");
const win = @import("window.zig");

const DEFAULT_TEMPLATE = "#{pane_index}: #{pane_width}x#{pane_height} pid=#{pane_pid}#{pane_title}";

fn exec(cmd: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {
    const args = cmd_mod.cmd_get_args(cmd);
    if (args.has('b')) {
        cmdq.cmdq_error(item, "background pane display not supported yet", .{});
        return .@"error";
    }
    if (args.has('d')) {
        cmdq.cmdq_error(item, "overlay delay not supported yet", .{});
        return .@"error";
    }
    if (args.get('t') != null) {
        cmdq.cmdq_error(item, "target client selection not supported yet", .{});
        return .@"error";
    }

    var target: T.CmdFindState = .{};
    if (cmd_find.cmd_find_target(&target, item, null, .window, 0) != 0)
        return .@"error";
    const s = target.s orelse return .@"error";
    const wl = target.wl orelse return .@"error";
    const w = wl.window;
    const template = args.value_at(0) orelse DEFAULT_TEMPLATE;

    for (w.panes.items, 0..) |wp, idx| {
        const line = render_pane_line(template, args.value_at(0) != null, s, wl, wp, idx);
        defer xm.allocator.free(line);
        cmdq.cmdq_print(item, "{s}", .{line});
    }
    return .normal;
}

fn render_pane_line(
    template: []const u8,
    custom_template: bool,
    s: *T.Session,
    wl: *T.Winlink,
    wp: *T.WindowPane,
    pane_index: usize,
) []u8 {
    if (custom_template) {
        var state = T.CmdFindState{
            .s = s,
            .wl = wl,
            .w = wl.window,
            .wp = wp,
            .idx = wl.idx,
        };
        return cmd_display.expand_format(xm.allocator, template, &state);
    }

    if (wp.screen.title) |title| {
        return xm.xasprintf("{d}: {d}x{d} pid={d} {s}{s}", .{
            pane_index,
            wp.sx,
            wp.sy,
            wp.pid,
            if (wl.window.active == wp) "[active] " else "",
            title,
        });
    }
    return xm.xasprintf("{d}: {d}x{d} pid={d}{s}", .{
        pane_index,
        wp.sx,
        wp.sy,
        wp.pid,
        if (wl.window.active == wp) " [active]" else "",
    });
}

pub const entry: cmd_mod.CmdEntry = .{
    .name = "display-panes",
    .alias = "displayp",
    .usage = "[-N] [template]",
    .template = "bd:Nt:",
    .lower = 0,
    .upper = 1,
    .flags = T.CMD_READONLY,
    .exec = exec,
};

test "display-panes default rendering summarizes pane state" {
    const opts = @import("options.zig");
    const env_mod = @import("environ.zig");
    const sess = @import("session.zig");
    const spawn = @import("spawn.zig");

    sess.session_init_globals(xm.allocator);
    win.window_init_globals(xm.allocator);

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

    const s = sess.session_create(null, "display-panes-test", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("display-panes-test") != null) sess.session_destroy(s, false, "test");

    var cause: ?[]u8 = null;
    var ctx: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const wl = spawn.spawn_window(&ctx, &cause).?;
    var second_ctx: T.SpawnContext = .{ .s = s, .wl = wl, .flags = T.SPAWN_EMPTY };
    const second = spawn.spawn_pane(&second_ctx, &cause).?;
    _ = second;
    s.curw = wl;

    wl.window.active.?.screen.title = xm.xstrdup("shell");

    const line = render_pane_line(DEFAULT_TEMPLATE, false, s, wl, wl.window.active.?, 0);
    defer xm.allocator.free(line);
    try std.testing.expectEqualStrings("0: 80x24 pid=-1 [active] shell", line);
}

test "display-panes template rendering uses pane placeholders" {
    const opts = @import("options.zig");
    const env_mod = @import("environ.zig");
    const sess = @import("session.zig");
    const spawn = @import("spawn.zig");

    sess.session_init_globals(xm.allocator);
    win.window_init_globals(xm.allocator);

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

    const s = sess.session_create(null, "display-panes-template", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("display-panes-template") != null) sess.session_destroy(s, false, "test");

    var cause: ?[]u8 = null;
    var ctx: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const wl = spawn.spawn_window(&ctx, &cause).?;
    s.curw = wl;
    wl.window.active.?.screen.title = xm.xstrdup("logs");

    const rendered = render_pane_line("#{pane_index}:#{pane_width}x#{pane_height}:#{pane_title}", true, s, wl, wl.window.active.?, 0);
    defer xm.allocator.free(rendered);
    try std.testing.expectEqualStrings("0:80x24:logs", rendered);
}

test "display-panes rejects unsupported target client selection" {
    var parse_cause: ?[]u8 = null;
    const display_cmd = try cmd_mod.cmd_parse_one(&.{ "display-panes", "-t", "client" }, null, &parse_cause);
    defer cmd_mod.cmd_free(display_cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.@"error", cmd_mod.cmd_execute(display_cmd, &item));
}
