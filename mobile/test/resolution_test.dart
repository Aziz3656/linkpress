import 'package:flutter_test/flutter_test.dart';
import 'package:linkpress/core/resolution.dart';

void main() {
  const src1080 = VideoMeta(title: 'a', width: 1920, height: 1080, duration: 600, size: 600 * 1000000);

  test('downscale shrinks the estimate', () {
    final r = analyze(src1080, '480p');
    expect(r.mode, ScaleMode.downscale);
    expect(r.estimatedBytes! < src1080.size, isTrue);
    expect(r.deltaPct! < 0, isTrue);
  });

  test('upscale is flagged and grows the file', () {
    final r = analyze(const VideoMeta(title: 'b', width: 854, height: 480, duration: 60, size: 9000000), '1080p');
    expect(r.mode, ScaleMode.upscale);
    expect(r.deltaBytes! > 0, isTrue);
  });

  test('portrait uses the short side', () {
    const p = VideoMeta(title: 'c', width: 1080, height: 1920, duration: 10, size: 10000000);
    expect(analyze(p, '720p').mode, ScaleMode.downscale);
    final d = outputDimensions(p, '720p');
    expect(d.width, 720);
    expect(d.height, 1280);
  });

  test('unknown metadata', () {
    expect(analyze(const VideoMeta(title: 'd'), '720p').mode, ScaleMode.unknown);
  });

  test('matches the desktop estimate', () {
    // Same input as desktop test: 1080p, 600s, 8 Mbps total -> 480p.
    final r = analyze(const VideoMeta(title: 'e', width: 1920, height: 1080, duration: 600, size: 600000000), '480p');
    expect(r.estimatedBytes, 114600000);
  });
}
