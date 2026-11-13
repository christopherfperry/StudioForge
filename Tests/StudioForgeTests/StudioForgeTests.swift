import XCTest
import Foundation
@testable import SFCore
@testable import SFEffects
@testable import SFInstruments
@testable import SFPresets
@testable import SFBeatGen
@testable import SFSeparation
@testable import SFProject
@testable import SFEngine
@testable import SFExport

final class DSPTests: XCTestCase {
    func sine(_ f: Float, sr: Float = 48_000, n: Int = 48_000, amp: Float = 0.5) -> [Float] {
        (0..<n).map { amp * sinf(2 * .pi * f * Float($0) / sr) }
    }

    func testEveryEffectProcessesWithoutNaN() {
        let reg = EffectRegistry.shared
        XCTAssertGreaterThanOrEqual(reg.all.count, 33, "expected at least 33 built-in effects")
        for d in reg.all {
            let fx = d.factory()
            fx.prepare(sampleRate: 48_000, maxFrames: 512)
            var l = sine(220, n: 512), r = sine(330, n: 512)
            for _ in 0..<20 {
                l.withUnsafeMutableBufferPointer { lb in r.withUnsafeMutableBufferPointer { rb in
                    fx.process(left: lb.baseAddress!, right: rb.baseAddress!, frameCount: 512) } }
            }
            XCTAssertFalse(l.contains { !$0.isFinite } || r.contains { !$0.isFinite }, "\(d.typeID) produced NaN/Inf")
        }
    }

    func testInstrumentsRenderSound() {
        for d in InstrumentRegistry.shared.all {
            let inst = d.factory()
            inst.prepare(sampleRate: 48_000, maxFrames: 512)
            inst.noteOn(note: d.typeID == "drums" ? 36 : 60, velocity: 1)
            var l = [Float](repeating: 0, count: 512), r = l
            var peak: Float = 0
            for _ in 0..<10 {
                for i in 0..<512 { l[i] = 0; r[i] = 0 }
                l.withUnsafeMutableBufferPointer { lb in r.withUnsafeMutableBufferPointer { rb in
                    inst.render(left: lb.baseAddress!, right: rb.baseAddress!, frameCount: 512) } }
                peak = max(peak, l.map(abs).max() ?? 0)
            }
            XCTAssertGreaterThan(peak, 0.001, "\(d.typeID) is silent")
            XCTAssertTrue(l.allSatisfy { $0.isFinite })
        }
    }

    func testWAVRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sf-rt-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let a = AudioData(channels: [sine(440, n: 4800), sine(880, n: 4800)], sampleRate: 48_000)
        try AudioFileIO.writeWAV(a, to: url, format: .int24)
        let b = try AudioFileIO.read(url)
        XCTAssertEqual(b.channelCount, 2)
        XCTAssertEqual(b.frameCount, 4800)
        XCTAssertEqual(b.sampleRate, 48_000)
        for i in stride(from: 0, to: 4800, by: 97) { XCTAssertEqual(a.channels[0][i], b.channels[0][i], accuracy: 1e-4) }
    }

    func testParameterSpecMapping() {
        let s = ParameterSpec("f", "Freq", min: 20, max: 20_000, default: 1000, unit: .hertz, log: true)
        XCTAssertEqual(s.value(fromNormalized: s.normalized(1000)), 1000, accuracy: 0.5)
        XCTAssertEqual(s.clamp(50_000), 20_000)
        XCTAssertEqual(ParameterSpec.choice("m", "Mode", ["A", "B", "C"]).clamp(1.6), 2)
    }
}

final class PresetTests: XCTestCase {
    func testFactoryPresetsAreValid() {
        let lib = PresetLibrary.shared
        XCTAssertTrue(lib.loadErrors.isEmpty, lib.loadErrors.joined(separator: "\n"))
        XCTAssertGreaterThanOrEqual(lib.presets.count, 100)
        for p in lib.presets {
            for e in p.effects {
                guard let fx = EffectRegistry.shared.make(e.type) else { XCTFail("\(p.id): unknown effect \(e.type)"); continue }
                for k in e.params.keys { XCTAssertTrue(fx.parameters.contains(k), "\(p.id): \(e.type) has no param \(k)") }
            }
            if let i = p.instrument {
                guard let inst = InstrumentRegistry.shared.make(i.type) else { XCTFail("\(p.id): unknown instrument \(i.type)"); continue }
                for k in i.params.keys { XCTAssertTrue(inst.parameters.contains(k), "\(p.id): \(i.type) has no param \(k)") }
            }
        }
        for required in ["tyrant-s-serenade-lead", "hallows-eve-deep-baritone-vocal", "elite-distorted-megaphone-vocal", "closer-kit-dry-heavy-kick"] {
            XCTAssertNotNil(lib.preset(id: required), "missing preset \(required)")
        }
    }

    func testPresetApplyRegeneratesEffectIDs() throws {
        let p = try XCTUnwrap(PresetLibrary.shared.preset(id: "tyrant-s-serenade-lead"))
        var t = Track(name: "Lead", kind: .audio)
        p.apply(to: &t)
        p.apply(to: &t)
        XCTAssertEqual(Set(t.effects.map(\.id)).count, t.effects.count)
        XCTAssertEqual(t.presetID, p.id)
    }

    func testTemplatesResolvePresets() {
        for tmpl in ProjectTemplates.builtIn {
            var proj = tmpl.makeProject()
            PresetLibrary.shared.applyReferencedPresets(to: &proj)
            XCTAssertEqual(proj.tracks.count, tmpl.tracks.count)
        }
    }
}

final class BeatTests: XCTestCase {
    func testStylesLoadAndGenerateDeterministically() throws {
        let lib = BeatStyleLibrary.shared
        XCTAssertTrue(lib.loadErrors.isEmpty, lib.loadErrors.joined(separator: "\n"))
        XCTAssertGreaterThanOrEqual(lib.styles.count, 20)
        for style in lib.styles {
            let s = BeatSettings(tempo: style.defaultTempo, bars: 4, seed: 7)
            let a = BeatGenerator().generate(style: style, settings: s)
            let b = BeatGenerator().generate(style: style, settings: s)
            XCTAssertFalse(a.notes.isEmpty, style.id)
            XCTAssertEqual(a.notes.map(\.pitch), b.notes.map(\.pitch), style.id)
            XCTAssertEqual(a.lengthBeats, style.timeSignature.quarterNotesPerBar * 4, accuracy: 1e-9)
        }
    }

