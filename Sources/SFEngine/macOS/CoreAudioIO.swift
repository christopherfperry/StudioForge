#if os(macOS)
import Foundation
import CoreAudio
import AudioToolbox
import AVFoundation
import SFCore

/// Low-latency CoreAudio driver built directly on the HAL output unit (AUHAL).
///
/// * Same device for input and output (typical audio interface): ONE full-duplex AUHAL — input is
///   pulled with `AudioUnitRender` inside the output callback, so input and output share a single
///   I/O cycle and the round-trip latency is just the hardware latency + 2 buffers.
/// * Different devices: an input AUHAL feeds a lock-free ring that the output callback drains
///   (adds roughly one buffer of latency). Both devices must run at the same sample rate; for
///   sample-accurate sync create an Aggregate Device in Audio MIDI Setup.
///
/// Buffer sizes down to 32 frames are requested from the device (kAudioDevicePropertyBufferFrameSize).
public final class CoreAudioIO: AudioIODriver {
    public struct Configuration: Equatable {
        public var inputDeviceUID: String?      // nil = system default
        public var outputDeviceUID: String?     // nil = system default
        public var bufferFrames: Int = 128
        public var preferredSampleRate: Double? // nil = keep device rate
        public var inputEnabled = true
        public init() {}
    }

    public var configuration = Configuration()
    public private(set) var isRunning = false
    public private(set) var sampleRate: Double = 48_000
    public private(set) var bufferFrames = 128
    public private(set) var inputChannelCount = 0
    public private(set) var inputLatencyFrames = 0
    public private(set) var outputLatencyFrames = 0
    public private(set) var statusMessage = "Stopped"
    public private(set) var inputDevice: AudioDeviceInfo?
    public private(set) var outputDevice: AudioDeviceInfo?

    private var outputUnit: AudioUnit?
    private var inputUnit: AudioUnit?      // only in split mode
    private var duplex = false
    private var core: EngineCore?
    private var inputList: UnsafeMutableAudioBufferListPointer?
    private var splitBuffers: [UnsafeMutablePointer<Float>] = []
    private var ring: SPSCRingBuffer?
    private var deinterleave: UnsafeMutablePointer<Float>?   // output thread scratch
    private var interleave: UnsafeMutablePointer<Float>?     // input thread scratch
    private let maxFrames: UInt32 = 4096

    public init() {}

    deinit { stop(); freeBuffers(); disposeUnits() }

    // MARK: Permissions

