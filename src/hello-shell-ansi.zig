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

const std = @import("std");

const helper_mode_var = "ZMUX_SMOKE_HELPER_MODE";
const helper_path_var = "ZMUX_SMOKE_HELPER_PATH";

const Mode = enum {
    idle,
    exit_on_exit_line,
    record_stdin,
    activity_bell,
    echo_stdin,
    emit_sixel,
};

fn parseMode(raw: []const u8) ?Mode {
    if (std.mem.eql(u8, raw, "idle")) return .idle;
    if (std.mem.eql(u8, raw, "exit-on-exit-line")) return .exit_on_exit_line;
    if (std.mem.eql(u8, raw, "record-stdin")) return .record_stdin;
    if (std.mem.eql(u8, raw, "activity-bell")) return .activity_bell;
    if (std.mem.eql(u8, raw, "echo-stdin")) return .echo_stdin;
    if (std.mem.eql(u8, raw, "emit-sixel")) return .emit_sixel;
    return null;
}

fn currentMode() Mode {
    const raw = std.posix.getenv(helper_mode_var) orelse "idle";
    return parseMode(raw) orelse .idle;
}

fn startupBanner(mode: Mode) []const u8 {
    return switch (mode) {
        .echo_stdin, .emit_sixel => "",
        else => "\x1b[0mhello-shell-ansi ready\r\n",
    };
}

fn trimmedLine(line: []const u8) []const u8 {
    return std.mem.trimRight(u8, line, "\r");
}

fn writeRecord(line: []const u8) !void {
    const path = std.posix.getenv(helper_path_var) orelse return error.MissingRecordPath;
    const file = try std.fs.createFileAbsolute(path, .{ .read = true, .truncate = false });
    defer file.close();
    try file.seekFromEnd(0);
    try file.writeAll(line);
    try file.writeAll("\n");
}

fn runLineMode(mode: Mode) !void {
    const stdin_file = std.fs.File.stdin();
    const stdout_file = std.fs.File.stdout();
    const banner = startupBanner(mode);
    if (banner.len != 0) try stdout_file.writeAll(banner);
    var pending = std.ArrayList(u8){};
    defer pending.deinit(std.heap.page_allocator);
    var buf: [1024]u8 = undefined;

    while (true) {
        const got = try stdin_file.read(&buf);
        if (got == 0) {
            if (pending.items.len == 0) return;
            const line = trimmedLine(pending.items);
            switch (mode) {
                .idle => {},
                .exit_on_exit_line => if (std.mem.eql(u8, line, "exit")) return,
                .record_stdin => try writeRecord(line),
                .activity_bell => {
                    if (std.mem.eql(u8, line, "activity")) {
                        try stdout_file.writeAll("activity\r\n");
                    } else if (std.mem.eql(u8, line, "bell")) {
                        try stdout_file.writeAll("\x07");
                    } else if (std.mem.eql(u8, line, "exit")) {
                        return;
                    }
                },
                .echo_stdin, .emit_sixel => unreachable,
            }
            return;
        }

        for (buf[0..got]) |byte| {
            if (byte != '\n') {
                try pending.append(std.heap.page_allocator, byte);
                continue;
            }
            const line = trimmedLine(pending.items);
            switch (mode) {
                .idle => {},
                .exit_on_exit_line => {
                    if (std.mem.eql(u8, line, "exit")) return;
                },
                .record_stdin => try writeRecord(line),
                .activity_bell => {
                    if (std.mem.eql(u8, line, "activity")) {
                        try stdout_file.writeAll("activity\r\n");
                    } else if (std.mem.eql(u8, line, "bell")) {
                        try stdout_file.writeAll("\x07");
                    } else if (std.mem.eql(u8, line, "exit")) {
                        return;
                    }
                },
                .echo_stdin, .emit_sixel => unreachable,
            }
            pending.clearRetainingCapacity();
        }
    }
}

fn runEchoMode() !void {
    const stdin_file = std.fs.File.stdin();
    const stdout_file = std.fs.File.stdout();
    var buf: [4096]u8 = undefined;
    while (true) {
        const got = try stdin_file.read(&buf);
        if (got == 0) return;
        try stdout_file.writeAll(buf[0..got]);
    }
}

fn runEmitSixelMode() !void {
    const stdout_file = std.fs.File.stdout();
    try stdout_file.writeAll("\x1bPq#0;2;100;0;0!4~-!4~\x1b\\");
    try runLineMode(.idle);
}

pub fn main() !void {
    const mode = currentMode();
    switch (mode) {
        .echo_stdin => try runEchoMode(),
        .emit_sixel => try runEmitSixelMode(),
        else => try runLineMode(mode),
    }
}
