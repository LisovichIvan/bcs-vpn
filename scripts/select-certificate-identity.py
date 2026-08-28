#!/usr/bin/env python3

import hashlib
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Optional

OPENSSL_EXECUTABLE = os.environ.get("OPENSSL_EXECUTABLE", "/usr/bin/openssl")


def run_openssl(arguments: list[str], input_data: Optional[bytes] = None) -> bytes:
    return subprocess.check_output(
        [OPENSSL_EXECUTABLE, *arguments],
        input=input_data,
        stderr=subprocess.DEVNULL,
    )


def certificate_sha1(certificate: bytes) -> str:
    output = run_openssl(["x509", "-noout", "-fingerprint", "-sha1"], certificate)
    return output.decode().split("=", 1)[1].replace(":", "").strip().upper()


def certificate_public_key_digest(certificate: bytes) -> bytes:
    public_key = run_openssl(["x509", "-pubkey", "-noout"], certificate)
    public_key_der = run_openssl(["pkey", "-pubin", "-outform", "DER"], public_key)
    return hashlib.sha256(public_key_der).digest()


def private_key_public_key_digest(private_key: bytes) -> bytes:
    public_key_der = run_openssl(["pkey", "-pubout", "-outform", "DER"], private_key)
    return hashlib.sha256(public_key_der).digest()


def main() -> None:
    if len(sys.argv) != 4:
        raise SystemExit(
            "Usage: select-certificate-identity.py SOURCE_PEM CERTIFICATE_SHA1 OUTPUT_PEM"
        )

    source_path = Path(sys.argv[1])
    requested_sha1 = sys.argv[2].replace(":", "").strip().upper()
    output_path = Path(sys.argv[3])
    source_content = source_path.read_bytes()

    certificate_blocks = re.findall(
        rb"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----",
        source_content,
        re.DOTALL,
    )
    private_key_blocks = re.findall(
        rb"-----BEGIN (?:RSA |EC )?PRIVATE KEY-----.*?"
        rb"-----END (?:RSA |EC )?PRIVATE KEY-----",
        source_content,
        re.DOTALL,
    )

    selected_certificate = next(
        (
            certificate
            for certificate in certificate_blocks
            if certificate_sha1(certificate) == requested_sha1
        ),
        None,
    )
    if selected_certificate is None:
        raise SystemExit(f"Certificate {requested_sha1} not found in exported identities")

    selected_public_key_digest = certificate_public_key_digest(selected_certificate)
    selected_private_key = next(
        (
            private_key
            for private_key in private_key_blocks
            if private_key_public_key_digest(private_key) == selected_public_key_digest
        ),
        None,
    )
    if selected_private_key is None:
        raise SystemExit(f"Private key for certificate {requested_sha1} not found")

    temporary_file_descriptor, temporary_file_name = tempfile.mkstemp(
        dir=output_path.parent,
        prefix="selected-identity-",
    )
    try:
        with os.fdopen(temporary_file_descriptor, "wb") as temporary_file:
            temporary_file.write(selected_certificate)
            temporary_file.write(b"\n")
            temporary_file.write(selected_private_key)
            temporary_file.write(b"\n")
        os.chmod(temporary_file_name, 0o600)
        os.replace(temporary_file_name, output_path)
    finally:
        if os.path.exists(temporary_file_name):
            os.unlink(temporary_file_name)


if __name__ == "__main__":
    main()
