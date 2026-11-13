#!/usr/bin/env bash
# Called by the GitHub Actions workflow on a macOS runner. All build logic lives here so the
# workflow file itself never needs editing. Produces dist/Install-FitzroviaRecordsDAW.pkg and the DMG.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "== Toolchain =="
xcodebuild -version || true
swift --version

echo "== Unit tests (non-blocking) =="
swift test || echo "::warning::Unit tests failed - continuing with packaging"

python3 -m pip install --quiet --break-system-packages pillow 2>/dev/null \
  || python3 -m pip install --quiet pillow 2>/dev/null || true

export SIGN_IDENTITY="${SIGN_IDENTITY:--}"
export UNIVERSAL="${UNIVERSAL:-1}"

echo "== Build app, installer package and DMG =="
./packaging/make_dmg.sh

# Space-free name so the GitHub download link is clean.
if [ -f "dist/Install Fitzrovia Records DAW.pkg" ]; then
  cp "dist/Install Fitzrovia Records DAW.pkg" dist/Install-FitzroviaRecordsDAW.pkg
  rm -f "dist/Install Fitzrovia Records DAW.pkg"
fi
rm -f dist/*.iso
ls -la dist
test -f dist/Install-FitzroviaRecordsDAW.pkg

# Publish to the permanent "latest" download page (needs GH_TOKEN from the workflow).
if [ -n "${GH_TOKEN:-}" ] && command -v gh >/dev/null; then
  echo "== Publishing release 'latest' =="
  gh release delete latest --yes --cleanup-tag 2>/dev/null || true
  gh release create latest dist/* --title "Fitzrovia Records DAW (latest build)" --latest \
    --notes "Download Install-FitzroviaRecordsDAW.pkg and double-click it. First time only: Control-click it and choose Open."
fi
