# My Mixer

Mixes your microphone with the audio of chosen apps (GarageBand, VLC, a browser…) into a
virtual microphone, so people on a Zoom call hear both.

```
GarageBand / VLC ──(process tap)──┐
                                  ├──► mixerd ─┬─► Master ──► BlackHole 2ch ──► Zoom (as microphone)
Microphone ───────────────────────┘            └─► Monitor ─► your headphones (optional)
```

**Pads** (below the mixer) are one-shot sound buttons: click plays the sound once, clicking
again restarts it, Esc stops everything. They're played by the engine and go to both Master
and Monitor, with their own fader. Sounds are copied to `~/Library/Application Support/MyMixer/sounds/`.

With **Monitor** on, the tapped apps are muted at their own output and heard only through
the mixer, so you hear exactly what goes into the call (optionally with your own mic).
With it off, they keep playing to wherever they normally play.

Requires macOS 14.2+ (process taps) and [BlackHole 2ch](https://github.com/ExistentialAudio/BlackHole).

## Run

```sh
cd app
npm install
npm start          # builds the engine (release) and opens the UI
```

In Zoom: **Settings → Audio → Microphone: BlackHole 2ch**, and enable
**Original sound for musicians** (otherwise Zoom's noise suppression mangles music).
Use headphones, or the mic will pick up the app audio a second time.

The first run asks for **System Audio Recording** and **Microphone** access. When launched
from a terminal, macOS attributes these to the terminal app.

## Layout

- `engine/` — Swift package.
  - `MixerCore/MixGraph.swift` — the real-time graph: one private aggregate device holding
    the output cable, the mic and the monitor, so everything runs on one clock.
  - `MixerCore/TapReader.swift` — each app tap runs in its own aggregate (same clock) and
    feeds the graph through a lock-free ring buffer. A tap on an app that isn't playing
    delivers no IO at all; inside the main aggregate it would stall mic and pads too.
  - `MixerCore/PadBank.swift` — decoded pad sounds and their voices; lock-free handoff to
    the audio thread (`CAtomics`).
  - `MixerCore/Mixer.swift` — config, graph rebuilds (source/device changes, apps starting
    and quitting), meters.
  - `mixerd` — the engine process, JSON lines over stdio: [PROTOCOL.md](engine/PROTOCOL.md).
  - `tapspike` — debugging tool: `list` audio processes, `record` an app, `device` records
    a device's input (e.g. what actually arrives in BlackHole).
- `app/` — Electron UI (plain HTML/CSS/JS). `main.js` spawns `mixerd` and restarts it if it
  crashes; the renderer talks to it through `preload.js`.

Config lives in `~/Library/Application Support/MyMixer/config.json` (`MYMIXER_CONFIG`
overrides it). The engine sets the output cable's own volume to 100% on start, since a
lowered BlackHole volume silently attenuates everything.

## Third-party

Not included in this repository; installed separately.

- [BlackHole](https://github.com/ExistentialAudio/BlackHole) by Existential Audio, GPL-3.0.
  Used as an ordinary system audio device via Core Audio; no BlackHole code is included or
  linked.
- [Electron](https://www.electronjs.org/), MIT, installed via npm.
