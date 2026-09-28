'use strict';

// Fader range in dB; the bottom stop means silence (gain 0).
const FADER_MIN_DB = -60;
const METER_MIN_DB = -60;
const METER_FALL_DB_PER_S = 24;
const PEAK_HOLD_MS = 1200;

const $ = (id) => document.getElementById(id);
const stripsEl = $('strips');
const appsEl = $('apps');
const outputEl = $('output');
const padGridEl = $('pad-grid');
const statusEl = $('status');

let state = null;
let devices = { inputs: [], outputs: [] };
let apps = [];
const strips = new Map(); // id -> { el, fader, meter state }

const send = (cmd, fields = {}) => window.engine.send({ cmd, ...fields });

const gainToDb = (gain) => (gain <= 0 ? -Infinity : 20 * Math.log10(gain));
const dbToGain = (db) => (db <= FADER_MIN_DB ? 0 : 10 ** (db / 20));
const formatDb = (db) => (db === -Infinity ? '−∞ dB' : `${db > 0 ? '+' : ''}${db.toFixed(1)} dB`);

// ---------- Strips ----------

function createStrip(id, kind) {
  const el = $('strip-template').content.firstElementChild.cloneNode(true);
  el.dataset.id = id;
  el.classList.add(`strip-${kind}`);
  const strip = {
    el,
    kind,
    fader: el.querySelector('.fader'),
    mask: el.querySelector('.meter-mask'),
    peakEl: el.querySelector('.meter-peak'),
    level: METER_MIN_DB, // displayed level, falls smoothly
    peak: METER_MIN_DB,
    peakAt: 0,
    dragging: false,
  };

  strip.fader.addEventListener('pointerdown', () => { strip.dragging = true; });
  window.addEventListener('pointerup', () => { strip.dragging = false; });
  strip.fader.addEventListener('input', () => {
    const db = Number(strip.fader.value);
    el.querySelector('.db').textContent = formatDb(db <= FADER_MIN_DB ? -Infinity : db);
    send('setGain', { id, gain: dbToGain(db) });
  });
  strip.fader.addEventListener('dblclick', () => {
    strip.fader.value = 0;
    strip.fader.dispatchEvent(new Event('input'));
  });
  el.querySelector('.mute').addEventListener('click', () => {
    send('setMute', { id, muted: !el.classList.contains('muted') });
  });

  const remove = el.querySelector('.remove');
  if (kind === 'source') remove.addEventListener('click', () => send('removeSource', { id }));
  else remove.remove();

  if (kind === 'mic') buildMicControls(strip);
  if (kind === 'monitor') buildMonitorControls(strip);
  if (kind === 'master') {
    strip.el.querySelector('.strip-extra').innerHTML = '<div class="route" title="Where the mix goes (your call hears this)"></div>';
  }
  strips.set(id, strip);
  return strip;
}

function buildMicControls(strip) {
  const extra = strip.el.querySelector('.strip-extra');
  extra.innerHTML = `
    <label class="toggle"><input type="checkbox" class="mic-enabled"> On</label>
    <select class="mic-device" title="Microphone"></select>
    <select class="mic-channel" title="Input channel"></select>`;
  extra.querySelector('.mic-enabled').addEventListener('change', (e) =>
    send('setMicEnabled', { enabled: e.target.checked }));
  extra.querySelector('.mic-device').addEventListener('change', (e) =>
    send('setMic', { uid: e.target.value || null }));
  extra.querySelector('.mic-channel').addEventListener('change', (e) =>
    send('setMicChannel', { channel: Number(e.target.value) }));
}

function buildMonitorControls(strip) {
  const extra = strip.el.querySelector('.strip-extra');
  extra.innerHTML = `
    <label class="toggle" title="Hear the apps through the mixer. Their direct sound is muted meanwhile."><input type="checkbox" class="monitor-enabled"> On</label>
    <select class="monitor-device" title="Headphones / speakers"></select>
    <label class="toggle" title="Also hear your own microphone"><input type="checkbox" class="monitor-mic"> My mic</label>`;
  extra.querySelector('.monitor-enabled').addEventListener('change', (e) =>
    send('setMonitorEnabled', { enabled: e.target.checked }));
  extra.querySelector('.monitor-device').addEventListener('change', (e) =>
    send('setMonitor', { uid: e.target.value || null }));
  extra.querySelector('.monitor-mic').addEventListener('change', (e) =>
    send('setMonitorMic', { enabled: e.target.checked }));
}

