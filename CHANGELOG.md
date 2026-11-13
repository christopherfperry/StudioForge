# Changelog

## 0.6.2 — 2026-11-13
- **Fixed: single-key shortcuts fired while typing.** Space, R, L, K, N, X and S no longer trigger transport and editing actions while you type in a text field (for example when renaming a track). They are now ignored whenever a text field, sheet or dialog has focus. ⌘⌫ in a text field now edits the text instead of deleting the track.
- **Fixed: a stale "Arm at least one audio track" error came back on every Stop.** Errors are now cleared when you start recording or stop.
- **Unsaved changes are protected:** New, Open and Quit ask *Save / Don't Save / Cancel* when the song has unsaved changes.
- Recording: the R button toggles recording on and off, and shows a filled icon while recording. If microphone access was denied, the app says so instead of recording silence. After stopping, the status shows how many takes were recorded (⌘Z to undo).
- Undo/Redo: menu items show what will be undone (for example "Undo Rename Track"). A track rename is now one undo step, not one per keystroke. "Nothing to undo" feedback was added.
- The toolbar *Split* (cut at playhead) is renamed **Cut at Playhead** so it is not confused with stem *Split*. It now reports when there is no clip under the playhead.
- Stem split: the "Added N stem tracks" message is no longer replaced by a Finder window. The Mixer visibility is remembered between launches. The Recent menu shows "No recent projects" when empty. Errors from *Save Current as Template* are shown. Onboarding has a new *Mix & tidy up* page.
- Installer: the welcome, read-me and finish pages have been rewritten for 0.6.x (features, shortcuts, microphone permission, Gatekeeper, uninstall), and the version is filled in automatically. Fixed the `.command` installer's quit-running-app step (`pkill -x StudioForge`).
- 7 new tests (49 total on Linux): record/stop error clearing, delete/undo/redo, live vs offline mute/solo gain parity, project save/load round-trip, export with mute, and a synth part for every genre.

## 0.6.1 — 2026-11-13
- **Fixed: mute (and solo / arm) buttons often did nothing.** Only the letter inside the button took clicks; clicks on the rest of the coloured box fell through to the header and only selected the track. The whole box is now clickable, in the track headers and the mixer. Toggles read the current project state.
- **Muted tracks are now visible:** muted tracks, and tracks silenced by another track's solo, are dimmed and labelled *MUTED* / *SOLO-OFF*. Muted clips are dimmed and struck through.
- New: right-click *Mute / Solo / Clear All Mute & Solo* on tracks; Edit › *Mute / Unmute Selected Track* (⌃⌘M), *Solo / Unsolo Selected Track* (⌃⌘S), *Clear All Mute & Solo*; *Mute Clip* for MIDI clips.
- **Fixed: exports leaked tracks silenced by solo** (and briefly ignored pan) for the first ~20 ms of a master bounce. Live playback and export now share one gain calculation.
- Fixed: the installer checksum file is now named `Install-FitzroviaRecordsDAW.pkg.sha256`, matching the download.
- 3 new tests (42 total on Linux).

## 0.6.0 — 2026-11-13
- **Delete tracks and stems:** trash button in every track header and mixer strip, right-click *Delete Track / Delete Stem*, ⌘⌫ for the selected track, *Delete All Stems From This Split*, and Edit › Delete All Stems. Undoable. Stem tracks are tagged (saved in the project; older projects load unchanged).
- **Easier volume:** per-track volume slider and dB readout in each header; redesigned mixer faders with 0 dB mark, double-click reset and mute/solo; *Volume & pan* box at the top of the inspector with −/+ 1 dB and 0 dB buttons; right-click *Volume* presets; ⌥⌘↑/↓ shortcuts; fader drags are a single undo step. The mixer button is now labelled *Mixer*.
- **Genre-matched synth tones:** new Genre setting (Auto-detect + 10 genres) in the split sheet, File menu and clip menu. Each genre has its own register, voicing, rhythm and synth timbre; Auto-detect uses rule-based audio features.
- 6 new unit tests (39 total on Linux).