    func testMIDIRoundTrip() throws {
        let notes = [MIDINote(pitch: 36, velocity: 110, startBeat: 0, durationBeats: 0.25),
                     MIDINote(pitch: 38, velocity: 90, startBeat: 1, durationBeats: 0.25)]
        let data = MIDIFile.data(tracks: [MIDIFile.Track(name: "Drums", channel: 9, notes: notes)], tempo: 92)
        let r = try MIDIFile.read(data)
        XCTAssertEqual(r.tempo, 92, accuracy: 0.01)
        let all = r.tracks.flatMap(\.notes)
        XCTAssertEqual(all.map(\.pitch).sorted(), [36, 38])
        XCTAssertEqual(all.first { $0.pitch == 38 }!.startBeat, 1, accuracy: 0.01)
    }

    func clicks(bpm: Double, seconds: Double = 12, sr: Double = 44_100) -> [Float] {
        var x = [Float](repeating: 0, count: Int(seconds * sr))
        var t = 0.0
        while t < seconds {
            let i = Int(t * sr)
            for k in 0..<400 where i + k < x.count { x[i + k] += 0.8 * expf(-Float(k) / 60) * sinf(Float(k) * 0.9) }
            t += 60 / bpm
        }
        return x
    }

    func testTempoEstimation() {
        for bpm in [120.0, 92.0] {
            let a = AudioAnalyzer().analyze(samples: clicks(bpm: bpm), sampleRate: 44_100)
            XCTAssertEqual(a.bpm, bpm, accuracy: 2.5, "estimated \(a.bpm) for \(bpm)")
        }
    }

    func testKeyDetectionOnChord() {
        let sr = 44_100.0
        let freqs: [Double] = [130.81, 164.81, 196.0, 261.63] // C major
        let x = (0..<Int(sr * 4)).map { i in Float(freqs.reduce(0) { $0 + sin(2 * .pi * $1 * Double(i) / sr) } * 0.2) }
        let a = AudioAnalyzer().analyze(samples: x, sampleRate: sr)
        XCTAssertEqual(a.keyRoot, 0, "detected \(a.key)")
        XCTAssertFalse(a.keyIsMinor)
    }
}

final class SeparationTests: XCTestCase {
    func testHPSSSeparatesClicksFromTone() {
        let sr: Float = 44_100
        let n = 44_100 * 2
        var tone = [Float](repeating: 0, count: n), click = tone
        for i in 0..<n { tone[i] = 0.3 * sinf(2 * .pi * 440 * Float(i) / sr) }
        for start in stride(from: 0, to: n, by: 11_025) { for k in 0..<64 where start + k < n { click[start + k] = k % 2 == 0 ? 0.9 : -0.9 } }
        let mix = zip(tone, click).map { $0 + $1 }
        let (h, p) = HPSS().separate(mix)
        func corr(_ a: [Float], _ b: [Float]) -> Float {
            var ab: Float = 0, aa: Float = 0, bb: Float = 0
            for i in 0..<min(a.count, b.count) { ab += a[i] * b[i]; aa += a[i] * a[i]; bb += b[i] * b[i] }
            return ab / max(1e-9, sqrtf(aa * bb))
        }
        XCTAssertGreaterThan(corr(h, tone), corr(h, click))
        XCTAssertGreaterThan(corr(p, click), corr(p, tone))
    }

    func testDSPSeparatorProducesRequestedStems() throws {
        let sr = 44_100.0
        let x = (0..<Int(sr * 2)).map { Float(0.3 * sin(2 * .pi * 110 * Double($0) / sr)) }
        let stems = try DSPStemSeparator().separate(AudioData(channels: [x, x], sampleRate: sr),
                                                    options: SeparationOptions(), progress: { _, _ in }, isCancelled: { false })
        for s in [Stem.vocals, .bass, .drums, .other] { XCTAssertNotNil(stems[s], "missing \(s)") }
        XCTAssertNotNil(stems[.kick])
    }

    func energy(_ a: AudioData?) -> Float { (a?.channels ?? []).reduce(0) { $0 + $1.reduce(0) { $0 + $1 * $1 } } }

    /// Synthetic mix: centred 220 Hz "vocal" + 55 Hz bass + hard-left 660 Hz "guitar" + 70 Hz kick and
    /// noisy hi-hat bursts. Every requested stem must be returned, finite, and the obvious sources must
    /// land in the right place.
    func testFullSplitRoutesSourcesAndReturnsAllStems() throws {
        let sr = 44_100.0, n = Int(sr * 3)
        var l = [Float](repeating: 0, count: n), r = l
        var rng = SystemRandomNumberGenerator()
        for i in 0..<n {
            let t = Double(i) / sr
            let vocal = Float(0.2 * sin(2 * .pi * 220 * t) + 0.1 * sin(2 * .pi * 440 * t))
            let bass = Float(0.3 * sin(2 * .pi * 55 * t))
            let guitar = Float(0.2 * sin(2 * .pi * 660 * t))
            l[i] = vocal + bass + guitar; r[i] = vocal + bass
        }
        let beat = Int(sr / 2)
        for s in stride(from: 0, to: n, by: beat) {
            for k in 0..<4000 where s + k < n {
                let kick = Float(0.9 * exp(-Double(k) / 1500) * sin(2 * .pi * 70 * Double(k) / sr))
                l[s + k] += kick; r[s + k] += kick
            }
            let h = s + beat / 2
            for k in 0..<600 where h + k < n {
                let v = Float.random(in: -0.4...0.4, using: &rng) * expf(-Float(k) / 150)
                l[h + k] += v; r[h + k] += v
            }
        }
        let opts = SeparationOptions.full
        let stems = try DSPStemSeparator().separate(AudioData(channels: [l, r], sampleRate: sr),
                                                    options: opts, progress: { _, _ in }, isCancelled: { false })
        for s in opts.expectedStems {
            XCTAssertNotNil(stems[s], "missing \(s)")
            XCTAssertTrue(stems[s]?.channels.allSatisfy { $0.allSatisfy(\.isFinite) } ?? false, "\(s) not finite")
            XCTAssertEqual(stems[s]?.frameCount, n)
        }
        XCTAssertEqual(opts.expectedStems.count, 11)
        XCTAssertGreaterThan(energy(stems[.guitar]), 0, "guitar empty")
        XCTAssertGreaterThan(energy(stems[.piano]), 0, "piano empty")
        XCTAssertGreaterThan(energy(stems[.other]), 0, "other empty")
        XCTAssertGreaterThan(energy(stems[.bass]), energy(stems[.vocals]) * 0.5)
        XCTAssertGreaterThan(energy(stems[.kick]), energy(stems[.hihat]), "kick should dominate the low drum hits")
        XCTAssertGreaterThan(energy(stems[.hihat]), energy(stems[.toms]), "short noise bursts are hi-hats")
        XCTAssertGreaterThan(energy(stems[.hihat]), energy(stems[.cymbals]), "short bursts must not be read as cymbals")
    }

