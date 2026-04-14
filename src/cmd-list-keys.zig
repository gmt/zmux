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
const cmd_format = @import("cmd-format.zig");
const cmdq = @import("cmd-queue.zig");
const key_bindings = @import("key-bindings.zig");
const key_string = @import("key-string.zig");
const opts = @import("options.zig");
const sort_mod = @import("sort.zig");
const status_runtime = @import("status-runtime.zig");
const utf8 = @import("utf8.zig");
const format_mod = @import("format.zig");
const cmd_render = @import("cmd-render.zig");

const PrintMode = enum {
    normal,
    notes_only,
};

const DEFAULT_TEMPLATE = "bind-key #{?key_has_repeat,#{?key_repeat,-r,  },} -T #{p|#{key_table_width}|:#{key_table}} #{p|#{key_string_width}|:#{key_string}}#{?key_command, #{key_command},}";
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
    const target_client = item.target_client;

    const count = if (args.has('1') and bindings.len > 1) @as(usize, 1) else bindings.len;
    const key_width = max_key_width(bindings[0..count]);
    const table_width = max_table_width(bindings[0..count]);
    const has_repeat = key_bindings.key_bindings_has_repeat(bindings[0..count]) != 0;
    for (bindings[0..count]) |binding| {
        const line = require_binding_line(item, binding, template, mode, prefix, has_repeat, key_width, table_width) orelse return .@"error";
        defer xm.allocator.free(line);
        if ((args.has('1') and target_client != null) or count == 1) {
            status_runtime.status_message_set_text_optional(target_client, -1, true, false, false, line);
        } else if (line.len != 0) {
            cmdq.cmdq_print(item, "{s}", .{line});
        }
    }
    return .normal;
}