function updateMonitorControls(strip) {
  const monitor = state.monitor;
  const extra = strip.el.querySelector('.strip-extra');
  extra.querySelector('.monitor-enabled').checked = monitor.enabled;
  extra.querySelector('.monitor-mic').checked = monitor.includesMic;
  extra.querySelector('.monitor-mic').disabled = !monitor.enabled;

  const select = extra.querySelector('.monitor-device');
  const outputs = devices.outputs.filter((d) => d.uid !== state.output?.uid);
  select.replaceChildren(...[{ uid: '', name: 'Default' }, ...outputs].map((d) => new Option(d.name, d.uid)));
  select.value = monitor.selectedUID ?? '';
  select.disabled = !monitor.enabled;
}

function updateStrip(strip, { name, gain, muted, note }) {
  const { el, fader } = strip;
  el.querySelector('.name').textContent = name;
  el.querySelector('.name').title = name;
  el.classList.toggle('muted', muted);
  el.querySelector('.mute').classList.toggle('on', muted);
  if (!strip.dragging) {
    const db = gainToDb(gain);
    fader.value = Math.max(FADER_MIN_DB, Math.min(12, db));
    el.querySelector('.db').textContent = formatDb(db);
  }
  let noteEl = el.querySelector('.note');
  if (note) {
    if (!noteEl) {
      noteEl = document.createElement('div');
      noteEl.className = 'note';
      el.querySelector('.strip-body').append(noteEl);
    }
    noteEl.textContent = note;
  } else {
    noteEl?.remove();
  }
  el.classList.toggle('inactive', Boolean(note));
}

function updateMicControls(strip) {
  const mic = state.mic;
  const extra = strip.el.querySelector('.strip-extra');
  extra.querySelector('.mic-enabled').checked = mic.enabled;

  const select = extra.querySelector('.mic-device');
  const inputs = devices.inputs.filter((d) => d.uid !== state.output?.uid);
  const options = [{ uid: '', name: 'Default' }, ...inputs];
  select.replaceChildren(...options.map((d) => new Option(d.name, d.uid)));
  select.value = mic.selectedUID ?? '';
  select.disabled = !mic.enabled;

  const channels = mic.device?.channels ?? 1;
  const channelSelect = extra.querySelector('.mic-channel');
  channelSelect.replaceChildren(
    ...Array.from({ length: channels }, (_, i) => new Option(`Ch ${i + 1}`, String(i))));
  channelSelect.value = String(Math.min(mic.channel, channels - 1));
  channelSelect.hidden = channels < 2;
  channelSelect.disabled = !mic.enabled;
}

function renderState() {
  if (!state) return;
  // Inputs on the left, buses on the right (like a desk).
  const desired = [
    { id: 'mic', kind: 'mic' },
    ...state.sources.map((s) => ({ id: s.id, kind: 'source' })),
    ...(state.pads.items.length ? [{ id: 'pads', kind: 'pads' }] : []),
    { id: 'master', kind: 'master' },
    { id: 'monitor', kind: 'monitor' },
  ];
  const wanted = new Set(desired.map((d) => d.id));
  for (const [id, strip] of strips) {
    if (!wanted.has(id)) {
      strip.el.remove();
      strips.delete(id);
    }
  }
  const elements = desired.map(({ id, kind }) => (strips.get(id) ?? createStrip(id, kind)).el);
  elements.forEach((el, i) => {
    if (stripsEl.children[i] !== el) stripsEl.insertBefore(el, stripsEl.children[i] ?? null);
  });

  updateStrip(strips.get('master'), { name: 'Master', gain: state.master.gain, muted: state.master.muted });
  strips.get('master').el.querySelector('.route').textContent = `→ ${state.output?.name ?? 'no output'}`;

  const monitor = state.monitor;
  updateStrip(strips.get('monitor'), {
    name: 'Monitor',
    gain: monitor.gain,
    muted: monitor.muted,
    note: !monitor.enabled ? 'off' : monitor.device ? null : 'no output device',
  });
  updateMonitorControls(strips.get('monitor'));
  const mic = state.mic;
  updateStrip(strips.get('mic'), {
    name: 'Mic',
    gain: mic.gain,
    muted: mic.muted,
    note: !mic.enabled ? 'off' : mic.device ? null : 'no input device',
  });
  updateMicControls(strips.get('mic'));
  for (const s of state.sources) {
    updateStrip(strips.get(s.id), {
      name: s.name, gain: s.gain, muted: s.muted, note: s.attached ? null : 'not running',
    });
  }

  if (strips.has('pads')) {
    updateStrip(strips.get('pads'), { name: 'Pads', gain: state.pads.gain, muted: state.pads.muted });
  }

  if (state.error) setStatus(state.error, 'error');
  else if (state.running) setStatus(`Live · ${(state.sampleRate / 1000).toFixed(1)} kHz`, 'live');
  else setStatus('stopped', 'idle');

  renderOutputs();
  renderApps();
  renderPads();
  $('hint-output').textContent = state.output?.name ?? 'BlackHole 2ch';
}

