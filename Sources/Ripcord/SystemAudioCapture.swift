import CoreAudio
import AudioToolbox

final class SystemAudioCapture: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.vibe.ripcord.systemaudio")
    var onSamples: (([Float]) -> Void)?
    private var tapID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var tapFormat: AudioStreamBasicDescription?

    private var deviceChangeListenerBlock: AudioObjectPropertyListenerBlock?
    private var restartTask: Task<Void, Never>?

    // Resampling state (lazy-initialized if tap sample rate differs from target)
    private var converter: AudioConverterRef?

    // Pre-allocated buffers for handleIOBlock (accessed only on serial queue)
    private var monoBuffer = [Float](repeating: 0, count: 8192)
    private var resampleOutputBuffer = [Float](repeating: 0, count: 16384)

    func start() async throws {
        // Get our own PID and translate to AudioObjectID so we can exclude ourselves
        let myPID = ProcessInfo.processInfo.processIdentifier
        let myObjectID = try translatePIDToProcessObject(myPID)

        // Create a mono global tap that captures ALL system audio except our process
        let tapDescription = CATapDescription(monoGlobalTapButExcludeProcesses: [myObjectID])
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
            kAudioAggregateDeviceTapAutoStartKey: true,
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

        installDeviceChangeListener()
    }

    func stop() {
        removeDeviceChangeListener()

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

    // MARK: - Device Change Listener

    private func installDeviceChangeListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            // Cancel any pending restart to debounce rapid notifications
            self.restartTask?.cancel()
            self.restartTask = Task { @MainActor [weak self] in
                // Debounce: wait 0.5s since macOS can fire multiple change
                // notifications rapidly during a device switch
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, let self else { return }
                self.stop()
                do {
                    try await self.start()
                } catch {
                    // Device may not be ready yet; nothing we can do here
                }
            }
        }
        deviceChangeListenerBlock = block
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block
        )
    }

    private func removeDeviceChangeListener() {
        if let block = deviceChangeListenerBlock {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block
            )
            deviceChangeListenerBlock = nil
        }
        restartTask?.cancel()
        restartTask = nil
    }

    // MARK: - I/O Block Handler

    private func handleIOBlock(inputData: UnsafePointer<AudioBufferList>, callback: (([Float]) -> Void)?) {
        let bufferList = inputData.pointee
        let buf = bufferList.mBuffers

        guard let data = buf.mData, buf.mDataByteSize > 0 else { return }

        let floatCount = Int(buf.mDataByteSize) / MemoryLayout<Float>.size
        guard floatCount > 0 else { return }

        let floatPtr = data.assumingMemoryBound(to: Float.self)
        let channelCount = Int(buf.mNumberChannels)

        let samples: [Float]
        if channelCount == 1 {
            samples = Array(UnsafeBufferPointer(start: floatPtr, count: floatCount))
        } else {
            // Mix down to mono
            let frameCount = floatCount / channelCount
            let scale = 1.0 / Float(channelCount)

            // Grow buffer if needed
            if monoBuffer.count < frameCount {
                monoBuffer = [Float](repeating: 0, count: frameCount)
            }

            for i in 0..<frameCount {
                var sum: Float = 0
                for ch in 0..<channelCount {
                    sum += floatPtr[i * channelCount + ch]
                }
                monoBuffer[i] = sum * scale
            }
            // Create array for consumer
            samples = Array(monoBuffer.prefix(frameCount))
        }

        // Resample if needed, then deliver
        if converter != nil {
            if let resampled = resample(samples) {
                callback?(resampled)
            }
        } else {
            callback?(samples)
        }
    }

    // MARK: - Resampling

    private static func monoFloat32ASBD(sampleRate: Double) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )
    }

    private func setupResampler(sourceFormat: AudioStreamBasicDescription) throws {
        var inputFormat = Self.monoFloat32ASBD(sampleRate: sourceFormat.mSampleRate)
        var outputFormat = Self.monoFloat32ASBD(sampleRate: AudioConstants.sampleRate)

        var conv: AudioConverterRef?
        let err = AudioConverterNew(&inputFormat, &outputFormat, &conv)
        guard err == noErr, let conv else {
            throw CaptureError.resamplerFailed(err)
        }
        self.converter = conv
    }

    private func resample(_ input: [Float]) -> [Float]? {
        guard let converter else { return nil }
        guard let tapFormat, tapFormat.mSampleRate > 0 else { return input }

        let ratio = AudioConstants.sampleRate / tapFormat.mSampleRate
        let outputFrameCount = Int(Double(input.count) * ratio) + 1

        // Grow resample output buffer if needed
        if resampleOutputBuffer.count < outputFrameCount {
            resampleOutputBuffer = [Float](repeating: 0, count: outputFrameCount)
        }

        var ioOutputDataPacketSize = UInt32(outputFrameCount)

        var inputCopy = input

        let err = inputCopy.withUnsafeMutableBytes { inputPtr in
            resampleOutputBuffer.withUnsafeMutableBytes { outputPtr -> OSStatus in
                var inputBufList = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(
                        mNumberChannels: 1,
                        mDataByteSize: UInt32(input.count * MemoryLayout<Float>.size),
                        mData: inputPtr.baseAddress
                    )
                )

                var outputBufList = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(
                        mNumberChannels: 1,
                        mDataByteSize: UInt32(outputFrameCount * MemoryLayout<Float>.size),
                        mData: outputPtr.baseAddress
                    )
                )

                return AudioConverterFillComplexBuffer(
                    converter,
                    { (_, ioNumberDataPackets, ioData, _, inUserData) -> OSStatus in
                        guard let userData = inUserData else {
                            ioNumberDataPackets.pointee = 0
                            return -50 // paramErr
                        }
                        let srcBufList = userData.assumingMemoryBound(to: AudioBufferList.self)
                        let available = srcBufList.pointee.mBuffers.mDataByteSize
                        if available == 0 {
                            ioNumberDataPackets.pointee = 0
                            return -50 // no more data
                        }
                        ioData.pointee.mBuffers.mData = srcBufList.pointee.mBuffers.mData
                        ioData.pointee.mBuffers.mDataByteSize = available
                        ioNumberDataPackets.pointee = available / 4
                        // Mark as consumed
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

        // Accept noErr or "no more data" (-50) as valid outcomes
        guard err == noErr || err == -50 else { return nil }

        let actualCount = Int(ioOutputDataPacketSize)
        guard actualCount > 0 else { return nil }
        return Array(resampleOutputBuffer.prefix(actualCount))
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
