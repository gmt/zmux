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
// Ported in part from tmux/format.c.
// Original copyright:
//   Copyright (c) 2011 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

//! format.zig – reduced shared tmux-style format expansion.

const std = @import("std");
const T = @import("types.zig");
const c = @import("c.zig");
const colour = @import("colour.zig");
const log = @import("log.zig");
const paste_mod = @import("paste.zig");
const sort_mod = @import("sort.zig");
const regsub_mod = @import("regsub.zig");
const utf8 = @import("utf8.zig");
const xm = @import("xmalloc.zig");
const sess = @import("session.zig");
const window_mod = @import("window.zig");

pub const FormatContext = struct {
    item: ?*anyopaque = null,
    client: ?*T.Client = null,
    session: ?*T.Session = null,
    winlink: ?*T.Winlink = null,
    window: ?*T.Window = null,
    pane: ?*T.WindowPane = null,
    mouse_event: ?*const T.MouseEvent = null,
    paste_buffer: ?*paste_mod.PasteBuffer = null,

    message_text: ?[]const u8 = null,
    message_number: ?u32 = null,
    message_time: ?i64 = null,
    command_prompt: ?bool = null,

    key_binding: ?*const T.KeyBinding = null,
    key_has_repeat: ?bool = null,
    key_note: ?[]const u8 = null,
    key_command: ?[]const u8 = null,
    key_prefix: ?[]const u8 = null,
    key_string_width: ?u32 = null,
    key_table_width: ?u32 = null,
    notes_only: ?bool = null,
    loop_last_flag: ?bool = null,

    command_name: ?[]const u8 = null,
    command_alias: ?[]const u8 = null,
    command_usage: ?[]const u8 = null,

    is_option: ?bool = null,
    is_key: ?bool = null,
    option_name: ?[]const u8 = null,
    option_value: ?[]const u8 = null,
    option_scope: ?[]const u8 = null,
    option_unit: ?[]const u8 = null,
    option_is_global: ?bool = null,
    option_inherited: ?bool = null,
    line: ?u32 = null,
};

pub const FormatExpandResult = struct {
    text: []u8,
    complete: bool,
};

pub const FormatError = error{Incomplete};
pub const FormatEachCallback = *const fn ([]const u8, []const u8, ?*anyopaque) void;
const fmt_resolve = @import("format-resolve.zig");

const Resolver = fmt_resolve.Resolver;
const resolver_table = fmt_resolve.resolver_table;
const FORMAT_LOOP_LIMIT = fmt_resolve.FORMAT_LOOP_LIMIT;

pub fn format_expand(alloc: std.mem.Allocator, template: []const u8, ctx: *const FormatContext) FormatExpandResult {
    return expand_template(alloc, template, ctx, 0);
}

pub fn format_expand_time(alloc: std.mem.Allocator, template: []const u8, ctx: *const FormatContext) FormatExpandResult {
    if (std.mem.indexOfScalar(u8, template, '%') == null) return format_expand(alloc, template, ctx);

    const timed_template = format_strftime_now(alloc, template) orelse {
        return .{ .text = alloc.dupe(u8, "") catch unreachable, .complete = true };
    };
    defer alloc.free(timed_template);

    return expand_template(alloc, timed_template, ctx, 0);
}

pub fn format_require_complete(alloc: std.mem.Allocator, template: []const u8, ctx: *const FormatContext) ?[]u8 {
    return format_require(alloc, template, ctx) catch null;
}

pub fn format_require(alloc: std.mem.Allocator, template: []const u8, ctx: *const FormatContext) FormatError![]u8 {
    const expanded = format_expand(alloc, template, ctx);
    if (!expanded.complete) {
        alloc.free(expanded.text);
        return error.Incomplete;
    }
    return expanded.text;
}

pub fn format_filter_match(alloc: std.mem.Allocator, filter: []const u8, ctx: *const FormatContext) ?bool {
    const expanded = format_filter_require(alloc, filter, ctx) catch return null;
    return expanded;
}

pub fn format_filter_require(alloc: std.mem.Allocator, filter: []const u8, ctx: *const FormatContext) FormatError!bool {
    const expanded = try format_require(alloc, filter, ctx);
    defer alloc.free(expanded);
    return format_truthy(expanded);
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

pub fn format_each(alloc: std.mem.Allocator, ctx: *const FormatContext, cb: FormatEachCallback, arg: ?*anyopaque) void {
    for (resolver_table) |resolver| {
        const value = resolver.func(alloc, ctx) orelse continue;
        defer alloc.free(value);
        cb(resolver.name, value, arg);
    }
}

pub fn format_log_defaults(alloc: std.mem.Allocator, prefix: []const u8, ctx: *const FormatContext) void {
    if (log.log_get_level() == 0) return;

    for (resolver_table) |resolver| {
        const value = resolver.func(alloc, ctx) orelse continue;
        defer alloc.free(value);
        log.log_debug("{s}: {s}={s}", .{ prefix, resolver.name, value });
    }
}

pub fn format_tidy_jobs() void {
    const job_mod = @import("job.zig");
    job_mod.job_tidy();
}

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

const CompareKind = enum {
    none,
    eq,
    ne,
    lt,
    gt,
    le,
    ge,
};

const LoopKind = enum {
    none,
    sessions,
    windows,
    panes,
    clients,
};

const NameCheckKind = enum {
    none,
    window,
    session,
};

const ArithmeticOp = enum {
    add,
    subtract,
    multiply,
    divide,
    modulus,
    eq,
    ne,
    gt,
    ge,
    lt,
    le,
};

const Modifier = struct {
    name: []const u8,
    args: [][]const u8,
};

const ParsedModifiers = struct {
    modifiers: []Modifier,
    rest: []const u8,

    fn deinit(self: ParsedModifiers, alloc: std.mem.Allocator) void {
        for (self.modifiers) |modifier| alloc.free(modifier.args);
        alloc.free(self.modifiers);
    }
};

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

    if (build_modifiers(alloc, expr)) |parsed| {
        defer parsed.deinit(alloc);
        return eval_modified_expr(alloc, expr, parsed.rest, parsed.modifiers, ctx, depth + 1);
    }

    return resolve_direct_key(alloc, expr, ctx, null);
}

