#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
root=$(mktemp -d)
trap 'rm -rf -- "$root"' EXIT
export COMPOSE_STAGING_DIR="$root/stage/compose"
mkdir -p "$COMPOSE_STAGING_DIR/bin" "$COMPOSE_STAGING_DIR/resources"
printf '%s\n' '#!/bin/sh' 'exit 0' > "$COMPOSE_STAGING_DIR/bin/compose"
chmod 0755 "$COMPOSE_STAGING_DIR/bin/compose"
printf '%s\n' 'fixture' > "$COMPOSE_STAGING_DIR/.container-compose-plugin"
printf '%s\n' 'abstract = "fixture"' > "$COMPOSE_STAGING_DIR/config.toml"
prefix="$root/prefix with spaces"
./scripts/install.sh --prefix "$prefix" >/dev/null
destination="$prefix/libexec/container-plugins/compose"
[[ -x "$destination/bin/compose" ]]
if ./scripts/install.sh --prefix "$prefix" >/dev/null 2>&1; then
    echo 'Installer overwrote a plugin without --replace.' >&2; exit 1
fi
printf '%s\n' 'new-version' > "$COMPOSE_STAGING_DIR/resources/version"
./scripts/install.sh --prefix "$prefix" --replace >/dev/null
[[ $(cat "$destination/resources/version") == new-version ]]
rm "$destination/.container-compose-plugin"
if ./scripts/install.sh --prefix "$prefix" --replace >/dev/null 2>&1; then
    echo 'Installer overwrote a foreign plugin.' >&2; exit 1
fi
if ./scripts/install.sh --prefix relative >/dev/null 2>&1; then
    echo 'Installer accepted a relative prefix.' >&2; exit 1
fi
printf '%s\n' 'Installer checks passed: spaces, install, replacement, foreign-plugin refusal, and prefix validation.'
