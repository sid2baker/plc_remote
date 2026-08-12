#!/usr/bin/env python3
import argparse
import os
import selectors
import socket
import sys
import time
import re

MARKER = b"PLC_REMOTE_CI:"
PROMPT = re.compile(rb"iex\(\d+\)>")


def connect(path: str, timeout: float) -> socket.socket:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            sock.connect(path)
            sock.setblocking(False)
            return sock
        except (FileNotFoundError, ConnectionRefusedError):
            time.sleep(0.1)
    raise TimeoutError(f"console socket was not ready: {path}")


def read_until(sock: socket.socket, needle, timeout: float, log) -> bytes:
    deadline = time.monotonic() + timeout
    next_nudge = time.monotonic() + 0.5
    selector = selectors.DefaultSelector()
    selector.register(sock, selectors.EVENT_READ)
    data = bytearray()

    while time.monotonic() < deadline:
        now = time.monotonic()
        if needle is PROMPT and now >= next_nudge:
            sock.sendall(b"\n")
            next_nudge = now + 0.5

        events = selector.select(min(0.25, deadline - now))
        for key, _mask in events:
            chunk = key.fileobj.recv(65536)
            if not chunk:
                raise RuntimeError("QEMU console closed")
            log.write(chunk)
            log.flush()
            data.extend(chunk)
            matched = needle.search(data) if hasattr(needle, "search") else needle in data
            if matched:
                return bytes(data)

    raise TimeoutError(f"did not receive {needle!r} from QEMU console")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--socket", required=True)
    parser.add_argument("--log", required=True)
    parser.add_argument("--boot-timeout", type=float, default=180)
    parser.add_argument("--command-timeout", type=float, default=60)
    parser.add_argument("command", nargs="+")
    args = parser.parse_args()

    os.makedirs(os.path.dirname(args.log), exist_ok=True)
    with open(args.log, "ab", buffering=0) as log:
        sock = connect(args.socket, args.boot_timeout)
        with sock:
            # A reconnect to the serial chardev has no buffered prompt. A blank
            # line is harmless during boot and asks an existing IEx for one.
            sock.sendall(b"\n")
            read_until(sock, PROMPT, args.boot_timeout, log)

            for command in args.command:
                sock.sendall(command.encode("utf-8") + b"\n")
                output = read_until(sock, MARKER, args.command_timeout, log)
                output += read_until(sock, b"\n", args.command_timeout, log)
                marker_line = (
                    output.rsplit(MARKER, 1)[1]
                    .splitlines()[0]
                    .decode("utf-8", errors="replace")
                )
                print("PLC_REMOTE_CI:" + marker_line)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
