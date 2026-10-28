import 'package:flutter/material.dart';
import '../core/native.dart';
import '../core/queue.dart';
import '../core/resolution.dart';
import 'theme.dart';

/// Bento card with the faint block number (01, 02, …) in the corner.
class BentoCard extends StatelessWidget {
  final String number;
  final String title;
  final String? subtitle;
  final Widget child;
  final bool compact;
  const BentoCard({super.key, required this.number, required this.title, this.subtitle, required this.child, this.compact = false});

  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(color: C.card, borderRadius: BorderRadius.circular(16), border: Border.all(color: C.border)),
        padding: EdgeInsets.all(compact ? 16 : 20),
        child: Stack(children: [
          Positioned(
            top: -4,
            right: 0,
            child: Text(number, style: TextStyle(fontSize: 26, fontWeight: FontWeight.w700, color: C.gray.withValues(alpha: 0.15))),
          ),
          Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Padding(
              padding: const EdgeInsets.only(right: 40),
              child: Text(title, style: TextStyle(color: C.white, fontSize: compact ? 15 : 18, fontWeight: FontWeight.w600, letterSpacing: -0.4)),
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 4),
              Text(subtitle!, style: const TextStyle(fontSize: 13)),
            ],
            SizedBox(height: compact ? 8 : 14),
            child,
          ]),
        ]),
      );
}

class Metric extends StatelessWidget {
  final String text;
  final bool danger;
  const Metric(this.text, {super.key, this.danger = false});

  @override
  Widget build(BuildContext context) => FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: Text(text,
            style: TextStyle(color: danger ? C.red : C.green, fontSize: 32, fontWeight: FontWeight.w600, height: 1.1, fontFeatures: const [FontFeature.tabularFigures()])),
      );
}

class ProgressBar extends StatelessWidget {
  final double value;
  final Color color;
  const ProgressBar(this.value, {super.key, this.color = C.green});

  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(3),
        child: LinearProgressIndicator(value: value.clamp(0, 1), minHeight: 6, backgroundColor: C.bg, valueColor: AlwaysStoppedAnimation(color)),
      );
}

class AlertBox extends StatelessWidget {
  final String text;
  const AlertBox(this.text, {super.key});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(color: C.red.withValues(alpha: 0.1), border: Border.all(color: C.red), borderRadius: BorderRadius.circular(8)),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Icon(Icons.warning_amber_rounded, color: C.red, size: 18),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: const TextStyle(color: C.red, fontSize: 13, fontWeight: FontWeight.w500))),
        ]),
      );
}

class OkBox extends StatelessWidget {
  final String text;
  const OkBox(this.text, {super.key});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(color: C.green.withValues(alpha: 0.08), border: Border.all(color: C.green.withValues(alpha: 0.4)), borderRadius: BorderRadius.circular(8)),
        child: Text(text, style: const TextStyle(color: C.green, fontSize: 13, fontWeight: FontWeight.w500)),
      );
}

class Segmented extends StatelessWidget {
  final List<String> options;
  final List<String>? labels;
  final String value;
  final ValueChanged<String> onChanged;
  final bool dense;
  const Segmented({super.key, required this.options, this.labels, required this.value, required this.onChanged, this.dense = false});

  @override
  Widget build(BuildContext context) {
    final items = [
      for (var i = 0; i < options.length; i++)
        _segment(options[i], labels?[i] ?? options[i]),
    ];
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(color: C.bg, borderRadius: BorderRadius.circular(10), border: Border.all(color: C.border)),
      child: Row(mainAxisSize: dense ? MainAxisSize.min : MainAxisSize.max, children: dense ? items : items.map((w) => Expanded(child: w)).toList()),
    );
  }

  Widget _segment(String option, String label) {
    final selected = option == value;
    return Semantics(
      selected: selected,
      button: true,
      child: InkWell(
        borderRadius: BorderRadius.circular(7),
        onTap: () => onChanged(option),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          constraints: BoxConstraints(minHeight: dense ? 36 : 44, minWidth: dense ? 40 : 0),
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          decoration: BoxDecoration(color: selected ? C.green : Colors.transparent, borderRadius: BorderRadius.circular(7)),
          child: Text(label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: selected ? Colors.black : C.gray, fontWeight: FontWeight.w600, fontSize: 13)),
        ),
      ),
    );
  }
}

class ResolutionPicker extends StatelessWidget {
  final String value;
  final ValueChanged<String> onChanged;
  const ResolutionPicker({super.key, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) => Segmented(options: targets.map((t) => t.id).toList(), value: value, onChanged: onChanged);
}

class EmptyQueue extends StatelessWidget {
  const EmptyQueue({super.key});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 16),
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), border: Border.all(color: C.border)),
        child: const Text('Paste a link, share one from another app, or import videos.', textAlign: TextAlign.center),
      );
}

const _statusLabel = {
  JobStatus.queued: 'Waiting for metadata',
  JobStatus.probing: 'Reading metadata…',
  JobStatus.ready: 'Ready',
  JobStatus.downloading: 'Downloading',
  JobStatus.transcoding: 'Compressing',
  JobStatus.saving: 'Saving to Gallery',
  JobStatus.done: 'Saved to Gallery',
  JobStatus.error: 'Failed',
  JobStatus.canceled: 'Canceled',
};

/// One queue item: title, source → target, size estimate, progress and actions.
class JobTile extends StatelessWidget {
  final Job job;
  final JobQueue queue;
  const JobTile({super.key, required this.job, required this.queue});

