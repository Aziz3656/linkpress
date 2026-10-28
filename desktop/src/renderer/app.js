'use strict';
// Renderer: talks to the main process only through window.lp (see preload.js).
// Rows are created once and patched in place, so a 100+ item queue stays smooth.

const $ = (id) => document.getElementById(id);
const state = { jobs: new Map(), rows: new Map(), selected: new Set(), targets: [], targetId: '720p', running: false };

const STATUS_LABEL = {
  queued: 'Waiting for metadata',
  probing: 'Reading metadata…',
  ready: 'Ready',
  downloading: 'Downloading',
  transcoding: 'Compressing',
  done: 'Done',
  error: 'Failed',
  canceled: 'Canceled',
};
const ACTIVE = ['probing', 'downloading', 'transcoding'];

function formatBytes(bytes) {
  if (bytes == null || !isFinite(bytes)) return '—';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  let v = Math.abs(bytes);
  let i = 0;
  while (v >= 1024 && i < units.length - 1) { v /= 1024; i++; }
  return `${bytes < 0 ? '-' : ''}${v.toFixed(v >= 100 || i === 0 ? 0 : 1)} ${units[i]}`;
}
function formatEta(sec) {
  if (sec == null || !isFinite(sec)) return '';
  sec = Math.round(sec);
  if (sec < 60) return `${sec}s left`;
  if (sec < 3600) return `${Math.floor(sec / 60)}m ${sec % 60}s left`;
  return `${Math.floor(sec / 3600)}h ${Math.floor((sec % 3600) / 60)}m left`;
}
function el(tag, cls, text) {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (text != null) e.textContent = text;
  return e;
}
function toast(msg) {
  const t = el('div', 'toast', msg);
  document.body.appendChild(t);
  setTimeout(() => t.remove(), 3200);
}

// ---------- target resolution picker ----------

function renderTargets() {
  const box = $('targets');
  box.textContent = '';
  for (const t of state.targets) {
    const b = el('button', null, t.id);
    b.setAttribute('role', 'radio');
    b.setAttribute('aria-checked', String(t.id === state.targetId));
    b.onclick = async () => {
      state.targetId = t.id;
      window.lp.setSettings({ targetId: t.id });
      if (state.selected.size) await window.lp.setTarget([...state.selected], t.id);
      renderTargets();
      renderSummary();
    };
    box.appendChild(b);
  }
}

// ---------- queue rows ----------

function createRow(job) {
  const row = el('div', 'job');
  const check = el('input');
  check.type = 'checkbox';
  check.onchange = () => {
    check.checked ? state.selected.add(job.id) : state.selected.delete(job.id);
    syncSelectAll();
  };

  const info = el('div');
  const title = el('div', 'job-title');
  const sub = el('span', 'job-sub');
  info.append(title, sub);

  const res = el('div', 'job-res');
  const src = el('span', 'res-src');
  const arrow = el('span', null, '→');
  const select = el('select');
  for (const t of state.targets) select.appendChild(new Option(t.id, t.id));
  select.onchange = () => window.lp.setTarget([job.id], select.value);
  const chip = el('span', 'chip');
  res.append(src, arrow, select, chip);

  const size = el('div');
  const sizeLine = el('div', 'size-line');
  const delta = el('span');
  size.append(sizeLine, delta);

  const prog = el('div');
  const bar = el('div', 'bar');
  const fill = el('div', 'bar-fill');
  bar.appendChild(fill);
  const status = el('span', 'job-status');
  prog.append(bar, status);

  const actions = el('div', 'job-actions');

  row.append(check, info, res, size, prog, actions);
  const r = { row, check, title, sub, src, select, chip, sizeLine, delta, fill, status, actions, actionKey: null };
  state.rows.set(job.id, r);
  $('queue').appendChild(row);
  return r;
}

