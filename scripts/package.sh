#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
[[ -x dist/staging/compose/bin/compose ]] || { echo 'Run make stage first.' >&2; exit 1; }
version=${VERSION:-$(dist/staging/compose/bin/compose --version)}
case "$version" in ''|*[!a-zA-Z0-9._-]*) echo 'Invalid package version.' >&2; exit 2;; esac
[[ $(uname -s) == Darwin ]] || { echo 'Package a macOS build on macOS.' >&2; exit 1; }
archive="$PWD/dist/container-compose-${version}-darwin-$(uname -m).tar.gz"
COPYFILE_DISABLE=1 tar -czf "$archive" -C dist/staging compose
shasum -a 256 "$archive" > "$archive.sha256"
printf '%s\n' "$archive"
