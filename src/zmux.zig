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
// Ported from tmux/tmux.c
// Original copyright:
//   Copyright (c) 2007 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

//! zmux.zig – main entry point for zmux.
//!
//! Parses the command line, initialises global state, and hands control
//! to client_main() which manages the libevent loop and IPC to the server.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const log = @import("log.zig");
const env_mod = @import("environ.zig");
const opts = @import("options.zig");
const client_mod = @import("client.zig");
const server_mod = @import("server.zig");
const cfg_mod = @import("cfg.zig");
const os_mod = @import("os/linux.zig");
const c = @import("c.zig");
const tty_features = @import("tty-features.zig");

pub const tty_acs = @import("tty-acs.zig");

// ── Usage ────────────────────────────────────────────────────────────────

fn usage(to_stderr: bool) void {
    const stream = if (to_stderr) std.fs.File.stderr() else std.fs.File.stdout();
    _ = stream.writeAll(
        "usage: zmux [-2CDhlNuVv] [-c shell-command] [-f file] [-L socket-name]\n" ++
            "            [-S socket-path] [-T features] [command [flags]]\n",
    ) catch {};
}

const ParsedMainArgs = struct {
    const Action = enum {
        none,
        usage,
        version,
    };

    path: ?[]u8 = null,
    label: ?[]u8 = null,
    shell_command: ?[]u8 = null,
    flags: u64 = 0,
    feat: i32 = 0,
    cfg_file_override: bool = false,
    command_start: usize = 0,
    action: Action = .none,

    fn deinit(self: *ParsedMainArgs) void {
        if (self.path) |path| xm.allocator.free(path);
        if (self.label) |label| xm.allocator.free(label);
        if (self.shell_command) |shell_command| xm.allocator.free(shell_command);
    }
};

fn parseMainArgs(raw_args: []const []const u8) error{Usage}!ParsedMainArgs {
    var parsed = ParsedMainArgs{};
    errdefer parsed.deinit();

    if (raw_args.len > 0 and raw_args[0].len > 0 and raw_args[0][0] == '-')
        parsed.flags |= T.CLIENT_LOGIN;

    var i: usize = 1;
    while (i < raw_args.len) : (i += 1) {
        const arg = raw_args[i];
        if (arg.len == 0 or arg[0] != '-') break;
        if (std.mem.eql(u8, arg, "--")) {
            i += 1;
            break;
        }
        if (arg.len < 2) return error.Usage;

        // Scan all flag characters in this arg.
        // Flags that take a value may have it inline (e.g. -Lname) or in
        // the next argv element (e.g. -L name), matching getopt behavior.
        var j: usize = 1;
        while (j < arg.len) {
            const opt_char = arg[j];
            j += 1;

            switch (opt_char) {
                '2' => tty_features.addFeatures(&parsed.feat, "256", ":,"),
                'C' => {
                    if (parsed.flags & T.CLIENT_CONTROL != 0)
                        parsed.flags |= T.CLIENT_CONTROLCONTROL
                    else
                        parsed.flags |= T.CLIENT_CONTROL;
                },
                'D' => parsed.flags |= T.CLIENT_NOFORK,
                'h' => {
                    parsed.action = .usage;
                    return parsed;
                },
                'l' => parsed.flags |= T.CLIENT_LOGIN,
                'N' => parsed.flags |= T.CLIENT_NOSTARTSERVER,
                'u' => parsed.flags |= T.CLIENT_UTF8,
                'v' => log.log_add_level(),
                'V' => {
                    parsed.action = .version;
                    return parsed;
                },
                'c', 'f', 'L', 'S', 'T' => {
                    const value = if (j < arg.len) blk: {
                        const v = arg[j..];
                        j = arg.len;
                        break :blk v;
                    } else blk: {
                        i += 1;
                        if (i >= raw_args.len) return error.Usage;
                        break :blk raw_args[i];
                    };
                    switch (opt_char) {
                        'c' => {
                            if (parsed.shell_command) |shell_command| xm.allocator.free(shell_command);
                            parsed.shell_command = xm.xstrdup(value);
                        },
                        'f' => {
                            if (!parsed.cfg_file_override) {
                                cfg_mod.cfg_reset_files();
                                parsed.cfg_file_override = true;
                            }
                            cfg_mod.cfg_quiet = false;
                            cfg_mod.cfg_add_file(value);
                        },
                        'L' => {
                            if (parsed.label) |label| xm.allocator.free(label);
                            parsed.label = xm.xstrdup(value);
                        },
                        'S' => {
                            if (parsed.path) |path| xm.allocator.free(path);
                            parsed.path = xm.xstrdup(value);
                        },
                        'T' => tty_features.addFeatures(&parsed.feat, value, ":,"),
                        else => unreachable,
                    }
                },
                else => return error.Usage,
            }
        }
    }

    parsed.command_start = i;
    const cmd_argc = raw_args.len - i;
    if (parsed.shell_command != null and cmd_argc != 0) return error.Usage;
    if (parsed.flags & T.CLIENT_NOFORK != 0 and cmd_argc != 0) return error.Usage;
    return parsed;
}

