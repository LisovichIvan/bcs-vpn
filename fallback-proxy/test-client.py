#!/usr/bin/env python3

import argparse
import socket


def read_exactly(connection: socket.socket, byte_count: int) -> bytes:
    result = b""
    while len(result) < byte_count:
        chunk = connection.recv(byte_count - len(result))
        if not chunk:
            raise ConnectionError("connection closed")
        result += chunk
    return result


def read_reply(connection: socket.socket) -> bytes:
    reply_header = read_exactly(connection, 4)
    address_type = reply_header[3]
    if address_type == 1:
        reply_tail = read_exactly(connection, 6)
    elif address_type == 4:
        reply_tail = read_exactly(connection, 18)
    else:
        raise AssertionError(f"unexpected address type: {address_type}")
    return reply_header + reply_tail


def main() -> None:
    argument_parser = argparse.ArgumentParser()
    argument_parser.add_argument("proxy_port", type=int)
    argument_parser.add_argument("destination_port", type=int)
    argument_parser.add_argument("expected_result", choices=["success", "rejected"])
    arguments = argument_parser.parse_args()

    with socket.create_connection(("127.0.0.1", arguments.proxy_port), timeout=5) as connection:
        connection.sendall(b"\x05\x01\x00")
        assert read_exactly(connection, 2) == b"\x05\x00"

        destination = b"localhost"
        connection.sendall(
            b"\x05\x01\x00\x03"
            + bytes([len(destination)])
            + destination
            + arguments.destination_port.to_bytes(2, "big")
        )
        reply = read_reply(connection)

        if arguments.expected_result == "rejected":
            assert reply[0] == 5
            assert reply[1] != 0
            return

        assert reply[0:4] in (b"\x05\x00\x00\x01", b"\x05\x00\x00\x04")
        assert any(reply[4:-2]), "bound address must not be unspecified"
        assert int.from_bytes(reply[-2:], "big") != 0, "bound port must not be zero"


if __name__ == "__main__":
    main()
