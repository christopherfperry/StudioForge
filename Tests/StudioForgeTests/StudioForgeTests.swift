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
