const { app, BrowserWindow, Menu, dialog, ipcMain } = require('electron');
const { spawn } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');

// The audio engine is a separate native process (engine/, Swift), driven over
// JSON lines on stdin/stdout — see engine/PROTOCOL.md.
function enginePath() {
  const candidates = [
    process.env.MYMIXER_ENGINE,
    path.join(__dirname, '../engine/.build/release/mixerd'),
    path.join(__dirname, '../engine/.build/debug/mixerd'),
  ].filter(Boolean);
  return candidates.find((p) => fs.existsSync(p));
}

let win = null;
let engine = null;
let quitting = false;
let restartDelay = 500;

function sendToUI(message) {
  if (win && !win.isDestroyed()) win.webContents.send('engine:event', message);
}

function startEngine() {
  const bin = enginePath();
  if (!bin) {
    sendToUI({ event: 'engineDown', data: { message: 'mixerd not found — run `npm run engine`' } });
    return;
  }
  engine = spawn(bin, [], { stdio: ['pipe', 'pipe', 'pipe'] });
  const startedAt = Date.now();

  let buffer = '';
  engine.stdout.setEncoding('utf8');
  engine.stdout.on('data', (chunk) => {
    buffer += chunk;
    let newline;
    while ((newline = buffer.indexOf('\n')) >= 0) {
      const line = buffer.slice(0, newline);
      buffer = buffer.slice(newline + 1);
      if (!line.trim()) continue;
      try {
        sendToUI(JSON.parse(line));
      } catch {
        console.warn('[mixerd] bad line:', line);
      }
    }
  });
  engine.stderr.setEncoding('utf8');
  engine.stderr.on('data', (chunk) => console.warn('[mixerd]', chunk.trimEnd()));

  engine.on('exit', (code, signal) => {
    engine = null;
    if (quitting) return;
    sendToUI({ event: 'engineDown', data: { message: `engine exited (${signal ?? code}), restarting…` } });
    // Back off if it keeps crashing right after start.
    restartDelay = Date.now() - startedAt > 10_000 ? 500 : Math.min(restartDelay * 2, 10_000);
    setTimeout(startEngine, restartDelay);
  });
}

function sendToEngine(command) {
  if (engine?.stdin.writable) engine.stdin.write(JSON.stringify(command) + '\n');
}

function createWindow() {
  win = new BrowserWindow({
    width: 1000,
    height: 800,
    minWidth: 620,
    minHeight: 660,
    title: 'Vibe Mixer',
    backgroundColor: '#15171b',
    titleBarStyle: 'hiddenInset',
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      sandbox: true,
    },
  });
  win.loadFile(path.join(__dirname, 'renderer/index.html'));
  // The UI asks for a full snapshot once it's ready (also after reloads).
}

ipcMain.on('engine:cmd', (_event, command) => sendToEngine(command));

const SOUND_EXTENSIONS = ['wav', 'aif', 'aiff', 'mp3', 'm4a', 'aac', 'caf', 'flac'];

ipcMain.handle('pads:pickSound', async () => {
  const result = await dialog.showOpenDialog(win, {
    title: 'Choose a sound',
    properties: ['openFile'],
    filters: [{ name: 'Audio', extensions: SOUND_EXTENSIONS }],
  });
  return result.canceled ? null : result.filePaths[0];
});

// Native context menu for a pad; resolves to the chosen action or null.
ipcMain.handle('pads:menu', (_event, name) => new Promise((resolve) => {
  let chosen = null;
  const item = (label, action) => ({ label, click: () => { chosen = action; } });
  Menu.buildFromTemplate([
    { label: name, enabled: false },
    { type: 'separator' },
    item('Rename…', 'rename'),
    item('Change Sound…', 'change'),
    { type: 'separator' },
    item('Remove', 'remove'),
  ]).popup({ window: win, callback: () => resolve(chosen) });
}));

app.whenReady().then(() => {
  createWindow();
  startEngine();
});

app.on('window-all-closed', () => app.quit());

app.on('before-quit', () => {
  quitting = true;
  if (engine) {
    sendToEngine({ cmd: 'quit' });
    engine.stdin.end();
  }
});
