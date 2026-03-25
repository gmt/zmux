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
// Ported from tmux/session.c
// Original copyright:
//   Copyright (c) 2007 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

//! session.zig – session lifecycle and management.

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const log = @import("log.zig");
const opts = @import("options.zig");
const env_mod = @import("environ.zig");
const sort_mod = @import("sort.zig");

// ── Global state ──────────────────────────────────────────────────────────

pub var sessions: std.StringHashMap(*T.Session) = undefined;
pub var session_groups: std.StringHashMap(*T.SessionGroup) = undefined;
var next_session_id: u32 = 0;

/// Call once at server startup.
pub fn session_init_globals(alloc: std.mem.Allocator) void {
    sessions = std.StringHashMap(*T.Session).init(alloc);
    session_groups = std.StringHashMap(*T.SessionGroup).init(alloc);
}

// ── Lookup ────────────────────────────────────────────────────────────────

pub fn session_alive(s: *T.Session) bool {
    var it = sessions.valueIterator();
    while (it.next()) |v| {
        if (v.* == s) return true;
    }
    return false;
}

pub fn session_find(name: []const u8) ?*T.Session {
    return sessions.get(name);
}

pub fn session_find_by_id(id: u32) ?*T.Session {
    var it = sessions.valueIterator();
    while (it.next()) |v| {
        if (v.*.id == id) return v.*;
    }
    return null;
}

pub fn session_find_by_id_str(s: []const u8) ?*T.Session {
    if (s.len == 0 or s[0] != '$') return null;
    const id = std.fmt.parseUnsigned(u32, s[1..], 10) catch return null;
    return session_find_by_id(id);
}

// ── Session groups ────────────────────────────────────────────────────────

pub fn session_group_find(name: []const u8) ?*T.SessionGroup {
    return session_groups.get(name);
}

pub fn session_group_contains(s: *T.Session) ?*T.SessionGroup {
    var it = session_groups.valueIterator();
    while (it.next()) |sg| {
        var sit = sg.*.sessions.first;
        while (sit) |node| : (sit = node.next) {
            if (node.data == s) return sg.*;
        }
    }
    return null;
}

// ── Creation / destruction ────────────────────────────────────────────────

pub fn session_create(
    _prefix: ?[]const u8,
    name: ?[]const u8,
    cwd: []const u8,
    environment: *T.Environ,
    oo: *T.Options,
    _tio: ?*anyopaque,
) *T.Session {
    _ = _prefix;
    _ = _tio;

    const s = xm.allocator.create(T.Session) catch unreachable;
    const sid = next_session_id;
    next_session_id += 1;

    const actual_name = if (name) |n| xm.xstrdup(n) else xm.xasprintf("{d}", .{sid});

    s.* = T.Session{
        .id = sid,
        .name = actual_name,
        .cwd = xm.xstrdup(cwd),
        .windows = std.AutoHashMap(i32, T.Winlink).init(xm.allocator),
        .options = oo,
        .environ = environment,
    };

    sessions.put(s.name, s) catch unreachable;
    log.log_debug("new session $%{d} {s}", .{ s.id, s.name });
    return s;
}

pub fn session_destroy(s: *T.Session, _notify: bool, _from: []const u8) void {
    _ = _notify;
    _ = _from;
    log.log_debug("destroy session $%{d} {s}", .{ s.id, s.name });
    _ = sessions.remove(s.name);

    // Kill all pane processes in all windows
    var wit = s.windows.valueIterator();
    while (wit.next()) |wl| {
        for (wl.window.panes.items) |wp| {
            if (wp.pid > 0) {
                log.log_debug("killing pane pid {d}", .{wp.pid});
                _ = std.c.kill(wp.pid, std.posix.SIG.HUP);
                _ = std.c.kill(wp.pid, std.posix.SIG.TERM);
            }
        }
    }

    s.windows.deinit();
    xm.allocator.free(s.name);
    xm.allocator.free(@constCast(s.cwd));
    xm.allocator.destroy(s);
}

/// Check a proposed session name for validity.  Returns null if invalid.
pub fn session_check_name(name: []const u8) ?[]u8 {
    if (name.len == 0) return null;
    for (name) |ch| {
        if (ch == ':' or ch == '.') return null;
    }
    return xm.xstrdup(name);
}

// ── Winlink management ────────────────────────────────────────────────────

pub fn winlink_find_by_index(wwl: *std.AutoHashMap(i32, T.Winlink), idx: i32) ?*T.Winlink {
    return wwl.getPtr(idx);
}

pub fn winlink_find_by_window(wwl: *std.AutoHashMap(i32, T.Winlink), w: *T.Window) ?*T.Winlink {
    var it = wwl.valueIterator();
    while (it.next()) |wl| {
        if (wl.window == w) return wl;
    }
    return null;
}

/// Add a window to a session at the given index (or next free index).
pub fn session_attach(s: *T.Session, w: *T.Window, idx: i32, cause: *?[]u8) ?*T.Winlink {
    _ = cause;
    const actual_idx = if (idx == -1) blk: {
        var i: i32 = 0;
        while (s.windows.contains(i)) i += 1;
        break :blk i;
    } else idx;

    const wl = T.Winlink{ .idx = actual_idx, .session = s, .window = w };
    s.windows.put(actual_idx, wl) catch unreachable;
    w.references += 1;
    return s.windows.getPtr(actual_idx);
}

pub fn session_detach(_s: *T.Session, _wl: ?*T.Winlink) void {
    _ = _s;
    _ = _wl;
    // TODO: implement full detach logic
}

pub fn session_has_window(s: *T.Session, w: *T.Window) bool {
    return winlink_find_by_window(&s.windows, w) != null;
}

pub fn session_get_by_name(name: []const u8) ?*T.Session {
    return sessions.get(name);
}

pub fn session_next_session(
    s: *T.Session,
    sort_crit: ?*const T.SortCriteria,
) ?*T.Session {
    const sorted = sort_mod.sorted_sessions(if (sort_crit) |crit| crit.* else .{});
    defer xm.allocator.free(sorted);

    for (sorted, 0..) |entry, idx| {
        if (entry != s) continue;
        return sorted[(idx + 1) % sorted.len];
    }
    return null;
}

pub fn session_previous_session(
    s: *T.Session,
    sort_crit: ?*const T.SortCriteria,
) ?*T.Session {
    const sorted = sort_mod.sorted_sessions(if (sort_crit) |crit| crit.* else .{});
    defer xm.allocator.free(sorted);

    for (sorted, 0..) |entry, idx| {
        if (entry != s) continue;
        return sorted[(idx + sorted.len - 1) % sorted.len];
    }
    return null;
}
