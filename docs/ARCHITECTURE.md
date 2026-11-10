# Architecture

```
StudioForgeApp (main.swift) ──> SFUI (SwiftUI, macOS only)
                                  │
     ┌──────────────┬─────────────┼──────────────┬───────────────┐
  SFEngine       SFExport      SFPresets      SFBeatGen      SFSeparation
  (graph, RT     (bounce,      (JSON presets, (styles, gen,  (Demucs CoreML,
   render, rec,   encoders)     Tone Picker)   analyzer,      HPSS, drum
   CoreAudio/                                   matcher, MIDI) splitter, model
   CoreMIDI)                                                    manager)
     │   └──────────┬──────────────┘
  SFProject (document model, editing, undo, package, autosave, templates, peak cache)
  SFInstruments ──> SFEffects ──> SFCore (atomics, RT queues, params, FFT/DSP, audio file IO)
```

All portable modules compile on Linux. Platform code lives in `#if os(macOS)` files:
`SFEngine/macOS/*` (CoreAudio devices and AUHAL I/O, CoreMIDI), `SFExport/AppleAudio.swift`, `SFSeparation/CoreMLSeparator.swift`, and all of `SFUI`.

## Real-time design
* `EngineCore.render` is the only function called on the I/O thread. It reads an immutable `RenderGraph` obtained through `RTObjectSwap`. The main thread publishes new graphs, and retired ones are freed on the main thread by `collectGarbage()`. There are no locks or allocations on the audio thread.
* Live values (fader, pan, mute/solo/arm, monitor, effect bypass/mix and parameters) are atomics. Moving a knob never rebuilds the graph. `EngineController.structure(of:)` decides when a rebuild is needed, and a rebuild reuses existing effect instances whose type and config are unchanged.
* MIDI travels from CoreMIDI or the UI keyboard through an SPSC queue to the armed or selected instrument track.
* Recording: the I/O thread copies the dry input (and optionally the post-chain wet signal) into per-track SPSC rings. A disk thread writes `StreamingWAVWriter` files. On stop, takes become clips, shifted by the reported round-trip latency plus a manual offset.
* Plugin delay compensation: each track is delayed to match the longest track-chain latency.
* Offline bounce (`OfflineRenderer`) runs the same `EngineCore` with fresh instances, faster than real time.

## Documents
`Project` is a value type (Codable). Each edit replaces the project and records the previous snapshot in `UndoStack`. Audio stays on disk inside the `.sfproj` package, so snapshots are cheap. JSON decoding is tolerant: missing keys fall back to defaults.

## Presets and styles
Presets and beat styles are JSON files. Factory files sit in SwiftPM resource bundles. User files live in Application Support and override factory files by id. Unknown parameter ids are ignored, and missing ones use effect defaults.
