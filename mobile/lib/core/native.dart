// Thin wrapper over the Kotlin side (android/app/src/main/kotlin/.../MainActivity.kt):
// yt-dlp (youtubedl-android), the system file picker, MediaStore export and the keep-alive service.
import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';

class PickedVideo {
  final String uri;
  final String name;
  final int size;
  PickedVideo(this.uri, this.name, this.size);
}

PickedVideo _picked(dynamic e) {
  final m = Map<String, dynamic>.from(e as Map);
  return PickedVideo(m['uri'] as String, m['name'] as String? ?? 'video', (m['size'] as num?)?.toInt() ?? 0);
}

class SharedItems {
  final String? text;
  final List<PickedVideo> files;
  SharedItems(this.text, this.files);
  factory SharedItems.fromMap(Map<dynamic, dynamic> m) => SharedItems(m['text'] as String?, ((m['files'] as List?) ?? []).map(_picked).toList());
}

class DownloadProgress {
  final String jobId;
  final double fraction;
  final int eta;
  DownloadProgress(this.jobId, this.fraction, this.eta);
}

class Native {
  static const _ch = MethodChannel('linkpress/native');
  static const _progress = EventChannel('linkpress/progress');

  static final _shared = StreamController<SharedItems>.broadcast();
  /// Links or videos shared into the app while it is open.
  static Stream<SharedItems> get shared => _shared.stream;

  static Stream<DownloadProgress>? _progressStream;
  static Stream<DownloadProgress> get downloadProgress => _progressStream ??= _progress
      .receiveBroadcastStream()
      .map((e) => Map<String, dynamic>.from(e as Map))
      .map((m) => DownloadProgress(m['jobId'] as String, ((m['progress'] as num?) ?? 0) / 100.0, (m['eta'] as num?)?.toInt() ?? -1));

  static void listen() {
    _ch.setMethodCallHandler((call) async {
      if (call.method == 'onShared' && call.arguments is Map) _shared.add(SharedItems.fromMap(call.arguments as Map));
    });
  }

  /// What was shared into the app when it was launched by a share, if anything.
  static Future<SharedItems?> initialShare() async {
    final m = await _ch.invokeMethod<Map<dynamic, dynamic>>('initialShare');
    return m == null ? null : SharedItems.fromMap(m);
  }

  static Future<void> initYtdlp() => _ch.invokeMethod('initYtdlp');

  /// Returns yt-dlp's `-J --flat-playlist` JSON.
  static Future<Map<String, dynamic>> ytdlpInfo(String url) async {
    final out = await _ch.invokeMethod<String>('ytdlpInfo', {'url': url});
    return jsonDecode(out!) as Map<String, dynamic>;
  }

  /// Downloads one format selection into [dir] and returns the file path.
  static Future<String> ytdlpDownload({required String jobId, required String url, required String format, required String dir}) async {
    final path = await _ch.invokeMethod<String>('ytdlpDownload', {'jobId': jobId, 'url': url, 'format': format, 'dir': dir});
    return path!;
  }

  static Future<void> ytdlpCancel(String jobId) => _ch.invokeMethod('ytdlpCancel', {'jobId': jobId});

  static Future<String?> ytdlpUpdate() => _ch.invokeMethod<String>('ytdlpUpdate');

  static Future<List<PickedVideo>> pickVideos() async {
    final list = await _ch.invokeMethod<List<dynamic>>('pickVideos') ?? [];
    return list.map(_picked).toList();
  }

  /// Copies a finished file into the public Movies/ or Download/ folder so the Samsung Gallery
  /// picks it up immediately. Returns the content:// URI.
  static Future<String> saveToGallery({required String path, required String name, required String folder}) async {
    final uri = await _ch.invokeMethod<String>('saveToGallery', {'path': path, 'name': name, 'folder': folder});
    return uri!;
  }

  static Future<void> openVideo(String uri) => _ch.invokeMethod('openVideo', {'uri': uri});

  static Future<int> freeBytes(String path) async => (await _ch.invokeMethod<num>('freeBytes', {'path': path}))?.toInt() ?? 0;

  /// Foreground service + notification, so Android doesn't kill a long batch when the screen is off.
  static Future<void> keepAlive(String text) => _ch.invokeMethod('keepAlive', {'text': text});
  static Future<void> stopKeepAlive() => _ch.invokeMethod('stopKeepAlive');
}
