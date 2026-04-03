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
// Based on tmux/fuzz/input-fuzzer.c
// Original copyright:
//   Copyright (c) 2020 Sergey Nizovtsev <snizovtsev@gmail.com>
//   ISC licence – same terms as above.

//! fuzz/input-fuzzer.zig – Zig fuzz target for the terminal input parser.
//!
//! Build with: `zig build -Dfuzzing=true install`
//! LibFuzzer:   `zig-out/bin/zmux-input-fuzzer fuzz/corpus/ fuzz/input-fuzzer.dict`
//! Stdin smoke: `sh fuzz/run-corpus.sh zig-out/bin/zmux-input-fuzzer` or `zig build -Dfuzzing=true fuzz-smoke`

const std = @import("std");
const zmux = @import("zmux");
const T = zmux.fuzz.T;
const xm = zmux.fuzz.xm;
const c = zmux.fuzz.c;
const input = zmux.fuzz.input;
const window_mod = zmux.fuzz.window;
const cmdq = zmux.fuzz.cmdq;
const session = zmux.fuzz.session;
const opts = zmux.fuzz.options;
const env_mod = zmux.fuzz.environ;

const FUZZER_MAXLEN = 512;
const PANE_WIDTH = 80;
const PANE_HEIGHT = 25;
const CMDQ_DRAIN_CAP = 256;

var g_wp: ?*T.WindowPane = null;
var g_base: ?*c.libevent.event_base = null;

fn fuzzEnsureInit() void {
    if (g_wp != null) return;

    session.session_init_globals(xm.allocator);
    window_mod.window_init_globals(xm.allocator);

    opts.global_options = opts.options_create(null);
    opts.global_s_options = opts.options_create(null);
    opts.global_w_options = opts.options_create(null);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);

    const env = env_mod.environ_create();
    const s = session.session_create(null, "fuzz", "/", env, opts.options_create(opts.global_s_options), null);

    const w = window_mod.window_create(PANE_WIDTH, PANE_HEIGHT, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    var cause: ?[]u8 = null;
    const wl = session.session_attach(s, w, 0, &cause).?;
    s.curw = wl;
    const wp = window_mod.window_add_pane(w, null, PANE_WIDTH, PANE_HEIGHT);
    w.active = wp;
    g_wp = wp;

    cmdq.cmdq_reset_for_tests();
    g_base = c.libevent.event_base_new();
}

/// LibFuzzer entry point.
export fn LLVMFuzzerTestOneInput(data: [*]const u8, size: usize) i32 {
    fuzzEnsureInit();
    if (size > FUZZER_MAXLEN) return 0;

    const wp = g_wp.?;

    cmdq.cmdq_reset_for_tests();
    input.input_init(wp, null);
    input.input_parse_buffer(wp, data[0..size]);

    var iter: u32 = 0;
    while (iter < CMDQ_DRAIN_CAP) : (iter += 1) {
        if (cmdq.cmdq_next(null) == 0) break;
    }

    if (g_base) |base| {
        _ = c.libevent.event_base_loop(base, c.libevent.EVLOOP_NONBLOCK);
    }

    return 0;
}

/// LibFuzzer initialisation hook.
export fn LLVMFuzzerInitialize(_argc: *c_int, _argv: *[*c][*c]u8) i32 {
    _ = _argc;
    _ = _argv;
    fuzzEnsureInit();
    return 0;
}

pub fn main() void {
    fuzzEnsureInit();
    var buf: [FUZZER_MAXLEN]u8 = undefined;
    const n = std.fs.File.stdin().read(&buf) catch return;
    _ = LLVMFuzzerTestOneInput(&buf, n);
}
