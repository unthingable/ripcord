import Foundation

// MARK: - Timestamp helpers

public func formatTimestamp(_ seconds: Double) -> String {
    let total = Int(seconds)
    let m = total / 60
    let s = total % 60
    return String(format: "%02d:%02d", m, s)
}

private func formatTimestampSRT(_ seconds: Double) -> String {
    let h = Int(seconds / 3600)
    let m = Int(seconds.truncatingRemainder(dividingBy: 3600) / 60)
    let s = Int(seconds.truncatingRemainder(dividingBy: 60))
    let ms = Int((seconds - Double(Int(seconds))) * 1000)
    return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
}

private func formatTimestampVTT(_ seconds: Double) -> String {
    let h = Int(seconds / 3600)
    let m = Int(seconds.truncatingRemainder(dividingBy: 3600) / 60)
    let s = Int(seconds.truncatingRemainder(dividingBy: 60))
    let ms = Int((seconds - Double(Int(seconds))) * 1000)
    return String(format: "%02d:%02d:%02d.%03d", h, m, s, ms)
}

public func formatDuration(_ seconds: Double) -> String {
    let total = Int(seconds)
    let m = total / 60
    let s = total % 60
    if m >= 60 {
        let h = m / 60
        let rm = m % 60
        return String(format: "%dh %02dm %02ds", h, rm, s)
    }
    return String(format: "%dm %02ds", m, s)
}

// MARK: - Speaker Grouping

private struct SpeakerGroup {
    let speaker: String?
    let start: Double
    let text: String
}

private func groupBySpeaker(_ segments: [TranscriptSegment]) -> [SpeakerGroup] {
    var groups: [SpeakerGroup] = []
    var currentSpeaker: String?
    var currentTexts: [String] = []
    var currentStart: Double?

    for seg in segments {
        if seg.speaker != currentSpeaker {
            if !currentTexts.isEmpty {
                groups.append(SpeakerGroup(
                    speaker: currentSpeaker, start: currentStart ?? 0,
                    text: currentTexts.joined(separator: " ")))
            }
            currentSpeaker = seg.speaker
            currentTexts = []
            currentStart = seg.start
        }
        currentTexts.append(seg.text)
    }

    if !currentTexts.isEmpty {
        groups.append(SpeakerGroup(
            speaker: currentSpeaker, start: currentStart ?? 0,
            text: currentTexts.joined(separator: " ")))
    }

    return groups
}

// MARK: - Format dispatch

public func formatOutput(
    segments: [TranscriptSegment],
    metadata: TranscriptMetadata,
    format: OutputFormat
) -> String {
    switch format {
    case .txt: return formatTxt(segments: segments, metadata: metadata)
    case .md: return formatMd(segments: segments, metadata: metadata)
    case .json: return formatJson(segments: segments, metadata: metadata)
    case .srt: return formatSrt(segments: segments, metadata: metadata)
    case .vtt: return formatVtt(segments: segments, metadata: metadata)
    }
}

// MARK: - Plain text

private func formatTxt(segments: [TranscriptSegment], metadata: TranscriptMetadata) -> String {
    var lines: [String] = []
    let hasSpeakers = segments.contains { $0.speaker != nil }

    if hasSpeakers {
        for group in groupBySpeaker(segments) {
            let ts = formatTimestamp(group.start)
            lines.append("[\(ts)] \(group.speaker ?? "Unknown"):")
            lines.append("  \(group.text)")
            lines.append("")
        }
    } else {
        for seg in segments {
            lines.append("[\(formatTimestamp(seg.start))] \(seg.text)")
        }
    }

    return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
}

// MARK: - Markdown

private func formatMd(segments: [TranscriptSegment], metadata: TranscriptMetadata) -> String {
    let source = URL(fileURLWithPath: metadata.sourceFile).lastPathComponent
    var lines = [
        "# Transcript: \(source)",
        "",
        "- **Duration:** \(formatDuration(metadata.duration))",
    ]
    if !metadata.speakers.isEmpty {
        lines.append("- **Speakers:** \(metadata.speakers.count)")
    }
    lines.append(contentsOf: ["", "---", ""])

    let hasSpeakers = segments.contains { $0.speaker != nil }

    if hasSpeakers {
        for group in groupBySpeaker(segments) {
            let ts = formatTimestamp(group.start)
            lines.append("**\(group.speaker ?? "Unknown")** \u{2014} \(ts)")
            lines.append("")
            lines.append(group.text)
            lines.append("")
        }
    } else {
        for seg in segments {
            lines.append("**\(formatTimestamp(seg.start))**")
            lines.append("")
            lines.append(seg.text)
            lines.append("")
        }
    }

    return lines.joined(separator: "\n")
}

// MARK: - JSON

private struct JsonSegment: Codable {
    let start: Double
    let end: Double
    let text: String
    let speaker: String?
}

private struct JsonMetadata: Codable {
    let duration: Double
    let speakers: [String]
    let source_file: String
}

private struct JsonOutput: Codable {
    let metadata: JsonMetadata
    let segments: [JsonSegment]
}

private func formatJson(segments: [TranscriptSegment], metadata: TranscriptMetadata) -> String {
    let output = JsonOutput(
        metadata: JsonMetadata(
            duration: metadata.duration,
            speakers: metadata.speakers,
            source_file: metadata.sourceFile),
        segments: segments.map { seg in
            JsonSegment(start: seg.start, end: seg.end, text: seg.text, speaker: seg.speaker)
        })
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(output),
        let str = String(data: data, encoding: .utf8)
    else {
        return "{}\n"
    }
    return str + "\n"
}

// MARK: - SRT

private func formatSrt(segments: [TranscriptSegment], metadata: TranscriptMetadata) -> String {
    var lines: [String] = []
    for (i, seg) in segments.enumerated() {
        let start = formatTimestampSRT(seg.start)
        let end = formatTimestampSRT(seg.end)
        var text = seg.text
        if let speaker = seg.speaker {
            text = "[\(speaker)] \(text)"
        }
        lines.append("\(i + 1)")
        lines.append("\(start) --> \(end)")
        lines.append(text)
        lines.append("")
    }
    return lines.joined(separator: "\n")
}

// MARK: - VTT

private func formatVtt(segments: [TranscriptSegment], metadata: TranscriptMetadata) -> String {
    var lines = ["WEBVTT", ""]
    for seg in segments {
        let start = formatTimestampVTT(seg.start)
        let end = formatTimestampVTT(seg.end)
        let text: String
        if let speaker = seg.speaker {
            text = "<v \(speaker)>\(seg.text)"
        } else {
            text = seg.text
        }
        lines.append("\(start) --> \(end)")
        lines.append(text)
        lines.append("")
    }
    return lines.joined(separator: "\n")
}
