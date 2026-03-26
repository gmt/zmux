// Copyright (c) 2026 Greg Turner <gmt@be-evil.net>
// ISC licence – see COPYING.
// Ported from tmux/cmd-select-window.c and cmd-new-window.c

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const cmd_mod = @import("cmd.zig");
const cmd_format = @import("cmd-format.zig");
const cmdq = @import("cmd-queue.zig");
const cmd_find = @import("cmd-find.zig");
const sess = @import("session.zig");
const env_mod = @import("environ.zig");
const win_mod = @import("window.zig");
const spawn_mod = @import("spawn.zig");
const server_client_mod = @import("server-client.zig");
const server_fn = @import("server-fn.zig");
const format_mod = @import("format.zig");

const NEW_WINDOW_TEMPLATE = "#{session_name}:#{window_index}.#{pane_index}";

fn exec_selectw(cmd: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {
    const args = cmd_mod.cmd_get_args(cmd);
    var target: T.CmdFindState = .{};
    const cl = cmdq.cmdq_get_client(item);

    if (cmd_find.cmd_find_target(&target, item, args.get('t'), .window, 0) != 0)
        return .@"error";
    const s = target.s orelse return .@"error";
    const wl = target.wl orelse return .@"error";

    _ = sess.session_set_current(s, wl);
    // Update client if one is attached
    if (cl) |c| {
        if (c.session == s) {
            server_client_mod.server_client_apply_session_size(c, s);
            server_client_mod.server_client_force_redraw(c);
        }
    }
    server_fn.server_redraw_session(s);
    return .normal;
}

fn exec_neww(cmd: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {
    const args = cmd_mod.cmd_get_args(cmd);
    var target: T.CmdFindState = .{};
    if (cmd_find.cmd_find_target(&target, item, args.get('t'), .session, T.CMD_FIND_CANFAIL) != 0)
        return .@"error";
    const s = target.s orelse return .@"error";

    var cause: ?[]u8 = null;
    var sc = T.SpawnContext{
        .item = @ptrCast(item),
        .s = s,
        .idx = -1,
        .cwd = args.get('c'),
        .name = args.get('n'),
        .flags = if (args.has('d')) T.SPAWN_DETACHED else 0,
    };
    const argv = argv_tail(args, 0);
    defer if (argv) |slice| free_argv(slice);
    if (argv) |slice| {
        sc.argv = slice;
        if (slice.len == 1 and slice[0].len == 0) sc.flags |= T.SPAWN_EMPTY;
    }
    const overlay = build_overlay_environment(args, item) catch return .@"error";
    defer if (overlay) |env| env_mod.environ_free(env);
    sc.environ = overlay;
    const wl = spawn_mod.spawn_window(&sc, &cause) orelse {
        cmdq.cmdq_error(item, "create window failed: {s}", .{cause orelse "unknown"});
        return .@"error";
    };
    if (!args.has('d')) _ = sess.session_set_current(s, wl);
    server_fn.server_redraw_session(s);
    if (args.has('P')) {
        const state = T.CmdFindState{
            .s = s,
            .wl = wl,
            .w = wl.window,
            .wp = wl.window.active,
            .idx = wl.idx,
        };
        const ctx = cmd_format.target_context(&state, null);
        const rendered = cmd_format.require(item, args.get('F') orelse NEW_WINDOW_TEMPLATE, &ctx) orelse return .@"error";
        defer xm.allocator.free(rendered);
        cmdq.cmdq_print(item, "{s}", .{rendered});
    }
    return .normal;
}

fn build_overlay_environment(args: *const @import("arguments.zig").Arguments, item: *cmdq.CmdqItem) !?*T.Environ {
    const env_entry = args.entry('e') orelse return null;
    const env = env_mod.environ_create();
    errdefer env_mod.environ_free(env);
    for (env_entry.values.items) |value| {
        if (std.mem.indexOfScalar(u8, value, '=')) |_| {
            env_mod.environ_put(env, value, 0);
        } else {
            cmdq.cmdq_error(item, "invalid environment: {s}", .{value});
            return error.InvalidEnvironment;
        }
    }
    return env;
}

fn argv_tail(args: *const @import("arguments.zig").Arguments, start: usize) ?[][]u8 {
    if (args.count() <= start) return null;
    const out = xm.allocator.alloc([]u8, args.count() - start) catch unreachable;
    for (start..args.count()) |idx| out[idx - start] = xm.xstrdup(args.value_at(idx).?);
    return out;
}

fn free_argv(argv: [][]u8) void {
    for (argv) |arg| xm.allocator.free(arg);
    xm.allocator.free(argv);
}

pub const entry: cmd_mod.CmdEntry = .{
    .name = "select-window",
    .alias = "selectw",
    .usage = "[-lnpT] [-t target-window]",
    .template = "lnpTt:",
    .lower = 0,
    .upper = 0,
    .flags = 0,
    .exec = exec_selectw,
};

pub const entry_neww: cmd_mod.CmdEntry = .{
    .name = "new-window",
    .alias = "neww",
    .usage = "[-abdkPS] [-c start-directory] [-e environment] [-F format] [-n window-name] [-t target-session] [shell-command]",
    .template = "abc:dF:kn:St:P",
    .lower = 0,
    .upper = -1,
    .flags = 0,
    .exec = exec_neww,
};
