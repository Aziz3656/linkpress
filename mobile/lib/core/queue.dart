// Batch queue for 1 to 100+ videos, mirroring desktop/src/core/queue.js.
// Metadata is probed ahead (a few at a time) so warnings show right away; processing runs with a
// small concurrency limit; the queue is saved to JSON so closing the app doesn't lose it.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'media.dart';
import 'native.dart';
import 'resolution.dart';

enum JobStatus { queued, probing, ready, downloading, transcoding, saving, done, error, canceled }

const _active = {JobStatus.probing, JobStatus.downloading, JobStatus.transcoding, JobStatus.saving};

class Job {
  final String id;
  final bool isUrl;
  final String input; // http(s) link or content:// URI
  String title;
  String targetId;
  JobStatus status = JobStatus.queued;
  double progress = 0;
  VideoMeta? meta;
  int knownSize;
  String? outputUri;
  int? outputBytes;
  String? error;

  Job({required this.id, required this.isUrl, required this.input, required this.title, required this.targetId, this.knownSize = 0});

  Analysis? get analysis => meta == null ? null : analyze(meta!, targetId);
  bool get isActive => _active.contains(status);
  bool get isFinished => status == JobStatus.done || status == JobStatus.canceled;

  Map<String, dynamic> toJson() => {
        'id': id,
        'isUrl': isUrl,
        'input': input,
        'title': title,
        'targetId': targetId,
        'status': status.name,
        'meta': meta?.toJson(),
        'knownSize': knownSize,
        'outputUri': outputUri,
        'outputBytes': outputBytes,
        'error': error,
      };

  static Job fromJson(Map<String, dynamic> j) {
    final job = Job(id: j['id'], isUrl: j['isUrl'], input: j['input'], title: j['title'], targetId: j['targetId'], knownSize: j['knownSize'] ?? 0)
      ..meta = j['meta'] == null ? null : VideoMeta.fromJson(Map<String, dynamic>.from(j['meta']))
      ..outputUri = j['outputUri']
      ..outputBytes = j['outputBytes']
      ..error = j['error'];
    var s = JobStatus.values.byName(j['status']);
    // Work interrupted by a quit goes back to waiting.
    if (_active.contains(s)) s = job.meta != null ? JobStatus.ready : JobStatus.queued;
    job.status = s;
    job.progress = s == JobStatus.done ? 1 : 0;
    return job;
  }
}

class JobQueue extends ChangeNotifier {
  final List<Job> jobs = [];
  final _downloads = <String, bool>{};
  final _transcodes = <String, Transcode>{};
  bool running = false;
  int concurrency = 1;
  String galleryFolder = 'Movies'; // or 'Download'
  int _probing = 0;
  int _seq = 0;
  late Directory _work;
  late File _stateFile;
  Timer? _saveTimer;
  Timer? _notifyTimer;

  static const probeConcurrency = 3;

  Future<void> init() async {
    _work = Directory('${(await getTemporaryDirectory()).path}/linkpress');
    await _work.create(recursive: true);
    _stateFile = File('${(await getApplicationSupportDirectory()).path}/queue.json');
    if (await _stateFile.exists()) {
      try {
        final data = jsonDecode(await _stateFile.readAsString()) as Map<String, dynamic>;
        concurrency = data['concurrency'] ?? 1;
        galleryFolder = data['galleryFolder'] ?? 'Movies';
        for (final j in (data['jobs'] as List)) {
          jobs.add(Job.fromJson(Map<String, dynamic>.from(j)));
        }
      } catch (_) {
        // A corrupt state file must never stop the app from opening.
      }
    }
    notifyListeners();
    _probeNext();
  }

  // ---------- public API ----------

  int addUrls(Iterable<String> text, String targetId) {
    final urls = text.expand((t) => t.split(RegExp(r'\s+'))).where((u) => RegExp(r'^https?://', caseSensitive: false).hasMatch(u)).toList();
    for (final u in urls) {
      _add(Job(id: _newId(), isUrl: true, input: u, title: u, targetId: targetId));
    }
    return urls.length;
  }

  void addPicked(List<PickedVideo> files, String targetId) {
    for (final f in files) {
      _add(Job(id: _newId(), isUrl: false, input: f.uri, title: f.name.replaceAll(RegExp(r'\.[^.]+$'), ''), targetId: targetId, knownSize: f.size));
    }
  }

  void setTarget(Job job, String targetId) {
    if (job.isActive || job.status == JobStatus.done) return;
    job.targetId = targetId;
    _changed();
  }

