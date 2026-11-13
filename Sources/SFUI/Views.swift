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
    enum Sheet: String, Identifiable { case newSong, presets, tonePicker, beat, stems, export, audio; var id: String { rawValue } }

    public init(model: AppModel) { self.model = model }

    public var body: some View {
        VStack(spacing: 0) {
            TransportBar(model: model, sheet: $sheet, showMixer: $model.showMixer)
            Divider()
            HSplitView {
                ArrangementView(model: model).frame(minWidth: 500)
                InspectorView(model: model, sheet: $sheet).frame(minWidth: 260, idealWidth: 300, maxWidth: 380)
            }
            if model.showMixer { Divider(); MixerView(model: model).frame(height: 180) }
            HStack {
                Text(model.status).font(.caption).lineLimit(1)
                Spacer()
                Text(model.engine.latencyDescription).font(.caption.monospacedDigit())
                Text(String(format: "CPU %.0f%%", model.cpu * 100)).font(.caption.monospacedDigit())
                    .foregroundColor(model.cpu > 0.8 ? .red : .secondary)
            }.padding(.horizontal, 8).padding(.vertical, 3)
        }
        .preferredColorScheme(.dark)
        .onAppear { model.installKeyMonitor() }
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
        .onChange(of: model.showSplitSheet) { show in
            // Menu command "Import & Split Audio…" (⇧⌘I) routes through the model.
            if show { sheet = .stems; model.showSplitSheet = false }
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
            // Single-key shortcuts (Space, Return, R, L, K, N, X, S) live in AppModel.handleKey so they
            // never fire while typing in a text field.
            Button(action: model.togglePlay) { Image(systemName: model.isPlaying ? "stop.fill" : "play.fill") }
                .help("Play / Stop (Space)")
            Button(action: model.record) { Image(systemName: model.isRecording ? "record.circle.fill" : "record.circle").foregroundColor(model.isRecording ? .red : .primary) }
                .help(model.isRecording ? "Stop recording (R)" : "Record armed tracks (R)")
            Text(timeString(model.position)).font(.system(.title3, design: .monospaced)).frame(width: 110)
            Stepper(value: Binding(get: { model.project.tempo }, set: { v in model.edit("Tempo") { $0.tempo = v } }), in: 30...300, step: 1) {
                Text("\(Int(model.project.tempo)) BPM").monospacedDigit()
            }.help("Project tempo")
            Text(model.project.timeSignature.description)
            Toggle("Loop", isOn: Binding(get: { model.project.loop.enabled }, set: { v in model.edit("Loop") { $0.loop.enabled = v } }))
                .toggleStyle(.button).help("Loop region (L)")
            Toggle("Punch", isOn: Binding(get: { model.project.punch.enabled }, set: { v in model.edit("Punch") { $0.punch.enabled = v } }))
                .toggleStyle(.button).help("Punch in/out region")
            Toggle("Click", isOn: Binding(get: { model.project.metronome.enabled }, set: { v in model.edit("Metronome") { $0.metronome.enabled = v } }))
                .toggleStyle(.button).help("Metronome (K)")
            Toggle(isOn: $model.showNotes) { Label("Notes", systemImage: "music.note") }
                .toggleStyle(.button)
                .help("Show which note each track is playing (N)")
            Spacer()
            Button("Tone Picker") { sheet = .tonePicker }.help("Pick an artist + instrument and get a preset")
            Button("Presets") { sheet = .presets }
            Button("Beat") { sheet = .beat }.help("Generate or match a drum beat")
            Button { sheet = .stems } label: { Label("Split", systemImage: "waveform.badge.plus") }
                .help("Import audio (or use the selected clip) and split it into vocals, instruments and drum parts")
            Button("Export") { sheet = .export }.keyboardShortcut("e", modifiers: [.command])
            Button { sheet = .audio } label: { Image(systemName: "slider.horizontal.3") }.help("Audio device & latency settings")
            Toggle(isOn: $showMixer) { Label("Mixer", systemImage: "slider.vertical.3") }.toggleStyle(.button)
                .help("Show the mixer: volume faders, pan, mute/solo for every track and stem (X)")
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
                Button { model.splitAtPlayhead() } label: { Label("Cut at Playhead", systemImage: "scissors") }
                    .help("Cut the clips under the playhead in two (S). To separate a song into stems use Split in the transport bar.")
            }
        }
    }
}

