import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:epub_translator_flutter/features/preview/application/preview_recovery.dart';
import 'package:epub_translator_flutter/features/preview/domain/models/preview_chapter.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub_isolate_worker.dart';
import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// Raw ZIP builders.
// ---------------------------------------------------------------------------

class _RawZipEntry {
  _RawZipEntry(
    this.name,
    this.crc,
    this.method,
    this.compressedSize,
    this.declaredSize,
    this.offset,
  );
  final String name;
  final int crc;
  final int method;
  final int compressedSize;
  final int declaredSize;
  final int offset;
}

/// Minimal raw ZIP writer: stored entries, plus deflated entries whose
/// header-declared uncompressed size may lie ([declaredSize]).
class _RawZipBuilder {
  final _out = <int>[];
  final _entries = <_RawZipEntry>[];

  static List<int> _u16(int v) => <int>[v & 0xff, (v >> 8) & 0xff];
  static List<int> _u32(int v) => <int>[
    v & 0xff,
    (v >> 8) & 0xff,
    (v >> 16) & 0xff,
    (v >> 24) & 0xff,
  ];

  void _add(
    String name,
    List<int> storedPayload, {
    required int method,
    required int crc,
    required int declaredSize,
  }) {
    final nameBytes = utf8.encode(name);
    final offset = _out.length;
    _out.addAll(_u32(0x04034b50));
    _out.addAll(_u16(20));
    _out.addAll(_u16(0)); // flags
    _out.addAll(_u16(method));
    _out.addAll(_u16(0));
    _out.addAll(_u16(0)); // time/date
    _out.addAll(_u32(crc));
    _out.addAll(_u32(storedPayload.length)); // compressed size: always honest
    _out.addAll(_u32(declaredSize)); // uncompressed size: may lie
    _out.addAll(_u16(nameBytes.length));
    _out.addAll(_u16(0)); // extra length
    _out.addAll(nameBytes);
    _out.addAll(storedPayload);
    _entries.add(
      _RawZipEntry(
        name,
        crc,
        method,
        storedPayload.length,
        declaredSize,
        offset,
      ),
    );
  }

  void addStored(String name, List<int> data) => _add(
    name,
    data,
    method: 0,
    crc: getCrc32(data),
    declaredSize: data.length,
  );

  /// A zip-bomb-shaped entry: [data] is the real payload, but the headers
  /// declare [declaredSize]. The compressed size stays honest so the decoder
  /// slices the right bytes (a real attacker does the same).
  void addLyingStored(String name, List<int> data, int declaredSize) => _add(
    name,
    data,
    method: 0,
    crc: getCrc32(data),
    declaredSize: declaredSize,
  );

  void addLyingDeflated(String name, List<int> data, int declaredSize) {
    final compressed = ZLibCodec(raw: true).encode(data);
    _add(
      name,
      compressed,
      method: 8,
      crc: getCrc32(data),
      declaredSize: declaredSize,
    );
  }