  void setTargetForWaiting(String targetId) {
    for (final j in jobs) {
      if (!j.isActive && !j.isFinished && j.status != JobStatus.error) j.targetId = targetId;
    }
    _changed();
  }

  void start() {
    running = true;
    _pump();
    _changed();
  }

  void pause() {
    running = false;
    _changed();
  }

  Future<void> cancel(Job job) async {
    if (_downloads.containsKey(job.id)) {
      _downloads[job.id] = true;
      await Native.ytdlpCancel(job.id);
    }
    final t = _transcodes[job.id];
    if (t != null) await t.cancel();
    if (!job.isActive) {
      job.status = JobStatus.canceled;
      _changed();
    }
  }

  void retry(Job job) {
    if (job.status != JobStatus.error && job.status != JobStatus.canceled) return;
    job
      ..status = job.meta != null ? JobStatus.ready : JobStatus.queued
      ..error = null
      ..progress = 0;
    _changed();
    _probeNext();
    _pump();
  }

  void remove(Job job) {
    if (job.isActive) cancel(job);
    jobs.remove(job);
    _changed();
  }

  void clearFinished() {
    jobs.removeWhere((j) => j.isFinished);
    _changed();
  }

  void setConcurrency(int n) {
    concurrency = n.clamp(1, 3);
    _changed();
    _pump();
  }

  void setGalleryFolder(String folder) {
    galleryFolder = folder;
    _changed();
  }

  // ---------- internals ----------

  String _newId() => '${DateTime.now().microsecondsSinceEpoch}-${_seq++}';

  void _add(Job job) {
    jobs.add(job);
    _changed();
    _probeNext();
  }

  void _probeNext() {
    while (_probing < probeConcurrency) {
      final job = jobs.where((j) => j.status == JobStatus.queued).firstOrNull;
      if (job == null) return;
      _probing++;
      _probe(job).whenComplete(() {
        _probing--;
        _probeNext();
        _pump();
      });
    }
  }

  Future<void> _probe(Job job) async {
    job.status = JobStatus.probing;
    _changed();
    try {
      if (job.isUrl) {
        final info = await Native.ytdlpInfo(job.input);
        if (info['_type'] == 'playlist') {
          // A playlist expands into one job per entry.
          final entries = ((info['entries'] as List?) ?? []).map((e) => Map<String, dynamic>.from(e as Map));
          final urls = entries.map((e) => (e['url'] ?? e['webpage_url'])?.toString()).whereType<String>();
          final idx = jobs.indexOf(job);
          jobs.remove(job);
          final added = urls.map((u) => Job(id: _newId(), isUrl: true, input: u, title: u, targetId: job.targetId)).toList();
          jobs.insertAll(math.max(0, idx), added);
          _changed();
          return;
        }
        job.meta = metaFromYtdlp(info);
      } else {
        job.meta = await probe(job.input, title: job.title, knownSize: job.knownSize);
      }
      job.title = job.meta!.title;
      job.status = JobStatus.ready;
    } catch (e) {
      job
        ..status = JobStatus.error
        ..error = _clean(e);
    }
    _changed();
  }

  void _pump() {
    if (!running) return;
    var active = jobs.where((j) => j.status == JobStatus.downloading || j.status == JobStatus.transcoding || j.status == JobStatus.saving).length;
    for (final job in jobs.where((j) => j.status == JobStatus.ready).toList()) {
      if (active >= concurrency) break;
      active++;
      _process(job).whenComplete(() {
        _pump();
        _updateKeepAlive();
      });
    }
    _updateKeepAlive();
  }

