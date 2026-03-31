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
// Ported in part from tmux/cmd-display-menu.c.
// Original copyright:
//   Copyright (c) 2019 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

const std = @import("std");
const T = @import("types.zig");
const args_mod = @import("arguments.zig");
const cmd_display = @import("cmd-display-message.zig");
const cmd_display_panes = @import("cmd-display-panes.zig");
const cmd_find = @import("cmd-find.zig");
const cmd_mod = @import("cmd.zig");
const cmd_render = @import("cmd-render.zig");
const cmdq = @import("cmd-queue.zig");
const format_draw = @import("format-draw.zig");
const job_mod = @import("job.zig");
const key_string = @import("key-string.zig");
const menu_mod = @import("menu.zig");
const mouse_runtime = @import("mouse-runtime.zig");
const opts = @import("options.zig");
const popup = @import("popup.zig");
const server_client = @import("server-client.zig");
const server_fn = @import("server-fn.zig");
const status = @import("status.zig");
const utf8 = @import("utf8.zig");
const xm = @import("xmalloc.zig");
const env_mod = @import("environ.zig");

const POPUP_BORDER_NONE: u32 = 6;

const ValidationResult = enum {
    ok,
    noop,
    err,
};

fn require_target_client(item: *cmdq.CmdqItem) ?*T.Client {
    const tc = cmdq.cmdq_get_target_client(item) orelse {
        cmdq.cmdq_error(item, "no target client", .{});
        return null;
    };
    if (tc.session == null) {
        cmdq.cmdq_error(item, "no target client", .{});
        return null;
    }
    return tc;
}

fn resolve_target(item: *cmdq.CmdqItem, target_name: ?[]const u8) ?T.CmdFindState {
    var target: T.CmdFindState = .{};
    if (cmd_find.cmd_find_target(&target, item, target_name, .pane, T.CMD_FIND_CANFAIL) != 0)
        return null;
    return target;
}

fn validate_choice(item: *cmdq.CmdqItem, option_name: []const u8, value: []const u8) bool {
    const oe = opts.options_table_entry(option_name) orelse {
        cmdq.cmdq_error(item, "{s} is unavailable", .{option_name});
        return false;
    };
    const idx = opts.options_choice_index(oe, value) orelse {
        cmdq.cmdq_error(item, "{s} invalid choice: {s}", .{ option_name, value });
        return false;
    };
    if (oe.choices) |choices| {
        if (idx >= choices.len) {
            cmdq.cmdq_error(item, "{s} invalid choice: {s}", .{ option_name, value });
            return false;
        }
    }
    return true;
}

fn validate_display_menu(args: *const args_mod.Arguments, item: *cmdq.CmdqItem) ValidationResult {
    if (args.has('C')) {
        const value = args.get('C').?;
        if (!std.mem.eql(u8, value, "-")) {
            var cause: ?[]u8 = null;
            _ = args_mod.args_strtonum(args, 'C', 0, std.math.maxInt(u32), &cause);
            if (cause) |msg| {
                defer xm.allocator.free(msg);
                cmdq.cmdq_error(item, "starting choice {s}", .{msg});
                return .err;
            }
        }
    }

    var count: usize = 0;
    var i: usize = 0;
    while (i < args.count()) {
        const name = args.value_at(i).?;
        i += 1;
        if (name.len == 0)
            continue;

        count += 1;
        if (args.count() - i < 2) {
            cmdq.cmdq_error(item, "not enough arguments", .{});
            return .err;
        }
        i += 2;
    }

    if (count == 0)
        return .noop;

    if (args.get('b')) |value| {
        if (!validate_choice(item, "menu-border-lines", value))
            return .err;
    }

    return .ok;
}

fn menu_title(args: *const args_mod.Arguments, target: *const T.CmdFindState) []u8 {
    if (args.get('T')) |raw| return cmd_display.expand_format(xm.allocator, raw, target);
    return xm.xstrdup("");
}

fn build_menu_item(
    raw_name: []const u8,
    raw_key: []const u8,
    raw_command: []const u8,
    target: *const T.CmdFindState,
    tc: *const T.Client,
) ?menu_mod.MenuItem {
    const expanded_name = cmd_display.expand_format(xm.allocator, raw_name, target);
    defer xm.allocator.free(expanded_name);
    if (expanded_name.len == 0) return null;

    const key = key_string.key_string_lookup_string(raw_key);
    const dimmed = expanded_name[0] == '-';
    var display_text: []u8 = undefined;

    if (dimmed) {
        display_text = xm.xstrdup(expanded_name[1..]);
    } else {
        const max_width_limit: u32 = tc.tty.sx -| 4;
        var available_width = max_width_limit;
        var key_text: ?[]const u8 = null;
        if (key != T.KEYC_UNKNOWN and key != T.KEYC_NONE) {
            const candidate = key_string.key_string_lookup_key(key, 0);
            const candidate_width: u32 = utf8.utf8_cstrwidth(candidate) + 3;
            const name_width = @min(format_display_width(expanded_name), max_width_limit);
            if (candidate_width <= max_width_limit / 4)
                available_width = max_width_limit - candidate_width
            else if (candidate_width < max_width_limit and name_width < max_width_limit - candidate_width)
                key_text = candidate
            else
                key_text = null;
            if (candidate_width <= max_width_limit / 4)
                key_text = candidate;
        }

        var suffix: []const u8 = "";
        if (format_display_width(expanded_name) > available_width and available_width > 0) {
            available_width -= 1;
            suffix = ">";
        }
        const trimmed = utf8.utf8_trim_left(expanded_name, available_width);
        defer xm.allocator.free(trimmed);

        if (key_text) |rendered|
            display_text = xm.xasprintf("{s}{s}#[default] #[align=right]({s})", .{ trimmed, suffix, rendered })
        else
            display_text = xm.xasprintf("{s}{s}", .{ trimmed, suffix });
    }

    const expanded_command = cmd_display.expand_format(xm.allocator, raw_command, target);
    return .{
        .display_text = display_text,
        .command = expanded_command,
        .key = key,
        .dimmed = dimmed,
    };
}

