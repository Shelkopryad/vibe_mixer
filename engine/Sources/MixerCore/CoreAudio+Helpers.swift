import CoreAudio
import Foundation

public struct CoreAudioError: Error, CustomStringConvertible {
    public let status: OSStatus
    public let context: String

    public var description: String {
        let fourCC = withUnsafeBytes(of: status.bigEndian) { bytes in
            String(bytes: bytes, encoding: .ascii).flatMap { s in
                s.allSatisfy({ $0.isASCII && !$0.isWhitespace || $0 == " " }) ? "'\(s)'" : nil
            }
        }
        return "\(context) failed: \(status)\(fourCC.map { " \($0)" } ?? "")"
    }
}

@discardableResult
public func check(_ status: OSStatus, _ context: @autoclosure () -> String) throws -> OSStatus {
    guard status == noErr else { throw CoreAudioError(status: status, context: context()) }
    return status
}

public extension AudioObjectPropertyAddress {
    init(_ selector: AudioObjectPropertySelector,
         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
         element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) {
        self.init(mSelector: selector, mScope: scope, mElement: element)
    }
}

public extension AudioObjectID {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    func read<T: BitwiseCopyable>(_ selector: AudioObjectPropertySelector,
                 scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                 default value: T) throws -> T {
        var address = AudioObjectPropertyAddress(selector, scope: scope)
        var size = UInt32(MemoryLayout<T>.size)
        var result = value
        try check(AudioObjectGetPropertyData(self, &address, 0, nil, &size, &result),
                  "read \(selector) of object \(self)")
        return result
    }

    func readArray<T: BitwiseCopyable>(_ selector: AudioObjectPropertySelector,
                      scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                      element: T) throws -> [T] {
        var address = AudioObjectPropertyAddress(selector, scope: scope)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size),
                  "size of \(selector) of object \(self)")
        let count = Int(size) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }
        var items = [T](repeating: element, count: count)
        try check(AudioObjectGetPropertyData(self, &address, 0, nil, &size, &items),
                  "read \(selector) of object \(self)")
        return items
    }

    func readString(_ selector: AudioObjectPropertySelector) throws -> String {
        var address = AudioObjectPropertyAddress(selector)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: Unmanaged<CFString>?
        try check(AudioObjectGetPropertyData(self, &address, 0, nil, &size, &value),
                  "read string \(selector) of object \(self)")
        return value?.takeRetainedValue() as String? ?? ""
    }
}
