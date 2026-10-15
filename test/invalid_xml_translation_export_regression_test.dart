import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_job.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_chapter_translator.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_html_extractor.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_xml_characters.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/translation_api_client.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/translation_cache_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

class _InvalidBodyClient extends TranslationApiClient {
  @override
  Future<Response<dynamic>> postChatCompletions({
    required Dio dio,
    required Map<String, dynamic> data,
    CancelToken? cancelToken,
  }) async {
    final prompt = (data['messages'] as List).first['content'] as String;
    final String content;
    if (prompt.contains('Create a compact translation memory')) {
      content = jsonEncode({
        'bookSummary': 'A short book.',
        'styleGuide': [],
        'glossary': [],
        'recentChapters': [],
      });
    } else if (prompt.contains('Translate the book title')) {
      content = '合法书名';
    } else if (prompt.contains('JSON')) {
      content = jsonEncode({
        'blocks': [
          {'id': 'p-1', 'html': '<p>非法\u0001译文。</p>'},
        ],
      });
    } else {
      content = '<p>非法\u0001译文。</p>';
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
}

void main() {
  test(
    'illegal API XML text preserves source in export without paid cache hit',
    () async {
      final dir = await Directory.systemTemp.createTemp('invalid-xml-export-');
      final cacheDir = Directory('${dir.path}/cache');
      final cache = TranslationCacheStore(cacheRoot: cacheDir);
      try {
        const source =
            '<html xmlns="http://www.w3.org/1999/xhtml">'
            '<head><title>Chapter</title></head>'
            '<body><p>Hello world.</p></body></html>';
        final archive = Archive();
        final files = {
          'mimetype': 'application/epub+zip',
          'META-INF/container.xml':
              '<container><rootfiles>'
              '<rootfile full-path="book.opf"/></rootfiles></container>',
          'book.opf':
              '<package xmlns="http://www.idpf.org/2007/opf" version="2.0">'
              '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">'
              '<dc:title>Original title</dc:title></metadata>'
              '<manifest><item id="ch" href="c.xhtml" media-type="application/xhtml+xml"/></manifest>'
              '<spine><itemref idref="ch"/></spine></package>',
          'c.xhtml': source,
        };
        for (final entry in files.entries) {
          archive.add(ArchiveFile.string(entry.key, entry.value));
        }
        final input = File('${dir.path}/source.epub');
        await input.writeAsBytes(ZipEncoder().encodeBytes(archive));
        final result =
            await EpubChapterTranslator(
              cacheStore: cache,
              apiClient: _InvalidBodyClient(),
            ).translateChapters(
              inputPath: input.path,
              outputDirectory: dir.path,
              config: TranslationConfig.defaults().copyWith(
                apiBaseUrl: 'https://offline.invalid',
                apiKey: 'offline-test',
                styleProfileEnabled: false,
                maxRetries: 1,
                retryDelaySeconds: 0,
              ),
              chapters: [
                const EpubHtmlExtractor().inspectChapterBytes(
                  chapterPath: 'c.xhtml',
                  bytes: utf8.encode(source),
                ),
              ],
              cancelToken: CancelToken(),
            );
        expect(result.job.status, TranslationJobStatus.failed);
        expect(result.job.degradedBlockCount, 1);
        final output = ZipDecoder().decodeBytes(
          await File(result.job.outputPath).readAsBytes(),
        );
        final chapter = utf8.decode(output.find('c.xhtml')!.content);
        expect(chapter, contains('Hello world.'));
        expect(() => validateEpubXmlMarkup(chapter), returnsNormally);
        expect(() => XmlDocument.parse(chapter), returnsNormally);
        final blocks = Directory('${cacheDir.path}/blocks');
        if (await blocks.exists()) {
          expect(
            await blocks.list(recursive: true).where((e) => e is File).length,
            0,
          );
        }
      } finally {
        await cache.waitForMaintenanceForTest();
        await dir.delete(recursive: true);
      }
    },
  );
}
