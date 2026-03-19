import Foundation
import Observation
import TranscribeKit

@Observable
final class SpeakerProfileStore {
    var profiles: [SpeakerProfile] = []

    private let fileURL: URL

    init(directory: URL) {
        self.fileURL = directory.appendingPathComponent("speakers.json")
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([SpeakerProfile].self, from: data)
        else { return }
        profiles = decoded
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(profiles) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    func addProfile(_ profile: SpeakerProfile) {
        profiles.append(profile)
        save()
    }

    func removeProfile(id: UUID) {
        profiles.removeAll { $0.id == id }
        save()
    }

    /// Running average update: new = (old * count + observation) / (count+1), then L2-normalize.
    func updateEmbedding(id: UUID, newEmbedding: [Float]) {
        guard let idx = profiles.firstIndex(where: { $0.id == id }) else { return }
        let old = profiles[idx].embedding
        let count = Float(profiles[idx].observationCount)
        guard old.count == newEmbedding.count else { return }

        var averaged = [Float](repeating: 0, count: old.count)
        for i in 0..<old.count {
            averaged[i] = (old[i] * count + newEmbedding[i]) / (count + 1)
        }

        profiles[idx].embedding = SpeakerMatcher.l2Normalize(averaged)
        profiles[idx].observationCount += 1
        save()
    }
}
