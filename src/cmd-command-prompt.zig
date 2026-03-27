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
// Ported in part from tmux/cmd-command-prompt.c.
// Original copyright:
//   Copyright (c) 2008 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const cmd_mod = @import("cmd.zig");
const cmd_render = @import("cmd-render.zig");
const cmdq = @import("cmd-queue.zig");
const opts_mod = @import("options.zig");
const options_table = @import("options-table.zig");
const sess_mod = @import("session.zig");
const status_prompt = @import("status-prompt.zig");
const status_runtime = @import("status-runtime.zig");

const PromptStep = struct {
    prompt: []u8,
    input: []u8,
};

const CommandPromptState = struct {
    item: ?*cmdq.CmdqItem = null,
    flags: u32 = 0,
    prompt_type: status_prompt.PromptType = .command,
    steps: []PromptStep,
    current: usize = 0,
    template: []u8,
    argv: std.ArrayList([]u8) = .{},
};

fn state_free(state: *CommandPromptState) void {
    for (state.steps) |step| {
        xm.allocator.free(step.prompt);
        xm.allocator.free(step.input);
    }
    xm.allocator.free(state.steps);
    for (state.argv.items) |arg| xm.allocator.free(arg);
    state.argv.deinit(xm.allocator);
    xm.allocator.free(state.template);
    xm.allocator.destroy(state);
}

fn prompt_free(data: ?*anyopaque) void {
    const state: *CommandPromptState = @ptrCast(@alignCast(data orelse return));
    state_free(state);
}

fn append_candidate(candidates: *std.ArrayList([]u8), value: []const u8) void {
    for (candidates.items) |existing| {
        if (std.mem.eql(u8, existing, value)) return;
    }
    candidates.append(xm.allocator, xm.xstrdup(value)) catch unreachable;
}

fn append_prefixed_candidate(candidates: *std.ArrayList([]u8), flag: ?u8, value: []const u8) void {
    if (flag) |ch| {
        const prefixed = xm.xasprintf("-{c}{s}", .{ ch, value });
        defer xm.allocator.free(prefixed);
        append_candidate(candidates, prefixed);
        return;
    }
    append_candidate(candidates, value);
}

fn free_candidates(candidates: *std.ArrayList([]u8)) void {
    for (candidates.items) |candidate| xm.allocator.free(candidate);
    candidates.deinit(xm.allocator);
}

fn shared_prefix_len(a: []const u8, b: []const u8) usize {
    const limit = @min(a.len, b.len);
    var idx: usize = 0;
    while (idx < limit and a[idx] == b[idx]) : (idx += 1) {}
    return idx;
}

fn longest_candidate_prefix(candidates: []const []u8) ?[]u8 {
    if (candidates.len == 0) return null;
    var prefix_len = candidates[0].len;
    for (candidates[1..]) |candidate| {
        prefix_len = shared_prefix_len(candidates[0][0..prefix_len], candidate);
        if (prefix_len == 0) return null;
    }
    return xm.xstrdup(candidates[0][0..prefix_len]);
}

fn completion_result(word: []const u8, candidates: *std.ArrayList([]u8), add_space: bool) ?[]u8 {
    if (candidates.items.len == 0) return null;
    if (candidates.items.len == 1) {
        if (add_space) return xm.xasprintf("{s} ", .{candidates.items[0]});
        return xm.xstrdup(candidates.items[0]);
    }

    const prefix = longest_candidate_prefix(candidates.items) orelse return null;
    if (std.mem.eql(u8, prefix, word)) {
        xm.allocator.free(prefix);
        return null;
    }
    return prefix;
}

