# Extending Fitzrovia Records DAW

## Add an effect
1. Subclass `EffectBase` (SFEffects) and give it a `typeID` (for example `"fx.mything"`) and `ParameterSpec`s. Implement `process(left:right:frameCount:)` so it is real-time safe: no allocation, locks or I/O. Read parameters with `parameters["id"]!.value`. Allocate buffers in `prepare(sampleRate:maxFrames:)`.
2. Register it in `BuiltInEffects.registerAll` with an `EffectDescriptor(typeID:name:category:summary:factory:)`, or at app launch with `EffectRegistry.shared.register(...)`.
3. The inspector builds its UI from the parameter specs automatically. The test `testEveryEffectProcessesWithoutNaN` covers the new effect.

**Audio Units:** call `EffectRegistry.shared.registerDynamic(typeID: "au") { state in ... }` and return an `AudioEffect` that wraps an `AUAudioUnit`. Use `state.extra["component"]` for the type:subtype:manufacturer and `state.extra["state"]` for the base64 `fullState`. Call its `renderBlock` with a pre-built pull-input block from `process`. This is the planned AU insert implementation.

## Add a preset
Drop a JSON file into `~/Library/Application Support/Fitzrovia Records DAW/Presets` and click Reload in the preset browser. You do not need to recompile.
```json
{ "id": "my-lead", "name": "My Lead", "category": "Guitar", "artistStyle": "Me",
  "tags": ["lead"], "description": "…",
  "effects": [ { "type": "drive.amp", "params": { "gain": 0.7 } }, { "type": "reverb.hall", "mix": 0.3 } ],
  "instrument": null }
```
To change factory presets, edit `tools/generate_presets.py`, run it, and then run `swift test` (the test validates effect and parameter ids).

## Add an instrument
Subclass `InstrumentBase` (SFInstruments), implement `noteOn`, `noteOff` and `render`, and register an `InstrumentDescriptor` in `InstrumentRegistry`.

## Add a beat style
Add a JSON file to `~/Library/Application Support/Fitzrovia Records DAW/BeatStyles`, or to `tools/generate_beat_styles.py` for factory styles. Lanes are step strings (`x` = hit, `X` = accent, `g` = ghost, `.` = rest), with `stepsPerBar`, `timeSignature`, `tempoRange`, optional `complexLanes`, `fills` and `kitPreset`.

## Add an export format
Implement `AudioEncoder` (SFExport) and call `AudioEncoders.register(MyEncoder())` at launch. Add a case to `ExportFormat` if the format is new. Registered encoders take priority, and failures fall through to the next capable encoder.

## Add a stem separator
Implement `StemSeparator` and return it from `SeparatorFactory.best()`.
