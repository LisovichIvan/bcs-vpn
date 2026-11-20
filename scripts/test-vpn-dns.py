#!/usr/bin/env python3
"""Exercise only the DNS helper command against synthetic loopback SOCKS peers."""

from contextlib import contextmanager
from pathlib import Path
import socket
import subprocess
import sys
import threading
import time
import unittest


HELPER_PATH = Path(sys.argv.pop(1)).resolve()
HOSTNAME = "lookup.example.invalid"
SUCCESS_RESPONSE = bytes([5, 0, 0, 1, 203, 0, 113, 7, 0, 0])


def receive_exact(connection, byte_count):
    result = bytearray()
    while len(result) < byte_count:
        chunk = connection.recv(byte_count - len(result))
        if not chunk:
            raise AssertionError("helper closed before sending its complete request")
        result.extend(chunk)
    return bytes(result)


@contextmanager
def socks_peer(response=SUCCESS_RESPONSE, greeting=b"\x05\x00", fragmented=False,
               fragment_interval=0.003, stall=False, expected_hostname=HOSTNAME):
    stopped = threading.Event()
    accepted = threading.Event()
    errors = []
    requests = []
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
        listener.bind(("127.0.0.1", 0))
        port = listener.getsockname()[1]
        if port in (8889, 8890):
            raise AssertionError("fixture must not use live VPN ports")
        listener.listen(1)
        listener.settimeout(0.05)

        def serve():
            try:
                while not stopped.is_set():
                    try:
                        connection, _ = listener.accept()
                        break
                    except socket.timeout:
                        continue
                else:
                    return
                accepted.set()
                with connection:
                    connection.settimeout(2)
                    if receive_exact(connection, 3) != b"\x05\x01\x00":
                        raise AssertionError("unexpected SOCKS greeting")
                    connection.sendall(greeting)
                    if greeting != b"\x05\x00":
                        return
                    header = receive_exact(connection, 5)
                    request = header + receive_exact(connection, header[4] + 2)
                    requests.append(request)
                    hostname_bytes = expected_hostname.encode("ascii")
                    if request != b"\x05\xf0\x00\x03" + bytes([len(hostname_bytes)]) + hostname_bytes + b"\x00\x00":
                        raise AssertionError("helper must send only RESOLVE, never CONNECT")
                    if stall:
                        stopped.wait(2)
                    elif fragmented:
                        for byte in response:
                            connection.sendall(bytes([byte]))
                            stopped.wait(fragment_interval)
                    else:
                        connection.sendall(response)
            except OSError as error:
                if not stopped.is_set():
                    errors.append(error)
            except Exception as error:
                errors.append(error)

        thread = threading.Thread(target=serve, name="synthetic-socks-peer", daemon=True)
        thread.start()
        try:
            yield port, accepted, requests
        finally:
            stopped.set()
            thread.join(timeout=3)
            if thread.is_alive():
                raise AssertionError("fixture thread did not stop")
            if errors:
                raise AssertionError(str(errors[0]))


class VPNDNSHelperTests(unittest.TestCase):
    def invoke(self, port, hostname=HOSTNAME, timeout_ms=1000):
        return subprocess.run(
            [str(HELPER_PATH), "resolve-host-test", hostname, str(port), str(timeout_ms)],
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, timeout=3, env={"PATH": "/usr/bin:/bin"},
        )

    def assert_failed(self, result):
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertTrue(result.stderr.strip())

    def test_success_and_fragmented_reply(self):
        for fragmented in (False, True):
            with self.subTest(fragmented=fragmented), socks_peer(fragmented=fragmented) as (port, accepted, requests):
                result = self.invoke(port)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, "203.0.113.7\n")
                self.assertEqual(result.stderr, "")
                self.assertTrue(accepted.is_set())
                self.assertEqual(len(requests), 1)

    def test_hostname_boundaries_and_trailing_dot(self):
        maximum_hostname = ".".join(["a" * 63, "b" * 63, "c" * 63, "d" * 61])
        self.assertEqual(len(maximum_hostname), 253)
        for supplied, normalized in ((HOSTNAME + ".", HOSTNAME), (maximum_hostname, maximum_hostname)):
            with self.subTest(hostname=supplied), socks_peer(expected_hostname=normalized) as (port, _, _):
                result = self.invoke(port, hostname=supplied)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, "203.0.113.7\n")

    def test_protocol_errors_and_eof(self):
        responses = [
            b"", SUCCESS_RESPONSE[:1], SUCCESS_RESPONSE[:7],
            bytes([4]) + SUCCESS_RESPONSE[1:],
            SUCCESS_RESPONSE[:2] + bytes([1]) + SUCCESS_RESPONSE[3:],
            SUCCESS_RESPONSE[:3] + bytes([4]) + SUCCESS_RESPONSE[4:],
            SUCCESS_RESPONSE[:-1] + bytes([80]),
            bytes([5, 4, 0, 1, 0, 0, 0, 0, 0, 0]),
        ]
        for response in responses:
            with self.subTest(response=response), socks_peer(response=response) as (port, _, _):
                self.assert_failed(self.invoke(port))

    def test_unsupported_resolve_has_actionable_error(self):
        with socks_peer(response=bytes([5, 7, 0, 1, 0, 0, 0, 0, 0, 0])) as (port, _, _):
            result = self.invoke(port)
            self.assert_failed(result)
            self.assertIn("не поддерживает RESOLVE", result.stderr)

    def test_incomplete_or_rejected_greeting(self):
        for greeting in (b"\x05", b"\x05\x02", b"\x04\x00"):
            with self.subTest(greeting=greeting), socks_peer(greeting=greeting) as (port, _, requests):
                self.assert_failed(self.invoke(port))
                self.assertEqual(requests, [])

    def test_timeout_is_bounded(self):
        with socks_peer(stall=True) as (port, _, _):
            result = self.invoke(port, timeout_ms=120)
            self.assert_failed(result)
            self.assertIn("таймаут", result.stderr)

    def test_slow_reply_cannot_extend_total_deadline(self):
        with socks_peer(fragmented=True, fragment_interval=0.04) as (port, _, _):
            started_at = time.monotonic()
            result = self.invoke(port, timeout_ms=120)
            self.assert_failed(result)
            self.assertIn("таймаут", result.stderr)
            self.assertLess(time.monotonic() - started_at, 0.6)

    def test_invalid_hostnames_do_not_connect(self):
        for hostname in ("", ".", "bad..example", "-bad.example", "bad-.example", "_service.example", "é.example", "a" * 64 + ".example", "a" * 254, "bad\nexample"):
            with self.subTest(hostname=hostname), socks_peer() as (port, accepted, _):
                self.assert_failed(self.invoke(port, hostname=hostname))
                self.assertFalse(accepted.is_set())

    def test_bound_non_listening_port_is_bounded(self):
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as reserved:
            reserved.bind(("127.0.0.1", 0))
            # Keep a bound, non-listening port separate from the closed-port fixture.
            result = self.invoke(reserved.getsockname()[1], timeout_ms=120)
            self.assert_failed(result)

    def test_connection_refused(self):
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as reserved:
            reserved.bind(("127.0.0.1", 0))
            closed_port = reserved.getsockname()[1]
        result = self.invoke(closed_port)
        self.assert_failed(result)
        self.assertIn("connect:", result.stderr)


if __name__ == "__main__":
    unittest.main()
