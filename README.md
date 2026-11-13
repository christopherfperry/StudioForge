# Fitzrovia Records DAW

A personal multi-track DAW for macOS 13 Ventura through macOS 27 (the latest release) (SwiftUI + CoreAudio). It records audio and instruments with low latency, includes its own effects and instruments, ships JSON presets (with artist-style tones), generates drum beats, separates stems, and exports to common audio formats.

> **Honesty note.** This source was written on a Linux machine. It was **not compiled or run on macOS**. The platform-independent modules build with Swift 5.10.1 on Linux, and 26 unit tests pass there: DSP, effects, instruments, presets, beat generator, analysis, HPSS separation, projects, offline render and export. Everything that needs Apple frameworks sits behind `#if os(macOS)` and has **never been compiled**: CoreAudio I/O, CoreMIDI, the SwiftUI UI, Core ML separation, and the AVFoundation encoders and decoders. Expect a few compile fixes on the first Xcode build. See *Known gaps* below.

## Install

Opening a disk image never installs anything by itself, because macOS does not auto-run software from a DMG. Use one of the following (macOS 13 Ventura or later, including macOS 27).

### Quickest: one Terminal command (no security prompts)
```bash
curl -L -o /tmp/FitzroviaRecordsDAW.pkg https://github.com/christopherfperry/StudioForge/releases/download/latest/Install-FitzroviaRecordsDAW.pkg && sudo installer -pkg /tmp/FitzroviaRecordsDAW.pkg -target /
```
Files downloaded with `curl` are not quarantined, so Gatekeeper does not block them. Then open **Fitzrovia Records DAW** from Applications or Launchpad.

### Tested on every build
After building, CI runs `packaging/smoke_test.sh`: it installs the package with `installer`, verifies the code signature and architecture, launches the app and checks it stays running with no crash report. The release is published only if it passes, and the release notes list the macOS version tested. The current workflow runs on `macos-latest` (macOS 26 Tahoe).

To also build with Xcode 27 on **macOS 27** and smoke-test on **macOS 26** and **macOS 15**, replace `.github/workflows/release.yml` with `packaging/release-workflow-macos27.yml` (GitHub web editor › paste › commit). The automation account cannot change workflow files, so this step has to be done by you.

### Recommended: `Install Fitzrovia Records DAW.pkg`
A normal macOS Installer package: double-click it and click through.
- It installs Fitzrovia Records DAW.app into /Applications.
- It creates `~/Music/Fitzrovia Records DAW/...` and `~/Library/Application Support/Fitzrovia Records DAW` for the logged-in user.
- It copies the factory presets, removes quarantine and registers the app with LaunchServices.
- Its last page explains the microphone prompt that appears on first launch. No installer can grant microphone access in advance.

To get the package:
- **GitHub Actions** (no Xcode needed): push the repository and download the **Fitzrovia Records DAW-installers** artifact from the Actions tab (section A below). It contains `Install Fitzrovia Records DAW.pkg` and `FitzroviaRecordsDAW-<version>.dmg`.
- **On a Mac:** run `./packaging/make_pkg.sh`, which writes `dist/Install Fitzrovia Records DAW.pkg`. `./packaging/make_dmg.sh` builds the package as well and puts it in the DMG.
- **Signing:** set `INSTALLER_IDENTITY="Developer ID Installer: Name (TEAMID)"` to sign the package with `productsign`. Add `NOTARIZE=1` plus `NOTARY_PROFILE` (or `APPLE_ID`/`APPLE_TEAM_ID`/`APPLE_APP_PASSWORD`) to notarize it.
- **Unsigned package (macOS 15 and later):** the first double-click is blocked. Click **Done**, then **System Settings › Privacy & Security › Open Anyway** (see *Gatekeeper* below). On macOS 13–14, Control-click › **Open** also works.

The DMG shows **Install Fitzrovia Records DAW.pkg** as the main item at the top. Below it is the alternative: drag Fitzrovia Records DAW onto Applications.

