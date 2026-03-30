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
// Ported from tmux/style.c
// Original copyright:
//   Copyright (c) 2007 Nicholas Marriott <nicholas.marriott@gmail.com>
//   Copyright (c) 2014 Tiago Cunha <tcunha@users.sourceforge.net>
//   ISC licence – same terms as above.

const std = @import("std");
const T = @import("types.zig");
const attrs = @import("attributes.zig");
const colour = @import("colour.zig");
const opts = @import("options.zig");
const utf8 = @import("utf8.zig");

threadlocal var style_buf: [256]u8 = undefined;

const style_default = T.Style{
    .gc = T.grid_default_cell,
    .ignore = false,
    .fill = 8,
    .@"align" = .default,
    .list = .off,
    .range_type = .none,
    .range_argument = 0,
    .range_string = std.mem.zeroes([16]u8),
    .width = -1,
    .width_percentage = 0,
    .pad = -1,
    .default_type = .base,
};

pub fn style_parse_is_valid(in: []const u8) bool {
    var sy = style_default;
    const base = T.GridCell{};
    return style_parse(&sy, &base, in) == 0;
}

pub fn style_parse(sy: *T.Style, base: *const T.GridCell, in: []const u8) i32 {
    if (in.len == 0) return 0;

    const saved = sy.*;
    var pos: usize = 0;
    while (true) {
        while (pos < in.len and isDelimiter(in[pos])) : (pos += 1) {}
        if (pos >= in.len) break;

        const start = pos;
        while (pos < in.len and !isDelimiter(in[pos])) : (pos += 1) {}
        const token = in[start..pos];
        if (token.len == 0 or token.len > 255) {
            sy.* = saved;
            return -1;
        }
        if (!applyToken(sy, base, token)) {
            sy.* = saved;
            return -1;
        }
    }
    return 0;
}

pub fn style_tostring(sy: *const T.Style) []const u8 {
    var stream = std.io.fixedBufferStream(&style_buf);
    const writer = stream.writer();
    var comma = false;

    if (sy.list != .off) {
        writeField(writer, &comma, "list=", switch (sy.list) {
            .on => "on",
            .focus => "focus",
            .left_marker => "left-marker",
            .right_marker => "right-marker",
            .off => unreachable,
        });
    }
    if (sy.range_type != .none) {
        var tmp: [32]u8 = undefined;
        const value = switch (sy.range_type) {
            .left => "left",
            .right => "right",
            .pane => std.fmt.bufPrint(&tmp, "pane|%{d}", .{sy.range_argument}) catch unreachable,
            .window => std.fmt.bufPrint(&tmp, "window|{d}", .{sy.range_argument}) catch unreachable,
            .session => std.fmt.bufPrint(&tmp, "session|${d}", .{sy.range_argument}) catch unreachable,
            .user => blk: {
                const len = std.mem.indexOfScalar(u8, &sy.range_string, 0) orelse sy.range_string.len;
                break :blk std.fmt.bufPrint(&tmp, "user|{s}", .{sy.range_string[0..len]}) catch unreachable;
            },
            .none => unreachable,
        };
        writeField(writer, &comma, "range=", value);
    }
    if (sy.@"align" != .default) {
        writeField(writer, &comma, "align=", switch (sy.@"align") {
            .left => "left",
            .centre => "centre",
            .right => "right",
            .absolute_centre => "absolute-centre",
            .default => unreachable,
        });
    }
    if (sy.default_type != .base) {
        writeToken(writer, &comma, switch (sy.default_type) {
            .push => "push-default",
            .pop => "pop-default",
            .set => "set-default",
            .base => unreachable,
        });
    }
    if (sy.fill != 8) writeField(writer, &comma, "fill=", colour.colour_tostring(sy.fill));
    if (sy.gc.fg != 8) writeField(writer, &comma, "fg=", colour.colour_tostring(sy.gc.fg));
    if (sy.gc.bg != 8) writeField(writer, &comma, "bg=", colour.colour_tostring(sy.gc.bg));
    if (sy.gc.us != 8) writeField(writer, &comma, "us=", colour.colour_tostring(sy.gc.us));
    if (sy.gc.attr != 0) writeToken(writer, &comma, attrs.attributes_tostring(sy.gc.attr));
    if (sy.width >= 0) {
        if (sy.width_percentage != 0)
            writeTokenFmt(writer, &comma, "width={d}%", .{sy.width})
        else
            writeTokenFmt(writer, &comma, "width={d}", .{sy.width});
    }
    if (sy.pad >= 0) writeTokenFmt(writer, &comma, "pad={d}", .{sy.pad});

    const written = stream.getWritten();
    return if (written.len == 0) "default" else written;
}

