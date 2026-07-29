import Foundation
import TranscribeKit

struct TranscriptionProgressSnapshot: Equatable, Sendable {
    let fraction: Double
    let elapsed: TimeInterval
    let estimatedRemaining: TimeInterval?
}

struct CompletedTranscriptionPhase: Equatable, Sendable {
    let phase: String
    let duration: TimeInterval
}

struct TranscriptionProgressEstimate: Equatable, Sendable {
    private let phases: [String]
    private let expectedDurations: [String: TimeInterval]
    private let startedAt: Date
    private var phaseStartedAt: Date
    private var completedDuration: TimeInterval = 0
    private var progressFloor: Double = 0
    private(set) var phase: String
    private var reportedPhaseProgress: Double?

    init(
        phases: [TranscriptionPhase],
        expectedDurations: [String: TimeInterval],
        startedAt: Date
    ) {
        let phaseNames = phases.map(\.rawValue)
        self.phases = phaseNames
        self.expectedDurations = expectedDurations
        self.startedAt = startedAt
        self.phaseStartedAt = startedAt
        self.phase = phaseNames.first ?? TranscriptionPhase.preparing.rawValue
    }

    mutating func update(
        phase newPhase: TranscriptionPhase,
        reportedProgress: Double?,
        at date: Date
    ) -> CompletedTranscriptionPhase? {
        progressFloor = snapshot(at: date).fraction
        let newName = newPhase.rawValue
        var completed: CompletedTranscriptionPhase?
        if newName != phase {
            let duration = max(0, date.timeIntervalSince(phaseStartedAt))
            completed = CompletedTranscriptionPhase(phase: phase, duration: duration)
            completedDuration += duration
            phase = newName
            phaseStartedAt = date
        }
        reportedPhaseProgress = reportedProgress.map { max(0, min(1, $0)) }
        return completed
    }

    mutating func finish(at date: Date) -> CompletedTranscriptionPhase {
        progressFloor = snapshot(at: date).fraction
        let duration = max(0, date.timeIntervalSince(phaseStartedAt))
        completedDuration += duration
        return CompletedTranscriptionPhase(phase: phase, duration: duration)
    }

    func snapshot(at date: Date) -> TranscriptionProgressSnapshot {
        let phaseElapsed = max(0, date.timeIntervalSince(phaseStartedAt))
        let currentExpected = max(0.1, expectedDurations[phase] ?? 1)
        let estimatedCurrentTotal: TimeInterval
        if let reportedPhaseProgress, reportedPhaseProgress >= 0.999 {
            estimatedCurrentTotal = phaseElapsed
        } else if let reportedPhaseProgress, reportedPhaseProgress > 0.01 {
            estimatedCurrentTotal = max(phaseElapsed, phaseElapsed / reportedPhaseProgress)
        } else {
            // Unknown-progress phases advance with elapsed time but retain at
            // least 10% uncertainty until the next phase actually begins.
            estimatedCurrentTotal = max(currentExpected, phaseElapsed / 0.9)
        }

        let currentIndex = phases.firstIndex(of: phase) ?? 0
        let futureExpected = phases.dropFirst(currentIndex + 1).reduce(0.0) {
            $0 + max(0, expectedDurations[$1] ?? 0)
        }
        let predictedTotal = completedDuration + estimatedCurrentTotal + futureExpected
        let elapsed = max(0, date.timeIntervalSince(startedAt))
        let rawFraction = predictedTotal > 0
            ? (completedDuration + phaseElapsed) / predictedTotal
            : 0
        let fraction = max(progressFloor, min(0.99, rawFraction))
        let remaining = predictedTotal > 0
            ? max(0, predictedTotal - completedDuration - phaseElapsed)
            : nil
        return TranscriptionProgressSnapshot(
            fraction: fraction,
            elapsed: elapsed,
            estimatedRemaining: remaining
        )
    }
}

final class TranscriptionTimingStore {
    private let defaults: UserDefaults
    private let storageKey: String

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "ripcord.transcriptionTimingRates"
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
    }

    func expectedDurations(
        profile: String,
        audioDuration: TimeInterval,
        phases: [TranscriptionPhase],
        diarizationEngine: DiarizationEngine
    ) -> [String: TimeInterval] {
        let stored = storedRates()
        return Dictionary(uniqueKeysWithValues: phases.map { phase in
            let rateKey = "\(profile).\(phase.rawValue)"
            let rate = stored[rateKey] ?? Self.defaultRate(
                for: phase,
                diarizationEngine: diarizationEngine
            )
            let minimum: TimeInterval = phase == .transcribing || phase == .diarizing ? 5 : 1
            return (phase.rawValue, max(minimum, max(1, audioDuration) * rate))
        })
    }

    func record(
        _ timings: [CompletedTranscriptionPhase],
        profile: String,
        audioDuration: TimeInterval
    ) {
        guard audioDuration > 0 else { return }
        var rates = storedRates()
        for timing in timings where timing.duration >= 0.1 {
            let key = "\(profile).\(timing.phase)"
            let observed = max(0.001, min(10, timing.duration / audioDuration))
            rates[key] = rates[key].map { $0 * 0.75 + observed * 0.25 } ?? observed
        }
        defaults.set(rates, forKey: storageKey)
    }

    private func storedRates() -> [String: Double] {
        let values = defaults.dictionary(forKey: storageKey) ?? [:]
        return values.compactMapValues {
            ($0 as? NSNumber)?.doubleValue
        }
    }

    private static func defaultRate(
        for phase: TranscriptionPhase,
        diarizationEngine: DiarizationEngine
    ) -> Double {
        switch phase {
        case .preparing:
            0.01
        case .transcribing:
            0.25
        case .diarizing:
            switch diarizationEngine {
            case .offline: 0.50
            case .lseend: 0.75
            case .sortformer: 0.40
            }
        case .finalizing:
            0.005
        }
    }
}
