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
    let speakers: [UnmatchedSpeaker]
    let segments: [SegmentTiming]
}

@Observable
final class TranscriptionService: @unchecked Sendable {
    var state: TranscriptionState = .idle
    var transcribingURL: URL?

    /// Unmatched speakers from the most recent transcription, keyed by audio file URL.
    var unmatchedSpeakers: [URL: [UnmatchedSpeaker]] = [:]

    /// Stored so we can re-format after naming.
    private var lastResults: [URL: (result: TranscriptionResult, config: TranscriptionConfig, mapping: [String: String])] = [:]

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

    // MARK: - Model Lifecycle

    func prepareModels(config: TranscriptionConfig, fromCache: Bool = false) async {
        guard state == .idle || isFailedState || state == .ready else { return }

        await MainActor.run { state = fromCache ? .loadingModels : .downloadingModels(0) }

        do {
            try await transcriber.prepareModels(version: config.asrModelVersion) { [weak self] progress in
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
        Transcriber.modelsExistOnDisk(version: config.asrModelVersion)
    }

    // MARK: - Transcription Pipeline

    func startTranscription(fileURL: URL, config: TranscriptionConfig, overwrite: Bool = false) {
        transcriptionTask?.cancel()
        transcriptionTask = Task {
            await MainActor.run { lastTranscriptionError = nil }
            do {
                _ = try await self.transcribe(fileURL: fileURL, config: config, overwrite: overwrite)
            } catch is CancellationError {
                // Cancelled — no error to show
            } catch {
                await MainActor.run {
                    lastTranscriptionError = error.localizedDescription
                    state = .ready
                    transcribingURL = nil
                }
            }
            self.transcriptionTask = nil
        }
    }

    @MainActor
    func cancelTranscription() {
        transcriptionTask?.cancel()
        transcriptionTask = nil
        state = .ready
        transcribingURL = nil
    }

    private func transcribe(fileURL: URL, config: TranscriptionConfig, overwrite: Bool = false) async throws -> URL {
        guard modelsReady, transcriber.isReady else {
            throw TranscriptionError.modelsNotReady
        }

        await MainActor.run {
            state = .transcribing
            transcribingURL = fileURL
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
                fileURL: fileURL, diarization: diarization)

            // Speaker matching against stored profiles
            var segments = result.segments
            var speakerMapping: [String: String] = [:]

            if let embeddings = result.speakerEmbeddings, !embeddings.isEmpty,
               let store = speakerProfileStore {
                let matchResult = SpeakerMatcher.match(
                    embeddings: embeddings, profiles: store.profiles)

                // Build mapping from matched profiles and update their embeddings
                for (rawID, profile) in matchResult.matched {
                    speakerMapping[rawID] = profile.name
                    if let embedding = embeddings[rawID] {
                        // Only update stored embedding on high-confidence matches
                        // to prevent drift from marginal matches
                        let sim = SpeakerMatcher.cosineSimilarity(embedding, profile.embedding)
                        if sim >= 0.85 {
                            store.updateEmbedding(id: profile.id, newEmbedding: embedding)
                        }
                    }
                }

                // Apply mapping to segments
                segments = SpeakerMatcher.remapSegments(segments, mapping: speakerMapping)

                // Store unmatched speakers for naming UI
                if !matchResult.unmatched.isEmpty {
                    let unmatched = matchResult.unmatched.map { (rawID, embedding) in
                        UnmatchedSpeaker(id: rawID, embedding: embedding)
                    }.sorted { $0.id < $1.id }

                    // Store result + config for re-formatting after naming
                    await MainActor.run {
                        self.unmatchedSpeakers[fileURL] = unmatched
                        self.lastResults[fileURL] = (result, config, speakerMapping)
                    }

                    // Persist to disk so naming survives app restart
                    self.writePendingSpeakers(unmatched, for: fileURL,
                                              format: config.transcriptFormat, result: result)
                }
            }

            let format = config.transcriptFormat
            let metadata = TranscriptMetadata(
                duration: result.duration,
                speakers: result.speakers,
                sourceFile: fileURL.path)
            let formatted = formatOutput(
                segments: segments, metadata: metadata, format: format)

            let baseTranscriptURL = fileURL.deletingPathExtension().appendingPathExtension(format.rawValue)
            let transcriptURL = overwrite ? baseTranscriptURL : uniqueFileURL(for: baseTranscriptURL)
            try formatted.write(to: transcriptURL, atomically: true, encoding: .utf8)

            await MainActor.run {
                if transcribingURL == fileURL {
                    state = .ready; transcribingURL = nil
                }
            }
            return transcriptURL
        } catch {
            await MainActor.run {
                if transcribingURL == fileURL {
                    state = .ready; transcribingURL = nil
                }
            }
            throw error
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
                sourceFile: fileURL.path)
            let formatted = formatOutput(
                segments: segments, metadata: metadata, format: saved.config.transcriptFormat)
            let transcriptURL = fileURL.deletingPathExtension()
                .appendingPathExtension(saved.config.transcriptFormat.rawValue)
            try? formatted.write(to: transcriptURL, atomically: true, encoding: .utf8)
        } else if !newMapping.isEmpty {
            // Post-restart: find and string-replace raw IDs in the transcript file
            replaceInTranscriptFiles(for: fileURL, mapping: newMapping)
        }

        // Clear state and remove sidecar
        unmatchedSpeakers.removeValue(forKey: fileURL)
        lastResults.removeValue(forKey: fileURL)
        loadedSegments.removeValue(forKey: fileURL)
        removePendingSpeakersFile(for: fileURL)
    }

