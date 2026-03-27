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
// Ported in part from tmux/session.c.
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
const win = @import("window.zig");
const notify = @import("notify.zig");
const utf8 = @import("utf8.zig");

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
        for (sg.*.sessions.items) |member| {
            if (member == s) return sg.*;
        }
    }
    return null;
}

pub fn session_group_new(name: []const u8) *T.SessionGroup {
    if (session_group_find(name)) |sg| return sg;

    const sg = xm.allocator.create(T.SessionGroup) catch unreachable;
    sg.* = .{
        .name = xm.xstrdup(name),
    };
    session_groups.put(sg.name, sg) catch unreachable;
    return sg;
}

pub fn session_group_add(sg: *T.SessionGroup, s: *T.Session) void {
    if (session_group_contains(s) != null) return;
    sg.sessions.append(xm.allocator, s) catch unreachable;
}

fn session_group_remove(s: *T.Session) void {
    const sg = session_group_contains(s) orelse return;

    var i: usize = 0;
    while (i < sg.sessions.items.len) : (i += 1) {
        if (sg.sessions.items[i] == s) {
            _ = sg.sessions.orderedRemove(i);
            break;
        }
    }

    if (sg.sessions.items.len == 0) {
        _ = session_groups.remove(sg.name);
        xm.allocator.free(sg.name);
        sg.sessions.deinit(xm.allocator);
        xm.allocator.destroy(sg);
    }
}

pub fn session_group_synchronize_from(target: *T.Session) void {
    const sg = session_group_contains(target) orelse return;

    for (sg.sessions.items) |s| {
        if (s != target)
            session_group_synchronize1(target, s);
    }
}

fn session_group_synchronize1(target: *T.Session, s: *T.Session) void {
    if (target.windows.count() == 0) return;

    const old_current_idx = if (s.curw) |wl| wl.idx else null;
    const target_current_idx = if (target.curw) |wl| wl.idx else null;

    var old_lastw_indices: std.ArrayList(i32) = .{};
    defer old_lastw_indices.deinit(xm.allocator);
    for (s.lastw.items) |wl| {
        if (session_has_live_winlink_ptr(s, wl))
            old_lastw_indices.append(xm.allocator, wl.idx) catch unreachable;
    }

    var old_indices: std.ArrayList(i32) = .{};
    defer old_indices.deinit(xm.allocator);
    var old_it = s.windows.keyIterator();
    while (old_it.next()) |idx|
        old_indices.append(xm.allocator, idx.*) catch unreachable;

    for (old_indices.items) |idx|
        _ = session_detach_index(s, idx, "session_group_synchronize1");

    var target_indices: std.ArrayList(i32) = .{};
    defer target_indices.deinit(xm.allocator);
    var target_it = target.windows.keyIterator();
    while (target_it.next()) |idx|
        target_indices.append(xm.allocator, idx.*) catch unreachable;
    std.sort.block(i32, target_indices.items, {}, std.sort.asc(i32));

    for (target_indices.items) |idx| {
        const target_wl = winlink_find_by_index(&target.windows, idx) orelse continue;
        var cause: ?[]u8 = null;
        const new_wl = session_attach(s, target_wl.window, idx, &cause) orelse unreachable;
        new_wl.flags |= target_wl.flags & T.WINLINK_ALERTFLAGS;
    }

    if (old_current_idx) |idx| {
        s.curw = winlink_find_by_index(&s.windows, idx);
    } else if (target_current_idx) |idx| {
        s.curw = winlink_find_by_index(&s.windows, idx);
    } else {
        s.curw = session_first_winlink(s);
    }

    s.lastw.clearRetainingCapacity();
    for (old_lastw_indices.items) |idx| {
        const wl = winlink_find_by_index(&s.windows, idx) orelse continue;
        if (s.curw != null and s.curw.? == wl) continue;

        var duplicate = false;
        for (s.lastw.items) |existing| {
            if (existing == wl) {
                duplicate = true;
                break;
            }
        }
        if (!duplicate)
            s.lastw.append(xm.allocator, wl) catch unreachable;
    }
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
    const now = std.time.milliTimestamp();

    s.* = T.Session{
        .id = sid,
        .name = actual_name,
        .cwd = xm.xstrdup(cwd),
        .created = now,
        .activity_time = now,
        .windows = std.AutoHashMap(i32, *T.Winlink).init(xm.allocator),
        .options = oo,
        .environ = environment,
    };

    sessions.put(s.name, s) catch unreachable;
    log.log_debug("new session $%{d} {s}", .{ s.id, s.name });
    notify.notify_session("session-created", s);
    return s;
}

