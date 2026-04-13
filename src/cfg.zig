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
const file_mod = @import("file.zig");
const opts = @import("options.zig");

extern fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern fn unsetenv(name: [*:0]const u8) c_int;

pub const CfgFlags = packed struct {
    quiet: bool = false,
    parse_only: bool = false,
    verbose: bool = false,
};

const SOURCE_DEPTH_LIMIT: u32 = 50;

pub var cfg_file_paths: std.ArrayList([]const u8) = .{};
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
    const zmux_mod = @import("zmux.zig");
    var it = std.mem.splitScalar(u8, zmux_mod.compat_conf_paths(), ':');
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

    const resolved = file_mod.resolvePath(cl, raw_path);
    defer if (resolved.owned) xm.allocator.free(resolved.path);

    if (flags.verbose) cmdq.cmdq_write_client(cl, 1, "source-file: {s}", .{resolved.path});
    if (std.mem.eql(u8, resolved.path, "/dev/null")) return true;

    return switch (file_mod.readResolvedPathAlloc(cl, resolved.path)) {
        .data => |content| blk: {
            defer xm.allocator.free(content);
            break :blk cfg_load_buffer(cl, resolved.path, content, flags);
        },
        .err => |errno_value| blk: {
            cfg_note_path_error(resolved.path, errno_value, flags.quiet);
            break :blk false;
        },
    };
}

pub fn cfg_show_causes(cl: ?*T.Client) void {
    for (cfg_causes.items) |cause| {
        cmdq.cmdq_write_client(cl, 2, "{s}", .{cause});
        xm.allocator.free(cause);
    }
    cfg_causes.clearRetainingCapacity();
}

pub fn cfg_source_content(cl: ?*T.Client, path: []const u8, content: []const u8, flags: CfgFlags) bool {
    return cfg_load_buffer(cl, path, content, flags);
}

pub fn cfg_note_path_error(path: []const u8, errno_value: c_int, quiet: bool) void {
    if (!quiet) cfg_note_cause("{s}: {s}", .{ file_mod.strerror(errno_value), path }, false);
}

fn cfg_load_buffer(cl: ?*T.Client, path: []const u8, content: []const u8, flags: CfgFlags) bool {
    var stripped: std.ArrayList(u8) = .{};
    defer stripped.deinit(xm.allocator);
    {
        var lines = std.mem.splitScalar(u8, content, '\n');
        var first = true;
        while (lines.next()) |raw_line| {
            const line = std.mem.trimRight(u8, raw_line, "\r");
            const trimmed = std.mem.trimLeft(u8, line, " \t");
            const is_comment = trimmed.len > 0 and trimmed[0] == '#';
            const is_directive = trimmed.len > 0 and trimmed[0] == '%';
            if (is_comment and !is_directive) {
                if (!first) stripped.append(xm.allocator, '\n') catch unreachable;
                first = false;
                continue;
            }
            if (!first) stripped.append(xm.allocator, '\n') catch unreachable;
            stripped.appendSlice(xm.allocator, line) catch unreachable;
            first = false;
        }
    }

    var pi_flags: u32 = 0;
    if (flags.parse_only) pi_flags |= T.CMD_PARSE_PARSEONLY;
    if (flags.verbose) pi_flags |= T.CMD_PARSE_VERBOSE;

    var pi = T.CmdParseInput{ .file = path, .flags = pi_flags };
    const result = cmd_mod.cmd_parse_from_string(stripped.items, &pi);
    switch (result.status) {
        .@"error" => {
            cfg_note_cause("{s}: {s}", .{ path, result.@"error" orelse "parse error" }, flags.quiet);
            return false;
        },
        .success => {
            if (result.cmdlist) |cl_ptr| {
                const list: *cmd_mod.CmdList = @ptrCast(@alignCast(cl_ptr));
                if (flags.parse_only) {
                    cmd_mod.cmd_list_free(list);
                } else {
                    if (cmdq.cmdq_run_immediate_flags(cl, list, T.CMDQ_STATE_NOATTACH) == .@"error")
                        return false;
                }
            }
            return true;
        },
    }
}

fn cfg_clear_causes() void {
    for (cfg_causes.items) |cause| xm.allocator.free(cause);
    cfg_causes.clearRetainingCapacity();
}

