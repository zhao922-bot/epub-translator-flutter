import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub_isolate_worker.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _ordinaryZip() => ZipEncoder().encodeBytes(
  Archive()..addFile(ArchiveFile.noCompress('data.bin', 1, [0])),
);

// Keep the outer EOCD valid, but put a second EOCD, directory and local entry
// in its comment. archive's reverse signature scan selects the inner EOCD.
Uint8List _ambiguousZip() {
  final outer = _ordinaryZip();
  final end = outer.length - 22;
  final name = utf8.encode('hidden-link');
  final payload = utf8.encode('target/path.txt');
  final innerEnd = end + 22;
  final central = innerEnd + 22;
  final local = central + 46 + name.length;
  final bytes = Uint8List(local + 30 + name.length + payload.length)
    ..setRange(0, outer.length, outer);
  final data = ByteData.sublistView(bytes);
  void u16(int at, int value) => data.setUint16(at, value, Endian.little);
  void u32(int at, int value) => data.setUint32(at, value, Endian.little);

  u16(end + 20, bytes.length - innerEnd);
  u32(innerEnd, 0x06054b50);
  u16(innerEnd + 8, 1);
  u16(innerEnd + 10, 1);
  u32(innerEnd + 12, 46 + name.length);
  u32(innerEnd + 16, central);

  u32(central, 0x02014b50);
  u16(central + 4, 0x0314); // Unix host.
  u16(central + 6, 20);
  u32(central + 20, payload.length);
  u32(central + 24, payload.length);
  u16(central + 28, name.length);
  u32(central + 38, 0xa1ff << 16);
  u32(central + 42, local);
  bytes.setRange(central + 46, local, name);

  u32(local, 0x04034b50);
  u16(local + 4, 20);
  u32(local + 18, payload.length);
  u32(local + 22, payload.length);
  u16(local + 26, name.length);
  bytes.setRange(local + 30, local + 30 + name.length, name);
  bytes.setRange(local + 30 + name.length, bytes.length, payload);
  return bytes;
}

void main() {
  group('B-P1-3 EOCD ambiguity', () {
    test('decoder selects the directory hidden in the EOCD comment', () {
      final archive = ZipDecoder().decodeBytes(_ambiguousZip());
      expect(archive.find('hidden-link'), isNotNull);
      expect(archive.find('data.bin'), isNull);
    });

    test('both preflights reject the ambiguous EOCD before decoding', () {
      final bytes = _ambiguousZip();
      expect(
        () => EpubIsolateWorker.checkZipEntryCountForTest('amb.epub', bytes),
        throwsFormatException,
      );
      expect(
        () =>
            EpubIsolateWorker.checkSymlinkEntrySizesForTest('amb.epub', bytes),
        throwsFormatException,
      );
    });

    test('production loading rejects the ambiguous EOCD', () async {
      final temp = await Directory.systemTemp.createTemp('eocd_ambiguity_');
      addTearDown(() => temp.delete(recursive: true));
      final file = File('${temp.path}/amb.epub');
      await file.writeAsBytes(_ambiguousZip());
      await expectLater(
        EpubIsolateWorker.loadArchiveFiles(file.path),
        throwsFormatException,
      );
    });

    test('both preflights accept an ordinary ZIP', () {
      final bytes = _ordinaryZip();
      expect(
        () => EpubIsolateWorker.checkZipEntryCountForTest('ok.epub', bytes),
        returnsNormally,
      );
      expect(
        () => EpubIsolateWorker.checkSymlinkEntrySizesForTest('ok.epub', bytes),
        returnsNormally,
      );
    });
  });
}
