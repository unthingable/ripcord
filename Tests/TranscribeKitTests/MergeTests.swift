import FluidAudio
import Foundation

import TranscribeKit

// MARK: - Minimal Test Harness

nonisolated(unsafe) var passed = 0
nonisolated(unsafe) var failed = 0

func assert(_ condition: Bool, _ message: String, file: String = #file, line: Int = #line) {
    if condition {
        passed += 1
    } else {
        failed += 1
        print("  FAIL [\(file.split(separator: "/").last ?? ""):\(line)] \(message)")
    }
}

func assertEqual<T: Equatable>(_ a: T, _ b: T, _ label: String = "", file: String = #file, line: Int = #line) {
    assert(a == b, "\(label.isEmpty ? "" : label + ": ")expected \(b), got \(a)", file: file, line: line)
}

func assertNil<T>(_ value: T?, _ label: String = "", file: String = #file, line: Int = #line) {
    assert(value == nil, "\(label.isEmpty ? "" : label + ": ")expected nil, got \(String(describing: value))", file: file, line: line)
}

func test(_ name: String, _ body: () -> Void) {
    print("  \(name)")
    body()
}

// MARK: - Test Helpers

func makeSeg(speaker: String, start: Float, end: Float) -> TimedSpeakerSegment {
    TimedSpeakerSegment(
        speakerId: speaker, embedding: [],
        startTimeSeconds: start, endTimeSeconds: end,
        qualityScore: 1.0)
}

func makeWord(_ text: String, start: Double, end: Double) -> WordTiming {
    WordTiming(word: text, startTime: start, endTime: end, confidence: 0.9)
}

// MARK: - Tests

print("Overlap-based speaker matching:")

test("Word fully inside a segment gets that speaker") {
    let segments = [
        makeSeg(speaker: "A", start: 0, end: 5),
        makeSeg(speaker: "B", start: 5, end: 10),
    ]
    assertEqual(findSpeakerByOverlap(wordStart: 1.0, wordEnd: 2.0, in: segments), "A")
}

test("Word spanning two segments picks speaker with more overlap") {
    let segments = [
        makeSeg(speaker: "A", start: 0, end: 5),
        makeSeg(speaker: "B", start: 5, end: 10),
    ]
    // Word 4.0-7.0: overlap A=1.0s, overlap B=2.0s
    assertEqual(findSpeakerByOverlap(wordStart: 4.0, wordEnd: 7.0, in: segments), "B")
}

test("Word in gap falls back to nearest segment within 2s") {
    let segments = [
        makeSeg(speaker: "A", start: 0, end: 3),
        makeSeg(speaker: "B", start: 6, end: 10),
    ]
    // Midpoint 4.25: closer to A end (1.25s) than B start (1.75s)
    assertEqual(findSpeakerByOverlap(wordStart: 4.0, wordEnd: 4.5, in: segments), "A")
}

test("Word far from any segment returns nil") {
    let segments = [makeSeg(speaker: "A", start: 0, end: 1)]
    assertNil(findSpeakerByOverlap(wordStart: 10.0, wordEnd: 10.5, in: segments))
}

print("\nContinuity bias:")

test("Boundary word stays with previous speaker on marginal overlap") {
    // Word at 4.8-5.2s straddles A (0-5s) and B (5-10s)
    // Overlap A = 0.2s, Overlap B = 0.2s — equal, but with continuity bias A wins
    let segments = [
        makeSeg(speaker: "A", start: 0, end: 5),
        makeSeg(speaker: "B", start: 5, end: 10),
    ]
    let result = findSpeakerByOverlap(
        wordStart: 4.8, wordEnd: 5.2, in: segments, previousSpeaker: "A")
    assertEqual(result, "A", "marginal overlap should stay with previous speaker")
}

test("Clear speaker change overrides continuity bias") {
    // Word at 6.0-7.0s: overlap A=0, overlap B=1.0s — clearly B despite bias toward A
    let segments = [
        makeSeg(speaker: "A", start: 0, end: 5),
        makeSeg(speaker: "B", start: 5, end: 10),
    ]
    let result = findSpeakerByOverlap(
        wordStart: 6.0, wordEnd: 7.0, in: segments, previousSpeaker: "A")
    assertEqual(result, "B", "clear overlap majority should override continuity bias")
}

test("Continuity bias only applies when previous speaker has overlap") {
    // Word at 6.0-7.0s: only B has overlap. Even though previousSpeaker is A,
    // A has no overlap so bias doesn't apply.
    let segments = [
        makeSeg(speaker: "A", start: 0, end: 5),
        makeSeg(speaker: "B", start: 5, end: 10),
    ]
    let result = findSpeakerByOverlap(
        wordStart: 6.0, wordEnd: 7.0, in: segments, previousSpeaker: "A")
    assertEqual(result, "B", "bias should not apply when previous speaker has no overlap")
}

