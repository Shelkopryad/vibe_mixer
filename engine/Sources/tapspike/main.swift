import AVFoundation
import CoreAudio
import Foundation
import MixerCore

// Stage-0 spike: record the audio of one app into a WAV file via a process tap.
// Also records a device's input, to check what the engine sends into BlackHole.
//
//   tapspike list
//   tapspike record <name|bundle-id|pid> [seconds=10] [out.wav]
//   tapspike device <device name> [seconds=10] [out.wav]

func usage() -> Never {
    print("""
    usage:
      tapspike list
      tapspike record <name|bundle-id|pid> [seconds=10] [out.wav]
      tapspike device <device name> [seconds=10] [out.wav]
    """)
    exit(2)
}

func listProcesses() throws {
    let processes = try AudioProcess.all().sorted { ($0.isPlaying ? 0 : 1, $0.name) < ($1.isPlaying ? 0 : 1, $1.name) }
    for p in processes {
        let mark = p.isPlaying ? "▶" : " "
        print("\(mark) \(String(p.pid).padding(toLength: 7, withPad: " ", startingAt: 0)) \(p.name)  [\(p.bundleID)]")
    }
}

func findProcesses(_ query: String) throws -> [AudioProcess] {
    let all = try AudioProcess.all()
    if let pid = pid_t(query) { return all.filter { $0.pid == pid } }
    let q = query.lowercased()
    return all.filter { $0.name.lowercased().contains(q) || $0.bundleID.lowercased().contains(q) }
}

func record(query: String, seconds: Double, path: String) throws {
    let matches = try findProcesses(query)
    guard !matches.isEmpty else {
        print("no audio process matches '\(query)'. Run `tapspike list` (the app must have played sound at least once).")
        exit(1)
    }
    for p in matches { print("tapping \(p.name) pid=\(p.pid) [\(p.bundleID)]") }

    let tap = try ProcessTap(processes: matches.map(\.objectID))
    var asbd = tap.format
    guard let format = AVAudioFormat(streamDescription: &asbd) else {
        print("unsupported tap format: \(asbd)"); exit(1)
    }
    print("tap format: \(format)")

    let url = URL(fileURLWithPath: path)
    let file = try AVAudioFile(forWriting: url, settings: format.settings,
                               commonFormat: format.commonFormat, interleaved: format.isInterleaved)

    // Peak meter updated from the IO thread, printed from main.
    let peak = UnsafeMutablePointer<Float>.allocate(capacity: 1)
    peak.initialize(to: 0)
    var writeError: Error?

    // Writing a file on the IO thread is not real-time safe; fine for a spike.
    try tap.start { input, frames in
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input) else { return }
        buffer.frameLength = frames
        for audioBuffer in UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)) {
            guard let data = audioBuffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let count = Int(audioBuffer.mDataByteSize) / MemoryLayout<Float>.size
            for i in 0..<count { peak.pointee = max(peak.pointee, abs(data[i])) }
        }
        do { try file.write(from: buffer) } catch { writeError = error }
    }

    print("recording \(seconds)s → \(url.path)")
    meter(seconds: seconds, peak: peak)
    tap.invalidate()
    if let writeError { print("write error: \(writeError)") }
    print("done: \(file.length) frames written")
}

/// Prints the peak level every 250 ms until `seconds` elapse.
func meter(seconds: Double, peak: UnsafeMutablePointer<Float>) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        Thread.sleep(forTimeInterval: 0.25)
        let p = peak.pointee
        peak.pointee = 0
        let db = p > 0 ? 20 * log10(p) : -120
        let bar = String(repeating: "█", count: max(0, Int((db + 60) / 2)))
        print(String(format: "%6.1f dBFS %@", db, bar))
    }
}

func recordDevice(query: String, seconds: Double, path: String) throws {
    guard let device = try AudioDevice.all().first(where: {
        $0.inputChannels > 0 && $0.name.localizedCaseInsensitiveContains(query)
    }) else {
        print("no input device matches '\(query)'"); exit(1)
    }
    var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                             mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    var rate: Float64 = 48000
    var size = UInt32(MemoryLayout<Float64>.size)
    AudioObjectGetPropertyData(device.id, &address, 0, nil, &size, &rate)
    print("recording \(device.name) (\(device.inputChannels) ch, \(rate) Hz) \(seconds)s → \(path)")

    var file: AVAudioFile?
    let peak = UnsafeMutablePointer<Float>.allocate(capacity: 1)
    peak.initialize(to: 0)
    var procID: AudioDeviceIOProcID?
    try check(AudioDeviceCreateIOProcIDWithBlock(&procID, device.id, nil) { _, input, _, _, _ in
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let first = list.first, let mData = first.mData else { return }
        let channels = Int(first.mNumberChannels)
        let data = mData.assumingMemoryBound(to: Float.self)
        let count = Int(first.mDataByteSize) / MemoryLayout<Float>.size
        for i in 0..<count { peak.pointee = max(peak.pointee, abs(data[i])) }

        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                   channels: AVAudioChannelCount(channels), interleaved: true)!
        if file == nil {
            file = try? AVAudioFile(forWriting: URL(fileURLWithPath: path), settings: format.settings,
                                    commonFormat: .pcmFormatFloat32, interleaved: true)
        }
        var single = AudioBufferList(mNumberBuffers: 1, mBuffers: first)
        if let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: &single) {
            buffer.frameLength = AVAudioFrameCount(count / max(channels, 1))
            try? file?.write(from: buffer)
        }
    }, "AudioDeviceCreateIOProcIDWithBlock")
    try check(AudioDeviceStart(device.id, procID), "AudioDeviceStart")
    meter(seconds: seconds, peak: peak)
    AudioDeviceStop(device.id, procID)
    AudioDeviceDestroyIOProcID(device.id, procID!)
    print("done: \(file?.length ?? 0) frames written")
}

let args = CommandLine.arguments.dropFirst()
do {
    switch args.first {
    case "list": try listProcesses()
    case "record":
        guard args.count >= 2 else { usage() }
        let rest = Array(args.dropFirst())
        try record(query: rest[0],
                   seconds: rest.count > 1 ? Double(rest[1]) ?? 10 : 10,
                   path: rest.count > 2 ? rest[2] : "tap.wav")
    case "device":
        guard args.count >= 2 else { usage() }
        let rest = Array(args.dropFirst())
        try recordDevice(query: rest[0],
                         seconds: rest.count > 1 ? Double(rest[1]) ?? 10 : 10,
                         path: rest.count > 2 ? rest[2] : "device.wav")
    default: usage()
    }
} catch {
    print("error: \(error)")
    exit(1)
}