    /// Returns a segment time range for a given raw speaker ID, for audio preview.
    /// Picks randomly from the top 3 longest segments, offset to avoid boundary bleed.
    func randomSegmentRange(for speakerID: String, fileURL: URL) -> (start: Double, end: Double)? {
        // Use in-memory results if available, otherwise fall back to loaded sidecar data.
        // When in-memory results exist, filter out sparse-text segments (likely silence).
        let allSegments: [(start: Double, end: Double)]
        if let saved = lastResults[fileURL] {
            allSegments = saved.result.segments
                .filter { $0.speaker == speakerID }
                .filter { seg in
                    let duration = seg.end - seg.start
                    guard duration >= 2.0 else { return false }
                    let wordCount = seg.text.split(separator: " ").count
                    return wordCount >= 3
                }
                .map { ($0.start, $0.end) }
        } else if let loaded = loadedSegments[fileURL] {
            allSegments = loaded
                .filter { $0.speaker == speakerID }
                .filter { ($0.end - $0.start) >= 2.0 }
                .map { ($0.start, $0.end) }
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
            if !pending.segments.isEmpty {
                loadedSegments[audioURL] = pending.segments
            }
        }
    }

    private func writePendingSpeakers(_ speakers: [UnmatchedSpeaker], for fileURL: URL,
                                      format: OutputFormat, result: TranscriptionResult) {
        let timings = result.segments.map {
            SegmentTiming(start: $0.start, end: $0.end, speaker: $0.speaker)
        }
        let pending = PendingSpeakers(
            audioFile: fileURL.lastPathComponent,
            transcriptExtension: format.rawValue,
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
    private func replaceInTranscriptFiles(for fileURL: URL, mapping: [String: String]) {
        let base = fileURL.deletingPathExtension()
        for format in OutputFormat.allCases {
            let transcriptURL = base.appendingPathExtension(format.rawValue)
            guard var content = try? String(contentsOf: transcriptURL, encoding: .utf8) else { continue }
            for (rawID, name) in mapping {
                content = content.replacingOccurrences(of: rawID, with: name)
            }
            try? content.write(to: transcriptURL, atomically: true, encoding: .utf8)
        }
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
