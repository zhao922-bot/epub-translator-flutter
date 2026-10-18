import 'package:flutter/foundation.dart';
import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_chapter_translator.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/epub_inspector.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/epub/translation_api_client.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/translation_cache_store.dart';

const _title = 'The General Crisis of the Seventeenth Century';

class _TitleRetentionApi extends TranslationApiClient {
  _TitleRetentionApi(this.prefix);
  final String prefix;
  int bodies = 0;
  String get translation =>
      '<${prefix}p>他读了<${prefix}i>$_title</${prefix}i>。</${prefix}p>';
  @override
  Future<Response<dynamic>> postChatCompletions({
    required Dio dio,
    required Map<String, dynamic> data,
    CancelToken? cancelToken,
  }) async {
    final messages = data['messages'] as List;
    final system = (messages.first as Map)['content'] as String;
    final user = (messages.last as Map)['content'] as String;
    Object reply;
    if (system.startsWith('Translate the book title')) {
      reply = '书名';
    } else {
      Map? payload;
      try {
        final parsed = jsonDecode(user);
        if (parsed is Map) payload = parsed;
      } catch (_) {}
      if (payload?['kind'] == 'initialBookMemory' ||
          payload?['kind'] == 'chapterMemory') {
        reply = {
          'bookSummary': 'An excerpt about a book.',
          'summary': 'An excerpt.',
          'glossary': [],
          'styleGuide': [],
          'recentChapters': [],
        };
      } else {
        bodies++;
        if (payload?['blocks'] is List) {
          reply = {
            'blocks': [
              for (final block in payload!['blocks'] as List)
                {'id': (block as Map)['id'], 'html': translation},
            ],
          };
        } else {
          reply = translation;
        }
      }
    }
    return Response(
      requestOptions: RequestOptions(path: ''),
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
  for (final prefix in ['', 'x:']) {
    test(
      'source-owned inline work title passes actual translation: prefix=$prefix',
      () async {
        final temp = await Directory.systemTemp.createTemp('audit-r25-title-');
        final cache = TranslationCacheStore(
          cacheRoot: Directory('${temp.path}/cache'),
        );
        addTearDown(() async {
          await cache.waitForMaintenanceForTest();
          await temp.delete(recursive: true);
        });
        final source =
            '<${prefix}html ${prefix.isEmpty ? 'xmlns' : 'xmlns:x'}="http://www.w3.org/1999/xhtml"><${prefix}head><${prefix}title>Chapter</${prefix}title></${prefix}head><${prefix}body><${prefix}p>He read <${prefix}i>$_title</${prefix}i>.</${prefix}p></${prefix}body></${prefix}html>';
        final archive = Archive()
          ..addFile(
            ArchiveFile.string(
              'META-INF/container.xml',
              '<container><rootfile full-path="OPS/book.opf"/></container>',
            ),
          )
          ..addFile(
            ArchiveFile.string(
              'OPS/book.opf',
              '<package xmlns:dc="http://purl.org/dc/elements/1.1/"><metadata><dc:title>Book</dc:title></metadata><manifest><item id="c" href="c.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="c"/></spine></package>',
            ),
          )
          ..addFile(ArchiveFile.string('OPS/c.xhtml', source));
        final input = await File(
          '${temp.path}/book.epub',
        ).writeAsBytes(ZipEncoder().encodeBytes(archive));
        final inspected = await EpubInspector().inspect(
          inputPath: input.path,
          outputDirectory: temp.path,
          cancelToken: CancelToken(),
        );
        expect(inspected.chapters.single.blocks, hasLength(1));
        final api = _TitleRetentionApi(prefix);
        final config = TranslationConfig.defaults().copyWith(
          apiBaseUrl: 'https://offline.invalid',
          apiKey: 'offline',
          styleProfileEnabled: false,
          residualQualityCheck: true,
          maxRetries: 0,
        );
        final result =
            await EpubChapterTranslator(
              cacheStore: cache,
              apiClient: api,
            ).translateChapters(
              inputPath: input.path,
              outputDirectory: temp.path,
              config: config,
              chapters: inspected.chapters,
              cancelToken: CancelToken(),
            );
        final exported = ZipDecoder().decodeBytes(
          await File(result.job.outputPath).readAsBytes(),
        );
        final chapterHtml = utf8.decode(
          exported.findFile('OPS/c.xhtml')!.content as List<int>,
        );
        debugPrint(
          'AUDIT work-title prefix=$prefix bodyRequests=${api.bodies} degraded=${result.job.degradedBlockCount} source=${inspected.chapters.single.blocks.single.sourceHtml} output=$chapterHtml',
        );
        expect(chapterHtml, contains(_title));
        expect(
          result.job.degradedBlockCount,
          0,
          reason:
              'Equivalent valid source-owned work titles must not be falsely degraded because of XHTML prefixes.',
        );
        expect(api.bodies, 1);
      },
    );
  }
}
