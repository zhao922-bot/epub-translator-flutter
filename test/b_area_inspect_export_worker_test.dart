import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_job.dart';
import 'package:epub_translator_flutter/features/translation/domain/repositories/translation_repository.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_html_extractor.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_inspector.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub_isolate_worker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:xml/xml.dart';

// Signal actual worker entry before cancellation, avoiding timing assumptions
// about isolate startup on slow CI machines. CPU work simulates a huge DOM
// parse; native sleep cannot service isolate kill messages until it returns.
class _SlowExtractor extends EpubHtmlExtractor {
  const _SlowExtractor(this.started);
  final SendPort started;
  @override
  InspectedChapter inspectChapterBytes({
    required String chapterPath,
    required List<int> bytes,
  }) {
    started.send('started');
    _busyParse();
    return super.inspectChapterBytes(chapterPath: chapterPath, bytes: bytes);
  }
}

Set<String> _slowSelector(Map<String, List<int>> files, String opfPath) {
  _busyParse();
  return EpubInspector.inspectionEntryPaths(files, opfPath);
}

void _busyParse() {
  final watch = Stopwatch()..start();
  while (watch.elapsed < const Duration(seconds: 10)) {
    // Keep executing Dart so the VM can process immediate isolate control.
  }
}

Map<String, List<int>> _metadata({
  String languages = '<dc:language>en</dc:language>',
}) => {
  'META-INF/container.xml': utf8.encode(
    '<container><rootfile full-path="OPS/book.opf"/></container>',
  ),
  'OPS/book.opf': utf8.encode(
    '''<package xmlns="http://www.idpf.org/2007/opf" xmlns:dc="http://purl.org/dc/elements/1.1/">
<metadata><dc:title>Source title</dc:title>$languages</metadata><manifest>
<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
${List.generate(8, (i) => '<item id="c$i" href="c$i.xhtml" media-type="application/xhtml+xml"/>').join()}
</manifest><spine toc="ncx">${List.generate(8, (i) => '<itemref idref="c$i"/>').join()}</spine></package>''',
  ),
  'OPS/toc.ncx': utf8.encode(
    '<ncx><docTitle><text>Source title</text></docTitle><navMap><navPoint><navLabel><text>Source label</text></navLabel><content src="c0.xhtml"/></navPoint></navMap></ncx>',
  ),
  'OPS/nav.xhtml': utf8.encode(
    '<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><body><nav epub:type="toc"><a href="c0.xhtml">Source label</a></nav></body></html>',
  ),
};

File _book(Directory dir, {int present = 8}) {
  final files = _metadata();
  for (int i = 0; i < present; i++) {
    files['OPS/c$i.xhtml'] = utf8.encode(
      '<html><body><p>Chapter $i.</p></body></html>',
    );
  }
  final archive = Archive();
  for (final entry in files.entries) {
    archive.addFile(ArchiveFile.bytes(entry.key, entry.value));
  }
  return File(path.join(dir.path, 'source.epub'))
    ..writeAsBytesSync(ZipEncoder().encodeBytes(archive));
}

