import CoreAudio
import Foundation

/// A Core Audio process tap: a stereo mixdown of the given processes' output.
/// Unless `muted`, the tapped processes keep playing to their own output as well;
/// when muted, they're silenced only while the tap is being read. Destroyed on deinit.
public final class Tap {
    public let id: AudioObjectID
    public let uid: String

    public init(processes: [AudioObjectID], name: String, muted: Bool = false) throws {
        let description = CATapDescription(stereoMixdownOfProcesses: processes)
        description.name = name
        description.isPrivate = true
        description.muteBehavior = muted ? .mutedWhenTapped : .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(description, &tap), "AudioHardwareCreateProcessTap")
        id = tap
        uid = description.uuid.uuidString
    }

    public func format() throws -> AudioStreamBasicDescription {
        try id.read(kAudioTapPropertyFormat, default: AudioStreamBasicDescription())
    }

    deinit { AudioHardwareDestroyProcessTap(id) }
}
