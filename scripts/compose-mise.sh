#!/bin/bash
# Shipped as cli/compose; bin/compose remains the host's native plugin.
set -euo pipefail
plugin=$(cd "$(dirname "$0")/.." && pwd)
# The host treats --version as a global flag, even after the plugin name.
if [[ $# -eq 1 && $1 == --version ]]; then
    exec "$plugin/bin/compose" "$@"
fi
prefix="$(mise where container)/Payload"
destination="$prefix/libexec/container-plugins/compose"
# Hooks install eagerly. Also repair missing registration, or a different
# selected plugin version, without copying files on every invocation.
if [[ ! -f "$destination/.container-compose-plugin" ]] ||
    ! cmp -s "$plugin/bin/compose" "$destination/bin/compose" ||
    ! cmp -s "$plugin/config.toml" "$destination/config.toml"; then
    "$plugin/install.sh" --replace --prefix "$prefix" >&2
fi
CONTAINER_INSTALL_ROOT="$prefix" exec "$prefix/bin/container" compose "$@"
