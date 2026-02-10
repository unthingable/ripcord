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

@Observable
final class TranscriptionService: @unchecked Sendable {
    var state: TranscriptionState = .idle
    var transcribingURL: URL?

    var modelsReady: Bool { state == .ready }

    private var transcriber = Transcriber()

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

    private var isFailedState: Bool {
        if case .failed = state { return true }
        return false
    }

    /// Check whether model files exist on disk (no download, no loading).
    static func modelsExistOnDisk(config: TranscriptionConfig) -> Bool {
        return Transcriber.modelsExistOnDisk(version: config.asrModelVersion)
    }

    // MARK: - Transcription Pipeline

    func transcribe(fileURL: URL, config: TranscriptionConfig, overwrite: Bool = false) async throws -> URL {
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

            let format = config.transcriptFormat
            let metadata = TranscriptMetadata(
                duration: result.duration,
                speakers: result.speakers,
                sourceFile: fileURL.path)
            let formatted = formatOutput(
                segments: result.segments, metadata: metadata, format: format)

            let baseTranscriptURL = fileURL.deletingPathExtension().appendingPathExtension(format.rawValue)
            let transcriptURL = overwrite ? baseTranscriptURL : uniqueFileURL(for: baseTranscriptURL)
            try formatted.write(to: transcriptURL, atomically: true, encoding: .utf8)

            await MainActor.run { state = .ready; transcribingURL = nil }
            return transcriptURL
        } catch {
            await MainActor.run { state = .ready; transcribingURL = nil }
            throw error
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
