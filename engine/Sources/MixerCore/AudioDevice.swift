import CoreAudio
import Foundation

public struct AudioDevice: Sendable, Codable, Equatable {
    public let id: AudioObjectID
    public let uid: String
    public let name: String
    public let inputChannels: Int
    public let outputChannels: Int

    public static func all() throws -> [AudioDevice] {
        let ids = try AudioObjectID.system.readArray(kAudioHardwarePropertyDevices, element: AudioObjectID(0))
        return ids.compactMap { id in
            guard let uid = try? id.readString(kAudioDevicePropertyDeviceUID),
                  !uid.hasPrefix("local.mymixer.") else { return nil }
            return AudioDevice(
                id: id, uid: uid,
                name: (try? id.readString(kAudioObjectPropertyName)) ?? uid,
                inputChannels: id.channelCount(scope: kAudioObjectPropertyScopeInput),
                outputChannels: id.channelCount(scope: kAudioObjectPropertyScopeOutput))
        }
    }

    public static func find(uid: String) -> AudioDevice? {
        (try? all())?.first { $0.uid == uid }
    }

    public static func defaultInput() -> AudioDevice? { systemDefault(kAudioHardwarePropertyDefaultInputDevice) }
    public static func defaultOutput() -> AudioDevice? { systemDefault(kAudioHardwarePropertyDefaultOutputDevice) }

    private static func systemDefault(_ selector: AudioObjectPropertySelector) -> AudioDevice? {
        guard let id = try? AudioObjectID.system.read(selector, default: AudioObjectID(kAudioObjectUnknown)) else { return nil }
        return (try? all())?.first { $0.id == id }
    }
}

extension AudioObjectID {
    func channelCount(scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(kAudioDevicePropertyStreamConfiguration, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(self, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    func streamCount(scope: AudioObjectPropertyScope) -> Int {
        (try? readArray(kAudioDevicePropertyStreams, scope: scope, element: AudioStreamID(0)).count) ?? 0
    }

    /// Sets the main volume to 100% and unmutes, where the device has those controls.
    func resetVolume(scope: AudioObjectPropertyScope) {
        try? write(kAudioDevicePropertyVolumeScalar, Float32(1), scope: scope)
        try? write(kAudioDevicePropertyMute, UInt32(0), scope: scope)
    }

    func write<T: BitwiseCopyable>(_ selector: AudioObjectPropertySelector, _ value: T,
                                   scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws {
        var address = AudioObjectPropertyAddress(selector, scope: scope)
        var v = value
        try check(AudioObjectSetPropertyData(self, &address, 0, nil, UInt32(MemoryLayout<T>.size), &v),
                  "write \(selector) of object \(self)")
    }
}
