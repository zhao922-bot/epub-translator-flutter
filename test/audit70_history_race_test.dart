import 'package:flutter/foundation.dart';
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:epub_translator_flutter/features/translation/application/translation_dashboard_controller.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/inspection_result.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_job.dart';
import 'package:epub_translator_flutter/features/translation/domain/repositories/translation_repository.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/job_history_store.dart';

class _History extends JobHistoryStore {
  final loaded = Completer<({List<TranslationJob> jobs, int clearedAt})>();
  List<TranslationJob> disk = [];
  int tombstone = 0;
  @override
  Future<({List<TranslationJob> jobs, int clearedAt})> loadWithTombstone() =>
      loaded.future;
  @override
  Future<({bool written, int fileClearedAt})> saveMerged({
    required List<TranslationJob> Function(List<TranslationJob>, int) merge,
    required int clearedAtEpochMs,
  }) async {
    if (clearedAtEpochMs < tombstone) {
      return (written: false, fileClearedAt: tombstone);
    }
    disk = merge(disk, tombstone);
    tombstone = clearedAtEpochMs;
    return (written: true, fileClearedAt: tombstone);
  }
}

class _Repository implements TranslationRepository {
  int calls = 0;
  final enteredSecond = Completer<void>();
  final finishSecond = Completer<void>();
  @override
  Future<InspectionResult> startJob({
    required String inputPath,
    required String outputDirectory,
    required TranslationConfig config,
    TranslationProgressCallback? onProgress,
    TranslationCancellationCheck? isCancelled,
  }) async {
    calls++;
    if (calls == 2) {
      enteredSecond.complete();
      await finishSecond.future;
    }
    final job = TranslationJob(
      id: '${DateTime.now().millisecondsSinceEpoch}-$calls',
      inputPath: inputPath,
      outputPath: outputDirectory,
      status: TranslationJobStatus.inspected,
      phase: TranslationJobPhase.inspection,
      progress: 1,
    );
    onProgress?.call(job, 'Inspection complete.');
    return InspectionResult(job: job, chapters: const []);
  }

  @override
  Future<void> cancelJob(String jobId) async {}
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected repository call');
}

void main() {
  test(
    'clear rejects a run started while initial history loading is pending',
    () async {
      final history = _History();
      final repository = _Repository();
      final controller = TranslationDashboardController(
        repository: repository,
        historyStore: history,
      );
      controller.setOutputDirectory('C:/audit-output');
      controller.setInputPath('C:/first.epub');
      await controller.startInspection(generateStyle: false);
      expect(controller.state.jobHistory, isNotEmpty);
      final clearing = controller.clearJobHistory();
      controller.setInputPath('C:/second.epub');
      final inspecting = controller.startInspection(generateStyle: false);
      await repository.enteredSecond.future;
      expect(controller.state.isRunActive, isTrue);
      history.loaded.complete((jobs: const <TranslationJob>[], clearedAt: 0));
      final cleared = await clearing;
      final activeAtClear = controller.state.isRunActive;
      final historyAtClear = controller.state.jobHistory.length;
      repository.finishSecond.complete();
      await inspecting;
      await controller.debugPersistJobHistoryNow();
      final historyAfterCompletion = controller.state.jobHistory.length;
      await controller.debugDispose();
      debugPrint(
        'AUDIT clear=$cleared active=$activeAtClear historyAtClear=$historyAtClear historyAfterCompletion=$historyAfterCompletion disk=${history.disk.length}',
      );
      expect(
        cleared,
        isFalse,
        reason:
            'An active run must still block a clear after the initial-load await',
      );
    },
  );
}
