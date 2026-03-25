// Copyright (c) 2026 Greg Turner <gmt@pobox.com>
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
// Ported in part from tmux/format.c.
// Original copyright:
//   Copyright (c) 2011 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

//! format.zig – reduced shared tmux-style format expansion.

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const key_string = @import("key-string.zig");
const names = @import("names.zig");
const sess = @import("session.zig");

pub const FormatContext = struct {
    item: ?*anyopaque = null,
    client: ?*T.Client = null,
    session: ?*T.Session = null,
    winlink: ?*T.Winlink = null,
    window: ?*T.Window = null,
    pane: ?*T.WindowPane = null,

    message_text: ?[]const u8 = null,

    key_binding: ?*const T.KeyBinding = null,
    key_note: ?[]const u8 = null,
    key_command: ?[]const u8 = null,
    key_padding: ?[]const u8 = null,
    key_prefix: ?[]const u8 = null,
    key_string_width: ?u32 = null,
    key_table_width: ?u32 = null,
    notes_only: ?bool = null,

    command_name: ?[]const u8 = null,
    command_alias: ?[]const u8 = null,
    command_usage: ?[]const u8 = null,
};

pub const FormatExpandResult = struct {
    text: []u8,
    complete: bool,
};

const Resolver = struct {
    name: []const u8,
    func: *const fn (std.mem.Allocator, *const FormatContext) ?[]u8,
};

const FORMAT_LOOP_LIMIT: u32 = 100;

const resolver_table = [_]Resolver{
    .{ .name = "message_text", .func = resolve_message_text },

    .{ .name = "client_height", .func = resolve_client_height },
    .{ .name = "client_session_name", .func = resolve_client_session_name },
    .{ .name = "client_tty", .func = resolve_client_tty },
    .{ .name = "client_width", .func = resolve_client_width },

    .{ .name = "command_alias", .func = resolve_command_alias },
    .{ .name = "command_name", .func = resolve_command_name },
    .{ .name = "command_usage", .func = resolve_command_usage },

    .{ .name = "key_command", .func = resolve_key_command },
    .{ .name = "key_has_repeat", .func = resolve_key_has_repeat },
    .{ .name = "key_note", .func = resolve_key_note },
    .{ .name = "key_padding", .func = resolve_key_padding },
    .{ .name = "key_prefix", .func = resolve_key_prefix },
    .{ .name = "key_repeat", .func = resolve_key_repeat },
    .{ .name = "key_string", .func = resolve_key_string },
    .{ .name = "key_string_width", .func = resolve_key_string_width },
    .{ .name = "key_table", .func = resolve_key_table },
    .{ .name = "key_table_width", .func = resolve_key_table_width },
    .{ .name = "notes_only", .func = resolve_notes_only },

    .{ .name = "pane_active", .func = resolve_pane_active },
    .{ .name = "pane_current_command", .func = resolve_pane_current_command },
    .{ .name = "pane_dead", .func = resolve_pane_dead },
    .{ .name = "pane_dead_status", .func = resolve_pane_dead_status },
    .{ .name = "pane_height", .func = resolve_pane_height },
    .{ .name = "pane_id", .func = resolve_pane_id },
    .{ .name = "pane_in_mode", .func = resolve_pane_in_mode },
    .{ .name = "pane_index", .func = resolve_pane_index },
    .{ .name = "pane_pid", .func = resolve_pane_pid },
    .{ .name = "pane_title", .func = resolve_pane_title },
    .{ .name = "pane_width", .func = resolve_pane_width },

    .{ .name = "session_attached", .func = resolve_session_attached },
    .{ .name = "session_created", .func = resolve_session_created },
    .{ .name = "session_group", .func = resolve_session_group },
    .{ .name = "session_group_list", .func = resolve_session_group_list },
    .{ .name = "session_grouped", .func = resolve_session_grouped },
    .{ .name = "session_name", .func = resolve_session_name },
    .{ .name = "session_windows", .func = resolve_session_windows },

    .{ .name = "window_active", .func = resolve_window_active },
    .{ .name = "window_flags", .func = resolve_window_flags },
    .{ .name = "window_height", .func = resolve_window_height },
    .{ .name = "window_id", .func = resolve_window_id },
    .{ .name = "window_index", .func = resolve_window_index },
    .{ .name = "window_name", .func = resolve_window_name },
    .{ .name = "window_panes", .func = resolve_window_panes },
    .{ .name = "window_raw_flags", .func = resolve_window_raw_flags },
    .{ .name = "window_width", .func = resolve_window_width },
};

