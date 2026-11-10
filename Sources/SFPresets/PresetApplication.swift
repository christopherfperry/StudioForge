import Foundation
import SFCore
import SFProject

public extension Preset {
    /// Applies this preset to a track: replaces the insert chain (fresh effect ids), sets the
    /// instrument if the preset has one (and the track can host it), and remembers the preset id.
    func apply(to track: inout Track) {
        track.effects = effects.map { var e = $0; e.id = UUID(); return e }
        if let inst = instrument {
            track.instrument = inst
            if track.kind == .audio { track.kind = inst.type == "drums" ? .drums : .instrument }
        }
        track.presetID = id
    }

    /// Builds a preset from a track's current chain (for "Save Track as Preset").
    static func from(track: Track, name: String, category: PresetCategory, artistStyle: String = "") -> Preset {
        Preset(id: Preset.slug(name), name: name, category: category, artistStyle: artistStyle, tags: ["user"],
               description: "Saved from track \(track.name)", effects: track.effects,
               instrument: track.kind == .audio ? nil : track.instrument)
    }
}

public extension PresetLibrary {
    /// Fills in effects/instruments for tracks that reference a preset id but have an empty chain
    /// (used when instantiating templates). Missing presets are ignored.
    func applyReferencedPresets(to project: inout Project) {
        for i in project.tracks.indices {
            guard let pid = project.tracks[i].presetID, project.tracks[i].effects.isEmpty,
                  let preset = preset(id: pid) else { continue }
            let keepInstrument = project.tracks[i].instrument
            preset.apply(to: &project.tracks[i])
            if preset.instrument == nil, let k = keepInstrument { project.tracks[i].instrument = k }
        }
    }
}
