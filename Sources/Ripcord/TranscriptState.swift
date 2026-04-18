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
    /// Whether this word came from a mid-chunk hypothesis (will be replaced by full-chunk output).
    let isHypothesis: Bool
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
    private static let turnBreakThreshold: TimeInterval = 2.0

    /// Drop turns older than this relative to the newest confirmed word.
    /// Protects against unbounded growth if the user leaves live transcript on for days.
    private static let retentionSeconds: TimeInterval = 90 * 60
    /// Hard backstop if word rate or stream-time behavior ever defeats the time-based prune.
    private static let hardTurnCap = 2000

    /// Highest word.end observed from full-chunk (non-hypothesis) words.
    /// Used as the reference point for the retention window.
    private var maxSeenEnd: TimeInterval = 0

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
        maxSeenEnd = 0
    }

    private func addWord(_ word: TranscriptWord) {
        // Update confirmed-through watermark
        if word.confirmedThrough > (confirmedThrough[word.source] ?? 0) {
            confirmedThrough[word.source] = word.confirmedThrough
        }

        if word.isHypothesis {
            addHypothesisWord(word)
        } else {
            // Full-chunk word: retract any hypothesis words for this source first
            retractHypothesisWords(source: word.source)
            appendWord(word)
            if word.end > maxSeenEnd { maxSeenEnd = word.end }
            pruneOldTurns()
        }
    }

    /// Drop turns whose last word is older than the retention window, plus a hard count backstop.
    /// Only runs on full-chunk words (hypothesis words are transient).
    private func pruneOldTurns() {
        let cutoff = maxSeenEnd - Self.retentionSeconds
        while let first = turns.first,
              let lastEnd = first.phrases.last?.words.last?.end,
              lastEnd < cutoff {
            turns.removeFirst()
        }
        if turns.count > Self.hardTurnCap {
            turns.removeFirst(turns.count - Self.hardTurnCap)
        }
    }

    /// Append a word to the turn/phrase structure (standard path for both full-chunk and hypothesis).
    private func appendWord(_ word: TranscriptWord) {
        if var lastTurn = turns.last, lastTurn.source == word.source,
           let lastEnd = lastTurn.phrases.last?.words.last?.end
        {
            let gap = word.start - lastEnd

            if gap >= Self.turnBreakThreshold {
                // Long pause — start a new turn (same speaker, new "message")
                let phrase = TranscriptPhrase(words: [word], source: word.source)
                turns.append(TranscriptTurn(source: word.source, phrases: [phrase]))
            } else if gap >= Self.pauseThreshold {
                // Short pause — new phrase within the same turn
                lastTurn.phrases.append(TranscriptPhrase(words: [word], source: word.source))
                turns[turns.count - 1] = lastTurn
            } else {
                // Continuous speech — append to current phrase
                var lastPhrase = lastTurn.phrases[lastTurn.phrases.count - 1]
                lastPhrase.words.append(word)
                lastTurn.phrases[lastTurn.phrases.count - 1] = lastPhrase
                turns[turns.count - 1] = lastTurn
            }
        } else if turns.last?.source == word.source {
            // Same source but no words yet (empty turn after retraction)
            var lastTurn = turns[turns.count - 1]
            lastTurn.phrases.append(TranscriptPhrase(words: [word], source: word.source))
            turns[turns.count - 1] = lastTurn
        } else {
            // Different speaker or first word
            let phrase = TranscriptPhrase(words: [word], source: word.source)
            turns.append(TranscriptTurn(source: word.source, phrases: [phrase]))
        }
    }

    /// Add a hypothesis word, replacing any prior hypothesis words for this source.
    private func addHypothesisWord(_ word: TranscriptWord) {
        // On first hypothesis word for a new batch, retract previous hypothesis words
        // We detect "new batch" by checking if this word's start is before the last hypothesis end
        // (which means the ASR re-processed the same region with more context)
        retractHypothesisWords(source: word.source)
        appendWord(word)
    }

    /// Remove all hypothesis words for a given source from the tail of the turns array.
    private func retractHypothesisWords(source: String) {
        guard !turns.isEmpty else { return }

        // Walk backwards through turns — hypothesis words only exist at the tail for their source
        var i = turns.count - 1
        while i >= 0 {
            guard turns[i].source == source else {
                // Stop once we pass a turn from a different source — hypothesis words
                // for this source can't exist before a different speaker's turn
                break
            }

            var turn = turns[i]
            var j = turn.phrases.count - 1
            while j >= 0 {
                let original = turn.phrases[j].words
                let filtered = original.filter { !$0.isHypothesis }
                if filtered.isEmpty {
                    turn.phrases.remove(at: j)
                } else if filtered.count != original.count {
                    turn.phrases[j].words = filtered
                }
                j -= 1
            }

            if turn.phrases.isEmpty {
                turns.remove(at: i)
            } else {
                turns[i] = turn
            }
            i -= 1
        }
    }
}
