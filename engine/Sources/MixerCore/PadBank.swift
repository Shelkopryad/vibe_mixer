import AVFoundation
import CAtomics
import Foundation

/// A decoded sound: interleaved stereo Float32 at a fixed sample rate. Immutable once built.
struct SampleData {
    let data: UnsafeMutablePointer<Float>
    let frames: Int
}

/// One-shot sample players ("pads"), rendered by the audio thread of whichever `MixGraph`
/// is running. The bank outlives graph rebuilds.
///
/// Control → IO handoff is lock-free: each slot holds an atomically published pointer to its
/// `SampleData` and a trigger counter. The IO thread restarts a voice whenever the counter
/// changes. Replaced samples are freed after a grace period, well after any render cycle
/// that could still be reading them has finished.
public final class PadBank {
    public static let capacity = 256
    public static let maxDuration: Double = 5 * 60
    static let maxFrames = 8192

    // Control-written, IO-read (atomic).
    private let samples: UnsafeMutablePointer<UnsafeMutableRawPointer?>
    private let triggers: UnsafeMutablePointer<UInt64>
    private let stops: UnsafeMutablePointer<UInt64>
    // IO-owned.
    private let seenTriggers: UnsafeMutablePointer<UInt64>
    private let seenStops: UnsafeMutablePointer<UInt64>
    private let positions: UnsafeMutablePointer<Int>
    // IO-written, control-read: playback progress 0..<1, or -1 when idle.
    private let progress: UnsafeMutablePointer<Float>
    // IO-owned mix buffer (interleaved stereo).
    let scratch: UnsafeMutablePointer<Float>

    public init() {
        let n = PadBank.capacity
        samples = .allocate(capacity: n); samples.initialize(repeating: nil, count: n)
        triggers = .allocate(capacity: n); triggers.initialize(repeating: 0, count: n)
        stops = .allocate(capacity: n); stops.initialize(repeating: 0, count: n)
        seenTriggers = .allocate(capacity: n); seenTriggers.initialize(repeating: 0, count: n)
        seenStops = .allocate(capacity: n); seenStops.initialize(repeating: 0, count: n)
        positions = .allocate(capacity: n); positions.initialize(repeating: -1, count: n)
        progress = .allocate(capacity: n); progress.initialize(repeating: -1, count: n)
        scratch = .allocate(capacity: 2 * PadBank.maxFrames)
        scratch.initialize(repeating: 0, count: 2 * PadBank.maxFrames)
    }

    // MARK: - Control side

    /// Publishes a sample into a slot (nil clears it). The previous sample is freed later.
    func install(_ sample: UnsafeMutablePointer<SampleData>?, slot: Int, releaseQueue: DispatchQueue) {
        let old = ca_load_ptr(samples + slot)
        ca_store_ptr(samples + slot, sample.map(UnsafeMutableRawPointer.init))
        guard let old else { return }
        releaseQueue.asyncAfter(deadline: .now() + 2) {
            PadBank.free(old.assumingMemoryBound(to: SampleData.self))
        }
    }

    func trigger(slot: Int) { ca_store_u64(triggers + slot, ca_load_u64(triggers + slot) &+ 1) }
    func stop(slot: Int) { ca_store_u64(stops + slot, ca_load_u64(stops + slot) &+ 1) }
    func progress(slot: Int) -> Float { ca_load_float(progress + slot) }

    /// Decodes an audio file to interleaved stereo at `sampleRate`. Mono is duplicated to both
    /// channels; extra channels beyond two are dropped.
    static func decode(url: URL, sampleRate: Double) throws -> UnsafeMutablePointer<SampleData> {
        guard FileManager.default.fileExists(atPath: url.path) else { throw PadError.missing }
        let file = try AVAudioFile(forReading: url)
        let source = file.processingFormat
        let duration = Double(file.length) / source.sampleRate
        guard duration <= maxDuration else { throw PadError.tooLong(duration) }

        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                         channels: source.channelCount, interleaved: false),
              let converter = AVAudioConverter(from: source, to: target),
              let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw PadError.unsupported
        }
        try file.read(into: input)

        let capacity = AVAudioFrameCount(Double(input.frameLength) * sampleRate / source.sampleRate) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { throw PadError.unsupported }
        var consumed = false
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, status in
            if consumed {
                status.pointee = .endOfStream
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return input
        }
        if let conversionError { throw conversionError }
        guard let channels = output.floatChannelData else { throw PadError.unsupported }

        let frames = Int(output.frameLength)
        let data = UnsafeMutablePointer<Float>.allocate(capacity: max(1, frames * 2))
        let left = channels[0]
        let right = output.format.channelCount > 1 ? channels[1] : channels[0]
        for f in 0..<frames {
            data[2 * f] = left[f]
            data[2 * f + 1] = right[f]
        }
        let sample = UnsafeMutablePointer<SampleData>.allocate(capacity: 1)
        sample.initialize(to: SampleData(data: data, frames: frames))
        return sample
    }

    static func free(_ sample: UnsafeMutablePointer<SampleData>) {
        sample.pointee.data.deallocate()
        sample.deinitialize(count: 1)
        sample.deallocate()
    }

    // MARK: - Real-time side

    /// Renders all active voices into `scratch`. Returns false if nothing is playing
    /// (scratch is then left untouched).
    func render(frames: Int) -> Bool {
        let frames = min(frames, PadBank.maxFrames)
        var cleared = false
        for slot in 0..<PadBank.capacity {
            let trigger = ca_load_u64(triggers + slot)
            if trigger != seenTriggers[slot] {
                seenTriggers[slot] = trigger
                positions[slot] = 0
            }
            let stop = ca_load_u64(stops + slot)
            if stop != seenStops[slot] {
                seenStops[slot] = stop
                positions[slot] = -1
                ca_store_float(progress + slot, -1)
            }
            let position = positions[slot]
            guard position >= 0 else { continue }
            guard let raw = ca_load_ptr(samples + slot) else {
                positions[slot] = -1
                ca_store_float(progress + slot, -1)
                continue
            }
            let sample = raw.assumingMemoryBound(to: SampleData.self).pointee
            let count = min(frames, sample.frames - position)
            if count <= 0 {
                positions[slot] = -1
                ca_store_float(progress + slot, -1)
                continue
            }
            if !cleared {
                memset(scratch, 0, 2 * frames * MemoryLayout<Float>.size)
                cleared = true
            }
            let src = sample.data + 2 * position
            for i in 0..<(2 * count) { scratch[i] += src[i] }
            positions[slot] = position + count
            ca_store_float(progress + slot, Float(position + count) / Float(sample.frames))
        }
        return cleared
    }
}

public enum PadError: Error, CustomStringConvertible {
    case tooLong(Double)
    case unsupported
    case missing

    public var description: String {
        switch self {
        case let .tooLong(duration):
            "sound is \(Int(duration / 60)) min long; pads take up to \(Int(PadBank.maxDuration / 60)) min"
        case .unsupported:
            "unsupported audio format"
        case .missing:
            "sound file is missing — use Change Sound…"
        }
    }
}
