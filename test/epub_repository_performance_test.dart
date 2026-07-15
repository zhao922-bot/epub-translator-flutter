import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/repositories/epub_translation_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'reuses cached translations without extra memory or translation requests',
    () async {
      final Directory temp = await Directory.systemTemp.createTemp(
        'epub_repository_cached_performance_test_',
      );
      addTearDown(() => temp.delete(recursive: true));

      final List<String> requestKinds = <String>[];
      final HttpServer server = await _startFakeTranslationServer(requestKinds);
      addTearDown(() => server.close(force: true));

      final File epubFile = File('${temp.path}/cached_run.epub');
      await _writeTestEpub(
        epubFile,
        chapters: const <String, String>{
          'OPS/Text/chapter.xhtml': '<p>Hello.</p><p>World.</p>',
        },
      );

      final TranslationConfig config = TranslationConfig.defaults().copyWith(
        apiBaseUrl: 'http://127.0.0.1:${server.port}',
        apiKey: 'sk-test',
        model: 'cache-performance-model-${server.port}',
        chunkSize: 1000,
        maxConcurrent: 2,
      );
      final EpubTranslationRepository repository = EpubTranslationRepository();

      final inspection = await repository.startJob(
        inputPath: epubFile.path,
        outputDirectory: temp.path,
        config: config,
      );
      await repository.translateChapters(
        inputPath: epubFile.path,
        outputDirectory: temp.path,
        config: config,
        chapters: inspection.chapters,
      );

      expect(requestKinds, contains('initialBookMemory'));
      expect(requestKinds, contains('blocks'));
      requestKinds.clear();

      await repository.translateChapters(
        inputPath: epubFile.path,
        outputDirectory: temp.path,
        config: config,
        chapters: inspection.chapters,
      );

      expect(requestKinds, isEmpty);
    },
  );

  test(
    'skips chapter memory when no later uncached chapter can use it',
    () async {
      final Directory temp = await Directory.systemTemp.createTemp(
        'epub_repository_final_memory_test_',
      );
      addTearDown(() => temp.delete(recursive: true));

      final List<String> requestKinds = <String>[];
      final HttpServer server = await _startFakeTranslationServer(requestKinds);
      addTearDown(() => server.close(force: true));

      final File epubFile = File('${temp.path}/single_chapter.epub');
      await _writeTestEpub(
        epubFile,
        chapters: const <String, String>{
          'OPS/Text/chapter.xhtml': '<p>Only chapter.</p>',
        },
      );

      final TranslationConfig config = TranslationConfig.defaults().copyWith(
        apiBaseUrl: 'http://127.0.0.1:${server.port}',
        apiKey: 'sk-test',
        model: 'single-chapter-performance-model-${server.port}',
        chunkSize: 1000,
        maxConcurrent: 2,
      );
      final EpubTranslationRepository repository = EpubTranslationRepository();
      final inspection = await repository.startJob(
        inputPath: epubFile.path,
        outputDirectory: temp.path,
        config: config,
      );

      await repository.translateChapters(
        inputPath: epubFile.path,
        outputDirectory: temp.path,
        config: config,
        chapters: inspection.chapters,
      );

      expect(requestKinds, contains('initialBookMemory'));
      expect(requestKinds, contains('blocks'));
      expect(requestKinds, isNot(contains('chapterMemory')));
    },
  );
}

Future<HttpServer> _startFakeTranslationServer(
  List<String> requestKinds,
) async {
  final HttpServer server = await HttpServer.bind(
    InternetAddress.loopbackIPv4,
    0,
  );
  server.listen((HttpRequest request) async {
    final String rawBody = await utf8.decoder.bind(request).join();
    final Map<String, dynamic> requestBody =
        jsonDecode(rawBody) as Map<String, dynamic>;
    final List<dynamic> messages = requestBody['messages'] as List<dynamic>;
    final Map<String, dynamic> payload =
        jsonDecode((messages.last as Map<String, dynamic>)['content'] as String)
            as Map<String, dynamic>;
    final String kind = payload['kind'] as String? ?? 'blocks';
    requestKinds.add(kind);

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
