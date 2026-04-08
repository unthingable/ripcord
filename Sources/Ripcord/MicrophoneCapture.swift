import CoreAudio
import AudioToolbox
@preconcurrency import AVFoundation
import os.log

private let logger = Logger(subsystem: "com.vibe.ripcord", category: "MicCapture")

// C callback invoked by AUHAL when input data is available
private func micInputCallback(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let capture = Unmanaged<MicrophoneCapture>.fromOpaque(inRefCon).takeUnretainedValue()
    return capture.renderInput(
        ioActionFlags: ioActionFlags,
        timeStamp: inTimeStamp,
        busNumber: inBusNumber,
        frameCount: inNumberFrames
    )
}

final class MicrophoneCapture: @unchecked Sendable {
    private var audioUnit: AudioComponentInstance?
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

    // Resampling (when device rate != 48 kHz)
    private var converter: AudioConverterRef?
    private var deviceSampleRate: Double = 0

    // Buffers (accessed only from the IO thread — pre-allocated to avoid
    // heap allocations on the real-time audio thread)
    private var renderBuffer = [Float](repeating: 0, count: 8192)
    private var resampleOutputBuffer = [Float](repeating: 0, count: 16384)

    // Captured at start() so the IO callback avoids a data race on onSamples
    private var capturedCallback: (([Float]) -> Void)?

    // Diagnostic: track render errors from the IO thread
    private var renderErrorCount: Int = 0

    var onSamples: (([Float]) -> Void)?

