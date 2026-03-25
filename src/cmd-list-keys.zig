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
// Ported from tmux/cmd-list-keys.c
// Original copyright:
//   Copyright (c) 2007 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const args_mod = @import("arguments.zig");
const cmd_mod = @import("cmd.zig");
const cmdq = @import("cmd-queue.zig");
const key_bindings = @import("key-bindings.zig");
const key_string = @import("key-string.zig");
const opts = @import("options.zig");
const sort_mod = @import("sort.zig");
const utf8 = @import("utf8.zig");
const format_mod = @import("format.zig");
const cmd_render = @import("cmd-render.zig");

const PrintMode = enum {
    normal,
    notes_only,
};

const DEFAULT_TEMPLATE = "bind-key#{?key_has_repeat, -r,} -T #{key_table} #{key_string}#{?key_command, #{key_command},}";
const DEFAULT_NOTES_TEMPLATE = "#{?key_prefix,#{key_prefix} ,}#{p|#{key_string_width}|:#{key_string}} #{?key_note,#{key_note},#{key_command}}";

fn exec(cmd: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {
    const args = cmd_mod.cmd_get_args(cmd);
    const mode: PrintMode = if (args.has('N')) .notes_only else .normal;
    const template = args.get('F') orelse switch (mode) {
        .normal => DEFAULT_TEMPLATE,
        .notes_only => DEFAULT_NOTES_TEMPLATE,
    };

    var only: ?T.key_code = null;
    if (args.value_at(0)) |key_name| {
        const parsed = key_string.key_string_lookup_string(key_name);
        if (parsed == T.KEYC_UNKNOWN) {
            cmdq.cmdq_error(item, "invalid key: {s}", .{key_name});
            return .@"error";
        }
        only = normalize_key(parsed);
    }

    const requested_order = sort_mod.sort_order_from_string(args.get('O'));
    if (requested_order == .end and args.has('O')) {
        cmdq.cmdq_error(item, "invalid sort order", .{});
        return .@"error";
    }
    if (!order_supported(requested_order) and requested_order != .end) {
        cmdq.cmdq_error(item, "invalid sort order", .{});
        return .@"error";
    }

    const table = if (args.get('T')) |name|
        key_bindings.key_bindings_get_table(name, false) orelse {
            cmdq.cmdq_error(item, "table {s} doesn't exist", .{name});
            return .@"error";
        }
    else
        null;

    const bindings = collect_bindings(
        table,
        args.has('N'),
        args.has('a'),
        only,
        .{ .order = requested_order, .reversed = args.has('r') },
    );
    defer xm.allocator.free(bindings);

    const prefix = get_prefix_string(args);
    defer xm.allocator.free(prefix);

    const count = if (args.has('1') and bindings.len > 1) @as(usize, 1) else bindings.len;
    const key_width = max_key_width(bindings[0..count]);
    for (bindings[0..count]) |binding| {
        const line = render_binding_line(binding, template, mode, prefix, key_width) orelse {
            cmdq.cmdq_error(item, "format expansion not supported yet", .{});
            return .@"error";
        };
        defer xm.allocator.free(line);
        cmdq.cmdq_print(item, "{s}", .{line});
    }
    return .normal;
}

fn collect_bindings(
    table: ?*T.KeyTable,
    notes_only: bool,
    include_without_notes: bool,
    only: ?T.key_code,
    sort_crit: T.SortCriteria,
) []*T.KeyBinding {
    const base = if (table) |selected|
        sort_mod.sorted_key_bindings_table(selected, effective_sort_criteria(sort_crit))
    else if (notes_only)
        collect_root_prefix_bindings(effective_sort_criteria(sort_crit))
    else
        sort_mod.sorted_key_bindings(effective_sort_criteria(sort_crit));
    defer xm.allocator.free(base);

    var filtered: std.ArrayList(*T.KeyBinding) = .{};
    for (base) |binding| {
        if (only) |expected| {
            if (normalize_key(binding.key) != expected) continue;
        }
        if (notes_only and !include_without_notes and binding.note == null) continue;
        filtered.append(xm.allocator, binding) catch unreachable;
    }
    return filtered.toOwnedSlice(xm.allocator) catch unreachable;
}

fn collect_root_prefix_bindings(sort_crit: T.SortCriteria) []*T.KeyBinding {
    var list: std.ArrayList(*T.KeyBinding) = .{};
    for (&[_][]const u8{ "prefix", "root" }) |name| {
        const table = key_bindings.key_bindings_get_table(name, false) orelse continue;
        const entries = sort_mod.sorted_key_bindings_table(table, sort_crit);
        defer xm.allocator.free(entries);
        list.appendSlice(xm.allocator, entries) catch unreachable;
    }
    return list.toOwnedSlice(xm.allocator) catch unreachable;
}

fn render_binding_line(binding: *T.KeyBinding, template: []const u8, mode: PrintMode, prefix: []const u8, key_width: u32) ?[]u8 {
    const command = render_binding_command(binding);
    defer xm.allocator.free(command);

    const ctx = format_mod.FormatContext{
        .key_binding = binding,
        .key_command = command,
        .key_prefix = prefix,
        .key_string_width = key_width,
        .key_table_width = @intCast(binding.tablename.len),
        .notes_only = mode == .notes_only,
    };
    return format_mod.format_require(xm.allocator, template, &ctx) catch null;
}

fn render_binding_command(binding: *T.KeyBinding) []u8 {
    const list_ptr = binding.cmdlist orelse return xm.xstrdup("");
    const list: *cmd_mod.CmdList = @ptrCast(@alignCast(list_ptr));

    var out: std.ArrayList(u8) = .{};
    var first = true;
    var cmd = list.head;
    while (cmd) |current| : (cmd = current.next) {
        if (!first) out.appendSlice(xm.allocator, "; ") catch unreachable;
        first = false;
        append_rendered_cmd(&out, current);
    }
    return out.toOwnedSlice(xm.allocator) catch unreachable;
}

fn append_rendered_cmd(out: *std.ArrayList(u8), cmd: *cmd_mod.Cmd) void {
    out.appendSlice(xm.allocator, cmd.entry.name) catch unreachable;
    cmd_render.append_arguments(out, &cmd.args);
}

fn get_prefix_string(args: *const args_mod.Arguments) []u8 {
    if (args.get('P')) |value| return xm.xstrdup(value);

    const raw = opts.options_get_string(opts.global_s_options, "prefix");
    if (raw.len == 0) return xm.xstrdup("");

    const parsed = key_string.key_string_lookup_string(raw);
    if (parsed == T.KEYC_NONE) return xm.xstrdup("");
    if (parsed == T.KEYC_UNKNOWN) return xm.xstrdup(raw);
    return xm.xstrdup(key_string.key_string_lookup_key(parsed, 0));
}

fn effective_sort_criteria(sort_crit: T.SortCriteria) T.SortCriteria {
    return .{
        .order = if (sort_crit.order == .end) .index else sort_crit.order,
        .reversed = sort_crit.reversed,
    };
}

fn order_supported(order: T.SortOrder) bool {
    return switch (order) {
        .index, .modifier, .name, .order, .end => true,
        else => false,
    };
}

fn normalize_key(key: T.key_code) T.key_code {
    return key & (T.KEYC_MASK_KEY | T.KEYC_MASK_MODIFIERS);
}

fn max_key_width(bindings: []const *T.KeyBinding) u32 {
    var width: u32 = 0;
    for (bindings) |binding| {
        width = @max(width, utf8.utf8_cstrwidth(key_string.key_string_lookup_key(binding.key, 0)));
    }
    return width;
}

pub const entry: cmd_mod.CmdEntry = .{
    .name = "list-keys",
    .alias = "lsk",
    .usage = "[-1aNr] [-F format] [-O order] [-P prefix-string] [-T key-table] [key]",
    .template = "1aF:NO:P:rT:",
    .lower = 0,
    .upper = 1,
    .flags = 0,
    .exec = exec,
};

test "list-keys renders binding command and notes views" {
    key_bindings.key_bindings_init();
    key_bindings.key_bindings_add("prefix", T.KEYC_CTRL | 'b', "repeat me", true, null);

    var cause: ?[]u8 = null;
    const bind_cmd = try cmd_mod.cmd_parse_one(&.{ "bind-key", "-T", "root", "F1", "display-message", "hello world" }, null, &cause);
    defer cmd_mod.cmd_free(bind_cmd);
    var bind_list: cmd_mod.CmdList = .{};
    var bind_item = cmdq.CmdqItem{ .client = null, .cmdlist = &bind_list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(bind_cmd, &bind_item));

    const binding = key_bindings.key_bindings_get(key_bindings.key_bindings_get_table("root", false).?, T.KEYC_F1).?;
    const normal = render_binding_line(binding, DEFAULT_TEMPLATE, .normal, "C-b", 0).?;
    defer xm.allocator.free(normal);
    try std.testing.expectEqualStrings("bind-key -T root F1 display-message \"hello world\"", normal);

    const note_binding = key_bindings.key_bindings_get(key_bindings.key_bindings_get_table("prefix", false).?, T.KEYC_CTRL | 'b').?;
    const notes = render_binding_line(note_binding, DEFAULT_NOTES_TEMPLATE, .notes_only, "C-b", utf8.utf8_cstrwidth("C-b")).?;
    defer xm.allocator.free(notes);
    try std.testing.expectEqualStrings("C-b C-b repeat me", notes);
}

test "list-keys command supports format and rejects unsupported sort order" {
    key_bindings.key_bindings_init();
    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    key_bindings.key_bindings_add("root", T.KEYC_F1, "Display help", false, null);

    const binding = key_bindings.key_bindings_get(key_bindings.key_bindings_get_table("root", false).?, T.KEYC_F1).?;
    const rendered = render_binding_line(binding, "#{key_string}", .normal, "", 0).?;
    defer xm.allocator.free(rendered);
    try std.testing.expectEqualStrings("F1", rendered);

    var cause: ?[]u8 = null;
    const order_cmd = try cmd_mod.cmd_parse_one(&.{ "list-keys", "-O", "size" }, null, &cause);
    defer cmd_mod.cmd_free(order_cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = null, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.@"error", cmd_mod.cmd_execute(order_cmd, &item));
}

test "list-keys command honors table selection single key and prefix override" {
    key_bindings.key_bindings_init();
    key_bindings.key_bindings_add("prefix", T.KEYC_CTRL | 'b', "prefix-note", false, null);
    key_bindings.key_bindings_add("root", 'n', null, false, null);

    const prefix_bindings = collect_bindings(
        key_bindings.key_bindings_get_table("prefix", false).?,
        true,
        false,
        normalize_key(T.KEYC_CTRL | 'b'),
        .{ .order = .index },
    );
    defer xm.allocator.free(prefix_bindings);
    try std.testing.expectEqual(@as(usize, 1), prefix_bindings.len);
    const line = render_binding_line(prefix_bindings[0], DEFAULT_NOTES_TEMPLATE, .notes_only, "ZZ", utf8.utf8_cstrwidth("C-b")).?;
    defer xm.allocator.free(line);
    try std.testing.expectEqualStrings("ZZ C-b prefix-note", line);
}
