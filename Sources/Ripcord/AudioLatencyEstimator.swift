import CoreAudio
import Foundation

struct AudioLatencyEstimate: Equatable, Sendable {
    let inputMs: Double
    let outputMs: Double
    let isPartial: Bool

    var totalMs: Double { inputMs + outputMs }
}

enum AudioLatencyEstimator {
    static func estimate(inputDeviceID: AudioDeviceID?) -> AudioLatencyEstimate? {
        let input = inputDeviceID.flatMap { latencyFrames(deviceID: $0, scope: kAudioDevicePropertyScopeInput) }
        let output = defaultOutputDeviceID().flatMap {
            latencyFrames(deviceID: $0, scope: kAudioDevicePropertyScopeOutput)
        }

        guard input != nil || output != nil else { return nil }
        return AudioLatencyEstimate(
            inputMs: Double(input ?? 0) * 1000.0 / AudioConstants.sampleRate,
            outputMs: Double(output ?? 0) * 1000.0 / AudioConstants.sampleRate,
            isPartial: input == nil || output == nil
        )
    }

    private static func defaultOutputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        ) == noErr, deviceID != 0 else {
            return nil
        }
        return deviceID
    }

    private static func latencyFrames(deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) -> UInt32? {
        let latency = uint32Property(kAudioDevicePropertyLatency, deviceID: deviceID, scope: scope)
        let safety = uint32Property(kAudioDevicePropertySafetyOffset, deviceID: deviceID, scope: scope)
        let buffer = uint32Property(kAudioDevicePropertyBufferFrameSize, deviceID: deviceID, scope: scope)
        let total = (latency ?? 0) + (safety ?? 0) + (buffer ?? 0)
        return total > 0 ? total : nil
    }

    private static func uint32Property(_ selector: AudioObjectPropertySelector,
                                       deviceID: AudioDeviceID,
                                       scope: AudioObjectPropertyScope) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value
    }
}
