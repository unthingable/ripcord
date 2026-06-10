import AudioToolbox
import AudioUnit
import CoreAudio
import Darwin
import Foundation
import os

private func fourCC(_ status: OSStatus) -> String {
    let value = UInt32(bitPattern: status)
    let bytes = [
        UInt8((value >> 24) & 0xff),
        UInt8((value >> 16) & 0xff),
        UInt8((value >> 8) & 0xff),
        UInt8(value & 0xff),
    ]
    if bytes.allSatisfy({ $0 >= 32 && $0 <= 126 }) {
        return String(decoding: bytes, as: UTF8.self)
    }
    return "\(status)"
}

private struct InputDevice {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

private enum CaptureError: Error, CustomStringConvertible {
    case coreAudio(String, OSStatus)
    case noInputDevices
    case deviceNotFound(String)
    case noInputStream(AudioDeviceID)
    case unsupportedFormat(AudioStreamBasicDescription)
    case writer(OSStatus)

    var description: String {
        switch self {
        case .coreAudio(let op, let status):
            return "\(op) failed: \(fourCC(status))"
        case .noInputDevices:
            return "No CoreAudio input devices found"
        case .deviceNotFound(let query):
            return "No input device matched \(query)"
        case .noInputStream(let id):
            return "Device \(id) has no input streams"
        case .unsupportedFormat(let asbd):
            return "Unsupported format: \(describe(asbd))"
        case .writer(let status):
            return "ExtAudioFile write failed: \(fourCC(status))"
        }
    }
}

private func describe(_ asbd: AudioStreamBasicDescription) -> String {
    let flags = asbd.mFormatFlags
    let isFloat = (flags & kAudioFormatFlagIsFloat) != 0
    let isInt = (flags & kAudioFormatFlagIsSignedInteger) != 0
    let isPacked = (flags & kAudioFormatFlagIsPacked) != 0
    let isNonInterleaved = (flags & kAudioFormatFlagIsNonInterleaved) != 0
    return "\(asbd.mSampleRate) Hz, \(asbd.mChannelsPerFrame) ch, bits=\(asbd.mBitsPerChannel), bytes/frame=\(asbd.mBytesPerFrame), flags=\(flags) float=\(isFloat) int=\(isInt) packed=\(isPacked) nonInterleaved=\(isNonInterleaved)"
}

private func getProperty<T>(
    objectID: AudioObjectID,
    selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
    element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
    as type: T.Type
) throws -> T {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    let raw = UnsafeMutableRawPointer.allocate(
        byteCount: MemoryLayout<T>.size,
        alignment: MemoryLayout<T>.alignment
    )
    defer { raw.deallocate() }
    var size = UInt32(MemoryLayout<T>.size)
    let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, raw)
    guard status == noErr else { throw CaptureError.coreAudio("AudioObjectGetPropertyData(\(selector))", status) }
    return raw.load(as: T.self)
}

private func stringProperty(
    objectID: AudioObjectID,
    selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
) -> String? {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
    guard status == noErr, let value else { return nil }
    return value.takeRetainedValue() as String
}

private func inputChannelCount(_ deviceID: AudioDeviceID) -> Int {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreamConfiguration,
        mScope: kAudioDevicePropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain
    )
    var dataSize: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr,
          dataSize >= UInt32(MemoryLayout<AudioBufferList>.size) else {
        return 0
    }

    let raw = UnsafeMutableRawPointer.allocate(
        byteCount: Int(dataSize),
        alignment: MemoryLayout<AudioBufferList>.alignment
    )
    defer { raw.deallocate() }

    guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, raw) == noErr else {
        return 0
    }

    let abl = UnsafeMutableAudioBufferListPointer(raw.bindMemory(to: AudioBufferList.self, capacity: 1))
    return abl.reduce(0) { $0 + Int($1.mNumberChannels) }
}

private func inputDevices() throws -> [InputDevice] {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var dataSize: UInt32 = 0
    var status = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize)
    guard status == noErr else { throw CaptureError.coreAudio("AudioObjectGetPropertyDataSize(devices)", status) }

    let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
    var ids = [AudioDeviceID](repeating: 0, count: count)
    status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &ids)
    guard status == noErr else { throw CaptureError.coreAudio("AudioObjectGetPropertyData(devices)", status) }

    return ids.compactMap { id in
        guard inputChannelCount(id) > 0,
              let uid = stringProperty(objectID: id, selector: kAudioDevicePropertyDeviceUID),
              let name = stringProperty(objectID: id, selector: kAudioObjectPropertyName) else {
            return nil
        }
        return InputDevice(id: id, uid: uid, name: name)
    }
}

