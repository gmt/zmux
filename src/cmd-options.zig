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
// Ported in part from tmux/cmd-set-option.c and tmux/cmd-show-options.c.
// Original copyright:
//   Copyright (c) 2007 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const cmdq = @import("cmd-queue.zig");
const cmd_find = @import("cmd-find.zig");
const opts = @import("options.zig");

pub const ScopeKind = enum {
    server,
    session,
    window,
    pane,
};

pub const ResolvedTarget = struct {
    kind: ScopeKind,
    options: *T.Options,
    global: bool,
    session: ?*T.Session = null,
    winlink: ?*T.Winlink = null,
    window: ?*T.Window = null,
    pane: ?*T.WindowPane = null,
};

pub fn resolve_target(
    item: *cmdq.CmdqItem,
    args: *const @import("arguments.zig").Arguments,
    window_default: bool,
) ?ResolvedTarget {
    const kind = requested_scope(args, window_default);
    switch (kind) {
        .server => return .{ .kind = .server, .options = opts.global_options, .global = true },
        .session => {
            if (args.has('g')) return .{ .kind = .session, .options = opts.global_s_options, .global = true };
            var target: T.CmdFindState = .{};
            if (cmd_find.cmd_find_target(&target, item, args.get('t'), .session, T.CMD_FIND_QUIET) != 0 or target.s == null) {
                if (args.get('t')) |tflag|
                    cmdq.cmdq_error(item, "no such session: {s}", .{tflag})
                else
                    cmdq.cmdq_error(item, "no current session", .{});
                return null;
            }
            return .{
                .kind = .session,
                .options = target.s.?.options,
                .global = false,
                .session = target.s,
                .winlink = target.wl,
                .window = target.w,
                .pane = target.wp,
            };
        },
        .window => {
            if (args.has('g')) return .{ .kind = .window, .options = opts.global_w_options, .global = true };
            var target: T.CmdFindState = .{};
            if (cmd_find.cmd_find_target(&target, item, args.get('t'), .window, T.CMD_FIND_QUIET) != 0 or target.w == null) {
                if (args.get('t')) |tflag|
                    cmdq.cmdq_error(item, "can't find target: {s}", .{tflag})
                else
                    cmdq.cmdq_error(item, "no current window", .{});
                return null;
            }
            return .{
                .kind = .window,
                .options = target.w.?.options,
                .global = false,
                .session = target.s,
                .winlink = target.wl,
                .window = target.w,
                .pane = target.wp,
            };
        },
        .pane => {
            if (args.has('g')) {
                cmdq.cmdq_error(item, "global pane options not supported yet", .{});
                return null;
            }

            var target: T.CmdFindState = .{};
            if (cmd_find.cmd_find_target(&target, item, args.get('t'), .pane, T.CMD_FIND_QUIET) != 0 or target.wp == null) {
                if (args.get('t')) |tflag|
                    cmdq.cmdq_error(item, "can't find target: {s}", .{tflag})
                else
                    cmdq.cmdq_error(item, "no current pane", .{});
                return null;
            }
            return .{
                .kind = .pane,
                .options = target.wp.?.options,
                .global = false,
                .session = target.s,
                .winlink = target.wl,
                .window = target.w,
                .pane = target.wp.?,
            };
        },
    }
}

pub fn option_allowed(oe: ?*const T.OptionsTableEntry, kind: ScopeKind) bool {
    if (oe == null) return true;
    const scope = switch (kind) {
        .server => T.OPTIONS_TABLE_SERVER,
        .session => T.OPTIONS_TABLE_SESSION,
        .window => T.OPTIONS_TABLE_WINDOW,
        .pane => T.OPTIONS_TABLE_PANE,
    };
    return opts.options_scope_has(scope, oe.?);
}

pub fn is_custom_option(name: []const u8) bool {
    return name.len > 0 and name[0] == '@';
}

