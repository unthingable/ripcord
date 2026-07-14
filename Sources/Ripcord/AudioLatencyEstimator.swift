import CoreAudio
import Foundation

struct AudioLatencyEstimate: Equatable, Sendable {
    let inputMs: Double
    let outputMs: Double
    let isPartial: Bool

    var totalMs: Double { inputMs + outputMs }
}

enum AudioLatencyEstimator {
    private struct DeviceLatency {
        let milliseconds: Double
        let isPartial: Bool
    }

    static func estimate(inputDeviceID: AudioDeviceID?) -> AudioLatencyEstimate? {
        let input = inputDeviceID.flatMap {
            deviceLatency(deviceID: $0, scope: kAudioDevicePropertyScopeInput)
        }
        let output = defaultOutputDeviceID().flatMap {
            deviceLatency(deviceID: $0, scope: kAudioDevicePropertyScopeOutput)
        }

        guard input != nil || output != nil else { return nil }
        return AudioLatencyEstimate(
            inputMs: input?.milliseconds ?? 0,
            outputMs: output?.milliseconds ?? 0,
            isPartial: input == nil || output == nil
                || input?.isPartial == true || output?.isPartial == true
        )
    }

    private static func deviceLatency(
        deviceID: AudioDeviceID, scope: AudioObjectPropertyScope
    ) -> DeviceLatency? {
        let latency = uint32Property(
            kAudioDevicePropertyLatency, objectID: deviceID, scope: scope)
        let safety = uint32Property(
            kAudioDevicePropertySafetyOffset, objectID: deviceID, scope: scope)
        let buffer = uint32Property(
            kAudioDevicePropertyBufferFrameSize, objectID: deviceID, scope: scope)
        let stream = streamLatencyFrames(deviceID: deviceID, scope: scope)
        guard latency != nil || safety != nil || buffer != nil || stream != nil,
              let sampleRate = nominalSampleRate(deviceID: deviceID), sampleRate > 0 else {
            return nil
        }
        let frames = UInt64(latency ?? 0) + UInt64(safety ?? 0)
            + UInt64(buffer ?? 0) + UInt64(stream ?? 0)
        return DeviceLatency(
            milliseconds: Double(frames) * 1000.0 / sampleRate,
            isPartial: latency == nil || safety == nil || buffer == nil || stream == nil
        )
    }

    private static func nominalSampleRate(deviceID: AudioDeviceID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value
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

    private static func streamLatencyFrames(
        deviceID: AudioDeviceID, scope: AudioObjectPropertyScope
    ) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioStreamID>.size) else { return nil }
        var streams = [AudioStreamID](
            repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &streams) == noErr else {
            return nil
        }
        let values = streams.compactMap {
            uint32Property(
                kAudioStreamPropertyLatency,
                objectID: $0,
                scope: kAudioObjectPropertyScopeGlobal
            )
        }
        return values.max()
    }

    private static func uint32Property(_ selector: AudioObjectPropertySelector,
                                       objectID: AudioObjectID,
                                       scope: AudioObjectPropertyScope) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value
    }
}
