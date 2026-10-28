'use strict';
// Scales and compresses one file with ffmpeg. Output goes to "<name>.part.mp4" and is renamed
// only on success, so a crash or cancel never leaves a half file that looks finished.
const fs = require('fs');
const { run } = require('./run');
const { getTarget, outputDimensions, AUDIO_KBPS } = require('./resolution');

function buildArgs({ input, output, meta, targetId, preset = 'veryfast', crf = 23 }) {
  const target = getTarget(targetId);
  const dims = outputDimensions(meta, targetId);
  const scale = dims.width ? `scale=${dims.width}:${dims.height}:flags=lanczos` : `scale=-2:${dims.height}:flags=lanczos`;
  return [
    '-hide_banner', '-nostdin', '-y',
    '-i', input,
    '-map', '0:v:0', '-map', '0:a:0?',
    '-vf', `${scale},format=yuv420p`,
    '-c:v', 'libx264', '-preset', preset, '-crf', String(crf),
    // Cap the bitrate so a noisy source can't produce a file bigger than the estimate suggests.
    '-maxrate', `${Math.round(target.videoKbps * 1.5)}k`, '-bufsize', `${target.videoKbps * 3}k`,
    '-c:a', 'aac', '-b:a', `${AUDIO_KBPS}k`, '-ac', '2',
    '-movflags', '+faststart',
    '-progress', 'pipe:1', '-nostats',
    output,
  ];
}

async function transcode(ffmpeg, { input, output, meta, targetId, onProgress, signal }) {
  const part = output.replace(/\.mp4$/i, '') + '.part.mp4';
  const args = buildArgs({ input, output: part, meta, targetId });
  const duration = meta.duration || 0;
  const started = Date.now();
  let lastSize = 0;
  try {
    await run(ffmpeg, args, {
      signal,
      onLine: (line) => {
        const [k, v] = line.split('=');
        if (k === 'total_size') lastSize = Number(v) || lastSize;
        if (k === 'out_time_us' && duration && onProgress) {
          const fraction = Math.min(1, Number(v) / 1e6 / duration);
          const elapsed = (Date.now() - started) / 1000;
          onProgress({ fraction, outBytes: lastSize, eta: fraction > 0.01 ? (elapsed / fraction) * (1 - fraction) : null });
        }
      },
    });
    fs.renameSync(part, output);
  } catch (err) {
    fs.rmSync(part, { force: true });
    throw err;
  }
  return { output, bytes: fs.statSync(output).size };
}

module.exports = { transcode, buildArgs };
