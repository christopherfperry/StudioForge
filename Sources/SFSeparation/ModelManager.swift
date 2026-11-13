import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CoreML)
import CoreML
#endif
import SFCore

/// Manages the on-device stem separation model (Demucs htdemucs_6s converted to Core ML).
///
/// The model is ~1–2 GB uncompressed (FP32) and is not bundled with the app. It can be installed by:
///  1. **Download** from a URL you configure (Settings ▸ Stem Separation ▸ Model URL) — a .zip
///     containing `htdemucs_6s.mlpackage` or `htdemucs_6s.mlmodelc`;
///  2. **Import** a model you converted yourself with `tools/convert_demucs_to_coreml.py`.
/// Fitzrovia Records DAW does not ship or hard-code a third-party download location.
public final class SeparationModelManager: NSObject {
    public enum State: Equatable {
        case notInstalled
        case downloading(progress: Double)
        case installing
        case installed
        case failed(String)
    }

    public static let shared = SeparationModelManager()
    public static let modelName = "htdemucs_6s"
    public static let downloadURLDefaultsKey = "SFSeparationModelURL"
    /// Approximate size shown in the UI before download.
    public static let approximateDownloadSize = "≈ 1–2 GB"

    public private(set) var state: State = .notInstalled { didSet { notify() } }
    /// Called on the main queue whenever `state` changes.
    public var onChange: ((State) -> Void)?

    public let directory: URL
    private var session: URLSession?
    private var task: URLSessionDownloadTask?

    public init(directory: URL = AppPaths.models) {
        self.directory = directory
        super.init()
        state = installedModelURL != nil ? .installed : .notInstalled
    }

    public var compiledModelURL: URL { directory.appendingPathComponent("\(Self.modelName).mlmodelc") }
    public var packageModelURL: URL { directory.appendingPathComponent("\(Self.modelName).mlpackage") }

    /// URL of the installed model (compiled preferred), or nil.
    public var installedModelURL: URL? {
        let fm = FileManager.default
        if fm.fileExists(atPath: compiledModelURL.path) { return compiledModelURL }
        if fm.fileExists(atPath: packageModelURL.path) { return packageModelURL }
        return nil
    }

    public var isInstalled: Bool { installedModelURL != nil }

    public var configuredDownloadURL: URL? {
        get { UserDefaults.standard.string(forKey: Self.downloadURLDefaultsKey).flatMap { URL(string: $0) } }
        set { UserDefaults.standard.set(newValue?.absoluteString, forKey: Self.downloadURLDefaultsKey) }
    }

    // MARK: Download

    public func startDownload(from url: URL? = nil) {
        guard let src = url ?? configuredDownloadURL else {
            state = .failed("No model download URL configured. Set one in Settings, or import a converted model.")
            return
        }
        if case .downloading = state { return }
        state = .downloading(progress: 0)
        let s = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        session = s
        let t = s.downloadTask(with: src)
        task = t
        t.resume()
    }

    public func cancelDownload() {
        task?.cancel(); task = nil
        session?.invalidateAndCancel(); session = nil
        state = isInstalled ? .installed : .notInstalled
    }

    // MARK: Import / install

    /// Installs a model from a local .zip, .mlpackage or .mlmodelc. Runs synchronously (call off-main).
    public func importModel(from url: URL) throws {
        DispatchQueue.main.async { self.state = .installing }
        do {
            try install(from: url)
            DispatchQueue.main.async { self.state = .installed }
        } catch {
            DispatchQueue.main.async { self.state = .failed(error.localizedDescription) }
            throw error
        }
    }

    func install(from url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var source = url
        var tempDir: URL?
        defer { if let t = tempDir { try? fm.removeItem(at: t) } }
        if url.pathExtension.lowercased() == "zip" {
            let t = fm.temporaryDirectory.appendingPathComponent("sf-model-\(UUID().uuidString)")
            try fm.createDirectory(at: t, withIntermediateDirectories: true)
            tempDir = t
            try Self.unzip(url, to: t)
            guard let found = Self.findModel(in: t) else {
                throw StudioForgeError.invalid("The archive does not contain a .mlpackage or .mlmodelc model.")
            }
            source = found
        }
        switch source.pathExtension.lowercased() {
        case "mlmodelc":
            try? fm.removeItem(at: compiledModelURL)
            try fm.copyItem(at: source, to: compiledModelURL)
        case "mlpackage", "mlmodel":
            #if canImport(CoreML)
            let compiled = try MLModel.compileModel(at: source)
            try? fm.removeItem(at: compiledModelURL)
            try fm.moveItem(at: compiled, to: compiledModelURL)
            #else
            try? fm.removeItem(at: packageModelURL)
            try fm.copyItem(at: source, to: packageModelURL)
            #endif
        default:
            throw StudioForgeError.unsupportedFormat("Expected a .zip, .mlpackage or .mlmodelc file.")
        }
    }

    public func deleteModel() throws {
        let fm = FileManager.default
        for u in [compiledModelURL, packageModelURL] where fm.fileExists(atPath: u.path) { try fm.removeItem(at: u) }
        state = .notInstalled
    }

    static func findModel(in dir: URL) -> URL? {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { return nil }
        for case let u as URL in e {
            let ext = u.pathExtension.lowercased()
            if ext == "mlmodelc" || ext == "mlpackage" || ext == "mlmodel" { return u }
        }
        return nil
    }

    static func unzip(_ zip: URL, to dir: URL) throws {
        let p = Process()
        #if os(macOS)
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", zip.path, dir.path]
        #else
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = ["-q", zip.path, "-d", dir.path]
        #endif
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw StudioForgeError.io("Could not unpack the model archive (exit \(p.terminationStatus)).") }
    }

    private func notify() {
        let s = state
        if Thread.isMainThread { onChange?(s) } else { DispatchQueue.main.async { self.onChange?(s) } }
    }

    fileprivate func setState(_ s: State) {
        DispatchQueue.main.async { self.state = s }
    }
}

extension SeparationModelManager: URLSessionDownloadDelegate {
    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                           totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let p = totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : 0
        setState(.downloading(progress: p))
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temporary file is deleted when this method returns, so move it first.
        let fm = FileManager.default
        let ext = downloadTask.originalRequest?.url?.pathExtension.lowercased() ?? "zip"
        let dest = fm.temporaryDirectory.appendingPathComponent("sf-model-download-\(UUID().uuidString).\(ext.isEmpty ? "zip" : ext)")
        do {
            try fm.moveItem(at: location, to: dest)
        } catch {
            setState(.failed("Could not save download: \(error.localizedDescription)"))
            return
        }
        setState(.installing)
        DispatchQueue.global(qos: .userInitiated).async {
            defer { try? fm.removeItem(at: dest) }
            do { try self.install(from: dest); self.setState(.installed) }
            catch { self.setState(.failed(error.localizedDescription)) }
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            if (error as NSError).code == NSURLErrorCancelled { return }
            setState(.failed(error.localizedDescription))
        }
        session.finishTasksAndInvalidate()
    }
}
