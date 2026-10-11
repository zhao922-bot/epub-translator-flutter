import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/job_resume_state.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_run_result.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_chapter_translator.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_html_extractor.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_repacker.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/translation_api_client.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/translation_batch_planner.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/translation_cache_store.dart';
import 'package:flutter_test/flutter_test.dart';

class _Cache extends TranslationCacheStore {
  final values = <String, String>{};
  @override
  Future<String?> getBlockTranslation(String cacheKey) async =>
      values[cacheKey];
  @override
  Future<void> putBlockTranslation(
    String cacheKey,
    String translatedHtml,
  ) async {
    values[cacheKey] = translatedHtml;
  }

  @override
  Future<JobResumeState?> loadJobState(String jobKey) async => null;
  @override
  Future<void> saveJobState(JobResumeState state) async {}
}

class _Repacker extends EpubRepacker {
  @override
  Future<void> writeTranslatedEpub({
    required String inputPath,
    required String outputFilePath,
    required TranslationConfig config,
    required List<InspectedChapter> chapters,
    CancelToken? cancelToken,
    bool Function()? isCancelled,
    Set<String> degradedBlockIds = const {},
    String? translatedTitle,
  }) async {
    await File(outputFilePath).writeAsString('output');
  }
}

class _Api extends TranslationApiClient {
  final sourceRequests = <String>[];
  final glossaryRequests = <String>[];
  @override
  Future<Response<dynamic>> postChatCompletions({
    required Dio dio,
    required Map<String, dynamic> data,
    CancelToken? cancelToken,
  }) async {
    final messages = data['messages'] as List;
    final system = messages.first['content'] as String;
    final user = messages.last['content'] as String;
    Object reply;
    if (system.startsWith('Translate the book title')) {
      reply = '译名';
    } else {
      final payload = jsonDecode(user) as Map<String, dynamic>;
      if (payload['kind'] == 'initialBookMemory') {
        final target = user.contains('river') ? '河岸' : '银行';
        reply = {
          'bookSummary': 'context',
          'glossary': [
            {'source': 'bank', 'target': target},
          ],
        };
      } else if (payload['kind'] == 'chapterMemory') {
        reply = {'title': 'chapter', 'summary': 'context', 'glossary': []};
      } else {
        final context = payload['context'] as Map<String, dynamic>? ?? payload;
        final memory = context['bookMemory'] as Map<String, dynamic>?;
        final glossary = memory?['glossary'] as List? ?? [];
        final target = glossary.isEmpty
            ? '无上下文'
            : glossary.first['target'] as String;
        glossaryRequests.add(target);
        reply = {
          'blocks': [
            for (final block in payload['blocks'] as List)
              (() {
                final source = block['html'] as String;
                sourceRequests.add(source);
                expect(source, isNotEmpty);
                return {'id': block['id'], 'html': '<p>$target</p>'};
              })(),
          ],
        };
      }
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

class _OverlappingApi extends _Api {
  final firstBatchStarted = Completer<void>();
  final releaseFirst = Completer<void>();

  @override
  Future<Response<dynamic>> postChatCompletions({
    required Dio dio,
    required Map<String, dynamic> data,
    CancelToken? cancelToken,
  }) async {
    final messages = data['messages'] as List;
    final user = messages.last['content'] as String;
    Map<String, dynamic>? payload;
    try {
      payload = jsonDecode(user) as Map<String, dynamic>;
    } on FormatException {
      // Plain book-title requests.
    }
    if (payload?['blocks'] != null) {
      if (user.contains('<p>bank</p>')) {
        firstBatchStarted.complete();
        await releaseFirst.future;
        throw DioException(
          requestOptions: RequestOptions(),
          type: DioExceptionType.connectionTimeout,
        );
      }
      releaseFirst.complete();
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return super.postChatCompletions(
      dio: dio,
      data: data,
      cancelToken: cancelToken,
    );
  }
}

class _SchedulingApi extends _Api {
  final slow = Completer<void>();
  final started = <String>[];

  @override
  Future<Response<dynamic>> postChatCompletions({
    required Dio dio,
    required Map<String, dynamic> data,
    CancelToken? cancelToken,
  }) async {
    final messages = data['messages'] as List;
    final user = messages.last['content'] as String;
    Map<String, dynamic>? payload;
    try {
      payload = jsonDecode(user) as Map<String, dynamic>;
    } on FormatException {
      // Plain book-title requests.
    }
    if (payload?['blocks'] is List) {
      final id = (payload!['blocks'] as List).first['id'] as String;
      started.add(id);
      if (id == 'p-1') await slow.future;
    }
    return super.postChatCompletions(
      dio: dio,
      data: data,
      cancelToken: cancelToken,
    );
  }
}

/// Counts calls at the actual API boundary, including child requests. The
/// first wave cannot fail until every outer worker has entered its batch.
class _ConcurrentFallbackApi extends _Api {
  _ConcurrentFallbackApi(this.limit, {required this.payloadTooLarge});

  final int limit;
  final bool payloadTooLarge;
  final firstWave = Completer<void>();
  final failedBatches = <List<String>>[];
  final singleSources = <String>[];
  final activeParents = <int, int>{};
  int active = 0;
  int peak = 0;
  int activeSingles = 0;
  int singlePeak = 0;
  int overlappingParents = 0;

  @override
  Future<Response<dynamic>> postChatCompletions({
    required Dio dio,
    required Map<String, dynamic> data,
    CancelToken? cancelToken,
  }) async {
    active++;
    if (active > peak) peak = active;
    try {
      final messages = data['messages'] as List;
      final system = messages.first['content'] as String;
      final user = messages.last['content'] as String;
      if (system.startsWith('You translate EPUB HTML fragments') &&
          user.startsWith('{')) {
        final payload = jsonDecode(user) as Map<String, dynamic>;
        final blocks = payload['blocks'] as List;
        failedBatches.add([for (final block in blocks) block['id'] as String]);
        if (failedBatches.length == limit) firstWave.complete();
        await firstWave.future;
        if (payloadTooLarge) {
          final options = RequestOptions();
          throw DioException(
            requestOptions: options,
            type: DioExceptionType.badResponse,
            response: Response(requestOptions: options, statusCode: 413),
          );
        }
        // Valid JSON with missing blocks enters the malformed-batch fallback.
        return _reply(jsonEncode({'blocks': []}));
      }
      if (system.startsWith('You translate EPUB HTML fragments')) {
        final item = int.parse(RegExp(r'Item (\d+)').firstMatch(user)![1]!);
        final parent = (item - 1) ~/ 3;
        singleSources.add(user);
        activeSingles++;
        activeParents.update(parent, (count) => count + 1, ifAbsent: () => 1);
        if (activeSingles > singlePeak) singlePeak = activeSingles;
        if (activeParents.length > overlappingParents) {
          overlappingParents = activeParents.length;
        }
        try {
          await Future<void>.delayed(const Duration(milliseconds: 15));
          return _reply('<p>译文 $item</p>');
        } finally {
          activeSingles--;
          final remaining = activeParents[parent]! - 1;
          if (remaining == 0) {
            activeParents.remove(parent);
          } else {
            activeParents[parent] = remaining;
          }
        }
      }
      return await super.postChatCompletions(
        dio: dio,
        data: data,
        cancelToken: cancelToken,
      );
    } finally {
      active--;
    }
  }

  Response<dynamic> _reply(String content) => Response(
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

void main() {
  late Directory temp;
  late String input;
  late List<InspectedChapter> chapters;
  late TranslationConfig config;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('rerun_context_');
    input = '${temp.path}/book.epub';
    final archive = Archive();
    final files = {
      'META-INF/container.xml':
          '<container><rootfiles><rootfile full-path="book.opf"/></rootfiles></container>',
      'book.opf':
          '<package xmlns:dc="http://purl.org/dc/elements/1.1/"><metadata><dc:title>English title</dc:title></metadata></package>',
      'one.xhtml': '<html><body><p>bank</p></body></html>',
      'two.xhtml': '<html><body><p>river</p></body></html>',
    };
    for (final file in files.entries) {
      final bytes = utf8.encode(file.value);
      archive.addFile(ArchiveFile(file.key, bytes.length, bytes));
    }
    await File(input).writeAsBytes(ZipEncoder().encodeBytes(archive));
    chapters = [
      for (final name in ['one.xhtml', 'two.xhtml'])
        const EpubHtmlExtractor()
            .inspectChapterBytes(
              chapterPath: name,
              bytes: utf8.encode(files[name]!),
            )
            .copyWith(
              category: ChapterCategory.content,
              includeInTranslation: true,
            ),
    ];
    config = TranslationConfig.defaults().copyWith(
      apiBaseUrl: 'https://example.invalid/v1',
      apiKey: 'test',
      model: 'test',
      targetLanguage: 'Chinese',
      styleProfileEnabled: false,
      residualQualityCheck: false,
    );
  });
  tearDown(() => temp.delete(recursive: true));

  for (final limit in [1, 2, 3]) {
    for (final payloadTooLarge in [false, true]) {
      test('actual API budget caps simultaneous batch fallbacks at $limit '
          '(${payloadTooLarge ? 'HTTP 413' : 'malformed batch'})', () async {
        final api = _ConcurrentFallbackApi(
          limit,
          payloadTooLarge: payloadTooLarge,
        );
        final cache = _Cache();
        final count = limit * 6;
        final chapter = const EpubHtmlExtractor()
            .inspectChapterBytes(
              chapterPath: 'one.xhtml',
              bytes: utf8.encode(
                '<html><body>${List.generate(count, (i) => '<p>Item ${i + 1}</p>').join()}</body></html>',
              ),
            )
            .copyWith(
              category: ChapterCategory.content,
              includeInTranslation: true,
            );
        final result =
            await EpubChapterTranslator(
                  cacheStore: cache,
                  apiClient: api,
                  repacker: _Repacker(),
                  // Budget three tiny blocks plus the real context envelope.
                  batchPlanner: const TranslationBatchPlanner(
                    tinyBlockBudget: 1000,
                  ),
                )
                .translateChapters(
                  inputPath: input,
                  outputDirectory: temp.path,
                  config: config.copyWith(
                    chunkSize: 3500,
                    maxConcurrent: limit,
                    maxRetries: 1,
                  ),
                  chapters: [chapter],
                  cancelToken: CancelToken(),
                )
                .timeout(const Duration(seconds: 5));

        expect(api.failedBatches, hasLength(limit * 2));
        expect(api.failedBatches.every((batch) => batch.length == 3), isTrue);
        expect(api.singleSources, hasLength(count));
        expect(api.singleSources.toSet(), hasLength(count));
        expect(api.peak, limit);
        expect(api.singlePeak, limit);
        if (limit > 1) expect(api.overlappingParents, greaterThanOrEqualTo(2));
        expect(api.active, 0);
        expect(result.job.completedBlocks, count);
        expect(result.job.degradedBlockCount, 0);
        expect(cache.values, hasLength(count));
        expect(result.chapters.single.blocks.map((b) => b.translatedHtml), [
          for (int i = 1; i <= count; i++) '<p>译文 $i</p>',
        ]);
      });
    }
  }

  test(
    'translation pipeline advances and reports completed batches around a slow sibling',
    () async {
      final api = _SchedulingApi();
      final thirdReported = Completer<void>();
      final cache = _Cache();
      final html =
          '<html><body>${List.generate(4, (i) => '<p>Item ${i + 1}</p>').join()}</body></html>';
      final chapter = const EpubHtmlExtractor()
          .inspectChapterBytes(
            chapterPath: 'one.xhtml',
            bytes: utf8.encode(html),
          )
          .copyWith(
            category: ChapterCategory.content,
            includeInTranslation: true,
          );
      final result =
          EpubChapterTranslator(
            cacheStore: cache,
            apiClient: api,
            repacker: _Repacker(),
          ).translateChapters(
            inputPath: input,
            outputDirectory: temp.path,
            config: config.copyWith(chunkSize: 1, maxConcurrent: 2),
            chapters: [chapter],
            cancelToken: CancelToken(),
            onProgress: (job, _) {
              if (job.currentBlock == 'Item 3' && !thirdReported.isCompleted) {
                thirdReported.complete();
              }
            },
          );
      try {
        await thirdReported.future.timeout(const Duration(seconds: 2));
        expect(api.slow.isCompleted, isFalse);
        expect(api.started, containsAll(['p-1', 'p-2', 'p-3']));
        expect(cache.values.length, greaterThanOrEqualTo(2));
      } finally {
        api.slow.complete();
      }
      final translated = await result;
      expect(translated.job.completedBlocks, 4);
      expect(translated.chapters.single.blocks.map((block) => block.id), [
        'p-1',
        'p-2',
        'p-3',
        'p-4',
      ]);
    },
  );

  test(
    'overlapping calls on one translator keep degraded state run-local',
    () async {
      final api = _OverlappingApi();
      final translator = EpubChapterTranslator(
        cacheStore: _Cache(),
        apiClient: api,
        repacker: _Repacker(),
      );
      final first = translator.translateChapters(
        inputPath: input,
        outputDirectory: temp.path,
        config: config.copyWith(maxRetries: 1, outputSuffix: '_first'),
        chapters: [chapters.first],
        cancelToken: CancelToken(),
      );
      await api.firstBatchStarted.future;
      final second = translator.translateChapters(
        inputPath: input,
        outputDirectory: temp.path,
        config: config.copyWith(maxRetries: 1, outputSuffix: '_second'),
        chapters: [chapters.last],
        cancelToken: CancelToken(),
      );
      final results = await Future.wait([first, second]);
      expect(results.first.job.degradedBlockCount, 1);
      expect(results.last.job.degradedBlockCount, 0);
      expect(
        results.last.chapters.single.blocks.single.translatedHtml,
        '<p>河岸</p>',
      );
    },
  );

  Future<TranslationRunResult> run(
    _Cache cache,
    _Api api,
    List<InspectedChapter> selected, {
    TranslationConfig? configuration,
  }) =>
      EpubChapterTranslator(
        cacheStore: cache,
        apiClient: api,
        repacker: _Repacker(),
      ).translateChapters(
        inputPath: input,
        outputDirectory: temp.path,
        config: configuration ?? config,
        chapters: selected,
        cancelToken: CancelToken(),
      );

  test(
    'finished chapters reuse cache and send real source for a new language',
    () async {
      final cache = _Cache();
      final api = _Api();
      final first = await run(cache, api, chapters);
      final requests = api.sourceRequests.length;
      final second = await run(cache, api, first.chapters);
      expect(second.job.cachedBlocks, 2);
      expect(api.sourceRequests.length, requests);
      final third = await run(
        cache,
        api,
        second.chapters,
        configuration: config.copyWith(targetLanguage: 'Korean'),
      );
      expect(third.job.cachedBlocks, 0);
      expect(api.sourceRequests.skip(requests), [
        '<p>bank</p>',
        '<p>river</p>',
      ]);
    },
  );

  test(
    'expanding selection matches a clean full translation with different glossary',
    () async {
      final cache = _Cache();
      final api = _Api();
      final partial = await run(cache, api, [
        chapters[0],
        chapters[1].copyWith(includeInTranslation: false),
      ]);
      expect(partial.chapters[0].blocks.single.translatedHtml, '<p>银行</p>');
      final expanded = await run(cache, api, [
        for (final chapter in partial.chapters)
          chapter.copyWith(includeInTranslation: true),
      ]);
      final cleanApi = _Api();
      final clean = await run(_Cache(), cleanApi, chapters);
      expect(cleanApi.glossaryRequests.first, '河岸');
      expect(
        expanded.chapters[0].blocks.single.translatedHtml,
        clean.chapters[0].blocks.single.translatedHtml,
      );
      expect(expanded.job.cachedBlocks, 0);
      final repeated = await run(cache, api, expanded.chapters);
      expect(repeated.job.cachedBlocks, 2);
    },
  );
}