pub fn format_expand(alloc: std.mem.Allocator, template: []const u8, ctx: *const FormatContext) FormatExpandResult {
    return expand_template(alloc, template, ctx, 0);
}

pub fn format_require_complete(alloc: std.mem.Allocator, template: []const u8, ctx: *const FormatContext) ?[]u8 {
    const expanded = format_expand(alloc, template, ctx);
    if (!expanded.complete) {
        alloc.free(expanded.text);
        return null;
    }
    return expanded.text;
}

pub fn format_truthy(text: []const u8) bool {
    if (text.len == 0) return false;
    if (std.mem.eql(u8, text, "0")) return false;
    if (std.ascii.eqlIgnoreCase(text, "false")) return false;
    if (std.ascii.eqlIgnoreCase(text, "off")) return false;
    if (std.ascii.eqlIgnoreCase(text, "no")) return false;
    return true;
}

pub fn format_single(
    item: ?*anyopaque,
    fmt: []const u8,
    cl: ?*T.Client,
    s: ?*T.Session,
    wl: ?*T.Winlink,
    wp: ?*T.WindowPane,
) []u8 {
    const w = if (wl) |winlink| winlink.window else if (wp) |pane| pane.window else null;
    const ctx = FormatContext{
        .item = item,
        .client = cl,
        .session = s,
        .winlink = wl,
        .window = w,
        .pane = wp,
    };
    return format_expand(xm.allocator, fmt, &ctx).text;
}

pub fn format_tidy_jobs() void {}

fn expand_template(alloc: std.mem.Allocator, template: []const u8, ctx: *const FormatContext, depth: u32) FormatExpandResult {
    if (depth >= FORMAT_LOOP_LIMIT) {
        return .{ .text = alloc.dupe(u8, template) catch unreachable, .complete = false };
    }

    var out: std.ArrayList(u8) = .{};
    var complete = true;
    var i: usize = 0;
    while (i < template.len) {
        if (template[i] != '#') {
            out.append(alloc, template[i]) catch unreachable;
            i += 1;
            continue;
        }

        if (i + 1 >= template.len) {
            out.append(alloc, '#') catch unreachable;
            break;
        }

        const next = template[i + 1];
        if (next == '#') {
            out.append(alloc, '#') catch unreachable;
            i += 2;
            continue;
        }

        if (next == '{') {
            const end = find_format_end(template, i + 2) orelse {
                out.appendSlice(alloc, template[i..]) catch unreachable;
                complete = false;
                break;
            };
            const expr = template[i + 2 .. end];
            const result = eval_expr(alloc, expr, ctx, depth + 1);
            defer alloc.free(result.text);
            out.appendSlice(alloc, result.text) catch unreachable;
            complete = complete and result.complete;
            i = end + 1;
            continue;
        }

        if (short_alias_key(next)) |key| {
            const result = resolve_direct_key(alloc, key, ctx, next);
            defer alloc.free(result.text);
            out.appendSlice(alloc, result.text) catch unreachable;
            complete = complete and result.complete;
            i += 2;
            continue;
        }

        out.append(alloc, '#') catch unreachable;
        i += 1;
    }

    return .{ .text = out.toOwnedSlice(alloc) catch unreachable, .complete = complete };
}

