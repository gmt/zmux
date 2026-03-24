// Copyright (c) 2026 Greg Turner <gmt@pobox.com>
// ISC licence – see COPYING.
//
// Ported from tmux/arguments.c
// Original copyright:
//   Copyright (c) 2010 Jonathan Alvarado <radobobol@gmail.com>
//   ISC licence – same terms as above.

//! arguments.zig – command argument parsing.

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");

pub const Arguments = struct {
    allocator: std.mem.Allocator,
    flags: std.AutoHashMap(u8, std.ArrayList([]u8)),
    values: std.ArrayList([]u8),

    pub fn init(alloc: std.mem.Allocator) Arguments {
        return .{
            .allocator = alloc,
            .flags = std.AutoHashMap(u8, std.ArrayList([]u8)).init(alloc),
            .values = .{},
        };
    }

    pub fn deinit(self: *Arguments) void {
        var it = self.flags.valueIterator();
        while (it.next()) |list| {
            for (list.items) |s| self.allocator.free(s);
            list.deinit(self.allocator);
        }
        self.flags.deinit();
        for (self.values.items) |s| self.allocator.free(s);
        self.values.deinit(self.allocator);
    }

    pub fn has(self: *const Arguments, flag: u8) bool {
        return self.flags.contains(flag);
    }

    pub fn get(self: *const Arguments, flag: u8) ?[]const u8 {
        const list = self.flags.get(flag) orelse return null;
        if (list.items.len == 0) return null;
        return list.items[list.items.len - 1];
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
    _ = lower;
    _ = upper;

    var args = Arguments.init(alloc);

    var i: usize = 0;
    while (i < argv.len) {
        const arg = argv[i];
        if (arg.len >= 2 and arg[0] == '-') {
            const flag = arg[1];
            if (flag == '-') { i += 1; break; }
            if (flag == 'h') { i += 1; continue; }

            const flag_idx = std.mem.indexOfScalar(u8, template, flag);
            if (flag_idx == null) {
                cause.* = xm.xasprintf("unknown option: -{c}", .{flag});
                args.deinit();
                return error.UnknownOption;
            }
            const takes_arg = flag_idx.? + 1 < template.len and template[flag_idx.? + 1] == ':';

            const gop = args.flags.getOrPut(flag) catch unreachable;
            if (!gop.found_existing) {
                gop.value_ptr.* = .{};
            }

            if (takes_arg) {
                // Value is either inline (rest of this token) or next argv element
                const value = if (arg.len > 2) arg[2..] else blk: {
                    i += 1;
                    if (i >= argv.len) {
                        cause.* = xm.xasprintf("option -{c} requires an argument", .{flag});
                        args.deinit();
                        return error.MissingArgument;
                    }
                    break :blk argv[i];
                };
                gop.value_ptr.append(alloc, xm.xstrdup(value)) catch unreachable;
            } else {
                gop.value_ptr.append(alloc, xm.xstrdup("")) catch unreachable;
            }
        } else {
            args.values.append(alloc, xm.xstrdup(arg)) catch unreachable;
        }
        i += 1;
    }
    while (i < argv.len) : (i += 1) {
        args.values.append(alloc, xm.xstrdup(argv[i])) catch unreachable;
    }

    return args;
}

pub fn args_from_vector(alloc: std.mem.Allocator, argv: []const []const u8) []T.ArgsValue {
    const result = alloc.alloc(T.ArgsValue, argv.len) catch unreachable;
    for (argv, 0..) |arg, idx| {
        result[idx] = .{
            .@"type" = .string,
            .data = .{ .string = xm.xstrdup(arg) },
        };
    }
    return result;
}
