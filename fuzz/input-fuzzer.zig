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
//! Build with: zig build -Dfuzzing=true
//! Run with:   zig-out/bin/zmux-input-fuzzer corpus/ fuzz/input-fuzzer.dict

const std = @import("std");

const FUZZER_MAXLEN = 512;
const PANE_WIDTH = 80;
const PANE_HEIGHT = 25;

/// LibFuzzer entry point.
export fn LLVMFuzzerTestOneInput(data: [*]const u8, size: usize) i32 {
    _ = data;
    if (size > FUZZER_MAXLEN) return 0;
    // TODO: wire up once input parser is ported
    // 1. Create a minimal window+pane
    // 2. Feed data through input_parse_buffer
    // 3. Drain cmdq_next(null)
    // 4. Run one nonblocking libevent iteration
    return 0;
}

/// LibFuzzer initialisation hook.
export fn LLVMFuzzerInitialize(_argc: *c_int, _argv: *[*c][*c]u8) i32 {
    _ = _argc;
    _ = _argv;
    return 0;
}

pub fn main() void {
    // Standalone entry: read from stdin and pass to fuzzer
    var buf: [FUZZER_MAXLEN]u8 = undefined;
    const n = std.fs.File.stdin().read(&buf) catch return;
    _ = LLVMFuzzerTestOneInput(&buf, n);
}
