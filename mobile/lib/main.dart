import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'core/native.dart';
import 'core/queue.dart';
import 'ui/home_screen.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: C.bg,
    systemNavigationBarColor: C.bg,
    statusBarIconBrightness: Brightness.light,
  ));
  Native.listen();
  final queue = JobQueue();
  await queue.init();
  // Unpack yt-dlp in the background so the first pasted link is fast.
  Native.initYtdlp().ignore();
  runApp(LinkPressApp(queue: queue));
}

class LinkPressApp extends StatelessWidget {
  final JobQueue queue;
  const LinkPressApp({super.key, required this.queue});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'LinkPress',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(),
        home: HomeScreen(queue: queue),
      );
}
