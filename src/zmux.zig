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

// ── Global environ (set before options, needed by client.c) ───────────────
pub var global_environ: *T.Environ = undefined;

// ── Usage ────────────────────────────────────────────────────────────────

fn usage(to_stderr: bool) void {
    const stream = if (to_stderr) std.fs.File.stderr() else std.fs.File.stdout();
    _ = stream.writeAll(
        "usage: zmux [-2CDhlNuVv] [-c shell-command] [-f file] [-L socket-name]\n" ++
        "            [-S socket-path] [-T features] [command [flags]]\n",
    ) catch {};
}

// ── main ─────────────────────────────────────────────────────────────────

pub fn main() !void {
    const alloc = xm.allocator;
    _ = alloc;

    // Set up locale / UTF-8 (best-effort on Linux; libc call via C shim)
    _ = std.c.setlocale(std.c.LC.CTYPE, "en_US.UTF-8");

    // Build the global environment from the process environment
    global_environ = env_mod.environ_create();
    {
        const env_map = try std.process.getEnvMap(xm.allocator);
        defer @constCast(&env_map).deinit();
        var env_it = env_map.iterator();
        while (env_it.next()) |kv| {
            env_mod.environ_set(global_environ, kv.key_ptr.*, 0, kv.value_ptr.*);
        }
    }

    // Initialise global options from table defaults
    opts.global_options = opts.options_create(null);
    opts.global_s_options = opts.options_create(null);
    opts.global_w_options = opts.options_create(null);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);

    // Set default shell from $SHELL or /etc/passwd
    const default_shell = getshell();
    opts.options_set_string(opts.global_s_options, false, "default-shell", default_shell);

    // Parse command line
    const raw_args = try std.process.argsAlloc(xm.allocator);
    defer std.process.argsFree(xm.allocator, raw_args);

    var path: ?[]u8 = null;
    var label: ?[]u8 = null;
    var flags: u64 = 0;
    var feat: i32 = 0;
    _ = &feat; // mutable for future -T feature flags
    // Config file list (from -f flags)
    var cfg_file_override = false;
    var cmd_argc: i32 = 0;
    var cmd_argv: [*]const [*:0]const u8 = undefined;
    var cmd_argv_storage: [256][*:0]const u8 = undefined;

    // Check if invoked as a login shell
    if (raw_args.len > 0 and raw_args[0].len > 0 and raw_args[0][0] == '-')
        flags |= T.CLIENT_LOGIN;

    var i: usize = 1;
    while (i < raw_args.len) : (i += 1) {
        const arg = raw_args[i];
        if (arg.len == 0 or arg[0] != '-') break;
        if (std.mem.eql(u8, arg, "--")) { i += 1; break; }
        if (arg.len < 2) { usage(true); std.process.exit(1); }

        // Scan all flag characters in this arg.
        // Flags that take a value may have it inline (e.g. -Lname) or in
        // the next argv element (e.g. -L name), matching getopt behavior.
        var j: usize = 1;
        while (j < arg.len) {
            const opt_char = arg[j];
            j += 1;

            switch (opt_char) {
                '2' => {},
                'C' => {
                    if (flags & T.CLIENT_CONTROL != 0)
                        flags |= T.CLIENT_CONTROLCONTROL
                    else
                        flags |= T.CLIENT_CONTROL;
                },
                'D' => flags |= T.CLIENT_NOFORK,
                'h' => { usage(false); return; },
                'l' => flags |= T.CLIENT_LOGIN,
                'N' => flags |= T.CLIENT_NOSTARTSERVER,
                'u' => flags |= T.CLIENT_UTF8,
                'v' => log.log_add_level(),
                'V' => {
                    _ = std.fs.File.stdout().writeAll("zmux 3.6a-dev\n") catch {};
                    return;
                },
                // Flags that take a value argument
                'c', 'f', 'L', 'S', 'T' => {
                    // Value is either the rest of this arg or the next arg
                    const value = if (j < arg.len) blk: {
                        const v = arg[j..];
                        j = arg.len; // consume rest of arg
                        break :blk v;
                    } else blk: {
                        i += 1;
                        if (i >= raw_args.len) { usage(true); std.process.exit(1); }
                        break :blk raw_args[i];
                    };
                    switch (opt_char) {
                        'c' => {}, // shell-command – TODO
                        'f' => {
                            if (!cfg_file_override) {
                                cfg_mod.cfg_nfiles = 0;
                                cfg_file_override = true;
                            }
                            cfg_mod.cfg_quiet = false;
                            cfg_mod.cfg_add_file(value);
                        },
                        'L' => {
                            if (label) |l| xm.allocator.free(l);
                            label = xm.xstrdup(value);
                        },
                        'S' => {
                            if (path) |p| xm.allocator.free(p);
                            path = xm.xstrdup(value);
                        },
                        'T' => {
                            feat += 0; // TODO: tty_add_features with value
                        },
                        else => unreachable,
                    }
                },
                else => { usage(true); std.process.exit(1); },
            }
        }
    }

    // Remaining args are the command
    cmd_argc = @intCast(raw_args.len - i);
    for (0..@intCast(cmd_argc)) |j| {
        cmd_argv_storage[j] = raw_args[i + j].ptr;
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
    if (label) |l| xm.allocator.free(l);

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
    const empty_argv: [1][*:0]const u8 = .{ "" };
    const rc = client_mod.client_main(base, cmd_argc, if (cmd_argc > 0) cmd_argv else &empty_argv, flags, feat);
    std.process.exit(@intCast(@as(i32, @max(rc, 0))));
}

// ── Helpers ───────────────────────────────────────────────────────────────

fn getshell() []const u8 {
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

test {
    _ = @import("attributes.zig");
    _ = @import("names.zig");
    _ = @import("sort.zig");
}