fn eval_modified_expr(
    alloc: std.mem.Allocator,
    original_expr: []const u8,
    copy: []const u8,
    modifiers: []const Modifier,
    ctx: *const FormatContext,
    depth: u32,
) FormatExpandResult {
    var compare: CompareKind = .none;
    var match_flags: ?[]const u8 = null;
    var search_flags: ?[]const u8 = null;
    var bool_and: ?bool = null;
    var negate = false;
    var truthy_only = false;
    var loop_kind: LoopKind = .none;
    var loop_sort: T.SortCriteria = .{ .order = .end, .reversed = false };
    var name_check: NameCheckKind = .none;
    var arithmetic_index: ?usize = null;

    var limit_spec: ?[]const u8 = null;
    var limit_marker_spec: ?[]const u8 = null;
    var pad_spec: ?[]const u8 = null;

    var literal = false;
    var char_output = false;
    var colour_output = false;
    var basename = false;
    var dirname = false;
    var quote_shell = false;
    var quote_style = false;
    var length_output = false;
    var width_output = false;
    var expand_nested = false;
    var expand_time = false;
    var repeat_output = false;
    var time_string = false;
    var time_format_spec: ?[]const u8 = null;
    var time_pretty = false;
    var time_pretty_seconds = false;

    for (modifiers, 0..) |modifier, idx| {
        if (std.mem.eql(u8, modifier.name, "==")) {
            compare = .eq;
        } else if (std.mem.eql(u8, modifier.name, "!=")) {
            compare = .ne;
        } else if (std.mem.eql(u8, modifier.name, "<")) {
            compare = .lt;
        } else if (std.mem.eql(u8, modifier.name, ">")) {
            compare = .gt;
        } else if (std.mem.eql(u8, modifier.name, "<=")) {
            compare = .le;
        } else if (std.mem.eql(u8, modifier.name, ">=")) {
            compare = .ge;
        } else if (std.mem.eql(u8, modifier.name, "&&")) {
            bool_and = true;
        } else if (std.mem.eql(u8, modifier.name, "||")) {
            bool_and = false;
        } else if (std.mem.eql(u8, modifier.name, "!")) {
            negate = true;
        } else if (std.mem.eql(u8, modifier.name, "m")) {
            match_flags = if (modifier.args.len != 0) modifier.args[0] else "";
        } else if (std.mem.eql(u8, modifier.name, "C")) {
            search_flags = if (modifier.args.len != 0) modifier.args[0] else "";
        } else if (std.mem.eql(u8, modifier.name, "!!")) {
            truthy_only = true;
        } else if (std.mem.eql(u8, modifier.name, "R")) {
            repeat_output = true;
        } else if (std.mem.eql(u8, modifier.name, "e")) {
            arithmetic_index = idx;
        } else if (std.mem.eql(u8, modifier.name, "l")) {
            literal = true;
        } else if (std.mem.eql(u8, modifier.name, "a")) {
            char_output = true;
        } else if (std.mem.eql(u8, modifier.name, "c")) {
            colour_output = true;
        } else if (std.mem.eql(u8, modifier.name, "b")) {
            basename = true;
        } else if (std.mem.eql(u8, modifier.name, "d")) {
            dirname = true;
        } else if (std.mem.eql(u8, modifier.name, "q")) {
            if (modifier.args.len == 0) {
                quote_shell = true;
            } else if (std.mem.indexOfAny(u8, modifier.args[0], "eh") != null) {
                quote_style = true;
            } else {
                quote_shell = true;
            }
        } else if (std.mem.eql(u8, modifier.name, "n")) {
            length_output = true;
        } else if (std.mem.eql(u8, modifier.name, "w")) {
            width_output = true;
        } else if (std.mem.eql(u8, modifier.name, "E")) {
            expand_nested = true;
        } else if (std.mem.eql(u8, modifier.name, "T")) {
            expand_time = true;
        } else if (std.mem.eql(u8, modifier.name, "t")) {
            time_string = true;
            if (modifier.args.len >= 1) {
                if (std.mem.indexOfScalar(u8, modifier.args[0], 'p') != null) time_pretty = true;
                if (std.mem.indexOfScalar(u8, modifier.args[0], 's') != null) time_pretty_seconds = true;
                if (modifier.args.len >= 2 and std.mem.indexOfScalar(u8, modifier.args[0], 'f') != null) {
                    time_format_spec = modifier.args[1];
                }
            }
        } else if (std.mem.eql(u8, modifier.name, "=")) {
            if (modifier.args.len >= 1) limit_spec = modifier.args[0];
            if (modifier.args.len >= 2) limit_marker_spec = modifier.args[1];
        } else if (std.mem.eql(u8, modifier.name, "p")) {
            if (modifier.args.len >= 1) pad_spec = modifier.args[0];
        } else if (std.mem.eql(u8, modifier.name, "N")) {
            if (modifier.args.len != 0 and std.mem.indexOfScalar(u8, modifier.args[0], 's') != null)
                name_check = .session
            else
                name_check = .window;
        } else if (std.mem.eql(u8, modifier.name, "S")) {
            loop_kind = .sessions;
            loop_sort = parse_loop_sort(.sessions, modifier.args);
        } else if (std.mem.eql(u8, modifier.name, "W")) {
            loop_kind = .windows;
            loop_sort = parse_loop_sort(.windows, modifier.args);
        } else if (std.mem.eql(u8, modifier.name, "P")) {
            loop_kind = .panes;
            loop_sort = parse_loop_sort(.panes, modifier.args);
        } else if (std.mem.eql(u8, modifier.name, "L")) {
            loop_kind = .clients;
            loop_sort = parse_loop_sort(.clients, modifier.args);
        }
    }

    const value = blk: {
        if (loop_kind != .none) break :blk eval_loop_expr(alloc, original_expr, copy, loop_kind, loop_sort, ctx, depth + 1);
        if (name_check != .none) break :blk eval_name_check_expr(alloc, original_expr, copy, name_check, ctx, depth + 1);
        if (search_flags) |flags| {
            const term = expand_template(alloc, copy, ctx, depth + 1);
            defer alloc.free(term.text);
            if (!term.complete) break :blk unresolved_expr(alloc, original_expr);

            const wp = ctx_pane(ctx) orelse break :blk FormatExpandResult{
                .text = alloc.dupe(u8, "0") catch unreachable,
                .complete = true,
            };
            break :blk FormatExpandResult{
                .text = xm.xasprintf("{d}", .{
                    window_mod.window_pane_search(
                        wp,
                        term.text,
                        std.mem.indexOfScalar(u8, flags, 'r') != null,
                        std.mem.indexOfScalar(u8, flags, 'i') != null,
                    ),
                }),
                .complete = true,
            };
        }

        if (repeat_output) {
            const parts = split_top_level_2(copy, ',') orelse break :blk unresolved_expr(alloc, original_expr);
            const body = expand_template(alloc, parts.a, ctx, depth + 1);
            defer alloc.free(body.text);
            const count_text = expand_value_expr(alloc, parts.b, ctx, depth + 1);
            defer alloc.free(count_text.text);
            if (!body.complete or !count_text.complete) break :blk unresolved_expr(alloc, original_expr);
            const count = std.fmt.parseInt(u32, count_text.text, 10) catch break :blk unresolved_expr(alloc, original_expr);

            var out: std.ArrayList(u8) = .{};
            for (0..count) |_| out.appendSlice(alloc, body.text) catch unreachable;
            break :blk FormatExpandResult{ .text = out.toOwnedSlice(alloc) catch unreachable, .complete = true };
        }

        if (negate or truthy_only or bool_and != null or compare != .none or match_flags != null) {
            break :blk eval_boolean_expr(alloc, original_expr, copy, compare, match_flags, negate, truthy_only, bool_and, ctx, depth + 1);
        }

        if (arithmetic_index) |idx| {
            break :blk eval_arithmetic_expr(alloc, copy, modifiers[idx], ctx, depth + 1);
        }

        if (literal) break :blk FormatExpandResult{ .text = format_unescape(copy), .complete = true };
        if (char_output) break :blk eval_character_expr(alloc, original_expr, copy, ctx, depth + 1);
        if (colour_output) break :blk eval_colour_expr(alloc, original_expr, copy, ctx, depth + 1);
        break :blk resolve_base_value(alloc, original_expr, copy, ctx, depth + 1, expand_nested or expand_time);
    };
    if (!value.complete) return unresolved_expr(alloc, original_expr);
    defer alloc.free(value.text);

    var working = alloc.dupe(u8, value.text) catch unreachable;
    errdefer alloc.free(working);

    if (time_string) {
        const rendered = if (time_pretty)
            format_pretty_time(alloc, working, time_pretty_seconds)
        else blk: {
            const fmt = if (time_format_spec) |raw_fmt| blk_fmt: {
                const expanded_fmt = expand_template(alloc, raw_fmt, ctx, depth + 1);
                defer alloc.free(expanded_fmt.text);
                if (!expanded_fmt.complete) return unresolved_expr(alloc, original_expr);
                break :blk_fmt expanded_fmt.text;
            } else "%Y-%m-%d %H:%M:%S";
            break :blk format_timestamp_local(alloc, working, fmt);
        };
        if (rendered == null) {
            alloc.free(working);
            return unresolved_expr(alloc, original_expr);
        }
        alloc.free(working);
        working = rendered.?;
    }

    if (basename) {
        const rendered = format_basename(working);
        alloc.free(working);
        working = rendered;
    }
    if (dirname) {
        const rendered = format_dirname(working);
        alloc.free(working);
        working = rendered;
    }
    if (quote_shell) {
        const rendered = format_quote_shell(working);
        alloc.free(working);
        working = rendered;
    }
    if (quote_style) {
        const rendered = format_quote_style(working);
        alloc.free(working);
        working = rendered;
    }

    if (expand_nested or expand_time) {
        const expanded = expand_template(alloc, working, ctx, depth + 1);
        alloc.free(working);
        if (!expanded.complete) {
            alloc.free(expanded.text);
            return unresolved_expr(alloc, original_expr);
        }
        working = expanded.text;
        if (expand_time) {
            const rendered = format_strftime_now(alloc, working) orelse {
                alloc.free(working);
                return unresolved_expr(alloc, original_expr);
            };
            alloc.free(working);
            working = rendered;
        }
    }

    for (modifiers) |modifier| {
        if (!std.mem.eql(u8, modifier.name, "s") or modifier.args.len < 2) continue;

        const pattern = expand_template(alloc, modifier.args[0], ctx, depth + 1);
        defer alloc.free(pattern.text);
        const replacement = expand_template(alloc, modifier.args[1], ctx, depth + 1);
        defer alloc.free(replacement.text);
        if (!pattern.complete or !replacement.complete) {
            alloc.free(working);
            return unresolved_expr(alloc, original_expr);
        }

        const flags = if (modifier.args.len >= 3) modifier.args[2] else "";
        const substituted = format_substitute(alloc, working, pattern.text, replacement.text, flags);
        alloc.free(working);
        working = substituted;
    }

    if (limit_spec) |spec| {
        const limit_text = expand_template(alloc, spec, ctx, depth + 1);
        defer alloc.free(limit_text.text);
        if (!limit_text.complete) {
            alloc.free(working);
            return unresolved_expr(alloc, original_expr);
        }
        const limit = std.fmt.parseInt(i32, limit_text.text, 10) catch {
            alloc.free(working);
            return unresolved_expr(alloc, original_expr);
        };
        var marker: []u8 = &.{};
        if (limit_marker_spec) |raw_marker| {
            const marker_result = expand_template(alloc, raw_marker, ctx, depth + 1);
            defer alloc.free(marker_result.text);
            if (!marker_result.complete) {
                alloc.free(working);
                return unresolved_expr(alloc, original_expr);
            }
            marker = alloc.dupe(u8, marker_result.text) catch unreachable;
        } else {
            marker = alloc.dupe(u8, "") catch unreachable;
        }
        defer alloc.free(marker);

        const trimmed = if (limit > 0)
            utf8.trimDisplay(working, .left, @intCast(limit))
        else if (limit < 0)
            utf8.trimDisplay(working, .right, @intCast(-limit))
        else
            xm.xstrdup("");
        defer alloc.free(trimmed);

        const changed = !std.mem.eql(u8, trimmed, working);
        const final_trimmed = if (limit > 0 and changed and marker.len != 0)
            std.fmt.allocPrint(alloc, "{s}{s}", .{ trimmed, marker }) catch unreachable
        else if (limit < 0 and changed and marker.len != 0)
            std.fmt.allocPrint(alloc, "{s}{s}", .{ marker, trimmed }) catch unreachable
        else
            alloc.dupe(u8, trimmed) catch unreachable;
        alloc.free(working);
        working = final_trimmed;
    }

    if (pad_spec) |spec| {
        const pad_text = expand_template(alloc, spec, ctx, depth + 1);
        defer alloc.free(pad_text.text);
        if (!pad_text.complete) {
            alloc.free(working);
            return unresolved_expr(alloc, original_expr);
        }
        const pad = std.fmt.parseInt(i32, pad_text.text, 10) catch {
            alloc.free(working);
            return unresolved_expr(alloc, original_expr);
        };
        const padded = if (pad > 0)
            utf8.padDisplay(working, .left, @intCast(pad))
        else if (pad < 0)
            utf8.padDisplay(working, .right, @intCast(-pad))
        else
            xm.xstrdup(working);
        alloc.free(working);
        working = padded;
    }

    if (length_output) {
        const rendered = xm.xasprintf("{d}", .{working.len});
        alloc.free(working);
        working = rendered;
    }
    if (width_output) {
        const rendered = xm.xasprintf("{d}", .{utf8.displayWidth(working)});
        alloc.free(working);
        working = rendered;
    }

    return .{ .text = working, .complete = true };
}

