import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_job.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_run_estimate.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_chapter_translator.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_html_extractor.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/footnote_batch_planner.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/protected_anchor_text_slots.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/translation_api_client.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub_isolate_worker.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/translation_cache_store.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/translation_quality.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:xml/xml.dart';

void main() {
  group('性能-#24/#27 cached protected-slot ids', () {
    test('production request reuses the same ordered ids', () {
      final block = ExtractedBlock(
        id: 'p-1',
        tagName: 'p',
        sourceHtml:
            '<p>${List.generate(1000, (i) => 'Text $i<a role="doc-noteref" href="#n$i">*</a>').join()}</p>',
        sourceText: '',
      );
      final slotIds = EpubChapterTranslator.protectedSlotIdsForTest(block);
      final first = slotIds();
      expect(slotIds(), same(first));
      expect(first, List.generate(1000, (i) => 's$i'));
    });
  });

  group('性能-#26 incremental checkpoint serialization', () {
    test(
      'growth, resume, shrink and empty rebuild preserve exact timeline',
      () async {
        final dir = await Directory.systemTemp.createTemp('round10-timeline-');
        addTearDown(() => dir.delete(recursive: true));
        final cache = TranslationCacheStore(cacheRoot: dir);
        const jobKey = 'round10-job';
        const chunkSize = 3000;
        final key = sha256
            .convert(utf8.encode('$jobKey:book-memory'))
            .toString();
        final write =
            await EpubChapterTranslator.bookMemoryCheckpointWriterForTest(
              cacheStore: cache,
              jobKey: jobKey,
              chunkSize: chunkSize,
            );
        final entries = List.generate(
          4,
          (i) => (
            path: 'chapter-"$i\\.xhtml',
            memory: <String, Object?>{
              'bookSummary': 'Summary $i "quoted"\n中\\文',
            },
          ),
        );

        Future<void> verify(
          Future<void> Function(
            List<({String path, Map<String, Object?> memory})>,
          )
          writer,
          List<({String path, Map<String, Object?> memory})> timeline,
        ) async {
          await writer(timeline);
          final state = await cache.loadJobState(key);
          expect(state, isNotNull);
          final decoded =
              jsonDecode(state!.currentChapter) as Map<String, dynamic>;
          expect(decoded.keys, [
            'schema',
            'jobKey',
            'chunkSize',
            'memory',
            'timelineFormat',
            'timelineHead',
            'timelineLength',
            'glossaryEvictionPolicy',
          ]);
          expect(
            decoded['schema'],
            '${EpubChapterTranslator.qualityCacheSchemaVersion}:memory-history-v1',
          );
          expect(decoded['jobKey'], jobKey);
          expect(decoded['chunkSize'], chunkSize);
          final saved = await EpubChapterTranslator.loadBookMemoryTimelineForTest(
            cacheStore: cache, jobKey: jobKey, chunkSize: chunkSize,
          );
          expect(saved.map((e) => e['path']), timeline.map((e) => e.path));
          expect(
            saved.map((e) => (e['memory'] as Map)['bookSummary']),
            timeline.map((e) => e.memory['bookSummary']),
          );
          expect(decoded['timelineLength'], timeline.length);
          // The cached raw JSON has exactly the same bytes as a full encode of
          // the same envelope, including escaped strings and field ordering.
          expect(state.currentChapter, jsonEncode(decoded));
          final resumed =
              await EpubChapterTranslator.loadBookMemoryTimelineForTest(
                cacheStore: cache,
                jobKey: jobKey,
                chunkSize: chunkSize,
              );
          expect(resumed, saved);
        }

        await verify(write, entries.take(1).toList());
        await verify(write, entries.take(2).toList());
        await verify(write, entries.take(2).toList()); // No appended entries.
        final resumedWrite =
            await EpubChapterTranslator.bookMemoryCheckpointWriterForTest(
              cacheStore: cache,
              jobKey: jobKey,
              chunkSize: chunkSize,
              resume: true,
            );
        await verify(resumedWrite, entries.take(3).toList());
        await verify(
          write,
          entries.skip(3).toList(),
        ); // Rebuilt shorter prefix.
        await verify(write, []);
        await verify(write, entries);
      },
    );
  });

  group('性能-#25 nested protected-slot extraction', () {
    String nested(String content) =>
        '<p>${List.filled(250, '<span>Level ').join()}$content'
        '${List.filled(250, ' tail</span>').join()}</p>';

    test('anchor-free deep DOM matches the pre-fix golden', () {
      final source = nested('Leaf &amp; text');
      final template = ProtectedAnchorTextSlots.parse(source);
      expect(template.hasProtectedAnchors, isFalse);
      expect(template.slotTexts, [
        ...List.filled(249, 'Level '),
        'Level Leaf & text tail',
        ...List.filled(249, ' tail'),
      ]);
      expect(template.render(template.slotTexts), source);
    });

    test('deep DOM retains footnote anchors and semantic markers', () {
      final source = nested(
        'Before<a role="doc-noteref" href="#note"><b>1</b></a>'
        '<span epub:type="backlink">↩</span>'
        '<span role="doc-pagebreak">iv</span>After',
      );
      final template = ProtectedAnchorTextSlots.parse(source);
      expect(template.hasProtectedAnchors, isTrue);
      expect(template.slotTexts, [
        ...List.filled(249, 'Level '),
        'Level Before',
        'After tail',
        ...List.filled(249, ' tail'),
      ]);
      expect(template.render(template.slotTexts), source);
    });
  });

  group('P2-#14 literal angle brackets in book titles', () {
    test('XML text title allows a generic type parameter', () {
      const title = 'Introduction to Generics <T>';
      expect(
        EpubChapterTranslator.cleanBookTitleForTest(
          title,
          checkHtmlTags: false,
        ),
        title,
      );
      expect(
        () => EpubChapterTranslator.cleanBookTitleForTest(title),
        throwsA(isA<TranslationParseException>()),
      );
    });
    // Existing cleanup deliberately peels **title** and explanation prefixes.
    // Wrappers left after that cleanup must still fail with HTML checks off.
    for (final raw in [
      '`title`',
      'title\n**extra**\n---',
      'Sure, here is the translation: ```text\ntitle',
      '{"title":"title"}',
      '<b>中文书名</b>',
    ]) {
      test('residual wrapper rejects $raw', () {
        expect(
          () => EpubChapterTranslator.cleanBookTitleForTest(
            raw,
            checkHtmlTags: false,
          ),
          throwsA(isA<TranslationParseException>()),
        );
      });
    }
  });

  test('P2-#15 merged body fallback excludes protected code text', () {
    final result = EpubChapterTranslator.lockHtmlStructureForTest(
      sourceHtml: '<p>Use <em>this command</em>: <code>foo()</code> today.</p>',
      translatedHtml: '<p>今天使用这个命令：<code>foo()</code></p>',
    );
    expect('foo()'.allMatches(result), hasLength(1));
    final dom = html_parser.parseFragment(result);
    expect(dom.querySelector('code')!.text, 'foo()');
    expect(dom.text, '今天使用这个命令：foo()');
    expect(dom.querySelector('em')!.text, isEmpty);
  });

  group('P2-#18 footnote degradation throughput', () {
    for (final protected in [false, true]) {
      for (final successful in [0, 1]) {
        test('$successful successful footnotes, protected=$protected', () async {
          final dir = await Directory.systemTemp.createTemp('round10-notes-');
          addTearDown(() => dir.delete(recursive: true));
          final html =
              '<html><body>${List.generate(10, (i) => '<p>Footnote text $i.${protected ? '<a href="#n$i">*</a>' : ''}</p>').join()}</body></html>';
          final chapter = const EpubHtmlExtractor().inspectChapterBytes(
            chapterPath: 'notes.xhtml',
            bytes: utf8.encode(html),
          );
          expect(chapter.blocks, hasLength(10));
          expect(
            FootnoteBatchPlanner.isStandaloneFootnoteChapter(chapter),
            isTrue,
          );
          final archive = Archive();
          for (final entry in {
            'mimetype': 'application/epub+zip',
            'META-INF/container.xml':
                '<container><rootfiles><rootfile full-path="content.opf"/></rootfiles></container>',
            'content.opf':
                '<package xmlns="http://www.idpf.org/2007/opf" version="2.0">'
                '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>Original Title</dc:title></metadata>'
                '<manifest><item id="notes" href="notes.xhtml" media-type="application/xhtml+xml"/></manifest>'
                '<spine><itemref idref="notes"/></spine></package>',
            'notes.xhtml': html,
          }.entries) {
            archive.addFile(ArchiveFile.string(entry.key, entry.value));
          }
          final input = File('${dir.path}/book.epub');
          await input.writeAsBytes(ZipEncoder().encodeBytes(archive));
          final ticks = <TranslationJob>[];
          final logs = <String>[];
          final api = _DegradedFootnoteClient(successful: successful);
          final result =
              await EpubChapterTranslator(
                apiClient: api,
                cacheStore: TranslationCacheStore(
                  cacheRoot: Directory('${dir.path}/cache'),
                ),
              ).translateChapters(
                inputPath: input.path,
                outputDirectory: dir.path,
                config: _slotConfig(),
                chapters: [chapter],
                cancelToken: CancelToken(),
                onProgress: (job, line) {
                  ticks.add(job);
                  logs.add(line);
                },
              );
          expect(api.blockRequests, greaterThan(0));
          expect(result.job.completedBlocks, 10);
          expect(result.job.totalBlocks, 10);
          expect(result.job.apiDegradedBlocks, 10 - successful);
          expect(result.job.degradedBlockCount, 10 - successful);
          expect(result.job.cachedBlocks, 0);
          expect(result.job.progress, 1);
          expect(
            TranslationRunEstimate.apiTranslatedBlocksForThroughput(result.job),
            successful,
          );
          expect(
            result.job.status,
            successful == 0
                ? TranslationJobStatus.failed
                : TranslationJobStatus.completedWithWarnings,
          );
          expect(
            ticks.any((job) => job.completedBlocks == 10 && job.progress == 1),
            isTrue,
          );
          for (final tick in ticks.where((job) => job.completedBlocks > 0)) {
            if (tick.completedFiles < tick.totalFiles) {
              expect(tick.progress, tick.completedBlocks / tick.totalBlocks);
            }
            expect(
              TranslationRunEstimate.apiTranslatedBlocksForThroughput(tick),
              inInclusiveRange(0, successful),
            );
          }
          expect(
            logs.singleWhere((line) => line.contains('new blocks')),
            contains('Translated $successful new blocks'),
          );
          final output = await EpubIsolateWorker.loadArchiveFiles(
            result.job.outputPath,
          );
          final opf = utf8.decode(output['content.opf']!);
          expect(opf, contains('&lt;T'));
          expect(
            XmlDocument.parse(opf).findAllElements('dc:title').single.innerText,
            'Introduction to Generics <T>',
          );
        });
      }
    }
  });

  group('P2-#12 protected-slot HTML comment validation', () {
    const block = ExtractedBlock(
      id: 'p-1',
      tagName: 'p',
      sourceHtml:
          '<p>Use &lt;!-- note --&gt; to annotate<a href="#note-1">*</a></p>',
      sourceText: 'Use <!-- note --> to annotate*',
    );
    const translated = '使用 <!-- note --> 添加注释';

    for (final forceIndividual in [false, true]) {
      test(
        forceIndividual
            ? 'individual fallback still rejects HTML comments'
            : 'batch accepts comment literals and escapes them without fallback',
        () async {
          final api = _CommentSlotClient(
            translated,
            forceIndividual: forceIndividual,
          );
          final dio = Dio();
          addTearDown(() => dio.close(force: true));
          final translator = EpubChapterTranslator(apiClient: api);
          final result = await translator.translateBlockBatchForTest(
            dio: dio,
            config: TranslationConfig.defaults().copyWith(
              apiKey: 'test-key',
              targetLanguage: 'Chinese',
              residualQualityCheck: false,
              styleProfileEnabled: false,
              maxRetries: 1,
            ),
            blocks: [block],
          );

          expect(api.batchRequests, 1);
          expect(api.individualRequests, forceIndividual ? 1 : 0);
          if (forceIndividual) {
            expect(result, [block.sourceHtml]);
            expect(translator.getDegradedBlockIdsForTest(), hasLength(1));
          } else {
            expect(result.single, contains('&lt;!-- note --&gt;'));
            expect(result.single, isNot(contains('<!-- note -->')));
            expect(result.single, contains('href="#note-1"'));
            expect(
              html_parser.parseFragment(result.single).text,
              '$translated*',
            );
            expect(translator.getDegradedBlockIdsForTest(), isEmpty);
          }
        },
      );
    }
  });

  group('P2-#13 protected-slot quoted translations', () {
    for (final source in ['“Hello”', '"Hello"', 'Hello']) {
      test('$source with straight-quoted translation', () async {
        final block = ExtractedBlock(
          id: 'p-1',
          tagName: 'p',
          sourceHtml: '<p>$source<a href="#note-1">*</a></p>',
          sourceText: '$source*',
        );
        final api = _CommentSlotClient('"你好"', forceIndividual: false);
        final dio = Dio();
        addTearDown(() => dio.close(force: true));
        final translator = EpubChapterTranslator(apiClient: api);
        final result = await translator.translateBlockBatchForTest(
          dio: dio,
          config: _slotConfig(),
          blocks: [block],
        );
        final rejected = source == 'Hello';
        expect(api.batchRequests, 1);
        expect(api.individualRequests, rejected ? 1 : 0);
        if (rejected) {
          expect(result, [block.sourceHtml]);
          expect(translator.getDegradedBlockIdsForTest(), {
            EpubChapterTranslator.degradedKeyForTest(blockId: block.id),
          });
        } else {
          expect(html_parser.parseFragment(result.single).text, '"你好"*');
          expect(translator.getDegradedBlockIdsForTest(), isEmpty);
        }
      });
    }
  });

  test('P2-#17 individual fallback bounds huge neighbor context', () async {
    // Quotes, backslashes and newlines also exercise JSON serialization after
    // truncation. Put the same huge neighbor on each side of the tiny slot.
    final huge = List.filled(1000, 'Neighbor "quoted" \\ text\n').join();
    final escaped = const HtmlEscape(HtmlEscapeMode.element).convert(huge);
    final block = ExtractedBlock(
      id: 'p-1',
      tagName: 'p',
      sourceHtml:
          '<p>$escaped<a href="#n1">*</a>Tiny'
          '<a href="#n2">*</a>$escaped</p>',
      sourceText: '$huge*Tiny*$huge',
    );
    final api = _CommentSlotClient('译文', forceIndividual: true);
    final dio = Dio();
    addTearDown(() => dio.close(force: true));
    final translator = EpubChapterTranslator(apiClient: api);
    await translator.translateBlockBatchForTest(
      dio: dio,
      config: _slotConfig(),
      blocks: [block],
    );
    expect(api.individualRequests, 3);
    expect(api.individualContexts.first['previousText'], isNull);
    expect(api.individualContexts.last['nextText'], isNull);
    final tinyContext = api.individualContexts[1];
    for (final key in ['previousText', 'nextText']) {
      expect((tinyContext[key] as String).length, 600);
      expect(tinyContext[key], huge.substring(0, 600));
    }
    for (final context in api.individualContexts) {
      expect(
        (context['blockSummary'] as String).length,
        lessThanOrEqualTo(600),
      );
      for (final key in ['previousText', 'nextText']) {
        final text = context[key] as String?;
        if (text != null) expect(text.length, lessThanOrEqualTo(600));
      }
    }
    expect(translator.getDegradedBlockIdsForTest(), isEmpty);
  });

  group('P2-#16 supplementary CJK quality detection', () {
    for (final text in ['Hello world', '123', '\u{20000}', '\u{2FA1D}']) {
      test('work-title gate detects CJK only in $text', () {
        final finding = TranslationQuality.findSuspiciousHtmlResidual(
          sourceHtml:
              '<p><cite>Original Title</cite>'
              '<cite>Another Title</cite></p>',
          translatedHtml: '<p><cite>$text</cite></p>',
          targetLanguage: 'Chinese',
        );
        if (text == 'Hello world' || text == '123') {
          expect(finding?.kind, TranslationResidualKind.longSourceText);
        } else {
          expect(finding, isNull);
        }
      });
    }
    for (final cjk in ['\u{20000}', '\u{2FA1D}']) {
      for (final translatedFirst in [true, false]) {
        test('parenthetical gloss direction $translatedFirst with $cjk', () {
          TranslationResidualFinding? check(String context) =>
              TranslationQuality.findSuspiciousHtmlResidual(
                sourceHtml: '<p>A short source.</p>',
                translatedHtml: translatedFirst
                    ? '<p>$context(中assarting)</p>'
                    : '<p>中assarting($context)</p>',
                targetLanguage: 'Chinese',
              );
          expect(
            check('Hello world')?.kind,
            TranslationResidualKind.cjkAdjacentLowercaseWord,
          );
          expect(check(cjk), isNull);
        });
      }
    }
  });
}

