'use strict';
// Spawns a CLI tool and streams its output line by line. Nothing is buffered beyond one line,
// so a 10 GB transcode costs the same memory as a 10 MB one.
const { spawn } = require('child_process');

function run(bin, args, { onLine, onStderrLine, signal } = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(bin, args, { windowsHide: true });
    let stderrTail = '';
    const splitter = (cb) => {
      let buf = '';
      return (chunk) => {
        buf += chunk.toString('utf8');
        let i;
        while ((i = buf.search(/\r|\n/)) >= 0) {
          const line = buf.slice(0, i);
          buf = buf.slice(i + 1);
          if (line && cb) cb(line);
        }
      };
    };
    child.stdout.on('data', splitter(onLine));
    child.stderr.on('data', splitter((line) => {
      stderrTail = (stderrTail + line + '\n').slice(-4000);
      if (onStderrLine) onStderrLine(line);
    }));

    const abort = () => child.kill('SIGKILL');
    if (signal) {
      if (signal.aborted) abort();
      signal.addEventListener('abort', abort, { once: true });
    }

    child.on('error', (err) => {
      if (err.code === 'ENOENT') err.message = `Could not find "${bin}". Run "npm run fetch-bin" or install it on PATH.`;
      reject(err);
    });
    child.on('close', (code) => {
      if (signal) signal.removeEventListener('abort', abort);
      if (signal && signal.aborted) return reject(Object.assign(new Error('Canceled'), { canceled: true }));
      if (code === 0) resolve();
      else reject(new Error(lastErrorLine(stderrTail) || `${bin} exited with code ${code}`));
    });
  });
}

function lastErrorLine(text) {
  const lines = text.trim().split('\n').filter(Boolean);
  const err = lines.reverse().find((l) => /error/i.test(l));
  return (err || lines[0] || '').trim();
}

// Collects stdout fully: only for small JSON outputs such as ffprobe / yt-dlp -J.
async function runJson(bin, args, opts = {}) {
  const lines = [];
  await run(bin, args, { ...opts, onLine: (l) => lines.push(l) });
  return JSON.parse(lines.join('\n'));
}

module.exports = { run, runJson };
