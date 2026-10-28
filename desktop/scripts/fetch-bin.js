'use strict';
// Downloads the latest yt-dlp release into bin/ so it ships inside the installer.
// ffmpeg and ffprobe come from the ffmpeg-static / ffprobe-static npm packages.
const fs = require('fs');
const path = require('path');
const https = require('https');

const assets = { win32: 'yt-dlp.exe', darwin: 'yt-dlp_macos', linux: 'yt-dlp_linux' };
const platform = process.argv[2] || process.platform;
const asset = assets[platform];
if (!asset) throw new Error(`No yt-dlp build for platform ${platform}`);

const dest = path.join(__dirname, '..', 'bin', platform === 'win32' ? 'yt-dlp.exe' : 'yt-dlp');
fs.mkdirSync(path.dirname(dest), { recursive: true });

function get(url, redirects = 5) {
  https.get(url, { headers: { 'User-Agent': 'linkpress-fetch-bin' } }, (res) => {
    if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location && redirects > 0) {
      res.resume();
      return get(res.headers.location, redirects - 1);
    }
    if (res.statusCode !== 200) throw new Error(`Download failed: HTTP ${res.statusCode}`);
    const tmp = dest + '.part';
    res.pipe(fs.createWriteStream(tmp)).on('finish', () => {
      fs.renameSync(tmp, dest);
      fs.chmodSync(dest, 0o755);
      console.log(`yt-dlp saved to ${dest}`);
    });
  }).on('error', (e) => { throw e; });
}

get(`https://github.com/yt-dlp/yt-dlp/releases/latest/download/${asset}`);