    /// Asks for microphone access (required on macOS for any audio input, incl. interfaces).
    public static func requestMicrophoneAccess(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { ok in DispatchQueue.main.async { completion(ok) } }
        default: completion(false)
        }
    }

    // MARK: AudioIODriver

    public func open() throws {
        stop()
        disposeUnits()
        statusMessage = ""
        guard let outID = configuration.outputDeviceUID.flatMap(CoreAudioDevices.device(uid:)) ?? CoreAudioDevices.defaultOutputDevice() else {
            throw StudioForgeError.io("No audio output device found.")
        }
        let micAllowed = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        var inID: AudioDeviceID?
        if configuration.inputEnabled && micAllowed {
            inID = configuration.inputDeviceUID.flatMap(CoreAudioDevices.device(uid:)) ?? CoreAudioDevices.defaultInputDevice()
            if let i = inID, CoreAudioDevices.channelCount(i, input: true) == 0 { inID = nil }
        }
        if let pref = configuration.preferredSampleRate {
            CoreAudioDevices.setNominalSampleRate(outID, pref)
            if let i = inID, i != outID { CoreAudioDevices.setNominalSampleRate(i, pref) }
        }
        CoreAudioDevices.setBufferFrameSize(outID, frames: configuration.bufferFrames)
        if let i = inID, i != outID { CoreAudioDevices.setBufferFrameSize(i, frames: configuration.bufferFrames) }

        outputDevice = CoreAudioDevices.info(outID)
        inputDevice = inID.map(CoreAudioDevices.info)
        sampleRate = CoreAudioDevices.nominalSampleRate(outID)
        if sampleRate <= 0 { sampleRate = 48_000 }
        bufferFrames = CoreAudioDevices.bufferFrameSize(outID)

        if let i = inID, i != outID {
            let inRate = CoreAudioDevices.nominalSampleRate(i)
            if abs(inRate - sampleRate) > 0.5 {
                statusMessage = "Input (\(Int(inRate)) Hz) and output (\(Int(sampleRate)) Hz) run at different sample rates. Input disabled — set both to the same rate in Audio MIDI Setup or use an Aggregate Device."
                inID = nil
                inputDevice = nil
            }
        }

        duplex = inID != nil && inID == outID
        inputChannelCount = min(EngineCore.maxInputChannels, inID.map { CoreAudioDevices.channelCount($0, input: true) } ?? 0)

        outputUnit = try makeHAL(device: outID, enableInput: duplex, enableOutput: true)
        if let i = inID, !duplex {
            inputUnit = try makeHAL(device: i, enableInput: true, enableOutput: false)
        }

        let bufIn = inID.map { $0 == outID ? bufferFrames : CoreAudioDevices.bufferFrameSize($0) } ?? 0
        inputLatencyFrames = inID.map { CoreAudioDevices.latencyFrames($0, input: true) + bufIn } ?? 0
        outputLatencyFrames = CoreAudioDevices.latencyFrames(outID, input: false) + bufferFrames
        if !duplex && inID != nil { inputLatencyFrames += bufferFrames } // ring hand-over
        if statusMessage.hasPrefix("Input (") == false {
            statusMessage = inID == nil
                ? (micAllowed || !configuration.inputEnabled ? "Output only" : "Output only — microphone access not granted (System Settings › Privacy & Security › Microphone)")
                : (duplex ? "Full duplex" : "Separate input/output devices")
        }
    }

    public func start(core: EngineCore) throws {
        guard let out = outputUnit else { throw StudioForgeError.io("Audio device not opened.") }
        self.core = core
        try configureStreams(core: core)
        try check(AudioUnitInitialize(out), "initialize output")
        if let inp = inputUnit { try check(AudioUnitInitialize(inp), "initialize input") }
        if let inp = inputUnit { try check(AudioOutputUnitStart(inp), "start input") }
        try check(AudioOutputUnitStart(out), "start output")
        isRunning = true
    }

    public func stop() {
        if let out = outputUnit { AudioOutputUnitStop(out); AudioUnitUninitialize(out) }
        if let inp = inputUnit { AudioOutputUnitStop(inp); AudioUnitUninitialize(inp) }
        isRunning = false
    }

    // MARK: Setup

    private func check(_ status: OSStatus, _ what: String) throws {
        if status != noErr { throw StudioForgeError.io("CoreAudio failed to \(what) (error \(status)).") }
    }

    private func makeHAL(device: AudioDeviceID, enableInput: Bool, enableOutput: Bool) throws -> AudioUnit {
        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output,
                                             componentSubType: kAudioUnitSubType_HALOutput,
                                             componentManufacturer: kAudioUnitManufacturer_Apple,
                                             componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else { throw StudioForgeError.io("HAL output unit not available.") }
        var unitOpt: AudioUnit?
        try check(AudioComponentInstanceNew(comp, &unitOpt), "create HAL unit")
        guard let unit = unitOpt else { throw StudioForgeError.io("HAL unit is nil.") }
        var one: UInt32 = enableInput ? 1 : 0
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1,
                                       &one, UInt32(MemoryLayout<UInt32>.size)), "enable input")
        var outFlag: UInt32 = enableOutput ? 1 : 0
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0,
                                       &outFlag, UInt32(MemoryLayout<UInt32>.size)), "enable output")
        var dev = device
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                       &dev, UInt32(MemoryLayout<AudioDeviceID>.size)), "select device")
        var maxF = maxFrames
        AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
                             &maxF, UInt32(MemoryLayout<UInt32>.size))
        return unit
    }

    private static func floatFormat(sampleRate: Double, channels: UInt32) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
                                    mFormatFlags: AudioFormatFlags(kAudioFormatFlagIsFloat) | AudioFormatFlags(kAudioFormatFlagIsPacked) | AudioFormatFlags(kAudioFormatFlagIsNonInterleaved),
                                    mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                                    mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0)
    }

    private func configureStreams(core: EngineCore) throws {
        guard let out = outputUnit else { return }
        freeBuffers()
        let refCon = Unmanaged.passUnretained(self).toOpaque()

        // Output: we supply stereo float32 at the device rate on input scope of element 0.
        var outFmt = Self.floatFormat(sampleRate: sampleRate, channels: 2)
        try check(AudioUnitSetProperty(out, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
                                       &outFmt, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)), "set output format")
        var cb = AURenderCallbackStruct(inputProc: outputRenderCallback, inputProcRefCon: refCon)
        try check(AudioUnitSetProperty(out, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
                                       &cb, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "set render callback")

        guard inputChannelCount > 0 else { return }
        let inUnit = duplex ? out : inputUnit!
        var inFmt = Self.floatFormat(sampleRate: sampleRate, channels: UInt32(inputChannelCount))
        try check(AudioUnitSetProperty(inUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1,
                                       &inFmt, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)), "set input format")
        // Pre-allocated AudioBufferList whose buffers point straight at the engine's input buffers
        // (duplex) or at private buffers that are then pushed through the ring (split mode).
        let list = AudioBufferList.allocate(maximumBuffers: inputChannelCount)
        for ch in 0..<inputChannelCount {
            let data: UnsafeMutablePointer<Float>
            if duplex { data = core.inputBuffers[ch] } else {
                data = .allocate(capacity: Int(maxFrames)); data.initialize(repeating: 0, count: Int(maxFrames))
                splitBuffers.append(data)
            }
            list[ch] = AudioBuffer(mNumberChannels: 1, mDataByteSize: maxFrames * 4, mData: UnsafeMutableRawPointer(data))
        }
        inputList = list
        if !duplex {
            ring = SPSCRingBuffer(minimumCapacity: Int(maxFrames) * 4 * inputChannelCount)
            deinterleave = .allocate(capacity: Int(maxFrames) * inputChannelCount)
            interleave = .allocate(capacity: Int(maxFrames) * inputChannelCount)
            var icb = AURenderCallbackStruct(inputProc: inputCallback, inputProcRefCon: refCon)
            try check(AudioUnitSetProperty(inUnit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
                                           &icb, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "set input callback")
        }
    }

    private func freeBuffers() {
        if let l = inputList { free(l.unsafeMutablePointer) }
        inputList = nil
        splitBuffers.forEach { $0.deallocate() }
        splitBuffers = []
        deinterleave?.deallocate(); deinterleave = nil
        interleave?.deallocate(); interleave = nil
        ring = nil
    }

    private func disposeUnits() {
        if let u = outputUnit { AudioComponentInstanceDispose(u) }
        if let u = inputUnit { AudioComponentInstanceDispose(u) }
        outputUnit = nil; inputUnit = nil
    }

    // MARK: Real-time callbacks

    fileprivate func renderOutput(_ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, _ ts: UnsafePointer<AudioTimeStamp>,
                                  _ frames: UInt32, _ ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
        guard let ioData, let core else { return noErr }
        let out = UnsafeMutableAudioBufferListPointer(ioData)
        let n = Int(frames)
        guard n <= core.maxFrames, out.count > 0, let l = out[0].mData?.assumingMemoryBound(to: Float.self) else {
            for b in out { if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) } }
            return noErr
        }
        var channels = 0
        if inputChannelCount > 0, let list = inputList {
            if duplex, let unit = outputUnit {
                for ch in 0..<list.count {
                    list[ch].mData = UnsafeMutableRawPointer(core.inputBuffers[ch])
                    list[ch].mDataByteSize = frames * 4
                }
                if AudioUnitRender(unit, flags, ts, 1, frames, list.unsafeMutablePointer) == noErr { channels = inputChannelCount }
            } else if let ring, let tmp = deinterleave {
                let need = n * inputChannelCount
                // Keep latency bounded: drop stale input if the ring runs ahead.
                while ring.availableToRead > need * 3 { _ = ring.read(into: tmp, count: need) }
                if ring.availableToRead >= need {
                    _ = ring.read(into: tmp, count: need)
                    for ch in 0..<inputChannelCount {
                        let dst = core.inputBuffers[ch]
                        for i in 0..<n { dst[i] = tmp[i * inputChannelCount + ch] }
                    }
                    channels = inputChannelCount
                }
            }
        }
        let r = out.count > 1 ? (out[1].mData?.assumingMemoryBound(to: Float.self) ?? l) : l
        core.render(inputChannelCount: channels, left: l, right: r, frames: n)
        return noErr
    }

    fileprivate func captureInput(_ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, _ ts: UnsafePointer<AudioTimeStamp>,
                                  _ frames: UInt32) -> OSStatus {
        guard let unit = inputUnit, let list = inputList, let ring, let tmp = interleave, frames <= maxFrames else { return noErr }
        for ch in 0..<list.count {
            list[ch].mData = UnsafeMutableRawPointer(splitBuffers[ch])
            list[ch].mDataByteSize = frames * 4
        }
        let st = AudioUnitRender(unit, flags, ts, 1, frames, list.unsafeMutablePointer)
        guard st == noErr else { return st }
        let n = Int(frames), c = inputChannelCount
        for ch in 0..<c {
            let src = splitBuffers[ch]
            for i in 0..<n { tmp[i * c + ch] = src[i] }
        }
        ring.write(tmp, count: n * c)
        return noErr
    }
}

private let outputRenderCallback: AURenderCallback = { refCon, flags, ts, _, frames, ioData in
    Unmanaged<CoreAudioIO>.fromOpaque(refCon).takeUnretainedValue().renderOutput(flags, ts, frames, ioData)
}

private let inputCallback: AURenderCallback = { refCon, flags, ts, _, frames, _ in
    Unmanaged<CoreAudioIO>.fromOpaque(refCon).takeUnretainedValue().captureInput(flags, ts, frames)
}
#endif
