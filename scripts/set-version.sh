#!/bin/bash
# Stamp a release version into the executable before it is built. The
# checked-in version stays a development marker; the release workflow runs
# this on the release commit without committing the result.
set -euo pipefail
cd "$(dirname "$0")/.."
version=${1:-}
case "$version" in ''|*[!a-zA-Z0-9._-]*) echo 'usage: set-version.sh <version>' >&2; exit 2;; esac
file=Sources/ContainerCompose/ComposeVersion.swift
updated=$(sed "s/\(public static let current = \)\"[^\"]*\"/\1\"$version\"/" "$file")
grep -q "current = \"$version\"" <<<"$updated" || { echo "Version line not found in $file" >&2; exit 1; }
printf '%s\n' "$updated" > "$file"
printf '%s\n' "$version"
