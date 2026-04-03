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
const c = @import("c.zig");
const xm = @import("xmalloc.zig");
const log = @import("log.zig");
const opts = @import("options.zig");
const env_mod = @import("environ.zig");
const grid = @import("grid.zig");
const sort_mod = @import("sort.zig");
const win = @import("window.zig");
const marked_pane_mod = @import("marked-pane.zig");
const notify = @import("notify.zig");
const proc_mod = @import("proc.zig");
const utf8 = @import("utf8.zig");

// ── Global state ──────────────────────────────────────────────────────────

pub var sessions: std.StringHashMap(*T.Session) = undefined;
pub var session_groups: std.StringHashMap(*T.SessionGroup) = undefined;
var next_session_id: u32 = 0;

/// Call once at server startup.
pub fn session_init_globals(alloc: std.mem.Allocator) void {
    sessions = std.StringHashMap(*T.Session).init(alloc);
    session_groups = std.StringHashMap(*T.SessionGroup).init(alloc);
    next_session_id = 0;
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

pub fn session_group_count(sg: *T.SessionGroup) u32 {
    return @intCast(sg.sessions.items.len);
}

pub fn session_group_attached_count(sg: *T.SessionGroup) u32 {
    var count: u32 = 0;
    for (sg.sessions.items) |member|
        count += member.attached;
    return count;
}

pub fn session_next_id_peek() u32 {
    return next_session_id;
}

pub fn session_group_add(sg: *T.SessionGroup, s: *T.Session) void {
    if (session_group_contains(s) != null) return;
    sg.sessions.append(xm.allocator, s) catch unreachable;
}

pub fn session_group_synchronize_to(s: *T.Session) void {
    const sg = session_group_contains(s) orelse return;

    for (sg.sessions.items) |target| {
        if (target == s) continue;
        session_group_synchronize1(target, s);
        return;
    }
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
        const new_wl = session_attach_internal(s, target_wl.window, idx, &cause, false) orelse unreachable;
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

// ── Comparison ────────────────────────────────────────────────────────────

/// Compare two sessions by name (mirrors tmux session_cmp for RB tree).
pub fn session_cmp(s1: *T.Session, s2: *T.Session) std.math.Order {
    return std.mem.order(u8, s1.name, s2.name);
}

/// Compare two session groups by name (mirrors tmux session_group_cmp).
pub fn session_group_cmp(sg1: *T.SessionGroup, sg2: *T.SessionGroup) std.math.Order {
    return std.mem.order(u8, sg1.name, sg2.name);
}

// ── Reference counting ───────────────────────────────────────────────────

/// Add a reference to a session.
pub fn session_add_ref(s: *T.Session, from: []const u8) void {
    s.references += 1;
    log.log_debug("session_add_ref: {s} {s}, now {d}", .{ s.name, from, s.references });
}

/// Remove a reference from a session.  When the count reaches zero the
/// session is freed.  In tmux this schedules an event_once callback;
/// here we call session_free directly.
pub fn session_remove_ref(s: *T.Session, from: []const u8) void {
    s.references -= 1;
    log.log_debug("session_remove_ref: {s} {s}, now {d}", .{ s.name, from, s.references });

    if (s.references == 0)
        session_free(s);
}

/// Free a session whose reference count has reached zero.
/// In tmux this is a static libevent callback triggered via event_once.
fn session_free(s: *T.Session) void {
    log.log_debug("session {s} freed ({d} references)", .{ s.name, s.references });

    if (s.references == 0) {
        env_mod.environ_free(s.environ);
        opts.options_free(s.options);
        xm.allocator.free(s.name);
        xm.allocator.destroy(s);
    }
}

// ── Creation / destruction ────────────────────────────────────────────────

pub fn session_create(
    prefix: ?[]const u8,
    name: ?[]const u8,
    cwd: []const u8,
    environment: *T.Environ,
    oo: *T.Options,
    _tio: ?*anyopaque,
) *T.Session {
    _ = _tio;

    const s = xm.allocator.create(T.Session) catch unreachable;
    const now = std.time.milliTimestamp();

    s.* = T.Session{
        .id = 0,
        .name = undefined,
        .cwd = xm.xstrdup(cwd),
        .created = now,
        .activity_time = now,
        .windows = std.AutoHashMap(i32, *T.Winlink).init(xm.allocator),
        .options = oo,
        .environ = environment,
    };

    if (name) |explicit_name| {
        s.id = next_session_id;
        next_session_id += 1;
        s.name = xm.xstrdup(explicit_name);
    } else {
        while (true) {
            s.id = next_session_id;
            next_session_id += 1;

            const generated_name = if (prefix) |name_prefix|
                xm.xasprintf("{s}-{d}", .{ name_prefix, s.id })
            else
                xm.xasprintf("{d}", .{s.id});

            if (sessions.get(generated_name) == null) {
                s.name = generated_name;
                break;
            }
            xm.allocator.free(generated_name);
        }
    }

    sessions.put(s.name, s) catch unreachable;
    log.log_debug("new session $%{d} {s}", .{ s.id, s.name });
    return s;
}

pub fn session_update_activity(s: *T.Session, from: ?i64) void {
    s.activity_time = from orelse std.time.milliTimestamp();

    // Reset the lock-after-time inactivity timer.
    if (s.lock_timer) |ev|
        _ = c.libevent.event_del(ev);

    const base = proc_mod.libevent orelse return;
    if (s.lock_timer == null) {
        s.lock_timer = c.libevent.event_new(
            base,
            -1,
            @intCast(c.libevent.EV_TIMEOUT),
            session_lock_timer_cb,
            s,
        );
    }
    const ev = s.lock_timer orelse return;
    if (s.attached != 0) {
        const lock_after: i64 = opts.options_get_number(s.options, "lock-after-time");
        if (lock_after != 0) {
            var tv = std.posix.timeval{ .sec = @intCast(lock_after), .usec = 0 };
            _ = c.libevent.event_add(ev, @ptrCast(&tv));
        }
    }
}

/// Libevent timer callback: lock a session after inactivity.
export fn session_lock_timer_cb(_fd: c_int, _events: c_short, arg: ?*anyopaque) void {
    _ = _fd;
    _ = _events;
    const s: *T.Session = @ptrCast(@alignCast(arg orelse return));

    if (s.attached == 0)
        return;

    log.log_debug("session {s} locked, activity time {d}", .{ s.name, s.activity_time });

    @import("server-fn.zig").server_lock_session(s);
    @import("resize.zig").recalculate_sizes();
}

pub fn session_theme_changed(s: ?*T.Session) void {
    const session = s orelse return;

    var it = session.windows.valueIterator();
    while (it.next()) |wl| {
        for (wl.*.window.panes.items) |wp|
            wp.flags |= T.PANE_THEMECHANGED;
    }
}

/// Update history-limit for every pane in the session, trimming excess
/// scrollback where necessary.  Mirrors tmux session_update_history.
pub fn session_update_history(s: *T.Session) void {
    const limit: u32 = @intCast(opts.options_get_number(s.options, "history-limit"));
    var it = s.windows.valueIterator();
    while (it.next()) |wl| {
        for (wl.*.window.panes.items) |wp| {
            const gd = wp.base.grid;
            const osize = gd.hsize;
            gd.hlimit = limit;
            grid.grid_collect_history(gd, true);
            if (gd.hsize != osize) {
                log.log_debug("session_update_history: %%{d} {d} -> {d}", .{
                    wp.id, osize, gd.hsize,
                });
            }
        }
    }
}

pub fn session_destroy(s: *T.Session, do_notify: bool, from: []const u8) void {
    log.log_debug("destroy session $%{d} {s} ({s})", .{ s.id, s.name, from });

    _ = sessions.remove(s.name);
    if (do_notify)
        notify.notify_session("session-closed", s);

    if (s.lock_timer) |ev| {
        _ = c.libevent.event_del(ev);
        c.libevent.event_free(ev);
        s.lock_timer = null;
    }

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
    xm.allocator.free(@constCast(s.cwd));

    // Drop the creation reference.  session_free runs when refcount
    // reaches zero — notifications may still hold refs that keep the
    // session alive until they are processed or the queue is cleared.
    session_remove_ref(s, "session_destroy");
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
    return session_attach_internal(s, w, idx, cause, true);
}

fn session_attach_internal(
    s: *T.Session,
    w: *T.Window,
    idx: i32,
    cause: *?[]u8,
    synchronize_group: bool,
) ?*T.Winlink {
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
    if (synchronize_group)
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
    const old = s.curw;
    if (old) |o| {
        session_remove_lastw_reference(s, o);
        s.lastw.insert(xm.allocator, 0, o) catch unreachable;
    }
    s.curw = wl;
    if (opts.options_ready and
        opts.options_get_number(opts.global_options, "focus-events") != 0)
    {
        if (old) |o| win.window_update_focus(o.window);
        win.window_update_focus(wl.window);
    }
    notify.notify_session("session-window-changed", s);
    return true;
}

pub fn session_detach_index(s: *T.Session, idx: i32, from: []const u8) bool {
    if (s.windows.fetchRemove(idx)) |kv| {
        const wl = kv.value;
        marked_pane_mod.clear_if_winlink(wl);
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

/// Return true if a window is linked outside this session (not including
/// session groups).  The window must belong to this session.
pub fn session_is_linked(s: *T.Session, w: *T.Window) bool {
    if (session_group_contains(s)) |sg| {
        return w.references != session_group_count(sg);
    }
    return w.references != 1;
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

pub fn winlink_shuffle_up(s: *T.Session, wl: ?*T.Winlink, before: bool) i32 {
    const target = wl orelse return -1;
    const limit = std.math.maxInt(i32);

    const idx = if (before) target.idx else blk: {
        if (target.idx == limit) return -1;
        break :blk target.idx + 1;
    };

    var last = idx;
    while (last < limit and s.windows.contains(last)) : (last += 1) {}
    if (last == limit) return -1;

    while (last > idx) : (last -= 1) {
        const moving = winlink_find_by_index(&s.windows, last - 1) orelse unreachable;
        _ = s.windows.remove(last - 1);
        moving.idx += 1;
        s.windows.put(last, moving) catch unreachable;
    }

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
    if (marked_pane_mod.marked_pane.s == s and marked_pane_mod.marked_pane.wl != null)
        marked_pane_mod.marked_pane.idx = marked_pane_mod.marked_pane.wl.?.idx;
}

pub fn session_first_winlink(s: *T.Session) ?*T.Winlink {
    var best: ?*T.Winlink = null;
    var it = s.windows.valueIterator();
    while (it.next()) |wl| {
        if (best == null or wl.*.idx < best.?.idx) best = wl.*;
    }
    return best;
}

fn session_last_winlink(s: *T.Session) ?*T.Winlink {
    var best: ?*T.Winlink = null;
    var it = s.windows.valueIterator();
    while (it.next()) |wl| {
        if (best == null or wl.*.idx > best.?.idx) best = wl.*;
    }
    return best;
}

fn session_next_alert(wl: ?*T.Winlink, s: *T.Session) ?*T.Winlink {
    var next = wl;
    while (next) |candidate| {
        if (session_has_live_winlink_ptr(s, candidate) and candidate.flags & T.WINLINK_ALERTFLAGS != 0)
            return candidate;

        var best: ?*T.Winlink = null;
        var it = s.windows.valueIterator();
        while (it.next()) |entry| {
            const current = entry.*;
            if (current.idx <= candidate.idx) continue;
            if (best == null or current.idx < best.?.idx) best = current;
        }
        next = best;
    }
    return null;
}

fn session_previous_alert(wl: ?*T.Winlink, s: *T.Session) ?*T.Winlink {
    var previous = wl;
    while (previous) |candidate| {
        if (session_has_live_winlink_ptr(s, candidate) and candidate.flags & T.WINLINK_ALERTFLAGS != 0)
            return candidate;

        var best: ?*T.Winlink = null;
        var it = s.windows.valueIterator();
        while (it.next()) |entry| {
            const current = entry.*;
            if (current.idx >= candidate.idx) continue;
            if (best == null or current.idx > best.?.idx) best = current;
        }
        previous = best;
    }
    return null;
}

pub fn session_get_by_name(name: []const u8) ?*T.Session {
    return sessions.get(name);
}

pub fn session_next(s: *T.Session, alert: bool) bool {
    session_repair_current(s);
    const current = s.curw orelse return false;

    var next = blk: {
        var best: ?*T.Winlink = null;
        var it = s.windows.valueIterator();
        while (it.next()) |wl| {
            const candidate = wl.*;
            if (candidate.idx <= current.idx) continue;
            if (best == null or candidate.idx < best.?.idx) best = candidate;
        }
        break :blk best;
    };
    if (alert) next = session_next_alert(next, s);
    if (next == null) {
        next = session_first_winlink(s);
        if (alert) next = session_next_alert(next, s);
    }

    return session_set_current(s, next orelse return false);
}

pub fn session_previous(s: *T.Session, alert: bool) bool {
    session_repair_current(s);
    const current = s.curw orelse return false;

    var previous = blk: {
        var best: ?*T.Winlink = null;
        var it = s.windows.valueIterator();
        while (it.next()) |wl| {
            const candidate = wl.*;
            if (candidate.idx >= current.idx) continue;
            if (best == null or candidate.idx > best.?.idx) best = candidate;
        }
        break :blk best;
    };
    if (alert) previous = session_previous_alert(previous, s);
    if (previous == null) {
        previous = session_last_winlink(s);
        if (alert) previous = session_previous_alert(previous, s);
    }

    return session_set_current(s, previous orelse return false);
}

pub fn session_select(s: *T.Session, idx: i32) bool {
    return session_set_current(s, winlink_find_by_index(&s.windows, idx) orelse return false);
}

pub fn session_last(s: *T.Session) bool {
    session_repair_current(s);
    return session_set_current(s, if (s.lastw.items.len > 0) s.lastw.items[0] else return false);
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
    const cmdq = @import("cmd-queue.zig");
    cmdq.cmdq_reset_for_tests();
    defer cmdq.cmdq_reset_for_tests();
    session_init_globals(xm.allocator);

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

test "session_next_session and session_previous_session wrap in name order" {
    const cmdq = @import("cmd-queue.zig");
    const opts_mod = @import("options.zig");

    cmdq.cmdq_reset_for_tests();
    defer cmdq.cmdq_reset_for_tests();
    session_init_globals(xm.allocator);

    opts_mod.global_options = opts_mod.options_create(null);
    defer opts_mod.options_free(opts_mod.global_options);
    opts_mod.global_s_options = opts_mod.options_create(null);
    defer opts_mod.options_free(opts_mod.global_s_options);
    opts_mod.global_w_options = opts_mod.options_create(null);
    defer opts_mod.options_free(opts_mod.global_w_options);
    opts_mod.options_default_all(opts_mod.global_options, T.OPTIONS_TABLE_SERVER);
    opts_mod.options_default_all(opts_mod.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts_mod.options_default_all(opts_mod.global_w_options, T.OPTIONS_TABLE_WINDOW);

    const sa = session_create(null, "aa-nextprev", "/", env_mod.environ_create(), opts_mod.options_create(opts_mod.global_s_options), null);
    defer if (session_find("aa-nextprev") != null) session_destroy(sa, false, "test");
    const sb = session_create(null, "bb-nextprev", "/", env_mod.environ_create(), opts_mod.options_create(opts_mod.global_s_options), null);
    defer if (session_find("bb-nextprev") != null) session_destroy(sb, false, "test");

    var sort_crit = T.SortCriteria{ .order = .name, .reversed = false };
    try std.testing.expectEqual(sb, session_next_session(sa, &sort_crit).?);
    try std.testing.expectEqual(sb, session_previous_session(sa, &sort_crit).?);
    try std.testing.expectEqual(sa, session_next_session(sb, &sort_crit).?);
    try std.testing.expectEqual(sa, session_previous_session(sb, &sort_crit).?);
}