pub fn style_set(sy: *T.Style, gc: *const T.GridCell) void {
    sy.* = style_default;
    sy.gc = gc.*;
}

pub fn style_copy(dst: *T.Style, src: *const T.Style) void {
    dst.* = src.*;
}

pub fn style_from_option(oo: *T.Options, name: []const u8) ?T.Style {
    const raw = opts.options_get_style_string(oo, name) orelse return null;
    if (std.mem.indexOf(u8, raw, "#{") != null) return null;

    var sy = style_default;
    if (style_parse(&sy, &T.grid_default_cell, raw) != 0) return null;
    return sy;
}

pub fn style_add(gc: *T.GridCell, oo: *T.Options, name: []const u8, _ft: ?*anyopaque) void {
    _ = _ft;
    const sy = style_from_option(oo, name) orelse style_default;
    if (sy.gc.fg != 8) gc.fg = sy.gc.fg;
    if (sy.gc.bg != 8) gc.bg = sy.gc.bg;
    if (sy.gc.us != 8) gc.us = sy.gc.us;
    gc.attr |= sy.gc.attr;
}

pub fn style_apply(gc: *T.GridCell, oo: *T.Options, name: []const u8, ft: ?*anyopaque) void {
    gc.* = T.grid_default_cell;
    style_add(gc, oo, name, ft);
}

pub fn style_set_scrollbar_style_from_option(sb_style: *T.Style, oo: *T.Options) void {
    if (style_from_option(oo, "pane-scrollbars-style")) |sy| {
        style_copy(sb_style, &sy);
        if (sb_style.width < 1) sb_style.width = T.PANE_SCROLLBARS_DEFAULT_WIDTH;
        if (sb_style.pad < 0) sb_style.pad = T.PANE_SCROLLBARS_DEFAULT_PADDING;
    } else {
        style_set(sb_style, &T.grid_default_cell);
        sb_style.width = T.PANE_SCROLLBARS_DEFAULT_WIDTH;
        sb_style.pad = T.PANE_SCROLLBARS_DEFAULT_PADDING;
    }
    utf8.utf8_set(&sb_style.gc.data, T.PANE_SCROLLBARS_CHARACTER);
}

