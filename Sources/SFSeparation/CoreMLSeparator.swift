import Foundation
import SFCore

#if canImport(CoreML)
import CoreML

/// Runs the converted Demucs network (tools/convert_htdemucs_core.py) with Core ML.
public final class CoreMLDemucsCore: DemucsCore {
    private let model: MLModel
    public let segment: Int
    public let sourceCount: Int
    private let frames: Int

    public init(modelURL: URL, computeUnits: MLComputeUnits = .cpuAndGPU) throws {
        let config = MLModelConfiguration()
        // CPU+GPU: the Neural Engine runs this network in reduced precision.
        config.computeUnits = computeUnits
        var url = modelURL
        if url.pathExtension.lowercased() != "mlmodelc" { url = try MLModel.compileModel(at: modelURL) }
        model = try MLModel(contentsOf: url, configuration: config)
        let inputs = model.modelDescription.inputDescriptionsByName
        guard let mixShape = inputs[DemucsModelContract.mixInput]?.multiArrayConstraint?.shape, mixShape.count == 3,
              let specShape = inputs[DemucsModelContract.specInput]?.multiArrayConstraint?.shape, specShape.count == 4 else {
            throw StudioForgeError.invalid("This separation model is from an older version. Download the AI model again from the Split window.")
        }
        segment = mixShape[2].intValue
        frames = specShape[3].intValue
        let meta = model.modelDescription.metadata[.creatorDefinedKey] as? [String: String]
        sourceCount = meta?["sources"]?.split(separator: ",").count ?? DemucsModelContract.sources.count
    }

    public func run(mix: [Float], spec: [Float]) throws -> (spec: [Float], wave: [Float]) {
        let mixArr = try MLMultiArray(shape: [1, 2, NSNumber(value: segment)], dataType: .float32)
        let specArr = try MLMultiArray(shape: [1, 4, 2048, NSNumber(value: frames)], dataType: .float32)
        Self.fill(mixArr, from: mix)
        Self.fill(specArr, from: spec)
        let provider = try MLDictionaryFeatureProvider(dictionary: [
            DemucsModelContract.mixInput: MLFeatureValue(multiArray: mixArr),
            DemucsModelContract.specInput: MLFeatureValue(multiArray: specArr),
        ])
        let out = try model.prediction(from: provider)
        guard let s = out.featureValue(for: DemucsModelContract.specOutput)?.multiArrayValue,
              let w = out.featureValue(for: DemucsModelContract.waveOutput)?.multiArrayValue else {
            throw StudioForgeError.invalid("Unexpected separation model output.")
        }
        return (Self.flat(s), Self.flat(w))
    }

    /// Copies a row-major [Float] into a (possibly strided) Float32 array.
    static func fill(_ a: MLMultiArray, from src: [Float]) {
        let shape = a.shape.map { $0.intValue }, strides = a.strides.map { $0.intValue }
        let p = a.dataPointer.bindMemory(to: Float.self, capacity: a.count)
        if isContiguous(shape, strides) {
            src.withUnsafeBufferPointer { p.update(from: $0.baseAddress!, count: min(src.count, a.count)) }
            return
        }
        forEachIndex(shape) { linear, offset in p[offsetFor(offset, strides)] = src[linear] }
    }

    /// Row-major [Float] from a Float32 / Float64 / Float16 output array of any strides.
    static func flat(_ a: MLMultiArray) -> [Float] {
        let shape = a.shape.map { $0.intValue }, strides = a.strides.map { $0.intValue }
        let count = shape.reduce(1, *)
        var out = [Float](repeating: 0, count: count)
        if a.dataType == .float32 {
            let p = a.dataPointer.bindMemory(to: Float.self, capacity: a.count)
            if isContiguous(shape, strides) {
                out.withUnsafeMutableBufferPointer { $0.baseAddress!.update(from: p, count: count) }
            } else {
                forEachIndex(shape) { linear, idx in out[linear] = p[offsetFor(idx, strides)] }
            }
        } else {
            for i in 0..<count { out[i] = a[i].floatValue }   // slow path (not produced by our converter)
        }
        return out
    }

    private static func isContiguous(_ shape: [Int], _ strides: [Int]) -> Bool {
        var expected = 1
        for d in stride(from: shape.count - 1, through: 0, by: -1) {
            if shape[d] > 1 && strides[d] != expected { return false }
            expected *= shape[d]
        }
        return true
    }
    private static func offsetFor(_ idx: [Int], _ strides: [Int]) -> Int { zip(idx, strides).reduce(0) { $0 + $1.0 * $1.1 } }
    private static func forEachIndex(_ shape: [Int], _ body: (Int, [Int]) -> Void) {
        let count = shape.reduce(1, *)
        var idx = [Int](repeating: 0, count: shape.count)
        for linear in 0..<count {
            body(linear, idx)
            var d = shape.count - 1
            while d >= 0 { idx[d] += 1; if idx[d] < shape[d] { break }; idx[d] = 0; d -= 1 }
        }
    }
}
#endif

/// Picks the best available separator: the AI (Demucs) model if installed, otherwise DSP.
public enum SeparatorFactory {
    public static func best(manager: SeparationModelManager = .shared) -> StemSeparator {
        (try? neural(manager: manager)) ?? DSPStemSeparator()
    }

    /// The AI separator, or nil if no model is installed. Throws if the model cannot be loaded.
    public static func neural(manager: SeparationModelManager = .shared) throws -> StemSeparator? {
        #if canImport(CoreML)
        guard let url = manager.installedModelURL else { return nil }
        return NeuralStemSeparator(core: try CoreMLDemucsCore(modelURL: url))
        #else
        return nil
        #endif
    }
}
