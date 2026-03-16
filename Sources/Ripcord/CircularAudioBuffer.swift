import Foundation

enum BarState: UInt8, Comparable {
    case idle = 0
    case priorRecorded = 1
    case priorPaused = 2
    case paused = 3
    case recorded = 4

    static func < (lhs: BarState, rhs: BarState) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Dims active recording/paused states to their "prior" equivalents.
    var dimmed: BarState {
        switch self {
        case .recorded: return .priorRecorded
        case .paused: return .priorPaused
        default: return self
        }
    }
}

final class CircularAudioBuffer: @unchecked Sendable {
    private var capacity: Int
    private var buffer: [Float]
    private var writeHead: Int = 0
    private var totalWritten: Int = 0
    private let lock = NSLock()

    // Inline peak tracking for waveform bars
    private var barPeaks: [Float]
    private var barStates: [BarState]
    private var barPeakHead: Int = 0
    private var barPeakCommitted: Int = 0
    private var currentBarPeak: Float = 0
    private var currentBarSamples: Int = 0
    private var samplesPerBar: Int
    private var currentBarState: BarState = .idle

    // Inline peak tracking for level meter
    private var meterPeakAccum: Float = 0

    init(durationSeconds: Int, sampleRate: Int = 48000) {
        self.capacity = durationSeconds * sampleRate
        self.buffer = [Float](repeating: 0, count: capacity)
        self.samplesPerBar = capacity / 100
        self.barPeaks = [Float](repeating: 0, count: 100)
        self.barStates = [BarState](repeating: .idle, count: 100)
    }

    var sampleCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return min(totalWritten, capacity)
    }

    /// Sets the state that new bars will be tagged with.
    func setBarState(_ state: BarState) {
        lock.lock()
        currentBarState = state
        lock.unlock()
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
                barStates[barPeakHead] = currentBarState
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
        lock.lock()
        defer { lock.unlock() }
        let p = meterPeakAccum
        meterPeakAccum = 0
        return p
    }

    /// Returns the 100 most recent waveform bar peaks and their states.
    func getBarPeaks() -> (peaks: [Float], states: [BarState]) {
        lock.lock()
        defer { lock.unlock() }

        var peaks = [Float](repeating: 0, count: 100)
        var states = [BarState](repeating: .idle, count: 100)
        let available = min(barPeakCommitted, 99)

        for i in 0..<available {
            let idx = (barPeakHead - available + i + 100) % 100
            peaks[99 - available + i] = barPeaks[idx]
            states[99 - available + i] = barStates[idx]
        }

        // Rightmost bar is always the live partial bar
        peaks[99] = currentBarPeak
        states[99] = currentBarState

        return (peaks, states)
    }

    /// Dims all committed bars: `.recorded` → `.priorRecorded`, `.paused` → `.priorPaused`.
    func dimAllBars() {
        lock.lock()
        defer { lock.unlock() }

        for i in 0..<100 {
            barStates[i] = barStates[i].dimmed
        }
    }

    /// Marks the last `count` committed bars with the given state.
    func markRecentBars(_ count: Int, state: BarState) {
        lock.lock()
        defer { lock.unlock() }

        let available = min(barPeakCommitted, 99)  // cap at 99 to match getBarPeaks (slot 99 = live partial)
        let n = min(count, available)
        for i in 0..<n {
            let idx = (barPeakHead - n + i + 100) % 100
            barStates[idx] = state
        }
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
        barStates = [BarState](repeating: .idle, count: 100)
        barPeakHead = 0
        barPeakCommitted = 0
        currentBarPeak = 0
        currentBarSamples = 0
        currentBarState = .idle
        meterPeakAccum = 0
    }
}
