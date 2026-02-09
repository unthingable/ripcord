import AVFoundation
import CoreAudio
import Foundation
import Observation
import SwiftUI
import TranscribeKit

enum AppState: Equatable {
    case starting
    case buffering
    case recording
    case error(String)
}

enum MicStatus: Equatable {
    case off
    case permissionDenied
    case failed(String)
    case active
}

enum SettingsKey {
    static let bufferDuration = "ripcord.bufferDurationSeconds"
    static let outputFormat   = "ripcord.outputFormat"
    static let audioQuality   = "ripcord.audioQuality"
    static let micEnabled     = "ripcord.micEnabled"
    static let outputDirectory = "ripcord.outputDirectory"
    static let captureDuration = "ripcord.captureDurationSeconds"
    static let launchAtLogin  = "ripcord.launchAtLogin"
    static let selectedMicUID = "ripcord.selectedMicUID"
    static let enableTranscription = "ripcord.enableTranscription"
    static let asrModelVersion = "ripcord.asrModelVersion"
    static let diarizationEnabled = "ripcord.diarizationEnabled"
    static let speakerSensitivity = "ripcord.speakerSensitivity"
    static let expectedSpeakerCount = "ripcord.expectedSpeakerCount"
    static let hasRecordedBefore = "ripcord.hasRecordedBefore"
    static let silenceAutoPauseEnabled = "ripcord.silenceAutoPauseEnabled"
    static let silenceThreshold = "ripcord.silenceThreshold"
    static let silenceTimeoutSeconds = "ripcord.silenceTimeoutSeconds"
    static let transcriptFormat = "ripcord.transcriptFormat"
    static let removeFillerWords = "ripcord.removeFillerWords"
}

enum SpeakerSensitivity: String, CaseIterable {
    case low, medium, high

    /// Maps to DiarizerConfig.clusteringThreshold
    var clusteringThreshold: Float {
        switch self {
        case .low: return 0.5
        case .medium: return 0.7
        case .high: return 0.9
        }
    }
}

struct TranscriptionConfig: Equatable {
    var asrModelVersion: ModelVersion = .v3
    var diarizationEnabled: Bool = true
    var speakerSensitivity: SpeakerSensitivity = .medium
    var expectedSpeakerCount: Int = -1  // -1 = auto
    var transcriptFormat: OutputFormat = .txt
    var removeFillerWords: Bool = false
}

@Observable
final class RecordingManager: @unchecked Sendable {
    var state: AppState = .starting
    private var initialStartupLaunched = false
    var bufferDurationSeconds: Int = 300
    var captureDurationSeconds: Int = 300
    var outputFormat: AudioOutputFormat = .wav
    var audioQuality: AudioQuality = .medium
    var micEnabled: Bool = true
    var outputDirectory: URL
    var recentRecordings: [RecordingInfo] = []  // newest first, capped at 10
    var recordingElapsed: TimeInterval = 0
    var micStatus: MicStatus = .off
    var waveformAmplitudes: [Float] = Array(repeating: 0, count: 100)
    var filledBarCount: Int = 1
    var systemLevel: Float = 0
    var micLevel: Float = 0
    var selectedMicUID: String?
    var transcriptionEnabled: Bool = false
    var transcriptionConfig: TranscriptionConfig = TranscriptionConfig()
    var silenceAutoPauseEnabled: Bool = false
    var silenceThreshold: Float = 0.01
    var silenceTimeoutSeconds: Double = 3.0
    var isSilencePaused: Bool = false

    let transcriptionService = TranscriptionService()
    let deviceEnumerator = AudioDeviceEnumerator()

    private let systemCapture = SystemAudioCapture()
    private let micCapture = MicrophoneCapture()

    // Dual circular buffers for proper mixing
    private var systemBuffer: CircularAudioBuffer
    private var micBuffer: CircularAudioBuffer

    // Pending sample accumulation for recording — protected by pendingLock
    private var pendingActive = false
    private var pendingSystemSamples: [Float] = []
    private var pendingMicSamples: [Float] = []
    private let pendingLock = NSLock()