TranslationConfig _slotConfig() => TranslationConfig.defaults().copyWith(
  apiKey: 'test-key',
  targetLanguage: 'Chinese',
  residualQualityCheck: false,
  styleProfileEnabled: false,
  maxRetries: 1,
);

class _DegradedFootnoteClient extends TranslationApiClient {
  _DegradedFootnoteClient({required this.successful});

  final int successful;
  int blockRequests = 0;

  @override
  Future<Response<dynamic>> postChatCompletions({
    required Dio dio,
    required Map<String, dynamic> data,
    CancelToken? cancelToken,
  }) async {
    final user = (data['messages'] as List).last['content'] as String;
    String content = 'Introduction to Generics <T>';
    if (user.startsWith('{')) {
      final payload = jsonDecode(user) as Map<String, dynamic>;
      final blocks = payload['blocks'] as List?;
      if (blocks != null) {
        blockRequests++;
        content = jsonEncode({
          'blocks': [
            for (final block in blocks)
              if (block['slots'] != null)
                {
                  'id': block['id'],
                  'slots': [
                    for (final slot in block['slots'] as List)
                      {
                        'id': slot['id'],
                        'text': successful > 0 && block['id'] == 'f0:p-1'
                            ? '成功译文'
                            : '```',
                      },
                  ],
                }
              else
                {
                  'id': block['id'],
                  'html': successful > 0 && block['id'] == 'f0:p-1'
                      ? '<p>成功译文</p>'
                      : '',
                },
          ],
        });
      } else {
        content = '{}';
      }
    } else if (user.startsWith('Translate')) {
      content = '```';
    }
    return Response(
      requestOptions: RequestOptions(),
      data: {
        'choices': [
          {
            'message': {'content': content},
          },
        ],
      },
    );
  }
}

