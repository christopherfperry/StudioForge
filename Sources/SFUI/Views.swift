#if os(macOS)
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import SFCore
import SFEffects
import SFInstruments
import SFEngine
import SFProject
import SFPresets
import SFBeatGen
import SFSeparation
import SFExport

/// Root window: transport on top, arrangement in the middle, inspector on the right, mixer below.
public struct MainView: View {
    @ObservedObject var model: AppModel
    @State private var sheet: Sheet?
    @State private var showMixer = true
    enum Sheet: String, Identifiable { case newSong, presets, tonePicker, beat, stems, export, audio; var id: String { rawValue } }

    public init(model: AppModel) { self.model = model }

    public var body: some View {
        VStack(spacing: 0) {
            TransportBar(model: model, sheet: $sheet, showMixer: $showMixer)
            Divider()
            HSplitView {
                ArrangementView(model: model).frame(minWidth: 500)
                InspectorView(model: model, sheet: $sheet).frame(minWidth: 260, idealWidth: 300, maxWidth: 380)
            }
            if showMixer { Divider(); MixerView(model: model).frame(height: 180) }
            HStack {
                Text(model.status).font(.caption).lineLimit(1)
                Spacer()
                Text(model.engine.latencyDescription).font(.caption.monospacedDigit())
                Text(String(format: "CPU %.0f%%", model.cpu * 100)).font(.caption.monospacedDigit())
                    .foregroundColor(model.cpu > 0.8 ? .red : .secondary)
            }.padding(.horizontal, 8).padding(.vertical, 3)
        }
        .preferredColorScheme(.dark)
        .sheet(item: $sheet) { s in
            switch s {
            case .newSong: NewSongSheet(model: model) { sheet = nil }
            case .presets: PresetBrowser(model: model) { sheet = nil }
            case .tonePicker: TonePickerSheet(model: model) { sheet = nil }
            case .beat: BeatGeneratorSheet(model: model) { sheet = nil }
            case .stems: StemSeparatorSheet(model: model) { sheet = nil }
            case .export: ExportSheet(model: model) { sheet = nil }
            case .audio: AudioSettingsSheet(model: model) { sheet = nil }
            }
        }
        .sheet(isPresented: $model.showOnboarding) { OnboardingView(model: model) }
        .background(EmptyView().sheet(isPresented: $model.showWelcome) {
            WelcomePermissionView(model: model, permissions: model.permissions).interactiveDismissDisabled()
        })
        .background(EmptyView().sheet(isPresented: $model.showSetup) {
            VStack(spacing: 0) {
                SetupPermissionsView(permissions: model.permissions)
                HStack { Spacer(); Button("Done") { model.showSetup = false }.keyboardShortcut(.defaultAction) }.padding()
            }
        })
    }
}

// MARK: Transport

struct TransportBar: View {
    @ObservedObject var model: AppModel
    @Binding var sheet: MainView.Sheet?
    @Binding var showMixer: Bool

    var body: some View {
        HStack(spacing: 10) {
            Button { sheet = .newSong } label: { Label("New Song", systemImage: "plus.square") }.help("Start a new song from a template")
            Divider().frame(height: 22)
            Button(action: model.rewind) { Image(systemName: "backward.end.fill") }.help("Go to start (Return)")
            Button(action: model.togglePlay) { Image(systemName: model.isPlaying ? "stop.fill" : "play.fill") }
                .keyboardShortcut(.space, modifiers: []).help("Play / Stop (Space)")
            Button(action: model.record) { Image(systemName: "record.circle").foregroundColor(model.isRecording ? .red : .primary) }
                .keyboardShortcut("r", modifiers: []).help("Record armed tracks (R)")
            Text(timeString(model.position)).font(.system(.title3, design: .monospaced)).frame(width: 110)
            Stepper(value: Binding(get: { model.project.tempo }, set: { v in model.edit("Tempo") { $0.tempo = v } }), in: 30...300, step: 1) {
                Text("\(Int(model.project.tempo)) BPM").monospacedDigit()
            }.help("Project tempo")
            Text(model.project.timeSignature.description)
            Toggle("Loop", isOn: Binding(get: { model.project.loop.enabled }, set: { v in model.edit("Loop") { $0.loop.enabled = v } }))
                .toggleStyle(.button).keyboardShortcut("l", modifiers: []).help("Loop region (L)")
            Toggle("Punch", isOn: Binding(get: { model.project.punch.enabled }, set: { v in model.edit("Punch") { $0.punch.enabled = v } }))
                .toggleStyle(.button).help("Punch in/out region")
            Toggle("Click", isOn: Binding(get: { model.project.metronome.enabled }, set: { v in model.edit("Metronome") { $0.metronome.enabled = v } }))
                .toggleStyle(.button).keyboardShortcut("k", modifiers: []).help("Metronome (K)")
            Spacer()
            Button("Tone Picker") { sheet = .tonePicker }.help("Pick an artist + instrument and get a preset")
            Button("Presets") { sheet = .presets }
            Button("Beat") { sheet = .beat }.help("Generate or match a drum beat")
            Button("Stems") { sheet = .stems }.help("Split a song into stems")
            Button("Export") { sheet = .export }.keyboardShortcut("e", modifiers: [.command])
            Button { sheet = .audio } label: { Image(systemName: "slider.horizontal.3") }.help("Audio device & latency settings")
            Toggle(isOn: $showMixer) { Image(systemName: "dial.medium") }.toggleStyle(.button).help("Show mixer (X)")
                .keyboardShortcut("x", modifiers: [])
        }
        .padding(8)
    }