fn eval_boolean_expr(
    alloc: std.mem.Allocator,
    original_expr: []const u8,
    copy: []const u8,
    compare: CompareKind,
    match_flags: ?[]const u8,
    negate: bool,
    truthy_only: bool,
    bool_and: ?bool,
    ctx: *const FormatContext,
    depth: u32,
) FormatExpandResult {
    if (bool_and) |and_mode| {
        const parts = split_top_level_all(alloc, copy, ',') orelse return unresolved_expr(alloc, original_expr);
        defer alloc.free(parts);

        var result = and_mode;
        for (parts) |part| {
            const expanded = expand_value_expr(alloc, part, ctx, depth + 1);
            defer alloc.free(expanded.text);
            if (!expanded.complete) return unresolved_expr(alloc, original_expr);
            if (and_mode)
                result = result and format_truthy(expanded.text)
            else
                result = result or format_truthy(expanded.text);
        }
        return .{ .text = alloc.dupe(u8, if (result) "1" else "0") catch unreachable, .complete = true };
    }

    if (compare != .none or match_flags != null) {
        const parts = split_top_level_2(copy, ',') orelse return unresolved_expr(alloc, original_expr);
        const left = expand_value_expr(alloc, parts.a, ctx, depth + 1);
        defer alloc.free(left.text);
        const right = expand_value_expr(alloc, parts.b, ctx, depth + 1);
        defer alloc.free(right.text);
        if (!left.complete or !right.complete) return unresolved_expr(alloc, original_expr);

        const truth = if (match_flags) |flags|
            format_match(left.text, right.text, flags)
        else switch (compare) {
            .eq => std.mem.eql(u8, left.text, right.text),
            .ne => !std.mem.eql(u8, left.text, right.text),
            .lt => std.mem.lessThan(u8, left.text, right.text),
            .gt => std.mem.lessThan(u8, right.text, left.text),
            .le => !std.mem.lessThan(u8, right.text, left.text),
            .ge => !std.mem.lessThan(u8, left.text, right.text),
            .none => false,
        };
        return .{ .text = alloc.dupe(u8, if (truth) "1" else "0") catch unreachable, .complete = true };
    }

    const expanded = expand_value_expr(alloc, copy, ctx, depth + 1);
    defer alloc.free(expanded.text);
    if (!expanded.complete) return unresolved_expr(alloc, original_expr);

    const truth = if (negate)
        !format_truthy(expanded.text)
    else if (truthy_only)
        format_truthy(expanded.text)
    else
        false;
    return .{ .text = alloc.dupe(u8, if (truth) "1" else "0") catch unreachable, .complete = true };
}