class _CommentSlotClient extends TranslationApiClient {
  _CommentSlotClient(this.translation, {required this.forceIndividual});

  final String translation;
  final bool forceIndividual;
  int batchRequests = 0;
  int individualRequests = 0;
  final individualContexts = <Map<String, dynamic>>[];

  @override
  Future<Response<dynamic>> postChatCompletions({
    required Dio dio,
    required Map<String, dynamic> data,
    CancelToken? cancelToken,
  }) async {
    final user = (data['messages'] as List).last['content'] as String;
    final String content;
    if (user.startsWith('{')) {
      batchRequests++;
      final payload = jsonDecode(user) as Map<String, dynamic>;
      content = forceIndividual
          ? 'invalid JSON'
          : jsonEncode({
              'blocks': [
                for (final block in payload['blocks'] as List)
                  {
                    'id': block['id'],
                    'slots': [
                      for (final slot in block['slots'] as List)
                        {'id': slot['id'], 'text': translation},
                    ],
                  },
              ],
            });
    } else {
      individualRequests++;
      final messages = data['messages'] as List;
      final contextMessage = messages[messages.length - 2]['content'] as String;
      individualContexts.add(
        jsonDecode(contextMessage.substring(contextMessage.indexOf('\n') + 1))
            as Map<String, dynamic>,
      );
      content = translation;
    }
    return Response(
      requestOptions: RequestOptions(),
      data: {
        'choices': [
          {
            'message': {'content': content},
          },
        ],
      },
    );
  }
}
