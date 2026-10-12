import 'dart:io';

import 'package:epub_translator_flutter/features/translation/infrastructure/epub_isolate_worker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

/// B-03 regression: `<basename>.recovery-index` used to grow by append
/// forever — it matched neither `_reclaimRecoveryFiles`'s
/// `<basename>.recovery.` prefix nor `_enforceRecoveryBudget`'s accounting
/// (`'x.recovery-index'.startsWith('x.recovery.')` is false).
///
/// Fixed: the index is reclaimed together with the spares after a
/// successful commit, and it counts against the recovery budget (it sorts
/// after `...recovery.<digits>`, so the ledger is evicted last).
void main() {
  group('B-03 recovery-index lifecycle', () {
    test('reclaim deletes spares and the index file', () async {
      final dir = await Directory.systemTemp.createTemp('b03_reclaim_');
      addTearDown(() => dir.delete(recursive: true));
      final finalFile = File(path.join(dir.path, 'book.epub'))..createSync();
      final spare = File(path.join(dir.path, 'book.epub.recovery.1000000000000001'))
        ..createSync();
      final index = File(path.join(dir.path, 'book.epub.recovery-index'))
        ..writeAsStringSync('book.epub.tmp.42\n');

      await EpubIsolateWorker.reclaimRecoveryFilesForTest(finalFile);

      expect(await spare.exists(), isFalse);
      expect(await index.exists(), isFalse);
      // The final output itself is never touched.
      expect(await finalFile.exists(), isTrue);
    });

    test('budget counts the index: 5 spares + index evicts the oldest spare',
        () async {
      final dir = await Directory.systemTemp.createTemp('b03_budget_');
      addTearDown(() => dir.delete(recursive: true));
      final finalFile = File(path.join(dir.path, 'book.epub'))..createSync();
      // _kMaxRecoveryFiles is 5: 5 spares alone would pass the budget, but
      // the index counts as a 6th entry, so the oldest spare must go.
      final spares = <File>[
        for (int i = 0; i < 5; i++)
          File(path.join(dir.path, 'book.epub.recovery.100000000000000$i'))
            ..createSync(),
      ];
      final index = File(path.join(dir.path, 'book.epub.recovery-index'))
        ..writeAsStringSync('book.epub.tmp.42\n');

      await EpubIsolateWorker.enforceRecoveryBudgetForTest(finalFile);

      // Oldest spare evicted; the index (sorting last) survives.
      expect(await spares.first.exists(), isFalse);
      for (final spare in spares.skip(1)) {
        expect(await spare.exists(), isTrue);
      }
      expect(await index.exists(), isTrue);
    });

    test('unrelated files are never swept as recovery files', () async {
      final dir = await Directory.systemTemp.createTemp('b03_unrelated_');
      addTearDown(() => dir.delete(recursive: true));
      final finalFile = File(path.join(dir.path, 'book.epub'))..createSync();
      final other = File(path.join(dir.path, 'other.epub.recovery-index'))
        ..createSync();

      await EpubIsolateWorker.reclaimRecoveryFilesForTest(finalFile);

      expect(await other.exists(), isTrue);
    });
  });
}