fn cfg_note_cause(comptime fmt: []const u8, args: anytype, quiet: bool) void {
    if (quiet) return;
    cfg_causes.append(xm.allocator, xm.xasprintf(fmt, args)) catch unreachable;
}

/// Resolve the user's home directory, matching tmux's find_home() behavior.
/// Tries $HOME first; falls back to getpwuid(getuid()).pw_dir when $HOME is
/// unset or empty, so config paths still resolve on headless systems and in
/// cron jobs where $HOME is sometimes stripped.
fn find_home() ?[]const u8 {
    if (std.posix.getenv("HOME")) |home| {
        if (home.len > 0) return home;
    }
    const c_mod = @import("c.zig");
    const pw = c_mod.posix_sys.getpwuid(std.os.linux.getuid()) orelse return null;
    const dir: [*c]const u8 = pw.*.pw_dir;
    return std.mem.span(@as([*:0]const u8, @ptrCast(dir orelse return null)));
}

fn expand_default_path(path: []const u8) ?[]u8 {
    if (std.mem.startsWith(u8, path, "~/")) {
        const home = find_home() orelse return null;
        return xm.xasprintf("{s}/{s}", .{ home, path[2..] });
    }
    if (std.mem.eql(u8, path, "~")) {
        const home = find_home() orelse return null;
        return xm.xstrdup(home);
    }
    if (std.mem.startsWith(u8, path, "$XDG_CONFIG_HOME/")) {
        const base = std.posix.getenv("XDG_CONFIG_HOME") orelse return null;
        return xm.xasprintf("{s}/{s}", .{ base, path["$XDG_CONFIG_HOME/".len..] });
    }
    return xm.xstrdup(path);
}

const SavedEnvVar = struct {
    name: []const u8,
    value: ?[]u8,

    fn capture(name: []const u8) SavedEnvVar {
        return .{
            .name = name,
            .value = if (std.posix.getenv(name)) |value| xm.xstrdup(value) else null,
        };
    }

    fn restore(self: *SavedEnvVar) void {
        defer if (self.value) |value| xm.allocator.free(value);
        if (self.value) |value| {
            setProcessEnv(self.name, value) catch unreachable;
        } else {
            unsetProcessEnv(self.name) catch unreachable;
        }
        self.value = null;
    }
};

fn setProcessEnv(name: []const u8, value: []const u8) !void {
    const name_z = xm.xm_dupeZ(name);
    defer xm.allocator.free(name_z);
    const value_z = xm.xm_dupeZ(value);
    defer xm.allocator.free(value_z);

    try std.testing.expectEqual(@as(c_int, 0), setenv(name_z.ptr, value_z.ptr, 1));
}

fn unsetProcessEnv(name: []const u8) !void {
    const name_z = xm.xm_dupeZ(name);
    defer xm.allocator.free(name_z);

    try std.testing.expectEqual(@as(c_int, 0), unsetenv(name_z.ptr));
}

fn initCfgLoadOptionsForTest() void {
    opts.global_options = opts.options_create(null);
    opts.global_s_options = opts.options_create(null);
    opts.global_w_options = opts.options_create(null);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    opts.options_ready = true;
}

fn deinitCfgLoadOptionsForTest() void {
    opts.options_free(opts.global_w_options);
    opts.options_free(opts.global_s_options);
    opts.options_free(opts.global_options);
    opts.options_ready = false;
}