fn eval_expr(alloc: std.mem.Allocator, expr: []const u8, ctx: *const FormatContext, depth: u32) FormatExpandResult {
    if (expr.len == 0) return .{ .text = alloc.dupe(u8, "") catch unreachable, .complete = true };

    if (expr[0] == '?') {
        const parts = split_top_level_3(expr[1..], ',') orelse return unresolved_expr(alloc, expr);
        const cond = expand_value_expr(alloc, parts.a, ctx, depth + 1);
        defer alloc.free(cond.text);
        const branch = if (!cond.complete)
            unresolved_expr(alloc, expr)
        else if (format_truthy(cond.text))
            expand_template(alloc, parts.b, ctx, depth + 1)
        else
            expand_template(alloc, parts.c, ctx, depth + 1);
        return branch;
    }

    inline for ([_][]const u8{ "==:", "!=:", "&&:", "||:" }) |prefix| {
        if (std.mem.startsWith(u8, expr, prefix)) {
            const parts = split_top_level_2(expr[prefix.len..], ',') orelse return unresolved_expr(alloc, expr);
            const left = expand_value_expr(alloc, parts.a, ctx, depth + 1);
            defer alloc.free(left.text);
            const right = expand_value_expr(alloc, parts.b, ctx, depth + 1);
            defer alloc.free(right.text);

            if (!left.complete or !right.complete) return unresolved_expr(alloc, expr);

            const truth = if (std.mem.eql(u8, prefix, "==:"))
                std.mem.eql(u8, left.text, right.text)
            else if (std.mem.eql(u8, prefix, "!=:"))
                !std.mem.eql(u8, left.text, right.text)
            else if (std.mem.eql(u8, prefix, "&&:"))
                format_truthy(left.text) and format_truthy(right.text)
            else
                format_truthy(left.text) or format_truthy(right.text);

            return .{ .text = alloc.dupe(u8, if (truth) "1" else "0") catch unreachable, .complete = true };
        }
    }

    if (std.mem.startsWith(u8, expr, "t:")) {
        const inner = expand_value_expr(alloc, expr[2..], ctx, depth + 1);
        defer alloc.free(inner.text);
        if (!inner.complete) return unresolved_expr(alloc, expr);
        const seconds = std.fmt.parseInt(i64, inner.text, 10) catch return unresolved_expr(alloc, expr);
        return .{
            .text = format_timestamp_utc(alloc, seconds),
            .complete = true,
        };
    }

    return resolve_direct_key(alloc, expr, ctx, null);
}

fn expand_value_expr(alloc: std.mem.Allocator, expr: []const u8, ctx: *const FormatContext, depth: u32) FormatExpandResult {
    if (expr.len == 0) return .{ .text = alloc.dupe(u8, "") catch unreachable, .complete = true };
    if (std.mem.indexOfScalar(u8, expr, '#') != null) {
        return expand_template(alloc, expr, ctx, depth + 1);
    }
    if (lookup_resolver(expr)) |resolver| {
        const value = resolver.func(alloc, ctx) orelse {
            return .{ .text = alloc.dupe(u8, "") catch unreachable, .complete = false };
        };
        return .{ .text = value, .complete = true };
    }
    return .{ .text = alloc.dupe(u8, expr) catch unreachable, .complete = true };
}

fn resolve_direct_key(alloc: std.mem.Allocator, key: []const u8, ctx: *const FormatContext, short_alias: ?u8) FormatExpandResult {
    if (lookup_resolver(key)) |resolver| {
        const value = resolver.func(alloc, ctx) orelse return unresolved_key(alloc, key, short_alias);
        return .{ .text = value, .complete = true };
    }
    return unresolved_key(alloc, key, short_alias);
}

fn unresolved_key(alloc: std.mem.Allocator, key: []const u8, short_alias: ?u8) FormatExpandResult {
    _ = alloc;
    if (short_alias) |ch| {
        return .{
            .text = xm.xasprintf("#{c}", .{ch}),
            .complete = false,
        };
    }
    return .{
        .text = xm.xasprintf("#{{{s}}}", .{key}),
        .complete = false,
    };
}

fn unresolved_expr(alloc: std.mem.Allocator, expr: []const u8) FormatExpandResult {
    _ = alloc;
    return .{
        .text = xm.xasprintf("#{{{s}}}", .{expr}),
        .complete = false,
    };
}

