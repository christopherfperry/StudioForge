import XCTest
import Foundation
@testable import SFCore
@testable import SFProject
@testable import SFSeparation

/// 0.7.0: New Project settings and the Demucs spectral front end used by the neural separator.
final class ProjectAndSeparationTests: XCTestCase {

    // MARK: New Project

    func testNewProjectAppliesNameTempoAndTimeSignature() {
        let s = NewProjectSettings(name: "  My Song  ", tempo: 87.5, timeSignature: TimeSignature(6, 8))
        let p = ProjectTemplates.band.makeProject(settings: s, sampleRate: 44_100)
        XCTAssertEqual(p.name, "My Song")
        XCTAssertEqual(p.tempo, 87.5)
        XCTAssertEqual(p.timeSignature, TimeSignature(6, 8))
        XCTAssertEqual(p.sampleRate, 44_100)
        XCTAssertEqual(p.tracks.count, ProjectTemplates.band.tracks.count)
        XCTAssertEqual(p.loop.end, p.secondsPerBar * 4, accuracy: 1e-9)
        // Fresh track ids every time.
        let q = ProjectTemplates.band.makeProject(settings: s)
        XCTAssertTrue(Set(p.tracks.map(\.id)).isDisjoint(with: q.tracks.map(\.id)))
    }

    func testNewProjectNameAndTempoAreSanitised() {
        XCTAssertEqual(NewProjectSettings(name: "").cleanName, "Untitled")
        XCTAssertEqual(NewProjectSettings(name: "   ").cleanName, "Untitled")
        XCTAssertEqual(NewProjectSettings(name: "a/b:c").cleanName, "a-b-c")
        XCTAssertEqual(NewProjectSettings(name: "..hidden").cleanName, "hidden")
        XCTAssertEqual(NewProjectSettings(tempo: 5).clampedTempo, 30)
        XCTAssertEqual(NewProjectSettings(tempo: 999).clampedTempo, 300)
        XCTAssertEqual(NewProjectSettings(tempo: .nan).clampedTempo, 120)
    }

