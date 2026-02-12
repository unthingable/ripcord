import FluidAudio
import Foundation

// MARK: - Filler Words

/// Unambiguous single-word fillers to strip when removeFillerWords is enabled.
public let fillerWords: Set<String> = [
    "um", "uh", "umm", "uhh", "hmm", "hm", "er", "ah", "erm", "eh", "mm",
]

/// Returns true if the word (after lowercasing and stripping punctuation) is a filler.
public func isFillerWord(_ word: String) -> Bool {
    let stripped = word.lowercased().trimmingCharacters(
        in: .punctuationCharacters.union(.symbols))
    return fillerWords.contains(stripped)
}

// MARK: - Token → Word Merging

/// Merge subword token timings into word-level timings.
///
/// Tokens starting with whitespace indicate word boundaries (SentencePiece convention).
public func mergeTokensIntoWords(_ tokenTimings: [TokenTiming]) -> [WordTiming] {
    guard !tokenTimings.isEmpty else { return [] }

    var words: [WordTiming] = []
    var currentWord = ""
    var currentStart: TimeInterval?
    var currentEnd: TimeInterval = 0
    var confidences: [Float] = []

    for timing in tokenTimings {
        let token = timing.token

        if token.hasPrefix(" ") || token.hasPrefix("\n") || token.hasPrefix("\t") {
            if !currentWord.isEmpty, let start = currentStart {
                let avgConf = confidences.isEmpty
                    ? Float(0) : confidences.reduce(0, +) / Float(confidences.count)
                words.append(WordTiming(
                    word: currentWord, startTime: start,
                    endTime: currentEnd, confidence: avgConf))
            }
            currentWord = token.trimmingCharacters(in: .whitespacesAndNewlines)
            currentStart = timing.startTime
            currentEnd = timing.endTime
            confidences = [timing.confidence]
        } else {
            if currentStart == nil {
                currentStart = timing.startTime
            }
            currentWord += token
            currentEnd = timing.endTime
            confidences.append(timing.confidence)
        }
    }

    if !currentWord.isEmpty, let start = currentStart {
        let avgConf = confidences.isEmpty
            ? Float(0) : confidences.reduce(0, +) / Float(confidences.count)
        words.append(WordTiming(
            word: currentWord, startTime: start,
            endTime: currentEnd, confidence: avgConf))
    }

    return words
}

// MARK: - Overlap-Based Speaker Matching

/// Find the speaker for a word by computing overlap with diarization segments.
/// Falls back to nearest segment within 2s if there is no overlap.
///
/// When `previousSpeaker` is provided and has overlap with the current word, a small
/// continuity bonus is added to their overlap before comparing. This makes speaker
/// transitions "sticky" — a switch only happens when there's a clear overlap majority
/// for the new speaker, preventing boundary bleed at speaker transitions.
public func findSpeakerByOverlap(
    wordStart: Double, wordEnd: Double,
    in segments: [TimedSpeakerSegment],
    previousSpeaker: String? = nil
) -> String? {
    // Compute overlap per speaker
    var speakerOverlap: [String: Double] = [:]
    for seg in segments {
        let segStart = Double(seg.startTimeSeconds)
        let segEnd = Double(seg.endTimeSeconds)
        let overlapStart = max(wordStart, segStart)
        let overlapEnd = min(wordEnd, segEnd)
        let overlap = overlapEnd - overlapStart
        if overlap > 0 {
            speakerOverlap[seg.speakerId, default: 0] += overlap
        }
    }

    // Apply continuity bias: give previous speaker a bonus to prevent boundary bleed
    let continuityBonus = 0.08
    if let prev = previousSpeaker, speakerOverlap[prev] != nil {
        speakerOverlap[prev]! += continuityBonus
    }

    // Pick speaker with greatest total overlap
    if let best = speakerOverlap.max(by: { $0.value < $1.value }) {
        return best.key
    }

    // Fallback: nearest segment within 2s
    let wordMid = (wordStart + wordEnd) / 2
    var bestSpeaker: String?
    var bestDistance = Double.infinity
    for seg in segments {
        let segStart = Double(seg.startTimeSeconds)
        let segEnd = Double(seg.endTimeSeconds)
        let distance: Double
        if wordMid < segStart {
            distance = segStart - wordMid
        } else if wordMid > segEnd {
            distance = wordMid - segEnd
        } else {
            distance = 0
        }
        if distance < bestDistance {
            bestDistance = distance
            bestSpeaker = seg.speakerId
        }
    }
    return bestDistance <= 2.0 ? bestSpeaker : nil
}