fn build_menu(args: *const args_mod.Arguments, target: *const T.CmdFindState, tc: *const T.Client) ?*menu_mod.Menu {
    var items: std.ArrayList(menu_mod.MenuItem) = .{};
    defer {
        for (items.items) |*item| item.deinit();
        items.deinit(xm.allocator);
    }

    const title = menu_title(args, target);
    errdefer xm.allocator.free(title);
    var width: u32 = format_display_width(title);

    var i: usize = 0;
    while (i < args.count()) {
        const name = args.value_at(i).?;
        i += 1;
        if (name.len == 0) {
            if (items.items.len == 0) continue;
            if (items.items[items.items.len - 1].separator) continue;
            items.append(xm.allocator, .{ .separator = true }) catch unreachable;
            continue;
        }

        if (args.count() - i < 2) return null;
        const key = args.value_at(i).?;
        const command = args.value_at(i + 1).?;
        i += 2;

        const built = build_menu_item(name, key, command, target, tc) orelse continue;
        width = @max(width, format_display_width(built.display_text orelse ""));
        items.append(xm.allocator, built) catch unreachable;
    }

    if (items.items.len == 0) {
        xm.allocator.free(title);
        return null;
    }

    const menu = xm.allocator.create(menu_mod.Menu) catch unreachable;
    menu.* = .{
        .title = title,
        .items = xm.allocator.dupe(menu_mod.MenuItem, items.items) catch unreachable,
        .width = width,
    };
    for (menu.items, 0..) |*item, idx| {
        item.* = items.items[idx];
    }
    items.clearRetainingCapacity();
    return menu;
}

fn format_display_width(text: []const u8) u32 {
    return format_draw.format_width(text);
}

fn menu_lines(args: *const args_mod.Arguments, item: *cmdq.CmdqItem, options: *T.Options) ?u32 {
    if (args.get('b')) |value| {
        const oe = opts.options_table_entry("menu-border-lines") orelse return null;
        return opts.options_choice_index(oe, value) orelse {
            cmdq.cmdq_error(item, "menu-border-lines invalid choice: {s}", .{value});
            return null;
        };
    }
    return @intCast(opts.options_get_number(options, "menu-border-lines"));
}

fn menu_flags(args: *const args_mod.Arguments, event: *const T.key_event) i32 {
    var flags: i32 = 0;
    if (args.has('O')) flags |= menu_mod.MENU_STAYOPEN;
    if (!event.m.valid and !args.has('M')) flags |= menu_mod.MENU_NOMOUSE;
    return flags;
}

fn menu_starting_choice(args: *const args_mod.Arguments, item: *cmdq.CmdqItem) ?i32 {
    if (!args.has('C')) return 0;
    const value = args.get('C').?;
    if (std.mem.eql(u8, value, "-")) return -1;

    var cause: ?[]u8 = null;
    const parsed = args_mod.args_strtonum(args, 'C', 0, std.math.maxInt(u32), &cause);
    if (cause) |msg| {
        defer xm.allocator.free(msg);
        cmdq.cmdq_error(item, "starting choice {s}", .{msg});
        return null;
    }
    return @intCast(parsed);
}

fn parse_menu_position(
    raw: ?[]const u8,
    default_value: i64,
    size: u32,
    limit: u32,
    item: *cmdq.CmdqItem,
    label: []const u8,
    target: *const T.CmdFindState,
    special: i64,
    vertical: bool,
) ?u32 {
    const value = raw orelse return clamp_menu_position(default_value, size, limit, vertical);
    const expanded_value = if (value.len == 1 and std.ascii.isAlphabetic(value[0]))
        null
    else
        cmd_display.expand_format(xm.allocator, value, target);
    defer if (expanded_value) |owned| xm.allocator.free(owned);

    const numeric_text = expanded_value orelse value;
    const parsed = if (value.len == 1 and std.ascii.isAlphabetic(value[0]))
        special
    else
        std.fmt.parseInt(i64, numeric_text, 10) catch {
            cmdq.cmdq_error(item, "unsupported menu {s} position: {s}", .{ label, value });
            return null;
        };
    return clamp_menu_position(parsed, size, limit, vertical);
}

fn clamp_menu_position(raw: i64, size: u32, limit: u32, vertical: bool) ?u32 {
    var absolute = raw;
    if (absolute < 0) absolute = 0;
    if (vertical) {
        if (absolute < size)
            absolute = 0
        else
            absolute -= size;
    }
    const max_start = @max(@as(i64, 0), @as(i64, @intCast(limit)) - @as(i64, @intCast(size)));
    if (absolute > max_start) absolute = max_start;
    return @intCast(absolute);
}

fn status_window_anchor(tc: *T.Client, wl_idx: i32) struct { x: i64, row: i64 } {
    const rendered = status.render(tc);
    defer if (rendered.payload.len != 0) xm.allocator.free(rendered.payload);

    for (tc.status.entries, 0..) |status_entry, row| {
        for (status_entry.ranges.items) |range| {
            if (range.type == .window and range.argument == @as(u32, @intCast(wl_idx))) {
                return .{ .x = range.start, .row = @intCast(row) };
            }
        }
    }
    return .{ .x = 0, .row = 0 };
}

