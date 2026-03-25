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
const c = @import("c.zig");
const cmd_render = @import("cmd-render.zig");
const colour = @import("colour.zig");
const opts = @import("options.zig");
const screen_mod = @import("screen.zig");
const sort_mod = @import("sort.zig");
const srv = @import("server.zig");
const utf8 = @import("utf8.zig");
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
    key_prefix: ?[]const u8 = null,
    key_string_width: ?u32 = null,
    key_table_width: ?u32 = null,
    notes_only: ?bool = null,
    loop_last_flag: ?bool = null,

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

    .{ .name = "client_control_mode", .func = resolve_client_control_mode },
    .{ .name = "client_height", .func = resolve_client_height },
    .{ .name = "client_key_table", .func = resolve_client_key_table },
    .{ .name = "client_prefix", .func = resolve_client_prefix },
    .{ .name = "client_readonly", .func = resolve_client_readonly },
    .{ .name = "client_session_name", .func = resolve_client_session_name },
    .{ .name = "client_tty", .func = resolve_client_tty },
    .{ .name = "client_termname", .func = resolve_client_termname },
    .{ .name = "client_utf8", .func = resolve_client_utf8 },
    .{ .name = "client_width", .func = resolve_client_width },

    .{ .name = "command_alias", .func = resolve_command_alias },
    .{ .name = "command_name", .func = resolve_command_name },
    .{ .name = "command_usage", .func = resolve_command_usage },

    .{ .name = "key_command", .func = resolve_key_command },
    .{ .name = "key_has_repeat", .func = resolve_key_has_repeat },
    .{ .name = "key_note", .func = resolve_key_note },
    .{ .name = "key_prefix", .func = resolve_key_prefix },
    .{ .name = "key_repeat", .func = resolve_key_repeat },
    .{ .name = "key_string", .func = resolve_key_string },
    .{ .name = "key_string_width", .func = resolve_key_string_width },
    .{ .name = "key_table", .func = resolve_key_table },
    .{ .name = "key_table_width", .func = resolve_key_table_width },
    .{ .name = "loop_last_flag", .func = resolve_loop_last_flag },
    .{ .name = "notes_only", .func = resolve_notes_only },

    .{ .name = "host", .func = resolve_host },
    .{ .name = "host_short", .func = resolve_host_short },

    .{ .name = "pid", .func = resolve_pid },
    .{ .name = "socket_path", .func = resolve_socket_path },
    .{ .name = "start_time", .func = resolve_start_time },

    .{ .name = "alternate_on", .func = resolve_alternate_on },
    .{ .name = "alternate_saved_x", .func = resolve_alternate_saved_x },
    .{ .name = "alternate_saved_y", .func = resolve_alternate_saved_y },
    .{ .name = "cursor_flag", .func = resolve_cursor_flag },
    .{ .name = "cursor_x", .func = resolve_cursor_x },
    .{ .name = "cursor_y", .func = resolve_cursor_y },

    .{ .name = "pane_active", .func = resolve_pane_active },
    .{ .name = "pane_current_command", .func = resolve_pane_current_command },
    .{ .name = "pane_dead", .func = resolve_pane_dead },
    .{ .name = "pane_dead_status", .func = resolve_pane_dead_status },
    .{ .name = "pane_height", .func = resolve_pane_height },
    .{ .name = "pane_id", .func = resolve_pane_id },
    .{ .name = "pane_in_mode", .func = resolve_pane_in_mode },
    .{ .name = "pane_index", .func = resolve_pane_index },
    .{ .name = "pane_pid", .func = resolve_pane_pid },
    .{ .name = "pane_pipe", .func = resolve_pane_pipe },
    .{ .name = "pane_pipe_pid", .func = resolve_pane_pipe_pid },
    .{ .name = "pane_path", .func = resolve_pane_path },
    .{ .name = "pane_start_command", .func = resolve_pane_start_command },
    .{ .name = "pane_start_path", .func = resolve_pane_start_path },
    .{ .name = "pane_tty", .func = resolve_pane_tty },
    .{ .name = "pane_title", .func = resolve_pane_title },
    .{ .name = "pane_width", .func = resolve_pane_width },

    .{ .name = "scroll_region_lower", .func = resolve_scroll_region_lower },
    .{ .name = "scroll_region_upper", .func = resolve_scroll_region_upper },

    .{ .name = "session_active", .func = resolve_session_active },
    .{ .name = "session_attached", .func = resolve_session_attached },
    .{ .name = "session_alerts", .func = resolve_session_alerts },
    .{ .name = "session_created", .func = resolve_session_created },
    .{ .name = "session_group", .func = resolve_session_group },
    .{ .name = "session_group_list", .func = resolve_session_group_list },
    .{ .name = "session_grouped", .func = resolve_session_grouped },
    .{ .name = "session_id", .func = resolve_session_id },
    .{ .name = "session_name", .func = resolve_session_name },
    .{ .name = "session_windows", .func = resolve_session_windows },

    .{ .name = "window_active", .func = resolve_window_active },
    .{ .name = "window_bigger", .func = resolve_window_bigger },
    .{ .name = "window_flags", .func = resolve_window_flags },
    .{ .name = "window_height", .func = resolve_window_height },
    .{ .name = "window_id", .func = resolve_window_id },
    .{ .name = "window_index", .func = resolve_window_index },
    .{ .name = "window_linked", .func = resolve_window_linked },
    .{ .name = "window_name", .func = resolve_window_name },
    .{ .name = "window_offset_x", .func = resolve_window_offset_x },
    .{ .name = "window_offset_y", .func = resolve_window_offset_y },
    .{ .name = "window_panes", .func = resolve_window_panes },
    .{ .name = "window_raw_flags", .func = resolve_window_raw_flags },
    .{ .name = "window_zoomed_flag", .func = resolve_window_zoomed_flag },
    .{ .name = "window_width", .func = resolve_window_width },
    .{ .name = "version", .func = resolve_version },
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

