import CoreAudio
import Foundation

/// Engine controller: owns the persisted configuration and the running `MixGraph`,
/// rebuilds the graph when the device or source set changes, and publishes state
/// and meters. All methods must be called on `queue`.
public final class Mixer {
    public struct SourceConfig: Codable, Equatable {
        public var id: String
        public var name: String
        public var gain: Float = 1
        public var muted = false

        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
            gain = try c.decodeIfPresent(Float.self, forKey: .gain) ?? 1
            muted = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        }
    }

    public struct PadConfig: Codable, Equatable {
        public var id: String
        public var name: String
        /// File name inside the sounds directory (a copy of what the user picked).
        public var file: String
    }

    public struct Config: Codable, Equatable {
        public var outputUID: String?
        public var micUID: String?
        public var micEnabled = true
        public var micChannel = 0
        public var micGain: Float = 1
        public var micMuted = false
        public var masterGain: Float = 1
        public var masterMuted = false
        /// Monitor output (what you hear). nil UID = system default output.
        public var monitorEnabled = false
        public var monitorUID: String?
        public var monitorGain: Float = 1
        public var monitorMuted = false
        public var monitorIncludesMic = false
        public var padsGain: Float = 1
        public var padsMuted = false
        public var sources: [SourceConfig] = []
        public var pads: [PadConfig] = []

        public init() {}

        /// Missing keys keep their defaults, so configs from older versions still load.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Config()
            outputUID = try c.decodeIfPresent(String.self, forKey: .outputUID)
            micUID = try c.decodeIfPresent(String.self, forKey: .micUID)
            micEnabled = try c.decodeIfPresent(Bool.self, forKey: .micEnabled) ?? d.micEnabled
            micChannel = try c.decodeIfPresent(Int.self, forKey: .micChannel) ?? d.micChannel
            micGain = try c.decodeIfPresent(Float.self, forKey: .micGain) ?? d.micGain
            micMuted = try c.decodeIfPresent(Bool.self, forKey: .micMuted) ?? d.micMuted
            masterGain = try c.decodeIfPresent(Float.self, forKey: .masterGain) ?? d.masterGain
            masterMuted = try c.decodeIfPresent(Bool.self, forKey: .masterMuted) ?? d.masterMuted
            monitorEnabled = try c.decodeIfPresent(Bool.self, forKey: .monitorEnabled) ?? d.monitorEnabled
            monitorUID = try c.decodeIfPresent(String.self, forKey: .monitorUID)
            monitorGain = try c.decodeIfPresent(Float.self, forKey: .monitorGain) ?? d.monitorGain
            monitorMuted = try c.decodeIfPresent(Bool.self, forKey: .monitorMuted) ?? d.monitorMuted
            monitorIncludesMic = try c.decodeIfPresent(Bool.self, forKey: .monitorIncludesMic) ?? d.monitorIncludesMic
            padsGain = try c.decodeIfPresent(Float.self, forKey: .padsGain) ?? d.padsGain
            padsMuted = try c.decodeIfPresent(Bool.self, forKey: .padsMuted) ?? d.padsMuted
            sources = try c.decodeIfPresent([SourceConfig].self, forKey: .sources) ?? d.sources
            pads = try c.decodeIfPresent([PadConfig].self, forKey: .pads) ?? d.pads
        }
    }

    public struct State: Encodable {
        struct Device: Encodable { let uid: String; let name: String; let channels: Int }
        struct Source: Encodable { let id: String; let name: String; let gain: Float; let muted: Bool; let attached: Bool }
        struct Mic: Encodable {
            /// `selectedUID` is what was picked (null = system default); `device` is what's in use.
            let enabled: Bool; let selectedUID: String?; let device: Device?
            let channel: Int; let gain: Float; let muted: Bool
        }
        struct Master: Encodable { let gain: Float; let muted: Bool }
        struct Monitor: Encodable {
            /// `selectedUID` is what was picked (null = system default); `device` is what's in use.
            let enabled: Bool; let selectedUID: String?; let device: Device?
            let gain: Float; let muted: Bool; let includesMic: Bool
        }

        let running: Bool
        let sampleRate: Double
        let error: String?
        let output: Device?
        let mic: Mic
        let master: Master
        let monitor: Monitor
        let sources: [Source]
        struct Pad: Encodable { let id: String; let name: String; let ready: Bool; let duration: Double?; let error: String? }
        struct Pads: Encodable { let gain: Float; let muted: Bool; let items: [Pad] }
        let pads: Pads
    }

    public struct Meters: Encodable {
        let master: Float
        let mic: Float
        let monitor: Float
        let pads: Float
        let sources: [String: Float]
        /// Playback progress (0..<1) of pads that are playing right now.
        let padProgress: [String: Float]
    }

    public let queue: DispatchQueue
    public var onEvent: (_ name: String, _ payload: Encodable) -> Void = { _, _ in }

    private let configURL: URL
    private var config: Config
    private var graph: MixGraph?
    private var graphSignature: Signature?
    private var lastError: String?
    private var meterTimer: DispatchSourceTimer?
    private var pendingAppsEvent = false
    private var saveWork: DispatchWorkItem?

    private let padBank = PadBank()
    private let padLoadQueue = DispatchQueue(label: "mymixer.pads", qos: .userInitiated)
    private var padSlots: [String: Int] = [:]
    /// What's installed in each pad's slot (file + sample rate), and what's being decoded.
    private var padLoaded: [String: (file: String, rate: Double, duration: Double)] = [:]
    private var padLoading: [String: (file: String, rate: Double, generation: Int)] = [:]
    private var padErrors: [String: String] = [:]
    private var padGeneration = 0

    /// Everything that requires a graph rebuild when it changes.
    private struct Signature: Equatable {
        let outputID: AudioObjectID
        let micID: AudioObjectID?
        let micChannel: Int
        let monitorID: AudioObjectID?
        let sources: [String: [AudioObjectID]]
    }

    public init(queue: DispatchQueue, configURL: URL = Mixer.defaultConfigURL) {
        self.queue = queue
        self.configURL = configURL
        config = (try? JSONDecoder().decode(Config.self, from: Data(contentsOf: configURL))) ?? Config()
    }

    private var soundsDirectory: URL { configURL.deletingLastPathComponent().appendingPathComponent("sounds") }

    public static var defaultConfigURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MyMixer/config.json")
    }

    // MARK: - Lifecycle

    public func start() {
        dispatchPrecondition(condition: .onQueue(queue))
        var processes = AudioObjectPropertyAddress(kAudioHardwarePropertyProcessObjectList)
        AudioObjectAddPropertyListenerBlock(.system, &processes, queue) { [weak self] _, _ in
            self?.reconcile()
            self?.scheduleAppsEvent()
        }
        var devices = AudioObjectPropertyAddress(kAudioHardwarePropertyDevices)
        AudioObjectAddPropertyListenerBlock(.system, &devices, queue) { [weak self] _, _ in
            self?.reconcile()
            self?.emitDevices()
        }
        // "System default" mic/monitor follow the defaults (e.g. plugging in headphones).
        for selector in [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDefaultOutputDevice] {
            var address = AudioObjectPropertyAddress(selector)
            AudioObjectAddPropertyListenerBlock(.system, &address, queue) { [weak self] _, _ in
                self?.reconcile()
                self?.emitState()
            }
        }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(50))
        timer.setEventHandler { [weak self] in self?.emitMeters() }
        timer.resume()
        meterTimer = timer

        reconcile()
        emitDevices()
        emitApps()
        emitState()
    }

    public func shutdown() {
        if let saveWork, !saveWork.isCancelled {
            saveWork.cancel()
            save()
        }
        meterTimer?.cancel()
        graph?.stop()
        graph = nil
    }

    // MARK: - Commands

    public func setOutput(uid: String?) { update { $0.outputUID = uid } }
    public func setMic(uid: String?) { update { $0.micUID = uid } }
    public func setMicEnabled(_ enabled: Bool) { update { $0.micEnabled = enabled } }
    public func setMicChannel(_ channel: Int) { update { $0.micChannel = max(0, channel) } }
    public func setMonitor(uid: String?) { update { $0.monitorUID = uid } }
    public func setMonitorEnabled(_ enabled: Bool) { update { $0.monitorEnabled = enabled } }
    public func setMonitorIncludesMic(_ enabled: Bool) { update { $0.monitorIncludesMic = enabled } }

    public func addSource(id: String) {
        guard !config.sources.contains(where: { $0.id == id }) else { return }
        let name = (try? AudioApp.all())?.first { $0.id == id }?.name ?? id
        update { $0.sources.append(SourceConfig(id: id, name: name)) }
    }

    /// Forces a graph rebuild, e.g. after granting a permission that made the last build fail.
    public func restart() {
        graphSignature = nil
        reconcile()
    }

    // MARK: Pads

    public func addPad(path: String, name: String?) {
        do {
            let file = try importSound(path)
            let id = UUID().uuidString
            let name = name ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            update { $0.pads.append(PadConfig(id: id, name: name, file: file)) }
        } catch {
            onEvent("error", ["message": "can't add sound: \(error.localizedDescription)"])
        }
    }

    public func setPadSound(id: String, path: String) {
        guard let old = config.pads.first(where: { $0.id == id }) else { return }
        do {
            let file = try importSound(path)
            update { config in
                if let i = config.pads.firstIndex(where: { $0.id == id }) { config.pads[i].file = file }
            }
            deleteSound(old.file)
        } catch {
            onEvent("error", ["message": "can't load sound: \(error.localizedDescription)"])
        }
    }

    public func renamePad(id: String, name: String) {
        update { config in
            if let i = config.pads.firstIndex(where: { $0.id == id }) { config.pads[i].name = name }
        }
    }

    public func removePad(id: String) {
        guard let pad = config.pads.first(where: { $0.id == id }) else { return }
        update { $0.pads.removeAll { $0.id == id } }
        deleteSound(pad.file)
    }

    /// Plays the pad from the start (restarting it if it's already playing).
    public func triggerPad(id: String) {
        guard let slot = padSlots[id], padLoaded[id] != nil else { return }
        padBank.trigger(slot: slot)
    }

    public func stopPads() {
        for slot in padSlots.values { padBank.stop(slot: slot) }
    }

    public func removeSource(id: String) { update { $0.sources.removeAll { $0.id == id } } }

    /// `target` is "master", "mic", "monitor", or a source ID.
    public func setGain(_ target: String, _ gain: Float) {
        let gain = max(0, min(gain, 4))
        update { config in
            switch target {
            case "master": config.masterGain = gain
            case "mic": config.micGain = gain
            case "monitor": config.monitorGain = gain
            case "pads": config.padsGain = gain
            default: if let i = config.sources.firstIndex(where: { $0.id == target }) { config.sources[i].gain = gain }
            }
        }
    }

    public func setMuted(_ target: String, _ muted: Bool) {
        update { config in
            switch target {
            case "master": config.masterMuted = muted
            case "mic": config.micMuted = muted
            case "monitor": config.monitorMuted = muted
            case "pads": config.padsMuted = muted
            default: if let i = config.sources.firstIndex(where: { $0.id == target }) { config.sources[i].muted = muted }
            }
        }
    }

    public func emitDevices() {
        let devices = (try? AudioDevice.all()) ?? []
        struct Devices: Encodable { let inputs: [AudioDevice]; let outputs: [AudioDevice] }
        onEvent("devices", Devices(inputs: devices.filter { $0.inputChannels > 0 },
                                   outputs: devices.filter { $0.outputChannels > 0 }))
    }

    public func emitApps() {
        pendingAppsEvent = false
        onEvent("apps", (try? AudioApp.all()) ?? [])
    }

    public func emitState() {
        let output = resolveOutput()
        let mic = resolveMic()
        let monitor = resolveMonitor()
        let attached = Set(graph?.sourceIDs ?? [])
        onEvent("state", State(
            running: graph != nil,
            sampleRate: graph?.sampleRate ?? 0,
            error: lastError,
            output: output.map { .init(uid: $0.uid, name: $0.name, channels: $0.outputChannels) },
            mic: .init(enabled: config.micEnabled,
                       selectedUID: config.micUID,
                       device: mic.map { .init(uid: $0.uid, name: $0.name, channels: $0.inputChannels) },
                       channel: config.micChannel, gain: config.micGain, muted: config.micMuted),
            master: .init(gain: config.masterGain, muted: config.masterMuted),
            monitor: .init(enabled: config.monitorEnabled,
                           selectedUID: config.monitorUID,
                           device: monitor.map { .init(uid: $0.uid, name: $0.name, channels: $0.outputChannels) },
                           gain: config.monitorGain, muted: config.monitorMuted,
                           includesMic: config.monitorIncludesMic),
            sources: config.sources.map {
                .init(id: $0.id, name: $0.name, gain: $0.gain, muted: $0.muted, attached: attached.contains($0.id))
            },
            pads: .init(gain: config.padsGain, muted: config.padsMuted, items: config.pads.map { pad in
                let loaded = padLoaded[pad.id].flatMap { $0.file == pad.file ? $0 : nil }
                return .init(id: pad.id, name: pad.name, ready: loaded != nil,
                             duration: loaded?.duration, error: padErrors[pad.id])
            })))
    }

    // MARK: - Internals

    private func update(_ change: (inout Config) -> Void) {
        dispatchPrecondition(condition: .onQueue(queue))
        var next = config
        change(&next)
        guard next != config else { return }
        config = next
        scheduleSave()
        reconcile()
        syncPads()
        applyGains()
        emitState()
    }

    /// Fader drags produce many updates per second; write the file once they settle.
    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = work
        queue.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(config).write(to: configURL, options: .atomic)
        } catch {
            onEvent("log", ["message": "failed to save config: \(error)"])
        }
    }

    /// Output defaults to the first BlackHole device.
    private func resolveOutput() -> AudioDevice? {
        let devices = (try? AudioDevice.all()) ?? []
        if let uid = config.outputUID { return devices.first { $0.uid == uid && $0.outputChannels > 0 } }
        return devices.first { $0.name.localizedCaseInsensitiveContains("BlackHole") && $0.outputChannels > 0 }
    }

    /// Mic defaults to the system default input (unless that's our own output device).
    private func resolveMic() -> AudioDevice? {
        guard config.micEnabled else { return nil }
        let output = resolveOutput()
        let mic = config.micUID.flatMap(AudioDevice.find(uid:)) ?? AudioDevice.defaultInput()
        guard let mic, mic.inputChannels > 0, mic.uid != output?.uid else { return nil }
        return mic
    }

    /// Monitor defaults to the system default output (unless that's our own output device).
    private func resolveMonitor() -> AudioDevice? {
        guard config.monitorEnabled else { return nil }
        let output = resolveOutput()
        let monitor = config.monitorUID.flatMap(AudioDevice.find(uid:)) ?? AudioDevice.defaultOutput()
        guard let monitor, monitor.outputChannels > 0, monitor.uid != output?.uid else { return nil }
        return monitor
    }

    /// Rebuilds the graph if the resolved devices or process objects changed.
    private func reconcile() {
        guard let output = resolveOutput() else {
            teardown(error: "output device not found (install BlackHole or pick an output)")
            return
        }
        let mic = resolveMic()
        let monitor = resolveMonitor()
        let processes = (try? AudioProcess.all()) ?? []
        var sources: [String: [AudioObjectID]] = [:]
        for source in config.sources {
            let objects = AudioApp.processObjects(for: source.id, in: processes)
            if !objects.isEmpty { sources[source.id] = objects }
        }
        let signature = Signature(outputID: output.id, micID: mic?.id,
                                  micChannel: config.micChannel, monitorID: monitor?.id, sources: sources)
        guard signature != graphSignature else { return }

        graph?.stop()
        graph = nil
        graphSignature = signature
        do {
            let ordered = config.sources.compactMap { s in sources[s.id].map { (id: s.id, processes: $0) } }
            let next = try MixGraph(output: output, mic: mic, micChannel: config.micChannel,
                                    monitor: monitor, sources: ordered, pads: padBank)
            graph = next
            applyGains()
            try next.start()
            lastError = nil
            syncPads()
        } catch {
            graph = nil
            lastError = "\(error)"
        }
        emitState()
    }

    private func teardown(error: String) {
        graph?.stop()
        graph = nil
        graphSignature = nil
        if lastError != error {
            lastError = error
            emitState()
        }
    }

    private func applyGains() {
        guard let graph else { return }
        graph.setGain(slot: MixGraph.masterSlot, config.masterMuted ? 0 : config.masterGain)
        graph.setGain(slot: MixGraph.micSlot, config.micMuted ? 0 : config.micGain)
        graph.setGain(slot: MixGraph.monitorSlot, config.monitorMuted ? 0 : config.monitorGain)
        graph.setGain(slot: MixGraph.micToMonitorSlot, config.monitorIncludesMic ? 1 : 0)
        graph.setGain(slot: MixGraph.padsSlot, config.padsMuted ? 0 : config.padsGain)
        for (i, id) in graph.sourceIDs.enumerated() {
            guard let source = config.sources.first(where: { $0.id == id }) else { continue }
            graph.setGain(slot: MixGraph.firstSourceSlot + i, source.muted ? 0 : source.gain)
        }
    }

    private func emitMeters() {
        guard let graph else { return }
        let peaks = graph.takePeaks()
        func db(_ p: Float) -> Float { p > 0 ? max(-100, 20 * log10(p)) : -100 }
        var sources: [String: Float] = [:]
        for (i, id) in graph.sourceIDs.enumerated() { sources[id] = db(peaks[MixGraph.firstSourceSlot + i]) }
        onEvent("meters", Meters(master: db(peaks[MixGraph.masterSlot]),
                                 mic: db(peaks[MixGraph.micSlot]),
                                 monitor: graph.hasMonitor ? db(peaks[MixGraph.monitorSlot]) : -100,
                                 pads: db(peaks[MixGraph.padsSlot]),
                                 sources: sources,
                                 padProgress: padSlots.reduce(into: [:]) { result, entry in
                                     let p = padBank.progress(slot: entry.value)
                                     if p >= 0 { result[entry.key] = p }
                                 }))
    }

    // MARK: - Pads internals

    /// Copies a picked sound into the sounds directory; returns the new file name.
    private func importSound(_ path: String) throws -> String {
        let source = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: soundsDirectory, withIntermediateDirectories: true)
        let ext = source.pathExtension.isEmpty ? "" : ".\(source.pathExtension.lowercased())"
        let file = UUID().uuidString + ext
        try FileManager.default.copyItem(at: source, to: soundsDirectory.appendingPathComponent(file))
        return file
    }

    private func deleteSound(_ file: String) {
        guard !file.isEmpty, !file.contains("/") else { return }
        try? FileManager.default.removeItem(at: soundsDirectory.appendingPathComponent(file))
    }

    /// Frees slots of removed pads and (re)decodes pads whose file or the graph's sample rate
    /// changed. Decoding runs off the control queue; results are installed back on it.
    private func syncPads() {
        let ids = Set(config.pads.map(\.id))
        for (id, slot) in padSlots where !ids.contains(id) {
            padBank.stop(slot: slot)
            padBank.install(nil, slot: slot, releaseQueue: queue)
            padSlots[id] = nil
            padLoaded[id] = nil
            padLoading[id] = nil
            padErrors[id] = nil
        }
        guard let rate = graph?.sampleRate, rate > 0 else { return }

        for pad in config.pads {
            if padSlots[pad.id] == nil {
                let used = Set(padSlots.values)
                guard let free = (0..<PadBank.capacity).first(where: { !used.contains($0) }) else {
                    padErrors[pad.id] = "too many pads"
                    continue
                }
                padSlots[pad.id] = free
            }
            if let loaded = padLoaded[pad.id], loaded.file == pad.file, loaded.rate == rate { continue }
            if let loading = padLoading[pad.id], loading.file == pad.file, loading.rate == rate { continue }

            padGeneration += 1
            let generation = padGeneration
            padLoading[pad.id] = (pad.file, rate, generation)
            let url = soundsDirectory.appendingPathComponent(pad.file)
            padLoadQueue.async { [weak self] in
                let result = Result { try PadBank.decode(url: url, sampleRate: rate) }
                self?.queue.async { self?.finishLoading(id: pad.id, file: pad.file, rate: rate,
                                                        generation: generation, result: result) }
            }
        }
    }

    private func finishLoading(id: String, file: String, rate: Double, generation: Int,
                               result: Result<UnsafeMutablePointer<SampleData>, Error>) {
        guard padLoading[id]?.generation == generation, let slot = padSlots[id] else {
            if case let .success(sample) = result { PadBank.free(sample) }
            return
        }
        padLoading[id] = nil
        switch result {
        case let .success(sample):
            padBank.install(sample, slot: slot, releaseQueue: queue)
            padLoaded[id] = (file, rate, Double(sample.pointee.frames) / rate)
            padErrors[id] = nil
        case let .failure(error):
            padErrors[id] = (error as? PadError)?.description ?? error.localizedDescription
        }
        emitState()
    }

    /// Process lists churn (browser helpers come and go), so coalesce app-list events.
    private func scheduleAppsEvent() {
        guard !pendingAppsEvent else { return }
        pendingAppsEvent = true
        queue.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.emitApps() }
    }
}
