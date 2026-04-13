#!/usr/bin/env python3
# Copyright (c) 2026 Greg Turner <gmt@be-evil.net>
#
# Permission to use, copy, modify, and distribute this software for any
# purpose with or without fee is hereby granted, provided that the above
# copyright notice and this permission notice appear in all copies.
#
# THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
# WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
# MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
# ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
# WHATSOEVER RESULTING FROM LOSS OF MIND, USE, DATA OR PROFITS, WHETHER
# IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING
# OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

from __future__ import annotations

import argparse
import array
import enum
import os
import pathlib
import selectors
import signal
import socket
import stat
import struct
import sys
import textwrap
import time
from typing import BinaryIO


IMSG_HDR = struct.Struct("=IIII")
RECV_CHUNK = 65536
FD_WIDTH = 16
IMSG_FD_MARK = 0x80000000


class MsgType(enum.IntEnum):
    version = 12

    identify_flags = 100
    identify_term = 101
    identify_ttyname = 102
    identify_oldcwd = 103
    identify_stdin = 104
    identify_environ = 105
    identify_done = 106
    identify_clientpid = 107
    identify_cwd = 108
    identify_features = 109
    identify_stdout = 110
    identify_longflags = 111
    identify_terminfo = 112

    command = 200
    detach = 201
    detachkill = 202
    exit = 203
    exited = 204
    exiting = 205
    lock = 206
    ready = 207
    resize = 208
    shell = 209
    shutdown = 210
    oldstderr = 211
    oldstdin = 212
    oldstdout = 213
    suspend = 214
    unlock = 215
    wakeup = 216
    exec = 217
    flags = 218

    read_open = 300
    read = 301
    read_done = 302
    write_open = 303
    write = 304
    write_ready = 305
    write_close = 306
    read_cancel = 307


STRING_TYPES = {
    MsgType.identify_term,
    MsgType.identify_ttyname,
    MsgType.identify_oldcwd,
    MsgType.identify_environ,
    MsgType.identify_cwd,
    MsgType.identify_terminfo,
    MsgType.lock,
    MsgType.detach,
    MsgType.detachkill,
    MsgType.shell,
}


def die(message: str) -> "NoReturn":
    print(f"socket-spy: {message}", file=sys.stderr)
    raise SystemExit(1)


def hexdump(data: bytes) -> str:
    lines: list[str] = []
    for offset in range(0, len(data), FD_WIDTH):
        chunk = data[offset : offset + FD_WIDTH]
        hex_part = " ".join(f"{byte:02x}" for byte in chunk)
        ascii_part = "".join(chr(byte) if 32 <= byte < 127 else "." for byte in chunk)
        lines.append(f"{offset:04x}  {hex_part:<47}  {ascii_part}")
    return "\n".join(lines)


def printable_string(data: bytes) -> str | None:
    if not data:
        return ""
    if data[-1] != 0:
        return None
    raw = data[:-1]
    if not raw:
        return ""
    if any(byte < 0x20 and byte not in (0x09, 0x0A, 0x0D) for byte in raw):
        return None
    try:
        return raw.decode("utf-8", "backslashreplace")
    except UnicodeDecodeError:
        return raw.decode("latin-1", "backslashreplace")


def describe_payload(msg_type: int, payload: bytes) -> str | None:
    try:
        kind = MsgType(msg_type)
    except ValueError:
        return None

    if kind in STRING_TYPES:
        value = printable_string(payload)
        if value is not None:
            return f"string={value!r}"
        return None

    if kind == MsgType.command and len(payload) >= 4:
        argc = struct.unpack_from("=i", payload, 0)[0]
        argv_blob = payload[4:]
        argv = [
            part.decode("utf-8", "backslashreplace")
            for part in argv_blob.split(b"\x00")
            if part
        ]
        return f"argc={argc} argv={argv!r}"

    if kind in {MsgType.identify_features, MsgType.resize, MsgType.exit, MsgType.flags}:
        return f"payload={payload.hex()}"

    return None


class TimelineWriter:
    def __init__(self, output: BinaryIO, verbose: bool, raw: BinaryIO | None) -> None:
        self.output = output
        self.verbose = verbose
        self.raw = raw
        self.seq = 0
        self.buffers: dict[str, bytearray] = {
            "\u2192": bytearray(),
            "\u2190": bytearray(),
        }

    def log_chunk(self, data: bytes, fds: list[int], direction: str) -> None:
        if self.raw is not None:
            self.raw.write(data)
            self.raw.flush()
        self.buffers[direction].extend(data)
        self._drain_messages(direction)

    def _drain_messages(self, direction: str) -> None:
        buf = self.buffers[direction]
        while len(buf) >= IMSG_HDR.size:
            msg_type, raw_msg_len, peerid, pid = IMSG_HDR.unpack_from(buf)
            msg_len = raw_msg_len & ~IMSG_FD_MARK
            has_fd = bool(raw_msg_len & IMSG_FD_MARK)
            if msg_len < IMSG_HDR.size:
                self.output.write(f"# invalid imsg length {msg_len}\n")
                self.output.flush()
                return
            if len(buf) < msg_len:
                return
            frame = bytes(buf[:msg_len])
            del buf[:msg_len]

            self.seq += 1
            payload = frame[IMSG_HDR.size :]
            try:
                type_name = MsgType(msg_type).name
            except ValueError:
                type_name = f"unknown"

            summary = describe_payload(msg_type, payload)
            payload_str = f"  {summary}" if summary else ""
            fd_str = "  fd=1" if has_fd else ""

            self.output.write(
                f"{self.seq:5d}  {direction}  {type_name}({msg_type:<3d})"
                f"  len={msg_len:<6d} peerid={peerid}  pid={pid}{fd_str}{payload_str}\n"
            )
            if self.verbose:
                for line in hexdump(frame).splitlines():
                    self.output.write(f"          {line}\n")
            self.output.flush()


