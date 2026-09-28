import CoreAudio
import Foundation

/// An app as the user sees it: helper processes (e.g. `com.google.Chrome.helper`)
/// are grouped under the parent bundle ID, since that's where browsers play audio.
public struct AudioApp: Sendable, Codable {
    /// Source ID: the bundle ID, or `pid:<n>` for processes without one.
    public let id: String
    public let name: String
    public let isPlaying: Bool
    /// A regular app (Dock icon) rather than a daemon; UIs can hide the rest by default.
    public let isApp: Bool

    public static func all(excludingPID: pid_t = getpid()) throws -> [AudioApp] {
        let processes = try AudioProcess.all().filter { $0.pid != excludingPID }
        let bundleIDs = Set(processes.map(\.bundleID).filter { !$0.isEmpty })

        var apps: [String: AudioApp] = [:]
        for p in processes {
            let id = p.bundleID.isEmpty ? "pid:\(p.pid)" : AudioApp.parentID(of: p.bundleID, among: bundleIDs)
            let isParent = id == p.bundleID || id.hasPrefix("pid:")
            let existing = apps[id]
            apps[id] = AudioApp(
                id: id,
                name: isParent ? p.name : existing?.name ?? p.name,
                isPlaying: (existing?.isPlaying ?? false) || p.isPlaying,
                isApp: (existing?.isApp ?? false) || p.isApp)
        }
        return apps.values.sorted { ($0.isPlaying ? 0 : 1, $0.name) < ($1.isPlaying ? 0 : 1, $1.name) }
    }

    /// The Core Audio process objects that make up the source with this ID.
    public static func processObjects(for id: String, in processes: [AudioProcess]) -> [AudioObjectID] {
        if id.hasPrefix("pid:"), let pid = pid_t(id.dropFirst(4)) {
            return processes.filter { $0.pid == pid }.map(\.objectID)
        }
        return processes.filter { $0.bundleID == id || $0.bundleID.hasPrefix(id + ".") }.map(\.objectID)
    }

    private static func parentID(of bundleID: String, among all: Set<String>) -> String {
        var parts = bundleID.split(separator: ".")
        var best = bundleID
        while parts.count > 2 {
            parts.removeLast()
            let candidate = parts.joined(separator: ".")
            if all.contains(candidate) { best = candidate }
        }
        return best
    }
}
