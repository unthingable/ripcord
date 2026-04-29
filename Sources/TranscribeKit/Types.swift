import Foundation

// MARK: - Model Configuration

public enum ModelVersion: String, CaseIterable, Sendable {
    case v2, v3
}

// MARK: - Diarization Configuration

public enum DiarizationEngine: String, CaseIterable, Sendable {
    case offline      // Pyannote-style segmentation + embedding + clustering (~1s boundary resolution)
    case lseend       // LS-EEND end-to-end neural diarizer (100ms frame precision, up to 10 speakers)
    case sortformer   // NVIDIA Sortformer (80ms frames, 4 fixed speaker slots)
}

public enum DiarizationQuality: String, CaseIterable, Sendable {
    case fast      // FluidAudio defaults (faster, less accurate boundaries)
    case balanced  // stepRatio 0.05 for denser frames (~2x slower)
}

public enum SpeakerCount: Sendable, Equatable {
    case auto
    case exactly(Int)
    case range(min: Int?, max: Int?)
}

public struct DiarizationConfig: Sendable {
    public var engine: DiarizationEngine
    public var quality: DiarizationQuality
    public var clusteringThreshold: Double?
    public var speakerCount: SpeakerCount
    public var speechThreshold: Float?
    public var minSegmentDuration: Double?
    public var minGapDuration: Double?
    public var removeFillerWords: Bool

    public init(
        engine: DiarizationEngine = .offline,
        quality: DiarizationQuality = .balanced,
        clusteringThreshold: Double? = nil,
        speakerCount: SpeakerCount = .auto,
        speechThreshold: Float? = nil,
        minSegmentDuration: Double? = nil,
        minGapDuration: Double? = nil,
        removeFillerWords: Bool = false
    ) {
        self.engine = engine
        self.quality = quality
        self.clusteringThreshold = clusteringThreshold
        self.speakerCount = speakerCount
        self.speechThreshold = speechThreshold
        self.minSegmentDuration = minSegmentDuration
        self.minGapDuration = minGapDuration
        self.removeFillerWords = removeFillerWords
    }
}

// MARK: - Transcript Types

public struct WordTiming: Sendable {
    public let word: String
    public let startTime: TimeInterval
    public let endTime: TimeInterval
    public let confidence: Float

    public init(word: String, startTime: TimeInterval, endTime: TimeInterval, confidence: Float) {
        self.word = word
        self.startTime = startTime
        self.endTime = endTime
        self.confidence = confidence
    }
}

public struct TranscriptSegment: Sendable {
    public let start: Double
    public let end: Double
    public let text: String
    public let speaker: String?

    public init(start: Double, end: Double, text: String, speaker: String?) {
        self.start = start
        self.end = end
        self.text = text
        self.speaker = speaker
    }
}

public struct TranscriptMetadata: Sendable {
    public let duration: TimeInterval
    public let speakers: [String]
    public let sourceFile: String
    public let configSummary: String?

    public init(duration: TimeInterval, speakers: [String], sourceFile: String, configSummary: String? = nil) {
        self.duration = duration
        self.speakers = speakers
        self.sourceFile = sourceFile
        self.configSummary = configSummary
    }
}

public enum OutputFormat: String, CaseIterable, Sendable {
    case txt, md, json, srt, vtt
}

// MARK: - Speaker Identity

public struct SpeakerProfile: Codable, Sendable, Identifiable {
    public let id: UUID
    public var name: String
    public var embedding: [Float]
    public var observationCount: Int

    public init(id: UUID = UUID(), name: String, embedding: [Float], observationCount: Int = 1) {
        self.id = id
        self.name = name
        self.embedding = embedding
        self.observationCount = observationCount
    }
}

// MARK: - Transcription Result

public struct TranscriptionResult: Sendable {
    public let segments: [TranscriptSegment]
    public let duration: TimeInterval
    public let speakers: [String]
    public let text: String
    public let speakerEmbeddings: [String: [Float]]?

    public init(segments: [TranscriptSegment], duration: TimeInterval, speakers: [String], speakerEmbeddings: [String: [Float]]? = nil) {
        self.segments = segments
        self.duration = duration
        self.speakers = speakers
        self.text = segments.map(\.text).joined(separator: " ")
        self.speakerEmbeddings = speakerEmbeddings
    }
}
