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
// Reduced attached-client editor handoff for popup-editor consumers.

const std = @import("std");
const opts = @import("options.zig");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");

pub const CloseCallback = *const fn (?[]u8, ?*anyopaque) void;

const PendingEdit = struct {
    client: *T.Client,
    path: []u8,
    cb: CloseCallback,
    arg: ?*anyopaque,
};

var pending_edits: std.ArrayListUnmanaged(PendingEdit) = .{};
var next_file_id: u64 = 0;

pub var test_editor_override: ?[]const u8 = null;
pub var test_tmpdir_override: ?[]const u8 = null;

pub fn begin(client: *T.Client, initial: []const u8, cb: CloseCallback, arg: ?*anyopaque) ?[]u8 {
    if (findPending(client) != null) return null;

    const editor = test_editor_override orelse opts.options_get_string(opts.global_options, "editor");
    if (editor.len == 0) return null;

    const path = createTempFile(client, initial) catch return null;

    pending_edits.append(xm.allocator, .{
        .client = client,
        .path = path,
        .cb = cb,
        .arg = arg,
    }) catch {
        std.fs.deleteFileAbsolute(path) catch {};
        xm.allocator.free(path);
        return null;
    };

    return xm.xasprintf("{s} {s}", .{ editor, path });
}

pub fn handleUnlock(client: *T.Client, status: i32) void {
    const index = findPending(client) orelse return;
    finish(index, status);
}

pub fn clearClient(client: *T.Client) void {
    const index = findPending(client) orelse return;
    finish(index, 1);
}

fn finish(index: usize, status: i32) void {
    var pending = pending_edits.swapRemove(index);
    defer {
        std.fs.deleteFileAbsolute(pending.path) catch {};
        xm.allocator.free(pending.path);
    }

    if (status != 0) {
        pending.cb(null, pending.arg);
        return;
    }

    const file = std.fs.openFileAbsolute(pending.path, .{}) catch {
        pending.cb(null, pending.arg);
        return;
    };
    defer file.close();

    const stat = file.stat() catch {
        pending.cb(null, pending.arg);
        return;
    };
    if (stat.size == 0) {
        pending.cb(null, pending.arg);
        return;
    }

    const max_len: usize = @intCast(stat.size);
    const data = file.readToEndAlloc(xm.allocator, max_len) catch {
        pending.cb(null, pending.arg);
        return;
    };
    if (data.len == 0) {
        xm.allocator.free(data);
        pending.cb(null, pending.arg);
        return;
    }

    pending.cb(data, pending.arg);
}

fn createTempFile(client: *T.Client, initial: []const u8) ![]u8 {
    const tmpdir = test_tmpdir_override orelse (std.posix.getenv("ZMUX_TMPDIR") orelse "/tmp");
    var dir = try std.fs.openDirAbsolute(tmpdir, .{});
    defer dir.close();

    var attempts: usize = 0;
    while (attempts < 32) : (attempts += 1) {
        const filename = xm.xasprintf(
            "zmux-editor-{d}-{d}-{d}",
            .{ client.id, std.os.linux.getpid(), next_file_id },
        );
        next_file_id += 1;
        defer xm.allocator.free(filename);

        const file = dir.createFile(filename, .{
            .read = true,
            .truncate = true,
            .exclusive = true,
            .mode = 0o600,
        }) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return err,
        };
        defer file.close();

        if (initial.len != 0)
            try file.writeAll(initial);

        return xm.xasprintf("{s}/{s}", .{ tmpdir, filename });
    }

    return error.PathAlreadyExists;
}

fn findPending(client: *T.Client) ?usize {
    for (pending_edits.items, 0..) |pending, idx| {
        if (pending.client == client) return idx;
    }
    return null;
}

pub fn resetForTests() void {
    while (pending_edits.items.len != 0) {
        const pending = pending_edits.swapRemove(pending_edits.items.len - 1);
        std.fs.deleteFileAbsolute(pending.path) catch {};
        xm.allocator.free(pending.path);
    }
    pending_edits.deinit(xm.allocator);
    pending_edits = .{};
    next_file_id = 0;
    test_editor_override = null;
    test_tmpdir_override = null;
}

test "editor handoff returns file content to the unlock callback" {
    const env_mod = @import("environ.zig");

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmpdir = try tmp.dir.realpathAlloc(xm.allocator, ".");
    defer xm.allocator.free(tmpdir);

    test_tmpdir_override = tmpdir;
    test_editor_override = "/bin/sh";
    defer resetForTests();

    const environ = env_mod.environ_create();
    defer env_mod.environ_free(environ);

    var client = T.Client{
        .id = 7,
        .environ = environ,
        .tty = undefined,
        .status = .{},
    };
    client.tty = .{ .client = &client };

    const capture = struct {
        var seen: ?[]u8 = null;

        fn close(buf: ?[]u8, _: ?*anyopaque) void {
            seen = buf;
        }
    };
    defer if (capture.seen) |buf| xm.allocator.free(buf);

    const command = begin(&client, "before\n", capture.close, null) orelse return error.TestUnexpectedResult;
    defer xm.allocator.free(command);

    const path = command["/bin/sh ".len..];
    const file = try std.fs.createFileAbsolute(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll("after\n");

    handleUnlock(&client, 0);
    try std.testing.expectEqualStrings("after\n", capture.seen.?);
}

test "editor handoff reports a failed editor exit as no save" {
    const env_mod = @import("environ.zig");

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmpdir = try tmp.dir.realpathAlloc(xm.allocator, ".");
    defer xm.allocator.free(tmpdir);

    test_tmpdir_override = tmpdir;
    test_editor_override = "/bin/sh";
    defer resetForTests();

    const environ = env_mod.environ_create();
    defer env_mod.environ_free(environ);

    var client = T.Client{
        .id = 9,
        .environ = environ,
        .tty = undefined,
        .status = .{},
    };
    client.tty = .{ .client = &client };

    const capture = struct {
        var called = false;
        var saw_null = false;

        fn close(buf: ?[]u8, _: ?*anyopaque) void {
            called = true;
            saw_null = buf == null;
            if (buf) |owned| xm.allocator.free(owned);
        }
    };

    const command = begin(&client, "before\n", capture.close, null) orelse return error.TestUnexpectedResult;
    defer xm.allocator.free(command);

    handleUnlock(&client, 1);
    try std.testing.expect(capture.called);
    try std.testing.expect(capture.saw_null);
}