    func testDrumsOnlyPresetAndStemWriterNeverOverwrites() throws {
        XCTAssertEqual(SeparationOptions.drumsOnly.expectedStems, Stem.drumParts)
        XCTAssertTrue(SeparationOptions(stems: [], splitDrums: false).isEmpty)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sf-stems-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = AudioData(channels: [[Float](repeating: 0.1, count: 100)], sampleRate: 44_100)
        let first = try StemWriter.write([.drums: a, .piano: a], baseName: "Song: 1", to: dir)
        let second = try StemWriter.write([.drums: a], baseName: "Song: 1", to: dir)
        XCTAssertEqual(first[.drums]?.lastPathComponent, "Song- 1 - Drums full.wav")
        XCTAssertEqual(first[.piano]?.lastPathComponent, "Song- 1 - Piano - Keys.wav")
        XCTAssertNotEqual(first[.drums], second[.drums])
    }
}

final class ProjectTests: XCTestCase {
    func testAddStemTracksIsOneMutationAlignedToSourceClip() {
        var p = Project(name: "T")
        let src = p.addTrack(kind: .audio, name: "Mix")
        let other = p.addTrack(kind: .audio, name: "After")
        let specs = [Project.StemTrackSpec(name: "Vocals", file: "Audio/v.wav", fileDuration: 10),
                     Project.StemTrackSpec(name: "Kick", file: "Audio/k.wav", fileDuration: 10)]
        let ids = p.addStemTracks(specs, start: 4, offset: 2, duration: 5, afterTrack: src, muteTrack: src)
        XCTAssertEqual(ids.count, 2)
        XCTAssertEqual(p.tracks.map(\.name), ["Mix", "Vocals", "Kick", "After"])
        XCTAssertTrue(p.tracks[0].mute)
        XCTAssertEqual(p.trackIndex(other), 3)
        let c = p.tracks[2].audioClips[0]
        XCTAssertEqual(c.start, 4); XCTAssertEqual(c.offset, 2); XCTAssertEqual(c.duration, 5)
        // Duration is clamped to the file.
        p.addStemTracks([Project.StemTrackSpec(name: "X", file: "x", fileDuration: 3)], start: 0, offset: 2, duration: 5)
        XCTAssertEqual(p.tracks.last?.audioClips.first?.duration, 1)
        XCTAssertTrue(p.addStemTracks([], start: 0).isEmpty)
    }

    func testAdoptAndRelocateClipsDoNotDuplicateOrLoseAudio() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("sf-reloc-\(UUID())")
        defer { try? fm.removeItem(at: root) }
        let oldPkg = root.appendingPathComponent("A.sfproj"), newPkg = root.appendingPathComponent("B.sfproj")
        try ProjectPackage.create(at: oldPkg)
        let a = AudioData(channels: [[Float](repeating: 0.1, count: 100)], sampleRate: 44_100)
        let inside = oldPkg.appendingPathComponent("Audio/stem.wav")
        try AudioFileIO.writeWAV(a, to: inside, format: .int24)
        // A file already inside the package is referenced, not copied.
        XCTAssertEqual(try ProjectPackage.adopt(inside, into: oldPkg), "Audio/stem.wav")
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: oldPkg.appendingPathComponent("Audio").path).count, 1)
        // Save As: relative clips are copied into the new package once even if shared by two clips.
        var p = Project(name: "T")
        let t = p.addTrack(kind: .audio)
        let i = try XCTUnwrap(p.trackIndex(t))
        p.tracks[i].audioClips = [AudioClip(name: "a", file: "Audio/stem.wav", start: 0, duration: 1),
                                  AudioClip(name: "b", file: "Audio/stem.wav", start: 2, duration: 1),
                                  AudioClip(name: "gone", file: "/nonexistent/x.wav", start: 0, duration: 1)]
        try ProjectPackage.create(at: newPkg)
        let r = ProjectPackage.relocateClips(p, from: oldPkg, to: newPkg)
        let files = r.tracks[i].audioClips.map(\.file)
        XCTAssertEqual(files[0], "Audio/stem.wav"); XCTAssertEqual(files[1], files[0])
        XCTAssertEqual(files[2], "/nonexistent/x.wav")
        XCTAssertTrue(fm.fileExists(atPath: newPkg.appendingPathComponent(files[0]).path))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: newPkg.appendingPathComponent("Audio").path).count, 1)
    }

    func testSaveLoadRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sf-\(UUID()).\(ProjectPackage.fileExtension)")
        defer { try? FileManager.default.removeItem(at: url) }
        var p = ProjectTemplates.band.makeProject(name: "Song")
        p.tracks[0].audioClips.append(AudioClip(name: "c", file: "Audio/c.wav", start: 1, duration: 2))
        try ProjectPackage.save(p, to: url)
        let q = try ProjectPackage.load(from: url)
        XCTAssertEqual(q.name, "Song")
        XCTAssertEqual(q.tracks.count, p.tracks.count)
        XCTAssertEqual(q.tracks[0].audioClips.first?.start, 1)
    }

    func testClipEditingAndUndo() throws {
        let c = AudioClip(name: "c", file: "x.wav", start: 2, offset: 0.5, duration: 4)
        let (a, b) = try XCTUnwrap(ClipEditing.split(c, at: 3))
        XCTAssertEqual(a.duration, 1, accuracy: 1e-9)
        XCTAssertEqual(b.start, 3, accuracy: 1e-9)
        XCTAssertEqual(b.offset, 1.5, accuracy: 1e-9)
        let t = ClipEditing.trimStart(c, to: 2.5)
        XCTAssertEqual(t.offset, 1.0, accuracy: 1e-9)
        XCTAssertEqual(t.end, c.end, accuracy: 1e-9)

        var undo = UndoStack()
        var p = Project(name: "A")
        undo.record(p, label: "Add")
        p.addTrack(kind: .audio)
        let restored = try XCTUnwrap(undo.undo(current: p))
        XCTAssertEqual(restored.tracks.count, 0)
        XCTAssertEqual(undo.redo(current: restored)?.tracks.count, 1)
    }
}

