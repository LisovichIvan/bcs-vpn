#!/usr/bin/env python3

from __future__ import annotations

import stat
import subprocess
import sys
import tempfile
from pathlib import Path


project_directory = Path(__file__).resolve().parent.parent
run_directory = project_directory / "run"
run_directory.mkdir(exist_ok=True)

if len(sys.argv) != 2:
    raise SystemExit("Usage: test-certificate-selection.py VPN_COMMAND_HELPER")
vpn_command_helper = Path(sys.argv[1])


def run_openssl(arguments: list[Path | str], input_data: bytes | None = None) -> bytes:
    return subprocess.check_output(
        ["/usr/bin/openssl", *map(str, arguments)],
        input=input_data,
        stderr=subprocess.DEVNULL,
    )


with tempfile.TemporaryDirectory(dir=run_directory, prefix="certificate-tests.") as directory:
    test_directory = Path(directory)
    password_file = test_directory / "password"
    password_file.write_text("test-password\n", encoding="utf-8")
    password_file.chmod(0o600)

    certificate_file = test_directory / "certificate.pem"
    private_key_file = test_directory / "private-key.pem"
    run_openssl(
        [
            "req",
            "-x509",
            "-newkey",
            "rsa:2048",
            "-nodes",
            "-days",
            "1",
            "-subj",
            "/CN=BCS VPN export test",
            "-keyout",
            private_key_file,
            "-out",
            certificate_file,
        ]
    )

    pkcs12_file = test_directory / "selected-identity.p12"
    run_openssl(
        [
            "pkcs12",
            "-export",
            "-inkey",
            private_key_file,
            "-in",
            certificate_file,
            "-passout",
            f"file:{password_file}",
            "-out",
            pkcs12_file,
        ]
    )
    pkcs12_file.chmod(0o600)

    selected_file = test_directory / "selected.pem"
    subprocess.run(
        [
            vpn_command_helper,
            "convert-pkcs12",
            pkcs12_file,
            selected_file,
            password_file,
        ],
        check=True,
    )
    selected_content = selected_file.read_bytes()
    if selected_content.count(b"BEGIN CERTIFICATE") != 1:
        raise SystemExit("Результат содержит не один сертификат.")
    if b"BEGIN ENCRYPTED PRIVATE KEY" in selected_content:
        raise SystemExit("Выбранный ключ остался зашифрованным.")
    run_openssl(["pkey", "-in", selected_file, "-noout"])

    source_certificate_sha1 = (
        run_openssl(["x509", "-in", certificate_file, "-noout", "-fingerprint", "-sha1"])
        .decode()
        .split("=", 1)[1]
        .replace(":", "")
        .strip()
    )
    selected_certificate_sha1 = (
        run_openssl(["x509", "-in", selected_file, "-noout", "-fingerprint", "-sha1"])
        .decode()
        .split("=", 1)[1]
        .replace(":", "")
        .strip()
    )
    if selected_certificate_sha1 != source_certificate_sha1:
        raise SystemExit("Преобразован неверный сертификат.")
    if stat.S_IMODE(selected_file.stat().st_mode) != 0o600:
        raise SystemExit("Результат должен иметь права 600.")

    invalid_export = subprocess.run(
        [
            vpn_command_helper,
            "export-identity",
            "INVALID-SHA1",
            test_directory / "invalid.pem",
            password_file,
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    if invalid_export.returncode == 0:
        raise SystemExit("Некорректный SHA-1 принят helper-командой.")

print("bcs-vpn-helper: PKCS#12 выбранного identity преобразован безопасно.")
