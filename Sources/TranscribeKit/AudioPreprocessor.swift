@preconcurrency import AVFoundation
import Foundation

public enum AudioPreprocessor {
    /// Get the audio duration from the file directly.
    public static func getAudioDuration(_ url: URL) -> TimeInterval {
        do {
            let audioFile = try AVAudioFile(forReading: url)
            return Double(audioFile.length) / audioFile.processingFormat.sampleRate
        } catch {
            return 0
        }
    }

    /// Mix to mono (if needed), normalize, and optionally trim to a time range.
    /// Returns the URL to use and a cleanup closure for any temp file.
    public static func prepareAudio(
        from url: URL,
        startTime: Double? = nil,
        endTime: Double? = nil
    ) throws -> (url: URL, cleanup: () -> Void) {
        let audioFile = try AVAudioFile(forReading: url)
        let format = audioFile.processingFormat
        let sampleRate = format.sampleRate
        let totalFrames = AVAudioFrameCount(audioFile.length)

        let needsTrim = startTime != nil || endTime != nil
        let needsMono = format.channelCount > 1

        guard needsTrim || needsMono else {
            return (url, cleanup: {})
        }

        // Compute frame range for trimming
        let startFrame = AVAudioFramePosition(
            min(Double(totalFrames), max(0, (startTime ?? 0) * sampleRate)))
        let endFrame = AVAudioFramePosition(
            min(Double(totalFrames), max(Double(startFrame), (endTime ?? Double(totalFrames) / sampleRate) * sampleRate)))
        let frameCount = AVAudioFrameCount(endFrame - startFrame)

        guard frameCount > 0 else {
            return (url, cleanup: {})
        }

        audioFile.framePosition = startFrame
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return (url, cleanup: {})
        }
        try audioFile.read(into: buffer, frameCount: frameCount)

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