pub fn session_update_activity(s: *T.Session, from: ?i64) void {
    s.activity_time = from orelse std.time.milliTimestamp();
}

pub fn session_destroy(s: *T.Session, _notify: bool, _from: []const u8) void {
    _ = _notify;
    _ = _from;
    log.log_debug("destroy session $%{d} {s}", .{ s.id, s.name });
    _ = sessions.remove(s.name);
    notify.notify_session("session-closed", s);
    session_group_remove(s);

    var window_counts = std.AutoHashMap(*T.Window, u32).init(xm.allocator);
    defer window_counts.deinit();

    var wit = s.windows.valueIterator();
    while (wit.next()) |wl| {
        const gop = window_counts.getOrPut(wl.*.window) catch unreachable;
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += 1;
    }

    var wcit = window_counts.iterator();
    while (wcit.next()) |entry| {
        const w = entry.key_ptr.*;
        const count = entry.value_ptr.*;
        if (w.references == count) win.window_destroy_all_panes(w);
    }

    var indices: std.ArrayList(i32) = .{};
    defer indices.deinit(xm.allocator);
    var kit = s.windows.keyIterator();
    while (kit.next()) |idx| indices.append(xm.allocator, idx.*) catch unreachable;
    for (indices.items) |idx| {
        _ = session_detach_index(s, idx, "session_destroy");
    }

    s.lastw.deinit(xm.allocator);
    s.windows.deinit();
    opts.options_free(s.options);
    env_mod.environ_free(s.environ);
    xm.allocator.free(s.name);
    xm.allocator.free(@constCast(s.cwd));
    xm.allocator.destroy(s);
}

/// Check a proposed session name for validity.  Returns null if invalid.
pub fn session_check_name(name: []const u8) ?[]u8 {
    if (name.len == 0) return null;
    const copy = xm.xstrdup(name);
    defer xm.allocator.free(copy);
    for (copy) |*ch| {
        if (ch.* == ':' or ch.* == '.') ch.* = '_';
    }
    return utf8.utf8_stravis(copy, utf8.VIS_OCTAL | utf8.VIS_CSTYLE | utf8.VIS_TAB | utf8.VIS_NL);
}

// ── Winlink management ────────────────────────────────────────────────────

pub fn winlink_find_by_index(wwl: *std.AutoHashMap(i32, *T.Winlink), idx: i32) ?*T.Winlink {
    return wwl.get(idx);
}

pub fn winlink_find_by_window(wwl: *std.AutoHashMap(i32, *T.Winlink), w: *T.Window) ?*T.Winlink {
    var it = wwl.valueIterator();
    while (it.next()) |wl| {
        if (wl.*.window == w) return wl.*;
    }
    return null;
}

fn window_add_winlink(w: *T.Window, wl: *T.Winlink) void {
    w.winlinks.append(xm.allocator, wl) catch unreachable;
}

fn window_remove_winlink(w: *T.Window, wl: *T.Winlink) void {
    var i: usize = 0;
    while (i < w.winlinks.items.len) : (i += 1) {
        if (w.winlinks.items[i] == wl) {
            _ = w.winlinks.orderedRemove(i);
            return;
        }
    }
}

pub fn session_rebind_winlink(wl: *T.Winlink, w: *T.Window) void {
    if (wl.window == w) return;
    window_remove_winlink(wl.window, wl);
    wl.window = w;
    window_add_winlink(w, wl);
}

/// Add a window to a session at the given index (or next free index).
pub fn session_attach(s: *T.Session, w: *T.Window, idx: i32, cause: *?[]u8) ?*T.Winlink {
    _ = cause;
    const actual_idx = if (idx == -1) blk: {
        break :blk session_next_index(s);
    } else idx;

    const wl = xm.allocator.create(T.Winlink) catch unreachable;
    wl.* = .{ .idx = actual_idx, .session = s, .window = w };
    s.windows.put(actual_idx, wl) catch unreachable;
    window_add_winlink(w, wl);
    w.references += 1;
    notify.notify_session_window("window-linked", s, w);
    session_group_synchronize_from(s);
    return wl;
}

pub fn session_detach(s: *T.Session, wl: ?*T.Winlink) bool {
    const live = wl orelse return false;
    if (!session_detach_index(s, live.idx, "session_detach")) return false;
    session_group_synchronize_from(s);
    return s.windows.count() == 0;
}

fn session_has_live_winlink_ptr(s: *T.Session, candidate: *T.Winlink) bool {
    var it = s.windows.valueIterator();
    while (it.next()) |wl| {
        if (wl.* == candidate) return true;
    }
    return false;
}

