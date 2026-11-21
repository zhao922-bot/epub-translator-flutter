import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_job.dart';
import 'package:epub_translator_flutter/features/translation/domain/repositories/translation_repository.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_chapter_translator.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/translation_api_client.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/translation_book_budget.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/translation_cache_store.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/repositories/epub_translation_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

void main() {
  late Directory directory;
  late File ledger;
  const estimate = (input: 40, output: 60);

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('book_budget_test_');
    ledger = File(path.join(directory.path, 'ledger.json'));
    addTearDown(() async {
      for (var retry = 0; ; retry++) {
        try {
          if (await directory.exists()) await directory.delete(recursive: true);
          return;
        } on FileSystemException {
          if (retry == 4) rethrow;
          await Future<void>.delayed(Duration(milliseconds: 50 << retry));
        }
      }
    });
  });

  Future<TranslationBookBudget> open(int maxTokens) =>
      TranslationBookBudget.open(
        file: Future.value(ledger),
        maxTokens: maxTokens,
        throwIfCancelled: () {},
      );

  Future<TranslationBookReservation> reserve(
    TranslationBookBudget budget, {
    String kind = 'blocks',
    CancelToken? cancelToken,
  }) => budget.reserve(
    kind: kind,
    estimate: estimate,
    throwIfCancelled: () {},
    cancelToken: cancelToken,
  );

  TranslationApiMetrics attempt(String kind, int input, int output) =>
      TranslationApiMetrics()..recordAttempt(
        kind: kind,
        estimate: estimate,
        usage: {'prompt_tokens': input, 'completion_tokens': output},
      );

  test(
    'contending attempts recheck settled usage and retain an overage',
    () async {
      final budget = await open(150);
      try {
        final first = await reserve(budget);
        bool admitted = false;
        final waiting = reserve(budget, kind: 'bookTitle').then((reservation) {
          admitted = true;
          return reservation;
        });
        await Future<void>.delayed(Duration.zero);
        expect(admitted, isFalse);
        await budget.settle(first, attempt('blocks', 15, 5));
        final second = await waiting;
        await budget.settle(second, attempt('bookTitle', 100, 40));
        await expectLater(
          reserve(budget),
          throwsA(isA<TranslationBudgetPausedException>()),
        );
        expect(budget.apiUsage['chargedTokensEstimate'], 160);
        expect(budget.apiUsage['nextRequestEstimatedTokens'], 100);
      } finally {
        await budget.close();
      }
      final restarted = await open(300);
      try {
        expect(restarted.apiUsage['requests'], 0);
        expect(restarted.apiUsage['priorChargedTokensEstimate'], 160);
        expect(restarted.apiUsage['priorChargedTokensEstimateByKind'], {
          'blocks': 20,
          'bookTitle': 140,
        });
        expect((restarted.apiUsage['cumulativeUsage'] as Map)['requests'], 2);
        await restarted.settle(
          await reserve(restarted),
          attempt('blocks', 1, 2),
        );
        expect(restarted.apiUsage['chargedTokensEstimate'], 163);
      } finally {
        await restarted.close();
      }
    },
  );

  test(
    'cancellation detaches a waiter with another attempt still in flight',
    () async {
      final budget = await open(100);
      try {
        final active = await reserve(budget);
        final token = CancelToken();
        final pending = expectLater(
          reserve(budget, cancelToken: token),
          throwsA(isA<TranslationCancelledException>()),
        );
        await Future<void>.delayed(Duration.zero);
        token.cancel();
        await pending;
        expect(budget.isPaused, isFalse);
        await budget.settle(active, attempt('blocks', 12, 8));
        expect(budget.apiUsage['requests'], 1);
      } finally {
        await budget.close();
      }
    },
  );

  test(
    'abandoned unlimited reservations survive a capped restart exactly once',
    () async {
      final unlimited = await open(0);
      try {
        await unlimited.settle(
          await reserve(unlimited),
          attempt('blocks', 4, 6),
        );
        await reserve(unlimited, kind: 'semanticReview');
        await reserve(unlimited, kind: 'chapterMemoryBatch');
      } finally {
        await unlimited.close();
      }
      for (var restart = 0; restart < 2; restart++) {
        final capped = await open(220);
        try {
          expect(capped.apiUsage['priorChargedTokensEstimate'], 210);
          expect(capped.apiUsage['estimatedUnreportedTokens'], 200);
          expect((capped.apiUsage['cumulativeUsage'] as Map)['requests'], 3);
          await expectLater(
            reserve(capped),
            throwsA(isA<TranslationBudgetPausedException>()),
          );
        } finally {
          await capped.close();
        }
      }
      await ledger.writeAsString('corrupt');
      await expectLater(
        open(220),
        throwsA(isA<TranslationBudgetAccountingException>()),
      );
    },
  );

  test(
    'opens and immediately removes a Windows lock in an extended path',
    () async {
      final deepDirectory = path.joinAll([
        directory.path,
        for (var index = 0; index < 5; index++) '目录-$index-${'a' * 45}',
      ]);
      final longPath = path.join(deepDirectory, 'ledger.json');
      expect(longPath.length, greaterThan(260));
      for (final filename in [longPath, r'\\?\' + longPath]) {
        ledger = File(filename);
        final budget = await open(200);
        try {
          await budget.settle(await reserve(budget), attempt('blocks', 1, 2));
        } finally {
          await budget.close();
        }
        expect(await File('$filename.lock').exists(), isFalse);
      }
    },
    skip: !Platform.isWindows,
  );

  test('charges reported totals and details without double counting', () {
    final metrics = TranslationApiMetrics()
      ..recordAttempt(
        kind: 'blocks',
        estimate: estimate,
        usage: {
          'total_tokens': 12,
          'prompt_tokens_details': {'cached_tokens': 4},
          'completion_tokens_details': {'reasoning_tokens': 0},
        },
      )
      ..recordAttempt(
        kind: 'blocks',
        estimate: estimate,
        usage: {'input_tokens': 18, 'reasoning_tokens': 6},
      );
    expect(metrics.toJson(), containsPair('chargedTokensEstimate', 90));
    expect(metrics.toJson(), containsPair('estimatedUnreportedTokens', 54));
    expect(metrics.toJson(), containsPair('usageReportedRequests', 0));
    expect(metrics.toJson(), containsPair('totalUsageReportedRequests', 1));
    expect(metrics.toJson(), containsPair('reportedTotalTokens', 12));
    expect(metrics.toJson(), containsPair('cachedPromptTokens', 4));
    expect(metrics.toJson(), containsPair('reasoningReportedRequests', 2));
    expect(metrics.toJson(), containsPair('reasoningTokens', 6));
  });

  test(
    'settles a stream after assembly and reserves its buffered fallback',
    () async {
      final adapter = _Adapter([
        () => ResponseBody.fromString(
          'data: {"choices":[{"delta":{"content":"ok"},"finish_reason":"stop"}]}\n\n'
          'data: {"choices":[],"usage":{"prompt_tokens":9,"completion_tokens":2}}\n\n'
          'data: [DONE]\n\n',
          200,
          headers: {
            Headers.contentTypeHeader: ['text/event-stream'],
          },
        ),
        () => _jsonResponse({
          'error': {'message': 'stream is unsupported'},
        }, status: 400),
        () => _completion({'ok': true}, total: 16),
      ]);
      final client = _Client(adapter);
      final dio = client.buildDio(_config);
      final budget = await open(300);
      try {
        client.useBookBudget(dio, budget);
        await client.postChatCompletionsStream(
          dio: dio,
          data: _request,
          stream: true,
        );
        expect(budget.apiUsage['chargedTokensEstimate'], 11);
        expect(budget.apiUsage['usageReportedRequests'], 1);
        await client.postChatCompletionsStream(
          dio: dio,
          data: _request,
          stream: true,
        );
        expect(adapter.requests.map((e) => e['stream']), [true, true, null]);
        expect(budget.apiUsage['requests'], 3);
        expect(budget.apiUsage['errors'], 1);
        final estimated = budget.apiUsage['estimatedUnreportedTokens'] as int;
        expect(estimated, greaterThan(32));
        expect(budget.apiUsage['chargedTokensEstimate'], 27 + estimated);
      } finally {
        dio.close(force: true);
        await budget.close();
      }
    },
  );

  test('length retry is refused before a second physical attempt', () async {
    final adapter = _Adapter([
      () => _completion({}, total: 90, reason: 'length'),
    ]);
    final client = _Client(adapter);
    final dio = client.buildDio(_config);
    final budget = await open(100);
    try {
      client.useBookBudget(dio, budget);
      await expectLater(
        client.postChatCompletions(dio: dio, data: _request),
        throwsA(isA<TranslationBudgetPausedException>()),
      );
      expect(adapter.requests, hasLength(1));
      expect(budget.apiUsage['chargedTokensEstimate'], 90);
      expect(budget.apiUsage['nextRequestEstimatedTokens'], greaterThan(64));
    } finally {
      dio.close(force: true);
      await budget.close();
    }
  });

  test('a successful response survives a failed settlement write', () async {
    final heldPath = '${ledger.path}.held';
    final adapter = _Adapter([
      () async {
        await ledger.rename(heldPath);
        await Directory(ledger.path).create();
        return _completion({'ok': true}, total: 4);
      },
    ]);
    final client = _Client(adapter);
    final dio = client.buildDio(_config);
    final budget = await open(400);
    try {
      client.useBookBudget(dio, budget);
      final response = await client.postChatCompletions(
        dio: dio,
        data: _request,
      );
      expect(client.extractMessageContent(response.data), '{"ok":true}');
      expect(
        budget.throwIfAccountingFailed,
        throwsA(isA<TranslationBudgetAccountingException>()),
      );
      await expectLater(
        client.postChatCompletions(dio: dio, data: _request),
        throwsA(isA<TranslationBudgetAccountingException>()),
      );
      expect(adapter.requests, hasLength(1));
    } finally {
      dio.close(force: true);
      await budget.close();
    }
    await Directory(ledger.path).delete();
    await File(heldPath).rename(ledger.path);
    final restarted = await open(400);
    try {
      expect(restarted.apiUsage['priorChargedTokensEstimate'], greaterThan(32));
      expect((restarted.apiUsage['cumulativeUsage'] as Map)['requests'], 1);
    } finally {
      await restarted.close();
    }
  });

  test(
    'a title budget pause retains paid body work and creates no output',
    () async {
      final epub = await _writeTestBook(directory);
      final output = await Directory(
        path.join(directory.path, 'output'),
      ).create();
      final cache = TranslationCacheStore(cacheRoot: directory);
      addTearDown(cache.waitForMaintenanceForTest);
      final adapter = _Adapter.fromHandler((request, kind) {
        if (kind == 'bookTitle') {
          return _jsonResponse({'error': 'title unavailable'}, status: 400);
        }
        if (kind == 'translation') {
          final messages = request['messages'] as List;
          final payload =
              jsonDecode((messages.last as Map)['content'] as String) as Map;
          return _completion({
            'blocks': [
              for (final block in (payload['blocks'] as List).cast<Map>())
                {
                  'id': block['id'],
                  if (block['text'] != null)
                    'text': '西尔维娅在车站旁听见一阵怪声。'
                  else
                    'html': '<p>西尔维娅在车站旁听见一阵怪声。</p>',
                },
            ],
          }, total: 100);
        }
        return _completion({
          'bookSummary': 'A strange sound at the station.',
        }, total: 10);
      });
      final client = _Client(adapter);
      final repository = EpubTranslationRepository(
        cacheStore: cache,
        translator: EpubChapterTranslator(cacheStore: cache, apiClient: client),
      );
      final config = _config.copyWith(
        styleProfileEnabled: false,
        tokenSavingMode: true,
        maxRetries: 1,
        maxConcurrent: 1,
      );
      final inspection = await repository.startJob(
        inputPath: epub.path,
        outputDirectory: output.path,
        config: config,
      );
      final progress = <TranslationJob>[];
      final first = await repository.translateChapters(
        inputPath: epub.path,
        outputDirectory: output.path,
        config: config,
        chapters: inspection.chapters,
        onProgress: (job, log) {
          if (log.isEmpty) progress.add(job);
        },
      );
      expect(adapter.kinds, containsAll(['translation', 'bookTitle']));
      expect(progress, hasLength(adapter.requests.length));
      expect(progress.last.apiUsage['requests'], adapter.requests.length);
      final spent = first.apiUsage['chargedTokensEstimate'] as int;
      await File(first.job.outputPath).delete();
      final count = adapter.requests.length;
      final second = await repository.translateChapters(
        inputPath: epub.path,
        outputDirectory: output.path,
        config: config.copyWith(maxBookTokens: spent),
        chapters: inspection.chapters,
      );
      expect(second.job.status, TranslationJobStatus.budgetPaused);
      expect(second.job.completedBlocks, 1);
      expect(second.job.cachedBlocks, 1);
      expect(second.job.outputPath, isEmpty);
      expect(second.apiUsage['priorChargedTokensEstimate'], spent);
      expect(second.apiUsage['nextRequestEstimatedTokens'], greaterThan(0));
      expect(adapter.requests, hasLength(count));
      expect(
        await output
            .list()
            .where((entry) => entry.path.endsWith('.epub'))
            .toList(),
        isEmpty,
      );
    },
  );

  test(
    'style generation respects the cap before profile confirmation',
    () async {
      final adapter = _Adapter([
        () => _completion({
          'primaryGenre': 'fiction',
          'confidence': 'high',
        }, total: 28),
      ]);
      final cache = TranslationCacheStore(cacheRoot: directory);
      addTearDown(cache.waitForMaintenanceForTest);
      final client = _Client(adapter);
      final translator = EpubChapterTranslator(
        cacheStore: cache,
        apiClient: client,
      );
      final config = _config.copyWith(
        styleProfileEnabled: true,
        maxBookTokens: 1,
      );
      await expectLater(
        translator.generateStyleProfile(config: config, chapters: _chapters),
        throwsA(isA<TranslationBudgetPausedException>()),
      );
      expect(adapter.requests, isEmpty);
      final profile = await translator.generateStyleProfile(
        config: config.copyWith(maxBookTokens: 0),
        chapters: _chapters,
      );
      expect(profile.primaryGenre, 'fiction');
      final restarted = EpubChapterTranslator(
        cacheStore: cache,
        apiClient: client,
      );
      await expectLater(
        restarted.generateStyleProfile(
          config: config.copyWith(model: 'another-fixture-model'),
          chapters: _chapters,
        ),
        throwsA(
          isA<TranslationBudgetPausedException>().having(
            (error) => error.apiUsage['priorChargedTokensEstimate'],
            'prior style usage',
            28,
          ),
        ),
      );
      expect(adapter.requests, hasLength(1));
    },
  );
}