final class EngineExportTests: XCTestCase {
    func testOfflineRenderAndExport() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sf-exp-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // A one-second sine clip on an audio track + a beat on a drum track.
        let sr = 48_000.0
        let wav = dir.appendingPathComponent("tone.wav")
        let x = (0..<Int(sr)).map { Float(0.25 * sin(2 * .pi * 220 * Double($0) / sr)) }
        try AudioFileIO.writeWAV(AudioData(channels: [x], sampleRate: sr), to: wav, format: .float32)
        var p = Project(name: "Render", tempo: 120)
        let id = p.addTrack(kind: .audio)
        p.tracks[p.trackIndex(id)!].audioClips.append(AudioClip(name: "tone", file: wav.path, start: 0, duration: 1))
        let d = p.addTrack(kind: .drums)
        let style = try XCTUnwrap(BeatStyleLibrary.shared.styles.first)
        let beat = BeatGenerator().generate(style: style, settings: BeatSettings(tempo: 120, bars: 1))
        p.tracks[p.trackIndex(d)!].midiClips.append(MIDIClip(name: "beat", startBeat: 0, lengthBeats: beat.lengthBeats, notes: beat.notes))

        var opts = OfflineRenderer.Options()
        opts.sampleRate = sr; opts.tail = 0.5
        let audio = try OfflineRenderer().renderMaster(project: p, packageURL: nil, options: opts)
        XCTAssertGreaterThan(audio.peak, 0.05)
        XCTAssertTrue(audio.channels[0].allSatisfy { $0.isFinite })

        var s = ExportSettings()
        s.content = .masterAndStems; s.normalize = true; s.includeMIDI = true
        let r = try Exporter().export(project: p, packageURL: nil, settings: s, folder: dir, baseName: "Render")
        XCTAssertEqual(r.files.filter { $0.pathExtension == "wav" }.count, 3)   // master + 2 stems
        XCTAssertTrue(r.files.contains { $0.pathExtension == "mid" })
        let master = try AudioFileIO.read(r.files[0])
        XCTAssertEqual(master.peak, dbToGain(-1), accuracy: 0.01)
    }

    func testFFmpegEncoderWhenAvailable() throws {
        guard FFmpegLocator.find() != nil else { throw XCTSkip("ffmpeg not installed") }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sf-\(UUID()).flac")
        defer { try? FileManager.default.removeItem(at: url) }
        var s = ExportSettings(); s.format = .flac
        let a = AudioData(channels: [[Float](repeating: 0.1, count: 4800)], sampleRate: 48_000)
        try FFmpegEncoder().encode(a, to: url, settings: s)
        XCTAssertGreaterThan((try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0, 100)
    }
}

final class SetupTests: XCTestCase {
    func testFirstRunSetupCreatesLibraryAndCopiesPresetsIdempotently() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("sf-setup-\(UUID())")
        defer { try? fm.removeItem(at: base) }
        let root = base.appendingPathComponent("Music/Fitzrovia Records DAW"), support = base.appendingPathComponent("Support")
        let r1 = FirstRunSetup.run(root: root, support: support, markComplete: false)
        XCTAssertTrue(r1.ok, "\(r1.errors)")
        for f in ["Projects", "Recordings", "Exports", "Presets/User", "ImpulseResponses", "Models", "Samples"] {
            XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent(f).path), f)
        }
        XCTAssertTrue(fm.fileExists(atPath: support.path))
        XCTAssertGreaterThanOrEqual(r1.copiedPresets, 100)
        XCTAssertTrue(FirstRunSetup.folderStatus(root: root).allSatisfy { $0.exists && $0.writable })
        let r2 = FirstRunSetup.run(root: root, support: support, markComplete: false)
        XCTAssertEqual(r2.copiedPresets, 0); XCTAssertTrue(r2.createdFolders.isEmpty)
        XCTAssertEqual(ProjectPackage.fileExtension, "sfproj")
        XCTAssertTrue(AppPaths.defaultProjectsFolder.path.hasSuffix("Fitzrovia Records DAW/Projects"))
    }
}


final class PlayingNotesTests: XCTestCase {
    func tone(_ hz: Double, seconds: Double, sr: Double = 48_000, amp: Float = 0.4) -> [Float] {
        // fundamental + a 2nd harmonic, like a real instrument
        let w: Double = 2 * Double.pi * hz / sr
        return (0..<Int(seconds * sr)).map { (i: Int) -> Float in
            let ph: Double = w * Double(i)
            let v: Double = sin(ph) + 0.4 * sin(2 * ph)
            return amp * Float(v)
        }
    }

