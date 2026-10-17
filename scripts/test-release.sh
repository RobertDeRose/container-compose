#!/bin/bash
# Exercises the release script's recovery of a release that stopped partway.
# Fake gh, make, and Cocogitto commands stand in for GitHub, the Swift build,
# and the version calculation; local bare repositories stand in for the
# origin and the Homebrew tap.
set -euo pipefail
cd "$(dirname "$0")/.."
root=$(mktemp -d)
trap 'rm -rf -- "$root"' EXIT
fail() {
    echo "Release check failed: $*" >&2
    exit 1
}

repo="$root/repo"
mkdir -p "$repo/scripts" "$repo/homebrew" "$repo/Sources/ContainerCompose" "$root/bin" "$root/gh"
cp scripts/release.sh scripts/set-version.sh scripts/publish-homebrew.sh "$repo/scripts/"
cp homebrew/container-compose-plugin.rb.in "$repo/homebrew/"
cp Sources/ContainerCompose/ComposeVersion.swift "$repo/Sources/ContainerCompose/"
printf 'dist/\n' >"$repo/.gitignore"
git() { command git -c user.name=t -c user.email=t@example.com -c advice.detachedHead=false "$@"; }
git init -q -b main "$repo"
git -C "$repo" add -A
git -C "$repo" commit -q -m "feat: start"
git init -q --bare -b main "$root/origin.git"
git init -q --bare -b main "$root/tap.git"
git clone -q "file://$root/tap.git" "$root/seed" 2>/dev/null
git -C "$root/seed" commit -q --allow-empty -m seed
git -C "$root/seed" push -q origin HEAD:main

# Cocogitto: the next version comes from FAKE_NEXT; the notes name the tag.
cat >"$root/bin/mise" <<'EOF'
#!/bin/bash
case $4 in
    bump) echo "${FAKE_NEXT:-No conventional commit found to bump current version.}" ;;
    changelog) [[ -z ${FAKE_CHANGELOG_FAIL:-} ]] || exit 1; printf '\n### Fixed\n\n- Notes for %s\n' "$6" ;;
esac
EOF
# The build: the archive records the commit and version it was built from.
cat >"$root/bin/make" <<'EOF'
#!/bin/bash
version=${2#VERSION=}
echo "$version" >>"$FAKE_ROOT/make.log"
mkdir -p dist
archive=container-compose-plugin-$version-darwin-arm64.tar.gz
{ git rev-parse HEAD; grep -o 'current = "[^"]*"' Sources/ContainerCompose/ComposeVersion.swift; } >"dist/$archive"
(cd dist && shasum -a 256 "$archive" >"$archive.sha256")
EOF
# GitHub releases: one folder per release, holding its assets and notes; a
# .draft file marks an upload that never finished.
cat >"$root/bin/gh" <<'EOF'
#!/bin/bash
[[ -z ${FAKE_GH_DOWN:-} ]] || { echo "HTTP 401: Bad credentials" >&2; exit 1; }
release="$FAKE_ROOT/gh/$3"
case "$1 $2" in
    "release view")
        [[ -d $release ]] || { echo "release not found" >&2; exit 1; }
        [[ -f $release/.draft ]] && echo true || echo false ;;
    "release delete") rm -rf -- "$release" ;;
    "release create")
        command git ls-remote --exit-code --tags "$RELEASE_REMOTE" "refs/tags/$3" >/dev/null ||
            { echo "tag $3 is not pushed" >&2; exit 1; }
        mkdir -p "$release"; shift 3
        while (($#)); do
            case $1 in
                --verify-tag) shift ;;
                --title) shift 2 ;;
                --notes-file) cp "$2" "$release/.notes"; shift 2 ;;
                *) cp "$1" "$release/"; shift ;;
            esac
        done ;;
    "release download") mkdir -p "$7"; cp "$release"/$5 "$7/" ;;
esac
EOF
chmod +x "$root/bin/"*
export PATH="$root/bin:$PATH" FAKE_ROOT=$root GITHUB_TOKEN=fake GITHUB_REPOSITORY=owner/repo
export RELEASE_REMOTE="file://$root/origin.git" TAP_REMOTE="file://$root/tap.git"

release() { "$repo/scripts/release.sh" "$@" 2>&1; }
commit() { git -C "$repo" commit -q --allow-empty -m "$1"; }
push_tag() {
    git -C "$repo" tag "$1"
    git -C "$repo" push -q "$RELEASE_REMOTE" "refs/tags/$1"
}
formula_version() {
    git -C "$root/tap.git" show main:Formula/container-compose-plugin.rb 2>/dev/null | sed -n 's/^ *version "\(.*\)"/\1/p'
}
asset() { echo "$root/gh/$1/container-compose-plugin-${1#v}-darwin-arm64.tar.gz"; }
built() { : >"$root/make.log"; }