fn menu_position(
    args: *const args_mod.Arguments,
    item: *cmdq.CmdqItem,
    target: *const T.CmdFindState,
    tc: *T.Client,
    menu: *const menu_mod.Menu,
) ?struct { x: u32, y: u32 } {
    const event = cmdq.cmdq_get_event(item);
    const pane_height = @as(u32, @intCast(available_popup_height(tc)));
    const pane_row_offset = status.pane_row_offset(tc);
    const width = menu.width + 4;
    const height: u32 = @as(u32, @intCast(menu.items.len)) + 2;
    if (width > tc.tty.sx or height > pane_height) return null;

    const anchor = status_window_anchor(tc, target.wl.?.idx);
    const mouse_x: i64 = if (event.m.valid) event.m.x else 0;
    const mouse_y: i64 = if (event.m.valid) @as(i64, @intCast(event.m.y)) - @as(i64, @intCast(pane_row_offset)) else 0;
    const pane_x: i64 = if (target.wp) |wp| wp.xoff else 0;
    const pane_y: i64 = if (target.wp) |wp| wp.yoff else 0;
    const pane_right: i64 = if (target.wp) |wp|
        @max(@as(i64, 0), @as(i64, @intCast(wp.xoff + wp.sx)) - @as(i64, @intCast(width)))
    else
        0;
    const pane_bottom: i64 = if (target.wp) |wp| pane_y + @as(i64, @intCast(wp.sy)) else 0;
    const lines = status.overlay_rows(tc);
    const status_bottom: i64 = @intCast(pane_height);
    const status_top: i64 = if (lines == 0) 0 else @intCast(anchor.row + 1);
    const window_status_top: i64 = if (status.status_at_line(tc) == 0) status_top else status_bottom + anchor.row;
    const x_mode = (args.get('x') orelse "C")[0];
    const y_mode = (args.get('y') orelse "C")[0];

    const px = parse_menu_position(
        args.get('x'),
        if (tc.tty.sx > width) @divTrunc(tc.tty.sx - width, 2) else 0,
        width,
        tc.tty.sx,
        item,
        "x",
        target,
        switch (x_mode) {
            'C' => if (tc.tty.sx > width) @divTrunc(tc.tty.sx - width, 2) else 0,
            'M' => mouse_x - @as(i64, @intCast(width / 2)),
            'P' => pane_x,
            'R' => pane_right,
            'W' => anchor.x,
            else => 0,
        },
        false,
    ) orelse return null;
    const py = parse_menu_position(
        args.get('y'),
        if (pane_height > height) @divTrunc(pane_height - height, 2) else 0,
        height,
        pane_height,
        item,
        "y",
        target,
        switch (y_mode) {
            'C' => if (pane_height > height) @divTrunc(pane_height - height, 2) else 0,
            'M' => mouse_y,
            'P' => pane_bottom,
            'S' => status_bottom,
            'W' => window_status_top,
            else => 0,
        },
        true,
    ) orelse return null;

    return .{ .x = px, .y = py };
}

fn validate_display_popup(args: *const args_mod.Arguments, item: *cmdq.CmdqItem, tc: *T.Client) bool {
    const popup_height = available_popup_height(tc);
    if (args.has('h')) {
        var cause: ?[]u8 = null;
        _ = args_mod.args_percentage(args, 'h', 1, popup_height, popup_height, &cause);
        if (cause) |msg| {
            defer xm.allocator.free(msg);
            cmdq.cmdq_error(item, "height {s}", .{msg});
            return false;
        }
    }

    if (args.has('w')) {
        var cause: ?[]u8 = null;
        _ = args_mod.args_percentage(args, 'w', 1, tc.tty.sx, tc.tty.sx, &cause);
        if (cause) |msg| {
            defer xm.allocator.free(msg);
            cmdq.cmdq_error(item, "width {s}", .{msg});
            return false;
        }
    }

    if (!args.has('B')) {
        if (args.get('b')) |value| {
            if (!validate_choice(item, "popup-border-lines", value))
                return false;
        }
    }

    return true;
}

fn available_popup_height(tc: *const T.Client) i64 {
    const overlay_rows = status.overlay_rows(@constCast(tc));
    const height: u32 = if (tc.tty.sy > overlay_rows) tc.tty.sy - overlay_rows else 0;
    return @intCast(height);
}

fn popup_dimension(
    args: *const args_mod.Arguments,
    flag: u8,
    default_value: u32,
    max_value: u32,
    item: *cmdq.CmdqItem,
    label: []const u8,
) ?u32 {
    if (!args.has(flag)) return default_value;

    var cause: ?[]u8 = null;
    const value = args_mod.args_percentage(args, flag, 1, max_value, max_value, &cause);
    if (cause) |msg| {
        defer xm.allocator.free(msg);
        cmdq.cmdq_error(item, "{s} {s}", .{ label, msg });
        return null;
    }
    return @intCast(value);
}

fn parse_popup_position(
    raw: ?[]const u8,
    default_value: u32,
    size: u32,
    limit: u32,
    item: *cmdq.CmdqItem,
    label: []const u8,
    vertical: bool,
) ?u32 {
    const value = raw orelse return default_value;
    if (std.mem.eql(u8, value, "C")) return default_value;

    const parsed = std.fmt.parseInt(i64, value, 10) catch {
        cmdq.cmdq_error(item, "unsupported popup {s} position: {s}", .{ label, value });
        return null;
    };
    if (parsed < 0) {
        cmdq.cmdq_error(item, "unsupported popup {s} position: {s}", .{ label, value });
        return null;
    }

    var absolute: i64 = parsed;
    if (vertical) {
        if (absolute < size)
            absolute = 0
        else
            absolute -= size;
    }

    const max_start: i64 = @max(@as(i64, 0), @as(i64, @intCast(limit)) - @as(i64, @intCast(size)));
    if (absolute > max_start) absolute = max_start;
    return @intCast(absolute);
}

fn popup_title(args: *const args_mod.Arguments, target: *const T.CmdFindState) []u8 {
    if (args.get('T')) |raw| return cmd_display.expand_format(xm.allocator, raw, target);
    return xm.xstrdup("");
}

fn popup_lines(args: *const args_mod.Arguments, item: *cmdq.CmdqItem, options: *T.Options) ?u32 {
    if (args.has('B')) return POPUP_BORDER_NONE;
    if (args.get('b')) |value| {
        const oe = opts.options_table_entry("popup-border-lines") orelse return null;
        return opts.options_choice_index(oe, value) orelse {
            cmdq.cmdq_error(item, "popup-border-lines invalid choice: {s}", .{value});
            return null;
        };
    }
    return @intCast(opts.options_get_number(options, "popup-border-lines"));
}

fn popup_modify_flags(args: *const args_mod.Arguments) ?i32 {
    if (!args.has('N') and !args.has('k')) return null;
    var flags: i32 = 0;
    if (args.has('k')) flags |= popup.POPUP_CLOSEANYKEY;
    return flags;
}

