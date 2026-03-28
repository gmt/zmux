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
const c = @import("c.zig");
const xm = @import("xmalloc.zig");
const sess = @import("session.zig");
const sort_mod = @import("sort.zig");
const win_mod = @import("window.zig");
const marked_pane_mod = @import("marked-pane.zig");
const opts = @import("options.zig");
const cmdq_mod = @import("cmd-queue.zig");
const client_registry = @import("client-registry.zig");
const env_mod = @import("environ.zig");
const mouse_runtime = @import("mouse-runtime.zig");

const ParsedTarget = struct {
    session: ?[]const u8 = null,
    window: ?[]const u8 = null,
    pane: ?[]const u8 = null,
    window_only: bool = false,
    pane_only: bool = false,
};

/// Determine whether a cmd_find_state is valid.
pub fn cmd_find_valid_state(fs: *const T.CmdFindState) bool {
    const s = fs.s orelse return false;
    const wl = fs.wl orelse return false;
    const w = fs.w orelse return false;
    const wp = fs.wp orelse return false;

    if (!sess.session_alive(s)) return false;
    if (sess.winlink_find_by_window(&s.windows, w) != wl) return false;
    if (wl.window != w) return false;

    for (w.panes.items) |pane| {
        if (pane == wp) return true;
    }
    return false;
}

fn cmd_find_clear_state(fs: *T.CmdFindState, flags: u32) void {
    fs.* = .{};
    fs.flags = flags;
    fs.idx = -1;
}

fn cmd_find_copy_state(dst: *T.CmdFindState, src: *const T.CmdFindState) void {
    dst.s = src.s;
    dst.wl = src.wl;
    dst.idx = src.idx;
    dst.w = src.w;
    dst.wp = src.wp;
}

/// Walk the state and generate a default find state from the server context.
pub fn cmd_find_from_session(current: *T.CmdFindState, s: *T.Session, flags: u32) void {
    cmd_find_clear_state(current, flags);
    sess.session_repair_current(s);
    current.s = s;
    current.wl = s.curw;
    current.w = if (s.curw) |wl| wl.window else null;
    current.wp = if (current.w) |w| w.active else null;
}

pub fn cmd_find_from_mouse(fs: *T.CmdFindState, mouse: *const T.MouseEvent, flags: u32) bool {
    cmd_find_clear_state(fs, flags);

    fs.wp = mouse_runtime.cmd_mouse_pane(mouse, &fs.s, &fs.wl) orelse {
        cmd_find_clear_state(fs, flags);
        return false;
    };
    fs.w = fs.wl.?.window;
    fs.idx = fs.wl.?.idx;
    return true;
}

/// Resolve a target string to a cmd_find_state.
pub fn cmd_find_target(
    fs: *T.CmdFindState,
    item: *cmdq_mod.CmdqItem,
    target: ?[]const u8,
    find_type: T.CmdFindType,
    incoming_flags: u32,
) i32 {
    var flags = incoming_flags;
    if (flags & T.CMD_FIND_CANFAIL != 0) flags |= T.CMD_FIND_QUIET;

    cmd_find_clear_state(fs, flags);

    var current: T.CmdFindState = .{ .flags = flags, .idx = -1 };
    if (flags & T.CMD_FIND_DEFAULT_MARKED != 0 and marked_pane_mod.check()) {
        cmd_find_copy_state(&current, &marked_pane_mod.marked_pane);
    } else {
        current = resolve_current_state(item, flags) orelse {
            if (flags & T.CMD_FIND_QUIET == 0)
                cmdq_mod.cmdq_error(item, "no current target", .{});
            return fail_target(fs, flags);
        };
    }

    if (target == null or target.?.len == 0) {
        cmd_find_copy_state(fs, &current);
        if (flags & T.CMD_FIND_WINDOW_INDEX != 0) fs.idx = -1;
        return 0;
    }

    const raw_target = target.?;
    if (std.mem.eql(u8, raw_target, "@") or
        std.mem.eql(u8, raw_target, "{active}") or
        std.mem.eql(u8, raw_target, "{current}"))
    {
        const cl = cmdq_mod.cmdq_get_client(item) orelse {
            if (flags & T.CMD_FIND_QUIET == 0)
                cmdq_mod.cmdq_error(item, "no current client", .{});
            return fail_target(fs, flags);
        };
        const s = cl.session orelse {
            if (flags & T.CMD_FIND_QUIET == 0)
                cmdq_mod.cmdq_error(item, "no current client", .{});
            return fail_target(fs, flags);
        };
        if (!cmd_find_from_client(fs, cl, flags)) {
            if (flags & T.CMD_FIND_QUIET == 0)
                cmdq_mod.cmdq_error(item, "no current target", .{});
            return fail_target(fs, flags);
        }
        fs.s = s;
        return 0;
    }

    if (std.mem.eql(u8, raw_target, "=") or std.mem.eql(u8, raw_target, "{mouse}")) {
        const mouse = &cmdq_mod.cmdq_get_event(item).m;
        switch (find_type) {
            .pane => {
                if (cmd_find_from_mouse(fs, mouse, flags)) return 0;
                if (mouse_runtime.cmd_mouse_window(mouse, &fs.s)) |mouse_wl| {
                    fs.wl = mouse_wl;
                    fs.w = mouse_wl.window;
                    fs.wp = mouse_wl.window.active;
                    fs.idx = mouse_wl.idx;
                    return 0;
                }
            },
            .window, .session => {
                if (mouse_runtime.cmd_mouse_window(mouse, &fs.s)) |mouse_wl| {
                    fs.wl = mouse_wl;
                    fs.w = mouse_wl.window;
                    fs.wp = mouse_wl.window.active;
                    fs.idx = mouse_wl.idx;
                    return 0;
                }
            },
        }

        if (flags & T.CMD_FIND_QUIET == 0)
            cmdq_mod.cmdq_error(item, "no mouse target", .{});
        return fail_target(fs, flags);
    }
    if (std.mem.eql(u8, raw_target, "~") or std.mem.eql(u8, raw_target, "{marked}")) {
        if (!marked_pane_mod.check()) {
            if (flags & T.CMD_FIND_QUIET == 0)
                cmdq_mod.cmdq_error(item, "no marked target", .{});
            return fail_target(fs, flags);
        }
        cmd_find_copy_state(fs, &marked_pane_mod.marked_pane);
        return 0;
    }

    var parsed = parse_target(raw_target, find_type);
    if (parsed.session) |part| {
        if (part.len > 0 and part[0] == '=') {
            parsed.session = part[1..];
            fs.flags |= T.CMD_FIND_EXACT_SESSION;
        }
    }
    if (parsed.window) |part| {
        if (part.len > 0 and part[0] == '=') {
            parsed.window = part[1..];
            fs.flags |= T.CMD_FIND_EXACT_WINDOW;
        }
    }

    parsed.session = map_session_target(parsed.session);
    parsed.window = map_window_target(parsed.window);
    parsed.pane = map_pane_target(parsed.pane);

    if (parsed.pane != null and (flags & T.CMD_FIND_WINDOW_INDEX != 0)) {
        if (flags & T.CMD_FIND_QUIET == 0)
            cmdq_mod.cmdq_error(item, "can't specify pane here", .{});
        return fail_target(fs, flags);
    }

    if (parsed.session != null) {
        if (!resolve_session_state(fs, parsed.session.?)) {
            if (flags & T.CMD_FIND_QUIET == 0)
                cmdq_mod.cmdq_error(item, "can't find session: {s}", .{parsed.session.?});
            return fail_target(fs, flags);
        }

        if (parsed.window == null and parsed.pane == null) {
            set_state_to_session_current(fs);
            return 0;
        }
        if (parsed.window != null and parsed.pane == null) {
            if (!resolve_window_with_session(fs, parsed.window.?)) {
                if (flags & T.CMD_FIND_QUIET == 0)
                    cmdq_mod.cmdq_error(item, "can't find window: {s}", .{parsed.window.?});
                return fail_target(fs, flags);
            }
            if (fs.wl) |wl| fs.wp = wl.window.active;
            return 0;
        }
        if (parsed.window == null and parsed.pane != null) {
            if (!resolve_pane_with_session(fs, parsed.pane.?)) {
                if (flags & T.CMD_FIND_QUIET == 0)
                    cmdq_mod.cmdq_error(item, "can't find pane: {s}", .{parsed.pane.?});
                return fail_target(fs, flags);
            }
            return 0;
        }

        if (!resolve_window_with_session(fs, parsed.window.?)) {
            if (flags & T.CMD_FIND_QUIET == 0)
                cmdq_mod.cmdq_error(item, "can't find window: {s}", .{parsed.window.?});
            return fail_target(fs, flags);
        }
        if (!resolve_pane_with_window(fs, parsed.pane.?)) {
            if (flags & T.CMD_FIND_QUIET == 0)
                cmdq_mod.cmdq_error(item, "can't find pane: {s}", .{parsed.pane.?});
            return fail_target(fs, flags);
        }
        return 0;
    }

    if (parsed.window != null and parsed.pane != null) {
        if (!resolve_window_general(fs, &current, parsed.window.?, parsed.window_only)) {
            if (flags & T.CMD_FIND_QUIET == 0)
                cmdq_mod.cmdq_error(item, "can't find window: {s}", .{parsed.window.?});
            return fail_target(fs, flags);
        }
        if (!resolve_pane_with_window(fs, parsed.pane.?)) {
            if (flags & T.CMD_FIND_QUIET == 0)
                cmdq_mod.cmdq_error(item, "can't find pane: {s}", .{parsed.pane.?});
            return fail_target(fs, flags);
        }
        return 0;
    }

    if (parsed.window != null) {
        if (!resolve_window_general(fs, &current, parsed.window.?, parsed.window_only)) {
            if (flags & T.CMD_FIND_QUIET == 0)
                cmdq_mod.cmdq_error(item, "can't find window: {s}", .{parsed.window.?});
            return fail_target(fs, flags);
        }
        if (fs.wl) |wl| fs.wp = wl.window.active;
        return 0;
    }

    if (parsed.pane != null) {
        if (!resolve_pane_general(fs, &current, parsed.pane.?, parsed.pane_only)) {
            if (flags & T.CMD_FIND_QUIET == 0)
                cmdq_mod.cmdq_error(item, "can't find pane: {s}", .{parsed.pane.?});
            return fail_target(fs, flags);
        }
        return 0;
    }

    cmd_find_copy_state(fs, &current);
    if (flags & T.CMD_FIND_WINDOW_INDEX != 0) fs.idx = -1;
    return 0;
}

