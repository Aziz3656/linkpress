import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linkpress/core/queue.dart';
import 'package:linkpress/core/resolution.dart';
import 'package:linkpress/ui/home_screen.dart';
import 'package:linkpress/ui/theme.dart';

Job job(String title, int w, int h, int size, String target, {JobStatus status = JobStatus.ready, double progress = 0, int? out}) =>
    Job(id: title, isUrl: false, input: 'content://$title', title: title, targetId: target)
      ..meta = VideoMeta(title: title, width: w, height: h, duration: 300, size: size)
      ..status = status
      ..progress = progress
      ..outputBytes = out;

JobQueue sampleQueue() => JobQueue()
  ..jobs.addAll([
    job('Concert 4K', 3840, 2160, 2400000000, '720p', status: JobStatus.transcoding, progress: 0.42),
    job('Old phone clip', 640, 360, 30000000, '720p'),
    job('Interview', 1920, 1080, 450000000, '720p', status: JobStatus.done, progress: 1, out: 98000000),
  ]);

Future<void> pumpHome(WidgetTester tester, JobQueue q) async {
  const channel = MethodChannel('linkpress/native');
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (_) async => null);
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 2.625;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(theme: buildTheme(), home: HomeScreen(queue: q)));
  await tester.pump();
}

void main() {
  testWidgets('shows the upscale warning and size estimates', (tester) async {
    await pumpHome(tester, sampleQueue());
    expect(find.textContaining('Upscaling increases file size'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('UPSCALE'), 300, scrollable: find.byType(Scrollable).first);
    expect(find.text('UPSCALE'), findsOneWidget);
    expect(find.textContaining('Saves ~'), findsWidgets);
  });

  testWidgets('empty queue shows guidance and disables Start', (tester) async {
    await pumpHome(tester, JobQueue());
    await tester.scrollUntilVisible(find.textContaining('share one from another app'), 300, scrollable: find.byType(Scrollable).first);
    expect(find.textContaining('share one from another app'), findsOneWidget);
    final start = tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Start'));
    expect(start.onPressed, isNull);
  });
}

