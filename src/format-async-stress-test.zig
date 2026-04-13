const std = @import("std");
const builtin = @import("builtin");
const T = @import("types.zig");
const c = @import("c.zig");
const env_mod = @import("environ.zig");
const format = @import("format.zig");
const proc_mod = @import("proc.zig");
const os_mod = @import("os/linux.zig");

const TestClientContext = struct {
    client: T.Client,
    ctx: format.FormatContext,

    fn init(self: *TestClientContext, cwd: []const u8) void {
        self.* = .{
            .client = T.Client{
                .environ = env_mod.environ_create(),
                .tty = undefined,
                .status = .{},
                .cwd = cwd,
            },
            .ctx = .{},
        };
        self.client.tty = .{ .client = &self.client };
        self.ctx = .{ .client = &self.client };
    }

    fn deinit(self: *TestClientContext) void {
        env_mod.environ_free(self.client.environ);
    }
};

fn installEventBase() ?*c.libevent.event_base {
    const old_base = proc_mod.libevent;
    proc_mod.libevent = os_mod.osdep_event_init();
    return old_base;
}

fn restoreEventBase(old_base: ?*c.libevent.event_base) void {
    if (proc_mod.libevent) |base| c.libevent.event_base_free(base);
    proc_mod.libevent = old_base;
}

fn expandTemplate(alloc: std.mem.Allocator, template: []const u8, ctx: *const format.FormatContext) ![]u8 {
    return format.format_require_complete(alloc, template, ctx) orelse error.TestUnexpectedResult;
}

fn pumpAsyncNonblock() void {
    if (proc_mod.libevent) |base|
        _ = c.libevent.event_base_loop(base, c.libevent.EVLOOP_NONBLOCK);
}

fn waitForFormatValue(template: []const u8, ctx: *const format.FormatContext, expected: []const u8) !void {
    for (0..400) |_| {
        const expanded = try expandTemplate(std.testing.allocator, template, ctx);
        defer std.testing.allocator.free(expanded);
        if (std.mem.eql(u8, expanded, expected)) return;
        pumpAsyncNonblock();
        std.Thread.sleep(5 * std.time.ns_per_ms);
    }
    return error.TestUnexpectedResult;
}

fn waitForFileContents(path: []const u8, expected: []const u8) !void {
    for (0..400) |_| {
        const actual = try readFileOrEmpty(std.testing.allocator, path);
        defer std.testing.allocator.free(actual);
        if (std.mem.eql(u8, actual, expected)) return;
        pumpAsyncNonblock();
        std.Thread.sleep(5 * std.time.ns_per_ms);
    }
    return error.TestUnexpectedResult;
}

fn readFileOrEmpty(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return alloc.dupe(u8, ""),
        else => return err,
    };
    defer file.close();
    return file.readToEndAlloc(alloc, 1024);
}

fn tmpChildPath(alloc: std.mem.Allocator, dir: std.fs.Dir, child: []const u8) ![]u8 {
    const root = try dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);
    return std.fs.path.join(alloc, &.{ root, child });
}

test "format async shell collects output and trims trailing newlines" {
    if (builtin.os.tag != .linux) return;

    const old_base = installEventBase();
    defer restoreEventBase(old_base);

    var client_ctx: TestClientContext = undefined;
    client_ctx.init("/");
    defer client_ctx.deinit();

    try waitForFormatValue("#(printf 'alpha\\n')", &client_ctx.ctx, "alpha");
}

test "format async shell reports slow commands as not ready after one second" {
    if (builtin.os.tag != .linux) return;

    const old_base = installEventBase();
    defer restoreEventBase(old_base);

    var client_ctx: TestClientContext = undefined;
    client_ctx.init("/");
    defer client_ctx.deinit();

    const template = "#(sleep 2.5; printf late)";

    const initial = try expandTemplate(std.testing.allocator, template, &client_ctx.ctx);
    defer std.testing.allocator.free(initial);
    try std.testing.expectEqualStrings("", initial);

    try waitForFormatValue(template, &client_ctx.ctx, "<'sleep 2.5; printf late' not ready>");
    try waitForFormatValue(template, &client_ctx.ctx, "late");
}

test "format async shell completion order keeps concurrent caches isolated" {
    if (builtin.os.tag != .linux) return;

    const old_base = installEventBase();
    defer restoreEventBase(old_base);

    var client_ctx: TestClientContext = undefined;
    client_ctx.init("/");
    defer client_ctx.deinit();

    const fast_template = "#(sleep 0.02; printf fast)";
    const slow_template = "#(sleep 0.4; printf slow)";

    const fast_initial = try expandTemplate(std.testing.allocator, fast_template, &client_ctx.ctx);
    defer std.testing.allocator.free(fast_initial);
    try std.testing.expectEqualStrings("", fast_initial);

    const slow_initial = try expandTemplate(std.testing.allocator, slow_template, &client_ctx.ctx);
    defer std.testing.allocator.free(slow_initial);
    try std.testing.expectEqualStrings("", slow_initial);

    try waitForFormatValue(fast_template, &client_ctx.ctx, "fast");

    const slow_while_fast_is_done = try expandTemplate(std.testing.allocator, slow_template, &client_ctx.ctx);
    defer std.testing.allocator.free(slow_while_fast_is_done);
    try std.testing.expectEqualStrings("", slow_while_fast_is_done);

    try waitForFormatValue(slow_template, &client_ctx.ctx, "slow");

    const fast_again = try expandTemplate(std.testing.allocator, fast_template, &client_ctx.ctx);
    defer std.testing.allocator.free(fast_again);
    try std.testing.expectEqualStrings("fast", fast_again);
}

