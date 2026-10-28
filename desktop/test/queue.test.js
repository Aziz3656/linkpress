'use strict';
// End-to-end: real ffprobe/ffmpeg/yt-dlp on generated clips, including a link served over HTTP.
const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const http = require('http');
const { execFileSync } = require('child_process');
const { JobQueue } = require('../src/core/queue');
const { resolveBinaries } = require('../src/core/binaries');

const bins = resolveBinaries();
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'lp-test-'));

function makeClip(name, w, h, seconds = 3) {
  const file = path.join(tmp, name);
  execFileSync(bins.ffmpeg, ['-v', 'error', '-y', '-f', 'lavfi', '-i', `testsrc2=size=${w}x${h}:rate=30:duration=${seconds}`,
    '-f', 'lavfi', '-i', `sine=frequency=440:duration=${seconds}`, '-c:v', 'libx264', '-b:v', '6M', '-c:a', 'aac', '-shortest', file]);
  return file;
}

function waitDrained(q) {
  return new Promise((resolve) => q.once('drained', resolve));
}

test('batch of local files: downscale and upscale warning', async () => {
  const big = makeClip('big.mp4', 1920, 1080);
  const small = makeClip('small.mp4', 640, 360);
  const out = path.join(tmp, 'out1');
  const q = new JobQueue({ bins, outputDir: out, workDir: path.join(tmp, 'work'), stateFile: path.join(tmp, 'state1.json') });
  const [a] = q.addFiles([big], '480p');
  const [b] = q.addFiles([small], '720p');
  q.start();
  await waitDrained(q);
  assert.equal(a.status, 'done', a.error);
  assert.equal(a.analysis.mode, 'downscale');
  assert.equal(b.status, 'done', b.error);
  assert.equal(b.analysis.mode, 'upscale');
  const h = execFileSync(bins.ffprobe, ['-v', 'error', '-select_streams', 'v:0', '-show_entries', 'stream=width,height', '-of', 'csv=p=0', a.output]).toString().trim();
  assert.equal(h, '854,480');
  assert.ok(a.outputBytes < fs.statSync(big).size);
  assert.equal(fs.readdirSync(out).filter((f) => f.includes('.part')).length, 0);
  q.flush();
});

test('link download through yt-dlp', async () => {
  const clip = makeClip('remote.mp4', 1280, 720);
  const server = http.createServer((req, res) => {
    const stat = fs.statSync(clip);
    res.writeHead(200, { 'Content-Type': 'video/mp4', 'Content-Length': stat.size });
    fs.createReadStream(clip).pipe(res);
  });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const url = `http://127.0.0.1:${server.address().port}/remote.mp4`;
  const q = new JobQueue({ bins, outputDir: path.join(tmp, 'out2'), workDir: path.join(tmp, 'work2'), stateFile: null });
  const [job] = q.addUrls([url, 'not a url'], '360p');
  assert.equal(q.list().length, 1);
  q.start();
  await waitDrained(q);
  server.close();
  assert.equal(job.status, 'done', job.error);
  assert.ok(fs.existsSync(job.output));
});

test('cancel stops a running job and leaves no partial file', async () => {
  const long = makeClip('long.mp4', 1920, 1080, 20);
  const out = path.join(tmp, 'out3');
  const q = new JobQueue({ bins, outputDir: out, workDir: path.join(tmp, 'work3'), stateFile: null });
  const [job] = q.addFiles([long], '240p');
  q.on('progress', (p) => p.id === job.id && p.progress > 0.05 && q.cancel(job.id));
  q.start();
  await waitDrained(q);
  assert.equal(job.status, 'canceled');
  assert.deepEqual(fs.readdirSync(out), []);
});

test('state file restores the queue after restart', () => {
  const q = new JobQueue({ bins, outputDir: path.join(tmp, 'out1'), stateFile: path.join(tmp, 'state1.json') });
  assert.equal(q.list().length, 2);
  assert.ok(q.list().every((j) => j.status === 'done'));
});
