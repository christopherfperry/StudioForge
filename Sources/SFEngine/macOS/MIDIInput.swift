#if os(macOS)
import Foundation
import CoreMIDI
import SFCore

/// CoreMIDI input: connects to every MIDI source (USB keyboards, interfaces, network/IAC) and
/// pushes events into the engine's lock-free MIDI queue. Reconnects automatically when devices
/// are plugged in or removed.
public final class MIDIInputManager {
    private var client = MIDIClientRef()
    private var port = MIDIPortRef()
    private var queue: SPSCQueue<LiveMIDIEvent>
    private var connected: Set<MIDIEndpointRef> = []
    public private(set) var sourceNames: [String] = []
    public private(set) var isStarted = false
    /// Pitch-bend range in semitones.
    public var bendRange: Float = 2
    /// Called on the main queue whenever the source list changes.
    public var onSourcesChanged: (([String]) -> Void)?
    /// Last received note (main-queue notification for activity LEDs). Optional.
    public var onActivity: (() -> Void)?

    public init(queue: SPSCQueue<LiveMIDIEvent>) { self.queue = queue }

    /// Points input at a new engine queue (after the engine core is recreated).
    public func retarget(_ q: SPSCQueue<LiveMIDIEvent>) { queue = q }

    public func start() throws {
        guard !isStarted else { return }
        var status = MIDIClientCreateWithBlock("StudioForge" as CFString, &client) { [weak self] notification in
            if notification.pointee.messageID == .msgSetupChanged {
                DispatchQueue.main.async { self?.connectAllSources() }
            }
        }
        guard status == noErr else { throw StudioForgeError.io("CoreMIDI client could not be created (\(status)).") }
        status = MIDIInputPortCreateWithBlock(client, "StudioForge Input" as CFString, &port) { [weak self] packetList, _ in
            self?.handle(packetList)
        }
        guard status == noErr else { throw StudioForgeError.io("CoreMIDI input port could not be created (\(status)).") }
        isStarted = true
        connectAllSources()
    }

    public func stop() {
        guard isStarted else { return }
        for s in connected { MIDIPortDisconnectSource(port, s) }
        connected = []
        MIDIPortDispose(port)
        MIDIClientDispose(client)
        isStarted = false
    }

    public func connectAllSources() {
        var names: [String] = []
        var now: Set<MIDIEndpointRef> = []
        for i in 0..<MIDIGetNumberOfSources() {
            let src = MIDIGetSource(i)
            if src == 0 { continue }
            now.insert(src)
            if !connected.contains(src) { MIDIPortConnectSource(port, src, nil) }
            names.append(Self.name(of: src))
        }
        connected = now
        sourceNames = names
        onSourcesChanged?(names)
    }

    static func name(of endpoint: MIDIEndpointRef) -> String {
        var cf: Unmanaged<CFString>?
        if MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &cf) == noErr, let s = cf?.takeRetainedValue() {
            return s as String
        }
        return "MIDI Source"
    }

    /// Runs on the CoreMIDI thread. Parses MIDI 1.0 bytes incl. running status.
    private func handle(_ list: UnsafePointer<MIDIPacketList>) {
        var activity = false
        for packet in list.unsafeSequence() {
            let length = Int(packet.pointee.length)
            withUnsafeBytes(of: packet.pointee.data) { raw in
                var i = 0
                var status: UInt8 = 0
                let n = min(length, raw.count)
                while i < n {
                    let b = raw[i]
                    if b >= 0xF8 { i += 1; continue }                 // real-time bytes
                    if b >= 0xF0 {                                    // sysex/system common: skip to end
                        status = 0
                        i += 1
                        while i < n && raw[i] < 0x80 { i += 1 }
                        if i < n && raw[i] == 0xF7 { i += 1 }
                        continue
                    }
                    if b & 0x80 != 0 { status = b; i += 1 }
                    guard status != 0 else { i += 1; continue }
                    let type = status & 0xF0
                    let needs = (type == 0xC0 || type == 0xD0) ? 1 : 2
                    guard i + needs <= n else { break }
                    let d1 = raw[i], d2 = needs == 2 ? raw[i + 1] : 0
                    i += needs
                    switch type {
                    case 0x90:
                        queue.push(LiveMIDIEvent(kind: d2 == 0 ? .noteOff : .noteOn, data1: d1, data2: d2)); activity = true
                    case 0x80:
                        queue.push(LiveMIDIEvent(kind: .noteOff, data1: d1, data2: d2))
                    case 0xB0:
                        if d1 == 123 || d1 == 120 { queue.push(LiveMIDIEvent(kind: .allNotesOff)) }
                        else { queue.push(LiveMIDIEvent(kind: .controlChange, data1: d1, data2: d2)) }
                    case 0xE0:
                        let v = (Int(d2) << 7 | Int(d1)) - 8192
                        queue.push(LiveMIDIEvent(kind: .pitchBend, value: Float(v) / 8192 * bendRange))
                    default:
                        break
                    }
                }
            }
        }
        if activity, let cb = onActivity { DispatchQueue.main.async(execute: cb) }
    }

    deinit { stop() }
}
#endif
