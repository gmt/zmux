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
// Ported from tmux/paste.c
// Original copyright:
//   Copyright (c) 2007 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

const std = @import("std");
const xm = @import("xmalloc.zig");
const notify_mod = @import("notify.zig");
const opts = @import("options.zig");
const T = @import("types.zig");

pub const PasteBuffer = struct {
    data: []u8,
    name: []u8,
    created: i64,
    automatic: bool,
    order: u32,
};

var paste_next_index: u32 = 0;
var paste_next_order: u32 = 0;
var paste_num_automatic: u32 = 0;
var paste_by_name: std.StringHashMap(*PasteBuffer) = undefined;
var paste_by_time: std.ArrayList(*PasteBuffer) = undefined;
var paste_init = false;
var buffer_limit_override: ?u32 = null;

fn ensure_init() void {
    if (paste_init) return;
    paste_by_name = std.StringHashMap(*PasteBuffer).init(xm.allocator);
    paste_by_time = .{};
    paste_init = true;
}

pub fn paste_buffer_name(pb: *PasteBuffer) []const u8 {
    return pb.name;
}

pub fn paste_buffer_order(pb: *PasteBuffer) u32 {
    return pb.order;
}

pub fn paste_buffer_created(pb: *PasteBuffer) i64 {
    return pb.created;
}

pub fn paste_buffer_data(pb: *PasteBuffer, size: ?*usize) []const u8 {
    if (size) |out| out.* = pb.data.len;
    return pb.data;
}

pub fn paste_make_sample(pb: *PasteBuffer) []u8 {
    const input_limit: usize = 200;
    const output_limit: usize = 200;
    const data = pb.data[0..@min(pb.data.len, input_limit)];

    var out: std.ArrayList(u8) = .{};
    var truncated = pb.data.len > input_limit;

    for (data) |ch| {
        const escaped_len = sample_escape_len(ch);
        if (out.items.len + escaped_len > output_limit) {
            truncated = true;
            break;
        }
        append_sample_escaped(&out, ch);
    }

    if (truncated) {
        while (out.items.len + 3 > output_limit and out.items.len > 0) _ = out.pop();
        out.appendSlice(xm.allocator, "...") catch unreachable;
    }

    return out.toOwnedSlice(xm.allocator) catch unreachable;
}

pub fn paste_walk(pb: ?*PasteBuffer) ?*PasteBuffer {
    ensure_init();

    if (pb == null) {
        if (paste_by_time.items.len == 0) return null;
        return paste_by_time.items[0];
    }

    for (paste_by_time.items, 0..) |entry, idx| {
        if (entry != pb.?) continue;
        if (idx + 1 >= paste_by_time.items.len) return null;
        return paste_by_time.items[idx + 1];
    }
    return null;
}

pub fn paste_is_empty() bool {
    ensure_init();
    return paste_by_time.items.len == 0;
}

pub fn paste_get_top(name: ?*?[]u8) ?*PasteBuffer {
    ensure_init();

    for (paste_by_time.items) |pb| {
        if (!pb.automatic) continue;
        if (name) |out| out.* = xm.xstrdup(pb.name);
        return pb;
    }
    return null;
}

pub fn paste_get_name(name: ?[]const u8) ?*PasteBuffer {
    ensure_init();
    const actual_name = name orelse return null;
    if (actual_name.len == 0) return null;
    return paste_by_name.get(actual_name);
}

pub fn paste_free(pb: *PasteBuffer) void {
    ensure_init();

    notify_mod.notify_paste_buffer(pb.name, true);

    _ = paste_by_name.remove(pb.name);
    remove_from_time(pb);
    if (pb.automatic and paste_num_automatic > 0) paste_num_automatic -= 1;

    xm.allocator.free(pb.data);
    xm.allocator.free(pb.name);
    xm.allocator.destroy(pb);
}

pub fn paste_add(prefix: ?[]const u8, data: []u8) void {
    ensure_init();

    const actual_prefix = prefix orelse "buffer";
    if (data.len == 0) {
        xm.allocator.free(data);
        return;
    }

    while (paste_num_automatic >= current_buffer_limit()) {
        const oldest = oldest_automatic_buffer() orelse break;
        paste_free(oldest);
    }

    const pb = xm.allocator.create(PasteBuffer) catch unreachable;
    pb.* = .{
        .data = data,
        .name = next_automatic_name(actual_prefix),
        .created = std.time.timestamp(),
        .automatic = true,
        .order = paste_next_order,
    };
    paste_next_order += 1;
    paste_num_automatic += 1;

    insert_buffer(pb);
    notify_mod.notify_paste_buffer(pb.name, false);
}