private func streams(for deviceID: AudioDeviceID) throws -> [AudioStreamID] {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreams,
        mScope: kAudioDevicePropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain
    )
    var dataSize: UInt32 = 0
    let status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize)
    guard status == noErr, dataSize > 0 else { throw CaptureError.noInputStream(deviceID) }
    var values = [AudioStreamID](repeating: 0, count: Int(dataSize) / MemoryLayout<AudioStreamID>.size)
    var size = dataSize
    let readStatus = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &values)
    guard readStatus == noErr else { throw CaptureError.coreAudio("AudioObjectGetPropertyData(streams)", readStatus) }
    return values
}

private func virtualFormat(for streamID: AudioStreamID) throws -> AudioStreamBasicDescription {
    try getProperty(
        objectID: streamID,
        selector: kAudioStreamPropertyVirtualFormat,
        as: AudioStreamBasicDescription.self
    )
}

private func float64Property(
    objectID: AudioObjectID,
    selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
) -> (value: Float64?, status: OSStatus) {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain
    )
    var value: Float64 = 0
    var size = UInt32(MemoryLayout<Float64>.size)
    let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
    return (status == noErr ? value : nil, status)
}

private func formatRate(_ result: (value: Float64?, status: OSStatus)) -> String {
    guard let value = result.value else {
        return "n/a(status=\(fourCC(result.status)))"
    }
    return "\(value)(status=ok)"
}

private func sampleRateSummary(for deviceID: AudioDeviceID) -> String {
    let nominal = float64Property(
        objectID: deviceID,
        selector: kAudioDevicePropertyNominalSampleRate
    )
    let actual = float64Property(
        objectID: deviceID,
        selector: kAudioDevicePropertyActualSampleRate
    )
    return "nominal=\(formatRate(nominal)) actual=\(formatRate(actual))"
}

private final class SampleHandoff: @unchecked Sendable {
    private var lock = os_unfair_lock_s()
    private var buffer: [Float]
    private var readIndex = 0
    private var writeIndex = 0
    private var storedCount = 0
    private(set) var droppedSamples = 0

    init(capacitySamples: Int) {
        buffer = [Float](repeating: 0, count: max(1, capacitySamples))
    }

    func write(_ samples: UnsafeBufferPointer<Float>) {
        guard samples.count > 0, let base = samples.baseAddress else { return }
        guard os_unfair_lock_trylock(&lock) else { return }
        defer { os_unfair_lock_unlock(&lock) }

        let capacity = buffer.count
        if samples.count >= capacity {
            let start = samples.count - capacity
            buffer.withUnsafeMutableBufferPointer { dst in
                dst.baseAddress!.update(from: base.advanced(by: start), count: capacity)
            }
            droppedSamples += storedCount + start
            readIndex = 0
            writeIndex = 0
            storedCount = capacity
            return
        }

        let free = capacity - storedCount
        if samples.count > free {
            let drop = samples.count - free
            readIndex = (readIndex + drop) % capacity
            storedCount -= drop
            droppedSamples += drop
        }

        let firstCopy = min(samples.count, capacity - writeIndex)
        buffer.withUnsafeMutableBufferPointer { dst in
            dst.baseAddress!.advanced(by: writeIndex).update(from: base, count: firstCopy)
            if samples.count > firstCopy {
                dst.baseAddress!.update(from: base.advanced(by: firstCopy), count: samples.count - firstCopy)
            }
        }
        writeIndex = (writeIndex + samples.count) % capacity
        storedCount += samples.count
    }

    func drain() -> [Float] {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }

        guard storedCount > 0 else { return [] }
        let count = storedCount
        var out = [Float](repeating: 0, count: count)
        let firstCopy = min(count, buffer.count - readIndex)
        out.withUnsafeMutableBufferPointer { dst in
            buffer.withUnsafeBufferPointer { src in
                dst.baseAddress!.update(from: src.baseAddress!.advanced(by: readIndex), count: firstCopy)
                if count > firstCopy {
                    dst.baseAddress!.advanced(by: firstCopy).update(from: src.baseAddress!, count: count - firstCopy)
                }
            }
        }
        readIndex = writeIndex
        storedCount = 0
        return out
    }
}

