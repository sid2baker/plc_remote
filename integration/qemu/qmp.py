#!/usr/bin/env python3
import argparse
import json
import socket


def receive(file):
    line = file.readline()
    if not line:
        raise RuntimeError("QMP connection closed")
    return json.loads(line)


def execute(file, command, arguments=None):
    payload = {"execute": command}
    if arguments:
        payload["arguments"] = arguments
    file.write((json.dumps(payload) + "\n").encode())
    file.flush()

    while True:
        reply = receive(file)
        if "return" in reply:
            return reply["return"]
        if "error" in reply:
            raise RuntimeError(reply["error"])


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--socket", required=True)
    parser.add_argument("--device")
    parser.add_argument("--up", action="store_true")
    parser.add_argument("--down", action="store_true")
    parser.add_argument("--shutdown", action="store_true")
    args = parser.parse_args()

    if args.shutdown:
        if args.device or args.up or args.down:
            parser.error("--shutdown cannot be combined with link options")
    elif not args.device or args.up == args.down:
        parser.error("specify --device and exactly one of --up or --down")

    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
        sock.connect(args.socket)
        file = sock.makefile("rwb")
        receive(file)
        execute(file, "qmp_capabilities")

        if args.shutdown:
            execute(file, "system_powerdown")
        else:
            execute(file, "set_link", {"name": args.device, "up": args.up})


if __name__ == "__main__":
    main()