pub fn paste_rename(oldname: ?[]const u8, newname: ?[]const u8, cause: *?[]u8) i32 {
    ensure_init();
    cause.* = null;

    const old_name = oldname orelse {
        cause.* = xm.xstrdup("no buffer");
        return -1;
    };
    const new_name = newname orelse {
        cause.* = xm.xstrdup("new name is empty");
        return -1;
    };

    if (old_name.len == 0) {
        cause.* = xm.xstrdup("no buffer");
        return -1;
    }
    if (new_name.len == 0) {
        cause.* = xm.xstrdup("new name is empty");
        return -1;
    }

    const pb = paste_get_name(old_name) orelse {
        cause.* = xm.xasprintf("no buffer {s}", .{old_name});
        return -1;
    };

    if (std.mem.eql(u8, old_name, new_name)) return 0;

    if (paste_get_name(new_name)) |existing| {
        if (existing != pb) paste_free(existing);
    }

    _ = paste_by_name.remove(pb.name);
    const old_copy = xm.xstrdup(pb.name);
    xm.allocator.free(pb.name);
    pb.name = xm.xstrdup(new_name);

    if (pb.automatic and paste_num_automatic > 0) paste_num_automatic -= 1;
    pb.automatic = false;

    paste_by_name.put(pb.name, pb) catch unreachable;
    notify_mod.notify_paste_buffer(old_copy, true);
    notify_mod.notify_paste_buffer(pb.name, false);
    xm.allocator.free(old_copy);
    return 0;
}

pub fn paste_set(data: []u8, name: ?[]const u8, cause: *?[]u8) i32 {
    ensure_init();
    cause.* = null;

    if (data.len == 0) {
        xm.allocator.free(data);
        return 0;
    }
    if (name == null) {
        paste_add(null, data);
        return 0;
    }
    if (name.?.len == 0) {
        cause.* = xm.xstrdup("empty buffer name");
        return -1;
    }

    if (paste_get_name(name.?)) |old| {
        paste_free(old);
    }

    const pb = xm.allocator.create(PasteBuffer) catch unreachable;
    pb.* = .{
        .data = data,
        .name = xm.xstrdup(name.?),
        .created = std.time.timestamp(),
        .automatic = false,
        .order = paste_next_order,
    };
    paste_next_order += 1;

    insert_buffer(pb);
    notify_mod.notify_paste_buffer(pb.name, false);
    return 0;
}

pub fn paste_replace(pb: *PasteBuffer, data: []u8) void {
    xm.allocator.free(pb.data);
    pb.data = data;
    notify_mod.notify_paste_buffer(pb.name, false);
}

fn insert_buffer(pb: *PasteBuffer) void {
    paste_by_name.put(pb.name, pb) catch unreachable;
    paste_by_time.insert(xm.allocator, 0, pb) catch unreachable;
}

fn remove_from_time(pb: *PasteBuffer) void {
    for (paste_by_time.items, 0..) |entry, idx| {
        if (entry != pb) continue;
        _ = paste_by_time.orderedRemove(idx);
        return;
    }
}

fn next_automatic_name(prefix: []const u8) []u8 {
    while (true) {
        const name = xm.xasprintf("{s}{d}", .{ prefix, paste_next_index });
        paste_next_index += 1;
        if (paste_get_name(name) == null) return name;
        xm.allocator.free(name);
    }
}

fn oldest_automatic_buffer() ?*PasteBuffer {
    var idx = paste_by_time.items.len;
    while (idx > 0) {
        idx -= 1;
        const pb = paste_by_time.items[idx];
        if (pb.automatic) return pb;
    }
    return null;
}

fn current_buffer_limit() u32 {
    if (buffer_limit_override) |limit| return limit;
    return @intCast(@max(opts.options_get_number(opts.global_options, "buffer-limit"), 1));
}

pub fn paste_reset_for_tests() void {
    if (!paste_init) {
        paste_by_name = std.StringHashMap(*PasteBuffer).init(xm.allocator);
        paste_by_time = .{};
        paste_init = true;
    }

    while (paste_by_time.items.len > 0) {
        const pb = paste_by_time.items[0];
        paste_free(pb);
    }
    paste_by_name.clearRetainingCapacity();
    paste_by_time.clearRetainingCapacity();
    paste_next_index = 0;
    paste_next_order = 0;
    paste_num_automatic = 0;
}

fn sample_escape_len(ch: u8) usize {
    return switch (ch) {
        0x07, 0x08, 0x0c, '\n', '\r', '\t', 0x0b, '\\', '"' => 2,
        else => if (sample_byte_is_printable(ch) or ch >= 0x80) 1 else 4,
    };
}

fn append_sample_escaped(out: *std.ArrayList(u8), ch: u8) void {
    switch (ch) {
        0x07 => out.appendSlice(xm.allocator, "\\a") catch unreachable,
        0x08 => out.appendSlice(xm.allocator, "\\b") catch unreachable,
        0x0c => out.appendSlice(xm.allocator, "\\f") catch unreachable,
        '\n' => out.appendSlice(xm.allocator, "\\n") catch unreachable,
        '\r' => out.appendSlice(xm.allocator, "\\r") catch unreachable,
        '\t' => out.appendSlice(xm.allocator, "\\t") catch unreachable,
        0x0b => out.appendSlice(xm.allocator, "\\v") catch unreachable,
        '\\' => out.appendSlice(xm.allocator, "\\\\") catch unreachable,
        '"' => out.appendSlice(xm.allocator, "\\\"") catch unreachable,
        else => {
            if (sample_byte_is_printable(ch) or ch >= 0x80) {
                out.append(xm.allocator, ch) catch unreachable;
            } else {
                const escaped = xm.xasprintf("\\{o:0>3}", .{ch});
                defer xm.allocator.free(escaped);
                out.appendSlice(xm.allocator, escaped) catch unreachable;
            }
        },
    }
}