    // Dedicated write queue for off-thread file I/O
    private let writeQueue = DispatchQueue(label: "com.vibe.ripcord.writequeue")
    private var writer: AudioFileWriter?  // Only accessed on writeQueue
    private var writeError: Error?         // Only accessed on writeQueue
    private var writeTimer: DispatchSourceTimer?  // Only accessed on writeQueue

    // Remainder buffers for carry-forward interleaving — only accessed on writeQueue
    private var systemRemainder: [Float] = []
    private var micRemainder: [Float] = []

    // Silence detection state — only accessed on writeQueue
    private var silenceEnabled: Bool = false
    private var silenceThresholdLocal: Float = 0.01
    private var silenceSampleThreshold: Int = 0
    private var silenceSampleCount: Int = 0
    private var silenceDetected: Bool = false

    /// Max samples one source can accumulate without the other before we assume the other is off.
    /// 500ms at 48kHz = 24000 samples.
    private static let remainderCap = 24000

    // Inline peak tracking for level meters (works during recording too)
    private var systemPeakAccum: Float = 0
    private var micPeakAccum: Float = 0
    private let meterLock = NSLock()

    // Elapsed timer — only accessed from main thread
    private var recordingStartTime: Date?
    private var elapsedTimer: Timer?
    private var waveformTimer: Timer?

    init() {
        let defaults = UserDefaults.standard
        let defaultDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents")
            .appendingPathComponent("Ripcord")

        defaults.register(defaults: [
            SettingsKey.bufferDuration: 300,
            SettingsKey.captureDuration: 300,
            SettingsKey.outputFormat: AudioOutputFormat.wav.rawValue,
            SettingsKey.audioQuality: AudioQuality.medium.rawValue,
            SettingsKey.micEnabled: true,
            SettingsKey.outputDirectory: defaultDir.path,
            SettingsKey.launchAtLogin: false,
        ])

        let savedDuration = defaults.integer(forKey: SettingsKey.bufferDuration)
        let duration = savedDuration > 0 ? savedDuration : 300

        // Init buffers first (required before accessing self properties with @Observable)
        systemBuffer = CircularAudioBuffer(durationSeconds: duration, sampleRate: AudioConstants.sampleRateInt)
        micBuffer = CircularAudioBuffer(durationSeconds: duration, sampleRate: AudioConstants.sampleRateInt)

        if let dirPath = defaults.string(forKey: SettingsKey.outputDirectory), !dirPath.isEmpty {
            outputDirectory = URL(fileURLWithPath: dirPath, isDirectory: true)
        } else {
            outputDirectory = defaultDir
        }

        bufferDurationSeconds = duration

        let savedCapture = defaults.integer(forKey: SettingsKey.captureDuration)
        captureDurationSeconds = savedCapture > 0 ? min(savedCapture, duration) : duration

        if let formatStr = defaults.string(forKey: SettingsKey.outputFormat),
           let fmt = AudioOutputFormat(rawValue: formatStr) {
            outputFormat = fmt
        }

        if let qualStr = defaults.string(forKey: SettingsKey.audioQuality),
           let q = AudioQuality(rawValue: qualStr) {
            audioQuality = q
        }

        micEnabled = defaults.bool(forKey: SettingsKey.micEnabled)
        selectedMicUID = defaults.string(forKey: SettingsKey.selectedMicUID)
        transcriptionEnabled = defaults.bool(forKey: SettingsKey.enableTranscription)

        // Load silence auto-pause settings
        if defaults.object(forKey: SettingsKey.silenceAutoPauseEnabled) != nil {
            silenceAutoPauseEnabled = defaults.bool(forKey: SettingsKey.silenceAutoPauseEnabled)
        }
        let savedThreshold = defaults.float(forKey: SettingsKey.silenceThreshold)
        if savedThreshold > 0 {
            silenceThreshold = savedThreshold
        }
        let savedTimeout = defaults.double(forKey: SettingsKey.silenceTimeoutSeconds)
        if savedTimeout > 0 {
            silenceTimeoutSeconds = savedTimeout
        }

        // Load transcription config
        if let asrStr = defaults.string(forKey: SettingsKey.asrModelVersion),
           let asr = ModelVersion(rawValue: asrStr) {
            transcriptionConfig.asrModelVersion = asr
        }
        if defaults.object(forKey: SettingsKey.diarizationEnabled) != nil {
            transcriptionConfig.diarizationEnabled = defaults.bool(forKey: SettingsKey.diarizationEnabled)
        }
        if let sensStr = defaults.string(forKey: SettingsKey.speakerSensitivity),
           let sens = SpeakerSensitivity(rawValue: sensStr) {
            transcriptionConfig.speakerSensitivity = sens
        }
        let savedSpeakerCount = defaults.integer(forKey: SettingsKey.expectedSpeakerCount)
        if defaults.object(forKey: SettingsKey.expectedSpeakerCount) != nil {
            transcriptionConfig.expectedSpeakerCount = savedSpeakerCount
        }
        if let fmtStr = defaults.string(forKey: SettingsKey.transcriptFormat),
           let fmt = OutputFormat(rawValue: fmtStr) {
            transcriptionConfig.transcriptFormat = fmt
        }
        if defaults.object(forKey: SettingsKey.removeFillerWords) != nil {
            transcriptionConfig.removeFillerWords = defaults.bool(forKey: SettingsKey.removeFillerWords)
        }
    }

