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
# A stage created under a restrictive umask must still install readable
# directories, as the installer may copy it as root.
restricted="$root/restricted"
mkdir -p "$restricted"
(umask 077 && mkdir -p "$restricted/stage/compose/bin")
cp "$COMPOSE_STAGING_DIR/bin/compose" "$restricted/stage/compose/bin/compose"
cp "$COMPOSE_STAGING_DIR/config.toml" "$restricted/stage/compose/config.toml"
printf '%s\n' 'fixture' > "$restricted/stage/compose/.container-compose-plugin"
restricted_prefix="$restricted/prefix"
(umask 077 && COMPOSE_STAGING_DIR="$restricted/stage/compose" ./scripts/install.sh --prefix "$restricted_prefix" >/dev/null)
restricted_destination="$restricted_prefix/libexec/container-plugins/compose"
# The plugin's directories and the parents the installer created. `find
# -perm` is an exact match on both BSD and GNU find; `stat` differs.
for directory in "$restricted_prefix/libexec" "$restricted_prefix/libexec/container-plugins" \
    "$restricted_destination" "$restricted_destination/bin"; do
    [[ -n $(find "$directory" -maxdepth 0 -perm 0755) ]] || { echo "Installed directory $directory is not 0755." >&2; exit 1; }
done
# A release archive carries the installer, which then runs from the extracted
# directory without the repository or COMPOSE_STAGING_DIR.
extracted="$root/extracted/compose"
mkdir -p "$extracted/bin"
cp "$COMPOSE_STAGING_DIR/bin/compose" "$extracted/bin/compose"
cp "$COMPOSE_STAGING_DIR/config.toml" "$extracted/config.toml"
printf '%s\n' 'fixture' > "$extracted/.container-compose-plugin"
cp scripts/install.sh "$extracted/install.sh"
archive_prefix="$root/archive-prefix"
(cd "$root" && env -u COMPOSE_STAGING_DIR "$extracted/install.sh" --prefix "$archive_prefix" >/dev/null)
archive_destination="$archive_prefix/libexec/container-plugins/compose"
[[ -x "$archive_destination/bin/compose" && -f "$archive_destination/config.toml" ]]
[[ ! -e "$archive_destination/install.sh" ]] || { echo 'Installer copied itself into the plugin.' >&2; exit 1; }
printf '%s\n' 'Installer checks passed: spaces, install, replacement, foreign-plugin refusal, prefix validation, umask, and release archive.'