function updateRow(job) {
  const r = state.rows.get(job.id) || createRow(job);
  const a = job.analysis;
  const m = job.meta;
  r.row.className = `job ${job.status === 'error' ? 'is-error' : job.status === 'done' ? 'is-done' : ''}`;
  r.title.textContent = job.title || job.input;
  r.title.title = job.input;
  r.sub.textContent = job.kind === 'url' ? `${m && m.extractor ? m.extractor + ' · ' : ''}${job.input}` : job.input;

  r.src.textContent = m && m.height ? `${Math.min(m.width, m.height)}p` : '…';
  r.select.value = job.targetId;
  r.select.disabled = ACTIVE.includes(job.status) || job.status === 'done';

  r.chip.className = 'chip';
  r.chip.textContent = '';
  r.chip.title = '';
  if (a && a.mode === 'upscale') {
    r.chip.className = 'chip up';
    r.chip.textContent = 'UPSCALE';
    r.chip.title = 'Target is higher than the source. File size grows without adding real detail.';
  } else if (a && a.mode === 'downscale') {
    r.chip.className = 'chip down';
    r.chip.textContent = 'DOWN';
  } else if (a && a.mode === 'same') {
    r.chip.className = 'chip same';
    r.chip.textContent = 'SAME';
  }

  if (job.status === 'done' && job.outputBytes != null) {
    r.sizeLine.textContent = `${formatBytes(m && m.size)} → ${formatBytes(job.outputBytes)}`;
    const d = m && m.size ? job.outputBytes - m.size : null;
    setDelta(r.delta, d, m && m.size, false);
  } else if (a && a.estimatedBytes != null) {
    r.sizeLine.textContent = `${m.size ? (m.sizeIsEstimate ? '~' : '') + formatBytes(m.size) : '?'} → ~${formatBytes(a.estimatedBytes)}`;
    setDelta(r.delta, a.deltaBytes, m.size, true);
  } else {
    r.sizeLine.textContent = m && m.size ? formatBytes(m.size) : '—';
    r.delta.textContent = '';
  }

  r.fill.style.width = `${Math.round((job.progress || 0) * 100)}%`;
  r.fill.className = `bar-fill ${job.status === 'downloading' ? 'mint' : ''}`;
  setStatus(r, job, job.detail);
  renderActions(r, job);
}

function setDelta(node, delta, srcBytes, estimate) {
  if (delta == null || !srcBytes) {
    node.textContent = '';
    return;
  }
  const pct = Math.round((delta / srcBytes) * 100);
  if (delta <= 0) {
    node.className = 'delta-down';
    node.textContent = `${estimate ? 'Saves ~' : 'Saved '}${formatBytes(-delta)} (${pct}%)`;
  } else {
    node.className = 'delta-up';
    node.textContent = `${estimate ? 'Grows ~' : 'Grew '}${formatBytes(delta)} (+${pct}%)`;
  }
}

function setStatus(r, job, detail) {
  let text = STATUS_LABEL[job.status] || job.status;
  r.status.className = 'job-status';
  if (job.status === 'error') {
    r.status.className = 'job-status err';
    text = job.error || 'Failed';
  } else if (job.status === 'done') {
    r.status.className = 'job-status ok';
  } else if (job.status === 'downloading' || job.status === 'transcoding') {
    const pct = Math.round((job.progress || 0) * 100);
    const parts = [`${job.stage === 'Starting' ? 'Starting' : STATUS_LABEL[job.status]} ${pct}%`];
    if (detail && detail.speed) parts.push(`${formatBytes(detail.speed)}/s`);
    if (detail && detail.eta) parts.push(formatEta(detail.eta));
    text = parts.join(' · ');
  }
  r.status.textContent = text;
  r.status.title = text;
}

function renderActions(r, job) {
  const key = job.status;
  if (r.actionKey === key) return;
  r.actionKey = key;
  r.actions.textContent = '';
  const btn = (label, title, onclick, danger) => {
    const b = el('button', `icon-btn${danger ? ' danger' : ''}`, label);
    b.title = title;
    b.setAttribute('aria-label', title);
    b.onclick = onclick;
    r.actions.appendChild(b);
  };
  if (job.status === 'done') btn('↗', 'Show in folder', () => window.lp.showFile(job.output));
  if (job.status === 'error' || job.status === 'canceled') btn('↻', 'Retry', () => window.lp.retry(job.id));
  if (ACTIVE.includes(job.status) || job.status === 'ready' || job.status === 'queued') btn('■', 'Cancel', () => window.lp.cancel(job.id), true);
  if (!ACTIVE.includes(job.status)) btn('✕', 'Remove', () => window.lp.remove([job.id]), true);
}

