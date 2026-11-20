#!/bin/bash

set -euo pipefail

PROJECT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_COMMIT="88b1087f6ab2c860c8729478643e081b6e97f6d3"
SOURCE_CHECKSUM="b751bb39a7620dbe7edb9fde1594570252910e62b504143dd39c89c7984c7e11"
BUILD_ROOT="$PROJECT_DIRECTORY/run/ocproxy-build"
ARCHIVE_PATH="$BUILD_ROOT/downloads/ocproxy-88b1087.tar.gz"
LIBRARY_DIRECTORY="$PROJECT_DIRECTORY/vendor/macos-arm64/lib"
HEADER_DIRECTORY="${BCS_LIBEVENT_INCLUDE_DIRECTORY:-/opt/homebrew/opt/libevent/include}"

if [[ "$#" -ne 0 || "$(uname -m)" != "arm64" || "$(uname -s)" != "Darwin" ]]; then
  printf 'Run without arguments on macOS arm64.\n' >&2
  exit 1
fi
if [[ ! -f "$HEADER_DIRECTORY/event2/event.h" || ! -f "$HEADER_DIRECTORY/event2/event-config.h" ]]; then
  printf 'Existing libevent development headers are required: %s\n' "$HEADER_DIRECTORY" >&2
  exit 1
fi
HEADER_DIRECTORY="$(cd "$HEADER_DIRECTORY" && pwd -P)"
mkdir -p "$BUILD_ROOT/downloads"
if [[ ! -f "$ARCHIVE_PATH" ]]; then
  /usr/bin/curl --fail --silent --show-error --location \
    --proto '=https' --proto-redir '=https' --connect-timeout 8 --max-time 45 \
    "https://codeload.github.com/cernekee/ocproxy/tar.gz/$SOURCE_COMMIT" \
    --output "$ARCHIVE_PATH"
fi
BUILD_DIRECTORY="$(mktemp -d "$BUILD_ROOT/build.XXXXXX")"
mkdir -p "$BUILD_DIRECTORY/tmp" "$BUILD_DIRECTORY/home" "$BUILD_ROOT/runtime/bin" "$BUILD_ROOT/runtime/lib"

python3 - "$ARCHIVE_PATH" "$SOURCE_CHECKSUM" "$BUILD_DIRECTORY" "$SOURCE_COMMIT" <<'PY'
import hashlib
from pathlib import Path, PurePosixPath
import sys
import tarfile

archive_path, expected_checksum, build_directory, source_commit = sys.argv[1:]
if hashlib.sha256(Path(archive_path).read_bytes()).hexdigest() != expected_checksum:
    raise SystemExit('Source archive checksum mismatch; refusing to extract or compile')
with tarfile.open(archive_path, 'r:gz') as archive:
    members = archive.getmembers()
    expected_prefix = 'ocproxy-' + source_commit
    for member in members:
        name = PurePosixPath(member.name)
        if name.is_absolute() or '..' in name.parts or name.parts[0] != expected_prefix:
            raise SystemExit('Unsafe source archive path')
        if not member.isdir() and not member.isfile():
            raise SystemExit('Unexpected source archive link or special file')
    archive.extractall(build_directory, members=members)
PY

SOURCE_DIRECTORY="$BUILD_DIRECTORY/ocproxy-$SOURCE_COMMIT"
/usr/bin/patch --batch --forward -d "$SOURCE_DIRECTORY" -p1 < "$PROJECT_DIRECTORY/vendor/ocproxy/resolve.patch"

# Compile the upstream C source list directly; never execute downloaded build scripts.
# The compiler gets no user environment, credentials, network, or access to user files.
python3 - "$PROJECT_DIRECTORY" "$SOURCE_DIRECTORY" "$BUILD_DIRECTORY" "$LIBRARY_DIRECTORY" "$HEADER_DIRECTORY" <<'PY'
from pathlib import Path
import re
import subprocess
import sys

project_directory, source_directory, build_directory, library_directory, header_directory = map(Path, sys.argv[1:])
makefile = (source_directory / 'Makefile.am').read_text()
source_list = makefile.split('LWIP_SOURCES', 1)[1].split('APP_SOURCES', 1)[0]
source_names = re.findall(r'(?:lwip|contrib)/[A-Za-z0-9_/]+\.c', source_list)
if len(source_names) != len(set(source_names)) or not source_names:
    raise SystemExit('Unexpected upstream C source list')
include_directories = [
    source_directory / 'lwip/src',
    source_directory / 'lwip/src/include',
    source_directory / 'lwip/src/include/ipv4',
    source_directory / 'lwip/src/include/ipv6',
    source_directory / 'contrib/ports/unix/include',
    source_directory / 'src',
    header_directory,
]
command = ['/usr/bin/sandbox-exec']
for name, value in [
    ('SOURCE_DIRECTORY', source_directory), ('BUILD_DIRECTORY', build_directory),
    ('LIBRARY_DIRECTORY', library_directory), ('HEADER_DIRECTORY', header_directory),
]:
    command.extend(['-D', name + '=' + str(value)])
command.extend([
    '-f', str(project_directory / 'scripts/ocproxy-build.sb'),
    '/Library/Developer/CommandLineTools/usr/bin/clang', '-arch', 'arm64',
    '-isysroot', '/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk',
    '-mmacosx-version-min=26.0', '-O2', '-Wall', '-Wextra',
    '-ffile-prefix-map=' + str(source_directory) + '=ocproxy',
    '-Werror=implicit-function-declaration', '-Werror=incompatible-pointer-types',
    '-Dunix', '-DIPv4', '-o', str(build_directory / 'ocproxy'),
])
for include_directory in include_directories:
    command.extend(['-I', str(include_directory)])
command.extend(str(source_directory / name) for name in source_names + ['src/ocproxy.c'])
command.append(str(library_directory / 'libevent-2.1.7.dylib'))
subprocess.run(command, check=True, cwd=build_directory, env={
    'PATH': '/usr/bin:/bin:/usr/sbin:/sbin',
    'HOME': str(build_directory / 'home'),
    'TMPDIR': str(build_directory / 'tmp') + '/',
    'LC_ALL': 'C',
})
PY

OUTPUT_PATH="$BUILD_ROOT/runtime/bin/ocproxy"
/usr/bin/install -m 755 "$BUILD_DIRECTORY/ocproxy" "$OUTPUT_PATH"
/usr/bin/install -m 644 "$LIBRARY_DIRECTORY/libevent-2.1.7.dylib" "$BUILD_ROOT/runtime/lib/libevent-2.1.7.dylib"
LIBRARY_INSTALL_NAME="$(/usr/bin/otool -D "$LIBRARY_DIRECTORY/libevent-2.1.7.dylib" | /usr/bin/tail -n 1)"
/usr/bin/install_name_tool -change "$LIBRARY_INSTALL_NAME" '@loader_path/../lib/libevent-2.1.7.dylib' "$OUTPUT_PATH"
/usr/bin/codesign --force --sign - --timestamp=none "$OUTPUT_PATH"
printf 'Built only; installed runtime unchanged: %s\n' "$OUTPUT_PATH"
/usr/bin/shasum -a 256 "$OUTPUT_PATH"