struct TrackLane: View {
    @ObservedObject var model: AppModel
    let track: Track

    /// "Muted" / "Silenced by solo" when this track can't be heard right now.
    var silence: String? { model.project.silenceReason(track.id) }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    if track.isStem {
                        Image(systemName: "square.stack.3d.down.right").font(.caption2).foregroundColor(.secondary)
                            .help("Stem track from Import & Split")
                    }
                    Text(track.name).font(.headline).lineLimit(1)
                    Spacer(minLength: 0)
                    Button { model.deleteTrack(track.id) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless).foregroundColor(.secondary)
                        .help(track.isStem ? "Delete this stem (⌘⌫, undo with ⌘Z)" : "Delete this track (⌘⌫, undo with ⌘Z)")
                }
                HStack(spacing: 4) {
                    ChipToggle(title: "M", isOn: track.mute, color: .yellow,
                               help: track.mute ? "Unmute this track (⌃⌘M)" : "Mute this track (⌃⌘M)") { model.toggleMute(track.id) }
                    ChipToggle(title: "S", isOn: track.solo, color: .green,
                               help: track.solo ? "Unsolo this track (⌃⌘S)" : "Solo: hear only soloed tracks (⌃⌘S)") { model.toggleSolo(track.id) }
                    if track.kind == .audio || track.instrument != nil {
                        ChipToggle(title: "R", isOn: track.arm, color: .red, help: "Arm for recording") { model.toggleArm(track.id) }
                    }
                    if let why = silence {
                        Text(why == "Muted" ? "MUTED" : "SOLO-OFF").font(.system(size: 9, weight: .bold))
                            .foregroundColor(.secondary).help(why)
                    }
                    if model.showNotes {
                        // Fixed slot so the header does not jump as notes start and stop.
                        Text(model.playingNotes[track.id] ?? "–")
                            .font(.system(.caption, design: .monospaced).bold())
                            .lineLimit(1).truncationMode(.tail)
                            .foregroundColor(model.playingNotes[track.id] == nil ? .secondary : .black)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(model.playingNotes[track.id] == nil ? Color.gray.opacity(0.25) : Color.mint)
                            .cornerRadius(3)
                            .help("Note playing at the playhead")
                    }
                }
                VolumeControl(model: model, trackID: track.id, volumeDB: track.volumeDB, compact: true)
            }
            .frame(width: 162, alignment: .leading).padding(4)
            .background(model.selectedTrackID == track.id ? Color.accentColor.opacity(0.25) : Color(nsColor: .controlBackgroundColor))
            .contentShape(Rectangle())
            // Simultaneous so selecting never swallows clicks meant for the M / S / R buttons.
            .simultaneousGesture(TapGesture().onEnded { model.selectedTrackID = track.id })
            .contextMenu { TrackMenuItems(model: model, track: track) }
            ZStack(alignment: .topLeading) {
                Color(nsColor: .textBackgroundColor).opacity(0.15)
                ForEach(track.audioClips) { clip in
                    ClipView(model: model, trackID: track.id, clip: clip)
                        .frame(width: max(4, clip.duration * model.zoom), height: track.height - 8)
                        .offset(x: clip.start * model.zoom, y: 4)
                }
                ForEach(track.midiClips) { clip in
                    MIDIClipView(clip: clip)
                        .contextMenu {
                            Button(clip.muted ? "Unmute Clip" : "Mute Clip") {
                                model.edit(clip.muted ? "Unmute Clip" : "Mute Clip") { $0.toggleClipMute(clip.id) }
                            }
                            Button("Delete Clip", role: .destructive) { model.edit("Delete Clip") { $0.deleteClip(clip.id) } }
                            Divider()
                            TrackMenuItems(model: model, track: track)
                        }
                        .frame(width: max(4, model.project.seconds(forBeat: clip.lengthBeats) * model.zoom), height: track.height - 8)
                        .offset(x: model.project.seconds(forBeat: clip.startBeat) * model.zoom, y: 4)
                }
                if model.showNotes, let label = model.playingNotes[track.id] {
                    // Note tag riding next to the playhead on this lane.
                    Text(label)
                        .font(.system(.callout, design: .monospaced).bold())
                        .foregroundColor(.black).lineLimit(1).fixedSize()
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.mint))
                        .offset(x: model.position * model.zoom + 4, y: max(2, track.height / 2 - 11))
                        .allowsHitTesting(false)
                }
            }
            .frame(height: track.height)
            .opacity(silence == nil ? 1 : 0.4)   // silent tracks are visibly dimmed
            .contentShape(Rectangle())
            .onTapGesture { model.selectedTrackID = track.id }
        }
    }
}