    func testNoteNamesAndLabels() {
        XCTAssertEqual(NoteName.name(60), "C4")
        XCTAssertEqual(NoteName.name(69), "A4")
        XCTAssertEqual(NoteName.name(61), "C#4")
        XCTAssertEqual(NoteName.name(21), "A0")
        XCTAssertEqual(NoteName.name(0), "C-1")
        XCTAssertEqual(NoteName.label(for: [67, 60, 64, 60], drums: false), "C4 E4 G4")
        XCTAssertEqual(NoteName.label(for: [36, 42], drums: true), "Kick + Closed Hat")
        XCTAssertEqual(NoteName.label(for: [60, 62, 64, 65, 67, 69], drums: false), "C4 D4 E4 F4 +2")
        XCTAssertEqual(NoteName.label(for: [], drums: false), "")
        XCTAssertEqual(NoteName.midi(fromFrequency: 440), 69, accuracy: 1e-9)
    }

    func testSoundingMIDIPitchesFollowsClipsAndTempo() {
        var p = Project(name: "N", tempo: 120)   // 0.5 s per beat
        let id = p.addTrack(kind: .instrument, name: "Keys")
        let i = p.trackIndex(id)!
        p.tracks[i].midiClips = [MIDIClip(name: "c", startBeat: 4, lengthBeats: 4, notes: [
            MIDINote(pitch: 60, velocity: 100, startBeat: 0, durationBeats: 2),
            MIDINote(pitch: 64, velocity: 100, startBeat: 1, durationBeats: 1),
            MIDINote(pitch: 72, velocity: 100, startBeat: 3, durationBeats: 8),   // runs past clip end
        ])]
        let t = p.tracks[i]
        XCTAssertEqual(p.soundingMIDIPitches(track: t, at: 1.0), [])          // before the clip
        XCTAssertEqual(p.soundingMIDIPitches(track: t, at: 2.1), [60])        // beat 4.2
        XCTAssertEqual(p.soundingMIDIPitches(track: t, at: 2.6).sorted(), [60, 64])
        XCTAssertEqual(p.soundingMIDIPitches(track: t, at: 3.9), [72])        // beat 7.8
        XCTAssertEqual(p.soundingMIDIPitches(track: t, at: 4.1), [])          // clip ended
        p.tracks[i].midiClips[0].muted = true
        XCTAssertEqual(p.soundingMIDIPitches(track: p.tracks[i], at: 2.1), [])
    }

    func testAudioClipPositionMapsToFileTime() {
        var p = Project(name: "A")
        let id = p.addTrack(kind: .audio, name: "Bass")
        let i = p.trackIndex(id)!
        p.tracks[i].audioClips = [AudioClip(name: "b", file: "Audio/b.wav", start: 10, offset: 2, duration: 5)]
        let hit = p.audioClipPosition(track: p.tracks[i], at: 12)
        XCTAssertEqual(hit?.fileTime ?? -1, 4, accuracy: 1e-9)
        XCTAssertNil(p.audioClipPosition(track: p.tracks[i], at: 15.5))
    }

    func testPitchTrackerFindsNotesAndSilence() {
        let sr = 48_000.0
        // A2 (bass), silence, A4, E5 (vocal range)
        let samples = tone(110, seconds: 1) + [Float](repeating: 0, count: Int(sr / 2)) + tone(440, seconds: 1) + tone(659.255, seconds: 1)
        let c = PitchTracker.contour(samples: samples, sampleRate: sr)
        XCTAssertGreaterThan(c.duration, 3)
        XCTAssertEqual(c.note(at: 0.5), 45)    // A2
        XCTAssertNil(c.note(at: 1.25))         // silence
        XCTAssertEqual(c.note(at: 2.0), 69)    // A4
        XCTAssertEqual(c.note(at: 3.0), 76)    // E5
        let noise = PitchTracker.contour(samples: (0..<48_000).map { _ in Float.random(in: -0.3...0.3) }, sampleRate: sr)
        let voiced = noise.notes.compactMap { $0 }.count
        XCTAssertLessThan(Double(voiced), Double(noise.notes.count) * 0.2, "white noise should mostly read as no note")
    }
}

// MARK: - 0.5.0: high-quality split, artefact reduction, matching synth

final class QualitySplitTests: XCTestCase {
    func energy(_ a: AudioData?) -> Float { (a?.channels ?? []).reduce(0) { $0 + $1.reduce(0) { $0 + $1 * $1 } } }

    /// Goertzel power of `hz` in the mono mix of `a`.
    func tone(_ a: AudioData?, _ hz: Double) -> Double {
        guard let a = a else { return 0 }
        let x = a.mono, w = 2 * Double.pi * hz / a.sampleRate, c = 2 * cos(w)
        var s1 = 0.0, s2 = 0.0
        for v in x { let s = Double(v) + c * s1 - s2; s2 = s1; s1 = s }
        return (s1 * s1 + s2 * s2 - c * s1 * s2) / Double(max(1, x.count))
    }

    func testOptionsDefaultsAreBackwardCompatible() {
        let o = SeparationOptions()
        XCTAssertEqual(o.quality, .standard)
        XCTAssertEqual(o.artefactReduction, 0)
        XCTAssertEqual(SeparationOptions(artefactReduction: 3).artefactReduction, 1)
        XCTAssertEqual(SeparationOptions.fourStem.quality, .standard)
    }

    /// Centred bass (55 Hz + harmonics) and vocal (220 Hz), hard-left guitar (660 / 880 Hz), clicks.
    func makeMix(seconds: Double = 3) -> AudioData {
        let sr = 44_100.0, n = Int(sr * seconds)
        var l = [Float](repeating: 0, count: n), r = l
        for i in 0..<n {
            let t = Double(i) / sr
            let bass = 0.3 * sin(2 * .pi * 55 * t) + 0.12 * sin(2 * .pi * 110 * t) + 0.06 * sin(2 * .pi * 165 * t)
            let vocal = 0.15 * sin(2 * .pi * 220 * t + 2 * sin(2 * .pi * 5 * t))
            let guitar = 0.15 * sin(2 * .pi * 660 * t) + 0.1 * sin(2 * .pi * 880 * t)
            l[i] = Float(bass + vocal + guitar); r[i] = Float(bass + vocal)
        }
        for s in stride(from: 0, to: n, by: Int(sr / 2)) {
            for k in 0..<300 where s + k < n {
                let v = Float(0.6 * exp(-Double(k) / 60)) * (k % 2 == 0 ? 1 : -1)
                l[s + k] += v; r[s + k] += v
            }
        }
        return AudioData(channels: [l, r], sampleRate: sr)
    }

