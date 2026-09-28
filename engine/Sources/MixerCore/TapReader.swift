import CAtomics
import CoreAudio
import Foundation

/// Reads one process tap in its own private aggregate device and hands the audio to the main
/// graph through a lock-free single-producer/single-consumer ring buffer.
///
/// Why not put taps straight into the main aggregate: a tap on a process that isn't playing
/// (Telegram, Chrome, Zoom between sounds) never delivers IO, and an aggregate containing it
/// stalls entirely — mic and pads included. Isolated like this, an idle app just yields
/// silence, and its IO resumes by itself once the app plays again.
///
/// The tap aggregate is clocked by the same device as the main graph, so producer and
/// consumer run at the same rate; the ring only absorbs scheduling jitter.
final class TapReader {
    static let capacity = 16384 // frames, power of two
    private static let mask = UInt64(capacity - 1)
    /// Latency the consumer primes to before playing (and returns to after an underrun).
    static let targetFill: UInt64 = 768
    /// Beyond this the consumer skips ahead to `targetFill` (e.g. after the main IO hiccuped).
    static let maxFill: UInt64 = 4096

    private let tap: Tap
    private let aggregateID: AudioObjectID
    private let tapBufferIndex: Int
    private var ioProcID: AudioDeviceIOProcID?

    private let ring: UnsafeMutablePointer<Float>          // interleaved stereo
    private let writeIndex: UnsafeMutablePointer<UInt64>   // frames written (producer-owned)
    private let readIndex: UnsafeMutablePointer<UInt64>    // frames read (consumer-owned)
    private var priming = true                             // consumer-only

    init(processes: [AudioObjectID], name: String, muted: Bool, clock: AudioDevice) throws {
        tap = try Tap(processes: processes, name: name, muted: muted)
        aggregateID = try createAggregateDevice(
            name: "MyMixer \(name)", mainUID: clock.uid,
            subDevices: [(uid: clock.uid, driftCompensation: false)], tapUIDs: [tap.uid])
        // The clock device's own input streams come first, then the tap's.
        tapBufferIndex = clock.id.streamCount(scope: kAudioObjectPropertyScopeInput)

        ring = .allocate(capacity: 2 * TapReader.capacity)
        ring.initialize(repeating: 0, count: 2 * TapReader.capacity)
        writeIndex = .allocate(capacity: 1); writeIndex.initialize(to: 0)
        readIndex = .allocate(capacity: 1); readIndex.initialize(to: 0)
    }

    func start() throws {
        var procID: AudioDeviceIOProcID?
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) { [unowned self] _, input, _, _, _ in
            self.produce(input)
        }, "AudioDeviceCreateIOProcIDWithBlock (tap)")
        ioProcID = procID
        try check(AudioDeviceStart(aggregateID, procID), "AudioDeviceStart (tap)")
    }

    func stop() {
        guard let procID = ioProcID else { return }
        AudioDeviceStop(aggregateID, procID)
        AudioDeviceDestroyIOProcID(aggregateID, procID)
        ioProcID = nil
    }

    deinit {
        stop()
        AudioHardwareDestroyAggregateDevice(aggregateID)
        ring.deallocate()
        writeIndex.deallocate()
        readIndex.deallocate()
    }

    // MARK: - Producer (tap aggregate's IO thread)

    private func produce(_ input: UnsafePointer<AudioBufferList>) {
        let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard tapBufferIndex < ins.count,
              let data = ins[tapBufferIndex].mData?.assumingMemoryBound(to: Float.self) else { return }
        let channels = Int(ins[tapBufferIndex].mNumberChannels)
        guard channels > 0 else { return }
        let frames = Int(ins[tapBufferIndex].mDataByteSize) / (MemoryLayout<Float>.size * channels)

        let w = writeIndex.pointee
        let r = ca_load_u64(readIndex)
        let free = UInt64(TapReader.capacity) - (w - r)
        let count = min(UInt64(frames), free) // on overflow, drop the newest frames
        for f in 0..<Int(count) {
            let i = Int((w + UInt64(f)) & TapReader.mask) * 2
            let l = data[f * channels]
            ring[i] = l
            ring[i + 1] = channels > 1 ? data[f * channels + 1] : l
        }
        ca_store_u64(writeIndex, w + count)
    }

    // MARK: - Consumer (main graph's IO thread)

    /// Fills `frames` interleaved stereo frames into `out`, with silence where no audio is buffered.
    /// Returns false if everything written is silence.
    func consume(frames: Int, into out: UnsafeMutablePointer<Float>) -> Bool {
        let w = ca_load_u64(writeIndex)
        var r = readIndex.pointee
        var available = w - r
        if available > TapReader.maxFill {
            r = w - TapReader.targetFill
            available = TapReader.targetFill
        }
        if priming {
            guard available >= TapReader.targetFill else {
                memset(out, 0, 2 * frames * MemoryLayout<Float>.size)
                return false
            }
            priming = false
        }

        let count = Int(min(UInt64(frames), available))
        for f in 0..<count {
            let i = Int((r + UInt64(f)) & TapReader.mask) * 2
            out[2 * f] = ring[i]
            out[2 * f + 1] = ring[i + 1]
        }
        if count < frames {
            memset(out + 2 * count, 0, 2 * (frames - count) * MemoryLayout<Float>.size)
            priming = true // underrun (app went quiet): re-prime before playing again
        }
        ca_store_u64(readIndex, r + UInt64(count))
        return count > 0
    }
}
