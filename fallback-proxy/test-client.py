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
    argument_parser.add_argument(
        "expected_result",
        choices=["success", "rejected", "half-close"],
    )
    arguments = argument_parser.parse_args()

    with socket.create_connection(("127.0.0.1", arguments.proxy_port), timeout=5) as connection:
        connection.sendall(b"\x05\x01\x00")
        greeting_response = read_exactly(connection, 2)
        if greeting_response != b"\x05\x00":
            raise AssertionError(f"unexpected greeting response: {greeting_response!r}")

        destination = b"localhost"
        connection.sendall(
            b"\x05\x01\x00\x03"
            + bytes([len(destination)])
            + destination
            + arguments.destination_port.to_bytes(2, "big")
        )
        reply = read_reply(connection)

        if arguments.expected_result == "rejected":
            if reply[0] != 5:
                raise AssertionError(f"unexpected SOCKS version: {reply[0]}")
            if reply[1] == 0:
                raise AssertionError("request was not rejected")
            return

        if reply[0:4] not in (b"\x05\x00\x00\x01", b"\x05\x00\x00\x04"):
            raise AssertionError(f"unexpected success reply: {reply!r}")
        if not any(reply[4:-2]):
            raise AssertionError("bound address must not be unspecified")
        if int.from_bytes(reply[-2:], "big") == 0:
            raise AssertionError("bound port must not be zero")

        if arguments.expected_result == "half-close":
            connection.sendall(b"request-before-half-close")
            connection.shutdown(socket.SHUT_WR)
            if read_exactly(connection, 18) != b"response-after-eof":
                raise AssertionError("unexpected response after half-close")
            if connection.recv(1) != b"":
                raise AssertionError("destination connection remains open")


if __name__ == "__main__":
    main()
