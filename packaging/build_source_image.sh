#!/usr/bin/env bash
# Builds StudioForge-Source-Installer.dmg on Linux (or macOS) without hdiutil.
#
# The result is an ISO 9660 image with Rock Ridge (POSIX permissions, long names, symlinks) and
# Joliet extensions. It is NOT a UDIF (.dmg) container; macOS opens it anyway on double-click
# (DiskImageMounter detects the ISO format by content, not by extension). An identical .iso copy
# is written too, for tools that insist on the extension.
#
# Layout of the mounted volume "StudioForge Installer":
#   Install StudioForge.command   double-click to build + install (asks before installing tools)
#   START HERE.txt
#   StudioForge/                  full source tree (Swift package)
#
# Usage: packaging/build_source_image.sh [output-dir]   (default: dist/)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/dist}"
VERSION="$(python3 -c "import plistlib;print(plistlib.load(open('$ROOT/Resources/Info.plist','rb'))['CFBundleShortVersionString'])")"
NAME="StudioForge-Source-Installer"
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
cp "$ROOT/packaging/Install StudioForge.command" "$VOL/Install StudioForge.command"
chmod 755 "$VOL/Install StudioForge.command" "$VOL/StudioForge/build.sh" "$VOL/StudioForge/packaging/"*.sh
cat > "$VOL/START HERE.txt" <<EOF
StudioForge $VERSION - source installer
=======================================

Opening this disk image does not install anything by itself: macOS never runs anything
automatically from a disk image. Do the following:

STEP 1 - start the installer
  Control-click (or right-click) "Install StudioForge.command" and choose Open,
  then click Open again in the dialog.
  (A plain double-click is blocked because macOS refuses unsigned scripts that came from
  the internet. Control-click > Open is the supported way to allow it once.)

STEP 2 - what happens next (a Terminal window shows progress)
  1. It checks for the Xcode Command Line Tools. If they are missing it offers to install
     them (free, about 1-2 GB, from Apple). When they have finished, repeat step 1.
  2. It builds StudioForge from the source on this disk image (a few minutes the first time).
  3. It installs StudioForge.app into /Applications, asking for your password if needed
     (or uses ~/Applications if you decline).
  4. It creates your library in Music/StudioForge (Projects, Recordings, Exports, Presets,
     ImpulseResponses, Models, Samples), removes the quarantine flag and registers the app
     so .sfproj projects open with a double-click.
  5. It opens StudioForge. On first launch StudioForge explains why it needs the
     microphone, then macOS asks you: click OK. (No installer can grant this in advance.)

STILL BLOCKED?
  Copy "Install StudioForge.command" to your Desktop, open Terminal and run:
      xattr -dr com.apple.quarantine ~/Desktop/"Install StudioForge.command"
      ~/Desktop/"Install StudioForge.command"
  (Run it from the Desktop copy only if this disk image is still mounted; it finds the
  source next to itself or in /Volumes/StudioForge Installer.)
  Or: System Settings > Privacy & Security > "Open Anyway".

REQUIREMENTS
  macOS 13 Ventura or later, the Xcode Command Line Tools (the installer offers them),
  about 3 GB of free space for the build.

EASIER OPTION
  A prebuilt "Install StudioForge.pkg" (a normal macOS installer you double-click) is made
  by packaging/make_pkg.sh on a Mac, or by the GitHub Actions workflow
  (see StudioForge/README.md > Install).
EOF

# -r: Rock Ridge with sane permissions (keeps execute bits), -J/-joliet-long: Windows names,
# -V: volume name shown in Finder, -iso-level 3: large files.
$TOOL -quiet -iso-level 3 -r -J -joliet-long -V "StudioForge Installer" -A "StudioForge $VERSION" \
  -o "$OUT/$NAME.dmg" "$VOL"
cp "$OUT/$NAME.dmg" "$OUT/$NAME.iso"
( cd "$OUT" && sha256sum "$NAME.dmg" > "$NAME.dmg.sha256" 2>/dev/null || shasum -a 256 "$NAME.dmg" > "$NAME.dmg.sha256" )
echo "Wrote $OUT/$NAME.dmg (ISO 9660 + Rock Ridge + Joliet) and $NAME.iso"