fn fail_target(fs: *T.CmdFindState, flags: u32) i32 {
    cmd_find_clear_state(fs, flags);
    return if (flags & T.CMD_FIND_CANFAIL != 0) 0 else -1;
}

fn resolve_current_state(item: *cmdq_mod.CmdqItem, flags: u32) ?T.CmdFindState {
    var queued = cmdq_mod.cmdq_get_current(item);
    if (cmd_find_valid_state(&queued)) return queued;

    var current: T.CmdFindState = .{};
    if (!cmd_find_from_client(&current, cmdq_mod.cmdq_get_client(item), flags))
        return null;
    return current;
}

fn cmd_find_from_client(fs: *T.CmdFindState, cl: ?*T.Client, flags: u32) bool {
    if (cl == null) return cmd_find_from_nothing(fs, flags);
    const client = cl.?;

    if (client.session) |s| {
        if (!sess.session_alive(s)) return false;
        cmd_find_from_session(fs, s, flags);
        fs.idx = if (fs.wl) |wl| wl.idx else -1;
        return cmd_find_valid_state(fs);
    }

    cmd_find_clear_state(fs, flags);
    if (cmd_find_inside_pane(client)) |wp| {
        const s = select_session_for_window(wp.window, flags) orelse return cmd_find_from_nothing(fs, flags);
        cmd_find_from_session(fs, s, flags);
        fs.idx = if (fs.wl) |wl| wl.idx else -1;
        return cmd_find_valid_state(fs);
    }

    return cmd_find_from_nothing(fs, flags);
}

fn cmd_find_from_nothing(fs: *T.CmdFindState, flags: u32) bool {
    cmd_find_clear_state(fs, flags);
    const s = select_best_session(flags) orelse return false;
    cmd_find_from_session(fs, s, flags);
    fs.idx = if (fs.wl) |wl| wl.idx else -1;
    return cmd_find_valid_state(fs);
}

pub fn cmd_find_best_pane(flags: u32) ?*T.WindowPane {
    var fs: T.CmdFindState = .{};
    if (!cmd_find_from_nothing(&fs, flags)) return null;
    return fs.wp;
}

fn select_best_session(flags: u32) ?*T.Session {
    var best: ?*T.Session = null;
    var sessions = sess.sessions.valueIterator();
    while (sessions.next()) |entry| {
        const candidate = entry.*;
        sess.session_repair_current(candidate);
        const wl = candidate.curw orelse continue;
        if (wl.window.active == null) continue;
        if (cmd_find_session_better(candidate, best, flags))
            best = candidate;
    }
    return best;
}

fn select_session_for_window(window: *T.Window, flags: u32) ?*T.Session {
    var best: ?*T.Session = null;
    var sessions = sess.sessions.valueIterator();
    while (sessions.next()) |entry| {
        const candidate = entry.*;
        if (!sess.session_has_window(candidate, window)) continue;
        sess.session_repair_current(candidate);
        const wl = candidate.curw orelse continue;
        if (wl.window.active == null) continue;
        if (cmd_find_session_better(candidate, best, flags))
            best = candidate;
    }
    return best;
}

fn cmd_find_inside_pane(cl: *T.Client) ?*T.WindowPane {
    if (cl.ttyname) |ttyname| {
        var panes = win_mod.all_window_panes.valueIterator();
        while (panes.next()) |entry| {
            const wp = entry.*;
            if (wp.fd == -1) continue;
            if (std.mem.eql(u8, pane_tty_name(wp), ttyname))
                return wp;
        }
    }

    const entry = env_mod.environ_find(cl.environ, "TMUX_PANE") orelse return null;
    const value = entry.value orelse return null;
    if (value.len <= 1 or value[0] != '%') return null;
    const id = std.fmt.parseUnsigned(u32, value[1..], 10) catch return null;
    return win_mod.window_pane_find_by_id(id);
}

