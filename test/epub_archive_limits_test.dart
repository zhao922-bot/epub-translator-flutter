import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub_isolate_worker.dart';
import 'package:flutter_test/flutter_test.dart';

// Repeated names deliberately exercise the raw header count, not Archive's
// deduplicated file count. No payload allocation or encoder is needed.
Uint8List _emptyEntryZip(int count, {int? declaredCount, bool zip64 = false}) {
  const localSize = 31;
  const centralSize = 47;
  final centralEnd = count * (localSize + centralSize);
  final bytes = Uint8List(centralEnd + (zip64 ? 76 : 0) + 22);
  final data = ByteData.sublistView(bytes);
  void u16(int offset, int value) =>
      data.setUint16(offset, value, Endian.little);
  void u32(int offset, int value) =>
      data.setUint32(offset, value, Endian.little);
  for (int i = 0; i < count; i++) {
    final local = i * localSize;
    final central = count * localSize + i * centralSize;
    u32(local, 0x04034b50);
    u16(local + 4, 20);
    u16(local + 26, 1);
    bytes[local + 30] = 120;
    u32(central, 0x02014b50);
    u16(central + 4, 20);
    u16(central + 6, 20);
    u16(central + 28, 1);
    u32(central + 42, local);
    bytes[central + 46] = 120;
  }
  final end = bytes.length - 22;
  u32(end, 0x06054b50);
  u16(end + 8, zip64 ? 65535 : declaredCount ?? count);
  u16(end + 10, zip64 ? 65535 : declaredCount ?? count);
  u32(end + 12, zip64 ? 0xffffffff : count * centralSize);
  u32(end + 16, zip64 ? 0xffffffff : count * localSize);
  if (zip64) {
    u32(centralEnd, 0x06064b50);
    u32(centralEnd + 4, 44);
    u16(centralEnd + 12, 45);
    u16(centralEnd + 14, 45);
    u32(centralEnd + 24, declaredCount ?? count);
    u32(centralEnd + 32, declaredCount ?? count);
    u32(centralEnd + 40, count * centralSize);
    u32(centralEnd + 48, count * localSize);
    u32(centralEnd + 56, 0x07064b50);
    u32(centralEnd + 64, centralEnd);
    u32(centralEnd + 72, 1);
  }
  return bytes;
}

/// Regression tests for the zip-bomb guards and the source-file lock
/// classification in [EpubIsolateWorker].
void main() {
  group('archive decompression limits', () {
    for (final zip64 in [false, true]) {
      test(
        'preflight counts actual headers before decoding (ZIP64=$zip64)',
        () {
          for (final declared in [50001, 1]) {
            final bytes = _emptyEntryZip(
              50001,
              declaredCount: declared,
              zip64: zip64,
            );
            expect(
              () => EpubIsolateWorker.checkZipEntryCountForTest(
                'bomb.epub',
                bytes,
              ),
              throwsA(isA<EpubDecompressionLimitException>()),
            );
          }
          expect(
            () => EpubIsolateWorker.checkZipEntryCountForTest(
              'boundary.epub',
              _emptyEntryZip(50000, zip64: zip64),
            ),
            returnsNormally,
          );
          final normal = _emptyEntryZip(1, zip64: zip64);
          EpubIsolateWorker.checkZipEntryCountForTest('normal.epub', normal);
          expect(ZipDecoder().decodeBytes(normal).length, 1);
        },
      );
    }

    test('production archive loading rejects over-limit metadata', () async {
      final temp = await Directory.systemTemp.createTemp('zip_entry_limit_');
      addTearDown(() => temp.delete(recursive: true));
      final file = File('${temp.path}/bomb.epub');
      await file.writeAsBytes(_emptyEntryZip(50001, declaredCount: 1));
      await expectLater(
        EpubIsolateWorker.loadArchiveFiles(file.path),
        throwsA(isA<EpubDecompressionLimitException>()),
      );
    });

    test('preflight rejects truncated or inconsistent central directories', () {
      final bytes = _emptyEntryZip(1);
      for (final malformed in [
        bytes.sublist(0, bytes.length - 1),
        _emptyEntryZip(1, declaredCount: 0),
        Uint8List.fromList(bytes)..[31 + 28] = 255,
      ]) {
        expect(
          () => EpubIsolateWorker.checkZipEntryCountForTest(
            'bad.epub',
            malformed,
          ),
          throwsFormatException,
        );
      }
    });

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
