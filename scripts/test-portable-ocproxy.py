#!/usr/bin/env python3

import os
import socket
import subprocess
import tempfile
import time
from pathlib import Path


def check_ocproxy(ocproxy_executable: Path, listen_port: int) -> None:
    first_socket, second_socket = socket.socketpair(socket.AF_UNIX, socket.SOCK_DGRAM)
    child_environment = dict(os.environ)
    child_environment.update(
        {
            "VPNFD": str(second_socket.fileno()),
            "INTERNAL_IP4_ADDRESS": "10.0.0.2",
            "INTERNAL_IP4_MTU": "1400",
            "INTERNAL_IP4_DNS": "1.1.1.1",
        }
    )

    process = subprocess.Popen(
        [ocproxy_executable, "-D", str(listen_port), "-k", "30"],
        env=child_environment,
        pass_fds=(second_socket.fileno(),),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )

    try:
        time.sleep(2)
        with socket.create_connection(("127.0.0.1", listen_port), timeout=2):
            pass
        print(f"ocproxy открыл SOCKS5 listener: {ocproxy_executable}")
    finally:
        process.terminate()
        output, error_output = process.communicate(timeout=5)
        if process.returncode not in (-15, 0):
            raise SystemExit(output + error_output)


project_directory = Path(__file__).resolve().parent.parent
check_ocproxy(project_directory / "vendor/macos-arm64/bin/ocproxy", 18890)
check_ocproxy(
    Path.home()
    / "Library/Application Support/BCS VPN/runtime-macos-arm64/bin/ocproxy",
    18891,
)

with tempfile.TemporaryDirectory() as temporary_directory:
    first_socket, second_socket = socket.socketpair(socket.AF_UNIX, socket.SOCK_DGRAM)
    child_environment = dict(os.environ)
    child_environment.update(
        {
            "VPNFD": str(second_socket.fileno()),
            "INTERNAL_IP4_ADDRESS": "10.0.0.2",
            "INTERNAL_IP4_MTU": "1400",
            "INTERNAL_IP4_DNS": "1.1.1.1",
            "BCS_VPN_RUNTIME_DIRECTORY": str(
                Path.home() / "Library/Application Support/BCS VPN/runtime-macos-arm64"
            ),
            "BCS_VPN_RUN_DIRECTORY": temporary_directory,
        }
    )
    wrapper_process = subprocess.Popen(
        [project_directory / "scripts/run-ocproxy.sh"],
        env=child_environment,
        pass_fds=(second_socket.fileno(),),
    )
    try:
        time.sleep(2)
        with socket.create_connection(("127.0.0.1", 8890), timeout=2):
            pass
        recorded_process_id = int(
            (Path(temporary_directory) / "ocproxy.pid").read_text().strip()
        )
        if recorded_process_id != wrapper_process.pid:
            raise SystemExit("run-ocproxy.sh записал неверный идентификатор процесса")
        if not (Path(temporary_directory) / "ocproxy.start-time").read_text().strip():
            raise SystemExit("run-ocproxy.sh не записал время запуска процесса")
        print("run-ocproxy.sh открыл SOCKS5 listener и записал идентификаторы.")
    finally:
        wrapper_process.terminate()
        wrapper_process.wait(timeout=5)
