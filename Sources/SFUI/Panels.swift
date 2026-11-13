#if os(macOS)
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import SFCore
import SFEngine
import SFProject
import SFPresets
import SFBeatGen
import SFSeparation
import SFExport

struct SheetFrame<Content: View>: View {
    let title: String
    let close: () -> Void
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text(title).font(.title2.bold()); Spacer(); Button("Close", action: close).keyboardShortcut(.cancelAction) }
            content
        }.padding(20).frame(minWidth: 560, minHeight: 380)
    }
}

// MARK: New song

/// File › New Project… (⌘N), toolbar "New Project", and the start window at launch.
struct NewProjectSheet: View {
    @ObservedObject var model: AppModel
    let close: () -> Void
    @State private var templates: [ProjectTemplate] = ProjectTemplates.builtIn + ProjectTemplates.userTemplates()
    @State private var templateID = ProjectTemplates.empty.id
    @State private var name = "Untitled"
    @State private var tempo: Double = 120
    @State private var signature = TimeSignature(4, 4)
    @State private var folder = AppPaths.defaultProjectsFolder
    @AppStorage("SFSaveNewProjectImmediately") private var saveNow = true

    private var template: ProjectTemplate { templates.first { $0.id == templateID } ?? ProjectTemplates.empty }

    private func pick(_ t: ProjectTemplate) {
        templateID = t.id; tempo = t.tempo; signature = t.timeSignature
    }

    private func create() {
        let s = NewProjectSettings(name: name, tempo: tempo, timeSignature: signature)
        if model.newProject(from: template, settings: s, saveIn: saveNow ? folder : nil) { close() }
    }

    var body: some View {
        SheetFrame(title: "New Project", close: close) {
            Text("Pick a starting point, name your project and press Create.").foregroundColor(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140))], spacing: 10) {
                ForEach(templates) { t in
                    let selected = t.id == templateID
                    Button { pick(t) } label: {
                        VStack(spacing: 5) {
                            Image(systemName: t.symbol).font(.title)
                            Text(t.name).font(.headline)
                            Text(t.summary).font(.caption).multilineTextAlignment(.center).foregroundColor(.secondary).lineLimit(3)
                        }
                        .frame(width: 140, height: 105).padding(4)
                        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.accentColor.opacity(0.25) : Color.gray.opacity(0.12)))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Color.accentColor : .clear, lineWidth: 2))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .help(t.summary)
                }
            }
            Form {
                TextField("Project name", text: $name)
                HStack {
                    TextField("Tempo (BPM)", value: $tempo, format: .number.precision(.fractionLength(0...2))).frame(maxWidth: 200)
                    Stepper("", value: $tempo, in: 30...300, step: 1).labelsHidden()
                    Picker("Time signature", selection: $signature) {
                        ForEach(NewProjectSettings.timeSignatures, id: \.self) { Text($0.description).tag($0) }
                    }.frame(maxWidth: 220)
                }
                HStack {
                    Toggle("Save to", isOn: $saveNow)
                    Text(folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.caption).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
                    Button("Choose…") {
                        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false
                        p.canCreateDirectories = true; p.directoryURL = folder; p.prompt = "Choose"
                        if p.runModal() == .OK, let u = p.url { folder = u; saveNow = true }
                    }.controlSize(.small)
                }
                .help("Saves the project as “\(NewProjectSettings(name: name).cleanName).sfproj” straight away so recordings go inside it")
            }
            HStack {
                Button("Open Project…") {
                    let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = true
                    panel.treatsFilePackagesAsDirectories = false
                    panel.directoryURL = AppPaths.projects
                    if panel.runModal() == .OK, let url = panel.url { model.open(url); if model.packageURL == url { close() } }
                }
                Menu("Open Recent") {
                    if RecentProjects.shared.urls.isEmpty { Text("No recent projects") }
                    ForEach(RecentProjects.shared.urls, id: \.self) { u in
                        Button(u.deletingPathExtension().lastPathComponent) { model.open(u); if model.packageURL == u { close() } }
                    }
                }.frame(maxWidth: 160)
                Toggle("Show at launch", isOn: $model.showNewProjectAtLaunch).controlSize(.small)
                Spacer()
                Button("Create") { create() }.keyboardShortcut(.defaultAction)
            }
            HStack {
                Spacer()
                Button("Save Current as Template") {
                    do {
                        try ProjectTemplates.saveAsTemplate(model.project, name: model.project.name)
                        model.status = "Saved “\(model.project.name)” as a template"
                        templates = ProjectTemplates.builtIn + ProjectTemplates.userTemplates()
                    } catch { model.status = "Could not save template: \(error.localizedDescription)" }
                }
            }
        }
    }
}