fn lookup_resolver(name: []const u8) ?Resolver {
    for (resolver_table) |resolver| {
        if (std.mem.eql(u8, resolver.name, name)) return resolver;
    }
    return null;
}

fn short_alias_key(ch: u8) ?[]const u8 {
    return switch (ch) {
        'D' => "pane_id",
        'I' => "window_index",
        'P' => "pane_index",
        'S' => "session_name",
        'T' => "pane_title",
        'W' => "window_name",
        else => null,
    };
}

const Split2 = struct { a: []const u8, b: []const u8 };
const Split3 = struct { a: []const u8, b: []const u8, c: []const u8 };

fn split_top_level_2(input: []const u8, delim: u8) ?Split2 {
    const first = index_of_top_level(input, delim) orelse return null;
    return .{
        .a = input[0..first],
        .b = input[first + 1 ..],
    };
}

fn split_top_level_3(input: []const u8, delim: u8) ?Split3 {
    const first = index_of_top_level(input, delim) orelse return null;
    const second = index_of_top_level(input[first + 1 ..], delim) orelse {
        return .{
            .a = input[0..first],
            .b = input[first + 1 ..],
            .c = "",
        };
    };
    const second_abs = first + 1 + second;
    return .{
        .a = input[0..first],
        .b = input[first + 1 .. second_abs],
        .c = input[second_abs + 1 ..],
    };
}

fn index_of_top_level(input: []const u8, delim: u8) ?usize {
    var depth: u32 = 0;
    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        if (input[i] == '#' and i + 1 < input.len and input[i + 1] == '{') {
            depth += 1;
            i += 1;
            continue;
        }
        if (input[i] == '}' and depth > 0) {
            depth -= 1;
            continue;
        }
        if (input[i] == delim and depth == 0) return i;
    }
    return null;
}

fn find_format_end(input: []const u8, start: usize) ?usize {
    var depth: u32 = 0;
    var i = start;
    while (i < input.len) : (i += 1) {
        if (input[i] == '#' and i + 1 < input.len and input[i + 1] == '{') {
            depth += 1;
            i += 1;
            continue;
        }
        if (input[i] != '}') continue;
        if (depth == 0) return i;
        depth -= 1;
    }
    return null;
}

fn ctx_session(ctx: *const FormatContext) ?*T.Session {
    if (ctx.session) |s| return s;
    if (ctx.winlink) |wl| return wl.session;
    if (ctx.client) |cl| return cl.session;
    return null;
}

fn ctx_winlink(ctx: *const FormatContext) ?*T.Winlink {
    if (ctx.winlink) |wl| return wl;
    if (ctx.session) |s| return s.curw;
    if (ctx.client) |cl| {
        if (cl.session) |s| return s.curw;
    }
    return null;
}

fn ctx_window(ctx: *const FormatContext) ?*T.Window {
    if (ctx.window) |w| return w;
    if (ctx.winlink) |wl| return wl.window;
    if (ctx.pane) |wp| return wp.window;
    if (ctx.session) |s| {
        if (s.curw) |wl| return wl.window;
    }
    if (ctx.client) |cl| {
        if (cl.session) |s| {
            if (s.curw) |wl| return wl.window;
        }
    }
    return null;
}

fn ctx_pane(ctx: *const FormatContext) ?*T.WindowPane {
    if (ctx.pane) |wp| return wp;
    if (ctx.window) |w| return w.active;
    if (ctx.winlink) |wl| return wl.window.active;
    if (ctx.session) |s| {
        if (s.curw) |wl| return wl.window.active;
    }
    if (ctx.client) |cl| {
        if (cl.session) |s| {
            if (s.curw) |wl| return wl.window.active;
        }
    }
    return null;
}

fn resolve_message_text(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    return alloc.dupe(u8, ctx.message_text orelse "") catch unreachable;
}

fn resolve_client_tty(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const cl = ctx.client orelse return null;
    return alloc.dupe(u8, cl.ttyname orelse "/dev/unknown") catch unreachable;
}

