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
// Ported from tmux/cmd-new-session.c
// Original copyright:
//   Copyright (c) 2007 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

//! cmd-new-session.zig – new-session, has-session, start-server commands.

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const log = @import("log.zig");
const cmd_mod = @import("cmd.zig");
const cmdq = @import("cmd-queue.zig");
const cmd_find = @import("cmd-find.zig");
const sess = @import("session.zig");
const win_mod = @import("window.zig");
const spawn_mod = @import("spawn.zig");
const opts = @import("options.zig");
const env_mod = @import("environ.zig");
const server_client_mod = @import("server-client.zig");
const server_mod = @import("server.zig");
const format_mod = @import("format.zig");

fn exec_new_session(cmd: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {
    const args = cmd_mod.cmd_get_args(cmd);
    const cl = cmdq.cmdq_get_client(item);
    var target: T.CmdFindState = .{};

    // has-session: just validate the -t target (cmd_find_target already did it)
    if (cmd.entry == &entry_has) {
        return .normal;
    }

    // Determine session name
    var session_name: ?[]u8 = null;
    if (args.get('s')) |name| {
        session_name = sess.session_check_name(name);
        if (session_name == null) {
            cmdq.cmdq_error(item, "invalid session name: {s}", .{name});
            return .@"error";
        }
    }
    defer if (session_name) |n| xm.allocator.free(n);

    // If name exists and -A flag set, attach instead
    if (args.has('A')) {
        if (session_name) |n| {
            if (sess.session_find(n)) |existing| {
                _ = existing;
                // TODO: implement attach fallback
                return .normal;
            }
        }
    }

    if (session_name) |n| {
        if (sess.session_find(n)) |_| {
            cmdq.cmdq_error(item, "duplicate session: {s}", .{n});
            return .@"error";
        }
    }

    // Determine dimensions
    var sx: u32 = 80;
    var sy: u32 = 24;
    if (args.get('x')) |xs| {
        if (!std.mem.eql(u8, xs, "-")) {
            sx = std.fmt.parseInt(u32, xs, 10) catch {
                cmdq.cmdq_error(item, "bad width: {s}", .{xs});
                return .@"error";
            };
        } else if (cl) |c| sx = c.tty.sx;
    }
    if (args.get('y')) |ys| {
        if (!std.mem.eql(u8, ys, "-")) {
            sy = std.fmt.parseInt(u32, ys, 10) catch {
                cmdq.cmdq_error(item, "bad height: {s}", .{ys});
                return .@"error";
            };
        } else if (cl) |c| sy = c.tty.sy;
    }
    if (sx == 0) sx = 1;
    if (sy == 0) sy = 1;

    // Determine CWD
    const cwd = server_client_mod.server_client_get_cwd(cl, null);

    var group_target: ?*T.Session = null;
    if (args.get('t')) |target_name| {
        if (cmd_find.cmd_find_target(&target, item, target_name, .session, 0) != 0)
            return .@"error";
        group_target = target.s;
    }

    // Create session
    const new_env = env_mod.environ_create();
    if (cl) |c| env_mod.environ_copy(c.environ, new_env);

    const sess_opts = opts.options_create(opts.global_s_options);

    const s = sess.session_create(
        null,
        session_name,
        cwd,
        new_env,
        sess_opts,
        null,
    );

    var wl: ?*T.Winlink = null;
    if (group_target) |group_session| {
        var keys: std.ArrayList(i32) = .{};
        defer keys.deinit(xm.allocator);
        var it = group_session.windows.keyIterator();
        while (it.next()) |idx| keys.append(xm.allocator, idx.*) catch unreachable;
        std.sort.block(i32, keys.items, {}, std.sort.asc(i32));

        var cause: ?[]u8 = null;
        for (keys.items) |idx| {
            const existing = sess.winlink_find_by_index(&group_session.windows, idx) orelse continue;
            const new_wl = sess.session_attach(s, existing.window, idx, &cause) orelse {
                cmdq.cmdq_error(item, "attach grouped window failed", .{});
                sess.session_destroy(s, false, "exec_new_session");
                return .@"error";
            };
            if (group_session.curw != null and existing.idx == group_session.curw.?.idx) {
                s.curw = new_wl;
            }
        }
        wl = s.curw;
    } else {
        // Spawn the initial window
        var cause: ?[]u8 = null;
        var sc = T.SpawnContext{
            .item = @ptrCast(item),
            .s = s,
            .idx = -1,
            .cwd = cwd,
            .flags = if (args.has('d')) T.SPAWN_DETACHED else 0,
        };
        // Inherit command from positional args
        if (args.count() > 0) {
            // TODO: pass argv from positional args to spawn context
        }
        wl = spawn_mod.spawn_window(&sc, &cause);
        if (wl == null) {
            cmdq.cmdq_error(item, "create window failed: {s}", .{cause orelse "unknown"});
            sess.session_destroy(s, false, "exec_new_session");
            return .@"error";
        }
    }

    // Apply explicit -x/-y dimensions
    if (wl) |created_wl| {
        if (args.has('x') or args.has('y')) {
            const w = created_wl.window;
            w.sx = sx;
            w.sy = sy;
            for (w.panes.items) |wp| {
                wp.sx = sx;
                wp.sy = sy;
            }
        }
    }

    // Attach client if not detached
    if (!args.has('d')) {
        if (cl) |c| {
            if (args.has('x') or args.has('y')) {
                c.tty.sx = sx;
                c.tty.sy = sy;
            }
            server_client_mod.server_client_attach(c, s);
        }
    }

    // Print new session name if -P flag
    if (args.has('P')) {
        const fmt = args.get('F') orelse "#{session_name}:";
        const print_wp = if (wl) |created_wl| created_wl.window.active else null;
        const ctx = format_mod.FormatContext{
            .item = @ptrCast(item),
            .client = cl,
            .session = s,
            .winlink = wl,
            .window = if (wl) |created_wl| created_wl.window else null,
            .pane = print_wp,
        };
        const expanded = format_mod.format_require_complete(xm.allocator, fmt, &ctx) orelse {
            cmdq.cmdq_error(item, "format expansion not supported yet", .{});
            return .@"error";
        };
        defer xm.allocator.free(expanded);
        cmdq.cmdq_print(item, "{s}", .{expanded});
    }

    log.log_debug("new session ${d} {s}", .{ s.id, s.name });
    return .normal;
}

fn exec_has_session(cmd: *cmd_mod.Cmd, item: *cmdq.CmdqItem) T.CmdRetval {
    const args = cmd_mod.cmd_get_args(cmd);
    var target: T.CmdFindState = .{};
    // Resolve the -t target (quietly; not-found → error exit code)
    if (cmd_find.cmd_find_target(&target, item, args.get('t'), .session, T.CMD_FIND_QUIET) != 0)
        return .@"error";
    if (target.s == null) return .@"error";
    return .normal;
}

fn exec_start_server(_cmd: *cmd_mod.Cmd, _item: *cmdq.CmdqItem) T.CmdRetval {
    _ = _cmd;
    _ = _item;
    // Server is already running by the time we execute; just succeed.
    return .normal;
}

pub const entry: cmd_mod.CmdEntry = .{
    .name = "new-session",
    .alias = "new",
    .usage = "[-AdDEPX] [-c start-directory] [-e environment] [-F format] [-f flags] [-n session-name] [-s group-name] [-t target-session] [shell-command]",
    .template = "Ac:dDe:EF:f:n:Ps:t:x:Xy:",
    .lower = 0,
    .upper = -1,
    .flags = T.CMD_STARTSERVER,
    .exec = exec_new_session,
};

pub const entry_has: cmd_mod.CmdEntry = .{
    .name = "has-session",
    .alias = "has",
    .usage = "[-t target-session]",
    .template = "t:",
    .lower = 0,
    .upper = 0,
    .flags = 0,
    .exec = exec_has_session,
};

pub const entry_start: cmd_mod.CmdEntry = .{
    .name = "start-server",
    .alias = "start",
    .usage = "",
    .template = "",
    .lower = 0,
    .upper = 0,
    .flags = T.CMD_STARTSERVER,
    .exec = exec_start_server,
};