fn collect_command_candidates(candidates: *std.ArrayList([]u8), word: []const u8, at_start: bool) void {
    for (cmd_mod.cmd_entries()) |cmd_entry| {
        if (std.mem.startsWith(u8, cmd_entry.name, word))
            append_candidate(candidates, cmd_entry.name);
        if (cmd_entry.alias) |alias| {
            if (std.mem.startsWith(u8, alias, word))
                append_candidate(candidates, alias);
        }
    }

    for (opts_mod.options_get_array(opts_mod.global_options, "command-alias")) |value| {
        const eq = std.mem.indexOfScalar(u8, value, '=') orelse continue;
        const alias = value[0..eq];
        if (std.mem.startsWith(u8, alias, word))
            append_candidate(candidates, alias);
    }

    if (at_start) return;

    for (options_table.options_table) |table_entry| {
        if (std.mem.startsWith(u8, table_entry.name, word))
            append_candidate(candidates, table_entry.name);
    }

    for (&[_][]const u8{
        "even-horizontal",
        "even-vertical",
        "main-horizontal",
        "main-horizontal-mirrored",
        "main-vertical",
        "main-vertical-mirrored",
        "tiled",
    }) |layout| {
        if (std.mem.startsWith(u8, layout, word))
            append_candidate(candidates, layout);
    }
}

fn complete_command_like(word: []const u8, at_start: bool) ?[]u8 {
    var candidates: std.ArrayList([]u8) = .{};
    defer free_candidates(&candidates);

    collect_command_candidates(&candidates, word, at_start);
    return completion_result(word, &candidates, true);
}

fn collect_session_candidates(candidates: *std.ArrayList([]u8), word: []const u8, flag: ?u8) void {
    var it = sess_mod.sessions.valueIterator();
    while (it.next()) |session_ptr| {
        const session = session_ptr.*;
        if (std.mem.startsWith(u8, session.name, word)) {
            const target = xm.xasprintf("{s}:", .{session.name});
            defer xm.allocator.free(target);
            append_prefixed_candidate(candidates, flag, target);
        }

        var id_buf: [32]u8 = undefined;
        const id_text = std.fmt.bufPrint(&id_buf, "${d}:", .{session.id}) catch unreachable;
        if (std.mem.startsWith(u8, id_text, word))
            append_prefixed_candidate(candidates, flag, id_text);
    }
}

fn find_target_session(c: *T.Client, spec: []const u8) ?*T.Session {
    if (spec.len == 0) return c.session;
    if (spec[0] == '$') return sess_mod.session_find_by_id_str(spec);
    return sess_mod.session_find(spec);
}

fn collect_window_candidates(
    candidates: *std.ArrayList([]u8),
    prompt_type: status_prompt.PromptType,
    session: *T.Session,
    word: []const u8,
    flag: ?u8,
) void {
    var it = session.windows.valueIterator();
    while (it.next()) |wl_ptr| {
        const wl = wl_ptr.*;
        var idx_buf: [32]u8 = undefined;
        const idx_text = std.fmt.bufPrint(&idx_buf, "{d}", .{wl.idx}) catch unreachable;
        if (!std.mem.startsWith(u8, idx_text, word)) continue;

        const target = if (prompt_type == .window_target)
            xm.xstrdup(idx_text)
        else
            xm.xasprintf("{s}:{s}", .{ session.name, idx_text });
        defer xm.allocator.free(target);
        append_prefixed_candidate(candidates, flag, target);
    }
}

fn complete_target_like(c: *T.Client, prompt_type: status_prompt.PromptType, word: []const u8) ?[]u8 {
    var candidates: std.ArrayList([]u8) = .{};
    defer free_candidates(&candidates);

    if (prompt_type == .window_target) {
        const session = c.session orelse return null;
        collect_window_candidates(&candidates, prompt_type, session, word, null);
        return completion_result(word, &candidates, false);
    }

    var flag: ?u8 = null;
    var spec = word;
    if (prompt_type != .target) {
        if (!std.mem.startsWith(u8, word, "-t") and !std.mem.startsWith(u8, word, "-s"))
            return null;
        flag = word[1];
        spec = word[2..];
    }

    const colon = std.mem.indexOfScalar(u8, spec, ':');
    if (colon == null) {
        collect_session_candidates(&candidates, spec, flag);
        return completion_result(word, &candidates, false);
    }

    const session_name = spec[0..colon.?];
    const window_word = spec[colon.? + 1 ..];
    if (std.mem.indexOfScalar(u8, window_word, '.') != null) return null;

    const session = find_target_session(c, session_name) orelse return null;
    collect_window_candidates(&candidates, prompt_type, session, window_word, flag);
    return completion_result(word, &candidates, false);
}