fn applyToken(sy: *T.Style, base: *const T.GridCell, token: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(token, "default")) {
        sy.gc.fg = base.fg;
        sy.gc.bg = base.bg;
        sy.gc.us = base.us;
        sy.gc.attr = base.attr;
        sy.gc.flags = base.flags;
        return true;
    }
    if (std.ascii.eqlIgnoreCase(token, "ignore")) {
        sy.ignore = true;
        return true;
    }
    if (std.ascii.eqlIgnoreCase(token, "noignore")) {
        sy.ignore = false;
        return true;
    }
    if (std.ascii.eqlIgnoreCase(token, "push-default")) {
        sy.default_type = .push;
        return true;
    }
    if (std.ascii.eqlIgnoreCase(token, "pop-default")) {
        sy.default_type = .pop;
        return true;
    }
    if (std.ascii.eqlIgnoreCase(token, "set-default")) {
        sy.default_type = .set;
        return true;
    }
    if (std.ascii.eqlIgnoreCase(token, "nolist")) {
        sy.list = .off;
        return true;
    }
    if (stripPrefixIgnoreCase(token, "list=")) |value| {
        sy.list = if (std.ascii.eqlIgnoreCase(value, "on"))
            .on
        else if (std.ascii.eqlIgnoreCase(value, "focus"))
            .focus
        else if (std.ascii.eqlIgnoreCase(value, "left-marker"))
            .left_marker
        else if (std.ascii.eqlIgnoreCase(value, "right-marker"))
            .right_marker
        else
            return false;
        return true;
    }
    if (std.ascii.eqlIgnoreCase(token, "norange")) {
        sy.range_type = style_default.range_type;
        sy.range_argument = style_default.range_argument;
        sy.range_string = style_default.range_string;
        return true;
    }
    if (stripPrefixIgnoreCase(token, "range=")) |value| {
        return parseRange(sy, value);
    }
    if (std.ascii.eqlIgnoreCase(token, "noalign")) {
        sy.@"align" = style_default.@"align";
        return true;
    }
    if (stripPrefixIgnoreCase(token, "align=")) |value| {
        sy.@"align" = if (std.ascii.eqlIgnoreCase(value, "left"))
            .left
        else if (std.ascii.eqlIgnoreCase(value, "centre"))
            .centre
        else if (std.ascii.eqlIgnoreCase(value, "right"))
            .right
        else if (std.ascii.eqlIgnoreCase(value, "absolute-centre"))
            .absolute_centre
        else
            return false;
        return true;
    }
    if (stripPrefixIgnoreCase(token, "fill=")) |value| {
        const parsed = colour.colour_fromstring(value);
        if (parsed == -1) return false;
        sy.fill = parsed;
        return true;
    }
    if (token.len > 3 and (std.ascii.eqlIgnoreCase(token[1..3], "g="))) {
        const parsed = colour.colour_fromstring(token[3..]);
        if (parsed == -1) return false;
        if (token[0] == 'f' or token[0] == 'F')
            sy.gc.fg = if (parsed != 8) parsed else base.fg
        else if (token[0] == 'b' or token[0] == 'B')
            sy.gc.bg = if (parsed != 8) parsed else base.bg
        else
            return false;
        return true;
    }
    if (stripPrefixIgnoreCase(token, "us=")) |value| {
        const parsed = colour.colour_fromstring(value);
        if (parsed == -1) return false;
        sy.gc.us = if (parsed != 8) parsed else base.us;
        return true;
    }
    if (std.ascii.eqlIgnoreCase(token, "none")) {
        sy.gc.attr = 0;
        return true;
    }
    if (token.len > 2 and std.ascii.eqlIgnoreCase(token[0..2], "no")) {
        if (std.ascii.eqlIgnoreCase(token[2..], "attr")) {
            sy.gc.attr |= T.GRID_ATTR_NOATTR;
            return true;
        }
        const parsed = attrs.attributes_fromstring(token[2..]);
        if (parsed == -1) return false;
        sy.gc.attr &= ~@as(u16, @intCast(parsed));
        return true;
    }
    if (stripPrefixIgnoreCase(token, "width=")) |value| {
        var raw = value;
        if (raw.len == 0) return false;
        if (raw[raw.len - 1] == '%') {
            raw = raw[0 .. raw.len - 1];
            const parsed = parseBoundedU32(raw, 100) orelse return false;
            sy.width = @intCast(parsed);
            sy.width_percentage = 1;
            return true;
        }
        const parsed = parseAnyU32(raw) orelse return false;
        sy.width = @intCast(parsed);
        sy.width_percentage = 0;
        return true;
    }
    if (stripPrefixIgnoreCase(token, "pad=")) |value| {
        const parsed = parseAnyU32(value) orelse return false;
        sy.pad = @intCast(parsed);
        return true;
    }

    const parsed = attrs.attributes_fromstring(token);
    if (parsed == -1) return false;
    sy.gc.attr |= @as(u16, @intCast(parsed));
    return true;
}

