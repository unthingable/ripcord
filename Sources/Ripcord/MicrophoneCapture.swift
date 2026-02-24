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
    private var _isRunning = false
    private var currentDeviceID: AudioDeviceID?
    private var restartWorkItem: DispatchWorkItem?

    // Device change listeners
    private var deviceAliveListener: AudioObjectPropertyListenerBlock?
    private var defaultInputListener: AudioObjectPropertyListenerBlock?
    private var listeningDeviceID: AudioDeviceID = 0

    // Render buffer (grown as needed, accessed only from the IO thread)
    private var renderBuffer = [Float](repeating: 0, count: 8192)

    // Captured at start() so the IO callback avoids a data race on onSamples
    private var capturedCallback: (([Float]) -> Void)?

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
        stateLock.unlock()

        currentDeviceID = deviceID

        let effectiveDeviceID: AudioDeviceID
        if let deviceID {
            effectiveDeviceID = deviceID
        } else if let defaultID = Self.currentDefaultInputDeviceID() {
            effectiveDeviceID = defaultID
        } else {
            stateLock.lock()
            _isRunning = false
            stateLock.unlock()
            throw DeviceError.formatNotReady
        }

        capturedCallback = onSamples

        do {
            let unit = try createAudioUnit(deviceID: effectiveDeviceID)
            self.audioUnit = unit
            installDeviceListeners(deviceID: effectiveDeviceID)
        } catch {
            stateLock.lock()
            _isRunning = false
            stateLock.unlock()
            throw error
        }
    }

    func stop() {
        restartWorkItem?.cancel()
        restartWorkItem = nil
        removeDeviceListeners()

        stateLock.lock()
        guard _isRunning else {
            stateLock.unlock()
            return
        }
        _isRunning = false
        stateLock.unlock()

        tearDownAudioUnit()
    }

    // MARK: - Audio Unit Setup

    private func createAudioUnit(deviceID: AudioDeviceID) throws -> AudioComponentInstance {
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

            // Request 48 kHz mono Float32 on the output side of element 1.
            // The AUHAL's internal converter handles sample-rate conversion
            // and channel mixing from the device's native format.
            var outputFormat = AudioStreamBasicDescription(
                mSampleRate: AudioConstants.sampleRate,
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                mBytesPerPacket: 4,
                mFramesPerPacket: 1,
                mBytesPerFrame: 4,
                mChannelsPerFrame: 1,
                mBitsPerChannel: 32,
                mReserved: 0
            )
            try osCheck(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat,
                kAudioUnitScope_Output, 1, &outputFormat,
                UInt32(MemoryLayout<AudioStreamBasicDescription>.size)))

            // Install the input callback
            var callbackStruct = AURenderCallbackStruct(
                inputProc: micInputCallback,
                inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
            )
            try osCheck(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback,
                kAudioUnitScope_Global, 0, &callbackStruct,
                UInt32(MemoryLayout<AURenderCallbackStruct>.size)))

            try osCheck(AudioUnitInitialize(unit))
            try osCheck(AudioOutputUnitStart(unit))
            return unit
        } catch {
            AudioComponentInstanceDispose(unit)
            throw error
        }
    }

    private func tearDownAudioUnit() {
        guard let unit = audioUnit else { return }
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        audioUnit = nil
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

        guard status == noErr else { return status }

        let samples = Array(renderBuffer.prefix(count))
        capturedCallback?(samples)
        return noErr
    }

    // MARK: - Device Change Handling

    private func installDeviceListeners(deviceID: AudioDeviceID) {
        listeningDeviceID = deviceID

        // Listen for device death (unplug)
        var aliveAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let aliveBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handleDeviceChange(reason: "device unplugged")
        }
        deviceAliveListener = aliveBlock
        AudioObjectAddPropertyListenerBlock(deviceID, &aliveAddress, DispatchQueue.main, aliveBlock)

        // When using the system default, also listen for the default changing
        if currentDeviceID == nil {
            var defaultAddress = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let defaultBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.handleDeviceChange(reason: "default input changed")
            }
            defaultInputListener = defaultBlock
            AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &defaultAddress, DispatchQueue.main, defaultBlock
            )
        }
    }

    private func removeDeviceListeners() {
        if let block = deviceAliveListener {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsAlive,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(listeningDeviceID, &address, DispatchQueue.main, block)
            deviceAliveListener = nil
        }

        if let block = defaultInputListener {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block
            )
            defaultInputListener = nil
        }
    }

    private func handleDeviceChange(reason: String) {
        logger.error("Device change (\(reason)), scheduling restart")

        removeDeviceListeners()

        stateLock.lock()
        let wasRunning = _isRunning
        _isRunning = false
        stateLock.unlock()

        guard wasRunning else { return }

        tearDownAudioUnit()
        scheduleRestart(delay: 0.5)
    }

    private static let maxRestartAttempts = 5

    private func scheduleRestart(delay: TimeInterval, attempt: Int = 1) {
        restartWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            do {
                try self.start(deviceID: self.currentDeviceID)
                logger.error("Mic restarted successfully (attempt \(attempt))")
            } catch {
                if self.currentDeviceID != nil {
                    do {
                        try self.start(deviceID: nil)
                        logger.error("Mic restarted on system default (attempt \(attempt))")
                        return
                    } catch {}
                }
                if attempt < Self.maxRestartAttempts {
                    logger.error("Mic not ready (attempt \(attempt)), retrying in 1s")
                    self.scheduleRestart(delay: 1.0, attempt: attempt + 1)
                } else {
                    logger.error("Mic restart failed after \(attempt) attempts: \(error.localizedDescription)")
                }
            }
        }
        restartWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
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
