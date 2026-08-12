#!/usr/bin/env python3
import argparse
import socket


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("host")
    parser.add_argument("port", type=int)
    parser.add_argument("--payload", default="plc-remote-tailnet")
    parser.add_argument("--timeout", type=float, default=30)
    args = parser.parse_args()

    payload = args.payload.encode()
    with socket.create_connection((args.host, args.port), timeout=args.timeout) as connection:
        connection.sendall(payload)
        received = bytearray()

        while len(received) < len(payload):
            chunk = connection.recv(len(payload) - len(received))
            if not chunk:
                raise RuntimeError("proxy closed before returning the payload")
            received.extend(chunk)

    if bytes(received) != payload:
        raise RuntimeError("proxy returned a different payload")

    print("Live tailnet PLC proxy echo passed")


if __name__ == "__main__":
    main()
