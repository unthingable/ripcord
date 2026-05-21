@preconcurrency import AVFoundation
import FluidAudio
import Foundation
import os

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

        // Speaker re-verification: check segment embeddings against speaker profiles
        if let dia = diarizationResult {
            diarizationResult = try await verifySpeakerAssignments(
                dia, fileURL: processURL)
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

        diarizerConfig.embedding.minSegmentDurationSeconds = config.minSegmentDuration ?? 0.5
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

    // MARK: - Speaker Re-Verification

    /// Re-verify diarization speaker assignments by extracting fresh embeddings for each segment
    /// and comparing against speaker profiles built from the longest, highest-confidence segments.
    ///
    /// The offline diarizer's VBx clustering operates globally and can misassign segments,
    /// especially near turn boundaries or during rapid speaker exchanges. This pass extracts
    /// WeSpeaker embeddings at segment granularity and flips assignments where the embedding
    /// clearly matches a different speaker's profile.
    private func verifySpeakerAssignments(
        _ result: DiarizationResult,
        fileURL: URL
    ) async throws -> DiarizationResult {
        let segments = result.segments
        let speakerIds = Array(Set(segments.map(\.speakerId)).sorted())
        guard speakerIds.count >= 2 else { return result }

        let models = try await DiarizerModels.download()
        let diarizerManager = DiarizerManager()
        diarizerManager.initialize(models: models)
        defer { diarizerManager.cleanup() }

        let converter = AudioConverter(sampleRate: 16000)
        let audio16k = try converter.resampleAudioFile(fileURL)

        let minSamples = 8000  // 0.5s minimum for reliable embedding
        let profileMaxSamples = 160_000  // 10s for speaker profiles

        // Step 1: Extract embeddings for all segments that are long enough
        struct SegmentEmbedding {
            let index: Int
            let embedding: [Float]
            let duration: Float
        }

        var segEmbeddings: [SegmentEmbedding] = []
        for (idx, seg) in segments.enumerated() {
            let startSample = max(0, Int(Double(seg.startTimeSeconds) * 16000))
            let endSample = min(audio16k.count, Int(Double(seg.endTimeSeconds) * 16000))
            guard endSample - startSample >= minSamples else { continue }

            let slice = Array(audio16k[startSample..<endSample])
            let embedding = try diarizerManager.extractSpeakerEmbedding(from: slice)
            segEmbeddings.append(SegmentEmbedding(
                index: idx, embedding: embedding, duration: seg.durationSeconds))
        }

        guard segEmbeddings.count >= 2 else { return result }

        // Step 2: Build speaker profiles from the longest segments per speaker
        var profiles: [String: [Float]] = [:]
        for speakerId in speakerIds {
            let speakerSegs = segEmbeddings
                .filter { segments[$0.index].speakerId == speakerId }
                .sorted { $0.duration > $1.duration }
            guard !speakerSegs.isEmpty else { continue }

            // Use top segments up to profileMaxSamples worth of audio
            var totalDuration: Float = 0
            var selectedEmbeddings: [([Float], Float)] = []
            for se in speakerSegs {
                guard totalDuration < Float(profileMaxSamples) / 16000.0 else { break }
                selectedEmbeddings.append((se.embedding, se.duration))
                totalDuration += se.duration
            }

            // Duration-weighted average embedding
            let totalWeight = selectedEmbeddings.reduce(Float(0)) { $0 + $1.1 }
            let dim = selectedEmbeddings[0].0.count
            var centroid = [Float](repeating: 0, count: dim)
            for (emb, dur) in selectedEmbeddings {
                let w = dur / totalWeight
                for i in 0..<dim { centroid[i] += emb[i] * w }
            }
            // L2 normalize
            let norm = sqrt(centroid.reduce(Float(0)) { $0 + $1 * $1 })
            if norm > 0 { centroid = centroid.map { $0 / norm } }
            profiles[speakerId] = centroid
        }

        guard profiles.count >= 2 else { return result }

        // Step 3: Re-verify each segment's assignment
        var corrected = segments
        var flips = 0
        for se in segEmbeddings {
            let seg = segments[se.index]
            let assignedId = seg.speakerId

            // Cosine similarity (embeddings are L2-normalized, so dot product = cosine sim)
            var bestId = assignedId
            var bestSim: Float = -1
            var assignedSim: Float = -1

            for (speakerId, profile) in profiles {
                var sim: Float = 0
                for i in 0..<se.embedding.count {
                    sim += se.embedding[i] * profile[i]
                }
                if speakerId == assignedId { assignedSim = sim }
                if sim > bestSim {
                    bestSim = sim
                    bestId = speakerId
                }
            }

            // Flip if a different speaker is clearly better
            let margin = bestSim - assignedSim
            if bestId != assignedId && margin > 0.20 {
                corrected[se.index] = TimedSpeakerSegment(
                    speakerId: bestId,
                    embedding: seg.embedding,
                    startTimeSeconds: seg.startTimeSeconds,
                    endTimeSeconds: seg.endTimeSeconds,
                    qualityScore: seg.qualityScore)
                flips += 1
            }
        }

        if flips > 0 {
            os_log(.info, "Speaker re-verification: flipped %d/%d segments", flips, segEmbeddings.count)
        }

        return DiarizationResult(
            segments: corrected, speakerDatabase: result.speakerDatabase)
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
