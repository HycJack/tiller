#!/usr/bin/env bash
# Downloads CEF as README.md describes: the stock build, whose headers the Rust
# crates build against, into $CEF_PATH, and the third-party build with H.264
# and AAC, whose framework goes in the app, into ~/.local/share/cef-codecs.
# A folder already there is kept when its framework is the version below, and
# replaced otherwise, so changing a version can't leave the old framework in
# the app. The release workflow runs this.
set -euo pipefail

CEF_RS_TAG="cef-v154.2.0+154.0.28"
CEF_VERSION="154.0.28"
CODECS_URL="https://github.com/sorrycc/Tiller/releases/download/cef-codecs-154.0.26/cef-154.0.26-macosarm64-codecs.tar.zst"
CODECS_VERSION="154.0.26"
# The codecs build is unsigned and made by a third party, aiexkwan/aurix-cef,
# which no longer publishes it, so a copy lives on this repository's
# cef-codecs-154.0.26 release: this is the archive that was checked. Change
# both together. bump.sh checks the URL still works before tagging.
CODECS_SHA256="ef6dd8cad079bd4b8402134132c699f50575610fa1d553624d17334477e4c3a9"
FRAMEWORK="Chromium Embedded Framework.framework"
CEF_PATH="${CEF_PATH:-$HOME/.local/share/cef}"
CODECS_DIR="$HOME/.local/share/cef-codecs"

[ -f "$HOME/.cargo/env" ] && source "$HOME/.cargo/env"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# has_version <folder> <version>: the folder's framework is that CEF version,
# which its Info.plist gives with a fourth number, as in 154.0.28.0.
has_version() {
    local found
    found="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$1/$FRAMEWORK/Resources/Info.plist" 2>/dev/null)" || return 1
    [ "$found" = "$2" ] || [ "$found" = "$2.0" ]
}

if has_version "$CEF_PATH" "$CEF_VERSION"; then
    echo "==> CEF $CEF_VERSION already at $CEF_PATH"
else
    echo "==> exporting CEF ($CEF_RS_TAG) to $CEF_PATH"
    git clone --quiet --depth 1 --branch "$CEF_RS_TAG" https://github.com/tauri-apps/cef-rs "$TMP/cef-rs"
    cargo run --quiet --manifest-path "$TMP/cef-rs/Cargo.toml" -p export-cef-dir -- --force "$CEF_PATH"
fi

if has_version "$CODECS_DIR" "$CODECS_VERSION"; then
    echo "==> CEF $CODECS_VERSION with codecs already at $CODECS_DIR"
else
    echo "==> downloading CEF $CODECS_VERSION with codecs to $CODECS_DIR"
    curl -fsSL --retry 3 --retry-all-errors --connect-timeout 30 -o "$TMP/codecs.tar.zst" "$CODECS_URL" || {
        echo "::error::Couldn't download the codecs build from $CODECS_URL. It's an asset of a release in sorrycc/Tiller; docs/releasing.md says how to replace it." >&2
        exit 1
    }
    echo "$CODECS_SHA256  $TMP/codecs.tar.zst" | shasum -a 256 -c - >/dev/null
    # Another version's files would otherwise stay mixed in with these.
    rm -rf "$CODECS_DIR"
    mkdir -p "$CODECS_DIR"
    tar --use-compress-program=unzstd -xf "$TMP/codecs.tar.zst" -C "$CODECS_DIR"
fi