// MARK: - Snap Transitions to Pauses

/// Correct diarization boundary lag by snapping speaker transitions to actual speech pauses.
///
/// Diarization models produce segment boundaries that can lag behind real speaker transitions
/// by up to a full word duration. When this happens, the last word(s) of the outgoing speaker
/// fall entirely within the incoming speaker's diarization segment and get misattributed.
///
/// This pass exploits the fact that real speaker transitions almost always coincide with pauses
/// in speech. ASR word timings are precise enough to detect these pauses. At each speaker
/// transition where there is no pause (continuous speech), we look ahead for the first real
/// pause and snap the transition boundary to it, reassigning the intermediate words back to
/// the previous speaker.
///
/// - Parameters:
///   - words: Speaker-assigned words to correct (modified in place).
///   - pauseThreshold: Minimum inter-word gap (seconds) that constitutes a real pause.
///     Typical within-utterance gaps are <0.2s; turn-taking gaps are 0.2-0.5s. Default 0.3s.
///   - maxWords: Maximum number of words to reassign per transition (safety cap).
///   - maxDuration: Maximum total duration of reassigned words (safety cap, seconds).
public func snapTransitionsToPauses(
    _ words: inout [SpeakerWord],
    pauseThreshold: Double = 0.3,
    maxWords: Int = 3,
    maxDuration: Double = 2.0
) {
    guard words.count >= 2 else { return }

    var i = 1
    while i < words.count {
        guard words[i].speaker != words[i - 1].speaker,
              words[i - 1].speaker != nil,
              words[i].speaker != nil
        else {
            i += 1
            continue
        }

        // Backward check: if there's already a pause at this transition, it's probably correct
        let gapAtTransition = words[i].word.startTime - words[i - 1].word.endTime
        if gapAtTransition >= pauseThreshold {
            i += 1
            continue
        }

        // No pause at transition — look ahead for the first real pause within the new speaker's run
        let prevSpeaker = words[i - 1].speaker
        let newSpeaker = words[i].speaker
        var snapTo: Int? = nil
        var accumulated = words[i].word.endTime - words[i].word.startTime

        for j in (i + 1)..<words.count {
            // Stop if we leave the new speaker's run
            guard words[j].speaker == newSpeaker else { break }
            // Stop if we'd exceed caps
            guard (j - i) <= maxWords, accumulated < maxDuration else { break }

            let gap = words[j].word.startTime - words[j - 1].word.endTime
            if gap >= pauseThreshold {
                snapTo = j
                break
            }
            accumulated += words[j].word.endTime - words[j].word.startTime
        }

        if let snapTo {
            // Reassign words [i..<snapTo] to the previous speaker
            for k in i..<snapTo {
                words[k].speaker = prevSpeaker
            }
            i = snapTo + 1
        } else {
            i += 1
        }
    }
}

// MARK: - Speaker Smoothing

public struct SpeakerWord {
    public let word: WordTiming
    public var speaker: String?

    public init(word: WordTiming, speaker: String?) {
        self.word = word
        self.speaker = speaker
    }
}

