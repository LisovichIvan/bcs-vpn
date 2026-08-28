#!/usr/bin/env python3

import argparse
import socket
import time


def read_exactly(connection: socket.socket, byte_count: int) -> bytes:
    result = b""
    while len(result) < byte_count:
        chunk = connection.recv(byte_count - len(result))
        if not chunk:
            raise ConnectionError("connection closed")
        result += chunk
    return result


def read_request(connection: socket.socket) -> None:
    request_header = read_exactly(connection, 4)
    address_type = request_header[3]
    if address_type == 1:
        read_exactly(connection, 6)
    elif address_type == 3:
        domain_length = read_exactly(connection, 1)[0]
        read_exactly(connection, domain_length + 2)
    elif address_type == 4:
        read_exactly(connection, 18)
    else:
        raise ValueError(f"unsupported address type: {address_type}")


def main() -> None:
    argument_parser = argparse.ArgumentParser()
    argument_parser.add_argument(
        "mode",
        choices=[
            "close-after-greeting",
            "hang-after-request",
            "malformed-replies",
            "reject-request",
        ],
    )
    argument_parser.add_argument("port", type=int)
    arguments = argument_parser.parse_args()

    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as server_socket:
        server_socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server_socket.bind(("127.0.0.1", arguments.port))
        server_socket.listen(1)

        malformed_replies = [
            b"\x04\x00\x00\x01\x7f\x00\x00\x01\x30\x39",
            b"\x05\x09\x00\x01\x7f\x00\x00\x01\x30\x39",
            b"\x05\x00\x01\x01\x7f\x00\x00\x01\x30\x39",
            b"\x05\x00\x00\x02",
        ]
        connection_count = len(malformed_replies) if arguments.mode == "malformed-replies" else 1

        for connection_index in range(connection_count):
            connection, _ = server_socket.accept()
            with connection:
                read_exactly(connection, 3)
                if arguments.mode == "close-after-greeting":
                    return

                connection.sendall(b"\x05\x00")
                read_request(connection)
                if arguments.mode == "hang-after-request":
                    time.sleep(5)
                elif arguments.mode == "malformed-replies":
                    connection.sendall(malformed_replies[connection_index])
                else:
                    connection.sendall(b"\x05\x05\x00\x01\x7f\x00\x00\x01\x30\x39")


if __name__ == "__main__":
    main()