private final class NativeInputRecorder: @unchecked Sendable {
    private let device: InputDevice
    private let asbd: AudioStreamBasicDescription
    private let channels: Int
    private let handoff: SampleHandoff
    private let writerQueue = DispatchQueue(label: "usb-audio-capture.writer")
    private var writerTimer: DispatchSourceTimer?
    private var outputFile: ExtAudioFileRef?
    private var procID: AudioDeviceIOProcID?
    private var scratch = [Float](repeating: 0, count: 8192)
    private var callbackCount = 0
    private var previousSampleTime: Float64?
    private var previousFrameCount = 0
    private var discontinuityCount = 0
    private var writeError: Error?
    private var writtenFrames = 0

    init(device: InputDevice, asbd: AudioStreamBasicDescription) {
        self.device = device
        self.asbd = asbd
        self.channels = Int(asbd.mChannelsPerFrame)
        let capacitySamples = max(48_000, Int(asbd.mSampleRate) * max(1, Int(asbd.mChannelsPerFrame)) * 4)
        self.handoff = SampleHandoff(capacitySamples: capacitySamples)
    }

    func start(outputURL: URL) throws {
        try createWriter(outputURL: outputURL)

        let timer = DispatchSource.makeTimerSource(queue: writerQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(20))
        timer.setEventHandler { [weak self] in self?.flush() }
        timer.resume()
        writerTimer = timer

        var id: AudioDeviceIOProcID?
        let createStatus = AudioDeviceCreateIOProcID(
            device.id,
            nativeInputIOProc,
            Unmanaged.passUnretained(self).toOpaque(),
            &id
        )
        guard createStatus == noErr, let id else {
            throw CaptureError.coreAudio("AudioDeviceCreateIOProcID", createStatus)
        }
        procID = id

        let startStatus = AudioDeviceStart(device.id, id)
        guard startStatus == noErr else {
            AudioDeviceDestroyIOProcID(device.id, id)
            procID = nil
            throw CaptureError.coreAudio("AudioDeviceStart", startStatus)
        }
    }

    func stop() {
        if let procID {
            AudioDeviceStop(device.id, procID)
            AudioDeviceDestroyIOProcID(device.id, procID)
            self.procID = nil
        }

        writerQueue.sync {
            flush()
            writerTimer?.cancel()
            writerTimer = nil
            if let outputFile {
                ExtAudioFileDispose(outputFile)
                self.outputFile = nil
            }
        }
    }

    func report() {
        print("callbacks=\(callbackCount) writtenFrames=\(writtenFrames) discontinuities=\(discontinuityCount) droppedSamples=\(handoff.droppedSamples)")
        if let writeError {
            print("writeError=\(writeError)")
        }
    }

    func handle(inputData: UnsafePointer<AudioBufferList>, inputTime: UnsafePointer<AudioTimeStamp>) {
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        guard abl.count > 0 else { return }
        let bytesPerSample = Self.bytesPerSample(asbd)
        guard bytesPerSample > 0 else { return }

        let first = abl[0]
        guard first.mData != nil, first.mDataByteSize > 0 else { return }
        let firstChannels = max(1, Int(first.mNumberChannels))
        let frameCount = Int(first.mDataByteSize) / bytesPerSample / firstChannels
        guard frameCount > 0 else { return }

        logTiming(inputTime: inputTime.pointee, frameCount: frameCount)

        var totalChannels = 0
        for buffer in abl {
            totalChannels += Int(buffer.mNumberChannels)
        }
        let nativeChannels = max(1, totalChannels)
        let sampleCount = frameCount * nativeChannels
        if scratch.count < sampleCount {
            scratch = [Float](repeating: 0, count: sampleCount)
        }

        if abl.count == 1 {
            guard let data = first.mData else { return }
            for i in 0..<sampleCount {
                scratch[i] = Self.readSample(data, sampleIndex: i, bytesPerSample: bytesPerSample, format: asbd)
            }
        } else {
            var channelOffset = 0
            for b in 0..<abl.count {
                let buffer = abl[b]
                guard let data = buffer.mData else { continue }
                let bufferChannels = Int(buffer.mNumberChannels)
                for frame in 0..<frameCount {
                    for channel in 0..<bufferChannels {
                        scratch[frame * nativeChannels + channelOffset + channel] = Self.readSample(
                            data,
                            sampleIndex: frame * bufferChannels + channel,
                            bytesPerSample: bytesPerSample,
                            format: asbd
                        )
                    }
                }
                channelOffset += bufferChannels
            }
        }

        scratch.withUnsafeBufferPointer { ptr in
            handoff.write(UnsafeBufferPointer(start: ptr.baseAddress, count: sampleCount))
        }

        callbackCount += 1
        if callbackCount == 1 || callbackCount % 500 == 0 {
            var peak: Float = 0
            var sumSq: Float = 0
            for i in 0..<sampleCount {
                let sample = scratch[i]
                let absSample = abs(sample)
                if absSample > peak { peak = absSample }
                sumSq += sample * sample
            }
            let rms = sqrt(sumSq / Float(sampleCount))
            print("callback #\(callbackCount): frames=\(frameCount) ch=\(nativeChannels) rms=\(rms) peak=\(peak)")
        }
    }

