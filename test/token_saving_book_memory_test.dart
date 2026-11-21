import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/job_resume_state.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/domain/repositories/translation_repository.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_chapter_translator.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_html_extractor.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/translation_api_client.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/translation_cache_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'helpers/memory_history_cache.dart';

void main() {
  test(
    'short chapters share a memory request and the last chapter needs none',
    () async {
      final book = await _BookFixture.create();
      final regular = _FakeApi();
      await book.translate(
        regular,
        book.newCache('regular'),
        tokenSaving: false,
      );
      expect(regular.singleUpdates, hasLength(7));
      expect(regular.batchUpdates, isEmpty);

      final saving = _FakeApi();
      await book.translate(saving, book.newCache('saving'));
      expect(saving.singleUpdates, isEmpty);
      expect(saving.batchUpdates.map(_titles), [
        ['Section 1', 'Section 2', 'Section 3', 'Section 4'],
      ]);
    },
  );

  test(
    'the sole useful update flushes before the last pending chapter',
    () async {
      final book = await _BookFixture.create(chapterCount: 3);
      final api = _FakeApi();
      await book.translate(api, book.newCache('saving'));
      expect(api.batchUpdates.map(_titles), [
        ['Section 1', 'Section 2'],
      ]);
    },
  );

  test(
    'novel terms refresh early and locked targets survive grouped updates',
    () async {
      final book = await _BookFixture.create(
        overrides: {
          2: 'The lantern came from Saffron Harbor.',
          6: 'They returned to Saffron Harbor.',
        },
        footnoteIndex: 4,
      );
      final cache = book.newCache('saving');
      final api = _FakeApi();
      await book.translate(api, cache);
      final batchTitles = api.batchUpdates.map(_titles).toList();
      expect(batchTitles.first, ['Section 1', 'Section 2']);
      expect(batchTitles[1], ['Section 3']);
      expect(
        batchTitles.expand((titles) => titles),
        isNot(contains('Section 4')),
      );
      final novel = (api.batchUpdates.first['chapters'] as List).last as Map;
      expect(novel['newTerms'], contains('Saffron Harbor'));
      expect(
        jsonEncode(api.batchUpdates.skip(1).toList()),
        isNot(contains('Saffron Harbor')),
      );
      final glossary = (cache.checkpoint['memory'] as Map)['glossary'] as List;
      final lock = glossary.singleWhere((entry) => entry['source'] == 'stone');
      expect(lock['target'], '石头');
      expect(lock['locked'], 'true');
      expect(jsonEncode(glossary), isNot(contains('模型替换')));
    },
  );

  test(
    'large translated excerpts refresh independently of chapter count',
    () async {
      final book = await _BookFixture.create(
        overrides: {
          1: 'the river carried leaves to the estuary. ' * 43,
          2: 'the river carried leaves to the estuary. ' * 43,
        },
      );
      final api = _FakeApi();
      await book.translate(api, book.newCache('saving'));
      expect(_titles(api.batchUpdates.first), ['Section 1']);
      final sample = (api.batchUpdates.first['chapters'] as List).single as Map;
      expect((sample['text'] as String).length, lessThanOrEqualTo(1800));
      expect(sample['text'], contains('河水'));
    },
  );

  test('two medium chapters flush at the combined size threshold', () async {
    final book = await _BookFixture.create(
      overrides: {
        1: 'the river carried leaves to the lagoon. ' * 43,
        2: 'the river carried leaves to the lagoon. ' * 43,
      },
    );
    final api = _FakeApi();
    await book.translate(api, book.newCache('saving'));
    expect(_titles(api.batchUpdates.first), ['Section 1', 'Section 2']);
  });

  test(
    'the wire byte ceiling holds when medium and large excerpts come together',
    () async {
      final book = await _BookFixture.create(
        overrides: {
          1: 'the river carried leaves to the lagoon. ' * 43,
          2: 'the river carried leaves to the estuary. ' * 43,
        },
      );
      final api = _FakeApi(heavyInitialMemory: true);
      await book.translate(api, book.newCache('saving'));
      final request = api.batchUpdates.first;
      expect(_titles(request), ['Section 1', 'Section 2']);
      expect(api.memoryPromptBytes.first, inInclusiveRange(4300, 6200));
      final text = (request['chapters'] as List).last['text'] as String;
      expect(text, endsWith('…'));
    },
  );

  test(
    'equivalent short chapters skip a redundant grouped update after resume',
    () async {
      const repeated = 'a stone rested beside the old road.';
      final book = await _BookFixture.create(
        chapterCount: 10,
        overrides: {for (var index = 1; index <= 10; index++) index: repeated},
      );
      final cache = book.newCache('saving');
      final initial = _FakeApi();
      final token = CancelToken();
      await expectLater(
        book.translate(initial, cache, cancelToken: token, stopAfter: 5),
        throwsA(isA<TranslationCancelledException>()),
      );
      expect(initial.batchUpdates.map(_titles), [
        ['Section 1', 'Section 2', 'Section 3', 'Section 4'],
      ]);
      expect(cache.checkpoint['recentFingerprints'], hasLength(1));
      final resumed = _FakeApi();
      await book.translate(resumed, cache);
      expect(resumed.batchUpdates, isEmpty);
      expect(
        cache.expandMemoryState(cache.checkpoint)['memoryTimeline'],
        hasLength(1),
      );
    },
  );

  test(
    'changed wording and note boundaries preserve a grouped refresh',
    () async {
      const repeated = 'a stone rested beside the old road.';
      final book = await _BookFixture.create(
        chapterCount: 14,
        footnoteIndex: 9,
        overrides: {
          for (var index = 1; index <= 14; index++) index: repeated,
          7: 'a stone never rested beside the old road.',
        },
      );
      final api = _FakeApi();
      await book.translate(api, book.newCache('saving'));
      expect(api.batchUpdates.map(_titles), [
        ['Section 1', 'Section 2', 'Section 3', 'Section 4'],
        ['Section 5', 'Section 6', 'Section 7', 'Section 8'],
        ['Section 10', 'Section 11', 'Section 12', 'Section 13'],
      ]);
    },
  );

  test(
    'grouped memory sends only bounded relevant terms, threads, and excerpts',
    () async {
      final book = await _BookFixture.create(chapterCount: 10);
      final cache = book.newCache('saving');
      final api = _FakeApi(heavyInitialMemory: true);
      await book.translate(api, cache);
      final first = api.batchUpdates.first;
      final second = api.batchUpdates.last;
      expect((first['bookMemory'] as Map).keys, ['glossary']);
      expect((second['bookMemory'] as Map).keys, [
        'glossary',
        'continuityNotes',
      ]);
      final context = second['bookMemory'] as Map;
      expect(context['continuityNotes'], ['旧路仍然封闭。']);
      expect(jsonEncode(context['glossary']), contains('石头'));
      expect(jsonEncode(context['glossary']), contains('旧路'));
      expect(jsonEncode(context['glossary']), isNot(contains('irrelevant')));
      final full = cache.checkpoint['memory'] as Map;
      expect(jsonEncode(full), contains('irrelevant'));
      expect(jsonEncode(full), isNot(contains('未经确认的术语')));
      expect(_jsonBytes(context), lessThan(_jsonBytes(full) ~/ 4));
      expect(api.memoryPromptBytes, everyElement(lessThanOrEqualTo(6200)));
    },
  );

  test(
    'a refused grouped request keeps its queue for replay before later chapters',
    () async {
      final book = await _BookFixture.create();
      final cache = book.newCache('saving');
      final paused = _FakeApi(pauseGroupedMemory: true);
      await expectLater(
        book.translate(paused, cache),
        throwsA(isA<TranslationBudgetPausedException>()),
      );
      expect(_titles({'chapters': cache.checkpoint['pendingChapters']}), [
        'Section 1',
        'Section 2',
        'Section 3',
        'Section 4',
      ]);
      final resumed = _FakeApi();
      await book.translate(resumed, cache);
      expect(resumed.batchUpdates, paused.batchUpdates);
      expect(resumed.payloads.first['kind'], 'chapterMemoryBatch');
    },
  );

  test(
    'resume preserves queued excerpts and earlier positional memory',
    () async {
      final book = await _BookFixture.create();
      final cold = _FakeApi();
      await book.translate(cold, book.newCache('cold'));

      final cache = book.newCache('resumed');
      final interrupted = _FakeApi();
      final firstCancel = CancelToken();
      await expectLater(
        book.translate(
          interrupted,
          cache,
          cancelToken: firstCancel,
          stopAfter: 2,
        ),
        throwsA(isA<TranslationCancelledException>()),
      );
      expect(interrupted.batchUpdates, isEmpty);
      expect(_titles({'chapters': cache.checkpoint['pendingChapters']}), [
        'Section 1',
        'Section 2',
      ]);
      final retainedEarlyKey = cache.blocks.entries
          .singleWhere((entry) => entry.value.contains('经过第一块石头'))
          .key;

      final afterFirstResume = _FakeApi();
      final secondCancel = CancelToken();
      await expectLater(
        book.translate(
          afterFirstResume,
          cache,
          cancelToken: secondCancel,
          stopAfter: 5,
        ),
        throwsA(isA<TranslationCancelledException>()),
      );
      expect(afterFirstResume.batchUpdates, cold.batchUpdates);
      cache.blocks.remove(retainedEarlyKey);

      final afterSecondResume = _FakeApi();
      await book.translate(afterSecondResume, cache);
      expect(afterSecondResume.batchUpdates, isEmpty);
      final earlyRequests = afterSecondResume.bodyRequestsFor(
        'the first stone',
      );
      expect(earlyRequests, cold.bodyRequestsFor('the first stone'));
      expect(earlyRequests, hasLength(1));
      expect(jsonEncode(earlyRequests.single), contains('书籍简介'));
    },
  );
}

