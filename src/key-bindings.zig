// Copyright (c) 2026 Greg Turner <gmt@be-evil.net>
// ISC licence – see COPYING.
// Ported from tmux/key-bindings.c (skeleton)

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const log = @import("log.zig");

pub fn key_bindings_init() void {
    // TODO: initialise default key binding tables (prefix, root, etc.)
    log.log_debug("key_bindings_init (stub)", .{});
}

pub fn key_bindings_get_table(_name: []const u8, _create: bool) ?*anyopaque {
    _ = _name;
    _ = _create;
    return null;
}

pub fn key_bindings_unref_table(_table: ?*anyopaque) void {
    _ = _table;
}
