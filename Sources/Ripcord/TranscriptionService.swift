import Foundation
import Observation
import TranscribeKit

enum TranscriptionState: Equatable {
    case idle
    case loadingModels
    case downloadingModels(Double)
    case ready
    case transcribing
    case failed(String)
}

struct UnmatchedSpeaker: Identifiable, Codable {
    let id: String   // raw diarization ID (e.g. "SPEAKER_0")
    let embedding: [Float]
    var name: String = ""
}

/// Lightweight segment timing for audio preview (no text needed).
private struct SegmentTiming: Codable {
    let start: Double
    let end: Double
    let speaker: String?
}

/// On-disk representation of pending speaker naming for a recording.
private struct PendingSpeakers: Codable {
    let audioFile: String  // filename only, for portability
    let transcriptExtension: String
    let transcriptFile: String?  // actual transcript filename including version suffix (e.g. "recording-1.txt")
    let speakers: [UnmatchedSpeaker]
    let segments: [SegmentTiming]
}

@Observable
final class TranscriptionService: @unchecked Sendable {
    var state: TranscriptionState = .idle
    var transcribingURL: URL?
    var transcriptionPhase: TranscriptionPhase?
    var transcriptionProgress: Double?
    var transcriptionStartedAt: Date?

    /// Unmatched speakers from the most recent transcription, keyed by audio file URL.
    var unmatchedSpeakers: [URL: [UnmatchedSpeaker]] = [:]

    /// Stored so we can re-format after naming.
    private var lastResults: [URL: (result: TranscriptionResult, config: TranscriptionConfig, mapping: [String: String], transcriptURL: URL)] = [:]

    /// Transcript URL loaded from sidecar files (for post-restart speaker naming).
    private var lastTranscriptURLs: [URL: URL] = [:]

    /// Segment timings loaded from sidecar files (for audio preview after restart).
    private var loadedSegments: [URL: [SegmentTiming]] = [:]

    /// Tracks which segment indices have been played per (file, speaker) to cycle through variety.
    private var playedSegmentIndices: [URL: [String: Set<Int>]] = [:]

    var modelsReady: Bool { state == .ready }
    var modelsLoaded: Bool { state == .ready || state == .transcribing }
    var isTranscribing: Bool { state == .transcribing }
    /// Most recent transcription error, cleared on next transcription attempt.
    var lastTranscriptionError: String?

    var speakerProfileStore: SpeakerProfileStore?

    private var transcriber = Transcriber()
    private var transcriptionTask: Task<Void, Never>?
    private let transcriptionOperationLock = NSLock()
    private var activeTranscriptionID: UUID?

    // MARK: - Model Lifecycle

