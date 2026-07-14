import CoreAudio
import Foundation

struct AudioSampleTiming: Sendable {
    let hostTime: UInt64
    let sampleTime: Double?
    let sampleRate: Double
    let channelsPerFrame: Int

    static func from(_ timestamp: AudioTimeStamp?, sampleRate: Double,
                     channelsPerFrame: Int = CircularAudioBuffer.channelsPerFrame,
                     fallbackHostTime: UInt64? = nil) -> AudioSampleTiming {
        let hostTime: UInt64
        if let timestamp, timestamp.mFlags.contains(.hostTimeValid), timestamp.mHostTime > 0 {
            hostTime = timestamp.mHostTime
        } else {
            hostTime = fallbackHostTime ?? AudioGetCurrentHostTime()
        }

        let sampleTime = timestamp?.mFlags.contains(.sampleTimeValid) == true
            ? timestamp?.mSampleTime
            : nil

        return AudioSampleTiming(
            hostTime: hostTime,
            sampleTime: sampleTime,
            sampleRate: sampleRate,
            channelsPerFrame: channelsPerFrame
        )
    }

    var hostFramePosition: Int64 {
        let nanos = AudioConvertHostTimeToNanos(hostTime)
        return Int64((Double(nanos) * AudioConstants.sampleRate / 1_000_000_000.0).rounded())
    }
}

struct AudioSampleChunk: Sendable {
    var samples: [Float]
    var timing: AudioSampleTiming

    var frameCount: Int {
        samples.count / max(1, timing.channelsPerFrame)
    }

    var startFrame: Int64 {
        timing.hostFramePosition
    }

    var endFrame: Int64 {
        startFrame + Int64(frameCount)
    }

    func shiftedStart(by frames: Int64) -> AudioSampleChunk {
        var copy = self
        let shiftedHostFrame = startFrame + frames
        let hostNanos = UInt64(max(0, Double(shiftedHostFrame) * 1_000_000_000.0 / AudioConstants.sampleRate))
        copy.timing = AudioSampleTiming(
            hostTime: AudioConvertNanosToHostTime(hostNanos),
            sampleTime: timing.sampleTime.map { $0 + Double(frames) },
            sampleRate: timing.sampleRate,
            channelsPerFrame: timing.channelsPerFrame
        )
        return copy
    }

    func trimming(before frame: Int64) -> AudioSampleChunk? {
        guard frame > startFrame else { return self }
        guard frame < endFrame else { return nil }
        let dropFrames = Int(frame - startFrame)
        let ch = max(1, timing.channelsPerFrame)
        let dropSamples = min(samples.count, dropFrames * ch)
        var copy = self
        copy.samples = Array(samples.dropFirst(dropSamples))
        copy.timing = AudioSampleTiming(
            hostTime: AudioConvertNanosToHostTime(
                AudioConvertHostTimeToNanos(timing.hostTime)
                    + UInt64(Double(dropFrames) * 1_000_000_000.0 / AudioConstants.sampleRate)
            ),
            sampleTime: timing.sampleTime.map { $0 + Double(dropFrames) },
            sampleRate: timing.sampleRate,
            channelsPerFrame: timing.channelsPerFrame
        )
        return copy
    }
}
