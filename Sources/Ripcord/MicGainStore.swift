import Foundation

/// Per-device-UID input gain in dB. Some USB audio interfaces (e.g. Roland
/// USB audio device) output at "instrument send" levels that read at ~-60 dB through
/// HAL — much quieter than what e.g. AVCaptureSession sees. A per-device
/// gain lets the user compensate without affecting devices that don't need it.
final class MicGainStore {
    private let key: String
    private let defaults: UserDefaults

    init(key: String = "ripcord.micGainDB", defaults: UserDefaults = .standard) {
        self.key = key
        self.defaults = defaults
    }

    /// Returns 0 dB (unity) if no value has been set for `uid`.
    func gainDB(forUID uid: String) -> Double {
        let dict = defaults.dictionary(forKey: key) as? [String: Double] ?? [:]
        return dict[uid] ?? 0
    }

    func setGainDB(_ dB: Double, forUID uid: String) {
        var dict = defaults.dictionary(forKey: key) as? [String: Double] ?? [:]
        // Clamp to sensible range so a typo can't blow the writer's ears.
        let clamped = max(-60, min(80, dB))
        dict[uid] = clamped
        defaults.set(dict, forKey: key)
    }

    /// Convert dB to a linear amplitude multiplier.
    static func linearMultiplier(forDB dB: Double) -> Float {
        Float(pow(10.0, dB / 20.0))
    }
}
