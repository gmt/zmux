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
// Ported from tmux/arguments.c
// Original copyright:
//   Copyright (c) 2010 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

//! arguments.zig – command argument parsing and small utility helpers.

const std = @import("std");
const T = @import("types.zig");
const utf8 = @import("utf8.zig");
const xm = @import("xmalloc.zig");

const ARGS_ENTRY_OPTIONAL_VALUE: u32 = 0x1;

pub const ParseError = error{
    InvalidFlag,
    MissingArgument,
    UnknownFlag,
    TooFewArguments,
    TooManyArguments,
};

pub const FlagEntry = struct {
    values: std.ArrayList([]u8) = .{},
    count: usize = 0,
    flags: u32 = 0,

    pub fn deinit(self: *FlagEntry, alloc: std.mem.Allocator) void {
        for (self.values.items) |value| alloc.free(value);
        self.values.deinit(alloc);
    }

    pub fn hasOptionalValue(self: *const FlagEntry) bool {
        return (self.flags & ARGS_ENTRY_OPTIONAL_VALUE) != 0;
    }

    pub fn lastValue(self: *const FlagEntry) ?[]const u8 {
        if (self.values.items.len == 0) return null;
        return self.values.items[self.values.items.len - 1];
    }
};

pub const Arguments = struct {
    allocator: std.mem.Allocator,
    flags: std.AutoHashMap(u8, FlagEntry),
    values: std.ArrayList([]u8),

    pub fn init(alloc: std.mem.Allocator) Arguments {
        return .{
            .allocator = alloc,
            .flags = std.AutoHashMap(u8, FlagEntry).init(alloc),
            .values = .{},
        };
    }

    pub fn deinit(self: *Arguments) void {
        var it = self.flags.valueIterator();
        while (it.next()) |flag_entry| flag_entry.deinit(self.allocator);
        self.flags.deinit();
        for (self.values.items) |s| self.allocator.free(s);
        self.values.deinit(self.allocator);
    }

    pub fn has(self: *const Arguments, flag: u8) bool {
        const flag_entry = self.flags.get(flag) orelse return false;
        return flag_entry.count != 0;
    }

    pub fn get(self: *const Arguments, flag: u8) ?[]const u8 {
        const flag_entry = self.flags.get(flag) orelse return null;
        return flag_entry.lastValue();
    }

    pub fn entry(self: *const Arguments, flag: u8) ?*const FlagEntry {
        return self.flags.getPtr(flag);
    }

    pub fn count(self: *const Arguments) usize {
        return self.values.items.len;
    }

    pub fn value_at(self: *const Arguments, idx: usize) ?[]const u8 {
        if (idx >= self.values.items.len) return null;
        return self.values.items[idx];
    }
};

pub fn args_parse(
    alloc: std.mem.Allocator,
    argv: []const []const u8,
    template: []const u8,
    lower: i32,
    upper: i32,
    cause: *?[]u8,
) !Arguments {
    var args = Arguments.init(alloc);
    errdefer args.deinit();

    var i: usize = 0;
    while (i < argv.len) {
        const stop = try args_parse_flags(&args, argv, template, cause, &i);
        if (stop) break;
    }

    while (i < argv.len) : (i += 1) {
        args.values.append(alloc, alloc.dupe(u8, argv[i]) catch unreachable) catch unreachable;
    }

    if (lower != -1 and args.values.items.len < @as(usize, @intCast(lower))) {
        cause.* = xm.xasprintf("too few arguments (need at least {d})", .{lower});
        return ParseError.TooFewArguments;
    }
    if (upper != -1 and args.values.items.len > @as(usize, @intCast(upper))) {
        cause.* = xm.xasprintf("too many arguments (need at most {d})", .{upper});
        return ParseError.TooManyArguments;
    }
    return args;
}