// MARK: Presets

struct PresetBrowser: View {
    @ObservedObject var model: AppModel
    let close: () -> Void
    @State private var search = ""
    @State private var category: PresetCategory?
    var body: some View {
        SheetFrame(title: "Preset Browser", close: close) {
            HStack {
                TextField("Search presets, artists, tags", text: $search)
                Picker("Category", selection: $category) {
                    Text("All").tag(PresetCategory?.none)
                    ForEach(PresetCategory.allCases) { Text($0.rawValue).tag(PresetCategory?.some($0)) }
                }.frame(width: 200)
                Button("Reload") { model.presets.reload() }.help("Re-read preset JSON files from disk")
                Button("Show Folder") { NSWorkspace.shared.open(model.presets.userDirectory) }
            }
            List(model.presets.search(search, category: category)) { p in
                HStack {
                    VStack(alignment: .leading) {
                        Text(p.name).font(.headline)
                        Text("\(p.artistStyle) · \(p.category.rawValue) — \(p.description)").font(.caption).foregroundColor(.secondary).lineLimit(2)
                    }
                    Spacer()
                    Button("Apply") {
                        if let id = model.selectedTrackID { model.apply(preset: p, to: id); close() } else { model.status = "Select a track first." }
                    }.disabled(model.selectedTrackID == nil)
                }
            }.frame(minHeight: 300)
            if !model.presets.loadErrors.isEmpty {
                Text(model.presets.loadErrors.joined(separator: "\n")).font(.caption).foregroundColor(.orange)
            }
            Text("Artist presets are original DSP approximations of a tonal character, not copies of any recording or plugin.")
                .font(.caption2).foregroundColor(.secondary)
        }
    }
}

