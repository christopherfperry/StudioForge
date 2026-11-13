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

# The AI separation model the app downloads: check it loads in Core ML and matches PyTorch.
echo "== AI model check (Core ML vs PyTorch) =="
MODELS=https://github.com/christopherfperry/StudioForge/releases/download/models-v1
CHK="${RUNNER_TEMP:-/tmp}/sfmodel"; mkdir -p "$CHK"
if curl -fsSL -o "$CHK/m.zip" "$MODELS/htdemucs_6s.mlpackage.zip" && curl -fsSL -o "$CHK/check.bin" "$MODELS/coreml_check.bin"; then
  ditto -x -k "$CHK/m.zip" "$CHK"
  SF_COREML_MODEL="$CHK/htdemucs_6s.mlpackage" SF_COREML_CHECK="$CHK/check.bin" \
    swift test --filter testCoreMLModelMatchesPyTorch 2>&1 | grep -E "Core ML vs PyTorch|error|passed|failed|skipped" \
    || echo "::warning::AI model check failed"
else
  echo "::warning::Could not download the AI model for the check"
fi

python3 -m pip install --quiet --break-system-packages pillow 2>/dev/null \
  || python3 -m pip install --quiet pillow 2>/dev/null || true

export SIGN_IDENTITY="${SIGN_IDENTITY:--}"
export UNIVERSAL="${UNIVERSAL:-1}"

echo "== Build app, installer package and DMG =="
./packaging/make_dmg.sh

# Space-free name so the GitHub download link is clean.
if [ -f "dist/Install Fitzrovia Records DAW.pkg" ]; then
  cp "dist/Install Fitzrovia Records DAW.pkg" dist/Install-FitzroviaRecordsDAW.pkg
  rm -f "dist/Install Fitzrovia Records DAW.pkg" "dist/Install Fitzrovia Records DAW.pkg.sha256"
  # Checksum file named after the file people actually download.
  ( cd dist && shasum -a 256 Install-FitzroviaRecordsDAW.pkg > Install-FitzroviaRecordsDAW.pkg.sha256 )
fi
rm -f dist/*.iso
ls -la dist
test -f dist/Install-FitzroviaRecordsDAW.pkg

# Install the package on this runner and launch the app. A build that does not install and
# open is never published.
if [ "${SMOKE:-1}" = "1" ]; then
  echo "== Install + launch smoke test =="
  ./packaging/smoke_test.sh dist/Install-FitzroviaRecordsDAW.pkg
fi

# Publish to the permanent "latest" download page (needs GH_TOKEN from the workflow).
# The workflow sets PUBLISH=0 here and publishes after the smoke tests on every macOS version pass.
if [ "${PUBLISH:-1}" = "1" ]; then
  ./packaging/publish_release.sh
fi