pub fn args_print(args: *const Arguments) []u8 {
    var out: std.ArrayList(u8) = .{};
    const sorted = sorted_flags(args);
    defer xm.allocator.free(sorted);

    var last_optional = false;

    for (sorted) |flag| {
        const entry = args.flags.get(flag).?;
        if (entry.hasOptionalValue()) continue;
        if (entry.values.items.len != 0) continue;

        if (out.items.len == 0) {
            out.append(xm.allocator, '-') catch unreachable;
        }
        for (0..entry.count) |_| out.append(xm.allocator, flag) catch unreachable;
    }

    for (sorted) |flag| {
        const entry = args.flags.get(flag).?;
        if (entry.hasOptionalValue()) {
            if (out.items.len != 0) out.appendSlice(xm.allocator, " ") catch unreachable;
            out.appendSlice(xm.allocator, "-") catch unreachable;
            out.append(xm.allocator, flag) catch unreachable;
            last_optional = true;
            continue;
        }
        if (entry.values.items.len == 0) continue;
        for (entry.values.items) |value| {
            if (out.items.len != 0) out.append(xm.allocator, ' ') catch unreachable;
            out.appendSlice(xm.allocator, "-") catch unreachable;
            out.append(xm.allocator, flag) catch unreachable;
            out.append(xm.allocator, ' ') catch unreachable;
            const escaped = args_escape(value);
            defer xm.allocator.free(escaped);
            out.appendSlice(xm.allocator, escaped) catch unreachable;
        }
        last_optional = false;
    }

    if (last_optional) out.appendSlice(xm.allocator, " --") catch unreachable;

    for (args.values.items) |value| {
        if (out.items.len != 0) out.append(xm.allocator, ' ') catch unreachable;
        const escaped = args_escape(value);
        defer xm.allocator.free(escaped);
        out.appendSlice(xm.allocator, escaped) catch unreachable;
    }

    return out.toOwnedSlice(xm.allocator) catch unreachable;
}

pub fn args_escape(s: []const u8) []u8 {
    const dquoted = " #';${}%";
    const squoted = " \"";

    if (s.len == 0) return xm.xstrdup("''");

    var quotes: u8 = 0;
    if (std.mem.indexOfAny(u8, s, dquoted) != null) {
        quotes = '"';
    } else if (std.mem.indexOfAny(u8, s, squoted) != null) {
        quotes = '\'';
    }

    if (s[0] != ' ' and s.len == 1 and (quotes != 0 or s[0] == '~')) {
        return xm.xasprintf("\\{c}", .{s[0]});
    }

    var flags = utf8.VIS_OCTAL | utf8.VIS_CSTYLE | utf8.VIS_TAB | utf8.VIS_NL;
    if (quotes == '"') flags |= utf8.VIS_DQ;
    const escaped = utf8.utf8_stravis(s, flags);
    defer xm.allocator.free(escaped);

    if (quotes == '\'') return xm.xasprintf("'{s}'", .{escaped});
    if (quotes == '"') {
        if (escaped.len != 0 and escaped[0] == '~') return xm.xasprintf("\"\\{s}\"", .{escaped});
        return xm.xasprintf("\"{s}\"", .{escaped});
    }
    if (escaped.len != 0 and escaped[0] == '~') return xm.xasprintf("\\{s}", .{escaped});
    return xm.xstrdup(escaped);
}

pub fn args_to_vector(alloc: std.mem.Allocator, args: *const Arguments) [][]u8 {
    const result = alloc.alloc([]u8, args.values.items.len) catch unreachable;
    for (args.values.items, 0..) |value, idx| {
        result[idx] = alloc.dupe(u8, value) catch unreachable;
    }
    return result;
}

pub fn args_strtonum(
    args: *const Arguments,
    flag: u8,
    minval: i64,
    maxval: i64,
    cause: *?[]u8,
) i64 {
    const value = args.get(flag) orelse {
        cause.* = xm.xstrdup("missing");
        return 0;
    };
    return parse_long_long(value, minval, maxval, cause);
}

pub fn args_percentage(
    args: *const Arguments,
    flag: u8,
    minval: i64,
    maxval: i64,
    curval: i64,
    cause: *?[]u8,
) i64 {
    const entry = args.entry(flag) orelse {
        cause.* = xm.xstrdup("missing");
        return 0;
    };
    if (entry.values.items.len == 0) {
        cause.* = xm.xstrdup("empty");
        return 0;
    }
    return args_string_percentage(entry.values.items[entry.values.items.len - 1], minval, maxval, curval, cause);
}