## 0.5.0 — 2026-11-13
- **High-quality splitting:** new *Quality* setting (Standard / High). High adds a second HPSS pass, stereo-coherence vocal detection, pitch-aware bass (fundamental and harmonics), Wiener mask refinement and short-window drum clean-up. The engine is still DSP: converting Demucs to Core ML failed (rank-6 tensors, dynamic casts), so the Core ML import remains optional.
- **Reduce artefacts** toggle and strength: time–frequency mask smoothing, soft mask floor, spectral gating of faint residue, transient preservation and high-frequency smoothing. Remembered between launches.
- **Generate matching synth track** from guitar and bass: chord detection (chroma + triad templates), YIN bass tracking, key detection, grid quantisation. Styles: Pad, Bass synth, Arpeggio. Available in the split sheet, the clip context menu and the File menu.
- 7 new unit tests (33 total on Linux).

## 0.4.0 — 2026-11-13
- **Show Playing Notes** (transport **Notes** toggle, key **N**, or **View › Show Playing Notes** ⌥⌘N; remembered between launches). While the song plays, every track shows the note it is sounding: a badge in the track header and a tag riding next to the playhead. Instrument tracks show chords (e.g. `C4 E4 G4`); drum tracks show the drum names (`Kick + Closed Hat`); audio tracks (recordings, imports, split stems) use a background pitch tracker (YIN), so they show one note at a time and work best on single-note parts such as vocals, bass and lead lines. Muted clips and muted/un-soloed tracks show nothing.
- **Latest macOS:** every CI build is now installed and launched automatically (`packaging/smoke_test.sh`: installer, code signature, architecture, launch, crash-report check, DMG mount) and is only published if that passes. `packaging/release-workflow-macos27.yml` extends this to build with Xcode 27 on macOS 27 and test on macOS 26 and 15 (it must be copied into `.github/workflows/` by the repo owner).
- Install instructions updated for macOS 15+, which removed Control-click › Open for unnotarized software: use **System Settings › Privacy & Security › Open Anyway**, or the new one-line Terminal install (no prompts).
- 4 new unit tests (26 total on Linux).

## 0.3.0 — 2026-11-13
- **Renamed to Fitzrovia Records DAW**: app bundle `Fitzrovia Records DAW.app`, installer `Install-FitzroviaRecordsDAW.pkg`, disk image `FitzroviaRecordsDAW-<version>.dmg`, window title, menus and docs. The bundle id (`com.studioforge.daw`) and project extensions (`.sfproj`/`.sforge`) are unchanged, so existing projects and settings keep working. `~/Music/StudioForge` and `~/Library/Application Support/StudioForge` are moved to the new names automatically (by the installer, and again on first launch). The installer removes the old `/Applications/StudioForge.app`.
- **Import & Split Audio** (⇧⌘I / toolbar **Split**): split a file or the selected clip into vocals, drums, bass, guitar, piano/keys and other. Drum types: kick, snare, toms, hi-hat and cymbals, each selectable. Presets: Vocals + 3, Everything, Drums only. Stems are added as aligned tracks in one undo step and can mute the source. Cancel works safely mid-run.
- DSP separator: guitar, piano/keys and other now each get their own content. Before, piano was never produced, and "other" came out silent whenever guitar was requested.
- Drum-part splitter: hi-hats were classified as cymbals (the sustain measure was ~1 at every new hit). Toms no longer pick up the kick.
- Stem files never overwrite an earlier split of the same song.
- Fix: Save As left audio behind in the old project, so every clip in the new copy broke. Audio is now copied into the new package (shared files once). Added **File › Save As…** (⇧⌘S).
- Fix: importing files that were already inside the project copied them again. Multi-file imports are now one undo step.
- Fix: track controls (mute, volume, etc.) could edit the wrong track after tracks were added, removed or reordered (a binding captured the array index).
- Fix: importing a separation model froze the UI (it ran on the main thread).
- Fix: possible crash when the separate input device failed to open (force-unwrapped input unit).
- 5 new unit tests (22 total on Linux).