fn require_binding_line(item: *cmdq.CmdqItem, binding: *T.KeyBinding, template: []const u8, mode: PrintMode, prefix: []const u8, has_repeat: bool, key_width: u32, table_width: u32) ?[]u8 {
    const command = render_binding_command(binding);
    defer xm.allocator.free(command);

    const ctx = format_mod.FormatContext{
        .key_binding = binding,
        .key_has_repeat = has_repeat,
        .key_command = command,
        .key_prefix = prefix,
        .key_string_width = key_width,
        .key_table_width = table_width,
        .notes_only = mode == .notes_only,
    };
    return cmd_format.require(item, template, &ctx);
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

fn render_binding_line(binding: *T.KeyBinding, template: []const u8, mode: PrintMode, prefix: []const u8, has_repeat: bool, key_width: u32, table_width: u32) ?[]u8 {
    const command = render_binding_command(binding);
    defer xm.allocator.free(command);

    const ctx = format_mod.FormatContext{
        .key_binding = binding,
        .key_has_repeat = has_repeat,
        .key_command = command,
        .key_prefix = prefix,
        .key_string_width = key_width,
        .key_table_width = table_width,
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
        // Use escaped semicolons so list-keys output can be fed back to
        // source-file without the semicolons being treated as command
        // separators.  Matches tmux CMD_LIST_PRINT_ESCAPED behaviour.
        if (!first) out.appendSlice(xm.allocator, " \\; ") catch unreachable;
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

fn normalize_key(key: T.key_code) T.key_code {
    return key & (T.KEYC_MASK_KEY | T.KEYC_MASK_MODIFIERS);
}

fn max_key_width(bindings: []const *T.KeyBinding) u32 {
    var width: u32 = 0;
    for (bindings) |binding| {
        width = @max(width, utf8.displayWidth(key_string.key_string_lookup_key(binding.key, 0)));
    }
    return width;
}

fn max_table_width(bindings: []const *T.KeyBinding) u32 {
    var width: u32 = 0;
    for (bindings) |binding| {
        width = @max(width, utf8.displayWidth(binding.tablename));
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
    const normal = render_binding_line(binding, DEFAULT_TEMPLATE, .normal, "C-b", false, 0, utf8.displayWidth("root")).?;
    defer xm.allocator.free(normal);
    try std.testing.expectEqualStrings("bind-key  -T root F1 display-message \"hello world\"", normal);

    const note_binding = key_bindings.key_bindings_get(key_bindings.key_bindings_get_table("prefix", false).?, T.KEYC_CTRL | 'b').?;
    const notes = render_binding_line(note_binding, DEFAULT_NOTES_TEMPLATE, .notes_only, "C-b", false, utf8.displayWidth("C-b"), 0).?;
    defer xm.allocator.free(notes);
    try std.testing.expectEqualStrings("C-b C-b repeat me", notes);
}

test "list-keys command supports format accepts shared sort orders and rejects invalid sort order" {
    const env_mod = @import("environ.zig");
    const server = @import("server.zig");

    key_bindings.key_bindings_init();
    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    server.server_reset_message_log();
    defer server.server_reset_message_log();
    key_bindings.key_bindings_add("root", T.KEYC_F1, "Display help", false, null);
    key_bindings.key_bindings_add("unit-list-keys-sort", T.KEYC_F1, null, false, null);
    key_bindings.key_bindings_add("unit-list-keys-sort", T.KEYC_CTRL | 'b', null, false, null);

    const binding = key_bindings.key_bindings_get(key_bindings.key_bindings_get_table("root", false).?, T.KEYC_F1).?;
    const rendered = render_binding_line(binding, "#{key_string}", .normal, "", false, 0, 0).?;
    defer xm.allocator.free(rendered);
    try std.testing.expectEqualStrings("F1", rendered);

    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);
    var client = T.Client{
        .environ = env,
        .tty = undefined,
        .status = .{},
        .flags = T.CLIENT_ATTACHED,
    };
    client.tty.client = &client;

    inline for (&[_][]const u8{ "activity", "creation", "size" }) |order| {
        var cause: ?[]u8 = null;
        const order_cmd = try cmd_mod.cmd_parse_one(
            &.{ "list-keys", "-O", order, "-T", "unit-list-keys-sort", "-P", "", "F1" },
            null,
            &cause,
        );
        defer cmd_mod.cmd_free(order_cmd);
        var list: cmd_mod.CmdList = .{};
        var item = cmdq.CmdqItem{ .client = &client, .cmdlist = &list };
        try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(order_cmd, &item));
        try std.testing.expectEqual(@as(usize, 1), server.message_log.items.len);
        try std.testing.expectEqualStrings("message: bind-key  -T unit-list-keys-sort F1", server.message_log.items[0].msg);
        server.server_reset_message_log();
    }

    var cause: ?[]u8 = null;
    const order_cmd = try cmd_mod.cmd_parse_one(&.{ "list-keys", "-O", "mystery" }, null, &cause);
    defer cmd_mod.cmd_free(order_cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &client, .cmdlist = &list };
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
    const line = render_binding_line(prefix_bindings[0], DEFAULT_NOTES_TEMPLATE, .notes_only, "ZZ", false, utf8.displayWidth("C-b"), 0).?;
    defer xm.allocator.free(line);
    try std.testing.expectEqualStrings("ZZ C-b prefix-note", line);
}

test "list-keys default template pads table and key columns to the filtered maximum width" {
    key_bindings.key_bindings_init();
    var cause: ?[]u8 = null;

    const short_cmd = try cmd_mod.cmd_parse_one(&.{ "bind-key", "-T", "short", "F1", "display-message", "short" }, null, &cause);
    defer cmd_mod.cmd_free(short_cmd);
    var short_list: cmd_mod.CmdList = .{};
    var short_item = cmdq.CmdqItem{ .client = null, .cmdlist = &short_list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(short_cmd, &short_item));

    const long_cmd = try cmd_mod.cmd_parse_one(&.{ "bind-key", "-T", "much-longer-table", "C-b", "display-message", "longer" }, null, &cause);
    defer cmd_mod.cmd_free(long_cmd);
    var long_list: cmd_mod.CmdList = .{};
    var long_item = cmdq.CmdqItem{ .client = null, .cmdlist = &long_list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(long_cmd, &long_item));

    const short_binding = key_bindings.key_bindings_get(key_bindings.key_bindings_get_table("short", false).?, T.KEYC_F1).?;
    const long_binding = key_bindings.key_bindings_get(key_bindings.key_bindings_get_table("much-longer-table", false).?, T.KEYC_CTRL | 'b').?;
    const subset = [_]*T.KeyBinding{ short_binding, long_binding };

    try std.testing.expectEqual(@as(u32, utf8.displayWidth("much-longer-table")), max_table_width(subset[0..]));
    try std.testing.expectEqual(@as(u32, utf8.displayWidth("C-b")), max_key_width(subset[0..]));

    const rendered = render_binding_line(
        short_binding,
        DEFAULT_TEMPLATE,
        .normal,
        "",
        false,
        max_key_width(subset[0..]),
        max_table_width(subset[0..]),
    ).?;
    defer xm.allocator.free(rendered);
    try std.testing.expectEqualStrings("bind-key  -T short             F1  display-message short", rendered);
}

test "list-keys default template keeps the repeat column aligned" {
    key_bindings.key_bindings_init();
    var cause: ?[]u8 = null;

    const repeat_cmd = try cmd_mod.cmd_parse_one(&.{ "bind-key", "-r", "-T", "unit-repeat", "C-b", "display-message", "repeat" }, null, &cause);
    defer cmd_mod.cmd_free(repeat_cmd);
    var repeat_list: cmd_mod.CmdList = .{};
    var repeat_item = cmdq.CmdqItem{ .client = null, .cmdlist = &repeat_list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(repeat_cmd, &repeat_item));

    const plain_cmd = try cmd_mod.cmd_parse_one(&.{ "bind-key", "-T", "unit-repeat", "F1", "display-message", "plain" }, null, &cause);
    defer cmd_mod.cmd_free(plain_cmd);
    var plain_list: cmd_mod.CmdList = .{};
    var plain_item = cmdq.CmdqItem{ .client = null, .cmdlist = &plain_list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(plain_cmd, &plain_item));

    const repeat_binding = key_bindings.key_bindings_get(key_bindings.key_bindings_get_table("unit-repeat", false).?, T.KEYC_CTRL | 'b').?;
    const plain_binding = key_bindings.key_bindings_get(key_bindings.key_bindings_get_table("unit-repeat", false).?, T.KEYC_F1).?;
    const subset = [_]*T.KeyBinding{ repeat_binding, plain_binding };
    const key_width = max_key_width(subset[0..]);
    const table_width = max_table_width(subset[0..]);

    const repeat_line = render_binding_line(repeat_binding, DEFAULT_TEMPLATE, .normal, "", true, key_width, table_width).?;
    defer xm.allocator.free(repeat_line);
    try std.testing.expectEqualStrings("bind-key -r -T unit-repeat C-b display-message repeat", repeat_line);

    const plain_line = render_binding_line(plain_binding, DEFAULT_TEMPLATE, .normal, "", true, key_width, table_width).?;
    defer xm.allocator.free(plain_line);
    try std.testing.expectEqualStrings("bind-key    -T unit-repeat F1  display-message plain", plain_line);
}

test "list-keys -1 shows a single binding through the shared status runtime" {
    const env_mod = @import("environ.zig");

    key_bindings.key_bindings_init();
    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);

    key_bindings.key_bindings_add("unit-list-keys", T.KEYC_F1, "show note", false, null);

    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);
    var client = T.Client{
        .environ = env,
        .tty = undefined,
        .status = .{},
        .flags = T.CLIENT_ATTACHED,
    };
    client.tty.client = &client;
    defer if (client.message_string) |_| status_runtime.status_message_clear(&client);

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "list-keys", "-1", "-N", "-P", "", "-T", "unit-list-keys", "F1" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{
        .client = &client,
        .target_client = &client,
        .cmdlist = &list,
    };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));
    try std.testing.expectEqualStrings("F1 show note", client.message_string.?);
}

test "list-keys single-result without a target client logs through the shared status-message path" {
    const env_mod = @import("environ.zig");

    key_bindings.key_bindings_init();
    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    const server = @import("server.zig");
    server.server_reset_message_log();
    defer server.server_reset_message_log();

    key_bindings.key_bindings_add("unit-list-keys-log", T.KEYC_F1, "show note", false, null);

    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);
    var client = T.Client{
        .environ = env,
        .tty = undefined,
        .status = .{},
        .flags = T.CLIENT_ATTACHED,
    };
    client.tty.client = &client;

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{ "list-keys", "-N", "-P", "", "-T", "unit-list-keys-log", "F1" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &client, .cmdlist = &list };
    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));

    try std.testing.expect(client.message_string == null);
    try std.testing.expectEqual(@as(usize, 1), server.message_log.items.len);
    try std.testing.expectEqualStrings("message: F1 show note", server.message_log.items[0].msg);
}