fn append_popup_shell_word(out: *std.ArrayList(u8), word: []const u8) void {
    cmd_render.append_shell_word(out, word);
}

fn popup_shell_command(args: *const args_mod.Arguments, session: *T.Session) []u8 {
    if (args.count() == 0) {
        const default_command = opts.options_get_string(session.options, "default-command");
        if (default_command.len != 0) return xm.xstrdup(default_command);

        const default_shell = opts.options_get_string(session.options, "default-shell");
        if (default_shell.len != 0 and @import("zmux.zig").checkshell(default_shell))
            return xm.xstrdup(default_shell);
        return xm.xstrdup("/bin/sh");
    }

    if (args.count() == 1) return xm.xstrdup(args.value_at(0).?);

    var out: std.ArrayList(u8) = .{};
    errdefer out.deinit(xm.allocator);
    for (0..args.count()) |idx| {
        if (idx != 0) out.append(xm.allocator, ' ') catch unreachable;
        append_popup_shell_word(&out, args.value_at(idx).?);
    }
    return out.toOwnedSlice(xm.allocator) catch unreachable;
}

fn popup_environment_overlays(args: *const args_mod.Arguments) ?*T.Environ {
    const env_entry = args.entry('e') orelse return null;
    if (env_entry.count == 0) return null;

    const env = env_mod.environ_create();
    for (env_entry.values.items) |value| env_mod.environ_put(env, value, 0);
    return env;
}

fn popup_working_directory(args: *const args_mod.Arguments, target: *const T.CmdFindState, tc: *T.Client, session: *T.Session) []u8 {
    if (args.get('d')) |raw|
        return cmd_display.expand_format(xm.allocator, raw, target);
    return xm.xstrdup(server_client.server_client_get_cwd(tc, session));
}

fn popup_render_environment_prefix(env: *T.Environ) []u8 {
    const entries = env_mod.environ_sorted_entries(env);
    defer xm.allocator.free(entries);

    var out: std.ArrayList(u8) = .{};
    errdefer out.deinit(xm.allocator);
    var first = true;
    for (entries) |env_entry| {
        const value = env_entry.value orelse continue;
        if (!first) out.append(xm.allocator, ' ') catch unreachable;
        first = false;
        out.appendSlice(xm.allocator, env_entry.name) catch unreachable;
        out.append(xm.allocator, '=') catch unreachable;
        append_popup_shell_word(&out, value);
    }
    return out.toOwnedSlice(xm.allocator) catch unreachable;
}

fn popup_command_with_environment(shell_command: []const u8, env: ?*T.Environ) []u8 {
    const overlays = env orelse return xm.xstrdup(shell_command);
    const prefix = popup_render_environment_prefix(overlays);
    defer xm.allocator.free(prefix);
    if (prefix.len == 0) return xm.xstrdup(shell_command);
    return xm.xasprintf("env {s} {s}", .{ prefix, shell_command });
}

fn popup_job_environment_map(env: ?*T.Environ) ?*std.process.EnvMap {
    const overlays = env orelse return null;

    const env_map_ptr = xm.allocator.create(std.process.EnvMap) catch unreachable;
    env_map_ptr.* = std.process.EnvMap.init(xm.allocator);
    errdefer {
        env_map_ptr.deinit();
        xm.allocator.destroy(env_map_ptr);
    }

    const base_env = std.process.getEnvMap(xm.allocator) catch {
        env_map_ptr.deinit();
        xm.allocator.destroy(env_map_ptr);
        return null;
    };
    defer @constCast(&base_env).deinit();

    var base_it = base_env.iterator();
    while (base_it.next()) |env_entry| {
        env_map_ptr.put(env_entry.key_ptr.*, env_entry.value_ptr.*) catch unreachable;
    }

    const overlay_entries = env_mod.environ_sorted_entries(overlays);
    defer xm.allocator.free(overlay_entries);
    for (overlay_entries) |overlay_entry| {
        const value = overlay_entry.value orelse continue;
        env_map_ptr.put(overlay_entry.name, value) catch unreachable;
    }

    return env_map_ptr;
}