test("No previous speaker behaves as before") {
    // Word at 4.8-5.2s straddles A and B equally — without bias, either could win
    // but without previousSpeaker the function should still return a result
    let segments = [
        makeSeg(speaker: "A", start: 0, end: 5),
        makeSeg(speaker: "B", start: 5, end: 10),
    ]
    let result = findSpeakerByOverlap(
        wordStart: 4.8, wordEnd: 5.2, in: segments, previousSpeaker: nil)
    assert(result == "A" || result == "B", "should return some speaker without bias")
}

print("\nSnap transitions to pauses:")

test("Boundary words snapped back to previous speaker when no pause") {
    // S2 says "у него ограниченный", then S1 says "у меня предложение"
    // No pause between "него" and "ограниченный" (0.08s gap) — continuous speech
    // Real pause (0.4s) between "ограниченный" and "у" — actual transition
    var words: [SpeakerWord] = [
        SpeakerWord(word: makeWord("у", start: 10.0, end: 10.2), speaker: "A"),
        SpeakerWord(word: makeWord("него", start: 10.3, end: 10.6), speaker: "A"),
        // Transition here, but only 0.08s gap — continuous speech
        SpeakerWord(word: makeWord("ограниченный", start: 10.68, end: 11.7), speaker: "B"),
        // Real pause: 0.4s gap
        SpeakerWord(word: makeWord("у", start: 12.1, end: 12.2), speaker: "B"),
        SpeakerWord(word: makeWord("меня", start: 12.3, end: 12.5), speaker: "B"),
    ]
    snapTransitionsToPauses(&words)
    assertEqual(words[2].speaker, "A", "ограниченный should snap back to A")
    assertEqual(words[3].speaker, "B", "у should stay with B (after the pause)")
    assertEqual(words[4].speaker, "B", "меня should stay with B")
}

test("Transition at a pause left alone") {
    // Clear pause (0.5s) at the transition — diarizer probably got it right
    var words: [SpeakerWord] = [
        SpeakerWord(word: makeWord("hello", start: 0, end: 0.3), speaker: "A"),
        SpeakerWord(word: makeWord("there", start: 0.4, end: 0.7), speaker: "A"),
        // 0.5s pause — real turn-taking gap
        SpeakerWord(word: makeWord("yes", start: 1.2, end: 1.4), speaker: "B"),
        SpeakerWord(word: makeWord("indeed", start: 1.5, end: 1.8), speaker: "B"),
    ]
    snapTransitionsToPauses(&words)
    assertEqual(words[0].speaker, "A")
    assertEqual(words[1].speaker, "A")
    assertEqual(words[2].speaker, "B", "transition at pause should not be changed")
    assertEqual(words[3].speaker, "B")
}

test("Word cap limits reassignment") {
    // No pause anywhere, but cap at 3 words prevents runaway reassignment
    var words: [SpeakerWord] = [
        SpeakerWord(word: makeWord("a", start: 0, end: 0.2), speaker: "A"),
        // Transition, no pause (0.1s gap)
        SpeakerWord(word: makeWord("b", start: 0.3, end: 0.5), speaker: "B"),
        SpeakerWord(word: makeWord("c", start: 0.6, end: 0.8), speaker: "B"),
        SpeakerWord(word: makeWord("d", start: 0.9, end: 1.1), speaker: "B"),
        SpeakerWord(word: makeWord("e", start: 1.2, end: 1.4), speaker: "B"),
        SpeakerWord(word: makeWord("f", start: 1.5, end: 1.7), speaker: "B"),
    ]
    snapTransitionsToPauses(&words)
    // No pause found within 3 words, so nothing should be reassigned
    assertEqual(words[1].speaker, "B", "no snap when no pause found within cap")
}

test("Multiple words snapped before pause") {
    // Two words with no pauses, then a pause — both should snap back
    var words: [SpeakerWord] = [
        SpeakerWord(word: makeWord("x", start: 0, end: 0.3), speaker: "A"),
        // Transition, tiny gap
        SpeakerWord(word: makeWord("y", start: 0.35, end: 0.6), speaker: "B"),
        SpeakerWord(word: makeWord("z", start: 0.65, end: 0.9), speaker: "B"),
        // Real pause: 0.5s
        SpeakerWord(word: makeWord("w", start: 1.4, end: 1.7), speaker: "B"),
    ]
    snapTransitionsToPauses(&words)
    assertEqual(words[1].speaker, "A", "y should snap back to A")
    assertEqual(words[2].speaker, "A", "z should snap back to A")
    assertEqual(words[3].speaker, "B", "w stays with B (after pause)")
}

test("No transitions means no changes") {
    var words: [SpeakerWord] = [
        SpeakerWord(word: makeWord("a", start: 0, end: 0.2), speaker: "A"),
        SpeakerWord(word: makeWord("b", start: 0.3, end: 0.5), speaker: "A"),
        SpeakerWord(word: makeWord("c", start: 0.6, end: 0.8), speaker: "A"),
    ]
    snapTransitionsToPauses(&words)
    assertEqual(words[0].speaker, "A")
    assertEqual(words[1].speaker, "A")
    assertEqual(words[2].speaker, "A")
}

