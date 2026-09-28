const { contextBridge, ipcRenderer, webUtils } = require('electron');

contextBridge.exposeInMainWorld('engine', {
  send: (command) => ipcRenderer.send('engine:cmd', command),
  onEvent: (handler) => ipcRenderer.on('engine:event', (_event, message) => handler(message)),
});

contextBridge.exposeInMainWorld('pads', {
  pickSound: () => ipcRenderer.invoke('pads:pickSound'),
  menu: (name) => ipcRenderer.invoke('pads:menu', name),
  // Dropped files carry no path in the renderer; Electron resolves it here.
  pathForFile: (file) => webUtils.getPathForFile(file),
});
