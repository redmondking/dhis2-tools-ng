#!/usr/bin/env bash
#
#   Release a version of dhis2-tools (see RELEASING.md). Runs in the repo, never on servers.
#   Checks, sets VERSION (and moves the CHANGELOG.md "Unreleased" section for a final release), commits and tags locally,
#   then prints the push and publish commands for you to run.

set -euo pipefail

PROG=$(basename "$0")
REPO_URL=https://github.com/redmondking/dhis2-tools-ng

usage() {
  cat <<EOF
Usage: $PROG [--dry-run] <version>
       $PROG --notes <version>
  <version>        x.y.z for a release, x.y.z-rc.N for a release candidate
  --dry-run        run the checks and show what would change; change nothing
  --notes <ver>    print that version's CHANGELOG.md section (a release candidate: the Unreleased section)
  -h, --help       this help
Must run on release/x.y.z or hotfix/x.y.z with a clean working tree. Exit codes: 0 ok, 1 refused or failed, 3 missing input.
EOF
  exit "${1:-1}"
}

die() { echo "Error: $*" >&2; exit 1; }

# vkey VERSION: a sortable key; a release candidate sorts before its release (0.1.0-rc.2 < 0.1.0)
vkey() {
  local base=${1%%-rc.*} rc=999999 a b c
  [[ $1 == *-rc.* ]] && rc=${1##*-rc.}
  IFS=. read -r a b c <<< "$base"
  printf '%06d.%06d.%06d.%06d' "$a" "$b" "$c" "$rc"
}

# section VERSION: the CHANGELOG.md section of VERSION (Unreleased for a release candidate), without its heading
section() {
  local head
  if [[ $1 == *-rc.* ]]; then head='## [Unreleased]'; else head="## [$1]"; fi
  awk -v h="$head" 'index($0, h) == 1 {on = 1; next} on && /^## \[/ {exit} on && /^\[[^]]*\]: / {exit} on' CHANGELOG.md
}

DRY_RUN=false
NOTES=false
VERSION=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run) DRY_RUN=true ;;
    --notes) NOTES=true ;;
    -h|--help) usage 0 ;;
    -*) die "unknown option $1 (see $PROG --help)" ;;
    *) [[ -z $VERSION ]] || die "one version at a time"; VERSION=$1 ;;
  esac
  shift
done
[[ -n $VERSION ]] || { echo "Error: missing <version> (see $PROG --help)" >&2; exit 3; }
[[ $VERSION =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)(-rc\.[0-9]+)?$ ]] || die "$VERSION is not x.y.z or x.y.z-rc.N"
BASE=${VERSION%%-rc.*}
cd "$(git rev-parse --show-toplevel)"

if [[ $NOTES == true ]]; then
  section "$VERSION"
  exit 0
fi

###############################################################
# Checks: nothing changes unless all pass

[[ -z $(git status --porcelain) ]] || die "the working tree has uncommitted changes: commit or stash them first"
BRANCH=$(git symbolic-ref --short -q HEAD) || die "not on a branch"
[[ $BRANCH == "release/$BASE" || $BRANCH == "hotfix/$BASE" ]] \
  || die "$VERSION is released from release/$BASE or hotfix/$BASE, not from $BRANCH"
if git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null; then die "tag v$VERSION already exists"; fi
NEWEST=""
for T in $(git tag -l 'v[0-9]*'); do
  T=${T#v}
  [[ -z $NEWEST || $(vkey "$T") > $(vkey "$NEWEST") ]] && NEWEST=$T
done
if [[ -n $NEWEST && ! $(vkey "$VERSION") > $(vkey "$NEWEST") ]]; then
  die "$VERSION is not newer than the newest release, $NEWEST"
fi
grep -q '^## \[Unreleased\]' CHANGELOG.md || die "CHANGELOG.md has no '## [Unreleased]' section"
if [[ $VERSION != *-rc.* ]]; then
  section "$VERSION" | grep -q . && die "CHANGELOG.md already has a section for $VERSION"
  [[ $(awk '/^## \[Unreleased\]/ {on = 1; next} on && /^(## |\[)/ {exit} on && /^- /' CHANGELOG.md) ]] \
    || die "the Unreleased section of CHANGELOG.md is empty: nothing to release"
fi
FAILED=()
while IFS= read -r F; do
  bash -n "$F" 2>/dev/null || FAILED+=("$F")
done < <({ echo install.sh; find setup -type f -name '*.sh'; grep -rlE '^#!.*(ba)?sh' setup; } | sort -u)
[[ ${#FAILED[@]} -eq 0 ]] || die "bash -n fails on: ${FAILED[*]}"

###############################################################
# Changes

TODAY=$(date -u +%F)
if [[ $DRY_RUN == true ]]; then
  echo "Checks passed. Would:"
  echo "  set VERSION to $VERSION"
  [[ $VERSION == *-rc.* ]] || echo "  move the Unreleased section of CHANGELOG.md to [$VERSION] - $TODAY"
  echo "  commit 'Release $VERSION' on $BRANCH and tag v$VERSION"
  exit 0
fi

printf '%s\n' "$VERSION" > VERSION
if [[ $VERSION != *-rc.* ]]; then
  FROM=$(sed -n 's|^\[Unreleased\]: .*/compare/\(.*\)\.\.\.HEAD$|\1|p' CHANGELOG.md)
  [[ -n $FROM ]] || die "CHANGELOG.md has no '[Unreleased]: .../compare/<from>...HEAD' link"
  awk -v v="$VERSION" -v d="$TODAY" -v url="$REPO_URL" -v from="$FROM" '
    /^## \[Unreleased\]/ { print; print ""; print "## [" v "] - " d; next }
    /^\[Unreleased\]: / { print "[Unreleased]: " url "/compare/v" v "...HEAD"; print "[" v "]: " url "/compare/" from "...v" v; next }
    { print }' CHANGELOG.md > CHANGELOG.md.new
  mv CHANGELOG.md.new CHANGELOG.md
fi
git commit -q -am "Release $VERSION"
git tag -a "v$VERSION" -m "dhis2-tools $VERSION"
echo "Committed 'Release $VERSION' and tagged v$VERSION (nothing pushed)."

###############################################################
# What to run next

PRE=""
[[ $VERSION == *-rc.* ]] && PRE=" --prerelease"
cat <<EOF

Next steps (see RELEASING.md):
  git push origin $BRANCH v$VERSION
  tools/release.sh --notes $VERSION | gh release create v$VERSION --title "dhis2-tools $VERSION"$PRE --notes-file -
EOF
if [[ $VERSION != *-rc.* ]]; then
  cat <<EOF
Only with the maintainer's yes, move master to the release:
  git checkout master && git merge --ff-only v$VERSION && git push origin master
Then remove the finished branch (the tag keeps the release):
  git branch -d $BRANCH && git push origin --delete $BRANCH
EOF
fi