fn eval_arithmetic_expr(
    alloc: std.mem.Allocator,
    copy: []const u8,
    modifier: Modifier,
    ctx: *const FormatContext,
    depth: u32,
) FormatExpandResult {
    if (modifier.args.len == 0 or modifier.args.len > 3) return empty_result(alloc);

    const op = parse_arithmetic_op(modifier.args[0]) orelse return empty_result(alloc);
    const parts = split_top_level_2(copy, ',') orelse return empty_result(alloc);

    const left = expand_value_expr(alloc, parts.a, ctx, depth + 1);
    defer alloc.free(left.text);
    const right = expand_value_expr(alloc, parts.b, ctx, depth + 1);
    defer alloc.free(right.text);
    if (!left.complete or !right.complete) return .{ .text = alloc.dupe(u8, "") catch unreachable, .complete = false };

    var use_fp = false;
    var precision: usize = 0;
    if (modifier.args.len >= 2 and std.mem.indexOfScalar(u8, modifier.args[1], 'f') != null) {
        use_fp = true;
        precision = 2;
    }
    if (modifier.args.len >= 3) {
        precision = std.fmt.parseInt(usize, modifier.args[2], 10) catch return empty_result(alloc);
    }

    var lhs = std.fmt.parseFloat(f64, left.text) catch return empty_result(alloc);
    var rhs = std.fmt.parseFloat(f64, right.text) catch return empty_result(alloc);
    if (!use_fp) {
        const int_lhs = truncate_to_i64(lhs) orelse return empty_result(alloc);
        const int_rhs = truncate_to_i64(rhs) orelse return empty_result(alloc);
        lhs = @floatFromInt(int_lhs);
        rhs = @floatFromInt(int_rhs);
    }

    const result = switch (op) {
        .add => lhs + rhs,
        .subtract => lhs - rhs,
        .multiply => lhs * rhs,
        .divide => lhs / rhs,
        .modulus => std.math.mod(f64, lhs, rhs) catch return empty_result(alloc),
        .eq => if (@abs(lhs - rhs) < 1e-9) @as(f64, 1.0) else @as(f64, 0.0),
        .ne => if (@abs(lhs - rhs) > 1e-9) @as(f64, 1.0) else @as(f64, 0.0),
        .gt => if (lhs > rhs) @as(f64, 1.0) else @as(f64, 0.0),
        .ge => if (lhs >= rhs) @as(f64, 1.0) else @as(f64, 0.0),
        .lt => if (lhs < rhs) @as(f64, 1.0) else @as(f64, 0.0),
        .le => if (lhs <= rhs) @as(f64, 1.0) else @as(f64, 0.0),
    };

    const rendered = if (use_fp)
        std.fmt.allocPrint(alloc, "{d:.[1]}", .{ result, precision }) catch unreachable
    else
        std.fmt.allocPrint(alloc, "{d:.[1]}", .{ @as(f64, @floatFromInt(truncate_to_i64(result) orelse return empty_result(alloc))), precision }) catch unreachable;
    return .{ .text = rendered, .complete = true };
}