pub fn args_string_percentage(
    value: []const u8,
    minval: i64,
    maxval: i64,
    curval: i64,
    cause: *?[]u8,
) i64 {
    if (value.len == 0) {
        cause.* = xm.xstrdup("empty");
        return 0;
    }

    if (value[value.len - 1] == '%') {
        const percent = parse_long_long(value[0 .. value.len - 1], 0, 100, cause);
        if (cause.* != null) return 0;

        const scaled = @divTrunc(curval * percent, 100);
        if (scaled < minval) {
            cause.* = xm.xstrdup("too small");
            return 0;
        }
        if (scaled > maxval) {
            cause.* = xm.xstrdup("too large");
            return 0;
        }
        cause.* = null;
        return scaled;
    }

    return parse_long_long(value, minval, maxval, cause);
}

pub fn args_from_vector(alloc: std.mem.Allocator, argv: []const []const u8) []T.ArgsValue {
    const result = alloc.alloc(T.ArgsValue, argv.len) catch unreachable;
    for (argv, 0..) |arg, idx| {
        result[idx] = .{
            .type = .string,
            .data = .{ .string = xm.xstrdup(arg) },
        };
    }
    return result;
}

fn args_parse_flags(
    args: *Arguments,
    argv: []const []const u8,
    template: []const u8,
    cause: *?[]u8,
    i: *usize,
) !bool {
    const value = argv[i.*];
    if (value.len < 2 or value[0] != '-') return true;

    var string = value[1..];
    if (string.len == 0) return true;
    i.* += 1;
    if (string.len == 1 and string[0] == '-') return true;

    while (true) {
        if (string.len == 0) return false;

        const flag = string[0];
        string = string[1..];

        if (flag == '?') return ParseError.InvalidFlag;
        if (!std.ascii.isAlphanumeric(flag)) {
            cause.* = xm.xasprintf("invalid flag -{c}", .{flag});
            return ParseError.InvalidFlag;
        }

        const info = template_flag(template, flag) orelse {
            cause.* = xm.xasprintf("unknown flag -{c}", .{flag});
            return ParseError.UnknownFlag;
        };

        if (!info.takes_argument) {
            args_set(args, flag, null, 0);
            continue;
        }

        if (string.len != 0) {
            args_set(args, flag, string, 0);
            return false;
        }

        const argument = if (i.* < argv.len) argv[i.*] else null;
        if (argument == null) {
            if (info.optional_argument) {
                args_set(args, flag, null, ARGS_ENTRY_OPTIONAL_VALUE);
                return false;
            }
            cause.* = xm.xasprintf("-{c} expects an argument", .{flag});
            return ParseError.MissingArgument;
        }

        args_set(args, flag, argument.?, 0);
        i.* += 1;
        return false;
    }
}

fn args_set(args: *Arguments, flag: u8, value: ?[]const u8, flags: u32) void {
    const gop = args.flags.getOrPut(flag) catch unreachable;
    if (!gop.found_existing) gop.value_ptr.* = .{};
    gop.value_ptr.count += 1;
    gop.value_ptr.flags |= flags;
    if (value) |string| {
        gop.value_ptr.values.append(args.allocator, args.allocator.dupe(u8, string) catch unreachable) catch unreachable;
    }
}

fn sorted_flags(args: *const Arguments) []u8 {
    var out = xm.allocator.alloc(u8, args.flags.count()) catch unreachable;
    var idx: usize = 0;
    var it = args.flags.keyIterator();
    while (it.next()) |key| : (idx += 1) out[idx] = key.*;
    std.sort.block(u8, out, {}, less_than_u8);
    return out;
}