    private func createWriter(outputURL: URL) throws {
        var fileFormat = AudioStreamBasicDescription(
            mSampleRate: asbd.mSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(channels * MemoryLayout<Float>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(channels * MemoryLayout<Float>.size),
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var clientFormat = fileFormat
        var ref: ExtAudioFileRef?
        let createStatus = ExtAudioFileCreateWithURL(
            outputURL as CFURL,
            kAudioFileWAVEType,
            &fileFormat,
            nil,
            AudioFileFlags.eraseFile.rawValue,
            &ref
        )
        guard createStatus == noErr, let ref else { throw CaptureError.writer(createStatus) }

        let setStatus = ExtAudioFileSetProperty(
            ref,
            kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
            &clientFormat
        )
        guard setStatus == noErr else {
            ExtAudioFileDispose(ref)
            throw CaptureError.writer(setStatus)
        }
        outputFile = ref
    }

    private func flush() {
        guard writeError == nil, let outputFile else { return }
        let samples = handoff.drain()
        guard samples.count >= channels else { return }
        let usableCount = samples.count - (samples.count % channels)
        let frames = usableCount / channels
        guard frames > 0 else { return }

        samples.withUnsafeBufferPointer { ptr in
            var bufferList = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: UInt32(channels),
                    mDataByteSize: UInt32(usableCount * MemoryLayout<Float>.size),
                    mData: UnsafeMutableRawPointer(mutating: ptr.baseAddress)
                )
            )
            let status = ExtAudioFileWrite(outputFile, UInt32(frames), &bufferList)
            if status == noErr {
                writtenFrames += frames
            } else {
                writeError = CaptureError.writer(status)
            }
        }
    }

    private func logTiming(inputTime: AudioTimeStamp, frameCount: Int) {
        guard inputTime.mFlags.contains(.sampleTimeValid) else { return }
        let sampleTime = inputTime.mSampleTime
        if let previousSampleTime {
            let expected = previousSampleTime + Float64(previousFrameCount)
            let delta = sampleTime - expected
            if abs(delta) > 1.0 {
                discontinuityCount += 1
                print("sample-time discontinuity #\(discontinuityCount): expected=\(expected) actual=\(sampleTime) delta=\(delta)")
            }
        }
        previousSampleTime = sampleTime
        previousFrameCount = frameCount
    }

    private static func bytesPerSample(_ format: AudioStreamBasicDescription) -> Int {
        if format.mBitsPerChannel > 0 {
            return Int((format.mBitsPerChannel + 7) / 8)
        }
        let channels = max(1, Int(format.mChannelsPerFrame))
        if format.mBytesPerFrame > 0 {
            return max(1, Int(format.mBytesPerFrame) / channels)
        }
        return 0
    }

