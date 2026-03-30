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
// Ported from tmux/sort.c
// Original copyright:
//   Copyright (c) 2026 Dane Jensen <dhcjensen@gmail.com>
//   ISC licence – same terms as above.

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const key_bindings = @import("key-bindings.zig");
const paste_mod = @import("paste.zig");
const sess = @import("session.zig");
const registry = @import("client-registry.zig");

pub fn sort_order_from_string(order: ?[]const u8) T.SortOrder {
    if (order) |value| {
        if (std.ascii.eqlIgnoreCase(value, "activity")) return .activity;
        if (std.ascii.eqlIgnoreCase(value, "creation")) return .creation;
        if (std.ascii.eqlIgnoreCase(value, "index") or std.ascii.eqlIgnoreCase(value, "key")) return .index;
        if (std.ascii.eqlIgnoreCase(value, "modifier")) return .modifier;
        if (std.ascii.eqlIgnoreCase(value, "name") or std.ascii.eqlIgnoreCase(value, "title")) return .name;
        if (std.ascii.eqlIgnoreCase(value, "order")) return .order;
        if (std.ascii.eqlIgnoreCase(value, "size")) return .size;
    }
    return .end;
}

pub fn sort_order_to_string(order: T.SortOrder) ?[]const u8 {
    return switch (order) {
        .activity => "activity",
        .creation => "creation",
        .index => "index",
        .modifier => "modifier",
        .name => "name",
        .order => "order",
        .size => "size",
        .end => null,
    };
}

pub fn sorted_sessions(sort_crit: T.SortCriteria) []*T.Session {
    var list: std.ArrayList(*T.Session) = .{};
    var it = sess.sessions.valueIterator();
    while (it.next()) |entry| list.append(xm.allocator, entry.*) catch unreachable;

    const items = list.toOwnedSlice(xm.allocator) catch unreachable;
    sort_sessions_in_place(items, sort_crit);
    return items;
}

pub fn sorted_winlinks_session(s: *T.Session, sort_crit: T.SortCriteria) []*T.Winlink {
    var list: std.ArrayList(*T.Winlink) = .{};
    var it = s.windows.valueIterator();
    while (it.next()) |entry| list.append(xm.allocator, entry.*) catch unreachable;

    const items = list.toOwnedSlice(xm.allocator) catch unreachable;
    sort_winlinks_in_place(items, sort_crit);
    return items;
}

pub fn sorted_winlinks(sort_crit: T.SortCriteria) []*T.Winlink {
    var list: std.ArrayList(*T.Winlink) = .{};
    var sit = sess.sessions.valueIterator();
    while (sit.next()) |s| {
        var wit = s.*.windows.valueIterator();
        while (wit.next()) |wl| list.append(xm.allocator, wl.*) catch unreachable;
    }

    const items = list.toOwnedSlice(xm.allocator) catch unreachable;
    sort_winlinks_in_place(items, sort_crit);
    return items;
}

/// All panes in all windows of all sessions (tmux `sort_get_panes`).
pub fn sorted_panes(sort_crit: T.SortCriteria) []*T.WindowPane {
    var list: std.ArrayList(*T.WindowPane) = .{};
    var sit = sess.sessions.valueIterator();
    while (sit.next()) |sp| {
        var wit = sp.*.windows.valueIterator();
        while (wit.next()) |wl| {
            for (wl.*.window.panes.items) |wp| {
                list.append(xm.allocator, wp) catch unreachable;
            }
        }
    }
    const items = list.toOwnedSlice(xm.allocator) catch unreachable;
    sort_panes_in_place(items, sort_crit);
    return items;
}

/// All panes in all windows of one session (tmux `sort_get_panes_session`).
pub fn sorted_panes_session(s: *T.Session, sort_crit: T.SortCriteria) []*T.WindowPane {
    var list: std.ArrayList(*T.WindowPane) = .{};
    var wit = s.windows.valueIterator();
    while (wit.next()) |wl| {
        for (wl.*.window.panes.items) |wp| {
            list.append(xm.allocator, wp) catch unreachable;
        }
    }
    const items = list.toOwnedSlice(xm.allocator) catch unreachable;
    sort_panes_in_place(items, sort_crit);
    return items;
}

pub fn sorted_panes_window(w: *T.Window, sort_crit: T.SortCriteria) []*T.WindowPane {
    const items = xm.allocator.alloc(*T.WindowPane, w.panes.items.len) catch unreachable;
    @memcpy(items, w.panes.items);
    sort_panes_in_place(items, sort_crit);
    return items;
}

