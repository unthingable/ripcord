import Foundation

public struct SpeakerMatchResult: Sendable {
    public let matched: [String: SpeakerProfile]   // rawID -> matched profile
    public let unmatched: [String: [Float]]          // rawID -> embedding (no profile matched)
}

public enum SpeakerMatcher {
    /// L2-normalizes a vector in place; returns the input unchanged if its norm is zero.
    public static func l2Normalize(_ v: [Float]) -> [Float] {
        var norm: Float = 0
        for x in v { norm += x * x }
        norm = sqrt(norm)
        guard norm > 0 else { return v }
        return v.map { $0 / norm }
    }

    /// Cosine similarity between two L2-normalized embeddings (= dot product).
    public static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
        }
        return dot
    }

    /// Match new speaker embeddings against stored profiles using greedy best-match.
    /// Each new speaker and each profile matches at most once.
    public static func match(
        embeddings: [String: [Float]],
        profiles: [SpeakerProfile],
        threshold: Float = 0.75
    ) -> SpeakerMatchResult {
        guard !embeddings.isEmpty, !profiles.isEmpty else {
            return SpeakerMatchResult(matched: [:], unmatched: embeddings)
        }

        // Build all (rawID, profile, similarity) triples above threshold
        var candidates: [(rawID: String, profile: SpeakerProfile, similarity: Float)] = []
        for (rawID, embedding) in embeddings {
            for profile in profiles {
                let sim = cosineSimilarity(embedding, profile.embedding)
                if sim >= threshold {
                    candidates.append((rawID, profile, sim))
                }
            }
        }

        // Sort descending by similarity for greedy assignment
        candidates.sort { $0.similarity > $1.similarity }

        var matched: [String: SpeakerProfile] = [:]
        var usedRawIDs: Set<String> = []
        var usedProfileIDs: Set<UUID> = []

        for candidate in candidates {
            guard !usedRawIDs.contains(candidate.rawID),
                  !usedProfileIDs.contains(candidate.profile.id) else { continue }
            matched[candidate.rawID] = candidate.profile
            usedRawIDs.insert(candidate.rawID)
            usedProfileIDs.insert(candidate.profile.id)
        }

        // Unmatched: embeddings with no profile match
        var unmatched: [String: [Float]] = [:]
        for (rawID, embedding) in embeddings where !usedRawIDs.contains(rawID) {
            unmatched[rawID] = embedding
        }

        return SpeakerMatchResult(matched: matched, unmatched: unmatched)
    }

    /// Substitute speaker names in segments using rawID -> name mapping.
    public static func remapSegments(
        _ segments: [TranscriptSegment],
        mapping: [String: String]
    ) -> [TranscriptSegment] {
        guard !mapping.isEmpty else { return segments }
        return segments.map { seg in
            guard let speaker = seg.speaker, let name = mapping[speaker] else { return seg }
            return TranscriptSegment(start: seg.start, end: seg.end, text: seg.text, speaker: name)
        }
    }
}