fn parseRange(sy: *T.Style, value: []const u8) bool {
    const sep = std.mem.indexOfScalar(u8, value, '|');
    const kind = if (sep) |idx| value[0..idx] else value;
    const arg = if (sep) |idx| value[idx + 1 ..] else "";

    if (std.ascii.eqlIgnoreCase(kind, "left")) {
        if (sep != null) return false;
        sy.range_type = .left;
        sy.range_argument = 0;
        setRangeString(sy, "");
        return true;
    }
    if (std.ascii.eqlIgnoreCase(kind, "right")) {
        if (sep != null) return false;
        sy.range_type = .right;
        sy.range_argument = 0;
        setRangeString(sy, "");
        return true;
    }
    if (std.ascii.eqlIgnoreCase(kind, "pane")) {
        if (sep == null or arg.len < 2 or arg[0] != '%') return false;
        const parsed = parseAnyU32(arg[1..]) orelse return false;
        sy.range_type = .pane;
        sy.range_argument = parsed;
        setRangeString(sy, "");
        return true;
    }
    if (std.ascii.eqlIgnoreCase(kind, "window")) {
        if (sep == null or arg.len == 0) return false;
        const parsed = parseAnyU32(arg) orelse return false;
        sy.range_type = .window;
        sy.range_argument = parsed;
        setRangeString(sy, "");
        return true;
    }
    if (std.ascii.eqlIgnoreCase(kind, "session")) {
        if (sep == null or arg.len < 2 or arg[0] != '$') return false;
        const parsed = parseAnyU32(arg[1..]) orelse return false;
        sy.range_type = .session;
        sy.range_argument = parsed;
        setRangeString(sy, "");
        return true;
    }
    if (std.ascii.eqlIgnoreCase(kind, "user")) {
        if (sep == null or arg.len == 0) return false;
        sy.range_type = .user;
        sy.range_argument = 0;
        setRangeString(sy, arg);
        return true;
    }
    return false;
}

fn setRangeString(sy: *T.Style, s: []const u8) void {
    @memset(&sy.range_string, 0);
    const len = @min(sy.range_string.len - 1, s.len);
    @memcpy(sy.range_string[0..len], s[0..len]);
}

fn parseAnyU32(s: []const u8) ?u32 {
    return std.fmt.parseInt(u32, s, 10) catch null;
}

fn parseBoundedU32(s: []const u8, max: u32) ?u32 {
    const value = parseAnyU32(s) orelse return null;
    if (value > max) return null;
    return value;
}

fn stripPrefixIgnoreCase(s: []const u8, prefix: []const u8) ?[]const u8 {
    if (s.len < prefix.len) return null;
    if (!std.ascii.eqlIgnoreCase(s[0..prefix.len], prefix)) return null;
    return s[prefix.len..];
}

fn isDelimiter(ch: u8) bool {
    return ch == ' ' or ch == ',' or ch == '\n';
}

fn writeToken(writer: anytype, comma: *bool, token: []const u8) void {
    if (comma.*) writer.writeByte(',') catch unreachable;
    writer.writeAll(token) catch unreachable;
    comma.* = true;
}

fn writeField(writer: anytype, comma: *bool, name: []const u8, value: []const u8) void {
    if (comma.*) writer.writeByte(',') catch unreachable;
    writer.writeAll(name) catch unreachable;
    writer.writeAll(value) catch unreachable;
    comma.* = true;
}

fn writeTokenFmt(writer: anytype, comma: *bool, comptime fmt: []const u8, args: anytype) void {
    if (comma.*) writer.writeByte(',') catch unreachable;
    writer.print(fmt, args) catch unreachable;
    comma.* = true;
}

fn initTestOptions() T.Options {
    return T.Options.init(std.testing.allocator, null);
}

fn putTestString(oo: *T.Options, key: []const u8, value: []const u8) !void {
    const owned_key = try std.testing.allocator.dupe(u8, key);
    errdefer std.testing.allocator.free(owned_key);
    const owned_value = try std.testing.allocator.dupe(u8, value);
    errdefer std.testing.allocator.free(owned_value);
    try oo.entries.put(owned_key, .{ .string = owned_value });
}

fn freeTestOptions(oo: *T.Options) void {
    var it = oo.entries.iterator();
    while (it.next()) |entry| {
        std.testing.allocator.free(entry.key_ptr.*);
        switch (entry.value_ptr.*) {
            .string => |s| std.testing.allocator.free(s),
            else => {},
        }
    }
    oo.deinit();
}

