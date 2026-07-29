import AVFoundation
import CoreAudio
import Foundation
import Observation
import os.log
import SwiftUI
import TranscribeKit

private let logger = Logger(subsystem: "com.vibe.ripcord", category: "RecordingManager")

enum AppState: Equatable {
    case starting
    case buffering
    case recording
    case paused
    case error(String)
}

enum MicStatus: Equatable {
    case off
    case permissionDenied
    case failed(String)
    case active
}

enum SystemMicMode: Equatable {
    case unavailable
    case standard
    case wideSpectrum
    case voiceIsolation
    case unknown(Int)

    var label: String {
        switch self {
        case .unavailable: "Unavailable"
        case .standard: "Standard"
        case .wideSpectrum: "Wide Spectrum"
        case .voiceIsolation: "Voice Isolation"
        case .unknown(let raw): "Unknown (\(raw))"
        }
    }

    var isVoiceIsolation: Bool {
        self == .voiceIsolation
    }
}

enum SettingsKey {
    static let bufferDuration = "ripcord.bufferDurationSeconds"
    static let outputFormat   = "ripcord.outputFormat"
    static let audioQuality   = "ripcord.audioQuality"
    static let micEnabled     = "ripcord.micEnabled"
    static let systemCaptureEnabled = "ripcord.systemCaptureEnabled"
    static let nativeMicDebugEnabled = "ripcord.nativeMicDebugEnabled"
    static let channelSplit   = "ripcord.channelSplit"
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
    static let diarizationQuality = "ripcord.diarizationQuality"
    static let speechThreshold = "ripcord.speechThreshold"
    static let minSegmentDuration = "ripcord.minSegmentDuration"
    static let minGapDuration = "ripcord.minGapDuration"
    static let filePrefix = "ripcord.filePrefix"
    static let recordingNameHistory = "ripcord.recordingNameHistory"
    static let appearanceOverride = "ripcord.appearanceOverride"
    static let liveTranscriptEnabled = "ripcord.liveTranscriptEnabled"
    static let autoLiveTranscript = "ripcord.autoLiveTranscript"
    static let liveTranscriptChunkSize = "ripcord.liveTranscriptChunkSize"
    static let liveTranscriptRightContext = "ripcord.liveTranscriptRightContext"
    static let liveTranscriptMinContext = "ripcord.liveTranscriptMinContext"
    static let liveTranscriptConfirmThreshold = "ripcord.liveTranscriptConfirmThreshold"
    static let modelDownloadPromptDismissed = "ripcord.modelDownloadPromptDismissed"
    static let mainPanelRecentsHeight = "ripcord.mainPanelRecentsHeight"
    static let micLatencySettings = "ripcord.micLatencySettings"
    static let pendingMicRestoreUID = "ripcord.pendingMicRestoreUID"
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
    var diarizationEngine: DiarizationEngine = .offline
    var speakerSensitivity: SpeakerSensitivity = .medium
    var expectedSpeakerCount: Int = -1  // -1 = auto
    var transcriptFormat: OutputFormat = .txt
    var removeFillerWords: Bool = false
    var diarizationQuality: DiarizationQuality = .balanced
    var speechThreshold: Double = 0.5
    var minSegmentDuration: Double = 0.5
    var minGapDuration: Double = 0.0
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
    var systemCaptureEnabled: Bool = true
    var nativeMicDebugEnabled: Bool = false
    var channelSplit: Bool = true
    var outputDirectory: URL
    var recentRecordings: [RecordingInfo] = []  // newest first, capped at 10
    var recordingElapsed: TimeInterval = 0
    var micStatus: MicStatus = .off
    var systemMicMode: SystemMicMode = .unavailable
    var waveformAmplitudes: [Float] = Array(repeating: 0, count: 100)
    var waveformBarStates: [BarState] = Array(repeating: .idle, count: 100)
    var filledBarCount: Int = 1
    /// Absolute visible capture window, used by the waveform handles. Values
    /// are snapshots, never array offsets, so a rolling buffer cannot make a
    /// drag select the wrong audio.
    var visibleCaptureRange = CaptureFrameRange(0, 0)
    var pausedSelectionRange: CaptureFrameRange?
    var recordingSelectedRanges: [CaptureFrameRange] = []
    var isEditingLatestRecording = false
    var latestRecordingEditRange: CaptureFrameRange?
    var latestRecordingEditVisibleRange: CaptureFrameRange?
    var latestRecordingEditWaveformAmplitudes: [Float]?
    var latestRecordingEditWaveformStates: [BarState]?
    var latestRecordingEditFilledBarCount: Int?
    var hasEditableLatestRecording: Bool { latestFinalizedDescriptor != nil }
    var latestRecordingBoundaryRange: CaptureFrameRange? {
        guard let descriptor = latestFinalizedDescriptor,
              let start = descriptor.sourceStart,
              let end = descriptor.sourceEnd else { return nil }
        return CaptureFrameRange(start, end)
    }
    var isApplyingLatestRecordingEdit = false
    var systemLevel: Float = 0
    var micLevel: Float = 0
    var selectedMicUID: String?
    private var pendingMicRestoreUID: String?
    var micLatencyEstimate: AudioLatencyEstimate?
    private var micLatencySettingsByUID: [String: MicLatencySettings] = [:]
    var transcriptionEnabled: Bool = false
    var transcriptionConfig: TranscriptionConfig = TranscriptionConfig()
    var silenceAutoPauseEnabled: Bool = false
    var silenceThreshold: Float = 0.01
    var silenceTimeoutSeconds: Double = 3.0
    var isSilencePaused: Bool = false
    var filePrefix: String = "ripcord"
    var recordingName: String = ""
    var nameHistory: [String] = []
    var liveTranscriptEnabled: Bool = false
    var autoLiveTranscript: Bool = false
    var liveTranscriptClientCount: Int = 0
    var liveTranscriptChunkSize: Double = 3.0
    var liveTranscriptRightContext: Double = 1.0
    var liveTranscriptMinContext: Double = 5.0
    var liveTranscriptConfirmThreshold: Double = 0.65
    private var autoLiveTranscriptStartedForRecording = false
    private var skipAutomaticTranscriptionForRecording = false

    let transcriptionService = TranscriptionService()
    private(set) var speakerProfileStore: SpeakerProfileStore
    let deviceEnumerator = AudioDeviceEnumerator()

    private let systemCapture = SystemAudioCapture()
    private let micCapture = MicrophoneCapture()
    private let micChannelModeStore = MicChannelModeStore()
    private let micGainStore = MicGainStore()
    private let micLatencyStore = MicLatencyStore(key: SettingsKey.micLatencySettings)
    private let latencyEstimateQueue = DispatchQueue(label: "com.vibe.ripcord.latencyEstimate", qos: .utility)

    // CoreAudio callbacks write into these pre-allocated handoffs. A normal
    // queue drains them and performs buffering, waveform, recording, and live
    // transcript work so the real-time threads do not take app-level locks.
    private let systemSampleHandoff = AudioChunkHandoff(capacityFrames: AudioConstants.sampleRateInt * 2)
    private let micSampleHandoff = AudioChunkHandoff(capacityFrames: AudioConstants.sampleRateInt * 2)
    private let audioProcessingQueue = DispatchQueue(label: "com.vibe.ripcord.audiohandoff", qos: .userInitiated)
    private var audioProcessingTimer: DispatchSourceTimer?

    // Dual circular buffers for proper mixing
    private var systemBuffer: CircularAudioBuffer
    private var micBuffer: CircularAudioBuffer

    // Shared waveform tracker — both sources feed peaks here; bars commit on a
    // wall-clock cadence so all 100 slots advance together.
    private var waveformTracker: WaveformTracker

    // Pending sample accumulation for recording — protected by pendingLock
    private var pendingActive = false
    private var pendingSystemChunks: [AudioSampleChunk] = []
    private var pendingMicChunks: [AudioSampleChunk] = []
    private let pendingLock = NSLock()

    // Live transcript streaming
    private(set) var liveTranscriptStream: LiveTranscriptStream?
    private var transcriptSocketServer: TranscriptSocketServer?
    private let liveTranscriptLock = NSLock()

    // App-scoped transcript state — survives window close/open so reopening
    // doesn't replay the backlog word-by-word.
    let transcriptState: TranscriptState

    // Dedicated write queue for off-thread file I/O
    private let writeQueue = DispatchQueue(label: "com.vibe.ripcord.writequeue")
    private var writer: AudioFileWriter?  // Only accessed on writeQueue
    private var writeError: Error?         // Only accessed on writeQueue
    private var writeTimer: DispatchSourceTimer?  // Only accessed on writeQueue

    private var effectiveMicAdvanceFrames = 0
    private var lastObservedDefaultInputID: AudioDeviceID?

    // Channel split snapshot — only accessed on writeQueue
    private var splitEnabled: Bool = true

    // Silence detection state — only accessed on writeQueue
    private var silenceEnabled: Bool = false
    private var silenceThresholdLocal: Float = 0.01
    private var silenceSampleThreshold: Int = 0
    private var silenceSampleCount: Int = 0
    private var silenceDetected: Bool = false