fn empty_result(alloc: std.mem.Allocator) FormatExpandResult {
    return .{ .text = alloc.dupe(u8, "") catch unreachable, .complete = true };
}

fn parse_arithmetic_op(text: []const u8) ?ArithmeticOp {
    if (std.mem.eql(u8, text, "+")) return .add;
    if (std.mem.eql(u8, text, "-")) return .subtract;
    if (std.mem.eql(u8, text, "*")) return .multiply;
    if (std.mem.eql(u8, text, "/")) return .divide;
    if (std.mem.eql(u8, text, "%") or std.mem.eql(u8, text, "%%") or std.mem.eql(u8, text, "m")) return .modulus;
    if (std.mem.eql(u8, text, "==")) return .eq;
    if (std.mem.eql(u8, text, "!=")) return .ne;
    if (std.mem.eql(u8, text, ">")) return .gt;
    if (std.mem.eql(u8, text, ">=")) return .ge;
    if (std.mem.eql(u8, text, "<")) return .lt;
    if (std.mem.eql(u8, text, "<=")) return .le;
    return null;
}

fn truncate_to_i64(value: f64) ?i64 {
    if (!std.math.isFinite(value)) return null;
    const truncated = @trunc(value);
    const min_value = @as(f64, @floatFromInt(std.math.minInt(i64)));
    const max_value = @as(f64, @floatFromInt(std.math.maxInt(i64)));
    if (truncated < min_value or truncated > max_value) return null;
    return @intFromFloat(truncated);
}

fn format_match(pattern: []const u8, text: []const u8, flags_text: []const u8) bool {
    if (std.mem.indexOfScalar(u8, flags_text, 'r') == null) {
        const ignore_case = std.mem.indexOfScalar(u8, flags_text, 'i') != null;
        const match_pattern = if (ignore_case)
            std.ascii.allocLowerString(xm.allocator, pattern) catch unreachable
        else
            xm.xstrdup(pattern);
        defer xm.allocator.free(match_pattern);
        const match_text = if (ignore_case)
            std.ascii.allocLowerString(xm.allocator, text) catch unreachable
        else
            xm.xstrdup(text);
        defer xm.allocator.free(match_text);
        const pattern_z = xm.xm_dupeZ(match_pattern);
        defer xm.allocator.free(pattern_z);
        const text_z = xm.xm_dupeZ(match_text);
        defer xm.allocator.free(text_z);
        return c.posix_sys.fnmatch(pattern_z.ptr, text_z.ptr, 0) == 0;
    }

    var flags: c_int = c.posix_sys.REG_EXTENDED | c.posix_sys.REG_NOSUB;
    if (std.mem.indexOfScalar(u8, flags_text, 'i') != null) flags |= c.posix_sys.REG_ICASE;

    const pattern_z = xm.xm_dupeZ(pattern);
    defer xm.allocator.free(pattern_z);
    const text_z = xm.xm_dupeZ(text);
    defer xm.allocator.free(text_z);

    const regex = c.posix_sys.zmux_regex_new() orelse return false;
    defer c.posix_sys.zmux_regex_free(regex);
    if (c.posix_sys.zmux_regex_compile(regex, pattern_z.ptr, flags) != 0) return false;

    return c.posix_sys.zmux_regex_exec(regex, text_z.ptr, 0, null) == 0;
}

fn format_substitute(
    alloc: std.mem.Allocator,
    text: []const u8,
    pattern: []const u8,
    replacement: []const u8,
    flags_text: []const u8,
) []u8 {
    var flags: c_int = c.posix_sys.REG_EXTENDED;
    if (std.mem.indexOfScalar(u8, flags_text, 'i') != null) flags |= c.posix_sys.REG_ICASE;
    return regsub_mod.regsub(alloc, pattern, replacement, text, flags) orelse alloc.dupe(u8, text) catch unreachable;
}

