import CoreAudio
import Foundation
import os

/// Bounded non-blocking handoff for timestamped audio chunks.
final class AudioChunkHandoff: @unchecked Sendable {
    private var lock = os_unfair_lock_s()
    private var chunks: [AudioSampleChunk] = []
    private var storedSamples = 0
    private var droppedSamples = 0
    private let capacitySamples: Int

    init(capacityFrames: Int, channelsPerFrame: Int = CircularAudioBuffer.channelsPerFrame) {
        self.capacitySamples = max(channelsPerFrame, capacityFrames * channelsPerFrame)
        self.chunks.reserveCapacity(256)
    }

    func write(_ samples: UnsafeBufferPointer<Float>, timing: AudioSampleTiming) {
        guard samples.count > 0 else { return }
        guard os_unfair_lock_trylock(&lock) else { return }
        defer { os_unfair_lock_unlock(&lock) }

        let copied: [Float]
        let adjustedTiming: AudioSampleTiming
        if samples.count > capacitySamples {
            let drop = samples.count - capacitySamples
            copied = Array(samples.dropFirst(drop))
            let dropFrames = drop / max(1, timing.channelsPerFrame)
            adjustedTiming = AudioSampleTiming(
                hostTime: AudioConvertNanosToHostTime(
                    AudioConvertHostTimeToNanos(timing.hostTime)
                        + UInt64(Double(dropFrames) * 1_000_000_000.0 / timing.sampleRate)
                ),
                sampleTime: timing.sampleTime.map { $0 + Double(dropFrames) },
                sampleRate: timing.sampleRate,
                channelsPerFrame: timing.channelsPerFrame
            )
            droppedSamples += storedSamples + drop
            chunks.removeAll(keepingCapacity: true)
            storedSamples = 0
        } else {
            copied = Array(samples)
            adjustedTiming = timing
        }

        chunks.append(AudioSampleChunk(samples: copied, timing: adjustedTiming))
        storedSamples += copied.count

        while storedSamples > capacitySamples, let first = chunks.first {
            storedSamples -= first.samples.count
            droppedSamples += first.samples.count
            chunks.removeFirst()
        }
    }

    func drain() -> (chunks: [AudioSampleChunk], droppedSamples: Int) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }

        let out = chunks
        let dropped = droppedSamples
        chunks.removeAll(keepingCapacity: true)
        storedSamples = 0
        droppedSamples = 0
        return (out, dropped)
    }
}