/// Pass 1: Absorb nil-speaker words into the nearest non-nil neighbor by temporal distance.
public func absorbNilSpeakers(_ words: inout [SpeakerWord]) {
    for i in words.indices where words[i].speaker == nil {
        var bestSpeaker: String?
        var bestDistance = Double.infinity

        // Look backward
        for j in stride(from: i - 1, through: 0, by: -1) {
            if let sp = words[j].speaker {
                let dist = words[i].word.startTime - words[j].word.endTime
                if dist < bestDistance {
                    bestDistance = dist
                    bestSpeaker = sp
                }
                break
            }
        }

        // Look forward
        for j in (i + 1)..<words.count {
            if let sp = words[j].speaker {
                let dist = words[j].word.startTime - words[i].word.endTime
                if dist < bestDistance {
                    bestDistance = dist
                    bestSpeaker = sp
                }
                break
            }
        }

        words[i].speaker = bestSpeaker
    }
}

/// Pass 2: Iteratively merge the shortest speaker run (by time) into its longer neighbor until
/// all runs meet the minimum duration threshold.
///
/// Each pass finds the shortest run by `endTime - startTime`. If it's under `threshold` seconds,
/// it merges into the longer adjacent neighbor (or only neighbor for edge runs). Repeats until
/// no run is under the threshold or no merge is possible.
public func smoothSpeakerRuns(_ words: inout [SpeakerWord], threshold: Double = 1.5) {
    guard words.count >= 2 else { return }

    while true {
        // Build runs: [(startIdx, count, speaker)]
        var runs: [(start: Int, count: Int, speaker: String?)] = []
        var runStart = 0
        for i in 1..<words.count {
            if words[i].speaker != words[runStart].speaker {
                runs.append((runStart, i - runStart, words[runStart].speaker))
                runStart = i
            }
        }
        runs.append((runStart, words.count - runStart, words[runStart].speaker))

        guard runs.count >= 2 else { break }

        // Find the shortest run by time duration
        var shortestIdx = -1
        var shortestDuration = Double.infinity
        for ri in runs.indices {
            let run = runs[ri]
            let startTime = words[run.start].word.startTime
            let endTime = words[run.start + run.count - 1].word.endTime
            let duration = endTime - startTime
            if duration < shortestDuration {
                shortestDuration = duration
                shortestIdx = ri
            }
        }

        guard shortestIdx >= 0, shortestDuration < threshold else { break }

        // Determine which neighbor to merge into (the longer one)
        let run = runs[shortestIdx]
        let neighborIdx: Int
        if shortestIdx == 0 {
            neighborIdx = 1
        } else if shortestIdx == runs.count - 1 {
            neighborIdx = runs.count - 2
        } else {
            let prevRun = runs[shortestIdx - 1]
            let nextRun = runs[shortestIdx + 1]
            let prevDuration = words[prevRun.start + prevRun.count - 1].word.endTime - words[prevRun.start].word.startTime
            let nextDuration = words[nextRun.start + nextRun.count - 1].word.endTime - words[nextRun.start].word.startTime
            neighborIdx = prevDuration >= nextDuration ? shortestIdx - 1 : shortestIdx + 1
        }

        // Merge: assign the neighbor's speaker to all words in the short run
        let neighborSpeaker = runs[neighborIdx].speaker
        for wi in run.start..<(run.start + run.count) {
            words[wi].speaker = neighborSpeaker
        }
    }
}

// MARK: - Public Merge API

/// Merge ASR result with optional diarization into transcript segments.
public func mergeResults(
    asrResult: ASRResult,
    diarizationResult: DiarizationResult?,
    removeFillerWords: Bool = false
) -> [TranscriptSegment] {
    guard let tokenTimings = asrResult.tokenTimings, !tokenTimings.isEmpty else {
        return [TranscriptSegment(
            start: 0, end: asrResult.duration,
            text: asrResult.text.trimmingCharacters(in: .whitespacesAndNewlines),
            speaker: nil)]
    }

    var words = mergeTokensIntoWords(tokenTimings)
    guard !words.isEmpty else {
        return [TranscriptSegment(
            start: 0, end: asrResult.duration,
            text: asrResult.text.trimmingCharacters(in: .whitespacesAndNewlines),
            speaker: nil)]
    }

    // Filter filler words before speaker assignment
    if removeFillerWords {
        words = words.filter { !isFillerWord($0.word) }
        guard !words.isEmpty else {
            return [TranscriptSegment(start: 0, end: asrResult.duration, text: "", speaker: nil)]
        }
    }

    if let diarization = diarizationResult {
        return mergeWithDiarization(words: words, diarization: diarization)
    }
    return segmentWithoutDiarization(words: words)
}