fn eval_character_expr(
    alloc: std.mem.Allocator,
    original_expr: []const u8,
    copy: []const u8,
    ctx: *const FormatContext,
    depth: u32,
) FormatExpandResult {
    const expanded = expand_value_expr(alloc, copy, ctx, depth + 1);
    defer alloc.free(expanded.text);
    if (!expanded.complete) return unresolved_expr(alloc, original_expr);

    const parsed = std.fmt.parseInt(u8, expanded.text, 10) catch return unresolved_expr(alloc, original_expr);
    if (parsed < 32 or parsed > 126) return .{ .text = alloc.dupe(u8, "") catch unreachable, .complete = true };
    const out = alloc.alloc(u8, 1) catch unreachable;
    out[0] = parsed;
    return .{ .text = out, .complete = true };
}

fn eval_colour_expr(
    alloc: std.mem.Allocator,
    original_expr: []const u8,
    copy: []const u8,
    ctx: *const FormatContext,
    depth: u32,
) FormatExpandResult {
    const expanded = expand_value_expr(alloc, copy, ctx, depth + 1);
    defer alloc.free(expanded.text);
    if (!expanded.complete) return unresolved_expr(alloc, original_expr);

    const parsed = colour.colour_fromstring(expanded.text);
    if (parsed == -1) return .{ .text = alloc.dupe(u8, "") catch unreachable, .complete = true };
    const rgb = colour.colour_force_rgb(parsed);
    if (rgb == -1) return .{ .text = alloc.dupe(u8, "") catch unreachable, .complete = true };
    return .{ .text = xm.xasprintf("{x:0>6}", .{rgb & 0x00ff_ffff}), .complete = true };
}

fn eval_name_check_expr(
    alloc: std.mem.Allocator,
    original_expr: []const u8,
    copy: []const u8,
    kind: NameCheckKind,
    ctx: *const FormatContext,
    depth: u32,
) FormatExpandResult {
    const expanded = expand_template(alloc, copy, ctx, depth + 1);
    defer alloc.free(expanded.text);
    if (!expanded.complete) return unresolved_expr(alloc, original_expr);

    const truth = switch (kind) {
        .session => sess.session_find(expanded.text) != null,
        .window => blk: {
            const s = ctx_session(ctx) orelse break :blk false;
            var it = s.windows.valueIterator();
            while (it.next()) |wl| {
                if (std.mem.eql(u8, wl.*.window.name, expanded.text)) break :blk true;
            }
            break :blk false;
        },
        .none => false,
    };
    return .{ .text = alloc.dupe(u8, if (truth) "1" else "0") catch unreachable, .complete = true };
}

fn eval_loop_expr(
    alloc: std.mem.Allocator,
    original_expr: []const u8,
    copy: []const u8,
    kind: LoopKind,
    sort_crit: T.SortCriteria,
    ctx: *const FormatContext,
    depth: u32,
) FormatExpandResult {
    const parts = split_top_level_2(copy, ',');
    const all_template = if (parts) |pair| pair.a else copy;
    const active_template = if (parts) |pair| pair.b else null;

    var out: std.ArrayList(u8) = .{};
    var complete = true;

    switch (kind) {
        .sessions => {
            const items = sort_mod.sorted_sessions(sort_crit);
            defer alloc.free(items);
            for (items, 0..) |entry, idx| {
                var child = child_context_for_session(ctx, entry, idx + 1 == items.len);
                const use_template = if (active_template != null and session_is_active(ctx, entry)) active_template.? else all_template;
                const rendered = expand_template(alloc, use_template, &child, depth + 1);
                defer alloc.free(rendered.text);
                out.appendSlice(alloc, rendered.text) catch unreachable;
                complete = complete and rendered.complete;
            }
        },
        .windows => {
            const s = ctx_session(ctx) orelse return unresolved_expr(alloc, original_expr);
            const items = sort_mod.sorted_winlinks_session(s, sort_crit);
            defer alloc.free(items);
            for (items, 0..) |entry, idx| {
                var child = child_context_for_winlink(ctx, s, entry, idx + 1 == items.len);
                const use_template = if (active_template != null and s.curw == entry) active_template.? else all_template;
                const rendered = expand_template(alloc, use_template, &child, depth + 1);
                defer alloc.free(rendered.text);
                out.appendSlice(alloc, rendered.text) catch unreachable;
                complete = complete and rendered.complete;
            }
        },
        .panes => {
            const w = ctx_window(ctx) orelse return unresolved_expr(alloc, original_expr);
            const items = sort_mod.sorted_panes_window(w, sort_crit);
            defer alloc.free(items);
            for (items, 0..) |entry, idx| {
                var child = child_context_for_pane(ctx, w, entry, idx + 1 == items.len);
                const use_template = if (active_template != null and w.active == entry) active_template.? else all_template;
                const rendered = expand_template(alloc, use_template, &child, depth + 1);
                defer alloc.free(rendered.text);
                out.appendSlice(alloc, rendered.text) catch unreachable;
                complete = complete and rendered.complete;
            }
        },
        .clients => {
            const items = sort_mod.sorted_clients(sort_crit);
            defer alloc.free(items);
            for (items, 0..) |entry, idx| {
                var child = child_context_for_client(ctx, entry, idx + 1 == items.len);
                const use_template = if (active_template != null and ctx.client == entry) active_template.? else all_template;
                const rendered = expand_template(alloc, use_template, &child, depth + 1);
                defer alloc.free(rendered.text);
                out.appendSlice(alloc, rendered.text) catch unreachable;
                complete = complete and rendered.complete;
            }
        },
        .none => unreachable,
    }

    return .{ .text = out.toOwnedSlice(alloc) catch unreachable, .complete = complete };
}

