import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/job_resume_state.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_job.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_chapter_translator.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_html_extractor.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/translation_api_client.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub_isolate_worker.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/translation_cache_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/memory_history_cache.dart';

class _CachedTranslations extends TranslationCacheStore
    with MemoryHistoryCache {
  _CachedTranslations(this.values);

  final List<String?> values;
  var index = 0;

  @override
  Future<String?> getBlockTranslation(String cacheKey) async =>
      index < values.length ? values[index++] : null;

  @override
  Future<JobResumeState?> loadJobState(String jobKey) async => null;

  @override
  Future<void> saveJobState(JobResumeState state) async {}
}

class _TitleClient extends TranslationApiClient {
  _TitleClient(this.title);

  final String? title;
  var calls = 0;

  @override
  Future<Response<dynamic>> postChatCompletions({
    required Dio dio,
    required Map<String, dynamic> data,
    CancelToken? cancelToken,
  }) async {
    calls++;
    if (title == null) {
      throw StateError('Metadata title request should have been skipped.');
    }
    expect(data['messages'][0]['content'], contains('book title'));
    return Response(
      requestOptions: RequestOptions(),
      data: {
        'choices': [
          {
            'message': {'content': title},
          },
        ],
      },
    );
  }
}

Future<File> _writeEpub(
  Directory dir, {
  required String metadataTitle,
  required String chapterHtml,
}) async {
  final archive = Archive();
  final files = {
    'mimetype': 'application/epub+zip',
    'META-INF/container.xml':
        '<container><rootfiles><rootfile full-path="content.opf"/></rootfiles></container>',
    'content.opf':
        '<package xmlns="http://www.idpf.org/2007/opf" version="2.0">'
        '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">'
        '<dc:title>$metadataTitle</dc:title>'
        '</metadata><manifest><item id="ch" href="chapter.xhtml" '
        'media-type="application/xhtml+xml"/></manifest>'
        '<spine><itemref idref="ch"/></spine></package>',
    'chapter.xhtml': chapterHtml,
  };
  for (final entry in files.entries) {
    archive.addFile(ArchiveFile.string(entry.key, entry.value));
  }
  final input = File('${dir.path}/book.epub');
  await input.writeAsBytes(ZipEncoder().encodeBytes(archive));
  return input;
}

void main() {
  test('translated equivalent body title becomes canonical metadata', () async {
    final dir = await Directory.systemTemp.createTemp('title_consistency_');
    addTearDown(() => dir.delete(recursive: true));
    const html = '<html><body><h1>The Yellow Wallpaper</h1></body></html>';
    final input = await _writeEpub(
      dir,
      metadataTitle: 'The Yellow Wallpaper',
      chapterHtml: html,
    );
    final client = _TitleClient(null);
    final result =
        await EpubChapterTranslator(
          cacheStore: _CachedTranslations(['<h1>黄色墙纸</h1>']),
          apiClient: client,
        ).translateChapters(
          inputPath: input.path,
          outputDirectory: dir.path,
          config: TranslationConfig.defaults().copyWith(
            apiKey: 'offline',
            model: 'offline',
            targetLanguage: 'Chinese',
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
        );
    expect(result.job.status, TranslationJobStatus.completed);
    expect(client.calls, 0);
    final output = await EpubIsolateWorker.loadArchiveFiles(
      result.job.outputPath,
    );
    expect(utf8.decode(output['content.opf']!), contains('黄色墙纸'));
  });

  test('unqualified cousin forms are repaired before repacking', () async {
    final dir = await Directory.systemTemp.createTemp('cousin_consistency_');
    addTearDown(() => dir.delete(recursive: true));
    const html =
        '<html><body>'
        '<p>We asked Cousin Henry and Julia to visit.</p>'
        '<p>I wanted to visit Cousin Henry and Cousin Julia.</p>'
        '</body></html>';
    final input = await _writeEpub(
      dir,
      metadataTitle: 'Family Story',
      chapterHtml: html,
    );
    final client = _TitleClient('家族故事');
    final result =
        await EpubChapterTranslator(
          cacheStore: _CachedTranslations([
            '<p>我们请堂兄亨利和朱莉娅来。</p>',
            '<p>我想去拜访亨利表哥和朱莉娅表姐。</p>',
          ]),
          apiClient: client,
        ).translateChapters(
          inputPath: input.path,
          outputDirectory: dir.path,
          config: TranslationConfig.defaults().copyWith(
            apiKey: 'offline',
            model: 'offline',
            targetLanguage: 'Chinese',
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
        );
    expect(result.job.status, TranslationJobStatus.completed);
    final output = await EpubIsolateWorker.loadArchiveFiles(
      result.job.outputPath,
    );
    final translated = utf8.decode(output['chapter.xhtml']!);
    expect(translated, contains('表亲亨利'));
    expect(translated, contains('表亲朱莉娅'));
    expect(translated, isNot(matches(RegExp('堂兄|表哥|表姐'))));
  });
}