    func testNewProjectSavesAsUniqueSfprojAndReloads() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sf-new-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let p = ProjectTemplates.empty.makeProject(settings: NewProjectSettings(name: "Demo", tempo: 140))
        let u1 = ProjectPackage.uniqueURL(in: dir, baseName: p.name, ext: ProjectPackage.fileExtension)
        try ProjectPackage.save(p, to: u1)
        let u2 = ProjectPackage.uniqueURL(in: dir, baseName: p.name, ext: ProjectPackage.fileExtension)
        XCTAssertEqual(u1.lastPathComponent, "Demo.sfproj")
        XCTAssertEqual(u2.lastPathComponent, "Demo 2.sfproj")
        let back = try ProjectPackage.load(from: u1)
        XCTAssertEqual(back.name, "Demo")
        XCTAssertEqual(back.tempo, 140)
    }

    // MARK: Demucs spectral front end

    func testDemucsSpectralRoundTrip() {
        let d = DemucsSpectral()
        for n in [8000, 44_100, 343_980 / 20] {
            let x = (0..<n).map { i in 0.4 * sinf(Float(i) * 0.031) + 0.2 * sinf(Float(i) * 0.47 + 1) }
            let s = d.forward(x)
            XCTAssertEqual(s.frames, (n + 1023) / 1024)
            let y = d.inverse(re: s.re, im: s.im, frames: s.frames, length: n)
            var err: Float = 0
            // Like PyTorch's _ispec, the first/last ~1.5 frames are attenuated (the cropped edge frames
            // are zero but still count in the window envelope), so compare the interior.
            for i in 3072..<(n - 3072) { err = max(err, abs(x[i] - y[i])) }
            XCTAssertLessThan(err, 1e-3, "n=\(n)")
        }
    }

    /// Compares against PyTorch/Demucs (`HTDemucs._spec` / `_ispec`) when the reference vector
    /// produced by tools/convert_htdemucs_core.py's companion script is available.
    func testDemucsSpectralMatchesPyTorchReference() throws {
        let path = ProcessInfo.processInfo.environment["SF_DEMUCS_SPEC_VECTOR"] ?? "/home/ubuntu/demucs_conv/specvec.bin"
        guard let data = FileManager.default.contents(atPath: path) else { throw XCTSkip("reference vector not present") }
        let ints = data.prefix(8).withUnsafeBytes { Array($0.bindMemory(to: Int32.self)) }
        let n = Int(ints[0]), t = Int(ints[1])
        let floats = data.dropFirst(8).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let bins = 2048
        var o = 0
        func take(_ k: Int) -> [Float] { defer { o += k }; return Array(floats[o..<o + k]) }
        let x = take(n), re = take(bins * t), im = take(bins * t), mask = take(bins * t), y = take(n)
        let d = DemucsSpectral()
        let s = d.forward(x)
        XCTAssertEqual(s.frames, t)
        var e1: Float = 0
        for i in 0..<bins * t { e1 = max(e1, abs(s.re[i] - re[i]), abs(s.im[i] - im[i])) }
        XCTAssertLessThan(e1, 1e-4, "forward STFT differs from PyTorch")
        let mr = zip(re, mask).map { $0 * $1 }, mi = zip(im, mask).map { $0 * $1 }
        let yy = d.inverse(re: mr, im: mi, frames: t, length: n)
        var e2: Float = 0
        for i in 0..<n { e2 = max(e2, abs(yy[i] - y[i])) }
        XCTAssertLessThan(e2, 1e-4, "inverse STFT differs from PyTorch")
    }

    /// Replays recorded htdemucs_6s network outputs through the Swift pipeline (spectrogram input,
    /// inverse STFT, wave + spec sum) and compares with PyTorch's full `HTDemucs.forward` output.
    func testNeuralPipelineMatchesPyTorchHTDemucs() throws {
        let path = ProcessInfo.processInfo.environment["SF_DEMUCS_CORE_VECTOR"] ?? "/home/ubuntu/demucs_conv/core6s.bin"
        guard let data = FileManager.default.contents(atPath: path) else { throw XCTSkip("reference vector not present") }
        let ints = data.prefix(12).withUnsafeBytes { Array($0.bindMemory(to: Int32.self)) }
        let seg = Int(ints[0]), t = Int(ints[1]), sources = Int(ints[2])
        let floats = data.dropFirst(12).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        var o = 0
        func take(_ k: Int) -> [Float] { defer { o += k }; return Array(floats[o..<o + k]) }
        let mix = take(2 * seg), spec = take(4 * 2048 * t), specOut = take(sources * 4 * 2048 * t)
        let waveOut = take(sources * 2 * seg), full = take(sources * 2 * seg)

        final class Replay: DemucsCore {
            let segment: Int, sourceCount: Int, expectedSpec: [Float], out: (spec: [Float], wave: [Float])
            var specError: Float = 0
            init(_ seg: Int, _ s: Int, _ es: [Float], _ o: (spec: [Float], wave: [Float])) {
                segment = seg; sourceCount = s; expectedSpec = es; out = o
            }
            func run(mix: [Float], spec: [Float]) throws -> (spec: [Float], wave: [Float]) {
                for i in spec.indices { specError = max(specError, abs(spec[i] - expectedSpec[i])) }
                return out
            }
        }
        let core = Replay(seg, sources, spec, (specOut, waveOut))
        let sep = NeuralStemSeparator(core: core)
        let x = [Array(mix[0..<seg]), Array(mix[seg..<2 * seg])]
        let out = try sep.runPass(x, length: seg, keep: Array(0..<sources), isCancelled: { false }, chunkDone: {})
        XCTAssertLessThan(core.specError, 1e-4, "spectrogram fed to the network differs from PyTorch")
        var err: Float = 0, peak: Float = 0
        for s in 0..<sources { for c in 0..<2 { for i in 0..<seg {
            let ref = full[(s * 2 + c) * seg + i]
            err = max(err, abs(out[s][c][i] - ref)); peak = max(peak, abs(ref))
        } } }
        XCTAssertLessThan(err, 1e-4 + 1e-3 * peak, "Swift Demucs pipeline differs from PyTorch (peak \(peak))")
    }

    #if canImport(CoreML)
    /// macOS only: runs the published Core ML model on the reference mix and compares all six
    /// stems with PyTorch's HTDemucs output. CI sets SF_COREML_MODEL / SF_COREML_CHECK.
    func testCoreMLModelMatchesPyTorch() throws {
        let env = ProcessInfo.processInfo.environment
        guard let modelPath = env["SF_COREML_MODEL"], let checkPath = env["SF_COREML_CHECK"],
              let data = FileManager.default.contents(atPath: checkPath) else { throw XCTSkip("Core ML check files not provided") }
        let ints = data.prefix(8).withUnsafeBytes { Array($0.bindMemory(to: Int32.self)) }
        let seg = Int(ints[0]), sources = Int(ints[1])
        let floats = data.dropFirst(8).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let mix = Array(floats[0..<2 * seg]), full = Array(floats[2 * seg..<2 * seg + sources * 2 * seg])
        let core = try CoreMLDemucsCore(modelURL: URL(fileURLWithPath: modelPath))
        XCTAssertEqual(core.segment, seg)
        XCTAssertEqual(core.sourceCount, sources)
        let sep = NeuralStemSeparator(core: core)
        let out = try sep.runPass([Array(mix[0..<seg]), Array(mix[seg...])], length: seg, keep: Array(0..<sources),
                                  isCancelled: { false }, chunkDone: {})
        for s in 0..<sources {
            var errE: Double = 0, refE: Double = 0
            for c in 0..<2 { for i in 0..<seg {
                let r = Double(full[(s * 2 + c) * seg + i]), d = Double(out[s][c][i]) - r
                errE += d * d; refE += r * r
            } }
            let sdr = 10 * log10(max(refE, 1e-12) / max(errE, 1e-12))
            print("Core ML vs PyTorch, source \(DemucsModelContract.sources[s]): \(String(format: "%.1f", sdr)) dB")
            XCTAssertGreaterThan(sdr, 40, "Core ML output for \(DemucsModelContract.sources[s]) differs from PyTorch")
        }
    }
    #endif

    func testNeuralSourceOrderCoversSixStems() {
        XCTAssertEqual(Set(DemucsModelContract.sources), [.drums, .bass, .other, .vocals, .guitar, .piano])
    }
}