fn pane_tty_name(wp: *T.WindowPane) []const u8 {
    const len = std.mem.indexOfScalar(u8, &wp.tty_name, 0) orelse wp.tty_name.len;
    return wp.tty_name[0..len];
}

fn cmd_find_client_better(candidate: *T.Client, than: ?*T.Client) bool {
    if (than == null) return true;
    if (candidate.activity_time != than.?.activity_time)
        return candidate.activity_time > than.?.activity_time;
    return candidate.id > than.?.id;
}

fn cmd_find_session_better(candidate: *T.Session, than: ?*T.Session, flags: u32) bool {
    if (than == null) return true;
    if (flags & T.CMD_FIND_PREFER_UNATTACHED != 0) {
        const than_attached = than.?.attached != 0;
        if (than_attached and candidate.attached == 0) return true;
        if (!than_attached and candidate.attached != 0) return false;
    }
    if (candidate.activity_time != than.?.activity_time)
        return candidate.activity_time > than.?.activity_time;
    return candidate.id > than.?.id;
}

pub fn cmd_find_best_client(s: ?*T.Session) ?*T.Client {
    var session_filter = s;
    if (session_filter != null and session_filter.?.attached == 0)
        session_filter = null;

    var best: ?*T.Client = null;
    const clients = sort_mod.sorted_clients(.{ .order = .creation, .reversed = true });
    defer xm.allocator.free(clients);

    for (clients) |candidate| {
        if (candidate.session == null) continue;
        if (session_filter != null and candidate.session != session_filter.?) continue;
        if (cmd_find_client_better(candidate, best))
            best = candidate;
    }
    return best;
}

pub fn cmd_find_current_client(item: ?*cmdq_mod.CmdqItem, quiet: bool) ?*T.Client {
    var client: ?*T.Client = null;
    if (item) |queued|
        client = cmdq_mod.cmdq_get_client(queued);

    if (client != null and client.?.session != null)
        return client;

    var found: ?*T.Client = null;
    if (client) |unattached| {
        if (cmd_find_inside_pane(unattached)) |wp| {
            const s = select_session_for_window(wp.window, T.CMD_FIND_QUIET);
            if (s != null) found = cmd_find_best_client(s);
        }
    }
    if (found == null) {
        const s = select_best_session(T.CMD_FIND_QUIET);
        if (s != null) found = cmd_find_best_client(s);
    }

    if (found == null and item != null and !quiet)
        cmdq_mod.cmdq_error(item.?, "no current client", .{});
    return found;
}

pub fn cmd_find_client(item: ?*cmdq_mod.CmdqItem, target: ?[]const u8, quiet: bool) ?*T.Client {
    if (target == null)
        return cmd_find_current_client(item, quiet);

    var trimmed = target.?;
    if (trimmed.len != 0 and trimmed[trimmed.len - 1] == ':')
        trimmed = trimmed[0 .. trimmed.len - 1];

    for (client_registry.clients.items) |cl| {
        if (cl.session == null) continue;
        if (cl.name) |name| {
            if (std.mem.eql(u8, trimmed, name)) return cl;
        }
        if (cl.ttyname) |ttyname| {
            if (std.mem.eql(u8, trimmed, ttyname)) return cl;
            if (std.mem.startsWith(u8, ttyname, "/dev/") and
                std.mem.eql(u8, trimmed, ttyname["/dev/".len..]))
                return cl;
        }
    }

    if (item != null and !quiet)
        cmdq_mod.cmdq_error(item.?, "can't find client: {s}", .{trimmed});
    return null;
}

fn resolve_session_state(fs: *T.CmdFindState, target: []const u8) bool {
    const session = find_session(target, fs.flags) orelse return false;
    sess.session_repair_current(session);
    fs.s = session;
    return true;
}

fn find_session(target: []const u8, flags: u32) ?*T.Session {
    if (target.len == 0) return null;
    if (target[0] == '$') return sess.session_find_by_id_str(target);

    if (sess.session_find(target)) |session|
        return session;
    if (find_session_by_client(target)) |session|
        return session;
    if (flags & T.CMD_FIND_EXACT_SESSION != 0)
        return null;

    var matched: ?*T.Session = null;
    var sessions = sess.sessions.valueIterator();
    while (sessions.next()) |entry| {
        const candidate = entry.*;
        if (std.mem.startsWith(u8, candidate.name, target)) {
            if (matched != null) return null;
            matched = candidate;
        }
    }
    if (matched != null) return matched;

    matched = null;
    sessions = sess.sessions.valueIterator();
    while (sessions.next()) |entry| {
        const candidate = entry.*;
        if (fnmatch_matches(target, candidate.name)) {
            if (matched != null) return null;
            matched = candidate;
        }
    }
    return matched;
}

fn find_session_by_client(target: []const u8) ?*T.Session {
    var trimmed = target;
    if (trimmed.len > 0 and trimmed[trimmed.len - 1] == ':')
        trimmed = trimmed[0 .. trimmed.len - 1];

    for (client_registry.clients.items) |cl| {
        const session = cl.session orelse continue;
        if (cl.name) |name| {
            if (std.mem.eql(u8, trimmed, name)) return session;
        }
        if (cl.ttyname) |ttyname| {
            if (std.mem.eql(u8, trimmed, ttyname)) return session;
            if (std.mem.startsWith(u8, ttyname, "/dev/") and
                std.mem.eql(u8, trimmed, ttyname["/dev/".len..]))
                return session;
        }
    }
    return null;
}

fn set_state_to_session_current(fs: *T.CmdFindState) void {
    const s = fs.s orelse return;
    sess.session_repair_current(s);
    fs.wl = s.curw;
    fs.idx = -1;
    fs.w = if (fs.wl) |wl| wl.window else null;
    fs.wp = if (fs.w) |w| w.active else null;
}

fn resolve_window_general(fs: *T.CmdFindState, current: *const T.CmdFindState, target: []const u8, only: bool) bool {
    if (target.len > 0 and target[0] == '@') {
        const id = std.fmt.parseUnsigned(u32, target[1..], 10) catch return false;
        const w = win_mod.window_find_by_id(id) orelse return false;
        const s = select_session_for_window(w, fs.flags) orelse return false;
        fs.s = s;
        return set_state_for_window(fs, w);
    }

    fs.s = current.s;
    if (!resolve_window_with_session(fs, target)) {
        if (!only and resolve_session_state(fs, target)) {
            set_state_to_session_current(fs);
            return fs.w != null;
        }
        return false;
    }
    return true;
}