List<Object?> _titles(Map payload) => [
  for (final item in payload['chapters'] as List) (item as Map)['title'],
];

class _BookFixture {
  const _BookFixture(this.root, this.inputPath, this.chapters);

  final Directory root;
  final String inputPath;
  final List<InspectedChapter> chapters;

  static Future<_BookFixture> create({
    int chapterCount = 8,
    Map<int, String> overrides = const {},
    int? footnoteIndex,
  }) async {
    final root = await Directory.systemTemp.createTemp(
      'ferry-memory-batching-',
    );
    addTearDown(() => root.delete(recursive: true));
    final archive = Archive()
      ..addFile(
        ArchiveFile.string(
          'META-INF/container.xml',
          '<container><rootfiles><rootfile full-path="book.opf"/></rootfiles></container>',
        ),
      )
      ..addFile(
        ArchiveFile.string(
          'book.opf',
          '<package xmlns:dc="http://purl.org/dc/elements/1.1/"><metadata>'
              '<dc:title>Fixture</dc:title></metadata></package>',
        ),
      );
    final chapters = <InspectedChapter>[];
    for (var index = 1; index <= chapterCount; index++) {
      final path = index == footnoteIndex
          ? 'notes-fn.xhtml'
          : 'ch-$index.xhtml';
      final text =
          overrides[index] ??
          (index == 1
              ? 'They passed the first stone beside the old road.'
              : 'a stone beside the old road, marker $index.');
      final content = '<html><body><p>$text</p></body></html>';
      archive.addFile(ArchiveFile.string(path, content));
      chapters.add(
        const EpubHtmlExtractor()
            .inspectChapterBytes(chapterPath: path, bytes: utf8.encode(content))
            .copyWith(
              title: 'Section $index',
              category: ChapterCategory.content,
              includeInTranslation: true,
            ),
      );
    }
    final input = await File(
      p.join(root.path, 'book.epub'),
    ).writeAsBytes(ZipEncoder().encodeBytes(archive));
    return _BookFixture(root, input.path, chapters);
  }