    func timeString(_ t: Double) -> String {
        let m = Int(t) / 60, s = t - Double(m * 60)
        return String(format: "%02d:%06.3f", m, s)
    }
}

// MARK: Arrangement

struct ArrangementView: View {
    @ObservedObject var model: AppModel
    @State private var dropTargeted = false

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(model.project.tracks) { track in
                        TrackLane(model: model, track: track)
                    }
                    HStack {
                        Button("+ Audio") { model.addTrack(.audio) }
                        Button("+ Instrument") { model.addTrack(.instrument) }
                        Button("+ Drums") { model.addTrack(.drums) }
                    }.padding(8)
                }
                Rectangle().fill(Color.red).frame(width: 1)
                    .offset(x: 170 + model.position * model.zoom)
                    .allowsHitTesting(false)
            }
            .frame(minWidth: 170 + max(120, model.project.contentEnd + 30) * model.zoom, alignment: .topLeading)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .overlay(dropTargeted ? RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: 3) : nil)
        .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { DispatchQueue.main.async { model.importAudio([url], at: model.position) } }
                }
            }
            return true
        }
        .toolbar {
            ToolbarItemGroup {
                Button { model.zoom = max(5, model.zoom / 1.5) } label: { Image(systemName: "minus.magnifyingglass") }.keyboardShortcut("-", modifiers: [.command])
                Button { model.zoom = min(800, model.zoom * 1.5) } label: { Image(systemName: "plus.magnifyingglass") }.keyboardShortcut("=", modifiers: [.command])
                Button("Split") { model.splitAtPlayhead() }.keyboardShortcut("s", modifiers: []).help("Split clips at the playhead (S)")
            }
        }
    }
}

struct TrackLane: View {
    @ObservedObject var model: AppModel
    let track: Track

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(track.name).font(.headline).lineLimit(1)
                HStack(spacing: 4) {
                    flag("M", track.mute, .yellow) { v in model.edit("Mute") { p in p.tracks[p.trackIndex(track.id)!].mute = v } }
                    flag("S", track.solo, .green) { v in model.edit("Solo") { p in p.tracks[p.trackIndex(track.id)!].solo = v } }
                    if track.kind == .audio || track.instrument != nil {
                        flag("R", track.arm, .red) { v in model.edit("Arm") { p in p.tracks[p.trackIndex(track.id)!].arm = v } }
                    }
                }
            }
            .frame(width: 162, alignment: .leading).padding(4)
            .background(model.selectedTrackID == track.id ? Color.accentColor.opacity(0.25) : Color(nsColor: .controlBackgroundColor))
            .onTapGesture { model.selectedTrackID = track.id }
            ZStack(alignment: .topLeading) {
                Color(nsColor: .textBackgroundColor).opacity(0.15)
                ForEach(track.audioClips) { clip in
                    ClipView(model: model, trackID: track.id, clip: clip)
                        .frame(width: max(4, clip.duration * model.zoom), height: track.height - 8)
                        .offset(x: clip.start * model.zoom, y: 4)
                }
                ForEach(track.midiClips) { clip in
                    MIDIClipView(clip: clip)
                        .frame(width: max(4, model.project.seconds(forBeat: clip.lengthBeats) * model.zoom), height: track.height - 8)
                        .offset(x: model.project.seconds(forBeat: clip.startBeat) * model.zoom, y: 4)
                }
            }
            .frame(height: track.height)
            .contentShape(Rectangle())
            .onTapGesture { model.selectedTrackID = track.id }
        }
    }

    func flag(_ title: String, _ on: Bool, _ color: Color, _ set: @escaping (Bool) -> Void) -> some View {
        Button(title) { set(!on) }
            .buttonStyle(.plain).frame(width: 22, height: 18)
            .background(on ? color : Color.gray.opacity(0.3)).foregroundColor(on ? .black : .primary).cornerRadius(3)
    }
}

