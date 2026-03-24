// Copyright (c) 2026 Greg Turner <gmt@be-evil.net>
// ISC licence – see COPYING.
// Ported from tmux/format.c (skeleton – full format engine is deferred)

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");

pub fn format_single(
    _item: ?*anyopaque,
    fmt: []const u8,
    _cl: ?*T.Client,
    _s: ?*T.Session,
    _wl: ?*T.Winlink,
    _wp: ?*T.WindowPane,
) []u8 {
    _ = _item;
    _ = _cl;
    _ = _s;
    _ = _wl;
    _ = _wp;
    // Stub: return format string verbatim until format engine is ported
    return xm.xstrdup(fmt);
}

pub fn format_tidy_jobs() void {}