fn resolve_client_width(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    _ = alloc;
    const cl = ctx.client orelse return null;
    return xm.xasprintf("{d}", .{cl.tty.sx});
}

fn resolve_client_height(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    _ = alloc;
    const cl = ctx.client orelse return null;
    return xm.xasprintf("{d}", .{cl.tty.sy});
}

fn resolve_client_session_name(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const cl = ctx.client orelse return null;
    return alloc.dupe(u8, if (cl.session) |s| s.name else "") catch unreachable;
}

fn resolve_command_name(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    return alloc.dupe(u8, ctx.command_name orelse return null) catch unreachable;
}

fn resolve_command_alias(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    _ = alloc;
    if (ctx.command_name == null) return null;
    return xm.xstrdup(ctx.command_alias orelse "");
}

fn resolve_command_usage(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    _ = alloc;
    if (ctx.command_name == null) return null;
    return xm.xstrdup(ctx.command_usage orelse "");
}

fn resolve_key_binding(ctx: *const FormatContext) ?*const T.KeyBinding {
    return ctx.key_binding;
}

fn resolve_key_table(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const binding = resolve_key_binding(ctx) orelse return null;
    return alloc.dupe(u8, binding.tablename) catch unreachable;
}

fn resolve_key_string(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const binding = resolve_key_binding(ctx) orelse return null;
    return alloc.dupe(u8, key_string.key_string_lookup_key(binding.key, 0)) catch unreachable;
}

fn resolve_key_note(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const binding = resolve_key_binding(ctx) orelse return null;
    const note = ctx.key_note orelse binding.note orelse "";
    return alloc.dupe(u8, note) catch unreachable;
}

fn resolve_key_command(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const binding = resolve_key_binding(ctx) orelse return null;
    _ = binding;
    return alloc.dupe(u8, ctx.key_command orelse "") catch unreachable;
}

fn resolve_key_has_repeat(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const binding = resolve_key_binding(ctx) orelse return null;
    const value: []const u8 = if (binding.flags & T.KEY_BINDING_REPEAT != 0) "1" else "0";
    return alloc.dupe(u8, value) catch unreachable;
}

fn resolve_key_repeat(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    return resolve_key_has_repeat(alloc, ctx);
}

fn resolve_key_prefix(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const binding = resolve_key_binding(ctx) orelse return null;
    _ = binding;
    return alloc.dupe(u8, ctx.key_prefix orelse "") catch unreachable;
}

fn resolve_key_padding(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const binding = resolve_key_binding(ctx) orelse return null;
    _ = binding;
    return alloc.dupe(u8, ctx.key_padding orelse "") catch unreachable;
}

fn resolve_key_string_width(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    _ = alloc;
    const binding = resolve_key_binding(ctx) orelse return null;
    _ = binding;
    return xm.xasprintf("{d}", .{ctx.key_string_width orelse 0});
}

fn resolve_key_table_width(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    _ = alloc;
    const binding = resolve_key_binding(ctx) orelse return null;
    _ = binding;
    return xm.xasprintf("{d}", .{ctx.key_table_width orelse 0});
}

fn resolve_notes_only(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const binding = resolve_key_binding(ctx) orelse return null;
    _ = binding;
    const value: []const u8 = if (ctx.notes_only orelse false) "1" else "0";
    return alloc.dupe(u8, value) catch unreachable;
}

fn resolve_session_name(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const s = ctx_session(ctx) orelse return null;
    return alloc.dupe(u8, s.name) catch unreachable;
}

fn resolve_session_windows(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    _ = alloc;
    const s = ctx_session(ctx) orelse return null;
    return xm.xasprintf("{d}", .{s.windows.count()});
}

fn resolve_session_attached(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const s = ctx_session(ctx) orelse return null;
    const value: []const u8 = if (s.attached > 0) "1" else "0";
    return alloc.dupe(u8, value) catch unreachable;
}

fn resolve_session_created(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    _ = alloc;
    const s = ctx_session(ctx) orelse return null;
    return xm.xasprintf("{d}", .{s.created});
}

