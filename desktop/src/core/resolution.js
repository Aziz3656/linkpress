'use strict';
// Resolution rules shared by the desktop app and (ported 1:1) the Android app.
// Pure functions only: no I/O, so they are easy to test and to port.

const TARGETS = [
  { id: '1080p', height: 1080, videoKbps: 5000 },
  { id: '720p', height: 720, videoKbps: 2800 },
  { id: '480p', height: 480, videoKbps: 1400 },
  { id: '360p', height: 360, videoKbps: 800 },
  { id: '240p', height: 240, videoKbps: 450 },
];

const AUDIO_KBPS = 128;
// Bitrate does not scale linearly with pixel count; 0.75 tracks H.264 at a fixed CRF well enough.
const PIXEL_EXPONENT = 0.75;

function getTarget(id) {
  const t = TARGETS.find((x) => x.id === id);
  if (!t) throw new Error(`Unknown target resolution: ${id}`);
  return t;
}

// "Short side" is what people mean by 720p, so portrait 1080x1920 counts as 1080p.
function sourceShortSide(meta) {
  if (!meta || !meta.width || !meta.height) return 0;
  return Math.min(meta.width, meta.height);
}

// Output dimensions keep the aspect ratio and orientation, rounded to even numbers for yuv420p.
function outputDimensions(meta, targetId) {
  const { height: short } = getTarget(targetId);
  const w = meta.width;
  const h = meta.height;
  if (!w || !h) return { width: null, height: short };
  const even = (n) => Math.max(2, Math.round(n / 2) * 2);
  if (w >= h) return { width: even((w * short) / h), height: short };
  return { width: short, height: even((h * short) / w) };
}

// Returns { mode: 'upscale' | 'downscale' | 'same' | 'unknown', estimatedBytes, deltaBytes, deltaPct }.
function analyze(meta, targetId) {
  const target = getTarget(targetId);
  const srcShort = sourceShortSide(meta);
  const duration = meta && meta.duration > 0 ? meta.duration : 0;
  const srcBytes = meta && meta.size > 0 ? meta.size : 0;

  let mode = 'unknown';
  if (srcShort) {
    if (target.height > srcShort) mode = 'upscale';
    else if (target.height < srcShort) mode = 'downscale';
    else mode = 'same';
  }

  let estimatedBytes = null;
  if (duration) {
    const srcVideoKbps = sourceVideoKbps(meta);
    let videoKbps = target.videoKbps;
    if (srcVideoKbps && srcShort) {
      const scaled = srcVideoKbps * Math.pow(target.height / srcShort, 2 * PIXEL_EXPONENT);
      // Downscaling never needs more bits than a scaled copy of the source.
      // Upscaling invents pixels, so the encoder spends more bits on the same detail.
      videoKbps = mode === 'upscale' ? Math.max(scaled, srcVideoKbps * 1.05) : Math.min(target.videoKbps, scaled);
    }
    const audioKbps = meta.hasAudio === false ? 0 : AUDIO_KBPS;
    estimatedBytes = Math.round(((videoKbps + audioKbps) * 1000 * duration) / 8);
  }

  let deltaBytes = null;
  let deltaPct = null;
  if (estimatedBytes != null && srcBytes) {
    deltaBytes = estimatedBytes - srcBytes;
    deltaPct = Math.round((deltaBytes / srcBytes) * 100);
  }

  return {
    target: target.id,
    mode,
    sourceHeight: srcShort || null,
    estimatedBytes,
    deltaBytes,
    deltaPct,
    output: meta ? outputDimensions(meta, targetId) : null,
  };
}

function sourceVideoKbps(meta) {
  if (meta.videoBitrate > 0) return meta.videoBitrate / 1000;
  if (meta.size > 0 && meta.duration > 0) {
    const totalKbps = (meta.size * 8) / meta.duration / 1000;
    return Math.max(50, totalKbps - (meta.hasAudio === false ? 0 : AUDIO_KBPS));
  }
  return 0;
}

function formatBytes(bytes) {
  if (bytes == null || !isFinite(bytes)) return '—';
  const abs = Math.abs(bytes);
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  let i = 0;
  let v = abs;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return `${bytes < 0 ? '-' : ''}${v.toFixed(v >= 100 || i === 0 ? 0 : 1)} ${units[i]}`;
}

module.exports = { TARGETS, AUDIO_KBPS, getTarget, analyze, outputDimensions, formatBytes };
