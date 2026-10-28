// Resolution rules, ported 1:1 from the desktop app (desktop/src/core/resolution.js).
// Pure Dart with no plugins, so it is covered by plain unit tests.
import 'dart:math' as math;

class Target {
  final String id;
  final int height;
  final int videoKbps;
  const Target(this.id, this.height, this.videoKbps);
}

const targets = <Target>[
  Target('1080p', 1080, 5000),
  Target('720p', 720, 2800),
  Target('480p', 480, 1400),
  Target('360p', 360, 800),
  Target('240p', 240, 450),
];

const audioKbps = 128;
// Bitrate does not scale linearly with pixel count; 0.75 tracks H.264 at a fixed CRF well enough.
const _pixelExponent = 0.75;

Target targetById(String id) => targets.firstWhere((t) => t.id == id, orElse: () => throw ArgumentError('Unknown target $id'));

enum ScaleMode { upscale, downscale, same, unknown }

class VideoMeta {
  final String title;
  final int width;
  final int height;
  final double duration; // seconds
  final int size; // bytes, 0 when unknown
  final int videoBitrate; // bits/s, 0 when unknown
  final bool hasAudio;
  final bool sizeIsEstimate;
  final String? extractor;

  const VideoMeta({
    required this.title,
    this.width = 0,
    this.height = 0,
    this.duration = 0,
    this.size = 0,
    this.videoBitrate = 0,
    this.hasAudio = true,
    this.sizeIsEstimate = false,
    this.extractor,
  });

  // "Short side" is what people mean by 720p, so portrait 1080x1920 counts as 1080p.
  int get shortSide => (width > 0 && height > 0) ? math.min(width, height) : 0;

  VideoMeta copyWith({String? title, int? width, int? height, double? duration, int? size}) => VideoMeta(
        title: title ?? this.title,
        width: width ?? this.width,
        height: height ?? this.height,
        duration: duration ?? this.duration,
        size: size ?? this.size,
        videoBitrate: videoBitrate,
        hasAudio: hasAudio,
        sizeIsEstimate: sizeIsEstimate,
        extractor: extractor,
      );

  Map<String, dynamic> toJson() => {
        'title': title,
        'width': width,
        'height': height,
        'duration': duration,
        'size': size,
        'videoBitrate': videoBitrate,
        'hasAudio': hasAudio,
        'sizeIsEstimate': sizeIsEstimate,
        'extractor': extractor,
      };

  factory VideoMeta.fromJson(Map<String, dynamic> j) => VideoMeta(
        title: j['title'] ?? 'video',
        width: (j['width'] ?? 0) as int,
        height: (j['height'] ?? 0) as int,
        duration: ((j['duration'] ?? 0) as num).toDouble(),
        size: (j['size'] ?? 0) as int,
        videoBitrate: (j['videoBitrate'] ?? 0) as int,
        hasAudio: j['hasAudio'] ?? true,
        sizeIsEstimate: j['sizeIsEstimate'] ?? false,
        extractor: j['extractor'],
      );
}

class Dimensions {
  final int? width;
  final int height;
  const Dimensions(this.width, this.height);
}

class Analysis {
  final ScaleMode mode;
  final int? estimatedBytes;
  final int? deltaBytes;
  final int? deltaPct;
  const Analysis(this.mode, this.estimatedBytes, this.deltaBytes, this.deltaPct);
}

int _even(double n) => math.max(2, (n / 2).round() * 2);

// Keeps aspect ratio and orientation; even numbers for yuv420p.
Dimensions outputDimensions(VideoMeta meta, String targetId) {
  final short = targetById(targetId).height;
  final w = meta.width, h = meta.height;
  if (w <= 0 || h <= 0) return Dimensions(null, short);
  if (w >= h) return Dimensions(_even(w * short / h), short);
  return Dimensions(short, _even(h * short / w));
}

double _sourceVideoKbps(VideoMeta m) {
  if (m.videoBitrate > 0) return m.videoBitrate / 1000;
  if (m.size > 0 && m.duration > 0) {
    final total = m.size * 8 / m.duration / 1000;
    return math.max(50, total - (m.hasAudio ? audioKbps : 0));
  }
  return 0;
}

Analysis analyze(VideoMeta meta, String targetId) {
  final target = targetById(targetId);
  final src = meta.shortSide;
  var mode = ScaleMode.unknown;
  if (src > 0) {
    mode = target.height > src
        ? ScaleMode.upscale
        : target.height < src
            ? ScaleMode.downscale
            : ScaleMode.same;
  }

  int? estimated;
  if (meta.duration > 0) {
    final srcKbps = _sourceVideoKbps(meta);
    var kbps = target.videoKbps.toDouble();
    if (srcKbps > 0 && src > 0) {
      final scaled = srcKbps * math.pow(target.height / src, 2 * _pixelExponent);
      // Downscaling never needs more bits than a scaled copy of the source;
      // upscaling invents pixels, so the encoder spends more bits on the same detail.
      kbps = mode == ScaleMode.upscale ? math.max(scaled, srcKbps * 1.05) : math.min(kbps, scaled);
    }
    final a = meta.hasAudio ? audioKbps : 0;
    estimated = ((kbps + a) * 1000 * meta.duration / 8).round();
  }

  int? delta, pct;
  if (estimated != null && meta.size > 0) {
    delta = estimated - meta.size;
    pct = (delta / meta.size * 100).round();
  }
  return Analysis(mode, estimated, delta, pct);
}

String formatBytes(num? bytes) {
  if (bytes == null || !bytes.isFinite) return '—';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var v = bytes.abs().toDouble();
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  final s = v.toStringAsFixed(v >= 100 || i == 0 ? 0 : 1);
  return '${bytes < 0 ? '-' : ''}$s ${units[i]}';
}
