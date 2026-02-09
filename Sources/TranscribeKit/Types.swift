import Foundation

// MARK: - Model Configuration

public enum ModelVersion: String, CaseIterable, Sendable {
    case v2, v3
}

// MARK: - Diarization Configuration

public enum DiarizationQuality: String, CaseIterable, Sendable {
    case fast      // clustering threshold 0.7, otherwise FA defaults
    case balanced  // clustering threshold 0.7, stepRatio 0.1 (~2x slower)
}

public enum SpeakerCount: Sendable, Equatable {
    case auto
    case exactly(Int)
    case range(min: Int?, max: Int?)
}

public struct DiarizationConfig: Sendable {
    public var quality: DiarizationQuality
    public var clusteringThreshold: Double?
    public var speakerCount: SpeakerCount
    public var speechThreshold: Float?
    public var minSegmentDuration: Double?
    public var minGapDuration: Double?
    public var removeFillerWords: Bool

    public init(
        quality: DiarizationQuality = .balanced,
        clusteringThreshold: Double? = nil,
        speakerCount: SpeakerCount = .auto,
        speechThreshold: Float? = nil,
        minSegmentDuration: Double? = nil,
        minGapDuration: Double? = nil,
        removeFillerWords: Bool = false
    ) {
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

    public init(duration: TimeInterval, speakers: [String], sourceFile: String) {
        self.duration = duration
        self.speakers = speakers
        self.sourceFile = sourceFile
    }
}

public enum OutputFormat: String, CaseIterable, Sendable {
    case txt, md, json, srt, vtt
}

// MARK: - Transcription Result

public struct TranscriptionResult: Sendable {
    public let segments: [TranscriptSegment]
    public let duration: TimeInterval
    public let speakers: [String]
    public let text: String

    public init(segments: [TranscriptSegment], duration: TimeInterval, speakers: [String]) {
        self.segments = segments
        self.duration = duration
        self.speakers = speakers
        self.text = segments.map(\.text).joined(separator: " ")
    }
}