fn resolve_window_with_session(fs: *T.CmdFindState, target: []const u8) bool {
    const s = fs.s orelse return false;
    sess.session_repair_current(s);
    fs.wl = s.curw;
    fs.w = if (fs.wl) |wl| wl.window else null;
    fs.idx = if (fs.wl) |wl| wl.idx else -1;

    if (target.len == 0) return fs.w != null;

    if (target[0] == '@') {
        const id = std.fmt.parseUnsigned(u32, target[1..], 10) catch return false;
        const w = win_mod.window_find_by_id(id) orelse return false;
        if (!sess.session_has_window(s, w)) return false;
        return set_state_for_window(fs, w);
    }

    const exact = fs.flags & T.CMD_FIND_EXACT_WINDOW != 0;

    if (!exact and (target[0] == '+' or target[0] == '-')) {
        const amount = parse_optional_positive(target[1..]) orelse return false;
        if (fs.flags & T.CMD_FIND_WINDOW_INDEX != 0) {
            const current_wl = s.curw orelse return false;
            if (target[0] == '+') {
                if (current_wl.idx > std.math.maxInt(i32) - @as(i32, @intCast(amount)))
                    return false;
                fs.idx = current_wl.idx + @as(i32, @intCast(amount));
            } else {
                if (current_wl.idx < @as(i32, @intCast(amount)))
                    return false;
                fs.idx = current_wl.idx - @as(i32, @intCast(amount));
            }
            return true;
        }

        const next = if (target[0] == '+')
            window_next_by_number(s, amount)
        else
            window_previous_by_number(s, amount);
        if (next) |wl| {
            fs.wl = wl;
            fs.idx = wl.idx;
            fs.w = wl.window;
            return true;
        }
    }

    if (!exact) {
        if (std.mem.eql(u8, target, "!")) {
            if (s.lastw.items.len == 0) return false;
            const wl = s.lastw.items[0];
            fs.wl = wl;
            fs.idx = wl.idx;
            fs.w = wl.window;
            return true;
        }
        if (std.mem.eql(u8, target, "^")) {
            const wl = session_first_by_index(s) orelse return false;
            fs.wl = wl;
            fs.idx = wl.idx;
            fs.w = wl.window;
            return true;
        }
        if (std.mem.eql(u8, target, "$")) {
            const wl = session_last_by_index(s) orelse return false;
            fs.wl = wl;
            fs.idx = wl.idx;
            fs.w = wl.window;
            return true;
        }
    }

    if (target[0] != '+' and target[0] != '-') {
        if (std.fmt.parseInt(i32, target, 10)) |idx| {
            if (sess.winlink_find_by_index(&s.windows, idx)) |wl| {
                fs.wl = wl;
                fs.idx = wl.idx;
                fs.w = wl.window;
                return true;
            }
            if (fs.flags & T.CMD_FIND_WINDOW_INDEX != 0) {
                fs.idx = idx;
                return true;
            }
        } else |_| {}
    }

    if (match_window_name(s, target, .exact)) |wl| {
        fs.wl = wl;
        fs.idx = wl.idx;
        fs.w = wl.window;
        return true;
    }
    if (exact) return false;

    if (match_window_name(s, target, .prefix)) |wl| {
        fs.wl = wl;
        fs.idx = wl.idx;
        fs.w = wl.window;
        return true;
    }
    if (match_window_name(s, target, .pattern)) |wl| {
        fs.wl = wl;
        fs.idx = wl.idx;
        fs.w = wl.window;
        return true;
    }
    return false;
}

const WindowMatchKind = enum { exact, prefix, pattern };

fn match_window_name(s: *T.Session, target: []const u8, kind: WindowMatchKind) ?*T.Winlink {
    var matched: ?*T.Winlink = null;
    var it = s.windows.valueIterator();
    while (it.next()) |entry| {
        const wl = entry.*;
        const ok = switch (kind) {
            .exact => std.mem.eql(u8, target, wl.window.name),
            .prefix => std.mem.startsWith(u8, wl.window.name, target),
            .pattern => fnmatch_matches(target, wl.window.name),
        };
        if (!ok) continue;
        if (matched != null) return null;
        matched = wl;
    }
    return matched;
}

fn resolve_pane_general(fs: *T.CmdFindState, current: *const T.CmdFindState, target: []const u8, only: bool) bool {
    if (target.len > 0 and target[0] == '%') {
        const id = std.fmt.parseUnsigned(u32, target[1..], 10) catch return false;
        const wp = win_mod.window_pane_find_by_id(id) orelse return false;
        fs.wp = wp;
        fs.w = wp.window;
        const s = select_session_for_window(wp.window, fs.flags) orelse return false;
        fs.s = s;
        return set_state_for_window(fs, wp.window);
    }

    fs.s = current.s;
    fs.wl = current.wl;
    fs.idx = current.idx;
    fs.w = current.w;
    if (resolve_pane_with_window(fs, target))
        return true;

    if (!only and resolve_window_general(fs, current, target, false)) {
        fs.wp = if (fs.w) |w| w.active else null;
        return fs.wp != null;
    }
    return false;
}

fn resolve_pane_with_session(fs: *T.CmdFindState, target: []const u8) bool {
    if (target.len > 0 and target[0] == '%') {
        const id = std.fmt.parseUnsigned(u32, target[1..], 10) catch return false;
        const wp = win_mod.window_pane_find_by_id(id) orelse return false;
        if (!set_state_for_window(fs, wp.window)) return false;
        fs.wp = wp;
        return true;
    }

    const s = fs.s orelse return false;
    sess.session_repair_current(s);
    fs.wl = s.curw;
    fs.idx = if (fs.wl) |wl| wl.idx else -1;
    fs.w = if (fs.wl) |wl| wl.window else null;
    return resolve_pane_with_window(fs, target);
}

fn resolve_pane_with_window(fs: *T.CmdFindState, target: []const u8) bool {
    const w = fs.w orelse return false;
    if (target.len == 0) {
        fs.wp = w.active;
        return fs.wp != null;
    }

    if (target[0] == '%') {
        const id = std.fmt.parseUnsigned(u32, target[1..], 10) catch return false;
        const wp = win_mod.window_pane_find_by_id(id) orelse return false;
        if (wp.window != w) return false;
        fs.wp = wp;
        return true;
    }

    if (std.mem.eql(u8, target, "!")) {
        fs.wp = win_mod.window_get_last_pane(w);
        return fs.wp != null;
    }
    if (std.mem.eql(u8, target, "{up-of}")) {
        const active = w.active orelse return false;
        fs.wp = win_mod.window_pane_find_up(active);
        return fs.wp != null;
    }
    if (std.mem.eql(u8, target, "{down-of}")) {
        const active = w.active orelse return false;
        fs.wp = win_mod.window_pane_find_down(active);
        return fs.wp != null;
    }
    if (std.mem.eql(u8, target, "{left-of}")) {
        const active = w.active orelse return false;
        fs.wp = win_mod.window_pane_find_left(active);
        return fs.wp != null;
    }
    if (std.mem.eql(u8, target, "{right-of}")) {
        const active = w.active orelse return false;
        fs.wp = win_mod.window_pane_find_right(active);
        return fs.wp != null;
    }

    if (target[0] == '+' or target[0] == '-') {
        const amount = parse_optional_positive(target[1..]) orelse return false;
        const active = w.active orelse return false;
        fs.wp = if (target[0] == '+')
            window_pane_next_by_number(w, active, amount)
        else
            window_pane_previous_by_number(w, active, amount);
        return fs.wp != null;
    }

    if (std.fmt.parseUnsigned(u32, target, 10)) |idx| {
        fs.wp = window_pane_at_index(w, idx);
        if (fs.wp != null) return true;
    } else |_| {}

    fs.wp = window_find_string(w, target);
    return fs.wp != null;
}

