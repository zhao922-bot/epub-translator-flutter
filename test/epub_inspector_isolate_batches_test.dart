import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_job.dart';
import 'package:epub_translator_flutter/features/translation/domain/repositories/translation_repository.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_html_extractor.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_inspector.dart';
import 'package:flutter_test/flutter_test.dart';

class _WorkerCheckingExtractor extends EpubHtmlExtractor {
  const _WorkerCheckingExtractor(this.callerId, {this.delay = false});

  final int callerId;
  final bool delay;

  @override
  InspectedChapter inspectChapterBytes({
    required String chapterPath,
    required List<int> bytes,
  }) {
    if (Isolate.current.hashCode == callerId) {
      throw StateError('Chapter decoding ran on the caller isolate');
    }
    if (delay) sleep(const Duration(milliseconds: 100));
    return super.inspectChapterBytes(chapterPath: chapterPath, bytes: bytes);
  }
}

Future<File> _book(Directory temp, {bool brokenLast = false}) async {
  final archive = Archive()
    ..addFile(
      ArchiveFile.string(
        'META-INF/container.xml',
        '<container><rootfiles><rootfile full-path="OPS/book.opf"/></rootfiles></container>',
      ),
    )
    ..addFile(
      ArchiveFile.string('OPS/book.opf', '''
<package><manifest>
${List.generate(9, (i) => '<item id="c$i" href="c$i.xhtml" media-type="application/xhtml+xml"/>').join()}
</manifest><spine>
${List.generate(9, (i) => '<itemref idref="c$i"/>').join()}
<itemref idref="unknown"/></spine></package>'''),
    );
  for (int i = 0; i < 9; i++) {
    if (i == 2) continue; // A missing file within the first batch.
    archive.addFile(
      ArchiveFile.string(
        'OPS/c$i.xhtml',
        brokenLast && i == 4
            ? '<?xml version="1.0" encoding="GBK"?><html/>'
            : '<html><head><title>Chapter $i</title></head><body><p>Hello $i<br/>world.</p><p>中文。</p></body></html>',
      ),
    );
  }
  return File('${temp.path}/book.epub')
    ..writeAsBytesSync(ZipEncoder().encodeBytes(archive));
}

void main() {
  late Directory temp;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('epub_inspector_batches_');
  });
  tearDown(() => temp.delete(recursive: true));

  test(
    'multiple worker batches preserve chapter order, progress and identity',
    () async {
      final file = await _book(temp);
      final completed = <int>[];
      final totals = <int>[];
      final result =
          await EpubInspector(
            extractor: _WorkerCheckingExtractor(Isolate.current.hashCode),
          ).inspect(
            inputPath: file.path,
            outputDirectory: temp.path,
            cancelToken: CancelToken(),
            onProgress: (job, _) {
              if (job.status == TranslationJobStatus.running &&
                  job.completedFiles > 0) {
                completed.add(job.completedFiles);
                totals.add(job.totalBlocks);
              }
            },
          );
      expect(completed, [1, 2, 4, 5, 6, 7, 8, 9]);
      expect(totals, [2, 4, 6, 8, 10, 12, 14, 16]);
      expect(result.job.status, TranslationJobStatus.inspected);
      expect(result.job.totalFiles, 9);
      expect(result.warnings, hasLength(2));
      expect(result.warnings.join(), contains('OPS/c2.xhtml'));
      expect(result.warnings.join(), contains('unknown'));
      final hash = sha256.convert(await file.readAsBytes()).toString();
      for (final chapter in result.chapters) {
        final expected = const EpubHtmlExtractor().inspectChapterBytes(
          chapterPath: chapter.path,
          bytes: utf8.encode(chapter.originalHtml),
        );
        expect(chapter.title, expected.title);
        expect(chapter.body, expected.body);
        expect(chapter.category, expected.category);
        expect(chapter.includeInTranslation, expected.includeInTranslation);
        expect(
          chapter.blocks.map((b) => (b.id, b.sourceText, b.sourceHtml)),
          expected.blocks.map((b) => (b.id, b.sourceText, b.sourceHtml)),
        );
        expect(chapter.sourceIdentity?.sha256, hash);
        expect(chapter.sourceIdentity?.inputPath, file.absolute.path);
      }
    },
  );

  for (final useToken in [true, false]) {
    test(
      'cancel between batches via ${useToken ? 'token' : 'check'} skips invalid next chapter',
      () async {
        final file = await _book(temp, brokenLast: true);
        final token = CancelToken();
        bool cancelled = false;
        final completed = <int>[];
        await expectLater(
          EpubInspector().inspect(
            inputPath: file.path,
            outputDirectory: temp.path,
            cancelToken: token,
            isCancelled: () => cancelled,
            onProgress: (job, _) {
              if (job.completedFiles > 0) completed.add(job.completedFiles);
              if (job.completedFiles == 4) {
                if (useToken) {
                  token.cancel();
                } else {
                  cancelled = true;
                }
              }
            },
          ),
          throwsA(isA<TranslationCancelledException>()),
        );
        expect(completed, [1, 2, 4]);
      },
    );
  }

  test('caller event loop can cancel while worker parses a batch', () async {
    final file = await _book(temp);
    final token = CancelToken();
    Timer? timer;
    addTearDown(() => timer?.cancel());
    final completed = <int>[];
    await expectLater(
      EpubInspector(
        extractor: _WorkerCheckingExtractor(
          Isolate.current.hashCode,
          delay: true,
        ),
      ).inspect(
        inputPath: file.path,
        outputDirectory: temp.path,
        cancelToken: token,
        onProgress: (job, _) {
          if (job.totalFiles == 9 && timer == null) {
            timer = Timer(
              const Duration(milliseconds: 20),
              () => token.cancel(),
            );
          }
          if (job.completedFiles > 0) completed.add(job.completedFiles);
        },
      ),
      throwsA(isA<TranslationCancelledException>()),
    );
    expect(completed, isEmpty);
  });

  test('worker encoding failures retain their type and chapter path', () async {
    final file = await _book(temp, brokenLast: true);
    await expectLater(
      EpubInspector().inspect(
        inputPath: file.path,
        outputDirectory: temp.path,
        cancelToken: CancelToken(),
      ),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('OPS/c4.xhtml'),
        ),
      ),
    );
  });
}