/// Group words into segments by speaker continuity, using overlap-based matching and debouncing.
private func mergeWithDiarization(
    words: [WordTiming],
    diarization: DiarizationResult
) -> [TranscriptSegment] {
    let diarizationSegments = diarization.segments

    // Step 1: Overlap-based speaker assignment with continuity bias
    var speakerWords: [SpeakerWord] = []
    var previousSpeaker: String? = nil
    for word in words {
        let speaker = findSpeakerByOverlap(
            wordStart: word.startTime, wordEnd: word.endTime,
            in: diarizationSegments, previousSpeaker: previousSpeaker)
        speakerWords.append(SpeakerWord(word: word, speaker: speaker))
        previousSpeaker = speaker ?? previousSpeaker
    }

    // Step 2: Snap speaker transitions to actual speech pauses
    snapTransitionsToPauses(&speakerWords)

    // Step 3: Absorb nil-speaker words into nearest neighbor
    absorbNilSpeakers(&speakerWords)

    // Step 4: Smooth short false speaker switches
    smoothSpeakerRuns(&speakerWords)

    // Step 5: Sentence-aware segment grouping
    return groupBySentenceAndSpeaker(speakerWords)
}

// MARK: - Sentence-Aware Grouping

private let sentenceEnders: Set<Character> = [".", "!", "?"]

/// Maximum segment duration (seconds) before force-emitting, even without a sentence boundary.
/// Prevents runaway segments when ASR produces no punctuation (common in non-English).
private let maxSegmentDuration: Double = 30.0

