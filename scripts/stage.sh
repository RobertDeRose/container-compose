#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $(uname -s) == Darwin ]] || { echo 'Building the plugin requires macOS.' >&2; exit 1; }
configuration=${BUILD_CONFIGURATION:-release}
bin_dir=$(swift build -c "$configuration" --show-bin-path)
stage="$PWD/dist/staging/compose"
rm -rf "$stage"
# Explicit modes throughout: the stage is copied as root by the installer,
# so anything left to the umask (such as 077) would be unreadable afterwards.
install -d -m 0755 "$stage" "$stage/bin"
install -m 0755 "$bin_dir/compose" "$stage/bin/compose"
install -m 0644 config.toml LICENSE NOTICE.md "$stage/"
printf '%s\n' 'container-compose external CLI plugin' > "$stage/.container-compose-plugin"
chmod 0644 "$stage/.container-compose-plugin"
# The installer ships in the archive so a release installs without the repository.
install -m 0755 scripts/install.sh "$stage/install.sh"
codesign --force --sign "${CODE_SIGN_IDENTITY:--}" --timestamp=none "$stage/bin/compose"
printf '%s\n' "$stage"
