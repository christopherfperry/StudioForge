import Foundation
import SFCore

/// I/O contract between `tools/convert_demucs_to_coreml.py` and the app.
public enum DemucsModelContract {
    public static let sampleRate: Double = 44_100
    public static let inputName = "mix"          // Float32 [1, 2, segment]
    public static let outputName = "sources"     // Float32 [1, 6, 2, segment]
    public static let defaultSegment = 343_980   // 7.8 s @ 44.1 kHz (htdemucs training segment)
    /// Source order of htdemucs_6s.
    public static let sources: [Stem] = [.drums, .bass, .other, .vocals, .guitar, .piano]
}

#if canImport(CoreML)
import CoreML

/// Runs the converted Demucs (htdemucs_6s) Core ML model over overlapping segments with
/// cross-fading, then optionally splits the drum stem into parts with `DrumPartSplitter`.
public final class CoreMLStemSeparator: StemSeparator {
    public let name = "Demucs htdemucs_6s (Core ML)"
    private let model: MLModel
    private let segment: Int

    public init(modelURL: URL, computeUnits: MLComputeUnits = .cpuAndGPU) throws {
        let config = MLModelConfiguration()
        // The Neural Engine is not reliable for this network; CPU+GPU is the safe default.
        config.computeUnits = computeUnits
        var url = modelURL
        if url.pathExtension.lowercased() != "mlmodelc" { url = try MLModel.compileModel(at: modelURL) }
        model = try MLModel(contentsOf: url, configuration: config)
        if let shape = model.modelDescription.inputDescriptionsByName[DemucsModelContract.inputName]?.multiArrayConstraint?.shape,
           shape.count == 3 {
            segment = shape[2].intValue
        } else {
            throw StudioForgeError.invalid("The model has no '\(DemucsModelContract.inputName)' input of shape [1, 2, N]. Re-convert it with tools/convert_demucs_to_coreml.py.")
        }
    }

    public func separate(_ audio: AudioData, options: SeparationOptions, progress: SeparationProgress,
                         isCancelled: () -> Bool) throws -> [Stem: AudioData] {
        let originalRate = audio.sampleRate
        var input = audio.stereo
        if abs(input.sampleRate - DemucsModelContract.sampleRate) > 0.5 {
            progress(0.01, "Resampling to 44.1 kHz")
            input = Resampler.resample(input, to: DemucsModelContract.sampleRate)
        }
        let n = input.frameCount
        let seg = segment
        let overlap = seg / 4
        let hop = seg - overlap
        let nSources = DemucsModelContract.sources.count
        var acc = [[[Float]]](repeating: [[Float]](repeating: [Float](repeating: 0, count: n), count: 2), count: nSources)
        var wsum = [Float](repeating: 0, count: n)
        // Cross-fade window: linear ramps over the overlap at both ends.
        var window = [Float](repeating: 1, count: seg)
        for i in 0..<overlap {
            let w = Float(i + 1) / Float(overlap + 1)
            window[i] = w; window[seg - 1 - i] = w
        }
        let chunks = max(1, Int(ceil(Double(max(0, n - overlap)) / Double(hop))))
        let inArr = try MLMultiArray(shape: [1, 2, NSNumber(value: seg)], dataType: .float32)
        let inStrides = inArr.strides.map { $0.intValue }
        let inPtr = inArr.dataPointer.bindMemory(to: Float.self, capacity: inArr.count)

        for c in 0..<chunks {
            if isCancelled() { throw StudioForgeError.cancelled }
            let start = c * hop
            for ch in 0..<2 {
                let src = input.channels[ch]
                for t in 0..<seg {
                    let idx = start + t
                    inPtr[ch * inStrides[1] + t * inStrides[2]] = idx < n ? src[idx] : 0
                }
            }
            let provider = try MLDictionaryFeatureProvider(dictionary: [DemucsModelContract.inputName: MLFeatureValue(multiArray: inArr)])
            let out = try model.prediction(from: provider)
            guard let arr = out.featureValue(for: DemucsModelContract.outputName)?.multiArrayValue, arr.shape.count == 4 else {
                throw StudioForgeError.invalid("Unexpected model output; expected '\(DemucsModelContract.outputName)' [1, 6, 2, N].")
            }
            let st = arr.strides.map { $0.intValue }
            let outLen = min(seg, arr.shape[3].intValue)
            let isFloat32 = arr.dataType == .float32
            let fptr = isFloat32 ? arr.dataPointer.bindMemory(to: Float.self, capacity: arr.count) : nil
            for s in 0..<min(nSources, arr.shape[1].intValue) {
                for ch in 0..<2 {
                    for t in 0..<outLen {
                        let idx = start + t
                        guard idx < n else { break }
                        let v: Float
                        if let p = fptr { v = p[s * st[1] + ch * st[2] + t * st[3]] }
                        else { v = arr[[0, NSNumber(value: s), NSNumber(value: ch), NSNumber(value: t)]].floatValue }
                        acc[s][ch][idx] += v * window[t]
                    }
                }
            }
            for t in 0..<outLen where start + t < n { wsum[start + t] += window[t] }
            progress(0.05 + 0.75 * Double(c + 1) / Double(chunks), "Separating (\(c + 1)/\(chunks))")
        }
        for s in 0..<nSources { for ch in 0..<2 { for i in 0..<n where wsum[i] > 1e-6 { acc[s][ch][i] /= wsum[i] } } }

        var result: [Stem: AudioData] = [:]
        for (i, stem) in DemucsModelContract.sources.enumerated() {
            var a = AudioData(channels: acc[i], sampleRate: DemucsModelContract.sampleRate)
            if abs(originalRate - a.sampleRate) > 0.5 { a = Resampler.resample(a, to: originalRate) }
            result[stem] = a
        }
        if options.splitDrums, let drums = result[.drums] {
            progress(0.85, "Splitting drum parts")
            for (k, v) in try DrumPartSplitter().split(drums, isCancelled: isCancelled) { result[k] = v }
        }
        // Keep only what was requested (plus drum parts if splitting).
        result = result.filter { options.stems.contains($0.key) || ($0.key.isDrumPart && options.splitDrums) }
        progress(1, "Done")
        return result
    }
}
#endif

/// Picks the best available separator: Core ML model if installed, otherwise the DSP fallback.
public enum SeparatorFactory {
    public static func best(manager: SeparationModelManager = .shared) -> StemSeparator {
        #if canImport(CoreML)
        if let url = manager.installedModelURL, let s = try? CoreMLStemSeparator(modelURL: url) { return s }
        #endif
        return DSPStemSeparator()
    }
}
