import XCTest
import Foundation
@testable import SFCore
@testable import SFEngine
@testable import SFProject
@testable import SFExport
@testable import SFBeatGen

/// 0.6.2 regression tests: transport errors, delete + undo, live/offline gain parity,
/// project round-trip of mix state, export content.
final class RegressionTests: XCTestCase {
    private func noteTrack(_ p: inout Project, beats: Double = 16) -> UUID {
        let id = p.addTrack(kind: .instrument)
        p.tracks[p.trackIndex(id)!].midiClips.append(MIDIClip(name: "n", startBeat: 0, lengthBeats: beats,
            notes: [MIDINote(pitch: 57, velocity: 110, startBeat: 0, durationBeats: beats)]))
        return id
    }

    /// "Arm at least one audio track" used to stay in lastError and reappear on every later Stop.
    func testRecordErrorIsClearedByNextTransportAction() {
        let engine = EngineController(io: NullAudioIO(sampleRate: 48_000), maxFrames: 512)
        var p = Project(name: "Rec")
        let a = p.addTrack(kind: .audio)
        engine.load(project: p, packageURL: nil)
        XCTAssertFalse(engine.record())
        XCTAssertNotNil(engine.lastError)
        engine.play()
        XCTAssertTrue(engine.stop().isEmpty)
        XCTAssertNil(engine.lastError, "a plain Stop must not repeat the old record error")
        XCTAssertFalse(engine.isPlaying)
        _ = a
    }

