// Metadata probing and transcoding with ffmpeg-kit. Everything streams from storage to storage,
// so a 10 GB file costs no more RAM than a small one.
import 'dart:async';
import 'dart:io';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit_config.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'resolution.dart';

class Canceled implements Exception {
  @override
  String toString() => 'Canceled';
}

/// [input] is a file path, a content:// URI (from the picker) or an http(s) URL.
Future<String> ffmpegInput(String input) async {
  if (input.startsWith('content://')) return (await FFmpegKitConfig.getSafParameterForRead(input))!;
  return input;
}

Future<VideoMeta> probe(String input, {String? title, int? knownSize}) async {
  final session = await FFprobeKit.getMediaInformation(await ffmpegInput(input));
  final info = session.getMediaInformation();
  if (info == null) throw Exception('Could not read this video');
  final streams = info.getStreams();
  final v = streams.where((s) => s.getType() == 'video').firstOrNull;
  if (v == null) throw Exception('No video stream found');
  final hasAudio = streams.any((s) => s.getType() == 'audio');
  var w = v.getWidth() ?? 0, h = v.getHeight() ?? 0;
  // Phones record portrait as landscape plus a rotation flag.
  final props = v.getAllProperties() ?? {};
  final rotate = int.tryParse('${(v.getTags() ?? {})['rotate'] ?? ''}') ??
      ((props['side_data_list'] as List?)?.map((d) => (d as Map)['rotation']).whereType<num>().firstOrNull?.toInt() ?? 0);
  if (rotate.abs() == 90 || rotate.abs() == 270) {
    final t = w;
    w = h;
    h = t;
  }
  int size = knownSize ?? 0;
  if (size == 0 && !input.contains('://')) size = await File(input).length();
  if (size == 0) size = int.tryParse(info.getSize() ?? '') ?? 0;
  return VideoMeta(
    title: title ?? input.split('/').last.replaceAll(RegExp(r'\.[^.]+$'), ''),
    width: w,
    height: h,
    duration: double.tryParse(info.getDuration() ?? '') ?? 0,
    size: size,
    videoBitrate: int.tryParse(v.getBitrate() ?? '') ?? 0,
    hasAudio: hasAudio,
  );
}

/// Normalizes yt-dlp `-J` output to [VideoMeta]; the best format tells us the true source size.
VideoMeta metaFromYtdlp(Map<String, dynamic> d) {
  final formats = ((d['formats'] as List?) ?? [])
      .map((f) => Map<String, dynamic>.from(f as Map))
      .where((f) => f['vcodec'] != null && f['vcodec'] != 'none' && f['height'] != null)
      .toList()
    ..sort((a, b) => ((b['height'] as num) * ((b['width'] as num?) ?? 1)).compareTo((a['height'] as num) * ((a['width'] as num?) ?? 1)));
  final best = formats.isNotEmpty ? formats.first : <String, dynamic>{};
  num? n(dynamic x) => x is num ? x : null;
  final size = n(d['filesize']) ?? n(d['filesize_approx']) ?? n(best['filesize']) ?? n(best['filesize_approx']) ?? 0;
  final vbr = n(best['vbr']) ?? n(d['vbr']) ?? 0;
  return VideoMeta(
    title: (d['title'] ?? d['id'] ?? 'video').toString(),
    width: (n(d['width']) ?? n(best['width']) ?? 0).toInt(),
    height: (n(d['height']) ?? n(best['height']) ?? 0).toInt(),
    duration: (n(d['duration']) ?? 0).toDouble(),
    size: size.toInt(),
    videoBitrate: (vbr * 1000).toInt(),
    hasAudio: d['acodec'] == null || d['acodec'] != 'none',
    sizeIsEstimate: d['filesize'] == null,
    extractor: (d['extractor_key'] ?? d['extractor'])?.toString(),
  );
}

class Transcode {
  int? _sessionId;
  bool _canceled = false;

  Future<void> cancel() async {
    _canceled = true;
    if (_sessionId != null) await FFmpegKit.cancel(_sessionId);
  }

  /// Scales and compresses to H.264/AAC MP4. Writes `name.part.mp4` and renames only on success.
  Future<int> run({
    required String video,
    String? audio,
    required String output,
    required VideoMeta meta,
    required String targetId,
    required void Function(double fraction) onProgress,
  }) async {
    final target = targetById(targetId);
    final dims = outputDimensions(meta, targetId);
    final scale = dims.width != null ? 'scale=${dims.width}:${dims.height}:flags=lanczos' : 'scale=-2:${dims.height}:flags=lanczos';
    final part = output.replaceAll(RegExp(r'\.mp4$'), '.part.mp4');
    final args = <String>[
      '-y', '-hide_banner',
      '-i', await ffmpegInput(video),
      if (audio != null) ...['-i', audio],
      '-map', '0:v:0',
      '-map', audio != null ? '1:a:0?' : '0:a:0?',
      '-vf', '$scale,format=yuv420p',
      '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '23',
      '-maxrate', '${(target.videoKbps * 1.5).round()}k', '-bufsize', '${target.videoKbps * 3}k',
      '-c:a', 'aac', '-b:a', '${audioKbps}k', '-ac', '2',
      '-movflags', '+faststart',
      part,
    ];

    final done = Completer<void>();
    final session = await FFmpegKit.executeWithArgumentsAsync(
      args,
      (s) async {
        final rc = await s.getReturnCode();
        if (ReturnCode.isSuccess(rc)) {
          done.complete();
        } else if (ReturnCode.isCancel(rc) || _canceled) {
          done.completeError(Canceled());
        } else {
          final logs = await s.getAllLogsAsString() ?? '';
          final err = logs.trim().split('\n').reversed.firstWhere((l) => l.toLowerCase().contains('error'), orElse: () => 'ffmpeg failed');
          done.completeError(Exception(err.trim()));
        }
      },
      null,
      (stats) {
        if (meta.duration > 0) onProgress((stats.getTime() / 1000 / meta.duration).clamp(0, 1).toDouble());
      },
    );
    _sessionId = session.getSessionId();
    if (_canceled) await FFmpegKit.cancel(_sessionId);

    try {
      await done.future;
    } catch (_) {
      final f = File(part);
      if (await f.exists()) await f.delete();
      rethrow;
    }
    final out = await File(part).rename(output);
    return out.length();
  }
}