fn exec_display_menu(cmd: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {
    const args = cmd_mod.cmd_get_args(cmd);
    const target = resolve_target(item, args.get('t')) orelse return .@"error";
    const tc = require_target_client(item) orelse return .@"error";
    const session = target.s orelse tc.session orelse return .@"error";
    const options = session.curw.?.window.options;
    const event = cmdq.cmdq_get_event(item);

    if (cmd_display_panes.overlay_active(tc) or menu_mod.overlay_active(tc) or popup.overlay_active(tc))
        return .normal;

    switch (validate_display_menu(args, item)) {
        .err => return .@"error",
        .noop => return .normal,
        .ok => {},
    }

    const menu = build_menu(args, &target, tc) orelse {
        cmdq.cmdq_error(item, "invalid menu arguments", .{});
        return .@"error";
    };
    errdefer menu.deinit();

    if (menu.items.len == 0)
        return .normal;

    const position = menu_position(args, item, &target, tc, menu) orelse return .normal;
    const lines = menu_lines(args, item, options) orelse return .@"error";
    const starting_choice = menu_starting_choice(args, item) orelse return .@"error";
    const flags = menu_flags(args, event);

    if (menu_mod.menu_display(
        menu,
        flags,
        starting_choice,
        item,
        position.x,
        position.y,
        tc,
        lines,
        args.get('s'),
        args.get('H'),
        args.get('S'),
        &target,
        null,
        null,
    ) != 0) return .normal;

    return .wait;
}

fn exec_display_popup(cmd: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {
    const args = cmd_mod.cmd_get_args(cmd);
    if (args.has('C')) {
        if (cmdq.cmdq_get_target_client(item)) |tc| popup.clear_overlay(tc);
        return .normal;
    }

    const target = resolve_target(item, args.get('t')) orelse return .@"error";
    const tc = require_target_client(item) orelse return .@"error";
    const session = target.s orelse tc.session orelse return .@"error";
    const options = session.curw.?.window.options;
    const modify = popup.popup_present(tc);

    if (!modify and (cmd_display_panes.overlay_active(tc) or popup.overlay_active(tc)))
        return .normal;

    if (!validate_display_popup(args, item, tc))
        return .@"error";

    const lines = popup_lines(args, item, options) orelse return .@"error";
    const style = args.get('s');
    const border_style = args.get('S');
    const flags = popup_modify_flags(args);

    if (modify) {
        const title = if (args.has('T')) popup_title(args, &target) else null;
        defer if (title) |value| xm.allocator.free(value);
        popup.popup_modify(tc, title, style, border_style, if (args.has('B') or args.get('b') != null) lines else null, flags);
        return .normal;
    }

    const popup_limit_h: u32 = @intCast(available_popup_height(tc));
    const popup_h = popup_dimension(args, 'h', @max(@as(u32, 1), if (popup_limit_h == 0) @as(u32, 1) else popup_limit_h / 2), popup_limit_h, item, "height") orelse return .@"error";
    const popup_w = popup_dimension(args, 'w', @max(@as(u32, 1), @divTrunc(tc.tty.sx, 2)), tc.tty.sx, item, "width") orelse return .@"error";
    const popup_y = parse_popup_position(args.get('y'), if (popup_limit_h > popup_h) (popup_limit_h - popup_h) / 2 else 0, popup_h, popup_limit_h, item, "y", true) orelse return .@"error";
    const popup_x = parse_popup_position(args.get('x'), if (tc.tty.sx > popup_w) (tc.tty.sx - popup_w) / 2 else 0, popup_w, tc.tty.sx, item, "x", false) orelse return .@"error";

    const cwd = popup_working_directory(args, &target, tc, session);
    defer xm.allocator.free(cwd);

    const shell_command = popup_shell_command(args, session);
    defer xm.allocator.free(shell_command);
    const overlay_env = popup_environment_overlays(args);
    defer if (overlay_env) |env| env_mod.environ_free(env);
    const command = popup_command_with_environment(shell_command, overlay_env);
    defer xm.allocator.free(command);
    const job_env = popup_job_environment_map(overlay_env);
    defer if (job_env) |env_map| {
        env_map.deinit();
        xm.allocator.destroy(env_map);
    };

    var result = job_mod.job_run_shell_command(null, command, .{
        .cwd = cwd,
        .merge_stderr = true,
        .capture_output = true,
        .env_map = job_env,
    });
    defer result.deinit();
    if (result.spawn_failed) {
        cmdq.cmdq_error(item, "failed to run command: {s}", .{command});
        return .@"error";
    }

    const title = popup_title(args, &target);
    defer xm.allocator.free(title);
    var initial_flags: i32 = flags orelse 0;
    if (args.has('E')) initial_flags |= popup.POPUP_CLOSEANYKEY;
    if (popup.popup_display(
        initial_flags,
        lines,
        item,
        popup_x,
        popup_y,
        popup_w,
        popup_h,
        title,
        tc,
        session,
        style,
        border_style,
        result.output.items,
    ) != 0) return .normal;

    return .wait;
}

pub const entry: cmd_mod.CmdEntry = .{
    .name = "display-menu",
    .alias = "menu",
    .usage = "[-MO] [-b border-lines] [-c target-client] [-C starting-choice] [-H selected-style] [-s style] [-S border-style] [-t target-pane] [-T title] [-x position] [-y position] name [key] [command] ...",
    .template = "b:c:C:H:s:S:MOt:T:x:y:",
    .lower = 1,
    .upper = -1,
    .flags = T.CMD_AFTERHOOK | T.CMD_CLIENT_CFLAG,
    .exec = exec_display_menu,
};

pub const entry_popup: cmd_mod.CmdEntry = .{
    .name = "display-popup",
    .alias = "popup",
    .usage = "[-BCEkN] [-b border-lines] [-c target-client] [-d start-directory] [-e environment] [-h height] [-s style] [-S border-style] [-t target-pane] [-T title] [-w width] [-x position] [-y position] [shell-command [argument ...]]",
    .template = "Bb:Cc:d:e:Eh:kNs:S:t:T:w:x:y:",
    .lower = 0,
    .upper = -1,
    .flags = T.CMD_AFTERHOOK | T.CMD_CLIENT_CFLAG,
    .exec = exec_display_popup,
};

fn test_setup(name: []const u8) struct {
    session: *T.Session,
    window: *T.Window,
    client: T.Client,
} {
    const opts_mod = @import("options.zig");
    const sess = @import("session.zig");
    const win = @import("window.zig");

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
    defer if (attach_cause) |msg| xm.allocator.free(msg);
    const wl = sess.session_attach(session, window, -1, &attach_cause).?;
    session.curw = wl;
    const pane = win.window_add_pane(window, null, 80, 24);
    window.active = pane;

    var client = T.Client{
        .name = xm.xstrdup(name),
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{},
        .flags = T.CLIENT_ATTACHED,
        .session = session,
    };
    client.tty = .{ .client = &client, .sx = 80, .sy = 24 };

    return .{
        .session = session,
        .window = window,
        .client = client,
    };
}

fn test_teardown(setup: *@TypeOf(test_setup("unused"))) void {
    const opts_mod = @import("options.zig");
    const sess = @import("session.zig");
    const status_runtime = @import("status-runtime.zig");
    const win = @import("window.zig");

    cmd_display_panes.clear_overlay(&setup.client);
    menu_mod.clear_overlay(&setup.client);
    popup.clear_overlay(&setup.client);
    status_runtime.status_message_clear(&setup.client);
    env_mod.environ_free(setup.client.environ);
    if (setup.client.name) |name| xm.allocator.free(@constCast(name));

    if (sess.session_find(setup.session.name) != null)
        sess.session_destroy(setup.session, false, "test");
    win.window_remove_ref(setup.window, "test");

    env_mod.environ_free(env_mod.global_environ);
    opts_mod.options_free(opts_mod.global_options);
    opts_mod.options_free(opts_mod.global_s_options);
    opts_mod.options_free(opts_mod.global_w_options);
}

fn bind_test_client(setup: *@TypeOf(test_setup("unused"))) void {
    setup.client.tty.client = &setup.client;
}

fn status_window_range_start(client: *T.Client, idx: i32) ?u32 {
    for (client.status.entries) |status_entry| {
        for (status_entry.ranges.items) |range| {
            if (range.type == .window and range.argument == @as(u32, @intCast(idx)))
                return range.start;
        }
    }
    return null;
}

test "display-menu and display-popup commands are registered" {
    try std.testing.expectEqual(&entry, cmd_mod.cmd_find_entry("display-menu").?);
    try std.testing.expectEqual(&entry, cmd_mod.cmd_find_entry("menu").?);
    try std.testing.expectEqual(&entry_popup, cmd_mod.cmd_find_entry("display-popup").?);
    try std.testing.expectEqual(&entry_popup, cmd_mod.cmd_find_entry("popup").?);
}

test "display-menu opens the shared overlay runtime" {
    var setup = test_setup("display-menu-runtime");
    bind_test_client(&setup);
    defer test_teardown(&setup);

    var parse_cause: ?[]u8 = null;
    defer if (parse_cause) |msg| xm.allocator.free(msg);
    const cmd = try cmd_mod.cmd_parse_one(&.{ "display-menu", "Item", "x", "display-message ok" }, null, &parse_cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &setup.client, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.wait, cmd_mod.cmd_execute(cmd, &item));
    try std.testing.expect(menu_mod.overlay_active(&setup.client));

    const payload = (try menu_mod.render_overlay_payload_region(
        &setup.client,
        0,
        0,
        setup.client.tty.sx,
        @intCast(available_popup_height(&setup.client)),
        status.pane_row_offset(&setup.client),
    )).?;
    defer xm.allocator.free(payload);
    try std.testing.expect(std.mem.indexOf(u8, payload, "Item") != null);

    var escape = T.key_event{ .key = T.C0_ESC, .len = 1 };
    escape.data[0] = 0x1b;
    try std.testing.expect(server_fn.server_client_handle_key(&setup.client, &escape));
    try std.testing.expect(!menu_mod.overlay_active(&setup.client));
}

test "display-menu rejects invalid starting choice before opening the overlay" {
    var setup = test_setup("display-menu-start");
    bind_test_client(&setup);
    defer test_teardown(&setup);

    var parse_cause: ?[]u8 = null;
    defer if (parse_cause) |msg| xm.allocator.free(msg);
    const cmd = try cmd_mod.cmd_parse_one(&.{ "display-menu", "-C", "-2", "Item", "x", "display-message ok" }, null, &parse_cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &setup.client, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.@"error", cmd_mod.cmd_execute(cmd, &item));
    try std.testing.expectEqualStrings("Starting choice too small", setup.client.message_string.?);
}

test "display-menu with only separators is a no-op" {
    var setup = test_setup("display-menu-separator");
    bind_test_client(&setup);
    defer test_teardown(&setup);

    var parse_cause: ?[]u8 = null;
    defer if (parse_cause) |msg| xm.allocator.free(msg);
    const cmd = try cmd_mod.cmd_parse_one(&.{ "display-menu", "" }, null, &parse_cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &setup.client, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));
    try std.testing.expect(setup.client.message_string == null);
}

test "display-menu validates menu border lines before opening the overlay" {
    var setup = test_setup("display-menu-border");
    bind_test_client(&setup);
    defer test_teardown(&setup);

    var parse_cause: ?[]u8 = null;
    defer if (parse_cause) |msg| xm.allocator.free(msg);
    const cmd = try cmd_mod.cmd_parse_one(&.{ "display-menu", "-b", "mystery", "Item", "x", "display-message ok" }, null, &parse_cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &setup.client, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.@"error", cmd_mod.cmd_execute(cmd, &item));
    try std.testing.expectEqualStrings("Menu-border-lines invalid choice: mystery", setup.client.message_string.?);
}

test "display-menu keyboard navigation queues the chosen command" {
    var setup = test_setup("display-menu-keys");
    bind_test_client(&setup);
    defer test_teardown(&setup);

    var parse_cause: ?[]u8 = null;
    defer if (parse_cause) |msg| xm.allocator.free(msg);
    const cmd = try cmd_mod.cmd_parse_one(&.{
        "display-menu",
        "",
        "First",
        "a",
        "display-message first",
        "Second",
        "b",
        "display-message second",
    }, null, &parse_cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &setup.client, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.wait, cmd_mod.cmd_execute(cmd, &item));
    try std.testing.expect(menu_mod.overlay_active(&setup.client));

    var down = T.key_event{ .key = T.KEYC_DOWN };
    try std.testing.expect(server_fn.server_client_handle_key(&setup.client, &down));
    try std.testing.expect(menu_mod.overlay_active(&setup.client));

    var enter = T.key_event{ .key = '\r', .len = 1 };
    enter.data[0] = '\r';
    try std.testing.expect(server_fn.server_client_handle_key(&setup.client, &enter));
    try std.testing.expect(!menu_mod.overlay_active(&setup.client));
    try std.testing.expectEqual(@as(u32, 1), cmdq.cmdq_next(&setup.client));
    try std.testing.expectEqualStrings("second", setup.client.message_string.?);
}

test "display-menu uses tmux window-status anchors for -xW -yW" {
    var setup = test_setup("display-menu-window-anchor");
    bind_test_client(&setup);
    defer test_teardown(&setup);

    setup.session.statusat = 1;
    const rendered = status.render(&setup.client);
    defer if (rendered.payload.len != 0) xm.allocator.free(rendered.payload);
    const range_start = status_window_range_start(&setup.client, setup.session.curw.?.idx).?;

    var parse_cause: ?[]u8 = null;
    defer if (parse_cause) |msg| xm.allocator.free(msg);
    const cmd = try cmd_mod.cmd_parse_one(&.{ "display-menu", "-xW", "-yW", "Item", "x", "display-message ok" }, null, &parse_cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &setup.client, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.wait, cmd_mod.cmd_execute(cmd, &item));

    const bounds = menu_mod.overlay_bounds(&setup.client).?;
    try std.testing.expectEqual(range_start, bounds.px);
    try std.testing.expectEqual(@as(u32, 20), bounds.py);
}

test "display-menu -M enables overlay mouse mode and mouse selection" {
    var setup = test_setup("display-menu-mouse");
    bind_test_client(&setup);
    defer test_teardown(&setup);

    var parse_cause: ?[]u8 = null;
    defer if (parse_cause) |msg| xm.allocator.free(msg);
    const cmd = try cmd_mod.cmd_parse_one(&.{ "display-menu", "-M", "Item", "x", "display-message ok" }, null, &parse_cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &setup.client, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.wait, cmd_mod.cmd_execute(cmd, &item));
    try std.testing.expect(menu_mod.overlay_active(&setup.client));
    try std.testing.expectEqual(@as(i32, T.MODE_MOUSE_ALL | T.MODE_MOUSE_BUTTON), mouse_runtime.client_outer_tty_mode(&setup.client) & T.ALL_MOUSE_MODES);

    const bounds = menu_mod.overlay_bounds(&setup.client).?;
    var hover = T.key_event{ .key = T.KEYC_MOUSE, .len = 1 };
    hover.m = .{ .x = bounds.px + 2, .y = bounds.py + 1, .b = T.MOUSE_BUTTON_1 };
    try std.testing.expect(server_fn.server_client_handle_key(&setup.client, &hover));
    try std.testing.expect(menu_mod.overlay_active(&setup.client));

    var release = T.key_event{ .key = T.KEYC_MOUSE, .len = 1 };
    release.m = .{ .x = bounds.px + 2, .y = bounds.py + 1, .b = 3 };
    try std.testing.expect(server_fn.server_client_handle_key(&setup.client, &release));
    try std.testing.expect(!menu_mod.overlay_active(&setup.client));
    try std.testing.expectEqual(@as(u32, 1), cmdq.cmdq_next(&setup.client));
    try std.testing.expectEqualStrings("ok", setup.client.message_string.?);
}

test "display-menu is a no-op while another overlay owns the target client" {
    var setup = test_setup("display-menu-overlay");
    bind_test_client(&setup);
    defer test_teardown(&setup);

    var display_parse_cause: ?[]u8 = null;
    defer if (display_parse_cause) |msg| xm.allocator.free(msg);
    const display_cmd = try cmd_mod.cmd_parse_one(&.{ "display-panes", "-b", "-d", "0" }, null, &display_parse_cause);
    defer cmd_mod.cmd_free(display_cmd);

    var display_list: cmd_mod.CmdList = .{};
    var display_item = cmdq.CmdqItem{ .client = &setup.client, .cmdlist = &display_list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(display_cmd, &display_item));
    try std.testing.expect(cmd_display_panes.overlay_active(&setup.client));

    var menu_parse_cause: ?[]u8 = null;
    defer if (menu_parse_cause) |msg| xm.allocator.free(msg);
    const menu_cmd = try cmd_mod.cmd_parse_one(&.{ "display-menu", "Item", "x", "display-message ok" }, null, &menu_parse_cause);
    defer cmd_mod.cmd_free(menu_cmd);

    var menu_list: cmd_mod.CmdList = .{};
    var menu_item = cmdq.CmdqItem{ .client = &setup.client, .cmdlist = &menu_list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(menu_cmd, &menu_item));
    try std.testing.expect(setup.client.message_string == null);
}

test "display-popup close is a no-op without popup runtime" {
    var setup = test_setup("display-popup-close");
    bind_test_client(&setup);
    defer test_teardown(&setup);

    var parse_cause: ?[]u8 = null;
    defer if (parse_cause) |msg| xm.allocator.free(msg);
    const cmd = try cmd_mod.cmd_parse_one(&.{ "display-popup", "-C" }, null, &parse_cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &setup.client, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));
    try std.testing.expect(setup.client.message_string == null);
}

