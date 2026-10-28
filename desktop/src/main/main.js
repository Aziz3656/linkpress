'use strict';
const { app, BrowserWindow, ipcMain, dialog, shell, clipboard } = require('electron');
const fs = require('fs');
const path = require('path');
const { JobQueue } = require('../core/queue');
const { resolveBinaries } = require('../core/binaries');
const { TARGETS } = require('../core/resolution');

// Lets tests and portable installs keep their queue and settings in a chosen folder.
if (process.env.LINKPRESS_USER_DATA) app.setPath('userData', process.env.LINKPRESS_USER_DATA);

let win;
let queue;
const settingsFile = () => path.join(app.getPath('userData'), 'settings.json');

function loadSettings() {
  const defaults = { outputDir: path.join(app.getPath('videos'), 'LinkPress'), targetId: '720p', concurrency: 1 };
  try {
    return { ...defaults, ...JSON.parse(fs.readFileSync(settingsFile(), 'utf8')) };
  } catch (_) {
    return defaults;
  }
}
let settings;
function saveSettings(patch) {
  settings = { ...settings, ...patch };
  fs.writeFileSync(settingsFile(), JSON.stringify(settings, null, 2));
}

function send(channel, payload) {
  if (win && !win.isDestroyed()) win.webContents.send(channel, payload);
}

function createWindow() {
  win = new BrowserWindow({
    width: 1280,
    height: 820,
    minWidth: 960,
    minHeight: 640,
    frame: false,
    backgroundColor: '#071C13',
    show: false,
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
    },
  });
  win.loadFile(path.join(__dirname, '..', 'renderer', 'index.html'));
  win.once('ready-to-show', () => win.show());
  win.on('maximize', () => send('window:maximized', true));
  win.on('unmaximize', () => send('window:maximized', false));
}

function setupQueue() {
  queue = new JobQueue({
    bins: resolveBinaries(),
    outputDir: settings.outputDir,
    workDir: path.join(app.getPath('temp'), 'linkpress-work'),
    stateFile: path.join(app.getPath('userData'), 'queue.json'),
    concurrency: settings.concurrency,
  });
  for (const ev of ['added', 'updated', 'progress', 'removed', 'running', 'drained']) {
    queue.on(ev, (payload) => send(`queue:${ev}`, payload));
  }
}

ipcMain.handle('app:init', () => ({ settings, targets: TARGETS, jobs: queue.list(), running: queue.running, stats: queue.stats(), platform: process.platform }));
ipcMain.handle('queue:addUrls', (_e, urls, targetId) => queue.addUrls(urls, targetId).map((j) => j.id));
ipcMain.handle('queue:addFiles', (_e, files, targetId) => queue.addFiles(files, targetId).map((j) => j.id));
ipcMain.handle('queue:pickFiles', async (_e, targetId) => {
  const r = await dialog.showOpenDialog(win, {
    title: 'Import videos',
    properties: ['openFile', 'multiSelections'],
    filters: [{ name: 'Videos', extensions: ['mp4', 'mkv', 'mov', 'avi', 'webm', 'm4v', 'flv', 'wmv', 'ts', '3gp'] }, { name: 'All files', extensions: ['*'] }],
  });
  return r.canceled ? [] : queue.addFiles(r.filePaths, targetId).map((j) => j.id);
});
ipcMain.handle('queue:setTarget', (_e, ids, targetId) => queue.setTarget(ids, targetId));
ipcMain.handle('queue:start', () => queue.start());
ipcMain.handle('queue:pause', () => queue.pause());
ipcMain.handle('queue:cancel', (_e, id) => queue.cancel(id));
ipcMain.handle('queue:retry', (_e, id) => queue.retry(id));
ipcMain.handle('queue:remove', (_e, ids) => queue.remove(ids));
ipcMain.handle('queue:clearFinished', () => queue.clearFinished());
ipcMain.handle('queue:stats', () => queue.stats());

ipcMain.handle('settings:set', (_e, patch) => {
  const allowed = {};
  if (patch.targetId) allowed.targetId = patch.targetId;
  if (patch.concurrency) allowed.concurrency = Math.max(1, Math.min(4, Number(patch.concurrency) || 1));
  saveSettings(allowed);
  if (allowed.concurrency) queue.concurrency = allowed.concurrency;
  return settings;
});
ipcMain.handle('settings:pickOutputDir', async () => {
  const r = await dialog.showOpenDialog(win, { title: 'Choose output folder', defaultPath: settings.outputDir, properties: ['openDirectory', 'createDirectory'] });
  if (r.canceled || !r.filePaths[0]) return settings;
  saveSettings({ outputDir: r.filePaths[0] });
  queue.outputDir = settings.outputDir;
  return settings;
});

ipcMain.handle('shell:openOutput', async () => {
  fs.mkdirSync(settings.outputDir, { recursive: true });
  return shell.openPath(settings.outputDir);
});
ipcMain.handle('shell:showFile', (_e, file) => file && fs.existsSync(file) && shell.showItemInFolder(file));
ipcMain.handle('clipboard:read', () => clipboard.readText());

ipcMain.on('window:minimize', () => win.minimize());
ipcMain.on('window:toggleMaximize', () => (win.isMaximized() ? win.unmaximize() : win.maximize()));
ipcMain.on('window:close', () => win.close());

app.whenReady().then(() => {
  settings = loadSettings();
  setupQueue();
  createWindow();
  app.on('activate', () => BrowserWindow.getAllWindows().length === 0 && createWindow());
});
app.on('before-quit', () => queue && queue.flush());
app.on('window-all-closed', () => process.platform !== 'darwin' && app.quit());