fn expectDefaultConfigLoadMarkers(compat_name: []const u8, expected_marker: []const u8, unexpected_marker: []const u8) !void {
    const zmux_mod = @import("zmux.zig");

    cmdq.cmdq_reset_for_tests();
    defer cmdq.cmdq_reset_for_tests();

    initCfgLoadOptionsForTest();
    defer deinitCfgLoadOptionsForTest();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("home/.config/zmux");
    try tmp.dir.makePath("home/.config/tmux");
    try tmp.dir.writeFile(.{
        .sub_path = "home/.config/zmux/zmux.conf",
        .data = "set-option -agq status-left zmux-xdg\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "home/.config/tmux/tmux.conf",
        .data = "set-option -agq status-left tmux-xdg\n",
    });

    const tmp_root = try tmp.dir.realpathAlloc(xm.allocator, ".");
    defer xm.allocator.free(tmp_root);
    const home = try std.fs.path.join(xm.allocator, &.{ tmp_root, "home" });
    defer xm.allocator.free(home);
    const xdg = try std.fs.path.join(xm.allocator, &.{ home, ".config" });
    defer xm.allocator.free(xdg);

    var saved_home = SavedEnvVar.capture("HOME");
    defer saved_home.restore();
    var saved_xdg = SavedEnvVar.capture("XDG_CONFIG_HOME");
    defer saved_xdg.restore();

    try setProcessEnv("HOME", home);
    try setProcessEnv("XDG_CONFIG_HOME", xdg);

    const saved_compat_name = zmux_mod.compat_name;
    defer zmux_mod.compat_name = saved_compat_name;
    zmux_mod.compat_name = compat_name;

    const saved_cfg_quiet = cfg_quiet;
    defer cfg_quiet = saved_cfg_quiet;
    const saved_cfg_finished = cfg_finished;
    defer cfg_finished = saved_cfg_finished;
    cfg_quiet = true;
    cfg_finished = false;

    cfg_reset_files();
    defer cfg_reset_files();
    cfg_add_defaults();
    cfg_load(null);

    const status_left = opts.options_get_string(opts.global_s_options, "status-left");
    try std.testing.expect(std.mem.containsAtLeast(u8, status_left, 1, expected_marker));
    try std.testing.expect(std.mem.indexOf(u8, status_left, unexpected_marker) == null);
}

test "expand_default_path duplicates plain absolute paths" {
    const p = expand_default_path("/tmp/zmux-plain-cfg-path").?;
    defer xm.allocator.free(p);
    try std.testing.expectEqualStrings("/tmp/zmux-plain-cfg-path", p);
}

test "cfg default path expansion handles home and xdg" {
    cfg_reset_files();
    defer cfg_reset_files();

    var saved_home = SavedEnvVar.capture("HOME");
    defer saved_home.restore();
    var saved_xdg = SavedEnvVar.capture("XDG_CONFIG_HOME");
    defer saved_xdg.restore();

    try setProcessEnv("HOME", "/tmp/zmux-cfg-home");
    try setProcessEnv("XDG_CONFIG_HOME", "/tmp/zmux-cfg-xdg");

    const expanded_home = expand_default_path("~/.zmux.conf").?;
    defer xm.allocator.free(expanded_home);
    try std.testing.expectEqualStrings("/tmp/zmux-cfg-home/.zmux.conf", expanded_home);

    const expanded_xdg = expand_default_path("$XDG_CONFIG_HOME/zmux/zmux.conf").?;
    defer xm.allocator.free(expanded_xdg);
    try std.testing.expectEqualStrings("/tmp/zmux-cfg-xdg/zmux/zmux.conf", expanded_xdg);
}

test "cfg parse only does not enqueue commands" {
    cfg_clear_causes();
    defer cfg_clear_causes();

    const content = "set-option status off\n";
    try std.testing.expect(cfg_load_buffer(null, "/tmp/test.conf", content, .{ .parse_only = true }));
}

test "cfg source path reads stdin through the shared reduced file path" {
    cfg_clear_causes();
    defer cfg_clear_causes();

    const saved_stdin = try std.posix.dup(std.posix.STDIN_FILENO);
    defer {
        std.posix.dup2(saved_stdin, std.posix.STDIN_FILENO) catch {};
        std.posix.close(saved_stdin);
    }

    const pipe_fds = try std.posix.pipe();
    try std.posix.dup2(pipe_fds[0], std.posix.STDIN_FILENO);
    std.posix.close(pipe_fds[0]);
    _ = try std.posix.write(pipe_fds[1], "set-option status off\n");
    std.posix.close(pipe_fds[1]);

    var env = T.Environ.init(xm.allocator);
    defer env.deinit();
    var client = T.Client{
        .environ = &env,
        .tty = undefined,
        .status = .{},
    };

    try std.testing.expect(cfg_source_path(&client, "-", .{ .parse_only = true }));
}

