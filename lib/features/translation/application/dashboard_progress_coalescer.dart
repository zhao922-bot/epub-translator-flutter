import 'dart:async';

import '../domain/models/translation_job.dart';

/// Signature for applying a coalesced batch of progress and log updates.
typedef CoalescedProgressCommit =
    void Function(TranslationJob job, List<String> logs, bool isTranslationRun);

/// Coalesces rapid in-phase progress/log updates (e.g. high-throughput block
/// completions) within a bounded [coalesceWindow] (~120 ms) while dispatching
/// leading-edge emits and phase/status/milestone transitions immediately.
class DashboardProgressCoalescer {
  DashboardProgressCoalescer({
    required this.onFlush,
    this.coalesceWindow = const Duration(milliseconds: 120),
  });

  final CoalescedProgressCommit onFlush;
  final Duration coalesceWindow;
  final Stopwatch _clock = Stopwatch()..start();

  Duration? _lastFlushElapsed;
  Timer? _timer;
  TranslationJob? _pendingJob;
  final List<String> _pendingLogs = <String>[];
  bool _pendingIsTranslation = false;

  /// Enqueues an incoming progress update.
  ///
  /// [forceImmediate] should be set on phase transitions, terminal states,
  /// completed-file milestones, or when `completedBlocks >= totalBlocks`.
  void enqueue({
    required TranslationJob job,
    required List<String> logLines,
    required bool isTranslationRun,
    required bool forceImmediate,
  }) {
    final Duration now = _clock.elapsed;
    final bool windowElapsed =
        _lastFlushElapsed == null ||
        (now - _lastFlushElapsed!) >= coalesceWindow;

    if (forceImmediate || windowElapsed) {
      if (_pendingJob != null && _pendingIsTranslation == isTranslationRun) {
        _pendingJob = job;
        _pendingLogs.addAll(logLines);
        flush();
        return;
      }
      // Flush any earlier pending updates from a prior stage before switching.
      flush();
      _lastFlushElapsed = now;
      onFlush(job, logLines, isTranslationRun);
      return;
    }

    if (_pendingJob != null && _pendingIsTranslation != isTranslationRun) {
      flush();
    }
    _pendingJob = job;
    _pendingIsTranslation = isTranslationRun;
    _pendingLogs.addAll(logLines);
    _timer ??= Timer(coalesceWindow - (now - _lastFlushElapsed!), flush);
  }

  /// Synchronously flushes any buffered progress/logs through [onFlush].
  void flush() {
    _timer?.cancel();
    _timer = null;
    final TranslationJob? job = _pendingJob;
    if (job == null && _pendingLogs.isEmpty) {
      return;
    }
    final List<String> logs = List<String>.of(_pendingLogs);
    final bool isTranslation = _pendingIsTranslation;
    _pendingJob = null;
    _pendingLogs.clear();
    _lastFlushElapsed = _clock.elapsed;
    if (job != null) {
      onFlush(job, logs, isTranslation);
    }
  }

  /// Drops any pending buffered updates and cancels timers (on cancel/dispose).
  void clear() {
    _timer?.cancel();
    _timer = null;
    _pendingJob = null;
    _pendingLogs.clear();
    _lastFlushElapsed = null;
  }
}