test "display-popup opens a reduced popup with captured shell output" {
    var setup = test_setup("display-popup-runtime");
    bind_test_client(&setup);
    defer test_teardown(&setup);

    var parse_cause: ?[]u8 = null;
    defer if (parse_cause) |msg| xm.allocator.free(msg);
    const cmd = try cmd_mod.cmd_parse_one(&.{ "display-popup", "-T", "runtime", "printf 'popup\\noutput'" }, null, &parse_cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &setup.client, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.wait, cmd_mod.cmd_execute(cmd, &item));
    try std.testing.expect(popup.overlay_active(&setup.client));

    const payload = (try popup.render_overlay_payload_region(&setup.client, 0, 0, 80, 24, 0)).?;
    defer xm.allocator.free(payload);
    try std.testing.expect(std.mem.indexOf(u8, payload, "runtime") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "popup") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "output") != null);

    var event = T.key_event{ .key = T.C0_ESC, .len = 1 };
    event.data[0] = 0x1b;
    try std.testing.expect(popup.handle_key(&setup.client, &event));
    try std.testing.expect(!popup.overlay_active(&setup.client));
}

test "display-popup validates size before running the reduced runtime" {
    var setup = test_setup("display-popup-height");
    bind_test_client(&setup);
    defer test_teardown(&setup);

    var parse_cause: ?[]u8 = null;
    defer if (parse_cause) |msg| xm.allocator.free(msg);
    const cmd = try cmd_mod.cmd_parse_one(&.{ "display-popup", "-h", "101%" }, null, &parse_cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &setup.client, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.@"error", cmd_mod.cmd_execute(cmd, &item));
    try std.testing.expectEqualStrings("Height too large", setup.client.message_string.?);
}