    private static func readSample(
        _ raw: UnsafeMutableRawPointer,
        sampleIndex: Int,
        bytesPerSample: Int,
        format: AudioStreamBasicDescription
    ) -> Float {
        let flags = format.mFormatFlags
        let sample = raw.advanced(by: sampleIndex * bytesPerSample)
        if (flags & kAudioFormatFlagIsFloat) != 0 {
            if bytesPerSample == MemoryLayout<Float>.size {
                return sample.assumingMemoryBound(to: Float.self).pointee
            }
            if bytesPerSample == MemoryLayout<Double>.size {
                return Float(sample.assumingMemoryBound(to: Double.self).pointee)
            }
            return 0
        }

        guard (flags & kAudioFormatFlagIsSignedInteger) != 0 else { return 0 }
        switch bytesPerSample {
        case 2:
            return Float(sample.load(as: Int16.self)) / Float(Int16.max)
        case 3:
            let bytes = sample.assumingMemoryBound(to: UInt8.self)
            let rawValue = Int32(bytes[0]) | (Int32(bytes[1]) << 8) | (Int32(bytes[2]) << 16)
            let signed = (rawValue & 0x800000) != 0 ? rawValue | ~0xFFFFFF : rawValue
            return Float(signed) / 8_388_607.0
        case 4:
            return Float(sample.load(as: Int32.self)) / Float(Int32.max)
        default:
            return 0
        }
    }
}

private final class AUHALInputRecorder: @unchecked Sendable {
    private let device: InputDevice
    private let deviceFormat: AudioStreamBasicDescription
    private var clientFormat: AudioStreamBasicDescription
    private let channels: Int
    private let handoff: SampleHandoff
    private let writerQueue = DispatchQueue(label: "usb-audio-capture.auhal.writer")
    private var writerTimer: DispatchSourceTimer?
    private var outputFile: ExtAudioFileRef?
    private var audioUnit: AudioUnit?
    private var renderBufferList: UnsafeMutableAudioBufferListPointer?
    private var renderBufferStorage: [UnsafeMutableRawPointer] = []
    private var callbackCount = 0
    private var previousSampleTime: Float64?
    private var previousFrameCount = 0
    private var discontinuityCount = 0
    private var writeError: Error?
    private var writtenFrames = 0

    init(device: InputDevice, asbd: AudioStreamBasicDescription) {
        self.device = device
        self.deviceFormat = asbd
        self.channels = max(1, Int(asbd.mChannelsPerFrame))
        self.clientFormat = AudioStreamBasicDescription(
            mSampleRate: asbd.mSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: UInt32(MemoryLayout<Float>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(MemoryLayout<Float>.size),
            mChannelsPerFrame: UInt32(self.channels),
            mBitsPerChannel: 32,
            mReserved: 0
        )
        let capacitySamples = max(48_000, Int(asbd.mSampleRate) * self.channels * 4)
        self.handoff = SampleHandoff(capacitySamples: capacitySamples)
    }

    func start(outputURL: URL) throws {
        try createWriter(outputURL: outputURL)
        try createAudioUnit()
        try configureAudioUnit()
        try allocateRenderBuffers()

        let timer = DispatchSource.makeTimerSource(queue: writerQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(20))
        timer.setEventHandler { [weak self] in self?.flush() }
        timer.resume()
        writerTimer = timer

        guard let audioUnit else { throw CaptureError.coreAudio("AudioComponentInstanceNew", -1) }
        let initStatus = AudioUnitInitialize(audioUnit)
        guard initStatus == noErr else { throw CaptureError.coreAudio("AudioUnitInitialize", initStatus) }
        let startStatus = AudioOutputUnitStart(audioUnit)
        guard startStatus == noErr else { throw CaptureError.coreAudio("AudioOutputUnitStart", startStatus) }
    }

    func stop() {
        if let audioUnit {
            AudioOutputUnitStop(audioUnit)
            AudioUnitUninitialize(audioUnit)
            AudioComponentInstanceDispose(audioUnit)
            self.audioUnit = nil
        }

        writerQueue.sync {
            flush()
            writerTimer?.cancel()
            writerTimer = nil
            if let outputFile {
                ExtAudioFileDispose(outputFile)
                self.outputFile = nil
            }
        }

        for pointer in renderBufferStorage {
            pointer.deallocate()
        }
        renderBufferStorage.removeAll()
        renderBufferList?.unsafeMutablePointer.deallocate()
        renderBufferList = nil
    }

    func report() {
        print("callbacks=\(callbackCount) writtenFrames=\(writtenFrames) discontinuities=\(discontinuityCount) droppedSamples=\(handoff.droppedSamples)")
        if let writeError {
            print("writeError=\(writeError)")
        }
    }

    func render(
        actionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timeStamp: UnsafePointer<AudioTimeStamp>,
        busNumber: UInt32,
        frameCount: UInt32
    ) -> OSStatus {
        guard let audioUnit, let renderBufferList else { return noErr }
        for index in 0..<renderBufferList.count {
            renderBufferList[index].mDataByteSize = frameCount * UInt32(MemoryLayout<Float>.size)
        }

        let status = AudioUnitRender(audioUnit, actionFlags, timeStamp, busNumber, frameCount, renderBufferList.unsafeMutablePointer)
        guard status == noErr else {
            print("AudioUnitRender failed: \(fourCC(status))")
            return noErr
        }

        let frames = Int(frameCount)
        let sampleCount = frames * channels
        var interleaved = [Float](repeating: 0, count: sampleCount)
        for channel in 0..<min(channels, renderBufferList.count) {
            guard let data = renderBufferList[channel].mData?.assumingMemoryBound(to: Float.self) else { continue }
            for frame in 0..<frames {
                interleaved[frame * channels + channel] = data[frame]
            }
        }

        interleaved.withUnsafeBufferPointer { ptr in
            handoff.write(ptr)
        }

        logTiming(inputTime: timeStamp.pointee, frameCount: frames)
        callbackCount += 1
        if callbackCount == 1 || callbackCount % 500 == 0 {
            var peak: Float = 0
            var sumSq: Float = 0
            for sample in interleaved {
                let absSample = abs(sample)
                if absSample > peak { peak = absSample }
                sumSq += sample * sample
            }
            let rms = sqrt(sumSq / Float(max(1, interleaved.count)))
            print("callback #\(callbackCount): frames=\(frames) ch=\(channels) rms=\(rms) peak=\(peak)")
        }
        return noErr
    }

    private func createAudioUnit() throws {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw CaptureError.coreAudio("AudioComponentFindNext(HALOutput)", -1)
        }
        var unit: AudioUnit?
        let status = AudioComponentInstanceNew(component, &unit)
        guard status == noErr, let unit else { throw CaptureError.coreAudio("AudioComponentInstanceNew", status) }
        audioUnit = unit
    }

