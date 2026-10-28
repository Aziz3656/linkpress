'use strict';
// The only bridge between the UI and Node. The renderer gets these functions and nothing else.
const { contextBridge, ipcRenderer, webUtils } = require('electron');

const invoke = (ch) => (...args) => ipcRenderer.invoke(ch, ...args);

contextBridge.exposeInMainWorld('lp', {
  init: invoke('app:init'),
  addUrls: invoke('queue:addUrls'),
  addFiles: invoke('queue:addFiles'),
  pickFiles: invoke('queue:pickFiles'),
  setTarget: invoke('queue:setTarget'),
  start: invoke('queue:start'),
  pause: invoke('queue:pause'),
  cancel: invoke('queue:cancel'),
  retry: invoke('queue:retry'),
  remove: invoke('queue:remove'),
  clearFinished: invoke('queue:clearFinished'),
  stats: invoke('queue:stats'),
  setSettings: invoke('settings:set'),
  pickOutputDir: invoke('settings:pickOutputDir'),
  openOutput: invoke('shell:openOutput'),
  showFile: invoke('shell:showFile'),
  readClipboard: invoke('clipboard:read'),
  // Dropped File objects only expose their disk path through webUtils in sandboxed renderers.
  pathForFile: (file) => webUtils.getPathForFile(file),
  window: {
    minimize: () => ipcRenderer.send('window:minimize'),
    toggleMaximize: () => ipcRenderer.send('window:toggleMaximize'),
    close: () => ipcRenderer.send('window:close'),
  },
  on: (event, cb) => {
    const ch = `queue:${event}`;
    const listener = (_e, payload) => cb(payload);
    ipcRenderer.on(ch, listener);
    return () => ipcRenderer.removeListener(ch, listener);
  },
  onMaximized: (cb) => ipcRenderer.on('window:maximized', (_e, v) => cb(v)),
});