    deinit {
        writeTimer?.cancel()
        elapsedTimer?.invalidate()
        waveformTimer?.invalidate()
    }

    // MARK: - Public Interface

    /// Called once from ContentView.onAppear; guards against duplicate launches
    /// when MenuBarExtra recreates the view during permission dialogs.
    func startBufferingOnce() async {
        guard !initialStartupLaunched else { return }
        initialStartupLaunched = true
        await startBuffering()
    }

    func startBuffering() async {
        // Snapshot config from @Observable properties on MainActor before doing async work
        let wantsMic = await MainActor.run { micEnabled }

        // Request mic permission upfront BEFORE system capture. On macOS 15,
        // aggregate device creation can trigger an unexpected mic permission dialog.
        // By requesting here first, the permission is already granted by the time
        // system capture (and later startMic) runs — avoiding duplicate prompts.
        var micGranted = false
        if wantsMic {
            micGranted = await MicrophoneCapture.requestPermission()
            if !micGranted {
                await MainActor.run { self.micStatus = .permissionDenied }
            }
        }

        // Set up audio callbacks
        systemCapture.onSamples = { [weak self] samples in
            self?.handleSystemSamples(samples)
        }
        micCapture.onSamples = { [weak self] samples in
            self?.handleMicSamples(samples)
        }

        // Start system audio capture
        do {
            try await systemCapture.start()
        } catch {
            await MainActor.run {
                self.state = .error("System audio: \(error.localizedDescription)")
            }
            return
        }

        // Start mic capture if enabled and permission was granted
        if micGranted {
            await startMic()
        }

        await MainActor.run {
            self.state = .buffering
        }

        await loadRecentRecordings()

        if !transcriptionService.modelsReady
            && TranscriptionService.modelsExistOnDisk(config: transcriptionConfig) {
            Task { await transcriptionService.prepareModels(config: transcriptionConfig, fromCache: true) }
        }
    }

    private func loadRecentRecordings() async {
        let dir = await MainActor.run { outputDirectory }
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.fileSizeKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let audioExtensions: Set<String> = ["wav", "m4a"]
        let recordings: [(RecordingInfo, Date)] = files
            .filter { audioExtensions.contains($0.pathExtension.lowercased()) }
            .compactMap { url in
                guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                      let size = attrs[.size] as? UInt64,
                      let created = attrs[.creationDate] as? Date else { return nil }
                let duration = Self.audioDuration(url: url) ?? 0
                return (RecordingInfo(url: url, duration: duration, fileSize: size), created)
            }
            .sorted { $0.1 > $1.1 }
        let loaded = Array(recordings.prefix(10).map { $0.0 })

        await MainActor.run {
            recentRecordings = loaded
        }
    }

