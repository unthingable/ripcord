import Foundation
import os.log

private let logger = Logger(subsystem: "com.vibe.ripcord", category: "UpdateChecker")

@Observable
@MainActor
final class UpdateChecker {
    var latestVersion: String?

    private let repo = "unthingable/ripcord"
    private let checkInterval: TimeInterval = 4 * 3600  // 4 hours
    private var lastCheck: Date = .distantPast

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    /// Non-nil when a newer version is available.
    var availableUpdate: String? {
        guard let latest = latestVersion else { return nil }
        // Strip leading "v" for comparison
        let current = currentVersion.split(separator: "-").first.map(String.init) ?? currentVersion
        let remote = latest.hasPrefix("v") ? String(latest.dropFirst()) : latest
        guard remote != current else { return nil }
        // Simple numeric comparison
        if compareVersions(remote, isNewerThan: current) {
            return latest
        }
        return nil
    }

    var installCommand: String {
        "curl -fsSL https://raw.githubusercontent.com/\(repo)/main/install.sh | bash"
    }

    func checkIfNeeded() {
        guard Date().timeIntervalSince(lastCheck) > checkInterval else { return }
        Task { await check() }
    }

    func check() async {
        lastCheck = Date()
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let tag = json["tag_name"] as? String {
                latestVersion = tag
                if let update = availableUpdate {
                    logger.info("Update available: \(update)")
                }
            }
        } catch {
            logger.error("Update check failed: \(error.localizedDescription)")
        }
    }

    private func compareVersions(_ a: String, isNewerThan b: String) -> Bool {
        let partsA = a.split(separator: ".").compactMap { Int($0) }
        let partsB = b.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(partsA.count, partsB.count) {
            let va = i < partsA.count ? partsA[i] : 0
            let vb = i < partsB.count ? partsB[i] : 0
            if va != vb { return va > vb }
        }
        return false
    }
}
