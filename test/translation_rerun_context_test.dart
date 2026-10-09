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
