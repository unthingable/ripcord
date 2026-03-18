import CoreAudio
import Observation

struct AudioInputDevice: Identifiable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

@Observable
final class AudioDeviceEnumerator {
    var inputDevices: [AudioInputDevice] = []

    private var listenerBlock: AudioObjectPropertyListenerBlock?
    private let audioQueue = DispatchQueue(label: "com.vibe.ripcord.deviceEnum")

    init() {
        refresh()
        installHotplugListener()
    }

    deinit {
        removeHotplugListener()
    }

    func refresh() {
        inputDevices = computeDevices()
    }

    /// Query CoreAudio for all input devices. Pure computation, no UI side effects.
    /// Safe to call from any queue.
    private func computeDevices() -> [AudioInputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize
        )
        guard status == noErr, dataSize > 0 else { return [] }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceIDs
        )
        guard status == noErr else { return [] }

        var result: [AudioInputDevice] = []
        for devID in deviceIDs {
            guard hasInputStreams(devID) else { continue }
            guard let uid = deviceUID(devID), let name = deviceName(devID) else { continue }
            // Exclude our own aggregate device
            if name == "Ripcord-Tap" { continue }
            result.append(AudioInputDevice(id: devID, uid: uid, name: name))
        }

        result.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return result
    }

    func deviceID(forUID uid: String) -> AudioDeviceID? {
        inputDevices.first(where: { $0.uid == uid })?.id
    }

    // MARK: - Private

    private func hasInputStreams(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize)
        return status == noErr && dataSize > 0
    }

    private func deviceUID(_ deviceID: AudioDeviceID) -> String? {
        stringProperty(kAudioDevicePropertyDeviceUID, of: deviceID)
    }

    private func deviceName(_ deviceID: AudioDeviceID) -> String? {
        stringProperty(kAudioObjectPropertyName, of: deviceID)
    }

    private func stringProperty(_ selector: AudioObjectPropertySelector, of deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var prop: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &prop)
        guard status == noErr, let cf = prop?.takeUnretainedValue() else { return nil }
        return cf as String
    }

    private func installHotplugListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            nonisolated(unsafe) let s = self
            // CoreAudio queries run here on audioQueue (off main).
            // Only the final inputDevices assignment goes to main.
            let devices = s.computeDevices()
            DispatchQueue.main.async {
                s.inputDevices = devices
            }
        }
        listenerBlock = block

        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, audioQueue, block
        )
    }

    private func removeHotplugListener() {
        guard let block = listenerBlock else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, audioQueue, block
        )
        listenerBlock = nil
    }
}