struct ClipView: View {
    @ObservedObject var model: AppModel
    let trackID: UUID
    let clip: AudioClip
    @State private var peaks: WaveformPeaks?
    @State private var drag: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 4).fill(clip.isWetCapture ? Color.purple.opacity(0.5) : Color.blue.opacity(0.55))
                if let peaks {
                    Canvas { ctx, size in
                        let cols = peaks.columns(start: clip.offset, length: clip.duration, columns: max(1, Int(size.width)))
                        var path = Path()
                        let mid = size.height / 2
                        for (x, c) in cols.enumerated() {
                            path.move(to: CGPoint(x: CGFloat(x), y: mid - CGFloat(c.max) * mid))
                            path.addLine(to: CGPoint(x: CGFloat(x), y: mid - CGFloat(c.min) * mid))
                        }
                        ctx.stroke(path, with: .color(.white.opacity(0.8)), lineWidth: 1)
                    }
                }
                Text(clip.name).font(.caption2).padding(3).lineLimit(1)
                // Trim handles
                HStack {
                    handle { dx in model.edit("Trim Start") { p in
                        if let (t, c) = p.locateAudioClip(clip.id) { p.tracks[t].audioClips[c] = ClipEditing.trimStart(clip, to: clip.start + dx / model.zoom) } } }
                    Spacer()
                    handle { dx in model.edit("Trim End") { p in
                        if let (t, c) = p.locateAudioClip(clip.id) { p.tracks[t].audioClips[c] = ClipEditing.trimEnd(clip, to: clip.end + dx / model.zoom) } } }
                }
            }
            .offset(x: drag)
            .gesture(DragGesture(minimumDistance: 3)
                .onChanged { drag = $0.translation.width }
                .onEnded { v in
                    drag = 0
                    model.edit("Move Clip") { p in
                        if let (t, c) = p.locateAudioClip(clip.id) {
                            p.tracks[t].audioClips[c] = ClipEditing.move(clip, to: max(0, clip.start + v.translation.width / model.zoom))
                        }
                    }
                })
            .contextMenu {
                Button("Split at Playhead") { model.edit("Split") { p in p.splitClips(at: model.position, trackIDs: [trackID]) } }
                Button("Fade In 50 ms") { setFades(fadeIn: 0.05) }
                Button("Fade Out 500 ms") { setFades(fadeOut: 0.5) }
                Button(clip.muted ? "Unmute Clip" : "Mute Clip") { model.edit("Mute Clip") { p in
                    if let (t, c) = p.locateAudioClip(clip.id) { p.tracks[t].audioClips[c].muted.toggle() } } }
                Divider()
                Button("Delete", role: .destructive) { model.edit("Delete Clip") { $0.deleteClip(clip.id) } }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .onAppear {
            let url = ProjectPackage.resolve(clip.file, in: model.packageURL)
            let folder = model.packageURL?.appendingPathComponent(ProjectPackage.peaksFolder)
            PeakCache.shared.request(url, peaksFolder: folder) { p in DispatchQueue.main.async { peaks = p } }
        }
    }

    func setFades(fadeIn: Double? = nil, fadeOut: Double? = nil) {
        model.edit("Fade") { p in
            if let (t, c) = p.locateAudioClip(clip.id) { p.tracks[t].audioClips[c] = ClipEditing.setFades(clip, fadeIn: fadeIn, fadeOut: fadeOut) }
        }
    }

    func handle(_ onEnd: @escaping (Double) -> Void) -> some View {
        Rectangle().fill(Color.white.opacity(0.25)).frame(width: 6)
            .gesture(DragGesture().onEnded { onEnd(Double($0.translation.width)) })
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
    }
}

struct MIDIClipView: View {
    let clip: MIDIClip
    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4).fill(Color.orange.opacity(0.55))
            Canvas { ctx, size in
                guard clip.lengthBeats > 0 else { return }
                for n in clip.notes {
                    let x = CGFloat(n.startBeat / clip.lengthBeats) * size.width
                    let y = size.height - CGFloat(n.pitch - 24) / 80 * size.height
                    ctx.fill(Path(CGRect(x: x, y: y, width: max(2, CGFloat(n.durationBeats / clip.lengthBeats) * size.width), height: 2)), with: .color(.white))
                }
            }
            Text(clip.name).font(.caption2).padding(3)
        }
    }
}

