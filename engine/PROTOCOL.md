# mixerd protocol

`mixerd` reads one JSON command per line on stdin and writes one JSON event per line on stdout.
It exits when stdin closes, so it dies with the UI that spawned it.

Config is persisted to `~/Library/Application Support/MyMixer/config.json`
(override with `MYMIXER_CONFIG`) and restored on start.

## Commands

| cmd | fields | effect |
|---|---|---|
| `getState` | | emits `state` |
| `listApps` | | emits `apps` |
| `listDevices` | | emits `devices` |
| `setOutput` | `uid` (null = first BlackHole) | virtual cable to write into |
| `setMic` | `uid` (null = system default input) | microphone device |
| `setMicEnabled` | `enabled` | |
| `setMicChannel` | `channel` (0-based) | which input channel of the mic device is used (mono) |
| `setMonitorEnabled` | `enabled` | monitor output on/off; while on, tapped apps are heard only through it |
| `setMonitor` | `uid` (null = system default output) | headphones/speakers for the monitor |
| `setMonitorMic` | `enabled` | also send the mic to the monitor |
| `addSource` | `id` | app ID from `apps` (bundle ID or `pid:<n>`) |
| `removeSource` | `id` | |
| `setGain` | `id` (`master`, `mic`, `monitor`, `pads` or source ID), `gain` (linear, 0…4) | smoothed, no rebuild |
| `setMute` | `id`, `muted` | |
| `addPad` | `path`, `name` (default: file name) | copies the sound into `sounds/` next to the config |
| `setPadSound` | `id`, `path` | replace a pad's sound |
| `renamePad` | `id`, `name` | |
| `removePad` | `id` | also deletes its copied sound |
| `triggerPad` | `id` | play once from the start (restarts if already playing) |
| `stopPads` | | stop all pads |
| `restart` | | force a graph rebuild (e.g. after granting a permission) |
| `quit` | | |

Example: `{"cmd":"setGain","id":"com.apple.garageband10","gain":0.5}`

## Events

Every event is `{"event": <name>, "data": <payload>}`.

- `state` — after any change:
  ```json
  {"running": true, "sampleRate": 44100, "error": null,
   "output": {"uid": "BlackHole2ch_UID", "name": "BlackHole 2ch", "channels": 2},
   "mic": {"enabled": true, "selectedUID": null, "device": {"uid": "...", "name": "...", "channels": 1},
           "channel": 0, "gain": 1, "muted": false},
   "master": {"gain": 1, "muted": false},
   "monitor": {"enabled": true, "selectedUID": null, "device": {"uid": "...", "name": "External Headphones", "channels": 2},
               "gain": 1, "muted": false, "includesMic": false},
   "sources": [{"id": "com.apple.garageband10", "name": "GarageBand",
                "gain": 1, "muted": false, "attached": true}],
   "pads": {"gain": 1, "muted": false,
            "items": [{"id": "…", "name": "Applause", "ready": true, "duration": 3.2, "error": null}]}}
  ```
  A pad is `ready` once its sound is decoded (at the graph's sample rate; up to 5 min long).
  `mic.selectedUID` is the picked device (null = system default), `mic.device` the one in use.
  `attached: false` means the app isn't running (or has no audio client yet); it is attached
  automatically once it appears.
- `meters` — every 50 ms while running, post-gain peak in dBFS (floor −100):
  `{"master": -12.1, "mic": -40.3, "monitor": -14.2, "pads": -20.0,
    "sources": {"com.apple.garageband10": -14.0}, "padProgress": {"<pad id>": 0.42}}`
  `padProgress` lists only pads that are playing.
- `apps` — apps with audio clients, playing ones first: `[{"id", "name", "isPlaying", "isApp"}]`.
  `isApp` is false for daemons and background processes.
  Sent on start and when the process list changes (coalesced).
- `devices` — `{"inputs": [AudioDevice], "outputs": [AudioDevice]}`,
  `AudioDevice = {"id", "uid", "name", "inputChannels", "outputChannels"}`.
- `error` — `{"message"}` for a bad command.
- `log` — `{"message"}` diagnostic.
