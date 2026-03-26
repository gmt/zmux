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
// Ported from tmux/hyperlinks.c
// Original copyright:
//   Copyright (c) 2021 Will <author@will.party>
//   Copyright (c) 2022 Jeff Chiang <pobomp@gmail.com>
//   ISC licence – same terms as above.

const std = @import("std");
const xm = @import("xmalloc.zig");
const utf8 = @import("utf8.zig");

pub const MAX_HYPERLINKS: usize = 5000;

pub const Hyperlinks = struct {
    next_inner: u32 = 1,
    by_inner: std.AutoHashMap(u32, *HyperlinkUri),
    by_uri: std.StringHashMap(*HyperlinkUri),
    references: u32 = 1,
};

const HyperlinkUri = struct {
    tree: *Hyperlinks,
    inner: u32,
    internal_id: []u8,
    external_id: []u8,
    uri: []u8,
    dedupe_key: ?[]u8 = null,
};

var global_hyperlinks: std.ArrayList(*HyperlinkUri) = undefined;
var global_hyperlinks_init = false;
var hyperlinks_next_external_id: u64 = 1;

fn ensure_global_init() void {
    if (global_hyperlinks_init) return;
    global_hyperlinks = .{};
    global_hyperlinks_init = true;
}

pub fn hyperlinks_init() *Hyperlinks {
    ensure_global_init();

    const hl = xm.allocator.create(Hyperlinks) catch unreachable;
    hl.* = .{
        .by_inner = std.AutoHashMap(u32, *HyperlinkUri).init(xm.allocator),
        .by_uri = std.StringHashMap(*HyperlinkUri).init(xm.allocator),
    };
    return hl;
}

pub fn hyperlinks_copy(hl: *Hyperlinks) *Hyperlinks {
    hl.references += 1;
    return hl;
}

pub fn hyperlinks_reset(hl: *Hyperlinks) void {
    while (hl.by_inner.count() != 0) {
        var it = hl.by_inner.valueIterator();
        const hlu = it.next().?.*;
        hyperlinks_remove(hlu);
    }
}

pub fn hyperlinks_free(hl: *Hyperlinks) void {
    if (hl.references == 0) return;
    hl.references -= 1;
    if (hl.references != 0) return;

    hyperlinks_reset(hl);
    hl.by_inner.deinit();
    hl.by_uri.deinit();
    xm.allocator.destroy(hl);
}

pub fn hyperlinks_put(hl: *Hyperlinks, uri_in: []const u8, internal_id_in: ?[]const u8) u32 {
    ensure_global_init();

    const internal_id_src = internal_id_in orelse "";
    const uri = utf8.utf8_stravis(uri_in, utf8.VIS_OCTAL | utf8.VIS_CSTYLE);
    errdefer xm.allocator.free(uri);
    const internal_id = utf8.utf8_stravis(internal_id_src, utf8.VIS_OCTAL | utf8.VIS_CSTYLE);
    errdefer xm.allocator.free(internal_id);
    const anonymous = internal_id_src.len == 0;
    const dedupe_key = if (anonymous) null else make_dedupe_key(internal_id, uri);
    defer if (dedupe_key) |key| xm.allocator.free(key);

    if (dedupe_key) |key| {
        if (hl.by_uri.get(key)) |existing| {
            xm.allocator.free(uri);
            xm.allocator.free(internal_id);
            return existing.inner;
        }
    }

    const hlu = xm.allocator.create(HyperlinkUri) catch unreachable;
    hlu.* = .{
        .tree = hl,
        .inner = hl.next_inner,
        .internal_id = internal_id,
        .external_id = xm.xasprintf("tmux{X}", .{hyperlinks_next_external_id}),
        .uri = uri,
        .dedupe_key = if (dedupe_key) |key| xm.xstrdup(key) else null,
    };
    hl.next_inner += 1;
    hyperlinks_next_external_id += 1;

    hl.by_inner.put(hlu.inner, hlu) catch unreachable;
    if (hlu.dedupe_key) |key| {
        hl.by_uri.put(key, hlu) catch unreachable;
    }

    global_hyperlinks.append(xm.allocator, hlu) catch unreachable;
    if (global_hyperlinks.items.len == MAX_HYPERLINKS) {
        hyperlinks_remove(global_hyperlinks.items[0]);
    }

    return hlu.inner;
}

pub fn hyperlinks_get(
    hl: *Hyperlinks,
    inner: u32,
    uri_out: ?*[]const u8,
    internal_id_out: ?*[]const u8,
    external_id_out: ?*[]const u8,
) bool {
    const hlu = hl.by_inner.get(inner) orelse return false;
    if (uri_out) |out| out.* = hlu.uri;
    if (internal_id_out) |out| out.* = hlu.internal_id;
    if (external_id_out) |out| out.* = hlu.external_id;
    return true;
}

