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
        WindowGroup("StudioForge") {
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
                Button("Import Audio…") {
                    let p = NSOpenPanel(); p.allowsMultipleSelection = true; p.allowedContentTypes = [.audio]
                    if p.runModal() == .OK { model.importAudio(p.urls, at: model.position) }
                }.keyboardShortcut("i")
            }
            CommandGroup(after: .help) {
                Button("Setup & Permissions…") { model.permissions.refresh(); model.showSetup = true }
                Button("Show Library in Finder") { NSWorkspace.shared.activateFileViewerSelecting([AppPaths.musicRoot]) }
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { model.undoAction() }.keyboardShortcut("z")
                Button("Redo") { model.redoAction() }.keyboardShortcut("z", modifiers: [.command, .shift])
            }
        }
    }
}

StudioForgeApp.main()
#else
print("StudioForge is a macOS application (SwiftUI + CoreAudio). Build it on macOS 13+ with ./build.sh.")
print("On this platform you can run the portable unit tests with: swift test")
#endif