struct TonePickerSheet: View {
    @ObservedObject var model: AppModel
    let close: () -> Void
    @State private var category: PresetCategory = .guitar
    @State private var artist = ""
    var body: some View {
        let picker = TonePicker(library: model.presets)
        let artists = picker.artists(for: category)
        SheetFrame(title: "Tone Picker", close: close) {
            Text("Choose an instrument and an artist style — Fitzrovia Records DAW loads a matching preset on the selected track.").foregroundColor(.secondary)
            Picker("Instrument", selection: $category) { ForEach(PresetCategory.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
            Picker("Artist style", selection: $artist) { ForEach(artists, id: \.self) { Text($0).tag($0) } }
            let options = picker.candidates(artist: artist, category: category)
            List(options) { p in
                HStack { Text(p.name); Spacer(); Button("Use") {
                    if let id = model.selectedTrackID { model.apply(preset: p, to: id); close() } else { model.status = "Select a track first." } } }
            }
            if let best = picker.pick(artist: artist, category: category) {
                Button("Use “\(best.name)”") { if let id = model.selectedTrackID { model.apply(preset: best, to: id); close() } }
                    .keyboardShortcut(.defaultAction).disabled(model.selectedTrackID == nil)
            }
        }
        .onAppear { if artist.isEmpty { artist = artists.first ?? "" } }
    }
}

// MARK: Beat generator

struct BeatGeneratorSheet: View {
    @ObservedObject var model: AppModel
    let close: () -> Void
    @State private var styleID = ""
    @State private var settings = BeatSettings()
    var body: some View {
        let styles = model.beatStyles.styles
        SheetFrame(title: "Beat Generator", close: close) {
            Picker("Style", selection: $styleID) { ForEach(styles) { Text("\($0.name) (\($0.genre))").tag($0.id) } }
            HStack { Text("Tempo"); Slider(value: $settings.tempo, in: 50...220); Text("\(Int(settings.tempo))").monospacedDigit() }
            Stepper("Bars: \(settings.bars)", value: $settings.bars, in: 1...64)
            HStack { Text("Swing"); Slider(value: $settings.swing, in: 0...0.5) }
            HStack { Text("Humanize"); Slider(value: $settings.humanize, in: 0...1) }
            HStack { Text("Complexity"); Slider(value: $settings.complexity, in: 0...1) }
            HStack { Text("Fills"); Slider(value: $settings.fills, in: 0...1) }
            HStack {
                Button("New Variation") { settings.seed &+= 1 }
                Button("Insert at Playhead") {
                    if let s = model.beatStyles.style(id: styleID) {
                        model.insertBeat(style: s, settings: settings, at: model.project.beats(forSeconds: model.position)); close()
                    }
                }.keyboardShortcut(.defaultAction)
                Button("Export MIDI…") { exportMIDI() }
                Spacer()
                Button("Match to Recording") { model.matchBeat(styleHint: nil); close() }
                    .help("Analyse the selected audio track (tempo, beats, key, energy) and drop a fitting beat")
            }
        }
        .onAppear {
            if styleID.isEmpty, let first = styles.first { styleID = first.id; settings.tempo = model.project.tempo }
        }
    }
    func exportMIDI() {
        guard let s = model.beatStyles.style(id: styleID) else { return }
        let beat = BeatGenerator().generate(style: s, settings: settings)
        let panel = NSSavePanel(); panel.nameFieldStringValue = "\(s.name).mid"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let clip = MIDIClip(name: s.name, startBeat: 0, lengthBeats: beat.lengthBeats, notes: beat.notes)
        do { try Exporter.writeMIDI(clip: clip, trackName: s.name, drums: true, tempo: settings.tempo, timeSignature: s.timeSignature, to: url) }
        catch { model.status = error.localizedDescription }
    }
}

// MARK: Import & split (stem separation)

final class SeparationJob: ObservableObject {
    @Published var progress = 0.0
    @Published var message = ""
    @Published var running = false
    @Published var modelState: SeparationModelManager.State = SeparationModelManager.shared.state
    private let lock = NSLock()
    private var _cancelled = false
    /// Read from the worker thread, written from the UI — guarded by a lock.
    var cancelled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _cancelled }
        set { lock.lock(); _cancelled = newValue; lock.unlock() }
    }
    init() { SeparationModelManager.shared.onChange = { [weak self] s in self?.modelState = s } }
}

/// "Import & Split Audio": pick a file (or the selected clip), choose which instruments / vocals /
/// drum parts to extract, and add each stem as an aligned track in one undo step.
struct StemSeparatorSheet: View {
    @ObservedObject var model: AppModel
    let close: () -> Void
    @StateObject private var job = SeparationJob()
    @State private var stems: Set<Stem> = Set(Stem.mainStems)
    @State private var splitDrums = true
    @State private var drumParts: Set<Stem> = Set(Stem.drumParts)
    @State private var addToProject = true
    @State private var muteSource = true
    @AppStorage("SFSplitQuality") private var quality = SeparationQuality.high.rawValue
    @AppStorage("SFReduceArtefacts") private var reduceArtefacts = true
    @AppStorage("SFArtefactStrength") private var artefactStrength = 0.5
    @AppStorage("SFGenerateSynth") private var generateSynth = false
    @AppStorage("SFSynthStyle") private var synthStyle = SynthStyle.pad.rawValue
    @AppStorage("SFSynthGenre") private var synthGenre = MusicGenre.auto.rawValue

    private var options: SeparationOptions {
        SeparationOptions(stems: stems, splitDrums: splitDrums && !drumParts.isEmpty,
                          quality: SeparationQuality(rawValue: quality) ?? .high,
                          artefactReduction: reduceArtefacts ? Float(artefactStrength) : 0)
    }
    private var canGenerateSynth: Bool { stems.contains(.guitar) || stems.contains(.bass) }

    private func toggle(_ s: Stem, in set: Binding<Set<Stem>>) -> Binding<Bool> {
        Binding(get: { set.wrappedValue.contains(s) },
                set: { on in if on { set.wrappedValue.insert(s) } else { set.wrappedValue.remove(s) } })
    }