/// Mute / solo / arm chip. The whole coloured box is clickable: with a plain button style only the
/// letter itself received clicks, so most clicks on the box fell through to the header and only
/// selected the track instead of toggling mute.
struct ChipToggle: View {
    let title: String
    let isOn: Bool
    let color: Color
    var width: CGFloat = 22
    var height: CGFloat = 18
    var help: String = ""
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(.caption.bold())
                .frame(width: width, height: height)
                .foregroundColor(isOn ? .black : .primary)
                .background(RoundedRectangle(cornerRadius: 3).fill(isOn ? color : Color.gray.opacity(0.3)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(Text(title == "M" ? "Mute" : title == "S" ? "Solo" : "Record arm"))
        .accessibilityValue(Text(isOn ? "On" : "Off"))
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
                Text(clip.muted ? "\(clip.name) (muted)" : clip.name).font(.caption2).padding(3).lineLimit(1)
                    .strikethrough(clip.muted)
                // Trim handles
                HStack {
                    handle { dx in model.edit("Trim Start") { p in
                        if let (t, c) = p.locateAudioClip(clip.id) { p.tracks[t].audioClips[c] = ClipEditing.trimStart(clip, to: clip.start + dx / model.zoom) } } }
                    Spacer()
                    handle { dx in model.edit("Trim End") { p in
                        if let (t, c) = p.locateAudioClip(clip.id) { p.tracks[t].audioClips[c] = ClipEditing.trimEnd(clip, to: clip.end + dx / model.zoom) } } }
                }
            }
            .opacity(clip.muted ? 0.35 : 1)
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
                Button(clip.muted ? "Unmute Clip" : "Mute Clip") { model.edit(clip.muted ? "Unmute Clip" : "Mute Clip") { $0.toggleClipMute(clip.id) } }
                Divider()
                SynthMenuItems(model: model, trackID: trackID)
                Divider()
                Button("Delete Clip", role: .destructive) { model.edit("Delete Clip") { $0.deleteClip(clip.id) } }
                if let t = model.project.tracks.first(where: { $0.id == trackID }) {
                    TrackMenuItems(model: model, track: t)
                }
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
            Text(clip.muted ? "\(clip.name) (muted)" : clip.name).font(.caption2).padding(3).strikethrough(clip.muted)
        }
        .opacity(clip.muted ? 0.35 : 1)
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
                    Text(track.isStem ? "Stem (audio)" : track.kind.displayName).foregroundColor(.secondary)
                    GroupBox("Volume & pan") {
                        VStack(alignment: .leading, spacing: 6) {
                            VolumeControl(model: model, trackID: id, volumeDB: track.volumeDB, compact: false)
                            HStack {
                                Text("Pan").font(.caption)
                                Slider(value: model.binding(track: id, \.pan, label: "Pan")!, in: -1...1)
                                Text(panText(track.pan)).font(.caption.monospacedDigit()).frame(width: 34)
                                    .onTapGesture(count: 2) { model.edit("Pan") { p in if let i = p.trackIndex(id) { p.tracks[i].pan = 0 } } }
                                    .help("Double-click to centre")
                            }
                        }
                    }
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
                    HStack {
                        Button(role: .destructive) { model.deleteTrack(id) } label: {
                            Label(track.isStem ? "Delete Stem" : "Delete Track", systemImage: "trash")
                        }
                        if track.isStem && model.project.stemSiblings(of: id).count > 1 {
                            Button(role: .destructive) { model.deleteStemGroup(of: id) } label: { Text("Delete All Stems From This Split") }
                        }
                    }
                }.padding(10)
            } else {
                Text("Select a track to edit its input, effects and instrument.").foregroundColor(.secondary).padding()
            }
        }
    }

    func panText(_ p: Float) -> String {
        abs(p) < 0.01 ? "C" : (p < 0 ? "L\(Int(-p * 100))" : "R\(Int(p * 100))")
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
                    VStack(spacing: 4) {
                        Text(t.name).font(.caption).lineLimit(1).frame(width: 84)
                        Slider(value: model.binding(track: t.id, \.pan, label: "Pan")!, in: -1...1).frame(width: 74).help("Pan (left / right)")
                        Fader(value: model.volumeBinding(t.id)).frame(height: 84)
                            .help("Volume — drag, scroll, or double-click for 0 dB")
                        Text(VolumeControl.dbText(t.volumeDB)).font(.caption2.monospacedDigit())
                        HStack(spacing: 3) {
                            ChipToggle(title: "M", isOn: t.mute, color: .yellow, width: 20, height: 16,
                                       help: t.mute ? "Unmute" : "Mute") { model.toggleMute(t.id) }
                            ChipToggle(title: "S", isOn: t.solo, color: .green, width: 20, height: 16,
                                       help: t.solo ? "Unsolo" : "Solo") { model.toggleSolo(t.id) }
                            Button { model.deleteTrack(t.id) } label: { Image(systemName: "trash").font(.caption2) }
                                .buttonStyle(.borderless).help(t.isStem ? "Delete stem" : "Delete track")
                        }
                    }
                    .padding(4).background(model.selectedTrackID == t.id ? Color.accentColor.opacity(0.2) : Color.clear).cornerRadius(4)
                    .opacity(model.project.silenceReason(t.id) == nil ? 1 : 0.55)
                    .contentShape(Rectangle())
                    .simultaneousGesture(TapGesture().onEnded { model.selectedTrackID = t.id })
                    .contextMenu { TrackMenuItems(model: model, track: t) }
                }
                Divider()
                VStack(spacing: 4) {
                    Text("Master").font(.caption.bold())
                    ProgressView(value: Double(min(1, model.masterPeak))).frame(width: 74)
                    Fader(value: model.masterVolumeBinding).frame(height: 84).help("Master volume — double-click for 0 dB")
                    Text(VolumeControl.dbText(model.project.master.volumeDB)).font(.caption2.monospacedDigit())
                }
            }.padding(8)
        }
    }
}

