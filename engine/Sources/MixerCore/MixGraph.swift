import CoreAudio
import Foundation

/// One running audio graph, inside a single private aggregate device so everything shares
/// one clock:
///
///     mic ──────────┬─────────────────────► main bus ──► output (e.g. BlackHole → Zoom)
///     tapped apps ──┴──► (post-fader) ────► monitor bus ──► monitor device (your headphones)
///     mic ──► mic-to-monitor send ─────────┘
///     pads (PadBank) ──► both buses, like an app source
///
/// With a monitor device the taps mute the apps' own output, so you hear them exactly once,
/// through the monitor bus.
///
/// Taps are not part of this aggregate: each runs in its own (`TapReader`) and is read from a
/// ring buffer, because a tap on an app that isn't playing would stall the whole device.
///
/// The graph is immutable once built; changing a device or the source set means building a
/// new graph. Gains and meters are exchanged with the IO thread through preallocated slots —
/// no locks or allocations on the real-time path.
public final class MixGraph {
    public static let masterSlot = 0
    public static let micSlot = 1
    public static let monitorSlot = 2
    public static let micToMonitorSlot = 3
    public static let padsSlot = 4
    public static let firstSourceSlot = 5

    public let sourceIDs: [String]
    public let sampleRate: Double
    public let hasMonitor: Bool
    public var slotCount: Int { MixGraph.firstSourceSlot + sourceIDs.count }

    private let readers: [TapReader]
    private let tapScratch: UnsafeMutablePointer<Float> // interleaved stereo, IO-owned
    private let pads: PadBank?
    private let aggregateID: AudioObjectID
    private var ioProcID: AudioDeviceIOProcID?

    // Written by the control thread, read by the IO thread.
    private let targetGains: UnsafeMutablePointer<Float>
    // Owned by the IO thread (gain smoothing).
    private let currentGains: UnsafeMutablePointer<Float>
    // Written by the IO thread (max since last read), read and reset by the meter timer.
    private let peaks: UnsafeMutablePointer<Float>

    // Buffer indices inside the aggregate's IOProc buffer lists.
    private let outputBufferIndex: Int
    private let monitorBufferIndex: Int?
    private let micBufferIndex: Int?
    private let micChannel: Int

    public init(output: AudioDevice,
                mic: AudioDevice?,
                micChannel: Int,
                monitor: AudioDevice?,
                sources: [(id: String, processes: [AudioObjectID])],
                pads: PadBank? = nil,
                bufferFrames: UInt32 = 256) throws {
        let mic = mic?.uid == output.uid ? nil : mic
        let monitor = monitor?.uid == output.uid ? nil : monitor
        hasMonitor = monitor != nil
        self.pads = pads

        // A virtual cable must pass audio untouched; its own volume control (BlackHole has one,
        // and macOS volume keys change it while it's the system output) would silently attenuate.
        output.id.resetVolume(scope: kAudioObjectPropertyScopeOutput)
        output.id.resetVolume(scope: kAudioObjectPropertyScopeInput)

        sourceIDs = sources.map(\.id)
        readers = try sources.map {
            try TapReader(processes: $0.processes, name: $0.id, muted: monitor != nil, clock: output)
        }

        // Sub-devices: output first (it's the clock), then mic, then monitor. A headset can be
        // both mic and monitor; it's then listed once.
        var subDevices = [output]
        if let mic { subDevices.append(mic) }
        if let monitor, monitor.uid != mic?.uid { subDevices.append(monitor) }
        aggregateID = try createAggregateDevice(
            name: "MyMixer Engine", mainUID: output.uid,
            subDevices: subDevices.map { (uid: $0.uid, driftCompensation: $0.uid != output.uid) },
            tapUIDs: [])

        // Aggregate streams are ordered by sub-device.
        func firstStream(of device: AudioDevice?, scope: AudioObjectPropertyScope) -> Int? {
            guard let device, let position = subDevices.firstIndex(where: { $0.uid == device.uid }) else { return nil }
            guard device.id.streamCount(scope: scope) > 0 else { return nil }
            return subDevices[..<position].reduce(0) { $0 + $1.id.streamCount(scope: scope) }
        }
        let totalIn = subDevices.reduce(0) { $0 + $1.id.streamCount(scope: kAudioObjectPropertyScopeInput) }
        let totalOut = subDevices.reduce(0) { $0 + $1.id.streamCount(scope: kAudioObjectPropertyScopeOutput) }
        outputBufferIndex = 0
        micBufferIndex = firstStream(of: mic, scope: kAudioObjectPropertyScopeInput)
        monitorBufferIndex = firstStream(of: monitor, scope: kAudioObjectPropertyScopeOutput)
        self.micChannel = max(0, micChannel)

        let slots = MixGraph.firstSourceSlot + sources.count
        targetGains = .allocate(capacity: slots); targetGains.initialize(repeating: 0, count: slots)
        currentGains = .allocate(capacity: slots); currentGains.initialize(repeating: 0, count: slots)
        peaks = .allocate(capacity: slots); peaks.initialize(repeating: 0, count: slots)
        tapScratch = .allocate(capacity: 2 * PadBank.maxFrames)
        tapScratch.initialize(repeating: 0, count: 2 * PadBank.maxFrames)

        try? aggregateID.write(kAudioDevicePropertyBufferFrameSize, bufferFrames)
        sampleRate = (try? aggregateID.read(kAudioDevicePropertyNominalSampleRate, default: Float64(0))) ?? 0

        // deinit cleans up if the layout isn't what the buffer indices assume.
        let actualIn = aggregateID.streamCount(scope: kAudioObjectPropertyScopeInput)
        let actualOut = aggregateID.streamCount(scope: kAudioObjectPropertyScopeOutput)
        guard actualIn == totalIn, actualOut == totalOut else {
            throw MixGraphError.unexpectedLayout(
                expected: "\(totalIn) in / \(totalOut) out", actual: "\(actualIn) in / \(actualOut) out")
        }
    }