    /// Explanation + one-click download, shown while only the basic separator is available.
    @ViewBuilder private var installAIModel: some View {
        Text("Using the basic built-in separator, which only roughly isolates instruments. For clean vocals, drums, bass, guitar and piano, download the AI model once (\(SeparationModelManager.approximateDownloadSize); it runs on your Mac, no internet needed afterwards).")
            .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
        HStack {
            Button { SeparationModelManager.shared.startDownload() } label: {
                Label("Download AI Model", systemImage: "arrow.down.circle")
            }.buttonStyle(.borderedProminent)
            Button("Import Model File...") {
                let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = true
                if p.runModal() == .OK, let u = p.url {
                    SeparationModelManager.shared.importModelInBackground(from: u) { err in
                        if let e = err { model.status = "Model import failed: \(e.localizedDescription)" }
                    }
                }
            }.help("Install a model .zip / .mlpackage made with tools/convert_htdemucs_core.py")
        }
    }

    var body: some View {
        SheetFrame(title: "Import & Split Audio", close: close) {
            GroupBox("Separation engine") {
                VStack(alignment: .leading, spacing: 6) {
                    switch job.modelState {
                    case .installed:
                        Label("AI separation (Demucs v4, 6 stems) is installed and will be used.", systemImage: "checkmark.seal.fill")
                            .foregroundColor(.green)
                    case .notInstalled:
                        installAIModel
                    case .failed(let e):
                        Text(e).foregroundColor(.orange).fixedSize(horizontal: false, vertical: true)
                        installAIModel
                    case .downloading(let p):
                        HStack {
                            ProgressView("Downloading AI model… \(Int(p * 100))%", value: p)
                            Button("Cancel") { SeparationModelManager.shared.cancelDownload() }
                        }
                    case .installing: ProgressView("Installing AI model (this can take a minute)…")
                    }
                    if job.modelState == .installed {
                        Button("Remove AI Model") {
                            do { try SeparationModelManager.shared.deleteModel() }
                            catch { model.status = "Could not remove the model: \(error.localizedDescription)" }
                        }.controlSize(.small)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(alignment: .top, spacing: 24) {
                GroupBox("Instruments & vocals") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Stem.mainStems) { s in Toggle(s == .drums ? "Drums (full kit)" : s.displayName, isOn: toggle(s, in: $stems)) }
                    }.frame(minWidth: 180, alignment: .leading)
                }
                GroupBox("Drum types") {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Split drums into parts", isOn: $splitDrums)
                        ForEach(Stem.drumParts) { s in
                            Toggle(s.displayName, isOn: toggle(s, in: $drumParts)).padding(.leading, 16).disabled(!splitDrums)
                        }
                    }.frame(minWidth: 180, alignment: .leading)
                }
            }
            HStack {
                Text("Presets:").font(.caption)
                Button("Vocals + 3") { stems = SeparationOptions.fourStem.stems; splitDrums = false }
                Button("Everything") { stems = Set(Stem.mainStems); splitDrums = true; drumParts = Set(Stem.drumParts) }
                Button("Drums only") { stems = []; splitDrums = true; drumParts = Set(Stem.drumParts) }
            }.controlSize(.small)
            GroupBox("Quality") {
                VStack(alignment: .leading, spacing: 6) {
                    Picker("Split quality", selection: $quality) {
                        ForEach(SeparationQuality.allCases) { q in Text(q.displayName).tag(q.rawValue) }
                    }.pickerStyle(.segmented)
                    HStack {
                        Toggle("Reduce artefacts", isOn: $reduceArtefacts)
                            .help("Smooths warbling, musical noise, faint bleed and harsh highs")
                        Slider(value: $artefactStrength, in: 0.1...1) { Text("Strength") }
                            .disabled(!reduceArtefacts).frame(maxWidth: 220)
                        Text("\(Int(artefactStrength * 100))%").font(.caption).monospacedDigit()
                    }
                    Text("Applies to the built-in separator. Higher strength sounds smoother but can dull detail.")
                        .font(.caption).foregroundColor(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Toggle("Generate a matching synth track", isOn: $generateSynth).disabled(!canGenerateSynth || !addToProject)
                Picker("", selection: $synthStyle) {
                    ForEach(SynthStyle.allCases) { s in Text(s.displayName).tag(s.rawValue) }
                }.labelsHidden().frame(maxWidth: 220).disabled(!generateSynth || !canGenerateSynth || !addToProject)
                Picker("Genre", selection: $synthGenre) {
                    ForEach(MusicGenre.allCases) { g in Text(g.displayName).tag(g.rawValue) }
                }.frame(maxWidth: 200).disabled(!generateSynth || !canGenerateSynth || !addToProject)
                    .help("Sets the synth's register, voicing and tone to suit the genre. Auto-detect listens to the guitar and bass.")
            }.help("Uses the guitar and bass stems to write chords / bass notes for a new synth track")
            Toggle("Add stems to the project as new tracks", isOn: $addToProject)
            Toggle("Mute the original track after splitting a clip", isOn: $muteSource).disabled(!addToProject)
            if job.running {
                ProgressView(job.message, value: job.progress)
                Button("Cancel") { job.cancelled = true }
            } else {
                HStack {
                    Button("Import Audio File & Split…") { chooseFile() }.keyboardShortcut(.defaultAction)
                    if let src = model.selectedClipSplitSource {
                        Button("Split Selected Clip “\(src.displayName)”") { run(src) }
                    }
                }.disabled(options.isEmpty)
                if options.isEmpty { Text("Choose at least one stem or drum part.").font(.caption).foregroundColor(.orange) }
            }
        }
    }

    func chooseFile() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.audio]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        run(AppModel.SplitSource(url: url, displayName: url.deletingPathExtension().lastPathComponent,
                                 start: 0, offset: 0, duration: nil, trackID: nil))
    }

    func run(_ source: AppModel.SplitSource) {
        let opts = options
        let wantedParts = drumParts
        let folder = model.stemOutputFolder
        let add = addToProject, mute = muteSource && source.trackID != nil
        let synth: SynthStyle? = add && generateSynth && canGenerateSynth ? SynthStyle(rawValue: synthStyle) ?? .pad : nil
        let genre = MusicGenre(rawValue: synthGenre) ?? .auto
        let tempo = model.project.tempo, bpb = model.project.timeSignature.numerator
        let job = self.job
        job.running = true; job.cancelled = false; job.progress = 0; job.message = "Decoding \(source.displayName)…"
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let audio = try AudioDecoding.decode(source.url)
                // AI model when installed; if it is installed but cannot load, say so instead of
                // silently producing the much rougher built-in result.
                let sep: StemSeparator
                do { sep = try SeparatorFactory.neural() ?? DSPStemSeparator() }
                catch { throw StudioForgeError.invalid("The AI model could not be loaded (\(error.localizedDescription)). Remove it and download it again in this window.") }
                var stems = try sep.separate(audio, options: opts, progress: { p, m in
                    DispatchQueue.main.async { job.progress = p; job.message = "\(sep.name): \(m)" }
                }, isCancelled: { job.cancelled })
                // Keep only what was ticked (separators may return extra stems, e.g. the full kit).
                stems = stems.filter { k, _ in k.isDrumPart ? (opts.splitDrums && wantedParts.contains(k)) : opts.stems.contains(k) }
                if job.cancelled { throw StudioForgeError.cancelled }
                let count = stems.count
                DispatchQueue.main.async { job.message = "Writing \(count) stems…" }
                let urls = try StemWriter.write(stems, baseName: source.displayName, to: folder)
                let durations = stems.mapValues { $0.duration }
                var part: SynthGenerationResult?
                if let style = synth {
                    DispatchQueue.main.async { job.message = "Generating \(style.trackName.lowercased())..." }
                    func clip(_ a: AudioData?) -> AudioData? {
                        a.map { AppModel.slice($0, offset: source.offset, duration: source.duration) }
                    }
                    part = AppModel.makeSynthPart(style: style, guitar: clip(stems[.guitar]), bass: clip(stems[.bass]),
                                                  tempo: tempo, beatsPerBar: bpb, genre: genre)
                }
                DispatchQueue.main.async {
                    job.running = false
                    if add { model.addSeparatedStems(urls, durations: durations, source: source, muteSource: mute) }
                    if let p = part { model.addGeneratedSynth(p, startSeconds: source.start) }
                    else if synth != nil { model.status += " — no clear notes for a synth track" }
                    if !add {
                        // Only reveal the files when they were not added to the project (previously
                        // this also ran after adding stems and overwrote the "Added N stem tracks" status).
                        model.status = "Wrote \(urls.count) stems to \(folder.path)"
                        NSWorkspace.shared.activateFileViewerSelecting(Array(urls.values))
                    }
                    close()
                }
            } catch {
                DispatchQueue.main.async {
                    job.running = false
                    if let e = error as? StudioForgeError, case .cancelled = e { model.status = "Split cancelled" }
                    else { model.status = "Split failed: \(error.localizedDescription)" }
                }
            }
        }
    }
}

