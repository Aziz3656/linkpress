// Vertical bento layout for phones: link input, target picker, metrics, export folder, queue.
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../core/native.dart';
import '../core/queue.dart';
import '../core/resolution.dart';
import 'theme.dart';
import 'widgets.dart';

class HomeScreen extends StatefulWidget {
  final JobQueue queue;
  const HomeScreen({super.key, required this.queue});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _links = TextEditingController();
  String _target = '720p';
  StreamSubscription<SharedItems>? _shareSub;

  JobQueue get q => widget.queue;

  @override
  void initState() {
    super.initState();
    Native.initialShare().then((s) => s != null ? _onShared(s) : null);
    _shareSub = Native.shared.listen(_onShared);
  }

  @override
  void dispose() {
    _shareSub?.cancel();
    _links.dispose();
    super.dispose();
  }

  void _onShared(SharedItems s) {
    var added = 0;
    if (s.text != null) added += q.addUrls([s.text!], _target);
    if (s.files.isNotEmpty) {
      q.addPicked(s.files, _target);
      added += s.files.length;
    }
    _toast(added > 0 ? 'Added $added item${added == 1 ? '' : 's'} from share' : 'No link found in the shared text');
  }

  void _toast(String msg) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating));

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (text.isEmpty) return _toast('Clipboard is empty');
    _links.text = _links.text.trim().isEmpty ? text : '${_links.text.trim()}\n$text';
  }

  void _addLinks() {
    final n = q.addUrls([_links.text], _target);
    if (n == 0) return _toast('Paste at least one link starting with http:// or https://');
    _links.clear();
    FocusScope.of(context).unfocus();
  }

  Future<void> _import() async {
    final files = await Native.pickVideos();
    if (files.isNotEmpty) q.addPicked(files, _target);
  }

  void _setTarget(String id) {
    setState(() => _target = id);
    // Items that haven't started yet follow the picker, like on desktop.
    q.setTargetForWaiting(id);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: ListenableBuilder(
          listenable: q,
          builder: (context, _) {
            final jobs = q.jobs;
            return CustomScrollView(
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                  sliver: SliverList.list(children: [
                    _header(),
                    const SizedBox(height: 16),
                    _linkCard(),
                    const SizedBox(height: 12),
                    _targetCard(jobs),
                    const SizedBox(height: 12),
                    _metrics(jobs),
                    const SizedBox(height: 12),
                    _exportCard(),
                    const SizedBox(height: 20),
                    _queueHeader(jobs),
                    const SizedBox(height: 10),
                    if (jobs.isEmpty) const EmptyQueue(),
                  ]),
                ),
                // Lazily built, so 100+ items scroll smoothly.
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
                  sliver: SliverList.separated(
                    itemCount: jobs.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, i) => JobTile(key: ValueKey(jobs[i].id), job: jobs[i], queue: q),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _header() => Row(children: [
        Container(width: 10, height: 10, decoration: const BoxDecoration(color: C.green, shape: BoxShape.circle, boxShadow: [BoxShadow(color: C.green, blurRadius: 8)])),
        const SizedBox(width: 10),
        const Expanded(child: Text('LinkPress', style: TextStyle(color: C.white, fontSize: 24, fontWeight: FontWeight.w600, letterSpacing: -0.5))),
        const Text('Download · Compress · Save', style: TextStyle(color: C.mint, fontSize: 12)),
      ]);

  Widget _linkCard() => BentoCard(
        number: '01',
        title: 'Paste links',
        subtitle: 'One per line, or tap Share → LinkPress in any app.',
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          TextField(
            controller: _links,
            minLines: 2,
            maxLines: 5,
            keyboardType: TextInputType.url,
            style: const TextStyle(color: C.white, fontSize: 14),
            decoration: const InputDecoration(hintText: 'https://…'),
          ),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: FilledButton(onPressed: _addLinks, child: const Text('Add to queue'))),
            const SizedBox(width: 8),
            OutlinedButton(onPressed: _paste, child: const Icon(Icons.content_paste_rounded, size: 20)),
          ]),
          const SizedBox(height: 8),
          OutlinedButton.icon(onPressed: _import, icon: const Icon(Icons.video_library_outlined, size: 20), label: const Text('Import videos from phone')),
        ]),
      );

  Widget _targetCard(List<Job> jobs) {
    final pending = jobs.where((j) => j.meta != null && !j.isFinished && j.status != JobStatus.error);
    final upscale = pending.where((j) => j.analysis?.mode == ScaleMode.upscale).length;
    return BentoCard(
      number: '02',
      title: 'Target resolution',
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        ResolutionPicker(value: _target, onChanged: _setTarget),
        if (upscale > 0) ...[
          const SizedBox(height: 12),
          AlertBox('$upscale video${upscale == 1 ? ' is' : 's are'} below $_target. Upscaling increases file size without improving native detail.'),
        ] else if (pending.isNotEmpty) ...[
          const SizedBox(height: 12),
          const OkBox('No video is being upscaled, so every file gets smaller or stays the same.'),
        ],
      ]),
    );
  }

  Widget _metrics(List<Job> jobs) {
    var src = 0, out = 0;
    for (final j in jobs) {
      final m = j.meta;
      if (j.status == JobStatus.canceled || m == null || m.size == 0) continue;
      if (j.status == JobStatus.done && j.outputBytes != null) {
        src += m.size;
        out += j.outputBytes!;
      } else if (j.analysis?.estimatedBytes != null) {
        src += m.size;
        out += j.analysis!.estimatedBytes!;
      }
    }
    final counted = jobs.where((j) => j.status != JobStatus.canceled).toList();
    final done = counted.where((j) => j.status == JobStatus.done).length;
    final sum = counted.fold<double>(0, (s, j) => s + (j.status == JobStatus.done ? 1 : j.isActive ? j.progress : 0));
    final diff = src - out;
    return IntrinsicHeight(
      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Expanded(
          child: BentoCard(
            number: '03',
            title: 'Savings',
            compact: true,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Metric(src == 0 ? '—' : '${diff < 0 ? '+' : ''}${formatBytes(diff.abs())}', danger: diff < 0),
              const SizedBox(height: 4),
              Text(src == 0 ? 'Add videos' : '${(diff / src * 100).round()}% ${diff >= 0 ? 'smaller' : 'larger'}', style: const TextStyle(fontSize: 12)),
            ]),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: BentoCard(
            number: '04',
            title: 'Progress',
            compact: true,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Metric('$done / ${counted.length}'),
              const SizedBox(height: 10),
              ProgressBar(counted.isEmpty ? 0 : sum / counted.length),
            ]),
          ),
        ),
      ]),
    );
  }

  Widget _exportCard() => BentoCard(
        number: '05',
        title: 'Save to',
        subtitle: 'Finished videos appear in the Samsung Gallery right away.',
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Segmented(
            options: const ['Movies', 'Download'],
            labels: const ['Movies/LinkPress', 'Download/LinkPress'],
            value: q.galleryFolder,
            onChanged: q.setGalleryFolder,
          ),
          const SizedBox(height: 12),
          Row(children: [
            const Expanded(child: Text('Videos at the same time', style: TextStyle(fontSize: 13))),
            Segmented(options: const ['1', '2', '3'], value: '${q.concurrency}', onChanged: (v) => q.setConcurrency(int.parse(v)), dense: true),
          ]),
        ]),
      );

  Widget _queueHeader(List<Job> jobs) => Row(children: [
        const Text('Queue', style: TextStyle(color: C.white, fontSize: 20, fontWeight: FontWeight.w600)),
        const SizedBox(width: 8),
        Text('${jobs.length}', style: const TextStyle(color: C.mint)),
        const Spacer(),
        if (jobs.any((j) => j.isFinished))
          IconButton(tooltip: 'Clear finished', onPressed: q.clearFinished, icon: const Icon(Icons.playlist_remove_rounded, color: C.gray)),
        const SizedBox(width: 4),
        q.running
            ? OutlinedButton(
                style: OutlinedButton.styleFrom(foregroundColor: C.green, side: const BorderSide(color: C.green), minimumSize: const Size(96, 40)),
                onPressed: q.pause,
                child: const Text('Pause'))
            : FilledButton(style: FilledButton.styleFrom(minimumSize: const Size(96, 40)), onPressed: jobs.isEmpty ? null : q.start, child: const Text('Start')),
      ]);
}
