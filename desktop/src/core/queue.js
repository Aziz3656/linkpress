'use strict';
// Batch queue for 1 to 100+ jobs. Jobs run with a small concurrency limit, each one streams from
// disk to disk through a child process, and the queue state is saved to JSON so a restart resumes it.
const EventEmitter = require('events');
const fs = require('fs');
const os = require('os');
const path = require('path');
const crypto = require('crypto');
const { probeFile, probeUrl } = require('./probe');
const { download } = require('./extractor');
const { transcode } = require('./transcoder');
const { analyze, getTarget } = require('./resolution');

const ACTIVE = ['probing', 'downloading', 'transcoding'];
const PROGRESS_INTERVAL_MS = 250;

class JobQueue extends EventEmitter {
  constructor({ bins, outputDir, workDir, stateFile, concurrency = 1, probeConcurrency = 4 }) {
    super();
    this.bins = bins;
    this.outputDir = outputDir;
    this.workDir = workDir || path.join(os.tmpdir(), 'linkpress');
    this.stateFile = stateFile;
    this.concurrency = concurrency;
    this.probeConcurrency = probeConcurrency;
    this.jobs = new Map();
    this.controllers = new Map();
    this.running = false;
    this.probing = 0;
    this.lastEmit = new Map();
    fs.mkdirSync(this.workDir, { recursive: true });
    this._load();
  }

  // ---------- public API ----------

  addFiles(files, targetId) {
    return files.map((f) => this._add({ kind: 'file', input: f, title: path.basename(f), targetId }));
  }

