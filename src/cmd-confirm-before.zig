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
// Ported in part from tmux/cmd-confirm-before.c.
// Original copyright:
//   Copyright (c) 2009 Tiago Cunha <me@tiagocunha.org>
//   ISC licence – same terms as above.

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const cmd_mod = @import("cmd.zig");
const cmd_display = @import("cmd-display-message.zig");
const cmd_render = @import("cmd-render.zig");
const cmdq = @import("cmd-queue.zig");
const status_prompt = @import("status-prompt.zig");

const ConfirmBeforeState = struct {
    item: ?*cmdq.CmdqItem = null,
    cmdlist: *cmd_mod.CmdList,
    confirm_key: u8 = 'y',
    default_yes: bool = false,
};

fn state_free(state: *ConfirmBeforeState) void {
    cmd_mod.cmd_list_unref(@ptrCast(state.cmdlist));
    xm.allocator.destroy(state);
}

fn prompt_free(data: ?*anyopaque) void {
    const state: *ConfirmBeforeState = @ptrCast(@alignCast(data orelse return));
    state_free(state);
}

fn join_command_words(args: *const @import("arguments.zig").Arguments) []u8 {
    var out: std.ArrayList(u8) = .{};
    defer out.deinit(xm.allocator);

    for (0..args.count()) |idx| {
        if (idx != 0) out.append(xm.allocator, ' ') catch unreachable;
        cmd_render.append_shell_word(&out, args.value_at(idx).?);
    }

    return out.toOwnedSlice(xm.allocator) catch unreachable;
}

fn parse_command_now(cmd: *cmd_mod.Cmd, item: *cmdq.CmdqItem) ?*cmd_mod.CmdList {
    const args = cmd_mod.cmd_get_args(cmd);
    const joined = join_command_words(args);
    defer xm.allocator.free(joined);

    var target = cmdq.cmdq_get_target(item);
    const expanded = cmd_display.expand_format(xm.allocator, joined, &target);
    defer xm.allocator.free(expanded);

    var pi = T.CmdParseInput{
        .c = cmdq.cmdq_get_target_client(item),
        .fs = target,
        .item = @ptrCast(item),
    };
    const parsed = cmd_mod.cmd_parse_from_string(expanded, &pi);
    switch (parsed.status) {
        .success => return @ptrCast(@alignCast(parsed.cmdlist.?)),
        .@"error" => {
            const err = parsed.@"error" orelse xm.xstrdup("parse error");
            defer xm.allocator.free(err);
            cmdq.cmdq_error(item, "{s}", .{err});
            return null;
        },
    }
}

fn prompt_text(cmdlist: *cmd_mod.CmdList, args: *const @import("arguments.zig").Arguments, confirm_key: u8) []u8 {
    if (args.get('p')) |prompt| return xm.xasprintf("{s} ", .{prompt});
    const first = cmdlist.head orelse unreachable;
    return xm.xasprintf("Confirm '{s}'? ({c}/n) ", .{ first.entry.name, confirm_key });
}

fn enqueue_confirmed_command(c: *T.Client, state: *ConfirmBeforeState) void {
    const cmdlist_ref = cmd_mod.cmd_list_ref(@ptrCast(state.cmdlist));
    if (state.item) |item| {
        const new_item = cmdq.cmdq_get_command(cmdlist_ref, cmdq.cmdq_get_state(item));
        _ = cmdq.cmdq_insert_after(item, new_item);
    } else {
        cmdq.cmdq_append(c, @ptrCast(@alignCast(cmdlist_ref)));
    }
}

fn prompt_callback(c: *T.Client, data: ?*anyopaque, s: ?[]const u8, _: bool) i32 {
    const state: *ConfirmBeforeState = @ptrCast(@alignCast(data orelse return 0));
    var retcode: i32 = 1;

    if ((c.flags & T.CLIENT_EXIT) == 0) {
        if (s) |text| {
            if (text.len != 0 and (text[0] == state.confirm_key or (text[0] == '\r' and state.default_yes))) {
                retcode = 0;
                enqueue_confirmed_command(c, state);
            }
        }
    }

    if (state.item) |item| {
        if (cmdq.cmdq_get_client(item)) |item_client| {
            if (item_client.session == null) item_client.retval = retcode;
        }
        cmdq.cmdq_continue(item);
    }
    return 0;
}

