import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:epub_translator_flutter/features/preview/application/preview_provider.dart';
import 'package:epub_translator_flutter/features/preview/application/preview_recovery.dart';
import 'package:epub_translator_flutter/features/preview/domain/models/preview_chapter.dart';
import 'package:epub_translator_flutter/features/translation/application/translation_dashboard_controller.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/repositories/epub_translation_repository.dart';

InspectedChapter legacy({
  String source = 'Original',
  String translation = '译文',
}) => InspectedChapter(
  path: 'one.xhtml',
  title: 'One',
  body: translation,
  originalHtml: '<html><body><p>$source</p></body></html>',
  blocks: [
    ExtractedBlock(
      id: 'p-1',
      tagName: 'p',
      sourceHtml: '',
      sourceText: '',
      translatedHtml: '<p>$translation</p>',
    ),
  ],
  category: ChapterCategory.content,
  recommendedForTranslation: true,
  includeInTranslation: true,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'perf-#35 runner receives untouched chapters; isolate slims with identical excerpts',
    () async {
      final long = '${'a' * 5998}😀${'文' * 100000}';
      final chapters = [
        legacy(source: long, translation: long),
        legacy(translation: '${'a' * 6000} ${'b' * 100000}'),
        legacy().copyWith(
          blocks: [
            legacy().blocks.single.copyWith(translatedHtml: '<p>Start</p>'),
            legacy().blocks.single.copyWith(translatedHtml: '<p>$long</p>'),
          ],
        ),
        legacy().copyWith(
          originalHtml:
              '<html><head><style>${'x' * 100000}</style></head>'
              '<body><p>First<br>line</p><p>Second &amp; third</p></body></html>',
          blocks: [
            legacy().blocks.single.copyWith(translatedHtml: '<p></p>'),
            ...List.generate(
              15,
              (i) => legacy().blocks.single.copyWith(
                translatedHtml: '<p>Translation $i</p>',
              ),
            ),
          ],
        ),
        legacy(source: long, translation: long).copyWith(
          originalHtml: '',
          blocks: [
            legacy().blocks.single.copyWith(
              sourceText: long,
              translatedHtml: '<p>$long</p>',
            ),
            legacy().blocks.single.copyWith(
              sourceText: 'tail',
              translatedHtml: '<p>tail</p>',
            ),
          ],
        ),
        legacy().copyWith(
          originalHtml: '<html><body><pre>${'x' * 100000}</pre></body></html>',
        ),
        legacy().copyWith(
          originalHtml: '<html><body><p>${'&amp;' * 15000}</p></body></html>',
        ),
      ];
      for (final chapter in chapters) {
        final expected = previewChapterFromInspected(chapter);
        final cache = PreviewRecoveryCache(
          runner: (received) async {
            // perf-#35: no payload is built on the caller thread — the
            // runner gets the chapter untouched; the DOM-parsing slimming
            // happens in the isolate (_recoverBatch), never before
            // compute().
            expect(received, hasLength(1));
            expect(identical(received.single, chapter), isTrue);
            return recoverBatchForTest(received);
          },
        );
        await cache.prepare([chapter]);
        final actual = cache.lookup(chapter)!;
        expect(actual.body, expected.body);
        expect(actual.translatedBody, expected.translatedBody);
        expect(actual.blockCount, expected.blockCount);
        expect(actual.translatedBlockCount, expected.translatedBlockCount);
        expect(actual.title, expected.title);
        expect(actual.category, expected.category);
      }
    },
  );

  test(
    'switched-away completion is dropped before reading or applying results',
    () async {
      final jobs = <Completer<List<PreviewChapter>>>[];
      final cache = PreviewRecoveryCache(
        runner: (_) {
          final job = Completer<List<PreviewChapter>>();
          jobs.add(job);
          return job.future;
        },
      );
      final first = legacy();
      final second = legacy(source: 'Second book');
      final oldWork = cache.prepare([first]);
      final newWork = cache.prepare([second]);
      // An empty result makes any attempt to apply the obsolete batch observable.
      jobs.first.complete([]);
      await oldWork;
      expect(cache.lookup(first), isNull);
      expect(cache.lookup(second), isNull);
      jobs.last.complete([previewChapterFromInspected(second)]);
      await newWork;
      expect(cache.lookup(second)!.body, 'Second book');
    },
  );

  test(
    'identical pending content is adopted by the current generation',
    () async {
      final job = Completer<List<PreviewChapter>>();
      var calls = 0;
      final cache = PreviewRecoveryCache(
        runner: (_) {
          calls++;
          return job.future;
        },
      );
      final chapter = legacy();
      final first = cache.prepare([chapter]);
      final second = cache.prepare([chapter.copyWith(title: 'New title')]);
      job.complete([previewChapterFromInspected(chapter)]);
      await Future.wait([first, second]);
      expect(calls, 1);
      expect(cache.lookup(chapter)!.body, 'Original');
    },
  );

  test(
    'real isolate restores released legacy source and helper stays compatible',
    () async {
      final chapter = legacy();
      final cache = PreviewRecoveryCache();
      expect(cache.lookup(chapter), isNull);
      await cache.prepare([chapter]);
      expect(cache.lookup(chapter)!.body, 'Original');
      expect(cache.lookup(chapter)!.translatedBody, '译文');
      expect(previewChapterFromInspected(chapter).body, 'Original');
      final noHtml = chapter.copyWith(
        originalHtml: '',
        blocks: [chapter.blocks.single.copyWith(sourceText: 'Fallback')],
      );
      await cache.prepare([noHtml]);
      expect(cache.lookup(noHtml)!.body, 'Fallback');
    },
  );

  test(
    'content versions reuse metadata changes and invalidate source and translation',
    () async {
      var calls = 0;
      final cache = PreviewRecoveryCache(
        runner: (chapters) async {
          calls++;
          return chapters.map(previewChapterFromInspected).toList();
        },
      );
      final first = legacy();
      await cache.prepare([first]);
      await cache.prepare([
        first.copyWith(includeInTranslation: false, title: 'New'),
      ]);
      // Recreated immutable blocks with the same content are the same version.
      await cache.prepare([legacy()]);
      expect(calls, 1);
      final changed = legacy(source: 'Changed');
      expect(cache.lookup(changed), isNull);
      await cache.prepare([changed]);
      expect(cache.lookup(changed)!.body, 'Changed');
      final translated = legacy(source: 'Changed', translation: '新译文');
      await cache.prepare([translated]);
      expect(cache.lookup(translated)!.translatedBody, '新译文');
      expect(calls, 3);
      final blockOnly = translated.copyWith(
        blocks: [
          translated.blocks.single.copyWith(translatedHtml: '<p>仅块更新</p>'),
        ],
      );
      expect(cache.lookup(blockOnly), isNull);
      await cache.prepare([blockOnly]);
      expect(cache.lookup(blockOnly)!.translatedBody, '仅块更新');
      expect(calls, 4);
      await cache.prepare([]);
      expect(cache.lookup(blockOnly), isNull);
    },
  );

  test(
    'in-flight work is reused and stale completion cannot replace newer content',
    () async {
      final jobs = <Completer<List<PreviewChapter>>>[];
      final cache = PreviewRecoveryCache(
        runner: (_) {
          final job = Completer<List<PreviewChapter>>();
          jobs.add(job);
          return job.future;
        },
      );
      final old = legacy();
      final next = legacy(source: 'New book');
      final a = cache.prepare([old]);
      final same = cache.prepare([old.copyWith(includeInTranslation: false)]);
      expect(jobs, hasLength(1));
      final b = cache.prepare([next]);
      jobs[1].complete([previewChapterFromInspected(next)]);
      await b;
      jobs[0].complete([previewChapterFromInspected(old)]);
      await Future.wait([a, same]);
      expect(cache.lookup(old), isNull);
      expect(cache.lookup(next)!.body, 'New book');
    },
  );

  test(
    'main provider projects without synchronous recovery and reuses cache on toggles/logs',
    () async {
      final pending = Completer<List<PreviewChapter>>();
      var calls = 0;
      final cache = PreviewRecoveryCache(
        runner: (_) {
          calls++;
          return pending.future;
        },
      );
      final chapter = legacy();
      final controller = TranslationDashboardController(
        repository: EpubTranslationRepository(),
      );
      controller.state = controller.state.copyWith(
        inspectedChapters: [chapter],
      );
      final container = ProviderContainer(
        overrides: [
          translationDashboardProvider.overrideWith((_) => controller),
          previewRecoveryCacheProvider.overrideWithValue(cache),
        ],
      );
      addTearDown(container.dispose);
      final subscription = container.listen(previewChaptersProvider, (_, _) {});
      addTearDown(subscription.close);
      expect(container.read(previewChaptersProvider).single.body, isEmpty);
      expect(calls, 1);
      pending.complete([previewChapterFromInspected(chapter)]);
      await container.read(previewRecoveryProvider.future);
      expect(container.read(previewChaptersProvider).single.body, 'Original');
      controller.state = controller.state.copyWith(
        inspectedChapters: [chapter.copyWith(includeInTranslation: false)],
      );
      await container.read(previewRecoveryProvider.future);
      expect(
        container.read(previewChaptersProvider).single.includeInTranslation,
        isFalse,
      );
      controller.state = controller.state.copyWith(logs: ['tick']);
      expect(container.read(previewChaptersProvider).single.body, 'Original');
      expect(calls, 1);
    },
  );

  test('modern excerpts skip recovery and failed loads can retry', () async {
    var calls = 0;
    final cache = PreviewRecoveryCache(
      runner: (chapters) async {
        calls++;
        if (calls == 1) throw StateError('load failed');
        return chapters.map(previewChapterFromInspected).toList();
      },
    );
    final chapter = legacy();
    await cache.prepare([
      chapter.copyWith(body: 'Original', translatedBody: '译文'),
    ]);
    expect(calls, 0);
    await expectLater(cache.prepare([chapter]), throwsStateError);
    expect(cache.lookup(chapter), isNull);
    await cache.prepare([chapter]);
    expect(cache.lookup(chapter)!.body, 'Original');
    expect(calls, 2);
  });
}