pub fn sorted_clients(sort_crit: T.SortCriteria) []*T.Client {
    const items = xm.allocator.alloc(*T.Client, registry.clients.items.len) catch unreachable;
    @memcpy(items, registry.clients.items);
    sort_clients_in_place(items, sort_crit);
    return items;
}

pub fn sorted_buffers(sort_crit: T.SortCriteria) []*paste_mod.PasteBuffer {
    var list: std.ArrayList(*paste_mod.PasteBuffer) = .{};
    var pb = paste_mod.paste_walk(null);
    while (pb) |current| : (pb = paste_mod.paste_walk(current)) {
        list.append(xm.allocator, current) catch unreachable;
    }

    const items = list.toOwnedSlice(xm.allocator) catch unreachable;
    sort_buffers_in_place(items, sort_crit);
    return items;
}

pub fn sorted_key_bindings(sort_crit: T.SortCriteria) []*T.KeyBinding {
    var list: std.ArrayList(*T.KeyBinding) = .{};
    var table = key_bindings.key_bindings_first_table();
    while (table) |current| : (table = key_bindings.key_bindings_next_table(current)) {
        var binding = key_bindings.key_bindings_first(current);
        while (binding) |entry| : (binding = key_bindings.key_bindings_next(current, entry)) {
            list.append(xm.allocator, entry) catch unreachable;
        }
    }

    const items = list.toOwnedSlice(xm.allocator) catch unreachable;
    sort_key_bindings_in_place(items, sort_crit);
    return items;
}

pub fn sorted_key_bindings_table(table: *T.KeyTable, sort_crit: T.SortCriteria) []*T.KeyBinding {
    var list: std.ArrayList(*T.KeyBinding) = .{};
    var binding = key_bindings.key_bindings_first(table);
    while (binding) |entry| : (binding = key_bindings.key_bindings_next(table, entry)) {
        list.append(xm.allocator, entry) catch unreachable;
    }

    const items = list.toOwnedSlice(xm.allocator) catch unreachable;
    sort_key_bindings_in_place(items, sort_crit);
    return items;
}

/// tmux `window_tree_order_seq` — used with `sort_next_order` in tree mode.
pub const window_tree_sort_order_seq: []const T.SortOrder = &.{ .index, .name, .activity };

/// tmux `window_buffer_order_seq`.
pub const window_buffer_sort_order_seq: []const T.SortOrder = &.{ .creation, .name, .size };

/// tmux `window_client_order_seq`.
pub const window_client_sort_order_seq: []const T.SortOrder = &.{ .name, .size, .creation, .activity };

/// Cycle `sort_crit.order` through `sort_crit.order_seq` (tmux `sort_next_order`).
pub fn sort_next_order(sort_crit: *T.SortCriteria) void {
    const seq = sort_crit.order_seq orelse return;
    if (seq.len == 0) return;

    var i: usize = 0;
    while (i < seq.len) : (i += 1) {
        if (seq[i] == sort_crit.order) break;
    }
    if (i >= seq.len) {
        i = 0;
    } else {
        i += 1;
        if (i >= seq.len) i = 0;
    }
    sort_crit.order = seq[i];
}

/// True when tree window swap should be refused (tmux `sort_would_window_tree_swap`).
pub fn sort_would_window_tree_swap(sort_crit: T.SortCriteria, wla: *T.Winlink, wlb: *T.Winlink) bool {
    if (sort_crit.order == .index) return false;
    return compare_winlink(wla, wlb, sort_crit.order) != .eq;
}

/// tmux `sort_qsort`: no sort if `.end`; if `.order`, only optional reverse; else block sort.
pub fn sort_qsort(
    comptime Elem: type,
    items: []Elem,
    sort_crit: T.SortCriteria,
    comptime Ctx: type,
    ctx: Ctx,
    lessThan: fn (Ctx, Elem, Elem) bool,
) void {
    if (sort_crit.order == .end) return;
    if (sort_crit.order == .order) {
        if (sort_crit.reversed) reverse_slice(Elem, items);
        return;
    }
    std.sort.block(Elem, items, ctx, lessThan);
}

/// tmux `sort_get_sessions` — fills `out_n` and returns an allocated slice (caller frees with `xm.allocator`).
pub fn sort_get_sessions(out_n: *usize, sort_crit: T.SortCriteria) []*T.Session {
    const items = sorted_sessions(sort_crit);
    out_n.* = items.len;
    return items;
}

