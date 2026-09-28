import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub_isolate_worker.dart';
import 'package:flutter_test/flutter_test.dart';

/// Regression tests for the zip-bomb guards and the source-file lock
/// classification in [EpubIsolateWorker].
void main() {
  group('archive decompression limits', () {
    test('rejects an entry with a huge header-declared size', () {
      final Archive archive = Archive()
        ..addFile(ArchiveFile('big.bin', 600 * 1024 * 1024, Uint8List(0)));
      expect(
        () => EpubIsolateWorker.checkArchiveLimitsForTest(
          inputPath: 'test.epub',
          archive: archive,
          compressedBytes: 1024,
        ),
        throwsA(isA<EpubDecompressionLimitException>()),
      );
    });

    test('rejects an absurd overall compression ratio', () {
      // 1 KB of "compressed" input declaring 200 KB of output: far beyond
      // what real text (3-5x) or images (~1x) ever produce.
      final Archive archive = Archive()
        ..addFile(ArchiveFile('bomb.txt', 200 * 1024, Uint8List(0)));
      expect(
        () => EpubIsolateWorker.checkArchiveLimitsForTest(
          inputPath: 'test.epub',
          archive: archive,
          compressedBytes: 1024,
        ),
        throwsA(isA<EpubDecompressionLimitException>()),
      );
    });

    test('accepts a normal archive', () {
      final Archive archive = Archive()
        ..addFile(ArchiveFile.string('mimetype', 'application/epub+zip'))
        ..addFile(ArchiveFile.string('OEBPS/ch1.xhtml', '<p>hello</p>'));
      expect(
        () => EpubIsolateWorker.checkArchiveLimitsForTest(
          inputPath: 'test.epub',
          archive: archive,
          compressedBytes: 4096,
        ),
        returnsNormally,
      );
    });

    test('limit exception carries diagnostic details', () {
      final Archive archive = Archive()
        ..addFile(ArchiveFile('big.bin', 600 * 1024 * 1024, Uint8List(0)));
      try {
        EpubIsolateWorker.checkArchiveLimitsForTest(
          inputPath: 'evil.epub',
          archive: archive,
          compressedBytes: 1024,
        );
        fail('expected EpubDecompressionLimitException');
      } on EpubDecompressionLimitException catch (error) {
        expect(error.inputPath, 'evil.epub');
        expect(error.uncompressedBytes, greaterThan(error.limitBytes));
      }
    });
  });

  group('source file lock classification', () {
    test(
      'missing file surfaces as FileSystemException, never as a lock',
      () async {
        await expectLater(
          EpubIsolateWorker.loadArchiveFiles(
            '/definitely/not/here/missing.epub',
          ),
          throwsA(
            allOf(
              isA<FileSystemException>(),
              isNot(isA<InputFileLockedException>()),
            ),
          ),
        );
      },
    );

    test('InputFileLockedException carries the input path', () {
      final InputFileLockedException error = InputFileLockedException(
        '/books/locked.epub',
      );
      expect(error.inputPath, '/books/locked.epub');
      expect(error.toString(), contains('/books/locked.epub'));
    });
  });
}
