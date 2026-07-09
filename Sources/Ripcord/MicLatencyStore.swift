import Foundation

struct MicLatencySettings: Codable, Equatable, Sendable {
    var autoEnabled: Bool = false
    var manualOffsetMs: Double = 0
    var manualTrimMs: Double = 0
}

final class MicLatencyStore {
    private let key: String
    private let defaults: UserDefaults
    private static let range: ClosedRange<Double> = -250...250

    init(key: String = "ripcord.micLatencySettings", defaults: UserDefaults = .standard) {
        self.key = key
        self.defaults = defaults
    }

    func settings(forUID uid: String) -> MicLatencySettings {
        dictionary()[uid] ?? MicLatencySettings()
    }

    func allSettings() -> [String: MicLatencySettings] {
        dictionary()
    }

    func setSettings(_ settings: MicLatencySettings, forUID uid: String) {
        var dict = dictionary()
        dict[uid] = Self.clamped(settings)
        save(dict)
    }

    func setAutoEnabled(_ enabled: Bool, forUID uid: String) {
        var settings = settings(forUID: uid)
        settings.autoEnabled = enabled
        setSettings(settings, forUID: uid)
    }

    func setManualOffsetMs(_ value: Double, forUID uid: String) {
        var settings = settings(forUID: uid)
        settings.manualOffsetMs = Self.clamp(value)
        setSettings(settings, forUID: uid)
    }

    func setManualTrimMs(_ value: Double, forUID uid: String) {
        var settings = settings(forUID: uid)
        settings.manualTrimMs = Self.clamp(value)
        setSettings(settings, forUID: uid)
    }

    static func clamp(_ value: Double) -> Double {
        min(range.upperBound, max(range.lowerBound, value))
    }

    private static func clamped(_ settings: MicLatencySettings) -> MicLatencySettings {
        MicLatencySettings(
            autoEnabled: settings.autoEnabled,
            manualOffsetMs: clamp(settings.manualOffsetMs),
            manualTrimMs: clamp(settings.manualTrimMs)
        )
    }

    private func dictionary() -> [String: MicLatencySettings] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: MicLatencySettings].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private func save(_ dict: [String: MicLatencySettings]) {
        guard let data = try? JSONEncoder().encode(dict) else { return }
        defaults.set(data, forKey: key)
    }
}