fn set_state_for_window(fs: *T.CmdFindState, window: *T.Window) bool {
    const s = fs.s orelse return false;
    const wl = sess.winlink_find_by_window(&s.windows, window) orelse return false;
    fs.wl = wl;
    fs.idx = wl.idx;
    fs.w = window;
    if (fs.wp == null or fs.wp.?.window != window)
        fs.wp = window.active;
    return fs.wp != null;
}

fn parse_target(target: []const u8, find_type: T.CmdFindType) ParsedTarget {
    const colon = std.mem.indexOfScalar(u8, target, ':');
    const period = if (colon) |i|
        if (std.mem.indexOfScalar(u8, target[i + 1 ..], '.')) |j| i + 1 + j else null
    else
        std.mem.indexOfScalar(u8, target, '.');

    var parsed: ParsedTarget = .{};
    if (colon) |colon_idx| {
        if (period) |period_idx| {
            parsed.session = target[0..colon_idx];
            parsed.window = target[colon_idx + 1 .. period_idx];
            parsed.window_only = true;
            parsed.pane = target[period_idx + 1 ..];
            parsed.pane_only = true;
        } else {
            parsed.session = target[0..colon_idx];
            parsed.window = target[colon_idx + 1 ..];
            parsed.window_only = true;
        }
    } else if (period) |period_idx| {
        parsed.window = target[0..period_idx];
        parsed.pane = target[period_idx + 1 ..];
        parsed.pane_only = true;
    } else {
        if (target.len > 0 and target[0] == '$')
            parsed.session = target
        else if (target.len > 0 and target[0] == '@')
            parsed.window = target
        else if (target.len > 0 and target[0] == '%')
            parsed.pane = target
        else {
            switch (find_type) {
                .session => parsed.session = target,
                .window => parsed.window = target,
                .pane => parsed.pane = target,
            }
        }
    }

    if (parsed.session) |part| {
        if (part.len == 0) parsed.session = null;
    }
    if (parsed.window) |part| {
        if (part.len == 0) parsed.window = null;
    }
    if (parsed.pane) |part| {
        if (part.len == 0) parsed.pane = null;
    }
    return parsed;
}

fn map_session_target(value: ?[]const u8) ?[]const u8 {
    return value;
}

fn map_window_target(value: ?[]const u8) ?[]const u8 {
    const target = value orelse return null;
    if (std.mem.eql(u8, target, "{start}")) return "^";
    if (std.mem.eql(u8, target, "{last}")) return "!";
    if (std.mem.eql(u8, target, "{end}")) return "$";
    if (std.mem.eql(u8, target, "{next}")) return "+";
    if (std.mem.eql(u8, target, "{previous}")) return "-";
    return target;
}

fn map_pane_target(value: ?[]const u8) ?[]const u8 {
    const target = value orelse return null;
    if (std.mem.eql(u8, target, "{last}")) return "!";
    if (std.mem.eql(u8, target, "{next}")) return "+";
    if (std.mem.eql(u8, target, "{previous}")) return "-";
    return target;
}

fn parse_optional_positive(text: []const u8) ?usize {
    if (text.len == 0) return 1;
    return std.fmt.parseUnsigned(usize, text, 10) catch null;
}

fn session_first_by_index(s: *T.Session) ?*T.Winlink {
    const winlinks = sort_mod.sorted_winlinks_session(s, .{});
    defer xm.allocator.free(winlinks);
    return if (winlinks.len == 0) null else winlinks[0];
}

fn session_last_by_index(s: *T.Session) ?*T.Winlink {
    const winlinks = sort_mod.sorted_winlinks_session(s, .{});
    defer xm.allocator.free(winlinks);
    return if (winlinks.len == 0) null else winlinks[winlinks.len - 1];
}

fn window_next_by_number(s: *T.Session, count: usize) ?*T.Winlink {
    const current = s.curw orelse return null;
    const winlinks = sort_mod.sorted_winlinks_session(s, .{});
    defer xm.allocator.free(winlinks);
    if (winlinks.len == 0) return null;

    var current_idx: usize = 0;
    while (current_idx < winlinks.len and winlinks[current_idx] != current) : (current_idx += 1) {}
    if (current_idx == winlinks.len) return null;
    return winlinks[(current_idx + count) % winlinks.len];
}

fn window_previous_by_number(s: *T.Session, count: usize) ?*T.Winlink {
    const current = s.curw orelse return null;
    const winlinks = sort_mod.sorted_winlinks_session(s, .{});
    defer xm.allocator.free(winlinks);
    if (winlinks.len == 0) return null;

    var current_idx: usize = 0;
    while (current_idx < winlinks.len and winlinks[current_idx] != current) : (current_idx += 1) {}
    if (current_idx == winlinks.len) return null;

    const offset = count % winlinks.len;
    const next_idx = (current_idx + winlinks.len - offset) % winlinks.len;
    return winlinks[next_idx];
}

fn window_pane_at_index(w: *T.Window, idx: u32) ?*T.WindowPane {
    var current = opts.options_get_number(w.options, "pane-base-index");
    for (w.panes.items) |pane| {
        if (current == idx) return pane;
        current += 1;
    }
    return null;
}

fn window_pane_next_by_number(w: *T.Window, current: *T.WindowPane, count: usize) ?*T.WindowPane {
    const start = win_mod.window_pane_index(w, current) orelse return null;
    if (w.panes.items.len == 0) return null;
    return w.panes.items[(start + count) % w.panes.items.len];
}

fn window_pane_previous_by_number(w: *T.Window, current: *T.WindowPane, count: usize) ?*T.WindowPane {
    const start = win_mod.window_pane_index(w, current) orelse return null;
    if (w.panes.items.len == 0) return null;
    const offset = count % w.panes.items.len;
    return w.panes.items[(start + w.panes.items.len - offset) % w.panes.items.len];
}

fn window_find_string(w: *T.Window, target: []const u8) ?*T.WindowPane {
    var x = w.sx / 2;
    var y = w.sy / 2;
    var top: u32 = 0;
    var bottom = if (w.sy == 0) 0 else w.sy - 1;

    const status = opts.options_get_number(w.options, "pane-border-status");
    if (status == T.PANE_STATUS_TOP)
        top += 1
    else if (status == T.PANE_STATUS_BOTTOM and bottom > 0)
        bottom -= 1;

    if (std.ascii.eqlIgnoreCase(target, "top"))
        y = top
    else if (std.ascii.eqlIgnoreCase(target, "bottom"))
        y = bottom
    else if (std.ascii.eqlIgnoreCase(target, "left"))
        x = 0
    else if (std.ascii.eqlIgnoreCase(target, "right"))
        x = if (w.sx == 0) 0 else w.sx - 1
    else if (std.ascii.eqlIgnoreCase(target, "top-left")) {
        x = 0;
        y = top;
    } else if (std.ascii.eqlIgnoreCase(target, "top-right")) {
        x = if (w.sx == 0) 0 else w.sx - 1;
        y = top;
    } else if (std.ascii.eqlIgnoreCase(target, "bottom-left")) {
        x = 0;
        y = bottom;
    } else if (std.ascii.eqlIgnoreCase(target, "bottom-right")) {
        x = if (w.sx == 0) 0 else w.sx - 1;
        y = bottom;
    } else return null;

    return win_mod.window_get_active_at(w, x, y);
}

