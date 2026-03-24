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
// Ported from tmux/tmux-protocol.h
// Original copyright:
//   Copyright (c) 2021 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

//! tmux-protocol.zig – IPC wire protocol constants and message structs.
//!
//! This is a near-verbatim port of tmux-protocol.h.  The protocol version
//! must stay in sync with the C header; bump PROTOCOL_VERSION when any wire
//! struct changes.

pub const PROTOCOL_VERSION: u32 = 8;

/// IPC message types exchanged between client and server.
pub const MsgType = enum(c_int) {
    version = 12,

    identify_flags = 100,
    identify_term,
    identify_ttyname,
    identify_oldcwd, // unused
    identify_stdin,
    identify_environ,
    identify_done,
    identify_clientpid,
    identify_cwd,
    identify_features,
    identify_stdout,
    identify_longflags,
    identify_terminfo,

    command = 200,
    detach,
    detachkill,
    exit,
    exited,
    exiting,
    lock,
    ready,
    resize,
    shell,
    shutdown,
    oldstderr, // unused
    oldstdin, // unused
    oldstdout, // unused
    @"suspend",
    unlock,
    wakeup,
    exec,
    flags,

    read_open = 300,
    read,
    read_done,
    write_open,
    write,
    write_ready,
    write_close,
    read_cancel,
};

// ── Wire payload structs (keep in sync with tmux-protocol.h) ──────────────

/// Payload for MSG_COMMAND – followed by packed argv strings.
pub const MsgCommand = extern struct {
    argc: c_int,
};

pub const MsgReadOpen = extern struct {
    stream: c_int,
    fd: c_int,
    // followed by path string
};

pub const MsgReadData = extern struct {
    stream: c_int,
};

pub const MsgReadDone = extern struct {
    stream: c_int,
    @"error": c_int,
};

pub const MsgReadCancel = extern struct {
    stream: c_int,
};

pub const MsgWriteOpen = extern struct {
    stream: c_int,
    fd: c_int,
    flags: c_int,
    // followed by path string
};

pub const MsgWriteData = extern struct {
    stream: c_int,
    // followed by data
};

pub const MsgWriteReady = extern struct {
    stream: c_int,
    @"error": c_int,
};

pub const MsgWriteClose = extern struct {
    stream: c_int,
};