    private static func audioDuration(url: URL) -> Double? {
        guard let audioFile = try? AVAudioFile(forReading: url) else { return nil }
        let sampleRate = audioFile.processingFormat.sampleRate
        guard sampleRate > 0 else { return nil }
        return Double(audioFile.length) / sampleRate
    }

    func startRecording() {
        guard state == .buffering else { return }

        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "T", with: "_")
            .prefix(19)

        let filename = "ripcord_\(timestamp).\(outputFormat.fileExtension)"
        let outputDir = outputDirectory

        do {
            try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        } catch {
            state = .error("Cannot create output directory: \(error.localizedDescription)")
            return
        }

        let fileURL = outputDir.appendingPathComponent(filename)
        let newWriter = AudioFileWriter(url: fileURL, format: outputFormat, quality: audioQuality)

        do {
            try newWriter.open()
        } catch {
            state = .error("Failed to create recording: \(error)")
            return
        }

        // Bug #1 fix: Enable pending BEFORE draining so no samples are lost.
        // From this instant, all new callback samples go to pending arrays.
        pendingLock.lock()
        pendingActive = true
        pendingSystemSamples.removeAll()
        pendingMicSamples.removeAll()
        pendingLock.unlock()

        // Drain circular buffers (fast — just array copies under lock).
        // Any samples arriving now go to pending arrays, not the drained buffers.
        // Trim to capture duration — user may only want the last N seconds of the buffer.
        let captureSamples = captureDurationSeconds * AudioConstants.sampleRateInt
        let systemSamples = Array(systemBuffer.drain().suffix(captureSamples))
        let micSamples = Array(micBuffer.drain().suffix(captureSamples))

        // Snapshot silence settings for writeQueue (read from main thread before dispatch)
        let silenceOn = silenceAutoPauseEnabled
        let silenceThresh = silenceThreshold
        let silenceTimeout = silenceTimeoutSeconds

        // Bug #2 fix: Dispatch the expensive interleave + write to writeQueue.
        // The serial queue guarantees the initial write completes before any flush timer fires.
        writeQueue.async { [weak self] in
            guard let self else { return }
            self.writer = newWriter
            self.writeError = nil
            self.systemRemainder = []
            self.micRemainder = []

            // Initialize silence detection state
            self.silenceEnabled = silenceOn
            self.silenceThresholdLocal = silenceThresh
            self.silenceSampleThreshold = Int(silenceTimeout * Double(AudioConstants.sampleRateInt))
            self.silenceSampleCount = 0
            self.silenceDetected = false

            // Write the retroactive buffer (use max() — full buffer, no next cycle)
            let stereoBuffered = Self.interleave(systemSamples, micSamples)
            if !stereoBuffered.isEmpty {
                do {
                    try newWriter.append(samples: stereoBuffered)
                } catch {
                    self.writeError = error
                }
            }

            // Start write timer AFTER initial write (fires every 50ms on writeQueue)
            let timer = DispatchSource.makeTimerSource(queue: self.writeQueue)
            timer.schedule(deadline: .now() + .milliseconds(50), repeating: .milliseconds(50))
            timer.setEventHandler { [weak self] in
                self?.flushPendingSamples()
            }
            timer.resume()
            self.writeTimer = timer
        }