# A tag pushed but never released is rebuilt from its own commit, not HEAD.
commit "fix: one"
push_tag v0.1.0
tagged=$(git -C "$repo" rev-parse HEAD)
commit "docs: after the tag"
built
out=$(release) || fail "unreleased tag: $out"
[[ -f $(asset v0.1.0) ]] || fail "v0.1.0 was not released"
[[ $(head -n 1 "$(asset v0.1.0)") == "$tagged" ]] || fail "v0.1.0 was not built from its tag"
grep -q 'current = "0.1.0"' "$(asset v0.1.0)" || fail "v0.1.0 was not stamped"
grep -q 'Notes for v0.1.0' "$root/gh/v0.1.0/.notes" || fail "v0.1.0 has no notes"
[[ $(formula_version) == 0.1.0 ]] || fail "formula was not published for v0.1.0"
[[ -z $(git -C "$repo" status --porcelain) ]] || fail "the checkout was left dirty"
[[ -z $(git -C "$repo" worktree list | sed 1d) ]] || fail "the build worktree was left behind"

# A fully published tag needs nothing.
built
out=$(release) || fail "published tag: $out"
grep -q 'already describes 0.1.0' <<<"$out" || fail "formula was not left alone: $out"
grep -q 'No release' <<<"$out" || fail "a release was made from nothing: $out"
[[ ! -s $root/make.log ]] || fail "a published tag was rebuilt"

# An interrupted upload leaves a draft, which is replaced.
commit "fix: two"
push_tag v0.2.0
mkdir -p "$root/gh/v0.2.0" && : >"$root/gh/v0.2.0/.draft"
out=$(release) || fail "draft: $out"
[[ ! -f $root/gh/v0.2.0/.draft && -f $(asset v0.2.0) ]] || fail "the v0.2.0 draft was not replaced"
[[ $(formula_version) == 0.2.0 ]] || fail "formula was not published for v0.2.0"

# A release whose formula step failed gets the formula, with the uploaded
# checksum and no rebuild.
commit "fix: three"
push_tag v0.3.0
mkdir -p "$root/gh/v0.3.0"
printf 'uploaded build\n' >"$(asset v0.3.0)"
(cd "$root/gh/v0.3.0" && shasum -a 256 "$(basename "$(asset v0.3.0)")" >"$(basename "$(asset v0.3.0)").sha256")
built
out=$(release) || fail "formula retry: $out"
[[ ! -s $root/make.log ]] || fail "a released tag was rebuilt for its formula"
[[ $(formula_version) == 0.3.0 ]] || fail "formula was not published for v0.3.0"
sha=$(cut -d' ' -f1 "$root/gh/v0.3.0/"*.sha256)
git -C "$root/tap.git" show main:Formula/container-compose-plugin.rb | grep -q "$sha" ||
    fail "formula does not use the uploaded checksum"

# An unfinished tag is finished before the next version is released.
commit "fix: four"
push_tag v0.4.0
commit "feat: five"
out=$(FAKE_NEXT=v0.5.0 release) || fail "finish then release: $out"
[[ -f $(asset v0.4.0) && -f $(asset v0.5.0) ]] || fail "v0.4.0 and v0.5.0 were not both released"
command git ls-remote --exit-code --tags "$RELEASE_REMOTE" refs/tags/v0.5.0 >/dev/null || fail "v0.5.0 was not pushed"
[[ $(formula_version) == 0.5.0 ]] || fail "formula was not published for v0.5.0"

# A preview reports unfinished work, even without GitHub, and changes nothing.
git -C "$repo" checkout -q -- .
commit "fix: six"
push_tag v0.6.0
commit "feat: seven"
tags=$(git -C "$repo" tag -l)
out=$(FAKE_NEXT=v0.7.0 release --dry-run) || fail "preview: $out"
grep -q 'v0.6.0 has no published GitHub release' <<<"$out" || fail "preview missed v0.6.0: $out"
grep -q 'Next release: v0.7.0' <<<"$out" || fail "preview missed v0.7.0: $out"
out=$(FAKE_GH_DOWN=1 FAKE_NEXT=v0.7.0 release --dry-run) || fail "preview without GitHub: $out"
grep -q 'Could not check the GitHub release for v0.6.0' <<<"$out" || fail "preview hid the GitHub failure: $out"
# A preview whose notes fail still removes the tag it created.
FAKE_CHANGELOG_FAIL=1 FAKE_NEXT=v0.7.0 release --dry-run >/dev/null && fail "a failed changelog was ignored"
[[ $(git -C "$repo" tag -l) == "$tags" ]] || fail "a preview left tags behind"
[[ ! -d $root/gh/v0.6.0 && ! -d $root/gh/v0.7.0 ]] || fail "a preview published a release"

# A release that cannot read GitHub stops before releasing anything new.
FAKE_GH_DOWN=1 FAKE_NEXT=v0.7.0 release >/dev/null && fail "a release ran without GitHub"
[[ $(git -C "$repo" tag -l) == "$tags" ]] || fail "a release went ahead past an unfinished tag"

printf '%s\n' 'Release checks passed: unreleased tag, published tag, draft, formula retry, finish then release, preview.'