fn session_remove_lastw_reference(s: *T.Session, target: *T.Winlink) void {
    var i: usize = 0;
    while (i < s.lastw.items.len) {
        if (s.lastw.items[i] == target) {
            _ = s.lastw.orderedRemove(i);
        } else {
            i += 1;
        }
    }
}

fn session_prune_lastw(s: *T.Session) void {
    var i: usize = 0;
    while (i < s.lastw.items.len) {
        const candidate = s.lastw.items[i];
        if (!session_has_live_winlink_ptr(s, candidate) or (s.curw != null and s.curw.? == candidate)) {
            _ = s.lastw.orderedRemove(i);
            continue;
        }
        var j: usize = 0;
        var duplicate = false;
        while (j < i) : (j += 1) {
            if (s.lastw.items[j] == candidate) {
                duplicate = true;
                break;
            }
        }
        if (duplicate) {
            _ = s.lastw.orderedRemove(i);
            continue;
        }
        i += 1;
    }
}

pub fn session_repair_current(s: *T.Session) void {
    if (s.curw) |current| {
        if (!session_has_live_winlink_ptr(s, current))
            s.curw = null;
    }
    session_prune_lastw(s);
    if (s.curw == null)
        s.curw = if (s.lastw.items.len > 0) s.lastw.items[0] else session_first_winlink(s);
    if (s.curw) |current|
        session_remove_lastw_reference(s, current);
}

pub fn session_set_current(s: *T.Session, wl: *T.Winlink) bool {
    session_repair_current(s);
    if (!session_has_live_winlink_ptr(s, wl)) return false;
    if (s.curw == wl) return true;
    session_remove_lastw_reference(s, wl);
    if (s.curw) |old| {
        session_remove_lastw_reference(s, old);
        s.lastw.insert(xm.allocator, 0, old) catch unreachable;
    }
    s.curw = wl;
    return true;
}

pub fn session_detach_index(s: *T.Session, idx: i32, from: []const u8) bool {
    if (s.windows.fetchRemove(idx)) |kv| {
        const wl = kv.value;
        if (s.curw == wl) s.curw = null;
        session_remove_lastw_reference(s, wl);
        window_remove_winlink(wl.window, wl);
        notify.notify_session_window("window-unlinked", s, wl.window);
        win.window_remove_ref(wl.window, from);
        xm.allocator.destroy(wl);
        session_repair_current(s);
        return true;
    }
    return false;
}

pub fn session_has_window(s: *T.Session, w: *T.Window) bool {
    return winlink_find_by_window(&s.windows, w) != null;
}

pub fn session_window_link_count(w: *T.Window) u32 {
    var count: u32 = 0;
    var sit = sessions.valueIterator();
    while (sit.next()) |s| {
        var wit = s.*.windows.valueIterator();
        while (wit.next()) |wl| {
            if (wl.*.window == w) count += 1;
        }
    }
    return count;
}

pub fn session_next_index(s: *T.Session) i32 {
    var idx: i32 = @intCast(opts.options_get_number(s.options, "base-index"));
    while (s.windows.contains(idx)) idx += 1;
    return idx;
}

pub fn session_renumber_windows(s: *T.Session) void {
    const RenumberEntry = struct {
        old_idx: i32,
        current: bool,
        wl: *T.Winlink,
    };

    const old_current_idx = if (s.curw) |wl| wl.idx else -1;
    var entries: std.ArrayList(RenumberEntry) = .{};
    defer entries.deinit(xm.allocator);

    var it = s.windows.valueIterator();
    while (it.next()) |wl| {
        entries.append(xm.allocator, .{
            .old_idx = wl.*.idx,
            .current = wl.*.idx == old_current_idx,
            .wl = wl.*,
        }) catch unreachable;
    }
    std.sort.block(RenumberEntry, entries.items, {}, struct {
        fn less(_: void, a: RenumberEntry, b: RenumberEntry) bool {
            return a.old_idx < b.old_idx;
        }
    }.less);

    var new_windows = std.AutoHashMap(i32, *T.Winlink).init(xm.allocator);
    var next_idx: i32 = @intCast(opts.options_get_number(s.options, "base-index"));
    var new_current_idx: ?i32 = null;
    for (entries.items) |entry| {
        entry.wl.idx = next_idx;
        new_windows.put(next_idx, entry.wl) catch unreachable;
        if (entry.current) new_current_idx = next_idx;
        next_idx += 1;
    }

    s.windows.deinit();
    s.windows = new_windows;
    s.curw = if (new_current_idx) |idx| s.windows.get(idx) else session_first_winlink(s);
    session_prune_lastw(s);
}