test "cfg source path missing file records cause when not quiet" {
    cfg_clear_causes();
    defer cfg_show_causes(null);

    const missing = "/zmux-unit-test-nonexistent-config-path/.conf";
    try std.testing.expect(!cfg_source_path(null, missing, .{ .quiet = false }));
    try std.testing.expect(cfg_causes.items.len >= 1);
}

test "cfg_add_defaults loads zmux config paths in zmux mode" {
    const zmux_mod = @import("zmux.zig");
    zmux_mod.compat_name = "zmux";
    defer {
        zmux_mod.compat_name = "zmux";
    }
    cfg_reset_files();
    defer cfg_reset_files();
    cfg_add_defaults();
    for (cfg_file_paths.items) |path| {
        try std.testing.expect(std.mem.indexOf(u8, path, "zmux") != null);
        try std.testing.expect(std.mem.indexOf(u8, path, "tmux.conf") == null);
    }
    try std.testing.expect(cfg_file_paths.items.len > 0);
}

test "cfg_add_defaults loads tmux config paths in compat mode" {
    const zmux_mod = @import("zmux.zig");
    zmux_mod.compat_name = "tmux";
    defer {
        zmux_mod.compat_name = "zmux";
    }
    cfg_reset_files();
    defer cfg_reset_files();
    cfg_add_defaults();
    for (cfg_file_paths.items) |path| {
        try std.testing.expect(std.mem.indexOf(u8, path, "tmux") != null);
        try std.testing.expect(std.mem.indexOf(u8, path, "zmux.conf") == null);
    }
    try std.testing.expect(cfg_file_paths.items.len > 0);
}

test "cfg_load sources tmux XDG defaults instead of zmux defaults in compat mode" {
    try expectDefaultConfigLoadMarkers("tmux", "tmux-xdg", "zmux-xdg");
}

test "cfg_load sources zmux XDG defaults instead of tmux defaults in native mode" {
    try expectDefaultConfigLoadMarkers("zmux", "zmux-xdg", "tmux-xdg");
}

test "cfg_add_defaults produces exactly four paths per personality" {
    const zmux_mod = @import("zmux.zig");
    var saved_home = SavedEnvVar.capture("HOME");
    defer saved_home.restore();
    var saved_xdg = SavedEnvVar.capture("XDG_CONFIG_HOME");
    defer saved_xdg.restore();
    try setProcessEnv("HOME", "/test-home");
    try setProcessEnv("XDG_CONFIG_HOME", "/test-xdg");

    {
        const saved = zmux_mod.compat_name;
        defer zmux_mod.compat_name = saved;
        zmux_mod.compat_name = "zmux";
        cfg_reset_files();
        defer cfg_reset_files();
        cfg_add_defaults();
        try std.testing.expectEqual(@as(usize, 4), cfg_file_paths.items.len);
        try std.testing.expectEqualStrings("/etc/zmux.conf", cfg_file_paths.items[0]);
        try std.testing.expectEqualStrings("/test-home/.zmux.conf", cfg_file_paths.items[1]);
        try std.testing.expectEqualStrings("/test-xdg/zmux/zmux.conf", cfg_file_paths.items[2]);
        try std.testing.expectEqualStrings("/test-home/.config/zmux/zmux.conf", cfg_file_paths.items[3]);
    }

    {
        const saved = zmux_mod.compat_name;
        defer zmux_mod.compat_name = saved;
        zmux_mod.compat_name = "tmux";
        cfg_reset_files();
        defer cfg_reset_files();
        cfg_add_defaults();
        try std.testing.expectEqual(@as(usize, 4), cfg_file_paths.items.len);
        try std.testing.expectEqualStrings("/etc/tmux.conf", cfg_file_paths.items[0]);
        try std.testing.expectEqualStrings("/test-home/.tmux.conf", cfg_file_paths.items[1]);
        try std.testing.expectEqualStrings("/test-xdg/tmux/tmux.conf", cfg_file_paths.items[2]);
        try std.testing.expectEqualStrings("/test-home/.config/tmux/tmux.conf", cfg_file_paths.items[3]);
    }
}