    func prepareModels(config: TranscriptionConfig, fromCache: Bool = false) async {
        guard state == .idle || isFailedState || state == .ready else { return }

        await MainActor.run { state = fromCache ? .loadingModels : .downloadingModels(0) }

        do {
            try await transcriber.prepareModels(version: config.asrModelVersion, engine: config.diarizationEngine) { [weak self] progress in
                if !fromCache {
                    Task { @MainActor in
                        self?.state = .downloadingModels(progress)
                    }
                }
            }

            await MainActor.run {
                self.state = .ready
            }
        } catch {
            await MainActor.run {
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    private var isFailedState: Bool { if case .failed = state { true } else { false } }

    /// Check whether model files exist on disk (no download, no loading).
    static func modelsExistOnDisk(config: TranscriptionConfig) -> Bool {
        Transcriber.modelsExistOnDisk(version: config.asrModelVersion, engine: config.diarizationEngine)
    }

    // MARK: - Transcription Pipeline

    func startTranscription(fileURL: URL, config: TranscriptionConfig, overwrite: Bool = false) {
        let operationID = UUID()
        let previousTask = transcriptionOperationLock.withLock { () -> Task<Void, Never>? in
            let task = transcriptionTask
            transcriptionTask = nil
            activeTranscriptionID = operationID
            return task
        }
        previousTask?.cancel()

        let task = Task { [weak self] in
            guard let self else { return }
            await previousTask?.value
            guard !Task.isCancelled else { return }
            await self.updateCurrentOperation(operationID) {
                if self.state == .transcribing {
                    self.state = .ready
                    self.transcribingURL = nil
                }
                self.lastTranscriptionError = nil
            }
            do {
                _ = try await self.transcribe(
                    fileURL: fileURL, config: config, overwrite: overwrite, operationID: operationID)
            } catch is CancellationError {
                // Cancelled — no error to show
            } catch {
                await self.updateCurrentOperation(operationID) {
                    self.lastTranscriptionError = error.localizedDescription
                    self.state = .ready
                    self.transcribingURL = nil
                    self.transcriptionPhase = nil
                    self.transcriptionProgress = nil
                    self.transcriptionStartedAt = nil
                }
            }
            self.clearOperationIfCurrent(operationID)
        }
        transcriptionOperationLock.withLock {
            guard activeTranscriptionID == operationID else {
                task.cancel()
                return
            }
            transcriptionTask = task
        }
    }

    @MainActor
    func cancelTranscription() {
        let task = transcriptionOperationLock.withLock { () -> Task<Void, Never>? in
            let task = transcriptionTask
            transcriptionTask = nil
            activeTranscriptionID = nil
            return task
        }
        task?.cancel()
        state = .ready
        transcribingURL = nil
        transcriptionPhase = nil
        transcriptionProgress = nil
        transcriptionStartedAt = nil
    }

    private func transcribe(
        fileURL: URL,
        config: TranscriptionConfig,
        overwrite: Bool = false,
        operationID: UUID
    ) async throws -> URL {
        try ensureCurrentOperation(operationID)
        guard modelsReady, transcriber.isReady else {
            throw TranscriptionError.modelsNotReady
        }

        await updateCurrentOperation(operationID) {
            self.state = .transcribing
            self.transcribingURL = fileURL
            self.transcriptionPhase = .preparing
            self.transcriptionProgress = nil
            self.transcriptionStartedAt = Date()
        }

        do {
            // Map Ripcord's TranscriptionConfig to TranscribeKit's DiarizationConfig
            let diarization: DiarizationConfig?
            if config.diarizationEnabled {
                let speakerCount: SpeakerCount
                if config.expectedSpeakerCount > 0 {
                    speakerCount = .exactly(config.expectedSpeakerCount)
                } else {
                    speakerCount = .auto
                }
                diarization = DiarizationConfig(
                    engine: config.diarizationEngine,
                    quality: config.diarizationQuality,
                    clusteringThreshold: Double(config.speakerSensitivity.clusteringThreshold),
                    speakerCount: speakerCount,
                    speechThreshold: Float(config.speechThreshold),
                    minSegmentDuration: config.minSegmentDuration,
                    minGapDuration: config.minGapDuration,
                    removeFillerWords: config.removeFillerWords
                )
            } else {
                diarization = nil
            }

            let result = try await transcriber.transcribe(
                fileURL: fileURL, diarization: diarization
            ) { [weak self] phase, progress in
                Task { @MainActor in
                    guard let self, self.isCurrentOperation(operationID) else { return }
                    self.transcriptionPhase = phase
                    self.transcriptionProgress = progress
                }
            }
            try ensureCurrentOperation(operationID)

            // Speaker matching against stored profiles
            var segments = result.segments
            var speakerMapping: [String: String] = [:]

            // Compute transcript URL before speaker matching so it can be stored
            // with unmatched speakers (needed to apply labels to the correct file)
            let format = config.transcriptFormat
            let baseTranscriptURL = fileURL.deletingPathExtension().appendingPathExtension(format.rawValue)
            let transcriptURL = overwrite ? baseTranscriptURL : uniqueFileURL(for: baseTranscriptURL)

            if let embeddings = result.speakerEmbeddings, !embeddings.isEmpty,
               let store = speakerProfileStore {
                let matchResult = SpeakerMatcher.match(
                    embeddings: embeddings, profiles: store.profiles)

                for (rawID, profile) in matchResult.matched {
                    speakerMapping[rawID] = profile.name
                }

                segments = SpeakerMatcher.remapSegments(segments, mapping: speakerMapping)

                // All speakers go to confirmation UI — matched ones pre-filled
                let allSpeakers = embeddings.map { (rawID, embedding) in
                    var speaker = UnmatchedSpeaker(id: rawID, embedding: embedding)
                    if let profile = matchResult.matched[rawID] {
                        speaker.name = profile.name
                    }
                    return speaker
                }.sorted { $0.id < $1.id }

                await updateCurrentOperation(operationID) {
                    self.unmatchedSpeakers[fileURL] = allSpeakers
                    self.lastResults[fileURL] = (result, config, speakerMapping, transcriptURL)
                }

                try performIfCurrentOperation(operationID) {
                    self.writePendingSpeakers(allSpeakers, for: fileURL,
                                              format: format, result: result,
                                              transcriptURL: transcriptURL)
                }
            }

            let metadata = TranscriptMetadata(
                duration: result.duration,
                speakers: result.speakers,
                sourceFile: fileURL.path,
                configSummary: Self.configSummary(config))
            let formatted = formatOutput(
                segments: segments, metadata: metadata, format: format)
            try performIfCurrentOperation(operationID) {
                try formatted.write(to: transcriptURL, atomically: true, encoding: .utf8)
            }

            await updateCurrentOperation(operationID) {
                self.state = .ready; self.transcribingURL = nil
                self.transcriptionPhase = nil
                self.transcriptionProgress = nil
                self.transcriptionStartedAt = nil
            }
            return transcriptURL
        } catch {
            await updateCurrentOperation(operationID) {
                self.state = .ready; self.transcribingURL = nil
            }
            throw error
        }
    }

    private func isCurrentOperation(_ operationID: UUID) -> Bool {
        transcriptionOperationLock.withLock { activeTranscriptionID == operationID }
    }

    private func ensureCurrentOperation(_ operationID: UUID) throws {
        try Task.checkCancellation()
        guard isCurrentOperation(operationID) else { throw CancellationError() }
    }

    private func clearOperationIfCurrent(_ operationID: UUID) {
        transcriptionOperationLock.withLock {
            guard activeTranscriptionID == operationID else { return }
            activeTranscriptionID = nil
            transcriptionTask = nil
        }
    }

    private func performIfCurrentOperation<T>(
        _ operationID: UUID,
        _ operation: () throws -> T
    ) throws -> T {
        try transcriptionOperationLock.withLock {
            guard activeTranscriptionID == operationID else { throw CancellationError() }
            return try operation()
        }
    }

    private func updateCurrentOperation(
        _ operationID: UUID,
        _ update: @escaping @MainActor () -> Void
    ) async {
        await MainActor.run {
            guard self.isCurrentOperation(operationID) else { return }
            update()
        }
    }

    // MARK: - Speaker Naming

    /// Save named speakers and re-write the transcript with all names applied.
    func saveNewSpeakerProfiles(for fileURL: URL) {
        guard let store = speakerProfileStore,
              let unmatched = unmatchedSpeakers[fileURL] else { return }

        // Group named speakers by name — multiple raw IDs with the same name
        // are merged into a single profile (handles diarizer oversplitting)
        var nameGroups: [String: [(id: String, embedding: [Float])]] = [:]
        for speaker in unmatched {
            let name = speaker.name.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            nameGroups[name, default: []].append((speaker.id, speaker.embedding))
        }

        var newMapping: [String: String] = [:]
        for (name, speakers) in nameGroups {
            // Average embeddings and L2-normalize
            let dim = speakers[0].embedding.count
            var averaged = [Float](repeating: 0, count: dim)
            for s in speakers {
                for i in 0..<dim { averaged[i] += s.embedding[i] }
            }
            let count = Float(speakers.count)
            for i in 0..<dim { averaged[i] /= count }
            averaged = SpeakerMatcher.l2Normalize(averaged)

            // Check if a profile with this name already exists — update it instead
            if let existing = store.profiles.first(where: { $0.name == name }) {
                store.updateEmbedding(id: existing.id, newEmbedding: averaged)
            } else {
                let profile = SpeakerProfile(
                    name: name, embedding: averaged, observationCount: speakers.count)
                store.addProfile(profile)
            }
            for s in speakers { newMapping[s.id] = name }
        }

        // Re-write transcript: prefer full re-format if we have the result in memory,
        // otherwise fall back to string replacement in the existing file
        if let saved = lastResults[fileURL] {
            var fullMapping = saved.mapping
            for (k, v) in newMapping { fullMapping[k] = v }
            let segments = SpeakerMatcher.remapSegments(saved.result.segments, mapping: fullMapping)
            let metadata = TranscriptMetadata(
                duration: saved.result.duration,
                speakers: saved.result.speakers,
                sourceFile: fileURL.path,
                configSummary: Self.configSummary(saved.config))
            let formatted = formatOutput(
                segments: segments, metadata: metadata, format: saved.config.transcriptFormat)
            try? formatted.write(to: saved.transcriptURL, atomically: true, encoding: .utf8)
        } else if !newMapping.isEmpty {
            replaceInTranscriptFiles(for: fileURL, mapping: newMapping,
                                     transcriptURL: lastTranscriptURLs[fileURL])
        }

        // Clear state and remove sidecar
        unmatchedSpeakers.removeValue(forKey: fileURL)
        lastResults.removeValue(forKey: fileURL)
        lastTranscriptURLs.removeValue(forKey: fileURL)
        loadedSegments.removeValue(forKey: fileURL)
        removePendingSpeakersFile(for: fileURL)
    }

    /// Returns a segment time range for a given raw speaker ID, for audio preview.
    /// Picks randomly from the top 3 longest segments, offset to avoid boundary bleed.
    func randomSegmentRange(for speakerID: String, fileURL: URL) -> (start: Double, end: Double)? {
        // Use in-memory results if available, otherwise fall back to loaded sidecar data.
        // When in-memory results exist, prefer segments with enough speech content,
        // but fall back to any segment so the play button always works.
        let allSegments: [(start: Double, end: Double)]
        if let saved = lastResults[fileURL] {
            let speakerSegments = saved.result.segments
                .filter { $0.speaker == speakerID }
                .map { ($0.start, $0.end) }
            let preferred = saved.result.segments
                .filter { $0.speaker == speakerID }
                .filter { seg in
                    let duration = seg.end - seg.start
                    guard duration >= 2.0 else { return false }
                    let wordCount = seg.text.split(separator: " ").count
                    return wordCount >= 3
                }
                .map { ($0.start, $0.end) }
            allSegments = preferred.isEmpty ? speakerSegments : preferred
        } else if let loaded = loadedSegments[fileURL] {
            let matching = loaded.filter { $0.speaker == speakerID }
            let preferred = matching
                .filter { ($0.end - $0.start) >= 2.0 }
                .map { ($0.start, $0.end) }
            let all = matching.map { ($0.start, $0.end) }
            allSegments = preferred.isEmpty ? all : preferred
        } else {
            return nil
        }

        guard !allSegments.isEmpty else { return nil }

        // Cycle through segments — avoid repeating until all have been played
        var played = playedSegmentIndices[fileURL]?[speakerID] ?? []
        if played.count >= allSegments.count {
            played = []
        }
        let unplayed = allSegments.indices.filter { !played.contains($0) }
        guard let idx = unplayed.randomElement() else { return nil }
        playedSegmentIndices[fileURL, default: [:]][speakerID, default: []].insert(idx)

        let seg = allSegments[idx]
        let segDuration = seg.end - seg.start
        // Skip into the segment to avoid previous speaker's tail
        let skipAmount = min(1.0, segDuration * 0.2)
        let start = seg.start + skipAmount
        // Cap playback at 5 seconds
        let end = min(seg.end, start + 5.0)
        guard end > start else { return (seg.start, min(seg.end, seg.start + 5.0)) }
        return (start, end)
    }

    /// Dismiss unmatched speakers without naming them.
    func skipNaming(for fileURL: URL) {
        unmatchedSpeakers.removeValue(forKey: fileURL)
        lastResults.removeValue(forKey: fileURL)
        lastTranscriptURLs.removeValue(forKey: fileURL)
        loadedSegments.removeValue(forKey: fileURL)
        removePendingSpeakersFile(for: fileURL)
    }

    // MARK: - Pending Speakers Persistence

    private static let pendingSuffix = ".pending-speakers.json"

    /// Load any pending speaker naming state from sidecar files on disk.
    func loadPendingSpeakers(in directory: URL) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: nil, options: .skipsHiddenFiles) else { return }

        for file in files where file.lastPathComponent.hasSuffix(Self.pendingSuffix) {
            guard let data = try? Data(contentsOf: file),
                  let pending = try? JSONDecoder().decode(PendingSpeakers.self, from: data) else { continue }
            let audioURL = directory.appendingPathComponent(pending.audioFile)
            guard fm.fileExists(atPath: audioURL.path) else {
                try? fm.removeItem(at: file)  // orphaned sidecar
                continue
            }
            unmatchedSpeakers[audioURL] = pending.speakers
            if let transcriptFile = pending.transcriptFile {
                lastTranscriptURLs[audioURL] = directory.appendingPathComponent(transcriptFile)
            }
            if !pending.segments.isEmpty {
                loadedSegments[audioURL] = pending.segments
            }
        }
    }

    private func writePendingSpeakers(_ speakers: [UnmatchedSpeaker], for fileURL: URL,
                                      format: OutputFormat, result: TranscriptionResult,
                                      transcriptURL: URL) {
        let timings = result.segments.map {
            SegmentTiming(start: $0.start, end: $0.end, speaker: $0.speaker)
        }
        let pending = PendingSpeakers(
            audioFile: fileURL.lastPathComponent,
            transcriptExtension: format.rawValue,
            transcriptFile: transcriptURL.lastPathComponent,
            speakers: speakers,
            segments: timings)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(pending) else { return }
        let sidecarURL = pendingSpeakersURL(for: fileURL)
        try? data.write(to: sidecarURL, options: .atomic)
    }

    private func removePendingSpeakersFile(for fileURL: URL) {
        try? FileManager.default.removeItem(at: pendingSpeakersURL(for: fileURL))
    }

    private func pendingSpeakersURL(for fileURL: URL) -> URL {
        let dir = fileURL.deletingLastPathComponent()
        let stem = fileURL.deletingPathExtension().lastPathComponent
        return dir.appendingPathComponent(stem + Self.pendingSuffix)
    }

    /// String-replace raw speaker IDs in transcript files (used post-restart when
    /// the full TranscriptionResult is no longer in memory).
    private func replaceInTranscriptFiles(for fileURL: URL, mapping: [String: String],
                                          transcriptURL: URL? = nil) {
        var urls: [URL]
        if let url = transcriptURL {
            urls = [url]
        } else {
            let base = fileURL.deletingPathExtension()
            urls = OutputFormat.allCases.map { base.appendingPathExtension($0.rawValue) }
        }
        for url in urls {
            guard var content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for (rawID, name) in mapping {
                content = content.replacingOccurrences(of: rawID, with: name)
            }
            try? content.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Config Summary

    private static func configSummary(_ config: TranscriptionConfig) -> String {
        var parts = ["whisper-\(config.asrModelVersion.rawValue)"]
        if config.diarizationEnabled {
            let engine: String
            switch config.diarizationEngine {
            case .offline: engine = "pyannote"
            case .lseend: engine = "ls-eend"
            case .sortformer: engine = "sortformer"
            }
            parts.append("\(engine) \(config.diarizationQuality.rawValue)")
            let speakers = config.expectedSpeakerCount > 0 ? "\(config.expectedSpeakerCount)" : "auto"
            parts.append("speakers: \(speakers)")
            parts.append("sensitivity: \(config.speakerSensitivity.rawValue)")
            parts.append("speech: \(config.speechThreshold)")
            parts.append("min-seg: \(config.minSegmentDuration)s")
            parts.append("min-gap: \(config.minGapDuration)s")
            if config.removeFillerWords { parts.append("fillers removed") }
        } else {
            parts.append("no diarization")
        }
        return parts.joined(separator: " | ")
    }

    // MARK: - Errors

    enum TranscriptionError: Error, LocalizedError {
        case modelsNotReady

        var errorDescription: String? {
            switch self {
            case .modelsNotReady: return "Transcription models not loaded"
            }
        }
    }
}
