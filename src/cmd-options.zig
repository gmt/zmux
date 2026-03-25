// Copyright (c) 2026 Greg Turner <gmt@pobox.com>
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//
// 1. Redistributions of source code must retain the above copyright notice,
//    this list of conditions and the following disclaimer.
// 2. Redistributions in binary form must reproduce the above copyright notice,
//    this list of conditions and the following disclaimer in the documentation
//    and/or other materials provided with the distribution.
// 3. Neither the name of the copyright holder nor the names of its
//    contributors may be used to endorse or promote products derived from
//    this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
// ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
// LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
// POSSIBILITY OF SUCH DAMAGE.
//
// Ported in part from tmux/cmd-set-option.c and tmux/cmd-show-options.c.

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
            return .{ .kind = .session, .options = target.s.?.options, .global = false };
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
            return .{ .kind = .window, .options = target.w.?.options, .global = false };
        },
        .pane => {
            cmdq.cmdq_error(item, "pane options not supported yet", .{});
            return null;
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
