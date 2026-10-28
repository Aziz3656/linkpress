'use strict';
// Metadata for local files (ffprobe) and links (yt-dlp -J), normalized to one shape:
// { title, width, height, duration, size, videoBitrate, hasAudio, container, vcodec, sizeIsEstimate }
const fs = require('fs');
const path = require('path');
const { runJson } = require('./run');

async function probeFile(ffprobe, file, opts) {
  const data = await runJson(ffprobe, ['-v', 'error', '-print_format', 'json', '-show_format', '-show_streams', file], opts);
  const v = (data.streams || []).find((s) => s.codec_type === 'video' && !(s.disposition && s.disposition.attached_pic));
  if (!v) throw new Error('No video stream found in file');
  const a = (data.streams || []).find((s) => s.codec_type === 'audio');
  const fmt = data.format || {};
  let width = Number(v.width) || 0;
  let height = Number(v.height) || 0;
  // Phones store portrait video as landscape plus a rotation flag.
  const rotation = Math.abs(Number((v.tags && v.tags.rotate) || (v.side_data_list || []).map((d) => d.rotation).find((r) => r != null) || 0));
  if (rotation === 90 || rotation === 270) [width, height] = [height, width];
  // Works for local paths and for direct http(s) media URLs, which ffprobe can read too.
  const isUrl = /^https?:\/\//i.test(file);
  const size = isUrl ? Number(fmt.size) || 0 : fs.statSync(file).size;
  return {
    title: path.basename(isUrl ? new URL(file).pathname : file).replace(/\.[^.]+$/, '') || 'video',
    width,
    height,
    duration: Number(fmt.duration || v.duration) || 0,
    size,
    videoBitrate: Number(v.bit_rate) || 0,
    hasAudio: !!a,
    container: (fmt.format_name || '').split(',')[0],
    vcodec: v.codec_name,
    sizeIsEstimate: false,
  };
}

// Returns { kind: 'video', meta } or { kind: 'playlist', title, entries: [{ url, title }] }.
async function probeUrl(ytdlp, url, opts) {
  const data = await runJson(ytdlp, ['-J', '--flat-playlist', '--no-warnings', url], opts);
  if (data._type === 'playlist') {
    const entries = (data.entries || [])
      .map((e) => ({ url: e.url || e.webpage_url || (e.id && e.ie_key === 'Youtube' ? `https://www.youtube.com/watch?v=${e.id}` : null), title: e.title }))
      .filter((e) => e.url);
    return { kind: 'playlist', title: data.title, entries };
  }
  return { kind: 'video', meta: normalizeYtdlp(data) };
}

function normalizeYtdlp(d) {
  // Best video format yt-dlp knows about tells us the true source resolution.
  const formats = (d.formats || []).filter((f) => f.vcodec && f.vcodec !== 'none' && f.height);
  const best = formats.sort((a, b) => b.height * (b.width || 1) - a.height * (a.width || 1))[0] || {};
  const width = d.width || best.width || 0;
  const height = d.height || best.height || 0;
  const size = d.filesize || d.filesize_approx || best.filesize || best.filesize_approx || 0;
  const vbr = best.vbr || d.vbr || 0;
  return {
    title: d.title || d.id || 'video',
    width,
    height,
    duration: Number(d.duration) || 0,
    size,
    videoBitrate: vbr ? vbr * 1000 : 0,
    hasAudio: d.acodec ? d.acodec !== 'none' : true,
    container: d.ext,
    vcodec: d.vcodec || best.vcodec,
    sizeIsEstimate: !d.filesize,
    extractor: d.extractor_key || d.extractor,
    directUrl: d.url || null,
  };
}

module.exports = { probeFile, probeUrl, normalizeYtdlp };