fn sample_byte_is_printable(ch: u8) bool {
    return ch >= 0x20 and ch <= 0x7e and ch != '\\' and ch != '"';
}

test "paste_add creates automatic buffers and get_top returns newest automatic" {
    buffer_limit_override = 10;
    defer buffer_limit_override = null;
    paste_reset_for_tests();

    paste_add(null, xm.xstrdup("one"));
    paste_add(null, xm.xstrdup("two"));

    var top_name: ?[]u8 = null;
    const top = paste_get_top(&top_name) orelse return error.TestUnexpectedResult;
    defer if (top_name) |name| xm.allocator.free(name);

    try std.testing.expectEqualStrings("two", paste_buffer_data(top, null));
    try std.testing.expectEqualStrings("buffer1", top_name.?);
}

test "paste_set creates and replaces named buffers" {
    buffer_limit_override = 10;
    defer buffer_limit_override = null;
    paste_reset_for_tests();

    var cause: ?[]u8 = null;
    try std.testing.expectEqual(@as(i32, 0), paste_set(xm.xstrdup("first"), "named", &cause));
    try std.testing.expectEqual(@as(i32, 0), paste_set(xm.xstrdup("second"), "named", &cause));

    const pb = paste_get_name("named") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("second", paste_buffer_data(pb, null));
}

test "paste_rename clears automatic flag and handles collisions" {
    buffer_limit_override = 10;
    defer buffer_limit_override = null;
    paste_reset_for_tests();

    paste_add(null, xm.xstrdup("auto"));
    var cause: ?[]u8 = null;
    try std.testing.expectEqual(@as(i32, 0), paste_set(xm.xstrdup("named"), "named", &cause));

    const auto = paste_get_name("buffer0") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(i32, 0), paste_rename("buffer0", "named", &cause));

    const renamed = paste_get_name("named") orelse return error.TestUnexpectedResult;
    try std.testing.expect(renamed == auto);
    try std.testing.expect(!renamed.automatic);
}

test "paste_walk iterates newest first" {
    buffer_limit_override = 10;
    defer buffer_limit_override = null;
    paste_reset_for_tests();

    var cause: ?[]u8 = null;
    _ = paste_set(xm.xstrdup("one"), "one", &cause);
    _ = paste_set(xm.xstrdup("two"), "two", &cause);
    _ = paste_set(xm.xstrdup("three"), "three", &cause);

    const first = paste_walk(null) orelse return error.TestUnexpectedResult;
    const second = paste_walk(first) orelse return error.TestUnexpectedResult;
    const third = paste_walk(second) orelse return error.TestUnexpectedResult;

    try std.testing.expectEqualStrings("three", first.name);
    try std.testing.expectEqualStrings("two", second.name);
    try std.testing.expectEqualStrings("one", third.name);
    try std.testing.expect(paste_walk(third) == null);
}

test "paste_add honours automatic buffer limit" {
    buffer_limit_override = 2;
    defer buffer_limit_override = null;
    paste_reset_for_tests();

    paste_add(null, xm.xstrdup("one"));
    paste_add(null, xm.xstrdup("two"));
    paste_add(null, xm.xstrdup("three"));

    try std.testing.expect(paste_get_name("buffer0") == null);
    try std.testing.expect(paste_get_name("buffer1") != null);
    try std.testing.expect(paste_get_name("buffer2") != null);
}

test "paste_make_sample escapes control bytes and truncates" {
    paste_reset_for_tests();

    var cause: ?[]u8 = null;
    try std.testing.expectEqual(@as(i32, 0), paste_set(xm.xstrdup("a\n\t\"\\\x01"), "sample", &cause));

    const pb = paste_get_name("sample") orelse return error.TestUnexpectedResult;
    const sample = paste_make_sample(pb);
    defer xm.allocator.free(sample);
    try std.testing.expectEqualStrings("a\\n\\t\\\"\\\\\\001", sample);

    const long = xm.allocator.alloc(u8, 205) catch unreachable;
    @memset(long, 'x');
    try std.testing.expectEqual(@as(i32, 0), paste_set(long, "long", &cause));

    const long_pb = paste_get_name("long") orelse return error.TestUnexpectedResult;
    const long_sample = paste_make_sample(long_pb);
    defer xm.allocator.free(long_sample);
    try std.testing.expectEqual(@as(usize, 200), long_sample.len);
    try std.testing.expect(std.mem.endsWith(u8, long_sample, "..."));
}
