#!/usr/bin/env bash
# Builds, signs and notarizes Tiller, publishes it as a GitHub release and adds
# it to the appcast on the gh-pages branch, from which installed Tillers update.
# Runs on a Mac with the Developer ID certificate in the keychain, or in the
# release workflow. Usage: scripts/release.sh
#
# The version is Cargo.toml's; one with a pre-release part, such as
# 0.2.0-beta.1, is a beta. The release notes, on GitHub and in the update
# window, come from CHANGELOG.md. Settings come from the environment:
#   TILLER_SIGN_IDENTITY    certificate to sign with (default: "Developer ID Application")
#   NOTARY_PROFILE          notarytool keychain profile (default: tiller-notary), or
#   APPLE_ID, APPLE_APP_SPECIFIC_PASSWORD, APPLE_TEAM_ID   to notarize without one
#   SPARKLE_PRIVATE_KEY     Sparkle's EdDSA key; without it sign_update reads the keychain
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/build/dist"
APP="$ROOT/build/Tiller.app"
SPARKLE_BIN="$ROOT/app/.build/artifacts/sparkle/Sparkle/bin"
VERSION="$(sed -n 's/^version = "\(.*\)"$/\1/p' "$ROOT/Cargo.toml" | head -n 1)"
TAG="v$VERSION"
BUILD="$(git -C "$ROOT" rev-list --count HEAD)"
export TILLER_SIGN_IDENTITY="${TILLER_SIGN_IDENTITY:-Developer ID Application}"
export TILLER_BUILD="$BUILD"
CHANNEL=""
PRERELEASE=()
if [[ "$VERSION" == *-* ]]; then
    CHANNEL="beta"
    PRERELEASE=(--prerelease)
fi

if [ -n "$(git -C "$ROOT" status --porcelain)" ]; then
    echo "The working tree has changes. Commit them first." >&2
    exit 1
fi
# In the workflow, the pushed tag has to be the version being built.
if [ -n "${GITHUB_REF_NAME:-}" ] && [ "$GITHUB_REF_NAME" != "$TAG" ]; then
    echo "Tag $GITHUB_REF_NAME doesn't match Cargo.toml's version $VERSION." >&2
    exit 1
fi
if gh release view "$TAG" >/dev/null 2>&1; then
    echo "Release $TAG exists already. Bump the version in Cargo.toml." >&2
    exit 1
fi

# The notes are the version's section of CHANGELOG.md, which a release must
# have, or for a beta whatever "## Unreleased" holds, which may be nothing.
NOTES="$(/usr/bin/python3 - "$ROOT/CHANGELOG.md" "${CHANNEL:+Unreleased}" "$VERSION" <<'EOF'
import re, sys
path, heading = sys.argv[1], sys.argv[2] or sys.argv[3]
m = re.search(rf"^## {re.escape(heading)}\n(.*?)(?=^## |\Z)", open(path).read(), re.M | re.S)
if not m and heading != "Unreleased":
    sys.exit(f"CHANGELOG.md has no ## {heading} section. Add it and commit it first.")
print(m.group(1).strip() if m else "")
EOF
)"

if [ -n "${APPLE_ID:-}" ]; then
    notary_auth=(--apple-id "$APPLE_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD" --team-id "$APPLE_TEAM_ID")
else
    notary_auth=(--keychain-profile "${NOTARY_PROFILE:-tiller-notary}")
fi

echo "==> Tiller $VERSION (build $BUILD)${CHANNEL:+, $CHANNEL}"
"$ROOT/scripts/bundle.sh" release

rm -rf "$DIST"
mkdir -p "$DIST/dmg"
NOTES_FILE="$DIST/notes.md"
printf '%s\n' "$NOTES" > "$NOTES_FILE"
DMG="$DIST/Tiller-$VERSION.dmg"
ZIP="$DIST/Tiller-$VERSION.zip"

