import AVFoundation
import Foundation

/// Offline renderer for finalized-recording drafts. It deliberately writes a
/// fresh sibling file through AudioFileWriter; the target is never truncated
/// or rewritten in place.
enum AudioEditRenderer {
    static func render(from source: URL, originalCrop: ClosedRange<Double>?, prefix: [Float], suffix: [Float],
                       to staging: URL, format: AudioOutputFormat, quality: AudioQuality) throws -> RecordingInfo {
        let writer = AudioFileWriter(url: staging, format: format, quality: quality)
        try writer.open()
        do {
            if !prefix.isEmpty { try writer.append(samples: prefix) }
            if let originalCrop {
                try appendCrop(from: source, seconds: originalCrop, to: writer)
            }
            if !suffix.isEmpty { try writer.append(samples: suffix) }
            let info = try writer.finalize()
            guard info.duration > 0, FileManager.default.fileExists(atPath: staging.path) else { throw RenderError.verificationFailed }
            return info
        } catch {
            _ = try? writer.finalize()
            throw error
        }
    }

    private static func appendCrop(from source: URL, seconds: ClosedRange<Double>,
                                   to writer: AudioFileWriter) throws {
        let file = try AVAudioFile(forReading: source, commonFormat: .pcmFormatFloat32, interleaved: false)
        let inputRate = file.processingFormat.sampleRate
        let channels = Int(file.processingFormat.channelCount)
        guard inputRate > 0, channels > 0 else { throw RenderError.invalidInput }
        let start = max(0, Int64((seconds.lowerBound * inputRate).rounded(.down)))
        let end = min(file.length, Int64((seconds.upperBound * inputRate).rounded(.up)))
        guard end > start else { throw RenderError.emptySelection }
        file.framePosition = start
        guard let outputFormat = AVAudioFormat(
            standardFormatWithSampleRate: AudioConstants.sampleRate,
            channels: 2
        ), let converter = AVAudioConverter(
            from: file.processingFormat,
            to: outputFormat
        ) else { throw RenderError.invalidInput }
        var remaining = end - start
        let inputChunkFrames = AVAudioFrameCount(max(1, Int(inputRate)))
        while remaining > 0 {
            let requested = AVAudioFrameCount(min(Int64(inputChunkFrames), remaining))
            guard let input = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: requested
            ) else { throw RenderError.invalidInput }
            try file.read(into: input, frameCount: requested)
            guard input.frameLength > 0 else { break }
            remaining -= Int64(input.frameLength)

            let outputCapacity = AVAudioFrameCount(
                max(
                    1,
                    Int(ceil(
                        Double(input.frameLength) * AudioConstants.sampleRate / inputRate
                    )) + 32
                )
            )
            converter.reset()
            var supplied = false
            while true {
                guard let output = AVAudioPCMBuffer(
                    pcmFormat: outputFormat,
                    frameCapacity: outputCapacity
                ) else { throw RenderError.invalidInput }
                var conversionError: NSError?
                let status = converter.convert(to: output, error: &conversionError) {
                    _, inputStatus in
                    if supplied {
                        inputStatus.pointee = .endOfStream
                        return nil
                    }
                    supplied = true
                    inputStatus.pointee = .haveData
                    return input
                }
                guard status != .error, conversionError == nil else {
                    if let conversionError { throw conversionError }
                    throw RenderError.invalidInput
                }
                if let channelData = output.floatChannelData, output.frameLength > 0 {
                    let outputFrames = Int(output.frameLength)
                    var stereo = [Float](repeating: 0, count: outputFrames * 2)
                    for frame in 0..<outputFrames {
                        stereo[frame * 2] = channelData[0][frame]
                        stereo[frame * 2 + 1] = channelData[1][frame]
                    }
                    try writer.append(samples: stereo)
                }
                if status == .endOfStream { break }
            }
        }
    }

    enum RenderError: LocalizedError {
        case invalidInput, emptySelection, verificationFailed, targetChanged
        var errorDescription: String? {
            switch self {
            case .invalidInput: "Invalid audio input"
            case .emptySelection: "The selected audio range is empty"
            case .verificationFailed: "Rendered audio could not be verified"
            case .targetChanged: "The recording changed while it was being edited"
            }
        }
    }
}
