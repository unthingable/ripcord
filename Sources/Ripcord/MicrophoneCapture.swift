import CoreAudio
import AudioToolbox
import AudioUnit
@preconcurrency import AVFoundation
import os.log

private let logger = Logger(subsystem: "com.vibe.ripcord", category: "MicCapture")

// C callback invoked by CoreAudio when the device has new input frames.
// IOProc is retained as a fallback; the primary path is AUHAL because it matches
// OBS's CoreAudio input path and behaves cleanly with the USB audio device.
private func micDeviceIOProc(
    inDevice: AudioObjectID,
    inNow: UnsafePointer<AudioTimeStamp>,
    inInputData: UnsafePointer<AudioBufferList>,
    inInputTime: UnsafePointer<AudioTimeStamp>,
    outOutputData: UnsafeMutablePointer<AudioBufferList>,
    inOutputTime: UnsafePointer<AudioTimeStamp>,
    inClientData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let inClientData else { return noErr }
    let capture = Unmanaged<MicrophoneCapture>.fromOpaque(inClientData).takeUnretainedValue()
    capture.handleIOInput(inputData: inInputData)
    return noErr
}

private func micAUHALInputCallback(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let capture = Unmanaged<MicrophoneCapture>.fromOpaque(inRefCon).takeUnretainedValue()
    return capture.handleAUHALInput(
        actionFlags: ioActionFlags,
        timeStamp: inTimeStamp,
        busNumber: inBusNumber,
        frameCount: inNumberFrames
    )
}

final class MicrophoneCapture: @unchecked Sendable {
    // IO proc registered with the device. nil when not running.
    private var ioProcID: AudioDeviceIOProcID?
    private var ioProcDevice: AudioDeviceID = 0
    private var auhalAudioUnit: AudioUnit?
    private var auhalRenderBufferList: UnsafeMutableAudioBufferListPointer?
    private var auhalRenderBufferStorage: [UnsafeMutableRawPointer] = []
    private let stateLock = NSLock()
    // All CoreAudio calls (teardown, restart, listener callbacks) run here — never on main.
    // CoreAudio property changes synchronously notify coreaudiod, which can block for 1-2s.
    // Running on main would stall the UI and block other apps' audio negotiation.
    private let audioQueue = DispatchQueue(label: "com.vibe.ripcord.micCapture")
    private var _isRunning = false
    private var currentDeviceID: AudioDeviceID?
    private var restartWorkItem: DispatchWorkItem?
    private var restartSuppressed = false

    // Device change listeners
    private var deviceAliveListener: AudioObjectPropertyListenerBlock?
    private var defaultInputListener: AudioObjectPropertyListenerBlock?
    private var listeningDeviceID: AudioDeviceID = 0

    // Resampling (when device rate != 48 kHz). Resampler always operates on
    // stereo-interleaved samples.
    private var deviceSampleRate: Double = 0
    private var deviceChannelCount: Int = 0
    private var deviceInputFormat = AudioStreamBasicDescription()
    private var channelMode: MicChannelMode = .monoDevice
    // Linear amplitude multiplier from the user's per-device input gain.
    // Read on the RT thread; assignment is atomic for aligned Float.
    private var inputGainLinear: Float = 1.0

    // Buffers (accessed only from the IO thread — pre-allocated to avoid
    // heap allocations on the real-time audio thread).
    // renderBuffer: device-native channels interleaved, native sample rate
    // extractedBuffer: stereo interleaved, native sample rate (after channel selection)
    // resampleOutputBuffer: stereo interleaved, 48 kHz (after resampling)
    private var renderBuffer = [Float](repeating: 0, count: 8192)
    private var extractedBuffer = [Float](repeating: 0, count: 16384)
    private var resampleOutputBuffer = [Float](repeating: 0, count: 16384)

    // Streaming linear resampler state for devices whose native sample rate is
    // not 48 kHz. This avoids per-callback AudioConverter buffering semantics
    // on the CoreAudio IO thread; phase carries across callbacks so the output
    // stream remains continuous.
    private var resamplerActive = false
    private var resampleStep: Double = 1.0
    private var resamplePhase: Double = 0
    private var hasPreviousResampleFrame = false
    private var previousResampleL: Float = 0
    private var previousResampleR: Float = 0

    // Captured at start() so the IO callback avoids a data race on onSamples.
    // Emitted samples are always stereo-interleaved at 48 kHz.
    private var capturedCallback: ((UnsafeBufferPointer<Float>) -> Void)?

    // Diagnostic: track render errors from the IO thread
    private var renderErrorCount = 0
    private var renderSuccessCount = 0

    // Diagnostic native tap. When enabled by RecordingManager, this records the
    // exact device-native samples seen by Ripcord before channel selection, gain,
    // resampling, mixing, or encoding.
    private let nativeDebugQueue = DispatchQueue(label: "com.vibe.ripcord.micCapture.nativeDebug")
    private var nativeDebugHandoff: AudioSampleHandoff?
    private var nativeDebugTimer: DispatchSourceTimer?
    private var nativeDebugFile: ExtAudioFileRef?
    private var nativeDebugChannels = 0

    var onSamples: ((UnsafeBufferPointer<Float>) -> Void)?

    var isRunning: Bool {
        stateLock.withLock { _isRunning }
    }

    deinit {
        stop()
    }

    func startNativeDebugRecording(url: URL) throws {
        let rate = deviceSampleRate
        let channels = max(1, deviceChannelCount)
        guard rate > 0 else { throw DeviceError.formatNotReady }

        var fileFormat = Self.interleavedFloat32ASBD(sampleRate: rate, channels: channels)
        var clientFormat = fileFormat
        var ref: ExtAudioFileRef?
        let createStatus = ExtAudioFileCreateWithURL(
            url as CFURL,
            kAudioFileWAVEType,
            &fileFormat,
            nil,
            AudioFileFlags.eraseFile.rawValue,
            &ref
        )
        guard createStatus == noErr, let ref else { throw DeviceError.osFailed(createStatus) }

        let setStatus = ExtAudioFileSetProperty(
            ref,
            kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
            &clientFormat
        )
        guard setStatus == noErr else {
            ExtAudioFileDispose(ref)
            throw DeviceError.osFailed(setStatus)
        }

        nativeDebugQueue.sync {
            nativeDebugFile = ref
            nativeDebugChannels = channels
            nativeDebugHandoff = AudioSampleHandoff(
                capacityFrames: max(Int(rate) * 4, 48_000),
                channelsPerFrame: channels
            )

            let timer = DispatchSource.makeTimerSource(queue: nativeDebugQueue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(20))
            timer.setEventHandler { [weak self] in self?.flushNativeDebugSamples() }
            timer.resume()
            nativeDebugTimer = timer
        }
        logger.error("Native mic debug recording started: \(url.path, privacy: .public) rate=\(rate, privacy: .public) channels=\(channels, privacy: .public)")
    }

