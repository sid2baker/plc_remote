#!/usr/bin/env python3
import socket
import sys


def echo(connection):
    with connection:
        while True:
            payload = connection.recv(65536)
            if not payload:
                return
            connection.sendall(payload)


def main():
    port_file = sys.argv[1]

    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as server:
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.bind(("127.0.0.1", 0))
        server.listen(16)

        with open(port_file, "w", encoding="utf-8") as output:
            output.write(str(server.getsockname()[1]))
            output.flush()
        while True:
            connection, _address = server.accept()
            echo(connection)


if __name__ == "__main__":
    main()