pub fn format_filter_match(alloc: std.mem.Allocator, filter: []const u8, ctx: *const FormatContext) ?bool {
    const expanded = format_require_complete(alloc, filter, ctx) orelse return null;
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
    var bool_and: ?bool = null;
    var negate = false;
    var truthy_only = false;
    var loop_kind: LoopKind = .none;
    var loop_sort: T.SortCriteria = .{ .order = .end, .reversed = false };
    var name_check: NameCheckKind = .none;

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

    for (modifiers) |modifier| {
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
        } else if (std.mem.eql(u8, modifier.name, "!!")) {
            truthy_only = true;
        } else if (std.mem.eql(u8, modifier.name, "R")) {
            repeat_output = true;
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

    if (time_pretty) return unresolved_expr(alloc, original_expr);

    if (loop_kind != .none) {
        return eval_loop_expr(alloc, original_expr, copy, loop_kind, loop_sort, ctx, depth + 1);
    }

    if (name_check != .none) {
        return eval_name_check_expr(alloc, original_expr, copy, name_check, ctx, depth + 1);
    }

    if (repeat_output) {
        const parts = split_top_level_2(copy, ',') orelse return unresolved_expr(alloc, original_expr);
        const body = expand_template(alloc, parts.a, ctx, depth + 1);
        defer alloc.free(body.text);
        const count_text = expand_value_expr(alloc, parts.b, ctx, depth + 1);
        defer alloc.free(count_text.text);
        if (!body.complete or !count_text.complete) return unresolved_expr(alloc, original_expr);
        const count = std.fmt.parseInt(u32, count_text.text, 10) catch return unresolved_expr(alloc, original_expr);

        var out: std.ArrayList(u8) = .{};
        for (0..count) |_| out.appendSlice(alloc, body.text) catch unreachable;
        return .{ .text = out.toOwnedSlice(alloc) catch unreachable, .complete = true };
    }

    if (negate or truthy_only or bool_and != null or compare != .none) {
        return eval_boolean_expr(alloc, original_expr, copy, compare, negate, truthy_only, bool_and, ctx, depth + 1);
    }

    const value = if (literal)
        FormatExpandResult{ .text = format_unescape(copy), .complete = true }
    else if (char_output)
        eval_character_expr(alloc, original_expr, copy, ctx, depth + 1)
    else if (colour_output)
        eval_colour_expr(alloc, original_expr, copy, ctx, depth + 1)
    else
        resolve_base_value(alloc, original_expr, copy, ctx, depth + 1, expand_nested or expand_time);
    if (!value.complete) return unresolved_expr(alloc, original_expr);
    defer alloc.free(value.text);

    var working = alloc.dupe(u8, value.text) catch unreachable;
    errdefer alloc.free(working);

    if (time_string) {
        const fmt = if (time_format_spec) |raw_fmt| blk: {
            const expanded_fmt = expand_template(alloc, raw_fmt, ctx, depth + 1);
            defer alloc.free(expanded_fmt.text);
            if (!expanded_fmt.complete) return unresolved_expr(alloc, original_expr);
            break :blk expanded_fmt.text;
        } else "%Y-%m-%d %H:%M:%S";
        const rendered = format_timestamp_local(alloc, working, fmt) orelse {
            alloc.free(working);
            return unresolved_expr(alloc, original_expr);
        };
        alloc.free(working);
        working = rendered;
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
            utf8.utf8_trim_left(working, @intCast(limit))
        else if (limit < 0)
            utf8.utf8_trim_right(working, @intCast(-limit))
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
            utf8.utf8_padcstr(working, @intCast(pad))
        else if (pad < 0)
            utf8.utf8_rpadcstr(working, @intCast(-pad))
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
        const rendered = xm.xasprintf("{d}", .{utf8.utf8_cstrwidth(working)});
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

    if (compare != .none) {
        const parts = split_top_level_2(copy, ',') orelse return unresolved_expr(alloc, original_expr);
        const left = expand_value_expr(alloc, parts.a, ctx, depth + 1);
        defer alloc.free(left.text);
        const right = expand_value_expr(alloc, parts.b, ctx, depth + 1);
        defer alloc.free(right.text);
        if (!left.complete or !right.complete) return unresolved_expr(alloc, original_expr);

        const truth = switch (compare) {
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
                if (std.mem.eql(u8, wl.window.name, expanded.text)) break :blk true;
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
            if (std.mem.indexOfScalar(u8, "labcdnwETSWPL!<>Rq", expr[pos]) != null) {
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

        if (std.mem.indexOfScalar(u8, "Ntp=q", expr[pos]) == null) return null;
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
            const end_rel = index_of_top_level(expr[pos..], wrapper) orelse return null;
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

fn c_string_bytes(bytes: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, bytes, 0) orelse bytes.len;
    return bytes[0..end];
}

fn format_timestamp_local(alloc: std.mem.Allocator, seconds_text: []const u8, fmt: []const u8) ?[]u8 {
    const seconds = std.fmt.parseInt(i64, seconds_text, 10) catch return null;
    var when: c.posix_sys.time_t = @intCast(seconds);
    var tm_value: c.posix_sys.struct_tm = undefined;
    if (c.posix_sys.localtime_r(&when, &tm_value) == null) return null;
    return format_strftime_tm(alloc, fmt, &tm_value);
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

fn lookup_option_value(alloc: std.mem.Allocator, name: []const u8, ctx: *const FormatContext) ?[]u8 {
    const found = find_option_value(name, ctx) orelse return null;
    return switch (found.value.*) {
        .array => |arr| std.mem.join(alloc, " ", arr.items) catch unreachable,
        else => opts.options_value_to_string(name, found.value, found.entry),
    };
}

const FoundOption = struct {
    value: *const T.OptionsValue,
    entry: ?*const T.OptionsTableEntry,
};

fn find_option_value(name: []const u8, ctx: *const FormatContext) ?FoundOption {
    const entry = opts.options_table_entry(name);
    if (entry) |oe| {
        if (oe.scope.pane) {
            if (ctx_pane(ctx)) |wp| {
                if (opts.options_get(wp.options, name)) |value| return .{ .value = value, .entry = oe };
            }
        }
        if (oe.scope.window) {
            if (ctx_window(ctx)) |w| {
                if (opts.options_get(w.options, name)) |value| return .{ .value = value, .entry = oe };
            }
        }
        if (oe.scope.session) {
            if (ctx_session(ctx)) |s| {
                if (opts.options_get(s.options, name)) |value| return .{ .value = value, .entry = oe };
            } else if (opts.options_get(opts.global_s_options, name)) |value| {
                return .{ .value = value, .entry = oe };
            }
        }
        if (oe.scope.server) {
            if (opts.options_get(opts.global_options, name)) |value| return .{ .value = value, .entry = oe };
        }
        return null;
    }

    if (!(name.len > 0 and name[0] == '@')) return null;

    if (ctx_pane(ctx)) |wp| {
        if (opts.options_get(wp.options, name)) |value| return .{ .value = value, .entry = null };
    }
    if (ctx_window(ctx)) |w| {
        if (opts.options_get(w.options, name)) |value| return .{ .value = value, .entry = null };
    }
    if (ctx_session(ctx)) |s| {
        if (opts.options_get(s.options, name)) |value| return .{ .value = value, .entry = null };
    }
    if (opts.options_get(opts.global_options, name)) |value| return .{ .value = value, .entry = null };
    if (opts.options_get(opts.global_s_options, name)) |value| return .{ .value = value, .entry = null };
    if (opts.options_get(opts.global_w_options, name)) |value| return .{ .value = value, .entry = null };
    return null;
}

fn child_context_for_session(base: *const FormatContext, s: *T.Session, last: bool) FormatContext {
    var child = base.*;
    child.session = s;
    child.winlink = s.curw;
    child.window = if (s.curw) |wl| wl.window else null;
    child.pane = if (s.curw) |wl| wl.window.active else null;
    child.loop_last_flag = last;
    return child;
}

fn child_context_for_winlink(base: *const FormatContext, s: *T.Session, wl: *T.Winlink, last: bool) FormatContext {
    var child = base.*;
    child.session = s;
    child.winlink = wl;
    child.window = wl.window;
    child.pane = wl.window.active;
    child.loop_last_flag = last;
    return child;
}

fn child_context_for_pane(base: *const FormatContext, w: *T.Window, wp: *T.WindowPane, last: bool) FormatContext {
    var child = base.*;
    child.window = w;
    child.pane = wp;
    child.loop_last_flag = last;
    return child;
}

fn child_context_for_client(base: *const FormatContext, cl: *T.Client, last: bool) FormatContext {
    var child = base.*;
    child.client = cl;
    if (cl.session) |s| {
        child.session = s;
        child.winlink = s.curw;
        child.window = if (s.curw) |wl| wl.window else null;
        child.pane = if (s.curw) |wl| wl.window.active else null;
    }
    child.loop_last_flag = last;
    return child;
}

fn session_is_active(base: *const FormatContext, s: *T.Session) bool {
    if (base.client) |cl| return cl.session == s;
    return base.session == s;
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

fn resolve_client_control_mode(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const cl = ctx.client orelse return null;
    return alloc.dupe(u8, if (cl.flags & T.CLIENT_CONTROL != 0) "1" else "0") catch unreachable;
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

fn resolve_client_key_table(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const cl = ctx.client orelse return null;
    return alloc.dupe(u8, cl.key_table_name orelse "root") catch unreachable;
}

fn resolve_client_prefix(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const cl = ctx.client orelse return null;
    return alloc.dupe(u8, if (cl.key_table_name != null and std.mem.eql(u8, cl.key_table_name.?, "prefix")) "1" else "0") catch unreachable;
}

fn resolve_client_readonly(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const cl = ctx.client orelse return null;
    return alloc.dupe(u8, if (cl.flags & T.CLIENT_READONLY != 0) "1" else "0") catch unreachable;
}

fn resolve_client_termname(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const cl = ctx.client orelse return null;
    return alloc.dupe(u8, cl.term_name orelse "") catch unreachable;
}

fn resolve_client_utf8(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const cl = ctx.client orelse return null;
    return alloc.dupe(u8, if (cl.flags & T.CLIENT_UTF8 != 0) "1" else "0") catch unreachable;
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

fn resolve_loop_last_flag(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    return alloc.dupe(u8, if (ctx.loop_last_flag orelse false) "1" else "0") catch unreachable;
}

fn resolve_notes_only(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const binding = resolve_key_binding(ctx) orelse return null;
    _ = binding;
    const value: []const u8 = if (ctx.notes_only orelse false) "1" else "0";
    return alloc.dupe(u8, value) catch unreachable;
}

fn resolve_host(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    _ = ctx;
    var uts: c.posix_sys.struct_utsname = undefined;
    if (c.posix_sys.uname(&uts) != 0) return alloc.dupe(u8, "") catch unreachable;
    return alloc.dupe(u8, c_string_bytes(uts.nodename[0..])) catch unreachable;
}

fn resolve_host_short(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const host = resolve_host(alloc, ctx) orelse return null;
    defer alloc.free(host);
    const short = std.mem.indexOfScalar(u8, host, '.') orelse host.len;
    return alloc.dupe(u8, host[0..short]) catch unreachable;
}

fn resolve_pid(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    _ = alloc;
    _ = ctx;
    return xm.xasprintf("{d}", .{std.c.getpid()});
}

fn resolve_socket_path(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    _ = ctx;
    return alloc.dupe(u8, srv.socket_path) catch unreachable;
}

fn resolve_start_time(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    _ = alloc;
    _ = ctx;
    return xm.xasprintf("{d}", .{srv.start_time.sec});
}

fn resolve_alternate_on(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const wp = ctx_pane(ctx) orelse return null;
    return alloc.dupe(u8, if (screen_mod.screen_alternate_active(wp)) "1" else "0") catch unreachable;
}

fn resolve_alternate_saved_x(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    _ = alloc;
    const wp = ctx_pane(ctx) orelse return null;
    return xm.xasprintf("{d}", .{wp.screen.saved_cx});
}

fn resolve_alternate_saved_y(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    _ = alloc;
    const wp = ctx_pane(ctx) orelse return null;
    return xm.xasprintf("{d}", .{wp.screen.saved_cy});
}

fn resolve_cursor_flag(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const wp = ctx_pane(ctx) orelse return null;
    const screen = screen_mod.screen_current(wp);
    return alloc.dupe(u8, if (screen.cursor_visible) "1" else "0") catch unreachable;
}

fn resolve_cursor_x(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    _ = alloc;
    const wp = ctx_pane(ctx) orelse return null;
    const screen = screen_mod.screen_current(wp);
    return xm.xasprintf("{d}", .{screen.cx});
}

fn resolve_cursor_y(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    _ = alloc;
    const wp = ctx_pane(ctx) orelse return null;
    const screen = screen_mod.screen_current(wp);
    return xm.xasprintf("{d}", .{screen.cy});
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

fn resolve_session_active(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const s = ctx_session(ctx) orelse return null;
    const active = if (ctx.client) |cl| cl.session == s else ctx.session == s;
    return alloc.dupe(u8, if (active) "1" else "0") catch unreachable;
}

fn resolve_session_attached(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const s = ctx_session(ctx) orelse return null;
    const value: []const u8 = if (s.attached > 0) "1" else "0";
    return alloc.dupe(u8, value) catch unreachable;
}

fn resolve_session_alerts(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const s = ctx_session(ctx) orelse return null;
    var has_activity = false;
    var has_bell = false;
    var has_silence = false;
    var it = s.windows.valueIterator();
    while (it.next()) |wl| {
        has_activity = has_activity or (wl.flags & T.WINLINK_ACTIVITY != 0);
        has_bell = has_bell or (wl.flags & T.WINLINK_BELL != 0);
        has_silence = has_silence or (wl.flags & T.WINLINK_SILENCE != 0);
    }

    var out: std.ArrayList(u8) = .{};
    if (has_activity) out.append(alloc, '#') catch unreachable;
    if (has_bell) out.append(alloc, '!') catch unreachable;
    if (has_silence) out.append(alloc, '~') catch unreachable;
    return out.toOwnedSlice(alloc) catch unreachable;
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

fn resolve_session_id(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    _ = alloc;
    const s = ctx_session(ctx) orelse return null;
    return xm.xasprintf("${d}", .{s.id});
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

fn resolve_window_bigger(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const w = ctx_window(ctx) orelse return null;
    const cl = ctx.client orelse return alloc.dupe(u8, "0") catch unreachable;
    const bigger = w.sx > cl.tty.sx or w.sy > cl.tty.sy;
    return alloc.dupe(u8, if (bigger) "1" else "0") catch unreachable;
}

fn resolve_window_id(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const w = ctx_window(ctx) orelse return null;
    _ = alloc;
    return xm.xasprintf("@{d}", .{w.id});
}

fn resolve_window_linked(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const w = ctx_window(ctx) orelse return null;
    return alloc.dupe(u8, if (w.references > 1) "1" else "0") catch unreachable;
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

fn resolve_window_offset_x(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    _ = alloc;
    const wp = ctx_pane(ctx) orelse return null;
    return xm.xasprintf("{d}", .{wp.xoff});
}

fn resolve_window_offset_y(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    _ = alloc;
    const wp = ctx_pane(ctx) orelse return null;
    return xm.xasprintf("{d}", .{wp.yoff});
}

fn resolve_window_zoomed_flag(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const w = ctx_window(ctx) orelse return null;
    return alloc.dupe(u8, if (w.flags & T.WINDOW_ZOOMED != 0) "1" else "0") catch unreachable;
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

fn resolve_pane_pipe(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const wp = ctx_pane(ctx) orelse return null;
    const active = wp.pipe_fd >= 0 or wp.pipe_pid > 0;
    return alloc.dupe(u8, if (active) "1" else "0") catch unreachable;
}

fn resolve_pane_pipe_pid(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const wp = ctx_pane(ctx) orelse return null;
    if (wp.pipe_pid <= 0) return alloc.dupe(u8, "") catch unreachable;
    return xm.xasprintf("{d}", .{wp.pipe_pid});
}

fn resolve_pane_path(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const wp = ctx_pane(ctx) orelse return null;
    if (wp.screen.path) |path| return alloc.dupe(u8, path) catch unreachable;
    if (wp.cwd) |cwd| return alloc.dupe(u8, cwd) catch unreachable;
    return alloc.dupe(u8, "") catch unreachable;
}

fn resolve_pane_start_command(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const wp = ctx_pane(ctx) orelse return null;
    if (wp.argv) |argv| return cmd_render.stringify_argv(alloc, argv);
    if (wp.shell) |shell| return alloc.dupe(u8, shell) catch unreachable;
    return alloc.dupe(u8, "") catch unreachable;
}

fn resolve_pane_start_path(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const wp = ctx_pane(ctx) orelse return null;
    return alloc.dupe(u8, wp.cwd orelse "") catch unreachable;
}

fn resolve_pane_tty(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    const wp = ctx_pane(ctx) orelse return null;
    return alloc.dupe(u8, c_string_bytes(wp.tty_name[0..])) catch unreachable;
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
        const text = cmd_render.stringify_argv(alloc, argv);
        defer alloc.free(text);
        return names.parse_window_name(text);
    }
    if (wp.shell) |shell| return names.parse_window_name(shell);
    return alloc.dupe(u8, "") catch unreachable;
}

fn resolve_scroll_region_upper(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    _ = alloc;
    const wp = ctx_pane(ctx) orelse return null;
    const screen = screen_mod.screen_current(wp);
    return xm.xasprintf("{d}", .{screen.rupper});
}

fn resolve_scroll_region_lower(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    _ = alloc;
    const wp = ctx_pane(ctx) orelse return null;
    const screen = screen_mod.screen_current(wp);
    return xm.xasprintf("{d}", .{screen.rlower});
}

fn resolve_version(alloc: std.mem.Allocator, ctx: *const FormatContext) ?[]u8 {
    _ = ctx;
    return alloc.dupe(u8, T.ZMUX_VERSION) catch unreachable;
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
    const expected = format_timestamp_local(xm.allocator, "0", "%Y-%m-%d %H:%M:%S").?;
    defer xm.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, timed.text);

    const unresolved = format_expand(xm.allocator, "#{definitely_missing}", &ctx);
    defer xm.allocator.free(unresolved.text);
    try std.testing.expect(!unresolved.complete);
    try std.testing.expectEqualStrings("#{definitely_missing}", unresolved.text);
    try std.testing.expect(format_require_complete(xm.allocator, "#{definitely_missing}", &ctx) == null);
}

test "format_expand handles width, pad, repeat, and comparisons" {
    var screen = T.Screen{
        .grid = undefined,
        .title = xm.xstrdup("abcdef"),
    };
    defer xm.allocator.free(screen.title.?);

    var w = T.Window{
        .id = 1,
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

    var wp = T.WindowPane{
        .id = 1,
        .window = &w,
        .options = undefined,
        .sx = 80,
        .sy = 24,
        .cwd = xm.xstrdup("/tmp/demo"),
        .screen = &screen,
        .base = screen,
    };
    defer xm.allocator.free(wp.cwd.?);
    w.active = &wp;
    w.panes.append(xm.allocator, &wp) catch unreachable;

    const ctx = FormatContext{ .window = &w, .pane = &wp, .message_text = "a b" };

    const rendered = format_expand(
        xm.allocator,
        "#{=4:pane_title}|#{p6:pane_title}|#{b:pane_path}|#{d:pane_path}|#{q:message_text}|#{R:xy,3}|#{<:aaa,bbb}|#{>=:bbb,bbb}",
        &ctx,
    );
    defer xm.allocator.free(rendered.text);
    try std.testing.expect(rendered.complete);
    try std.testing.expectEqualStrings("abcd|abcdef|demo|/tmp|a\\ b|xyxyxy|1|1", rendered.text);
}

test "format_expand supports option indirection and loops" {
    const env_mod = @import("environ.zig");
    const win_mod = @import("window.zig");

    sess.session_init_globals(xm.allocator);
    win_mod.window_init_globals(xm.allocator);

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

    const session_opts_a = opts.options_create(opts.global_s_options);
    const session_env_a = env_mod.environ_create();
    const sa = sess.session_create(null, "alpha", "/", session_env_a, session_opts_a, null);
    defer sess.session_destroy(sa, false, "test");

    const session_opts_b = opts.options_create(opts.global_s_options);
    const session_env_b = env_mod.environ_create();
    const sb = sess.session_create(null, "beta", "/", session_env_b, session_opts_b, null);
    defer sess.session_destroy(sb, false, "test");

    opts.options_set_string(sa.options, false, "@clock", "%H:%M");

    const w1 = win_mod.window_create(80, 24, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    xm.allocator.free(w1.name);
    w1.name = xm.xstrdup("one");
    var cause_a: ?[]u8 = null;
    const wl1 = sess.session_attach(sa, w1, 0, &cause_a).?;
    sa.curw = wl1;
    w1.active = win_mod.window_add_pane(w1, null, 80, 24);
    w1.active.?.screen.title = xm.xstrdup("pane-a");

    const w2 = win_mod.window_create(80, 24, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    xm.allocator.free(w2.name);
    w2.name = xm.xstrdup("two");
    var cause_b: ?[]u8 = null;
    _ = sess.session_attach(sa, w2, 1, &cause_b).?;
    w2.active = win_mod.window_add_pane(w2, null, 80, 24);
    w2.active.?.screen.title = xm.xstrdup("pane-b");

    const ctx = FormatContext{
        .session = sa,
        .winlink = wl1,
        .window = w1,
        .pane = w1.active.?,
    };

    const left = format_require_complete(xm.allocator, "#{E:status-left}", &ctx).?;
    defer xm.allocator.free(left);
    try std.testing.expectEqualStrings("[alpha] ", left);

    const clock = format_require_complete(xm.allocator, "#{T:@clock}", &ctx).?;
    defer xm.allocator.free(clock);
    try std.testing.expectEqual(@as(usize, 5), clock.len);
    try std.testing.expect(clock[2] == ':');

    const loop = format_require_complete(xm.allocator, "#{W:#{window_name}#{?loop_last_flag,,|},[#{window_name}]#{?loop_last_flag,,|}}", &ctx).?;
    defer xm.allocator.free(loop);
    try std.testing.expectEqualStrings("[one]|two", loop);

    const sessions_loop = format_require_complete(xm.allocator, "#{S:#{session_name}#{?loop_last_flag,,|},[#{session_name}]#{?loop_last_flag,,|}}", &ctx).?;
    defer xm.allocator.free(sessions_loop);
    try std.testing.expectEqualStrings("[alpha]|beta", sessions_loop);
}

test "format_expand covers key option-table defaults" {
    const env_mod = @import("environ.zig");
    const win_mod = @import("window.zig");

    sess.session_init_globals(xm.allocator);
    win_mod.window_init_globals(xm.allocator);

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
    const s = sess.session_create(null, "defaults", "/", session_env, session_opts, null);
    defer sess.session_destroy(s, false, "test");

    const w = win_mod.window_create(80, 24, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    xm.allocator.free(w.name);
    w.name = xm.xstrdup("editor");
    var cause: ?[]u8 = null;
    const wl = sess.session_attach(s, w, 0, &cause).?;
    s.curw = wl;
    const wp = win_mod.window_add_pane(w, null, 80, 24);
    w.active = wp;
    wp.shell = xm.xstrdup("sh");
    wp.screen.title = xm.xstrdup("pane-title");

    const ctx = FormatContext{
        .session = s,
        .winlink = wl,
        .window = w,
        .pane = wp,
    };

    const automatic = format_require_complete(xm.allocator, "#{E:automatic-rename-format}", &ctx).?;
    defer xm.allocator.free(automatic);
    try std.testing.expectEqualStrings("sh", automatic);

    wp.flags |= T.PANE_EXITED;
    wp.status = 7;
    const remain = format_require_complete(xm.allocator, "#{E:remain-on-exit-format}", &ctx).?;
    defer xm.allocator.free(remain);
    try std.testing.expectEqualStrings("Pane is dead (7)", remain);
    wp.flags &= ~T.PANE_EXITED;

    const border = format_require_complete(xm.allocator, "#{E:pane-border-format}", &ctx).?;
    defer xm.allocator.free(border);
    try std.testing.expectEqualStrings("#[reverse]0#[default] \"pane-title\"", border);

    const window_status = format_require_complete(xm.allocator, "#{E:window-status-format}", &ctx).?;
    defer xm.allocator.free(window_status);
    try std.testing.expectEqualStrings("0:editor*", window_status);

    const titles = format_require_complete(xm.allocator, "#{T:set-titles-string}", &ctx).?;
    defer xm.allocator.free(titles);
    try std.testing.expect(std.mem.indexOf(u8, titles, "#{") == null);
    try std.testing.expect(std.mem.indexOf(u8, titles, "defaults") != null);

    const status_right = format_require_complete(xm.allocator, "#{T:status-right}", &ctx).?;
    defer xm.allocator.free(status_right);
    try std.testing.expect(std.mem.indexOf(u8, status_right, "#{") == null);
    try std.testing.expect(std.mem.indexOf(u8, status_right, "pane-title") != null);
}