test("Nil speakers at transition are skipped") {
    var words: [SpeakerWord] = [
        SpeakerWord(word: makeWord("a", start: 0, end: 0.2), speaker: "A"),
        SpeakerWord(word: makeWord("b", start: 0.25, end: 0.5), speaker: nil),
        SpeakerWord(word: makeWord("c", start: 0.55, end: 0.8), speaker: "B"),
    ]
    snapTransitionsToPauses(&words)
    assertNil(words[1].speaker, "nil speaker should not be touched by snap pass")
}

print("\nNil speaker absorption:")

test("Nil-speaker word inherits nearest neighbor") {
    var words: [SpeakerWord] = [
        SpeakerWord(word: makeWord("hello", start: 0, end: 0.5), speaker: "A"),
        SpeakerWord(word: makeWord("world", start: 0.6, end: 1.0), speaker: nil),
        SpeakerWord(word: makeWord("there", start: 5.0, end: 5.5), speaker: "B"),
    ]
    absorbNilSpeakers(&words)
    assertEqual(words[1].speaker, "A")
}

test("All-nil words remain nil") {
    var words: [SpeakerWord] = [
        SpeakerWord(word: makeWord("a", start: 0, end: 0.5), speaker: nil),
        SpeakerWord(word: makeWord("b", start: 1, end: 1.5), speaker: nil),
    ]
    absorbNilSpeakers(&words)
    assertNil(words[0].speaker)
    assertNil(words[1].speaker)
}

print("\nSpeaker run smoothing:")

test("Short run merged into longer neighbor") {
    // A: 0-1.8s (long), B: 0.9-1.0s (short, 0.1s), A: 1.1-1.8s
    var words: [SpeakerWord] = [
        SpeakerWord(word: makeWord("I", start: 0, end: 0.2), speaker: "A"),
        SpeakerWord(word: makeWord("think", start: 0.3, end: 0.5), speaker: "A"),
        SpeakerWord(word: makeWord("that", start: 0.6, end: 0.8), speaker: "A"),
        SpeakerWord(word: makeWord("the", start: 0.9, end: 1.0), speaker: "B"),
        SpeakerWord(word: makeWord("idea", start: 1.1, end: 1.4), speaker: "A"),
        SpeakerWord(word: makeWord("works", start: 1.5, end: 1.8), speaker: "A"),
    ]
    smoothSpeakerRuns(&words)
    assertEqual(words[3].speaker, "A", "short B run should merge into longer A neighbor")
}

test("Short run between different speakers merges into longer neighbor") {
    // A: 0-0.2s (0.2s), C: 0.3-0.5s (0.2s), B: 0.6-2.5s (1.9s)
    var words: [SpeakerWord] = [
        SpeakerWord(word: makeWord("x", start: 0, end: 0.2), speaker: "A"),
        SpeakerWord(word: makeWord("y", start: 0.3, end: 0.5), speaker: "C"),
        SpeakerWord(word: makeWord("z", start: 0.6, end: 1.5), speaker: "B"),
        SpeakerWord(word: makeWord("w", start: 1.6, end: 2.5), speaker: "B"),
    ]
    smoothSpeakerRuns(&words)
    // A (0.2s) and C (0.2s) are both short; shortest merges into longer neighbor
    // Eventually all short runs merge into B
    assertEqual(words[0].speaker, "B", "A should eventually merge into B")
    assertEqual(words[1].speaker, "B", "C should eventually merge into B")
}

test("Edge run (first) merges into its only neighbor") {
    // B: 0-0.1s (short edge), A: 0.2-2.0s (long)
    var words: [SpeakerWord] = [
        SpeakerWord(word: makeWord("oh", start: 0, end: 0.1), speaker: "B"),
        SpeakerWord(word: makeWord("I", start: 0.2, end: 0.5), speaker: "A"),
        SpeakerWord(word: makeWord("see", start: 0.6, end: 1.0), speaker: "A"),
        SpeakerWord(word: makeWord("now", start: 1.1, end: 2.0), speaker: "A"),
    ]
    smoothSpeakerRuns(&words)
    assertEqual(words[0].speaker, "A", "edge run should merge into only neighbor")
}

test("Edge run (last) merges into its only neighbor") {
    // A: 0-2.0s (long), B: 2.1-2.2s (short edge)
    var words: [SpeakerWord] = [
        SpeakerWord(word: makeWord("that", start: 0, end: 0.5), speaker: "A"),
        SpeakerWord(word: makeWord("is", start: 0.6, end: 1.0), speaker: "A"),
        SpeakerWord(word: makeWord("right", start: 1.1, end: 2.0), speaker: "A"),
        SpeakerWord(word: makeWord("yeah", start: 2.1, end: 2.2), speaker: "B"),
    ]
    smoothSpeakerRuns(&words)
    assertEqual(words[3].speaker, "A", "trailing edge run should merge into only neighbor")
}

