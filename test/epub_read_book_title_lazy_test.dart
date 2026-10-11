import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_source_guard.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub_isolate_worker.dart';
import 'package:flutter_test/flutter_test.dart';

Archive _archive({
  String opf = '''
<package xmlns:dc="http://purl.org/dc/elements/1.1/">
<metadata><dc:title>  中文 &amp; Book  </dc:title></metadata></package>''',
}) {
  return Archive()
    ..addFile(
      ArchiveFile.string(
        'META-INF/container.xml',
        '<container><rootfile full-path="OPS/nested/book.opf"/></container>',
      ),
    )
    ..addFile(ArchiveFile.string('OPS/nested/book.opf', opf))
    ..addFile(
      ArchiveFile.string('OPS/unrelated.bin', 'unrelated asset ' * 100),
    );
}

// Locate an entry through the central directory, then corrupt only its
// compressed payload. ZIP headers stay valid, so lazy readers can skip it.
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
  late Directory temp;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('epub_title_lazy_');
  });
  tearDown(() => temp.delete(recursive: true));

  test(
    'title read does not inflate unrelated corrupt compressed entries',
    () async {
      final bytes = ZipEncoder().encodeBytes(_archive());
      final data = ByteData.sublistView(bytes);
      final entry = _centralEntry(bytes, 'OPS/unrelated.bin');
      expect(data.getUint16(entry + 10, Endian.little), 8);
      final local = data.getUint32(entry + 42, Endian.little);
      final payload =
          local +
          30 +
          data.getUint16(local + 26, Endian.little) +
          data.getUint16(local + 28, Endian.little);
      bytes[payload] = 0x07; // Reserved DEFLATE block type: cannot inflate.
      final file = File('${temp.path}/corrupt_asset.epub')
        ..writeAsBytesSync(bytes);
      await expectLater(
        EpubIsolateWorker.loadArchiveSnapshot(file.path),
        throwsA(anything),
      );
      expect(
        await EpubIsolateWorker.readBookTitle(
          file.path,
          expectedSourceFingerprint: sha256.convert(bytes).toString(),
        ),
        '中文 & Book',
      );
    },
  );

  test('fingerprint mismatch is not swallowed as a missing title', () async {
    final file = File('${temp.path}/book.epub')
      ..writeAsBytesSync(ZipEncoder().encodeBytes(_archive()));
    await expectLater(
      EpubIsolateWorker.readBookTitle(
        file.path,
        expectedSourceFingerprint: 'wrong',
      ),
      throwsA(isA<EpubSourceChangedException>()),
    );
  });

  test('title read still rejects archive declared expansion limits', () async {
    final bytes = ZipEncoder().encodeBytes(_archive());
    final entry = _centralEntry(bytes, 'OPS/unrelated.bin');
    ByteData.sublistView(
      bytes,
    ).setUint32(entry + 24, 513 * 1024 * 1024, Endian.little);
    final file = File('${temp.path}/oversized.epub')..writeAsBytesSync(bytes);
    await expectLater(
      EpubIsolateWorker.readBookTitle(file.path),
      throwsA(isA<EpubDecompressionLimitException>()),
    );
  });

  test('missing or malformed metadata retains nullable title behavior', () async {
    final archives = [
      Archive()..addFile(ArchiveFile.string('other', 'no container')),
      Archive()
        ..addFile(ArchiveFile.string('META-INF/container.xml', '<broken')),
      Archive()..addFile(
        ArchiveFile.string(
          'META-INF/container.xml',
          '<container><rootfile full-path="missing.opf"/></container>',
        ),
      ),
      _archive(opf: '<broken'),
      _archive(opf: '<package><title>Not Dublin Core</title></package>'),
      _archive(
        opf:
            '<package xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title> </dc:title></package>',
      ),
    ];
    for (int i = 0; i < archives.length; i++) {
      final file = File('${temp.path}/missing$i.epub')
        ..writeAsBytesSync(ZipEncoder().encodeBytes(archives[i]));
      expect(await EpubIsolateWorker.readBookTitle(file.path), isNull);
    }
  });
}
