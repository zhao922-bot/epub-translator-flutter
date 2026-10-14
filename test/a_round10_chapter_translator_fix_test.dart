import 'helpers/memory_history_cache.dart';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/job_resume_state.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_style_profile.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_chapter_translator.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_html_extractor.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_repacker.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/translation_api_client.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/translation_cache_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;

void main() {
  late Directory temp;
  late String input;
  late List<InspectedChapter> chapters;
  final config = TranslationConfig.defaults().copyWith(
    apiBaseUrl: 'https://example.invalid/v1',
    apiKey: 'test',
    model: 'test',
    targetLanguage: 'Chinese',
    uiLanguage: UiLanguage.english,
    residualQualityCheck: false,
    maxRetries: 2,
  );

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('a-chapter-fixes-');
    input = '${temp.path}/book.epub';
    final archive = Archive();
    final files = {
      'META-INF/container.xml':
          '<container><rootfiles><rootfile full-path="book.opf"/></rootfiles></container>',
      'book.opf':
          '<package xmlns:dc="http://purl.org/dc/elements/1.1/"><metadata><dc:title>Title</dc:title></metadata></package>',
      for (final name in ['one.xhtml', 'notes-fn.xhtml', 'later.xhtml', 'last.xhtml'])
        name: '<html><body><p>Prose for $name</p></body></html>',
    };
    for (final entry in files.entries) {
      archive.addFile(ArchiveFile.string(entry.key, entry.value));
    }
    await File(input).writeAsBytes(ZipEncoder().encodeBytes(archive));
    chapters = [
      for (final name in ['one.xhtml', 'notes-fn.xhtml', 'later.xhtml', 'last.xhtml'])
        const EpubHtmlExtractor().inspectChapterBytes(
          chapterPath: name,
          bytes: utf8.encode(files[name]!),
        ).copyWith(category: ChapterCategory.content, includeInTranslation: true),
    ];
  });
  tearDown(() => temp.delete(recursive: true));

  Future<void> run(_Cache cache, _Api api, {
    TranslationStyleProfile? profile,
    List<InspectedChapter>? selected,
    List<String>? logs,
  }) async {
    await EpubChapterTranslator(
      cacheStore: cache,
      apiClient: api,
      repacker: _Repacker(),
    ).translateChapters(
      inputPath: input,
      outputDirectory: temp.path,
      config: config,
      chapters: selected ?? chapters,
      confirmedStyleProfile: profile,
      cancelToken: CancelToken(),
      onProgress: (_, line) => logs?.add(line),
    );
  }

  test('A-P2-6 confirmed empty profile suppresses generated style', () async {
    final api = _Api();
    await run(_Cache(), api, profile: TranslationStyleProfile.empty);
    final blocks = api.payloads.where((p) => p['blocks'] != null);
    expect(blocks, isNotEmpty);
    for (final payload in blocks) {
      final memory = (payload['context'] as Map)['bookMemory'] as Map;
      expect(memory['styleProfileConfirmed'], isTrue);
      expect(jsonEncode(memory), isNot(contains('AUTO_STYLE')));
    }
    expect(api.systems.join(), isNot(contains('AUTO_STYLE')));
  });

  test('A-P2-6 confirmed empty and automatic profiles have distinct cache keys', () {
    final block = chapters.first.blocks.first;
    String key(TranslationStyleProfile? profile) => EpubChapterTranslator.blockCacheKeyForTest(
      config: config, block: block, chapterPath: 'one.xhtml', confirmedStyleProfile: profile,
    );
    expect(key(TranslationStyleProfile.empty), isNot(key(null)));
  });

  test('A-P2-7 restored footnote uses memory before its position', () async {
    final cache = _Cache();
    await run(cache, _Api());
    cache.blocks.clear();
    final api = _Api();
    await run(cache, api);
    final payload = api.payloads.singleWhere((p) =>
      (p['blocks'] as List?)?.any((b) => '${b['id']}'.startsWith('f1:')) ?? false);
    final memory = (payload['context'] as Map)['bookMemory'] as Map;
    final recent = memory['recentChapters'] as List;
    expect(recent.map((c) => c['path']), ['one.xhtml']);
    expect(jsonEncode(memory), isNot(contains('later.xhtml')));
  });

  test('A-P2-8 supplementary update cannot see future memory', () async {
    final cache = _Cache();
    await run(cache, _Api());
    cache.blocks.clear();
    // Retain later history but mark the first chapter's update as missing.
    cache.rewriteMemory((memory) {
      (memory['completedChapterPaths'] as List).remove('one.xhtml');
    });
    final api = _Api();
    await run(cache, api);
    final update = api.payloads.firstWhere((p) => p['kind'] == 'chapterMemory');
    final memory = update['bookMemory'] as Map;
    expect(memory['recentChapters'], isEmpty);
    expect(jsonEncode(memory), isNot(contains('later.xhtml')));
  });

  test('A-P2-9 v17 invalidates the v15 block identity', () {
    final block = chapters.first.blocks.first;
    String historicalKey(String schema) => sha256.convert(utf8.encode([
      schema, EpubChapterTranslator.qualityCacheSchemaVersion,
      const TranslationApiClient().normalizedBaseUrl(config.apiBaseUrl),
      config.model.trim(), config.targetLanguage.trim(), config.lockedGlossary.trim(),
      config.chunkSize, config.residualQualityCheck, config.styleProfileEnabled,
      'none', 'test-book', 'one.xhtml', block.id, block.sourceHtml,
    ].join('|'))).toString();
    final actual = EpubChapterTranslator.blockCacheKeyForTest(
      config: config, block: block, chapterPath: 'one.xhtml',
    );
    expect(actual, historicalKey('v17-structure-repair'));
    expect(actual, isNot(historicalKey('v15-second-person-and-idiom')));
  });

  for (final source in ['<p><em>First</em><b>Second</b><i>Third</i></p>', '<p>First</p>']) {
    test('A-P2-10 fallback code preserves standalone spaces for $source', () {
      final result = EpubChapterTranslator.lockHtmlStructureForTest(
        sourceHtml: source,
        translatedHtml: '<p>文<code><i>甲</i> <b>乙</b></code></p>',
      );
      expect(html.parseFragment(result).text, '文甲 乙');
    });
  }

  for (final tag in ['script', 'style']) {
    for (final source in ['<p>First</p>', '<p><em>First</em><b>Second</b></p>']) {
      test('A-P2-11 extra $tag stays non-prose for $source', () {
        final result = EpubChapterTranslator.lockHtmlStructureForTest(
          sourceHtml: source,
          translatedHtml: '<p><i>译文</i><$tag>UNWANTED_CODE</$tag></p>',
        );
        expect(html.parseFragment(result).text, '译文');
        expect(result, isNot(contains('UNWANTED_CODE')));
      });
    }
  }

  for (final failAll in [false, true]) {
    test('A-P2-12 memory attempts include retries and failures ($failAll)', () async {
      final api = _Api(retryMemory: true, failAllMemory: failAll);
      final logs = <String>[];
      await run(_Cache(), api, selected: [chapters.first, chapters.last], logs: logs);
      expect(api.memoryAttempts, 4);
      final report = logs.singleWhere((s) => s.contains('book memory') && s.contains('new blocks'));
      expect(report, contains('across 4 requests'));
      final duration = RegExp(r'book memory (\d+(?:\.\d+)?)(ms|s)').firstMatch(report)!;
      final milliseconds = double.parse(duration[1]!) * (duration[2] == 's' ? 1000 : 1);
      expect(milliseconds, greaterThanOrEqualTo(200), reason: 'All four attempts, including failures, take at least 60ms each.');
    });
  }
}