// ── main ─────────────────────────────────────────────────────────────────

pub fn main() !void {
    const alloc = xm.allocator;
    _ = alloc;

    // Set up locale / UTF-8 (best-effort on Linux; libc call via C shim)
    _ = std.c.setlocale(std.c.LC.CTYPE, "en_US.UTF-8");

    // Build the global environment from the process environment
    env_mod.global_environ = env_mod.environ_create();
    {
        const env_map = try std.process.getEnvMap(xm.allocator);
        defer @constCast(&env_map).deinit();
        var env_it = env_map.iterator();
        while (env_it.next()) |kv| {
            env_mod.environ_set(env_mod.global_environ, kv.key_ptr.*, 0, kv.value_ptr.*);
        }
    }

    // Initialise global options from table defaults
    opts.global_options = opts.options_create(null);
    opts.global_s_options = opts.options_create(null);
    opts.global_w_options = opts.options_create(null);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    opts.options_ready = true;

    // Set default shell from $SHELL or /etc/passwd
    const default_shell = getshell();
    opts.options_set_string(opts.global_s_options, false, "default-shell", default_shell);

    // Parse command line
    const raw_args = try std.process.argsAlloc(xm.allocator);
    defer std.process.argsFree(xm.allocator, raw_args);

    const parsed = parseMainArgs(raw_args) catch {
        usage(true);
        std.process.exit(1);
    };

    var path = parsed.path;
    const label = parsed.label;
    var flags = parsed.flags;
    const feat = parsed.feat;
    const shell_command = parsed.shell_command;
    const cfg_file_override = parsed.cfg_file_override;
    var cmd_argc: i32 = 0;
    var cmd_argv: [*]const [*:0]const u8 = undefined;
    var cmd_argv_storage: [256][*:0]const u8 = undefined;

    switch (parsed.action) {
        .usage => {
            usage(false);
            return;
        },
        .version => {
            _ = std.fs.File.stdout().writeAll("zmux 3.6a-dev\n") catch {};
            return;
        },
        .none => {},
    }

    // Remaining args are the command
    cmd_argc = @intCast(raw_args.len - parsed.command_start);
    for (0..@as(usize, @intCast(cmd_argc))) |j| {
        cmd_argv_storage[j] = raw_args[parsed.command_start + j].ptr;
    }
    if (cmd_argc > 0) cmd_argv = &cmd_argv_storage;

    // Resolve socket path
    if (path == null) {
        if (std.posix.getenv("ZMUX")) |zmux_env| {
            const comma = std.mem.indexOfScalar(u8, zmux_env, ',');
            const socket_str = if (comma) |ci| zmux_env[0..ci] else zmux_env;
            if (socket_str.len > 0) {
                path = xm.xstrdup(socket_str);
            }
        }
    }
    if (path == null) {
        path = make_label(label) orelse {
            std.debug.print("zmux: couldn't create socket directory\n", .{});
            std.process.exit(1);
        };
        flags |= T.CLIENT_DEFAULTSOCKET;
    }
    server_mod.socket_path = path.?;
    env_mod.socket_path = path.?;
    if (label) |l| xm.allocator.free(l);

    if (!cfg_file_override) {
        cfg_mod.cfg_quiet = true;
        cfg_mod.cfg_add_defaults();
    }

    // UTF-8 detection
    if (std.posix.getenv("ZMUX")) |_| {
        flags |= T.CLIENT_UTF8;
    } else {
        const s = std.posix.getenv("LC_ALL") orelse
            std.posix.getenv("LC_CTYPE") orelse
            std.posix.getenv("LANG") orelse "";
        if (std.ascii.indexOfIgnoreCase(s, "UTF-8")) |_| flags |= T.CLIENT_UTF8;
        if (std.ascii.indexOfIgnoreCase(s, "UTF8")) |_| flags |= T.CLIENT_UTF8;
    }

    // Initialise libevent
    const base = os_mod.osdep_event_init();
    proc_mod.libevent = base;

    // Hand off to client
    const empty_argv: [1][*:0]const u8 = .{""};
    const rc = client_mod.client_main(base, shell_command, cmd_argc, if (cmd_argc > 0) cmd_argv else &empty_argv, flags, feat);
    std.process.exit(@intCast(@as(i32, @max(rc, 0))));
}