test "format async shell rapid re-expansion does not respawn a running job" {
    if (builtin.os.tag != .linux) return;

    const old_base = installEventBase();
    defer restoreEventBase(old_base);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const count_path = try tmpChildPath(std.testing.allocator, tmp.dir, "run-count");
    defer std.testing.allocator.free(count_path);

    const cmd = try std.fmt.allocPrint(std.testing.allocator, "printf x >> '{s}'; sleep 0.1; printf ready", .{count_path});
    defer std.testing.allocator.free(cmd);
    const template = try std.fmt.allocPrint(std.testing.allocator, "#({s})", .{cmd});
    defer std.testing.allocator.free(template);

    var client_ctx: TestClientContext = undefined;
    client_ctx.init("/");
    defer client_ctx.deinit();

    for (0..12) |_| {
        const expanded = try expandTemplate(std.testing.allocator, template, &client_ctx.ctx);
        defer std.testing.allocator.free(expanded);
        try std.testing.expectEqualStrings("", expanded);
    }

    try waitForFormatValue(template, &client_ctx.ctx, "ready");
    try waitForFileContents(count_path, "x");

    for (0..6) |_| {
        const expanded = try expandTemplate(std.testing.allocator, template, &client_ctx.ctx);
        defer std.testing.allocator.free(expanded);
        try std.testing.expectEqualStrings("ready", expanded);
    }

    const count = try readFileOrEmpty(std.testing.allocator, count_path);
    defer std.testing.allocator.free(count);
    try std.testing.expectEqualStrings("x", count);
}

test "format async shell refreshes cached output after the one-second launch window" {
    if (builtin.os.tag != .linux) return;

    const old_base = installEventBase();
    defer restoreEventBase(old_base);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const count_path = try tmpChildPath(std.testing.allocator, tmp.dir, "run-count");
    defer std.testing.allocator.free(count_path);

    const cmd = try std.fmt.allocPrint(std.testing.allocator, "printf x >> '{s}'; printf fresh", .{count_path});
    defer std.testing.allocator.free(cmd);
    const template = try std.fmt.allocPrint(std.testing.allocator, "#({s})", .{cmd});
    defer std.testing.allocator.free(template);

    var client_ctx: TestClientContext = undefined;
    client_ctx.init("/");
    defer client_ctx.deinit();

    try waitForFormatValue(template, &client_ctx.ctx, "fresh");
    try waitForFileContents(count_path, "x");

    std.Thread.sleep(1100 * std.time.ns_per_ms);
    const cached = try expandTemplate(std.testing.allocator, template, &client_ctx.ctx);
    defer std.testing.allocator.free(cached);
    try std.testing.expectEqualStrings("fresh", cached);

    try waitForFileContents(count_path, "xx");
}

test "format async shell caches completed no-output jobs as empty strings" {
    if (builtin.os.tag != .linux) return;

    const old_base = installEventBase();
    defer restoreEventBase(old_base);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const count_path = try tmpChildPath(std.testing.allocator, tmp.dir, "run-count");
    defer std.testing.allocator.free(count_path);

    const cmd = try std.fmt.allocPrint(std.testing.allocator, "printf x >> '{s}'", .{count_path});
    defer std.testing.allocator.free(cmd);
    const template = try std.fmt.allocPrint(std.testing.allocator, "#({s})", .{cmd});
    defer std.testing.allocator.free(template);

    var client_ctx: TestClientContext = undefined;
    client_ctx.init("/");
    defer client_ctx.deinit();

    const initial = try expandTemplate(std.testing.allocator, template, &client_ctx.ctx);
    defer std.testing.allocator.free(initial);
    try std.testing.expectEqualStrings("", initial);

    try waitForFileContents(count_path, "x");
    std.Thread.sleep(50 * std.time.ns_per_ms);
    pumpAsyncNonblock();

    for (0..6) |_| {
        const expanded = try expandTemplate(std.testing.allocator, template, &client_ctx.ctx);
        defer std.testing.allocator.free(expanded);
        try std.testing.expectEqualStrings("", expanded);
    }

    const count = try readFileOrEmpty(std.testing.allocator, count_path);
    defer std.testing.allocator.free(count);
    try std.testing.expectEqualStrings("x", count);
}