class Forwarder:
    def __init__(
        self,
        listen_path: pathlib.Path,
        connect_path: pathlib.Path,
        args: argparse.Namespace,
    ) -> None:
        self.listen_path = listen_path
        self.connect_path = connect_path
        self.args = args
        self.selector = selectors.DefaultSelector()
        self.client_sock: socket.socket | None = None
        self.server_sock: socket.socket | None = None
        self.shutdown_sent: set[socket.socket] = set()

    def run(self) -> int:
        if str(self.args.output) == "-":
            output_file = sys.stdout
        else:
            output_file = open(self.args.output, "w", encoding="utf-8")

        raw_file = None
        if self.args.raw:
            raw_file = open(self.args.raw, "wb")

        self.timeline = TimelineWriter(output_file, self.args.verbose, raw_file)

        output_file.write("# socket-spy trace\n")
        output_file.write(f"# server: {self.connect_path}\n")
        output_file.write(f"# proxy: {self.listen_path}\n")
        output_file.write(f"# started: {time.strftime('%Y-%m-%dT%H:%M:%S')}\n")
        output_file.write("#\n")
        output_file.flush()

        try:
            self.listen_path.unlink()
        except FileNotFoundError:
            pass

        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        listener.bind(str(self.listen_path))
        listener.listen(1)
        os.chmod(self.listen_path, stat.S_IRUSR | stat.S_IWUSR)

        print(f"listen: {self.listen_path}", file=sys.stderr)
        print(f"connect: {self.connect_path}", file=sys.stderr)
        sys.stderr.flush()

        self.client_sock, _ = listener.accept()
        listener.close()

        self.server_sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.server_sock.connect(str(self.connect_path))

        self.client_sock.setblocking(False)
        self.server_sock.setblocking(False)

        self.selector.register(
            self.client_sock, selectors.EVENT_READ, (self.server_sock, "\u2192")
        )
        self.selector.register(
            self.server_sock, selectors.EVENT_READ, (self.client_sock, "\u2190")
        )

        try:
            while self.selector.get_map():
                for key, _ in self.selector.select():
                    source: socket.socket = key.fileobj
                    peer, direction = key.data
                    if not self._forward_once(source, peer, direction):
                        self._close_half(source, peer)
        finally:
            if output_file is not sys.stdout:
                output_file.close()
            if raw_file is not None:
                raw_file.close()
            self._cleanup()

        return 0

    def _forward_once(
        self, source: socket.socket, peer: socket.socket, direction: str
    ) -> bool:
        ancbuf = socket.CMSG_SPACE(4 * array.array("i").itemsize)
        try:
            data, ancdata, _msg_flags, _address = source.recvmsg(RECV_CHUNK, ancbuf)
        except BlockingIOError:
            return True

        if not data and not ancdata:
            return False

        fds = self._extract_fds(ancdata)
        self.timeline.log_chunk(data, fds, direction)

        out_anc: list[tuple[int, int, bytes]] = []
        if fds:
            fd_array = array.array("i", fds)
            out_anc.append((socket.SOL_SOCKET, socket.SCM_RIGHTS, fd_array.tobytes()))

        try:
            peer.sendmsg([data], out_anc)
        finally:
            for fd in fds:
                try:
                    os.close(fd)
                except OSError:
                    pass
        return True

    def _extract_fds(self, ancdata: list[tuple[int, int, bytes]]) -> list[int]:
        fds: list[int] = []
        for level, ctype, cdata in ancdata:
            if level != socket.SOL_SOCKET or ctype != socket.SCM_RIGHTS:
                continue
            fd_array = array.array("i")
            usable = len(cdata) - (len(cdata) % fd_array.itemsize)
            fd_array.frombytes(cdata[:usable])
            fds.extend(fd_array.tolist())
        return fds

    def _close_half(self, source: socket.socket, peer: socket.socket) -> None:
        try:
            self.selector.unregister(source)
        except Exception:
            pass
        try:
            source.close()
        except OSError:
            pass
        if peer not in self.shutdown_sent:
            try:
                peer.shutdown(socket.SHUT_WR)
            except OSError:
                pass
            self.shutdown_sent.add(peer)

    def _cleanup(self) -> None:
        self.selector.close()
        for sock in (self.client_sock, self.server_sock):
            if sock is None:
                continue
            try:
                sock.close()
            except OSError:
                pass
        try:
            self.listen_path.unlink()
        except FileNotFoundError:
            pass


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="socket-spy",
        description="transparent UNIX socket MITM proxy that captures the zmux/tmux wire protocol as a merged timeline",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=textwrap.dedent(
            """\
            Example:
              python3 regress/socket_spy.py \\
                --listen /tmp/fake.sock \\
                --connect /tmp/real.sock \\
                --output /tmp/trace.log
            """
        ),
    )
    parser.add_argument(
        "--listen",
        required=True,
        type=pathlib.Path,
        help="proxy socket path clients connect to",
    )
    parser.add_argument(
        "--connect",
        required=True,
        type=pathlib.Path,
        help="real server socket path to forward to",
    )
    parser.add_argument(
        "--output", default="-", help="output path for timeline trace (default: stdout)"
    )
    parser.add_argument(
        "--verbose", action="store_true", help="include hex dumps after each message"
    )
    parser.add_argument("--raw", default=None, help="optional path for raw binary dump")
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)

    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))

    proxy = Forwarder(args.listen.resolve(), args.connect.resolve(), args)
    return proxy.run()


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
