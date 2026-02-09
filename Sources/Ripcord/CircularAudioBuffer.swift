import Foundation

final class CircularAudioBuffer: @unchecked Sendable {
    private var capacity: Int
    private var buffer: [Float]
    private var writeHead: Int = 0
    private var totalWritten: Int = 0
    private let lock = NSLock()

    // Inline peak tracking for waveform bars
    private var barPeaks: [Float]
    private var barPeakHead: Int = 0
    private var barPeakCommitted: Int = 0
    private var currentBarPeak: Float = 0
    private var currentBarSamples: Int = 0
    private var samplesPerBar: Int

    // Inline peak tracking for level meter
    private var meterPeakAccum: Float = 0

    init(durationSeconds: Int, sampleRate: Int = 48000) {
        self.capacity = durationSeconds * sampleRate
        self.buffer = [Float](repeating: 0, count: capacity)
        self.samplesPerBar = capacity / 100
        self.barPeaks = [Float](repeating: 0, count: 100)
    }

    var sampleCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return min(totalWritten, capacity)
    }

    func write(_ samples: [Float]) {
        lock.lock()
        defer { lock.unlock() }

        for sample in samples {
            buffer[writeHead] = sample
            writeHead = (writeHead + 1) % capacity

            let a = abs(sample)

            // Level meter: track peak since last consume
            if a > meterPeakAccum { meterPeakAccum = a }

            // Waveform bars: accumulate peak per bar-sized chunk
            if a > currentBarPeak { currentBarPeak = a }
            currentBarSamples += 1
            if currentBarSamples >= samplesPerBar {
                barPeaks[barPeakHead] = currentBarPeak
                barPeakHead = (barPeakHead + 1) % 100
                barPeakCommitted += 1
                currentBarPeak = 0
                currentBarSamples = 0
            }
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
        barPeakHead = 0
        barPeakCommitted = 0
        currentBarPeak = 0
        currentBarSamples = 0

        return result
    }

    /// Reads and resets the peak accumulated since last call.
    func consumeMeterPeak() -> Float {
        lock.lock()
        defer { lock.unlock() }
        let p = meterPeakAccum
        meterPeakAccum = 0
        return p
    }

    /// Returns the 100 most recent waveform bar peaks.
    /// The last 99 entries are committed (complete) bars; entry [99] is the in-progress partial bar.
    func getBarPeaks() -> [Float] {
        lock.lock()
        defer { lock.unlock() }

        var result = [Float](repeating: 0, count: 100)
        let available = min(barPeakCommitted, 99)

        for i in 0..<available {
            let idx = (barPeakHead - available + i + 100) % 100
            result[99 - available + i] = barPeaks[idx]
        }

        // Rightmost bar is always the live partial bar
        result[99] = currentBarPeak

        return result
    }

    func resize(durationSeconds: Int, sampleRate: Int = 48000) {
        lock.lock()
        defer { lock.unlock() }

        capacity = durationSeconds * sampleRate
        buffer = [Float](repeating: 0, count: capacity)
        writeHead = 0
        totalWritten = 0

        samplesPerBar = capacity / 100
        barPeaks = [Float](repeating: 0, count: 100)
        barPeakHead = 0
        barPeakCommitted = 0
        currentBarPeak = 0
        currentBarSamples = 0
        meterPeakAccum = 0
    }
}
