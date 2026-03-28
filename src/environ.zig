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
// Ported from tmux/environ.c
// Original copyright:
//   Copyright (c) 2009 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

//! environ.zig – environment variable management.
//!
//! Implements a named set of environment variables with value, clear, and
//! hidden semantics, mirroring the behaviour of tmux's environ.c.
//! The RB_TREE from tmux is replaced by std.StringHashMap.

const std = @import("std");
const c = @import("c.zig");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const log = @import("log.zig");
const opts = @import("options.zig");

extern fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern fn unsetenv(name: [*:0]const u8) c_int;

pub var global_environ: *T.Environ = undefined;

/// Allocate and initialise a new empty environment.
pub fn environ_create() *T.Environ {
    const env = xm.allocator.create(T.Environ) catch unreachable;
    env.* = T.Environ.init(xm.allocator);
    return env;
}

/// Free all resources associated with an environment.
pub fn environ_free(env: *T.Environ) void {
    var it = env.entries.valueIterator();
    while (it.next()) |entry| {
        xm.allocator.free(entry.name);
        if (entry.value) |v| xm.allocator.free(v);
    }
    env.entries.deinit();
    xm.allocator.destroy(env);
}

/// Return the first entry (sorted alphabetically; we sort on demand).
pub fn environ_first(env: *T.Environ) ?*T.EnvironEntry {
    // For ordered iteration, callers should iterate the values directly.
    var it = env.entries.valueIterator();
    return it.next();
}

/// Copy all entries from src into dst.
pub fn environ_copy(srcenv: *T.Environ, dstenv: *T.Environ) void {
    var it = srcenv.entries.valueIterator();
    while (it.next()) |entry| {
        if (entry.value) |v| {
            environ_set(dstenv, entry.name, entry.flags, v);
        } else {
            environ_clear(dstenv, entry.name);
        }
    }
}

/// Find an environment variable by name.  Returns null if not found.
pub fn environ_find(env: *T.Environ, name: []const u8) ?*T.EnvironEntry {
    return env.entries.getPtr(name);
}

/// Set or create an environment variable.
pub fn environ_set(env: *T.Environ, name: []const u8, flags: u32, value: []const u8) void {
    if (env.entries.getPtr(name)) |entry| {
        entry.flags = flags;
        if (entry.value) |old| xm.allocator.free(old);
        entry.value = xm.xstrdup(value);
    } else {
        const owned_name = xm.xstrdup(name);
        const entry = T.EnvironEntry{
            .name = owned_name,
            .value = xm.xstrdup(value),
            .flags = flags,
        };
        env.entries.put(owned_name, entry) catch unreachable;
    }
}

/// Mark a variable as explicitly unset (value = null, entry still present).
pub fn environ_clear(env: *T.Environ, name: []const u8) void {
    if (env.entries.getPtr(name)) |entry| {
        if (entry.value) |v| xm.allocator.free(v);
        entry.value = null;
    } else {
        const owned_name = xm.xstrdup(name);
        env.entries.put(owned_name, .{
            .name = owned_name,
            .value = null,
            .flags = 0,
        }) catch unreachable;
    }
}

/// Parse "NAME=VALUE" and call environ_set.
pub fn environ_put(env: *T.Environ, var_str: []const u8, flags: u32) void {
    const eq = std.mem.indexOfScalar(u8, var_str, '=') orelse return;
    const name = var_str[0..eq];
    const value = var_str[eq + 1 ..];
    environ_set(env, name, flags, value);
}

/// Permanently remove a variable from the environment.
pub fn environ_unset(env: *T.Environ, name: []const u8) void {
    if (env.entries.fetchRemove(name)) |kv| {
        xm.allocator.free(kv.value.name);
        if (kv.value.value) |v| xm.allocator.free(v);
    }
}

pub fn environ_update(oo: *T.Options, srcenv: *T.Environ, dstenv: *T.Environ) void {
    const patterns = opts.options_get_array(oo, "update-environment");
    for (patterns) |pattern| {
        var found = false;
        var it = srcenv.entries.valueIterator();
        while (it.next()) |entry| {
            if (!environ_match(pattern, entry.name)) continue;
            if (entry.value) |value|
                environ_set(dstenv, entry.name, 0, value)
            else
                environ_clear(dstenv, entry.name);
            found = true;
        }
        if (!found) environ_clear(dstenv, pattern);
    }
}

/// Push all non-hidden variables with a value into the process environment
/// (call after fork, before exec).
pub fn environ_push(env: *T.Environ) void {
    var it = env.entries.valueIterator();
    while (it.next()) |entry| {
        if (entry.name.len == 0) continue;
        if (entry.flags & T.ENVIRON_HIDDEN != 0) continue;
        const name_z = xm.allocator.dupeZ(u8, entry.name) catch unreachable;
        defer xm.allocator.free(name_z);
        if (entry.value == null) {
            _ = unsetenv(name_z);
            continue;
        }
        const val_z = xm.allocator.dupeZ(u8, entry.value.?) catch unreachable;
        defer xm.allocator.free(val_z);
        _ = setenv(name_z, val_z, 1);
    }
}

/// Log all variables via log_debug.
pub fn environ_log(env: *T.Environ, comptime prefix_fmt: []const u8, prefix_args: anytype) void {
    var it = env.entries.valueIterator();
    while (it.next()) |entry| {
        if (entry.value != null and entry.name.len > 0) {
            log.log_debug(prefix_fmt ++ "{s}={s}", prefix_args ++ .{ entry.name, entry.value.? });
        }
    }
}

pub fn environ_sorted_entries(env: *T.Environ) []*T.EnvironEntry {
    var list: std.ArrayList(*T.EnvironEntry) = .{};
    var it = env.entries.valueIterator();
    while (it.next()) |entry| list.append(xm.allocator, entry) catch unreachable;
    std.sort.block(*T.EnvironEntry, list.items, {}, less_than_entry);
    return list.toOwnedSlice(xm.allocator) catch unreachable;
}

fn less_than_entry(_: void, a: *T.EnvironEntry, b: *T.EnvironEntry) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

fn environ_match(pattern: []const u8, name: []const u8) bool {
    const pattern_z = xm.xm_dupeZ(pattern);
    defer xm.allocator.free(pattern_z);
    const name_z = xm.xm_dupeZ(name);
    defer xm.allocator.free(name_z);
    return c.posix_sys.fnmatch(pattern_z.ptr, name_z.ptr, 0) == 0;
}

test "environ_sorted_entries returns alphabetical order" {
    const env = environ_create();
    defer environ_free(env);

    environ_set(env, "Z_LAST", 0, "1");
    environ_set(env, "A_FIRST", 0, "2");
    const entries = environ_sorted_entries(env);
    defer xm.allocator.free(entries);

    try std.testing.expectEqualStrings("A_FIRST", entries[0].name);
    try std.testing.expectEqualStrings("Z_LAST", entries[1].name);
}
