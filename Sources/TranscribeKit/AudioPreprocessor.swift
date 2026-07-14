@preconcurrency import AVFoundation
import Foundation

public enum AudioPreprocessor {
    private struct TimeRange: Sendable {
        let start: Double
        let end: Double
    }

    /// Serializes cancellation with the currently active reader. AVAssetReader's
    /// cancellation is synchronous, so the decoding loop also checks the task.
    private final class ReaderCancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var reader: AVAssetReader?

        func set(_ reader: AVAssetReader) {
            lock.withLock { self.reader = reader }
        }

        func clear(_ reader: AVAssetReader) {
            lock.withLock {
                if self.reader === reader { self.reader = nil }
            }
        }

        func cancel() {
            lock.withLock { reader?.cancelReading() }
        }
    }

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
    public static func extractAudio(
        from url: URL,
        startTime: Double? = nil,
        endTime: Double? = nil
    ) async throws -> (url: URL, cleanup: () -> Void) {
        let range = try await validatedTimeRange(for: url, startTime: startTime, endTime: endTime)
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcribekit-extract-\(UUID().uuidString).wav")
        let cleanup: () -> Void = { try? FileManager.default.removeItem(at: tempURL) }
        var succeeded = false
        defer {
            if !succeeded { cleanup() }
        }

        // Prefer ffmpeg — AVAssetReader can silently fail mid-file on long/complex containers
        if try await extractWithFFmpeg(from: url, to: tempURL, range: range)
        {
            try Task.checkCancellation()
            try normalizeWAVInPlace(tempURL)
            succeeded = true
            return (tempURL, cleanup: cleanup)
        }

        // Fall back to AVAssetReader in time-ranged chunks
        try await extractWithAssetReader(from: url, to: tempURL, range: range)
        try Task.checkCancellation()
        try normalizeWAVInPlace(tempURL)
        succeeded = true
        return (tempURL, cleanup: cleanup)
    }

    private static func normalizeWAVInPlace(_ url: URL) throws {
        let input = try AVAudioFile(forReading: url)
        let format = input.processingFormat
        let capacity: AVAudioFrameCount = 65_536
        guard let scanBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw AudioPreprocessorError.exportFailed("Could not allocate normalization buffer")
        }

        var peak: Float = 0
        while input.framePosition < input.length {
            try Task.checkCancellation()
            try input.read(into: scanBuffer, frameCount: capacity)
            guard let channels = scanBuffer.floatChannelData else { break }
            for channel in 0..<Int(format.channelCount) {
                for frame in 0..<Int(scanBuffer.frameLength) {
                    peak = max(peak, abs(channels[channel][frame]))
                }
            }
        }
        guard peak > 0.01, peak < 0.95 else { return }

        let gain = 1.0 / peak
        let normalizedURL = url.deletingLastPathComponent()
            .appendingPathComponent("transcribekit-normalized-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: normalizedURL) }
        try writeNormalizedWAV(
            from: url, to: normalizedURL, format: format, capacity: capacity, gain: gain)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: normalizedURL, to: url)
    }

    private static func writeNormalizedWAV(
        from sourceURL: URL,
        to outputURL: URL,
        format: AVAudioFormat,
        capacity: AVAudioFrameCount,
        gain: Float
    ) throws {
        let input = try AVAudioFile(forReading: sourceURL)
        let output = try AVAudioFile(forWriting: outputURL, settings: format.settings)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw AudioPreprocessorError.exportFailed("Could not allocate normalization buffer")
        }
        while input.framePosition < input.length {
            try Task.checkCancellation()
            try input.read(into: buffer, frameCount: capacity)
            guard let channels = buffer.floatChannelData else {
                throw AudioPreprocessorError.exportFailed("Unsupported normalization format")
            }
            for channel in 0..<Int(format.channelCount) {
                for frame in 0..<Int(buffer.frameLength) {
                    channels[channel][frame] *= gain
                }
            }
            try output.write(from: buffer)
        }
    }

    /// Match AVAssetReader's historical clamping behavior, but resolve it before
    /// choosing a backend so ffmpeg and AVFoundation transcribe the same interval.
    private static func validatedTimeRange(
        for url: URL,
        startTime: Double?,
        endTime: Double?
    ) async throws -> TimeRange {
        let duration = await getAudioDuration(url)
        guard duration.isFinite, duration > 0 else {
            throw AudioPreprocessorError.exportFailed("File has zero duration")
        }
        guard (startTime ?? 0).isFinite, (endTime ?? duration).isFinite else {
            throw AudioPreprocessorError.invalidTimeRange
        }

        let start = min(duration, max(0, startTime ?? 0))
        let end = min(duration, max(start, endTime ?? duration))
        guard end > start else { throw AudioPreprocessorError.invalidTimeRange }
        return TimeRange(start: start, end: end)
    }

    // MARK: - ffmpeg extraction

    private static func extractWithFFmpeg(
        from url: URL,
        to outputURL: URL,
        range: TimeRange
    ) async throws -> Bool {
        let searchPaths = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
        guard let path = searchPaths.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            return false
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        var arguments = ["-nostdin", "-i", url.path, "-ss", String(range.start),
                         "-t", String(range.end - range.start)]
        arguments += [
            "-vn",                // discard video
            "-ac", "1",           // mono
            "-ar", "16000",       // 16 kHz
            "-c:a", "pcm_f32le", // float32 PCM to match AVAssetReader output
            "-f", "wav",
            "-y",                 // overwrite
            outputURL.path,
        ]
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        let ok: Bool
        do {
            ok = try await withTaskCancellationHandler(operation: {
                try Task.checkCancellation()
                let succeeded: Bool = try await withCheckedThrowingContinuation { continuation in
                    process.terminationHandler = { p in
                        continuation.resume(returning: p.terminationStatus == 0)
                    }
                    do {
                        try process.run()
                        if Task.isCancelled { process.terminate() }
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
                try Task.checkCancellation()
                return succeeded
            }, onCancel: {
                if process.isRunning { process.terminate() }
            })
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: outputURL)
            throw CancellationError()
        } catch {
            return false
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

    private static func extractWithAssetReader(
        from url: URL,
        to outputURL: URL,
        range: TimeRange
    ) async throws {
        let cancellation = ReaderCancellation()
        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            let asset = AVAsset(url: url)
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            guard let audioTrack = audioTracks.first else {
                throw AudioPreprocessorError.noAudioTrack
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
            var offset = range.start
            var totalFrames: UInt64 = 0

            while offset < range.end {
                try Task.checkCancellation()
                let duration = min(chunkSeconds, range.end - offset)
            let timeRange = CMTimeRange(
                start: CMTime(seconds: offset, preferredTimescale: 600),
                duration: CMTime(seconds: duration, preferredTimescale: 600))

                let reader = try AVAssetReader(asset: asset)
                cancellation.set(reader)
                defer { cancellation.clear(reader) }
                reader.timeRange = timeRange
                let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
                reader.add(output)
                guard reader.startReading() else {
                    if totalFrames > 0 { break }
                    throw AudioPreprocessorError.exportFailed(reader.error?.localizedDescription)
                }

                var chunkFrames: UInt64 = 0
                while !Task.isCancelled,
                      let sampleBuffer = output.copyNextSampleBuffer(),
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
                try Task.checkCancellation()

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
            if actualDuration / (range.end - range.start) < 0.9 {
                throw AudioPreprocessorError.exportFailed(
                    "Extracted \(Int(actualDuration))s of \(Int(range.end - range.start))s")
            }
        }, onCancel: {
            cancellation.cancel()
        })
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
            // extractAudio already streams normalization to 16 kHz mono and applies
            // the validated trim, so avoid decoding a video once just to decode it again.
            return try await extractAudio(from: url, startTime: startTime, endTime: endTime)
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
        let totalFrames = audioFile.length

        let needsTrim = startTime != nil || endTime != nil
        let needsMono = format.channelCount > 1
        let needsResample = format.sampleRate != 16000

        guard needsTrim || needsMono || needsResample else {
            if let extractCleanup {
                // The fallback extraction has already normalized this temporary file.
                return (URL(fileURLWithPath: audioFile.url.path), cleanup: extractCleanup)
            }
            return try await extractAudio(from: url)
        }

        let requestedStart = startTime ?? 0
        let requestedEnd = endTime ?? (Double(totalFrames) / sampleRate)
        guard requestedStart.isFinite, requestedEnd.isFinite, sampleRate.isFinite, sampleRate > 0 else {
            extractCleanup?()
            throw AudioPreprocessorError.invalidTimeRange
        }
        guard requestedEnd > requestedStart else {
            extractCleanup?()
            throw AudioPreprocessorError.invalidTimeRange
        }

        let sourceURL = URL(fileURLWithPath: audioFile.url.path)
        do {
            let result = try await extractAudio(
                from: sourceURL, startTime: startTime, endTime: endTime)
            extractCleanup?()
            return result
        } catch {
            extractCleanup?()
            throw error
        }
    }
}

public enum AudioPreprocessorError: LocalizedError {
    case noAudioTrack
    case exportFailed(String?)
    case invalidTimeRange

    public var errorDescription: String? {
        switch self {
        case .noAudioTrack: return "No audio track found in file"
        case .exportFailed(let detail):
            if let detail { return "Failed to extract audio: \(detail)" }
            return "Failed to extract audio from file"
        case .invalidTimeRange:
            return "The requested transcription time range is invalid"
        }
    }
}