    func testHighQualitySplitRoutesSourcesAndReconstructs() throws {
        let mix = makeMix()
        let opts = SeparationOptions(stems: [.vocals, .bass, .drums, .guitar, .other], splitDrums: false, quality: .high)
        let stems = try DSPStemSeparator().separate(mix, options: opts, progress: { _, _ in }, isCancelled: { false })
        for s in opts.expectedStems {
            XCTAssertEqual(stems[s]?.frameCount, mix.frameCount, "\(s)")
            XCTAssertTrue(stems[s]?.channels.allSatisfy { $0.allSatisfy(\.isFinite) } ?? false, "\(s) not finite")
        }
        // Pitch-aware bass keeps the bass harmonics; guitar tones stay out of the bass.
        XCTAssertGreaterThan(tone(stems[.bass], 55), 10 * tone(stems[.guitar], 55))
        XCTAssertGreaterThan(tone(stems[.bass], 110), tone(stems[.guitar], 110) + tone(stems[.other], 110))
        let g660 = tone(stems[.guitar], 660) + tone(stems[.other], 660)
        XCTAssertGreaterThan(g660, 5 * tone(stems[.bass], 660))
        XCTAssertGreaterThan(g660, tone(stems[.vocals], 660))
        XCTAssertGreaterThan(tone(stems[.vocals], 220), tone(stems[.guitar], 220))
        // Wiener masks partition the mix: the stems add back up to (almost) the input.
        var err: Float = 0, total: Float = 0
        let skip = 4096   // ignore STFT edge frames
        for c in 0..<2 {
            for i in skip..<(mix.frameCount - skip) {
                var sum: Float = 0
                for s in opts.expectedStems { sum += stems[s]!.channels[c][i] }
                let d = sum - mix.channels[c][i]
                err += d * d; total += mix.channels[c][i] * mix.channels[c][i]
            }
        }
        XCTAssertLessThan(err / total, 0.05, "stems should sum back to the mix")
    }

    func testArtefactReductionRunsInSeparatorAndStaysFinite() throws {
        let mix = makeMix(seconds: 2)
        for q in SeparationQuality.allCases {
            let opts = SeparationOptions(stems: [.vocals, .bass, .drums, .guitar], splitDrums: true, quality: q, artefactReduction: 0.7)
            let stems = try DSPStemSeparator().separate(mix, options: opts, progress: { _, _ in }, isCancelled: { false })
            for s in opts.expectedStems {
                XCTAssertTrue(stems[s]?.channels.allSatisfy { $0.allSatisfy(\.isFinite) } ?? false, "\(q) \(s)")
            }
            XCTAssertGreaterThan(energy(stems[.bass]), 0)
        }
    }

    func testArtefactReducerRemovesSpecklesAndGatesResidue() {
        let frames = 40, bins = 64
        let mag = [Float](repeating: 1, count: frames * bins)
        // Musical noise: isolated speckles in mask B, complement in A.
        var b = [Float](repeating: 0.02, count: frames * bins)
        for f in stride(from: 3, to: frames, by: 7) { for k in stride(from: 5, to: bins, by: 11) { b[f * bins + k] = 0.6 } }
        let a = b.map { 1 - $0 }
        XCTAssertEqual(ArtefactReducer(strength: 0).refine([a, b], mixMagnitude: mag, frames: frames, bins: bins, binHz: 50)[1], b)
        let out = ArtefactReducer(strength: 0.8).refine([a, b], mixMagnitude: mag, frames: frames, bins: bins, binHz: 50)
        XCTAssertLessThan(out[1].max()!, 0.3, "speckles should be smoothed away")
        for i in 0..<(frames * bins) {
            XCTAssertTrue(out[0][i].isFinite && out[1][i].isFinite)
            XCTAssertGreaterThanOrEqual(out[0][i], 0); XCTAssertGreaterThanOrEqual(out[1][i], 0)
            XCTAssertLessThanOrEqual(out[0][i] + out[1][i], 1.0001)
        }
        XCTAssertGreaterThan(out[0].reduce(0, +) / Float(frames * bins), 0.8, "the main stem must survive")

        // Faint residue in a quiet passage is gated.
        var quietMag = mag
        for i in (20 * bins)..<(frames * bins) { quietMag[i] = 1e-5 }
        let half = [Float](repeating: 0.5, count: frames * bins)
        let gated = ArtefactReducer(strength: 0.8).refine([half], mixMagnitude: quietMag, frames: frames, bins: bins, binHz: 50)[0]
        let before = half[(20 * bins)...].reduce(0, +), after = gated[(20 * bins)...].reduce(0, +)
        XCTAssertLessThan(after, 0.2 * before)
        XCTAssertGreaterThan(gated[5 * bins + 10], 0.4, "loud passage is untouched")
    }
}

final class SynthGeneratorTests: XCTestCase {
    let sr = 22_050.0

    func sine(_ midis: [Int], seconds: Double, amp: Double = 0.2) -> [Float] {
        let n = Int(sr * seconds)
        return (0..<n).map { i in
            let t = Double(i) / sr
            var v = 0.0
            for m in midis {
                let f = 440 * pow(2, Double(m - 69) / 12)
                v += amp * (sin(2 * .pi * f * t) + 0.3 * sin(4 * .pi * f * t))
            }
            return Float(v)
        }
    }

    func chordAudio(_ chords: [[Int]], seconds: Double) -> AudioData {
        AudioData(channels: [chords.flatMap { sine($0, seconds: seconds, amp: 0.12) }], sampleRate: sr)
    }