    func stopNativeDebugRecording() {
        nativeDebugQueue.sync {
            flushNativeDebugSamples()
            nativeDebugTimer?.cancel()
            nativeDebugTimer = nil
            nativeDebugHandoff = nil
            nativeDebugChannels = 0
            if let nativeDebugFile {
                ExtAudioFileDispose(nativeDebugFile)
                self.nativeDebugFile = nil
            }
        }
        logger.error("Native mic debug recording stopped")
    }

    func start(
        deviceID: AudioDeviceID? = nil,
        channelMode: MicChannelMode = .monoDevice,
        gainDB: Double = 0
    ) throws {
        let alreadyRunning = stateLock.withLock {
            guard !_isRunning else { return true }
            _isRunning = true
            currentDeviceID = deviceID
            self.channelMode = channelMode
            self.inputGainLinear = MicGainStore.linearMultiplier(forDB: gainDB)
            return false
        }
        guard !alreadyRunning else { return }

        do {
            try startCapture()
        } catch {
            stateLock.withLock { _isRunning = false }
            throw error
        }
    }

    /// Core setup: resolve device, create audio unit, install listeners.
    /// Caller is responsible for setting _isRunning and currentDeviceID
    /// before calling this.
    private func startCapture() throws {
        let deviceID = stateLock.withLock { currentDeviceID }

        let effectiveDeviceID: AudioDeviceID
        if let deviceID {
            effectiveDeviceID = deviceID
        } else if let defaultID = Self.currentDefaultInputDeviceID() {
            effectiveDeviceID = defaultID
        } else {
            throw DeviceError.formatNotReady
        }

        capturedCallback = onSamples
        try setupIOProc(deviceID: effectiveDeviceID)
        installDeviceListeners(deviceID: effectiveDeviceID)
    }

    func stop() {
        let wasRunning = stateLock.withLock {
            restartWorkItem?.cancel()
            restartWorkItem = nil
            guard _isRunning else { return false }
            _isRunning = false
            restartSuppressed = false
            return true
        }
        guard wasRunning else { return }

        // Fence: wait for any in-flight performDebouncedRestart on
        // audioQueue to complete. It will observe _isRunning=false via
        // its re-checks and bail, or finish setup so we can tear it down.
        audioQueue.sync {}

        removeDeviceListeners()
        tearDownIOProc()
    }

    /// Suppress independent restarts. Called when SystemAudioCapture detects
    /// a route change and will handle the mic restart via the coordinated cycle.
    func suppressRestart() {
        stateLock.withLock {
            restartSuppressed = true
            restartWorkItem?.cancel()
            restartWorkItem = nil
        }
        logger.error("Mic restart suppressed (system capture coordinating)")
    }

    func unsuppressRestart() {
        stateLock.withLock { restartSuppressed = false }
    }

    /// Live-update the input gain without restarting capture. Read on the RT
    /// thread; aligned-Float assignment is atomic on Apple platforms and a
    /// brief stale read is harmless.
    func setInputGain(dB: Double) {
        inputGainLinear = MicGainStore.linearMultiplier(forDB: dB)
    }

    // MARK: - IO Proc Setup

    private func setupIOProc(deviceID: AudioDeviceID) throws {
        // Pre-configure device buffer size so AUHAL-equivalent latency is
        // predictable and CoreAudio doesn't pick a value our buffers can't
        // accommodate.
        Self.configureDeviceBufferSize(deviceID: deviceID, preferred: 512)

        // Read the device's native input format directly from its input stream
        // (no AU intermediary). This is the ground truth — what the IO proc
        // will hand us.
        let inputFormat = try Self.readDeviceInputFormat(deviceID: deviceID)
        let rate = inputFormat.mSampleRate
        let channels = Int(inputFormat.mChannelsPerFrame)
        deviceSampleRate = rate
        deviceChannelCount = channels
        deviceInputFormat = inputFormat

        logger.error("Device \(deviceID): native \(rate) Hz, \(channels) ch")
        logger.error("Mic capture config: channelMode=\(self.channelMode.encoded, privacy: .public) gainLinear=\(self.inputGainLinear, privacy: .public)")
        Self.logDeviceDiagnostics(deviceID: deviceID)

        // Set up our resampler (stereo in / stereo out) when device rate
        // differs from our target. Channel projection happens in extractToStereo
        // before resampling, so the resampler is always stereo regardless of
        // device channel count.
        resetResampler()
        if rate != AudioConstants.sampleRate {
            do {
                try setupResampler(sourceSampleRate: rate)
            } catch {
                throw error
            }
        }

        renderErrorCount = 0
        renderSuccessCount = 0

        do {
            try setupAUHAL(deviceID: deviceID, inputFormat: inputFormat)
        } catch {
            logger.error("AUHAL mic capture setup failed, falling back to IOProc: \(error.localizedDescription)")
            try setupDeviceIOProc(deviceID: deviceID)
        }
    }

    private func setupDeviceIOProc(deviceID: AudioDeviceID) throws {
        var procID: AudioDeviceIOProcID?
        let createStatus = AudioDeviceCreateIOProcID(
            deviceID,
            micDeviceIOProc,
            Unmanaged.passUnretained(self).toOpaque(),
            &procID
        )
        guard createStatus == noErr, let procID else {
            throw DeviceError.osFailed(createStatus)
        }

        // Store under lock BEFORE start so a concurrent stop() sees a valid
        // procID to tear down even if start races with the first callback.
        stateLock.withLock {
            self.ioProcDevice = deviceID
            self.ioProcID = procID
        }

        let startStatus = AudioDeviceStart(deviceID, procID)
        if startStatus != noErr {
            stateLock.withLock {
                self.ioProcID = nil
                self.ioProcDevice = 0
                self.resetResampler()
            }
            AudioDeviceDestroyIOProcID(deviceID, procID)
            throw DeviceError.osFailed(startStatus)
        }
        logger.error("Mic capture backend started: IOProc")
    }

