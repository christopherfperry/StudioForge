import Foundation
import SFCore

/// Transport state shared between the UI (writer of requests/settings) and the audio thread
/// (owner of the play position). All fields are lock-free atomics. Positions are in frames at
/// the engine sample rate and may be negative during a count-in.
public final class Transport: @unchecked Sendable {
    public static let noSeek = Int.min

    public let isPlaying = AtomicBool(false)
    public let isRecording = AtomicBool(false)
    /// Current play position (written by the audio thread; by `seek` while stopped).
    public let position = AtomicInt(0)
    let seekRequest = AtomicInt(Transport.noSeek)

    public let loopEnabled = AtomicBool(false)
    public let loopStart = AtomicInt(0)
    public let loopEnd = AtomicInt(0)

    public let punchEnabled = AtomicBool(false)
    public let punchStart = AtomicInt(0)
    public let punchEnd = AtomicInt(0)

    public let metronomeEnabled = AtomicBool(false)
    public let metronomeOnlyWhileRecording = AtomicBool(false)
    public let metronomeGain = AtomicFloat(0.5)
    public let metronomeAccent = AtomicBool(true)

    public let tempo = AtomicDouble(120)
    public let beatsPerBar = AtomicInt(4)
    public let beatUnit = AtomicInt(4)

    /// When true the app never monitors inputs in software (the interface's direct monitoring is used).
    public let directMonitoring = AtomicBool(false)

    public init() {}

    /// Requests a jump. Applied at the start of the next audio block (or immediately when the
    /// audio thread is not running, so the UI shows the new position).
    public func seek(toFrame frame: Int) {
        seekRequest.value = frame
        if !isPlaying.value { position.value = frame }
    }

    /// Frames per metronome click (one click per time-signature beat unit).
    public func framesPerClick(sampleRate: Double) -> Double {
        sampleRate * 60 / max(1, tempo.value) * 4 / Double(max(1, beatUnit.value))
    }

    public func apply(project: SFProjectTransportSettings, sampleRate: Double) {
        tempo.value = project.tempo
        beatsPerBar.value = project.beatsPerBar
        beatUnit.value = project.beatUnit
        loopEnabled.value = project.loopEnabled
        loopStart.value = Int(project.loopStart * sampleRate)
        loopEnd.value = Int(project.loopEnd * sampleRate)
        punchEnabled.value = project.punchEnabled
        punchStart.value = Int(project.punchStart * sampleRate)
        punchEnd.value = Int(project.punchEnd * sampleRate)
        metronomeEnabled.value = project.metronomeEnabled
        metronomeOnlyWhileRecording.value = project.metronomeOnlyWhileRecording
        metronomeGain.value = dbToGain(project.metronomeDB)
        metronomeAccent.value = project.metronomeAccent
        HostContext.shared.tempo.value = project.tempo
    }
}

/// Plain value copy of the transport-related project fields (keeps Transport free of SFProject).
public struct SFProjectTransportSettings: Equatable {
    public var tempo: Double = 120
    public var beatsPerBar = 4
    public var beatUnit = 4
    public var loopEnabled = false, loopStart = 0.0, loopEnd = 0.0
    public var punchEnabled = false, punchStart = 0.0, punchEnd = 0.0
    public var metronomeEnabled = false, metronomeOnlyWhileRecording = false
    public var metronomeDB: Float = -6
    public var metronomeAccent = true
    public init() {}
}