// MARK: Export

struct ExportSheet: View {
    @ObservedObject var model: AppModel
    let close: () -> Void
    @State private var settings = ExportSettings()
    @State private var progress = 0.0
    @State private var running = false
    @State private var message = ""

    var body: some View {
        SheetFrame(title: "Export", close: close) {
            Picker("Format", selection: $settings.format) { ForEach(ExportFormat.allCases) { Text($0.displayName).tag($0) } }
            if let note = settings.format.requirementNote { Text(note).font(.caption).foregroundColor(AudioEncoders.isAvailable(settings.format) ? .secondary : .orange) }
            if settings.format.isLossy {
                Picker("Bitrate", selection: $settings.bitrateKbps) { ForEach([128, 192, 256, 320], id: \.self) { Text("\($0) kbps").tag($0) } }
            } else {
                Picker("Bit depth", selection: $settings.sampleFormat) {
                    ForEach(settings.format.supportedSampleFormats, id: \.self) { f in Text(f.isFloat ? "32-bit float" : "\(f.bitsPerSample)-bit").tag(f) }
                }
                Toggle("Dither (TPDF)", isOn: $settings.dither)
            }
            Picker("Sample rate", selection: Binding(get: { settings.sampleRate ?? model.project.sampleRate }, set: { settings.sampleRate = $0 })) {
                ForEach(ExportSettings.sampleRates, id: \.self) { Text("\(Int($0)) Hz").tag($0) }
            }
            Picker("Content", selection: $settings.content) { ForEach(ExportContent.allCases, id: \.self) { Text($0.displayName).tag($0) } }
            Picker("Range", selection: Binding(get: { settings.range == .loop ? 1 : 0 }, set: { settings.range = $0 == 1 ? .loop : .wholeProject })) {
                Text("Whole song").tag(0); Text("Loop region").tag(1)
            }
            Toggle("Normalize to \(String(format: "%.1f", settings.normalizePeakDB)) dBFS", isOn: $settings.normalize)
            Toggle("Also export MIDI (.mid)", isOn: $settings.includeMIDI)
            if running { ProgressView(message, value: progress) }
            Button("Export…") { run() }.keyboardShortcut(.defaultAction).disabled(running)
        }
    }

