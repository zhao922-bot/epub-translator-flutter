import 'dart:io';

import 'package:epub_translator_flutter/features/translation/infrastructure/epub_isolate_worker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

/// B-06 regression: the 5-attempt backoff delete (`_deleteQuietly`, added
/// for #36's cancel path where the handle was just released) must not leak
/// onto sweep/commit paths. Sweeping stale files is best-effort: a stuck
/// delete must not stall the commit on 25/50/100/200ms retry delays.
///
/// Split under test:
/// - cancel path keeps `_deleteQuietly` (retries): _exportOperation's
///   shouldCommit veto, commitTempFile's OutputLockCancelledException and
///   !_allowCommit vetoes.
/// - sweep/commit paths use single-attempt `_deleteBestEffort`:
///   _reclaimStaleBackups, _reclaimStaleTempFiles, _enforceRecoveryBudget,
///   _reclaimRecoveryFiles, and the post-promotion backup delete.
void main() {
  group('B-06 sweep delete is single-attempt best-effort', () {
    test('stale-temp sweep attempts each file exactly once on failure',
        () async {
      final dir = await Directory.systemTemp.createTemp('b06_sweep_');
      addTearDown(() => dir.delete(recursive: true));
      final finalFile = File(path.join(dir.path, 'book.epub'))..createSync();
      final liveTemp = File(path.join(dir.path, 'book.epub.tmp.999'))
        ..createSync();
      final stale1 = File(path.join(dir.path, 'book.epub.tmp.100'))
        ..createSync();
      final stale2 = File(path.join(dir.path, 'book.epub.tmp.101'))
        ..createSync();
      final old = DateTime.now().subtract(const Duration(hours: 1));
      stale1.setLastModifiedSync(old);
      stale2.setLastModifiedSync(old);
      liveTemp.setLastModifiedSync(old);

      final attempts = <String, int>{};
      Future<void> failingDelete(File file) async {
        attempts.update(file.path, (n) => n + 1, ifAbsent: () => 1);
        throw const FileSystemException('simulated stuck delete');
      }

      // Must not throw: the sweep swallows deleter failures.
      await EpubIsolateWorker.reclaimStaleTempFilesForTest(
        finalFile,
        liveTemp,
        deleteForTest: failingDelete,
      );

      // Exactly one attempt per stale file — no 5x backoff retries.
      expect(attempts[stale1.path], 1);
      expect(attempts[stale2.path], 1);
      // The live temp this commit is about to promote is never touched,
      // even though it is older than the stale cutoff.
      expect(attempts.containsKey(liveTemp.path), isFalse);
    });

    test('deleteBestEffort deletes when possible, ignores missing files',
        () async {
      final dir = await Directory.systemTemp.createTemp('b06_besteffort_');
      addTearDown(() => dir.delete(recursive: true));
      final victim = File(path.join(dir.path, 'gone.tmp'))..createSync();
      await EpubIsolateWorker.deleteBestEffortForTest(victim);
      expect(await victim.exists(), isFalse);
      // Missing file: no throw, no-op.
      await EpubIsolateWorker.deleteBestEffortForTest(
        File(path.join(dir.path, 'never-existed.tmp')),
      );
    });

    test('recovery-budget sweep is single-attempt on failure', () async {
      final dir = await Directory.systemTemp.createTemp('b06_budget_');
      addTearDown(() => dir.delete(recursive: true));
      final finalFile = File(path.join(dir.path, 'book.epub'))..createSync();
      // 6 spares > _kMaxRecoveryFiles (5): the oldest must go.
      for (int i = 0; i < 6; i++) {
        File(path.join(dir.path, 'book.epub.recovery.100000000000000$i'))
            .createSync();
      }
      final attempts = <String, int>{};
      Future<void> failingDelete(File file) async {
        attempts.update(file.path, (n) => n + 1, ifAbsent: () => 1);
        throw const FileSystemException('simulated stuck delete');
      }
      await EpubIsolateWorker.enforceRecoveryBudgetForTest(
        finalFile,
        deleteForTest: failingDelete,
      );
      expect(attempts.length, 1);
      expect(attempts.values.single, 1);
      expect(
        attempts.keys.single,
        endsWith('book.epub.recovery.1000000000000000'),
      );
    });
  });
}
