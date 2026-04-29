@preconcurrency import AVFoundation
import FluidAudio
import Foundation

public final class Transcriber: @unchecked Sendable {
    private let lock = NSLock()
    private var asrManager: AsrManager?

    public init() {}

    // MARK: - Model Lifecycle

    public static func modelsExistOnDisk(version: ModelVersion, engine: DiarizationEngine = .offline) -> Bool {
        let asrVersion: AsrModelVersion = version == .v2 ? .v2 : .v3
        let asrDir = AsrModels.defaultCacheDirectory(for: asrVersion)
        guard AsrModels.modelsExist(at: asrDir, version: asrVersion) else { return false }

        switch engine {
        case .offline:
            let diaDir = OfflineDiarizerModels.defaultModelsDirectory()
            guard let contents = try? FileManager.default.contentsOfDirectory(atPath: diaDir.path),
                  !contents.isEmpty
            else { return false }
            return true
        case .lseend:
            let modelsDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("FluidAudio/Models")
                .appendingPathComponent(Repo.lseend.folderName)
            let variant = LSEENDVariant.dihard3
            return FileManager.default.fileExists(atPath: modelsDir.appendingPathComponent(variant.modelFile).path)
                && FileManager.default.fileExists(atPath: modelsDir.appendingPathComponent(variant.configFile).path)
        case .sortformer:
            let modelsDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("FluidAudio/Models")
                .appendingPathComponent(Repo.sortformer.folderName)
            return FileManager.default.fileExists(atPath: modelsDir.path)
        }
    }

    public func prepareModels(
        version: ModelVersion,
        engine: DiarizationEngine = .offline,
        progress: @Sendable (Double) -> Void = { _ in }
    ) async throws {
        progress(0.1)

        let asrVersion: AsrModelVersion = version == .v2 ? .v2 : .v3
        let asrModels = try await AsrModels.downloadAndLoad(version: asrVersion)
        let asr = AsrManager()
        try await asr.initialize(models: asrModels)

        progress(0.5)

        switch engine {
        case .offline:
            let diarizer = OfflineDiarizerManager()
            try await diarizer.prepareModels()
        case .lseend:
            _ = try await LSEENDModelDescriptor.loadFromHuggingFace(variant: .dihard3)
            _ = try await DiarizerModels.download()
        case .sortformer:
            _ = try await SortformerModels.loadFromHuggingFace(config: .default)
            _ = try await DiarizerModels.download()
        }

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
        let (processURL, cleanup) = try await AudioPreprocessor.prepareAudio(
            from: fileURL, startTime: startTime, endTime: endTime)
        defer { cleanup() }

        let audioDuration = await AudioPreprocessor.getAudioDuration(processURL)
        try Task.checkCancellation()

        // ASR
        let asrResult = try await asr.transcribe(processURL)
        let duration = asrResult.duration > 0 ? asrResult.duration : audioDuration

        try Task.checkCancellation()

        // Diarization
        var diarizationResult: DiarizationResult?
        if let config = diarization {
            switch config.engine {
            case .offline:
                diarizationResult = try await diarizeOffline(fileURL: processURL, config: config)
            case .lseend:
                diarizationResult = try await diarizeWithLSEEND(fileURL: processURL)
            case .sortformer:
                diarizationResult = try await diarizeWithSortformer(fileURL: processURL)
            }
        }

        try Task.checkCancellation()

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

        return TranscriptionResult(segments: segments, duration: duration, speakers: speakers, speakerEmbeddings: diarizationResult?.speakerDatabase)
    }

    public func cleanup() async {
        let asr = lock.withLock { () -> AsrManager? in
            let a = asrManager
            asrManager = nil
            return a
        }
        await asr?.cleanup()
    }

    // MARK: - Diarization Engines

    private func diarizeWithLSEEND(fileURL: URL) async throws -> DiarizationResult {
        let descriptor = try await LSEENDModelDescriptor.loadFromHuggingFace(variant: .dihard3)
        let diarizer = LSEENDDiarizer(computeUnits: .cpuOnly)
        try diarizer.initialize(descriptor: descriptor)
        let timeline = try diarizer.processComplete(audioFileURL: fileURL)

        // Extract speaker embeddings using the WeSpeaker model for identification
        let speakerDB = try await extractSpeakerEmbeddings(
            from: fileURL, timeline: timeline)

        return timelineToDiarizationResult(timeline, speakerDatabase: speakerDB)
    }

