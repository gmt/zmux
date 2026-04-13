const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const cmd_mod = @import("cmd.zig");
const cmdq = @import("cmd-queue.zig");
const paste_mod = @import("paste.zig");
const file_mod = @import("file.zig");
const cmd_source_file = @import("cmd-source-file.zig");

test "source-file waits for detached client reads and loads remote content" {
    try cmd_source_file.StressTests.sourceFileWaitsForDetachedClientReadsAndLoadsRemoteContent();
}

test "source-file glob nomatch without -q returns error" {
    paste_mod.paste_reset_for_tests();
    defer paste_mod.paste_reset_for_tests();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try tmp.dir.realpathAlloc(xm.allocator, ".");
    defer xm.allocator.free(cwd);

    var env = T.Environ.init(xm.allocator);
    defer env.deinit();
    var client = T.Client{
        .environ = &env,
        .tty = undefined,
        .status = .{},
        .cwd = cwd,
    };

    var cause: ?[]u8 = null;
    defer if (cause) |msg| xm.allocator.free(msg);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &client, .cmdlist = &list };

    // Without -q, a nomatch glob must yield an error return.
    const cmd = try cmd_mod.cmd_parse_one(&.{ "source-file", "*.nonexistent" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);

    try std.testing.expectEqual(T.CmdRetval.@"error", cmd_mod.cmd_execute(cmd, &item));
}

test "source-file multiple path arguments sources all files" {
    paste_mod.paste_reset_for_tests();
    defer paste_mod.paste_reset_for_tests();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "alpha.conf", .data = "set-buffer -b alpha val-alpha\n" });
    try tmp.dir.writeFile(.{ .sub_path = "beta.conf", .data = "set-buffer -b beta val-beta\n" });
    try tmp.dir.writeFile(.{ .sub_path = "gamma.conf", .data = "set-buffer -b gamma val-gamma\n" });

    const cwd = try tmp.dir.realpathAlloc(xm.allocator, ".");
    defer xm.allocator.free(cwd);

    var env = T.Environ.init(xm.allocator);
    defer env.deinit();
    var client = T.Client{
        .environ = &env,
        .tty = undefined,
        .status = .{},
        .cwd = cwd,
    };

    var cause: ?[]u8 = null;
    defer if (cause) |msg| xm.allocator.free(msg);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &client, .cmdlist = &list };

    const cmd = try cmd_mod.cmd_parse_one(
        &.{ "source-file", "alpha.conf", "beta.conf", "gamma.conf" },
        null,
        &cause,
    );
    defer cmd_mod.cmd_free(cmd);

    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));

    const a = paste_mod.paste_get_name("alpha") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("val-alpha", paste_mod.paste_buffer_data(a, null));

    const b = paste_mod.paste_get_name("beta") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("val-beta", paste_mod.paste_buffer_data(b, null));

    const g = paste_mod.paste_get_name("gamma") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("val-gamma", paste_mod.paste_buffer_data(g, null));
}

test "source-file missing absolute path returns error" {
    paste_mod.paste_reset_for_tests();
    defer paste_mod.paste_reset_for_tests();

    var env = T.Environ.init(xm.allocator);
    defer env.deinit();
    var client = T.Client{
        .environ = &env,
        .tty = undefined,
        .status = .{},
        .cwd = "/tmp",
    };

    var cause: ?[]u8 = null;
    defer if (cause) |msg| xm.allocator.free(msg);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &client, .cmdlist = &list };

    const cmd = try cmd_mod.cmd_parse_one(
        &.{ "source-file", "/tmp/zmux-stress-test-nonexistent-path-3829172.conf" },
        null,
        &cause,
    );
    defer cmd_mod.cmd_free(cmd);

    try std.testing.expectEqual(T.CmdRetval.@"error", cmd_mod.cmd_execute(cmd, &item));
}

test "source-file cwd with glob metacharacters resolves correctly" {
    paste_mod.paste_reset_for_tests();
    defer paste_mod.paste_reset_for_tests();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create a subdirectory whose name contains glob metacharacters.
    tmp.dir.makeDir("conf[v1]") catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };
    var sub = try tmp.dir.openDir("conf[v1]", .{});
    defer sub.close();

    try sub.writeFile(.{ .sub_path = "load.conf", .data = "set-buffer -b metachar loaded-meta\n" });

    const sub_path = try tmp.dir.realpathAlloc(xm.allocator, "conf[v1]");
    defer xm.allocator.free(sub_path);

    var env = T.Environ.init(xm.allocator);
    defer env.deinit();
    var client = T.Client{
        .environ = &env,
        .tty = undefined,
        .status = .{},
        .cwd = sub_path,
    };

    var cause: ?[]u8 = null;
    defer if (cause) |msg| xm.allocator.free(msg);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &client, .cmdlist = &list };

    const cmd = try cmd_mod.cmd_parse_one(&.{ "source-file", "load.conf" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);

    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));

    const pb = paste_mod.paste_get_name("metachar") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("loaded-meta", paste_mod.paste_buffer_data(pb, null));
}

test "source-file empty file returns normal" {
    paste_mod.paste_reset_for_tests();
    defer paste_mod.paste_reset_for_tests();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "empty.conf", .data = "" });

    const cwd = try tmp.dir.realpathAlloc(xm.allocator, ".");
    defer xm.allocator.free(cwd);

    var env = T.Environ.init(xm.allocator);
    defer env.deinit();
    var client = T.Client{
        .environ = &env,
        .tty = undefined,
        .status = .{},
        .cwd = cwd,
    };

    var cause: ?[]u8 = null;
    defer if (cause) |msg| xm.allocator.free(msg);

    var list: cmd_mod.CmdList = .{};
    var item = cmdq.CmdqItem{ .client = &client, .cmdlist = &list };

    const cmd = try cmd_mod.cmd_parse_one(&.{ "source-file", "empty.conf" }, null, &cause);
    defer cmd_mod.cmd_free(cmd);

    try std.testing.expectEqual(T.CmdRetval.normal, cmd_mod.cmd_execute(cmd, &item));
}