function removeRows(ids) {
  for (const id of ids) {
    const r = state.rows.get(id);
    if (r) r.row.remove();
    state.rows.delete(id);
    state.jobs.delete(id);
    state.selected.delete(id);
  }
  renderSummary();
}

function syncSelectAll() {
  const all = $('select-all');
  all.checked = state.jobs.size > 0 && state.selected.size === state.jobs.size;
  all.indeterminate = state.selected.size > 0 && !all.checked;
  $('remove-selected').disabled = state.selected.size === 0;
}

// ---------- summary cards ----------

let summaryQueued = false;
function renderSummary() {
  // Coalesce bursts of updates (e.g. 100 files added at once) into one paint.
  if (summaryQueued) return;
  summaryQueued = true;
  requestAnimationFrame(() => {
    summaryQueued = false;
    paintSummary();
  });
}

function paintSummary() {
  const jobs = [...state.jobs.values()];
  $('empty').style.display = jobs.length ? 'none' : '';

  // Savings: finished jobs count with real sizes, pending jobs with estimates.
  let src = 0;
  let out = 0;
  let upscale = 0;
  for (const j of jobs) {
    if (j.status === 'canceled' || !j.meta || !j.meta.size) continue;
    if (j.status === 'done' && j.outputBytes != null) {
      src += j.meta.size;
      out += j.outputBytes;
    } else if (j.analysis && j.analysis.estimatedBytes != null) {
      src += j.meta.size;
      out += j.analysis.estimatedBytes;
    }
    if (j.analysis && j.analysis.mode === 'upscale' && j.status !== 'done') upscale++;
  }
  const saving = $('m-saving');
  if (src) {
    const diff = src - out;
    saving.textContent = `${diff >= 0 ? '' : '+'}${formatBytes(Math.abs(diff))}`;
    saving.classList.toggle('danger', diff < 0);
    $('m-saving-sub').textContent = `${formatBytes(src)} in → ~${formatBytes(out)} out (${Math.round((diff / src) * 100)}% ${diff >= 0 ? 'smaller' : 'larger'})`;
  } else {
    saving.textContent = '—';
    saving.classList.remove('danger');
    $('m-saving-sub').textContent = 'Add videos to see the size estimate';
  }

  const counted = jobs.filter((j) => j.status !== 'canceled');
  const done = counted.filter((j) => j.status === 'done').length;
  const failed = counted.filter((j) => j.status === 'error').length;
  const active = counted.filter((j) => ACTIVE.includes(j.status));
  const progressSum = counted.reduce((s, j) => s + (j.status === 'done' ? 1 : ACTIVE.includes(j.status) ? j.progress || 0 : 0), 0);
  $('m-progress').textContent = `${done} / ${counted.length}`;
  $('m-progress-bar').style.width = counted.length ? `${(progressSum / counted.length) * 100}%` : '0';
  const bits = [];
  if (active.length) bits.push(`${active.length} active`);
  if (failed) bits.push(`${failed} failed`);
  if (!counted.length) bits.push('Queue is empty');
  else if (done === counted.length) bits.push('All finished');
  else if (!state.running) bits.push('Paused · press Start');
  $('m-progress-sub').textContent = bits.join(' · ');

  // Target hint: red alert when this target would upscale anything, green note otherwise.
  const hint = $('target-hint');
  hint.textContent = '';
  const pending = jobs.filter((j) => j.meta && !['done', 'canceled'].includes(j.status));
  if (upscale) {
    const box = el('div', 'alert-box');
    box.append(el('span', 'alert-icon', '!'));
    const n = upscale;
    box.append(el('span', null, `${n} video${n === 1 ? ' is' : 's are'} below the target. Upscaling increases file size without improving native detail.`));
    hint.appendChild(box);
  } else if (pending.length) {
    const box = el('div', 'ok-box');
    box.append(el('span', null, 'No queued video is being upscaled, so every output gets smaller or stays the same.'));
    hint.appendChild(box);
  }

  const startBtn = $('start');
  startBtn.textContent = state.running ? 'Pause' : 'Start';
  startBtn.classList.toggle('paused', state.running);
  syncSelectAll();
}

// ---------- adding items ----------

