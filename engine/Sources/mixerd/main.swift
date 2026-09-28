import Foundation
import MixerCore

// mixerd: the audio engine process. Controlled with JSON lines on stdin,
// reports JSON lines on stdout. See engine/PROTOCOL.md.
//
//   mixerd                 run until stdin closes
//   mixerd --add <id> ...  also add sources on start (handy without a UI)
//
// MYMIXER_CONFIG overrides the config path (default: ~/Library/Application Support/MyMixer/config.json).

setvbuf(stdout, nil, _IOLBF, 0)

let queue = DispatchQueue(label: "mymixer.engine")
let mixer = Mixer(queue: queue, configURL: ProcessInfo.processInfo.environment["MYMIXER_CONFIG"]
    .map { URL(fileURLWithPath: $0) } ?? Mixer.defaultConfigURL)
let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys]

struct Envelope: Encodable {
    let event: String
    let data: any Encodable

    enum CodingKeys: CodingKey { case event, data }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(event, forKey: .event)
        try c.encode(data, forKey: .data)
    }
}

let outputLock = NSLock()
func send(_ event: String, _ data: any Encodable) {
    guard let json = try? encoder.encode(Envelope(event: event, data: data)) else { return }
    outputLock.lock()
    FileHandle.standardOutput.write(json)
    FileHandle.standardOutput.write(Data([0x0A]))
    outputLock.unlock()
}

struct Command: Decodable {
    let cmd: String
    let id: String?
    let uid: String?
    let gain: Float?
    let muted: Bool?
    let enabled: Bool?
    let channel: Int?
    let path: String?
    let name: String?
}

func handle(_ line: String) {
    guard let data = line.data(using: .utf8), !line.trimmingCharacters(in: .whitespaces).isEmpty else { return }
    let command: Command
    do {
        command = try JSONDecoder().decode(Command.self, from: data)
    } catch {
        send("error", ["message": "bad command: \(line)"])
        return
    }
    func need<T>(_ value: T?, _ field: String) -> T? {
        if value == nil { send("error", ["message": "\(command.cmd): missing '\(field)'"]) }
        return value
    }

    switch command.cmd {
    case "getState": mixer.emitState()
    case "listApps": mixer.emitApps()
    case "listDevices": mixer.emitDevices()
    case "restart": mixer.restart()
    case "setOutput": mixer.setOutput(uid: command.uid)
    case "setMic": mixer.setMic(uid: command.uid)
    case "setMicEnabled": if let v = need(command.enabled, "enabled") { mixer.setMicEnabled(v) }
    case "setMicChannel": if let v = need(command.channel, "channel") { mixer.setMicChannel(v) }
    case "setMonitor": mixer.setMonitor(uid: command.uid)
    case "setMonitorEnabled": if let v = need(command.enabled, "enabled") { mixer.setMonitorEnabled(v) }
    case "setMonitorMic": if let v = need(command.enabled, "enabled") { mixer.setMonitorIncludesMic(v) }
    case "addPad": if let path = need(command.path, "path") { mixer.addPad(path: path, name: command.name) }
    case "setPadSound":
        if let id = need(command.id, "id"), let path = need(command.path, "path") { mixer.setPadSound(id: id, path: path) }
    case "renamePad":
        if let id = need(command.id, "id"), let name = need(command.name, "name") { mixer.renamePad(id: id, name: name) }
    case "removePad": if let id = need(command.id, "id") { mixer.removePad(id: id) }
    case "triggerPad": if let id = need(command.id, "id") { mixer.triggerPad(id: id) }
    case "stopPads": mixer.stopPads()
    case "addSource": if let id = need(command.id, "id") { mixer.addSource(id: id) }
    case "removeSource": if let id = need(command.id, "id") { mixer.removeSource(id: id) }
    case "setGain":
        if let id = need(command.id, "id"), let g = need(command.gain, "gain") { mixer.setGain(id, g) }
    case "setMute":
        if let id = need(command.id, "id"), let m = need(command.muted, "muted") { mixer.setMuted(id, m) }
    case "quit":
        mixer.shutdown()
        exit(0)
    default:
        send("error", ["message": "unknown command '\(command.cmd)'"])
    }
}

mixer.onEvent = send

var initialSources: [String] = []
var args = CommandLine.arguments.dropFirst()
while let arg = args.popFirst() {
    if arg == "--add", let id = args.popFirst() { initialSources.append(id) }
}

queue.async {
    mixer.start()
    initialSources.forEach { mixer.addSource(id: $0) }
}

// stdin closing means the UI went away: shut down with it.
Thread.detachNewThread {
    while let line = readLine() {
        queue.async { handle(line) }
    }
    queue.async {
        mixer.shutdown()
        exit(0)
    }
}

var signalSources: [DispatchSourceSignal] = []
for sig in [SIGINT, SIGTERM] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: queue)
    source.setEventHandler {
        mixer.shutdown()
        exit(0)
    }
    source.resume()
    signalSources.append(source)
}

dispatchMain()
