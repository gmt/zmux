// Copyright (c) 2026 Greg Turner <gmt@pobox.com>
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
const sess = @import("session.zig");
const srv = @import("server.zig");

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
    while (it.next()) |entry| list.append(xm.allocator, entry) catch unreachable;

    const items = list.toOwnedSlice(xm.allocator) catch unreachable;
    sort_winlinks_in_place(items, sort_crit, .index);
    return items;
}

pub fn sorted_winlinks(sort_crit: T.SortCriteria) []*T.Winlink {
    var list: std.ArrayList(*T.Winlink) = .{};
    var sit = sess.sessions.valueIterator();
    while (sit.next()) |s| {
        var wit = s.*.windows.valueIterator();
        while (wit.next()) |wl| list.append(xm.allocator, wl) catch unreachable;
    }

    const items = list.toOwnedSlice(xm.allocator) catch unreachable;
    sort_winlinks_in_place(items, sort_crit, .index);
    return items;
}

pub fn sorted_panes_window(w: *T.Window, sort_crit: T.SortCriteria) []*T.WindowPane {
    const items = xm.allocator.alloc(*T.WindowPane, w.panes.items.len) catch unreachable;
    @memcpy(items, w.panes.items);
    sort_panes_in_place(items, w, sort_crit);
    return items;
}

pub fn sorted_clients(sort_crit: T.SortCriteria) []*T.Client {
    const items = xm.allocator.alloc(*T.Client, srv.clients.items.len) catch unreachable;
    @memcpy(items, srv.clients.items);
    sort_clients_in_place(items, sort_crit);
    return items;
}

fn sort_sessions_in_place(items: []*T.Session, sort_crit: T.SortCriteria) void {
    const effective = if (sort_crit.order == .end) T.SortOrder.name else sort_crit.order;
    if (effective == .order) {
        if (sort_crit.reversed) reverse_slice(*T.Session, items);
        return;
    }
    std.sort.block(*T.Session, items, SortContext{ .order = effective, .reversed = sort_crit.reversed }, session_less_than);
}

fn sort_winlinks_in_place(items: []*T.Winlink, sort_crit: T.SortCriteria, default_order: T.SortOrder) void {
    const effective = if (sort_crit.order == .end) default_order else sort_crit.order;
    if (effective == .order) {
        if (sort_crit.reversed) reverse_slice(*T.Winlink, items);
        return;
    }
    std.sort.block(*T.Winlink, items, SortContext{ .order = effective, .reversed = sort_crit.reversed }, winlink_less_than);
}

fn sort_panes_in_place(items: []*T.WindowPane, w: *T.Window, sort_crit: T.SortCriteria) void {
    const effective = if (sort_crit.order == .end) T.SortOrder.order else sort_crit.order;
    if (effective == .order) {
        if (sort_crit.reversed) reverse_slice(*T.WindowPane, items);
        return;
    }
    std.sort.block(*T.WindowPane, items, PaneSortContext{ .order = effective, .reversed = sort_crit.reversed, .window = w }, pane_less_than);
}

fn sort_clients_in_place(items: []*T.Client, sort_crit: T.SortCriteria) void {
    const effective = if (sort_crit.order == .end) T.SortOrder.order else sort_crit.order;
    if (effective == .order) {
        if (sort_crit.reversed) reverse_slice(*T.Client, items);
        return;
    }
    std.sort.block(*T.Client, items, SortContext{ .order = effective, .reversed = sort_crit.reversed }, client_less_than);
}

const SortContext = struct {
    order: T.SortOrder,
    reversed: bool,
};

const PaneSortContext = struct {
    order: T.SortOrder,
    reversed: bool,
    window: *T.Window,
};

fn session_less_than(ctx: SortContext, a: *T.Session, b: *T.Session) bool {
    return order_to_less(compare_session(a, b, ctx.order), ctx.reversed);
}

fn winlink_less_than(ctx: SortContext, a: *T.Winlink, b: *T.Winlink) bool {
    return order_to_less(compare_winlink(a, b, ctx.order), ctx.reversed);
}

fn pane_less_than(ctx: PaneSortContext, a: *T.WindowPane, b: *T.WindowPane) bool {
    return order_to_less(compare_pane(a, b, ctx.window, ctx.order), ctx.reversed);
}

fn client_less_than(ctx: SortContext, a: *T.Client, b: *T.Client) bool {
    return order_to_less(compare_client(a, b, ctx.order), ctx.reversed);
}

fn order_to_less(order: std.math.Order, reversed: bool) bool {
    return if (reversed) order == .gt else order == .lt;
}

fn compare_session(a: *T.Session, b: *T.Session, order: T.SortOrder) std.math.Order {
    const primary = switch (order) {
        .index, .creation => std.math.order(a.id, b.id),
        .name => std.mem.order(u8, a.name, b.name),
        else => std.math.Order.eq,
    };
    if (primary != .eq) return primary;
    return std.math.order(a.id, b.id);
}

fn compare_winlink(a: *T.Winlink, b: *T.Winlink, order: T.SortOrder) std.math.Order {
    const primary = switch (order) {
        .index => std.math.order(a.idx, b.idx),
        .creation => std.math.order(a.window.id, b.window.id),
        .name => std.mem.order(u8, a.window.name, b.window.name),
        .size => std.math.order(window_area(a.window), window_area(b.window)),
        else => std.math.Order.eq,
    };
    if (primary != .eq) return primary;
    return std.math.order(a.idx, b.idx);
}

fn compare_pane(a: *T.WindowPane, b: *T.WindowPane, w: *T.Window, order: T.SortOrder) std.math.Order {
    const primary = switch (order) {
        .activity => std.math.order(a.active_point, b.active_point),
        .creation => std.math.order(a.id, b.id),
        .index => std.math.order(window_pane_index(w, a), window_pane_index(w, b)),
        .name => std.mem.order(u8, pane_title(a), pane_title(b)),
        .size => std.math.order(a.sx * a.sy, b.sx * b.sy),
        else => std.math.Order.eq,
    };
    if (primary != .eq) return primary;
    return std.math.order(a.id, b.id);
}

fn compare_client(a: *T.Client, b: *T.Client, order: T.SortOrder) std.math.Order {
    const primary = switch (order) {
        .creation => std.math.order(a.id, b.id),
        .name => std.mem.order(u8, client_name(a), client_name(b)),
        .size => blk: {
            const sx_cmp = std.math.order(a.tty.sx, b.tty.sx);
            if (sx_cmp != .eq) break :blk sx_cmp;
            break :blk std.math.order(a.tty.sy, b.tty.sy);
        },
        else => std.math.Order.eq,
    };
    if (primary != .eq) return primary;
    return std.math.order(a.id, b.id);
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

test "sort_order_from_string parses aliases" {
    try std.testing.expectEqual(T.SortOrder.index, sort_order_from_string("key"));
    try std.testing.expectEqual(T.SortOrder.name, sort_order_from_string("title"));
    try std.testing.expectEqual(T.SortOrder.end, sort_order_from_string("mystery"));
}
