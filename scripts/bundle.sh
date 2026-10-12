#!/usr/bin/env bash
# Builds the Rust crates and the Swift app, then assembles and signs
# build/Tiller.app. Usage: scripts/bundle.sh [debug|release]   (default: release)
# TILLER_OUT and TILLER_BUNDLE_ID build a second copy with settings of its own,
# for trying changes while the everyday Tiller keeps running.
# The app is ad-hoc signed unless TILLER_SIGN_IDENTITY names a Developer ID
# certificate, which signs it for the hardened runtime and turns on updates.
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${TILLER_OUT:-$ROOT/build}"
APP="$OUT/Tiller.app"
BUNDLE_ID="${TILLER_BUNDLE_ID:-dev.sorrycc.tiller}"
# The version is the workspace's; the build number counts commits, so it
# goes up with every release, betas included, as Sparkle needs.
VERSION="$(sed -n 's/^version = "\(.*\)"$/\1/p' "$ROOT/Cargo.toml" | head -n 1)"
BUILD="${TILLER_BUILD:-$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)}"
IDENTITY="${TILLER_SIGN_IDENTITY:--}"
FEED_URL="https://sorrycc.github.io/Tiller/appcast.xml"
FRAMEWORK="Chromium Embedded Framework.framework"
SPARKLE="Sparkle.framework"
HELPERS=("Helper" "Helper (GPU)" "Helper (Renderer)" "Helper (Plugin)" "Helper (Alerts)")

[ -f "$HOME/.cargo/env" ] && source "$HOME/.cargo/env"
export CEF_PATH="${CEF_PATH:-$HOME/.local/share/cef}"
if [ ! -d "$CEF_PATH/$FRAMEWORK" ]; then
    echo "CEF not found at $CEF_PATH. See README.md for the one-time download." >&2
    exit 1
fi
# The framework copied into the app can come from another folder than the
# headers the Rust crates build against: the stock CEF download lacks H.264
# and AAC, so README.md has a build with them go in ~/.local/share/cef-codecs.
# CEF_FRAMEWORK_DIR overrides; without it that folder is used when it holds
# the framework, else the CEF_PATH one.
if [ -z "${CEF_FRAMEWORK_DIR:-}" ]; then
    CEF_FRAMEWORK_DIR="$HOME/.local/share/cef-codecs"
    [ -d "$CEF_FRAMEWORK_DIR/$FRAMEWORK" ] || CEF_FRAMEWORK_DIR="$CEF_PATH"
fi
if [ ! -d "$CEF_FRAMEWORK_DIR/$FRAMEWORK" ]; then
    echo "CEF framework not found at $CEF_FRAMEWORK_DIR." >&2
    exit 1
fi
FRAMEWORK_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$CEF_FRAMEWORK_DIR/$FRAMEWORK/Resources/Info.plist" 2>/dev/null || echo unknown)"
echo "==> CEF framework $FRAMEWORK_VERSION from $CEF_FRAMEWORK_DIR"

cargo_flags=()
[ "$CONFIG" = "release" ] && cargo_flags+=(--release)
echo "==> cargo build ($CONFIG)"
# Bash 3.2 treats empty arrays as unset under set -u.
cargo build --manifest-path "$ROOT/Cargo.toml" --workspace ${cargo_flags[@]+"${cargo_flags[@]}"}
RUST_OUT="$ROOT/target/$CONFIG"

echo "==> swift build ($CONFIG)"
SWIFT_OUT="$(swift build --package-path "$ROOT/app" -c "$CONFIG" --show-bin-path)"
# SwiftPM doesn't track the Rust static library, so a Rust-only change would
# not relink. Removing the executable forces the link step.
rm -f "$SWIFT_OUT/Tiller"
swift build --package-path "$ROOT/app" -c "$CONFIG" -Xlinker -L"$RUST_OUT" -Xlinker -dead_strip \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks

SPARKLE_KEY=""
if [ "$IDENTITY" != "-" ]; then
    SPARKLE_KEY="$(tr -d '[:space:]' < "$ROOT/scripts/sparkle-public-key" 2>/dev/null || true)"
    if [ -z "$SPARKLE_KEY" ]; then
        echo "scripts/sparkle-public-key is missing. See docs/releasing.md." >&2
        exit 1
    fi
fi

echo "==> assembling $APP ($VERSION, build $BUILD)"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

