#!/bin/bash
# Renders the Homebrew formula for a released version and pushes it to the
# tap. Runs from the release workflow after the GitHub release exists, with
# a token that can push to the tap.
set -euo pipefail
cd "$(dirname "$0")/.."
version=${1:-}
case "$version" in ''|*[!a-zA-Z0-9._-]*) echo 'usage: publish-homebrew.sh <version>' >&2; exit 2;; esac
dist=${DIST_DIR:-"$PWD/dist"}
tap_repository=${TAP_REPOSITORY:-RobertDeRose/homebrew-tap}
tap_remote=${TAP_REMOTE:-"https://x-access-token:${GITHUB_TOKEN:?GITHUB_TOKEN is required to push to the tap}@github.com/${tap_repository}.git"}
template=homebrew/container-compose-plugin.rb.in
formula=Formula/container-compose-plugin.rb

checksum_file="$dist/container-compose-plugin-${version}-darwin-arm64.tar.gz.sha256"
[[ -f $checksum_file ]] || { echo "Checksum file not found: $checksum_file" >&2; exit 1; }
sha256=$(cut -d' ' -f1 "$checksum_file")
[[ $sha256 =~ ^[0-9a-f]{64}$ ]] || { echo "Malformed checksum in $checksum_file" >&2; exit 1; }

work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
git clone -q --depth 1 "$tap_remote" "$work/tap"
mkdir -p "$work/tap/Formula"
sed -e "s/@VERSION@/${version}/g" -e "s/@SHA256@/${sha256}/g" "$template" > "$work/tap/$formula"
cd "$work/tap"
git config user.name "robborg-the-creator[bot]"
git config user.email "280037799+robborg-the-creator[bot]@users.noreply.github.com"
git add "$formula"
if git diff --cached --quiet; then
    echo "Formula already describes ${version}"
    exit 0
fi
git commit -q -m "container-compose-plugin ${version}"
# Other projects push to the same tap; rebase onto whatever landed meanwhile.
for _ in 1 2 3; do
    if git push -q origin HEAD:main; then
        echo "Published ${formula} for ${version} to ${tap_repository}"
        exit 0
    fi
    git pull -q --rebase origin main
done
echo "Could not push the formula after 3 attempts" >&2
exit 1
