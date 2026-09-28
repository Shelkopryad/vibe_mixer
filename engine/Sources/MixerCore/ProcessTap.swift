import AudioToolbox
import CoreAudio
import Foundation

/// Captures the audio output of one or more processes via a Core Audio process tap
/// (macOS 14.2+). The tapped apps keep playing to their normal output.
///
/// A tap can't be read directly: it is wrapped into a private aggregate device,
/// clocked by the default output device, and read through an IOProc.
public final class ProcessTap {
    public typealias IOHandler = (_ input: UnsafePointer<AudioBufferList>, _ frames: UInt32) -> Void

    public let format: AudioStreamBasicDescription
    private let tap: Tap
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?

    public init(processes: [AudioObjectID]) throws {
        tap = try Tap(processes: processes, name: "MyMixer tap")
        format = try tap.format()

        let outputID = try AudioObjectID.system.read(
            kAudioHardwarePropertyDefaultSystemOutputDevice, default: AudioObjectID(kAudioObjectUnknown))
        let outputUID = try outputID.readString(kAudioDevicePropertyDeviceUID)

        aggregateID = try createAggregateDevice(
            name: "MyMixer Tap Aggregate",
            mainUID: outputUID,
            subDevices: [(uid: outputUID, driftCompensation: false)],
            tapUIDs: [tap.uid])
    }

    public func start(queue: DispatchQueue? = nil, handler: @escaping IOHandler) throws {
        let bytesPerFrame = max(format.mBytesPerFrame, 1)
        var procID: AudioDeviceIOProcID?
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { _, input, _, _, _ in
            handler(input, input.pointee.mBuffers.mDataByteSize / bytesPerFrame)
        }, "AudioDeviceCreateIOProcIDWithBlock")
        ioProcID = procID
        try check(AudioDeviceStart(aggregateID, procID), "AudioDeviceStart")
    }

    public func invalidate() {
        if let procID = ioProcID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            ioProcID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    deinit { invalidate() }
}

/// Creates a private aggregate device (visible only to this process).
func createAggregateDevice(name: String,
                           mainUID: String,
                           subDevices: [(uid: String, driftCompensation: Bool)],
                           tapUIDs: [String]) throws -> AudioObjectID {
    let config: [String: Any] = [
        kAudioAggregateDeviceNameKey: name,
        kAudioAggregateDeviceUIDKey: "local.mymixer.aggregate.\(UUID().uuidString)",
        kAudioAggregateDeviceMainSubDeviceKey: mainUID,
        kAudioAggregateDeviceIsPrivateKey: true,
        kAudioAggregateDeviceIsStackedKey: false,
        kAudioAggregateDeviceTapAutoStartKey: true,
        kAudioAggregateDeviceSubDeviceListKey: subDevices.map {
            [kAudioSubDeviceUIDKey: $0.uid,
             kAudioSubDeviceDriftCompensationKey: $0.driftCompensation ? 1 : 0] as [String: Any]
        },
        kAudioAggregateDeviceTapListKey: tapUIDs.map {
            [kAudioSubTapUIDKey: $0, kAudioSubTapDriftCompensationKey: true] as [String: Any]
        },
    ]
    var aggregate = AudioObjectID(kAudioObjectUnknown)
    try check(AudioHardwareCreateAggregateDevice(config as CFDictionary, &aggregate),
              "AudioHardwareCreateAggregateDevice")
    return aggregate
}
