import CoreAudio
import Foundation

enum Direction: String, CaseIterable {
    case output, input

    var isInput: Bool { self == .input }
    var defaultEmoji: String { isInput ? "🎙️" : "🔈" }
}

struct AudioDevice: Equatable {
    let id: AudioDeviceID
    /// Stable across reconnects and reboots, unlike `id`, so it's what preferences are keyed by
    let uid: String
    let name: String
}

// Thin wrappers around the CoreAudio HAL for listing devices and reading/setting the defaults
enum AudioHAL {
    /// Posted on the main queue when devices are added/removed or a default device changes
    static let didChangeNotification = Notification.Name("AudIOAudioDevicesDidChange")

    private static let system = AudioObjectID(kAudioObjectSystemObject)

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func defaultSelector(_ direction: Direction) -> AudioObjectPropertySelector {
        direction.isInput ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice
    }

    /// Every device that has at least one stream in the given direction
    static func devices(_ direction: Direction) -> [AudioDevice] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }

        var streamsAddr = address(kAudioDevicePropertyStreams,
                                  scope: direction.isInput ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput)
        return ids.compactMap { id in
            var streamsSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streamsAddr, 0, nil, &streamsSize) == noErr, streamsSize > 0 else { return nil }
            let uid = string(kAudioDevicePropertyDeviceUID, of: id)
            guard !uid.isEmpty else { return nil }
            return AudioDevice(id: id, uid: uid, name: string(kAudioObjectPropertyName, of: id))
        }
    }

    static func defaultDevice(_ direction: Direction) -> AudioDeviceID? {
        var addr = address(defaultSelector(direction))
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &id) == noErr,
              id != kAudioObjectUnknown else { return nil }
        return id
    }

    static func setDefaultDevice(_ id: AudioDeviceID, _ direction: Direction) {
        var addr = address(defaultSelector(direction))
        var id = id
        AudioObjectSetPropertyData(system, &addr, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &id)
    }

    static func startObservingChanges() {
        for selector in [kAudioHardwarePropertyDevices,
                         kAudioHardwarePropertyDefaultInputDevice,
                         kAudioHardwarePropertyDefaultOutputDevice] {
            var addr = address(selector)
            AudioObjectAddPropertyListenerBlock(system, &addr, .main) { _, _ in
                NotificationCenter.default.post(name: didChangeNotification, object: nil)
            }
        }
    }

    private static func string(_ selector: AudioObjectPropertySelector, of id: AudioDeviceID) -> String {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr, let value else { return "" }
        return value.takeRetainedValue() as String
    }
}