pub fn sort_get_winlinks(out_n: *usize, sort_crit: T.SortCriteria) []*T.Winlink {
    const items = sorted_winlinks(sort_crit);
    out_n.* = items.len;
    return items;
}

pub fn sort_get_winlinks_session(s: *T.Session, out_n: *usize, sort_crit: T.SortCriteria) []*T.Winlink {
    const items = sorted_winlinks_session(s, sort_crit);
    out_n.* = items.len;
    return items;
}

pub fn sort_get_panes(out_n: *usize, sort_crit: T.SortCriteria) []*T.WindowPane {
    const items = sorted_panes(sort_crit);
    out_n.* = items.len;
    return items;
}

pub fn sort_get_panes_session(s: *T.Session, out_n: *usize, sort_crit: T.SortCriteria) []*T.WindowPane {
    const items = sorted_panes_session(s, sort_crit);
    out_n.* = items.len;
    return items;
}

pub fn sort_get_panes_window(w: *T.Window, out_n: *usize, sort_crit: T.SortCriteria) []*T.WindowPane {
    const items = sorted_panes_window(w, sort_crit);
    out_n.* = items.len;
    return items;
}

pub fn sort_get_clients(out_n: *usize, sort_crit: T.SortCriteria) []*T.Client {
    const items = sorted_clients(sort_crit);
    out_n.* = items.len;
    return items;
}

pub fn sort_get_buffers(out_n: *usize, sort_crit: T.SortCriteria) []*paste_mod.PasteBuffer {
    const items = sorted_buffers(sort_crit);
    out_n.* = items.len;
    return items;
}

pub fn sort_get_key_bindings(out_n: *usize, sort_crit: T.SortCriteria) []*T.KeyBinding {
    const items = sorted_key_bindings(sort_crit);
    out_n.* = items.len;
    return items;
}

pub fn sort_get_key_bindings_table(table: *T.KeyTable, out_n: *usize, sort_crit: T.SortCriteria) []*T.KeyBinding {
    const items = sorted_key_bindings_table(table, sort_crit);
    out_n.* = items.len;
    return items;
}

fn sort_sessions_in_place(items: []*T.Session, sort_crit: T.SortCriteria) void {
    if (sort_crit.order == .end) return;
    if (sort_crit.order == .order) {
        if (sort_crit.reversed) reverse_slice(*T.Session, items);
        return;
    }
    std.sort.block(*T.Session, items, SortContext{ .order = sort_crit.order, .reversed = sort_crit.reversed }, session_less_than);
}

fn sort_winlinks_in_place(items: []*T.Winlink, sort_crit: T.SortCriteria) void {
    if (sort_crit.order == .end) return;
    if (sort_crit.order == .order) {
        if (sort_crit.reversed) reverse_slice(*T.Winlink, items);
        return;
    }
    std.sort.block(*T.Winlink, items, SortContext{ .order = sort_crit.order, .reversed = sort_crit.reversed }, winlink_less_than);
}

fn sort_panes_in_place(items: []*T.WindowPane, sort_crit: T.SortCriteria) void {
    if (sort_crit.order == .end) return;
    if (sort_crit.order == .order) {
        if (sort_crit.reversed) reverse_slice(*T.WindowPane, items);
        return;
    }
    std.sort.block(*T.WindowPane, items, SortContext{ .order = sort_crit.order, .reversed = sort_crit.reversed }, pane_less_than);
}

fn sort_clients_in_place(items: []*T.Client, sort_crit: T.SortCriteria) void {
    if (sort_crit.order == .end) return;
    if (sort_crit.order == .order) {
        if (sort_crit.reversed) reverse_slice(*T.Client, items);
        return;
    }
    std.sort.block(*T.Client, items, SortContext{ .order = sort_crit.order, .reversed = sort_crit.reversed }, client_less_than);
}

fn sort_buffers_in_place(items: []*paste_mod.PasteBuffer, sort_crit: T.SortCriteria) void {
    if (sort_crit.order == .end) return;
    if (sort_crit.order == .order) {
        if (sort_crit.reversed) reverse_slice(*paste_mod.PasteBuffer, items);
        return;
    }
    std.sort.block(*paste_mod.PasteBuffer, items, SortContext{ .order = sort_crit.order, .reversed = sort_crit.reversed }, buffer_less_than);
}