    func testChordDetectionFindsMajorAndMinorTriads() {
        let audio = chordAudio([[60, 64, 67], [57, 60, 64], [53, 57, 60], [55, 59, 62]], seconds: 2)
        let g = SynthTrackGenerator(tempo: 120)   // 2 beats per 1 s window
        let key = g.detectKey([audio])
        let chords = g.detectChords(audio, keyRoot: key.root, minor: key.minor, keyConfidence: key.confidence)
        XCTAssertEqual(chords.map(\.name), ["C", "Am", "F", "G"])
        XCTAssertEqual(chords.map(\.startBeat), [0, 4, 8, 12])
        XCTAssertEqual(chords.first?.lengthBeats, 4)
    }

    func testBassNotesFollowPitchAndAreQuantised() {
        let audio = AudioData(channels: [sine([33], seconds: 1, amp: 0.4) + sine([38], seconds: 1, amp: 0.4)
                                         + sine([40], seconds: 1, amp: 0.4)], sampleRate: sr)
        let notes = SynthTrackGenerator(tempo: 120).bassNotes(audio, keyRoot: 9, minor: true)
        XCTAssertEqual(notes.map(\.pitch), [33, 38, 40])
        XCTAssertEqual(notes.map(\.startBeat), [0, 2, 4])
        for n in notes { XCTAssertEqual((n.lengthBeats / 0.5).rounded() * 0.5, n.lengthBeats, accuracy: 1e-9) }
        // Out-of-key pitches snap to the scale.
        XCTAssertEqual(SynthTrackGenerator.snap(61, to: SynthTrackGenerator.scale(root: 0, minor: false)), 60)
    }

    func testEveryStyleIsInKeyOnGridAndPlayable() {
        let guitar = chordAudio([[60, 64, 67], [57, 60, 64], [53, 57, 60], [55, 59, 62]], seconds: 2)
        let bass = AudioData(channels: [[36, 33, 41, 43].flatMap { sine([$0], seconds: 2, amp: 0.4) }], sampleRate: sr)
        let scale = SynthTrackGenerator.scale(root: 0, minor: false)
        for style in SynthStyle.allCases {
            let r = SynthTrackGenerator(tempo: 120).generate(style: style, guitar: guitar, bass: bass)
            XCTAssertFalse(r.notes.isEmpty, "\(style)")
            XCTAssertTrue(scale == SynthTrackGenerator.scale(root: r.keyRoot, minor: r.keyIsMinor), "key \(r.keyName)")
            let step = style == .arpeggio ? 0.25 : 0.5
            for n in r.notes {
                XCTAssertTrue(scale.contains(n.pitch % 12), "\(style) \(n.pitch) out of key")
                XCTAssertEqual((n.startBeat / step).rounded() * step, n.startBeat, accuracy: 1e-9)
                XCTAssertGreaterThan(n.durationBeats, 0)
                XCTAssertLessThan(n.startBeat, r.lengthBeats)
            }
            XCTAssertEqual(r.lengthBeats, 16)
            XCTAssertNotNil(InstrumentRegistry.shared.make(r.instrument.type), "\(r.instrument.type) not registered")
        }
        let pad = SynthTrackGenerator(tempo: 120).generate(style: .pad, guitar: guitar, bass: nil)
        let atBeat4 = Set(pad.notes.filter { $0.startBeat == 4 }.map { $0.pitch % 12 })
        XCTAssertEqual(atBeat4, [9, 0, 4], "pad follows the A minor chord")
        let bs = SynthTrackGenerator(tempo: 120).generate(style: .bassSynth, guitar: nil, bass: bass)
        XCTAssertEqual(bs.notes.map { $0.pitch % 12 }, [0, 9, 5, 7])
    }
}

final class GenreToneTests: XCTestCase {
    let sr = 22_050.0
    func tone(_ midis: [Int], seconds: Double, amp: Double = 0.15, clip: Float? = nil) -> [Float] {
        let n = Int(sr * seconds)
        return (0..<n).map { i in
            let t = Double(i) / sr
            var v: Float = 0
            for m in midis { v += Float(amp * sin(2 * .pi * 440 * pow(2, Double(m - 69) / 12) * t)) }
            if let c = clip { v = max(-c, min(c, v * 12)) }   // hard clipping = distortion
            return v
        }
    }

    func testEveryGenreHasPlayableInstrumentsAndSaneRegisters() {
        for g in MusicGenre.concrete {
            let p = GenreTone.profile(g)
            for st in SynthStyle.allCases {
                XCTAssertNotNil(InstrumentRegistry.shared.make(p.instrument(for: st).type), "\(g) \(st)")
            }
            XCTAssertLessThan(p.bassRange.upperBound, p.padRange.upperBound, "\(g)")
            XCTAssertGreaterThanOrEqual(p.padRange.count, 13, "\(g) pad range must hold an octave")
            XCTAssertGreaterThanOrEqual(p.bassRange.count, 13, "\(g) bass range must hold an octave")
            XCTAssertGreaterThanOrEqual(GenreTone.hz(p.bassRange.lowerBound), 29, "\(g) bass below audible sub range")
        }
        // Genre registers differ the way the styles do: hip-hop sub bass sits lowest, ambient pads highest.
        XCTAssertLessThan(GenreTone.profile(.hipHop).bassRange.lowerBound, GenreTone.profile(.pop).bassRange.lowerBound)
        XCTAssertLessThan(GenreTone.profile(.metal).bassRange.lowerBound, GenreTone.profile(.funk).bassRange.lowerBound)
        XCTAssertGreaterThan(GenreTone.profile(.ambient).padRange.upperBound, GenreTone.profile(.rock).padRange.upperBound)
        let cut = { (g: MusicGenre) in GenreTone.profile(g).pad.params["cutoff"] ?? 0 }
        XCTAssertGreaterThan(cut(.electronic), cut(.ambient), "electronic pads brighter than ambient")
    }

