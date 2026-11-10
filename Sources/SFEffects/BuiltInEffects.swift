import Foundation
import SFCore

/// Registers all built-in effects. To add a new effect: implement `EffectBase`, then add one line here
/// (or call `EffectRegistry.shared.register(...)` from your own module at launch).
enum BuiltInEffects {
    static func registerAll(into r: EffectRegistry) {
        let list: [EffectDescriptor] = [
            .init(typeID: "eq", name: "Parametric EQ", category: .eq, summary: "7-band EQ with low/high cut") { ParametricEQ() },
            .init(typeID: "filter", name: "Filter", category: .eq, summary: "Resonant multimode filter with LFO sweep") { FilterEffect() },
            .init(typeID: "autowah", name: "Auto-Wah", category: .eq, summary: "Envelope / LFO wah") { AutoWah() },
            .init(typeID: "compressor", name: "Compressor", category: .dynamics) { Compressor() },
            .init(typeID: "limiter", name: "Limiter", category: .dynamics) { Limiter() },
            .init(typeID: "gate", name: "Noise Gate", category: .dynamics) { Gate() },
            .init(typeID: "distortion", name: "Distortion", category: .drive, summary: "Overdrive, fuzz, tube, foldback, tape...") { Distortion() },
            .init(typeID: "bitcrusher", name: "Bitcrusher", category: .drive) { Bitcrusher() },
            .init(typeID: "waveshaper", name: "Waveshaper", category: .drive) { Waveshaper() },
            .init(typeID: "amp", name: "Amp Simulator", category: .drive, summary: "Preamp + tone stack + power amp") { AmpSim() },
            .init(typeID: "cabinet", name: "Cabinet (IR)", category: .drive, summary: "Synth cab IRs or load your own") { CabinetSim() },
            .init(typeID: "chorus", name: "Chorus", category: .modulation) { Chorus() },
            .init(typeID: "flanger", name: "Flanger", category: .modulation) { Flanger() },
            .init(typeID: "phaser", name: "Phaser", category: .modulation) { Phaser() },
            .init(typeID: "tremolo", name: "Tremolo / Auto-Pan", category: .modulation) { Tremolo() },
            .init(typeID: "ringmod", name: "Ring Modulator", category: .modulation) { RingModulator() },
            .init(typeID: "doubler", name: "Doubler", category: .modulation, summary: "ADT-style double tracking") { Doubler() },
            .init(typeID: "delay", name: "Delay", category: .delay, summary: "Stereo / ping-pong / tape, tempo sync") { StereoDelay() },
            .init(typeID: "pitchshift", name: "Pitch Shifter", category: .pitch) { PitchShifter() },
            .init(typeID: "octaver", name: "Octaver", category: .pitch) { Octaver() },
            .init(typeID: "formant", name: "Formant Filter", category: .pitch, summary: "Vowel / talk-box colours") { FormantFilter() },
            .init(typeID: "utility", name: "Utility", category: .utility) { Utility() },
            .init(typeID: "reverb.room", name: "Room Reverb", category: .reverb) { RoomReverb(kind: .room) },
            .init(typeID: "reverb.hall", name: "Hall Reverb", category: .reverb) { RoomReverb(kind: .hall) },
            .init(typeID: "reverb.chamber", name: "Chamber Reverb", category: .reverb) { RoomReverb(kind: .chamber) },
            .init(typeID: "reverb.plate", name: "Plate Reverb", category: .reverb) { RoomReverb(kind: .plate) },
            .init(typeID: "reverb.cathedral", name: "Cathedral Reverb", category: .reverb) { RoomReverb(kind: .cathedral) },
            .init(typeID: "reverb.ambient", name: "Ambient / Huge Reverb", category: .reverb) { RoomReverb(kind: .ambient) },
            .init(typeID: "reverb.spring", name: "Spring Reverb", category: .reverb) { SpringReverb() },
            .init(typeID: "reverb.gated", name: "Gated Reverb", category: .reverb) { GatedReverb() },
            .init(typeID: "reverb.shimmer", name: "Shimmer Reverb", category: .reverb) { ShimmerReverb() },
            .init(typeID: "reverb.reverse", name: "Reverse Reverb", category: .reverb) { ReverseReverb() },
            .init(typeID: "reverb.convolution", name: "Convolution Reverb", category: .reverb, summary: "Load any IR file") { ConvolutionReverb() },
        ]
        list.forEach(r.register)
    }
}
