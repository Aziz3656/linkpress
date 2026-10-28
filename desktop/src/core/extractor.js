'use strict';
// Downloads a link with yt-dlp straight to disk. yt-dlp writes in chunks and resumes .part files,
// so very large streams never sit in memory.
const fs = require('fs');
const path = require('path');
const { run } = require('./run');

// Prefer the smallest stream that still covers the target, so 240p jobs don't pull a 4K file.
// If the site has nothing that tall, take the best available (the UI already warned about upscaling).
function formatSelector(targetHeight) {
  const h = targetHeight;
  return [
    `bv*[height>=${h}][height<=${h * 1.5}]+ba`,
    `b[height>=${h}][height<=${h * 1.5}]`,
    `bv*[height<=${h}]+ba`,
    `b[height<=${h}]`,
    'bv*+ba',
    'b',
  ].join('/');
}

async function download(ytdlp, url, { dir, targetHeight, ffmpeg, onProgress, signal }) {
  let filePath = null;
  const template = 'P|%(progress.downloaded_bytes)s|%(progress.total_bytes)s|%(progress.total_bytes_estimate)s|%(progress.speed)s|%(progress.eta)s';
  const args = [
    url,
    '--no-playlist',
    '--newline',
    '--progress', // --print implies --quiet, which would hide progress otherwise
    '--no-warnings',
    '--no-mtime',
    '--continue',
    '--restrict-filenames',
    '-f', formatSelector(targetHeight),
    '--merge-output-format', 'mkv',
    '-o', path.join(dir, '%(id)s.%(ext)s'),
    // yt-dlp needs ffmpeg to merge separate video and audio streams. The bundled copy is not on
    // PATH in the installed app, so point yt-dlp at it explicitly.
    ...(ffmpeg && path.isAbsolute(ffmpeg) ? ['--ffmpeg-location', ffmpeg] : []),
    '--progress-template', `download:${template}`,
    '--print', 'after_move:F|%(filepath)s',
  ];
  await run(ytdlp, args, {
    signal,
    onLine: (line) => {
      if (line.startsWith('F|')) filePath = line.slice(2);
      else if (line.startsWith('P|') && onProgress) {
        const [, done, total, est, speed, eta] = line.split('|').map((x) => (x === 'NA' || x === 'None' ? null : Number(x)));
        const t = total || est;
        onProgress({ fraction: t ? Math.min(1, done / t) : null, downloaded: done, total: t, speed, eta });
      }
    },
  });
  if (filePath && fs.existsSync(filePath)) return filePath;
  // The reported name can differ from what is on disk (e.g. a merge that fell back to another
  // container). The job folder only holds this download, so take the largest finished file.
  const files = fs.readdirSync(dir)
    .filter((f) => !/\.(part|ytdl|temp)$/i.test(f) && !/\.part-Frag/i.test(f))
    .map((f) => path.join(dir, f))
    .filter((f) => fs.statSync(f).isFile())
    .sort((a, b) => fs.statSync(b).size - fs.statSync(a).size);
  if (files.length) return files[0];
  throw new Error('yt-dlp finished but no downloaded file was found');
}

module.exports = { download, formatSelector };