fn sort_key_bindings_in_place(items: []*T.KeyBinding, sort_crit: T.SortCriteria) void {
    if (sort_crit.order == .end) return;
    if (sort_crit.order == .order) {
        if (sort_crit.reversed) reverse_slice(*T.KeyBinding, items);
        return;
    }
    std.sort.block(*T.KeyBinding, items, SortContext{ .order = sort_crit.order, .reversed = sort_crit.reversed }, key_binding_less_than);
}

const SortContext = struct {
    order: T.SortOrder,
    reversed: bool,
};

fn session_less_than(ctx: SortContext, a: *T.Session, b: *T.Session) bool {
    return order_to_less(compare_session(a, b, ctx.order), ctx.reversed);
}

fn winlink_less_than(ctx: SortContext, a: *T.Winlink, b: *T.Winlink) bool {
    return order_to_less(compare_winlink(a, b, ctx.order), ctx.reversed);
}

fn pane_less_than(ctx: SortContext, a: *T.WindowPane, b: *T.WindowPane) bool {
    return order_to_less(compare_pane(a, b, ctx.order), ctx.reversed);
}

fn client_less_than(ctx: SortContext, a: *T.Client, b: *T.Client) bool {
    return order_to_less(compare_client(a, b, ctx.order), ctx.reversed);
}

fn buffer_less_than(ctx: SortContext, a: *paste_mod.PasteBuffer, b: *paste_mod.PasteBuffer) bool {
    return order_to_less(compare_buffer(a, b, ctx.order), ctx.reversed);
}

fn key_binding_less_than(ctx: SortContext, a: *T.KeyBinding, b: *T.KeyBinding) bool {
    return order_to_less(compare_key_binding(a, b, ctx.order), ctx.reversed);
}

fn order_to_less(order: std.math.Order, reversed: bool) bool {
    return if (reversed) order == .gt else order == .lt;
}

fn activity_newer_first(ta: i64, tb: i64) std.math.Order {
    if (ta > tb) return .lt;
    if (ta < tb) return .gt;
    return .eq;
}

fn compare_session(a: *T.Session, b: *T.Session, order: T.SortOrder) std.math.Order {
    const primary = switch (order) {
        .index => std.math.order(a.id, b.id),
        .creation => std.math.order(a.created, b.created),
        .activity => activity_newer_first(a.activity_time, b.activity_time),
        .name => std.mem.order(u8, a.name, b.name),
        else => std.math.Order.eq,
    };
    if (primary != .eq) return primary;
    return std.mem.order(u8, a.name, b.name);
}

fn compare_winlink(a: *T.Winlink, b: *T.Winlink, order: T.SortOrder) std.math.Order {
    const primary = switch (order) {
        .index => std.math.order(a.idx, b.idx),
        // tmux uses window creation_time (newer first); zmux has no per-window time yet — higher id first.
        .creation => std.math.order(b.window.id, a.window.id),
        .activity => std.math.Order.eq,
        .name => std.mem.order(u8, a.window.name, b.window.name),
        .size => std.math.order(window_area(a.window), window_area(b.window)),
        else => std.math.Order.eq,
    };
    if (primary != .eq) return primary;
    return std.mem.order(u8, a.window.name, b.window.name);
}

fn compare_pane(a: *T.WindowPane, b: *T.WindowPane, order: T.SortOrder) std.math.Order {
    const primary = switch (order) {
        .activity => std.math.order(a.active_point, b.active_point),
        .creation => std.math.order(a.id, b.id),
        .index => std.math.order(window_pane_index(a.window, a), window_pane_index(b.window, b)),
        .name => std.mem.order(u8, pane_title(a), pane_title(b)),
        .size => std.math.order(a.sx * a.sy, b.sx * b.sy),
        else => std.math.Order.eq,
    };
    if (primary != .eq) return primary;
    return std.mem.order(u8, pane_title(a), pane_title(b));
}

fn compare_client(a: *T.Client, b: *T.Client, order: T.SortOrder) std.math.Order {
    const primary = switch (order) {
        .creation => std.math.order(a.creation_time, b.creation_time),
        .activity => activity_newer_first(a.activity_time, b.activity_time),
        .name => std.mem.order(u8, client_name(a), client_name(b)),
        .size => blk: {
            const sx_cmp = std.math.order(a.tty.sx, b.tty.sx);
            if (sx_cmp != .eq) break :blk sx_cmp;
            break :blk std.math.order(a.tty.sy, b.tty.sy);
        },
        else => std.math.Order.eq,
    };
    if (primary != .eq) return primary;
    return std.mem.order(u8, client_name(a), client_name(b));
}

