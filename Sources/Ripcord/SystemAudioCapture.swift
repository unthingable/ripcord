import CoreAudio
import AudioToolbox
import os.log

private let logger = Logger(subsystem: "com.vibe.ripcord", category: "SysCapture")

final class SystemAudioCapture: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.vibe.ripcord.systemaudio")
    deinit { stop() }

    var onSamples: ((UnsafeBufferPointer<Float>) -> Void)?

    /// Called before and after route-change restart so the owner can cycle
    /// other audio inputs (e.g. mic AUHAL) and avoid IOState escalation.
    var onWillRestart: (() -> Void)?
    var onDidRestart: (() async -> Void)?
    /// Called immediately when a route change is detected, before debouncing.
    var onRouteChangeDetected: (() -> Void)?

    private var tapID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var tapFormat: AudioStreamBasicDescription?

    // Resampling state (lazy-initialized if tap sample rate differs from target)
    private var converter: AudioConverterRef?

    // Serializes teardown so stop() and restartAfterRouteChange() can't
    // double-destroy the same CoreAudio objects.
    private let resourceLock = NSLock()

    // Route-change handling
    private var routeChangeListener: AudioObjectPropertyListenerBlock?
    private var restartWorkItem: DispatchWorkItem?
    private var restartTask: Task<Void, Never>?

    // Pre-allocated buffers for handleIOBlock (accessed only on serial queue).
    // stereoBuffer: stereo-interleaved at tap rate (after channel projection)
    // resampleOutputBuffer: stereo-interleaved at 48 kHz (after resampling)
    private var stereoBuffer = [Float](repeating: 0, count: 16384)
    private var resampleOutputBuffer = [Float](repeating: 0, count: 16384)

    func start() async throws {
        // Get our own PID and translate to AudioObjectID so we can exclude ourselves
        let myPID = ProcessInfo.processInfo.processIdentifier
        let myObjectID = try translatePIDToProcessObject(myPID)

        // Capture system audio as stereo. Recording split mode downmixes later;
        // mixed mode preserves incoming L/R.
        let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: [myObjectID])
        tapDescription.name = "Ripcord System Audio Tap"
        tapDescription.uuid = UUID()
        tapDescription.muteBehavior = .unmuted
        tapDescription.isPrivate = true

        var newTapID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
        var err = AudioHardwareCreateProcessTap(tapDescription, &newTapID)
        guard err == noErr else {
            throw CaptureError.tapCreationFailed(err)
        }
        self.tapID = newTapID

        // Read the tap's audio format
        self.tapFormat = try readTapFormat(tapID: newTapID)

        // Read the tap's UID
        let tapUID = try readTapUID(tapID: newTapID)

        // Create an aggregate device that includes the tap
        let aggregateUID = UUID().uuidString
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Ripcord-Tap",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUID
                ]
            ] as [[String: Any]],
            kAudioAggregateDeviceSubDeviceListKey: [] as [Any],
        ]

        var newDeviceID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
        err = AudioHardwareCreateAggregateDevice(description as CFDictionary, &newDeviceID)
        guard err == noErr else {
            throw CaptureError.aggregateDeviceFailed(err)
        }
        self.aggregateDeviceID = newDeviceID

        // Wait for aggregate device to become ready (poll up to 1 second)
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(50))
            if let format = readDeviceInputFormat(deviceID: newDeviceID), format.mSampleRate > 0 {
                break
            }
        }

        // Read the actual input format from the aggregate device (may differ from tap format)
        if let deviceFormat = readDeviceInputFormat(deviceID: newDeviceID) {
            self.tapFormat = deviceFormat
        }

        // Set up resampler if the tap sample rate differs from our target
        if let tapFormat = self.tapFormat, tapFormat.mSampleRate != AudioConstants.sampleRate {
            try setupResampler(sourceFormat: tapFormat)
        }

        // Capture the onSamples callback to avoid concurrent access
        let samplesCallback = self.onSamples

        // Create the I/O proc to receive audio data
        var newProcID: AudioDeviceIOProcID?
        err = AudioDeviceCreateIOProcIDWithBlock(&newProcID, newDeviceID, queue) {
            [weak self] _, inInputData, _, _, _ in
            guard let self else { return }
            self.handleIOBlock(inputData: inInputData, callback: samplesCallback)
        }
        guard err == noErr else {
            throw CaptureError.ioProcFailed(err)
        }
        self.ioProcID = newProcID

        // Start the device
        err = AudioDeviceStart(newDeviceID, newProcID)
        guard err == noErr else {
            throw CaptureError.deviceStartFailed(err)
        }

        installRouteChangeListener()
    }

    func stop() {
        restartWorkItem?.cancel()
        restartWorkItem = nil
        restartTask?.cancel()
        restartTask = nil
        removeRouteChangeListener()
        tearDownResources()
    }

    /// Atomically claims and destroys all CoreAudio resources.  Safe to call
    /// from multiple threads — the lock ensures only the first caller tears
    /// down; subsequent callers find everything already nil/unknown.
    private func tearDownResources() {
        resourceLock.lock()
        defer { resourceLock.unlock() }

        if let ioProcID, aggregateDeviceID != kAudioObjectUnknown {
            _ = AudioDeviceStop(aggregateDeviceID, ioProcID)
            _ = AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
            self.ioProcID = nil
        }

        if aggregateDeviceID != kAudioObjectUnknown {
            _ = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        }

        if tapID != kAudioObjectUnknown {
            _ = AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }

        if let converter {
            AudioConverterDispose(converter)
            self.converter = nil
        }
    }

    // MARK: - Route Change Handling

    private func installRouteChangeListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            self.handleRouteChange()
        }
        routeChangeListener = block

        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block
        )
    }

    private func removeRouteChangeListener() {
        guard let block = routeChangeListener else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block
        )
        routeChangeListener = nil
    }

    private func handleRouteChange() {
        logger.error("Output device changed, scheduling recycle")
        onRouteChangeDetected?()

        // Do NO CoreAudio calls on main — they can block for 1-2 seconds
        // (AUHAL SelectDevice) and deadlock the main thread.
        // Debounced full teardown + restart off main.
        restartWorkItem?.cancel()
        restartTask?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.restartTask = Task { await self.restartAfterRouteChange() }
        }
        restartWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
    }

    private func restartAfterRouteChange() async {
        // Full teardown runs on the cooperative thread pool, not main.
        guard !Task.isCancelled else { return }

        // Stop other input sessions (mic AUHAL) BEFORE our teardown so that
        // IOState goes through [0, 0] instead of [1, 0] → [2, 0].
        // The [2, 0] escalation blocks VoiceProcessingIO in meeting apps.
        onWillRestart?()
        tearDownResources()

        // Check cancellation before expensive recreation
        guard !Task.isCancelled else { return }

        removeRouteChangeListener()

        do {
            try await start()
            logger.error("System capture restarted after route change")
        } catch {
            logger.error("System capture restart failed: \(error.localizedDescription)")
        }

        // Restart other input sessions after our restart completes
        await onDidRestart?()
    }

    // MARK: - I/O Block Handler

    private var ioBlockCount = 0

    private func handleIOBlock(inputData: UnsafePointer<AudioBufferList>, callback: ((UnsafeBufferPointer<Float>) -> Void)?) {
        let bufferList = inputData.pointee
        let buf = bufferList.mBuffers

        guard let data = buf.mData, buf.mDataByteSize > 0 else { return }

        let floatCount = Int(buf.mDataByteSize) / MemoryLayout<Float>.size
        guard floatCount > 0 else { return }

        let floatPtr = data.assumingMemoryBound(to: Float.self)
        let channelCount = max(1, Int(buf.mNumberChannels))
        let frameCount = floatCount / channelCount
        guard frameCount > 0 else { return }

        // Project tap audio onto stereo-interleaved: mono → duplicated L=R;
        // stereo → pass-through; >2 channels → take first two (front L/R of
        // typical surround layouts). We don't trust CoreAudio's downmix policy
        // for the same reasons MicrophoneCapture handles channels itself.
        let stereoSize = frameCount * 2
        if stereoBuffer.count < stereoSize {
            stereoBuffer = [Float](repeating: 0, count: stereoSize)
        }
        if channelCount == 1 {
            for f in 0..<frameCount {
                let s = floatPtr[f]
                stereoBuffer[f * 2]     = s
                stereoBuffer[f * 2 + 1] = s
            }
        } else {
            for f in 0..<frameCount {
                let base = f * channelCount
                stereoBuffer[f * 2]     = floatPtr[base]
                stereoBuffer[f * 2 + 1] = floatPtr[base + 1]
            }
        }
        ioBlockCount += 1
        if ioBlockCount == 1 || ioBlockCount % 500 == 0 {
            var peak: Float = 0
            for i in 0..<stereoSize {
                let a = abs(stereoBuffer[i])
                if a > peak { peak = a }
            }
            logger.error("IOBlock #\(self.ioBlockCount) frames=\(frameCount) ch=\(channelCount) peak=\(peak) converter=\(self.converter != nil)")
        }

        if converter != nil {
            if let resampledCount = resample(frameCount: frameCount) {
                resampleOutputBuffer.withUnsafeBufferPointer { ptr in
                    callback?(UnsafeBufferPointer(start: ptr.baseAddress, count: resampledCount))
                }
            }
        } else {
            stereoBuffer.withUnsafeBufferPointer { ptr in
                callback?(UnsafeBufferPointer(start: ptr.baseAddress, count: stereoSize))
            }
        }
    }

    // MARK: - Resampling

    private static func stereoFloat32InterleavedASBD(sampleRate: Double) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8,
            mFramesPerPacket: 1,
            mBytesPerFrame: 8,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )
    }

    private func setupResampler(sourceFormat: AudioStreamBasicDescription) throws {
        var inputFormat = Self.stereoFloat32InterleavedASBD(sampleRate: sourceFormat.mSampleRate)
        var outputFormat = Self.stereoFloat32InterleavedASBD(sampleRate: AudioConstants.sampleRate)

        var conv: AudioConverterRef?
        let err = AudioConverterNew(&inputFormat, &outputFormat, &conv)
        guard err == noErr, let conv else {
            throw CaptureError.resamplerFailed(err)
        }
        self.converter = conv
    }

    // Sentinel returned by the converter data proc when all input has been
    // consumed.  Must not collide with a real OSStatus error.
    private static let kNoMoreData: OSStatus = 1

    /// Resample stereo-interleaved data in `stereoBuffer` (frameCount frames)
    /// from the tap's native rate to 48 kHz. Writes output to
    /// `resampleOutputBuffer`. Returns sample count (stereo), or nil on error.
    private func resample(frameCount: Int) -> Int? {
        guard let converter else { return nil }
        guard let tapFormat, tapFormat.mSampleRate > 0 else { return nil }

        let ratio = AudioConstants.sampleRate / tapFormat.mSampleRate
        let outputFrameCount = Int(Double(frameCount) * ratio) + 1
        let outputBufferSize = outputFrameCount * 2

        if resampleOutputBuffer.count < outputBufferSize {
            resampleOutputBuffer = [Float](repeating: 0, count: outputBufferSize)
        }

        let bytesPerFrame = 2 * MemoryLayout<Float>.size
        let inputByteSize = frameCount * bytesPerFrame
        var ioOutputDataPacketSize = UInt32(outputFrameCount)

        let err = stereoBuffer.withUnsafeMutableBytes { inputPtr in
            resampleOutputBuffer.withUnsafeMutableBytes { outputPtr -> OSStatus in
                var inputBufList = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(
                        mNumberChannels: 2,
                        mDataByteSize: UInt32(inputByteSize),
                        mData: inputPtr.baseAddress
                    )
                )

                var outputBufList = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(
                        mNumberChannels: 2,
                        mDataByteSize: UInt32(outputBufferSize * MemoryLayout<Float>.size),
                        mData: outputPtr.baseAddress
                    )
                )

                return AudioConverterFillComplexBuffer(
                    converter,
                    { (_, ioNumberDataPackets, ioData, _, inUserData) -> OSStatus in
                        guard let userData = inUserData else {
                            ioNumberDataPackets.pointee = 0
                            return SystemAudioCapture.kNoMoreData
                        }
                        let srcBufList = userData.assumingMemoryBound(to: AudioBufferList.self)
                        let available = srcBufList.pointee.mBuffers.mDataByteSize
                        if available == 0 {
                            ioNumberDataPackets.pointee = 0
                            return SystemAudioCapture.kNoMoreData
                        }
                        ioData.pointee.mBuffers.mData = srcBufList.pointee.mBuffers.mData
                        ioData.pointee.mBuffers.mDataByteSize = available
                        ioNumberDataPackets.pointee = available / 8
                        srcBufList.pointee.mBuffers.mDataByteSize = 0
                        srcBufList.pointee.mBuffers.mData = nil
                        return noErr
                    },
                    &inputBufList,
                    &ioOutputDataPacketSize,
                    &outputBufList,
                    nil
                )
            }
        }

        guard err == noErr || err == Self.kNoMoreData else { return nil }

        let actualFrameCount = Int(ioOutputDataPacketSize)
        guard actualFrameCount > 0 else { return nil }
        return actualFrameCount * 2
    }

    // MARK: - Core Audio Helpers

    private func translatePIDToProcessObject(_ pid: pid_t) throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var processObject: AudioObjectID = 0
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var mutablePID = pid

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            UInt32(MemoryLayout<pid_t>.size),
            &mutablePID,
            &size,
            &processObject
        )

        guard status == noErr, processObject != kAudioObjectUnknown else {
            throw CaptureError.pidTranslationFailed(pid)
        }
        return processObject
    }

    private func readTapFormat(tapID: AudioObjectID) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.stride)

        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format)
        guard status == noErr else {
            throw CaptureError.formatReadFailed(status)
        }
        return format
    }

    private func readTapUID(tapID: AudioObjectID) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)

        let status = withUnsafeMutablePointer(to: &uid) { ptr in
            AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, ptr)
        }
        guard status == noErr else {
            throw CaptureError.uidReadFailed(status)
        }
        return uid as String
    }

    private func readDeviceInputFormat(deviceID: AudioObjectID) -> AudioStreamBasicDescription? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.stride)

        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &format)
        guard status == noErr else { return nil }
        return format
    }

    // MARK: - Errors

    enum CaptureError: Error, LocalizedError {
        case tapCreationFailed(OSStatus)
        case aggregateDeviceFailed(OSStatus)
        case ioProcFailed(OSStatus)
        case deviceStartFailed(OSStatus)
        case pidTranslationFailed(pid_t)
        case formatReadFailed(OSStatus)
        case uidReadFailed(OSStatus)
        case resamplerFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .tapCreationFailed(let s): return "Failed to create audio tap (error \(s)). Grant System Audio Recording permission in System Settings > Privacy & Security."
            case .aggregateDeviceFailed(let s): return "Failed to create aggregate device (error \(s))"
            case .ioProcFailed(let s): return "Failed to create I/O proc (error \(s))"
            case .deviceStartFailed(let s): return "Failed to start audio device (error \(s))"
            case .pidTranslationFailed(let pid): return "Failed to translate PID \(pid) to audio object"
            case .formatReadFailed(let s): return "Failed to read tap format (error \(s))"
            case .uidReadFailed(let s): return "Failed to read tap UID (error \(s))"
            case .resamplerFailed(let s): return "Failed to create audio resampler (error \(s))"
            }
        }
    }
}