fn exec(cmd: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {
    const args = cmd_mod.cmd_get_args(cmd);
    const tc = cmdq.cmdq_get_target_client(item) orelse {
        cmdq.cmdq_error(item, "no target client", .{});
        return .@"error";
    };
    const cmdlist = parse_command_now(cmd, item) orelse return .@"error";

    const state = xm.allocator.create(ConfirmBeforeState) catch unreachable;
    state.* = .{
        .item = if (args.has('b')) null else item,
        .cmdlist = cmdlist,
        .default_yes = args.has('y'),
    };
    errdefer state_free(state);

    if (args.get('c')) |confirm_key| {
        if (confirm_key.len == 1 and confirm_key[0] > 31 and confirm_key[0] < 127) {
            state.confirm_key = confirm_key[0];
        } else {
            cmdq.cmdq_error(item, "invalid confirm key", .{});
            return .@"error";
        }
    }

    const prompt = prompt_text(cmdlist, args, state.confirm_key);
    defer xm.allocator.free(prompt);

    var target = cmdq.cmdq_get_target(item);
    status_prompt.status_prompt_set(
        tc,
        &target,
        prompt,
        null,
        prompt_callback,
        prompt_free,
        state,
        status_prompt.PROMPT_SINGLE,
        .command,
    );

    return if (state.item == null) .normal else .wait;
}

pub const entry: cmd_mod.CmdEntry = .{
    .name = "confirm-before",
    .alias = "confirm",
    .usage = "[-by] [-c confirm-key] [-p prompt] [-t target-client] command",
    .template = "bc:p:t:y",
    .lower = 1,
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

    const s = sess.session_create(null, name, "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    const w = win.window_create(80, 24, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    var attach_cause: ?[]u8 = null;
    const wl = sess.session_attach(s, w, -1, &attach_cause).?;
    const wp = win.window_add_pane(w, null, 80, 24);
    w.active = wp;
    s.curw = wl;

    const env = env_mod.environ_create();
    var client = T.Client{
        .name = xm.xstrdup(name),
        .environ = env,
        .tty = undefined,
        .status = .{ .screen = undefined },
        .flags = T.CLIENT_ATTACHED,
        .session = s,
    };
    client.tty.client = &client;

    return .{
        .session = s,
        .window = w,
        .client = client,
    };
}

fn prompt_test_teardown(setup: *@TypeOf(prompt_test_setup("unused"))) void {
    const sess = @import("session.zig");
    const win = @import("window.zig");
    const env_mod = @import("environ.zig");
    const opts = @import("options.zig");

    status_prompt.status_prompt_clear(&setup.client);
    env_mod.environ_free(setup.client.environ);
    if (setup.client.name) |name| xm.allocator.free(@constCast(name));
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

test "confirm-before waits for confirmation and queues the command after yes" {
    var setup = prompt_test_setup("confirm-before-yes");
    defer prompt_test_teardown(&setup);

    var cause: ?[]u8 = null;
    const argv = [_][]const u8{
        "confirm-before",
        "rename-window",
        "confirmed",
    };
    const cmdlist = try cmd_mod.cmd_parse_from_argv_with_cause(&argv, &setup.client, &cause);
    defer if (cause) |msg| xm.allocator.free(msg);

    cmdq.cmdq_append(&setup.client, cmdlist);
    try std.testing.expectEqual(@as(u32, 0), cmdq.cmdq_next(&setup.client));
    try std.testing.expectEqualStrings("Confirm 'rename-window'? (y/n) ", status_prompt.status_prompt_message(&setup.client).?);

    send_key(&setup.client, 'y', "y");
    try std.testing.expect(!status_prompt.status_prompt_active(&setup.client));
    try std.testing.expectEqual(@as(u32, 1), cmdq.cmdq_next(&setup.client));
    try std.testing.expectEqualStrings("confirmed", setup.window.name);
}

test "confirm-before default-yes accepts enter for single prompts" {
    var setup = prompt_test_setup("confirm-before-enter");
    defer prompt_test_teardown(&setup);

    var cause: ?[]u8 = null;
    const argv = [_][]const u8{
        "confirm-before",
        "-y",
        "rename-window",
        "enter-accepted",
    };
    const cmdlist = try cmd_mod.cmd_parse_from_argv_with_cause(&argv, &setup.client, &cause);
    defer if (cause) |msg| xm.allocator.free(msg);

    cmdq.cmdq_append(&setup.client, cmdlist);
    try std.testing.expectEqual(@as(u32, 0), cmdq.cmdq_next(&setup.client));
    send_key(&setup.client, T.C0_CR, "\r");
    try std.testing.expect(!status_prompt.status_prompt_active(&setup.client));
    try std.testing.expectEqual(@as(u32, 1), cmdq.cmdq_next(&setup.client));
    try std.testing.expectEqualStrings("enter-accepted", setup.window.name);
}

test "confirm-before honors custom prompt text and confirm key" {
    var setup = prompt_test_setup("confirm-before-custom");
    defer prompt_test_teardown(&setup);

    var cause: ?[]u8 = null;
    const argv = [_][]const u8{
        "confirm-before",
        "-c",
        "x",
        "-p",
        "Proceed?",
        "rename-window",
        "custom-ok",
    };
    const cmdlist = try cmd_mod.cmd_parse_from_argv_with_cause(&argv, &setup.client, &cause);
    defer if (cause) |msg| xm.allocator.free(msg);

    cmdq.cmdq_append(&setup.client, cmdlist);
    try std.testing.expectEqual(@as(u32, 0), cmdq.cmdq_next(&setup.client));
    try std.testing.expectEqualStrings("Proceed? ", status_prompt.status_prompt_message(&setup.client).?);

    send_key(&setup.client, 'x', "x");
    try std.testing.expect(!status_prompt.status_prompt_active(&setup.client));
    try std.testing.expectEqual(@as(u32, 1), cmdq.cmdq_next(&setup.client));
    try std.testing.expectEqualStrings("custom-ok", setup.window.name);
}

test "confirm-before background mode returns immediately and appends after confirmation" {
    var setup = prompt_test_setup("confirm-before-background");
    defer prompt_test_teardown(&setup);

    var cause: ?[]u8 = null;
    const argv = [_][]const u8{
        "confirm-before",
        "-b",
        "-c",
        "x",
        "rename-window",
        "background-ok",
    };
    const cmdlist = try cmd_mod.cmd_parse_from_argv_with_cause(&argv, &setup.client, &cause);
    defer if (cause) |msg| xm.allocator.free(msg);

    cmdq.cmdq_append(&setup.client, cmdlist);
    try std.testing.expectEqual(@as(u32, 1), cmdq.cmdq_next(&setup.client));
    try std.testing.expect(status_prompt.status_prompt_active(&setup.client));

    send_key(&setup.client, 'x', "x");
    try std.testing.expect(!status_prompt.status_prompt_active(&setup.client));
    try std.testing.expectEqual(@as(u32, 1), cmdq.cmdq_next(&setup.client));
    try std.testing.expectEqualStrings("background-ok", setup.window.name);
}

test "confirm-before skips the command when the client is already exiting" {
    var setup = prompt_test_setup("confirm-before-exit");
    defer prompt_test_teardown(&setup);

    var cause: ?[]u8 = null;
    const argv = [_][]const u8{
        "confirm-before",
        "rename-window",
        "should-not-run",
    };
    const cmdlist = try cmd_mod.cmd_parse_from_argv_with_cause(&argv, &setup.client, &cause);
    defer if (cause) |msg| xm.allocator.free(msg);

    cmdq.cmdq_append(&setup.client, cmdlist);
    try std.testing.expectEqual(@as(u32, 0), cmdq.cmdq_next(&setup.client));

    setup.client.flags |= T.CLIENT_EXIT;
    send_key(&setup.client, 'y', "y");
    try std.testing.expect(!status_prompt.status_prompt_active(&setup.client));
    try std.testing.expectEqual(@as(u32, 0), cmdq.cmdq_next(&setup.client));
    try std.testing.expect(!std.mem.eql(u8, setup.window.name, "should-not-run"));
}

test "confirm-before rejection updates detached client retval" {
    var env = T.Environ.init(xm.allocator);
    defer env.deinit();

    var client = T.Client{
        .environ = &env,
        .tty = undefined,
        .status = .{ .screen = undefined },
    };

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{
        "confirm-before",
        "kill-server",
    }, null, &cause);
    defer cmd_mod.cmd_free(cmd);
    defer if (cause) |msg| xm.allocator.free(msg);

    var item = cmdq.CmdqItem{
        .client = &client,
    };

    try std.testing.expectEqual(T.CmdRetval.wait, cmd_mod.cmd_execute(cmd, &item));
    var event = T.key_event{ .key = 'n', .len = 1, .data = [_]u8{'n'} ++ std.mem.zeroes([15]u8) };
    try std.testing.expect(status_prompt.status_prompt_handle_key(&client, &event));
    try std.testing.expectEqual(@as(i32, 1), client.retval);
}

test "confirm-before rejects invalid confirm keys" {
    var env = T.Environ.init(xm.allocator);
    defer env.deinit();

    var client = T.Client{
        .environ = &env,
        .tty = undefined,
        .status = .{ .screen = undefined },
    };

    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(&.{
        "confirm-before",
        "-c",
        "zz",
        "kill-server",
    }, null, &cause);
    defer cmd_mod.cmd_free(cmd);
    defer if (cause) |msg| xm.allocator.free(msg);

    var item = cmdq.CmdqItem{
        .client = &client,
    };

    try std.testing.expectEqual(T.CmdRetval.@"error", cmd_mod.cmd_execute(cmd, &item));
}