// ── Helpers ───────────────────────────────────────────────────────────────

pub fn getshell() []const u8 {
    if (std.posix.getenv("SHELL")) |sh| {
        if (sh.len > 0 and sh[0] == '/') return sh;
    }
    return "/bin/sh";
}

fn make_label(label: ?[]u8) ?[]u8 {
    const lname = if (label) |l| l else "default";
    const uid = std.os.linux.getuid();
    const tmpdir = std.posix.getenv("ZMUX_TMPDIR") orelse "/tmp";

    const base = xm.xasprintf("{s}/zmux-{d}", .{ tmpdir, uid });
    defer xm.allocator.free(base);

    std.fs.makeDirAbsolute(base) catch |err| {
        if (err != error.PathAlreadyExists) return null;
    };

    return xm.xasprintf("{s}/{s}", .{ base, lname });
}

// ── Module re-exports needed by other files ───────────────────────────────

const proc_mod = @import("proc.zig");

pub fn checkshell(shell: ?[]const u8) bool {
    const sh = shell orelse return false;
    if (sh.len == 0 or sh[0] != '/') return false;
    std.fs.accessAbsolute(sh, .{}) catch return false;
    return true;
}

pub fn getversion() []const u8 {
    return T.ZMUX_VERSION;
}

test "parseMainArgs stores top-level shell command" {
    cfg_mod.cfg_reset_files();
    defer cfg_mod.cfg_reset_files();

    const args = [_][]const u8{ "zmux", "-c", "printf top-level" };
    var parsed = try parseMainArgs(args[0..]);
    defer parsed.deinit();

    try std.testing.expectEqualStrings("printf top-level", parsed.shell_command.?);
    try std.testing.expectEqual(@as(usize, args.len), parsed.command_start);
}

test "parseMainArgs rejects top-level shell command mixed with command argv" {
    cfg_mod.cfg_reset_files();
    defer cfg_mod.cfg_reset_files();

    const args = [_][]const u8{ "zmux", "-c", "printf top-level", "new-session" };
    try std.testing.expectError(error.Usage, parseMainArgs(args[0..]));
}

test "parseMainArgs rejects nofork with command argv" {
    cfg_mod.cfg_reset_files();
    defer cfg_mod.cfg_reset_files();

    const args = [_][]const u8{ "zmux", "-D", "new-session" };
    try std.testing.expectError(error.Usage, parseMainArgs(args[0..]));
}

test {
    _ = @import("attributes.zig");
    _ = @import("alerts.zig");
    _ = @import("colour.zig");
    _ = @import("grid.zig");
    _ = @import("grid-test.zig");
    _ = @import("hyperlinks.zig");
    _ = @import("input.zig");
    _ = @import("key-string.zig");
    _ = @import("names.zig");
    _ = @import("pane-io.zig");
    _ = @import("paste.zig");
    _ = @import("screen-redraw.zig");
    _ = @import("screen-write.zig");
    _ = @import("screen.zig");
    _ = @import("sort.zig");
    _ = @import("style.zig");
    _ = @import("tty.zig");
    _ = @import("tty-draw.zig");
    _ = @import("tty-keys.zig");
    _ = @import("input-keys.zig");
    _ = @import("mode-tree.zig");
    _ = @import("utf8.zig");
    _ = @import("window-client.zig");
    _ = @import("cmd-send-keys-test.zig");
    _ = @import("window-copy-test.zig");
    _ = @import("server-client-test.zig");
    _ = @import("layout.zig");
    _ = @import("window-test.zig");
    _ = @import("cmd-find-test.zig");
    _ = @import("cmd-session-lifecycle-test.zig");
    _ = @import("image-sixel.zig");
    _ = @import("image.zig");
    _ = @import("screen-redraw.zig");
    _ = @import("format-test.zig");
    _ = @import("options-test.zig");
    _ = @import("popup-menu-test.zig");
    _ = @import("control-test.zig");
    _ = @import("small-modules-test.zig");
    _ = @import("zmux-protocol-test.zig");
}