## 0.2.1 — 2026-11-10
- Fix: opening the source disk image installed nothing. macOS never auto-runs anything from a disk image, and Gatekeeper blocks a plain double-click on the unsigned `.command`.
- New `packaging/make_pkg.sh`: builds a double-click macOS Installer package `Install StudioForge.pkg` with pkgbuild + productbuild. It installs StudioForge.app into /Applications (not relocatable) and requires macOS 13+. It has welcome, readme and conclusion pages that explain the first-launch microphone prompt; macOS does not let any installer grant microphone access in advance.
- `packaging/pkg/scripts/postinstall` does the following for the logged-in console user:
  - creates `~/Music/StudioForge/{Projects,Recordings,Exports,Presets/User,Presets/Factory,ImpulseResponses,Models,Samples}` and `~/Library/Application Support/StudioForge`, owned by that user;
  - copies the bundled presets;
  - removes quarantine;
  - registers the app with LaunchServices.
  It never fails the installation.
- Optional `INSTALLER_IDENTITY` (Developer ID Installer) runs `productsign`; `NOTARIZE=1` notarizes and staples the package.
- `make_dmg.sh` now builds the package and puts `Install StudioForge.pkg` in the DMG as the main item (top centre, highlighted in the background). The drag-to-Applications row stays below it. The window is now 640×480.
- GitHub Actions builds and uploads both the `.pkg` and the DMG (artifact `StudioForge-installers`, and Release assets on `v*` tags). New optional secret: `MACOS_INSTALLER_IDENTITY`.
- Source image: the root note is replaced by `START HERE.txt` (Control-click › Open › Open, what the installer does, `xattr -dr com.apple.quarantine` fallback, requirements). The `.command` also finds the source when run from a Desktop copy.


## 0.2.0 — 2026-11-10
- Installer packaging: `packaging/make_dmg.sh` builds a universal Release app, signs it (ad hoc, or Developer ID + notarization through environment variables) and creates a DMG with background, arrow, volume icon and Finder layout (create-dmg or hdiutil + AppleScript).
- `packaging/Install StudioForge.command` plus `packaging/build_source_image.sh`: double-click source installer (checks the Command Line Tools, builds, installs to /Applications, clears quarantine, creates folders, launches the app).
- GitHub Actions `release.yml` (macos-14): runs tests, builds the DMG, uploads it as an artifact and attaches it to a GitHub Release on `v*` tags.
- First-launch setup: `~/Music/StudioForge/...` library plus Application Support; factory presets copied to `Presets/Factory`; welcome screen that explains and then requests microphone access; Help › Setup & Permissions screen.
- Default locations: projects go to `Projects`, unsaved recordings to `Recordings`, models to `Models`, IRs to `ImpulseResponses`, user presets to `Presets/User`.
- Project extension is now `.sfproj` with an exported UTI `com.studioforge.project`; `.sforge` still opens. Double-clicking a project in Finder opens it.
- Info.plist: app icon, folder usage strings, document type and UTI. Entitlements: audio input, user-selected files, Music folder, network client, Bluetooth.
- Fix: SwiftPM resource bundles are now found inside Contents/Resources of a distributed .app; before, `Bundle.module` would have crashed outside the build machine.
- App icon and DMG artwork generated by `packaging/make_art.py`.
- 18 unit tests (new: first-run setup).


## 0.1.0 — 2026-11-10
- First version: modular Swift package (SFCore, SFEffects, SFInstruments, SFPresets, SFBeatGen, SFSeparation, SFProject, SFEngine, SFExport, SFUI, app).
- Real-time engine: recording (always dry, optional wet), loop, punch, metronome, latency compensation, CoreAudio AUHAL I/O, CoreMIDI.
- 33 effects (including 11 reverb types and convolution with user IRs), 5 instruments, 111 JSON presets, Tone Picker.
- Beat generator with 27 styles, match-to-recording and MIDI export.
- Stem separation: Core ML Demucs htdemucs_6s with model manager; DSP fallback; drum-part splitter.
- Export: WAV, AIFF, FLAC, AAC, ALAC, CAF; MP3 and OGG via ffmpeg; stems, MIDI, dither, normalize.
- 17 unit tests (pass on Linux with Swift 5.10.1).
- Known gaps: macOS code not yet compiled; AU/AUv3 insert hosting not implemented; no piano roll or automation.