  _Cache newCache(String key) => _Cache(Directory(p.join(root.path, key)));

  Future<void> translate(
    _FakeApi api,
    _Cache cache, {
    bool tokenSaving = true,
    CancelToken? cancelToken,
    int? stopAfter,
  }) async {
    var released = 0;
    await EpubChapterTranslator(
      cacheStore: cache,
      apiClient: api,
    ).translateChapters(
      inputPath: inputPath,
      outputDirectory: root.path,
      config: TranslationConfig.defaults().copyWith(
        apiBaseUrl: 'https://fixture.invalid/v1',
        apiKey: 'offline-fixture',
        model: 'fixture-memory',
        targetLanguage: 'Chinese',
        tokenSavingMode: tokenSaving,
        styleProfileEnabled: false,
        residualQualityCheck: false,
        autoApplyVerifiedCorrections: false,
        lockedGlossary: 'stone => 石头',
        maxRetries: 1,
        chunkSize: 5000,
      ),
      chapters: [...chapters],
      cancelToken: cancelToken ?? CancelToken(),
      onProgress: (_, _) {},
      onChapterSourcesReleased: (_) {
        if (++released == stopAfter) cancelToken?.cancel('fixture stop');
      },
    );
  }
}

class _Cache extends TranslationCacheStore with MemoryHistoryCache {
  _Cache(Directory cacheRoot) : super(cacheRoot: cacheRoot);

