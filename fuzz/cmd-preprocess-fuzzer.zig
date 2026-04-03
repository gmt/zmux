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
//! LibFuzzer harness for `cmd_parse_from_string` (preprocess + tokenise + parse-one).

const std = @import("std");
const zmux = @import("zmux");
const T = zmux.fuzz.T;
const cmd = zmux.fuzz.cmd;
const xm = zmux.fuzz.xm;

const FUZZER_MAXLEN = 4096;

export fn LLVMFuzzerTestOneInput(data: [*]const u8, size: usize) i32 {
    if (size > FUZZER_MAXLEN) return 0;

    var pi = T.CmdParseInput{
        .flags = T.CMD_PARSE_PARSEONLY,
        .c = null,
        .fs = .{},
    };
    const parsed = cmd.cmd_parse_from_string(data[0..size], &pi);
    switch (parsed.status) {
        .success => {
            if (parsed.cmdlist) |opaque_list| {
                const list: *cmd.CmdList = @ptrCast(@alignCast(opaque_list));
                cmd.cmd_list_free(list);
            }
        },
        .@"error" => {
            if (parsed.@"error") |msg| xm.allocator.free(msg);
        },
    }
    return 0;
}

export fn LLVMFuzzerInitialize(_argc: *c_int, _argv: *[*c][*c]u8) i32 {
    _ = _argc;
    _ = _argv;
    return 0;
}

pub fn main() void {
    var buf: [FUZZER_MAXLEN]u8 = undefined;
    const n = std.fs.File.stdin().read(&buf) catch return;
    _ = LLVMFuzzerTestOneInput(&buf, n);
}