    func testClassifierRules() {
        var f = GenreFeatures(); f.distortion = 0.9; f.tempo = 170
        XCTAssertEqual(GenreTone.classify(f).genre, .metal)
        f.distortion = 0.55; f.tempo = 120
        XCTAssertEqual(GenreTone.classify(f).genre, .rock)
        f = GenreFeatures(); f.tempo = 90; f.subWeight = 0.5
        XCTAssertEqual(GenreTone.classify(f).genre, .hipHop)
        f = GenreFeatures(); f.tempo = 65; f.sustain = 0.9; f.onsetRate = 0.5
        XCTAssertEqual(GenreTone.classify(f).genre, .ambient)
        f = GenreFeatures(); f.tempo = 110; f.onsetRate = 6; f.sustain = 0.4
        XCTAssertEqual(GenreTone.classify(f).genre, .funk)
    }

    func testDistortedGuitarIsDetectedAsHeavierThanCleanGuitar() {
        let clean = AudioData(channels: [tone([52, 59, 64], seconds: 3)], sampleRate: sr)
        let dirty = AudioData(channels: [tone([40, 47, 52], seconds: 3, clip: 0.3)], sampleRate: sr)
        let fc = GenreTone.features(guitar: clean, bass: nil, tempo: 120, chords: [], beatsPerBar: 4, keyConfidence: 1)
        let fd = GenreTone.features(guitar: dirty, bass: nil, tempo: 120, chords: [], beatsPerBar: 4, keyConfidence: 1)
        XCTAssertGreaterThan(fd.distortion, fc.distortion + 0.2, "clean \(fc.distortion) dirty \(fd.distortion)")
        XCTAssertTrue([.rock, .metal].contains(GenreTone.classify(fd).genre))
        XCTAssertFalse([.rock, .metal].contains(GenreTone.classify(fc).genre))
    }

    func testGenreShapesRegisterVoicingAndTone() {
        let guitar = AudioData(channels: [[[60, 64, 67], [57, 60, 64], [53, 57, 60], [55, 59, 62]]
            .flatMap { tone($0, seconds: 2, amp: 0.12) }], sampleRate: sr)
        let bass = AudioData(channels: [[36, 33, 41, 43].flatMap { tone([$0], seconds: 2, amp: 0.4) }], sampleRate: sr)
        let gen = SynthTrackGenerator(tempo: 120)
        let scale = SynthTrackGenerator.scale(root: 0, minor: false)
        for g in MusicGenre.concrete {
            let p = GenreTone.profile(g)
            for st in SynthStyle.allCases {
                let r = gen.generate(style: st, guitar: guitar, bass: bass, genre: g)
                XCTAssertEqual(r.genre, g)
                XCTAssertFalse(r.notes.isEmpty, "\(g) \(st)")
                XCTAssertEqual(r.instrument, p.instrument(for: st))
                for n in r.notes { XCTAssertTrue(scale.contains(n.pitch % 12), "\(g) \(st) \(n.pitch) out of key") }
                switch st {
                case .bassSynth: for n in r.notes { XCTAssertTrue(p.bassRange.contains(n.pitch), "\(g) bass \(n.pitch)") }
                case .arpeggio: for n in r.notes { XCTAssertTrue(p.arpRange.contains(n.pitch), "\(g) arp \(n.pitch)") }
                case .pad:
                    let upper = r.notes.filter { $0.pitch >= p.padRange.lowerBound }
                    for n in upper { XCTAssertTrue(p.padRange.contains(n.pitch), "\(g) pad \(n.pitch)") }
                }
            }
        }
        // Metal pads are power chords (no thirds); jazz pads add sevenths.
        let metal = gen.generate(style: .pad, guitar: guitar, bass: nil, genre: .metal)
        let first = Set(metal.notes.filter { $0.startBeat == 0 }.map { $0.pitch % 12 })
        XCTAssertEqual(first, [0, 7], "C power chord")
        let jazz = gen.generate(style: .pad, guitar: guitar, bass: nil, genre: .jazz)
        XCTAssertTrue(Set(jazz.notes.filter { $0.startBeat == 0 }.map { $0.pitch % 12 }).contains(11), "Cmaj7")
        // Hip-hop bass plays lower than electronic bass for the same line.
        let hh = gen.generate(style: .bassSynth, guitar: nil, bass: bass, genre: .hipHop).notes.map(\.pitch)
        let el = gen.generate(style: .bassSynth, guitar: nil, bass: bass, genre: .electronic).notes.map(\.pitch)
        XCTAssertLessThan(hh.reduce(0, +), el.reduce(0, +))
    }
}

final class TrackDeletionTests: XCTestCase {
    func testDeleteTracksAndStemGroups() {
        var p = Project(name: "T")
        let keep = p.addTrack(kind: .audio, name: "Mix")
        let a = p.addStemTracks([.init(name: "Vox", file: "a.wav", fileDuration: 4), .init(name: "Bass", file: "b.wav", fileDuration: 4)], start: 0)
        let b = p.addStemTracks([.init(name: "Drums", file: "c.wav", fileDuration: 4)], start: 0)
        XCTAssertEqual(p.stemSiblings(of: a[0]), Set(a))
        XCTAssertEqual(p.stemSiblings(of: keep), [])
        XCTAssertEqual(p.allStemTrackIDs, Set(a + b))
        XCTAssertEqual(p.deleteTracks(p.stemSiblings(of: a[1])), 2)
        XCTAssertEqual(p.tracks.map(\.id), [keep] + b)
        XCTAssertEqual(p.deleteTracks([keep]), 1)
        XCTAssertEqual(p.deleteTracks([UUID()]), 0)
        XCTAssertEqual(p.tracks.count, 1)
    }

    func testStemGroupSurvivesSaveAndOldProjectsLoad() throws {
        var p = Project(name: "T")
        let ids = p.addStemTracks([.init(name: "Vox", file: "a.wav", fileDuration: 4)], start: 0)
        p.addTrack(kind: .audio, name: "Plain")
        let data = try JSONEncoder().encode(p)
        let back = try JSONDecoder().decode(Project.self, from: data)
        XCTAssertTrue(back.tracks.first { $0.id == ids[0] }!.isStem)
        XCTAssertFalse(back.tracks.last!.isStem)
        let old = try JSONDecoder().decode(Track.self, from: #"{"name":"Old","kind":"audio"}"#.data(using: .utf8)!)
        XCTAssertNil(old.stemGroup)
    }
}
