# LinkPress (desktop)

Paste website links or import videos, pick a target resolution (1080p, 720p, 480p, 360p, 240p),
and get compressed MP4 files in one folder. Built with Electron, yt-dlp and ffmpeg. Works offline
for local files; links need internet only for the download.

## Run it

Requires Node.js 20+.

```bash
npm install          # also downloads ffmpeg + ffprobe for your OS
npm run fetch-bin    # downloads yt-dlp into bin/
npm start
```

## Build the Windows .exe

Run these on a Windows PC (ffmpeg-static downloads the binary for the OS that runs `npm install`):

```bash
npm install
npm run fetch-bin
npm run dist:win     # dist/LinkPress Setup 0.1.0.exe and a portable LinkPress 0.1.0.exe
```

## How it works

| Part | File | What it does |
|---|---|---|
| Resolution rules | `src/core/resolution.js` | Upscale / downscale detection (short side, so portrait works) and file size estimates |
| Metadata | `src/core/probe.js` | `ffprobe` for files, `yt-dlp -J` for links; playlists expand into one job per video |
| Download | `src/core/extractor.js` | `yt-dlp` picks the smallest stream that still covers the target, writes straight to disk, resumes `.part` files |
| Compress | `src/core/transcoder.js` | `ffmpeg` H.264 + AAC, Lanczos scaling, bitrate cap, `+faststart`; writes `.part.mp4` and renames only on success |
| Queue | `src/core/queue.js` | 1 to 100+ jobs, metadata probed ahead (4 at a time), 1 to 4 parallel jobs, cancel/retry, disk space check, saved to `queue.json` so a restart resumes |
| Window | `src/main/main.js` | Frameless window, folder dialogs, "Open output folder" via `shell.openPath` |
| UI | `src/renderer/` | Bento grid on the project design system (#071C13 / #0D2D20 / #00FF66 / #8EFFC1 / #FF3B30) |

Large files: every tool runs as a child process that streams disk to disk, and the app reads its
output one line at a time, so memory use is the same for a 10 MB clip and a 10 GB recording.

## Tests

```bash
npm test
```

Runs the resolution rules plus real end-to-end jobs: generated clips through ffprobe and ffmpeg,
a link served over local HTTP through yt-dlp, cancel mid-encode, and queue restore after restart.