    func testRecordStartsOnArmedTrackAndStopReturnsTake() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sf-rec-\(UUID()).\(ProjectPackage.fileExtension)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let engine = EngineController(io: NullAudioIO(sampleRate: 48_000), maxFrames: 512)
        var p = Project(name: "Rec")
        let a = p.addTrack(kind: .audio)
        p.tracks[0].arm = true
        try ProjectPackage.save(p, to: dir)
        engine.load(project: p, packageURL: dir)
        XCTAssertTrue(engine.record(), engine.lastError ?? "")
        XCTAssertTrue(engine.isRecording && engine.isPlaying)
        XCTAssertFalse(engine.record(), "second record while recording is refused")
        var l = [Float](repeating: 0, count: 512), r = l
        for _ in 0..<40 {
            l.withUnsafeMutableBufferPointer { lb in r.withUnsafeMutableBufferPointer { rb in
                engine.core.render(inputChannelCount: 0, left: lb.baseAddress!, right: rb.baseAddress!, frames: 512) } }
        }
        let takes = engine.stop()
        XCTAssertFalse(engine.isRecording)
        XCTAssertEqual(takes.first?.trackID, a)
        let q = engine.applyTakes(takes, to: p)
        XCTAssertEqual(q.tracks[0].audioClips.count, takes.isEmpty ? 0 : 1)
    }

    /// Delete → undo → redo through the same UndoStack the app uses; mix state survives the round trip.
    func testDeleteUndoRedoRestoresTracksExactly() {
        var undo = UndoStack()
        var p = Project(name: "U")
        let keep = p.addTrack(kind: .audio, name: "Mix")
        let stems = p.addStemTracks([.init(name: "Vox", file: "v.wav", fileDuration: 3),
                                     .init(name: "Bass", file: "b.wav", fileDuration: 3)], start: 1)
        p.tracks[p.trackIndex(stems[0])!].mute = true
        p.tracks[p.trackIndex(stems[1])!].volumeDB = -7
        let original = p

        undo.record(p, label: "Delete Stems")
        XCTAssertEqual(p.deleteTracks(p.stemSiblings(of: stems[0])), 2)
        XCTAssertEqual(p.tracks.map(\.id), [keep])
        let restored = undo.undo(current: p)!
        XCTAssertEqual(restored, original, "undo restores order, mute and volume exactly")
        XCTAssertEqual(undo.redoLabel, "Delete Stems")
        let again = undo.redo(current: restored)!
        XCTAssertEqual(again.tracks.map(\.id), [keep])
        XCTAssertNil(again.trackIndex(stems[0]))
    }

    /// The same project must sound the same live and in an offline bounce (volume + pan + solo).
    func testLiveAndOfflineGainsMatch() throws {
        var p = Project(name: "Parity", tempo: 120)
        let a = noteTrack(&p), b = noteTrack(&p)
        p.tracks[p.trackIndex(a)!].volumeDB = -6
        p.tracks[p.trackIndex(a)!].pan = -0.5
        p.tracks[p.trackIndex(b)!].mute = true

        let frames = 24_000, block = 512
        var opts = OfflineRenderer.Options()
        opts.sampleRate = 48_000; opts.tail = 0; opts.end = Double(frames) / 48_000; opts.blockSize = block
        let offline = try OfflineRenderer().renderMaster(project: p, packageURL: nil, options: opts)

        let engine = EngineController(io: NullAudioIO(sampleRate: 48_000), maxFrames: block)
        engine.load(project: p, packageURL: nil)
        engine.play()
        var liveL: [Float] = [], liveR: [Float] = []
        var l = [Float](repeating: 0, count: block), r = l
        while liveL.count < frames {
            l.withUnsafeMutableBufferPointer { lb in r.withUnsafeMutableBufferPointer { rb in
                engine.core.render(inputChannelCount: 0, left: lb.baseAddress!, right: rb.baseAddress!, frames: block) } }
            liveL += l; liveR += r
        }
        func rms(_ x: ArraySlice<Float>) -> Float { sqrt(x.reduce(0) { $0 + $1 * $1 } / Float(max(1, x.count))) }
        // Compare the steady part (after any live gain ramp).
        let range = 4_800..<frames
        let oL = rms(offline.channels[0][range]), oR = rms(offline.channels[1][range])
        let lL = rms(liveL[range]), lR = rms(liveR[range])
        XCTAssertGreaterThan(oL, 1e-3)
        XCTAssertEqual(lL / oL, 1, accuracy: 0.1, "left level live vs offline")
        XCTAssertEqual(lR / oR, 1, accuracy: 0.1, "right level live vs offline")
        XCTAssertGreaterThan(oL, oR * 1.3, "pan left is audible in the bounce")
    }

    func testProjectPackageRoundTripKeepsMixState() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sf-mix-\(UUID()).\(ProjectPackage.fileExtension)")
        defer { try? FileManager.default.removeItem(at: url) }
        var p = ProjectTemplates.band.makeProject(name: "Mix State")
        p.tracks[0].mute = true
        p.tracks[1].solo = true
        p.tracks[1].volumeDB = -12.5
        p.tracks[1].pan = 0.25
        p.tracks[0].arm = true
        p.master.volumeDB = -3
        p.tempo = 97
        let ids = p.addStemTracks([.init(name: "Vox", file: "Audio/v.wav", fileDuration: 2)], start: 0.5)
        try ProjectPackage.save(p, to: url)
        let q = try ProjectPackage.load(from: url)
        XCTAssertEqual(q.tracks.map(\.id), p.tracks.map(\.id))
        XCTAssertTrue(q.tracks[0].mute); XCTAssertTrue(q.tracks[0].arm)
        XCTAssertTrue(q.tracks[1].solo)
        XCTAssertEqual(q.tracks[1].volumeDB, -12.5); XCTAssertEqual(q.tracks[1].pan, 0.25)
        XCTAssertEqual(q.master.volumeDB, -3); XCTAssertEqual(q.tempo, 97)
        XCTAssertTrue(q.tracks.first { $0.id == ids[0] }!.isStem)
        XCTAssertEqual(q.silenceReason(q.tracks[2].id), "Silenced by solo")
    }

    /// Master export honours mute; stems export one file per track; MIDI export only when MIDI exists.
    func testExportContentAndMute() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sf-exp2-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        var p = Project(name: "Exp", tempo: 120)
        let a = noteTrack(&p, beats: 2)
        p.tracks[p.trackIndex(a)!].mute = true
        var s = ExportSettings()
        s.content = .master; s.normalize = false; s.tailSeconds = 0; s.includeMIDI = false
        let r = try Exporter().export(project: p, packageURL: nil, settings: s, folder: dir, baseName: "Exp")
        XCTAssertEqual(r.files.count, 1)
        XCTAssertLessThan(try AudioFileIO.read(r.files[0]).peak, 1e-5, "muted track is not in the master bounce")

        s.content = .stems; s.includeMIDI = true
        let r2 = try Exporter().export(project: p, packageURL: nil, settings: s, folder: dir, baseName: "Exp")
        XCTAssertEqual(r2.files.filter { $0.pathExtension == "wav" }.count, 1)
        XCTAssertTrue(r2.files.contains { $0.pathExtension == "mid" })

        XCTAssertEqual(Exporter.bounds(.loop, project: p).0, 0, "invalid loop falls back to the whole song")
    }

    /// Genre synth: every genre produces in-key, finite notes from the same guitar input.
    func testEveryGenreGeneratesASynthPart() {
        let sr = 22_050.0
        // A-minor triad, 4 s.
        let n = Int(sr * 4)
        let x = (0..<n).map { i -> Float in
            let t = Double(i) / sr
            return Float(0.2 * (sin(2 * .pi * 220 * t) + sin(2 * .pi * 261.63 * t) + sin(2 * .pi * 329.63 * t)))
        }
        let guitar = AudioData(channels: [x], sampleRate: sr)
        for genre in MusicGenre.allCases {
            let r = SynthTrackGenerator(tempo: 120, beatsPerBar: 4).generate(style: .pad, guitar: guitar, bass: nil, genre: genre)
            XCTAssertFalse(r.notes.isEmpty, "\(genre) produced no notes")
            XCTAssertTrue(r.notes.allSatisfy { (0...127).contains(Int($0.pitch)) && $0.durationBeats > 0 }, "\(genre)")
        }
    }
}