pub fn session_first_winlink(s: *T.Session) ?*T.Winlink {
    var best: ?*T.Winlink = null;
    var it = s.windows.valueIterator();
    while (it.next()) |wl| {
        if (best == null or wl.*.idx < best.?.idx) best = wl.*;
    }
    return best;
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

test "session_set_current maintains last-window history" {
    var s = T.Session{
        .id = 1,
        .name = xm.xstrdup("session-history"),
        .cwd = "",
        .windows = std.AutoHashMap(i32, *T.Winlink).init(xm.allocator),
        .options = undefined,
        .environ = undefined,
    };
    defer {
        var it = s.windows.valueIterator();
        while (it.next()) |wl| xm.allocator.destroy(wl.*);
        s.windows.deinit();
        s.lastw.deinit(xm.allocator);
        xm.allocator.free(s.name);
    }

    const w1 = xm.allocator.create(T.Window) catch unreachable;
    const w2 = xm.allocator.create(T.Window) catch unreachable;
    defer xm.allocator.destroy(w1);
    defer xm.allocator.destroy(w2);
    w1.* = .{ .id = 1, .name = xm.xstrdup("one"), .sx = 80, .sy = 24, .options = undefined };
    w2.* = .{ .id = 2, .name = xm.xstrdup("two"), .sx = 80, .sy = 24, .options = undefined };
    defer xm.allocator.free(w1.name);
    defer xm.allocator.free(w2.name);
    defer w1.panes.deinit(xm.allocator);
    defer w1.last_panes.deinit(xm.allocator);
    defer w1.winlinks.deinit(xm.allocator);
    defer w2.panes.deinit(xm.allocator);
    defer w2.last_panes.deinit(xm.allocator);
    defer w2.winlinks.deinit(xm.allocator);

    const wl1 = xm.allocator.create(T.Winlink) catch unreachable;
    const wl2 = xm.allocator.create(T.Winlink) catch unreachable;
    wl1.* = .{ .idx = 0, .session = &s, .window = w1 };
    wl2.* = .{ .idx = 1, .session = &s, .window = w2 };
    s.windows.put(0, wl1) catch unreachable;
    s.windows.put(1, wl2) catch unreachable;
    s.curw = wl1;

    try std.testing.expect(session_set_current(&s, wl2));
    try std.testing.expectEqual(wl2, s.curw.?);
    try std.testing.expectEqual(@as(usize, 1), s.lastw.items.len);
    try std.testing.expectEqual(wl1, s.lastw.items[0]);

    try std.testing.expect(session_set_current(&s, wl1));
    try std.testing.expectEqual(wl1, s.curw.?);
    try std.testing.expectEqual(@as(usize, 1), s.lastw.items.len);
    try std.testing.expectEqual(wl2, s.lastw.items[0]);
}

test "session_repair_current drops non-live winlinks" {
    var s = T.Session{
        .id = 2,
        .name = xm.xstrdup("session-repair"),
        .cwd = "",
        .windows = std.AutoHashMap(i32, *T.Winlink).init(xm.allocator),
        .options = undefined,
        .environ = undefined,
    };
    defer {
        var it = s.windows.valueIterator();
        while (it.next()) |wl| xm.allocator.destroy(wl.*);
        s.windows.deinit();
        s.lastw.deinit(xm.allocator);
        xm.allocator.free(s.name);
    }

    const w = xm.allocator.create(T.Window) catch unreachable;
    defer xm.allocator.destroy(w);
    w.* = .{ .id = 3, .name = xm.xstrdup("live"), .sx = 80, .sy = 24, .options = undefined };
    defer xm.allocator.free(w.name);
    defer w.panes.deinit(xm.allocator);
    defer w.last_panes.deinit(xm.allocator);
    defer w.winlinks.deinit(xm.allocator);

    const live = xm.allocator.create(T.Winlink) catch unreachable;
    const stale = xm.allocator.create(T.Winlink) catch unreachable;
    defer xm.allocator.destroy(stale);
    live.* = .{ .idx = 0, .session = &s, .window = w };
    stale.* = .{ .idx = 9, .session = &s, .window = w };
    s.windows.put(0, live) catch unreachable;
    s.curw = stale;
    s.lastw.append(xm.allocator, stale) catch unreachable;
    s.lastw.append(xm.allocator, live) catch unreachable;

    session_repair_current(&s);
    try std.testing.expectEqual(live, s.curw.?);
    try std.testing.expectEqual(@as(usize, 0), s.lastw.items.len);
}

test "session_check_name sanitizes separators and escapes controls" {
    const checked = session_check_name("bad:name.\n") orelse return error.TestUnexpectedResult;
    defer xm.allocator.free(checked);

    try std.testing.expectEqualStrings("bad_name_\\n", checked);
}
