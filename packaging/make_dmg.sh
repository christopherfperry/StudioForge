#!/usr/bin/env bash
# Builds StudioForge.app (Release) and packages it as dist/StudioForge-<version>.dmg.
# Run on macOS 13+ with Xcode 15+ (or Command Line Tools; universal builds need full Xcode).
#
# Environment variables (all optional):
#   UNIVERSAL=1|0          build arm64+x86_64 (default 1; falls back to native arch on failure)
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)"   default "-" (ad-hoc)
#   NOTARIZE=1             notarize + staple (needs Developer ID and one of the credentials below)
#   NOTARY_PROFILE=name    keychain profile from `xcrun notarytool store-credentials`
#   APPLE_ID / APPLE_TEAM_ID / APPLE_APP_PASSWORD             alternative notary credentials
#   SKIP_BUILD=1           package an existing build/StudioForge.app
#   SKIP_PKG=1             do not build/include Install StudioForge.pkg
#   INSTALLER_IDENTITY=... "Developer ID Installer: ..." used by make_pkg.sh to sign the .pkg
#   USE_CREATE_DMG=0       ignore create-dmg even if installed
#   DRY_RUN=1              print the steps without executing them (works on Linux for review)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
APP="build/StudioForge.app"
DIST="dist"
VOLNAME="StudioForge"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
UNIVERSAL="${UNIVERSAL:-1}"
DRY_RUN="${DRY_RUN:-0}"

run() { echo "+ $*"; if [[ "$DRY_RUN" != "1" ]]; then "$@"; fi; }
die() { echo "error: $*" >&2; exit 1; }

plist_version() {
  if command -v /usr/libexec/PlistBuddy >/dev/null 2>&1; then
    /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist
  else
    python3 -c "import plistlib;print(plistlib.load(open('Resources/Info.plist','rb'))['CFBundleShortVersionString'])"
  fi
}
VERSION="${VERSION:-$(plist_version)}"
DMG="$DIST/StudioForge-$VERSION.dmg"
echo "==> StudioForge $VERSION -> $DMG (signing identity: $SIGN_IDENTITY)"

if [[ "$(uname)" != "Darwin" && "$DRY_RUN" != "1" ]]; then
  die "make_dmg.sh needs macOS (hdiutil, codesign). Use DRY_RUN=1 to review the steps, or the GitHub Actions workflow."
fi

# 1. Artwork (background, icons). Uses committed PNG/ICNS when Pillow is unavailable.
if python3 -c "import PIL" 2>/dev/null; then run python3 packaging/make_art.py; fi
[[ -f packaging/assets/dmg_background.png ]] || die "packaging/assets/dmg_background.png missing (pip3 install pillow; python3 packaging/make_art.py)"

# 2. Build the app
if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
  if [[ "$UNIVERSAL" == "1" ]]; then
    if ! run env CONFIG=release UNIVERSAL=1 SKIP_SIGN=1 ./build.sh; then
      echo "warning: universal build failed (full Xcode required); building for the native architecture only"
      run env CONFIG=release UNIVERSAL=0 SKIP_SIGN=1 ./build.sh
    fi
  else
    run env CONFIG=release UNIVERSAL=0 SKIP_SIGN=1 ./build.sh
  fi
fi
[[ "$DRY_RUN" == "1" || -d "$APP" ]] || die "$APP not found"

# 3. Code signing (hardened runtime is required for notarization; harmless for ad-hoc)
SIGN_FLAGS=(--force --timestamp --options runtime --entitlements StudioForge.entitlements --sign "$SIGN_IDENTITY")
[[ "$SIGN_IDENTITY" == "-" ]] && SIGN_FLAGS=(--force --options runtime --entitlements StudioForge.entitlements --sign -)
if [[ -f "$APP/Contents/Resources/ffmpeg" ]]; then
  run codesign --force --options runtime --sign "$SIGN_IDENTITY" "$APP/Contents/Resources/ffmpeg"
fi
run codesign "${SIGN_FLAGS[@]}" "$APP"
run codesign --verify --deep --strict --verbose=2 "$APP"

# 4. Installer package (main item of the DMG): reuses the signed app above.
PKG="$DIST/Install StudioForge.pkg"
if [[ "${SKIP_PKG:-0}" != "1" ]]; then
  run env SKIP_BUILD=1 DRY_RUN="$DRY_RUN" NOTARIZE="${NOTARIZE:-0}" ./packaging/make_pkg.sh
fi
[[ "$DRY_RUN" == "1" || "${SKIP_PKG:-0}" == "1" || -f "$PKG" ]] || die "$PKG not found"