test("Multi-pass cascading merges") {
    // A(0.3s) B(0.2s) C(0.3s) D(3.0s) — should cascade: B merges into neighbor,
    // then remaining short runs merge, until all meet threshold or merge into D
    var words: [SpeakerWord] = [
        SpeakerWord(word: makeWord("a", start: 0, end: 0.3), speaker: "A"),
        SpeakerWord(word: makeWord("b", start: 0.4, end: 0.6), speaker: "B"),
        SpeakerWord(word: makeWord("c", start: 0.7, end: 1.0), speaker: "C"),
        SpeakerWord(word: makeWord("d", start: 1.1, end: 2.0), speaker: "D"),
        SpeakerWord(word: makeWord("e", start: 2.1, end: 4.0), speaker: "D"),
    ]
    smoothSpeakerRuns(&words)
    // All short runs should eventually merge into D (the longest)
    assertEqual(words[0].speaker, "D", "cascading merge: A -> D")
    assertEqual(words[1].speaker, "D", "cascading merge: B -> D")
    assertEqual(words[2].speaker, "D", "cascading merge: C -> D")
}

test("Run at exactly threshold is not merged") {
    // A: 0-1.5s (exactly 1.5s = threshold), B: 1.6-5.0s (long)
    var words: [SpeakerWord] = [
        SpeakerWord(word: makeWord("hello", start: 0, end: 0.5), speaker: "A"),
        SpeakerWord(word: makeWord("there", start: 0.6, end: 1.5), speaker: "A"),
        SpeakerWord(word: makeWord("world", start: 1.6, end: 3.0), speaker: "B"),
        SpeakerWord(word: makeWord("now", start: 3.1, end: 5.0), speaker: "B"),
    ]
    smoothSpeakerRuns(&words)
    assertEqual(words[0].speaker, "A", "run at threshold should not be merged")
    assertEqual(words[1].speaker, "A", "run at threshold should not be merged")
}

test("Single word array unchanged") {
    var words: [SpeakerWord] = [
        SpeakerWord(word: makeWord("hi", start: 0, end: 0.1), speaker: "A"),
    ]
    smoothSpeakerRuns(&words)
    assertEqual(words[0].speaker, "A")
}

print("\nFiller word removal:")

test("Common fillers are detected") {
    assert(isFillerWord("um"), "um should be filler")
    assert(isFillerWord("uh"), "uh should be filler")
    assert(isFillerWord("hmm"), "hmm should be filler")
    assert(isFillerWord("er"), "er should be filler")
    assert(isFillerWord("ah"), "ah should be filler")
}

test("Normal words are not fillers") {
    assert(!isFillerWord("hello"), "hello should not be filler")
    assert(!isFillerWord("the"), "the should not be filler")
    assert(!isFillerWord("umber"), "umber should not be filler")
    assert(!isFillerWord("hmmm"), "hmmm (4 m's) should not be filler")
}

test("Punctuated fillers are caught") {
    assert(isFillerWord("um,"), "um, should be filler")
    assert(isFillerWord("uh."), "uh. should be filler")
    assert(isFillerWord("Hmm!"), "Hmm! should be filler")
}

test("Case-insensitive matching") {
    assert(isFillerWord("Um"), "Um should be filler")
    assert(isFillerWord("UH"), "UH should be filler")
    assert(isFillerWord("Hmm"), "Hmm should be filler")
}

test("Fillers stripped from word list by mergeResults") {
    let tokens: [TokenTiming] = [
        TokenTiming(token: " Hello", tokenId: 1, startTime: 0, endTime: 0.5, confidence: 0.9),
        TokenTiming(token: " um", tokenId: 2, startTime: 0.6, endTime: 0.8, confidence: 0.9),
        TokenTiming(token: " world", tokenId: 3, startTime: 1.0, endTime: 1.5, confidence: 0.9),
    ]
    let asr = ASRResult(
        text: "Hello um world", confidence: 0.9, duration: 2.0, processingTime: 0.1,
        tokenTimings: tokens)

    let segments = mergeResults(asrResult: asr, diarizationResult: nil, removeFillerWords: true)
    let text = segments.map(\.text).joined(separator: " ")
    assert(!text.contains("um"), "text should not contain 'um'")
    assert(text.contains("Hello"), "text should contain 'Hello'")
    assert(text.contains("world"), "text should contain 'world'")
}

test("Fillers kept when removeFillerWords is false") {
    let tokens: [TokenTiming] = [
        TokenTiming(token: " Hello", tokenId: 1, startTime: 0, endTime: 0.5, confidence: 0.9),
        TokenTiming(token: " um", tokenId: 2, startTime: 0.6, endTime: 0.8, confidence: 0.9),
        TokenTiming(token: " world", tokenId: 3, startTime: 1.0, endTime: 1.5, confidence: 0.9),
    ]
    let asr = ASRResult(
        text: "Hello um world", confidence: 0.9, duration: 2.0, processingTime: 0.1,
        tokenTimings: tokens)

    let segments = mergeResults(asrResult: asr, diarizationResult: nil, removeFillerWords: false)
    let text = segments.map(\.text).joined(separator: " ")
    assert(text.contains("um"), "text should contain 'um' when filler removal disabled")
}