fn compare_buffer(a: *paste_mod.PasteBuffer, b: *paste_mod.PasteBuffer, order: T.SortOrder) std.math.Order {
    const primary = switch (order) {
        .creation => std.math.order(a.order, b.order),
        .name => std.mem.order(u8, a.name, b.name),
        .size => std.math.order(a.data.len, b.data.len),
        else => std.math.Order.eq,
    };
    if (primary != .eq) return primary;
    return std.mem.order(u8, a.name, b.name);
}

fn compare_key_binding(a: *T.KeyBinding, b: *T.KeyBinding, order: T.SortOrder) std.math.Order {
    const primary = switch (order) {
        .index => std.math.order(a.key, b.key),
        .modifier => blk: {
            const a_mod = a.key & T.KEYC_MASK_MODIFIERS;
            const b_mod = b.key & T.KEYC_MASK_MODIFIERS;
            const mod_cmp = std.math.order(a_mod, b_mod);
            if (mod_cmp != .eq) break :blk mod_cmp;
            break :blk std.math.order(a.key, b.key);
        },
        .name => ascii_order_ignore_case(a.tablename, b.tablename),
        else => std.math.Order.eq,
    };
    if (primary != .eq) return primary;

    const table_cmp = ascii_order_ignore_case(a.tablename, b.tablename);
    if (table_cmp != .eq) return table_cmp;
    return std.math.order(a.key, b.key);
}

fn window_area(w: *T.Window) u64 {
    return @as(u64, w.sx) * @as(u64, w.sy);
}

fn pane_title(wp: *T.WindowPane) []const u8 {
    return if (wp.screen.title) |title| title else "";
}

fn client_name(cl: *T.Client) []const u8 {
    if (cl.name) |name| return name;
    if (cl.ttyname) |ttyname| return ttyname;
    return "";
}

fn window_pane_index(w: *T.Window, wp: *T.WindowPane) u32 {
    for (w.panes.items, 0..) |pane, idx| {
        if (pane == wp) return @intCast(idx);
    }
    return std.math.maxInt(u32);
}

fn reverse_slice(comptime Item: type, items: []Item) void {
    if (items.len <= 1) return;
    var i: usize = 0;
    var j: usize = items.len - 1;
    while (i < j) : ({
        i += 1;
        j -= 1;
    }) {
        const tmp = items[i];
        items[i] = items[j];
        items[j] = tmp;
    }
}

fn ascii_order_ignore_case(a: []const u8, b: []const u8) std.math.Order {
    const limit = @min(a.len, b.len);
    var i: usize = 0;
    while (i < limit) : (i += 1) {
        const ac = std.ascii.toLower(a[i]);
        const bc = std.ascii.toLower(b[i]);
        if (ac < bc) return .lt;
        if (ac > bc) return .gt;
    }
    return std.math.order(a.len, b.len);
}

fn order_as_cmp_int(ord: std.math.Order, reversed: bool) i32 {
    const v: i32 = switch (ord) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    };
    return if (reversed) -v else v;
}

/// qsort-style comparison (tmux `sort_session_cmp`).
pub fn sort_session_cmp(sort_crit: T.SortCriteria, a: *T.Session, b: *T.Session) i32 {
    if (sort_crit.order == .end or sort_crit.order == .order) return 0;
    return order_as_cmp_int(compare_session(a, b, sort_crit.order), sort_crit.reversed);
}

pub fn sort_winlink_cmp(sort_crit: T.SortCriteria, a: *T.Winlink, b: *T.Winlink) i32 {
    if (sort_crit.order == .end or sort_crit.order == .order) return 0;
    return order_as_cmp_int(compare_winlink(a, b, sort_crit.order), sort_crit.reversed);
}

pub fn sort_pane_cmp(sort_crit: T.SortCriteria, a: *T.WindowPane, b: *T.WindowPane) i32 {
    if (sort_crit.order == .end or sort_crit.order == .order) return 0;
    return order_as_cmp_int(compare_pane(a, b, sort_crit.order), sort_crit.reversed);
}

pub fn sort_client_cmp(sort_crit: T.SortCriteria, a: *T.Client, b: *T.Client) i32 {
    if (sort_crit.order == .end or sort_crit.order == .order) return 0;
    return order_as_cmp_int(compare_client(a, b, sort_crit.order), sort_crit.reversed);
}