    private func diarizeOffline(fileURL: URL, config: DiarizationConfig) async throws -> DiarizationResult {
        var diarizerConfig = OfflineDiarizerConfig()

        switch config.speakerCount {
        case .auto:
            break
        case .exactly(let n):
            diarizerConfig = diarizerConfig.withSpeakers(exactly: n)
        case .range(let min, let max):
            diarizerConfig = diarizerConfig.withSpeakers(min: min, max: max)
        }

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

        diarizerConfig.embedding.minSegmentDurationSeconds = config.minSegmentDuration ?? 0.1
        if let g = config.minGapDuration {
            diarizerConfig.postProcessing.minGapDurationSeconds = g
        }

        let diarizer = OfflineDiarizerManager(config: diarizerConfig)
        try await diarizer.prepareModels()
        return try await diarizer.process(fileURL)
    }

    private func diarizeWithSortformer(fileURL: URL) async throws -> DiarizationResult {
        let models = try await SortformerModels.loadFromHuggingFace(config: .default)
        let diarizer = SortformerDiarizer()
        diarizer.initialize(models: models)

        let converter = AudioConverter(sampleRate: 16000)
        let audio = try converter.resampleAudioFile(fileURL)
        let timeline = try diarizer.processComplete(audio, sourceSampleRate: 16000)

        let speakerDB = try await extractSpeakerEmbeddings(
            from: fileURL, timeline: timeline)

        return timelineToDiarizationResult(timeline, speakerDatabase: speakerDB)
    }

    /// Convert LS-EEND DiarizerTimeline to the DiarizationResult format consumed by the merge pipeline.
    private func timelineToDiarizationResult(
        _ timeline: DiarizerTimeline,
        speakerDatabase: [String: [Float]]? = nil
    ) -> DiarizationResult {
        var segments: [TimedSpeakerSegment] = []
        for (_, speaker) in timeline.speakers {
            let speakerId = speaker.name ?? "SPEAKER_\(speaker.index)"
            for seg in speaker.finalizedSegments {
                segments.append(TimedSpeakerSegment(
                    speakerId: speakerId,
                    embedding: [],
                    startTimeSeconds: seg.startTime,
                    endTimeSeconds: seg.endTime,
                    qualityScore: seg.confidence))
            }
        }
        segments.sort { $0.startTimeSeconds < $1.startTimeSeconds }
        return DiarizationResult(segments: segments, speakerDatabase: speakerDatabase)
    }

    /// Extract 256-dim WeSpeaker embeddings for each speaker using LS-EEND segments.
    ///
    /// For each speaker, collects their longest segments (up to 10s of audio),
    /// loads the corresponding audio, and runs the WeSpeaker embedding model.
    private func extractSpeakerEmbeddings(
        from fileURL: URL,
        timeline: DiarizerTimeline
    ) async throws -> [String: [Float]] {
        let models = try await DiarizerModels.download()
        let diarizerManager = DiarizerManager()
        diarizerManager.initialize(models: models)

        let converter = AudioConverter(sampleRate: 16000)
        let audio16k = try converter.resampleAudioFile(fileURL)

        var speakerDB: [String: [Float]] = [:]
        let maxSamples = 160_000  // 10s at 16kHz — model's input window

        for (_, speaker) in timeline.speakers {
            let speakerId = speaker.name ?? "SPEAKER_\(speaker.index)"
            let segments = speaker.finalizedSegments.sorted { $0.duration > $1.duration }
            guard !segments.isEmpty else { continue }

            // Collect audio from longest segments up to 10s
            var collected: [Float] = []
            for seg in segments {
                guard collected.count < maxSamples else { break }
                let startSample = max(0, Int(seg.startTime * 16000))
                let endSample = min(audio16k.count, Int(seg.endTime * 16000))
                guard endSample > startSample else { continue }
                let remaining = maxSamples - collected.count
                let take = min(endSample - startSample, remaining)
                collected.append(contentsOf: audio16k[startSample..<(startSample + take)])
            }

            guard collected.count >= 8000 else { continue } // need at least 0.5s

            let embedding = try diarizerManager.extractSpeakerEmbedding(from: collected)
            speakerDB[speakerId] = embedding
        }

        diarizerManager.cleanup()
        return speakerDB
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