### A. Prebuilt DMG from GitHub Actions (no Xcode on your Mac)
1. Every push runs `.github/workflows/release.yml` (`packaging/ci_build.sh`): it runs the tests, builds a universal (arm64 + x86_64) app, `Install-FitzroviaRecordsDAW.pkg` and `FitzroviaRecordsDAW-<version>.dmg`, then smoke-tests install + launch.
2. If the smoke test passes, the files replace the release **latest** (Releases page).
3. Double-click the DMG and drag **Fitzrovia Records DAW** onto **Applications**.
4. Optional: add the secrets `MACOS_INSTALLER_IDENTITY`, `MACOS_CERT_P12_BASE64`, `MACOS_CERT_PASSWORD`, `MACOS_SIGN_IDENTITY`, `APPLE_ID`, `APPLE_TEAM_ID` and `APPLE_APP_PASSWORD` to get a Developer ID signed, notarized DMG. Without them the DMG is ad-hoc signed.

### B. Build the DMG yourself
```bash
./packaging/make_dmg.sh            # -> dist/Install Fitzrovia Records DAW.pkg + dist/FitzroviaRecordsDAW-0.6.0.dmg
```
The script builds the Release app (universal when full Xcode is installed, otherwise your Mac's architecture), signs it ad hoc with the entitlements, and creates a compressed DMG. The DMG contains the app, an Applications shortcut, a background image with an arrow, a volume icon and an arranged Finder window. It uses `create-dmg` if that is installed (`brew install create-dmg`). Otherwise it uses `hdiutil` plus AppleScript.

Signed and notarized builds:
```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" NOTARIZE=1 NOTARY_PROFILE=myprofile ./packaging/make_dmg.sh
```
Run `DRY_RUN=1 ./packaging/make_dmg.sh` to print every step without running anything.

### C. Source installer (builds on your Mac)
Open `FitzroviaRecordsDAW-Source-Installer.dmg` and read **START HERE.txt**. Double-click **Install Fitzrovia Records DAW.command**; macOS blocks it the first time because it is unsigned, so allow it with **System Settings › Privacy & Security › Open Anyway** (macOS 13–14: Control-click › **Open**). Alternatively, copy it to the Desktop and run `xattr -dr com.apple.quarantine ~/Desktop/"Install Fitzrovia Records DAW.command"`. The Xcode Command Line Tools are required (the script offers to install them). It does the following:
1. Checks for the Xcode Command Line Tools and offers to install them.
2. Builds the app.
3. Installs it to `/Applications`, or to `~/Applications` if you decline to use an admin password.
4. Removes the quarantine flag and registers the `.sfproj` document type.
5. Creates the library folders and launches the app.

This image is an ISO 9660 disk image (Rock Ridge + Joliet), not a UDIF DMG; macOS mounts it on double-click. Rebuild it with `packaging/build_source_image.sh`, which runs on Linux or macOS.

### Gatekeeper (unsigned / ad-hoc builds)
Builds that are not notarized by Apple show "Apple could not verify ... is free of malware" the first time they are opened from a browser download. **macOS 15 Sequoia, 26 Tahoe and 27 removed the Control-click › Open bypass**, so:
1. Double-click the `.pkg` (or the app from the DMG). Click **Done** in the warning.
2. Open **System Settings › Privacy & Security**, scroll to *Security*, click **Open Anyway** next to the item (shown for about an hour), and enter your password or use Touch ID.
3. Click **Open** in the final prompt. macOS remembers this choice.

Other options: the Terminal command at the top of this section (no prompts at all), or `xattr -dr com.apple.quarantine ~/Downloads/Install-FitzroviaRecordsDAW.pkg` before double-clicking. An app installed by the package is never quarantined (the installer also clears the flag), so it opens normally. On macOS 13–14, Control-click › **Open** still works. A Developer ID certificate plus notarization (see *Signing* above) removes all of this.

### What first launch sets up
- Library folders: `~/Music/Fitzrovia Records DAW/{Projects, Recordings, Exports, Presets/User, Presets/Factory, ImpulseResponses, Models, Samples}` and `~/Library/Application Support/Fitzrovia Records DAW`. The factory presets are copied to `Presets/Factory` for browsing. Projects save to `Projects`, recordings made before the first save go to `Recordings`, and models download to `Models`.
- A welcome screen explains microphone and audio-input access, then asks for it.
- **Help › Setup & Permissions** shows microphone status and folder status. It has buttons to create missing folders and to open the Microphone, Files & Folders and Bluetooth privacy panes, Sound settings and Audio MIDI Setup.
- Projects are `.sfproj` packages (`com.studioforge.project`). Double-clicking one in Finder opens Fitzrovia Records DAW. Older `.sforge` projects still open.

## Build and run (on your Mac)

Requirements: macOS 13 or later, and Xcode 15+ (or its Command Line Tools with Swift 5.9+).

```bash
unzip StudioForge.zip && cd mac_daw
./build.sh                 # builds release, assembles build/Fitzrovia Records DAW.app, ad-hoc signs it
open build/Fitzrovia Records DAW.app
```

Other ways to build:
* **Xcode:** `open Package.swift`, choose the `Fitzrovia Records DAW` scheme, then Run.
* **XcodeGen:** `brew install xcodegen && xcodegen generate && open StudioForge.xcodeproj`. This uses `project.yml`, `Resources/Info.plist` and `StudioForge.entitlements`.
* **Tests:** `swift test` (also works on Linux).

On first launch, macOS asks for microphone access. You need it for any audio input, including USB and Thunderbolt interfaces. Pick your interface and buffer size under **Audio Settings** (the slider icon).

To bundle ffmpeg for MP3/OGG export: `FFMPEG=$(which ffmpeg) ./build.sh`.

## Features

| Area | What's there |
|---|---|
| Engine | Unlimited audio, instrument and drum tracks. Record, play, loop, punch in/out, metronome with count-in. Per-track volume, pan, mute, solo, arm and monitor mode. Input = any channel or stereo pair on any CoreAudio device. Clips can be split, trimmed, moved, faded and muted. Tempo and time signature, snapshot undo/redo, zoom. |
| Latency | Buffer 32–1024 samples. One full-duplex AUHAL when input and output are the same device. Lock-free real-time path (atomics, SPSC rings, object swap; no locks or allocation in the render callback). Automatic latency compensation for recordings, plus a manual offset. Plugin delay compensation. Latency and CPU readout. Monitor = Off for interface direct monitoring. |
| Record clean | The dry input is **always** recorded. "Also capture wet" writes a second, linked, muted clip with the effects printed. |
| Effects (33) | Parametric EQ, filters, auto-wah, formant; compressor, limiter, gate; overdrive/distortion/fuzz (8 modes), bitcrusher, waveshaper, amp (8 models) plus cabinet IR (9 synthesized cabs, or your own IR); chorus, flanger, phaser, tremolo, ring mod, vocoder-style; delay, pitch shift and octaver; reverbs: room, hall, plate, spring, chamber, cathedral, shimmer, reverse, gated, ambient/huge, and convolution with user IR loading. Every effect has bypass and mix. |
| Instruments | Subtractive synth (multi-osc, unison, filter, envelopes, LFO, FM, noise), bass synth, keys (piano, EP, Rhodes, organ, harpsichord, string machine), trumpet/brass with mutes, and a drum machine (synth voices plus sample pads). CoreMIDI input from all sources, plus an on-screen keyboard. |
| Presets | 111 factory presets as JSON (`Sources/SFPresets/Resources/Presets`). User presets live in `~/Library/Application Support/Fitzrovia Records DAW/Presets` and override factory ones with the same id. Preset browser, **Tone Picker** (artist + instrument), save-as-preset. |
| Show Playing Notes | Transport **Notes** toggle (N, or View › Show Playing Notes ⌥⌘N). During playback each track shows the note(s) it is playing in its header and next to the playhead: chords on instrument tracks, drum names on drum tracks, and a pitch-tracked note on audio tracks (one note at a time; best on vocals, bass and lead lines). |
| Beat generator | 27 styles (industrial, doom, grunge, goth, nu-metal, new wave, alt-rock, plus artist-style templates such as NIN "Closer" at 92 BPM and "March of the Pigs" in 7/8). Controls for tempo, swing, humanize, complexity and fills. **Match to recording** estimates tempo, beats, key, energy and swing, then drops a fitting beat. MIDI export. |
| Import & split | **File › Import & Split Audio…** (⇧⌘I) or the **Split** toolbar button. Pick an audio file, or split the selected clip. Tick the stems you want: vocals, drums (full kit), bass, guitar, piano/keys, other. Then tick the drum types: kick, snare, toms, hi-hat, cymbals. Each stem goes on its own track, aligned with the source, in a single undo step. The original track is muted (optional). Stem files go into the project's `Audio` folder, or `~/Music/Fitzrovia Records DAW/Stems` when the project is unsaved. Uses Demucs **htdemucs_6s** via Core ML if you install it, otherwise the built-in DSP separator (HPSS + band/stereo masks + drum-part splitter). |
| Projects | `.sfproj` package (legacy `.sforge` still opens): `project.json` plus `Audio/`, `Peaks/`, `Bounces/`. Autosave (`autosave.json`, offered when newer), recent projects, built-in and user templates. |
| Export | WAV and AIFF (built in). FLAC, AAC/M4A, ALAC and CAF (Apple encoders, with ffmpeg fallback). MP3 and OGG need ffmpeg. Master, stems or both. Bit depth, sample rate, TPDF dither, normalize, loop range, MIDI. All exports are offline bounces. |
| UX | Onboarding tour, one-click templates (Vocals, Guitar, Band, Beat + Synth), dark theme, tooltips, drag-and-drop audio import, mixer, inspector with generic controls for every effect and instrument. |

Keyboard shortcuts: Space = play/stop, R = record, L = loop, K = metronome, S = split, X = mixer, ⌘Z / ⇧⌘Z = undo/redo, ⌘S = save, ⌘O = open, ⌘I = import, ⌘E = export, ⌘+ / ⌘− = zoom.

## Split quality, artefact reduction and matching synth (0.5.0)
- **Import & Split › Quality:** *Standard* (fast) or *High* (two-pass HPSS, stereo-coherence vocal detection, pitch-aware bass with harmonics, Wiener mask refinement, short-window drum clean-up). High takes roughly 2–3× longer.
- **Reduce artefacts** (with strength): smooths musical noise and warbling, gates faint bleed in quiet passages, softens harsh highs, and keeps attacks sharp. Settings are remembered.
- **Generate matching synth track:** after a split (tick the option and pick a style), or right-click any audio clip › **Generate Matching Synth**, or **File › Generate Matching Synth**. It reads the guitar track for chords and the bass track for notes, detects the key, quantises to the project tempo, and adds an instrument track: *Pad* (follows chords), *Bass synth* (doubles the bass) or *Arpeggio*.
- The separator is still DSP-based (no neural model), so expect some bleed on dense mixes.

## Deleting tracks/stems, volume, genre-matched synths (0.6.0)
- **Delete a track or stem:** click the trash icon in its header, right-click it › *Delete Track / Delete Stem*, use the mixer's trash button, or select it and press **⌘⌫** (Edit › Delete Selected Track / Stem). Stems from one split can be removed together (*Delete All Stems From This Split*), or all at once with **Edit › Delete All Stems**. Everything is undoable with ⌘Z.
- **Volume:** every track and stem header now has its own volume slider and dB readout (double-click the value for 0 dB). The **Mixer** button (key X) shows faders with 0 dB marks (drag, double-click to reset). The inspector has a *Volume & pan* box with −/+ 1 dB buttons and a 0 dB reset. Right-click a track › *Volume* for quick levels, or use ⌥⌘↑ / ⌥⌘↓ on the selected track. A fader drag counts as one undo step.
- **Genre-matched synth tones:** *Generate Matching Synth* now has a **Genre** setting (Auto-detect, Rock, Metal, Pop, Funk, R&B / Soul, Hip-hop, Electronic, Ambient, Jazz, Folk / Acoustic). The genre sets the note register (the frequencies the synth plays at), chord voicing (power chords for rock/metal, diatonic sevenths for jazz/R&B/funk/hip-hop), rhythm (arpeggio speed, bass note length) and timbre (waveform, filter brightness, envelope, drive; Rhodes for jazz/R&B, string machine for folk, 808-style sine sub for hip-hop). Auto-detect guesses the genre from the guitar and bass (distortion, brightness, note density, sustain, sub-bass, tempo, chord changes); it is a rule-based guess, so pick the genre manually if it misjudges.

## Stem-separation model (first-run download, about 1–2 GB)

The Core ML model is **not bundled** (it is large, and Demucs weights have their own license). There are two ways to get it:

1. **Convert it yourself** (recommended):
   ```bash
   python3 -m venv .venv && source .venv/bin/activate
   pip install torch==2.3.1 demucs==4.0.1 coremltools
   python3 tools/convert_demucs_to_coreml.py --out htdemucs_6s.mlpackage
   ```
   Then use **Stems → Import…** and choose the `.mlpackage`. Model contract: input `mix` [1,2,N] at 44.1 kHz; output `sources` [1,6,2,N] in the order drums, bass, other, vocals, guitar, piano.
   The conversion script is **untested**. coremltools has no `istft`, so the script uses a matrix iDFT plus overlap-add. Check its output against PyTorch before relying on it.
2. **Host your converted model** (a zipped `.mlpackage` or `.mlmodelc`) and paste its URL into the Split sheet. The URL is stored in UserDefaults under `SFSeparationModelURL`. You then get a download progress bar.

Without the model, Fitzrovia Records DAW uses the DSP separator automatically. It is lower quality but always available. Expect clean results for bass, drums and drum parts. Vocals, guitar, piano/keys and other are split heuristically (frequency band + stereo position), so they bleed into each other on dense mixes. No pre-converted model is published: an attempt to convert htdemucs_6s on Linux (coremltools 8.1) failed because Core ML rejects a rank-6 reshape inside the model. Converting it on a Mac may need changes to the model code.

## MP3 / OGG

Apple provides no MP3 or Vorbis encoder. Fitzrovia Records DAW calls **ffmpeg** (`brew install ffmpeg`). It looks in the app bundle, `/opt/homebrew/bin`, `/usr/local/bin`, `$PATH`, or the path stored in UserDefaults under `SFFFmpegPath`. A LAME-based encoder can be added by registering an `AudioEncoder` (see docs/EXTENDING.md).

## Artist presets: disclaimer

Artist-named presets and beat styles (NIN, Killing Joke, Type O Negative, Deftones and others) are **original DSP approximations of a general tonal character**. They are built only from Fitzrovia Records DAW's own effects and instruments. They are not copies of any recording, sample, proprietary plugin or preset, and they do not imply any affiliation.

## rea.tools

As you suggested, https://rea.tools/ ("REA – Reverse Engineer Anything", an MIT-licensed agent toolkit for inspecting binaries, JavaScript and runtimes) was consulted only as a reference for how software can be studied. **No proprietary code was inspected, decompiled or copied.** All Fitzrovia Records DAW code is original.

## Known gaps / next steps

* None of the macOS code (UI, CoreAudio, CoreMIDI, Core ML, AVFoundation) has been compiled yet. Build it in Xcode and fix whatever comes up.
* **AU/AUv3 hosting as inserts is not implemented yet.** The graph already reserves an `"au"` effect type, and `EffectRegistry.registerDynamic(typeID:"au")` is the hook to add an `AUAudioUnit` wrapper (see docs/EXTENDING.md). Right now an `"au"` slot is skipped with a log message.
* The arrangement view is functional but basic: no piano-roll editor, automation lanes or tempo map (tempo is constant).
* Split-device mode (different input and output devices) adds about one buffer of latency. For sample-accurate sync, use an Aggregate Device.

See docs/ARCHITECTURE.md, docs/EXTENDING.md and CHANGELOG.md.
