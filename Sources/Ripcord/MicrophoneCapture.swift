@preconcurrency import AVFoundation
import CoreAudio

final class MicrophoneCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let stateLock = NSLock()
    private var _isRunning = false
    private var currentDeviceID: AudioDeviceID?
    private var configChangeObserver: NSObjectProtocol?

    var onSamples: (([Float]) -> Void)?

    var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _isRunning
    }

    init() {
        registerConfigChangeHandler()
    }

    deinit {
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
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

        let inputNode = engine.inputNode

        // Set specific input device if requested
        if let deviceID {
            guard let audioUnit = inputNode.audioUnit else {
                throw DeviceError.setDeviceFailed(kAudioUnitErr_Uninitialized)
            }
            var devID = deviceID
            let status = AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global, 0,
                &devID, UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            if status != noErr {
                throw DeviceError.setDeviceFailed(status)
            }
        }

        let nativeFormat = inputNode.inputFormat(forBus: 0)

        // Capture callback and conversion state locally to avoid self references in tap
        let callback = self.onSamples
        let needsConversion = nativeFormat.sampleRate != AudioConstants.sampleRate
        var converter: AVAudioConverter?
        var outputFormat: AVAudioFormat?

        if needsConversion {
            outputFormat = AVAudioFormat(standardFormatWithSampleRate: AudioConstants.sampleRate, channels: 1)
            if let outputFormat {
                converter = AVAudioConverter(from: nativeFormat, to: outputFormat)
            }
        }

        // Pre-allocate buffer for mono mixing
        var monoBuffer = [Float](repeating: 0, count: 8192)

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nativeFormat) { buffer, _ in
            if let converter, let outputFormat {
                // Convert to target sample rate, mono
                let ratio = AudioConstants.sampleRate / nativeFormat.sampleRate
                let outputFrameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
                guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputFrameCount) else { return }

                var error: NSError?
                nonisolated(unsafe) var consumed = false
                converter.convert(to: outputBuffer, error: &error) { _, outStatus in
                    if consumed {
                        outStatus.pointee = .noDataNow
                        return nil
                    }
                    consumed = true
                    outStatus.pointee = .haveData
                    return buffer
                }

                if error == nil, let channelData = outputBuffer.floatChannelData {
                    let samples = Array(UnsafeBufferPointer(start: channelData[0], count: Int(outputBuffer.frameLength)))
                    callback?(samples)
                }
            } else {
                // Already at target rate or close enough — mix to mono
                guard let channelData = buffer.floatChannelData else { return }
                let frameCount = Int(buffer.frameLength)
                let channelCount = Int(nativeFormat.channelCount)

                if channelCount == 1 {
                    let samples = Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))
                    callback?(samples)
                } else {
                    // Use pre-allocated buffer, resize if needed
                    if frameCount > monoBuffer.count {
                        monoBuffer = [Float](repeating: 0, count: frameCount)
                    }

                    let scale = 1.0 / Float(channelCount)
                    for i in 0..<frameCount {
                        var sum: Float = 0
                        for ch in 0..<channelCount {
                            sum += channelData[ch][i]
                        }
                        monoBuffer[i] = sum * scale
                    }

                    let samples = Array(monoBuffer[0..<frameCount])
                    callback?(samples)
                }
            }
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            stateLock.lock()
            _isRunning = false
            stateLock.unlock()
            throw error
        }
    }

    func stop() {
        stateLock.lock()
        guard _isRunning else {
            stateLock.unlock()
            return
        }
        _isRunning = false
        stateLock.unlock()

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    private func registerConfigChangeHandler() {
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.handleConfigChange()
        }
    }

    private func handleConfigChange() {
        // Engine has been stopped by the system. Restart if we were running.
        stateLock.lock()
        let wasRunning = _isRunning
        _isRunning = false
        stateLock.unlock()

        guard wasRunning else { return }

        // Clean up old tap and engine state before restarting
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        // Restart the engine, trying the previously selected device first
        do {
            try start(deviceID: currentDeviceID)
        } catch {
            // Device may be gone — fall back to system default
            if currentDeviceID != nil {
                do {
                    try start(deviceID: nil)
                } catch {
                    // Both attempts failed
                }
            }
        }
    }

    enum DeviceError: Error {
        case setDeviceFailed(OSStatus)
    }

    static func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}
