import 'package:flutter/foundation.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:epub_translator_flutter/features/translation/application/translation_dashboard_controller.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_job.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/repositories/epub_translation_repository.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/translation_cache_store.dart';
import 'package:epub_translator_flutter/shared/localization/app_strings.dart';

void main() {
  test(
    'a resumed run with uncached metadata does not promise zero API calls',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'audit-r18-cache-notice-',
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await server.close(force: true);
        await temp.delete(recursive: true);
      });
      int requests = 0, titleRequests = 0, bodyRequests = 0;
      server.listen((request) async {
        requests++;
        final data = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        final messages = data['messages'] as List;
        final system = (messages.first as Map)['content'] as String;
        final user = (messages.last as Map)['content'] as String;
        Object response;
        if (system.startsWith('Translate the book title')) {
          titleRequests++;
          response = '审查书籍';
        } else {
          final payload = jsonDecode(user) as Map;
          if (payload['kind'] == 'initialBookMemory') {
            response = {
              'bookSummary': 'A cold morning.',
              'styleGuide': [],
              'glossary': [],
              'recentChapters': [],
            };
          } else if (payload['kind'] == 'chapterMemory') {
            response = {
              'title': 'Chapter',
              'summary': 'A cold morning.',
              'glossary': [],
            };
          } else {
            bodyRequests++;
            response = {
              'blocks': [
                for (final block in payload['blocks'] as List)
                  {'id': (block as Map)['id'], 'html': '<p>清晨寒冷，风吹过寂静的田野。</p>'},
              ],
            };
          }
        }
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'choices': [
              {
                'message': {
                  'content': response is String
                      ? response
                      : jsonEncode(response),
                },
              },
            ],
            'usage': {'prompt_tokens': 2, 'completion_tokens': 2},
          }),
        );
        await request.response.close();
      });
      final archive = Archive()
        ..addFile(ArchiveFile.string('mimetype', 'application/epub+zip'))
        ..addFile(
          ArchiveFile.string(
            'META-INF/container.xml',
            '<container><rootfile full-path="OPS/book.opf"/></container>',
          ),
        )
        ..addFile(
          ArchiveFile.string(
            'OPS/book.opf',
            '<package xmlns:dc="http://purl.org/dc/elements/1.1/"><metadata><dc:title>Audit Book</dc:title></metadata><manifest><item id="c" href="c.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="c"/></spine></package>',
          ),
        )
        ..addFile(
          ArchiveFile.string(
            'OPS/c.xhtml',
            '<html><head><title>Chapter 1</title></head><body><p>The morning was cold and the wind blew across the quiet fields.</p></body></html>',
          ),
        );
      final input = await File(
        '${temp.path}/book.epub',
      ).writeAsBytes(ZipEncoder().encodeBytes(archive));
      final cache = TranslationCacheStore(
        cacheRoot: Directory('${temp.path}/cache'),
      );
      final controller = TranslationDashboardController(
        repository: EpubTranslationRepository(cacheStore: cache),
      );
      addTearDown(() async {
        await controller.debugDispose();
        await cache.waitForMaintenanceForTest();
      });
      controller.syncSettings(
        TranslationConfig.defaults().copyWith(
          apiBaseUrl: 'http://127.0.0.1:${server.port}/v1',
          apiKey: 'offline-audit-key',
          uiLanguage: UiLanguage.english,
          styleProfileEnabled: false,
          residualQualityCheck: false,
          maxConcurrent: 1,
        ),
      );
      controller.setOutputDirectory(temp.path);
      controller.setInputPath(input.path);
      await controller.startInspection(generateStyle: false);
      bool requested = false;
      final detach = controller.addListener((state) {
        final job = state.job;
        if (!requested &&
            job != null &&
            job.phase == TranslationJobPhase.translation &&
            job.totalBlocks > 0 &&
            job.completedBlocks == job.totalBlocks) {
          requested = true;
          unawaited(controller.requestCancel());
        }
      });
      await controller.startTranslation();
      detach();
      expect(requested, isTrue);
      expect(controller.state.job!.status, TranslationJobStatus.cancelled);
      expect(titleRequests, 0);
      final beforeRequests = requests,
          beforeTitles = titleRequests,
          beforeBody = bodyRequests;
      final logStart = controller.state.logs.length;
      await controller.startTranslation();
      final job = controller.state.job!;
      final logs = controller.state.logs.skip(logStart).toList();
      const wrongNotice = 'Reused all 1 blocks; this run made no API requests.';
      final hasNotice = logs.contains(wrongNotice);
      expect(
        logs,
        contains(
          const AppStrings(UiLanguage.english).logAllBlocksRestoredNoApi(1),
        ),
      );
      expect(
        const AppStrings(UiLanguage.chinese).logAllBlocksRestoredNoApi(1),
        contains('正文缓存恢复'),
      );
      final secondRequests = requests - beforeRequests,
          secondTitles = titleRequests - beforeTitles,
          secondBody = bodyRequests - beforeBody;
      final outputExists = await File(job.outputPath).exists();
      debugPrint(
        'AUDIT resumed run: cached=${job.cachedBlocks}/${job.totalBlocks}, requests=$secondRequests, titles=$secondTitles, body=$secondBody, zeroApiNotice=$hasNotice, status=${job.status}, outputExists=$outputExists',
      );
      expect(job.cachedBlocks, 1);
      expect(secondBody, 0);
      expect(secondTitles, 1);
      expect(secondRequests, 1);
      expect(outputExists, isTrue);
      expect(
        hasNotice,
        isFalse,
        reason:
            'A run that sends a title API request must not promise that the entire run made no API calls',
      );
    },
  );
}
