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

//! One execution smoke pass per command family (beyond cmd-breadth parse-only).

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
const spawn = @import("spawn.zig");

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

/// Runs argv against a session named `grp` with one pane; accepts normal, error, or wait.
fn runCase(client: *T.Client, argv: []const []const u8) !void {
    const r = try execWithClient(client, argv);
    switch (r) {
        .normal, .@"error", .wait, .stop => {},
    }
}

// tmux parity: `show-prompt-history` uses `-T prompt-type` (not `-t` session).
test "cmd exec group table: buffers options env keys list motion" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(xm.allocator, ".");
    defer xm.allocator.free(dir);
    const save_path = try std.fs.path.join(xm.allocator, &.{ dir, "exec-grp-save.txt" });
    defer xm.allocator.free(save_path);
    const load_path = try std.fs.path.join(xm.allocator, &.{ dir, "exec-grp-load.txt" });
    defer xm.allocator.free(load_path);
    try tmp.dir.writeFile(.{ .sub_path = "exec-grp-load.txt", .data = "loadline\n" });

    init_harness();
    defer deinit_harness();

    client_registry.clients.clearRetainingCapacity();
    defer client_registry.clients.clearRetainingCapacity();

    const session = sess.session_create(null, "grp", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("grp") != null) sess.session_destroy(session, false, "test");
    attach_placeholder_window(session);

    var client = T.Client{
        .name = "exec-grp-client",
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
        &.{ "list-buffers" },
        &.{ "set-buffer", "-b", "execbuf", "hello" },
        &.{ "show-buffer", "-b", "execbuf" },
        &.{ "save-buffer", "-b", "execbuf", save_path },
        &.{ "load-buffer", "-b", "execbuf2", load_path },
        &.{ "paste-buffer", "-b", "execbuf2", "-d" },
        &.{ "show-options", "-g", "status" },
        &.{ "set-option", "-s", "remain-on-exit", "off" },
        &.{ "show-environment", "-g" },
        &.{ "set-environment", "-g", "EXEC_GRP_TEST", "1" },
        &.{ "list-keys", "-T", "root" },
        &.{ "bind-key", "-n", "C-x", "display-message", "-p", "bound" },
        &.{ "unbind-key", "-n", "C-x" },
        &.{ "list-panes", "-t", "grp" },
        &.{ "list-windows", "-t", "grp" },
        &.{ "display-message", "-t", "grp", "-p", "exec-grp-msg" },
        &.{ "show-messages" },
        &.{ "show-prompt-history", "-T", "command" },
        &.{ "select-layout", "-t", "grp", "tiled" },
        &.{ "find-window", "-t", "grp", ".*" },
    };

    for (cases) |argv| {
        try runCase(&client, argv);
    }
}

test "cmd exec group: swap-window with two windows" {
    init_harness();
    defer deinit_harness();

    client_registry.clients.clearRetainingCapacity();
    defer client_registry.clients.clearRetainingCapacity();

    const s = sess.session_create(null, "grp2", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("grp2") != null) sess.session_destroy(s, false, "test");
    attach_placeholder_window(s);

    var cause: ?[]u8 = null;
    var nw_sc: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    _ = spawn.spawn_window(&nw_sc, &cause).?;

    var client = T.Client{
        .name = "exec-grp2-client",
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{},
        .flags = T.CLIENT_ATTACHED,
        .session = s,
    };
    defer env_mod.environ_free(client.environ);
    tty_mod.tty_init(&client.tty, &client);
    client_registry.add(&client);

    try runCase(&client, &.{ "swap-window", "-t", "grp2:0", "-s", "grp2:1" });
}
