import 'dart:async';

import 'package:epub_translator_flutter/features/translation/domain/models/job_resume_state.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_job.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/translation_progress_persistence.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/translation_cache_store.dart';
import 'package:flutter_test/flutter_test.dart';

class _Store extends TranslationCacheStore {
  final saves = <int>[];
  bool fail = false;
  Completer<void>? hold;
  final firstSaveStarted = Completer<void>();
  int active = 0;
  int peak = 0;

  @override
  Future<void> saveJobState(JobResumeState state) async {
    active++;
    if (active > peak) peak = active;
    try {
      if (!firstSaveStarted.isCompleted) firstSaveStarted.complete();
      await hold?.future;
      if (fail) throw StateError('disk unavailable');
      saves.add(state.completedBlocks);
    } finally {
      active--;
    }
  }

  @override
  Future<void> putBlockTranslation(String key, String html) async {
    if (fail) throw StateError('disk unavailable');
  }
}

TranslationJob _job(int count) => TranslationJob(
  id: 'job',
  inputPath: 'input.epub',
  outputPath: 'output.epub',
  status: TranslationJobStatus.running,
  progress: count / 100,
  completedBlocks: count,
  totalBlocks: 100,
);

JobResumeState _state(TranslationJob job) => JobResumeState(
  jobKey: 'job-key',
  inputFingerprint: 'fingerprint',
  inputPath: job.inputPath,
  outputPath: job.outputPath,
  status: job.status.name,
  completedFiles: 0,
  totalFiles: 1,
  completedBlocks: job.completedBlocks,
  totalBlocks: job.totalBlocks,
  cachedBlocks: 0,
  resumedBlocks: 0,
  currentChapter: 'Chapter',
  updatedAtIso8601: DateTime.now().toIso8601String(),
);

void main() {
  test(
    'concurrent saves are serialized and preserve newer snapshots',
    () async {
      final store = _Store()..hold = Completer<void>();
      final persistence = TranslationProgressPersistence(
        cacheStore: store,
        stateFor: _state,
        onCacheError: (_, _) {},
        onCheckpointError: (_, _) {},
      );
      final first = persistence.save(_job(20), force: true);
      await store.firstSaveStarted.future;
      final second = persistence.save(_job(21), force: true);
      final third = persistence.save(_job(22), force: true);
      await Future<void>.delayed(Duration.zero);
      expect(store.peak, 1);
      store.hold!.complete();
      await Future.wait([first, second, third]);
      expect(store.saves, [20, 21, 22]);
      expect(store.peak, 1);
    },
  );

  test(
    'blocks completed during a save count toward the next checkpoint',
    () async {
      final store = _Store()..hold = Completer<void>();
      final persistence = TranslationProgressPersistence(
        cacheStore: store,
        stateFor: _state,
        onCacheError: (_, _) {},
        onCheckpointError: (_, _) {},
      );
      for (int i = 0; i < 20; i++) {
        persistence.blockCompleted();
      }
      final first = persistence.save(_job(20));
      await store.firstSaveStarted.future;
      for (int i = 0; i < 20; i++) {
        persistence.blockCompleted();
      }
      final second = persistence.save(_job(40));
      store.hold!.complete();
      await Future.wait([first, second]);
      await persistence.save(_job(40));
      expect(store.saves, [20, 40]);
    },
  );

  test(
    'cache and checkpoint failures stay best-effort and recover later',
    () async {
      final store = _Store()..fail = true;
      final cacheFailures = <bool>[];
      final checkpointFailures = <bool>[];
      final persistence = TranslationProgressPersistence(
        cacheStore: store,
        stateFor: _state,
        onCacheError: (_, first) => cacheFailures.add(first),
        onCheckpointError: (_, first) => checkpointFailures.add(first),
      );
      expect(await persistence.putBlock('one', '译文'), isFalse);
      expect(await persistence.putBlock('two', '译文'), isFalse);
      await persistence.save(_job(20), force: true);
      await persistence.save(_job(21), force: true);
      store.fail = false;
      expect(await persistence.putBlock('three', '译文'), isTrue);
      await persistence.save(_job(22), force: true);
      expect(cacheFailures, [true, false]);
      expect(checkpointFailures, [true, false]);
      expect(store.saves, [22]);
    },
  );
}