class _Cache extends TranslationCacheStore with MemoryHistoryCache {
  final blocks = <String, String>{};
  final states = <String, JobResumeState>{};
  @override
  Future<String?> getBlockTranslation(String key) async => blocks[key];
  @override
  Future<void> putBlockTranslation(String key, String html) async { blocks[key] = html; }
  @override
  Future<JobResumeState?> loadJobState(String key) async => states[key];
  @override
  Future<void> saveJobState(JobResumeState state) async { states[state.jobKey] = state; }

  void rewriteMemory(void Function(Map<String, dynamic>) rewrite) {
    for (final entry in states.entries.toList()) {
      if (!entry.value.currentChapter.startsWith('{')) continue;
      var memory = jsonDecode(entry.value.currentChapter) as Map<String, dynamic>;
      if (memory.containsKey('timelineFormat')) memory = expandMemoryState(memory);
      if (!memory.containsKey('memoryTimeline')) continue;
      rewrite(memory);
      states[entry.key] = JobResumeState.fromJson({
        ...entry.value.toJson(), 'currentChapter': jsonEncode(memory),
      });
    }
  }
}

class _Repacker extends EpubRepacker {
  @override
  Future<void> writeTranslatedEpub({
    required String inputPath, required String outputFilePath,
    required TranslationConfig config, required List<InspectedChapter> chapters,
    CancelToken? cancelToken, bool Function()? isCancelled,
    Set<String> degradedBlockIds = const {}, String? translatedTitle,
    void Function(int, int)? onProgress,
  }) async { await File(outputFilePath).writeAsString('output'); }
}