    private func configureAudioUnit() throws {
        guard let audioUnit else { throw CaptureError.coreAudio("configureAudioUnit", -1) }
        var enable: UInt32 = 1
        var disable: UInt32 = 0
        var status = AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enable, UInt32(MemoryLayout<UInt32>.size))
        guard status == noErr else { throw CaptureError.coreAudio("EnableIO(input)", status) }
        status = AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &disable, UInt32(MemoryLayout<UInt32>.size))
        guard status == noErr else { throw CaptureError.coreAudio("EnableIO(output)", status) }

        var deviceID = device.id
        status = AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else { throw CaptureError.coreAudio("CurrentDevice", status) }

        var format = clientFormat
        status = AudioUnitSetProperty(audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &format, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        guard status == noErr else { throw CaptureError.coreAudio("StreamFormat(output bus 1)", status) }

        var callback = AURenderCallbackStruct(
            inputProc: auhalInputCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        status = AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        guard status == noErr else { throw CaptureError.coreAudio("SetInputCallback", status) }

        var actual = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = AudioUnitGetProperty(audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &actual, &size)
        if status == noErr {
            clientFormat = actual
            print("auhal client format: \(describe(actual))")
        }
    }

    private func allocateRenderBuffers() throws {
        guard let audioUnit else { throw CaptureError.coreAudio("allocateRenderBuffers", -1) }
        var frameCount: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioUnitGetProperty(audioUnit, kAudioDevicePropertyBufferFrameSize, kAudioUnitScope_Global, 0, &frameCount, &size)
        guard status == noErr else { throw CaptureError.coreAudio("BufferFrameSize", status) }
        let bufferFrames = max(4096, Int(frameCount))
        let bufferListSize = MemoryLayout<AudioBufferList>.offset(of: \.mBuffers)! + MemoryLayout<AudioBuffer>.stride * channels
        let rawList = UnsafeMutableRawPointer.allocate(byteCount: bufferListSize, alignment: MemoryLayout<AudioBufferList>.alignment)
        rawList.initializeMemory(as: UInt8.self, repeating: 0, count: bufferListSize)
        let listPointer = rawList.bindMemory(to: AudioBufferList.self, capacity: 1)
        listPointer.pointee.mNumberBuffers = UInt32(channels)
        let list = UnsafeMutableAudioBufferListPointer(listPointer)
        for channel in 0..<channels {
            let data = UnsafeMutableRawPointer.allocate(
                byteCount: bufferFrames * MemoryLayout<Float>.size,
                alignment: MemoryLayout<Float>.alignment
            )
            data.initializeMemory(as: UInt8.self, repeating: 0, count: bufferFrames * MemoryLayout<Float>.size)
            renderBufferStorage.append(data)
            list[channel].mNumberChannels = 1
            list[channel].mDataByteSize = UInt32(bufferFrames * MemoryLayout<Float>.size)
            list[channel].mData = data
        }
        renderBufferList = list
        print("auhal render buffers: frames=\(bufferFrames) buffers=\(channels)")
    }

    private func createWriter(outputURL: URL) throws {
        var fileFormat = AudioStreamBasicDescription(
            mSampleRate: deviceFormat.mSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(channels * MemoryLayout<Float>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(channels * MemoryLayout<Float>.size),
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var clientFormat = fileFormat
        var ref: ExtAudioFileRef?
        let createStatus = ExtAudioFileCreateWithURL(
            outputURL as CFURL,
            kAudioFileWAVEType,
            &fileFormat,
            nil,
            AudioFileFlags.eraseFile.rawValue,
            &ref
        )
        guard createStatus == noErr, let ref else { throw CaptureError.writer(createStatus) }
        let setStatus = ExtAudioFileSetProperty(ref, kExtAudioFileProperty_ClientDataFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &clientFormat)
        guard setStatus == noErr else {
            ExtAudioFileDispose(ref)
            throw CaptureError.writer(setStatus)
        }
        outputFile = ref
    }

    private func flush() {
        guard writeError == nil, let outputFile else { return }
        let samples = handoff.drain()
        guard samples.count >= channels else { return }
        let usableCount = samples.count - (samples.count % channels)
        let frames = usableCount / channels
        guard frames > 0 else { return }
        samples.withUnsafeBufferPointer { ptr in
            var bufferList = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: UInt32(channels),
                    mDataByteSize: UInt32(usableCount * MemoryLayout<Float>.size),
                    mData: UnsafeMutableRawPointer(mutating: ptr.baseAddress)
                )
            )
            let status = ExtAudioFileWrite(outputFile, UInt32(frames), &bufferList)
            if status == noErr {
                writtenFrames += frames
            } else {
                writeError = CaptureError.writer(status)
            }
        }
    }

    private func logTiming(inputTime: AudioTimeStamp, frameCount: Int) {
        guard inputTime.mFlags.contains(.sampleTimeValid) else { return }
        let sampleTime = inputTime.mSampleTime
        if let previousSampleTime {
            let expected = previousSampleTime + Float64(previousFrameCount)
            let delta = sampleTime - expected
            if abs(delta) > 1.0 {
                discontinuityCount += 1
                print("sample-time discontinuity #\(discontinuityCount): expected=\(expected) actual=\(sampleTime) delta=\(delta)")
            }
        }
        previousSampleTime = sampleTime
        previousFrameCount = frameCount
    }
}