fn hyperlinks_remove(hlu: *HyperlinkUri) void {
    const hl = hlu.tree;

    _ = hl.by_inner.remove(hlu.inner);
    if (hlu.dedupe_key) |key| {
        _ = hl.by_uri.remove(key);
    }

    for (global_hyperlinks.items, 0..) |entry, idx| {
        if (entry != hlu) continue;
        _ = global_hyperlinks.orderedRemove(idx);
        break;
    }

    xm.allocator.free(hlu.internal_id);
    xm.allocator.free(hlu.external_id);
    xm.allocator.free(hlu.uri);
    if (hlu.dedupe_key) |key| xm.allocator.free(key);
    xm.allocator.destroy(hlu);
}

fn make_dedupe_key(internal_id: []const u8, uri: []const u8) []u8 {
    return std.fmt.allocPrint(xm.allocator, "{s}\x1f{s}", .{ internal_id, uri }) catch unreachable;
}

fn reset_global_state_for_tests() void {
    if (global_hyperlinks_init) {
        for (global_hyperlinks.items) |hlu| {
            // The owning hyperlink set frees entries during reset/free.
            _ = hlu;
        }
        global_hyperlinks.deinit(xm.allocator);
    }
    global_hyperlinks = .{};
    global_hyperlinks_init = true;
    hyperlinks_next_external_id = 1;
}

test "hyperlinks deduplicate non-anonymous entries" {
    reset_global_state_for_tests();
    const hl = hyperlinks_init();
    defer hyperlinks_free(hl);

    const first = hyperlinks_put(hl, "https://example.com", "pane-1");
    const second = hyperlinks_put(hl, "https://example.com", "pane-1");

    try std.testing.expectEqual(first, second);
}

test "hyperlinks keep anonymous entries unique" {
    reset_global_state_for_tests();
    const hl = hyperlinks_init();
    defer hyperlinks_free(hl);

    const first = hyperlinks_put(hl, "https://example.com", null);
    const second = hyperlinks_put(hl, "https://example.com", null);

    try std.testing.expect(first != second);
}

test "hyperlinks_get returns stored fields" {
    reset_global_state_for_tests();
    const hl = hyperlinks_init();
    defer hyperlinks_free(hl);

    const inner = hyperlinks_put(hl, "https://example.com/docs", "internal");

    var uri: []const u8 = undefined;
    var internal_id: []const u8 = undefined;
    var external_id: []const u8 = undefined;
    try std.testing.expect(hyperlinks_get(hl, inner, &uri, &internal_id, &external_id));
    try std.testing.expectEqualStrings("https://example.com/docs", uri);
    try std.testing.expectEqualStrings("internal", internal_id);
    try std.testing.expectEqualStrings("tmux1", external_id);
}

test "hyperlinks escape strings before deduping and storage" {
    reset_global_state_for_tests();
    const hl = hyperlinks_init();
    defer hyperlinks_free(hl);

    const uri_in = [_]u8{ 'u', 0x01 };
    const first = hyperlinks_put(hl, &uri_in, "pane:1");
    const second = hyperlinks_put(hl, &uri_in, "pane:1");
    try std.testing.expectEqual(first, second);

    var uri: []const u8 = undefined;
    var internal_id: []const u8 = undefined;
    try std.testing.expect(hyperlinks_get(hl, first, &uri, &internal_id, null));
    try std.testing.expectEqualStrings("u\\001", uri);
    try std.testing.expectEqualStrings("pane:1", internal_id);
}

test "hyperlinks copy and free share ownership" {
    reset_global_state_for_tests();
    const hl = hyperlinks_init();
    const copy = hyperlinks_copy(hl);

    const inner = hyperlinks_put(hl, "https://example.com/shared", "x");
    hyperlinks_free(hl);

    var uri: []const u8 = undefined;
    try std.testing.expect(hyperlinks_get(copy, inner, &uri, null, null));
    try std.testing.expectEqualStrings("https://example.com/shared", uri);

    hyperlinks_free(copy);
}

test "hyperlinks reset removes all entries" {
    reset_global_state_for_tests();
    const hl = hyperlinks_init();
    defer hyperlinks_free(hl);

    const inner = hyperlinks_put(hl, "https://example.com/reset", "x");
    hyperlinks_reset(hl);

    try std.testing.expect(!hyperlinks_get(hl, inner, null, null, null));
}