test "cfg_load sources home-dir zmux.conf in native mode" {
    const zmux_mod = @import("zmux.zig");
    cmdq.cmdq_reset_for_tests();
    defer cmdq.cmdq_reset_for_tests();
    initCfgLoadOptionsForTest();
    defer deinitCfgLoadOptionsForTest();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("home");
    try tmp.dir.writeFile(.{
        .sub_path = "home/.zmux.conf",
        .data = "set-option -agq status-left zmux-home\n",
    });

    const tmp_root = try tmp.dir.realpathAlloc(xm.allocator, ".");
    defer xm.allocator.free(tmp_root);
    const home = try std.fs.path.join(xm.allocator, &.{ tmp_root, "home" });
    defer xm.allocator.free(home);

    var saved_home = SavedEnvVar.capture("HOME");
    defer saved_home.restore();
    var saved_xdg = SavedEnvVar.capture("XDG_CONFIG_HOME");
    defer saved_xdg.restore();
    try setProcessEnv("HOME", home);
    unsetProcessEnv("XDG_CONFIG_HOME") catch unreachable;

    const saved_compat = zmux_mod.compat_name;
    defer zmux_mod.compat_name = saved_compat;
    zmux_mod.compat_name = "zmux";

    const saved_q = cfg_quiet;
    defer cfg_quiet = saved_q;
    const saved_f = cfg_finished;
    defer cfg_finished = saved_f;
    cfg_quiet = true;
    cfg_finished = false;

    cfg_reset_files();
    defer cfg_reset_files();
    cfg_add_defaults();
    cfg_load(null);

    const status_left = opts.options_get_string(opts.global_s_options, "status-left");
    try std.testing.expect(std.mem.containsAtLeast(u8, status_left, 1, "zmux-home"));
}

test "cfg_load sources home-dir tmux.conf in compat mode" {
    const zmux_mod = @import("zmux.zig");
    cmdq.cmdq_reset_for_tests();
    defer cmdq.cmdq_reset_for_tests();
    initCfgLoadOptionsForTest();
    defer deinitCfgLoadOptionsForTest();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("home");
    try tmp.dir.writeFile(.{
        .sub_path = "home/.tmux.conf",
        .data = "set-option -agq status-left tmux-home\n",
    });

    const tmp_root = try tmp.dir.realpathAlloc(xm.allocator, ".");
    defer xm.allocator.free(tmp_root);
    const home = try std.fs.path.join(xm.allocator, &.{ tmp_root, "home" });
    defer xm.allocator.free(home);

    var saved_home = SavedEnvVar.capture("HOME");
    defer saved_home.restore();
    var saved_xdg = SavedEnvVar.capture("XDG_CONFIG_HOME");
    defer saved_xdg.restore();
    try setProcessEnv("HOME", home);
    unsetProcessEnv("XDG_CONFIG_HOME") catch unreachable;

    const saved_compat = zmux_mod.compat_name;
    defer zmux_mod.compat_name = saved_compat;
    zmux_mod.compat_name = "tmux";

    const saved_q = cfg_quiet;
    defer cfg_quiet = saved_q;
    const saved_f = cfg_finished;
    defer cfg_finished = saved_f;
    cfg_quiet = true;
    cfg_finished = false;

    cfg_reset_files();
    defer cfg_reset_files();
    cfg_add_defaults();
    cfg_load(null);

    const status_left = opts.options_get_string(opts.global_s_options, "status-left");
    try std.testing.expect(std.mem.containsAtLeast(u8, status_left, 1, "tmux-home"));
    try std.testing.expect(std.mem.indexOf(u8, status_left, "zmux") == null);
}

