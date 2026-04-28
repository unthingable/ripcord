import Foundation
import QuartzCore

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

/// Single shared bar tracker for the capture waveform. Both audio sources
/// (system + mic) feed per-chunk peaks here and a bar commits on a wall-clock
/// cadence (`bufferDurationSeconds / 100`). One commit event advances all 100
/// slots uniformly — avoids the caterpillar drift that came from two
/// independent per-buffer bar counters falling out of phase.
final class WaveformTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var barPeaks: [Float]
    private var barStates: [BarState]
    private var barPeakHead: Int = 0
    private var barPeakCommitted: Int = 0
    private var currentPeak: Float = 0
    private var currentBarState: BarState = .idle
    private var barInterval: TimeInterval
    private var lastCommitTime: TimeInterval = 0
    private var initialized = false

    init(durationSeconds: Int) {
        self.barPeaks = [Float](repeating: 0, count: 100)
        self.barStates = [BarState](repeating: .idle, count: 100)
        self.barInterval = Double(durationSeconds) / 100.0
    }

    /// Feed a chunk peak and advance bars if the wall-clock interval has elapsed.
    /// Called from audio callbacks (either system or mic) — the peak is max-merged
    /// across both sources into the current in-progress bar.
    func feedPeak(_ peak: Float) {
        lock.lock()
        defer { lock.unlock() }
        let now = CACurrentMediaTime()
        if !initialized {
            lastCommitTime = now
            initialized = true
        }
        if peak > currentPeak { currentPeak = peak }
        while now - lastCommitTime >= barInterval {
            barPeaks[barPeakHead] = currentPeak
            barStates[barPeakHead] = currentBarState
            barPeakHead = (barPeakHead + 1) % 100
            barPeakCommitted += 1
            currentPeak = 0
            lastCommitTime += barInterval
        }
    }

    func setBarState(_ state: BarState) {
        lock.withLock { currentBarState = state }
    }

    /// Dims committed `.recorded`/`.paused` bars to their prior variants.
    func dimAllBars() {
        lock.lock()
        defer { lock.unlock() }
        for i in 0..<100 {
            barStates[i] = barStates[i].dimmed
        }
    }

    /// Marks the last `count` committed bars with `state` (used for back-record at record start).
    func markRecentBars(_ count: Int, state: BarState) {
        lock.lock()
        defer { lock.unlock() }
        let available = min(barPeakCommitted, 99)
        let n = min(count, available)
        for i in 0..<n {
            let idx = (barPeakHead - n + i + 100) % 100
            barStates[idx] = state
        }
    }

    /// Returns the 100 most recent bar peaks + states. Slot 99 is the live
    /// partial bar (current in-progress accumulation).
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
        peaks[99] = currentPeak
        states[99] = currentBarState
        return (peaks, states)
    }

    var committedCount: Int {
        lock.withLock { barPeakCommitted }
    }

    func resize(durationSeconds: Int) {
        lock.lock()
        defer { lock.unlock() }
        barPeaks = [Float](repeating: 0, count: 100)
        barStates = [BarState](repeating: .idle, count: 100)
        barPeakHead = 0
        barPeakCommitted = 0
        currentPeak = 0
        currentBarState = .idle
        barInterval = Double(durationSeconds) / 100.0
        initialized = false
    }
}
