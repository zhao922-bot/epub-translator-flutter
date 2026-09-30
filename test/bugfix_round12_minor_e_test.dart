import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub_isolate_worker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

/// Regression tests for the isolate-worker minor fixes (round 12, batch E):
/// 1. `.tmp.*` orphan reclamation on commit (previously only `.bak.*` was
///    reclaimed).
/// 2. Zip-bomb guard: new cap on archive entry count.
/// 3. `META-INF/container.xml` exact-case lookup: intentionally NOT changed
///    (OCF mandates the exact path; hard failure is spec-compliant).
/// 4. Repack dedupes duplicate entry names last-wins, matching the read path.
void main() {
  group('.tmp orphan reclamation', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('epub_tmp_reclaim_');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test(
      'reclaims a stale .tmp orphan but commits the live temp file',
      () async {
        final File finalFile = File(path.join(tempDir.path, 'out.epub'));
        // Orphan from a dead previous process: old mtime.
        final File orphan = File('${finalFile.path}.tmp.111');
        await orphan.writeAsString('ORPHAN', flush: true);
        await orphan.setLastModified(
          DateTime.now().subtract(const Duration(hours: 2)),
        );
        // The temp file this commit is about to promote: fresh mtime.
        final File liveTemp = File('${finalFile.path}.tmp.222');
        await liveTemp.writeAsString('NEW_CONTENT', flush: true);

        final bool committed = await EpubIsolateWorker.commitTempFile(
          liveTemp,
          finalFile,
        );

        expect(committed, isTrue);
        expect(
          await orphan.exists(),
          isFalse,
          reason: 'stale .tmp orphan should be reclaimed',
        );
        expect(await finalFile.readAsString(), 'NEW_CONTENT');
      },
    );

    test('does not delete a live .tmp file written by this process', () async {
      final File finalFile = File(path.join(tempDir.path, 'out2.epub'));
      // Simulates a temp deliberately kept by an OutputFileLockedException
      // recovery in this process: fresh mtime, must survive.
      final File keptTemp = File('${finalFile.path}.tmp.333');
      await keptTemp.writeAsString('KEPT', flush: true);
      final File liveTemp = File('${finalFile.path}.tmp.444');
      await liveTemp.writeAsString('NEW_CONTENT', flush: true);

      final bool committed = await EpubIsolateWorker.commitTempFile(
        liveTemp,
        finalFile,
      );

      expect(committed, isTrue);
      expect(
        await keptTemp.exists(),
        isTrue,
        reason: 'live .tmp file must not be reclaimed',
      );
      expect(await keptTemp.readAsString(), 'KEPT');
    });

    test('ignores non-.tmp files during reclamation', () async {
      final File finalFile = File(path.join(tempDir.path, 'out3.epub'));
      final File unrelated = File(
        path.join(tempDir.path, 'out3.epub.notes.txt'),
      );
      await unrelated.writeAsString('NOTES', flush: true);
      await unrelated.setLastModified(
        DateTime.now().subtract(const Duration(hours: 2)),
      );
      final File liveTemp = File('${finalFile.path}.tmp.555');
      await liveTemp.writeAsString('NEW_CONTENT', flush: true);

      await EpubIsolateWorker.commitTempFile(liveTemp, finalFile);

      expect(await unrelated.exists(), isTrue);
    });
  });

  group('archive entry-count limit', () {
    test('rejects an archive with more entries than the cap', () {
      final Archive archive = Archive();
      for (int i = 0; i < 50001; i++) {
        archive.addFile(
          ArchiveFile('e$i.bin', 1, Uint8List.fromList(<int>[0])),
        );
      }
      expect(
        () => EpubIsolateWorker.checkArchiveLimitsForTest(
          inputPath: 'evil.epub',
          archive: archive,
          compressedBytes: 1024,
        ),
        throwsA(isA<EpubDecompressionLimitException>()),
      );
    });

    test('accepts an archive under the entry cap', () {
      final Archive archive = Archive();
      for (int i = 0; i < 1000; i++) {
        archive.addFile(
          ArchiveFile('e$i.bin', 1, Uint8List.fromList(<int>[0])),
        );
      }
      expect(
        () => EpubIsolateWorker.checkArchiveLimitsForTest(
          inputPath: 'ok.epub',
          archive: archive,
          compressedBytes: 4096,
        ),
        returnsNormally,
      );
    });
  });

  group('duplicate entry-name handling', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('epub_dedupe_');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    Future<File> writeDupEpub() async {
      final Archive archive = Archive();
      final List<int> mimetype = 'application/epub+zip'.codeUnits;
      archive.add(
        ArchiveFile.noCompress('mimetype', mimetype.length, mimetype),
      );
      archive.add(
        ArchiveFile.bytes(
          'OEBPS/chapter.xhtml',
          '<html><body><p>FIRST</p></body></html>'.codeUnits,
        ),
      );
      archive.add(
        ArchiveFile.bytes(
          'OEBPS/chapter.xhtml',
          '<html><body><p>SECOND</p></body></html>'.codeUnits,
        ),
      );
      final File file = File(path.join(tempDir.path, 'dup.epub'));
      await file.writeAsBytes(ZipEncoder().encodeBytes(archive), flush: true);
      return file;
    }

    test('read path resolves duplicate names last-wins', () async {
      final File input = await writeDupEpub();
      final Map<String, Uint8List> files =
          await EpubIsolateWorker.loadArchiveFiles(input.path);
      expect(
        String.fromCharCodes(files['OEBPS/chapter.xhtml']!),
        contains('SECOND'),
      );
    });

    test('repack emits exactly one copy of a duplicated entry', () async {
      final File input = await writeDupEpub();
      final String tempPath =
          await EpubIsolateWorker.writeTranslatedEpubToTempForTest(
            inputPath: input.path,
            outputFilePath: path.join(tempDir.path, 'dup_out.epub'),
            translatedHtmlByPath: const <String, String>{
              'OEBPS/chapter.xhtml':
                  '<html><body><p>translated</p></body></html>',
            },
          );
      final Archive repacked = ZipDecoder().decodeBytes(
        await File(tempPath).readAsBytes(),
      );
      final List<ArchiveFile> copies = repacked
          .where((ArchiveFile f) => f.name == 'OEBPS/chapter.xhtml')
          .toList();
      expect(
        copies,
        hasLength(1),
        reason: 'duplicate source entries must not both be written',
      );
      expect(
        String.fromCharCodes(copies.single.content as List<int>),
        contains('translated'),
      );
      // The mimetype entry is still first and uncompressed (spec requirement).
      expect(repacked.first.name, 'mimetype');
    });
  });
}
