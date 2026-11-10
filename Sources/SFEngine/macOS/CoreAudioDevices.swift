#if os(macOS)
import Foundation
import CoreAudio
import AudioToolbox

/// A CoreAudio device (built-in mic/speakers, USB/Thunderbolt interfaces, aggregate devices...).
public struct AudioDeviceInfo: Identifiable, Hashable {
    public var id: AudioDeviceID
    public var uid: String
    public var name: String
    public var inputChannels: Int
    public var outputChannels: Int
    public var nominalSampleRate: Double
    public var bufferFrameRange: ClosedRange<Int>
    public var hasInput: Bool { inputChannels > 0 }
    public var hasOutput: Bool { outputChannels > 0 }
}

/// Thin, typed wrappers around the CoreAudio HAL property API.
public enum CoreAudioDevices {
    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = AudioObjectPropertyScope(kAudioObjectPropertyScopeGlobal)) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: AudioObjectPropertyElement(kAudioObjectPropertyElementMain))
    }

    static let inputScope = AudioObjectPropertyScope(kAudioDevicePropertyScopeInput)
    static let outputScope = AudioObjectPropertyScope(kAudioDevicePropertyScopeOutput)
    static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    static func getValue<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                            _ scope: AudioObjectPropertyScope = AudioObjectPropertyScope(kAudioObjectPropertyScopeGlobal),
                            initial: T) -> T? {
        var addr = address(selector, scope)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, ptr)
        }
        return status == noErr ? value : nil
    }

    @discardableResult
    static func setValue<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                            _ scope: AudioObjectPropertyScope = AudioObjectPropertyScope(kAudioObjectPropertyScopeGlobal),
                            _ value: T) -> Bool {
        var addr = address(selector, scope)
        var v = value
        let status = withUnsafeMutablePointer(to: &v) { ptr in
            AudioObjectSetPropertyData(object, &addr, 0, nil, UInt32(MemoryLayout<T>.size), ptr)
        }
        return status == noErr
    }

    static func getString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var cf: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &cf) { ptr in
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, ptr)
        }
        guard status == noErr, let s = cf?.takeRetainedValue() else { return nil }
        return s as String
    }

    public static func deviceIDs() -> [AudioDeviceID] {
        var addr = address(AudioObjectPropertySelector(kAudioHardwarePropertyDevices))
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemObject, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        let status = ids.withUnsafeMutableBufferPointer { buf in
            AudioObjectGetPropertyData(systemObject, &addr, 0, nil, &size, buf.baseAddress!)
        }
        return status == noErr ? ids : []
    }

    public static func channelCount(_ id: AudioDeviceID, input: Bool) -> Int {
        var addr = address(AudioObjectPropertySelector(kAudioDevicePropertyStreamConfiguration), input ? inputScope : outputScope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let abl = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return abl.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    public static func info(_ id: AudioDeviceID) -> AudioDeviceInfo {
        let name = getString(id, AudioObjectPropertySelector(kAudioObjectPropertyName)) ?? "Device \(id)"
        let uid = getString(id, AudioObjectPropertySelector(kAudioDevicePropertyDeviceUID)) ?? "\(id)"
        let sr = getValue(id, AudioObjectPropertySelector(kAudioDevicePropertyNominalSampleRate), initial: Float64(0)) ?? 0
        let range = getValue(id, AudioObjectPropertySelector(kAudioDevicePropertyBufferFrameSizeRange),
                             initial: AudioValueRange(mMinimum: 0, mMaximum: 0))
        let lo = Int(range?.mMinimum ?? 32), hi = max(lo, Int(range?.mMaximum ?? 4096))
        return AudioDeviceInfo(id: id, uid: uid, name: name, inputChannels: channelCount(id, input: true),
                               outputChannels: channelCount(id, input: false), nominalSampleRate: sr,
                               bufferFrameRange: lo...hi)
    }

    public static func allDevices() -> [AudioDeviceInfo] { deviceIDs().map(info) }
    public static func inputDevices() -> [AudioDeviceInfo] { allDevices().filter(\.hasInput) }
    public static func outputDevices() -> [AudioDeviceInfo] { allDevices().filter(\.hasOutput) }

    public static func defaultInputDevice() -> AudioDeviceID? {
        getValue(systemObject, AudioObjectPropertySelector(kAudioHardwarePropertyDefaultInputDevice), initial: AudioDeviceID(0)).flatMap { $0 == 0 ? nil : $0 }
    }
    public static func defaultOutputDevice() -> AudioDeviceID? {
        getValue(systemObject, AudioObjectPropertySelector(kAudioHardwarePropertyDefaultOutputDevice), initial: AudioDeviceID(0)).flatMap { $0 == 0 ? nil : $0 }
    }

    public static func device(uid: String) -> AudioDeviceID? { deviceIDs().first { info($0).uid == uid } }

    public static func bufferFrameSize(_ id: AudioDeviceID) -> Int {
        Int(getValue(id, AudioObjectPropertySelector(kAudioDevicePropertyBufferFrameSize), initial: UInt32(0)) ?? 0)
    }

    /// Requests a hardware buffer size; the device clamps to its supported range.
    @discardableResult
    public static func setBufferFrameSize(_ id: AudioDeviceID, frames: Int) -> Bool {
        setValue(id, AudioObjectPropertySelector(kAudioDevicePropertyBufferFrameSize), UInt32(frames))
    }

    public static func nominalSampleRate(_ id: AudioDeviceID) -> Double {
        getValue(id, AudioObjectPropertySelector(kAudioDevicePropertyNominalSampleRate), initial: Float64(0)) ?? 0
    }

    @discardableResult
    public static func setNominalSampleRate(_ id: AudioDeviceID, _ rate: Double) -> Bool {
        setValue(id, AudioObjectPropertySelector(kAudioDevicePropertyNominalSampleRate), Float64(rate))
    }

    public static func availableSampleRates(_ id: AudioDeviceID) -> [Double] {
        var addr = address(AudioObjectPropertySelector(kAudioDevicePropertyAvailableNominalSampleRates))
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        let n = Int(size) / MemoryLayout<AudioValueRange>.size
        var ranges = [AudioValueRange](repeating: AudioValueRange(mMinimum: 0, mMaximum: 0), count: n)
        let st = ranges.withUnsafeMutableBufferPointer { AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0.baseAddress!) }
        guard st == noErr else { return [] }
        let common: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000]
        return common.filter { r in ranges.contains { r >= $0.mMinimum && r <= $0.mMaximum } }
    }

    /// Device + safety offset + stream latency for one direction, in frames (excludes the buffer).
    public static func latencyFrames(_ id: AudioDeviceID, input: Bool) -> Int {
        let scope = input ? inputScope : outputScope
        let dev = getValue(id, AudioObjectPropertySelector(kAudioDevicePropertyLatency), scope, initial: UInt32(0)) ?? 0
        let safety = getValue(id, AudioObjectPropertySelector(kAudioDevicePropertySafetyOffset), scope, initial: UInt32(0)) ?? 0
        var stream: UInt32 = 0
        var addr = address(AudioObjectPropertySelector(kAudioDevicePropertyStreams), scope)
        var size: UInt32 = 0
        if AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size >= UInt32(MemoryLayout<AudioStreamID>.size) {
            var streams = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
            let st = streams.withUnsafeMutableBufferPointer { AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0.baseAddress!) }
            if st == noErr, let first = streams.first {
                stream = getValue(first, AudioObjectPropertySelector(kAudioStreamPropertyLatency), initial: UInt32(0)) ?? 0
            }
        }
        return Int(dev + safety + stream)
    }
}
#endif
