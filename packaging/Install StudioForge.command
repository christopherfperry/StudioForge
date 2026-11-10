#!/usr/bin/env bash
# First time: Control-click > Open > Open (macOS blocks unsigned downloaded scripts on a plain double-click).
# Double-click in Finder to build and install StudioForge from source.
# Works from the source disk image (read-only) or an unzipped source folder.
#
#   DRY_RUN=1         print what would happen, change nothing (also works on Linux)
#   ASSUME_YES=1      do not ask questions (CI / scripted use)
#   INSTALL_DIR=...   default /Applications (falls back to ~/Applications if not writable)
#   NO_LAUNCH=1       do not open the app at the end
set -euo pipefail

DRY_RUN="${DRY_RUN:-0}"
ASSUME_YES="${ASSUME_YES:-0}"
HERE="$(cd "$(dirname "$0")" && pwd)"
LOG="${TMPDIR:-/tmp}/StudioForge-install.log"

say()  { printf '\n\033[1;35m==>\033[0m %s\n' "$*"; }
run()  { echo "+ $*"; if [[ "$DRY_RUN" != "1" ]]; then "$@"; fi; }
fail() { printf '\n\033[1;31mInstallation failed:\033[0m %s\nLog: %s\n' "$*" "$LOG"; pause_exit 1; }
pause_exit() {
  if [[ "$ASSUME_YES" != "1" && -t 0 ]]; then read -r -p "Press Return to close this window. " _ || true; fi
  exit "$1"
}
confirm() {
  [[ "$ASSUME_YES" == "1" || "$DRY_RUN" == "1" ]] && return 0
  local reply; read -r -p "$1 [Y/n] " reply || reply=""
  [[ -z "$reply" || "$reply" =~ ^[Yy] ]]
}

# Locate the source tree: next to this script, or in a "StudioForge" / "mac_daw" subfolder.
find_source() {
  local c
  for c in "$HERE" "$HERE/StudioForge" "$HERE/mac_daw" "$HERE/.." "/Volumes/StudioForge Installer/StudioForge"; do
    if [[ -f "$c/Package.swift" && -f "$c/build.sh" ]]; then (cd "$c" && pwd); return 0; fi
  done
  return 1
}

library_folders=(Projects Recordings Exports "Presets/User" "Presets/Factory" ImpulseResponses Models Samples)

main() {
  echo "StudioForge installer — builds the app from source on this Mac."
  echo "Log file: $LOG"

  local src; src="$(find_source)" || fail "could not find Package.swift next to this script."
  say "Source: $src"

  if [[ "$(uname)" != "Darwin" ]]; then
    [[ "$DRY_RUN" == "1" ]] || fail "this installer runs on macOS only (use DRY_RUN=1 to preview)."
    echo "(Not macOS: dry run only.)"
  else
    local major; major="$(sw_vers -productVersion | cut -d. -f1)"
    (( major >= 13 )) || fail "StudioForge needs macOS 13 Ventura or later (found $(sw_vers -productVersion))."
  fi

  # 1. Xcode command line tools / Swift
  say "Checking for Xcode Command Line Tools"
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "+ xcode-select -p && swift --version"
  elif ! xcode-select -p >/dev/null 2>&1 || ! xcrun --find swift >/dev/null 2>&1; then
    echo "The Xcode Command Line Tools (free, about 1–2 GB) are required to build StudioForge."
    if confirm "Install them now?"; then
      xcode-select --install || true
      echo "Follow the dialog that just opened. When the installation has finished, double-click this installer again."
      pause_exit 0
    else
      fail "Command Line Tools are required. Install with: xcode-select --install"
    fi
  fi
  if [[ "$DRY_RUN" != "1" ]]; then
    local swiftver; swiftver="$(xcrun swift --version 2>/dev/null | head -1)"
    echo "$swiftver"
    [[ "$swiftver" =~ Swift\ version\ (5\.(9|[1-9][0-9])|[6-9]\.) ]] || fail "Swift 5.9 or later required (Xcode 15+). Update the Command Line Tools in Software Update."
  fi

  # 2. Build in a writable copy (the disk image is read-only)
  local work="$HOME/Library/Caches/StudioForge/source"
  say "Building StudioForge (first build takes a few minutes)"
  run mkdir -p "$work"
  run rsync -a --delete --exclude /.build --exclude /build --exclude /dist --exclude /.git "$src/" "$work/"
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "+ (cd $work && CONFIG=release ./build.sh)"
  else
    (cd "$work" && CONFIG=release ./build.sh) 2>&1 | tee "$LOG" || fail "build failed (see log)."
    [[ "${PIPESTATUS[0]}" == "0" && -d "$work/build/StudioForge.app" ]] || fail "build failed (see log)."
  fi

  # 3. Install
  local dest="${INSTALL_DIR:-/Applications}"
  if [[ "$DRY_RUN" != "1" && ! -w "$dest" ]]; then
    echo "$dest is not writable by your account."
    if confirm "Use your administrator password to install into $dest?"; then
      SUDO="sudo"
    else
      dest="$HOME/Applications"; SUDO=""
    fi
  else
    SUDO=""
  fi
  say "Installing to $dest/StudioForge.app"
  if [[ "$DRY_RUN" != "1" ]]; then
    pkill -x StudioForge 2>/dev/null || true
    mkdir -p "$dest" 2>/dev/null || $SUDO mkdir -p "$dest"
  fi
  run ${SUDO:+$SUDO} rm -rf "$dest/StudioForge.app"
  run ${SUDO:+$SUDO} ditto "$work/build/StudioForge.app" "$dest/StudioForge.app"
  # Built locally, so normally not quarantined — clear it anyway (e.g. source copied from a download).
  run ${SUDO:+$SUDO} xattr -dr com.apple.quarantine "$dest/StudioForge.app" || true
  # Register the app so .sfproj projects open with StudioForge on double-click.
  local lsreg="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
  if [[ -x "$lsreg" || "$DRY_RUN" == "1" ]]; then run "$lsreg" -f "$dest/StudioForge.app" || true; fi

  # 4. Library folders (the app also creates these on first launch)
  say "Creating your library in ~/Music/StudioForge"
  local f
  for f in "${library_folders[@]}"; do run mkdir -p "$HOME/Music/StudioForge/$f"; done
  run mkdir -p "$HOME/Library/Application Support/StudioForge"

  # 5. Launch
  say "StudioForge is installed."
  echo "On first launch StudioForge explains and then asks for microphone / audio-input access."
  echo "You can review permissions any time under Help > Setup & Permissions."
  if [[ "${NO_LAUNCH:-0}" != "1" ]]; then run open "$dest/StudioForge.app"; fi
  pause_exit 0
}

main "$@"
