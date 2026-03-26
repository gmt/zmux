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
// Ported from tmux/cmd-find.c
// Original copyright:
//   Copyright (c) 2015 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

//! cmd-find.zig – target session/window/pane resolution.

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const log = @import("log.zig");
const sess = @import("session.zig");
const win_mod = @import("window.zig");
const cmdq_mod = @import("cmd-queue.zig");

/// Determine whether a cmd_find_state is valid.
pub fn cmd_find_valid_state(fs: *const T.CmdFindState) bool {
    return fs.s != null;
}

/// Walk the state and generate a default find state from the server context.
pub fn cmd_find_from_session(current: *T.CmdFindState, s: *T.Session, _flags: u32) void {
    _ = _flags;
    sess.session_repair_current(s);
    current.s = s;
    current.wl = s.curw;
    current.w = if (s.curw) |wl| wl.window else null;
    current.wp = if (current.w) |w| w.active else null;
}

/// Resolve a target string to a cmd_find_state.
pub fn cmd_find_target(
    fs: *T.CmdFindState,
    item: *cmdq_mod.CmdqItem,
    target: ?[]const u8,
    find_type: T.CmdFindType,
    flags: u32,
) i32 {
    const cl = cmdq_mod.cmdq_get_client(item);

    // Default: use current client's session
    if (target == null or target.?.len == 0) {
        if (cl) |c| {
            if (c.session) |s| {
                if (!sess.session_alive(s)) {
                    c.session = null;
                } else {
                    sess.session_repair_current(s);
                    fs.s = s;
                    fs.wl = s.curw;
                    fs.w = if (s.curw) |wl| wl.window else null;
                    fs.wp = if (fs.w) |w| w.active else null;
                    return 0;
                }
            }
        }
        // Fall through to first session
    }

    if (target) |t| {
        switch (find_type) {
            .session => {
                if (t.len > 0 and t[0] == '$') {
                    if (sess.session_find_by_id_str(t)) |s| {
                        sess.session_repair_current(s);
                        fs.s = s;
                        fs.wl = s.curw;
                        fs.w = if (s.curw) |wl| wl.window else null;
                        fs.wp = if (fs.w) |w| w.active else null;
                        return 0;
                    }
                }
                // Strip leading '=' (exact match prefix) and trailing ':'
                var name = if (t.len > 0 and t[0] == '=') t[1..] else t;
                // Strip trailing ':' and anything after (window spec)
                if (std.mem.indexOfScalar(u8, name, ':')) |colon|
                    name = name[0..colon];
                if (name.len > 0) {
                    if (sess.session_find(name)) |s| {
                        sess.session_repair_current(s);
                        fs.s = s;
                        fs.wl = s.curw;
                        fs.w = if (s.curw) |wl| wl.window else null;
                        fs.wp = if (fs.w) |w| w.active else null;
                        return 0;
                    }
                }
            },
            .window => {
                var tw = t;
                if (tw.len > 0 and tw[0] == '=') tw = tw[1..];
                if (flags & T.CMD_FIND_WINDOW_INDEX != 0) {
                    if (find_window_with_index(fs, cl, tw)) return 0;
                }
                if (std.mem.indexOfScalar(u8, tw, ':')) |colon| {
                    const sess_part = tw[0..colon];
                    var win_part = tw[colon + 1 ..];
                    // Strip .pane suffix
                    if (std.mem.indexOfScalar(u8, win_part, '.')) |dot|
                        win_part = win_part[0..dot];
                    const sess_name = if (sess_part.len > 0 and sess_part[0] == '=') sess_part[1..] else sess_part;
                    const target_session = if (sess_name.len == 0)
                        if (cl) |c| c.session else null
                    else
                        sess.session_find(sess_name);
                    if (target_session) |s| {
                        const idx = std.fmt.parseInt(i32, win_part, 10) catch -1;
                        if (sess.winlink_find_by_index(&s.windows, idx)) |wl| {
                            fs.s = s;
                            fs.wl = wl;
                            fs.w = wl.window;
                            fs.wp = wl.window.active;
                            return 0;
                        }
                    }
                }
            },
            .pane => {
                // %id format
                if (t.len > 0 and t[0] == '%') {
                    const id = std.fmt.parseInt(u32, t[1..], 10) catch return -1;
                    if (win_mod.window_pane_find_by_id(id)) |wp| {
                        fs.wp = wp;
                        fs.w = wp.window;
                        var sit = sess.sessions.valueIterator();
                        while (sit.next()) |s_val| {
                            if (sess.winlink_find_by_window(&s_val.*.windows, wp.window)) |wl| {
                                fs.s = s_val.*;
                                fs.wl = wl;
                                return 0;
                            }
                        }
                        return -1;
                    }
                }
                // session:window.pane format (e.g. "0:0.0" or "test:0.0")
                var tp = t;
                if (tp.len > 0 and tp[0] == '=') tp = tp[1..];
                if (std.mem.indexOfScalar(u8, tp, ':')) |colon| {
                    const sess_part = tp[0..colon];
                    const rest = tp[colon + 1 ..];
                    var win_part = rest;
                    var pane_part: ?[]const u8 = null;
                    if (std.mem.indexOfScalar(u8, rest, '.')) |dot| {
                        win_part = rest[0..dot];
                        pane_part = rest[dot + 1 ..];
                    }
                    const target_session = if (sess_part.len == 0)
                        if (cl) |c| c.session else null
                    else
                        sess.session_find(sess_part);
                    if (target_session) |s_val| {
                        const idx = std.fmt.parseInt(i32, win_part, 10) catch -1;
                        if (sess.winlink_find_by_index(&s_val.windows, idx)) |wl| {
                            fs.s = s_val;
                            fs.wl = wl;
                            fs.w = wl.window;
                            fs.wp = resolve_window_pane(wl.window, pane_part);
                            return 0;
                        }
                    }
                    // Try by session ID
                    if (sess.session_find_by_id_str(sess_part)) |s_val| {
                        const idx = std.fmt.parseInt(i32, win_part, 10) catch -1;
                        if (sess.winlink_find_by_index(&s_val.windows, idx)) |wl| {
                            fs.s = s_val;
                            fs.wl = wl;
                            fs.w = wl.window;
                            fs.wp = resolve_window_pane(wl.window, pane_part);
                            return 0;
                        }
                    }
                }
            },
        }
    }

    // If a specific target was given but not found, fail (don't fall through
    // to "use first available session").
    if (target != null and target.?.len > 0) {
        if (flags & T.CMD_FIND_QUIET == 0)
            cmdq_mod.cmdq_error(item, "can't find target: {s}", .{target.?});
        return -1;
    }

    // No target specified: use first available session
    var sit = sess.sessions.valueIterator();
    if (sit.next()) |s| {
        sess.session_repair_current(s.*);
        fs.s = s.*;
        fs.wl = s.*.curw;
        fs.w = if (s.*.curw) |wl| wl.window else null;
        fs.wp = if (fs.w) |w| w.active else null;
        return 0;
    }

    cmdq_mod.cmdq_error(item, "no sessions", .{});
    return -1;
}

