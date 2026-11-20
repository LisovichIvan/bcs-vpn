#!/usr/bin/env python3
"""Offline real-ocproxy SOCKS5 RESOLVE tests; no host DNS, VPN or route changes.

Run: python3 -B scripts/test-ocproxy-resolve.py [--ocproxy /path/to/ocproxy]
Only loopback TCP and an AF_UNIX datagram pair carry traffic. DNS packets are
synthetic IPv4/UDP; every unexpected VPN packet (including TCP SYN) fails.
"""

import argparse
import os
from pathlib import Path
import select
import socket
import struct
import subprocess
import sys
import tempfile
import time
import unittest

PROJECT_DIRECTORY = Path(__file__).resolve().parent.parent
OCPROXY = PROJECT_DIRECTORY / "vendor/macos-arm64/bin/ocproxy"
HOSTNAME = b"lookup.example.invalid"
ANSWER = "203.0.113.7"
VPN_ADDRESS = "10.0.0.2"
DNS_ADDRESS = "10.0.0.53"
QUESTION = b"".join(bytes([len(label)]) + label for label in HOSTNAME.split(b"."))
QUESTION += b"\0" + struct.pack("!HH", 1, 1)
TIMEOUT = 3.0


def ipv4_checksum(header):
    words = struct.unpack("!%dH" % (len(header) // 2), header)
    total = sum(words)
    while total >> 16:
        total = (total & 0xFFFF) + (total >> 16)
    return (~total) & 0xFFFF


def domain_request(command=0xF0, hostname=HOSTNAME, port=0):
    return bytes([5, command, 0, 3, len(hostname)]) + hostname + struct.pack("!H", port)


class ResolveTests(unittest.TestCase):
    def setUp(self):
        run_directory = PROJECT_DIRECTORY / "run"
        run_directory.resolve().relative_to(PROJECT_DIRECTORY)
        run_directory.mkdir(exist_ok=True)
        temporary = tempfile.TemporaryDirectory(prefix="ocproxy-resolve-", dir=run_directory)
        self.addCleanup(temporary.cleanup)
        self.vpn, child_vpn = socket.socketpair(socket.AF_UNIX, socket.SOCK_DGRAM)
        self.addCleanup(self.vpn.close)
        self.addCleanup(child_vpn.close)
        self.vpn.settimeout(TIMEOUT)
        for attempt in range(10):
            with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as reservation:
                reservation.bind(("127.0.0.1", 0))
                self.port = reservation.getsockname()[1]
            if self.port not in (8889, 8890):
                break
        else:
            self.fail("Could not reserve a safe ephemeral loopback port")
        environment = {
            "VPNFD": str(child_vpn.fileno()),
            "INTERNAL_IP4_ADDRESS": VPN_ADDRESS,
            "INTERNAL_IP4_MTU": "1400",
            "INTERNAL_IP4_DNS": DNS_ADDRESS,
            "TMPDIR": temporary.name,
        }
        self.process = subprocess.Popen(
            [str(OCPROXY), "-D", str(self.port)], env=environment,
            pass_fds=(child_vpn.fileno(),), cwd=temporary.name,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        self.addCleanup(self.stop_process)
        child_vpn.close()
        deadline = time.monotonic() + TIMEOUT
        while time.monotonic() < deadline:
            self.assertIsNone(self.process.poll(), "ocproxy exited before listener was ready")
            with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
                probe.settimeout(0.1)
                try:
                    probe.connect(("127.0.0.1", self.port))
                    return
                except (ConnectionRefusedError, TimeoutError):
                    time.sleep(0.02)
        self.fail("ocproxy loopback listener did not become ready before deadline")

    def stop_process(self):
        unexpected_exit = self.process.poll()
        if unexpected_exit is None:
            self.process.terminate()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait(timeout=5)
        self.assertIsNone(unexpected_exit, "ocproxy exited unexpectedly during the test")
        self.assertIn(self.process.returncode, (-15, 0), "ocproxy crashed during cleanup")

    def client(self):
        client = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.addCleanup(client.close)
        client.settimeout(TIMEOUT)
        client.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        client.connect(("127.0.0.1", self.port))
        client.sendall(b"\x05\x01\x00")
        self.assertEqual(self.receive(client, 2), b"\x05\x00")
        return client

    def ready(self, clients=(), timeout=TIMEOUT):
        deadline = time.monotonic() + timeout
        while True:
            remaining = max(0, deadline - time.monotonic())
            ready = select.select([self.vpn, *clients], [], [], remaining)[0]
            if self.vpn in ready and self.vpn.recv(65535, socket.MSG_PEEK) == b"":
                # The upstream housekeeping timer sends zero-byte liveness datagrams.
                self.vpn.recv(65535)
                ready.remove(self.vpn)
                if not ready and time.monotonic() < deadline:
                    continue
            return ready

    def receive(self, client, count):
        received = b""
        deadline = time.monotonic() + TIMEOUT
        while len(received) < count:
            remaining = deadline - time.monotonic()
            self.assertGreater(remaining, 0, "SOCKS receive deadline expired")
            ready = self.ready((client,), remaining)
            self.assertNotIn(self.vpn, ready, "Unexpected VPN packet, not just a SOCKS reply")
            self.assertIn(client, ready, "SOCKS response/close timed out")
            chunk = client.recv(count - len(received))
            if not chunk:
                break
            received += chunk
        return received

    def quiet(self, *clients):
        self.assertEqual(self.ready(clients, 0.1), [],
                         "Unexpected VPN traffic or premature SOCKS response/close")

    def reply(self, client, code=0, address=None):
        response = self.receive(client, 10)
        self.assertEqual(len(response), 10, "Truncated SOCKS5 IPv4 reply")
        self.assertEqual(response[:4], bytes([5, code, 0, 1]),
                         "Wrong SOCKS5 reply (RESOLVE must not return command-unsupported 7)")
        self.assertEqual(response[-2:], b"\0\0", "RESOLVE reply port must be zero")
        if address is not None:
            self.assertEqual(response[4:8], socket.inet_aton(address), "Address byte order/value")
        self.assertEqual(self.receive(client, 1), b"", "RESOLVE must close after its reply")
        self.quiet()

    def ipv4_payload(self, packet, protocol, destination):
        self.assertGreaterEqual(len(packet), 20)
        self.assertEqual(packet[0] >> 4, 4)
        header_length = (packet[0] & 15) * 4
        self.assertGreaterEqual(header_length, 20)
        self.assertGreaterEqual(len(packet), header_length)
        self.assertEqual(struct.unpack("!H", packet[2:4])[0], len(packet))
        self.assertEqual(ipv4_checksum(packet[:header_length]), 0)
        self.assertEqual(struct.unpack("!H", packet[6:8])[0] & 0x3FFF, 0)
        self.assertEqual(packet[9], protocol, "Unexpected VPN protocol (RESOLVE must not send TCP)")
        self.assertEqual(packet[12:16], socket.inet_aton(VPN_ADDRESS))
        self.assertEqual(packet[16:20], socket.inet_aton(destination))
        return packet[header_length:]

    def dns_query(self, client):
        ready = self.ready((client,))
        if client in ready:
            early = client.recv(10)
            code = early[1] if len(early) >= 2 else "closed/truncated"
            self.fail(f"Expected asynchronous DNS query; SOCKS replied first (REP={code})")
        self.assertIn(self.vpn, ready, "No lwIP DNS query before deadline")
        udp = self.ipv4_payload(self.vpn.recv(65535), 17, DNS_ADDRESS)
        self.assertGreaterEqual(len(udp), 20)
        source_port, destination_port, length, checksum = struct.unpack("!HHHH", udp[:8])
        self.assertGreater(source_port, 0)
        self.assertEqual(destination_port, 53)
        self.assertEqual(length, len(udp))
        identifier, flags, questions, answers, authority, additional = struct.unpack("!HHHHHH", udp[8:20])
        self.assertEqual((flags & 0xF800, questions, answers, authority, additional), (0, 1, 0, 0, 0))
        self.assertEqual(udp[20:], QUESTION, "Expected lookup.example.invalid IN A")
        self.quiet(client)  # Neither reply nor another packet before the fixture answers.
        return identifier, source_port

    def answer_dns(self, query, nxdomain=False):
        identifier, destination_port = query
        dns = struct.pack("!HHHHHH", identifier, 0x8183 if nxdomain else 0x8180,
                          1, 0 if nxdomain else 1, 0, 0) + QUESTION
        if not nxdomain:
            dns += b"\xc0\x0c" + struct.pack("!HHIH", 1, 1, 60, 4) + socket.inet_aton(ANSWER)
        udp = struct.pack("!HHHH", 53, destination_port, len(dns) + 8, 0) + dns
        header = struct.pack("!BBHHHBBH4s4s", 0x45, 0, len(udp) + 20, 1, 0, 64, 17, 0,
                             socket.inet_aton(DNS_ADDRESS), socket.inet_aton(VPN_ADDRESS))
        header = header[:10] + struct.pack("!H", ipv4_checksum(header)) + header[12:]
        self.assertEqual(self.vpn.send(header + udp), len(header) + len(udp))

    def resolve(self):
        client = self.client()
        client.sendall(domain_request())
        self.answer_dns(self.dns_query(client))
        self.reply(client, address=ANSWER)

    def expect_syn(self):
        self.assertTrue(self.ready(), "CONNECT emitted no SYN")
        tcp = self.ipv4_payload(self.vpn.recv(65535), 6, ANSWER)
        self.assertGreaterEqual(len(tcp), 20)
        self.assertEqual(struct.unpack("!H", tcp[2:4])[0], 443)
        self.assertEqual(tcp[13] & 0x12, 0x02, "CONNECT must emit SYN without ACK")

    def test_resolve_async_dns_success(self):
        self.resolve()

    def test_resolve_cached_success_without_any_vpn_packet(self):
        self.resolve()
        client = self.client()
        client.sendall(domain_request())
        self.reply(client, address=ANSWER)

    def test_resolve_nxdomain_returns_host_unreachable_4(self):
        client = self.client()
        client.sendall(domain_request())
        self.answer_dns(self.dns_query(client), nxdomain=True)
        self.reply(client, code=4)

    def test_resolve_numeric_domain_immediate_without_any_vpn_packet(self):
        client = self.client()
        client.sendall(domain_request(hostname=ANSWER.encode("ascii")))
        self.reply(client, address=ANSWER)

    def test_resolve_fragmented_until_complete_domain_and_port(self):
        client = self.client()
        frame = domain_request()
        start = 0
        for end in (4, 5, 10, len(frame) - 2, len(frame) - 1):
            client.sendall(frame[start:end])
            self.quiet(client)
            start = end
        client.sendall(frame[start:])
        self.answer_dns(self.dns_query(client))
        self.reply(client, address=ANSWER)

    def test_resolve_rejects_invalid_hostnames_before_dns(self):
        for hostname in (b"", b"lookup\0.example.invalid", b"bad..example", b"-bad.example",
                         b"bad-.example", b"a" * 64 + b".example", b"a" * 254, b"bad\nexample"):
            with self.subTest(hostname=hostname):
                client = self.client()
                client.sendall(domain_request(hostname=hostname))
                self.reply(client, code=8)
                client.close()

    def test_resolve_unsupported_address_type_returns_8(self):
        client = self.client()
        client.sendall(b"\x05\xf0\x00\x09\0\0")
        self.reply(client, code=8)

    def test_unsupported_command_returns_7(self):
        client = self.client()
        client.sendall(domain_request(command=0x7E))
        self.reply(client, code=7)

    def test_connect_numeric_ip_still_emits_tcp_syn(self):
        client = self.client()
        client.sendall(b"\x05\x01\x00\x01" + socket.inet_aton(ANSWER) + struct.pack("!H", 443))
        self.expect_syn()

    def test_connect_domain_validates_raw_dns_fixture_then_emits_syn(self):
        client = self.client()
        client.sendall(domain_request(command=1, port=443))
        self.answer_dns(self.dns_query(client))
        self.expect_syn()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ocproxy", type=Path, default=OCPROXY)
    options, unittest_arguments = parser.parse_known_args()
    OCPROXY = options.ocproxy.resolve()
    if not OCPROXY.is_file() or not os.access(OCPROXY, os.X_OK):
        parser.error("--ocproxy must name an executable binary")
    unittest.main(argv=[sys.argv[0], *unittest_arguments],
                  testRunner=unittest.TextTestRunner(stream=sys.stdout, verbosity=2))
