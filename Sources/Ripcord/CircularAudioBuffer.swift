import Foundation

/// Stereo-interleaved ring buffer of Float samples. A "frame" is one pair of
/// L/R samples (= 2 Floats). All sizes externally are in frames; storage
/// internally is `frames * 2` Floats.
final class CircularAudioBuffer: @unchecked Sendable {
    static let channelsPerFrame = 2

    private var capacityFrames: Int
    private var buffer: [Float]
    private var writeHead: Int = 0  // sample index (not frame index)
    private var totalWritten: Int = 0  // in frames
    private var latestEndHostTime: UInt64?
    private let lock = NSLock()

    // Inline peak tracking for level meter
    private var meterPeakAccum: Float = 0

    init(durationSeconds: Int, sampleRate: Int = 48000) {
        self.capacityFrames = durationSeconds * sampleRate
        self.buffer = [Float](repeating: 0, count: capacityFrames * Self.channelsPerFrame)
    }

    /// Number of stereo frames currently buffered.
    var frameCount: Int {
        lock.withLock { min(totalWritten, capacityFrames) }
    }

    func write(_ samples: UnsafeBufferPointer<Float>, endHostTime: UInt64? = nil) {
        lock.lock()
        defer { lock.unlock() }

        let capacitySamples = capacityFrames * Self.channelsPerFrame
        for i in 0..<samples.count {
            buffer[writeHead] = samples[i]
            writeHead = (writeHead + 1) % capacitySamples

            let a = abs(samples[i])
            if a > meterPeakAccum { meterPeakAccum = a }
        }
        totalWritten += samples.count / Self.channelsPerFrame
        if let endHostTime { latestEndHostTime = endHostTime }
    }

    /// Returns all buffered audio (stereo-interleaved) in chronological order
    /// and resets the buffer.
    func drain() -> [Float] {
        lock.lock()
        defer { lock.unlock() }

        let filledFrames = min(totalWritten, capacityFrames)
        guard filledFrames > 0 else { return [] }
        let filledSamples = filledFrames * Self.channelsPerFrame
        let capacitySamples = capacityFrames * Self.channelsPerFrame

        var result = [Float](repeating: 0, count: filledSamples)

        if totalWritten >= capacityFrames {
            // Buffer is full — read from writeHead (oldest) forward
            let firstChunkLen = capacitySamples - writeHead
            result[0..<firstChunkLen] = buffer[writeHead..<capacitySamples]
            result[firstChunkLen..<filledSamples] = buffer[0..<writeHead]
        } else {
            // Buffer not yet full — data starts at 0
            result[0..<filledSamples] = buffer[0..<filledSamples]
        }

        // Reset
        writeHead = 0
        totalWritten = 0
        latestEndHostTime = nil

        return result
    }

    /// Reads the last N frames (stereo-interleaved samples) without draining.
    func read(lastNFrames count: Int) -> [Float] {
        lock.lock()
        defer { lock.unlock() }

        return readLocked(lastNFrames: count)
    }

    func readWithEndHostTime(lastNFrames count: Int) -> (samples: [Float], endHostTime: UInt64?) {
        lock.lock()
        defer { lock.unlock() }
        return (readLocked(lastNFrames: count), latestEndHostTime)
    }

    private func readLocked(lastNFrames count: Int) -> [Float] {
        let availableFrames = min(totalWritten, capacityFrames)
        let n = min(count, availableFrames)
        guard n > 0 else { return [] }

        let nSamples = n * Self.channelsPerFrame
        let capacitySamples = capacityFrames * Self.channelsPerFrame
        var result = [Float](repeating: 0, count: nSamples)
        let start = (writeHead - nSamples + capacitySamples) % capacitySamples
        if start + nSamples <= capacitySamples {
            result[0..<nSamples] = buffer[start..<(start + nSamples)]
        } else {
            let firstChunk = capacitySamples - start
            result[0..<firstChunk] = buffer[start..<capacitySamples]
            result[firstChunk..<nSamples] = buffer[0..<(nSamples - firstChunk)]
        }
        return result
    }

    /// Reads and resets the peak accumulated since last call.
    func consumeMeterPeak() -> Float {
        lock.withLock {
            let p = meterPeakAccum
            meterPeakAccum = 0
            return p
        }
    }

    func resize(durationSeconds: Int, sampleRate: Int = 48000) {
        lock.lock()
        defer { lock.unlock() }

        capacityFrames = durationSeconds * sampleRate
        buffer = [Float](repeating: 0, count: capacityFrames * Self.channelsPerFrame)
        writeHead = 0
        totalWritten = 0
        meterPeakAccum = 0
        latestEndHostTime = nil
    }
}