fn resolve_session_grouped(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const s = ctx_session(ctx) orelse return null;
    const value: []const u8 = if (sess.session_group_contains(s) != null) "1" else "0";
    return alloc.dupe(u8, value) catch unreachable;
}

fn resolve_session_group(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const s = ctx_session(ctx) orelse return null;
    const group = sess.session_group_contains(s) orelse return alloc.dupe(u8, "") catch unreachable;
    return alloc.dupe(u8, group.name) catch unreachable;
}

fn resolve_session_group_list(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const s = ctx_session(ctx) orelse return null;
    const group = sess.session_group_contains(s) orelse return alloc.dupe(u8, "") catch unreachable;

    var out: std.ArrayList(u8) = .{};
    for (group.sessions.items, 0..) |entry, idx| {
        if (idx != 0) out.appendSlice(alloc, ",") catch unreachable;
        out.appendSlice(alloc, entry.name) catch unreachable;
    }
    return out.toOwnedSlice(alloc) catch unreachable;
}

fn resolve_window_name(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const w = ctx_window(ctx) orelse return null;
    return alloc.dupe(u8, w.name) catch unreachable;
}

fn resolve_window_index(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const wl = ctx_winlink(ctx) orelse return null;
    _ = alloc;
    return xm.xasprintf("{d}", .{wl.idx});
}

fn resolve_window_width(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const w = ctx_window(ctx) orelse return null;
    _ = alloc;
    return xm.xasprintf("{d}", .{w.sx});
}

fn resolve_window_height(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const w = ctx_window(ctx) orelse return null;
    _ = alloc;
    return xm.xasprintf("{d}", .{w.sy});
}

fn resolve_window_panes(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const w = ctx_window(ctx) orelse return null;
    _ = alloc;
    return xm.xasprintf("{d}", .{w.panes.items.len});
}

fn resolve_window_active(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const wl = ctx_winlink(ctx) orelse return null;
    const s = ctx_session(ctx) orelse return null;
    const value: []const u8 = if (s.curw == wl) "1" else "0";
    return alloc.dupe(u8, value) catch unreachable;
}

fn resolve_window_id(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const w = ctx_window(ctx) orelse return null;
    _ = alloc;
    return xm.xasprintf("@{d}", .{w.id});
}

fn resolve_window_flags(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    return resolve_window_flags_impl(alloc, ctx);
}

fn resolve_window_raw_flags(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    return resolve_window_flags_impl(alloc, ctx);
}

fn resolve_window_flags_impl(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const wl = ctx_winlink(ctx) orelse return null;
    const s = ctx_session(ctx) orelse return null;

    var out: std.ArrayList(u8) = .{};
    if (wl.flags & T.WINLINK_ACTIVITY != 0) out.append(alloc, '#') catch unreachable;
    if (wl.flags & T.WINLINK_BELL != 0) out.append(alloc, '!') catch unreachable;
    if (wl.flags & T.WINLINK_SILENCE != 0) out.append(alloc, '~') catch unreachable;
    if (s.curw == wl) out.append(alloc, '*') catch unreachable;
    if (s.lastw.items.len > 0 and s.lastw.items[0] == wl) out.append(alloc, '-') catch unreachable;
    if (wl.window.flags & T.WINDOW_ZOOMED != 0) out.append(alloc, 'Z') catch unreachable;
    return out.toOwnedSlice(alloc) catch unreachable;
}

fn resolve_pane_id(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const wp = ctx_pane(ctx) orelse return null;
    _ = alloc;
    return xm.xasprintf("%{d}", .{wp.id});
}

fn resolve_pane_pid(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const wp = ctx_pane(ctx) orelse return null;
    _ = alloc;
    return xm.xasprintf("{d}", .{wp.pid});
}

fn resolve_pane_width(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const wp = ctx_pane(ctx) orelse return null;
    _ = alloc;
    return xm.xasprintf("{d}", .{wp.sx});
}

fn resolve_pane_height(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const wp = ctx_pane(ctx) orelse return null;
    _ = alloc;
    return xm.xasprintf("{d}", .{wp.sy});
}