fn prompt_complete(c: *T.Client, data: ?*anyopaque, word: []const u8, offset: usize) ?[]u8 {
    const state: *CommandPromptState = @ptrCast(@alignCast(data orelse return null));

    if (word.len == 0 and state.prompt_type != .target and state.prompt_type != .window_target)
        return null;

    if (state.prompt_type != .target and state.prompt_type != .window_target and
        !std.mem.startsWith(u8, word, "-t") and !std.mem.startsWith(u8, word, "-s"))
    {
        return complete_command_like(word, offset == 0);
    }

    return complete_target_like(c, state.prompt_type, word);
}

fn append_saved_arg(state: *CommandPromptState, text: []const u8) void {
    state.argv.append(xm.allocator, xm.xstrdup(text)) catch unreachable;
}

fn copy_argv_with_current(state: *CommandPromptState, current: ?[]const u8) [][]u8 {
    const extra: usize = if (current != null) 1 else 0;
    const out = xm.allocator.alloc([]u8, state.argv.items.len + extra) catch unreachable;
    var idx: usize = 0;
    for (state.argv.items) |arg| {
        out[idx] = xm.xstrdup(arg);
        idx += 1;
    }
    if (current) |text| out[idx] = xm.xstrdup(text);
    return out;
}

fn free_argv(argv: [][]u8) void {
    for (argv) |arg| xm.allocator.free(arg);
    xm.allocator.free(argv);
}

fn command_head(command: []const u8) []u8 {
    const stop = std.mem.indexOfAny(u8, command, " ,") orelse command.len;
    return xm.xstrdup(command[0..stop]);
}

