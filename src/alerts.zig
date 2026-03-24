// Copyright (c) 2026 Greg Turner <gmt@pobox.com>
// ISC licence – see COPYING.
// Ported from tmux/alerts.c (skeleton)

const std = @import("std");
const T = @import("types.zig");

pub fn alerts_queue(_w: *T.Window, _flag: u32) void { _ = _w; _ = _flag; }
pub fn alerts_check_session(_s: *T.Session) void { _ = _s; }
