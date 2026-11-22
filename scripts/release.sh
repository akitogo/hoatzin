#!/bin/zsh
# Publishes a release of Hoatzin on GitHub.
#
#   scripts/release.sh 1.0.1                raise the version, test, build, notarize, tag, push and
#                                           create the GitHub release with the notarized app
#   scripts/release.sh 1.0.1 --prerelease   the same, marked as a pre-release on GitHub
#   scripts/release.sh 1.0.1 --dry-run      only build and package (not notarized); nothing is
#                                           committed, tagged or published, Info.plist is restored
#   --notes-file <file>                     release notes; otherwise GitHub writes them from the
#                                           commits since the last release
#
# The version goes into CFBundleShortVersionString; CFBundleVersion (the build number) goes up by
# one whenever the version changes. Signing and notarization work as in scripts/build-app.sh.
set -euo pipefail
cd "${0:A:h}/.."

# Like build-app.sh: the macOS SDK's SwiftUI macros ship with Xcode, not with the Command Line Tools.
if [[ -d /Applications/Xcode.app ]]; then
  export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
fi

usage() { echo "usage: scripts/release.sh <x.y.z> [--prerelease] [--dry-run] [--notes-file <file>]" >&2; exit 2; }
VERSION=${1:-}
[[ $VERSION =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || usage
shift
PRERELEASE=false DRY_RUN=false NOTES_FILE=""
while (( $# )); do
  case $1 in
    --prerelease) PRERELEASE=true ;;
    --dry-run) DRY_RUN=true ;;
    --notes-file) [[ $# -ge 2 ]] || usage; NOTES_FILE=$2; shift ;;
    *) usage ;;
  esac
  shift
done

PLIST=Resources/Info.plist
TAG=v$VERSION
APP=build/Hoatzin.app
ZIP=build/release/Hoatzin-$VERSION.zip
fail() { echo "release: $*" >&2; exit 1; }
plist() { /usr/libexec/PlistBuddy -c "$1" "$PLIST"; }

# 1. Checks, before anything changes.
current=$(plist 'Print CFBundleShortVersionString')
build=$(plist 'Print CFBundleVersion')
[[ $(printf '%s\n%s\n' "$current" "$VERSION" | sort -V | tail -1) == "$VERSION" ]] \
  || fail "$VERSION is older than the current version $current"
[[ -z $NOTES_FILE || -f $NOTES_FILE ]] || fail "no such notes file: $NOTES_FILE"
if ! $DRY_RUN; then
  [[ -z $(git status --porcelain) ]] || fail "commit or stash your changes first"
  [[ $(git branch --show-current) == main ]] || fail "releases are made from main"
  git remote get-url origin >/dev/null 2>&1 || fail "no 'origin' remote; create the GitHub repository first (see README)"
  gh auth status >/dev/null 2>&1 || fail "not signed in to GitHub; run: gh auth login"
  git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && fail "tag $TAG exists already"
  [[ -z $(git ls-remote --tags origin "refs/tags/$TAG") ]] || fail "tag $TAG exists on GitHub already"
fi

# 2. Version. A dry run puts Info.plist back afterwards.
if [[ $VERSION != "$current" ]]; then
  if $DRY_RUN; then
    cp "$PLIST" build/Info.plist.release-backup
    trap 'mv build/Info.plist.release-backup "$PLIST"' EXIT
  fi
  build=$((build + 1))
  plist "Set :CFBundleShortVersionString $VERSION"
  plist "Set :CFBundleVersion $build"
fi
echo "Releasing Hoatzin $VERSION (build $build)"

# 3. Test, build, sign, notarize.
if $DRY_RUN; then
  scripts/build-app.sh
else
  swift test
  scripts/build-app.sh --notarize
  xcrun stapler validate "$APP"
  spctl --assess --type execute "$APP" || fail "Gatekeeper does not accept the app"
fi
codesign --verify --strict --deep "$APP"

# 4. Package. ditto keeps the signature and the stapled notarization intact.
mkdir -p build/release
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
SHA=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)
echo "Packaged $ZIP"
echo "SHA-256 $SHA"
if $DRY_RUN; then
  echo "Dry run: not notarized; nothing committed, tagged or published."
  exit 0
fi

# 5. Commit the version, tag, push, publish.
git add "$PLIST"
git diff --cached --quiet || git commit -m "Release $VERSION"
git tag -a "$TAG" -m "Hoatzin $VERSION"
git push origin main "$TAG"
args=(release create "$TAG" "$ZIP" --verify-tag --title "Hoatzin $VERSION"
      --notes "Notarized for macOS 14 or later. SHA-256 of Hoatzin-$VERSION.zip: \`$SHA\`")
if [[ -n $NOTES_FILE ]]; then
  args=(release create "$TAG" "$ZIP" --verify-tag --title "Hoatzin $VERSION" --notes-file "$NOTES_FILE")
else
  args+=(--generate-notes)
fi
$PRERELEASE && args+=(--prerelease)
gh "${args[@]}"
echo "Published $TAG: $(gh release view "$TAG" --json url --jq .url)"
