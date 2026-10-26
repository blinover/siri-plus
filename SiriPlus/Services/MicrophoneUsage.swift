import CoreAudio

protocol MicrophoneUsageSource: Sendable {
    /// Bundle identifiers of the processes recording from any input device right now.
    func appsUsingMicrophone() -> Set<String>
}

/// Reads CoreAudio's process list. It tells which apps record, not what they record, and needs no permission.
struct CoreAudioMicrophoneUsage: MicrophoneUsageSource {
    func appsUsingMicrophone() -> Set<String> {
        var address = Self.address(kAudioHardwarePropertyProcessObjectList)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var processes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &processes) == noErr else { return [] }
        return Set(processes.compactMap { process in
            isRecording(process) ? bundleID(of: process) : nil
        })
    }

    private func isRecording(_ process: AudioObjectID) -> Bool {
        var address = Self.address(kAudioProcessPropertyIsRunningInput)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(process, &address, 0, nil, &size, &value) == noErr && value == 1
    }

    private func bundleID(of process: AudioObjectID) -> String? {
        var address = Self.address(kAudioProcessPropertyBundleID)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &value) == noErr else { return nil }
        // CoreAudio hands over ownership of the string.
        return value?.takeRetainedValue() as String?
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }
}

/// Where the default output device plays.
enum AudioOutput {
    /// Whether the call plays out loud, so the microphone hears it: built-in speakers, displays and AirPlay.
    /// Bluetooth and USB devices count as headsets, since CoreAudio does not tell headphones from speakers there.
    static func isLoudspeaker() -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else {
            return false
        }
        return isLoudspeaker(
            transport: value(kAudioDevicePropertyTransportType, scope: kAudioObjectPropertyScopeGlobal, of: device),
            dataSource: value(kAudioDevicePropertyDataSource, scope: kAudioObjectPropertyScopeOutput, of: device)
        )
    }

    static func isLoudspeaker(transport: UInt32?, dataSource: UInt32?) -> Bool {
        switch transport {
        // The built-in output is either the internal speakers or the headphone jack ('hdpn').
        case kAudioDeviceTransportTypeBuiltIn: dataSource != 0x6864_706E
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort, kAudioDeviceTransportTypeAirPlay: true
        default: false
        }
    }

    private static func value(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope, of device: AudioObjectID) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr ? value : nil
    }
}