# 5. Disk image. Layout (640x480 window): Install StudioForge.pkg top centre (320,140);
# alternative drag-install row below: StudioForge.app (160,330) -> Applications (480,330).
# Finder uses one icon size per window, so the package is emphasised by position and the background.
run mkdir -p "$DIST"
run rm -f "$DMG"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/studioforge-dmg.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT

if [[ "${USE_CREATE_DMG:-1}" == "1" ]] && command -v create-dmg >/dev/null 2>&1; then
  echo "==> Using create-dmg"
  run cp -R "$APP" "$STAGE/"
  if [[ -f "$PKG" ]]; then run cp "$PKG" "$STAGE/"; fi
  run create-dmg --volname "$VOLNAME" --volicon Resources/StudioForge.icns \
    --background packaging/assets/dmg_background.png --window-pos 200 120 --window-size 640 480 \
    --icon-size 112 --icon "Install StudioForge.pkg" 320 140 --icon "StudioForge.app" 160 330 \
    --hide-extension "StudioForge.app" --app-drop-link 480 330 --no-internet-enable "$DMG" "$STAGE"
else
  echo "==> Using hdiutil + AppleScript layout"
  RW="$STAGE/rw.dmg"
  run mkdir -p "$STAGE/src/.background"
  run cp -R "$APP" "$STAGE/src/"
  if [[ -f "$PKG" || "$DRY_RUN" == "1" ]]; then run cp "$PKG" "$STAGE/src/"; fi
  run ln -s /Applications "$STAGE/src/Applications"
  run cp packaging/assets/dmg_background.png "$STAGE/src/.background/background.png"
  run cp Resources/StudioForge.icns "$STAGE/src/.VolumeIcon.icns"
  run hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE/src" -fs HFS+ -format UDRW -ov "$RW"
  MOUNT="/Volumes/$VOLNAME"
  if [[ -d "$MOUNT" ]]; then run hdiutil detach "$MOUNT" -force || true; fi
  run hdiutil attach "$RW" -readwrite -noverify -noautoopen -mountpoint "$MOUNT"
  # Custom volume icon flag
  if command -v SetFile >/dev/null 2>&1; then run SetFile -a C "$MOUNT"; fi
  if [[ "${CI:-}" == "true" ]]; then
    echo "CI detected: skipping Finder AppleScript layout (no GUI session)"
  elif [[ "$DRY_RUN" != "1" ]]; then
    # Finder layout. Fails harmlessly on headless CI without Finder automation permission.
    osascript <<EOF || echo "warning: Finder layout via AppleScript failed; DMG will use default layout"
tell application "Finder"
  tell disk "$VOLNAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 840, 628}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 112
    set text size of opts to 13
    set background picture of opts to file ".background:background.png"
    try
      set position of item "Install StudioForge.pkg" of container window to {320, 140}
    end try
    set position of item "StudioForge.app" of container window to {160, 330}
    set position of item "Applications" of container window to {480, 330}
    close
    open
    update without registering applications
    delay 1
    close
  end tell
end tell
EOF
  else
    echo "+ osascript (Finder window layout: 640x480, pkg at 320,140, app at 160,330, Applications at 480,330)"
  fi
  run sync
  run hdiutil detach "$MOUNT"
  run hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG"
fi

# 6. Sign / notarize the DMG
if [[ "$SIGN_IDENTITY" != "-" ]]; then
  run codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
fi
if [[ "${NOTARIZE:-0}" == "1" ]]; then
  [[ "$SIGN_IDENTITY" != "-" ]] || die "NOTARIZE=1 requires a Developer ID SIGN_IDENTITY"
  if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    run xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  else
    [[ -n "${APPLE_ID:-}" && -n "${APPLE_TEAM_ID:-}" && -n "${APPLE_APP_PASSWORD:-}" ]] || die "set NOTARY_PROFILE or APPLE_ID/APPLE_TEAM_ID/APPLE_APP_PASSWORD"
    run xcrun notarytool submit "$DMG" --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD" --wait
  fi
  run xcrun stapler staple "$DMG"
fi

run hdiutil verify "$DMG"
if [[ "$DRY_RUN" != "1" ]]; then
  shasum -a 256 "$DMG" | tee "$DMG.sha256"
fi
echo "Done: $DMG"
[[ "$SIGN_IDENTITY" == "-" ]] && echo "Note: ad-hoc signed. On first launch, Control-click StudioForge.app > Open (Gatekeeper)."
exit 0