test "display-popup validates popup border lines before the reduced runtime error" {
    var setup = test_setup("display-popup-border");
    bind_test_client(&setup);
    defer test_teardown(&setup);

    var parse_cause: ?[]u8 = null;
    defer if (parse_cause) |msg| xm.allocator.free(msg);
    const cmd = try cmd_mod.cmd_parse_one(&.{ "display-popup", "-b", "mystery" }, null, &parse_cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &setup.client, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.@"error", cmd_mod.cmd_execute(cmd, &item));
    try std.testing.expectEqualStrings("Popup-border-lines invalid choice: mystery", setup.client.message_string.?);
}

test "display-popup without a command falls back to the default shell" {
    var setup = test_setup("display-popup-shell");
    bind_test_client(&setup);
    defer test_teardown(&setup);

    var parse_cause: ?[]u8 = null;
    defer if (parse_cause) |msg| xm.allocator.free(msg);
    const cmd = try cmd_mod.cmd_parse_one(&.{"display-popup"}, null, &parse_cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &setup.client, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.wait, cmd_mod.cmd_execute(cmd, &item));
    try std.testing.expect(popup.overlay_active(&setup.client));
}

test "display-popup accepts environment overlays in the reduced runtime" {
    var setup = test_setup("display-popup-env");
    bind_test_client(&setup);
    defer test_teardown(&setup);

    var parse_cause: ?[]u8 = null;
    defer if (parse_cause) |msg| xm.allocator.free(msg);
    const cmd = try cmd_mod.cmd_parse_one(&.{ "display-popup", "-e", "NAME=value", "sh", "-lc", "printf '%s' \"$NAME\"" }, null, &parse_cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &setup.client, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.wait, cmd_mod.cmd_execute(cmd, &item));
    const payload = (try popup.render_overlay_payload_region(&setup.client, 0, 0, 80, 24, 0)).?;
    defer xm.allocator.free(payload);
    const state = popup.popup_data(&setup.client).?;
    try std.testing.expectEqualStrings("value", state.content.items);
}

