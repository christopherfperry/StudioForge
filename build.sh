#!/usr/bin/env bash
# Builds StudioForge.app on macOS 13+ (Xcode 15+ / Swift 5.9+ command line tools required).
set -euo pipefail
cd "$(dirname "$0")"
CONFIG="${CONFIG:-release}"
APP="build/StudioForge.app"

if [[ "$(uname)" != "Darwin" ]]; then
  echo "StudioForge.app can only be built on macOS. Running the portable unit tests instead."
  exec swift test
fi

# UNIVERSAL=1 builds arm64 + x86_64 (needs full Xcode, not just the command line tools).
ARCH_FLAGS=()
if [[ "${UNIVERSAL:-0}" == "1" ]]; then ARCH_FLAGS=(--arch arm64 --arch x86_64); fi

echo "==> swift build -c $CONFIG ${ARCH_FLAGS[*]:-}"
swift build -c "$CONFIG" --product StudioForge ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"})"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/StudioForge" "$APP/Contents/MacOS/StudioForge"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[[ -f Resources/StudioForge.icns ]] && cp Resources/StudioForge.icns "$APP/Contents/Resources/StudioForge.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"
# SwiftPM resource bundles (factory presets, beat styles). Bundle.module finds them next to the
# executable or in Contents/Resources.
for b in "$BIN_DIR"/*.bundle; do
  [[ -e "$b" ]] && cp -R "$b" "$APP/Contents/Resources/"
done
# Optional: bundle ffmpeg for MP3/OGG export (FFMPEG=/path/to/ffmpeg ./build.sh)
if [[ -n "${FFMPEG:-}" && -x "${FFMPEG}" ]]; then cp "$FFMPEG" "$APP/Contents/Resources/ffmpeg"; fi

if [[ "${SKIP_SIGN:-0}" != "1" ]]; then
  echo "==> Ad-hoc code signing (with audio-input entitlement)"
  codesign --force --deep --sign - --entitlements StudioForge.entitlements "$APP"
fi
lipo -info "$APP/Contents/MacOS/StudioForge" || true

echo "Done: $APP"
echo "Run: open $APP"
