import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:html/parser.dart' as html;
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_repacker.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_chapter_translator.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/repositories/epub_translation_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_job.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/job_history_store.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_html_extractor.dart';

class ReadFailureFile implements File {
  ReadFailureFile(this.delegate);
  final File delegate;
  @override
  String get path => delegate.path;
  @override
  Directory get parent => delegate.parent;
  @override
  Future<bool> exists() => delegate.exists();
  @override
  Future<String> readAsString({Encoding encoding = utf8}) async =>
      throw FileSystemException('Simulated transient read failure', path);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

TranslationJob job(String id) => TranslationJob(
  id: id,
  inputPath: '$id.epub',
  outputPath: '$id-out.epub',
  status: TranslationJobStatus.failed,
  progress: 0,
);

void main() {
  for (final merged in [false, true]) {
    test(
      'read failure preserves tombstone and releases locks: merged=$merged',
      () async {
        final dir = await Directory.systemTemp.createTemp(
          'audit-history-tombstone-',
        );
        addTearDown(() => dir.delete(recursive: true));
        final file = File('${dir.path}/history.json');
        final normal = JobHistoryStore(historyFileProvider: () async => file);
        await normal.save([job('old')], clearedAtEpochMs: 100);
        final before = await file.readAsString();
        final failed = JobHistoryStore(
          historyFileProvider: () async => ReadFailureFile(file),
        );
        await expectLater(
          merged
              ? failed.saveMerged(
                  merge: (jobs, _) => [job('stale')],
                  clearedAtEpochMs: 0,
                )
              : failed.save([job('stale')]),
          throwsA(isA<FileSystemException>()),
        );
        expect(await file.readAsString(), before);
        await normal.saveMerged(
          merge: (jobs, _) => [job('new'), ...jobs],
          clearedAtEpochMs: 100,
        );
        expect((await normal.load()).map((job) => job.id), ['new', 'old']);
        expect((await normal.loadWithTombstone()).clearedAt, 100);
      },
    );
    test('corrupt data is backed up before save: merged=$merged', () async {
      final dir = await Directory.systemTemp.createTemp(
        'audit-history-backup-',
      );
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/history.json');
      await file.writeAsString('{broken');
      final store = JobHistoryStore(historyFileProvider: () async => file);
      if (merged) {
        await store.saveMerged(
          merge: (_, _) => [job('new')],
          clearedAtEpochMs: 0,
        );
      } else {
        await store.save([job('new')]);
      }
      final backup = dir.listSync().whereType<File>().singleWhere(
        (f) => f.path.contains('.bad-'),
      );
      expect(await backup.readAsString(), '{broken');
      expect((await store.load()).single.id, 'new');
    });
  }
  test(
    'language allowlist does not carry unrelated attributes or invalid tags',
    () {
      const source = '<p>Before <q id="quote">Stay hungry.</q></p>';
      final translated = EpubChapterTranslator.lockHtmlStructureForTest(
        sourceHtml: source,
        translatedHtml:
            '<p>之前 <q id="wrong" onclick="bad()" xml:lang="en">Stay hungry.</q></p>',
      );
      final q = html.parseFragment(translated).querySelector('q')!;
      expect(q.attributes['id'], 'quote');
      expect(q.attributes['onclick'], isNull);
      expect(q.attributes['xml:lang'], 'en');
      final invalid = EpubChapterTranslator.lockHtmlStructureForTest(
        sourceHtml: source,
        translatedHtml: '<p>之前 <q lang="not a language">Stay hungry.</q></p>',
      );
      expect(
        html.parseFragment(invalid).querySelector('q')!.attributes['lang'],
        isNull,
      );
    },
  );
  test('stale original language is still corrected after translation', () {
    const source = '<p><em lang="en">Hello world.</em></p>';
    final chapter = const EpubHtmlExtractor().inspectChapterBytes(
      chapterPath: 'ch.xhtml',
      bytes: utf8.encode('<html><body>$source</body></html>'),
    );
    final locked = EpubChapterTranslator.lockHtmlStructureForTest(
      sourceHtml: source,
      translatedHtml: '<p><em lang="en">Bonjour.</em></p>',
    );
    final rendered = EpubRepacker().renderTranslatedChapter(
      chapter: chapter.copyWith(
        blocks: [chapter.blocks.single.copyWith(translatedHtml: locked)],
      ),
      bilingual: false,
      targetLanguage: 'French',
    );
    expect(html.parse(rendered).querySelector('em')!.attributes['lang'], 'fr');
  });
  for (final throughBatch in [false, true]) {
    test(
      'intentional foreign quote language survives pipeline: batch=$throughBatch',
      () async {
        final chapter = const EpubHtmlExtractor().inspectChapterBytes(
          chapterPath: 'chapter.xhtml',
          bytes: utf8.encode(
            '<html lang="en"><body><p>He said <q>Stay hungry.</q></p></body></html>',
          ),
        );
        const modelHtml = '<p>他说 <q lang="en">Stay hungry.</q></p>';
        var translated = modelHtml;
        if (throughBatch) {
          final dio = Dio();
          addTearDown(() => dio.close(force: true));
          dio.interceptors.add(
            InterceptorsWrapper(
              onRequest: (options, handler) {
                final payload =
                    jsonDecode(
                          ((options.data as Map)['messages'] as List)
                                  .last['content']
                              as String,
                        )
                        as Map;
                handler.resolve(
                  Response(
                    requestOptions: options,
                    data: {
                      'choices': [
                        {
                          'message': {
                            'content': jsonEncode({
                              'blocks': [
                                for (final item in payload['blocks'] as List)
                                  {'id': item['id'], 'html': modelHtml},
                              ],
                            }),
                          },
                        },
                      ],
                    },
                  ),
                );
              },
            ),
          );
          translated =
              (await EpubTranslationRepository().translateBlockBatchForTest(
                dio: dio,
                config: TranslationConfig.defaults().copyWith(
                  apiBaseUrl: 'https://audit.invalid/v1',
                  apiKey: 'mock',
                  residualQualityCheck: false,
                  maxRetries: 1,
                ),
                blocks: chapter.blocks,
              )).single;
        }
        final rendered = EpubRepacker().renderTranslatedChapter(
          chapter: chapter.copyWith(
            blocks: [
              chapter.blocks.single.copyWith(translatedHtml: translated),
            ],
          ),
          bilingual: false,
        );
        final document = html.parse(rendered);
        final quote = document.querySelector('q')!;
        expect(quote.text, 'Stay hungry.');
        expect(
          quote.attributes['lang'] ?? quote.attributes['xml:lang'],
          'en',
          reason: document.body!.innerHtml,
        );
      },
    );
  }
  for (final failRead in [false, true]) {
    test(
      'merged save preserves existing jobs after read failure=$failRead',
      () async {
        final dir = await Directory.systemTemp.createTemp(
          'audit-v148-history-',
        );
        addTearDown(() => dir.delete(recursive: true));
        final file = File('${dir.path}/history.json');
        final normal = JobHistoryStore(historyFileProvider: () async => file);
        await normal.save([job('old')]);
        final store = JobHistoryStore(
          historyFileProvider: () async =>
              failRead ? ReadFailureFile(file) : file,
        );
        try {
          await store.saveMerged(
            merge: (jobs, _) => [job('new'), ...jobs],
            clearedAtEpochMs: 0,
          );
        } on FileSystemException {
          // Aborting a write on unreadable state is safe.
        }
        expect((await normal.load()).map((e) => e.id), contains('old'));
      },
    );
  }
  for (final scenario in [
    ('chapter.xhtml', 'Cover Story', true),
    ('cover.xhtml', 'Cover', false),
    ('cover_story.xhtml', 'Cover Story', true),
    ('credit_crunch.xhtml', 'Credit Crunch', true),
    ('OPS/cover/chapter1.xhtml', 'Chapter One', true),
    ('OPS/notes/chapter1.xhtml', 'Chapter One', true),
    ('credits.xhtml', 'Credits', false),
    ('cover-2.xhtml', 'Front Image', false),
    ('advertisement.xhtml', 'Advertisement', false),
    ('chapter_ad_2.xhtml', 'Chapter 2', false),
    ('book_cvi_r1.htm', 'Front Image', false),
  ]) {
    test('chapter selection: ${scenario.$1} / ${scenario.$2}', () {
      final chapter = const EpubHtmlExtractor().inspectChapterBytes(
        chapterPath: scenario.$1,
        bytes: utf8.encode(
          '<html><head><title>${scenario.$2}</title></head><body><p>This is the main story of the book.</p></body></html>',
        ),
      );
      expect(chapter.blocks, isNotEmpty);
      expect(chapter.recommendedForTranslation, scenario.$3);
    });
  }
}
