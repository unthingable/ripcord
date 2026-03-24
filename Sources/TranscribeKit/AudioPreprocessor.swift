@preconcurrency import AVFoundation
import Foundation

public enum AudioPreprocessor {
    /// Get the audio duration from the file directly.
    public static func getAudioDuration(_ url: URL) async -> TimeInterval {
        do {
            let audioFile = try AVAudioFile(forReading: url)
            return Double(audioFile.length) / audioFile.processingFormat.sampleRate
        } catch {
            // Try as video/media container
            let asset = AVAsset(url: url)
            guard let duration = try? await asset.load(.duration),
                  duration.timescale > 0 else { return 0 }
            return CMTimeGetSeconds(duration)
        }
    }

    /// Extract audio track from a video/media file to a temporary PCM WAV.
    /// Uses AVAssetReader to decode to LPCM, avoiding AAC codec issues with AVAudioFile.
    public static func extractAudio(from url: URL) async throws -> (url: URL, cleanup: () -> Void) {
        let asset = AVAsset(url: url)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard let audioTrack = audioTracks.first else {
            throw AudioPreprocessorError.noAudioTrack
        }

        let reader = try AVAssetReader(asset: asset)
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
        ]
        let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
        reader.add(output)
        guard reader.startReading() else {
            throw AudioPreprocessorError.exportFailed(reader.error?.localizedDescription)
        }

        // Read all sample buffers into a contiguous array
        var samples = [Float]()
        while let buffer = output.copyNextSampleBuffer(),
              let blockBuffer = CMSampleBufferGetDataBuffer(buffer) {
            var length = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil,
                                        totalLengthOut: &length, dataPointerOut: &dataPointer)
            if let dataPointer, length > 0 {
                let floatCount = length / MemoryLayout<Float>.size
                dataPointer.withMemoryRebound(to: Float.self, capacity: floatCount) { floats in
                    samples.append(contentsOf: UnsafeBufferPointer(start: floats, count: floatCount))
                }
            }
        }

        // Accept data even if reader ended with an error (e.g. trailing decode issue)
        guard !samples.isEmpty else {
            throw AudioPreprocessorError.exportFailed(reader.error?.localizedDescription)
        }

        // Write to WAV via AVAudioFile
        let wavFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000,
                                      channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: wavFormat,
                                      frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcribekit-extract-\(UUID().uuidString).wav")
        let wavFile = try AVAudioFile(forWriting: tempURL, settings: wavFormat.settings)
        try wavFile.write(from: buffer)

        return (tempURL, cleanup: { try? FileManager.default.removeItem(at: tempURL) })
    }

    /// Mix to mono (if needed), normalize, and optionally trim to a time range.
    /// Accepts audio files directly, or video/media files (audio is extracted automatically).
    /// Returns the URL to use and a cleanup closure for any temp file.
    public static func prepareAudio(
        from url: URL,
        startTime: Double? = nil,
        endTime: Double? = nil
    ) async throws -> (url: URL, cleanup: () -> Void) {
        // Video/media containers need audio extraction even if AVAudioFile can open them,
        // because downstream readers (FluidAudio) choke on compressed codecs like AAC.
        let videoExtensions: Set<String> = [
            "mp4", "m4v", "mov", "avi", "mkv", "webm", "mpg", "mpeg", "ts", "mts",
        ]
        let isVideo = videoExtensions.contains(url.pathExtension.lowercased())

        let audioFile: AVAudioFile
        var extractCleanup: (() -> Void)?
        if isVideo {
            let (extractedURL, cleanup) = try await extractAudio(from: url)
            extractCleanup = cleanup
            do {
                audioFile = try AVAudioFile(forReading: extractedURL)
            } catch {
                cleanup()
                throw error
            }
        } else {
            do {
                audioFile = try AVAudioFile(forReading: url)
            } catch {
                // Try extraction as fallback for unrecognized containers
                let (extractedURL, cleanup) = try await extractAudio(from: url)
                extractCleanup = cleanup
                do {
                    audioFile = try AVAudioFile(forReading: extractedURL)
                } catch {
                    cleanup()
                    throw error
                }
            }
        }

        let format = audioFile.processingFormat
        let sampleRate = format.sampleRate
        let totalFrames = AVAudioFrameCount(audioFile.length)

        let needsTrim = startTime != nil || endTime != nil
        let needsMono = format.channelCount > 1

        guard needsTrim || needsMono else {
            if let extractCleanup {
                // Extracted file is already the right format — return it with its cleanup
                return (URL(fileURLWithPath: audioFile.url.path), cleanup: extractCleanup)
            }
            return (url, cleanup: {})
        }

        // Compute frame range for trimming
        let startFrame = AVAudioFramePosition(
            min(Double(totalFrames), max(0, (startTime ?? 0) * sampleRate)))
        let endFrame = AVAudioFramePosition(
            min(Double(totalFrames), max(Double(startFrame), (endTime ?? Double(totalFrames) / sampleRate) * sampleRate)))
        let frameCount = AVAudioFrameCount(endFrame - startFrame)

        guard frameCount > 0 else {
            extractCleanup?()
            return (url, cleanup: {})
        }

        audioFile.framePosition = startFrame
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            extractCleanup?()
            return (url, cleanup: {})
        }
        try audioFile.read(into: buffer, frameCount: frameCount)
        // Done with extracted file if any
        extractCleanup?()

        guard let channelData = buffer.floatChannelData else {
            return (url, cleanup: {})
        }

        let channelCount = Int(format.channelCount)
        let sampleCount = Int(buffer.frameLength)

        guard let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: format.sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            return (url, cleanup: {})
        }

        guard let monoBuffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: frameCount)
        else {
            return (url, cleanup: {})
        }
        monoBuffer.frameLength = AVAudioFrameCount(sampleCount)

        guard let monoSamples = monoBuffer.floatChannelData?[0] else {
            return (url, cleanup: {})
        }

        // Mix to mono (average all channels)
        let scale = 1.0 / Float(channelCount)
        for i in 0..<sampleCount {
            var sum: Float = 0
            for ch in 0..<channelCount {
                sum += channelData[ch][i]
            }
            monoSamples[i] = sum * scale
        }

        // Normalize to peak amplitude
        var peak: Float = 0
        for i in 0..<sampleCount {
            let abs = Swift.abs(monoSamples[i])
            if abs > peak { peak = abs }
        }
        if peak > 0.01 && peak < 0.95 {
            let gain = 1.0 / peak
            for i in 0..<sampleCount {
                monoSamples[i] *= gain
            }
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcribekit-mono-\(UUID().uuidString).wav")
        let outputFile = try AVAudioFile(forWriting: tempURL, settings: monoFormat.settings)
        try outputFile.write(from: monoBuffer)

        return (tempURL, cleanup: { try? FileManager.default.removeItem(at: tempURL) })
    }
}

public enum AudioPreprocessorError: LocalizedError {
    case noAudioTrack
    case exportFailed(String?)

    public var errorDescription: String? {
        switch self {
        case .noAudioTrack: return "No audio track found in file"
        case .exportFailed(let detail):
            if let detail { return "Failed to extract audio: \(detail)" }
            return "Failed to extract audio from file"
        }
    }
}
