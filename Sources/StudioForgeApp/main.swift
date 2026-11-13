#if os(macOS)
import SwiftUI
import SFUI
import AppKit
import UniformTypeIdentifiers
import SFCore
import SFProject

extension Notification.Name { static let sfOpenDocuments = Notification.Name("SFOpenDocuments") }

/// Receives .sfproj packages double-clicked in Finder (CFBundleDocumentTypes in Info.plist).
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var pending: [URL] = []
    func application(_ application: NSApplication, open urls: [URL]) {
        let projects = urls.filter { ProjectPackage.readableExtensions.contains($0.pathExtension.lowercased()) }
        guard !projects.isEmpty else { return }
        AppDelegate.pending.append(contentsOf: projects)
        NotificationCenter.default.post(name: .sfOpenDocuments, object: nil)
    }
}

struct StudioForgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    private func openPending() {
        if let url = AppDelegate.pending.last { model.open(url) }
        AppDelegate.pending.removeAll()
    }

    var body: some Scene {
        WindowGroup("Fitzrovia Records DAW") {
            MainView(model: model).frame(minWidth: 1100, minHeight: 700)
                .onAppear { openPending() }
                .onReceive(NotificationCenter.default.publisher(for: .sfOpenDocuments)) { _ in openPending() }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") {
                    let p = NSOpenPanel(); p.canChooseDirectories = true
                    p.directoryURL = AppPaths.projects
                    p.allowedContentTypes = ProjectPackage.readableExtensions.compactMap { UTType(filenameExtension: $0) }
                    if p.runModal() == .OK, let u = p.url { model.open(u) }
                }.keyboardShortcut("o")
                Button("Save") { model.save() }.keyboardShortcut("s")
                Button("Save As…") { model.saveAs() }.keyboardShortcut("s", modifiers: [.command, .shift])
                Button("Import Audio…") {
                    let p = NSOpenPanel(); p.allowsMultipleSelection = true; p.allowedContentTypes = [.audio]
                    if p.runModal() == .OK { model.importAudio(p.urls, at: model.position) }
                }.keyboardShortcut("i")
                Button("Import & Split Audio…") { model.showSplitSheet = true }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                Menu("Generate Matching Synth") {
                    ForEach(AppModel.synthStyleMenu, id: \.id) { item in
                        Button(item.name) { model.generateMatchingSynth(styleID: item.id) }
                    }
                    Divider()
                    Picker("Genre", selection: $model.synthGenreID) {
                        ForEach(AppModel.genreMenu, id: \.id) { g in Text(g.name).tag(g.id) }
                    }
                }
            }
            CommandGroup(after: .toolbar) {
                Toggle("Show Playing Notes", isOn: $model.showNotes)
                    .keyboardShortcut("n", modifiers: [.command, .option])
            }
            CommandGroup(after: .help) {
                Button("Setup & Permissions…") { model.permissions.refresh(); model.showSetup = true }
                Button("Show Library in Finder") { NSWorkspace.shared.activateFileViewerSelecting([AppPaths.musicRoot]) }
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { model.undoAction() }.keyboardShortcut("z")
                Button("Redo") { model.redoAction() }.keyboardShortcut("z", modifiers: [.command, .shift])
            }
            CommandGroup(after: .pasteboard) {
                Divider()
                Button("Delete Selected Track / Stem") { model.deleteSelectedTrack() }
                    .keyboardShortcut(.delete, modifiers: [.command])
                    .disabled(model.selectedTrackID == nil)
                Button("Delete All Stems") { model.deleteAllStems() }
                    .disabled(!model.hasStems)
                Divider()
                Button("Mute / Unmute Selected Track") { model.toggleMuteSelected() }
                    .keyboardShortcut("m", modifiers: [.command, .control])
                    .disabled(model.selectedTrackID == nil)
                Button("Solo / Unsolo Selected Track") { model.toggleSoloSelected() }
                    .keyboardShortcut("s", modifiers: [.command, .control])
                    .disabled(model.selectedTrackID == nil)
                Button("Clear All Mute & Solo") { model.clearAllMuteSolo() }
                    .disabled(!model.project.tracks.contains { $0.mute || $0.solo })
                Divider()
                Button("Selected Track Volume Up 1 dB") { if let id = model.selectedTrackID { model.nudgeVolume(id, by: 1) } }
                    .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                Button("Selected Track Volume Down 1 dB") { if let id = model.selectedTrackID { model.nudgeVolume(id, by: -1) } }
                    .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                Button("Reset Selected Track Volume to 0 dB") { if let id = model.selectedTrackID { model.setVolume(id, 0) } }
            }
        }
    }
}

StudioForgeApp.main()
#else
print("Fitzrovia Records DAW is a macOS application (SwiftUI + CoreAudio). Build it on macOS 13+ with ./build.sh.")
print("On this platform you can run the portable unit tests with: swift test")
#endif