class _Api extends TranslationApiClient {
  _Api({this.retryMemory = false, this.failAllMemory = false});
  final bool retryMemory;
  final bool failAllMemory;
  final payloads = <Map<String, dynamic>>[];
  final systems = <String>[];
  int memoryAttempts = 0;

  @override
  Future<T> runRetried<T>({
    required TranslationConfig config, required Future<T> Function() operation,
    bool Function(Object)? shouldRetry, Duration? retryDelayOverride,
    CancelToken? cancelToken, int? maxAttemptsOverride, void Function()? throwIfCancelled,
  }) => super.runRetried(
    config: config, operation: operation, shouldRetry: shouldRetry,
    retryDelayOverride: Duration.zero, cancelToken: cancelToken,
    maxAttemptsOverride: maxAttemptsOverride, throwIfCancelled: throwIfCancelled,
  );

  @override
  Future<Response<dynamic>> postChatCompletions({
    required Dio dio, required Map<String, dynamic> data, CancelToken? cancelToken,
  }) async {
    final messages = data['messages'] as List;
    systems.add(messages.first['content'] as String);
    final user = messages.last['content'] as String;
    Object reply = '译名';
    if (user.startsWith('{')) {
      final payload = jsonDecode(user) as Map<String, dynamic>;
      payloads.add(payload);
      if (payload['kind'] == 'initialBookMemory' || payload['kind'] == 'chapterMemory') {
        memoryAttempts++;
        if (retryMemory) await Future<void>.delayed(const Duration(milliseconds: 60));
        if (retryMemory && (failAllMemory || memoryAttempts.isOdd)) {
          throw DioException(requestOptions: RequestOptions(), type: DioExceptionType.connectionTimeout);
        }
        reply = payload['kind'] == 'initialBookMemory' ? {
          'bookSummary': 'Initial context',
          'styleProfile': {'primaryGenre': 'AUTO_STYLE', 'confidence': 'high'},
        } : {'title': 'Chapter', 'summary': 'Chapter summary', 'glossary': []};
      } else {
        reply = {'blocks': [
          for (final block in payload['blocks'] as List)
            {'id': block['id'], 'html': '<p>译文</p>'},
        ]};
      }
    }
    return Response(requestOptions: RequestOptions(), data: {
      'choices': [{'message': {'content': reply is String ? reply : jsonEncode(reply)}}],
    });
  }
}
