#!/usr/bin/env bash
# Builds FitzroviaRecordsDAW-Source-Installer.dmg on Linux (or macOS) without hdiutil.
#
# The result is an ISO 9660 image with Rock Ridge (POSIX permissions, long names, symlinks) and
# Joliet extensions. It is NOT a UDIF (.dmg) container; macOS opens it anyway on double-click
# (DiskImageMounter detects the ISO format by content, not by extension). An identical .iso copy
# is written too, for tools that insist on the extension.
#
# Layout of the mounted volume "Fitzrovia Records DAW Installer":
#   Install Fitzrovia Records DAW.command   double-click to build + install (asks before installing tools)
#   START HERE.txt
#   Fitzrovia Records DAW/                  full source tree (Swift package)
#
# Usage: packaging/build_source_image.sh [output-dir]   (default: dist/)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/dist}"
VERSION="$(python3 -c "import plistlib;print(plistlib.load(open('$ROOT/Resources/Info.plist','rb'))['CFBundleShortVersionString'])")"
NAME="FitzroviaRecordsDAW-Source-Installer"
TOOL=""
if command -v xorriso >/dev/null 2>&1; then TOOL="xorriso -as mkisofs"
elif command -v genisoimage >/dev/null 2>&1; then TOOL="genisoimage"
elif command -v mkisofs >/dev/null 2>&1; then TOOL="mkisofs"
else echo "error: install xorriso or genisoimage (apt-get install xorriso)" >&2; exit 1; fi

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/sf-srcimg.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
VOL="$STAGE/vol"
mkdir -p "$VOL/StudioForge" "$OUT"

rsync -a --exclude /.build --exclude /build --exclude /dist --exclude /.git --exclude /.swiftpm \
  --exclude .DS_Store --exclude /.abacus.donotdelete "$ROOT/" "$VOL/StudioForge/"
cp "$ROOT/packaging/Install Fitzrovia Records DAW.command" "$VOL/Install Fitzrovia Records DAW.command"
chmod 755 "$VOL/Install Fitzrovia Records DAW.command" "$VOL/StudioForge/build.sh" "$VOL/StudioForge/packaging/"*.sh
cat > "$VOL/START HERE.txt" <<EOF
Fitzrovia Records DAW $VERSION - source installer
=======================================

Opening this disk image does not install anything by itself: macOS never runs anything
automatically from a disk image. Do the following:

STEP 1 - start the installer
  Double-click "Install Fitzrovia Records DAW.command". macOS blocks it the first time
  because it is an unsigned script from the internet. Click Done, then open
  System Settings > Privacy & Security, click "Open Anyway" and enter your password.
  (macOS 13-14 only: Control-click > Open also works. macOS 15 Sequoia and later removed that.)
  Or in Terminal:  bash "/Volumes/<this disk>/Install Fitzrovia Records DAW.command"

STEP 2 - what happens next (a Terminal window shows progress)
  1. It checks for the Xcode Command Line Tools. If they are missing it offers to install
     them (free, about 1-2 GB, from Apple). When they have finished, repeat step 1.
  2. It builds Fitzrovia Records DAW from the source on this disk image (a few minutes the first time).
  3. It installs Fitzrovia Records DAW.app into /Applications, asking for your password if needed
     (or uses ~/Applications if you decline).
  4. It creates your library in Music/Fitzrovia Records DAW (Projects, Recordings, Exports, Presets,
     ImpulseResponses, Models, Samples), removes the quarantine flag and registers the app
     so .sfproj projects open with a double-click.
  5. It opens Fitzrovia Records DAW. On first launch Fitzrovia Records DAW explains why it needs the
     microphone, then macOS asks you: click OK. (No installer can grant this in advance.)

STILL BLOCKED?
  Copy "Install Fitzrovia Records DAW.command" to your Desktop, open Terminal and run:
      xattr -dr com.apple.quarantine ~/Desktop/"Install Fitzrovia Records DAW.command"
      ~/Desktop/"Install Fitzrovia Records DAW.command"
  (Run it from the Desktop copy only if this disk image is still mounted; it finds the
  source next to itself or in /Volumes/StudioForge Installer.)
  Or: System Settings > Privacy & Security > "Open Anyway".

REQUIREMENTS
  macOS 13 Ventura or later, the Xcode Command Line Tools (the installer offers them),
  about 3 GB of free space for the build.

EASIER OPTION
  A prebuilt "Install Fitzrovia Records DAW.pkg" (a normal macOS installer you double-click) is made
  by packaging/make_pkg.sh on a Mac, or by the GitHub Actions workflow
  (see Fitzrovia Records DAW/README.md > Install).
EOF

# -r: Rock Ridge with sane permissions (keeps execute bits), -J/-joliet-long: Windows names,
# -V: volume name shown in Finder, -iso-level 3: large files.
$TOOL -quiet -iso-level 3 -r -J -joliet-long -V "Fitzrovia Records DAW Installer" -A "Fitzrovia Records DAW $VERSION" \
  -o "$OUT/$NAME.dmg" "$VOL"
cp "$OUT/$NAME.dmg" "$OUT/$NAME.iso"
( cd "$OUT" && sha256sum "$NAME.dmg" > "$NAME.dmg.sha256" 2>/dev/null || shasum -a 256 "$NAME.dmg" > "$NAME.dmg.sha256" )
echo "Wrote $OUT/$NAME.dmg (ISO 9660 + Rock Ridge + Joliet) and $NAME.iso"