  @override
  Widget build(BuildContext context) {
    final m = job.meta;
    final a = job.analysis;
    final borderColor = job.status == JobStatus.error
        ? C.red.withValues(alpha: 0.5)
        : job.status == JobStatus.done
            ? C.green.withValues(alpha: 0.3)
            : C.border;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: C.card, borderRadius: BorderRadius.circular(12), border: Border.all(color: borderColor)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(job.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: C.white, fontWeight: FontWeight.w500, fontSize: 15)),
              Text(job.isUrl ? '${m?.extractor != null ? '${m!.extractor} · ' : ''}${job.input}' : 'From phone',
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
            ]),
          ),
          ..._actions(),
        ]),
        const SizedBox(height: 10),
        Row(children: [
          Text(m != null && m.shortSide > 0 ? '${m.shortSide}p' : '…', style: const TextStyle(color: C.white)),
          const Padding(padding: EdgeInsets.symmetric(horizontal: 6), child: Icon(Icons.arrow_forward_rounded, size: 14, color: C.gray)),
          _targetMenu(context),
          const SizedBox(width: 8),
          if (a?.mode == ScaleMode.upscale) const _Chip('UPSCALE', C.red),
          if (a?.mode == ScaleMode.downscale) const _Chip('DOWN', C.green),
          if (a?.mode == ScaleMode.same) const _Chip('SAME', C.mint),
        ]),
        const SizedBox(height: 8),
        _size(m, a),
        const SizedBox(height: 10),
        ProgressBar(job.progress, color: job.status == JobStatus.downloading ? C.mint : C.green),
        const SizedBox(height: 6),
        Text(_statusText(),
            maxLines: job.status == JobStatus.error ? 3 : 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: job.status == JobStatus.error ? C.red : job.status == JobStatus.done ? C.green : C.gray)),
      ]),
    );
  }

  String _statusText() {
    if (job.status == JobStatus.error) return job.error ?? 'Failed';
    final label = _statusLabel[job.status]!;
    if (job.status == JobStatus.downloading || job.status == JobStatus.transcoding) return '$label ${(job.progress * 100).round()}%';
    return label;
  }

  Widget _size(VideoMeta? m, Analysis? a) {
    String line;
    Widget? delta;
    if (job.status == JobStatus.done && job.outputBytes != null) {
      line = '${formatBytes(m?.size)} → ${formatBytes(job.outputBytes)}';
      if (m != null && m.size > 0) delta = _delta(job.outputBytes! - m.size, m.size, false);
    } else if (m != null && a?.estimatedBytes != null) {
      line = '${m.size > 0 ? '${m.sizeIsEstimate ? '~' : ''}${formatBytes(m.size)}' : '?'} → ~${formatBytes(a!.estimatedBytes)}';
      if (a.deltaBytes != null) delta = _delta(a.deltaBytes!, m.size, true);
    } else {
      line = m != null && m.size > 0 ? formatBytes(m.size) : '';
    }
    return Row(children: [
      Expanded(child: Text(line, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: C.white, fontSize: 13))),
      ?delta,
    ]);
  }

  Widget _delta(int delta, int src, bool estimate) {
    final pct = (delta / src * 100).round();
    final down = delta <= 0;
    final text = down ? '${estimate ? 'Saves ~' : 'Saved '}${formatBytes(-delta)} ($pct%)' : '${estimate ? 'Grows ~' : 'Grew '}${formatBytes(delta)} (+$pct%)';
    return Text(text, style: TextStyle(color: down ? C.green : C.red, fontSize: 13, fontWeight: FontWeight.w600));
  }

  Widget _targetMenu(BuildContext context) {
    final locked = job.isActive || job.status == JobStatus.done;
    return PopupMenuButton<String>(
      enabled: !locked,
      color: C.raised,
      initialValue: job.targetId,
      onSelected: (v) => queue.setTarget(job, v),
      itemBuilder: (_) => [for (final t in targets) PopupMenuItem(value: t.id, child: Text(t.id, style: const TextStyle(color: C.white)))],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(color: C.bg, borderRadius: BorderRadius.circular(6), border: Border.all(color: C.border)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text(job.targetId, style: const TextStyle(color: C.white, fontSize: 13)),
          if (!locked) const Icon(Icons.expand_more_rounded, size: 16, color: C.gray),
        ]),
      ),
    );
  }

  List<Widget> _actions() {
    Widget btn(IconData icon, String tip, VoidCallback onTap, {bool danger = false}) => IconButton(
          tooltip: tip,
          onPressed: onTap,
          icon: Icon(icon, size: 20, color: danger ? C.red : C.gray),
          visualDensity: VisualDensity.compact,
        );
    final s = job.status;
    return [
      if (s == JobStatus.done && job.outputUri != null) btn(Icons.play_circle_outline_rounded, 'Open', () => Native.openVideo(job.outputUri!)),
      if (s == JobStatus.error || s == JobStatus.canceled) btn(Icons.refresh_rounded, 'Retry', () => queue.retry(job)),
      if (job.isActive || s == JobStatus.ready || s == JobStatus.queued) btn(Icons.stop_rounded, 'Cancel', () => queue.cancel(job), danger: true),
      if (!job.isActive) btn(Icons.close_rounded, 'Remove', () => queue.remove(job)),
    ];
  }
}

class _Chip extends StatelessWidget {
  final String text;
  final Color color;
  const _Chip(this.text, this.color);

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(99), border: Border.all(color: color.withValues(alpha: 0.6))),
        child: Text(text, style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 0.3)),
      );
}