# The disk image holds the app and a link to Applications to drag it to.
echo "==> making $DMG"
ditto "$APP" "$DIST/dmg/Tiller.app"
ln -s /Applications "$DIST/dmg/Applications"
hdiutil create -quiet -volname Tiller -srcfolder "$DIST/dmg" -format UDZO "$DMG"
rm -rf "$DIST/dmg"
codesign --force --sign "$TILLER_SIGN_IDENTITY" --timestamp "$DMG"

# Notarizing the disk image covers the app in it too, so both can be stapled.
echo "==> notarizing"
# Polls instead of `submit --wait` or `wait`, whose progress output has
# crashed notarytool. Apple can take hours over a team's first submissions.
json_field() { /usr/bin/python3 -c "import json, sys; print(json.load(sys.stdin)['$1'])"; }
id="$(xcrun notarytool submit "$DMG" "${notary_auth[@]}" --output-format json | json_field id)"
echo "    submission $id"
status="In Progress"
for _ in $(seq 360); do
    status="$(xcrun notarytool info "$id" "${notary_auth[@]}" --output-format json | json_field status || echo "In Progress")"
    [ "$status" != "In Progress" ] && break
    sleep 30
done
if [ "$status" != "Accepted" ]; then
    echo "Notarization finished as $status:" >&2
    xcrun notarytool log "$id" "${notary_auth[@]}" >&2
    exit 1
fi
xcrun stapler staple -q "$DMG"
xcrun stapler staple -q "$APP"

# Sparkle downloads the zip, signed with its own key.
echo "==> making $ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
if [ -n "${SPARKLE_PRIVATE_KEY:-}" ]; then
    signature="$("$SPARKLE_BIN/sign_update" --ed-key-file - "$ZIP" <<<"$SPARKLE_PRIVATE_KEY")"
else
    signature="$("$SPARKLE_BIN/sign_update" "$ZIP")"
fi

echo "==> publishing $TAG"
# A beta with nothing under "## Unreleased" lists its pull requests instead.
if [ -n "$NOTES" ]; then
    notes_args=(--notes-file "$NOTES_FILE")
else
    notes_args=(--generate-notes)
fi
gh release create "$TAG" "$DMG" "$ZIP" --target "$(git -C "$ROOT" rev-parse HEAD)" \
    --title "Tiller $VERSION" "${notes_args[@]}" ${PRERELEASE[@]+"${PRERELEASE[@]}"}

# The appcast goes on gh-pages, committed without checking that branch out,
# and only once the release it points to is there.
echo "==> updating the appcast"
git -C "$ROOT" fetch --quiet origin gh-pages 2>/dev/null || true
APPCAST="$DIST/appcast.xml"
parent=()
tree_entries=""
if git -C "$ROOT" rev-parse --verify --quiet origin/gh-pages >/dev/null; then
    parent=(-p origin/gh-pages)
    git -C "$ROOT" show origin/gh-pages:appcast.xml > "$APPCAST" 2>/dev/null || rm -f "$APPCAST"
    tree_entries="$(git -C "$ROOT" ls-tree origin/gh-pages | grep -v $'\tappcast.xml$' || true)"
fi
URL="https://github.com/sorrycc/Tiller/releases/download/$TAG/Tiller-$VERSION.zip"
/usr/bin/python3 "$ROOT/scripts/appcast.py" "$APPCAST" "$VERSION" "$BUILD" "$URL" "$signature" "$NOTES_FILE" $CHANNEL
blob="$(git -C "$ROOT" hash-object -w "$APPCAST")"
tree="$(printf '%s\n100644 blob %s\tappcast.xml\n' "$tree_entries" "$blob" | sed '/^$/d' | git -C "$ROOT" mktree)"
commit="$(git -C "$ROOT" commit-tree "$tree" ${parent[@]+"${parent[@]}"} -m "Add Tiller $VERSION to the appcast")"
git -C "$ROOT" push --quiet origin "$commit:refs/heads/gh-pages"

echo "==> released Tiller $VERSION: https://github.com/sorrycc/Tiller/releases/tag/$TAG"