# write_plist <contents dir> <executable> <identifier> <is_helper>
write_plist() {
    local ui_element=""
    [ "$4" = "1" ] && ui_element="<key>LSUIElement</key><string>1</string>"
    local icon=""
    [ "$4" = "0" ] && icon="<key>CFBundleIconFile</key><string>Tiller</string>"
    # Web links and HTML files, so macOS offers Tiller as the default browser.
    # Updates, only for a build signed to be released.
    local updates=""
    [ "$4" = "0" ] && [ "$IDENTITY" != "-" ] && updates="<key>SUFeedURL</key><string>$FEED_URL</string>
    <key>SUPublicEDKey</key><string>$SPARKLE_KEY</string>
    <key>SUEnableAutomaticChecks</key><true/>
    <key>SUAutomaticallyUpdate</key><true/>"
    local browser=""
    [ "$4" = "0" ] && browser="<key>CFBundleURLTypes</key><array><dict>
        <key>CFBundleURLName</key><string>Web site URL</string>
        <key>CFBundleTypeRole</key><string>Viewer</string>
        <key>CFBundleURLSchemes</key><array><string>http</string><string>https</string></array>
    </dict></array>
    <key>CFBundleDocumentTypes</key><array><dict>
        <key>CFBundleTypeName</key><string>HTML document</string>
        <key>CFBundleTypeRole</key><string>Viewer</string>
        <key>LSHandlerRank</key><string>Default</string>
        <key>LSItemContentTypes</key><array><string>public.html</string><string>public.xhtml</string></array>
    </dict></array>"
    cat > "$1/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Tiller</string>
    <key>CFBundleDisplayName</key><string>Tiller</string>
    <key>CFBundleExecutable</key><string>$2</string>
    <key>CFBundleIdentifier</key><string>$3</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSEnvironment</key><dict><key>MallocNanoZone</key><string>0</string></dict>
    <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSBluetoothAlwaysUsageDescription</key><string>A website wants to connect to a Bluetooth device through the browser.</string>
    <key>NSCameraUsageDescription</key><string>A website wants to use the camera.</string>
    <key>NSMicrophoneUsageDescription</key><string>A website wants to use the microphone.</string>
    <key>NSAppleEventsUsageDescription</key><string>Tiller asks Finder to copy Chrome's data when security software blocks reading it directly.</string>
    $ui_element
    $browser
    $icon
    $updates
</dict>
</plist>
PLIST
}

cp "$SWIFT_OUT/Tiller" "$APP/Contents/MacOS/Tiller"
# Debug builds keep their symbols for the debugger.
[ "$CONFIG" = "release" ] && strip -x "$APP/Contents/MacOS/Tiller"
cp "$RUST_OUT/tiller_mcp" "$APP/Contents/MacOS/tiller_mcp"
# Not in MacOS/, where `tiller` and `Tiller` would be the same file on a
# case-insensitive disk.
cp "$RUST_OUT/tiller" "$APP/Contents/Helpers/tiller"
cp "$ROOT/app/Resources/Tiller.icns" "$APP/Contents/Resources/Tiller.icns"
cp -R "$ROOT/app/Resources/Agents" "$APP/Contents/Resources/Agents"
write_plist "$APP/Contents" "Tiller" "$BUNDLE_ID" 0

# ditto keeps the framework's symlinks and permissions intact.
ditto "$CEF_FRAMEWORK_DIR/$FRAMEWORK" "$APP/Contents/Frameworks/$FRAMEWORK"

# Keep only the English and Chinese Chromium locales, and drop SwiftShader,
# the software renderer used only when the GPU is unavailable.
find "$APP/Contents/Frameworks/$FRAMEWORK/Resources" -maxdepth 1 -name '*.lproj' \
    ! -name 'en.lproj' ! -name 'en_*.lproj' ! -name 'zh_CN*.lproj' ! -name 'zh_TW*.lproj' \
    -exec rm -rf {} +
rm -f "$APP/Contents/Frameworks/$FRAMEWORK/Libraries/"{libvk_swiftshader.dylib,libvulkan.dylib,vk_swiftshader_icd.json}

# Sparkle's XPC services are for sandboxed apps only.
ditto "$SWIFT_OUT/$SPARKLE" "$APP/Contents/Frameworks/$SPARKLE"
rm -rf "$APP/Contents/Frameworks/$SPARKLE/XPCServices" "$APP/Contents/Frameworks/$SPARKLE/Versions/B/XPCServices"

for suffix in "${HELPERS[@]}"; do
    name="Tiller $suffix"
    helper="$APP/Contents/Frameworks/$name.app"
    mkdir -p "$helper/Contents/MacOS"
    cp "$RUST_OUT/tiller_helper" "$helper/Contents/MacOS/$name"
    id_suffix="$(echo "$suffix" | tr -d '()' | tr ' ' '.' | tr '[:upper:]' '[:lower:]')"
    write_plist "$helper/Contents" "$name" "$BUNDLE_ID.$id_suffix" 1
done

# Inside out: the code in each bundle before the bundle. A Developer ID
# signature adds the hardened runtime and a timestamp, which notarization needs.
sign_flags=(--force --sign "$IDENTITY")
if [ "$IDENTITY" = "-" ]; then
    echo "==> ad-hoc signing"
else
    echo "==> signing as $IDENTITY"
    sign_flags+=(--options runtime --timestamp)
fi
sign() { codesign "${sign_flags[@]}" "$@"; }
for dylib in "$APP/Contents/Frameworks/$FRAMEWORK/Libraries/"*.dylib; do
    sign "$dylib"
done
sign "$APP/Contents/Frameworks/$FRAMEWORK"
sign "$APP/Contents/Frameworks/$SPARKLE/Versions/B/Autoupdate"
sign "$APP/Contents/Frameworks/$SPARKLE/Versions/B/Updater.app"
sign "$APP/Contents/Frameworks/$SPARKLE"
for suffix in "${HELPERS[@]}"; do
    sign --entitlements "$ROOT/app/Helper.entitlements" "$APP/Contents/Frameworks/Tiller $suffix.app"
done
sign "$APP/Contents/MacOS/tiller_mcp"
sign "$APP/Contents/Helpers/tiller"
sign --entitlements "$ROOT/app/Tiller.entitlements" "$APP"

echo "==> verifying signature"
codesign --verify --deep --strict "$APP"

echo "==> done: $APP ($(du -sh "$APP" | cut -f1))"
