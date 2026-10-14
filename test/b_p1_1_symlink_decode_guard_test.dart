import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub_isolate_worker.dart';
import 'package:flutter_test/flutter_test.dart';

// Reuse the central-header lookup pattern from epub_read_book_title_lazy_test.
int _centralEntry(Uint8List bytes, String name) {
  final data = ByteData.sublistView(bytes);
  for (int i = 0; i + 46 <= bytes.length; i++) {
    if (data.getUint32(i, Endian.little) != 0x02014b50) continue;
    final length = data.getUint16(i + 28, Endian.little);
    if (String.fromCharCodes(bytes.sublist(i + 46, i + 46 + length)) == name) {
      return i;
    }
  }
  throw StateError('Missing entry $name');
}

Uint8List _zip(List<int> payload, {bool symlink = true}) {
  final bytes = ZipEncoder().encodeBytes(
    Archive()..addFile(ArchiveFile.noCompress('link', payload.length, payload)),
  );
  if (symlink) {
    final entry = _centralEntry(bytes, 'link');
    bytes[entry + 5] = 3; // Unix host; ZipEncoder defaults to MSDOS.
    ByteData.sublistView(
      bytes,
    ).setUint32(entry + 38, 0xa1ff << 16, Endian.little);
  }
  return bytes;
}

// ZIP64 EOCD/locator layout from epub_archive_limits_test's raw ZIP helper.
Uint8List _withZip64Directory(Uint8List bytes) {
  final end = bytes.length - 22;
  final result = Uint8List(bytes.length + 76)
    ..setRange(0, end, bytes)
    ..setRange(end + 76, bytes.length + 76, bytes, end);
  final original = ByteData.sublistView(bytes);
  final data = ByteData.sublistView(result);
  void u32(int offset, int value) =>
      data.setUint32(offset, value, Endian.little);
  u32(end, 0x06064b50);
  u32(end + 4, 44);
  data.setUint16(end + 12, 45, Endian.little);
  data.setUint16(end + 14, 45, Endian.little);
  u32(end + 24, 1);
  u32(end + 32, 1);
  u32(end + 40, original.getUint32(end + 12, Endian.little));
  u32(end + 48, original.getUint32(end + 16, Endian.little));
  u32(end + 56, 0x07064b50);
  u32(end + 64, end);
  u32(end + 72, 1);
  data.setUint16(end + 76 + 8, 65535, Endian.little);
  data.setUint16(end + 76 + 10, 65535, Endian.little);
  u32(end + 76 + 12, 0xffffffff);
  u32(end + 76 + 16, 0xffffffff);
  return result;
}

void main() {
  group('B-P1-1 symlink decode guard', () {
    for (final zip64 in [false, true]) {
      test('rejects oversized symlink before decoding (ZIP64=$zip64)', () {
        final stored = _zip(Uint8List(128 * 1024));
        final bytes = zip64 ? _withZip64Directory(stored) : stored;
        EpubIsolateWorker.checkZipEntryCountForTest('attack.epub', bytes);
        expect(
          () => EpubIsolateWorker.checkSymlinkEntrySizesForTest(
            'attack.epub',
            bytes,
          ),
          throwsA(
            isA<EpubDecompressionLimitException>()
                .having((e) => e.inputPath, 'inputPath', 'attack.epub')
                .having((e) => e.compressedBytes, 'compressedBytes', 128 * 1024)
                .having((e) => e.uncompressedBytes, 'uncompressedBytes', -1)
                .having((e) => e.limitBytes, 'limitBytes', 64 * 1024),
          ),
        );
      });
    }

    test('tiny legitimate symlink is rejected before decoding', () {
      const target = 'target/path.txt';
      final bytes = _zip(utf8.encode(target));
      expect(
        () => EpubIsolateWorker.checkSymlinkEntrySizesForTest('ok.epub', bytes),
        throwsA(
          isA<EpubDecompressionLimitException>()
              .having(
                (e) => e.compressedBytes,
                'compressedBytes',
                target.length,
              )
              .having((e) => e.uncompressedBytes, 'uncompressedBytes', -1)
              .having((e) => e.limitBytes, 'limitBytes', 64 * 1024),
        ),
      );
    });

    test('normal non-symlink entry above the symlink quota is unaffected', () {
      final bytes = _zip(Uint8List(128 * 1024), symlink: false);
      expect(
        () => EpubIsolateWorker.checkSymlinkEntrySizesForTest(
          'normal.epub',
          bytes,
        ),
        returnsNormally,
      );
    });

    test('symlink attributes on a non-Unix host do not trigger the guard', () {
      final bytes = _zip(Uint8List(128 * 1024));
      bytes[_centralEntry(bytes, 'link') + 5] = 0;
      expect(
        () =>
            EpubIsolateWorker.checkSymlinkEntrySizesForTest('dos.epub', bytes),
        returnsNormally,
      );
    });

    test('symlink compressed size exactly at the quota is rejected', () {
      final bytes = _zip(Uint8List(64 * 1024));
      expect(
        () => EpubIsolateWorker.checkSymlinkEntrySizesForTest(
          'boundary.epub',
          bytes,
        ),
        throwsA(isA<EpubDecompressionLimitException>()),
      );
    });

    test('ZIP64 size placeholder is rejected using only tiny headers', () {
      final bytes = _zip(utf8.encode('target'));
      final entry = _centralEntry(bytes, 'link');
      ByteData.sublistView(
        bytes,
      ).setUint32(entry + 20, 0xffffffff, Endian.little);
      // No giant payload is constructed or decoded to exercise this limit.
      expect(bytes.length, lessThan(1024));
      expect(
        () => EpubIsolateWorker.checkSymlinkEntrySizesForTest(
          'zip64.epub',
          bytes,
        ),
        throwsA(
          isA<EpubDecompressionLimitException>().having(
            (e) => e.compressedBytes,
            'compressedBytes',
            0xffffffff,
          ),
        ),
      );
    });

    test(
      'production loading checks symlink size before decoder reads payload',
      () async {
        final temp = await Directory.systemTemp.createTemp('symlink_guard_');
        addTearDown(() => temp.delete(recursive: true));
        final bytes = _zip(utf8.encode('target'));
        final data = ByteData.sublistView(bytes);
        final entry = _centralEntry(bytes, 'link');
        // A large compressed size with no backing payload would fail decoding;
        // the quota exception proves production rejects it before that happens.
        data.setUint32(entry + 20, 128 * 1024, Endian.little);
        final file = File('${temp.path}/attack.epub')..writeAsBytesSync(bytes);
        await expectLater(
          EpubIsolateWorker.loadArchiveFiles(file.path),
          throwsA(isA<EpubDecompressionLimitException>()),
        );
      },
    );
  });
}