fn join_template_args(args: *const @import("arguments.zig").Arguments) []u8 {
    const count = args.count();
    if (count == 0) return xm.xstrdup("%1");
    if (count == 1) return xm.xstrdup(args.value_at(0).?);

    const values = xm.allocator.alloc([]const u8, count) catch unreachable;
    defer xm.allocator.free(values);
    for (0..count) |idx| values[idx] = args.value_at(idx).?;
    return cmd_render.stringify_argv(xm.allocator, values);
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

fn expand_command_template(template: []const u8, argv: [][]u8) []u8 {
    var current = xm.xstrdup(template);
    for (argv, 0..) |arg, idx| {
        const next = template_replace(current, arg, idx + 1);
        xm.allocator.free(current);
        current = next;
    }
    return current;
}

fn parse_expanded_command(c: *T.Client, item: ?*cmdq.CmdqItem, expanded: []const u8) ?*cmd_mod.CmdList {
    var pi = T.CmdParseInput{
        .c = c,
        .fs = if (item) |it| cmdq.cmdq_get_target(it) else .{},
        .item = if (item) |it| @ptrCast(it) else null,
    };
    const parsed = cmd_mod.cmd_parse_from_string(expanded, &pi);
    switch (parsed.status) {
        .success => return @ptrCast(@alignCast(parsed.cmdlist.?)),
        .@"error" => {
            const err = parsed.@"error" orelse xm.xstrdup("parse error");
            defer xm.allocator.free(err);
            if (item) |it|
                cmdq.cmdq_error(it, "{s}", .{err})
            else
                status_runtime.present_client_message(c, err);
            return null;
        },
    }
}

fn execute_prompt_command(c: *T.Client, state: *CommandPromptState, current: ?[]const u8) void {
    const argv = copy_argv_with_current(state, current);
    defer free_argv(argv);

    const expanded = expand_command_template(state.template, argv);
    defer xm.allocator.free(expanded);

    const cmdlist = parse_expanded_command(c, state.item, expanded) orelse return;
    if (state.item) |item| {
        const new_item = cmdq.cmdq_get_command(@ptrCast(cmdlist), cmdq.cmdq_get_state(item));
        _ = cmdq.cmdq_insert_after(item, new_item);
    } else {
        cmdq.cmdq_append(c, cmdlist);
    }
}

fn prompt_callback(c: *T.Client, data: ?*anyopaque, s: ?[]const u8, done: bool) i32 {
    const state: *CommandPromptState = @ptrCast(@alignCast(data orelse return 0));

    if (s == null) {
        if (state.item) |item| cmdq.cmdq_continue(item);
        return 0;
    }

    if (done) {
        if (state.flags & status_prompt.PROMPT_INCREMENTAL != 0) {
            if (state.item) |item| cmdq.cmdq_continue(item);
            return 0;
        }

        append_saved_arg(state, s.?);
        if (state.current + 1 < state.steps.len) {
            state.current += 1;
            const next = state.steps[state.current];
            status_prompt.status_prompt_update(c, next.prompt, next.input);
            return 1;
        }
    }

    execute_prompt_command(c, state, if (done) null else s.?);

    if (state.item) |item| cmdq.cmdq_continue(item);
    return 0;
}

fn build_steps(args: *const @import("arguments.zig").Arguments, default_prompt: []const u8, add_space: bool) []PromptStep {
    if (args.has('l')) {
        const prompt_text = if (args.get('p')) |raw| xm.xstrdup(raw) else xm.xstrdup(default_prompt);
        const input_text = if (args.get('I')) |raw| xm.xstrdup(raw) else xm.xstrdup("");
        const steps = xm.allocator.alloc(PromptStep, 1) catch unreachable;
        steps[0] = .{ .prompt = prompt_text, .input = input_text };
        return steps;
    }

    const raw_prompts = if (args.get('p')) |text| text else default_prompt;
    const raw_inputs = args.get('I');

    var prompt_parts: std.ArrayList([]const u8) = .{};
    defer prompt_parts.deinit(xm.allocator);
    var prompt_it = std.mem.splitScalar(u8, raw_prompts, ',');
    while (prompt_it.next()) |part| prompt_parts.append(xm.allocator, part) catch unreachable;

    var input_parts: std.ArrayList([]const u8) = .{};
    defer input_parts.deinit(xm.allocator);
    if (raw_inputs) |text| {
        var input_it = std.mem.splitScalar(u8, text, ',');
        while (input_it.next()) |part| input_parts.append(xm.allocator, part) catch unreachable;
    }

    const steps = xm.allocator.alloc(PromptStep, prompt_parts.items.len) catch unreachable;
    for (prompt_parts.items, 0..) |part, idx| {
        const prompt_text = if (add_space)
            xm.xasprintf("{s} ", .{part})
        else
            xm.xstrdup(part);
        const input_text = if (idx < input_parts.items.len) input_parts.items[idx] else "";
        steps[idx] = .{
            .prompt = prompt_text,
            .input = xm.xstrdup(input_text),
        };
    }
    return steps;
}

fn exec(cmd: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {
    const args = cmd_mod.cmd_get_args(cmd);
    const tc = cmdq.cmdq_get_target_client(item) orelse {
        cmdq.cmdq_error(item, "no target client", .{});
        return .@"error";
    };
    if (status_prompt.status_prompt_active(tc)) return .normal;

    var wait = !args.has('b');
    if (args.has('i')) wait = false;

    const command_template = join_template_args(args);
    errdefer xm.allocator.free(command_template);

    const expanded_template = if (args.has('F')) blk: {
        var target = cmdq.cmdq_get_target(item);
        break :blk @import("cmd-display-message.zig").expand_format(xm.allocator, command_template, &target);
    } else command_template;
    if (expanded_template.ptr != command_template.ptr) xm.allocator.free(command_template);
    errdefer xm.allocator.free(expanded_template);

    const default_prompt, const add_space = if (args.get('p') != null) .{ xm.xstrdup(args.get('p').?), true } else if (args.count() != 0) .{ blk: {
        const head = command_head(expanded_template);
        defer xm.allocator.free(head);
        break :blk xm.xasprintf("({s})", .{head});
    }, true } else .{ xm.xstrdup(":"), false };
    defer xm.allocator.free(default_prompt);

    const steps = build_steps(args, default_prompt, add_space);
    errdefer {
        for (steps) |step| {
            xm.allocator.free(step.prompt);
            xm.allocator.free(step.input);
        }
        xm.allocator.free(steps);
    }

    const prompt_type = if (args.get('T')) |raw_type| blk: {
        const parsed = status_prompt.status_prompt_type(raw_type);
        if (parsed == .invalid) {
            cmdq.cmdq_error(item, "unknown type: {s}", .{raw_type});
            return .@"error";
        }
        break :blk parsed;
    } else .command;

    var flags: u32 = 0;
    if (args.has('1'))
        flags |= status_prompt.PROMPT_SINGLE
    else if (args.has('N'))
        flags |= status_prompt.PROMPT_NUMERIC
    else if (args.has('i'))
        flags |= status_prompt.PROMPT_INCREMENTAL
    else if (args.has('k'))
        flags |= status_prompt.PROMPT_KEY
    else if (args.has('e'))
        flags |= status_prompt.PROMPT_BSPACE_EXIT;

    const state = xm.allocator.create(CommandPromptState) catch unreachable;
    state.* = .{
        .item = if (wait) item else null,
        .flags = flags,
        .prompt_type = prompt_type,
        .steps = steps,
        .template = expanded_template,
    };

    var target = cmdq.cmdq_get_target(item);
    status_prompt.status_prompt_set(
        tc,
        &target,
        state.steps[0].prompt,
        state.steps[0].input,
        prompt_callback,
        prompt_complete,
        prompt_free,
        state,
        flags,
        prompt_type,
    );

    return if (wait) .wait else .normal;
}

pub const entry: cmd_mod.CmdEntry = .{
    .name = "command-prompt",
    .alias = null,
    .usage = "[-1beFiklN] [-I inputs] [-p prompts] [-t target-client] [-T prompt-type] [template]",
    .template = "1beFiklI:Np:t:T:",
    .lower = 0,
    .upper = -1,
    .flags = T.CMD_CLIENT_TFLAG,
    .exec = exec,
};

fn prompt_test_setup(name: []const u8) struct {
    session: *T.Session,
    window: *T.Window,
    client: T.Client,
} {
    const sess = @import("session.zig");
    const win = @import("window.zig");
    const env_mod = @import("environ.zig");
    const opts = @import("options.zig");

    sess.session_init_globals(xm.allocator);
    win.window_init_globals(xm.allocator);

    opts.global_options = opts.options_create(null);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.global_s_options = opts.options_create(null);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.global_w_options = opts.options_create(null);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);

    env_mod.global_environ = env_mod.environ_create();
    status_prompt.status_prompt_history_clear(null);

    const s = sess.session_create(null, name, "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    const w = win.window_create(80, 24, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    var attach_cause: ?[]u8 = null;
    const wl = sess.session_attach(s, w, -1, &attach_cause).?;
    const wp = win.window_add_pane(w, null, 80, 24);
    w.active = wp;
    s.curw = wl;

    const env = env_mod.environ_create();
    var client = T.Client{
        .environ = env,
        .tty = undefined,
        .status = .{ .screen = undefined },
        .flags = T.CLIENT_ATTACHED,
        .session = s,
    };
    client.tty.client = &client;

    return .{ .session = s, .window = w, .client = client };
}

fn prompt_test_teardown(setup: *@TypeOf(prompt_test_setup("x"))) void {
    const sess = @import("session.zig");
    const win = @import("window.zig");
    const env_mod = @import("environ.zig");
    const opts = @import("options.zig");

    status_prompt.status_prompt_clear(&setup.client);
    status_prompt.status_prompt_history_clear(null);
    env_mod.environ_free(setup.client.environ);
    if (sess.session_find(setup.session.name)) |_| sess.session_destroy(setup.session, false, "test");
    win.window_remove_ref(setup.window, "test");
    env_mod.environ_free(env_mod.global_environ);
    opts.options_free(opts.global_options);
    opts.options_free(opts.global_s_options);
    opts.options_free(opts.global_w_options);
}

fn send_key(client: *T.Client, key: T.key_code, bytes: []const u8) void {
    const server_fn = @import("server-fn.zig");

    var event = T.key_event{ .key = key, .len = bytes.len };
    if (bytes.len != 0) @memcpy(event.data[0..bytes.len], bytes);
    _ = server_fn.server_client_handle_key(client, &event);
}

test "command-prompt queues a multi-step command after prompt completion" {
    var setup = prompt_test_setup("command-prompt-test");
    defer prompt_test_teardown(&setup);

    var cause: ?[]u8 = null;
    const argv = [_][]const u8{
        "command-prompt",
        "-p",
        "Name,Again",
        "--",
        "rename-window",
        "-t",
        "command-prompt-test:0",
        "%1-%2",
    };
    const cmdlist = try cmd_mod.cmd_parse_from_argv_with_cause(&argv, &setup.client, &cause);
    defer if (cause) |msg| xm.allocator.free(msg);

    cmdq.cmdq_append(&setup.client, cmdlist);
    try std.testing.expectEqual(@as(u32, 0), cmdq.cmdq_next(&setup.client));
    try std.testing.expectEqualStrings("Name ", status_prompt.status_prompt_message(&setup.client).?);

    send_key(&setup.client, 'A', "A");
    send_key(&setup.client, T.C0_CR, "\r");
    try std.testing.expectEqualStrings("Again ", status_prompt.status_prompt_message(&setup.client).?);
    try std.testing.expectEqualStrings("", status_prompt.status_prompt_input(&setup.client).?);

    send_key(&setup.client, 'B', "B");
    send_key(&setup.client, T.C0_CR, "\r");
    try std.testing.expect(!status_prompt.status_prompt_active(&setup.client));
    try std.testing.expectEqual(@as(u32, 1), cmdq.cmdq_next(&setup.client));
    try std.testing.expectEqualStrings("A-B", setup.window.name);
}

test "command-prompt key mode forwards the tmux key name" {
    var setup = prompt_test_setup("command-prompt-key");
    defer prompt_test_teardown(&setup);

    var cause: ?[]u8 = null;
    const argv = [_][]const u8{
        "command-prompt",
        "-k",
        "--",
        "rename-window",
        "-t",
        "command-prompt-key:0",
        "%1",
    };
    const cmdlist = try cmd_mod.cmd_parse_from_argv_with_cause(&argv, &setup.client, &cause);
    defer if (cause) |msg| xm.allocator.free(msg);

    cmdq.cmdq_append(&setup.client, cmdlist);
    try std.testing.expectEqual(@as(u32, 0), cmdq.cmdq_next(&setup.client));
    send_key(&setup.client, T.KEYC_LEFT, "");
    try std.testing.expect(!status_prompt.status_prompt_active(&setup.client));
    try std.testing.expectEqual(@as(u32, 1), cmdq.cmdq_next(&setup.client));
    try std.testing.expectEqualStrings("Left", setup.window.name);
}

test "command-prompt tab completion uses the shared prompt completion seam" {
    var setup = prompt_test_setup("command-prompt-complete");
    defer prompt_test_teardown(&setup);

    var cause: ?[]u8 = null;
    const argv = [_][]const u8{
        "command-prompt",
        "-I",
        "rename-w",
        "--",
        "%1",
    };
    const cmdlist = try cmd_mod.cmd_parse_from_argv_with_cause(&argv, &setup.client, &cause);
    defer if (cause) |msg| xm.allocator.free(msg);

    cmdq.cmdq_append(&setup.client, cmdlist);
    try std.testing.expectEqual(@as(u32, 0), cmdq.cmdq_next(&setup.client));
    try std.testing.expect(status_prompt.status_prompt_active(&setup.client));
    try std.testing.expectEqualStrings("rename-w", status_prompt.status_prompt_input(&setup.client).?);

    send_key(&setup.client, T.C0_HT, "\t");
    try std.testing.expectEqualStrings("rename-window ", status_prompt.status_prompt_input(&setup.client).?);
}