    func run() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.prompt = "Export Here"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        running = true
        let project = model.project, pkg = model.packageURL, s = settings
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let r = try Exporter().export(project: project, packageURL: pkg, settings: s, folder: folder, baseName: project.name,
                                              progress: { p, m in DispatchQueue.main.async { progress = p; message = m } })
                DispatchQueue.main.async {
                    running = false
                    model.status = "Exported \(r.files.count) file(s). " + r.warnings.joined(separator: " ")
                    NSWorkspace.shared.activateFileViewerSelecting(r.files)
                    close()
                }
            } catch {
                DispatchQueue.main.async { running = false; model.status = "Export failed: \(error.localizedDescription)" }
            }
        }
    }
}

// MARK: Audio settings

struct AudioSettingsSheet: View {
    @ObservedObject var model: AppModel
    let close: () -> Void
    var body: some View {
        let inputs = CoreAudioDevices.inputDevices()
        let outputs = CoreAudioDevices.outputDevices()
        SheetFrame(title: "Audio Settings", close: close) {
            Picker("Input device", selection: $model.audioConfig.inputDeviceUID) {
                Text("System default").tag(String?.none)
                ForEach(inputs, id: \.uid) { d in Text("\(d.name) (\(d.inputChannels) in)").tag(String?.some(d.uid)) }
            }
            Picker("Output device", selection: $model.audioConfig.outputDeviceUID) {
                Text("System default").tag(String?.none)
                ForEach(outputs, id: \.uid) { d in Text("\(d.name) (\(d.outputChannels) out)").tag(String?.some(d.uid)) }
            }
            Picker("Buffer size", selection: $model.audioConfig.bufferFrames) {
                ForEach([32, 64, 128, 256, 512, 1024], id: \.self) { Text("\($0) samples").tag($0) }
            }.help("Smaller = lower latency, more CPU. 32–64 for tracking, 512+ for mixing.")
            Picker("Sample rate", selection: $model.audioConfig.preferredSampleRate) {
                Text("Device setting").tag(Double?.none)
                ForEach([44_100.0, 48_000, 88_200, 96_000], id: \.self) { Text("\(Int($0)) Hz").tag(Double?.some($0)) }
            }
            Toggle("Enable audio input", isOn: $model.audioConfig.inputEnabled)
            Stepper("Manual record offset: \(model.engine.recordOffsetFrames) samples", value: Binding(
                get: { model.engine.recordOffsetFrames }, set: { model.engine.recordOffsetFrames = $0; model.objectWillChange.send() }), in: -4096...4096, step: 16)
            Text(model.engine.latencyDescription).font(.callout.monospacedDigit())
            Text("Tip: for zero-latency monitoring set a track's Monitor to Off and use your interface's direct monitoring. Recordings are latency compensated automatically.")
                .font(.caption).foregroundColor(.secondary)
            Text(model.io.statusMessage).font(.caption)
            Button("Apply & Restart Audio") { model.restartAudio() }.keyboardShortcut(.defaultAction)
        }
    }
}