  Uint8List build() {
    final out = <int>[..._out];
    final cdOffset = out.length;
    for (final entry in _entries) {
      final nameBytes = utf8.encode(entry.name);
      out.addAll(_u32(0x02014b50));
      out.addAll(_u16(63));
      out.addAll(_u16(20));
      out.addAll(_u16(0)); // flags
      out.addAll(_u16(entry.method));
      out.addAll(_u16(0));
      out.addAll(_u16(0)); // time/date
      out.addAll(_u32(entry.crc));
      out.addAll(_u32(entry.compressedSize));
      out.addAll(_u32(entry.declaredSize));
      out.addAll(_u16(nameBytes.length));
      out.addAll(_u16(0)); // extra
      out.addAll(_u16(0)); // comment
      out.addAll(_u16(0)); // disk
      out.addAll(_u16(0)); // internal attrs
      out.addAll(_u32(0)); // external attrs
      out.addAll(_u32(entry.offset));
      out.addAll(nameBytes);
    }
    final cdSize = out.length - cdOffset;
    out.addAll(_u32(0x06054b50));
    out.addAll(_u16(0));
    out.addAll(_u16(0));
    out.addAll(_u16(_entries.length));
    out.addAll(_u16(_entries.length));
    out.addAll(_u32(cdSize));
    out.addAll(_u32(cdOffset));
    out.addAll(_u16(0));
    return Uint8List.fromList(out);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // -------------------------------------------------------------------------
  // P1-#1: streaming inflate guard counts ACTUAL decompressed bytes.
  // -------------------------------------------------------------------------
  group('P1-#1 guarded inflate', () {
    test('stored liar aborts on actual bytes, not declared size', () {
      // 200 KiB of payload declaring 10 bytes: the declared-size preflight
      // cannot see it, but the streaming guard counts real bytes.
      final data = Uint8List(200 * 1024);
      final zip = _RawZipBuilder()
        ..addLyingStored('big.bin', data, 10)
        ..build();
      final archive = ZipDecoder().decodeBytes(zip.build());
      final file = archive.find('big.bin')!;
      expect(file.size, 10);
      expect(
        () => EpubIsolateWorker.checkArchiveLimitsForTest(
          inputPath: 'liar.epub',
          archive: archive,
          compressedBytes: zip.build().length,
        ),
        returnsNormally,
        reason: 'declared sizes sail through the preflight',
      );
      expect(
        () => EpubIsolateWorker.inflateZipFileGuardedForTest(
          file: file,
          inputPath: 'liar.epub',
          limitBytes: 1024,
        ),
        throwsA(isA<EpubDecompressionLimitException>()),
      );
      // Under the cap the payload inflates intact.
      final inflated = EpubIsolateWorker.inflateZipFileGuardedForTest(
        file: file,
        inputPath: 'liar.epub',
        limitBytes: 300 * 1024,
      );
      expect(inflated, data);
    });

    test('deflated liar aborts mid-stream via incremental writes', () {
      final data = Uint8List(200 * 1024); // highly compressible
      final builder = _RawZipBuilder()..addLyingDeflated('bomb.bin', data, 10);
      final bytes = builder.build();
      final archive = ZipDecoder().decodeBytes(bytes);
      final file = archive.find('bomb.bin')!;
      expect(file.size, 10);
      try {
        EpubIsolateWorker.inflateZipFileGuardedForTest(
          file: file,
          inputPath: 'bomb.epub',
          limitBytes: 1024,
        );
        fail('expected EpubDecompressionLimitException');
      } on EpubDecompressionLimitException catch (error) {
        expect(error.uncompressedBytes, greaterThan(error.limitBytes));
        expect(error.limitBytes, 1024);
      }
      final inflated = EpubIsolateWorker.inflateZipFileGuardedForTest(
        file: file,
        inputPath: 'bomb.epub',
        limitBytes: 300 * 1024,
      );
      expect(inflated, data);
    });

    test('honest entries under the cap inflate normally', () {
      final data = utf8.encode('hello world');
      final builder = _RawZipBuilder()..addStored('ok.txt', data);
      final archive = ZipDecoder().decodeBytes(builder.build());
      final file = archive.find('ok.txt')!;
      expect(
        EpubIsolateWorker.inflateZipFileGuardedForTest(
          file: file,
          inputPath: 'ok.epub',
          limitBytes: 1024,
        ),
        data,
      );
    });
  });

  // -------------------------------------------------------------------------
  // P1-#2: quota cleanup must not evict the ledger while it still describes
  // live fallback payloads.
  // -------------------------------------------------------------------------
  group('P1-#2 ledger protection', () {
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

    test('ledger survives while a registered fallback payload does', () {
      // Byte budget exceeded; the fallback tmp is the last complete payload
      // (protected) and the ledger is its only registration record.
      expect(
        recoveryBudgetDeletions([fallback(1, 600 * mib), ledger]),
        isEmpty,
      );
    });

    test('ledger still evicted when no fallback payload needs it', () {
      // Pre-existing behavior: a lone recovery spare needs no ledger, so the
      // ledger remains the evictable entry.
      expect(recoveryBudgetDeletions([recovery(1, 600 * mib), ledger]), [
        ledger.name,
      ]);
    });

    test('count pressure evicts spares, never the ledger or its payload', () {
      final entries = [
        recovery(1, mib),
        recovery(2, mib),
        recovery(3, mib),
        recovery(4, mib),
        recovery(5, mib),
        fallback(6, mib),
        ledger,
      ];
      final deletions = recoveryBudgetDeletions(entries);
      expect(deletions, hasLength(2));
      expect(deletions, contains('book.epub.recovery.1'));
      expect(deletions, contains('book.epub.recovery.2'));
      expect(deletions, isNot(contains(ledger.name)));
      expect(deletions, isNot(contains('book.epub.tmp.6')));
    });
  });

  // -------------------------------------------------------------------------
  // P2-#6: duplicate names detected from raw headers; repack writes valid
  // CRCs. (The old per-archive name count was always 1: dead trigger.)
  // -------------------------------------------------------------------------
  group('P2-#6 duplicate entry CRC repair', () {
    test('repacked output carries valid CRCs for duplicate entries', () async {
      final dir = await Directory.systemTemp.createTemp('round11_dup_');
      addTearDown(() => dir.delete(recursive: true));
      final builder = _RawZipBuilder()
        ..addStored('mimetype', utf8.encode('application/epub+zip'))
        ..addStored(
          'META-INF/container.xml',
          utf8.encode(
            '<container><rootfile full-path="OPS/book.opf"/></container>',
          ),
        )
        ..addStored(
          'OPS/book.opf',
          utf8.encode(
            '<package xmlns="http://www.idpf.org/2007/opf"><metadata/>'
            '<manifest><item id="c0" href="c0.xhtml" '
            'media-type="application/xhtml+xml"/></manifest>'
            '<spine><itemref idref="c0"/></spine></package>',
          ),
        )
        ..addStored(
          'OPS/c0.xhtml',
          utf8.encode('<html><body><p>Hello.</p></body></html>'),
        )
        ..addStored('OPS/dup.css', utf8.encode('p{color:red}'))
        ..addStored('OPS/dup.css', utf8.encode('p{color:blue}'));
      final input = File('${dir.path}/in.epub')
        ..writeAsBytesSync(builder.build());
      final output = '${dir.path}/out.epub';
      expect(
        await EpubIsolateWorker.writeTranslatedEpub(
          inputPath: input.path,
          outputFilePath: output,
          translatedHtmlByPath: const <String, String>{},
        ),
        isTrue,
      );
      final outputDecoder = ZipDecoder();
      final repacked = outputDecoder.decodeBytes(
        File(output).readAsBytesSync(),
      );
      for (final file in repacked) {
        if (!file.isFile) continue;
        expect(
          getCrc32(file.content),
          file.crc32,
          reason: 'CRC mismatch for ${file.name}',
        );
      }
      // The worker resolves raw duplicates last-wins before CRC-safe repacking.
      expect(
        repacked.files.where((f) => f.name == 'OPS/dup.css'),
        hasLength(1),
      );
      expect(
        outputDecoder.directory.fileHeaders.where(
          (h) => h.file?.filename == 'OPS/dup.css',
        ),
        hasLength(1),
      );
      final dup = repacked.find('OPS/dup.css')!;
      expect(utf8.decode(dup.content), 'p{color:blue}');
    });
  });

  // -------------------------------------------------------------------------
  // perf-#35: no payload is built on the caller thread before compute().
  // -------------------------------------------------------------------------
  group('perf-#35 isolate-side slimming', () {
    test('prepare passes a parse-free payload to the runner (P-#46)', () async {
      final chapter = InspectedChapter(
        path: 'big.xhtml',
        title: 'Big',
        body: 'source body',
        // Oversized HTML: the old code ran a full DOM parse
        // (inspectChapterBytes) on the caller thread right here.
        originalHtml:
            '<html><head><style>${'x' * 100000}</style></head>'
            '<body><p>${'y' * 100000}</p></body></html>',
        blocks: [
          ExtractedBlock(
            id: 'b1',
            tagName: 'p',
            sourceHtml: '<p>src</p>',
            sourceText: 'src',
            translatedHtml: '<p>${'z' * 100000}</p>',
          ),
        ],
        category: ChapterCategory.content,
        recommendedForTranslation: true,
        includeInTranslation: true,
      );
      var sawPayload = false;
      final cache = PreviewRecoveryCache(
        runner: (received) async {
          // P-#46: the runner now receives the parse-free transfer payload
          // (same identity fields, slimmed blocks), not the full chapter.
          final payload = received.single;
          sawPayload =
              !identical(payload, chapter) &&
              payload.path == chapter.path &&
              payload.title == chapter.title &&
              payload.originalHtml == chapter.originalHtml &&
              payload.blocks.single.id.isEmpty &&
              payload.blocks.single.sourceHtml.isEmpty;
          return received
              .map(
                (c) => PreviewChapter(
                  title: c.title,
                  body: '',
                  path: c.path,
                  category: '',
                  recommendedForTranslation: false,
                  includeInTranslation: false,
                  blockCount: 0,
                  translatedBlockCount: 0,
                ),
              )
              .toList();
        },
      );
      await cache.prepare([chapter]);
      expect(sawPayload, isTrue);
    });
  });
}
