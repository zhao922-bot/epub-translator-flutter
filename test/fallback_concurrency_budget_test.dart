import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_job.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/repositories/epub_translation_repository.dart';
import 'package:flutter_test/flutter_test.dart';

/// Regression test: when several batches fail at once, their per-block
/// fallbacks share the chapter-wide concurrency budget instead of each
/// opening [maxConcurrent] requests (maxConcurrent^2 in flight).
void main() {
  test('per-batch fallbacks share the chapter concurrency budget', () async {
    final Directory temp = await Directory.systemTemp.createTemp(
      'fallback_concurrency_budget_test_',
    );
    addTearDown(() => temp.delete(recursive: true));

    final _ConcurrencyTrackingServer server = _ConcurrencyTrackingServer();
    await server.start();
    addTearDown(server.close);

    // 16 small paragraphs; the chunk size packs ~4 blocks per batch, so one
    // chapter produces several batches and a single outer window holds
    // maxConcurrent batches at once.
    final String body = List<String>.generate(
      16,
      (int index) =>
          '<p>Paragraph number $index with some translatable text.</p>',
    ).join('\n');
    final File epubFile = File('${temp.path}/concurrency.epub');
    await _writeTestEpub(
      epubFile,
      chapters: <String, String>{'OPS/Text/ch1.xhtml': body},
    );

    final TranslationConfig config = TranslationConfig.defaults().copyWith(
      apiBaseUrl: 'http://127.0.0.1:${server.port}',
      apiKey: 'sk-test',
      model: 'concurrency-model-${server.port}',
      chunkSize: 220,
      maxConcurrent: 4,
      maxRetries: 1,
      retryDelaySeconds: 0,
      styleProfileEnabled: false,
    );
    final EpubTranslationRepository repository = EpubTranslationRepository();
    final inspection = await repository.startJob(
      inputPath: epubFile.path,
      outputDirectory: temp.path,
      config: config,
    );
    final result = await repository.translateChapters(
      inputPath: epubFile.path,
      outputDirectory: temp.path,
      config: config,
      chapters: inspection.chapters,
    );

    expect(result.job.status, TranslationJobStatus.completed);
    // The fallbacks genuinely overlapped (otherwise the test is vacuous),
    // but never exceeded the configured budget.
    expect(server.peakConcurrent, greaterThan(1));
    expect(
      server.peakConcurrent,
      lessThanOrEqualTo(4),
      reason: '4 concurrent batches x 4-wide fallback windows would peak at 16',
    );
  });
}

/// Fake translation API: multi-block batch requests get a non-JSON reply
/// (deterministic parse failure, so every batch falls back to per-block
/// requests); single-block requests are translated after a delay so overlap
/// is observable. Tracks peak in-flight requests.
class _ConcurrencyTrackingServer {
  HttpServer? _server;
  int inFlight = 0;
  int peakConcurrent = 0;

  int get port => _server!.port;

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen((HttpRequest request) async {
      inFlight += 1;
      if (inFlight > peakConcurrent) {
        peakConcurrent = inFlight;
      }
      try {
        final String rawBody = await utf8.decoder.bind(request).join();
        final Map<String, dynamic> requestBody =
            jsonDecode(rawBody) as Map<String, dynamic>;
        final List<dynamic> messages = requestBody['messages'] as List<dynamic>;
        final String userContent =
            (messages.last as Map<String, dynamic>)['content'] as String;
        final Object? payload = _tryJsonDecode(userContent);

        final String responseContent;
        if (payload is Map<String, dynamic> &&
            payload['kind'] == 'initialBookMemory') {
          responseContent = jsonEncode(<String, Object?>{
            'bookSummary': 'A tiny test book.',
            'styleGuide': <Object?>[],
            'glossary': <Object?>[],
            'recentChapters': <Object?>[],
          });
        } else if (payload is Map<String, dynamic> &&
            payload['kind'] == 'chapterMemory') {
          responseContent = jsonEncode(<String, Object?>{
            'title': 'Chapter',
            'summary': 'The chapter was translated.',
            'continuityNotes': <Object?>[],
            'glossary': <Object?>[],
          });
        } else if (payload is Map<String, dynamic> &&
            payload['blocks'] is List &&
            (payload['blocks'] as List).length > 1) {
          // Multi-block batch: fail deterministically so the per-block
          // fallback path runs.
          responseContent = 'this is not json';
        } else {
          // Single-block fallback request: slow enough to overlap.
          await Future<void>.delayed(const Duration(milliseconds: 100));
          responseContent = '<p>Translated.</p>';
        }

        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode(<String, Object?>{
            'choices': <Object?>[
              <String, Object?>{
                'message': <String, Object?>{'content': responseContent},
              },
            ],
          }),
        );
        await request.response.close();
      } finally {
        inFlight -= 1;
      }
    });
  }

  Future<void> close() async {
    await _server?.close(force: true);
  }

  static Object? _tryJsonDecode(String value) {
    try {
      return jsonDecode(value);
    } catch (_) {
      return null;
    }
  }
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
