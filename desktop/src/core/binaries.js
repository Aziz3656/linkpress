'use strict';
// Locates ffmpeg, ffprobe and yt-dlp. Order: bundled (packaged app), project bin/, npm static builds, system PATH.
const fs = require('fs');
const path = require('path');

const exe = (name) => (process.platform === 'win32' ? `${name}.exe` : name);

// Inside a packaged Electron app, binaries must be read from app.asar.unpacked.
const unpacked = (p) => (p ? p.replace(`app.asar${path.sep}`, `app.asar.unpacked${path.sep}`) : p);

function firstExisting(candidates) {
  for (const c of candidates) if (c && fs.existsSync(c)) return c;
  return null;
}

function resolveBinaries() {
  const roots = [process.resourcesPath && path.join(process.resourcesPath, 'bin'), path.join(__dirname, '..', '..', 'bin')];
  const local = (name) => roots.filter(Boolean).map((r) => path.join(r, exe(name)));

  let ffmpegStatic = null;
  let ffprobeStatic = null;
  try { ffmpegStatic = unpacked(require('ffmpeg-static')); } catch (_) {}
  try { ffprobeStatic = unpacked(require('ffprobe-static').path); } catch (_) {}

  return {
    ffmpeg: firstExisting([...local('ffmpeg'), ffmpegStatic]) || exe('ffmpeg'),
    ffprobe: firstExisting([...local('ffprobe'), ffprobeStatic]) || exe('ffprobe'),
    ytdlp: firstExisting(local('yt-dlp')) || exe('yt-dlp'),
  };
}

module.exports = { resolveBinaries };