fn resolve_pane_index(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const wp = ctx_pane(ctx) orelse return null;
    const w = ctx_window(ctx) orelse return null;
    for (w.panes.items, 0..) |pane, idx| {
        if (pane == wp) return xm.xasprintf("{d}", .{idx});
    }
    return alloc.dupe(u8, "0") catch unreachable;
}

fn resolve_pane_title(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const wp = ctx_pane(ctx) orelse return null;
    return alloc.dupe(u8, if (wp.screen.title) |title| title else "") catch unreachable;
}

fn resolve_pane_active(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const wp = ctx_pane(ctx) orelse return null;
    const w = ctx_window(ctx) orelse return null;
    const value: []const u8 = if (w.active == wp) "1" else "0";
    return alloc.dupe(u8, value) catch unreachable;
}

fn resolve_pane_dead(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const wp = ctx_pane(ctx) orelse return null;
    const value: []const u8 = if (wp.flags & T.PANE_EXITED != 0) "1" else "0";
    return alloc.dupe(u8, value) catch unreachable;
}

fn resolve_pane_dead_status(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const wp = ctx_pane(ctx) orelse return null;
    if (wp.flags & T.PANE_EXITED == 0) return alloc.dupe(u8, "") catch unreachable;
    return xm.xasprintf("{d}", .{wp.status});
}

fn resolve_pane_in_mode(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const wp = ctx_pane(ctx) orelse return null;
    _ = wp;
    return alloc.dupe(u8, "0") catch unreachable;
}

fn resolve_pane_current_command(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const wp = ctx_pane(ctx) orelse return null;
    if (wp.argv) |argv| {
        const text = stringify_argv(alloc, argv);
        defer alloc.free(text);
        return names.parse_window_name(text);
    }
    if (wp.shell) |shell| return names.parse_window_name(shell);
    return alloc.dupe(u8, "") catch unreachable;
}

fn stringify_argv(alloc: std.mem.Allocator, argv: []const []u8) []u8 {
    if (argv.len == 0) return alloc.dupe(u8, "") catch unreachable;
    var len: usize = 0;
    for (argv, 0..) |arg, idx| {
        len += arg.len;
        if (idx + 1 < argv.len) len += 1;
    }
    const out = alloc.alloc(u8, len) catch unreachable;
    var pos: usize = 0;
    for (argv, 0..) |arg, idx| {
        @memcpy(out[pos .. pos + arg.len], arg);
        pos += arg.len;
        if (idx + 1 < argv.len) {
            out[pos] = ' ';
            pos += 1;
        }
    }
    return out;
}

fn format_timestamp_utc(alloc: std.mem.Allocator, seconds: i64) []u8 {
    if (seconds < 0) return xm.xasprintf("{d}", .{seconds});

    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(seconds) };
    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();
    return std.fmt.allocPrint(alloc, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
    }) catch unreachable;
}

test "format_expand resolves direct keys and aliases" {
    var s = T.Session{
        .id = 7,
        .name = xm.xstrdup("alpha"),
        .cwd = "",
        .created = 1234567890,
        .windows = std.AutoHashMap(i32, T.Winlink).init(xm.allocator),
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
        .windows = std.AutoHashMap(i32, T.Winlink).init(xm.allocator),
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

test "format_expand handles time modifier and incomplete formats" {
    var s = T.Session{
        .id = 1,
        .name = xm.xstrdup("gamma"),
        .cwd = "",
        .created = 0,
        .windows = std.AutoHashMap(i32, T.Winlink).init(xm.allocator),
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
    try std.testing.expectEqualStrings("1970-01-01 00:00:00", timed.text);

    const unresolved = format_expand(xm.allocator, "#{definitely_missing}", &ctx);
    defer xm.allocator.free(unresolved.text);
    try std.testing.expect(!unresolved.complete);
    try std.testing.expectEqualStrings("#{definitely_missing}", unresolved.text);
    try std.testing.expect(format_require_complete(xm.allocator, "#{definitely_missing}", &ctx) == null);
}
