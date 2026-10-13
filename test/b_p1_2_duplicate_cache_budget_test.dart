import 'package:archive/archive.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub_isolate_worker.dart';
import 'package:flutter_test/flutter_test.dart';

Archive _decodedEntries(Map<String, List<int>> payloads) {
  final archive = Archive();
  for (final entry in payloads.entries) {
    archive.addFile(
      ArchiveFile(entry.key, entry.value.length, entry.value)
        ..compression = CompressionType.deflate,
    );
  }
  return ZipDecoder().decodeBytes(ZipEncoder().encode(archive));
}

void main() {
  group('B-P1-2 duplicate cache budget', () {
    test('insertion hook fires once per distinct file, never on hits', () {
      final payloads = <String, List<int>>{
        'a.bin': [1, 2, 3],
        'b.bin': [4, 5, 6, 7],
      };
      final archive = _decodedEntries(payloads);
      final a = archive.find('a.bin')!;
      final b = archive.find('b.bin')!;
      expect(a.rawContent, isA<ZipFile>());
      expect(b.rawContent, isA<ZipFile>());
      final cache = <ArchiveFile, List<int>>{};
      final insertions = <ArchiveFile, int>{};
      int calls = 0;
      void onCacheInsert(ArchiveFile file, List<int> inserted) {
        calls++;
        insertions[file] = inserted.length;
      }

      List<int> read(ArchiveFile file) => EpubIsolateWorker.fileBytesForTest(
        file,
        bytesCache: cache,
        onCacheInsert: onCacheInsert,
      );
      final first = read(a);
      expect(first, payloads['a.bin']);
      expect(identical(read(a), first), isTrue);
      expect(read(b), payloads['b.bin']);
      expect(calls, 2);
      expect(insertions, {a: 3, b: 4});
      expect(a.rawContent, isA<ZipFile>());
      expect(a.isCompressed, isTrue);
      expect(b.isCompressed, isTrue);
    });

    test('budget accumulates bytes, accepts equality, and rejects excess', () {
      int check(int total, int length) =>
          EpubIsolateWorker.checkDuplicateCacheBudgetForTest(
            currentTotalBytes: total,
            insertedBytes: List<int>.filled(length, 0),
            inputPath: 'budget.epub',
            compressedBytes: 2,
            budgetBytesOverride: 10,
          );
      final first = check(0, 3);
      expect(first, 3);
      final second = check(first, 4);
      expect(second, 7);
      expect(check(second, 3), 10);
      expect(
        () => check(second, 4),
        throwsA(
          isA<EpubDecompressionLimitException>()
              .having((e) => e.inputPath, 'inputPath', 'budget.epub')
              .having((e) => e.compressedBytes, 'compressedBytes', 2)
              .having((e) => e.uncompressedBytes, 'uncompressedBytes', 11)
              .having((e) => e.limitBytes, 'limitBytes', 10),
        ),
      );
    });

    test(
      'cache insertion and cumulative budget compose across ZIP entries',
      () {
        final archive = _decodedEntries({
          'a.bin': [1, 2, 3, 4],
          'b.bin': [5, 6, 7, 8],
          'c.bin': [9, 10, 11, 12],
        });
        final cache = <ArchiveFile, List<int>>{};
        int total = 0;
        List<int> read(ArchiveFile file) => EpubIsolateWorker.fileBytesForTest(
          file,
          inputPath: 'composed.epub',
          bytesCache: cache,
          onCacheInsert: (file, inserted) {
            total = EpubIsolateWorker.checkDuplicateCacheBudgetForTest(
              currentTotalBytes: total,
              insertedBytes: inserted,
              inputPath: 'composed.epub',
              compressedBytes: (file.rawContent as ZipFile).compressedSize,
              budgetBytesOverride: 8,
            );
          },
        );
        final a = archive.find('a.bin')!;
        final b = archive.find('b.bin')!;
        final c = archive.find('c.bin')!;
        expect(read(a), [1, 2, 3, 4]);
        expect(read(a), [1, 2, 3, 4]);
        expect(total, 4);
        expect(read(b), [5, 6, 7, 8]);
        expect(total, 8);
        expect(
          () => read(c),
          throwsA(
            isA<EpubDecompressionLimitException>()
                .having((e) => e.uncompressedBytes, 'uncompressedBytes', 12)
                .having((e) => e.limitBytes, 'limitBytes', 8),
          ),
        );
        expect(total, 8);
        expect(cache.keys, [a, b]);
        expect(c.rawContent, isA<ZipFile>());
        expect(c.isCompressed, isTrue);
      },
    );
  });
}