void main() {
  late Directory dir;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('b_area_c2_');
  });
  tearDown(() => dir.delete(recursive: true));

  test('all spine files absent fails with explicit warning', () async {
    final result = await EpubInspector().inspect(
      inputPath: _book(dir, present: 0).path,
      outputDirectory: dir.path,
      cancelToken: CancelToken(),
    );
    expect(result.job.status, TranslationJobStatus.failed);
    expect(result.job.progress, 1);
    expect(result.chapters, isEmpty);
    expect(result.warnings.join(), contains('所有 spine 引用的章节文件均缺失'));
  });

  test('partial spine loss remains inspected with warnings', () async {
    final result = await EpubInspector().inspect(
      inputPath: _book(dir, present: 4).path,
      outputDirectory: dir.path,
      cancelToken: CancelToken(),
    );
    expect(result.job.status, TranslationJobStatus.inspected);
    expect(result.chapters, hasLength(4));
    expect(result.warnings, hasLength(4));
  });

  test('all inspect progress emissions are monotonic', () async {
    final progress = <double>[];
    await EpubInspector().inspect(
      inputPath: _book(dir).path,
      outputDirectory: dir.path,
      cancelToken: CancelToken(),
      onProgress: (job, _) => progress.add(job.progress),
    );
    expect(progress, containsAllInOrder([0.1, 0.2]));
    expect(progress[3], closeTo(0.3, 1e-12));
    for (int i = 1; i < progress.length; i++) {
      expect(progress[i], greaterThanOrEqualTo(progress[i - 1]));
    }
    expect(progress.last, 1);
  });

  test('snapshot worker cancels without waiting for slow selection', () async {
    final file = _book(dir);
    var cancelled = false;
    final timer = Timer(
      const Duration(milliseconds: 100),
      () => cancelled = true,
    );
    addTearDown(timer.cancel);
    await expectLater(
      EpubIsolateWorker.loadInspectionSnapshot(
        file.path,
        selectEntries: _slowSelector,
        isCancelled: () => cancelled,
      ).timeout(const Duration(seconds: 2)),
      throwsA(isA<TranslationCancelledException>()),
    );
  });

  for (final viaToken in [true, false]) {
    test(
      'cancel active chapter parse via ${viaToken ? 'token' : 'check'}',
      () async {
        final started = ReceivePort();
        final token = CancelToken();
        var cancelled = false;
        final subscription = started.listen((_) {
          if (viaToken) {
            token.cancel();
          } else {
            cancelled = true;
          }
        });
        addTearDown(() async {
          await subscription.cancel();
          started.close();
        });
        await expectLater(
          EpubInspector(extractor: _SlowExtractor(started.sendPort))
              .inspect(
                inputPath: _book(dir).path,
                outputDirectory: dir.path,
                cancelToken: token,
                isCancelled: () => cancelled,
              )
              .timeout(const Duration(seconds: 2)),
          throwsA(isA<TranslationCancelledException>()),
        );
      },
    );
  }

  test(
    'cancel ZIP encoding after temp creation cleans this temp and preserves final',
    () async {
      final input = _book(dir);
      final output = File(path.join(dir.path, 'output.epub'))
        ..writeAsStringSync('original');
      // A large replacement makes encoding last long enough to observe an
      // actual opened temp, rather than cancelling before worker startup.
      final large = List.generate(
        400000,
        (i) => '<p>Translated paragraph $i with text.</p>',
      ).join();
      var sawTemp = false;
      await expectLater(
        EpubIsolateWorker.writeTranslatedEpub(
          inputPath: input.path,
          outputFilePath: output.path,
          translatedHtmlByPath: {
            'OPS/c0.xhtml': '<html><body>$large</body></html>',
          },
          isCancelled: () {
            sawTemp =
                sawTemp ||
                dir.listSync().any(
                  (f) => f.path.startsWith('${output.path}.tmp.'),
                );
            return sawTemp;
          },
        ).timeout(const Duration(seconds: 10)),
        throwsA(isA<TranslationCancelledException>()),
      );
      expect(sawTemp, isTrue);
      expect(
        dir.listSync().where((f) => f.path.startsWith('${output.path}.tmp.')),
        isEmpty,
      );
      expect(output.readAsStringSync(), 'original');
    },
  );

  for (final language in <String?>[null, 'zh']) {
    for (final languages in [
      '',
      '<dc:language>en</dc:language><dc:language>en</dc:language>',
    ]) {
      test(
        'translated title and labels with tag=$language and existing languages=${languages.isNotEmpty}',
        () {
          final rendered = EpubIsolateWorker.renderNavigationMetadata(
            archiveFiles: _metadata(languages: languages),
            labelsByPath: {'OPS/c0.xhtml': '译文标签'},
            languageTag: language,
            translatedTitle: '译文书名',
            bilingual: true,
          );
          final opf = XmlDocument.parse(rendered['OPS/book.opf']!);
          final languageValues = opf.descendants
              .whereType<XmlElement>()
              .where((e) => e.name.local == 'language')
              .map((e) => e.innerText)
              .toList();
          expect(
            opf.descendants
                .whereType<XmlElement>()
                .firstWhere((e) => e.name.local == 'title')
                .innerText,
            '译文书名',
          );
          expect(rendered['OPS/toc.ncx'], contains('<text>译文标签</text>'));
          expect(rendered['OPS/toc.ncx'], contains('译文书名'));
          expect(rendered['OPS/nav.xhtml'], contains('译文标签'));
          if (language == null) {
            expect(
              languageValues,
              languages.isEmpty ? isEmpty : equals(['en', 'en']),
            );
            for (final markup in rendered.values) {
              expect(markup, isNot(contains('xml:lang=')));
              expect(markup, isNot(contains(' lang=')));
            }
          } else {
            expect(languageValues, languages.isEmpty ? ['zh'] : ['en', 'zh']);
            expect(rendered['OPS/toc.ncx'], contains('xml:lang="zh"'));
          }
        },
      );
    }
  }

  test('export writes title and navigation even without target tag', () async {
    final output = path.join(dir.path, 'translated.epub');
    expect(
      await EpubIsolateWorker.writeTranslatedEpub(
        inputPath: _book(dir).path,
        outputFilePath: output,
        translatedHtmlByPath: {},
        translatedTitle: '译文书名',
        navigationLabelsByPath: {'OPS/c0.xhtml': '译文标签'},
      ),
      isTrue,
    );
    final files = await EpubIsolateWorker.loadArchiveFiles(output);
    expect(utf8.decode(files['OPS/book.opf']!), contains('译文书名'));
    expect(utf8.decode(files['OPS/toc.ncx']!), contains('译文标签'));
  });

  test('orphan sweep preserves old recovery payload and active temp', () async {
    final output = File(path.join(dir.path, 'output.epub'));
    final orphan = File('${output.path}.tmp.orphan')
      ..writeAsStringSync('orphan');
    final active = File('${output.path}.tmp.active')
      ..writeAsStringSync('active');
    final locked = File('${output.path}.tmp.locked')
      ..writeAsStringSync('translated');
    final recovery = await EpubIsolateWorker.preserveRecoveryTempForTest(
      locked,
      output,
    );
    for (final file in [orphan, active, recovery]) {
      file.setLastModifiedSync(
        DateTime.now().subtract(const Duration(days: 1)),
      );
    }
    await EpubIsolateWorker.reclaimStaleTempFilesForTest(output, active);
    expect(orphan.existsSync(), isFalse);
    expect(active.existsSync(), isTrue);
    expect(recovery.readAsStringSync(), 'translated');
    expect(locked.existsSync(), isFalse);
    expect(recovery.path, contains('.recovery.'));
  });

  test(
    'growth during chunk reads is rejected before accumulating beyond cap',
    () {
      final chunks = [
        [1, 2],
        [3, 4],
        [5, 6, 7],
        <int>[],
      ];
      int index = 0;
      expect(
        () => EpubIsolateWorker.readChunksGuardedForTest(
          inputPath: 'growing.epub',
          nextChunk: () => chunks[index++],
          limitBytes: 5,
        ),
        throwsA(
          isA<EpubDecompressionLimitException>().having(
            (e) => e.compressedBytes,
            'actual bytes',
            7,
          ),
        ),
      );
      expect(index, 3); // Must stop without reading any later chunk.
    },
  );

  test('small chunked read returns complete bytes including exact limit', () {
    final chunks = [
      [1, 2],
      [3],
      <int>[],
    ];
    int index = 0;
    expect(
      EpubIsolateWorker.readChunksGuardedForTest(
        inputPath: 'small.epub',
        nextChunk: () => chunks[index++],
        limitBytes: 3,
      ),
      [1, 2, 3],
    );
  });
}
