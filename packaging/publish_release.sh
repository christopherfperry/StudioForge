#!/usr/bin/env bash
# Replaces the GitHub release "latest" with the files in dist/ (needs GH_TOKEN and the gh CLI).
set -euo pipefail
cd "$(dirname "$0")/.."
if [ -z "${GH_TOKEN:-}" ] || ! command -v gh >/dev/null; then
  echo "GH_TOKEN or gh not available - not publishing"; exit 0
fi
VERSION="$(python3 -c "import plistlib;print(plistlib.load(open('Resources/Info.plist','rb'))['CFBundleShortVersionString'])")"
# Versions that passed packaging/smoke_test.sh (result-macOS-<version>-<arch>.txt containing PASS).
TESTED="$(grep -l '^PASS' smoke/result-*.txt 2>/dev/null | sed -E 's#.*/result-(.*)\.txt#\1#' | sort -rV | paste -sd ',' - | sed 's/,/, /g' || true)"
TESTED="${TESTED:-the build runner}"
NOTES="$(cat <<TXT
Fitzrovia Records DAW $VERSION. Install and launch were tested automatically on: $TESTED.

**Easiest install (no security prompts):** open Terminal and paste:

    curl -L -o /tmp/FitzroviaRecordsDAW.pkg https://github.com/${GITHUB_REPOSITORY:-christopherfperry/StudioForge}/releases/download/latest/Install-FitzroviaRecordsDAW.pkg && sudo installer -pkg /tmp/FitzroviaRecordsDAW.pkg -target /

**Or download Install-FitzroviaRecordsDAW.pkg and double-click it.** The build is not notarised by Apple, so on macOS 15 Sequoia, 26 Tahoe and 27 the first double-click is blocked ("Apple could not verify..."). Click **Done**, open **System Settings > Privacy & Security**, scroll down, click **Open Anyway** next to the installer, enter your password, then **Open**. (Control-click > Open no longer works on these versions.) The app installed by the package opens normally afterwards.
TXT
)"
echo "== Publishing release 'latest' =="
gh release delete latest --yes --cleanup-tag 2>/dev/null || true
gh release create latest dist/* --title "Fitzrovia Records DAW $VERSION (latest build)" --latest --notes "$NOTES"