/// Group speaker-assigned words into segments aligned to sentence boundaries.
///
/// Instead of splitting at every speaker change (which fragments sentences mid-phrase),
/// this accumulates words and only emits a segment when a sentence boundary (punctuation
/// or significant pause) coincides with a speaker change. If a speaker change occurs
/// mid-sentence, the trailing words are kept in the current segment and the segment is
/// attributed to whichever speaker covers the most duration.
///
/// A safety cap (`maxSegmentDuration`) force-emits at the last speaker-change point
/// within the accumulator to prevent unbounded segments when punctuation is absent.
public func groupBySentenceAndSpeaker(_ speakerWords: [SpeakerWord]) -> [TranscriptSegment] {
    guard !speakerWords.isEmpty else { return [] }

    var segments: [TranscriptSegment] = []
    // Accumulator: (word, speaker) pairs for the current segment
    var accum: [SpeakerWord] = []
    // Index within accum of the last speaker change (used for force-emit split point)
    var lastSpeakerChangeIdx: Int? = nil

    for (i, sw) in speakerWords.enumerated() {
        accum.append(sw)

        // Track where speaker changes happen within the accumulator
        if accum.count >= 2 && accum[accum.count - 1].speaker != accum[accum.count - 2].speaker {
            lastSpeakerChangeIdx = accum.count - 1
        }

        // Detect sentence boundary: punctuation or significant pause to next word
        let isSentenceEnd = sw.word.word.last.map { sentenceEnders.contains($0) } ?? false
        let isPause: Bool
        if i + 1 < speakerWords.count {
            isPause = (speakerWords[i + 1].word.startTime - sw.word.endTime) > 1.0
        } else {
            isPause = false
        }
        let isBoundary = isSentenceEnd || isPause

        // Check if the next word has a different speaker
        let speakerChangesNext: Bool
        if i + 1 < speakerWords.count {
            speakerChangesNext = speakerWords[i + 1].speaker != sw.speaker
        } else {
            speakerChangesNext = false
        }

        // Emit when we hit a sentence boundary and the next word is a different speaker
        if isBoundary && speakerChangesNext {
            segments.append(emitSegment(from: accum))
            accum = []
            lastSpeakerChangeIdx = nil
            continue
        }

        // Lookahead: if boundary but no immediate speaker change, check if one is imminent.
        // Diarizer boundaries often lag 1-3 words behind real turn-taking points.
        // Only trigger when there's a small gap (>0.15s) to avoid splitting mid-phrase
        // punctuation like "Mr. Smith".
        if isBoundary && !speakerChangesNext && i + 1 < speakerWords.count {
            let gap = speakerWords[i + 1].word.startTime - sw.word.endTime
            if gap > 0.15 {
                let lookahead = min(i + 4, speakerWords.count) // up to 3 words ahead
                var imminentChange = false
                for j in (i + 1)..<lookahead {
                    if speakerWords[j].speaker != sw.speaker {
                        imminentChange = true
                        break
                    }
                }
                if imminentChange {
                    segments.append(emitSegment(from: accum))
                    accum = []
                    lastSpeakerChangeIdx = nil
                    continue
                }
            }
        }

        // Safety cap: force-emit if the segment has grown too long
        let duration = sw.word.endTime - accum.first!.word.startTime
        if duration >= maxSegmentDuration, let splitIdx = lastSpeakerChangeIdx, splitIdx > 0 {
            // Emit everything before the last speaker change
            let before = Array(accum.prefix(splitIdx))
            segments.append(emitSegment(from: before))
            accum = Array(accum.suffix(from: splitIdx))
            // Recalculate lastSpeakerChangeIdx for the remaining accumulator
            lastSpeakerChangeIdx = nil
            for j in 1..<accum.count {
                if accum[j].speaker != accum[j - 1].speaker {
                    lastSpeakerChangeIdx = j
                }
            }
        }
    }

    // Emit any remaining words
    if !accum.isEmpty {
        segments.append(emitSegment(from: accum))
    }

    return segments
}

/// Build a TranscriptSegment from accumulated speaker-words, attributing the segment
/// to whichever speaker covers the most total duration.
private func emitSegment(from words: [SpeakerWord]) -> TranscriptSegment {
    let start = words.first!.word.startTime
    let end = words.last!.word.endTime
    let text = words.map(\.word.word).joined(separator: " ")

    // Majority speaker by duration
    var speakerDuration: [String: Double] = [:]
    for sw in words {
        if let speaker = sw.speaker {
            speakerDuration[speaker, default: 0] += sw.word.endTime - sw.word.startTime
        }
    }
    let speaker = speakerDuration.max(by: { $0.value < $1.value })?.key

    return TranscriptSegment(start: start, end: end, text: text, speaker: speaker)
}

/// Group words into segments at sentence boundaries or pauses.
private func segmentWithoutDiarization(words: [WordTiming]) -> [TranscriptSegment] {
    var segments: [TranscriptSegment] = []
    var currentWords: [WordTiming] = []
    let sentenceEnders: Set<Character> = [".", "!", "?"]

    for word in words {
        currentWords.append(word)

        let isSentenceEnd = word.word.last.map { sentenceEnders.contains($0) } ?? false
        let isPause = currentWords.count > 1
            && (word.startTime - currentWords[currentWords.count - 2].endTime) > 1.0

        if isSentenceEnd || isPause {
            segments.append(TranscriptSegment(
                start: currentWords.first!.startTime,
                end: currentWords.last!.endTime,
                text: currentWords.map(\.word).joined(separator: " "),
                speaker: nil))
            currentWords = []
        }
    }

    if !currentWords.isEmpty {
        segments.append(TranscriptSegment(
            start: currentWords.first!.startTime,
            end: currentWords.last!.endTime,
            text: currentWords.map(\.word).joined(separator: " "),
            speaker: nil))
    }

    return segments
}