fn find_window_with_index(fs: *T.CmdFindState, cl: ?*T.Client, target: []const u8) bool {
    var session_part: ?[]const u8 = null;
    var index_part: ?[]const u8 = null;

    if (std.mem.indexOfScalar(u8, target, ':')) |colon| {
        session_part = target[0..colon];
        const rest = target[colon + 1 ..];
        index_part = if (rest.len == 0) null else rest;
    } else if (target.len > 0 and is_integer(target)) {
        session_part = null;
        index_part = target;
    } else {
        session_part = target;
        index_part = null;
    }

    const s = resolve_window_target_session(cl, session_part orelse "") orelse return false;
    fs.s = s;
    fs.idx = -1;

    if (index_part) |idx_str| {
        fs.idx = std.fmt.parseInt(i32, idx_str, 10) catch return false;
        if (sess.winlink_find_by_index(&s.windows, fs.idx)) |wl| {
            fs.wl = wl;
            fs.w = wl.window;
            fs.wp = wl.window.active;
        } else {
            fs.wl = null;
            fs.w = null;
            fs.wp = null;
        }
        return true;
    }

    fs.wl = s.curw;
    fs.w = if (s.curw) |wl| wl.window else null;
    fs.wp = if (fs.w) |w| w.active else null;
    return true;
}

fn resolve_window_target_session(cl: ?*T.Client, session_name: []const u8) ?*T.Session {
    if (session_name.len == 0) {
        if (cl) |c| {
            if (c.session) |s| {
                if (!sess.session_alive(s)) {
                    c.session = null;
                } else {
                    return s;
                }
            }
        }
        var sit = sess.sessions.valueIterator();
        return if (sit.next()) |s| s.* else null;
    }
    if (session_name[0] == '$') return sess.session_find_by_id_str(session_name);
    return sess.session_find(session_name);
}

fn is_integer(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |ch| {
        if (ch < '0' or ch > '9') return false;
    }
    return true;
}

fn resolve_window_pane(w: *T.Window, pane_part: ?[]const u8) ?*T.WindowPane {
    const pane_spec = pane_part orelse return w.active;
    const pane_idx = std.fmt.parseInt(usize, pane_spec, 10) catch return null;
    if (pane_idx >= w.panes.items.len) return null;
    return w.panes.items[pane_idx];
}

test "cmd_find_target resolves explicit pane indexes within a window" {
    const cmd_mod = @import("cmd.zig");
    const opts = @import("options.zig");
    const env_mod = @import("environ.zig");
    const spawn = @import("spawn.zig");

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

    const s = sess.session_create(null, "find-pane", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("find-pane") != null) sess.session_destroy(s, false, "test");

    var cause: ?[]u8 = null;
    var first_ctx: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const wl = spawn.spawn_window(&first_ctx, &cause).?;
    var second_ctx: T.SpawnContext = .{ .s = s, .wl = wl, .flags = T.SPAWN_EMPTY };
    _ = spawn.spawn_pane(&second_ctx, &cause).?;
    s.curw = wl;

    var list: cmd_mod.CmdList = .{};
    var item = cmdq_mod.CmdqItem{ .client = null, .cmdlist = &list };
    var target: T.CmdFindState = .{};
    try std.testing.expectEqual(@as(i32, 0), cmd_find_target(&target, &item, "find-pane:0.1", .pane, 0));
    try std.testing.expectEqual(wl.window.panes.items[1], target.wp.?);
}