test "cfg_load sources all user config paths in correct order" {
    const zmux_mod = @import("zmux.zig");
    cmdq.cmdq_reset_for_tests();
    defer cmdq.cmdq_reset_for_tests();
    initCfgLoadOptionsForTest();
    defer deinitCfgLoadOptionsForTest();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create config files at all three user-writable locations, each
    // appending a numbered marker so we can verify load order.
    try tmp.dir.makePath("home/.config/zmux");
    try tmp.dir.writeFile(.{
        .sub_path = "home/.zmux.conf",
        .data = "set-option -agq status-left :p2-home:\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "home/.config/zmux/zmux.conf",
        .data = "set-option -agq status-left :p4-xdg-fallback:\n",
    });

    const tmp_root = try tmp.dir.realpathAlloc(xm.allocator, ".");
    defer xm.allocator.free(tmp_root);
    const home = try std.fs.path.join(xm.allocator, &.{ tmp_root, "home" });
    defer xm.allocator.free(home);

    // Also create a separate XDG_CONFIG_HOME directory so the $XDG
    // expansion and the ~/.config fallback exercise independent paths.
    try tmp.dir.makePath("xdg-home/zmux");
    try tmp.dir.writeFile(.{
        .sub_path = "xdg-home/zmux/zmux.conf",
        .data = "set-option -agq status-left :p3-xdg:\n",
    });
    const xdg_separate = try std.fs.path.join(xm.allocator, &.{ tmp_root, "xdg-home" });
    defer xm.allocator.free(xdg_separate);

    var saved_home = SavedEnvVar.capture("HOME");
    defer saved_home.restore();
    var saved_xdg = SavedEnvVar.capture("XDG_CONFIG_HOME");
    defer saved_xdg.restore();
    try setProcessEnv("HOME", home);
    try setProcessEnv("XDG_CONFIG_HOME", xdg_separate);

    const saved_compat = zmux_mod.compat_name;
    defer zmux_mod.compat_name = saved_compat;
    zmux_mod.compat_name = "zmux";

    const saved_q = cfg_quiet;
    defer cfg_quiet = saved_q;
    const saved_f = cfg_finished;
    defer cfg_finished = saved_f;
    cfg_quiet = true;
    cfg_finished = false;

    cfg_reset_files();
    defer cfg_reset_files();
    cfg_add_defaults();
    cfg_load(null);

    const status_left = opts.options_get_string(opts.global_s_options, "status-left");

    // All three markers must appear.
    try std.testing.expect(std.mem.containsAtLeast(u8, status_left, 1, ":p2-home:"));
    try std.testing.expect(std.mem.containsAtLeast(u8, status_left, 1, ":p3-xdg:"));
    try std.testing.expect(std.mem.containsAtLeast(u8, status_left, 1, ":p4-xdg-fallback:"));

    // Verify ordering: home-dir before XDG before XDG-fallback.
    const idx_home = std.mem.indexOf(u8, status_left, ":p2-home:").?;
    const idx_xdg = std.mem.indexOf(u8, status_left, ":p3-xdg:").?;
    const idx_fallback = std.mem.indexOf(u8, status_left, ":p4-xdg-fallback:").?;
    try std.testing.expect(idx_home < idx_xdg);
    try std.testing.expect(idx_xdg < idx_fallback);
}

test "find_home prefers HOME when set" {
    var saved_home = SavedEnvVar.capture("HOME");
    defer saved_home.restore();
    try setProcessEnv("HOME", "/my/test/home");

    try std.testing.expectEqualStrings("/my/test/home", find_home().?);
}

test "find_home falls back to getpwuid when HOME is unset" {
    var saved_home = SavedEnvVar.capture("HOME");
    defer saved_home.restore();
    unsetProcessEnv("HOME") catch unreachable;

    const home = find_home();
    try std.testing.expect(home != null);
    try std.testing.expect(home.?.len > 0);
    try std.testing.expect(home.?[0] == '/');
}

test "find_home falls back to getpwuid when HOME is empty" {
    var saved_home = SavedEnvVar.capture("HOME");
    defer saved_home.restore();
    try setProcessEnv("HOME", "");

    const home = find_home();
    try std.testing.expect(home != null);
    try std.testing.expect(home.?.len > 0);
    try std.testing.expect(home.?[0] == '/');
}

test "expand_default_path uses getpwuid fallback for tilde when HOME is unset" {
    var saved_home = SavedEnvVar.capture("HOME");
    defer saved_home.restore();
    unsetProcessEnv("HOME") catch unreachable;

    // With HOME unset, find_home should fall back to getpwuid, so ~/
    // expansion should still work on any system with a valid passwd entry.
    const expanded = expand_default_path("~/.zmux.conf");
    try std.testing.expect(expanded != null);
    defer if (expanded) |e| xm.allocator.free(e);
    if (expanded) |e| {
        try std.testing.expect(e.len > "/.zmux.conf".len);
        try std.testing.expect(std.mem.endsWith(u8, e, "/.zmux.conf"));
        try std.testing.expect(e[0] == '/');
    }
}