// MARK: Onboarding

struct OnboardingView: View {
    @ObservedObject var model: AppModel
    @State private var page = 0
    let pages: [(String, String, String)] = [
        ("waveform", "Welcome to Fitzrovia Records DAW", "A simple multi-track studio. Click New Project (⌘N), pick Vocals, Guitar, Band or Beat + Synth, name it and click Create."),
        ("mic", "Record", "Arm a track (R button), pick its input in the Inspector, press R or the record button. Fitzrovia Records DAW always records the clean, dry signal — effects stay editable later."),
        ("slider.horizontal.3", "Low latency", "Open Audio Settings to choose your interface and a buffer of 32–128 samples while recording. Turn Monitor off to use your interface's direct monitoring."),
        ("paintpalette", "Tone Picker", "Choose an artist style and instrument, and Fitzrovia Records DAW loads a matching preset. Every preset is editable and saved as JSON."),
        ("metronome", "Beats & stems", "Generate drum beats by style, or let Fitzrovia Records DAW match a beat to your recording. Split any song into vocals, guitar, bass, piano and drum parts with the Split button (download the AI model there once for the cleanest stems)."),
        ("slider.vertical.3", "Mix & tidy up", "Click M to mute and S to solo (⌃⌘M / ⌃⌘S for the selected track). Drag the faders in the Mixer (X), double-click for 0 dB. Delete a track or stem with the trash button or ⌘⌫ — ⌘Z undoes anything."),
        ("square.and.arrow.up", "Export", "Bounce to WAV, AIFF, FLAC, AAC, ALAC, CAF (MP3/OGG with ffmpeg), export stems and MIDI."),
    ]
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: pages[page].0).font(.system(size: 48))
            Text(pages[page].1).font(.title.bold())
            Text(pages[page].2).multilineTextAlignment(.center).frame(width: 420)
            HStack {
                Button("Skip") { model.completeOnboarding() }
                Spacer()
                Text("\(page + 1) / \(pages.count)").foregroundColor(.secondary)
                Spacer()
                Button(page == pages.count - 1 ? "Get Started" : "Next") {
                    if page == pages.count - 1 { model.completeOnboarding() } else { page += 1 }
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(30).frame(width: 520, height: 340)
    }
}
#endif
