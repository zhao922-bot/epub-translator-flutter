import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub_isolate_worker.dart';
import 'package:flutter_test/flutter_test.dart';

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

void main() {
  test('B-P1-4 rejects a tiny BZIP2 symlink that expands to 8 MiB', () {
    const expandedSize = 8 * 1024 * 1024;
    final bz = BZip2Encoder().encodeBytes(Uint8List(expandedSize));
    final bytes = ZipEncoder().encodeBytes(
      Archive()..addFile(ArchiveFile.noCompress('link', bz.length, bz)),
    );
    final data = ByteData.sublistView(bytes);
    final entry = _centralEntry(bytes, 'link');
    void u16(int at, int value) => data.setUint16(at, value, Endian.little);
    void u32(int at, int value) => data.setUint32(at, value, Endian.little);

    // Store the BZIP2 stream unchanged, then select method 12 in both headers.
    // The claimed output size is deliberately much smaller than the payload.
    u16(8, 12);
    u32(18, bz.length);
    u32(22, 1);
    bytes[entry + 5] = 3; // Unix host.
    u16(entry + 10, 12);
    u32(entry + 20, bz.length);
    u32(entry + 24, 1);
    u32(entry + 38, 0xa1ff << 16);

    expect(bz.length, lessThan(64 * 1024));
    EpubIsolateWorker.checkZipEntryCountForTest('bz.epub', bytes);
    expect(
      () => EpubIsolateWorker.checkSymlinkEntrySizesForTest('bz.epub', bytes),
      throwsA(
        isA<EpubDecompressionLimitException>()
            .having((e) => e.inputPath, 'inputPath', 'bz.epub')
            .having((e) => e.compressedBytes, 'compressedBytes', bz.length)
            .having((e) => e.uncompressedBytes, 'uncompressedBytes', -1)
            .having((e) => e.limitBytes, 'limitBytes', 64 * 1024),
      ),
    );
    // Verify the fixture reaches the eager symlink inflate in the decoder.
    expect(
      ZipDecoder().decodeBytes(bytes).find('link')!.symbolicLink!.length,
      expandedSize,
    );
  });
}
