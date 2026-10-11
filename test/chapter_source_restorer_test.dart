import 'dart:async';
import 'dart:convert';

import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/domain/repositories/translation_repository.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/chapter_source_restorer.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_html_extractor.dart';
import 'package:flutter_test/flutter_test.dart';

InspectedChapter _released(String path) {
  final chapter = const EpubHtmlExtractor().inspectChapterBytes(
    chapterPath: path,
    bytes: utf8.encode('<html><body><p>Source paragraph</p></body></html>'),
  );
  return chapter.copyWith(
    blocks: [
      for (final block in chapter.blocks)
        block.copyWith(
          sourceHtml: '',
          sourceText: '',
          translatedHtml: '<p>译文</p>',
        ),
    ],
    translatedBody: '译文',
  );
}

void main() {
  test(
    'only selected released chapters are restored; identity is preserved',
    () async {
      final selected = _released('selected.xhtml').copyWith(
        sourceIdentity: const EpubSourceIdentity(
          inputPath: 'book.epub',
          sha256: 'fingerprint',
        ),
      );
      // If this unselected chapter were parsed, its block-order validation
      // would fail. It must remain untouched and must not enter the worker.
      final excluded = _released('excluded.xhtml').copyWith(
        includeInTranslation: false,
        originalHtml: '<html><body></body></html>',
      );
      final progress = <(int, int)>[];
      final result = await ChapterSourceRestorer.restore(
        chapters: [excluded, selected],
        isCancelled: () => false,
        onProgress: (done, total) => progress.add((done, total)),
      );
      expect(identical(result[0], excluded), isTrue);
      expect(result[0].blocks.single.sourceHtml, isEmpty);
      expect(result[1].blocks.single.sourceText, 'Source paragraph');
      expect(result[1].blocks.single.sourceHtml, '<p>Source paragraph</p>');
      expect(result[1].sourceIdentity!.sha256, 'fingerprint');
      expect(result[1].translatedBody, '译文');
      expect(progress, [(0, 1), (1, 1)]);
    },
  );

  test('selected changed block order still fails in worker', () async {
    await expectLater(
      ChapterSourceRestorer.restore(
        chapters: [
          _released(
            'changed.xhtml',
          ).copyWith(originalHtml: '<body><h1>Changed</h1></body>'),
        ],
        isCancelled: () => false,
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test('legacy translated preview restores the original source body', () async {
    final chapter = const EpubHtmlExtractor().inspectChapterBytes(
      chapterPath: 'legacy.xhtml',
      bytes: utf8.encode('<body><p>Original text</p></body>'),
    );
    final result = await ChapterSourceRestorer.restore(
      chapters: [
        chapter.copyWith(
          body: '旧译文',
          blocks: [
            chapter.blocks.single.copyWith(translatedHtml: '<p>旧译文</p>'),
          ],
        ),
      ],
      isCancelled: () => false,
    );
    expect(result.single.body, 'Original text');
    expect(result.single.blocks.single.sourceText, 'Original text');
  });

  test(
    'UI timer can cancel a worker during a single large chapter parse',
    () async {
      final large = _released('large.xhtml').copyWith(
        originalHtml:
            '<html><body>${List.filled(100000, '<p>Long original paragraph with words.</p>').join()}</body></html>',
      );
      var cancelled = false;
      var uiTimerRan = false;
      var parsedChapters = 0;
      Timer? timer;
      addTearDown(() => timer?.cancel());
      final future = ChapterSourceRestorer.restore(
        chapters: [large],
        isCancelled: () => cancelled,
        onProgress: (done, _) {
          parsedChapters = done;
          if (done == 0) {
            timer = Timer(const Duration(milliseconds: 5), () {
              uiTimerRan = true;
              cancelled = true;
            });
          }
        },
      );
      await expectLater(
        future.timeout(const Duration(seconds: 5)),
        throwsA(isA<TranslationCancelledException>()),
      );
      expect(uiTimerRan, isTrue);
      expect(parsedChapters, 0);
    },
  );

  test('already cancelled restoration never starts work', () async {
    await expectLater(
      ChapterSourceRestorer.restore(
        chapters: [_released('cancel.xhtml')],
        isCancelled: () => true,
        onProgress: (_, _) => fail('Cancelled work must not start'),
      ),
      throwsA(isA<TranslationCancelledException>()),
    );
  });
}
