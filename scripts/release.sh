#!/bin/bash
# Release the next version when the commits since the latest tag call for one:
# Cocogitto picks the version and writes the notes, then this stamps and
# packages the executable, pushes the tag, publishes the GitHub release, and
# updates the Homebrew formula. Nothing is committed; the checked-in version
# stays a development marker.
#
# A run that stopped partway leaves the latest tag without its release or
# formula, and Cocogitto counts from that tag regardless. So each run first
# finishes the latest tag, rebuilding it from its own commit, and releases
# nothing new until it is finished.
#
#   release.sh --dry-run   print unfinished work, the next version, and its
#                          notes; change nothing
#   release.sh             release (the release workflow, with GITHUB_TOKEN set)
set -euo pipefail
cd "$(dirname "$0")/.."
dry_run=false
[[ ${1:-} == --dry-run ]] && dry_run=true

cog() { mise exec -- cog "$@"; }

work=$(mktemp -d)
preview_tag=
cleanup() {
    [[ -n $preview_tag ]] && git tag -d "$preview_tag" >/dev/null 2>&1
    git worktree remove --force "$work/build" >/dev/null 2>&1 || true
    rm -rf -- "$work"
    return 0
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# Prints published, draft, or missing for a tag's GitHub release, or unknown
# with the reason on stderr when GitHub cannot be asked.
release_state() {
    local answer
    if answer=$(gh release view "$1" --json isDraft --jq .isDraft 2>&1); then
        [[ $answer == true ]] && echo draft || echo published
    elif [[ $answer == *"release not found"* ]]; then
        echo missing
    else
        echo "$answer" >&2
        echo unknown
    fi
}

# Writes the release notes for an existing tag.
write_notes() {
    cog changelog --at "$1" --template .config/cog-release-notes.tera | sed '/./,$!d' >"$work/notes"
}

# Publishes the GitHub release for a pushed tag from the archives in a folder.
publish_release() {
    gh release create "$1" "$2"/*.tar.gz "$2"/*.tar.gz.sha256 \
        --verify-tag --title "$1" --notes-file "$work/notes"
}

# Points the Homebrew formula at a published release, using the checksum that
# was uploaded with it: an ad-hoc signed rebuild is not byte-identical.
publish_formula() {
    rm -rf -- "$work/checksums"
    gh release download "$1" --pattern '*.tar.gz.sha256' --dir "$work/checksums"
    DIST_DIR="$work/checksums" ./scripts/publish-homebrew.sh "${1#v}"
}

# Publishes whatever an earlier run left undone for a pushed tag. The rebuild
# happens in a separate worktree, so this checkout stays clean for Cocogitto.
finish_tag() {
    local tag=$1 state
    state=$(release_state "$tag")
    case $state in
        unknown)
            echo "Cannot read the GitHub release for $tag" >&2
            return 1
            ;;
        draft) gh release delete "$tag" --yes ;;
    esac
    if [[ $state != published ]]; then
        echo "Finishing $tag: publishing its GitHub release"
        git worktree add -q --detach "$work/build" "$tag"
        (cd "$work/build" && ./scripts/set-version.sh "${tag#v}" >/dev/null && make package VERSION="${tag#v}")
        write_notes "$tag"
        publish_release "$tag" "$work/build/dist"
        git worktree remove --force "$work/build"
    fi
    publish_formula "$tag"
}

latest=$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || true)
if $dry_run; then
    if [[ -n $latest ]]; then
        case $(release_state "$latest" 2>/dev/null) in
            missing | draft) echo "$latest has no published GitHub release; the next release run publishes it" ;;
            unknown) echo "Could not check the GitHub release for $latest (is gh signed in?)" ;;
        esac
    fi
else
    : "${GITHUB_TOKEN:?GITHUB_TOKEN is required to publish a release}"
    : "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required to publish a release}"
    export GH_TOKEN=$GITHUB_TOKEN GH_REPO=$GITHUB_REPOSITORY
    remote=${RELEASE_REMOTE:-"https://x-access-token:${GITHUB_TOKEN}@github.com/${GITHUB_REPOSITORY}.git"}
    # Not `&& finish_tag`: errexit does not apply inside a function run that way.
    if [[ -n $latest ]]; then
        finish_tag "$latest"
    fi
fi

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

# The notes need the tag, so it is created locally first; a preview removes
# it again on any exit, including a failed changelog or an interrupt.
git tag "$next"
$dry_run && preview_tag=$next
write_notes "$next"

if $dry_run; then
    echo "Next release: $next"
    echo
    cat "$work/notes"
    exit 0
fi

./scripts/set-version.sh "$version" >/dev/null
make package VERSION="$version"
# The tag is pushed with the given token so that, as the release app, it
# starts the machine image workflow for this version.
git push -q "$remote" "refs/tags/$next"
publish_release "$next" dist
publish_formula "$next"
