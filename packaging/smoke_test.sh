#!/usr/bin/env bash
# Installs dist/Install-FitzroviaRecordsDAW.pkg on this Mac exactly as the Installer app would,
# then launches Fitzrovia Records DAW and checks it stays running without a crash report.
# Used by CI on every supported macOS runner; safe to run on your own Mac too.
#   packaging/smoke_test.sh [path/to/pkg] [path/to/dmg]
# Exit code is non-zero if the install or launch fails. Writes smoke/ (screenshot + logs).
set -uo pipefail
cd "$(dirname "$0")/.."

PKG="${1:-dist/Install-FitzroviaRecordsDAW.pkg}"
DMG="${2:-$(ls dist/FitzroviaRecordsDAW-*.dmg 2>/dev/null | head -1)}"
APP="/Applications/Fitzrovia Records DAW.app"
OUT="smoke"; mkdir -p "$OUT"
OSVER="$(sw_vers -productVersion)"; ARCH="$(uname -m)"
TAG="macOS-$OSVER-$ARCH"
fail() { echo "::error::[$TAG] $*"; echo "FAIL: $*" >> "$OUT/result-$TAG.txt"; exit 1; }

echo "== Smoke test on macOS $OSVER ($ARCH) =="
sw_vers
[[ -f "$PKG" ]] || fail "package not found: $PKG"

echo "-- package checks"
pkgutil --check-signature "$PKG" || echo "(package is unsigned - expected without a Developer ID Installer certificate)"
pkgutil --payload-files "$PKG" | grep -q "Applications/Fitzrovia Records DAW.app/Contents/MacOS/StudioForge" \
  || fail "package payload does not contain the app binary"

echo "-- install (same engine as double-clicking the .pkg)"
sudo installer -pkg "$PKG" -target / -verboseR || fail "installer failed"
[[ -x "$APP/Contents/MacOS/StudioForge" ]] || fail "app not installed at $APP"

echo "-- bundle checks"
plutil -lint "$APP/Contents/Info.plist" || fail "Info.plist invalid"
codesign --verify --deep --strict --verbose=2 "$APP" || fail "code signature invalid (macOS would refuse to launch it)"
codesign -dv --entitlements - "$APP" 2>&1 | tee "$OUT/codesign-$TAG.txt"
lipo -archs "$APP/Contents/MacOS/StudioForge"
lipo -archs "$APP/Contents/MacOS/StudioForge" | grep -qw "$ARCH" || fail "binary has no $ARCH slice"
MINOS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist")"
echo "LSMinimumSystemVersion=$MINOS"
if xattr -p com.apple.quarantine "$APP" >/dev/null 2>&1; then fail "installed app is quarantined (postinstall should clear it)"; fi
spctl --assess --type execute -vv "$APP" 2>&1 || echo "(Gatekeeper assessment rejects ad-hoc builds that are not notarized - expected; see README)"
LIB="$HOME/Music/Fitzrovia Records DAW"
[[ -d "$LIB/Projects" ]] && echo "library created by postinstall: $LIB" || echo "warning: $LIB not created by postinstall (app creates it on launch)"

echo "-- launch"
CRASH_DIRS=("$HOME/Library/Logs/DiagnosticReports" "/Library/Logs/DiagnosticReports")
MARK="$OUT/.mark"; touch "$MARK"
open "$APP" || fail "open(1) could not launch the app"
ALIVE=0
for i in $(seq 1 30); do
  sleep 1
  if pgrep -x StudioForge >/dev/null; then ALIVE=$((ALIVE + 1)); else ALIVE=0; fi
  [[ $ALIVE -ge 15 ]] && break
done
screencapture -x "$OUT/screen-$TAG.png" 2>/dev/null || true
CRASHES="$(find "${CRASH_DIRS[@]}" -newer "$MARK" \( -name 'StudioForge*' -o -name 'Fitzrovia*' \) 2>/dev/null)"
log show --last 2m --style compact --predicate 'process == "StudioForge"' 2>/dev/null | tail -200 > "$OUT/log-$TAG.txt" || true
if [[ -n "$CRASHES" ]]; then
  for c in $CRASHES; do echo "== $c"; head -120 "$c"; cp "$c" "$OUT/" 2>/dev/null; done
  fail "app crashed on launch"
fi
[[ $ALIVE -ge 15 ]] || fail "app did not stay running for 15 s"
echo "app running for ${ALIVE}s, pid $(pgrep -x StudioForge | head -1)"

echo "-- quit"
osascript -e 'tell application id "com.studioforge.daw" to quit' 2>/dev/null || true
sleep 3
pkill -x StudioForge 2>/dev/null || true

if [[ -n "$DMG" && -f "$DMG" ]]; then
  echo "-- disk image checks ($DMG)"
  hdiutil verify "$DMG" || fail "disk image is corrupt"
  MNT="$(mktemp -d)"
  hdiutil attach -nobrowse -readonly -mountpoint "$MNT" "$DMG" >/dev/null || fail "disk image does not mount"
  ls -la "$MNT"
  codesign --verify --deep --strict "$MNT/Fitzrovia Records DAW.app" || { hdiutil detach "$MNT" -force >/dev/null; fail "app inside the DMG has an invalid signature"; }
  hdiutil detach "$MNT" -force >/dev/null || true
fi

echo "PASS" > "$OUT/result-$TAG.txt"
echo "== PASS: installs and opens on macOS $OSVER ($ARCH) =="