print("\nSentence-aware grouping:")

test("Sentence boundary + speaker change → clean split") {
    let words: [SpeakerWord] = [
        SpeakerWord(word: makeWord("Hello", start: 0, end: 0.3), speaker: "A"),
        SpeakerWord(word: makeWord("world.", start: 0.4, end: 0.7), speaker: "A"),
        SpeakerWord(word: makeWord("How", start: 0.9, end: 1.1), speaker: "B"),
        SpeakerWord(word: makeWord("are", start: 1.2, end: 1.4), speaker: "B"),
        SpeakerWord(word: makeWord("you?", start: 1.5, end: 1.8), speaker: "B"),
    ]
    let segments = groupBySentenceAndSpeaker(words)
    assertEqual(segments.count, 2, "should produce 2 segments")
    assertEqual(segments[0].text, "Hello world.", "first segment text")
    assertEqual(segments[0].speaker, "A", "first segment speaker")
    assertEqual(segments[1].text, "How are you?", "second segment text")
    assertEqual(segments[1].speaker, "B", "second segment speaker")
}

test("Speaker change mid-sentence → stays merged with majority speaker") {
    // "we can definitely kick off when ready." — A says first 4 words (0-1.6s), B says last 3 (1.7-3.0s)
    // No punctuation until the end, so no sentence boundary mid-way → stays as one segment
    let words: [SpeakerWord] = [
        SpeakerWord(word: makeWord("we", start: 0, end: 0.2), speaker: "A"),
        SpeakerWord(word: makeWord("can", start: 0.3, end: 0.5), speaker: "A"),
        SpeakerWord(word: makeWord("definitely", start: 0.6, end: 1.1), speaker: "A"),
        SpeakerWord(word: makeWord("kick", start: 1.2, end: 1.5), speaker: "A"),
        SpeakerWord(word: makeWord("off", start: 1.58, end: 1.8), speaker: "B"),
        SpeakerWord(word: makeWord("when", start: 1.9, end: 2.1), speaker: "B"),
        SpeakerWord(word: makeWord("ready.", start: 2.2, end: 2.5), speaker: "B"),
    ]
    let segments = groupBySentenceAndSpeaker(words)
    assertEqual(segments.count, 1, "mid-sentence speaker change should not split")
    assertEqual(segments[0].text, "we can definitely kick off when ready.", "full sentence preserved")
    // A: 0-0.2 + 0.3-0.5 + 0.6-1.1 + 1.2-1.5 = 0.2+0.2+0.5+0.3 = 1.2s
    // B: 1.58-1.8 + 1.9-2.1 + 2.2-2.5 = 0.22+0.2+0.3 = 0.72s
    assertEqual(segments[0].speaker, "A", "majority speaker by duration should be A")
}

test("Orphaned word at end becomes its own segment") {
    // "That sounds great." from A, then "Yeah." from B at the very end
    let words: [SpeakerWord] = [
        SpeakerWord(word: makeWord("That", start: 0, end: 0.3), speaker: "A"),
        SpeakerWord(word: makeWord("sounds", start: 0.4, end: 0.7), speaker: "A"),
        SpeakerWord(word: makeWord("great.", start: 0.8, end: 1.2), speaker: "A"),
        SpeakerWord(word: makeWord("Yeah.", start: 1.4, end: 1.7), speaker: "B"),
    ]
    let segments = groupBySentenceAndSpeaker(words)
    // "great." is a sentence boundary and next word is B → split
    assertEqual(segments.count, 2, "should split at sentence boundary + speaker change")
    assertEqual(segments[0].text, "That sounds great.", "first sentence")
    assertEqual(segments[0].speaker, "A", "first segment speaker")
    assertEqual(segments[1].text, "Yeah.", "trailing word")
    assertEqual(segments[1].speaker, "B", "trailing word speaker")
}

test("Pause-based boundary splits even without punctuation") {
    let words: [SpeakerWord] = [
        SpeakerWord(word: makeWord("okay", start: 0, end: 0.3), speaker: "A"),
        SpeakerWord(word: makeWord("sure", start: 0.4, end: 0.7), speaker: "A"),
        // >1s pause to next word, and speaker changes
        SpeakerWord(word: makeWord("right", start: 2.0, end: 2.3), speaker: "B"),
        SpeakerWord(word: makeWord("then", start: 2.4, end: 2.7), speaker: "B"),
    ]
    let segments = groupBySentenceAndSpeaker(words)
    assertEqual(segments.count, 2, "pause + speaker change should split")
    assertEqual(segments[0].text, "okay sure", "first segment")
    assertEqual(segments[0].speaker, "A", "first speaker")
    assertEqual(segments[1].text, "right then", "second segment")
    assertEqual(segments[1].speaker, "B", "second speaker")
}

