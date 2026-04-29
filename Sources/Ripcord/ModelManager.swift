import Foundation
import TranscribeKit

struct InstalledModel: Identifiable {
    let id: String
    let name: String
    let sizeBytes: Int64
    let path: URL
    let isUsed: Bool
}

struct ModelManager {
    private static let modelsRoot: URL = {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("FluidAudio", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }()

    /// Known model directories and their display names.
    private static let knownModels: [(id: String, folder: String, name: String)] = [
        ("asr-v3", "parakeet-tdt-0.6b-v3-coreml", "ASR v3 (Multilingual)"),
        ("asr-v2", "parakeet-tdt-0.6b-v2-coreml", "ASR v2 (English)"),
        ("diarizer", "speaker-diarization-coreml", "Pyannote Diarizer"),
        ("lseend", "ls-eend", "LS-EEND Diarizer"),
        ("sortformer", "sortformer", "Sortformer Diarizer"),
    ]

    static func installedModels(config: TranscriptionConfig) -> [InstalledModel] {
        let fm = FileManager.default
        var results: [InstalledModel] = []

        let usedASR = config.asrModelVersion == .v3 ? "asr-v3" : "asr-v2"
        let engine = config.diarizationEngine

        for entry in knownModels {
            let dir = modelsRoot.appendingPathComponent(entry.folder)
            guard fm.fileExists(atPath: dir.path) else { continue }
            let size = directorySize(dir)
            let isUsed: Bool
            switch entry.id {
            case "asr-v3", "asr-v2":
                isUsed = entry.id == usedASR
            case "diarizer":
                isUsed = true
            case "lseend":
                isUsed = engine == .lseend
            case "sortformer":
                isUsed = engine == .sortformer
            default:
                isUsed = false
            }
            results.append(InstalledModel(
                id: entry.id, name: entry.name,
                sizeBytes: size, path: dir, isUsed: isUsed))
        }

        return results
    }

    static func deleteModel(_ model: InstalledModel) throws {
        try FileManager.default.removeItem(at: model.path)
    }

    private static func directorySize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }
}
