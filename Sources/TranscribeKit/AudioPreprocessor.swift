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
    /// Prefers ffmpeg when available (handles problematic containers more robustly),
    /// falls back to AVAssetReader in time-ranged chunks.
    public static func extractAudio(from url: URL) async throws -> (url: URL, cleanup: () -> Void) {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcribekit-extract-\(UUID().uuidString).wav")
        let cleanup: () -> Void = { try? FileManager.default.removeItem(at: tempURL) }

        // Prefer ffmpeg — AVAssetReader can silently fail mid-file on long/complex containers
        if await extractWithFFmpeg(from: url, to: tempURL) {
            return (tempURL, cleanup: cleanup)
        }

        // Fall back to AVAssetReader in time-ranged chunks
        try await extractWithAssetReader(from: url, to: tempURL)
        return (tempURL, cleanup: cleanup)
    }

    // MARK: - ffmpeg extraction

    private static func extractWithFFmpeg(from url: URL, to outputURL: URL) async -> Bool {
        let searchPaths = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
        guard let path = searchPaths.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            return false
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = [
            "-i", url.path,
            "-vn",                // discard video
            "-ac", "1",           // mono
            "-ar", "16000",       // 16 kHz
            "-c:a", "pcm_f32le", // float32 PCM to match AVAssetReader output
            "-f", "wav",
            "-y",                 // overwrite
            outputURL.path,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        let ok: Bool = await withCheckedContinuation { continuation in
            process.terminationHandler = { p in
                continuation.resume(returning: p.terminationStatus == 0)
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: false)
            }
        }

        guard ok else {
            try? FileManager.default.removeItem(at: outputURL)
            return false
        }

        // Sanity-check: output must exist and have meaningful size (WAV header = 44 bytes)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: outputURL.path),
              let size = attrs[.size] as? UInt64, size > 1000 else {
            try? FileManager.default.removeItem(at: outputURL)
            return false
        }

        return true
    }

    // MARK: - AVAssetReader extraction (fallback)

    private static func extractWithAssetReader(from url: URL, to outputURL: URL) async throws {
        let asset = AVAsset(url: url)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard let audioTrack = audioTracks.first else {
            throw AudioPreprocessorError.noAudioTrack
        }

        let totalDuration = try await CMTimeGetSeconds(asset.load(.duration))
        guard totalDuration > 0 else {
            throw AudioPreprocessorError.exportFailed("File has zero duration")
        }

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
        ]

        let wavFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000,
                                      channels: 1, interleaved: false)!
        let wavFile = try AVAudioFile(forWriting: outputURL, settings: wavFormat.settings)

        // Process in time-ranged chunks — a fresh AVAssetReader per chunk avoids
        // internal resource limits that cause silent mid-file failures.
        let chunkSeconds: Double = 300
        var offset: Double = 0
        var totalFrames: UInt64 = 0

        while offset < totalDuration {
            let duration = min(chunkSeconds, totalDuration - offset)
            let timeRange = CMTimeRange(
                start: CMTime(seconds: offset, preferredTimescale: 600),
                duration: CMTime(seconds: duration, preferredTimescale: 600))

            let reader = try AVAssetReader(asset: asset)
            reader.timeRange = timeRange
            let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
            reader.add(output)
            guard reader.startReading() else {
                if totalFrames > 0 { break }
                throw AudioPreprocessorError.exportFailed(reader.error?.localizedDescription)
            }

            var chunkFrames: UInt64 = 0
            while let sampleBuffer = output.copyNextSampleBuffer(),
                  let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) {
                var length = 0
                var dataPointer: UnsafeMutablePointer<Int8>?
                CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil,
                                            totalLengthOut: &length, dataPointerOut: &dataPointer)
                if let dataPointer, length > 0 {
                    let floatCount = length / MemoryLayout<Float>.size
                    let pcmBuffer = AVAudioPCMBuffer(pcmFormat: wavFormat,
                                                      frameCapacity: AVAudioFrameCount(floatCount))!
                    pcmBuffer.frameLength = AVAudioFrameCount(floatCount)
                    dataPointer.withMemoryRebound(to: Float.self, capacity: floatCount) { floats in
                        pcmBuffer.floatChannelData![0].update(from: floats, count: floatCount)
                    }
                    try wavFile.write(from: pcmBuffer)
                    chunkFrames += UInt64(floatCount)
                }
            }

            if reader.status == .failed && chunkFrames == 0 {
                break
            }

            totalFrames += chunkFrames
            offset += duration
        }

        guard totalFrames > 0 else {
            throw AudioPreprocessorError.exportFailed("No audio samples could be decoded")
        }

        let actualDuration = Double(totalFrames) / 16000.0
        if actualDuration / totalDuration < 0.9 {
            throw AudioPreprocessorError.exportFailed(
                "Extracted \(Int(actualDuration))s of \(Int(totalDuration))s")
        }
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