test("No speaker change at sentence boundary → continues same segment") {
    let words: [SpeakerWord] = [
        SpeakerWord(word: makeWord("Hello", start: 0, end: 0.3), speaker: "A"),
        SpeakerWord(word: makeWord("world.", start: 0.4, end: 0.7), speaker: "A"),
        SpeakerWord(word: makeWord("How", start: 0.9, end: 1.1), speaker: "A"),
        SpeakerWord(word: makeWord("are", start: 1.2, end: 1.4), speaker: "A"),
        SpeakerWord(word: makeWord("you?", start: 1.5, end: 1.8), speaker: "A"),
    ]
    let segments = groupBySentenceAndSpeaker(words)
    assertEqual(segments.count, 1, "same speaker across sentences → one segment")
    assertEqual(segments[0].text, "Hello world. How are you?", "full text")
    assertEqual(segments[0].speaker, "A", "speaker")
}

test("Empty input returns empty") {
    let segments = groupBySentenceAndSpeaker([])
    assertEqual(segments.count, 0, "empty input → empty output")
}

test("Safety cap force-emits at last speaker change") {
    // Build a long sequence >30s with a speaker change in the middle, no punctuation
    var words: [SpeakerWord] = []
    // A speaks for 0-18s (36 words, 0.5s each)
    for i in 0..<36 {
        let start = Double(i) * 0.5
        words.append(SpeakerWord(
            word: makeWord("word\(i)", start: start, end: start + 0.4), speaker: "A"))
    }
    // B speaks for 18-36s (36 words, 0.5s each) — no punctuation anywhere
    for i in 36..<72 {
        let start = Double(i) * 0.5
        words.append(SpeakerWord(
            word: makeWord("word\(i)", start: start, end: start + 0.4), speaker: "B"))
    }
    let segments = groupBySentenceAndSpeaker(words)
    assert(segments.count >= 2, "safety cap should force at least 2 segments for >30s")
    // First segment should end at or before the speaker change
    assertEqual(segments[0].speaker, "A", "first segment should be speaker A")
}

test("Duration-weighted majority attribution") {
    // A has 3 short words (0.2s each = 0.6s total), B has 1 long word (1.5s)
    // B should win by duration despite fewer words
    let words: [SpeakerWord] = [
        SpeakerWord(word: makeWord("I", start: 0, end: 0.2), speaker: "A"),
        SpeakerWord(word: makeWord("think", start: 0.25, end: 0.45), speaker: "A"),
        SpeakerWord(word: makeWord("so", start: 0.5, end: 0.7), speaker: "A"),
        SpeakerWord(word: makeWord("absolutely.", start: 0.8, end: 2.3), speaker: "B"),
    ]
    let segments = groupBySentenceAndSpeaker(words)
    // This is the end of input, so it gets emitted as one segment
    assertEqual(segments.count, 1, "should be one segment")
    // A: 0.2+0.2+0.2 = 0.6s, B: 1.5s → B wins
    assertEqual(segments[0].speaker, "B", "B should win by duration")
}

test("Speaker change at sentence boundary with pause but no punctuation") {
    // Pause >1s acts as sentence boundary even without punctuation
    let words: [SpeakerWord] = [
        SpeakerWord(word: makeWord("yes", start: 0, end: 0.3), speaker: "A"),
        SpeakerWord(word: makeWord("indeed", start: 0.4, end: 0.8), speaker: "A"),
        // 1.5s pause, speaker changes — should split
        SpeakerWord(word: makeWord("so", start: 2.3, end: 2.5), speaker: "B"),
        SpeakerWord(word: makeWord("anyway.", start: 2.6, end: 3.0), speaker: "B"),
    ]
    let segments = groupBySentenceAndSpeaker(words)
    assertEqual(segments.count, 2, "pause + speaker change should split")
    assertEqual(segments[0].speaker, "A")
    assertEqual(segments[1].speaker, "B")
}

print("\nLookahead speaker splits:")

test("Lookahead splits at sentence boundary when speaker change is 2 words ahead") {
    let words: [SpeakerWord] = [
        SpeakerWord(word: makeWord("sounds", start: 0, end: 0.4), speaker: "A"),
        SpeakerWord(word: makeWord("great.", start: 0.5, end: 1.0), speaker: "A"),
        // 0.2s gap (>0.15s), speaker A continues but B is 2 words ahead
        SpeakerWord(word: makeWord("Thank", start: 1.2, end: 1.5), speaker: "A"),
        SpeakerWord(word: makeWord("you", start: 1.6, end: 1.8), speaker: "B"),
        SpeakerWord(word: makeWord("so", start: 1.9, end: 2.1), speaker: "B"),
        SpeakerWord(word: makeWord("much.", start: 2.2, end: 2.5), speaker: "B"),
    ]
    let segments = groupBySentenceAndSpeaker(words)
    assertEqual(segments.count, 2, "lookahead should split at sentence boundary")
    assertEqual(segments[0].text, "sounds great.", "first segment")
    assertEqual(segments[0].speaker, "A", "first speaker")
    assertEqual(segments[1].text, "Thank you so much.", "second segment")
}

