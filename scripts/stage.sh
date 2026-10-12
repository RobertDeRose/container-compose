#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $(uname -s) == Darwin ]] || { echo 'Building the plugin requires macOS.' >&2; exit 1; }
configuration=${BUILD_CONFIGURATION:-release}
bin_dir=$(swift build -c "$configuration" --show-bin-path)
stage="$PWD/dist/staging/compose"
rm -rf "$stage"
mkdir -p "$stage/bin"
install -m 0755 "$bin_dir/compose" "$stage/bin/compose"
install -m 0644 config.toml LICENSE NOTICE.md "$stage/"
printf '%s\n' 'container-compose external CLI plugin' > "$stage/.container-compose-plugin"
codesign --force --sign "${CODE_SIGN_IDENTITY:--}" --timestamp=none "$stage/bin/compose"
printf '%s\n' "$stage"
