#if os(macOS)
import SwiftUI
import AppKit
import AVFoundation
import SFCore
import SFPresets

/// Microphone permission + library folder status, shared by the first-launch welcome screen and
/// the "Setup & Permissions" window.
public final class PermissionsModel: ObservableObject {
    public enum MicStatus: String { case notDetermined = "Not asked yet", authorized = "Allowed", denied = "Denied", restricted = "Restricted" }

    @Published public private(set) var mic: MicStatus = .notDetermined
    @Published public private(set) var folders: [(name: String, exists: Bool, writable: Bool)] = []
    @Published public private(set) var lastReport: FirstRunSetup.Report?
    /// Called on the main thread when microphone access becomes authorized.
    public var onAuthorized: (() -> Void)?

    public init() { refresh() }

    public func refresh() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: mic = .authorized
        case .denied: mic = .denied
        case .restricted: mic = .restricted
        default: mic = .notDetermined
        }
        folders = FirstRunSetup.folderStatus()
    }

    public var everythingReady: Bool { mic == .authorized && folders.allSatisfy { $0.exists && $0.writable } }

    public func requestMicrophone() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            DispatchQueue.main.async {
                self?.refresh()
                if granted { self?.onAuthorized?() }
            }
        }
    }

    public func createFolders() {
        lastReport = FirstRunSetup.run()
        refresh()
    }

    public static func openSettings(_ pane: String) {
        // Privacy panes; the same URLs work in System Settings (macOS 13+).
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
    public static func openSoundSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.sound") { NSWorkspace.shared.open(url) }
    }
    public static func openAudioMIDISetup() {
        let url = URL(fileURLWithPath: "/System/Applications/Utilities/Audio MIDI Setup.app")
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}

/// First-launch welcome: explains why microphone access is needed, then asks for it.
struct WelcomePermissionView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var permissions: PermissionsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "mic.circle.fill").font(.system(size: 44)).foregroundColor(.accentColor)
                VStack(alignment: .leading) {
                    Text("Welcome to StudioForge").font(.title.bold())
                    Text("Two quick steps and you're ready to record.").foregroundColor(.secondary)
                }
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Your library", systemImage: "folder").font(.headline)
                    Text("StudioForge keeps projects, recordings, exports, presets, impulse responses, models and samples in Music › StudioForge. These folders have been created for you.")
                    StatusRow(ok: permissions.folders.allSatisfy { $0.exists && $0.writable },
                              text: permissions.folders.allSatisfy { $0.exists } ? "Folders ready" : "Some folders are missing")
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Microphone & audio input", systemImage: "waveform").font(.headline)
                    Text("macOS asks once whether StudioForge may use audio input. This covers your microphone, guitar and any audio interface. Audio is only processed on your Mac and never uploaded.")
                    HStack {
                        StatusRow(ok: permissions.mic == .authorized, text: "Status: \(permissions.mic.rawValue)")
                        Spacer()
                        switch permissions.mic {
                        case .notDetermined: Button("Allow Audio Input…") { permissions.requestMicrophone() }.keyboardShortcut(.defaultAction)
                        case .denied, .restricted: Button("Open Privacy Settings") { PermissionsModel.openSettings("Privacy_Microphone") }
                        case .authorized: EmptyView()
                        }
                    }
                    if permissions.mic == .denied {
                        Text("Access was denied. Turn on StudioForge in System Settings › Privacy & Security › Microphone, then restart audio from Audio Settings.")
                            .font(.caption).foregroundColor(.orange)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Text("You can revisit this any time from Help › Setup & Permissions.").font(.caption).foregroundColor(.secondary)
                Spacer()
                Button(permissions.mic == .authorized ? "Continue" : "Skip for Now") { model.finishWelcome() }
                    .keyboardShortcut(permissions.mic == .authorized ? .defaultAction : .cancelAction)
            }
        }
        .padding(24).frame(width: 560)
        .onAppear { permissions.refresh() }
    }
}

/// "Setup & Permissions" screen: status of everything the installer/first launch configures.
public struct SetupPermissionsView: View {
    @ObservedObject var permissions: PermissionsModel
    public init(permissions: PermissionsModel) { self.permissions = permissions }

    public var body: some View {
        Form {
            Section("Microphone / audio input") {
                HStack {
                    StatusRow(ok: permissions.mic == .authorized, text: permissions.mic.rawValue)
                    Spacer()
                    if permissions.mic == .notDetermined { Button("Request Access") { permissions.requestMicrophone() } }
                    Button("Open Microphone Privacy") { PermissionsModel.openSettings("Privacy_Microphone") }
                }
            }
            Section("Library folders (Music › StudioForge)") {
                ForEach(permissions.folders.indices, id: \.self) { i in
                    let f = permissions.folders[i]
                    StatusRow(ok: f.exists && f.writable, text: f.name + (f.exists ? (f.writable ? "" : " — not writable") : " — missing"))
                }
                HStack {
                    Button("Create Missing Folders") { permissions.createFolders() }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([AppPaths.musicRoot]) }
                    Button("Application Support") { NSWorkspace.shared.activateFileViewerSelecting([AppPaths.support]) }
                }
                if let r = permissions.lastReport {
                    Text(r.ok ? "Created \(r.createdFolders.count) folder(s), copied \(r.copiedPresets) preset(s)." : r.errors.joined(separator: "\n"))
                        .font(.caption).foregroundColor(r.ok ? .secondary : .red)
                }
            }
            Section("Other settings") {
                HStack {
                    Button("Files & Folders Privacy") { PermissionsModel.openSettings("Privacy_FilesAndFolders") }
                    Button("Bluetooth (MIDI)") { PermissionsModel.openSettings("Privacy_Bluetooth") }
                    Button("Sound Settings") { PermissionsModel.openSoundSettings() }
                    Button("Audio MIDI Setup") { PermissionsModel.openAudioMIDISetup() }
                }
                Text("Unsigned build blocked by Gatekeeper? In Finder, Control-click StudioForge.app › Open, or allow it under Privacy & Security.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 560, minHeight: 480)
        .onAppear { permissions.refresh() }
        .toolbar { Button("Refresh") { permissions.refresh() } }
    }
}

struct StatusRow: View {
    let ok: Bool
    let text: String
    var body: some View {
        Label(text, systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            .foregroundColor(ok ? .green : .orange)
    }
}
#endif
