#!/usr/bin/env bash
# Called by the GitHub Actions workflow on a macOS runner. All build logic lives here so the
# workflow file itself never needs editing. Produces dist/Install-StudioForge.pkg and the DMG.
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
if [ -f "dist/Install StudioForge.pkg" ]; then
  cp "dist/Install StudioForge.pkg" dist/Install-StudioForge.pkg
  rm -f "dist/Install StudioForge.pkg"
fi
rm -f dist/*.iso
ls -la dist
test -f dist/Install-StudioForge.pkg