/// Vertical volume fader (-60…+6 dB) with a 0 dB mark; double-click resets to 0 dB, scroll nudges.
struct Fader: View {
    @Binding var value: Float
    private let range = AppModel.volumeRange

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let frac = CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
            let zero = CGFloat((0 - range.lowerBound) / (range.upperBound - range.lowerBound))
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 3).fill(Color.gray.opacity(0.25)).frame(width: 6)
                RoundedRectangle(cornerRadius: 3).fill(Color.accentColor.opacity(0.8)).frame(width: 6, height: max(0, frac * h))
                Rectangle().fill(Color.white.opacity(0.5)).frame(width: 18, height: 1).offset(y: -zero * h)
                RoundedRectangle(cornerRadius: 3).fill(Color.white).frame(width: 26, height: 10)
                    .shadow(radius: 1).offset(y: -(frac * h) + 5)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                let f = Float(1 - min(max(g.location.y / h, 0), 1))
                value = (range.lowerBound + f * (range.upperBound - range.lowerBound) * 10).rounded() / 10
            })
            .onTapGesture(count: 2) { value = 0 }
        }
        .frame(width: 44)
        .accessibilityElement()
        .accessibilityLabel("Volume")
        .accessibilityValue(VolumeControl.dbText(value))
        .accessibilityAdjustableAction { dir in value = min(range.upperBound, max(range.lowerBound, value + (dir == .increment ? 1 : -1))) }
    }
}

