import Foundation

/// Generates a unique file URL by appending numeric suffixes if the file already exists.
/// - Parameter url: The desired output URL
/// - Returns: The original URL if it doesn't exist, or a modified URL with `-1`, `-2`, etc. appended to the filename
public func uniqueFileURL(for url: URL) -> URL {
    let fm = FileManager.default
    guard fm.fileExists(atPath: url.path) else { return url }

    let dir = url.deletingLastPathComponent()
    let stem = url.deletingPathExtension().lastPathComponent
    let ext = url.pathExtension

    var i = 1
    while true {
        let candidate = dir.appendingPathComponent("\(stem)-\(i).\(ext)")
        if !fm.fileExists(atPath: candidate.path) { return candidate }
        i += 1
    }
}
