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

//! c.zig – single point of @cImport for all external C libraries.
//!
//! Every other .zig file that needs C types or functions imports this module:
//!   const c = @import("c.zig");
//! then accesses symbols as c.event_base_new(), c.imsg_compose(), etc.

pub const libevent = @cImport({
    @cInclude("event2/event.h");
    @cInclude("event2/bufferevent.h");
    @cInclude("event2/buffer.h");
    @cInclude("event2/util.h");
    @cInclude("event2/event_compat.h");
});

pub const ncurses = @cImport({
    @cDefine("NCURSES_WIDECHAR", "1");
    @cInclude("curses.h");
    @cInclude("term.h");
});

pub const imsg = @cImport({
    @cInclude("sys/types.h");
    @cInclude("sys/socket.h");
    @cInclude("sys/uio.h");
    @cInclude("sys/queue.h");
    @cInclude("stdint.h");
    @cInclude("imsg.h");
});

pub const posix_sys = @cImport({
    @cInclude("sys/types.h");
    @cInclude("sys/stat.h");
    @cInclude("sys/ioctl.h");
    @cInclude("sys/utsname.h");
    @cInclude("fcntl.h");
    @cInclude("termios.h");
    @cInclude("pty.h");
    @cInclude("unistd.h");
    @cInclude("signal.h");
    @cInclude("pwd.h");
    @cInclude("fnmatch.h");
    @cInclude("wchar.h");
});
