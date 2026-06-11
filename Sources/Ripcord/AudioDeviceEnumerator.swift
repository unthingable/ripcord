import CoreAudio
import Observation

struct AudioInputDevice: Identifiable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let inputChannelCount: Int
    let transportType: UInt32?

    var isUSBTransport: Bool {
        transportType == kAudioDeviceTransportTypeUSB
    }

    var isNamedMicrophone: Bool {
        let lowercased = name.lowercased()
        return lowercased == "mic"
            || lowercased.hasPrefix("mic ")
            || lowercased.contains("microphone")
            || lowercased.contains(" mic")
    }

    var shouldSkipAutomaticTranscription: Bool {
        isUSBTransport && !isNamedMicrophone
    }
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
            let chCount = inputChannelCount(devID)
            guard chCount > 0 else { continue }
            guard let uid = deviceUID(devID), let name = deviceName(devID) else { continue }
            // Exclude our own aggregate device
            if name == "Ripcord-Tap" { continue }
            result.append(AudioInputDevice(
                id: devID,
                uid: uid,
                name: name,
                inputChannelCount: chCount,
                transportType: transportType(devID)
            ))
        }

        result.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return result
    }

    func deviceID(forUID uid: String) -> AudioDeviceID? {
        inputDevices.first(where: { $0.uid == uid })?.id
    }

    // MARK: - Private

    /// Returns the total number of input channels the device exposes (summed
    /// across all input streams). 0 means the device has no input (output-only).
    private func inputChannelCount(_ deviceID: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr,
              dataSize >= UInt32(MemoryLayout<AudioBufferList>.size) else {
            return 0
        }
        let bufferListPtr = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize), alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { bufferListPtr.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, bufferListPtr) == noErr else {
            return 0
        }
        let abl = UnsafeMutableAudioBufferListPointer(
            bufferListPtr.bindMemory(to: AudioBufferList.self, capacity: 1)
        )
        var total: UInt32 = 0
        for i in 0..<abl.count {
            total += abl[i].mNumberChannels
        }
        return Int(total)
    }

    private func deviceUID(_ deviceID: AudioDeviceID) -> String? {
        stringProperty(kAudioDevicePropertyDeviceUID, of: deviceID)
    }

    private func deviceName(_ deviceID: AudioDeviceID) -> String? {
        stringProperty(kAudioObjectPropertyName, of: deviceID)
    }

    private func transportType(_ deviceID: AudioDeviceID) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &value)
        guard status == noErr else { return nil }
        return value
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
        guard status == noErr, let cf = prop?.takeRetainedValue() else { return nil }
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