        // Update state and start elapsed timer (main thread, immediate)
        // Reset waveform for fresh streaming display during recording
        waveformAmplitudes = [Float](repeating: 0, count: 100)
        filledBarCount = 0
        state = .recording
        recordingStartTime = Date()
        recordingElapsed = 0
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, let start = self.recordingStartTime else { return }
            self.recordingElapsed = Date().timeIntervalSince(start)
        }
    }

    func stopRecording() {
        guard state == .recording else { return }

        // Stop elapsed timer (main thread)
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        recordingStartTime = nil
        recordingElapsed = 0
        isSilencePaused = false

        // Disable pending accumulation and grab remaining samples
        pendingLock.lock()
        pendingActive = false
        let remainingSystem = pendingSystemSamples
        let remainingMic = pendingMicSamples
        pendingSystemSamples.removeAll()
        pendingMicSamples.removeAll()
        pendingLock.unlock()

        // Flush remaining samples, cancel timer, and finalize writer on writeQueue
        var result: Result<RecordingInfo, Error>?
        writeQueue.sync {
            // Cancel timer on its owning queue
            self.writeTimer?.cancel()
            self.writeTimer = nil

            // Combine remainders with final pending samples
            let finalSystem = self.systemRemainder + remainingSystem
            let finalMic = self.micRemainder + remainingMic
            self.systemRemainder = []
            self.micRemainder = []

            // Final flush uses max() — no next cycle to carry forward to
            let stereo = Self.interleave(finalSystem, finalMic)
            if !stereo.isEmpty, let w = self.writer, self.writeError == nil {
                do {
                    try w.append(samples: stereo)
                } catch {
                    self.writeError = error
                }
            }

            // Finalize
            guard let w = self.writer else {
                result = .failure(RecordingError.noWriter)
                return
            }

            if let writeError = self.writeError {
                _ = try? w.finalize()
                result = .failure(writeError)
            } else {
                do {
                    let info = try w.finalize()
                    result = .success(info)
                } catch {
                    result = .failure(error)
                }
            }

            self.writer = nil
            self.writeError = nil
        }

        // Update state based on result
        switch result {
        case .success(let info):
            recentRecordings.insert(info, at: 0)
            if recentRecordings.count > 10 { recentRecordings.removeLast() }
            UserDefaults.standard.set(true, forKey: SettingsKey.hasRecordedBefore)
            state = .buffering
            if transcriptionEnabled && transcriptionService.modelsReady {
                transcribeRecording(info)
            }
        case .failure(let error):
            state = .error("Recording failed: \(error.localizedDescription)")
        case .none:
            state = .buffering
        }
    }

    func setMicEnabled(_ enabled: Bool) async {
        micEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: SettingsKey.micEnabled)
        if enabled {
            await startMic()
        } else {
            micCapture.stop()
            micStatus = .off
        }
    }

    func updateBufferDuration(_ seconds: Int) {
        guard state != .recording else { return }
        bufferDurationSeconds = seconds
        UserDefaults.standard.set(seconds, forKey: SettingsKey.bufferDuration)
        systemBuffer.resize(durationSeconds: seconds, sampleRate: AudioConstants.sampleRateInt)
        micBuffer.resize(durationSeconds: seconds, sampleRate: AudioConstants.sampleRateInt)
        // Clamp capture duration to not exceed new buffer size
        if captureDurationSeconds > seconds {
            updateCaptureDuration(seconds)
        }
    }

    func updateCaptureDuration(_ seconds: Int) {
        captureDurationSeconds = max(30, min(seconds, bufferDurationSeconds))
        UserDefaults.standard.set(captureDurationSeconds, forKey: SettingsKey.captureDuration)
    }

    func updateOutputFormat(_ format: AudioOutputFormat) {
        guard state != .recording else { return }
        outputFormat = format
        UserDefaults.standard.set(format.rawValue, forKey: SettingsKey.outputFormat)
    }

    func updateAudioQuality(_ quality: AudioQuality) {
        guard state != .recording else { return }
        audioQuality = quality
        UserDefaults.standard.set(quality.rawValue, forKey: SettingsKey.audioQuality)
    }

    func updateOutputDirectory(_ url: URL) {
        outputDirectory = url
        UserDefaults.standard.set(url.path, forKey: SettingsKey.outputDirectory)
    }

    func updateTranscriptionEnabled(_ enabled: Bool) {
        transcriptionEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: SettingsKey.enableTranscription)
    }

    func updateSilenceAutoPause(enabled: Bool) {
        silenceAutoPauseEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: SettingsKey.silenceAutoPauseEnabled)
    }

    func updateSilenceThreshold(_ value: Float) {
        silenceThreshold = value
        UserDefaults.standard.set(value, forKey: SettingsKey.silenceThreshold)
    }

    func updateSilenceTimeout(_ value: Double) {
        silenceTimeoutSeconds = value
        UserDefaults.standard.set(value, forKey: SettingsKey.silenceTimeoutSeconds)
    }

    func transcriptionConfigBinding<T>(_ keyPath: WritableKeyPath<TranscriptionConfig, T>) -> Binding<T> {
        nonisolated(unsafe) let kp = keyPath
        return Binding(
            get: { self.transcriptionConfig[keyPath: kp] },
            set: { value in
                var config = self.transcriptionConfig
                config[keyPath: kp] = value
                self.updateTranscriptionConfig(config)
            }
        )
    }

    func downloadTranscriptionModels() {
        Task { await transcriptionService.prepareModels(config: transcriptionConfig) }
    }

    func updateTranscriptionConfig(_ config: TranscriptionConfig) {
        let oldConfig = transcriptionConfig
        transcriptionConfig = config

        let defaults = UserDefaults.standard
        defaults.set(config.asrModelVersion.rawValue, forKey: SettingsKey.asrModelVersion)
        defaults.set(config.diarizationEnabled, forKey: SettingsKey.diarizationEnabled)
        defaults.set(config.speakerSensitivity.rawValue, forKey: SettingsKey.speakerSensitivity)
        defaults.set(config.expectedSpeakerCount, forKey: SettingsKey.expectedSpeakerCount)
        defaults.set(config.transcriptFormat.rawValue, forKey: SettingsKey.transcriptFormat)
        defaults.set(config.removeFillerWords, forKey: SettingsKey.removeFillerWords)

        // Re-prepare models if ASR version changed
        if transcriptionService.modelsReady
            && config.asrModelVersion != oldConfig.asrModelVersion
        {
            Task { await transcriptionService.prepareModels(config: config) }
        }
    }

    func transcribeRecording(_ recording: RecordingInfo, config: TranscriptionConfig? = nil, overwrite: Bool = false) {
        guard transcriptionService.modelsReady else { return }
        let effectiveConfig = config ?? transcriptionConfig
        Task {
            _ = try? await transcriptionService.transcribe(fileURL: recording.url, config: effectiveConfig, overwrite: overwrite)
        }
    }

    func transcribeFile(_ url: URL, config: TranscriptionConfig? = nil, overwrite: Bool = false) {
        // If already in list, just transcribe it
        if let existing = recentRecordings.first(where: { $0.url == url }) {
            transcribeRecording(existing, config: config, overwrite: overwrite)
            return
        }
        // Build RecordingInfo from file attributes and add to recent list
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = attrs?[.size] as? UInt64 ?? 0
        let duration = Self.audioDuration(url: url) ?? 0
        let info = RecordingInfo(url: url, duration: duration, fileSize: size)
        recentRecordings.insert(info, at: 0)
        if recentRecordings.count > 10 { recentRecordings.removeLast() }
        transcribeRecording(info, config: config, overwrite: overwrite)
    }

    func updateSelectedMic(_ uid: String?) async {
        selectedMicUID = uid
        if let uid {
            UserDefaults.standard.set(uid, forKey: SettingsKey.selectedMicUID)
        } else {
            UserDefaults.standard.removeObject(forKey: SettingsKey.selectedMicUID)
        }
        // Restart mic if active to pick up the new device
        if micCapture.isRunning {
            micCapture.stop()
            await startMic()
        }
    }

    var bufferFillSeconds: Int {
        max(systemBuffer.sampleCount, micBuffer.sampleCount) / AudioConstants.sampleRateInt
    }

    private func updateFilledBarCount() {
        let samples = max(systemBuffer.sampleCount, micBuffer.sampleCount)
        let samplesPerBar = bufferDurationSeconds * AudioConstants.sampleRateInt / 100
        filledBarCount = min(100, samples / max(1, samplesPerBar) + 1) // +1 for live bar
    }

    func shutdown() {
        if state == .recording {
            stopRecording()
        }
        writeQueue.sync {
            self.writeTimer?.cancel()
            self.writeTimer = nil
        }
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        waveformTimer?.invalidate()
        waveformTimer = nil
        systemCapture.stop()
        micCapture.stop()
    }

    // MARK: - Stereo Interleaving

    static func interleave(_ system: [Float], _ mic: [Float]) -> [Float] {
        let len = max(system.count, mic.count)
        guard len > 0 else { return [] }
        var result = [Float](repeating: 0, count: len * 2)
        for i in 0..<len {
            result[i * 2]     = i < system.count ? system[i] : 0  // L
            result[i * 2 + 1] = i < mic.count    ? mic[i]    : 0  // R
        }
        return result
    }

    // MARK: - Private

    // Bug #4 fix: Mutually exclusive — when recording, write only to pending arrays;
    // when buffering, write only to circular buffer. Prevents stale data in the
    // circular buffer from polluting the next recording's retroactive buffer.

    private func handleSystemSamples(_ samples: [Float]) {
        routeSamples(samples, peakAccum: &systemPeakAccum,
                     pendingArray: &pendingSystemSamples, buffer: systemBuffer)
    }

    private func handleMicSamples(_ samples: [Float]) {
        routeSamples(samples, peakAccum: &micPeakAccum,
                     pendingArray: &pendingMicSamples, buffer: micBuffer)
    }

    /// Routes incoming audio samples to either the pending recording array or the circular buffer,
    /// and tracks peak amplitude for level metering.
    private func routeSamples(_ samples: [Float], peakAccum: inout Float,
                              pendingArray: inout [Float], buffer: CircularAudioBuffer) {
        var peak: Float = 0
        for s in samples {
            let a = abs(s)
            if a > peak { peak = a }
        }
        meterLock.lock()
        if peak > peakAccum { peakAccum = peak }
        meterLock.unlock()

        var recording = false
        pendingLock.lock()
        if pendingActive {
            recording = true
            pendingArray.append(contentsOf: samples)
        }
        pendingLock.unlock()
        if !recording {
            buffer.write(samples)
        }
    }

    /// Called on writeQueue by the write timer — flushes pending samples to disk.
    /// Bug #3 fix: Uses carry-forward remainder approach to avoid zero-padding micro-gaps.
    /// System and mic deliver different sample counts per 50ms cycle. Instead of padding the
    /// shorter one with zeros, we interleave min() frames and carry forward the tail.
    private func flushPendingSamples() {
        pendingLock.lock()
        let pendingSys = pendingSystemSamples
        let pendingMic = pendingMicSamples
        pendingSystemSamples.removeAll(keepingCapacity: true)
        pendingMicSamples.removeAll(keepingCapacity: true)
        pendingLock.unlock()

        // Prepend any carried-forward remainder from last cycle
        let sys = systemRemainder.isEmpty ? pendingSys : systemRemainder + pendingSys
        let mic = micRemainder.isEmpty ? pendingMic : micRemainder + pendingMic
        systemRemainder = []
        micRemainder = []

        // Silence detection: measure peak amplitude across both sources
        if silenceEnabled {
            var peak: Float = 0
            for s in sys {
                let a = abs(s)
                if a > peak { peak = a }
            }
            for s in mic {
                let a = abs(s)
                if a > peak { peak = a }
            }

            if peak < silenceThresholdLocal {
                silenceSampleCount += max(sys.count, mic.count)
                if silenceSampleCount >= silenceSampleThreshold {
                    if !silenceDetected {
                        silenceDetected = true
                        DispatchQueue.main.async { [weak self] in
                            self?.isSilencePaused = true
                        }
                    }
                    // Discard samples and clear remainders during silence
                    return
                }
                // Below threshold but timeout not yet reached — fall through and write normally
            } else {
                silenceSampleCount = 0
                if silenceDetected {
                    silenceDetected = false
                    DispatchQueue.main.async { [weak self] in
                        self?.isSilencePaused = false
                    }
                }
            }
        }

        guard let w = writer, writeError == nil else { return }

        let sysCount = sys.count
        let micCount = mic.count

        let stereo: [Float]
        if sysCount > 0 && micCount > 0 {
            // Both sources have data — interleave min(), carry forward the tail
            let len = min(sysCount, micCount)
            stereo = Self.interleave(Array(sys.prefix(len)), Array(mic.prefix(len)))
            if sysCount > len {
                systemRemainder = Array(sys.suffix(sysCount - len))
            }
            if micCount > len {
                micRemainder = Array(mic.suffix(micCount - len))
            }
        } else if sysCount == 0 && micCount == 0 {
            // Nothing to write
            return
        } else if sysCount == 0 && micCount <= Self.remainderCap {
            // Mic has data but system doesn't yet — carry forward, wait for next cycle
            micRemainder = mic
            return
        } else if micCount == 0 && sysCount <= Self.remainderCap {
            // System has data but mic doesn't yet — carry forward, wait for next cycle
            systemRemainder = sys
            return
        } else {
            // One source exceeds the cap — the other is truly off; flush with zero-pad
            stereo = Self.interleave(sys, mic)
        }

        guard !stereo.isEmpty else { return }

        do {
            try w.append(samples: stereo)
        } catch {
            writeError = error
        }
    }

    private func consumeMeterPeaks() -> (system: Float, mic: Float) {
        meterLock.lock()
        let sys = systemPeakAccum
        let mic = micPeakAccum
        systemPeakAccum = 0
        micPeakAccum = 0
        meterLock.unlock()
        return (sys, mic)
    }

    func startWaveformTimer() {
        waveformTimer?.invalidate()
        waveformAmplitudes = [Float](repeating: 0, count: 100)
        filledBarCount = 1

        waveformTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            guard let self else { return }

            // Level meters: consume peaks tracked inline in audio callbacks
            let peaks = self.consumeMeterPeaks()
            self.systemLevel = max(self.systemLevel * 0.6, peaks.system)
            self.micLevel = max(self.micLevel * 0.6, peaks.mic)

            if self.state == .recording {
                // Streaming mode: shift bars left, append new bar from peak data
                var amps = self.waveformAmplitudes
                amps.removeFirst()
                amps.append(max(peaks.system, peaks.mic))
                self.waveformAmplitudes = amps
                self.filledBarCount = min(100, self.filledBarCount + 1)
            } else {
                // Buffer mode: read from circular buffers
                let sysRaw = self.systemBuffer.getBarPeaks()
                let micRaw = self.micBuffer.getBarPeaks()
                var raw = [Float](repeating: 0, count: 100)
                for i in 0..<100 {
                    raw[i] = max(sysRaw[i], micRaw[i])
                }
                self.waveformAmplitudes = raw
                self.updateFilledBarCount()
            }
        }
    }

    func stopWaveformTimer() {
        waveformTimer?.invalidate()
        waveformTimer = nil
    }

    private func startMic() async {
        let granted = await MicrophoneCapture.requestPermission()
        guard granted else {
            await MainActor.run {
                self.micStatus = .permissionDenied
            }
            return
        }
        do {
            let resolvedID = selectedMicUID.flatMap { deviceEnumerator.deviceID(forUID: $0) }
            try micCapture.start(deviceID: resolvedID)
            await MainActor.run {
                self.micStatus = .active
            }
        } catch {
            await MainActor.run {
                self.micStatus = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: - Errors

    private enum RecordingError: Error, LocalizedError {
        case noWriter

        var errorDescription: String? {
            switch self {
            case .noWriter: return "No active writer"
            }
        }
    }
}
