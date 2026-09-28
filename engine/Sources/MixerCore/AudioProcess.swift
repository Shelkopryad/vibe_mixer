import AppKit
import CoreAudio
import Darwin

/// A process known to Core Audio (anything that has opened an audio client).
public struct AudioProcess: Sendable {
    public let objectID: AudioObjectID
    public let pid: pid_t
    public let bundleID: String
    public let name: String
    public let isPlaying: Bool
    /// A regular app with a Dock icon (as opposed to daemons and helpers).
    public let isApp: Bool

    public static func all() throws -> [AudioProcess] {
        let ids = try AudioObjectID.system.readArray(
            kAudioHardwarePropertyProcessObjectList, element: AudioObjectID(0))
        return ids.compactMap { id in
            guard let pid = try? id.read(kAudioProcessPropertyPID, default: pid_t(-1)) else { return nil }
            let bundleID = (try? id.readString(kAudioProcessPropertyBundleID)) ?? ""
            let playing = (try? id.read(kAudioProcessPropertyIsRunningOutput, default: UInt32(0))) ?? 0
            let app = NSRunningApplication(processIdentifier: pid)
            let name = app?.localizedName
                ?? app?.executableURL?.lastPathComponent
                ?? processName(pid)
                ?? (bundleID.isEmpty ? "pid \(pid)" : bundleID)
            return AudioProcess(objectID: id, pid: pid, bundleID: bundleID,
                                name: name, isPlaying: playing != 0,
                                isApp: app?.activationPolicy == .regular)
        }
    }
}

private func processName(_ pid: pid_t) -> String? {
    var buffer = [CChar](repeating: 0, count: 1024)
    guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
    return String(cString: buffer)
}
