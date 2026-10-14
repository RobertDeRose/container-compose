#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
root=$(mktemp -d)
trap 'rm -rf -- "$root"' EXIT
plugin="$root/plugin with spaces"
export MISE_COMPOSE_TEST_HOST="$root/host with spaces"
mkdir -p "$plugin/cli" "$plugin/bin" "$root/bin" "$MISE_COMPOSE_TEST_HOST/Payload/bin"
cp scripts/compose-mise.sh "$plugin/cli/compose"
cp scripts/install.sh "$plugin/install.sh"
printf '%s\n' 'fixture' > "$plugin/.container-compose-plugin"
printf '%s\n' 'abstract = "fixture"' > "$plugin/config.toml"
printf '%s\n' '#!/bin/sh' 'echo native-version-one' > "$plugin/bin/compose"
cat > "$root/bin/mise" <<'EOF'
#!/bin/sh
[ "$1" = where ] && [ "$2" = container ] || exit 2
printf '%s\n' "$MISE_COMPOSE_TEST_HOST"
EOF
cat > "$MISE_COMPOSE_TEST_HOST/Payload/bin/container" <<'EOF'
#!/bin/sh
[ "$CONTAINER_INSTALL_ROOT" = "$MISE_COMPOSE_TEST_HOST/Payload" ] || exit 3
[ "$1" = compose ] || exit 4
shift
if [ "$1" = --fail ]; then exit 17; fi
printf '%s\n' "$@"
EOF
chmod 0755 "$plugin/cli/compose" "$plugin/install.sh" "$plugin/bin/compose" \
    "$root/bin/mise" "$MISE_COMPOSE_TEST_HOST/Payload/bin/container"
export PATH="$root/bin:$PATH"
unset COMPOSE_STAGING_DIR
destination="$MISE_COMPOSE_TEST_HOST/Payload/libexec/container-plugins/compose"
expected=$(printf '%s\n' '-f' 'a file with spaces.yaml' 'config')
[[ $("$plugin/cli/compose" -f 'a file with spaces.yaml' config) == "$expected" ]]
[[ -x "$destination/bin/compose" && ! -e "$destination/cli" ]]
# Correct registrations aren't rewritten on each command.
touch "$destination/keep"
"$plugin/cli/compose" --help >/dev/null
[[ -f "$destination/keep" ]]
if "$plugin/cli/compose" --fail; then
    echo 'Wrapper lost the host exit status.' >&2; exit 1
else
    [[ $? == 17 ]]
fi
# Selecting a different plugin version replaces only our own installation.
printf '%s\n' '#!/bin/sh' 'echo native-version-two' > "$plugin/bin/compose"
"$plugin/cli/compose" --help >/dev/null
cmp "$plugin/bin/compose" "$destination/bin/compose"
# A different selected host gets its own registration.
old_host=$MISE_COMPOSE_TEST_HOST
export MISE_COMPOSE_TEST_HOST="$root/upgraded host"
mkdir -p "$MISE_COMPOSE_TEST_HOST/Payload/bin"
cp "$old_host/Payload/bin/container" "$MISE_COMPOSE_TEST_HOST/Payload/bin/container"
"$plugin/cli/compose" --help >/dev/null
[[ -x "$MISE_COMPOSE_TEST_HOST/Payload/libexec/container-plugins/compose/bin/compose" ]]
# Foreign installations must survive a refused registration.
rm "$destination/.container-compose-plugin"
export MISE_COMPOSE_TEST_HOST=$old_host
if "$plugin/cli/compose" --help >/dev/null 2>&1; then
    echo 'Wrapper overwrote a foreign plugin.' >&2; exit 1
fi
cmp "$plugin/bin/compose" "$destination/bin/compose"
printf '%s\n' 'mise wrapper checks passed: first use, arguments, exit status, plugin/host changes, and foreign-plugin refusal.'
