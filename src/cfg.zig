// Copyright (c) 2026 Greg Turner <gmt@be-evil.net>
// ISC licence – see COPYING.
// Ported from tmux/cfg.c (config file loading)

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const log = @import("log.zig");
const cmd_mod = @import("cmd.zig");
const cmdq = @import("cmd-queue.zig");

var cfg_file_paths: std.ArrayList([]const u8) = .{};
pub var cfg_nfiles: usize = 0;
pub var cfg_quiet: bool = true;
pub var cfg_finished: bool = false;

pub fn cfg_add_file(path: []const u8) void {
    cfg_file_paths.append(xm.allocator, xm.xstrdup(path)) catch unreachable;
    cfg_nfiles = cfg_file_paths.items.len;
}

pub fn cfg_load() void {
    for (cfg_file_paths.items) |path| {
        log.log_debug("loading config: {s}", .{path});
        if (std.mem.eql(u8, path, "/dev/null")) continue;
        const f = std.fs.cwd().openFile(path, .{}) catch |err| {
            if (!cfg_quiet) log.log_warn("can't open config {s}: {}", .{ path, err });
            continue;
        };
        defer f.close();
        const content = f.readToEndAlloc(xm.allocator, 1024 * 1024) catch |err| {
            if (!cfg_quiet) log.log_warn("can't read config {s}: {}", .{ path, err });
            continue;
        };
        defer xm.allocator.free(content);
        load_string(path, content);
    }
    cfg_finished = true;
}

fn load_string(path: []const u8, content: []const u8) void {
    var lines = std.mem.tokenizeAny(u8, content, "\n");
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        var pi = T.CmdParseInput{ .file = path };
        const result = cmd_mod.cmd_parse_from_string(trimmed, &pi);
        switch (result.status) {
            .@"error" => {
                if (!cfg_quiet) log.log_warn("config error in {s}: {s}", .{ path, result.@"error" orelse "?" });
            },
            .success => {
                if (result.cmdlist) |cl| {
                    const list: *cmd_mod.CmdList = @ptrCast(@alignCast(cl));
                    cmdq.cmdq_append(null, list);
                }
            },
        }
    }
}

pub fn cfg_show_causes() void {}
