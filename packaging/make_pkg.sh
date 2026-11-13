#!/usr/bin/env bash
# Builds "dist/Install Fitzrovia Records DAW.pkg": a double-click macOS Installer package that puts
# Fitzrovia Records DAW.app into /Applications and runs packaging/pkg/scripts/postinstall
# (library folders for the logged-in user, presets, quarantine removal, LaunchServices).
# Run on macOS 13+ (pkgbuild/productbuild ship with the Xcode Command Line Tools).
#
# Environment variables (all optional):
#   SKIP_BUILD=1            use an existing build/Fitzrovia Records DAW.app (make_dmg.sh sets this)
#   UNIVERSAL=1|0           passed to build.sh when building (default 1, falls back to native)
#   SIGN_IDENTITY=...       "Developer ID Application: ..." for the app (default "-", ad-hoc)
#   INSTALLER_IDENTITY=...  "Developer ID Installer: Name (TEAMID)" to productsign the .pkg
#   NOTARIZE=1              notarize + staple the .pkg (needs INSTALLER_IDENTITY and
#                           NOTARY_PROFILE or APPLE_ID / APPLE_TEAM_ID / APPLE_APP_PASSWORD)
#   DRY_RUN=1               print the steps only (works on Linux)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
APP="build/Fitzrovia Records DAW.app"
DIST="dist"
PKG="$DIST/Install Fitzrovia Records DAW.pkg"
IDENTIFIER="com.studioforge.daw.pkg"
DRY_RUN="${DRY_RUN:-0}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

run() { echo "+ $*"; if [[ "$DRY_RUN" != "1" ]]; then "$@"; fi; }
die() { echo "error: $*" >&2; exit 1; }

VERSION="${VERSION:-$(python3 -c "import plistlib;print(plistlib.load(open('Resources/Info.plist','rb'))['CFBundleShortVersionString'])")}"
echo "==> Install Fitzrovia Records DAW.pkg $VERSION"

if [[ "$(uname)" != "Darwin" && "$DRY_RUN" != "1" ]]; then
  die "make_pkg.sh needs macOS (pkgbuild, productbuild). Use DRY_RUN=1 to review the steps, or the GitHub Actions workflow."
fi

# 1. App
if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
  if [[ "${UNIVERSAL:-1}" == "1" ]]; then
    run env CONFIG=release UNIVERSAL=1 SKIP_SIGN=1 ./build.sh || run env CONFIG=release UNIVERSAL=0 SKIP_SIGN=1 ./build.sh
  else
    run env CONFIG=release UNIVERSAL=0 SKIP_SIGN=1 ./build.sh
  fi
  if [[ "$SIGN_IDENTITY" == "-" ]]; then
    run codesign --force --options runtime --entitlements StudioForge.entitlements --sign - "$APP"
  else
    run codesign --force --timestamp --options runtime --entitlements StudioForge.entitlements --sign "$SIGN_IDENTITY" "$APP"
  fi
fi
[[ "$DRY_RUN" == "1" || -d "$APP" ]] || die "$APP not found"

# 2. Stage payload: <root>/Applications/Fitzrovia Records DAW.app
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/sf-pkg.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
run mkdir -p "$STAGE/root/Applications" "$STAGE/scripts" "$DIST"
run ditto "$APP" "$STAGE/root/Applications/Fitzrovia Records DAW.app"
run cp packaging/pkg/scripts/postinstall "$STAGE/scripts/postinstall"
run chmod 755 "$STAGE/scripts/postinstall"

# Component plist: always install to /Applications (no relocation to an old copy elsewhere).
COMPONENT_PLIST="$STAGE/component.plist"
cat > "$COMPONENT_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><array><dict>
  <key>RootRelativeBundlePath</key><string>Applications/Fitzrovia Records DAW.app</string>
  <key>BundleIsRelocatable</key><false/>
  <key>BundleIsVersionChecked</key><false/>
  <key>BundleHasStrictIdentifier</key><true/>
  <key>BundleOverwriteAction</key><string>upgrade</string>
</dict></array></plist>
EOF

# 3. Component package
run pkgbuild --root "$STAGE/root" --component-plist "$COMPONENT_PLIST" --scripts "$STAGE/scripts" \
  --identifier "$IDENTIFIER" --version "$VERSION" --install-location / "$STAGE/FitzroviaRecordsDAW-component.pkg"

# 4. Product archive with welcome / readme / conclusion pages
sed "s/@VERSION@/$VERSION/g" packaging/pkg/distribution.xml > "$STAGE/distribution.xml"
mkdir -p "$STAGE/resources"
for page in welcome readme conclusion; do
  echo "+ sed @VERSION@ packaging/pkg/resources/$page.html > $STAGE/resources/$page.html"
  sed "s/@VERSION@/$VERSION/g" "packaging/pkg/resources/$page.html" > "$STAGE/resources/$page.html"
done
if [[ -f packaging/assets/dmg_background.png ]]; then run cp packaging/assets/dmg_background.png "$STAGE/resources/background.png"; fi
UNSIGNED="$STAGE/unsigned.pkg"
run productbuild --distribution "$STAGE/distribution.xml" --resources "$STAGE/resources" \
  --package-path "$STAGE" "$UNSIGNED"

# 5. Sign (Developer ID Installer) or ship unsigned
run rm -f "$PKG"
if [[ -n "${INSTALLER_IDENTITY:-}" ]]; then
  run productsign --timestamp --sign "$INSTALLER_IDENTITY" "$UNSIGNED" "$PKG"
  run pkgutil --check-signature "$PKG"
else
  run cp "$UNSIGNED" "$PKG"
  echo "Note: unsigned package. macOS 15+: double-click, then System Settings > Privacy & Security > Open Anyway (or: sudo installer -pkg <pkg> -target /)."
fi

# 6. Notarize
if [[ "${NOTARIZE:-0}" == "1" ]]; then
  [[ -n "${INSTALLER_IDENTITY:-}" ]] || die "NOTARIZE=1 requires INSTALLER_IDENTITY"
  if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    run xcrun notarytool submit "$PKG" --keychain-profile "$NOTARY_PROFILE" --wait
  else
    [[ -n "${APPLE_ID:-}" && -n "${APPLE_TEAM_ID:-}" && -n "${APPLE_APP_PASSWORD:-}" ]] || die "set NOTARY_PROFILE or APPLE_ID/APPLE_TEAM_ID/APPLE_APP_PASSWORD"
    run xcrun notarytool submit "$PKG" --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD" --wait
  fi
  run xcrun stapler staple "$PKG"
fi

if [[ "$DRY_RUN" != "1" ]]; then shasum -a 256 "$PKG" | tee "$PKG.sha256"; fi
echo "Done: $PKG"