  Future<void> _process(Job job) async {
    // Claim synchronously so a parallel _pump() can't start the job twice.
    job
      ..status = job.isUrl ? JobStatus.downloading : JobStatus.transcoding
      ..progress = 0
      ..error = null;
    _changed();
    final dir = Directory('${_work.path}/${job.id}');
    try {
      await dir.create(recursive: true);
      await _checkSpace(job);
      final target = targetById(job.targetId);
      var meta = job.meta!;
      var video = job.input;
      String? audio;

      if (job.isUrl) {
        _downloads[job.id] = false;
        final sub = Native.downloadProgress.where((p) => p.jobId == job.id).listen((p) {
          job.progress = p.fraction.clamp(0, 1);
          _progressChanged();
        });
        try {
          // Video first: the smallest stream that still covers the target. Audio is fetched
          // separately and merged during compression, so no second ffmpeg is needed for muxing.
          final h = target.height;
          video = await Native.ytdlpDownload(
            jobId: job.id,
            url: job.input,
            format: 'bv*[height>=$h][height<=${(h * 1.5).round()}]/bv*[height<=$h]/bv*/b',
            dir: dir.path,
          );
          final real = await probe(video, title: meta.title);
          if (!real.hasAudio && meta.hasAudio) {
            try {
              audio = await Native.ytdlpDownload(jobId: job.id, url: job.input, format: 'ba/bestaudio', dir: dir.path);
            } catch (_) {
              if (_downloads[job.id] == true) rethrow;
              // Some sites have no separate audio; keep the video-only result.
            }
          }
          meta = real.copyWith(title: meta.title, size: meta.size > 0 ? meta.size : real.size, duration: real.duration > 0 ? real.duration : meta.duration);
          if (job.meta!.shortSide == 0) job.meta = meta;
        } finally {
          await sub.cancel();
          _downloads.remove(job.id);
        }
      }

      job
        ..status = JobStatus.transcoding
        ..progress = 0;
      _changed();
      final t = Transcode();
      _transcodes[job.id] = t;
      final out = '${dir.path}/${_safeName(job.title)}_${job.targetId}.mp4';
      final bytes = await t.run(
        video: video,
        audio: audio,
        output: out,
        meta: meta,
        targetId: job.targetId,
        onProgress: (f) {
          job.progress = f;
          _progressChanged();
        },
      );
      _transcodes.remove(job.id);

      job.status = JobStatus.saving;
      _changed();
      job.outputUri = await Native.saveToGallery(path: out, name: '${_safeName(job.title)}_${job.targetId}.mp4', folder: galleryFolder);
      job
        ..outputBytes = bytes
        ..status = JobStatus.done
        ..progress = 1;
    } catch (e) {
      final canceled = e is Canceled || _downloads[job.id] == true || e.toString().contains('Canceled');
      job
        ..status = canceled ? JobStatus.canceled : JobStatus.error
        ..error = canceled ? null : _clean(e);
    } finally {
      _transcodes.remove(job.id);
      _downloads.remove(job.id);
      if (await dir.exists()) await dir.delete(recursive: true);
      _changed();
    }
  }

  Future<void> _checkSpace(Job job) async {
    final est = job.analysis?.estimatedBytes ?? 0;
    // Downloaded source + local output + gallery copy all exist for a moment.
    final need = est * 2 + (job.isUrl ? (job.meta?.size ?? 0) : 0);
    if (need == 0) return;
    final free = await Native.freeBytes(_work.path);
    if (free > 0 && free < need * 1.1) {
      throw Exception('Not enough storage: needs about ${formatBytes(need)}, ${formatBytes(free)} free');
    }
  }

  void _updateKeepAlive() {
    final active = jobs.where((j) => j.status == JobStatus.downloading || j.status == JobStatus.transcoding || j.status == JobStatus.saving).length;
    final waiting = jobs.where((j) => j.status == JobStatus.ready).length;
    if (running && (active > 0 || waiting > 0)) {
      final done = jobs.where((j) => j.status == JobStatus.done).length;
      final total = jobs.where((j) => j.status != JobStatus.canceled).length;
      Native.keepAlive('Processing videos: $done of $total done');
    } else {
      Native.stopKeepAlive();
    }
  }

  String _safeName(String s) {
    final n = s.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]+'), '_').replaceAll(RegExp(r'\s+'), ' ').trim();
    final name = n.isEmpty ? 'video' : n;
    return name.length > 100 ? name.substring(0, 100) : name;
  }

  String _clean(Object e) => e.toString().replaceFirst(RegExp(r'^(Exception|PlatformException)\s*:?\s*'), '');

  // Progress ticks repaint at most 5 times a second; structural changes repaint and save.
  void _progressChanged() {
    _notifyTimer ??= Timer(const Duration(milliseconds: 200), () {
      _notifyTimer = null;
      notifyListeners();
    });
  }

  void _changed() {
    notifyListeners();
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 400), _save);
  }

  Future<void> _save() async {
    final tmp = File('${_stateFile.path}.tmp');
    await tmp.writeAsString(jsonEncode({'concurrency': concurrency, 'galleryFolder': galleryFolder, 'jobs': jobs.map((j) => j.toJson()).toList()}));
    await tmp.rename(_stateFile.path);
  }
}
