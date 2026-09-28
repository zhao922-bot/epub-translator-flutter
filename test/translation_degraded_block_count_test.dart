import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_job.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/repositories/epub_translation_repository.dart';
import 'package:epub_translator_flutter/shared/localization/app_strings.dart';
import 'package:flutter_test/flutter_test.dart';

/// Regression test for the degraded-block counting bug: blocks that kept
/// their source text (degraded) must not be counted in the "Translated N new
/// blocks" performance report.
///
/// A chapter with a single protected-anchor block is translated against a
/// server that stalls translation requests past the client receive timeout.
/// The protected-slot pipeline degrades the block to its source HTML; the
/// report must then say "Translated 0 new blocks", not "Translated 1".
void main() {
  test(
    'degraded protected-slot blocks are not counted as translated',
    () async {
      final Directory temp = await Directory.systemTemp.createTemp(
        'epub_degraded_count_test_',
      );
      addTearDown(() => temp.delete(recursive: true));

      final File epubFile = File('${temp.path}/slots.epub');
      await _writeTestEpub(
        epubFile,
        chapters: const <String, String>{
          'OPS/Text/01.xhtml':
              '<p>First <a href="#n1"><span>[1]</span></a> tail.</p>',
        },
      );

      final HttpServer server = await _startStallingTranslationServer();
      addTearDown(() => server.close(force: true));

      final TranslationConfig config = TranslationConfig.defaults().copyWith(
        apiBaseUrl: 'http://127.0.0.1:${server.port}',
        apiKey: 'sk-test',
        model: 'degraded-count-model',
        timeoutSeconds: 1,
        maxRetries: 1,
        retryDelaySeconds: 0,
        maxConcurrent: 1,
      );

      final EpubTranslationRepository repository = EpubTranslationRepository();
      final inspection = await repository.startJob(
        inputPath: epubFile.path,
        outputDirectory: temp.path,
        config: config,
      );
      expect(inspection.chapters, isNotEmpty);
      expect(
        inspection.chapters.fold<int>(
          0,
          (int sum, chapter) => sum + chapter.blocks.length,
        ),
        1,
      );

      final List<String> logs = <String>[];
      final result = await repository.translateChapters(
        inputPath: epubFile.path,
        outputDirectory: temp.path,
        config: config,
        chapters: inspection.chapters,
        onProgress: (TranslationJob job, String line) => logs.add(line),
      );

      // Every block degraded, so the run reports failure — but the degraded
      // block kept its source text and must not count as "translated".
      expect(result.job.status, TranslationJobStatus.failed);
      // The terminal errorMessage is the localized notice, not a raw
      // English hard-coded string.
      expect(
        result.job.errorMessage,
        const AppStrings(UiLanguage.english).runErrorAllBlocksDegraded,
      );
      final String report = logs.firstWhere(
        (String line) =>
            line.startsWith('Performance: Translation run took') &&
            line.contains('new blocks'),
        orElse: () => '',
      );
      expect(report, isNotEmpty);
      expect(report, contains('Translated 0 new blocks'));
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

/// Fake translation endpoint: answers book/chapter-memory requests instantly
/// but stalls translation (`blocks`) requests past the client timeout, which
/// forces the protected-slot pipeline down its degrade path.
Future<HttpServer> _startStallingTranslationServer() async {
  final HttpServer server = await HttpServer.bind(
    InternetAddress.loopbackIPv4,
    0,
  );
  server.listen((HttpRequest request) async {
    try {
      final String rawBody = await utf8.decoder.bind(request).join();
      final Map<String, dynamic> requestBody =
          jsonDecode(rawBody) as Map<String, dynamic>;
      final List<dynamic> messages = requestBody['messages'] as List<dynamic>;
      final Map<String, dynamic> payload =
          jsonDecode(
                (messages.last as Map<String, dynamic>)['content'] as String,
              )
              as Map<String, dynamic>;
      final String kind = payload['kind'] as String? ?? 'blocks';
      if (kind == 'blocks') {
        // Stall past the 1s client receive timeout. The client gives up and
        // the late response below lands on a dead connection (ignored).
        await Future<void>.delayed(const Duration(seconds: 5));
      }

      final Object responsePayload = switch (kind) {
        'initialBookMemory' => <String, Object?>{
          'bookSummary': 'A tiny test book.',
          'styleGuide': <Object?>[],
          'glossary': <Object?>[],
          'recentChapters': <Object?>[],
        },
        'chapterMemory' => <String, Object?>{
          'title': 'Chapter',
          'summary': 'The chapter was translated.',
          'continuityNotes': <Object?>[],
          'glossary': <Object?>[],
        },
        _ => <String, Object?>{
          'blocks': (payload['blocks'] as List<dynamic>)
              .cast<Map<String, dynamic>>()
              .map(
                (Map<String, dynamic> block) => <String, Object?>{
                  'id': block['id'],
                  'html': '<p>Translated ${block['id']}</p>',
                },
              )
              .toList(),
        },
      };

      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode(<String, Object?>{
          'choices': <Object?>[
            <String, Object?>{
              'message': <String, Object?>{
                'content': jsonEncode(responsePayload),
              },
            },
          ],
        }),
      );
      await request.response.close();
    } catch (_) {
      // The client already timed out and went away; nothing to do.
    }
  });
  return server;
}

Future<void> _writeTestEpub(
  File epubFile, {
  required Map<String, String> chapters,
}) async {
  final Archive archive = Archive()
    ..addFile(
      ArchiveFile.string('META-INF/container.xml', '''
<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
'''),
    );

  final String manifest = chapters.keys
      .map((String path) {
        final String id = path.split('/').last.replaceAll('.', '-');
        final String href = path.replaceFirst('OPS/', '');
        return '<item id="$id" href="$href" media-type="application/xhtml+xml"/>';
      })
      .join('\n    ');
  final String spine = chapters.keys
      .map((String path) {
        final String id = path.split('/').last.replaceAll('.', '-');
        return '<itemref idref="$id"/>';
      })
      .join('\n    ');
  archive.addFile(
    ArchiveFile.string('OPS/content.opf', '''
<?xml version="1.0" encoding="UTF-8"?>
<package version="3.0" xmlns="http://www.idpf.org/2007/opf">
  <manifest>
    $manifest
  </manifest>
  <spine>
    $spine
  </spine>
</package>
'''),
  );

  for (final MapEntry<String, String> entry in chapters.entries) {
    archive.addFile(
      ArchiveFile.string(entry.key, '''
<!doctype html>
<html xmlns="http://www.w3.org/1999/xhtml">
  <head><title>Chapter</title></head>
  <body>${entry.value}</body>
</html>
'''),
    );
  }

  await epubFile.writeAsBytes(ZipEncoder().encodeBytes(archive), flush: true);
}