function setStatus(text, kind) {
  statusEl.textContent = text;
  statusEl.className = `status ${kind}`;
  statusEl.title = text;
}

function renderOutputs() {
  const outputs = devices.outputs;
  outputEl.replaceChildren(...outputs.map((d) => new Option(d.name, d.uid)));
  if (state?.output) outputEl.value = state.output.uid;
}

outputEl.addEventListener('change', () => send('setOutput', { uid: outputEl.value }));

// ---------- Apps ----------

function renderApps() {
  const added = new Set(state?.sources.map((s) => s.id) ?? []);
  const showAll = $('show-all').checked;
  const items = apps.filter((a) => !added.has(a.id) && (showAll || a.isApp || a.isPlaying));
  if (!items.length) {
    const empty = document.createElement('li');
    empty.className = 'empty';
    empty.textContent = 'No other apps with audio. Start playback in the app you want to add.';
    appsEl.replaceChildren(empty);
    return;
  }
  appsEl.replaceChildren(...items.map((a) => {
    const li = document.createElement('li');
    const button = document.createElement('button');
    button.className = a.isPlaying ? 'playing' : '';
    button.title = a.id;
    button.innerHTML = '<span class="dot"></span><span class="app-name"></span><span class="add">+</span>';
    button.querySelector('.app-name').textContent = a.name;
    button.addEventListener('click', () => send('addSource', { id: a.id }));
    li.append(button);
    return li;
  }));
}

$('show-all').addEventListener('change', renderApps);

// ---------- Pads ----------

const padEls = new Map(); // pad id -> button
let renamingPad = null;

function renderPads() {
  const items = state?.pads.items ?? [];
  const ids = new Set(items.map((p) => p.id));
  for (const [id, el] of padEls) {
    if (!ids.has(id)) {
      el.remove();
      padEls.delete(id);
    }
  }
  const elements = items.map((pad) => {
    let el = padEls.get(pad.id);
    if (!el) {
      el = createPad(pad.id);
      padEls.set(pad.id, el);
    }
    if (renamingPad !== pad.id) el.querySelector('.pad-name').textContent = pad.name;
    el.classList.toggle('loading', !pad.ready && !pad.error);
    el.classList.toggle('broken', Boolean(pad.error));
    el.title = pad.error ?? (pad.duration ? `${pad.name} · ${pad.duration.toFixed(1)} s` : pad.name);
    return el;
  });
  elements.push(addPadButton);
  elements.forEach((el, i) => {
    if (padGridEl.children[i] !== el) padGridEl.insertBefore(el, padGridEl.children[i] ?? null);
  });
}

function createPad(id) {
  const el = document.createElement('button');
  el.className = 'pad';
  el.innerHTML = '<span class="pad-progress"></span><span class="pad-name"></span>';
  el.addEventListener('click', () => {
    if (renamingPad !== id) send('triggerPad', { id });
  });
  el.addEventListener('contextmenu', async (e) => {
    e.preventDefault();
    const pad = state.pads.items.find((p) => p.id === id);
    const action = await window.pads.menu(pad?.name ?? '');
    if (action === 'rename') startRename(id);
    if (action === 'remove') send('removePad', { id });
    if (action === 'change') {
      const path = await window.pads.pickSound();
      if (path) send('setPadSound', { id, path });
    }
  });
  acceptSoundDrop(el, (path) => send('setPadSound', { id, path }));
  return el;
}