test("Lookahead does not split without sufficient gap") {
    let words: [SpeakerWord] = [
        SpeakerWord(word: makeWord("great.", start: 0, end: 0.3), speaker: "A"),
        // Only 0.05s gap (<0.15s) — continuous speech, no lookahead
        SpeakerWord(word: makeWord("Thank", start: 0.35, end: 0.5), speaker: "A"),
        SpeakerWord(word: makeWord("you", start: 0.6, end: 0.8), speaker: "B"),
    ]
    let segments = groupBySentenceAndSpeaker(words)
    assertEqual(segments.count, 1, "no split without sufficient gap")
}

test("Lookahead does not split when no speaker change within window") {
    let words: [SpeakerWord] = [
        SpeakerWord(word: makeWord("great.", start: 0, end: 0.3), speaker: "A"),
        // 0.2s gap, but no speaker change within 3 words
        SpeakerWord(word: makeWord("And", start: 0.5, end: 0.7), speaker: "A"),
        SpeakerWord(word: makeWord("then", start: 0.8, end: 1.0), speaker: "A"),
        SpeakerWord(word: makeWord("we", start: 1.1, end: 1.3), speaker: "A"),
        SpeakerWord(word: makeWord("switch.", start: 1.4, end: 1.7), speaker: "B"),
    ]
    let segments = groupBySentenceAndSpeaker(words)
    // Speaker change is 4 words ahead — beyond the 3-word window
    assertEqual(segments.count, 1, "no split when change is beyond lookahead window")
}

test("Lookahead splits at exactly 3 words ahead") {
    let words: [SpeakerWord] = [
        SpeakerWord(word: makeWord("okay.", start: 0, end: 0.3), speaker: "A"),
        // 0.2s gap, speaker change at 3rd word ahead
        SpeakerWord(word: makeWord("so", start: 0.5, end: 0.6), speaker: "A"),
        SpeakerWord(word: makeWord("yeah", start: 0.65, end: 0.75), speaker: "A"),
        SpeakerWord(word: makeWord("right.", start: 0.8, end: 1.5), speaker: "B"),
    ]
    let segments = groupBySentenceAndSpeaker(words)
    assertEqual(segments.count, 2, "should split — change is within 3-word window")
    assertEqual(segments[0].text, "okay.", "first segment")
    assertEqual(segments[0].speaker, "A", "first speaker")
}

test("Lookahead does not trigger on mid-phrase punctuation without gap") {
    // "Mr. Smith said" — period after "Mr." but no gap
    let words: [SpeakerWord] = [
        SpeakerWord(word: makeWord("Mr.", start: 0, end: 0.2), speaker: "A"),
        // 0.02s gap — continuous speech
        SpeakerWord(word: makeWord("Smith", start: 0.22, end: 0.5), speaker: "A"),
        SpeakerWord(word: makeWord("said", start: 0.55, end: 0.8), speaker: "B"),
    ]
    let segments = groupBySentenceAndSpeaker(words)
    assertEqual(segments.count, 1, "no split on mid-phrase punctuation without gap")
}

print("\nHeal split sentences:")

test("Basic heal: incomplete sentence + completing word reassigned") {
    // "a useful" (A) + "exercise. You know..." (B) → "exercise." reassigned to A
    var words: [SpeakerWord] = [
        SpeakerWord(word: makeWord("a", start: 0, end: 0.2), speaker: "A"),
        SpeakerWord(word: makeWord("useful", start: 0.25, end: 0.6), speaker: "A"),
        // 0.05s gap — continuous speech
        SpeakerWord(word: makeWord("exercise.", start: 0.65, end: 1.0), speaker: "B"),
        SpeakerWord(word: makeWord("You", start: 1.1, end: 1.3), speaker: "B"),
        SpeakerWord(word: makeWord("know,", start: 1.35, end: 1.6), speaker: "B"),
    ]
    healSplitSentences(&words)
    assertEqual(words[2].speaker, "A", "exercise. should heal back to A")
    assertEqual(words[3].speaker, "B", "You should stay with B")
    assertEqual(words[4].speaker, "B", "know should stay with B")
}

test("Heals despite inflated word timings at speaker boundary") {
    // ASR produces inflated durations for first word after speaker transition
    var words: [SpeakerWord] = [
        SpeakerWord(word: makeWord("actual", start: 0, end: 0.3), speaker: "A"),
        SpeakerWord(word: makeWord("administrative", start: 0.35, end: 0.8), speaker: "A"),
        // "reports." has inflated timing (2.0s duration) — typical ASR boundary artifact
        SpeakerWord(word: makeWord("reports.", start: 1.6, end: 3.6), speaker: "B"),
        SpeakerWord(word: makeWord("Or", start: 3.7, end: 3.9), speaker: "B"),
        SpeakerWord(word: makeWord("like", start: 4.0, end: 4.2), speaker: "B"),
    ]
    healSplitSentences(&words)
    assertEqual(words[2].speaker, "A", "reports. should heal to A despite inflated timing")
    assertEqual(words[3].speaker, "B", "Or should stay with B")
}

