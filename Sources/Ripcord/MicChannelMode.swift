import Foundation

/// How a multi-channel input device's channels are captured into our stereo
/// internal representation. Stored per device UID.
enum MicChannelMode: Equatable {
    /// Treat device channels 1 and 2 as the L/R pair.
    case stereo
    /// Capture only a single channel (1-indexed). Internally duplicated to L=R.
    case mono(channel: Int)

    /// Default mode for a freshly-seen device. Mono channel 1 is the safe
    /// choice: matches what most DAWs do with stereo inputs and avoids the
    /// phase-cancellation trap that AUHAL's 2→1 average mixdown can hit on
    /// differential USB sources (the USB audio device case).
    static let defaultForMultiChannel: MicChannelMode = .mono(channel: 1)

    /// Mono devices always capture their single channel; no user choice.
    static let monoDevice: MicChannelMode = .mono(channel: 1)

    // MARK: - String encoding for UserDefaults storage
    // "stereo" or "mono:N"

    var encoded: String {
        switch self {
        case .stereo: return "stereo"
        case .mono(let ch): return "mono:\(ch)"
        }
    }

    init?(encoded: String) {
        if encoded == "stereo" { self = .stereo; return }
        let parts = encoded.split(separator: ":", maxSplits: 1)
        if parts.count == 2, parts[0] == "mono", let ch = Int(parts[1]), ch >= 1 {
            self = .mono(channel: ch)
            return
        }
        return nil
    }
}

/// Per-device-UID persistence of MicChannelMode in UserDefaults.
/// Stored as [uid: encodedMode]. Devices not present in the dict use the default.
final class MicChannelModeStore {
    private let key: String
    private let defaults: UserDefaults

    init(key: String = "ripcord.micChannelModes", defaults: UserDefaults = .standard) {
        self.key = key
        self.defaults = defaults
    }

    /// Mode for `uid`. Returns `.monoDevice` for 1-channel devices regardless
    /// of stored value (single-channel devices have no real choice).
    func mode(forUID uid: String, channelCount: Int) -> MicChannelMode {
        guard channelCount > 1 else { return .monoDevice }
        let dict = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        if let encoded = dict[uid], let mode = MicChannelMode(encoded: encoded) {
            // Clamp mono channel to device's actual channel count
            if case .mono(let ch) = mode, ch > channelCount {
                return .defaultForMultiChannel
            }
            return mode
        }
        return .defaultForMultiChannel
    }

    func setMode(_ mode: MicChannelMode, forUID uid: String) {
        var dict = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        dict[uid] = mode.encoded
        defaults.set(dict, forKey: key)
    }
}
