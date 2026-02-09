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

// MARK: - Summary

print("\n\(passed) passed, \(failed) failed")
if failed > 0 {
    Foundation.exit(1)
}
