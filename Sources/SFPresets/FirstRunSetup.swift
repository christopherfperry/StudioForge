import Foundation
import SFCore

/// Creates the user library (~/Music/Fitzrovia Records DAW/...) and Application Support folder, and copies
/// the bundled factory presets into `Presets/Factory` so users can browse and duplicate them in
/// Finder. Idempotent: existing files are never overwritten. Portable (unit-tested on Linux).
public enum FirstRunSetup {
    public struct Report: Equatable {
        public var createdFolders: [String] = []
        public var copiedPresets = 0
        public var errors: [String] = []
        public var ok: Bool { errors.isEmpty }
    }

    public static let completedKey = "SFFirstRunSetupVersion"
    public static let currentVersion = 1

    public static var isNeeded: Bool {
        UserDefaults.standard.integer(forKey: completedKey) < currentVersion
            || !FileManager.default.fileExists(atPath: AppPaths.musicRoot.appendingPathComponent("Projects").path)
    }

    /// Runs setup. `root` and `support` are injectable for tests.
    @discardableResult
    public static func run(root: URL = AppPaths.musicRoot,
                           support: URL = AppPaths.support,
                           factoryPresets: URL? = PresetLibrary.bundledPresetDirectory(),
                           markComplete: Bool = true) -> Report {
        let fm = FileManager.default
        var report = Report()
        for folder in [support] + AppPaths.libraryFolders.map({ root.appendingPathComponent($0, isDirectory: true) }) {
            if fm.fileExists(atPath: folder.path) { continue }
            do {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                report.createdFolders.append(folder.path)
            } catch { report.errors.append("Could not create \(folder.path): \(error.localizedDescription)") }
        }
        if let src = factoryPresets, fm.fileExists(atPath: src.path) {
            let dst = root.appendingPathComponent("Presets/Factory", isDirectory: true)
            let files = (fm.enumerator(at: src, includingPropertiesForKeys: nil)?.allObjects as? [URL]) ?? []
            for file in files where file.pathExtension.lowercased() == "json" {
                let rel = String(file.standardizedFileURL.path.dropFirst(src.standardizedFileURL.path.count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                let target = dst.appendingPathComponent(rel)
                if fm.fileExists(atPath: target.path) { continue }
                do {
                    try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.copyItem(at: file, to: target)
                    report.copiedPresets += 1
                } catch { report.errors.append("Could not copy preset \(rel): \(error.localizedDescription)") }
            }
        }
        let readme = root.appendingPathComponent("README.txt")
        if !fm.fileExists(atPath: readme.path) {
            let text = """
            Fitzrovia Records DAW library
            Projects/          your songs (.sfproj)
            Recordings/        recordings made before a project was saved
            Exports/           bounces, stems and MIDI exports
            Presets/User/      your presets (JSON, editable)
            Presets/Factory/   copies of the built-in presets (edits here are not loaded; duplicate into User/)
            ImpulseResponses/  WAV/AIFF impulse responses for the Convolution reverb
            Models/            stem-separation models (Core ML)
            Samples/           your samples
            """
            try? text.write(to: readme, atomically: true, encoding: .utf8)
        }
        if markComplete && report.ok { UserDefaults.standard.set(currentVersion, forKey: completedKey) }
        return report
    }

    /// Folder status for the Setup & Permissions screen.
    public static func folderStatus(root: URL = AppPaths.musicRoot) -> [(name: String, exists: Bool, writable: Bool)] {
        let fm = FileManager.default
        return AppPaths.libraryFolders.map { name in
            let p = root.appendingPathComponent(name).path
            return (name, fm.fileExists(atPath: p), fm.isWritableFile(atPath: p))
        }
    }
}