final _config = TranslationConfig.defaults().copyWith(
  apiBaseUrl: 'https://example.invalid/v1',
  apiKey: 'fixture',
  model: 'fixture-model',
  useStreamingApi: false,
);

const _request = <String, dynamic>{
  'max_tokens': 32,
  'messages': <Map<String, String>>[
    {'role': 'user', 'content': 'Test'},
  ],
};

const _chapters = [
  InspectedChapter(
    path: 'chapter.xhtml',
    title: 'A long day',
    body: 'Sylvia listened to a strange sound beside the railway station.',
    originalHtml:
        '<p>Sylvia listened to a strange sound beside the railway station.</p>',
    blocks: [
      ExtractedBlock(
        id: 'p1',
        tagName: 'p',
        sourceHtml:
            '<p>Sylvia listened to a strange sound beside the railway station.</p>',
        sourceText:
            'Sylvia listened to a strange sound beside the railway station.',
      ),
    ],
    category: ChapterCategory.content,
    recommendedForTranslation: true,
    includeInTranslation: true,
  ),
];

ResponseBody _jsonResponse(Object data, {int status = 200}) =>
    ResponseBody.fromString(
      jsonEncode(data),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );

ResponseBody _completion(
  Map<String, Object> content, {
  required int total,
  String reason = 'stop',
}) => _jsonResponse({
  'choices': [
    {
      'message': {'content': jsonEncode(content)},
      'finish_reason': reason,
    },
  ],
  'usage': {'total_tokens': total},
});

