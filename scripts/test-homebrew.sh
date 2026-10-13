#!/bin/bash
# Exercises the formula publisher against a local bare repository standing in
# for the tap, with a fixture archive checksum.
set -euo pipefail
cd "$(dirname "$0")/.."
root=$(mktemp -d)
trap 'rm -rf -- "$root"' EXIT
git init -q --bare -b main "$root/tap.git"
seed="$root/seed"
git clone -q "file://$root/tap.git" "$seed" 2>/dev/null
printf '%s\n' '# tap' > "$seed/README.md"
git -C "$seed" -c user.name=t -c user.email=t@example.com add README.md
git -C "$seed" -c user.name=t -c user.email=t@example.com commit -q -m seed
git -C "$seed" push -q origin HEAD:main
mkdir -p "$root/dist"
sha=$(printf 'fixture' | shasum -a 256 | cut -d' ' -f1)
printf '%s  container-compose-plugin-1.2.3-darwin-arm64.tar.gz\n' "$sha" > "$root/dist/container-compose-plugin-1.2.3-darwin-arm64.tar.gz.sha256"

DIST_DIR="$root/dist" TAP_REMOTE="file://$root/tap.git" ./scripts/publish-homebrew.sh 1.2.3 >/dev/null
check="$root/check"
git clone -q "file://$root/tap.git" "$check"
formula="$check/Formula/container-compose-plugin.rb"
[[ -f $formula ]] || { echo 'Formula was not published.' >&2; exit 1; }
grep -q "version \"1.2.3\"" "$formula"
grep -q "sha256 \"$sha\"" "$formula"
grep -q "releases/download/v1.2.3/container-compose-plugin-1.2.3-darwin-arm64.tar.gz" "$formula"
! grep -q "@VERSION@\|@SHA256@" "$formula"
# Publishing the same version again is a no-op, not an error.
DIST_DIR="$root/dist" TAP_REMOTE="file://$root/tap.git" ./scripts/publish-homebrew.sh 1.2.3 | grep -q "already describes"
# A malformed checksum file is refused.
printf 'junk\n' > "$root/dist/container-compose-plugin-9.9.9-darwin-arm64.tar.gz.sha256"
if DIST_DIR="$root/dist" TAP_REMOTE="file://$root/tap.git" ./scripts/publish-homebrew.sh 9.9.9 >/dev/null 2>&1; then
    echo 'Publisher accepted a malformed checksum.' >&2; exit 1
fi
if command -v brew >/dev/null; then
    brew ruby -e "load '$formula'" >/dev/null 2>&1 || { echo 'Formula does not parse.' >&2; exit 1; }
fi
printf '%s\n' 'Homebrew publisher checks passed: render, push, idempotence, checksum validation.'