fn template_flag(template: []const u8, flag: u8) ?struct { takes_argument: bool, optional_argument: bool } {
    const idx = std.mem.indexOfScalar(u8, template, flag) orelse return null;
    const takes_argument = idx + 1 < template.len and template[idx + 1] == ':';
    const optional_argument = takes_argument and idx + 2 < template.len and template[idx + 2] == ':';
    return .{
        .takes_argument = takes_argument,
        .optional_argument = optional_argument,
    };
}

fn parse_long_long(value: []const u8, minval: i64, maxval: i64, cause: *?[]u8) i64 {
    const parsed = std.fmt.parseInt(i128, value, 10) catch |err| {
        cause.* = switch (err) {
            error.Overflow => if (value.len != 0 and value[0] == '-') xm.xstrdup("too small") else xm.xstrdup("too large"),
            else => xm.xstrdup("invalid"),
        };
        return 0;
    };

    if (parsed < minval) {
        cause.* = xm.xstrdup("too small");
        return 0;
    }
    if (parsed > maxval) {
        cause.* = xm.xstrdup("too large");
        return 0;
    }

    cause.* = null;
    return @intCast(parsed);
}

fn less_than_u8(_: void, a: u8, b: u8) bool {
    return a < b;
}

test "args_parse handles stacked flags, values, and positionals" {
    var cause: ?[]u8 = null;
    var args = try args_parse(xm.allocator, &.{ "-ab", "-cvalue", "tail", "tail2" }, "abc:", 2, 2, &cause);
    defer args.deinit();

    try std.testing.expect(cause == null);
    try std.testing.expect(args.has('a'));
    try std.testing.expect(args.has('b'));
    try std.testing.expectEqualStrings("value", args.get('c').?);
    try std.testing.expectEqual(@as(usize, 2), args.count());
    try std.testing.expectEqualStrings("tail", args.value_at(0).?);
    try std.testing.expectEqualStrings("tail2", args.value_at(1).?);
}

test "args_parse records optional flag without value" {
    var cause: ?[]u8 = null;
    var args = try args_parse(xm.allocator, &.{"-f"}, "f::", 0, 0, &cause);
    defer args.deinit();

    try std.testing.expect(cause == null);
    try std.testing.expect(args.has('f'));
    try std.testing.expect(args.get('f') == null);

    const rendered = args_print(&args);
    defer xm.allocator.free(rendered);
    try std.testing.expectEqualStrings("-f --", rendered);
}

test "args_parse stops at double dash and enforces arity" {
    var cause: ?[]u8 = null;
    var args = try args_parse(xm.allocator, &.{ "-a", "--", "-b" }, "a", 1, 1, &cause);
    defer args.deinit();

    try std.testing.expect(cause == null);
    try std.testing.expect(args.has('a'));
    try std.testing.expectEqual(@as(usize, 1), args.count());
    try std.testing.expectEqualStrings("-b", args.value_at(0).?);
}

test "args_escape matches tmux-style shell quoting rules for common cases" {
    const plain = args_escape("plain");
    defer xm.allocator.free(plain);
    try std.testing.expectEqualStrings("plain", plain);

    const spaced = args_escape("hello world");
    defer xm.allocator.free(spaced);
    try std.testing.expectEqualStrings("\"hello world\"", spaced);

    const tilde = args_escape("~");
    defer xm.allocator.free(tilde);
    try std.testing.expectEqualStrings("\\~", tilde);
}

test "args numeric helpers report missing and percentage values" {
    var cause: ?[]u8 = null;
    var args = try args_parse(xm.allocator, &.{ "-x", "25%", "-n", "42" }, "x:n:", 0, 0, &cause);
    defer args.deinit();

    try std.testing.expectEqual(@as(i64, 50), args_percentage(&args, 'x', 1, 100, 200, &cause));
    try std.testing.expect(cause == null);
    try std.testing.expectEqual(@as(i64, 42), args_strtonum(&args, 'n', 1, 100, &cause));
    try std.testing.expect(cause == null);

    _ = args_strtonum(&args, 'm', 0, 10, &cause);
    defer if (cause) |msg| xm.allocator.free(msg);
    try std.testing.expectEqualStrings("missing", cause.?);
}