pub fn collect_lines(target: ResolvedTarget, name: ?[]const u8, values_only: bool) [][]u8 {
    if (name) |single_name| {
        return collect_single(target, single_name, values_only);
    }

    var lines: std.ArrayList([]u8) = .{};
    for (@import("options-table.zig").options_table) |*oe| {
        if (!option_allowed(oe, target.kind)) continue;
        const value = opts.options_get(target.options, oe.name) orelse continue;
        append_lines(&lines, oe.name, value, oe, values_only);
    }
    append_custom_lines(&lines, target, values_only);
    return lines.toOwnedSlice(xm.allocator) catch unreachable;
}

fn collect_single(target: ResolvedTarget, name: []const u8, values_only: bool) [][]u8 {
    const value = opts.options_get(target.options, name) orelse return &.{};
    var lines: std.ArrayList([]u8) = .{};
    append_lines(&lines, name, value, opts.options_table_entry(name), values_only);
    return lines.toOwnedSlice(xm.allocator) catch unreachable;
}

fn append_custom_lines(lines: *std.ArrayList([]u8), target: ResolvedTarget, values_only: bool) void {
    var names: std.ArrayList([]const u8) = .{};
    defer names.deinit(xm.allocator);

    var it = target.options.entries.keyIterator();
    while (it.next()) |name| {
        if (!is_custom_option(name.*)) continue;
        names.append(xm.allocator, name.*) catch unreachable;
    }
    std.sort.block([]const u8, names.items, {}, less_than_string);
    for (names.items) |name| {
        const value = target.options.entries.getPtr(name).?;
        append_lines(lines, name, value, null, values_only);
    }
}

fn append_lines(
    lines: *std.ArrayList([]u8),
    name: []const u8,
    value: *const T.OptionsValue,
    oe: ?*const T.OptionsTableEntry,
    values_only: bool,
) void {
    switch (value.*) {
        .array => |arr| {
            if (arr.items.len == 0) {
                if (!values_only) lines.append(xm.allocator, xm.xstrdup(name)) catch unreachable;
                return;
            }
            for (arr.items, 0..) |item, idx| {
                const line = if (values_only)
                    xm.xstrdup(item)
                else
                    xm.xasprintf("{s}[{d}] {s}", .{ name, idx, item });
                lines.append(xm.allocator, line) catch unreachable;
            }
        },
        else => {
            const rendered = opts.options_value_to_string(name, value, oe);
            defer xm.allocator.free(rendered);
            const line = if (values_only)
                xm.xstrdup(rendered)
            else
                xm.xasprintf("{s} {s}", .{ name, rendered });
            lines.append(xm.allocator, line) catch unreachable;
        },
    }
}

fn requested_scope(args: *const @import("arguments.zig").Arguments, window_default: bool) ScopeKind {
    if (args.has('s')) return .server;
    if (args.has('p')) return .pane;
    if (args.has('w')) return .window;
    return if (window_default) .window else .session;
}

fn less_than_string(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

test "resolve_target and collect_lines support pane scoped options" {
    const cmd_mod = @import("cmd.zig");
    const sess = @import("session.zig");
    const win = @import("window.zig");
    const env_mod = @import("environ.zig");

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

    const session_opts = opts.options_create(opts.global_s_options);
    const session_env = env_mod.environ_create();
    const s = sess.session_create(null, "pane-show", "/", session_env, session_opts, null);
    defer sess.session_destroy(s, false, "test");

    const w = win.window_create(80, 24, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    var attach_cause: ?[]u8 = null;
    _ = sess.session_attach(s, w, -1, &attach_cause).?;
    const wp = win.window_add_pane(w, null, 80, 24);
    w.active = wp;
    s.curw = sess.winlink_find_by_window(&s.windows, w).?;

    opts.options_set_string(wp.options, false, "@pane-note", "active");
    const target = xm.xasprintf("%{d}", .{wp.id});
    defer xm.allocator.free(target);

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "show-options", "-p", "-t", target, "@pane-note" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    const resolved = resolve_target(&item, cmd_mod.cmd_get_args(cmd), false).?;
    try std.testing.expectEqual(wp, resolved.pane.?);

    const lines = collect_lines(resolved, "@pane-note", false);
    defer {
        for (lines) |line| xm.allocator.free(line);
        xm.allocator.free(lines);
    }
    try std.testing.expectEqual(@as(usize, 1), lines.len);
    try std.testing.expectEqualStrings("@pane-note active", lines[0]);
}