test "display-popup accepts argv vector commands in the reduced runtime" {
    var setup = test_setup("display-popup-argv");
    bind_test_client(&setup);
    defer test_teardown(&setup);

    var parse_cause: ?[]u8 = null;
    defer if (parse_cause) |msg| xm.allocator.free(msg);
    const cmd = try cmd_mod.cmd_parse_one(&.{ "display-popup", "printf", "ready" }, null, &parse_cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &setup.client, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.wait, cmd_mod.cmd_execute(cmd, &item));
    const state = popup.popup_data(&setup.client).?;
    try std.testing.expectEqualStrings("ready", state.content.items);
}

test "display-popup close-on-exit maps to close-any-key in the reduced runtime" {
    var setup = test_setup("display-popup-close-exit");
    bind_test_client(&setup);
    defer test_teardown(&setup);

    var parse_cause: ?[]u8 = null;
    defer if (parse_cause) |msg| xm.allocator.free(msg);
    const cmd = try cmd_mod.cmd_parse_one(&.{ "display-popup", "-E", "printf ready" }, null, &parse_cause);
    defer cmd_mod.cmd_free(cmd);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &setup.client, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.wait, cmd_mod.cmd_execute(cmd, &item));
    try std.testing.expect(popup.overlay_active(&setup.client));

    var event = T.key_event{ .key = 'x', .len = 1 };
    event.data[0] = 'x';
    try std.testing.expect(popup.handle_key(&setup.client, &event));
    try std.testing.expect(!popup.overlay_active(&setup.client));
}

test "display-popup modify updates title and close-any-key handling" {
    var setup = test_setup("display-popup-modify");
    bind_test_client(&setup);
    defer test_teardown(&setup);

    var parse_cause: ?[]u8 = null;
    defer if (parse_cause) |msg| xm.allocator.free(msg);
    const open_cmd = try cmd_mod.cmd_parse_one(&.{ "display-popup", "-T", "before", "printf ready" }, null, &parse_cause);
    defer cmd_mod.cmd_free(open_cmd);

    var open_list: cmd_mod.CmdList = .{};
    var open_item = cmdq.CmdqItem{ .client = &setup.client, .cmdlist = &open_list };
    try std.testing.expectEqual(T.CmdRetval.wait, cmd_mod.cmd_execute(open_cmd, &open_item));

    var modify_cause: ?[]u8 = null;
    defer if (modify_cause) |msg| xm.allocator.free(msg);
    const modify_cmd = try cmd_mod.cmd_parse_one(&.{ "display-popup", "-T", "after", "-k" }, null, &modify_cause);
    defer cmd_mod.cmd_free(modify_cmd);

    var modify_list: cmd_mod.CmdList = .{};
    var modify_item = cmdq.CmdqItem{ .client = &setup.client, .cmdlist = &modify_list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(modify_cmd, &modify_item));

    const payload = (try popup.render_overlay_payload_region(&setup.client, 0, 0, 80, 24, 0)).?;
    defer xm.allocator.free(payload);
    try std.testing.expect(std.mem.indexOf(u8, payload, "after") != null);

    var key_event = T.key_event{ .key = 'x', .len = 1 };
    key_event.data[0] = 'x';
    try std.testing.expect(popup.handle_key(&setup.client, &key_event));
    try std.testing.expect(!popup.overlay_active(&setup.client));
}

test "display-popup is a no-op while another overlay owns the target client" {
    var setup = test_setup("display-popup-overlay");
    bind_test_client(&setup);
    defer test_teardown(&setup);

    var display_parse_cause: ?[]u8 = null;
    defer if (display_parse_cause) |msg| xm.allocator.free(msg);
    const display_cmd = try cmd_mod.cmd_parse_one(&.{ "display-panes", "-b", "-d", "0" }, null, &display_parse_cause);
    defer cmd_mod.cmd_free(display_cmd);

    var display_list: cmd_mod.CmdList = .{};
    var display_item = cmdq.CmdqItem{ .client = &setup.client, .cmdlist = &display_list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(display_cmd, &display_item));
    try std.testing.expect(cmd_display_panes.overlay_active(&setup.client));

    var popup_parse_cause: ?[]u8 = null;
    defer if (popup_parse_cause) |msg| xm.allocator.free(msg);
    const popup_cmd = try cmd_mod.cmd_parse_one(&.{"display-popup"}, null, &popup_parse_cause);
    defer cmd_mod.cmd_free(popup_cmd);

    var popup_list: cmd_mod.CmdList = .{};
    var popup_item = cmdq.CmdqItem{ .client = &setup.client, .cmdlist = &popup_list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(popup_cmd, &popup_item));
    try std.testing.expect(setup.client.message_string == null);
}