private func auhalInputCallback(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let recorder = Unmanaged<AUHALInputRecorder>.fromOpaque(inRefCon).takeUnretainedValue()
    return recorder.render(
        actionFlags: ioActionFlags,
        timeStamp: inTimeStamp,
        busNumber: inBusNumber,
        frameCount: inNumberFrames
    )
}

private func nativeInputIOProc(
    inDevice: AudioObjectID,
    inNow: UnsafePointer<AudioTimeStamp>,
    inInputData: UnsafePointer<AudioBufferList>,
    inInputTime: UnsafePointer<AudioTimeStamp>,
    outOutputData: UnsafeMutablePointer<AudioBufferList>,
    inOutputTime: UnsafePointer<AudioTimeStamp>,
    inClientData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let inClientData else { return noErr }
    let recorder = Unmanaged<NativeInputRecorder>.fromOpaque(inClientData).takeUnretainedValue()
    recorder.handle(inputData: inInputData, inputTime: inInputTime)
    return noErr
}

private struct Arguments {
    enum Mode: String {
        case ioProc = "ioproc"
        case auhal
    }

    var list = false
    var uid: String?
    var name: String?
    var seconds: Double = 10
    var output: String?
    var mode: Mode = .ioProc

    init(_ args: [String]) throws {
        var iterator = args.dropFirst().makeIterator()
        while let arg = iterator.next() {
            switch arg {
            case "--":
                continue
            case "--list":
                list = true
            case "--uid":
                uid = iterator.next()
            case "--name":
                name = iterator.next()
            case "--seconds":
                if let value = iterator.next(), let parsed = Double(value) {
                    seconds = parsed
                }
            case "--output":
                output = iterator.next()
            case "--mode":
                if let value = iterator.next(), let parsed = Mode(rawValue: value) {
                    mode = parsed
                } else {
                    throw CaptureError.deviceNotFound("mode must be ioproc or auhal")
                }
            case "--help", "-h":
                printUsage()
                exit(0)
            default:
                throw CaptureError.deviceNotFound("unknown argument \(arg)")
            }
        }
    }
}

