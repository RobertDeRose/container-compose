#!/bin/bash
# Release the next version when the commits since the latest tag call for one:
# Cocogitto picks the version and writes the notes, then this stamps and
# packages the executable, pushes the tag, publishes the GitHub release, and
# updates the Homebrew formula. Nothing is committed; the checked-in version
# stays a development marker.
#
#   release.sh --dry-run   print the next version and its notes, change nothing
#   release.sh             release (the release workflow, with GITHUB_TOKEN set)
set -euo pipefail
cd "$(dirname "$0")/.."
dry_run=false
[[ ${1:-} == --dry-run ]] && dry_run=true

cog() { mise exec -- cog "$@"; }

# A release needs a clean checkout; a preview tolerates untracked files.
# Cocogitto prints a message instead of a version when nothing calls for a
# release, so only a version-shaped answer proceeds.
bump=(bump --auto --dry-run)
$dry_run && bump+=(--skip-untracked)
if ! answer=$(cog "${bump[@]}" 2>&1); then
    echo "$answer" >&2
    exit 1
fi
next=$(grep -v '^[[:space:]]*$' <<<"$answer" | tail -n 1)
if [[ ! $next =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "No release: $answer"
    exit 0
fi
version=${next#v}

notes=$(mktemp)
trap 'rm -f "$notes"' EXIT
git tag "$next"
cog changelog --at "$next" --template .config/cog-release-notes.tera | sed '/./,$!d' >"$notes"

if $dry_run; then
    git tag -d "$next" >/dev/null
    echo "Next release: $next"
    echo
    cat "$notes"
    exit 0
fi

: "${GITHUB_TOKEN:?GITHUB_TOKEN is required to publish a release}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required to publish a release}"
./scripts/set-version.sh "$version" >/dev/null
make package VERSION="$version"
# The tag is pushed with the given token so that, as the release app, it
# starts the machine image workflow for this version.
git push -q "https://x-access-token:${GITHUB_TOKEN}@github.com/${GITHUB_REPOSITORY}.git" "refs/tags/$next"
GH_TOKEN=$GITHUB_TOKEN gh release create "$next" dist/*.tar.gz dist/*.tar.gz.sha256 \
    --verify-tag --title "$next" --notes-file "$notes"
./scripts/publish-homebrew.sh "$version"