  addUrls(urls, targetId) {
    return urls
      .map((u) => u.trim())
      .filter((u) => /^https?:\/\//i.test(u))
      .map((u) => this._add({ kind: 'url', input: u, title: u, targetId }));
  }

  setTarget(ids, targetId) {
    getTarget(targetId);
    for (const id of ids) {
      const job = this.jobs.get(id);
      if (!job || ACTIVE.includes(job.status) || job.status === 'done') continue;
      job.targetId = targetId;
      job.analysis = job.meta ? analyze(job.meta, targetId) : null;
      this._changed(job, true);
    }
  }

  start() {
    this.running = true;
    this._pump();
    this.emit('running', true);
  }

  pause() {
    this.running = false;
    this.emit('running', false);
  }

  cancel(id) {
    const job = this.jobs.get(id);
    if (!job) return;
    const c = this.controllers.get(id);
    if (c) c.abort();
    else if (['queued', 'ready', 'error'].includes(job.status)) this._set(job, { status: 'canceled' });
  }

  retry(id) {
    const job = this.jobs.get(id);
    if (!job || !['error', 'canceled'].includes(job.status)) return;
    this._set(job, { status: job.meta ? 'ready' : 'queued', error: null, progress: 0 });
    if (!job.meta) this._probeNext();
    this._pump();
  }

  remove(ids) {
    for (const id of ids) {
      this.cancel(id);
      this.jobs.delete(id);
    }
    this._save();
    this.emit('removed', ids);
  }

  clearFinished() {
    this.remove([...this.jobs.values()].filter((j) => ['done', 'canceled'].includes(j.status)).map((j) => j.id));
  }

  list() {
    return [...this.jobs.values()];
  }

  stats() {
    const s = { total: 0, done: 0, active: 0, waiting: 0, failed: 0, upscale: 0, savedBytes: 0, inputBytes: 0, outputBytes: 0 };
    for (const j of this.jobs.values()) {
      s.total++;
      if (j.status === 'done') {
        s.done++;
        if (j.meta && j.meta.size && j.outputBytes) {
          s.inputBytes += j.meta.size;
          s.outputBytes += j.outputBytes;
          s.savedBytes += j.meta.size - j.outputBytes;
        }
      } else if (ACTIVE.includes(j.status)) s.active++;
      else if (j.status === 'error') s.failed++;
      else if (j.status !== 'canceled') s.waiting++;
      if (j.analysis && j.analysis.mode === 'upscale' && j.status !== 'done') s.upscale++;
    }
    return s;
  }

  // ---------- internals ----------

  _add({ kind, input, title, targetId }) {
    getTarget(targetId);
    const job = {
      id: crypto.randomUUID(),
      kind,
      input,
      title,
      targetId,
      status: 'queued', // queued -> probing -> ready -> downloading -> transcoding -> done
      progress: 0,
      stage: null,
      meta: null,
      analysis: null,
      output: null,
      outputBytes: null,
      error: null,
      addedAt: Date.now(),
    };
    this.jobs.set(job.id, job);
    this.emit('added', job);
    this._save();
    this._probeNext();
    return job;
  }

  // Probing runs ahead of processing so warnings and estimates show as soon as items are added.
  _probeNext() {
    while (this.probing < this.probeConcurrency) {
      const job = [...this.jobs.values()].find((j) => j.status === 'queued');
      if (!job) return;
      this.probing++;
      this._probe(job).finally(() => {
        this.probing--;
        this._probeNext();
        this._pump();
      });
    }
  }

  async _probe(job) {
    this._set(job, { status: 'probing', stage: 'Reading metadata' });
    try {
      if (job.kind === 'file') {
        job.meta = await probeFile(this.bins.ffprobe, job.input);
      } else {
        const res = await probeUrl(this.bins.ytdlp, job.input);
        if (res.kind === 'playlist') {
          // A playlist expands into one job per entry; the placeholder job is removed.
          this.addUrls(res.entries.map((e) => e.url), job.targetId);
          this.remove([job.id]);
          return;
        }
        job.meta = res.meta;
        // Generic pages often give yt-dlp a plain media URL without dimensions; ask ffprobe instead.
        if (!job.meta.height && job.meta.directUrl) {
          try {
            const direct = await probeFile(this.bins.ffprobe, job.meta.directUrl);
            job.meta = { ...direct, title: job.meta.title, extractor: job.meta.extractor, directUrl: job.meta.directUrl };
          } catch (_) {
            // Keep the partial metadata; the real file is probed again after download.
          }
        }
      }
      job.title = job.meta.title || job.title;
      job.analysis = analyze(job.meta, job.targetId);
      this._set(job, { status: 'ready', stage: null });
    } catch (err) {
      this._set(job, { status: 'error', error: err.message, stage: null });
    }
  }

  _pump() {
    if (!this.running) return;
    let active = [...this.jobs.values()].filter((j) => j.status === 'downloading' || j.status === 'transcoding').length;
    for (const job of this.jobs.values()) {
      if (active >= this.concurrency) break;
      if (job.status !== 'ready') continue;
      active++;
      this._process(job).finally(() => {
        this._pump();
        if (!this.list().some((j) => ['queued', 'probing', 'ready', ...ACTIVE].includes(j.status))) this.emit('drained', this.stats());
      });
    }
  }

  async _process(job) {
    const controller = new AbortController();
    this.controllers.set(job.id, controller);
    const { signal } = controller;
    let downloaded = null;
    // Claim the job synchronously so a parallel _pump() can't start it twice.
    this._set(job, { status: job.kind === 'url' ? 'downloading' : 'transcoding', stage: 'Starting', progress: 0 });
    try {
      fs.mkdirSync(this.outputDir, { recursive: true });
      await this._checkDiskSpace(job);

      let input = job.input;
      if (job.kind === 'url') {
        this._set(job, { status: 'downloading', stage: 'Downloading', progress: 0 });
        const jobDir = path.join(this.workDir, job.id);
        fs.mkdirSync(jobDir, { recursive: true });
        downloaded = await download(this.bins.ytdlp, job.input, {
          dir: jobDir,
          targetHeight: getTarget(job.targetId).height,
          ffmpeg: this.bins.ffmpeg,
          signal,
          onProgress: (p) => this._progress(job, p.fraction, p),
        });
        // Re-probe the actual file: the downloaded stream is what ffmpeg will scale.
        const real = await probeFile(this.bins.ffprobe, downloaded, { signal });
        job.downloadedMeta = real;
        if (!job.meta.height || !job.meta.size) {
          job.meta = { ...job.meta, width: real.width, height: real.height, size: job.meta.size || real.size, duration: job.meta.duration || real.duration };
          job.analysis = analyze(job.meta, job.targetId);
        }
        input = downloaded;
      }

      this._set(job, { status: 'transcoding', stage: 'Compressing', progress: 0 });
      const meta = job.downloadedMeta || job.meta;
      const output = this._uniqueOutputPath(job);
      const res = await transcode(this.bins.ffmpeg, {
        input,
        output,
        meta,
        targetId: job.targetId,
        signal,
        onProgress: (p) => this._progress(job, p.fraction, p),
      });
      this._set(job, { status: 'done', stage: null, progress: 1, output: res.output, outputBytes: res.bytes, finishedAt: Date.now() });
    } catch (err) {
      if (err.canceled) this._set(job, { status: 'canceled', stage: null });
      else this._set(job, { status: 'error', stage: null, error: err.message });
    } finally {
      this.controllers.delete(job.id);
      if (downloaded) fs.rmSync(path.dirname(downloaded), { recursive: true, force: true });
    }
  }

  async _checkDiskSpace(job) {
    if (!fs.promises.statfs) return;
    const need = ((job.analysis && job.analysis.estimatedBytes) || 0) + (job.kind === 'url' ? (job.meta && job.meta.size) || 0 : 0);
    for (const dir of new Set([this.outputDir, this.workDir])) {
      const s = await fs.promises.statfs(dir);
      const free = s.bavail * s.bsize;
      if (need && free < need * 1.2) {
        throw new Error(`Not enough disk space in ${dir}: need about ${Math.round(need / 1e6)} MB, ${Math.round(free / 1e6)} MB free`);
      }
    }
  }

  _uniqueOutputPath(job) {
    const safe = (job.title || 'video').replace(/[\\/:*?"<>|\u0000-\u001f]+/g, '_').replace(/\s+/g, ' ').trim().slice(0, 120) || 'video';
    let candidate = path.join(this.outputDir, `${safe}_${job.targetId}.mp4`);
    for (let n = 2; fs.existsSync(candidate); n++) candidate = path.join(this.outputDir, `${safe}_${job.targetId} (${n}).mp4`);
    return candidate;
  }

  _progress(job, fraction, detail) {
    if (fraction != null) job.progress = fraction;
    job.detail = detail;
    const now = Date.now();
    if (now - (this.lastEmit.get(job.id) || 0) < PROGRESS_INTERVAL_MS) return;
    this.lastEmit.set(job.id, now);
    this.emit('progress', { id: job.id, status: job.status, progress: job.progress, detail });
  }

  _set(job, patch) {
    Object.assign(job, patch);
    this._changed(job, true);
  }

  _changed(job, persist) {
    this.emit('updated', job);
    if (persist) this._save();
  }

  _save() {
    if (!this.stateFile) return;
    clearTimeout(this.saveTimer);
    this.saveTimer = setTimeout(() => {
      const data = JSON.stringify({ outputDir: this.outputDir, jobs: this.list() });
      const tmp = this.stateFile + '.tmp';
      fs.writeFile(tmp, data, (err) => !err && fs.rename(tmp, this.stateFile, () => {}));
    }, 300);
  }

  _load() {
    if (!this.stateFile || !fs.existsSync(this.stateFile)) return;
    try {
      const data = JSON.parse(fs.readFileSync(this.stateFile, 'utf8'));
      for (const j of data.jobs || []) {
        // Work interrupted by a quit goes back to waiting; nothing is lost but the partial output.
        if (ACTIVE.includes(j.status)) j.status = j.meta ? 'ready' : 'queued';
        j.progress = j.status === 'done' ? 1 : 0;
        this.jobs.set(j.id, j);
      }
      this._probeNext();
    } catch (_) {
      // A corrupt state file should never stop the app from opening.
    }
  }

  flush() {
    clearTimeout(this.saveTimer);
    if (this.stateFile) fs.writeFileSync(this.stateFile, JSON.stringify({ outputDir: this.outputDir, jobs: this.list() }));
  }
}

module.exports = { JobQueue };
