import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/domain/repositories/translation_repository.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_chapter_translator.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_html_extractor.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_repacker.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/footnote_batch_planner.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/translation_api_client.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/translation_batch_planner.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/translation_cache_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logger/logger.dart';

InspectedChapter _chapter(
  String title,
  String path, {
  String text = 'Original prose.',
}) {
  return const EpubHtmlExtractor()
      .inspectChapterBytes(
        chapterPath: path,
        bytes: utf8.encode(
          '<html><head><title>$title</title></head><body><p>$text</p></body></html>',
        ),
      )
      .copyWith(
        title: title,
        category: ChapterCategory.content,
        includeInTranslation: true,
      );
}

Map<String, Object?> _fullGlossary({bool locked = false}) => {
  'bookSummary': 'A summary',
  'styleGuide': ['Be precise'],
  'glossary': [
    for (int i = 0; i < 32; i++)
      {
        'source': 'term$i',
        'target': '译$i',
        'lastUsed': '${i + 1}',
        if (locked && i == 0) 'locked': 'true',
      },
  ],
  'styleProfile': {'primaryGenre': 'memoir', 'confidence': 'high'},
  'styleProfileConfirmed': true,
};

Future<void> _writeEpub(File input, List<InspectedChapter> chapters) async {
  final archive = Archive();
  for (final entry in {
    'mimetype': 'application/epub+zip',
    'META-INF/container.xml':
        '<container><rootfiles><rootfile full-path="OPS/content.opf"/></rootfiles></container>',
    'OPS/content.opf':
        '<package><metadata><dc:title xmlns:dc="http://purl.org/dc/elements/1.1/">Book</dc:title></metadata></package>',
    for (final c in chapters) c.path: c.originalHtml,
  }.entries) {
    final bytes = utf8.encode(entry.value);
    archive.addFile(ArchiveFile(entry.key, bytes.length, bytes));
  }
  await input.writeAsBytes(ZipEncoder().encode(archive));
}

Map<String, Object?> _mention(String source, {String target = '新译'}) => {
  'title': 'chapter',
  'summary': 'summary',
  'glossary': [
    {'source': source, 'target': target},
  ],
};

List<Map<dynamic, dynamic>> _terms(Map<String, Object?> memory) =>
    (memory['glossary'] as List).cast<Map<dynamic, dynamic>>();

class _Api extends TranslationApiClient {
  final List<Map<String, dynamic>> requests = [];
  final List<String> replies = [];
  int initialMemoryCalls = 0;
  int chapterMemoryCalls = 0;
  int jsonCalls = 0;
  int individualCalls = 0;

  @override
  Dio buildDio(TranslationConfig config) =>
      Dio(BaseOptions(baseUrl: config.apiBaseUrl));

  @override
  Future<Response<dynamic>> postChatCompletions({
    required Dio dio,
    required Map<String, dynamic> data,
    CancelToken? cancelToken,
  }) async {
    requests.add(data);
    final messages = data['messages'] as List;
    final user = messages.last['content'] as String;
    Object reply;
    if (user.startsWith('{')) {
      final payload = jsonDecode(user) as Map<String, dynamic>;
      if (payload['kind'] == 'initialBookMemory') {
        initialMemoryCalls++;
        reply = {
          'bookSummary': 'Persistent summary',
          'glossary': [
            {'source': 'prose', 'target': '散文'},
          ],
        };
      } else if (payload['kind'] == 'chapterMemory') {
        chapterMemoryCalls++;
        reply = _mention('continuity');
      } else {
        jsonCalls++;
        reply = replies.isNotEmpty
            ? replies.removeAt(0)
            : {
                'blocks': [
                  for (final b in payload['blocks'] as List)
                    {'id': b['id'], 'html': '<p>这是一段已翻译的文字。</p>'},
                ],
              };
      }
    } else {
      individualCalls++;
      reply = '<p>这是一段已翻译的文字。</p>';
    }
    return Response(
      requestOptions: RequestOptions(),
      data: {
        'choices': [
          {
            'message': {'content': reply is String ? reply : jsonEncode(reply)},
          },
        ],
      },
    );
  }
}

