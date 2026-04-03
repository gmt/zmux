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

//! Execution and parse-negative coverage for interactive / UI-heavy commands.

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const cmd_mod = @import("cmd.zig");
const cmdq = @import("cmd-queue.zig");
const sess = @import("session.zig");
const win_mod = @import("window.zig");
const opts = @import("options.zig");
const env_mod = @import("environ.zig");
const client_registry = @import("client-registry.zig");
const tty_mod = @import("tty.zig");
const cfg_mod = @import("cfg.zig");

fn attach_placeholder_window(s: *T.Session) void {
    const w = win_mod.window_create(80, 24, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    _ = win_mod.window_add_pane(w, null, 80, 24);
    var cause: ?[]u8 = null;
    const wl = sess.session_attach(s, w, -1, &cause).?;
    s.curw = wl;
}

fn init_harness() void {
    cfg_mod.cfg_reset_files();
    cmdq.cmdq_reset_for_tests();
    sess.session_init_globals(xm.allocator);
    win_mod.window_init_globals(xm.allocator);

    opts.global_options = opts.options_create(null);
    opts.global_s_options = opts.options_create(null);
    opts.global_w_options = opts.options_create(null);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);

    env_mod.global_environ = env_mod.environ_create();
}

fn deinit_harness() void {
    env_mod.environ_free(env_mod.global_environ);
    opts.options_free(opts.global_w_options);
    opts.options_free(opts.global_s_options);
    opts.options_free(opts.global_options);
    cmdq.cmdq_reset_for_tests();
    cfg_mod.cfg_reset_files();
}

fn execWithClient(client: *T.Client, argv: []const []const u8) !T.CmdRetval {
    var cause: ?[]u8 = null;
    const cmd = try cmd_mod.cmd_parse_one(argv, client, &cause);
    defer cmd_mod.cmd_free(cmd);
    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{
        .client = client,
        .target_client = client,
        .cmdlist = &list,
    };
    return cmd_mod.cmd_execute(cmd, &item);
}

fn runCase(client: *T.Client, argv: []const []const u8) !void {
    const r = try execWithClient(client, argv);
    switch (r) {
        .normal, .@"error", .wait, .stop => {},
    }
}

test "cmd UI commands exec smoke on attached client" {
    init_harness();
    defer deinit_harness();

    client_registry.clients.clearRetainingCapacity();
    defer client_registry.clients.clearRetainingCapacity();

    const session = sess.session_create(null, "uiexec", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("uiexec") != null) sess.session_destroy(session, false, "test");
    attach_placeholder_window(session);

    var client = T.Client{
        .name = "uiexec-client",
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{},
        .flags = T.CLIENT_ATTACHED,
        .session = session,
    };
    defer env_mod.environ_free(client.environ);
    tty_mod.tty_init(&client.tty, &client);
    client_registry.add(&client);

    const cases = [_][]const []const u8{
        &.{ "display-panes", "-t", "uiexec" },
        &.{ "break-pane", "-t", "uiexec:0.0", "-n", "broken" },
        &.{ "pipe-pane", "-t", "uiexec:0.0" },
        &.{ "respawn-pane", "-t", "uiexec:0.0", "-k" },
        &.{ "respawn-window", "-t", "uiexec:0", "-k" },
        &.{ "command-prompt", "-p", "prompt#", "list-sessions" },
        &.{ "confirm-before", "-p", "OK?", "display-message", "-p", "ok" },
        &.{ "copy-mode", "-t", "uiexec:0.0" },
        &.{ "choose-tree", "-t", "uiexec:0.0", "-s" },
        &.{ "display-menu", "-T", "t", "-x", "0", "-y", "0", "Item", "x", "display-message", "-p", "m" },
    };

    for (cases) |argv| {
        try runCase(&client, argv);
    }
}

test "cmd UI commands reject bogus flags at parse time" {
    const bad = [_][]const []const u8{
        &.{ "display-panes", "-Z" },
        &.{ "break-pane", "--not-a-flag" },
        &.{ "pipe-pane", "-t", "%0", "-!" },
        &.{ "copy-mode", "-t", "uiexec:0.0", "-@" },
        &.{ "choose-tree", "-t", "%0", "-9" },
    };

    for (bad) |argv| {
        var cause: ?[]u8 = null;
        if (cmd_mod.cmd_parse_one(argv, null, &cause)) |cmd| {
            cmd_mod.cmd_free(cmd);
            return error.ExpectedParseFailure; // Parsed argv that should be invalid.
        } else |_| {
            if (cause) |c| xm.allocator.free(c);
        }
    }
}