private func printUsage() {
    print("""
    Usage:
      swift run usb-audio-capture -- --list
      swift run usb-audio-capture -- --name "USB audio device" --seconds 10 --output /tmp/usb-audio-native.wav
      swift run usb-audio-capture -- --mode auhal --name "USB audio device" --seconds 10 --output /tmp/usb-audio-auhal.wav
      swift run usb-audio-capture -- --uid <device-uid> --seconds 10

    Captures native CoreAudio input to Float32 WAV with no resampling, gain, mixing, or live transcript.
    """)
}

@main
private enum Main {
    static func main() {
        do {
            let arguments = try Arguments(CommandLine.arguments)
            let devices = try inputDevices()
            guard !devices.isEmpty else { throw CaptureError.noInputDevices }

            if arguments.list {
                for device in devices {
                    let stream = try? streams(for: device.id).first
                    let format = try? stream.map { try virtualFormat(for: $0) }
                    print("[\(device.id)] \(device.name) uid=\(device.uid) channels=\(inputChannelCount(device.id)) rates=\(sampleRateSummary(for: device.id)) format=\(format.map(describe) ?? "unknown")")
                }
                return
            }

            let selected: InputDevice
            if let uid = arguments.uid {
                guard let match = devices.first(where: { $0.uid == uid }) else {
                    throw CaptureError.deviceNotFound("uid=\(uid)")
                }
                selected = match
            } else {
                let query = arguments.name ?? "USB audio device"
                guard let match = devices.first(where: { $0.name.localizedCaseInsensitiveContains(query) }) else {
                    throw CaptureError.deviceNotFound("name contains \(query)")
                }
                selected = match
            }

            guard let stream = try streams(for: selected.id).first else {
                throw CaptureError.noInputStream(selected.id)
            }
            let format = try virtualFormat(for: stream)
            guard format.mChannelsPerFrame > 0 else { throw CaptureError.unsupportedFormat(format) }

            let outputURL: URL
            if let output = arguments.output {
                outputURL = URL(fileURLWithPath: output)
            } else {
                let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
                outputURL = URL(fileURLWithPath: "/tmp/usb-audio-native-\(stamp).wav")
            }

            print("device: \(selected.name) uid=\(selected.uid) id=\(selected.id)")
            print("format: \(describe(format))")
            print("rates before start: \(sampleRateSummary(for: selected.id))")
            print("output: \(outputURL.path)")
            print("mode: \(arguments.mode.rawValue)")
            print("capturing \(arguments.seconds)s...")

            switch arguments.mode {
            case .ioProc:
                let recorder = NativeInputRecorder(device: selected, asbd: format)
                try recorder.start(outputURL: outputURL)
                print("rates after start: \(sampleRateSummary(for: selected.id))")
                Thread.sleep(forTimeInterval: max(0.1, arguments.seconds))
                recorder.stop()
                recorder.report()
            case .auhal:
                let recorder = AUHALInputRecorder(device: selected, asbd: format)
                try recorder.start(outputURL: outputURL)
                print("rates after start: \(sampleRateSummary(for: selected.id))")
                Thread.sleep(forTimeInterval: max(0.1, arguments.seconds))
                recorder.stop()
                recorder.report()
            }
            print("done: \(outputURL.path)")
        } catch {
            fputs("error: \(error)\n", stderr)
            printUsage()
            exit(1)
        }
    }
}
