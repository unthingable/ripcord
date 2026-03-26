import Foundation
import Observation

/// A single word emitted by live transcript streaming.
struct TranscriptWord: Sendable {
    let word: String
    let start: TimeInterval
    let end: TimeInterval
    let source: String  // "sys" or "mic"
    /// Confirmed-through end time at emission. Words with end <= confirmedThrough are confirmed.
    let confirmedThrough: TimeInterval
}

/// A phrase — a sequence of words from the same source separated by < pauseThreshold.
struct TranscriptPhrase: Identifiable {
    let id = UUID()
    var words: [TranscriptWord]
    var source: String

    var text: String { words.map(\.word).joined(separator: " ") }
    var startTime: TimeInterval? { words.first?.start }
}

/// A speaker turn — one or more consecutive phrases from the same source.
struct TranscriptTurn: Identifiable {
    let id = UUID()
    var source: String
    var phrases: [TranscriptPhrase]

    var startTime: TimeInterval? { phrases.first?.startTime }

    var speakerLabel: String { source == "mic" ? "You" : "Other" }

    var fullText: String {
        phrases.map(\.text).joined(separator: " ")
    }
}

/// Observable state for the live transcript panel.
///
/// Consumes an `AsyncStream<TranscriptWord>` and groups words into phrases
/// (by pause detection) and turns (by speaker change).
@MainActor
@Observable
final class TranscriptState {
    private(set) var turns: [TranscriptTurn] = []

    /// Whether the user has scrolled up (disables auto-scroll).
    var userScrolledUp = false

    /// Confirmed-through end time per source. Words with end <= this are confirmed.
    private(set) var confirmedThrough: [String: TimeInterval] = [:]

    private static let pauseThreshold: TimeInterval = 0.5

    private var consumeTask: Task<Void, Never>?

    /// Returns the confirmed-through end time for a given source.
    func confirmedEnd(for source: String) -> TimeInterval {
        confirmedThrough[source] ?? 0
    }

    func startConsuming(_ stream: AsyncStream<TranscriptWord>) {
        consumeTask?.cancel()
        consumeTask = Task { [weak self] in
            for await word in stream {
                guard !Task.isCancelled else { break }
                self?.addWord(word)
            }
        }
    }

    func stopConsuming() {
        consumeTask?.cancel()
        consumeTask = nil
    }

    func clear() {
        turns.removeAll()
        confirmedThrough.removeAll()
    }

    private func addWord(_ word: TranscriptWord) {
        // Update confirmed-through watermark
        if word.confirmedThrough > (confirmedThrough[word.source] ?? 0) {
            confirmedThrough[word.source] = word.confirmedThrough
        }

        // If same source as current turn, check if we need a new phrase (pause gap)
        if var lastTurn = turns.last, lastTurn.source == word.source {
            if var lastPhrase = lastTurn.phrases.last,
               let lastEnd = lastPhrase.words.last?.end,
               word.start - lastEnd < Self.pauseThreshold
            {
                // Append to existing phrase
                lastPhrase.words.append(word)
                lastTurn.phrases[lastTurn.phrases.count - 1] = lastPhrase
            } else {
                // New phrase (pause detected)
                lastTurn.phrases.append(TranscriptPhrase(words: [word], source: word.source))
            }
            turns[turns.count - 1] = lastTurn
        } else {
            // New speaker turn
            let phrase = TranscriptPhrase(words: [word], source: word.source)
            turns.append(TranscriptTurn(source: word.source, phrases: [phrase]))
        }
    }
}