    private func setupAUHAL(deviceID: AudioDeviceID, inputFormat: AudioStreamBasicDescription) throws {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw DeviceError.formatNotReady
        }

        var unit: AudioUnit?
        try osCheck(AudioComponentInstanceNew(component, &unit))
        guard let unit else { throw DeviceError.formatNotReady }

        var renderResources: (list: UnsafeMutableAudioBufferListPointer, storage: [UnsafeMutableRawPointer])?
        var storedInState = false
        do {
            var enable: UInt32 = 1
            var disable: UInt32 = 0
            try osCheck(AudioUnitSetProperty(
                unit,
                kAudioOutputUnitProperty_EnableIO,
                kAudioUnitScope_Input,
                1,
                &enable,
                UInt32(MemoryLayout<UInt32>.size)
            ))
            try osCheck(AudioUnitSetProperty(
                unit,
                kAudioOutputUnitProperty_EnableIO,
                kAudioUnitScope_Output,
                0,
                &disable,
                UInt32(MemoryLayout<UInt32>.size)
            ))

            var selectedDeviceID = deviceID
            try osCheck(AudioUnitSetProperty(
                unit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &selectedDeviceID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            ))

            var clientFormat = Self.nonInterleavedFloat32ASBD(
                sampleRate: inputFormat.mSampleRate,
                channels: Int(inputFormat.mChannelsPerFrame)
            )
            try osCheck(AudioUnitSetProperty(
                unit,
                kAudioUnitProperty_StreamFormat,
                kAudioUnitScope_Output,
                1,
                &clientFormat,
                UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            ))

            var actualFormat = AudioStreamBasicDescription()
            var actualSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            let actualStatus = AudioUnitGetProperty(
                unit,
                kAudioUnitProperty_StreamFormat,
                kAudioUnitScope_Output,
                1,
                &actualFormat,
                &actualSize
            )
            if actualStatus == noErr {
                logger.error("AUHAL client format: rate=\(actualFormat.mSampleRate, privacy: .public) ch=\(actualFormat.mChannelsPerFrame, privacy: .public) bytes/frame=\(actualFormat.mBytesPerFrame, privacy: .public) flags=\(actualFormat.mFormatFlags, privacy: .public)")
            }

            renderResources = try makeAUHALRenderBufferList(unit: unit, channels: Int(inputFormat.mChannelsPerFrame))

            var callback = AURenderCallbackStruct(
                inputProc: micAUHALInputCallback,
                inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
            )
            try osCheck(AudioUnitSetProperty(
                unit,
                kAudioOutputUnitProperty_SetInputCallback,
                kAudioUnitScope_Global,
                0,
                &callback,
                UInt32(MemoryLayout<AURenderCallbackStruct>.size)
            ))

            try osCheck(AudioUnitInitialize(unit))

            guard let renderResources else { throw DeviceError.formatNotReady }
            stateLock.withLock {
                self.auhalAudioUnit = unit
                self.auhalRenderBufferList = renderResources.list
                self.auhalRenderBufferStorage = renderResources.storage
            }
            storedInState = true

            try osCheck(AudioOutputUnitStart(unit))
            logger.error("Mic capture backend started: AUHAL")
        } catch {
            if storedInState {
                stateLock.withLock {
                    if self.auhalAudioUnit == unit {
                        self.auhalAudioUnit = nil
                        self.auhalRenderBufferList = nil
                        self.auhalRenderBufferStorage = []
                    }
                }
            }
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
            if let renderResources {
                for pointer in renderResources.storage {
                    pointer.deallocate()
                }
                renderResources.list.unsafeMutablePointer.deallocate()
            }
            throw error
        }
    }

    private func makeAUHALRenderBufferList(unit: AudioUnit, channels: Int) throws -> (list: UnsafeMutableAudioBufferListPointer, storage: [UnsafeMutableRawPointer]) {
        var frameCount: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        try osCheck(AudioUnitGetProperty(
            unit,
            kAudioDevicePropertyBufferFrameSize,
            kAudioUnitScope_Global,
            0,
            &frameCount,
            &size
        ))

        let channelCount = max(1, channels)
        let bufferFrames = max(4096, Int(frameCount))
        let bufferListSize = MemoryLayout<AudioBufferList>.offset(of: \.mBuffers)! + MemoryLayout<AudioBuffer>.stride * channelCount
        let rawList = UnsafeMutableRawPointer.allocate(
            byteCount: bufferListSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        rawList.initializeMemory(as: UInt8.self, repeating: 0, count: bufferListSize)

        let listPointer = rawList.bindMemory(to: AudioBufferList.self, capacity: 1)
        listPointer.pointee.mNumberBuffers = UInt32(channelCount)
        let list = UnsafeMutableAudioBufferListPointer(listPointer)

        var storage: [UnsafeMutableRawPointer] = []
        storage.reserveCapacity(channelCount)
        for channel in 0..<channelCount {
            let data = UnsafeMutableRawPointer.allocate(
                byteCount: bufferFrames * MemoryLayout<Float>.size,
                alignment: MemoryLayout<Float>.alignment
            )
            data.initializeMemory(as: UInt8.self, repeating: 0, count: bufferFrames * MemoryLayout<Float>.size)
            storage.append(data)
            list[channel].mNumberChannels = 1
            list[channel].mDataByteSize = UInt32(bufferFrames * MemoryLayout<Float>.size)
            list[channel].mData = data
        }

        logger.error("AUHAL render buffers: frames=\(bufferFrames, privacy: .public) buffers=\(channelCount, privacy: .public)")
        return (list, storage)
    }

    private func tearDownIOProc() {
        // Claim atomically so concurrent teardowns (stop on main,
        // performDebouncedRestart on audioQueue) don't double-destroy.
        let (device, procID, unit, bufferList, bufferStorage) = stateLock.withLock { () -> (AudioDeviceID, AudioDeviceIOProcID?, AudioUnit?, UnsafeMutableAudioBufferListPointer?, [UnsafeMutableRawPointer]) in
            let d = ioProcDevice
            let p = ioProcID
            let u = auhalAudioUnit
            let list = auhalRenderBufferList
            let storage = auhalRenderBufferStorage
            ioProcID = nil
            ioProcDevice = 0
            auhalAudioUnit = nil
            auhalRenderBufferList = nil
            auhalRenderBufferStorage = []
            return (d, p, u, list, storage)
        }
        if let procID, device != 0 {
            // AudioDeviceStop drains in-flight callbacks before returning, so
            // safe to reset resampler state after this.
            AudioDeviceStop(device, procID)
            AudioDeviceDestroyIOProcID(device, procID)
        }

        if let unit {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        for pointer in bufferStorage {
            pointer.deallocate()
        }
        bufferList?.unsafeMutablePointer.deallocate()

        stateLock.withLock { resetResampler() }
    }

    // MARK: - IO Proc Callback

    /// Called from the CoreAudio RT thread for each new chunk of input frames.
    /// Handles BOTH interleaved (single buffer, mNumberChannels=N) and
    /// non-interleaved (N buffers, each mNumberChannels=1) layouts — CoreAudio
    /// USB drivers can deliver either depending on the device's preferred
    /// physical/virtual format.
    func handleIOInput(inputData: UnsafePointer<AudioBufferList>) {
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        let nBuffers = abl.count
        guard nBuffers > 0 else { return }

        // Determine layout. Total channels = sum of mNumberChannels across all buffers.
        // Frame count from the first buffer (all buffers describe the same frames).
        let firstBuf = abl[0]
        guard let firstData = firstBuf.mData, firstBuf.mDataByteSize > 0 else { return }
        let format = deviceInputFormat
        let bytesPerSample = Self.bytesPerSample(format)
        guard bytesPerSample > 0 else { return }

        let firstChannels = max(1, Int(firstBuf.mNumberChannels))
        let frameCount = Int(firstBuf.mDataByteSize) / bytesPerSample / firstChannels
        guard frameCount > 0 else { return }

        // Total channels across all buffers (handles non-interleaved properly).
        var totalChannels = 0
        for i in 0..<nBuffers { totalChannels += Int(abl[i].mNumberChannels) }
        let nativeChannels = max(1, totalChannels)

        // First-time diagnostic: unredacted layout dump (integers, not strings,
        // to avoid Logger's auto-privatization of dynamic strings).
        if renderSuccessCount == 0 {
            logger.error("IOProc layout: nBuffers=\(nBuffers, privacy: .public) totalChannels=\(totalChannels, privacy: .public) frameCount=\(frameCount, privacy: .public)")
            for i in 0..<nBuffers {
                logger.error("  buf[\(i, privacy: .public)] mNumberChannels=\(abl[i].mNumberChannels, privacy: .public) mDataByteSize=\(abl[i].mDataByteSize, privacy: .public)")
            }
        }

        // Coalesce into renderBuffer as interleaved native-channel frames.
        let nativeBufferSize = frameCount * nativeChannels
        if renderBuffer.count < nativeBufferSize {
            logger.error("renderBuffer too small (\(self.renderBuffer.count) < \(nativeBufferSize)) — reallocating on IO thread")
            renderBuffer = [Float](repeating: 0, count: nativeBufferSize)
        }
        if nBuffers == 1 {
            // Interleaved single-buffer input. Convert from the device's PCM
            // format; class-compliant USB interfaces are not guaranteed to use
            // Float32 even when the rest of our pipeline does.
            for i in 0..<nativeBufferSize {
                renderBuffer[i] = Self.readPCMSample(
                    firstData,
                    sampleIndex: i,
                    bytesPerSample: bytesPerSample,
                    format: format
                )
            }
        } else {
            // Non-interleaved: gather each buffer's channel(s) into the
            // interleaved renderBuffer. For each buffer b starting at channel
            // offset c0, frame f's sample lands at renderBuffer[f*N + c0 + k]
            // where k is the in-buffer channel index.
            var channelOffset = 0
            for b in 0..<nBuffers {
                let bufB = abl[b]
                guard let bData = bufB.mData else { continue }
                let bChannels = Int(bufB.mNumberChannels)
                for f in 0..<frameCount {
                    for k in 0..<bChannels {
                        renderBuffer[f * nativeChannels + channelOffset + k] = Self.readPCMSample(
                            bData,
                            sampleIndex: f * bChannels + k,
                            bytesPerSample: bytesPerSample,
                            format: format
                        )
                    }
                }
                channelOffset += bChannels
            }
        }

        processNativeInput(frameCount: frameCount, nativeChannels: nativeChannels, source: "IOProc")
    }

    func handleAUHALInput(
        actionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timeStamp: UnsafePointer<AudioTimeStamp>,
        busNumber: UInt32,
        frameCount: UInt32
    ) -> OSStatus {
        guard let unit = auhalAudioUnit, let bufferList = auhalRenderBufferList else { return noErr }
        let frames = Int(frameCount)
        let nativeChannels = max(1, deviceChannelCount)
        guard frames > 0 else { return noErr }

        for i in 0..<bufferList.count {
            bufferList[i].mDataByteSize = frameCount * UInt32(MemoryLayout<Float>.size)
        }

        let status = AudioUnitRender(unit, actionFlags, timeStamp, busNumber, frameCount, bufferList.unsafeMutablePointer)
        guard status == noErr else {
            renderErrorCount += 1
            if renderErrorCount == 1 || renderErrorCount % 100 == 0 {
                logger.error("AUHAL AudioUnitRender failed #\(self.renderErrorCount): \(status)")
            }
            return noErr
        }

        let nativeBufferSize = frames * nativeChannels
        if renderBuffer.count < nativeBufferSize {
            logger.error("renderBuffer too small (\(self.renderBuffer.count) < \(nativeBufferSize)) — reallocating on IO thread")
            renderBuffer = [Float](repeating: 0, count: nativeBufferSize)
        }

        for channel in 0..<min(nativeChannels, bufferList.count) {
            guard let data = bufferList[channel].mData?.assumingMemoryBound(to: Float.self) else { continue }
            for frame in 0..<frames {
                renderBuffer[frame * nativeChannels + channel] = data[frame]
            }
        }

        if renderSuccessCount == 0 {
            logger.error("AUHAL layout: nBuffers=\(bufferList.count, privacy: .public) totalChannels=\(nativeChannels, privacy: .public) frameCount=\(frames, privacy: .public)")
            for i in 0..<bufferList.count {
                logger.error("  buf[\(i, privacy: .public)] mNumberChannels=\(bufferList[i].mNumberChannels, privacy: .public) mDataByteSize=\(bufferList[i].mDataByteSize, privacy: .public)")
            }
        }

        processNativeInput(frameCount: frames, nativeChannels: nativeChannels, source: "AUHAL")
        return noErr
    }

    private func processNativeInput(frameCount: Int, nativeChannels: Int, source: String) {
        let nativeBufferSize = frameCount * nativeChannels

        if let nativeDebugHandoff {
            renderBuffer.withUnsafeBufferPointer { ptr in
                nativeDebugHandoff.write(UnsafeBufferPointer(start: ptr.baseAddress, count: nativeBufferSize))
            }
        }

        // Project native channels onto stereo per the user's channel mode.
        let stereoSize = frameCount * 2
        if extractedBuffer.count < stereoSize {
            logger.error("extractedBuffer too small (\(self.extractedBuffer.count) < \(stereoSize)) — reallocating on IO thread")
            extractedBuffer = [Float](repeating: 0, count: stereoSize)
        }
        extractToStereo(frameCount: frameCount, nativeChannels: nativeChannels)

        renderSuccessCount += 1
        if renderSuccessCount == 1 || renderSuccessCount % 500 == 0 {
            var rawSumSq: Float = 0
            var rawPeak: Float = 0
            for i in 0..<nativeBufferSize {
                let s = renderBuffer[i]
                rawSumSq += s * s
                let a = abs(s)
                if a > rawPeak { rawPeak = a }
            }
            let rawRms = sqrt(rawSumSq / Float(nativeBufferSize))
            var sumSq: Float = 0
            var peak: Float = 0
            for i in 0..<stereoSize {
                let s = extractedBuffer[i]
                sumSq += s * s
                let a = abs(s)
                if a > peak { peak = a }
            }
            let rms = sqrt(sumSq / Float(stereoSize))
            logger.error("\(source, privacy: .public) OK #\(self.renderSuccessCount) frames=\(frameCount) nativeCh=\(nativeChannels) raw_rms=\(rawRms) raw_peak=\(rawPeak) ext_rms=\(rms) ext_peak=\(peak)")
        }

        if resamplerActive {
            if let resampledCount = resample(frameCount: frameCount) {
                resampleOutputBuffer.withUnsafeBufferPointer { ptr in
                    capturedCallback?(UnsafeBufferPointer(start: ptr.baseAddress, count: resampledCount))
                }
            }
        } else {
            extractedBuffer.withUnsafeBufferPointer { ptr in
                capturedCallback?(UnsafeBufferPointer(start: ptr.baseAddress, count: stereoSize))
            }
        }
    }

    /// Project the device-native interleaved frames in `renderBuffer` onto the
    /// stereo-interleaved `extractedBuffer` per the current channel mode.
    /// Applies the user's per-device input gain. Read on the RT thread without
    /// a lock: Float assignment is atomic on aligned addresses on Apple
    /// platforms, and a brief stale read during a gain change is harmless.
    private func extractToStereo(frameCount: Int, nativeChannels: Int) {
        let g = inputGainLinear
        switch channelMode {
        case .stereo:
            if nativeChannels >= 2 {
                for f in 0..<frameCount {
                    let base = f * nativeChannels
                    extractedBuffer[f * 2]     = renderBuffer[base]     * g
                    extractedBuffer[f * 2 + 1] = renderBuffer[base + 1] * g
                }
            } else {
                // Stereo mode requested on a mono device — duplicate the single channel
                for f in 0..<frameCount {
                    let s = renderBuffer[f] * g
                    extractedBuffer[f * 2]     = s
                    extractedBuffer[f * 2 + 1] = s
                }
            }
        case .mono(let channel):
            // Clamp to valid range; channel is 1-indexed.
            let idx = max(0, min(channel - 1, nativeChannels - 1))
            for f in 0..<frameCount {
                let s = renderBuffer[f * nativeChannels + idx] * g
                extractedBuffer[f * 2]     = s
                extractedBuffer[f * 2 + 1] = s
            }
        }
    }

    // MARK: - Resampling

    private static func interleavedFloat32ASBD(sampleRate: Double, channels: Int) -> AudioStreamBasicDescription {
        let bytesPerFrame = UInt32(4 * channels)
        return AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: bytesPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32,
            mReserved: 0
        )
    }

    private static func nonInterleavedFloat32ASBD(sampleRate: Double, channels: Int) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: UInt32(MemoryLayout<Float>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(MemoryLayout<Float>.size),
            mChannelsPerFrame: UInt32(max(1, channels)),
            mBitsPerChannel: 32,
            mReserved: 0
        )
    }

    private func resetResampler() {
        resamplerActive = false
        resampleStep = 1.0
        resamplePhase = 0
        hasPreviousResampleFrame = false
        previousResampleL = 0
        previousResampleR = 0
    }

    private func setupResampler(sourceSampleRate: Double) throws {
        guard sourceSampleRate > 0 else { throw DeviceError.formatNotReady }
        resamplerActive = true
        resampleStep = sourceSampleRate / AudioConstants.sampleRate
        resamplePhase = 0
        hasPreviousResampleFrame = false
    }

    /// Resample stereo-interleaved samples in `extractedBuffer` (frameCount
    /// frames at deviceSampleRate) to 48 kHz. Returns stereo-interleaved
    /// samples (frame count varies with ratio).
    private func resample(frameCount: Int) -> Int? {
        guard resamplerActive, frameCount > 1, resampleStep > 0 else { return nil }

        if resamplePhase < 0, !hasPreviousResampleFrame {
            resamplePhase = 0
        }

        let maxOutputFrames = Int(ceil((Double(frameCount) + 1.0) / resampleStep)) + 2
        let outputBufferSize = maxOutputFrames * 2
        if resampleOutputBuffer.count < outputBufferSize {
            logger.error("resampleOutputBuffer too small (\(self.resampleOutputBuffer.count) < \(outputBufferSize)) — reallocating on IO thread")
            resampleOutputBuffer = [Float](repeating: 0, count: outputBufferSize)
        }

        var outFrame = 0
        while resamplePhase < Double(frameCount - 1), outFrame < maxOutputFrames {
            let srcIndex = Int(floor(resamplePhase))
            let frac = Float(resamplePhase - Double(srcIndex))

            let l0: Float
            let r0: Float
            let l1: Float
            let r1: Float

            if srcIndex < 0 {
                l0 = previousResampleL
                r0 = previousResampleR
                l1 = extractedBuffer[0]
                r1 = extractedBuffer[1]
            } else {
                let base0 = srcIndex * 2
                let base1 = base0 + 2
                l0 = extractedBuffer[base0]
                r0 = extractedBuffer[base0 + 1]
                l1 = extractedBuffer[base1]
                r1 = extractedBuffer[base1 + 1]
            }

            let outBase = outFrame * 2
            resampleOutputBuffer[outBase] = l0 + (l1 - l0) * frac
            resampleOutputBuffer[outBase + 1] = r0 + (r1 - r0) * frac
            outFrame += 1
            resamplePhase += resampleStep
        }

        let lastBase = (frameCount - 1) * 2
        previousResampleL = extractedBuffer[lastBase]
        previousResampleR = extractedBuffer[lastBase + 1]
        hasPreviousResampleFrame = true
        resamplePhase -= Double(frameCount)

        guard outFrame > 0 else { return nil }
        return outFrame * 2
    }

    private func flushNativeDebugSamples() {
        guard let nativeDebugFile, let nativeDebugHandoff, nativeDebugChannels > 0 else { return }
        let drain = nativeDebugHandoff.drain()
        if drain.droppedSamples > 0 {
            logger.error("Native mic debug handoff dropped \(drain.droppedSamples) samples")
        }
        let usableCount = drain.samples.count - (drain.samples.count % nativeDebugChannels)
        guard usableCount > 0 else { return }
        let frames = usableCount / nativeDebugChannels

        drain.samples.withUnsafeBufferPointer { ptr in
            var bufferList = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: UInt32(nativeDebugChannels),
                    mDataByteSize: UInt32(usableCount * MemoryLayout<Float>.size),
                    mData: UnsafeMutableRawPointer(mutating: ptr.baseAddress)
                )
            )
            let status = ExtAudioFileWrite(nativeDebugFile, UInt32(frames), &bufferList)
            if status != noErr {
                logger.error("Native mic debug write failed: \(status)")
            }
        }
    }

    // MARK: - Device Change Handling

    private func installDeviceListeners(deviceID: AudioDeviceID) {
        // Listen for device death (unplug)
        var aliveAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let aliveBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handleDeviceChange(reason: "device unplugged")
        }

        let pinned = stateLock.withLock {
            listeningDeviceID = deviceID
            deviceAliveListener = aliveBlock
            return currentDeviceID != nil
        }

        AudioObjectAddPropertyListenerBlock(deviceID, &aliveAddress, audioQueue, aliveBlock)

        // When using the system default, also listen for the default changing
        if !pinned {
            var defaultAddress = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let defaultBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.handleDeviceChange(reason: "default input changed")
            }

            stateLock.withLock { defaultInputListener = defaultBlock }

            AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &defaultAddress, audioQueue, defaultBlock
            )
        }
    }

    private func removeDeviceListeners() {
        let (aliveBlock, defaultBlock, devID) = stateLock.withLock {
            defer {
                deviceAliveListener = nil
                defaultInputListener = nil
            }
            return (deviceAliveListener, defaultInputListener, listeningDeviceID)
        }

        if let aliveBlock {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsAlive,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(devID, &address, audioQueue, aliveBlock)
        }

        if let defaultBlock {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, audioQueue, defaultBlock
            )
        }
    }

    private func handleDeviceChange(reason: String) {
        logger.error("Device change (\(reason)), scheduling restart")

        // Debounce: reset the 2s timer on every event. The AUHAL keeps
        // running during the storm (render errors are harmless) so we
        // don't churn coreaudiod with stop/start cycles that block other
        // apps' audio negotiation. Only after 2s of quiet do we do a
        // single clean teardown + restart.
        let work = DispatchWorkItem { [weak self] in
            self?.performDebouncedRestart()
        }
        stateLock.withLock {
            restartWorkItem?.cancel()
            restartWorkItem = work
        }
        audioQueue.asyncAfter(deadline: .now() + 2.0, execute: work)
    }

    private static let maxRestartAttempts = 5

    private func performDebouncedRestart(attempt: Int = 1) {
        let (isRunning, suppressed, savedDeviceID) = stateLock.withLock {
            (_isRunning, restartSuppressed, currentDeviceID)
        }
        guard isRunning else { return }
        if suppressed {
            logger.error("Mic restart suppressed, skipping independent restart")
            return
        }

        // Keep _isRunning = true throughout the restart so stop() always
        // sees us as running and performs a full teardown if called.
        removeDeviceListeners()
        tearDownIOProc()

        // Re-check: stop() may have set _isRunning = false while we were
        // tearing down. If so, don't create a new audio unit — stop() has
        // already declared us stopped.
        guard stateLock.withLock({ _isRunning }) else { return }

        do {
            try startCapture()
            logger.error("Mic restarted successfully (attempt \(attempt))")
        } catch {
            if savedDeviceID != nil {
                let stillRunning = stateLock.withLock {
                    guard _isRunning else { return false }
                    currentDeviceID = nil
                    return true
                }
                guard stillRunning else { return }
                do {
                    try startCapture()
                    logger.error("Mic restarted on system default (attempt \(attempt))")
                    return
                } catch {
                    logger.error("Mic restart on system default also failed (attempt \(attempt)): \(error.localizedDescription)")
                }
            }
            if attempt < Self.maxRestartAttempts {
                logger.error("Mic not ready (attempt \(attempt)), retrying in 2s")
                let work = DispatchWorkItem { [weak self] in
                    self?.performDebouncedRestart(attempt: attempt + 1)
                }
                let stillRunning = stateLock.withLock {
                    guard _isRunning else { return false }
                    restartWorkItem = work
                    return true
                }
                guard stillRunning else { return }
                audioQueue.asyncAfter(deadline: .now() + 2.0, execute: work)
            } else {
                stateLock.withLock { _isRunning = false }
                logger.error("Mic restart failed after \(attempt) attempts: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Helpers

    private func osCheck(_ status: OSStatus) throws {
        guard status == noErr else { throw DeviceError.osFailed(status) }
    }

    /// Read the device's input stream's native format (rate + channel count).
    /// Uses the first input stream — all our supported devices expose a single
    /// input stream covering all channels.
    private static func readDeviceInputFormat(deviceID: AudioDeviceID) throws -> AudioStreamBasicDescription {
        var streamsAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var streamsSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &streamsAddr, 0, nil, &streamsSize) == noErr,
              streamsSize > 0 else {
            throw DeviceError.formatNotReady
        }
        let count = Int(streamsSize) / MemoryLayout<AudioStreamID>.size
        guard count > 0 else { throw DeviceError.formatNotReady }
        var streams = [AudioStreamID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(deviceID, &streamsAddr, 0, nil, &streamsSize, &streams) == noErr else {
            throw DeviceError.formatNotReady
        }
        let firstStream = streams[0]

        var asbd = AudioStreamBasicDescription()
        var asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var fmtAddr = AudioObjectPropertyAddress(
            mSelector: kAudioStreamPropertyVirtualFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(firstStream, &fmtAddr, 0, nil, &asbdSize, &asbd) == noErr,
              asbd.mSampleRate > 0, asbd.mChannelsPerFrame > 0 else {
            throw DeviceError.formatNotReady
        }
        return asbd
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

    private static func readPCMSample(
        _ raw: UnsafeMutableRawPointer,
        sampleIndex: Int,
        bytesPerSample: Int,
        format: AudioStreamBasicDescription
    ) -> Float {
        let flags = format.mFormatFlags
        let isFloat = (flags & kAudioFormatFlagIsFloat) != 0
        let isSignedInt = (flags & kAudioFormatFlagIsSignedInteger) != 0
        let isBigEndian = (flags & kAudioFormatFlagIsBigEndian) != 0
        let sample = raw.advanced(by: sampleIndex * bytesPerSample)

        if isFloat {
            if bytesPerSample == MemoryLayout<Float>.size {
                return sample.assumingMemoryBound(to: Float.self).pointee
            }
            if bytesPerSample == MemoryLayout<Double>.size {
                return Float(sample.assumingMemoryBound(to: Double.self).pointee)
            }
            return 0
        }

        guard isSignedInt else { return 0 }

        switch bytesPerSample {
        case 2:
            let value: Int16
            if isBigEndian {
                value = Int16(bitPattern: UInt16(sample.load(as: UInt16.self)).bigEndian)
            } else {
                value = sample.load(as: Int16.self)
            }
            return Float(value) / Float(Int16.max)
        case 3:
            let bytes = sample.assumingMemoryBound(to: UInt8.self)
            let rawValue: Int32
            if isBigEndian {
                rawValue = (Int32(bytes[0]) << 16) | (Int32(bytes[1]) << 8) | Int32(bytes[2])
            } else {
                rawValue = Int32(bytes[0]) | (Int32(bytes[1]) << 8) | (Int32(bytes[2]) << 16)
            }
            let signed = (rawValue & 0x800000) != 0 ? rawValue | ~0xFFFFFF : rawValue
            return Float(signed) / 8_388_607.0
        case 4:
            let value: Int32
            if isBigEndian {
                value = Int32(bitPattern: UInt32(sample.load(as: UInt32.self)).bigEndian)
            } else {
                value = sample.load(as: Int32.self)
            }
            return Float(value) / Float(Int32.max)
        default:
            return 0
        }
    }

    /// Clamp the device's buffer frame size into its supported range and
    /// nudge it toward `preferred`. Logs what it did. Best-effort: failures
    /// are non-fatal because the IO proc will use whatever the device ends up at.
    private static func configureDeviceBufferSize(deviceID: AudioDeviceID, preferred: UInt32) {
        // Read current
        var currentAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var currentSize: UInt32 = 0
        var sz = UInt32(MemoryLayout<UInt32>.size)
        let curStatus = AudioObjectGetPropertyData(deviceID, &currentAddr, 0, nil, &sz, &currentSize)

        // Read the supported range
        var rangeAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSizeRange,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var range = AudioValueRange(mMinimum: 0, mMaximum: 0)
        var rangeSize = UInt32(MemoryLayout<AudioValueRange>.size)
        let rangeStatus = AudioObjectGetPropertyData(deviceID, &rangeAddr, 0, nil, &rangeSize, &range)

        guard rangeStatus == noErr, range.mMaximum > 0 else {
            logger.error("BufferFrameSize: device \(deviceID) range query failed (status=\(rangeStatus)) current=\(currentSize)(s=\(curStatus))")
            return
        }

        let clamped = max(UInt32(range.mMinimum), min(UInt32(range.mMaximum), preferred))
        if currentSize == clamped {
            logger.error("BufferFrameSize: device \(deviceID) already \(currentSize) (range \(range.mMinimum)..\(range.mMaximum))")
            return
        }

        var newSize = clamped
        let setStatus = AudioObjectSetPropertyData(deviceID, &currentAddr, 0, nil,
            UInt32(MemoryLayout<UInt32>.size), &newSize)
        logger.error("BufferFrameSize: device \(deviceID) set \(currentSize) -> \(newSize) (range \(range.mMinimum)..\(range.mMaximum), status=\(setStatus))")
    }

    /// Query device properties directly (bypassing AUHAL) to compare against
    /// what AUHAL reports. Useful for debugging silent / non-rendering devices.
    private static func logDeviceDiagnostics(deviceID: AudioDeviceID) {
        // Nominal sample rate (from the device itself)
        var nominalRate: Float64 = 0
        var rateSize = UInt32(MemoryLayout<Float64>.size)
        var rateAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let rateStatus = AudioObjectGetPropertyData(deviceID, &rateAddr, 0, nil, &rateSize, &nominalRate)
        logger.error("Device \(deviceID) nominal rate: \(nominalRate) Hz (status=\(rateStatus))")

        // Enumerate input streams
        var streamsAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var streamsSize: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(deviceID, &streamsAddr, 0, nil, &streamsSize)
        guard sizeStatus == noErr, streamsSize > 0 else {
            logger.error("Device \(deviceID) input streams query failed: status=\(sizeStatus) size=\(streamsSize)")
            return
        }
        let streamCount = Int(streamsSize) / MemoryLayout<AudioStreamID>.size
        var streamIDs = [AudioStreamID](repeating: 0, count: streamCount)
        let streamsStatus = AudioObjectGetPropertyData(
            deviceID, &streamsAddr, 0, nil, &streamsSize, &streamIDs
        )
        logger.error("Device \(deviceID) has \(streamCount) input stream(s) (status=\(streamsStatus))")

        for (idx, streamID) in streamIDs.enumerated() {
            var asbd = AudioStreamBasicDescription()
            var asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            var fmtAddr = AudioObjectPropertyAddress(
                mSelector: kAudioStreamPropertyVirtualFormat,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let fmtStatus = AudioObjectGetPropertyData(streamID, &fmtAddr, 0, nil, &asbdSize, &asbd)

            var startingChannel: UInt32 = 0
            var chSize = UInt32(MemoryLayout<UInt32>.size)
            var chAddr = AudioObjectPropertyAddress(
                mSelector: kAudioStreamPropertyStartingChannel,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let chStatus = AudioObjectGetPropertyData(streamID, &chAddr, 0, nil, &chSize, &startingChannel)

            let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
            let isSignedInt = (asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0
            let isPacked = (asbd.mFormatFlags & kAudioFormatFlagIsPacked) != 0
            let isBigEndian = (asbd.mFormatFlags & kAudioFormatFlagIsBigEndian) != 0
            let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
            logger.error("  Stream[\(idx)] id=\(streamID) fmtStatus=\(fmtStatus) chStatus=\(chStatus) startCh=\(startingChannel) rate=\(asbd.mSampleRate) ch=\(asbd.mChannelsPerFrame) bits=\(asbd.mBitsPerChannel) flags=\(asbd.mFormatFlags) isFloat=\(isFloat) isInt=\(isSignedInt) packed=\(isPacked) BE=\(isBigEndian) nonInterleaved=\(isNonInterleaved)")
        }

        // Input data sources — devices like the USB audio device can expose
        // multiple inputs (instrument, mic, USB return); the wrong default
        // selection produces a silent stream.
        var sourcesAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDataSources,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var srcSize: UInt32 = 0
        let srcSizeStatus = AudioObjectGetPropertyDataSize(deviceID, &sourcesAddr, 0, nil, &srcSize)
        if srcSizeStatus == noErr && srcSize > 0 {
            let count = Int(srcSize) / MemoryLayout<UInt32>.size
            var sources = [UInt32](repeating: 0, count: count)
            if AudioObjectGetPropertyData(deviceID, &sourcesAddr, 0, nil, &srcSize, &sources) == noErr {
                var currentAddr = AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyDataSource,
                    mScope: kAudioDevicePropertyScopeInput,
                    mElement: kAudioObjectPropertyElementMain
                )
                var current: UInt32 = 0
                var currentSize = UInt32(MemoryLayout<UInt32>.size)
                _ = AudioObjectGetPropertyData(deviceID, &currentAddr, 0, nil, &currentSize, &current)
                logger.error("  Input data sources (\(count)) current=\(current):")
                for sid in sources {
                    let name = dataSourceName(deviceID: deviceID, sourceID: sid) ?? "<no name>"
                    let marker = sid == current ? "*" : " "
                    logger.error("    \(marker) [\(sid)] \(name)")
                }
            }
        } else {
            logger.error("  Input data sources: none (status=\(srcSizeStatus))")
        }

        // Input volume / mute — silent capture sometimes traces to the device
        // having its input volume slammed to ~0 by a previous client (or by
        // macOS's per-app input volume management).
        // Try master channel (0) first, then channel 1, then channel 2.
        for ch in [UInt32(0), 1, 2] {
            var volAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: ch
            )
            var vol: Float32 = 0
            var volSize = UInt32(MemoryLayout<Float32>.size)
            let volStatus = AudioObjectGetPropertyData(deviceID, &volAddr, 0, nil, &volSize, &vol)
            if volStatus == noErr {
                logger.error("  Input volume ch=\(ch): \(vol) (status=ok)")
            } else {
                logger.error("  Input volume ch=\(ch): n/a (status=\(volStatus))")
            }
        }
        var muteAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var mute: UInt32 = 0
        var muteSize = UInt32(MemoryLayout<UInt32>.size)
        let muteStatus = AudioObjectGetPropertyData(deviceID, &muteAddr, 0, nil, &muteSize, &mute)
        if muteStatus == noErr {
            logger.error("  Input mute: \(mute) (status=ok)")
        } else {
            logger.error("  Input mute: n/a (status=\(muteStatus))")
        }
    }

    private static func dataSourceName(deviceID: AudioDeviceID, sourceID: UInt32) -> String? {
        var sid = sourceID
        var name: Unmanaged<CFString>?
        var translation = AudioValueTranslation(
            mInputData: withUnsafeMutablePointer(to: &sid) { UnsafeMutableRawPointer($0) },
            mInputDataSize: UInt32(MemoryLayout<UInt32>.size),
            mOutputData: withUnsafeMutablePointer(to: &name) { UnsafeMutableRawPointer($0) },
            mOutputDataSize: UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        )
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDataSourceNameForIDCFString,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<AudioValueTranslation>.size)
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &translation) == noErr,
              let cf = name?.takeRetainedValue() else {
            return nil
        }
        return cf as String
    }

    static func currentDefaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown, deviceID != 0 else {
            return nil
        }
        return deviceID
    }

    enum DeviceError: Error {
        case osFailed(OSStatus)
        case formatNotReady
        case componentNotFound
    }

    static func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}
