@preconcurrency import AVFoundation
import FluidAudio
import Foundation

public final class Transcriber: @unchecked Sendable {
    private let lock = NSLock()
    private var asrManager: AsrManager?

    public init() {}

    // MARK: - Model Lifecycle

    public static func modelsExistOnDisk(version: ModelVersion) -> Bool {
        let asrVersion: AsrModelVersion = version == .v2 ? .v2 : .v3
        let asrDir = AsrModels.defaultCacheDirectory(for: asrVersion)
        guard AsrModels.modelsExist(at: asrDir, version: asrVersion) else { return false }

        // Check that the offline diarizer models directory exists and is non-empty.
        // The exact model files are managed by FluidAudio internally.
        let diaDir = OfflineDiarizerModels.defaultModelsDirectory()
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: diaDir.path),
              !contents.isEmpty
        else { return false }
        return true
    }

    public func prepareModels(
        version: ModelVersion,
        progress: @Sendable (Double) -> Void = { _ in }
    ) async throws {
        progress(0.1)

        let asrVersion: AsrModelVersion = version == .v2 ? .v2 : .v3
        let asrModels = try await AsrModels.downloadAndLoad(version: asrVersion)
        let asr = AsrManager()
        try await asr.initialize(models: asrModels)

        progress(0.5)

        // Pre-download diarization models so they're available for transcribe calls
        let diarizer = OfflineDiarizerManager()
        try await diarizer.prepareModels()

        progress(1.0)

        lock.withLock { self.asrManager = asr }
    }

    public var isReady: Bool {
        lock.withLock { asrManager != nil }
    }

    // MARK: - Transcription

    public func transcribe(
        fileURL: URL,
        diarization: DiarizationConfig? = DiarizationConfig(),
        startTime: Double? = nil,
        endTime: Double? = nil
    ) async throws -> TranscriptionResult {
        guard let asr = lock.withLock({ asrManager }) else {
            throw TranscriberError.modelsNotReady
        }

        // Pre-process audio (mono mix, normalization, optional trim)
        let (processURL, cleanup) = try AudioPreprocessor.prepareAudio(
            from: fileURL, startTime: startTime, endTime: endTime)
        defer { cleanup() }

        let audioDuration = AudioPreprocessor.getAudioDuration(processURL)

        // ASR
        let asrResult = try await asr.transcribe(processURL)
        let duration = asrResult.duration > 0 ? asrResult.duration : audioDuration

        // Diarization
        var diarizationResult: DiarizationResult?
        if let config = diarization {
            var diarizerConfig = OfflineDiarizerConfig()

            switch config.speakerCount {
            case .auto:
                break
            case .exactly(let n):
                diarizerConfig = diarizerConfig.withSpeakers(exactly: n)
            case .range(let min, let max):
                diarizerConfig = diarizerConfig.withSpeakers(min: min, max: max)
            }

            // FluidAudio defaults to clustering threshold 0.6, which is too
            // conservative and fragments speakers. Match pyannote's optimized ~0.7.
            diarizerConfig.clustering.threshold = config.clusteringThreshold ?? 0.75
            if let t = config.speechThreshold {
                diarizerConfig.segmentation.speechOnsetThreshold = t
                diarizerConfig.segmentation.speechOffsetThreshold = t
            }

            switch config.quality {
            case .balanced:
                diarizerConfig.segmentation.stepRatio = 0.05
            case .fast:
                break
            }

            // FluidAudio defaults to 1.0s minimum segment duration, which discards
            // brief but real speaker turns at boundaries, shifting them by up to ~1s.
            // Use a much lower threshold to preserve boundary precision.
            diarizerConfig.embedding.minSegmentDurationSeconds = config.minSegmentDuration ?? 0.1
            if let g = config.minGapDuration {
                diarizerConfig.postProcessing.minGapDurationSeconds = g
            }

            let diarizer = OfflineDiarizerManager(config: diarizerConfig)
            try await diarizer.prepareModels()
            diarizationResult = try await diarizer.process(processURL)
        }

        // Merge
        let removeFillers = diarization?.removeFillerWords ?? false
        var segments = mergeResults(
            asrResult: asrResult,
            diarizationResult: diarizationResult,
            removeFillerWords: removeFillers)

        // Offset timestamps back to original file positions
        let offset = startTime ?? 0
        if offset > 0 {
            segments = segments.map {
                TranscriptSegment(start: $0.start + offset, end: $0.end + offset,
                                  text: $0.text, speaker: $0.speaker)
            }
        }

        let speakers: [String]
        if let dia = diarizationResult {
            speakers = Set(dia.segments.map(\.speakerId)).sorted()
        } else {
            speakers = []
        }

        return TranscriptionResult(segments: segments, duration: duration, speakers: speakers)
    }

    public func cleanup() {
        let asr = lock.withLock { () -> AsrManager? in
            let a = asrManager
            asrManager = nil
            return a
        }
        asr?.cleanup()
    }

    // MARK: - Errors

    public enum TranscriberError: Error, LocalizedError {
        case modelsNotReady

        public var errorDescription: String? {
            switch self {
            case .modelsNotReady: return "Transcription models not loaded"
            }
        }
    }
}
