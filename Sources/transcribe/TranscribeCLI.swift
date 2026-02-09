import ArgumentParser
import Foundation
import TranscribeKit

extension ModelVersion: ExpressibleByArgument {}
extension OutputFormat: ExpressibleByArgument {}

/// Print a message to stderr (progress/status output).
func log(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

@main
struct TranscribeCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "transcribe",
        abstract: "Transcribe audio with speaker diarization using FluidAudio")

    @Argument(help: "Path to audio file")
    var audioFile: String

    @Option(name: .long, help: "ASR model version (default: v3)")
    var model: ModelVersion = .v3

    @Option(name: .customLong("format"), help: "Output format: txt, md, json, srt, vtt")
    var outputFormat: OutputFormat = .txt

    @Option(name: [.short, .long], help: "Output file path")
    var output: String?

    @Flag(name: .customLong("no-diarize"), help: "Skip speaker diarization")
    var noDiarize: Bool = false

    @Option(name: .customLong("min-speakers"), help: "Minimum speaker count hint")
    var minSpeakers: Int?

    @Option(name: .customLong("max-speakers"), help: "Maximum speaker count hint")
    var maxSpeakers: Int?

    @Option(name: .customLong("num-speakers"), help: "Exact speaker count (overrides min/max)")
    var numSpeakers: Int?

    @Option(name: .long, help: "Diarization sensitivity 0.0-1.0 (higher = more speakers)")
    var sensitivity: Double?

    @Option(name: .customLong("speech-threshold"), help: "Speech detection threshold 0.0-1.0 (lower = more sensitive)")
    var speechThreshold: Float?

    @Option(name: .customLong("min-segment"), help: "Minimum segment duration in seconds")
    var minSegment: Double?

    @Option(name: .customLong("min-gap"), help: "Minimum gap duration in seconds")
    var minGap: Double?

    @Flag(name: .customLong("fast"), help: "Use fast diarization quality (default: balanced)")
    var fast: Bool = false

    @Flag(name: .customLong("remove-fillers"), help: "Remove filler words (um, uh, etc.)")
    var removeFillers: Bool = false

    @Flag(name: .customLong("force"), help: "Overwrite existing output file")
    var force: Bool = false

    @Option(name: .long, help: "Time range as start-end (e.g. 5:00-7:30, 300-450, 5:00-)")
    var range: String?

    @Flag(name: [.short, .customLong("verbose")], help: "Print performance metrics")
    var verbose: Bool = false

    mutating func run() async throws {
        let audioURL = URL(fileURLWithPath: audioFile)
        guard FileManager.default.fileExists(atPath: audioFile) else {
            throw ValidationError("Audio file not found: \(audioFile)")
        }

        let outputPath = output ?? deriveOutputPath(audioFile: audioFile, format: outputFormat)

        // Validate ranges
        if let s = sensitivity, s <= 0.0 || s > 1.0 {
            throw ValidationError("--sensitivity must be in (0.0, 1.0]")
        }
        if let t = speechThreshold, t <= 0.0 || t > 1.0 {
            throw ValidationError("--speech-threshold must be in (0.0, 1.0]")
        }

        // 1. Prepare models
        log("Loading ASR models (\(model.rawValue))...")
        let transcriber = Transcriber()
        try await transcriber.prepareModels(version: model) { progress in
            if progress >= 0.5 {
                log("Models loaded, preparing diarization...")
            }
        }

        // 2. Build diarization config
        let diarization: DiarizationConfig?
        if noDiarize {
            diarization = nil
        } else {
            let speakerCount: SpeakerCount
            if let n = numSpeakers {
                speakerCount = .exactly(n)
            } else if minSpeakers != nil || maxSpeakers != nil {
                speakerCount = .range(min: minSpeakers, max: maxSpeakers)
            } else {
                speakerCount = .auto
            }
            diarization = DiarizationConfig(
                quality: fast ? .fast : .balanced,
                clusteringThreshold: sensitivity,
                speakerCount: speakerCount,
                speechThreshold: speechThreshold,
                minSegmentDuration: minSegment,
                minGapDuration: minGap,
                removeFillerWords: removeFillers
            )
        }

        // 3. Parse time range (start-end, start-, or -end; times as seconds or MM:SS)
        var startTime: Double?
        var endTime: Double?
        if let range {
            let parts = range.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else {
                throw ValidationError("--range must be start-end (e.g. 5:00-7:30, 300-450, 5:00-)")
            }
            let s = parts[0].isEmpty ? nil : parseTime(String(parts[0]))
            let e = parts[1].isEmpty ? nil : parseTime(String(parts[1]))
            if (!parts[0].isEmpty && s == nil) || (!parts[1].isEmpty && e == nil) {
                throw ValidationError("--range times must be seconds or MM:SS (e.g. 300, 5:00)")
            }
            if let s, let e, s >= e {
                throw ValidationError("--range start must be less than end")
            }
            startTime = s
            endTime = e
            let sDesc = s.map { formatTimeCompact($0) } ?? "start"
            let eDesc = e.map { formatTimeCompact($0) } ?? "end"
            log("Range: \(sDesc) – \(eDesc)")
        }

        log("Transcribing \(audioFile)...")
        let result = try await transcriber.transcribe(
            fileURL: audioURL, diarization: diarization,
            startTime: startTime, endTime: endTime)
        log("Duration: \(String(format: "%.1f", result.duration))s")
        if !result.speakers.isEmpty {
            log("Found \(result.speakers.count) speakers: \(result.speakers.joined(separator: ", "))")
        }

        // 4. Format and write output
        let metadata = TranscriptMetadata(
            duration: result.duration,
            speakers: result.speakers,
            sourceFile: audioFile)

        let formatted = formatOutput(
            segments: result.segments, metadata: metadata, format: outputFormat)

        let finalOutputPath: String
        if force {
            finalOutputPath = outputPath
        } else {
            let outputURL = URL(fileURLWithPath: outputPath)
            finalOutputPath = uniqueFileURL(for: outputURL).path
        }
        try formatted.write(toFile: finalOutputPath, atomically: true, encoding: .utf8)

        log("Output: \(finalOutputPath)")
        transcriber.cleanup()
    }
}

private func deriveOutputPath(audioFile: String, format: OutputFormat) -> String {
    let url = URL(fileURLWithPath: audioFile)
    let base = url.deletingPathExtension().path
    return "\(base).\(format.rawValue)"
}

/// Parse a time string as seconds (e.g. "300", "5:00", "1:23:45").
private func parseTime(_ str: String) -> Double? {
    let parts = str.split(separator: ":")
    switch parts.count {
    case 1:
        return Double(parts[0])
    case 2:
        guard let m = Double(parts[0]), let s = Double(parts[1]) else { return nil }
        return m * 60 + s
    case 3:
        guard let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2]) else { return nil }
        return h * 3600 + m * 60 + s
    default:
        return nil
    }
}

private func formatTimeCompact(_ seconds: Double) -> String {
    let m = Int(seconds) / 60
    let s = Int(seconds) % 60
    return m > 0 ? String(format: "%d:%02d", m, s) : String(format: "%ds", s)
}