/// Horizontal volume control used in track headers (compact) and the inspector (full).
struct VolumeControl: View {
    @ObservedObject var model: AppModel
    let trackID: UUID
    let volumeDB: Float
    let compact: Bool

    static func dbText(_ v: Float) -> String { v <= AppModel.volumeRange.lowerBound + 0.05 ? "−∞ dB" : String(format: "%+.1f dB", v) }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: volumeDB <= -59.9 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.caption2).foregroundColor(.secondary)
            if !compact {
                Button { model.nudgeVolume(trackID, by: -1) } label: { Image(systemName: "minus") }.buttonStyle(.borderless)
                    .help("Volume down 1 dB")
            }
            Slider(value: model.volumeBinding(trackID), in: AppModel.volumeRange)
                .controlSize(.mini)
                .help("Track volume — drag to change, double-click the dB value to reset to 0 dB")
            if !compact {
                Button { model.nudgeVolume(trackID, by: 1) } label: { Image(systemName: "plus") }.buttonStyle(.borderless)
                    .help("Volume up 1 dB")
            }
            Text(Self.dbText(volumeDB)).font(.caption2.monospacedDigit()).frame(width: compact ? 46 : 52, alignment: .trailing)
                .onTapGesture(count: 2) { model.setVolume(trackID, 0) }
            if !compact {
                Button("0 dB") { model.setVolume(trackID, 0) }.controlSize(.small).help("Reset to 0 dB")
            }
        }
    }
}

/// Track / stem commands shared by the track header, clip and mixer context menus.
struct TrackMenuItems: View {
    @ObservedObject var model: AppModel
    let track: Track
    var body: some View {
        Button(track.mute ? "Unmute" : "Mute") { model.toggleMute(track.id) }
        Button(track.solo ? "Unsolo" : "Solo") { model.toggleSolo(track.id) }
        if model.project.tracks.contains(where: { $0.mute || $0.solo }) {
            Button("Clear All Mute & Solo") { model.clearAllMuteSolo() }
        }
        Divider()
        Menu("Volume") {
            ForEach([6, 3, 0, -3, -6, -12, -18], id: \.self) { (db: Int) in
                Button(db == 0 ? "0 dB (reset)" : String(format: "%+d dB", db)) { model.setVolume(track.id, Float(db)) }
            }
            Divider()
            Button("Up 1 dB") { model.nudgeVolume(track.id, by: 1) }
            Button("Down 1 dB") { model.nudgeVolume(track.id, by: -1) }
        }
        Button(track.isStem ? "Delete Stem" : "Delete Track", role: .destructive) { model.deleteTrack(track.id) }
        if track.isStem && model.project.stemSiblings(of: track.id).count > 1 {
            Button("Delete All Stems From This Split", role: .destructive) { model.deleteStemGroup(of: track.id) }
        }
    }
}

/// "Generate Matching Synth" submenu: style plus the genre that sets its register and tone.
struct SynthMenuItems: View {
    @ObservedObject var model: AppModel
    let trackID: UUID
    var body: some View {
        Menu("Generate Matching Synth") {
            ForEach(SynthStyle.allCases) { style in
                Button(style.displayName) { model.selectedTrackID = trackID; model.generateMatchingSynth(style: style) }
            }
            Divider()
            Picker("Genre: \(model.synthGenre.displayName)", selection: Binding(get: { model.synthGenreID }, set: { model.synthGenreID = $0 })) {
                ForEach(MusicGenre.allCases) { g in Text(g.displayName).tag(g.rawValue) }
            }
        }.help("Builds a synth track from the project's guitar and bass tracks (or this track), in the chosen genre's register and tone")
    }
}
#endif