test "style_parse handles core tokens and rollback" {
    var sy = style_default;
    try std.testing.expectEqual(@as(i32, 0), style_parse(&sy, &T.grid_default_cell, "fg=red,bg=blue,us=green,bright,noitalics,noattr,width=50%,pad=3,align=centre,range=user|hello,push-default"));
    try std.testing.expectEqual(@as(i32, 1), sy.gc.fg);
    try std.testing.expectEqual(@as(i32, 4), sy.gc.bg);
    try std.testing.expectEqual(@as(i32, 2), sy.gc.us);
    try std.testing.expect(sy.gc.attr & T.GRID_ATTR_BRIGHT != 0);
    try std.testing.expect(sy.gc.attr & T.GRID_ATTR_NOATTR != 0);
    try std.testing.expectEqual(T.StyleAlign.centre, sy.@"align");
    try std.testing.expectEqual(T.StyleRangeType.user, sy.range_type);
    try std.testing.expectEqualStrings("hello", std.mem.sliceTo(&sy.range_string, 0));
    try std.testing.expectEqual(@as(i32, 50), sy.width);
    try std.testing.expectEqual(@as(i32, 1), sy.width_percentage);
    try std.testing.expectEqual(@as(i32, 3), sy.pad);
    try std.testing.expectEqual(T.StyleDefaultType.push, sy.default_type);

    const saved = sy;
    try std.testing.expectEqual(@as(i32, -1), style_parse(&sy, &T.grid_default_cell, "mystery-token"));
    try std.testing.expectEqual(saved, sy);
}

test "style_tostring roundtrips representative subset" {
    var sy = style_default;
    try std.testing.expectEqual(@as(i32, 0), style_parse(&sy, &T.grid_default_cell, "list=focus,range=session|$7,align=right,set-default,fill=colour3,fg=brightred,bg=default,us=#010203,bright,noattr,width=9,pad=2"));

    try std.testing.expectEqualStrings(
        "list=focus,range=session|$7,align=right,set-default,fill=colour3,fg=brightred,us=#010203,bright,noattr,width=9,pad=2",
        style_tostring(&sy),
    );
}

test "style_from_option rejects dynamic strings and parses static ones" {
    var oo = initTestOptions();
    defer freeTestOptions(&oo);

    try putTestString(&oo, "ok", "fg=red,bright");
    try putTestString(&oo, "dynamic", "#{pane_title}");

    const parsed = style_from_option(&oo, "ok") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(i32, 1), parsed.gc.fg);
    try std.testing.expect(parsed.gc.attr & T.GRID_ATTR_BRIGHT != 0);
    try std.testing.expect(style_from_option(&oo, "dynamic") == null);
}

test "style_apply and scrollbar defaults use grid default cell" {
    var oo = initTestOptions();
    defer freeTestOptions(&oo);

    try putTestString(&oo, "pane-scrollbars-style", "fg=blue,pad=4");
    try putTestString(&oo, "message-style", "bg=brightwhite,italics");

    var gc = T.GridCell{
        .data = std.mem.zeroes(T.Utf8Data),
        .attr = 0,
        .flags = 0,
        .fg = 99,
        .bg = 99,
        .us = 99,
        .link = 0,
    };
    style_apply(&gc, &oo, "message-style", null);
    try std.testing.expectEqual(T.grid_default_cell.fg, gc.fg);
    try std.testing.expectEqual(@as(i32, 97), gc.bg);
    try std.testing.expect(gc.attr & T.GRID_ATTR_ITALICS != 0);

    var sb = style_default;
    style_set_scrollbar_style_from_option(&sb, &oo);
    try std.testing.expectEqual(@as(i32, 4), sb.gc.fg);
    try std.testing.expectEqual(T.PANE_SCROLLBARS_DEFAULT_WIDTH, sb.width);
    try std.testing.expectEqual(@as(i32, 4), sb.pad);
    try std.testing.expectEqual(@as(u8, T.PANE_SCROLLBARS_CHARACTER), sb.gc.data.data[0]);
}
