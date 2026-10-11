import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/job_resume_state.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_job.dart';
import 'package:epub_translator_flutter/features/translation/domain/repositories/translation_repository.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_chapter_translator.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_html_extractor.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/translation_api_client.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub_isolate_worker.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/translation_cache_store.dart';
import 'package:flutter_test/flutter_test.dart';

class _CachedBody extends TranslationCacheStore {
  @override
  Future<String?> getBlockTranslation(String cacheKey) async => '<p>正文译文</p>';
  @override
  Future<JobResumeState?> loadJobState(String jobKey) async => null;
  @override
  Future<void> saveJobState(JobResumeState state) async {}
}

class _TitleClient extends TranslationApiClient {
  _TitleClient(this.mode);
  final String mode;
  int calls = 0;
  @override
  Future<Response<dynamic>> postChatCompletions({
    required Dio dio,
    required Map<String, dynamic> data,
    CancelToken? cancelToken,
  }) async {
    calls++;
    expect(data['messages'][0]['content'], contains('book title'));
    if (mode == 'cancel') {
      cancelToken!.cancel('cancel title');
      throw const TranslationCancelledException();
    }
    if (mode == 'error') {
      throw StateError(
        'Bearer SECRET_API_KEY http://user:PROXY_PASSWORD@proxy:8080',
      );
    }
    return Response(
      requestOptions: RequestOptions(),
      data: {
        'choices': [
          {
            'message': {'content': mode == 'empty' ? '' : '译后书名'},
          },
        ],
      },
    );
  }
}

void main() {
  for (final mode in ['error', 'empty', 'success', 'cancel']) {
    test('book title $mode preserves honest status and metadata', () async {
      final dir = await Directory.systemTemp.createTemp('title_failure_');
      addTearDown(() => dir.delete(recursive: true));
      const html = '<html><body><p>Original body</p></body></html>';
      final input = File('${dir.path}/book.epub');
      final archive = Archive();
      final files = {
        'mimetype': 'application/epub+zip',
        'META-INF/container.xml':
            '<container><rootfiles><rootfile full-path="content.opf"/></rootfiles></container>',
        'content.opf':
            '<package xmlns="http://www.idpf.org/2007/opf" version="2.0">'
            '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>Original Title</dc:title></metadata>'
            '<manifest><item id="ch" href="chapter.xhtml" media-type="application/xhtml+xml"/></manifest>'
            '<spine><itemref idref="ch"/></spine></package>',
        'chapter.xhtml': html,
      };
      for (final entry in files.entries) {
        archive.addFile(ArchiveFile.string(entry.key, entry.value));
      }
      await input.writeAsBytes(ZipEncoder().encodeBytes(archive));
      final client = _TitleClient(mode);
      final translator = EpubChapterTranslator(
        cacheStore: _CachedBody(),
        apiClient: client,
      );
      final logs = <String>[];
      final printed = <String>[];
      final future = runZoned(
        () => translator.translateChapters(
          inputPath: input.path,
          outputDirectory: dir.path,
          config: TranslationConfig.defaults().copyWith(
            apiKey: 'SECRET_API_KEY',
            model: 'test',
            uiLanguage: UiLanguage.chinese,
            styleProfileEnabled: false,
            residualQualityCheck: false,
          ),
          chapters: [
            const EpubHtmlExtractor().inspectChapterBytes(
              chapterPath: 'chapter.xhtml',
              bytes: utf8.encode(html),
            ),
          ],
          cancelToken: CancelToken(),
          onProgress: (_, log) => logs.add(log),
        ),
        zoneSpecification: ZoneSpecification(
          print: (_, _, _, message) => printed.add(message),
        ),
      );
      if (mode == 'cancel') {
        await expectLater(
          future,
          throwsA(isA<TranslationCancelledException>()),
        );
        expect(client.calls, 1);
        expect(
          await File('${dir.path}/book_translated.epub').exists(),
          isFalse,
        );
        expect(logs.join(), isNot(contains('书名翻译失败')));
        return;
      }
      final result = await future;
      expect(client.calls, 1);
      final failedTitle = mode == 'error' || mode == 'empty';
      expect(
        result.job.status,
        failedTitle
            ? TranslationJobStatus.completedWithWarnings
            : TranslationJobStatus.completed,
      );
      expect(result.job.degradedBlockCount, 0);
      expect(result.job.completedBlocks, 1);
      expect(logs.join().contains('书名翻译失败，已保留原名'), failedTitle);
      final output = await EpubIsolateWorker.loadArchiveFiles(
        result.job.outputPath,
      );
      expect(
        utf8.decode(output['content.opf']!),
        contains(failedTitle ? 'Original Title' : '译后书名'),
      );
      expect(utf8.decode(output['chapter.xhtml']!), contains('正文译文'));
      expect(printed.join(), isNot(contains('SECRET_API_KEY')));
      expect(printed.join(), isNot(contains('PROXY_PASSWORD')));
      if (failedTitle) {
        expect(printed.join(), contains('Book title translation failed'));
      }
      if (mode == 'success') {
        // Finished runs release block source strings. A fully cached second
        // run must restore selected sources and ignore depleted exclusions.
        expect(result.chapters.single.blocks.single.sourceHtml, isEmpty);
        final excluded = result.chapters.single.copyWith(
          path: 'excluded.xhtml',
          includeInTranslation: false,
          originalHtml: '<html><body></body></html>',
        );
        final rerun = await translator.translateChapters(
          inputPath: input.path,
          outputDirectory: dir.path,
          config: TranslationConfig.defaults().copyWith(
            apiKey: 'test',
            styleProfileEnabled: false,
            residualQualityCheck: false,
          ),
          chapters: [...result.chapters, excluded],
          cancelToken: CancelToken(),
        );
        expect(rerun.job.status, TranslationJobStatus.completed);
        expect(rerun.job.cachedBlocks, 1);
        expect(rerun.job.totalFiles, 1);
        expect(client.calls, 2); // Title only, no body requests on either run.
      }
    });
  }
}