fn fnmatch_matches(pattern: []const u8, text: []const u8) bool {
    const pattern_z = xm.xm_dupeZ(pattern);
    defer xm.allocator.free(pattern_z);
    const text_z = xm.xm_dupeZ(text);
    defer xm.allocator.free(text_z);
    return c.posix_sys.fnmatch(pattern_z.ptr, text_z.ptr, 0) == 0;
}

test "cmd_find_target resolves current client state when target is omitted" {
    const cmd_mod = @import("cmd.zig");
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

    const s = sess.session_create(null, "find-current", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("find-current") != null) sess.session_destroy(s, false, "test");

    var cause: ?[]u8 = null;
    var first_ctx: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const wl = spawn.spawn_window(&first_ctx, &cause).?;
    var second_ctx: T.SpawnContext = .{ .s = s, .wl = wl, .flags = T.SPAWN_EMPTY };
    const second = spawn.spawn_pane(&second_ctx, &cause).?;
    _ = win_mod.window_set_active_pane(wl.window, second, true);
    s.curw = wl;

    var client = T.Client{
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{ .screen = undefined },
        .session = s,
    };
    defer env_mod.environ_free(client.environ);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq_mod.CmdqItem{ .client = &client, .cmdlist = &list };
    var target: T.CmdFindState = .{};

    try std.testing.expectEqual(@as(i32, 0), cmd_find_target(&target, &item, null, .pane, 0));
    try std.testing.expectEqual(s, target.s.?);
    try std.testing.expectEqual(wl, target.wl.?);
    try std.testing.expectEqual(wl.window, target.w.?);
    try std.testing.expectEqual(second, target.wp.?);
}

test "cmd_find_target resolves session prefixes and patterns" {
    const cmd_mod = @import("cmd.zig");
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

    const alpha = sess.session_create(null, "alpha", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("alpha") != null) sess.session_destroy(alpha, false, "test");
    const beta = sess.session_create(null, "beta", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("beta") != null) sess.session_destroy(beta, false, "test");

    var cause: ?[]u8 = null;
    var alpha_ctx: T.SpawnContext = .{ .s = alpha, .idx = -1, .flags = T.SPAWN_EMPTY };
    const alpha_wl = spawn.spawn_window(&alpha_ctx, &cause).?;
    alpha.curw = alpha_wl;
    var beta_ctx: T.SpawnContext = .{ .s = beta, .idx = -1, .flags = T.SPAWN_EMPTY };
    const beta_wl = spawn.spawn_window(&beta_ctx, &cause).?;
    beta.curw = beta_wl;

    var client = T.Client{
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{ .screen = undefined },
        .session = alpha,
    };
    defer env_mod.environ_free(client.environ);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq_mod.CmdqItem{ .client = &client, .cmdlist = &list };
    var target: T.CmdFindState = .{};

    try std.testing.expectEqual(@as(i32, 0), cmd_find_target(&target, &item, "alp", .session, 0));
    try std.testing.expectEqual(alpha, target.s.?);
    try std.testing.expectEqual(@as(i32, 0), cmd_find_target(&target, &item, "b*", .session, 0));
    try std.testing.expectEqual(beta, target.s.?);
}

test "cmd_find_target resolves window names, last window, and window-index targets" {
    const cmd_mod = @import("cmd.zig");
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

    const s = sess.session_create(null, "find-window", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("find-window") != null) sess.session_destroy(s, false, "test");

    var cause: ?[]u8 = null;
    var first_ctx: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const wl0 = spawn.spawn_window(&first_ctx, &cause).?;
    xm.allocator.free(wl0.window.name);
    wl0.window.name = xm.xstrdup("editor");

    var second_ctx: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const wl1 = spawn.spawn_window(&second_ctx, &cause).?;
    xm.allocator.free(wl1.window.name);
    wl1.window.name = xm.xstrdup("logs");

    _ = sess.session_set_current(s, wl1);

    var client = T.Client{
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{ .screen = undefined },
        .session = s,
    };
    defer env_mod.environ_free(client.environ);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq_mod.CmdqItem{ .client = &client, .cmdlist = &list };
    var target: T.CmdFindState = .{};

    try std.testing.expectEqual(@as(i32, 0), cmd_find_target(&target, &item, "ed", .window, 0));
    try std.testing.expectEqual(wl0, target.wl.?);

    try std.testing.expectEqual(@as(i32, 0), cmd_find_target(&target, &item, "l*", .window, 0));
    try std.testing.expectEqual(wl1, target.wl.?);

    try std.testing.expectEqual(@as(i32, 0), cmd_find_target(&target, &item, "!", .window, 0));
    try std.testing.expectEqual(wl0, target.wl.?);

    try std.testing.expectEqual(@as(i32, 0), cmd_find_target(&target, &item, "find-window:5", .window, T.CMD_FIND_WINDOW_INDEX));
    try std.testing.expectEqual(s, target.s.?);
    try std.testing.expectEqual(@as(i32, 5), target.idx);
}

