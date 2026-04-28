import Foundation

final class CircularAudioBuffer: @unchecked Sendable {
    private var capacity: Int
    private var buffer: [Float]
    private var writeHead: Int = 0
    private var totalWritten: Int = 0
    private let lock = NSLock()

    // Inline peak tracking for level meter
    private var meterPeakAccum: Float = 0

    init(durationSeconds: Int, sampleRate: Int = 48000) {
        self.capacity = durationSeconds * sampleRate
        self.buffer = [Float](repeating: 0, count: capacity)
    }

    var sampleCount: Int {
        lock.withLock { min(totalWritten, capacity) }
    }

    func write(_ samples: [Float]) {
        lock.lock()
        defer { lock.unlock() }

        for sample in samples {
            buffer[writeHead] = sample
            writeHead = (writeHead + 1) % capacity

            let a = abs(sample)
            if a > meterPeakAccum { meterPeakAccum = a }
        }
        totalWritten += samples.count
    }

    /// Returns all buffered audio in chronological order and resets the buffer.
    func drain() -> [Float] {
        lock.lock()
        defer { lock.unlock() }

        let filled = min(totalWritten, capacity)
        guard filled > 0 else { return [] }

        var result = [Float](repeating: 0, count: filled)

        if totalWritten >= capacity {
            // Buffer is full — read from writeHead (oldest) forward
            let firstChunkLen = capacity - writeHead
            result[0..<firstChunkLen] = buffer[writeHead..<capacity]
            result[firstChunkLen..<filled] = buffer[0..<writeHead]
        } else {
            // Buffer not yet full — data starts at 0
            result[0..<filled] = buffer[0..<filled]
        }

        // Reset
        writeHead = 0
        totalWritten = 0

        return result
    }

    /// Reads the last N samples from the buffer without draining.
    func read(lastNSamples count: Int) -> [Float] {
        lock.lock()
        defer { lock.unlock() }

        let available = min(totalWritten, capacity)
        let n = min(count, available)
        guard n > 0 else { return [] }

        var result = [Float](repeating: 0, count: n)
        let start = (writeHead - n + capacity) % capacity
        if start + n <= capacity {
            result[0..<n] = buffer[start..<(start + n)]
        } else {
            let firstChunk = capacity - start
            result[0..<firstChunk] = buffer[start..<capacity]
            result[firstChunk..<n] = buffer[0..<(n - firstChunk)]
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

        capacity = durationSeconds * sampleRate
        buffer = [Float](repeating: 0, count: capacity)
        writeHead = 0
        totalWritten = 0
        meterPeakAccum = 0
    }
}
