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
// Ported in part from tmux/cfg.c
// Original copyright:
//   Copyright (c) 2008 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const log = @import("log.zig");
const cmd_mod = @import("cmd.zig");
const cmdq = @import("cmd-queue.zig");
const server_client_mod = @import("server-client.zig");

pub const CfgFlags = packed struct {
    quiet: bool = false,
    parse_only: bool = false,
    verbose: bool = false,
};

const SOURCE_DEPTH_LIMIT: u32 = 50;

var cfg_file_paths: std.ArrayList([]const u8) = .{};
var cfg_causes: std.ArrayList([]const u8) = .{};
pub var cfg_nfiles: usize = 0;
pub var cfg_quiet: bool = true;
pub var cfg_finished: bool = false;
var cfg_source_depth: u32 = 0;

pub fn cfg_reset_files() void {
    for (cfg_file_paths.items) |path| xm.allocator.free(path);
    cfg_file_paths.clearRetainingCapacity();
    cfg_nfiles = 0;
}

pub fn cfg_add_file(path: []const u8) void {
    cfg_file_paths.append(xm.allocator, xm.xstrdup(path)) catch unreachable;
    cfg_nfiles = cfg_file_paths.items.len;
}

pub fn cfg_add_defaults() void {
    var it = std.mem.splitScalar(u8, T.ZMUX_CONF, ':');
    while (it.next()) |raw| {
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (trimmed.len == 0) continue;
        const expanded = expand_default_path(trimmed) orelse continue;
        cfg_add_file(expanded);
        xm.allocator.free(expanded);
    }
}

pub fn cfg_load(cl: ?*T.Client) void {
    cfg_clear_causes();
    for (cfg_file_paths.items) |path| {
        _ = cfg_source_path(cl, path, .{ .quiet = cfg_quiet });
    }
    cfg_finished = true;
    cfg_show_causes(cl);
}

pub fn cfg_source_path(cl: ?*T.Client, raw_path: []const u8, flags: CfgFlags) bool {
    if (cfg_source_depth >= SOURCE_DEPTH_LIMIT) {
        cfg_note_cause("too many nested files", .{}, flags.quiet);
        return false;
    }
    cfg_source_depth += 1;
    defer cfg_source_depth -= 1;

    if (std.mem.eql(u8, raw_path, "-")) {
        cfg_note_cause("source-file - not supported yet", .{}, flags.quiet);
        return false;
    }

    const resolved = resolve_path(cl, raw_path);
    defer if (resolved.owned) xm.allocator.free(resolved.path);

    if (flags.verbose) cmdq.cmdq_write_client(cl, 1, "source-file: {s}", .{resolved.path});
    if (std.mem.eql(u8, resolved.path, "/dev/null")) return true;

    const file = std.fs.cwd().openFile(resolved.path, .{}) catch |err| {
        if (!flags.quiet) cfg_note_cause("{s}: {}", .{ resolved.path, err }, false);
        return false;
    };
    defer file.close();

    const content = file.readToEndAlloc(xm.allocator, 1024 * 1024) catch |err| {
        if (!flags.quiet) cfg_note_cause("{s}: {}", .{ resolved.path, err }, false);
        return false;
    };
    defer xm.allocator.free(content);

    return cfg_load_buffer(cl, resolved.path, content, flags);
}

pub fn cfg_show_causes(cl: ?*T.Client) void {
    for (cfg_causes.items) |cause| {
        cmdq.cmdq_write_client(cl, 2, "{s}", .{cause});
        xm.allocator.free(cause);
    }
    cfg_causes.clearRetainingCapacity();
}

fn cfg_load_buffer(cl: ?*T.Client, path: []const u8, content: []const u8, flags: CfgFlags) bool {
    var ok = true;
    var lines = std.mem.splitScalar(u8, content, '\n');
    var line_no: usize = 0;
    while (lines.next()) |line| {
        line_no += 1;
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        if (flags.verbose) {
            cmdq.cmdq_write_client(cl, 1, "{s}:{d}: {s}", .{ path, line_no, trimmed });
        }

        var pi = T.CmdParseInput{ .file = path };
        const result = cmd_mod.cmd_parse_from_string(trimmed, &pi);
        switch (result.status) {
            .@"error" => {
                cfg_note_cause("{s}:{d}: {s}", .{ path, line_no, result.@"error" orelse "parse error" }, flags.quiet);
                ok = false;
            },
            .success => {
                if (result.cmdlist) |cl_ptr| {
                    const list: *cmd_mod.CmdList = @ptrCast(@alignCast(cl_ptr));
                    if (flags.parse_only)
                        cmd_mod.cmd_list_free(list)
                    else if (cmdq.cmdq_run_immediate(cl, list) == .@"error")
                        ok = false;
                }
            },
        }
    }
    return ok;
}

fn cfg_clear_causes() void {
    for (cfg_causes.items) |cause| xm.allocator.free(cause);
    cfg_causes.clearRetainingCapacity();
}

fn cfg_note_cause(comptime fmt: []const u8, args: anytype, quiet: bool) void {
    if (quiet) return;
    cfg_causes.append(xm.allocator, xm.xasprintf(fmt, args)) catch unreachable;
}

fn expand_default_path(path: []const u8) ?[]u8 {
    if (std.mem.startsWith(u8, path, "~/")) {
        const home = std.posix.getenv("HOME") orelse return null;
        return xm.xasprintf("{s}/{s}", .{ home, path[2..] });
    }
    if (std.mem.eql(u8, path, "~")) {
        const home = std.posix.getenv("HOME") orelse return null;
        return xm.xstrdup(home);
    }
    if (std.mem.startsWith(u8, path, "$XDG_CONFIG_HOME/")) {
        const base = std.posix.getenv("XDG_CONFIG_HOME") orelse return null;
        return xm.xasprintf("{s}/{s}", .{ base, path["$XDG_CONFIG_HOME/".len..] });
    }
    return xm.xstrdup(path);
}

const ResolvedPath = struct {
    path: []const u8,
    owned: bool = false,
};

fn resolve_path(cl: ?*T.Client, raw_path: []const u8) ResolvedPath {
    if (std.mem.startsWith(u8, raw_path, "/")) return .{ .path = raw_path };
    if (std.mem.startsWith(u8, raw_path, "~/") or std.mem.eql(u8, raw_path, "~")) {
        if (expand_default_path(raw_path)) |expanded| return .{ .path = expanded, .owned = true };
    }
    const cwd = server_client_mod.server_client_get_cwd(cl, null);
    return .{ .path = xm.xasprintf("{s}/{s}", .{ cwd, raw_path }), .owned = true };
}

test "cfg default path expansion handles home and xdg" {
    cfg_reset_files();
    defer cfg_reset_files();

    const home = std.posix.getenv("HOME") orelse return error.SkipZigTest;
    const xdg = std.posix.getenv("XDG_CONFIG_HOME");

    const expanded_home = expand_default_path("~/.zmux.conf").?;
    defer xm.allocator.free(expanded_home);
    try std.testing.expectEqualStrings(home, expanded_home[0..home.len]);

    if (xdg) |base| {
        const expanded_xdg = expand_default_path("$XDG_CONFIG_HOME/zmux/zmux.conf").?;
        defer xm.allocator.free(expanded_xdg);
        try std.testing.expectEqualStrings(base, expanded_xdg[0..base.len]);
    }
}

test "cfg parse only does not enqueue commands" {
    cfg_clear_causes();
    defer cfg_clear_causes();

    const content = "set-option status off\n";
    try std.testing.expect(cfg_load_buffer(null, "/tmp/test.conf", content, .{ .parse_only = true }));
}