class _Repacker extends EpubRepacker {
  List<InspectedChapter> received = [];
  @override
  Future<void> writeTranslatedEpub({
    Set<String> reviewChapterPaths = const {},
    Map<String, Object?>? reviewSnapshots,
    required String inputPath,
    required String outputFilePath,
    required TranslationConfig config,
    required List<InspectedChapter> chapters,
    CancelToken? cancelToken,
    bool Function()? isCancelled,
    Set<String> degradedBlockIds = const {},
    String? translatedTitle,
    void Function(int, int)? onProgress,
  }) async {
    received = chapters;
    for (final c in chapters) {
      expect(
        c.originalHtml,
        isNotEmpty,
        reason: 'repack skeleton was reloaded',
      );
      expect(c.blocks.every((b) => b.sourceHtml.isEmpty), isTrue);
    }
    await File(outputFilePath).writeAsString('translated epub');
  }
}

void main() {
  final config = TranslationConfig.defaults().copyWith(
    apiBaseUrl: 'https://example.com/v1',
    apiKey: 'test-key',
    model: 'test',
    residualQualityCheck: false,
    styleProfileEnabled: false,
    maxRetries: 3,
  );

  test(
    'A1 word boundaries retain Discovery/Recovery and exclude real structure',
    () {
      final samples = EpubChapterTranslator.styleProfileSourceChaptersForTest([
        _chapter('Discovery', 'index-directory/self-discovery.xhtml'),
        _chapter('Recovery', 'Text/recovery.xhtml'),
        _chapter('Cover', 'Text/cover.xhtml'),
        _chapter('Copyright', 'Text/copyright.xhtml'),
        _chapter('Table of Contents', 'Text/contents.xhtml'),
        _chapter('Opaque', 'Text/book_toc_page.xhtml'),
      ]);
      expect(samples.map((s) => s['title']), ['Discovery', 'Recovery']);
    },
  );

  test('A1 front matter words do not match reintroduction/prologuesque', () {
    final samples = EpubChapterTranslator.styleProfileSourceChaptersForTest([
      _chapter(
        'Reintroduction',
        'reintroduction.xhtml',
      ).copyWith(category: ChapterCategory.frontMatter),
      _chapter(
        'Prologuesque',
        'prologuesque.xhtml',
      ).copyWith(category: ChapterCategory.frontMatter),
      _chapter(
        'Preface',
        'preface.xhtml',
      ).copyWith(category: ChapterCategory.frontMatter),
      _chapter('Body', 'body.xhtml'),
    ]);
    expect(
      samples.where((s) => s['role'] == 'frontMatter').map((s) => s['title']),
      ['Preface'],
    );
  });

  test('A2 capacity eviction is LRU and emits the evicted term', () {
    final events = <String>[];
    void listen(OutputEvent event) => events.addAll(event.lines);
    Logger.addOutputListener(listen);
    addTearDown(() => Logger.removeOutputListener(listen));
    var memory = EpubChapterTranslator.mergeBookMemoryForTest(
      _fullGlossary(),
      _mention('term0'),
    );
    memory = EpubChapterTranslator.mergeBookMemoryForTest(
      memory,
      _mention('new'),
    );
    expect(_terms(memory), hasLength(32));
    expect(_terms(memory).map((e) => e['source']), contains('term0'));
    expect(_terms(memory).map((e) => e['source']), isNot(contains('term1')));
    expect(events.join('\n'), contains('LRU evicted: term1'));
  });

  test('A2 locked terms retain their mapping when full', () {
    var memory = EpubChapterTranslator.mergeBookMemoryForTest(
      _fullGlossary(locked: true),
      _mention('new'),
    );
    expect(_terms(memory).map((e) => e['source']), contains('term0'));
    expect(_terms(memory).map((e) => e['source']), isNot(contains('term1')));
    memory = EpubChapterTranslator.mergeBookMemoryForTest(
      memory,
      _mention('term0', target: 'wrong'),
    );
    expect(
      _terms(memory).singleWhere((e) => e['source'] == 'term0')['target'],
      '译0',
    );
  });

  test('A3 HTML byte budget covers markup, not just visible prose', () {
    const text = 'A short sentence.';
    final html =
        '<p>${List.generate(200, (_) => '<span class="rich-markup">$text</span>').join()}</p>';
    final estimate = EpubChapterTranslator.htmlBudgetTokensForTest(html);
    expect(
      EpubChapterTranslator.htmlBudgetTokensForTest('<p><em>$text</em></p>'),
      greaterThan(EpubChapterTranslator.htmlBudgetTokensForTest(text)),
    );
    expect(
      estimate,
      greaterThanOrEqualTo((utf8.encode(html).length / 4 * 1.2).ceil()),
    );
    expect(
      estimate,
      greaterThan(
        EpubChapterTranslator.htmlBudgetTokensForTest(
          List.filled(200, text).join(),
        ),
      ),
    );
  });

  test('A3 actual HTML request receives its serialized budget', () async {
    final api = _Api();
    await EpubChapterTranslator(apiClient: api).translateBlockBatchForTest(
      dio: api.buildDio(config),
      config: config,
      blocks: _chapter('Body', 'body.xhtml').blocks,
    );
    final budget = EpubChapterTranslator.requestBudgetForTest(
      api.requests.single,
    );
    expect(
      api.requests.single['max_tokens'] as int,
      greaterThanOrEqualTo(budget.totalTokens),
    );
  });

  test(
    'A4 footnote budget includes real system/style/locks/idiomatic context',
    () async {
      final chapter = _chapter('Footnotes', 'footnotes.xhtml');
      Future<Map<String, dynamic>> request(TranslationConfig cfg) async {
        final api = _Api();
        await EpubChapterTranslator(
          apiClient: api,
        ).translateFootnoteBatchForTest(
          dio: api.buildDio(cfg),
          config: cfg,
          references: [
            FootnoteBlockReference(
              chapterIndex: 0,
              chapter: chapter,
              block: chapter.blocks.single,
            ),
          ],
          bookMemory: _fullGlossary(),
        );
        return api.requests.single;
      }

      final styledConfig = config.copyWith(styleProfileEnabled: true);
      final plain = await request(styledConfig);
      final locked = await request(
        styledConfig.copyWith(lockedGlossary: 'prose=散文\nterm=术语'),
      );
      final budget = EpubChapterTranslator.requestBudgetForTest(locked);
      expect(
        locked['max_tokens'] as int,
        greaterThanOrEqualTo(budget.fixedTokens + budget.payloadTokens),
      );
      expect(
        locked['max_tokens'] as int,
        greaterThan(plain['max_tokens'] as int),
      );
      expect(
        (locked['messages'] as List).first['content'],
        contains('Locked terminology'),
      );
      expect((locked['messages'] as List).first['content'], contains('memoir'));
    },
  );

  test(
    'A5 chunkSize isolates both block caches and progress identities',
    () async {
      final temp = await Directory.systemTemp.createTemp('a-quality-cache-');
      addTearDown(() => temp.delete(recursive: true));
      final cache = TranslationCacheStore(cacheRoot: temp);
      final chapter = _chapter('Body', 'body.xhtml');
      String blockKey(TranslationConfig cfg) =>
          EpubChapterTranslator.blockCacheKeyForTest(
            config: cfg,
            block: chapter.blocks.single,
            chapterPath: chapter.path,
          );
      final changed = config.copyWith(chunkSize: config.chunkSize + 1);
      await cache.putBlockTranslation(blockKey(config), '<p>译文</p>');
      expect(await cache.getBlockTranslation(blockKey(changed)), isNull);
      expect(
        EpubChapterTranslator.jobKeyForTest(
          inputFingerprint: 'book',
          config: config,
          chapters: [chapter],
        ),
        isNot(
          EpubChapterTranslator.jobKeyForTest(
            inputFingerprint: 'book',
            config: changed,
            chapters: [chapter],
          ),
        ),
      );
      await EpubChapterTranslator.saveBookMemoryCheckpointForTest(
        cacheStore: cache,
        jobKey: 'job',
        chunkSize: config.chunkSize,
        memory: _fullGlossary(),
      );
      expect(
        await EpubChapterTranslator.loadBookMemoryCheckpointForTest(
          cacheStore: cache,
          jobKey: 'job',
          chunkSize: changed.chunkSize,
        ),
        isNull,
      );
      await cache.waitForMaintenanceForTest();
    },
  );

  test(
    'A6 release clears sources, retains metadata/translation, and retry reloads',
    () async {
      final temp = await Directory.systemTemp.createTemp('a-quality-source-');
      addTearDown(() => temp.delete(recursive: true));
      final source = _chapter('Body', 'body.xhtml');
      final completed = source.copyWith(
        translatedBody: '译文',
        blocks: [source.blocks.single.copyWith(translatedHtml: '<p>译文</p>')],
      );
      final released = await EpubChapterTranslator.releaseChapterSourcesForTest(
        completed,
        temp,
      );
      expect(released.originalHtml, isEmpty);
      expect(released.body, isEmpty);
      expect(released.blocks.single.sourceHtml, isEmpty);
      expect(released.blocks.single.sourceText, isEmpty);
      expect(released.path, completed.path);
      expect(released.title, completed.title);
      expect(released.blocks.single.id, completed.blocks.single.id);
      expect(released.blocks.single.translatedHtml, '<p>译文</p>');
      final restored = await EpubChapterTranslator.restoreChapterSourcesForTest(
        released,
        temp,
      );
      expect(restored.originalHtml, completed.originalHtml);
      expect(
        restored.blocks.single.sourceHtml,
        completed.blocks.single.sourceHtml,
      );
      expect(
        restored.blocks.single.sourceText,
        completed.blocks.single.sourceText,
      );
      expect(restored.blocks.single.translatedHtml, '<p>译文</p>');
    },
  );

  test('A7 extreme planner inputs fall back safely and log warnings', () {
    final events = <String>[];
    void listen(OutputEvent event) => events.addAll(event.lines);
    Logger.addOutputListener(listen);
    addTearDown(() => Logger.removeOutputListener(listen));
    const planner = TranslationBatchPlanner(
      contextBeforeBlockCount: -1,
      contextAfterBlockCount: -5,
      contextTextLimit: -1,
      tinyBlockBudget: 0,
      tinyBlockHtmlThreshold: -1,
      tinyBlockTextThreshold: 100000000,
    );
    final blocks = [
      for (int i = 0; i < 5; i++)
        _chapter('Body', '$i.xhtml').blocks.single.copyWith(id: '$i'),
    ];
    for (final chunk in [0, -1, 1000000000]) {
      final batches = planner.plan(
        pendingBlocks: blocks,
        chapterBlocks: blocks,
        chunkSize: chunk,
      );
      expect(batches.expand((b) => b.blocks).map((b) => b.id), [
        '0',
        '1',
        '2',
        '3',
        '4',
      ]);
      expect(batches.every((b) => b.blocks.isNotEmpty), isTrue);
      expect(
        batches.every(
          (b) => b.context.before.length <= 2 && b.context.after.length <= 1,
        ),
        isTrue,
      );
    }
    expect(planner.trimContextText('x' * 300).length, 240);
    expect(planner.contextBeforeBlockCount, 2);
    expect(planner.tinyBlockBudget, 48);
    expect(events.join('\n'), contains('Invalid chunkSize:0=0'));
    expect(events.join('\n'), contains('Invalid contextBeforeBlockCount=-1'));
  });

  test(
    'A6 missing spool reloads the fingerprint-guarded EPUB and keeps translations',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'a-quality-archive-reload-',
      );
      addTearDown(() => temp.delete(recursive: true));
      final input = File('${temp.path}/book.epub');
      final source = _chapter('Body', 'OPS/body.xhtml');
      await _writeEpub(input, [source]);
      final completed = source.copyWith(
        sourceIdentity: EpubSourceIdentity(
          inputPath: input.path,
          sha256: sha256.convert(await input.readAsBytes()).toString(),
        ),
        translatedBody: '译文',
        blocks: [source.blocks.single.copyWith(translatedHtml: '<p>译文</p>')],
      );
      final released = await EpubChapterTranslator.releaseChapterSourcesForTest(
        completed,
        temp,
      );
      await for (final file in temp.list()) {
        if (file.path.endsWith('.json')) await file.delete();
      }
      final restored = await EpubChapterTranslator.restoreChapterSourcesForTest(
        released,
        temp,
      );
      expect(restored.originalHtml, source.originalHtml);
      expect(
        restored.blocks.single.sourceText,
        source.blocks.single.sourceText,
      );
      expect(restored.blocks.single.translatedHtml, '<p>译文</p>');
      // A changed archive must never silently restore a different chapter.
      await input.writeAsBytes([0], mode: FileMode.append);
      await expectLater(
        EpubChapterTranslator.restoreChapterSourcesForTest(released, temp),
        throwsA(isA<FormatException>()),
      );
    },
  );

  for (final reply in [
    '{}',
    '{"blocks":[{"id":"wrong","html":"<p>译文</p>"}]}',
    '{"blocks":[{"id":"p-1"}]}',
  ]) {
    test('A8 deterministic structure only sends JSON once: $reply', () async {
      final api = _Api()..replies.add(reply);
      final result = await EpubChapterTranslator(apiClient: api)
          .translateBlockBatchForTest(
            dio: api.buildDio(config),
            config: config,
            blocks: _chapter('Body', 'body.xhtml').blocks,
          );
      expect(api.jsonCalls, 1);
      expect(api.individualCalls, 1);
      expect(result.single, contains('已翻译'));
    });
  }

  for (final jitter in [
    '```json\n{"blocks":',
    '{"blocks":[',
    '{"blocks":[],}',
  ]) {
    test('A8 format jitter retries and succeeds: $jitter', () async {
      final api = _Api()..replies.add(jitter);
      final result = await EpubChapterTranslator(apiClient: api)
          .translateBlockBatchForTest(
            dio: api.buildDio(config),
            config: config,
            blocks: _chapter('Body', 'body.xhtml').blocks,
          );
      expect(api.jsonCalls, 2);
      expect(api.individualCalls, 0);
      expect(result.single, contains('已翻译'));
    });
  }

  test(
    'A9 disk round-trip preserves style, locks and LRU; rejects old schema',
    () async {
      final temp = await Directory.systemTemp.createTemp('a-quality-memory-');
      addTearDown(() => temp.delete(recursive: true));
      final cache = TranslationCacheStore(cacheRoot: temp);
      final memory = EpubChapterTranslator.mergeBookMemoryForTest(
        _fullGlossary(locked: true),
        _mention('term1'),
      );
      await EpubChapterTranslator.saveBookMemoryCheckpointForTest(
        cacheStore: cache,
        jobKey: 'job',
        chunkSize: 3000,
        memory: memory,
      );
      final restored =
          await EpubChapterTranslator.loadBookMemoryCheckpointForTest(
            cacheStore: TranslationCacheStore(cacheRoot: temp),
            jobKey: 'job',
            chunkSize: 3000,
          );
      expect(restored, memory);
      final after = EpubChapterTranslator.mergeBookMemoryForTest(
        restored!,
        _mention('new'),
      );
      expect(
        _terms(after).map((e) => e['source']),
        containsAll(['term0', 'term1', 'new']),
      );
      expect(_terms(after).map((e) => e['source']), isNot(contains('term2')));
      await EpubChapterTranslator.saveBookMemoryCheckpointForTest(
        cacheStore: cache,
        jobKey: 'job',
        chunkSize: 3000,
        memory: memory,
        schema: 'v15',
      );
      expect(
        await EpubChapterTranslator.loadBookMemoryCheckpointForTest(
          cacheStore: cache,
          jobKey: 'job',
          chunkSize: 3000,
        ),
        isNull,
      );
    },
  );

  test(
    'A9 interrupted run restores memory without paying for initial generation again',
    () async {
      final temp = await Directory.systemTemp.createTemp('a-quality-resume-');
      addTearDown(() => temp.delete(recursive: true));
      final chapters = [
        _chapter('One', 'OPS/one.xhtml'),
        _chapter('Two', 'OPS/two.xhtml'),
      ];
      final input = File('${temp.path}/book.epub');
      await _writeEpub(input, chapters);
      final cache = TranslationCacheStore(
        cacheRoot: Directory('${temp.path}/cache'),
      );
      final api = _Api();
      final repacker = _Repacker();
      final translator = EpubChapterTranslator(
        cacheStore: cache,
        apiClient: api,
        repacker: repacker,
      );
      final cancel = CancelToken();
      await expectLater(
        translator.translateChapters(
          inputPath: input.path,
          outputDirectory: temp.path,
          config: config,
          chapters: chapters,
          cancelToken: cancel,
          onProgress: (job, line) {
            if (job.completedBlocks == 1) cancel.cancel();
          },
        ),
        throwsA(isA<TranslationCancelledException>()),
      );
      expect(api.initialMemoryCalls, 1);
      final result = await translator.translateChapters(
        inputPath: input.path,
        outputDirectory: temp.path,
        config: config,
        chapters: chapters,
        cancelToken: CancelToken(),
      );
      expect(result.job.completedBlocks, 2);
      expect(result.job.resumedBlocks, 1);
      expect(api.initialMemoryCalls, 1);
      expect(api.chapterMemoryCalls, 1);
      expect(
        result.chapters.every(
          (c) => c.blocks.every(
            (b) => b.sourceHtml.isEmpty && b.sourceText.isEmpty,
          ),
        ),
        isTrue,
      );
      expect(repacker.received, hasLength(2));
      final memoryUser =
          (api.requests.lastWhere((r) {
                        final user =
                            (r['messages'] as List).last['content'] as String;
                        return user.startsWith('{') &&
                            jsonDecode(user)['blocks'] != null;
                      })['messages']
                      as List)
                  .last['content']
              as String;
      expect(memoryUser, contains('Persistent summary'));
      await cache.waitForMaintenanceForTest();
    },
  );
}