async function addUrls() {
  const lines = $('url-input').value.split(/\s+/).filter(Boolean);
  const valid = lines.filter((l) => /^https?:\/\//i.test(l));
  if (!valid.length) {
    toast('Paste at least one link starting with http:// or https://');
    return;
  }
  await window.lp.addUrls(valid, state.targetId);
  $('url-input').value = '';
  if (valid.length < lines.length) toast(`Skipped ${lines.length - valid.length} line(s) that were not links`);
}

function setupDrop() {
  let depth = 0;
  const overlay = $('drop-overlay');
  window.addEventListener('dragenter', (e) => {
    if (![...e.dataTransfer.types].includes('Files')) return;
    depth++;
    overlay.classList.add('show');
  });
  window.addEventListener('dragleave', () => {
    depth = Math.max(0, depth - 1);
    if (!depth) overlay.classList.remove('show');
  });
  window.addEventListener('dragover', (e) => e.preventDefault());
  window.addEventListener('drop', async (e) => {
    e.preventDefault();
    depth = 0;
    overlay.classList.remove('show');
    const files = [...e.dataTransfer.files].map((f) => window.lp.pathForFile(f)).filter(Boolean);
    if (files.length) await window.lp.addFiles(files, state.targetId);
    else {
      const text = e.dataTransfer.getData('text/uri-list') || e.dataTransfer.getData('text/plain');
      if (text) await window.lp.addUrls(text.split(/\s+/), state.targetId);
    }
  });
}

// ---------- wiring ----------

async function init() {
  const data = await window.lp.init();
  state.targets = data.targets;
  state.targetId = data.settings.targetId;
  state.running = data.running;
  $('output-dir').textContent = data.settings.outputDir;
  $('output-dir').title = data.settings.outputDir;
  $('concurrency').value = String(data.settings.concurrency);
  renderTargets();
  for (const j of data.jobs) {
    state.jobs.set(j.id, j);
    updateRow(j);
  }
  renderSummary();

  window.lp.on('added', (j) => { state.jobs.set(j.id, j); updateRow(j); renderSummary(); });
  window.lp.on('updated', (j) => { state.jobs.set(j.id, j); updateRow(j); renderSummary(); });
  window.lp.on('progress', (p) => {
    const j = state.jobs.get(p.id);
    if (!j) return;
    j.progress = p.progress;
    j.status = p.status;
    j.detail = p.detail;
    const r = state.rows.get(p.id);
    if (r) {
      r.fill.style.width = `${Math.round(p.progress * 100)}%`;
      setStatus(r, j, p.detail);
    }
    renderSummary();
  });
  window.lp.on('removed', removeRows);
  window.lp.on('running', (v) => { state.running = v; renderSummary(); });
  window.lp.on('drained', (s) => toast(`Batch finished: ${s.done} done${s.failed ? `, ${s.failed} failed` : ''}`));

  $('add-urls').onclick = addUrls;
  $('url-input').addEventListener('keydown', (e) => (e.ctrlKey || e.metaKey) && e.key === 'Enter' && addUrls());
  $('paste').onclick = async () => {
    const text = await window.lp.readClipboard();
    const el = $('url-input');
    el.value = (el.value.trim() ? el.value.trim() + '\n' : '') + text.trim();
  };
  $('import-files').onclick = () => window.lp.pickFiles(state.targetId);
  $('open-output').onclick = async () => {
    const err = await window.lp.openOutput();
    if (err) toast(err);
  };
  $('change-output').onclick = async () => {
    const s = await window.lp.pickOutputDir();
    $('output-dir').textContent = s.outputDir;
    $('output-dir').title = s.outputDir;
  };
  $('start').onclick = () => (state.running ? window.lp.pause() : window.lp.start());
  $('clear-finished').onclick = () => window.lp.clearFinished();
  $('remove-selected').onclick = () => window.lp.remove([...state.selected]);
  $('concurrency').onchange = (e) => window.lp.setSettings({ concurrency: Number(e.target.value) });
  $('select-all').onchange = (e) => {
    state.selected = e.target.checked ? new Set(state.jobs.keys()) : new Set();
    for (const [id, r] of state.rows) r.check.checked = state.selected.has(id);
    syncSelectAll();
  };

  $('win-min').onclick = () => window.lp.window.minimize();
  $('win-max').onclick = () => window.lp.window.toggleMaximize();
  $('win-close').onclick = () => window.lp.window.close();
  setupDrop();
}

init();
