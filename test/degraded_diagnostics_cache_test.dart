import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_job.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_run_result.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_chapter_translator.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/translation_api_client.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/translation_cache_store.dart';
import 'real_book_fix_regression_test.dart' as fixture;

class _Cache extends TranslationCacheStore {
  _Cache(Directory root) : super(cacheRoot: root);
  bool injectBad = false;
  @override
  Future<String?> getBlockTranslation(String key) async {
    final value = await super.getBlockTranslation(key);
    return injectBad && value != null ? '<p>请提供需要翻译的原文。</p>' : value;
  }
}

class _Api extends TranslationApiClient {
  bool failSecond = true;
  int bodyBlocks = 0;
  @override
  Future<Response<dynamic>> postChatCompletions({
    required Dio dio,
    required Map<String, dynamic> data,
    CancelToken? cancelToken,
  }) async {
    final user = (data['messages'] as List).last['content'] as String;
    Object? payload;
    try {
      payload = jsonDecode(user);
    } on FormatException {
      payload = null;
    }
    String content;
    if (payload is Map && payload['kind'] != null) {
      content = jsonEncode({
        'bookSummary': 'A short test story.',
        'title': 'Story',
        'summary': 'A short test story.',
        'glossary': [],
        'recentChapters': [],
        'continuityNotes': [],
        'styleGuide': [],
      });
    } else if (payload is Map && payload['blocks'] is List) {
      content = jsonEncode({
        'blocks': [
          for (final b in payload['blocks'] as List)
            {'id': b['id'], 'html': _translate(b['html'] as String)},
        ],
      });
    } else if (user.startsWith('<')) {
      content = _translate(user);
    } else {
      content = '测试故事';
    }
    return Response(
      requestOptions: RequestOptions(),
      data: {
        'choices': [
          {
            'finish_reason': 'stop',
            'message': {'content': content},
          },
        ],
      },
    );
  }

  String _translate(String html) {
    bodyBlocks++;
    return failSecond && html.contains('Scene 1')
        ? '<p>请提供需要翻译的原文。</p>'
        : '<p>她先欢喜，接着却伤心地哭喊起来。</p>';
  }
}

void main() {
  test(
    'export diagnostics, selective cache guard and warm reuse work end to end',
    () async {
      final f = fixture.Fixture();
      await f.init();
      addTearDown(f.dispose);
    final cache = _Cache(Directory('${f.dir.path}/guard-cache'));
      final api = _Api();
      final config = f.config.copyWith(
        semanticQualityCheck: false,
        styleProfileEnabled: false,
        maxRetries: 2,
        retryDelaySeconds: 0,
        bilingual: false,
      );
      final logs = <String>[];
      Future<TranslationRunResult> run() async {
        final inspected = await f.repo.startJob(
          inputPath: f.book.path,
          outputDirectory: f.dir.path,
          config: config,
        );
        return EpubChapterTranslator(
          cacheStore: cache,
          apiClient: api,
        ).translateChapters(
          inputPath: f.book.path,
          outputDirectory: f.dir.path,
          config: config,
          chapters: inspected.chapters
              .where((c) => c.includeInTranslation)
              .toList(),
          cancelToken: CancelToken(),
          onProgress: (_, line) => logs.add(line),
        );
      }

      final first = await run();
      expect(first.job.status, TranslationJobStatus.completedWithWarnings);
      expect(first.job.degradedBlockCount, 1);
    final output = first.job.outputPath;
      final report =
          jsonDecode(await File('$output.diagnostics.json').readAsString())
              as Map;
      expect(report['degradedBlocks'], hasLength(1));
      final record = (report['degradedBlocks'] as List).single as Map;
      expect(record['block'], 'story.xhtml:p-2');
      expect(record['fallback'], 'source');
      expect(record['reason'], contains('Non-translation'));
      expect(
        logs.any((l) => l.contains('Non-translation') && l.contains('保留原文')),
        isTrue,
      );
      final zip = ZipDecoder().decodeBytes(await File(output).readAsBytes());
      final text = utf8.decode(zip.findFile('story.xhtml')!.content);
      expect(text, isNot(contains('请提供')));
      expect(text, contains('Scene 1'));

      // Simulate a bad reply cached by an older build. A narrow guard should
      // reject that one entry without changing cache identities for healthy data.
      cache.injectBad = true;
      api.failSecond = false;
      api.bodyBlocks = 0;
      final second = await run();
      expect(second.job.status, TranslationJobStatus.completed);
      expect(second.job.cachedBlocks, 0);
      expect(second.job.degradedBlockCount, 0);
      expect(api.bodyBlocks, 2);
      final refreshed =
          jsonDecode(await File('$output.diagnostics.json').readAsString())
              as Map;
      expect(refreshed['degradedBlocks'], isEmpty);

      cache.injectBad = false;
      api.bodyBlocks = 0;
      final third = await run();
      expect(third.job.cachedBlocks, 2);
      expect(api.bodyBlocks, 0);
      expect(third.job.status, TranslationJobStatus.completed);
    },
  );
}