// MARK: Inspector (track settings, input, effects with generic controls)

struct InspectorView: View {
    @ObservedObject var model: AppModel
    @Binding var sheet: MainView.Sheet?

    var body: some View {
        ScrollView {
            if let id = model.selectedTrackID, let track = model.project.tracks.first(where: { $0.id == id }) {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Name", text: model.binding(track: id, \.name, label: "Rename")!).font(.headline)
                    Text(track.kind.displayName).foregroundColor(.secondary)
                    if track.kind == .audio {
                        GroupBox("Input & recording") {
                            Stepper("Input channel: \(track.input.firstChannel + 1)", value: model.binding(track: id, \.input.firstChannel, label: "Input")!, in: 0...63)
                            Picker("Channels", selection: model.binding(track: id, \.input.channelCount, label: "Input")!) {
                                Text("Mono").tag(1); Text("Stereo").tag(2)
                            }
                            Picker("Monitor", selection: model.binding(track: id, \.monitor, label: "Monitor")!) {
                                Text("Off (direct monitoring)").tag(MonitorMode.off); Text("Auto").tag(MonitorMode.auto); Text("On").tag(MonitorMode.on)
                            }
                            Toggle("Record clean (dry) — always on", isOn: .constant(true)).disabled(true)
                                .help("Fitzrovia Records DAW always records the dry input; effects are only applied on playback")
                            Toggle("Also capture wet (with effects)", isOn: model.binding(track: id, \.captureWet, label: "Capture Wet")!)
                        }
                    }
                    HStack {
                        Button("Presets…") { sheet = .presets }
                        Button("Tone Picker…") { sheet = .tonePicker }
                        Button("Save as Preset") { savePreset(track) }
                    }
                    GroupBox("Inserts") {
                        ForEach(track.effects) { fx in EffectEditor(model: model, trackID: id, state: fx) }
                        Menu("Add Effect") {
                            ForEach(EffectCategory.allCases, id: \.self) { cat in
                                let items = EffectRegistry.shared.all.filter { $0.category == cat }
                                if !items.isEmpty {
                                    Menu(cat.rawValue) {
                                        ForEach(items, id: \.typeID) { d in
                                            Button(d.name) { model.edit("Add \(d.name)") { p in
                                                if let i = p.trackIndex(id) { p.tracks[i].effects.append(EffectState(type: d.typeID)) } } }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    if track.instrument != nil {
                        GroupBox("Instrument") { InstrumentEditor(model: model, track: track) }
                    }
                    Button("Delete Track", role: .destructive) { model.edit("Delete Track") { $0.tracks.removeAll { $0.id == id } } }
                }.padding(10)
            } else {
                Text("Select a track to edit its input, effects and instrument.").foregroundColor(.secondary).padding()
            }
        }
    }

    func savePreset(_ t: Track) {
        let p = Preset.from(track: t, name: "\(t.name) Preset", category: t.kind == .drums ? .drums : (t.kind == .instrument ? .synth : .other), artistStyle: "User")
        do { _ = try model.presets.save(p); model.presets.reload(); model.status = "Saved preset \(p.name)" }
        catch { model.status = "Preset save failed: \(error.localizedDescription)" }
    }
}

struct EffectEditor: View {
    @ObservedObject var model: AppModel
    let trackID: UUID
    let state: EffectState
    @State private var expanded = false

    var body: some View {
        let specs = EffectRegistry.shared.make(state.type)?.parameters.specs ?? []
        DisclosureGroup(isExpanded: $expanded) {
            ForEach(specs, id: \.id) { spec in
                ParameterControl(spec: spec, value: state.params[spec.id] ?? spec.defaultValue) { v in
                    model.setParameter(track: trackID, effect: state.id, id: spec.id, value: v)
                }
            }
            Slider(value: Binding(get: { Double(state.mix) }, set: { v in update { $0.mix = Float(v) } }), in: 0...1) { Text("Mix") }
            if state.type == "reverb.convolution" {
                Button("Load IR File…") {
                    let panel = NSOpenPanel(); panel.allowedContentTypes = [.audio]
                    if panel.runModal() == .OK, let url = panel.url { update { $0.extra["irPath"] = url.path; $0.params["irType"] = 4 } }
                }
            }
        } label: {
            HStack {
                Toggle("", isOn: Binding(get: { !state.bypassed }, set: { v in update { $0.bypassed = !v } })).labelsHidden()
                    .help("Bypass")
                Text(EffectRegistry.shared.descriptor(state.type)?.name ?? state.type)
                Spacer()
                Button { model.edit("Remove Effect") { p in if let i = p.trackIndex(trackID) { p.tracks[i].effects.removeAll { $0.id == state.id } } } }
                    label: { Image(systemName: "xmark.circle") }.buttonStyle(.plain)
            }
        }
    }

    func update(_ f: @escaping (inout EffectState) -> Void) {
        model.edit("Edit Effect") { p in
            if let i = p.trackIndex(trackID), let e = p.tracks[i].effects.firstIndex(where: { $0.id == state.id }) { f(&p.tracks[i].effects[e]) }
        }
    }
}

struct InstrumentEditor: View {
    @ObservedObject var model: AppModel
    let track: Track
    var body: some View {
        let st = track.instrument!
        let specs = InstrumentRegistry.shared.make(st.type)?.parameters.specs ?? []
        VStack(alignment: .leading) {
            Picker("Type", selection: Binding(get: { st.type }, set: { v in edit { $0 = InstrumentState(type: v) } })) {
                ForEach(InstrumentRegistry.shared.all, id: \.typeID) { Text($0.name).tag($0.typeID) }
            }
            ForEach(specs.prefix(60), id: \.id) { spec in
                ParameterControl(spec: spec, value: st.params[spec.id] ?? spec.defaultValue) { v in
                    model.engine.setInstrumentParameter(track: track.id, id: spec.id, value: v)
                    edit { $0.params[spec.id] = v }
                }
            }
            HStack {   // on-screen keyboard (one octave) for auditioning
                ForEach(0..<12, id: \.self) { i in
                    Button(" ") {}.buttonStyle(.plain).frame(width: 14, height: 30)
                        .background([1, 3, 6, 8, 10].contains(i) ? Color.black : Color.white).border(Color.gray)
                        .onLongPressGesture(minimumDuration: 0, pressing: { down in model.engine.uiNote(60 + i, velocity: 100, on: down) }, perform: {})
                }
            }
        }
    }
    func edit(_ f: @escaping (inout InstrumentState) -> Void) {
        model.edit("Edit Instrument") { p in if let i = p.trackIndex(track.id), p.tracks[i].instrument != nil { f(&p.tracks[i].instrument!) } }
    }
}

/// Generic control for any ParameterSpec (choice → picker, toggle → switch, else slider).
struct ParameterControl: View {
    let spec: ParameterSpec
    let value: Float
    let onChange: (Float) -> Void
    var body: some View {
        if let choices = spec.choices {
            Picker(spec.name, selection: Binding(get: { Int(value.rounded()) }, set: { onChange(Float($0)) })) {
                ForEach(Array(choices.enumerated()), id: \.offset) { Text($0.element).tag($0.offset) }
            }
        } else if spec.unit == .toggle {
            Toggle(spec.name, isOn: Binding(get: { value >= 0.5 }, set: { onChange($0 ? 1 : 0) }))
        } else {
            VStack(alignment: .leading, spacing: 0) {
                HStack { Text(spec.name).font(.caption); Spacer(); Text(spec.display(value)).font(.caption.monospacedDigit()) }
                Slider(value: Binding(get: { Double(spec.normalized(value)) }, set: { onChange(spec.value(fromNormalized: Float($0))) }), in: 0...1)
            }
        }
    }
}

// MARK: Mixer

struct MixerView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(model.project.tracks) { t in
                    VStack {
                        Text(t.name).font(.caption).lineLimit(1).frame(width: 70)
                        Slider(value: model.binding(track: t.id, \.pan, label: "Pan")!, in: -1...1).frame(width: 70).help("Pan")
                        Slider(value: model.binding(track: t.id, \.volumeDB, label: "Volume")!, in: -60...6)
                            .rotationEffect(.degrees(-90)).frame(width: 100, height: 20).padding(.vertical, 40)
                        Text(String(format: "%.1f dB", t.volumeDB)).font(.caption2.monospacedDigit())
                    }
                    .padding(4).background(model.selectedTrackID == t.id ? Color.accentColor.opacity(0.2) : Color.clear).cornerRadius(4)
                    .onTapGesture { model.selectedTrackID = t.id }
                }
                Divider()
                VStack {
                    Text("Master").font(.caption.bold())
                    ProgressView(value: Double(min(1, model.masterPeak))).frame(width: 70)
                    Slider(value: Binding(get: { model.project.master.volumeDB }, set: { v in model.edit("Master Volume") { $0.master.volumeDB = v } }), in: -60...6)
                        .rotationEffect(.degrees(-90)).frame(width: 100, height: 20).padding(.vertical, 40)
                }
            }.padding(8)
        }
    }
}
#endif
