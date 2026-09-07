#!/bin/bash
# Install only this CLI plugin. Never change host binaries, daemons, or VM data.
set -euo pipefail
cd "$(dirname "$0")/.."
stage=${COMPOSE_STAGING_DIR:-"$PWD/dist/staging/compose"}
prefix=
replace=false
while (($#)); do
    case "$1" in
        --prefix)
            [[ $# -ge 2 && $2 == /* ]] || { echo '--prefix requires an absolute installation root.' >&2; exit 2; }
            prefix=${2%/}; [[ -n $prefix ]] || prefix=/
            shift 2 ;;
        --replace) replace=true; shift ;;
        *) echo "Unknown installer argument: $1" >&2; exit 2 ;;
    esac
done
[[ -x "$stage/bin/compose" && -f "$stage/.container-compose-plugin" && -r "$stage/config.toml" ]] || {
    echo 'Staged plugin is missing. Run make stage first, as your normal user.' >&2; exit 1;
}
if [[ -n $prefix ]]; then
    destination="${prefix%/}/libexec/container-plugins/compose"
else
    # Resolve while running as the user's launchd session, before requesting sudo.
    destination=$("$stage/bin/compose" --install-path)
fi
[[ $destination == /*/libexec/container-plugins/compose ]] || {
    echo "Invalid plugin destination: $destination" >&2; exit 1;
}
parent=${destination%/compose}
ancestor=$parent
while [[ ! -e $ancestor ]]; do ancestor=$(dirname "$ancestor"); done
needs_sudo=false
if [[ ! -w $ancestor ]]; then needs_sudo=true; fi
run_privileged() {
    if [[ $needs_sudo == true ]]; then sudo "$@"; else "$@"; fi
}
if [[ -e $destination || -L $destination ]]; then
    [[ $replace == true && -f "$destination/.container-compose-plugin" && ! -L $destination ]] || {
        echo "Refusing to overwrite $destination; use --replace only for this plugin's existing installation." >&2
        exit 1
    }
fi
run_privileged mkdir -p "$parent"
[[ ! -L $parent ]] || { echo 'Refusing a symlinked plugin parent directory.' >&2; exit 1; }
temporary=$(run_privileged mktemp -d "$parent/.compose-install.XXXXXX")
backup=
cleanup() {
    run_privileged rm -rf -- "$temporary"
    if [[ -n $backup && -e $backup && ! -e $destination ]]; then
        run_privileged mv -- "$backup" "$destination"
    fi
}
trap cleanup EXIT
run_privileged cp -R "$stage/." "$temporary/"
run_privileged chmod 0755 "$temporary"
if [[ -e $destination ]]; then
    backup="$temporary.previous"
    run_privileged mv -- "$destination" "$backup"
fi
run_privileged mv -- "$temporary" "$destination"
if [[ -n $backup ]]; then run_privileged rm -rf -- "$backup"; fi
printf 'Installed %s\n' "$destination"