class _Client extends TranslationApiClient {
  const _Client(this.adapter);
  final _Adapter adapter;

  @override
  Dio buildDio(TranslationConfig config) =>
      super.buildDio(config)..httpClientAdapter = adapter;
}

class _Adapter implements HttpClientAdapter {
  _Adapter(this.replies) : handler = null;

  _Adapter.fromHandler(this.handler) : replies = const [];

  final FutureOr<ResponseBody> Function(Map<String, dynamic>, String)? handler;

  final List<FutureOr<ResponseBody> Function()> replies;
  final List<Map<String, dynamic>> requests = [];
  final kinds = <String>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final request = Map<String, dynamic>.from(options.data as Map);
    final kind = options.extra['requestKind'] as String;
    requests.add(request);
    kinds.add(kind);
    return await (handler?.call(request, kind) ??
        replies[requests.length - 1]());
  }

  @override
  void close({bool force = false}) {}
}

Future<File> _writeTestBook(Directory directory) async {
  final archive = Archive()
    ..addFile(
      ArchiveFile.noCompress(
        'mimetype',
        20,
        utf8.encode('application/epub+zip'),
      ),
    )
    ..addFile(
      ArchiveFile.string(
        'META-INF/container.xml',
        '<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">'
            '<rootfiles><rootfile full-path="book.opf" media-type="application/oebps-package+xml"/>'
            '</rootfiles></container>',
      ),
    )
    ..addFile(
      ArchiveFile.string(
        'book.opf',
        '<package version="3.0" xmlns="http://www.idpf.org/2007/opf">'
            '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">'
            '<dc:title>Whispers of the Lantern</dc:title><dc:language>en</dc:language></metadata>'
            '<manifest><item id="c1" href="chapter.xhtml" media-type="application/xhtml+xml"/>'
            '</manifest><spine><itemref idref="c1"/></spine></package>',
      ),
    )
    ..addFile(
      ArchiveFile.string(
        'chapter.xhtml',
        '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>A long day</title></head>'
            '<body>${_chapters.single.originalHtml}</body></html>',
      ),
    );
  return File(
    path.join(directory.path, 'source.epub'),
  ).writeAsBytes(ZipEncoder().encode(archive));
}