fn resolve_base_value(
    alloc: std.mem.Allocator,
    original_expr: []const u8,
    expr: []const u8,
    ctx: *const FormatContext,
    depth: u32,
    allow_option_lookup: bool,
) FormatExpandResult {
    if (expr.len == 0) return .{ .text = alloc.dupe(u8, "") catch unreachable, .complete = true };

    if (std.mem.indexOfScalar(u8, expr, '#') != null) {
        const expanded = expand_template(alloc, expr, ctx, depth + 1);
        if (!expanded.complete) return unresolved_expr(alloc, original_expr);
        if (allow_option_lookup) {
            defer alloc.free(expanded.text);
            if (lookup_option_value(alloc, expanded.text, ctx)) |value| return .{ .text = value, .complete = true };
            return unresolved_expr(alloc, original_expr);
        }
        return expanded;
    }

    if (lookup_resolver(expr)) |resolver| {
        const value = resolver.func(alloc, ctx) orelse return unresolved_key(alloc, expr, null);
        return .{ .text = value, .complete = true };
    }

    if (allow_option_lookup) {
        if (lookup_option_value(alloc, expr, ctx)) |value| {
            return .{ .text = value, .complete = true };
        }
    }

    return unresolved_key(alloc, expr, null);
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
    if (lookup_option_value(alloc, key, ctx)) |value| {
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
        'F' => "window_flags",
        'H' => "host",
        'I' => "window_index",
        'P' => "pane_index",
        'S' => "session_name",
        'T' => "pane_title",
        'W' => "window_name",
        'h' => "host_short",
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

fn split_top_level_all(alloc: std.mem.Allocator, input: []const u8, delim: u8) ?[][]const u8 {
    var parts: std.ArrayList([]const u8) = .{};
    var start: usize = 0;
    while (true) {
        const idx = index_of_top_level(input[start..], delim) orelse {
            parts.append(alloc, input[start..]) catch unreachable;
            return parts.toOwnedSlice(alloc) catch unreachable;
        };
        const abs = start + idx;
        parts.append(alloc, input[start..abs]) catch unreachable;
        start = abs + 1;
    }
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

fn index_of_top_level_any(input: []const u8, delims: []const u8) ?usize {
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
        if (depth == 0 and std.mem.indexOfScalar(u8, delims, input[i]) != null) return i;
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

fn modifier_is_end(ch: u8) bool {
    return ch == ';' or ch == ':';
}

fn build_modifiers(alloc: std.mem.Allocator, expr: []const u8) ?ParsedModifiers {
    if (index_of_top_level(expr, ':') == null) return null;

    var pos: usize = 0;
    var list: std.ArrayList(Modifier) = .{};
    while (pos < expr.len and expr[pos] != ':') {
        if (expr[pos] == ';') {
            pos += 1;
            continue;
        }

        if (pos + 1 < expr.len and modifier_is_end(expr[pos + 1])) {
            if (std.mem.indexOfScalar(u8, "labcdnwETSWPLC!<>Rqmes", expr[pos]) != null) {
                list.append(alloc, .{ .name = expr[pos .. pos + 1], .args = alloc.alloc([]const u8, 0) catch unreachable }) catch unreachable;
                pos += 1;
                continue;
            }
        }

        if (pos + 2 < expr.len and modifier_is_end(expr[pos + 2])) {
            const candidate = expr[pos .. pos + 2];
            if (std.mem.eql(u8, candidate, "||") or
                std.mem.eql(u8, candidate, "&&") or
                std.mem.eql(u8, candidate, "!!") or
                std.mem.eql(u8, candidate, "!=") or
                std.mem.eql(u8, candidate, "==") or
                std.mem.eql(u8, candidate, "<=") or
                std.mem.eql(u8, candidate, ">="))
            {
                list.append(alloc, .{ .name = candidate, .args = alloc.alloc([]const u8, 0) catch unreachable }) catch unreachable;
                pos += 2;
                continue;
            }
        }

        if (std.mem.indexOfScalar(u8, "CNtp=qmes", expr[pos]) == null) return null;
        const name = expr[pos .. pos + 1];

        if (pos + 1 >= expr.len) return null;
        if (modifier_is_end(expr[pos + 1])) {
            list.append(alloc, .{ .name = name, .args = alloc.alloc([]const u8, 0) catch unreachable }) catch unreachable;
            pos += 1;
            continue;
        }

        var args = std.ArrayList([]const u8){};
        const next = expr[pos + 1];
        if (std.ascii.isAlphanumeric(next) or next == '-') {
            const end_rel = index_of_top_level_any(expr[pos + 1 ..], ":;") orelse return null;
            const end_abs = pos + 1 + end_rel;
            args.append(alloc, expr[pos + 1 .. end_abs]) catch unreachable;
            list.append(alloc, .{ .name = name, .args = args.toOwnedSlice(alloc) catch unreachable }) catch unreachable;
            pos = end_abs;
            continue;
        }

        const wrapper = next;
        pos += 2;
        while (true) {
            const next_wrapper = index_of_top_level(expr[pos..], wrapper);
            const next_end = index_of_top_level_any(expr[pos..], ":;");
            if (next_end) |end_rel| {
                if (next_wrapper == null or end_rel < next_wrapper.?) {
                    const end_abs = pos + end_rel;
                    args.append(alloc, expr[pos..end_abs]) catch unreachable;
                    pos = end_abs;
                    break;
                }
            }

            const end_rel = next_wrapper orelse return null;
            const end_abs = pos + end_rel;
            args.append(alloc, expr[pos..end_abs]) catch unreachable;
            pos = end_abs + 1;
            if (pos >= expr.len) return null;
            if (modifier_is_end(expr[pos])) break;
        }
        list.append(alloc, .{ .name = name, .args = args.toOwnedSlice(alloc) catch unreachable }) catch unreachable;
    }

    if (pos >= expr.len or expr[pos] != ':') {
        for (list.items) |modifier| alloc.free(modifier.args);
        list.deinit(alloc);
        return null;
    }

    return .{
        .modifiers = list.toOwnedSlice(alloc) catch unreachable,
        .rest = expr[pos + 1 ..],
    };
}

fn parse_loop_sort(kind: LoopKind, args: [][]const u8) T.SortCriteria {
    const flags = if (args.len != 0) args[0] else "";
    const reversed = std.mem.indexOfScalar(u8, flags, 'r') != null;
    const order = switch (kind) {
        .sessions => if (std.mem.indexOfScalar(u8, flags, 'n') != null) T.SortOrder.name else if (std.mem.indexOfScalar(u8, flags, 't') != null) T.SortOrder.activity else T.SortOrder.index,
        .windows => if (std.mem.indexOfScalar(u8, flags, 'n') != null) T.SortOrder.name else if (std.mem.indexOfScalar(u8, flags, 't') != null) T.SortOrder.activity else T.SortOrder.index,
        .panes => T.SortOrder.creation,
        .clients => if (std.mem.indexOfScalar(u8, flags, 'n') != null) T.SortOrder.name else T.SortOrder.order,
        .none => T.SortOrder.end,
    };
    return .{ .order = order, .reversed = reversed };
}

fn format_unescape(s: []const u8) []u8 {
    var out: std.ArrayList(u8) = .{};
    var braces: u32 = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '#' and i + 1 < s.len and s[i + 1] == '{') braces += 1;
        if (braces == 0 and s[i] == '#' and i + 1 < s.len and std.mem.indexOfScalar(u8, ",#{}:", s[i + 1]) != null) {
            out.append(xm.allocator, s[i + 1]) catch unreachable;
            i += 1;
            continue;
        }
        if (s[i] == '}' and braces > 0) braces -= 1;
        out.append(xm.allocator, s[i]) catch unreachable;
    }
    return out.toOwnedSlice(xm.allocator) catch unreachable;
}

fn format_quote_shell(s: []const u8) []u8 {
    var out: std.ArrayList(u8) = .{};
    for (s) |ch| {
        if (std.mem.indexOfScalar(u8, "|&;<>()$`\\\"'*?[# =%", ch) != null) out.append(xm.allocator, '\\') catch unreachable;
        out.append(xm.allocator, ch) catch unreachable;
    }
    return out.toOwnedSlice(xm.allocator) catch unreachable;
}

fn format_quote_style(s: []const u8) []u8 {
    var out: std.ArrayList(u8) = .{};
    for (s) |ch| {
        if (ch == '#') out.append(xm.allocator, '#') catch unreachable;
        out.append(xm.allocator, ch) catch unreachable;
    }
    return out.toOwnedSlice(xm.allocator) catch unreachable;
}

fn format_basename(s: []const u8) []u8 {
    return xm.xstrdup(std.fs.path.basename(s));
}

fn format_dirname(s: []const u8) []u8 {
    return xm.xstrdup(std.fs.path.dirname(s) orelse ".");
}


pub fn format_timestamp_local(alloc: std.mem.Allocator, seconds_text: []const u8, fmt: []const u8) ?[]u8 {
    const seconds = std.fmt.parseInt(i64, seconds_text, 10) catch return null;
    var when: c.posix_sys.time_t = @intCast(seconds);
    var tm_value: c.posix_sys.struct_tm = undefined;
    if (c.posix_sys.localtime_r(&when, &tm_value) == null) return null;
    return format_strftime_tm(alloc, fmt, &tm_value);
}

fn format_pretty_time(alloc: std.mem.Allocator, seconds_text: []const u8, include_seconds: bool) ?[]u8 {
    const seconds = std.fmt.parseInt(i64, seconds_text, 10) catch return null;
    return format_pretty_time_at(alloc, std.time.timestamp(), seconds, include_seconds);
}

pub fn format_pretty_time_at(
    alloc: std.mem.Allocator,
    now_seconds: i64,
    when_seconds: i64,
    include_seconds: bool,
) ?[]u8 {
    const effective_now = @max(now_seconds, when_seconds);
    const age = effective_now - when_seconds;

    var now_time: c.posix_sys.time_t = @intCast(effective_now);
    var when_time: c.posix_sys.time_t = @intCast(when_seconds);
    var now_tm: c.posix_sys.struct_tm = undefined;
    var when_tm: c.posix_sys.struct_tm = undefined;

    if (c.posix_sys.localtime_r(&now_time, &now_tm) == null) return null;
    if (c.posix_sys.localtime_r(&when_time, &when_tm) == null) return null;

    const fmt = if (age < 24 * 3600)
        if (include_seconds) "%H:%M:%S" else "%H:%M"
    else if ((when_tm.tm_year == now_tm.tm_year and when_tm.tm_mon == now_tm.tm_mon) or age < 28 * 24 * 3600)
        "%a%d"
    else if ((when_tm.tm_year == now_tm.tm_year and when_tm.tm_mon < now_tm.tm_mon) or
        (when_tm.tm_year == now_tm.tm_year - 1 and when_tm.tm_mon > now_tm.tm_mon))
        "%d%b"
    else
        "%h%y";

    return format_strftime_tm(alloc, fmt, &when_tm);
}

fn format_strftime_now(alloc: std.mem.Allocator, fmt: []const u8) ?[]u8 {
    const now = std.time.timestamp();
    var when: c.posix_sys.time_t = @intCast(now);
    var tm_value: c.posix_sys.struct_tm = undefined;
    if (c.posix_sys.localtime_r(&when, &tm_value) == null) return null;
    return format_strftime_tm(alloc, fmt, &tm_value);
}


fn format_strftime_tm(alloc: std.mem.Allocator, fmt: []const u8, tm_value: *c.posix_sys.struct_tm) ?[]u8 {
    var cap: usize = 128;
    while (cap <= 4096) : (cap *= 2) {
        const buf = alloc.alloc(u8, cap) catch unreachable;
        const fmt_z = alloc.dupeZ(u8, fmt) catch unreachable;
        defer alloc.free(fmt_z);
        const written = c.posix_sys.strftime(buf.ptr, cap, fmt_z.ptr, tm_value);
        if (written != 0) return buf[0..written];
        alloc.free(buf);
    }
    return null;
}

const lookup_option_value = fmt_resolve.lookup_option_value;
const ctx_session = fmt_resolve.ctx_session;
const ctx_window = fmt_resolve.ctx_window;
const ctx_pane = fmt_resolve.ctx_pane;
const child_context_for_session = fmt_resolve.child_context_for_session;
const child_context_for_winlink = fmt_resolve.child_context_for_winlink;
const child_context_for_pane = fmt_resolve.child_context_for_pane;
const child_context_for_client = fmt_resolve.child_context_for_client;
const session_is_active = fmt_resolve.session_is_active;