test "cmd_find_target resolves explicit pane indexes within a window" {
    const cmd_mod = @import("cmd.zig");
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

test "cmd_find_target resolves last pane in the current window" {
    const cmd_mod = @import("cmd.zig");
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

    const s = sess.session_create(null, "find-last-pane", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("find-last-pane") != null) sess.session_destroy(s, false, "test");

    var cause: ?[]u8 = null;
    var first_ctx: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const wl = spawn.spawn_window(&first_ctx, &cause).?;
    var second_ctx: T.SpawnContext = .{ .s = s, .wl = wl, .flags = T.SPAWN_EMPTY };
    const second = spawn.spawn_pane(&second_ctx, &cause).?;
    _ = win_mod.window_set_active_pane(wl.window, second, true);
    _ = win_mod.window_set_active_pane(wl.window, wl.window.panes.items[0], true);
    s.curw = wl;

    var client = T.Client{
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{ .screen = undefined },
        .session = s,
    };
    defer env_mod.environ_free(client.environ);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq_mod.CmdqItem{ .client = &client, .cmdlist = &list };
    var target: T.CmdFindState = .{};
    try std.testing.expectEqual(@as(i32, 0), cmd_find_target(&target, &item, "!", .pane, 0));
    try std.testing.expectEqual(second, target.wp.?);
}

test "cmd_find_target uses unattached inside-pane context to choose a session" {
    const cmd_mod = @import("cmd.zig");
    const spawn = @import("spawn.zig");

    sess.session_init_globals(xm.allocator);
    win_mod.window_init_globals(xm.allocator);
    client_registry.clients.clearRetainingCapacity();

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

    const pane_session = sess.session_create(null, "pane-session", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("pane-session") != null) sess.session_destroy(pane_session, false, "test");
    const newer_session = sess.session_create(null, "newer-session", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("newer-session") != null) sess.session_destroy(newer_session, false, "test");

    var cause: ?[]u8 = null;
    var pane_ctx: T.SpawnContext = .{ .s = pane_session, .idx = -1, .flags = T.SPAWN_EMPTY };
    const pane_wl = spawn.spawn_window(&pane_ctx, &cause).?;
    var current_ctx: T.SpawnContext = .{ .s = pane_session, .idx = -1, .flags = T.SPAWN_EMPTY };
    const current_wl = spawn.spawn_window(&current_ctx, &cause).?;
    pane_session.curw = current_wl;
    var newer_ctx: T.SpawnContext = .{ .s = newer_session, .idx = -1, .flags = T.SPAWN_EMPTY };
    _ = spawn.spawn_window(&newer_ctx, &cause).?;

    pane_wl.window.panes.items[0].fd = 7;
    defer pane_wl.window.panes.items[0].fd = -1;
    @memset(&pane_wl.window.panes.items[0].tty_name, 0);
    const tty = "/tmp/inside-pane-tty";
    @memcpy(pane_wl.window.panes.items[0].tty_name[0..tty.len], tty);

    const client_env = env_mod.environ_create();
    defer env_mod.environ_free(client_env);
    var client = T.Client{
        .environ = client_env,
        .tty = undefined,
        .status = .{ .screen = undefined },
        .ttyname = xm.xstrdup(tty),
    };
    defer xm.allocator.free(client.ttyname.?);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq_mod.CmdqItem{ .client = &client, .cmdlist = &list };
    var target: T.CmdFindState = .{};

    try std.testing.expectEqual(@as(i32, 0), cmd_find_target(&target, &item, null, .pane, 0));
    try std.testing.expectEqual(pane_session, target.s.?);
    try std.testing.expectEqual(current_wl, target.wl.?);
    try std.testing.expectEqual(current_wl.window.active.?, target.wp.?);
}

test "cmd_find_target uses TMUX_PANE for unattached clients without tty matches" {
    const cmd_mod = @import("cmd.zig");
    const spawn = @import("spawn.zig");

    sess.session_init_globals(xm.allocator);
    win_mod.window_init_globals(xm.allocator);
    client_registry.clients.clearRetainingCapacity();

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

    const s = sess.session_create(null, "tmux-pane-session", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("tmux-pane-session") != null) sess.session_destroy(s, false, "test");

    var cause: ?[]u8 = null;
    var ctx: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const wl = spawn.spawn_window(&ctx, &cause).?;
    s.curw = wl;

    const client_env = env_mod.environ_create();
    defer env_mod.environ_free(client_env);
    const pane_id = try std.fmt.allocPrint(xm.allocator, "%{d}", .{wl.window.panes.items[0].id});
    defer xm.allocator.free(pane_id);
    env_mod.environ_set(client_env, "TMUX_PANE", 0, pane_id);

    var client = T.Client{
        .environ = client_env,
        .tty = undefined,
        .status = .{ .screen = undefined },
    };

    var list: cmd_mod.CmdList = .{};
    var item = cmdq_mod.CmdqItem{ .client = &client, .cmdlist = &list };
    var target: T.CmdFindState = .{};

    try std.testing.expectEqual(@as(i32, 0), cmd_find_target(&target, &item, null, .pane, 0));
    try std.testing.expectEqual(s, target.s.?);
    try std.testing.expectEqual(wl.window.active.?, target.wp.?);
}

test "cmd_find_current_client prefers attached clients in the inside-pane session" {
    const cmd_mod = @import("cmd.zig");
    const spawn = @import("spawn.zig");

    sess.session_init_globals(xm.allocator);
    win_mod.window_init_globals(xm.allocator);
    client_registry.clients.clearRetainingCapacity();

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

    const s = sess.session_create(null, "client-session", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("client-session") != null) sess.session_destroy(s, false, "test");
    s.attached = 2;
    const other = sess.session_create(null, "other-session", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("other-session") != null) sess.session_destroy(other, false, "test");
    other.attached = 1;

    var cause: ?[]u8 = null;
    var ctx: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const wl = spawn.spawn_window(&ctx, &cause).?;
    s.curw = wl;
    wl.window.panes.items[0].fd = 9;
    defer wl.window.panes.items[0].fd = -1;
    @memset(&wl.window.panes.items[0].tty_name, 0);
    const tty = "/tmp/current-client-tty";
    @memcpy(wl.window.panes.items[0].tty_name[0..tty.len], tty);

    const attached_old_env = env_mod.environ_create();
    defer env_mod.environ_free(attached_old_env);
    var attached_old = T.Client{
        .id = 1,
        .environ = attached_old_env,
        .tty = undefined,
        .status = .{ .screen = undefined },
        .session = s,
    };
    const attached_new_env = env_mod.environ_create();
    defer env_mod.environ_free(attached_new_env);
    var attached_new = T.Client{
        .id = 2,
        .environ = attached_new_env,
        .tty = undefined,
        .status = .{ .screen = undefined },
        .session = s,
    };
    const other_env = env_mod.environ_create();
    defer env_mod.environ_free(other_env);
    var other_client = T.Client{
        .id = 3,
        .environ = other_env,
        .tty = undefined,
        .status = .{ .screen = undefined },
        .session = other,
    };

    client_registry.add(&attached_old);
    client_registry.add(&attached_new);
    client_registry.add(&other_client);
    defer client_registry.clients.clearRetainingCapacity();

    const query_env = env_mod.environ_create();
    defer env_mod.environ_free(query_env);
    var query_client = T.Client{
        .environ = query_env,
        .tty = undefined,
        .status = .{ .screen = undefined },
        .ttyname = xm.xstrdup(tty),
    };
    defer xm.allocator.free(query_client.ttyname.?);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq_mod.CmdqItem{ .client = &query_client, .cmdlist = &list };

    try std.testing.expectEqual(&attached_new, cmd_find_current_client(&item, false).?);
    try std.testing.expectEqual(&attached_new, cmd_find_client(&item, null, false).?);
}

test "cmd_find_current_client prefers higher activity over client id" {
    const opts_mod = @import("options.zig");
    const spawn = @import("spawn.zig");

    sess.session_init_globals(xm.allocator);
    win_mod.window_init_globals(xm.allocator);
    client_registry.clients.clearRetainingCapacity();

    opts_mod.global_options = opts_mod.options_create(null);
    defer opts_mod.options_free(opts_mod.global_options);
    opts_mod.global_s_options = opts_mod.options_create(null);
    defer opts_mod.options_free(opts_mod.global_s_options);
    opts_mod.global_w_options = opts_mod.options_create(null);
    defer opts_mod.options_free(opts_mod.global_w_options);
    opts_mod.options_default_all(opts_mod.global_options, T.OPTIONS_TABLE_SERVER);
    opts_mod.options_default_all(opts_mod.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts_mod.options_default_all(opts_mod.global_w_options, T.OPTIONS_TABLE_WINDOW);

    env_mod.global_environ = env_mod.environ_create();
    defer env_mod.environ_free(env_mod.global_environ);

    const s = sess.session_create(null, "activity-client-session", "/", env_mod.environ_create(), opts_mod.options_create(opts_mod.global_s_options), null);
    defer if (sess.session_find("activity-client-session") != null) sess.session_destroy(s, false, "test");
    s.attached = 2;

    var cause: ?[]u8 = null;
    var ctx: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const wl = spawn.spawn_window(&ctx, &cause).?;
    s.curw = wl;

    const old_env = env_mod.environ_create();
    defer env_mod.environ_free(old_env);
    var older_id_newer_activity = T.Client{
        .id = 1,
        .activity_time = 200,
        .environ = old_env,
        .tty = undefined,
        .status = .{ .screen = undefined },
        .session = s,
    };
    const new_env = env_mod.environ_create();
    defer env_mod.environ_free(new_env);
    var newer_id_older_activity = T.Client{
        .id = 9,
        .activity_time = 100,
        .environ = new_env,
        .tty = undefined,
        .status = .{ .screen = undefined },
        .session = s,
    };

    client_registry.add(&newer_id_older_activity);
    client_registry.add(&older_id_newer_activity);
    defer client_registry.clients.clearRetainingCapacity();

    try std.testing.expectEqual(&older_id_newer_activity, cmd_find_current_client(null, false).?);
    try std.testing.expectEqual(&older_id_newer_activity, cmd_find_client(null, null, false).?);
}

test "cmd_find_target prefers unattached session for shared window ids" {
    const cmd_mod = @import("cmd.zig");
    const opts_mod = @import("options.zig");
    const spawn = @import("spawn.zig");

    sess.session_init_globals(xm.allocator);
    win_mod.window_init_globals(xm.allocator);

    opts_mod.global_options = opts_mod.options_create(null);
    defer opts_mod.options_free(opts_mod.global_options);
    opts_mod.global_s_options = opts_mod.options_create(null);
    defer opts_mod.options_free(opts_mod.global_s_options);
    opts_mod.global_w_options = opts_mod.options_create(null);
    defer opts_mod.options_free(opts_mod.global_w_options);
    opts_mod.options_default_all(opts_mod.global_options, T.OPTIONS_TABLE_SERVER);
    opts_mod.options_default_all(opts_mod.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts_mod.options_default_all(opts_mod.global_w_options, T.OPTIONS_TABLE_WINDOW);

    env_mod.global_environ = env_mod.environ_create();
    defer env_mod.environ_free(env_mod.global_environ);

    const attached = sess.session_create(null, "shared-window-attached", "/", env_mod.environ_create(), opts_mod.options_create(opts_mod.global_s_options), null);
    defer if (sess.session_find("shared-window-attached") != null) sess.session_destroy(attached, false, "test");
    const unattached = sess.session_create(null, "shared-window-unattached", "/", env_mod.environ_create(), opts_mod.options_create(opts_mod.global_s_options), null);
    defer if (sess.session_find("shared-window-unattached") != null) sess.session_destroy(unattached, false, "test");

    var cause: ?[]u8 = null;
    var attached_ctx: T.SpawnContext = .{ .s = attached, .idx = -1, .flags = T.SPAWN_EMPTY };
    const attached_wl = spawn.spawn_window(&attached_ctx, &cause).?;
    attached.curw = attached_wl;
    attached.attached = 1;
    attached.activity_time = 500;

    const unattached_wl = sess.session_attach(unattached, attached_wl.window, -1, &cause).?;
    unattached.curw = unattached_wl;
    unattached.attached = 0;
    unattached.activity_time = 100;

    const query_env = env_mod.environ_create();
    defer env_mod.environ_free(query_env);
    var query_client = T.Client{
        .environ = query_env,
        .tty = undefined,
        .status = .{ .screen = undefined },
        .session = attached,
    };

    var list: cmd_mod.CmdList = .{};
    var item = cmdq_mod.CmdqItem{ .client = &query_client, .cmdlist = &list };
    var target: T.CmdFindState = .{};
    const window_id = try std.fmt.allocPrint(xm.allocator, "@{d}", .{attached_wl.window.id});
    defer xm.allocator.free(window_id);

    try std.testing.expectEqual(@as(i32, 0), cmd_find_target(&target, &item, window_id, .window, T.CMD_FIND_PREFER_UNATTACHED));
    try std.testing.expectEqual(unattached, target.s.?);
    try std.testing.expectEqual(unattached_wl, target.wl.?);
    try std.testing.expectEqual(attached_wl.window.active.?, target.wp.?);
}

test "cmd_find_target resolves {mouse} through the shared mouse runtime state" {
    const cmd_mod = @import("cmd.zig");
    const opts_mod = @import("options.zig");
    const spawn = @import("spawn.zig");

    sess.session_init_globals(xm.allocator);
    win_mod.window_init_globals(xm.allocator);

    opts_mod.global_options = opts_mod.options_create(null);
    defer opts_mod.options_free(opts_mod.global_options);
    opts_mod.global_s_options = opts_mod.options_create(null);
    defer opts_mod.options_free(opts_mod.global_s_options);
    opts_mod.global_w_options = opts_mod.options_create(null);
    defer opts_mod.options_free(opts_mod.global_w_options);
    opts_mod.options_default_all(opts_mod.global_options, T.OPTIONS_TABLE_SERVER);
    opts_mod.options_default_all(opts_mod.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts_mod.options_default_all(opts_mod.global_w_options, T.OPTIONS_TABLE_WINDOW);

    env_mod.global_environ = env_mod.environ_create();
    defer env_mod.environ_free(env_mod.global_environ);

    const s = sess.session_create(null, "mouse-target", "/", env_mod.environ_create(), opts_mod.options_create(opts_mod.global_s_options), null);
    defer if (sess.session_find("mouse-target") != null) sess.session_destroy(s, false, "test");

    var cause: ?[]u8 = null;
    var spawn_ctx: T.SpawnContext = .{ .s = s, .idx = -1, .flags = T.SPAWN_EMPTY };
    const wl = spawn.spawn_window(&spawn_ctx, &cause).?;
    s.curw = wl;
    const wp = wl.window.active.?;

    const query_env = env_mod.environ_create();
    defer env_mod.environ_free(query_env);
    var query_client = T.Client{
        .environ = query_env,
        .tty = undefined,
        .status = .{ .screen = undefined },
        .session = s,
    };

    var list: cmd_mod.CmdList = .{};
    var item = cmdq_mod.CmdqItem{ .client = &query_client, .cmdlist = &list };
    item.event.m = .{
        .valid = true,
        .key = T.keycMouse(T.KEYC_MOUSEDOWN1, .status),
        .s = @intCast(s.id),
        .w = @intCast(wl.window.id),
        .wp = @intCast(wp.id),
    };

    var target: T.CmdFindState = .{};
    try std.testing.expectEqual(@as(i32, 0), cmd_find_target(&target, &item, "{mouse}", .pane, 0));
    try std.testing.expectEqual(s, target.s.?);
    try std.testing.expectEqual(wl, target.wl.?);
    try std.testing.expectEqual(wp, target.wp.?);
}