pub fn sort_buffer_cmp(sort_crit: T.SortCriteria, a: *paste_mod.PasteBuffer, b: *paste_mod.PasteBuffer) i32 {
    if (sort_crit.order == .end or sort_crit.order == .order) return 0;
    return order_as_cmp_int(compare_buffer(a, b, sort_crit.order), sort_crit.reversed);
}

pub fn sort_key_binding_cmp(sort_crit: T.SortCriteria, a: *T.KeyBinding, b: *T.KeyBinding) i32 {
    if (sort_crit.order == .end or sort_crit.order == .order) return 0;
    return order_as_cmp_int(compare_key_binding(a, b, sort_crit.order), sort_crit.reversed);
}

test "sort_order_from_string parses aliases" {
    try std.testing.expectEqual(T.SortOrder.index, sort_order_from_string("key"));
    try std.testing.expectEqual(T.SortOrder.name, sort_order_from_string("title"));
    try std.testing.expectEqual(T.SortOrder.end, sort_order_from_string("mystery"));
}

test "sort_next_order cycles order_seq" {
    var crit: T.SortCriteria = .{
        .order = .index,
        .order_seq = &.{ .index, .name, .activity },
    };
    sort_next_order(&crit);
    try std.testing.expectEqual(T.SortOrder.name, crit.order);
    sort_next_order(&crit);
    try std.testing.expectEqual(T.SortOrder.activity, crit.order);
    sort_next_order(&crit);
    try std.testing.expectEqual(T.SortOrder.index, crit.order);
}

test "sorted_buffers preserves walk order and supports creation sort" {
    paste_mod.paste_reset_for_tests();

    var cause: ?[]u8 = null;
    try std.testing.expectEqual(@as(i32, 0), paste_mod.paste_set(xm.xstrdup("bbb"), "beta", &cause));
    try std.testing.expectEqual(@as(i32, 0), paste_mod.paste_set(xm.xstrdup("a"), "alpha", &cause));
    try std.testing.expectEqual(@as(i32, 0), paste_mod.paste_set(xm.xstrdup("cccc"), "gamma", &cause));

    const natural = sorted_buffers(.{});
    defer xm.allocator.free(natural);
    try std.testing.expectEqualStrings("gamma", natural[0].name);
    try std.testing.expectEqualStrings("alpha", natural[1].name);
    try std.testing.expectEqualStrings("beta", natural[2].name);

    const by_creation = sorted_buffers(.{ .order = .creation });
    defer xm.allocator.free(by_creation);
    try std.testing.expectEqualStrings("beta", by_creation[0].name);
    try std.testing.expectEqualStrings("alpha", by_creation[1].name);
    try std.testing.expectEqualStrings("gamma", by_creation[2].name);
}

test "sorted_key_bindings_table supports index modifier and order views" {
    key_bindings.key_bindings_init();
    key_bindings.key_bindings_add("scratch", T.KEYC_CTRL | 'b', null, false, null);
    key_bindings.key_bindings_add("scratch", T.KEYC_SHIFT | T.KEYC_LEFT, null, false, null);
    key_bindings.key_bindings_add("scratch", 'z', null, false, null);
    const scratch = key_bindings.key_bindings_get_table("scratch", false).?;

    const index_sorted = sorted_key_bindings_table(scratch, .{ .order = .index });
    defer xm.allocator.free(index_sorted);
    try std.testing.expectEqual(@as(T.key_code, 'z'), index_sorted[0].key);

    const modifier_sorted = sorted_key_bindings_table(scratch, .{ .order = .modifier });
    defer xm.allocator.free(modifier_sorted);
    try std.testing.expectEqual(@as(T.key_code, 'z'), modifier_sorted[0].key);
    try std.testing.expect(modifier_sorted[2].key & T.KEYC_SHIFT != 0);

    const ordered = sorted_key_bindings_table(scratch, .{ .order = .order });
    defer xm.allocator.free(ordered);
    try std.testing.expectEqual(@as(T.key_code, T.KEYC_CTRL | 'b'), ordered[0].key);
    try std.testing.expectEqual(@as(T.key_code, T.KEYC_SHIFT | T.KEYC_LEFT), ordered[1].key);
    try std.testing.expectEqual(@as(T.key_code, 'z'), ordered[2].key);
}