    public func setGain(slot: Int, _ gain: Float) {
        guard slot >= 0, slot < slotCount else { return }
        targetGains[slot] = gain
    }

    /// Peak levels (linear, 0...1+) since the previous call.
    public func takePeaks() -> [Float] {
        (0..<slotCount).map { slot in
            let p = peaks[slot]
            peaks[slot] = 0
            return p
        }
    }

    public func start() throws {
        for reader in readers { try reader.start() }
        var procID: AudioDeviceIOProcID?
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) { [unowned self] _, input, _, output, _ in
            self.render(input: input, output: output)
        }, "AudioDeviceCreateIOProcIDWithBlock")
        ioProcID = procID
        try check(AudioDeviceStart(aggregateID, procID), "AudioDeviceStart")
    }

    public func stop() {
        for reader in readers { reader.stop() }
        guard let procID = ioProcID else { return }
        AudioDeviceStop(aggregateID, procID)
        AudioDeviceDestroyIOProcID(aggregateID, procID)
        ioProcID = nil
    }

    deinit {
        stop()
        AudioHardwareDestroyAggregateDevice(aggregateID)
        targetGains.deallocate()
        currentGains.deallocate()
        peaks.deallocate()
        tapScratch.deallocate()
    }

    // MARK: - Real-time path

    /// An interleaved output buffer inside the aggregate's output list.
    private struct Bus {
        let data: UnsafeMutablePointer<Float>
        let channels: Int
        let frames: Int

        init?(_ buffer: AudioBuffer) {
            guard let mData = buffer.mData, buffer.mNumberChannels > 0 else { return nil }
            data = mData.assumingMemoryBound(to: Float.self)
            channels = Int(buffer.mNumberChannels)
            frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)
        }

        @inline(__always) func add(_ frame: Int, _ l: Float, _ r: Float) {
            data[frame * channels] += l
            if channels > 1 { data[frame * channels + 1] += r }
        }
    }

    private func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
        let outs = UnsafeMutableAudioBufferListPointer(output)
        for buffer in outs where buffer.mData != nil {
            memset(buffer.mData, 0, Int(buffer.mDataByteSize))
        }
        guard outputBufferIndex < outs.count, let main = Bus(outs[outputBufferIndex]) else { return }
        let monitor = monitorBufferIndex.flatMap { $0 < outs.count ? Bus(outs[$0]) : nil }
        let frames = min(main.frames, monitor?.frames ?? .max)
        guard frames > 0 else { return }

        let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))

        if let micIndex = micBufferIndex, micIndex < ins.count,
           let data = ins[micIndex].mData?.assumingMemoryBound(to: Float.self) {
            let channels = Int(ins[micIndex].mNumberChannels)
            if channels > 0 {
                let available = Int(ins[micIndex].mDataByteSize) / (MemoryLayout<Float>.size * channels)
                let ch = min(micChannel, channels - 1)
                mix(slot: MixGraph.micSlot, sendSlot: MixGraph.micToMonitorSlot,
                    frames: min(frames, available), main: main, monitor: monitor) {
                    let s = data[$0 * channels + ch]
                    return (s, s)
                }
            }
        }

        let tapFrames = min(frames, PadBank.maxFrames)
        let scratch = tapScratch
        for (i, reader) in readers.enumerated() {
            // Mix even when silent, so the gain ramp and meter keep tracking.
            _ = reader.consume(frames: tapFrames, into: scratch)
            mix(slot: MixGraph.firstSourceSlot + i, sendSlot: nil,
                frames: tapFrames, main: main, monitor: monitor) { (scratch[2 * $0], scratch[2 * $0 + 1]) }
        }

        if let pads, pads.render(frames: frames) {
            let scratch = pads.scratch
            mix(slot: MixGraph.padsSlot, sendSlot: nil, frames: min(frames, PadBank.maxFrames),
                main: main, monitor: monitor) { (scratch[2 * $0], scratch[2 * $0 + 1]) }
        }

        applyBusGain(slot: MixGraph.masterSlot, bus: main, frames: frames)
        if let monitor { applyBusGain(slot: MixGraph.monitorSlot, bus: monitor, frames: frames) }
    }

    /// Adds a stereo source into the main bus with a smoothed gain, and post-fader into the
    /// monitor bus (scaled by `sendSlot`'s gain when given). Meters the post-fader signal.
    @inline(__always)
    private func mix(slot: Int, sendSlot: Int?, frames: Int, main: Bus, monitor: Bus?,
                     sample: (Int) -> (Float, Float)) {
        let (g0, step) = ramp(slot: slot, frames: frames)
        let (s0, sendStep) = sendSlot.map { ramp(slot: $0, frames: frames) } ?? (1, 0)
        var peak: Float = 0
        for f in 0..<frames {
            let g = g0 + step * Float(f)
            let (l, r) = sample(f)
            let gl = l * g, gr = r * g
            main.add(f, gl, gr)
            if let monitor {
                let send = s0 + sendStep * Float(f)
                monitor.add(f, gl * send, gr * send)
            }
            peak = max(peak, abs(gl), abs(gr))
        }
        peaks[slot] = max(peaks[slot], peak)
    }

    /// Bus gain + hard clip, metered post-gain.
    @inline(__always)
    private func applyBusGain(slot: Int, bus: Bus, frames: Int) {
        let (g0, step) = ramp(slot: slot, frames: frames)
        var peak: Float = 0
        for f in 0..<frames {
            let g = g0 + step * Float(f)
            for c in 0..<min(bus.channels, 2) {
                let v = min(1, max(-1, bus.data[f * bus.channels + c] * g))
                bus.data[f * bus.channels + c] = v
                peak = max(peak, abs(v))
            }
        }
        peaks[slot] = max(peaks[slot], peak)
    }

    /// Linear ramp from the current gain to the target over one buffer (avoids zipper noise).
    @inline(__always)
    private func ramp(slot: Int, frames: Int) -> (start: Float, step: Float) {
        let start = currentGains[slot]
        let target = targetGains[slot]
        currentGains[slot] = target
        return (start, frames > 0 ? (target - start) / Float(frames) : 0)
    }
}

public enum MixGraphError: Error, CustomStringConvertible {
    case unexpectedLayout(expected: String, actual: String)

    public var description: String {
        switch self {
        case let .unexpectedLayout(expected, actual):
            "aggregate device has \(actual) streams, expected \(expected)"
        }
    }
}