test("Cap at first punctuation: only first punctuated word healed") {
    // "the" (A) + "big. red. house." (B) → only "big." reassigned
    var words: [SpeakerWord] = [
        SpeakerWord(word: makeWord("the", start: 0, end: 0.2), speaker: "A"),
        SpeakerWord(word: makeWord("big.", start: 0.25, end: 0.4), speaker: "B"),
        SpeakerWord(word: makeWord("red.", start: 0.45, end: 0.6), speaker: "B"),
        SpeakerWord(word: makeWord("house.", start: 0.65, end: 0.8), speaker: "B"),
    ]
    healSplitSentences(&words)
    assertEqual(words[1].speaker, "A", "big. should heal to A")
    assertEqual(words[2].speaker, "B", "red. should stay with B")
    assertEqual(words[3].speaker, "B", "house. should stay with B")
}

test("Previous sentence already complete: no heal") {
    // "okay." (A) + "right." (B) → no reassignment (A already ends with punctuation)
    var words: [SpeakerWord] = [
        SpeakerWord(word: makeWord("okay.", start: 0, end: 0.3), speaker: "A"),
        SpeakerWord(word: makeWord("right.", start: 0.35, end: 0.6), speaker: "B"),
    ]
    healSplitSentences(&words)
    assertEqual(words[1].speaker, "B", "right. should stay with B (prev sentence complete)")
}

test("Backchannel guard: skip when next word returns to previous speaker") {
    // "so it's a useful" (A) + "right." (B) + "concept" (A) → no heal (backchannel)
    var words: [SpeakerWord] = [
        SpeakerWord(word: makeWord("so", start: 0, end: 0.15), speaker: "A"),
        SpeakerWord(word: makeWord("it's", start: 0.2, end: 0.35), speaker: "A"),
        SpeakerWord(word: makeWord("a", start: 0.4, end: 0.5), speaker: "A"),
        SpeakerWord(word: makeWord("useful", start: 0.55, end: 0.8), speaker: "A"),
        // 0.05s gap
        SpeakerWord(word: makeWord("right.", start: 0.85, end: 1.0), speaker: "B"),
        // Returns to A — backchannel
        SpeakerWord(word: makeWord("concept", start: 1.1, end: 1.4), speaker: "A"),
    ]
    healSplitSentences(&words)
    assertEqual(words[4].speaker, "B", "right. should stay with B (backchannel guard)")
}

test("Multi-word heal: two completing words reassigned") {
    // "a useful" (A) + "exercise complete." (B) → both reassigned to A
    var words: [SpeakerWord] = [
        SpeakerWord(word: makeWord("a", start: 0, end: 0.2), speaker: "A"),
        SpeakerWord(word: makeWord("useful", start: 0.25, end: 0.5), speaker: "A"),
        SpeakerWord(word: makeWord("exercise", start: 0.55, end: 0.8), speaker: "B"),
        SpeakerWord(word: makeWord("complete.", start: 0.85, end: 1.1), speaker: "B"),
        SpeakerWord(word: makeWord("Now", start: 1.2, end: 1.4), speaker: "B"),
    ]
    healSplitSentences(&words)
    assertEqual(words[2].speaker, "A", "exercise should heal to A")
    assertEqual(words[3].speaker, "A", "complete. should heal to A")
    assertEqual(words[4].speaker, "B", "Now should stay with B")
}

test("3-word cap: no punctuation within 3 words means no heal") {
    // "so it's a" (A) + "very interesting and remarkable exercise." (B)
    // "exercise." has punctuation but is the 5th word — beyond 3-word scan
    var words: [SpeakerWord] = [
        SpeakerWord(word: makeWord("a", start: 0, end: 0.2), speaker: "A"),
        SpeakerWord(word: makeWord("very", start: 0.25, end: 0.4), speaker: "B"),
        SpeakerWord(word: makeWord("interesting", start: 0.45, end: 0.7), speaker: "B"),
        SpeakerWord(word: makeWord("and", start: 0.75, end: 0.85), speaker: "B"),
        SpeakerWord(word: makeWord("remarkable", start: 0.9, end: 1.2), speaker: "B"),
        SpeakerWord(word: makeWord("exercise.", start: 1.25, end: 1.5), speaker: "B"),
    ]
    healSplitSentences(&words)
    assertEqual(words[1].speaker, "B", "very should stay B (punctuation beyond 3-word cap)")
}

// MARK: - Summary

print("\n\(passed) passed, \(failed) failed")
if failed > 0 {
    Foundation.exit(1)
}