    var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _isRunning
    }

    deinit {
        stop()
    }

    func start(deviceID: AudioDeviceID? = nil) throws {
        stateLock.lock()
        guard !_isRunning else {
            stateLock.unlock()
            return
        }
        _isRunning = true
        currentDeviceID = deviceID
        stateLock.unlock()

        do {
            try startCapture()
        } catch {
            stateLock.lock()
            _isRunning = false
            stateLock.unlock()
            throw error
        }
    }

    /// Core setup: resolve device, create audio unit, install listeners.
    /// Caller is responsible for setting _isRunning and currentDeviceID
    /// before calling this.
    private func startCapture() throws {
        stateLock.lock()
        let deviceID = currentDeviceID
        stateLock.unlock()

        let effectiveDeviceID: AudioDeviceID
        if let deviceID {
            effectiveDeviceID = deviceID
        } else if let defaultID = Self.currentDefaultInputDeviceID() {
            effectiveDeviceID = defaultID
        } else {
            throw DeviceError.formatNotReady
        }

        capturedCallback = onSamples
        try setupAudioUnit(deviceID: effectiveDeviceID)
        installDeviceListeners(deviceID: effectiveDeviceID)
    }

    func stop() {
        stateLock.lock()
        restartWorkItem?.cancel()
        restartWorkItem = nil
        guard _isRunning else {
            stateLock.unlock()
            return
        }
        _isRunning = false
        restartSuppressed = false
        stateLock.unlock()

        // Fence: wait for any in-flight performDebouncedRestart on
        // audioQueue to complete. It will observe _isRunning=false via
        // its re-checks and bail, or finish setup so we can tear it down.
        audioQueue.sync {}

        removeDeviceListeners()
        tearDownAudioUnit()
    }

    /// Suppress independent restarts. Called when SystemAudioCapture detects
    /// a route change and will handle the mic restart via the coordinated cycle.
    func suppressRestart() {
        stateLock.lock()
        restartSuppressed = true
        restartWorkItem?.cancel()
        restartWorkItem = nil
        stateLock.unlock()
        logger.error("Mic restart suppressed (system capture coordinating)")
    }

    func unsuppressRestart() {
        stateLock.lock()
        restartSuppressed = false
        stateLock.unlock()
    }

    // MARK: - Audio Unit Setup

    private func setupAudioUnit(deviceID: AudioDeviceID) throws {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &desc) else {
            throw DeviceError.componentNotFound
        }

        var unit: AudioComponentInstance?
        try osCheck(AudioComponentInstanceNew(component, &unit))
        guard let unit else { throw DeviceError.componentNotFound }

        do {
            // Enable input (element 1), disable output (element 0).
            // Input-only mode prevents the AUHAL from creating an internal
            // aggregate device that would flicker the mic indicator on
            // output device changes.
            var enable: UInt32 = 1
            var disable: UInt32 = 0
            try osCheck(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO,
                kAudioUnitScope_Input, 1, &enable, UInt32(MemoryLayout<UInt32>.size)))
            try osCheck(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO,
                kAudioUnitScope_Output, 0, &disable, UInt32(MemoryLayout<UInt32>.size)))

            // Pin the specific input device
            var devID = deviceID
            try osCheck(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global, 0, &devID, UInt32(MemoryLayout<AudioDeviceID>.size)))

            // Read the device's native format
            var nativeFormat = AudioStreamBasicDescription()
            var fmtSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try osCheck(AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat,
                kAudioUnitScope_Input, 1, &nativeFormat, &fmtSize))

            guard nativeFormat.mSampleRate > 0, nativeFormat.mChannelsPerFrame > 0 else {
                throw DeviceError.formatNotReady
            }
            deviceSampleRate = nativeFormat.mSampleRate

            logger.error("Device \(deviceID): native \(nativeFormat.mSampleRate) Hz, \(nativeFormat.mChannelsPerFrame) ch")

            // Set the output side of element 1 to mono Float32 at the DEVICE's
            // native sample rate. Don't ask the AUHAL to resample — its internal
            // converter fails (-10863) on some devices (e.g. AirPods HFP at 24 kHz).
            // We handle resampling to 48 kHz ourselves via AudioConverter.
            var outputFormat = Self.monoFloat32ASBD(sampleRate: nativeFormat.mSampleRate)
            try osCheck(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat,
                kAudioUnitScope_Output, 1, &outputFormat,
                UInt32(MemoryLayout<AudioStreamBasicDescription>.size)))

            // Set up resampler if the device rate differs from our target
            if nativeFormat.mSampleRate != AudioConstants.sampleRate {
                try setupResampler(sourceSampleRate: nativeFormat.mSampleRate)
            }

            // Install the input callback
            var callbackStruct = AURenderCallbackStruct(
                inputProc: micInputCallback,
                inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
            )
            try osCheck(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback,
                kAudioUnitScope_Global, 0, &callbackStruct,
                UInt32(MemoryLayout<AURenderCallbackStruct>.size)))

            try osCheck(AudioUnitInitialize(unit))

            // Set audioUnit under lock (consistent with tearDownAudioUnit's
            // locked read) BEFORE starting so the IO callback can use it
            // from the very first invocation.
            renderErrorCount = 0
            stateLock.lock()
            self.audioUnit = unit
            stateLock.unlock()
            try osCheck(AudioOutputUnitStart(unit))
        } catch {
            stateLock.lock()
            self.audioUnit = nil
            stateLock.unlock()
            AudioComponentInstanceDispose(unit)
            throw error
        }
    }

    private func tearDownAudioUnit() {
        // Claim the audio unit atomically so concurrent teardown calls
        // (stop on main, performDebouncedRestart on audioQueue) don't
        // double-dispose.
        stateLock.lock()
        let unit = audioUnit
        audioUnit = nil
        stateLock.unlock()

        if let unit {
            // AudioOutputUnitStop drains all in-flight IO callbacks before
            // returning. After this, renderInput will never fire again for
            // this unit, so it's safe to tear down the converter.
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }

        stateLock.lock()
        let conv = converter
        converter = nil
        stateLock.unlock()

        if let conv {
            AudioConverterDispose(conv)
        }
    }

    // MARK: - IO Callback

    func renderInput(
        ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timeStamp: UnsafePointer<AudioTimeStamp>,
        busNumber: UInt32,
        frameCount: UInt32
    ) -> OSStatus {
        guard let audioUnit else { return noErr }

        let count = Int(frameCount)
        if renderBuffer.count < count {
            renderBuffer = [Float](repeating: 0, count: count)
        }

        let status = renderBuffer.withUnsafeMutableBytes { ptr -> OSStatus in
            var bufferList = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: 1,
                    mDataByteSize: UInt32(count * MemoryLayout<Float>.size),
                    mData: ptr.baseAddress
                )
            )
            return AudioUnitRender(audioUnit, ioActionFlags, timeStamp, busNumber, frameCount, &bufferList)
        }

        if status != noErr {
            renderErrorCount += 1
            if renderErrorCount == 1 || renderErrorCount % 1000 == 0 {
                logger.error("AudioUnitRender failed: \(status) (count: \(self.renderErrorCount))")
            }
            return status
        }

        if converter != nil {
            if let resampled = resample(frameCount: count) {
                capturedCallback?(resampled)
            }
        } else {
            // Single allocation for the consumer
            let samples = Array(renderBuffer.prefix(count))
            capturedCallback?(samples)
        }
        return noErr
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

    private func setupResampler(sourceSampleRate: Double) throws {
        var inputFmt = Self.monoFloat32ASBD(sampleRate: sourceSampleRate)
        var outputFmt = Self.monoFloat32ASBD(sampleRate: AudioConstants.sampleRate)

        var conv: AudioConverterRef?
        let err = AudioConverterNew(&inputFmt, &outputFmt, &conv)
        guard err == noErr, let conv else {
            throw DeviceError.osFailed(err)
        }
        self.converter = conv
    }

    // Sentinel returned by the converter data proc when all input has been
    // consumed.  Must not collide with a real OSStatus error.  Using 1
    // (a positive value no CoreAudio API returns) is the pattern used in
    // Apple sample code.
    private static let kNoMoreData: OSStatus = 1

    /// Resample from renderBuffer (frameCount samples at deviceSampleRate)
    /// to 48 kHz.  Reads renderBuffer directly to avoid intermediate copies.
    private func resample(frameCount: Int) -> [Float]? {
        guard let converter else { return nil }
        guard deviceSampleRate > 0 else { return nil }

        let ratio = AudioConstants.sampleRate / deviceSampleRate
        let outputFrameCount = Int(Double(frameCount) * ratio) + 1

        if resampleOutputBuffer.count < outputFrameCount {
            resampleOutputBuffer = [Float](repeating: 0, count: outputFrameCount)
        }

        let inputByteSize = frameCount * MemoryLayout<Float>.size
        var ioOutputDataPacketSize = UInt32(outputFrameCount)

        let err = renderBuffer.withUnsafeMutableBytes { inputPtr in
            resampleOutputBuffer.withUnsafeMutableBytes { outputPtr -> OSStatus in
                var inputBufList = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(
                        mNumberChannels: 1,
                        mDataByteSize: UInt32(inputByteSize),
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
                            return 1  // kNoMoreData
                        }
                        let srcBufList = userData.assumingMemoryBound(to: AudioBufferList.self)
                        let available = srcBufList.pointee.mBuffers.mDataByteSize
                        if available == 0 {
                            ioNumberDataPackets.pointee = 0
                            return 1  // kNoMoreData
                        }
                        ioData.pointee.mBuffers.mData = srcBufList.pointee.mBuffers.mData
                        ioData.pointee.mBuffers.mDataByteSize = available
                        ioNumberDataPackets.pointee = available / 4
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

        let actualCount = Int(ioOutputDataPacketSize)
        guard actualCount > 0 else { return nil }
        return Array(resampleOutputBuffer.prefix(actualCount))
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

        stateLock.lock()
        let pinned = currentDeviceID != nil
        listeningDeviceID = deviceID
        deviceAliveListener = aliveBlock
        stateLock.unlock()

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

            stateLock.lock()
            defaultInputListener = defaultBlock
            stateLock.unlock()

            AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &defaultAddress, audioQueue, defaultBlock
            )
        }
    }

    private func removeDeviceListeners() {
        stateLock.lock()
        let aliveBlock = deviceAliveListener
        deviceAliveListener = nil
        let defaultBlock = defaultInputListener
        defaultInputListener = nil
        let devID = listeningDeviceID
        stateLock.unlock()

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
        stateLock.lock()
        restartWorkItem?.cancel()
        restartWorkItem = work
        stateLock.unlock()
        audioQueue.asyncAfter(deadline: .now() + 2.0, execute: work)
    }

    private static let maxRestartAttempts = 5

    private func performDebouncedRestart(attempt: Int = 1) {
        stateLock.lock()
        guard _isRunning else {
            stateLock.unlock()
            return
        }
        if restartSuppressed {
            stateLock.unlock()
            logger.error("Mic restart suppressed, skipping independent restart")
            return
        }
        let savedDeviceID = currentDeviceID
        stateLock.unlock()

        // Keep _isRunning = true throughout the restart so stop() always
        // sees us as running and performs a full teardown if called.
        removeDeviceListeners()
        tearDownAudioUnit()

        // Re-check: stop() may have set _isRunning = false while we were
        // tearing down. If so, don't create a new audio unit — stop() has
        // already declared us stopped.
        stateLock.lock()
        guard _isRunning else {
            stateLock.unlock()
            return
        }
        stateLock.unlock()

        do {
            try startCapture()
            logger.error("Mic restarted successfully (attempt \(attempt))")
        } catch {
            if savedDeviceID != nil {
                stateLock.lock()
                guard _isRunning else {
                    stateLock.unlock()
                    return
                }
                currentDeviceID = nil
                stateLock.unlock()
                do {
                    try startCapture()
                    logger.error("Mic restarted on system default (attempt \(attempt))")
                    return
                } catch {}
            }
            if attempt < Self.maxRestartAttempts {
                logger.error("Mic not ready (attempt \(attempt)), retrying in 2s")
                let work = DispatchWorkItem { [weak self] in
                    self?.performDebouncedRestart(attempt: attempt + 1)
                }
                stateLock.lock()
                guard _isRunning else {
                    stateLock.unlock()
                    return
                }
                restartWorkItem = work
                stateLock.unlock()
                audioQueue.asyncAfter(deadline: .now() + 2.0, execute: work)
            } else {
                stateLock.lock()
                _isRunning = false
                stateLock.unlock()
                logger.error("Mic restart failed after \(attempt) attempts: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Helpers

    private func osCheck(_ status: OSStatus) throws {
        guard status == noErr else { throw DeviceError.osFailed(status) }
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