function startRename(id) {
  const el = padEls.get(id);
  const nameEl = el.querySelector('.pad-name');
  const input = document.createElement('input');
  input.className = 'pad-rename';
  input.value = nameEl.textContent;
  renamingPad = id;
  nameEl.replaceChildren(input);
  input.focus();
  input.select();

  let done = false;
  const finish = (commit) => {
    if (done) return;
    done = true;
    renamingPad = null;
    const name = input.value.trim();
    nameEl.textContent = commit && name ? name : state.pads.items.find((p) => p.id === id)?.name ?? '';
    if (commit && name) send('renamePad', { id, name });
  };
  input.addEventListener('keydown', (e) => {
    e.stopPropagation();
    if (e.key === 'Enter') finish(true);
    if (e.key === 'Escape') finish(false);
  });
  input.addEventListener('click', (e) => e.stopPropagation());
  input.addEventListener('blur', () => finish(true));
}

function acceptSoundDrop(el, onPath) {
  el.addEventListener('dragover', (e) => {
    e.preventDefault();
    el.classList.add('drop');
  });
  el.addEventListener('dragleave', () => el.classList.remove('drop'));
  el.addEventListener('drop', (e) => {
    e.preventDefault();
    el.classList.remove('drop');
    const file = e.dataTransfer.files[0];
    if (file) onPath(window.pads.pathForFile(file));
  });
}

const addPadButton = document.createElement('button');
addPadButton.className = 'pad pad-add';
addPadButton.textContent = '+';
addPadButton.title = 'Add a pad (or drop an audio file here)';
addPadButton.addEventListener('click', async () => {
  const path = await window.pads.pickSound();
  if (path) send('addPad', { path });
});
acceptSoundDrop(addPadButton, (path) => send('addPad', { path }));
padGridEl.append(addPadButton);

// Dropping a file anywhere else must not navigate the window to it.
window.addEventListener('dragover', (e) => e.preventDefault());
window.addEventListener('drop', (e) => e.preventDefault());

window.addEventListener('keydown', (e) => {
  if (e.key === 'Escape' && !renamingPad) send('stopPads');
});

// ---------- Meters ----------

let meterData = null;
function onMeters(data) { meterData = data; }

let lastFrame = performance.now();
function animateMeters(now) {
  const dt = (now - lastFrame) / 1000;
  lastFrame = now;
  for (const [id, strip] of strips) {
    let target = METER_MIN_DB;
    if (meterData) {
      target = strip.kind === 'source' ? meterData.sources[id] ?? -100 : meterData[id] ?? -100;
    }
    target = Math.max(METER_MIN_DB, target);
    strip.level = target > strip.level ? target : Math.max(target, strip.level - METER_FALL_DB_PER_S * dt);
    if (target >= strip.peak || now - strip.peakAt > PEAK_HOLD_MS) {
      strip.peak = target >= strip.peak ? target : Math.max(target, strip.peak - METER_FALL_DB_PER_S * dt);
      if (target >= strip.peak) strip.peakAt = now;
    }
    const toFraction = (db) => (Math.min(0, db) - METER_MIN_DB) / -METER_MIN_DB;
    strip.mask.style.height = `${(1 - toFraction(strip.level)) * 100}%`;
    strip.peakEl.style.bottom = `${toFraction(strip.peak) * 100}%`;
    strip.peakEl.classList.toggle('clip', strip.peak > -0.5);
  }
  for (const [id, el] of padEls) {
    const p = meterData?.padProgress?.[id];
    el.classList.toggle('playing', p !== undefined);
    el.style.setProperty('--progress', p ?? 0);
  }
  requestAnimationFrame(animateMeters);
}
requestAnimationFrame(animateMeters);

// ---------- Engine events ----------

window.engine.onEvent(({ event, data }) => {
  switch (event) {
    case 'state':
      state = data;
      renderState();
      break;
    case 'meters':
      onMeters(data);
      break;
    case 'devices':
      devices = data;
      renderState();
      break;
    case 'apps':
      apps = data;
      renderApps();
      break;
    case 'engineDown':
      meterData = null;
      setStatus(data.message, 'error');
      break;
    case 'error':
    case 'log':
      console.warn(`[engine ${event}]`, data.message);
      break;
  }
});

send('getState');
send('listDevices');
send('listApps');
