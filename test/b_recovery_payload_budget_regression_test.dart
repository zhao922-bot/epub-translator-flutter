import 'dart:io';

import 'package:epub_translator_flutter/features/translation/infrastructure/epub_isolate_worker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

class _RenameFailure implements File {
  _RenameFailure(this.path);

  @override
  final String path;

  @override
  Future<File> rename(String newPath) async =>
      throw const FileSystemException('simulated recovery rename failure');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  const mib = 1024 * 1024;
  RecoveryBudgetEntry recovery(int stamp, int size) => (
    name: 'book.epub.recovery.$stamp',
    sizeBytes: size,
    kind: RecoveryBudgetKind.recoverySpare,
  );
  RecoveryBudgetEntry fallback(int stamp, int size) => (
    name: 'book.epub.tmp.$stamp',
    sizeBytes: size,
    kind: RecoveryBudgetKind.fallbackTmp,
  );
  const ledger = (
    name: 'book.epub.recovery-index',
    sizeBytes: 1,
    kind: RecoveryBudgetKind.indexLedger,
  );

  group('P1-4 / perf-21 recovery payload budget', () {
    test('single 600MiB complete spare survives the byte budget', () {
      expect(recoveryBudgetDeletions([recovery(1, 600 * mib)]), isEmpty);
      // Metadata is not the last complete spare, and is still budgeted.
      expect(
        recoveryBudgetDeletions([ledger, recovery(1, 600 * mib)]),
        [ledger.name],
      );
    });

    test('oldest payloads go first; newest oversized complete spare survives', () {
      expect(
        recoveryBudgetDeletions([
          recovery(30, 600 * mib),
          recovery(10, 200 * mib),
          recovery(20, 400 * mib),
        ]),
        ['book.epub.recovery.10', 'book.epub.recovery.20'],
      );
    });

    test('fallback payloads count and sort by timestamp across prefixes', () {
      expect(
        recoveryBudgetDeletions([
          recovery(20, 300 * mib),
          fallback(10, 300 * mib),
          fallback(30, 300 * mib),
          ledger,
        ]),
        ['book.epub.tmp.10', 'book.epub.recovery.20'],
      );
      expect(recoveryBudgetDeletions([fallback(1, 600 * mib)]), isEmpty);
    });

    test('explicit exemption protects a preserved payload even if oldest', () {
      expect(
        recoveryBudgetDeletions(
          [fallback(10, 600 * mib), recovery(20, 600 * mib)],
          exemptNames: {'book.epub.tmp.10'},
        ),
        ['book.epub.recovery.20'],
      );
    });

    late Directory dir;
    late File output;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('recovery_payload_budget_');
      output = File(path.join(dir.path, 'book.epub'));
    });
    tearDown(() => dir.delete(recursive: true));

    test('IO budget counts only existing, local, ledger-listed tmp payloads', () async {
      final spares = [
        for (var i = 10; i < 15; i++)
          File('${output.path}.tmp.$i')..writeAsStringSync('payload'),
      ];
      final live = File('${output.path}.tmp.1')..writeAsStringSync('live');
      final unrelated = File(path.join(dir.path, 'other.epub.tmp.1'))
        ..writeAsStringSync('unrelated');
      final index = File('${output.path}.recovery-index')
        ..writeAsStringSync([
          ...spares.map((file) => path.basename(file.path)),
          'book.epub.tmp.999', // Missing entries must not consume the quota.
          '../book.epub.tmp.1',
          'other.epub.tmp.1',
        ].join('\n'));
      final deleted = <String>[];
      await EpubIsolateWorker.enforceRecoveryBudgetForTest(
        output,
        deleteForTest: (file) async {
          deleted.add(file.path);
          await file.delete();
        },
      );
      expect(deleted, [spares.first.path]);
      expect(spares.skip(1).every((file) => file.existsSync()), isTrue);
      expect(live.readAsStringSync(), 'live');
      expect(unrelated.existsSync(), isTrue);
      expect(index.existsSync(), isTrue);
    });

    test('fallback preservation enforces quota and exempts returned path', () async {
      final old = [
        for (var i = 10; i < 15; i++)
          File('${output.path}.recovery.$i')..writeAsStringSync('old'),
      ];
      // Deliberately older than the other spares to exercise explicit exemption.
      final temp = File('${output.path}.tmp.1')
        ..writeAsStringSync('complete translated payload');
      final preserved = await EpubIsolateWorker.preserveRecoveryTempForTest(
        _RenameFailure(temp.path),
        output,
      );
      expect(preserved.path, temp.path);
      expect(temp.readAsStringSync(), 'complete translated payload');
      expect(old.take(2).every((file) => !file.existsSync()), isTrue);
      expect(old.skip(2).every((file) => file.existsSync()), isTrue);
      expect(File('${output.path}.recovery-index').existsSync(), isTrue);
    });

    test('successful commit reclaims indexed fallbacks but preserves live temps', () async {
      final fallback = File('${output.path}.tmp.10')
        ..writeAsStringSync('obsolete');
      final live = File('${output.path}.tmp.20')..writeAsStringSync('live');
      final commit = File('${output.path}.tmp.30')..writeAsStringSync('new');
      File('${output.path}.recovery-index').writeAsStringSync(
        '${path.basename(fallback.path)}\n${path.basename(commit.path)}\n',
      );
      expect(await EpubIsolateWorker.commitTempFile(commit, output), isTrue);
      expect(output.readAsStringSync(), 'new');
      expect(fallback.existsSync(), isFalse);
      expect(live.readAsStringSync(), 'live');
      expect(File('${output.path}.recovery-index').existsSync(), isFalse);
    });

    test('reclaim defensively skips the just-committed temp path', () async {
      final temp = File('${output.path}.tmp.1')..writeAsStringSync('new');
      File('${output.path}.recovery-index')
          .writeAsStringSync('${path.basename(temp.path)}\n');
      await EpubIsolateWorker.reclaimRecoveryFilesForTest(
        output,
        committedTempFile: temp,
      );
      expect(temp.readAsStringSync(), 'new');
    });
  });
}