    // Pause tracking
    private var pausedDuration: TimeInterval = 0
    private var pauseStartTime: Date?
    private var selectionTimeline = RecordingSelectionTimeline()
    private var emittedThroughSourceFrame: CaptureFrame?
    private var displayedVisibleStart: CaptureFrame = 0
    private var waveformDisplayActive = false
    private let selectionTimelineLock = NSLock()
    private var recordingSplitSnapshot = true
    private var recordingFormatSnapshot: AudioOutputFormat = .wav
    private var recordingQualitySnapshot: AudioQuality = .medium
    private var recordingMicAdvanceSnapshot = 0
    private var latestFinalizedDescriptor: FinalizedRecordingDescriptor?
    private var editableDescriptor: FinalizedRecordingDescriptor?
    private var frozenFinalizedSystem: AudioBufferSnapshot?
    private var frozenFinalizedMic: AudioBufferSnapshot?
    private var editableFingerprint: FinalizedRecordingDescriptor.Fingerprint?
    private static let storageMarginSeconds = 2

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

    // Directory monitor for recent recordings
    private var directoryMonitorSource: DispatchSourceFileSystemObject?
    private var directoryMonitorFD: Int32 = -1

    // Signal handlers for clean shutdown on kill
    private var signalSources: [DispatchSourceSignal] = []

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
            SettingsKey.systemCaptureEnabled: true,
            SettingsKey.channelSplit: true,
            SettingsKey.outputDirectory: defaultDir.path,
            SettingsKey.launchAtLogin: false,
        ])

        let savedDuration = defaults.integer(forKey: SettingsKey.bufferDuration)
        let duration = savedDuration > 0 ? savedDuration : 300

        // Init buffers first (required before accessing self properties with @Observable)
        systemBuffer = CircularAudioBuffer(
            durationSeconds: duration + Self.storageMarginSeconds,
            sampleRate: AudioConstants.sampleRateInt
        )
        micBuffer = CircularAudioBuffer(
            durationSeconds: duration + Self.storageMarginSeconds,
            sampleRate: AudioConstants.sampleRateInt
        )
        waveformTracker = WaveformTracker(durationSeconds: duration)

        transcriptState = MainActor.assumeIsolated { TranscriptState() }

        let resolvedDir: URL
        if let dirPath = defaults.string(forKey: SettingsKey.outputDirectory), !dirPath.isEmpty {
            resolvedDir = URL(fileURLWithPath: dirPath, isDirectory: true)
        } else {
            resolvedDir = defaultDir
        }
        outputDirectory = resolvedDir

        speakerProfileStore = SpeakerProfileStore(directory: resolvedDir)
        transcriptionService.speakerProfileStore = speakerProfileStore

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
        systemCaptureEnabled = defaults.bool(forKey: SettingsKey.systemCaptureEnabled)
        nativeMicDebugEnabled = defaults.bool(forKey: SettingsKey.nativeMicDebugEnabled)
        channelSplit = defaults.bool(forKey: SettingsKey.channelSplit)
        selectedMicUID = defaults.string(forKey: SettingsKey.selectedMicUID)
        pendingMicRestoreUID = defaults.string(forKey: SettingsKey.pendingMicRestoreUID)
        micLatencySettingsByUID = micLatencyStore.allSettings()
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
        if let qualStr = defaults.string(forKey: SettingsKey.diarizationQuality),
           let qual = DiarizationQuality(rawValue: qualStr) {
            transcriptionConfig.diarizationQuality = qual
        }
        if defaults.object(forKey: SettingsKey.speechThreshold) != nil {
            transcriptionConfig.speechThreshold = defaults.double(forKey: SettingsKey.speechThreshold)
        }
        if defaults.object(forKey: SettingsKey.minSegmentDuration) != nil {
            transcriptionConfig.minSegmentDuration = defaults.double(forKey: SettingsKey.minSegmentDuration)
        }
        if defaults.object(forKey: SettingsKey.minGapDuration) != nil {
            transcriptionConfig.minGapDuration = defaults.double(forKey: SettingsKey.minGapDuration)
        }

        // Load file prefix and name history
        if let savedPrefix = defaults.string(forKey: SettingsKey.filePrefix) {
            filePrefix = savedPrefix
        }
        nameHistory = (defaults.stringArray(forKey: SettingsKey.recordingNameHistory) ?? [])

        // Live transcript
        liveTranscriptEnabled = defaults.bool(forKey: SettingsKey.liveTranscriptEnabled)
        autoLiveTranscript = defaults.bool(forKey: SettingsKey.autoLiveTranscript)
        let savedChunk = defaults.double(forKey: SettingsKey.liveTranscriptChunkSize)
        liveTranscriptChunkSize = savedChunk > 0 ? savedChunk : 3.0
        let savedRC = defaults.double(forKey: SettingsKey.liveTranscriptRightContext)
        liveTranscriptRightContext = savedRC > 0 ? savedRC : 1.0
        let savedMinCtx = defaults.double(forKey: SettingsKey.liveTranscriptMinContext)
        liveTranscriptMinContext = savedMinCtx > 0 ? savedMinCtx : 5.0
        let savedThresh = defaults.double(forKey: SettingsKey.liveTranscriptConfirmThreshold)
        liveTranscriptConfirmThreshold = savedThresh > 0 ? savedThresh : 0.65

        refreshSystemMicMode()
        deviceEnumerator.onDevicesChanged = { [weak self] devices in
            self?.handleInputDevicesChanged(devices)
        }
        lastObservedDefaultInputID = deviceEnumerator.defaultInputDeviceID
        handleInputDevicesChanged(deviceEnumerator.inputDevices)
        refreshCurrentMicLatencyEstimate()
        installSignalHandlers()
        startAudioProcessingTimer()
    }

    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                self?.shutdown()
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    deinit {
        audioProcessingTimer?.cancel()
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
        systemCapture.onSamples = { [weak self] samples, timing in
            self?.systemSampleHandoff.write(samples, timing: timing)
        }
        micCapture.onSamples = { [weak self] samples, timing in
            self?.micSampleHandoff.write(samples, timing: timing)
        }

        // Coordinate mic AUHAL with system capture restarts.
        // When the system capture's aggregate device restarts (output device
        // change), we must also cycle the mic AUHAL so both input sessions
        // tear down together. Otherwise IOState escalates from [1, 0] to
        // [2, 0] which blocks VoiceProcessingIO in meeting apps.
        //
        // Suppress the mic's independent restart immediately when a route
        // change is detected — before the 2s debounce. This prevents the
        // mic from restarting on its own (via its default-input listener)
        // before the coordinated cycle runs.
        systemCapture.onRouteChangeDetected = { [weak self] in
            self?.micCapture.suppressRestart()
        }
        systemCapture.onWillRestart = { [weak self] in
            self?.micCapture.stop()
        }
        systemCapture.onDidRestart = { [weak self] in
            guard let self else { return }
            self.micCapture.unsuppressRestart()
            let wantsMic = await MainActor.run { self.micEnabled }
            guard wantsMic else { return }
            await self.startMic()
        }

        let wantsSystemCapture = await MainActor.run { systemCaptureEnabled }
        if wantsSystemCapture {
            do {
                try await systemCapture.start()
            } catch {
                await MainActor.run {
                    self.state = .error("System audio: \(error.localizedDescription)")
                }
                return
            }
        } else {
            logger.error("System audio capture disabled by \(SettingsKey.systemCaptureEnabled, privacy: .public)")
        }

        // Start mic capture if enabled and permission was granted
        if micGranted {
            await startMic()
        }

        await MainActor.run {
            self.state = .buffering
        }

        // Ensure output directory exists before loading recordings or monitoring it
        let dir = await MainActor.run { outputDirectory }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        await loadRecentRecordings()
        await MainActor.run {
            transcriptionService.loadPendingSpeakers(in: outputDirectory)
            startDirectoryMonitor()
        }

        // Start the control/transcript socket server (always on for remote control)
        await startControlSocket()

        if !transcriptionService.modelsReady
            && TranscriptionService.modelsExistOnDisk(config: transcriptionConfig) {
            Task {
                await transcriptionService.prepareModels(config: transcriptionConfig, fromCache: true)
                // Auto-start live transcript if enabled and models are now ready
                if await MainActor.run(body: { self.liveTranscriptEnabled })
                    && transcriptionService.modelsReady {
                    await startLiveTranscript()
                }
            }
        } else if transcriptionService.modelsReady && liveTranscriptEnabled {
            Task { await startLiveTranscript() }
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

    private func startDirectoryMonitor() {
        stopDirectoryMonitor()
        let dir = outputDirectory
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        directoryMonitorFD = fd
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            // Skip reload while recording — stopRecording handles list insertion itself,
            // and the file write/finalize events would cause stale or duplicate entries.
            if self.state == .recording || self.state == .paused { return }
            Task { await self.loadRecentRecordings() }
        }
        source.setCancelHandler { close(fd) }
        directoryMonitorSource = source
        source.resume()
    }

    private func stopDirectoryMonitor() {
        directoryMonitorSource?.cancel()
        directoryMonitorSource = nil
        directoryMonitorFD = -1
    }

    private static func audioDuration(url: URL) -> Double? {
        if let audioFile = try? AVAudioFile(forReading: url) {
            let sampleRate = audioFile.processingFormat.sampleRate
            guard sampleRate > 0 else { return nil }
            return Double(audioFile.length) / sampleRate
        }
        // Fall back to AVAsset for video/media containers
        let asset = AVURLAsset(url: url)
        let d = asset.duration  // sync property deprecated but async load() unusable from sync context
        guard d.timescale > 0 else { return nil }
        let s = CMTimeGetSeconds(d)
        return s.isFinite ? s : nil
    }

    private static func fingerprint(for url: URL) -> FinalizedRecordingDescriptor.Fingerprint? {
        guard let values = try? url.resourceValues(forKeys: [
            .fileSizeKey,
            .contentModificationDateKey,
        ]), let size = values.fileSize,
           let modificationDate = values.contentModificationDate else { return nil }
        return FinalizedRecordingDescriptor.Fingerprint(
            size: UInt64(size),
            modificationDate: modificationDate
        )
    }

    private static func synchronizeFile(at url: URL) {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { return }
        _ = fsync(descriptor)
        close(descriptor)
    }

    private static func synchronizeDirectory(containing url: URL) {
        let descriptor = open(url.deletingLastPathComponent().path, O_RDONLY)
        guard descriptor >= 0 else { return }
        _ = fsync(descriptor)
        close(descriptor)
    }

    func transcriptURLs(for audioURL: URL) -> [URL] {
        let directory = audioURL.deletingLastPathComponent()
        let stem = audioURL.deletingPathExtension().lastPathComponent
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        let extensions = Set(OutputFormat.allCases.map(\.rawValue))
        return files.filter { url in
            guard extensions.contains(url.pathExtension.lowercased()) else { return false }
            let candidate = url.deletingPathExtension().lastPathComponent
            guard candidate == stem || candidate.hasPrefix(stem + "-") else { return false }
            if candidate == stem { return true }
            return Int(candidate.dropFirst(stem.count + 1)) != nil
        }
    }

    func startRecording() {
        guard state == .buffering, !isEditingLatestRecording else { return }
        logger.error("Recording started")
        refreshSystemMicMode()
        if systemMicMode.isVoiceIsolation {
            logger.error("Recording while macOS Mic Mode is Voice Isolation; non-voice USB inputs may be attenuated")
        }
        let skipAutomaticTranscription = shouldSkipAutomaticTranscriptionForCurrentInput()
        skipAutomaticTranscriptionForRecording = skipAutomaticTranscription
        autoLiveTranscriptStartedForRecording = false
        if skipAutomaticTranscription, let device = currentSelectedMicDevice() {
            logger.info("Skipping automatic transcription for USB audio input: \(device.name, privacy: .public)")
        }

        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "T", with: "_")
            .prefix(19)

        var parts: [String] = []
        let trimmedPrefix = filePrefix.trimmingCharacters(in: .whitespaces)
        if !trimmedPrefix.isEmpty {
            parts.append(trimmedPrefix)
        }
        parts.append(String(timestamp))
        let filename = parts.joined(separator: "_") + ".\(outputFormat.fileExtension)"

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

        if nativeMicDebugEnabled {
            let nativeDebugURL = fileURL
                .deletingPathExtension()
                .appendingPathExtension("native.wav")
            do {
                try micCapture.startNativeDebugRecording(url: nativeDebugURL)
            } catch {
                logger.error("Native mic debug recording could not start: \(error.localizedDescription)")
            }
        }

        // Select buffered audio on the canonical capture timeline. It remains
        // unwritten while it is visible, which is what makes later Out edits
        // reversible without truncating WAV/M4A files.
        let captureFrames = captureDurationSeconds * AudioConstants.sampleRateInt
        let visible = currentVisibleCaptureRange()
        let initialStart = max(visible.start, visible.end - CaptureFrame(captureFrames))
        selectionTimelineLock.withLock {
            selectionTimeline.start(with: CaptureFrameRange(initialStart, visible.end))
            emittedThroughSourceFrame = visible.isEmpty ? nil : initialStart
            displayedVisibleStart = visible.start
        }
        recordingSelectedRanges = visible.isEmpty
            ? []
            : [CaptureFrameRange(initialStart, visible.end)]
        latestFinalizedDescriptor = nil
        recordingSplitSnapshot = channelSplit
        recordingFormatSnapshot = outputFormat
        recordingQualitySnapshot = audioQuality

        // Mark back-record bars as recorded and set state for new bars
        let barsInCapture = min(100, captureDurationSeconds * 100 / max(1, bufferDurationSeconds))
        waveformTracker.markRecentBars(barsInCapture, state: .recorded)
        waveformTracker.setBarState(.recorded)

        // Enable pending AFTER reading (tiny sample gap is negligible)
        pendingLock.lock()
        pendingActive = true
        pendingSystemChunks.removeAll()
        pendingMicChunks.removeAll()
        pendingLock.unlock()

        // Snapshot settings for writeQueue (read from main thread before dispatch)
        let split = channelSplit
        let silenceOn = silenceAutoPauseEnabled
        let silenceThresh = silenceThreshold
        let silenceTimeout = silenceTimeoutSeconds
        let micAdvanceFrames = currentEffectiveMicLatencyFrames()
        recordingMicAdvanceSnapshot = micAdvanceFrames

        writeQueue.async { [weak self] in
            guard let self else { return }
            self.writer = newWriter
            self.writeError = nil
            self.effectiveMicAdvanceFrames = micAdvanceFrames
            self.splitEnabled = split
            self.silenceEnabled = silenceOn
            self.silenceThresholdLocal = silenceThresh
            self.silenceSampleThreshold = Int(silenceTimeout * Double(AudioConstants.sampleRateInt))
            self.silenceSampleCount = 0
            self.silenceDetected = false

            // Start write timer (fires every 50ms on writeQueue)
            let timer = DispatchSource.makeTimerSource(queue: self.writeQueue)
            timer.schedule(deadline: .now() + .milliseconds(50), repeating: .milliseconds(50))
            timer.setEventHandler { [weak self] in
                self?.flushPendingSamples()
            }
            timer.resume()
            self.writeTimer = timer
        }

        // Update state and start elapsed timer
        state = .recording
        recordingStartTime = Date()
        recordingElapsed = 0
        pausedDuration = 0
        pauseStartTime = nil
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, let start = self.recordingStartTime else { return }
            guard self.state != .paused else { return }
            self.recordingElapsed = Date().timeIntervalSince(start) - self.pausedDuration
        }

        if autoLiveTranscript && !liveTranscriptEnabled && !skipAutomaticTranscription {
            autoLiveTranscriptStartedForRecording = true
            Task { await setLiveTranscriptEnabled(true) }
        }
    }

    func stopRecording() {
        guard state == .recording || state == .paused else { return }
        logger.error("Recording stopping")
        let stopFrame = currentVisibleCaptureRange().end
        let finalizedSpans = selectionTimelineLock.withLock { () -> [SourceOutputSpan] in
            selectionTimeline.stop(at: stopFrame)
            return selectionTimeline.outputSpans(at: stopFrame)
        }

        if autoLiveTranscriptStartedForRecording && liveTranscriptEnabled {
            Task { await setLiveTranscriptEnabled(false) }
        }
        autoLiveTranscriptStartedForRecording = false
        let skipAutomaticTranscription = skipAutomaticTranscriptionForRecording
        skipAutomaticTranscriptionForRecording = false

        // Finalize any ongoing pause
        if let pauseStart = pauseStartTime {
            pausedDuration += Date().timeIntervalSince(pauseStart)
            pauseStartTime = nil
        }

        // Stop elapsed timer (main thread)
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        recordingStartTime = nil
        recordingElapsed = 0
        isSilencePaused = false
        pausedSelectionRange = nil
        recordingSelectedRanges = []

        // Dim recorded/paused bars to prior variants, set new bars to idle
        waveformTracker.dimAllBars()
        waveformTracker.setBarState(.idle)

        // Disable pending accumulation and grab remaining samples
        pendingLock.lock()
        pendingActive = false
        pendingSystemChunks.removeAll()
        pendingMicChunks.removeAll()
        pendingLock.unlock()

        if nativeMicDebugEnabled {
            micCapture.stopNativeDebugRecording()
        }

        // Flush remaining samples, cancel timer, and finalize writer on writeQueue
        var result: Result<RecordingInfo, Error>?
        writeQueue.sync {
            // Cancel timer on its owning queue
            self.writeTimer?.cancel()
            self.writeTimer = nil

            self.commitSelectedTimeline(upTo: stopFrame)

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

        // Apply recording name (user may have typed it during recording)
        let sanitizedName = Self.sanitizeRecordingName(recordingName)
        addToNameHistory(sanitizedName)
        recordingName = ""

        if !sanitizedName.isEmpty, case .success(var info) = result {
            let ext = info.url.pathExtension
            let stem = info.url.deletingPathExtension().lastPathComponent
            let newFilename = stem + "_" + sanitizedName + "." + ext
            let newURL = info.url.deletingLastPathComponent().appendingPathComponent(newFilename)
            do {
                try FileManager.default.moveItem(at: info.url, to: newURL)
                info.url = newURL
                result = .success(info)
            } catch {
                // Rename failed; keep original filename
            }
        }

        // Update state based on result
        switch result {
        case .success(let info):
            logger.error("Recording stopped: \(info.url.lastPathComponent) (\(info.formattedDuration), \(info.formattedSize))")
            recentRecordings.removeAll { $0.url == info.url }
            recentRecordings.insert(info, at: 0)
            if recentRecordings.count > 10 { recentRecordings.removeLast() }
            UserDefaults.standard.set(true, forKey: SettingsKey.hasRecordedBefore)
            if let fingerprint = Self.fingerprint(for: info.url) {
                latestFinalizedDescriptor = FinalizedRecordingDescriptor(
                    recording: info,
                    spans: finalizedSpans,
                    split: recordingSplitSnapshot,
                    format: recordingFormatSnapshot,
                    quality: recordingQualitySnapshot,
                    micAdvanceFrames: recordingMicAdvanceSnapshot,
                    fingerprint: fingerprint
                )
            } else {
                latestFinalizedDescriptor = nil
            }
            state = .buffering
            if transcriptionEnabled && transcriptionService.modelsReady && !skipAutomaticTranscription {
                transcribeRecording(info)
            }
        case .failure(let error):
            logger.error("Recording failed: \(error.localizedDescription)")
            state = .error("Recording failed: \(error.localizedDescription)")
        case .none:
            state = .buffering
        }
    }

    func pauseRecording() {
        guard state == .recording else { return }
        logger.error("Recording paused")

        // Stop accumulating samples for recording
        pendingLock.lock()
        pendingActive = false
        pendingSystemChunks.removeAll()
        pendingMicChunks.removeAll()
        pendingLock.unlock()

        // Update bar states to paused
        waveformTracker.setBarState(.paused)

        // Track pause time
        pauseStartTime = Date()
        let visible = currentVisibleCaptureRange()
        selectionTimelineLock.withLock {
            selectionTimeline.pause(at: visible.end)
            if let edit = selectionTimeline.pauseEdit {
                pausedSelectionRange = CaptureFrameRange(edit.out, edit.in)
            }
        }

        state = .paused
    }

    func updatePausedSelection(out: CaptureFrame? = nil, in: CaptureFrame? = nil) {
        guard state == .paused else { return }
        let visible = currentVisibleCaptureRange()
        selectionTimelineLock.withLock {
            selectionTimeline.updatePause(
                out: out,
                in: `in`,
                now: visible.end,
                visible: visible
            )
            if let edit = selectionTimeline.pauseEdit {
                pausedSelectionRange = CaptureFrameRange(edit.out, edit.in)
            }
        }
    }

    func resumeRecording() {
        guard state == .paused else { return }
        logger.error("Recording resumed")

        // Accumulate paused duration
        if let pauseStart = pauseStartTime {
            pausedDuration += Date().timeIntervalSince(pauseStart)
            pauseStartTime = nil
        }

        let resumeFrame = currentVisibleCaptureRange().end
        selectionTimelineLock.withLock {
            selectionTimeline.resume(at: resumeFrame)
        }

        pendingLock.lock()
        pendingActive = true
        pendingSystemChunks.removeAll()
        pendingMicChunks.removeAll()
        pendingLock.unlock()

        // Update bar states to recorded
        waveformTracker.setBarState(.recorded)

        // Update elapsed immediately so the display doesn't lag for up to 1 second
        if let start = recordingStartTime {
            recordingElapsed = Date().timeIntervalSince(start) - pausedDuration
        }

        state = .recording
        pausedSelectionRange = nil
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

    func updateChannelSplit(_ enabled: Bool) {
        channelSplit = enabled
        UserDefaults.standard.set(enabled, forKey: SettingsKey.channelSplit)
    }

    func updateBufferDuration(_ seconds: Int) {
        guard state != .recording && state != .paused else { return }
        if isEditingLatestRecording { cancelLatestRecordingEdit() }
        latestFinalizedDescriptor = nil
        bufferDurationSeconds = seconds
        UserDefaults.standard.set(seconds, forKey: SettingsKey.bufferDuration)
        systemBuffer.resize(
            durationSeconds: seconds + Self.storageMarginSeconds,
            sampleRate: AudioConstants.sampleRateInt
        )
        micBuffer.resize(
            durationSeconds: seconds + Self.storageMarginSeconds,
            sampleRate: AudioConstants.sampleRateInt
        )
        waveformTracker.resize(durationSeconds: seconds)
        // Clamp capture duration to not exceed new buffer size
        if captureDurationSeconds > seconds {
            updateCaptureDuration(seconds)
        }
    }

    func updateCaptureDuration(_ seconds: Int) {
        captureDurationSeconds = max(5, min(seconds, bufferDurationSeconds))
        UserDefaults.standard.set(captureDurationSeconds, forKey: SettingsKey.captureDuration)
    }

    func updateLatestRecordingEdit(start: CaptureFrame? = nil, end: CaptureFrame? = nil) {
        guard state == .buffering, let descriptor = latestFinalizedDescriptor,
              descriptor.recording.url == recentRecordings.first?.url else { return }
        if !isEditingLatestRecording {
            editableDescriptor = descriptor
            frozenFinalizedSystem = systemBuffer.snapshot()
            frozenFinalizedMic = micBuffer.snapshot()
            latestRecordingEditVisibleRange = visibleCaptureRange
            latestRecordingEditWaveformAmplitudes = waveformAmplitudes
            latestRecordingEditWaveformStates = waveformBarStates
            latestRecordingEditFilledBarCount = filledBarCount
            latestRecordingEditRange = latestRecordingBoundaryRange
            editableFingerprint = descriptor.fingerprint
            isEditingLatestRecording = true
        }
        guard var range = latestRecordingEditRange,
              let visible = latestRecordingEditVisibleRange else { return }
        if let start {
            range.start = max(visible.start, min(start, range.end))
        }
        if let end {
            range.end = min(visible.end, max(end, range.start))
        }
        latestRecordingEditRange = range
    }

    func cancelLatestRecordingEdit() {
        isEditingLatestRecording = false
        editableDescriptor = nil
        latestRecordingEditRange = nil
        latestRecordingEditVisibleRange = nil
        latestRecordingEditWaveformAmplitudes = nil
        latestRecordingEditWaveformStates = nil
        latestRecordingEditFilledBarCount = nil
        frozenFinalizedSystem = nil
        frozenFinalizedMic = nil
        editableFingerprint = nil
    }

    func applyLatestRecordingEdit() async {
        guard !isApplyingLatestRecordingEdit, isEditingLatestRecording,
              let descriptor = editableDescriptor,
              let range = latestRecordingEditRange, !range.isEmpty,
              let system = frozenFinalizedSystem,
              let mic = frozenFinalizedMic,
              let expectedFingerprint = editableFingerprint else { return }
        isApplyingLatestRecordingEdit = true
        defer { isApplyingLatestRecordingEdit = false }

        let recording = descriptor.recording
        await transcriptionService.cancelTranscriptionAndWait(for: recording.url)
        guard Self.fingerprint(for: recording.url) == expectedFingerprint else { return }
        let ext = descriptor.format.fileExtension
        let staging = recording.url.deletingLastPathComponent().appendingPathComponent(
            ".\(recording.url.deletingPathExtension().lastPathComponent).ripcord-edit-\(UUID().uuidString).\(ext)"
        )
        guard !FileManager.default.fileExists(atPath: staging.path) else { return }
        do {
            let plan = FinalizedBoundaryEditPlan(selection: range, descriptor: descriptor)
            let prefix = plan.prefixRange.map {
                packedCaptureRange(
                    $0,
                    systemSnapshot: system,
                    micSnapshot: mic,
                    split: descriptor.split,
                    micAdvanceFrames: descriptor.micAdvanceFrames
                )
            } ?? []
            let suffix = plan.suffixRange.map {
                packedCaptureRange(
                    $0,
                    systemSnapshot: system,
                    micSnapshot: mic,
                    split: descriptor.split,
                    micAdvanceFrames: descriptor.micAdvanceFrames
                )
            } ?? []
            let expectedDuration =
                Double(prefix.count / 2 + suffix.count / 2) / AudioConstants.sampleRate
                + (plan.originalCrop.map { $0.upperBound - $0.lowerBound } ?? 0)
            let rendered = try AudioEditRenderer.render(
                from: recording.url,
                originalCrop: plan.originalCrop,
                prefix: prefix,
                suffix: suffix,
                to: staging,
                format: descriptor.format,
                quality: descriptor.quality
            )
            guard let stagedDuration = Self.audioDuration(url: staging),
                  abs(stagedDuration - expectedDuration) < max(0.15, expectedDuration * 0.01),
                  rendered.fileSize > 0,
                  let stagedFile = try? AVAudioFile(forReading: staging),
                  stagedFile.processingFormat.channelCount == 2 else {
                throw AudioEditRenderer.RenderError.verificationFailed
            }
            Self.synchronizeFile(at: staging)
            guard Self.fingerprint(for: recording.url) == expectedFingerprint else {
                throw AudioEditRenderer.RenderError.targetChanged
            }
            _ = try FileManager.default.replaceItemAt(recording.url, withItemAt: staging,
                                                        backupItemName: nil, options: [])
            Self.synchronizeDirectory(containing: recording.url)
            var updated = rendered
            updated.url = recording.url
            recentRecordings.removeAll { $0.url == recording.url }
            recentRecordings.insert(updated, at: 0)
            if recentRecordings.count > 10 { recentRecordings.removeLast() }
            let newRanges = RecordingSelectionTimeline.coalesced(
                descriptor.spans.compactMap { span -> CaptureFrameRange? in
                    let start = max(range.start, span.source.start)
                    let end = min(range.end, span.source.end)
                    return end > start ? CaptureFrameRange(start, end) : nil
                } + [plan.prefixRange, plan.suffixRange].compactMap { $0 }
            )
            var output: CaptureFrame = 0
            let newSpans = newRanges.map { source -> SourceOutputSpan in
                defer { output += CaptureFrame(source.count) }
                return SourceOutputSpan(source: source, outputStart: output)
            }
            if let fingerprint = Self.fingerprint(for: recording.url) {
                latestFinalizedDescriptor = FinalizedRecordingDescriptor(
                    recording: updated,
                    spans: newSpans,
                    split: descriptor.split,
                    format: descriptor.format,
                    quality: descriptor.quality,
                    micAdvanceFrames: descriptor.micAdvanceFrames,
                    fingerprint: fingerprint
                )
            }
            cancelLatestRecordingEdit()
        } catch {
            try? FileManager.default.removeItem(at: staging)
            logger.error("Could not apply recording edit: \(error.localizedDescription)")
        }
    }

    func transcriptIsStale(for recording: RecordingInfo) -> Bool {
        let audioDate = (try? recording.url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        guard let audioDate else { return false }
        guard let transcriptDate = transcriptURLs(for: recording.url).compactMap({
            (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        }).max() else { return false }
        return transcriptDate < audioDate
    }

    func updateOutputFormat(_ format: AudioOutputFormat) {
        guard state != .recording && state != .paused else { return }
        outputFormat = format
        UserDefaults.standard.set(format.rawValue, forKey: SettingsKey.outputFormat)
    }

    func updateAudioQuality(_ quality: AudioQuality) {
        guard state != .recording && state != .paused else { return }
        audioQuality = quality
        UserDefaults.standard.set(quality.rawValue, forKey: SettingsKey.audioQuality)
    }

    func updateOutputDirectory(_ url: URL) {
        if isEditingLatestRecording { cancelLatestRecordingEdit() }
        latestFinalizedDescriptor = nil
        outputDirectory = url
        UserDefaults.standard.set(url.path, forKey: SettingsKey.outputDirectory)
        speakerProfileStore = SpeakerProfileStore(directory: url)
        transcriptionService.speakerProfileStore = speakerProfileStore
        transcriptionService.loadPendingSpeakers(in: url)
        startDirectoryMonitor()
        Task { await loadRecentRecordings() }
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
        Task {
            await transcriptionService.prepareModels(config: transcriptionConfig)
            // Auto-enable transcription on first successful download
            await MainActor.run {
                if transcriptionService.modelsReady && !transcriptionEnabled {
                    updateTranscriptionEnabled(true)
                }
            }
        }
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
        defaults.set(config.diarizationQuality.rawValue, forKey: SettingsKey.diarizationQuality)
        defaults.set(config.speechThreshold, forKey: SettingsKey.speechThreshold)
        defaults.set(config.minSegmentDuration, forKey: SettingsKey.minSegmentDuration)
        defaults.set(config.minGapDuration, forKey: SettingsKey.minGapDuration)

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
        transcriptionService.startTranscription(
            fileURL: recording.url,
            audioDuration: recording.duration,
            config: effectiveConfig,
            overwrite: overwrite
        )
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
        pendingMicRestoreUID = nil
        UserDefaults.standard.removeObject(forKey: SettingsKey.pendingMicRestoreUID)
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
        refreshCurrentMicLatencyEstimate()
    }

    private func handleInputDevicesChanged(_ devices: [AudioInputDevice]) {
        let currentDefaultID = deviceEnumerator.defaultInputDeviceID
        let defaultChanged = currentDefaultID != lastObservedDefaultInputID
        lastObservedDefaultInputID = currentDefaultID

        if let pendingMicRestoreUID,
           devices.contains(where: { $0.uid == pendingMicRestoreUID }) {
            selectedMicUID = pendingMicRestoreUID
            self.pendingMicRestoreUID = nil
            UserDefaults.standard.set(pendingMicRestoreUID, forKey: SettingsKey.selectedMicUID)
            UserDefaults.standard.removeObject(forKey: SettingsKey.pendingMicRestoreUID)
            Task { await restartMicIfDesired() }
            refreshCurrentMicLatencyEstimate()
            return
        }

        if selectedMicUID == nil, defaultChanged, micEnabled {
            Task { await restartMicIfDesired() }
        }

        guard let selectedMicUID,
              !devices.contains(where: { $0.uid == selectedMicUID }) else {
            return
        }

        pendingMicRestoreUID = selectedMicUID
        self.selectedMicUID = nil
        UserDefaults.standard.removeObject(forKey: SettingsKey.selectedMicUID)
        UserDefaults.standard.set(selectedMicUID, forKey: SettingsKey.pendingMicRestoreUID)
        Task { await restartMicIfDesired() }
        refreshCurrentMicLatencyEstimate()
    }

    private func restartMicIfDesired() async {
        guard micEnabled else { return }
        if micCapture.isRunning { micCapture.stop() }
        await startMic()
    }

    /// Returns the persisted channel mode for the currently selected mic
    /// (or system default, identified by its current device ID's UID).
    /// Returns nil when no mic is selected and no system default exists.
    func currentMicChannelMode() -> MicChannelMode? {
        guard let device = currentSelectedMicDevice() else { return nil }
        return micChannelModeStore.mode(forUID: device.uid, channelCount: device.inputChannelCount)
    }

    /// Resolves the currently selected mic to an AudioInputDevice (the user's
    /// pinned UID, or the system default if no pin).
    func currentSelectedMicDevice() -> AudioInputDevice? {
        let devices = deviceEnumerator.inputDevices
        if let uid = selectedMicUID {
            return devices.first(where: { $0.uid == uid })
        }
        if let defaultID = deviceEnumerator.defaultInputDeviceID {
            return devices.first(where: { $0.id == defaultID })
        }
        return nil
    }

    private func shouldSkipAutomaticTranscriptionForCurrentInput() -> Bool {
        guard micEnabled, let device = currentSelectedMicDevice() else { return false }
        return device.shouldSkipAutomaticTranscription
    }

    /// Persist channel mode for a specific device UID and restart mic if
    /// it's the currently active device.
    func updateMicChannelMode(_ mode: MicChannelMode, forUID uid: String) async {
        micChannelModeStore.setMode(mode, forUID: uid)
        let currentUID = currentSelectedMicDevice()?.uid
        if currentUID == uid, micCapture.isRunning {
            micCapture.stop()
            await startMic()
        }
    }

    /// Per-device input gain in dB. 0 = unity. USB instrument/line inputs
    /// commonly need +20..+60 dB because they skip the mic-preamp stage that
    /// audio interfaces apply before the ADC.
    func currentMicGainDB() -> Double {
        guard let device = currentSelectedMicDevice() else { return 0 }
        return micGainStore.gainDB(forUID: device.uid)
    }

    /// Live-update gain without restarting capture if it's the active device.
    func updateMicGainDB(_ dB: Double, forUID uid: String) {
        let clamped = max(-60, min(80, dB))
        micGainStore.setGainDB(clamped, forUID: uid)
        if currentSelectedMicDevice()?.uid == uid {
            micCapture.setInputGain(dB: clamped)
        }
    }

    func currentMicLatencySettings() -> MicLatencySettings {
        guard let device = currentSelectedMicDevice() else { return MicLatencySettings() }
        return micLatencySettingsByUID[device.uid] ?? MicLatencySettings()
    }

    func currentMicLatencyEstimate() -> AudioLatencyEstimate? {
        micLatencyEstimate
    }

    func refreshCurrentMicLatencyEstimate() {
        let inputID = currentSelectedMicDevice()?.id
        let selectedUID = currentSelectedMicDevice()?.uid
        latencyEstimateQueue.async { [weak self] in
            let estimate = AudioLatencyEstimator.estimate(inputDeviceID: inputID)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if self.currentSelectedMicDevice()?.uid == selectedUID {
                    self.micLatencyEstimate = estimate
                    self.refreshWriteLatencyOffsetIfNeeded(uid: selectedUID ?? "")
                }
            }
        }
    }

    func currentEffectiveMicLatencyOffsetMs() -> Double {
        let settings = currentMicLatencySettings()
        if settings.autoEnabled {
            return MicLatencyStore.clamp((currentMicLatencyEstimate()?.totalMs ?? 0) + settings.manualTrimMs)
        }
        return settings.manualOffsetMs
    }

    func updateMicLatencyAutoEnabled(_ enabled: Bool, forUID uid: String) {
        var settings = micLatencySettingsByUID[uid] ?? MicLatencySettings()
        settings.autoEnabled = enabled
        setMicLatencySettings(settings, forUID: uid)
        refreshWriteLatencyOffsetIfNeeded(uid: uid)
    }

    func updateMicLatencyManualOffsetMs(_ value: Double, forUID uid: String) {
        var settings = micLatencySettingsByUID[uid] ?? MicLatencySettings()
        settings.manualOffsetMs = MicLatencyStore.clamp(value)
        setMicLatencySettings(settings, forUID: uid)
        refreshWriteLatencyOffsetIfNeeded(uid: uid)
    }

    func updateMicLatencyManualTrimMs(_ value: Double, forUID uid: String) {
        var settings = micLatencySettingsByUID[uid] ?? MicLatencySettings()
        settings.manualTrimMs = MicLatencyStore.clamp(value)
        setMicLatencySettings(settings, forUID: uid)
        refreshWriteLatencyOffsetIfNeeded(uid: uid)
    }

    private func setMicLatencySettings(_ settings: MicLatencySettings, forUID uid: String) {
        micLatencySettingsByUID[uid] = settings
        micLatencyStore.setSettings(settings, forUID: uid)
    }

    private func currentEffectiveMicLatencyFrames() -> Int {
        Int((currentEffectiveMicLatencyOffsetMs() * AudioConstants.sampleRate / 1000.0).rounded())
    }

    private func refreshWriteLatencyOffsetIfNeeded(uid: String) {
        guard currentSelectedMicDevice()?.uid == uid else { return }
        let frames = currentEffectiveMicLatencyFrames()
        writeQueue.async { [weak self] in
            self?.effectiveMicAdvanceFrames = frames
        }
    }

    func refreshSystemMicMode() {
        guard #available(macOS 12.0, *) else {
            systemMicMode = .unavailable
            return
        }

        let mode = AVCaptureDevice.activeMicrophoneMode
        switch mode {
        case .standard:
            systemMicMode = .standard
        case .wideSpectrum:
            systemMicMode = .wideSpectrum
        case .voiceIsolation:
            systemMicMode = .voiceIsolation
        @unknown default:
            systemMicMode = .unknown(mode.rawValue)
        }
    }

    func openSystemMicModePicker() {
        guard #available(macOS 12.0, *) else { return }
        AVCaptureDevice.showSystemUserInterface(.microphoneModes)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.refreshSystemMicMode()
        }
    }

    func updateFilePrefix(_ prefix: String) {
        filePrefix = prefix
        UserDefaults.standard.set(prefix, forKey: SettingsKey.filePrefix)
    }

    func updateAutoLiveTranscript(_ enabled: Bool) {
        autoLiveTranscript = enabled
        UserDefaults.standard.set(enabled, forKey: SettingsKey.autoLiveTranscript)
    }

    func setLiveTranscriptEnabled(_ enabled: Bool) async {
        liveTranscriptEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: SettingsKey.liveTranscriptEnabled)
        if enabled {
            await startLiveTranscript()
        } else {
            await stopLiveTranscript()
        }
    }

    func renameRecording(_ recording: RecordingInfo, to newName: String) {
        let sanitized = Self.sanitizeRecordingName(newName)
        let oldURL = recording.url
        let dir = oldURL.deletingLastPathComponent()
        let ext = oldURL.pathExtension

        // Parse existing filename to extract prefix+timestamp portion
        let oldStem = oldURL.deletingPathExtension().lastPathComponent
        let (basePart, _) = Self.parseFilenameParts(oldStem)

        // Build new stem
        var newStem = basePart
        if !sanitized.isEmpty {
            newStem += "_\(sanitized)"
        }

        let newURL = dir.appendingPathComponent(newStem + ".\(ext)")
        guard newURL != oldURL else { return }

        let fm = FileManager.default
        do {
            try fm.moveItem(at: oldURL, to: newURL)
        } catch {
            return
        }

        // Rename associated transcript files (including -1, -2, etc. variants)
        let transcriptExtensions = OutputFormat.allCases.map(\.rawValue)
        for tExt in transcriptExtensions {
            let oldTranscript = dir.appendingPathComponent(oldStem + ".\(tExt)")
            let newTranscript = dir.appendingPathComponent(newStem + ".\(tExt)")
            if fm.fileExists(atPath: oldTranscript.path) {
                try? fm.moveItem(at: oldTranscript, to: newTranscript)
            }
            // Numbered variants: stem-1.txt, stem-2.txt, ...
            var i = 1
            while true {
                let oldNumbered = dir.appendingPathComponent("\(oldStem)-\(i).\(tExt)")
                guard fm.fileExists(atPath: oldNumbered.path) else { break }
                let newNumbered = dir.appendingPathComponent("\(newStem)-\(i).\(tExt)")
                try? fm.moveItem(at: oldNumbered, to: newNumbered)
                i += 1
            }
        }

        // Update entry in recentRecordings
        if let idx = recentRecordings.firstIndex(where: { $0.url == oldURL }) {
            recentRecordings[idx].url = newURL
        }
        if var descriptor = latestFinalizedDescriptor,
           descriptor.recording.url == oldURL {
            descriptor.recording.url = newURL
            if let fingerprint = Self.fingerprint(for: newURL) {
                latestFinalizedDescriptor = FinalizedRecordingDescriptor(
                    recording: descriptor.recording,
                    spans: descriptor.spans,
                    split: descriptor.split,
                    format: descriptor.format,
                    quality: descriptor.quality,
                    micAdvanceFrames: descriptor.micAdvanceFrames,
                    fingerprint: fingerprint
                )
            } else {
                latestFinalizedDescriptor = nil
            }
        }

        addToNameHistory(sanitized)
    }

    private func addToNameHistory(_ name: String) {
        guard !name.isEmpty else { return }
        nameHistory.removeAll { $0.caseInsensitiveCompare(name) == .orderedSame }
        nameHistory.insert(name, at: 0)
        if nameHistory.count > 50 { nameHistory = Array(nameHistory.prefix(50)) }
        UserDefaults.standard.set(nameHistory, forKey: SettingsKey.recordingNameHistory)
    }

    func nameSuggestions(for input: String) -> [String] {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        return Array(nameHistory
            .filter { $0.localizedCaseInsensitiveContains(trimmed) && $0.caseInsensitiveCompare(trimmed) != .orderedSame }
            .prefix(5))
    }

    /// Parses a filename stem into (prefix+timestamp, name) components.
    /// E.g. "ripcord_2024-01-01_12-00-00_episode-42" → ("ripcord_2024-01-01_12-00-00", "episode-42")
    /// E.g. "2024-01-01_12-00-00_meeting" → ("2024-01-01_12-00-00", "meeting")
    static func parseFilenameParts(_ stem: String) -> (base: String, name: String) {
        // Match timestamp pattern: YYYY-MM-DD_HH-MM-SS
        let pattern = #"\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}"#
        guard let range = stem.range(of: pattern, options: .regularExpression) else {
            return (stem, "")
        }
        let tsEnd = range.upperBound
        let base = String(stem[stem.startIndex..<tsEnd])
        // Everything after the timestamp (skip leading underscore)
        let remainder = stem[tsEnd...]
        if remainder.hasPrefix("_") {
            return (base, String(remainder.dropFirst()))
        }
        return (base, "")
    }

    static func sanitizeRecordingName(_ name: String) -> String {
        var s = name.trimmingCharacters(in: .whitespaces)
        s = s.replacingOccurrences(of: " ", with: "-")
        // Strip path-unsafe characters
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        s = String(s.unicodeScalars.filter { allowed.contains($0) })
        if s.count > 80 { s = String(s.prefix(80)) }
        return s
    }

    var bufferFillSeconds: Int {
        max(systemBuffer.frameCount, micBuffer.frameCount) / AudioConstants.sampleRateInt
    }

    private func updateFilledBarCount() {
        filledBarCount = min(100, waveformTracker.committedCount + 1) // +1 for live bar
    }

    func shutdown() {
        logger.error("Shutdown (state: \(String(describing: self.state)))")
        if state == .recording || state == .paused {
            stopRecording()
        }
        writeQueue.sync {
            self.writeTimer?.cancel()
            self.writeTimer = nil
        }
        if nativeMicDebugEnabled {
            micCapture.stopNativeDebugRecording()
        }
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        waveformTimer?.invalidate()
        waveformTimer = nil
        micCapture.stop()
        systemCapture.stop()
    }

    // MARK: - Stereo Packing
    //
    // Inputs `system` and `mic` are stereo-interleaved (2 floats per frame).
    // Outputs are 2-ch stereo-interleaved suitable for AudioFileWriter.
    //
    // - Split mode: each source downmixed to mono; sys → L, mic → R.
    // - Mixed mode: each source's L/R preserved; sum sysL+micL → L, sysR+micR → R.

    private static let ch = CircularAudioBuffer.channelsPerFrame

    /// Split mode: downmix each source to mono, then route sys→L, mic→R.
    static func interleave(_ system: [Float], _ mic: [Float]) -> [Float] {
        let sysFrames = system.count / ch
        let micFrames = mic.count / ch
        let frames = max(sysFrames, micFrames)
        guard frames > 0 else { return [] }
        return [Float](unsafeUninitializedCapacity: frames * 2) { buffer, count in
            for f in 0..<frames {
                let sysMono: Float = f < sysFrames
                    ? (system[f * ch] + system[f * ch + 1]) * 0.5
                    : 0
                let micMono: Float = f < micFrames
                    ? (mic[f * ch] + mic[f * ch + 1]) * 0.5
                    : 0
                buffer[f * 2]     = sysMono  // L
                buffer[f * 2 + 1] = micMono  // R
            }
            count = frames * 2
        }
    }

    /// Mixed mode: preserve stereo per source, sum L+L and R+R per frame.
    static func mixStereo(_ system: [Float], _ mic: [Float]) -> [Float] {
        let sysFrames = system.count / ch
        let micFrames = mic.count / ch
        let frames = max(sysFrames, micFrames)
        guard frames > 0 else { return [] }
        return [Float](unsafeUninitializedCapacity: frames * 2) { buffer, count in
            for f in 0..<frames {
                let sysL: Float = f < sysFrames ? system[f * ch]     : 0
                let sysR: Float = f < sysFrames ? system[f * ch + 1] : 0
                let micL: Float = f < micFrames ? mic[f * ch]        : 0
                let micR: Float = f < micFrames ? mic[f * ch + 1]    : 0
                buffer[f * 2]     = sysL + micL
                buffer[f * 2 + 1] = sysR + micR
            }
            count = frames * 2
        }
    }

    // MARK: - Control Socket

    private func startControlSocket() async {
        let server = TranscriptSocketServer()
        server.commandHandler = { [weak self] jsonLine, respond in
            guard let self else { return }
            Task { await self.handleRemoteCommand(jsonLine, respond: respond) }
        }
        do {
            try server.start()
            transcriptSocketServer = server
        } catch {
            logger.error("Control socket failed: \(error.localizedDescription)")
        }
    }

    private func handleRemoteCommand(
        _ jsonLine: String, respond: @Sendable @escaping (String) -> Void
    ) async {
        guard let data = jsonLine.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cmd = obj["cmd"] as? String else {
            respond("{\"type\":\"error\",\"message\":\"Invalid command\"}")
            return
        }

        switch cmd {
        case "status":
            let stateStr: String
            switch state {
            case .starting: stateStr = "starting"
            case .buffering: stateStr = "buffering"
            case .recording: stateStr = "recording"
            case .paused: stateStr = "paused"
            case .error(let msg): stateStr = "error: \(msg)"
            }
            let status: [String: Any] = [
                "type": "response", "cmd": "status",
                "state": stateStr,
                "liveTranscript": liveTranscriptEnabled,
                "mic": micEnabled,
                "channelSplit": channelSplit,
                "chunkSize": liveTranscriptChunkSize,
                "rightContext": liveTranscriptRightContext,
                "minContext": liveTranscriptMinContext,
                "confirmThreshold": liveTranscriptConfirmThreshold,
                "modelsReady": transcriptionService.modelsReady,
                "clients": transcriptSocketServer?.connectedClientCount ?? 0,
            ]
            if let json = try? JSONSerialization.data(withJSONObject: status),
               let str = String(data: json, encoding: .utf8) {
                respond(str)
            }

        case "start":
            await setLiveTranscriptEnabled(true)
            respond("{\"type\":\"response\",\"cmd\":\"start\",\"ok\":true}")

        case "stop":
            await setLiveTranscriptEnabled(false)
            respond("{\"type\":\"response\",\"cmd\":\"stop\",\"ok\":true}")

        case "configure":
            if let chunk = obj["chunkSize"] as? Double {
                await setLiveTranscriptChunkSize(chunk)
            }
            if let rc = obj["rightContext"] as? Double {
                await setLiveTranscriptRightContext(rc)
            }
            if let mc = obj["minContext"] as? Double {
                await setLiveTranscriptMinContext(mc)
            }
            if let ct = obj["confirmThreshold"] as? Double {
                await setLiveTranscriptConfirmThreshold(ct)
            }
            respond("{\"type\":\"response\",\"cmd\":\"configure\",\"ok\":true,\"chunkSize\":\(liveTranscriptChunkSize),\"rightContext\":\(liveTranscriptRightContext),\"minContext\":\(liveTranscriptMinContext),\"confirmThreshold\":\(liveTranscriptConfirmThreshold)}")

        case "setMic":
            if let enabled = obj["enabled"] as? Bool {
                await setMicEnabled(enabled)
                respond("{\"type\":\"response\",\"cmd\":\"setMic\",\"ok\":true,\"enabled\":\(enabled)}")
            } else {
                respond("{\"type\":\"error\",\"cmd\":\"setMic\",\"message\":\"Missing 'enabled'\"}")
            }

        case "setChannelSplit":
            if let enabled = obj["enabled"] as? Bool {
                updateChannelSplit(enabled)
                respond("{\"type\":\"response\",\"cmd\":\"setChannelSplit\",\"ok\":true,\"enabled\":\(enabled)}")
            } else {
                respond("{\"type\":\"error\",\"cmd\":\"setChannelSplit\",\"message\":\"Missing 'enabled'\"}")
            }

        default:
            respond("{\"type\":\"error\",\"message\":\"Unknown command: \(cmd)\"}")
        }
    }

    // MARK: - Live Transcript

    func startLiveTranscript() async {
        guard liveTranscriptEnabled else { return }
        guard let server = transcriptSocketServer else { return }

        let stream = LiveTranscriptStream(socketServer: server)
        do {
            try await stream.start(
                chunkSeconds: liveTranscriptChunkSize,
                rightContextSeconds: liveTranscriptRightContext,
                minContextForConfirmation: liveTranscriptMinContext,
                confirmationThreshold: liveTranscriptConfirmThreshold
            )
        } catch {
            logger.error("Live transcript start failed: \(error.localizedDescription)")
            if state != .recording && state != .paused {
                state = .error("Live transcript: \(error.localizedDescription)")
            }
            return
        }

        liveTranscriptLock.withLock { liveTranscriptStream = stream }
        liveTranscriptClientCount = server.connectedClientCount

        // Attach app-scoped transcript state to the word stream so turns
        // accumulate regardless of whether the transcript window is open.
        if let wordStream = stream.wordStream {
            await MainActor.run {
                self.transcriptState.clear()
                self.transcriptState.startConsuming(wordStream)
            }
        }
    }

    func stopLiveTranscript() async {
        let stream = liveTranscriptLock.withLock { () -> LiveTranscriptStream? in
            let s = liveTranscriptStream
            liveTranscriptStream = nil
            return s
        }
        await stream?.stop()
        liveTranscriptClientCount = 0
        await MainActor.run { self.transcriptState.stopConsuming() }
    }

    func setLiveTranscriptChunkSize(_ size: Double) async {
        liveTranscriptChunkSize = size
        UserDefaults.standard.set(size, forKey: SettingsKey.liveTranscriptChunkSize)
        await reconfigureLiveTranscript()
    }

    func setLiveTranscriptRightContext(_ value: Double) async {
        liveTranscriptRightContext = value
        UserDefaults.standard.set(value, forKey: SettingsKey.liveTranscriptRightContext)
        await reconfigureLiveTranscript()
    }

    func setLiveTranscriptMinContext(_ value: Double) async {
        liveTranscriptMinContext = value
        UserDefaults.standard.set(value, forKey: SettingsKey.liveTranscriptMinContext)
        await reconfigureLiveTranscript()
    }

    func setLiveTranscriptConfirmThreshold(_ value: Double) async {
        liveTranscriptConfirmThreshold = value
        UserDefaults.standard.set(value, forKey: SettingsKey.liveTranscriptConfirmThreshold)
        await reconfigureLiveTranscript()
    }

    private func reconfigureLiveTranscript() async {
        guard let stream = liveTranscriptLock.withLock({ liveTranscriptStream }) else { return }
        do {
            try await stream.reconfigure(
                chunkSeconds: liveTranscriptChunkSize,
                rightContextSeconds: liveTranscriptRightContext,
                minContextForConfirmation: liveTranscriptMinContext,
                confirmationThreshold: liveTranscriptConfirmThreshold
            )
        } catch {
            logger.error("Live transcript reconfigure failed: \(error.localizedDescription)")
            if state != .recording && state != .paused {
                state = .error("Live transcript reconfigure: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Private

    // Audio always flows to circular buffers (continuous waveform); also to pending when recording.

    private func startAudioProcessingTimer() {
        let timer = DispatchSource.makeTimerSource(queue: audioProcessingQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(10))
        timer.setEventHandler { [weak self] in
            self?.flushAudioHandoffs()
        }
        timer.resume()
        audioProcessingTimer = timer
    }

    private func flushAudioHandoffs() {
        let sysDrain = systemSampleHandoff.drain()
        if sysDrain.droppedSamples > 0 {
            logger.error("System audio handoff dropped \(sysDrain.droppedSamples) samples")
        }
        if !sysDrain.chunks.isEmpty {
            processSystemChunks(sysDrain.chunks)
        }

        let micDrain = micSampleHandoff.drain()
        if micDrain.droppedSamples > 0 {
            logger.error("Mic audio handoff dropped \(micDrain.droppedSamples) samples")
        }
        if !micDrain.chunks.isEmpty {
            processMicChunks(micDrain.chunks)
        }
    }

    private func processSystemChunks(_ chunks: [AudioSampleChunk]) {
        routeChunks(chunks, peakAccum: &systemPeakAccum,
                    pendingArray: &pendingSystemChunks, buffer: systemBuffer)
        for chunk in chunks {
            chunk.samples.withUnsafeBufferPointer { samples in
                liveTranscriptLock.withLock { liveTranscriptStream }?.feedSystemAudio(samples)
            }
        }
    }

    private func processMicChunks(_ chunks: [AudioSampleChunk]) {
        routeChunks(chunks, peakAccum: &micPeakAccum,
                    pendingArray: &pendingMicChunks, buffer: micBuffer)
        for chunk in chunks {
            chunk.samples.withUnsafeBufferPointer { samples in
                liveTranscriptLock.withLock { liveTranscriptStream }?.feedMicAudio(samples)
            }
        }
    }

    private func routeChunks(_ chunks: [AudioSampleChunk], peakAccum: inout Float,
                             pendingArray: inout [AudioSampleChunk], buffer: CircularAudioBuffer) {
        var peak: Float = 0
        for chunk in chunks {
            for sample in chunk.samples {
                let a = abs(sample)
                if a > peak { peak = a }
            }
        }
        meterLock.lock()
        if peak > peakAccum { peakAccum = peak }
        meterLock.unlock()

        waveformTracker.feedPeak(peak)

        for chunk in chunks {
            let nanos = UInt64(max(0, Double(chunk.endFrame) * 1_000_000_000.0
                / AudioConstants.sampleRate))
            let endHostTime = AudioConvertNanosToHostTime(nanos)
            chunk.samples.withUnsafeBufferPointer {
                buffer.write($0, startFrame: chunk.startFrame, endHostTime: endHostTime)
            }
        }

        pendingLock.lock()
        if pendingActive {
            pendingArray.append(contentsOf: chunks)
        }
        pendingLock.unlock()
    }

    /// Called on writeQueue by the write timer — flushes pending samples to disk.
    /// Uses timestamped chunks to avoid aligning sources by queue arrival time.
    private func flushPendingSamples() {
        pendingLock.lock()
        let pendingSys = pendingSystemChunks
        let pendingMic = pendingMicChunks
        let recordingActive = pendingActive
        pendingSystemChunks.removeAll(keepingCapacity: true)
        pendingMicChunks.removeAll(keepingCapacity: true)
        pendingLock.unlock()

        // Compute combined peak amplitude for silence detection.
        var flushPeak: Float = 0
        if !pendingSys.isEmpty || !pendingMic.isEmpty {
            for chunk in pendingSys + pendingMic {
                for s in chunk.samples {
                    let a = abs(s)
                    if a > flushPeak { flushPeak = a }
                }
            }
        }

        let chunkStarts = (pendingSys + pendingMic).map(\.startFrame)
        let chunkEnds = (pendingSys + pendingMic).map(\.endFrame)
        let batchStart = chunkStarts.min()
        let batchEnd = chunkEnds.max()
        var includeBatch = recordingActive && batchEnd != nil

        // Silence auto-pause remains independent from manual Pause, but its
        // excluded source spans are now represented in the same EDL.
        if silenceEnabled, recordingActive {
            if flushPeak < silenceThresholdLocal {
                let sysFrames = pendingSys.reduce(0) { $0 + $1.frameCount }
                let micFrames = pendingMic.reduce(0) { $0 + $1.frameCount }
                silenceSampleCount += max(sysFrames, micFrames)
                if silenceSampleCount >= silenceSampleThreshold {
                    if !silenceDetected {
                        silenceDetected = true
                        DispatchQueue.main.async { [weak self] in
                            self?.isSilencePaused = true
                        }
                    }
                    includeBatch = false
                }
            } else {
                silenceSampleCount = 0
                if silenceDetected {
                    silenceDetected = false
                    if let batchStart {
                        selectionTimelineLock.withLock {
                            selectionTimeline.beginLive(at: batchStart)
                        }
                    }
                    DispatchQueue.main.async { [weak self] in
                        self?.isSilencePaused = false
                    }
                }
            }
        }

        if includeBatch, let batchEnd {
            selectionTimelineLock.withLock {
                if let batchStart {
                    selectionTimeline.rebaseEmptyLive(at: batchStart)
                    if emittedThroughSourceFrame == nil {
                        emittedThroughSourceFrame = batchStart
                    }
                }
                selectionTimeline.extendLive(to: batchEnd)
            }
        } else if recordingActive, silenceDetected, let batchStart {
            selectionTimelineLock.withLock {
                selectionTimeline.closeLive(at: batchStart)
            }
        }

        let visible = currentVisibleCaptureRange()
        selectionTimelineLock.withLock {
            selectionTimeline.advancePaused(to: visible.end)
        }
        let safeCutoff = selectionTimelineLock.withLock {
            waveformDisplayActive ? displayedVisibleStart : visible.start
        }
        commitSelectedTimeline(upTo: safeCutoff)
    }

    /// Append only source-time decisions that have left the visible waveform.
    /// A two-second storage margin keeps those frames readable while this runs.
    private func commitSelectedTimeline(upTo cutoff: CaptureFrame) {
        guard let writer, writeError == nil else { return }
        let snapshot = selectionTimelineLock.withLock {
            (
                selectionTimeline.selectedSlices(
                    from: emittedThroughSourceFrame ?? cutoff,
                    to: cutoff,
                    at: currentVisibleCaptureRange().end
                ),
                emittedThroughSourceFrame
            )
        }
        guard let cursor = snapshot.1, cutoff > cursor else { return }

        do {
            for selected in snapshot.0 {
                try writer.append(samples: packedCaptureRange(selected))
            }
            selectionTimelineLock.withLock {
                emittedThroughSourceFrame = cutoff
            }
        } catch {
            writeError = error
        }
    }

    private func packedCaptureRange(
        _ range: CaptureFrameRange,
        systemSnapshot: AudioBufferSnapshot? = nil,
        micSnapshot: AudioBufferSnapshot? = nil,
        split: Bool? = nil,
        micAdvanceFrames: Int? = nil
    ) -> [Float] {
        guard !range.isEmpty else { return [] }
        let systemSource = systemSnapshot ?? systemBuffer.snapshot(range: range)
        let advance = micAdvanceFrames ?? effectiveMicAdvanceFrames
        let micReadRange = CaptureFrameRange(
            range.start + CaptureFrame(advance),
            range.end + CaptureFrame(advance)
        )
        let rawMic = micSnapshot.map { alignedSnapshot($0, in: micReadRange) }
            ?? micBuffer.snapshot(range: micReadRange)
        let relabeledMic = AudioBufferSnapshot(
            range: CaptureFrameRange(
                rawMic.range.start - CaptureFrame(advance),
                rawMic.range.end - CaptureFrame(advance)
            ),
            samples: rawMic.samples
        )
        let system = alignedSnapshot(systemSource, in: range).samples
        let mic = alignedSnapshot(relabeledMic, in: range).samples
        return (split ?? splitEnabled)
            ? Self.interleave(system, mic)
            : Self.mixStereo(system, mic)
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
        selectionTimelineLock.withLock { waveformDisplayActive = true }

        // Seed immediately from circular buffers
        updateWaveformFromBuffers()

        waveformTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            self?.updateWaveformFromBuffers()
        }
    }

    private func updateWaveformFromBuffers() {
        // Level meters: consume peaks tracked inline in audio callbacks
        let meterPeaks = consumeMeterPeaks()
        systemLevel = max(systemLevel * 0.6, meterPeaks.system)
        micLevel = max(micLevel * 0.6, meterPeaks.mic)

        // Waveform from shared tracker — peaks are already merged across sources
        // and bars commit on a single wall-clock cadence.
        let (peaks, states) = waveformTracker.getBarPeaks()
        waveformAmplitudes = peaks
        waveformBarStates = states
        visibleCaptureRange = currentVisibleCaptureRange()
        selectionTimelineLock.withLock {
            displayedVisibleStart = visibleCaptureRange.start
        }
        if state == .paused {
            selectionTimelineLock.withLock {
                selectionTimeline.advancePaused(to: visibleCaptureRange.end)
                if let edit = selectionTimeline.pauseEdit {
                    pausedSelectionRange = CaptureFrameRange(edit.out, edit.in)
                }
                recordingSelectedRanges = selectionTimeline.selectedRanges(
                    at: visibleCaptureRange.end
                )
            }
        } else if state == .recording {
            recordingSelectedRanges = selectionTimelineLock.withLock {
                selectionTimeline.selectedRanges(at: visibleCaptureRange.end)
            }
        }
        updateFilledBarCount()
    }

    private func currentVisibleCaptureRange() -> CaptureFrameRange {
        let system = systemBuffer.visibleRange
        let mic = micBuffer.visibleRange
        let storageRange: CaptureFrameRange
        switch (
            systemCaptureEnabled ? system : nil,
            micEnabled && micStatus == .active ? mic : nil
        ) {
        case let (.some(a), .some(b)): storageRange = commonRange(a, b)
        case let (.some(a), .none): storageRange = a
        case let (.none, .some(b)): storageRange = b
        case (.none, .none):
            if let system { storageRange = system }
            else if let mic { storageRange = mic }
            else { return CaptureFrameRange(0, 0) }
        }
        let visibleFrames = CaptureFrame(bufferDurationSeconds * AudioConstants.sampleRateInt)
        return CaptureFrameRange(
            max(storageRange.start, storageRange.end - visibleFrames),
            storageRange.end
        )
    }

    private func visibleRange(system: CaptureFrameRange, mic: CaptureFrameRange) -> CaptureFrameRange {
        if system.isEmpty { return mic }
        if mic.isEmpty { return system }
        return commonRange(system, mic)
    }

    private func commonRange(_ a: CaptureFrameRange, _ b: CaptureFrameRange) -> CaptureFrameRange {
        let start = max(a.start, b.start)
        return CaptureFrameRange(start, max(start, min(a.end, b.end)))
    }

    private func alignedSnapshot(_ source: AudioBufferSnapshot, in range: CaptureFrameRange) -> AudioBufferSnapshot {
        let clipped = range.clamped(to: source.range)
        var samples = [Float](repeating: 0, count: range.count * CircularAudioBuffer.channelsPerFrame)
        guard !clipped.isEmpty else { return AudioBufferSnapshot(range: range, samples: samples) }
        let sourceOffset = Int(clipped.start - source.range.start) * CircularAudioBuffer.channelsPerFrame
        let destinationOffset = Int(clipped.start - range.start) * CircularAudioBuffer.channelsPerFrame
        let count = clipped.count * CircularAudioBuffer.channelsPerFrame
        samples[destinationOffset..<(destinationOffset + count)] = source.samples[sourceOffset..<(sourceOffset + count)]
        return AudioBufferSnapshot(range: range, samples: samples)
    }

    func stopWaveformTimer() {
        waveformTimer?.invalidate()
        waveformTimer = nil
        selectionTimelineLock.withLock { waveformDisplayActive = false }
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
            let mode = currentMicChannelMode() ?? .monoDevice
            let gainDB = currentMicGainDB()
            try micCapture.start(deviceID: resolvedID, channelMode: mode, gainDB: gainDB)
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