  final blocks = <String, String>{};
  final states = <String, JobResumeState>{};

  Map<String, dynamic> get checkpoint =>
      jsonDecode(
            states.values
                .singleWhere((state) => state.status == 'book-memory')
                .currentChapter,
          )
          as Map<String, dynamic>;

  @override
  Future<String?> getBlockTranslation(String key) async => blocks[key];

  @override
  Future<void> putBlockTranslation(String key, String html) async {
    blocks[key] = html;
  }

  @override
  Future<JobResumeState?> loadJobState(String key) async => states[key];

  @override
  Future<void> saveJobState(JobResumeState state) async {
    states[state.jobKey] = state;
  }
}

int _jsonBytes(Object value) => utf8.encode(jsonEncode(value)).length;

class _FakeApi extends TranslationApiClient {
  _FakeApi({this.heavyInitialMemory = false, this.pauseGroupedMemory = false});

  final bool heavyInitialMemory;
  final bool pauseGroupedMemory;
  final payloads = <Map<String, dynamic>>[];
  final memoryPromptBytes = <int>[];

  Iterable<Map<String, dynamic>> get batchUpdates =>
      payloads.where((payload) => payload['kind'] == 'chapterMemoryBatch');

  Iterable<Map<String, dynamic>> get singleUpdates =>
      payloads.where((payload) => payload['kind'] == 'chapterMemory');

  List<Map<String, dynamic>> bodyRequestsFor(String text) => [
    for (final payload in payloads)
      if ((payload['blocks'] as List?)?.any(
            (block) => ((block['text'] ?? block['html']) as String? ?? '')
                .contains(text),
          ) ??
          false)
        payload,
  ];

  String _translatedHtml(String source) {
    const riverTranslation = '河水带着落叶流向海口。';
    if (source.contains('estuary')) return '<p>${riverTranslation * 195}</p>';
    if (source.contains('lagoon')) return '<p>${riverTranslation * 50}</p>';
    if (source.contains('the first stone')) return '<p>他们经过第一块石头。</p>';
    return '<p>旧路旁放着一块石头。</p>';
  }

  @override
  Future<Response<dynamic>> postChatCompletions({
    required Dio dio,
    required Map<String, dynamic> data,
    CancelToken? cancelToken,
  }) async {
    final messages = data['messages'] as List;
    final user = (messages.last as Map)['content'] as String;
    Object reply = '译名';
    if (user.startsWith('{')) {
      final payload = jsonDecode(user) as Map<String, dynamic>;
      payloads.add(payload);
      if (payload['kind'] == 'chapterMemoryBatch') {
        final system = (messages.first as Map)['content'] as String;
        memoryPromptBytes.add(
          utf8.encode(system).length + utf8.encode(user).length,
        );
        if (pauseGroupedMemory) {
          throw const TranslationBudgetPausedException({
            'maxBookTokens': 5000,
            'nextRequestEstimatedTokens': 1000,
          });
        }
      }
      reply = switch (payload['kind']) {
        'initialBookMemory' => {
          'bookSummary': '书籍简介',
          if (heavyInitialMemory) ...{
            'styleGuide': ['Keep the exact tone of the initial memory.'],
            'glossary': [
              {'source': 'old road', 'target': '旧路'},
              for (var index = 0; index < 20; index++)
                {'source': 'irrelevant entry $index', 'target': '无关术语$index'},
            ],
          },
        },
        'chapterMemoryBatch' || 'chapterMemory' => {
          'summary': '新章节的情节摘要。',
          'continuityNotes': ['旧路仍然封闭。'],
          'glossary': [
            {'source': 'stone', 'target': '模型替换'},
            if (heavyInitialMemory)
              {'source': 'fabricated entry', 'target': '未经确认的术语'},
          ],
        },
        _ => {
          'blocks': [
            for (final block in payload['blocks'] as List)
              {
                'id': block['id'],
                if (block['text'] case final String source)
                  'text': _translatedHtml(
                    source,
                  ).replaceAll(RegExp(r'</?p>'), '')
                else
                  'html': _translatedHtml(block['html'] as String),
              },
          ],
        },
      };
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
